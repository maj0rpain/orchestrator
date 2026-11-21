"""The gh adapter (ADR-0033): the one place the Python side runs `gh`, the
failure contract its callers die by, and the factory that picks the real
adapter or the store-backed fake.

Every GitHub call goes through an operation named for what its callers need.
Each owns gh's flags and --jq expressions and answers in Python values; a gh
failure raises GhFailed carrying gh's stderr, and an answer that does not
parse as the operation's JSON raises Unparsed. A caller dies through gh_or_die
or gh_die, or reacts another way through gh_reason.

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

from orch.common import die, plain_number, warn
from orch.git import Git
from orch.repo import REPO_REMEDY, RepoPin

T = TypeVar("T")

# The trimmed issue object issue_json answers: every other field gh answers
# with is dropped, so the shape does not change with gh's version.
ISSUE_JSON_JQ = "{number, title, body, labels: [.labels[].name]}"

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


def issue_list_limit(env: Mapping[str, str]) -> int:
    """The most issues one listing asks gh for: ORCH_ISSUE_LIST_LIMIT, a
    test's knob, else 1000."""
    return int(env.get("ORCH_ISSUE_LIST_LIMIT", "") or 1000)


def labelled_limit_warn(env: Mapping[str, str], count: int, label: str) -> None:
    """Warns when a listing of the open issues labelled <label> returned
    <count> rows, reaching its effective limit - the lesser of the issue-list
    limit and GitHub's search cap - naming that limit."""
    limit = min(issue_list_limit(env), ISSUE_SEARCH_CAP)
    if count >= limit:
        warn(
            "the open issues labelled %s reached the issue-list limit of %d"
            " - the newest past it are missing from this list" % (label, limit)
        )


def lines_of(text: str) -> List[str]:
    """<text>'s lines, a final newline ending the last rather than starting
    an empty one; none for empty text. Splits on newlines alone."""
    if not text:
        return []
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    return lines


def _captured_lines(text: str) -> List[str]:
    """The lines of an answer read as the bash readers capture it: every
    trailing newline dropped first."""
    return lines_of(text.rstrip("\n"))


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
        i += 3
        labels = lines[i:i + int(count)]
        if len(labels) < int(count):
            raise GhFailed(LISTING_UNPARSED)
        i += int(count)
        state, _, title = field.partition("\t")
        rows.append(IssueRow(int(number), state, title, labels))
    return rows


def parse_state_labels_body(text: str) -> Tuple[str, List[str], str]:
    """State, label count, the labels, then the body, its trailing newlines
    dropped as the bash reader's capture drops them. Raises GhFailed "gh
    answered no label count" when the count is not a number."""
    state, _, rest = text.rstrip("\n").partition("\n")
    count, _, rest = rest.partition("\n")
    if not plain_number(count):
        raise GhFailed("gh answered no label count")
    labels = []
    for _ in range(int(count)):
        label, _, rest = rest.partition("\n")
        labels.append(label)
    return state, labels, rest


def parse_blocker_states(text: str) -> List[Tuple[int, str]]:
    """<number><TAB><state> lines; GhFailed on a line that is not."""
    states = []
    for line in _captured_lines(text):
        number, _, state = line.partition("\t")
        if not plain_number(number):
            raise GhFailed("gh answered a blocker that does not parse: " + line)
        states.append((int(number), state))
    return states


def urlnumber_of(kind: str, out: str) -> Optional[int]:
    """The number in the last issue (<kind> "issues") or PR ("pull") URL of
    what gh create printed - the URL alone on its line - or None."""
    found = None
    for line in out.split("\n"):
        match = re.match(r"^https?://.*/%s/([0-9]+)$" % kind, line)
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
                raise GhFailed("orch: " + self.message() + "\n") from None

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
            if len(fields) >= 4 and fields[1].isdigit() and int(fields[1]) == 0:
                latest = max(latest, number_of(fields[3]))
        return latest or int(self.now()) + LIMIT_RESET_FALLBACK

    def message(self) -> str:
        return (
            "GitHub API rate limit reached - it resets at %s. An autopilot session"
            " ends its turn now and does not retry; the watcher picks the work up"
            " after the reset." % epoch_iso(self.reset())
        )


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

    def issue_create(self, title: str, body_file: str, labels: Sequence[str]) -> int:
        """Files the issue under every label named; its number. Fails where
        gh succeeded but printed no issue URL."""
        args = ["issue", "create", "--title", title, "--body-file", body_file]
        for label in labels:
            args += ["--label", label]
        out = self._gh(args).rstrip("\n")
        number = urlnumber_of("issues", out)
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
        return parse_blocker_states(answer)


def adapter(env: Optional[Mapping[str, str]] = None, cwd: Optional[str] = None):
    """The gh adapter a command runs on: the store-backed fake when
    ORCH_GH_FAKE_STORE is set in <env> (the process's own when None), else
    the real one; either pinned to the repo of the checkout at <cwd>."""
    env = os.environ if env is None else env
    pin = RepoPin(env, Git(cwd=cwd))
    store = env.get("ORCH_GH_FAKE_STORE", "")
    if store:
        from orch.gh_fake import FakeGh

        return FakeGh(store, env, pin=pin)
    return Gh(pin, env)
