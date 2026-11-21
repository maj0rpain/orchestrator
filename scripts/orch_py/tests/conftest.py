"""The pytest suite's shared setup: every test starts from a clean
environment, and no test reaches the real gh.

The real-gh guard, like the bash suite's: a stub gh first on PATH that logs
its arguments and exits 1. It answers nothing, so a test that reaches gh
without a fixture gh of its own (which goes ahead of it) fails, and the guard's
teardown fails the test naming each logged call.
"""
from __future__ import annotations

import calendar
import json
import os
import stat
import subprocess
import sys
import time

import pytest

from orch import audit, issue, verification
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


def read(store, *parts):
    """A file of the store, or None where it is absent."""
    path = os.path.join(str(store), *(str(part) for part in parts))
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as f:
        return f.read()


def snapshot(store):
    """Every file the store holds, with its contents - but the comment-read
    counter, which a read bumps."""
    files = {}
    for directory, _, names in os.walk(str(store)):
        for name in names:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, str(store))
            if relative != "comment_reads":
                with open(path, "rb") as f:
                    files[relative] = f.read()
    return files


def labels_of(store, n):
    return (read(store, "issues", n, "labels") or "").split("\n")[:-1]


def comments_of(store, n):
    """The bodies of issue #n's comments, in order."""
    bodies = []
    k = 1
    while read(store, "issues", n, "comments", k, "body") is not None:
        bodies.append(read(store, "issues", n, "comments", k, "body"))
        k += 1
    return bodies


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


def git_repo(path, origin=None, object_format=None):
    """A fresh repository at <path>, with <origin> as its origin remote when
    one is given, its objects named by <object_format> (sha1 or sha256) when
    one is given, else git's default: its Git adapter."""
    formats = ["--object-format=" + object_format] if object_format else []
    subprocess.run(
        ["git", "init", "-q", *formats, str(path)], check=True, stdin=subprocess.DEVNULL
    )
    if origin is not None:
        subprocess.run(
            ["git", "-C", str(path), "remote", "add", "origin", origin],
            check=True,
            stdin=subprocess.DEVNULL,
        )
    return Git(cwd=str(path))


def run_git(root, *args, env=None):
    """git <args> in the repository at <root>, as a test author t with
    signing off, in <env> when given, else this process's environment: its
    stdout, stripped. A failure raises."""
    return subprocess.run(
        ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t",
         "-c", "commit.gpgsign=false", *args],
        check=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, env=env,
    ).stdout.decode().strip()


def write_staged(root, files):
    """Writes the files named, removes those mapped to None, and stages
    every change."""
    for name, text in files.items():
        path = root / name
        if text is None:
            path.unlink()
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    run_git(root, "add", "-A")


def committed(root, files, message):
    """Writes the files named, removes those mapped to None, commits; the
    new commit's SHA."""
    write_staged(root, files)
    run_git(root, "commit", "-qm", message)
    return run_git(root, "rev-parse", "HEAD")


# The verification knobs every verification call runs under unless a test
# sets its own: a short grace and a fast poll, so a stop and a delivery take a
# fraction of a second.
VERIFICATION_KNOBS = {"ORCH_VERIFICATION_GRACE": "0.3", "ORCH_VERIFICATION_INTERVAL": "0.02"}


def verification_store(root):
    """The verification store of the main checkout <root>, a Path."""
    return root / ".orchestrator" / "verification"


def verification_records(root):
    """The names of the records in the verification store of the main
    checkout <root>, its temporary directories (and the main checkout's own
    identity token) left out."""
    store = verification_store(root)
    if not store.is_dir():
        return []
    return sorted(path.name for path in store.iterdir()
                  if path.is_dir() and not path.name.startswith("."))


def until(check, bound=5.0):
    """Waits up to <bound> seconds for <check>() to hold: whether it did."""
    deadline = time.monotonic() + bound
    while not check():
        if time.monotonic() > deadline:
            return False
        time.sleep(0.02)
    return True


def gone(group):
    """Whether the process group <group> is gone, the verification module's
    in-process runners reaped first, so an ended one is never counted as a
    zombie."""
    verification.reap_runners()
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return True
    return False


def path_without(tmp_path, command):
    """The test's PATH with no <command> on it: each directory holding one is
    replaced by a directory of its own linking every other command there."""
    kept = []
    for k, directory in enumerate(os.environ["PATH"].split(os.pathsep)):
        if not os.path.exists(os.path.join(directory, command)):
            kept.append(directory)
            continue
        links = tmp_path / ("no-%s-%d" % (command, k))
        links.mkdir()
        for name in os.listdir(directory):
            if name != command:
                (links / name).symlink_to(os.path.join(directory, name))
        kept.append(str(links))
    return os.pathsep.join(kept)


def fake(seed):
    """The gh fake on <seed>'s store, its retries never sleeping."""
    return FakeGh(seed.store, {}, sleep=lambda _: None)


def died_of(capsys, run):
    """(exit code, stdout, stderr) of <run>, which must die."""
    with pytest.raises(SystemExit) as died:
        run()
    out, err = capsys.readouterr()
    return died.value.code, out, err


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


# The audit noun's usage text, naming every form, as a refused audit prints it.
AUDIT_USAGE = (
    "orch: usage: orch.sh audit begin <code|docs|tests>\n"
    "   or: orch.sh audit report <dir> <out.html>\n"
    "   or: orch.sh audit file --run <dir> <numbers>\n"
    "   or: orch.sh audit file <title> --category <bug|enhancement|documentation>"
    " --finding-file <f> --location <<file>:<line>|<file>:<start>-<end>> [--location ...]\n"
)
# The clock an in-process audit reads, pinned so a run directory's name is
# known.
AUDIT_CLOCK = float(calendar.timegm((2030, 1, 2, 3, 4, 5)))


def orch_audit(git, *argv, gh=None):
    """`orch.sh audit <argv>` in-process, in the checkout of the git adapter
    <git>, with the gh adapter <gh>, at AUDIT_CLOCK: its exit code, a
    SystemExit's included."""
    try:
        return audit.run(list(argv), gh=gh, git=git, env={}, clock=lambda: AUDIT_CLOCK)
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
