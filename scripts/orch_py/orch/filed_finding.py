"""The Filed finding module, as the bash side's filed-finding.sh holds it: an
issue a review loop filed carries a review:<severity> label until finding
triage gives it one of its own labels (ADR-0031). The issue and
finding-triage nouns read it - issue triage and finding triage: its filed
severities and their label test, its categories with each one's label, the
create that makes a missing label, and its issue body parsed back into its
fields. The bash side's copy serves
review file, audit file and audit report.
"""
from __future__ import annotations

import re
from typing import List, NamedTuple, Optional, Sequence

from orch.common import die
from orch.gh import GhFailed, label_listed
from orch.triage_labels import TriageLabels

# A review label: review: in any casing, followed by at least one character.
REVIEW_LABEL = re.compile(r"^review:.", re.IGNORECASE)

# The roles finding triage itself applies, so their labels show it ran.
FINDING_TRIAGE_ROLES = ("ready-for-agent", "ready-for-human", "wontfix")

# The severities a filed finding carries as review:<severity>, in the bash
# severity table's order. Blocking is always fixed in the loop, never filed.
FILED_SEVERITIES = ("major", "nit")

# The category table: each category a finding is filed under, with its
# label's colour and description - GitHub's own defaults - in the bash
# table's order.
FILED_CATEGORIES = (
    ("bug", "d73a4a", "Something isn't working"),
    ("enhancement", "a2eeef", "New feature or request"),
    ("documentation", "0075ca", "Improvements or additions to documentation"),
)

# The opposite category, the one a finding loses when triage settles on the
# other: bug and enhancement alone have one.
CATEGORY_OTHER = {"bug": "enhancement", "enhancement": "bug"}

# The whitespace bash's [:space:] trims, ASCII alone.
SPACE = " \t\n\v\f\r"
LOCATION = re.compile(r"`([^`:]+):([0-9]+(-[0-9]+)?)`")
AT_SHA = re.compile(r" at ([0-9a-fA-F]+)")
PR_URL = re.compile(r"/pull/([0-9]+)/*[ \t\n\v\f\r]*$")


class FindingBody(NamedTuple):
    """Every labelled field of a filed finding's body, each "" where its
    line is missing or does not parse: the axis lowercased, the severity and
    its reason, the Location's file, line (N or N-M) and SHA, the PR's URL
    and number, why it was not fixed in the loop, and the spec question."""

    axis: str
    severity: str
    reason: str
    file: str
    line: str
    sha: str
    pr: str
    pr_number: str
    why: str
    question: str


def review_labels(labels: Sequence[str]) -> List[str]:
    """Each of <labels> that marks a review finding, at any severity, in
    order."""
    return [label for label in labels if REVIEW_LABEL.match(label)]


def finding_untriaged(labels: Sequence[str], triage: TriageLabels) -> bool:
    """Whether the issue is a filed finding finding triage has not yet
    triaged: it carries a review label and none of the repo's labels for
    ready-for-agent, ready-for-human or wontfix."""
    if not review_labels(labels):
        return False
    return not any(label_listed(labels, triage.label(role)) for role in FINDING_TRIAGE_ROLES)


def has_filed_severity_label(labels: Sequence[str]) -> bool:
    """Whether some review label carries a filed severity, in any casing."""
    return any(label.lower()[len("review:"):] in FILED_SEVERITIES
               for label in review_labels(labels))


def filed_severity_label_or_die(n: str, labels: Sequence[str]) -> None:
    """Dies, naming issue #<n>, unless its <labels> carry a filed
    severity's review label: the check finding triage's scan and bundle
    make of an issue they take as a filed finding."""
    if not has_filed_severity_label(labels):
        die("issue #%s is not a filed finding - it carries no review:<severity> label"
            " for a filed severity (%s)"
            % (n, " or ".join("review:" + sev for sev in FILED_SEVERITIES)))


def category_other(category: str) -> Optional[str]:
    """The category a finding loses when triage settles on <category>; None
    for anything but bug or enhancement."""
    return CATEGORY_OTHER.get(category)


def label_ensure(gh, name: str, colour: str, description: str) -> None:
    """Creates label <name>, with <colour> and <description>, where the repo
    has none: the label is the repo's, so it is never rewritten, and a failed
    create - most often because the label exists - is forgiven; a label truly
    missing then fails the write that applies it."""
    try:
        gh.label_create(name, colour, description)
    except GhFailed:
        pass


def category_label_ensure(gh, category: str) -> bool:
    """Creates <category>'s label where the repo has none, with its colour
    and description, through label_ensure. False, creating nothing, for a
    category not in the table."""
    for name, colour, description in FILED_CATEGORIES:
        if name == category:
            label_ensure(gh, name, colour, description)
            return True
    return False


def _labelled(line: str, label: str) -> Optional[str]:
    """The rest of <line>, trimmed, when it starts with <label>; else None."""
    return line[len(label):].strip(SPACE) if line.startswith(label) else None


def finding_body_parse(body: str) -> FindingBody:
    """Every labelled line of a filed finding's body, each field from the
    first line that carries it: Location from the first line starting with
    its label, with no fallback when that one does not parse - its first
    backticked <file>:<line>, the file free of backticks and colons, and the
    hex run of the line's last " at <hex>"; PR from the first **PR:** line
    ending in a URL whose last segment after /pull/ is a number; the rest from
    the first line starting with their label, as the rest of it, trimmed.
    Severity splits at its first " - ". Never fails on a body."""
    found = dict.fromkeys(FindingBody._fields, "")
    seen = set()
    for line in body.split("\n"):
        for label, field in (("**Axis:**", "axis"), ("**Severity:**", "severity"),
                             ("**Location:**", "location"),
                             ("**Why not fixed in the loop:**", "why"),
                             ("**Spec question:**", "question")):
            value = _labelled(line, label)
            if value is None or field in seen:
                continue
            seen.add(field)
            if field == "axis":
                found["axis"] = value.lower()
            elif field == "severity":
                severity, dash, reason = value.partition(" - ")
                found["severity"] = severity.strip(SPACE) if dash else value
                found["reason"] = reason.strip(SPACE)
            elif field == "location":
                location = LOCATION.search(line)
                shas = AT_SHA.findall(line)
                if location and shas:
                    found["file"], found["line"], found["sha"] = (
                        location.group(1), location.group(2), shas[-1])
            else:
                found[field] = value
        pr = _labelled(line, "**PR:**")
        if "pr" not in seen and pr is not None:
            number = PR_URL.search(line)
            if number:
                seen.add("pr")
                found["pr"], found["pr_number"] = pr, number.group(1)
    return FindingBody(**found)
