"""`orch.sh branch create|off|busy|base-sha|retire` and the noun's dispatch,
called in-process through the branch module's run: create, off, busy and
retire against FakeGit and the gh fake, base-sha against real repositories
with a real origin under tmp_path, since its fallback is git's merge-base,
which a fake would only restate - as are create's and off's full-ref naming
beside same-named tags and git's own refusal of a clashing checkout. Each
message, exit code and order of checks is the bash noun's, verbatim."""
from __future__ import annotations

import json
import subprocess

import pytest

from conftest import (GITHUB_ORIGIN, committed, exclude_orchestrator, fake, hold_flow,
                      origin_clone, outcome, run_git, state_json)
from orch import branch as module
from orch.git import FakeGit, Git, Worktree

ROOT = "/nonexistent/checkout"


def orch(capsys, *argv, git=None, env=None, gh=None):
    """`orch.sh branch <argv>` in-process, through <git> (a FakeGit at ROOT
    when None) and the gh adapter <gh>: (exit code, stdout, stderr)."""
    git = FakeGit(toplevel=ROOT) if git is None else git
    return outcome(capsys, lambda: module.run(
        list(argv), gh=gh, git=git, env={} if env is None else env))


# --- the dispatch ----------------------------------------------------------------------


@pytest.mark.parametrize("argv, named", [(("bogus",), "bogus"), ((), "<none>")],
                         ids=["unknown", "missing"])
def test_an_unknown_or_missing_op_is_refused_naming_the_six(capsys, argv, named):
    assert orch(capsys, *argv) == (1, "", (
        "orch: unknown branch op: %s (want create|off|busy|base-sha|sync|retire)\n" % named))


# --- off -------------------------------------------------------------------------------

NAME = "quick/9-widgets"
OFF_USAGE = "orch: usage: orch.sh branch off <name>\n"
ORIGIN_TIP, LOCAL_TIP = "a" * 40, "b" * 40
ABORT = "/orchestrator:abort (or orch-flow's Abort section)"


def forking(tmp_path, base="main", on="main", dirty=(), fetched=True, branches=(), **config):
    """A FakeGit at tmp_path on <on> (None for a detached HEAD), <dirty> changed (a str for a status
    that cannot run), its local config holding <config> (each key's - spelled
    _ and . spelled __), local branch <base> at LOCAL_TIP beside <branches>,
    origin's <base> at ORIGIN_TIP, its fetch working when <fetched>."""
    local = {key.replace("__", ".").replace("_", "-"): value for key, value in config.items()}
    git = FakeGit(toplevel=str(tmp_path), local_config=local,
                  branches=dict.fromkeys(b for b in (base, on) + tuple(branches) if b))
    git.seed("current_branch", answer=on)
    git.seed("dirty_paths", answer=dirty if isinstance(dirty, str) else list(dirty))
    git.seed("fetch_default_branch", base, answer=fetched)
    git.seed("resolve_commit", "refs/remotes/origin/" + base, answer=ORIGIN_TIP)
    git.seed("resolve_commit", "refs/heads/" + base, answer=LOCAL_TIP)
    return git


def off(capsys, seed, git, *argv):
    return orch(capsys, "off", *argv, git=git, gh=fake(seed))


def facts(git):
    """What a refused off must leave as it was: the local branches, the
    current branch and the local git config."""
    return (dict(git.branches), git.current_branch(), git.config_regexp("local", "."))


def recorded(git, name=NAME):
    """The base and base SHA <name> records, the branch checked out and its
    upstream."""
    return (git.config_value("branch.%s.orchestrator-base" % name),
            git.config_value("branch.%s.orchestrator-base-sha" % name),
            git.current_branch(), git.branch_upstream(name))


def test_off_forks_from_origin_s_base_records_it_with_no_upstream_and_prints_the_name(
        tmp_path, seed, capsys):
    git = forking(tmp_path)

    assert off(capsys, seed, git, NAME) == (0, NAME + "\n", "")
    assert recorded(git) == ("main", ORIGIN_TIP, NAME, None)
    assert not (tmp_path / ".orchestrator").exists()


def test_off_forks_from_the_base_setting_over_the_default_branch(tmp_path, seed, capsys):
    git = forking(tmp_path, base="uat", orchestrator__base="uat")

    assert off(capsys, seed, git, NAME) == (0, NAME + "\n", "")
    assert recorded(git) == ("uat", ORIGIN_TIP, NAME, None)


def test_with_no_base_setting_off_forks_from_the_default_branch(tmp_path, seed, capsys):
    git = forking(tmp_path, base="trunk", on="trunk")
    git.seed("origin_head_branch", answer="trunk")
    git.seed("is_branch_name", "trunk", answer=True)

    assert off(capsys, seed, git, NAME) == (0, NAME + "\n", "")
    assert recorded(git) == ("trunk", ORIGIN_TIP, NAME, None)


@pytest.mark.parametrize("argv", [(), (NAME, "extra")], ids=["none", "two"])
def test_off_with_no_name_or_more_than_one_is_a_usage_error(tmp_path, seed, capsys, argv):
    assert off(capsys, seed, forking(tmp_path), *argv) == (1, "", OFF_USAGE)


def test_off_s_usage_error_comes_before_the_busy_refusal(tmp_path, seed, capsys):
    # Both its first checks broken: no name, and a flow mid-pipeline.
    hold_flow(tmp_path, slug="busy", phase="implement")

    assert off(capsys, seed, forking(tmp_path)) == (1, "", OFF_USAGE)


@pytest.mark.parametrize("phase", ["spec", "implement", "review"])
def test_off_beside_a_flow_mid_pipeline_exits_3_writing_nothing(tmp_path, seed, capsys, phase):
    hold_flow(tmp_path, slug="busy", phase=phase)
    git = forking(tmp_path)
    before = facts(git)

    assert off(capsys, seed, git, NAME) == (3, "", (
        "orch: busy: a flow is mid-pipeline (slug: busy, phase: %s)\n"
        "     One flow at a time - finish it, or run %s.\n" % (phase, ABORT)))
    assert facts(git) == before


def test_off_beside_an_unreadable_state_json_exits_3_writing_nothing(tmp_path, seed, capsys):
    hold_flow(tmp_path).write_text("{\"slug\": \"held\", \"pha")
    git = forking(tmp_path)
    before = facts(git)

    assert off(capsys, seed, git, NAME) == (3, "", (
        "orch: busy: a flow's state.json cannot be read\n"
        "     Run orch.sh doctor --flow, or %s.\n" % ABORT))
    assert facts(git) == before


def test_off_beside_a_done_flow_forks(tmp_path, seed, capsys):
    hold_flow(tmp_path, slug="finished", phase="done")
    git = forking(tmp_path)

    assert off(capsys, seed, git, NAME) == (0, NAME + "\n", "")
    assert recorded(git) == ("main", ORIGIN_TIP, NAME, None)


def test_off_on_a_plugin_made_branch_with_no_pr_exits_3_writing_nothing(tmp_path, seed, capsys):
    git = forking(tmp_path, on="quick/1-running", dirty=["README.md"],
                  **{"branch__quick/1-running__orchestrator_base": "main"})
    before = facts(git)

    assert off(capsys, seed, git, NAME) == (3, "", (
        "orch: busy: branch quick/1-running has no PR yet\n"
        "     Open its PR, or switch off it.\n"))
    assert facts(git) == before


def test_off_on_a_branch_a_redo_retired_is_not_busy(tmp_path, seed, capsys):
    git = forking(tmp_path, on="quick/1-old-redo-1",
                  **{"branch__quick/1-old-redo-1__orchestrator_base": "main",
                     "branch__quick/1-old-redo-1__orchestrator_retired": "true"})

    assert off(capsys, seed, git, NAME) == (0, NAME + "\n", "")


def test_off_on_a_tree_dirty_outside_the_allowlist_exits_3_writing_nothing(
        tmp_path, seed, capsys):
    git = forking(tmp_path, dirty=["README.md", "docs/agents/note.md"])
    before = facts(git)

    assert off(capsys, seed, git, NAME) == (3, "", (
        "orch: busy: the working tree has changes outside the planning allowlist: README.md\n"
        "     Commit, stash, or discard these changes.\n"))
    assert facts(git) == before


def test_off_with_only_an_allowlisted_edit_forks(tmp_path, seed, capsys):
    git = forking(tmp_path, dirty=["docs/agents/note.md"])

    assert off(capsys, seed, git, NAME) == (0, NAME + "\n", "")
    assert recorded(git) == ("main", ORIGIN_TIP, NAME, None)


def test_off_on_a_tree_that_cannot_be_read_exits_1_writing_nothing(tmp_path, seed, capsys):
    git = forking(tmp_path, dirty="fatal: index file corrupt")
    before = facts(git)

    assert off(capsys, seed, git, NAME) == (1, "", (
        "orch: git status failed - cannot check the working tree: fatal: index file corrupt\n"))
    assert facts(git) == before


def test_off_refuses_a_busy_checkout_ahead_of_a_taken_name(tmp_path, seed, capsys):
    git = forking(tmp_path, dirty=["README.md"], branches=(NAME,))

    assert off(capsys, seed, git, NAME)[0] == 3


def test_off_refuses_a_name_already_taken_writing_nothing(tmp_path, seed, capsys):
    git = forking(tmp_path, branches=(NAME,))
    before = facts(git)

    assert off(capsys, seed, git, NAME) == (1, "", "orch: branch %s already exists\n" % NAME)
    assert facts(git) == before


def test_off_refuses_a_base_origin_says_is_gone_with_the_default_remedy(tmp_path, seed, capsys):
    git = forking(tmp_path, fetched=False)
    git.seed("origin_has_branch", "main", answer=False)
    git.seed("ref_exists", "refs/remotes/origin/main", answer=True)
    before = facts(git)

    assert off(capsys, seed, git, NAME) == (1, "", (
        "orch: base branch main does not exist on origin - push it, or start again on another"
        " base branch\n"))
    assert facts(git) == before


def test_off_dies_when_the_fetch_fails_while_origin_has_the_base(tmp_path, seed, capsys):
    git = forking(tmp_path, fetched=False)
    git.seed("origin_has_branch", "main", answer=True)
    git.seed("ref_exists", "refs/remotes/origin/main", answer=True)
    before = facts(git)

    assert off(capsys, seed, git, NAME) == (1, "", "orch: could not fetch main from origin\n")
    assert facts(git) == before


@pytest.mark.parametrize("tracked, tip", [(True, ORIGIN_TIP), (False, LOCAL_TIP)],
                         ids=["origin-s-local-ref", "local-base"])
def test_with_origin_unreachable_off_forks_from_origin_s_local_ref_else_the_local_base(
        tmp_path, seed, capsys, tracked, tip):
    git = forking(tmp_path, fetched=False)
    git.seed("ref_exists", "refs/remotes/origin/main", answer=tracked)

    assert off(capsys, seed, git, NAME) == (0, NAME + "\n", "")
    assert recorded(git) == ("main", tip, NAME, None)


def test_a_record_git_refuses_ends_off_with_git_s_status_and_stderr(tmp_path, seed, capsys):
    # As bash's set -e did: git's own refusal, no orch: line, no name printed.
    git = forking(tmp_path)
    git.config_write_fails.add(("local", "branch.%s.orchestrator-base" % NAME))

    assert off(capsys, seed, git, NAME) == (
        255, "", "error: could not lock config file .git/config: File exists\n")
    assert git.config_value("branch.%s.orchestrator-base-sha" % NAME) is None


@pytest.fixture
def off_repo(tmp_path):
    """A clone of a bare origin holding main two commits deep, origin/HEAD
    naming it, on main one commit behind origin's: (clone, origin's tip,
    the local tip)."""
    root = tmp_path / "repo"
    origin_clone(tmp_path / "origin.git", root, "main")
    run_git(root, "checkout", "-qb", "main")
    committed(root, {"docs/agents/notes.md": "one\n"}, "notes")
    committed(root, {"docs/agents/notes.md": "two\n"}, "origin moves notes")
    run_git(root, "push", "-q", "origin", "HEAD:refs/heads/main")
    run_git(root, "reset", "-q", "--hard", "HEAD~1")
    run_git(root, "fetch", "-q", "origin")
    run_git(root, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    return root, head_of(root, "refs/remotes/origin/main"), head_of(root, "HEAD")


def repo_facts(root, name):
    """Whether <name> exists, the base SHA it records, and the branch checked
    out, in the real repository at <root>."""
    made = run_git(root, "for-each-ref", "--format=made", "refs/heads/" + name) or "none"
    sha = subprocess.run(["git", "-C", str(root), "config", "--get",
                          "branch.%s.orchestrator-base-sha" % name],
                         stdout=subprocess.PIPE, stdin=subprocess.DEVNULL).stdout.decode().strip()
    return made, sha or "<unset>", run_git(root, "branch", "--show-current")


def test_off_beside_tags_named_like_the_branch_and_origin_s_base_forks_from_origin_s_tip(
        off_repo, seed, capsys):
    root, origin_tip, local_tip = off_repo
    for tag in (NAME, "origin/main"):
        run_git(root, "tag", tag, local_tip)

    assert orch(capsys, "off", NAME, git=Git(cwd=str(root)), gh=fake(seed)) == (
        0, NAME + "\n", "")
    assert (head_of(root, "refs/heads/" + NAME), repo_facts(root, NAME),
            run_git(root, "for-each-ref", "--format=%(upstream)", "refs/heads/" + NAME)) == (
        origin_tip, ("made", origin_tip, NAME), "")


def test_off_offline_beside_tags_named_like_the_base_forks_from_the_local_base(
        off_repo, seed, capsys, tmp_path):
    # Origin unreachable, and no remote-tracking ref of the base: neither the
    # tag named main nor the one named origin/main is taken for it, and
    # autoSetupMerge=always, which would track the local base, sets nothing.
    root, _, tagged = off_repo
    run_git(root, "config", "branch.autoSetupMerge", "always")
    run_git(root, "update-ref", "-d", "refs/remotes/origin/main")
    run_git(root, "remote", "set-url", "origin", str(tmp_path / "missing.git"))
    for tag in ("main", "origin/main"):
        run_git(root, "tag", tag, tagged)
    local_tip = committed(root, {"local.txt": "moves on\n"}, "local base moves on")

    assert orch(capsys, "off", NAME, git=Git(cwd=str(root)), gh=fake(seed)) == (
        0, NAME + "\n", "")
    assert (repo_facts(root, NAME),
            run_git(root, "for-each-ref", "--format=%(upstream)", "refs/heads/" + NAME)) == (
        ("made", local_tip, NAME), "")


def test_off_whose_checkout_clashes_with_an_edit_dies_with_git_s_message_writing_nothing(
        off_repo, seed, capsys):
    root, _, _ = off_repo
    with open(root / "docs" / "agents" / "notes.md", "a") as notes:
        notes.write("mine\n")

    code, out, err = orch(capsys, "off", "quick/7-x", git=Git(cwd=str(root)), gh=fake(seed))

    assert (code, out) == (1, "")
    assert err.startswith("orch: could not create quick/7-x from refs/remotes/origin/main: ")
    assert "would be overwritten" in err and "docs/agents/notes.md" in err
    assert repo_facts(root, "quick/7-x") == ("none", "<unset>", "main")
    assert (root / "docs" / "agents" / "notes.md").read_text() == "one\nmine\n"


# --- create ----------------------------------------------------------------------------

FLOW = "orch/11-feat"
CREATE_USAGE = "orch: usage: orch.sh branch create\n"
GONE_REMEDY = "point this flow at another base: orch.sh base set <branch> --flow"
NO_FLOW = ("orch: no active flow (.orchestrator/state.json not found). Run /orchestrator:start"
           " (or orch-flow's Starting a flow section) first.\n")
UNREADABLE = "orch: state.json cannot be read - run orch.sh doctor --flow\n"
NO_ISSUE = "orch: no issue recorded in state - the spec phase must publish one first\n"
AUTOPILOT = {"ORCH_AUTOPILOT": "1"}


def flowing(tmp_path, on="main", recorded=None, base="main", issue=11, phase="implement",
            main=True, **forked):
    """Flow feat on <issue> in the checkout at tmp_path, at <phase>, its
    state.json recording branch <recorded> and base <base> (None for no base
    key), and a FakeGit there as forking makes it on <on> (None for a
    detached HEAD), with <forked> handed on: the worktree list naming
    tmp_path the main checkout when <main>, else a hand-made worktree, and
    every step of the discard sequence working."""
    state = {"slug": "feat", "phase": phase, "issue": issue, "branch": recorded}
    if base is not None:
        state["base"] = base
    hold_flow(tmp_path, **state)
    git = forking(tmp_path, base=base or "main", on=on, **forked)
    root = str(tmp_path)
    git.checkouts[root] = root
    git.seed("branch_at", root, answer=on)
    git.seed("worktree_list", answer=[Worktree(root, on)] if main else [
        Worktree("/elsewhere/main", "main"), Worktree(root, on)])
    for step in ("merge_abort_at", "reset_hard_at", "clean_at"):
        git.seed(step, root, answer=True)
    git.seed("rebase_abort_at", root, answer=None)
    return git


def rebasing_onto(tmp_path, branch):
    """Leaves git's record of a rebase of <branch> in progress in the
    checkout at tmp_path, as a stopped rebase leaves it: HEAD detached."""
    record = tmp_path / ".git" / "rebase-merge"
    record.mkdir(parents=True)
    (tmp_path / ".git" / "HEAD").write_text(ORIGIN_TIP + "\n")
    (record / "head-name").write_text("refs/heads/%s\n" % branch)


def create(capsys, seed, git, *argv, env=None):
    return orch(capsys, "create", *argv, git=git, gh=fake(seed), env=env)


def made(tmp_path, git, name=FLOW):
    """The branch and base SHA the flow's state records, then what recorded
    says of <name>."""
    state = json.loads(state_json(tmp_path).read_text())
    return (state.get("branch"), state.get("base_sha")) + recorded(git, name)


def untouched(tmp_path, git):
    """What a create that writes nothing must leave as it was: the
    state.json's text and what facts reads."""
    return (state_json(tmp_path).read_text(),) + facts(git)


def interactive_refusal(tmp_path, dirty, merging=""):
    """The flow-branch discard's refusal in an interactive main checkout at
    tmp_path, naming <dirty> and the abort command <merging> names."""
    return ("orch: uncommitted or in-progress work on the flow's branch in the main checkout -"
            " discard it yourself (%s): %sgit -C \"%s\" reset --hard && git -C \"%s\" clean -fd\n"
            % (dirty, merging, tmp_path, tmp_path))


def foreign_refusal(branch):
    return ("orch: branch create: the current branch %s is not the flow's branch %s - nothing"
            " was discarded\n" % (branch, FLOW))


def test_create_forks_the_flow_s_branch_records_it_in_state_and_git_config_and_prints_it(
        tmp_path, seed, capsys):
    git = flowing(tmp_path)

    assert create(capsys, seed, git) == (0, FLOW + "\n", "")
    assert made(tmp_path, git) == (FLOW, ORIGIN_TIP, "main", ORIGIN_TIP, FLOW, None)


def test_create_forks_from_the_base_the_flow_records_over_the_base_setting(
        tmp_path, seed, capsys):
    git = flowing(tmp_path, base="uat", orchestrator__base="main")

    assert create(capsys, seed, git) == (0, FLOW + "\n", "")
    assert made(tmp_path, git) == (FLOW, ORIGIN_TIP, "uat", ORIGIN_TIP, FLOW, None)


def test_a_state_json_recording_no_base_forks_from_the_flow_base_fallback_s_base(
        tmp_path, seed, capsys):
    # GitHub's default branch, never the base setting or origin/HEAD's branch.
    seed.default_branch("trunk")
    git = flowing(tmp_path, base=None, orchestrator__base="uat")
    git.remotes = dict(GITHUB_ORIGIN)
    for name in ("trunk", "main", "uat"):
        git.seed("is_branch_name", name, answer=True)
    git.seed("origin_head_branch", answer="main")
    git.seed("fetch_default_branch", "trunk", answer=True)
    git.seed("resolve_commit", "refs/remotes/origin/trunk", answer=LOCAL_TIP)

    assert create(capsys, seed, git) == (0, FLOW + "\n", "")
    assert made(tmp_path, git) == (FLOW, LOCAL_TIP, "trunk", LOCAL_TIP, FLOW, None)


def test_create_on_a_plugin_made_branch_with_no_pr_exits_3_discarding_and_writing_nothing(
        tmp_path, seed, capsys):
    # The tree is dirty too: the busy refusal comes before the discard.
    git = flowing(tmp_path, on="quick/6-earlier", dirty=["README.md"],
                  **{"branch__quick/6-earlier__orchestrator_base": "main"})
    before = untouched(tmp_path, git)

    assert create(capsys, seed, git) == (3, "", (
        "orch: busy: branch quick/6-earlier has no PR yet\n"
        "     Open its PR, or switch off it.\n"))
    assert untouched(tmp_path, git) == before


def test_create_checks_the_branch_signal_only_never_its_own_flow_or_the_tree(
        tmp_path, seed, capsys):
    # Its own flow mid-pipeline, and a tree dirty outside the allowlist on a
    # detached HEAD, which an autopilot flow discards.
    git = flowing(tmp_path, on=None, dirty=["README.md"])

    assert create(capsys, seed, git, env=AUTOPILOT) == (0, FLOW + "\n", "")
    assert made(tmp_path, git) == (FLOW, ORIGIN_TIP, "main", ORIGIN_TIP, FLOW, None)


@pytest.mark.parametrize("env", [{}, AUTOPILOT], ids=["interactive", "autopilot"])
def test_create_refuses_a_name_already_taken_discarding_and_writing_nothing(
        tmp_path, seed, capsys, env):
    # A branch the flow never recorded; the dirty detached HEAD shows the
    # discard never ran: in the interactive main checkout it would refuse.
    git = flowing(tmp_path, on=None, dirty=["README.md"], branches=(FLOW,))
    git.seed("reset_hard_at", str(tmp_path), answer=False)
    before = untouched(tmp_path, git)

    assert create(capsys, seed, git, env=env) == (
        1, "", "orch: branch %s already exists\n" % FLOW)
    assert untouched(tmp_path, git) == before


@pytest.mark.parametrize("has, message", [
    (False, "base branch main does not exist on origin - push it, or %s" % GONE_REMEDY),
    (True, "could not fetch main from origin"),
], ids=["gone", "fetch-failed"])
def test_create_refuses_a_base_origin_lacks_or_failed_to_fetch_discarding_and_writing_nothing(
        tmp_path, seed, capsys, has, message):
    git = flowing(tmp_path, on=None, dirty=["README.md"], fetched=False)
    git.seed("origin_has_branch", "main", answer=has)
    git.seed("ref_exists", "refs/remotes/origin/main", answer=True)
    before = untouched(tmp_path, git)

    assert create(capsys, seed, git) == (1, "", "orch: %s\n" % message)
    assert untouched(tmp_path, git) == before


@pytest.mark.parametrize("tracked, tip", [(True, ORIGIN_TIP), (False, LOCAL_TIP)],
                         ids=["origin-s-local-ref", "local-base"])
def test_with_origin_unreachable_create_forks_from_origin_s_local_ref_else_the_local_base(
        tmp_path, seed, capsys, tracked, tip):
    git = flowing(tmp_path, fetched=False)
    git.seed("ref_exists", "refs/remotes/origin/main", answer=tracked)

    assert create(capsys, seed, git) == (0, FLOW + "\n", "")
    assert made(tmp_path, git) == (FLOW, tip, "main", tip, FLOW, None)


def test_the_fresh_path_on_a_detached_head_in_an_interactive_main_checkout_is_refused(
        tmp_path, seed, capsys):
    git = flowing(tmp_path, on=None, dirty=["README.md", "stray.txt"])
    before = untouched(tmp_path, git)

    assert create(capsys, seed, git) == (
        1, "", interactive_refusal(tmp_path, "README.md, stray.txt"))
    assert untouched(tmp_path, git) == before


def test_the_fresh_path_on_a_detached_head_in_a_hand_made_worktree_discards_and_forks(
        tmp_path, seed, capsys):
    git = flowing(tmp_path, on=None, dirty=["README.md"], main=False)

    assert create(capsys, seed, git) == (0, FLOW + "\n", "")
    assert made(tmp_path, git) == (FLOW, ORIGIN_TIP, "main", ORIGIN_TIP, FLOW, None)


@pytest.mark.parametrize("env", [{}, AUTOPILOT], ids=["interactive", "autopilot"])
@pytest.mark.parametrize("on, recorded_branch, config", [
    ("human-scratch", None, {}),
    ("orch/11-feat-redo-1", "orch/11-feat-redo-1", {
        "branch__orch/11-feat-redo-1__orchestrator_base": "main",
        "branch__orch/11-feat-redo-1__orchestrator_retired": "true"}),
], ids=["foreign", "retired-redo-branch-state-still-records"])
def test_the_fresh_path_on_a_dirty_branch_not_the_flow_s_dies_discarding_and_writing_nothing(
        tmp_path, seed, capsys, env, on, recorded_branch, config):
    git = flowing(tmp_path, on=on, recorded=recorded_branch, dirty=["README.md"], **config)
    before = untouched(tmp_path, git)

    assert create(capsys, seed, git, env=env) == (1, "", foreign_refusal(on))
    assert untouched(tmp_path, git) == before


def test_the_fresh_path_on_a_branch_not_the_flow_s_with_a_merge_in_progress_dies(
        tmp_path, seed, capsys):
    git = flowing(tmp_path, on="scratch-m")
    git.seed("merge_in_progress_at", str(tmp_path), answer=True)
    before = untouched(tmp_path, git)

    assert create(capsys, seed, git, env=AUTOPILOT) == (1, "", foreign_refusal("scratch-m"))
    assert untouched(tmp_path, git) == before


def test_the_fresh_path_on_a_foreign_branch_s_rebase_in_progress_dies_naming_it(
        tmp_path, seed, capsys):
    # The rebase detaches HEAD; the branch it rebases is the current one.
    git = flowing(tmp_path, on=None, branches=("scratch-r",))
    rebasing_onto(tmp_path, "scratch-r")
    before = untouched(tmp_path, git)

    assert create(capsys, seed, git, env=AUTOPILOT) == (1, "", foreign_refusal("scratch-r"))
    assert untouched(tmp_path, git) == before


def test_a_record_git_refuses_ends_create_with_git_s_status_and_stderr(tmp_path, seed, capsys):
    # As bash's set -e did, the state already written.
    git = flowing(tmp_path)
    git.config_write_fails.add(("local", "branch.%s.orchestrator-base" % FLOW))

    assert create(capsys, seed, git) == (
        255, "", "error: could not lock config file .git/config: File exists\n")
    assert made(tmp_path, git) == (FLOW, ORIGIN_TIP, None, None, FLOW, None)


def test_a_failed_state_write_records_neither_key_nor_the_git_config(tmp_path, seed, capsys):
    git = flowing(tmp_path)
    folder = state_json(tmp_path).parent
    folder.chmod(0o555)
    try:
        result = create(capsys, seed, git)
    finally:
        folder.chmod(0o755)

    assert result == (1, "", (
        "orch: could not record branch, base_sha in %s - the flow is unchanged\n"
        % state_json(tmp_path)))
    assert made(tmp_path, git) == (None, None, None, None, FLOW, None)


# The restart: the flow's own branch, recorded and made.


def restarting(tmp_path, on="main", **forked):
    """flowing's flow with FLOW made and recorded, its git config holding a
    base and a base SHA unlike any create would write."""
    forked.setdefault("branches", (FLOW,))
    return flowing(tmp_path, on=on, recorded=FLOW, **{
        "branch__%s__orchestrator_base" % FLOW: "main",
        "branch__%s__orchestrator_base_sha" % FLOW: "moved-marker"}, **forked)


@pytest.mark.parametrize("on", ["main", FLOW], ids=["elsewhere", "on-it"])
@pytest.mark.parametrize("phase", ["implement", "done"])
def test_a_restart_checks_the_flow_s_branch_out_and_prints_it_writing_nothing(
        tmp_path, seed, capsys, on, phase):
    git = restarting(tmp_path, on=on, phase=phase)
    state = state_json(tmp_path).read_text()

    assert create(capsys, seed, git) == (0, FLOW + "\n", "")
    assert (state_json(tmp_path).read_text(), recorded(git, FLOW)) == (
        state, ("main", "moved-marker", FLOW, None))


def test_a_restart_is_never_refused_as_busy(tmp_path, seed, capsys):
    git = restarting(tmp_path, on="quick/6-earlier",
                     **{"branch__quick/6-earlier__orchestrator_base": "main"})

    assert create(capsys, seed, git) == (0, FLOW + "\n", "")
    assert git.current_branch() == FLOW


@pytest.mark.parametrize("on", [FLOW, None], ids=["own-branch", "detached-head"])
def test_a_restart_s_dirty_tree_in_an_interactive_main_checkout_is_refused(
        tmp_path, seed, capsys, on):
    git = restarting(tmp_path, on=on, dirty=["README.md", "stray.txt"])
    before = untouched(tmp_path, git)

    assert create(capsys, seed, git) == (
        1, "", interactive_refusal(tmp_path, "README.md, stray.txt"))
    assert untouched(tmp_path, git) == before


def test_a_restart_s_merge_in_progress_in_an_interactive_main_checkout_names_merge_abort(
        tmp_path, seed, capsys):
    git = restarting(tmp_path, on=FLOW)
    git.seed("merge_in_progress_at", str(tmp_path), answer=True)

    assert create(capsys, seed, git) == (1, "", interactive_refusal(
        tmp_path, " merge in progress", 'git -C "%s" merge --abort; ' % tmp_path))


def test_a_restart_s_own_rebase_in_progress_in_an_interactive_main_checkout_names_it(
        tmp_path, seed, capsys):
    git = restarting(tmp_path, on=None)
    rebasing_onto(tmp_path, FLOW)

    assert create(capsys, seed, git) == (1, "", interactive_refusal(
        tmp_path, "", 'git -C "%s" rebase --abort; ' % tmp_path))


@pytest.mark.parametrize("env, main", [(AUTOPILOT, True), ({}, False)],
                         ids=["autopilot", "hand-made-worktree"])
@pytest.mark.parametrize("on", [FLOW, None], ids=["own-branch", "detached-head"])
def test_a_restart_s_dirty_tree_is_discarded_where_the_discard_rule_allows(
        tmp_path, seed, capsys, env, main, on):
    git = restarting(tmp_path, on=on, dirty=["README.md"], main=main)

    assert create(capsys, seed, git, env=env) == (0, FLOW + "\n", "")
    assert git.current_branch() == FLOW


def test_a_restart_s_failed_discard_step_dies_naming_it(tmp_path, seed, capsys):
    git = restarting(tmp_path, on=FLOW, dirty=["README.md"])
    git.seed("reset_hard_at", str(tmp_path), answer=False)

    assert create(capsys, seed, git, env=AUTOPILOT) == (1, "", (
        "orch: could not discard: git reset --hard failed in %s\n" % tmp_path))


def test_a_restart_where_the_main_checkout_cannot_be_told_discards_nothing(
        tmp_path, seed, capsys):
    git = restarting(tmp_path, on=FLOW, dirty=["README.md"])
    git.seed("worktree_list", answer=None)

    assert create(capsys, seed, git) == (1, "", (
        "orch: could not tell whether %s is the main checkout - nothing was discarded\n"
        % tmp_path))


@pytest.mark.parametrize("env", [{}, AUTOPILOT], ids=["interactive", "autopilot"])
def test_a_restart_on_a_dirty_branch_not_the_flow_s_dies_discarding_nothing(
        tmp_path, seed, capsys, env):
    git = restarting(tmp_path, on="human-scratch", dirty=["README.md", "untracked.txt"])
    before = untouched(tmp_path, git)

    assert create(capsys, seed, git, env=env) == (1, "", foreign_refusal("human-scratch"))
    assert untouched(tmp_path, git) == before


def test_a_restart_on_a_foreign_branch_s_rebase_in_progress_dies_naming_it(
        tmp_path, seed, capsys):
    git = restarting(tmp_path, on=None, branches=(FLOW, "scratch-r"))
    rebasing_onto(tmp_path, "scratch-r")

    assert create(capsys, seed, git, env=AUTOPILOT) == (1, "", foreign_refusal("scratch-r"))
    assert git.current_branch() is None


# The refusals before either path.


def test_create_with_no_flow_is_refused(tmp_path, seed, capsys):
    assert create(capsys, seed, forking(tmp_path)) == (1, "", NO_FLOW)


def test_create_beside_an_unreadable_state_json_is_refused(tmp_path, seed, capsys):
    hold_flow(tmp_path).write_text("{\"slug\": \"feat\", \"pha")

    assert create(capsys, seed, forking(tmp_path)) == (1, "", UNREADABLE)


def test_create_with_no_issue_recorded_is_refused_writing_nothing(tmp_path, seed, capsys):
    git = flowing(tmp_path, issue=None)
    before = untouched(tmp_path, git)

    assert create(capsys, seed, git) == (1, "", NO_ISSUE)
    assert untouched(tmp_path, git) == before


def test_create_with_an_argument_is_a_usage_error(tmp_path, seed, capsys):
    assert create(capsys, seed, flowing(tmp_path), "extra") == (1, "", CREATE_USAGE)


@pytest.mark.parametrize("state, issue, expected", [
    (None, 11, NO_FLOW),
    ("{\"slug\": \"feat\", \"pha", 11, UNREADABLE),
    ("flow", None, CREATE_USAGE),
], ids=["no-flow", "unreadable", "no-issue"])
def test_the_state_refusals_come_before_the_usage_and_the_usage_before_the_issue(
        tmp_path, seed, capsys, state, issue, expected):
    git = forking(tmp_path) if state is None else flowing(tmp_path, issue=issue)
    if state not in (None, "flow"):
        state_json(tmp_path).write_text(state)

    assert create(capsys, seed, git, "extra") == (1, "", expected)


# Real repositories: the full-ref naming, and git's refusal of a checkout.


def test_create_beside_tags_named_like_the_branch_and_origin_s_base_forks_from_origin_s_tip(
        off_repo, seed, capsys):
    root, origin_tip, local_tip = off_repo
    hold_flow(root, slug="feat", phase="implement", issue=11, branch=None, base="main")
    for tag in (FLOW, "origin/main"):
        run_git(root, "tag", tag, local_tip)

    assert orch(capsys, "create", git=Git(cwd=str(root)), gh=fake(seed)) == (0, FLOW + "\n", "")
    assert (head_of(root, "refs/heads/" + FLOW), repo_facts(root, FLOW),
            run_git(root, "for-each-ref", "--format=%(upstream)", "refs/heads/" + FLOW),
            json.loads(state_json(root).read_text())["base_sha"]) == (
        origin_tip, ("made", origin_tip, FLOW), "", origin_tip)


def test_a_restart_whose_checkout_git_refuses_dies_with_git_s_message_after_it(
        off_repo, seed, capsys):
    # The flow's branch tracks an allowlisted file main holds untracked: no
    # work to discard, but a checkout git will not make over it.
    root, _, _ = off_repo
    run_git(root, "checkout", "-qb", FLOW)
    committed(root, {"docs/agents/plan.md": "branch\n"}, "plan")
    run_git(root, "checkout", "-q", "main")
    (root / "docs" / "agents" / "plan.md").write_text("mine\n")
    hold_flow(root, slug="feat", phase="implement", issue=11, branch=FLOW, base="main")
    exclude_orchestrator(root)

    code, out, err = orch(capsys, "create", git=Git(cwd=str(root)), gh=fake(seed))

    assert (code, out) == (1, "")
    assert "would be overwritten" in err and "docs/agents/plan.md" in err
    assert err.endswith("orch: could not check out %s\n" % FLOW)
    assert (run_git(root, "branch", "--show-current"),
            (root / "docs" / "agents" / "plan.md").read_text()) == ("main", "mine\n")


# --- busy ------------------------------------------------------------------------------

BUSY_USAGE = "orch: usage: orch.sh branch busy\n"
TREE_BUSY = "busy: the working tree has changes outside the planning allowlist: "


def checkout(tmp_path, dirty=(), branch=None, **config):
    """A FakeGit at tmp_path, its status finding <dirty> changed (a str for a
    status that cannot run), on <branch> (None for a detached HEAD), its git
    config holding <config>, each key's - spelled _ and . spelled __."""
    git = FakeGit(toplevel=str(tmp_path))
    git.seed("dirty_paths", answer=dirty if isinstance(dirty, str) else list(dirty))
    git.seed("current_branch", answer=branch)
    for key, value in config.items():
        git.seed("config_value", key.replace("__", ".").replace("_", "-"), answer=value)
    return git


def busy(capsys, git, *argv):
    return orch(capsys, "busy", *argv, git=git)


@pytest.mark.parametrize("dirty", [(), ("docs/agents/note.md",)], ids=["clean", "allowlisted"])
def test_a_checkout_clean_outside_the_allowlist_is_free_printing_nothing(tmp_path, capsys, dirty):
    assert busy(capsys, checkout(tmp_path, dirty, "main")) == (0, "", "")


def test_a_dirty_tree_outside_the_allowlist_is_busy_naming_every_path(tmp_path, capsys):
    git = checkout(tmp_path, ["README.md", "docs/agents/note.md", "stray.txt"], "main")

    assert busy(capsys, git) == (3, TREE_BUSY + "README.md, stray.txt\n", "")


def test_a_working_tree_that_cannot_be_read_exits_1_printing_no_busy_line(tmp_path, capsys):
    git = checkout(tmp_path, "fatal: index file corrupt", "main")

    assert busy(capsys, git) == (1, "", (
        "orch: git status failed - cannot check the working tree: fatal: index file corrupt\n"))


def test_an_argument_is_a_usage_error_before_the_tree_is_read(tmp_path, capsys):
    # Both its checks broken: the argument and the unreadable tree.
    git = checkout(tmp_path, "fatal: index file corrupt", "main")

    assert busy(capsys, git, "extra") == (1, "", BUSY_USAGE)


def test_a_detached_head_is_never_a_plugin_made_branch(tmp_path, capsys):
    assert busy(capsys, checkout(tmp_path, ["docs/agents/x.md"])) == (0, "", "")


@pytest.mark.parametrize("name", ["quick/5-held", "orch/30-unheld"])
def test_a_plugin_made_branch_with_no_pr_is_busy_ahead_of_a_dirty_tree(tmp_path, capsys, name):
    git = checkout(tmp_path, ["README.md"], name, **{"branch__%s__orchestrator_base" % name: "main"})

    assert busy(capsys, git) == (3, "busy: branch %s has no PR yet\n" % name, "")


@pytest.mark.parametrize("key, value", [
    ("orchestrator_pr", "42"),
    ("orchestrator_retired", "true"),
    ("orchestrator_ticket_parent", "orch/30-unheld"),
], ids=["with-a-pr", "retired-by-a-redo", "ticket-branch"])
def test_a_branch_with_a_pr_retired_or_a_ticket_s_is_free(tmp_path, capsys, key, value):
    name = "orch/30-unheld--t31" if key == "orchestrator_ticket_parent" else "quick/5-held"
    config = {"branch__%s__%s" % (name, key): value}
    if key != "orchestrator_ticket_parent":
        config["branch__%s__orchestrator_base" % name] = "main"

    assert busy(capsys, checkout(tmp_path, (), name, **config)) == (0, "", "")


@pytest.mark.parametrize("phase", ["spec", "implement", "review"])
def test_a_flow_mid_pipeline_is_busy_ahead_of_the_branch_and_tree(tmp_path, capsys, phase):
    hold_flow(tmp_path, slug="held", phase=phase)
    git = checkout(tmp_path, ["README.md"], "quick/5-held",
                   **{"branch__quick/5-held__orchestrator_base": "main"})

    assert busy(capsys, git) == (
        3, "busy: a flow is mid-pipeline (slug: held, phase: %s)\n" % phase, "")


def test_a_done_flow_is_free(tmp_path, capsys):
    hold_flow(tmp_path, slug="held", phase="done")

    assert busy(capsys, checkout(tmp_path, (), "main")) == (0, "", "")


def test_a_flow_whose_state_json_cannot_be_read_is_busy(tmp_path, capsys):
    (hold_flow(tmp_path)).write_text("{\"slug\": \"held\", \"pha")

    assert busy(capsys, checkout(tmp_path, (), "main")) == (
        3, "busy: a flow's state.json cannot be read\n", "")


# --- base-sha --------------------------------------------------------------------------

QUICK = "quick/1-sha"
BASE_SHA_USAGE = "orch: usage: orch.sh branch base-sha\n"


@pytest.fixture
def sha_repo(tmp_path):
    """A clone of a bare origin holding main, origin/HEAD naming it, on QUICK
    branched off origin/main with one commit of its own and nothing
    recorded: the clone's root."""
    root = tmp_path / "repo"
    origin_clone(tmp_path / "origin.git", root, "main")
    run_git(root, "checkout", "-qb", "main")
    run_git(root, "commit", "-q", "--allow-empty", "-m", "one")
    run_git(root, "push", "-q", "origin", "HEAD:refs/heads/main")
    run_git(root, "fetch", "-q", "origin")
    run_git(root, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    run_git(root, "checkout", "-q", "--no-track", "-b", QUICK, "refs/remotes/origin/main")
    run_git(root, "commit", "-q", "--allow-empty", "-m", "work on the branch")
    return root


def base_sha(capsys, seed, root, *argv):
    return orch(capsys, "base-sha", *argv, git=Git(cwd=str(root)), gh=fake(seed))


def head_of(root, ref):
    return run_git(root, "rev-parse", ref)


def advance_origin_main(root):
    """Moves origin's main one commit on, fetched, and merges it into QUICK:
    origin's new tip."""
    run_git(root, "checkout", "-q", "-b", "advance", "refs/remotes/origin/main")
    run_git(root, "commit", "-q", "--allow-empty", "-m", "main moves on")
    run_git(root, "push", "-q", "origin", "advance:refs/heads/main")
    run_git(root, "fetch", "-q", "origin")
    run_git(root, "checkout", "-q", QUICK)
    run_git(root, "branch", "-q", "-D", "advance")
    run_git(root, "merge", "-q", "--no-edit", "refs/remotes/origin/main")
    return head_of(root, "refs/remotes/origin/main")


def test_base_sha_prints_the_recorded_base_sha_however_the_base_moved(
        sha_repo, seed, capsys):
    branched = head_of(sha_repo, "refs/remotes/origin/main")
    run_git(sha_repo, "config", "branch.%s.orchestrator-base-sha" % QUICK, branched)
    advance_origin_main(sha_repo)

    assert base_sha(capsys, seed, sha_repo) == (0, branched + "\n", "")


def test_with_no_recorded_sha_it_prints_the_merge_base_with_origin_s_base_over_the_local(
        sha_repo, seed, capsys):
    run_git(sha_repo, "config", "branch.%s.orchestrator-base" % QUICK, "main")
    moved = advance_origin_main(sha_repo)

    # Local main still sits at the branched tip; origin's copy answers.
    assert base_sha(capsys, seed, sha_repo) == (0, moved + "\n", "")


def test_with_no_remote_tracking_ref_it_uses_the_local_base(sha_repo, seed, capsys):
    branched = head_of(sha_repo, "refs/remotes/origin/main")
    advance_origin_main(sha_repo)
    run_git(sha_repo, "branch", "-q", "localbase", branched)
    run_git(sha_repo, "config", "branch.%s.orchestrator-base" % QUICK, "localbase")

    assert base_sha(capsys, seed, sha_repo) == (0, branched + "\n", "")


def test_with_neither_key_it_uses_the_base_setting_else_the_default_branch(
        sha_repo, seed, capsys):
    branched = head_of(sha_repo, "refs/remotes/origin/main")
    run_git(sha_repo, "checkout", "-q", "-b", "uat", branched)
    run_git(sha_repo, "commit", "-q", "--allow-empty", "-m", "uat only")
    run_git(sha_repo, "push", "-q", "origin", "uat:refs/heads/uat")
    run_git(sha_repo, "fetch", "-q", "origin")
    run_git(sha_repo, "checkout", "-q", "-b", "quick/2-legacy", "uat")
    run_git(sha_repo, "commit", "-q", "--allow-empty", "-m", "legacy work")
    run_git(sha_repo, "config", "orchestrator.base", "uat")
    setting = base_sha(capsys, seed, sha_repo)
    run_git(sha_repo, "config", "--unset", "orchestrator.base")

    assert (setting, base_sha(capsys, seed, sha_repo)) == (
        (0, head_of(sha_repo, "refs/remotes/origin/uat") + "\n", ""), (0, branched + "\n", ""))


def test_a_detached_head_is_refused(sha_repo, seed, capsys):
    run_git(sha_repo, "checkout", "-q", "--detach")

    assert base_sha(capsys, seed, sha_repo) == (1, "", "orch: not on a branch (detached HEAD)\n")


def test_an_argument_is_a_usage_error_before_the_detached_head(sha_repo, seed, capsys):
    # Both its first checks broken: the argument and the detached HEAD.
    run_git(sha_repo, "checkout", "-q", "--detach")

    assert base_sha(capsys, seed, sha_repo, "extra") == (1, "", BASE_SHA_USAGE)


def test_a_base_neither_on_origin_nor_local_is_refused(sha_repo, seed, capsys):
    run_git(sha_repo, "config", "branch.%s.orchestrator-base" % QUICK, "gone")

    assert base_sha(capsys, seed, sha_repo) == (1, "", (
        "orch: base branch gone of %s is neither on origin nor local - no base SHA to fall"
        " back to\n" % QUICK))


def test_a_base_sharing_no_history_with_the_branch_is_refused(sha_repo, seed, capsys):
    run_git(sha_repo, "checkout", "-q", "--orphan", "unrelated")
    run_git(sha_repo, "commit", "-q", "--allow-empty", "-m", "elsewhere")
    run_git(sha_repo, "checkout", "-q", QUICK)
    run_git(sha_repo, "config", "branch.%s.orchestrator-base" % QUICK, "unrelated")

    assert base_sha(capsys, seed, sha_repo) == (1, "", (
        "orch: %s shares no history with base branch unrelated\n" % QUICK))


# --- retire ----------------------------------------------------------------------------

OLD, NEW = "orch/7-feature", "orch/7-feature-redo-1"
RETIRE_USAGE = "orch: usage: orch.sh branch retire <old> <new>\n"


@pytest.mark.parametrize("argv", [(), (OLD,), (OLD, NEW, "extra")], ids=["none", "one", "three"])
def test_retire_with_the_wrong_number_of_arguments_is_a_usage_error(capsys, argv):
    assert orch(capsys, "retire", *argv) == (1, "", RETIRE_USAGE)


def test_retire_with_one_argument_naming_no_branch_reports_the_usage_first(capsys):
    # Both its checks broken: the argument count and the branch's existence.
    assert orch(capsys, "retire", "nosuchbranch") == (1, "", RETIRE_USAGE)


def test_retire_renames_a_local_only_branch_and_prints_the_new_name(capsys):
    git = FakeGit(toplevel=ROOT, branches={OLD: None})

    assert orch(capsys, "retire", OLD, NEW, git=git) == (0, NEW + "\n", "")
    assert (git.branch_exists(OLD), git.branch_exists(NEW),
            git.config_value("branch.%s.orchestrator-retired" % NEW)) == (False, True, "true")


@pytest.fixture
def tagged(tmp_path):
    """A clone of a bare origin holding main, two commits deep, on OLD
    pushed and tracking origin's, a tag named OLD and one named NEW at the
    older commit, OLD's tag pushed too (#2337): (clone, origin)."""
    root, origin = tmp_path / "repo", tmp_path / "origin.git"
    origin_clone(origin, root, "main")
    run_git(root, "checkout", "-qb", "main")
    run_git(root, "commit", "-q", "--allow-empty", "-m", "one")
    run_git(root, "push", "-q", "origin", "HEAD:refs/heads/main")
    run_git(root, "commit", "-q", "--allow-empty", "-m", "later")
    run_git(root, "checkout", "-q", "-b", OLD)
    run_git(root, "push", "-q", "-u", "origin", OLD)
    for tag in (OLD, NEW):
        run_git(root, "tag", tag, "HEAD~1")
    run_git(root, "push", "-q", "origin", "refs/tags/" + OLD)
    return root, origin


def test_retire_beside_tags_named_like_both_branches_moves_the_branch_itself(tagged, capsys):
    root, origin = tagged
    tip = run_git(root, "rev-parse", "refs/heads/" + OLD)

    assert orch(capsys, "retire", OLD, NEW, git=Git(cwd=str(root))) == (0, NEW + "\n", "")
    assert (run_git(root, "rev-parse", "refs/heads/" + NEW),
            run_git(origin, "rev-parse", "refs/heads/" + NEW),
            run_git(origin, "for-each-ref", "refs/heads/" + OLD),
            run_git(root, "config", "--get", "branch.%s.merge" % NEW)) == (
        tip, tip, "", "refs/heads/" + NEW)


def test_retire_of_a_name_only_a_tag_has_says_the_branch_does_not_exist(tagged, capsys):
    root, _ = tagged
    run_git(root, "tag", "tg-only", "HEAD~1")

    assert orch(capsys, "retire", "tg-only", "tg-only-redo-1", git=Git(cwd=str(root))) == (
        1, "", "orch: branch tg-only does not exist\n")


def test_retire_resumes_beside_a_tag_named_old_once_new_exists(tagged, capsys):
    # A previous call renamed locally only: origin still has OLD, beside
    # OLD's pushed tag.
    root, origin = tagged
    run_git(root, "tag", "-d", NEW)
    run_git(root, "branch", "-m", OLD, NEW)

    assert orch(capsys, "retire", OLD, NEW, git=Git(cwd=str(root))) == (0, NEW + "\n", "")
    assert (run_git(origin, "for-each-ref", "--format=%(refname)", "refs/heads/"),
            run_git(origin, "for-each-ref", "--format=%(refname)", "refs/tags/")) == (
        "refs/heads/main\nrefs/heads/" + NEW, "refs/tags/" + OLD)
