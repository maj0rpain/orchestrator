"""The redo concept's module, so far the one piece of bash redo.sh the review
loop's terminal-state read shares: redo_midway, the predicate that says a
redo (review or spec) is half-finished. The `redo` noun grows it rather than
moving it.
"""
from __future__ import annotations

import re
from typing import Optional

from orch.branch import branch_name_redo

# An integer as bash's test reads one for -gt: leading whitespace, a sign and
# digits, then trailing spaces or tabs.
_TEST_INTEGER = re.compile(r"[ \t\n\v\f\r]*[+-]?[0-9]+[ \t]*")


def redo_midway(issue: str, slug: str, branch: str, redo_count: str) -> Optional[str]:
    """<redo_count> while a redo is half-finished, else None; reads nothing -
    the caller holds the Flow state's branch and redo_count. True between a
    redo's branch retire and its closing write, which clears state.branch:
    redo_count is above 0 and <branch> is exactly the -redo-<redo_count> name
    of <issue> and <slug> (the exact name, so a slug that merely ends that way
    does not match: #2550). As bash redo_midway, the one test the redo noun's
    retire plan and the terminal-state read both make."""
    if not _TEST_INTEGER.fullmatch(redo_count) or int(redo_count) <= 0:
        return None
    if branch != branch_name_redo(issue, slug, redo_count):
        return None
    return redo_count
