"""The git adapter: the one place the Python side runs `git`, and its fake.

Each operation is named for what its callers need, as the gh adapter's are
(ADR-0033): the origin URL the repo pin reads, the checkout's toplevel
the issue noun finds the triage-labels doc under, the toplevel of another
directory's checkout the outside-a-checkout remedy names, the comparisons
an audit body's drift line reads, the commit resolution, fetches, file and
line histories finding triage's scan, Lines fate and the default-branch
lookup read, and the working-tree state, object names, config value and main
checkout the verification noun reads. There is no generic run: each later noun adds the operations it
needs, each with a test run against a real repository and against FakeGit,
asserting the same answers. The scan's, Lines fate's and the lookup's
operations run at the checkout's top level, and answer their "could not"
value, never raising, on a git failure.
"""
from __future__ import annotations

import re
import subprocess
from typing import Any, Dict, List, NamedTuple, Optional, Sequence, Set, Tuple


class FileDiff(NamedTuple):
    """One file's zero-context diff between two revisions: whether the file
    differs, and the diff's text, empty when it does not."""

    differs: bool
    text: str


# Each seeded operation's "could not" value: what it answers on a git failure,
# and what FakeGit answers for a call nothing was seeded for.
COULD_NOT: Dict[str, Any] = {
    "resolve_commit": None,
    "fetch_pr_head": False,
    "fetch_default_branch": False,
    "path_exists_at": False,
    "file_diff": None,
    "merge_base": None,
    "is_ancestor": False,
    "file_commits": None,
    "first_parent_file_commits": None,
    "file_commits_oldest_first": None,
    "newest_file_commit": None,
    "newest_lines_commit": None,
    "blame_last_seen": None,
    "origin_head_branch": None,
    "is_branch_name": False,
    "tree_state": None,
    "text_hash": None,
    "config_value": None,
    "main_checkout": None,
}

# A commit's full SHA-1 name, the only one the bash scan's line-range log
# and blame took: a SHA-256 name matches neither, as it matched neither there.
_FULL_SHA = re.compile(r"[0-9a-f]{40}")
# A porcelain blame's header line: the commit's full SHA-1 name, then line
# numbers.
_BLAME_HEADER = re.compile(r"(%s) [0-9]" % _FULL_SHA.pattern)


class Git:
    """The real operations, each a `git` run in <cwd> (the current directory
    when None)."""

    def __init__(self, cwd: Optional[str] = None) -> None:
        self.cwd = cwd
        self._top_level: Optional[str] = None

    def _run(
        self, args: List[str], cwd: Optional[str] = None
    ) -> "subprocess.CompletedProcess[bytes]":
        return subprocess.run(
            ["git", *args],
            cwd=self.cwd if cwd is None else cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def _output(self, args: List[str]) -> Optional[str]:
        """The one line a `git` run prints, its newline stripped; None when
        the run fails."""
        run = self._run(args)
        if run.returncode != 0:
            return None
        return run.stdout.decode("utf-8", "surrogateescape").rstrip("\n")

    def _top(self) -> Optional[str]:
        """The checkout's top level, read once: None outside a checkout."""
        if self._top_level is None:
            self._top_level = self.toplevel()
        return self._top_level

    def _run_at_top(self, args: List[str]) -> "subprocess.CompletedProcess[bytes]":
        """A `git` run at the checkout's top level, as bash's `git -C "$ROOT"`,
        so a root-relative path reads the same from any directory of it;
        outside a checkout, where it runs, for git to fail as it does."""
        return self._run(args, cwd=self._top())

    def _text_at_top(self, args: List[str]) -> Optional[str]:
        """What a `git` run at the top level prints; None when it fails."""
        run = self._run_at_top(args)
        if run.returncode != 0:
            return None
        return run.stdout.decode("utf-8", "surrogateescape")

    def _line_at_top(self, args: List[str]) -> Optional[str]:
        """The one line a `git` run at the top level prints, stripped; None
        when it fails or prints nothing."""
        text = self._text_at_top(args)
        return (text.strip() or None) if text is not None else None

    def _run_input(
        self, args: List[str], data: bytes, cwd: Optional[str] = None
    ) -> "subprocess.CompletedProcess[bytes]":
        """A `git` run, as _run, reading <data> on stdin."""
        return subprocess.run(
            ["git", *args], cwd=self.cwd if cwd is None else cwd, input=data,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def _file_log(self, flags: List[str], ref: str, since: str, path: str) -> Optional[List[str]]:
        """The full SHAs a `log <flags>` of the commits of <ref> since
        <since> touching <path> lists, in its order, each line taken as it
        is, unfiltered as the bash scan took them; None when it cannot run,
        never the empty list of a log that found no commit."""
        text = self._text_at_top(
            ["log", *flags, "--format=%H", ref, "^" + since, "--", ":(top,literal)" + path]
        )
        if text is None:
            return None
        return text.split()

    def origin_url(self) -> Optional[str]:
        """The `origin` remote's URL; None when the repository has no origin,
        or there is no repository - any failure of the read, as the bash
        resolver's `git remote get-url origin 2>/dev/null` takes it."""
        return self._output(["remote", "get-url", "origin"])

    def toplevel(self) -> Optional[str]:
        """The checkout's root, as orch.sh's ROOT block reads it; None outside
        a repository."""
        return self.toplevel_at(None)

    def toplevel_at(self, path: Optional[str]) -> Optional[str]:
        """The root of the checkout directory <path> is in (this adapter's
        own directory when None), as `git -C <path> rev-parse --show-toplevel`
        reads it; None when it is in no repository or does not exist."""
        return self._output(
            (["-C", path] if path is not None else []) + ["rev-parse", "--show-toplevel"]
        )

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

    # The scan's, Lines fate's and the default-branch lookup's operations, each
    # run at the top level, each a "could not" value on a git failure.

    def resolve_commit(self, rev: str) -> Optional[str]:
        """The full SHA of the commit <rev> names; None when it names none
        the clone holds."""
        return self._line_at_top(["rev-parse", "--verify", "-q", rev + "^{commit}"])

    def fetch_pr_head(self, pr: str) -> bool:
        """Fetches pull request <pr>'s head from origin, `refs/pull/<pr>/head`,
        so a squash-merged PR's head commit is in the clone: whether it did."""
        return self._run_at_top(["fetch", "-q", "origin", "refs/pull/%s/head" % pr]).returncode == 0

    def fetch_default_branch(self, branch: str) -> bool:
        """Fetches origin's <branch> into its remote ref,
        `refs/remotes/origin/<branch>`, forced: whether it did."""
        refspec = "+refs/heads/%s:refs/remotes/origin/%s" % (branch, branch)
        return self._run_at_top(["fetch", "-q", "origin", refspec]).returncode == 0

    def path_exists_at(self, ref: str, path: str) -> bool:
        """Whether <ref>'s tree holds <path>, from the top level; False too
        when <ref> names nothing."""
        return self._run_at_top(["cat-file", "-e", "%s:%s" % (ref, path)]).returncode == 0

    def file_diff(self, old: str, new: str, path: str) -> Optional[FileDiff]:
        """The zero-context diff of the one file <path>, from the top level,
        between revisions <old> and <new>, whatever the user's diff config;
        None when the diff cannot be made."""
        run = self._run_at_top(
            ["diff", "--exit-code", "-U0", "--no-ext-diff", "--no-color", old, new,
             "--", ":(top,literal)" + path]
        )
        if run.returncode not in (0, 1):
            return None
        return FileDiff(run.returncode == 1, run.stdout.decode("utf-8", "surrogateescape"))

    def merge_base(self, one: str, other: str) -> Optional[str]:
        """The best common ancestor of commits <one> and <other>; None when
        they have none, or either names no commit."""
        return self._line_at_top(["merge-base", one, other])

    def is_ancestor(self, commit: str, of: str) -> bool:
        """Whether <commit> is <of> or one of its ancestors; False too when
        either names no commit."""
        return self._run_at_top(["merge-base", "--is-ancestor", commit, of]).returncode == 0

    def file_commits(self, ref: str, since: str, path: str) -> Optional[List[str]]:
        """The commits of <ref> not in <since> that touch <path>, newest
        first: `log <ref> ^<since> -- <path>`."""
        return self._file_log([], ref, since, path)

    def first_parent_file_commits(self, ref: str, since: str, path: str) -> Optional[List[str]]:
        """The same, along <ref>'s first-parent line alone, a merge counted
        by what it brought its first parent."""
        return self._file_log(["--first-parent"], ref, since, path)

    def file_commits_oldest_first(self, ref: str, since: str, path: str) -> Optional[List[str]]:
        """The commits file_commits lists, oldest first."""
        return self._file_log(["--reverse"], ref, since, path)

    def newest_file_commit(self, ref: str, since: str, path: str) -> Optional[List[str]]:
        """The newest of the commits file_commits lists, alone in its list:
        empty when there is none."""
        return self._file_log(["-1"], ref, since, path)

    def newest_lines_commit(
        self, ref: str, since: str, path: str, ranges: Sequence[Tuple[int, int]]
    ) -> Optional[List[str]]:
        """The newest commit of <ref> not in <since> to touch any of the
        <ranges>, (start, end) line ranges of <path> at <ref>, alone in its
        list: `log -1 -L <start>,<end>:<path>...`. Empty when none did, or
        its first line is no full SHA-1 name; None when the log cannot run,
        as for a range past the file's end."""
        follow = [arg for start, end in ranges for arg in ("-L", "%d,%d:%s" % (start, end, path))]
        text = self._text_at_top(["log", "-1", "--format=%H", *follow, ref, "^" + since])
        if text is None:
            return None
        first = text.split("\n", 1)[0]
        return [first] if _FULL_SHA.fullmatch(first) else []

    def blame_last_seen(
        self, old: str, ref: str, path: str, start: int, end: int
    ) -> Optional[List[str]]:
        """The commits a reverse blame of lines <start>-<end> of <path> at
        <old> names, from <old> to <ref>: each line's last commit to hold it,
        <ref>'s own for a line it still holds, read from the headers naming
        a full SHA-1. Sorted, each once; None when the blame cannot run."""
        text = self._text_at_top(
            ["blame", "--reverse", "--porcelain", "-L", "%d,%d" % (start, end),
             "%s..%s" % (old, ref), "--", path]
        )
        if text is None:
            return None
        return sorted({m.group(1) for m in map(_BLAME_HEADER.match, text.splitlines()) if m})

    def origin_head_branch(self) -> Optional[str]:
        """The branch origin/HEAD points at, read in full and its
        `refs/remotes/origin/` taken off - never --short, which a local
        branch named origin/<b> makes remotes/origin/<b>; None when
        origin/HEAD is not set. Unchecked: the caller checks it is a branch
        name."""
        ref = self._line_at_top(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"])
        if ref is None:
            return None
        prefix = "refs/remotes/origin/"
        return ref[len(prefix):] if ref.startswith(prefix) else ref

    def is_branch_name(self, name: str) -> bool:
        """Whether <name> is a valid branch name, as `check-ref-format
        --branch` takes it: False for an empty one."""
        return self._run_at_top(["check-ref-format", "--branch", name]).returncode == 0

    # The verification noun's operations, each run at the top level, each None
    # on a git failure.

    def tree_state(self) -> Optional[str]:
        """The working-tree state, as the bash verification noun hashes it: the
        object name of a text holding what `rev-parse HEAD` prints, `none`
        after it when it fails (an unborn branch, where it prints HEAD), the
        tracked files' changes against HEAD, staged or not, as a binary diff,
        and a line per untracked file git does not ignore, by its object name,
        .orchestrator left out. Ignored files never count. None outside a
        checkout."""
        top = self._top()
        if top is None:
            return None
        named_head = self._run_at_top(["rev-parse", "HEAD"])
        head = named_head.stdout + (b"" if named_head.returncode == 0 else b"none\n")
        text = b"head " + head.rstrip(b"\n") + b"\n"
        diff = self._run_at_top(["diff", "HEAD", "--binary"])
        if diff.returncode != 0:
            diff = self._run_at_top(["diff", "--binary"])
        if diff.returncode == 0:
            text += diff.stdout
        listed = self._run_at_top(
            ["ls-files", "--others", "--exclude-standard", "-z", "--", ":!.orchestrator"]
        )
        if listed.returncode == 0:
            for name in listed.stdout.split(b"\0"):
                if name:
                    named = self._run_at_top(
                        ["hash-object", "--", name.decode("utf-8", "surrogateescape")]
                    )
                    sha = named.stdout.strip() if named.returncode == 0 else b""
                    text += b"untracked " + name + b" " + sha + b"\n"
        return self._hash(text)

    def _hash(self, data: bytes) -> Optional[str]:
        run = self._run_input(["hash-object", "--stdin"], data, cwd=self._top())
        if run.returncode != 0:
            return None
        return run.stdout.decode("utf-8", "surrogateescape").strip() or None

    def text_hash(self, text: str) -> Optional[str]:
        """The object name `git hash-object --stdin` gives <text>, as UTF-8."""
        return self._hash(text.encode("utf-8", "surrogateescape"))

    def config_value(self, key: str) -> Optional[str]:
        """The value git config holds for <key>; None when it holds none."""
        return self._line_at_top(["config", "--get", key])

    def main_checkout(self) -> Optional[str]:
        """The main checkout's root: the first entry `git worktree list`
        prints. None when the list fails or is empty."""
        text = self._text_at_top(["worktree", "list", "--porcelain"])
        for line in (text or "").splitlines():
            if line.startswith("worktree "):
                return line[len("worktree "):]
        return None


class FakeGit:
    """The in-process fake: a repository held in memory. <remotes> maps each
    remote's name to its URL; <toplevel> is its top-level directory, None
    for no repository; <commits> maps each commit's SHA to its tree, a path
    to its contents; <head> is HEAD's commit, None on an unborn branch;
    <diff_fails> makes every comparison fail, as a git that cannot read its
    objects does; <checkouts> maps each other directory in a checkout to
    that checkout's root.

    The operations COULD_NOT names answer what seed() set for their
    arguments, and their "could not" value for a call nothing was seeded
    for."""

    def __init__(
        self,
        remotes: Optional[Dict[str, str]] = None,
        toplevel: Optional[str] = None,
        commits: Optional[Dict[str, Dict[str, str]]] = None,
        head: Optional[str] = None,
        diff_fails: bool = False,
        checkouts: Optional[Dict[str, str]] = None,
    ) -> None:
        self.remotes = dict(remotes or {})
        self.root = toplevel
        self.checkouts = dict(checkouts or {})
        self.commits = dict(commits or {})
        self.head = head
        self.diff_fails = diff_fails
        self._answers: Dict[Tuple[Any, ...], Any] = {}

    def seed(self, name: str, *args: Any, answer: Any) -> None:
        """Seeds operation <name>'s answer to <args>: <answer>, replacing any
        seeded before."""
        if name not in COULD_NOT:
            raise ValueError("FakeGit has no seeded operation %r" % name)
        self._answers[_call_key(name, args)] = answer

    def _answer(self, name: str, *args: Any) -> Any:
        answer = self._answers.get(_call_key(name, args), COULD_NOT[name])
        return list(answer) if isinstance(answer, list) else answer

    def origin_url(self) -> Optional[str]:
        return self.remotes.get("origin")

    def toplevel(self) -> Optional[str]:
        return self.root

    def toplevel_at(self, path: Optional[str]) -> Optional[str]:
        return self.root if path is None else self.checkouts.get(path)

    def changed_paths(self, base: str, paths: Sequence[str]) -> Optional[Set[str]]:
        if self.diff_fails or self.head is None or base not in self.commits:
            return None
        old, new = self.commits[base], self.commits[self.head]
        return {path for path in paths if old.get(path) != new.get(path)}

    def has_head_commit(self) -> bool:
        return self.head is not None

    def has_commit(self, sha: str) -> bool:
        return sha in self.commits

    def resolve_commit(self, rev: str) -> Optional[str]:
        return self._answer("resolve_commit", rev)

    def fetch_pr_head(self, pr: str) -> bool:
        return self._answer("fetch_pr_head", pr)

    def fetch_default_branch(self, branch: str) -> bool:
        return self._answer("fetch_default_branch", branch)

    def path_exists_at(self, ref: str, path: str) -> bool:
        return self._answer("path_exists_at", ref, path)

    def file_diff(self, old: str, new: str, path: str) -> Optional[FileDiff]:
        return self._answer("file_diff", old, new, path)

    def merge_base(self, one: str, other: str) -> Optional[str]:
        return self._answer("merge_base", one, other)

    def is_ancestor(self, commit: str, of: str) -> bool:
        return self._answer("is_ancestor", commit, of)

    def file_commits(self, ref: str, since: str, path: str) -> Optional[List[str]]:
        return self._answer("file_commits", ref, since, path)

    def first_parent_file_commits(self, ref: str, since: str, path: str) -> Optional[List[str]]:
        return self._answer("first_parent_file_commits", ref, since, path)

    def file_commits_oldest_first(self, ref: str, since: str, path: str) -> Optional[List[str]]:
        return self._answer("file_commits_oldest_first", ref, since, path)

    def newest_file_commit(self, ref: str, since: str, path: str) -> Optional[List[str]]:
        return self._answer("newest_file_commit", ref, since, path)

    def newest_lines_commit(
        self, ref: str, since: str, path: str, ranges: Sequence[Tuple[int, int]]
    ) -> Optional[List[str]]:
        return self._answer("newest_lines_commit", ref, since, path, ranges)

    def blame_last_seen(
        self, old: str, ref: str, path: str, start: int, end: int
    ) -> Optional[List[str]]:
        return self._answer("blame_last_seen", old, ref, path, start, end)

    def origin_head_branch(self) -> Optional[str]:
        return self._answer("origin_head_branch")

    def is_branch_name(self, name: str) -> bool:
        return self._answer("is_branch_name", name)

    def tree_state(self) -> Optional[str]:
        return self._answer("tree_state")

    def text_hash(self, text: str) -> Optional[str]:
        return self._answer("text_hash", text)

    def config_value(self, key: str) -> Optional[str]:
        return self._answer("config_value", key)

    def main_checkout(self) -> Optional[str]:
        return self._answer("main_checkout")


def _call_key(name: str, args: Sequence[Any]) -> Tuple[Any, ...]:
    """A call's key among the seeded answers: a list argument, such as a
    sequence of line ranges, keyed as the tuple of its items."""
    return (name,) + tuple(_frozen(arg) for arg in args)


def _frozen(value: Any) -> Any:
    if isinstance(value, (list, tuple)):
        return tuple(_frozen(item) for item in value)
    return value
