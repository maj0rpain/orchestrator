"""The phase module's phase_finish, the finished phase's close review ready
reaches through orch_python_call, run in-process in a FakeGit checkout under
tmp_path against the gh fake on a tmp_path store: in a plain session the
next phase recorded and nothing else, in an autopilot one the issue checked,
then the label moved, the phase recorded and the claim released."""
from __future__ import annotations

import json
import sys

import pytest

from conftest import died_of, fake, flow_state, labels_of, snapshot, state_json
from orch import phase
from orch.__main__ import main
from orch.git import FakeGit

AUTOPILOT = {"ORCH_AUTOPILOT": "1"}
# A clock reading 2026-01-02T03:04:05Z.
CLOCK = 1767323045.0


def phase_finish(root, seed, *args, env=None):
    """phase_finish(<args>) in the checkout at <root> under <env> (a plain
    session's when None), on <seed>'s store."""
    return phase.phase_finish(list(args), gh=fake(seed), git=FakeGit(toplevel=str(root)),
                              env={} if env is None else env, clock=lambda: CLOCK)


def phase_of(root):
    return json.loads(state_json(root).read_text())["phase"]


@pytest.fixture
def reviewing(root, seed):
    """A flow at phase review on issue #7, which carries orch:review and
    orch:running and whose claim is held."""
    flow_state(root, "review", 7)
    seed.issue(7, "open", "ready-for-agent", "orch:review", "orch:running")
    seed.claim(7)


def test_a_plain_session_records_the_next_phase_and_touches_nothing_on_github(
        root, seed, store, capsys, reviewing):
    before = snapshot(store)

    assert phase_finish(root, seed, "done", "marked PR #9 ready", "7") is None
    assert capsys.readouterr() == ("", "")
    assert phase_of(root) == "done"
    assert snapshot(store) == before


def test_a_plain_session_s_failed_phase_write_dies_leaving_the_flow_unchanged(
        root, seed, capsys, reviewing):
    state_json(root).write_text("not json")

    assert died_of(capsys, lambda: phase_finish(root, seed, "done", "r", "7")) == (
        1, "", "orch: could not record phase in %s - the flow is unchanged\n" % state_json(root))
    assert state_json(root).read_text() == "not json"


def test_an_autopilot_session_moves_the_label_records_the_phase_and_releases_the_claim(
        root, seed, store, capsys, reviewing):
    assert phase_finish(root, seed, "done", "marked PR #9 ready", "7", env=AUTOPILOT) is None
    assert capsys.readouterr() == ("", "")
    assert labels_of(store, 7) == ["ready-for-agent", "orch:done"]
    assert phase_of(root) == "done"
    assert seed.claim_held(7) is False


def test_an_autopilot_session_s_failure_dies_with_the_reason_seeding_the_writes_that_landed(
        root, seed, store, capsys, reviewing):
    seed.fail("adapter_claim_delete", "HTTP 500")

    assert died_of(capsys, lambda: phase_finish(
        root, seed, "done", "marked PR #9 ready", "7", env=AUTOPILOT)) == (
        1, "", "orch: could not delete the claim ref on issue #7: HTTP 500 - writes that landed:"
               " marked PR #9 ready, moved the phase label to orch:done, recorded phase done,"
               " removed orch:running; the claim stays held\n")
    assert seed.claim_held(7) is True


def test_an_autopilot_session_with_no_issue_dies_before_any_write(
        root, seed, store, capsys, reviewing):
    before = snapshot(store)

    assert died_of(capsys, lambda: phase_finish(root, seed, "done", "r", "", env=AUTOPILOT)) == (
        1, "", "orch: no issue recorded in state - the spec phase must publish one first\n")
    assert phase_of(root) == "review"
    assert snapshot(store) == before


@pytest.mark.parametrize("args", [(), ("done", "r"), ("done", "r", "7", "x")])
def test_phase_finish_refuses_any_count_of_arguments_but_three(root, seed, capsys, args):
    assert died_of(capsys, lambda: phase_finish(root, seed, *args)) == (
        1, "", "orch: usage: orch_python_call phase phase_finish <next> <reason> <issue>\n")


def test_orch_python_call_reaches_phase_finish_naming_the_command_given_by_as(capsys):
    assert died_of(capsys, lambda: main(["--call", "--as", "review", "phase", "phase_finish"])) \
        == (1, "", "orch: usage: orch_python_call phase phase_finish <next> <reason> <issue>\n")


def test_orch_python_call_below_python_3_9_refuses_naming_orch_sh_review(monkeypatch, capsys):
    monkeypatch.setattr(sys, "version_info", (3, 8, 10, "final", 0))

    assert died_of(capsys, lambda: main(
        ["--call", "--as", "review", "phase", "phase_finish", "done", "r", "7"])) == (
        1, "", "orch: orch.sh review needs python3 3.9 or newer (found 3.8.10)"
               " - run orch.sh doctor\n")
