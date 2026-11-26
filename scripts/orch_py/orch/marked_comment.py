"""The Marked comment module (scripts/orch/marked-comment.sh), kept to what
the issue, review-pass and spec-review nouns and the handoff module's
comment retire use: the first line a marked comment opens with
(marked_comment_write, every kind as bash's - the spec review's changelog
heading, and the retired handoff marker a redo posts);
recognising the spec review's changelogs, comments whose first line is the
`## Spec review` heading, to drop them; the texts of the spec rulings, comments whose first
line begins `Spec ruling:`, that a review pass reads; and every comment's
kind, argument and retired tag (marked_comment_info, the jq prelude's), which
the issue timeline reads the handoff comments by.

No other marked kind can open with the heading or with `Spec ruling:`, so
recognising the opening alone is enough there.
"""
from __future__ import annotations

import re
from typing import List, NamedTuple, Optional

from orch.common import die, without_cr

SPEC_REVIEW_OPENING = "## Spec review"
SPEC_RULING_OPENING = "Spec ruling:"
_SPEC_REVIEW_LINE = re.compile(re.escape(SPEC_REVIEW_OPENING) + r"[ \t]*")

# The kind registry, as bash's: the hidden-marker kinds, the one kind that can
# be retired, the one kind that takes a cause token after its argument and the
# causes, and the legacy openings of a refusal and a failure stop comment.
MARKED_COMMENT_KINDS = ("question", "limited", "reentry", "handoff", "refusal", "failure")
MARKED_COMMENT_RETIRABLE = "handoff"
MARKED_COMMENT_CAUSED = "limited"
MARKED_COMMENT_CAUSES = ("github",)
LEGACY_REFUSAL = "Autopilot refused to run the "
LEGACY_FAILURE = "Autopilot failed in the "
_MARKER = re.compile(
    r"<!-- orch:(?P<kind>%s) (?P<arg>[^ ]+)(?: (?P<cause>%s))?(?P<retired> retired)? -->"
    % ("|".join(MARKED_COMMENT_KINDS), "|".join(MARKED_COMMENT_CAUSES)))
_LEGACY = re.compile(r"(?P<p>[^ ]+) phase")
# What bash's [[:space:]] matches.
_WHITESPACE = re.compile(r"[ \t\n\v\f\r]")


class MarkedInfo(NamedTuple):
    """A comment's kind and argument (None for an unmarked comment, or a
    kind that takes none), whether it is tagged retired, and its cause."""

    kind: Optional[str]
    arg: Optional[str]
    retired: bool
    cause: str


class NotText(ValueError):
    """A comment body that is neither text nor absent."""


def marked_comment_write(kind: str, arg: Optional[str] = None, tag: str = "") -> str:
    """The first line a marked comment of <kind> opens with, newline
    included, as bash's marked_comment_write prints it: the spec-review and
    spec-ruling kinds' openings, which take no <arg>, and every other
    registered kind's hidden marker, naming <arg> - which must hold no
    whitespace - and <tag>: `retired` on a handoff, or a cause on the caused
    kind. Dies, as bash's does, on an unknown kind or tag and on an argument
    or tag the kind does not take."""
    if kind in ("spec-review", "spec-ruling"):
        if arg is not None:
            die("marked comment: %s takes no argument" % kind)
        return (SPEC_REVIEW_OPENING if kind == "spec-review" else SPEC_RULING_OPENING) + "\n"
    if kind not in MARKED_COMMENT_KINDS:
        die("marked comment: unknown kind: %s" % kind)
    if not arg or _WHITESPACE.search(arg):
        die("marked comment: %s needs an argument without whitespace" % kind)
    if tag == "retired" and kind != MARKED_COMMENT_RETIRABLE:
        die("marked comment: only a handoff can be retired")
    if tag in MARKED_COMMENT_CAUSES and kind != MARKED_COMMENT_CAUSED:
        die("marked comment: only a %s comment takes a cause" % MARKED_COMMENT_CAUSED)
    if tag and tag != "retired" and tag not in MARKED_COMMENT_CAUSES:
        die("marked comment: unknown tag: %s" % tag)
    return "<!-- orch:%s %s%s -->\n" % (kind, arg, " " + tag if tag else "")


def is_spec_review(comment: dict) -> bool:
    """Whether the comment's first line, less a trailing CR, is the spec
    review's heading, trailing blanks allowed. NotText for a body that is
    no string."""
    body = comment.get("body")
    if body is None:
        body = ""
    if not isinstance(body, str):
        raise NotText("a comment body is no text")
    first = without_cr(body.split("\n", 1)[0])
    return _SPEC_REVIEW_LINE.fullmatch(first) is not None


def drop_spec_reviews(comments: List[dict]) -> List[dict]:
    """<comments> without the spec review's changelogs, the rest
    unchanged."""
    return [c for c in comments if not is_spec_review(c)]


def _body_text(comment: dict) -> str:
    """The comment's body as jq's `.body // ""` reads it: null or false as
    "". NotText for any other body that is no string."""
    body = comment.get("body")
    if body is None or body is False:
        return ""
    if not isinstance(body, str):
        raise NotText("a comment body is no text")
    return body


def marked_comment_texts(comments: List[dict]) -> List[str]:
    """For every spec ruling among <comments>, in order, its body with the
    `Spec ruling:` prefix alone removed and every CR removed - bash's
    `marked_comment_texts spec-ruling`, the one kind read so far. NotText for
    a body that is no text."""
    texts = []
    for comment in comments:
        body = _body_text(comment)
        if body.split("\n", 1)[0].startswith(SPEC_RULING_OPENING):
            texts.append(body[len(SPEC_RULING_OPENING):].replace("\r", ""))
    return texts


def marked_comment_info(comment: dict) -> MarkedInfo:
    """The comment's MarkedInfo, read from its first line less a trailing CR
    as the jq prelude's marked_comment_info reads it: a hidden marker of a
    registered kind, retired only on a handoff and with a cause only on a
    limited comment, else the spec review's heading, else a spec ruling's
    opening, else a legacy stop's opening. NotText for a body that is no
    text."""
    line = without_cr(_body_text(comment).split("\n", 1)[0])
    marker = _MARKER.fullmatch(line)
    if marker is not None:
        kind, cause = marker.group("kind"), marker.group("cause") or ""
        retired = marker.group("retired") is not None
        if (not retired or kind == MARKED_COMMENT_RETIRABLE) and \
                (not cause or kind == MARKED_COMMENT_CAUSED):
            return MarkedInfo(kind, marker.group("arg"), retired, cause)
    if _SPEC_REVIEW_LINE.fullmatch(line) is not None:
        return MarkedInfo("spec-review", None, False, "")
    if line.startswith(SPEC_RULING_OPENING):
        return MarkedInfo("spec-ruling", None, False, "")
    for kind, opening in (("refusal", LEGACY_REFUSAL), ("failure", LEGACY_FAILURE)):
        if line.startswith(opening):
            legacy = _LEGACY.match(line, len(opening))
            if legacy is not None:
                return MarkedInfo(kind, legacy.group("p"), False, "")
    return MarkedInfo(None, None, False, "")
