"""The git adapter: the one place the Python side runs `git`, and its fake.

Each operation is named for what its callers need, as the gh adapter's are
(ADR-0033): the origin URL the repo pin reads, and the checkout's toplevel
the issue noun finds the triage-labels doc under. Each later noun adds the
operations it needs, each with a test run against a real repository and
against FakeGit, asserting the same answers.
"""
from __future__ import annotations

import subprocess
from typing import Dict, List, Mapping, Optional


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


class FakeGit:
    """The in-process fake: a repository held in memory. <remotes> maps each
    remote's name to its URL; <toplevel> is the checkout's root, None for no
    repository."""

    def __init__(
        self, remotes: Optional[Dict[str, str]] = None, toplevel: Optional[str] = None
    ) -> None:
        self.remotes = dict(remotes or {})
        self.root = toplevel

    def origin_url(self) -> Optional[str]:
        return self.remotes.get("origin")

    def toplevel(self) -> Optional[str]:
        return self.root
