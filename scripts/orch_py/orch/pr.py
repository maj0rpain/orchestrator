"""The pr noun (scripts/orch/pr.sh), as far as it is ported: `pr open` and
`pr publish`, with the helpers they share - the push-then-issue-line step
(pr_push_and_body), open_pr, update_pr, pr_label_value, pr_labels_check and
the PR-writing standard's body check (pr_body_check) - and the current
branch's open PR, current_open_pr, which the review-pass noun uses.

run(argv) takes the arguments after `pr`, as orch.sh would hand them on, and
returns the exit code; every error dies through orch.common.die, with bash's
messages and in bash's order of guards and side effects. An op it does not
run dies with bash's "unknown pr op" refusal, every op bash has named in it.
The bash noun still serves the CLI: nothing dispatches here yet.

Bash caches the default branch for its process, so pr open's base fallback
and its issue-line check - and pr publish's recorded base and its check -
share one ask of GitHub; one run here shares it the same way (_DefaultOnce).
The open-tickets refusal is orch.ticket's require_no_open_tickets, called
directly.
"""
from __future__ import annotations

import os
from contextlib import contextmanager
from typing import Iterator, List, Mapping, Optional, Sequence, Tuple

from orch.base import default_branch, recorded_base_into
from orch.branch import branch_pr_set
from orch.checkout import current_branch_or_die
from orch.common import (die, fenced, lines_of, plain_number, read_raw, stdout_write,
                         temp_text_file, warn)
from orch.flow_state import (flow_base_fallback_into, flow_state_file, require_state_read,
                             require_value, state_write_many)
from orch.gh import GhFailed, Unparsed, adapter_of, gh_or_die, label_listed
from orch.git import Git, git_failed
from orch.repo import REPO_REMEDY, RepoPin
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
MERGE_DANGER_HEADING = "Merge Danger"
BODY_HEADINGS = ("Summary", "Evidence", MERGE_DANGER_HEADING)

DOOR = "**Door:**"
BLAST_RADIUS = "**Blast Radius:**"


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
        if section != MERGE_DANGER_HEADING:
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
    under = " under ## " + MERGE_DANGER_HEADING
    for heading in required:
        if heading not in seen:
            problems.append("no ## %s heading" % heading)
        if heading != MERGE_DANGER_HEADING:
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
def pr_push_and_body(run: _Run, branch: str, base: str, issue: str, body_file: str,
                     outcome: str) -> Iterator[str]:
    """The one place the push-then-issue-line rule lives, for open_pr and
    update_pr: pushes <branch> to origin, then yields the path of a temp
    file holding <body_file> behind its issue line - Closes into the default
    branch, so GitHub links the PR as a closer, Refs into any other base,
    since GitHub acts on a closing keyword only there - removed on exit. A
    failed push or write dies naming <outcome>, what the failure leaves
    undone ("no PR was opened", "PR #7 was not updated")."""
    # Full refs: a tag named like the branch outranks a bare source (#2337).
    why = run.git.push_set_upstream("origin", "refs/heads/%s:refs/heads/%s" % (branch, branch))
    if why is not None:
        die("could not push branch %s to origin - %s: %s" % (branch, outcome, why))
    keyword = "Closes" if base == run.default() else "Refs"
    unwritten = "could not write the PR body from %s - %s" % (body_file, outcome)
    text = read_raw(body_file)
    if text is None:
        die(unwritten)
    with temp_text_file("%s #%s\n\n%s" % (keyword, issue, text),
                        "could not create a temp file for the PR body - " + outcome,
                        unwritten) as path:
        yield path


def open_pr(run: _Run, branch: str, base: str, issue: str, title: str, body_file: str,
            draft: bool, labels: Sequence[str]) -> int:
    """Pushes <branch> and opens its PR into <base> under <title>, the body
    behind its issue line (pr_push_and_body) - a draft under <draft>,
    carrying each of <labels> from creation (#1299) - and answers its
    number. Once the PR exists it records the number on the branch as
    branch.<b>.orchestrator-pr (#1200), so a busy check tells, locally,
    that the branch's work is handed off; a failed record only warns: the PR
    is open either way, and the branch merely stays busy."""
    with pr_push_and_body(run, branch, base, issue, body_file, "no PR was opened") as tmp:
        number = gh_or_die("open the PR for branch %s (issue #%s)" % (branch, issue),
                           run.gh().pr_create, base, branch, title, tmp,
                           draft=draft, labels=labels)
    if git_failed(branch_pr_set(run.git, branch, str(number))):
        warn("could not record PR #%d on branch %s - it counts as busy until you switch off it"
             % (number, branch))
    return number


def update_pr(run: _Run, recorded: str, branch: str, base: str, issue: str, title: str,
              body_file: str, labels: Sequence[str]) -> None:
    """pr open's restart path (#1609), for a flow whose state already names
    its PR, <recorded>: the PR must be open on <branch>, else it dies naming
    it and creates none. It pushes, then writes the title, the body (issue
    line included, as on creation, from the PR's own base, warning when that
    is not the flow's <base>) and each of <labels> the PR lacks, removing
    none. A failed push dies before any PR write; a failed write dies naming
    it and each write already landed. A rerun repeats every write."""
    gh = run.gh()
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
    with pr_push_and_body(run, branch, line_base, issue, body_file, outcome) as tmp:
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


def pr_open(args: List[str], run: _Run, root: str) -> None:
    """`pr open <title> <body-file> [--label <name>]...`: the flow's own PR,
    opened from its branch into its base as a draft - the review loop has
    not run yet, so marking it ready is the loop's success condition - and
    recorded in state and on the branch; or, with a PR already recorded,
    that PR updated (update_pr). Prints the PR's number."""
    state_file = flow_state_file(root)
    state = require_state_read(state_file, run.env, ("issue", "branch", "base", "pr"), 1)
    if len(args) < 2:
        die(OPEN_USAGE)
    title, body_file = args[:2]
    _, labels = pr_options(args[2:], OPEN_USAGE, ("--label",))
    if not os.path.isfile(body_file):
        die("body file not found: " + body_file)
    issue, branch, recorded = state["issue"], state["branch"], state["pr"]
    require_value("issue", issue)
    require_value("branch", branch)
    base = flow_base_fallback_into(state["base"], run.gh, run.git, run.pin)
    pr_body_check(body_file, BODY_HEADINGS)
    require_no_open_tickets(run.gh(), issue, "pr open")
    if recorded:
        update_pr(run, recorded, branch, base, issue, title, body_file, labels)
        stdout_write(recorded + "\n")
        return
    number = open_pr(run, branch, base, issue, title, body_file, True, labels)
    state_write_many(state_file, [("pr", str(number))])
    pr_labels_check(run.gh(), number, labels)
    stdout_write("%d\n" % number)


def pr_publish(args: List[str], run: _Run, _root: str) -> None:
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
    branch = current_branch_or_die(run.git)
    base = recorded_base_into(run.gh(), run.git, run.pin, branch)
    pr_body_check(body_file, BODY_HEADINGS)
    require_no_open_tickets(run.gh(), issue, "pr publish")
    number = open_pr(run, branch, base, issue, title, body_file, draft, labels)
    pr_labels_check(run.gh(), number, labels)
    stdout_write("%d\n" % number)


VERBS = {
    "open": pr_open,
    "publish": pr_publish,
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
    verb(argv[1:], _Run(gh, git, env), root)
    return 0
