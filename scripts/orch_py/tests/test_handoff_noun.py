"""The handoff noun's entry, run in-process in a FakeGit checkout under
tmp_path against the gh fake on a tmp_path store - the cases of the deleted
bash handoff sections, each verb's contract as the bash cmd_handoff had it:
`path` through each Handoff store, `validate` (state readable, a missing
state file passing), `section`'s trim and refusals, `post` and `fetch` in an
autopilot session and their refusals in bash's order, every usage line and
the unknown-op refusal. The orch-handoff skill's templates validate."""
from __future__ import annotations

import re
import tempfile
from pathlib import Path

import pytest

from conftest import (AUTOPILOT, CLAUDE, GH_502, comments_of, died_of, fake, flow_state, hold_flow,
                      lines, marker_of, snapshot, state_json, write)
from orch import handoff
from orch.flow_state import STATE_UNREADABLE_MSG
from orch.git import FakeGit

OPS = "path|post|fetch|validate|section"
NAMES = "01-plan|02-spec|03-implement"
NO_ISSUE = "orch: no issue recorded in state - the spec phase must publish one first\n"
OUTSIDE = ("orch: handoff %s is for an autopilot flow (ORCH_AUTOPILOT=1): an interactive flow"
           " keeps its handoffs as files\n")
HANDOFF_SKILL = Path(__file__).resolve().parents[3] / "skills" / "orch-handoff" / "SKILL.md"

# A spec handoff complete with Host fallbacks, and its required headings.
SPEC = lines("## Spec issue", "#7.", "", "## Host fallbacks", "None (Claude Code).")
# A plan handoff complete for an autopilot session, its block included.
PLAN = lines("## Decisions", "Use X.", "", "## Rejected alternatives", "Y, because Z.", "",
             "## Constraints", "Must run offline.", "", "## Open assumptions", "Assumes W.", "",
             "## Host fallbacks", "None (Claude Code).", "", "## Autopilot", "Rounds: 2",
             "Budget: 3")


def orch_handoff(root, seed, *argv, env=None):
    """`orch.sh handoff <argv>` in-process in the checkout at <root>, on
    <seed>'s store, under <env> (Claude Code's plain session when None): its
    exit code."""
    return handoff.run(list(argv), gh=fake(seed), git=FakeGit(toplevel=str(root)),
                       env=CLAUDE if env is None else env)


def handoff_file(root, name, text):
    """<text> written as the handoff <name> in <root>'s handoff directory:
    its path."""
    return write(root, Path(".orchestrator", "handoff", name), raw=text)


def on_issue(seed, *bodies):
    """Issue #7, open, carrying each of <bodies> as a comment, in order."""
    seed.issue(7, "open")
    for i, body in enumerate(bodies):
        seed.comment(7, "someone", "2030-01-01T00:00:%02dZ" % i, body)


def tagged(name, text, tag=""):
    """The comment body of the handoff <name>, <tag>ged, holding <text>."""
    return marker_of("handoff", name, tag) + "\n" + text


# --- the dispatch -------------------------------------------------------------


@pytest.mark.parametrize("argv, shown", [((), "<none>"), (("bogus",), "bogus"), (("",), "<none>")])
def test_an_unknown_op_is_refused_naming_every_op(root, seed, capsys, argv, shown):
    assert died_of(capsys, lambda: orch_handoff(root, seed, *argv)) == (
        1, "", "orch: unknown handoff op: %s (want %s)\n" % (shown, OPS))


@pytest.mark.parametrize("argv, usage", [
    (("path",), "path <phase>"), (("path", "spec", "x"), "path <phase>"),
    (("post", "01-plan"), "post <name> <file>"), (("post", "a", "b", "c"), "post <name> <file>"),
    (("fetch", "01-plan"), "fetch <name> <file>"),
    (("fetch", "a", "b", "c"), "fetch <name> <file>"),
    (("validate",), "validate <file>"), (("validate", "a", "b"), "validate <file>"),
    (("section", "f"), "section <file> <heading>"),
    (("section", "f", "X", "extra"), "section <file> <heading>"),
])
def test_a_verb_given_the_wrong_number_of_arguments_dies_with_its_usage_line(
        root, seed, capsys, argv, usage):
    assert died_of(capsys, lambda: orch_handoff(root, seed, *argv, env=AUTOPILOT)) == (
        1, "", "orch: usage: orch.sh handoff %s\n" % usage)


# --- handoff path -------------------------------------------------------------


@pytest.mark.parametrize("phase, name", [
    ("spec", "01-plan.md"), ("implement", "02-spec.md"), ("review", "03-implement.md")])
def test_path_prints_the_handoff_a_phase_reads_in_the_handoff_directory(
        root, seed, capsys, phase, name):
    path = handoff_file(root, name, SPEC)

    assert orch_handoff(root, seed, "path", phase) == 0
    assert capsys.readouterr() == ("%s\n" % path, "")


def test_path_of_a_handoff_not_yet_written_prints_its_write_target_and_fails(root, seed, capsys):
    assert orch_handoff(root, seed, "path", "spec") == 1
    assert capsys.readouterr() == ("%s/.orchestrator/handoff/01-plan.md\n" % root, "")


@pytest.mark.parametrize("phase", ["bogus", "done"])
def test_path_of_a_phase_with_no_handoff_dies_printing_no_path(root, seed, capsys, phase):
    assert died_of(capsys, lambda: orch_handoff(root, seed, "path", phase)) == (
        1, "", "orch: no handoff defined for phase: %s\n" % phase)


def test_path_in_autopilot_copies_the_live_comment_to_the_scratch_directory(root, seed, capsys):
    flow_state(root, "implement", 7)
    on_issue(seed, tagged("01-plan", "the plan\n"), tagged("02-spec", SPEC))

    assert orch_handoff(root, seed, "path", "implement", env=AUTOPILOT) == 0

    scratch = root / ".orchestrator" / "scratch"
    assert capsys.readouterr() == ("%s/02-spec.md\n" % scratch, "")
    assert (scratch / "02-spec.md").read_text() == SPEC
    assert (scratch / "01-plan.md").read_text() == "the plan\n"


def test_path_in_autopilot_with_no_live_comment_prints_the_scratch_path_then_dies(
        root, seed, capsys):
    flow_state(root, "spec", 7)
    on_issue(seed, tagged("01-plan", "the plan\n"), tagged("01-plan", "", "retired"))

    assert died_of(capsys, lambda: orch_handoff(root, seed, "path", "spec", env=AUTOPILOT)) == (
        1, "%s/.orchestrator/scratch/01-plan.md\n" % root,
        "orch: issue #7 has no 01-plan handoff comment\n")


def test_path_in_autopilot_dies_with_gh_s_reason_when_the_comments_cannot_be_read(
        root, seed, capsys):
    flow_state(root, "spec", 7)
    on_issue(seed)
    seed.fail("adapter_issue_comments", GH_502)

    assert died_of(capsys, lambda: orch_handoff(root, seed, "path", "spec", env=AUTOPILOT)) == (
        1, "", "orch: gh could not read the comments of issue #7: HTTP 502: Bad Gateway\n")


def test_path_in_autopilot_requires_the_recorded_issue(root, seed, capsys):
    flow_state(root, "spec", None)

    assert died_of(capsys, lambda: orch_handoff(root, seed, "path", "spec", env=AUTOPILOT)) == (
        1, "", NO_ISSUE)


def test_path_in_autopilot_with_a_scratch_copy_it_cannot_write_says_so_and_exits_1(
        root, seed, capsys):
    flow_state(root, "spec", 7)
    on_issue(seed, tagged("01-plan", "the plan\n"))
    write(root, Path(".orchestrator", "scratch"), "a file where the directory goes")

    assert died_of(capsys, lambda: orch_handoff(root, seed, "path", "spec", env=AUTOPILOT)) == (
        1, "", "orch: could not write %s/.orchestrator/scratch/01-plan.md\n" % root)


# --- handoff validate ---------------------------------------------------------


def test_validate_reports_every_required_section_ok_for_a_complete_handoff(root, seed, capsys):
    hold_flow(root, phase="implement", host_fallbacks=True)
    path = handoff_file(root, "02-spec.md", SPEC)

    assert orch_handoff(root, seed, "validate", str(path)) == 0
    assert capsys.readouterr() == ("ok    ## Spec issue\nok    ## Host fallbacks\n", "")


def test_validate_fails_naming_a_missing_section(root, seed, capsys):
    hold_flow(root, phase="implement", host_fallbacks=True)
    path = handoff_file(root, "02-spec.md", lines("## Spec issue", "#7."))

    assert orch_handoff(root, seed, "validate", str(path)) == 1
    assert capsys.readouterr() == (
        "ok    ## Spec issue\nFAIL  missing section: ## Host fallbacks\n", "")


def test_validate_of_a_file_that_does_not_exist_is_one_fail_line_and_exit_1(root, seed, capsys):
    missing = root / "02-spec.md"

    assert orch_handoff(root, seed, "validate", str(missing)) == 1
    assert capsys.readouterr() == ("FAIL  handoff not found: %s\n" % missing, "")


def test_validate_with_no_state_file_passes_and_requires_host_fallbacks(root, seed, capsys):
    path = handoff_file(root, "02-spec.md", lines("## Spec issue", "#7."))

    assert orch_handoff(root, seed, "validate", str(path)) == 1
    path.write_text(SPEC)
    assert orch_handoff(root, seed, "validate", str(path)) == 0
    assert capsys.readouterr() == (
        "ok    ## Spec issue\nFAIL  missing section: ## Host fallbacks\n"
        "ok    ## Spec issue\nok    ## Host fallbacks\n", "")


def test_validate_refuses_an_unreadable_state_file(root, seed, capsys):
    path = handoff_file(root, "02-spec.md", SPEC)
    state_json(root).write_text('{"phase": "implement"')

    assert died_of(capsys, lambda: orch_handoff(root, seed, "validate", str(path))) == (
        1, "", "orch: %s\n" % STATE_UNREADABLE_MSG)


def test_validate_in_autopilot_checks_the_plan_s_autopilot_block(root, seed, capsys):
    path = handoff_file(root, "01-plan.md", PLAN)

    assert orch_handoff(root, seed, "validate", str(path), env=AUTOPILOT) == 0
    assert capsys.readouterr().out.splitlines()[-1] == "ok    ## Autopilot"


def skill_template(name):
    """The orch-handoff skill's template for the handoff <name>: the
    markdown fence under its ### `<name>` heading."""
    text = HANDOFF_SKILL.read_text()
    found = re.search(r"^### `%s`.*?^```markdown\n(.*?)^```$" % re.escape(name), text,
                      re.M | re.S)
    assert found is not None
    return found.group(1)


@pytest.mark.parametrize("name", ["01-plan.md", "02-spec.md", "03-implement.md"])
def test_each_orch_handoff_template_validates_when_host_fallbacks_is_required(
        root, seed, capsys, name):
    hold_flow(root, host_fallbacks=True)
    path = handoff_file(root, name, skill_template(name))

    assert orch_handoff(root, seed, "validate", str(path)) == 0, capsys.readouterr().out


# --- handoff section ----------------------------------------------------------


def test_section_prints_the_body_trimmed_of_leading_and_trailing_blank_lines(
        root, seed, capsys):
    path = write(root, "h.md", "## Decisions", "", "", "Use X.", "", "And Y.", "   ", "",
                 "## Constraints", "Must run offline.")

    assert orch_handoff(root, seed, "section", str(path), "Decisions") == 0
    assert orch_handoff(root, seed, "section", str(path), "Constraints") == 0
    assert capsys.readouterr() == ("Use X.\n\nAnd Y.\nMust run offline.\n", "")


def test_section_prints_an_inner_whitespace_only_line_as_an_empty_line(root, seed, capsys):
    path = write(root, "h.md", "## Decisions", "Use X.", "   ", "\t", "And Y.", "## Constraints",
                 "None.")

    assert orch_handoff(root, seed, "section", str(path), "Decisions") == 0
    assert capsys.readouterr() == ("Use X.\n\n\nAnd Y.\n", "")


def test_section_of_a_whitespace_only_section_prints_nothing(root, seed, capsys):
    path = write(root, "h.md", "## Rejected alternatives", "  ", "", "## Constraints", "None.")

    assert orch_handoff(root, seed, "section", str(path), "Rejected alternatives") == 0
    assert capsys.readouterr() == ("", "")


def test_section_reads_a_fenced_copy_of_its_heading_as_body(root, seed, capsys):
    path = write(root, "h.md", "## X", "```", "## X", "quoted", "```", "Real.", "## Y", "Other.")

    assert orch_handoff(root, seed, "section", str(path), "X") == 0
    assert capsys.readouterr() == ("```\n## X\nquoted\n```\nReal.\n", "")


def test_section_of_a_file_that_does_not_exist_dies_naming_it(root, seed, capsys):
    missing = root / "h.md"

    assert died_of(capsys, lambda: orch_handoff(root, seed, "section", str(missing), "X")) == (
        1, "", "orch: handoff not found: %s\n" % missing)


@pytest.mark.parametrize("heading", ["Open questions", "Rejected"])
def test_section_of_a_heading_the_file_lacks_dies_naming_it(root, seed, capsys, heading):
    path = write(root, "h.md", "## Rejected alternatives", "Y.")

    assert died_of(capsys, lambda: orch_handoff(root, seed, "section", str(path), heading)) == (
        1, "", "orch: section not found: ## %s in %s\n" % (heading, path))


def test_section_of_a_repeated_heading_dies_printing_neither_body(root, seed, capsys):
    path = write(root, "h.md", "## X", "First.", "## Y", "Between.", "## X", "Second.")

    assert died_of(capsys, lambda: orch_handoff(root, seed, "section", str(path), "X")) == (
        1, "", "orch: repeated section: ## X in %s\n" % path)


# --- handoff post -------------------------------------------------------------


def test_post_posts_a_valid_handoff_as_the_issue_s_tagged_comment(root, seed, capsys, tmp_path):
    flow_state(root, "spec", 7)
    on_issue(seed)
    path = write(tmp_path, "draft.md", raw=PLAN)

    assert orch_handoff(root, seed, "post", "01-plan", str(path), env=AUTOPILOT) == 0
    assert capsys.readouterr() == ("", "")
    assert comments_of(seed.store, 7) == [tagged("01-plan", PLAN)]


def test_post_refuses_outside_an_autopilot_session_before_any_other_check(root, seed, capsys):
    assert died_of(capsys, lambda: orch_handoff(root, seed, "post", "bogus", "missing.md")) == (
        1, "", OUTSIDE % "post")


def test_post_refuses_an_unknown_name_before_the_file_check(root, seed, capsys):
    assert died_of(capsys, lambda: orch_handoff(
        root, seed, "post", "bogus", "missing.md", env=AUTOPILOT)) == (
        1, "", "orch: unknown handoff name: bogus (want %s)\n" % NAMES)


def test_post_of_a_file_that_does_not_exist_dies_before_the_issue_check(root, seed, capsys):
    missing = root / "missing.md"

    assert died_of(capsys, lambda: orch_handoff(
        root, seed, "post", "01-plan", str(missing), env=AUTOPILOT)) == (
        1, "", "orch: handoff not found: %s\n" % missing)


def test_post_requires_the_recorded_issue_before_validating(root, seed, capsys, tmp_path):
    flow_state(root, "spec", None)
    path = write(tmp_path, "draft.md", "not a plan")

    assert died_of(capsys, lambda: orch_handoff(
        root, seed, "post", "01-plan", str(path), env=AUTOPILOT)) == (1, "", NO_ISSUE)


def test_post_of_an_invalid_handoff_prints_its_fail_lines_and_posts_nothing(
        root, seed, capsys, tmp_path):
    flow_state(root, "spec", 7)
    on_issue(seed)
    before = snapshot(seed.store)
    path = write(tmp_path, "draft.md", "## Decisions", "Only.", "", "## Rejected alternatives",
                 "Y.", "", "## Constraints", "C.", "", "## Open assumptions", "W.", "",
                 "## Host fallbacks", "None.")

    assert died_of(capsys, lambda: orch_handoff(
        root, seed, "post", "01-plan", str(path), env=AUTOPILOT)) == (
        1, "FAIL  missing section: ## Autopilot\n",
        "orch: handoff %s is not valid - nothing posted\n" % path)
    assert snapshot(seed.store) == before


def test_post_with_no_temp_file_for_the_body_posts_nothing(
        root, seed, capsys, tmp_path, monkeypatch):
    flow_state(root, "spec", 7)
    on_issue(seed)
    before = snapshot(seed.store)
    path = write(tmp_path, "draft.md", raw=PLAN)
    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path / "gone"))

    assert died_of(capsys, lambda: orch_handoff(
        root, seed, "post", "01-plan", str(path), env=AUTOPILOT)) == (
        1, "", "orch: could not create a temp file for the handoff comment\n")
    assert snapshot(seed.store) == before


def test_a_post_gh_refuses_exits_1_with_gh_s_reason_leaving_no_temp_file(
        root, seed, capsys, tmp_path, monkeypatch):
    flow_state(root, "spec", 7)
    on_issue(seed)
    path = write(tmp_path, "draft.md", raw=PLAN)
    temp = tmp_path / "temp"
    temp.mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(temp))
    seed.fail("adapter_issue_comment", GH_502)

    assert orch_handoff(root, seed, "post", "01-plan", str(path), env=AUTOPILOT) == 1
    assert capsys.readouterr() == (
        "", "orch: gh could not post the 01-plan handoff on issue #7: HTTP 502: Bad Gateway\n")
    assert comments_of(seed.store, 7) == []
    assert list(temp.iterdir()) == []


# --- handoff fetch ------------------------------------------------------------


def test_fetch_writes_the_newest_tagged_comment_s_body_without_its_marker(
        root, seed, capsys, tmp_path):
    flow_state(root, "spec", 7)
    on_issue(seed, tagged("01-plan", "older\n"), tagged("01-plan", PLAN), "unrelated chatter")
    got = tmp_path / "got.md"

    assert orch_handoff(root, seed, "fetch", "01-plan", str(got), env=AUTOPILOT) == 0
    assert capsys.readouterr() == ("", "")
    assert got.read_text() == PLAN


def test_fetch_refuses_outside_an_autopilot_session_before_any_other_check(root, seed, capsys):
    assert died_of(capsys, lambda: orch_handoff(root, seed, "fetch", "bogus", "got.md")) == (
        1, "", OUTSIDE % "fetch")


def test_fetch_refuses_an_unknown_name_before_the_issue_check(root, seed, capsys):
    assert died_of(capsys, lambda: orch_handoff(
        root, seed, "fetch", "bogus", "got.md", env=AUTOPILOT)) == (
        1, "", "orch: unknown handoff name: bogus (want %s)\n" % NAMES)


def test_fetch_requires_the_recorded_issue(root, seed, capsys):
    flow_state(root, "spec", None)

    assert died_of(capsys, lambda: orch_handoff(
        root, seed, "fetch", "01-plan", "got.md", env=AUTOPILOT)) == (1, "", NO_ISSUE)


@pytest.mark.parametrize("bodies", [
    (), (tagged("02-spec", SPEC),), (tagged("01-plan", PLAN), tagged("01-plan", "", "retired"))],
    ids=["no-comment", "another-handoff", "retired"])
def test_fetch_with_no_live_comment_dies_leaving_an_existing_file_as_it_was(
        root, seed, capsys, tmp_path, bodies):
    flow_state(root, "spec", 7)
    on_issue(seed, *bodies)
    got = write(tmp_path, "got.md", "keep")

    assert died_of(capsys, lambda: orch_handoff(
        root, seed, "fetch", "01-plan", str(got), env=AUTOPILOT)) == (
        1, "", "orch: issue #7 has no 01-plan handoff comment\n")
    assert got.read_text() == "keep\n"


def test_fetch_dies_with_gh_s_reason_when_the_comments_cannot_be_read(
        root, seed, capsys, tmp_path):
    flow_state(root, "spec", 7)
    on_issue(seed)
    seed.fail("adapter_issue_comments", GH_502)

    assert died_of(capsys, lambda: orch_handoff(
        root, seed, "fetch", "01-plan", str(tmp_path / "got.md"), env=AUTOPILOT)) == (
        1, "", "orch: gh could not read the comments of issue #7: HTTP 502: Bad Gateway\n")


def test_fetch_into_a_file_it_cannot_write_says_so_and_exits_1(root, seed, capsys, tmp_path):
    flow_state(root, "spec", 7)
    on_issue(seed, tagged("01-plan", PLAN))
    write(tmp_path, "blocker", "a file where the directory goes")
    got = tmp_path / "blocker" / "got.md"

    assert orch_handoff(root, seed, "fetch", "01-plan", str(got), env=AUTOPILOT) == 1
    assert capsys.readouterr() == ("", "orch: could not write %s\n" % got)
