"""The review noun (scripts/orch/review.sh), as far as it is ported: the verb
dispatch, with its unknown-op refusal and every usage line bash has, and
`review begin`, `path`, `terminal`, `resume` and `retire`, with the budget
fallback and its default of 5 (review_budget_fallback). The verbs other
tickets port - file, known-items, standards, ci, ci-log, rerun and ready -
check their arguments as bash does and, past them, die with the unknown-op
refusal.

run(argv) takes the arguments after `review`, as orch.sh would hand them on,
and returns the exit code; every error dies through orch.common.die, with
bash's messages and in bash's order of guards and side effects, in a plain
and an autopilot session. Each verb reads its flow state once. The bash noun
still serves the CLI: nothing dispatches here yet.

Under the verbs sits the review loop's terminal-state read: an iteration's
record path (review_record_path), the record's Terminal state section
(review_record_terminal), the record the terminal state is read from, the
flat one or, while a redo is half-finished, its retired copy under
pre-redo-<n>/ (review_terminal_record), whether the flat record is gone
(review_flat_record_gone), and the classification itself
(review_terminal_state), each as bash's, messages included; and `review
retire <n>`'s move of the iteration records aside into pre-redo-<n>/
(review_retire), which a redo review makes. The bash copies stay for
doctor until the cutover; tests/test_review.py pins this classification to
bash's by the golden review records of tests/review_terminal/, run through
both, and tests/test_review_noun.py reads them through `review terminal`.

It also holds the CI gate `pr ready` runs before it marks a PR ready
(ci_ready_gate), with the helpers under it - which checks count
(ci_counted), one look at them (ci_counted_probe), its classification
(ci_classify) and the unreachable verdict (ci_unreachable) - each a copy of
bash's, messages included. The bash versions stay in review.sh for `review
ci`, the loop and doctor until the review noun converts (ADR-0067).
"""
from __future__ import annotations

import fnmatch
import glob
import os
import time
from typing import Callable, Dict, List, Mapping, NoReturn, Optional, Tuple

from orch.common import (ORCH_DIR_NAME, capture, die, int_as_test_reads, is_positive_int,
                         mkdir_p_or_die, move_files_aside, plain_number, read_raw, rm_f_or_die,
                         stdout_write, trim, warn)
from orch.branch import discard_own_branch_work
from orch.checkout import checkout_branch_or_rebasing
from orch.filed_finding import FILED_AXES, FILED_SEVERITIES
from orch.flow_state import (Pair, flow_state_file, flow_state_get_many, require_state,
                             require_state_read, state_write_many)
from orch.gh import Check, GhFailed, gh_reason
from orch.git import Git
from orch.handoff import section_body
from orch.redo import redo_midway
from orch.root import checkout_root

TERMINAL_HEADING = "## Terminal state"
# The separators `stop` may carry its reason after, on the same line.
STOP_SEPARATORS = ("-", "–", "—", ":")
# The one expected-shape line a malformed terminal state is quoted with.
MALFORMED_SHAPE = ("expected: first line 'ready', or 'stop' with its reason after a separator "
                   "(-, –, —, :) or on the lines below")


def review_dir(root: str) -> str:
    """The review directory of the checkout at <root>, where every review
    record lies."""
    return "%s/%s/review" % (root, ORCH_DIR_NAME)


def review_record_path(root: str, i: str) -> str:
    """The path of iteration <i>'s review record in the checkout at <root>,
    as `review path` gives it - numeric check, base 10, the review directory
    made - reading no state. Dies when <i> is not a plain number or the
    directory cannot be made."""
    if not plain_number(i):
        die("not an iteration number: %s" % i)
    # Flat, and numbered on across every loop the flow runs: one flow, one
    # trail, and nothing is ever moved aside for a loop that comes later.
    directory = review_dir(root)
    mkdir_p_or_die(directory, "cannot create the review directory %s" % directory)
    return "%s/iteration-%02d.md" % (directory, int(i, 10))


def review_record_terminal(path: str) -> Optional[str]:
    """The Terminal state section of the record at <path>, its trailing
    newlines dropped, when the record exists and the section holds more than
    whitespace - the one test of a loop's recorded end; None otherwise."""
    if not os.path.isfile(path):
        return None
    text = "\n".join(section_body(read_raw(path) or "", TERMINAL_HEADING)).rstrip("\n")
    return text if trim(text) else None


# The keys the fallback to a retired record reads.
FALLBACK_KEYS = ("issue", "slug", "branch", "redo_count")
# The keys `review terminal` reads, the fallback's among them, in one read.
TERMINAL_KEYS = ("iteration", "budget") + FALLBACK_KEYS


def review_terminal_record(root: str, i: str,
                           state: Optional[Mapping[str, str]] = None) -> str:
    """The path of the record iteration <i>'s terminal state is read from:
    the flat iteration-NN.md, or, when that is gone while a redo review is
    half-finished (redo_midway), the same record under
    review/pre-redo-<redo_count>/ if it is there. A caller that already read
    FALLBACK_KEYS hands them over as <state>; otherwise it reads state only
    on that fallback, those keys in one read, a failed one counting as no
    redo in progress. Dies as review_record_path does."""
    flat = review_record_path(root, i)
    if not os.path.exists(flat):
        if state is None:
            state = flow_state_get_many(flow_state_file(root), FALLBACK_KEYS)
        n = state and redo_midway(state["issue"], state["slug"], state["branch"],
                                  state["redo_count"])
        if n:
            retired = "%s/pre-redo-%s/%s" % (review_dir(root), n, os.path.basename(flat))
            if os.path.exists(retired):
                return retired
    return flat


def review_flat_record_gone(root: str, i: str) -> bool:
    """Whether iteration <i> is an integer above 0 and its flat
    iteration-NN.md is gone - the one state in which review_terminal_record
    looks past it (redo_midway)."""
    if not is_positive_int(i):
        return False
    flat, _, died = capture(lambda: review_record_path(root, i))
    return not died and not os.path.exists(flat)


def review_terminal_state(root: str, i: str, budget: str,
                          state: Optional[Mapping[str, str]] = None) -> Tuple[List[str], int]:
    """The review loop's last iteration, <i>, classified against <budget>,
    as bash review_terminal_state: (its lines, its status). The first line is
    the classification word: ready or stop (status 0), or none, pending,
    interrupted, malformed or unreadable (status 1). For stop the recorded
    reason follows, for malformed the expected-shape line, and for
    unreadable review_record_path's own message.

    The section is read as markdown is written: blank lines under the heading
    are skipped, the first line is trimmed, and `stop` may carry its reason
    on the same line after a separator (-, –, —, :). Anything else in a
    non-empty section is malformed. A missing or empty record is pending
    short of the budget and interrupted once it is spent. While a redo review
    is half-finished and the flat record is gone, the record is read from
    pre-redo-<redo_count>/ (review_terminal_record), <state> its keys when
    the caller read them."""
    if int_as_test_reads(i) == 0:
        return ["none"], 1
    path, err, died = capture(lambda: review_terminal_record(root, i, state))
    if died:
        # The detail is review_record_path's own last orch: line, its
        # newline kept as bash's capture keeps it, so a blank line follows.
        return ["unreadable"] + err.rpartition("orch: ")[2].split("\n"), 1
    # A loop can stop short of its budget, so a recorded terminal state is
    # read whatever the iteration; only its absence depends on the budget.
    sec = review_record_terminal(path)
    if sec is None:
        n, spent = int_as_test_reads(i), int_as_test_reads(budget)
        pending = n is not None and spent is not None and n < spent
        return ["pending" if pending else "interrupted"], 1
    # The section from its first line holding more than spaces and tabs on.
    lines = sec.split("\n")
    start = next(k for k, line in enumerate(lines) if line.strip(" \t"))
    first_raw, _, rest = "\n".join(lines[start:]).rstrip("\n").partition("\n")
    first = trim(first_raw)
    if first == "ready":
        return ["ready"], 0
    if first.startswith("stop"):
        after = trim(first[len("stop"):])
        sep = next((s for s in STOP_SEPARATORS if after.startswith(s)), "")
        # Bare `stop`, or `stop` and a separator: anything else after the word
        # (`stopped`, `stop CI failed`) falls through to malformed.
        if not after or sep:
            reason = trim(after[len(sep):])
            return ["stop"] + ([reason] if reason else []) + (rest.split("\n") if rest else []), 0
    return ["malformed", MALFORMED_SHAPE], 1


def review_retire(root: str, n: str) -> str:
    """`review retire <n>`'s move, as bash's: every iteration record of the
    checkout at <root> moved into review/pre-redo-<n>/, the review directory
    made first; the folder's path, which the bash verb prints. A folder that
    exists is the one a run of this same redo made before dying, so it is
    resumed into, but one already holding a record being moved is refused
    before any move (move_files_aside). Dies first when <n> is not a plain
    number. It reads no state: the caller requires the flow."""
    if not plain_number(n):
        die("not a redo number: %s" % n)
    directory = review_dir(root)
    dest = "%s/pre-redo-%s" % (directory, n)
    mkdir_p_or_die(directory, "cannot create the review directory %s" % directory)
    names = sorted(name for name in os.listdir(directory)
                   if fnmatch.fnmatchcase(name, "iteration-*.md")
                   and os.path.exists(os.path.join(directory, name)))
    move_files_aside(directory, dest, "a review record - redo_count should only increase", names)
    return dest


# --- the CI gate ---------------------------------------------------------------

# The indent of a classification's detail lines, like doctor's remedies.
CI_DETAIL_INDENT = "      "


def ci_unreachable(detail: str) -> List[str]:
    """The `unreachable` verdict and its indented detail line, the one
    spelling of both."""
    return ["unreachable", CI_DETAIL_INDENT + detail]


def ci_classify(checks: Optional[List[Check]], stderr: str) -> List[str]:
    """One read of a PR's checks classified, as bash ci_classify: the
    verdict, then any detail lines, indented. <checks> is None for a read
    that failed, with gh's <stderr>: unreachable, naming its reason. No
    checks is none; any failed or cancelled check with a name is failing,
    naming each; else any pending one is pending; else green."""
    if checks is None:
        return ci_unreachable(gh_reason(stderr))
    if not checks:
        return ["none"]
    failed = [c.name for c in checks if c.bucket in ("fail", "cancel") and c.name]
    if failed:
        return ["failing"] + [CI_DETAIL_INDENT + name for name in failed]
    if any(c.bucket == "pending" for c in checks):
        return ["pending"]
    return ["green"]


def ci_counted(gh, pr: int) -> List[Check]:
    """The one owner of which checks count for a PR: the required checks
    where any are reported, else every check. A failed read raises GhFailed,
    so it stays apart from an empty answer. No grace: a caller that waits
    does so before calling it."""
    return gh.pr_checks(pr, "required") or gh.pr_checks(pr, "all")


def ci_counted_probe(gh, pr: int) -> List[str]:
    """ci_classify's classification of PR <pr>'s counted checks
    (ci_counted)."""
    try:
        checks = ci_counted(gh, pr)
    except GhFailed as failed:
        return ci_classify(None, failed.stderr)
    return ci_classify(checks, "")


def ci_ready_gate(gh, pr: int, code: int = 1) -> None:
    """The check before PR <pr> is marked ready: one look, no grace and no
    polling, through ci_counted. It only refuses. Failed and unreadable
    checks die, exit <code>; pending ones warn on stderr and return; green
    or none return silently. bash's --hint is not copied: pr ready, its one
    Python caller, gives none."""
    verdict, *detail = ci_counted_probe(gh, pr)
    # The detail lines, unindented, comma-separated, empty ones skipped.
    checks = ", ".join(line.lstrip(" ") for line in detail if line.lstrip(" "))
    if verdict == "failing":
        message = "PR #%d has failed checks: %s" % (pr, checks)
    elif verdict == "unreachable":
        message = "PR #%d checks cannot be read: %s" % (pr, checks)
    else:
        if verdict == "pending":
            warn("PR #%d checks are still pending" % pr)
        return
    die(message, code)


# --- the noun -----------------------------------------------------------------

# What a review budget reads as when nobody has set one - a flow started
# before the key existed, or a value nothing can count. The bound lives here
# rather than in the skill's prose: a session that has spent four iterations
# arguing with itself is exactly the one that would re-remember five as six.
# The number itself is the human's, read from state.
DEFAULT_BUDGET = "5"


def review_budget_fallback(raw: str) -> str:
    """The budget read from state, <raw>, or DEFAULT_BUDGET where it is
    empty or not a plain number - bash review_budget_fallback."""
    return raw if plain_number(raw) else DEFAULT_BUDGET


# Every op of the review noun, as its unknown-op refusal names them.
OPS = "begin|path|file|known-items|standards|ci|ci-log|rerun|ready|terminal|resume|retire"


def run(argv: List[str], git=None, env: Optional[Mapping[str, str]] = None,
        clock: Callable[[], float] = time.time) -> int:
    """`orch.sh review <op>`: the real git adapter, the process's
    environment and the system clock unless a test hands in others; the exit
    code. Outside a checkout it dies first, as orch.sh does, whatever the
    op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op, args = (argv[0], argv[1:]) if argv else ("", [])
    verb = _VERBS.get(op)
    if verb is None:
        die("unknown review op: %s (want %s)" % (op or "<none>", OPS))
    return verb(args, root, git, env, clock) or 0


def _begin(args: List[str], root: str, git, env: Mapping[str, str], clock) -> None:
    """`review begin`: refuses past the budget, else records and prints the
    next iteration. A loop's first iteration - the recorded one 0, or one
    whose record has a Terminal state - renews the loop's flake rerun in the
    write that records it; resume never gets here. Its arguments are
    ignored, as bash's."""
    state_file = flow_state_file(root)
    state = require_state_read(state_file, env, ["iteration", "budget"], 1)
    prior = state["iteration"]
    recorded = int_as_test_reads(prior)
    if recorded is None:
        die("not an iteration number: %s" % prior)
    n = recorded + 1
    budget = review_budget_fallback(state["budget"])
    if n > int(budget, 10):
        die("budget of %s iterations spent - stop the loop and report, do not start another"
            % budget)
    pairs: List[Pair] = [("iteration", str(n))]
    if recorded == 0 or _terminal_recorded(root, prior):
        pairs.append(("flake_rerun_used", "false"))
    state_write_many(state_file, pairs, clock)
    stdout_write("%d\n" % n)


def _terminal_recorded(root: str, i: str) -> bool:
    """Whether iteration <i>'s record has a Terminal state. A record path
    that cannot be had - its death's message let through to stderr, as
    bash's command substitution lets it through - counts as none."""
    try:
        path = review_record_path(root, i)
    except SystemExit:
        return False
    return review_record_terminal(path) is not None


# The keys `review resume` reads, the terminal-state read's among them, in
# one read.
RESUME_KEYS = TERMINAL_KEYS + ("phase",)


def _resume(args: List[str], root: str, git, env: Mapping[str, str], clock) -> None:
    """`review resume`: resumes a review loop whose driving session died
    mid-iteration, spending no budget (ADR-0054). Only a pending or
    interrupted loop resumes; any other state exits 1 with nothing changed.
    Then the current branch - the one a rebase in progress is rebasing - must
    be the flow's own, and the discard rule is applied to it, a refusal in an
    interactive main checkout touching nothing else. With no record for the
    last iteration the dead run's reviewer reports are cleared and `rerun
    <i>` printed; with a record, the iteration finished, and `next`
    (pending) or `terminate` (interrupted) is printed. `iteration` and
    `budget` are never written. A failed clear dies naming the report."""
    if args:
        die("usage: orch.sh review resume")
    state = require_state_read(flow_state_file(root), env, RESUME_KEYS, 1)
    i = state["iteration"]
    lines, _ = review_terminal_state(root, i, review_budget_fallback(state["budget"]), state)
    word = lines[0]
    if word not in ("pending", "interrupted"):
        die("nothing to resume: review terminal says %s" % (word or "nothing"))
    branch = checkout_branch_or_rebasing(git, root)
    if branch is None:
        die("review resume: the current checkout is on no branch - nothing was discarded")
    discard_own_branch_work(git, root, env, "review resume", branch, state["branch"],
                            state["phase"] != "done")
    path = review_record_path(root, i)
    if not os.path.isfile(path):
        stem = path[:-len(".md")]
        for report in sorted(glob.glob(glob.escape(stem) + "-*.md")):
            rm_f_or_die(report, "could not clear the dead iteration's reviewer report " + report)
        stdout_write("rerun %s\n" % i)
    elif word == "pending":
        stdout_write("next\n")
    else:
        stdout_write("terminate\n")


def _path(args: List[str], root: str, git, env: Mapping[str, str], clock) -> None:
    """`review path [iteration]`: the record path of <iteration>, or of the
    recorded iteration when none is given or it is empty."""
    state_file = flow_state_file(root)
    if not args or args == [""]:
        n = require_state_read(state_file, env, ["iteration"], 1)["iteration"]
    else:
        require_state(state_file, env)
        if len(args) > 1:
            die("usage: orch.sh review path [iteration]")
        n = args[0]
    stdout_write(review_record_path(root, n) + "\n")


def _terminal(args: List[str], root: str, git, env: Mapping[str, str], clock) -> int:
    """`review terminal`: review_terminal_state's lines, and its status as
    the exit code."""
    state = require_state_read(flow_state_file(root), env, TERMINAL_KEYS, 1)
    if args:
        die("usage: orch.sh review terminal")
    lines, status = review_terminal_state(root, state["iteration"],
                                          review_budget_fallback(state["budget"]), state)
    stdout_write("".join(line + "\n" for line in lines))
    return status


def _retire(args: List[str], root: str, git, env: Mapping[str, str], clock) -> None:
    """`review retire <n>`: review_retire's move, its folder printed."""
    require_state(flow_state_file(root), env)
    if len(args) != 1:
        die("usage: orch.sh review retire <n>")
    stdout_write(review_retire(root, args[0]) + "\n")


# --- the verbs other tickets port ---------------------------------------------
# Each checks its arguments as bash does, in bash's order; past them, a verb
# not ported yet dies with the unknown-op refusal, as an op review lacks.

FILE_USAGE = ("usage: orch.sh review file <%s> <title> --axis <%s> --finding-file <f>"
              " --severity-reason <r> --location <<file>:<line>> --why <reason>"
              " [--spec-question <q>]" % ("|".join(FILED_SEVERITIES), "|".join(FILED_AXES)))


def _unported(op: str) -> NoReturn:
    die("unknown review op: %s (want %s)" % (op, OPS))


def _file(args: List[str], root: str, git, env: Mapping[str, str], clock) -> None:
    require_state_read(flow_state_file(root), env, ["pr"], 1)
    if len(args) < 2:
        die(FILE_USAGE)
    _unported("file")


def _known_items(args: List[str], root: str, git, env: Mapping[str, str], clock) -> None:
    require_state(flow_state_file(root), env)
    if len(args) != 2:
        die("usage: orch.sh review known-items <path> <loop boundary>")
    _unported("known-items")


def _standards(args: List[str], root: str, git, env: Mapping[str, str], clock) -> None:
    if args:
        die("usage: orch.sh review standards")
    _unported("standards")


def _ci(args: List[str], root: str, git, env: Mapping[str, str], clock) -> None:
    given = [arg for arg in args if arg != "--no-wait"]
    if len(given) > 1:
        die("usage: orch.sh review ci [--no-wait] [<pr>]", 2)
    _unported("ci")


def _ci_log(args: List[str], root: str, git, env: Mapping[str, str], clock) -> None:
    if len(args) != 1:
        die("usage: orch.sh review ci-log <pr>")
    _unported("ci-log")


def _rerun(args: List[str], root: str, git, env: Mapping[str, str], clock) -> None:
    if len(args) != 1:
        die("usage: orch.sh review rerun <pr>", 2)
    _unported("rerun")


def _ready(args: List[str], root: str, git, env: Mapping[str, str], clock) -> None:
    _unported("ready")


_VERBS: Dict[str, Callable[..., Optional[int]]] = {
    "begin": _begin,
    "path": _path,
    "file": _file,
    "known-items": _known_items,
    "standards": _standards,
    "ci": _ci,
    "ci-log": _ci_log,
    "rerun": _rerun,
    "ready": _ready,
    "terminal": _terminal,
    "resume": _resume,
    "retire": _retire,
}
