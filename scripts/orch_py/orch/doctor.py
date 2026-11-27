"""orch.sh's doctor noun (ADR-0067), so far reached through doctor.run and
`python3 -m orch doctor` alone: diagnostics for the orchestrator plugin, as
the bash doctor module reports them. Scopes are named for the content they
cover, never for the caller that asks - `--env` and `--flow` - so a check's
home does not move when a caller changes.

Every check reports through the Doctor's reporter - ok, warn, fail, remedy,
under a group header - and the exit code comes from the FAIL count alone.
Doctor is the thing you run when the world is already broken, so no check
may abort the report: one that raises is reported as the warn `<name> could
not run.`, <name> its registry entry's, the bash check's function name, and
the report carries on.

A check whose answer is unavailable reports *skip* rather than a FAIL it
derived from not knowing, and the skipped checks collapse into one warn per
cause in the skip report, naming the cause. GitHub is asked at most once per
answer per run: the probe reads gh's auth status (which doubles as the
reachability probe) and the repo's default branch, and every check takes
those answers.

run(argv) takes the arguments after `doctor`, as orch.sh hands them on; it
returns the exit code, and a usage error dies through orch.common.die, exit
1.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from typing import Callable, List, Mapping, NamedTuple, Optional, Union

from orch.base import default_branch_local
from orch.common import die, stdout_write
from orch.gh import GhFailed, adapter_of, gh_reason
from orch.git import Git
from orch.repo import REPO_CAUSE, REPO_MISSING, RepoPin, owner_name
from orch.root import checkout_root

USAGE = "usage: orch.sh doctor [--env|--flow]"
SCOPES = {"": "both", "--env": "env", "--flow": "flow"}

# The gh probe's answer where GitHub answered, and its two failed answers.
GH_OK = "ok"
GH_UNAUTHENTICATED = "not authenticated"
GH_UNREACHABLE = "GitHub is not reachable"
# The words in gh's failed auth status saying it could not connect, the only
# signal gh offers telling "could not connect" from "not authenticated".
UNREACHABLE_WORDS = ("dial tcp", "lookup ", "connection refused", "network is unreachable",
                     "imeout")
# The trim orch.sh hands the running bash's version through, and the probe
# of the bash on PATH where it handed none.
RUNNING_BASH = "ORCH_RUNNING_BASH"
BASH_VERSION_PROBE = 'printf "%s\\n" "${BASH_VERSION%%(*}"'
PACKAGE_REMEDY = "brew install %s    # or your platform's package manager"


class Doctor:
    """One run's reporter, its counters, and the probe's answers. <env> is
    the environment the tools are looked for on (its PATH); <git> the
    checkout at <root>; <pin> the repo pin; <gh_of> the gh adapter, made at
    first use."""

    def __init__(self, env: Mapping[str, str], git, root: str, pin: RepoPin,
                 gh_of: Callable[[], object]) -> None:
        self.env = env
        self.git = git
        self.root = root
        self.pin = pin
        self._gh_of = gh_of
        self._gh_adapter = None
        self.oks = self.warns = self.fails = self.groups = 0
        self.gh_skipped = self.jq_skipped = 0
        # "ok", or the reason GitHub could not be asked; "" until probed.
        self.gh_answer = ""
        # The GitHub host the probe asked about.
        self.gh_host = ""
        # Whether GitHub answered for the repo; gh's stderr where it did not.
        self.repo_seen = False
        self.repo_reason = ""
        # The default branch as GitHub reports it, when a valid branch name.
        self.repo_branch = ""
        self.jq = self.installed("jq")

    # --- the reporter ---

    def line(self, text: str) -> None:
        stdout_write(text + "\n")

    def head(self, title: str) -> None:
        if self.groups:
            self.line("")
        self.groups += 1
        self.line(title)

    def ok(self, text: str) -> None:
        self.line("ok    " + text)
        self.oks += 1

    def warn(self, text: str) -> None:
        self.line("warn  " + text)
        self.warns += 1

    def fail(self, text: str) -> None:
        self.line("FAIL  " + text)
        self.fails += 1

    def remedy(self, *lines: str) -> None:
        """A remedy is a runnable command, verbatim, wherever one command
        fixes the problem; where none does, a short plain instruction saying
        what to do. Running one is the user's call."""
        for text in lines:
            self.line("      " + text)

    def skip_line(self, n: int, noun: str, cause: str) -> None:
        # No remedy: the cause is bare, and its remedy, where one exists, is
        # given once by the check that found it.
        if n:
            self.warn("%d %s %s skipped: %s" % (n, noun, "check" if n == 1 else "checks", cause))

    def skip_report(self) -> None:
        if not self.gh_skipped + self.jq_skipped:
            return
        self.head("skipped")
        self.skip_line(self.gh_skipped, "GitHub", self.gh_answer)
        self.skip_line(self.jq_skipped, "flow", "jq is not installed")

    def run(self, registry: List["Entry"]) -> None:
        """Runs each entry of <registry> in order: a header opens its group,
        and a check that raises is reported as one that could not run."""
        for entry in registry:
            if isinstance(entry, Head):
                self.head(entry.title)
                continue
            try:
                entry.check(self)
            except (Exception, SystemExit):
                self.warn("%s could not run." % entry.name)

    # --- the probe ---

    def installed(self, command: str) -> bool:
        """Whether <command> is an executable on the PATH doctor runs
        with."""
        return shutil.which(command, path=self.env.get("PATH")) is not None

    @property
    def gh(self):
        if self._gh_adapter is None:
            self._gh_adapter = self._gh_of()
        return self._gh_adapter

    def probe_gh(self) -> None:
        """Asks GitHub at most once, and only when something needs it: gh's
        auth status on the repo's host doubles as the reachability probe."""
        if self.gh_answer:
            return
        if not self.installed("gh"):
            self.gh_answer = "gh is not installed"
            return
        # No repo to pin the calls to: ask nothing.
        if self.pin.resolve() is None:
            self.gh_answer = REPO_MISSING
            return
        self.gh_host = self.pin.gh_host()
        try:
            self.gh.auth_status(self.gh_host)
        except GhFailed as failed:
            report = failed.stdout + failed.stderr
            unreachable = any(word in report for word in UNREACHABLE_WORDS)
            self.gh_answer = GH_UNREACHABLE if unreachable else GH_UNAUTHENTICATED
            return
        self.gh_answer = GH_OK

    def gh_gate(self) -> bool:
        """Whether GitHub can be asked; a check it shuts counts itself on the
        skip line and says nothing of its own."""
        self.probe_gh()
        return self.gate(self.gh_answer == GH_OK)

    def gate(self, open_: bool) -> bool:
        if not open_:
            self.gh_skipped += 1
        return open_

    def probe(self, scope: str) -> None:
        """The answers the env checks share, read once. The flow scope
        reaches gh through gh_gate instead, which probes on first use, so a
        run that needs no GitHub answer costs no round trip."""
        if scope == "flow":
            return
        self.probe_gh()
        if self.gh_answer != GH_OK:
            return
        # Validated as the default-branch lookup validates it (#485): an
        # answer that is no branch name is GitHub not having said.
        try:
            view = self.gh.repo_default_branch(self.pin.resolve().name)
        except GhFailed as failed:
            self.repo_reason = failed.stderr
            return
        self.repo_seen = True
        if view and self.git.is_branch_name(view):
            self.repo_branch = view


class Head(NamedTuple):
    """A registry's group header."""

    title: str


class Check(NamedTuple):
    """A registry's check: its name, the bash check's function name, and the
    check, run on the Doctor."""

    name: str
    check: Callable[[Doctor], None]


Entry = Union[Head, Check]


def checks(*functions: Callable[[Doctor], None]) -> List[Check]:
    """A registry's checks, each named by its function."""
    return [Check(function.__name__, function) for function in functions]


# --- tools ----------------------------------------------------------------------


def check_git(d: Doctor) -> None:
    if d.installed("git"):
        d.ok("git present")
        return
    d.fail("git not found.")
    d.remedy(PACKAGE_REMEDY % "git")


def check_gh(d: Doctor) -> None:
    if d.installed("gh"):
        d.ok("gh present")
        return
    d.fail("gh not found - the spec phase publishes the issue and the PR through it.")
    d.remedy(PACKAGE_REMEDY % "gh")


def check_jq(d: Doctor) -> None:
    """The flow state the bash nouns read and write needs jq, which makes
    "jq is missing" the one message that has to survive without it."""
    if d.jq:
        d.ok("jq present")
        return
    d.fail("jq not found - orch.sh reads and writes state.json with it.")
    d.remedy(PACKAGE_REMEDY % "jq")


def check_python3(d: Doctor) -> None:
    """The running python3, as an ok line only: the entry point's version
    gate stops every python3 below 3.9 before doctor can run."""
    d.ok("python3 %d.%d.%d" % tuple(sys.version_info[:3]))


def running_bash(env: Mapping[str, str]) -> str:
    """The bash that ran orch.sh, as orch.sh hands it on; else - doctor run
    directly - the bash on PATH. Raises where there is none to ask."""
    version = env.get(RUNNING_BASH, "")
    if version:
        return version
    bash = shutil.which("bash", path=env.get("PATH"))
    if bash is None:
        raise OSError("no bash on PATH")
    probe = subprocess.run([bash, "-c", BASH_VERSION_PROBE], env=dict(env),
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, check=True)
    return probe.stdout.decode("utf-8", "replace").split("\n", 1)[0]


def check_bash(d: Doctor) -> None:
    """The running bash, as an ok line only: orch.sh's version guard stops
    every command below bash 4.2 before doctor can run."""
    d.ok("bash " + running_bash(d.env))


# --- auth & remotes -------------------------------------------------------------


def check_origin(d: Doctor) -> None:
    url = d.git.origin_url()
    if url:
        d.ok("origin: " + url)
        return
    d.fail("no origin remote - the flow pushes the branch and opens the PR there.")
    d.remedy("git remote add origin https://github.com/<owner>/<repo>.git")


def check_gh_auth(d: Doctor) -> None:
    """The gh auth check. When the probe failed for a repo whose host came
    from origin's SSH URL and is not github.com, the host may be an SSH Host
    alias the ssh translation could not resolve: the alias hint adds one
    warn and the GH_REPO remedy beside the result. The offline arm stays a
    skip, never a FAIL."""
    if d.gh_answer == GH_OK:
        d.ok("gh authenticated")
    elif d.gh_answer == GH_UNAUTHENTICATED:
        d.fail("gh is not authenticated to %s." % d.gh_host)
        d.remedy("gh auth login --hostname " + d.gh_host)
        ssh_alias_hint(d)
    else:
        d.gate(False)
        if d.gh_answer == GH_UNREACHABLE:
            ssh_alias_hint(d)


def ssh_alias_hint(d: Doctor) -> None:
    """check_gh_auth's alias hint, for a repo resolved from an SSH-form
    origin on a host other than github.com only."""
    repo = d.pin.resolve()
    if repo is None or repo.source != "origin" or not repo.origin_ssh:
        return
    if d.gh_host == "github.com":
        return
    d.warn("the host %s came from origin's SSH URL and may be an SSH Host alias." % d.gh_host)
    d.remedy("export GH_REPO=" + owner_name(repo.name))


def check_gh_repo(d: Doctor) -> None:
    """The repo the orchestrator works on (#520), resolved locally - so a
    checkout with none is a FAIL here, and gh_gate counts every later GitHub
    check on the skip line. gh's own default repo, which in a fork is the
    upstream, is only a warn: every call is pinned to the resolved repo
    regardless."""
    repo = d.pin.resolve()
    if repo is None:
        d.fail(REPO_CAUSE)
        d.remedy("export GH_REPO=<owner>/<repo>")
        return
    d.ok("repo: %s (%s)" % (repo.name, repo.source))
    # set-default --view reads local git config, so it needs gh but no
    # network. It prints a bare owner/name even for a default off github.com,
    # so it is compared with the repo's owner/name, any host dropped.
    if d.installed("gh"):
        try:
            default = d.gh.repo_local_default()
        except GhFailed:
            default = ""
        if "/" in default and default != owner_name(repo.name):
            d.warn("gh's default repo is %s; the orchestrator uses %s" % (default, repo.name))
    if not d.gh_gate() or d.repo_seen:
        return
    d.fail("GitHub cannot see %s - origin may point somewhere you cannot see: %s"
           % (repo.name, gh_reason(d.repo_reason)))
    d.remedy("git remote set-url origin https://github.com/<owner>/<repo>.git")


def check_default_branch(d: Doctor) -> None:
    """Worth its own line because getting it wrong is silent: with GitHub's
    answer missing, the lookup falls back to a local pointer and then to the
    literal main, and a branch forked from the wrong place looks fine until
    review."""
    # Silent when the repo itself did not resolve: check_gh_repo has said so,
    # and a second line derived from the first buries it.
    if not d.gh_gate() or not d.repo_seen:
        return
    if d.repo_branch:
        d.ok("default branch: %s (from GitHub)" % d.repo_branch)
        return
    d.warn("default branch not resolved from GitHub - falling back to %s."
           % default_branch_local(d.git).name)
    d.remedy("git remote set-head origin --auto")


# The env checks, in report order.
ENV_CHECKS: List[Entry] = [
    Head("tools"),
    *checks(check_git, check_gh, check_jq, check_python3, check_bash),
    Head("auth & remotes"),
    *checks(check_origin, check_gh_auth, check_gh_repo, check_default_branch),
]


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    pin: Optional[RepoPin] = None,
) -> int:
    """`orch.sh doctor [--env|--flow]`: the real adapters and the process's
    environment unless a test hands in others. Outside a checkout it dies
    first, as orch.sh does."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    if len(argv) > 1:
        die(USAGE)
    flag = argv[0] if argv else ""
    scope = SCOPES.get(flag)
    if scope is None:
        die("unknown doctor flag: %s (want --env or --flow)" % flag)
    pin = RepoPin(env, git) if pin is None else pin
    d = Doctor(env, git, root, pin, adapter_of(gh, env, pin))
    d.probe(scope)
    if scope != "flow":
        d.run(ENV_CHECKS)
    d.skip_report()
    d.line("")
    d.line("%d ok, %d warn, %d FAIL" % (d.oks, d.warns, d.fails))
    return 1 if d.fails else 0
