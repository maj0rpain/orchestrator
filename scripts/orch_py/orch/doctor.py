"""orch.sh's doctor noun (ADR-0067), and its alias health: diagnostics for
the orchestrator plugin, reported as they were before the noun was converted.
Scopes are named for the content they
cover, never for the caller that asks - `--env` and `--flow` - so a check's
home does not move when a caller changes. The flow scope is the flow state
group, each check in the phases it runs in (a registry entry's phase list),
then the working-tree check against the planning allowlist and the
ticket-worktrees check, which runs on every path, a flow or none.

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
import re
import shutil
import subprocess
import sys
import time
from typing import Callable, Dict, List, Mapping, NamedTuple, Optional, Sequence, TypeVar, Union

from orch import agent, glossary
from orch.autopilot import autopilot_active, iso_epoch
from orch.base import base_setting, default_branch_local
from orch.checkout import checkouts, ticket_worktrees_under
from orch.common import (EXCLUDED_DIRS, ORCH_DIR_NAME, capture, die, err_line, exclude_missing,
                         fenced, file_lines, int_as_test_reads, list_join, stdout_write, trim)
from orch.flow_state import (flow_state_file, flow_state_get_many, recorded_pr,
                             require_state_exists)
from orch.gh import GhFailed, adapter_of, gh_reason, label_listed
from orch.git import Git
from orch.handoff import (NOT_READY, PHASES, READY_IF_GH, handoff_doctor_missing,
                          handoff_fetch_due, handoff_fetched, handoff_ready, handoff_report,
                          handoff_scratch_dir, handoffs_due, phases_from)
from orch.host import flow_cmd, host_detect
from orch.liveness import issue_alive
from orch.planning_allowlist import dirty_outside_allowlist
from orch.repo import REPO_CAUSE, REPO_MISSING, RepoPin, owner_name
from orch.review import (ci_probe, review_budget_fallback, review_terminal_report,
                         standards_resolve_source)
from orch.root import checkout_root
from orch.side_checkout import (FINISHED, UNREAD, side_checkout_finished,
                                side_checkout_marker_issue)
from orch.standing import (claims_read, host_id, label_verdict, live_phase, phase_label,
                           redo_phase, standing_read)
from orch.triage_labels import LABELS_DOC, expected_labels

T = TypeVar("T")

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
# The plugin root doctor reports from, two directories above this package, as
# orch.sh's ORCH_PLUGIN names it: the path the package was loaded by, not
# resolved through a link.
PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))
SETUP_REMEDY = "see docs/repo-setup.md under the plugin root"


class Doctor:
    """One run's reporter, its counters, and the probe's answers. <env> is
    the environment the tools are looked for on (its PATH); <git> the
    checkout at <root>; <pin> the repo pin; <gh_of> the gh adapter, made at
    first use; <plugin> the plugin root the run reports from."""

    def __init__(self, env: Mapping[str, str], git, root: str, pin: RepoPin,
                 gh_of: Callable[[], object], plugin: str = PLUGIN_ROOT) -> None:
        self.env = env
        self.git = git
        self.root = root
        self.pin = pin
        self.plugin = plugin
        # The host check_host detected; "" for none, or one it does not know.
        self.host = ""
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
        # The flow's values (FLOW_KEYS, the budget after its fallback) from
        # the one state read, when state.json is exactly one JSON object.
        self.flow: Optional[Dict[str, str]] = None
        self._issue: Optional[IssueRead] = None
        self._pr: Optional[PrRead] = None

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

    def run(self, registry: Sequence["Entry"]) -> None:
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

    def answer_or_fail(self, call: Callable[[], T]) -> Optional[T]:
        """The answer of <call>, a read in the module of the concept it
        serves; where it dies, or raises the GhFailed it reports a failed
        read with, the check's one FAIL carrying the failure's message, and
        None - never the aborted-check warn, so the exit stays a FAIL's."""
        try:
            answer, err, code = capture(call)
        except GhFailed as failed:
            self.fail(gh_reason(failed.stderr))
            return None
        if code:
            self.fail(err_line(err))
            return None
        return answer

    # --- the flow memos ---

    def issue_read(self) -> "IssueRead":
        """The flow issue's state and labels, read from GitHub at most once
        per run: every check that needs either takes that one answer. Call
        only after gh_gate has opened. The recorded number goes to gh as
        recorded_pr hands a recorded PR on: a plain number as an int."""
        if self._issue is None:
            try:
                state, labels = self.gh.issue_state_labels(recorded_pr(self.flow["issue"]))
                self._issue = IssueRead(True, state, labels, "")
            except GhFailed as failed:
                self._issue = IssueRead(False, "", [], failed.stderr)
        return self._issue

    def pr_read(self) -> "PrRead":
        """The flow PR's state and draft flag, read once, as issue_read."""
        if self._pr is None:
            try:
                state, draft = self.gh.pr_state_draft(recorded_pr(self.flow["pr"]))
                self._pr = PrRead(True, state, draft, "")
            except GhFailed as failed:
                self._pr = PrRead(False, "", False, failed.stderr)
        return self._pr

    def probe(self, scope: str) -> None:
        """The answers the checks share, read once. A state file holding
        anything but exactly one JSON object leaves self.flow None, which
        settles every flow check at once; the same one read takes the values
        the flow checks use. The flow scope reaches gh through gh_gate,
        which probes on first use, so a run that needs no GitHub answer
        costs no round trip."""
        if scope != "env" and self.jq:
            self.flow = flow_state_get_many(flow_state_file(self.root), FLOW_KEYS)
            if self.flow is not None:
                self.flow["budget"] = review_budget_fallback(self.flow["budget"])
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


# The state keys the flow checks read, in the probe's one read.
FLOW_KEYS = ("phase", "issue", "branch", "pr", "iteration", "budget")


class IssueRead(NamedTuple):
    """The flow-issue memo: whether the read answered, the state and labels
    it gave, and gh's stderr where it did not."""

    read: bool
    state: str
    labels: List[str]
    err: str


class PrRead(NamedTuple):
    """The flow-PR memo: whether the read answered, the state (empty where
    it did not) and draft flag it gave, and gh's stderr where it did not."""

    read: bool
    state: str
    draft: bool
    err: str


class Head(NamedTuple):
    """A registry's group header."""

    title: str


class Check(NamedTuple):
    """A registry's check: its name, the bash check's function name, the
    check, run on the Doctor, and the phases it runs in - "" for every
    phase, else a comma-separated list whose `<phase>+` element stands for
    <phase> and every phase after it in the phase table."""

    name: str
    check: Callable[[Doctor], None]
    phases: str = ""


Entry = Union[Head, Check]


def checks(*functions: Callable[[Doctor], None]) -> List[Check]:
    """A registry's checks, each named by its function."""
    return [Check(function.__name__, function) for function in functions]


def phase_list(entry: Check) -> List[str]:
    """<entry>'s phases, each `<phase>+` element expanded to the phases it
    stands for. Every element is checked against the phase table, so a typo
    never quietly disables a check: one naming a phase the table does not
    hold dies naming its entry."""
    phases: List[str] = []
    for element in entry.phases.split(","):
        named = element[:-1] if element.endswith("+") else element
        following = phases_from(named)
        if following is None:
            die("%s:%s: no such phase in the phase table: %s" % (entry.name, entry.phases, named))
        phases += following if element.endswith("+") else [named]
    return phases


def entries_at(registry: Sequence[Entry], phase: str) -> List[Entry]:
    """The entries of <registry> that apply at <phase>: a header or a check
    with no phase list always, a listed check only when its list names
    <phase>."""
    return [entry for entry in registry
            if isinstance(entry, Head) or not entry.phases or phase in phase_list(entry)]


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


# --- plugin environment ---------------------------------------------------------

HOST_REF = "docs/host-capabilities.md"
# Each host's column header in the capabilities reference.
HOST_NAMES = {"claude": "Claude Code", "junie": "Junie CLI", "antigravity": "Antigravity CLI"}
HOST_REMEDY = "export ORCHESTRATOR_HOST=claude    # or junie, antigravity"
CAPABILITY_HEADER = re.compile(r"\| *Capability *\|")


def _cell(text: str) -> str:
    """A table cell less the spaces padding it, as the bash read trims it."""
    return text.strip(" ")


def host_marked(plugin: str, host: str, mark: str) -> List[str]:
    """The capabilities whose cell in <host>'s column of the plugin's
    capabilities reference carries **<mark>** (Fallback or Unverified), read
    from the reference itself rather than restated here, so doctor and the
    table can never disagree; none without the reference."""
    path = os.path.join(plugin, HOST_REF)
    if not os.path.isfile(path):
        return []
    marked = []
    column = 0
    for line in file_lines(path):
        fields = line.split("|")
        if CAPABILITY_HEADER.match(line):
            for i in range(1, len(fields) - 1):
                if _cell(fields[i]) == host:
                    column = i
            continue
        if column and line.startswith("|") and column < len(fields) \
                and "**%s**" % mark in fields[column]:
            marked.append(_cell(fields[1]))
    return marked


def check_host(d: Doctor) -> None:
    """Reduced enforcement has to be visible: which host doctor believes it
    runs under, and what that host cannot do, in the reference's words. Not
    a failure: the flow runs on every host, with the documented fallbacks.
    An unverified cell is reported apart, so doctor never states it as a
    gap."""
    detected = host_detect(d.env)
    if not detected:
        d.warn("host not detected - which capabilities are missing is unknown.")
        d.remedy(HOST_REMEDY)
        return
    name = HOST_NAMES.get(detected)
    if name is None:
        d.warn("ORCHESTRATOR_HOST=%s names no supported host." % detected)
        d.remedy(HOST_REMEDY)
        return
    d.host = detected
    lacks = host_marked(d.plugin, name, "Fallback")
    unverified = host_marked(d.plugin, name, "Unverified")
    if not lacks + unverified:
        d.ok("host: " + name)
        return
    detail = []
    if lacks:
        detail.append("lacks: " + list_join(lacks))
    if unverified:
        detail.append("unverified: " + list_join(unverified))
    d.warn("host: %s %s - fallbacks in %s" % (name, "; ".join(detail), HOST_REF))


# What an unset CLAUDE_PLUGIN_ROOT means on each host: no remedy on any,
# because nothing is broken - every skill falls back to the orch.sh two
# directories above its own.
PLUGIN_ROOT_UNSET = {
    "junie": "CLAUDE_PLUGIN_ROOT unset - Junie expands it only in hooks; skills use the"
             " relative path.",
    "antigravity": "CLAUDE_PLUGIN_ROOT unset - Antigravity sets PLUGIN_ROOT only in hooks;"
                   " skills use the relative path.",
    "": "CLAUDE_PLUGIN_ROOT unset - only Claude Code sets it; skills use the relative path.",
}


def check_plugin_root(d: Doctor) -> None:
    """Only Claude Code sets CLAUDE_PLUGIN_ROOT, so whether its absence means
    anything depends on the host check, which runs first."""
    if d.env.get("CLAUDE_PLUGIN_ROOT", ""):
        d.ok("CLAUDE_PLUGIN_ROOT set")
    elif d.host == "claude":
        d.warn("CLAUDE_PLUGIN_ROOT is not set under Claude Code - orch.sh was run by hand, not"
               " through a plugin command.")
    else:
        d.ok(PLUGIN_ROOT_UNSET.get(d.host, PLUGIN_ROOT_UNSET[""]))


# The user-level skill stores scanned whatever the host: the one the skills
# CLI installs into, Claude Code's own, and Antigravity CLI's own. Junie's own
# store is not yet verified, so it is not scanned.
SKILL_STORES = (".agents/skills", ".claude/skills", ".gemini/config/skills")


def tilde(path: str, home: str) -> str:
    """<path> with a leading <home> written as ~."""
    return "~" + path[len(home):] if home and path.startswith(home) else path


def skills_only_copies(store: str, seen: List[str]) -> List[str]:
    """The orch-* skill folders in <store> with no orch.sh two directories
    above them - `..` after a linked folder resolving beside the real one -
    in name order, each real folder named once across the stores <seen>
    holds."""
    try:
        names = sorted(os.listdir(store))
    except OSError:
        return []
    found = []
    for name in names:
        folder = os.path.join(store, name)
        if not name.startswith("orch-") or not os.path.isdir(folder):
            continue
        if not os.path.isfile(os.path.join(folder, "SKILL.md")):
            continue
        if os.path.isfile(os.path.join(folder, "..", "..", "scripts", "orch.sh")):
            continue
        # The skills CLI links ~/.claude/skills/<skill> into ~/.agents/skills,
        # so one copy can be reached from both stores: report it once.
        real = os.path.realpath(folder)
        if real in seen:
            continue
        seen.append(real)
        found.append(name)
    return found


def check_orch_sh(d: Doctor) -> None:
    """A skills-only install copies the skills without scripts/, so the
    orch.sh every skill resolves two directories above it is not there.
    Doctor runs from an orch.sh, so it can only see such a copy in a
    user-level skill store beside the full install: a warn per store, not a
    FAIL, since which host picks up the copy is not something doctor can
    see."""
    home = d.env.get("HOME", "")
    seen: List[str] = []
    found = False
    for store in SKILL_STORES:
        path = home + "/" + store
        names = skills_only_copies(path, seen)
        if not names:
            continue
        d.warn("orch.sh missing beside the orchestrator skills in %s: %s - a skills-only install."
               % (tilde(path, home), list_join(names)))
        found = True
    if not found:
        d.ok("orch.sh: %s/scripts/orch.sh" % tilde(d.plugin, home))
        return
    d.remedy(*ORCH_INSTALLS.get(d.host, ORCH_INSTALLS[""]))


# The install remedy of a skills-only copy, naming only the detected host's
# install method - every method with no host detected.
_CLAUDE_INSTALL = ("Claude Code: /plugin marketplace add maj0rpain/orchestrator",
                   "             /plugin install orchestrator@orchestrator")
_JUNIE_INSTALL = ("Junie:       install maj0rpain/orchestrator as a Junie extension"
                  " (unverified)",)
_AGY_INSTALL = ("Antigravity: agy plugin install <path-to-orchestrator-clone>",)
_AFTER_INSTALL = ("then remove the skills-only copy named above.",)
ORCH_INSTALLS = {
    "claude": _CLAUDE_INSTALL + _AFTER_INSTALL,
    "junie": _JUNIE_INSTALL + _AFTER_INSTALL,
    "antigravity": _AGY_INSTALL + _AFTER_INSTALL,
    "": _CLAUDE_INSTALL + _JUNIE_INSTALL + _AGY_INSTALL + _AFTER_INSTALL,
}


# --- repo config ----------------------------------------------------------------


def check_labels_doc(d: Doctor) -> None:
    """Absent is fine: the canonical names apply. Present but unreadable is a
    FAIL, because a doc that exists was meant to say something."""
    if not os.path.isfile(os.path.join(d.root, LABELS_DOC)):
        d.ok("no %s - the canonical triage label names apply" % LABELS_DOC)
        return
    n = len(expected_labels(d.root))
    if n:
        d.ok("%d triage labels documented in %s" % (n, LABELS_DOC))
        return
    d.fail("%s lists no triage labels - the spec phase labels its issue from it." % LABELS_DOC)
    d.remedy("fix %s's table, or delete it to use the canonical names" % LABELS_DOC)


# The most labels the labels-exist check asks gh to list.
LABEL_LIMIT = 1000


def check_labels_exist(d: Doctor) -> None:
    """The spec phase applies a label at `gh issue create`, so a label the
    repo does not have kills the phase after the whole exchange has been
    spent. A label is matched in any casing, as GitHub attaches one."""
    if not d.gh_gate():
        return
    want = expected_labels(d.root)
    # Nothing to compare against, and check_labels_doc has said so: one
    # problem earns one FAIL, never a second derived from the first.
    if not want:
        return
    try:
        have = d.gh.labels(LABEL_LIMIT)
    except GhFailed as failed:
        # GitHub answered the auth probe and then would not answer this: an
        # absent answer rather than a "no".
        d.warn("the repo's labels could not be listed: " + gh_reason(failed.stderr))
        return
    missing = [label for label in want if not label_listed(have, label)]
    if not missing:
        d.ok("every triage label exists on the repo")
        return
    # Found every one is definitive whatever the page held, so the cut-off
    # caveat only ever qualifies a negative.
    if len(have) >= LABEL_LIMIT:
        d.warn("the repo has more than %d labels - cannot confirm: %s"
               % (LABEL_LIMIT, list_join(missing)))
        return
    d.fail("triage labels missing from the repo: " + list_join(missing))
    # Quoted, because a label that needs quoting is exactly the one pasted
    # wrong.
    d.remedy(*('gh label create "%s"' % label for label in missing))


STANDARDS_CRAWL_TAIL = (" - or delete the paragraph to have the reviewers crawl the standards"
                        " documents")


def check_standards_declaration(d: Doctor) -> None:
    """The Standards resolution both reviewers' prompts are built from, read
    in-process from the review module and reported - never parsed a second
    time: `declared <file>` or `crawled`, then the list. A declaration it
    rejects is a FAIL carrying the resolution's own message, its remedy
    naming the entry it stopped at."""
    lines: List[str] = []
    _, err, code = capture(lambda: standards_resolve_source(d.root, lines.append))
    first, listed = (lines[0], lines[1:]) if lines else ("", [])
    declared = first[len("declared "):] if first.startswith("declared ") else ""
    if code:
        d.fail(err_line(err))
        if not declared:
            return
        if listed:
            d.remedy("change the entry `%s` in the Standards: paragraph of %s to a repo-relative"
                     " path of a file in the repo, with at most one #Heading that matches once"
                     % (listed[-1], declared) + STANDARDS_CRAWL_TAIL, SETUP_REMEDY)
        else:
            d.remedy("list backticked repo-relative paths in the Standards: paragraph of %s"
                     % declared + STANDARDS_CRAWL_TAIL, SETUP_REMEDY)
        return
    if declared:
        d.ok("Standards declared in %s: %s" % (declared, list_join(listed)))
    elif listed:
        d.ok("no Standards: declaration - the list is crawled: " + list_join(listed))
    else:
        d.ok("no Standards: declaration and nothing to crawl - the reviewers apply the smell"
             " baseline alone")


def check_glossary(d: Doctor) -> None:
    """The root GLOSSARY.md, read in-process through the glossary module's
    own parse: absent is ok; one that parses is ok with its entry count; one
    that gives no entries is a FAIL carrying the message `orch.sh glossary
    terms` dies with. No heuristic for a near miss."""
    path = os.path.join(d.root, "GLOSSARY.md")
    if not os.path.isfile(path):
        d.ok("no GLOSSARY.md - no glossary is read, so the Consistency lens reads none and the"
             " reviewers' glossary parse check does not run")
        return
    terms, err, code = capture(lambda: glossary.terms(path))
    if not code:
        d.ok("%d glossary entries read from GLOSSARY.md" % len(terms))
        return
    d.fail(err_line(err))
    d.remedy('write each entry as a **Term**: line, e.g. "**Doctor**: the diagnostic command."'
             ' (optionally after a "- " bullet)', SETUP_REMEDY)


def check_adr_dir(d: Doctor) -> None:
    """Absent is fine: no ADRs are read. A docs/adr that exists and is no
    directory is a FAIL, since the skills and the spec review's lenses read
    it as one. The count is the Markdown files directly in it."""
    adr = os.path.join(d.root, "docs", "adr")
    if not os.path.lexists(adr):
        d.ok("no docs/adr - no ADRs are read")
        return
    if not os.path.isdir(adr):
        d.fail("docs/adr exists and is no directory - the skills and the spec review read ADRs"
               " from it.")
        d.remedy("remove docs/adr and create it as a directory of Markdown files, or delete it"
                 " to have no ADRs read", SETUP_REMEDY)
        return
    n = sum(1 for name in os.listdir(adr) if name.endswith(".md") and not name.startswith(".")
            and os.path.isfile(os.path.join(adr, name)))
    d.ok("docs/adr holds %d ADRs" % n)


def check_sub_issues(d: Doctor) -> None:
    """Sub-issues have no setting of their own, so the endpoint is asked
    against an issue that exists. A warn, never a FAIL: the real gate is
    breakdown publish's sub-issue listing read (ticket_link), and a probe
    that fails outright is neither answer, saying so in gh's first line."""
    if not d.gh_gate():
        return
    try:
        supported = d.gh.sub_issues_supported()
    except GhFailed as failed:
        d.warn("sub-issues support could not be probed: " + gh_reason(failed.stderr))
        return
    if supported is None:
        d.warn("sub-issues support could not be probed - the repo has no issue to test it"
               " against.")
    elif supported:
        d.ok("sub-issues supported")
    else:
        d.warn("sub-issues do not appear to be supported on this GitHub instance - breakdown"
               " publish will fail at its sub-issue listing read (ticket_link) at spec time.")


def check_git_exclude(d: Doctor) -> None:
    """A warn, not a FAIL: init writes these lines, so a missing one only
    bites someone who arrived mid-flow. One warning for every missing line,
    and a remedy appending only those - its leading echo ending an
    unterminated last line, so it never glues onto the user's pattern."""
    missing = exclude_missing(EXCLUDED_DIRS, d.git)
    if not missing:
        d.ok(list_join(EXCLUDED_DIRS) + " git-excluded")
        return
    d.warn(list_join(missing) + " not git-excluded - flow state and planning drafts would show as"
           " untracked.")
    d.remedy("{ echo; printf '%%s\\n' %s; }>>\"$(git rev-parse --git-common-dir)/info/exclude\""
             % "".join("'%s' " % line for line in missing))


def default_known(d: Doctor) -> str:
    """The default branch as doctor already holds it, bash's seeded memo:
    GitHub's answer from the probe, else the local fallback - never a
    GitHub read of its own."""
    return d.repo_branch or default_branch_local(d.git).name


def check_base_branch(d: Doctor) -> None:
    """The base branch every new flow forks from and targets. A setting whose
    branch has gone from origin would send the next fork at nothing, so it
    FAILs; origin unreachable only means it could not be checked. The
    default reuses the branch GitHub answered in the probe, else the local
    fallback, with no second ask."""
    branch = base_setting(d.git)
    if not branch:
        d.ok("base branch: %s (default)" % default_known(d))
        return
    on_origin = d.git.origin_has_branch(branch)
    if on_origin:
        d.ok("base branch: %s (set)" % branch)
    elif on_origin is False:
        d.fail("base branch %s is set but no longer exists on origin - new flows would fork from"
               " nothing." % branch)
        d.remedy("orch.sh base clear", "orch.sh base set <branch>")
    else:
        d.warn("base branch %s (set) could not be verified - origin is not reachable." % branch)


# The verification labels, in the order doctor reports them, and the files
# they are read from, in the order the agents read them (ADR-0058).
VERIFICATION_LABELS = ("Ticket verification", "Full verification", "Branch verification")
VERIFICATION_FILES = ("CLAUDE.md", "AGENTS.md", "CONTRIBUTING.md")
# The words bash itself answers, a builtin or a keyword, which count as found
# though no file is: bash 5's `compgen -b` and `compgen -k`.
BASH_WORDS = frozenset("""
. : [ alias bg bind break builtin caller cd command compgen complete compopt continue declare
dirs disown echo enable eval exec exit export false fc fg getopts hash help history jobs kill
let local logout mapfile popd printf pushd pwd read readarray readonly return set shift shopt
source suspend test times trap true type typeset ulimit umask unalias unset wait
if then else elif fi case esac for select while until do done in function time { } ! [[ ]]
coproc
""".split())
ASSIGNMENT_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# bash's default IFS, which splits a command into its words.
IFS_WORDS = re.compile(r"[ \t\n]+")


class VerificationLine(NamedTuple):
    label: str
    file: str
    command: str


def verification_lines(root: str) -> List[VerificationLine]:
    """Every verification line of the repo's instructions at <root>: a line
    outside a fenced code block opening with a label and its colon, its
    command trimmed, "" for a label with no command. Doctor never judges
    whether a command runs, only that each label is named once, with one."""
    found = []
    for name in VERIFICATION_FILES:
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            continue
        lines = file_lines(path)
        for line, state in zip(lines, fenced(lines)):
            if state:
                continue
            label = next((label for label in VERIFICATION_LABELS
                          if line.startswith(label + ":")), None)
            if label is not None:
                found.append(VerificationLine(label, name, trim(line[len(label) + 1:])))
    return found


def verification_report(d: Doctor, label: str, lines: List[VerificationLine]) -> None:
    """One label's report, by the first rule that holds: a line with no
    command is a FAIL and the label's only line; two different commands
    warn; else the label is found. A found label's report, and a twice-named
    one's, ends on the installed check of its first command."""
    setup = os.path.join(d.plugin, "docs", "repo-setup.md")
    named = [line for line in lines if line.label == label]
    bare = next((line.file for line in named if not line.command), None)
    if bare is not None:
        d.fail("%s has a '%s:' line with no command." % (bare, label))
        d.remedy("write the command after '%s:' in %s, or remove the line - see %s"
                 % (label, bare, setup))
        return
    if not named:
        verification_missing(d, label, setup)
        return
    first = named[0]
    other = next((line for line in named if line.command != first.command), None)
    if other is not None:
        d.warn("%s is named twice with different commands: '%s' in %s and '%s' in %s - the"
               " first, '%s', is the one used." % (label, first.command, first.file,
                                                   other.command, other.file, first.command))
        d.remedy("remove the line '%s: %s' from %s, or make it match - see %s"
                 % (label, other.command, other.file, setup))
    else:
        d.ok("%s: %s (%s)" % (label, first.command, first.file))
    verification_installed_check(d, first)


def verification_missing(d: Doctor, label: str, setup: str) -> None:
    """A label no file names: Full warns with its remedy; Ticket and Branch
    are ok, naming what runs instead."""
    if label == "Full verification":
        d.warn("no 'Full verification:' line in CLAUDE.md, AGENTS.md or CONTRIBUTING.md - the"
               " agents' fallback is not defined by the code.")
        d.remedy("add the line 'Full verification: <command>' to CLAUDE.md - see " + setup)
    elif label == "Branch verification":
        d.ok("no 'Branch verification:' line - the combined-branch check runs the full"
             " verification")
    else:
        d.ok("no 'Ticket verification:' line - tickets run the full verification (ADR-0058)")


def verification_word(command: str) -> str:
    """The first command word of a verification line's command, the
    backticks around it and any leading VAR=value words dropped; "" where
    none is left."""
    rest = trim(command)
    rest = rest[1:] if rest.startswith("`") else rest
    rest = rest[:-1] if rest.endswith("`") else rest
    for word in IFS_WORDS.split(rest):
        if not word:
            continue
        name, equals, _ = word.partition("=")
        if equals and ASSIGNMENT_NAME.fullmatch(name):
            continue
        return word
    return ""


def verification_found(d: Doctor, word: str) -> bool:
    """Whether a command word is found: an executable file for a path,
    relative to the repo root; else a bash builtin or keyword, or a file on
    PATH. A function orch.sh defines never counts."""
    if "/" in word:
        path = word if word.startswith("/") else os.path.join(d.root, word)
        return os.path.isfile(path) and os.access(path, os.X_OK)
    return word in BASH_WORDS or d.installed(word)


def verification_installed_check(d: Doctor, line: VerificationLine) -> None:
    """The installed check of a label's chosen command: found is ok; not
    found a warn with no remedy, since no one command installs an arbitrary
    tool. A command that leaves no word says nothing."""
    word = verification_word(line.command)
    if not word:
        return
    if verification_found(d, word):
        d.ok("%s command: %s" % (line.label, word))
    else:
        d.warn("%s command %s (from %s) is not installed." % (line.label, word, line.file))


def check_verification_lines(d: Doctor) -> None:
    lines = verification_lines(d.root)
    for label in VERIFICATION_LABELS:
        verification_report(d, label, lines)


# How each kind of the agent module's settings records reports.
AGENT_REPORTERS = {"ok": Doctor.ok, "warn": Doctor.warn, "fail": Doctor.fail,
                   "remedy": Doctor.remedy}


def check_agent_settings(d: Doctor) -> None:
    """Claude Code's and Junie's agent settings, the Junie session and the
    models Junie did not recognise, and the copies' sync drift, single-
    sourced in the agent module and read from it in-process: each record
    reported as its kind. A read that dies is this check's one FAIL."""
    records = d.answer_or_fail(lambda: agent.settings_report(d.git, d.root, d.env, d.plugin))
    for kind, message in records or ():
        AGENT_REPORTERS[kind](d, message)


def check_side_checkouts_finished(d: Doctor) -> None:
    """A finished side checkout left standing is a leftover the sweep has
    not run on: a warn on each, with the command that removes it, and
    nothing for one still in use. The finished test is the sweep's own,
    side_checkout_finished. With no side checkout there is nothing to ask
    GitHub, so the gate - and a skip with GitHub unreachable - only counts
    once one exists. The test's default branch is the probe's answer:
    doctor asks GitHub for it only in its probe."""
    found = checkouts(d.git)
    if found is None:
        d.fail("could not read the checkouts - git worktree list failed, so no side checkout"
               " could be checked.")
        return
    sides = [checkout.path for checkout in found if checkout.kind == "side"]
    if not sides or not d.gh_gate():
        return
    for path in sides:
        name = os.path.basename(path)
        verdict = side_checkout_finished(d.gh, d.git, path, lambda: default_known(d))
        if verdict.code == FINISHED:
            d.warn("side checkout %s is finished - its PR is merged, and it is still standing at"
                   " %s." % (name, path))
            d.remedy("orch.sh side-checkout remove " + name)
        elif verdict.code == UNREAD:
            d.warn("side checkout %s could not be checked: %s" % (name, verdict.reason))


# How long another host's claim is held before doctor names it.
CLAIM_DAY = 86400


def check_autopilot_claims(d: Doctor) -> None:
    """Claims: this host's whose process is gone (asked of the Liveness
    module), and other hosts' held for more than a day (the watcher never
    touches those). Silent where origin cannot be read, and for this host's
    claims where the main checkout cannot be resolved."""
    claims, _ = claims_read(d.gh)
    if claims is None:
        return
    now, me, main = int(time.time()), host_id(d.env), d.git.main_checkout()
    for claim in claims:
        if claim.host == me:
            if main is None:
                continue
            alive, pid = issue_alive(main, claim.issue, d.env)
            if alive:
                continue
            d.warn("issue #%s is claimed by this host (phase %s), but its process is gone (%s)."
                   % (claim.issue, claim.phase, "pid " + pid if pid else "no record"))
            d.remedy("orch.sh autopilot tick")
            continue
        started = iso_epoch(claim.started)
        if started is None or not now - started > CLAIM_DAY:
            continue
        d.warn("issue #%s has been claimed by %s (pid %s, phase %s) since %s - more than a day."
               % (claim.issue, claim.host, claim.pid, claim.phase, claim.started))
        d.remedy("if that session is gone, run orch.sh autopilot tick on " + claim.host)


def check_autopilot_side_flows(d: Doctor) -> None:
    """check_flow_autopilot_label's check for each autopilot flow living in
    a side checkout other than this one: the watcher makes those, so a plain
    doctor in the main checkout is where a label that disagrees with a side
    checkout's recorded phase is seen. One whose marker records no issue,
    with no flow, or whose state file will not parse is passed over, and so
    is one whose issue cannot be read."""
    found = checkouts(d.git)
    here = os.path.realpath(d.root)
    for checkout in found or ():
        if checkout.kind != "side" or checkout.path == here:
            continue
        issue = side_checkout_marker_issue(d.git, checkout.path)
        if issue is None:
            continue
        state = flow_state_get_many(flow_state_file(checkout.path), ("phase",))
        if state is None:
            continue
        if not d.gh_gate():
            return
        standing, _ = standing_read(d.gh, int(issue))
        if standing is None:
            continue
        phase_label_verdict(d, issue, state["phase"], standing.labels,
                            "its side checkout " + os.path.basename(checkout.path),
                            "phase label of #" + issue)


# The flow checks' group header.
FLOW_HEAD = "flow state"

# The env checks, in report order.
ENV_CHECKS: List[Entry] = [
    Head("tools"),
    *checks(check_git, check_gh, check_jq, check_python3, check_bash),
    Head("auth & remotes"),
    *checks(check_origin, check_gh_auth, check_gh_repo, check_default_branch),
    Head("plugin environment"),
    *checks(check_host, check_plugin_root, check_orch_sh),
    Head("repo config"),
    *checks(check_labels_doc, check_labels_exist, check_standards_declaration, check_glossary,
            check_adr_dir, check_sub_issues, check_git_exclude, check_base_branch,
            check_verification_lines, check_agent_settings, check_side_checkouts_finished,
            check_autopilot_claims, check_autopilot_side_flows),
]


# --- flow state -----------------------------------------------------------------
# The checks below read the values the probe read from state.json in one read
# (Doctor.flow), never state.json itself, so a missing jq and a file that will
# not parse each settle all of them at once, in flow_scope, before any runs:
# reaching a check at all is the proof that its preconditions held.


def check_state_phase(d: Doctor) -> None:
    phase = d.flow["phase"]
    if phase in PHASES:
        d.ok("phase: " + phase)
        return
    d.fail("unknown phase: %s (want one of: %s)" % (phase, " ".join(PHASES)))
    d.remedy(flow_cmd(d.env, "abort"))


def check_flow_issue(d: Doctor) -> None:
    """Unconditional on how the issue arrived - adopted at init or published
    by the spec phase. The ready-for-agent label is deliberately not
    re-checked: it is a one-time gate at adoption (docs/adr/0005). Read
    through the shared flow-issue memo, which knows OPEN and CLOSED only."""
    issue = d.flow["issue"]
    if not issue:
        d.ok("issue: not recorded yet")
        return
    if not d.gh_gate():
        return
    read = d.issue_read()
    if read.state == "OPEN":
        d.ok("issue #%s open" % issue)
    elif read.state == "CLOSED":
        # pr open always writes `Closes #<issue>`, so a done flow's issue
        # being closed is the expected result of merging.
        if d.flow["phase"] == "done":
            d.ok("issue #%s closed" % issue)
        else:
            d.fail("issue #%s is closed." % issue)
            d.remedy("gh issue reopen " + issue)
    else:
        d.fail("issue #%s could not be read from GitHub: %s" % (issue, gh_reason(read.err)))
        d.remedy("gh issue view " + issue)


def check_flow_branch(d: Doctor) -> None:
    """A local branch alone, never a tag of the same name."""
    branch = d.flow["branch"]
    if not branch:
        d.ok("branch: not created yet")
        return
    if d.git.branch_exists(branch):
        d.ok("branch: " + branch)
        return
    # A done flow stays put until the next init archives it (ADR-0009), and
    # its branch deleted after the merge is the routine end of a flow.
    if d.flow["phase"] == "done":
        d.ok("branch: %s gone - expected after merge" % branch)
        return
    d.fail("branch %s no longer exists - the flow has nothing left to build on." % branch)
    d.remedy(flow_cmd(d.env, "abort"))


def check_flow_upstream(d: Doctor) -> None:
    """Only from the phase that pushes onwards: before implement, not having
    pushed is correct. origin/<branch> specifically, not just any upstream:
    a branch may still track its base until its first push (#1152)."""
    branch = d.flow["branch"]
    if not branch:
        return
    upstream = d.git.branch_upstream(branch) or ""
    if upstream == "refs/remotes/origin/" + branch:
        d.ok("upstream: " + upstream[len("refs/remotes/"):])
        return
    # After the merge the remote branch is routinely deleted; a push remedy
    # here would recreate a branch somebody removed on purpose.
    if d.flow["phase"] == "done":
        d.ok("upstream: none - expected after merge")
        return
    d.warn("branch %s is not on origin yet." % branch)
    d.remedy("git push -u origin refs/heads/%s:refs/heads/%s" % (branch, branch))


def check_flow_pr(d: Doctor) -> None:
    pr = d.flow["pr"]
    if not pr:
        d.ok("PR: not opened yet")
        return
    if not d.gh_gate():
        return
    read = d.pr_read()
    if read.state == "OPEN":
        d.ok("PR #%s open" % pr)
    elif read.state == "MERGED":
        d.ok("PR #%s merged" % pr)
    elif read.state == "CLOSED":
        d.fail("PR #%s is closed." % pr)
        d.remedy("gh pr reopen " + pr)
    else:
        d.fail("PR #%s could not be read from GitHub: %s" % (pr, gh_reason(read.err)))
        d.remedy("gh pr view " + pr)


def check_flow_review_terminal(d: Doctor) -> None:
    """The proactive surface for the classification `redo review` refuses
    on: a human sees "this loop looks interrupted" before wondering why redo
    won't run. The classification is the review module's, handed the
    iteration and budget the probe read: the word, its detail and, for
    malformed, the record path last."""
    i, budget = d.flow["iteration"], d.flow["budget"]
    lines = d.answer_or_fail(lambda: review_terminal_report(d.root, i, budget))
    if lines is None:
        return
    # As bash's $(...) read the bridge's lines: trailing newlines dropped.
    word, _, detail = "\n".join(lines).rstrip("\n").partition("\n")
    if word == "none":
        d.ok("review loop: not started yet")
    elif word == "ready":
        d.ok("review loop at a terminal state: ready")
    elif word == "stop":
        d.ok("review loop at a terminal state: stop (%s)" % detail.split("\n", 1)[0])
    # Both warn rather than FAIL: /orchestrator:next resumes either one. A
    # loop short of its budget is proceeding normally, where one whose last
    # iteration recorded nothing looks like its session simply died.
    elif word == "pending":
        d.warn("review loop hasn't reached its budget yet (iteration %s of budget %s) - %s will"
               " resume it; redo refuses until it reaches a terminal state."
               % (i, budget, flow_cmd(d.env, "next")))
    elif word == "interrupted":
        d.warn("review loop's last iteration (%s of budget %s) has no recorded terminal state -"
               " the session looks interrupted, not stopped. %s will resume it; redo refuses"
               " until it reaches a terminal state." % (i, budget, flow_cmd(d.env, "next")))
    # A FAIL, not a warn: the record is there but unreadable, and
    # /orchestrator:next will not rewrite it - only a human editing it will.
    elif word == "malformed":
        shape, _, record = detail.partition("\n")
        d.fail("review loop's last iteration (%s) has a malformed terminal state - %s"
               % (i, shape))
        d.remedy("rewrite the first line of %s in the expected shape above"
                 % record.split("\n", 1)[0])
    elif word == "unreadable":
        d.fail("review loop's terminal state cannot be read: " + detail)


def check_flow_review_budget(d: Doctor) -> None:
    """`review begin` dies rather than start an iteration past budget, so an
    iteration count past it is state.json in a shape nothing produced on a
    healthy run. An iteration test cannot count reads as within budget."""
    i, budget = d.flow["iteration"], d.flow["budget"]
    n = int_as_test_reads(i)
    if n is not None and n > int(budget):
        d.fail("review loop iteration (%s) is past its budget (%s) - the loop's stop"
               " enforcement did not hold." % (i, budget))
        d.remedy(flow_cmd(d.env, "abort"))
        return
    d.ok("review loop iteration (%s) within budget (%s)" % (i, budget))


def check_flow_review_ci(d: Doctor) -> None:
    """The loop requires CI green before it marks the PR ready, so the
    review module's ci_probe over the required checks is the loop's read of
    exactly this, asked once: a snapshot, never the live loop's grace."""
    pr = d.flow["pr"]
    if not pr or not d.gh_gate():
        return
    lines = d.answer_or_fail(lambda: ci_probe(d.gh, recorded_pr(pr), "required"))
    if lines is None:
        return
    verdict, detail = lines[0], "\n".join(lines[1:])
    if verdict == "green":
        d.ok("CI: required checks green")
    elif verdict == "none":
        d.ok("CI: no required checks reported")
    elif verdict == "pending":
        d.ok("CI: required checks still pending")
    elif verdict == "failing":
        d.fail("CI: required check(s) failing on PR #%s." % pr)
        d.remedy("gh pr checks " + pr)
    else:
        # ci_probe's only other word - a failing round trip, not fixable
        # from here, so no remedy; gh's reason rides in the warn.
        d.warn("CI: could not be read from GitHub for PR #%s: %s" % (pr, trim(detail)))
        return
    if detail:
        d.line(detail)


def check_flow_review_draft(d: Doctor) -> None:
    """`review ready` marks the PR ready and records phase: done as one
    operation, so isDraft and phase disagreeing on an open PR is evidence
    that operation only half landed."""
    pr = d.flow["pr"]
    if not pr or not d.gh_gate():
        return
    read = d.pr_read()
    if not read.state:
        d.warn("PR #%s draft state could not be read from GitHub: %s" % (pr, gh_reason(read.err)))
        return
    # A merged or closed PR cannot go back to draft.
    if read.state != "OPEN":
        return
    phase = d.flow["phase"]
    if phase == "done" and read.draft:
        d.fail("PR #%s is still a draft but the flow phase is done - review ready did not take."
               % pr)
        d.remedy("orch.sh pr ready    # on " + d.flow["branch"])
    elif phase == "review" and not read.draft:
        d.fail("PR #%s was marked ready on GitHub but the flow phase is still review -"
               " state.json fell out of sync." % pr)
        d.remedy("gh pr view " + pr)
    else:
        d.ok("PR #%s draft state matches phase (%s)" % (pr, phase))


def check_flow_handoffs(d: Doctor) -> None:
    """Pure reuse: what makes a handoff valid lives in handoff_report, and
    which are due is the phase table's handoffs_due - phase names what runs
    next, so every earlier phase has already written one."""
    phase, issue = d.flow["phase"], d.flow["issue"]
    # A phase the table does not hold is due nothing, so the check skips it.
    due = handoffs_due(phase)
    if due:
        ready, finding = handoff_ready(d.env, issue)
        if ready == NOT_READY:
            d.fail(finding)
            d.remedy(flow_cmd(d.env, "abort"))
            return
        if ready == READY_IF_GH and not d.gh_gate():
            return
        fetched, reason = handoff_fetch_due(lambda: d.gh, d.env, d.root, phase, issue)
        if fetched == 2:
            d.fail("could not write the copies of issue #%s's handoff comments to %s"
                   % (issue, handoff_scratch_dir(d.root)))
            return
        if fetched:
            d.fail("could not read issue #%s's handoff comments: %s"
                   % (issue, reason or "gh's output is not a comment list"))
            return
    state_file = flow_state_file(d.root)
    for name in due:
        path, present = handoff_fetched(d.env, d.root, name)
        if not present:
            d.fail(handoff_doctor_missing(d.env, name, issue))
            d.remedy(flow_cmd(d.env, "redo"))
            continue
        lines, _ = handoff_report(path, state_file, d.env, name)
        problems = [line for line in lines if not line.startswith("ok ")]
        if not problems:
            d.ok("handoff %s complete" % name)
            continue
        for line in problems:
            d.fail("handoff %s: %s" % (name, line[len("FAIL "):] if line.startswith("FAIL ")
                                       else line))
        d.remedy(flow_cmd(d.env, "redo"))


def phase_label_verdict(d: Doctor, issue: str, phase: str, labels: Sequence[str], source: str,
                        ok_lead: str) -> bool:
    """The ok or warn line, and the warn's remedy, for issue #<issue>'s
    phase labels among <labels> against the phase <source> (where it was
    recorded, e.g. "this checkout") last moved to; <ok_lead> opens the ok
    line. False, printing nothing, when the issue carries no phase
    label."""
    verdict, text = label_verdict(labels, phase)
    if verdict == "none":
        return False
    if verdict == "agrees":
        d.ok("%s: %s" % (ok_lead, text))
        return True
    d.warn("issue #%s is labelled %s, but %s last moved to phase %s."
           % (issue, text, source, phase))
    redo = redo_phase(live_phase(labels), phase)
    if redo is not None:
        d.remedy("the watcher will run %s %s" % (flow_cmd(d.env, "redo"), redo))
    else:
        d.remedy("relabel the issue %s; the watcher refuses this disagreement" % phase_label(phase))
    return True


def check_flow_autopilot_label(d: Doctor) -> None:
    """An autopilot flow's phase is its issue's phase label (ADR-0052);
    state.json records the phase this checkout last moved to, and a label
    that disagrees is flagged. An interactive flow carries no phase label
    and is left alone - except under ORCH_AUTOPILOT=1, where a flow with
    none is refused. The labels come from the shared flow-issue memo; a
    failed read is the issue check's to report."""
    issue, phase = d.flow["issue"], d.flow["phase"]
    if not issue:
        if autopilot_active(d.env):
            d.fail("autopilot session, but no issue is recorded - the flow's phase has no label"
                   " to live on.")
            d.remedy(flow_cmd(d.env, "abort"))
        return
    if not d.gh_gate():
        return
    read = d.issue_read()
    if not read.read:
        return
    if phase_label_verdict(d, issue, phase, read.labels, "this checkout", "phase label"):
        return
    if autopilot_active(d.env):
        d.fail("issue #%s carries no phase label - an autopilot session needs the flow's phase"
               " recorded on its issue." % issue)
        d.remedy("gh issue edit %s --add-label %s" % (issue, phase_label(phase)))


def check_flow_worktree_clean(d: Doctor) -> None:
    """Every phase commits and pushes its own work before it ends, so a
    change outside the planning allowlist at a phase boundary is a bug in
    the phase that left it - caught here, at the top of /orchestrator:next.
    Silent on a clean tree; a git status that cannot run is this check's
    FAIL, never the end of the report."""
    dirty = d.answer_or_fail(lambda: dirty_outside_allowlist(d.git))
    if not dirty:
        return
    d.fail("the working tree has changes outside the planning allowlist: " + list_join(dirty))
    d.remedy("git status")


def check_ticket_worktrees_left(d: Doctor) -> None:
    """A ticket worktree under this checkout is a run's leftover once its
    phase is not running (ADR-0036): the next implement phase or quick
    implementation stops on it, and archive refuses to move it. Silent when
    there is none - ticket-worktree list's own scope, so another checkout's
    in-flight tickets never fail this one. A listing that cannot be read is
    never read as none: it is this check's one FAIL."""
    left = d.answer_or_fail(lambda: ticket_worktrees_under(d.git, d.root))
    for n, path in left or ():
        d.fail("ticket worktree %s is left over - a ticket run did not finish." % path)
        d.remedy("orch.sh ticket-worktree remove " + n)


# The flow checks, in report order, each with the phases it runs in.
FLOW_CHECKS: List[Entry] = [
    Head(FLOW_HEAD),
    *checks(check_state_phase, check_flow_issue, check_flow_branch),
    Check("check_flow_upstream", check_flow_upstream, "implement+"),
    *checks(check_flow_pr),
    Check("check_flow_review_terminal", check_flow_review_terminal, "review"),
    Check("check_flow_review_budget", check_flow_review_budget, "review"),
    Check("check_flow_review_ci", check_flow_review_ci, "review"),
    Check("check_flow_review_draft", check_flow_review_draft, "review+"),
    *checks(check_flow_handoffs, check_flow_autopilot_label),
]


def flow_scope(d: Doctor, scope: str) -> None:
    """The flow scope, after the env scope where both run. --flow asks about
    a flow specifically, so having none is a failure there; bare doctor did
    not ask, so it states the absence and carries on: an empty answer must
    never be mistaken for a healthy one."""
    state_file = flow_state_file(d.root)
    if scope == "flow":
        require_state_exists(state_file, d.env)
    if not os.path.isfile(state_file):
        d.head(FLOW_HEAD)
        d.ok("no active flow")
    elif scope == "flow" and not d.jq:
        # --flow never runs the tools group, so nothing else here would
        # report the jq every flow check needs: skipping them all and still
        # exiting 0 is the one answer a diagnostic must never give -
        # /orchestrator:next gates on exactly that exit code.
        d.run([Head(FLOW_HEAD), *checks(check_jq)])
    else:
        run_flow(d)
    # On every path here - no flow, a broken state file, no jq - because it
    # reads git alone (#673): a quick implementation has no flow, and its
    # leftover is reported here or nowhere.
    d.run(checks(check_ticket_worktrees_left))


def run_flow(d: Doctor) -> None:
    """The flow checks that apply at the flow's phase, once jq and the state
    file both held; else, under the flow header, the skip of every flow
    check or the state file's one FAIL."""
    if d.jq and d.flow is not None:
        d.run(entries_at(FLOW_CHECKS, d.flow["phase"]))
        # Outside the registry: it reads git alone and prints nothing when
        # clean, so a flow with a clean tree reports exactly what it did.
        d.run(checks(check_flow_worktree_clean))
        return
    d.head(FLOW_HEAD)
    if not d.jq:
        d.jq_skipped += sum(1 for entry in FLOW_CHECKS if isinstance(entry, Check))
        return
    # One problem earns one FAIL: every check reads this file, so there is
    # nothing left to say about it and nothing that could be said honestly.
    d.fail("%s/state.json is not exactly one JSON object." % ORCH_DIR_NAME)
    d.remedy(flow_cmd(d.env, "abort"))


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    pin: Optional[RepoPin] = None,
    plugin: str = PLUGIN_ROOT,
) -> int:
    """`orch.sh doctor [--env|--flow]`: the real adapters, the process's
    environment and this package's plugin root unless a test hands in
    others. Outside a checkout it dies first, as orch.sh does."""
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
    d = Doctor(env, git, root, pin, adapter_of(gh, env, pin), plugin)
    d.probe(scope)
    if scope != "flow":
        d.run(ENV_CHECKS)
    if scope != "env":
        flow_scope(d, scope)
    d.skip_report()
    d.line("")
    d.line("%d ok, %d warn, %d FAIL" % (d.oks, d.warns, d.fails))
    return 1 if d.fails else 0
