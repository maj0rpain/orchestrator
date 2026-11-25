"""The planning allowlist in Python: its lists, texts and matcher pinned to
the bash module the edit guard sources, and the dirty-path scan the
flow-start check refuses with."""
from __future__ import annotations

import subprocess
from pathlib import Path

from conftest import committed, died_of, git_repo, run_git, write_staged
from orch import planning_allowlist
from orch.git import FakeGit, Git

PLANNING_ALLOWLIST_SH = Path(__file__).resolve().parents[2] / "planning-allowlist.sh"


def bash_lines(script, *args):
    """The NUL-separated fields <script> prints with the bash planning
    allowlist module sourced, <args> its positional parameters."""
    run = subprocess.run(
        ["bash", "-c", 'source "$1"; shift\n' + script, "_", str(PLANNING_ALLOWLIST_SH), *args],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, timeout=30, check=True,
    )
    return run.stdout.decode().split("\0")[:-1]


def test_the_lists_and_texts_are_the_bash_module_s():
    bash = bash_lines(
        'printf "%s\\0" "${PLANNING_ALLOWLIST[*]}" "${PLANNING_EXCLUSIONS[*]}" '
        '"${PLANNING_RECORDS[*]}" "$(planning_allowlist_text)" "$(planning_records_text)" '
        '"$(planning_record_redirect)"\n'
    )

    python = [
        " ".join(entries) for entries in (
            planning_allowlist.ALLOWLIST, planning_allowlist.EXCLUSIONS,
            planning_allowlist.RECORDS)
    ] + [
        planning_allowlist.allowlist_text(),
        planning_allowlist.records_text(),
        planning_allowlist.RECORD_REDIRECT,
    ]
    assert python == bash


# A directory prefix, an exact path, an excluded path and a planning record,
# with the near misses each rule must refuse: a prefix's name without its
# slash, and an exact path's longer cousin.
JUDGED_PATHS = [
    "docs/agents/issue-tracker.md", "docs/agents", ".scratch/plan.md",
    "GLOSSARY.md", "GLOSSARY.md.bak", "src/GLOSSARY.md",
    ".orchestrator/worktrees/t3/src.sh", ".orchestrator/checkouts/side/a.md",
    ".orchestrator/handoffs/spec.md",
    "docs/adr/0013-the-edit-guard.md", "CONTEXT-MAP.md",
    "scripts/orch.sh",
]


def python_judgement(path):
    return "%d%d%d" % (planning_allowlist.allowlisted(path),
                       planning_allowlist.excluded(path), planning_allowlist.record(path))


def test_the_matcher_judges_each_path_as_the_bash_one_does():
    bash = bash_lines(
        'judge() { "$@" && printf 1 || printf 0; }\n'
        'for path; do\n'
        '  judge planning_allowlisted "$path"; judge planning_excluded "$path"\n'
        '  judge planning_record "$path"; printf "\\0"\n'
        'done\n',
        *JUDGED_PATHS,
    )

    assert [python_judgement(path) for path in JUDGED_PATHS] == bash


def test_the_scan_lists_each_dirty_path_outside_the_allowlist_both_sides_of_a_move(tmp_path):
    root = tmp_path / "repo"
    git_repo(root)
    body = "".join("line %d\n" % n for n in range(20))
    committed(root, {"src.sh": body, "orig.sh": body + "orig\n", "keep.sh": "k\n",
                     "GLOSSARY.md": "g\n", "docs/agents/domain.md": "d\n"}, "first")
    run_git(root, "config", "status.renames", "copies")
    run_git(root, "mv", "src.sh", "moved.sh")
    (root / "copy.sh").write_text(body + "orig\n")
    write_staged(root, {"orig.sh": body + "orig, changed\n"})
    (root / "keep.sh").write_text("k2\n")
    (root / "GLOSSARY.md").write_text("g2\n")
    (root / "docs" / "agents" / "domain.md").write_text("d2\n")
    (root / "new dir").mkdir()
    (root / "new dir" / "a b.sh").write_text("a\n")
    (root / "new dir" / "c.sh").write_text("c\n")
    (root / ".scratch").mkdir()
    (root / ".scratch" / "plan.md").write_text("p\n")
    (root / ".orchestrator" / "worktrees" / "t3").mkdir(parents=True)
    (root / ".orchestrator" / "worktrees" / "t3" / "x.sh").write_text("x\n")

    assert planning_allowlist.dirty_outside_allowlist(Git(cwd=str(root / "new dir"))) == [
        "GLOSSARY.md", "copy.sh", "orig.sh", "keep.sh", "moved.sh", "src.sh", "orig.sh",
        ".orchestrator/worktrees/t3/x.sh", "new dir/a b.sh", "new dir/c.sh",
    ]


def test_a_seeded_dirty_list_is_judged_by_the_allowlist():
    git = FakeGit()
    git.seed("dirty_paths", answer=["docs/agents/a.md", "src/a.sh", ".scratch/p.md",
                                    "docs/adr/0001-x.md"])

    assert planning_allowlist.dirty_outside_allowlist(git) == ["src/a.sh", "docs/adr/0001-x.md"]


def test_a_git_status_that_cannot_run_refuses_with_git_s_own_error_line(capsys):
    git = FakeGit()
    git.seed("dirty_paths", answer="fatal: unable to read index file")

    assert died_of(capsys, lambda: planning_allowlist.dirty_outside_allowlist(git)) == (
        1, "",
        "orch: git status failed - cannot check the working tree:"
        " fatal: unable to read index file\n",
    )
