"""The archive noun: in the main checkout the flow is archived in place,
refused while a ticket worktree is left; in a side checkout it is archived
into the main checkout's archive and then the worktree is removed, a refused
removal kept and warned of with exit 0 (ADR-0037). Run in-process from the
checkout, against real repositories under tmp_path, since git's worktree
semantics are git's; only the failed checkout read runs against FakeGit.
Every expected text is a literal of bash cmd_archive's output, byte for
byte."""
from __future__ import annotations

import json

import pytest

from conftest import committed, died_of, git_repo, mark_side, run_git, worktree_add
from orch import archive
from orch.git import FakeGit

# A clock pinned at 2026-01-02 03:04:05 UTC, so an archive directory's name
# is known: 20260102-030405-<slug>.
STAMP = "20260102-030405"


def clock():
    return 1767323045.0


def hold_flow(path, slug):
    """A flow named <slug> in the checkout at <path>: its state.json and a
    spec handoff."""
    orch = path / ".orchestrator"
    (orch / "handoff").mkdir(parents=True, exist_ok=True)
    (orch / "handoff" / "01-plan.md").write_text("plan\n")
    (orch / "state.json").write_text(json.dumps({"slug": slug, "phase": "done"}) + "\n")


def archived(main, slug):
    """The archive directory of <slug> under <main>'s archive."""
    return main / ".orchestrator" / "archive" / ("%s-%s" % (STAMP, slug))


@pytest.fixture
def main(tmp_path):
    """A repository with one commit whose .orchestrator/ git ignores, as
    init's exclude makes it: its root, resolved."""
    root = tmp_path.resolve() / "main"
    git_repo(root)
    committed(root, {"a.txt": "a\n"}, "first")
    with open(root / ".git" / "info" / "exclude", "a") as f:
        f.write(".orchestrator/\n")
    return root


def side(main, name):
    """A side checkout <name> of <main>, carrying the ownership marker."""
    path = worktree_add(main, main / ".orchestrator" / "checkouts" / name, "-b", name)
    mark_side(path)
    return path


def orch_archive(at, monkeypatch, env=None, git=None):
    """`orch.sh archive` in-process, run from the directory <at>, under
    <env> (empty when None): its exit code."""
    monkeypatch.chdir(at)
    return archive.run([], git=git, env={} if env is None else env, clock=clock)


def test_archive_in_the_main_checkout_moves_the_flow_in_place(main, monkeypatch, capsys):
    hold_flow(main, "my-feature")
    (main / ".orchestrator" / "review-pass" / "b").mkdir(parents=True)

    assert orch_archive(main, monkeypatch) == 0
    assert capsys.readouterr() == (".orchestrator/archive/%s-my-feature\n" % STAMP, "")
    assert sorted(p.name for p in archived(main, "my-feature").iterdir()) == [
        "handoff", "state.json"]
    assert sorted(p.name for p in (main / ".orchestrator").iterdir()) == [
        "archive", "review-pass"]


def test_archive_refuses_while_a_ticket_worktree_is_left(main, monkeypatch, capsys):
    hold_flow(main, "my-feature")
    t4 = worktree_add(main, main / ".orchestrator" / "worktrees" / "t4", "-b", "f--t4")
    t5 = worktree_add(main, main / ".orchestrator" / "worktrees" / "t5", "-b", "f--t5")

    assert died_of(capsys, lambda: orch_archive(main, monkeypatch)) == (1, "", (
        "orch: ticket worktrees are left under %s - moving them would break git's record of"
        " them:\n       %s (orch.sh ticket-worktree remove 4)\n"
        "       %s (orch.sh ticket-worktree remove 5)\n"
        "     Remove each with orch.sh ticket-worktree remove <n> first.\n" % (main, t4, t5)))
    assert (main / ".orchestrator" / "state.json").is_file()
    assert not (main / ".orchestrator" / "archive").exists()
    assert run_git(t4, "rev-parse", "--show-toplevel") == str(t4)


def test_archive_in_a_side_checkout_archives_into_the_main_checkout_then_removes_it(
        main, monkeypatch, capsys):
    sc = side(main, "alpha")
    hold_flow(sc, "second")

    assert orch_archive(sc, monkeypatch) == 0
    assert capsys.readouterr() == (
        "%s\nremoved side checkout %s\nThis session's working directory was that side"
        " checkout, and it is gone - close this session.\n" % (archived(main, "second"), sc),
        "")
    assert sorted(p.name for p in archived(main, "second").iterdir()) == [
        "handoff", "state.json"]
    assert not sc.exists()
    assert str(sc) not in run_git(main, "worktree", "list")


def test_a_refused_removal_keeps_the_side_checkout_warns_and_exits_0(
        main, monkeypatch, capsys):
    sc = side(main, "alpha")
    hold_flow(sc, "second")
    (sc / "wip.txt").write_text("wip\n")

    assert orch_archive(sc, monkeypatch) == 0
    assert capsys.readouterr() == (
        "%s\n" % archived(main, "second"),
        "orch: could not remove side checkout %s: fatal: '%s' contains modified or"
        " untracked files, use --force to delete it - left as it stands. Commit or"
        " discard its changes, then run orch.sh side-checkout remove alpha.\n" % (sc, sc))
    assert (archived(main, "second") / "state.json").is_file()
    assert (sc / "wip.txt").is_file()
    assert str(sc) in run_git(main, "worktree", "list")


def test_a_side_checkout_whose_move_fails_is_kept_and_archive_dies(main, monkeypatch, capsys):
    sc = side(main, "alpha")
    hold_flow(sc, "second")
    (archived(main, "second") / "handoff").mkdir(parents=True)
    (archived(main, "second") / "handoff" / "kept.md").write_text("kept\n")
    orch = sc / ".orchestrator"

    assert died_of(capsys, lambda: orch_archive(sc, monkeypatch)) == (1, "", (
        "orch: could not move %s/handoff into %s - moved there: nothing; left in place:"
        " %s/handoff %s/state.json\n" % (orch, archived(main, "second"), orch, orch)))
    assert (orch / "state.json").is_file()
    assert str(sc) in run_git(main, "worktree", "list")


@pytest.mark.parametrize("env,start", [
    ({"CLAUDECODE": "1"}, "/orchestrator:start"),
    ({"JUNIE_EXTENSION_ROOT": "/junie"},
     "/orchestrator:start (or orch-flow's Starting a flow section)"),
], ids=["claude", "junie"])
def test_with_no_active_flow_archive_dies_naming_the_host_s_start_command(
        main, monkeypatch, capsys, env, start):
    assert died_of(capsys, lambda: orch_archive(main, monkeypatch, env)) == (1, "", (
        "orch: no active flow (.orchestrator/state.json not found). Run %s first.\n"
        % start))
    assert not (main / ".orchestrator" / "archive").exists()


def test_a_failed_checkout_read_archives_nothing(main, monkeypatch, capsys):
    hold_flow(main, "my-feature")

    assert died_of(capsys, lambda: orch_archive(
        main, monkeypatch, git=FakeGit(toplevel=str(main)))) == (
        1, "", "orch: could not read the checkouts - nothing was archived\n")
    assert (main / ".orchestrator" / "state.json").is_file()
