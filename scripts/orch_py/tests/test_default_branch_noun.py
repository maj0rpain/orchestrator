"""`orch.sh default-branch [--sha]`, called in-process through the base
module's run_default_branch: the lookup's three sources against FakeGit and
the gh fake, and --sha against a real clone of a real bare origin under
tmp_path, since its no-fetch promise is about the remote-tracking ref a fake
would only restate. Each output, message and exit code is the bash noun's,
verbatim."""
from __future__ import annotations

import pytest

from conftest import (GH_502, GITHUB_ORIGIN, CountingGh, commit_of, committed, fake, outcome,
                      origin_main_clone, run_git)
from orch import base as module
from orch.git import FakeGit, Git

ROOT = "/nonexistent/checkout"
USAGE = "orch: usage: orch.sh default-branch [--sha]\n"
BANNER = "mise ~/.config/mise/config.toml tools: gh@2.102.0\ntrunk"


def checkout(head=None, *names, **config):
    """A FakeGit at ROOT with the acme/widgets origin, origin/HEAD naming
    <head> (None for unset), each of <names> a valid branch name, its local
    config holding <config>."""
    git = FakeGit(GITHUB_ORIGIN, toplevel=ROOT, local_config=config)
    git.seed("origin_head_branch", answer=head)
    for name in names:
        git.seed("is_branch_name", name, answer=True)
    return git


def orch(capsys, git, gh, *argv, env=None):
    """`orch.sh default-branch <argv>` in-process through <git> and the gh
    adapter <gh>: (exit code, stdout, stderr)."""
    return outcome(capsys, lambda: module.run_default_branch(
        list(argv), gh=gh, git=git, env={} if env is None else env))


# --- the sources -----------------------------------------------------------------------


def test_github_s_answer_wins_over_a_stale_origin_head(capsys, seed):
    seed.default_branch("trunk\n")

    assert orch(capsys, checkout("some-feature", "trunk", "some-feature"), fake(seed)) == (
        0, "trunk\n", "")


@pytest.mark.parametrize("answer", [None, BANNER + "\n", "\n"],
                         ids=["no-answer", "banner", "empty"])
def test_an_answer_naming_no_branch_falls_back_to_origin_head(capsys, seed, answer):
    if answer is not None:
        seed.default_branch(answer)

    assert orch(capsys, checkout("some-feature", "trunk", "some-feature"), fake(seed)) == (
        0, "some-feature\n", "")


def test_the_output_of_a_gh_that_failed_is_ignored(capsys, seed):
    seed.default_branch("trunk\n")
    seed.fail("adapter_repo_default_branch", GH_502)

    assert orch(capsys, checkout("some-feature", "trunk", "some-feature"), fake(seed)) == (
        0, "some-feature\n", "")


@pytest.mark.parametrize("head", [None, "-dash"], ids=["unset", "invalid"])
def test_main_is_the_guess_when_nothing_else_answers(capsys, seed, head):
    assert orch(capsys, checkout(head, "some-feature"), fake(seed)) == (0, "main\n", "")


def test_a_local_branch_named_origin_main_still_leaves_main_the_default(capsys, seed, tmp_path):
    """#1111: a local branch named origin/main makes git's short name for
    origin/HEAD ambiguous (remotes/origin/main); origin/HEAD, read in full,
    still names main. The origin is a local path, so GitHub is not asked."""
    root, _ = origin_main_clone(tmp_path, {"f.txt": "one\n"})
    run_git(root, "branch", "origin/main")

    assert orch(capsys, Git(str(root)), fake(seed)) == (0, "main\n", "")


def test_a_base_setting_leaves_the_default_branch_as_it_is(capsys, seed):
    git = checkout("main", "main", **{"orchestrator.base": "uat"})

    assert orch(capsys, git, fake(seed)) == (0, "main\n", "")


def test_each_run_asks_github_afresh_and_sees_a_rename(capsys, seed):
    gh = CountingGh(seed.store, {}, sleep=lambda _: None)
    git = checkout("main", "main", "trunk")

    seed.default_branch("main\n")
    assert orch(capsys, git, gh) == (0, "main\n", "")
    seed.default_branch("trunk\n")
    assert orch(capsys, git, gh) == (0, "trunk\n", "")
    assert gh.default_asks == ["acme/widgets", "acme/widgets"]


# --- the usage and the checkout ----------------------------------------------------------


@pytest.mark.parametrize("argv", [("--name",), ("extra",), ("--sha", "extra")],
                         ids=["other-flag", "stray", "after-sha"])
def test_any_argument_but_a_lone_sha_is_refused_with_the_usage(capsys, seed, argv):
    assert orch(capsys, checkout("main", "main"), fake(seed), *argv) == (1, "", USAGE)


def test_outside_a_checkout_it_dies_first_as_orch_sh_does(capsys, seed):
    code, out, err = orch(capsys, FakeGit(GITHUB_ORIGIN), fake(seed))

    assert (code, out) == (1, "")
    assert err.startswith("orch: not inside a git repository (")


# --- --sha -----------------------------------------------------------------------------


def test_sha_prints_the_remote_tracking_tip_and_never_fetches(capsys, seed, tmp_path):
    root, fetched_tip = origin_main_clone(tmp_path, {"f.txt": "one\n"})
    seed.default_branch("main\n")
    moved = committed(root, {"f.txt": "two\n"}, "moved on")
    run_git(root, "push", "-q", "origin", "HEAD:refs/heads/main")
    run_git(root, "update-ref", "refs/remotes/origin/main", fetched_tip)
    git = Git(str(root))

    assert commit_of(tmp_path / "origin.git", "main") == moved
    assert orch(capsys, git, fake(seed), "--sha") == (0, fetched_tip + "\n", "")
    assert commit_of(root, "refs/remotes/origin/main") == fetched_tip
    assert orch(capsys, git, fake(seed)) == (0, "main\n", "")


def test_sha_dies_naming_the_missing_remote_tracking_ref(capsys, seed):
    assert orch(capsys, checkout("main", "main"), fake(seed), "--sha") == (
        1, "", "orch: no refs/remotes/origin/main - fetch the default branch first\n")


def test_sha_reads_the_default_branch_s_own_ref(capsys, seed):
    seed.default_branch("trunk\n")
    git = checkout("main", "main", "trunk")
    git.seed("resolve_commit", "refs/remotes/origin/trunk", answer="c" * 40)

    assert orch(capsys, git, fake(seed), "--sha") == (0, "c" * 40 + "\n", "")
