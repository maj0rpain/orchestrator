"""The primitives no concept owns: the `orch: ` message lines, the
plain-number test every verb checks its issue numbers with, the atomic file
write, the temporary file a comment is handed to gh from, and the words a
list and a state read as in a line.

Every `orch: ` message goes through die or warn, as in the bash side's
common.sh: die(message, 2) is the bash die2, for a command that reserves exit
1 for a meaningful "no". Both flush stdout first, so a line printed ahead of
the message comes ahead of it, as bash's unbuffered output does. Both build
the line with message_line, which a message handed on rather than printed -
the gh adapter's rate-limit failure - uses alone.
"""
from __future__ import annotations

import os
import sys
import tempfile
from contextlib import contextmanager
from typing import Callable, Iterable, Iterator, NoReturn, Tuple


def die(message: str, code: int = 1) -> NoReturn:
    """Prints `orch: <message>` on stderr and exits with <code>."""
    warn(message)
    sys.exit(code)


def warn(message: str) -> None:
    """die's line on stderr, without the exit."""
    sys.stdout.flush()
    sys.stderr.write(message_line(message))


def message_line(message: str) -> str:
    """The `orch: <message>` line die and warn print, newline included, for a
    caller that hands the line on rather than printing it."""
    return "orch: " + message + "\n"


def plain_number(text: str) -> bool:
    """Whether <text> is a plain number: one or more ASCII digits and nothing
    else, as bash's `''|*[!0-9]*` refusal reads one."""
    return text.isdigit() and text.isascii()


def file_write_atomic(path: str, text: str) -> bool:
    """Writes <text> to <path> through a temporary file beside it, renamed
    over it, its directory made first: a reader never sees half a file, and
    a failed write leaves the file as it was and no temporary file behind.
    Whether it succeeded."""
    directory = os.path.dirname(path) or "."
    try:
        os.makedirs(directory, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", dir=directory)
    except OSError:
        return False
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(text.encode("utf-8", "surrogateescape"))
        os.replace(tmp, path)
    except OSError:
        os.unlink(tmp)
        return False
    return True


@contextmanager
def temp_text_file(
    text: str,
    unmade: str,
    unwritten: str,
    mkstemp: Callable[[], Tuple[int, str]] = tempfile.mkstemp,
) -> Iterator[str]:
    """Yields the path of a temporary file, made by <mkstemp>, holding
    <text> as UTF-8 - surrogateescape, so bytes read that way come back as
    they were - and removes it on exit, a death included. Dies with <unmade>
    when the file cannot be made, and with <unwritten> when it cannot be
    written."""
    try:
        fd, path = mkstemp()
    except OSError:
        die(unmade)
    try:
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(text.encode("utf-8", "surrogateescape"))
        except OSError:
            die(unwritten)
        yield path
    finally:
        os.remove(path)


def list_join(items: Iterable[str]) -> str:
    """The non-empty items joined with ", ", as a list reads in a sentence."""
    return ", ".join(item for item in items if item)


STATE_WORDS = {"OPEN": "open", "CLOSED": "closed", "MERGED": "merged"}


def state_word(state: str) -> str:
    """GitHub's uppercase issue or PR state as the lowercase word a message
    prints; any other value unchanged."""
    return STATE_WORDS.get(state, state)
