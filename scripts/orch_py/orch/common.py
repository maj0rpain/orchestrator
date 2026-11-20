"""The primitives no concept owns: the `orch: ` message lines.

Every `orch: ` message goes through die or warn, as in the bash side's
common.sh: die(message, 2) is the bash die2, for a command that reserves exit
1 for a meaningful "no".
"""
from __future__ import annotations

import sys
from typing import NoReturn


def die(message: str, code: int = 1) -> NoReturn:
    """Prints `orch: <message>` on stderr and exits with <code>."""
    print("orch: " + message, file=sys.stderr)
    sys.exit(code)


def warn(message: str) -> None:
    """die's line on stderr, without the exit."""
    print("orch: " + message, file=sys.stderr)
