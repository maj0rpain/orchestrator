"""`orch.sh autopilot tick`, its second half - ranking and Pickup within
the Cap and the Sync slots, the direct read before each claim, and
Pickup's steps in order (the trust check, the side checkout, init, the plan
comment, the recorded phase, redo) up to the detached start of `autopilot
run` - run in-process through autopilot.run on the tick fixture of
test_autopilot_tick: a FakeGit main checkout under tmp_path, the gh fake on
a tmp_path store, a fixed clock, and the fake starter standing in for the
init, redo and run children. Each case asserts what the tick leaves behind:
its exit code and messages, the labels, comments and claims on the store,
the side checkouts and flows under tmp_path, and the children it started.
Ported from the bash autopilot sections that held them: autopilot tick and
run, the flow-issue read at the issue-list limit, the direct read before
each claim, the cap, lost claims and the order, side checkouts, refusals
and failed steps, limited issues, the trust check, sync requests, pickup
rank and sync slots, a pickup that meets a GitHub limit, and contained
stops."""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

from conftest import comments_of, hold_flow
from orch.side_checkout import short_slug
from test_autopilot_tick import API_LIMIT, NOW, CountingGh, Ticker

READY_SPEC = ["orch:spec", "ready-for-agent"]
HUMAN_SPEC = ["needs-human", "orch:spec", "ready-for-agent"]
# A limit pause that has passed.
NOW_PAST = NOW - 60


class Picker(Ticker):
    """The tick fixture, with issues a pickup can make a side checkout for
    and side checkouts already holding a flow."""

    def addable(self, name):
        """Side checkout <name> can be added: origin's main fetched, the
        worktree added at it and its git folder made as git makes it. Its
        path."""
        path = "%s/.orchestrator/checkouts/%s" % (self.main, name)
        gitdir = Path(self.main) / "git-dir" / "worktrees" / name
        self.git.seed("fetch_branch_at", self.main, "main", answer=True)
        self.git.seed("worktree_add_detached_at", self.main, path, "refs/remotes/origin/main",
                      answer=None)
        self.git.seed("absolute_git_dir_at", path, answer=str(gitdir))
        gitdir.mkdir(parents=True, exist_ok=True)
        return path

    def issue(self, n, title, *labels):
        """Issue #n, open, titled <title>, carrying <labels> (ready for
        agent at spec when none), its side checkout addable under its short
        slug."""
        self.seed.issue(n, "open", *(labels or READY_SPEC))
        self.seed.title(n, title)
        self.addable(short_slug(title))

    def side(self, name, n, phase="spec"):
        """Side checkout <name> recording issue #n, holding its flow at
        <phase>: its path."""
        path = self.clone.add(name, "orch/%d-%s" % (n, name), marker="%d\n" % n)
        hold_flow(Path(path), slug=name, issue=n, phase=phase)
        return path

    def flowing(self, n, phase="spec", *labels):
        """Issue #n, open with <labels> (ready for agent at spec when none),
        its side checkout flowing-<n> holding its flow at <phase> and its
        plan comment posted, so a pickup starts neither init nor a post.
        The side checkout's path."""
        from orch.marked_comment import marked_comment_write

        path = self.side("flowing-%d" % n, n, phase)
        self.seed.issue(n, "open", *(labels or READY_SPEC))
        self.seed.comment(n, "fake-gh", "2026-01-01T00:00:00Z",
                          marked_comment_write("handoff", "01-plan") + "the plan\n")
        return path

    def added(self, name):
        """The side checkout <name> a pickup added, listed from now on as
        git lists a worktree, its git pointer naming the folder add
        marked."""
        from orch.git import Worktree

        path = "%s/.orchestrator/checkouts/%s" % (self.main, name)
        with open(os.path.join(path, ".git"), "w") as f:
            f.write("gitdir: %s/git-dir/worktrees/%s\n" % (self.main, name))
        self.clone.worktrees.append(Worktree(path, None))
        return path

    def runs(self):
        return self.children.runs()

    def recorded(self, path):
        return json.loads((Path(path) / ".orchestrator" / "state.json").read_text())["phase"]


@pytest.fixture
def p(tmp_path, seed, proc, claude_bin, monkeypatch):
    monkeypatch.chdir(tmp_path)
    return Picker(tmp_path, seed, proc, claude_bin)


# --- the cap, lost claims and the order ------------------------------------------


def test_a_tick_under_a_cap_of_2_starts_the_two_oldest_and_the_third_waits(p):
    for n in (9, 7, 8):
        p.issue(n, "Issue %d" % n)
    p.set("cap", "2")

    assert p.tick() == 0
    assert p.runs() == ["7", "8"]
    assert p.labels(9) == READY_SPEC
    assert p.seed.claim_held(9) is False


def test_claims_of_other_hosts_count_against_the_cap_and_a_lost_claim_skips_its_issue(p):
    p.issue(7, "Issue 7")
    p.issue(8, "Issue 8")
    p.claim(7, host="otherhost")
    p.claim(90, host="otherhost")
    p.set("cap", "3")

    assert p.tick() == 0
    assert p.runs() == ["8"]
    assert p.seed.claim_held(7) is True
    assert p.labels(7) == READY_SPEC


def test_running_needs_human_closed_done_and_unlabelled_issues_are_not_picked_up(p):
    p.seed.issue(7, "open", "ready-for-agent", "orch:spec", "orch:running")
    p.seed.issue(8, "open", "ready-for-agent", "orch:spec", "needs-human")
    p.seed.issue(9, "closed", "ready-for-agent", "orch:spec")
    p.seed.issue(10, "open", "ready-for-agent", "orch:done")
    p.seed.issue(11, "open", "ready-for-agent")

    assert p.tick() == 0
    assert p.children.calls == []
    assert not any(p.seed.claim_held(n) for n in (8, 9, 10, 11))


def test_a_claim_create_failing_for_another_reason_stops_the_tick_naming_it(p, capsys):
    p.issue(7, "Issue 7")
    p.seed.fail("adapter_claim_create", "HTTP 500 pushing the ref")

    assert p.tick() == 1
    assert capsys.readouterr().err.endswith(
        "orch: could not claim issue #7: HTTP 500 pushing the ref - the tick stops\n")
    assert p.children.calls == []


def test_a_claimed_issue_gets_a_tick_record_of_the_tick_s_process(p):
    p.issue(7, "Issue 7")

    assert p.tick() == 0
    assert p.text("run/7.tick") == "%d %s\n" % (os.getpid(), "424242")


# --- pickup rank and sync slots ---------------------------------------------------


def rank_sides(p):
    """Issues 20, 21 and 22 at spec, implement and review, and the sync
    requests 31 and 32, each with a side checkout recording its phase."""
    for n, phase in ((20, "spec"), (21, "implement"), (22, "review"), (31, "done"),
                     (32, "done")):
        p.side("rank-%d" % n, n, phase)
    p.seed.issue(20, "open", "ready-for-agent", "orch:spec")
    p.seed.issue(21, "open", "ready-for-agent", "orch:implement")
    p.seed.issue(22, "open", "ready-for-agent", "orch:review")
    p.seed.issue(31, "open", "orch:done", "orch:sync")
    p.seed.issue(32, "open", "orch:done", "orch:sync")


def test_sync_requests_come_first_then_review_implement_and_spec_oldest_first(p):
    rank_sides(p)
    p.set("cap", "6")

    assert p.tick() == 0
    assert p.runs() == ["31", "32", "22", "21", "20"]
    assert p.labels(31) == ["orch:done", "orch:running", "orch:sync"]


def test_at_a_full_cap_the_sync_slots_take_sync_requests_and_no_phase(p):
    rank_sides(p)
    p.set("cap", "4")
    for n in (90, 91, 92, 93):
        p.claim(n, host="otherhost")

    assert p.tick() == 0
    assert p.runs() == ["31", "32"]
    assert p.labels(20) == READY_SPEC


def test_with_cap_and_sync_slots_claimed_no_sync_request_is_read_or_claimed(p):
    rank_sides(p)
    p.set("cap", "4")
    for n in range(90, 96):
        p.claim(n, host="otherhost")
    assert p.tick(gh_class=ReadCounting) == 0
    assert p.runs() == []
    assert p.gh.reads == []


def test_at_cap_1_there_is_no_sync_slot(p):
    rank_sides(p)
    p.set("cap", "1")
    p.claim(90, host="otherhost")

    assert p.tick() == 0
    assert p.runs() == []


def test_a_limited_issue_ranks_by_what_it_resumes(p):
    rank_sides(p)
    p.set("cap", "6")
    p.seed.issue(20, "closed")
    p.seed.issue(22, "closed")
    p.seed.labels(21, "ready-for-agent", "orch:implement", "orch:limited")
    p.seed.labels(31, "orch:done", "orch:sync", "orch:limited")

    assert p.tick() == 0
    assert p.runs() == ["31", "32", "21"]


def test_a_sync_request_lost_to_another_host_is_skipped_and_the_next_claimed(p):
    rank_sides(p)
    p.set("cap", "6")
    p.claim(31, host="otherhost")

    assert p.tick() == 0
    assert p.runs()[:2] == ["32", "22"]
    assert "31" not in p.runs()


def test_a_re_entered_review_issue_is_picked_up(p):
    from orch.marked_comment import marked_comment_write

    p.side("rank-22", 22, "review")
    p.seed.issue(22, "open", "ready-for-agent", "orch:review")
    p.seed.comment(22, "o", "2026-01-01T00:00:00Z",
                   marked_comment_write("reentry", "review") + "stop reason\n")

    assert p.tick() == 0
    assert p.runs() == ["22"]


# --- the flow listing and the direct read before each claim -----------------------


class ReadCounting(CountingGh):
    """The counting gh fake, keeping each issue it reads directly and
    counting its listings of the flow issues."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.reads = []
        self.flow_reads = 0

    def issue_state_labels(self, n):
        self.reads.append(n)
        return super().issue_state_labels(n)

    def issues_any_labelled_rows(self, *labels):
        self.flow_reads += 1
        return super().issues_any_labelled_rows(*labels)


def test_an_idle_tick_over_unpickable_flow_issues_lists_once_and_reads_no_issue(p):
    p.seed.issue(41, "open", "orch:spec", "orch:running")
    p.seed.issue(42, "open", "orch:implement", "needs-human")
    p.seed.issue(43, "open", "orch:done")
    p.seed.issue(44, "open", "orch:done", "orch:running")

    assert p.tick(gh_class=ReadCounting) == 0
    assert (p.gh.done_reads, p.gh.flow_reads, p.gh.reads) == (1, 1, [])


def test_a_tick_at_its_cap_reads_no_issue(p):
    p.issue(45, "Cap 45")
    p.set("cap", "2")
    p.claim(90, host="otherhost")
    p.claim(91, host="otherhost")

    assert p.tick(gh_class=ReadCounting) == 0
    assert p.gh.reads == []


def test_a_sync_request_in_a_free_sync_slot_is_read_and_the_phase_past_the_cap_never(p):
    p.issue(45, "Cap 45")
    p.side("sync-46", 46, "done")
    p.seed.issue(46, "open", "orch:done", "orch:sync")
    p.set("cap", "2")
    p.claim(90, host="otherhost")
    p.claim(91, host="otherhost")

    assert p.tick(gh_class=ReadCounting) == 0
    assert 46 in p.gh.reads and 45 not in p.gh.reads
    assert p.runs() == ["46"]


@pytest.mark.parametrize("state,labels", [
    ("closed", READY_SPEC),
    ("open", HUMAN_SPEC),
    ("open", ["orch:implement", "ready-for-agent"]),
])
def test_a_row_served_late_whose_issue_is_no_longer_pickable_there_is_skipped_silently(
        p, capsys, state, labels):
    p.issue(47, "Late 47")
    p.seed.lag("adapter_issues_any_labelled_rows", 1, "47\nOPEN\n2\norch:spec\nready-for-agent")
    p.seed.issue(47, state, *labels)

    assert p.tick() == 0
    assert p.children.calls == []
    assert "47" not in capsys.readouterr().err
    assert p.seed.claim_held(47) is False


def test_the_pickup_acts_on_the_direct_read_s_limited_flag_not_the_row_s(p):
    p.issue(48, "Limited 48", "orch:limited", *READY_SPEC)
    p.seed.lag("adapter_issues_any_labelled_rows", 1, "48\nOPEN\n2\norch:spec\nready-for-agent")

    assert p.tick() == 0
    assert p.runs() == ["48"]
    assert p.labels(48) == ["orch:running", "orch:spec", "ready-for-agent"]


def test_a_failed_direct_read_stops_the_tick_and_makes_no_claim(p, capsys):
    p.issue(49, "Read 49")
    p.seed.fail("adapter_issue_state_labels", "HTTP 502")

    assert p.tick() == 1
    assert capsys.readouterr().err.endswith("orch: could not read issue #49: HTTP 502\n")
    assert p.seed.claim_held(49) is False


def test_a_flow_listing_at_the_issue_list_limit_picks_up_the_oldest_and_warns(p, capsys):
    for n in (7, 8, 9, 10):
        p.issue(n, "Issue %d" % n)
    p.set("cap", "3")
    p.env["ORCH_ISSUE_LIST_LIMIT"] = "3"

    assert p.tick() == 0
    assert p.runs() == ["7", "8", "9"]
    assert ("orch: the open issues labelled orch:spec or orch:implement or orch:review or"
            " orch:sync reached the issue-list limit of 3 - the newest past it are missing from"
            " this list\n") in capsys.readouterr().err


def test_a_failed_flow_listing_fails_the_tick_naming_the_labels(p, capsys):
    p.issue(7, "Issue 7")
    p.seed.fail("adapter_issues_any_labelled_rows", "HTTP 502")

    assert p.tick() == 1
    assert capsys.readouterr().err.endswith(
        "orch: could not list the issues labelled orch:spec or orch:implement or orch:review or"
        " orch:sync: HTTP 502\n")


# --- side checkouts, init and the plan comment -------------------------------------


def test_a_hand_labelled_issue_gets_a_side_checkout_its_flow_and_the_minimal_plan(p, capsys):
    p.issue(7, "Add the widget")
    side = "%s/.orchestrator/checkouts/add-the-widget" % p.main

    assert p.tick() == 0
    [(argv, how)] = p.children.of("init")
    assert argv[1:] == ["init", "add-the-widget", "--issue", "7"]
    assert (how["cwd"], how["env"]["ORCH_AUTOPILOT"], how["stdout"]) == (
        side, "1", subprocess.DEVNULL)
    assert "ORCH_AUTOPILOT" not in p.env
    assert p.recorded(side) == "spec"
    plan = comments_of(p.store, 7)[-1]
    assert plan.startswith("<!-- orch:handoff 01-plan -->\n")
    assert "Rounds: 2\nBudget: 3\n" in plan
    assert "This issue was adopted to be reviewed as it stands: no spec was written for it." in plan
    assert p.labels(7) == ["orch:running", "orch:spec", "ready-for-agent"]
    assert p.runs() == ["7"]
    assert "no finished side checkouts\n" in capsys.readouterr().err


def test_a_plan_comment_the_issue_already_has_is_not_posted_again(p):
    p.flowing(7)

    assert p.tick() == 0
    assert len(comments_of(p.store, 7)) == 1
    assert p.children.of("init") == []
    assert p.runs() == ["7"]


def test_the_side_checkout_is_named_for_the_title_s_short_slug(p):
    p.issue(21, "Fix the widget")

    assert p.tick() == 0
    [(argv, how)] = p.children.of("init")
    assert (argv[2], how["cwd"]) == ("fix-the-widget",
                                     "%s/.orchestrator/checkouts/fix-the-widget" % p.main)


def test_a_clash_moves_on_to_the_issue_numbered_name(p):
    p.side("fix-the-widget", 22)
    p.seed.issue(25, "open", *READY_SPEC)
    p.seed.title(25, "Fix the widget")
    p.addable("fix-the-widget-25")

    assert p.tick() == 0
    assert [argv[2] for argv, _ in p.children.of("init")] == ["fix-the-widget-25"]


def test_a_re_pickup_reuses_the_issue_s_side_checkout_whatever_its_name(p):
    side = p.clone.add("26-legacy-title", "orch/26-x", marker="26\n")
    p.seed.issue(26, "open", *READY_SPEC)
    p.seed.title(26, "Legacy title")

    assert p.tick() == 0
    [(argv, how)] = p.children.of("init")
    assert (argv[2], how["cwd"]) == ("26-legacy-title", side)
    assert p.runs() == ["26"]


def test_an_init_refusal_stops_the_issue_keeping_its_side_checkout_and_the_tick_goes_on(
        p, capsys):
    p.issue(7, "Needs ready", "orch:spec")
    p.children.fails["init"] = "orch: issue #7 does not carry ready-for-agent\n"

    assert p.tick() == 0
    assert p.runs() == []
    assert p.labels(7) == ["needs-human", "orch:spec"]
    assert p.seed.claim_held(7) is False
    assert ("step init failed: orch: issue #7 does not carry ready-for-agent"
            in comments_of(p.store, 7)[-1])
    assert "spec phase" in comments_of(p.store, 7)[-1]


def test_a_failed_title_read_is_a_failed_side_checkout_add(p):
    p.issue(8, "Blocked add")
    p.seed.fail("adapter_issue_title_labels", "HTTP 502 title")

    assert p.tick() == 0
    assert ("step side-checkout add failed: could not read the issue's title: HTTP 502 title"
            in comments_of(p.store, 8)[-1])
    assert p.seed.claim_held(8) is False


def test_a_failed_side_checkout_add_is_a_failure_its_report_on_the_tick_s_stderr(p, capsys):
    p.seed.issue(8, "open", *READY_SPEC)
    p.seed.title(8, "Blocked add")
    p.git.seed("fetch_branch_at", p.main, "main", answer=False)

    assert p.tick() == 0
    comment = comments_of(p.store, 8)[-1]
    assert ("step side-checkout add failed: orch: could not fetch base branch main from origin"
            " - no side checkout was made") in comment
    assert "no finished side checkouts" not in comment
    assert "no finished side checkouts\n" in capsys.readouterr().err
    assert (p.labels(8), p.seed.claim_held(8)) == (HUMAN_SPEC, False)


def test_a_failed_plan_comment_post_is_a_failure_leaving_no_temp_file(
        p, tmp_path, monkeypatch):
    import tempfile

    scratch = tmp_path / "tmp"
    scratch.mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(scratch))
    p.issue(9, "No plan")
    p.seed.fail_times("adapter_issue_comment", 1, "HTTP 500 comment")

    assert p.tick() == 0
    assert ("step minimal plan comment failed: orch: gh could not post the 01-plan handoff on"
            " issue #9: HTTP 500 comment") in comments_of(p.store, 9)[-1]
    assert (p.labels(9), p.seed.claim_held(9), p.runs()) == (HUMAN_SPEC, False, [])
    assert list(scratch.iterdir()) == []


def test_a_failed_comments_read_is_a_failed_plan_comment_step(p):
    p.issue(9, "No plan")
    p.seed.fail_times("adapter_issue_comments", 1, "HTTP 502 comments")

    assert p.tick() == 0
    assert ("step minimal plan comment failed: orch: gh could not read the comments of issue"
            " #9: HTTP 502 comments") in comments_of(p.store, 9)[-1]


def test_a_failed_orch_running_write_keeps_begin_s_own_wording(p):
    p.flowing(21)
    p.seed.fail_times("adapter_issue_relabel", 1, "HTTP 500")

    assert p.tick() == 0
    assert ("Autopilot failed in the spec phase: step adding orch:running failed: HTTP 500"
            in comments_of(p.store, 21)[-1])
    assert p.seed.claim_held(21) is False


def test_a_step_s_reason_is_its_last_orch_line_the_other_lines_reaching_stderr(p, capsys):
    p.issue(7, "Noisy init")
    p.children.fails["init"] = "warning one\norch: first\nwarning two\norch: the real cause\n"

    assert p.tick() == 0
    assert "step init failed: orch: the real cause" in comments_of(p.store, 7)[-1]
    assert "warning one\norch: first\nwarning two\n" in capsys.readouterr().err


@pytest.mark.parametrize("err,reason", [
    ("first\nlast words\n\n", "last words"),
    ("", "the step gave no reason"),
])
def test_with_no_orch_line_the_reason_is_the_last_non_empty_line_or_none_given(p, err, reason):
    p.issue(7, "Plain init")
    p.children.fails["init"] = err

    assert p.tick() == 0
    assert "step init failed: %s\n" % reason in comments_of(p.store, 7)[-1]


def test_a_succeeding_step_passes_its_stderr_on(p, capsys):
    p.issue(7, "Fine init")
    p.children.notes["init"] = "note a\nnote b\n"

    assert p.tick() == 0
    assert p.runs() == ["7"]
    assert "note a\nnote b\n" in capsys.readouterr().err


# --- the recorded phase and redo -----------------------------------------------------


@pytest.mark.parametrize("label,recorded", [
    ("orch:review", "spec"), ("orch:implement", "done"), ("orch:spec", "review")])
def test_a_label_not_one_step_back_from_the_recorded_phase_is_refused_naming_the_rule(
        p, label, recorded):
    p.side("skip-7", 7, recorded)
    p.seed.issue(7, "open", "ready-for-agent", label)

    assert p.tick() == 0
    assert (p.runs(), p.children.of("redo")) == ([], [])
    assert ("the issue is labelled %s, but its side checkout last moved to phase %s - only a step"
            " back from review to implement or from implement to spec is a redo"
            % (label, recorded)) in comments_of(p.store, 7)[-1]
    assert sorted(p.labels(7)) == sorted(["needs-human", label, "ready-for-agent"])
    assert p.seed.claim_held(7) is False


def test_one_step_back_runs_redo_in_the_side_checkout_and_starts_the_new_phase(p):
    side = p.side("back-7", 7, "implement")
    p.seed.issue(7, "open", *READY_SPEC)

    assert p.tick() == 0
    [(argv, how)] = p.children.of("redo")
    assert (argv[1:], how["cwd"], how["env"]["ORCH_AUTOPILOT"]) == (["redo", "spec"], side, "1")
    assert p.recorded(side) == "spec"
    assert p.runs() == ["7"]


def test_a_redo_refusal_is_a_refusal(p):
    p.side("back-7", 7, "review")
    p.seed.issue(7, "open", "ready-for-agent", "orch:implement")
    p.children.fails["redo"] = "orch: the review loop has not reached a terminal state\n"

    assert p.tick() == 0
    comment = comments_of(p.store, 7)[-1]
    assert ("redo review refused: orch: the review loop has not reached a terminal state"
            in comment)
    assert "refused to run the implement phase" in comment
    assert p.runs() == []


def test_an_unreadable_state_file_stops_the_issue_with_the_plain_reason(p):
    side = p.flowing(7)
    (Path(side) / ".orchestrator" / "state.json").write_text('{"phase": "sp')

    assert p.tick() == 0
    assert ("step reading the recorded phase failed: state.json in %s cannot be read - run"
            " orch.sh doctor --flow" % side) in comments_of(p.store, 7)[-1]
    assert (p.labels(7), p.seed.claim_held(7), p.runs()) == (HUMAN_SPEC, False, [])


# --- the trust check ----------------------------------------------------------------


def test_an_untrusted_issue_is_refused_first_leaving_no_side_checkout_flow_or_plan(p):
    p.issue(8, "Trust 8")
    p.seed.authorship(8, "stranger", "NONE")

    assert p.tick() == 0
    assert p.children.calls == []
    comment = comments_of(p.store, 8)[-1]
    assert ("the issue's title and body was last written by stranger, who is not an owner,"
            " member or collaborator of the repository - an owner, member or collaborator must"
            " edit it before autopilot runs on it") in comment
    assert "refused to run the spec phase" in comment
    assert (p.labels(8), p.seed.claim_held(8)) == (["needs-human", "orch:spec",
                                                     "ready-for-agent"], False)
    assert not os.path.exists(os.path.join(p.main, ".orchestrator", "checkouts"))
    assert not any("01-plan" in body for body in comments_of(p.store, 8))


def test_a_stranger_re_editing_a_trusted_issue_is_refused_at_the_next_phase(p):
    p.flowing(11, "implement", "ready-for-agent", "orch:implement")
    p.seed.authorship(11, "stranger", "NONE", "stranger")

    assert p.tick() == 0
    assert p.runs() == []
    assert "the issue's title and body was last written by stranger" in comments_of(p.store, 11)[-1]


def test_a_failed_trust_read_fails_closed(p):
    p.issue(12, "Trust 12")
    p.seed.fail("adapter_issue_authorship", "HTTP 502 authorship")

    assert p.tick() == 0
    assert p.children.calls == []
    assert "step trust read failed: HTTP 502 authorship" in comments_of(p.store, 12)[-1]
    assert (p.labels(12), p.seed.claim_held(12)) == (HUMAN_SPEC, False)


# --- limited issues -----------------------------------------------------------------


def test_after_a_usage_pause_limited_issues_start_oldest_first_orch_limited_removed(p):
    for n in (5, 6, 7):
        p.issue(n, "Lim %d" % n, *(READY_SPEC + (["orch:limited"] if n > 5 else [])))
    p.set("cap", "2")
    p.pause("limit", NOW_PAST)

    assert p.tick() == 0
    assert p.runs() == ["5", "6"]
    assert p.labels(6) == ["orch:running", "orch:spec", "ready-for-agent"]
    assert p.labels(7) == ["orch:limited", "orch:spec", "ready-for-agent"]


def test_under_the_usage_pause_no_limited_issue_is_picked_up(p):
    p.issue(6, "Lim 6", "orch:limited", *READY_SPEC)
    p.pause("limit", NOW + 3600)

    assert p.tick() == 0
    assert (p.runs(), p.labels(6)) == ([], ["orch:limited", "orch:spec", "ready-for-agent"])


def test_a_lost_claim_leaves_orch_limited_in_place(p):
    p.issue(6, "Lim 6", "orch:limited", *READY_SPEC)
    p.claim(6, host="otherhost")

    assert p.tick() == 0
    assert p.labels(6) == ["orch:limited", "orch:spec", "ready-for-agent"]


def test_a_failed_orch_limited_removal_ends_needs_human_with_no_orch_limited(p):
    p.flowing(6, "spec", "orch:limited", *READY_SPEC)
    p.seed.fail_times("adapter_issue_relabel", 1, "HTTP 500")

    assert p.tick() == 0
    assert "step removing orch:limited failed: HTTP 500" in comments_of(p.store, 6)[-1]
    assert (p.labels(6), p.runs()) == (HUMAN_SPEC, [])


def test_an_early_step_failing_on_a_limited_issue_ends_needs_human_only(p):
    p.issue(9, "Lim 9 needs ready", "orch:spec", "orch:limited")
    p.children.fails["init"] = "orch: not ready\n"

    assert p.tick() == 0
    assert p.labels(9) == ["needs-human", "orch:spec"]
    assert "step init failed" in comments_of(p.store, 9)[-1]


# --- sync requests --------------------------------------------------------------------


def test_a_sync_request_with_a_done_side_checkout_starts_its_run_and_adds_nothing(p):
    side = p.side("sync-seven", 7, "done")
    p.seed.issue(7, "open", "orch:done", "orch:sync")

    assert p.tick() == 0
    assert p.runs() == ["7"]
    assert p.labels(7) == ["orch:done", "orch:running", "orch:sync"]
    assert [argv[1] for argv, _ in p.children.calls] == ["autopilot"]
    assert comments_of(p.store, 7) == []
    assert p.recorded(side) == "done"


def test_with_auto_sync_false_a_hand_added_sync_request_is_still_picked_up(p):
    p.side("sync-seven", 7, "done")
    p.seed.issue(7, "open", "orch:done", "orch:sync")
    p.set("auto-sync", "false")

    assert p.tick() == 0
    assert p.runs() == ["7"]


def test_orch_sync_without_orch_done_is_no_sync_request_but_a_live_phase_still_is(p):
    p.issue(9, "Slip nine", "ready-for-agent", "orch:sync")

    assert p.tick() == 0
    assert (p.runs(), p.labels(9)) == ([], ["orch:sync", "ready-for-agent"])

    p.seed.labels(9, "orch:spec", "ready-for-agent", "orch:sync")
    assert p.tick() == 0
    assert p.runs() == ["9"]
    assert [argv[1] for argv, _ in p.children.calls] == ["init", "autopilot"]


def test_a_sync_request_whose_side_checkout_is_not_at_done_is_refused_naming_it(p):
    p.side("sync-seven", 7, "review")
    p.seed.issue(7, "open", "orch:done", "orch:sync")

    assert p.tick() == 0
    comment = comments_of(p.store, 7)[-1]
    assert comment.startswith("<!-- orch:refusal sync -->\n")
    assert ("the issue carries a sync request, but its side checkout records phase review, not"
            " done") in comment
    assert (p.labels(7), p.seed.claim_held(7), p.runs()) == (
        ["needs-human", "orch:done", "orch:sync"], False, [])


def test_a_sync_request_with_no_side_checkout_is_refused_saying_where_to_sync(p):
    p.seed.issue(12, "open", "orch:done", "orch:sync")

    assert p.tick() == 0
    comment = comments_of(p.store, 12)[-1]
    assert comment.startswith("<!-- orch:refusal sync -->\n")
    assert ("no side checkout on this host holds issue #12 - run /orchestrator:sync where it"
            " lives") in comment
    assert (p.labels(12), p.seed.claim_held(12)) == (["needs-human", "orch:done", "orch:sync"],
                                                      False)
    assert p.children.calls == []
    assert not os.path.exists(os.path.join(p.main, ".orchestrator", "checkouts"))


def test_an_untrusted_sync_request_is_refused_by_the_trust_check(p):
    p.side("sync-13", 13, "done")
    p.seed.issue(13, "open", "orch:done", "orch:sync")
    p.seed.authorship(13, "stranger", "NONE")

    assert p.tick() == 0
    assert "last written by stranger" in comments_of(p.store, 13)[-1]
    assert p.labels(13) == ["needs-human", "orch:done", "orch:sync"]


def test_a_sync_request_counts_toward_the_cap_ahead_of_the_phases(p):
    p.side("sync-seven", 7, "done")
    p.seed.issue(7, "open", "orch:done", "orch:sync")
    p.issue(8, "Sync eight")
    p.issue(6, "Sync six")
    p.set("cap", "2")

    assert p.tick() == 0
    assert p.runs() == ["7", "6"]
    assert p.labels(8) == READY_SPEC


# --- a pickup that meets a GitHub limit --------------------------------------------


def test_a_pickup_that_meets_a_github_limit_only_deletes_the_claim_and_ends_the_tick(p):
    p.issue(7, "Limit pickup 7")
    p.issue(8, "Limit pickup 8")
    p.seed.fail_times("adapter_issue_comment", 1, API_LIMIT)

    assert p.tick() == 0
    assert p.seed.claim_held(7) is False
    assert not any("orch:" in body for body in comments_of(p.store, 7))
    assert p.labels(7) == READY_SPEC
    assert (p.seed.claim_held(8), p.runs()) == (False, [])
    assert p.text("github-limit") is not None

    os.remove(p.path("github-limit"))
    p.added("limit-pickup-7")
    p.children.calls.clear()
    assert p.tick() == 0
    assert p.runs() == ["7", "8"]


def test_a_failed_claim_delete_after_a_github_limit_leaves_the_claim_held(p, capsys):
    p.issue(9, "Limit pickup 9")
    p.seed.fail_times("adapter_issue_comment", 1, API_LIMIT)
    p.seed.fail("adapter_claim_delete", "HTTP 500 push")

    assert p.tick() == 0
    assert p.seed.claim_held(9) is True
    assert ("orch: could not delete the claim ref on issue #9; it stays held for stale cleanup\n"
            in capsys.readouterr().err)


# --- stops that cannot land are contained --------------------------------------------


def test_a_failed_step_whose_stop_cannot_land_is_contained_and_the_next_issue_picked_up(
        p, capsys):
    p.issue(7, "Contained step 7", "orch:spec")
    p.flowing(8)
    p.children.fails["init"] = "orch: not ready\n"
    p.seed.fail_times("adapter_issue_relabel", 1, "HTTP 500 relabel")

    assert p.tick() == 0
    err = capsys.readouterr().err
    warning = ("orch: could not stop issue #7 - its claim stays held; failure: step init failed:"
               " orch: not ready; a later tick's stale cleanup stops it\n")
    assert warning in err
    assert "orch: could not " in err[:err.index(warning)]
    assert p.seed.claim_held(7) is True
    assert p.runs() == ["8"]

    # The first tick's process has exited: its tick record names a gone
    # process.
    p.put("run/7.tick", "999999 1\n")
    assert p.tick() == 0
    assert (p.labels(7), p.seed.claim_held(7)) == (["needs-human", "orch:spec"], False)


def test_a_refusal_whose_stop_cannot_land_is_contained_with_its_kind(p, capsys):
    p.side("refusal-7", 7, "spec")
    p.seed.issue(7, "open", "ready-for-agent", "orch:review")
    p.issue(8, "Contained refusal 8")
    p.seed.fail_times("adapter_issue_relabel", 1, "HTTP 500 relabel")

    assert p.tick() == 0
    assert ("could not stop issue #7 - its claim stays held; refusal: the issue is labelled"
            " orch:review" in capsys.readouterr().err)
    assert (p.seed.claim_held(7), p.runs()) == (True, ["8"])


def test_a_pickup_whose_stop_meets_a_github_limit_ends_the_tick(p, capsys):
    p.issue(7, "Limited stop 7", "orch:spec")
    p.issue(8, "Limited stop 8")
    p.children.fails["init"] = "orch: not ready\n"
    p.seed.fail_times("adapter_issue_relabel", 1, API_LIMIT)

    assert p.tick() == 0
    assert "could not stop issue #7 - its claim stays held" in capsys.readouterr().err
    assert p.text("github-limit") is not None
    assert (p.seed.claim_held(7), p.seed.claim_held(8)) == (True, False)


def test_a_claim_held_after_a_failed_stale_stop_still_counts_against_the_cap(p):
    p.set("cap", "1")
    p.claim(5)
    p.issue(7, "Cap stale 7")

    assert p.tick() == 0
    assert p.tick() == 0
    assert p.seed.claim_held(7) is False


def test_a_claim_held_after_a_failed_pickup_stop_still_counts_against_the_cap(p):
    p.set("cap", "1")
    p.issue(7, "Cap pickup 7", "orch:spec")
    p.issue(8, "Cap pickup 8")
    p.children.fails["init"] = "orch: not ready\n"
    p.seed.fail("adapter_issue_relabel", "HTTP 500 relabel")

    assert p.tick() == 0
    assert p.tick() == 0
    assert p.seed.claim_held(8) is False


# --- the run's detached start --------------------------------------------------------


def test_each_run_starts_detached_from_the_main_checkout_through_orch_sh(p):
    from orch.agent import default_plugin_root

    p.issue(7, "Issue 7")

    assert p.tick() == 0
    [(argv, how)] = p.children.of("autopilot")
    assert argv == [os.path.join(default_plugin_root(), "scripts", "orch.sh"),
                    "autopilot", "run", "7"]
    assert (how["cwd"], how["start_new_session"], how["stdin"], how["stdout"],
            how["stderr"]) == (p.main, True, subprocess.DEVNULL, subprocess.DEVNULL,
                               subprocess.DEVNULL)
    assert how["env"]["ORCH_AUTOPILOT_TICK"] == "1"
    assert p.children.started[-1].waited is False


def test_under_orch_autopilot_foreground_the_run_starts_the_same_way_and_is_waited_for(p):
    p.issue(7, "Issue 7")
    p.env["ORCH_AUTOPILOT_FOREGROUND"] = "1"

    assert p.tick() == 0
    [(_, how)] = p.children.of("autopilot")
    assert how["start_new_session"] is True
    assert p.children.started[-1].waited is True


@pytest.mark.parametrize("foreground", ["", "1"])
def test_a_run_the_starter_cannot_start_is_ignored_its_claim_left_for_stale_cleanup(
        p, capsys, foreground):
    p.issue(7, "Issue 7")
    p.issue(8, "Issue 8")
    p.env["ORCH_AUTOPILOT_FOREGROUND"] = foreground
    p.children.unstartable.add("autopilot")

    assert p.tick() == 0
    assert [argv[3] for argv, _ in p.children.of("autopilot")] == ["7", "8"]
    assert (p.seed.claim_held(7), p.seed.claim_held(8)) == (True, True)
    assert p.labels(7) == ["orch:running", "orch:spec", "ready-for-agent"]
    assert capsys.readouterr().out == ""


def test_the_tick_starts_orch_sh_only_for_python_nouns(p):
    from orch.cli import NOUNS

    p.side("back-7", 7, "implement")
    p.seed.issue(7, "open", *READY_SPEC)
    p.issue(8, "Issue 8")

    assert p.tick() == 0
    nouns = [argv[1] for argv, _ in p.children.calls]
    assert sorted(set(nouns)) == ["autopilot", "init", "redo"]
    assert all(noun in NOUNS for noun in nouns if noun != "autopilot")
