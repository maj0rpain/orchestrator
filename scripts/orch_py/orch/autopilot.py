"""orch.sh's autopilot noun (ADR-0067). orch.sh runs the noun as a converted
noun, and the bash autopilot module is gone: each helper is named for its bash
one without the `autopilot_` prefix, its bash name noted as `bash <name>`, and
keeps its messages and its order of steps.
run(argv) takes the arguments after `autopilot`, as orch.sh hands them on, and
returns the exit code; every error dies through orch.common.die. It dispatches
every verb, refusing an unknown op and each verb's arguments with bash's
messages, and runs them all - `settings`, `show`, `active`, `rounds`,
`budget`, `start`, `candidates`, `watch`, the question, reply and re-entry
verbs `questions`, `reply`, `resume`, `ask`, `answer` and `reenter`, and the
Sync request verbs `sync`, `sync-finish`, `sync-dropped` and `sync-fail`, over
the Standing module's transitions, `run`, the session wrapper a tick starts,
with its session end, the pause files it reads and extends, and the review
budget record, and `tick` - the pause checks, the label check, the claims read
and stale cleanup, the done read, the merged-PR close through the pr module
in-process, the hourly housekeeping, sync detection, and ranking and Pickup
within the Cap and the Sync slots, each run started detached as `orch.sh
autopilot run <issue>` - with the bash noun's stdout, exit codes and `orch:`
messages, in a plain and an autopilot (ORCH_AUTOPILOT=1) session. The only
orch.sh children it starts run Python nouns: the watch's fresh `orch.sh
autopilot tick` per tick, a tick's init and redo in a side checkout, its runs,
and a run's `verification stop`.

Beside the noun, the concept every Python noun reads: whether this is an
autopilot session, the plan's `## Autopilot` block, as handoff_report checks
it for 01-plan.md, the UTC timestamps the pause files hold, and the GitHub
limit record the gh adapter's limit handling makes in an autopilot process -
the GitHub limit pause under the main checkout and a session's hit file, in
the format and at the path the bash gh adapter's limit record writes them
too (pinned by tests/github_pause/, ADR-0067).

The gh, handoff, flow-state, standing, trust, filed-finding, liveness,
side-checkout, checkout, PR, branch and issue-timeline modules the verbs
call are imported inside them: each imports this module's concept part at
its own import, or imports a module that does, so importing them here at
the top would be a cycle; the session-log module is imported with them.
"""
from __future__ import annotations

import calendar
import contextlib
import io
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import Callable, Dict, List, Mapping, Optional, Tuple

from orch.agent import autopilot_setting_check, default_plugin_root
from orch.common import (ORCH_DIR_NAME, UTC_STAMP_FORMAT, capture, die, exit_status,
                         file_write_atomic, is_positive_int, lines_of, plain_number, read_raw,
                         read_text, rm_f, stderr_write, stdout_write, subshell, temp_text_file,
                         trim, warn)
from orch.git import Git
from orch.host import host_detect, plugin_cmd
from orch.repo import REPO_REMEDY, RepoPin, owner_name
from orch.root import checkout_root
from orch.triage_labels import TriageLabels

# A GitHub pause is never recorded further ahead than this many seconds:
# no GitHub limit names a later reset.
AUTOPILOT_GITHUB_PAUSE_MAX = 3600

# The `## Autopilot` block's keys, in the order its report checks them.
AUTOPILOT_BLOCK_KEYS = ("Rounds", "Budget")


def autopilot_active(env: Mapping[str, str]) -> bool:
    """Whether <env> is an autopilot session's - the one reader of
    ORCH_AUTOPILOT, so no skill reads the variable itself."""
    return env.get("ORCH_AUTOPILOT", "") == "1"


def autopilot_block_values(text: str, key: str) -> List[str]:
    """The value of each `<key>: <value>` line in <text>'s `## Autopilot`
    section, trimmed, in order, as bash's autopilot_block_values read it: a
    line whose value is blank holds none."""
    # Imported here: the handoff module reads this one at its own import.
    from orch.handoff import section_body

    prefix = key + ":"
    values = []
    for line in section_body(text, "## Autopilot"):
        value = trim(line[len(prefix):]) if line.startswith(prefix) else ""
        if value:
            values.append(value)
    return values


def autopilot_block_report(text: str) -> Tuple[List[str], int]:
    """The plan <text>'s `## Autopilot` block in handoff_report's lines, as
    bash's autopilot_block_report gave it: `ok ## Autopilot`, or one FAIL line
    per problem with status 1. The block is `Rounds` and `Budget`, each one
    line holding a whole number of 1 or more."""
    from orch.handoff import section_count

    if section_count(text, "## Autopilot") == 0:
        return ["FAIL missing section: ## Autopilot"], 1
    lines = []
    for key in AUTOPILOT_BLOCK_KEYS:
        values = autopilot_block_values(text, key)
        if not values:
            lines.append('FAIL ## Autopilot has no %s line (want "%s: <n>")' % (key, key))
        elif len(values) > 1:
            lines.append("FAIL ## Autopilot repeats its %s line" % key)
        elif not is_positive_int(values[0]):
            lines.append("FAIL ## Autopilot %s is %s - it must be a whole number of 1 or more"
                         % (key, values[0]))
    if lines:
        return lines, 1
    return ["ok ## Autopilot"], 0


# --- the pause files ------------------------------------------------------------


def epoch_iso(epoch: int) -> str:
    """Epoch seconds as a UTC timestamp, bash autopilot_epoch_iso."""
    return time.strftime(UTC_STAMP_FORMAT, time.gmtime(epoch))


def iso_epoch(text: str) -> Optional[int]:
    """The UTC timestamp <text>, YYYY-MM-DDTHH:MM:SSZ, as epoch seconds, or
    None for a value that does not read - bash autopilot_iso_epoch."""
    try:
        return calendar.timegm(time.strptime(text, UTC_STAMP_FORMAT))
    except ValueError:
        return None


def autopilot_dir(main: str) -> str:
    """Where a clone's autopilot files live under its main checkout <main>."""
    return "%s/%s/autopilot" % (main, ORCH_DIR_NAME)


def github_pause_file(main: str) -> str:
    """The GitHub limit file under <main>, the pause a GitHub API rate limit
    writes (#2577)."""
    return autopilot_dir(main) + "/github-limit"


def pause_epoch(path: str) -> int:
    """The reset recorded in the limit file <path> as epoch seconds; 0 when
    the file is missing or its text does not read."""
    return iso_epoch(read_text(path) or "") or 0


def pause_put(path: str, epoch: int) -> bool:
    """bash autopilot_pause_put: records <epoch> in <path> as one UTC
    timestamp line, keeping a reset already there that is later and
    replacing one that is earlier or does not read. Whether it held: False
    when the file cannot be written."""
    if os.path.isfile(path) and not pause_epoch(path) < epoch:
        return True
    return file_write_atomic(path, epoch_iso(epoch) + "\n")


def github_reset_cap(epoch: int, now: float) -> int:
    """<epoch>, or <now> plus AUTOPILOT_GITHUB_PAUSE_MAX when <epoch> is
    further ahead, bash autopilot_github_reset_cap."""
    return min(epoch, int(now) + AUTOPILOT_GITHUB_PAUSE_MAX)


def github_limit_record(env: Mapping[str, str], reset: int, now: float,
                        main_checkout: Callable[[], Optional[str]]) -> List[str]:
    """bash autopilot_github_limit_record <reset>: in an autopilot process -
    a tick or the session wrapper, each by a flag of its own, or a session
    (ORCH_AUTOPILOT=1) - the GitHub limit pause under the main checkout
    <main_checkout> answers (None when it cannot be read), its reset capped
    at an hour from <now>, kept if a later one is recorded; in a session,
    which has the wrapper's hit file path, the hit file too. A plain process
    writes nothing. Never fails: one clause per failed write, in order, for
    the limit line to carry."""
    if not (autopilot_active(env) or env.get("ORCH_AUTOPILOT_TICK", "")
            or env.get("ORCH_AUTOPILOT_RUN", "")):
        return []
    capped = github_reset_cap(reset, now)
    clauses = []
    main = main_checkout()
    if main:
        if not pause_put(github_pause_file(main), capped):
            clauses.append("could not write the GitHub limit pause under " + main)
    else:
        clauses.append("could not write the GitHub limit pause: the main checkout is unreadable")
    hit = env.get("ORCH_AUTOPILOT_HIT_FILE", "")
    if autopilot_active(env) and hit and not pause_put(hit, capped):
        clauses.append("could not write the GitHub limit hit file " + hit)
    return clauses


# --- the noun -------------------------------------------------------------------

# The verbs, in the order the unknown-op refusal lists them.
OPS = "show|settings|active|rounds|budget|start|candidates|tick|watch|run|ask|answer|reenter|questions|reply|resume|sync|sync-finish|sync-dropped|sync-fail"

# The permission modes a headless session may run with, and the numeric
# settings' defaults. Each lives here alone, so show validates against one
# list.
AUTOPILOT_MODES = ("default", "acceptEdits", "plan", "dontAsk", "bypassPermissions")
AUTOPILOT_CAP_DEFAULT = 3
AUTOPILOT_ROUNDS_DEFAULT = 2
AUTOPILOT_BUDGET_DEFAULT = 3
AUTOPILOT_GITHUB_RESERVE_DEFAULT = 20

# The autopilot setting names, in the order show prints them; settings prints
# the same list, so the two never disagree.
AUTOPILOT_SETTING_NAMES = ("permission-mode", "cap", "handle", "rounds", "budget", "model",
                           "effort", "auto-sync", "github-reserve")

# The seconds watch waits between ticks unless --every names others.
AUTOPILOT_WATCH_EVERY_DEFAULT = 60

# The git config section every setting lives under, and the pattern that
# reads them all.
SETTING_PREFIX = "orchestrator.autopilot."
SETTING_PATTERN = r"^orchestrator\.autopilot\."
# The defaults of the settings that have one but the handle, as text.
SETTING_DEFAULTS = {
    "cap": str(AUTOPILOT_CAP_DEFAULT),
    "rounds": str(AUTOPILOT_ROUNDS_DEFAULT),
    "budget": str(AUTOPILOT_BUDGET_DEFAULT),
    "auto-sync": "true",
    "github-reserve": str(AUTOPILOT_GITHUB_RESERVE_DEFAULT),
}

WATCH_USAGE = "usage: orch.sh autopilot watch [--every <seconds>]"
CANDIDATES_USAGE = "usage: orch.sh autopilot candidates [<n>... | --all | --limit <k>]"


class Autopilot:
    """One run of the noun: the checkout at <root> the git adapter <git>
    runs in, the environment <env>, the repo pin <pin>, the gh adapter
    <gh_of> makes at the first GitHub call, the clock, the process starter
    and the sleep."""

    def __init__(self, root: str, git, env: Mapping[str, str], pin, gh_of,
                 clock: Callable[[], float], starter: Callable[..., object],
                 sleep: Callable[[float], None] = time.sleep) -> None:
        self.root = root
        self.git = git
        self.env = env
        self.pin = pin
        self.gh_of = gh_of
        self.clock = clock
        self.starter = starter
        self.sleep = sleep
        self._config: Dict[str, Dict[str, str]] = {}

    def lookup(self, name: str) -> Tuple[str, str]:
        """The key orchestrator.autopilot.<name> - local config, then global
        - and where it came from, local, global or unset: ("", "unset") when
        neither holds it. Never validates. Each scope is read once."""
        key = SETTING_PREFIX + name
        for scope in ("local", "global"):
            if scope not in self._config:
                self._config[scope] = self.git.config_regexp(scope, SETTING_PATTERN)
            if key in self._config[scope]:
                return self._config[scope][key], scope
        return "", "unset"

    def setting(self, name: str) -> Tuple[str, str]:
        """The effective, validated value of orchestrator.autopilot.<name>
        and its source (local, global, default or unset), bash
        autopilot_setting. The permission mode, the model and the effort
        stay unset when unset, the handle falls back to the repo's owner, the
        auto-sync to true and the four integers to their defaults
        (github-reserve ranging 0-99). Dies naming the key and the value when
        a value is out of range; the handle's owner is resolved only when the
        handle is needed."""
        value, source = self.lookup(name)
        key = SETTING_PREFIX + name
        if name in ("permission-mode", "model", "effort"):
            if source == "unset":
                return value, source
            if name != "permission-mode":
                # The agent module holds Claude Code's lists.
                autopilot_setting_check(name, value, key)
            elif value not in AUTOPILOT_MODES:
                die("%s is %s - not a permission mode (want %s)"
                    % (key, value, "|".join(AUTOPILOT_MODES)))
            return value, source
        if name == "handle":
            if source != "unset":
                return value, source
            repo = self.pin.resolve()
            if repo is None:
                die("%s (the handle defaults to the repo's owner; or git config %s <handle>)"
                    % (REPO_REMEDY, key))
            return owner_name(repo.name).split("/", 1)[0], "default"
        if source == "unset":
            value, source = SETTING_DEFAULTS[name], "default"
        if name == "auto-sync":
            if value not in ("true", "false"):
                die("%s is %s - it must be true or false (git config %s true|false)"
                    % (key, value, key))
        elif name == "github-reserve":
            if not plain_number(value) or int(value) > 99:
                die("%s is %s - it must be an integer from 0 to 99 (git config %s <n>)"
                    % (key, value, key))
            value = str(int(value))
        else:
            if not is_positive_int(value):
                die("%s is %s - it must be a positive integer (git config %s <n>)"
                    % (key, value, key))
            value = str(int(value))
        return value, source


def watch_every(args: List[str]) -> int:
    """watch's arguments, bash's: none, or `--every <seconds>`, a positive
    whole number - the seconds between ticks."""
    every = str(AUTOPILOT_WATCH_EVERY_DEFAULT)
    if args:
        if args[0] != "--every" or len(args) != 2:
            die(WATCH_USAGE)
        every = args[1]
    if not is_positive_int(every):
        die("--every must be a positive whole number of seconds, got: " + every)
    return int(every)


def dispatch(ap: Autopilot, op: str, args: List[str]) -> int:
    """Runs the verb <op> on <args>, its exit code; refuses an unknown op
    and arguments the verb does not take, as bash's cmd_autopilot does."""
    if op in VERBS:
        count, tail, verb = VERBS[op]
        if len(args) != count:
            die("usage: orch.sh autopilot %s%s" % (op, tail))
        return verb(ap, *args)
    if op == "watch":
        return watch_verb(ap, watch_every(args))
    if op == "candidates":
        return candidates_verb(ap, *candidates_args(args))
    die("unknown autopilot op: %s (want %s)" % (op or "<none>", OPS))


def candidates_args(args: List[str]) -> Tuple[str, int, List[int]]:
    """candidates' arguments, bash's: issue numbers, `--all` or `--limit
    <k>`, never two forms - the mode (named, all or limit), the limit and
    the issues named."""
    mode, limit, issues = "", 0, []
    rest = list(args)
    while rest:
        arg = rest.pop(0)
        if arg == "--all":
            if mode:
                die(CANDIDATES_USAGE)
            mode = "all"
        elif arg == "--limit":
            if mode or not rest:
                die(CANDIDATES_USAGE)
            if not is_positive_int(rest[0]):
                die("--limit must be a positive whole number, got: " + rest[0])
            mode, limit = "limit", int(rest.pop(0))
        elif not plain_number(arg) or mode not in ("", "named"):
            die(CANDIDATES_USAGE)
        else:
            mode = "named"
            issues.append(int(arg))
    if not mode:
        die(CANDIDATES_USAGE)
    return mode, limit, issues


def settings_verb(ap: Autopilot) -> int:
    """`autopilot settings`: the setting names, one a line, in show order."""
    stdout_write("".join(name + "\n" for name in AUTOPILOT_SETTING_NAMES))
    return 0


def show_verb(ap: Autopilot) -> int:
    """`autopilot show`: one line per setting, its key, value and source,
    "(none)" for a setting with no value. Dies on a value out of range,
    after the lines of the settings before it."""
    for name in AUTOPILOT_SETTING_NAMES:
        value, source = ap.setting(name)
        stdout_write("%s%s %s (%s)\n" % (SETTING_PREFIX, name, value or "(none)", source))
    return 0


def active_verb(ap: Autopilot) -> int:
    """`autopilot active`: 0 in an autopilot session, else 1, printing
    nothing."""
    return 0 if autopilot_active(ap.env) else 1


def plan_number(ap: Autopilot, root: str, key: str) -> int:
    """The <key> line of the `## Autopilot` block of the newest plan comment
    of the issue the flow in the checkout at <root> records, a plain
    integer, bash autopilot_plan_value. Dies when no issue is recorded, when
    the comments cannot be read, when the issue has no plan comment, and when
    its block holds no one valid <key> line."""
    # Imported here: these modules read this one at their own import.
    from orch.flow_state import flow_state_file, require_issue
    from orch.handoff import handoff_comment_missing
    from orch.issue_timeline import timeline_body, timeline_handoff, timeline_read_or_die

    issue = require_issue(flow_state_file(root), ap.env)["issue"]
    entries = timeline_read_or_die(ap.gh_of(), issue)
    index = timeline_handoff(entries, "01-plan")
    if index is None:
        handoff_comment_missing(issue, "01-plan")
    values = autopilot_block_values(timeline_body(entries, index), key)
    if len(values) != 1 or not is_positive_int(values[0]):
        die("issue #%s's plan comment has no valid ## Autopilot %s line" % (issue, key))
    return int(values[0])


def plan_value(ap: Autopilot, key: str) -> int:
    """`autopilot rounds` and `autopilot budget`: this checkout's flow's
    plan_number for <key>, printed."""
    stdout_write("%d\n" % plan_number(ap, ap.root, key))
    return 0


def start_verb(ap: Autopilot, issue: str, plan_file: str) -> int:
    """`autopilot start <issue> <plan-file>`: the Standing module's start,
    the ready label the repo's own, the plan checked against this
    checkout's flow state."""
    from orch.flow_state import flow_state_file
    from orch.standing import standing_start

    ready = TriageLabels(lambda: ap.root).label("ready-for-agent")
    standing_start(ap.gh_of(), issue, plan_file, ready, flow_state_file(ap.root), ap.env)
    return 0


def verdict(gh, triage, n: int, row: Optional[Tuple[str, List[str]]] = None) -> str:
    """The quick autopilot's verdict on issue #n, bash autopilot_verdict:
    `eligible <none|move|override>` or `skip <reason>`, the first exclusion
    in the fixed order (closed, missing, untrusted, phase, wontfix,
    needs-info, ticket, untriaged-finding). Only an issue read here - one
    with no listed <row>, its state and labels - can be `missing`, on gh's
    not-found reason. <triage> names the repo's triage labels. Writes
    nothing; dies on any other failed read."""
    from orch.filed_finding import finding_untriaged
    from orch.gh import GhFailed, gh_issue_not_found, gh_or_die, gh_reason, label_listed
    from orch.standing import phase_labels_in
    from orch.trust import issue_check

    if row is None:
        try:
            row = gh.issue_state_labels(n)
        except GhFailed as failed:
            if gh_issue_not_found(failed.stderr):
                return "skip missing"
            die("could not read issue #%d: %s" % (n, gh_reason(failed.stderr)))
    state, labels = row
    if state != "OPEN":
        return "skip closed"
    try:
        untrusted = issue_check(gh, n)
    except GhFailed as failed:
        die("could not check the trust of issue #%d: %s" % (n, gh_reason(failed.stderr)))
    if untrusted is not None:
        return "skip untrusted " + untrusted.writer
    phases = phase_labels_in(labels)
    if phases:
        return "skip phase " + phases[0]
    for role in ("wontfix", "needs-info"):
        if label_listed(labels, triage.label(role)):
            return "skip " + role
    parent = gh_or_die("read issue #%d's parent" % n, gh.issue_parent, n)
    if parent:
        return "skip ticket #%d" % parent
    # A filed finding finding triage has not yet triaged: the issue triage gate.
    if finding_untriaged(labels, triage):
        return "skip untriaged-finding"
    if label_listed(labels, triage.label("ready-for-agent")):
        return "eligible none"
    if label_listed(labels, triage.label("ready-for-human")):
        return "eligible override"
    return "eligible move"


def candidates_verb(ap: Autopilot, mode: str, limit: int, issues: List[int]) -> int:
    """`autopilot candidates`: one line per issue, `<n> <verdict>` - the
    issues named, in the order named, each read on its own; or with --all
    and --limit <k> every open issue, oldest first, from one listing whose
    rows give each verdict its state and labels, --limit keeping the first
    k eligible lines. Every read comes before the first line is printed, so
    a failed read leaves no partial list. It writes nothing."""
    from orch.gh import gh_or_die

    gh = ap.gh_of()
    triage = TriageLabels(lambda: ap.root)
    rows: Mapping[int, Tuple[str, List[str]]] = {}
    if mode != "named":
        listed = gh_or_die("list the open issues", gh.issues_open_rows)
        issues = [row.number for row in listed]
        rows = {row.number: (row.state, row.labels) for row in listed}
    report, eligible = [], 0
    for n in issues:
        if mode == "limit" and eligible >= limit:
            break
        answer = verdict(gh, triage, n, rows.get(n))
        if answer.startswith("eligible"):
            eligible += 1
        report.append("%d %s\n" % (n, answer))
    stdout_write("".join(report))
    return 0


# --- the question, reply and re-entry verbs --------------------------------------


def phase_arg(phase: str, code: int = 1) -> None:
    """Dies, exit <code>, unless <phase> is a phase a question can be asked
    in - one flow phase, never done - bash autopilot_phase_arg."""
    from orch.handoff import PHASES

    if phase not in PHASES:
        die("not a flow phase: %s (want %s)" % (phase, "|".join(PHASES)), code)
    if phase == "done":
        die("a done flow asks no question", code)


def file_text(what: str, path: str) -> str:
    """<path>'s text, exactly; dies, naming <what>, when it is no file, and
    when it cannot be read - bash autopilot_file_text."""
    if not os.path.isfile(path):
        die("%s file not found: %s" % (what, path))
    text = read_raw(path)
    if text is None:
        die("could not read " + path)
    return text.replace("\0", "")


def flow_issue(ap: Autopilot, code: int = 1) -> str:
    """The flow's recorded issue, read in one state read; dies, exit
    <code>, as require_issue does."""
    from orch.flow_state import flow_state_file, require_issue

    return require_issue(flow_state_file(ap.root), ap.env, code=code)["issue"]


def handle_of(ap: Autopilot) -> str:
    """The handle a question @mentions: the handle setting's value."""
    return ap.setting("handle")[0]


def ask_verb(ap: Autopilot, phase: str, path: str) -> int:
    """`autopilot ask <phase> <file>`: <file> posted as <phase>'s question
    comment on the flow's issue, the handle @mentioned, needs-human added,
    the claim released."""
    from orch.standing import Chain, standing_ask

    phase_arg(phase)
    text = file_text("question", path)
    issue = flow_issue(ap)
    handle = handle_of(ap)
    standing_ask(Chain(ap.gh_of(), issue), phase, text, handle)
    return 0


def reenter_verb(ap: Autopilot, phase: str, path: str) -> int:
    """`autopilot reenter <phase> <file>`: the automatic re-entry of a
    review loop whose stop asks nothing - <file> posted as a re-entry
    comment, the claim released; the third in a row asks instead. Only the
    review phase re-enters, refused before any write."""
    from orch.standing import Chain, standing_reenter

    if phase != "review":
        die("only the review phase re-enters automatically, got: " + phase)
    text = file_text("re-entry", path)
    issue = flow_issue(ap)
    standing_reenter(Chain(ap.gh_of(), issue), phase, text, lambda: handle_of(ap))
    return 0


def answer_verb(ap: Autopilot, phase: str, path: str) -> int:
    """`autopilot answer <phase> <file>`: <phase>'s newest question comment,
    marker stripped, and each reply after it behind a `---` line, written to
    <file>. Exits 1, writing nothing, when no reply follows the question or
    the phase was re-entered automatically since - the caller re-asks, or
    carries on - and 2 on any other failure, so a failed read is never taken
    for no reply."""
    from orch.issue_timeline import (timeline_answers, timeline_body, timeline_question,
                                     timeline_read_or_die, timeline_reentered, timeline_replied)

    phase_arg(phase, 2)
    issue = flow_issue(ap, 2)
    gh = ap.gh_of()
    if not gh.pin():
        die(REPO_REMEDY, 2)
    entries = timeline_read_or_die(gh, issue, code=2)
    if timeline_reentered(entries, phase):
        die("issue #%s was re-entered automatically in %s - no reply to read" % (issue, phase))
    question = timeline_question(entries, phase)
    if question is None:
        die("issue #%s has no %s question comment" % (issue, phase), 2)
    if not timeline_replied(entries, phase):
        die("no reply to the %s question on issue #%s yet" % (phase, issue))
    text = (timeline_body(entries, question) + (timeline_answers(entries, phase) or "")).rstrip(
        "\n")
    if not file_write_atomic(path, text + "\n"):
        die("could not write " + path, 2)
    return 0


def resume_verb(ap: Autopilot, issue: str) -> int:
    """`autopilot resume <issue>`: needs-human removed from an open issue
    carrying it, and nothing else."""
    from orch.gh import gh_die
    from orch.standing import STANDING_HUMAN_LABEL, standing_human_guard, standing_resume

    if not is_positive_int(issue):
        die("not an issue number: " + issue)
    gh = ap.gh_of()
    standing_human_guard(gh, issue)
    reason = standing_resume(gh, issue)
    if reason:
        gh_die("remove %s from issue #%s" % (STANDING_HUMAN_LABEL, issue), reason)
    return 0


def reply_verb(ap: Autopilot, issue: str, path: str) -> int:
    """`autopilot reply <issue> <file>`: <file> posted as a comment on the
    issue, then needs-human removed - refused unless the label is still on
    and no reply follows the issue's newest question comment."""
    from orch.gh import gh_or_die
    from orch.issue_timeline import timeline_question, timeline_read_or_die, timeline_replied
    from orch.standing import STANDING_HUMAN_LABEL, standing_human_guard, standing_resume

    if not is_positive_int(issue):
        die("not an issue number: " + issue)
    if not os.path.isfile(path):
        die("reply file not found: " + path)
    if not os.path.getsize(path):
        die("reply file is empty: " + path)
    gh = ap.gh_of()
    standing_human_guard(gh, issue)
    entries = timeline_read_or_die(gh, issue)
    if timeline_question(entries) is None:
        die("issue #%s has no question comment to reply to" % issue)
    if timeline_replied(entries):
        die("a reply already follows the newest question on issue #%s" % issue)
    gh_or_die("post the reply on issue #" + issue, gh.issue_comment, int(issue), path)
    reason = standing_resume(gh, issue)
    if reason:
        die("the reply comment landed on issue #%s, but %s could not be removed: %s"
            % (issue, STANDING_HUMAN_LABEL, reason))
    return 0


def sync_verb(ap: Autopilot, issue: str) -> int:
    """`autopilot sync <issue>`: a Sync request filed on an open orch:done
    issue, through the Standing sync request transition - refused, with an
    `orch: ` message, for an issue that is closed, not at orch:done or
    already carrying orch:sync. It reads the issue's labels alone: no side
    checkout, as bash's autopilot_sync reads none."""
    from orch.gh import gh_die
    from orch.standing import (STANDING_SYNC_LABEL, phase_label, standing_read_or_die,
                               standing_sync_request)

    if not is_positive_int(issue):
        die("not an issue number: " + issue)
    gh = ap.gh_of()
    standing = standing_read_or_die(gh, issue)
    if standing.state != "OPEN":
        die("issue #%s is closed" % issue)
    if not standing.is_done():
        die("issue #%s is not at %s - a sync request needs a done flow"
            % (issue, phase_label("done")))
    if standing.sync:
        die("issue #%s already carries %s" % (issue, STANDING_SYNC_LABEL))
    reason = standing_sync_request(gh, issue)
    if reason:
        gh_die("add %s to issue #%s" % (STANDING_SYNC_LABEL, issue), reason)
    return 0


# The three ends of a sync session, each a Standing transition the orch-sync
# skill's autopilot branch calls, on the issue flow state records.


def sync_finish_verb(ap: Autopilot) -> int:
    """`autopilot sync-finish`: orch:sync removed, the claim released."""
    from orch.standing import Chain, standing_sync_finish

    standing_sync_finish(Chain(ap.gh_of(), flow_issue(ap)))
    return 0


def sync_dropped_verb(ap: Autopilot, path: str) -> int:
    """`autopilot sync-dropped <file>`: the dropped-intent stop, <file>
    listing the intents the resolver dropped. The auto-sync setting picks
    the comment's what-happens-next wording; the merge is pushed, so a bad
    value never kills the stop: its refusal is the warning, and the stop
    takes false."""
    from orch.standing import Chain, standing_sync_dropped

    text = file_text("dropped-intents", path)
    issue = flow_issue(ap)
    try:
        auto_sync = ap.setting("auto-sync")[0] == "true"
    except SystemExit:
        auto_sync = False
    standing_sync_dropped(Chain(ap.gh_of(), issue), text, auto_sync)
    return 0


def sync_fail_verb(ap: Autopilot, reason: str) -> int:
    """`autopilot sync-fail <reason>`: the failure stop of the sync,
    orch:sync kept."""
    from orch.standing import STANDING_SYNC_PHASE, Chain, standing_stop

    if not reason:
        die("a sync failure needs a reason")
    standing_stop(Chain(ap.gh_of(), flow_issue(ap)), "failure", STANDING_SYNC_PHASE, reason)
    return 0


def questions_verb(ap: Autopilot) -> int:
    """`autopilot questions`: one tab-separated line per open needs-human
    issue carrying a phase label other than orch:done, or sitting at
    orch:done stopped by a sync (phase sync) - the issue, its kind
    (question, replied or stop), the phase, and the URL of the comment the
    kind is about. The newer of the issue's newest question comment and its
    latest stop decides the kind. One line saying so when nothing is listed;
    every read comes first, so a failed one dies printing nothing."""
    from orch.gh import gh_or_die
    from orch.issue_timeline import (timeline_question, timeline_read_or_die,
                                     timeline_replied, timeline_stop, timeline_url)
    from orch.standing import STANDING_HUMAN_LABEL, STANDING_SYNC_PHASE, standing_of

    gh = ap.gh_of()
    rows = gh_or_die("list the %s issues" % STANDING_HUMAN_LABEL, gh.issues_labelled_rows,
                     STANDING_HUMAN_LABEL)
    lines = []
    for row in sorted(rows, key=lambda row: row.number):
        standing = standing_of(row.state, row.labels)
        entries = timeline_read_or_die(gh, str(row.number))
        question, stop = timeline_question(entries), timeline_stop(entries)
        q_phase = entries[question].info.arg if question is not None else ""
        stop_phase = entries[stop].info.arg if stop is not None else ""
        phase = standing.phase
        if not phase:
            # A done issue is listed only when a sync stopped it: orch:sync
            # still on it (a failure stop), or its newest stop a sync stop.
            if not standing.is_done() or not (standing.is_sync()
                                              or stop_phase == STANDING_SYNC_PHASE):
                continue
            phase = q_phase = stop_phase = STANDING_SYNC_PHASE
        if question is not None and (stop is None or question > stop):
            kind = "replied" if timeline_replied(entries) else "question"
            lines.append((row.number, kind, q_phase, timeline_url(entries, question)))
        elif stop is not None:
            lines.append((row.number, "stop", stop_phase, timeline_url(entries, stop)))
        else:
            lines.append((row.number, "stop", phase, ""))
    if not lines:
        stdout_write("nothing pending: no open %s issue of an autopilot flow\n"
                     % STANDING_HUMAN_LABEL)
    stdout_write("".join("%d\t%s\t%s\t%s\n" % line for line in lines))
    return 0


# --- the gate and watch --------------------------------------------------------------


def gate(ap: Autopilot) -> None:
    """The host and settings gate tick and watch start with, bash
    autopilot_gate: dies on any detected host other than Claude Code, or no
    claude on PATH, then with no permission mode set, naming the key, then
    on a model or effort outside its list - before any issue is claimed."""
    host = host_detect(ap.env)
    if (host and host != "claude") or shutil.which("claude", path=ap.env.get("PATH")) is None:
        die("autopilot is Claude Code only (no headless-session fallback on this host;"
            " see docs/host-capabilities.md)")
    mode_require(ap)
    for name in ("model", "effort"):
        ap.setting(name)


def orch_sh() -> str:
    """The orch.sh beside the package's plugin root, which the watcher's
    and the session wrapper's children run - bash AUTOPILOT_SELF."""
    return os.path.join(default_plugin_root(), "scripts", "orch.sh")


class WatchStopped(BaseException):
    """The INT or TERM the watch took: it ends the loop wherever it is."""


class Watch:
    """One watch: the run it serves and the tick it waits on, None between
    ticks."""

    def __init__(self, ap: Autopilot) -> None:
        self.ap = ap
        self.tick = None

    def tick_status(self) -> int:
        """Starts one tick, a fresh `orch.sh autopilot tick` with stdin from
        /dev/null and stdout dropped, as bash's background job has them,
        held as the tick it waits on, and waits for it: its exit status as
        bash's wait gives it (started)."""
        code = started(self.ap, [orch_sh(), "autopilot", "tick"], hold=self.hold,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        self.tick = None
        return code

    def hold(self, tick) -> None:
        """Holds <tick> as the tick the watch waits on, for stop_tick."""
        self.tick = tick

    def stop_tick(self) -> None:
        """The watch's INT/TERM step for the tick it waits on, bash
        autopilot_watch_stop_child: sends it TERM and waits for it to
        exit."""
        if self.tick is None:
            return
        try:
            self.tick.terminate()
        except OSError:
            pass
        self.tick.wait()


def watch_verb(ap: Autopilot, every: int) -> int:
    """Repeats tick every <every> seconds until interrupted, bash
    autopilot_watch, after the gate. Refuses while another watch of this
    clone is alive, replaces a pidfile whose process is gone, reports a
    failed tick on stderr and carries on. On INT or TERM it removes its
    pidfile, TERMs the tick it waits on and waits for it, or cuts its sleep
    short, and exits 0; on any other exit it removes its pidfile. Each tick
    is a fresh orch.sh process, so a tick that dies takes nothing else with
    it."""
    from orch.liveness import watch_begin, watch_end, watch_pidfile

    gate(ap)
    pidfile = watch_pidfile(ap.git)
    if not watch_begin(pidfile, ap.env):
        return 1
    watch = Watch(ap)
    # Set once the first INT or TERM is taken, or the watch is ending:
    # another signal then changes nothing.
    stopping = []

    def stop(signum, frame) -> None:
        if not stopping:
            stopping.append(signum)
            raise WatchStopped()

    handlers = {signum: signal.signal(signum, stop) for signum in (signal.SIGINT, signal.SIGTERM)}
    try:
        while True:
            code = watch.tick_status()
            if code != 0:
                warn("autopilot watch: the tick failed (exit %d); trying again in %ds"
                     % (code, every))
            ap.sleep(every)
    except WatchStopped:
        watch_end(pidfile)
        watch.stop_tick()
        return 0
    finally:
        stopping.append(0)
        for signum, handler in handlers.items():
            signal.signal(signum, handler)
        watch_end(pidfile)
# --- the pause files read and extended --------------------------------------------


def usage_pause_file(main: str) -> str:
    """The usage limit file under <main>: pickup paused until a usage
    limit's reset."""
    return autopilot_dir(main) + "/limit"


def pause_held(path: str, now: float, capped: bool) -> Optional[str]:
    """Whether the limit file <path> pauses pickup at <now>, bash
    autopilot_pause_until's read: while its reset is ahead, the reset as
    shown (the file's text); once it has passed, the file removed and None.
    A <capped> file - the GitHub one or an early pool's - more than an hour
    ahead is first rewritten to an hour on, the cut warned; a failed rewrite
    still holds until the cut time, and the next read cuts again."""
    if not os.path.isfile(path):
        return None
    epoch = pause_epoch(path)
    if epoch <= now:
        rm_f(path)
        return None
    shown = read_text(path) or ""
    if capped:
        cut = github_reset_cap(epoch, now)
        if cut != epoch:
            file_write_atomic(path, epoch_iso(cut) + "\n", make_directory=False)
            shown = epoch_iso(cut)
            warn("the GitHub pause until %s is more than an hour away, which no GitHub limit"
                 " names; it is cut to %s" % (epoch_iso(epoch), shown))
    return shown


def github_paused(ap: Autopilot) -> bool:
    """Whether a GitHub pause holds, saying nothing but the warning of a
    pause it cut, bash autopilot_github_paused; never, where the main
    checkout cannot be read."""
    main = ap.git.main_checkout()
    return main is not None and pause_held(github_pause_file(main), ap.clock(), True) is not None


def github_pause_wait(ap: Autopilot, wait: float = 0) -> None:
    """Sleeps until a GitHub pause that holds has passed, else <wait>
    seconds; ORCH_GH_LIMIT_WAIT, the guard's test knob, replaces the wait
    either way."""
    from orch.checkout import main_checkout_or_die

    if github_paused(ap):
        path = github_pause_file(main_checkout_or_die(ap.git))
        wait = github_reset_cap(pause_epoch(path), ap.clock()) - ap.clock()
    knob = ap.env.get("ORCH_GH_LIMIT_WAIT", "")
    try:
        wait = float(knob) if knob else wait
    except ValueError:
        pass
    ap.sleep(max(0.0, wait))


def log_append(log: str, text: str) -> None:
    """Appends <text> to the session log <log>; a failed write is lost, as
    bash's `>>` loses it."""
    try:
        with open(log, "a") as f:
            f.write(text)
    except OSError:
        pass


def pause_extend(path: str, epoch: int, log: str, what: str = "") -> None:
    """Records <epoch> as the reset of the limit file <path>, by
    pause_put's rule; <what> ("GitHub") prefixes "limit file" in a
    failure's note. A failed write is noted in <log> and on stderr, and is
    no failure of the caller."""
    if not pause_put(path, epoch):
        message = "autopilot run: could not write the %slimit file %s" % (
            what + " " if what else "", path)
        warn(message)
        log_append(log, message + "\n")


# --- tick -----------------------------------------------------------------------


def pause_until(ap: Autopilot, main: str, kind: str = "") -> bool:
    """bash autopilot_pause_until: whether a limit pauses pickup under the
    main checkout <main> - the usage limit, with <kind> "github" the GitHub
    API rate limit, or with a pool (core or graphql) its early GitHub pause.
    While it holds, one line names its reset: the GitHub pauses on stderr,
    which the watcher keeps so its log says why it is idle, the usage limit
    on stdout. A passed pause's file is removed (pause_held)."""
    if kind == "github":
        path, what = github_pause_file(main), "GitHub API rate limit: the tick does nothing until"
    elif kind:
        path = github_early_file(main, kind)
        what = "GitHub %s pool is below the github-reserve: no issue is picked up until" % kind
    else:
        path, what = usage_pause_file(main), "usage limit: no issue is picked up until"
    shown = pause_held(path, ap.clock(), bool(kind))
    if shown is None:
        return False
    if kind:
        warn("%s %s" % (what, shown))
    else:
        stdout_write("%s %s\n" % (what, shown))
    return True


def github_early_file(main: str, pool: str) -> str:
    """The early GitHub pause's file for <pool> (core or graphql) under
    <main>: pickup paused, before any limit is hit, while the pool is below
    the github-reserve (#2577)."""
    return "%s/github-early-%s" % (autopilot_dir(main), pool)


def github_early(ap: Autopilot, gh, main: str, reserve: int) -> None:
    """The early GitHub pause, bash autopilot_github_early: reads the pools
    and, for each with less than <reserve> (the github-reserve setting)
    percent of its limit left, records its reset, capped at an hour from
    now, in the pool's early file under <main> (kept if later). A reserve of
    0 reads nothing; a failed or empty read pauses nothing."""
    if reserve <= 0:
        return
    pools = pools_read(gh)
    if pools is None:
        return
    now = ap.clock()
    for line in pools.split("\n"):
        fields = line.split(None, 3)
        if len(fields) != 4 or fields[0] not in ("core", "graphql") \
                or not all(plain_number(field) for field in fields[1:]):
            continue
        remaining, limit, reset = (int(field) for field in fields[1:])
        if limit <= 0 or remaining * 100 >= reserve * limit or reset <= now:
            continue
        if not pause_put(github_early_file(main, fields[0]), github_reset_cap(reset, now)):
            warn("could not write the early GitHub pause under " + main)


def labels_ensure(gh) -> None:
    """The labels a tick ensures exist with their colour and description,
    bash autopilot_labels_ensure: reads the repo's labels once and upserts
    only the standing labels missing or drifted in colour or description -
    names and colours compared case-insensitively, descriptions exactly -
    so with nothing drifted it writes nothing. A failed read or upsert dies,
    stopping the tick."""
    from orch.gh import GhFailed, gh_reason
    from orch.standing import label_entries

    try:
        have = gh.labels_detail(1000)
    except GhFailed as failed:
        die("could not read the repo's labels: %s - the tick stops" % gh_reason(failed.stderr))
    seen = {(name.lower(), colour.lower(), description) for name, colour, description in have}
    for name, colour, description in label_entries():
        if (name.lower(), colour.lower(), description) in seen:
            continue
        try:
            gh.label_upsert(name, colour, description)
        except GhFailed as failed:
            die("could not upsert the label %s: %s - the tick stops"
                % (name, gh_reason(failed.stderr)))


def stop_contained(ap: Autopilot, issue: str, tail: str, kind: str, phase: str,
                   detail: str) -> bool:
    """The tick's one way to run a stop, bash autopilot_stop_contained: a
    single standing_stop attempt, a death inside it ending the stop and not
    the tick (the next tick is the retry). The stop's own failure line
    reaches stderr; when it fails, warns "could not stop issue #<issue> -
    its claim stays held; <tail>" and is False."""
    from orch.standing import Chain, standing_stop

    chain = Chain(ap.gh_of(), issue)
    if subshell(lambda: standing_stop(chain, kind, phase, detail)) == 0:
        return True
    warn("could not stop issue #%s - its claim stays held; %s" % (issue, tail))
    return False


def backstop_line(log: str) -> str:
    """The last line of the session log <log> a wrapper's stop chain wrote
    when it gave up; "" when it holds none or cannot be read."""
    text = read_raw(log) or ""
    lines = [line for line in text.split("\n") if line.startswith(AUTOPILOT_BACKSTOP_PREFIX)]
    return lines[-1] if lines else ""


def cleanup_stale(ap: Autopilot, main: str, claims) -> int:
    """Stale claims released, bash autopilot_cleanup_stale: every claim of
    <claims> - the tick's one read - held by this host whose process is
    gone (liveness's to name) is a failure stop, quoting its session log's
    backstop line when it has one, and both of the issue's records go with
    the claim. A stop that cannot land is contained: the claim and the
    records stay held for a later tick, and a GitHub pause holding after it
    ends the cleanup early. Other hosts' claims are never touched. The
    number of claims it released."""
    from orch import liveness
    from orch.gh import claim_ref
    from orch.standing import host_id

    me = host_id(ap.env)
    released = 0
    for claim in claims:
        if claim.host != me:
            continue
        alive, gone_pid = liveness.issue_alive(main, claim.issue, ap.env)
        if alive:
            continue
        unknown = " - no exit code is known"
        detail = ("the session's process (pid %s) is gone and the claim was never released%s"
                  % (gone_pid or "unknown", unknown))
        log = liveness.latest_log(main, claim.issue, claim.phase)
        backstop = backstop_line(log) if log else ""
        if backstop:
            detail = '%s - the session log says: "%s"' % (
                detail[:-len(unknown)], backstop[len("autopilot run: "):])
        detail += "; log: " + log if log else "; no session log"
        tail = ("the next tick tries again; if the issue is gone for good, delete the claim ref"
                " by hand: git push origin :" + claim_ref(int(claim.issue)))
        if stop_contained(ap, claim.issue, tail, "failure", claim.phase, detail):
            liveness.issue_forget(main, claim.issue)
            released += 1
        elif github_paused(ap):
            break
    return released


def done_read(gh) -> List[List[str]]:
    """The tick's one read of the open orch:done issues, bash
    autopilot_done_read: the done table from the listed rows, with no
    per-issue read - `[<issue>, <running>, <sync>, <human>]` for each issue
    whose row reads OPEN and still at orch:done, each flag "0" or "1". A
    failed listing warns once and gives none; it does not stop the tick."""
    from orch.gh import GhFailed, gh_reason
    from orch.standing import phase_label, standing_of

    label = phase_label("done")
    try:
        rows = gh.issues_labelled_rows(label)
    except GhFailed as failed:
        warn("could not list the issues labelled %s: %s - no merged-PR close or sync detection"
             " this tick" % (label, gh_reason(failed.stderr)))
        return []
    table = []
    for row in rows:
        standing = standing_of(row.state, row.labels)
        if standing.state != "OPEN" or not standing.is_done():
            continue
        table.append([str(row.number)] + [
            "1" if flag else "0" for flag in (standing.running, standing.sync, standing.human)])
    return table


def close_missed(ap: Autopilot, gh, table: List[List[str]]) -> List[List[str]]:
    """The merged-PR backstop (#2478), run every tick whatever the
    auto-sync setting, from the done <table>: pr's close_missed_rows called
    in-process, not at all for an empty table. The table less every issue
    it closed. A failed close keeps just that issue, and a failed read - or
    a death in the close - the whole table, after its warning: the tick
    never stops on it."""
    from orch.pr import close_missed_rows

    kept = [table]
    if table:
        def close() -> None:
            kept[0] = close_missed_rows(table, gh=gh, git=ap.git, env=ap.env, now=ap.clock)
        subshell(close)
    return kept[0]


def sync_detect(gh, table: List[List[str]]) -> None:
    """The sync request auto-detection, bash autopilot_sync_detect, from the
    done <table> (it reads no issue itself). When the table is not empty,
    reads the repo's open PRs once, fork PRs dropped, then files a sync
    request on every issue in it carrying none of orch:sync, needs-human and
    orch:running whose one open same-repository PR (head branch
    `orch/<issue>-`) is CONFLICTING. An issue with no such PR is skipped
    silently, one with several warned about; a failed read or write warns
    and skips that issue only."""
    from orch.branch import branch_name_flow
    from orch.gh import GhFailed, Unparsed, gh_reason
    from orch.pr import pr_lines_by_prefix
    from orch.standing import STANDING_SYNC_LABEL, standing_sync_request
    from orch.trust import trust_filter_prs

    if not table:
        return
    prs: List[str] = []
    reason = ""
    try:
        raw = gh.prs_open_mergeability()
    except GhFailed as failed:
        reason = gh_reason(failed.stderr)
    else:
        try:
            prs = trust_filter_prs("the open PRs", raw)
        except Unparsed:
            reason = "the open PRs could not be read: a malformed line"
    for issue, running, sync, human in table:
        if (running, sync, human) != ("0", "0", "0"):
            continue
        if reason:
            warn("could not read the PR of issue #%s: %s - sync detection skips it"
                 % (issue, reason))
            continue
        prefix = branch_name_flow(issue, "")
        lines = pr_lines_by_prefix(prs, prefix)
        if not lines:
            continue
        if len(lines) > 1:
            warn("issue #%s has %d open PRs from a branch starting %s - sync detection skips it"
                 % (issue, len(lines), prefix))
            continue
        if (lines[0].split("\t") + ["", ""])[2] != "CONFLICTING":
            continue
        failed_why = standing_sync_request(gh, issue)
        if failed_why:
            warn("could not add %s to issue #%s: %s - sync detection skips it"
                 % (STANDING_SYNC_LABEL, issue, failed_why))


# How long a housekeeping run holds: the next runs once the stamp is older.
HOUSEKEEPING_EVERY = 3600


def housekeeping(ap: Autopilot, main: str) -> None:
    """The tick's hourly housekeeping, bash autopilot_housekeeping. The
    housekeeping stamp (<autopilot dir>/housekeeping, the epoch of the last
    run) gates it: a missing stamp, one that does not parse as an epoch,
    one dated in the future and one more than an hour old each run it. The
    stamp is written first; when it cannot be, the step warns and is
    skipped. The session logs are pruned, a failure warned and never
    failing the step; then the finished sweep /orchestrator:finish runs, its
    report on stderr, a failed sweep warned and never failing the step."""
    from orch import liveness
    from orch.side_checkout import finished_sweep

    stamp = autopilot_dir(main) + "/housekeeping"
    now = int(ap.clock())
    text = read_text(stamp) or ""
    if is_positive_int(text) and int(text) <= now and now - int(text) <= HOUSEKEEPING_EVERY:
        return
    if not file_write_atomic(stamp, "%d\n" % now):
        warn("could not write the housekeeping stamp %s: housekeeping is skipped" % stamp)
        return
    liveness.logs_prune(main, ap.clock())
    finished_sweep(ap.gh_of(), ap.git, ap.env, ap.root, clock=ap.clock)


# --- pickup ---------------------------------------------------------------------


def rank(phase: str) -> int:
    """The pickup rank of a session's phase word <phase>, lowest first,
    bash autopilot_rank: a sync request 0, then the phases in reverse order
    of the phase table (review 1, implement 2, spec 3), the phase furthest
    along first. done is not picked up and has no rank of its own."""
    from orch.handoff import PHASES
    from orch.standing import STANDING_SYNC_PHASE

    if phase == STANDING_SYNC_PHASE:
        return 0
    live = [p for p in PHASES if p != "done"]
    return len(live) - live.index(phase) if phase in live else len(live) + 1


def flow_ranked(gh) -> List[Tuple[str, str]]:
    """The tick's one listing of its flow issues, bash autopilot_flow_ranked:
    the open issues carrying any live phase label (every phase but done) or
    orch:sync, listed once, each row's Standing read from the row with no
    per-issue read, the unpickable dropped and the rest ranked - (issue,
    session phase word) by rank, then oldest first. Dies when the listing
    fails."""
    from orch.gh import GhFailed, any_labels_phrase, gh_reason
    from orch.handoff import PHASES
    from orch.standing import STANDING_SYNC_LABEL, phase_label, standing_of

    labels = [phase_label(p) for p in PHASES if p != "done"] + [STANDING_SYNC_LABEL]
    try:
        rows = gh.issues_any_labelled_rows(*labels)
    except GhFailed as failed:
        die("could not list the issues labelled %s: %s"
            % (any_labels_phrase(labels), gh_reason(failed.stderr)))
    ranked = []
    for row in rows:
        standing = standing_of(row.state, row.labels)
        if standing.pickable():
            phase = standing.session_phase()
            ranked.append((rank(phase), row.number, phase))
    return [(str(n), phase) for _, n, phase in sorted(ranked)]


class PickupStop(Exception):
    """A pickup step that failed or refused: the stop's <kind> (refusal or
    failure) and its text."""

    def __init__(self, kind: str, text: str) -> None:
        super().__init__(text)
        self.kind = kind
        self.text = text


def settled(kind: str, detail: str, code: int, err: str) -> None:
    """The tail of a captured step that exited <code> with the stderr
    <err>, bash autopilot_pickup_settle: a success passes every stderr line
    on; a failure raises PickupStop(<kind>, "<detail>: <reason>"), the
    reason taken by pickup_reason's rule."""
    if code == 0:
        stderr_write(err)
        return
    raise PickupStop(kind, "%s: %s" % (detail, pickup_reason(err)))


def contained(kind: str, detail: str, call: Callable[[], object]) -> object:
    """Runs the in-process step <call> contained, bash
    autopilot_pickup_contained: its stdout dropped, its stderr captured, a
    death in it failing only the step (settled). Its answer."""

    with contextlib.redirect_stdout(io.StringIO()):
        answer, err, code = capture(call)
    settled(kind, detail, code, err)
    return answer


def orch_in(ap: Autopilot, side: str, kind: str, detail: str, *args: str) -> None:
    """The step running `orch.sh <args>` as a child in the side checkout
    <side> under ORCH_AUTOPILOT=1, bash autopilot_orch_in: stdout dropped,
    stderr captured for the failure's reason (settled)."""
    try:
        err_file = tempfile.TemporaryFile()
    except OSError:
        settled(kind, detail, 1, "could not create a temp file for the command's stderr\n")
        return
    with err_file:
        code = started(ap, [orch_sh(), *args], cwd=side, env=dict(ap.env, ORCH_AUTOPILOT="1"),
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err_file)
        err_file.seek(0)
        err = err_file.read().decode("utf-8", "surrogateescape")
    settled(kind, detail, code, err)


# The Decisions a hand-labelled issue's minimal plan gives.
MINIMAL_PLAN_DECISION = ("This issue was adopted to be reviewed as it stands: no spec was"
                         " written for it.")


def minimal_plan(ap: Autopilot) -> str:
    """The plan a hand-labelled issue gets, bash autopilot_minimal_plan: the
    repo's Rounds and Budget, a Decision saying the issue is reviewed as it
    stands, and None elsewhere."""
    from orch.flow_state import flow_state_file
    from orch.handoff import handoff_required

    rounds = ap.setting("rounds")[0]
    budget = ap.setting("budget")[0]
    text = ""
    for heading in handoff_required("01-plan.md", flow_state_file(ap.root)):
        text += "%s\n\n%s\n\n" % (
            heading, MINIMAL_PLAN_DECISION if heading == "## Decisions" else "None")
    return text + "## Autopilot\n\nRounds: %s\nBudget: %s\n" % (rounds, budget)


def post_minimal_plan(ap: Autopilot, gh, issue: str) -> None:
    """Posts the minimal plan comment when issue #<issue> has no plan
    comment, bash autopilot_post_minimal_plan. Dies, the reason on stderr,
    where the comments cannot be read, the plan does not validate or its
    post fails."""
    from orch.flow_state import flow_state_file
    from orch.handoff import handoff_check, handoff_comment_post
    from orch.issue_timeline import timeline_handoff, timeline_read_or_die

    entries = timeline_read_or_die(gh, issue)
    if timeline_handoff(entries, "01-plan") is not None:
        return
    unmade = "could not create a temp file"
    with temp_text_file(minimal_plan(ap), unmade, unmade) as path:
        with contextlib.redirect_stdout(sys.stderr):
            status = handoff_check(path, flow_state_file(ap.root), ap.env, "", "01-plan.md",
                                   "autopilot")
        if status != 0:
            stderr_write("the minimal plan does not validate\n")
            raise SystemExit(1)
        if not handoff_comment_post(gh, issue, "01-plan", path):
            raise SystemExit(1)


def pickup_trust(gh, issue: str) -> None:
    """Pickup's first step, before any side checkout, init or plan comment,
    so it runs before every phase: an untrusted issue is a refusal naming
    the writer and what they last wrote; a failed read is a failure naming
    the read - it fails closed."""
    from orch.gh import GhFailed, gh_reason
    from orch.trust import issue_check, writer_text

    try:
        untrusted = issue_check(gh, int(issue))
    except GhFailed as failed:
        raise PickupStop("failure", "step trust read failed: " + gh_reason(failed.stderr))
    if untrusted is not None:
        raise PickupStop("refusal", writer_text("the issue", untrusted) + " - an owner, member"
                         " or collaborator must edit it before autopilot runs on it")


def pickup_side_add(ap: Autopilot, gh, main: str, issue: str) -> str:
    """The side checkout added for issue #<issue>, which has none: its
    title read, then side-checkout add under the first free name of its
    short slug (side_checkout_free_slug), add's report passed on to stderr.
    Its path."""
    from orch.gh import GhFailed, gh_reason
    from orch.side_checkout import side_checkout_add, side_checkout_free_slug

    detail = "step side-checkout add failed"
    try:
        title, _ = gh.issue_title_labels(int(issue))
    except GhFailed as failed:
        raise PickupStop("failure", "%s: could not read the issue's title: %s"
                         % (detail, gh_reason(failed.stderr)))
    slug = side_checkout_free_slug(main, title, issue)
    return str(contained("failure", detail, lambda: side_checkout_add(
        [slug, "--issue", issue], gh, ap.git, ap.env, ap.root, clock=ap.clock)))


def pickup_steps(ap: Autopilot, gh, main: str, issue: str, phase: str, limited: bool) -> None:
    """Pickup's steps in order, up to the session's start, bash
    autopilot_pickup_steps: the trust check, the side checkout - added when
    the issue has none - init where it holds no flow, the plan comment, the
    recorded phase, a redo where the label stepped back one phase, then
    begin. A sync request adds no side checkout, runs no init, posts no plan
    comment and runs no redo, and wants its side checkout at done. The
    first step that fails or refuses raises PickupStop."""
    from orch.checkout import checkout_has_flow
    from orch.flow_state import flow_state_file, flow_state_get_many
    from orch.side_checkout import side_checkout_for_issue
    from orch.standing import (STANDING_SYNC_PHASE, phase_label, redo_phase, redo_rule,
                               standing_begin)

    sync = phase == STANDING_SYNC_PHASE
    pickup_trust(gh, issue)
    side = side_checkout_for_issue(ap.git, issue)
    if sync:
        if side is None:
            raise PickupStop("refusal", "no side checkout on this host holds issue #%s - run %s"
                             " where it lives" % (issue, plugin_cmd(ap.env, "sync",
                                                                     "the orch-sync skill")))
    else:
        if side is None:
            side = pickup_side_add(ap, gh, main, issue)
        if not checkout_has_flow(side):
            orch_in(ap, side, "failure", "step init failed",
                    "init", os.path.basename(side), "--issue", issue)
        contained("failure", "step minimal plan comment failed",
                  lambda: post_minimal_plan(ap, gh, issue))
    values = flow_state_get_many(flow_state_file(side), ["phase"])
    if values is None:
        raise PickupStop("failure", "step reading the recorded phase failed: state.json in %s"
                         " cannot be read - run orch.sh doctor --flow" % side)
    recorded = values["phase"]
    if sync:
        if recorded and recorded != "done":
            raise PickupStop("refusal", "the issue carries a sync request, but its side checkout"
                             " records phase %s, not done" % recorded)
    elif recorded != phase:
        redo = redo_phase(phase, recorded)
        if redo is None:
            raise PickupStop("refusal", "the issue is labelled %s, but its side checkout last"
                             " moved to phase %s - only %s is a redo"
                             % (phase_label(phase), recorded, redo_rule()))
        orch_in(ap, side, "refusal", "redo %s refused" % redo, "redo", redo)
    reason = standing_begin(gh, issue, limited)
    if reason:
        raise PickupStop("failure", reason)


def spawn_run(ap: Autopilot, main: str, issue: str) -> None:
    """Starts `orch.sh autopilot run <issue>` detached from the main
    checkout <main>, bash autopilot_spawn_run: in a new session, so neither
    the terminal's hangup nor a Ctrl-C at the watch reaches it, stdin from
    /dev/null, stdout and stderr dropped. ORCH_AUTOPILOT_FOREGROUND=1, set
    by tests, starts it the same way and waits for it. A run the starter
    cannot start is ignored in either mode: the claim is left for a later
    tick's stale cleanup."""
    try:
        child = ap.starter([orch_sh(), "autopilot", "run", issue], cwd=main, env=dict(ap.env),
                           start_new_session=True, stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return
    if ap.env.get("ORCH_AUTOPILOT_FOREGROUND", "") == "1":
        child.wait()


def pickup(ap: Autopilot, gh, main: str, issue: str, phase: str, limited: bool) -> None:
    """Steps 2 to 5 of a tick for the claimed issue #<issue>, bash
    autopilot_pickup. A refusal or a failed step ends in one stop and the
    tick goes on; a stop that cannot land is contained (stop_contained) and
    the claim stays held for a later tick's stale cleanup. A step that
    failed on a GitHub API rate limit - a GitHub pause holds once it has
    failed - only deletes the claim ref (no stop, no label, nothing
    counted); if that fails the claim stays held for stale cleanup. Past
    every step, the run starts."""
    from orch.gh import GhFailed

    try:
        pickup_steps(ap, gh, main, issue, phase, limited)
    except PickupStop as stop:
        if github_paused(ap):
            try:
                gh.claim_delete(int(issue))
            except GhFailed:
                warn("could not delete the claim ref on issue #%s; it stays held for stale"
                     " cleanup" % issue)
            return
        stop_contained(ap, issue, "%s: %s; a later tick's stale cleanup stops it"
                       % (stop.kind, stop.text), stop.kind, phase, stop.text)
        return
    spawn_run(ap, main, issue)


def tick_verb(ap: Autopilot) -> int:
    """`autopilot tick`: one pass of the watcher, bash autopilot_tick, after
    the gate, ORCH_AUTOPILOT_TICK=1 set for all it starts, run from the main
    checkout. In order: the GitHub limit pause check (while it holds the
    tick ends there, making no GitHub call, not even closing merged PRs),
    the early-pause quota read, the labels, the one read of the claims on
    origin and the stale claims released from it, one read of the done
    issues, the merged-PR close (which needs no session, so the usage and
    early pauses never hold it), the three limit-pause checks (usage, core,
    graphql), the hourly housekeeping, sync detection when auto-sync is
    true, from the done table less the issues the close closed, then
    Pickup. One listing of the flow issues ranks them (flow_ranked); a
    phase is claimed while the claim count - the claims read less those
    cleanup released - is below the cap, a sync request while it is below
    the cap plus the sync slots (half the cap, rounded down), and the first
    phase issue the cap leaves no room for ends the loop. Each ranked issue
    the cap leaves room for is read once, directly, just before its claim:
    one no longer pickable, or at another phase than its row, is skipped
    silently, and the pickup acts on that read's limited flag. A failed
    read, or a claim create that fails for a reason other than a lost race,
    stops the tick, naming it. The tick ends after stale cleanup, after
    housekeeping and after any pickup that leave a GitHub pause holding."""
    from orch import liveness
    from orch.checkout import main_checkout_or_die
    from orch.standing import (STANDING_SYNC_PHASE, claims_read_or_die, standing_claim,
                               standing_read)

    gate(ap)
    # Exported, as bash's, to every child; the gh adapter's limit handling
    # reads it to record a GitHub limit the tick meets.
    ap.env["ORCH_AUTOPILOT_TICK"] = "1"  # type: ignore[index]
    # Read first, as bash reads them: a bad value dies before any GitHub
    # call.
    cap = int(ap.setting("cap")[0])
    auto_sync, _ = ap.setting("auto-sync")
    main = main_checkout_or_die(ap.git)
    try:
        os.chdir(main)
    except OSError:
        die("could not enter the main checkout " + main)
    if pause_until(ap, main, "github"):
        return 0
    reserve = int(ap.setting("github-reserve")[0])
    gh = ap.gh_of()
    github_early(ap, gh, main, reserve)
    labels_ensure(gh)
    claims = claims_read_or_die(gh)
    # The claim count is the read's claims less those cleanup released.
    count = len(claims) - cleanup_stale(ap, main, claims)
    if pause_until(ap, main, "github"):
        return 0
    table = close_missed(ap, gh, done_read(gh))
    if pause_until(ap, main):
        return 0
    # A reserve of 0 turns the early pause off, a recorded one included.
    if reserve > 0 and (pause_until(ap, main, "core") or pause_until(ap, main, "graphql")):
        return 0
    housekeeping(ap, main)
    if pause_until(ap, main, "github"):
        return 0
    if auto_sync == "true":
        sync_detect(gh, table)
    slots = cap // 2
    pid = os.getpid()
    for issue, phase in flow_ranked(gh):
        sync = phase == STANDING_SYNC_PHASE
        if count >= (cap + slots if sync else cap):
            if sync:
                continue
            break
        # The listing may be served late: the issue itself is read, once,
        # before the claim. One no longer pickable, or at another phase, is
        # skipped.
        standing, reason = standing_read(gh, int(issue))
        if standing is None:
            die("could not read issue #%s: %s" % (issue, reason))
        if not standing.pickable() or standing.session_phase() != phase:
            continue
        code, reason = standing_claim(gh, issue, phase, pid, ap.env, ap.clock)
        if code == 2:
            continue
        if code:
            die("could not claim issue #%s: %s - the tick stops" % (issue, reason))
        liveness.tick_begin(main, issue, pid, ap.env)
        count += 1
        pickup(ap, gh, main, issue, phase, standing.limited)
        if pause_until(ap, main, "github"):
            return 0
    return 0


# --- run ------------------------------------------------------------------------

# The tools a headless phase session gets: those the plugin's skills and
# agents use.
AUTOPILOT_TOOLS = "Agent,Skill,Bash,Read,Edit,Write,Grep,Glob,SendMessage"
# Its system prompt addition: it is told it is headless, as print mode turns
# AskUserQuestion off and a question asked in chat is never answered.
AUTOPILOT_SYSTEM_PROMPT = (
    "You are a headless orchestrator autopilot session: no human reads this conversation, and"
    " no tool asks one. Never end your turn on a question. Where a skill offers an autopilot"
    " branch (`orch.sh autopilot active` exits 0, which it does in this session), take that"
    " branch. Where a decision truly needs the human, post it with `orch.sh autopilot ask"
    " <phase> <file>` and stop. When an `orch:` message says the GitHub API rate limit was"
    " reached, end your turn at once: do not retry or wait, the watcher picks the work up after"
    " the reset.")
# Its settings: no bundled skills, and no plugin-authoring, a built-in plugin
# that disableBundledSkills leaves listed.
AUTOPILOT_SETTINGS = '{"disableBundledSkills":true,"enabledPlugins":{"plugin-authoring@builtin":false}}'
# How long, in ms, print mode waits for background tasks after a session's
# last turn: a ticket subagent outlives its 10-minute default, and a finite
# ceiling (2 hours) still ends a hung session, which then goes through the
# existing failure handling. Not 0: nothing else limits a session, so a hung
# subagent would hold its claim forever.
AUTOPILOT_BG_WAIT_MS = 7200000
# The prompts of a phase session and of a sync request's session.
PHASE_PROMPT = ("Run the orchestrator:orch-flow skill's Next phase in this checkout: do the phase"
                " it names, and stop when the phase is finished.")
SYNC_PROMPT = ("Run the orchestrator:orch-sync skill's autopilot branch in this checkout: sync the"
               " branch with its base, and stop when the sync is finished.")

AUTOPILOT_STOP_ATTEMPTS = 3
AUTOPILOT_BACKSTOP_PREFIX = ("autopilot run: the stop chain failed after %d attempts - "
                             % AUTOPILOT_STOP_ATTEMPTS)


def mode_require(ap: Autopilot) -> str:
    """The permission mode, dying, naming the key and its remedy, when none
    is set - bash autopilot_mode_require."""
    mode, source = ap.setting("permission-mode")
    if source == "unset":
        die("%spermission-mode is not set - choose how headless sessions run (git config"
            " %spermission-mode <%s>)" % (SETTING_PREFIX, SETTING_PREFIX, "|".join(AUTOPILOT_MODES)))
    return mode


def recorded_of(side: str, key: str) -> str:
    """<key>'s value in the flow state of the side checkout <side>; dies
    when it cannot be read - bash autopilot_read_die."""
    from orch.flow_state import flow_state_file, flow_state_get_many

    values = flow_state_get_many(flow_state_file(side), [key])
    if values is None:
        die("could not read the recorded %s of %s - state.json cannot be read" % (key, side))
    return values[key]


def pickup_reason(err: str) -> str:
    """A failed step's reason from its stderr <err>: its last `orch: ` line,
    kept whole, else its last non-empty line, else "the step gave no
    reason". Every other line goes on to stderr - bash
    autopilot_pickup_reason."""
    lines = lines_of(err)
    picks = [i for i, line in enumerate(lines) if line.startswith("orch: ")] or [
        i for i, line in enumerate(lines) if line]
    if not picks:
        return "the step gave no reason"
    stderr_write("".join(line + "\n" for i, line in enumerate(lines) if i != picks[-1]))
    return lines[picks[-1]]


def stop_attempts(ap: Autopilot, issue: str, log: str, closing: str,
                  transition: Callable[..., None]) -> int:
    """The wrapper's stop chain: <transition>, given the issue's Chain, run
    up to AUTOPILOT_STOP_ATTEMPTS times, a death ending only the attempt;
    the claim and the run record are kept throughout. The attempts share one
    landed record, so each resumes from the first write that did not land.
    Before the second and third it waits for a GitHub pause when one holds,
    else 60, then 300 seconds (github_pause_wait). 0 when an attempt landed;
    when the last fails, 1, one backstop line written to <log> - the stop's
    kind, its first line and <closing>, the clause that ends it - for stale
    cleanup to quote."""
    from orch.standing import Chain

    try:
        handle, record = tempfile.mkstemp()
        os.close(handle)
    except OSError:
        die("could not create a temp file for the stop chain's state")
    try:
        for attempt in range(1, AUTOPILOT_STOP_ATTEMPTS + 1):
            if attempt > 1:
                github_pause_wait(ap, 60 if attempt == 2 else 300)
            chain = Chain(ap.gh_of(), issue, state_file=record)
            if subshell(lambda: transition(chain)) == 0:
                return 0
        line = Chain(ap.gh_of(), issue, state_file=record).get("stop")
    finally:
        rm_f(record)
    kind, _, first = (line or "stop\tno stop text was built").partition("\t")
    log_append(log, "%s%s: %s; %s\n" % (AUTOPILOT_BACKSTOP_PREFIX, kind, first, closing))
    return 1


def claim_release_only(ap: Autopilot, main: str, issue: str, fallback: str,
                       closing: str) -> None:
    """The claim release after a read that met a GitHub limit, no session
    having run. The log is named by the claim's own phase, else <fallback>.
    It waits out the GitHub pause, then releases the claim through
    stop_attempts with <closing> ending its backstop line; the chain's
    failure is ignored."""
    from orch import liveness
    from orch.standing import claim_of, claims_read, standing_claim_release

    claims, _ = claims_read(ap.gh_of())
    claim = claim_of(claims or [], issue)
    phase = claim.phase if claim is not None and claim.phase else fallback
    log = liveness.log_path(main, issue, phase, ap.clock)
    github_pause_wait(ap)
    stop_attempts(ap, issue, log, closing, standing_claim_release)


def review_budget_record(ap: Autopilot, side: str) -> None:
    """Records the plan's Budget as the side checkout <side>'s review
    budget: the plan read for that checkout's issue, as `autopilot budget`
    run there reads it, then written with `state set budget`'s refusals.
    Dies with the step's own reason."""
    from orch.flow_state import flow_state_file, require_state_exists, state_write_many

    budget = plan_number(ap, side, "Budget")
    state_file = flow_state_file(side)
    require_state_exists(state_file, ap.env)
    state_write_many(state_file, [("budget", str(budget))], ap.clock)


def pools_read(gh) -> Optional[str]:
    """GitHub's core and graphql pools, one per line - the one quiet read,
    never retried nor handled; None when it fails or is empty."""
    from orch.gh import GhFailed

    try:
        pools = gh.limits.pools()
    except GhFailed:
        return None
    return pools or None


def github_usage(before: Optional[str], after: Optional[str]) -> Optional[str]:
    """The change in core and graphql usage from the pools <before> to the
    pools <after> as one line, "core <n>, graphql <m>"; None when either
    read failed or names no such pool. A pool that reset meanwhile counts
    as no usage."""
    if not before or not after:
        return None

    def used(pools: str, pool: str) -> Optional[int]:
        for line in pools.split("\n"):
            fields = line.split()
            if len(fields) >= 3 and fields[0] == pool:
                if not (plain_number(fields[1]) and plain_number(fields[2])):
                    return None
                return int(fields[2]) - int(fields[1])
        return None

    parts = []
    for pool in ("core", "graphql"):
        was, now = used(before, pool), used(after, pool)
        if was is None or now is None:
            return None
        parts.append("%s %d" % (pool, max(0, now - was)))
    return ", ".join(parts)


def started(ap: Autopilot, argv: List[str], hold: Optional[Callable[[object], None]] = None,
            **how) -> int:
    """<argv> started through the process starter, handed to <hold> once
    started when one is given, and waited for: its exit status as the shell
    reports it - its exit code, 128 plus the signal that killed it, and 127,
    or 126, when it cannot be started, as for a command the shell could not
    find or run."""
    try:
        child = ap.starter(argv, **how)
    except FileNotFoundError:
        return 127
    except OSError:
        return 126
    if hold is not None:
        hold(child)
    return exit_status(child.wait())


def session_end(ap: Autopilot, main: str, issue: str, phase: str, log: str, rc: int,
                mine) -> int:
    """What a run does once its session has exited <rc>, bash
    autopilot_session_end: the claim <mine> held before the session, still
    held (or, with none before, any claim now), decides a stop; a released
    one is no stop, only a note. The limit pause is the reset the session
    named, or one hour on; the early pause is the five-hour window's
    resetsAt when its utilization is 0.9 or more, whatever the outcome; the
    usage pause file is extended once, with the later. A hit file naming a
    reset, with no usage limit, is a GitHub limit stop extending the GitHub
    pause. Every stop goes through stop_attempts: 1 when the chain gives up,
    the claim held. Dies, before any write, when the claims cannot be
    read."""
    from orch import liveness
    from orch.session_log import session_log_read
    from orch.standing import (claim_of, claims_read_or_die, standing_limit_stop,
                               standing_stop)

    claim = claim_of(claims_read_or_die(ap.gh_of()), issue)
    held = claim is not None and (mine is None or claim == mine)
    now = ap.clock()
    said = session_log_read(log, now)
    hit_epoch = iso_epoch(liveness.hit_take(main, issue).rstrip("\n")) or 0
    # A hit file from before the write cap may name a reset past the hour.
    gh_reset = github_reset_cap(hit_epoch, now) if hit_epoch > 0 else 0
    outcome, limit = "failure", None
    if not held:
        outcome = "released"
    elif said.limited:
        outcome, limit = "limited", said.reset if said.reset is not None else int(now) + 3600
    elif hit_epoch > 0:
        outcome = "github"
    # One write: the later of the two pauses.
    pause = said.early
    if limit is not None and (pause is None or limit > pause):
        pause = limit
    if pause is not None:
        pause_extend(usage_pause_file(main), pause, log)
    if outcome == "github":
        pause_extend(github_pause_file(main), gh_reset, log, "GitHub")
    closing = "the session exited with code %d" % rc
    if outcome == "released":
        note = "autopilot run: issue #%s's session exited %d with its claim released" % (issue, rc)
        stdout_write(note + "\n")
        log_append(log, note + "\n")
        return 0
    if outcome == "limited":
        reset = epoch_iso(said.reset) if said.reset is not None else ""
        return stop_attempts(ap, issue, log, closing, lambda chain: standing_limit_stop(
            chain, phase, reset, epoch_iso(limit), rc, log))
    if outcome == "github":
        return stop_attempts(ap, issue, log, closing, lambda chain: standing_limit_stop(
            chain, phase, epoch_iso(gh_reset), epoch_iso(gh_reset), rc, log, "github"))
    detail = closing + "; "
    if said.reply:
        detail += "it ended on: *%s*; " % said.reply
    return stop_attempts(ap, issue, log, closing, lambda chain: standing_stop(
        chain, "failure", phase, detail + "log: " + log))


def run_verb(ap: Autopilot, issue: str) -> int:
    """`autopilot run <issue>`: the session wrapper a tick starts. Runs the
    headless session in the issue's side checkout, its output in the session
    log, under a run record made before the start-up read and removed on
    exit while it still names this run; then stops the session's
    verification runs, writes the GitHub usage line and hands over to
    session_end. A start-up read, or a first-loop review's budget record,
    that met a GitHub limit only releases the claim."""
    from orch import liveness
    from orch.checkout import main_checkout_or_die
    from orch.side_checkout import side_checkout_for_issue

    if not plain_number(issue):
        die("issue must be a plain issue number, got: " + issue)
    mode = mode_require(ap)
    main = main_checkout_or_die(ap.git)
    side = side_checkout_for_issue(ap.git, issue)
    if side is None:
        die("no side checkout records issue #" + issue)
    recorded = recorded_of(side, "phase")
    # Marked before the start-up read: a GitHub limit it meets writes the
    # pause. Exported, as bash's, to every child.
    ap.env["ORCH_AUTOPILOT_RUN"] = "1"  # type: ignore[index]
    pid = os.getpid()
    # The run record is made once, before the start-up read, so stale
    # cleanup sees a live session throughout.
    if not liveness.run_begin(main, issue, pid, ap.env):
        return 1
    try:
        return run_session(ap, main, side, issue, recorded, mode)
    finally:
        liveness.run_end(main, issue, pid, ap.env)


def run_session(ap: Autopilot, main: str, side: str, issue: str, recorded: str,
                mode: str) -> int:
    """run_verb's part under the run record."""
    from orch import liveness
    from orch.gh import gh_die
    from orch.standing import claim_of, claims_read_or_die, standing_read, standing_stop

    gh = ap.gh_of()
    standing, reason = standing_read(gh, int(issue))
    if standing is None:
        # A read that met a GitHub limit (a pause holds once it has failed)
        # runs no session and makes no stop: only the claim is released.
        if github_paused(ap):
            claim_release_only(ap, main, issue, recorded,
                               "no session ran: the start-up read met a GitHub limit")
            return 0
        gh_die("read issue #" + issue, reason)
    prompt, phase = PHASE_PROMPT, recorded
    # A sync request is told by orch:sync on a done issue; its phase word is
    # sync.
    if recorded == "done" and standing.is_sync():
        prompt, phase = SYNC_PROMPT, standing.session_phase()
    hit = liveness.hit_path(main, issue)
    # The claim this run was started for: a session that releases it may
    # exit after the next phase's claim is made, and that one is not this
    # run's to fail.
    mine = claim_of(claims_read_or_die(gh), issue)
    log = liveness.log_path(main, issue, phase, ap.clock)
    if phase == "review" and recorded_of(side, "iteration") == "0":
        # A first-loop review session is not asked its budget: the plan's is
        # recorded, over any left by a loop before a redo.
        _, err, code = capture(lambda: review_budget_record(ap, side))
        if code:
            if github_paused(ap):
                claim_release_only(ap, main, issue, phase, "no session ran: the first-loop"
                                   " review's budget record met a GitHub limit")
                return 0
            detail = ("could not record the plan's Budget as the review budget: "
                      + pickup_reason(err))
            stop_attempts(ap, issue, log, "no session ran", lambda chain: standing_stop(
                chain, "failure", "review", detail))
            return 0
        stderr_write(err)
    flags: List[str] = []
    for name in ("model", "effort"):
        value, source = ap.setting(name)
        if source != "unset" and value != "inherit":
            flags += ["--" + name, value]
    before = pools_read(gh)
    launcher = ap.env.get("ORCH_AUTOPILOT_LAUNCHER", "") or "claude"
    session_env = dict(ap.env, ORCH_AUTOPILOT="1", ORCH_AUTOPILOT_HIT_FILE=hit,
                       CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS="1",
                       CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=str(AUTOPILOT_BG_WAIT_MS))
    argv = [launcher, "-p", prompt, "--permission-mode", mode, *flags,
            "--tools", AUTOPILOT_TOOLS, "--settings", AUTOPILOT_SETTINGS,
            "--strict-mcp-config", "--exclude-dynamic-system-prompt-sections",
            "--append-system-prompt", AUTOPILOT_SYSTEM_PROMPT,
            "--output-format", "stream-json", "--verbose"]
    try:
        with open(log, "wb") as out:
            rc = started(ap, argv, cwd=side, env=session_env, stdin=subprocess.DEVNULL,
                         stdout=out, stderr=subprocess.STDOUT)
    except OSError:
        rc = 1
    # The session's verification runs end with it. A child process, so the
    # stop's one failing exit (a group surviving KILL) never ends this
    # wrapper; a failed stop is a line in the log and changes nothing else.
    try:
        with open(log, "ab") as err_log:
            stopped = started(ap, [orch_sh(), "verification", "stop", side], cwd=side,
                              env=dict(ap.env, ORCH_LOAD_TRACE=""), stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=err_log)
    except OSError:
        stopped = 1
    if stopped != 0:
        log_append(log, "autopilot run: could not stop every verification run of %s\n" % side)
    usage = github_usage(before, pools_read(gh) if before else None)
    if usage is not None:
        log_append(log, "autopilot run: GitHub API usage this session: %s\n" % usage)
    return session_end(ap, main, issue, phase, log, rc, mine)


# Each verb that takes a fixed number of arguments: that number, what its
# usage line names after the verb, and the function called with the run and
# its arguments.
VERBS: Mapping[str, Tuple[int, str, Callable[..., int]]] = {
    "settings": (0, "", settings_verb),
    "show": (0, "", show_verb),
    "active": (0, "", active_verb),
    "rounds": (0, "", lambda ap: plan_value(ap, "Rounds")),
    "budget": (0, "", lambda ap: plan_value(ap, "Budget")),
    "start": (2, " <issue> <plan-file>", start_verb),
    "tick": (0, "", tick_verb),
    "run": (1, " <issue>", run_verb),
    "questions": (0, "", questions_verb),
    "reply": (2, " <issue> <file>", reply_verb),
    "resume": (1, " <issue>", resume_verb),
    "sync": (1, " <issue>", sync_verb),
    "sync-finish": (0, "", sync_finish_verb),
    "sync-dropped": (1, " <file>", sync_dropped_verb),
    "sync-fail": (1, " <reason>", sync_fail_verb),
    "reenter": (2, " <phase> <file>", reenter_verb),
    "ask": (2, " <phase> <file>", ask_verb),
    "answer": (2, " <phase> <file>", answer_verb),
}


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    clock: Callable[[], float] = time.time,
    starter: Callable[..., object] = subprocess.Popen,
    sleep: Callable[[float], None] = time.sleep,
) -> int:
    """`orch.sh autopilot <op> [<arg>...]`: the real adapters, the
    process's environment, the system clock and its sleep, and
    subprocess.Popen as the process starter unless a test hands in others.
    Outside a checkout it dies first, as orch.sh does, whatever the op."""
    from orch.gh import adapter_of

    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    pin = RepoPin(env, git)
    ap = Autopilot(root, git, env, pin, adapter_of(gh, env, pin), clock, starter, sleep)
    return dispatch(ap, argv[0] if argv else "", argv[1:])
