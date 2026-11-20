"""The git adapter's operations, each run against a real repository in
tmp_path and against the fake, giving the same answers."""
from __future__ import annotations

import subprocess

import pytest

from orch.git import FakeGit, Git

ORIGIN = "https://github.com/fork/widgets.git"


def git_repo(path, origin=None):
    """A fresh repository at <path>, with <origin> as its origin remote when
    one is given."""
    subprocess.run(
        ["git", "init", "-q", str(path)], check=True, stdin=subprocess.DEVNULL
    )
    if origin is not None:
        subprocess.run(
            ["git", "-C", str(path), "remote", "add", "origin", origin],
            check=True,
            stdin=subprocess.DEVNULL,
        )
    return Git(cwd=str(path))


@pytest.mark.parametrize("origin", [ORIGIN, None], ids=["origin", "no-origin"])
def test_origin_url_reads_the_same_from_a_real_repo_and_the_fake(tmp_path, origin):
    real = git_repo(tmp_path, origin)
    fake = FakeGit(remotes={} if origin is None else {"origin": origin})

    assert real.origin_url() == origin
    assert fake.origin_url() == origin


def test_a_repo_with_other_remotes_but_no_origin_has_no_origin_url(tmp_path):
    real = git_repo(tmp_path)
    subprocess.run(
        ["git", "-C", str(tmp_path), "remote", "add", "upstream", ORIGIN],
        check=True,
        stdin=subprocess.DEVNULL,
    )
    fake = FakeGit(remotes={"upstream": ORIGIN})

    assert real.origin_url() is None
    assert fake.origin_url() is None


def test_outside_a_repository_there_is_no_origin_url(tmp_path):
    assert Git(cwd=str(tmp_path)).origin_url() is None
