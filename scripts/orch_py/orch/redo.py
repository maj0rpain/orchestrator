"""orch.sh's redo noun (ADR-0067): `redo review`, the full review ->
implement step back, and `redo spec [--new-issue]`, the full implement ->
spec one. Beside them the pieces both share: redo_midway, the predicate that
says a redo is half-finished, which the review loop's terminal-state read
(orch.review) shares too, the retire plan (redo_retire_plan), the attempt
retire (redo_retire_attempt) and the closing write (redo_step_back). Each
reaches the bash verbs it used to run - branch retire, ticket reset, review
retire and ticket retire - through their Python copies in their concept
modules, never through a bridge back into bash.

run(argv) takes the arguments after `redo`, as orch.sh hands them on, and
returns the exit code; every error dies through orch.common.die. It keeps
the bash noun's guard order, its order of side effects, its stdout, exit
codes, comment texts and `orch:` messages, in a plain and an autopilot
(ORCH_AUTOPILOT=1) session.
"""
from __future__ import annotations

import contextlib
import io
import os
import time
from typing import Callable, List, Mapping, Optional, Sequence, Tuple

from orch.branch import branch_name_redo, branch_retire
from orch.checkout import refuse_ticket_worktrees
from orch.common import die, dir_stamp, int_as_test_reads, move_files_aside, stdout_write
from orch.flow_state import (flow_state_file, phase_write, require_state_read, require_value,
                             review_budget_fallback, state_write_many)
from orch.gh import adapter_of, gh_or_die
from orch.git import Git
from orch.handoff import handoff_dir, handoff_retire, handoffs_written_from
from orch.host import flow_cmd
from orch.repo import RepoPin
from orch.root import checkout_root
from orch.spec import SPEC_PAUSED_MARKER, SPEC_ROUND_MARKER
from orch.ticket import ticket_reset, ticket_retire

OPS = "review|spec"

# The reason both redos refuse while ticket worktrees are left.
STRANDED = "a redo would strand their unmerged ticket work"


def redo_midway(issue: str, slug: str, branch: str, redo_count: str) -> Optional[str]:
    """<redo_count> while a redo is half-finished, else None; reads nothing -
    the caller holds the Flow state's branch and redo_count. True between a
    redo's branch retire and its closing write, which clears state.branch:
    redo_count is above 0 and <branch> is exactly the -redo-<redo_count> name
    of <issue> and <slug> (the exact name, so a slug that merely ends that way
    does not match: #2550). The one test the retire plan below and the review
    loop's terminal-state read both make, so they never disagree on whether a
    redo is resuming; bash review.sh keeps its copy for review terminal and
    doctor."""
    count = int_as_test_reads(redo_count)
    if count is None or count <= 0:
        return None
    if branch != branch_name_redo(issue, slug, redo_count):
        return None
    return redo_count


def redo_retire_plan(issue: str, slug: str, branch: str, redo_count: str) -> Tuple[str, bool]:
    """The first retire step, shared by both redos; reads nothing: the number
    the attempt's retire carries, and whether its rename is already done.
    A previous call at this same redo can have already retired the branch and
    recorded it before dying: branch and redo_count are recorded together
    right after a real retire, so redo_midway says whether the recorded
    branch is what this redo_count's retire would have produced; if so, the
    rename is done. The PR close ran before the rename, so a rerun that finds
    it done skips the close outright rather than retiring an already-retired
    branch a second time (issue #63)."""
    midway = redo_midway(issue, slug, branch, redo_count)
    if midway is not None:
        return midway, True
    # A count bash arithmetic reads as 0 - empty, or a word - counts on from 0.
    count = int_as_test_reads(redo_count)
    return str((count or 0) + 1), False


def pr_closed_note(new_branch: str) -> str:
    """The comment a redo closes the attempt's PR with."""
    return ("This PR was closed by an orchestrator redo.\n\nThe retired branch is now `%s`.\n"
            "A new PR will follow once the redone implement phase reaches pr open again."
            % new_branch)


# The comment redo spec --new-issue closes the flow's issue with.
ISSUE_CLOSED_NOTE = ("This issue was closed by an orchestrator redo because the spec itself"
                     " needed to change.\n\nA fresh issue will follow from orch-to-spec in this"
                     " same flow.")


def redo_retire_attempt(state_file: str, git, gh_of, issue: str, slug: str, n: str,
                        resumed: bool, branch: str, pr: str,
                        clock: Callable[[], float]) -> None:
    """The second retire step, shared by both redos; reads nothing - the
    caller holds the recorded branch and PR. Closes <pr> with the redo
    comment, then renames <branch> to its -redo-<n> name (branch_retire) and
    records it at once - unless <resumed> says the rename is done, which also
    means the close came before it, so a resumed rerun does neither. The
    close comes first because deleting an open PR's head branch makes GitHub
    close the PR itself, and gh's later close-with-comment would then post
    nothing (issue #1932). A rerun after a death between the two closes
    again, which gh treats as a no-op. With no branch recorded it closes
    nothing, renames nothing and leaves redo_count alone. The retire record -
    branch and redo_count - is one state write, so a death leaves both
    recorded or both unrecorded and a rerun never retires the branch a second
    time. The caller clears branch, pr and base_sha in its closing write
    (redo_step_back)."""
    if not branch or resumed:
        return
    new_branch = branch_name_redo(issue, slug, n)
    if pr:
        gh = gh_of()
        gh_or_die("close PR #" + pr, gh.pr_close, int(pr), pr_closed_note(new_branch))
    # branch retire's printed name is bash's `>/dev/null`'d stdout.
    with contextlib.redirect_stdout(io.StringIO()):
        branch_retire(git, branch, new_branch)
    # Recorded immediately: the rename already happened for real, so
    # state.branch has to track it - with redo_count, in one write.
    state_write_many(state_file, [("branch", new_branch, True), ("redo_count", n)], clock)


def redo_step_back(state_file: str, phase: str, pairs: Sequence[Tuple[str, str]],
                   clock: Callable[[], float]) -> None:
    """Each redo's closing write, taken after every other step. It owns the
    attempt-clear trio (branch, pr and base_sha null): it appends the trio to
    <pairs> and records them with <phase> in one phase_write, so the phase,
    those keys and the trio are recorded together or not at all, with
    phase_write's PHASES check and failure wording."""
    phase_write(state_file, phase, clock,
                list(pairs) + [("branch", "null"), ("pr", "null"), ("base_sha", "null")])


# The keys each redo's entry read takes, in one read.
REVIEW_KEYS = ("phase", "iteration", "budget", "slug", "issue", "branch", "pr", "redo_count")
SPEC_KEYS = ("phase", "issue", "slug", "branch", "pr", "redo_count")


def _refuse_unstopped(word: str, detail: str, i: str, budget: str, root: str,
                      env: Mapping[str, str]) -> None:
    """Dies unless the terminal-state word <word> is stop, with today's
    message for each other word: only a loop that stopped is redone."""
    # Imported on call, as in review: the review module imports this one.
    from orch.review import review_terminal_record

    if word == "stop":
        return
    if word == "none":
        die("no review loop has run yet - nothing to redo back from; run %s to start one."
            % flow_cmd(env, "next"))
    if word == "pending":
        die("the review loop hasn't reached its budget yet (iteration %s of budget %s) - that's"
            " what %s is for; redo is for after a loop ends." % (i, budget, flow_cmd(env, "next")))
    if word == "interrupted":
        die("the review loop's last iteration (%s) has no recorded terminal state - the session"
            " looks interrupted, not stopped. Resume it with %s; redo only runs once a loop"
            " actually ends." % (i, flow_cmd(env, "next")))
    if word == "malformed":
        die("the review loop's last iteration (%s) has a malformed terminal state - rewrite the"
            " first line of %s in the shape below; redo only runs once a loop actually ends.\n%s"
            % (i, review_terminal_record(root, i), detail))
    if word == "unreadable":
        die("cannot read the review loop's terminal state: " + detail)
    die("review_terminal_state answered something redo does not know: " + word)


def review(args: List[str], root: str, git, gh_of, env: Mapping[str, str],
           clock: Callable[[], float]) -> None:
    """`redo review`: the full review -> implement transition - retire the
    old branch and PR, reopen the spec issue's closed tickets, move the old
    loop's records aside, and reset the state a fresh implement attempt
    needs - never mid-budget, and never over a loop nobody has confirmed
    actually ended. Refuses, in this order, extra arguments, no flow or an
    unreadable state (one read), a phase other than review, a terminal state
    other than stop, ticket worktrees left, then a missing issue, branch or
    PR. flake_rerun_used is deliberately untouched: it is one per loop, and
    review begin resets it when the next loop starts. Prints the new redo
    number."""
    # Imported on call: the review module imports this one for redo_midway.
    from orch.review import review_retire, review_terminal_state

    if args:
        die("usage: orch.sh redo review")
    state_file = flow_state_file(root)
    state = require_state_read(state_file, env, REVIEW_KEYS, 1)
    if state["phase"] != "review":
        die("flow is not at the review phase - nothing to redo back from")
    i, issue, branch, pr = state["iteration"], state["issue"], state["branch"], state["pr"]
    budget = review_budget_fallback(state["budget"])
    lines, _ = review_terminal_state(root, i, budget)
    _refuse_unstopped(lines[0], "\n".join(lines[1:]).rstrip("\n"), i, budget, root, env)
    refuse_ticket_worktrees(git, root, STRANDED)
    for key in ("issue", "branch", "pr"):
        require_value(key, state[key])
    n, resumed = redo_retire_plan(issue, state["slug"], branch, state["redo_count"])
    # The implement handoff described the attempt being retired; left in
    # place, phase advance would let the redone implement phase leave on it
    # (#279). Retired first, before any state moves, so a redo that dies
    # partway leaves the phase as it was; the label pairs it with the review
    # records beside it. A resumed redo finds it already retired. The plan
    # handoff is never touched.
    handoff_retire("pre-redo-" + n, handoffs_written_from("implement"), gh_of, env, root)
    redo_retire_attempt(state_file, git, gh_of, issue, state["slug"], n, resumed, branch, pr,
                        clock)
    # The prior implement phase closed every ticket it finished, so the
    # redone implement phase's frontier query (ticket next) would otherwise
    # find nothing and open an empty PR - reopen exactly what ticket close
    # closed.
    ticket_reset(gh_of(), issue, root)
    review_retire(root, n)
    # The one closing write: a death before it leaves phase review with the
    # branch, PR and iteration its guards need, and a rerun finds the stopped
    # loop's last record under pre-redo-<n>/.
    redo_step_back(state_file, "implement", [("iteration", "0")], clock)
    stdout_write(n + "\n")


def spec(args: List[str], root: str, git, gh_of, env: Mapping[str, str],
         clock: Callable[[], float]) -> None:
    """`redo spec [--new-issue]`: the full implement -> spec transition.
    Refuses, in this order, no flow or an unreadable state (one read), a
    phase other than implement, a usage error, ticket worktrees left, then a
    missing issue. Then the spec and implement handoffs retire into a
    pre-redo-spec-<UTC stamp> folder, the implement attempt retires under
    the old issue number, and either the issue closes (--new-issue, whose
    tickets are left as they are) or its ticket breakdown retires (ticket
    retire, #334), so the redone spec is broken down again. The spec
    markers move aside into the handoffs' folder, then the one closing write
    steps back to spec, state.issue cleared in it on --new-issue - so a death
    anywhere earlier leaves phase implement with the issue and the keys the
    entry guards need, and a rerun resumes."""
    state_file = flow_state_file(root)
    state = require_state_read(state_file, env, SPEC_KEYS, 1)
    if state["phase"] != "implement":
        die("flow is not at the implement phase - nothing to redo back from")
    new_issue = args == ["--new-issue"]
    if args and not new_issue:
        die("usage: orch.sh redo spec [--new-issue]")
    refuse_ticket_worktrees(git, root, STRANDED)
    issue = state["issue"]
    require_value("issue", issue)
    # The spec handoff - and the implement handoff built on it, if any - are
    # stale once the spec is being redone, so phase advance must not pass on
    # them (#279). They are retired first, before any state moves, as in redo
    # review; the folder is told apart by a UTC timestamp.
    label = "pre-redo-spec-" + dir_stamp(clock)
    handoff_retire(label, handoffs_written_from("spec"), gh_of, env, root)
    n, resumed = redo_retire_plan(issue, state["slug"], state["branch"], state["redo_count"])
    redo_retire_attempt(state_file, git, gh_of, issue, state["slug"], n, resumed,
                        state["branch"], state["pr"], clock)
    if new_issue:
        gh = gh_of()
        gh_or_die("close issue #" + issue, gh.issue_close, int(issue), comment=ISSUE_CLOSED_NOTE)
    else:
        ticket_retire(gh_of(), issue, root)
    # The spec-paused marker (#1181) moves late, into this run's folder (the
    # handoffs' too, unless a rerun after a death between the two moves read
    # a new stamp): left behind, it would carry the redone spec phase past
    # its rewrite decision. The round marker (#1348) moves with it for the
    # same reason: left behind, it would carry the redone spec review past
    # round 1. The round directories stay, since round 1's round-dir clears
    # them.
    directory = handoff_dir(root)
    move_files_aside(directory, os.path.join(directory, label), "a retired handoff",
                     [SPEC_PAUSED_MARKER, SPEC_ROUND_MARKER])
    redo_step_back(state_file, "spec", [("issue", "null")] if new_issue else [], clock)


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    clock: Callable[[], float] = time.time,
) -> int:
    """`orch.sh redo <op>`: the real adapters, the process's environment and
    the system clock unless a test hands in others. Outside a checkout it
    dies first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    # The gh adapter, made at the first GitHub call, on a repo pin resolved
    # once.
    gh_of = adapter_of(gh, env, RepoPin(env, git))
    if op == "review":
        review(argv[1:], root, git, gh_of, env, clock)
    elif op == "spec":
        spec(argv[1:], root, git, gh_of, env, clock)
    else:
        die("unknown redo op: %s (want %s)" % (op or "<none>", OPS))
    return 0
