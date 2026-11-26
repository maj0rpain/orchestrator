"""The autopilot concept's module (scripts/orch/autopilot.sh), kept to what
the Python nouns read: whether this is an autopilot session, and the plan's
`## Autopilot` block, as handoff_report checks it for 01-plan.md.
"""
from __future__ import annotations

from typing import List, Mapping, Tuple

from orch.common import plain_number, trim

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
        elif not (plain_number(values[0]) and int(values[0]) > 0):
            lines.append("FAIL ## Autopilot %s is %s - it must be a whole number of 1 or more"
                         % (key, values[0]))
    if lines:
        return lines, 1
    return ["ok ## Autopilot"], 0
