"""The entry point: the interpreter check first, then the converted noun.

main(argv) takes `<noun> <verb> ...` as orch.sh hands them on. Below Python
3.9 it dies before doing anything, exit 1, naming the version found. A noun
not in NOUNS dies as orch.sh dies on an unknown command.
"""
from __future__ import annotations

import sys
from typing import Callable, Dict, List, NoReturn

MIN_PYTHON = (3, 9)

# The converted nouns: each takes the arguments after the noun and returns its
# exit code.
NOUNS: Dict[str, Callable[[List[str]], int]] = {}


def die(message: str, code: int = 1) -> NoReturn:
    """Prints `orch: <message>` on stderr and exits with <code>."""
    print("orch: " + message, file=sys.stderr)
    sys.exit(code)


def require_python(noun: str) -> None:
    """Dies, exit 1, when the running Python is older than MIN_PYTHON."""
    if tuple(sys.version_info[:2]) >= MIN_PYTHON:
        return
    found = ".".join(str(part) for part in sys.version_info[:3])
    die(
        "orch.sh %s needs python3 3.9 or newer (found %s) - run orch.sh doctor"
        % (noun, found)
    )


def main(argv: List[str]) -> int:
    noun = argv[0] if argv else ""
    require_python(noun)
    run = NOUNS.get(noun)
    if run is None:
        die("unknown command: %s (run 'orch.sh help')" % noun)
    return run(argv[1:])
