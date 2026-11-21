"""The audit noun's begin verb, run in-process against FakeGit with the
checkout, its run directory and its git exclude file under tmp_path, each
checked by its stdout, its exit code, its `orch:` message and the files it
leaves."""
from __future__ import annotations

import calendar
import os
from pathlib import Path

import pytest

from orch import audit
from orch.git import FakeGit

HEAD = "0123456789abcdef0123456789abcdef01234567"
# The clock every run reads, pinned so a run directory's name is known.
PINNED = float(calendar.timegm((2030, 1, 2, 3, 4, 5)))
STAMP = "20300102-030405"

USAGE = (
    "orch: usage: orch.sh audit begin <code|docs|tests>\n"
    "   or: orch.sh audit report <dir> <out.html>\n"
    "   or: orch.sh audit file --run <dir> <numbers>\n"
    "   or: orch.sh audit file <title> --category <bug|enhancement|documentation>"
    " --finding-file <f> --location <<file>:<line>|<file>:<start>-<end>> [--location ...]\n"
)


@pytest.fixture
def root(tmp_path):
    """The checkout's root, tmp_path/repo, holding a .git directory with no
    info directory in it."""
    path = tmp_path / "repo"
    (path / ".git").mkdir(parents=True)
    return path


def checkout_git(root, git_class=FakeGit):
    """The checkout's git adapter: its toplevel <root>, HEAD at HEAD, and its
    common directory <root>/.git."""
    git = git_class(toplevel=str(root))
    git.seed("resolve_commit", "HEAD", answer=HEAD)
    git.seed("git_common_dir", answer=str(root / ".git"))
    return git


def orch_audit(git, *argv):
    """`orch.sh audit <argv>` in-process at the pinned clock: its exit code,
    a SystemExit's included."""
    try:
        return audit.run(list(argv), git=git, env={}, clock=lambda: PINNED)
    except SystemExit as died:
        return died.code


def run_dir(root, kind):
    return root / ".orchestrator" / "audit" / ("%s-%s" % (kind, STAMP))


def exclude_of(root):
    return root / ".git" / "info" / "exclude"


@pytest.mark.parametrize("kind", ["code", "docs", "tests"])
def test_begin_makes_the_kind_s_run_directory_and_prints_its_absolute_path(root, capsys, kind):
    assert orch_audit(checkout_git(root), "begin", kind) == 0

    assert capsys.readouterr() == ("%s\n" % run_dir(root, kind), "")
    assert run_dir(root, kind).is_dir()


def test_begin_records_the_kind_and_the_head_commit(root, capsys):
    orch_audit(checkout_git(root), "begin", "docs")

    assert (run_dir(root, "docs") / "record").read_text() == "kind docs\ncommit %s\n" % HEAD


def test_begin_makes_a_missing_info_directory_and_excludes_the_plugin_s_directories(root, capsys):
    assert orch_audit(checkout_git(root), "begin", "code") == 0

    assert exclude_of(root).read_text() == ".orchestrator/\n.scratch/\n"


def test_an_exclude_file_s_unterminated_last_line_is_ended_before_the_lines_added(root, capsys):
    exclude_of(root).parent.mkdir()
    exclude_of(root).write_text("build")

    assert orch_audit(checkout_git(root), "begin", "code") == 0

    assert exclude_of(root).read_text() == "build\n.orchestrator/\n.scratch/\n"


@pytest.mark.parametrize("before, after", [
    (".scratch/\n", ".scratch/\n.orchestrator/\n"),
    (".orchestrator/\n.scratch/", ".orchestrator/\n.scratch/"),
], ids=["one-present", "both-present"])
def test_a_line_already_in_the_exclude_file_is_not_added_again(root, capsys, before, after):
    exclude_of(root).parent.mkdir()
    exclude_of(root).write_text(before)

    assert orch_audit(checkout_git(root), "begin", "tests") == 0

    assert exclude_of(root).read_text() == after


@pytest.mark.parametrize("argv", [
    ["begin"], ["begin", "bogus"], ["begin", "code", "extra"], ["begin", "code "], ["bogus"], [],
], ids=["no-kind", "unknown-kind", "extra-word", "spaced-kind", "unknown-verb", "no-verb"])
def test_a_refused_begin_prints_the_usage_naming_every_form_and_makes_nothing(root, capsys, argv):
    assert orch_audit(checkout_git(root), *argv) == 1

    assert capsys.readouterr() == ("", USAGE)
    assert not (root / ".orchestrator").exists()
    assert not exclude_of(root).exists()


def test_a_checkout_with_no_head_commit_is_refused_and_makes_nothing(root, capsys):
    git = FakeGit(toplevel=str(root))
    git.seed("git_common_dir", answer=str(root / ".git"))

    assert orch_audit(git, "begin", "code") == 1

    assert capsys.readouterr() == ("", "orch: cannot read the HEAD commit\n")
    assert not (root / ".orchestrator").exists()


def test_an_existing_run_directory_is_never_reused(root, capsys):
    git = checkout_git(root)
    orch_audit(git, "begin", "code")
    (run_dir(root, "code") / "area-1.md").write_text("kept")
    capsys.readouterr()

    assert orch_audit(git, "begin", "code") == 1

    assert capsys.readouterr() == (
        "", "orch: the audit run directory already exists: %s\n" % run_dir(root, "code"))
    assert (run_dir(root, "code") / "area-1.md").read_text() == "kept"


def test_a_run_directory_that_cannot_be_made_is_refused(root, capsys):
    (root / ".orchestrator").write_text("a file in the way")

    assert orch_audit(checkout_git(root), "begin", "code") == 1

    assert capsys.readouterr() == (
        "", "orch: cannot make the audit run directory %s\n" % run_dir(root, "code"))


def test_an_unwritable_exclude_file_fails_begin_and_leaves_no_run_directory(root, capsys):
    exclude_of(root).mkdir(parents=True)

    assert orch_audit(checkout_git(root), "begin", "tests") == 1

    assert capsys.readouterr() == ("", (
        "orch: cannot add .orchestrator/, .scratch/ to the git exclude file %s\n"
        % exclude_of(root)))
    assert os.listdir(str(root / ".orchestrator" / "audit")) == []


class RecordBlockedGit(FakeGit):
    """A checkout whose run directory's record path is taken by a directory
    once the run directory is made: the exclude write's common-dir read,
    which comes between the two, puts it there."""

    def git_common_dir(self):
        (run_dir(Path(self.root), "code") / "record").mkdir(exist_ok=True)
        return super().git_common_dir()


def test_a_failed_record_write_removes_the_run_directory_and_keeps_the_exclude_lines(root, capsys):
    git = checkout_git(root, RecordBlockedGit)

    assert orch_audit(git, "begin", "code") == 1

    assert capsys.readouterr() == (
        "", "orch: cannot write the audit run record in %s\n" % run_dir(root, "code"))
    assert not run_dir(root, "code").exists()
    assert exclude_of(root).read_text() == ".orchestrator/\n.scratch/\n"


def test_begin_leaves_an_active_flow_s_state_untouched(root, capsys):
    state = root / ".orchestrator" / "state.json"
    state.parent.mkdir()
    state.write_text('{"phase": "implement"}\n')

    assert orch_audit(checkout_git(root), "begin", "docs") == 0

    assert state.read_text() == '{"phase": "implement"}\n'
