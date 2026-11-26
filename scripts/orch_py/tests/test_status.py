"""The status noun: the flow lines of the checkout's own flow, the "No active
flow" line naming the host's start command, and the listing of every other
checkout holding a flow and every side checkout. The flow lines run
in-process against FakeGit and the gh fake; the listing against real
repositories under tmp_path, since git's worktree semantics are git's. Every
expected text is a literal of bash cmd_status's output, byte for byte."""
from __future__ import annotations

import pytest

from conftest import (
    committed,
    died_of,
    git_repo,
    hold_flow,
    mark_side,
    orch_files,
    run_git,
    worktree_add,
)
from orch import status
from orch.gh_fake import FakeGh
from orch.git import FakeGit, Git, Worktree
from orch.repo import RepoPin

ORIGIN = {"origin": "https://github.com/acme/widgets.git"}
CLAUDE = {"CLAUDECODE": "1"}


def alone(root):
    """A FakeGit at <root>, the clone's only checkout, on orch/42-my-feature,
    its origin a GitHub repo."""
    git = FakeGit(ORIGIN, toplevel=str(root))
    git.seed("worktree_list", answer=[Worktree(str(root), "orch/42-my-feature")])
    return git


def orch_status(seed, git, env=CLAUDE):
    """`orch.sh status` in-process on the gh fake over <seed>'s store: its
    exit code."""
    pin = RepoPin(env, git)
    gh = FakeGh(seed.store, env, pin=pin, sleep=lambda _: None)
    return status.run([], gh=gh, git=git, env=env, pin=pin)


def test_status_prints_every_flow_line_a_flow_records(root, seed, capsys):
    hold_flow(root, slug="my-feature", phase="implement", issue=42, base="develop",
              branch="orch/42-my-feature", pr=7, budget=3, iteration=2, redo_count=1)
    orch_files(root, "handoff", "02-spec.md", "01-plan.md")

    assert orch_status(seed, alone(root)) == 0
    assert capsys.readouterr() == (
        "flow:      my-feature\n"
        "phase:     implement\n"
        "issue:     42\n"
        "base:      develop\n"
        "branch:    orch/42-my-feature\n"
        "PR:        7\n"
        "review:    iteration 2 of 3\n"
        "redo:      1\n"
        "\n"
        "handoffs:\n"
        "  .orchestrator/handoff/01-plan.md\n"
        "  .orchestrator/handoff/02-spec.md\n", "")


@pytest.mark.parametrize("budget", [{}, {"budget": None}, {"budget": "five"}],
                         ids=["missing", "null", "not-a-number"])
def test_a_flow_with_no_base_or_budget_reads_the_default_branch_and_budget(
        root, seed, capsys, budget):
    """A flow started before base and budget were recorded: base falls back
    to the default branch GitHub names, the budget to 5; an empty issue,
    branch and PR read as -, and a flow with no handoff says so."""
    seed.default_branch("trunk")
    git = alone(root)
    git.seed("is_branch_name", "trunk", answer=True)
    hold_flow(root, slug="legacy", phase="spec", issue=None, branch=None, pr=None,
              iteration=0, redo_count=0, **budget)

    assert orch_status(seed, git) == 0
    assert capsys.readouterr() == (
        "flow:      legacy\n"
        "phase:     spec\n"
        "issue:     -\n"
        "base:      trunk\n"
        "branch:    -\n"
        "PR:        -\n"
        "review:    iteration 0 of 5\n"
        "redo:      0\n"
        "\n"
        "handoffs:\n"
        "  (none yet)\n", "")


@pytest.mark.parametrize("env, start", [
    (CLAUDE, "/orchestrator:start"),
    ({"JUNIE_EXTENSION_ROOT": "/junie"},
     "/orchestrator:start (or orch-flow's Starting a flow section)"),
], ids=["claude", "junie"])
def test_with_no_flow_status_names_the_host_s_start_command(root, seed, capsys, env, start):
    assert orch_status(seed, alone(root), env) == 0
    assert capsys.readouterr() == (
        "No active flow. Run %s from an approved plan.\n" % start, "")


def test_status_on_an_unreadable_state_file_dies_naming_doctor(root, seed, capsys):
    (root / ".orchestrator").mkdir()
    (root / ".orchestrator" / "state.json").write_text('{"slug": "trunc')

    assert died_of(capsys, lambda: orch_status(seed, alone(root))) == (
        1, "", "orch: state.json cannot be read - run orch.sh doctor --flow\n")


def test_a_failed_checkout_read_dies_after_the_no_flow_line(root, seed, capsys):
    assert died_of(capsys, lambda: orch_status(seed, FakeGit(ORIGIN, toplevel=str(root)))) == (
        1, "No active flow. Run /orchestrator:start from an approved plan.\n",
        "orch: could not read the checkouts - git worktree list failed\n")


# --- the other checkouts, against real worktrees ------------------------------


@pytest.fixture
def clone(tmp_path):
    """A repository with one commit on main, holding a flow on #7, beside a
    ticket worktree and a hand-made worktree with no flow - none of which
    status lists: (its root, resolved, and the flow lines it prints)."""
    main = tmp_path.resolve() / "main"
    git_repo(main)
    committed(main, {"a.txt": "a\n"}, "first")
    run_git(main, "branch", "-M", "main")
    hold_flow(main, slug="main-flow", phase="spec", issue=7, base="main")
    worktree_add(main, main / ".orchestrator" / "worktrees" / "t4", "-b", "main--t4")
    worktree_add(main, tmp_path.resolve() / "bare-hand", "-b", "bare-hand")
    lines = ("flow:      main-flow\nphase:     spec\nissue:     7\nbase:      main\n"
             "branch:    -\nPR:        -\nreview:    iteration 0 of 5\nredo:      0\n\n"
             "handoffs:\n  (none yet)\n")
    return main, lines


def status_at(path, capsys):
    """`orch.sh status` in-process in the checkout at <path>, on real git and
    no GitHub: (the text before the blank line and other-checkouts heading,
    and the sorted lines under it - git lists linked worktrees in no fixed
    order)."""
    git = Git(cwd=str(path))
    assert status.run([], git=git, env=CLAUDE, pin=RepoPin(CLAUDE, git)) == 0
    out, err = capsys.readouterr()
    assert err == ""
    own, _, listed = out.partition("\nother checkouts:\n")
    return own, sorted(listed.splitlines())


def test_with_no_other_checkout_to_list_status_prints_nothing_extra(clone, capsys):
    main, lines = clone
    git = Git(cwd=str(main))

    assert status.run([], git=git, env=CLAUDE, pin=RepoPin(CLAUDE, git)) == 0
    assert capsys.readouterr() == (lines, "")


def test_status_lists_every_side_checkout_and_every_other_checkout_holding_a_flow(
        clone, tmp_path, capsys):
    main, lines = clone
    sides = main / ".orchestrator" / "checkouts"
    alpha = worktree_add(main, sides / "alpha", "--detach")
    beta = worktree_add(main, sides / "beta", "-b", "quick/3-beta")
    gamma = worktree_add(main, sides / "gamma", "--detach")
    for side in (alpha, beta, gamma):
        mark_side(side)
    hold_flow(gamma, slug="gamma-flow", phase="spec", issue=12, base="main")
    hand = worktree_add(main, tmp_path.resolve() / "hand", "-b", "hand")
    hold_flow(hand, slug="hand-flow", phase="spec", issue=None, base="main")
    stale = worktree_add(main, sides / "stale", "--detach")
    mark_side(stale)
    (stale / ".orchestrator").mkdir()
    (stale / ".orchestrator" / "state.json").write_text('{"slug": "trunc')

    assert status_at(main, capsys) == (lines, sorted([
        "  %s (no branch)" % alpha,
        "  %s branch quick/3-beta" % beta,
        "  %s flow gamma-flow spec #12" % gamma,
        "  %s flow hand-flow spec (no issue)" % hand,
        "  %s flow (state.json cannot be read)" % stale,
    ]))
    own, listed = status_at(gamma, capsys)
    assert own.startswith("flow:      gamma-flow\n")
    assert listed == sorted([
        "  %s flow main-flow spec #7" % main,
        "  %s (no branch)" % alpha,
        "  %s branch quick/3-beta" % beta,
        "  %s flow hand-flow spec (no issue)" % hand,
        "  %s flow (state.json cannot be read)" % stale,
    ])


def test_a_main_checkout_with_no_flow_is_never_listed_from_a_side_checkout(clone, capsys):
    """A quick implementation in the main checkout keeps no state and carries
    no marker; from the side checkout status prints No active flow first."""
    main, _ = clone
    (main / ".orchestrator" / "state.json").unlink()
    run_git(main, "checkout", "-qb", "quick/9-main")
    side = worktree_add(main, main / ".orchestrator" / "checkouts" / "alpha", "--detach")
    mark_side(side)

    assert status_at(side, capsys) == (
        "No active flow. Run /orchestrator:start from an approved plan.\n", [])
