"""orch.sh's handoff of a converted noun to the orch package, run as
`python3 -m orch` would be, through a `-c` bootstrap (ADR-0067), end to end:
each check runs `orch.sh issue <verb>` or `orch.sh finding-triage <verb>` as a
command, in a checkout under tmp_path, against a fake store seeded in the
layout the bash suite's fake_* helpers write, with ORCH_GH_FAKE_STORE set as
fake_github sets it."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import comments_of, committed, git_repo, labels_of, read, run_git

SCRIPTS = Path(__file__).resolve().parents[2]


@pytest.fixture
def repo(tmp_path):
    """A repository at tmp_path/repo pinned to a GitHub origin."""
    repo = tmp_path / "repo"
    git_repo(repo, "https://github.com/acme/widgets.git")
    return repo


def orch_sh(tmp_path, repo, seed, *args, path=None):
    """`orch.sh <args>` run by bash in <repo> on <seed>'s store, PATH <path>
    (the test's own when None): its stdout, stderr and exit code."""
    env = dict(os.environ, HOME=str(tmp_path), ORCH_GH_FAKE_STORE=seed.store,
               PYTHONDONTWRITEBYTECODE="1")
    if path is not None:
        env["PATH"] = path
    run = subprocess.run(
        ["/bin/bash", str(SCRIPTS / "orch.sh"), *args],
        cwd=str(repo), env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
    )
    return run.stdout.decode(), run.stderr.decode(), run.returncode


def path_without_python3(tmp_path):
    """The test's PATH with no python3 on it: each directory holding one is
    replaced by a directory of its own linking every other command there."""
    kept = []
    for k, directory in enumerate(os.environ["PATH"].split(os.pathsep)):
        if not os.path.exists(os.path.join(directory, "python3")):
            kept.append(directory)
            continue
        links = tmp_path / ("no-python3-%d" % k)
        links.mkdir()
        for name in os.listdir(directory):
            if name != "python3":
                (links / name).symlink_to(os.path.join(directory, name))
        kept.append(str(links))
    return os.pathsep.join(kept)


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
                     path=path_without_python3(tmp_path))

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
    origin, repo = tmp_path / "origin.git", tmp_path / "repo"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True,
                   stdin=subprocess.DEVNULL)
    git_repo(repo, str(origin))

    def commit(text, message):
        sha = committed(repo, {"src/app.sh": text}, message)
        run_git(repo, "push", "-q", "origin", "HEAD:refs/heads/main")
        return sha

    run_git(repo, "checkout", "-q", "-B", "main")
    filed = commit("one\ntwo\nthree\nfour\n", "reviewed")
    fix = commit("one\ntwo, fixed\nthree\nfour\n", "fix line 2")
    for n, line in ((3, 2), (4, 4)):
        seed.issue(n, "open", "review:nit", "needs-triage")
        seed.body(n, "**Location:** `src/app.sh:%d` at %s\n\n"
                     "**PR:** https://github.com/acme/widgets/pull/7\n" % (line, filed[:10]))

    assert orch_sh(tmp_path, repo, seed, "finding-triage", "scan") == ("".join([
        "3\t7\tsrc/app.sh:2\tchanged\t%s\tneeds-triage\n" % fix,
        "4\t7\tsrc/app.sh:4\tunchanged\t-\tneeds-triage\n",
    ]), "", 0)
