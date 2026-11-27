"""The Session log module, a concept module with no noun: what a phase
session's log says about Claude Code usage limits, read in one pass by
session_log_read. The Liveness module names the log files; this module reads
them. Times are epoch seconds. Ported from the deleted bash session-log.sh,
its one reader autopilot run's session end.
"""
from __future__ import annotations

import json
import math
import re
import time
from typing import Any, List, NamedTuple, Optional

from orch.common import read_raw

# The text of Claude Code's usage-limit message, with its reset time when it
# gives one: an epoch after `|`, or a `resets <time>`. Matched within one line,
# case-insensitively, as grep -Eio matches it.
LIMIT_PATTERN = re.compile(r"(usage|[0-9]+-hour|weekly) limit reached(\|[0-9]+|[^|]{0,8}resets [^|]*)?",
                           re.IGNORECASE)

# A `resets [<weekday>] <h>[:<mm>]<am|pm>` time, in lower-cased text.
RESETS_PATTERN = re.compile(r"resets\s+(([a-z]{3})[a-z]*\s+)?([0-9]{1,2})(:([0-9]{2}))?\s*(am|pm)")

DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")

# The longest final reply quoted, in characters, before it is cut with "…".
REPLY_MAX = 500


class SessionLog(NamedTuple):
    """What a session log says: whether the session stopped on a usage
    limit; the reset it named (None when none); the five-hour window's
    resetsAt when its utilization is 0.9 or more (else None); and the last
    result event's text as one line, cut to REPLY_MAX characters with "…"
    appended ("" when it has none)."""

    limited: bool
    reset: Optional[int]
    early: Optional[int]
    reply: str


NOT_LIMITED = SessionLog(False, None, None, "")


def resets_epoch(text: str, now: float) -> Optional[int]:
    """The next moment, in local time and as epoch seconds, of the `resets
    [<weekday>] <h>[:<mm>]<am|pm>` time in <text>, such as "resets 3pm" or
    "resets Mon 9am", seen from <now>; None when <text> holds none. A time
    already past today is the same time tomorrow, or, with a weekday, a week
    on at most."""
    found = RESETS_PATTERN.search(text.lower())
    if not found:
        return None
    day, h, m, ap = found.group(2) or "", int(found.group(3)), int(found.group(5) or 0), found.group(6)
    if not 1 <= h <= 12 or m > 59:
        return None
    if ap == "pm" and h != 12:
        h += 12
    if ap == "am" and h == 12:
        h = 0
    now_epoch = int(now)
    local = time.localtime(now_epoch)
    since = local.tm_hour * 3600 + local.tm_min * 60 + local.tm_sec
    target = now_epoch - since + h * 3600 + m * 60
    if day:
        if day not in DAYS:
            return None
        ahead = (DAYS.index(day) - local.tm_wday + 7) % 7
        target += ahead * 86400
        if target <= now_epoch:
            target += 7 * 86400
    elif target <= now_epoch:
        target += 86400
    # A clock change between now and then shifts the hour: pull the target
    # back to the wanted local time of day.
    clock = time.localtime(target)
    shift = h * 3600 + m * 60 - (clock.tm_hour * 3600 + clock.tm_min * 60 + clock.tm_sec)
    if shift > 43200:
        shift -= 86400
    if shift < -43200:
        shift += 86400
    return target + shift


def _or(value: Any, default: Any) -> Any:
    """jq's `<value> // <default>`: <default> where <value> is null or
    false."""
    return default if value is None or value is False else value


def _number(value: Any) -> bool:
    """Whether <value> is a JSON number, never a boolean."""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _rejecting_reset(event: Any) -> Any:
    """The last rate_limit_event's verdict: "none" when no window (top
    level or under unifiedWindows) has a status other than allowed or
    allowed_warning; else the latest resetsAt among those windows, floored,
    or None when none of them names one. An event of an unexpected shape
    reads as "none"."""
    info = _or(event.get("rate_limit_info") if isinstance(event, dict) else None, {})
    if not isinstance(info, dict):
        return "none"
    windows = _or(info.get("unifiedWindows"), {})
    if isinstance(windows, dict):
        windows = list(windows.values())
    elif not isinstance(windows, list):
        return "none"
    rejecting = [w for w in [info] + windows if isinstance(w, dict)
                 and _or(w.get("status"), "allowed") not in ("allowed", "allowed_warning")]
    if not rejecting:
        return "none"
    resets = [math.floor(w["resetsAt"]) for w in rejecting if _number(w.get("resetsAt"))]
    return max(resets) if resets else None


def _early(event: Any) -> Optional[int]:
    """The five-hour window's resetsAt, floored, when its utilization is 0.9
    or more: the event's own when its rateLimitType is five_hour, else the
    one under unifiedWindows; None otherwise."""
    info = _or(event.get("rate_limit_info") if isinstance(event, dict) else None, {})
    if not isinstance(info, dict):
        return None
    if info.get("rateLimitType") == "five_hour":
        window = info
    else:
        windows = info.get("unifiedWindows")
        if windows is not None and not isinstance(windows, dict):
            return None
        window = (windows or {}).get("five_hour")
    if not isinstance(window, dict):
        return None
    use, reset = window.get("utilization"), window.get("resetsAt")
    if _number(use) and use >= 0.9 and _number(reset):
        return math.floor(reset)
    return None


def _reply(result: str) -> str:
    """The final reply: <result>'s whitespace runs as one space, trimmed,
    cut to REPLY_MAX characters with "…" appended."""
    line = re.sub(r"\s+", " ", result)
    line = re.sub(r"^ | $", "", line)
    return line[:REPLY_MAX] + "…" if len(line) > REPLY_MAX else line


def session_log_read(path: str, now: float) -> SessionLog:
    """Reads the session log at <path> in one pass. The last
    rate_limit_event decides first: a window whose status is neither
    allowed nor allowed_warning is a limit stop at the latest resetsAt among
    such windows, or at none. Only without one is the text read - the lines
    that do not parse as JSON in log order, then the last result event's
    text, never an assistant message or a tool result - and the last
    usage-limit message in it decides the reset, a `resets <time>` one read
    from <now>. A missing or unreadable log is not limited, the rest
    empty."""
    text = read_raw(path)
    if text is None:
        return NOT_LIMITED
    last_rate_limit, last_result = None, None
    plain: List[str] = []
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            plain.append(line)
            continue
        if isinstance(event, dict) and event.get("type") == "rate_limit_event":
            last_rate_limit = event
        elif isinstance(event, dict) and event.get("type") == "result":
            last_result = event
    result = last_result.get("result") if last_result is not None else None
    result = result if isinstance(result, str) else ""
    early = _early(last_rate_limit)
    reply = _reply(result)
    rejecting = _rejecting_reset(last_rate_limit)
    if rejecting != "none":
        return SessionLog(True, rejecting, early, reply)
    hits = [found.group(0) for line in plain + result.split("\n")
            for found in LIMIT_PATTERN.finditer(line)]
    if not hits:
        return SessionLog(False, None, early, reply)
    hit = hits[-1]
    if "|" in hit:
        return SessionLog(True, int(hit.rsplit("|", 1)[1]), early, reply)
    return SessionLog(True, resets_epoch(hit, now), early, reply)
