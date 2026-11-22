"""The gh adapter (ADR-0033): the one place the Python side runs `gh`, the
failure contract its callers die by, and the factory that picks the real
adapter or the store-backed fake.

Every GitHub call goes through an operation named for what its callers need.
Each owns gh's flags and --jq expressions and answers in Python values; a gh
failure raises GhFailed carrying gh's stderr, and an answer that does not
parse as the operation's JSON raises Unparsed. A caller dies through gh_or_die
or gh_die, or reacts another way through gh_reason. The claim delete is the
one operation the real adapter makes through git rather than gh, as bash's
adapter_claim_delete is: the claim is a ref on origin.

The real adapter, Gh, reproduces gh.sh's guard: every call is pinned to the
repo (orch.repo), dying with the remedy when none resolves, and a failed call
goes through the rate-limit handling, Limits, which the fake's injected
failures go through too.

adapter() is the factory: the fake (orch.gh_fake) whenever ORCH_GH_FAKE_STORE
is set, as the bash suite's fake_github sets it, else the real adapter.
"""
from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import time
from typing import (
    Callable,
    List,
    Mapping,
    NamedTuple,
    NoReturn,
    Optional,
    Sequence,
    Tuple,
    TypeVar,
)

from orch.common import die, lines_of, message_line, plain_number, warn
from orch.git import Git
from orch.repo import REPO_REMEDY, RepoPin

T = TypeVar("T")

# The trimmed issue object issue_json answers: every other field gh answers
# with is dropped, so the shape does not change with gh's version.
ISSUE_JSON_JQ = "{number, title, body, labels: [.labels[].name]}"

# A parent's sub-issues as sub_issues reads them, gh.sh's SUB_ISSUES_JQ. GitHub
# can leave the dependency summary off an issue; its blocker field is then
# empty rather than a count.
SUB_ISSUES_JQ = ('.[] | "\\(.number)\\t\\(.state | ascii_upcase)\\t'
                 '\\(.issue_dependencies_summary.blocked_by // "")"')

# The GraphQL query and --jq behind issue_authorship, gh.sh's own: one line,
# so a logged argv stays one line.
ISSUE_AUTHORSHIP_QUERY = (
    "query($owner: String!, $name: String!, $number: Int!) { repository(owner:"
    " $owner, name: $name) { issue(number: $number) { author { login }"
    " authorAssociation editor { login } timelineItems(last: 1, itemTypes:"
    " [RENAMED_TITLE_EVENT]) { nodes { ... on RenamedTitleEvent { actor { login"
    " } } } } } } }"
)
ISSUE_AUTHORSHIP_JQ = (
    '.data.repository.issue | (.author.login // ""), (.authorAssociation // ""),'
    ' (.editor.login // ""), (.timelineItems.nodes[0].actor.login // "")'
)


class IssueRow(NamedTuple):
    """One issue of a titled listing: its number, its state as GitHub
    answered it (never assumed from the listing's open-only filter), its
    title and its labels."""

    number: int
    state: str
    title: str
    labels: List[str]


class LabelledBody(NamedTuple):
    """One issue of a listing with bodies: its number, its labels, and its
    body, carriage returns kept and trailing newlines dropped."""

    number: int
    labels: List[str]
    body: str


class SubIssue(NamedTuple):
    """One sub-issue of a parent: its number, OPEN or CLOSED, and the count
    of its blockers still open - None where GitHub gave no dependency
    summary, never a stand-in zero."""

    number: int
    state: str
    open_blockers: Optional[int]


# --- the failure contract ----------------------------------------------------


class GhFailed(Exception):
    """A failed gh call: <stderr> is gh's own error, or the rate-limit
    message that replaced it."""

    def __init__(self, stderr: str) -> None:
        super().__init__(stderr)
        self.stderr = stderr


class Unparsed(Exception):
    """gh succeeded but its answer is not the JSON the operation reads."""


def gh_reason(stderr: str) -> str:
    """The reason a failed gh call gives: the first line of its stderr, or
    "gh gave no reason" when that line is empty."""
    return stderr.split("\n", 1)[0] or "gh gave no reason"


def gh_die(what: str, stderr: str, hint: str = "", code: int = 1) -> NoReturn:
    """Dies with "gh could not <what>: <reason>", then " - <hint>" when a
    hint is given; exit <code>, 2 where the bash verb died through die2."""
    message = "gh could not %s: %s" % (what, gh_reason(stderr))
    if hint:
        message += " - " + hint
    die(message, code)


def gh_or_die(
    what: str,
    operation: Callable[..., T],
    *args,
    hint: str = "",
    code: int = 1,
    **kwargs,
) -> T:
    """Runs the operation and returns its answer; on a gh failure dies
    through gh_die with the same hint and code."""
    try:
        return operation(*args, **kwargs)
    except GhFailed as failed:
        gh_die(what, failed.stderr, hint, code)


def verify_twice(what: str, unverified: str, verifier: Callable[[], bool]) -> None:
    """The one verify-then-die runner - the one-retry policy ADR-0011
    records for ticket publish's links. <verifier> reads fresh and answers
    whether the read-back verified, raising GhFailed on a failed read. A
    mismatch or a failed read gets one more attempt, and that attempt
    decides: verified returns, a failed read dies through gh_die "<what>"
    with gh's reason, a mismatch dies with <unverified>. Either death exits
    1."""
    failed: Optional[GhFailed] = None
    for _ in range(2):
        try:
            if verifier():
                return
            failed = None
        except GhFailed as error:
            failed = error
    if failed is not None:
        gh_die(what, failed.stderr)
    die(unverified)


# --- labels -------------------------------------------------------------------

# ASCII case folding alone, whatever the locale: a Turkish I never folds to a
# dotless i, and a non-ASCII letter stays as it is.
_ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")


def label_listed(labels: Sequence[str], label: str) -> bool:
    """Whether <label> is one of <labels>, matched whole, literally and
    case-insensitively: GitHub's label names are case-insensitive, and it
    attaches a label in the repo's existing casing. A label holding a
    newline is never listed, as the bash side's list_has refuses one."""
    if "\n" in label:
        return False
    want = label.translate(_ASCII_LOWER)
    return any(have.translate(_ASCII_LOWER) == want for have in labels)


# --- answers, as the bash readers split them -------------------------------

# GitHub's search returns at most this many rows, whatever --limit asks for.
ISSUE_SEARCH_CAP = 1000
LISTING_UNPARSED = "gh answered a listing that does not parse"


def blocker_unparsed(line: str) -> str:
    """The failure of a blocker listing whose <line> does not parse - the
    adapter's and its fake's one wording."""
    return "gh answered a blocker that does not parse: " + line


def issue_list_limit(env: Mapping[str, str]) -> int:
    """The most issues one listing asks gh for: ORCH_ISSUE_LIST_LIMIT, a
    test's knob, else 1000."""
    return int(env.get("ORCH_ISSUE_LIST_LIMIT", "") or 1000)


def labelled_limit_warn(env: Mapping[str, str], count: int, *labels: str) -> None:
    """Warns when a listing of the open issues carrying every one of
    <labels> returned <count> rows, reaching its effective limit - the lesser
    of the issue-list limit and GitHub's search cap - naming that limit and
    the labels, joined by " and "."""
    limit = min(issue_list_limit(env), ISSUE_SEARCH_CAP)
    if count >= limit:
        warn(
            "the open issues labelled %s reached the issue-list limit of %d"
            " - the newest past it are missing from this list" % (" and ".join(labels), limit)
        )


def _captured_lines(text: str) -> List[str]:
    """The lines of an answer read as the bash readers capture it: every
    trailing newline dropped first."""
    return lines_of(text.rstrip("\n"))


def _label_block(lines: List[str], i: int, count: str) -> Tuple[List[str], int]:
    """The <count> labels of a record's label block starting at lines[i], and
    the index past them. Raises GhFailed "gh answered a listing that does not
    parse" when fewer are left."""
    labels = lines[i:i + int(count)]
    if len(labels) < int(count):
        raise GhFailed(LISTING_UNPARSED)
    return labels, i + int(count)


def parse_titled_rows(text: str) -> List[IssueRow]:
    """The count-marked records of a titled listing: number, state and title
    joined by a tab, label count, then one label per line. Raises GhFailed
    "gh answered a listing that does not parse" on a record that is not."""
    lines = _captured_lines(text)
    rows = []
    i = 0
    while i < len(lines):
        number = lines[i]
        field = lines[i + 1] if i + 1 < len(lines) else ""
        count = lines[i + 2] if i + 2 < len(lines) else ""
        if not (plain_number(number) and field and plain_number(count)):
            raise GhFailed(LISTING_UNPARSED)
        labels, i = _label_block(lines, i + 3, count)
        state, _, title = field.partition("\t")
        rows.append(IssueRow(int(number), state, title, labels))
    return rows


def parse_labelled_bodies(text: str) -> List[LabelledBody]:
    """The count-marked records of a listing with bodies: number, label
    count, one label per line, the body's line count, then the body's lines.
    The answer's trailing newlines are dropped first, so the last record's
    body lines missing at its end are empty lines. Raises GhFailed "gh
    answered a listing that does not parse" on a record that is not."""
    lines = _captured_lines(text)
    rows = []
    i = 0
    while i < len(lines):
        number = lines[i]
        count = lines[i + 1] if i + 1 < len(lines) else ""
        if not (plain_number(number) and plain_number(count)):
            raise GhFailed(LISTING_UNPARSED)
        labels, i = _label_block(lines, i + 2, count)
        if i >= len(lines) or not plain_number(lines[i]):
            raise GhFailed(LISTING_UNPARSED)
        body_line_count = int(lines[i])
        i += 1
        body = lines[i:i + body_line_count]
        body += [""] * (body_line_count - len(body))
        i += body_line_count
        rows.append(LabelledBody(int(number), labels, "\n".join(body).rstrip("\n")))
    return rows


def parse_state_labels_body(text: str) -> Tuple[str, List[str], str]:
    """State, label count, the labels, then the body, its trailing newlines
    dropped, as a `$(...)` capture drops them. Raises GhFailed "gh answered
    no label count" when the count is not a number."""
    state, _, rest = text.rstrip("\n").partition("\n")
    count, _, rest = rest.partition("\n")
    if not plain_number(count):
        raise GhFailed("gh answered no label count")
    labels = []
    for _ in range(int(count)):
        label, _, rest = rest.partition("\n")
        labels.append(label)
    return state, labels, rest


def parse_numbered_lines(text: str, unparsed: Callable[[str], str]) -> List[Tuple[int, str]]:
    """<number><TAB><value> lines, as each number and the rest; GhFailed
    with unparsed(<line>) on a line whose number is not one."""
    rows = []
    for line in _captured_lines(text):
        number, _, value = line.partition("\t")
        if not plain_number(number):
            raise GhFailed(unparsed(line))
        rows.append((int(number), value))
    return rows


def parse_sub_issues(text: str) -> List[SubIssue]:
    """<number><TAB><state><TAB><open blockers> lines, the count empty where
    GitHub gave no dependency summary; GhFailed on a line that is not one."""
    rows = []
    for line in _captured_lines(text):
        fields = line.split("\t")
        if (len(fields) != 3 or not plain_number(fields[0])
                or not (fields[2] == "" or plain_number(fields[2]))):
            raise GhFailed("gh answered a sub-issue that does not parse: " + line)
        rows.append(SubIssue(int(fields[0]), fields[1],
                             int(fields[2]) if fields[2] else None))
    return rows


def parse_numbers(text: str, unparsed: Callable[[str], str]) -> List[int]:
    """One number a line; GhFailed with unparsed(<line>) on a line that is
    not one."""
    numbers = []
    for line in _captured_lines(text):
        if not plain_number(line):
            raise GhFailed(unparsed(line))
        numbers.append(int(line))
    return numbers


def urlnumber_of(out: str) -> Optional[int]:
    """The number in the last issue URL of what gh issue create printed - the
    URL alone on its line - or None."""
    found = None
    for line in out.split("\n"):
        match = re.match(r"^https?://.*/issues/([0-9]+)$", line)
        if match:
            found = int(match.group(1))
    return found


def parse_comments(text: str) -> List[dict]:
    """The comments list of gh's `--json comments` object; Unparsed when the
    answer is no such object."""
    answer = _json(text)
    if not isinstance(answer, dict) or not isinstance(answer.get("comments"), list):
        raise Unparsed("no comment list")
    return answer["comments"]


def _json(text: str):
    try:
        return json.loads(text)
    except ValueError:
        raise Unparsed("not JSON") from None


def first_and_rest(text: str) -> Tuple[str, List[str]]:
    lines = _captured_lines(text)
    return (lines[0], lines[1:]) if lines else ("", [])


# --- GitHub API rate limits (#2577) -------------------------------------------

LIMIT_WAIT_DEFAULT = 60.0
# A limit with no exhausted pool to read its reset from is waited out this
# long.
LIMIT_RESET_FALLBACK = 900


def limit_kind(stderr: str) -> str:
    """"secondary" for GitHub's secondary-limit wording, "submitted too
    quickly" or an HTTP 429; "primary" for its primary-limit wording; "" for
    any other failure."""
    if re.search(r"secondary rate limit|submitted too quickly|HTTP 429", stderr, re.I):
        return "secondary"
    if re.search(r"API rate limit (already )?exceeded", stderr, re.I):
        return "primary"
    return ""


def epoch_iso(epoch: int) -> str:
    """Epoch seconds as a UTC timestamp."""
    moment = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def number_of(text: str) -> int:
    """<text> as a number, as awk reads one: its leading digits, else 0."""
    match = re.match(r"\s*([0-9]+)", text)
    return int(match.group(1)) if match else 0


Pools = Callable[[], str]


class Limits:
    """The one limit handler, gh.sh's gh_limit_retry and gh_limit_handle,
    for the real adapter's calls and the fake's injected failures alike.

    run(attempt) makes the attempt; a failure that is a limit is handled: a
    first secondary limit is waited out (ORCH_GH_LIMIT_WAIT seconds, default
    60) and retried once; a primary limit, one met again after the retry, or
    a first secondary one on a compound write (which a rerun could duplicate)
    is given up on, failing the call with the distinct message in place of
    gh's stderr. Any other failure passes through untouched. <pools> reads
    the rate-limit pools, a "<pool><TAB><remaining><TAB><limit><TAB><reset>"
    line each, raising GhFailed when it cannot: the read is never retried nor
    handled.

    Out of this slice: an autopilot process's record of the reset (the
    GitHub pause and the hit file), and a re-callable wait's quiet give-up,
    whose mark no Python process can be handed.
    """

    def __init__(
        self,
        env: Mapping[str, str],
        pools: Pools,
        sleep: Callable[[float], None],
        now: Callable[[], float],
    ) -> None:
        self.env = env
        self.pools = pools
        self.sleep = sleep
        self.now = now

    def run(self, attempt: Callable[[], T], compound: bool = False) -> T:
        retried = False
        while True:
            try:
                return attempt()
            except GhFailed as failed:
                kind = limit_kind(failed.stderr)
                if not kind:
                    raise
                if kind == "secondary" and not retried and not compound:
                    self.sleep(float(self.env.get("ORCH_GH_LIMIT_WAIT", "") or LIMIT_WAIT_DEFAULT))
                    retried = True
                    continue
                raise GhFailed(message_line(self.message())) from None

    def reset(self) -> int:
        """The epoch second a limit is waited out until: the latest reset
        among the pools at 0 remaining; with none, or a failed read of the
        pools, 15 minutes from now."""
        try:
            answer = self.pools()
        except GhFailed:
            answer = ""
        latest = 0
        for line in lines_of(answer):
            fields = line.split()
            if len(fields) >= 4 and plain_number(fields[1]) and int(fields[1]) == 0:
                latest = max(latest, number_of(fields[3]))
        return latest or int(self.now()) + LIMIT_RESET_FALLBACK

    def message(self) -> str:
        return (
            "GitHub API rate limit reached - it resets at %s. An autopilot session"
            " ends its turn now and does not retry; the watcher picks the work up"
            " after the reset." % epoch_iso(self.reset())
        )


# --- claims -------------------------------------------------------------------


def claim_ref(n: int) -> str:
    """The ref on origin that holds the claim on issue #n - bash
    adapter_claim_ref."""
    return "refs/orch/claims/%d" % n


# --- the real adapter --------------------------------------------------------


def _text(data: bytes) -> str:
    """gh's output as text, byte for byte: no newline translation, and an
    undecodable byte kept."""
    return data.decode("utf-8", "surrogateescape")


def _strip_one_newline(text: str) -> str:
    """<text> less the one newline gh's --jq ends a single value with."""
    return text[:-1] if text.endswith("\n") else text


class Gh:
    """The real operations. <pin> resolves the repo; <env> is the environment
    gh runs with (PATH among it) and the knobs are read from; <sleep> and
    <now> are the clock the rate-limit handling waits on and reads."""

    def __init__(
        self,
        pin: RepoPin,
        env: Mapping[str, str],
        sleep: Callable[[float], None] = time.sleep,
        now: Callable[[], float] = time.time,
    ) -> None:
        self.repo_pin = pin
        self.env = env
        self.limits = Limits(env, self._rate_limit, sleep, now)

    def pin(self) -> bool:
        """Whether a repo resolves to pin gh to, calling no gh - for a command
        that reserves exit 1 for a "no" and dies with the remedy itself."""
        return self.repo_pin.resolve() is not None

    def _run(self, args: Sequence[str]) -> str:
        """gh run once with <args>, pinned: its stdout on success; else
        GhFailed with its stderr. No repo dies with the remedy, exit 1,
        calling no gh."""
        env = self.repo_pin.gh_env()
        if env is None:
            die(REPO_REMEDY)
        run = subprocess.run(
            ["gh", *args],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if run.returncode != 0:
            raise GhFailed(_text(run.stderr))
        return _text(run.stdout)

    def _gh(self, args: Sequence[str], compound: bool = False) -> str:
        """gh.sh's guard: _run through the rate-limit handling - the stdout of
        the deciding attempt alone. A <compound> write is never retried."""
        return self.limits.run(lambda: self._run(args), compound)

    def _rate_limit(self) -> str:
        """The core and graphql pools, read once: never retried or handled,
        and costing no quota."""
        return self._run(
            ["api", "rate_limit", "--jq",
             ".resources | {core, graphql} | to_entries[] | "
             "[.key, .value.remaining, .value.limit, .value.reset] | @tsv"]
        )

    # --- issue operations ---

    def issue_body(self, n: int) -> str:
        """The issue's body as GitHub holds it."""
        return _strip_one_newline(
            self._gh(["issue", "view", str(n), "--json", "body", "--jq", ".body"])
        )


    def issue_json(self, n: int) -> dict:
        """The issue as one object - number, title, body and label names -
        with no comments; Unparsed when gh's answer is no such object."""
        answer = self._gh(
            ["issue", "view", str(n), "--json", "number,title,body,labels",
             "--jq", ISSUE_JSON_JQ]
        )
        issue = _json(answer)
        if not isinstance(issue, dict):
            raise Unparsed("not an issue object")
        return issue

    def issue_comments(self, n: int) -> List[dict]:
        """The issue's comments as gh answers them: each its author login
        object, authorAssociation, createdAt, body and url, among gh's other
        fields. Unparsed when gh's answer is no comment list."""
        return parse_comments(self._gh(["issue", "view", str(n), "--json", "comments"]))

    def issue_authorship(self, n: int) -> Tuple[str, str, str, str]:
        """The issue author's login, the author's authorAssociation, the
        login of whoever last edited the body and of whoever made the newest
        rename of the title - each "" where GitHub answers none. One GraphQL
        read, for the Trust module."""
        lines = _captured_lines(self._gh(
            ["api", "graphql", "-F", "owner={owner}", "-F", "name={repo}",
             "-F", "number=%d" % n, "-f", "query=" + ISSUE_AUTHORSHIP_QUERY,
             "--jq", ISSUE_AUTHORSHIP_JQ]
        ))
        lines += [""] * (4 - len(lines))
        return lines[0], lines[1], lines[2], lines[3]

    def issue_state(self, n: int) -> str:
        """OPEN or CLOSED - or PULL where <n> is a pull request's number,
        which gh issue view answers for too."""
        return self._gh(
            ["issue", "view", str(n), "--json", "state,url",
             "--jq", 'if (.url | test("/pull/")) then "PULL" else .state end']
        ).rstrip("\n")

    def issue_state_labels(self, n: int) -> Tuple[str, List[str]]:
        """OPEN or CLOSED, and the labels."""
        return first_and_rest(self._gh(
            ["issue", "view", str(n), "--json", "state,labels",
             "--jq", ".state, (.labels[].name)"]
        ))

    def issue_state_labels_body(self, n: int) -> Tuple[str, List[str], str]:
        """OPEN or CLOSED, the labels, and the body less its trailing
        newlines."""
        return parse_state_labels_body(self._gh(
            ["issue", "view", str(n), "--json", "state,labels,body",
             "--jq", ".state, (.labels | length), (.labels[].name), .body"]
        ))

    def issue_title_labels(self, n: int) -> Tuple[str, List[str]]:
        """The title, and the labels."""
        return first_and_rest(self._gh(
            ["issue", "view", str(n), "--json", "title,labels",
             "--jq", ".title, (.labels[].name)"]
        ))

    def issues_titled_rows(self, label: str) -> List[IssueRow]:
        """The open issues carrying <label>, oldest first and cut at the
        issue-list limit (the newest dropped), warning when the cut is
        reached."""
        rows = parse_titled_rows(self._gh(
            ["issue", "list", "--state", "open", "--label", label,
             "--search", "sort:created-asc", "--limit", str(issue_list_limit(self.env)),
             "--json", "number,state,title,labels",
             "--jq", '.[] | .number, (.state + "\\t" + .title), (.labels | length), (.labels[].name)']
        ))
        labelled_limit_warn(self.env, len(rows), label)
        return rows

    def issues_open_titles(self) -> List[Tuple[int, str]]:
        """Every open issue, pull requests left out, as its number and title,
        newest first as GitHub lists them - every page, never cut at the
        issue-list limit."""
        return parse_numbered_lines(self._gh(
            ["api", "--paginate", "repos/{owner}/{repo}/issues?state=open&per_page=100",
             "--jq", '.[] | select(has("pull_request") | not) | "\\(.number)\\t\\(.title)"']
        ), lambda line: LISTING_UNPARSED)

    def issues_labelled_bodies(self, *labels: str) -> List[LabelledBody]:
        """The open issues carrying every label named, oldest first and cut
        at the issue-list limit (the newest dropped), each with its labels and
        body, warning when the cut is reached. The body's line count is its
        newlines plus one, counted with `indices`, never `split`, whose answer
        on an empty string differs between jq implementations."""
        args = ["issue", "list", "--state", "open"]
        for label in labels:
            args += ["--label", label]
        rows = parse_labelled_bodies(self._gh(
            args + ["--search", "sort:created-asc", "--limit", str(issue_list_limit(self.env)),
                    "--json", "number,labels,body",
                    "--jq", '.[] | .number, (.labels | length), (.labels[].name),'
                    ' ((.body | indices("\\n") | length) + 1), .body']
        ))
        labelled_limit_warn(self.env, len(rows), *labels)
        return rows

    def issue_create(self, title: str, body_file: str, labels: Sequence[str]) -> int:
        """Files the issue under every label named; its number. Fails where
        gh succeeded but printed no issue URL."""
        args = ["issue", "create", "--title", title, "--body-file", body_file]
        for label in labels:
            args += ["--label", label]
        out = self._gh(args).rstrip("\n")
        number = urlnumber_of(out)
        if number is None:
            raise GhFailed("gh issue create printed no issue URL: " + out)
        return number

    def issue_body_edit(self, n: int, body_file: str) -> None:
        """Replaces the issue's body with the file's contents."""
        self._gh(["issue", "edit", str(n), "--body-file", body_file])

    def issue_comment(self, n: int, body_file: str) -> None:
        """Posts the file's contents as a comment on the issue."""
        self._gh(["issue", "comment", str(n), "--body-file", body_file])

    def issue_relabel(
        self, n: int, add: Sequence[str] = (), remove: Sequence[str] = ()
    ) -> None:
        """One edit adding and removing the labels named; with none named,
        no edit at all."""
        if not add and not remove:
            return
        args = ["issue", "edit", str(n)]
        for label in remove:
            args += ["--remove-label", label]
        for label in add:
            args += ["--add-label", label]
        self._gh(args)

    def issue_close(
        self,
        n: int,
        reason: str = "",
        comment: str = "",
        duplicate_of: Optional[int] = None,
    ) -> None:
        """Closes the issue, reason "completed" or "not planned" (none,
        gh's default), or as a duplicate of issue <duplicate_of> - never given
        with a reason, and needing gh 2.102 or newer - posting the comment on
        it where one is given."""
        args = ["issue", "close", str(n)]
        if reason:
            args += ["--reason", reason]
        if comment:
            args += ["--comment", comment]
        if duplicate_of is not None:
            args += ["--duplicate-of", str(duplicate_of)]
        # gh posts the comment first and closes second, so a failed close can
        # leave the comment, and a rerun would post it twice.
        self._gh(args, compound=bool(comment))

    # --- claim operations ---

    def claim_delete(self, n: int) -> None:
        """Frees the claim on #n - bash adapter_claim_delete: pushes the
        delete of its ref to origin through the repo pin's git adapter, no gh
        call. A claim already gone is freed all the same - a push whose
        reason says it does not exist; any other failure raises GhFailed with
        git's reason."""
        reason = self.repo_pin.git.push("origin", ":" + claim_ref(n))
        if reason is not None and "does not exist" not in reason:
            raise GhFailed(reason + "\n")

    # --- PR operations ---

    def prs_open(self, head: str, base: str = "") -> List[str]:
        """The open PRs from the head branch - into the base branch, where one
        is named - newest first, one line each as gh prints it,
        `<number><TAB><isCrossRepository>`, unfiltered: the Trust module's
        trust_filter_prs reads the lines and drops the fork PRs."""
        args = ["pr", "list", "--head", head]
        if base:
            args += ["--base", base]
        return _captured_lines(self._gh(
            args + ["--state", "open", "--json", "number,isCrossRepository",
                    "--jq", '.[] | "\\(.number)\\t\\(.isCrossRepository)"']
        ))

    def pr_body(self, n: int) -> str:
        """The PR's body as GitHub holds it."""
        return _strip_one_newline(
            self._gh(["pr", "view", str(n), "--json", "body", "--jq", ".body"])
        )

    def pr_comments(self, n: int) -> List[dict]:
        """The PR's comments as gh answers them, as issue_comments answers an
        issue's. Unparsed when gh's answer is no comment list."""
        return parse_comments(self._gh(["pr", "view", str(n), "--json", "comments"]))

    # --- label operations ---

    def label_create(self, name: str, colour: str, description: str) -> None:
        """Creates the label where the repo has none of that name; fails
        where it has one, leaving it as it is."""
        self._gh(["label", "create", name, "--color", colour, "--description", description])

    # --- repo operations ---

    def repo_default_branch(self, repo: str) -> str:
        """The default branch of <repo>, named [HOST/]OWNER/REPO, as gh
        answers it less its trailing newlines: a caller validates it. The
        repo goes in gh's argv because `gh repo view` ignores GH_REPO and
        would otherwise read gh's own default repo."""
        return self._gh(
            ["repo", "view", repo, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"]
        ).rstrip("\n")

    # --- sub-issue and dependency operations ---

    def issue_parent(self, n: int) -> Optional[int]:
        """The number of the issue #n is a sub-issue of, or None. Read from
        the issue's own parent_issue_url, so every gh failure is a real one."""
        url = self._gh(
            ["api", "repos/{owner}/{repo}/issues/%d" % n,
             "--jq", ".parent_issue_url // empty"]
        ).rstrip("\n")
        if not url:
            return None
        number = url.rsplit("/", 1)[-1]
        if not plain_number(number):
            raise GhFailed("gh api printed a parent URL with no issue number: " + url)
        return int(number)

    def sub_issues(self, parent: int) -> List[SubIssue]:
        """Every sub-issue of the parent, open or closed, in the order GitHub
        published them; none for a parent with none."""
        return parse_sub_issues(self._gh(
            ["api", "--paginate", "repos/{owner}/{repo}/issues/%d/sub_issues" % parent,
             "--jq", SUB_ISSUES_JQ]
        ))

    def blockers(self, n: int) -> List[int]:
        """The issues #n is blocked by, open or closed, in GitHub's order."""
        answer = self._gh(
            ["api", "--paginate",
             "repos/{owner}/{repo}/issues/%d/dependencies/blocked_by" % n,
             "--jq", ".[].number"]
        )
        return parse_numbers(answer, blocker_unparsed)

    def _issue_api_id(self, n: int) -> str:
        """The issue's REST id, which the sub-issue and dependency writes name
        the other issue by."""
        return self._gh(["api", "repos/{owner}/{repo}/issues/%d" % n, "--jq", ".id"]).rstrip("\n")

    def sub_issue_link(self, parent: int, child: int) -> None:
        """Links the child as a sub-issue of the parent."""
        child_id = self._issue_api_id(child)
        self._gh(["api", "--method", "POST", "repos/{owner}/{repo}/issues/%d/sub_issues" % parent,
                  "-F", "sub_issue_id=" + child_id])

    def sub_issue_unlink(self, parent: int, child: int) -> None:
        """Unlinks the child from the parent's sub-issues."""
        child_id = self._issue_api_id(child)
        self._gh(["api", "--method", "DELETE", "repos/{owner}/{repo}/issues/%d/sub_issue" % parent,
                  "-F", "sub_issue_id=" + child_id])

    def blocker_add(self, n: int, blocker: int) -> None:
        """Adds the edge marking #n blocked by the blocker."""
        blocker_id = self._issue_api_id(blocker)
        self._gh(["api", "--method", "POST",
                  "repos/{owner}/{repo}/issues/%d/dependencies/blocked_by" % n,
                  "-F", "issue_id=" + blocker_id])

    def blocker_remove(self, n: int, blocker: int) -> None:
        """Removes the edge marking #n blocked by the blocker."""
        blocker_id = self._issue_api_id(blocker)
        self._gh(["api", "--method", "DELETE",
                  "repos/{owner}/{repo}/issues/%d/dependencies/blocked_by/%s" % (n, blocker_id)])

    def issue_open_blockers(self, n: int) -> Optional[int]:
        """The count of #n's blockers still open, from its dependency
        summary; None where GitHub leaves the summary off - never a stand-in
        zero."""
        count = self._gh(
            ["api", "repos/{owner}/{repo}/issues/%d" % n,
             "--jq", '.issue_dependencies_summary.blocked_by // ""']
        ).strip("\n")
        if not count:
            return None
        if not plain_number(count):
            raise GhFailed("gh answered a blocker count that is not a number: " + count)
        return int(count)

    def blockers_states(self, n: int) -> List[Tuple[int, str]]:
        """The issues #n is blocked by, in GitHub's order, each with OPEN or
        CLOSED."""
        answer = self._gh(
            ["api", "--paginate",
             "repos/{owner}/{repo}/issues/%d/dependencies/blocked_by" % n,
             "--jq", '.[] | "\\(.number)\\t\\(.state | ascii_upcase)"']
        )
        return parse_numbered_lines(answer, blocker_unparsed)


def open_issue_read(
    gh, n: str, not_open: str, body: bool = False, hint: str = ""
) -> Tuple[List[str], str]:
    """Issue <n>'s labels and - only when <body> is asked for, else "" - its
    body, from one state read, <n> a plain number as given. A failed read
    dies through gh_die "read issue #<n>" with the hint; an issue that is not
    OPEN dies with <not_open>, verbatim, since the callers' messages are not
    one shape. It checks no label: each caller keeps its own label test."""
    what = "read issue #" + n
    if body:
        state, labels, text = gh_or_die(what, gh.issue_state_labels_body, int(n), hint=hint)
    else:
        state, labels = gh_or_die(what, gh.issue_state_labels, int(n), hint=hint)
        text = ""
    if state != "OPEN":
        die(not_open)
    return labels, text


def adapter(
    env: Optional[Mapping[str, str]] = None,
    cwd: Optional[str] = None,
    pin: Optional[RepoPin] = None,
):
    """The gh adapter a command runs on: the store-backed fake when
    ORCH_GH_FAKE_STORE is set in <env> (the process's own when None), else
    the real one; either pinned by <pin>, else to the repo of the checkout at
    <cwd> - a caller that reads the pin itself hands it in, so the repo is
    resolved once."""
    env = os.environ if env is None else env
    pin = RepoPin(env, Git(cwd=cwd)) if pin is None else pin
    store = env.get("ORCH_GH_FAKE_STORE", "")
    if store:
        from orch.gh_fake import FakeGh

        return FakeGh(store, env, pin=pin)
    return Gh(pin, env)
