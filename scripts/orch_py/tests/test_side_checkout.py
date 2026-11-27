"""The side-checkout concept module's archive and teardown - archive_root,
archive_flow, and archive-then-remove with its or-exit wrapper - and one round
of add, the issue lookup and the sweep, against real repositories under
tmp_path: git's worktree semantics are git's, so no fake
models them. Each message is bash side-checkout.sh's, verbatim."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from conftest import (ARCHIVE_STAMP, archive_clock, archive_main, archived, committed, died_of,
                      done_flow, fake, origin_clone, run_git, side_checkout, worktree_add)
from orch.git import Git
from orch.side_checkout import (
    FLOW_LESS_ENTRIES,
    archive_flow,
    archive_root,
    side_checkout_add,
    side_checkout_archive_and_remove_or_exit,
    side_checkout_for_issue,
    side_checkout_prune,
)

SIDE_CHECKOUT_SH = Path(__file__).resolve().parents[2] / "orch" / "side-checkout.sh"


def bash_flow_less_entries():
    """FLOW_LESS_ENTRIES in scripts/orch/side-checkout.sh, read with the bash
    module sourced in a bash child process, in list order."""
    run = subprocess.run(
        ["bash", "-c", 'source "$1"; printf "%s\\0" "${FLOW_LESS_ENTRIES[@]}"', "_",
         str(SIDE_CHECKOUT_SH)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, timeout=30, check=True,
    )
    return tuple(run.stdout.decode().split("\0")[:-1])


@pytest.mark.skipif(not SIDE_CHECKOUT_SH.exists(), reason="the bash side-checkout module is gone")
def test_the_flow_less_entries_are_the_bash_module_s():
    assert FLOW_LESS_ENTRIES == bash_flow_less_entries()


@pytest.fixture
def main(tmp_path):
    return archive_main(tmp_path)


def test_a_main_checkout_s_flow_is_archived_in_place_leaving_flow_less_entries(main):
    done_flow(main, "first")
    (main / ".orchestrator" / "review-pass" / "b").mkdir(parents=True)
    git = Git(cwd=str(main))

    home = archive_root(git, str(main))
    shown = archive_flow(git, str(main), home, str(main), archive_clock)

    dest = main / ".orchestrator" / "archive" / (ARCHIVE_STAMP + "-first")
    assert (home, shown) == (str(main), ".orchestrator/archive/%s-first" % ARCHIVE_STAMP)
    assert sorted(os.listdir(dest)) == ["handoff", "state.json"]
    assert sorted(os.listdir(main / ".orchestrator")) == ["archive", "review-pass"]
    assert (main / ".orchestrator" / "review-pass" / "b").is_dir()


def tear_down(main, path, policy, here=None):
    """side_checkout_archive_and_remove_or_exit on the side checkout at
    <path>, run from <here> (the main checkout when None): its status."""
    here = str(main if here is None else here)
    return side_checkout_archive_and_remove_or_exit(
        Git(cwd=str(main)), str(path), str(main), here, policy, str(main), archive_clock)


def test_a_side_checkout_s_flow_is_archived_in_the_main_checkout_then_the_worktree_removed(
        main, capsys):
    sc = side_checkout(main, "alpha")
    done_flow(sc, "second")

    assert archive_root(Git(cwd=str(sc)), str(sc)) == str(main)
    assert tear_down(main, sc, "die") == 0
    assert capsys.readouterr().out == (
        ".orchestrator/archive/%s-second\nremoved side checkout %s\n" % (ARCHIVE_STAMP, sc))
    assert sorted(os.listdir(archived(main, "second"))) == ["handoff", "state.json"]
    assert not sc.exists()


def test_a_removal_from_inside_the_side_checkout_says_to_close_the_session(main, capsys):
    sc = side_checkout(main, "alpha")

    assert tear_down(main, sc, "die", here=sc / "sub") == 0
    assert capsys.readouterr().out == (
        "removed side checkout %s\nThis session's working directory was that side"
        " checkout, and it is gone - close this session.\n" % sc)


def refusal(sc):
    return ("orch: could not remove side checkout %s: fatal: '%s' contains modified or"
            " untracked files, use --force to delete it - left as it stands. Commit or"
            " discard its changes, then run orch.sh side-checkout remove alpha.\n" % (sc, sc))


def test_a_refused_removal_under_warn_keeps_the_worktree_and_the_archive_made(main, capsys):
    sc = side_checkout(main, "alpha")
    done_flow(sc, "second")
    (sc / "wip.txt").write_text("wip\n")

    assert tear_down(main, sc, "warn") == 1
    out, err = capsys.readouterr()
    assert (out, err) == (".orchestrator/archive/%s-second\n" % ARCHIVE_STAMP, refusal(sc))
    assert (archived(main, "second") / "state.json").is_file()
    assert (sc / "wip.txt").is_file()


def test_a_refused_removal_under_die_dies_with_the_same_message(main, capsys):
    sc = side_checkout(main, "alpha")
    (sc / "wip.txt").write_text("wip\n")

    code, _, err = died_of(capsys, lambda: tear_down(main, sc, "die"))
    assert (code, err) == (1, refusal(sc))
    assert (sc / "wip.txt").is_file()


def block_archive(main):
    """A file where <main>'s archive directory goes, so none can be made."""
    (main / ".orchestrator").mkdir(exist_ok=True)
    (main / ".orchestrator" / "archive").write_text("")


def test_an_archive_directory_that_cannot_be_made_archives_nothing(main, capsys):
    done_flow(main, "first")
    block_archive(main)
    before = (main / ".orchestrator" / "state.json").read_text()

    code, out, err = died_of(
        capsys, lambda: archive_flow(Git(cwd=str(main)), str(main), str(main), str(main), archive_clock))
    assert (code, out, err) == (1, "", (
        "orch: could not create the archive directory %s - nothing was archived\n"
        % archived(main, "first")))
    assert (main / ".orchestrator" / "state.json").read_text() == before


def block_move(main, slug):
    """A non-empty handoff/ already in <slug>'s archive directory, so the
    flow's own handoff/ cannot move there."""
    (archived(main, slug) / "handoff" / "kept.md").parent.mkdir(parents=True)
    (archived(main, slug) / "handoff" / "kept.md").write_text("kept\n")


def test_a_move_failing_partway_names_what_moved_and_what_was_left(main, capsys):
    done_flow(main, "first")
    (main / ".orchestrator" / "notes.md").write_text("n\n")
    block_move(main, "first")
    orch, dest = main / ".orchestrator", archived(main, "first")

    code, out, err = died_of(
        capsys, lambda: archive_flow(Git(cwd=str(main)), str(main), str(main), str(main), archive_clock))
    assert (code, out, err) == (1, "", (
        "orch: could not move %s/handoff into %s - moved there: nothing; left in place:"
        " %s/handoff %s/notes.md %s/state.json\n" % (orch, dest, orch, orch, orch)))


def test_a_move_failing_after_some_moved_leaves_them_moved_and_the_state_in_place(
        main, capsys):
    done_flow(main, "first")
    (main / ".orchestrator" / "a-notes.md").write_text("n\n")
    block_move(main, "first")
    orch, dest = main / ".orchestrator", archived(main, "first")

    code, _, err = died_of(
        capsys, lambda: archive_flow(Git(cwd=str(main)), str(main), str(main), str(main), archive_clock))
    assert (code, err) == (1, (
        "orch: could not move %s/handoff into %s - moved there: %s/a-notes.md; left in"
        " place: %s/handoff %s/state.json\n" % (orch, dest, orch, orch, orch)))
    assert (dest / "a-notes.md").is_file()
    assert (orch / "state.json").is_file()


def test_a_side_checkout_whose_archive_cannot_be_made_keeps_the_worktree(main, capsys):
    sc = side_checkout(main, "alpha")
    done_flow(sc, "second")
    block_archive(main)

    code, out, err = died_of(capsys, lambda: tear_down(main, sc, "die"))
    assert (code, out, err) == (1, "", (
        "orch: could not create the archive directory %s - nothing was archived\n"
        % archived(main, "second")))
    assert (sc / ".orchestrator" / "state.json").is_file()


def test_a_side_checkout_whose_move_fails_keeps_the_worktree(main, capsys):
    sc = side_checkout(main, "alpha")
    done_flow(sc, "second")
    block_move(main, "second")
    orch = sc / ".orchestrator"

    code, out, err = died_of(capsys, lambda: tear_down(main, sc, "warn"))
    assert (code, out, err) == (1, "", (
        "orch: could not move %s/handoff into %s - moved there: nothing; left in place:"
        " %s/handoff %s/state.json\n" % (orch, archived(main, "second"), orch, orch)))
    assert (orch / "state.json").is_file()
    assert str(sc) in run_git(main, "worktree", "list")


def test_a_hand_made_worktree_archives_in_place(main, tmp_path):
    hand = worktree_add(main, tmp_path.resolve() / "hand", "-b", "hand")

    assert archive_root(Git(cwd=str(main)), str(hand)) == str(hand)


def test_no_archive_root_when_the_checkouts_cannot_be_read(tmp_path):
    assert archive_root(Git(cwd=str(tmp_path)), str(tmp_path)) is None


def test_a_flow_with_a_ticket_worktree_left_is_not_archived(main, capsys):
    done_flow(main, "first")
    t6 = worktree_add(main, main / ".orchestrator" / "worktrees" / "t6", "-b", "first--t6")

    code, out, err = died_of(
        capsys, lambda: archive_flow(Git(cwd=str(main)), str(main), str(main), str(main), archive_clock))
    assert (code, out, err) == (1, "", (
        "orch: ticket worktrees are left under %s - moving them would break git's record of"
        " them:\n       %s (orch.sh ticket-worktree remove 6)\n"
        "     Remove each with orch.sh ticket-worktree remove <n> first.\n" % (main, t6)))
    assert not (main / ".orchestrator" / "archive").exists()


def test_a_side_checkout_added_for_an_issue_is_found_for_it_then_swept_once_merged(
        tmp_path, seed, capsys):
    origin, main = tmp_path / "origin.git", tmp_path.resolve() / "clone"
    origin_clone(origin, main, "main")
    run_git(main, "checkout", "-qb", "main")
    committed(main, {"a.txt": "a\n"}, "first")
    run_git(main, "push", "-q", "origin", "main")
    seed.default_branch("main\n")
    git, gh = Git(cwd=str(main)), fake(seed)

    path = side_checkout_add(["alpha", "--issue", "5"], gh, git, {}, str(main))

    assert capsys.readouterr().out == path + "\n"
    assert (run_git(path, "branch", "--show-current"), run_git(path, "rev-parse", "HEAD")) \
        == ("", run_git(main, "rev-parse", "refs/remotes/origin/main"))
    assert side_checkout_for_issue(git, "5") == path == str(main / ".orchestrator/checkouts/alpha")
    run_git(path, "checkout", "-qb", "quick/5-alpha")
    run_git(path, "commit", "-q", "--allow-empty", "-m", "work")
    seed.pr(9, "merged", "quick/5-alpha", "main")
    seed.pr_head(9, run_git(path, "rev-parse", "HEAD"))
    seed.issue(5, "closed")

    assert side_checkout_prune([], gh, git, {}, str(main)) == 0
    assert capsys.readouterr() == (
        "removed side checkout %s\ndeleted branch quick/5-alpha\n" % path, "")
    assert side_checkout_for_issue(git, "5") is None
    assert not os.path.exists(path)
