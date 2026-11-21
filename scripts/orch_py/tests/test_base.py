"""The base module's default-branch lookup, as the bash side's
default_branch_resolve and default_branch_seed find it: GitHub's answer
through the repo pin when it names a branch, else origin/HEAD's branch, else
main - the name and its source, never a failure."""
from __future__ import annotations

from orch.base import default_branch
from orch.gh_fake import FakeGh
from orch.git import FakeGit
from orch.repo import RepoPin

from conftest import GH_502

ORIGIN = {"origin": "https://github.com/acme/widgets.git"}


def lookup(seed, git, pin=None):
    """The lookup on the gh fake over <seed>'s store, its repo pinned by
    <pin>, a pin on <git>'s origin when None."""
    pin = RepoPin({}, git) if pin is None else pin
    return default_branch(FakeGh(seed.store, {}, pin=pin, sleep=lambda _: None), git, pin)


def branches(*names):
    """A checkout with the acme/widgets origin, where each of <names> is a
    valid branch name."""
    git = FakeGit(ORIGIN)
    for name in names:
        git.seed("is_branch_name", name, answer=True)
    return git


def test_github_s_answer_wins_when_it_names_a_branch(seed):
    seed.default_branch("trunk")
    git = branches("trunk", "main")
    git.seed("origin_head_branch", answer="main")

    assert lookup(seed, git) == ("trunk", "github")


def test_an_answer_that_names_no_branch_falls_through_to_origin_head(seed):
    seed.default_branch("not a branch")
    git = branches("develop")
    git.seed("origin_head_branch", answer="develop")

    assert lookup(seed, git) == ("develop", "origin-head")


def test_a_failed_github_read_falls_through_with_no_death_or_warning(seed, capsys):
    seed.default_branch("trunk")
    seed.fail("adapter_repo_default_branch", GH_502)
    git = branches("trunk", "develop")
    git.seed("origin_head_branch", answer="develop")

    assert lookup(seed, git) == ("develop", "origin-head")
    assert capsys.readouterr() == ("", "")


def test_github_is_not_asked_when_no_repo_resolves(seed):
    seed.default_branch("trunk")
    git = FakeGit()
    for name in ("trunk", "develop"):
        git.seed("is_branch_name", name, answer=True)
    git.seed("origin_head_branch", answer="develop")

    assert lookup(seed, git, pin=RepoPin({}, git)) == ("develop", "origin-head")


def test_origin_head_must_name_a_branch_or_main_is_the_guess(seed):
    git = branches()
    git.seed("origin_head_branch", answer="not a branch")

    assert lookup(seed, git) == ("main", "fallback")


def test_main_is_the_guess_when_nothing_answers(seed):
    assert lookup(seed, branches("main")) == ("main", "fallback")
