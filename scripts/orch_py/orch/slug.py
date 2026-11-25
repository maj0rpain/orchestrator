"""orch.sh's slug noun (ADR-0067), a bare global command: the one
normalisation a slug gets, orch.common's normalize_slug, exposed so a skill
names a branch or flow with it rather than restating the algorithm as prose.

run(argv) takes the arguments after `slug`, as orch.sh hands them on, and
returns the exit code; every error dies through orch.common.die, exit 1. It
keeps the bash noun's usage line, stdout and `orch:` messages: arguments after
the text are ignored, as bash ignored them.
"""
from __future__ import annotations

from typing import List

from orch.common import die, normalize_slug


def run(argv: List[str]) -> int:
    """`orch.sh slug <text>`: prints the text's slug, one line."""
    text = argv[0] if argv else ""
    if not text:
        die("usage: orch.sh slug <text>")
    print(normalize_slug(text))
    return 0
