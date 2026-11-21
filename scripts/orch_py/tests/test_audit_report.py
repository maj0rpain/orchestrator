"""`orch.sh audit report <dir> <out.html>`, in-process: the page it writes,
byte for byte against the golden files the bash renderer wrote, its
refusals of a malformed run directory, and its output path's.

The golden files are tests/audit_report/full.html and none.html, rendered by
the bash audit module from the run directories beside them: full/ holds
notes, a Mermaid fence, a plain fence, an unclosed fence, inline code, an
overlap link and HTML-special characters, none/ an `@@ none` run.
"""
from __future__ import annotations

import os
import shutil

import pytest

from orch import audit, common
from orch.git import FakeGit

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "audit_report")
CHECKOUT = "/nonexistent/checkout"

USAGE = (
    "orch: usage: orch.sh audit begin <code|docs|tests>\n"
    "   or: orch.sh audit report <dir> <out.html>\n"
    "   or: orch.sh audit file --run <dir> <numbers>\n"
    "   or: orch.sh audit file <title> --category <bug|enhancement|documentation>"
    " --finding-file <f> --location <<file>:<line>|<file>:<start>-<end>> [--location ...]\n"
)


def report(*args):
    """`audit report <args>` in a checkout; its exit code."""
    return audit.run(["report", *(str(arg) for arg in args)],
                     git=FakeGit(toplevel=CHECKOUT), env={})


def golden(name):
    with open(os.path.join(FIXTURES, name + ".html"), "rb") as f:
        return f.read()


@pytest.mark.parametrize("name", ["full", "none"])
def test_report_writes_the_golden_page_byte_for_byte(tmp_path, capsys, name):
    out = tmp_path / "report.html"
    assert report(os.path.join(FIXTURES, name), out) == 0
    assert out.read_bytes() == golden(name)
    assert capsys.readouterr() == (str(out) + "\n", "")


@pytest.fixture
def run_dir(tmp_path):
    """A copy of the full/ run directory, at tmp_path/run."""
    path = tmp_path / "run"
    shutil.copytree(os.path.join(FIXTURES, "full"), str(path))
    return path


def edit(path, old, new):
    """<path> with its one <old> replaced by <new>."""
    text = path.read_text(encoding="utf-8")
    assert text.count(old) == 1
    path.write_text(text.replace(old, new), encoding="utf-8")


def listing(tmp_path):
    """Every path under <tmp_path>, relative to it."""
    return sorted(os.path.relpath(os.path.join(d, name), str(tmp_path))
                  for d, dirs, files in os.walk(str(tmp_path)) for name in dirs + files)


def refused(tmp_path, capsys, run, out, message):
    """`audit report <run> <out>` dies, exit 1, with exactly `orch:
    <message>`, printing nothing and changing no file under <tmp_path>."""
    before = listing(tmp_path)
    contents = out.read_bytes() if out.is_file() else None
    with pytest.raises(SystemExit) as death:
        report(run, out)
    assert death.value.code == 1
    assert capsys.readouterr() == ("", "orch: " + message + "\n")
    assert listing(tmp_path) == before
    assert (out.read_bytes() if out.is_file() else None) == contents


ALONE = ("a finding must read alone, so name no other finding by number and never"
         " this report; restate the field in the ranked block")
NOT_SHAPE = "is not <file>:<line> or <file>:<start>-<end>"

# Each malformed run: the file edited, the text replaced and its replacement,
# and the bash renderer's refusal of it.
MALFORMED = [
    ("ranked.md", "@@ scope the audit's `s.sh` scope & \"more\"\n", "",
     "ranked.md has no @@ scope line"),
    ("ranked.md", "@@ areas 2\n", "@@ areas 2\n@@ scope again\n",
     "ranked.md line 3: a second @@ scope"),
    ("ranked.md", "@@ scope the audit's `s.sh` scope & \"more\"\n", "@@ scope  \n",
     "ranked.md line 1: @@ scope names no scope"),
    ("ranked.md", "@@ areas 2\n", "stray\n@@ areas 2\n", "ranked.md line 1: text after @@ scope"),
    ("ranked.md", "@@ areas 2\n", "", "ranked.md has no @@ areas line"),
    ("ranked.md", "@@ areas 2\n", "@@ areas two\n",
     "ranked.md line 2: @@ areas takes a count, not 'two'"),
    ("ranked.md", "@@ note Second note\n", "@@ note\n",
     "ranked.md line 8: @@ note names no heading"),
    ("ranked.md", "@@ top 1\nStart here, because `a.sh` is hot.\n", "",
     "ranked.md needs exactly one of @@ top and @@ none"),
    ("ranked.md", "@@ top 1\n", "@@ none\n@@ top 1\n",
     "ranked.md needs exactly one of @@ top and @@ none"),
    ("ranked.md", "@@ areas 2\n", "@@ areas 2\n@@ top 2\n", "ranked.md line 13: a second @@ top"),
    ("ranked.md", "@@ top 1\n", "@@ top first\n",
     "ranked.md line 12: @@ top takes a finding number, not 'first'"),
    ("ranked.md", "@@ top 1\n", "@@ top 09\n",
     "ranked.md line 12: @@ top names finding 09, which the file lacks"),
    ("ranked.md", "@@ finding 2\n", "@@ finding 3\n",
     "ranked.md line 20: expected @@ finding 2, found '3': findings are numbered from 1 in order"),
    ("ranked.md", "@@ areas 2\n", "@@ areas 2\n@@ bogus\n",
     "ranked.md line 3: unknown line @@ bogus"),
    ("ranked.md", "@@ areas 2\n", "@@ areas 2\n@@Bogus\n",
     "ranked.md line 3: not a ranked-file line: @@Bogus"),
    ("ranked.md", "@@ scope", "\n  \nintro\n@@ scope",
     "ranked.md line 3: text before the first @@ line"),
    ("ranked.md", "From: area-2:1\n", "From: area-2:1\nFrom: area-1:2\n",
     "ranked.md line 22: finding 2 has two From: fields"),
    ("ranked.md", "From: area-2:1\n", "From: \n", "ranked.md line 21: From: names no source"),
    ("ranked.md", "From: area-2:1\n", "From: area-9:1\n",
     "ranked.md line 21: From: area-9:1 names area-9.md, which is not in the run directory"),
    ("ranked.md", "From: area-2:1\n", "From: area-2:7\n",
     "ranked.md line 21: From: area-2:7 names finding 7, which area-2.md lacks"),
    ("ranked.md", "From: area-2:1\n", "From: ranked:1\n",
     "ranked.md line 21: From: ranked:1 is not <area file>:<k>, an area-<n> file and a block"
     " number"),
    ("ranked.md", "Title: Deepen d.sh\n", "", "ranked.md line 20: finding 2 has no Title:"),
    ("ranked.md", "Title: Deepen d.sh\n", "Title:\n",
     "ranked.md line 22: finding 2's Title: is not one line"),
    ("ranked.md", "Category: bug\n", "Category: cheese\n",
     "ranked.md line 17: finding 1's Category: 'cheese' is not one of bug enhancement"
     " documentation"),
    ("ranked.md", "Category: bug\n", "", "ranked.md line 14: finding 1 has no Category:"),
    ("ranked.md", "Location: z.sh:4\n", "Location: z.sh\n",
     "ranked.md line 28: finding 3's location 'z.sh' " + NOT_SHAPE),
    ("ranked.md", "Location: z.sh:4\n", "", "ranked.md line 25: finding 3 has no Location:"),
    ("ranked.md", "Location: z.sh:4\n", "Location: , ,\n",
     "ranked.md line 28: finding 3 has no location"),
    ("ranked.md", "Overlaps: 3\n", "Overlaps: 9\n",
     "ranked.md line 18: finding 1 overlaps '9', which is not another finding of the file"),
    ("ranked.md", "Overlaps: 3\n", "Overlaps: 1\n",
     "ranked.md line 18: finding 1 overlaps '1', which is not another finding of the file"),
    ("ranked.md", "Title: Deepen d.sh\n", "Title: Deepen d.sh like Findings #3\n",
     "ranked.md line 22: finding 2's Title: says 'Findings #3' (line 1 of the field): " + ALONE),
    ("ranked.md", "Confidence: sure, restated\n", "Confidence: as in this\nReport\n",
     "ranked.md line 19: finding 1's Confidence: says 'this Report' (line 1 of the field): "
     + ALONE),
    ("ranked.md", "Confidence: sure, restated\n", "Confidence: see\nthe finding\n3 for it\n",
     "ranked.md line 19: finding 1's Confidence: says 'finding 3' (line 2 of the field): "
     + ALONE),
    ("area-1.md", "Location: a.sh:1, b.sh:2-3\n", "Location: a.sh, b.sh:2-3\n",
     "area-1.md line 3: finding 1's location 'a.sh' " + NOT_SHAPE),
    ("area-1.md", "Evidence: it <breaks> when `x & y` runs\n", "Evidence: as finding 3 says\n",
     "area-1.md line 4: finding 1's Evidence: says 'finding 3' (line 1 of the field): " + ALONE),
]


@pytest.mark.parametrize("name, old, new, message", MALFORMED,
                         ids=[case[3][:60] for case in MALFORMED])
def test_report_refuses_a_malformed_run_writing_nothing(tmp_path, capsys, run_dir, name, old,
                                                        new, message):
    out = tmp_path / "report.html"
    out.write_text("earlier report\n")
    edit(run_dir / name, old, new)
    refused(tmp_path, capsys, run_dir, out, message)


def test_report_names_the_area_file_line_of_a_hunters_category(tmp_path, capsys, run_dir):
    edit(run_dir / "area-2.md", "Evidence: friction\n", "Category: cheese\nEvidence: friction\n")
    edit(run_dir / "ranked.md", "Category: enhancement\nFix/Workaround", "Fix/Workaround")
    refused(tmp_path, capsys, run_dir, tmp_path / "report.html",
            "area-2.md line 4: finding 2's Category: 'cheese' is not one of bug enhancement"
            " documentation")


def test_report_refuses_a_run_with_no_record(tmp_path, capsys, run_dir):
    (run_dir / "record").unlink()
    refused(tmp_path, capsys, run_dir, tmp_path / "report.html",
            "%s holds no audit run record: make a run with orch.sh audit begin" % run_dir)


def test_report_refuses_a_record_naming_no_commit(tmp_path, capsys, run_dir):
    (run_dir / "record").write_text("kind code\ncommit 0123abc")
    refused(tmp_path, capsys, run_dir, tmp_path / "report.html",
            "%s/record names no kind or no commit" % run_dir)


def test_report_refuses_a_run_with_no_ranked_file(tmp_path, capsys, run_dir):
    (run_dir / "ranked.md").unlink()
    refused(tmp_path, capsys, run_dir, tmp_path / "report.html",
            "%s holds no ranked.md" % run_dir)


@pytest.mark.parametrize("old, new", [
    ("Confidence: sure, restated\n", "Confidence: the finding\n\n3 is apart; `finding\n4`, and"
                                     " the\nreport reads fine\n"),
    ("Title: Deepen d.sh\n", "Title: See the report and `finding 2`\n"),
    ("Evidence: not a field\n", "finding 9 and this report\n"),
])
def test_report_takes_a_reference_split_spanned_or_fenced(tmp_path, capsys, run_dir,
                                                         old, new):
    edit(run_dir / "ranked.md", old, new)
    assert report(run_dir, tmp_path / "report.html") == 0


def test_report_refuses_an_out_html_whose_directory_is_missing(tmp_path, capsys):
    out = tmp_path / "nodir" / "r.html"
    refused(tmp_path, capsys, os.path.join(FIXTURES, "full"), out,
            "the directory for the report does not exist: %s" % out.parent)


def test_report_refuses_an_out_html_that_is_a_directory(tmp_path, capsys):
    refused(tmp_path, capsys, os.path.join(FIXTURES, "full"), tmp_path,
            "the report path is a directory: %s" % tmp_path)


def test_a_failed_page_write_leaves_no_page_and_no_temporary_file(tmp_path, capsys,
                                                                 monkeypatch):
    def fail(src, dst):
        raise OSError("disk full")

    monkeypatch.setattr(common.os, "replace", fail)
    out = tmp_path / "report.html"
    refused(tmp_path, capsys, os.path.join(FIXTURES, "full"), out,
            "cannot write the report beside %s" % out)


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_an_out_html_in_a_read_only_directory_keeps_the_earlier_report(tmp_path, capsys):
    out = tmp_path / "ro" / "r.html"
    out.parent.mkdir()
    out.write_text("earlier\n")
    out.parent.chmod(0o555)
    try:
        refused(tmp_path, capsys, os.path.join(FIXTURES, "full"), out,
                "cannot write the report beside %s" % out)
    finally:
        out.parent.chmod(0o755)


@pytest.mark.parametrize("args", [[], ["only-one"], ["a", "b", "c"]])
def test_report_refuses_any_count_of_arguments_but_two_with_the_usage(capsys, args):
    with pytest.raises(SystemExit) as death:
        report(*args)
    assert death.value.code == 1
    assert capsys.readouterr() == ("", USAGE)


def test_audit_outside_a_checkout_dies_before_reading_the_run(tmp_path, capsys):
    with pytest.raises(SystemExit) as death:
        audit.run(["report", str(tmp_path / "missing"), str(tmp_path / "r.html")],
                  git=FakeGit(), env={})
    assert death.value.code == 1
    assert capsys.readouterr().err.startswith("orch: not inside a git repository (")
