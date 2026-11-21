"""The audit noun, a converted noun orch.sh hands to the package: its begin
verb, which makes an audit run's working directory (ADR-0064), its report
verb, which renders a run directory's ranked file and area files into one
HTML page, byte for byte as the bash renderer it replaced did (the golden
files in tests/audit_report/ pin it), its file verb, which files one audit
finding as a GitHub issue, or with --run a run's picked findings from its
ranked file, linking the overlapping ones by a **Related:** line, and an
audit-filed body's drift line, which the issue noun reads. run() is the
noun's entry point; its filing checks are the Filed finding module's
(orch/filed_finding.py), its run-directory stamp and git exclude writer the
common module's.

begin's checks all come before the run directory is made, and a write
failing after it is made removes it again; the git exclude lines already
written stay, as in bash. report's checks of the ranked file all come before
anything is written, and file's checks before any write or GitHub call, as
--run's are; --run prints and flushes each finding's line as it gets its
issue number, so a run that fails partway shows the findings already filed,
and a rerun finds them open by title rather than filing them again.

An audit-filed body is the finding's text, a blank line, one **Location:**
line per location and the **Audited at:** line naming the commit audited,
each followed by a blank line. Its drift line says which of the cited files
changed since the audited commit: compared tree to tree with HEAD, so no
ancestry is needed, uncommitted changes are not counted, and a renamed file is
listed as the path the body cites. The body is untrusted: only a hexadecimal
value reaches git as the commit, and every path reaches it as a literal one
(orch.git).
"""
from __future__ import annotations

import os
import re
import shutil
import time
from typing import Callable, Dict, List, Mapping, Optional, Sequence, Tuple

from orch.common import (
    ORCH_DIR_NAME,
    die,
    dir_stamp,
    exclude_orch_dirs,
    file_write_atomic,
    plain_number,
    read_text,
    warn,
)
from orch.filed_finding import (
    FILED_CATEGORY_NAMES,
    SPACE,
    SPACE_CLASS,
    category_label_ensure,
    finding_body_file_new,
    finding_body_file_rewrite,
    finding_flags_parse,
    finding_input_check,
    finding_location_check,
    finding_location_ok,
    needs_triage_label_ready,
)
from orch.gh import adapter, gh_or_die
from orch.git import Git
from orch.root import checkout_root
from orch.triage_labels import TriageLabels

# The verbs, each of which run() calls by name. docs_lint.sh reads a converted
# noun's verbs from this line, so it stays one `OPS = "<verb>|..."` line.
OPS = "begin|report|file"

# The kinds of audit `audit begin` takes, one per audit skill.
AUDIT_KINDS = ("code", "docs", "tests")

MARKER = "**Audited at:**"
LOCATION = "**Location:**"
_LOCATION_LINE = re.compile(r"\*\*Location:\*\* `([^`]*)`")
_HEX = re.compile(r"[0-9a-fA-F]+")


def audit_body_tail(sha: str, locations: Sequence[str]) -> str:
    """The body's tail: one **Location:** line per location in the order
    given, then the **Audited at:** line, each followed by a blank line."""
    lines = ["%s `%s`" % (LOCATION, location) for location in locations]
    lines.append("%s %s" % (MARKER, sha))
    return "".join(line + "\n\n" for line in lines)


def audit_body_render(finding: str, sha: str, locations: Sequence[str]) -> str:
    """The issue body: the finding's text <finding>, its trailing newlines
    stripped, a blank line, then audit_body_tail."""
    return finding.rstrip("\n") + "\n\n" + audit_body_tail(sha, locations)


def audit_open_find(listing: Sequence[Tuple[int, str]], title: str) -> Optional[int]:
    """The number of the first open issue in <listing> whose title is
    exactly <title>; None when there is none."""
    for n, name in listing:
        if name == title:
            return n
    return None


def audit_file(args: List[str], gh, git) -> int:
    """`audit file <title> --category <c> --finding-file <f> --location
    <loc>...`: files one finding as a GitHub issue and prints its number.
    Every check - the title, the finding file, the category, the locations, a
    reference to a report's numbering in the title or the finding, HEAD's SHA
    and the round trip of the rendered body - comes before any GitHub read or
    write. An open issue with exactly the title files nothing: its number is
    printed, with the already-open line on stderr, and the exit is 0."""
    usage = audit_file_usage()
    if not args:
        die(usage)
    title = args[0]
    category, finding, locations = "", "", []
    for flag, value in finding_flags_parse(
            usage, ("--category", "--finding-file", "--location"), args[1:]):
        if flag == "--location":
            locations.append(value)
        elif flag == "--category":
            if category:
                die(usage)
            category = value
        else:
            if finding:
                die(usage)
            finding = value
    if not (finding and category and locations):
        die(usage)
    if category not in FILED_CATEGORY_NAMES:
        die(usage)

    finding_input_check(title, finding)
    title_reference = ref_find(title)
    if title_reference:
        die("the title says '%s': %s" % (title_reference[0], ALONE))
    text = read_text(finding) or ""
    text_reference = ref_find(text)
    if text_reference:
        die("%s line %d says '%s': %s"
            % (finding, text_reference[1], text_reference[0], ALONE))
    for location in locations:
        finding_location_check(location)
    sha = git.resolve_commit("HEAD")
    if sha is None:
        die("cannot read the HEAD commit")

    body = audit_body_render(text, sha, locations)
    with finding_body_file_new(body) as body_file:
        got_locations, got_shas = body_parse(body)
        given, parsed = "\n".join(locations), "\n".join(got_locations)
        if parsed != given:
            die("the rendered body does not parse back: locations (given '%s', parsed '%s')"
                % (given, parsed))
        if got_shas != [sha]:
            die("the rendered body does not parse back: audited at (given '%s', parsed '%s')"
                % (sha, "\n".join(got_shas)))

        # An open issue with this exact title is the finding already filed.
        existing = audit_open_find(
            gh_or_die("list the open issues", gh.issues_open_titles), title)
        if existing is not None:
            warn("#%d is already open with this title; nothing filed" % existing)
            print(existing)
            return 0

        triage = needs_triage_label_ready(gh, TriageLabels(git.toplevel))
        category_label_ensure(gh, category)
        n = gh_or_die("create the issue", gh.issue_create, title, body_file, [triage, category])
    print(n)
    return 0


def audit_file_usage() -> str:
    """The one-finding form's usage line, its categories the filed-finding
    list's, in order."""
    return (
        "usage: orch.sh audit file <title> --category <%s> --finding-file <f>"
        " --location <<file>:<line>|<file>:<start>-<end>> [--location ...]"
        % "|".join(FILED_CATEGORY_NAMES)
    )


def audit_usage() -> str:
    """The usage text naming every form of the audit command, one per
    line."""
    return (
        "usage: orch.sh audit begin <%s>\n"
        "   or: orch.sh audit report <dir> <out.html>\n"
        "   or: orch.sh audit file --run <dir> <numbers>\n"
        "   or: %s" % ("|".join(AUDIT_KINDS), audit_file_usage()[len("usage: "):])
    )


def audit_begin(argv: List[str], git, root: str, clock: Callable[[], float]) -> int:
    """`audit begin <kind>`: makes <root>/.orchestrator/audit/<kind>-<stamp>/,
    the stamp <clock>'s UTC time, git-excluded through the git adapter <git>,
    records the kind and the HEAD commit in its `record` file, and prints its
    absolute path and nothing else. The directory is never reused. Reads and
    writes no flow state."""
    if len(argv) != 1 or argv[0] not in AUDIT_KINDS:
        die(audit_usage())
    kind = argv[0]
    sha = git.resolve_commit("HEAD")
    if sha is None:
        die("cannot read the HEAD commit")
    audits = os.path.join(root, ORCH_DIR_NAME, "audit")
    run_dir = os.path.join(audits, "%s-%s" % (kind, dir_stamp(clock)))
    if os.path.exists(run_dir):
        die("the audit run directory already exists: %s" % run_dir)
    try:
        os.makedirs(audits, exist_ok=True)
        os.mkdir(run_dir)
    except OSError:
        die("cannot make the audit run directory %s" % run_dir)
    made = False
    try:
        exclude_orch_dirs(git)
        try:
            with open(os.path.join(run_dir, "record"), "w", encoding="utf-8") as f:
                f.write("kind %s\ncommit %s\n" % (kind, sha))
        except OSError:
            die("cannot write the audit run record in %s" % run_dir)
        made = True
    finally:
        if not made:
            shutil.rmtree(run_dir, ignore_errors=True)
    print(run_dir)
    return 0


def body_parse(body: str) -> Tuple[List[str], List[str]]:
    """Every **Location:** line's backticked location, in order ("" for a
    line carrying none), and every **Audited at:** line's trimmed value."""
    locations, shas = [], []
    for line in body.split("\n"):
        if line.startswith(LOCATION):
            match = _LOCATION_LINE.fullmatch(line)
            locations.append(match.group(1) if match else "")
        elif line.startswith(MARKER):
            shas.append(line[len(MARKER):].strip(SPACE))
    return locations, shas


def drift_line(body: str, git) -> Optional[str]:
    """The drift line of an audit-filed body - `cited files changed since
    <sha>: ` then none, the changed files joined by ", " in body order, each
    once, or unknown (<reason>) - read through the git adapter <git>; None
    for any other body."""
    locations, shas = body_parse(body)
    if len(shas) != 1 or not _HEX.fullmatch(shas[0]):
        return None
    sha = shas[0]
    cited: List[str] = []
    for location in locations:
        if finding_location_ok(location):
            file = location.rpartition(":")[0]
            if file not in cited:
                cited.append(file)
    if not cited:
        return None
    prefix = "cited files changed since %s:" % sha
    changed = git.changed_paths(sha, cited)
    if changed is None:
        if not git.has_head_commit():
            reason = "no commit on HEAD"
        elif not git.has_commit(sha):
            reason = "commit not in this clone"
        else:
            reason = "git comparison failed"
        return "%s unknown (%s)" % (prefix, reason)
    listed = [file for file in cited if file in changed]
    return "%s %s" % (prefix, ", ".join(listed) if listed else "none")


# --- the ranked file and its reader (ADR-0064) ---------------------------------
#
# ranked_read is the one reader of a run directory: it checks that its ranked
# file holds together and returns the run, dying with an orch: message naming
# what is wrong and its line, before anything is written.

FENCE = "```"
# The remedy every refusal of a reference to a report's numbering ends on.
ALONE = ("a finding must read alone, so name no other finding by number and never"
         " this report")
# The fields that steer the ranked file's own reading and are not printed as
# the finding's content.
STEERING = ("From", "Title", "Category", "Overlaps")

_SECTION = re.compile(r"@@" + SPACE_CLASS + r"+([a-z]+)(" + SPACE_CLASS + r"+(.*))?", re.S)
_SECTION_KINDS = ("scope", "areas", "note", "top", "finding", "none")
_FIELD = re.compile(r"([A-Z][A-Za-z /]*):" + SPACE_CLASS + r"*(.*)", re.S)
_AREA_BLOCK = re.compile(
    r"@@" + SPACE_CLASS + r"+finding" + SPACE_CLASS + r"+([0-9]+)" + SPACE_CLASS + r"*")
_SOURCE = re.compile(r"(area-[0-9]+):([0-9]+)")
RELATED = "**Related:**"
_RELATED_TAIL = re.compile(r"#[0-9]+( #[0-9]+)*")
_RECORD_LINE = re.compile(r"([^ \t]*)[ \t]*(.*)", re.S)
_REFERENCE = re.compile(
    r"(^|[^a-z0-9_])((findings?|candidates?)" + SPACE_CLASS + r"+#?[0-9]+"
    r"|this" + SPACE_CLASS + r"+report)($|[^a-z0-9_])")


class Finding:
    """A resolved finding: its fields in resolved order, as (label, value)
    pairs, where each label's value was written (`<file> line <k>`) by label,
    where each location was written by location, and once checked its title,
    category, locations (one per line, as the page lists them) and the
    finding numbers it overlaps on either side."""

    def __init__(self) -> None:
        self.fields: List[Tuple[str, str]] = []
        self.where: Dict[str, str] = {}
        self.location_where: Dict[str, str] = {}
        self.title = ""
        self.category = ""
        self.locations: List[str] = []
        self.links: List[int] = []

    def field(self, label: str) -> Optional[str]:
        """The value of the first field <label>; None when it has none."""
        for name, value in self.fields:
            if name == label:
                return value
        return None

    def at(self, label: str, line: int) -> str:
        """Where field <label> was written, falling back to the block's own
        <line> of the ranked file."""
        return self.where.get(label) or "ranked.md line %d" % line


class Run:
    """A run directory as ranked_read reads it: its record's kind and commit,
    the ranked file's scope, area count, notes as (heading, text) pairs, its
    top finding's number and reason - or none, for an `@@ none` run - and its
    findings, finding n at findings[n - 1]. The top finding's number is kept
    as written too, as the page's link to it prints it."""

    def __init__(self, directory: str) -> None:
        self.directory = directory
        self.kind = ""
        self.commit = ""
        self.scope = ""
        self.areas = ""
        self.none = False
        self.top = 0
        self.top_written = ""
        self.top_text = ""
        self.notes: List[Tuple[str, str]] = []
        self.findings: List[Finding] = []


def _trim(text: str) -> str:
    return text.strip(SPACE)


def _blank(line: str) -> bool:
    return _trim(line) == ""


def _file_lines(path: str) -> Optional[List[str]]:
    """The lines of the file at <path> as bash's `read -r` loop reads them,
    a last line with no newline included; None when it cannot be read."""
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8", "surrogateescape")
    except OSError:
        return None
    lines = text.split("\n")
    lines.pop()
    if text and not text.endswith("\n"):
        lines.append(text.rsplit("\n", 1)[-1])
    return lines


def list_split(text: str) -> List[str]:
    """<text>'s comma-separated entries, trimmed, empty ones dropped."""
    return [item for item in (_trim(part) for part in text.split(",")) if item]


def list_lines(text: str) -> List[str]:
    """The non-empty lines of list_split's entries, one after another, as the
    bash reader's `read` loop over them walks them."""
    return [line for item in list_split(text) for line in item.split("\n") if line]


def fields_split(text: str, first: int) -> List[Tuple[str, str, int]]:
    """A block's fields, as (label, value, line) triples, the block's first
    line being <first>. A field opens on a line outside a fenced block that
    starts with a label - a capital letter, then letters, spaces or / - and a
    colon, and runs to the next field; values are trimmed. Text before the
    first field is dropped."""
    fields: List[List] = []
    fence = False
    line_number = first
    for line in text.split("\n"):
        match = None if fence or line.startswith(FENCE) else _FIELD.fullmatch(line)
        if line.startswith(FENCE):
            fence = not fence
            if fields:
                fields[-1][1] += "\n" + line
        elif match:
            fields.append([match.group(1), match.group(2), line_number])
        elif fields:
            fields[-1][1] += "\n" + line
        line_number += 1
    return [(label, _trim(value), at) for label, value, at in fields]


def area_load(directory: str, name: str) -> Optional[Dict[str, Tuple[str, int]]]:
    """<directory>/<name>.md's `@@ finding <k>` blocks, each its text and its
    first line under the key <name>:<k>; None when there is no such file."""
    path = directory + "/" + name + ".md"
    if not os.path.isfile(path):
        return None
    blocks: Dict[str, List] = {}
    key = ""
    for number, line in enumerate(_file_lines(path) or [], 1):
        match = _AREA_BLOCK.fullmatch(line)
        if match:
            key = "%s:%s" % (name, match.group(1))
            blocks[key] = ["", number + 1]
        elif line.startswith("@@"):
            key = ""
        elif key:
            blocks[key][0] += line + "\n"
    return {key: (text, at) for key, (text, at) in blocks.items()}


def ref_find(text: str) -> Optional[Tuple[str, int]]:
    """A reference to a report's numbering in <text>, outside inline
    backtick spans and fenced blocks and without regard to letter case:
    finding, findings, candidate or candidates followed by a number (an
    optional # before it), or "this report". A paragraph's lines read as one,
    so a reference split by a line wrap is found too. The phrase as written
    and the 1-based line it starts on; None when there is none."""
    fence = False
    para = ""
    starts: List[int] = []
    lines: List[int] = []
    for number, line in enumerate(text.split("\n") + [""], 1):
        if line.startswith(FENCE) or _blank(line):
            if para:
                found = _para_reference(para, starts, lines)
                if found:
                    return found
                para, starts, lines = "", [], []
            if line.startswith(FENCE):
                fence = not fence
            continue
        if fence:
            continue
        starts.append(len(para) + 1 if para else 0)
        lines.append(number)
        para += (" " if para else "") + line
    return None


def _para_reference(para: str, starts: List[int], lines: List[int]) -> Optional[Tuple[str, int]]:
    """ref_find's look at one paragraph: each inline span, which may wrap,
    blanked to as many spaces, and the ASCII letters lowered."""
    low = ""
    rest = para
    while rest.count("`") >= 2:
        pre, _, rest = rest.partition("`")
        span, _, rest = rest.partition("`")
        low += pre + " " * (len(span) + 2)
    # Each character lowered alone, as bash's ${low,,} lowers it: U+0130
    # lowers to i, never to two characters, so the positions still hold.
    low = "".join(c.lower()[:1] for c in low + rest)
    match = _REFERENCE.search(low)
    if not match:
        return None
    # The place is where the matched text first appears, as bash's
    # ${low%%"${BASH_REMATCH[0]}"*} takes it, which may be before the match.
    pos = low.find(match.group(0)) + len(match.group(1))
    at = 0
    for start, number in zip(starts, lines):
        if start > pos:
            break
        at = number
    return para[pos:pos + len(match.group(2))], at


def _record_read(audit_run: Run) -> None:
    """The run's kind and commit, read from its record as bash's `read -r
    key val` loop reads them: each newline-ended line's first word and the
    rest, trimmed; the last of each wins."""
    path = audit_run.directory + "/record"
    if not os.path.isfile(path):
        die("%s holds no audit run record: make a run with orch.sh audit begin" % audit_run.directory)
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8", "surrogateescape")
    except OSError:
        text = ""
    for line in text.split("\n")[:-1]:
        key, value = _RECORD_LINE.fullmatch(line.strip(" \t")).groups()
        if key == "kind":
            audit_run.kind = value
        elif key == "commit":
            audit_run.commit = value
    if not audit_run.kind or not audit_run.commit:
        die("%s/record names no kind or no commit" % audit_run.directory)


def _ranked_sections(path: str) -> List[Tuple[str, str, str, int]]:
    """The ranked file's `@@` lines, as (kind, argument, text, line)
    tuples, the argument trimmed and the text every line after it to the
    next, each newline-ended."""
    sections: List[List] = []
    for number, line in enumerate(_file_lines(path) or [], 1):
        if line.startswith("@@"):
            match = _SECTION.fullmatch(line)
            if not match:
                die("ranked.md line %d: not a ranked-file line: %s" % (number, line))
            kind = match.group(1)
            if kind not in _SECTION_KINDS:
                die("ranked.md line %d: unknown line @@ %s" % (number, kind))
            sections.append([kind, _trim(match.group(3) or ""), "", number])
        elif sections:
            sections[-1][2] += line + "\n"
        elif not _blank(line):
            die("ranked.md line %d: text before the first @@ line" % number)
    return [tuple(section) for section in sections]


def _finding_resolve(n: int, body: str, first: int, directory: str,
                     areas: Dict[str, Optional[Dict[str, Tuple[str, int]]]]) -> Finding:
    """Ranked finding <n>, resolved against its From: sources: the first
    source's fields in its order, each field the block restates replacing the
    source's in place, a label the source lacks added after; the locations of
    every source, in From: order and without repeats, unless the block
    restates Location:. <areas> caches the area files read so far."""
    finding = Finding()
    source = None
    source_line = 0
    restated: List[Tuple[str, str, str]] = []
    restates_location = False
    for label, value, at in fields_split(body, first):
        if label == "From":
            if source:
                die("ranked.md line %d: finding %d has two From: fields" % (at, n))
            source, source_line = value, at
            if not source:
                die("ranked.md line %d: From: names no source" % source_line)
        else:
            restated.append((label, value, "ranked.md line %d" % at))
            restates_location = restates_location or label == "Location"
    labels: List[str] = []
    values: List[str] = []
    wheres: List[str] = []
    locations = ""
    first_source = True
    for src in list_lines(source or ""):
        match = _SOURCE.fullmatch(src)
        if not match:
            die("ranked.md line %d: From: %s is not <area file>:<k>, an area-<n> file and"
                " a block number" % (source_line, src))
        area, block = match.group(1), match.group(2)
        if area not in areas:
            areas[area] = area_load(directory, area)
        blocks = areas[area]
        if blocks is None:
            die("ranked.md line %d: From: %s names %s.md, which is not in the run directory"
                % (source_line, src, area))
        if src not in blocks:
            die("ranked.md line %d: From: %s names finding %s, which %s.md lacks"
                % (source_line, src, block, area))
        fields = fields_split(*blocks[src])
        if first_source:
            first_source = False
            labels = [label for label, _, _ in fields]
            values = [value for _, value, _ in fields]
            wheres = ["%s.md line %d" % (area, at) for _, _, at in fields]
        for label, value, at in fields:
            if label != "Location":
                continue
            locations += value + ","
            if restates_location:
                continue
            for location in list_lines(value):
                finding.location_where.setdefault(location, "%s.md line %d" % (area, at))
    for label, value, where in restated:
        if label in labels:
            k = labels.index(label)
            values[k], wheres[k] = value, where
        else:
            labels.append(label)
            values.append(value)
            wheres.append(where)
    if not restates_location and locations:
        merged: List[str] = []
        for location in list_lines(locations):
            if location not in merged:
                merged.append(location)
        if "Location" in labels:
            values[labels.index("Location")] = ", ".join(merged)
        else:
            labels.append("Location")
            values.append(", ".join(merged))
            wheres.append("ranked.md line %d" % source_line)
    finding.fields = list(zip(labels, values))
    for label, where in zip(labels, wheres):
        finding.where[label] = where
    return finding


def _finding_check(n: int, finding: Finding, line: int, count: int,
                   links: Dict[int, List[int]]) -> None:
    """Dies unless resolved finding <n>, its block's `@@` line at <line> of
    the ranked file, has a one-line Title:, a filed Category:, well-formed
    locations, no field naming another finding or this report and overlaps
    only other findings of the <count>; records its checked fields, and
    each overlap, on either side, in <links>."""
    title = finding.field("Title")
    if title is None:
        die("ranked.md line %d: finding %d has no Title:" % (line, n))
    if not title or "\n" in title:
        die("%s: finding %d's Title: is not one line" % (finding.at("Title", line), n))
    category = finding.field("Category")
    if category is None:
        die("ranked.md line %d: finding %d has no Category:" % (line, n))
    if category not in FILED_CATEGORY_NAMES:
        die("%s: finding %d's Category: '%s' is not one of %s"
            % (finding.at("Category", line), n, category, " ".join(FILED_CATEGORY_NAMES)))
    location_field = finding.field("Location")
    if location_field is None:
        die("ranked.md line %d: finding %d has no Location:" % (line, n))
    location_at = finding.at("Location", line)
    entries = list_split(location_field)
    if not entries:
        die("%s: finding %d has no location" % (location_at, n))
    for location in list_lines(location_field):
        if not finding_location_ok(location):
            die("%s: finding %d's location '%s' is not <file>:<line> or <file>:<start>-<end>"
                % (finding.location_where.get(location) or location_at, n, location))
    for label, value in finding.fields:
        # Narrower than STEERING on purpose: Title and Category are read here
        # too, so one naming another finding is still refused.
        if label in ("From", "Overlaps"):
            continue
        found = ref_find(value)
        if found:
            die("%s: finding %d's %s: says '%s' (line %d of the field): %s; restate the"
                " field in the ranked block" % (finding.at(label, line), n, label, found[0],
                                                found[1], ALONE))
    finding.title, finding.category = title, category
    finding.locations = [line for entry in entries for line in entry.split("\n")]
    overlaps = finding.field("Overlaps")
    if overlaps is None:
        return
    overlaps_at = finding.at("Overlaps", line)
    for other in list_lines(overlaps):
        if not (plain_number(other) and 1 <= int(other) <= count and int(other) != n):
            die("%s: finding %d overlaps '%s', which is not another finding of the file"
                % (overlaps_at, n, other))
        links.setdefault(n, []).append(int(other))
        links.setdefault(int(other), []).append(n)


def ranked_read(directory: str) -> Run:
    """Reads and checks the run directory <directory>: its record, its
    ranked file, and every area file a From: names. Dies on the first thing
    that does not hold."""
    audit_run = Run(directory)
    _record_read(audit_run)
    if not os.path.isfile(directory + "/ranked.md"):
        die("%s holds no ranked.md" % directory)
    counts = dict.fromkeys(("scope", "areas", "top", "none"), 0)
    blocks: List[Tuple[str, int]] = []
    top_line = 0
    for kind, arg, text, line in _ranked_sections(directory + "/ranked.md"):
        body = _trim(text)
        if kind in counts:
            counts[kind] += 1
            if counts[kind] > 1:
                die("ranked.md line %d: a second @@ %s" % (line, kind))
        if kind == "scope":
            if not arg:
                die("ranked.md line %d: @@ scope names no scope" % line)
            audit_run.scope = arg
        elif kind == "areas":
            if not plain_number(arg):
                die("ranked.md line %d: @@ areas takes a count, not '%s'" % (line, arg))
            audit_run.areas = arg
        elif kind == "note":
            if not arg:
                die("ranked.md line %d: @@ note names no heading" % line)
            audit_run.notes.append((arg, body))
        elif kind == "top":
            if not plain_number(arg):
                die("ranked.md line %d: @@ top takes a finding number, not '%s'" % (line, arg))
            audit_run.top, audit_run.top_written, audit_run.top_text, top_line = int(arg), arg, body, line
        elif kind == "none":
            audit_run.none = True
        else:
            expect = len(blocks) + 1
            if not (plain_number(arg) and int(arg) == expect):
                die("ranked.md line %d: expected @@ finding %d, found '%s': findings are"
                    " numbered from 1 in order" % (line, expect, arg))
            blocks.append((text, line + 1))
        if kind in ("scope", "areas", "none") and body:
            die("ranked.md line %d: text after @@ %s" % (line, kind))
    if not counts["scope"]:
        die("ranked.md has no @@ scope line")
    if not counts["areas"]:
        die("ranked.md has no @@ areas line")
    if counts["top"] + counts["none"] != 1:
        die("ranked.md needs exactly one of @@ top and @@ none")
    count = len(blocks)
    if audit_run.none:
        if count:
            die("ranked.md has @@ none and findings")
        return audit_run
    if not count:
        die("ranked.md has @@ top and no findings")
    if not 1 <= audit_run.top <= count:
        die("ranked.md line %d: @@ top names finding %s, which the file lacks"
            % (top_line, audit_run.top_written))
    areas: Dict[str, Optional[Dict[str, Tuple[str, int]]]] = {}
    links: Dict[int, List[int]] = {}
    for n, (block, first) in enumerate(blocks, 1):
        finding = _finding_resolve(n, block, first, directory, areas)
        _finding_check(n, finding, first - 1, count, links)
        audit_run.findings.append(finding)
    for n, finding in enumerate(audit_run.findings, 1):
        finding.links = sorted(set(links.get(n, [])))
    return audit_run


# --- the report page ----------------------------------------------------------


def esc(text: str) -> str:
    """<text> with & < > " and ' made HTML-safe."""
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;").replace("'", "&#39;"))


def inline(text: str) -> str:
    """<text> escaped, each inline backtick span (a backtick, text, a
    backtick) as <code>."""
    out = ""
    rest = text
    while rest.count("`") >= 2:
        pre, _, rest = rest.partition("`")
        span, _, rest = rest.partition("`")
        out += esc(pre) + "<code>" + esc(span) + "</code>"
    return out + esc(rest)


def _para(para: str) -> str:
    return '<p class="my-2">%s</p>\n' % inline(para)


def _code(code: str) -> str:
    return ('<pre class="overflow-x-auto bg-gray-100 p-3 rounded text-sm"><code>%s</code></pre>\n'
            % esc(code))


def _finding_link(n: str, title_html: str) -> str:
    return '<a class="text-blue-700 underline" href="#finding-%s">Finding %s: %s</a>' % (
        n, n, title_html)


def _field_heading(text: str) -> str:
    return '<h3 class="mt-3 font-semibold">%s</h3>\n' % esc(text)


LIST_OPEN = '<ul class="list-disc ml-6">\n'


def md_render(text: str) -> str:
    """<text> as HTML, in the one small markup set: every character escaped;
    a blank line ends a paragraph; a fenced block is preformatted code, a
    fenced block tagged mermaid a Mermaid diagram, one left open plain code;
    an inline backtick span is code."""
    out = []
    fence = False
    tag = ""
    para: List[str] = []
    code: List[str] = []
    for line in text.split("\n"):
        if fence:
            if line.startswith(FENCE):
                if tag == "mermaid":
                    out.append('<pre class="mermaid">%s</pre>\n' % esc("\n".join(code)))
                else:
                    out.append(_code("\n".join(code)))
                fence, code = False, []
            else:
                code.append(line)
        elif line.startswith(FENCE) or _blank(line):
            if para:
                out.append(_para("\n".join(para)))
                para = []
            if line.startswith(FENCE):
                tag, fence = _trim(line[len(FENCE):]), True
        else:
            para.append(line)
    if para:
        out.append(_para("\n".join(para)))
    if fence:
        out.append(_code("\n".join(code)))
    return "".join(out)


def page_render(audit_run: Run) -> str:
    """The report page for <audit_run>. It holds no clock time and nothing
    random."""
    kind = esc(audit_run.kind)
    out = [
        '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n',
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n',
        "<title>Audit report: %s</title>\n" % kind,
        '<script src="https://cdn.tailwindcss.com"></script>\n',
        '<script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>\n',
        "<script>mermaid.initialize({ startOnLoad: true });</script>\n",
        '</head>\n<body class="bg-white text-gray-900 max-w-4xl mx-auto p-6">\n',
        '<header class="mb-6">\n<h1 class="text-2xl font-bold">Audit report: %s</h1>\n' % kind,
        '<dl class="mt-3 grid grid-cols-4 gap-2">\n<dt class="font-semibold">Scope</dt>'
        '<dd class="col-span-3">%s</dd>\n' % inline(audit_run.scope),
        '<dt class="font-semibold">Areas</dt><dd class="col-span-3">%s</dd>\n' % audit_run.areas,
        '<dt class="font-semibold">Commit</dt><dd class="col-span-3"><code>%s</code></dd>\n'
        "</dl>\n" % esc(audit_run.commit),
    ]
    for heading, text in audit_run.notes:
        out.append('<section class="mt-4">\n<h2 class="text-lg font-semibold">%s</h2>\n'
                   % inline(heading))
        out.append(md_render(text))
        out.append("</section>\n")
    out.append("</header>\n<main>\n")
    if audit_run.none:
        out.append('<p class="text-lg">The audit found nothing: no findings were kept.</p>\n')
    else:
        out.append('<section id="top" class="mb-8 p-4 border-l-4 border-blue-500 bg-blue-50">\n'
                   '<h2 class="text-lg font-semibold">Top recommendation</h2>\n')
        out.append('<p class="my-2">%s</p>\n'
                   % _finding_link(audit_run.top_written, inline(audit_run.findings[audit_run.top - 1].title)))
        out.append(md_render(audit_run.top_text))
        out.append("</section>\n")
        for n, finding in enumerate(audit_run.findings, 1):
            out.append('<article id="finding-%d" class="mb-8">\n' % n)
            out.append('<h2 class="text-xl font-semibold">%d. %s</h2>\n'
                       % (n, inline(finding.title)))
            out.append('<p class="my-1"><span class="inline-block px-2 py-0.5 rounded bg-gray-200'
                       ' text-sm">%s</span></p>\n' % esc(finding.category))
            for label, value in finding.fields:
                if label in STEERING:
                    continue
                out.append(_field_heading(label))
                if label == "Location":
                    out.append(LIST_OPEN)
                    for location in finding.locations:
                        out.append("<li><code>%s</code></li>\n" % esc(location))
                    out.append("</ul>\n")
                else:
                    out.append(md_render(value))
            if finding.links:
                out.append(_field_heading("Overlaps"))
                out.append(LIST_OPEN)
                for j in finding.links:
                    out.append("<li>%s</li>\n"
                               % _finding_link(str(j), inline(audit_run.findings[j - 1].title)))
                out.append("</ul>\n")
            out.append("</article>\n")
    out.append("</main>\n</body>\n</html>\n")
    return "".join(out)


# --- the verbs ----------------------------------------------------------------


def audit_report(argv: List[str]) -> int:
    """`audit report <dir> <out.html>`: renders the audit run <dir> into
    <out.html> and prints its path. Every check of the ranked file comes
    before anything is written; the page goes to a temporary file beside
    <out.html> and is moved into place, so a refusal or a failed write leaves
    an earlier report as it was."""
    if len(argv) != 2:
        die(audit_usage())
    directory, out = argv
    audit_run = ranked_read(directory)
    outdir = out.rpartition("/")[0] if "/" in out else "."
    if not os.path.isdir(outdir):
        die("the directory for the report does not exist: %s" % outdir)
    if os.path.isdir(out):
        die("the report path is a directory: %s" % out)
    if not file_write_atomic(out, page_render(audit_run)):
        die("cannot write the report beside %s" % out)
    print(out)
    return 0


def audit_batch_body(finding: Finding, commit: str) -> str:
    """The issue body of resolved finding <finding>: each field other than
    the steering four and Location as a paragraph with its label in bold, then
    audit_body_tail of its locations and <commit>, the commit audit begin
    recorded."""
    paragraphs = ["**%s:** %s\n\n" % (label, value) for label, value in finding.fields
                  if label not in STEERING and label != "Location"]
    return "".join(paragraphs) + audit_body_tail(commit, finding.locations)


def audit_body_norm(text: str) -> str:
    """<text> with its carriage returns and trailing newlines dropped."""
    return text.replace("\r", "").rstrip("\n")


def audit_file_batch(argv: List[str], gh, git) -> int:
    """`audit file --run <dir> <numbers>`: files the ranked findings
    <numbers> (comma separated) of the audit run <dir> as issues, in number
    order. Every check - the ranked file's reader, the numbers, the bodies'
    round trip - comes before any GitHub read or write. Prints, per finding,
    its number, its issue number and filed or open, tab-separated, flushed as
    its finding gets its issue number, so a failure partway leaves the lines
    of the findings already filed."""
    if len(argv) != 2:
        die(audit_usage())
    audit_run = ranked_read(argv[0])
    want = list_lines(argv[1])
    if not want:
        die(audit_usage())
    seen: List[int] = []
    for item in want:
        if not plain_number(item):
            die("'%s' is not a finding number" % item)
        n = int(item)
        if not 1 <= n <= len(audit_run.findings):
            die("the ranked file has no finding %d" % n)
        if n in seen:
            die("finding %d is given twice" % n)
        seen.append(n)
    picked = sorted(seen)

    base: Dict[int, str] = {}
    for n in picked:
        finding = audit_run.findings[n - 1]
        base[n] = audit_body_norm(audit_batch_body(finding, audit_run.commit))
        got_locations, got_shas = body_parse(base[n])
        if got_locations != finding.locations:
            die("the rendered body does not parse back: locations of finding %d" % n)
        if got_shas != [audit_run.commit]:
            die("the rendered body does not parse back: audited at of finding %d" % n)

    with finding_body_file_new("") as body_file:
        existing = list(gh_or_die("list the open issues", gh.issues_open_titles))
        issue: Dict[int, int] = {}
        state: Dict[int, str] = {}
        triage: Optional[str] = None
        ensured: List[str] = []
        for n in picked:
            finding = audit_run.findings[n - 1]
            found = audit_open_find(existing, finding.title)
            if found is not None:
                issue[n], state[n] = found, "open"
                print("%d\t%d\topen" % (n, found), flush=True)
                continue
            if triage is None:
                triage = needs_triage_label_ready(gh, TriageLabels(git.toplevel))
            if finding.category not in ensured:
                category_label_ensure(gh, finding.category)
                ensured.append(finding.category)
            finding_body_file_rewrite(body_file, base[n] + "\n\n")
            made = gh_or_die("create the issue", gh.issue_create, finding.title, body_file,
                             [triage, finding.category])
            issue[n], state[n] = made, "filed"
            existing.append((made, finding.title))
            print("%d\t%d\tfiled" % (n, made), flush=True)
        _related_write_all(audit_run, picked, base, issue, state, body_file, gh)
    return 0


def _nums_union(a: Sequence[int], b: Sequence[int]) -> List[int]:
    """The numbers of <a> and <b>, each once, ascending."""
    return sorted(set(a) | set(b))


def _related_write_all(audit_run: Run, picked: List[int], base: Dict[int, str],
                       issue: Dict[int, int], state: Dict[int, str], body_file: str,
                       gh) -> None:
    """Writes each picked finding's issue's **Related:** paragraph: the
    issues of the picks it overlaps, but its own. The picks sharing an issue
    pool their links, and the issue is written once, from the rendering of
    the pick it still matches - with or without a Related line, whose numbers
    are kept. An open issue matching none was edited since it was filed: it
    is left alone, with a warning. An issue already naming every number is
    not written."""
    first_pick: Dict[int, int] = {}
    pooled: Dict[int, List[int]] = {}
    for n in picked:
        first_pick.setdefault(issue[n], n)
        links = [issue[j] for j in picked
                 if j in audit_run.findings[n - 1].links and issue[j] != issue[n]]
        if links:
            pooled[issue[n]] = _nums_union(pooled.get(issue[n], []), links)
    for n in picked:
        number = issue[n]
        if first_pick[number] != n or number not in pooled:
            continue
        had: List[int] = []
        match: Optional[int] = n
        if state[n] == "open":
            now = audit_body_norm(gh_or_die("read issue #%d" % number, gh.issue_body, number))
            match = None
            for j in picked:
                if issue[j] != number:
                    continue
                if now == base[j]:
                    match = j
                    break
                prefix = base[j] + "\n\n" + RELATED + " "
                tail = now[len(prefix):] if now.startswith(prefix) else ""
                if _RELATED_TAIL.fullmatch(tail):
                    had = _nums_union([int(w) for w in tail.replace("#", "").split()], [])
                    match = j
                    break
            if match is None:
                warn("#%d was edited since it was filed; its Related line is not written"
                     % number)
                continue
        unioned = _nums_union(had, pooled[number])
        if unioned == had:
            continue
        finding_body_file_rewrite(body_file, "%s\n\n%s %s\n\n" % (
            base[match], RELATED, " ".join("#%d" % k for k in unioned)))
        gh_or_die("write issue #%d's Related line" % number, gh.issue_body_edit, number,
                  body_file)


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    clock: Callable[[], float] = time.time,
) -> int:
    """`orch.sh audit <op> ...`: the real adapters, the process's environment
    and the system clock unless a test hands in others. Outside a checkout it
    dies first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die(audit_usage())
    if op == "file":
        gh = adapter(env) if gh is None else gh
        if argv[1:2] == ["--run"]:
            return audit_file_batch(argv[2:], gh, git)
        return audit_file(argv[1:], gh, git)
    if op == "report":
        return audit_report(argv[1:])
    return audit_begin(argv[1:], git, root, clock)
