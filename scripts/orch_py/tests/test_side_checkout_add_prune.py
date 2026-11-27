"""The side-checkout concept module's add, finished sweep (prune) and
lookups - the verbs `orch.sh side-checkout add` and `prune` run, and Python
autopilot reaches - on a FakeGit checkout at tmp_path and the gh fake on its
store: their stdout, stderr and status, and what they leave on disk and on
the fake. Each message is the one the bash side-checkout noun gave, verbatim,
and the cases are those its bash add, prune, covered-tip, fork-PR, merged-PR
close and default-branch sections checked."""
from __future__ import annotations

import os
from pathlib import Path

import pytest

from conftest import (GITHUB_ORIGIN, CountingGh, SideCheckouts, comments_of, fake, hold_flow,
                      linked_worktree, read, sha_of)
from orch import side_checkout
from orch.base import branch_base_key
from orch.git import FakeGit, GitFailure, Worktree

# The clock the sweep archives and closes at, 2026-06-01T12:00:00Z, and the
# stamp of an archive directory made then.
NOW = 1780315200.0
STAMP = "20260601-120000"
HOUR_AGO = "2026-06-01T11:00:00Z"
MINUTE_AGO = "2026-06-01T11:59:00Z"


def clone_git(tmp_path, cls=FakeGit, **kwargs):
    """The checkout at tmp_path as a <cls>, a FakeGit, made with <kwargs>:
    origin on GitHub, main and uat branch names, its common directory
    tmp_path/git-dir, and no local branch yet."""
    git = cls(remotes=GITHUB_ORIGIN, toplevel=str(tmp_path), branches={}, **kwargs)
    git.seed("is_branch_name", "main", answer=True)
    git.seed("is_branch_name", "uat", answer=True)
    (tmp_path / "git-dir" / "info").mkdir(parents=True)
    git.seed("git_common_dir", answer=str(tmp_path / "git-dir"))
    return git


class Clone(SideCheckouts):
    """The checkout at tmp_path, its side checkouts and other worktrees, and
    GitHub's default branch main: each side checkout's removal goes
    through, unless refused, and its branch is a local branch. <git_kwargs>
    go to clone_git."""

    def __init__(self, tmp_path, seed, **git_kwargs):
        super().__init__(tmp_path, clone_git(tmp_path, **git_kwargs))
        self.seed = seed
        seed.default_branch("main\n")
        self.git.seed("branch_at", str(tmp_path), answer="main")
        self.git.seed("main_checkout", answer=str(tmp_path))

    @property
    def main(self):
        return str(self.tmp_path)

    def add(self, name, branch, tip=None, marker="7\n"):
        path = super().add(name, branch, tip, marker)
        self.git.seed("worktree_remove", self.main, path, answer=None)
        self.git.branches[branch] = None
        return path

    def quick(self, name, issue, n, state="merged"):
        """A flow-less side checkout <name> on quick/<issue>-<name>, its PR
        #n in <state>, and issue #<issue> closed, as that PR's merge closes
        it: its path."""
        branch = "quick/%d-%s" % (issue, name)
        path = self.add(name, branch)
        self.seed.issue(issue, "closed")
        if state == "merged":
            self.merged(self.seed, n, branch, sha_of(name))
        else:
            self.seed.pr(n, state, branch, "main")
        return path

    def flow(self, name, n, phase="done", issue=None):
        """A side checkout <name> holding flow <name>-flow at <phase> on
        orch/<name>-flow, its recorded PR #n merged, its issue <issue>: its
        path."""
        branch = "orch/%s-flow" % name
        path = self.add(name, branch)
        hold_flow(Path(path), slug=name + "-flow", phase=phase, branch=branch, pr=str(n),
                  issue=issue)
        self.merged(self.seed, n, branch, sha_of(name))
        return path

    def hand_made(self, name, **state):
        """A hand-made worktree <name> beside the clone, holding a flow of
        <state>: its path."""
        path = linked_worktree(self.tmp_path, self.tmp_path / "beside" / name)
        self.worktrees.append(Worktree(path, None))
        hold_flow(Path(path), **state)
        return path

    def archived(self, slug):
        return self.tmp_path / ".orchestrator" / "archive" / ("%s-%s" % (STAMP, slug))


@pytest.fixture
def clone(tmp_path, seed):
    return Clone(tmp_path, seed)


def outcome(capsys, call):
    """(exit code, stdout, stderr) of <call>: what it returned (0 for None),
    or the exit it died with."""
    try:
        code = call()
    except SystemExit as died:
        code = died.code
    out, err = capsys.readouterr()
    return (0 if code is None else code), out, err


def prune(capsys, clone, *argv, gh=None):
    """side-checkout prune <argv> from the main checkout, at NOW, the gh fake
    on the clone's store unless <gh>: (exit code, stdout, stderr)."""
    return outcome(capsys, lambda: side_checkout.side_checkout_prune(
        list(argv), fake(clone.seed) if gh is None else gh, clone.git, {}, clone.main,
        here=clone.main, clock=lambda: NOW))


def add(capsys, clone, *argv, gh=None):
    """side-checkout add <argv> from the main checkout, at NOW: (exit code,
    stdout, stderr), the stdout ending in the path add gives."""
    path, code = None, 0
    try:
        path = side_checkout.side_checkout_add(
            list(argv), fake(clone.seed) if gh is None else gh, clone.git, {}, clone.main,
            here=clone.main, clock=lambda: NOW)
    except SystemExit as died:
        code = died.code
    out, err = capsys.readouterr()
    assert path is None or out.endswith(path + "\n")
    return code, out, err


def noun(capsys, clone, *argv):
    """`orch.sh side-checkout <argv>` through the noun's run, from the main
    checkout, at NOW, the gh fake on the clone's store: (exit code, stdout,
    stderr)."""
    return outcome(capsys, lambda: side_checkout.run(
        list(argv), gh=fake(clone.seed), git=clone.git, env={}, clock=lambda: NOW))


# --- the noun's add and prune ------------------------------------------------------


def test_the_noun_s_prune_runs_the_sweep(capsys, clone, monkeypatch):
    monkeypatch.chdir(clone.main)
    qk = clone.quick("qk", 7, 42)

    assert noun(capsys, clone, "prune") == (
        0, "removed side checkout %s\ndeleted branch quick/7-qk\n" % qk, "")


def test_the_noun_s_prune_takes_no_arguments(capsys, clone):
    assert noun(capsys, clone, "prune", "extra") == (
        1, "", "orch: usage: orch.sh side-checkout prune\n")


def test_the_noun_s_add_prints_the_new_path_alone(capsys, adding, monkeypatch):
    monkeypatch.chdir(adding.main)
    path, marker = adding.addable("alpha")

    assert noun(capsys, adding, "add", "alpha", "--issue", "9") == (
        0, path + "\n", "no finished side checkouts\n")
    assert marker.read_text() == "9\n"


def test_the_noun_s_add_wants_a_slug(capsys, adding):
    assert noun(capsys, adding, "add") == (1, "", USAGE)


# --- the finished sweep: verdicts first ------------------------------------------


def test_the_sweep_archives_removes_and_deletes_each_finished_checkout_and_reports_the_rest(
        capsys, clone):
    hold_flow(clone.tmp_path, slug="main-flow", phase="done", branch="orch/main-flow", pr="45")
    clone.seed.pr(45, "merged", "orch/main-flow", "main")
    clone.seed.pr_head(45, sha_of("main"))
    fl = clone.flow("fl", 41)
    qk = clone.quick("qk", 7, 42)
    op = clone.quick("op", 8, 43, state="open")
    dt = clone.quick("dt", 9, 44)
    clone.git.seed("status_at", dt, answer="?? wip.txt\n")
    nd = clone.flow("nd", 46, phase="implement")
    po = clone.flow("po", 61)
    clone.seed.pr(61, "open", "orch/po-flow", "main")
    hand = clone.hand_made("hand", slug="hand-flow", phase="done", branch="orch/hand-flow", pr="47")

    assert prune(capsys, clone) == (0, "".join(line + "\n" for line in [
        "skipped %s: no merged PR from quick/8-op into main" % op,
        "skipped %s: uncommitted changes or untracked files" % dt,
        "skipped %s: flow nd-flow is at implement, not done" % nd,
        "skipped %s: PR #61 is open" % po,
        "%s: not a side checkout, left alone" % hand,
        ".orchestrator/archive/%s-main-flow" % STAMP,
        "archived the main checkout's flow in place - main is still checked out",
        ".orchestrator/archive/%s-fl-flow" % STAMP,
        "removed side checkout " + fl,
        "deleted branch orch/fl-flow",
        "removed side checkout " + qk,
        "deleted branch quick/7-qk",
    ]), "")
    assert sorted(os.listdir(clone.archived("fl-flow"))) == ["state.json"]
    assert not (clone.tmp_path / ".orchestrator" / "state.json").exists()
    assert sorted(clone.git.branches) == ["orch/nd-flow", "orch/po-flow", "quick/8-op",
                                          "quick/9-dt"]
    assert (Path(hand) / ".orchestrator" / "state.json").is_file()


def test_with_nothing_finished_the_sweep_says_so(capsys, clone):
    clone.quick("op", 8, 43, state="open")

    code, out, _ = prune(capsys, clone)
    assert (code, out.splitlines()[-1]) == (0, "no finished side checkouts")


def test_a_checkout_whose_verdict_cannot_be_read_stops_the_sweep_before_anything_goes(
        capsys, clone):
    fin = clone.quick("fin", 20, 60)
    broken = clone.quick("broken", 21, 61)
    clone.git.seed("status_at", broken,
                   answer=GitFailure(128, "fatal: index file corrupt\nmore"))
    bad = clone.add("bad", "orch/bad-flow")
    (Path(bad) / ".orchestrator").mkdir()
    (Path(bad) / ".orchestrator" / "state.json").write_text('{"phase": "do')

    assert prune(capsys, clone) == (1, "", "".join(line + "\n" for line in [
        "orch: could not check %s: git status failed - cannot check the working tree:"
        " fatal: index file corrupt" % broken,
        "orch: could not check %s: could not read %s/.orchestrator/state.json" % (bad, bad),
        "orch: 2 checkout(s) could not be checked - nothing was removed",
    ]))
    assert "quick/20-fin" in clone.git.branches and os.path.isdir(fin)


@pytest.mark.parametrize("operation", ["adapter_pr_state_draft", "adapter_pr_refs",
                                       "adapter_prs_merged"])
def test_a_github_read_that_fails_removes_nothing_naming_gh_s_first_line(
        capsys, clone, operation):
    clone.flow("fl", 41)
    clone.quick("qk", 7, 42)
    clone.seed.fail(operation, "HTTP 502: Bad Gateway\nsecond line")

    code, out, err = prune(capsys, clone)
    assert (code, out) == (1, "")
    assert "could not read GitHub: HTTP 502: Bad Gateway\n" in err
    assert "second line" not in err
    assert err.endswith("orch: 1 checkout(s) could not be checked - nothing was removed\n")
    assert sorted(clone.git.branches) == ["orch/fl-flow", "quick/7-qk"]


def test_checkouts_that_cannot_be_read_remove_nothing(capsys, clone):
    clone.git.seed("worktree_list", answer=None)

    assert prune(capsys, clone) == (
        1, "", "orch: could not read the checkouts - nothing was removed\n")


def test_the_sweep_takes_no_arguments(capsys, clone):
    assert prune(capsys, clone, "extra") == (1, "", "orch: usage: orch.sh side-checkout prune\n")


def test_the_whole_sweep_asks_github_for_the_default_branch_once(capsys, clone):
    for i, name in enumerate(("c1", "c2")):
        clone.quick(name, 11 + i, 49 + i)
        clone.seed.issue(11 + i, "open")
        clone.seed.pr_merged(49 + i, HOUR_AGO, 11 + i)
    gh = CountingGh(clone.seed.store, {}, sleep=lambda _: None)

    code, out, _ = prune(capsys, clone, gh=gh)
    assert (code, len(gh.default_asks)) == (0, 1)
    assert out.count("removed side checkout") == 2


# --- the finished sweep: each verdict's reason, as bash's sections check it --------


def test_a_side_checkout_on_no_branch_is_skipped_as_having_none(capsys, clone):
    nb = clone.add("nb", "quick/1-nb")
    clone.git.seed("branch_at", nb, answer=None)

    assert prune(capsys, clone) == (0, "skipped %s: no branch\nno finished side checkouts\n" % nb,
                                    "")


def test_a_done_flow_whose_pr_is_closed_unmerged_is_skipped_naming_it_closed(capsys, clone):
    pc = clone.flow("pc", 62)
    clone.seed.pr(62, "closed", "orch/pc-flow", "main")

    assert prune(capsys, clone)[:2] == (
        0, "skipped %s: PR #62 is closed\nno finished side checkouts\n" % pc)


def test_a_github_read_failing_with_nothing_on_stderr_says_gh_gave_no_reason(capsys, clone):
    fl = clone.flow("fl", 41)
    clone.seed.fail("adapter_pr_state_draft", "")

    assert prune(capsys, clone) == (1, "", (
        "orch: could not check %s: could not read GitHub: gh gave no reason\n"
        "orch: 1 checkout(s) could not be checked - nothing was removed\n" % fl))
    assert "orch/fl-flow" in clone.git.branches


@pytest.mark.parametrize("kind", ["flow-less", "flow"])
def test_a_tip_past_its_merged_pr_s_head_keeps_the_checkout_and_its_branch(
        capsys, clone, kind):
    if kind == "flow":
        path, branch = clone.flow("up", 81), "orch/up-flow"
    else:
        path, branch = clone.quick("up", 31, 81), "quick/31-up"
    clone.tip(branch, sha_of("up-follow-up"))
    clone.git.seed("ancestry", sha_of("up-follow-up"), sha_of("up"), answer=False)

    assert prune(capsys, clone)[:2] == (0, (
        "skipped %s: %s has commits past PR #81's merged head %s\nno finished side checkouts\n"
        % (path, branch, sha_of("up")[:7])))
    assert branch in clone.git.branches


def test_a_tip_behind_its_merged_pr_s_head_is_swept(capsys, clone):
    bh = clone.quick("bh", 32, 83)
    clone.tip("quick/32-bh", sha_of("bh-behind"))
    clone.git.seed("ancestry", sha_of("bh-behind"), sha_of("bh"), answer=True)

    assert prune(capsys, clone)[:2] == (
        0, "removed side checkout %s\ndeleted branch quick/32-bh\n" % bh)


def test_a_merged_head_this_repo_does_not_hold_keeps_the_checkout_saying_to_fetch(
        capsys, clone):
    ms = clone.add("ms", "quick/35-ms")
    clone.seed.pr(84, "merged", "quick/35-ms", "main")
    clone.seed.pr_head(84, "1" * 40)

    assert prune(capsys, clone)[:2] == (0, (
        "skipped %s: quick/35-ms: PR #84's head 1111111 is not in this repo - fetch it to let the"
        " sweep judge\nno finished side checkouts\n" % ms))


def test_an_older_merged_pr_s_head_covering_the_tip_sweeps_it(capsys, clone):
    mc = clone.add("mc", "quick/33-mc")
    clone.merged(clone.seed, 85, "quick/33-mc", sha_of("mc"))
    clone.merged(clone.seed, 86, "quick/33-mc", sha_of("unrelated"))
    clone.git.seed("ancestry", sha_of("mc"), sha_of("unrelated"), answer=False)

    assert prune(capsys, clone)[:2] == (
        0, "removed side checkout %s\ndeleted branch quick/33-mc\n" % mc)


def test_no_merged_pr_s_head_covering_the_tip_names_the_newest(capsys, clone):
    mn = clone.add("mn", "quick/34-mn")
    for n, head in ((87, "first"), (88, "second")):
        clone.merged(clone.seed, n, "quick/34-mn", sha_of(head))
        clone.git.seed("ancestry", sha_of("mn"), sha_of(head), answer=False)

    assert prune(capsys, clone)[:2] == (0, (
        "skipped %s: quick/34-mn has commits past PR #88's merged head %s\n"
        "no finished side checkouts\n" % (mn, sha_of("second")[:7])))


def test_a_merged_fork_pr_is_no_proof_the_checkout_is_finished(capsys, clone):
    fk = clone.quick("fk", 41, 91)
    clone.seed.pr_cross(91)

    assert prune(capsys, clone) == (
        0, "skipped %s: no merged PR from quick/41-fk into main\nno finished side checkouts\n"
        % fk, "orch: ignored 1 PR(s) from forks for quick/41-fk\n")


def test_a_cross_repository_flag_that_cannot_be_read_removes_nothing(capsys, clone):
    bf = clone.quick("bf", 43, 93)
    clone.seed.pr_cross(93, "maybe")

    assert prune(capsys, clone) == (1, "", (
        "orch: could not check %s: could not read GitHub: the merged PRs from quick/43-bf into"
        " main\norch: 1 checkout(s) could not be checked - nothing was removed\n" % bf))


def test_a_flow_less_checkout_is_held_to_the_base_recorded_for_its_branch(capsys, tmp_path, seed):
    clone = Clone(tmp_path, seed, local_config={
        "orchestrator.base": "main", branch_base_key("quick/15-rb"): "uat",
        branch_base_key("quick/16-rm2"): "uat"})
    rb = clone.add("rb", "quick/15-rb")
    clone.merged(seed, 54, "quick/15-rb", sha_of("rb"), base="uat")
    rm2 = clone.add("rm2", "quick/16-rm2")
    clone.merged(seed, 55, "quick/16-rm2", sha_of("rm2"))

    assert prune(capsys, clone)[:2] == (0, (
        "skipped %s: no merged PR from quick/16-rm2 into uat\nremoved side checkout %s\n"
        "deleted branch quick/15-rb\n" % (rm2, rb)))


def test_a_side_checkout_whose_archive_cannot_be_made_stays_and_the_sweep_carries_on(
        capsys, clone):
    ab = clone.flow("ab", 57)
    ac = clone.quick("ac", 12, 59)
    (clone.tmp_path / ".orchestrator" / "archive").write_text("")

    assert prune(capsys, clone) == (1, "removed side checkout %s\ndeleted branch quick/12-ac\n"
                                    % ac, (
        "orch: could not archive the flow in side checkout %s: could not create the archive"
        " directory %s - nothing was archived - left as it stands\n"
        % (ab, clone.archived("ab-flow"))))
    assert (Path(ab) / ".orchestrator" / "state.json").is_file()
    assert "orch/ab-flow" in clone.git.branches


def test_a_pr_merged_before_its_issue_was_created_closes_nothing_and_the_checkout_goes(
        capsys, clone):
    clone.quick("bd", 611, 711)
    clone.seed.issue(611, "open")
    clone.seed.pr_merged(711, "2026-06-01T10:00:00Z", 611)
    clone.seed.issue_created(611, HOUR_AGO)

    code, out, _ = prune(capsys, clone)
    assert (code, out.endswith("deleted branch quick/611-bd\n")) == (0, True)
    assert read(clone.seed.store, "issues", 611, "state") == "OPEN\n"


# --- the finished sweep and add: the default branch asked only when needed -------


def test_a_sweep_walking_no_side_checkout_never_asks_for_the_default_branch(capsys, clone):
    gh = CountingGh(clone.seed.store, {}, sleep=lambda _: None)

    assert prune(capsys, clone, gh=gh)[:2] == (0, "no finished side checkouts\n")
    assert gh.default_asks == []


def test_a_sweep_over_a_recorded_base_closed_issue_checkout_never_asks(capsys, tmp_path, seed):
    clone = Clone(tmp_path, seed, local_config={branch_base_key("quick/21-d2"): "main"})
    d2 = clone.quick("d2", 21, 61)
    gh = CountingGh(clone.seed.store, {}, sleep=lambda _: None)

    assert prune(capsys, clone, gh=gh)[:2] == (
        0, "removed side checkout %s\ndeleted branch quick/21-d2\n" % d2)
    assert gh.default_asks == []


@pytest.mark.parametrize("config,finished,asks", [
    ({}, False, 1),
    ({}, True, 1),
    ({"orchestrator.base": "main"}, False, 0),
], ids=["no-base-idle", "no-base-sweep-needs-it", "base-set-idle"])
def test_add_asks_for_the_default_branch_at_most_once(capsys, tmp_path, seed, config, finished,
                                                      asks):
    adding = Adding(tmp_path, seed, local_config=config)
    if finished:
        adding.quick("d3", 22, 62)
    path, _ = adding.addable("d4")
    gh = CountingGh(adding.seed.store, {}, sleep=lambda _: None)

    assert add(capsys, adding, "d4", gh=gh)[:2] == (0, path + "\n")
    assert len(gh.default_asks) == asks


# --- the finished sweep: per-checkout failures -----------------------------------


def test_a_refused_removal_keeps_its_archive_and_branch_and_the_sweep_moves_on(capsys, clone):
    lk = clone.flow("lk", 47)
    clone.git.seed("worktree_remove", clone.main, lk,
                   answer="fatal: cannot remove a locked working tree")
    q2 = clone.quick("q2", 10, 48)

    code, out, err = prune(capsys, clone)
    assert (code, err) == (1, (
        "orch: could not remove side checkout %s: fatal: cannot remove a locked working tree -"
        " left as it stands. Commit or discard its changes, then run orch.sh side-checkout"
        " remove lk.\n" % lk))
    assert out.endswith("removed side checkout %s\ndeleted branch quick/10-q2\n" % q2)
    assert (clone.archived("lk-flow") / "state.json").is_file()
    assert list(clone.git.branches) == ["orch/lk-flow"]


def test_a_branch_that_cannot_be_deleted_is_warned_of_and_the_sweep_moves_on(capsys, clone):
    db = clone.quick("db", 11, 58)
    del clone.git.branches["quick/11-db"]
    dd = clone.quick("dd", 14, 63)

    code, out, err = prune(capsys, clone)
    assert (code, err) == (
        1, "orch: could not delete branch quick/11-db: error: branch 'quick/11-db' not found\n")
    assert out == ("removed side checkout %s\nremoved side checkout %s\ndeleted branch"
                   " quick/14-dd\n" % (db, dd))


def test_a_side_checkout_whose_flow_cannot_be_archived_stays_whole(capsys, clone):
    tw = clone.flow("tw", 49)
    ticket = linked_worktree(clone.tmp_path, Path(tw) / ".orchestrator" / "worktrees" / "t8")
    clone.worktrees.append(Worktree(ticket, "orch/tw-flow--t8"))
    ac = clone.quick("ac", 12, 59)

    code, out, err = prune(capsys, clone)
    assert (code, err) == (1, (
        "orch: could not archive the flow in side checkout %s: ticket worktrees are left under"
        " %s - moving them would break git's record of them: - left as it stands\n" % (tw, tw)))
    assert out == "removed side checkout %s\ndeleted branch quick/12-ac\n" % ac
    assert (Path(tw) / ".orchestrator" / "state.json").is_file()
    assert "orch/tw-flow" in clone.git.branches


def test_a_main_checkout_flow_that_cannot_be_archived_is_warned_of_with_one_prefix(
        capsys, clone):
    hold_flow(clone.tmp_path, slug="main-flow", phase="done", branch="orch/main-flow", pr="64")
    clone.seed.pr(64, "merged", "orch/main-flow", "main")
    (clone.tmp_path / ".orchestrator" / "archive").write_text("")

    assert prune(capsys, clone) == (1, "", (
        "orch: could not archive the main checkout's flow: could not create the archive"
        " directory %s - nothing was archived\n" % clone.archived("main-flow")))
    assert (clone.tmp_path / ".orchestrator" / "state.json").is_file()


def test_a_detached_main_checkout_s_in_place_archive_names_an_empty_branch(capsys, clone):
    hold_flow(clone.tmp_path, slug="main-flow", phase="done", branch="orch/main-flow", pr="56")
    clone.seed.pr(56, "merged", "orch/main-flow", "main")
    clone.git.seed("branch_at", clone.main, answer=None)

    code, out, _ = prune(capsys, clone)
    assert (code, out.splitlines()[-1]) == (
        0, "archived the main checkout's flow in place -  is still checked out")


def test_a_removal_of_the_checkout_the_sweep_ran_in_says_to_close_the_session(capsys, clone):
    qk = clone.quick("qk", 7, 42)

    code, out, _ = outcome(capsys, lambda: side_checkout.side_checkout_prune(
        [], fake(clone.seed), clone.git, {}, qk, here=qk + "/sub", clock=lambda: NOW))
    assert (code, out) == (0, (
        "removed side checkout %s\nThis session's working directory was that side checkout,"
        " and it is gone - close this session.\ndeleted branch quick/7-qk\n" % qk))


# --- the finished sweep: the merged-PR close backstop (#2477) --------------------


def test_a_finished_checkout_s_open_issue_its_pr_left_behind_is_closed_before_it_goes(
        capsys, clone):
    clone.flow("ff", 701, issue=601)
    clone.seed.issue(601, "open", "orch:done")
    clone.seed.pr_merged(701, HOUR_AGO, 601)
    clone.quick("fq", 602, 702)
    clone.seed.issue(602, "open")
    clone.seed.pr_merged(702, HOUR_AGO, 602)
    clone.quick("fg", 603, 703)
    clone.seed.issue(603, "open")
    clone.seed.pr_merged(703, MINUTE_AGO, 603)
    clone.flow("fb", 704, issue=604)
    clone.seed.issue(604, "closed", "orch:done")
    clone.seed.pr_merged(704, HOUR_AGO, 604)
    clone.quick("fn", 609, 709)
    clone.seed.issue(609, "open")
    clone.seed.pr_merged(709, HOUR_AGO, 99)

    code, out, err = prune(capsys, clone)
    assert (code, err) == (0, (
        "orch: issue #603 is still open: PR #703 merged less than 5 minutes ago - GitHub may"
        " yet close it, and no later sweep will check\n"))
    assert [read(clone.seed.store, "issues", n, "state") for n in (601, 602, 603, 604, 609)] \
        == ["CLOSED\n", "CLOSED\n", "OPEN\n", "CLOSED\n", "OPEN\n"]
    assert comments_of(clone.seed.store, 601) == [
        "Closed by the orchestrator: PR #701 merged into `main` with `Closes #601`, but GitHub"
        " did not close this issue."]
    assert comments_of(clone.seed.store, 604) == []
    assert out.count("removed side checkout") == 5


def test_a_flow_less_checkout_on_a_branch_naming_no_issue_closes_nothing(capsys, clone):
    ot = clone.add("ot", "feature/ot")
    clone.merged(clone.seed, 705, "feature/ot", sha_of("ot"))
    clone.seed.issue(605, "open")
    clone.seed.pr_merged(705, HOUR_AGO, 605)

    assert prune(capsys, clone)[:2] == (0, "removed side checkout %s\ndeleted branch feature/ot\n"
                                        % ot)
    assert read(clone.seed.store, "issues", 605, "state") == "OPEN\n"


def test_the_main_checkout_s_finished_flow_closes_its_issue(capsys, clone):
    hold_flow(clone.tmp_path, slug="bm-flow", phase="done", branch="orch/bm-flow", pr="706",
              issue=606)
    clone.seed.pr(706, "merged", "orch/bm-flow", "main")
    clone.seed.pr_merged(706, HOUR_AGO, 606)
    clone.seed.issue(606, "open", "orch:done")

    assert prune(capsys, clone)[0] == 0
    assert read(clone.seed.store, "issues", 606, "state") == "CLOSED\n"


@pytest.mark.parametrize("operation,warning", [
    ("adapter_issue_state_labels",
     "could not read issue #607: HTTP 502 - the merged-PR close skips it"),
    ("adapter_issue_close", "could not close issue #607 after PR #707 merged: HTTP 502"),
    ("adapter_prs_merged_closing",
     "could not read the merged PRs: HTTP 502 - no merged-PR close for issue #607"),
    ("adapter_issue_created_at",
     "could not read the creation time of issue #607: HTTP 502 - no merged-PR close for"
     " issue #607"),
], ids=["issue-read", "close", "merged-read", "created-read"])
def test_a_failed_read_or_close_warns_and_never_blocks_the_removal(
        capsys, clone, operation, warning):
    clone.quick("fc", 607, 707)
    clone.seed.issue(607, "open")
    clone.seed.pr_merged(707, HOUR_AGO, 607)
    clone.seed.fail(operation, "HTTP 502")

    code, out, err = prune(capsys, clone)
    assert (code, err) == (0, "orch: " + warning + "\n")
    assert read(clone.seed.store, "issues", 607, "state") == "OPEN\n"
    assert out.endswith("deleted branch quick/607-fc\n")


def test_a_flow_whose_state_cannot_be_read_for_the_close_reads_no_issue(capsys, clone):
    path = clone.flow("ft", 710, issue=610)
    clone.seed.issue(610, "open")
    clone.seed.pr_merged(710, HOUR_AGO, 610)
    (Path(path) / ".orchestrator" / "state.json").write_text('{"issue": 6')

    assert outcome(capsys, lambda: side_checkout.side_checkout_close_missed(
        fake(clone.seed), clone.git, {}, path, "orch/ft-flow", lambda: NOW)) == (0, "", "")
    assert read(clone.seed.store, "issues", 610, "state") == "OPEN\n"


# --- add ---------------------------------------------------------------------------


class Adding(Clone):
    """A clone add can make side checkout <name> in: origin's base fetched,
    the worktree added at it, and its git folder made as git makes it."""

    def addable(self, name, base="main"):
        path = "%s/.orchestrator/checkouts/%s" % (self.main, name)
        gitdir = self.tmp_path / "git-dir" / "worktrees" / name
        self.git.seed("fetch_branch_at", self.main, base, answer=True)
        self.git.seed("worktree_add_detached_at", self.main, path, "refs/remotes/origin/" + base,
                      answer=None)
        self.git.seed("absolute_git_dir_at", path, answer=str(gitdir))
        gitdir.mkdir(parents=True, exist_ok=True)
        return path, gitdir / "orchestrator-side-checkout"


@pytest.fixture
def adding(tmp_path, seed):
    return Adding(tmp_path, seed)


def test_add_prints_the_new_side_checkout_s_path_alone_its_sweep_on_stderr(capsys, adding):
    path, marker = adding.addable("alpha")

    assert add(capsys, adding, "Alpha") == (0, path + "\n", "no finished side checkouts\n")
    assert marker.read_text() == ""
    assert (adding.tmp_path / "git-dir" / "info" / "exclude").read_text() == (
        ".orchestrator/\n.scratch/\n")


def test_add_with_an_issue_writes_it_into_the_marker(capsys, adding):
    path, marker = adding.addable("quick-one")

    assert add(capsys, adding, "quick-one", "--issue", "123")[:2] == (0, path + "\n")
    assert marker.read_text() == "123\n"


def test_add_forks_from_the_base_branch_in_effect(capsys, tmp_path, seed):
    adding = Adding(tmp_path, seed, local_config={"orchestrator.base": "uat"})
    path, _ = adding.addable("on-uat", base="uat")

    assert add(capsys, adding, "on-uat")[:2] == (0, path + "\n")


def test_add_runs_the_sweep_first_and_reports_it_on_stderr(capsys, adding):
    q3 = adding.quick("q3", 11, 49)
    path, _ = adding.addable("after")

    assert add(capsys, adding, "after") == (
        0, path + "\n", "removed side checkout %s\ndeleted branch quick/11-q3\n" % q3)


def test_add_carries_on_when_its_sweep_fails(capsys, adding):
    adding.quick("q4", 12, 50)
    adding.seed.fail("adapter_prs_merged", "HTTP 502")
    path, _ = adding.addable("after2")

    code, out, err = add(capsys, adding, "after2")
    assert (code, out) == (0, path + "\n")
    assert err.endswith("orch: 1 checkout(s) could not be checked - nothing was removed\n"
                        "orch: the finished sweep failed - carrying on with add\n")
    assert "quick/12-q4" in adding.git.branches


USAGE = "orch: usage: orch.sh side-checkout add <slug> [--issue N]\n"


@pytest.mark.parametrize("argv,err", [
    ((), USAGE),
    (("",), USAGE),
    (("badissue", "--issue"), USAGE),
    (("badissue", "--issue", ""), USAGE),
    (("badissue", "--issue", "12a"), "orch: --issue wants a plain issue number, got: 12a\n"),
    (("badissue", "--issue", "#5"), "orch: --issue wants a plain issue number, got: #5\n"),
    (("badissue", "--bogus"), "orch: unknown side-checkout add flag: --bogus (want --issue)\n"),
    (("!!!",), "orch: slug is empty after normalisation\n"),
], ids=["no-slug", "empty-slug", "no-issue", "empty-issue", "not-plain", "hash", "flag",
        "empty-normalised"])
def test_add_refuses_a_bad_command_line_before_any_sweep_or_worktree(capsys, adding, argv, err):
    adding.quick("q", 13, 51)

    assert add(capsys, adding, *argv) == (1, "", err)
    assert "quick/13-q" in adding.git.branches


def test_add_refuses_a_path_that_exists(capsys, adding):
    path, _ = adding.addable("stray")
    os.makedirs(path)

    assert add(capsys, adding, "stray") == (
        1, "", "no finished side checkouts\norch: side checkout %s already exists\n" % path)


def test_add_dies_when_the_base_branch_cannot_be_fetched(capsys, adding):
    path, _ = adding.addable("nofetch")
    adding.git.seed("fetch_branch_at", adding.main, "main", answer=False)

    code, out, err = add(capsys, adding, "nofetch")
    assert (code, out) == (1, "")
    assert err.endswith(
        "orch: could not fetch base branch main from origin - no side checkout was made\n")
    assert not os.path.exists(path)


def test_add_dies_when_git_refuses_the_worktree_passing_git_s_error_on(capsys, adding):
    path, _ = adding.addable("refused")
    adding.git.seed("worktree_add_detached_at", adding.main, path, "refs/remotes/origin/main",
                    answer=GitFailure(128, "fatal: invalid reference\n"))

    code, out, err = add(capsys, adding, "refused")
    assert (code, out) == (1, "")
    assert err.endswith("fatal: invalid reference\norch: could not add side checkout %s\n" % path)


class RecordingGit(FakeGit):
    """The FakeGit, keeping each worktree it was asked to remove."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.removed = []

    def worktree_remove(self, checkout, path):
        self.removed.append(path)
        return super().worktree_remove(checkout, path)


@pytest.mark.parametrize("breaks", ["no-git-folder", "unwritable"])
def test_a_marker_that_cannot_be_written_takes_the_fresh_worktree_back_out(
        capsys, tmp_path, seed, breaks):
    adding = Adding(tmp_path, seed, cls=RecordingGit)
    path, marker = adding.addable("nomarker")
    if breaks == "no-git-folder":
        adding.git.seed("absolute_git_dir_at", path, answer=None)
    else:
        marker.mkdir()

    code, out, err = add(capsys, adding, "nomarker")
    assert (code, out) == (1, "")
    assert err.endswith("orch: could not write the side-checkout marker - removed %s again\n"
                        % path)
    assert adding.git.removed == [path]


# --- the side checkout's name for a picked-up issue -----------------------------


@pytest.mark.parametrize("title,slug", [
    ("Agent settings: repeated kind/host switches and duplicated listing remedy builders"
     " (9 findings)", "agent-settings-repeated-kind-host"),
    ("Fix the widget", "fix-the-widget"),
    ("Aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeee rest",
     "aaaaaaaaaabbbbbbbbbbccccccccccdddddddddd"),
    ("!!! ???", "untitled"),
], ids=["long", "short", "long-first-word", "punctuation"])
def test_the_short_slug_is_whole_words_of_at_most_40_characters(title, slug):
    assert side_checkout.short_slug(title) == slug


@pytest.mark.parametrize("taken,name", [
    ((), "fix-gadget"),
    (("fix-gadget",), "fix-gadget-31"),
    (("fix-gadget", "fix-gadget-31"), "fix-gadget-31-2"),
    (("fix-gadget", "fix-gadget-31", "fix-gadget-31-2"), "fix-gadget-31-3"),
], ids=["free", "slug-taken", "issue-name-taken", "two-taken"])
def test_a_clash_moves_on_to_the_issue_numbered_name_then_its_counted_ones(
        tmp_path, taken, name):
    for entry in taken:
        (tmp_path / ".orchestrator" / "checkouts" / entry).mkdir(parents=True)

    assert side_checkout.side_checkout_free_slug(str(tmp_path), "Fix gadget", "31") == name


def test_a_plain_file_in_the_side_checkouts_directory_counts_as_a_clash(tmp_path):
    (tmp_path / ".orchestrator" / "checkouts" / "fix-sprocket").mkdir(parents=True)
    (tmp_path / ".orchestrator" / "checkouts" / "fix-sprocket-33").write_text("")

    assert side_checkout.side_checkout_free_slug(str(tmp_path), "Fix sprocket", "33") \
        == "fix-sprocket-33-2"


# --- the lookups ---------------------------------------------------------------------


def test_the_side_checkouts_directory_is_under_the_main_checkout_s_orchestrator_folder():
    assert side_checkout.side_checkouts_dir("/work/main") == "/work/main/.orchestrator/checkouts"


def test_the_side_checkout_for_an_issue_is_the_one_whose_marker_records_it(clone):
    clone.add("other", "quick/8-other", marker="8\n")
    seven = clone.add("seven", "quick/7-seven", marker="7\n")

    assert side_checkout.side_checkout_for_issue(clone.git, "7") == seven


def test_no_side_checkout_records_an_absent_issue(clone):
    clone.add("seven", "quick/7-seven", marker="7\n")
    clone.add("bare", "quick/9-bare", marker="")

    assert side_checkout.side_checkout_for_issue(clone.git, "9") is None


def test_a_side_checkout_whose_directory_is_missing_records_no_issue(clone, tmp_path):
    missing = str(tmp_path / ".orchestrator" / "checkouts" / "gone")
    clone.worktrees.append(Worktree(missing, "quick/7-gone"))

    assert side_checkout.side_checkout_for_issue(clone.git, "7") is None


def test_a_ticket_worktree_carrying_a_copied_marker_is_no_side_checkout_for_its_issue(
        clone, tmp_path):
    copied = linked_worktree(tmp_path, tmp_path / ".orchestrator" / "worktrees" / "t41", "7\n")
    clone.worktrees.append(Worktree(copied, "main--t41"))

    assert side_checkout.side_checkout_for_issue(clone.git, "7") is None


def test_no_side_checkout_is_found_when_the_checkouts_cannot_be_read(clone):
    clone.add("seven", "quick/7-seven", marker="7\n")
    clone.git.seed("worktree_list", answer=None)

    assert side_checkout.side_checkout_for_issue(clone.git, "7") is None
