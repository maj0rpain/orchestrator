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


def test_toplevel_reads_the_same_from_a_real_repo_and_the_fake(tmp_path):
    root = tmp_path / "checkout"
    git_repo(root)
    (root / "sub").mkdir()
    fake = FakeGit(toplevel=str(root.resolve()))

    assert Git(cwd=str(root / "sub")).toplevel() == str(root.resolve())
    assert fake.toplevel() == str(root.resolve())


def test_outside_a_repository_there_is_no_toplevel(tmp_path):
    assert Git(cwd=str(tmp_path)).toplevel() is None
    assert FakeGit().toplevel() is None


# --- the drift line's operations ---------------------------------------------


def run_git(root, *args):
    return subprocess.run(
        ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t", *args],
        check=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
    ).stdout.decode().strip()


def committed(root, files, message):
    """Writes the files named, removes those mapped to None, commits; the
    new commit's SHA."""
    for name, text in files.items():
        path = root / name
        if text is None:
            path.unlink()
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    run_git(root, "add", "-A")
    run_git(root, "commit", "-qm", message)
    return run_git(root, "rev-parse", "HEAD")


@pytest.fixture
def audited(tmp_path):
    """A repository whose first commit holds a.md, b.md, sub/d.md and
    -opt.md, then one changing a.md, -opt.md and sub/d.md and renaming b.md;
    its root, the first commit's SHA, and the fake holding the same two
    trees."""
    root = tmp_path / "repo"
    git_repo(root)
    base_files = {"a.md": "a\n", "b.md": "b\n", "sub/d.md": "d\n", "-opt.md": "x\n"}
    base = committed(root, base_files, "files")
    (root / "b.md").rename(root / "moved.md")
    head = committed(root, {"a.md": "changed\n", "-opt.md": "y\n", "sub/d.md": None}, "changes")
    head_files = {"a.md": "changed\n", "moved.md": "b\n", "-opt.md": "y\n"}
    return root, base, FakeGit(commits={base: base_files, head: head_files}, head=head)


CITED = ["a.md", "b.md", "sub/d.md", "-opt.md", "*.md", ":(glob)**", "missing.md"]


def test_changed_paths_reads_the_same_from_a_real_repo_and_the_fake(audited):
    root, base, fake = audited
    want = {"a.md", "b.md", "sub/d.md", "-opt.md"}

    assert Git(cwd=str(root)).changed_paths(base, CITED) == want
    assert fake.changed_paths(base, CITED) == want


def test_changed_paths_are_from_the_top_whatever_the_directory_and_diff_relative(audited):
    root, base, _ = audited
    run_git(root, "config", "diff.relative", "true")

    assert Git(cwd=str(root / "sub")).changed_paths(base, ["a.md", "sub/d.md"]) \
        == {"a.md", "sub/d.md"}


def test_an_uncommitted_change_is_not_a_changed_path(audited):
    root, _, _ = audited
    (root / "moved.md").write_text("uncommitted\n")
    head = run_git(root, "rev-parse", "HEAD")
    run_git(root, "commit", "-q", "--allow-empty", "-m", "nothing")

    assert Git(cwd=str(root)).changed_paths(head, ["moved.md"]) == set()


def test_changed_paths_fail_for_a_commit_the_clone_lacks_or_an_unborn_head(audited, tmp_path):
    root, _, fake = audited
    unborn = tmp_path / "unborn"
    git_repo(unborn)
    missing = "deadbeef" * 5

    assert Git(cwd=str(root)).changed_paths(missing, ["a.md"]) is None
    assert fake.changed_paths(missing, ["a.md"]) is None
    assert Git(cwd=str(unborn)).changed_paths(missing, ["a.md"]) is None
    assert FakeGit(commits={missing: {}}).changed_paths(missing, ["a.md"]) is None


def test_head_and_commit_presence_read_the_same_from_a_real_repo_and_the_fake(audited, tmp_path):
    root, base, fake = audited
    unborn = tmp_path / "unborn"
    git_repo(unborn)
    missing = "deadbeef" * 5
    real = Git(cwd=str(root))

    assert (real.has_head_commit(), Git(cwd=str(unborn)).has_head_commit()) == (True, False)
    assert (fake.has_head_commit(), FakeGit().has_head_commit()) == (True, False)
    assert (real.has_commit(base), real.has_commit(missing)) == (True, False)
    assert (fake.has_commit(base), fake.has_commit(missing)) == (True, False)
