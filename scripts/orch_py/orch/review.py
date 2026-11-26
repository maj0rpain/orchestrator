"""The review concept's module (scripts/orch/review.sh), so far the review
loop's terminal-state read: an iteration's record path (review_record_path),
the record's Terminal state section (review_record_terminal), the record the
terminal state is read from, the flat one or, while a redo is half-finished,
its retired copy under pre-redo-<n>/ (review_terminal_record), whether the
flat record is gone (review_flat_record_gone), and the classification itself
(review_terminal_state), each as bash's, messages included; and `review
retire <n>`'s move of the iteration records aside into pre-redo-<n>/
(review_retire), which a redo review makes. The bash copies
stay for `review terminal` and doctor; tests/test_review.py pins this
classification to bash's by the golden review records of
tests/review_terminal/, run through both.

It also holds the CI gate `pr ready` runs before it marks a PR ready
(ci_ready_gate), with the helpers under it - which checks count
(ci_counted), one look at them (ci_counted_probe), its classification
(ci_classify) and the unreachable verdict (ci_unreachable) - each a copy of
bash's, messages included. The bash versions stay in review.sh for `review
ci`, the loop and doctor until the review noun converts (ADR-0067).
"""
from __future__ import annotations

import fnmatch
import os
from typing import List, Optional, Tuple

from orch.common import (ORCH_DIR_NAME, capture, die, int_as_test_reads, mkdir_p_or_die,
                         move_files_aside, plain_number, read_raw, trim, warn)
from orch.flow_state import flow_state_file, flow_state_get_many
from orch.gh import Check, GhFailed, gh_reason
from orch.handoff import section_body
from orch.redo import redo_midway

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


def review_terminal_record(root: str, i: str) -> str:
    """The path of the record iteration <i>'s terminal state is read from:
    the flat iteration-NN.md, or, when that is gone while a redo review is
    half-finished (redo_midway), the same record under
    review/pre-redo-<redo_count>/ if it is there. It reads state only on that
    fallback, issue, slug, branch and redo_count in one read, a failed one
    counting as no redo in progress. Dies as review_record_path does."""
    flat = review_record_path(root, i)
    if not os.path.exists(flat):
        state = flow_state_get_many(flow_state_file(root), ["issue", "slug", "branch", "redo_count"])
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
    if not plain_number(i) or int(i, 10) == 0:
        return False
    flat, _, died = capture(lambda: review_record_path(root, i))
    return not died and not os.path.exists(flat)


def review_terminal_state(root: str, i: str, budget: str) -> Tuple[List[str], int]:
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
    pre-redo-<redo_count>/ (review_terminal_record)."""
    if int_as_test_reads(i) == 0:
        return ["none"], 1
    path, err, died = capture(lambda: review_terminal_record(root, i))
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
