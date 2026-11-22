"""The Issue timeline module (scripts/orch/issue-timeline.sh), kept to what
the handoff module's comment adapter reads: one read of an issue's trusted
comments, each with its marked_comment_info, and the live handoff and the
body a handoff comment holds.

Only the read can fail: timeline_read hands the failure back, and
timeline_die is the one dying helper, as in bash.
"""
from __future__ import annotations

from typing import List, NamedTuple, Optional, Tuple

from orch import comments
from orch.common import die
from orch.gh import gh_die
from orch.marked_comment import MarkedInfo, NotText, marked_comment_info


class Entry(NamedTuple):
    """One comment of the last read and its marked_comment_info."""

    comment: dict
    info: MarkedInfo


def timeline_read(gh, issue: str) -> Tuple[Optional[List[Entry]], str]:
    """Issue <issue>'s trusted comments, each with its info, in order, and
    "" - never dying: None and gh's reason when gh fails, None and "" when
    its answer is not a comment list."""
    kept, reason = comments.trusted_read(gh, issue)
    if kept is None:
        return None, reason
    try:
        return [Entry(comment, marked_comment_info(comment)) for comment in kept], ""
    except NotText:
        return None, ""


def timeline_die(issue: str, reason: str) -> None:
    """Dies for the timeline read that just failed, with gh's <reason>, or
    with `could not read issue #<n>'s comments` when gh succeeded but its
    answer was not a comment list."""
    if not reason:
        die("could not read issue #%s's comments" % issue)
    gh_die("read the comments of issue #" + issue, reason)


def timeline_handoff(entries: List[Entry], name: str) -> Optional[int]:
    """The index of the live handoff of <name> - its newest comment, when it
    is not retired; None when there is none or the newest is retired."""
    for index in range(len(entries) - 1, -1, -1):
        info = entries[index].info
        if info.kind == "handoff" and info.arg == name:
            return None if info.retired else index
    return None


def timeline_body(entries: List[Entry], index: int) -> str:
    """The body of comment <index> with its first line stripped, exactly;
    "" for a body of one line or none."""
    body = entries[index].comment.get("body") or ""
    return body.split("\n", 1)[1] if "\n" in body else ""
