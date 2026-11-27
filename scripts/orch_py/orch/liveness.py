"""The Liveness module, a concept module with no noun: whether the process
behind a record - an autopilot flow's claim on this host, a watch - is still
running.

It owns the main checkout's autopilot run/ layout (run/<issue>.pid, the run
record; run/<issue>.tick, the tick's record; and run/<issue>.hit, the hit
file: the reset of a GitHub API rate limit a session hit), the record format,
`<pid> <start-time>`, which the deleted bash liveness.sh wrote too, and the
start-time reader: field 22 of /proc/<pid>/stat under ORCH_PROC_DIR (default
/proc) on a host with /proc, else `ps -o lstart=`, its words joined by `_`. A
record is alive while its pid runs with the start time it records; a
bare-pid or malformed one is stale. It owns too the watch pidfile, under the
clone's git common directory, and the session log naming
(logs/<issue>-<phase>-<stamp>.log) and its retention: a session log last
modified more than 14 days ago is deleted (logs_prune). A session writes the
hit file only at the path the wrapper hands it.
"""
from __future__ import annotations

import os
import re
import subprocess
from typing import Callable, List, Mapping, Optional, Tuple

from orch.autopilot import autopilot_dir
from orch.common import (DIR_STAMP_PATTERN, dir_stamp, die, file_write_atomic, mkdir_p_or_die,
                         plain_number, read_raw, read_text, rm_f, text_file_write, warn)


def proc_start(pid: int, env: Mapping[str, str]) -> Optional[str]:
    """The process's start time as one whitespace-free token; None when it
    cannot be read."""
    root = env.get("ORCH_PROC_DIR", "") or "/proc"
    if os.path.isdir(os.path.join(root, str(os.getpid()))):
        stat = read_text(os.path.join(root, str(pid), "stat"))
        if stat is None:
            return None
        # After the command name, field 22 is the 20th word.
        words = stat.rsplit(") ", 1)[-1].split()
        return words[19] if len(words) > 19 else None
    try:
        run = subprocess.run(
            ["ps", "-o", "lstart=", "-p", str(pid)], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None
    words = run.stdout.decode("utf-8", "surrogateescape").split()
    if run.returncode != 0 or not words:
        return None
    return "_".join(words)


def record_of(pid: int, env: Mapping[str, str]) -> Optional[str]:
    """The process's record, `<pid> <start-time>` and a newline; None when
    its start time cannot be read."""
    start = proc_start(pid, env)
    return None if start is None else "%d %s\n" % (pid, start)


def record_pid(record: str) -> Optional[int]:
    """The pid a record names; None when its first word is no plain pid."""
    words = record.split()
    if not words or not plain_number(words[0]):
        return None
    return int(words[0])


def record_alive(record: str, env: Mapping[str, str]) -> bool:
    """Whether the record's process is running with the recorded start
    time."""
    words = record.split()
    pid = record_pid(record)
    if pid is None or len(words) != 2:
        return False
    return proc_start(pid, env) == words[1]


def run_dir(main: str) -> str:
    """The directory of the issues' run and tick records under the main
    checkout <main> - bash liveness_subdir run."""
    return autopilot_dir(main) + "/run"


def issue_record(main: str, issue: str) -> str:
    """Issue <issue>'s record text - its run record's when there is one,
    else its tick record's, else "" - bash liveness_issue_record; "" too for
    a record that cannot be read."""
    for kind in ("pid", "tick"):
        path = "%s/%s.%s" % (run_dir(main), issue, kind)
        if os.path.isfile(path):
            return read_raw(path) or ""
    return ""


def issue_alive(main: str, issue: str, env: Mapping[str, str]) -> Tuple[bool, str]:
    """Whether the process behind issue <issue>'s claim is alive, by its
    record under the main checkout <main> (issue_record); with neither
    record, gone - bash liveness_issue_alive. With it, the pid the record
    names, its first word, "" where there is no record."""
    record = issue_record(main, issue)
    return record_alive(record, env), record.split(" ", 1)[0].rstrip("\n")


def record_write(pid: int, path: str, env: Mapping[str, str]) -> bool:
    """Writes the process <pid>'s record to the file at <path>. Whether it
    held: False, with an orch: line, when the start time cannot be read or
    the file cannot be written."""
    record = record_of(pid, env)
    if record is None:
        warn("could not read the start time of pid %d" % pid)
        return False
    if not file_write_atomic(path, record, make_directory=False):
        warn("could not write " + path)
        return False
    return True


def file_alive(pid: int, path: str, env: Mapping[str, str]) -> bool:
    """Whether the file at <path> holds the record of <pid>, alive by the
    record-alive rule. An empty, malformed or unreadable file, or a record
    naming another pid, is stale."""
    record = read_text(path)
    return record is not None and record_pid(record) == pid and record_alive(record, env)


def _issue_file(main: str, issue: str, kind: str) -> str:
    """Issue <issue>'s file of <kind> (pid, tick or hit) in the run
    directory under <main>."""
    return "%s/%s.%s" % (run_dir(main), issue, kind)


def tick_begin(main: Optional[str], issue: str, pid: int, env: Mapping[str, str]) -> None:
    """Right after a tick takes a claim, writes the process <pid>'s record
    as issue <issue>'s tick record under the main checkout <main> (None when
    it cannot be read), over an older one. A failed write warns and carries
    on: with no record, the claim's process counts as gone."""
    record = record_of(pid, env)
    if (main is not None and record is not None
            and file_write_atomic(_issue_file(main, issue, "tick"), record)):
        return
    warn("could not write the tick record for issue #%s" % issue)


def run_begin(main: str, issue: str, pid: int, env: Mapping[str, str]) -> bool:
    """Writes the process <pid>'s run record for issue <issue> under <main>
    and removes the issue's tick record and hit file. Dies "could not create
    <dir>" when the run directory cannot be made; False, with an orch: line
    and the tick record left, when the record cannot be written."""
    mkdir_p_or_die(run_dir(main), "could not create " + run_dir(main))
    if not record_write(pid, _issue_file(main, issue, "pid"), env):
        return False
    rm_f(_issue_file(main, issue, "tick"))
    rm_f(_issue_file(main, issue, "hit"))
    return True


def run_end(main: str, issue: str, pid: int, env: Mapping[str, str]) -> None:
    """Removes issue <issue>'s run record only while it still names <pid>,
    so a later run's record survives an earlier run's exit."""
    path = _issue_file(main, issue, "pid")
    if file_alive(pid, path, env):
        rm_f(path)


def issue_forget(main: str, issue: str) -> None:
    """Removes both of issue <issue>'s records."""
    rm_f(_issue_file(main, issue, "pid"))
    rm_f(_issue_file(main, issue, "tick"))


def live_issues(main: str, env: Mapping[str, str]) -> List[str]:
    """The issues whose process is alive by issue_alive's rule, ascending."""
    try:
        names = os.listdir(run_dir(main))
    except OSError:
        names = []
    issues = {name.rsplit(".", 1)[0] for name in names
              if name.endswith((".pid", ".tick")) and plain_number(name.rsplit(".", 1)[0])}
    return [issue for issue in sorted(issues, key=int) if issue_alive(main, issue, env)[0]]


def hit_path(main: str, issue: str) -> str:
    """Issue <issue>'s hit file, beside its run record: where a session
    writes the reset of a GitHub API rate limit it hit (#2577)."""
    return _issue_file(main, issue, "hit")


def hit_take(main: str, issue: str) -> str:
    """The text of issue <issue>'s hit file, the file removed; "" when there
    is none. A failed removal is ignored."""
    path = hit_path(main, issue)
    if not os.path.isfile(path):
        return ""
    text = read_raw(path) or ""
    rm_f(path)
    return text


def logs_dir(main: str) -> str:
    """The session logs' directory under the main checkout <main>."""
    return autopilot_dir(main) + "/logs"


def log_path(main: str, issue: str, phase: str, clock: Callable[[], float]) -> str:
    """A new session log's path, logs/<issue>-<phase>-<stamp>.log, stamped
    with the time <clock> reads; makes the logs directory, dying "could not
    create <dir>" when it cannot."""
    folder = logs_dir(main)
    mkdir_p_or_die(folder, "could not create " + folder)
    return "%s/%s-%s-%s.log" % (folder, issue, phase, dir_stamp(clock))


def latest_log(main: str, issue: str, phase: str = "") -> str:
    """The newest session log of issue <issue> (of <phase>, when given),
    ordered by its stamp whatever its phase; "" when there is none."""
    prefix = "%s-%s-" % (issue, phase) if phase else issue + "-"
    try:
        names = os.listdir(logs_dir(main))
    except OSError:
        return ""
    stamped = []
    for name in names:
        if name.startswith(prefix) and name.endswith(".log"):
            rest = name[len(issue) + 1:]
            stamped.append((rest.split("-", 1)[-1], name))
    if not stamped:
        return ""
    return "%s/%s" % (logs_dir(main), max(stamped)[1])


# How old a session log must be to be pruned: 14 days, a fixed constant and
# no setting.
LOG_RETENTION_SECONDS = 14 * 24 * 60 * 60
# A session log's name, as log_path writes it.
LOG_NAME = re.compile(r"[0-9]+-[^-]+-%s\.log" % DIR_STAMP_PATTERN)


def logs_prune(main: str, now: float) -> bool:
    """Deletes the session logs (logs/<issue>-<phase>-<stamp>.log) last
    modified more than 14 days before <now>, and nothing else in the logs
    directory. Whether it all went: a missing logs directory is no failure;
    one that is no directory, or cannot be listed, or a log that cannot be
    deleted, warns with an orch: line and is."""
    folder = logs_dir(main)
    if not os.path.exists(folder):
        return True
    if not os.path.isdir(folder):
        warn("could not prune the session logs: %s is not a directory" % folder)
        return False
    try:
        entries = list(os.scandir(folder))
    except OSError:
        warn("could not prune the session logs: %s could not be listed" % folder)
        return False
    pruned = True
    for entry in sorted(entries, key=lambda entry: entry.name):
        try:
            old = (entry.is_file(follow_symlinks=False)
                   and now - entry.stat(follow_symlinks=False).st_mtime > LOG_RETENTION_SECONDS)
        except OSError:
            old = False
        if not old or not LOG_NAME.fullmatch(entry.name):
            continue
        path = "%s/%s" % (folder, entry.name)
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        except OSError:
            warn("could not delete the old session log " + path)
            pruned = False
    return pruned


def clone_orchestrator_dir(git) -> str:
    """The clone's orchestrator directory, under the git common directory
    the git adapter <git> reads, made absolute, which every worktree of the
    clone reaches alike. Dies when there is none."""
    common = git.git_common_dir()
    if not common or not os.path.isdir(common):
        die("could not find the clone's git common directory")
    return os.path.realpath(common) + "/orchestrator"


def watch_pidfile(git) -> str:
    """The clone's watch pidfile - bash liveness_watch_pidfile."""
    return clone_orchestrator_dir(git) + "/autopilot-watch.pid"


def watch_begin(pidfile: str, env: Mapping[str, str]) -> bool:
    """Writes this process's record to the watch pidfile <pidfile>, a
    record whose process is gone replaced - bash liveness_watch_begin. Dies
    while the record names a live watch, naming its pid, and when the
    directory cannot be made; False, with a warning, when this process's
    start time cannot be read."""
    if os.path.isfile(pidfile):
        other = read_raw(pidfile) or ""
        if record_alive(other, env):
            die("another autopilot watch (pid %s) is already running in this clone"
                % other.split(" ", 1)[0])
    directory = os.path.dirname(pidfile)
    mkdir_p_or_die(directory, "could not create " + directory)
    record = record_of(os.getpid(), env)
    if record is None:
        warn("could not read the start time of pid %d" % os.getpid())
        return False
    text_file_write(pidfile, record, "could not write " + pidfile)
    return True


def watch_end(pidfile: str) -> None:
    """Removes the watch pidfile - bash liveness_watch_end."""
    rm_f(pidfile)
