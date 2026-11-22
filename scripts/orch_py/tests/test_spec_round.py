"""The Python spec module's round helpers, against the golden round
directories of spec_round/ - which the bash spec section reads too, with the
same expected values (ADR-0067) - and its saved-answer lines, and against
round directories under tmp_path, checked by the files they leave, their
`orch:` messages and their exits, as bash's spec_round_* functions answered.

spec_round/states/<name>/ each hold the round files of one state and an
`expected` file naming it; spec_round/answer/ holds the arguments apply
saves (given), what a load reads back (args), and the line each language's
writer writes (python-written, and bash-written, the line bash
spec_round_answer_save wrote before it went with the bash spec-review module)."""
from __future__ import annotations

import os
import shutil
from pathlib import Path

import pytest

from orch import spec
from conftest import died_of

GOLDEN = Path(__file__).resolve().parent / "spec_round"
STATES = sorted(path.name for path in (GOLDEN / "states").iterdir())
FILE_OPTIONS = ("--reasons", "--ticket-reasons", "--host-fallbacks")


def golden_files(name):
    """The round files of the golden state directory <name>, by name, with
    their bytes - its expected file left out."""
    directory = GOLDEN / "states" / name
    return {path.name: path.read_bytes() for path in directory.iterdir()
            if path.name != "expected"}


def files_of(directory):
    return {path.name: path.read_bytes() for path in Path(directory).iterdir()}


def lines(name):
    return (GOLDEN / "answer" / name).read_text().splitlines()


# --- the round's state ---------------------------------------------------------


@pytest.mark.parametrize("name", STATES)
def test_each_golden_round_directory_reads_as_its_expected_state(name):
    directory = GOLDEN / "states" / name

    assert spec.spec_round_state(str(directory)) == (directory / "expected").read_text().strip()


def test_the_golden_states_cover_open_applying_waiting_complete_and_applying_over_waiting():
    assert STATES == ["applying", "applying-over-waiting", "complete", "open", "waiting"]


def test_a_missing_round_directory_is_open(tmp_path):
    assert spec.spec_round_state(str(tmp_path / "nowhere")) == "open"


def test_a_round_holding_fundamental_md_is_held_whatever_its_state():
    assert spec.spec_round_held(str(GOLDEN / "states" / "applying-over-waiting"))
    assert not spec.spec_round_held(str(GOLDEN / "states" / "applying"))


@pytest.mark.parametrize("name", ["apply-answer", "fundamental.md", "round-complete"])
def test_a_dangling_symlink_at_a_round_file_is_no_round_file_as_bash_s_test_e_reads_it(
        tmp_path, name):
    os.symlink(str(tmp_path / "nowhere"), str(tmp_path / name))

    assert spec.spec_round_state(str(tmp_path)) == "open"


def test_a_round_whose_fundamental_md_is_a_dangling_symlink_is_not_held(tmp_path):
    os.symlink(str(tmp_path / "nowhere"), str(tmp_path / "fundamental.md"))

    assert not spec.spec_round_held(str(tmp_path))


def test_hold_leaves_the_waiting_golden_s_files(tmp_path):
    blocks = golden_files("waiting")["fundamental.md"].decode()

    spec.spec_round_hold(str(tmp_path), blocks)

    assert files_of(tmp_path) == golden_files("waiting")
    assert spec.spec_round_state(str(tmp_path)) == "waiting"


def test_hold_writes_the_blocks_byte_for_byte_with_their_trailing_blank_line(tmp_path):
    spec.spec_round_hold(str(tmp_path), "@@ item 1\nbody\n\n")

    assert (tmp_path / "fundamental.md").read_bytes() == b"@@ item 1\nbody\n\n"


def test_hold_that_cannot_write_dies_saying_nothing_reached_github(tmp_path, capsys):
    (tmp_path / "fundamental.md").mkdir()

    code, out, err = died_of(capsys, lambda: spec.spec_round_hold(str(tmp_path), "x"))

    assert (code, out) == (1, "")
    assert err == "orch: could not write %s/fundamental.md - nothing written to GitHub\n" % tmp_path


# --- the round's local tail -------------------------------------------------------

CHANGELOG = golden_files("complete")["settled.md"].decode().rstrip("\n")


def applying_over_waiting(directory):
    """<directory> as a held round's resumed apply leaves it before its tail:
    the saved answer, a file copy and fundamental.md."""
    for name, data in golden_files("applying-over-waiting").items():
        (directory / name).write_bytes(data)
    (directory / "apply-reasons.copy").write_text("reasons\n")


def test_complete_leaves_the_complete_golden_s_files(tmp_path):
    applying_over_waiting(tmp_path)

    spec.spec_round_complete(str(tmp_path), CHANGELOG, "the body of issue #14")

    assert files_of(tmp_path) == golden_files("complete")
    assert spec.spec_round_state(str(tmp_path)) == "complete"


def test_complete_run_again_appends_the_changelog_once(tmp_path):
    applying_over_waiting(tmp_path)
    spec.spec_round_complete(str(tmp_path), CHANGELOG, "x")

    spec.spec_round_complete(str(tmp_path), CHANGELOG, "x")

    assert files_of(tmp_path) == golden_files("complete")


def test_complete_appends_after_an_earlier_round_s_changelog(tmp_path):
    (tmp_path / "settled.md").write_text("## Spec review\n\nRound 1 of 2\n")

    spec.spec_round_complete(str(tmp_path), "## Spec review\n\nRound 2 of 2", "x")

    assert (tmp_path / "settled.md").read_text() == (
        "## Spec review\n\nRound 1 of 2\n## Spec review\n\nRound 2 of 2\n")


LANDED = "the body of issue #14, the changelog comment on issue #14"


@pytest.mark.parametrize("blocked, message", [
    ("settled.md", "could not append the changelog to {d}/settled.md - every GitHub write"
                   " landed: " + LANDED),
    ("fundamental.md", "could not remove {d}/fundamental.md - every GitHub write landed and"
                       " settled.md is appended: " + LANDED),
    ("round-complete", "could not write {d}/round-complete - every GitHub write landed and"
                       " settled.md is appended: " + LANDED),
    ("apply-answer", "could not remove {d}/apply-answer - every GitHub write landed: " + LANDED),
], ids=["settled", "fundamental", "round-complete", "answer"])
def test_each_local_step_of_complete_that_fails_dies_naming_what_landed(
        tmp_path, capsys, blocked, message):
    applying_over_waiting(tmp_path)
    path = tmp_path / blocked
    if path.exists():
        path.unlink()
    path.mkdir()

    code, out, err = died_of(
        capsys, lambda: spec.spec_round_complete(str(tmp_path), CHANGELOG, LANDED))

    assert (code, out, err) == (1, "", "orch: " + message.format(d=tmp_path) + "\n")


def test_complete_s_steps_stop_at_the_first_that_fails(tmp_path, capsys):
    applying_over_waiting(tmp_path)
    (tmp_path / "fundamental.md").unlink()
    (tmp_path / "fundamental.md").mkdir()

    died_of(capsys, lambda: spec.spec_round_complete(str(tmp_path), CHANGELOG, LANDED))

    assert not (tmp_path / "round-complete").exists()
    assert (tmp_path / "apply-answer").exists()
    assert (tmp_path / "settled.md").read_text() == CHANGELOG + "\n"


def test_answer_clear_removes_the_answer_and_every_file_copy(tmp_path):
    applying_over_waiting(tmp_path)
    (tmp_path / "apply-host-fallbacks.copy").write_text("h\n")

    spec.spec_round_answer_clear(str(tmp_path), "x")

    assert sorted(files_of(tmp_path)) == ["fundamental.md"]


# --- the saved answer ---------------------------------------------------------------


@pytest.fixture
def answer_files(tmp_path, monkeypatch):
    """The golden answer's source files, in tmp_path as the working
    directory, beside its round directory `round`."""
    monkeypatch.chdir(tmp_path)
    (tmp_path / "round").mkdir()
    for name, text in (("reasons.md", "1 no\n"), ("ticket reasons.md", "2 later\n"),
                       ("hosts.md", "- none\n")):
        (tmp_path / name).write_text(text)
    return tmp_path


def test_answer_save_writes_the_golden_python_line_and_the_file_copies(answer_files):
    spec.spec_round_answer_save("round", FILE_OPTIONS, lines("given"))

    assert (answer_files / "round" / "apply-answer").read_bytes() \
        == (GOLDEN / "answer" / "python-written").read_bytes()
    assert (answer_files / "round" / "apply-ticket-reasons.copy").read_text() == "2 later\n"
    assert (answer_files / "round" / "apply-host-fallbacks.copy").read_text() == "- none\n"


@pytest.mark.parametrize("writer", ["bash-written", "python-written"])
def test_answer_load_reads_each_golden_line_as_the_saved_arguments(tmp_path, writer):
    shutil.copyfile(str(GOLDEN / "answer" / writer), str(tmp_path / "apply-answer"))

    assert spec.spec_round_answer_load(str(tmp_path)) == lines("args")


def test_answer_save_then_load_gives_back_the_arguments_with_the_copies(answer_files):
    spec.spec_round_answer_save("round", FILE_OPTIONS, lines("given"))

    assert spec.spec_round_answer_load("round") == lines("args")


def test_answer_save_that_cannot_copy_a_file_dies_before_the_answer_is_written(
        answer_files, capsys):
    code, out, err = died_of(capsys, lambda: spec.spec_round_answer_save(
        "round", FILE_OPTIONS, ["1A", "--reasons", "missing.md"]))

    assert (code, out) == (1, "")
    assert err == ("orch: could not copy missing.md to round/apply-reasons.copy"
                   " - nothing written to GitHub\n")
    assert not (answer_files / "round" / "apply-answer").exists()


def test_answer_save_that_cannot_write_the_answer_dies(answer_files, capsys):
    (answer_files / "round" / "apply-answer").mkdir()

    code, _, err = died_of(
        capsys, lambda: spec.spec_round_answer_save("round", FILE_OPTIONS, ["1A"]))

    assert (code, err) == (
        1, "orch: could not write round/apply-answer - nothing written to GitHub\n")


@pytest.mark.parametrize("line", [
    "$'1A\\n2B' --round 1/2 \n",
    "1A --reasons $'a\\tb' \n",
], ids=["first", "later"])
def test_answer_load_refuses_a_line_bash_wrote_in_ansi_c_quotes(tmp_path, capsys, line):
    (tmp_path / "apply-answer").write_text(line)

    code, out, err = died_of(capsys, lambda: spec.spec_round_answer_load(str(tmp_path)))

    assert (code, out) == (1, "")
    assert err == "orch: %s/apply-answer is unreadable - rerun the round\n" % tmp_path


@pytest.mark.parametrize("line, args", [
    ("\\$\\'x --round 1/2 \n", ["$'x", "--round", "1/2"]),
    ("'$'\"'\"'x' \n", ["$'x"]),
    ("a\\ \\$\\'b \n", ["a $'b"]),
], ids=["escaped", "single-quoted", "mid-word"])
def test_answer_load_reads_a_quoted_or_escaped_dollar_quote_as_text(tmp_path, line, args):
    (tmp_path / "apply-answer").write_text(line)

    assert spec.spec_round_answer_load(str(tmp_path)) == args


@pytest.mark.parametrize("content", [None, "'unclosed \n", "directory"],
                         ids=["missing", "unbalanced", "directory"])
def test_answer_load_refuses_a_missing_unbalanced_or_unreadable_answer(tmp_path, capsys, content):
    if content == "directory":
        (tmp_path / "apply-answer").mkdir()
    elif content is not None:
        (tmp_path / "apply-answer").write_text(content)

    code, _, err = died_of(capsys, lambda: spec.spec_round_answer_load(str(tmp_path)))

    assert (code, err) == (1, "orch: %s/apply-answer is unreadable - rerun the round\n" % tmp_path)


def test_the_saved_answer_s_file_name_is_apply_answer():
    assert spec.spec_round_answer_name() == "apply-answer"


# --- the rounds directory, the reset and the round count -------------------------------


def test_the_rounds_directory_is_under_the_orchestrator_directory():
    assert spec.spec_rounds_dir("/r") == "/r/.orchestrator/spec-rounds"


@pytest.mark.parametrize("directory, inside", [
    ("/r/.orchestrator/spec-rounds/1", True),
    ("/r/.orchestrator/spec-rounds/1/", True),
    ("/r/.orchestrator/spec-rounds/1/deeper", True),
    ("/r/.orchestrator/spec-rounds", False),
    ("/r/.orchestrator/spec-rounds/", False),
    ("/r/.orchestrator/spec-rounds-x/1", False),
    ("/r/.orchestrator/spec-review/14", False),
])
def test_a_directory_is_in_the_flow_only_under_the_rounds_directory(directory, inside):
    assert spec.spec_round_in_flow(directory, "/r/.orchestrator/spec-rounds") is inside


def seeded(directory):
    (directory / "sub").mkdir(parents=True)
    (directory / "sub" / "changelog.md").write_text("stale\n")
    (directory / "spec.md").write_text("stale\n")
    (directory / "map-implementability.md").write_text("map\n")
    (directory / "settled.md").write_text("settled\n")


def test_dir_reset_wipes_the_directory_whole(tmp_path):
    seeded(tmp_path / "14")

    spec.spec_round_dir_reset(str(tmp_path / "14"))

    assert os.listdir(str(tmp_path / "14")) == []


def test_dir_reset_with_carry_keeps_only_the_map_and_the_settled_file(tmp_path):
    seeded(tmp_path / "14")

    spec.spec_round_dir_reset(str(tmp_path / "14"), carry=True)

    assert files_of(tmp_path / "14") == {"map-implementability.md": b"map\n",
                                         "settled.md": b"settled\n"}


@pytest.mark.parametrize("carry", [False, True])
def test_dir_reset_creates_a_directory_never_there(tmp_path, carry):
    spec.spec_round_dir_reset(str(tmp_path / "a" / "14"), carry=carry)

    assert os.listdir(str(tmp_path / "a" / "14")) == []


def test_dir_reset_that_cannot_make_the_directory_dies_naming_it(tmp_path, capsys):
    (tmp_path / "a").write_text("a file\n")

    code, _, err = died_of(capsys, lambda: spec.spec_round_dir_reset(str(tmp_path / "a" / "14")))

    assert (code, err) == (1, "orch: could not reset the round directory %s/a/14\n" % tmp_path)


@pytest.mark.parametrize("arg, k, n", [("1/2", 1, 2), ("2/2", 2, 2), ("10/12", 10, 12)])
def test_count_parse_reads_a_round_and_the_round_count(arg, k, n):
    assert spec.spec_round_count_parse(arg) == (k, n)


@pytest.mark.parametrize("arg", ["", "1", "0/2", "01/2", "1/02", "a/2", "1/2/3", "-1/2", "1/"])
def test_count_parse_refuses_what_is_not_two_positive_whole_numbers(capsys, arg):
    code, _, err = died_of(capsys, lambda: spec.spec_round_count_parse(arg))

    assert (code, err) == (1, "orch: want <k>/<n>, a round and the round count, two positive"
                              " whole numbers, got: %s\n" % arg)


def test_count_parse_refuses_a_round_past_the_count(capsys):
    code, _, err = died_of(capsys, lambda: spec.spec_round_count_parse("3/2"))

    assert (code, err) == (1, "orch: round 3 is past the round count 2\n")
