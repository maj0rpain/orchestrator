"""The review concept's module (scripts/orch/review.sh), so far the review
loop's terminal-state read: an iteration's record path (review_record_path),
the record's Terminal state section (review_record_terminal), the record the
terminal state is read from, the flat one or, while a redo is half-finished,
its retired copy under pre-redo-<n>/ (review_terminal_record), whether the
flat record is gone (review_flat_record_gone), and the classification itself
(review_terminal_state), each as bash's, messages included. The bash copies
stay for `review terminal` and doctor; tests/test_review.py pins this
classification to bash's by the golden review records of
tests/review_terminal/, run through both.
"""
from __future__ import annotations

import os
from typing import List, Optional, Tuple

from orch.common import ORCH_DIR_NAME, capture, die, plain_number, read_raw, trim
from orch.flow_state import flow_state_file, flow_state_get_many
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
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError:
        die("cannot create the review directory %s" % directory)
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


def _test_int(text: str) -> Optional[int]:
    """<text> as bash's test reads an integer for -eq and -lt; None where
    test would refuse it."""
    try:
        return int(text.lstrip(" \t\n\v\f\r").rstrip(" \t"), 10)
    except ValueError:
        return None


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
    if _test_int(i) == 0:
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
        n, spent = _test_int(i), _test_int(budget)
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
