"""The Comments module (scripts/orch/comments.sh), kept to what the issue,
finding-triage, review-pass and pr nouns, the issue timeline and the ticket
module's `ticket retire` (run by spec-review apply) use: the one
reader of an issue's or a PR's trusted comments, in a dying form and one that
hands its failure back, the rendered shape every comments read writes, the
rendered read, and the split of a rendered text into its comments.

The adapter answers gh's raw comment objects; here they are normalised to
{author, createdAt, body, url}, the author its login, and the untrusted ones
dropped (orch.trust) before anything else reads them.
"""
from __future__ import annotations

import json
import re
from typing import List, Optional, Tuple

from orch import trust
from orch.common import die, lines_of
from orch.gh import GhFailed, Unparsed, gh_die, gh_reason

FIELDS = ("createdAt", "body", "url")
# The kinds of thing a comment read reads the comments of.
KINDS = ("issue", "pr")
# The marker line opening each rendered comment, as split() recognises it.
_MARKER = re.compile(r"<!-- comment @[^ ]* [^ ]* -->")


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


def trusted_read(gh, n: str, kind: str = "issue") -> Tuple[Optional[List[dict]], str]:
    """Issue or PR <n>'s trusted comments, by <kind> (issue or pr), each
    {author, createdAt, body, url}, <n> a plain number as given, and "" -
    never dying: on a gh failure None and gh's reason; on an answer that is
    no comment list None and "". The trust filter's line names #<n>. Any
    other <kind> is a programming error, a ValueError."""
    if kind not in KINDS:
        raise ValueError("comments: unknown kind: %s (want issue|pr)" % kind)
    read = gh.issue_comments if kind == "issue" else gh.pr_comments
    try:
        raw = read(int(n))
        comments = normalised(raw)
    except GhFailed as failed:
        return None, gh_reason(failed.stderr)
    except Unparsed:
        return None, ""
    kept = trust.filter_comments(n, comments)
    for comment in kept:
        del comment["authorAssociation"]
    return kept, ""


def trusted(gh, what: str, n: str, hint: str = "", kind: str = "issue",
            code: int = 1) -> List[dict]:
    """trusted_read's comments, dying where it fails, exit <code>: a gh
    failure as "gh could not <what>", then " - <hint>" when a hint is given;
    an answer that is no comment list as "could not <what>: its comments did
    not parse", never hinted."""
    kept, reason = trusted_read(gh, n, kind)
    if kept is None:
        if reason:
            gh_die(what, reason, hint, code)
        die("could not %s: its comments did not parse" % what, code)
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


def rendered(gh, what: str, n: str, kind: str, code: int = 1) -> str:
    """trusted's comments rendered, as bash's comments_rendered assigned them:
    the trailing newlines dropped, as a `$(...)` capture drops them. Its
    failures are trusted's, exit <code>."""
    return render(trusted(gh, what, n, kind=kind, code=code)).rstrip("\n")


def split(text: str) -> List[str]:
    """<text>, comments in their rendered shape, split as the bash review
    pass split its file before the noun was converted: a comment opens at every line that is a
    comment marker, one quoted inside a body included, and holds the lines
    up to the next, each newline-terminated; lines before the first marker
    belong to none."""
    comments: List[List[str]] = []
    for line in lines_of(text):
        if _MARKER.fullmatch(line):
            comments.append([])
        elif comments:
            comments[-1].append(line)
    return ["".join(line + "\n" for line in comment) for comment in comments]
