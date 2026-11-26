"""The ticket noun's landing verbs - `close`, `merge` and `reclaim` - run
in-process in a real repository under tmp_path, against the gh fake on a
tmp_path store: ADR-0067's carve-out for git history semantics, a rebase, a
fast-forward and a same-named tag (#2337). The cases of the bash ticket
close, ticket merge, same-named tag and ticket reclaim sections: close's
merged refusal (#1146), --unmerged and the no-worktree case; merge's every
refusal before anything moves, a clean merge, a conflict's exit 3 with both
branches at their prior tips, a rebase failing any other way and a
fast-forward failing after a clean rebase; and reclaim's guard (ADR-0054)
and each leftover's case. The close and merge cases run once more with
ORCH_AUTOPILOT=1, asserting the plain run's stdout, stderr and exit."""
from __future__ import annotations

import os
import shutil
from pathlib import Path

import pytest

from conftest import (CLAUDE, GH_502, TICKET_PARENT, added, committed, died_of, fake, has_branch,
                      hold_flow, lock_ref, orch_tw, read, rebasing, run_git, state_json, wt_path)
from orch import ticket
from orch.common import exclude_orch_dirs
from orch.git import Git, GitFailure

AUTOPILOT = {"ORCHESTRATOR_HOST": "claude", "ORCH_AUTOPILOT": "1"}
SESSIONS = pytest.mark.parametrize("env", [CLAUDE, AUTOPILOT], ids=["plain", "autopilot"])

PARENT = TICKET_PARENT
TICKET7 = PARENT + "--t7"


@pytest.fixture
def repo(ticket_repo):
    """conftest's ticket_repo, under the name this file's cases use."""
    return ticket_repo


def orch_ticket(seed, *argv, env=None):
    """`orch.sh ticket <argv>` in-process in the working directory's
    checkout, on <seed>'s store, under <env> (Claude Code's plain session
    when None): its exit code."""
    return ticket.run(list(argv), gh=fake(seed), env=CLAUDE if env is None else env)


def state_of(seed, n):
    """Issue #n's state in <seed>'s store: OPEN or CLOSED."""
    return (read(seed.store, "issues", n, "state") or "").strip()


def tip(root, branch):
    """The commit local branch <branch> is at, named in full so a same-named
    tag is never read."""
    return run_git(root, "rev-parse", "refs/heads/" + branch)


def work(path, name, text):
    """<name> committed holding <text> in the checkout at <path>, its message
    "<name>: <text>"."""
    committed(Path(path), {name: text + "\n"}, "%s: %s" % (name, text))


def switched(repo, capsys, n):
    """Ticket <n>'s worktree, switched to other-<n> with its forked-from
    record set to PARENT and one commit: its path."""
    wt = added(repo, capsys, n)
    run_git(wt, "checkout", "-q", "-b", "other-%s" % n)
    run_git(repo, "config", "branch.other-%s.orchestrator-ticket-parent" % n, PARENT)
    work(wt, "other%s.txt" % n, "one")
    return wt


# --- ticket close ---------------------------------------------------------------------


@SESSIONS
def test_close_of_a_ticket_with_no_worktree_closes_it(repo, seed, capsys, env):
    seed.issue(7, "open")

    assert orch_ticket(seed, "close", "7", env=env) == 0

    assert capsys.readouterr() == ("", "")
    assert state_of(seed, 7) == "CLOSED"


@SESSIONS
def test_close_refuses_a_ticket_whose_ticket_branch_is_unmerged(repo, seed, capsys, env):
    seed.issue(7, "open")
    work(added(repo, capsys), "ticket.txt", "one")

    assert died_of(capsys, lambda: orch_ticket(seed, "close", "7", env=env)) == (
        1, "", "orch: branch %s is not merged into %s - merge it first, or pass --unmerged to"
               " close it anyway\n" % (TICKET7, PARENT))
    assert state_of(seed, 7) == "OPEN"


@pytest.mark.parametrize("argv", [("7", "--unmerged"), ("--unmerged", "7")])
@SESSIONS
def test_close_unmerged_closes_an_unmerged_ticket_reading_no_checkouts(repo, seed, capsys,
                                                                      monkeypatch, argv, env):
    seed.issue(7, "open")
    work(added(repo, capsys), "ticket.txt", "one")
    monkeypatch.setattr(Git, "worktree_list", lambda self: None)

    assert orch_ticket(seed, "close", *argv, env=env) == 0

    assert capsys.readouterr() == ("", "")
    assert state_of(seed, 7) == "CLOSED"


@SESSIONS
def test_close_closes_a_ticket_merge_landed(repo, seed, capsys, env):
    seed.issue(8, "open")
    work(added(repo, capsys, 8), "ticket8.txt", "two")
    assert orch_ticket(seed, "merge", "8", env=env) == 0

    assert orch_ticket(seed, "close", "8", env=env) == 0

    assert state_of(seed, 8) == "CLOSED"


@SESSIONS
def test_close_from_a_detached_head_closes_a_merged_ticket(repo, seed, capsys, env):
    seed.issue(20, "open")
    work(added(repo, capsys, 20), "ticket20.txt", "one")
    assert orch_ticket(seed, "merge", "20", env=env) == 0
    run_git(repo, "checkout", "-q", "--detach")

    assert orch_ticket(seed, "close", "20", env=env) == 0

    assert state_of(seed, 20) == "CLOSED"


@SESSIONS
def test_close_refuses_a_ticket_branch_recording_no_forked_from_branch(repo, seed, capsys, env):
    seed.issue(9, "open")
    added(repo, capsys, 9)
    run_git(repo, "config", "--unset", "branch.%s--t9.orchestrator-ticket-parent" % PARENT)

    assert died_of(capsys, lambda: orch_ticket(seed, "close", "9", env=env)) == (
        1, "", "orch: branch %s--t9 records no forked-from branch - pass --unmerged to close it"
               " anyway\n" % PARENT)
    assert state_of(seed, 9) == "OPEN"


@SESSIONS
def test_close_refuses_a_ticket_worktree_on_a_detached_head(repo, seed, capsys, env):
    seed.issue(10, "open")
    wt = added(repo, capsys, 10)
    run_git(wt, "checkout", "-q", "--detach")

    assert died_of(capsys, lambda: orch_ticket(seed, "close", "10", env=env)) == (
        1, "", "orch: ticket worktree %s is not on a branch (detached HEAD)\n" % wt)
    assert state_of(seed, 10) == "OPEN"


@SESSIONS
def test_close_asks_the_merged_check_of_the_checked_out_branch(repo, seed, capsys, env):
    seed.issue(24, "open")
    switched(repo, capsys, 24)

    assert died_of(capsys, lambda: orch_ticket(seed, "close", "24", env=env)) == (
        1, "", "orch: branch other-24 is not merged into %s - merge it first, or pass --unmerged"
               " to close it anyway\n" % PARENT)
    assert state_of(seed, 24) == "OPEN"


@SESSIONS
def test_close_dies_when_the_checkouts_cannot_be_read(repo, seed, capsys, monkeypatch, env):
    seed.issue(22, "open")
    added(repo, capsys, 22)
    monkeypatch.setattr(Git, "worktree_list", lambda self: None)

    assert died_of(capsys, lambda: orch_ticket(seed, "close", "22", env=env)) == (
        1, "", "orch: could not read the checkouts - git worktree list failed\n")
    assert state_of(seed, 22) == "OPEN"


@SESSIONS
def test_close_ignores_a_leftover_directory_and_a_worktree_whose_directory_is_gone(repo, seed,
                                                                                capsys, env):
    seed.issue(11, "open")
    seed.issue(25, "open")
    os.makedirs(str(repo / ".orchestrator" / "worktrees" / "t11"))
    wt = added(repo, capsys, 25)
    work(wt, "ticket25.txt", "one")
    shutil.rmtree(wt)

    assert orch_ticket(seed, "close", "11", env=env) == 0
    assert orch_ticket(seed, "close", "25", env=env) == 0

    assert (state_of(seed, 11), state_of(seed, 25)) == ("CLOSED", "CLOSED")


@pytest.mark.parametrize("argv, err", [
    ((), "orch: usage: orch.sh ticket close <n> [--unmerged]\n"),
    (("--unmerged",), "orch: usage: orch.sh ticket close <n> [--unmerged]\n"),
    (("7", "8"), "orch: usage: orch.sh ticket close <n> [--unmerged]\n"),
    (("7", "--bogus"),
     "orch: unknown flag: --bogus (usage: orch.sh ticket close <n> [--unmerged])\n"),
    (("abc",), "orch: not a plain issue number: abc\n"),
])
@SESSIONS
def test_close_refuses_bad_arguments_leaving_the_issue_open(repo, seed, capsys, argv, err, env):
    seed.issue(7, "open")

    assert died_of(capsys, lambda: orch_ticket(seed, "close", *argv, env=env)) == (1, "", err)
    assert state_of(seed, 7) == "OPEN"


@SESSIONS
def test_a_close_github_refuses_dies_with_gh_s_first_line(repo, seed, capsys, env):
    seed.issue(7, "open")
    seed.fail("adapter_issue_close", GH_502)

    assert died_of(capsys, lambda: orch_ticket(seed, "close", "7", env=env)) == (
        1, "", "orch: gh could not close ticket #7: HTTP 502: Bad Gateway\n")


# --- ticket merge ---------------------------------------------------------------------


def subjects(root, ref, count):
    """The subjects of the <count> newest commits on <ref>, newest first."""
    return run_git(root, "log", "--format=%s", "-%d" % count, ref).split("\n")


def tips(repo):
    """(PARENT's tip, TICKET7's tip)."""
    return tip(repo, PARENT), tip(repo, TICKET7)


@SESSIONS
def test_merge_rebases_the_ticket_branch_and_fast_forwards_its_parent(repo, seed, capsys, env):
    wt = added(repo, capsys)
    work(wt, "ticket.txt", "one")
    work(wt, "ticket2.txt", "two")
    work(repo, "other.txt", "landed-first")
    flow_tip = tip(repo, PARENT)

    assert orch_ticket(seed, "merge", "7", env=env) == 0

    assert capsys.readouterr() == ("", "")
    assert subjects(repo, PARENT, 3) == ["ticket2.txt: two", "ticket.txt: one",
                                         "other.txt: landed-first"]
    assert run_git(repo, "rev-parse", PARENT + "~2") == flow_tip
    assert run_git(repo, "rev-list", "--merges", PARENT) == ""
    assert tip(repo, PARENT) == tip(repo, TICKET7)
    assert (repo / "ticket2.txt").read_text() == "two\n"
    assert run_git(repo, "status", "--porcelain") == ""
    assert orch_tw("remove", "7") == 0


@SESSIONS
def test_a_conflict_exits_3_leaving_both_branches_at_their_prior_tips(repo, seed, capsys, env):
    wt = added(repo, capsys)
    work(wt, "feature.txt", "from-ticket")
    work(repo, "feature.txt", "from-flow")
    before = tips(repo)

    assert died_of(capsys, lambda: orch_ticket(seed, "merge", "7", env=env)) == (
        3, "", "orch: rebasing %s onto %s hit a conflict - aborted; both branches are as they"
               " were\n" % (TICKET7, PARENT))
    assert tips(repo) == before
    assert not rebasing(wt)
    assert run_git(wt, "status", "--porcelain") == run_git(repo, "status", "--porcelain") == ""


@SESSIONS
def test_a_rebase_already_in_progress_is_refused_and_left_for_its_owner(repo, seed, capsys, env):
    wt = added(repo, capsys)
    work(wt, "feature.txt", "from-ticket")
    work(repo, "feature.txt", "from-flow")
    before = tips(repo)
    with pytest.raises(Exception):  # noqa: B017 - the conflict is the point
        run_git(wt, "rebase", "-q", PARENT)

    assert died_of(capsys, lambda: orch_ticket(seed, "merge", "7", env=env)) == (
        1, "", "orch: ticket worktree %s is not on a branch (detached HEAD)\n" % wt)
    assert rebasing(wt)
    assert tips(repo) == before


def refusing_hook(repo, tmp_path, script):
    """A pre-rebase hook running <script>, through core.hooksPath."""
    hooks = tmp_path / "hooks"
    hooks.mkdir()
    hook = hooks / "pre-rebase"
    hook.write_text("#!/bin/sh\n" + script)
    hook.chmod(0o755)
    run_git(repo, "config", "core.hooksPath", str(hooks))


@SESSIONS
def test_a_rebase_failing_without_a_conflict_exits_1_naming_git_s_first_line(repo, seed, capsys,
                                                                            tmp_path, env):
    wt = added(repo, capsys)
    work(wt, "ticket.txt", "one")
    work(repo, "other.txt", "landed-first")
    before = tips(repo)
    refusing_hook(repo, tmp_path, 'echo "no rebasing today"\necho "second line"\nexit 1\n')

    assert died_of(capsys, lambda: orch_ticket(seed, "merge", "7", env=env)) == (
        1, "", "orch: rebasing %s onto %s failed: no rebasing today\n" % (TICKET7, PARENT))
    assert tips(repo) == before
    assert not rebasing(wt)


@SESSIONS
def test_a_silent_refusing_hook_is_named_by_git_s_own_line(repo, seed, capsys, tmp_path, env):
    wt = added(repo, capsys)
    work(wt, "ticket.txt", "one")
    work(repo, "other.txt", "landed-first")
    before = tips(repo)
    refusing_hook(repo, tmp_path, "exit 1\n")

    code, out, err = died_of(capsys, lambda: orch_ticket(seed, "merge", "7", env=env))

    assert (code, out) == (1, "")
    assert err in ("orch: rebasing %s onto %s failed: %s: The pre-rebase hook refused to"
                   " rebase.\n" % (TICKET7, PARENT, word) for word in ("error", "fatal"))
    assert tips(repo) == before
    assert not rebasing(wt)


@SESSIONS
def test_a_fast_forward_failing_after_a_clean_rebase_leaves_the_ticket_branch_rebased(
        repo, seed, capsys, env):
    wt = added(repo, capsys)
    work(wt, "ticket.txt", "one")
    work(repo, "other.txt", "landed-first")
    flow_tip = tip(repo, PARENT)
    # A git run holding the checkout's index: status still reads the tree
    # clean, but no merge can write it.
    lock = repo / ".git" / "index.lock"
    lock.write_text("")

    code, out, err = died_of(capsys, lambda: orch_ticket(seed, "merge", "7", env=env))

    lock.unlink()
    assert (code, out) == (1, "")
    # git's own lines first, whichever prefix its version puts on them.
    assert err.split(": ", 1)[1].startswith("Unable to create '%s'" % lock)
    assert err.endswith("orch: could not fast-forward %s to %s in %s\n" % (PARENT, TICKET7, repo))
    assert tip(repo, PARENT) == flow_tip
    assert run_git(repo, "rev-parse", TICKET7 + "~1") == flow_tip
    assert subjects(repo, TICKET7, 1) == ["ticket.txt: one"]


def refused_changing_nothing(repo, seed, capsys, err, n="7", env=None):
    """`ticket merge <n>` dies with <err>, both of ticket 7's branches at
    their prior tips."""
    before = tips(repo)
    assert died_of(capsys, lambda: orch_ticket(seed, "merge", n, env=env)) == (1, "", err)
    assert tips(repo) == before


@SESSIONS
def test_merge_refuses_a_dirty_tree_on_either_side(repo, seed, capsys, env):
    wt = added(repo, capsys)
    work(wt, "ticket.txt", "one")
    Path(wt, "README.md").write_text("dirty\n")

    refused_changing_nothing(repo, seed, capsys, "orch: ticket worktree %s is dirty - commit or"
                             " discard its changes first\n" % wt, env=env)
    assert Path(wt, "README.md").read_text() == "dirty\n"
    run_git(wt, "checkout", "-q", "--", "README.md")
    (repo / "README.md").write_text("dirty\n")

    refused_changing_nothing(repo, seed, capsys, "orch: %s, the checkout of %s, is dirty - commit"
                             " or discard its changes first\n" % (repo, PARENT), env=env)
    assert (repo / "README.md").read_text() == "dirty\n"


@SESSIONS
def test_merge_refuses_a_forked_from_branch_checked_out_nowhere(repo, seed, capsys, env):
    work(added(repo, capsys), "ticket.txt", "one")
    run_git(repo, "checkout", "-q", "--detach")

    refused_changing_nothing(repo, seed, capsys, "orch: %s, the branch %s was forked from, is"
                             " checked out nowhere - check it out first\n" % (PARENT, TICKET7),
                             env=env)


@SESSIONS
def test_merge_refuses_a_branch_recording_no_forked_from_branch(repo, seed, capsys, env):
    work(added(repo, capsys), "ticket.txt", "one")
    run_git(repo, "config", "--unset", "branch.%s.orchestrator-ticket-parent" % TICKET7)

    refused_changing_nothing(repo, seed, capsys,
                             "orch: branch %s records no forked-from branch\n" % TICKET7, env=env)


@SESSIONS
def test_merge_refuses_a_ticket_worktree_whose_directory_is_gone(repo, seed, capsys, env):
    wt = added(repo, capsys)
    work(wt, "ticket.txt", "one")
    shutil.rmtree(wt)

    refused_changing_nothing(repo, seed, capsys,
                             "orch: no ticket worktree for ticket 7 at %s\n" % wt, env=env)
    assert "\nworktree %s\n" % wt in "\n" + run_git(repo, "worktree", "list", "--porcelain")


@SESSIONS
def test_merge_dies_before_anything_moves_when_the_checkouts_cannot_be_read(repo, seed, capsys,
                                                                          monkeypatch, env):
    wt = added(repo, capsys)
    work(wt, "ticket.txt", "one")
    Path(wt, "dirty.txt").write_text("dirt\n")
    monkeypatch.setattr(Git, "worktree_list", lambda self: None)

    refused_changing_nothing(repo, seed, capsys,
                             "orch: could not read the checkouts - git worktree list failed\n",
                             env=env)


@pytest.mark.parametrize("argv, err", [
    ((), "orch: usage: orch.sh ticket merge <n>\n"),
    (("7", "8"), "orch: usage: orch.sh ticket merge <n>\n"),
    (("9",), "orch: no ticket worktree for ticket 9 at %s\n"),
    (("07",), "orch: not a ticket number: 07 (want a positive integer)\n"),
])
@SESSIONS
def test_merge_refuses_bad_arguments_and_a_ticket_with_no_worktree(repo, seed, capsys, argv, err,
                                                                   env):
    if "%s" in err:
        err %= str(repo / ".orchestrator" / "worktrees" / "t9")

    assert died_of(capsys, lambda: orch_ticket(seed, "merge", *argv, env=env)) == (1, "", err)


@SESSIONS
def test_merge_fast_forwards_a_parent_checked_out_in_a_linked_worktree(repo, seed, capsys,
                                                                       tmp_path, monkeypatch, env):
    linked = tmp_path.resolve() / "elsewhere" / "linked"
    run_git(repo, "worktree", "add", "-q", "-b", "orch/6-other", str(linked))
    monkeypatch.chdir(linked)
    work(added(linked, capsys, 4), "ticket.txt", "four")
    work(linked, "other.txt", "landed-first")

    assert orch_ticket(seed, "merge", "4", env=env) == 0

    assert run_git(linked, "rev-parse", "HEAD") == tip(repo, "orch/6-other--t4")
    assert subjects(linked, "HEAD", 2) == ["ticket.txt: four", "other.txt: landed-first"]
    assert (linked / "ticket.txt").read_text() == "four\n"
    assert run_git(repo, "branch", "--show-current") == PARENT


@SESSIONS
def test_merge_lands_the_branch_checked_out_leaving_the_ticket_s_own(repo, seed, capsys, env):
    switched(repo, capsys, 24)
    own_tip = tip(repo, PARENT + "--t24")

    assert orch_ticket(seed, "merge", "24", env=env) == 0

    assert tip(repo, PARENT) == tip(repo, "other-24")
    assert tip(repo, PARENT + "--t24") == own_tip


# --- ticket merge beside a same-named tag (#2337) ---------------------------------------


@SESSIONS
def test_merge_lands_on_the_parent_branch_never_a_tag_named_like_it(repo, seed, capsys, env):
    old = run_git(repo, "rev-parse", "HEAD~1")
    work(added(repo, capsys), "ticket.txt", "one")
    work(repo, "other.txt", "landed-first")
    run_git(repo, "tag", PARENT, old)
    flow_tip = tip(repo, PARENT)

    assert orch_ticket(seed, "merge", "7", env=env) == 0

    assert run_git(repo, "rev-parse", "refs/heads/%s~1" % TICKET7) == flow_tip


@SESSIONS
def test_merge_lands_the_ticket_branch_never_a_tag_named_like_it(repo, seed, capsys, env):
    old = run_git(repo, "rev-parse", "HEAD~1")
    work(added(repo, capsys), "ticket.txt", "one")
    run_git(repo, "tag", TICKET7, old)

    assert orch_ticket(seed, "merge", "7", env=env) == 0

    assert tip(repo, PARENT) == tip(repo, TICKET7)


# --- ticket reclaim (ADR-0054) ----------------------------------------------------------

SPEC = 90


def reclaim_setup(repo, seed, capsys, count):
    """A flow on PARENT for spec issue #90, active in implement, with
    .orchestrator/ git-excluded as a real flow's is, and <count> published
    tickets numbered 7 on, each with a ticket worktree holding one commit,
    t<k>.txt reading "work <k>"."""
    seed.issue(SPEC, "open")
    for k in range(7, 7 + count):
        seed.issue(k, "open")
        seed.sub_issue(SPEC, k)
        work(added(repo, capsys, k), "t%d.txt" % k, "work %d" % k)
    exclude_orch_dirs(Git())
    hold_flow(repo, phase="implement", branch=PARENT, issue=SPEC)


def report(repo, n):
    """Ticket <n>'s report saved where `ticket report save` keeps it."""
    reports = repo / ".orchestrator" / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    (reports / ("%s.md" % n)).write_text("Ticket: #%s\n" % n)


def reclaim(seed, env=None):
    """`ticket reclaim 90`: its exit code."""
    return orch_ticket(seed, "reclaim", str(SPEC), env=env)


def merged(seed, capsys, n):
    """Ticket <n> landed by `ticket merge`, its output drained."""
    assert orch_ticket(seed, "merge", str(n)) == 0
    capsys.readouterr()


def has_worktree(repo, n):
    return os.path.exists(wt_path(repo, n) + "/.git")


def removed(n, branch=True):
    """The lines a teardown of ticket <n>'s worktree, and its branch when
    <branch>, prints."""
    return "removed the worktree of ticket #%s\n" % n + (
        "deleted the branch of ticket #%s\n" % n if branch else "")


def test_a_reported_merged_ticket_is_closed_and_removed_and_a_rerun_does_nothing(
        repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 1)
    report(repo, 7)
    merged(seed, capsys, 7)

    assert reclaim(seed) == 0

    assert capsys.readouterr() == ("closed ticket #7\n" + removed(7), "")
    assert state_of(seed, 7) == "CLOSED"
    assert not has_worktree(repo, 7) and not has_branch(repo, TICKET7)
    assert reclaim(seed) == 0
    assert capsys.readouterr() == ("", "")


def test_a_reported_unmerged_dirty_ticket_is_reset_merged_closed_and_removed(repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 1)
    report(repo, 7)
    Path(wt_path(repo, 7), "untracked.txt").write_text("junk\n")
    Path(wt_path(repo, 7), "t7.txt").write_text("work 7\nmore\n")
    work(repo, "other.txt", "landed-first")

    assert reclaim(seed) == 0

    assert capsys.readouterr() == ("merged ticket #7\nclosed ticket #7\n" + removed(7), "")
    assert (repo / "t7.txt").read_text() == "work 7\n"
    assert subjects(repo, PARENT, 1) == ["t7.txt: work 7"]
    assert not has_worktree(repo, 7)


def conflicting(repo, n):
    """Ticket <n>'s worktree and PARENT each with a commit changing
    feature.txt's one line."""
    work(wt_path(repo, n), "feature.txt", "from-ticket")
    work(repo, "feature.txt", "from-flow")


CONFLICT = ("orch: rebasing %s onto %s hit a conflict - aborted; both branches are as they"
            " were\n" % (TICKET7, PARENT))


def test_a_conflict_exits_3_with_both_tips_kept_and_later_leftovers_untouched(repo, seed,
                                                                           capsys):
    reclaim_setup(repo, seed, capsys, 2)
    report(repo, 7)
    report(repo, 8)
    conflicting(repo, 7)
    before = tips(repo)

    assert died_of(capsys, lambda: reclaim(seed)) == (3, "conflict 7\n", CONFLICT)
    assert tips(repo) == before
    assert state_of(seed, 7) == "OPEN"
    assert (has_worktree(repo, 8), state_of(seed, 8)) == (True, "OPEN")


def test_a_reported_worktree_left_mid_rebase_is_reset_then_its_conflict_reported(repo, seed,
                                                                               capsys):
    reclaim_setup(repo, seed, capsys, 1)
    report(repo, 7)
    conflicting(repo, 7)
    with pytest.raises(Exception):  # noqa: B017 - the conflict is the point
        run_git(wt_path(repo, 7), "rebase", "-q", PARENT)

    assert died_of(capsys, lambda: reclaim(seed)) == (3, "conflict 7\n", CONFLICT)
    assert not rebasing(wt_path(repo, 7))


def test_unreported_worktrees_are_discarded_leaving_their_tickets_open(repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 2)
    Path(wt_path(repo, 8), "untracked.txt").write_text("junk\n")
    Path(wt_path(repo, 8), "t8.txt").write_text("work 8\nmore\n")

    assert reclaim(seed) == 0

    assert capsys.readouterr() == (removed(7) + "discarded ticket #7\n" + removed(8)
                                   + "discarded ticket #8\n", "")
    assert not any(has_worktree(repo, n) or has_branch(repo, "%s--t%s" % (PARENT, n))
                   for n in (7, 8))
    assert (state_of(seed, 7), state_of(seed, 8)) == ("OPEN", "OPEN")


def test_a_collapsed_breakdown_s_merged_ticket_is_removed_never_closing_the_spec(repo, seed,
                                                                               capsys):
    reclaim_setup(repo, seed, capsys, 0)
    work(added(repo, capsys, SPEC), "t90.txt", "work")
    report(repo, SPEC)
    merged(seed, capsys, SPEC)

    assert reclaim(seed) == 0

    assert capsys.readouterr() == ("ticket #90 already landed\n" + removed(SPEC), "")
    assert state_of(seed, SPEC) == "OPEN"
    assert not has_worktree(repo, SPEC)


def test_a_collapsed_ticket_already_landed_keeps_its_report_and_the_spec_open(repo, seed,
                                                                            capsys):
    reclaim_setup(repo, seed, capsys, 0)
    report(repo, SPEC)

    assert reclaim(seed) == 0

    assert capsys.readouterr() == ("ticket #90 already landed\n", "")
    assert (repo / ".orchestrator" / "reports" / "90.md").read_text() == "Ticket: #90\n"
    assert state_of(seed, SPEC) == "OPEN"


def test_a_failed_close_dies_naming_the_ticket_touching_no_later_leftover(repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 2)
    report(repo, 7)
    report(repo, 8)
    merged(seed, capsys, 7)
    seed.fail("adapter_issue_close", GH_502)

    assert died_of(capsys, lambda: reclaim(seed)) == (
        1, "", "orch: gh could not close ticket #7: HTTP 502: Bad Gateway\n")
    assert (has_worktree(repo, 8), state_of(seed, 8)) == (True, "OPEN")


def test_a_branch_left_with_no_worktree_is_deleted_and_only_the_branch_noted(repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 1)
    report(repo, 7)
    merged(seed, capsys, 7)
    run_git(repo, "worktree", "remove", "--force", wt_path(repo, 7))

    assert reclaim(seed) == 0

    assert capsys.readouterr() == ("closed ticket #7\ndeleted the branch of ticket #7\n", "")
    assert not has_branch(repo, TICKET7)


def test_a_worktree_on_another_branch_loses_the_ticket_s_own_branch(repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 1)
    run_git(wt_path(repo, 7), "checkout", "-q", "-b", "elsewhere")

    assert reclaim(seed) == 0

    assert capsys.readouterr() == (removed(7) + "discarded ticket #7\n", "")
    assert not has_worktree(repo, 7) and not has_branch(repo, TICKET7)
    assert has_branch(repo, "elsewhere")


def test_a_worktree_that_cannot_be_removed_dies_naming_the_ticket(repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 1)
    run_git(repo, "worktree", "lock", wt_path(repo, 7))

    code, out, err = died_of(capsys, lambda: reclaim(seed))

    assert (code, out) == (1, "")
    assert err.endswith("orch: could not remove ticket worktree %s\norch: ticket #7: could not"
                        " remove its worktree %s\n" % (wt_path(repo, 7), wt_path(repo, 7)))
    assert has_worktree(repo, 7)


def test_a_branch_delete_failing_after_the_worktree_went_dies_naming_the_branch(repo, seed,
                                                                             capsys, monkeypatch):
    reclaim_setup(repo, seed, capsys, 1)
    # Not a ref lock: the discard's reset writes the ticket branch's ref too.
    monkeypatch.setattr(Git, "branch_delete", lambda self, name: GitFailure(1, "error: no\n"))

    assert died_of(capsys, lambda: reclaim(seed)) == (
        1, removed(7, branch=False), "error: no\norch: could not delete branch %s\n"
        "orch: ticket #7: could not delete branch %s\n" % (TICKET7, TICKET7))
    assert (has_worktree(repo, 7), has_branch(repo, TICKET7)) == (False, True)
    assert (has_worktree(repo, 7), has_branch(repo, TICKET7)) == (False, True)


def test_a_branch_delete_failing_with_no_worktree_notes_no_worktree(repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 1)
    report(repo, 7)
    run_git(repo, "worktree", "remove", "--force", wt_path(repo, 7))
    lock_ref(repo, TICKET7)

    code, out, err = died_of(capsys, lambda: reclaim(seed))

    assert (code, out) == (1, "")
    assert err.endswith("orch: ticket #7: could not delete branch %s\n" % TICKET7)


def test_a_discard_failing_before_any_removal_gets_the_worktree_line(repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 1)
    wt = wt_path(repo, 7)
    # A git run holding the ticket worktree's index, so its reset cannot run.
    Path(run_git(wt, "rev-parse", "--absolute-git-dir"), "index.lock").write_text("")

    assert died_of(capsys, lambda: reclaim(seed)) == (
        1, "", "orch: ticket #7: git reset --hard failed in %s\norch: ticket #7: could not"
               " remove its worktree %s\n" % (wt, wt))
    assert (has_worktree(repo, 7), has_branch(repo, TICKET7)) == (True, True)


def test_a_plain_directory_at_the_recorded_path_is_refused_keeping_all_three(repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 1)
    wt = wt_path(repo, 7)
    shutil.rmtree(wt)
    os.mkdir(wt)

    code, out, err = died_of(capsys, lambda: reclaim(seed))

    assert (code, out) == (1, "")
    assert "delete it and run the command again" in err
    assert err.endswith("orch: ticket #7: could not remove its worktree %s\n" % wt)
    assert os.path.isdir(wt) and has_branch(repo, TICKET7)
    assert orch_tw("list") == 0
    assert capsys.readouterr().out == "7 %s\n" % wt


@pytest.mark.parametrize("landed, branch, printed", [
    (True, True, "closed ticket #7\n" + removed(7)),
    (True, False, "closed ticket #7\n" + removed(7, branch=False)),
    (False, True, removed(7) + "discarded ticket #7\n"),
    (False, False, removed(7, branch=False) + "discarded ticket #7\n"),
], ids=["merged-branch", "merged-nobranch", "unreported-branch", "unreported-nobranch"])
def test_a_leftover_whose_directory_is_gone_has_its_record_cleared(repo, seed, capsys, tmp_path,
                                                                  landed, branch, printed):
    reclaim_setup(repo, seed, capsys, 1)
    wt = wt_path(repo, 7)
    stale = str(tmp_path.resolve() / "stale")
    if landed:
        # Another record whose directory is gone, which is no leftover.
        run_git(repo, "worktree", "add", "-q", "-b", "rc-stale", stale)
        shutil.rmtree(stale)
        report(repo, 7)
        merged(seed, capsys, 7)
    if not branch:
        run_git(wt, "checkout", "-q", "--detach")
        run_git(repo, "branch", "-q", "-D", TICKET7)
    shutil.rmtree(wt)

    assert reclaim(seed) == 0

    assert capsys.readouterr() == (printed, "")
    assert orch_tw("list") == 0
    assert capsys.readouterr().out == ""
    assert not has_branch(repo, TICKET7)
    if landed:
        assert "worktree %s\n" % stale in run_git(repo, "worktree", "list", "--porcelain") + "\n"


def test_a_gone_record_that_cannot_be_removed_dies_with_the_worktree_line(repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 1)
    wt = wt_path(repo, 7)
    run_git(repo, "worktree", "lock", wt)
    shutil.rmtree(wt)

    code, out, err = died_of(capsys, lambda: reclaim(seed))

    assert (code, out) == (1, "")
    assert err.endswith("orch: ticket #7: could not remove its worktree %s\n" % wt)


def test_a_dirty_flow_branch_is_refused_in_a_plain_main_checkout_and_discarded_by_autopilot(
        repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 1)
    report(repo, 7)
    (repo / "README.md").write_text("# repo\nhand\n")

    code, out, err = died_of(capsys, lambda: reclaim(seed))

    assert (code, out) == (1, "")
    assert "reset --hard" in err
    assert (has_worktree(repo, 7), state_of(seed, 7)) == (True, "OPEN")
    assert run_git(repo, "status", "--porcelain") == "M README.md"
    assert reclaim(seed, env=AUTOPILOT) == 0
    assert run_git(repo, "status", "--porcelain") == ""
    assert (has_worktree(repo, 7), state_of(seed, 7)) == (False, "CLOSED")


def on_branch(repo, name, base=True):
    """<name> made and checked out, recording a base when <base>."""
    run_git(repo, "checkout", "-q", "-b", name)
    if base:
        run_git(repo, "config", "branch.%s.orchestrator-base" % name, "main")


ACTIVE = {"phase": "implement", "branch": PARENT, "issue": SPEC}
DONE = dict(ACTIVE, phase="done")


@pytest.mark.parametrize("state, branch, message", [
    (ACTIVE, ("stray", False), "the current branch stray is not the flow's branch %s" % PARENT),
    (dict(ACTIVE, issue=91), None, "on %s, #90 is not the flow's issue #91" % PARENT),
    ({"phase": "implement", "branch": PARENT}, None,
     "on %s, the active flow records no issue yet" % PARENT),
    ({"phase": "implement"}, None, "on %s, the active flow records no branch yet" % PARENT),
    ({"phase": "implement", "issue": SPEC}, None,
     "on %s, the active flow records no branch yet" % PARENT),
    (DONE, None, "no active flow, and %s is not a quick implementation's branch for #90" % PARENT),
    (DONE, ("quick/91-other", True), "is not a quick implementation's branch for #90"),
    (DONE, ("quick/90-thing", False), "is not a quick implementation's branch for #90"),
    (DONE, ("quick/090-padded", True), "is not a quick implementation's branch for #90"),
    (DONE, ("quick/90-", True), "is not a quick implementation's branch for #90"),
], ids=["another-branch", "another-issue", "no-issue", "neither", "no-branch", "no-flow",
        "quick-for-another", "quick-no-base", "quick-padded", "quick-empty-slug"])
def test_the_guard_refuses_any_branch_but_the_run_s_own_discarding_nothing(repo, seed, capsys,
                                                                        state, branch, message):
    reclaim_setup(repo, seed, capsys, 1)
    (repo / "README.md").write_text("# repo\nhand\n")
    hold_flow(repo, **state)
    if branch:
        on_branch(repo, *branch)

    code, out, err = died_of(capsys, lambda: reclaim(seed, env=AUTOPILOT))

    assert (code, out) == (1, "")
    assert message in err and err.endswith(" - nothing was discarded\n")
    assert run_git(repo, "status", "--porcelain") == "M README.md"
    assert (has_worktree(repo, 7), state_of(seed, 7)) == (True, "OPEN")


@pytest.mark.parametrize("name", ["quick/90-thing", "quick/90-6-x"])
def test_with_no_flow_an_owned_quick_branch_is_reclaimed(repo, seed, capsys, name):
    reclaim_setup(repo, seed, capsys, 1)
    (repo / "README.md").write_text("# repo\nhand\n")
    hold_flow(repo, **DONE)
    on_branch(repo, name)

    assert reclaim(seed, env=AUTOPILOT) == 0

    assert run_git(repo, "status", "--porcelain") == ""
    assert (has_worktree(repo, 7), state_of(seed, 7)) == (False, "OPEN")


def test_a_state_file_that_cannot_be_read_is_refused_discarding_nothing(repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 1)
    state_json(repo).write_text('{"phase":')

    assert died_of(capsys, lambda: reclaim(seed)) == (
        1, "", "orch: state.json cannot be read - run orch.sh doctor --flow\n")
    assert has_worktree(repo, 7)


@pytest.mark.parametrize("argv, err", [
    ((), "orch: usage: orch.sh ticket reclaim <parent>\n"),
    (("90", "91"), "orch: usage: orch.sh ticket reclaim <parent>\n"),
    (("abc",), "orch: parent must be a plain issue number, got: abc\n"),
])
def test_reclaim_refuses_bad_arguments(repo, seed, capsys, argv, err):
    assert died_of(capsys, lambda: orch_ticket(seed, "reclaim", *argv)) == (1, "", err)


def test_reclaim_refuses_a_detached_checkout(repo, seed, capsys):
    reclaim_setup(repo, seed, capsys, 1)
    run_git(repo, "checkout", "-q", "--detach")

    assert died_of(capsys, lambda: reclaim(seed)) == (
        1, "", "orch: the current checkout is on no branch - nothing to reclaim onto\n")
    assert has_worktree(repo, 7)
