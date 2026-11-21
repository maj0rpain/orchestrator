"""orch.sh's handoff of a converted noun to the orch package, run as
`python3 -m orch` would be, through a `-c` bootstrap (ADR-0067), end to end:
each check runs `orch.sh issue <verb>`, `orch.sh finding-triage <verb>`,
`orch.sh verification <verb>` or `orch.sh audit <verb>` as a command, in a
checkout under tmp_path, against a fake store seeded in the
layout the bash suite's fake_* helpers write, with ORCH_GH_FAKE_STORE set as
fake_github sets it."""
from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import (
    AUDIT_FIXTURES,
    VERIFICATION_KNOBS,
    comments_of,
    committed,
    git_repo,
    gone,
    labels_of,
    path_without,
    read,
    run_git,
    until,
    verification_records,
    verification_store,
)

SCRIPTS = Path(__file__).resolve().parents[2]


@pytest.fixture
def repo(tmp_path):
    """A repository at tmp_path/repo pinned to a GitHub origin."""
    root = tmp_path / "repo"
    git_repo(root, "https://github.com/acme/widgets.git")
    return root


def orch_sh(tmp_path, cwd, seed, *args, path=None, knobs=None, unset=()):
    """`orch.sh <args>` run by bash in <cwd> on <seed>'s store, PATH <path>
    (the test's own when None), with the variables <knobs> set and those
    named in <unset> unset: its stdout, stderr and exit code."""
    env = dict(os.environ, HOME=str(tmp_path), ORCH_GH_FAKE_STORE=seed.store,
               PYTHONDONTWRITEBYTECODE="1", **(knobs or {}))
    for name in unset:
        env.pop(name, None)
    if path is not None:
        env["PATH"] = path
    run = subprocess.run(
        ["/bin/bash", str(SCRIPTS / "orch.sh"), *args],
        cwd=str(cwd), env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
    )
    return run.stdout.decode(), run.stderr.decode(), run.returncode





def test_issue_fetch_writes_the_body_through_the_dispatch(tmp_path, repo, seed):
    seed.issue(12, "open", "bug")
    seed.body(12, "# Spec\r\n\r\nThe body.")
    out = tmp_path / "body.md"

    answer = orch_sh(tmp_path, repo, seed, "issue", "fetch", "12", str(out))

    assert answer == ("", "", 0)
    assert out.read_text() == "# Spec\n\nThe body.\n"


def test_issue_comment_posts_the_file_through_the_dispatch(tmp_path, repo, seed):
    seed.issue(12, "open")
    note = tmp_path / "note.md"
    note.write_text("A note.\n")

    answer = orch_sh(tmp_path, repo, seed, "issue", "comment", "12", str(note))

    assert answer == ("", "", 0)
    assert (Path(seed.store) / "issues" / "12" / "comments" / "1" / "body").read_text() \
        == "A note.\n"


def test_a_usage_error_exits_1_with_the_usage_line(tmp_path, repo, seed):
    assert orch_sh(tmp_path, repo, seed, "issue", "labels") == (
        "", "orch: usage: orch.sh issue labels <n>...\n", 1)


def test_issue_ready_exits_2_when_github_cannot_answer(tmp_path, repo, seed):
    seed.issue(12, "open", "ready-for-agent")
    seed.fail("adapter_issue_state_labels", "HTTP 502: Bad Gateway")

    assert orch_sh(tmp_path, repo, seed, "issue", "ready", "12") == (
        "", "orch: gh could not read issue #12: HTTP 502: Bad Gateway\n", 2)


def test_a_converted_verb_dies_before_doing_anything_without_python3(tmp_path, repo, seed):
    seed.issue(12, "open")
    note = tmp_path / "note.md"
    note.write_text("A note.\n")

    answer = orch_sh(tmp_path, repo, seed, "issue", "comment", "12", str(note),
                     path=path_without(tmp_path, "python3"))

    assert answer == ("", "orch: orch.sh issue needs python3 3.9 or newer (found none)"
                          " - run orch.sh doctor\n", 1)
    assert not (Path(seed.store) / "issues" / "12" / "comments").exists()


def test_a_converted_verb_runs_with_site_packages_disabled(tmp_path, repo, seed):
    shim = tmp_path / "python3-S" / "python3"
    shim.parent.mkdir()
    shim.write_text('#!/bin/sh\necho ran >>"%s"\nexec "%s" -S "$@"\n'
                    % (tmp_path / "shim.log", sys.executable))
    shim.chmod(0o755)
    seed.issue(12, "open", "ready-for-agent")

    answer = orch_sh(tmp_path, repo, seed, "issue", "ready", "12",
                     path="%s%s%s" % (shim.parent, os.pathsep, os.environ["PATH"]))

    assert answer == ("", "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


@pytest.mark.parametrize("module", ["json.py", "orch.py"])
def test_a_module_file_in_the_callers_directory_shadows_nothing(tmp_path, repo, seed, module):
    (repo / module).write_text("import sys\nsys.stderr.write('shadowed\\n')\nsys.exit(7)\n")

    assert orch_sh(tmp_path, repo, seed, "issue", "labels") == (
        "", "orch: usage: orch.sh issue labels <n>...\n", 1)


@pytest.mark.parametrize("came_from", ["sub", None], ids=["oldpwd-in-a-checkout", "no-oldpwd"])
def test_the_noun_run_outside_a_checkout_dies_as_orch_sh_does(tmp_path, repo, came_from):
    (repo / "sub").mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    env = dict(os.environ, HOME=str(tmp_path), PYTHONDONTWRITEBYTECODE="1",
               PYTHONPATH=str(SCRIPTS / "orch_py"))
    env.pop("OLDPWD", None)
    if came_from is not None:
        env["OLDPWD"] = str(repo / came_from)

    def run(*command):
        done = subprocess.run([*command, "issue", "fetch", "931", "out.md"], cwd=str(outside),
                              env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=30)
        return done.stdout.decode(), done.stderr.decode(), done.returncode

    bash = run("/bin/bash", str(SCRIPTS / "orch.sh"))
    assert bash[2] == 1 and "not inside a git repository" in bash[1]
    assert run(sys.executable, "-m", "orch") == bash


# --- finding-triage ----------------------------------------------------------


def test_finding_triage_apply_closes_the_finding_through_the_dispatch(tmp_path, repo, seed):
    seed.issue(5, "open", "review:nit", "needs-triage", "bug")
    seed.body(5, "**Axis:** Spec\n")
    note = tmp_path / "note.md"
    note.write_text("Fixed by abc1234 on main.\n")

    answer = orch_sh(tmp_path, repo, seed, "finding-triage", "apply", "5", "close-fixed",
                     "--comment-file", str(note))

    assert answer == ("", "", 0)
    assert comments_of(seed.store, 5) == [
        "> *This was generated by AI during triage.*\n\nFixed by abc1234 on main.\n"]
    assert (read(seed.store, "issues", 5, "state"), read(seed.store, "issues", 5, "reason")) \
        == ("CLOSED\n", "completed\n")
    assert sorted(labels_of(seed.store, 5)) == ["bug", "review:nit"]


def test_a_finding_triage_usage_error_exits_1_with_the_usage_line(tmp_path, repo, seed):
    assert orch_sh(tmp_path, repo, seed, "finding-triage", "scan", "--all", "--all") == (
        "", "orch: usage: orch.sh finding-triage scan [--all] [<issue> | --pr <n>]\n", 1)


def test_finding_triage_scan_reads_a_real_history_fetched_from_a_bare_origin(tmp_path, seed):
    origin, clone = tmp_path / "origin.git", tmp_path / "repo"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True,
                   stdin=subprocess.DEVNULL)
    git_repo(clone, str(origin))

    def commit(text, message):
        sha = committed(clone, {"src/app.sh": text}, message)
        run_git(clone, "push", "-q", "origin", "HEAD:refs/heads/main")
        return sha

    run_git(clone, "checkout", "-q", "-B", "main")
    filed = commit("one\ntwo\nthree\nfour\n", "reviewed")
    fix = commit("one\ntwo, fixed\nthree\nfour\n", "fix line 2")
    for n, line in ((3, 2), (4, 4)):
        seed.issue(n, "open", "review:nit", "needs-triage")
        seed.body(n, "**Location:** `src/app.sh:%d` at %s\n\n"
                     "**PR:** https://github.com/acme/widgets/pull/7\n" % (line, filed[:10]))

    assert orch_sh(tmp_path, clone, seed, "finding-triage", "scan") == ("".join([
        "3\t7\tsrc/app.sh:2\tchanged\t%s\tneeds-triage\n" % fix,
        "4\t7\tsrc/app.sh:4\tunchanged\t-\tneeds-triage\n",
    ]), "", 0)


# --- verification ------------------------------------------------------------

def test_verification_run_delivers_a_run_through_the_dispatch(tmp_path, repo, seed):
    committed(repo, {"README.md": "readme\n"}, "first")

    answer = orch_sh(tmp_path, repo, seed, "verification", "run",
                     "echo out; echo err >&2; exit 3", knobs=VERIFICATION_KNOBS)

    assert answer == ("out\n", "err\n", 3)
    assert verification_records(repo) == []


@pytest.mark.parametrize("given", [None, "", "/the/caller/s/path"],
                         ids=["unset", "empty", "set"])
def test_verification_run_hands_the_command_the_pythonpath_orch_sh_was_given(
        tmp_path, repo, seed, given):
    committed(repo, {"README.md": "readme\n"}, "first")
    knobs = dict(VERIFICATION_KNOBS)
    if given is not None:
        knobs["PYTHONPATH"] = given

    answer = orch_sh(tmp_path, repo, seed, "verification", "run",
                     'echo "${PYTHONPATH-unset}"', knobs=knobs,
                     unset=["PYTHONPATH"] if given is None else [])

    assert answer == ("%s\n" % ("unset" if given is None else given), "", 0)


def test_verification_stop_stops_a_live_run_through_the_dispatch(tmp_path, repo, seed):
    committed(repo, {"README.md": "readme\n"}, "first")
    going = orch_sh(tmp_path, repo, seed, "verification", "run", "sleep 30",
                    knobs=dict(VERIFICATION_KNOBS, ORCH_WAIT_BLOCK="0.3"))
    record, = verification_records(repo)
    group = int((verification_store(repo) / record / "pid").read_text().split()[0])
    try:
        answer = orch_sh(tmp_path, repo, seed, "verification", "stop", str(repo),
                         knobs=VERIFICATION_KNOBS)

        assert going == ("", "orch: still running after 0.3s - run the same command again\n", 75)
        assert answer == ("", "", 0)
        assert until(lambda: gone(group))
        assert verification_records(repo) == []
    finally:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass


def test_verification_usage_names_its_two_verbs_and_no_runner_entry_point(tmp_path, repo, seed):
    assert orch_sh(tmp_path, repo, seed, "verification", "runner") == (
        "", "orch: usage: orch.sh verification run <command> | stop <checkout>\n", 1)


def test_help_lists_both_verification_verbs_and_no_runner_entry_point(tmp_path, repo, seed):
    out, err, code = orch_sh(tmp_path, repo, seed, "help")
    lines = [line for line in out.splitlines() if "verification" in line]

    assert (err, code) == ("", 0)
    assert [line.split()[:2] for line in lines if line.startswith("  verification ")] == [
        ["verification", "run"], ["verification", "stop"]]
    assert "ORCH_WAIT_BLOCK" in out
    for name in ("orch.verification", "runner_main", "__main__", "RUNNER_BOOTSTRAP"):
        assert name not in out


# --- audit -------------------------------------------------------------------



def test_audit_begin_makes_the_run_directory_recording_head_through_the_dispatch(
        tmp_path, repo, seed):
    head = committed(repo, {"README.md": "readme\n"}, "first")

    out, err, code = orch_sh(tmp_path, repo, seed, "audit", "begin", "docs")

    run = Path(out.rstrip("\n"))
    assert (err, code) == ("", 0)
    assert run.parent == repo / ".orchestrator" / "audit" and run.name.startswith("docs-")
    assert (run / "record").read_text() == "kind docs\ncommit %s\n" % head


def test_audit_report_writes_the_golden_page_through_the_dispatch(tmp_path, repo, seed):
    page = tmp_path / "report.html"

    answer = orch_sh(tmp_path, repo, seed, "audit", "report",
                     str(AUDIT_FIXTURES / "none"), str(page))

    assert answer == ("%s\n" % page, "", 0)
    assert page.read_bytes() == (AUDIT_FIXTURES / "none.html").read_bytes()


def test_audit_file_files_one_finding_through_the_dispatch(tmp_path, repo, seed):
    committed(repo, {"README.md": "readme\n"}, "first")
    seed.next_issue(31)
    finding = tmp_path / "finding.md"
    finding.write_text("The README names a flag that is gone.\n")

    answer = orch_sh(tmp_path, repo, seed, "audit", "file", "README names a gone flag",
                     "--category", "documentation", "--finding-file", str(finding),
                     "--location", "README.md:1")

    assert answer == ("31\n", "", 0)
    assert read(seed.store, "issues", 31, "title") == "README names a gone flag\n"
    assert sorted(labels_of(seed.store, 31)) == ["documentation", "needs-triage"]


def test_audit_file_run_files_a_run_s_pick_through_the_dispatch(tmp_path, repo, seed):
    run = tmp_path / "run"
    shutil.copytree(str(AUDIT_FIXTURES / "full"), str(run))
    seed.next_issue(40)

    answer = orch_sh(tmp_path, repo, seed, "audit", "file", "--run", str(run), "2")

    assert answer == ("2\t40\tfiled\n", "", 0)
    assert read(seed.store, "issues", 40, "title") == "Deepen d.sh\n"
