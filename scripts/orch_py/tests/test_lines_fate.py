"""Lines fate, asked of real repositories: what became of a range of filed
lines at a ref since the commit that filed them (seam 2). Git's history
semantics are what the module reads, so a fake would only restate them: each
history shape is built once, by the module-scoped fixture below, and every
case asks lines_fate of it through the real git adapter."""
from __future__ import annotations

import subprocess

import pytest

from orch.git import COULD_NOT, Git
from orch.lines_fate import lines_fate
from conftest import git_repo

REF = "main"


def lines(prefix, count):
    """<count> numbered lines, "<prefix> line <n>"."""
    return ["%s line %d" % (prefix, n) for n in range(1, count + 1)]


class Author:
    """The repository the history is written in, on its main branch."""

    def __init__(self, root):
        self.root = root
        git_repo(root)
        self.git("checkout", "-q", "-B", "main")

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.root), "-c", "user.name=t", "-c", "user.email=t@t",
             "-c", "commit.gpgsign=false", *args],
            check=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        ).stdout.decode().strip()

    def read(self, path):
        return (self.root / path).read_text().splitlines()

    def put(self, files):
        """Writes each file of <files>, a path mapped to its lines, and stages
        it."""
        for path, text in files.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("".join(line + "\n" for line in text))
        self.git("add", "-A")

    def commit(self, files, message):
        """Commits <files> written; the new commit's SHA."""
        self.put(files)
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def edit(self, path, change, message):
        """Commits <path>'s lines as <change>, a function of its old lines,
        makes them; the new commit's SHA."""
        return self.commit({path: change(self.read(path))}, message)

    def branch_head(self, name, base, path, change):
        """A PR head off <base> editing <path>, on a branch <name> main never
        merges: its SHA, main checked out again."""
        self.git("checkout", "-q", "-b", name, base)
        sha = self.edit(path, change, "the PR's own edit")
        self.git("checkout", "-q", "main")
        return sha


def replace(n, *text):
    """Line <n> replaced by <text>."""
    return lambda old: old[: n - 1] + list(text) + old[n:]


def reword(n):
    """Line <n> with ", reworded" after it."""
    return lambda old: old[: n - 1] + [old[n - 1] + ", reworded"] + old[n:]


def delete(*spans):
    """Lines <lo>-<hi> of each (lo, hi) span deleted."""
    return lambda old: [
        line for n, line in enumerate(old, 1) if not any(lo <= n <= hi for lo, hi in spans)
    ]


def insert(n, *text):
    """<text> inserted before line <n>."""
    return lambda old: old[: n - 1] + list(text) + old[n - 1 :]


@pytest.fixture(scope="module")
def history(tmp_path_factory):
    """The history every case is asked of: its Git adapter, and each named
    commit's full SHA."""
    author = Author(tmp_path_factory.mktemp("lines-fate") / "repo")
    sha = {}

    # The reviewed code, then a fix of one line and a reword of another.
    sha["head"] = author.commit(
        {"src/app.sh": lines("app", 12), "src/other.sh": lines("other", 4)}, "reviewed")
    sha["fix"] = author.edit("src/app.sh", replace(3, "app line 3, fixed"), "fix line 3")
    sha["reword"] = author.edit("src/app.sh", reword(11), "reword line 11")

    # A PR head that edited a line and never reached main.
    sha["unmerged"] = author.branch_head(
        "pr11", sha["head"], "src/other.sh", replace(2, "other line 2, on the PR only"))

    # A head with no history in common with main.
    author.git("checkout", "-q", "--orphan", "unrelated")
    sha["unrelated"] = author.commit(
        {"src/other.sh": ["other line 1", "an unrelated line", "other line 2"]}, "unrelated")
    author.git("checkout", "-q", "-f", "main")

    # Lines shifted down by an insert above them, then fixed, then the file
    # rewritten below them.
    sha["big"] = author.commit({"src/big.sh": lines("big", 300)}, "a big file")
    author.edit("src/big.sh", insert(1, *lines("inserted", 5)), "insert five on top")
    sha["shifted_fix"] = author.edit(
        "src/big.sh", replace(15, "big line 10, fixed"), "fix the shifted line")
    author.edit("src/big.sh", lambda old: old[:199] + [line + ", bulk" for line in old[199:]],
                "rewrite everything below")

    # Lines main later deleted outright, one file per case, each deleted by
    # its own commit.
    names = ("whole", "end", "start", "middle", "later", "two", "replaced", "squashed", "split")
    sha["filed"] = author.commit(
        {"src/del_%s.sh" % name: lines(name, 30) for name in names}, "the deletions' code")
    sha["whole"] = author.edit("src/del_whole.sh", delete((8, 12)), "delete the whole range")
    sha["end"] = author.edit("src/del_end.sh", delete((18, 25)), "delete the range's end")
    sha["start"] = author.edit("src/del_start.sh", delete((5, 12)), "delete the range's start")
    sha["middle"] = author.edit("src/del_middle.sh", delete((14, 16)), "delete its middle")
    sha["later_del"] = author.edit("src/del_later.sh", delete((8, 12)), "delete, then edit")
    sha["later_edit"] = author.edit("src/del_later.sh", reword(1), "a later, unrelated edit")
    author.edit("src/del_two.sh", delete((18, 20)), "delete the range's end first")
    sha["two"] = author.edit("src/del_two.sh", delete((10, 12)), "then delete its start")
    sha["replaced"] = author.edit(
        "src/del_replaced.sh", lambda old: old[:8] + ["replaced line"] + old[11:],
        "replace three lines with one")
    # PR heads off the filed commit, each squash-merged onto main as the same
    # edit, whose lines main then deletes.
    for name in ("squashed", "split"):
        path, pr_line = "src/del_%s.sh" % name, "%s pr line" % name
        sha[name + "_head"] = author.branch_head(
            "pr-" + name, sha["filed"], path, insert(1, pr_line))
        author.edit(path, insert(1, pr_line), "the PR, squash-merged")
    sha["squashed"] = author.edit("src/del_squashed.sh", delete((9, 13)), "delete squashed")
    author.edit("src/del_squashed.sh", reword(26), "a later edit to the squashed file")
    sha["split"] = author.edit("src/del_split.sh", delete((9, 10), (12, 13)), "in two hunks")

    # PR heads that never merged, off one base: the filed lines decide, never
    # the file.
    sha["unm_base"] = author.commit(
        dict({"src/um%d.sh" % n: lines("um%d" % n, 20) for n in range(1, 15)},
             **{"src/mb.sh": lines("mb", 30)}), "the code the unmerged PRs edit")
    sha["mb_head"] = author.branch_head(
        "mbpr", sha["unm_base"], "src/mb.sh", replace(1, "pr replaced"))
    sha["mb_del"] = author.edit("src/mb.sh", delete((8, 12)), "delete mb's lines")
    pr_edits = {
        1: replace(5, "pr replaced"),
        2: insert(6, "pr added a", "pr added b"),
        3: delete((6, 6)),
        4: replace(2, "pr replaced"),
        5: lambda old: old[:7] + ["pr above", old[7], old[8], "pr below"] + old[9:],
        6: replace(5, "pr replaced"),
        7: replace(5, "pr replaced"),
        8: insert(6, "pr added a", "pr added b"),
        9: insert(6, "pr added a", "pr added b"),
        10: replace(2, "pr replaced"),
        11: replace(2, "pr replaced"),
        12: replace(2, "pr replaced"),
        13: lambda old: old[:7] + ["pr above", old[7], old[8], "pr below"] + old[9:],
        14: insert(6, "pr added a", "pr added b"),
    }
    for n, change in pr_edits.items():
        sha["um%d" % n] = author.branch_head(
            "unm%d" % n, sha["unm_base"], "src/um%d.sh" % n, change)
    author.edit("src/um1.sh", reword(15), "an unrelated edit to um1")
    author.edit("src/um2.sh", reword(15), "an unrelated edit to um2")
    author.edit("src/um3.sh", reword(15), "an unrelated edit to um3")
    sha["um4_del"] = author.edit("src/um4.sh", delete((8, 9)), "delete um4's lines")
    author.edit("src/um4.sh", reword(15), "an unrelated edit to um4")
    author.edit("src/um5.sh", reword(15), "an unrelated edit to um5")
    sha["um6_edit"] = author.edit("src/um6.sh", reword(5), "reword um6's line")
    sha["um7_edit"] = author.edit("src/um7.sh", reword(8), "reword um7's line")
    sha["um8_edit"] = author.edit("src/um8.sh", reword(6), "reword um8's line")
    sha["um9_del"] = author.edit("src/um9.sh", delete((6, 6)), "delete um9's line")
    author.edit("src/um9.sh", reword(15), "an unrelated edit to um9")
    author.edit("src/um10.sh", reword(15), "an earlier edit to um10")
    sha["um10_del"] = author.edit("src/um10.sh", delete((8, 9)), "delete um10's lines")
    sha["um12_edit"] = author.edit("src/um12.sh", reword(15), "an edit to um12")
    sha["um14_edit"] = author.edit("src/um14.sh", reword(4), "reword um14's line")
    return Git(cwd=str(author.root)), sha


def ask(history, filed, path, start, end, git=None):
    """lines_fate of lines <start>-<end> of <path> at the commit named
    <filed>, asked of main: (fate, detail)."""
    real, sha = history
    return tuple(lines_fate(git or real, sha[filed], REF, path, start, end))


def fate(result, commit=None):
    """The expected answer: <result>, and the SHA of the commit named
    <commit>, or the empty detail."""
    return result, commit


CASES = {
    # The file is not at the ref.
    "file gone": ("head", "src/none.sh", 1, 1, fate("gone")),
    # The file did not change, or changed only elsewhere.
    "unchanged": ("reword", "src/app.sh", 6, 6, fate("unchanged")),
    "changed elsewhere in the file": ("head", "src/app.sh", 6, 6, fate("unchanged")),
    # The lines a commit since touched.
    "lines changed": ("head", "src/app.sh", 3, 3, fate("changed", "fix")),
    "lines shifted, then changed": ("big", "src/big.sh", 10, 10, fate("changed", "shifted_fix")),
    "reversed range taken as its start": ("head", "src/app.sh", 3, 1, fate("changed", "fix")),
    "reversed range, its start untouched": ("head", "src/app.sh", 6, 3, fate("unchanged")),
    # A range past the file's end: the newest commit to touch the file.
    "range past the end": ("head", "src/app.sh", 40, 41, fate("changed", "reword")),
    # No merge base: the newest commit to touch the file stands in.
    "no merge base": ("unrelated", "src/other.sh", 2, 2, fate("changed", "head")),
    # Lines main deleted outright, named by the deleting commit.
    "lines deleted whole": ("filed", "src/del_whole.sh", 10, 10, fate("changed", "whole")),
    "range's end deleted": ("filed", "src/del_end.sh", 10, 20, fate("changed", "end")),
    "range's start deleted": ("filed", "src/del_start.sh", 10, 20, fate("changed", "start")),
    "range's middle deleted": ("filed", "src/del_middle.sh", 10, 20, fate("changed", "middle")),
    "deleted, then the file edited": (
        "filed", "src/del_later.sh", 10, 10, fate("changed", "later_del")),
    "deleted, reversed range": ("filed", "src/del_later.sh", 10, 8, fate("changed", "later_del")),
    "deleted by two commits": ("filed", "src/del_two.sh", 10, 20, fate("changed", "two")),
    "three lines replaced by one": (
        "filed", "src/del_replaced.sh", 10, 10, fate("changed", "replaced")),
    "deleted through a squash merge": (
        "squashed_head", "src/del_squashed.sh", 11, 11, fate("changed", "squashed")),
    "deleted through a squash merge, in two hunks": (
        "split_head", "src/del_split.sh", 9, 13, fate("changed", "split")),
    "off-ref lines main deleted": ("mb_head", "src/mb.sh", 10, 10, fate("changed", "mb_del")),
    # Off-ref heads: their lines decide, never their file.
    "never-reached": ("unmerged", "src/other.sh", 2, 2, fate("never-reached")),
    "never-reached, replaced": ("um1", "src/um1.sh", 5, 5, fate("never-reached")),
    "never-reached, added": ("um2", "src/um2.sh", 6, 7, fate("never-reached")),
    "never-reached, deleted on the PR": ("um3", "src/um3.sh", 5, 6, fate("never-reached")),
    "never-reached, reversed range": ("um1", "src/um1.sh", 5, 3, fate("never-reached")),
    "off-ref, held lines deleted": ("um4", "src/um4.sh", 8, 9, fate("changed", "um4_del")),
    "off-ref, held lines deleted after an edit": (
        "um10", "src/um10.sh", 8, 9, fate("changed", "um10_del")),
    "off-ref, inserts around unchanged lines": ("um5", "src/um5.sh", 9, 10, fate("unchanged")),
    "off-ref, the file untouched on main": ("um13", "src/um13.sh", 9, 10, fate("unchanged")),
    "off-ref, its replaced line reworded": ("um6", "src/um6.sh", 5, 5, fate("changed", "um6_edit")),
    "off-ref, a range main touched": ("um7", "src/um7.sh", 5, 8, fate("changed", "um7_edit")),
    "off-ref, added lines then one main reworded": (
        "um8", "src/um8.sh", 6, 8, fate("changed", "um8_edit")),
    # Partly never-reached: of an off-ref head's deleted lines only some were
    # ever held on main, or none and the rest are followed.
    "partly never-reached, the held line deleted": (
        "um9", "src/um9.sh", 6, 8, fate("changed", "um9_del")),
    "partly never-reached, the rest followed and changed": (
        "um14", "src/um14.sh", 4, 7, fate("changed", "um14_edit")),
    "partly never-reached, the rest followed untouched": (
        "um2", "src/um2.sh", 5, 7, fate("never-reached")),
    # A range past the end at a head whose own commits changed the file,
    # where no commit on main touched it.
    "past the end, never-reached": ("um11", "src/um11.sh", 25, 25, fate("never-reached")),
    "past the end, main touched the file": (
        "um12", "src/um12.sh", 25, 25, fate("changed", "um12_edit")),
}


def expected(history, answer):
    result, commit = answer
    return result, history[1][commit] if commit else ""


@pytest.mark.parametrize("filed, path, start, end, answer", CASES.values(), ids=list(CASES))
def test_lines_fate_reads_what_became_of_the_filed_lines(history, filed, path, start, end, answer):
    assert ask(history, filed, path, start, end) == expected(history, answer)


class Failing:
    """The real adapter <git>, its named operations <names> answering their
    "could not" value, as a git that cannot run them would."""

    def __init__(self, git, *names):
        self._git = git
        self._names = names

    def __getattr__(self, name):
        if name in self._names:
            return lambda *args: COULD_NOT[name]
        return getattr(self._git, name)


FALLBACKS = {
    # A failed diff counts as differing, with no hunks: the lines are followed
    # at their filed numbers.
    "a failed diff": (("file_diff",), "head", "src/app.sh", 3, 3, fate("changed", "fix")),
    # A failed deleting-commit lookup: the newest commit to touch the file
    # stands in.
    "a failed deleting-commit lookup": (
        ("blame_last_seen",), "filed", "src/del_later.sh", 10, 10,
        fate("changed", "later_edit")),
    # ...and when the stand-in fails too, no commit is named: never-reached,
    # never changed with an empty detail.
    "a failed lookup and stand-in": (
        ("blame_last_seen", "newest_file_commit"), "filed", "src/del_later.sh", 10, 10,
        fate("never-reached")),
    # A failed merge-base lookup proves nothing about the lines: they are
    # taken as deleted.
    "a failed merge base": (
        ("merge_base",), "mb_head", "src/mb.sh", 10, 10, fate("changed", "mb_del")),
}


@pytest.mark.parametrize(
    "names, filed, path, start, end, answer", FALLBACKS.values(), ids=list(FALLBACKS))
def test_a_failed_git_operation_takes_its_stand_in(history, names, filed, path, start, end,
                                                    answer):
    git = Failing(history[0], *names)

    assert ask(history, filed, path, start, end, git=git) == expected(history, answer)
