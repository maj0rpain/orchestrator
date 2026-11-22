"""The Marked comment module (scripts/orch/marked-comment.sh), kept to what
the issue and review-pass nouns use: recognising the spec review's
changelogs, comments whose first line is the `## Spec review` heading, to
drop them; and the texts of the spec rulings, comments whose first line
begins `Spec ruling:`, that a review pass reads.

The other kinds - the hidden `<!-- orch:<kind> <arg> -->` markers - come with
the nouns that read them. No other marked kind can open with the heading or
with `Spec ruling:`, so recognising the opening alone is enough.
"""
from __future__ import annotations

import re
from typing import List

SPEC_REVIEW_OPENING = "## Spec review"
SPEC_RULING_OPENING = "Spec ruling:"
_SPEC_REVIEW_LINE = re.compile(re.escape(SPEC_REVIEW_OPENING) + r"[ \t]*")


class NotText(ValueError):
    """A comment body that is neither text nor absent."""


def is_spec_review(comment: dict) -> bool:
    """Whether the comment's first line, less a trailing CR, is the spec
    review's heading, trailing blanks allowed. NotText for a body that is
    no string."""
    body = comment.get("body")
    if body is None:
        body = ""
    if not isinstance(body, str):
        raise NotText("a comment body is no text")
    first = body.split("\n", 1)[0]
    if first.endswith("\r"):
        first = first[:-1]
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
