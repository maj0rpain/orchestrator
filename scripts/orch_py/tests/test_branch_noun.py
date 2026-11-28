"""`orch.sh branch busy|base-sha|retire` and the noun's dispatch, called
in-process through the branch module's run: busy and retire against FakeGit
and the gh fake, base-sha against real repositories with a real origin under
tmp_path, since its fallback is git's merge-base, which a fake would only
restate. Each message, exit code and order of checks is the bash noun's,
verbatim."""
from __future__ import annotations

import pytest

from conftest import fake, hold_flow, origin_clone, outcome, run_git
from orch import branch as module
from orch.git import FakeGit, Git

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


@pytest.mark.parametrize("op", ["create", "off", "sync"])
def test_a_verb_still_run_in_bash_is_known_never_an_unknown_op(capsys, op):
    # orch.sh routes branch to bash until the switch ticket, so run reaches
    # these only when called directly: a refusal naming the verb, exit 1.
    assert orch(capsys, op) == (1, "", (
        "orch: branch %s is not converted to Python yet - run orch.sh branch %s\n" % (op, op)))


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
