"""The Liveness module, a concept module with no noun, as far as a converted
noun needs it: whether the process behind a record is still running.

It owns the record format, `<pid> <start-time>`, which the bash side's
liveness.sh writes and reads too, and the start-time reader: field 22 of
/proc/<pid>/stat under ORCH_PROC_DIR (default /proc) on a host with /proc, else
`ps -o lstart=`, its words joined by `_`, so a record either side wrote reads
the same on the other. A record is alive while its pid runs with the start
time it records; a bare-pid or malformed one is stale.
"""
from __future__ import annotations

import os
import subprocess
from typing import Mapping, Optional

from orch.common import plain_number, read_text


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
