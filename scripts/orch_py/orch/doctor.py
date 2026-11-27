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
import re
import shutil
import subprocess
import sys
from typing import Callable, List, Mapping, NamedTuple, Optional, Union

from orch import glossary
from orch.base import base_setting, default_branch_local
from orch.common import (EXCLUDED_DIRS, capture, die, err_line, exclude_missing, fenced,
                         file_lines, list_join, stdout_write, trim)
from orch.gh import GhFailed, adapter_of, gh_reason, label_listed
from orch.git import Git
from orch.host import host_detect
from orch.repo import REPO_CAUSE, REPO_MISSING, RepoPin, owner_name
from orch.review import standards_resolve_source
from orch.root import checkout_root
from orch.triage_labels import LABELS_DOC, expected_labels

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


def check_base_branch(d: Doctor) -> None:
    """The base branch every new flow forks from and targets. A setting whose
    branch has gone from origin would send the next fork at nothing, so it
    FAILs; origin unreachable only means it could not be checked. The
    default reuses the branch GitHub answered in the probe, else the local
    fallback, with no second ask."""
    branch = base_setting(d.git)
    if not branch:
        d.ok("base branch: %s (default)" % (d.repo_branch or default_branch_local(d.git).name))
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
            check_verification_lines),
]


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
    d.skip_report()
    d.line("")
    d.line("%d ok, %d warn, %d FAIL" % (d.oks, d.warns, d.fails))
    return 1 if d.fails else 0
