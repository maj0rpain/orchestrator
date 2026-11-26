"""orch.sh's handoff of a converted noun to the orch package, run as
`python3 -m orch` would be, through a `-c` bootstrap (ADR-0067), end to end:
each check runs `orch.sh issue <verb>`, `orch.sh finding-triage <verb>`,
`orch.sh verification <verb>`, `orch.sh audit <verb>`, `orch.sh review-pass
<verb>`, `orch.sh spec-review <verb>`, `orch.sh breakdown <verb>`, `orch.sh
spec <verb>`, `orch.sh glossary <verb>`, `orch.sh parallel show`, `orch.sh
route show`, `orch.sh agent <verb>`, `orch.sh slug <text>`, `orch.sh status`,
`orch.sh init <slug>`, `orch.sh archive`, `orch.sh phase <verb>` or `orch.sh
help` (and its spellings)
as a command, in a checkout under tmp_path, against a fake store seeded in the
layout the bash suite's fake_* helpers write, with ORCH_GH_FAKE_STORE set as
fake_github sets it."""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import (
    AUDIT_FIXTURES,
    GLOBAL_CONFIG,
    PACKAGE_BOOTSTRAP,
    VERIFICATION_KNOBS,
    comments_of,
    committed,
    flow_state,
    git_repo,
    gone,
    labels_of,
    origin_clone,
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


def bash_run(tmp_path, cwd, argv, path=None, knobs=None, unset=(), joined=False):
    """bash <argv> run in <cwd>, HOME tmp_path, PATH <path> (the test's own
    when None), with the variables <knobs> set and those named in <unset>
    unset: its stdout, stderr and exit code. <joined> sends stderr into
    stdout, one stream in the order written, its stderr then empty."""
    env = dict(os.environ, HOME=str(tmp_path), PYTHONDONTWRITEBYTECODE="1", **(knobs or {}))
    for name in unset:
        env.pop(name, None)
    if path is not None:
        env["PATH"] = path
    run = subprocess.run(
        ["/bin/bash", *argv],
        cwd=str(cwd), env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT if joined else subprocess.PIPE,
        timeout=30,
    )
    return run.stdout.decode(), (run.stderr or b"").decode(), run.returncode


def orch_sh(tmp_path, cwd, seed, *args, path=None, knobs=None, unset=(), joined=False,
            script=None):
    """`orch.sh <args>` run by bash_run on <seed>'s store. <script> overrides
    the orch.sh path (e.g. a symlinked install)."""
    return bash_run(
        tmp_path, cwd, [str(SCRIPTS / "orch.sh" if script is None else script), *args],
        path=path, knobs={"ORCH_GH_FAKE_STORE": seed.store, **(knobs or {})}, unset=unset,
        joined=joined,
    )





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


def python3_shim(tmp_path):
    """A python3 first on PATH that logs `ran` to tmp_path/shim.log and runs
    this interpreter with site-packages disabled: that PATH."""
    shim = tmp_path / "python3-S" / "python3"
    shim.parent.mkdir()
    shim.write_text('#!/bin/sh\necho ran >>"%s"\nexec "%s" -S "$@"\n'
                    % (tmp_path / "shim.log", sys.executable))
    shim.chmod(0o755)
    return "%s%s%s" % (shim.parent, os.pathsep, os.environ["PATH"])


def test_a_converted_verb_runs_with_site_packages_disabled(tmp_path, repo, seed):
    path = python3_shim(tmp_path)
    seed.issue(12, "open", "ready-for-agent")

    answer = orch_sh(tmp_path, repo, seed, "issue", "ready", "12", path=path)

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
    env = dict(os.environ, HOME=str(tmp_path), PYTHONDONTWRITEBYTECODE="1")
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
    assert run(sys.executable, "-c", PACKAGE_BOOTSTRAP, str(SCRIPTS / "orch_py")) == bash


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
    origin_clone(origin, clone)

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


def colon_install(tmp_path):
    """orch.sh at a plugin root whose path holds a colon, the separator
    PYTHONPATH splits on: a symlink to this plugin, kept unresolved as the
    plugin root orch.sh works out."""
    root = tmp_path / "plugins" / "c:olon"
    root.parent.mkdir()
    root.symlink_to(SCRIPTS.parent)
    return root / "scripts" / "orch.sh"


def test_a_converted_noun_runs_from_a_plugin_root_holding_a_colon(tmp_path, repo, seed):
    out, err, code = orch_sh(tmp_path, repo, seed, "help", script=colon_install(tmp_path))

    assert (out.encode("utf-8"), err, code) == (
        HELP_GOLDEN.read_bytes(), "", 0)


def test_verification_run_starts_its_runner_from_a_plugin_root_holding_a_colon(
        tmp_path, repo, seed):
    committed(repo, {"README.md": "readme\n"}, "first")

    answer = orch_sh(tmp_path, repo, seed, "verification", "run",
                     'echo "${PYTHONPATH-unset}"', knobs=VERIFICATION_KNOBS,
                     unset=["PYTHONPATH"], script=colon_install(tmp_path))

    assert answer == ("unset\n", "", 0)


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


# --- review-pass -------------------------------------------------------------


@pytest.fixture
def review_branch(repo, seed):
    """The repository, committed, on quick/12-foo, its default branch main."""
    committed(repo, {"README.md": "readme\n"}, "first")
    run_git(repo, "checkout", "-q", "-b", "quick/12-foo")
    seed.default_branch("main")
    return repo


def test_review_pass_begin_prints_the_first_prefix_through_the_python_noun(
        tmp_path, review_branch, seed):
    answer = orch_sh(tmp_path, review_branch, seed, "review-pass", "begin", "12",
                     path=python3_shim(tmp_path))

    assert answer == ("%s/iteration-01\n" % (
        review_branch / ".orchestrator" / "review-pass" / "quick" / "12-foo"), "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_review_pass_known_items_writes_the_file_through_the_python_noun(
        tmp_path, review_branch, seed):
    seed.issue(12, "open")
    seed.comment(12, "pat", "2026-10-01T09:00:00Z", "Spec ruling: Retry once.")
    seed.pr(57, "open", "quick/12-foo", "main")
    seed.pr_body(57, "Closes #12\n\n## Deviations\n\n- Kept the old cache\n")
    known = tmp_path / "known.md"

    answer = orch_sh(tmp_path, review_branch, seed, "review-pass", "known-items", "12",
                     str(known), path=python3_shim(tmp_path))

    assert answer == ("", "", 0)
    assert known.read_text() == ("## Deviations\n- Kept the old cache\n"
                                 "## Known items\n- Retry once. - spec ruling\n")
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_an_unknown_review_pass_op_is_refused_through_the_python_noun(tmp_path, repo, seed):
    answer = orch_sh(tmp_path, repo, seed, "review-pass", "wipe", "12",
                     path=python3_shim(tmp_path))

    assert answer == ("", "orch: unknown review-pass op: wipe (want begin|known-items)\n", 1)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_help_lists_both_review_pass_verbs(tmp_path, repo, seed):
    out, err, code = orch_sh(tmp_path, repo, seed, "help")

    assert (err, code) == ("", 0)
    assert [line.split()[:3] for line in out.splitlines()
            if line.startswith("  review-pass ")] == [
        ["review-pass", "begin", "<issue>"], ["review-pass", "known-items", "<issue>"]]


# --- spec-review -------------------------------------------------------------

# A one-item round: the Fidelity lens's one finding, its one minor edit.
SPEC_REVIEW_BATCH = """@@ lens fidelity ran
@@ lens consistency not-run skipped
@@ lens testability not-run skipped
@@ lens implementability not-run skipped

@@ item 1 fidelity apply minor
@@ finding fidelity 1
@@ summary Alpha primed
@@ anchor
Alpha line.
@@ replace
Alpha prime line.
@@ end
"""


def spec_round(repo):
    """A standalone review's round directory for issue #14 under <repo>,
    holding the body, the comments, the one-item batch and its lens file."""
    d = repo.resolve() / ".orchestrator" / "spec-review" / "14"
    d.mkdir(parents=True)
    (d / "spec.md").write_text("Alpha line.\n")
    (d / "comments.md").write_text("")
    (d / "batch.md").write_text(SPEC_REVIEW_BATCH)
    (d / "lens-fidelity.md").write_text("@@ finding 1\nAlpha is stale.\n")
    return d


def test_spec_review_begin_resets_the_round_directory_through_the_python_noun(
        tmp_path, repo, seed):
    d = spec_round(repo)

    answer = orch_sh(tmp_path, repo, seed, "spec-review", "begin", "14",
                     path=python3_shim(tmp_path))

    assert answer == ("%s/\n" % d, "", 0)
    assert list(d.iterdir()) == []
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_spec_review_check_saves_the_view_through_the_python_noun(tmp_path, repo, seed):
    d = spec_round(repo)

    out, err, code = orch_sh(tmp_path, repo, seed, "spec-review", "check", str(d),
                             path=python3_shim(tmp_path))

    assert code == 0
    assert out.endswith("### Minor edits\n\n- **1** - Fidelity: Alpha primed\n")
    assert (d / "view.md").read_text() == out
    assert err.startswith("batch.md passes: 1 items, 1 anchors")
    assert err.endswith("; it is saved in %s/view.md\n" % d)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_spec_review_apply_publishes_the_round_through_the_python_noun(tmp_path, repo, seed):
    d = spec_round(repo)
    seed.issue(14, "open")
    seed.body(14, "Alpha line.\n")

    out, err, code = orch_sh(tmp_path, repo, seed, "spec-review", "apply", str(d),
                             "recommended", "--round", "1/1", "--issue", "14",
                             path=python3_shim(tmp_path))

    assert (code, err) == (0, "")
    assert read(seed.store, "issues", 14, "body") == "Alpha prime line.\n"
    assert comments_of(seed.store, 14) == [(d / "changelog.md").read_text()]
    assert (d / "round-complete").exists()
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_spec_review_wait_counts_the_lenses_back_through_the_python_noun(
        tmp_path, repo, seed):
    d = spec_round(repo)

    answer = orch_sh(tmp_path, repo, seed, "spec-review", "wait", str(d), "fidelity",
                     path=python3_shim(tmp_path))

    assert answer == ("lenses back: fidelity 1\n", "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_spec_review_prompt_prints_the_lens_s_lines_through_the_python_noun(
        tmp_path, repo, seed):
    d = spec_round(repo)

    answer = orch_sh(tmp_path, repo, seed, "spec-review", "prompt", str(d), "consistency",
                     path=python3_shim(tmp_path))

    assert answer == ("Spec body: {d}/spec.md\nComments: {d}/comments.md\n"
                      "Glossary: none\nADR directory: none\nSettled: none\n"
                      "Findings file: {d}/lens-consistency.md\n".format(d=d),
                      "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_an_unknown_spec_review_op_is_refused_through_the_python_noun(tmp_path, repo, seed):
    answer = orch_sh(tmp_path, repo, seed, "spec-review", "wipe", path=python3_shim(tmp_path))

    assert answer == ("", "orch: unknown spec-review op: wipe"
                          " (want begin|check|apply|wait|prompt)\n", 1)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_help_lists_all_five_spec_review_verbs(tmp_path, repo, seed):
    out, err, code = orch_sh(tmp_path, repo, seed, "help")

    assert (err, code) == ("", 0)
    assert [line.split()[1] for line in out.splitlines()
            if line.startswith("  spec-review ")] == [
        "begin", "check", "wait", "prompt", "apply", "apply"]


# --- breakdown ---------------------------------------------------------------

def test_breakdown_state_reads_the_spec_s_tickets_through_the_python_noun(tmp_path, repo, seed):
    seed.issue(50, "open")
    seed.issue(60, "open")
    seed.sub_issue(50, 60)

    answer = orch_sh(tmp_path, repo, seed, "breakdown", "state", "50",
                     path=python3_shim(tmp_path))

    assert answer == ("complete\n", "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


# --- spec --------------------------------------------------------------------

CLAUDE = {"ORCHESTRATOR_HOST": "claude"}


@pytest.fixture
def spec_flow(repo, seed):
    """The repository, a flow at the spec phase on issue #14, its issue open
    with a body: the repository's resolved path."""
    flow_state(repo, "spec", 14)
    seed.issue(14, "open")
    seed.body(14, "The spec.")
    return repo.resolve()


def test_spec_fetch_writes_the_flow_issue_s_body_through_the_python_noun(
        tmp_path, spec_flow, seed):
    out = tmp_path / "spec.md"

    answer = orch_sh(tmp_path, spec_flow, seed, "spec", "fetch", str(out),
                     path=python3_shim(tmp_path))

    assert answer == ("", "", 0)
    assert out.read_text() == "The spec.\n"
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_spec_update_replaces_the_flow_issue_s_body_through_the_python_noun(
        tmp_path, spec_flow, seed):
    body = tmp_path / "spec.md"
    body.write_text("The new spec.\n")

    answer = orch_sh(tmp_path, spec_flow, seed, "spec", "update", str(body),
                     path=python3_shim(tmp_path))

    assert answer == ("", "", 0)
    assert read(seed.store, "issues", 14, "body") == "The new spec.\n"
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_spec_comment_posts_on_the_flow_issue_through_the_python_noun(
        tmp_path, spec_flow, seed):
    note = tmp_path / "note.md"
    note.write_text("A note.\n")

    answer = orch_sh(tmp_path, spec_flow, seed, "spec", "comment", str(note),
                     path=python3_shim(tmp_path))

    assert answer == ("", "", 0)
    assert comments_of(seed.store, 14) == ["A note.\n"]
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_spec_comments_writes_the_flow_issue_s_comments_through_the_python_noun(
        tmp_path, spec_flow, seed):
    seed.comment(14, "pat", "2026-09-02T11:30:00Z", "A follow-up.")
    out = tmp_path / "comments.md"

    answer = orch_sh(tmp_path, spec_flow, seed, "spec", "comments", str(out),
                     path=python3_shim(tmp_path))

    assert answer == ("", "", 0)
    assert out.read_text() == "<!-- comment @pat 2026-09-02T11:30:00Z -->\nA follow-up.\n"
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_spec_pause_writes_the_marker_and_the_block_through_the_python_noun(
        tmp_path, spec_flow, seed):
    answer = orch_sh(tmp_path, spec_flow, seed, "spec", "pause", knobs=CLAUDE,
                     path=python3_shim(tmp_path))

    assert answer == ("Spec #14 written. The spec review runs in a fresh session.\n\n"
                      "  Next: /clear, then /orchestrator:next\n", "", 0)
    assert (spec_flow / ".orchestrator" / "handoff" / "spec-paused").read_text() == "14\n"
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_spec_round_dir_makes_the_round_ready_through_the_python_noun(
        tmp_path, spec_flow, seed):
    answer = orch_sh(tmp_path, spec_flow, seed, "spec", "round-dir", "1/2",
                     path=python3_shim(tmp_path))

    rounds = spec_flow / ".orchestrator" / "spec-rounds"
    assert answer == ("%s/1/\n" % rounds, "", 0)
    assert list((rounds / "1").iterdir()) == []
    assert (spec_flow / ".orchestrator" / "handoff" / "spec-round").read_text() == "14 1 2\n"
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_spec_round_reads_the_round_marker_through_the_python_noun(tmp_path, spec_flow, seed):
    handoff = spec_flow / ".orchestrator" / "handoff"
    handoff.mkdir()
    (handoff / "spec-round").write_text("14 2 3\n")

    answer = orch_sh(tmp_path, spec_flow, seed, "spec", "round", path=python3_shim(tmp_path))

    assert answer == ("2 3\n", "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_spec_pause_round_in_an_autopilot_flow_frees_the_claim_through_the_python_noun(
        tmp_path, spec_flow, seed):
    seed.issue(14, "open", "orch:spec", "orch:running")
    seed.claim(14)

    answer = orch_sh(tmp_path, spec_flow, seed, "spec", "pause", "--round", "1/2",
                     knobs=dict(CLAUDE, ORCH_AUTOPILOT="1"), path=python3_shim(tmp_path))

    assert answer == ("Spec review round 1 of 2 applied. Round 2 runs in a fresh session.\n\n"
                      "  Next: /clear, then /orchestrator:next\n", "", 0)
    assert (spec_flow / ".orchestrator" / "handoff" / "spec-round").read_text() == "14 2 2\n"
    assert labels_of(seed.store, 14) == ["orch:spec"]
    assert seed.claim_held(14) is False
    assert (tmp_path / "shim.log").read_text() == "ran\n"


@pytest.mark.parametrize("argv, named", [(("wipe",), "wipe"), ((), "<none>")],
                         ids=["unknown", "bare"])
def test_a_spec_op_the_noun_does_not_have_is_refused_through_the_python_noun(
        tmp_path, spec_flow, seed, argv, named):
    answer = orch_sh(tmp_path, spec_flow, seed, "spec", *argv, path=python3_shim(tmp_path))

    assert answer == ("", "orch: unknown spec op: %s"
                          " (want fetch|update|comment|comments|pause|round|round-dir)\n"
                          % named, 1)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_help_lists_every_spec_verb(tmp_path, repo, seed):
    out, err, code = orch_sh(tmp_path, repo, seed, "help")

    assert (err, code) == ("", 0)
    assert [line.split()[1] for line in out.splitlines() if line.startswith("  spec ")] == [
        "fetch", "update", "comment", "comments", "pause", "pause", "round-dir", "round"]


# --- parallel and route ------------------------------------------------------


def git_config(tmp_path, repo, *args):
    """`git config <args>` in <repo>, HOME tmp_path, as orch_sh runs."""
    env = dict(os.environ, HOME=str(tmp_path))
    for name in GLOBAL_CONFIG:
        env.pop(name, None)
    run_git(repo, "config", *args, env=env)


def test_parallel_show_prints_the_default_cap_through_the_python_noun(tmp_path, repo, seed):
    answer = orch_sh(tmp_path, repo, seed, "parallel", "show", path=python3_shim(tmp_path),
                     unset=GLOBAL_CONFIG)

    assert answer == ("3\n", "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_parallel_show_prints_a_padded_cap_trimmed_through_the_python_noun(
        tmp_path, repo, seed):
    git_config(tmp_path, repo, "orchestrator.parallel", " 5")

    assert orch_sh(tmp_path, repo, seed, "parallel", "show", unset=GLOBAL_CONFIG) == (
        "5\n", "", 0)


def test_route_show_reads_the_global_route_and_the_local_one_over_it(tmp_path, repo, seed):
    git_config(tmp_path, repo, "--global", "orchestrator.route", "quick")
    global_only = orch_sh(tmp_path, repo, seed, "route", "show", path=python3_shim(tmp_path),
                          unset=GLOBAL_CONFIG)
    git_config(tmp_path, repo, "orchestrator.route", "blueprint")

    assert global_only == ("quick\n", "", 0)
    assert orch_sh(tmp_path, repo, seed, "route", "show", unset=GLOBAL_CONFIG) == (
        "blueprint\n", "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_route_show_prints_a_padded_route_trimmed_through_the_python_noun(
        tmp_path, repo, seed):
    git_config(tmp_path, repo, "orchestrator.route", "flow ")

    assert orch_sh(tmp_path, repo, seed, "route", "show", unset=GLOBAL_CONFIG) == (
        "flow\n", "", 0)


def test_help_lists_parallel_show_beside_base_and_route_show(tmp_path, repo, seed):
    out, err, code = orch_sh(tmp_path, repo, seed, "help")
    lines = out.splitlines()
    after_base_clear = next(i for i, line in enumerate(lines) if line.startswith("  base clear"))

    assert (err, code) == ("", 0)
    assert any(line.startswith("  parallel show ") for line in lines[after_base_clear:][:4])
    assert any(line.startswith("  route show ") for line in lines)
    assert "### Default route" in (SCRIPTS.parent / "docs" / "how-it-works.md").read_text(
        ).splitlines()


# --- glossary -----------------------------------------------------------------

# Two entries, the second with an avoided alias.
GLOSSARY = ("# Glossary\n\n**Flow**:\nOne run of the pipeline.\n\n"
            "- **Round**: One review of the spec.\n  _Avoid_: pass.\n")
FLOW_ENTRY = "**Flow**:\nOne run of the pipeline.\n"
ROUND_ENTRY = "- **Round**: One review of the spec.\n  _Avoid_: pass.\n"


def test_glossary_terms_lists_the_root_glossary_s_terms_through_the_python_noun(
        tmp_path, repo, seed):
    (repo / "GLOSSARY.md").write_text(GLOSSARY)

    answer = orch_sh(tmp_path, repo, seed, "glossary", "terms", path=python3_shim(tmp_path))

    assert answer == ("Flow\nRound\n", "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_glossary_show_warns_of_a_missing_term_after_the_entries_it_found(
        tmp_path, repo, seed):
    (repo / "GLOSSARY.md").write_text(GLOSSARY)

    answer = orch_sh(tmp_path, repo, seed, "glossary", "show", "Nonesuch", "Flow", "Round",
                     "Other", joined=True)

    assert answer == (FLOW_ENTRY + "\n" + ROUND_ENTRY
                      + "orch: no glossary entry for 'Nonesuch'\n"
                      "orch: no glossary entry for 'Other'\n", "", 1)


def test_glossary_match_prints_the_entries_a_file_mentions_through_the_python_noun(
        tmp_path, repo, seed):
    (repo / "GLOSSARY.md").write_text(GLOSSARY)
    text = tmp_path / "text.md"
    text.write_text("Each\nPASS of the review.\n")

    answer = orch_sh(tmp_path, repo, seed, "glossary", "match", str(text),
                     path=python3_shim(tmp_path))

    assert answer == (ROUND_ENTRY, "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_an_unknown_glossary_op_is_refused_through_the_python_noun(tmp_path, repo, seed):
    answer = orch_sh(tmp_path, repo, seed, "glossary", "list", path=python3_shim(tmp_path))

    assert answer == ("", "orch: unknown glossary op: list (want terms|show|match)\n", 2)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_help_lists_the_glossary_verbs_and_the_entry_grammar(tmp_path, repo, seed):
    out, err, code = orch_sh(tmp_path, repo, seed, "help")

    assert (err, code) == ("", 0)
    assert "glossary terms" in out
    assert "glossary show <term>..." in out
    assert "glossary match <file>..." in out
    assert "optionally after a - or * bullet" in out
    assert "no entries is an error" in out


# --- agent --------------------------------------------------------------------


def py38_path(tmp_path):
    """A python3 first on PATH that fakes sys.version_info 3.8.10 before
    running `-c <code>` on this interpreter: that PATH."""
    shim_dir = tmp_path / "py38"
    shim_dir.mkdir(exist_ok=True)
    shim = shim_dir / "python3"
    shim.write_text(
        '#!/bin/sh\n'
        'code="$2"\n'
        'shift 2\n'
        'exec "%s" -c \'import sys; sys.version_info = (3, 8, 10, "final", 0);'
        ' exec(sys.argv.pop(1))\' "$code" "$@"\n' % sys.executable
    )
    shim.chmod(0o755)
    return "%s%s%s" % (shim_dir, os.pathsep, os.environ["PATH"])


def test_agent_roles_prints_the_canonical_roles_through_the_python_noun(tmp_path, repo, seed):
    answer = orch_sh(tmp_path, repo, seed, "agent", "roles", path=python3_shim(tmp_path),
                     unset=GLOBAL_CONFIG)

    assert answer == (
        "implementer\nlens\nreviewer\nfixer\ncloser\nresolver\nauditor\n", "", 0
    )
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_agent_set_get_show_and_clear_round_trip_through_the_python_noun(tmp_path, repo, seed):
    path = python3_shim(tmp_path)

    assert orch_sh(tmp_path, repo, seed, "agent", "set", "implementer",
                   "--model", "sonnet", "--effort", "high",
                   path=path, unset=GLOBAL_CONFIG) == ("", "", 0)
    assert orch_sh(tmp_path, repo, seed, "agent", "set", "lens",
                   "--model", "opus", "--global",
                   path=path, unset=GLOBAL_CONFIG) == ("", "", 0)
    assert orch_sh(tmp_path, repo, seed, "agent", "get", "implementer",
                   path=path, unset=GLOBAL_CONFIG) == ("model sonnet\neffort high\n", "", 0)
    assert orch_sh(tmp_path, repo, seed, "agent", "get", "lens",
                   path=path, unset=GLOBAL_CONFIG) == ("model opus\neffort inherit\n", "", 0)

    out, err, code = orch_sh(tmp_path, repo, seed, "agent", "show",
                             path=path, unset=GLOBAL_CONFIG)
    assert (err, code) == ("", 0)
    lines = out.splitlines()
    assert "implementer model sonnet (local) effort high (local)" in lines
    assert "lens model opus (global) effort inherit (inherit)" in lines
    assert "junie implementer model inherit (inherit) effort inherit (inherit)" in lines

    assert orch_sh(tmp_path, repo, seed, "agent", "clear", "implementer",
                   path=path, unset=GLOBAL_CONFIG) == ("", "", 0)
    assert orch_sh(tmp_path, repo, seed, "agent", "clear", "lens", "--global",
                   path=path, unset=GLOBAL_CONFIG) == ("", "", 0)
    assert orch_sh(tmp_path, repo, seed, "agent", "get", "implementer",
                   path=path, unset=GLOBAL_CONFIG) == ("model inherit\neffort inherit\n", "", 0)
    assert orch_sh(tmp_path, repo, seed, "agent", "get", "lens",
                   path=path, unset=GLOBAL_CONFIG) == ("model inherit\neffort inherit\n", "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n" * 9


def test_agent_sync_writes_and_prunes_junie_copies_through_the_python_noun(tmp_path, repo, seed):
    git_config(tmp_path, repo, "orchestrator.junie.model.implementer", "claude-sonnet-4-5")
    git_config(tmp_path, repo, "orchestrator.junie.effort.implementer", "high")
    path = python3_shim(tmp_path)

    assert orch_sh(tmp_path, repo, seed, "agent", "sync",
                   path=path, unset=GLOBAL_CONFIG) == ("", "", 0)
    copy = repo / ".junie" / "agents" / "orch-implementer.md"
    assert copy.is_file()
    assert copy.read_text().startswith(
        "---\n# written by orch.sh agent sync\nmodel: claude-sonnet-4-5\nreasoningLevel: high\n"
    )
    assert ".junie/agents/orch-*.md" in (repo / ".git" / "info" / "exclude").read_text().splitlines()

    assert orch_sh(tmp_path, repo, seed, "agent", "clear", "implementer", "--host", "junie",
                   path=path, unset=GLOBAL_CONFIG) == ("", "", 0)
    assert not copy.exists()
    assert (tmp_path / "shim.log").read_text() == "ran\nran\n"


def test_agent_sync_resolves_the_default_plugin_root_through_a_symlinked_install(
        tmp_path, repo, seed):
    # Install directory with symlinked scripts/ and no local agents/ proves
    # default_plugin_root follows symlinks back to the real plugin root.
    install = tmp_path / "symlinked-install"
    install.mkdir()
    (install / "scripts").symlink_to(SCRIPTS)
    git_config(tmp_path, repo, "orchestrator.junie.model.implementer", "claude-sonnet-4-5")

    answer = orch_sh(tmp_path, repo, seed, "agent", "sync",
                     path=python3_shim(tmp_path), unset=GLOBAL_CONFIG,
                     script=install / "scripts" / "orch.sh")

    assert answer == ("", "", 0)
    copy = repo / ".junie" / "agents" / "orch-implementer.md"
    assert copy.is_file()
    text = copy.read_text()
    assert text.startswith("---\n# written by orch.sh agent sync\nmodel: claude-sonnet-4-5\n")
    assert "name: orch-implementer\n" in text
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_an_unknown_agent_op_is_refused_through_the_python_noun(tmp_path, repo, seed):
    answer = orch_sh(tmp_path, repo, seed, "agent", "wipe",
                     path=python3_shim(tmp_path), unset=GLOBAL_CONFIG)

    assert answer == (
        "", "orch: unknown agent op: wipe (want set|show|clear|get|sync|roles)\n", 1
    )
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_agent_refuses_when_python3_is_missing_or_below_3_9(tmp_path, repo, seed):
    missing = orch_sh(tmp_path, repo, seed, "agent", "roles",
                      path=path_without(tmp_path, "python3"), unset=GLOBAL_CONFIG)
    too_old = orch_sh(tmp_path, repo, seed, "agent", "roles",
                      path=py38_path(tmp_path), unset=GLOBAL_CONFIG)

    assert missing == (
        "",
        "orch: orch.sh agent needs python3 3.9 or newer (found none) - run orch.sh doctor\n",
        1,
    )
    assert too_old == (
        "",
        "orch: orch.sh agent needs python3 3.9 or newer (found 3.8.10) - run orch.sh doctor\n",
        1,
    )


# --- slug, status, init, archive and help --------------------------------

HELP_GOLDEN = Path(__file__).resolve().parent / "help" / "golden.txt"


def test_slug_prints_the_normalized_slug_through_the_python_noun(tmp_path, repo, seed):
    assert orch_sh(tmp_path, repo, seed, "slug", "My Feature!!", path=python3_shim(tmp_path)) == (
        "my-feature\n", "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_status_prints_the_flow_lines_through_the_python_noun(tmp_path, repo, seed):
    flow_state(repo, "spec", 12, "orch/12-x")
    (repo / ".orchestrator" / "handoff").mkdir()
    (repo / ".orchestrator" / "handoff" / "01-plan.md").write_text("")

    assert orch_sh(tmp_path, repo, seed, "status", path=python3_shim(tmp_path),
                   knobs={"CLAUDECODE": "1"}) == (
        "flow:      x\n"
        "phase:     spec\n"
        "issue:     12\n"
        "base:      main\n"
        "branch:    orch/12-x\n"
        "PR:        -\n"
        "review:    iteration 0 of 5\n"
        "redo:      0\n"
        "\n"
        "handoffs:\n"
        "  .orchestrator/handoff/01-plan.md\n", "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_archive_moves_the_flow_into_the_archive_through_the_python_noun(tmp_path, repo, seed):
    flow_state(repo, "done", 12)

    out, err, code = orch_sh(tmp_path, repo, seed, "archive", path=python3_shim(tmp_path))

    assert (err, code) == ("", 0)
    assert re.fullmatch(r"\.orchestrator/archive/[0-9]{8}-[0-9]{6}-x\n", out)
    assert (repo / out.strip() / "state.json").is_file()
    assert not (repo / ".orchestrator" / "state.json").exists()
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_init_starts_a_flow_on_an_adopted_issue_through_the_python_noun(tmp_path, repo, seed):
    seed.issue(12, "open", "ready-for-agent")
    run_git(repo, "config", "orchestrator.base", "main")

    assert orch_sh(tmp_path, repo, seed, "init", "My Feature!!", "--issue", "12",
                   path=python3_shim(tmp_path)) == ("my-feature\n", "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"
    state = json.loads((repo / ".orchestrator" / "state.json").read_text())
    assert (state["slug"], state["phase"], state["issue"], state["base"]) == \
        ("my-feature", "spec", 12, "main")


@pytest.mark.parametrize("argv", [("help",), ("-h",), ("--help",), ()],
                         ids=["help", "-h", "--help", "bare"])
def test_every_help_spelling_prints_the_golden_text_through_the_python_noun(
        tmp_path, repo, seed, argv):
    out, err, code = orch_sh(tmp_path, repo, seed, *argv, path=python3_shim(tmp_path))

    assert (out.encode("utf-8"), err, code) == (HELP_GOLDEN.read_bytes(), "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"


def test_help_dies_pointing_at_doctor_without_python3(tmp_path, repo, seed):
    assert orch_sh(tmp_path, repo, seed, "help", path=path_without(tmp_path, "python3")) == (
        "", "orch: orch.sh help needs python3 3.9 or newer (found none) - run orch.sh doctor\n", 1)


def test_help_in_an_empty_home_still_builds_the_stub_cache(tmp_path, repo, seed):
    """The test runner seeds every section's stub cache by running orch.sh help
    in an empty HOME: orch.sh builds the cache before its dispatch hands help
    to Python."""
    assert not (tmp_path / ".cache").exists()

    assert orch_sh(tmp_path, repo, seed, "help")[1:] == ("", 0)
    assert list((tmp_path / ".cache" / "orchestrator").iterdir())


def test_help_into_a_pipe_closed_unread_dies_of_sigpipe_as_cat_did(tmp_path, repo, seed):
    """The text is longer than a pipe holds, so a reader that reads none of it
    stops the writer, silently, with the status SIGPIPE gives."""
    answer = bash_run(tmp_path, repo, ["-c", 'set -o pipefail; "$1" help | true', "_",
                                       str(SCRIPTS / "orch.sh")],
                      knobs={"ORCH_GH_FAKE_STORE": seed.store})

    assert answer == ("", "", 141)


# --- phase -----------------------------------------------------------------


def test_phase_advance_records_the_next_phase_and_prints_the_boundary_through_the_python_noun(
        tmp_path, repo, seed):
    flow_state(repo, "spec", 12)
    spec = repo / ".orchestrator" / "handoff" / "02-spec.md"
    spec.parent.mkdir()
    spec.write_text("## Spec issue\n#12.\n")

    assert orch_sh(tmp_path, repo, seed, "phase", "advance", path=python3_shim(tmp_path),
                   knobs={"ORCHESTRATOR_HOST": "junie"}) == (
        "Phase spec complete. Handoff written to %s.\n\n"
        "  Next: /new, then ask for the next phase with /orch-flow\n" % spec, "", 0)
    assert (tmp_path / "shim.log").read_text() == "ran\n"
    assert json.loads((repo / ".orchestrator" / "state.json").read_text())["phase"] == "implement"


def test_phase_dies_pointing_at_doctor_without_python3(tmp_path, repo, seed):
    flow_state(repo, "spec", 12)

    assert orch_sh(tmp_path, repo, seed, "phase", "boundary", path=path_without(tmp_path, "python3")) \
        == ("", "orch: orch.sh phase needs python3 3.9 or newer (found none)"
                " - run orch.sh doctor\n", 1)


# --- orch_python_call bootstrap ----------------------------------------------


def source_orch_sh(tmp_path, cwd, script, path=None, knobs=None, unset=()):
    """bash <script> with $1 = scripts/orch.sh, run by bash_run."""
    return bash_run(
        tmp_path, cwd, ["-euo", "pipefail", "-c", script, "_", str(SCRIPTS / "orch.sh")],
        path=path, knobs=knobs, unset=unset,
    )


def test_orch_python_call_runs_without_exec_and_returns_exit_code(tmp_path, repo):
    git_config(tmp_path, repo, "orchestrator.route", "quick")
    script = (
        'source "$1"\n'
        'orch_python_call route run show\n'
        'st=0; orch_python_call route run bogus 2>&1 || st=$?\n'
        'printf "after:%s\\n" "$st"\n'
    )

    out, err, code = source_orch_sh(tmp_path, repo, script, unset=GLOBAL_CONFIG)

    assert (err, code) == ("", 0)
    assert out == (
        "quick\n"
        "orch: unknown route op: bogus (want show)\n"
        "after:1\n"
    )


@pytest.mark.parametrize("module", ["json.py", "orch.py"])
def test_orch_python_call_drops_empty_sys_path_entry_so_cwd_modules_cannot_shadow(
        tmp_path, repo, module):
    (repo / module).write_text("import sys\nsys.stderr.write('shadowed\\n')\nsys.exit(7)\n")
    script = 'source "$1"\norch_python_call agent check_settings\n'

    out, err, code = source_orch_sh(tmp_path, repo, script, unset=GLOBAL_CONFIG)

    assert (err, code) == ("", 0)
    assert out.startswith("ok\tagent implementer: model inherit (inherit), effort inherit (inherit)\0")


@pytest.mark.parametrize("given", [None, "", "/the/caller/s/path"],
                         ids=["unset", "empty", "set"])
def test_orch_python_call_restores_callers_pythonpath_for_subprocesses(tmp_path, repo, given):
    real_git = shutil.which("git")
    shim_dir = tmp_path / "git-shim"
    shim_dir.mkdir()
    log = tmp_path / "pythonpath.log"
    shim = shim_dir / "git"
    shim.write_text(
        '#!/bin/sh\n'
        'printf "%%s\\n" "${PYTHONPATH-unset}" >>"%s"\n'
        'exec "%s" "$@"\n' % (log, real_git)
    )
    shim.chmod(0o755)
    script = (
        'source "$1"\n'
        'PATH="%s:$PATH" orch_python_call agent check_settings\n' % shim_dir
    )
    knobs = {} if given is None else {"PYTHONPATH": given}
    unset = GLOBAL_CONFIG + (("PYTHONPATH",) if given is None else ())

    out, err, code = source_orch_sh(tmp_path, repo, script, knobs=knobs, unset=unset)

    assert (err, code) == ("", 0)
    assert out.startswith("ok\tagent implementer: model inherit (inherit), effort inherit (inherit)\0")
    seen = log.read_text().splitlines()
    assert seen and all(line == ("unset" if given is None else given) for line in seen)


@pytest.mark.parametrize("path_of, found", [
    (lambda tmp_path: path_without(tmp_path, "python3"), "none"),
    (py38_path, "3.8.10"),
], ids=["missing", "below-3.9"])
def test_orch_python_call_refuses_cleanly_without_python3_3_9(tmp_path, repo, path_of, found):
    script = (
        'source "$1"\n'
        'st=0; orch_python_call route run show || st=$?\n'
        'printf "after:%s\\n" "$st"\n'
    )

    out, err, code = source_orch_sh(
        tmp_path, repo, script, path=path_of(tmp_path), unset=GLOBAL_CONFIG
    )

    assert (out, err, code) == (
        "after:1\n",
        "orch: orch.sh route needs python3 3.9 or newer (found %s) - run orch.sh doctor\n" % found,
        0,
    )


@pytest.mark.parametrize("path_of, found", [
    (lambda tmp_path: path_without(tmp_path, "python3"), "none"),
    (py38_path, "3.8.10"),
], ids=["missing", "below-3.9"])
def test_orch_python_call_names_the_command_given_by_as_in_its_refusal(
        tmp_path, repo, path_of, found):
    script = (
        'source "$1"\n'
        'st=0; orch_python_call --as autopilot route run show || st=$?\n'
        'printf "after:%s\\n" "$st"\n'
    )

    out, err, code = source_orch_sh(
        tmp_path, repo, script, path=path_of(tmp_path), unset=GLOBAL_CONFIG
    )

    assert (out, err, code) == (
        "after:1\n",
        "orch: orch.sh autopilot needs python3 3.9 or newer (found %s) - run orch.sh doctor\n"
        % found,
        0,
    )


@pytest.mark.parametrize("args", [["--as"], ["--as", "autopilot", "route"], ["--as", "", "route", "run"]],
                         ids=["as-alone", "as-without-func", "as-empty"])
def test_orch_python_call_refuses_an_incomplete_call_with_its_usage(tmp_path, repo, args):
    script = (
        'source "$1"\n'
        'shift\n'
        'st=0; orch_python_call "$@" || st=$?\n'
        'printf "after:%s\\n" "$st"\n'
    )

    out, err, code = bash_run(
        tmp_path, repo,
        ["-euo", "pipefail", "-c", script, "_", str(SCRIPTS / "orch.sh"), *args],
        unset=GLOBAL_CONFIG,
    )

    assert (out, err, code) == (
        "after:1\n",
        "orch: usage: orch_python_call [--as <command>] <noun> <func> [<arg>...]\n",
        0,
    )
