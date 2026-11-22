"""orch.sh's parallel noun (ADR-0067): the clone's parallel cap, how many
ticket subagents one frontier runs at once, 1 meaning sequential. Read here
alone, so the default lives in one place and the skills never call git config;
it is set with git config orchestrator.parallel.

run(argv) takes the arguments after `parallel`, as orch.sh hands them on, and
returns the exit code; every error dies through orch.common.die, exit 1. The
verb keeps the bash noun's usage line, stdout, exit codes and `orch:`
messages, but for one difference: git config's value is read through the git
adapter's config_value, which trims it, so a padded value such as " 5" is
accepted and printed trimmed where bash refused it.
"""
from __future__ import annotations

import re
from typing import List

from orch.common import die
from orch.git import Git

# The verbs. docs_lint.sh reads this line as the verbs the noun dispatches, so
# it stays one `OPS = "<verb>|..."` line.
OPS = "show"

# The cap when orchestrator.parallel is unset.
PARALLEL_DEFAULT = 3

_DIGITS = re.compile(r"[0-9]+")


def show(argv: List[str], git) -> int:
    """`parallel show`: orchestrator.parallel in base 10, leading zeros
    dropped, or PARALLEL_DEFAULT when it is unset; a value that is not a whole
    number of 1 or more dies, as bash's is_positive_int ruled."""
    if argv:
        die("usage: orch.sh parallel show")
    value = git.config_value("orchestrator.parallel") or str(PARALLEL_DEFAULT)
    if not _DIGITS.fullmatch(value) or int(value) == 0:
        die("orchestrator.parallel is %s - it must be a positive integer"
            " (git config orchestrator.parallel <n>)" % value)
    print(int(value))
    return 0


def run(argv: List[str], git=None) -> int:
    """`orch.sh parallel <op> ...`: the real git adapter unless a test hands
    in another."""
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die("unknown parallel op: %s (want %s)" % (op or "<none>", OPS))
    return show(argv[1:], Git() if git is None else git)
