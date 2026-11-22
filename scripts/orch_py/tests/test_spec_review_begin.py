"""The spec-review noun's begin verb and its top-level refusal, run
in-process against FakeGit, with the checkout, its state.json and its
.orchestrator/spec-review/<n>/ directory under tmp_path, each checked by its
stdout, its exit code, its `orch:` message and the files it leaves - as the
bash spec-review begin answered."""
from __future__ import annotations

import json
import os

import pytest

from conftest import orch_spec_review

USAGE = "orch: usage: orch.sh spec-review begin <n> [--carry]\n"
ON_CLAUDE = {"CLAUDECODE": "1"}


@pytest.fixture
def root(tmp_path):
    path = tmp_path.resolve() / "repo"
    path.mkdir()
    return path


def review_dir(root, n="14"):
    return root / ".orchestrator" / "spec-review" / n


def state_of(root):
    return root / ".orchestrator" / "state.json"


def flow(root, phase, issue):
    state_of(root).parent.mkdir(parents=True, exist_ok=True)
    state_of(root).write_text(
        json.dumps({"slug": "x", "phase": phase, "issue": issue, "branch": None}) + "\n")


def seed_review(root):
    """A round directory holding a map, a settled file and the round's other
    files, nested ones included."""
    d = review_dir(root)
    (d / "sub").mkdir(parents=True, exist_ok=True)
    (d / "map-implementability.md").write_text("map\n")
    (d / "settled.md").write_text("## Spec review\nRound 1 of 2\n")
    (d / "spec.md").write_text("stale\n")
    (d / "lens-implementability.md").write_text("stale\n")
    (d / "sub" / "changelog.md").write_text("stale\n")


def entries(root, n="14"):
    return sorted(os.listdir(str(review_dir(root, n))))


def begin(root, *args, env=None):
    return orch_spec_review(root, "begin", *args, env=env)


# --- the refusals before anything is written ----------------------------------


@pytest.mark.parametrize("args", [
    (), ("14", "15"), ("14", "--carry-map"), ("--carry", "14"), ("14", "--carry", "--carry"),
    ("14", "--carry", "15"),
], ids=["none", "two", "carry-map", "carry-first", "carry-twice", "carry-then-more"])
def test_begin_refuses_anything_but_a_number_and_carry_with_the_usage(root, capsys, args):
    seed_review(root)

    assert begin(root, *args) == 1

    assert capsys.readouterr() == ("", USAGE)
    assert (review_dir(root) / "spec.md").read_text() == "stale\n"


@pytest.mark.parametrize("args", [("abc",), ("14x",), ("../14",), ("",), ("abc", "--carry")])
def test_begin_refuses_an_issue_that_is_not_a_plain_number(root, capsys, args):
    seed_review(root)

    assert begin(root, *args) == 1

    assert capsys.readouterr() == (
        "", "orch: issue must be a plain issue number, got: %s\n" % args[0])
    assert (review_dir(root) / "spec.md").read_text() == "stale\n"


@pytest.mark.parametrize("op", ["wipe", ""])
def test_an_op_the_noun_does_not_have_is_refused_naming_the_ones_it_does(root, capsys, op):
    assert orch_spec_review(root, *((op,) if op else ())) == 1

    assert capsys.readouterr() == ("", "orch: unknown spec-review op: %s"
                                   " (want begin|check|apply|wait|prompt)\n" % (op or "<none>"))


# --- the flow guard --------------------------------------------------------------

HOLDS = {
    "spec": "the active flow holds issue #14 at phase spec - the flow's own spec phase will"
            " review it; run %s",
    "implement": "the active flow holds issue #14 at phase implement - the ticket subagents"
                 " build from this spec, so it cannot change behind the flow; run %s to step"
                 " back to the spec phase",
    "review": "the active flow holds issue #14 at phase review - the ticket subagents build"
              " from this spec, so it cannot change behind the flow; run %s to step back to"
              " the spec phase",
}
COMMANDS = {
    ("spec", False): "/orchestrator:next (or orch-flow's Next phase section)",
    ("spec", True): "/orchestrator:next",
    ("implement", False): "/orchestrator:redo (or orch-flow's Redo section)",
    ("implement", True): "/orchestrator:redo",
    ("review", False): "/orchestrator:redo (or orch-flow's Redo section)",
    ("review", True): "/orchestrator:redo",
}


@pytest.mark.parametrize("on_claude", [False, True], ids=["off-claude", "on-claude"])
@pytest.mark.parametrize("carry", [(), ("--carry",)], ids=["plain", "carry"])
@pytest.mark.parametrize("phase", ["spec", "implement", "review"])
def test_an_active_flow_holding_the_issue_refuses_it_naming_the_next_step(
        root, capsys, phase, carry, on_claude):
    flow(root, phase, 14)
    seed_review(root)
    before = state_of(root).read_bytes()

    assert begin(root, "14", *carry, env=ON_CLAUDE if on_claude else {}) == 1

    assert capsys.readouterr() == (
        "", "orch: " + HOLDS[phase] % COMMANDS[(phase, on_claude)] + "\n")
    assert (review_dir(root) / "spec.md").read_text() == "stale\n"
    assert state_of(root).read_bytes() == before


def test_a_flow_at_a_phase_outside_the_flow_s_phases_is_refused_pointing_at_doctor(root, capsys):
    flow(root, "bogus", 14)
    seed_review(root)

    assert begin(root, "14") == 1

    assert capsys.readouterr() == (
        "", "orch: the active flow holds issue #14 at phase 'bogus', which is not a flow phase"
            " - refusing to review it; run orch.sh doctor --flow\n")
    assert (review_dir(root) / "spec.md").read_text() == "stale\n"


def test_an_active_flow_on_another_issue_lets_the_issue_through(root, capsys):
    flow(root, "implement", 14)
    seed_review(root)
    before = state_of(root).read_bytes()

    assert begin(root, "15") == 0

    assert capsys.readouterr() == ("%s/\n" % review_dir(root, "15"), "")
    assert (review_dir(root) / "spec.md").read_text() == "stale\n"
    assert state_of(root).read_bytes() == before


def test_a_done_flow_holds_nothing(root, capsys):
    flow(root, "done", 14)
    seed_review(root)
    before = state_of(root).read_bytes()

    assert begin(root, "14") == 0

    assert capsys.readouterr() == ("%s/\n" % review_dir(root), "")
    assert entries(root) == []
    assert state_of(root).read_bytes() == before


def test_a_truncated_state_json_is_refused_as_unreadable(root, capsys):
    flow(root, "spec", 99)
    state_of(root).write_text('{"slug":"x","pha')
    seed_review(root)

    assert begin(root, "14") == 1

    assert capsys.readouterr() == (
        "", "orch: state.json cannot be read - run orch.sh doctor --flow\n")
    assert (review_dir(root) / "spec.md").read_text() == "stale\n"


# --- the reset ----------------------------------------------------------------------


def test_with_no_state_json_begin_wipes_the_directory_and_writes_no_state(root, capsys):
    seed_review(root)

    assert begin(root, "14") == 0

    assert capsys.readouterr() == ("%s/\n" % review_dir(root), "")
    assert entries(root) == []
    assert not state_of(root).exists()


def test_a_directory_never_there_is_created_empty(root, capsys):
    assert begin(root, "15") == 0

    assert capsys.readouterr().out == "%s/\n" % review_dir(root, "15")
    assert entries(root, "15") == []


def test_carry_keeps_only_the_map_and_the_settled_file_with_their_content(root, capsys):
    seed_review(root)

    assert begin(root, "14", "--carry") == 0

    assert capsys.readouterr() == ("%s/\n" % review_dir(root), "")
    assert entries(root) == ["map-implementability.md", "settled.md"]
    assert (review_dir(root) / "map-implementability.md").read_text() == "map\n"
    assert (review_dir(root) / "settled.md").read_text() == "## Spec review\nRound 1 of 2\n"


@pytest.mark.parametrize("removed, kept", [
    (("map-implementability.md",), ["settled.md"]),
    (("map-implementability.md", "settled.md"), []),
], ids=["no-map", "neither"])
def test_carry_keeps_each_carried_file_only_when_it_exists(root, removed, kept):
    seed_review(root)
    for name in removed:
        (review_dir(root) / name).unlink()

    assert begin(root, "14", "--carry") == 0

    assert entries(root) == kept


def test_carry_on_a_directory_never_there_creates_it_empty(root):
    assert begin(root, "16", "--carry") == 0

    assert entries(root, "16") == []
