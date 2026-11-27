"""The autopilot noun's Sync request verbs - `sync <issue>`, `sync-finish`,
`sync-dropped <file>` and `sync-fail <reason>` - run in-process through
autopilot.run in a FakeGit checkout under tmp_path, against the gh fake on a
tmp_path store: their labels, comments, claims, messages and exit codes.
Ported from the bash autopilot sections that held them - the sync request
cases of autopilot questions, reply and resume, and autopilot sync-finish,
sync-dropped and sync-fail. The Standing transitions under them are tested
in test_standing.py; their usage refusals and the unknown-op refusal in
test_autopilot.py."""
from __future__ import annotations

import pytest

from conftest import AUTOPILOT, CLAUDE, SESSIONS, comments_of, hold_flow, labels_of, snapshot
from orch import autopilot
from orch.gh import Gh
from orch.repo import REPO_REMEDY, RepoPin
from test_autopilot import ap, checkout
from test_autopilot_questions import held, marker_of, run_ap, text_file

AUTO_SYNC = "orchestrator.autopilot.auto-sync"


# --- sync -----------------------------------------------------------------------


@SESSIONS
def test_sync_on_an_open_done_issue_adds_only_orch_sync(root, seed, store, capsys, env):
    seed.issue(60, "open", "orch:done")

    assert (run_ap(seed, root, env, "sync", "60"), capsys.readouterr()) == (0, ("", ""))
    assert labels_of(store, 60) == ["orch:done", "orch:sync"]


@pytest.mark.parametrize("seeding, issue, message", [
    (lambda seed: seed.issue(60, "open", "orch:done", "orch:sync"), "60",
     "orch: issue #60 already carries orch:sync\n"),
    (lambda seed: seed.issue(61, "closed", "orch:done"), "61", "orch: issue #61 is closed\n"),
    (lambda seed: seed.issue(62, "open", "orch:review"), "62",
     "orch: issue #62 is not at orch:done - a sync request needs a done flow\n"),
    (lambda seed: (seed.issue(63, "open", "orch:done"),
                   seed.fail("adapter_issue_relabel", "HTTP 500")), "63",
     "orch: gh could not add orch:sync to issue #63: HTTP 500\n"),
    (lambda seed: (seed.issue(64, "open", "orch:done"),
                   seed.fail("adapter_issue_state_labels", "HTTP 502")), "64",
     "orch: gh could not read issue #64: HTTP 502\n"),
    (lambda seed: None, "x", "orch: not an issue number: x\n"),
], ids=["already requested", "closed", "not done", "a failed write", "a failed read",
        "not a number"])
def test_sync_refuses_with_its_message_leaving_the_labels(
        root, seed, store, capsys, seeding, issue, message):
    seeding(seed)
    before = snapshot(store)

    assert (run_ap(seed, root, CLAUDE, "sync", issue), capsys.readouterr()) == (
        1, ("", message))
    assert snapshot(store) == before


def test_sync_on_a_missing_issue_dies(root, seed, capsys):
    assert run_ap(seed, root, CLAUDE, "sync", "999") == 1
    assert capsys.readouterr().err.startswith("orch: gh could not read issue #999: ")


def test_sync_with_no_repo_dies_with_the_remedy(root, capsys):
    git = checkout(root, origin=None)

    with pytest.raises(SystemExit) as died:
        autopilot.run(["sync", "5"], gh=Gh(RepoPin(CLAUDE, git), CLAUDE), git=git, env=CLAUDE)
    assert (died.value.code, capsys.readouterr()) == (1, ("", "orch: %s\n" % REPO_REMEDY))


# --- sync-finish, sync-dropped and sync-fail -------------------------------------


@pytest.fixture
def syncing(root, seed):
    """The flow's issue #145 at orch:done with orch:sync, its sync session
    running under its claim; the flow state records it."""
    hold_flow(root, slug="sync", phase="done", issue="145")
    held(seed, 145, "orch:done", "orch:sync", "orch:running")


@pytest.fixture
def dropped(tmp_path):
    return text_file(tmp_path, "dropped.txt", "- dropped thing\n")


def dropped_comment(intents, following):
    """The dropped-intent stop's comment on issue #145 listing <intents>,
    ending <following>."""
    return ("%s\nThe sync pushed its merge, but its resolver dropped these intents:\n\n%s\n\n"
            "No reply is needed. Review the dropped intents; if you accept them, remove"
            " needs-human. To reject one, restore it on the branch first, then remove the"
            " label. The issue no longer carries orch:sync. %s\n"
            % (marker_of("failure", "sync"), intents, following))


AUTO_WORDING = ("Once the label is gone, the watcher files a new sync request by itself whenever"
                " the PR conflicts with its base; or run `orch.sh autopilot sync 145` to sync"
                " now.")
MANUAL_WORDING = "To sync again, run `orch.sh autopilot sync 145`."


@pytest.mark.parametrize("argv", [("sync-finish",), ("sync-dropped", "FILE"),
                                  ("sync-fail", "push rejected")],
                         ids=["finish", "dropped", "fail"])
def test_a_sync_end_with_no_issue_recorded_refuses_making_no_gh_call(
        root, seed, store, capsys, dropped, argv):
    hold_flow(root, slug="x", phase="done", issue=None)
    seed.issue(145, "open", "orch:done", "orch:sync", "orch:running")
    before = snapshot(store)
    argv = [dropped if arg == "FILE" else arg for arg in argv]

    assert (run_ap(seed, root, AUTOPILOT, *argv), capsys.readouterr()) == (
        1, ("", "orch: no issue recorded in state - the spec phase must publish one first\n"))
    assert snapshot(store) == before


def test_sync_finish_takes_orch_sync_off_and_releases_the_claim(
        root, seed, store, capsys, syncing):
    assert (run_ap(seed, root, AUTOPILOT, "sync-finish"), capsys.readouterr()) == (0, ("", ""))
    assert (labels_of(store, 145), comments_of(store, 145)) == (["orch:done"], [])
    assert seed.claim_held(145) is False


def test_sync_finish_failing_on_the_release_passes_the_transition_s_message_through(
        root, seed, capsys, syncing):
    seed.fail("adapter_claim_delete", "HTTP 500")

    assert (run_ap(seed, root, AUTOPILOT, "sync-finish"), capsys.readouterr()) == (
        1, ("", "orch: could not delete the claim ref on issue #145: HTTP 500 - writes that"
                " landed: removed orch:sync, removed orch:running; the claim stays held\n"))
    assert seed.claim_held(145) is True


@pytest.mark.parametrize("local, wording", [
    (None, AUTO_WORDING),
    ({AUTO_SYNC: "true"}, AUTO_WORDING),
    ({AUTO_SYNC: "false"}, MANUAL_WORDING),
], ids=["unset", "true", "false"])
def test_sync_dropped_posts_the_intents_with_the_auto_sync_wording_and_releases(
        root, seed, store, capsys, syncing, dropped, local, wording):
    git = checkout(root, local=local)

    assert (ap(seed, git, AUTOPILOT, "sync-dropped", dropped), capsys.readouterr()) == (
        0, ("", ""))
    assert comments_of(store, 145) == [dropped_comment("- dropped thing\n", wording)]
    assert labels_of(store, 145) == ["orch:done", "needs-human"]
    assert seed.claim_held(145) is False


def test_sync_dropped_with_a_bad_auto_sync_warns_and_still_lands_the_manual_stop(
        root, seed, store, capsys, syncing, dropped):
    git = checkout(root, local={AUTO_SYNC: "maybe"})

    assert (ap(seed, git, AUTOPILOT, "sync-dropped", dropped), capsys.readouterr()) == (
        0, ("", "orch: orchestrator.autopilot.auto-sync is maybe - it must be true or false"
                " (git config orchestrator.autopilot.auto-sync true|false)\n"))
    assert comments_of(store, 145) == [dropped_comment("- dropped thing\n", MANUAL_WORDING)]
    assert (labels_of(store, 145), seed.claim_held(145)) == (["orch:done", "needs-human"], False)


def test_sync_dropped_failing_partway_dies_naming_the_writes_that_landed(
        root, seed, capsys, syncing, dropped):
    seed.fail("adapter_issue_comment", "HTTP 500")

    assert (run_ap(seed, root, AUTOPILOT, "sync-dropped", dropped), capsys.readouterr()) == (
        1, ("", "orch: could not post the failure comment on issue #145: HTTP 500 - writes that"
                " landed: added needs-human, removed orch:sync; the claim stays held\n"))
    assert seed.claim_held(145) is True


def test_sync_dropped_with_a_missing_file_is_refused_before_any_read(
        root, seed, store, capsys, syncing):
    before = snapshot(store)

    assert (run_ap(seed, root, AUTOPILOT, "sync-dropped", "/nonexistent/dropped.txt"),
            capsys.readouterr()) == (
        1, ("", "orch: dropped-intents file not found: /nonexistent/dropped.txt\n"))
    assert snapshot(store) == before


def test_sync_fail_stops_the_sync_keeping_orch_sync_and_resume_lifts_it(
        root, seed, store, capsys, syncing):
    assert (run_ap(seed, root, AUTOPILOT, "sync-fail", "push rejected"),
            capsys.readouterr()) == (0, ("", ""))
    assert sorted(labels_of(store, 145)) == ["needs-human", "orch:done", "orch:sync"]
    assert seed.claim_held(145) is False
    [comment] = comments_of(store, 145)
    assert comment.startswith(marker_of("failure", "sync") + "\nAutopilot failed in the sync:"
                                                            " push rejected\n")

    assert run_ap(seed, root, CLAUDE, "resume", "145") == 0
    assert sorted(labels_of(store, 145)) == ["orch:done", "orch:sync"]


def test_sync_fail_with_an_empty_reason_is_refused_before_any_read(
        root, seed, store, capsys, syncing):
    before = snapshot(store)

    assert (run_ap(seed, root, AUTOPILOT, "sync-fail", ""), capsys.readouterr()) == (
        1, ("", "orch: a sync failure needs a reason\n"))
    assert snapshot(store) == before
