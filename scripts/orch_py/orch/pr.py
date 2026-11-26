"""orch.sh's pr noun (ADR-0067): `pr open` and `pr publish`, with the
helpers they share - the push-then-issue-line step (pr_push_and_body),
open_pr, update_pr, pr_label_value, pr_labels_check and the PR-writing
standard's body check (pr_body_check) - the verbs that need no flow state,
`pr release`, `pr comment`, `pr comments`, `pr fetch`, `pr read` and `pr
update`, the verbs that act on the branch's open PR's draft state, `pr
draft` and `pr ready`, and the current branch's open PR, current_open_pr,
which the review-pass noun uses too. orch.sh runs the noun as a converted
noun, and the bash pr module is gone: each helper keeps the name it had
there, with its messages and its order of steps.

run(argv) takes the arguments after `pr`, as orch.sh hands them on, and
returns the exit code; every error dies through orch.common.die, with bash's
messages and in bash's order of guards and side effects. An op it does not
run dies with bash's "unknown pr op" refusal, naming every op.

The merged-PR backstop (#2477, #2478) lives here alone: PR_CLOSE_GRACE,
pr_close_missed, the merged-closing read and the newest-merge pick, behind
two bridges: close_missed_tick, which autopilot's tick calls at most once a
tick, never once per issue, and close_missed_finish, which side-checkout's
sweep calls once per finished checkout, each call carrying that checkout's
one issue. Each exits 0 whatever its reads and closes did, after their
warnings; only a usage error dies.

Bash cached the default branch for its process, so pr open's base fallback
and its issue-line check - and pr publish's recorded base and its check, and
pr release's base and default branch - share one ask of GitHub; one run here
shares it the same way (_DefaultOnce). The open-tickets refusal is
orch.ticket's require_no_open_tickets, called directly.

pr draft and pr ready (#967) turn the current branch's open PR into a draft,
or mark it ready, for a standalone review pass whose spec questions hold the
PR or no longer do. Stateless, with pr comment's exit codes: 0 done, a PR
already in that state included, saying so - so the caller reads no draft
state; 1 only when the branch has no open PR; 2 for everything else, a
refusal included. A branch an active flow holds is refused: its PR changes
state only through the review loop (review ready and its Ready conditions).
pr ready makes one look at the PR's counted checks first, through
orch/review.py's ci_ready_gate.
"""
from __future__ import annotations

import calendar
import json
import os
import re
import tempfile
import time
from contextlib import contextmanager
from typing import Callable, Dict, Iterator, List, Mapping, Optional, Sequence, Tuple

from orch import comments
from orch.base import base_branch_into, default_branch, recorded_base_into
from orch.branch import branch_name_flow, branch_pr_set
from orch.checkout import checkout_branch, current_branch_or_die
from orch.common import (die, fenced, file_write_atomic, first_line, is_positive_int, lines_of,
                         plain_number, read_raw, rm_f, stdout_write, temp_text_file, warn)
from orch.flow_state import (STATE_UNREADABLE_MSG, StateUnreadable, flow_base_fallback_into,
                             flow_holding_phase, flow_state_file, require_state_read,
                             require_value, state_write_many)
from orch.gh import (GhFailed, Unparsed, adapter_of, gh_or_die, gh_reason, jq_text,
                     label_listed)
from orch.git import Git, git_failed
from orch.repo import REPO_REMEDY, RepoPin
from orch.review import ci_ready_gate
from orch.root import checkout_root
from orch.ticket import require_no_open_tickets
from orch.trust import trust_filter_prs

# Every op of the pr noun, as its unknown-op refusal names them.
OPS = "open|publish|release|comment|comments|fetch|read|update|draft|ready"

OPEN_USAGE = "usage: orch.sh pr open <title> <body-file> [--label <name>]..."
PUBLISH_USAGE = ("usage: orch.sh pr publish <issue> <title> <body-file> [--draft]"
                 " [--label <name>]...")

# The PR-writing standard's required headings (#1387) for pr open and pr
# publish, written once: both require all of them, and pr_body_check's Door
# and Blast Radius rules key on the Merge Danger one. pr release meets a
# smaller standard, Summary alone.
PR_MERGE_DANGER_HEADING = "Merge Danger"
PR_BODY_HEADINGS = ("Summary", "Evidence", PR_MERGE_DANGER_HEADING)

DOOR = "**Door:**"
BLAST_RADIUS = "**Blast Radius:**"

# An issue reference pr release counts in a merged PR's body: Refs, Closes,
# Fixes or Resolves, in any case and anywhere on a line, not inside a word -
# not every closing form GitHub knows, so prose such as "a quick fix #12" is
# never mistaken for one.
_REFERENCE = re.compile(r"(?:^|[^\w])(?:refs|closes|fixes|resolves):?\s+#([0-9]+)", re.IGNORECASE)


def current_open_pr(gh, git, code: int) -> Optional[int]:
    """The current branch's open PR number, the newest the Trust module
    trusts, or None when the branch has none - bash's exit 1. Every other
    failure dies with <code>, where bash dies 2: a detached HEAD;
    no repo (checked here, after the detached-HEAD check, so nothing reaches
    gh unpinned); a GitHub that cannot be read; a listing that does not
    parse."""
    branch = current_branch_or_die(git, code)
    if not gh.pin():
        die(REPO_REMEDY, code)
    lines = gh_or_die("list the open PRs from " + branch, gh.prs_open, branch, code=code)
    try:
        kept = trust_filter_prs(branch, lines)
    except Unparsed:
        die("the open PRs from %s could not be read" % branch, code)
    if not kept:
        return None
    return int(kept[0].split("\t", 1)[0])


# --- one run ------------------------------------------------------------------


class _DefaultOnce:
    """The gh adapter <gh>, its default-branch answer - or failure - asked
    of GitHub once and kept, as bash's default_branch_resolve keeps it for
    the process. Every other operation is <gh>'s own."""

    def __init__(self, gh) -> None:
        self._gh = gh
        self._answer: Optional[Tuple[str, Optional[GhFailed]]] = None

    def __getattr__(self, name: str):
        return getattr(self._gh, name)

    def repo_default_branch(self, repo: str) -> str:
        if self._answer is None:
            try:
                self._answer = (self._gh.repo_default_branch(repo), None)
            except GhFailed as failed:
                self._answer = ("", failed)
        answer, failed = self._answer
        if failed is not None:
            raise failed
        return answer


class _Run:
    """One pr command's adapters: the git adapter, the environment, the
    repo pin resolved once, and the gh adapter, made at its first call and
    kept (_DefaultOnce)."""

    def __init__(self, gh, git, env: Mapping[str, str]) -> None:
        self.git = git
        self.env = env
        self.pin = RepoPin(env, git)
        self._gh_of = adapter_of(gh, env, pin=self.pin)
        self._gh = None

    def gh(self):
        if self._gh is None:
            self._gh = _DefaultOnce(self._gh_of())
        return self._gh

    def default(self) -> str:
        """The default branch, as bash's default_branch_into answers it."""
        return default_branch(self.gh(), self.git, self.pin).name


# --- the merged-PR close (#2477, #2478) ---------------------------------------

# The grace period, in seconds, after a merge before the backstop closes an
# issue GitHub left open: GitHub's own close lands within it, so the backstop
# never races it.
PR_CLOSE_GRACE = 300


def iso_epoch(text: str) -> Optional[int]:
    """The UTC timestamp <text>, YYYY-MM-DDTHH:MM:SSZ, as epoch seconds, or
    None for a value that does not read - bash autopilot_iso_epoch, which
    stays for autopilot's other callers."""
    try:
        return calendar.timegm(time.strptime(text, "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        return None


def pr_close_missed(gh, issue: str, pr: str, merged_at: str, closing: str, default: str,
                    now: float) -> int:
    """The backstop for GitHub's auto-close (#2477). <issue> is open and its
    work finished - the caller checked both - and PR <pr> merged into
    <default>, the default branch, at <merged_at>, a UTC timestamp. Closes
    the issue as completed, with a comment naming the PR and the default
    branch, when the merge is at least PR_CLOSE_GRACE seconds old at <now>,
    epoch seconds, and <closing> - its closingIssuesReferences,
    comma-separated numbers - lists <issue>. Labels are left as they are.
    Returns 0 when it closed the issue, 1 on a silent skip, 2 when the close
    failed, after a warning that skips this issue only, 3 when every other
    condition held but the merge is inside the grace period (the caller may
    warn)."""
    if issue not in closing.split(","):
        return 1
    merged = iso_epoch(merged_at)
    if merged is None:
        return 1
    if int(now) - merged < PR_CLOSE_GRACE:
        return 3
    try:
        gh.issue_close(int(issue), reason="completed",
                       comment="Closed by the orchestrator: PR #%s merged into `%s` with"
                               " `Closes #%s`, but GitHub did not close this issue."
                               % (pr, default, issue))
    except GhFailed as failed:
        warn("could not close issue #%s after PR #%s merged: %s"
             % (issue, pr, gh_reason(failed.stderr)))
        return 2
    return 0


def newest_merge(lines: Sequence[str]) -> Optional[Tuple[str, str, str]]:
    """The newest merge among <lines>, the merged-PR read's lines the
    caller picked - its PR number, merge timestamp and closing issues - or
    None when no line has a merge timestamp, as bash's pr_close_newest
    picked it: the timestamps (one ISO format) compared as strings, a blank
    line skipped, a line with no timestamp never picked, and of equal
    timestamps the earlier line winning."""
    best: Optional[List[str]] = None
    for text in lines:
        fields = text.split("\t") + ["", "", ""]
        if fields[2] and (best is None or fields[2] > best[2]):
            best = fields
    return None if best is None else (best[0], best[2], best[3])


def pr_close_newest(gh, issue: str, default: str, lines: Sequence[str],
                 now: float) -> Tuple[int, str]:
    """pr_close_missed's status on the newest merge among <lines> - the
    caller's pick of the merged-PR read's lines, the ones that may close
    <issue> - and that merge's PR number; 1 and "" when no line has a merge
    timestamp."""
    newest = newest_merge(lines)
    if newest is None:
        return 1, ""
    number, merged_at, closing = newest
    return pr_close_missed(gh, issue, number, merged_at, closing, default, now), number


def pr_merged_closing_read(cmd: _Run, skip: str, issue: str) -> Optional[Tuple[str, List[str]]]:
    """The backstop's one read: the default branch, then the PRs merged
    into it since <issue> - the oldest the caller may close - was created,
    fork PRs dropped (trust_filter_prs), as the merged-PR read's lines less
    their flag. None after a warning ending in <skip>, the caller's words
    for what it gives up, when any read fails."""
    default = cmd.default()
    try:
        since = cmd.gh().issue_created_at(int(issue))
    except GhFailed as failed:
        warn("could not read the creation time of issue #%s: %s - %s"
             % (issue, gh_reason(failed.stderr), skip))
        return None
    try:
        raw = cmd.gh().prs_merged_closing(default, since)
    except GhFailed as failed:
        warn("could not read the merged PRs: %s - %s" % (gh_reason(failed.stderr), skip))
        return None
    try:
        return default, trust_filter_prs("the merged PRs", raw)
    except Unparsed:
        warn("the merged PRs could not be read: a malformed line - %s" % skip)
        return None


def pr_lines_by_prefix(lines: Sequence[str], prefix: str) -> List[str]:
    """The lines of <lines> whose head branch, the second tab-separated
    field, starts with <prefix>, in their order; a line with no second
    field never matches."""
    return [text for text in lines if "\t" in text and text.split("\t")[1].startswith(prefix)]


TICK_USAGE = "usage: orch_python_call pr close_missed_tick <table>"


def _done_rows(table: str) -> List[List[str]]:
    """The done table's rows, `<issue> <running> <sync> <human>` each, as
    their four fields, blank lines skipped; dies with TICK_USAGE on a row
    of another shape: not four fields, an issue that is no plain number, or
    a flag other than 0 or 1."""
    rows = []
    for text in table.split("\n"):
        fields = text.split()
        if not fields:
            continue
        if len(fields) != 4 or not plain_number(fields[0]) \
                or any(flag not in ("0", "1") for flag in fields[1:]):
            die(TICK_USAGE)
        rows.append(fields)
    return rows


def close_missed_tick(
    args: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    now: Callable[[], float] = time.time,
) -> None:
    """Bridge for autopilot's tick, once per tick and only on a done table
    that is not empty: `close_missed_tick <table>`, the done table
    autopilot_done_read took, its `<issue> <running> <sync> <human>` lines
    oldest issue first. The merged-PR backstop (#2478): reads the PRs merged
    into the default branch since the first issue not carrying orch:running
    was created - once, and not at all when every issue carries it - and
    closes each issue not carrying it whose newest merged PR from
    `orch/<issue>-` should have closed it; orch:sync and needs-human do not
    stop it. Prints the table less every issue it closed: the whole table
    when the read fails. A failed read or close warns and skips, never
    failing the bridge. The real adapters, the process's environment and
    clock unless a test hands in others."""
    if len(args) != 1:
        die(TICK_USAGE)
    rows = _done_rows(args[0])
    kept = rows
    bound = next((row[0] for row in rows if row[1] == "0"), None)
    if bound is not None:
        cmd = _Run(gh, Git() if git is None else git, os.environ if env is None else env)
        read = pr_merged_closing_read(cmd, "no merged-PR close this tick", bound)
        if read is not None:
            default, prs = read
            at = now()
            kept = []
            for row in rows:
                if row[1] == "0":
                    picked = pr_lines_by_prefix(prs, branch_name_flow(row[0], ""))
                    if pr_close_newest(cmd.gh(), row[0], default, picked, at)[0] == 0:
                        continue
                kept.append(row)
    stdout_write("".join(" ".join(row) + "\n" for row in kept))


FINISH_USAGE = "usage: orch_python_call pr close_missed_finish <issue> <pr> <branch>"


def close_missed_finish(
    args: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    now: Callable[[], float] = time.time,
) -> None:
    """Bridge for side-checkout's sweep, once per finished checkout whose
    issue is open: `close_missed_finish <issue> <pr> <branch>`, <pr> the
    flow's recorded PR or empty. The merged-PR backstop (#2477): reads the
    PRs merged into the default branch since <issue> was created and closes
    <issue> through the newest merge among them that is PR <pr>, or, with
    no <pr>, that is from <branch>. A merge inside the grace period gets a
    warning, since no later sweep will see it. A failed read or close warns
    and never fails the bridge. The real adapters, the process's
    environment and clock unless a test hands in others."""
    if len(args) != 3 or not plain_number(args[0]) or not (args[1] == "" or plain_number(args[1])):
        die(FINISH_USAGE)
    issue, number, branch = args
    cmd = _Run(gh, Git() if git is None else git, os.environ if env is None else env)
    read = pr_merged_closing_read(cmd, "no merged-PR close for issue #" + issue, issue)
    if read is None:
        return
    default, prs = read
    field, wanted = (0, number) if number else (1, branch)
    picked = [text for text in prs if (text.split("\t") + [""])[field] == wanted]
    status, closed = pr_close_newest(cmd.gh(), issue, default, picked, now())
    if status == 3:
        warn("issue #%s is still open: PR #%s merged less than %d minutes ago - GitHub may yet"
             " close it, and no later sweep will check" % (issue, closed, PR_CLOSE_GRACE // 60))


# --- the shared steps ---------------------------------------------------------


def pr_label_value(usage: str, names: Sequence[str], value: Optional[str]) -> None:
    """Dies, naming --label, unless <value>, the argument after it, is a
    label name: neither absent, empty nor one of the option <names>. Any
    other name is taken as given: gh refuses one the repo does not have,
    before it opens the PR."""
    if not value or value in names:
        die("--label needs a label name - " + usage)


def pr_options(args: List[str], usage: str, names: Sequence[str]) -> Tuple[bool, List[str]]:
    """The options after a command's positional arguments, each of <names>
    - --label, repeatable, and --draft where named: whether --draft was
    given, and the labels in order. Any other argument dies naming it."""
    draft = False
    labels: List[str] = []
    i = 0
    while i < len(args):
        if args[i] == "--draft" and "--draft" in names:
            draft = True
            i += 1
        elif args[i] == "--label":
            value = args[i + 1] if i + 1 < len(args) else None
            pr_label_value(usage, names, value)
            labels.append(value)
            i += 2
        else:
            die("unknown option: %s - %s" % (args[i], usage))
    return draft, labels


def pr_body_problems(text: str, required: Sequence[str]) -> List[str]:
    """Every piece of the PR-writing standard (#1387) <text> lacks or gets
    wrong, in bash's order: an exact `## <heading>` line for each of
    <required> - and, when Merge Danger is one of them, exactly one Door
    line reading one-way or two-way and a Blast Radius line with a value,
    both under ## Merge Danger before the next H2. Structure only, never
    wording or order (ADR-0027): lines inside fenced code blocks are
    skipped, so a Summary visual can neither satisfy nor break it. Each
    line's trailing blanks and CR are ignored."""
    lines = [line.rstrip(" \t\r") for line in lines_of(text)]
    seen = set()
    section = None
    doors = blasts = 0
    bad_doors: List[str] = []
    empty_blast = False
    for line, state in zip(lines, fenced(lines)):
        if state:
            continue
        if line.startswith("## "):
            section = line[3:]
            seen.add(section)
            continue
        if section != PR_MERGE_DANGER_HEADING:
            continue
        if line.startswith(DOOR):
            doors += 1
            value = line[len(DOOR):].lstrip(" \t")
            if value == "":
                bad_doors.append("an empty %s value" % DOOR)
            elif value not in ("one-way", "two-way"):
                bad_doors.append("%s value '%s' is not one-way or two-way" % (DOOR, value))
        elif line.startswith(BLAST_RADIUS):
            blasts += 1
            if line[len(BLAST_RADIUS):].lstrip(" \t") == "":
                empty_blast = True
    problems: List[str] = []
    under = " under ## " + PR_MERGE_DANGER_HEADING
    for heading in required:
        if heading not in seen:
            problems.append("no ## %s heading" % heading)
        if heading != PR_MERGE_DANGER_HEADING:
            continue
        if not doors:
            problems.append("no %s line%s" % (DOOR, under))
        problems.extend(bad_doors)
        if doors > 1:
            problems.append("a second %s line%s" % (DOOR, under))
        if not blasts:
            problems.append("no %s line%s" % (BLAST_RADIUS, under))
        elif empty_blast:
            problems.append("an empty %s value" % BLAST_RADIUS)
    return problems


def pr_body_check(body_file: str, required: Sequence[str]) -> None:
    """Dies, naming in one message every problem pr_body_problems finds in
    <body_file> against the <required> headings - or naming the file when it
    cannot be read. Run after the caller's argument and state checks, which
    it would otherwise mask, and before any push or create, so a refusal
    leaves nothing behind for the caller to undo."""
    text = read_raw(body_file)
    if text is None:
        die("could not read the PR body from %s - no PR was opened" % body_file)
    problems = pr_body_problems(text, required)
    if problems:
        die("the PR body does not meet the PR-writing standard - no PR was opened: "
            + "; ".join(problems))


@contextmanager
def pr_push_and_body(cmd: _Run, branch: str, base: str, issue: str, body_file: str,
                     outcome: str) -> Iterator[str]:
    """The one place the push-then-issue-line rule lives, for open_pr and
    update_pr: pushes <branch> to origin, then yields the path of a temp
    file holding <body_file> behind its issue line - Closes into the default
    branch, so GitHub links the PR as a closer, Refs into any other base,
    since GitHub acts on a closing keyword only there - removed on exit. A
    failed push or write dies naming <outcome>, what the failure leaves
    undone ("no PR was opened", "PR #7 was not updated")."""
    # Full refs: a tag named like the branch outranks a bare source (#2337).
    why = cmd.git.push_set_upstream("origin", "refs/heads/%s:refs/heads/%s" % (branch, branch))
    if why is not None:
        die("could not push branch %s to origin - %s: %s" % (branch, outcome, why))
    keyword = "Closes" if base == cmd.default() else "Refs"
    unwritten = "could not write the PR body from %s - %s" % (body_file, outcome)
    text = read_raw(body_file)
    if text is None:
        die(unwritten)
    with temp_text_file("%s #%s\n\n%s" % (keyword, issue, text),
                        "could not create a temp file for the PR body - " + outcome,
                        unwritten) as path:
        yield path


def open_pr(cmd: _Run, branch: str, base: str, issue: str, title: str, body_file: str,
            draft: bool, labels: Sequence[str]) -> int:
    """Pushes <branch> and opens its PR into <base> under <title>, the body
    behind its issue line (pr_push_and_body) - a draft under <draft>,
    carrying each of <labels> from creation (#1299) - and answers its
    number. Once the PR exists it records the number on the branch as
    branch.<b>.orchestrator-pr (#1200), so a busy check tells, locally,
    that the branch's work is handed off; a failed record only warns: the PR
    is open either way, and the branch merely stays busy."""
    with pr_push_and_body(cmd, branch, base, issue, body_file, "no PR was opened") as tmp:
        number = gh_or_die("open the PR for branch %s (issue #%s)" % (branch, issue),
                           cmd.gh().pr_create, base, branch, title, tmp,
                           draft=draft, labels=labels)
    if git_failed(branch_pr_set(cmd.git, branch, str(number))):
        warn("could not record PR #%d on branch %s - it counts as busy until you switch off it"
             % (number, branch))
    return number


def update_pr(cmd: _Run, recorded: str, branch: str, base: str, issue: str, title: str,
              body_file: str, labels: Sequence[str]) -> None:
    """pr open's restart path (#1609), for a flow whose state already names
    its PR, <recorded>: the PR must be open on <branch>, else it dies naming
    it and creates none. It pushes, then writes the title, the body (issue
    line included, as on creation, from the PR's own base, warning when that
    is not the flow's <base>) and each of <labels> the PR lacks, removing
    none. A failed push dies before any PR write; a failed write dies naming
    it and each write already landed. A rerun repeats every write."""
    gh = cmd.gh()
    # A recorded PR is a number pr open wrote; anything else goes to gh as
    # it is, which refuses it, as bash's adapter call did.
    n = int(recorded) if plain_number(recorded) else recorded
    state, _ = gh_or_die("read the state of PR #%s, recorded in state" % recorded,
                         gh.pr_state_draft, n)
    if state != "OPEN":
        die("PR #%s, recorded in state, is %s, not open - no PR was opened or updated"
            % (recorded, state))
    _, head, pr_base = gh_or_die("read the branch of PR #%s, recorded in state" % recorded,
                                 gh.pr_refs, n)
    if head != branch:
        die("PR #%s, recorded in state, is on branch %s, not the flow's branch %s - no PR was"
            " opened or updated" % (recorded, head, branch))
    line_base = pr_base or base
    if line_base != base:
        warn("PR #%s targets %s, not the flow's base %s - its issue line follows the PR's base"
             % (recorded, line_base, base))
    outcome = "PR #%s was not updated" % recorded
    with pr_push_and_body(cmd, branch, line_base, issue, body_file, outcome) as tmp:
        gh_or_die("write the title of PR #%s" % recorded, gh.pr_title_edit, n, title)
        landed = ["the title"]
        gh_or_die("write the body of PR #%s" % recorded, gh.pr_body_edit, n, tmp,
                  hint="already written: " + ", ".join(landed))
    landed.append("the body")
    if not labels:
        return
    have = gh_or_die("read the labels of PR #%s" % recorded, gh.pr_labels, n,
                     hint="already written: " + ", ".join(landed))
    for label in labels:
        if label_listed(have, label):
            continue
        gh_or_die("add the label '%s' to PR #%s" % (label, recorded), gh.pr_label_add, n, label,
                  hint="already written: " + ", ".join(landed))
        landed.append("the label '%s'" % label)


def pr_labels_check(gh, pr: int, labels: Sequence[str]) -> None:
    """With <labels> named, reads PR <pr>'s labels back and dies naming the
    PR and each label it lacks - or, where the read fails, relaying gh's
    reason. gh adds the labels in a separate mutation after the create
    (#1299), so a create that succeeded does not prove they landed. Called
    only once the PR is recorded, so the record survives either death."""
    if not labels:
        return
    have = gh_or_die("read the labels of PR #%d, open and recorded on its branch" % pr,
                     gh.pr_labels, pr)
    missing = ["'%s'" % label for label in labels if not label_listed(have, label)]
    if not missing:
        return
    if len(missing) == 1:
        die("PR #%d is open but lacks the label %s - add it by hand" % (pr, missing[0]))
    die("PR #%d is open but lacks the labels %s - add them by hand" % (pr, ", ".join(missing)))


# --- the verbs ----------------------------------------------------------------


def pr_open(args: List[str], cmd: _Run, root: str) -> None:
    """`pr open <title> <body-file> [--label <name>]...`: the flow's own PR,
    opened from its branch into its base as a draft - the review loop has
    not run yet, so marking it ready is the loop's success condition - and
    recorded in state and on the branch; or, with a PR already recorded,
    that PR updated (update_pr). Prints the PR's number."""
    state_file = flow_state_file(root)
    state = require_state_read(state_file, cmd.env, ("issue", "branch", "base", "pr"), 1)
    if len(args) < 2:
        die(OPEN_USAGE)
    title, body_file = args[:2]
    _, labels = pr_options(args[2:], OPEN_USAGE, ("--label",))
    if not os.path.isfile(body_file):
        die("body file not found: " + body_file)
    issue, branch, recorded = state["issue"], state["branch"], state["pr"]
    require_value("issue", issue)
    require_value("branch", branch)
    base = flow_base_fallback_into(state["base"], cmd.gh, cmd.git, cmd.pin)
    pr_body_check(body_file, PR_BODY_HEADINGS)
    require_no_open_tickets(cmd.gh(), issue, "pr open")
    if recorded:
        update_pr(cmd, recorded, branch, base, issue, title, body_file, labels)
        stdout_write(recorded + "\n")
        return
    number = open_pr(cmd, branch, base, issue, title, body_file, True, labels)
    state_write_many(state_file, [("pr", str(number))])
    pr_labels_check(cmd.gh(), number, labels)
    stdout_write("%d\n" % number)


def pr_publish(args: List[str], cmd: _Run, _root: str) -> None:
    """`pr publish <issue> <title> <body-file> [--draft] [--label <name>]...`:
    the PR-opening boundary a quick implementation calls. Stateless: it
    opens a PR on the current branch into its recorded base and records
    nothing in flow state - not a draft, since a quick implementation's
    review pass already ran, unless --draft holds it for a human's ruling on
    a spec question (#967)."""
    if len(args) < 3:
        die(PUBLISH_USAGE)
    issue, title, body_file = args[:3]
    draft, labels = pr_options(args[3:], PUBLISH_USAGE, ("--draft", "--label"))
    if not os.path.isfile(body_file):
        die("body file not found: " + body_file)
    if not plain_number(issue):
        die("issue must be a plain issue number, got: " + issue)
    branch = current_branch_or_die(cmd.git)
    base = recorded_base_into(cmd.gh(), cmd.git, cmd.pin, branch)
    pr_body_check(body_file, PR_BODY_HEADINGS)
    require_no_open_tickets(cmd.gh(), issue, "pr publish")
    number = open_pr(cmd, branch, base, issue, title, body_file, draft, labels)
    pr_labels_check(cmd.gh(), number, labels)
    stdout_write("%d\n" % number)


def referenced_issues(bodies: str) -> List[str]:
    """The issue numbers <bodies> refers to (_REFERENCE), each as written,
    in numeric order and once each - the first of equal numbers kept."""
    found: Dict[int, str] = {}
    for line in bodies.split("\n"):
        for match in _REFERENCE.finditer(line):
            found.setdefault(int(match.group(1)), match.group(1))
    return [found[n] for n in sorted(found)]


def pr_release(args: List[str], cmd: _Run, _root: str) -> Optional[int]:
    """The release PR: carries the base branch in effect back into the
    default branch. Stateless like pr publish, and pushes nothing - the base
    branch is already on origin."""
    usage = "usage: orch.sh pr release [--force] <title> <body-file>"
    force = bool(args) and args[0] == "--force"
    if force:
        args = args[1:]
    if len(args) != 2:
        die(usage)
    title, body_file = args
    if not title:
        die("the title is empty")
    if not os.path.isfile(body_file):
        die("body file not found: " + body_file)
    base = base_branch_into(cmd.gh(), cmd.git, cmd.pin)
    default = cmd.default()
    if base == default:
        die("the base branch is the default branch (%s) - there is nothing to release;"
            " set another with base set" % default)
    open_prs = gh_or_die("list the open PRs from %s into %s" % (base, default),
                         cmd.gh().prs_open, base, default)
    try:
        kept = trust_filter_prs(base, open_prs)
    except Unparsed:
        die("the open PRs from %s into %s could not be read" % (base, default))
    if kept:
        die("a release PR from %s into %s is already open: #%s" % (base, default, kept[0]))
    # Read from the merged PRs' bodies rather than GitHub's closing-issue
    # links: GitHub only links closing keywords on PRs into the default
    # branch, and a Refs line never links at all.
    bodies = gh_or_die("list the PRs merged into " + base, cmd.gh().prs_merged_bodies, base)
    refs = referenced_issues(bodies)
    issues: List[str] = []
    # The listing of open issues leaves pull requests out, so a reference to
    # a PR, a closed issue or an unknown number gets no Closes line. It is
    # read only when something is referenced, and even under --force.
    if refs:
        listed = gh_or_die("list the open issues", cmd.gh().issues_open_titles)
        open_issues = {str(n) for n, _ in listed}
        issues = [n for n in refs if n in open_issues]
    if not issues and not force:
        die("nothing to close: no PR merged into %s refers to a still-open issue"
            " - pass --force to release anyway" % base)
    # Only Summary: a release PR carries PRs already reviewed (#1387).
    pr_body_check(body_file, ("Summary",))
    head = "".join("Closes #%s\n" % n for n in issues) + ("\n" if issues else "")
    text = head + (read_raw(body_file) or "")
    with temp_text_file(text, "could not create a temp file for the release PR body",
                        "could not write the release PR body") as tmp:
        # Not a draft: nothing after this would ever mark it ready.
        number = gh_or_die("open the release PR from %s into %s" % (base, default),
                           cmd.gh().pr_create, default, base, title, tmp)
    stdout_write("%d\n" % number)
    return None


def pr_comment(args: List[str], cmd: _Run, _root: str) -> Optional[int]:
    """A stateless post on the current branch's open PR, the PR counterpart
    of issue comment - for a standalone review pass, which records its
    declines there. Three outcomes: 0 posted (printing the PR number), 1 only
    when the branch has no open PR, and 2 for everything else - GitHub
    unreadable, a failed post, a usage error, a missing file, a detached
    HEAD, no repo - so a caller reading 1 never takes a failure for "no
    PR"."""
    if len(args) != 1:
        die("usage: orch.sh pr comment <file>", 2)
    path = args[0]
    if not os.path.isfile(path):
        die("body file not found: " + path, 2)
    number = current_open_pr(cmd.gh(), cmd.git, 2)
    if number is None:
        return 1
    gh_or_die("comment on PR #%d" % number, cmd.gh().pr_comment, number, path, code=2)
    stdout_write("%d\n" % number)
    return None


def pr_comments(args: List[str], cmd: _Run, _root: str) -> Optional[int]:
    """The PR counterpart of issue comments (#418), so a standalone review
    pass reads earlier passes' declines: the trusted comments of the current
    branch's open PR written to the file in issue comments' format. Exits as
    pr comment does: 1, writing nothing, only when the branch has no open
    PR, and 2 for everything else, with the file untouched."""
    if len(args) != 1:
        die("usage: orch.sh pr comments <file>", 2)
    path = args[0]
    number = current_open_pr(cmd.gh(), cmd.git, 2)
    if number is None:
        return 1
    text = comments.rendered(cmd.gh(), "read the comments of PR #%d" % number, str(number), "pr",
                             code=2)
    if not file_write_atomic(path, text + "\n" if text else ""):
        die("could not write " + path, 2)
    return None


def required_open_pr(cmd: _Run) -> int:
    """The PR pr fetch and pr update work on: the current branch's open PR.
    Unlike pr comment, no open PR is an ordinary failure here, since both run
    where a PR is known to exist: every failure dies with exit 1."""
    number = current_open_pr(cmd.gh(), cmd.git, 1)
    if number is None:
        die("no open PR for branch %s" % checkout_branch(cmd.git))
    return number


def pr_fetch(args: List[str], cmd: _Run, _root: str) -> Optional[int]:
    """The PR counterpart of issue fetch: the current branch's open PR's
    body written to the file, every carriage return removed, so GitHub's
    web-UI CRLF lines reach agents as LF, and gh's one newline kept. The
    temporary file beside the target is made before the read, so a failed
    read leaves the target as it was and no temporary file behind."""
    if len(args) != 1:
        die("usage: orch.sh pr fetch <file>")
    path = args[0]
    number = required_open_pr(cmd)
    directory = os.path.dirname(path) or "."
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError:
        pass
    try:
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", dir=directory)
    except OSError:
        die("could not create a temp file beside " + path)
    try:
        body = gh_or_die("read the body of PR #%d" % number, cmd.gh().pr_body, number)
        with os.fdopen(fd, "wb") as out:
            out.write((body.replace("\r", "") + "\n").encode("utf-8", "surrogateescape"))
        os.replace(tmp, path)
    except OSError:
        rm_f(tmp)
        die("could not write " + path)
    except BaseException:
        rm_f(tmp)
        raise
    return None


def pr_update(args: List[str], cmd: _Run, _root: str) -> Optional[int]:
    """The PR counterpart of issue update, with one guard issue update has
    no need for: the body's first line is the Closes/Refs line pr open wrote,
    and a correction must never drop or change it, so a file that does not
    open with exactly that line is refused and the body left as it was."""
    if len(args) != 1:
        die("usage: orch.sh pr update <file>")
    path = args[0]
    if not os.path.isfile(path):
        die("body file not found: " + path)
    number = required_open_pr(cmd)
    current = gh_or_die("read the body of PR #%d" % number, cmd.gh().pr_body, number)
    line = first_line(current)
    if not re.fullmatch(r"(Closes|Refs) #[0-9]+", line):
        die("PR #%d's body does not open with a Closes/Refs #<issue> line, so there is no issue"
            " line to keep - refusing to replace it" % number)
    if first_line(read_raw(path) or "") != line:
        die("%s must open with PR #%d's issue line, '%s' - refusing to replace the body"
            % (path, number, line))
    gh_or_die("replace the body of PR #%d" % number, cmd.gh().pr_body_edit, number, path)
    return None


def listed_body(encoded: str) -> str:
    """A PR body as the open-PR listing carries it, a JSON string, decoded
    as `jq -r .` decodes it under a `$(...)` capture: every trailing newline
    dropped. Unparsed when it is no JSON."""
    try:
        value = json.loads(encoded)
    except ValueError:
        raise Unparsed("a body that is no JSON") from None
    return jq_text(value).rstrip("\n")


def pr_read(args: List[str], cmd: _Run, _root: str) -> Optional[int]:
    """`pr read <issue> <file>`: writes the body of the open PR whose body
    opens with the issue line `Closes #<issue>` or `Refs #<issue>` (the
    newest, where several do), a `---` line, then its diff, to <file>. One
    listing carries every body; only the winner's diff is read apart. Every
    listed line must read, whichever issue its body names. A fork PR is
    ignored, with one stderr line, as the Trust module's PR filter words
    it."""
    if len(args) != 2:
        die("usage: orch.sh pr read <issue> <file>")
    issue_text, path = args
    if not is_positive_int(issue_text):
        die("not an issue number: " + issue_text)
    # The number without its leading zeros: 012 is issue 12, never octal.
    issue = int(issue_text)
    unread = "the open PRs for issue #%d could not be read" % issue
    lines = gh_or_die("list the open PRs", cmd.gh().prs_open_bodies)
    named: List[str] = []
    bodies: Dict[int, str] = {}
    wanted = ("Closes #%d" % issue, "Refs #%d" % issue)
    for line in lines:
        # As bash's `IFS=$'\t' read -r pr enc flag` splits it: a run of tabs
        # is one separator, the last field takes the rest.
        fields = re.split(r"\t+", line.strip("\t"), maxsplit=2) + ["", ""]
        number, encoded, flag = fields[:3]
        if not number:
            continue
        if not is_positive_int(number) or flag not in ("true", "false"):
            die(unread)
        try:
            body = listed_body(encoded)
        except Unparsed:
            die(unread)
        if first_line(body) in wanted:
            named.append("%d\t%s" % (int(number), flag))
            bodies[int(number)] = body
    kept = trust_filter_prs("#%d" % issue, named)
    if not kept:
        die("no open PR closes or refers to issue #%d" % issue)
    found = int(kept[0])
    diff = gh_or_die("read the diff of PR #%d" % found, cmd.gh().pr_diff, found)
    text = (bodies[found] + "\n\n---\n" + diff).rstrip("\n") + "\n"
    if not file_write_atomic(path, text):
        die("could not write " + path)
    return None


def open_pr_draft_flag(cmd: _Run, root: str) -> Optional[Tuple[int, bool]]:
    """pr draft's and pr ready's shared front: refuses, exit 2, a branch an
    active flow holds or a state.json that cannot be read, then answers the
    current branch's open PR number and whether it is a draft; None when the
    branch has no open PR, as current_open_pr answers."""
    branch = current_branch_or_die(cmd.git, 2)
    try:
        hold = flow_holding_phase(flow_state_file(root), branch, "")
    except StateUnreadable:
        die(STATE_UNREADABLE_MSG, 2)
    if hold is not None:
        die("the active flow holds %s at phase %s - its PR changes state only through the"
            " review loop" % (branch, hold.phase), 2)
    n = current_open_pr(cmd.gh(), cmd.git, 2)
    if n is None:
        return None
    _, is_draft = gh_or_die("read PR #%d" % n, cmd.gh().pr_state_draft, n, code=2)
    return n, is_draft


def pr_draft(args: List[str], cmd: _Run, root: str) -> int:
    """`pr draft`: the current branch's open PR turned into a draft."""
    if args:
        die("usage: orch.sh pr draft", 2)
    found = open_pr_draft_flag(cmd, root)
    if found is None:
        return 1
    n, is_draft = found
    if is_draft:
        print("PR #%d is already a draft" % n)
        return 0
    gh_or_die("turn PR #%d into a draft" % n, cmd.gh().pr_draft, n, code=2)
    print("PR #%d is now a draft" % n)
    return 0


def pr_ready(args: List[str], cmd: _Run, root: str) -> int:
    """`pr ready`: the current branch's open draft PR marked ready, once the
    CI gate lets it through."""
    if args:
        die("usage: orch.sh pr ready", 2)
    found = open_pr_draft_flag(cmd, root)
    if found is None:
        return 1
    n, is_draft = found
    if not is_draft:
        print("PR #%d is already ready" % n)
        return 0
    ci_ready_gate(cmd.gh(), n, code=2)
    gh_or_die("mark PR #%d ready" % n, cmd.gh().pr_ready, n, code=2)
    print("PR #%d is now ready" % n)
    return 0


# The ops this noun runs, each taking the arguments after the op, the run's
# adapters and the checkout's root, and returning its exit code (None for 0).
VERBS = {
    "open": pr_open,
    "publish": pr_publish,
    "release": pr_release,
    "comment": pr_comment,
    "comments": pr_comments,
    "fetch": pr_fetch,
    "read": pr_read,
    "update": pr_update,
    "draft": pr_draft,
    "ready": pr_ready,
}


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
) -> int:
    """`orch.sh pr <op> ...`: the real adapters and the process's
    environment unless a test hands in others. Outside a checkout it dies
    first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    verb = VERBS.get(op)
    if verb is None:
        die("unknown pr op: %s (want %s)" % (op or "<none>", OPS))
    code = verb(argv[1:], _Run(gh, git, env), root)
    return 0 if code is None else code
