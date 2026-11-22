"""`audit file <title> --category <c> --finding-file <f> --location <loc>...`
and `audit file --run <dir> <numbers>`, in-process against the gh fake's
store: the issues they file - title, body and labels, a run's **Related:**
lines - what they print, and their refusals, each made before any write or
GitHub call. Every case checks that no body temp file is left behind."""
from __future__ import annotations

import io
import os
import shutil
import sys
import tempfile

import pytest

from orch import audit
from orch.filed_finding import FILED_CATEGORY_NAMES
from orch.git import FakeGit
from conftest import (
    AUDIT_USAGE, GH_502, edit, fake, labels_doc, labels_of, orch_audit, read, snapshot,
    write_labels_doc,
)

SHA = "0123456789abcdef0123456789abcdef01234567"
FINDING = "A doc says --force is required.\n\nThe code takes no such flag.\n\n\n"
# The one-finding form's usage line: the last form of the audit usage.
USAGE = "orch: usage: " + AUDIT_USAGE.rpartition("   or: ")[2]


@pytest.fixture(autouse=True)
def temp_dir(tmp_path, monkeypatch):
    """The directory every temp file is made in; empty again when the test
    ends, so no body temp file was left behind."""
    path = tmp_path / "tmp"
    path.mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(path))
    yield path
    assert list(path.iterdir()) == []


@pytest.fixture
def finding(tmp_path):
    """The finding file, holding FINDING."""
    path = tmp_path / "finding.md"
    path.write_text(FINDING)
    return path


@pytest.fixture
def parts(finding):
    """The flags a filing takes: documentation, the finding file and two
    locations."""
    return ["--category", "documentation", "--finding-file", str(finding),
            "--location", "docs/a.md:12", "--location", "README.md:3-9"]


def head_at(root, sha=SHA):
    """The checkout at <root>, its HEAD <sha>; None for a branch with no
    commit."""
    git = FakeGit(toplevel=str(root))
    if sha is not None:
        git.seed("resolve_commit", "HEAD", answer=sha)
    return git


def repo_labels(store):
    """The repo's labels in the store, one (name, colour, description) each."""
    text = read(store, "labels") or ""
    return [tuple(line.split("\t")) for line in text.splitlines()]


def test_a_finding_is_filed_and_its_number_alone_printed(seed, store, root, parts, capsys):
    seed.next_issue(31)

    code = orch_audit(head_at(root), "file", "Docs name a flag that is gone", *parts, gh=fake(seed))

    assert (code, capsys.readouterr()) == (0, ("31\n", ""))
    assert read(store, "issues", 31, "title") == "Docs name a flag that is gone\n"


def test_the_body_holds_the_finding_each_location_in_order_and_head(seed, store, root, parts):
    orch_audit(head_at(root), "file", "T", *parts, gh=fake(seed))

    assert read(store, "issues", 1, "body") == (
        "A doc says --force is required.\n\nThe code takes no such flag.\n\n"
        "**Location:** `docs/a.md:12`\n\n**Location:** `README.md:3-9`\n\n"
        "**Audited at:** %s\n\n" % SHA)


# --- labels ------------------------------------------------------------------


def test_the_issue_carries_needs_triage_and_its_category(seed, store, root, parts):
    orch_audit(head_at(root), "file", "T", *parts, gh=fake(seed))

    assert labels_of(store, 1) == ["needs-triage", "documentation"]


@pytest.mark.parametrize("category", ["bug", "enhancement"])
def test_the_category_given_is_the_category_label(seed, store, root, finding, category):
    orch_audit(head_at(root), "file", "T", "--category", category,
               "--finding-file", str(finding), "--location", "a.md:1", gh=fake(seed))

    assert labels_of(store, 1) == ["needs-triage", category]


def test_missing_labels_are_created_and_the_repo_s_own_left_as_they_are(
        seed, store, root, parts):
    (store / "labels").write_text("needs-triage\t000000\tThe repo's own\n")

    orch_audit(head_at(root), "file", "T", *parts, gh=fake(seed))

    assert repo_labels(store) == [
        ("needs-triage", "000000", "The repo's own"),
        ("documentation", "0075ca", "Improvements or additions to documentation"),
    ]


def test_a_missing_needs_triage_label_is_created_as_bash_creates_it(seed, store, root, parts):
    (store / "labels").write_text("documentation\tffffff\tThe repo's own\n")

    orch_audit(head_at(root), "file", "T", *parts, gh=fake(seed))

    assert repo_labels(store) == [
        ("documentation", "ffffff", "The repo's own"),
        ("needs-triage", "e4e669", "Not yet triaged"),
    ]


def test_a_failed_label_create_is_ignored(seed, store, root, parts, capsys):
    seed.fail("adapter_label_create", GH_502)

    code = orch_audit(head_at(root), "file", "T", *parts, gh=fake(seed))

    assert (code, capsys.readouterr().out) == (0, "1\n")
    assert labels_of(store, 1) == ["needs-triage", "documentation"]


def test_the_triage_label_is_the_repo_s_name_for_needs_triage(seed, store, root, parts):
    write_labels_doc(root, labels_doc(("needs-triage", "triage me")))

    orch_audit(head_at(root), "file", "T", *parts, gh=fake(seed))

    assert labels_of(store, 1) == ["triage me", "documentation"]
    assert [name for name, _, _ in repo_labels(store)] == ["triage me", "documentation"]


# --- an issue already open ---------------------------------------------------


@pytest.fixture
def twins(seed):
    """Open issue #5 and closed issue #6, each titled."""
    seed.issue(5, "open")
    seed.title(5, "Docs name a flag that is gone")
    seed.issue(6, "closed")
    seed.title(6, "Closed twin")


def test_an_open_issue_with_the_title_files_nothing_and_prints_its_number(
        seed, store, root, parts, twins, capsys):
    before = snapshot(store)

    code = orch_audit(head_at(root), "file", "Docs name a flag that is gone", *parts, gh=fake(seed))

    assert (code, capsys.readouterr()) == (
        0, ("5\n", "orch: #5 is already open with this title; nothing filed\n"))
    assert snapshot(store) == before


@pytest.mark.parametrize("title", ["docs name a flag that is gone", "Closed twin"])
def test_a_title_differing_in_case_or_closed_is_filed_anew(
        seed, store, root, parts, twins, title, capsys):
    code = orch_audit(head_at(root), "file", title, *parts, gh=fake(seed))

    assert (code, capsys.readouterr().out) == (0, "7\n")


# --- gh failures ---------------------------------------------------------------


@pytest.mark.parametrize("operation, message", [
    ("adapter_issues_open_titles", "list the open issues"),
    ("adapter_issue_create", "create the issue"),
])
def test_a_failed_gh_call_dies_naming_the_step_and_files_nothing(
        seed, store, root, parts, operation, message, capsys):
    seed.fail(operation, GH_502)

    code = orch_audit(head_at(root), "file", "T", *parts, gh=fake(seed))

    assert (code, capsys.readouterr()) == (
        1, ("", "orch: gh could not %s: HTTP 502: Bad Gateway\n" % message))
    assert read(store, "issues", 1, "title") is None


def test_a_failed_open_issue_listing_writes_no_label(seed, store, root, parts):
    seed.fail("adapter_issues_open_titles", GH_502)

    orch_audit(head_at(root), "file", "T", *parts, gh=fake(seed))

    assert read(store, "labels") is None


# --- refusals ------------------------------------------------------------------


class NoGh:
    """A gh adapter any call of fails the test: a refusal is made before
    any GitHub call."""

    def __getattr__(self, name):
        raise AssertionError("a refusal reached gh: " + name)


def refused(seed, root, capsys, *argv, git=None):
    """The exit code and stderr of `audit file <argv>`, which must refuse
    before any GitHub call, printing nothing on stdout."""
    code = orch_audit(head_at(root) if git is None else git, "file", *argv, gh=NoGh())
    out, err = capsys.readouterr()
    assert out == ""
    return code, err


def test_the_usage_line_s_categories_are_the_filed_finding_list_s_in_order():
    names = "|".join(FILED_CATEGORY_NAMES)

    assert "--category <%s>" % names in audit.audit_file_usage()


@pytest.mark.parametrize("argv", [
    [],
    ["T", "--category", "bug", "--location", "a.md:1"],
    ["T", "--category", "bug", "--finding-file", "{f}"],
    ["T", "--finding-file", "{f}", "--location", "a.md:1"],
    ["T", "--category", "bug", "--finding-file", "{f}", "--location", "a.md:1", "--bogus", "x"],
    ["T", "--category", "bug", "--finding-file", "{f}", "--location"],
    ["T", "--category", "bug", "--finding-file", "{f}", "--location", "  "],
    ["T", "--category", "bug", "--finding-file", "{f}", "--finding-file", "{f}",
     "--location", "a.md:1"],
    ["T", "--category", "bug", "--category", "bug", "--finding-file", "{f}",
     "--location", "a.md:1"],
    ["T", "--category", "question", "--finding-file", "{f}", "--location", "a.md:1"],
    # The usage refusals come first: a bad flag before an empty title or a
    # missing finding file, an unknown category before both.
    ["", "--category", "bug", "--finding-file", "{f}", "--location", "a.md:1", "--bogus", "x"],
    ["", "--category", "question", "--finding-file", "/nonexistent/f.md", "--location", "a:x"],
], ids=["no-title", "no-finding-file", "no-location", "no-category", "unknown-flag",
        "flag-without-value", "blank-value", "finding-file-twice", "category-twice",
        "unknown-category", "bad-flag-before-empty-title", "unknown-category-first"])
def test_a_malformed_command_is_refused_with_the_usage_line(seed, root, finding, argv, capsys):
    argv = [arg.replace("{f}", str(finding)) for arg in argv]

    assert refused(seed, root, capsys, *argv) == (1, USAGE)


def bad(tmp_path, finding, case):
    """The argv of refusal <case>, and the message it is refused with."""
    blank = tmp_path / "blank.md"
    blank.write_text("  \n\n")
    f = str(finding)
    alone = audit.ALONE
    return {
        "empty title": (["", "--category", "bug", "--finding-file", f, "--location", "a:x"],
                        "the title is empty"),
        "missing finding file": (
            ["T", "--category", "bug", "--finding-file", "/nonexistent/f.md", "--location", "a:x"],
            "finding file not found: /nonexistent/f.md"),
        "whitespace finding file": (
            ["T", "--category", "bug", "--finding-file", str(blank), "--location", "a.md:1"],
            "finding file is empty: %s" % blank),
        "title reference before a bad location": (
            ["Fix it as in finding 2", "--category", "bug", "--finding-file", f,
             "--location", "a:x"],
            "the title says 'finding 2': " + alone),
        "bad location": (["T", "--category", "bug", "--finding-file", f, "--location", "a.md:x"],
                         "not a location: a.md:x (want <file>:<line> or <file>:<start>-<end>)"),
        "location with no file": (["T", "--category", "bug", "--finding-file", f,
                                   "--location", ":3"],
                                  "not a location: :3 (want <file>:<line> or <file>:<start>-<end>)"),
        "backtick location": (["T", "--category", "bug", "--finding-file", f,
                               "--location", "a`b.md:1"],
                              "the rendered body does not parse back: locations"
                              " (given 'a`b.md:1', parsed '')"),
    }[case]


@pytest.mark.parametrize("case", [
    "empty title", "missing finding file", "whitespace finding file",
    "title reference before a bad location", "bad location", "location with no file",
    "backtick location",
])
def test_a_bad_input_is_refused_naming_it_before_any_write(
        seed, store, root, tmp_path, finding, case, capsys):
    argv, message = bad(tmp_path, finding, case)

    assert refused(seed, root, capsys, *argv) == (1, "orch: %s\n" % message)
    assert snapshot(store) == {}


def test_a_head_with_no_commit_is_refused_before_any_github_call(
        seed, root, parts, capsys):
    code, err = refused(seed, root, capsys, "T", *parts, git=head_at(root, sha=None))

    assert (code, err) == (1, "orch: cannot read the HEAD commit\n")


@pytest.mark.parametrize("text, given", [
    ("It reads the line\n**Location:** `x.md:1`\nas a site.\n",
     "locations (given 'a.md:1', parsed 'x.md:1\na.md:1')"),
    ("It reads the line\n**Audited at:** abc123\nas a SHA.\n",
     "audited at (given '%s', parsed 'abc123\n%s')" % (SHA, SHA)),
])
def test_a_finding_holding_a_labelled_line_does_not_parse_back(
        seed, root, finding, text, given, capsys):
    finding.write_text(text)

    code, err = refused(seed, root, capsys, "T", "--category", "bug",
                        "--finding-file", str(finding), "--location", "a.md:1")

    assert (code, err) == (1, "orch: the rendered body does not parse back: %s\n" % given)


@pytest.mark.parametrize("text, line, phrase", [
    ("Line one.\nSame as Finding 4 here.\n", 2, "Finding 4"),
    ("Line one, see finding\n3 here.\n", 1, "finding 3"),
    ("First paragraph.\n\nSee candidates #12, then\nthis  report.\n", 3, "candidates #12"),
    ("```\nfinding 1\n```\n\nIn this\nreport here.\n", 5, "this\nreport"),
    # bash took the place from the matched text's first appearance, here
    # inside "finding 12a", so the phrase and line are that earlier text's.
    ("See finding 12a.\nAnd Finding 1\n", 1, "finding 1"),
], ids=["a-line", "wrapped", "after-a-blank", "after-a-fence", "text-seen-earlier"])
def test_a_finding_naming_a_report_s_numbering_is_refused_at_its_line(
        seed, root, finding, parts, text, line, phrase, capsys):
    finding.write_text(text)
    phrase = phrase.replace("\n", " ")

    code, err = refused(seed, root, capsys, "T", *parts)

    assert (code, err) == (1, "orch: %s line %d says '%s': %s\n"
                           % (finding, line, phrase, audit.ALONE))


def test_the_report_a_span_and_a_fence_are_no_reference(seed, store, root, finding, parts):
    finding.write_text("The report says `finding 4`.\n```\nthis report\n```\n")

    assert orch_audit(head_at(root), "file", "T", *parts, gh=fake(seed)) == 0
    assert read(store, "issues", 1, "title") == "T\n"


# --- a run's picked findings: file --run ---------------------------------------

# The committed run directory whose two area files a batch run reads.
FULL_RUN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "audit_report", "full")
# The commit the run's record names: not HEAD, which has moved on since.
RECORDED = "abcdef0123456789abcdef0123456789abcdef01"
RANKED = """@@ scope the audit's scope
@@ areas 2
@@ top 1
Start here, because `a.sh` is hot.
@@ finding 1
From: area-1:1, area-1:2
Title: Latent bug in a.sh
Category: bug
Overlaps: 3
Evidence: restated <b>evidence</b>
@@ finding 2
From: area-2:1
Title: Deepen d.sh
Category: enhancement
@@ finding 3
Title: Whole finding with no source
Category: enhancement
Location: z.sh:4
Kind: inefficiency
Evidence: a `tick` and a fence:
```
Evidence: not a field
```
"""
# Finding 1's issue body once finding 3's issue is #41.
BODY_1 = (
    "**Kind:** latent bug\n\n**Evidence:** restated <b>evidence</b>\n\n"
    "**Confidence:** certain\n\n**Location:** `a.sh:1`\n\n**Location:** `b.sh:2-3`\n\n"
    "**Location:** `c.sh:9`\n\n**Audited at:** %s\n\n**Related:** #41\n\n" % RECORDED)


@pytest.fixture
def batch(tmp_path, seed, store):
    """An audit run's directory, its record naming RECORDED, holding the
    committed full/ run's two area files and a ranked file of three
    findings, 1 overlapping 3; the
    store holds the repo's own needs-triage label and numbers the next issue
    #40."""
    path = tmp_path / "run"
    path.mkdir()
    for name in ("area-1.md", "area-2.md"):
        shutil.copy(os.path.join(FULL_RUN, name), str(path / name))
    for name, text in (("record", "kind code\ncommit %s\n" % RECORDED), ("ranked.md", RANKED)):
        (path / name).write_text(text)
    (store / "labels").write_text("needs-triage\t000000\tThe repo's own\n")
    seed.next_issue(40)
    return path


def file_run(seed, root, batch, numbers, gh=None):
    """`audit file --run <batch> <numbers>`, with the gh fake on <seed>'s
    store unless <gh> is given: its exit code."""
    return orch_audit(head_at(root), "file", "--run", str(batch), numbers,
                      gh=fake(seed) if gh is None else gh)


def test_a_pick_is_filed_one_line_per_finding_in_number_order(seed, root, batch, capsys):
    code = file_run(seed, root, batch, "3,1")

    assert (code, capsys.readouterr()) == (0, ("1\t40\tfiled\n3\t41\tfiled\n", ""))


def test_each_line_is_flushed_before_the_next_finding_s_issue_is_created(
        seed, root, batch, monkeypatch):
    # stdout's text reaches <written> only when flushed.
    written = io.BytesIO()
    monkeypatch.setattr(sys, "stdout", io.TextIOWrapper(written, encoding="utf-8"))
    gh = fake(seed)
    create, seen = gh.issue_create, []

    def watched(*args):
        seen.append(written.getvalue().decode())
        return create(*args)

    monkeypatch.setattr(gh, "issue_create", watched)

    file_run(seed, root, batch, "1,2,3", gh=gh)

    assert seen == ["", "1\t40\tfiled\n", "1\t40\tfiled\n2\t41\tfiled\n"]


def test_the_body_is_the_resolved_fields_each_location_the_recorded_commit_and_related(
        seed, store, root, batch):
    file_run(seed, root, batch, "3,1")

    assert read(store, "issues", 40, "body") == BODY_1


def test_the_other_side_of_a_one_sided_overlap_takes_the_related_line_too(
        seed, store, root, batch):
    file_run(seed, root, batch, "1,3")

    assert read(store, "issues", 41, "body").endswith("\n\n**Related:** #40\n\n")


def test_a_filed_issue_carries_its_title_needs_triage_and_its_category(seed, store, root, batch):
    file_run(seed, root, batch, "1,2")

    assert read(store, "issues", 40, "title") == "Latent bug in a.sh\n"
    assert (labels_of(store, 40), labels_of(store, 41)) == (
        ["needs-triage", "bug"], ["needs-triage", "enhancement"])


def test_a_rerun_reports_each_finding_open_and_writes_nothing(seed, store, root, batch, capsys):
    file_run(seed, root, batch, "3,1")
    capsys.readouterr()
    for write in ("adapter_issue_create", "adapter_issue_body_edit", "adapter_label_create"):
        seed.fail(write)
    before = snapshot(store)

    code = file_run(seed, root, batch, "1,3")

    assert (code, capsys.readouterr()) == (0, ("1\t40\topen\n3\t41\topen\n", ""))
    assert snapshot(store) == before


def test_an_already_open_title_is_reported_open_and_not_filed_again(
        seed, store, root, batch, capsys):
    seed.issue(50, "open")
    seed.title(50, "Deepen d.sh")
    seed.body(50, "mine")

    code = file_run(seed, root, batch, "2")

    assert (code, capsys.readouterr().out) == (0, "2\t50\topen\n")
    assert read(store, "issues", 40, "title") is None


def test_a_finding_whose_category_is_in_the_hunter_s_block_is_labelled_with_it(
        seed, store, root, batch):
    with open(batch / "area-2.md", "a") as area:
        area.write("Category: bug\n")
    edit(batch / "ranked.md", "Title: Deepen d.sh\nCategory: enhancement\n", "Title: Deepen d.sh\n")

    assert file_run(seed, root, batch, "2") == 0
    assert labels_of(store, 40) == ["needs-triage", "bug"]
    assert "**Related:**" not in read(store, "issues", 40, "body")


# Finding 2 overlaps 3 too: 1 and 3 are linked, 2 and 3 are, 1 and 2 are not.
TWO_OVERLAPS_THREE = ("From: area-2:1\n", "From: area-2:1\nOverlaps: 3\n")


def test_an_overlap_outside_the_batch_writes_no_related_line(seed, store, root, batch):
    edit(batch / "ranked.md", *TWO_OVERLAPS_THREE)

    file_run(seed, root, batch, "3")

    assert "**Related:**" not in read(store, "issues", 40, "body")


def test_an_open_issue_differing_in_crlf_and_trailing_newlines_takes_the_related_line(
        seed, store, root, batch, capsys):
    edit(batch / "ranked.md", *TWO_OVERLAPS_THREE)
    file_run(seed, root, batch, "3")
    body = read(store, "issues", 40, "body")
    seed.body(40, body.replace("\n", "\r\n") + "\r\n\r\n\n")
    capsys.readouterr()

    code = file_run(seed, root, batch, "1,3")

    assert (code, capsys.readouterr()) == (0, ("1\t41\tfiled\n3\t40\topen\n", ""))
    assert read(store, "issues", 40, "body") == body.rstrip("\n") + "\n\n**Related:** #41\n\n"


def test_a_second_batch_keeps_the_first_batch_s_numbers_and_never_chains(
        seed, store, root, batch):
    edit(batch / "ranked.md", *TWO_OVERLAPS_THREE)
    file_run(seed, root, batch, "3")
    file_run(seed, root, batch, "1,3")

    assert file_run(seed, root, batch, "2,3") == 0
    assert read(store, "issues", 40, "body").endswith("\n\n**Related:** #41 #42\n\n")
    assert read(store, "issues", 41, "body").endswith("\n\n**Related:** #40\n\n")
    assert read(store, "issues", 42, "body").endswith("\n\n**Related:** #40\n\n")


def test_an_issue_edited_since_it_was_filed_gets_no_related_line_and_a_warning(
        seed, store, root, batch, capsys):
    file_run(seed, root, batch, "3")
    seed.body(40, "my own text")
    capsys.readouterr()

    code = file_run(seed, root, batch, "1,3")

    assert (code, capsys.readouterr()) == (0, (
        "1\t41\tfiled\n3\t40\topen\n",
        "orch: #40 was edited since it was filed; its Related line is not written\n"))
    assert read(store, "issues", 40, "body") == "my own text"
    assert read(store, "issues", 41, "body").endswith("\n\n**Related:** #40\n\n")


# Finding 3 takes finding 1's title.
SAME_TITLE = ("Title: Whole finding with no source", "Title: Latent bug in a.sh")


def test_two_picks_with_one_title_file_one_issue(seed, store, root, batch, capsys):
    edit(batch / "ranked.md", *SAME_TITLE)

    code = file_run(seed, root, batch, "1,3")

    assert (code, capsys.readouterr().out) == (0, "1\t40\tfiled\n3\t40\topen\n")
    assert read(store, "issues", 41, "title") is None


def test_a_shared_issue_and_a_third_pick_overlapping_it_name_each_other(
        seed, store, root, batch, capsys):
    edit(batch / "ranked.md", *SAME_TITLE)
    edit(batch / "ranked.md", *TWO_OVERLAPS_THREE)

    code = file_run(seed, root, batch, "1,2,3")

    assert (code, capsys.readouterr().err) == (0, "")
    assert read(store, "issues", 41, "body").endswith("\n\n**Related:** #40\n\n")
    assert read(store, "issues", 40, "body").endswith("\n\n**Related:** #41\n\n")


def test_a_shared_issue_filed_earlier_from_the_later_pick_still_takes_its_related_line(
        seed, store, root, batch, capsys):
    edit(batch / "ranked.md", *SAME_TITLE)
    edit(batch / "ranked.md", *TWO_OVERLAPS_THREE)
    file_run(seed, root, batch, "3")
    capsys.readouterr()

    code = file_run(seed, root, batch, "1,2,3")

    assert (code, capsys.readouterr().err) == (0, "")
    assert read(store, "issues", 40, "body").endswith("\n\n**Related:** #41\n\n")


def test_a_shared_issue_rerun_after_its_related_write_failed_takes_the_line(
        seed, store, root, batch, capsys):
    edit(batch / "ranked.md", *SAME_TITLE)
    edit(batch / "ranked.md", *TWO_OVERLAPS_THREE)
    seed.fail("adapter_issue_body_edit")
    file_run(seed, root, batch, "1,2,3")
    seed.unfail()

    assert file_run(seed, root, batch, "1,2,3") == 0
    assert read(store, "issues", 40, "body").endswith("\n\n**Related:** #41\n\n")


# --- file --run: refusals and gh failures --------------------------------------


@pytest.mark.parametrize("numbers, message", [
    ("1,1", "finding 1 is given twice"),
    ("9", "the ranked file has no finding 9"),
    ("0", "the ranked file has no finding 0"),
    ("x", "'x' is not a finding number"),
    ("1,,x", "'x' is not a finding number"),
    (" , ", AUDIT_USAGE[len("orch: "):-1]),
    ("", AUDIT_USAGE[len("orch: "):-1]),
])
def test_bad_numbers_are_refused_before_any_github_call(
        seed, store, root, batch, numbers, message, capsys):
    assert refused(seed, root, capsys, "--run", str(batch), numbers) == (1, "orch: %s\n" % message)
    assert snapshot(store) == {"labels": b"needs-triage\t000000\tThe repo's own\n",
                               "next_issue": b"40\n"}


def test_no_numbers_is_refused_with_the_usage_naming_every_form(seed, root, batch, capsys):
    assert refused(seed, root, capsys, "--run", str(batch)) == (1, AUDIT_USAGE)


def test_a_field_naming_another_finding_is_refused_before_any_github_call(
        seed, root, batch, capsys):
    edit(batch / "ranked.md", "Evidence: a `tick`", "Evidence: see finding 2 and a `tick`")

    code, err = refused(seed, root, capsys, "--run", str(batch), "3")

    assert (code, "says 'finding 2'" in err) == (1, True)


def test_a_run_with_no_ranked_file_is_refused_before_any_github_call(seed, root, batch, capsys):
    (batch / "ranked.md").unlink()

    assert refused(seed, root, capsys, "--run", str(batch), "1") == (
        1, "orch: %s holds no ranked.md\n" % batch)


@pytest.mark.parametrize("operation, message", [
    ("adapter_issues_open_titles", "list the open issues"),
    ("adapter_issue_create", "create the issue"),
])
def test_a_failed_listing_or_first_create_dies_naming_the_step_and_files_nothing(
        seed, store, root, batch, operation, message, capsys):
    seed.fail(operation, GH_502)

    code = file_run(seed, root, batch, "1,3")

    assert (code, capsys.readouterr()) == (
        1, ("", "orch: gh could not %s: HTTP 502: Bad Gateway\n" % message))
    assert read(store, "issues", 40, "title") is None


def test_a_failed_create_partway_keeps_the_lines_filed_and_a_rerun_files_each_once(
        seed, store, root, batch, capsys):
    seed.fail_after("adapter_issue_create", 1, GH_502)

    assert file_run(seed, root, batch, "1,3") == 1
    assert capsys.readouterr() == (
        "1\t40\tfiled\n", "orch: gh could not create the issue: HTTP 502: Bad Gateway\n")
    assert read(store, "issues", 41, "title") is None
    seed.unfail()

    assert file_run(seed, root, batch, "1,3") == 0
    assert capsys.readouterr().out == "1\t40\topen\n3\t41\tfiled\n"
    assert read(store, "issues", 40, "body") == BODY_1


def test_a_failed_related_write_dies_and_a_rerun_writes_it_then_nothing_more(
        seed, store, root, batch, capsys):
    seed.fail("adapter_issue_body_edit", GH_502)

    assert file_run(seed, root, batch, "1,3") == 1
    assert capsys.readouterr() == ("1\t40\tfiled\n3\t41\tfiled\n", (
        "orch: gh could not write issue #40's Related line: HTTP 502: Bad Gateway\n"))
    seed.unfail()

    assert file_run(seed, root, batch, "1,3") == 0
    assert read(store, "issues", 41, "body").endswith("\n\n**Related:** #40\n\n")
    before = snapshot(store)
    file_run(seed, root, batch, "1,3")
    assert snapshot(store) == before


def test_a_failed_read_of_an_open_issue_dies_naming_it(seed, root, batch, capsys):
    file_run(seed, root, batch, "3")
    seed.fail("adapter_issue_body", GH_502)
    capsys.readouterr()

    assert file_run(seed, root, batch, "1,3") == 1
    assert capsys.readouterr() == (
        "1\t41\tfiled\n3\t40\topen\n", "orch: gh could not read issue #40: HTTP 502: Bad Gateway\n")


def test_a_failed_label_create_is_ignored_by_a_run(seed, store, root, batch, capsys):
    seed.fail("adapter_label_create", GH_502)

    assert file_run(seed, root, batch, "2") == 0
    assert labels_of(store, 40) == ["needs-triage", "enhancement"]
