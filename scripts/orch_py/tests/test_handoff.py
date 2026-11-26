"""The handoff module's phase table against the bash phase table it copies,
the handoffs a phase has due and those a step back makes stale, and the
retire a redo sets the stale ones aside with, in each Handoff store."""
from __future__ import annotations

import re
from pathlib import Path

from conftest import GH_502, comments_of, died_of, fake, flow_state, orch_files, read
from orch.handoff import PHASE_TABLE, handoff_retire, handoffs_due, handoffs_written_from

HANDOFF_SH = Path(__file__).resolve().parents[2] / "orch" / "handoff.sh"


def test_the_phase_table_is_the_bash_phase_table_row_for_row():
    table = re.search(r"^readonly PHASE_TABLE='(.*?)'$", HANDOFF_SH.read_text(), re.M | re.S)

    assert table is not None
    rows = [row.split("|") for row in table.group(1).split("\n")]
    assert [(phase, handoff, writer, tuple(sections.split(";")) if sections else ())
            for phase, handoff, writer, sections in rows] == list(PHASE_TABLE)


def test_the_handoffs_due_at_a_phase_are_those_of_every_row_up_to_it():
    assert handoffs_due("spec") == ["01-plan.md"]
    assert handoffs_due("review") == ["01-plan.md", "02-spec.md", "03-implement.md"]
    assert handoffs_due("plan") == []


def test_the_handoffs_a_step_back_makes_stale_are_those_its_phase_or_a_later_one_wrote():
    assert handoffs_written_from("plan") == ["01-plan.md", "02-spec.md", "03-implement.md"]
    assert handoffs_written_from("spec") == ["02-spec.md", "03-implement.md"]
    assert handoffs_written_from("implement") == ["03-implement.md"]
    assert handoffs_written_from("review") == []
    assert handoffs_written_from("done") == []


def no_gh():
    raise AssertionError("the file adapter reaches no gh")


def test_the_file_retire_moves_each_named_handoff_there_into_its_label_s_folder(root):
    directory = orch_files(root, "handoff", "01-plan.md", "02-spec.md")

    handoff_retire("pre-redo-1", ["02-spec.md", "03-implement.md"], no_gh, {}, str(root))

    assert sorted(str(p.relative_to(directory)) for p in directory.rglob("*.md")) == [
        "01-plan.md", "pre-redo-1/02-spec.md"]


def test_the_file_retire_refuses_a_folder_already_holding_a_named_handoff(root, capsys):
    directory = orch_files(root, "handoff", "02-spec.md", "03-implement.md")
    (directory / "pre-redo-1").mkdir()
    (directory / "pre-redo-1" / "03-implement.md").write_text("an earlier attempt's")

    assert died_of(capsys, lambda: handoff_retire(
        "pre-redo-1", ["02-spec.md", "03-implement.md"], no_gh, {}, str(root))) == (
        1, "", "orch: %s/pre-redo-1 already holds a retired handoff - refusing to overwrite it\n"
        % directory)
    assert sorted(p.name for p in directory.glob("*.md")) == ["02-spec.md", "03-implement.md"]
    assert (directory / "pre-redo-1" / "03-implement.md").read_text() == "an earlier attempt's"


AUTOPILOT = {"ORCH_AUTOPILOT": "1"}
RETIRED_TEXT = "Retired by an orchestrator redo: this handoff described work the redo sets aside.\n"
ALL_HANDOFFS = ["01-plan.md", "02-spec.md", "03-implement.md"]


def retired_comment(stem):
    """The comment the comment retire posts for the handoff <stem>."""
    return "<!-- orch:handoff %s retired -->\n" % stem + RETIRED_TEXT


def handoff_comments(seed, *bodies):
    """An autopilot flow's issue #7, carrying each of <bodies> as a
    comment, in order."""
    seed.issue(7, "open")
    for body in bodies:
        seed.comment(7, "someone", "2026-01-01T00:00:00Z", body)


def test_the_comment_retire_posts_a_retired_comment_for_each_live_handoff_alone(
        root, seed):
    flow_state(root, "review", 7)
    handoff_comments(seed, "<!-- orch:handoff 02-spec -->\nthe spec",
                     "<!-- orch:handoff 03-implement -->\nthe attempt",
                     retired_comment("03-implement"))

    handoff_retire("pre-redo-1", ALL_HANDOFFS, lambda: fake(seed), AUTOPILOT, str(root))

    assert comments_of(seed.store, 7)[3:] == [retired_comment("02-spec")]
    assert read(seed.store, "comment_reads") == "x\n"
    assert not (root / ".orchestrator" / "handoff").exists()


def test_the_comment_retire_dies_naming_the_comments_already_posted_and_a_rerun_ends_it(
        root, seed, capsys):
    flow_state(root, "review", 7)
    handoff_comments(seed, "<!-- orch:handoff 01-plan -->\nthe plan",
                     "<!-- orch:handoff 02-spec -->\nthe spec",
                     "<!-- orch:handoff 03-implement -->\nthe attempt")
    seed.fail_after("adapter_issue_comment", 1, GH_502)

    assert died_of(capsys, lambda: handoff_retire(
        "pre-redo-1", ALL_HANDOFFS, lambda: fake(seed), AUTOPILOT, str(root))) == (
        1, "", "orch: could not retire the 02-spec handoff on issue #7: HTTP 502: Bad Gateway"
        " - comments posted: 01-plan; the recorded phase is unchanged, so a re-run retires"
        " the rest\n")
    seed.unfail()
    handoff_retire("pre-redo-1", ALL_HANDOFFS, lambda: fake(seed), AUTOPILOT, str(root))

    assert comments_of(seed.store, 7)[3:] == [
        retired_comment("01-plan"), retired_comment("02-spec"), retired_comment("03-implement")]


def test_the_comment_retire_s_first_failed_post_names_no_comment_posted(root, seed, capsys):
    flow_state(root, "review", 7)
    handoff_comments(seed, "<!-- orch:handoff 03-implement -->\nthe attempt")
    seed.fail("adapter_issue_comment", GH_502)

    assert died_of(capsys, lambda: handoff_retire(
        "pre-redo-1", ["03-implement.md"], lambda: fake(seed), AUTOPILOT, str(root)))[2] == (
        "orch: could not retire the 03-implement handoff on issue #7: HTTP 502: Bad Gateway"
        " - comments posted: none; the recorded phase is unchanged, so a re-run retires"
        " the rest\n")


def test_the_comment_retire_dies_with_gh_s_reason_when_the_comments_cannot_be_read(
        root, seed, capsys):
    flow_state(root, "review", 7)
    handoff_comments(seed)
    seed.fail("adapter_issue_comments", GH_502)

    assert died_of(capsys, lambda: handoff_retire(
        "pre-redo-1", ["03-implement.md"], lambda: fake(seed), AUTOPILOT, str(root))) == (
        1, "", "orch: gh could not read the comments of issue #7: HTTP 502: Bad Gateway\n")


def test_the_comment_retire_requires_the_recorded_issue_even_with_no_handoff_named(
        root, capsys):
    flow_state(root, "review", None)

    assert died_of(capsys, lambda: handoff_retire(
        "pre-redo-1", [], no_gh, AUTOPILOT, str(root))) == (
        1, "", "orch: no issue recorded in state - the spec phase must publish one first\n")


def test_the_comment_retire_with_no_handoff_named_reads_no_comment(root):
    flow_state(root, "review", 7)

    handoff_retire("pre-redo-1", [], no_gh, AUTOPILOT, str(root))
