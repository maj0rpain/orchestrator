"""`orch.sh branch sync [--finish]`, called in-process through the branch
module's run, against real repositories with a real bare origin under
tmp_path: a base sync's logic is git's merge, merge-base and push, which a
fake would only restate. Checked through tips, merge parents, git config,
state.json and what reached the bare origin; each message, exit code and
order of checks is the bash verb's, verbatim."""
from __future__ import annotations

import json
import subprocess
from typing import NamedTuple

import pytest

from conftest import (committed, exclude_orchestrator, fake, git_identity, git_of, hold_flow,
                      origin_main_clone, outcome, run_git, state_json, tip)
from orch import branch as module
from orch.git import Git

FLOW = "orch/11-bsync"
QUICK = "quick/12-qsync"
USAGE = "orch: usage: orch.sh branch sync [--finish]\n"
NOT_MADE = ("orch: %s is not a branch the plugin made: no flow here holds it and it records"
            " no base - nothing was synced\n")
CONFLICT = ("orch: merging origin/main into %s hit a conflict - the merge is left in progress;"
            " resolve and commit it, then run orch.sh branch sync --finish\n" % FLOW)
PENDING = ("orch: a merge of origin/main into %s is pending resolution - the merge is left in"
           " progress; resolve and commit it, then run orch.sh branch sync --finish\n" % FLOW)
FINISH_MERGING = ("orch: a merge is in progress on %s - commit it (or git merge --abort), then"
                  " rerun orch.sh branch sync --finish; nothing was synced\n" % FLOW)
MERGING = ("orch: a merge is in progress on %s - commit it (or git merge --abort), then rerun"
           " orch.sh branch sync\n" % FLOW)


class Repo(NamedTuple):
    """A sync's repositories: the checkout synced, its bare origin, and the
    clone origin's main is moved on from."""

    root: object
    origin: object
    pusher: object


@pytest.fixture
def repo(tmp_path):
    """A clone of a bare origin holding main, origin/HEAD naming it, on FLOW
    - branched off origin/main with no upstream, its base and base SHA
    recorded in git config, one commit of its own - held by this checkout's
    flow, which records the same base and base SHA."""
    root, branched = origin_main_clone(tmp_path, {"a.txt": "a\n"})
    origin, pusher = tmp_path / "origin.git", tmp_path / "pusher"
    git_identity(root)
    exclude_orchestrator(root)
    run_git(root, "checkout", "-q", "--no-track", "-b", FLOW, "refs/remotes/origin/main")
    record(root, FLOW, "main", branched)
    hold_flow(root, slug="bsync", issue=11, phase="implement", base="main", branch=FLOW,
              base_sha=branched)
    committed(root, {"work.txt": "work\n"}, "work on the branch")
    run_git(tmp_path, "clone", "-q", str(origin), str(pusher))
    git_identity(pusher)
    return Repo(root, origin, pusher)


def record(root, branch, base, sha=None):
    """<branch>'s base, and its base SHA when given, recorded in git config
    as branch off and branch create record them."""
    run_git(root, "config", "branch.%s.orchestrator-base" % branch, base)
    if sha is not None:
        run_git(root, "config", "branch.%s.orchestrator-base-sha" % branch, sha)


def advance(repo, name, text, branch="main"):
    """Commits <text> to <name> on origin's <branch>, from the pusher clone:
    origin's new tip."""
    run_git(repo.pusher, "fetch", "-q", "origin")
    run_git(repo.pusher, "checkout", "-q", "-B", branch, "refs/remotes/origin/" + branch)
    sha = committed(repo.pusher, {name: text}, "%s: %s" % (branch, name))
    run_git(repo.pusher, "push", "-q", "origin", "HEAD:refs/heads/" + branch)
    return sha


def sync(capsys, repo, seed, *argv):
    """`orch.sh branch sync <argv>` in the checkout: (exit, stdout, stderr)."""
    return outcome(capsys, lambda: module.run(
        ["sync", *argv], gh=fake(seed), git=Git(cwd=str(repo.root)), env={}))


def synced(branch, tip_sha):
    return "%s synced with origin/main at %s\n" % (branch, tip_sha)


def sha_of_base(root, branch=FLOW):
    """<branch>'s base SHA as its git config records it; "" when none is."""
    return git_of(root, "config", "--get", "branch.%s.orchestrator-base-sha" % branch)


def state_sha(root):
    return json.loads(state_json(root).read_text())["base_sha"]


def head(root, rev="HEAD"):
    return git_of(root, "rev-parse", rev)


def origin_tip(repo, branch):
    """origin's tip of <branch>; "" when it has none."""
    return git_of(repo.root, "ls-remote", str(repo.origin), "refs/heads/" + branch).split("\t")[0]


def merging(root):
    """Whether a merge is in progress in the checkout at <root>."""
    return head(root, "MERGE_HEAD") != ""


def try_git(root, *args):
    """git <args> in <root>, as a test author, whatever it exits."""
    subprocess.run(["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)


def conflicted(capsys, repo, seed):
    """FLOW and origin's main each edit clash.txt their own way, and a sync
    stops on the conflict: origin's tip."""
    committed(repo.root, {"clash.txt": "ours\n"}, "clash: ours")
    theirs = advance(repo, "clash.txt", "theirs\n")
    assert sync(capsys, repo, seed)[0] == 3
    return theirs


def rejecting(repo):
    """A pre-receive hook on origin refusing every push: its path."""
    hook = repo.origin / "hooks" / "pre-receive"
    hook.write_text("#!/bin/sh\nexit 1\n")
    hook.chmod(0o755)
    return hook


# --- the merge -------------------------------------------------------------------------


def test_with_nothing_to_merge_it_records_origin_s_tip_and_makes_no_commit(repo, seed, capsys):
    before, main_tip = head(repo.root), head(repo.root, "refs/remotes/origin/main")

    assert sync(capsys, repo, seed) == (0, synced(FLOW, main_tip), "")
    assert (head(repo.root), sha_of_base(repo.root), state_sha(repo.root)) == (
        before, main_tip, main_tip)


def test_origin_s_base_tip_is_merged_never_the_local_base_and_never_rebased(repo, seed, capsys):
    local_main, before = tip(repo.root, "main"), head(repo.root)
    new_tip = advance(repo, "other.txt", "from main\n")

    assert sync(capsys, repo, seed) == (0, synced(FLOW, new_tip), "")
    assert (head(repo.root, "HEAD^1"), head(repo.root, "HEAD^2")) == (before, new_tip)
    assert tip(repo.root, "main") == local_main
    assert (sha_of_base(repo.root), state_sha(repo.root)) == (new_tip, new_tip)


def test_a_branch_with_no_upstream_is_never_pushed(repo, seed, capsys):
    advance(repo, "other.txt", "from main\n")

    assert sync(capsys, repo, seed)[0] == 0
    assert origin_tip(repo, FLOW) == ""


def test_a_local_branch_and_a_tag_named_origin_main_never_stand_in_for_origin_s_tip(
        repo, seed, capsys):
    stale = tip(repo.root, "main")
    run_git(repo.root, "branch", "-q", "origin/main", stale)
    run_git(repo.root, "tag", "origin/main", stale)
    new_tip = advance(repo, "stray.txt", "stray\n")

    assert sync(capsys, repo, seed) == (0, synced(FLOW, new_tip), "")
    assert (head(repo.root, "HEAD^2"), sha_of_base(repo.root)) == (new_tip, new_tip)


def uat_apart(repo):
    """origin's uat, one commit ahead of origin's main: its tip."""
    run_git(repo.pusher, "push", "-q", "origin", "refs/remotes/origin/main:refs/heads/uat")
    return advance(repo, "uat.txt", "uat\n", "uat")


def test_a_held_branch_syncs_with_the_flow_s_base_over_its_config_s_and_the_setting(
        repo, seed, capsys):
    uat_apart(repo)
    run_git(repo.root, "config", "branch.%s.orchestrator-base" % FLOW, "uat")
    run_git(repo.root, "config", "orchestrator.base", "uat")
    before, main_tip = head(repo.root), head(repo.root, "refs/remotes/origin/main")

    assert sync(capsys, repo, seed) == (0, synced(FLOW, main_tip), "")
    assert (head(repo.root), sha_of_base(repo.root)) == (before, main_tip)


def test_a_held_flow_recording_no_base_syncs_with_the_default_branch(repo, seed, capsys):
    # The flow base fallback, never the branch config's base or the setting.
    uat_apart(repo)
    hold_flow(repo.root, slug="bsync", issue=11, phase="implement", base="", branch=FLOW,
              base_sha="")
    run_git(repo.root, "config", "branch.%s.orchestrator-base" % FLOW, "uat")
    run_git(repo.root, "config", "orchestrator.base", "uat")
    new_tip = advance(repo, "main.txt", "main\n")

    assert sync(capsys, repo, seed) == (0, synced(FLOW, new_tip), "")
    assert (head(repo.root, "HEAD^2"), state_sha(repo.root)) == (new_tip, new_tip)


@pytest.mark.parametrize("phase", ["done", "pr"])
def test_a_flow_s_branch_at_any_phase_is_held(repo, seed, capsys, phase):
    hold_flow(repo.root, slug="bsync", issue=11, phase=phase, base="main", branch=FLOW,
              base_sha="")
    new_tip = advance(repo, "done.txt", "done\n")

    assert sync(capsys, repo, seed) == (0, synced(FLOW, new_tip), "")
    assert state_sha(repo.root) == new_tip


def test_an_archived_flow_s_branch_syncs_through_its_config_writing_no_state(
        repo, seed, capsys):
    state_json(repo.root).unlink()
    new_tip = advance(repo, "archived.txt", "archived\n")

    assert sync(capsys, repo, seed) == (0, synced(FLOW, new_tip), "")
    assert (head(repo.root, "HEAD^2"), sha_of_base(repo.root)) == (new_tip, new_tip)
    assert not state_json(repo.root).exists()


@pytest.mark.parametrize("name", [QUICK, "feature/named"], ids=["quick", "any-name"])
def test_a_branch_recording_a_base_syncs_through_its_config_leaving_another_flow_s_state(
        repo, seed, capsys, name):
    run_git(repo.root, "checkout", "-q", "--no-track", "-b", name, "refs/remotes/origin/main")
    record(repo.root, name, "main")
    committed(repo.root, {"quick.txt": "quick\n"}, "quick work")
    state_before = state_json(repo.root).read_text()
    new_tip = advance(repo, "quick.txt.base", "base\n")

    assert sync(capsys, repo, seed) == (0, synced(name, new_tip), "")
    assert (head(repo.root, "HEAD^2"), sha_of_base(repo.root, name)) == (new_tip, new_tip)
    assert state_json(repo.root).read_text() == state_before


# --- the push --------------------------------------------------------------------------


def test_a_branch_tracking_its_own_name_has_the_merge_pushed(repo, seed, capsys):
    run_git(repo.root, "push", "-q", "-u", "origin", FLOW)
    advance(repo, "more.txt", "more\n")

    assert sync(capsys, repo, seed)[0] == 0
    assert origin_tip(repo, FLOW) == head(repo.root)


def test_a_branch_still_tracking_its_base_is_never_pushed(repo, seed, capsys):
    # Made before #1152: its upstream is its base, so a push would land there.
    run_git(repo.root, "branch", "-q", "--set-upstream-to=origin/main")
    origin_main = advance(repo, "more.txt", "more\n")

    assert sync(capsys, repo, seed)[0] == 0
    assert (origin_tip(repo, "main"), origin_tip(repo, FLOW)) == (origin_main, "")


def test_the_push_goes_to_the_branch_s_own_remote(repo, seed, capsys, tmp_path):
    fork = tmp_path / "fork.git"
    run_git(tmp_path, "init", "-q", "--bare", str(fork))
    run_git(repo.root, "remote", "add", "fork", str(fork))
    run_git(repo.root, "push", "-q", "-u", "fork", FLOW)
    advance(repo, "more.txt", "more\n")

    assert sync(capsys, repo, seed)[0] == 0
    assert git_of(repo.root, "ls-remote", str(fork), "refs/heads/" + FLOW).split("\t")[0] == (
        head(repo.root))
    assert origin_tip(repo, FLOW) == ""


def test_a_failed_push_exits_1_with_the_merge_and_base_sha_standing(repo, seed, capsys):
    run_git(repo.root, "push", "-q", "-u", "origin", FLOW)
    pushed = origin_tip(repo, FLOW)
    new_tip = advance(repo, "push.txt", "push\n")
    rejecting(repo)

    code, out, err = sync(capsys, repo, seed)

    assert (code, out) == (1, "")
    assert err.startswith("orch: could not push %s - the merge and base SHA are recorded; rerun"
                          " orch.sh branch sync to push: " % FLOW)
    assert (head(repo.root, "HEAD^2"), sha_of_base(repo.root), state_sha(repo.root)) == (
        new_tip, new_tip, new_tip)
    assert origin_tip(repo, FLOW) == pushed


# --- a conflict ------------------------------------------------------------------------


def test_a_conflict_exits_3_leaving_the_merge_in_progress_and_nothing_else_moved(
        repo, seed, capsys):
    run_git(repo.root, "push", "-q", "-u", "origin", FLOW)
    committed(repo.root, {"clash.txt": "ours\n"}, "clash: ours")
    run_git(repo.root, "push", "-q")
    before, pushed = head(repo.root), origin_tip(repo, FLOW)
    sha_before = sha_of_base(repo.root)
    advance(repo, "clash.txt", "theirs\n")

    assert sync(capsys, repo, seed) == (3, "", CONFLICT)
    assert merging(repo.root)
    assert (head(repo.root), sha_of_base(repo.root), state_sha(repo.root)) == (
        before, sha_before, sha_before)
    assert origin_tip(repo, FLOW) == pushed


def test_a_pending_base_merge_exits_3_again_fetching_and_moving_nothing(repo, seed, capsys):
    conflicted(capsys, repo, seed)
    merge_head, fetched = head(repo.root, "MERGE_HEAD"), head(repo.root, "refs/remotes/origin/main")
    tree = git_of(repo.root, "status", "--porcelain")
    advance(repo, "later.txt", "later\n")

    assert sync(capsys, repo, seed) == (3, "", PENDING)
    assert (head(repo.root, "MERGE_HEAD"), head(repo.root, "refs/remotes/origin/main")) == (
        merge_head, fetched)
    assert git_of(repo.root, "status", "--porcelain") == tree


def test_a_merge_in_progress_of_a_ref_not_on_the_base_is_refused(repo, seed, capsys):
    run_git(repo.root, "checkout", "-q", "-b", "other", "refs/remotes/origin/main")
    committed(repo.root, {"other.txt": "other\n"}, "other side")
    run_git(repo.root, "checkout", "-q", FLOW)
    committed(repo.root, {"other.txt": "mine\n"}, "mine")
    try_git(repo.root, "merge", "-q", "--no-edit", "refs/heads/other")

    assert sync(capsys, repo, seed) == (1, "", MERGING)
    assert merging(repo.root)


def test_a_merge_git_could_not_start_exits_1_as_no_conflict(repo, seed, capsys, monkeypatch):
    # merge.ff=only refuses the diverged merge before git writes any merge
    # state.
    advance(repo, "ffonly.txt", "ffonly\n")
    before = head(repo.root)
    for key, value in (("GIT_CONFIG_COUNT", "1"), ("GIT_CONFIG_KEY_0", "merge.ff"),
                       ("GIT_CONFIG_VALUE_0", "only")):
        monkeypatch.setenv(key, value)
    sha_before = sha_of_base(repo.root)

    assert sync(capsys, repo, seed) == (
        1, "", "orch: git could not merge origin/main into %s\n" % FLOW)
    assert not merging(repo.root)
    assert (head(repo.root), sha_of_base(repo.root)) == (before, sha_before)


# --- --finish --------------------------------------------------------------------------


def resolved(capsys, repo, seed):
    """A conflict's merge resolved and committed, FLOW tracking origin's
    FLOW: (the merge commit, origin's main tip it merged)."""
    run_git(repo.root, "push", "-q", "-u", "origin", FLOW)
    theirs = conflicted(capsys, repo, seed)
    (repo.root / "clash.txt").write_text("both\n")
    run_git(repo.root, "add", "clash.txt")
    run_git(repo.root, "commit", "-q", "--no-edit")
    return head(repo.root), theirs


def test_finish_records_the_merge_s_second_parent_and_pushes_never_fetching(
        repo, seed, capsys):
    merge, theirs = resolved(capsys, repo, seed)
    # origin's main moves on again, fetched, then again, not fetched.
    advance(repo, "again.txt", "again\n")
    run_git(repo.root, "fetch", "-q", "origin")
    fetched = head(repo.root, "refs/remotes/origin/main")
    advance(repo, "unfetched.txt", "unfetched\n")

    assert sync(capsys, repo, seed, "--finish") == (0, synced(FLOW, theirs), "")
    assert not merging(repo.root)
    assert (head(repo.root), sha_of_base(repo.root), state_sha(repo.root)) == (
        merge, theirs, theirs)
    assert origin_tip(repo, FLOW) == merge
    assert head(repo.root, "refs/remotes/origin/main") == fetched


def test_finish_accepts_fix_commits_above_the_merge(repo, seed, capsys):
    _, theirs = resolved(capsys, repo, seed)
    committed(repo.root, {"fixup.txt": "fix\n"}, "resolver fix")
    committed(repo.root, {"fixup.txt": "fix again\n"}, "resolver fix again")

    assert sync(capsys, repo, seed, "--finish") == (0, synced(FLOW, theirs), "")
    assert (sha_of_base(repo.root), origin_tip(repo, FLOW)) == (theirs, head(repo.root))


def test_finish_on_a_chain_holding_no_merge_is_refused(repo, seed, capsys):
    sha_before = sha_of_base(repo.root)

    assert sync(capsys, repo, seed, "--finish") == (1, "", (
        "orch: no merge commit on the first-parent chain of %s - nothing to finish; nothing"
        " was synced\n" % FLOW))
    assert sha_of_base(repo.root) == sha_before


def test_finish_on_a_merge_whose_second_parent_is_not_on_origin_s_base_is_refused(
        repo, seed, capsys):
    side = run_git(repo.root, "commit-tree", "-p", "HEAD", "-m", "side", "HEAD^{tree}")
    foreign = run_git(repo.root, "commit-tree", "-p", "HEAD", "-p", side, "-m", "foreign merge",
                      "HEAD^{tree}")
    run_git(repo.root, "reset", "-q", "--hard", foreign)
    sha_before = sha_of_base(repo.root)

    assert sync(capsys, repo, seed, "--finish") == (1, "", (
        "orch: the second parent of the newest merge on %s is not on origin/main - nothing to"
        " finish; nothing was synced\n" % FLOW))
    assert (head(repo.root), sha_of_base(repo.root)) == (foreign, sha_before)


def test_finish_while_a_merge_is_in_progress_is_refused(repo, seed, capsys):
    conflicted(capsys, repo, seed)
    sha_before = sha_of_base(repo.root)

    assert sync(capsys, repo, seed, "--finish") == (1, "", FINISH_MERGING)
    assert merging(repo.root)
    assert sha_of_base(repo.root) == sha_before


def test_finish_whose_push_is_rejected_records_the_base_sha_and_a_rerun_pushes(
        repo, seed, capsys):
    merge, theirs = resolved(capsys, repo, seed)
    pushed = origin_tip(repo, FLOW)
    hook = rejecting(repo)

    assert sync(capsys, repo, seed, "--finish") == (1, "", (
        "orch: could not push %s - the merge and base SHA are recorded; rerun orch.sh branch"
        " sync --finish to push: ! [remote rejected] %s -> %s (pre-receive hook declined)\n"
        % (FLOW, FLOW, FLOW)))
    assert (sha_of_base(repo.root), origin_tip(repo, FLOW)) == (theirs, pushed)
    hook.unlink()
    assert sync(capsys, repo, seed, "--finish")[0] == 0
    assert origin_tip(repo, FLOW) == merge


def test_finish_on_an_unheld_branch_records_its_config_only_and_pushes_nothing(
        repo, seed, capsys):
    merge, theirs = resolved(capsys, repo, seed)
    run_git(repo.root, "checkout", "-q", "--no-track", "-b", QUICK, merge)
    record(repo.root, QUICK, "main")
    state_before = state_json(repo.root).read_text()

    assert sync(capsys, repo, seed, "--finish") == (0, synced(QUICK, theirs), "")
    assert sha_of_base(repo.root, QUICK) == theirs
    assert state_json(repo.root).read_text() == state_before
    assert origin_tip(repo, QUICK) == ""


# --- refusals --------------------------------------------------------------------------


def test_a_dirty_tree_is_refused_moving_nothing(repo, seed, capsys):
    before, sha_before = head(repo.root), sha_of_base(repo.root)
    advance(repo, "refused.txt", "refused\n")
    (repo.root / "a.txt").write_text("dirty\n")

    assert sync(capsys, repo, seed) == (1, "", (
        "orch: the working tree is dirty - commit or discard its changes first; nothing was"
        " synced\n"))
    assert (head(repo.root), sha_of_base(repo.root)) == (before, sha_before)
    assert (repo.root / "a.txt").read_text() == "dirty\n"


def test_a_failed_fetch_is_refused_never_merging_the_local_base(repo, seed, capsys, tmp_path):
    run_git(repo.root, "checkout", "-q", "main")
    committed(repo.root, {"local.txt": "local\n"}, "local main only")
    run_git(repo.root, "checkout", "-q", FLOW)
    before, sha_before = head(repo.root), sha_of_base(repo.root)
    run_git(repo.root, "config", "remote.origin.url", str(tmp_path / "missing.git"))

    assert sync(capsys, repo, seed) == (
        1, "", "orch: could not fetch main from origin - nothing was synced\n")
    assert (head(repo.root), sha_of_base(repo.root)) == (before, sha_before)


def test_a_detached_head_is_refused_saying_nothing_was_synced(repo, seed, capsys):
    run_git(repo.root, "checkout", "-q", "--detach")
    before = head(repo.root)

    assert sync(capsys, repo, seed) == (
        1, "", "orch: not on a branch (detached HEAD) - nothing was synced\n")
    assert head(repo.root) == before


def test_a_branch_recording_no_base_is_refused_even_with_a_base_setting(repo, seed, capsys):
    run_git(repo.root, "checkout", "-q", "-b", "feature/hand-made")
    before = head(repo.root)
    bare = sync(capsys, repo, seed)
    run_git(repo.root, "config", "orchestrator.base", "main")

    assert (bare, sync(capsys, repo, seed)) == (
        (1, "", NOT_MADE % "feature/hand-made"),) * 2
    assert (head(repo.root), sha_of_base(repo.root, "feature/hand-made")) == (before, "")


def test_the_base_branch_itself_is_refused_as_no_plugin_made_branch(repo, seed, capsys):
    run_git(repo.root, "checkout", "-q", "main")
    before = head(repo.root)

    assert sync(capsys, repo, seed) == (1, "", NOT_MADE % "main")
    assert head(repo.root) == before


def test_a_branch_recorded_as_its_own_base_is_refused(repo, seed, capsys):
    run_git(repo.root, "checkout", "-q", "main")
    record(repo.root, "main", "main")
    before = head(repo.root)

    assert sync(capsys, repo, seed) == (
        1, "", "orch: main is its own base branch - nothing was synced\n")
    assert (head(repo.root), sha_of_base(repo.root, "main")) == (before, "")


def test_a_ticket_branch_is_refused_as_no_plugin_made_branch_to_sync(repo, seed, capsys):
    run_git(repo.root, "checkout", "-q", "-b", "feature/ticketed")
    run_git(repo.root, "config", "branch.feature/ticketed.orchestrator-ticket-parent", "main")

    assert sync(capsys, repo, seed) == (1, "", NOT_MADE % "feature/ticketed")


def test_an_unreadable_state_json_is_refused(repo, seed, capsys):
    state_json(repo.root).write_text("{ not json\n")

    assert sync(capsys, repo, seed) == (
        1, "", "orch: state.json cannot be read - run orch.sh doctor --flow\n")


@pytest.mark.parametrize("argv", [("extra",), ("--finish", "extra"), ("--Finish",)])
def test_any_argument_but_finish_is_a_usage_error(repo, seed, capsys, argv):
    assert sync(capsys, repo, seed, *argv) == (1, "", USAGE)


def test_an_argument_is_a_usage_error_before_the_detached_head(repo, seed, capsys):
    # Both its first checks broken: the argument and the detached HEAD.
    run_git(repo.root, "checkout", "-q", "--detach")

    assert sync(capsys, repo, seed, "extra") == (1, "", USAGE)


def test_a_base_sha_git_will_not_record_ends_the_run_with_git_s_refusal(repo, seed, capsys):
    # A lock on the config, as a git run holding it leaves one: bash's bare
    # `git config` under set -e let git's refusal and status through.
    new_tip = advance(repo, "locked.txt", "locked\n")
    sha_before = sha_of_base(repo.root)
    (repo.root / ".git" / "config.lock").write_text("")

    code, out, err = sync(capsys, repo, seed)

    assert (code, out) == (255, "")
    assert err.startswith("error: could not lock config file")
    assert head(repo.root, "HEAD^2") == new_tip
    assert (sha_of_base(repo.root), state_sha(repo.root)) == (sha_before, sha_before)
