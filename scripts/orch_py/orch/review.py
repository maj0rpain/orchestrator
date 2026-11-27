"""orch.sh's review noun (ADR-0067), all twelve verbs: the verb dispatch,
with its unknown-op refusal and every usage line the bash noun had;
`review begin`, `path`, `terminal`, `resume` and `retire`, with the budget
fallback and its default of 5 (review_budget_fallback); `review file`, built
on orch/filed_finding.py; `review known-items`, built on
orch/known_items.py; `review standards`, with the Standards resolution
under it (standards_resolve_source); `review ci`; `review rerun` and
`review ci-log`, over the failing counted checks' Actions links; and
`review ready`, the CI gate, the PR marked ready, then orch/phase.py's
finish called in process.

`review ci [--no-wait] [<pr>]` waits on the flow's PR or the one given: the
grace counted from the push, read from the head's remote-tracking reflog
(ci_push_time, #475), skipped when the repo shows no evidence of CI
(no_ci_evidence, #476, ADR-0032); the required checks while the grace
remains, then the counted ones; the total stored from the first call
(orch/wait.py's StoredTotal, a provisional Guard before its key is known),
each call blocking at most ORCH_WAIT_BLOCK seconds and exiting 75 while the
wait is not over. `--no-wait` is one pass of it that writes nothing. The
rate limits it meets go through the gh adapter's Limits, handed the open
wait, or told the call never waits. ci_probe, one look over one scope, is
what doctor's CI check reads.

Doctor's three review checks each read their answer from one bridge here,
through orch_python_call: doctor_terminal, the terminal-state check's
classification; doctor_ci, the CI check's ci_probe over the required checks;
and doctor_standards, the Standards declaration check's resolution, exiting
3 on a rejected declaration. Each prints data, and doctor.sh prints its own
lines from it.

run(argv) takes the arguments after `review`, as orch.sh would hand them on,
and returns the exit code; every error dies through orch.common.die, with
bash's messages and in bash's order of guards and side effects, in a plain
and an autopilot session. Each verb reads its flow state once. orch.sh hands
every `review` verb here; the bash noun is gone, and nothing here calls back
into bash.

Under the verbs sits the review loop's terminal-state read: an iteration's
record path (review_record_path), the record's Terminal state section
(review_record_terminal), the record the terminal state is read from, the
flat one or, while a redo is half-finished, its retired copy under
pre-redo-<n>/ (review_terminal_record), whether the flat record is gone
(review_flat_record_gone), and the classification itself
(review_terminal_state), each as bash's, messages included; and `review
retire <n>`'s move of the iteration records aside into pre-redo-<n>/
(review_retire), which a redo review makes. tests/test_review.py pins this
classification by the golden review records of tests/review_terminal/, bash's
answers while the bash noun stood, and tests/test_review_noun.py reads them
through `review terminal`.

It also holds the CI gate `pr ready` and `review ready` run before they
mark a PR ready (ci_ready_gate), with the helpers under it - which checks count
(ci_counted), one look at them (ci_counted_probe), its classification
(ci_classify) and the unreachable verdict (ci_unreachable) - each as the
bash noun's were, messages included.
"""
from __future__ import annotations

import fnmatch
import glob
import os
import re
import time
from typing import Callable, Dict, List, Mapping, Optional, Tuple

from orch.common import (ORCH_DIR_NAME, capture, die, fenced, int_as_test_reads,
                         is_number, is_positive_int, lines_of, list_join, mkdir_p_or_die,
                         move_files_aside, plain_number, read_raw, require_poll_knobs,
                         rm_f_or_die, stdout_write, trim, warn)
from orch.branch import discard_own_branch_work
from orch.checkout import checkout_branch_or_rebasing, checkout_kind
from orch.filed_finding import (FILED_AXES, FILED_SEVERITIES, FindingBody, category_for_axis,
                                category_label_ensure, filed_severity_label,
                                finding_body_file_new, finding_body_parse, finding_body_render,
                                finding_flags_parse, finding_input_check, finding_location_check,
                                needs_triage_label_ready, severity_label_ensure)
from orch.flow_state import (Pair, flow_state_file, flow_state_get_many, recorded_pr,
                             require_state, require_state_read, require_value,
                             state_write_many)
from orch.gh import Check, GhFailed, adapter_of, gh_or_die, gh_reason
from orch.git import Git
from orch.handoff import handoff_file_for, handoff_read, section_body
from orch.host import flow_cmd
from orch.known_items import (entries_append_from, known_items_write, section_entries,
                              section_entries_append)
from orch.phase import finish
from orch.redo import redo_midway
from orch.repo import REPO_REMEDY, RepoPin
from orch.root import checkout_root
from orch.triage_labels import TriageLabels
from orch.wait import Guard, StoredTotal, still_running, wait_block

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
    as bash's review_terminal_state was, its bash copy gone: (its lines, its
    status). The first line is
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
# The buckets of a failed or cancelled check: what ci_classify calls failing,
# and what review rerun and review ci-log act on.
FAILING_BUCKETS = ("fail", "cancel")


def ci_unreachable(detail: str) -> List[str]:
    """The `unreachable` verdict and its indented detail line, the one
    spelling of both."""
    return ["unreachable", CI_DETAIL_INDENT + detail]


def ci_classify(checks: Optional[List[Check]], stderr: str) -> List[str]:
    """One read of a PR's checks classified, as bash's ci_classify was, its
    bash copy gone: the verdict, then any detail lines, indented. <checks> is None for a read
    that failed, with gh's <stderr>: unreachable, naming its reason. No
    checks is none; any failed or cancelled check with a name is failing,
    naming each; else any pending one is pending; else green."""
    if checks is None:
        return ci_unreachable(gh_reason(stderr))
    if not checks:
        return ["none"]
    failed = [c.name for c in checks if c.bucket in FAILING_BUCKETS and c.name]
    if failed:
        return ["failing"] + [CI_DETAIL_INDENT + name for name in failed]
    if any(c.bucket == "pending" for c in checks):
        return ["pending"]
    return ["green"]


def ci_read_classify(read: Callable[[], List[Check]]) -> List[str]:
    """One read of a PR's checks, <read>, made and classified (ci_classify):
    a read that raises GhFailed is unreachable, naming gh's reason. The one
    shape of ci_probe and ci_counted_probe, which differ only in the read
    they hand it."""
    try:
        checks = read()
    except GhFailed as failed:
        return ci_classify(None, failed.stderr)
    return ci_classify(checks, "")


def ci_counted(gh, pr: int) -> List[Check]:
    """The one owner of which checks count for a PR: the required checks
    where any are reported, else every check. A failed read raises GhFailed,
    so it stays apart from an empty answer. No grace: a caller that waits
    does so before calling it."""
    return gh.pr_checks(pr, "required") or gh.pr_checks(pr, "all")


def ci_counted_probe(gh, pr: int) -> List[str]:
    """ci_classify's classification of PR <pr>'s counted checks
    (ci_counted)."""
    return ci_read_classify(lambda: ci_counted(gh, pr))


def ci_ready_gate(gh, pr: int, code: int = 1, hint: str = "") -> None:
    """The check before PR <pr> is marked ready: one look, no grace and no
    polling, through ci_counted. It only refuses; `review ci` keeps the
    waiting. Failed and unreadable checks die, exit <code>, " - <hint>"
    appended where one is given; pending ones warn on stderr and return;
    green or none return silently."""
    verdict, *detail = ci_counted_probe(gh, pr)
    # The detail lines, unindented, comma-separated, empty ones skipped.
    checks = ", ".join(line.lstrip(" ") for line in detail if line.lstrip(" "))
    if verdict == "failing":
        message = "PR #%s has failed checks: %s" % (pr, checks)
    elif verdict == "unreachable":
        message = "PR #%s checks cannot be read: %s" % (pr, checks)
    else:
        if verdict == "pending":
            warn("PR #%s checks are still pending" % pr)
        return
    die(message + (" - " + hint if hint else ""), code)


# --- review ci -----------------------------------------------------------------

# How long `review ci` waits and how often it looks, read from the
# environment rather than from positional arguments, with their defaults: the
# 60-second grace is what stops a repo whose checks have not registered yet
# being declared CI-less, and a test that could not turn it down would take a
# minute to prove it works.
CI_GRACE = ("ORCH_CI_GRACE", "60")
CI_TIMEOUT = ("ORCH_CI_TIMEOUT", "900")
CI_INTERVAL = ("ORCH_CI_INTERVAL", "10")

CI_USAGE = "usage: orch.sh review ci [--no-wait] [<pr>]"
NO_CI_SIGNALS = ("no CI signals found: no workflow files in the head, no required checks on %s,"
                 " no checks or statuses on earlier PR commits or the %s tip")
# A workflow file, as the head's tree listing is matched line by line.
WORKFLOW_FILE = re.compile(r"\.ya?ml$")
FULL_SHA = re.compile(r"[0-9a-f]{40}")


def ci_knob(env: Mapping[str, str], knob: Tuple[str, str]) -> str:
    """<knob>'s value as <env> sets it, else its default: unset and empty
    alike."""
    name, default = knob
    return env.get(name, "") or default


def ci_probe(gh, pr: int, scope: str) -> List[str]:
    """One look at PR <pr>'s checks in <scope> - "required", else every
    check - classified (ci_classify): the verdict, then its detail lines.
    pr_checks answers none for a repo with no checks and fails for an API
    that would not answer or an answer it could not read, so the two
    meanings an empty read could carry stay apart. Doctor's CI check reads
    this, over the required scope."""
    return ci_read_classify(lambda: gh.pr_checks(pr, scope))


def ci_push_time(git, oid: str, branch: str) -> Optional[int]:
    """When the PR's head <oid> was pushed, in epoch seconds: the newest
    reflog entry of head branch <branch>'s remote-tracking ref whose new
    value is <oid>. None when there is no such entry - pushed from another
    machine, or a reflog that is not kept - and the grace then counts from
    the wait's first call."""
    if not oid or not branch:
        return None
    ref = "refs/remotes/origin/" + branch
    if not git.ref_exists(ref):
        return None
    return next((date for sha, date in git.reflog_dates(ref) or [] if sha == oid), None)


def no_ci_evidence(gh, git, head: str, base: str, pr: int) -> bool:
    """Whether the repo shows no evidence of CI, for review ci's grace
    (#476, ADR-0032): True only when all four signals read as absent -
    workflow files in the PR head's tree, read locally; required checks on
    the base branch, by classic protection or a ruleset; a check run or
    commit status on an earlier commit of the PR; and one on the base tip.
    False on the first signal present or unreadable: a false "has CI" costs
    a minute of grace, a false "no CI" marks a PR ready over checks nobody
    verified. Recomputed on every call, so a workflow the PR itself adds is
    always seen."""
    if not head or not base:
        return False
    # A head this clone has never fetched is unreadable, not empty.
    if not git.has_commit(head):
        return False
    names = git.tree_names(head, ".github/workflows/")
    if names is None or any(WORKFLOW_FILE.search(line)
                            for name in names for line in name.split("\n")):
        return False
    try:
        if gh.branch_required_checks(base):
            return False
        if "required_status_checks" in gh.branch_rules(base):
            return False
        # The base tip's answer, then each PR commit's, from one read. The
        # refs read's head is skipped by SHA, not by position: a push landing
        # between the two reads leaves a newer last commit, judged as an
        # earlier one.
        tip, commits = gh.pr_commits_checked(pr)
    except GhFailed:
        return False
    if tip != "no":
        return False
    for sha, answer in commits:
        if not FULL_SHA.fullmatch(sha) or answer not in ("yes", "no"):
            return False
        if sha != head and answer != "no":
            return False
    return True


class _CiCall:
    """One review ci call's PR and what it learnt of it: <pr>, the PR's
    number as given or recorded, <n>, that PR as gh calls take it
    (recorded_pr: a recorded PR that is no number goes to gh as it is),
    <given> whether it was given on the command line, and, once read, the
    PR's head SHA ("" when the read failed), head branch and base branch,
    how long before the wait's first call the head was pushed (push_age, 0
    when unknown) and whether the repo shows no evidence of CI anywhere
    (no_ci)."""

    def __init__(self, gh, git, pr: str, given: bool, grace: str) -> None:
        self.gh = gh
        self.git = git
        self.pr = pr
        self.n = recorded_pr(pr)
        self.given = given
        self.grace = grace
        self.head = self.head_ref = self.base = ""
        self.unread: Optional[str] = None
        self.push_age = 0
        self.no_ci = False

    def refs_read(self) -> None:
        """The PR's refs read; a failed read leaves the head "" and gh's
        stderr in <unread>, None after a read that worked."""
        try:
            self.head, self.head_ref, self.base = self.gh.pr_refs(self.n)
        except GhFailed as failed:
            self.head = ""
            self.unread = failed.stderr

    def refs_unread(self) -> bool:
        """Whether the call must stop because the PR it was given by number
        could not be read - printing `unreachable` and its detail line; the
        flow's PR, whose unread refs only key its total by PR, goes on."""
        if self.unread is None or not self.given:
            return False
        lines_print(ci_unreachable("could not read PR #%s: %s" % (self.pr, gh_reason(self.unread))))
        return True

    def context(self, start: int) -> None:
        """push_age from the head's push before <start>, the wait's first
        call, and no_ci. With no evidence of CI anywhere, there is nothing
        for the grace to wait on; it replaces only the wait - the unfiltered
        probe still runs, so a check already reported on the head gives its
        verdict as before."""
        if not self.head:
            return
        pushed = ci_push_time(self.git, self.head, self.head_ref)
        if pushed is not None and pushed < start:
            self.push_age = start - pushed
        self.no_ci = no_ci_evidence(self.gh, self.git, self.head, self.base, self.n)

    def probe(self, elapsed: float) -> Tuple[List[str], bool]:
        """One probe of the PR's checks: its lines, and whether it answered
        `none` from the required checks while the grace remains. Branch
        protection's required checks decide it wherever it names any: gh
        cannot tell "this repo requires nothing" from "what it requires has
        not registered yet", so the grace is spent waiting on the required
        set, and only once it is spent or skipped does the read widen to
        every check (ci_counted). Widening sooner is how an unrelated green
        check gets mistaken for a required one that never arrived."""
        if not self.no_ci and self.push_age + elapsed < float(self.grace):
            lines = ci_probe(self.gh, self.n, "required")
            return lines, lines[0] == "none"
        return ci_counted_probe(self.gh, self.n), False

    def deliver(self, lines: List[str]) -> Optional[int]:
        """Prints a terminal verdict's <lines> and returns its status; None,
        printing nothing, for `pending`."""
        verdict = lines[0]
        if verdict == "pending":
            return None
        if verdict == "none":
            # Only reachable with the grace spent or skipped: the detail line
            # says which, here rather than in ci_probe, so doctor's lines are
            # unchanged.
            if self.no_ci:
                detail = NO_CI_SIGNALS % (self.base, self.base)
            else:
                detail = "nothing reported before the %ss grace ran out" % self.grace
            lines_print(lines + [CI_DETAIL_INDENT + detail])
            return 0
        if verdict in ("green", "failing", "unreachable"):
            lines_print(lines)
            return 0 if verdict == "green" else 1
        # Unreachable while ci_classify answers one of the five words: the arm
        # that keeps an unrecognised answer from spinning the waiting form.
        lines_print(ci_unreachable("unrecognised answer from gh pr checks: " + verdict))
        return 1


def lines_print(lines: List[str]) -> None:
    """<lines> on stdout, each ended by a newline - a verdict's, a
    classification's, a log's tail."""
    stdout_write("".join(line + "\n" for line in lines))


def review_ci_once(call: _CiCall, clock: Callable[[], float]) -> int:
    """`review ci --no-wait`: one pass of the probe the waiting form
    repeats. It reads no total, never sleeps and writes no state, wait file
    or guard; where the loop would sleep it prints `pending`. A rate limit
    is given up on at once. The push age counts from this call's start."""
    call.gh.limits.no_wait = True
    start = int(clock())
    call.refs_read()
    if call.refs_unread():
        return 1
    call.context(start)
    lines, grace_none = call.probe(0)
    if grace_none:
        lines_print(["pending"])
        return 0
    status = call.deliver(lines)
    if status is None:
        lines_print(lines)
        status = 0
    return status


def review_ci_wait(call: _CiCall, root: str, env: Mapping[str, str],
                   clock: Callable[[], float], sleep: Callable[[float], None]) -> int:
    """`review ci`: polls until a verdict or ORCH_CI_TIMEOUT. Two clocks: the
    timeout counts from the wait's first call (the stored total), the grace
    from the push. The total belongs to the PR and its head commit, or to
    the PR alone when the head cannot be read, and is forgotten once a call
    delivers an outcome. Each call blocks at most ORCH_WAIT_BLOCK seconds,
    ending as still running (75) while the wait is not over. The refs read
    runs before the wait's key is known, so a provisional guard stands in
    for it: a limit the block cannot hold ends the call as still running
    with no total yet."""
    timeout, interval = ci_knob(env, CI_TIMEOUT), ci_knob(env, CI_INTERVAL)
    require_poll_knobs([(CI_GRACE[0], call.grace), (CI_TIMEOUT[0], timeout),
                        (CI_INTERVAL[0], interval)], 2)
    block = wait_block(env, 2)
    orch_dir = "%s/%s" % (root, ORCH_DIR_NAME)
    guard = Guard.open(orch_dir, call.pr, block, clock, sleep)
    call.gh.limits.wait = guard
    call.refs_read()
    if not guard.check():
        return still_running(block)
    if call.refs_unread():
        return 1
    total = StoredTotal.open(orch_dir, "review ci %s %s" % (call.pr, call.head), block, clock,
                             sleep, call_start=guard.call_start)
    call.gh.limits.wait = total
    elapsed = total.taken()
    call.context(int(total.start))
    if call.head and not total.limited_check():
        return still_running(block)
    while True:
        lines, grace_none = call.probe(elapsed)
        if not total.limited_check():
            return still_running(block)
        status = None if grace_none else call.deliver(lines)
        if status is None and (grace_none or elapsed < float(timeout)):
            if not total.tick(interval):
                return still_running(block)
            elapsed = total.taken()
            continue
        if status is None:
            # Still pending at the cap is an answer we do not have, not a
            # green one: the loop stops rather than marking a PR ready over
            # something nothing ever verified.
            lines_print(ci_unreachable("checks were still pending after %ss" % timeout))
            status = 1
        break
    # Every terminal verdict leaves the loop with its status, so the stored
    # total is forgotten in this one place.
    total.forget()
    return status


# --- the noun -----------------------------------------------------------------

# What a review budget reads as when nobody has set one - a flow started
# before the key existed, or a value nothing can count. The bound lives here
# rather than in the skill's prose: a session that has spent four iterations
# arguing with itself is exactly the one that would re-remember five as six.
# The number itself is the human's, read from state.
DEFAULT_BUDGET = "5"


def review_budget_fallback(raw: str) -> str:
    """The budget read from state, <raw>, or DEFAULT_BUDGET where it is
    empty or not a plain number - as bash's review_budget_fallback was, its
    bash copy gone; doctor.sh's d_budget_fallback is the one bash copy
    left."""
    return raw if plain_number(raw) else DEFAULT_BUDGET


# Every op of the review noun, as its unknown-op refusal names them.
OPS = "begin|path|file|known-items|standards|ci|ci-log|rerun|ready|terminal|resume|retire"


def run(argv: List[str], git=None, env: Optional[Mapping[str, str]] = None,
        clock: Callable[[], float] = time.time, gh=None,
        sleep: Callable[[float], None] = time.sleep) -> int:
    """`orch.sh review <op>`: the real git and gh adapters, the process's
    environment and the system clock and sleep unless a test hands in
    others; the exit code. Outside a checkout it dies first, as orch.sh
    does, whatever the op. The gh adapter is made at an op's first GitHub
    call (adapter_of), pinned to the repo of the checkout <git> runs in."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op, args = (argv[0], argv[1:]) if argv else ("", [])
    verb = _VERBS.get(op)
    if verb is None:
        die("unknown review op: %s (want %s)" % (op or "<none>", OPS))
    gh_of = adapter_of(gh, env, pin=RepoPin(env, git))
    return verb(args, root, git, env, clock, gh_of, sleep) or 0


def _begin(args: List[str], root: str, git, env: Mapping[str, str], clock,
           gh_of, sleep) -> None:
    """`review begin`: refuses past the budget, else records and prints the
    next iteration. A loop's first iteration - the recorded one 0, or one
    whose record has a Terminal state - renews the loop's flake rerun in the
    write that records it; resume never gets here. Its arguments are
    ignored, as bash's."""
    state_file = flow_state_file(root)
    state = require_state_read(state_file, env, ["iteration", "budget"], 1)
    prior = state["iteration"]
    n = _iteration_as_arithmetic_reads(prior) + 1
    budget = review_budget_fallback(state["budget"])
    if n > int(budget, 10):
        die("budget of %s iterations spent - stop the loop and report, do not start another"
            % budget)
    pairs: List[Pair] = [("iteration", str(n))]
    # test's reading, not arithmetic's: an empty iteration is no loop's first.
    if int_as_test_reads(prior) == 0 or _terminal_recorded(root, prior):
        pairs.append(("flake_rerun_used", "false"))
    state_write_many(state_file, pairs, clock)
    stdout_write("%d\n" % n)


# An iteration as bash's `$(( prior + 1 ))` read one that test could read too:
# any run of whitespace, a sign and ASCII digits, then any run of whitespace.
_ARITHMETIC_INTEGER = re.compile(r"[ \t\n]*([+-]?)([0-9]+)[ \t\n]*")


def _iteration_as_arithmetic_reads(prior: str) -> int:
    """The recorded iteration <prior> as `review begin`'s bash arithmetic read
    it: one of only whitespace as 0, a zero-led number as octal, any other
    number as decimal. A zero-led number that is no octal one dies as bash's
    arithmetic did, exit 1; anything else dies as no iteration number, exit
    1 where bash's arithmetic died on it too (a word on an unbound
    variable)."""
    if not prior.strip(" \t\n"):
        return 0
    match = _ARITHMETIC_INTEGER.fullmatch(prior)
    if match is None:
        die("not an iteration number: %s" % prior)
    sign, digits = match.groups()
    if digits.startswith("0") and len(digits) > 1:
        if not re.fullmatch(r"[0-7]+", digits):
            die('%s: value too great for base (error token is "%s")'
                % (prior.strip(" \t\n"), digits))
        value = int(digits, 8)
    else:
        value = int(digits, 10)
    return -value if sign == "-" else value


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


def _resume(args: List[str], root: str, git, env: Mapping[str, str], clock,
            gh_of, sleep) -> None:
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


def _path(args: List[str], root: str, git, env: Mapping[str, str], clock,
          gh_of, sleep) -> None:
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


def _terminal(args: List[str], root: str, git, env: Mapping[str, str], clock,
              gh_of, sleep) -> int:
    """`review terminal`: review_terminal_state's lines, and its status as
    the exit code."""
    state = require_state_read(flow_state_file(root), env, TERMINAL_KEYS, 1)
    if args:
        die("usage: orch.sh review terminal")
    lines, status = review_terminal_state(root, state["iteration"],
                                          review_budget_fallback(state["budget"]), state)
    lines_print(lines)
    return status


def _retire(args: List[str], root: str, git, env: Mapping[str, str], clock,
            gh_of, sleep) -> None:
    """`review retire <n>`: review_retire's move, its folder printed."""
    require_state(flow_state_file(root), env)
    if len(args) != 1:
        die("usage: orch.sh review retire <n>")
    stdout_write(review_retire(root, args[0]) + "\n")


# --- doctor's bridges ----------------------------------------------------------
# One orch_python_call each, from doctor.sh's review-phase terminal-state and CI
# checks and its env scope's Standards declaration check: each prints the data
# the check reads, and doctor prints its own lines from it.

def doctor_terminal(args: List[str], git=None, env: Optional[Mapping[str, str]] = None) -> None:
    """Bridge for doctor's terminal-state check: `doctor_terminal
    <iteration> <budget>`, the two values doctor already read. Prints
    review_terminal_state's lines - the classification word, then its detail
    - and, for malformed, the path of the record the remedy names, last;
    exit 0 whatever the classification. Flow state is read once, and only
    when the flat record is gone, for the retired record of a half-finished
    redo. The real git adapter and the process's environment unless a test
    hands in others."""
    if len(args) != 2:
        die("usage: orch_python_call review doctor_terminal <iteration> <budget>")
    git = Git() if git is None else git
    root = checkout_root(git, os.environ if env is None else env)
    i, budget = args
    state = None
    if review_flat_record_gone(root, i):
        # A failed read counts as no redo in progress, and is not made again.
        state = flow_state_get_many(flow_state_file(root), FALLBACK_KEYS) or {}
    lines, _ = review_terminal_state(root, i, budget, state)
    if lines[0] == "malformed":
        lines.append(review_terminal_record(root, i, state))
    lines_print(lines)


def doctor_ci(args: List[str], gh=None, git=None, env: Optional[Mapping[str, str]] = None) -> None:
    """Bridge for doctor's CI check: `doctor_ci <pr>`. Prints ci_probe's
    verdict and detail lines over the PR's required checks. The real
    adapters and the process's environment unless a test hands in others."""
    if len(args) != 1:
        die("usage: orch_python_call review doctor_ci <pr>")
    env = os.environ if env is None else env
    git = Git() if git is None else git
    lines_print(ci_probe(adapter_of(gh, env, pin=RepoPin(env, git))(), args[0], "required"))


# The exit doctor_standards ends with on a rejected declaration, apart from
# every other failure of the call.
STANDARDS_REJECTED = 3


def doctor_standards(args: List[str], git=None,
                     env: Optional[Mapping[str, str]] = None) -> int:
    """Bridge for doctor's Standards declaration check: `doctor_standards`.
    Prints standards_resolve_source's lines - `declared <file>` or `crawled`,
    then the list - and exits 0. A declaration the resolution rejects leaves
    the declaring file and the entries up to the rejected one on stdout, its
    message on stderr, and exits STANDARDS_REJECTED. The real git adapter
    and the process's environment unless a test hands in others."""
    if args:
        die("usage: orch_python_call review doctor_standards")
    git = Git() if git is None else git
    root = checkout_root(git, os.environ if env is None else env)
    try:
        standards_resolve_source(root, lambda line: stdout_write(line + "\n"))
    except SystemExit:
        return STANDARDS_REJECTED
    return 0


def _ci(args: List[str], root: str, git, env: Mapping[str, str], clock,
        gh_of, sleep) -> int:
    """`review ci [--no-wait] [<pr>]`: the PR given, read with no flow
    state, or the flow's recorded PR; its stored total is the same wait
    store either way. Exit 0 for green or none, 1 for failing or
    unreachable, 75 while the wait is not over, and every refusal - usage,
    a PR that is no number, no flow or PR recorded, no repo, a bad knob -
    2."""
    nowait, pr_arg = False, None
    for arg in args:
        if arg == "--no-wait":
            nowait = True
            continue
        if pr_arg is not None:
            die(CI_USAGE, 2)
        pr_arg = arg
    if pr_arg is not None and not plain_number(pr_arg):
        die("not a PR number: %s" % pr_arg, 2)
    if pr_arg is not None:
        pr = pr_arg
    else:
        pr = require_state_read(flow_state_file(root), env, ["pr"], 2)["pr"]
        require_value("pr", pr, 2)
    gh = gh_of()
    if not gh.pin():
        die(REPO_REMEDY, 2)
    grace = ci_knob(env, CI_GRACE)
    call = _CiCall(gh, git, pr, pr_arg is not None, grace)
    if nowait:
        if not is_number(grace):
            die("%s is not a number: %s" % (CI_GRACE[0], grace), 2)
        return review_ci_once(call, clock)
    return review_ci_wait(call, root, env, clock, sleep)


# --- review file ----------------------------------------------------------------

FILE_USAGE = ("usage: orch.sh review file <%s> <title> --axis <%s> --finding-file <f>"
              " --severity-reason <r> --location <<file>:<line>> --why <reason>"
              " [--spec-question <q>]" % ("|".join(FILED_SEVERITIES), "|".join(FILED_AXES)))
# The flags review file takes, and the ones of them it requires.
FILE_FLAGS = ("--axis", "--finding-file", "--severity-reason", "--location", "--why",
              "--spec-question")
FILE_REQUIRED = FILE_FLAGS[:-1]
# A head SHA GitHub answers: hex, in either case.
HEX = re.compile(r"[0-9a-fA-F]+")


def _file(args: List[str], root: str, git, env: Mapping[str, str], clock,
          gh_of, sleep) -> None:
    """`review file <sev> <title> --axis <a> --finding-file <f>
    --severity-reason <r> --location <loc> --why <w> [--spec-question <q>]`:
    files a finding as a GitHub issue, its body rendered from its parts, and
    prints its number alone. Every check - the flags, the severity, the
    axis, the title, the finding file, the location, the flow's recorded PR
    and its head SHA read from GitHub, and the rendered body's round trip
    through the parser - comes before any label or issue write, so a
    malformed finding never reaches GitHub."""
    pr = require_state_read(flow_state_file(root), env, ["pr"], 1)["pr"]
    if len(args) < 2:
        die(FILE_USAGE)
    severity, title = args[0], args[1]
    given: Dict[str, str] = {}
    for flag, value in finding_flags_parse(FILE_USAGE, FILE_FLAGS, args[2:]):
        if flag in given:
            die(FILE_USAGE)
        given[flag] = value
    if any(flag not in given for flag in FILE_REQUIRED):
        die(FILE_USAGE)
    axis = given["--axis"].lower()
    finding, reason = given["--finding-file"], given["--severity-reason"]
    location, why = given["--location"], given["--why"]
    question = given.get("--spec-question", "")

    label = filed_severity_label(severity)
    if label is None:
        die("not a severity that gets filed: %s (want %s - blocking is always fixed, never filed)"
            % (severity, " or ".join(FILED_SEVERITIES)))
    # The category follows the axis; finding triage confirms or flips it later.
    category = category_for_axis(axis)
    if category is None:
        die("not a review axis: %s (want %s)" % (axis, " or ".join(FILED_AXES)))
    finding_input_check(title, finding)
    finding_location_check(location)
    # Split at the last colon: the line is the part after it, N or N-M.
    file, _, line = location.rpartition(":")
    # The PR's URL and remote head come from GitHub for the flow's recorded
    # PR, before any write: the URL is right on any host, and the remote head
    # is what finding triage scan fetches.
    require_value("pr", pr)
    gh = gh_of()
    url, sha = gh_or_die("read the URL and head of PR #%s, recorded in state" % pr,
                         gh.pr_url_head, recorded_pr(pr))
    if not HEX.fullmatch(sha):
        die("not a sha: %s (want a hex commit SHA)" % sha)

    # The PR's number is left out: the parser reads it off the URL.
    parts = FindingBody(axis, severity, reason, file, line, sha, url, "", why, question)
    body = finding_body_render(read_raw(finding) or "", parts)
    with finding_body_file_new(body) as body_file:
        got = finding_body_parse(body)._replace(pr_number="")
        for field, value, parsed in zip(FindingBody._fields, parts, got):
            if parsed != value:
                die("the rendered body does not parse back: %s (given '%s', parsed '%s')"
                    % (field, value, parsed))
        severity_label_ensure(gh, severity)
        triage = needs_triage_label_ready(gh, TriageLabels(lambda: root))
        category_label_ensure(gh, category)
        # The title carries no severity prefix: the label holds it, where
        # triage can change it, and the title reads as an issue.
        n = gh_or_die("create the issue", gh.issue_create, title, body_file,
                      ["review:" + severity, triage, category])
    # The number alone: the record cites a number, and the caller would
    # otherwise be parsing a URL out of prose every time.
    stdout_write("%d\n" % n)


# --- review known-items ----------------------------------------------------------

# A review record's own name: the reports and known-items files beside it
# carry a suffix after the number.
RECORD_NAME = re.compile(r"iteration-([0-9]+)\.md")
# A Filed entry's issue number, its leading #<n>.
FILED_NUMBER = re.compile(r"#[0-9]+")


def _known_items(args: List[str], root: str, git, env: Mapping[str, str], clock,
                 gh_of, sleep) -> None:
    """`review known-items <path> <loop boundary>`: writes the loop's
    known-items file to <path>, overwriting it - `## Deviations`, the
    implement handoff's Deviations, then `## Known items`: Waiting to be
    filed from each record numbered above the boundary, Filed from each at or
    below it, tagged with its #<n> where it leads with one, and the plan's
    Rejected alternatives. A heading with no entry reads None. Every refusal
    comes before the write, and the file is built aside and moved into
    place, so a refused run leaves <path> as it was. The handoffs are read
    through this session's adapter: comments in an autopilot flow."""
    require_state(flow_state_file(root), env)
    if len(args) != 2:
        die("usage: orch.sh review known-items <path> <loop boundary>")
    path, boundary = args
    if not plain_number(boundary):
        die("not a loop boundary: %s (want the iteration read before the loop's first)"
            % boundary)
    implement = read_raw(handoff_read(handoff_file_for("review"), "", gh_of, env, root)) or ""
    plan = read_raw(handoff_read(handoff_file_for("spec"), "", gh_of, env, root)) or ""

    deviations = section_entries_append(implement, "## Deviations")
    waiting = filed = ""
    directory = review_dir(root)
    names = os.listdir(directory) if os.path.isdir(directory) else []
    for name in sorted(names):
        match = RECORD_NAME.fullmatch(name)
        if not match:
            continue
        n = match.group(1)
        text = read_raw(os.path.join(directory, name)) or ""
        if int(n, 10) > int(boundary, 10):
            waiting += section_entries_append(text, "## Waiting to be filed",
                                              "waiting to be filed, iteration " + n)
            continue
        for entry in section_entries(text, "## Filed"):
            number = FILED_NUMBER.match(entry)
            filed += entries_append_from([entry], "filed " + number.group(0) if number
                                         else "filed")
    rejected = section_entries_append(plan, "## Rejected alternatives", "rejected alternative")
    known_items_write(path, deviations, waiting + filed + rejected)


# --- review standards (#1532) ----------------------------------------------------

# The whitespace awk's and bash's [[:space:]] match, ASCII alone.
SPACE = " \t\n\v\f\r"
# A URL's scheme, as bash's ^[A-Za-z][A-Za-z0-9+.-]*: reads one.
URL_SCHEME = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*:")
# A backticked span, or a Markdown link's target, as grep -oE finds them.
MENTION = re.compile(r"`[^`]+`|\]\([^)]+\)")
SPAN = re.compile(r"`[^`]+`")
# Where a link's target ends: its first whitespace, a title after it.
BLANK_RUN = re.compile("[%s]" % re.escape(SPACE))
# A heading's closing #s, after whitespace, then any trailing whitespace.
CLOSING_HASHES = re.compile(r"[%s]+#+[%s]*$" % (re.escape(SPACE), re.escape(SPACE)))
# The root files the resolution reads, the second pair only when the repo has
# neither of the first.
ROOT_FILES = (("CLAUDE.md", "AGENTS.md"), ("CODING_STANDARDS.md", "CONTRIBUTING.md"))


def _blank(line: str) -> bool:
    return not line.strip(SPACE)


def standards_is_heading(line: str) -> bool:
    """The one ATX heading rule: 1 to 6 #s, at most 3 spaces in, then a
    space, a tab or the line's end."""
    if not re.match(r" {0,3}#", line):
        return False
    h = line.lstrip(" ")
    hashes = len(h) - len(h.lstrip("#"))
    return hashes <= 6 and (len(h) == hashes or h[hashes] in " \t")


def standards_heading_text(line: str) -> str:
    """A heading's text: surrounding whitespace and closing #s trimmed."""
    h = line.lstrip(" ").lstrip("#")
    return CLOSING_HASHES.sub("", h, count=1).strip(SPACE)


def standards_paragraphs(root: str, relative: str) -> List[Tuple[bool, str]]:
    """The paragraphs of the repo file <relative>, each (fenced, its lines
    joined by spaces), none when it cannot be read. A paragraph ends at a
    blank line (inside a fence or out), an ATX heading outside a fence or a
    fence delimiter line; a heading is a paragraph of its own; lines inside
    a fence join into fenced paragraphs; delimiter lines are in no
    paragraph. Each line's one trailing CR is dropped."""
    text = read_raw(os.path.join(root, relative))
    found: List[Tuple[bool, str]] = []
    joined: List[str] = []
    kind = False

    def flush() -> None:
        if joined:
            found.append((kind, " ".join(joined)))
        del joined[:]

    rows = [line[:-1] if line.endswith("\r") else line for line in lines_of(text or "")]
    for line, fence in zip(rows, fenced(rows)):
        if fence == 2 or (fence == 1 and _blank(line)):
            flush()
        elif fence == 1:
            kind = True
            joined.append(line)
        elif standards_is_heading(line):
            flush()
            found.append((False, line))
        elif _blank(line):
            flush()
        else:
            kind = False
            joined.append(line)
    flush()
    return found


def standards_heading_count(root: str, relative: str, heading: str) -> int:
    """How many ATX headings of the repo file <relative> read exactly
    <heading>. Lines inside a fenced code block, blank ones and its
    delimiters too, are no headings."""
    rows = lines_of(read_raw(os.path.join(root, relative)) or "")
    return sum(1 for line, fence in zip(rows, fenced(rows))
               if not fence and standards_is_heading(line)
               and standards_heading_text(line) == heading)


def standards_resolve(base: str, target: str) -> Optional[str]:
    """The repo-relative path <target> names, taken against <base> (a
    repo-relative directory, "" for the repo root), its # fragment dropped;
    None for a URL, an absolute path, a path holding whitespace, one that
    leaves the repo, or one not ending in .md."""
    target = target.partition("#")[0]
    if not target or target.startswith("/") or any(c in SPACE for c in target):
        return None
    if URL_SCHEME.match(target) or not target.endswith(".md"):
        return None
    out: List[str] = []
    for seg in ("%s/%s" % (base, target)).split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if not out:
                return None
            out.pop()
        else:
            out.append(seg)
    return "/".join(out) or None


def standards_mentions(root: str, relative: str) -> List[str]:
    """The repo-relative .md paths the repo file <relative> mentions, in
    backticks (against the repo root) or as Markdown links (against its
    directory), in the order they appear. Backticks pair per paragraph, so a
    span may wrap a line break and a stray backtick never pairs across a
    blank line."""
    directory = relative.rpartition("/")[0]
    found = []
    for _, paragraph in standards_paragraphs(root, relative):
        for mention in MENTION.findall(paragraph):
            if mention.startswith("`"):
                path = standards_resolve("", mention[1:-1])
            else:
                link = BLANK_RUN.split(mention[2:-1], maxsplit=1)[0]
                link = link[1:] if link.startswith("<") else link
                link = link[:-1] if link.endswith(">") else link
                path = standards_resolve(directory, link)
            if path is not None:
                found.append(path)
    return found


def standards_inside(root: str, relative: str) -> bool:
    """Whether the repo path <relative> is an existing file that, every
    symlink followed, lies under the repo's physical root."""
    path = os.path.join(root, relative)
    if not os.path.isfile(path):
        return False
    return os.path.realpath(path).startswith(os.path.realpath(root) + "/")


def standards_declared(root: str, entry: str) -> None:
    """Dies unless the declared <entry> is a repo-relative path naming a
    regular file inside the repo, optionally with a #Heading naming one
    section that must match exactly once."""
    named = "Standards entry `%s`" % entry
    if entry.startswith("/"):
        die("%s is an absolute path (want a repo-relative path)" % named)
    if URL_SCHEME.match(entry):
        die("%s is a URL (want a repo-relative path)" % named)
    path, hashed, heading = entry.partition("#")
    depth = 0
    for seg in path.split("/"):
        if seg == "..":
            depth -= 1
            if depth < 0:
                die("%s leaves the repo (want a path inside it)" % named)
        elif seg not in ("", "."):
            depth += 1
    full = "%s/%s" % (root, path)
    if not os.path.exists(full):
        die("%s names a missing file" % named)
    if not os.path.isfile(full):
        die("%s is not a regular file" % named)
    if not standards_inside(root, path):
        die("%s leaves the repo (want a path inside it)" % named)
    if not hashed:
        return
    n = standards_heading_count(root, path, heading)
    if n < 1:
        die("%s names a missing heading" % named)
    if n != 1:
        die("%s names an ambiguous heading (matches %d times)" % (named, n))


def standards_resolve_source(root: str, emit: Callable[[str], None]) -> None:
    """The Standards resolution of the checkout at <root>, and the path it
    took, each line handed to <emit>: a declaration in the root files when
    one exists, else the crawl - CLAUDE.md and AGENTS.md, or with neither
    CODING_STANDARDS.md and CONTRIBUTING.md, then the .md paths they
    mention, then the ones those mention: two hops, never a third, each path
    listed once at its first place and only when it lies inside the repo.
    The first line is `declared <file>` or `crawled`, then the list, one
    path a line. A declaration the resolution rejects dies with its message,
    after emitting the first line and the entries up to the rejected one,
    last, for doctor to read as data."""
    listed: List[str] = []
    for names in ROOT_FILES:
        listed = [name for name in names if standards_inside(root, name)]
        if listed:
            break
    for name in listed:
        declaration = next((text for fence, text in standards_paragraphs(root, name)
                            if not fence and text.startswith("Standards:")), None)
        if declaration is None:
            continue
        emit("declared " + name)
        entries = [span[1:-1] for span in SPAN.findall(declaration)]
        if not entries:
            die("%s declares Standards: with no entries (want backticked paths)" % name)
        for entry in entries:
            emit(entry)
            standards_declared(root, entry)
        return
    hop = list(listed)
    for _ in range(2):
        found: List[str] = []
        for name in hop:
            for path in standards_mentions(root, name):
                if path not in listed and standards_inside(root, path):
                    listed.append(path)
                    found.append(path)
        hop = found
    emit("crawled")
    for path in listed:
        emit(path)


def _standards(args: List[str], root: str, git, env: Mapping[str, str], clock,
               gh_of, sleep) -> None:
    """`review standards`: the one Standards: line both reviewers' prompts
    end with, from the resolution's list - `Standards: none` when it is
    empty. A rejected declaration dies with its message and prints nothing
    on stdout."""
    if args:
        die("usage: orch.sh review standards")
    resolved: List[str] = []
    standards_resolve_source(root, resolved.append)
    listed = list_join(resolved[1:])
    stdout_write("Standards: %s\n" % (listed or "none"))


# --- review rerun and review ci-log ---------------------------------------------

# Where an Actions run's id starts in a check's link, and where a job's does.
RUNS_SEGMENT = "/actions/runs/"
JOB_SEGMENT = "/job/"
# A link to an Actions run: the segment, then a digit; and to one of its jobs.
RUN_LINK = re.compile(re.escape(RUNS_SEGMENT) + "[0-9]")
JOB_LINK = re.compile(re.escape(RUNS_SEGMENT) + "[0-9].*" + re.escape(JOB_SEGMENT) + "[0-9]")
JOB_ID = re.compile("[0-9]*")
# How many of a job log's last lines review ci-log prints.
LOG_TAIL = 200


def _ci_log(args: List[str], root: str, git, env: Mapping[str, str], clock,
            gh_of, sleep) -> None:
    """`review ci-log <pr>`: the failed-step log of each failing Actions job
    behind PR <pr>'s counted checks (ci_counted), for the driver to judge a
    failing CI, everything on stdout. A job's log is cut to its last
    LOG_TAIL lines, a line before it counting the lines cut. A failing check
    that is no Actions job gets a line saying so, and a job whose log cannot
    be read a line naming it, and the next job goes on. Every refusal and a
    GitHub that cannot be read die, exit 1. It reads no flow state."""
    if len(args) != 1:
        die("usage: orch.sh review ci-log <pr>")
    pr = args[0]
    if not plain_number(pr):
        die("not a PR number: %s" % pr)
    gh = gh_of()
    if not gh.pin():
        die(REPO_REMEDY)
    checks = gh_or_die("read the checks of PR #%s" % pr, ci_counted, gh, int(pr))
    for check in checks:
        if check.bucket not in FAILING_BUCKETS:
            continue
        if not JOB_LINK.search(check.link):
            stdout_write("check %s is not a GitHub Actions run - no log to read\n" % check.name)
            continue
        job = JOB_ID.match(check.link.rpartition(JOB_SEGMENT)[2]).group(0)
        try:
            log = gh.job_failed_log(job)
        except GhFailed as failed:
            stdout_write("check %s: the log of job %s could not be read: %s\n"
                         % (check.name, job, gh_reason(failed.stderr)))
            continue
        # Read as bash's capture reads it, its trailing newlines dropped, then
        # printed a line at a time: an empty log is one empty line.
        rows = log.rstrip("\n").split("\n")
        stdout_write("check %s: failed-step log of job %s\n" % (check.name, job))
        if len(rows) > LOG_TAIL:
            stdout_write("[cut: %d earlier lines of %d]\n" % (len(rows) - LOG_TAIL, len(rows)))
        lines_print(rows[-LOG_TAIL:])


def _rerun(args: List[str], root: str, git, env: Mapping[str, str], clock,
           gh_of, sleep) -> Optional[int]:
    """`review rerun <pr>`, the loop's flake rerun (#525): the failed jobs of
    every distinct Actions run behind PR <pr>'s failing counted checks
    (ci_counted), every failed or cancelled one, a run's id the `runs/<id>`
    segment of a check's link. Every failing check's link is verified before
    any rerun starts; each run is rerun once, in the order first met, its id
    printed as its rerun starts. Exit 0 means every rerun started, the only
    answer that spends the loop's rerun; 1 that a failing check is no
    Actions run, so nothing is rerun; everything else - a usage error, no
    repo, a GitHub that cannot be read, no failing check, a refused rerun -
    exits 2. It reads no flow state."""
    if len(args) != 1:
        die("usage: orch.sh review rerun <pr>", 2)
    pr = args[0]
    if not plain_number(pr):
        die("not a PR number: %s" % pr, 2)
    gh = gh_of()
    # Resolved here, not left to the adapter, whose death exits 1 and would
    # read as "nothing to rerun".
    if not gh.pin():
        die(REPO_REMEDY, 2)
    checks = gh_or_die("read the checks of PR #%s" % pr, ci_counted, gh, int(pr), code=2)
    if not checks:
        # gh's "no checks" answer, not a failure reason, so not gh_reason's
        # to cut.
        reported = checks.reported.split("\n", 1)[0]
        die("PR #%s has no checks to rerun: %s" % (pr, reported or "no checks reported"), 2)
    runs: List[str] = []
    failing = unrerunnable = False
    for check in checks:
        if check.bucket not in FAILING_BUCKETS:
            continue
        failing = True
        if not RUN_LINK.search(check.link):
            warn("check %s on PR #%s is not a GitHub Actions run - nothing to rerun"
                 % (check.name, pr))
            unrerunnable = True
            continue
        run_id = check.link.rpartition(RUNS_SEGMENT)[2].partition("/")[0]
        if not plain_number(run_id):
            warn("check %s on PR #%s links no Actions run id - nothing to rerun"
                 % (check.name, pr))
            unrerunnable = True
            continue
        if run_id not in runs:
            runs.append(run_id)
    if not failing:
        die("PR #%s has no failed or cancelled check to rerun" % pr, 2)
    if unrerunnable:
        return 1
    for run_id in runs:
        gh_or_die("rerun the failed jobs of Actions run %s" % run_id, gh.run_rerun, int(run_id),
                  code=2)
        stdout_write(run_id + "\n")
    return None


# --- review ready ---------------------------------------------------------------

# What every refusal of review ready ends with: nothing has moved on.
READY_HINT = "the flow stays in review"


def _ready(args: List[str], root: str, git, env: Mapping[str, str], clock,
           gh_of, sleep) -> None:
    """`review ready`: the review loop's Termination. The CI gate first
    (ci_ready_gate), then the flow's PR marked ready and the flow finished
    as done - GitHub first, state second: recording `done` over a PR still
    in draft would claim a success nobody can see, and leave the flow no
    phase to retry it from. The finish is orch/phase.py's, in process; a
    failure there dies as it does, the PR left ready and the phase review,
    so a re-run finishes the flow. stdout is the PR number alone; in a side
    checkout, which outlives its PR, stderr points at the finish command
    that clears it once the PR merges. Its arguments are ignored, as
    bash's."""
    state_file = flow_state_file(root)
    state = require_state_read(state_file, env, ["pr", "issue"], 1)
    pr = state["pr"]
    require_value("pr", pr)
    n = recorded_pr(pr)
    gh = gh_of()
    ci_ready_gate(gh, n, hint=READY_HINT)
    gh_or_die("mark PR #%s ready" % pr, gh.pr_ready, n, hint=READY_HINT)
    finish("done", "marked PR #%s ready" % pr, state["issue"], state_file, gh_of, env, clock)
    stdout_write(pr + "\n")
    if checkout_kind(git, root) == "side":
        warn("this is a side checkout - once PR #%s merges, run %s to archive its flow and"
             " remove it" % (pr, flow_cmd(env, "finish")))


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
