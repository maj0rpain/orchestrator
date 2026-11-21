"""The Marked comment module (scripts/orch/marked-comment.sh), kept to what
the issue noun uses: recognising the spec review's changelogs, comments whose
first line is the `## Spec review` heading, to drop them.

The other kinds - the hidden `<!-- orch:<kind> <arg> -->` markers and the
`Spec ruling:` line - come with the nouns that read them. No other marked
kind can open with the heading, so recognising the heading alone is enough.
"""
from __future__ import annotations

import re
from typing import List

SPEC_REVIEW_OPENING = "## Spec review"
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
