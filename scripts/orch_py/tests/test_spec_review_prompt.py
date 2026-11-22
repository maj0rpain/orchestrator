"""The spec-review noun's prompt verb, run in-process against FakeGit and,
for the Fidelity lens under autopilot, the gh fake on a store seeded as the
bash fake_* helpers seed it, with the checkout, its round directories, its
state.json and its handoff and scratch folders under tmp_path - each call
checked by its stdout, its exit code and its `orch:` line, as the bash
spec-review prompt answers. The plan handoff is the path `handoff path spec`
gives: the file adapter's, and under autopilot the comment adapter's copy of
the issue's live plan handoff comment."""
from __future__ import annotations

import json

import pytest

from conftest import orch_spec_review, read

AUTOPILOT = {"ORCH_AUTOPILOT": "1"}
UNKNOWN = ("orch: unknown lens 'clarity'"
           " (want one of: fidelity consistency testability implementability)\n")
CREATED = "2026-01-01T00:00:00Z"


def standalone(root):
    return root / ".orchestrator" / "spec-review" / "14"


def flow_round(root):
    return root / ".orchestrator" / "spec-rounds" / "1"


def fetched(directory):
    """A round directory as the session leaves it after fetching: the body
    and the comments, nothing carried."""
    directory.mkdir(parents=True)
    (directory / "spec.md").write_text("body\n")
    (directory / "comments.md").write_text("")
    return directory


def plan_file(root):
    path = root / ".orchestrator" / "handoff" / "01-plan.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("## Decisions\n- one\n")
    return path


def flow(root, issue=14):
    state = root / ".orchestrator" / "state.json"
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps({"slug": "x", "phase": "spec", "issue": issue,
                                 "branch": None}) + "\n")


def prompt(root, *args, seed=None, env=None):
    return orch_spec_review(root, "prompt", *(str(a) for a in args), seed=seed, env=env)


# --- each lens's lines ------------------------------------------------------------


def test_round_1_implementability_prints_every_line_in_order(root, capsys):
    d = fetched(standalone(root))

    assert prompt(root, d, "implementability") == 0

    assert capsys.readouterr() == (
        "Spec body: {d}/spec.md\nComments: {d}/comments.md\nRepo root: {r}\n"
        "Previous map: none\nMap file: {d}/map-implementability.md\nSettled: none\n"
        "Findings file: {d}/lens-implementability.md\n".format(d=d, r=root), "")


def test_a_later_round_names_the_carried_map_and_settled_file_under_a_trailing_slash(
        root, capsys):
    d = fetched(standalone(root))
    (d / "map-implementability.md").write_text("map\n")
    (d / "settled.md").write_text("settled\n")

    assert prompt(root, "%s/" % d, "implementability") == 0

    lines = capsys.readouterr().out.splitlines()
    assert "Previous map: %s/map-implementability.md" % d in lines
    assert "Map file: %s/map-implementability.md" % d in lines
    assert "Settled: %s/settled.md" % d in lines


def test_consistency_with_no_glossary_and_no_adr_directory_prints_none(root, capsys):
    d = fetched(standalone(root))

    assert prompt(root, d, "consistency") == 0

    assert capsys.readouterr().out == (
        "Spec body: {d}/spec.md\nComments: {d}/comments.md\nGlossary: none\n"
        "ADR directory: none\nSettled: none\nFindings file: {d}/lens-consistency.md\n"
        .format(d=d))


def test_consistency_names_the_glossary_match_the_adr_directory_and_the_settled_file(
        root, capsys):
    d = fetched(standalone(root))
    (d / "glossary.md").write_text("terms\n")
    (root / "docs" / "adr").mkdir(parents=True)
    (d / "settled.md").write_text("settled\n")

    assert prompt(root, d, "consistency") == 0

    assert capsys.readouterr().out == (
        "Spec body: {d}/spec.md\nComments: {d}/comments.md\nGlossary: {d}/glossary.md\n"
        "ADR directory: {r}/docs/adr/\nSettled: {d}/settled.md\n"
        "Findings file: {d}/lens-consistency.md\n".format(d=d, r=root))


def test_testability_prints_its_lines_in_order(root, capsys):
    d = fetched(standalone(root))

    assert prompt(root, d, "testability") == 0

    assert capsys.readouterr().out == (
        "Spec body: {d}/spec.md\nComments: {d}/comments.md\nRepo root: {r}\nSettled: none\n"
        "Findings file: {d}/lens-testability.md\n".format(d=d, r=root))


def test_a_relative_directory_is_printed_absolute(root, capsys, monkeypatch):
    d = fetched(standalone(root))
    monkeypatch.chdir(root / ".orchestrator")

    assert prompt(root, "spec-review/14", "testability") == 0

    assert capsys.readouterr().out.endswith("Findings file: %s/lens-testability.md\n" % d)


# --- the refusals -------------------------------------------------------------------


@pytest.mark.parametrize("args", [("dir",), (), ("dir", "testability", "x")],
                         ids=["one", "none", "three"])
def test_anything_but_a_directory_and_a_lens_is_refused_with_the_usage(root, capsys, args):
    d = fetched(standalone(root))

    assert prompt(root, *(d if a == "dir" else a for a in args)) == 1

    assert capsys.readouterr() == ("", "orch: usage: orch.sh spec-review prompt <dir> <lens>\n")


def test_an_unknown_lens_is_refused_naming_the_four(root, capsys):
    assert prompt(root, root / "nowhere", "clarity") == 1

    assert capsys.readouterr() == ("", UNKNOWN)


def test_a_missing_directory_is_refused_naming_it(root, capsys):
    assert prompt(root, root / "nowhere", "testability") == 1

    assert capsys.readouterr() == ("", "orch: no such directory: %s/nowhere\n" % root)


def test_a_directory_with_no_spec_body_is_refused(root, capsys):
    d = fetched(standalone(root))
    (d / "spec.md").unlink()

    assert prompt(root, d, "testability") == 1

    assert capsys.readouterr() == (
        "", "orch: no spec body: %s/spec.md does not exist - fetch it first\n" % d)


def test_a_directory_with_no_comments_file_is_refused(root, capsys):
    d = fetched(standalone(root))
    (d / "comments.md").unlink()

    assert prompt(root, d, "testability") == 1

    assert capsys.readouterr() == (
        "", "orch: no comments file: %s/comments.md does not exist - fetch it first\n" % d)


# --- Fidelity and the plan handoff ------------------------------------------------------

OUTSIDE = ("orch: the Fidelity lens runs only in a flow's spec review: {d} is not under"
           " {r}/.orchestrator/spec-rounds/\n")


def test_fidelity_in_a_flow_round_directory_names_the_plan_handoff_file(root, capsys):
    d = fetched(flow_round(root))
    plan = plan_file(root)

    assert prompt(root, d, "fidelity") == 0

    assert capsys.readouterr() == (
        "Spec body: {d}/spec.md\nComments: {d}/comments.md\nPlan handoff: {p}\nSettled: none\n"
        "Findings file: {d}/lens-fidelity.md\n".format(d=d, p=plan), "")


def test_fidelity_with_no_plan_handoff_file_dies_naming_it(root, capsys):
    d = fetched(flow_round(root))

    assert prompt(root, d, "fidelity") == 1

    assert capsys.readouterr() == (
        "", "orch: no plan handoff for the Fidelity prompt: %s/.orchestrator/handoff/01-plan.md"
            " does not exist\n" % root)


@pytest.mark.parametrize("held_elsewhere", [False, True], ids=["no-flow", "flow-on-99"])
def test_fidelity_in_a_standalone_review_s_directory_is_refused(root, capsys, held_elsewhere):
    d = fetched(standalone(root))
    plan_file(root)
    if held_elsewhere:
        flow(root, 99)

    assert prompt(root, d, "fidelity") == 1

    assert capsys.readouterr() == ("", OUTSIDE.format(d=d, r=root))


def plan_comment(seed, body="<!-- orch:handoff 01-plan -->\n## Decisions\n- from the comment",
                 association=""):
    seed.comment(14, "alice", CREATED, body, association)


def scratch_plan(root):
    return root / ".orchestrator" / "scratch" / "01-plan.md"


def autopilot_round(root, seed):
    seed.issue(14, "open")
    flow(root)
    return fetched(flow_round(root))


def test_under_autopilot_the_plan_handoff_is_read_from_its_comment_once(root, seed, capsys):
    d = autopilot_round(root, seed)
    seed.comment(14, "alice", CREATED, "<!-- orch:handoff 01-plan -->\nolder")
    plan_comment(seed)
    seed.comment(14, "bob", CREATED, "an unmarked reply")

    assert prompt(root, d, "fidelity", seed=seed, env=AUTOPILOT) == 0

    out, err = capsys.readouterr()
    assert (out.splitlines()[2], err) == ("Plan handoff: %s" % scratch_plan(root), "")
    assert scratch_plan(root).read_text() == "## Decisions\n- from the comment\n"
    assert read(seed.store, "comment_reads") == "x\n"


def test_an_untrusted_comment_dropped_on_the_way_says_nothing_when_the_plan_is_found(
        root, seed, capsys):
    d = autopilot_round(root, seed)
    seed.comment(14, "mallory", CREATED, "<!-- orch:handoff 01-plan -->\nforged", "NONE")
    plan_comment(seed)

    assert prompt(root, d, "fidelity", seed=seed, env=AUTOPILOT) == 0

    assert capsys.readouterr().err == ""
    assert scratch_plan(root).read_text() == "## Decisions\n- from the comment\n"


@pytest.mark.parametrize("comments", [
    (),
    ("<!-- orch:handoff 01-plan -->\nplan", "<!-- orch:handoff 01-plan retired -->\nRetired."),
    ("<!-- orch:handoff 02-spec -->\nnot the plan",),
    ("<!-- orch:handoff 01-plan github -->\na cause on a handoff is no marker",),
], ids=["none", "retired", "another-handoff", "caused"])
def test_under_autopilot_a_missing_plan_handoff_comment_dies_naming_the_issue(
        root, seed, capsys, comments):
    d = autopilot_round(root, seed)
    stale = scratch_plan(root)
    stale.parent.mkdir(parents=True)
    stale.write_text("a stale copy\n")
    for body in comments:
        seed.comment(14, "alice", CREATED, body)

    assert prompt(root, d, "fidelity", seed=seed, env=AUTOPILOT) == 1

    assert capsys.readouterr() == (
        "", "orch: no plan handoff for the Fidelity prompt: issue #14 has no 01-plan handoff"
            " comment\n")
    assert not stale.exists()


def test_under_autopilot_no_recorded_issue_dies_naming_it(root, seed, capsys):
    d = autopilot_round(root, seed)
    flow(root, None)

    assert prompt(root, d, "fidelity", seed=seed, env=AUTOPILOT) == 1

    assert capsys.readouterr() == (
        "", "orch: no plan handoff for the Fidelity prompt: no issue recorded in state - the"
            " spec phase must publish one first\n")


def test_under_autopilot_no_flow_dies_naming_the_missing_state(root, seed, capsys):
    d = autopilot_round(root, seed)
    (root / ".orchestrator" / "state.json").unlink()

    assert prompt(root, d, "fidelity", seed=seed, env=AUTOPILOT) == 1

    assert capsys.readouterr() == (
        "", "orch: no plan handoff for the Fidelity prompt: no active flow (.orchestrator/"
            "state.json not found). Run /orchestrator:start (or orch-flow's Starting a flow"
            " section) first.\n")


def test_under_autopilot_a_failed_timeline_read_dies_with_gh_s_reason(root, seed, capsys):
    d = autopilot_round(root, seed)
    seed.fail("adapter_issue_comments")

    assert prompt(root, d, "fidelity", seed=seed, env=AUTOPILOT) == 1

    assert capsys.readouterr() == (
        "", "orch: no plan handoff for the Fidelity prompt: gh could not read the comments of"
            " issue #14: fake gh: adapter_issue_comments failed\n")


def test_under_autopilot_a_handoff_copy_not_written_dies_naming_it(root, seed, capsys):
    d = autopilot_round(root, seed)
    plan_comment(seed)
    (root / ".orchestrator" / "scratch").write_text("a file in the way\n")

    assert prompt(root, d, "fidelity", seed=seed, env=AUTOPILOT) == 1

    assert capsys.readouterr() == (
        "", "orch: no plan handoff for the Fidelity prompt: could not write %s\n"
            % scratch_plan(root))


def test_under_autopilot_the_fidelity_refusal_outside_a_flow_comes_first(root, seed, capsys):
    seed.issue(14, "open")
    d = fetched(standalone(root))

    assert prompt(root, d, "fidelity", seed=seed, env=AUTOPILOT) == 1

    assert capsys.readouterr().err == OUTSIDE.format(d=d, r=root)
    assert read(seed.store, "comment_reads") is None
