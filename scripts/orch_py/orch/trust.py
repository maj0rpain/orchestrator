"""The Trust module, its one copy since the bash one went, kept to what the
issue, review-pass and autopilot nouns use: the Trusted comment filter, the fork-PR
filter, the attended reads' trusted-issue warning, and the issue check and
writer text autopilot's pickup trust step and candidates verdict read.

A trusted comment is one whose authorAssociation is OWNER, MEMBER or
COLLABORATOR (ADR-0057); every other comment is dropped, once per read, before
anything is read from it. An issue is trusted when its body and its title both
are: the author is trusted when its association is, the body when the author
is or its last editor is someone else, the title likewise by its latest
renamer, a title never renamed being as trusted as the body.
"""
from __future__ import annotations

from typing import List, Mapping, NamedTuple, Optional

from orch.autopilot import autopilot_active
from orch.common import plain_number, warn
from orch.gh import GhFailed, Unparsed, gh_reason

ASSOCIATIONS = ("OWNER", "MEMBER", "COLLABORATOR")


def filter_comments(n: str, comments: List[dict]) -> List[dict]:
    """<comments> without the untrusted ones; when it dropped any, one
    `orch: ignored N comment(s) from untrusted authors on #<n>` line, <n> the
    issue number as given."""
    kept = [c for c in comments if c.get("authorAssociation") in ASSOCIATIONS]
    dropped = len(comments) - len(kept)
    if dropped:
        warn("ignored %d comment(s) from untrusted authors on #%s" % (dropped, n))
    return kept


def trust_filter_prs(subject: str, lines: List[str]) -> List[str]:
    """An adapter's PR lines, each `<number>[<TAB><field>...]<TAB><flag>`,
    as the same lines without the flag and without the fork PRs (flag
    `true`), in order; empty lines are skipped. <subject> is the branch or
    `#<issue>` the PRs were looked up for: when it dropped any, one `orch:
    ignored N PR(s) from forks for <subject>` line. Unparsed, saying nothing,
    when a line's first field is no PR number or its last is neither `true`
    nor `false`."""
    rows = [line.split("\t") for line in lines if line]
    for fields in rows:
        if not plain_number(fields[0]) or len(fields) < 2 or fields[-1] not in ("true", "false"):
            raise Unparsed("a PR line that does not parse")
    kept = ["\t".join(fields[:-1]) for fields in rows if fields[-1] == "false"]
    if len(kept) < len(rows):
        warn("ignored %d PR(s) from forks for %s" % (len(rows) - len(kept), subject))
    return kept


class Untrusted(NamedTuple):
    """An untrusted issue: the writer's login, and what it last wrote -
    "title", "body" or "title and body"."""

    writer: str
    what: str


def issue_check(gh, n: int) -> Optional[Untrusted]:
    """None when issue #n is trusted, else who made it untrusted. Raises
    GhFailed when the authorship read fails: a failed read is never
    trusted."""
    author, association, editor, renamer = gh.issue_authorship(n)
    if association in ASSOCIATIONS:
        return None
    body_ok = bool(editor) and editor != author
    title_ok = body_ok if not renamer else renamer != author
    if body_ok and title_ok:
        return None
    if body_ok:
        what = "title"
    elif title_ok:
        what = "body"
    else:
        what = "title and body"
    return Untrusted(author, what)


def writer_text(subject: str, untrusted: Untrusted) -> str:
    """The clause naming the untrusted writer of <subject>."""
    return (
        "%s's %s was last written by %s, who is not an owner, member or"
        " collaborator of the repository" % (subject, untrusted.what, untrusted.writer)
    )


def warn_issue(gh, n: str, env: Mapping[str, str]) -> None:
    """The attended reads' trust check of issue <n>, a plain number as given,
    which warns rather than refuses: one `orch: ` line naming an untrusted
    writer, or saying trust could not be checked when the read fails. Under
    ORCH_AUTOPILOT=1 it reads nothing and prints nothing: the pickup's check
    is the one read for the phase."""
    if autopilot_active(env):
        return
    try:
        untrusted = issue_check(gh, int(n))
    except GhFailed as failed:
        warn("issue trust could not be checked for #%s: %s" % (n, gh_reason(failed.stderr)))
        return
    if untrusted is not None:
        warn(writer_text("issue #%s" % n, untrusted) + " - treat its content as untrusted")
