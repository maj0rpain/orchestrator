"""The entry point of `python3 -m orch`: its interpreter check and the
standard-library-only runtime."""
from __future__ import annotations

import os
import signal
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import (CLAUDE, PACKAGE_BOOTSTRAP, TICKET_PARENT, added, comments_of, committed,
                      died_of, fake, git_repo, hold_flow, run_git, wt_path)
from orch import ticket
from orch.common import exclude_orch_dirs
from orch.gh_fake import FakeStore
from orch.git import Git
from orch.__main__ import main

PACKAGE_ROOT = Path(__file__).resolve().parent.parent


def test_a_python_below_3_9_dies_before_doing_anything(monkeypatch, capsys):
    monkeypatch.setattr(sys, "version_info", (3, 8, 10, "final", 0))

    assert died_of(capsys, lambda: main(["issue", "fetch", "12"])) == (
        1, "",
        "orch: orch.sh issue needs python3 3.9 or newer (found 3.8.10)"
        " - run orch.sh doctor\n",
    )


def test_python_3_9_passes_the_check(monkeypatch, capsys):
    monkeypatch.setattr(sys, "version_info", (3, 9, 0, "final", 0))

    code, _, err = died_of(capsys, lambda: main(["no-such-noun"]))

    assert "needs python3" not in err
    assert code == 1


def test_an_unconverted_noun_is_an_unknown_command(capsys):
    assert died_of(capsys, lambda: main(["no-such-noun", "verb"])) == (
        1, "", "orch: unknown command: no-such-noun (run 'orch.sh help')\n"
    )


def test_every_module_imports_with_site_packages_disabled():
    script = (
        "import sys\n"
        "sys.path.insert(0, sys.argv.pop(1))\n"
        "import importlib, pkgutil, orch\n"
        "for m in pkgutil.walk_packages(orch.__path__, 'orch.'):\n"
        "    importlib.import_module(m.name)\n"
        "print('imported')\n"
    )
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")

    run = subprocess.run(
        [sys.executable, "-S", "-c", script, str(PACKAGE_ROOT)],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        timeout=30,
    )

    assert (run.returncode, run.stdout, run.stderr) == (0, "imported\n", "")


def into_a_closed_pipe(cwd, *call):
    """The entry point run with <call> in <cwd>, its stdout a pipe whose
    reader is already gone: the completed process."""
    reader, writer = os.pipe()
    os.close(reader)
    try:
        return subprocess.run(
            [sys.executable, "-c", PACKAGE_BOOTSTRAP, str(PACKAGE_ROOT), *call],
            cwd=str(cwd), env=dict(os.environ, HOME=str(cwd)),
            stdin=subprocess.DEVNULL, stdout=writer, stderr=subprocess.PIPE,
            universal_newlines=True, timeout=30,
        )
    finally:
        os.close(writer)


def test_a_noun_writing_into_a_closed_pipe_dies_of_sigpipe_silently(tmp_path):
    """bash's printf died of SIGPIPE on a pipe whose reader is gone: so does
    a noun this change converts, with no traceback and no flush warning on
    stderr."""
    run = into_a_closed_pipe(tmp_path, "slug", "Some Text")

    assert (run.returncode, run.stderr) == (-signal.SIGPIPE, "")


def test_phase_writing_into_a_closed_pipe_dies_of_sigpipe_silently(tmp_path):
    """phase, converted after init, keeps bash printf's silent SIGPIPE death
    too."""
    git_repo(tmp_path)
    hold_flow(tmp_path, slug="x", phase="spec", issue=7)

    run = into_a_closed_pipe(tmp_path, "phase", "boundary")

    assert (run.returncode, run.stderr) == (-signal.SIGPIPE, "")


def test_the_phase_noun_is_converted(capsys):
    assert died_of(capsys, lambda: main(["phase", "wipe"]))[2] == \
        "orch: unknown phase op: wipe (want advance|boundary)\n"


def test_redo_writing_into_a_closed_pipe_dies_of_sigpipe_silently(tmp_path, monkeypatch):
    """redo review prints the new redo number, as bash's printf did, so a
    closed pipe ends it silently too - once the redo itself is done."""
    store = tmp_path / "store"
    store.mkdir()
    seed = FakeStore(str(store))
    seed.issue(21, "open")
    seed.pr(30, "open", "orch/21-redo", "main")
    root = tmp_path / "repo"
    git_repo(root, "https://github.com/acme/widgets.git")
    run_git(root, "commit", "-q", "--allow-empty", "-m", "first")
    run_git(root, "checkout", "-q", "-b", "orch/21-redo")
    hold_flow(root, slug="redo", phase="review", issue=21, branch="orch/21-redo", pr=30,
              iteration=1, budget=1)
    (root / ".orchestrator" / "review").mkdir()
    (root / ".orchestrator" / "review" / "iteration-01.md").write_text(
        "## Terminal state\nstop\n")
    monkeypatch.setenv("ORCH_GH_FAKE_STORE", str(store))

    run = into_a_closed_pipe(root, "redo", "review")

    assert (run.returncode, run.stderr) == (-signal.SIGPIPE, "")
    assert run_git(root, "branch", "--show-current") == "orch/21-redo-redo-1"


def test_the_redo_noun_is_converted(capsys):
    assert died_of(capsys, lambda: main(["redo", "wipe"]))[2] == \
        "orch: unknown redo op: wipe (want review|spec)\n"


def spec_with_ticket(seed):
    """Spec issue #90 with one open sub-issue, #450."""
    for n in (90, 450):
        seed.issue(n, "open")
    seed.sub_issue(90, 450)


def published_into(root, seed, capsys):
    """A spec issue #50 and a body file to publish a ticket under it."""
    seed.issue(50, "open")
    seed.next_issue(100)
    body = root / ".." / "body.md"
    body.write_text("Build the thing.\n")
    return ["ticket", "publish", "50", "A ticket", str(body)]


def a_saved_report(root, seed, capsys):
    reports = root / ".orchestrator" / "reports"
    reports.mkdir(parents=True)
    (reports / "7.md").write_text("Ticket: #7\n")
    return ["ticket", "report", "show", "7"]


def a_merged_leftover(root, seed, capsys):
    """bash's reclaim of a reported ticket already merged: ticket #7 of spec
    #90, its worktree holding one commit, merged into the flow's branch, so
    reclaim prints a line for each of its close and removal."""
    seed.issue(90, "open")
    seed.issue(7, "open")
    seed.sub_issue(90, 7)
    committed(Path(added(root, capsys, 7)), {"t7.txt": "work 7\n"}, "t7.txt: work 7")
    exclude_orch_dirs(Git())
    hold_flow(root, phase="implement", branch=TICKET_PARENT, issue=90)
    a_saved_report(root, seed, capsys)
    assert ticket.run(["merge", "7"], gh=fake(seed), env=CLAUDE) == 0
    capsys.readouterr()
    return ["ticket", "reclaim", "90"]


def a_listed_worktree(root, seed, capsys):
    added(root, capsys, 7)
    return ["ticket-worktree", "list"]


TICKET_STDOUT_VERBS = {
    "ticket next": lambda root, seed, capsys: (spec_with_ticket(seed),
                                               ["ticket", "next", "90"])[1],
    "ticket list": lambda root, seed, capsys: (spec_with_ticket(seed),
                                               ["ticket", "list", "90"])[1],
    "ticket parent": lambda root, seed, capsys: (spec_with_ticket(seed),
                                                 ["ticket", "parent", "450"])[1],
    "ticket exists": lambda root, seed, capsys: (spec_with_ticket(seed),
                                                 ["ticket", "exists", "90"])[1],
    "ticket report show": a_saved_report,
    "ticket publish": published_into,
    "ticket reclaim": a_merged_leftover,
    "ticket-worktree list": a_listed_worktree,
}


@pytest.mark.parametrize("verb", sorted(TICKET_STDOUT_VERBS))
def test_a_ticket_verb_writing_into_a_closed_pipe_dies_of_sigpipe_silently(
        ticket_repo, seed, capsys, monkeypatch, verb):
    """Every ticket and ticket-worktree verb that prints to stdout ends a
    closed stdout pipe as bash's printf did: silently, of SIGPIPE. add's own
    test below checks it, with the checkout it still makes."""
    call = TICKET_STDOUT_VERBS[verb](ticket_repo, seed, capsys)
    monkeypatch.setenv("ORCH_GH_FAKE_STORE", seed.store)
    monkeypatch.setenv("GH_REPO", "acme/widgets")

    run = into_a_closed_pipe(ticket_repo, *call)

    assert (run.returncode, run.stderr) == (-signal.SIGPIPE, "")


def test_ticket_worktree_add_into_a_closed_pipe_still_checks_the_ticket_branch_out(
        ticket_repo, seed):
    run = into_a_closed_pipe(ticket_repo, "ticket-worktree", "add", "7")

    assert (run.returncode, run.stderr) == (-signal.SIGPIPE, "")
    assert run_git(wt_path(ticket_repo, 7), "branch", "--show-current") == TICKET_PARENT + "--t7"


def test_pr_comment_writing_into_a_closed_pipe_dies_of_sigpipe_silently(
        ticket_repo, seed, monkeypatch):
    """pr comment prints the PR number it posted on, as bash's printf did, so
    a closed stdout pipe ends it silently - once the comment is posted."""
    seed.pr(57, "open", TICKET_PARENT, "main")
    note = ticket_repo / ".." / "note.md"
    note.write_text("A note.\n")
    monkeypatch.setenv("ORCH_GH_FAKE_STORE", seed.store)
    monkeypatch.setenv("GH_REPO", "acme/widgets")

    run = into_a_closed_pipe(ticket_repo, "pr", "comment", str(note))

    assert (run.returncode, run.stderr) == (-signal.SIGPIPE, "")
    assert comments_of(seed.store, 57, "prs") == ["A note.\n"]


@pytest.mark.parametrize("call", [["route", "show"], ["--call", "route", "run", "show"]],
                         ids=["noun", "call-mode"])
def test_a_noun_converted_earlier_keeps_its_flush_failure_on_a_closed_pipe(tmp_path, call):
    """A noun converted before init, slug, status, archive and help, and an
    orch_python_call bridge, end a closed stdout pipe as they always did:
    Python's failed flush at exit, status 120, never SIGPIPE."""
    git_repo(tmp_path)

    run = into_a_closed_pipe(tmp_path, *call)

    assert (run.returncode, "BrokenPipeError" in run.stderr) == (120, True)


def test_the_issue_noun_is_converted(capsys):
    assert died_of(capsys, lambda: main(["issue", "labels"])) == (
        1, "", "orch: usage: orch.sh issue labels <n>...\n")


def test_the_finding_triage_noun_is_converted(capsys):
    assert died_of(capsys, lambda: main(["finding-triage", "scan", "--all", "--all"])) == (
        1, "", "orch: usage: orch.sh finding-triage scan [--all] [<issue> | --pr <n>]\n")


def test_the_spec_review_noun_is_routed_to_its_module(capsys):
    assert died_of(capsys, lambda: main(["spec-review", "wipe"])) == (
        1, "", "orch: unknown spec-review op: wipe (want begin|check|apply|wait|prompt)\n")


def test_call_mode_below_python_3_9_dies_naming_the_noun(monkeypatch, capsys):
    monkeypatch.setattr(sys, "version_info", (3, 8, 10, "final", 0))

    assert died_of(capsys, lambda: main(["--call", "agent", "check_settings"])) == (
        1, "",
        "orch: orch.sh agent needs python3 3.9 or newer (found 3.8.10)"
        " - run orch.sh doctor\n",
    )


def test_call_mode_below_python_3_9_dies_naming_the_command_given_by_as(monkeypatch, capsys):
    monkeypatch.setattr(sys, "version_info", (3, 8, 10, "final", 0))

    assert died_of(capsys, lambda: main(
        ["--call", "--as", "autopilot", "agent", "validate_autopilot"])) == (
        1, "",
        "orch: orch.sh autopilot needs python3 3.9 or newer (found 3.8.10)"
        " - run orch.sh doctor\n",
    )


def test_call_mode_with_as_dispatches_the_noun_after_it(capsys):
    assert died_of(capsys, lambda: main(["--call", "--as", "autopilot", "issue", "run", "labels"])) == (
        1, "", "orch: usage: orch.sh issue labels <n>...\n")


def test_call_mode_dispatches_a_named_function_on_a_converted_noun(capsys):
    assert died_of(capsys, lambda: main(["--call", "issue", "run", "labels"])) == (
        1, "", "orch: usage: orch.sh issue labels <n>...\n")
    assert died_of(capsys, lambda: main(["--call", "spec-review", "run", "wipe"])) == (
        1, "", "orch: unknown spec-review op: wipe (want begin|check|apply|wait|prompt)\n")


def test_call_mode_refuses_missing_args_unknown_noun_and_unknown_or_private_function(capsys):
    usage = "orch: usage: orch_python_call [--as <command>] <noun> <func> [<arg>...]\n"
    assert died_of(capsys, lambda: main(["--call"])) == (1, "", usage)
    assert died_of(capsys, lambda: main(["--call", "route"])) == (1, "", usage)
    assert died_of(capsys, lambda: main(["--call", "--as"])) == (1, "", usage)
    assert died_of(capsys, lambda: main(["--call", "--as", "autopilot", "route"])) == (
        1, "", usage)
    assert died_of(capsys, lambda: main(["--call", "no-such-noun", "run"])) == (
        1, "", "orch: unknown command: no-such-noun (run 'orch.sh help')\n")
    assert died_of(capsys, lambda: main(["--call", "route", "no_such_fn"])) == (
        1, "", "orch: unknown route function: no_such_fn\n")
    assert died_of(capsys, lambda: main(["--call", "route", "_private"])) == (
        1, "", "orch: unknown route function: _private\n")
