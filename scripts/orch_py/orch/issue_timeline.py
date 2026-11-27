"""The Issue timeline module (scripts/orch/issue-timeline.sh): one read of
an issue's trusted comments, each with its marked_comment_info, and the
queries answered from it with no gh call - the live handoff and the body a
comment holds, which the handoff module's comment adapter reads, and the
question, reply, stop, limit-stop and re-entry queries the Standing module
and the autopilot noun read.

A reply is any comment after the newest question comment but a re-entry
comment; a stop is a refusal or a failure comment, never a limit stop. Only
the read can fail: timeline_read hands the failure back, and timeline_die is
the one dying helper, as in bash.
"""
from __future__ import annotations

from typing import List, NamedTuple, Optional, Sequence, Tuple

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


def timeline_url(entries: List[Entry], index: int) -> str:
    """Comment <index>'s URL; "" where it has none."""
    return entries[index].comment.get("url") or ""


def _newest(entries: List[Entry], kinds: Sequence[str], phase: str = "") -> Optional[int]:
    """The index of the newest comment of one of <kinds>, of <phase> when
    one is given; None when there is none."""
    for index in range(len(entries) - 1, -1, -1):
        info = entries[index].info
        if info.kind in kinds and (not phase or info.arg == phase):
            return index
    return None


def timeline_question(entries: List[Entry], phase: str = "") -> Optional[int]:
    """The index of the newest question comment, of <phase> when one is
    given, else of any phase; None when there is none."""
    return _newest(entries, ("question",), phase)


def timeline_stop(entries: List[Entry]) -> Optional[int]:
    """The index of the latest stop - the newest refusal or failure
    comment; None when there is none."""
    return _newest(entries, ("refusal", "failure"))


def timeline_reply_indexes(entries: List[Entry], phase: str = "") -> Optional[List[int]]:
    """The one definition of a reply: the indexes of the comments after the
    newest question comment timeline_question finds but the re-entry
    comments, none when none follows; None when there is no question."""
    question = timeline_question(entries, phase)
    if question is None:
        return None
    return [index for index in range(question + 1, len(entries))
            if entries[index].info.kind != "reentry"]


def timeline_replied(entries: List[Entry], phase: str = "") -> bool:
    """Whether a reply follows the newest question comment
    timeline_question finds; False where there is no question."""
    return bool(timeline_reply_indexes(entries, phase))


def timeline_answers(entries: List[Entry], phase: str = "") -> Optional[str]:
    """The bodies of the replies to the newest question comment, each after
    a `---` line, exactly; "" when no reply follows, None when there is no
    question."""
    replies = timeline_reply_indexes(entries, phase)
    if replies is None:
        return None
    return "".join("\n---\n" + (entries[index].comment.get("body") or "") for index in replies)


def timeline_limit_count(entries: List[Entry], phase: str) -> int:
    """The number of <phase>'s limit stops in a row, counted newest first up
    to the first stop, question comment, handoff comment, or limit stop of
    another phase; other comments are skipped."""
    count = 0
    for entry in reversed(entries):
        kind = entry.info.kind
        if kind in ("refusal", "failure", "question", "handoff"):
            break
        if kind == "limited":
            if entry.info.arg != phase:
                break
            count += 1
    return count


def timeline_reentry_count(entries: List[Entry], phase: str) -> int:
    """The number of <phase>'s re-entry comments in a row, counted newest
    first up to the first question, refusal, failure or handoff comment, or
    unmarked comment (a reply); other marked comments are skipped."""
    count = 0
    for entry in reversed(entries):
        kind = entry.info.kind
        if kind in ("refusal", "failure", "question", "handoff", None):
            break
        if kind == "reentry" and entry.info.arg == phase:
            count += 1
    return count


def timeline_reentered(entries: List[Entry], phase: str) -> bool:
    """Whether a re-entry comment of <phase> is newer than <phase>'s newest
    question comment, or the issue has one and no question comment of
    <phase>."""
    question = timeline_question(entries, phase)
    after = -1 if question is None else question
    return any(entries[index].info.kind == "reentry" and entries[index].info.arg == phase
               for index in range(after + 1, len(entries)))


# What jq's sub("\\s+$"; "") strips from a body's end.
_TRAILING_SPACE = " \t\n\r\f\v"


def timeline_has_body(entries: List[Entry], text: str) -> bool:
    """Whether a comment's body is <text>, trailing whitespace aside."""
    want = text.rstrip(_TRAILING_SPACE)
    return any((entry.comment.get("body") or "").rstrip(_TRAILING_SPACE) == want
               for entry in entries)
