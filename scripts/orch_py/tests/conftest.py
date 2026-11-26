"""The pytest suite's shared setup: every test starts from a clean
environment, and no test reaches the real gh.

The real-gh guard, like the bash suite's: a stub gh first on PATH that logs
its arguments and exits 1. It answers nothing, so a test that reaches gh
without a fixture gh of its own (which goes ahead of it) fails, and the guard's
teardown fails the test naming each logged call.
"""
from __future__ import annotations

import builtins
import calendar
import json
import os
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest

from orch import audit, issue, pr, review_pass, spec_review, ticket_worktree, verification
from orch.gh import Unparsed
from orch.gh_fake import FakeGh, FakeStore
from orch.git import FakeGit, Git
from orch.repo import RepoPin
from orch.triage_labels import LABELS_DOC

# A gh failure's stderr: its first line is the reason a message names.
GH_502 = "HTTP 502: Bad Gateway\nsecond line"
# The root of the checkout a test runs in when it needs no file there: no
# triage-labels doc, so every role is its own label.
CHECKOUT = "/nonexistent/checkout"
# The variables naming a git config file other than $HOME's, unset so a test's
# HOME holds the only global config git reads or writes.
GLOBAL_CONFIG = ("GIT_CONFIG_GLOBAL", "XDG_CONFIG_HOME")
# orch.sh's -c bootstrap, as `python3 -c PACKAGE_BOOTSTRAP <package dir>
# <noun> ...`: the package directory, argv[1], goes first on sys.path - never
# on PYTHONPATH, which splits a path holding a colon - and orch's __main__ runs
# as `python3 -m orch` would.
PACKAGE_BOOTSTRAP = (
    "import sys\n"
    "if sys.path and sys.path[0] == '':\n"
    "    del sys.path[0]\n"
    "sys.path.insert(0, sys.argv.pop(1))\n"
    "import runpy\n"
    "runpy.run_module('orch', run_name='__main__', alter_sys=True)\n"
)


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


@pytest.fixture
def root(tmp_path):
    """The checkout's root, tmp_path/repo resolved, an empty directory - the
    toplevel a test's FakeGit names; no triage-labels doc unless a test
    writes one. A test file whose checkout needs more defines its own."""
    path = tmp_path.resolve() / "repo"
    path.mkdir()
    return path


def read(store, *parts):
    """A file of the store, or None where it is absent."""
    path = os.path.join(str(store), *(str(part) for part in parts))
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as f:
        return f.read()


def blockers_of(store, n):
    """The numbers the store lists as issue #n's blockers, in edge order."""
    return (read(store, "blocked_by", n) or "").split()


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


def comments_of(store, n, kind="issues"):
    """The bodies of issue #n's comments, in order - PR #n's with <kind>
    "prs"."""
    bodies = []
    k = 1
    while read(store, kind, n, "comments", k, "body") is not None:
        bodies.append(read(store, kind, n, "comments", k, "body"))
        k += 1
    return bodies


def files_under(path):
    """Every file under <path>, a Path, by its POSIX path relative to it,
    sorted."""
    return sorted(p.relative_to(path).as_posix() for p in path.rglob("*") if p.is_file())


def orch_files(root, folder, *names):
    """Writes each of <names> into <root>'s .orchestrator/<folder>, holding
    its own name: the folder, a Path."""
    directory = root / ".orchestrator" / folder
    directory.mkdir(parents=True, exist_ok=True)
    for name in names:
        (directory / name).write_text(name)
    return directory


def state_json(root):
    """The flow's state.json in the checkout at <root>, a Path."""
    return root / ".orchestrator" / "state.json"


def flow_state(root, phase, issue, branch=None):
    """<root>'s state.json, written to record a flow at <phase> on <issue>
    and <branch>, each as a JSON value (None for null); its path."""
    return hold_flow(root, slug="x", phase=phase, issue=issue, branch=branch)


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


def origin_clone(origin, root, branch=None):
    """A fresh bare repository at <origin>, its initial branch <branch> when
    one is given, else git's default, and a fresh repository at <root> with
    it as origin: the Git adapter on <root>."""
    initial = ["-b", branch] if branch else []
    subprocess.run(
        ["git", "init", "-q", "--bare", *initial, str(origin)], check=True,
        stdin=subprocess.DEVNULL,
    )
    return git_repo(root, str(origin))


def run_git(root, *args, env=None):
    """git <args> in the repository at <root>, as a test author t with
    signing off, in <env> when given, else this process's environment: its
    stdout, stripped. A failure raises."""
    return subprocess.run(
        ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@t",
         "-c", "commit.gpgsign=false", *args],
        check=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, env=env,
    ).stdout.decode().strip()


def git_identity(root):
    """The test author t with signing off, set in the repository at <root>'s
    own config, for the commits git makes there outside run_git - a rebase
    the code under test runs."""
    for key, value in (("user.name", "t"), ("user.email", "t@t"), ("commit.gpgsign", "false")):
        run_git(root, "config", key, value)


def exclude_orchestrator(root):
    """.orchestrator/ kept out of git status in the repository at <root>, as
    init's exclude keeps it."""
    with open(str(root / ".git" / "info" / "exclude"), "a") as exclude:
        exclude.write(".orchestrator/\n")


def bash_sourced(module, script, *args):
    """The stdout, decoded, of <script> run in a bash child process with the
    bash module at <module> sourced, <args> its positional parameters. A
    failure raises."""
    return subprocess.run(
        ["bash", "-c", 'source "$1"; shift\n' + script, "_", str(module), *map(str, args)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, timeout=30, check=True,
    ).stdout.decode()


def worktree_add(main, path, *how):
    """`git worktree add <how> <path>` in the repository at <main>, <path>'s
    parent made first: <path>."""
    path.parent.mkdir(parents=True, exist_ok=True)
    run_git(main, "worktree", "add", "-q", *how, str(path))
    return path


# Claude Code's plain session, as orch.sh reads the host from its
# environment.
CLAUDE = {"ORCHESTRATOR_HOST": "claude"}
# Claude Code's session under autopilot, for a case run once more as one.
AUTOPILOT = {"ORCHESTRATOR_HOST": "claude", "ORCH_AUTOPILOT": "1"}
# A case run in each session, plain and autopilot, its env the parameter.
SESSIONS = pytest.mark.parametrize("env", [CLAUDE, AUTOPILOT], ids=["plain", "autopilot"])
# The branch ticket_repo checks out, every ticket branch's forked-from branch.
TICKET_PARENT = "orch/5-feature"
# Ticket #7's branch, forked from TICKET_PARENT.
TICKET7 = TICKET_PARENT + "--t7"


@pytest.fixture
def ticket_repo(tmp_path, monkeypatch):
    """bash's tw_repo: a clone of a bare origin with one commit on its
    default branch pushed, then TICKET_PARENT checked out with a feature.txt
    commit of its own, git's identity set; the process's working directory:
    its root, resolved."""
    root = tmp_path.resolve() / "repo"
    origin_clone(tmp_path / "origin.git", root)
    git_identity(root)
    committed(root, {"README.md": "# repo\n"}, "init")
    run_git(root, "push", "-q", "origin", "HEAD")
    run_git(root, "checkout", "-qb", TICKET_PARENT)
    committed(root, {"feature.txt": "work\n"}, "feature")
    monkeypatch.chdir(root)
    return root


def conflicting(repo, n):
    """Ticket <n>'s worktree and TICKET_PARENT each with a commit changing
    feature.txt's one line, the worktree's to "from-ticket", the parent's to
    "from-flow"."""
    committed(Path(wt_path(repo, n)), {"feature.txt": "from-ticket\n"},
              "feature.txt: from-ticket")
    committed(repo, {"feature.txt": "from-flow\n"}, "feature.txt: from-flow")


def orch_tw(*argv, env=None):
    """`orch.sh ticket-worktree <argv>` in-process in the working directory's
    checkout, under <env> (Claude Code's plain session when None): its exit
    code."""
    return ticket_worktree.run(list(argv), env=CLAUDE if env is None else env)


def wt_path(root, n):
    """Where ticket <n>'s ticket worktree lives under the checkout at <root>,
    as a str."""
    return str(root / ".orchestrator" / "worktrees" / ("t%s" % n))


def added(root, capsys, n=7):
    """`ticket-worktree add <n>` run and its output drained: the path it
    printed, a str."""
    assert orch_tw("add", str(n)) == 0
    return capsys.readouterr().out.rstrip("\n")


def git_of(root, *args):
    """git <args> in the checkout at <root>, its stdout stripped; a failure
    reads as ""."""
    try:
        return run_git(root, *args)
    except Exception:  # noqa: BLE001 - a git refusal is the answer here
        return ""


def has_branch(root, branch):
    """Whether local branch <branch> exists in the repository at <root>."""
    return git_of(root, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch) != ""


def tip(root, branch):
    """The commit local branch <branch> of the repository at <root> is at,
    named in full so a same-named tag is never read."""
    return run_git(root, "rev-parse", "refs/heads/" + branch)


def lock_ref(repo, branch):
    """A lock file on local branch <branch>'s ref, as a git run holding it
    leaves one, so no git can delete the branch."""
    lock = repo / ".git" / "refs" / "heads" / (branch + ".lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    lock.write_text("")
    return lock


def rebasing(path):
    """Whether a rebase is in progress in the checkout at <path>."""
    return os.path.isdir(run_git(path, "rev-parse", "--absolute-git-dir") + "/rebase-merge")


def mark_side(path):
    """Writes the side-checkout ownership marker into the git folder of the
    worktree at <path>."""
    gitdir = run_git(path, "rev-parse", "--absolute-git-dir")
    with open(os.path.join(gitdir, "orchestrator-side-checkout"), "w"):
        pass


def hold_flow(path, **state):
    """Writes <state> as the state.json of the checkout at <path>: its
    path."""
    state_file = state_json(path)
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps(state) + "\n")
    return state_file


def done_flow(path, slug):
    """A done flow named <slug> in the checkout at <path>, with a spec
    handoff."""
    hold_flow(path, slug=slug, phase="done", issue=None)
    (path / ".orchestrator" / "handoff").mkdir(exist_ok=True)
    (path / ".orchestrator" / "handoff" / "spec.md").write_text("spec\n")


def side_checkout(main, name):
    """A side checkout <name> of the repository at <main>, on a new branch
    <name>, carrying the ownership marker: its path."""
    path = worktree_add(main, main / ".orchestrator" / "checkouts" / name, "-b", name)
    mark_side(path)
    return path


def archive_main(tmp_path):
    """A repository at tmp_path/main with one commit, whose .orchestrator/
    git ignores, as init's exclude makes it: its root, resolved."""
    root = tmp_path.resolve() / "main"
    git_repo(root)
    committed(root, {"a.txt": "a\n"}, "first")
    exclude_orchestrator(root)
    return root


# The stamp of an archive directory made at archive_clock's time,
# 2026-01-02 03:04:05 UTC.
ARCHIVE_STAMP = "20260102-030405"


def archive_clock():
    """The clock an archive reads, pinned so an archive directory's name is
    known: <ARCHIVE_STAMP>-<slug>."""
    return 1767323045.0


def archived(main, slug):
    """The directory <slug>'s flow is archived to under the archive of the
    main checkout at <main>, at archive_clock's time."""
    return main / ".orchestrator" / "archive" / ("%s-%s" % (ARCHIVE_STAMP, slug))


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


class Opens:
    """Counts the opens of one file, by any route: builtins.open and
    os.open."""

    def __init__(self, monkeypatch, path):
        self.path = os.path.realpath(str(path))
        self.count = 0
        real_open, real_os_open = builtins.open, os.open

        def counted(file, *args, **kwargs):
            self._seen(file)
            return real_open(file, *args, **kwargs)

        def os_counted(file, *args, **kwargs):
            self._seen(file)
            return real_os_open(file, *args, **kwargs)

        monkeypatch.setattr(builtins, "open", counted)
        monkeypatch.setattr(os, "open", os_counted)

    def _seen(self, file):
        if isinstance(file, (str, bytes, os.PathLike)) \
                and os.path.realpath(os.fsdecode(file)) == self.path:
            self.count += 1


def fake(seed):
    """The gh fake on <seed>'s store, its retries never sleeping."""
    return FakeGh(seed.store, {}, sleep=lambda _: None)


class CountingGh(FakeGh):
    """The gh fake, keeping each repo it is asked the default branch of, in
    order, in default_asks."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.default_asks = []

    def repo_default_branch(self, repo):
        self.default_asks.append(repo)
        return super().repo_default_branch(repo)


class UnparsedPrComments(FakeGh):
    """The gh fake, its PR comments an answer that is no comment list."""

    def pr_comments(self, n):
        raise Unparsed("no comment list")


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


def orch_pr(seed, git, *argv, env=None, gh=None):
    """`orch.sh pr <argv>` in-process, in the checkout of the git adapter
    <git>, under <env> (Claude Code's plain session when None), with the gh
    adapter <gh> - the gh fake on <seed>'s store pinned to <git>'s origin
    when None: its exit code, a SystemExit's included."""
    env = CLAUDE if env is None else env
    if gh is None:
        gh = FakeGh(seed.store, env, pin=RepoPin(env, git), sleep=lambda _: None)
    try:
        return pr.run(list(argv), gh=gh, git=git, env=env)
    except SystemExit as died:
        return died.code


def prs_of(store):
    """The numbers of the PRs the store holds, in order."""
    directory = os.path.join(str(store), "prs")
    return sorted(int(n) for n in os.listdir(directory)) if os.path.isdir(directory) else []


# The audit noun's usage text, naming every form, as a refused audit prints it.
AUDIT_USAGE = (
    "orch: usage: orch.sh audit begin <code|docs|tests>\n"
    "   or: orch.sh audit report <dir> <out.html>\n"
    "   or: orch.sh audit file --run <dir> <numbers>\n"
    "   or: orch.sh audit file <title> --category <bug|enhancement|documentation>"
    " --finding-file <f> --location <<file>:<line>|<file>:<start>-<end>> [--location ...]\n"
)
# The audit report golden files and the run directories they render.
AUDIT_FIXTURES = Path(__file__).resolve().parent / "audit_report"
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


def orch_review_pass(seed, git, *argv, gh=None, env=None):
    """`orch.sh review-pass <argv>` in-process, in the checkout of the git
    adapter <git>, under <env> (empty when None), with the gh adapter <gh> -
    the gh fake on <seed>'s store pinned to <git>'s origin when None: its
    exit code, a SystemExit's included."""
    env = {} if env is None else env
    pin = RepoPin(env, git)
    if gh is None:
        gh = FakeGh(seed.store, env, pin=pin, sleep=lambda _: None)
    try:
        return review_pass.run(list(argv), gh=gh, git=git, env=env, pin=pin)
    except SystemExit as died:
        return died.code


# The epoch second a FakeClock starts at unless a test gives another.
NOW = 1_800_000_000.0


class FakeClock:
    """A clock, called for the time, that its sleep advances: the clock and
    the sleep a wait is handed, every sleep recorded in <slept>. <on_sleep>,
    when given, is called after each sleep with the number of sleeps so
    far."""

    def __init__(self, now=NOW, on_sleep=None):
        self.now = now
        self.slept = []
        self.on_sleep = on_sleep

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.now += seconds
        if self.on_sleep is not None:
            self.on_sleep(len(self.slept))


def orch_spec_review(root, *argv, seed=None, env=None, clock=None, sleep=None):
    """`orch.sh spec-review <argv>` in-process, in the checkout at <root>
    (a FakeGit's toplevel), under <env> (empty when None), with the gh fake on
    <seed>'s store when one is given, and the clock and sleep a wait reads
    when given: its exit code, a SystemExit's included."""
    env = {} if env is None else env
    gh = None if seed is None else FakeGh(seed.store, env, sleep=lambda _: None)
    timing = {name: value for name, value in (("clock", clock), ("sleep", sleep))
              if value is not None}
    try:
        return spec_review.run(list(argv), gh=gh, git=FakeGit(toplevel=str(root)), env=env,
                               **timing)
    except SystemExit as died:
        return died.code


# The tail of spec-review check's pass line under --unattended.
UNATTENDED_TAIL = " - unattended: not a turn-final reply; go straight on to apply"


def nudge(d):
    """The tail of spec-review check's pass line on round directory <d>,
    attended: the nudge to end the turn on the view."""
    return (" - end your turn on one plain-text reply, no tool call: the view above word for"
            " word, then the question with its answer words spelled out; it is saved in"
            " %s/view.md" % d)


def _round_files(d):
    """Every file under <d>, by its path under <d>, with its bytes."""
    files = {}
    for here, _, names in os.walk(str(d)):
        for name in names:
            path = os.path.join(here, name)
            with open(path, "rb") as f:
                files[os.path.relpath(path, str(d))] = f.read()
    return files


def _without_view(files):
    return {name: data for name, data in files.items() if name != "view.md"}


def assert_check_passes(root, capsys, d, view, line, *args):
    """`spec-review check <d> <args>` in the checkout at <root> exits 0 with
    exactly <view> on stdout and <line>, the pass line, on stderr, saving
    <view> to view.md and changing nothing else."""
    before = _without_view(_round_files(d))

    assert orch_spec_review(root, "check", *(str(a) for a in (d,) + args)) == 0

    assert capsys.readouterr() == (view, line + "\n")
    assert (d / "view.md").read_text() == view
    assert _without_view(_round_files(d)) == before


def assert_check_refused(root, capsys, d, err, *args):
    """`spec-review check <d> <args>` in the checkout at <root> exits 1 with
    exactly <err> on stderr, nothing on stdout and <d> as it was."""
    before = _round_files(d)

    assert orch_spec_review(root, "check", *(str(a) for a in (d,) + args)) == 1

    assert capsys.readouterr() == ("", err)
    assert _round_files(d) == before


def refused_lines(*lines):
    """A refusal's stderr: each of <lines> as an `orch: ` line."""
    return "".join("orch: %s\n" % line for line in lines)


def lines_rewritten(text, changes):
    """<text>'s lines rewritten as one sed run rewrites them: <changes> maps
    a line number of <text> to the lines that take its place - [] deletes
    it, and ... in the list stands for the line itself."""
    out = []
    for number, line in enumerate(text.split("\n"), 1):
        out += [line if part is ... else part for part in changes.get(number, [line])]
    return "\n".join(out)


def rewrite_lines(path, changes):
    """The file at <path>, a Path, with its lines rewritten by <changes>, as
    lines_rewritten takes them."""
    path.write_text(lines_rewritten(path.read_text(), changes))


def edit(path, old, new):
    """The file at <path>, a Path, with its one <old> replaced by <new>."""
    text = path.read_text(encoding="utf-8")
    assert text.count(old) == 1
    path.write_text(text.replace(old, new), encoding="utf-8")


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
    "ORCHESTRATOR_HOST",
    "CLAUDECODE",
    "CLAUDE_PLUGIN_ROOT",
    "JUNIE_EXTENSION_ROOT",
    "JUNIE_SHIM_PATH",
    "ANTIGRAVITY_AGENT",
    "ANTIGRAVITY_CONVERSATION_ID",
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
    monkeypatch.setenv("GIT_TERMINAL_PROMPT", "0")
    monkeypatch.setenv(
        "PATH", "%s%s%s" % (real_gh_guard / "bin", os.pathsep, os.environ["PATH"])
    )
    log = real_gh_guard / "calls.log"
    log.write_text("")
    yield
    calls = log.read_text()
    assert calls == "", "the test reached the real gh:\n" + calls
