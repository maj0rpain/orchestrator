"""The primitives of orch.common no concept owns, each as bash common.sh's:
so far the move of named files aside into a folder."""
from __future__ import annotations

from conftest import died_of
from orch.common import move_files_aside


def files_under(path):
    """Every file under <path>, by its path relative to it, sorted."""
    return sorted(str(p.relative_to(path)) for p in path.rglob("*") if p.is_file())


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
