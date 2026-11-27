"""The review concept module's terminal-state read, pinned by the golden
review records of tests/review_terminal/: each case directory holds an `args`
file (the iteration and the budget), an optional state.json and review/ tree,
copied into a checkout's .orchestrator/ before the read, and an `expected` file
- the classification's lines, then `status <n>`, `<root>` standing for the
checkout's root. The Python read must print exactly that (ADR-0067's golden
files); they were bash review_terminal_state's answers while the bash review
noun stood, and stay the pin now it is gone. Beside it, the pieces the read is
built from: the record path, the record's terminal section, the
flat-record-gone check, and the redo predicate and flow-branch names the
fallback compares against."""
from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from conftest import died_of, orch_files
from orch.branch import branch_name_flow, branch_name_redo
from orch.redo import redo_midway
from orch.review import (review_flat_record_gone, review_record_path, review_record_terminal,
                         review_retire, review_terminal_record, review_terminal_state)

GOLDEN = Path(__file__).resolve().parent / "review_terminal"
CASES = sorted(path.name for path in GOLDEN.iterdir() if path.is_dir())
# The golden cases whose flat record is gone, as bash review_flat_record_gone
# answered them while the bash review noun stood.
FLAT_GONE = frozenset({
    "fallback-state-unread", "missing-at-budget", "missing-before-budget", "not-midway",
    "pre-redo-fallback", "pre-redo-missing"})


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


def python_text(root, i, budget):
    """The Python classification's lines, then `status <n>`, as text."""
    lines, status = review_terminal_state(str(root), i, budget)
    return "".join(line + "\n" for line in lines) + "status %d\n" % status


@pytest.mark.parametrize("case", CASES)
def test_a_golden_review_record_classifies_as_its_expected_file_says(case, tmp_path):
    root = checkout_of(case, tmp_path)

    assert python_text(root, *case_args(case)) == expected(case, root)


@pytest.mark.parametrize("case", CASES)
def test_a_golden_review_record_s_flat_record_is_gone_as_bash_answered(case, tmp_path):
    root = checkout_of(case, tmp_path)

    assert review_flat_record_gone(str(root), case_args(case)[0]) == (case in FLAT_GONE)


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


def test_a_retire_moves_every_iteration_record_into_its_redo_s_folder(tmp_path):
    review = orch_files(tmp_path, "review", "iteration-01.md", "iteration-02.md", "notes.md")

    assert review_retire(str(tmp_path), "3") == "%s/pre-redo-3" % review
    assert sorted(str(p.relative_to(review)) for p in review.rglob("*.md")) == [
        "notes.md", "pre-redo-3/iteration-01.md", "pre-redo-3/iteration-02.md"]


def test_a_retire_with_no_record_makes_the_review_directory_and_no_folder(tmp_path):
    assert review_retire(str(tmp_path), "1") == "%s/.orchestrator/review/pre-redo-1" % tmp_path
    assert list((tmp_path / ".orchestrator" / "review").iterdir()) == []


def test_a_retire_resumes_into_the_folder_a_died_run_of_the_same_redo_made(tmp_path):
    review = orch_files(tmp_path, "review", "iteration-02.md")
    (review / "pre-redo-1").mkdir()
    (review / "pre-redo-1" / "iteration-01.md").write_text("moved before the death")

    review_retire(str(tmp_path), "1")

    assert sorted(p.name for p in (review / "pre-redo-1").iterdir()) == [
        "iteration-01.md", "iteration-02.md"]


@pytest.mark.parametrize("n", ["", "1a", "-1", " 2"])
def test_a_retire_refuses_what_is_not_a_redo_number(tmp_path, capsys, n):
    orch_files(tmp_path, "review", "iteration-01.md")

    assert died_of(capsys, lambda: review_retire(str(tmp_path), n)) == (
        1, "", "orch: not a redo number: %s\n" % n)
    assert (tmp_path / ".orchestrator" / "review" / "iteration-01.md").exists()


def test_a_retire_refuses_a_folder_already_holding_one_of_its_records(tmp_path, capsys):
    review = orch_files(tmp_path, "review", "iteration-01.md", "iteration-02.md")
    (review / "pre-redo-1").mkdir()
    (review / "pre-redo-1" / "iteration-02.md").write_text("an earlier loop's")

    assert died_of(capsys, lambda: review_retire(str(tmp_path), "1")) == (
        1, "", "orch: %s/pre-redo-1 already holds a review record - redo_count should only "
        "increase - refusing to overwrite it\n" % review)
    assert sorted(p.name for p in review.glob("iteration-*.md")) == [
        "iteration-01.md", "iteration-02.md"]
    assert (review / "pre-redo-1" / "iteration-02.md").read_text() == "an earlier loop's"
