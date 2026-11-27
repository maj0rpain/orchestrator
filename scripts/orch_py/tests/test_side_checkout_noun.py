"""`orch.sh side-checkout list|issue|remove` and the noun's dispatch, called
in-process through the side-checkout module's run against real repositories
under tmp_path: a side checkout is a git worktree and its marker lives in its
git folder, git's own semantics, which a fake would only restate. Each
message, exit code and order of checks is the bash noun's, verbatim. add and
prune through run are test_side_checkout_add_prune.py's."""
from __future__ import annotations

import os

import pytest

from conftest import (ARCHIVE_STAMP, archive_clock, archive_main, archived, done_flow, has_branch,
                      hold_flow, mark_side, run_git, side_checkout, worktree_add)
from orch import side_checkout as module
from orch.git import FakeGit, Git


@pytest.fixture
def main(tmp_path):
    return archive_main(tmp_path)


def orch(capsys, monkeypatch, cwd, *argv, git=None):
    """`orch.sh side-checkout <argv>` run from <cwd> through the real git
    adapter there (or <git>), no gh adapter, at archive_clock's time: (exit
    code, stdout, stderr)."""
    monkeypatch.chdir(str(cwd))
    try:
        code = module.run(list(argv), git=Git(cwd=str(cwd)) if git is None else git, env={},
                          clock=archive_clock)
    except SystemExit as died:
        code = died.code
    out, err = capsys.readouterr()
    return code, out, err


def listed_order(main):
    """The worktree paths git lists, in its order."""
    return [line[len("worktree "):] for line in
            run_git(main, "worktree", "list", "--porcelain").split("\n")
            if line.startswith("worktree ")]


# --- list ----------------------------------------------------------------------


def test_list_prints_each_side_checkout_in_git_s_order_with_what_it_holds(
        capsys, monkeypatch, main, tmp_path):
    alpha = side_checkout(main, "alpha")
    beta = side_checkout(main, "beta")
    mark_side(beta, "12\n")
    gamma = side_checkout(main, "gamma")
    hold_flow(gamma, slug="gamma-flow", phase="spec", issue=7)
    hand = worktree_add(main, tmp_path.resolve() / "hand", "-b", "hand")
    hold_flow(hand, slug="hand-flow", phase="spec")
    ticket = worktree_add(main, main / ".orchestrator" / "worktrees" / "t4", "-b", "main--t4")
    mark_side(ticket, "4\n")
    rows = {str(alpha): "alpha %s branch alpha\n" % alpha,
            str(beta): "beta %s branch beta quick #12\n" % beta,
            str(gamma): "gamma %s flow gamma-flow spec #7\n" % gamma}

    assert orch(capsys, monkeypatch, main, "list") == (
        0, "".join(rows[path] for path in listed_order(main) if path in rows), "")


def test_list_from_a_side_checkout_prints_the_same(capsys, monkeypatch, main):
    alpha = side_checkout(main, "alpha")
    mark_side(alpha, "5\n")

    assert orch(capsys, monkeypatch, alpha, "list") == (
        0, "alpha %s branch alpha quick #5\n" % alpha, "")


@pytest.mark.parametrize("content", ["", "4x\n", "41\n42\n", "41\0"],
                         ids=["empty", "not-plain", "multi-line", "nul"])
def test_list_appends_no_issue_for_a_marker_recording_none(capsys, monkeypatch, main, content):
    alpha = side_checkout(main, "alpha")
    mark_side(alpha, content)

    assert orch(capsys, monkeypatch, main, "list") == (0, "alpha %s branch alpha\n" % alpha, "")


def test_list_takes_no_arguments(capsys, monkeypatch, main):
    side_checkout(main, "alpha")

    assert orch(capsys, monkeypatch, main, "list", "extra") == (
        1, "", "orch: usage: orch.sh side-checkout list\n")


def test_list_dies_when_the_checkouts_cannot_be_read(capsys, monkeypatch, main):
    git = FakeGit(toplevel=str(main))
    git.seed("worktree_list", answer=None)

    assert orch(capsys, monkeypatch, main, "list", git=git) == (
        1, "", "orch: could not read the checkouts - git worktree list failed\n")


# --- issue ---------------------------------------------------------------------


@pytest.mark.parametrize("content,printed", [
    ("123\n", "123\n"),
    ("123", "123\n"),
    ("123\n\n\n", "123\n"),
], ids=["line", "no-newline", "trailing-newlines"])
def test_issue_prints_the_issue_the_side_checkout_s_marker_records(
        capsys, monkeypatch, main, content, printed):
    alpha = side_checkout(main, "alpha")
    mark_side(alpha, content)

    assert orch(capsys, monkeypatch, alpha, "issue") == (0, printed, "")


def test_issue_from_a_folder_inside_the_side_checkout_prints_it_too(capsys, monkeypatch, main):
    alpha = side_checkout(main, "alpha")
    mark_side(alpha, "123\n")
    (alpha / "sub").mkdir()

    assert orch(capsys, monkeypatch, alpha / "sub", "issue") == (0, "123\n", "")


@pytest.mark.parametrize("content", ["", "4x\n", "41\n42\n", "41\0", "#5\n"],
                         ids=["empty", "not-plain", "multi-line", "nul", "hash"])
def test_issue_exits_1_printing_nothing_for_a_marker_recording_no_plain_number(
        capsys, monkeypatch, main, content):
    alpha = side_checkout(main, "alpha")
    mark_side(alpha, content)

    assert orch(capsys, monkeypatch, alpha, "issue") == (1, "", "")


def test_issue_exits_1_printing_nothing_in_a_worktree_with_no_marker(
        capsys, monkeypatch, main, tmp_path):
    alpha = side_checkout(main, "alpha")
    mark_side(alpha).unlink()

    assert orch(capsys, monkeypatch, alpha, "issue") == (1, "", "")


def test_issue_exits_1_printing_nothing_in_the_main_checkout(capsys, monkeypatch, main):
    mark_side(main, "123\n")

    assert orch(capsys, monkeypatch, main, "issue") == (1, "", "")


def test_issue_exits_1_in_a_ticket_worktree_carrying_a_copied_marker(capsys, monkeypatch, main):
    ticket = worktree_add(main, main / ".orchestrator" / "worktrees" / "t41", "-b", "main--t41")
    mark_side(ticket, "123\n")

    assert orch(capsys, monkeypatch, ticket, "issue") == (1, "", "")


@pytest.mark.parametrize("where", ["side", "main"])
def test_issue_refuses_any_argument_with_exit_2_before_judging_the_checkout(
        capsys, monkeypatch, main, where):
    alpha = side_checkout(main, "alpha")
    mark_side(alpha, "123\n")

    assert orch(capsys, monkeypatch, alpha if where == "side" else main, "issue", "extra") == (
        2, "", "orch: usage: orch.sh side-checkout issue\n")


# --- remove --------------------------------------------------------------------

REMOVE_USAGE = "orch: usage: orch.sh side-checkout remove <slug>\n"


def test_remove_archives_the_flow_into_the_main_checkout_removes_the_worktree_and_keeps_the_branch(
        capsys, monkeypatch, main):
    alpha = side_checkout(main, "alpha")
    done_flow(alpha, "alpha-flow")

    assert orch(capsys, monkeypatch, main, "remove", "alpha") == (0, (
        ".orchestrator/archive/%s-alpha-flow\nremoved side checkout %s\n" % (ARCHIVE_STAMP, alpha)),
        "")
    assert sorted(os.listdir(archived(main, "alpha-flow"))) == ["handoff", "state.json"]
    assert not alpha.exists()
    assert str(alpha) not in run_git(main, "worktree", "list")
    assert has_branch(main, "alpha")


def test_remove_normalises_the_slug_as_add_does(capsys, monkeypatch, main):
    side = side_checkout(main, "alpha-one")

    assert orch(capsys, monkeypatch, main, "remove", "Alpha One") == (
        0, "removed side checkout %s\n" % side, "")
    assert not side.exists()


def test_remove_from_inside_the_side_checkout_says_to_close_the_session(capsys, monkeypatch, main):
    alpha = side_checkout(main, "alpha")
    done_flow(alpha, "alpha-flow")

    assert orch(capsys, monkeypatch, alpha, "remove", "alpha") == (0, (
        "%s\nremoved side checkout %s\nThis session's working directory was that side checkout,"
        " and it is gone - close this session.\n" % (archived(main, "alpha-flow"), alpha)), "")


@pytest.mark.parametrize("argv", [(), ("alpha", "extra"), ("nosuch", "extra")],
                         ids=["no-slug", "two", "unknown-and-extra"])
def test_remove_wants_exactly_one_slug(capsys, monkeypatch, main, argv):
    alpha = side_checkout(main, "alpha")

    assert orch(capsys, monkeypatch, main, "remove", *argv) == (1, "", REMOVE_USAGE)
    assert alpha.exists()


def unreadable_checkouts(main):
    git = FakeGit(toplevel=str(main))
    git.seed("main_checkout", answer=None)
    return git


def test_remove_dies_when_the_main_checkout_cannot_be_read_before_judging_the_slug(
        capsys, monkeypatch, main):
    assert orch(capsys, monkeypatch, main, "remove", "nosuch", git=unreadable_checkouts(main)) == (
        1, "", "orch: could not read the checkouts - git worktree list failed\n")


def test_remove_s_usage_comes_before_the_main_checkout_read(capsys, monkeypatch, main):
    assert orch(capsys, monkeypatch, main, "remove", git=unreadable_checkouts(main)) == (
        1, "", REMOVE_USAGE)


@pytest.mark.parametrize("make", ["absent", "directory"])
def test_remove_refuses_an_unknown_slug(capsys, monkeypatch, main, make):
    path = main / ".orchestrator" / "checkouts" / "nosuch"
    if make == "directory":
        path.mkdir(parents=True)

    assert orch(capsys, monkeypatch, main, "remove", "nosuch") == (
        1, "", "orch: no side checkout nosuch at %s\n" % path)


def test_remove_refuses_an_unmarked_worktree_even_a_dirty_one_moving_nothing(
        capsys, monkeypatch, main):
    unmarked = worktree_add(main, main / ".orchestrator" / "checkouts" / "unmarked", "--detach")
    done_flow(unmarked, "unmarked-flow")
    (unmarked / "wip.txt").write_text("wip\n")

    assert orch(capsys, monkeypatch, main, "remove", "unmarked") == (1, "", (
        "orch: %s carries no side-checkout marker - it is not the plugin's to remove, so it is"
        " left alone\n" % unmarked))
    assert (unmarked / ".orchestrator" / "state.json").is_file()
    assert not (main / ".orchestrator" / "archive").exists()


DIRTY = ("orch: side checkout %s has uncommitted changes or untracked files - commit or discard"
         " them first; it is never removed with force\n")


@pytest.mark.parametrize("dirt", ["untracked", "modified"])
def test_remove_refuses_a_dirty_side_checkout_moving_nothing(capsys, monkeypatch, main, dirt):
    alpha = side_checkout(main, "alpha")
    done_flow(alpha, "alpha-flow")
    if dirt == "untracked":
        (alpha / "wip.txt").write_text("wip\n")
    else:
        (alpha / "a.txt").write_text("changed\n")

    assert orch(capsys, monkeypatch, main, "remove", "alpha") == (1, "", DIRTY % alpha)
    assert (alpha / ".orchestrator" / "state.json").is_file()
    assert not (main / ".orchestrator" / "archive").exists()


def ticket_left(side, n):
    return worktree_add(side, side / ".orchestrator" / "worktrees" / ("t%d" % n),
                        "-b", "alpha--t%d" % n)


def test_remove_refuses_a_dirty_side_checkout_before_its_ticket_worktrees(
        capsys, monkeypatch, main):
    alpha = side_checkout(main, "alpha")
    ticket_left(alpha, 6)
    (alpha / "wip.txt").write_text("wip\n")

    assert orch(capsys, monkeypatch, main, "remove", "alpha") == (1, "", DIRTY % alpha)


def ticket_refusal(side, n, ticket):
    return ("orch: ticket worktrees are left under %s - moving them would break git's record of"
            " them:\n       %s (orch.sh ticket-worktree remove %d)\n"
            "     Remove each with orch.sh ticket-worktree remove <n> first.\n" % (side, ticket, n))


@pytest.mark.parametrize("flow", [False, True], ids=["no-flow", "flow"])
def test_remove_refuses_while_ticket_worktrees_are_left_moving_nothing(
        capsys, monkeypatch, main, flow):
    alpha = side_checkout(main, "alpha")
    if flow:
        done_flow(alpha, "alpha-flow")
    ticket = ticket_left(alpha, 7)

    assert orch(capsys, monkeypatch, main, "remove", "alpha") == (
        1, "", ticket_refusal(alpha, 7, ticket))
    assert alpha.exists() and ticket.exists()
    assert (alpha / ".orchestrator" / "state.json").is_file() == flow
    assert not (main / ".orchestrator" / "archive").exists()
    assert has_branch(main, "alpha")


def test_remove_whose_archive_fails_removes_nothing_and_relays_the_error_with_one_prefix(
        capsys, monkeypatch, main):
    alpha = side_checkout(main, "alpha")
    done_flow(alpha, "alpha-flow")
    (main / ".orchestrator").mkdir(exist_ok=True)
    (main / ".orchestrator" / "archive").write_text("")

    assert orch(capsys, monkeypatch, main, "remove", "alpha") == (1, "", (
        "orch: could not create the archive directory %s - nothing was archived\n"
        % archived(main, "alpha-flow")))
    assert (alpha / ".orchestrator" / "state.json").is_file()


def test_remove_whose_worktree_removal_fails_keeps_the_archive_worktree_and_branch(
        capsys, monkeypatch, main):
    alpha = side_checkout(main, "alpha")
    done_flow(alpha, "alpha-flow")
    run_git(main, "worktree", "lock", str(alpha))

    code, out, err = orch(capsys, monkeypatch, main, "remove", "alpha")
    assert (code, out) == (1, ".orchestrator/archive/%s-alpha-flow\n" % ARCHIVE_STAMP)
    assert err.startswith("orch: could not remove side checkout %s: " % alpha)
    assert err.endswith(" - left as it stands. Commit or discard its changes, then run orch.sh"
                        " side-checkout remove alpha.\n")
    assert (archived(main, "alpha-flow") / "state.json").is_file()
    assert alpha.exists() and has_branch(main, "alpha")


# --- the dispatch ----------------------------------------------------------------


@pytest.mark.parametrize("argv,op", [((), "<none>"), (("bogus",), "bogus")])
def test_an_unknown_op_is_refused_naming_the_ops(capsys, monkeypatch, main, argv, op):
    assert orch(capsys, monkeypatch, main, *argv) == (1, "", (
        "orch: unknown side-checkout op: %s (want add|list|remove|prune|issue)\n" % op))
