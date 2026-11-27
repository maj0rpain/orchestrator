"""The Filed finding module: an issue a review loop filed carries a
review:<severity> label until finding triage gives it one of its own labels
(ADR-0031). The issue and finding-triage nouns read it - issue triage and
finding triage: its filed severities and their label test, its categories with
each one's label, the create that makes a missing label, and its issue body
parsed back into its fields. It also holds the filing checks audit file and
review file make: the flag parse, the input and location checks, the
needs-triage label made ready, and the body temp file; and what review file
alone needs - each severity's label and its upsert, the category a review axis
starts in, and the body rendered from its parts, and the untriaged finding
check autopilot's candidates verdict and issue triage make. It is the one
copy: the bash filed-finding.sh went with the bash autopilot noun.
"""
from __future__ import annotations

import os
import re
from contextlib import contextmanager
from typing import Iterator, List, NamedTuple, Optional, Sequence, Tuple

from orch.common import die, read_raw, temp_text_file, text_file_write
from orch.gh import GhFailed, gh_or_die, label_listed
from orch.triage_labels import TriageLabels

# A review label: review: in any casing, followed by at least one character.
REVIEW_LABEL = re.compile(r"^review:.", re.IGNORECASE)

# The roles finding triage itself applies, so their labels show it ran.
FINDING_TRIAGE_ROLES = ("ready-for-agent", "ready-for-human", "wontfix")

# The severity table: each severity a filed finding carries as
# review:<severity> - the ones `review file` files - with its label's colour,
# in order. Blocking is always fixed in the loop, never filed.
FILED_SEVERITY_TABLE = (("major", "d93f0b"), ("nit", "c5def5"))

# The filed severities alone, in the table's order.
FILED_SEVERITIES = tuple(severity for severity, _ in FILED_SEVERITY_TABLE)

# The axis table: each review axis a finding is filed on, with the category a
# finding filed on it starts in, in order. A Spec
# finding misses what was asked for, so it is a bug; a Standards finding
# improves how it was built.
FILED_AXIS_TABLE = (("spec", "bug"), ("standards", "enhancement"))

# The review axes alone, in the table's order.
FILED_AXES = tuple(axis for axis, _ in FILED_AXIS_TABLE)

# The category table: each category a finding is filed under, with its
# label's colour and description - GitHub's own defaults - in order.
FILED_CATEGORIES = (
    ("bug", "d73a4a", "Something isn't working"),
    ("enhancement", "a2eeef", "New feature or request"),
    ("documentation", "0075ca", "Improvements or additions to documentation"),
)

# The category table's names alone, in its order.
FILED_CATEGORY_NAMES = tuple(name for name, _, _ in FILED_CATEGORIES)

# The opposite category, the one a finding loses when triage settles on the
# other: bug and enhancement alone have one.
CATEGORY_OTHER = {"bug": "enhancement", "enhancement": "bug"}

# The whitespace bash's [:space:] trims, ASCII alone.
SPACE = " \t\n\v\f\r"
# SPACE as one regex character class.
SPACE_CLASS = "[%s]" % re.escape(SPACE)
LOCATION = re.compile(r"`([^`:]+):([0-9]+(-[0-9]+)?)`")
AT_SHA = re.compile(r" at ([0-9a-fA-F]+)")
PR_URL = re.compile(r"/pull/([0-9]+)/*" + SPACE_CLASS + r"*$")


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


def filed_severity_label(severity: str) -> Optional[Tuple[str, str]]:
    """The review:<severity> label's colour, from the severity table, and
    its description; None for a severity with no entry."""
    for name, colour in FILED_SEVERITY_TABLE:
        if name == severity:
            return colour, "Review finding filed at %s severity" % severity
    return None


def category_for_axis(axis: str) -> Optional[str]:
    """The category a finding filed on review axis <axis> starts in, from
    the axis table, whatever the axis's case; None for any other axis."""
    for name, category in FILED_AXIS_TABLE:
        if axis.lower() == name:
            return category
    return None


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


def severity_label_ensure(gh, severity: str) -> None:
    """Makes the filed severity <severity>'s review:<severity> label, with
    its colour and description, creating it or rewriting the one that
    exists: the label is this plugin's own, so overwriting it is safe, and
    filing needs no listing step. A failed write dies."""
    colour, description = filed_severity_label(severity) or ("", "")
    name = "review:" + severity
    gh_or_die("create label " + name, gh.label_upsert, name, colour, description)


def needs_triage_label_ready(gh, triage: TriageLabels) -> str:
    """The repo's needs-triage label, read through <triage>, made through
    label_ensure where it is missing, with the triage label's colour and
    description: the label is the repo's, so it is never rewritten."""
    label = triage.label("needs-triage")
    label_ensure(gh, label, "e4e669", "Not yet triaged")
    return label


# --- the filing checks ------------------------------------------------------

# A location's line part: <line> or <start>-<end>.
LOCATION_LINES = re.compile(r"[0-9]+(-[0-9]+)?")


def finding_flags_parse(usage: str, allowed: Sequence[str],
                        args: Sequence[str]) -> List[Tuple[str, str]]:
    """A finding filer's flag/value pairs, in the order given, each value
    trimmed. Dies with <usage> on a flag not in <allowed>, a flag with no
    value, or an empty value."""
    pairs = []
    for i in range(0, len(args), 2):
        if args[i] not in allowed or i + 1 >= len(args):
            die(usage)
        value = args[i + 1].strip(SPACE)
        if not value:
            die(usage)
        pairs.append((args[i], value))
    return pairs


def finding_input_check(title: str, finding_file: str) -> None:
    """Dies unless the title is not empty and the finding file exists and
    holds more than whitespace - the checks a finding's filer makes before it
    renders anything. An unreadable file holds nothing, as bash's `tr` over a
    failed redirect reads it, and a NUL is dropped, as bash's $(...) drops
    one."""
    if not title:
        die("the title is empty")
    if not os.path.isfile(finding_file):
        die("finding file not found: " + finding_file)
    text = read_raw(finding_file) or ""
    if not text.strip(SPACE + "\0"):
        die("finding file is empty: " + finding_file)


def finding_location_ok(location: str) -> bool:
    """Whether <location> is <file>:<line> or <file>:<start>-<end>, split at
    its last colon, the file part not empty."""
    file, colon, lines = location.rpartition(":")
    return bool(colon and file) and LOCATION_LINES.fullmatch(lines) is not None


def finding_location_check(location: str) -> None:
    """Dies unless <location> is <file>:<line> or <file>:<start>-<end>,
    naming both shapes in the refusal."""
    if not finding_location_ok(location):
        die("not a location: %s (want <file>:<line> or <file>:<start>-<end>)" % location)


# The refusal when a finding's body temp file cannot be written.
_BODY_UNWRITTEN = "could not write the issue body to its temp file"


@contextmanager
def finding_body_file_new(body: str) -> Iterator[str]:
    """Yields the path of the temp file holding a finding's issue body
    <body>, removed on exit, so a refusal or a gh failure that dies leaves
    none behind."""
    with temp_text_file(body, "could not create a temp file for the issue body",
                        _BODY_UNWRITTEN) as path:
        yield path


def finding_body_file_rewrite(path: str, body: str) -> None:
    """Rewrites the body temp file <path>, made by finding_body_file_new, to
    hold <body>."""
    text_file_write(path, body, _BODY_UNWRITTEN)


def finding_body_render(finding: str, fields: FindingBody) -> str:
    """A filed finding's issue body: the finding text <finding>, its NULs
    and trailing newlines dropped as bash's $(cat) drops them, a blank line,
    then each labelled line of <fields> followed by a blank line, so GitHub
    shows each as its own paragraph - the spec question's only when there is
    one. Its pr_number goes unused: the PR line carries the URL alone. The
    labelled lines are the closer's, byte for byte, so a body filed before
    rendering existed parses as one rendered now does."""
    axis = fields.axis.lower()
    parts = [finding.replace("\0", "").rstrip("\n"),
             "**Axis:** " + axis[:1].upper() + axis[1:],
             "**Severity:** %s - %s" % (fields.severity, fields.reason),
             "**Location:** `%s:%s` at %s" % (fields.file, fields.line, fields.sha),
             "**PR:** " + fields.pr,
             "**Why not fixed in the loop:** " + fields.why]
    if fields.question:
        parts.append("**Spec question:** " + fields.question)
    return "".join(part + "\n\n" for part in parts)


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
