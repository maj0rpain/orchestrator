"""orch.sh's autopilot noun (ADR-0067), being converted from
scripts/orch/autopilot.sh verb group by verb group; orch.sh still runs the
bash noun until every verb is here. run(argv) takes the arguments after
`autopilot`, as orch.sh will hand them on, and returns the exit code; every
error dies through orch.common.die. It dispatches every verb, refusing an
unknown op and each verb's arguments with bash's messages, and runs those
converted so far - `settings`, `show`, `active`, `rounds`, `budget`, `start`,
`candidates`, `watch`, the question, reply and re-entry verbs `questions`,
`reply`, `resume`, `ask`, `answer` and `reenter`, over the Standing module's
transitions, and `run`, the session wrapper a tick starts, with its session
end, the pause files it reads and extends, and the review budget record -
with the bash noun's stdout, exit codes and `orch:` messages, in a plain and
an autopilot (ORCH_AUTOPILOT=1) session. A verb whose body is not yet here is
refused (not_ported).

Beside the noun, the concept every Python noun reads: whether this is an
autopilot session, the plan's `## Autopilot` block, as handoff_report checks
it for 01-plan.md, the UTC timestamps the pause files hold, and the GitHub
limit record the gh adapter's limit handling makes in an autopilot process -
the GitHub limit pause under the main checkout and a session's hit file, in
the format and at the path autopilot.sh reads them (pinned by
tests/github_pause/, ADR-0067).

The gh, handoff, flow-state, standing, trust, filed-finding, liveness and
side-checkout modules the verbs call are imported inside them: each imports
this module's concept part at its own import, so importing them here at the
top would be a cycle; the session-log module is imported with them.
"""
from __future__ import annotations

import calendar
import os
import shutil
import signal
import subprocess
import time
from typing import Callable, Dict, List, Mapping, NoReturn, Optional, Tuple

from orch.agent import autopilot_setting_check, default_plugin_root
from orch.common import (ORCH_DIR_NAME, die, file_write_atomic, is_positive_int, plain_number,
                         read_raw, read_text, rm_f, stderr_write, stdout_write, trim, warn)
from orch.git import Git
from orch.host import host_detect
from orch.repo import REPO_REMEDY, RepoPin, owner_name
from orch.root import checkout_root

# A GitHub pause is never recorded further ahead than this many seconds:
# no GitHub limit names a later reset.
AUTOPILOT_GITHUB_PAUSE_MAX = 3600

ISO_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

# The `## Autopilot` block's keys, in the order its report checks them.
AUTOPILOT_BLOCK_KEYS = ("Rounds", "Budget")


def autopilot_active(env: Mapping[str, str]) -> bool:
    """Whether <env> is an autopilot session's - the one reader of
    ORCH_AUTOPILOT, so no skill reads the variable itself."""
    return env.get("ORCH_AUTOPILOT", "") == "1"


def autopilot_block_values(text: str, key: str) -> List[str]:
    """The value of each `<key>: <value>` line in <text>'s `## Autopilot`
    section, trimmed, in order, as bash autopilot_block_values: a line whose
    value is blank holds none."""
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
    """The plan <text>'s `## Autopilot` block in handoff_report's lines, bash
    autopilot_block_report: `ok ## Autopilot`, or one FAIL line per problem
    with status 1. The block is `Rounds` and `Budget`, each one line holding
    a whole number of 1 or more."""
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
    return time.strftime(ISO_FORMAT, time.gmtime(epoch))


def iso_epoch(text: str) -> Optional[int]:
    """The UTC timestamp <text>, YYYY-MM-DDTHH:MM:SSZ, as epoch seconds, or
    None for a value that does not read - bash autopilot_iso_epoch."""
    try:
        return calendar.timegm(time.strptime(text, ISO_FORMAT))
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
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(epoch_iso(epoch) + "\n")
    except OSError:
        return False
    return True


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
OPS = ("show|settings|active|rounds|budget|start|candidates|tick|watch|run|ask|answer|reenter"
       "|questions|reply|resume|sync|sync-finish|sync-dropped|sync-fail")

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

# Each verb that takes a fixed number of arguments: that number, and what its
# usage line names after the verb.
ARITY = {
    "settings": (0, ""),
    "show": (0, ""),
    "active": (0, ""),
    "rounds": (0, ""),
    "budget": (0, ""),
    "start": (2, " <issue> <plan-file>"),
    "tick": (0, ""),
    "run": (1, " <issue>"),
    "questions": (0, ""),
    "reply": (2, " <issue> <file>"),
    "resume": (1, " <issue>"),
    "sync": (1, " <issue>"),
    "sync-finish": (0, ""),
    "sync-dropped": (1, " <file>"),
    "sync-fail": (1, " <reason>"),
    "reenter": (2, " <phase> <file>"),
    "ask": (2, " <phase> <file>"),
    "answer": (2, " <phase> <file>"),
}

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


def not_ported(op: str) -> NoReturn:
    """The refusal of a verb whose body is not yet converted: the noun is
    not routed through orch.sh until every verb is."""
    die("autopilot %s is not converted to Python yet" % op)


def dispatch(ap: Autopilot, op: str, args: List[str]) -> int:
    """Runs the verb <op> on <args>, its exit code; refuses an unknown op
    and arguments the verb does not take, as bash's cmd_autopilot does."""
    if op in ARITY:
        count, tail = ARITY[op]
        if len(args) != count:
            die("usage: orch.sh autopilot %s%s" % (op, tail))
    elif op == "watch":
        return watch_verb(ap, watch_every(args))
    elif op == "candidates":
        return candidates_verb(ap, *candidates_args(args))
    else:
        die("unknown autopilot op: %s (want %s)" % (op or "<none>", OPS))
    verb = VERBS.get(op)
    if verb is None:
        not_ported(op)
    return verb(ap, *args)


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
    from orch.issue_timeline import timeline_body, timeline_die, timeline_handoff, timeline_read

    issue = require_issue(flow_state_file(root), ap.env)["issue"]
    entries, reason = timeline_read(ap.gh_of(), issue)
    if entries is None:
        timeline_die(issue, reason)
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
    from orch.triage_labels import TriageLabels

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
    from orch.triage_labels import TriageLabels

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
                                     timeline_read, timeline_reentered, timeline_replied)
    from orch.gh import gh_die
    from orch.repo import REPO_REMEDY

    phase_arg(phase, 2)
    issue = flow_issue(ap, 2)
    gh = ap.gh_of()
    if not gh.pin():
        die(REPO_REMEDY, 2)
    entries, reason = timeline_read(gh, issue)
    if entries is None:
        if not reason:
            die("could not read issue #%s's comments" % issue, 2)
        gh_die("read the comments of issue #" + issue, reason, code=2)
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
    from orch.issue_timeline import timeline_die, timeline_question, timeline_read, \
        timeline_replied
    from orch.standing import STANDING_HUMAN_LABEL, standing_human_guard, standing_resume

    if not is_positive_int(issue):
        die("not an issue number: " + issue)
    if not os.path.isfile(path):
        die("reply file not found: " + path)
    if not os.path.getsize(path):
        die("reply file is empty: " + path)
    gh = ap.gh_of()
    standing_human_guard(gh, issue)
    entries, reason = timeline_read(gh, issue)
    if entries is None:
        timeline_die(issue, reason)
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


def questions_verb(ap: Autopilot) -> int:
    """`autopilot questions`: one tab-separated line per open needs-human
    issue carrying a phase label other than orch:done, or sitting at
    orch:done stopped by a sync (phase sync) - the issue, its kind
    (question, replied or stop), the phase, and the URL of the comment the
    kind is about. The newer of the issue's newest question comment and its
    latest stop decides the kind. One line saying so when nothing is listed;
    every read comes first, so a failed one dies printing nothing."""
    from orch.gh import gh_or_die
    from orch.issue_timeline import (timeline_die, timeline_question, timeline_read,
                                     timeline_replied, timeline_stop, timeline_url)
    from orch.standing import STANDING_HUMAN_LABEL, STANDING_SYNC_PHASE, standing_of

    gh = ap.gh_of()
    rows = gh_or_die("list the %s issues" % STANDING_HUMAN_LABEL, gh.issues_labelled_rows,
                     STANDING_HUMAN_LABEL)
    lines = []
    for row in sorted(rows, key=lambda row: row.number):
        standing = standing_of(row.state, row.labels)
        entries, reason = timeline_read(gh, str(row.number))
        if entries is None:
            timeline_die(str(row.number), reason)
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
        /dev/null and stdout dropped, as bash's background job has them, and
        waits for it: its exit status as bash's wait gives it - 128 plus the
        signal that killed it, 127 for an orch.sh that is missing and 126
        for one that cannot be run."""
        try:
            self.tick = self.ap.starter([orch_sh(), "autopilot", "tick"],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        except FileNotFoundError:
            return 127
        except OSError:
            return 126
        code = self.tick.wait()
        self.tick = None
        return code if code >= 0 else 128 - code

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
            try:
                with open(path, "w") as f:
                    f.write(epoch_iso(cut) + "\n")
            except OSError:
                pass
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
    lines = err.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
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
    import tempfile

    from orch.common import subshell
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


def started(ap: Autopilot, argv: List[str], **how) -> int:
    """<argv> started through the process starter and waited for: its exit
    code; 127, or 126, when it cannot be started, as a shell reports a
    command it could not find or run."""
    import errno

    try:
        return ap.starter(argv, **how).wait()
    except OSError as failed:
        return 127 if failed.errno == errno.ENOENT else 126


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
    from orch.common import capture
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


# The verbs taking a fixed number of arguments that are converted, each
# called with the run and its arguments.
VERBS: Mapping[str, Callable[..., int]] = {
    "settings": settings_verb,
    "show": show_verb,
    "active": active_verb,
    "rounds": lambda ap: plan_value(ap, "Rounds"),
    "budget": lambda ap: plan_value(ap, "Budget"),
    "start": start_verb,
    "questions": questions_verb,
    "reply": reply_verb,
    "resume": resume_verb,
    "ask": ask_verb,
    "answer": answer_verb,
    "reenter": reenter_verb,
    "run": run_verb,
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
