"""The autopilot concept's module (scripts/orch/autopilot.sh), kept to what
the Python nouns read and write: whether this is an autopilot session, the
plan's `## Autopilot` block, as handoff_report checks it for 01-plan.md, the
UTC timestamps the pause files hold, and the GitHub limit record the gh
adapter's limit handling makes in an autopilot process - the GitHub limit
pause under the main checkout and a session's hit file, in the format and at
the path autopilot.sh reads them (pinned by tests/github_pause/, ADR-0067).
"""
from __future__ import annotations

import calendar
import os
import time
from typing import Callable, List, Mapping, Optional, Tuple

from orch.common import ORCH_DIR_NAME, is_positive_int, read_text, trim

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
