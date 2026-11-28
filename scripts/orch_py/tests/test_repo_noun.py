"""`orch.sh repo show [--name|--host]` and the noun's dispatch, called
in-process through the repo module's run against FakeGit, the SSH lookup an
SSH form's host goes through stood in: each output, message and exit code is
the bash noun's, verbatim."""
from __future__ import annotations

import pytest

from conftest import outcome
from orch import repo as module
from orch.git import FakeGit
from orch.repo import RepoPin

ROOT = "/nonexistent/checkout"
WIDGETS = "https://github.com/acme/widgets.git"
REMEDY = ("orch: no GitHub repo to work on: origin is missing or not a GitHub owner/name"
          " - set GH_REPO=<owner>/<repo>\n")
USAGE = "orch: usage: orch.sh repo show [--name|--host]\n"


def identity(host):
    return host


def orch(capsys, *argv, origin=WIDGETS, env=None, lookup=identity, git=None):
    """`orch.sh repo <argv>` in-process in a checkout at ROOT whose origin is
    <origin> (None for none), under <env>, an SSH form's host looked up
    through <lookup>: (exit code, stdout, stderr)."""
    env = {} if env is None else env
    if git is None:
        git = FakeGit({} if origin is None else {"origin": origin}, toplevel=ROOT)
    return outcome(capsys, lambda: module.run(
        list(argv), git=git, env=env, pin=RepoPin(env, git, lookup)))


# --- the dispatch ----------------------------------------------------------------------


@pytest.mark.parametrize("argv, named", [(("bogus",), "bogus"), ((), "<none>"), (("",), "<none>")],
                         ids=["unknown", "missing", "empty"])
def test_an_unknown_or_missing_op_is_refused_naming_show(capsys, argv, named):
    assert orch(capsys, *argv) == (1, "", "orch: unknown repo op: %s (want show)\n" % named)


def test_outside_a_checkout_it_dies_first_as_orch_sh_does(capsys):
    code, out, err = orch(capsys, "show", git=FakeGit({"origin": WIDGETS}))

    assert (code, out) == (1, "")
    assert err.startswith("orch: not inside a git repository (")


# --- show ------------------------------------------------------------------------------


def test_a_github_origin_shows_its_name_and_source(capsys):
    assert orch(capsys, "show", origin="https://github.com/o/r.git") == (0, "o/r (origin)\n", "")


@pytest.mark.parametrize("url", [
    "https://github.com/acme/widgets.git", "https://github.com/acme/widgets",
    "git@github.com:acme/widgets.git", "git@github.com:acme/widgets",
    "ssh://git@github.com/acme/widgets.git", "ssh://git@github.com/acme/widgets",
    "github.com:acme/widgets.git", "github.com:acme/widgets",
])
def test_every_github_origin_form_resolves_to_acme_widgets(capsys, url):
    assert orch(capsys, "show", "--name", origin=url) == (0, "acme/widgets\n", "")


@pytest.mark.parametrize("url", [
    "https://ghe.example.com/acme/widgets.git", "git@ghe.example.com:acme/widgets",
    "ssh://git@ghe.example.com/acme/widgets.git", "ghe.example.com:acme/widgets",
])
def test_an_origin_off_github_keeps_its_host(capsys, url):
    assert orch(capsys, "show", "--name", origin=url) == (
        0, "ghe.example.com/acme/widgets\n", "")


def test_gh_repo_wins_over_origin(capsys):
    env = {"GH_REPO": "fork/widgets"}

    assert orch(capsys, "show", env=env) == (0, "fork/widgets (GH_REPO)\n", "")
    assert orch(capsys, "show", "--name", env=env) == (0, "fork/widgets\n", "")


@pytest.mark.parametrize("argv", [("show", "extra"), ("show", "--name", "--host"),
                                  ("show", "", "")], ids=["stray", "both-flags", "two-empty"])
def test_show_refuses_anything_but_one_of_its_flags(capsys, argv):
    assert orch(capsys, *argv) == (1, "", USAGE)


def test_show_takes_one_empty_argument_as_none(capsys):
    """bash read its arguments joined, so one empty argument was no flag."""
    assert orch(capsys, "show", "") == (0, "acme/widgets (origin)\n", "")


@pytest.mark.parametrize("env, origin, host", [
    ({}, WIDGETS, "github.com"),
    ({"GH_REPO": "ghe.example.com/fork/widgets"}, WIDGETS, "ghe.example.com"),
    ({"GH_HOST": "other.example.com"}, WIDGETS, "github.com"),
    ({"GH_REPO": "fork/widgets", "GH_HOST": "ghe.example.com"}, WIDGETS, "ghe.example.com"),
    ({}, "git@ghe.example.com:acme/widgets.git", "ghe.example.com"),
], ids=["owner-repo", "explicit-host", "origin-under-user-host", "user-gh-repo-and-host",
        "origin-host"])
def test_show_host_prints_the_host_gh_targets(capsys, env, origin, host):
    assert orch(capsys, "show", "--host", env=env, origin=origin) == (0, host + "\n", "")


# --- the SSH lookup --------------------------------------------------------------------


@pytest.mark.parametrize("url", ["git@github-work:acme/widgets.git",
                                 "ssh://git@github-work/acme/widgets.git"])
def test_an_ssh_alias_origin_resolves_through_the_lookup(capsys, url):
    assert orch(capsys, "show", "--name", origin=url, lookup=lambda _: "github.com") == (
        0, "acme/widgets\n", "")


@pytest.mark.parametrize("answer, name", [
    ("ghe.example.com", "ghe.example.com/acme/widgets"),
    ("ssh.github.com", "acme/widgets"),
    ("GitHub.com", "acme/widgets"),
    ("github-work", "github-work/acme/widgets"),
], ids=["ghe", "ssh-github", "mixed-case", "unresolved"])
def test_the_lookup_s_answer_is_normalised_as_gh_does(capsys, answer, name):
    assert orch(capsys, "show", "--name", origin="git@github-work:acme/widgets.git",
                lookup=lambda _: answer) == (0, name + "\n", "")


def test_https_and_unsafe_origins_never_ask_the_lookup(capsys):
    asked = []

    def lookup(host):
        asked.append(host)
        return "github.com"

    assert orch(capsys, "show", "--name", origin="https://github-work/acme/widgets",
                lookup=lookup) == (0, "github-work/acme/widgets\n", "")
    assert orch(capsys, "show", "--name", origin="https://GitHub.com/acme/widgets",
                lookup=lookup) == (0, "acme/widgets\n", "")
    for url in ("../mirror:old/repo", "-oProxyCommand=x:acme/widgets",
                "ssh://git@-oProxyCommand=x/acme/widgets"):
        assert orch(capsys, "show", origin=url, lookup=lookup)[0] == 1
    assert asked == []


# --- no repo ---------------------------------------------------------------------------


@pytest.mark.parametrize("flags", [(), ("--name",), ("--host",)], ids=["plain", "name", "host"])
def test_with_no_repo_show_dies_with_the_repo_remedy(capsys, flags):
    assert orch(capsys, "show", *flags, origin=None) == (1, "", REMEDY)


def test_an_origin_with_no_owner_name_path_does_not_resolve(capsys):
    assert orch(capsys, "show", origin="https://example.invalid/notgithub") == (1, "", REMEDY)
