"""The Standing module against the gh fake on a tmp_path store: the read and
its label half, the Pickup rule and the sync-request reads, the phase-redo
rule, the phase labels and the label entries, the claims read and create,
the single writes (begin, sync request, resume) and the chain transitions
(stop, sync finish, sync dropped, limit stop, claim release, the finished
phase's close), each failure dying with the writes that landed and the claim
held, and the resumable chain's landed record - the cases the deleted bash
Standing sections held. Ask and re-entry are driven through
autopilot.run in test_autopilot_questions.py, their marker refusals, partway
failures and ask's temp body file here."""
from __future__ import annotations

import json
import os
import socket

import pytest

from conftest import comments_of, died_of, fake, hold_flow, labels_of, marker_of, snapshot
from orch.gh import ClaimRow, GhFailed
from orch.gh_fake import FakeGh
from orch.standing import (Chain, Standing, claim_of, claims_read, claims_read_or_die,
                           label_entries, phase_labels_in, phase_labels_text, phase_text,
                           redo_phase, redo_rule, standing_ask, standing_begin,
                           standing_claim, standing_claim_release, standing_finish,
                           standing_human_guard, standing_limit_stop, standing_of,
                           standing_read, standing_reenter, standing_resume, standing_stop,
                           standing_sync_dropped, standing_sync_finish, standing_sync_request)

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


@pytest.mark.parametrize("state, labels, read", [
    ("OPEN", ("orch:review", "needs-human", "bug"), ("review", "orch:review", False, True, False)),
    ("CLOSED", ("orch:done", "orch:spec", "orch:running", "orch:limited"),
     ("spec", "orch:spec orch:done", True, False, True)),
    ("OPEN", ("Orch:Spec", "Needs-Human", "Orch:Running", "orch:Limited"),
     ("spec", "orch:spec", True, True, True)),
], ids=["phase and needs-human", "done skipped, table order", "any casing"])
def test_the_read_and_the_label_half_from_state_and_labels_agree_field_by_field(
        seed, state, labels, read):
    seed.issue(5, state, *labels)

    standing, reason = standing_read(fake(seed), 5)

    assert (standing, reason) == (standing_of(state, labels), "")
    assert (standing.phase, standing.phase_labels, standing.running, standing.human,
            standing.limited) == read


def test_a_failed_read_hands_back_gh_s_reason_printing_nothing(seed, capsys):
    seed.issue(5, "open", "orch:spec")
    seed.fail("adapter_issue_state_labels", "HTTP 502")

    assert standing_read(fake(seed), 5) == (None, "HTTP 502")
    assert capsys.readouterr() == ("", "")


def test_the_human_guard_dies_in_one_line_naming_gh_and_the_reason(seed, capsys):
    seed.issue(5, "open", "needs-human")
    seed.fail("adapter_issue_state_labels", "HTTP 502")

    assert died_of(capsys, lambda: standing_human_guard(fake(seed), "5")) == (
        1, "", "orch: gh could not read issue #5: HTTP 502\n")


# --- the phase-redo rule, the phase labels and the label entries --------------------


@pytest.mark.parametrize("labelled, recorded, redo", [
    ("implement", "review", "review"), ("spec", "implement", "spec"),
    ("spec", "review", None), ("review", "spec", None), ("review", "done", None),
    ("done", "review", None), ("spec", "done", None), ("implement", "implement", None),
    ("review", "implement", None),
])
def test_the_phase_redo_rule_steps_back_only_from_review_and_implement(labelled, recorded, redo):
    assert redo_phase(labelled, recorded) == redo


def test_the_redo_rule_reads_as_a_sentence_naming_each_step_back():
    assert redo_rule() == "a step back from review to implement or from implement to spec"


@pytest.mark.parametrize("labels, text", [
    (["bug", "ready-for-agent"], ""), (["bug", "orch:review"], "orch:review"),
    (["orch:review", "bug", "orch:spec"], "orch:spec orch:review"),
])
def test_the_phase_labels_text_names_them_in_table_order(labels, text):
    assert phase_labels_text(labels) == text


def test_the_label_entries_are_a_label_per_phase_then_the_four_standing_labels():
    assert label_entries() == [
        ("orch:spec", "1d76db", "Autopilot flow: spec phase next"),
        ("orch:implement", "0e8a16", "Autopilot flow: implement phase next"),
        ("orch:review", "5319e7", "Autopilot flow: review phase next"),
        ("orch:done", "c2e0c6", "Autopilot flow: done"),
        ("orch:running", "fbca04", "Autopilot session running"),
        ("needs-human", "d93f0b", "Waiting on the human"),
        ("orch:limited", "c5def5", "Autopilot session stopped on a usage or GitHub API rate"
                                   " limit; retried after the reset"),
        ("orch:sync", "0075ca", "Autopilot: base sync requested on a done flow"),
    ]


# --- the Pickup rule and the sync-request reads -----------------------------------


@pytest.mark.parametrize("state, labels, pickable", [
    ("open", ("orch:spec",), True),
    ("open", ("orch:spec", "orch:running"), False),
    ("open", ("orch:spec", "needs-human"), False),
    ("closed", ("orch:spec",), False),
    ("open", ("orch:done",), False),
    ("open", ("orch:spec", "orch:limited"), True),
    ("open", ("orch:done", "orch:sync"), True),
], ids=["a live phase", "running", "waiting on the human", "closed", "done alone", "limited",
        "a sync request"])
def test_the_label_half_of_the_pickup_rule(seed, state, labels, pickable):
    seed.issue(10, state, *labels)

    assert standing_read(fake(seed), 10)[0].pickable() is pickable


@pytest.mark.parametrize("labels, sync, session", [
    (("orch:done", "orch:sync"), True, "sync"),
    (("orch:review", "orch:sync"), False, "review"),
    (("orch:sync",), False, ""),
    (("orch:done",), False, ""),
], ids=["done and sync", "a live phase is its phase's", "sync with no done", "done alone"])
def test_a_sync_request_is_orch_sync_on_a_done_issue_with_no_live_phase(labels, sync, session):
    standing = standing_of("OPEN", labels)

    assert (standing.is_sync(), standing.session_phase()) == (sync, session)


def test_a_stop_names_a_phase_or_the_sync():
    assert (phase_text("review"), phase_text("sync")) == ("the review phase", "the sync")


# --- the claims -------------------------------------------------------------------


def test_the_claims_read_keys_each_claim_by_its_issue(seed):
    seed.claim(21, "other-host", 7, "2026-01-01T00:00:00Z", "implement")
    seed.claim(20, None, 8, "2026-02-02T00:00:00Z", "spec")

    claims = claims_read_or_die(fake(seed))

    assert [claim.issue for claim in claims] == ["20", "21"]
    assert claim_of(claims, 21) == ClaimRow("21", "other-host", "7", "implement",
                                            "2026-01-01T00:00:00Z")
    assert claim_of(claims, 99) is None


def test_a_failed_claims_read_dies_or_hands_back_the_reason_quietly(seed, capsys):
    seed.fail("adapter_claim_list", "boom")

    assert claims_read(fake(seed)) == (None, "boom")
    assert capsys.readouterr() == ("", "")
    assert died_of(capsys, lambda: claims_read_or_die(fake(seed))) == (
        1, "", "orch: could not list the claims on origin: boom\n")


@pytest.mark.parametrize("env, host", [
    ({"ORCH_HOST_ID": "autopilot-abc123"}, "autopilot-abc123"),
    ({"ORCH_HOST_ID": ""}, socket.gethostname()),
], ids=["ORCH_HOST_ID", "the hostname when it is empty"])
def test_a_claim_taken_records_the_host_id_the_phase_and_the_start(seed, env, host):
    assert standing_claim(fake(seed), "30", "spec", 1, env, lambda: CLOCK) == (0, "")
    assert claim_of(claims_read_or_die(fake(seed)), 30) == ClaimRow(
        "30", host, "1", "spec", "2026-01-02T03:04:05Z")


def test_a_claim_on_a_held_issue_loses_the_race_and_any_other_failure_names_the_reason(seed):
    seed.claim(30)

    assert standing_claim(fake(seed), "30", "review", 2, {}) == (2, "")
    seed.fail("adapter_claim_create", "HTTP 500")
    assert standing_claim(fake(seed), "32", "spec", 1, {}) == (1, "HTTP 500")


# --- the single writes ------------------------------------------------------------


def test_a_sync_request_adds_orch_sync_and_keeps_orch_done(seed, store):
    seed.issue(49, "open", "orch:done")

    assert standing_sync_request(fake(seed), "49") == ""
    assert labels_of(store, 49) == ["orch:done", "orch:sync"]
    assert standing_read(fake(seed), 49)[0].is_sync() is True


def test_resume_removes_needs_human_or_hands_back_the_reason(seed, store, capsys):
    seed.issue(80, "open", "needs-human", "orch:spec")
    assert standing_resume(fake(seed), "80") == ""
    assert labels_of(store, 80) == ["orch:spec"]
    seed.issue(81, "open", "needs-human", "orch:spec")
    seed.fail("adapter_issue_relabel", "HTTP 500")

    assert standing_resume(fake(seed), "81") == "HTTP 500"
    assert capsys.readouterr() == ("", "")


@pytest.mark.parametrize("limited, labels", [
    (True, ["orch:spec", "orch:running"]), (False, ["orch:spec", "orch:limited", "orch:running"]),
], ids=["limited", "not limited"])
def test_begin_adds_orch_running_removing_orch_limited_when_asked(seed, store, limited, labels):
    seed.issue(60, "open", "orch:spec", "orch:limited")

    assert standing_begin(fake(seed), "60", limited) == ""
    assert labels_of(store, 60) == labels


@pytest.mark.parametrize("after, reason, labels", [
    (0, "step removing orch:limited failed: HTTP 500", ["orch:spec", "orch:limited"]),
    (1, "step adding orch:running failed: HTTP 500", ["orch:spec"]),
], ids=["the limited removal", "the running addition"])
def test_a_failed_begin_hands_back_the_step_s_wording(seed, store, capsys, after, reason, labels):
    seed.issue(62, "open", "orch:spec", "orch:limited")
    seed.fail_after("adapter_issue_relabel", after, "HTTP 500")

    assert standing_begin(fake(seed), "62", True) == reason
    assert capsys.readouterr() == ("", "")
    assert labels_of(store, 62) == labels


# --- the chain transitions ----------------------------------------------------------


@pytest.fixture
def chain_of(seed):
    """A chain on issue #<n> through the gh fake, its keyword arguments
    Chain's."""
    return lambda n, **kwargs: Chain(fake(seed), str(n), **kwargs)


def tr_seed(seed, n, *labels):
    seed.issue(n, "open", *labels)
    seed.claim(n)


def flags(store, n):
    """Issue #n's live phase and its running, needs-human and limited
    flags, as the standing read gives them."""
    standing = standing_of("OPEN", labels_of(store, n))
    return standing.phase, standing.running, standing.human, standing.limited


def test_a_sync_finish_removes_orch_sync_keeps_orch_done_and_releases(seed, store, chain_of):
    tr_seed(seed, 140, "orch:done", "orch:sync", "orch:running")

    standing_sync_finish(chain_of(140))

    assert (labels_of(store, 140), seed.claim_held(140)) == (["orch:done"], False)


def test_a_sync_finish_failing_on_the_release_names_the_writes_that_landed(
        seed, capsys, chain_of):
    tr_seed(seed, 143, "orch:done", "orch:sync", "orch:running")
    seed.fail("adapter_claim_delete", "HTTP 500")

    assert died_of(capsys, lambda: standing_sync_finish(chain_of(143)))[2] == (
        "orch: could not delete the claim ref on issue #143: HTTP 500 - writes that landed:"
        " removed orch:sync, removed orch:running; the claim stays held\n")
    assert seed.claim_held(143) is True


@pytest.mark.parametrize("auto_sync, following", [
    (False, "To sync again, run `orch.sh autopilot sync 141`."),
    (True, "Once the label is gone, the watcher files a new sync request by itself whenever the"
           " PR conflicts with its base; or run `orch.sh autopilot sync 141` to sync now."),
], ids=["auto-sync off", "auto-sync on"])
def test_the_dropped_intent_stop_swaps_orch_sync_for_needs_human_and_lists_the_intents(
        seed, store, chain_of, auto_sync, following):
    tr_seed(seed, 141, "orch:done", "orch:sync", "orch:running")

    standing_sync_dropped(chain_of(141), "- keep the cache flag (see https://x/y#c1)", auto_sync)

    assert (sorted(labels_of(store, 141)), seed.claim_held(141)) == (
        ["needs-human", "orch:done"], False)
    assert comments_of(store, 141) == [
        marker_of("failure", "sync") + "\nThe sync pushed its merge, but its resolver dropped"
        " these intents:\n\n- keep the cache flag (see https://x/y#c1)\n\nNo reply is needed."
        " Review the dropped intents; if you accept them, remove needs-human. To reject one,"
        " restore it on the branch first, then remove the label. The issue no longer carries"
        " orch:sync. " + following + "\n"]


@pytest.mark.parametrize("fail, landed", [
    ("adapter_issue_comment",
     "could not post the failure comment on issue #144: HTTP 500 - writes that landed: added"
     " needs-human, removed orch:sync"),
    ("adapter_issue_relabel",
     "could not add needs-human, remove orch:sync on issue #144: HTTP 500 - writes that landed:"
     " none"),
], ids=["its comment", "its relabel"])
def test_the_dropped_intent_stop_failing_names_the_writes_that_landed(
        seed, capsys, chain_of, fail, landed):
    tr_seed(seed, 144, "orch:done", "orch:sync", "orch:running")
    seed.fail(fail, "HTTP 500")

    assert died_of(capsys, lambda: standing_sync_dropped(chain_of(144), "x", False))[2] == (
        "orch: %s; the claim stays held\n" % landed)


def test_a_failure_stop_of_a_sync_keeps_orch_sync_and_names_the_sync(seed, store, chain_of):
    tr_seed(seed, 142, "orch:done", "orch:sync", "orch:running")

    standing_stop(chain_of(142), "failure", "sync", "the resolver gave up")

    assert (sorted(labels_of(store, 142)), seed.claim_held(142)) == (
        ["needs-human", "orch:done", "orch:sync"], False)
    assert "Autopilot failed in the sync: the resolver gave up" in comments_of(store, 142)[0]


@pytest.mark.parametrize("kind, phase, prose", [
    ("refusal", "spec", "Autopilot refused to run the spec phase: no plan\n\nThe issue is"
     " labelled needs-human. Remove the label once this is settled and the watcher picks the"
     " spec phase up again.\n"),
    ("failure", "review", "Autopilot failed in the review phase: no plan\n\nThe issue is"
     " labelled needs-human; nothing is retried automatically except a usage-limit stop"
     " labelled `orch:limited`. Remove the label to have the watcher start the review phase"
     " again.\n"),
])
def test_a_stop_adds_needs_human_drops_limited_comments_under_its_marker_and_releases(
        seed, store, chain_of, kind, phase, prose):
    tr_seed(seed, 56, "orch:spec", "orch:running", "orch:limited")

    standing_stop(chain_of(56), kind, phase, "no plan")

    assert (flags(store, 56), seed.claim_held(56)) == (("spec", False, True, False), False)
    assert comments_of(store, 56) == [marker_of(kind, phase) + "\n" + prose]


@pytest.mark.parametrize("fail, landed", [
    (("adapter_issue_relabel", 0),
     "could not add needs-human, remove orch:limited on issue #57: HTTP 500 - writes that"
     " landed: none"),
    (("adapter_issue_comment", 0),
     "could not post the failure comment on issue #57: HTTP 500 - writes that landed: added"
     " needs-human, removed orch:limited"),
    (("adapter_issue_relabel", 1),
     "could not remove orch:running on issue #57: HTTP 500 - writes that landed: added"
     " needs-human, removed orch:limited, posted the failure comment"),
    (("adapter_claim_delete", 0),
     "could not delete the claim ref on issue #57: HTTP 500 - writes that landed: added"
     " needs-human, removed orch:limited, posted the failure comment, removed orch:running"),
], ids=["its first write", "its comment", "the running removal", "the claim delete"])
def test_a_stop_failing_partway_names_the_writes_that_landed_the_claim_held(
        seed, capsys, chain_of, fail, landed):
    tr_seed(seed, 57, "orch:spec", "orch:running")
    seed.fail_after(*fail, "HTTP 500")

    assert died_of(capsys, lambda: standing_stop(chain_of(57), "failure", "spec", "boom")) == (
        1, "", "orch: %s; the claim stays held\n" % landed)
    assert seed.claim_held(57) is True


def test_a_stop_of_an_empty_phase_dies_writing_nothing(seed, store, capsys, chain_of):
    tr_seed(seed, 59, "orch:spec", "orch:running")
    before = snapshot(store)

    assert died_of(capsys, lambda: standing_stop(chain_of(59), "failure", "", "boom"))[0] == 1
    assert snapshot(store) == before


def test_each_chain_names_only_its_own_landed_writes(seed, store, capsys, chain_of):
    tr_seed(seed, 54, "orch:spec", "orch:running")
    tr_seed(seed, 55, "orch:spec", "orch:running")
    seed.fail_after("adapter_claim_delete", 1, "HTTP 500")

    standing_limit_stop(chain_of(54), "spec", "", "2026-01-01T01:00:00Z", 1, "log")
    assert died_of(capsys, lambda: standing_stop(chain_of(55), "failure", "spec", "boom"))[2] == (
        "orch: could not delete the claim ref on issue #55: HTTP 500 - writes that landed: added"
        " needs-human, removed orch:limited, posted the failure comment, removed orch:running;"
        " the claim stays held\n")
    assert (labels_of(store, 54), seed.claim_held(54)) == (["orch:spec", "orch:limited"], False)


def test_a_stop_whose_body_file_cannot_be_made_dies_after_its_label(
        seed, capsys, chain_of, tmp_path, monkeypatch):
    tr_seed(seed, 71, "orch:spec", "orch:running")
    monkeypatch.setattr("tempfile.tempdir", str(tmp_path / "missing"))

    assert died_of(capsys, lambda: standing_stop(chain_of(71), "failure", "spec", "boom"))[2] == (
        "orch: could not create a temp file to post the failure comment - writes that landed:"
        " added needs-human, removed orch:limited; the claim stays held\n")
    assert seed.claim_held(71) is True


def test_a_stop_whose_body_cannot_be_written_posts_nothing_and_leaves_no_file(
        seed, store, capsys, chain_of, tmp_path):
    tr_seed(seed, 72, "orch:spec", "orch:running")
    body = tmp_path / "body"

    def unwritable():
        return os.open(str(body), os.O_RDONLY | os.O_CREAT), str(body)

    assert died_of(capsys, lambda: standing_stop(chain_of(72, mkstemp=unwritable), "failure",
                                                 "spec", "boom"))[2] == (
        "orch: could not write the temp file to post the failure comment - writes that landed:"
        " added needs-human, removed orch:limited; the claim stays held\n")
    assert (seed.claim_held(72), comments_of(store, 72), body.exists()) == (True, [], False)


def test_ask_with_a_blank_phase_dies_before_any_write(seed, store, capsys, chain_of):
    tr_seed(seed, 68, "orch:spec", "orch:running")
    before = snapshot(store)

    assert died_of(capsys, lambda: standing_ask(chain_of(68), " ", "Q", "o"))[0] == 1
    assert snapshot(store) == before


def test_reenter_with_a_blank_phase_dies_with_the_marker_writer_s_refusal(
        seed, store, capsys, chain_of):
    tr_seed(seed, 72, "orch:spec", "orch:running")
    before = snapshot(store)

    assert died_of(capsys, lambda: standing_reenter(chain_of(72), " ", "Q", lambda: "o")) == (
        1, "", "orch: marked comment: reentry needs an argument without whitespace\n")
    assert snapshot(store) == before


@pytest.mark.parametrize("fail, landed", [
    (("adapter_issue_comment", 0),
     "could not post the spec question comment on issue #74: HTTP 500 - writes that landed:"
     " none"),
    (("adapter_claim_delete", 0),
     "could not delete the claim ref on issue #74: HTTP 500 - writes that landed: posted the"
     " spec question comment, added needs-human, removed orch:running"),
], ids=["its comment", "the claim delete"])
def test_ask_failing_partway_names_the_writes_that_landed_the_claim_held(
        seed, capsys, chain_of, fail, landed):
    tr_seed(seed, 74, "orch:spec", "orch:running")
    seed.fail_after(*fail, "HTTP 500")

    assert died_of(capsys, lambda: standing_ask(chain_of(74), "spec", "Q", "o")) == (
        1, "", "orch: %s; the claim stays held\n" % landed)
    assert seed.claim_held(74) is True


@pytest.mark.parametrize("fail", [None, "adapter_issue_comment"], ids=["posted", "failed post"])
def test_ask_leaves_no_temp_body_file_behind(seed, capsys, chain_of, tmp_path, monkeypatch, fail):
    tr_seed(seed, 76, "orch:spec", "orch:running")
    temp = tmp_path / "temp"
    temp.mkdir()
    monkeypatch.setattr("tempfile.tempdir", str(temp))

    if fail:
        seed.fail(fail, "HTTP 500")
        assert died_of(capsys, lambda: standing_ask(chain_of(76), "spec", "Q", "o"))[0] == 1
    else:
        standing_ask(chain_of(76), "spec", "Q", "o")

    assert os.listdir(str(temp)) == []


@pytest.mark.parametrize("earlier, fail, landed", [
    (0, ("adapter_issue_comment", 0),
     "could not post the re-entry comment on issue #75: HTTP 500 - writes that landed: none"),
    (2, ("adapter_issue_relabel", 0),
     "could not add needs-human on issue #75: HTTP 500 - writes that landed: posted the review"
     " question comment"),
    (0, ("adapter_issue_comments", 0),
     "could not read issue #75's comments to count the automatic re-entries in a row: HTTP 500"
     " - writes that landed: none"),
], ids=["its comment", "the ask path's label", "its comments read"])
def test_reenter_failing_partway_names_the_writes_that_landed_the_claim_held(
        seed, capsys, chain_of, earlier, fail, landed):
    tr_seed(seed, 75, "orch:review", "orch:running")
    for day in range(earlier):
        seed.comment(75, "o", "2026-01-0%dT00:00:00Z" % (day + 1),
                     marker_of("reentry", "review") + "\nr")
    seed.fail_after(*fail, "HTTP 500")

    assert died_of(capsys, lambda: standing_reenter(chain_of(75), "review", "R",
                                                    lambda: "o")) == (
        1, "", "orch: %s; the claim stays held\n" % landed)
    assert seed.claim_held(75) is True


# --- the limit stop -------------------------------------------------------------------

PAUSE = "2026-01-01T01:00:00Z"


def limit_stop(chain, cause="", reset=""):
    standing_limit_stop(chain, "spec", reset, PAUSE, 1, "log", cause)


def test_a_usage_limit_stop_adds_limited_comments_and_releases(seed, store, chain_of):
    tr_seed(seed, 60, "orch:spec", "orch:running")

    limit_stop(chain_of(60))

    assert (flags(store, 60), seed.claim_held(60)) == (("spec", False, False, True), False)
    assert comments_of(store, 60) == [
        marker_of("limited", "spec") + "\nThe session stopped on a usage limit in the spec phase;"
        " it gave no reset time, so the watcher falls back to a one-hour limit pause, until "
        + PAUSE + ".\n\nThe issue is labelled orch:limited; retry 1 of 2, started once the limit"
        " pause has passed.\n\nLog: log\n"]


def test_a_limit_stop_failing_on_its_comment_names_the_label_that_landed(
        seed, capsys, chain_of):
    tr_seed(seed, 61, "orch:spec", "orch:running")
    seed.fail("adapter_issue_comment", "HTTP 500")

    assert died_of(capsys, lambda: limit_stop(chain_of(61)))[2] == (
        "orch: could not post the limit stop comment on issue #61: HTTP 500 - writes that"
        " landed: added orch:limited; the claim stays held\n")
    assert seed.claim_held(61) is True


@pytest.mark.parametrize("earlier, retry", [(0, "retry 1 of 2"), (1, "retry 2 of 2")])
def test_the_first_and_second_limit_stops_in_a_row_stay_limited(
        seed, store, chain_of, earlier, retry):
    tr_seed(seed, 69, "orch:spec", "orch:running")
    for day in range(earlier):
        seed.comment(69, "o", "2026-01-0%dT00:00:00Z" % (day + 1), marker_of("limited", "spec"))

    limit_stop(chain_of(69))

    assert flags(store, 69) == ("spec", False, False, True)
    assert retry in comments_of(store, 69)[-1]


def test_the_third_limit_stop_in_a_row_is_a_needs_human_failure_stop(seed, store, chain_of):
    tr_seed(seed, 67, "orch:spec", "orch:running")
    for day in (1, 2):
        seed.comment(67, "o", "2026-01-0%dT00:00:00Z" % day, marker_of("limited", "spec"))

    limit_stop(chain_of(67))

    assert (flags(store, 67), seed.claim_held(67)) == (("spec", False, True, False), False)
    assert comments_of(store, 67)[-1].startswith(
        marker_of("failure", "spec") + "\nAutopilot failed in the spec phase: the session"
        " stopped on a usage limit (the session gave no reset time) and exited with code 1, the"
        " third in a row in the spec phase; log: log\n")


def test_unreadable_comments_fail_a_limit_stop_writing_nothing(seed, store, capsys, chain_of):
    tr_seed(seed, 70, "orch:spec", "orch:running")
    seed.fail("adapter_issue_comments", "HTTP 500 comments")
    before = snapshot(store)

    assert died_of(capsys, lambda: limit_stop(chain_of(70)))[2] == (
        "orch: could not read issue #70's comments to count the stops in a row: HTTP 500"
        " comments - writes that landed: none; the claim stays held\n")
    assert snapshot(store) == before


def test_a_limit_stop_whose_read_succeeds_notes_its_stop_once(seed, chain_of, tmp_path):
    tr_seed(seed, 73, "orch:spec", "orch:running")
    record = tmp_path / "record"

    limit_stop(chain_of(73, state_file=str(record)))

    assert [line.split("\t")[0] for line in record.read_text().splitlines()].count("stop") == 1


def test_a_github_limit_stop_adds_no_label_and_names_the_rate_limit_and_its_reset(
        seed, store, chain_of):
    tr_seed(seed, 95, "orch:spec", "orch:running")

    limit_stop(chain_of(95), "github", PAUSE)

    assert (flags(store, 95), seed.claim_held(95)) == (("spec", False, False, False), False)
    assert comments_of(store, 95) == [
        marker_of("limited", "spec", "github") + "\nThe session stopped on the GitHub API rate"
        " limit in the spec phase, which resets " + PAUSE + ".\n\nRetry 1 of 2: the issue is"
        " picked up again by the next tick, no label is added.\n\nLog: log\n"]


def test_a_github_stop_after_a_github_stop_is_retry_2_of_2(seed, store, chain_of):
    tr_seed(seed, 96, "orch:spec", "orch:running")
    seed.comment(96, "o", "2026-01-01T00:00:00Z", marker_of("limited", "spec", "github"))

    limit_stop(chain_of(96), "github", PAUSE)

    assert "Retry 2 of 2" in comments_of(store, 96)[-1]


def test_the_third_limit_stop_whatever_its_causes_fails_naming_the_github_cause(
        seed, store, chain_of):
    tr_seed(seed, 97, "orch:spec", "orch:running")
    seed.comment(97, "o", "2026-01-01T00:00:00Z", marker_of("limited", "spec"))
    seed.comment(97, "o", "2026-01-01T00:00:01Z", marker_of("limited", "spec", "github"))

    limit_stop(chain_of(97), "github", PAUSE)

    assert (flags(store, 97), seed.claim_held(97)) == (("spec", False, True, False), False)
    assert ("stopped on the GitHub API rate limit (resets %s) and exited with code 1, the third"
            " in a row" % PAUSE) in comments_of(store, 97)[-1]


def test_a_limit_stop_of_an_empty_phase_dies_writing_nothing(seed, store, capsys, chain_of):
    tr_seed(seed, 68, "orch:spec", "orch:running")
    before = snapshot(store)

    assert died_of(capsys, lambda: standing_limit_stop(chain_of(68), "", "", "", 1, "log"))[0] == 1
    assert snapshot(store) == before


# --- the resumable chain ---------------------------------------------------------------


class LosingGh(FakeGh):
    """The gh fake on a GitHub whose first comment post lands but reports a
    failure."""

    lost = False

    def issue_comment(self, n, body_file):
        super().issue_comment(n, body_file)
        if not LosingGh.lost:
            LosingGh.lost = True
            raise GhFailed("HTTP 502\n")


@pytest.fixture
def resumed(seed, tmp_path, capsys):
    """Runs a limit stop on issue <n> twice over one landed record, the first
    attempt's comment landing though its call fails, <between> run between
    the attempts: the record's lines."""
    def run(n, between=lambda: None):
        LosingGh.lost = False
        record = str(tmp_path / "record")
        gh = LosingGh(seed.store, {}, sleep=lambda _: None)
        with pytest.raises(SystemExit):
            limit_stop(Chain(gh, str(n), state_file=record))
        between()
        try:
            limit_stop(Chain(gh, str(n), state_file=record))
        except SystemExit:
            pass
        capsys.readouterr()
        return open(record).read().splitlines()
    return run


def limited_comments(store, n):
    return sum(1 for body in comments_of(store, n) if body.startswith(marker_of("limited", "spec")))


def test_a_resumed_stop_posts_no_second_comment_keeps_its_count_and_releases(
        seed, store, resumed):
    tr_seed(seed, 71, "orch:spec", "orch:running")

    record = resumed(71)

    assert "landed\tdeleted the claim ref" in record
    assert (limited_comments(store, 71), seed.claim_held(71)) == (1, False)
    assert "retry 1 of 2" in comments_of(store, 71)[0]


def test_a_resumed_stop_whose_duplicate_check_fails_posts_nothing(seed, store, capsys, resumed):
    tr_seed(seed, 72, "orch:spec", "orch:running")

    resumed(72, lambda: seed.fail("adapter_issue_comments", "HTTP 500 read"))

    assert (limited_comments(store, 72), seed.claim_held(72)) == (1, True)


def test_a_resumed_chain_starts_from_the_writes_an_earlier_attempt_landed(
        seed, tmp_path, capsys):
    record = tmp_path / "record"
    record.write_text("landed\tearlier\n")
    ran = []

    chain = Chain(fake(seed), "7", state_file=str(record))
    chain.step("earlier", "do earlier", lambda: ran.append("earlier"))
    chain.step("later", "do later", lambda: ran.append("later"))

    assert (ran, chain.landed) == (["later"], ["earlier", "later"])
    assert record.read_text() == "landed\tearlier\nlanded\tlater\n"

    def failing():
        raise GhFailed("HTTP 500\n")

    assert died_of(capsys, lambda: chain.step("third", "do third", failing))[2] == (
        "orch: could not do third on issue #7: HTTP 500 - writes that landed: earlier, later;"
        " the claim stays held\n")


def test_a_claim_release_removes_running_then_deletes_the_claim_noting_its_stop(
        seed, store, chain_of, tmp_path):
    tr_seed(seed, 90, "orch:spec", "orch:running")
    record = tmp_path / "record"

    standing_claim_release(chain_of(90, state_file=str(record)))

    assert (labels_of(store, 90), seed.claim_held(90)) == (["orch:spec"], False)
    assert record.read_text().splitlines()[0] == "stop\tclaim release\tcould not release the claim"
