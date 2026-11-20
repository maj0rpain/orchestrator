"""The Comments module (scripts/orch/comments.sh), kept to what the issue
noun uses: the one reader of an issue's trusted comments and the rendered
shape every comments read writes.

The adapter answers gh's raw comment objects; here they are normalised to
{author, createdAt, body, url}, the author its login, and the untrusted ones
dropped (orch.trust) before anything else reads them.
"""
from __future__ import annotations

import json
from typing import List

from orch import trust
from orch.common import die
from orch.gh import Unparsed, gh_or_die

FIELDS = ("createdAt", "body", "url")


def normalised(comments: List[object]) -> List[dict]:
    """Each comment as {author, authorAssociation, createdAt, body, url},
    the author its login; a missing field is None. Unparsed when a comment,
    or its author, is no object."""
    out = []
    for comment in comments:
        if not isinstance(comment, dict):
            raise Unparsed("a comment is no object")
        author = comment.get("author")
        if author is not None and not isinstance(author, dict):
            raise Unparsed("a comment's author is no object")
        out.append({
            "author": None if author is None else author.get("login"),
            "authorAssociation": comment.get("authorAssociation"),
            **{field: comment.get(field) for field in FIELDS},
        })
    return out


def trusted(gh, what: str, n: int) -> List[dict]:
    """Issue #n's trusted comments, each {author, createdAt, body, url}. A
    gh failure dies as "gh could not <what>"; an answer that is no comment
    list as "could not <what>: its comments did not parse"."""
    try:
        comments = normalised(gh_or_die(what, gh.issue_comments, n))
    except Unparsed:
        die("could not %s: its comments did not parse" % what)
    kept = trust.filter_comments(n, comments)
    for comment in kept:
        del comment["authorAssociation"]
    return kept


def _interpolated(value: object) -> str:
    """<value> as jq's string interpolation writes it: a string as it is,
    anything else as its JSON."""
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def render(comments: List[dict]) -> str:
    """The rendered shape: each comment opened by a marker line naming its
    author and its timestamp, one blank line between comments, bodies as
    they are; "" for none."""
    return "\n\n".join(
        "<!-- comment @%s %s -->\n%s" % (
            _interpolated(c.get("author")), _interpolated(c.get("createdAt")),
            _interpolated(c.get("body")),
        )
        for c in comments
    )
