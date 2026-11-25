"""orch.sh's agent noun (ADR-0067): per-role model and reasoning effort
settings stored in git config, modeled per host through an immutable
data-driven HostSpec table, plus .junie/agents/ copy-sync."""
from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from orch.common import (
    die,
    exclude_line,
    file_lines,
    lines_of,
    mkdir_p_or_die,
    read_raw,
    rm_f_or_die,
    stdout_write,
    text_file_write,
)
from orch.git import Git
from orch.root import checkout_root

# The verbs, in the unknown-op message's order. docs_lint.sh reads this line
# as the verbs the noun dispatches, so it stays one `OPS = "<verb>|..."` line.
OPS = "set|show|clear|get|sync|roles"

# The roles, in the order show and roles print them. The list lives here alone.
AGENT_ROLES: Tuple[str, ...] = (
    "implementer",
    "lens",
    "reviewer",
    "fixer",
    "closer",
    "resolver",
    "auditor",
)

# The plugin agents' name shapes, as ordered (role, glob) pairs: the first glob
# a name matches gives its role. Each * reads as [a-z]+.
AGENT_NAME_SHAPES: Tuple[Tuple[str, str], ...] = (
    ("implementer", "orch-implementer"),
    ("lens", "orch-lens-*"),
    ("reviewer", "orch-reviewer-*"),
    ("fixer", "orch-fixer"),
    ("closer", "orch-closer"),
    ("resolver", "orch-resolver"),
    ("auditor", "orch-*-auditor"),
)

# Every kind of setting, in canonical order (model, then effort).
AGENT_KINDS: Tuple[str, ...] = ("model", "effort")

# The host meant when no --host flag names one.
AGENT_DEFAULT_HOST = "claude"

# The marker sync puts on the line right after a copy's opening ---, and the
# exclude line that keeps the copies out of git.
AGENT_COPY_MARKER = "# written by orch.sh agent sync"
AGENT_COPY_EXCLUDE = ".junie/agents/orch-*.md"


@dataclass(frozen=True)
class KindRule:
    """Validation rule for one setting kind on one host: either an explicit
    tuple of allowed words, or a full-match regex pattern with its explanatory
    printf note (inherit is always allowed for pattern rules)."""

    allowed: Optional[Tuple[str, ...]] = None
    pattern: Optional[str] = None
    note: Optional[str] = None


@dataclass(frozen=True)
class HostSpec:
    """Immutable specification of one host in the agent host table."""

    name: str
    key_prefix: str
    line_prefix: str
    clear_flag: str
    flag_host: bool
    syncs_copies: bool
    rules: Mapping[str, KindRule]


# The host table, in the order agent show prints hosts: strictly Claude Code
# and Junie. Every verb reads this table rather than branching on host names.
HOST_SPECS: Mapping[str, HostSpec] = MappingProxyType({
    "claude": HostSpec(
        name="claude",
        key_prefix="orchestrator",
        line_prefix="",
        clear_flag="",
        flag_host=False,
        syncs_copies=False,
        rules=MappingProxyType({
            "model": KindRule(allowed=("sonnet", "opus", "haiku", "fable", "inherit")),
            "effort": KindRule(allowed=("low", "medium", "high", "xhigh", "max", "inherit")),
        }),
    ),
    "junie": HostSpec(
        name="junie",
        key_prefix="orchestrator.junie",
        line_prefix="junie ",
        clear_flag=" --host junie",
        flag_host=True,
        syncs_copies=True,
        rules=MappingProxyType({
            "model": KindRule(
                pattern=r"[A-Za-z0-9._:/-]+",
                note=(
                    "inherit or a name matching %s - use the names Junie's"
                    " /model picker and --model flag take; aliases resolve"
                    " unpredictably"
                ),
            ),
            "effort": KindRule(allowed=("low", "medium", "high", "inherit")),
        }),
    ),
})


FLAG_HOSTS: Tuple[str, ...] = tuple(
    name for name, spec in HOST_SPECS.items() if spec.flag_host
)


def default_plugin_root() -> str:
    """The plugin root, resolved from this module's own resolved location so
    symlinked plugin installs still locate agents/orch-*.md."""
    return str(Path(__file__).resolve().parents[3])


def _config_pattern() -> str:
    prefixes = "|".join(re.escape(spec.key_prefix) for spec in HOST_SPECS.values())
    kinds = "|".join(re.escape(kind) for kind in AGENT_KINDS)
    return r"^(%s)\.(%s)\." % (prefixes, kinds)


def agent_key(host: str, kind: str, role: str) -> str:
    """The git config key of the setting for <host>, <kind> and <role>."""
    return "%s.%s.%s" % (HOST_SPECS[host].key_prefix, kind, role)


def agent_allowed(kind: str, value: str, host: str = AGENT_DEFAULT_HOST) -> bool:
    """Whether <value> is allowed for <kind> on <host>."""
    rule = HOST_SPECS[host].rules[kind]
    if rule.pattern is not None:
        return value == "inherit" or re.fullmatch(rule.pattern, value) is not None
    return rule.allowed is not None and value in rule.allowed


def agent_values(kind: str, host: str = AGENT_DEFAULT_HOST) -> str:
    """The allowed values for <kind> on <host> as a|b|c, or the pattern and its
    explanatory note for a pattern-validated key."""
    rule = HOST_SPECS[host].rules[kind]
    if rule.note is not None and rule.pattern is not None:
        return rule.note % rule.pattern
    return "|".join(rule.allowed or ())


def agent_clear_cmd(host: str, kind: str, role: str, scope: str) -> str:
    """The clear command that removes <role>'s <kind> key for <host> at
    <scope> - the remedy for a disallowed stored value."""
    suffix = " --global" if scope == "global" else ""
    return "orch.sh agent clear %s%s --%s%s" % (role, HOST_SPECS[host].clear_flag, kind, suffix)


def agent_host(args: Sequence[str]) -> str:
    """The host named by the first --host flag among <args>, or the default
    host when there is none. Refuses a missing value or any host not in
    FLAG_HOSTS."""
    want = "|".join(FLAG_HOSTS)
    for idx, arg in enumerate(args):
        if arg == "--host":
            if idx + 1 >= len(args):
                die("--host needs a value (want %s)" % want)
            value = args[idx + 1]
            if value not in FLAG_HOSTS:
                die("host %s is not allowed (want %s)" % (value, want))
            return value
    return AGENT_DEFAULT_HOST


def agent_require_role(role: str) -> None:
    """Dies unless <role> is one of AGENT_ROLES."""
    if role not in AGENT_ROLES:
        die("unknown role %s (want %s)" % (role or "<none>", "|".join(AGENT_ROLES)))


class ConfigCache:
    """Scoped git config cache for agent settings: loads local and global keys
    once lazily via git.config_regexp and drops them on write or unset."""

    def __init__(self, git) -> None:
        self.git = git
        self._loaded = False
        self._local: Dict[str, str] = {}
        self._global: Dict[str, str] = {}

    def drop(self) -> None:
        self._loaded = False
        self._local = {}
        self._global = {}

    def load(self) -> None:
        if self._loaded:
            return
        pattern = _config_pattern()
        self._local = self.git.config_regexp("local", pattern)
        self._global = self.git.config_regexp("global", pattern)
        self._loaded = True

    def scoped(self, scope: str, key: str) -> Optional[str]:
        self.load()
        table = self._local if scope == "local" else self._global
        return table.get(key)

    def lookup(self, kind: str, role: str, host: str = AGENT_DEFAULT_HOST) -> Tuple[str, str]:
        """Effective (value, source) for <kind> of <role> on <host>: local,
        then global, else ('inherit', 'inherit'). Never validates."""
        key = agent_key(host, kind, role)
        local_val = self.scoped("local", key)
        if local_val is not None:
            return local_val, "local"
        global_val = self.scoped("global", key)
        if global_val is not None:
            return global_val, "global"
        return "inherit", "inherit"

    def unset(self, scope: str, key: str) -> None:
        """Drops the cache and removes <key> at <scope>; dies naming key and
        scope on any failure other than key-not-set."""
        self.drop()
        if not self.git.config_unset(scope, key):
            die("cannot clear %s at %s scope" % (key, scope))

    def write(self, scope: str, key: str, value: str) -> None:
        """Drops the cache and writes <key> = <value> at <scope>; dies naming
        key and scope on failure."""
        self.drop()
        if not self.git.config_set(scope, key, value):
            die("cannot set %s at %s scope" % (key, scope))


def agent_role_values(cache: ConfigCache, host: str, role: str, sep: str) -> str:
    """<role>'s effective model and effort for <host>, each with its source (a
    disallowed value marked invalid rather than refused), formatted as
    `model <v> (<label>)<sep> effort <v> (<label>)`."""
    parts: List[str] = []
    for kind in AGENT_KINDS:
        value, src = cache.lookup(kind, role, host)
        label = src if agent_allowed(kind, value, host) else "%s, invalid" % src
        parts.append("%s %s (%s)" % (kind, value, label))
    return (sep + " ").join(parts)


def _roles(args: List[str]) -> int:
    if args:
        die("usage: orch.sh agent roles")
    sys.stdout.write("".join(role + "\n" for role in AGENT_ROLES))
    return 0


def _show(args: List[str], cache: ConfigCache) -> int:
    if args:
        die("usage: orch.sh agent show")
    cache.load()
    lines: List[str] = []
    for host, spec in HOST_SPECS.items():
        for role in AGENT_ROLES:
            lines.append("%s%s %s\n" % (spec.line_prefix, role, agent_role_values(cache, host, role, "")))
    stdout_write("".join(lines))
    return 0


def _get(args: List[str], cache: ConfigCache) -> int:
    usage = "usage: orch.sh agent get <role> [--host %s]" % "|".join(FLAG_HOSTS)
    if len(args) == 1 or (2 <= len(args) <= 3 and args[1] == "--host"):
        host = agent_host(args[1:])
        role = args[0]
    else:
        die(usage)
    agent_require_role(role)
    lines: List[str] = []
    for kind in AGENT_KINDS:
        value, src = cache.lookup(kind, role, host)
        if not agent_allowed(kind, value, host):
            key = agent_key(host, kind, role)
            die(
                "%s is %s - not an allowed %s (want %s) - clear it: %s"
                % (key, value, kind, agent_values(kind, host), agent_clear_cmd(host, kind, role, src))
            )
        lines.append("%s %s\n" % (kind, value))
    sys.stdout.write("".join(lines))
    return 0


def agent_shape_ere(glob: str) -> str:
    """The unanchored ERE a name shape's <glob> stands for, each * as [a-z]+."""
    return glob.replace("*", "[a-z]+")


def agent_role_of(name: str) -> Optional[str]:
    """The role a plugin agent's <name> belongs to, or None when no shape
    covers it."""
    for role, glob in AGENT_NAME_SHAPES:
        if re.fullmatch(agent_shape_ere(glob), name) is not None:
            return role
    return None


def agent_copy_marked(path: str) -> bool:
    """Whether <path> carries AGENT_COPY_MARKER on the line right after its
    opening --- and nowhere else. Unreadable files, missing paths and
    directories return False quietly."""
    try:
        with open(path, "rb") as f:
            first = f.readline()
            second = f.readline()
    except OSError:
        return False
    if first.endswith(b"\n"):
        first = first[:-1]
    if second.endswith(b"\n"):
        second = second[:-1]
    return first == b"---" and second == AGENT_COPY_MARKER.encode("utf-8")


def agent_copy_content(agent_text: str, model: str, effort: str) -> str:
    """What agent sync writes for a plugin agent whose file holds
    <agent_text>: that text with the marker, then model: and reasoningLevel:
    (each only when not inherit) right after its opening ---."""
    lines = lines_of(agent_text)
    if not lines:
        return ""
    header = [lines[0], AGENT_COPY_MARKER]
    if model != "inherit":
        header.append("model: " + model)
    if effort != "inherit":
        header.append("reasoningLevel: " + effort)
    return "".join(line + "\n" for line in header + lines[1:])


@dataclass(frozen=True)
class PlannedWrite:
    """One agent copy agent_sync_plan wants written or updated."""

    name: str
    model: str
    effort: str
    state: str
    content: str


@dataclass(frozen=True)
class SyncPlan:
    """What agent sync would change in a checkout's copy directory without
    mutating disk - the one comparison agent sync and doctor share."""

    directory: str
    want: Tuple[str, ...]
    refused: Tuple[str, ...]
    unreadable: Tuple[str, ...]
    writes: Tuple[PlannedWrite, ...]
    deletes: Tuple[str, ...]


def _list_orch_md(directory: str) -> List[str]:
    """Sorted orch-*.md file names in <directory> that exist (following
    symlinks, as bash's `[ -e ]` check does); empty when <directory> cannot be
    read."""
    try:
        names = os.listdir(directory)
    except OSError:
        return []
    return sorted(
        name for name in names
        if name.startswith("orch-")
        and name.endswith(".md")
        and os.path.exists(os.path.join(directory, name))
    )


def agent_sync_plan(
    root: str,
    cache: ConfigCache,
    host: str,
    plugin_root: Optional[str] = None,
) -> SyncPlan:
    """Plans copy writes, stale deletes and unmarked-file refusals under
    <root>/.junie/agents for <host>, from <cache>'s settings, without mutating
    disk or git exclude. A wanted plugin agent file that cannot be read is
    listed, by full path, in unreadable: it stays wanted, so a marked copy of
    it is not deleted, and no write is planned for it."""
    resolved_plugin = default_plugin_root() if plugin_root is None else plugin_root
    plan_dir = os.path.join(root, ".junie", "agents")
    agents_dir = os.path.join(resolved_plugin, "agents")

    want: List[str] = []
    refused: List[str] = []
    unreadable: List[str] = []
    writes: List[PlannedWrite] = []
    deletes: List[str] = []

    for filename in _list_orch_md(agents_dir):
        name = filename[:-3]
        role = agent_role_of(name)
        if role is None:
            continue
        model, _ = cache.lookup("model", role, host)
        effort, _ = cache.lookup("effort", role, host)
        copy_model = model if agent_allowed("model", model, host) else "inherit"
        copy_effort = effort if agent_allowed("effort", effort, host) else "inherit"
        if copy_model == "inherit" and copy_effort == "inherit":
            continue
        want.append(name)
        agent_file = os.path.join(agents_dir, filename)
        agent_text = read_raw(agent_file)
        if agent_text is None:
            unreadable.append(agent_file)
            continue
        target = os.path.join(plan_dir, filename)
        content = agent_copy_content(agent_text, copy_model, copy_effort)
        state = "missing"
        if os.path.exists(target):
            if not agent_copy_marked(target):
                refused.append(name)
                continue
            if read_raw(target) == content:
                continue
            state = "stale"
        writes.append(PlannedWrite(name, copy_model, copy_effort, state, content))

    want_set = set(want)
    for filename in _list_orch_md(plan_dir):
        name = filename[:-3]
        if not agent_copy_marked(os.path.join(plan_dir, filename)):
            continue
        if name in want_set:
            continue
        deletes.append(name)

    return SyncPlan(
        directory=plan_dir,
        want=tuple(want),
        refused=tuple(refused),
        unreadable=tuple(unreadable),
        writes=tuple(writes),
        deletes=tuple(deletes),
    )


def _apply_sync(cache: ConfigCache, root: str, plugin_root: Optional[str], host: str) -> None:
    plan = agent_sync_plan(root, cache, host, plugin_root)
    if plan.unreadable:
        die("agent sync: cannot read %s" % plan.unreadable[0])
    if plan.refused:
        files = " ".join(name + ".md" for name in plan.refused)
        die(
            "agent sync: %s in %s carries no sync marker - not written by orch.sh agent sync,"
            " so left alone; rename or remove it, then rerun orch.sh agent sync"
            % (files, plan.directory)
        )
    if plan.want:
        exclude_line((AGENT_COPY_EXCLUDE,), cache.git)
    for name in plan.deletes:
        target = os.path.join(plan.directory, name + ".md")
        rm_f_or_die(target, "agent sync: cannot delete %s" % target)
    if plan.writes:
        mkdir_p_or_die(plan.directory, "agent sync: cannot create %s" % plan.directory)
        for entry in plan.writes:
            target = os.path.join(plan.directory, entry.name + ".md")
            text_file_write(target, entry.content, "agent sync: cannot write %s" % target)


def _sync(args: List[str], cache: ConfigCache, root: str, plugin_root: Optional[str]) -> int:
    if args:
        die("usage: orch.sh agent sync")
    for host_name, spec in HOST_SPECS.items():
        if spec.syncs_copies:
            _apply_sync(cache, root, plugin_root, host_name)
    return 0


def _set(args: List[str], cache: ConfigCache, root: str, plugin_root: Optional[str]) -> int:
    usage = (
        "usage: orch.sh agent set <role> [--model <m>] [--effort <e>]"
        " [--global] [--host %s]" % "|".join(FLAG_HOSTS)
    )
    role = args[0] if args else ""
    rest = args[1:]
    agent_require_role(role)
    host = agent_host(rest)
    scope = "local"
    seen_host = False
    vals: Dict[str, str] = {}
    i = 0
    while i < len(rest):
        arg = rest[i]
        if arg in ("--model", "--effort"):
            kind = arg[2:]
            if i + 1 >= len(rest):
                die("%s needs a value (want %s)" % (arg, agent_values(kind, host)))
            if kind in vals:
                die(usage)
            value = rest[i + 1]
            if not agent_allowed(kind, value, host):
                die("%s %s is not allowed (want %s)" % (kind, value, agent_values(kind, host)))
            vals[kind] = value
            i += 2
        elif arg == "--host":
            if seen_host:
                die(usage)
            seen_host = True
            i += 2
        elif arg == "--global":
            if scope != "local":
                die(usage)
            scope = "global"
            i += 1
        else:
            die(usage)
    if not vals:
        die(
            "agent set needs --model or --effort (models: %s; efforts: %s)"
            % (agent_values("model", host), agent_values("effort", host))
        )
    for kind in AGENT_KINDS:
        value = vals.get(kind)
        if value is None:
            continue
        key = agent_key(host, kind, role)
        if value == "inherit":
            cache.unset(scope, key)
        else:
            cache.write(scope, key, value)
    if HOST_SPECS[host].syncs_copies:
        _apply_sync(cache, root, plugin_root, host)
    return 0


def _clear(args: List[str], cache: ConfigCache, root: str, plugin_root: Optional[str]) -> int:
    usage = (
        "usage: orch.sh agent clear <role> [--model] [--effort]"
        " [--global] [--host %s]" % "|".join(FLAG_HOSTS)
    )
    role = args[0] if args else ""
    rest = args[1:]
    agent_require_role(role)
    host = agent_host(rest)
    kinds: List[str] = []
    scope = "local"
    seen_host = False
    i = 0
    while i < len(rest):
        arg = rest[i]
        if arg in ("--model", "--effort"):
            kinds.append(arg[2:])
            i += 1
        elif arg == "--global":
            scope = "global"
            i += 1
        elif arg == "--host":
            if seen_host:
                die(usage)
            seen_host = True
            i += 2
        else:
            die(usage)
    for kind in kinds or list(AGENT_KINDS):
        cache.unset(scope, agent_key(host, kind, role))
    if HOST_SPECS[host].syncs_copies:
        _apply_sync(cache, root, plugin_root, host)
    return 0


def run(
    argv: List[str],
    git=None,
    env: Optional[Mapping[str, str]] = None,
    plugin_root: Optional[str] = None,
) -> int:
    """`orch.sh agent <op> ...`: the real git adapter, the process's
    environment, and the resolved plugin root unless a test hands in others.
    Outside a checkout it dies first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die("unknown agent op: %s (want %s)" % (op or "<none>", OPS))
    if op == "roles":
        return _roles(argv[1:])
    cache = ConfigCache(git)
    if op == "show":
        return _show(argv[1:], cache)
    if op == "get":
        return _get(argv[1:], cache)
    if op == "set":
        return _set(argv[1:], cache, root, plugin_root)
    if op == "clear":
        return _clear(argv[1:], cache, root, plugin_root)
    return _sync(argv[1:], cache, root, plugin_root)


def name_shapes(args: Optional[List[str]] = None) -> int:
    """Bridge for docs_lint.sh: prints AGENT_NAME_SHAPES in order as
    `role<TAB>glob<TAB>ere` lines, pre-expanded via agent_shape_ere."""
    if args:
        die("usage: orch_python_call agent name_shapes")
    sys.stdout.write(
        "".join(
            "%s\t%s\t%s\n" % (role, glob, agent_shape_ere(glob))
            for role, glob in AGENT_NAME_SHAPES
        )
    )
    return 0


def validate_autopilot(args: List[str]) -> int:
    """Bridge for autopilot.sh: validates a Claude Code model or effort value
    against HOST_SPECS, dying with the exact autopilot error message when
    disallowed."""
    if len(args) != 3 or args[0] not in AGENT_KINDS:
        die("usage: orch_python_call agent validate_autopilot <model|effort> <value> <key>")
    kind, value, key = args
    if not agent_allowed(kind, value, AGENT_DEFAULT_HOST):
        die(
            "%s is %s - not an allowed %s (want %s)"
            % (key, value, kind, agent_values(kind, AGENT_DEFAULT_HOST))
        )
    return 0


def _check_host_settings(
    cache: ConfigCache,
    host: str,
    records: List[Tuple[str, str]],
) -> None:
    """One ok record per role with its effective model and effort for <host>
    and their sources, plus fail + clear-remedy records for every disallowed
    stored value at local or global scope."""
    cache.load()
    spec = HOST_SPECS[host]
    for role in AGENT_ROLES:
        records.append((
            "ok",
            "agent %s%s: %s" % (spec.line_prefix, role, agent_role_values(cache, host, role, ",")),
        ))
        for kind in AGENT_KINDS:
            key = agent_key(host, kind, role)
            for scope in ("local", "global"):
                scoped = cache.scoped(scope, key)
                if scoped is None or agent_allowed(kind, scoped, host):
                    continue
                records.append((
                    "fail",
                    "%s is %s (%s) - not an allowed %s (want %s)"
                    % (key, scoped, scope, kind, agent_values(kind, host)),
                ))
                records.append(("remedy", agent_clear_cmd(host, kind, role, scope)))


# The shape of the log line Junie writes when it runs an orch agent.
_JUNIE_EXEC_RE = re.compile(
    r"Executing agent custom_agent_(orch-[A-Za-z0-9-]*)_[0-9]* with parameters"
)
_JUNIE_LAST_NAME_RE = re.compile(
    r".*custom_agent_(orch-[A-Za-z0-9-]*)_[0-9]* with parameters"
)
_JUNIE_UNRECOGNIZED_RE = re.compile(r".*Unrecognized 'model' value '([^']*)'")
_JUNIE_ALLOWED_NAMES_RE = re.compile(r".*(Allowed LLM names:.*)")


def _json_sort_key(value: Any) -> Tuple[int, Any]:
    """Total-order sort key matching jq's sort_by ordering across JSON types:
    null < false < true < numbers < strings < arrays < objects."""
    if value is None:
        return (0, 0)
    if isinstance(value, bool):
        return (1, int(value))
    if isinstance(value, (int, float)):
        return (2, value)
    if isinstance(value, str):
        return (3, value)
    if isinstance(value, list):
        return (4, tuple(_json_sort_key(item) for item in value))
    if isinstance(value, dict):
        return (5, tuple((k, _json_sort_key(v)) for k, v in sorted(value.items())))
    return (6, str(value))


def _junie_path(home: str, *parts: str) -> str:
    """<home>/.junie/<parts>, joined as bash's "$HOME"/.junie/... reads it:
    an empty <home> gives the absolute /.junie/..., never a cwd-relative path."""
    return "/".join((home, ".junie") + parts)


def _junie_newest_log(home: str, sid: Optional[str] = None) -> Optional[str]:
    """Path of the newest <home>/.junie/logs/log-*.log by modification time,
    restricted to files containing <sid> when one is given; None when none
    qualifies."""
    logs_dir = _junie_path(home, "logs")
    try:
        names = sorted(os.listdir(logs_dir))
    except OSError:
        return None
    needle = sid.encode("utf-8", "surrogateescape") if sid else None
    best_path: Optional[str] = None
    best_mtime = -1
    for name in names:
        if not (name.startswith("log-") and name.endswith(".log") and len(name) >= 8):
            continue
        path = os.path.join(logs_dir, name)
        if not os.path.isfile(path):
            continue
        if needle is not None:
            try:
                with open(path, "rb") as f:
                    if needle not in f.read():
                        continue
            except OSError:
                continue
        try:
            mtime = os.stat(path).st_mtime_ns
        except OSError:
            continue
        if best_path is None or mtime > best_mtime:
            best_path = path
            best_mtime = mtime
    return best_path


def _junie_field(line: str, word: str) -> str:
    """The value after <word>= in a Junie log line (not preceded by a letter),
    up to a space, comma or closing parenthesis; empty when absent."""
    match = re.match(r"^.*[^A-Za-z]" + re.escape(word) + r"=([^ ,)]*)", line)
    return match.group(1) if match is not None else ""


def _parse_json_stream(text: str) -> List[Any]:
    """Parses a stream of zero or more whitespace-separated JSON values (as
    `jq -s` reads JSONL or multi-line JSON objects)."""
    decoder = json.JSONDecoder()
    values: List[Any] = []
    pos = 0
    length = len(text)
    while pos < length:
        while pos < length and text[pos] in " \t\r\n":
            pos += 1
        if pos >= length:
            break
        obj, pos = decoder.raw_decode(text, pos)
        values.append(obj)
    return values


def _check_junie_session(
    cache: ConfigCache,
    root: str,
    home: str,
    records: List[Tuple[str, str]],
) -> None:
    """Best-effort report of what each orch-* agent ran on in the newest Junie
    session for <root>, read from <home>/.junie/sessions/index.jsonl with
    stdlib json (no jq dependency) and <home>/.junie/logs/log-*.log."""
    index = _junie_path(home, "sessions", "index.jsonl")
    if not os.path.isfile(index):
        records.append(("ok", "junie session: cannot tell (no Junie session index)"))
        return
    try:
        with open(index, "r", encoding="utf-8") as f:
            values = _parse_json_stream(f.read())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        records.append(("ok", "junie session: cannot tell (the session index does not parse)"))
        return
    matched: List[Dict[str, Any]] = []
    for item in values:
        if item is None:
            continue
        if not isinstance(item, dict):
            records.append(("ok", "junie session: cannot tell (the session index does not parse)"))
            return
        if item.get("projectDir") == root:
            matched.append(item)
    matched.sort(key=lambda entry: _json_sort_key(entry.get("updatedAt")))
    raw_sid = matched[-1].get("sessionId") if matched else None
    if raw_sid is None or raw_sid is False or raw_sid == "":
        records.append(("ok", "junie session: cannot tell (no session for this checkout)"))
        return
    sid = str(raw_sid)
    log = _junie_newest_log(home, sid)
    if log is None:
        records.append(("ok", "junie session: cannot tell (no log names session %s)" % sid))
        return
    agents_ran: List[str] = []
    last_line: Dict[str, str] = {}
    for line in file_lines(log):
        if _JUNIE_EXEC_RE.search(line) is None:
            continue
        name_match = _JUNIE_LAST_NAME_RE.match(line)
        if name_match is None:
            continue
        agent_name = name_match.group(1)
        if agent_name not in last_line:
            agents_ran.append(agent_name)
        last_line[agent_name] = line
    if not agents_ran:
        records.append(("ok", "junie session: cannot tell (the log holds no agent runs)"))
        return
    pending: List[Tuple[str, str]] = []
    for agent_name in agents_ran:
        line = last_line[agent_name]
        model = _junie_field(line, "model")
        if not model:
            records.append(("ok", "junie session: cannot tell (the log does not parse)"))
            return
        effort = "inherited"
        for word in ("effort", "reasoningEffort"):
            val = _junie_field(line, word)
            if val and val != "null":
                effort = val
                break
        role = agent_role_of(agent_name)
        if role is not None:
            set_model, _ = cache.lookup("model", role, "junie")
            set_effort, _ = cache.lookup("effort", role, "junie")
        else:
            set_model, set_effort = "inherit", "inherit"
        mismatch = False
        if set_model != "inherit" and model != set_model and not model.startswith(set_model + "-"):
            mismatch = True
        if set_effort != "inherit" and effort != set_effort:
            mismatch = True
        verdict = "warn" if mismatch else "ok"
        pending.append((
            verdict,
            "junie %s ran model %s, effort %s (set model %s, effort %s)"
            % (agent_name, model, effort, set_model, set_effort),
        ))
    records.extend(pending)


def _check_junie_unrecognized(
    cache: ConfigCache,
    home: str,
    records: List[Tuple[str, str]],
) -> None:
    """Best-effort FAIL on Junie's own Unrecognized 'model' value lines in the
    most recent log-*.log when the value is a role's effective Junie model."""
    log = _junie_newest_log(home)
    if log is None:
        return
    log_lines = file_lines(log)
    values: List[str] = []
    seen = set()
    for line in log_lines:
        match = _JUNIE_UNRECOGNIZED_RE.match(line)
        if match is None:
            continue
        val = match.group(1)
        if val and val not in seen:
            seen.add(val)
            values.append(val)
    for val in values:
        needle = "Unrecognized 'model' value '%s'" % val
        last = ""
        for line in reversed(log_lines):
            if needle in line:
                last = line
                break
        names_match = _JUNIE_ALLOWED_NAMES_RE.match(last)
        names = names_match.group(1) if names_match is not None else ""
        for role in AGENT_ROLES:
            effective, src = cache.lookup("model", role, "junie")
            if effective != val:
                continue
            records.append((
                "fail",
                "Junie did not recognise model %s, set for %s (%s) - it fell back to the session model"
                % (val, role, src),
            ))
            if names:
                records.append(("remedy", names))
            records.append(("remedy", "orch.sh agent set %s --host junie --model <id>" % role))


def _check_sync_drift(
    cache: ConfigCache,
    root: str,
    plugin_root: Optional[str],
    host: str,
    records: List[Tuple[str, str]],
) -> None:
    """Warns when this checkout's copy directory for <host> differs from what
    agent_sync_plan would leave (missing, stale, extra, unmarked in the way,
    or a plugin agent file it cannot read)."""
    plan = agent_sync_plan(root, cache, host, plugin_root)
    missing = [w.name + ".md" for w in plan.writes if w.state == "missing"]
    stale = [w.name + ".md" for w in plan.writes if w.state != "missing"]
    extra = [name + ".md" for name in plan.deletes]
    refused = [name + ".md" for name in plan.refused]
    if not (missing or stale or extra or refused or plan.unreadable):
        return
    parts: List[str] = []
    if missing:
        parts.append("missing " + " ".join(missing))
    if stale:
        parts.append("stale " + " ".join(stale))
    if extra:
        parts.append("extra " + " ".join(extra))
    if refused:
        parts.append(" ".join(refused) + " carries no sync marker and is in the way")
    parts.extend("cannot read " + path for path in plan.unreadable)
    records.append((
        "warn",
        "%s agent copies in %s are not what agent sync would leave: %s"
        % (host.capitalize(), plan.directory, "; ".join(parts)),
    ))
    if plan.unreadable:
        records.append((
            "remedy",
            "make %s readable or reinstall the plugin, then run orch.sh agent sync"
            % plan.unreadable[0],
        ))
    else:
        records.append(("remedy", "orch.sh agent sync"))


def check_settings(
    args: Optional[List[str]] = None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    plugin_root: Optional[str] = None,
) -> int:
    """Bridge for doctor.sh's check_agent_settings: runs all four agent
    settings sub-checks and emits NUL-delimited `<kind>\\t<message>\\0`
    records (`ok`, `warn`, `fail`, `remedy`)."""
    if args:
        die("usage: orch_python_call agent check_settings")
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    home = env.get("HOME", "")
    cache = ConfigCache(git)
    records: List[Tuple[str, str]] = []
    _check_host_settings(cache, AGENT_DEFAULT_HOST, records)
    _check_junie_session(cache, root, home, records)
    _check_junie_unrecognized(cache, home, records)
    for host_name, spec in HOST_SPECS.items():
        if host_name == AGENT_DEFAULT_HOST:
            continue
        _check_host_settings(cache, host_name, records)
        if spec.syncs_copies:
            _check_sync_drift(cache, root, plugin_root, host_name, records)
    stdout_write("".join("%s\t%s\0" % (kind, message) for kind, message in records))
    return 0
