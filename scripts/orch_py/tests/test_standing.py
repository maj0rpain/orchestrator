"""The Phase label test, and the finished phase's close under its claim
(standing_finish) against the gh fake on a tmp_path store: the label moved,
then the phase recorded, then the claim released, each failure dying with
the writes that landed and the claim held - the messages bash's
scripts/test/orch/standing.sh asserts of its copy."""
from __future__ import annotations

import json
import os
import socket

import pytest

from conftest import died_of, fake, hold_flow, labels_of
from orch.gh import ClaimRow
from orch.standing import (Standing, claims_read, host_id, phase_labels_in, standing_finish,
                           standing_read)

# A clock reading 2026-01-02T03:04:05Z.
CLOCK = 1767323045.0


def test_the_phase_labels_among_labels_are_named_in_table_order_in_any_case():
    assert phase_labels_in(["orch:done", "bug", "ORCH:Spec", "orch:plan", "orch:running"]) \
        == ["spec", "done"]


@pytest.fixture
def state(tmp_path):
    """A flow's state.json at phase spec, under tmp_path/.orchestrator: its
    path, a str."""
    return str(hold_flow(tmp_path, phase="spec"))


def phase_of(state):
    with open(state) as f:
        return json.load(f)["phase"]


@pytest.fixture
def running(seed):
    """Issue #50 at orch:spec with a session running on it and its claim
    held."""
    seed.issue(50, "open", "orch:spec", "orch:running")
    seed.claim(50)


def finish(seed, state, phase="implement", reason="wrote the spec"):
    standing_finish(fake(seed), "50", phase, reason, state, lambda: CLOCK)


def test_a_finish_moves_the_phase_label_records_the_phase_and_releases_the_claim(
        seed, store, state, running, capsys):
    finish(seed, state)

    assert capsys.readouterr() == ("", "")
    assert labels_of(store, 50) == ["orch:implement"]
    assert phase_of(state) == "implement"
    assert seed.claim_held(50) is False


def test_a_finish_removes_every_other_phase_label_whatever_its_case(seed, store, state, capsys):
    seed.issue(50, "open", "bug", "ORCH:Spec", "orch:review", "orch:running")
    seed.claim(50)

    finish(seed, state, phase="review")

    assert labels_of(store, 50) == ["bug", "orch:review"]


@pytest.mark.parametrize("fail, reason, landed", [
    (("adapter_issue_state_labels", 0, "HTTP 502"), "wrote the spec",
     "could not read the labels on issue #50: HTTP 502 - writes that landed: wrote the spec"),
    (("adapter_issue_relabel", 0, "HTTP 500"), "",
     "could not move the phase label to orch:implement on issue #50: HTTP 500 - writes that"
     " landed: none"),
], ids=["label read", "label move"])
def test_a_finish_failing_before_its_label_moves_records_no_phase(
        seed, store, state, running, capsys, fail, reason, landed):
    seed.fail_after(*fail)

    assert died_of(capsys, lambda: finish(seed, state, reason=reason)) == (
        1, "", "orch: %s; the claim stays held\n" % landed)
    assert labels_of(store, 50) == ["orch:spec", "orch:running"]
    assert phase_of(state) == "spec"
    assert seed.claim_held(50) is True


@pytest.mark.parametrize("fail, reason, landed, labels", [
    (("adapter_issue_relabel", 1, "HTTP 500"), "wrote the spec",
     "could not remove orch:running on issue #50: HTTP 500 - writes that landed: wrote the"
     " spec, moved the phase label to orch:implement, recorded phase implement",
     ["orch:running", "orch:implement"]),
    (("adapter_claim_delete", 0, "HTTP 500"), "",
     "could not delete the claim ref on issue #50: HTTP 500 - writes that landed: moved the"
     " phase label to orch:implement, recorded phase implement, removed orch:running",
     ["orch:implement"]),
], ids=["running removal", "claim delete"])
def test_a_finish_failing_in_its_release_has_recorded_the_phase_and_holds_the_claim(
        seed, store, state, running, capsys, fail, reason, landed, labels):
    seed.fail_after(*fail)

    assert died_of(capsys, lambda: finish(seed, state, reason=reason)) == (
        1, "", "orch: %s; the claim stays held\n" % landed)
    assert labels_of(store, 50) == labels
    assert phase_of(state) == "implement"
    assert seed.claim_held(50) is True


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_finish_failing_on_its_phase_write_leaves_the_label_one_step_ahead_then_re_runs(
        seed, store, state, running, capsys):
    directory = os.path.dirname(state)
    os.chmod(directory, 0o555)
    try:
        assert died_of(capsys, lambda: finish(seed, state)) == (
            1, "", "orch: could not record phase implement in %s - writes that landed: wrote"
                   " the spec, moved the phase label to orch:implement; the claim stays held\n"
                   % state)
        assert labels_of(store, 50) == ["orch:running", "orch:implement"]
        assert seed.claim_held(50) is True
        assert phase_of(state) == "spec"
    finally:
        os.chmod(directory, 0o755)

    finish(seed, state)

    assert labels_of(store, 50) == ["orch:implement"]
    assert seed.claim_held(50) is False
    assert phase_of(state) == "implement"


# --- the read ---------------------------------------------------------------------


@pytest.mark.parametrize("labels, standing", [
    (("Orch:Implement", "orch:running", "needs-human", "bug"),
     Standing("OPEN", ["Orch:Implement", "orch:running", "needs-human", "bug"], "implement",
              "orch:implement", True, True, False, False)),
    (("orch:done", "orch:sync", "orch:limited"),
     Standing("OPEN", ["orch:done", "orch:sync", "orch:limited"], "", "orch:done", False, False,
              True, True)),
    ((), Standing("OPEN", [], "", "", False, False, False, False)),
])
def test_the_standing_read_fills_the_label_half_from_one_issue_read(seed, labels, standing):
    seed.issue(7, "open", *labels)

    assert standing_read(fake(seed), 7) == (standing, "")


@pytest.mark.parametrize("stderr, reason", [("HTTP 502: Bad Gateway\nsecond\n",
                                             "HTTP 502: Bad Gateway"),
                                            ("", "gh gave no reason")])
def test_a_failed_standing_read_gives_gh_s_reason_alone(seed, stderr, reason):
    seed.issue(7, "open")
    seed.fail("adapter_issue_state_labels", stderr)

    assert standing_read(fake(seed), 7) == (None, reason)


@pytest.mark.parametrize("env, host", [({"ORCH_HOST_ID": "autopilot-abc123"}, "autopilot-abc123"),
                                       ({"ORCH_HOST_ID": ""}, socket.gethostname()),
                                       ({}, socket.gethostname())])
def test_the_host_id_is_orch_host_id_else_the_hostname(env, host):
    assert host_id(env) == host


def test_the_claims_read_lists_every_claim_on_origin_by_issue_number(seed):
    seed.claim(12, host="thirdhost", pid=5, started="2020-01-01T00:00:00Z")
    seed.claim(7, host="otherhost", pid=6, started="2021-01-01T00:00:00Z", phase="review")
    seed.claim(9)

    assert claims_read(fake(seed)) == ([
        ClaimRow("7", "otherhost", "6", "review", "2021-01-01T00:00:00Z"),
        ClaimRow("9", socket.gethostname(), "1", "spec", "2026-01-01T00:00:00Z"),
        ClaimRow("12", "thirdhost", "5", "spec", "2020-01-01T00:00:00Z"),
    ], "")


def test_claims_origin_cannot_list_are_none_with_the_reason(seed):
    seed.claim(7)
    seed.fail("adapter_claim_list", "fatal: could not read from remote repository\n")

    assert claims_read(fake(seed)) == (None, "fatal: could not read from remote repository")
