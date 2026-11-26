"""The primitives of orch.common no concept owns, each as bash's: so far the
move of named files aside into a folder, an integer as bash's test reads
one, and the clean-tree refusal, on FakeGit's status answers."""
from __future__ import annotations

import pytest

from conftest import died_of, files_under
from orch.common import int_as_test_reads, move_files_aside, require_clean_tree
from orch.git import FakeGit, GitFailure


# Each text and what `[ "$text" -eq ... ]` reads it as, None where test
# refuses it with "integer expected" - each answer checked against bash.
@pytest.mark.parametrize("text, value", [
    ("3", 3), (" 3", 3), ("\n3", 3), ("3 ", 3), ("3\t", 3), ("3\n", 3), ("3 \n\n", 3),
    ("3\v", 3), ("+3", 3), ("-0", 0), ("007", 7), ("", None), ("x", None), ("1_0", None),
    ("3x", None), ("٣", None),
])
def test_an_integer_reads_as_bash_s_test_reads_it(text, value):
    assert int_as_test_reads(text) == value


def test_the_named_files_that_exist_move_aside_into_the_folder_made_for_them(tmp_path):
    (tmp_path / "a").write_text("A")
    (tmp_path / "other").write_text("kept")

    move_files_aside(str(tmp_path), str(tmp_path / "aside"), "a file", ["a", "b"])

    assert files_under(tmp_path) == ["aside/a", "other"]
    assert (tmp_path / "aside" / "a").read_text() == "A"


def test_no_folder_is_made_when_none_of_the_named_files_exists(tmp_path):
    move_files_aside(str(tmp_path), str(tmp_path / "aside"), "a file", ["a", "b"])

    assert not (tmp_path / "aside").exists()


def test_a_folder_that_merely_exists_is_moved_into(tmp_path):
    (tmp_path / "aside").mkdir()
    (tmp_path / "aside" / "older").write_text("O")
    (tmp_path / "a").write_text("A")

    move_files_aside(str(tmp_path), str(tmp_path / "aside"), "a file", ["a"])

    assert files_under(tmp_path) == ["aside/a", "aside/older"]


def test_a_folder_already_holding_one_of_the_files_is_refused_before_any_move(
        tmp_path, capsys):
    (tmp_path / "aside").mkdir()
    (tmp_path / "aside" / "b").write_text("old b")
    (tmp_path / "a").write_text("A")
    (tmp_path / "b").write_text("B")

    assert died_of(capsys, lambda: move_files_aside(
        str(tmp_path), str(tmp_path / "aside"), "a retired handoff", ["a", "b"])) == (
        1, "", "orch: %s already holds a retired handoff - refusing to overwrite it\n"
        % (tmp_path / "aside"))
    assert files_under(tmp_path) == ["a", "aside/b", "b"]
    assert (tmp_path / "aside" / "b").read_text() == "old b"


# --- the clean-tree refusal -----------------------------------------------------

WT = "/repo/.orchestrator/worktrees/t5"
DIRTY = "ticket worktree %s is dirty - commit or discard its changes first" % WT


def status(answer):
    """A FakeGit whose status at WT is <answer>."""
    git = FakeGit()
    git.seed("status_at", WT, answer=answer)
    return git


def test_a_clean_tree_passes_the_clean_tree_check(capsys):
    require_clean_tree(status(""), WT, DIRTY)

    assert capsys.readouterr() == ("", "")


def test_a_dirty_tree_dies_with_the_caller_s_message(capsys):
    assert died_of(capsys, lambda: require_clean_tree(status("?? new.txt\n"), WT, DIRTY)) == (
        1, "", "orch: %s\n" % DIRTY)


def test_a_status_that_cannot_run_dies_naming_git_s_first_line_never_read_as_clean(capsys):
    failed = GitFailure(128, "fatal: not a git repository\nsecond\n")

    assert died_of(capsys, lambda: require_clean_tree(status(failed), WT, DIRTY)) == (
        1, "", "orch: git status failed - cannot check the working tree:"
        " fatal: not a git repository\n")
