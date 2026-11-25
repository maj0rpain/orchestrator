"""The checkout concept module's scan, holdings, ticket-worktree refusal and
busy-checkout refusal, against real repositories under tmp_path: git's
worktree semantics are git's, so no fake models them. Each failure message
is bash checkout.sh's or ticket-worktree.sh's, verbatim."""
from __future__ import annotations

import shutil

import pytest

from conftest import (
    committed,
    died_of,
    git_repo,
    hold_flow,
    mark_side,
    run_git,
    worktree_add,
)
from orch.checkout import (
    Checkout,
    checkout_gitdir_into,
    checkout_holding,
    checkouts,
    checkouts_or_die,
    refuse_busy_checkout,
    refuse_ticket_worktrees,
    ticket_worktrees_under,
)
from orch.git import Git

UNREADABLE = "orch: could not read the checkouts - git worktree list failed\n"
ENV = {"CLAUDECODE": "1"}


@pytest.fixture
def main(tmp_path):
    """A repository with one commit on orch/1-feature: its root, resolved."""
    root = tmp_path.resolve() / "main"
    git_repo(root)
    committed(root, {"a.txt": "a\n"}, "first")
    run_git(root, "checkout", "-qb", "orch/1-feature")
    return root


@pytest.fixture
def walked(main, tmp_path):
    """<main> with every kind of checkout beside it: (main, its checkouts by
    name)."""
    worktrees = main / ".orchestrator" / "worktrees"
    side = worktree_add(main, main / ".orchestrator" / "checkouts" / "alpha", "-b", "side-branch")
    mark_side(side)
    made = {
        "side": side,
        "t7": worktree_add(main, worktrees / "t7", "-b", "orch/1-feature--t7"),
        "t3": worktree_add(main, side / ".orchestrator" / "worktrees" / "t3",
                           "-b", "side-branch--t3"),
        "t8": worktree_add(main, worktrees / "t8", "-b", "orch/1-feature--t8"),
        "spaced": worktree_add(main, tmp_path.resolve() / "hand made", "-b", "spaced"),
        "hand": worktree_add(main, tmp_path.resolve() / "hand", "-b", "handmade"),
        "flowed": worktree_add(main, tmp_path.resolve() / "flowed", "-b", "flowed"),
        "detached": worktree_add(main, tmp_path.resolve() / "detached", "--detach"),
        "gone": worktree_add(main, tmp_path.resolve() / "gone", "-b", "gone"),
    }
    for name in ("t0", "t01", "tfoo", "t9"):
        made[name] = worktree_add(main, worktrees / name, "--detach")
    mark_side(made["t9"])
    for name in ("t8", "gone"):
        shutil.rmtree(str(made[name]))
    hold_flow(made["flowed"])
    return main, made


def by_path(scan):
    return sorted(scan, key=lambda checkout: checkout.path)


def test_the_scan_classifies_every_checkout_the_main_checkout_first(walked):
    main, made = walked
    p = {name: str(path) for name, path in made.items()}

    scan = checkouts(Git(cwd=str(made["side"])))

    assert scan[0] == Checkout("main", False, "orch/1-feature", str(main))
    assert by_path(scan[1:]) == by_path([
        Checkout("side", False, "side-branch", p["side"]),
        Checkout("ticket", False, "orch/1-feature--t7", p["t7"]),
        Checkout("ticket", False, "side-branch--t3", p["t3"]),
        Checkout("ticket", False, "orch/1-feature--t8", p["t8"]),
        Checkout("hand-made", False, "spaced", p["spaced"]),
        Checkout("hand-made", False, "handmade", p["hand"]),
        Checkout("hand-made", True, "flowed", p["flowed"]),
        Checkout("hand-made", False, None, p["detached"]),
        Checkout("hand-made", False, "gone", p["gone"]),
        Checkout("hand-made", False, None, p["t0"]),
        Checkout("hand-made", False, None, p["t01"]),
        Checkout("hand-made", False, None, p["tfoo"]),
        Checkout("ticket", False, None, p["t9"]),
    ])


def test_checkouts_or_die_gives_the_scan(walked):
    main, _ = walked

    assert checkouts_or_die(Git(cwd=str(main))) == checkouts(Git(cwd=str(main)))


def test_the_scan_outside_a_repository_fails_and_checkouts_or_die_names_it(tmp_path, capsys):
    git = Git(cwd=str(tmp_path))

    assert checkouts(git) is None
    assert died_of(capsys, lambda: checkouts_or_die(git)) == (1, "", UNREADABLE)


# --- the git folder -------------------------------------------------------------


def test_a_main_checkout_s_git_folder_is_its_dot_git(main, tmp_path):
    assert checkout_gitdir_into(Git(cwd=str(tmp_path)), str(main)) == str(main / ".git")


def test_a_linked_worktree_s_git_folder_is_the_one_its_pointer_names(main, tmp_path):
    wt = worktree_add(main, tmp_path.resolve() / "wt", "-b", "wt")

    assert checkout_gitdir_into(Git(cwd=str(tmp_path)), str(wt)) == \
        str(main / ".git" / "worktrees" / "wt")


def test_a_relative_pointer_is_read_from_the_worktree_its_dots_resolved(main, tmp_path):
    wt = worktree_add(main, tmp_path.resolve() / "wt", "-b", "wt")
    (wt / ".git").write_text("gitdir: ../main/./.git/worktrees/wt\n")

    assert checkout_gitdir_into(None, str(wt)) == str(main / ".git" / "worktrees" / "wt")


def test_an_unterminated_pointer_line_is_read(main, tmp_path):
    wt = worktree_add(main, tmp_path.resolve() / "wt", "-b", "wt")
    gitdir = str(main / ".git" / "worktrees" / "wt")
    (wt / ".git").write_text("gitdir: " + gitdir)

    assert checkout_gitdir_into(None, str(wt)) == gitdir


def test_a_pointer_naming_no_git_folder_asks_git(main, tmp_path):
    wt = worktree_add(main, tmp_path.resolve() / "wt", "-b", "wt")
    sub = wt / "sub"
    sub.mkdir()

    assert checkout_gitdir_into(Git(cwd=str(tmp_path)), str(sub)) == \
        str(main / ".git" / "worktrees" / "wt")


def test_a_path_in_no_checkout_has_no_git_folder(tmp_path):
    assert checkout_gitdir_into(Git(cwd=str(tmp_path)), str(tmp_path)) is None


# --- what a checkout holds --------------------------------------------------------


def test_a_checkout_holding_a_flow_names_its_slug_phase_and_issue(main):
    hold_flow(main, slug="foo", phase="implement", issue=12)

    assert checkout_holding(Git(cwd=str(main)), str(main)) == "flow foo implement #12"


def test_a_flow_with_no_issue_says_so(main):
    hold_flow(main, slug="foo", phase="spec", issue=None)

    assert checkout_holding(Git(cwd=str(main)), str(main)) == "flow foo spec (no issue)"


def test_a_flow_whose_state_cannot_be_read_says_so(main):
    hold_flow(main)
    (main / ".orchestrator" / "state.json").write_text("{not json\n")

    assert checkout_holding(Git(cwd=str(main)), str(main)) == \
        "flow (state.json cannot be read)"


def test_a_checkout_with_no_flow_names_its_branch_or_none(main):
    git = Git(cwd=str(main))
    holding = checkout_holding(git, str(main))
    run_git(main, "checkout", "-q", "--detach")

    assert (holding, checkout_holding(git, str(main))) == \
        ("branch orch/1-feature", "(no branch)")


# --- the ticket-worktree refusal ----------------------------------------------------


@pytest.fixture
def ticketed(main, tmp_path):
    """<main> with ticket worktrees t4 and t12 under it, a hand-made t0, and
    a side checkout's own t5: (main, side)."""
    worktrees = main / ".orchestrator" / "worktrees"
    worktree_add(main, worktrees / "t12", "-b", "orch/1-feature--t12")
    worktree_add(main, worktrees / "t4", "-b", "orch/1-feature--t4")
    worktree_add(main, worktrees / "t0", "--detach")
    side = worktree_add(main, tmp_path.resolve() / "side", "-b", "side")
    worktree_add(main, side / ".orchestrator" / "worktrees" / "t5", "-b", "side--t5")
    return main, side


def test_the_ticket_worktrees_under_a_checkout_are_its_own(ticketed):
    main, side = ticketed
    worktrees = str(main / ".orchestrator" / "worktrees")

    assert sorted(ticket_worktrees_under(Git(cwd=str(main)), str(main))) == [
        ("12", worktrees + "/t12"), ("4", worktrees + "/t4")]


def test_the_ticket_worktree_refusal_names_each_left_and_its_remove_command(ticketed, capsys):
    main, _ = ticketed
    worktrees = str(main / ".orchestrator" / "worktrees")

    code, out, err = died_of(capsys, lambda: refuse_ticket_worktrees(
        Git(cwd=str(main)), str(main), "a redo would strand their unmerged ticket work"))

    assert (code, out) == (1, "")
    assert err == (
        "orch: ticket worktrees are left under %s - a redo would strand their unmerged"
        " ticket work:\n"
        "       %s/t12 (orch.sh ticket-worktree remove 12)\n"
        "       %s/t4 (orch.sh ticket-worktree remove 4)\n"
        "     Remove each with orch.sh ticket-worktree remove <n> first.\n"
        % (main, worktrees, worktrees))


def test_no_ticket_worktree_left_is_no_refusal(main):
    assert refuse_ticket_worktrees(Git(cwd=str(main)), str(main), "why") is None


def test_the_ticket_worktree_refusal_dies_when_the_checkouts_cannot_be_read(tmp_path, capsys):
    assert died_of(capsys, lambda: refuse_ticket_worktrees(
        Git(cwd=str(tmp_path)), str(tmp_path), "why")) == (1, "", UNREADABLE)


# --- the busy-checkout refusal --------------------------------------------------------


def refused(capsys, main, *signals):
    return died_of(capsys, lambda: refuse_busy_checkout(
        Git(cwd=str(main)), str(main), ENV, *signals))


def test_a_flow_mid_pipeline_is_busy_exit_3(main, capsys):
    hold_flow(main, slug="foo", phase="implement")

    assert refused(capsys, main, "flow", "branch") == (3, "", (
        "orch: busy: a flow is mid-pipeline (slug: foo, phase: implement)\n"
        "     One flow at a time - finish it, or run /orchestrator:abort.\n"))


def test_a_flow_whose_state_cannot_be_read_is_busy_exit_3(main, capsys):
    hold_flow(main)
    (main / ".orchestrator" / "state.json").write_text("[]\n")

    assert refused(capsys, main, "flow") == (3, "", (
        "orch: busy: a flow's state.json cannot be read\n"
        "     Run orch.sh doctor --flow, or /orchestrator:abort.\n"))


def test_a_done_flow_is_no_refusal(main):
    hold_flow(main, slug="foo", phase="done")

    assert refuse_busy_checkout(Git(cwd=str(main)), str(main), ENV, "flow", "branch") is None


def test_a_plugin_made_branch_with_no_pr_is_busy_exit_3(main, capsys):
    run_git(main, "config", "branch.orch/1-feature.orchestrator-base", "main")

    assert refused(capsys, main, "flow", "branch") == (3, "", (
        "orch: busy: branch orch/1-feature has no PR yet\n"
        "     Open its PR, or switch off it.\n"))


@pytest.mark.parametrize("key, value", [
    ("orchestrator-pr", "41"),
    ("orchestrator-retired", "true"),
    ("orchestrator-ticket-parent", "orch/1-main"),
], ids=["with-a-pr", "retired-by-a-redo", "ticket-branch"])
def test_a_plugin_made_branch_with_a_pr_retired_or_a_ticket_s_is_no_refusal(main, key, value):
    run_git(main, "config", "branch.orch/1-feature.orchestrator-base", "main")
    run_git(main, "config", "branch.orch/1-feature." + key, value)

    assert refuse_busy_checkout(Git(cwd=str(main)), str(main), ENV, "flow", "branch") is None


def test_a_foreign_branch_or_detached_head_is_no_refusal(main):
    git = Git(cwd=str(main))
    foreign = refuse_busy_checkout(git, str(main), ENV, "flow", "branch")
    run_git(main, "checkout", "-q", "--detach")

    assert (foreign, refuse_busy_checkout(git, str(main), ENV, "flow", "branch")) == \
        (None, None)


def test_only_the_signals_named_are_checked(main):
    hold_flow(main, slug="foo", phase="implement")
    run_git(main, "config", "branch.orch/1-feature.orchestrator-base", "main")

    assert refuse_busy_checkout(Git(cwd=str(main)), str(main), ENV) is None


def test_the_flow_signal_is_reported_before_the_branch_signal(main, capsys):
    hold_flow(main, slug="foo", phase="review")
    run_git(main, "config", "branch.orch/1-feature.orchestrator-base", "main")

    assert refused(capsys, main, "branch", "flow")[2].startswith(
        "orch: busy: a flow is mid-pipeline (slug: foo, phase: review)\n")


def test_a_busy_and_dirty_checkout_is_refused_busy_exit_3(main, capsys):
    run_git(main, "config", "branch.orch/1-feature.orchestrator-base", "main")
    (main / "a.txt").write_text("edited\n")
    (main / "stray.py").write_text("x\n")

    assert refused(capsys, main, "flow", "branch") == (3, "", (
        "orch: busy: branch orch/1-feature has no PR yet\n"
        "     Open its PR, or switch off it.\n"))


def test_an_unknown_signal_is_a_programming_error(main):
    with pytest.raises(ValueError, match="tree"):
        refuse_busy_checkout(Git(cwd=str(main)), str(main), ENV, "tree")
