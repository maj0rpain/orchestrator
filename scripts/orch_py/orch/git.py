"""The git adapter: the one place the Python side runs `git`, and its fake.

Each operation is named for what its callers need, as the gh adapter's are
(ADR-0033): the origin URL the repo pin reads, the checkout's toplevel
the issue noun finds the triage-labels doc under, the toplevel of another
directory's checkout the outside-a-checkout remedy names, the comparisons
an audit body's drift line reads, the commit resolution, fetches, file and
line histories finding triage's scan, Lines fate and the default-branch
lookup read, the working-tree state, object names, config value and main
checkout the verification noun reads, the common directory the git exclude
writer (orch.common) appends under, the current branch a review pass
starts on, the worktree list, another checkout's branch and its git folder
the checkout scan (orch.checkout) reads, the worktree removal a side
checkout's teardown (orch.side_checkout) makes, and the base fetch and
detached worktree add that side-checkout add makes, the push the gh
adapter's claim delete makes, the empty commit and its lease push the claim
create makes, branch retire's local branch reads and rename, origin probe,
tracking push and remote
delete (orch.branch), the dirty paths the planning allowlist's flow-start scan
judges, the scoped git config reads, writes and unsets
(`config_regexp`, `config_set`, `config_unset`) the agent noun uses, branch
off's and branch create's fork (a new branch checked out with no tracking),
and what the ticket nouns need: a ticket branch's create with no tracking and
its delete (-D), the worktree add that checks it out and the removal that takes
it back out, the rebase, rebase abort, unmerged-path listing and
fast-forward-only merge `ticket merge` runs in a given checkout, the
status the clean-tree check (orch.common) reads there, and the
merge-in-progress probe, merge abort, hard reset and clean of the
discard sequence (orch.checkout). A ticket branch's ref verify is
branch_exists, and the toplevel read at its worktree's path toplevel_at.
`review ci`'s push-time and no-CI-evidence checks read a ref's verify, a
remote-tracking reflog with its unix dates, a commit's existence
(has_commit) and a full-tree name listing under a path.
There is no generic run: each later noun adds the operations it needs, each
with a test run against a real repository and against FakeGit, asserting the
same answers. The scan's, Lines fate's and the lookup's operations run at the
checkout's top level, and answer their "could not" value, never raising, on a
git failure. An operation a caller hands git's own failure on from answers a
GitFailure, its status and stderr.
"""
from __future__ import annotations

import re
import subprocess
from typing import Any, Dict, Iterable, List, NamedTuple, Optional, Sequence, Set, Tuple, Union

from orch.common import ORCH_DIR_NAME, stderr_write, trim


class Worktree(NamedTuple):
    """One entry of `git worktree list`: its path, and git's own record of
    the branch checked out there, None on a detached HEAD."""

    path: str
    branch: Optional[str]


class GitFailure(NamedTuple):
    """A `git` run that failed: its exit status, and what it printed on
    stderr, for a caller that hands both on as bash's `set -e` did."""

    code: int
    stderr: str


def git_failed(failure: Optional[GitFailure]) -> bool:
    """Hands a failed git run's stderr on, as bash let it through: whether
    the run failed."""
    if failure is None:
        return False
    stderr_write(failure.stderr)
    return True


class FileDiff(NamedTuple):
    """One file's zero-context diff between two revisions: whether the file
    differs, and the diff's text, empty when it does not."""

    differs: bool
    text: str


# Each seeded operation's "could not" value: what it answers on a git failure,
# and what FakeGit answers for a call nothing was seeded for.
COULD_NOT: Dict[str, Any] = {
    "resolve_commit": None,
    "ref_exists": False,
    "reflog_dates": None,
    "tree_names": None,
    "fetch_pr_head": False,
    "fetch_default_branch": False,
    "path_exists_at": False,
    "file_diff": None,
    "merge_base": None,
    "is_ancestor": False,
    "ancestry": None,
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
    "worktree_list": None,
    "branch_at": None,
    "absolute_git_dir_at": None,
    "git_common_dir": None,
    "current_branch": None,
    "push": "git gave no reason",
    "empty_commit": None,
    "push_new_ref": "git gave no reason",
    "fetch_prune": "git gave no reason",
    "refs_contents": None,
    "origin_has_branch": None,
    "push_set_upstream": "git gave no reason",
    "remote_delete": "git gave no reason",
    "worktree_remove": "git gave no reason",
    "fetch_branch_at": False,
    "worktree_add_detached_at": GitFailure(1, ""),
    "dirty_paths": "git gave no reason",
    "worktree_add": GitFailure(1, ""),
    "worktree_delete": GitFailure(1, ""),
    "rebase_at": GitFailure(1, ""),
    "rebase_abort_at": GitFailure(1, ""),
    "unmerged_paths_at": [],
    "merge_ff_only_at": GitFailure(1, ""),
    "merge_no_edit_at": GitFailure(1, ""),
    "newest_merge_commit": None,
    "second_parent": None,
    "status_at": GitFailure(1, ""),
    "merge_in_progress_at": False,
    "merge_abort_at": False,
    "reset_hard_at": False,
    "clean_at": False,
}

def git_push_reason(stderr: str) -> str:
    """The reason a git push's <stderr> gives - bash git_push_reason: its
    ` ! ` ref lines, trimmed and joined by "; ", since they carry a
    rejection's cause; else its first fatal: line, an auth or network
    failure's; else its first non-empty line; else "git gave no reason".
    git's first line is often just "To <url>", so it comes last."""
    bangs: List[str] = []
    fatal = first = ""
    for line in stderr.split("\n"):
        trimmed = trim(line)
        if line.startswith(" ! "):
            bangs.append(trimmed)
        elif line.startswith("fatal:") and not fatal:
            fatal = line
        if not first:
            first = trimmed
    return "; ".join(bangs) or fatal or first or "git gave no reason"

# A commit's full SHA-1 name, the only one the bash scan's line-range log
# and blame took: a SHA-256 name matches neither, as it matched neither there.
_FULL_SHA = re.compile(r"[0-9a-f]{40}")
# A porcelain blame's header line: the commit's full SHA-1 name, then line
# numbers.
_BLAME_HEADER = re.compile(r"(%s) [0-9]" % _FULL_SHA.pattern)
_CONFIG_SCOPES = ("local", "global")


def _check_config_scope(scope: str) -> None:
    if scope not in _CONFIG_SCOPES:
        raise ValueError("git config scope must be 'local' or 'global', got %r" % scope)


def _config_entries(
    entries: Optional[Union[Dict[str, Optional[str]], Sequence[Tuple[str, Optional[str]]]]],
) -> List[Tuple[str, Optional[str]]]:
    if entries is None:
        return []
    if isinstance(entries, dict):
        return list(entries.items())
    return list(entries)


class Git:
    """The real operations, each a `git` run in <cwd> (the current directory
    when None)."""

    def __init__(self, cwd: Optional[str] = None) -> None:
        self.cwd = cwd
        self._top_level: Optional[str] = None

    def _run(
        self, args: List[str], cwd: Optional[str] = None, data: Optional[bytes] = None
    ) -> "subprocess.CompletedProcess[bytes]":
        """A `git` run, reading <data> on stdin, or nothing when None."""
        source = {"stdin": subprocess.DEVNULL} if data is None else {"input": data}
        return subprocess.run(
            ["git", *args],
            cwd=self.cwd if cwd is None else cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            **source,
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

    # review ci's push-time and no-CI-evidence reads, run where the adapter
    # runs, as the bash review ci ran its git; each a "could not" value on a
    # git failure.

    def ref_exists(self, ref: str) -> bool:
        """Whether the full ref <ref> names an object: `rev-parse -q
        --verify`."""
        return self._run(["rev-parse", "-q", "--verify", ref]).returncode == 0

    def reflog_dates(self, ref: str) -> Optional[List[Tuple[str, int]]]:
        """Each entry of <ref>'s reflog, newest first: the SHA it set the ref
        to and the unix second it did; None when the reflog cannot be read -
        a ref with none included."""
        run = self._run(["reflog", "show", "--date=unix", "--format=%H %gd", ref, "--"])
        if run.returncode != 0:
            return None
        entries = []
        for line in run.stdout.decode("utf-8", "surrogateescape").splitlines():
            sha, _, selector = line.partition(" ")
            date = selector.rpartition("@{")[2][:-1] if selector.endswith("}") else ""
            if date.isdigit():
                entries.append((sha, int(date)))
        return entries

    def tree_names(self, rev: str, path: str) -> Optional[List[str]]:
        """The names `ls-tree --full-tree --name-only <rev> -- <path>` lists -
        <path> read from the top level whatever the directory, so a directory
        given with its slash lists its entries, a sub-tree by its own name -
        each as it is, never quoted; None when <rev> names no tree the clone
        holds."""
        run = self._run(["ls-tree", "-z", "--full-tree", "--name-only", rev, "--", path])
        if run.returncode != 0:
            return None
        return [name for name in run.stdout.decode("utf-8", "surrogateescape").split("\0") if name]

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
        """Whether <commit> is <of> or one of its ancestors: ancestry's
        answer, False too where git cannot judge - either names no
        commit."""
        return self.ancestry(commit, of) is True

    def ancestry(self, commit: str, of: str) -> Optional[bool]:
        """Whether <commit> is <of> or one of its ancestors; None where git
        cannot judge - either names no commit - never read as a no."""
        code = self._run_at_top(["merge-base", "--is-ancestor", commit, of]).returncode
        return {0: True, 1: False}.get(code)

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

    # The planning allowlist's dirty-path scan's operation, run at the top
    # level as bash's `git -C "$ROOT" status` is.

    def dirty_paths(self) -> Union[List[str], str]:
        """Every path with tracked changes, staged or not, or an untracked
        file, from the top level, in `status --porcelain=v1 -z -uall`'s
        order: each untracked file named on its own, and both sides of a
        rename or copy, since the source is gone from where it was. When
        status cannot run, git's own error line, its stderr's first, instead:
        a str, never a list, so it cannot read as a clean tree."""
        run = self._run_at_top(["status", "--porcelain=v1", "-z", "-uall"])
        if run.returncode != 0:
            line = run.stderr.decode("utf-8", "surrogateescape").split("\n", 1)[0]
            return line or COULD_NOT["dirty_paths"]
        paths: List[str] = []
        want_source = False
        for rec in run.stdout.decode("utf-8", "surrogateescape").split("\0")[:-1]:
            if want_source:
                paths.append(rec)
                want_source = False
                continue
            paths.append(rec[3:])
            want_source = "R" in rec[:2] or "C" in rec[:2]
        return paths

    # The verification noun's operations, each run at the top level, each None
    # on a git failure.

    def tree_state(self) -> Optional[str]:
        """The working-tree state, as the bash verification noun hashed it, so
        a record a bash runner left still matches: the object name of a text
        holding what `rev-parse HEAD` prints, `none` after it when it fails (an
        unborn branch, where it prints HEAD), the tracked files' changes
        against HEAD, staged or not, as a binary diff, and a line per untracked
        file git does not ignore, by its object name, .orchestrator left out.
        Ignored files never count. None outside a checkout."""
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
            ["ls-files", "--others", "--exclude-standard", "-z", "--", ":!" + ORCH_DIR_NAME]
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
        run = self._run(["hash-object", "--stdin"], cwd=self._top(), data=data)
        if run.returncode != 0:
            return None
        return run.stdout.decode("utf-8", "surrogateescape").strip() or None

    def text_hash(self, text: str) -> Optional[str]:
        """The object name `git hash-object --stdin` gives <text>, as UTF-8."""
        return self._hash(text.encode("utf-8", "surrogateescape"))

    def config_value(self, key: str) -> Optional[str]:
        """The value git config holds for <key>; None when it holds none."""
        return self._line_at_top(["config", "--get", key])

    # The checkout scan's operations (orch.checkout), the list, and the main
    # checkout read from it, run where the adapter runs, as bash's
    # checkout_parse runs, the others in the checkout they name, as bash's
    # `git -C <path>`.

    def worktree_list(self) -> Optional[List[Worktree]]:
        """Every checkout of the clone, the main checkout first, read from
        `git worktree list --porcelain` - bash checkout_parse, the one place
        the porcelain is read: a Worktree for each `worktree` line, its branch
        the `branch refs/heads/` line after it. A worktree whose directory is
        gone is listed too. None when the list fails."""
        run = self._run(["worktree", "list", "--porcelain"])
        if run.returncode != 0:
            return None
        worktrees: List[Worktree] = []
        for line in run.stdout.decode("utf-8", "surrogateescape").split("\n"):
            if line.startswith("worktree "):
                worktrees.append(Worktree(line[len("worktree "):], None))
            elif line.startswith("branch refs/heads/") and worktrees:
                worktrees[-1] = worktrees[-1]._replace(branch=line[len("branch refs/heads/"):])
        return worktrees

    def main_checkout(self) -> Optional[str]:
        """The main checkout's root: the first entry `git worktree list`
        prints. None when the list fails or is empty."""
        worktrees = self.worktree_list()
        return worktrees[0].path if worktrees else None

    def branch_at(self, path: str) -> Optional[str]:
        """The branch checked out in the checkout at <path> - bash
        checkout_branch <path>, its refs/heads/ taken off: None on a
        detached HEAD, or where <path> is no checkout."""
        ref = self._output(["-C", path, "symbolic-ref", "--quiet", "HEAD"])
        if ref is None:
            return None
        prefix = "refs/heads/"
        return ref[len(prefix):] if ref.startswith(prefix) else ref

    def absolute_git_dir_at(self, path: str) -> Optional[str]:
        """The git folder of the checkout holding <path>, as `git -C <path>
        rev-parse --absolute-git-dir` prints it; None where <path> is in no
        checkout."""
        return self._output(["-C", path, "rev-parse", "--absolute-git-dir"])

    # The side checkout's teardown (orch.side_checkout), run in the checkout
    # it names, as bash's `git -C "$main_root" worktree remove`.

    def worktree_remove(self, checkout: str, path: str) -> Optional[str]:
        """`git -C <checkout> worktree remove <path>`, never with force, as
        bash side_checkout_remove_worktree ran it: None when the worktree is
        gone, else the first line of what git printed refusing it."""
        run = self._run(["-C", checkout, "worktree", "remove", path])
        if run.returncode == 0:
            return None
        return run.stderr.decode("utf-8", "surrogateescape").split("\n", 1)[0]

    # Side-checkout add's operations, run in the main checkout they name, as
    # bash's add runs them after its `cd "$main_root"`: the sweep before them
    # may have removed the checkout the command ran in.

    def fetch_branch_at(self, checkout: str, branch: str) -> bool:
        """`git -C <checkout> fetch --quiet origin
        +refs/heads/<branch>:refs/remotes/origin/<branch>`: origin's <branch>
        fetched into its remote ref, forced. Whether it did."""
        refspec = "+refs/heads/%s:refs/remotes/origin/%s" % (branch, branch)
        return self._run(["-C", checkout, "fetch", "--quiet", "origin", refspec]).returncode == 0

    def worktree_add_detached_at(self, checkout: str, path: str, ref: str
                                 ) -> Optional[GitFailure]:
        """`git -C <checkout> worktree add -q --detach <path> <ref>`: a new
        worktree at <path>, on no branch, at the commit <ref> names. None
        when it was added, else git's status and stderr."""
        return self._failure(["-C", checkout, "worktree", "add", "-q", "--detach", path, ref])


    # The git exclude writer's operation, run where the adapter runs, as the
    # bash writer's `git rev-parse` is.

    def git_common_dir(self) -> Optional[str]:
        """The clone's common directory, whose info/exclude is the one git
        reads for every worktree of it, as `rev-parse --git-common-dir` prints
        it: relative to the adapter's directory where git prints it so. None
        outside a repository."""
        return self._output(["rev-parse", "--git-common-dir"])

    # The review pass's operation, run where the adapter runs, as bash's
    # checkout_branch runs its `git -C .`.

    def current_branch(self) -> Optional[str]:
        """The branch HEAD names, its refs/heads/ taken off, as `symbolic-ref
        --quiet HEAD` reads it: an unborn one included. None on a detached
        HEAD, or outside a repository."""
        ref = self._output(["symbolic-ref", "--quiet", "HEAD"])
        if ref is None:
            return None
        prefix = "refs/heads/"
        return ref[len(prefix):] if ref.startswith(prefix) else ref

    # The claim delete's operation, run where the adapter runs, as bash's
    # git_push runs in orch.sh's directory.

    def push(self, remote: str, refspec: str) -> Optional[str]:
        """`git push <remote> <refspec>` - bash git_push: None when it
        landed, else the reason its stderr gives (git_push_reason)."""
        return self._push([remote, refspec])

    # The claim create's operations, run where the adapter runs, as bash's
    # adapter_claim_create runs its git.

    def empty_commit(self, subject: str, body: str) -> Optional[str]:
        """A commit of the empty tree with no parent, its message <subject>
        then <body> as two -m paragraphs: its name; None when git cannot make
        it."""
        tree = self._run(["hash-object", "-t", "tree", "--stdin"], data=b"")
        if tree.returncode != 0:
            return None
        return self._output(["commit-tree", tree.stdout.decode().strip(), "-m", subject,
                             "-m", body]) or None

    def push_new_ref(self, remote: str, commit: str, ref: str) -> Optional[str]:
        """`git push --force-with-lease=<ref>: <remote> <commit>:<ref>`: the
        push lands only where <remote> holds no <ref>. None when it landed,
        else its reason (git_push_reason)."""
        return self._push(["--force-with-lease=%s:" % ref, remote, "%s:%s" % (commit, ref)])

    # The claim list's operations, run where the adapter runs, as bash's
    # adapter_claim_list runs its git.

    def fetch_prune(self, remote: str, refspec: str) -> Optional[str]:
        """`git fetch --quiet --prune <remote> <refspec>`: None when it
        fetched, else its stderr, or "git gave no reason" for none."""
        run = self._run(["fetch", "--quiet", "--prune", remote, refspec])
        if run.returncode == 0:
            return None
        return run.stderr.decode("utf-8", "surrogateescape") or COULD_NOT["fetch_prune"]

    def refs_contents(self, prefix: str) -> Optional[List[Tuple[str, str]]]:
        """Every ref under <prefix>, in version (numeric) order, with the
        message of the commit it names - one for-each-ref; None when it
        fails."""
        run = self._run(["for-each-ref", "--sort=version:refname",
                         "--format=%(refname)%00%(contents)%00", prefix])
        if run.returncode != 0:
            return None
        fields = run.stdout.decode("utf-8", "surrogateescape").split("\0")
        # Each ref's record is `<ref>\0<message>\0\n`: the newline opens the
        # next ref's field.
        return [(fields[k].lstrip("\n"), fields[k + 1]) for k in range(0, len(fields) - 1, 2)]

    # Branch retire's operations (orch.branch), run where the adapter runs, as
    # bash's `branch retire` runs its git.

    def branch_exists(self, name: str) -> bool:
        """Whether local branch <name> exists: `rev-parse --verify --quiet
        refs/heads/<name>`."""
        return self._run(["rev-parse", "--verify", "--quiet", "refs/heads/" + name]).returncode == 0

    def branch_upstream(self, name: str) -> Optional[str]:
        """The full ref branch <name> tracks; None when it tracks none, or
        there is no such branch."""
        return self._output(
            ["rev-parse", "--symbolic-full-name", "--verify", "--quiet", name + "@{upstream}"]
        ) or None

    def branch_rename(self, old: str, new: str) -> Optional[GitFailure]:
        """`git branch -m <old> <new>`, its upstream moving with it: None when
        it renamed, else git's status and stderr."""
        return self._failure(["branch", "-m", old, new])

    def _failure(self, args: List[str]) -> Optional[GitFailure]:
        """A `git` run where the adapter runs: None when it succeeded, else
        its status and stderr. What it printed on stdout is dropped."""
        run = self._run(args)
        if run.returncode == 0:
            return None
        return GitFailure(run.returncode, run.stderr.decode("utf-8", "surrogateescape"))

    def origin_has_branch(self, name: str) -> Optional[bool]:
        """Whether origin has branch <name> - bash origin_has_branch, on
        ls-remote's own exit codes: True yes, False origin answered and it
        does not, None origin could not be asked."""
        code = self._run(
            ["ls-remote", "--quiet", "--exit-code", "origin", "refs/heads/" + name]
        ).returncode
        return {0: True, 2: False}.get(code)

    def push_set_upstream(self, remote: str, refspec: str) -> Optional[str]:
        """`git push -q -u <remote> <refspec>`: None when it landed and the
        branch tracks what it pushed, else its reason (git_push_reason)."""
        return self._push(["-q", "-u", remote, refspec])

    def remote_delete(self, remote: str, ref: str) -> Optional[str]:
        """`git push -q <remote> --delete <ref>`: None when <remote> no longer
        holds <ref>, else its reason (git_push_reason)."""
        return self._push(["-q", remote, "--delete", ref])

    def _push(self, args: List[str]) -> Optional[str]:
        run = self._run(["push", *args])
        if run.returncode == 0:
            return None
        return git_push_reason(run.stderr.decode("utf-8", "surrogateescape"))

    # The ticket nouns' operations: a ticket branch made and deleted where the
    # adapter runs, as bash's ticket-worktree add and teardown run them.

    def branch_create(self, name: str, start: str) -> Optional[GitFailure]:
        """`git branch -q --no-track <name> <start>`: a new local branch at
        <start> that tracks nothing, whatever branch.autoSetupMerge says. None
        when it was made, else git's status and stderr."""
        return self._failure(["branch", "-q", "--no-track", name, start])

    def checkout_new_branch(self, name: str, start: str) -> Optional[GitFailure]:
        """`git checkout -q --no-track -b <name> <start>`: a new local branch
        at <start>, checked out, tracking nothing whatever
        branch.autoSetupMerge says - branch off's and branch create's fork.
        None when it was made, else git's status and stderr, nothing moved."""
        return self._failure(["checkout", "-q", "--no-track", "-b", name, start])

    def checkout_existing_branch(self, name: str) -> Optional[GitFailure]:
        """`git checkout -q <name>`: checks out existing local branch <name>,
        a tag of its name never taken for it - branch create's restart. None
        when it is checked out, else git's status and stderr, nothing
        moved."""
        return self._failure(["checkout", "-q", name])

    def branch_delete(self, name: str) -> Optional[GitFailure]:
        """`git branch -q -D <name>`: deletes local branch <name>, merged or
        not, its config section with it. None when it is gone, else git's
        status and stderr."""
        return self._failure(["branch", "-q", "-D", name])

    def worktree_add(self, path: str, branch: str) -> Optional[GitFailure]:
        """`git worktree add -q <path> <branch>`: checks existing branch
        <branch> out in a new worktree at <path>, its parent folders made.
        None when it was added, else git's status and stderr."""
        return self._failure(["worktree", "add", "-q", path, branch])

    def worktree_delete(self, path: str) -> Optional[GitFailure]:
        """`git worktree remove <path>` where the adapter runs, never with
        force - the ticket worktree teardown's and add's back-out, which hand
        git's whole stderr on as bash's did, where worktree_remove keeps only
        its first line. None when the worktree is gone, else git's status and
        stderr."""
        return self._failure(["worktree", "remove", path])

    # The ticket merge's operations, each run in the checkout it names, as
    # bash's `git -C <path>`, a branch named in full (refs/heads/<b>) so a tag
    # of its name is never taken for it (#2337).

    def rebase_at(self, path: str, onto: str) -> Optional[GitFailure]:
        """`git -C <path> rebase -q <onto>`: rebases the branch checked out at
        <path> onto <onto>. None when it landed, else git's status and stderr,
        a conflict's rebase left in progress."""
        return self._failure(["-C", path, "rebase", "-q", onto])

    def rebase_abort_at(self, path: str) -> Optional[GitFailure]:
        """`git -C <path> rebase --abort`: None when the rebase in progress
        at <path> was aborted, its branch back at its prior tip, else git's
        status and stderr - a failure too when no rebase is in progress."""
        return self._failure(["-C", path, "rebase", "--abort"])

    def unmerged_paths_at(self, path: str) -> List[str]:
        """The unmerged paths of the checkout at <path>, `git -C <path> diff
        --name-only --diff-filter=U`'s lines: what tells a rebase stopped on a
        conflict from one failing any other way. Empty when there are none,
        and when the listing cannot run, as bash's `|| unmerged=""` read it."""
        run = self._run(["-C", path, "diff", "--name-only", "--diff-filter=U"])
        if run.returncode != 0:
            return []
        return run.stdout.decode("utf-8", "surrogateescape").splitlines()

    def merge_ff_only_at(self, path: str, ref: str) -> Optional[GitFailure]:
        """`git -C <path> merge -q --ff-only <ref>`: fast-forwards the branch
        checked out at <path> to <ref>. None when it moved, else git's status
        and stderr, the branch left at its tip."""
        return self._failure(["-C", path, "merge", "-q", "--ff-only", ref])

    # Branch sync's operations (orch.branch): the merge run in the checkout it
    # names, as bash's sync merges in $ROOT, the reads where the adapter runs.

    def merge_no_edit_at(self, path: str, ref: str) -> Optional[GitFailure]:
        """`git -C <path> merge --quiet --no-edit <ref>`: merges <ref> into
        the branch checked out at <path>, with git's own message. None when
        it merged, else git's status and stderr - a conflict's merge left in
        progress."""
        return self._failure(["-C", path, "merge", "--quiet", "--no-edit", ref])

    def newest_merge_commit(self, rev: str) -> Optional[str]:
        """The newest merge commit on <rev>'s first-parent chain, <rev>
        itself included, as `rev-list --first-parent --min-parents=2 -1`
        finds it: single-parent commits above it are passed over. None when
        the chain holds no merge, or git cannot read it."""
        return self._output(["rev-list", "--first-parent", "--min-parents=2", "-1", rev]) or None

    def second_parent(self, commit: str) -> Optional[str]:
        """The full SHA of <commit>'s second parent; None when it has none,
        or names no commit."""
        return self._output(["rev-parse", "--verify", "--quiet", commit + "^2^{commit}"]) or None

    # The clean-tree check's operation (orch.common) and the discard
    # sequence's (orch.checkout), each run in the checkout it names. The
    # sequence's steps answer only whether they ran, as bash silences them.

    def status_at(self, path: str) -> Union[str, GitFailure]:
        """`git -C <path> status --porcelain`'s text, empty for a clean
        tree; when status cannot run, git's status and stderr instead, never
        a str, so it cannot read as a clean tree."""
        run = self._run(["-C", path, "status", "--porcelain"])
        if run.returncode != 0:
            return GitFailure(run.returncode, run.stderr.decode("utf-8", "surrogateescape"))
        return run.stdout.decode("utf-8", "surrogateescape")

    def merge_in_progress_at(self, path: str) -> bool:
        """Whether a merge is in progress in the checkout at <path>: whether
        its MERGE_HEAD names a commit."""
        return self._run(
            ["-C", path, "rev-parse", "--quiet", "--verify", "MERGE_HEAD"]).returncode == 0

    def merge_abort_at(self, path: str) -> bool:
        """`git -C <path> merge --abort`: whether it aborted."""
        return self._run(["-C", path, "merge", "--abort"]).returncode == 0

    def reset_hard_at(self, path: str) -> bool:
        """`git -C <path> reset --hard -q`: whether the tracked files are
        back at HEAD."""
        return self._run(["-C", path, "reset", "--hard", "-q"]).returncode == 0

    def clean_at(self, path: str) -> bool:
        """`git -C <path> clean -fdq`: whether the untracked files and
        folders git does not ignore are gone."""
        return self._run(["-C", path, "clean", "-fdq"]).returncode == 0

    # Scoped git config operations for the agent noun, run where the adapter
    # runs, as bash's git_config_unset runs.

    def config_regexp(self, scope: str, pattern: str) -> Dict[str, str]:
        """The keys at <scope> ('local' or 'global') matching <pattern>, read
        from `git config --<scope> -z --get-regexp <pattern>`: leading and
        trailing spaces kept, a key with no value mapped to '', internal
        newlines kept, trailing newlines stripped, the last entry winning on
        duplicate keys, and an empty mapping when no key matches."""
        _check_config_scope(scope)
        run = self._run(["config", "--" + scope, "-z", "--get-regexp", "--", pattern])
        if run.returncode != 0:
            return {}
        out: Dict[str, str] = {}
        for rec in run.stdout.decode("utf-8", "surrogateescape").split("\0"):
            if not rec:
                continue
            if "\n" in rec:
                key, value = rec.split("\n", 1)
                out[key] = value.rstrip("\n")
            else:
                out[rec] = ""
        return out

    def config_set(self, scope: str, key: str, value: str) -> Optional[GitFailure]:
        """Writes <key> = <value> at <scope> ('local' or 'global'): None when
        it wrote, else git's status and stderr."""
        _check_config_scope(scope)
        return self._failure(["config", "--" + scope, "--", key, value])

    def config_unset(self, scope: str, key: str) -> bool:
        """Removes every value of <key> at <scope> ('local' or 'global'):
        True on exit 0 or exit 5 (key not set), False on any other failure
        such as a lock or write error."""
        _check_config_scope(scope)
        code = self._run(["config", "--" + scope, "--unset-all", "--", key]).returncode
        return code in (0, 5)


class FakeGit:
    """The in-process fake: a repository held in memory. <remotes> maps each
    remote's name to its URL; <toplevel> is its top-level directory, None
    for no repository; <commits> maps each commit's SHA to its tree, a path
    to its contents; <head> is HEAD's commit, None on an unborn branch;
    <diff_fails> makes every comparison fail, as a git that cannot read its
    objects does; <checkouts> maps each other directory in a checkout to
    that checkout's root; <local_config> and <global_config> hold the scoped
    git config entries (dict or sequence of (key, value|None) pairs, None
    for a valueless key); <config_write_fails> names scopes ('local',
    'global') or (scope, key) pairs whose config_set and config_unset calls
    fail, as a locked config file does, config_set answering git's lock
    refusal; <branches> maps each local branch's name to the full ref it
    tracks, None for none:
    branch_rename moves an entry as git moves a branch and its upstream,
    branch_create adds one tracking nothing, checkout_new_branch adds one
    tracking nothing at the commit resolve_commit seeds for its start and
    checks it out - current_branch and HEAD's resolve_commit answering it
    from then on - checkout_existing_branch checks one out, current_branch
    answering it from then on, and branch_delete drops one with its
    branch.<name>. config section, as -D does.

    The operations COULD_NOT names answer what seed() set for their
    arguments, and their "could not" value for a call nothing was seeded
    for - a GitFailure with no stderr for those answering one. config_value
    alone reads the config entries for a key nothing was seeded for."""

    def __init__(
        self,
        remotes: Optional[Dict[str, str]] = None,
        toplevel: Optional[str] = None,
        commits: Optional[Dict[str, Dict[str, str]]] = None,
        head: Optional[str] = None,
        diff_fails: bool = False,
        checkouts: Optional[Dict[str, str]] = None,
        local_config: Optional[
            Union[Dict[str, Optional[str]], Sequence[Tuple[str, Optional[str]]]]
        ] = None,
        global_config: Optional[
            Union[Dict[str, Optional[str]], Sequence[Tuple[str, Optional[str]]]]
        ] = None,
        config_write_fails: Optional[Iterable[Union[str, Tuple[str, str]]]] = None,
        branches: Optional[Dict[str, Optional[str]]] = None,
    ) -> None:
        self.remotes = dict(remotes or {})
        self.root = toplevel
        self.checkouts = dict(checkouts or {})
        self.commits = dict(commits or {})
        self.head = head
        self.diff_fails = diff_fails
        self._config: Dict[str, List[Tuple[str, Optional[str]]]] = {
            "local": _config_entries(local_config),
            "global": _config_entries(global_config),
        }
        self.config_write_fails: Set[Union[str, Tuple[str, str]]] = set(
            config_write_fails or ()
        )
        self.branches: Dict[str, Optional[str]] = dict(branches or {})
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

    def ref_exists(self, ref: str) -> bool:
        return self._answer("ref_exists", ref)

    def reflog_dates(self, ref: str) -> Optional[List[Tuple[str, int]]]:
        return self._answer("reflog_dates", ref)

    def tree_names(self, rev: str, path: str) -> Optional[List[str]]:
        return self._answer("tree_names", rev, path)

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

    def ancestry(self, commit: str, of: str) -> Optional[bool]:
        return self._answer("ancestry", commit, of)

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

    def dirty_paths(self) -> Union[List[str], str]:
        return self._answer("dirty_paths")

    def tree_state(self) -> Optional[str]:
        return self._answer("tree_state")

    def text_hash(self, text: str) -> Optional[str]:
        return self._answer("text_hash", text)

    def config_value(self, key: str) -> Optional[str]:
        """The seeded answer for <key>; else, as `git config --get` reads it,
        its last value in the local config, else in the global, blank read
        as none - so what config_set writes and branch_delete drops reads
        back."""
        seeded = self._answers.get(_call_key("config_value", (key,)), _UNSEEDED)
        if seeded is not _UNSEEDED:
            return seeded
        for scope in ("local", "global"):
            values = [value for k, value in self._config[scope] if k == key]
            if values:
                return (values[-1] or "").strip() or None
        return None

    def main_checkout(self) -> Optional[str]:
        return self._answer("main_checkout")

    def worktree_list(self) -> Optional[List[Worktree]]:
        return self._answer("worktree_list")

    def branch_at(self, path: str) -> Optional[str]:
        return self._answer("branch_at", path)

    def absolute_git_dir_at(self, path: str) -> Optional[str]:
        return self._answer("absolute_git_dir_at", path)

    def worktree_remove(self, checkout: str, path: str) -> Optional[str]:
        return self._answer("worktree_remove", checkout, path)

    def fetch_branch_at(self, checkout: str, branch: str) -> bool:
        return self._answer("fetch_branch_at", checkout, branch)

    def worktree_add_detached_at(self, checkout: str, path: str, ref: str
                                 ) -> Optional[GitFailure]:
        return self._answer("worktree_add_detached_at", checkout, path, ref)

    def worktree_add(self, path: str, branch: str) -> Optional[GitFailure]:
        return self._answer("worktree_add", path, branch)

    def worktree_delete(self, path: str) -> Optional[GitFailure]:
        return self._answer("worktree_delete", path)

    def rebase_at(self, path: str, onto: str) -> Optional[GitFailure]:
        return self._answer("rebase_at", path, onto)

    def rebase_abort_at(self, path: str) -> Optional[GitFailure]:
        return self._answer("rebase_abort_at", path)

    def unmerged_paths_at(self, path: str) -> List[str]:
        return self._answer("unmerged_paths_at", path)

    def merge_ff_only_at(self, path: str, ref: str) -> Optional[GitFailure]:
        return self._answer("merge_ff_only_at", path, ref)

    def merge_no_edit_at(self, path: str, ref: str) -> Optional[GitFailure]:
        return self._answer("merge_no_edit_at", path, ref)

    def newest_merge_commit(self, rev: str) -> Optional[str]:
        return self._answer("newest_merge_commit", rev)

    def second_parent(self, commit: str) -> Optional[str]:
        return self._answer("second_parent", commit)

    def status_at(self, path: str) -> Union[str, GitFailure]:
        return self._answer("status_at", path)

    def merge_in_progress_at(self, path: str) -> bool:
        return self._answer("merge_in_progress_at", path)

    def merge_abort_at(self, path: str) -> bool:
        return self._answer("merge_abort_at", path)

    def reset_hard_at(self, path: str) -> bool:
        return self._answer("reset_hard_at", path)

    def clean_at(self, path: str) -> bool:
        return self._answer("clean_at", path)

    def git_common_dir(self) -> Optional[str]:
        return self._answer("git_common_dir")

    def current_branch(self) -> Optional[str]:
        return self._answer("current_branch")

    def push(self, remote: str, refspec: str) -> Optional[str]:
        return self._answer("push", remote, refspec)

    def empty_commit(self, subject: str, body: str) -> Optional[str]:
        return self._answer("empty_commit", subject, body)

    def push_new_ref(self, remote: str, commit: str, ref: str) -> Optional[str]:
        return self._answer("push_new_ref", remote, commit, ref)

    def fetch_prune(self, remote: str, refspec: str) -> Optional[str]:
        return self._answer("fetch_prune", remote, refspec)

    def refs_contents(self, prefix: str) -> Optional[List[Tuple[str, str]]]:
        return self._answer("refs_contents", prefix)

    def branch_exists(self, name: str) -> bool:
        return name in self.branches

    def branch_upstream(self, name: str) -> Optional[str]:
        return self.branches.get(name)

    def branch_rename(self, old: str, new: str) -> Optional[GitFailure]:
        if old not in self.branches:
            return GitFailure(128, "fatal: no branch named '%s'\n" % old)
        if new in self.branches:
            return GitFailure(128, "fatal: a branch named '%s' already exists\n" % new)
        self.branches[new] = self.branches.pop(old)
        return None

    def branch_create(self, name: str, start: str) -> Optional[GitFailure]:
        if name in self.branches:
            return GitFailure(128, "fatal: a branch named '%s' already exists\n" % name)
        self.branches[name] = None
        return None

    def checkout_new_branch(self, name: str, start: str) -> Optional[GitFailure]:
        if name in self.branches:
            return GitFailure(128, "fatal: a branch named '%s' already exists\n" % name)
        commit = self._answer("resolve_commit", start)
        if commit is None:
            return GitFailure(128, "fatal: '%s' is not a commit and a branch '%s' cannot be"
                              " created from it\n" % (start, name))
        self.branches[name] = None
        self.seed("current_branch", answer=name)
        self.seed("resolve_commit", "HEAD", answer=commit)
        return None

    def checkout_existing_branch(self, name: str) -> Optional[GitFailure]:
        if name not in self.branches:
            return GitFailure(1, "error: pathspec '%s' did not match any file(s) known to"
                              " git\n" % name)
        self.seed("current_branch", answer=name)
        return None

    def branch_delete(self, name: str) -> Optional[GitFailure]:
        if name not in self.branches:
            return GitFailure(1, "error: branch '%s' not found\n" % name)
        del self.branches[name]
        section = "branch.%s." % name
        self._config["local"] = [
            (k, v) for k, v in self._config["local"] if not k.startswith(section)
        ]
        return None

    def origin_has_branch(self, name: str) -> Optional[bool]:
        return self._answer("origin_has_branch", name)

    def push_set_upstream(self, remote: str, refspec: str) -> Optional[str]:
        return self._answer("push_set_upstream", remote, refspec)

    def remote_delete(self, remote: str, ref: str) -> Optional[str]:
        return self._answer("remote_delete", remote, ref)

    def config_regexp(self, scope: str, pattern: str) -> Dict[str, str]:
        _check_config_scope(scope)
        rx = re.compile(pattern)
        out: Dict[str, str] = {}
        for key, value in self._config[scope]:
            if rx.search(key):
                out[key] = "" if value is None else value.rstrip("\n")
        return out

    def _config_write_blocked(self, scope: str, key: str) -> bool:
        return scope in self.config_write_fails or (scope, key) in self.config_write_fails

    def config_set(self, scope: str, key: str, value: str) -> Optional[GitFailure]:
        _check_config_scope(scope)
        if self._config_write_blocked(scope, key):
            return GitFailure(255, "error: could not lock config file %s: File exists\n"
                              % _FAKE_CONFIG_FILES[scope])
        entries = self._config[scope]
        matches = [i for i, (k, _) in enumerate(entries) if k == key]
        if len(matches) > 1:
            return GitFailure(5, "")
        if matches:
            entries[matches[0]] = (key, value)
        else:
            entries.append((key, value))
        return None

    def config_unset(self, scope: str, key: str) -> bool:
        _check_config_scope(scope)
        if self._config_write_blocked(scope, key):
            return False
        self._config[scope] = [(k, v) for k, v in self._config[scope] if k != key]
        return True


# The config file FakeGit's blocked write names in git's lock refusal, per scope.
_FAKE_CONFIG_FILES = {"local": ".git/config", "global": "~/.gitconfig"}

# What FakeGit's seeded answers give for a call nothing was seeded for, told
# apart from a seeded None.
_UNSEEDED = object()


def _call_key(name: str, args: Sequence[Any]) -> Tuple[Any, ...]:
    """A call's key among the seeded answers: a list argument, such as a
    sequence of line ranges, keyed as the tuple of its items."""
    return (name,) + tuple(_frozen(arg) for arg in args)


def _frozen(value: Any) -> Any:
    if isinstance(value, (list, tuple)):
        return tuple(_frozen(item) for item in value)
    return value
