"""The pytest suite's shared setup: every test starts from a clean
environment, and no test reaches the real gh.

The real-gh guard, like the bash suite's: a stub gh first on PATH that logs
its arguments and exits 1. It answers nothing, so a test that reaches gh
without a fixture gh of its own (which goes ahead of it) fails, and the guard's
teardown fails the test naming each logged call.
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys

import pytest

from orch import issue
from orch.gh_fake import FakeGh, FakeStore
from orch.git import FakeGit, Git
from orch.triage_labels import LABELS_DOC

# A gh failure's stderr: its first line is the reason a message names.
GH_502 = "HTTP 502: Bad Gateway\nsecond line"
# The root of the checkout a test runs in when it needs no file there: no
# triage-labels doc, so every role is its own label.
CHECKOUT = "/nonexistent/checkout"


@pytest.fixture
def store(tmp_path):
    """The gh fake's store, an empty directory: tmp_path/store."""
    path = tmp_path / "store"
    path.mkdir()
    return path


@pytest.fixture
def seed(store):
    """The store's seeder and reader, as the bash suite's fake_* helpers."""
    return FakeStore(str(store))


def write_labels_doc(root, text):
    """Writes <text> as the triage-labels doc of the checkout at <root>, a
    Path, making its directories as needed."""
    path = root / LABELS_DOC
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


# The triage-labels doc's role table header: its column names, then its
# separator row.
LABELS_TABLE = (
    "| Label in mattpocock/skills | Label in our tracker | Meaning |\n"
    "| --- | --- | --- |\n"
)


def labels_doc(*rows):
    """A triage-labels doc's text, its role table mapping each (role, label)
    row."""
    lines = ["| `%s` | `%s` | Meant |\n" % row for row in rows]
    return "# Triage Labels\n\n" + LABELS_TABLE + "".join(lines)


def checkout(tmp_path, doc=None):
    """A checkout rooted at tmp_path/repo, holding <doc> as its triage-labels
    doc when one is given: its git adapter, a FakeGit."""
    root = tmp_path / "repo"
    root.mkdir()
    if doc is not None:
        write_labels_doc(root, doc)
    return FakeGit(toplevel=str(root))


def git_repo(path, origin=None):
    """A fresh repository at <path>, with <origin> as its origin remote when
    one is given: its Git adapter."""
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


def orch_issue(seed, *argv, gh=None, git=None, env=None, pin=None):
    """`orch.sh issue <argv>` in-process: its exit code, a SystemExit's
    included. <gh> is the gh fake on <seed>'s store when None, <pin> its repo
    pin (a resolved one when None); <git> a checkout at CHECKOUT when None."""
    env = {} if env is None else env
    if gh is None:
        gh = FakeGh(seed.store, env, pin=pin, sleep=lambda _: None)
    try:
        return issue.run(list(argv), gh=gh, git=git or FakeGit(toplevel=CHECKOUT), env=env)
    except SystemExit as died:
        return died.code


# The fixture gh's program: it holds no logic and parses no flags. It logs
# each call - GH_REPO, GH_HOST and the argv, as one JSON line - then looks the
# whole argv up among the replies, exactly, and answers that reply's stdout,
# stderr and exit status: its n-th call of an argv the reply's n-th answer, the
# last repeating. An argv with no reply fails, exit 127, naming it.
FIXTURE_GH = r'''
import json, os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
argv = sys.argv[1:]
log = os.path.join(root, "calls.log")
with open(log, encoding="utf-8") as f:
    seen = sum(1 for line in f if json.loads(line)[2] == argv)
with open(log, "a", encoding="utf-8") as f:
    f.write(json.dumps([os.environ.get("GH_REPO"), os.environ.get("GH_HOST"), argv]) + "\n")
with open(os.path.join(root, "replies.json"), encoding="utf-8") as f:
    replies = json.load(f)
for reply in replies:
    if reply["argv"] == argv:
        answer = reply["answers"][min(seen, len(reply["answers"]) - 1)]
        sys.stdout.buffer.write(answer["stdout"].encode("utf-8"))
        sys.stderr.buffer.write(answer["stderr"].encode("utf-8"))
        sys.exit(answer["exit"])
sys.stderr.write("fixture gh: no reply for: %r\n" % (argv,))
sys.exit(127)
'''


class FixtureGh:
    """A fixture `gh` in <root>/bin, for the real gh adapter's contract tests
    (ADR-0033): it answers by exact argv the replies registered with reply().
    path() is a PATH with it first; calls() is every call made, in order, as
    (GH_REPO, GH_HOST, argv), None for an unset variable."""

    def __init__(self, root):
        self.root = root
        (root / "bin").mkdir()
        self._replies = []
        self._save()
        (root / "calls.log").write_text("")
        gh = root / "bin" / "gh"
        gh.write_text("#!%s -IS\n%s" % (sys.executable, FIXTURE_GH))
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR)

    def _save(self):
        (self.root / "replies.json").write_text(json.dumps(self._replies))

    def reply(self, argv, stdout="", stderr="", exit=0, then=()):
        """Registers the answer to <argv>, then each answer in <then>, a
        (stdout, stderr, exit) triple, for its later calls. Registering an argv
        again replaces its reply."""
        answers = [{"stdout": stdout, "stderr": stderr, "exit": exit}]
        answers += [{"stdout": o, "stderr": e, "exit": x} for o, e, x in then]
        self._replies = [r for r in self._replies if r["argv"] != list(argv)]
        self._replies.append({"argv": list(argv), "answers": answers})
        self._save()

    def calls(self):
        lines = (self.root / "calls.log").read_text().splitlines()
        return [tuple(json.loads(line)[:2]) + (json.loads(line)[2],) for line in lines]

    def argvs(self):
        return [argv for _, _, argv in self.calls()]

    def path(self):
        return "%s%s%s" % (self.root / "bin", os.pathsep, os.environ["PATH"])


@pytest.fixture
def fixture_gh(tmp_path):
    root = tmp_path / "fixture-gh"
    root.mkdir()
    return FixtureGh(root)

# The variables that would change what a test resolves or runs against: the
# caller's repo and host, the gh fake's knobs, its limit wait, git's own
# repository overrides (a test started from a git hook inherits them).
CLEARED = (
    "GH_REPO",
    "GH_HOST",
    "ORCH_GH_ADAPTER",
    "ORCH_GH_FAKE_STORE",
    "ORCH_GH_LIMIT_WAIT",
    "ORCH_ISSUE_LIST_LIMIT",
    "ORCH_AUTOPILOT",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
)


@pytest.fixture(scope="session")
def real_gh_guard(tmp_path_factory):
    """The guard's directory: bin/gh, and calls.log, one line per call."""
    root = tmp_path_factory.mktemp("real-gh-guard")
    (root / "bin").mkdir()
    log = root / "calls.log"
    gh = root / "bin" / "gh"
    gh.write_text(
        "#!/bin/sh\n"
        'printf "gh %%s\\n" "$*" >>"%s"\n'
        'echo "pytest: a test called the real gh: gh $*" >&2\n'
        "exit 1\n" % log
    )
    gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
    return root


@pytest.fixture(autouse=True)
def clean_env(monkeypatch, real_gh_guard):
    for name in CLEARED:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv(
        "PATH", "%s%s%s" % (real_gh_guard / "bin", os.pathsep, os.environ["PATH"])
    )
    log = real_gh_guard / "calls.log"
    log.write_text("")
    yield
    calls = log.read_text()
    assert calls == "", "the test reached the real gh:\n" + calls
