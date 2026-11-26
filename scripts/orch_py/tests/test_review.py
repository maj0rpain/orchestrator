"""The review concept module's terminal-state read, pinned to bash's
review_terminal_state by the golden review records of tests/review_terminal/:
each case directory holds an `args` file (the iteration and the budget), an
optional state.json and review/ tree, copied into a checkout's .orchestrator/
before the read, and an `expected` file - the classification's lines, then
`status <n>`, `<root>` standing for the checkout's root. Both the bash
review_terminal_state, sourced in a bash child process, and the Python one
must print exactly that (ADR-0067's golden files both languages are tested
against). Beside it, the pieces the read is built from: the record path, the
record's terminal section, the flat-record-gone check, and the redo predicate
and flow-branch names the fallback compares against."""
from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from conftest import bash_sourced, died_of
from orch.branch import branch_name_flow, branch_name_redo
from orch.redo import redo_midway
from orch.review import (review_flat_record_gone, review_record_path, review_record_terminal,
                         review_retire, review_terminal_record, review_terminal_state)

GOLDEN = Path(__file__).resolve().parent / "review_terminal"
SCRIPTS = Path(__file__).resolve().parents[2]
CASES = sorted(path.name for path in GOLDEN.iterdir() if path.is_dir())

# Each case run through the bash review_terminal_state, the modules loaded as
# orch.sh loads them, ROOT, STATE and REVIEW_DIR the checkout's: its lines,
# `status <n>`, then a `--` line and review_flat_record_gone's status.
# redo_midway is loaded from wherever bash keeps it: redo.sh today, review.sh
# once the redo noun is Python.
BASH_RUN = r'''
set -uo pipefail
source "$1"
source "$2"
ROOT="$3"
STATE="$ROOT/.orchestrator/state.json"
REVIEW_DIR="$ROOT/.orchestrator/review"
orch_load state
orch_load handoff
orch_load branch
orch_load review
declare -F redo_midway >/dev/null || orch_load redo
st=0
review_terminal_state "$4" "$5" || st=$?
printf 'status %s\n--\n' "$st"
st=0
review_flat_record_gone "$4" || st=$?
printf '%s\n' "$st"
'''


def case_args(case):
    """The iteration and budget of <case>."""
    return (GOLDEN / case / "args").read_text(encoding="utf-8").split()


def checkout_of(case, tmp_path):
    """A checkout under <tmp_path> holding <case>'s state.json and review/
    tree in its .orchestrator/: its root."""
    root = tmp_path / "repo"
    orch_dir = root / ".orchestrator"
    orch_dir.mkdir(parents=True)
    for name in ("state.json", "review"):
        source = GOLDEN / case / name
        if source.is_dir():
            shutil.copytree(source, orch_dir / name)
        elif source.exists():
            shutil.copy(source, orch_dir / name)
    return root


def expected(case, root):
    """<case>'s expected text, `<root>` read as the checkout's root."""
    return (GOLDEN / case / "expected").read_text(encoding="utf-8").replace("<root>", str(root))


def bash_run(case, root):
    """(the bash classification's text and status line, the bash flat-record-
    gone status) of <case> in the checkout at <root>."""
    out = bash_sourced(SCRIPTS / "flow-state.sh", BASH_RUN, SCRIPTS / "orch" / "common.sh",
                       SCRIPTS / "orch" / "loader.sh", root, *case_args(case))
    classified, gone = out.split("--\n")
    return classified, gone


def python_text(root, i, budget):
    """The Python classification's lines, then `status <n>`, as text."""
    lines, status = review_terminal_state(str(root), i, budget)
    return "".join(line + "\n" for line in lines) + "status %d\n" % status


@pytest.mark.parametrize("case", CASES)
def test_a_golden_review_record_classifies_as_its_expected_lines_and_status_in_both_languages(
        case, tmp_path):
    bash_root = checkout_of(case, tmp_path / "bash")
    python_root = checkout_of(case, tmp_path / "python")

    assert bash_run(case, bash_root)[0] == expected(case, bash_root)
    assert python_text(python_root, *case_args(case)) == expected(case, python_root)


@pytest.mark.parametrize("case", CASES)
def test_the_flat_record_is_gone_for_a_golden_case_exactly_when_bash_says_so(case, tmp_path):
    bash_gone = bash_run(case, checkout_of(case, tmp_path / "bash"))[1]
    i = case_args(case)[0]

    assert review_flat_record_gone(str(checkout_of(case, tmp_path / "python")), i) == \
        (bash_gone == "0\n")


def test_an_iteration_s_record_path_is_its_zero_padded_file_in_a_made_review_directory(tmp_path):
    assert review_record_path(str(tmp_path), "008") == \
        "%s/.orchestrator/review/iteration-08.md" % tmp_path
    assert (tmp_path / ".orchestrator" / "review").is_dir()


def test_an_iteration_that_is_not_a_number_has_no_record_path(tmp_path, capsys):
    assert died_of(capsys, lambda: review_record_path(str(tmp_path), "2a")) == \
        (1, "", "orch: not an iteration number: 2a\n")


def test_a_review_directory_that_cannot_be_made_is_no_record_path(tmp_path, capsys):
    (tmp_path / ".orchestrator").mkdir()
    (tmp_path / ".orchestrator" / "review").write_text("a file\n")

    assert died_of(capsys, lambda: review_record_path(str(tmp_path), "1")) == \
        (1, "", "orch: cannot create the review directory %s/.orchestrator/review\n" % tmp_path)


def test_a_record_s_terminal_section_is_its_text_when_it_holds_more_than_whitespace(tmp_path):
    record = tmp_path / "iteration-01.md"
    record.write_text("## Terminal state\n\nstop - red\n\n\n## Notes\nx\n")

    assert review_record_terminal(str(record)) == "\nstop - red"


@pytest.mark.parametrize("text", ["## Terminal state\n \t\n\n## Notes\nready\n", "## Notes\nready\n"],
                         ids=["blank", "absent"])
def test_a_record_with_no_terminal_text_has_no_terminal_section(tmp_path, text):
    record = tmp_path / "iteration-01.md"
    record.write_text(text)

    assert review_record_terminal(str(record)) is None


def test_a_missing_record_has_no_terminal_section(tmp_path):
    assert review_record_terminal(str(tmp_path / "iteration-01.md")) is None


def test_the_terminal_record_is_the_flat_one_while_it_stands(tmp_path):
    root = checkout_of("pre-redo-fallback", tmp_path)
    flat = root / ".orchestrator" / "review" / "iteration-02.md"
    flat.write_text("## Terminal state\nready\n")

    assert review_terminal_record(str(root), "2") == str(flat)


def test_the_terminal_record_falls_back_to_the_retired_one_while_a_redo_is_half_finished(
        tmp_path):
    root = checkout_of("pre-redo-fallback", tmp_path)

    assert review_terminal_record(str(root), "2") == \
        "%s/.orchestrator/review/pre-redo-1/iteration-02.md" % root


@pytest.mark.parametrize("i", ["0", "", "x", "-1"])
def test_an_iteration_not_above_zero_has_no_flat_record_to_be_gone(tmp_path, i):
    assert review_flat_record_gone(str(tmp_path), i) is False


def test_a_flow_s_branch_is_named_for_its_issue_and_slug():
    assert branch_name_flow("12", "foo-bar") == "orch/12-foo-bar"


def test_a_redo_s_branch_is_the_flow_s_with_its_redo_count():
    assert branch_name_redo("12", "foo", "3") == "orch/12-foo-redo-3"


def test_a_redo_is_midway_while_the_branch_is_its_count_s_redo_name():
    assert redo_midway("12", "foo", "orch/12-foo-redo-2", "2") == "2"


@pytest.mark.parametrize("branch, redo_count", [
    ("orch/12-foo-redo-2", "0"),
    ("orch/12-foo-redo-1", "2"),
    ("orch/12-foo", "2"),
    ("", "2"),
    ("orch/12-foo-redo-x", "x"),
    ("orch/12-foo-redo-", ""),
], ids=["no-redo", "other-count", "flow-branch", "no-branch", "not-a-number", "empty-count"])
def test_a_redo_is_not_midway_unless_its_count_is_above_zero_and_the_branch_is_its_name(
        branch, redo_count):
    assert redo_midway("12", "foo", branch, redo_count) is None


def test_a_slug_that_merely_ends_in_a_redo_name_is_not_midway():
    assert redo_midway("12", "foo-redo-1", "orch/12-foo-redo-1", "1") is None


def review_records(root, *names):
    """Writes each of <names> into <root>'s review directory, holding its own
    name: the directory, a Path."""
    directory = root / ".orchestrator" / "review"
    directory.mkdir(parents=True, exist_ok=True)
    for name in names:
        (directory / name).write_text(name)
    return directory


def test_a_retire_moves_every_iteration_record_into_its_redo_s_folder(tmp_path):
    review = review_records(tmp_path, "iteration-01.md", "iteration-02.md", "notes.md")

    assert review_retire(str(tmp_path), "3") == "%s/pre-redo-3" % review
    assert sorted(str(p.relative_to(review)) for p in review.rglob("*.md")) == [
        "notes.md", "pre-redo-3/iteration-01.md", "pre-redo-3/iteration-02.md"]


def test_a_retire_with_no_record_makes_the_review_directory_and_no_folder(tmp_path):
    assert review_retire(str(tmp_path), "1") == "%s/.orchestrator/review/pre-redo-1" % tmp_path
    assert list((tmp_path / ".orchestrator" / "review").iterdir()) == []


def test_a_retire_resumes_into_the_folder_a_died_run_of_the_same_redo_made(tmp_path):
    review = review_records(tmp_path, "iteration-02.md")
    (review / "pre-redo-1").mkdir()
    (review / "pre-redo-1" / "iteration-01.md").write_text("moved before the death")

    review_retire(str(tmp_path), "1")

    assert sorted(p.name for p in (review / "pre-redo-1").iterdir()) == [
        "iteration-01.md", "iteration-02.md"]


@pytest.mark.parametrize("n", ["", "1a", "-1", " 2"])
def test_a_retire_refuses_what_is_not_a_redo_number(tmp_path, capsys, n):
    review_records(tmp_path, "iteration-01.md")

    assert died_of(capsys, lambda: review_retire(str(tmp_path), n)) == (
        1, "", "orch: not a redo number: %s\n" % n)
    assert (tmp_path / ".orchestrator" / "review" / "iteration-01.md").exists()


def test_a_retire_refuses_a_folder_already_holding_one_of_its_records(tmp_path, capsys):
    review = review_records(tmp_path, "iteration-01.md", "iteration-02.md")
    (review / "pre-redo-1").mkdir()
    (review / "pre-redo-1" / "iteration-02.md").write_text("an earlier loop's")

    assert died_of(capsys, lambda: review_retire(str(tmp_path), "1")) == (
        1, "", "orch: %s/pre-redo-1 already holds a review record - redo_count should only "
        "increase - refusing to overwrite it\n" % review)
    assert sorted(p.name for p in review.glob("iteration-*.md")) == [
        "iteration-01.md", "iteration-02.md"]
    assert (review / "pre-redo-1" / "iteration-02.md").read_text() == "an earlier loop's"
