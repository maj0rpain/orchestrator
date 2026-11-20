"""The git adapter: the one place the Python side runs `git`, and its fake.

Each operation is named for what its callers need, as the gh adapter's are
(ADR-0033): the origin URL the repo pin reads, the checkout's toplevel
the issue noun finds the triage-labels doc under, and the comparisons
an audit body's drift line reads. Each later noun adds the
operations it needs, each with a test run against a real repository and
against FakeGit, asserting the same answers.
"""
from __future__ import annotations

import subprocess
from typing import Dict, List, Mapping, Optional, Sequence, Set


class Git:
    """The real operations, each a `git` run in <cwd> (the current directory
    when None) with <env> (the process's own when None)."""

    def __init__(
        self, cwd: Optional[str] = None, env: Optional[Mapping[str, str]] = None
    ) -> None:
        self.cwd = cwd
        self.env = None if env is None else dict(env)

    def _run(self, args: List[str]) -> "subprocess.CompletedProcess[bytes]":
        return subprocess.run(
            ["git", *args],
            cwd=self.cwd,
            env=self.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def origin_url(self) -> Optional[str]:
        """The `origin` remote's URL; None when the repository has no origin,
        or there is no repository - any failure of the read, as the bash
        resolver's `git remote get-url origin 2>/dev/null` takes it."""
        run = self._run(["remote", "get-url", "origin"])
        if run.returncode != 0:
            return None
        return run.stdout.decode("utf-8", "surrogateescape").rstrip("\n")

    def toplevel(self) -> Optional[str]:
        """The checkout's root, as orch.sh's ROOT block reads it; None outside
        a repository."""
        run = self._run(["rev-parse", "--show-toplevel"])
        if run.returncode != 0:
            return None
        return run.stdout.decode("utf-8", "surrogateescape").rstrip("\n")

    def changed_paths(self, base: str, paths: Sequence[str]) -> Optional[Set[str]]:
        """Which of <paths> differ between commit <base>'s tree and HEAD's:
        one diff for all of them, each a literal path from the top level
        whatever the directory or the user's diff config, renames not
        detected. None when the comparison cannot be made."""
        run = self._run(
            ["diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", "--no-relative",
             base, "HEAD", "--", *(":(top,literal)" + path for path in paths)]
        )
        if run.returncode != 0:
            return None
        names = run.stdout.decode("utf-8", "surrogateescape").split("\0")
        return {name for name in names if name}

    def has_head_commit(self) -> bool:
        """Whether HEAD names a commit: False on an unborn branch."""
        return self._run(["rev-parse", "--verify", "-q", "HEAD^{commit}"]).returncode == 0

    def has_commit(self, sha: str) -> bool:
        """Whether the clone holds commit <sha>."""
        return self._run(["cat-file", "-e", sha + "^{commit}"]).returncode == 0


class FakeGit:
    """The in-process fake: a repository held in memory. <remotes> maps each
    remote's name to its URL; <toplevel> is its top-level directory, None
    for no repository; <commits> maps each commit's SHA to its tree, a path
    to its contents; <head> is HEAD's commit, None on an unborn branch;
    <diff_fails> makes every comparison fail, as a git that cannot read its
    objects does."""

    def __init__(
        self,
        remotes: Optional[Dict[str, str]] = None,
        toplevel: Optional[str] = None,
        commits: Optional[Dict[str, Dict[str, str]]] = None,
        head: Optional[str] = None,
        diff_fails: bool = False,
    ) -> None:
        self.remotes = dict(remotes or {})
        self.root = toplevel
        self.commits = dict(commits or {})
        self.head = head
        self.diff_fails = diff_fails

    def origin_url(self) -> Optional[str]:
        return self.remotes.get("origin")

    def toplevel(self) -> Optional[str]:
        return self.root

    def changed_paths(self, base: str, paths: Sequence[str]) -> Optional[Set[str]]:
        if self.diff_fails or self.head is None or base not in self.commits:
            return None
        old, new = self.commits[base], self.commits[self.head]
        return {path for path in paths if old.get(path) != new.get(path)}

    def has_head_commit(self) -> bool:
        return self.head is not None

    def has_commit(self, sha: str) -> bool:
        return sha in self.commits
