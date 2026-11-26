"""The ticket-worktree noun and the ticket worktree concept, run in-process in
a real repository under tmp_path - ADR-0067's carve-out for git history
semantics: a fork, a rebase left in progress, the merged check beside a
same-named tag (#2337) and a ticket branch with no upstream (#1152). The
cases of the bash ticket-worktree sections: `add`, `list` and `remove` with
every usage line and the unknown-op refusal, each worktree state
ticket_facts reads, the back-out after a failed add, the teardown's refusals
and its two failure results, and the worktrees_left bridge doctor calls."""
from __future__ import annotations

import os
import shutil
from pathlib import Path

import pytest

from conftest import committed, died_of, origin_clone, run_git
from orch import ticket_worktree
from orch.git import Git, GitFailure

CLAUDE = {"ORCHESTRATOR_HOST": "claude"}
AUTOPILOT = {"ORCHESTRATOR_HOST": "claude", "ORCH_AUTOPILOT": "1"}

PARENT = "orch/5-feature"
TICKET7 = PARENT + "--t7"


@pytest.fixture
def repo(tmp_path, monkeypatch):
    """bash's tw_repo: a clone of a bare origin with one commit on its
    default branch pushed, then PARENT checked out with a feature.txt commit
    of its own, git's identity set; the process's working directory: its
    root, resolved."""
    root = tmp_path.resolve() / "repo"
    origin_clone(tmp_path / "origin.git", root)
    for key, value in (("user.name", "t"), ("user.email", "t@t"), ("commit.gpgsign", "false")):
        run_git(root, "config", key, value)
    committed(root, {"README.md": "# repo\n"}, "init")
    run_git(root, "push", "-q", "origin", "HEAD")
    run_git(root, "checkout", "-qb", PARENT)
    committed(root, {"feature.txt": "work\n"}, "feature")
    monkeypatch.chdir(root)
    return root


def orch_tw(*argv, env=None):
    """`orch.sh ticket-worktree <argv>` in-process in the working directory's
    checkout, under <env> (Claude Code's plain session when None): its exit
    code."""
    return ticket_worktree.run(list(argv), env=CLAUDE if env is None else env)


def wt_path(root, n):
    """Where ticket <n>'s ticket worktree lives under the checkout at <root>,
    as a str."""
    return str(root / ".orchestrator" / "worktrees" / ("t%s" % n))


def added(root, capsys, n=7):
    """`ticket-worktree add <n>` run and its output drained: the path it
    printed, a str."""
    assert orch_tw("add", str(n)) == 0
    return capsys.readouterr().out.rstrip("\n")


def git_of(root, *args):
    """git <args> in the checkout at <root>, its stdout stripped; a failure
    reads as ""."""
    try:
        return run_git(root, *args)
    except Exception:  # noqa: BLE001 - a git refusal is the answer here
        return ""


def has_branch(root, branch):
    return git_of(root, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch) != ""


def exclude_count(root, line):
    with open(str(root / ".git" / "info" / "exclude")) as f:
        return f.read().split("\n").count(line)


# --- ticket-worktree add ------------------------------------------------------------


@pytest.mark.parametrize("env", [CLAUDE, AUTOPILOT], ids=["plain", "autopilot"])
def test_add_forks_the_ticket_branch_records_its_parent_and_prints_the_path(repo, capsys, env):
    tip = run_git(repo, "rev-parse", "HEAD")

    assert orch_tw("add", "7", env=env) == 0

    path = wt_path(repo, 7)
    assert capsys.readouterr() == (path + "\n", "")
    assert run_git(path, "rev-parse", "--show-toplevel") == path
    assert run_git(path, "branch", "--show-current") == TICKET7
    assert run_git(repo, "rev-parse", TICKET7) == tip
    assert run_git(repo, "config", "--get",
                   "branch.orch/5-feature--t7.orchestrator-ticket-parent") == PARENT
    assert run_git(repo, "branch", "--show-current") == PARENT
    assert run_git(repo, "status", "--porcelain") == ""


def test_add_writes_each_exclude_entry_once(repo, capsys):
    added(repo, capsys, 7)
    added(repo, capsys, 8)

    assert (exclude_count(repo, ".orchestrator/"), exclude_count(repo, ".scratch/")) == (1, 1)


def test_add_refuses_an_existing_worktree(repo, capsys):
    path = added(repo, capsys)

    assert died_of(capsys, lambda: orch_tw("add", "7")) == (
        1, "", "orch: ticket worktree %s already exists\n" % path)


def test_add_refuses_an_existing_ticket_branch_adding_no_worktree(repo, capsys):
    run_git(repo, "branch", TICKET7)

    assert died_of(capsys, lambda: orch_tw("add", "7")) == (
        1, "", "orch: branch %s already exists\n" % TICKET7)
    assert not os.path.exists(wt_path(repo, 7))


@pytest.mark.parametrize("argv, err", [
    (("add",), "orch: usage: orch.sh ticket-worktree add <n>\n"),
    (("add", "7", "8"), "orch: usage: orch.sh ticket-worktree add <n>\n"),
    (("add", "0"), "orch: not a ticket number: 0 (want a positive integer)\n"),
    (("add", "07"), "orch: not a ticket number: 07 (want a positive integer)\n"),
    (("add", "x"), "orch: not a ticket number: x (want a positive integer)\n"),
    (("add", ""), "orch: not a ticket number: <none> (want a positive integer)\n"),
])
def test_add_refuses_a_missing_or_bad_ticket_number(repo, capsys, argv, err):
    assert died_of(capsys, lambda: orch_tw(*argv)) == (1, "", err)


def test_add_refuses_a_detached_head(repo, capsys):
    run_git(repo, "checkout", "-q", "--detach")

    assert died_of(capsys, lambda: orch_tw("add", "9")) == (
        1, "", "orch: not on a branch (detached HEAD)\n")


def test_a_failed_worktree_add_takes_the_branch_back_out(repo, capsys):
    # .orchestrator/worktrees is a file, so no worktree can be made under it.
    (repo / ".orchestrator").mkdir()
    (repo / ".orchestrator" / "worktrees").write_text("")

    code, out, err = died_of(capsys, lambda: orch_tw("add", "3"))

    assert (code, out) == (1, "")
    assert err.endswith("orch: could not add ticket worktree %s - removed branch %s again\n"
                        % (wt_path(repo, 3), PARENT + "--t3"))
    assert not has_branch(repo, PARENT + "--t3")
    assert git_of(repo, "config", "--get",
                  "branch.orch/5-feature--t3.orchestrator-ticket-parent") == ""
    assert len(run_git(repo, "worktree", "list").splitlines()) == 1
    assert exclude_count(repo, ".orchestrator/") == 1


def test_a_failed_parent_record_takes_the_worktree_and_branch_back_out(repo, capsys,
                                                                     monkeypatch):
    monkeypatch.setattr(Git, "config_set", lambda self, scope, key, value: False)

    assert died_of(capsys, lambda: orch_tw("add", "3")) == (
        1, "", "orch: could not add ticket worktree %s - removed branch %s again\n"
        % (wt_path(repo, 3), PARENT + "--t3"))
    assert not os.path.exists(wt_path(repo, 3))
    assert not has_branch(repo, PARENT + "--t3")


def test_add_dies_before_acting_where_the_checkouts_cannot_be_read(repo, capsys, monkeypatch):
    monkeypatch.setattr(Git, "worktree_list", lambda self: None)

    assert died_of(capsys, lambda: orch_tw("add", "7")) == (
        1, "", "orch: could not read the checkouts - git worktree list failed\n")
    assert not os.path.exists(wt_path(repo, 7)) and not has_branch(repo, TICKET7)


def test_a_branch_git_will_not_create_dies_handing_git_s_stderr_on(repo, capsys, monkeypatch):
    monkeypatch.setattr(Git, "branch_create",
                        lambda self, name, start: GitFailure(128, "fatal: no\n"))

    assert died_of(capsys, lambda: orch_tw("add", "7")) == (
        1, "", "fatal: no\norch: could not create branch %s\n" % TICKET7)


def test_a_ticket_branch_has_no_upstream_under_auto_setup_merge_inherit(repo, capsys):
    run_git(repo, "push", "-q", "-u", "origin", PARENT)
    run_git(repo, "config", "branch.autoSetupMerge", "inherit")

    added(repo, capsys, 4)

    branch = PARENT + "--t4"
    assert git_of(repo, "config", "--get", "branch.%s.merge" % branch) == ""
    assert git_of(repo, "config", "--get", "branch.%s.remote" % branch) == ""
    assert git_of(repo, "rev-parse", "--symbolic-full-name", branch + "@{upstream}") == ""


def test_add_from_a_linked_worktree_lands_under_its_own_top_level(repo, capsys, tmp_path,
                                                                 monkeypatch):
    linked = tmp_path.resolve() / "elsewhere" / "linked"
    linked.parent.mkdir()
    run_git(repo, "worktree", "add", "-q", "-b", "orch/6-other", str(linked))
    added(repo, capsys, 2)
    monkeypatch.chdir(linked)

    path = added(linked, capsys, 4)

    assert path == wt_path(linked, 4)
    assert exclude_count(repo, ".orchestrator/") == 1
    assert run_git(linked, "status", "--porcelain") == ""
    assert orch_tw("list") == 0
    assert capsys.readouterr().out == "4 %s\n" % wt_path(linked, 4)
    monkeypatch.chdir(repo)
    assert orch_tw("list") == 0
    assert capsys.readouterr().out == "2 %s\n" % wt_path(repo, 2)


# --- ticket-worktree list, the dispatch and the worktrees_left bridge -------------------


def test_list_prints_each_ticket_worktree_under_this_checkout(repo, capsys):
    added(repo, capsys, 7)
    added(repo, capsys, 8)

    assert orch_tw("list") == 0

    assert capsys.readouterr() == ("7 %s\n8 %s\n" % (wt_path(repo, 7), wt_path(repo, 8)), "")


def test_list_with_no_ticket_worktrees_prints_nothing(repo, capsys):
    assert orch_tw("list") == 0

    assert capsys.readouterr() == ("", "")


def test_list_dies_when_the_checkouts_cannot_be_read(repo, capsys, monkeypatch):
    monkeypatch.setattr(Git, "worktree_list", lambda self: None)

    assert died_of(capsys, lambda: orch_tw("list")) == (
        1, "", "orch: could not read the checkouts - git worktree list failed\n")


def test_list_takes_no_arguments(repo, capsys):
    assert died_of(capsys, lambda: orch_tw("list", "7")) == (
        1, "", "orch: usage: orch.sh ticket-worktree list\n")


@pytest.mark.parametrize("argv, shown", [((), "<none>"), (("bogus",), "bogus"), (("",), "<none>")])
def test_an_unknown_op_is_refused_naming_the_ops_there_are(repo, capsys, argv, shown):
    assert died_of(capsys, lambda: orch_tw(*argv)) == (
        1, "", "orch: unknown ticket-worktree op: %s (want add|list|remove)\n" % shown)


def bridge(*args):
    """`orch_python_call ticket-worktree worktrees_left <args>` as
    orch.__main__ hands it to call_func: its exit code."""
    from orch import cli

    return cli.call_func(["ticket-worktree", "worktrees_left", *args])


def test_worktrees_left_prints_what_list_prints_for_the_same_checkout(repo, capsys):
    added(repo, capsys, 7)
    added(repo, capsys, 12)
    assert orch_tw("list") == 0
    listed = capsys.readouterr()

    assert bridge() == 0

    assert capsys.readouterr() == listed
    # In git's worktree list order, which sorts t12 before t7.
    assert listed.out == "12 %s\n7 %s\n" % (wt_path(repo, 12), wt_path(repo, 7))


@pytest.mark.parametrize("args", [("7",), ("",), ("a", "b")])
def test_worktrees_left_dies_on_any_argument_with_its_usage(repo, capsys, args):
    assert died_of(capsys, lambda: bridge(*args)) == (
        1, "", "orch: usage: orch_python_call ticket-worktree worktrees_left\n")


# --- ticket_facts, the one read of a ticket's facts -----------------------------------


def facts_of(repo, n="7"):
    return ticket_worktree.ticket_facts(Git(), str(repo), n)


def mid_rebase(repo, wt):
    """The ticket worktree at <wt> left stopped on a conflict, rebasing onto
    PARENT, which gains a conflicting commit of its own."""
    committed(Path(wt), {"feature.txt": "ticket\n"}, "ticket edit")
    committed(repo, {"feature.txt": "parent\n"}, "parent edit")
    with pytest.raises(Exception):  # noqa: B017 - the conflict is the point
        run_git(wt, "rebase", "-q", PARENT)
    assert os.path.isdir(run_git(wt, "rev-parse", "--absolute-git-dir") + "/rebase-merge")


def test_the_facts_of_nothing_are_none_with_the_own_branch_built_from_the_parent(repo):
    assert facts_of(repo) == ticket_worktree.TicketFacts(
        n="7", path=wt_path(repo, 7), worktree="none", wt_branch="", parent=PARENT,
        own_branch=TICKET7, own_exists=False)


def test_a_leftover_directory_with_no_record_is_none(repo):
    os.makedirs(wt_path(repo, 7))

    assert facts_of(repo).worktree == "none"


def test_a_worktree_at_the_path_is_worktree_on_its_own_branch(repo, capsys):
    added(repo, capsys)

    facts = facts_of(repo)

    assert (facts.worktree, facts.wt_branch, facts.own_exists) == ("worktree", TICKET7, True)


def test_another_branch_checked_out_there_is_its_wt_branch(repo, capsys):
    wt = added(repo, capsys)
    run_git(wt, "checkout", "-qb", "other")

    facts = facts_of(repo)

    assert (facts.wt_branch, facts.own_branch) == ("other", TICKET7)


def test_mid_rebase_the_state_is_worktree_and_wt_branch_is_empty(repo, capsys):
    mid_rebase(repo, added(repo, capsys))

    facts = facts_of(repo)

    assert (facts.worktree, facts.wt_branch) == ("worktree", "")


def test_a_worktree_whose_ticket_branch_is_gone_has_no_own_branch(repo, capsys):
    wt = added(repo, capsys)
    run_git(wt, "checkout", "-q", "--detach")
    run_git(repo, "branch", "-q", "-D", TICKET7)

    facts = facts_of(repo)

    assert (facts.worktree, facts.own_exists) == ("worktree", False)


def test_a_record_whose_directory_is_gone_is_gone_then_occupied_by_a_plain_directory(
        repo, capsys):
    wt = added(repo, capsys)
    shutil.rmtree(wt)

    gone = facts_of(repo)
    os.mkdir(wt)
    occupied = facts_of(repo)

    assert (gone.worktree, gone.wt_branch) == ("gone", "")
    assert (occupied.worktree, occupied.wt_branch) == ("occupied", "")


@pytest.mark.parametrize("worktree", [True, False], ids=["a worktree present", "nothing there"])
def test_the_read_dies_when_the_checkouts_cannot_be_read(repo, capsys, monkeypatch, worktree):
    if worktree:
        added(repo, capsys)
    monkeypatch.setattr(Git, "worktree_list", lambda self: None)

    assert died_of(capsys, lambda: facts_of(repo)) == (
        1, "", "orch: could not read the checkouts - git worktree list failed\n")


def test_a_worktree_mid_rebase_is_refused_as_on_no_branch(repo, capsys):
    wt = added(repo, capsys)
    ticket_worktree.ticket_facts_require_wt_branch(facts_of(repo))
    mid_rebase(repo, wt)

    assert died_of(capsys, lambda: ticket_worktree.ticket_facts_require_wt_branch(
        facts_of(repo))) == (
        1, "", "orch: ticket worktree %s is not on a branch (detached HEAD)\n" % wt)


def test_a_detached_head_reads_no_parent_and_no_own_branch_without_dying(repo):
    run_git(repo, "checkout", "-q", "--detach")

    facts = facts_of(repo)

    assert (facts.parent, facts.own_branch, facts.own_exists) == ("", "", False)


# --- ticket-worktree remove and ticket_worktree_teardown ----------------------------


def teardown_of(repo, n="7", unmerged=False, discard=False):
    """ticket_worktree_teardown on ticket <n>'s facts, read first: its
    result."""
    git = Git()
    return ticket_worktree.ticket_worktree_teardown(
        git, ticket_worktree.ticket_facts(git, str(repo), n), unmerged=unmerged, discard=discard)


def listed(capsys):
    """What `ticket-worktree list` prints now."""
    assert orch_tw("list") == 0
    return capsys.readouterr().out


def rebasing(path):
    return os.path.isdir(run_git(path, "rev-parse", "--absolute-git-dir") + "/rebase-merge")


def worked(wt, message="ticket work"):
    """An empty commit on the branch checked out at <wt>: its SHA."""
    run_git(wt, "commit", "-q", "--allow-empty", "-m", message)
    return run_git(wt, "rev-parse", "HEAD")


def test_remove_of_a_merged_clean_ticket_takes_the_worktree_and_branch(repo, capsys):
    wt = added(repo, capsys)

    assert orch_tw("remove", "7") == 0

    assert capsys.readouterr() == ("", "")
    assert not os.path.exists(wt) and not has_branch(repo, TICKET7)
    assert len(run_git(repo, "worktree", "list").splitlines()) == 1
    assert listed(capsys) == ""


@pytest.mark.parametrize("flags", [(), ("--unmerged",)], ids=["plain", "--unmerged"])
@pytest.mark.parametrize("dirt", ["README.md", "untracked.txt"])
def test_remove_refuses_a_dirty_worktree_never_forcing_it(repo, capsys, flags, dirt):
    wt = added(repo, capsys)
    Path(wt, dirt).write_text("dirty\n")

    assert died_of(capsys, lambda: orch_tw("remove", "7", *flags)) == (
        1, "", "orch: ticket worktree %s is dirty - commit or discard its changes first; it is"
               " never removed with force\n" % wt)
    assert Path(wt, dirt).read_text() == "dirty\n" and has_branch(repo, TICKET7)


def test_remove_refuses_an_unmerged_branch_and_unmerged_discards_it(repo, capsys):
    wt = added(repo, capsys)
    tip = worked(wt)

    assert died_of(capsys, lambda: orch_tw("remove", "7")) == (
        1, "", "orch: branch %s is not merged into %s - merge it first, or pass --unmerged to"
               " discard it\n" % (TICKET7, PARENT))
    assert os.path.exists(wt) and run_git(repo, "rev-parse", TICKET7) == tip
    assert orch_tw("remove", "7", "--unmerged") == 0
    assert not os.path.exists(wt) and not has_branch(repo, TICKET7)


def test_remove_refuses_a_branch_that_records_no_forked_from_branch(repo, capsys):
    wt = added(repo, capsys)
    tip = worked(wt)
    run_git(repo, "config", "--unset", "branch.%s.orchestrator-ticket-parent" % TICKET7)

    assert died_of(capsys, lambda: orch_tw("remove", "7")) == (
        1, "", "orch: branch %s records no forked-from branch - pass --unmerged to discard it\n"
        % TICKET7)
    assert os.path.exists(wt) and run_git(repo, "rev-parse", TICKET7) == tip


def test_unmerged_aborts_a_rebase_left_in_progress_before_its_dirty_refusal(repo, capsys):
    wt = added(repo, capsys)
    mid_rebase(repo, wt)
    tip = run_git(repo, "rev-parse", TICKET7)
    Path(wt, "untracked.txt").write_text("leftover\n")

    code, out, err = died_of(capsys, lambda: teardown_of(repo, unmerged=True))

    assert (code, out) == (1, "") and "orch: ticket worktree %s is dirty" % wt in err
    assert not rebasing(wt)
    assert (run_git(wt, "rev-parse", "HEAD"), run_git(wt, "branch", "--show-current")) == (
        tip, TICKET7)
    assert os.path.exists(wt)


def test_unmerged_tears_down_a_clean_worktree_left_mid_rebase(repo, capsys):
    wt = added(repo, capsys)
    mid_rebase(repo, wt)

    assert teardown_of(repo, unmerged=True) == 0

    assert not os.path.exists(wt) and not has_branch(repo, TICKET7)


def test_without_unmerged_a_rebase_left_in_progress_is_refused_and_kept(repo, capsys):
    wt = added(repo, capsys)
    mid_rebase(repo, wt)

    assert died_of(capsys, lambda: teardown_of(repo))[0] == 1

    assert rebasing(wt)


def test_remove_unmerged_aborts_a_mid_rebase_worktree_s_rebase_then_removes_it(repo, capsys):
    wt = added(repo, capsys)
    mid_rebase(repo, wt)

    assert orch_tw("remove", "7", "--unmerged") == 0

    assert not os.path.exists(wt) and not has_branch(repo, TICKET7)


def test_discard_throws_dirty_work_away_under_the_ticket_label(repo, capsys):
    wt = added(repo, capsys)
    worked(wt)
    Path(wt, "README.md").write_text("dirty\n")
    lock = Path(run_git(wt, "rev-parse", "--absolute-git-dir"), "index.lock")
    lock.write_text("")

    assert died_of(capsys, lambda: teardown_of(repo, unmerged=True, discard=True)) == (
        1, "", "orch: ticket #7: git reset --hard failed in %s\n" % wt)
    assert os.path.exists(wt)
    lock.unlink()
    assert teardown_of(repo, unmerged=True, discard=True) == 0
    assert not os.path.exists(wt) and not has_branch(repo, TICKET7)


def test_discard_of_a_merged_branch_takes_it_without_unmerged(repo, capsys):
    wt = added(repo, capsys)
    Path(wt, "README.md").write_text("dirty\n")

    assert teardown_of(repo, discard=True) == 0

    assert not os.path.exists(wt)


def test_a_branch_whose_worktree_is_gone_is_judged_alone(repo, capsys):
    wt = added(repo, capsys)
    run_git(repo, "worktree", "remove", wt)
    assert teardown_of(repo) == 0
    assert not has_branch(repo, TICKET7)

    wt = added(repo, capsys)
    worked(wt, "work")
    run_git(repo, "worktree", "remove", wt)
    assert died_of(capsys, lambda: teardown_of(repo))[0] == 1
    assert has_branch(repo, TICKET7)
    assert teardown_of(repo, unmerged=True) == 0
    assert not has_branch(repo, TICKET7)

    assert died_of(capsys, lambda: teardown_of(repo)) == (
        1, "", "orch: no ticket worktree or branch for ticket 7 at %s\n" % wt)


def test_a_worktree_that_cannot_be_removed_returns_the_worktree_step_s_status(repo, capsys):
    wt = added(repo, capsys)
    run_git(repo, "worktree", "lock", wt)

    assert teardown_of(repo) == ticket_worktree.TICKET_TEARDOWN_WORKTREE_FAILED == 10

    err = capsys.readouterr().err
    assert err.startswith("fatal: ")
    assert err.endswith("orch: could not remove ticket worktree %s\n" % wt)
    assert os.path.exists(wt) and has_branch(repo, TICKET7)


def lock_ref(repo, branch):
    """A lock file on local branch <branch>'s ref, as a git run holding it
    leaves one, so no git can delete the branch."""
    lock = repo / ".git" / "refs" / "heads" / (branch + ".lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    lock.write_text("")
    return lock


def test_a_branch_that_cannot_be_deleted_returns_the_branch_step_s_status(repo, capsys):
    wt = added(repo, capsys)
    lock_ref(repo, TICKET7)

    assert teardown_of(repo) == ticket_worktree.TICKET_TEARDOWN_BRANCH_FAILED == 11

    err = capsys.readouterr().err
    assert err.startswith("error: ")
    assert err.endswith("orch: could not delete branch %s\n" % TICKET7)
    assert not os.path.exists(wt) and has_branch(repo, TICKET7)


@pytest.mark.parametrize("step", ["worktree", "branch"])
def test_remove_exits_1_with_the_teardown_s_message_on_either_failed_step(repo, capsys, step):
    wt = added(repo, capsys)
    if step == "worktree":
        run_git(repo, "worktree", "lock", wt)
        said = "orch: could not remove ticket worktree %s\n" % wt
    else:
        lock_ref(repo, TICKET7)
        said = "orch: could not delete branch %s\n" % TICKET7

    code, out, err = died_of(capsys, lambda: orch_tw("remove", "7"))

    assert (code, out) == (1, "") and err.endswith(said)


def test_a_worktree_on_another_branch_is_removed_keeping_that_branch(repo, capsys):
    wt = added(repo, capsys)
    run_git(wt, "checkout", "-qb", "elsewhere")

    assert teardown_of(repo) == 0

    assert not os.path.exists(wt)
    assert has_branch(repo, "elsewhere") and not has_branch(repo, TICKET7)


def test_a_worktree_whose_ticket_branch_is_gone_is_refused_then_cleared_by_unmerged(repo,
                                                                                    capsys):
    wt = added(repo, capsys)
    run_git(wt, "checkout", "-q", "--detach")
    run_git(repo, "branch", "-q", "-D", TICKET7)

    assert died_of(capsys, lambda: teardown_of(repo))[0] == 1
    assert os.path.exists(wt)
    assert teardown_of(repo, unmerged=True) == 0
    assert not os.path.exists(wt)


def test_a_detached_current_checkout_dies_with_the_work_untouched(repo, capsys):
    wt = added(repo, capsys)
    Path(wt, "README.md").write_text("dirty\n")
    run_git(repo, "checkout", "-q", "--detach")

    assert died_of(capsys, lambda: teardown_of(repo, unmerged=True, discard=True)) == (
        1, "", "orch: not on a branch (detached HEAD)\n")
    assert Path(wt, "README.md").read_text() == "dirty\n"


def test_a_leftover_t_n_directory_is_no_worktree_so_the_enclosing_rebase_stays(repo, capsys):
    run_git(repo, "checkout", "-qb", "orch/5-side")
    committed(repo, {"feature.txt": "side\n"}, "side edit")
    run_git(repo, "checkout", "-q", PARENT)
    committed(repo, {"feature.txt": "main\n"}, "main edit")
    with pytest.raises(Exception):  # noqa: B017 - the conflict is the point
        run_git(repo, "rebase", "-q", "orch/5-side")
    os.makedirs(wt_path(repo, 9))

    assert died_of(capsys, lambda: orch_tw("remove", "9", "--unmerged")) == (
        1, "", "orch: no ticket worktree for ticket 9 at %s\n" % wt_path(repo, 9))
    assert rebasing(repo)


def test_remove_from_another_branch_judges_that_branch_s_ticket_branch(repo, capsys):
    wt = added(repo, capsys)
    worked(wt)
    run_git(repo, "merge", "-q", "--ff-only", TICKET7)
    run_git(repo, "checkout", "-qb", "orch/5-elsewhere", "HEAD~1")

    assert died_of(capsys, lambda: orch_tw("remove", "7"))[0] == 1

    assert os.path.exists(wt)


@pytest.mark.parametrize("argv, err", [
    (("remove",), "orch: not a ticket number: <none> (want a positive integer)\n"),
    (("remove", "7", "8"), "orch: usage: orch.sh ticket-worktree remove <n> [--unmerged]\n"),
    (("remove", "7", "--bogus"),
     "orch: unknown flag: --bogus (usage: orch.sh ticket-worktree remove <n> [--unmerged])\n"),
    (("remove", "-"),
     "orch: unknown flag: - (usage: orch.sh ticket-worktree remove <n> [--unmerged])\n"),
    (("remove", "7"), None),
])
def test_remove_refuses_bad_arguments_and_a_ticket_with_no_worktree(repo, capsys, argv, err):
    err = err or "orch: no ticket worktree for ticket 7 at %s\n" % wt_path(repo, 7)

    assert died_of(capsys, lambda: orch_tw(*argv)) == (1, "", err)


def test_a_merged_ticket_whose_directory_is_gone_is_removed_with_no_flag(repo, capsys,
                                                                         tmp_path):
    wt = added(repo, capsys)
    worked(wt)
    run_git(repo, "merge", "-q", "--ff-only", TICKET7)
    other = tmp_path.resolve() / "other"
    run_git(repo, "worktree", "add", "-q", "-b", "gone-other", str(other))
    shutil.rmtree(str(other))
    shutil.rmtree(wt)
    assert listed(capsys) == "7 %s\n" % wt

    assert orch_tw("remove", "7") == 0

    porcelain = run_git(repo, "worktree", "list", "--porcelain").splitlines()
    assert "worktree " + wt not in porcelain and "worktree %s" % other in porcelain
    assert listed(capsys) == "" and not has_branch(repo, TICKET7)


def test_an_unmerged_ticket_whose_directory_is_gone_is_kept_until_unmerged(repo, capsys):
    wt = added(repo, capsys)
    worked(wt, "unmerged work")
    shutil.rmtree(wt)

    code, _, err = died_of(capsys, lambda: orch_tw("remove", "7"))

    assert code == 1 and "is not merged into" in err
    assert listed(capsys) == "7 %s\n" % wt and has_branch(repo, TICKET7)
    assert orch_tw("remove", "7", "--unmerged") == 0
    assert listed(capsys) == "" and not has_branch(repo, TICKET7)


@pytest.mark.parametrize("kind", ["dir", "file"])
def test_something_else_at_the_recorded_path_is_refused_before_the_merged_check(repo, capsys,
                                                                               kind):
    wt = added(repo, capsys)
    worked(wt, "unmerged work")
    shutil.rmtree(wt)
    if kind == "dir":
        os.mkdir(wt)
    else:
        Path(wt).write_text("x\n")
    refusal = (1, "", "orch: ticket worktree path %s holds something that is not a worktree,"
                      " though git's record names it - delete it and run the command again\n"
               % wt)

    assert died_of(capsys, lambda: orch_tw("remove", "7", "--unmerged")) == refusal
    assert died_of(capsys, lambda: orch_tw("remove", "7")) == refusal
    assert os.path.lexists(wt) and listed(capsys) == "7 %s\n" % wt


def test_a_gone_directory_holding_another_branch_keeps_that_branch(repo, capsys):
    wt = added(repo, capsys)
    run_git(wt, "checkout", "-qb", "keep-me")
    worked(wt, "other branch work")
    run_git(repo, "merge", "-q", "--ff-only", "keep-me")
    shutil.rmtree(wt)

    assert teardown_of(repo) == 0

    assert has_branch(repo, "keep-me") and not has_branch(repo, TICKET7)
    assert listed(capsys) == ""


def test_a_gone_directory_whose_ticket_branch_is_gone_is_cleared_only_by_unmerged(repo,
                                                                                  capsys):
    wt = added(repo, capsys)
    run_git(wt, "checkout", "-q", "--detach")
    run_git(repo, "branch", "-q", "-D", TICKET7)
    shutil.rmtree(wt)

    assert died_of(capsys, lambda: teardown_of(repo))[0] == 1
    assert listed(capsys) == "7 %s\n" % wt
    assert teardown_of(repo, unmerged=True) == 0
    assert listed(capsys) == ""


# --- the merged check beside a same-named tag (#2337) ---------------------------------


def test_the_merged_check_judges_the_parent_branch_never_a_tag_named_like_it(repo, capsys):
    wt = added(repo, capsys)
    worked(wt)
    run_git(repo, "merge", "-q", "--ff-only", TICKET7)
    run_git(repo, "tag", PARENT, "HEAD~1")

    assert orch_tw("remove", "7") == 0


def test_the_merged_check_judges_the_ticket_branch_never_a_tag_named_like_it(repo, capsys):
    wt = added(repo, capsys)
    worked(wt)
    run_git(repo, "tag", TICKET7, PARENT)

    code, _, err = died_of(capsys, lambda: orch_tw("remove", "7"))

    assert code == 1 and "not merged" in err
