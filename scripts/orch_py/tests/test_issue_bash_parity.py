"""The Python issue noun against the bash one on the same store, while both
exist: each case seeds one store, runs the bash `orch.sh issue <verb>` on it
through the bash gh fake, and runs the Python verb in-process on it, and the
two give the same stdout and exit code. It goes with the bash module."""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from orch import issue
from orch.gh_fake import FakeGh, FakeStore
from orch.git import Git

SCRIPTS = Path(__file__).resolve().parents[2]
MAPPED_DOC = (
    "| Label in mattpocock/skills | Label in our tracker | Meaning |\n"
    "| --- | --- | --- |\n"
    "| `ready-for-agent` | `agent go` | AFK-ready |\n"
)


def checkout(tmp_path, doc=None):
    """A repository at tmp_path/repo pinned to a GitHub origin, holding <doc>
    as its triage-labels doc when one is given."""
    repo = tmp_path / "repo"
    (repo / "docs" / "agents").mkdir(parents=True)
    if doc is not None:
        (repo / "docs" / "agents" / "triage-labels.md").write_text(doc)
    git(repo, "init", "-q")
    git(repo, "remote", "add", "origin", "https://github.com/acme/widgets.git")
    return repo


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *args],
        check=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
    ).stdout.decode().strip()


def bash_issue(tmp_path, repo, store, *args):
    """The bash `orch.sh issue <args>` in <repo> on the store: its stdout,
    stderr and exit code."""
    run = subprocess.run(
        ["bash", str(SCRIPTS / "orch.sh"), "issue", *args],
        cwd=str(repo),
        env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(tmp_path),
             "ORCH_GH_ADAPTER": str(SCRIPTS / "test" / "gh_adapter_fake.sh"),
             "ORCH_GH_FAKE_STORE": store.store},
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
    )
    return run.stdout.decode(), run.stderr.decode(), run.returncode


def python_issue(capsys, repo, store, *args):
    """The Python verb in-process, on the same store and checkout."""
    try:
        code = issue.run(list(args), gh=FakeGh(store.store, {}), git=Git(cwd=str(repo)), env={})
    except SystemExit as died:
        code = died.code
    out, err = capsys.readouterr()
    return out, err, code


def titled(store, n, title, state, *labels):
    store.issue(n, state, *labels)
    store.title(n, title)


def mixed(store):
    titled(store, 100, "Old phase", "open", "ready-for-agent", "orch:spec")
    titled(store, 101, "Old done", "open", "ready-for-agent", "orch:done")
    titled(store, 102, "Old sub", "open", "ready-for-agent")
    titled(store, 103, "Old blocked", "open", "ready-for-agent")
    titled(store, 104, "Old triage", "open", "needs-triage")
    titled(store, 105, "Old closed", "closed", "ready-for-agent")
    titled(store, 106, "The parent", "open", "Ready-For-Agent")
    titled(store, 107, "Newer", "open", "ready-for-agent")
    titled(store, 108, "Blocker", "open", "needs-triage")
    store.sub_issue(106, 102)
    store.blocked_by(103, 108)


def no_summary(store):
    titled(store, 120, "No summary, open blocker", "open", "ready-for-agent")
    titled(store, 121, "No summary, closed blocker", "open", "ready-for-agent", "ORCH:PLAN")
    titled(store, 122, "Open blocker", "open", "needs-triage")
    titled(store, 123, "Closed blocker", "closed", "needs-triage")
    store.blocked_by(120, 122)
    store.blocked_by(121, 123)
    store.no_dependency_summary(120)
    store.no_dependency_summary(121)


def none_qualifies(store):
    titled(store, 131, "Only triage", "open", "needs-triage")
    titled(store, 132, "Phased", "open", "ready-for-agent", "Orch:Review")


def mapped(store):
    titled(store, 133, "Default name", "open", "ready-for-agent")
    titled(store, 134, "Mapped", "open", "agent go")


@pytest.mark.parametrize("seed, doc, picked", [
    (mixed, None, ("106\tThe parent\n", 0)),
    (no_summary, None, ("121\tNo summary, closed blocker\n", 0)),
    (none_qualifies, None, ("", 1)),
    (mapped, MAPPED_DOC, ("134\tMapped\n", 0)),
], ids=["mixed", "no-summary", "none-qualifies", "mapped"])
def test_next_picks_the_issue_the_bash_verb_picks(tmp_path, capsys, seed, doc, picked):
    repo = checkout(tmp_path, doc)
    store = FakeStore(str(tmp_path / "store"))
    seed(store)

    assert bash_issue(tmp_path, repo, store, "next")[::2] == picked
    assert python_issue(capsys, repo, store, "next")[::2] == picked


def commented(store):
    store.issue(962, "open", "bug")
    store.title(962, "Trust")
    store.body(962, "# Spec\r\n\r\nA `$HOME` body.\r\nDEL \x7f, tab \t, \u00e9.\n\n")
    store.authorship(962, "stranger", "NONE", "", "owner")
    store.comment(962, "owner", "2026-09-04T09:00:00Z", "Owner note.\n\n", "OWNER")
    store.comment(962, "rando", "2026-09-04T12:00:00Z", "Stranger note.", "NONE")
    store.comment(962, "pat", "2026-09-04T13:00:00Z", "## Spec review\t\r\nRound 1 of 1", "MEMBER")
    store.comment(962, "sam", "2026-09-04T14:00:00Z", "## Spec reviewer notes\nkept", "COLLABORATOR")


@pytest.mark.parametrize("args", [
    ("fetch", "962", "OUT"),
    ("fetch", "962", "OUT", "--json"),
    ("comments", "962", "OUT"),
    ("comments", "962", "OUT", "--with-spec-review"),
    ("fetch", "962", "OUT", "--jsn"),
    ("comments", "x", "OUT"),
], ids=["fetch", "fetch-json", "comments", "comments-with-spec-review", "bad-flag", "bad-number"])
def test_fetch_and_comments_write_what_the_bash_verbs_write(tmp_path, capsys, args):
    repo = checkout(tmp_path)
    store = FakeStore(str(tmp_path / "store"))
    commented(store)
    out = tmp_path / "out"

    def written(run):
        answer = run(*(str(out) if a == "OUT" else a for a in args))
        text = out.read_bytes() if out.exists() else None
        if out.exists():
            out.unlink()
        return answer, text

    bash = written(lambda *a: bash_issue(tmp_path, repo, store, *a))
    python = written(lambda *a: python_issue(capsys, repo, store, *a))

    assert python == bash


def test_the_drift_line_reads_as_the_bash_verb_reads_it(tmp_path, capsys):
    repo = checkout(tmp_path)
    for name in ("a.md", "b.md", "c.md"):
        (repo / name).write_text(name + "\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "files")
    sha = git(repo, "rev-parse", "HEAD")
    (repo / "c.md").write_text("changed\n")
    git(repo, "commit", "-qam", "c changes")
    store = FakeStore(str(tmp_path / "store"))
    store.issue(23, "open")
    store.body(23, "A finding.\n\n**Location:** `c.md:1`\n\n**Location:** `a.md:2-3`\n\n"
                   "**Location:** `c.md:4`\n\n**Audited at:** %s\n\n" % sha)
    out = str(tmp_path / "out.md")

    bash = bash_issue(tmp_path, repo, store, "fetch", "23", out)
    assert bash == ("cited files changed since %s: c.md\n" % sha, "", 0)
    assert python_issue(capsys, repo, store, "fetch", "23", out) == bash
