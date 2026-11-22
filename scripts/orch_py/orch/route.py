"""orch.sh's route noun (ADR-0067): the default route, which of the four
routes the interview's Closing lists first. Read here alone, so the skills
never call git config; it is set with git config [--global] orchestrator.route
<route>. git config --get gives the clone's local value before the user's
global one.

run(argv) takes the arguments after `route`, as orch.sh hands them on, and
returns the exit code; every error dies through orch.common.die, exit 1. The
verb keeps the bash noun's usage line, stdout, exit codes and `orch:`
messages, but for one difference: git config's value is read through the git
adapter's config_value, which trims it, so a padded value such as "flow " is
accepted and printed trimmed where bash refused it.
"""
from __future__ import annotations

from typing import List

from orch.common import die
from orch.git import Git

# The verbs. docs_lint.sh reads this line as the verbs the noun dispatches, so
# it stays one `OPS = "<verb>|..."` line.
OPS = "show"

ROUTES = ("flow", "quick", "blueprint", "autopilot")


def show(argv: List[str], git) -> int:
    """`route show`: orchestrator.route, or none when it is unset or empty; a
    value that names no route dies."""
    if argv:
        die("usage: orch.sh route show")
    value = git.config_value("orchestrator.route")
    if value and value not in ROUTES:
        die("orchestrator.route is %s - it must be one of flow, quick, blueprint"
            " or autopilot (git config orchestrator.route <route>)" % value)
    print(value or "none")
    return 0


def run(argv: List[str], git=None) -> int:
    """`orch.sh route <op> ...`: the real git adapter unless a test hands in
    another."""
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die("unknown route op: %s (want %s)" % (op or "<none>", OPS))
    return show(argv[1:], Git() if git is None else git)
