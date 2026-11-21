"""`audit file <title> --category <c> --finding-file <f> --location <loc>...`,
in-process against the gh fake's store: the issue it files - its title, body
and labels - the number it prints, and its refusals, each made before any
write or GitHub call. Every case checks that no body temp file is left
behind."""
from __future__ import annotations

import tempfile

import pytest

from orch import audit
from orch.filed_finding import FILED_CATEGORIES
from orch.gh_fake import FakeGh
from orch.git import FakeGit
from conftest import GH_502, labels_doc, labels_of, read, snapshot, write_labels_doc

SHA = "0123456789abcdef0123456789abcdef01234567"
FINDING = "A doc says --force is required.\n\nThe code takes no such flag.\n\n\n"
USAGE = ("orch: usage: orch.sh audit file <title> --category <bug|enhancement|documentation>"
         " --finding-file <f> --location <<file>:<line>|<file>:<start>-<end>> [--location ...]\n")


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
def root(tmp_path):
    """The checkout's root: no triage-labels doc unless a test writes one."""
    path = tmp_path / "repo"
    path.mkdir()
    return path


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


def orch_audit(seed, root, *argv, gh=None, git=None):
    """`orch.sh audit <argv>` in-process, in the checkout at <root>: its exit
    code, a SystemExit's included."""
    gh = FakeGh(seed.store, {}, sleep=lambda _: None) if gh is None else gh
    try:
        return audit.run(list(argv), gh=gh, git=head_at(root) if git is None else git, env={})
    except SystemExit as died:
        return died.code


def repo_labels(store):
    """The repo's labels in the store, one (name, colour, description) each."""
    text = read(store, "labels") or ""
    return [tuple(line.split("\t")) for line in text.splitlines()]


def test_a_finding_is_filed_and_its_number_alone_printed(seed, store, root, parts, capsys):
    seed.next_issue(31)

    code = orch_audit(seed, root, "file", "Docs name a flag that is gone", *parts)

    assert (code, capsys.readouterr()) == (0, ("31\n", ""))
    assert read(store, "issues", 31, "title") == "Docs name a flag that is gone\n"


def test_the_body_holds_the_finding_each_location_in_order_and_head(seed, store, root, parts):
    orch_audit(seed, root, "file", "T", *parts)

    assert read(store, "issues", 1, "body") == (
        "A doc says --force is required.\n\nThe code takes no such flag.\n\n"
        "**Location:** `docs/a.md:12`\n\n**Location:** `README.md:3-9`\n\n"
        "**Audited at:** %s\n\n" % SHA)


# --- labels ------------------------------------------------------------------


def test_the_issue_carries_needs_triage_and_its_category(seed, store, root, parts):
    orch_audit(seed, root, "file", "T", *parts)

    assert labels_of(store, 1) == ["needs-triage", "documentation"]


@pytest.mark.parametrize("category", ["bug", "enhancement"])
def test_the_category_given_is_the_category_label(seed, store, root, finding, category):
    orch_audit(seed, root, "file", "T", "--category", category,
               "--finding-file", str(finding), "--location", "a.md:1")

    assert labels_of(store, 1) == ["needs-triage", category]


def test_missing_labels_are_created_and_the_repo_s_own_left_as_they_are(
        seed, store, root, parts):
    (store / "labels").write_text("needs-triage\t000000\tThe repo's own\n")

    orch_audit(seed, root, "file", "T", *parts)

    assert repo_labels(store) == [
        ("needs-triage", "000000", "The repo's own"),
        ("documentation", "0075ca", "Improvements or additions to documentation"),
    ]


def test_a_missing_needs_triage_label_is_created_as_bash_creates_it(seed, store, root, parts):
    (store / "labels").write_text("documentation\tffffff\tThe repo's own\n")

    orch_audit(seed, root, "file", "T", *parts)

    assert repo_labels(store) == [
        ("documentation", "ffffff", "The repo's own"),
        ("needs-triage", "e4e669", "Not yet triaged"),
    ]


def test_a_failed_label_create_is_ignored(seed, store, root, parts, capsys):
    seed.fail("adapter_label_create", GH_502)

    code = orch_audit(seed, root, "file", "T", *parts)

    assert (code, capsys.readouterr().out) == (0, "1\n")
    assert labels_of(store, 1) == ["needs-triage", "documentation"]


def test_the_triage_label_is_the_repo_s_name_for_needs_triage(seed, store, root, parts):
    write_labels_doc(root, labels_doc(("needs-triage", "triage me")))

    orch_audit(seed, root, "file", "T", *parts)

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

    code = orch_audit(seed, root, "file", "Docs name a flag that is gone", *parts)

    assert (code, capsys.readouterr()) == (
        0, ("5\n", "orch: #5 is already open with this title; nothing filed\n"))
    assert snapshot(store) == before


@pytest.mark.parametrize("title", ["docs name a flag that is gone", "Closed twin"])
def test_a_title_differing_in_case_or_closed_is_filed_anew(
        seed, store, root, parts, twins, title, capsys):
    code = orch_audit(seed, root, "file", title, *parts)

    assert (code, capsys.readouterr().out) == (0, "7\n")


# --- gh failures ---------------------------------------------------------------


@pytest.mark.parametrize("operation, message", [
    ("adapter_issues_open_titles", "list the open issues"),
    ("adapter_issue_create", "create the issue"),
])
def test_a_failed_gh_call_dies_naming_the_step_and_files_nothing(
        seed, store, root, parts, operation, message, capsys):
    seed.fail(operation, GH_502)

    code = orch_audit(seed, root, "file", "T", *parts)

    assert (code, capsys.readouterr()) == (
        1, ("", "orch: gh could not %s: HTTP 502: Bad Gateway\n" % message))
    assert read(store, "issues", 1, "title") is None


def test_a_failed_open_issue_listing_writes_no_label(seed, store, root, parts):
    seed.fail("adapter_issues_open_titles", GH_502)

    orch_audit(seed, root, "file", "T", *parts)

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
    code = orch_audit(seed, root, "file", *argv, gh=NoGh(), git=git)
    out, err = capsys.readouterr()
    assert out == ""
    return code, err


def test_the_usage_line_s_categories_are_the_filed_finding_list_s_in_order():
    names = "|".join(name for name, _, _ in FILED_CATEGORIES)

    assert "--category <%s>" % names in audit.audit_file_usage()
    assert audit.audit_usage().endswith("\n   or: " + audit.audit_file_usage()[len("usage: "):])


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
], ids=["a-line", "wrapped", "after-a-blank", "after-a-fence"])
def test_a_finding_naming_a_report_s_numbering_is_refused_at_its_line(
        seed, root, finding, parts, text, line, phrase, capsys):
    finding.write_text(text)
    phrase = phrase.replace("\n", " ")

    code, err = refused(seed, root, capsys, "T", *parts)

    assert (code, err) == (1, "orch: %s line %d says '%s': %s\n"
                           % (finding, line, phrase, audit.ALONE))


def test_the_report_a_span_and_a_fence_are_no_reference(seed, store, root, finding, parts):
    finding.write_text("The report says `finding 4`.\n```\nthis report\n```\n")

    assert orch_audit(seed, root, "file", "T", *parts) == 0
    assert read(store, "issues", 1, "title") == "T\n"


def test_no_op_is_refused_with_the_whole_usage_text(seed, root, capsys):
    code = orch_audit(seed, root, gh=NoGh())

    assert (code, capsys.readouterr()) == (1, ("", (
        "orch: usage: orch.sh audit begin <code|docs|tests>\n"
        "   or: orch.sh audit report <dir> <out.html>\n"
        "   or: orch.sh audit file --run <dir> <numbers>\n"
        "   or: " + USAGE[len("orch: usage: "):])))
