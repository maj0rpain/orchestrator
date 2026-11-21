"""The Lines fate module: a concept module with no noun of its own, holding
what became of a range of a file's lines at a ref since a commit filed them.
Only finding triage's scan reads it, through lines_fate.

The hunk-header parse, the line mapping, the deleted ranges, the range
segments and the "lines differ" test are plain functions over parsed hunk
rows; every git command runs through the git adapter's named operations,
each answering its "could not" value on a git failure, which the rules below
take a stand-in for.
"""
from __future__ import annotations

import re
from typing import Iterable, List, NamedTuple, Optional, Sequence, Tuple

# A range of lines, (first, last), both included.
Range = Tuple[int, int]

GONE = "gone"
UNCHANGED = "unchanged"
CHANGED = "changed"
NEVER_REACHED = "never-reached"

# A zero-context diff's hunk header: each side's start, and its count when
# not 1.
_HUNK_HEADER = re.compile(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


class Hunk(NamedTuple):
    """One hunk header of a zero-context diff: where it starts and how many
    lines it spans on the old side and on the new."""

    old_start: int
    old_count: int
    new_start: int
    new_count: int


class Fate(NamedTuple):
    """What became of the lines: gone, unchanged, changed or never-reached,
    and the detail, the full SHA of the commit that touched or deleted them,
    empty unless the fate is changed."""

    fate: str
    detail: str


def hunk_rows(diff: str) -> List[Hunk]:
    """The hunk headers of the zero-context diff <diff>, in its order: the
    one parse of them, shared by every reader below."""
    rows = []
    for line in diff.splitlines():
        if not line.startswith("@@ "):
            continue
        header = _HUNK_HEADER.match(line)
        if header is None:
            continue
        a, b, c, d = header.groups()
        rows.append(Hunk(int(a), 1 if b is None else int(b), int(c), 1 if d is None else int(d)))
    return rows


def map_line(rows: Sequence[Hunk], line: int) -> int:
    """Where <line> of the old side of the hunks <rows> sits on the new side.
    A line inside a changed hunk maps to that hunk's start."""
    offset = 0
    for old_start, old_count, new_start, new_count in rows:
        if old_count > 0 and old_start <= line <= old_start + old_count - 1:
            return new_start if new_start > 0 else 1
        if ((old_count > 0 and old_start + old_count - 1 < line)
                or (old_count == 0 and old_start < line)):
            offset += new_count - old_count
        else:
            break
    return line + offset


def deleted_in(rows: Sequence[Hunk], start: int, end: int) -> List[Range]:
    """The parts of lines <start>-<end> the hunks <rows> delete outright -
    inside a hunk whose new count is 0. A line a hunk replaces is not deleted
    by this rule."""
    parts = []
    for old_start, old_count, _, new_count in rows:
        if old_start <= end and old_count > 0 and new_count == 0:
            lo, hi = max(start, old_start), min(old_start + old_count - 1, end)
            if lo <= hi:
                parts.append((lo, hi))
    return parts


def lines_differ(rows: Sequence[Hunk], start: int, end: int) -> bool:
    """Whether lines <start>-<end> differ: a hunk of <rows> removes or
    replaces one of them, or inserts lines between two of them. Lines
    inserted before the first line or after the last do not make the range
    differ."""
    return any(
        old_start <= end
        and ((old_count > 0 and old_start + old_count - 1 >= start)
             or (old_count == 0 and start <= old_start < end))
        for old_start, old_count, _, _ in rows
    )


def range_segments(start: int, end: int, ranges: Iterable[Range]) -> List[Range]:
    """The runs of lines <start>-<end> the <ranges> leave out, in order."""
    taken = list(ranges)
    runs: List[Range] = []
    for line in range(start, end + 1):
        if any(lo <= line <= hi for lo, hi in taken):
            continue
        if runs and runs[-1][1] == line - 1:
            runs[-1] = (runs[-1][0], line)
        else:
            runs.append((line, line))
    return runs


def deleted_ranges(git, old: str, new: str, path: str, start: int, end: int) -> List[Range]:
    """The parts of lines <start>-<end> of <path> at <old> that the
    zero-context diff to <new> deletes outright. A diff that cannot be made
    deletes nothing."""
    diff = git.file_diff(old, new, path)
    return deleted_in(hunk_rows(diff.text) if diff is not None else [], start, end)


def _held_lines(git, old: str, commit: str, path: str, ranges: Sequence[Range]) -> bool:
    """Whether <commit> holds some line of the <ranges>, lines of <path> at
    <old>: the diff from <old> to <commit> does not delete it outright."""
    deleted = deleted_ranges(git, old, commit, path, ranges[0][0], ranges[-1][1])
    return any(range_segments(lo, hi, deleted) for lo, hi in ranges)


def _ever_held(git, old: str, ref: str, path: str, ranges: Sequence[Range]) -> bool:
    """Whether some line of the <ranges>, lines of <path> at <old>, a commit
    off <ref>, was held by the merge base of the two or by a commit on <ref>
    since it - False for lines that never reached <ref>. A lookup that fails
    proves nothing about the lines, so they count as held: the caller takes
    them as deleted."""
    base = git.merge_base(old, ref)
    if base is None:
        return True
    if _held_lines(git, old, base, path, ranges):
        return True
    commits = git.file_commits(ref, old, path)
    if commits is None:
        return True
    return any(_held_lines(git, old, commit, path, ranges) for commit in commits)


def _squash_deleting_commit(
    git, old: str, ref: str, path: str, ranges: Sequence[Range]
) -> Optional[str]:
    """The commit on <ref>'s first-parent line that deleted the newest of the
    <ranges> - lines of <path> at <old>, a commit off <ref>, deleted by <ref>
    - or None. Off <ref>, the lines reached it through a squash commit, so the
    deleting commit is the newest one since which every line stays deleted:
    walking back, the one after the first commit that still holds one."""
    commits = git.first_parent_file_commits(ref, old, path)
    if commits is None:
        return None
    after = None
    for commit in commits:
        if _held_lines(git, old, commit, path, ranges):
            return after
        after = commit
    # No commit since the merge base holds any of them: the merge base held
    # them when the oldest commit touching the file deleted them.
    base = git.merge_base(old, ref)
    if base is not None and _held_lines(git, old, base, path, ranges):
        return after
    return None


def _deleting_commit(git, old: str, ref: str, path: str, ranges: Sequence[Range]) -> Optional[str]:
    """The commit that deleted the <ranges>, lines of <path> at <old> that
    <ref> no longer has - the newest such commit when several deleted them -
    or None when the exact lookup fails. A reverse blame names, for each
    line, the commit it last existed in, and its deleting commit is the
    oldest since that one to touch the file."""
    ref_sha = git.resolve_commit(ref)
    if ref_sha is None:
        return None
    deleters = set()
    off_branch = False
    for lo, hi in ranges:
        last_seen = git.blame_last_seen(old, ref, path, lo, hi)
        if not last_seen:
            return None
        for last in last_seen:
            if last == ref_sha:
                return None
            if not git.is_ancestor(last, ref):
                off_branch = True
                continue
            since_last = git.file_commits_oldest_first(ref, last, path)
            if not since_last:
                return None
            deleters.add(since_last[0])
    if off_branch:
        deleter = _squash_deleting_commit(git, old, ref, path, ranges)
        if deleter is None:
            return None
        deleters.add(deleter)
    for commit in git.file_commits(ref, old, path) or []:
        if commit in deleters:
            return commit
    return None


def _settled(detail: Optional[str]) -> Fate:
    """A detail settled by a stand-in: changed when it names a commit, else
    never-reached, never changed with an empty detail."""
    return Fate(CHANGED, detail) if detail else Fate(NEVER_REACHED, "")


def lines_fate(git, filed_sha: str, ref: str, path: str, start: int, end: int) -> Fate:
    """What became of lines <start>-<end> of <path> (root-relative) at
    <filed_sha>, a commit already in the clone, at <ref>, read through the git
    adapter <git>: gone (the file is not at <ref>), unchanged, changed (the
    detail the full SHA of a commit that touched or deleted the lines, or
    stands in for lines that cannot be followed) or never-reached (the lines
    differ only by commits that never reached <ref>). A reversed range is
    taken as its start line alone. Never raises on a git failure: each takes
    its stand-in, as the comments below say."""
    if end < start:
        end = start
    if not git.path_exists_at(ref, path):
        return Fate(GONE, "")
    # The one diff of the filed SHA against the ref. A diff that fails counts
    # as differing, with no hunks: the lines are followed at their filed
    # numbers.
    diff = git.file_diff(filed_sha, ref, path)
    if diff is not None and not diff.differs:
        return Fate(UNCHANGED, "")
    rows = hunk_rows(diff.text) if diff is not None else []
    # The newest commit since the filing that touched the file: the stand-in
    # when the exact lookup fails.
    newest = git.newest_file_commit(ref, filed_sha, path)
    file_commit = newest[0] if newest else None
    # Off the ref's history, a difference no commit on it made is the filed
    # SHA's own commits, never on it: the finding's lines decide, not its file.
    off_ref = not git.is_ancestor(filed_sha, ref)
    # Filed lines deleted outright are changed, whatever the lines around them
    # say - unless an off-ref SHA's deleted lines no commit on the ref ever
    # held: then the rest of the lines are followed.
    deleted = deleted_in(rows, start, end)
    if deleted and (not off_ref or _ever_held(git, filed_sha, ref, path, deleted)):
        return _settled(_deleting_commit(git, filed_sha, ref, path, deleted) or file_commit)
    follow = []
    for lo, hi in range_segments(start, end, deleted):
        new_start, new_end = map_line(rows, lo), map_line(rows, hi)
        follow.append((new_start, max(new_start, new_end)))
    if not follow:
        return Fate(NEVER_REACHED, "")
    # The newest commit since the filing that touched the finding's lines.
    touched = git.newest_lines_commit(ref, filed_sha, path, follow)
    if touched is None:
        # A range starting past the file's end cannot be followed: the newest
        # commit touching the file stands in.
        return _settled(file_commit)
    if touched:
        return Fate(CHANGED, touched[0])
    if off_ref and lines_differ(rows, start, end):
        # Nothing since the filing touched the lines, but they differ, by
        # commits that never reached the ref.
        return Fate(NEVER_REACHED, "")
    # The file changed only elsewhere.
    return Fate(UNCHANGED, "")
