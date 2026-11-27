"""The Liveness module, a concept module with no noun, as far as a converted
noun needs it: whether the process behind a record is still running, and
whether the process behind an issue's claim is - by its run record under the
main checkout's autopilot directory, else its tick record.

It owns the record format, `<pid> <start-time>`, which the bash side's
liveness.sh writes and reads too, and the start-time reader: field 22 of
/proc/<pid>/stat under ORCH_PROC_DIR (default /proc) on a host with /proc, else
`ps -o lstart=`, its words joined by `_`, so a record either side wrote reads
the same on the other. A record is alive while its pid runs with the start
time it records; a bare-pid or malformed one is stale. It also owns the
clone's watch pidfile, under the git common directory, which holds the
watch's record.
"""
from __future__ import annotations

import os
import subprocess
from typing import Mapping, Optional, Tuple

from orch.autopilot import autopilot_dir
from orch.common import (die, mkdir_p_or_die, plain_number, read_raw, read_text, rm_f,
                         text_file_write, warn)


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


def clone_orchestrator_dir(git) -> str:
    """The clone's orchestrator directory, under its git common directory
    made absolute, which every worktree of the clone reaches alike - bash
    clone_orchestrator_dir. Dies when there is none."""
    common = git.git_common_dir()
    if common is None or not os.path.isdir(common):
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
