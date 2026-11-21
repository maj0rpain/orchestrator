"""The Comments module (scripts/orch/comments.sh), kept to what the issue
and finding-triage nouns use: the one reader of an issue's trusted comments,
in a dying form and one that hands its failure back, and the rendered shape
every comments read writes.

The adapter answers gh's raw comment objects; here they are normalised to
{author, createdAt, body, url}, the author its login, and the untrusted ones
dropped (orch.trust) before anything else reads them.
"""
from __future__ import annotations

import json
from typing import List, Optional, Tuple

from orch import trust
from orch.common import die
from orch.gh import GhFailed, Unparsed, gh_die, gh_reason

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


def trusted_read(gh, n: str) -> Tuple[Optional[List[dict]], str]:
    """Issue <n>'s trusted comments, each {author, createdAt, body, url}, <n>
    a plain number as given, and "" - never dying: on a gh failure None and
    gh's reason; on an answer that is no comment list None and ""."""
    try:
        raw = gh.issue_comments(int(n))
        comments = normalised(raw)
    except GhFailed as failed:
        return None, gh_reason(failed.stderr)
    except Unparsed:
        return None, ""
    kept = trust.filter_comments(n, comments)
    for comment in kept:
        del comment["authorAssociation"]
    return kept, ""


def trusted(gh, what: str, n: str, hint: str = "") -> List[dict]:
    """trusted_read's comments, dying where it fails: a gh failure as "gh
    could not <what>", then " - <hint>" when a hint is given; an answer that
    is no comment list as "could not <what>: its comments did not parse",
    never hinted."""
    kept, reason = trusted_read(gh, n)
    if kept is None:
        if reason:
            gh_die(what, reason, hint)
        die("could not %s: its comments did not parse" % what)
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
