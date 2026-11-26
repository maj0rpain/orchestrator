"""The primitives no concept owns: the `orch: ` message lines, the hint an
unescaped @@ line's refusal adds, the @@-line test and the trailing-CR drop the
@@ grammars read each line with, the plain-number tests every verb checks its
issue numbers with - any plain number, and one with no leading zero - the
decimal-number tests and the poll-knob check a waiting verb reads its knobs
with, the trim bash's trim makes, the word split bash's read -r makes, the
atomic file write, the plain file write and append, the surrogateescape
stdout and stderr writes, the file read as bash's
$(<file) gives it, the lines of a text and of a file, the markdown code-fence
rule, the temporary file a comment is handed to gh from, the words a list and
a state read as in a line, the orchestrator's directory name, the UTC stamp
a run directory is named with, the git exclude writer, the copy bash's cp
makes, the directory bash's mkdir -p makes, the removals bash's rm -f and
rm -rf make, the move of named files aside into a folder, every name
checked before the first move, as bash's move_files_aside makes it, and the
capture of a call's stderr and death that bash's capture
and err_line make.

Every `orch: ` message goes through die or warn, as in the bash side's
common.sh: die(message, 2) is the bash die2, for a command that reserves exit
1 for a meaningful "no". Both flush stdout first, so a line printed ahead of
the message comes ahead of it, as bash's unbuffered output does. Both build
the line with message_line, which a message handed on rather than printed -
the gh adapter's rate-limit failure - uses alone.
"""
from __future__ import annotations

import io
import os
import re
import shutil
import sys
import tempfile
import time
from contextlib import contextmanager, redirect_stderr
from typing import (Any, Callable, Iterable, Iterator, List, NoReturn, Optional, Sequence, Tuple,
                    Union)

# The directory every checkout keeps the orchestrator's own files in.
ORCH_DIR_NAME = ".orchestrator"
# The directories the plugin writes to and keeps out of git status: its own,
# and .scratch/, where planning drafts land.
EXCLUDED_DIRS = (ORCH_DIR_NAME + "/", ".scratch/")

# What the refusal of an unescaped @@ line inside a block adds: how a body
# line starting with @@ is written. The breakdown draft grammar's parser and
# the spec review grammars' block reader both append it.
AT_LINE_ESCAPE_HINT = " - a body line starting with @@ is written \\@@"


def is_at_line(line: str) -> bool:
    """Whether <line> is an @@ line: `@@`, or `@@ ` and more."""
    return line == "@@" or line.startswith("@@ ")


def without_cr(line: str) -> str:
    """<line> with one trailing CR dropped, if it has one."""
    return line[:-1] if line.endswith("\r") else line


def die(message: str, code: int = 1) -> NoReturn:
    """Prints `orch: <message>` on stderr and exits with <code>."""
    warn(message)
    sys.exit(code)


def warn(message: str) -> None:
    """die's line on stderr, without the exit."""
    sys.stdout.flush()
    stderr_write(message_line(message))


def message_line(message: str) -> str:
    """The `orch: <message>` line die and warn print, newline included, for a
    caller that hands the line on rather than printing it."""
    return "orch: " + message + "\n"


def stdout_write(text: str) -> None:
    """Writes <text> to stdout, bytes read through surrogateescape going back
    as they were."""
    _stream_write(sys.stdout, text)


def stderr_write(text: str) -> None:
    """Writes <text> to stderr as stdout_write writes stdout."""
    _stream_write(sys.stderr, text)


def _stream_write(stream, text: str) -> None:
    """Writes <text> to <stream> through its byte buffer, as UTF-8 with
    surrogateescape, after what its text layer holds; a stream with no
    buffer - a capture's StringIO - takes the text as it is."""
    buffer = getattr(stream, "buffer", None)
    if buffer is None:
        stream.write(text)
        return
    stream.flush()
    buffer.write(text.encode("utf-8", "surrogateescape"))
    buffer.flush()


def plain_number(text: str) -> bool:
    """Whether <text> is a plain number: one or more ASCII digits and nothing
    else, as bash's `''|*[!0-9]*` refusal reads one."""
    return text.isdigit() and text.isascii()


def plain_positive_number(text: str) -> bool:
    """Whether <text> is a plain number (plain_number) with no leading zero,
    as bash's `''|*[!0-9]*|0*` refusal reads one."""
    return plain_number(text) and not text.startswith("0")


# bash's [:space:], the characters trim drops.
_SPACE = " \t\n\r\v\f"


def trim(text: str) -> str:
    """<text> with leading and trailing whitespace removed, as bash's trim."""
    return text.strip(_SPACE)


# bash's default IFS, the characters `read` splits words on.
IFS = " \t\n"


def read_words(text: str, count: int) -> List[str]:
    """<text> split as bash's `read -r` splits a line into <count> names:
    a word each, separated by runs of spaces, tabs or newlines, the last name
    taking the rest, its trailing ones dropped. A name past the words is
    empty."""
    rest = text.strip(IFS)
    words = []
    for _ in range(count - 1):
        word = re.match(r"[^ \t\n]*", rest).group()
        words.append(word)
        rest = rest[len(word):].lstrip(IFS)
    words.append(rest)
    return words


_NUMBER = re.compile(r"[0-9]+\.?[0-9]*|\.[0-9]+")


def is_number(text: str) -> bool:
    """Whether <text> is a non-negative decimal number, as bash's is_number
    reads one: digits with at most one point, and not the point alone."""
    return _NUMBER.fullmatch(text) is not None


def is_positive_number(text: str) -> bool:
    """Whether <text> is a number (is_number) above zero: some character of
    it neither a zero nor the point."""
    return is_number(text) and text.strip("0.") != ""


def require_poll_knobs(knobs: Sequence[Tuple[str, str]]) -> None:
    """Dies unless every (name, value) of <knobs> holds a number and the
    last, the poll interval, one greater than zero, with bash's
    require_poll_knobs messages: a non-number would make a poll loop's
    comparisons meaningless, and a zero interval would poll as fast as it
    can."""
    for name, value in knobs:
        if not is_number(value):
            die("%s is not a number: %s" % (name, value))
    name, value = knobs[-1]
    if not is_positive_number(value):
        die("%s must be greater than zero: %s" % (name, value))


def file_write_atomic(path: str, text: str, make_directory: bool = True) -> bool:
    """Writes <text> to <path> through a temporary file beside it, renamed
    over it, its directory made first unless <make_directory> is False: a
    reader never sees half a file, and a failed write leaves the file as it
    was and no temporary file behind. Whether it succeeded - False, with
    <make_directory> False, when the directory is gone."""
    directory = os.path.dirname(path) or "."
    try:
        if make_directory:
            os.makedirs(directory, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", dir=directory)
    except OSError:
        return False
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(text.encode("utf-8", "surrogateescape"))
        os.replace(tmp, path)
    except OSError:
        rm_f(tmp)
        return False
    return True


def read_raw(path: str) -> Optional[str]:
    """The file's whole text, decoded as UTF-8 with surrogateescape so bytes
    that are not UTF-8 survive; None when it cannot be read."""
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "surrogateescape")
    except OSError:
        return None


def lines_of(text: str) -> List[str]:
    """<text>'s lines, a final newline ending the last rather than starting
    an empty one; none for empty text. Splits on newlines alone."""
    if not text:
        return []
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    return lines


def _run_of(text: str, char: str) -> int:
    """How many times <char> repeats at the start of <text>."""
    return len(text) - len(text.lstrip(char)) if char else 0


def fenced(lines: Iterable[str]) -> List[int]:
    """The one markdown code-fence rule, common.sh's FENCE_AWK, over <lines>
    in order: for each, 2 for a fence delimiter line (opening or closing), 1
    for a line inside a fence and 0 otherwise. A fence opens on a line whose
    first non-space character, after at most three spaces of indent, starts a
    run of at least three backticks or tildes; it closes only on a line that,
    with the same indent allowance, is a bare run of the same character at
    least as long. Each line's CR and trailing blanks are ignored."""
    states = []
    fence_char = ""
    fence_len = 0
    for line in lines:
        text = line.rstrip(" \t\r")
        indent = _run_of(text, " ")
        if indent <= 3:
            text = text[indent:]
        char = text[:1]
        run = _run_of(text, char)
        if fence_char:
            if char == fence_char and run >= fence_len and run == len(text):
                fence_char = ""
                states.append(2)
            else:
                states.append(1)
        elif char in ("`", "~") and run >= 3:
            fence_char, fence_len = char, run
            states.append(2)
        else:
            states.append(0)
    return states


def file_lines(path: str) -> List[str]:
    """The lines of the file at <path> as bash's `read -r` loop reads them,
    a last line with no newline included; none when it cannot be read."""
    return lines_of(read_raw(path) or "")


def read_text(path: str) -> Optional[str]:
    """The file's text, its trailing newlines dropped as bash's $(<file)
    drops them; None when it cannot be read."""
    text = read_raw(path)
    return None if text is None else text.rstrip("\n")


def text_file_write(file: Union[str, int], text: str, unwritten: str) -> None:
    """Writes <text> to <file> - a path, or an open descriptor it closes -
    as UTF-8, surrogateescape, so bytes read that way go back as they were.
    Dies with <unwritten> when it cannot be written."""
    try:
        with open(file, "wb") as f:
            f.write(text.encode("utf-8", "surrogateescape"))
    except OSError:
        die(unwritten)


def text_file_append(path: str, text: str, unappended: str) -> None:
    """Appends <text> and a newline to the file at <path>, made where it is
    missing, as UTF-8, surrogateescape, as text_file_write writes. Dies with
    <unappended> when it cannot be appended."""
    try:
        with open(path, "ab") as f:
            f.write((text + "\n").encode("utf-8", "surrogateescape"))
    except OSError:
        die(unappended)


def copy_or_die(source: str, target: str, uncopied: str) -> None:
    """cp <source> <target>: the file's bytes copied over whatever <target>
    held. Dies with <uncopied> when it cannot be copied."""
    try:
        shutil.copyfile(source, target)
    except OSError:
        die(uncopied)


def mkdir_p_or_die(path: str, unmade: str) -> None:
    """mkdir -p <path>: the directory and any missing parents made, one
    already there no failure. Dies with <unmade> when it cannot be made."""
    try:
        os.makedirs(path, exist_ok=True)
    except OSError:
        die(unmade)


def rm_f(path: str) -> None:
    """rm -f <path>, its failure ignored."""
    try:
        os.remove(path)
    except OSError:
        pass


def rm_f_or_die(path: str, unremoved: str) -> None:
    """rm -f <path>: nothing there is no failure; dies with <unremoved>
    when something there cannot be removed."""
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    except OSError:
        die(unremoved)


def rm_rf_or_die(path: str, unremoved: str) -> None:
    """rm -rf <path>: a link or a file removed, a directory with all it
    holds; nothing there is no failure. Dies with <unremoved> when it
    cannot."""
    try:
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        elif os.path.lexists(path):
            os.remove(path)
    except OSError:
        die(unremoved)


def move_files_aside(directory: str, dest: str, what: str, names: Sequence[str]) -> None:
    """Moves each of <names> that exists in <directory> into exactly <dest>,
    made only when there is something to move - bash's move_files_aside.
    A <dest> already holding one of them is refused, naming <what>, before
    any move; a <dest> that merely exists is fine. Dies, too, when <dest>
    cannot be made or a file cannot be moved, where bash's mkdir or mv
    stops it."""
    if not any(os.path.exists(os.path.join(directory, name)) for name in names):
        return
    if any(os.path.exists(os.path.join(dest, name)) for name in names):
        die("%s already holds %s - refusing to overwrite it" % (dest, what))
    mkdir_p_or_die(dest, "could not create " + dest)
    for name in names:
        source = os.path.join(directory, name)
        if os.path.exists(source):
            try:
                shutil.move(source, os.path.join(dest, name))
            except OSError:
                die("could not move %s into %s" % (source, dest))


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
        text_file_write(fd, text, unwritten)
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


# bash's tr '[:upper:]' '[:lower:]', which lowercases ASCII letters alone.
_ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")
# A run of anything but a slug's characters, one hyphen in a slug.
_SLUG_SEPARATORS = re.compile(r"[^a-z0-9]+")


def normalize_slug(text: str) -> str:
    """The one normalisation a slug gets, as the bash copy in common.sh makes
    it: ASCII letters lowercased, each run of anything but a-z and 0-9 one
    hyphen, hyphens trimmed. Like bash's sed it reads <text> a line at a time,
    so a newline survives, and trailing newlines go as $(...) drops them. Dies
    when nothing survives."""
    lines = [_SLUG_SEPARATORS.sub("-", line.translate(_ASCII_LOWER)).strip("-")
             for line in text.split("\n")]
    slug = "\n".join(lines).rstrip("\n")
    if not slug:
        die("slug is empty after normalisation")
    return slug


def dir_stamp(clock: Callable[[], float] = time.time) -> str:
    """The time <clock> reads, in UTC, as a directory name's stamp:
    %Y%m%d-%H%M%S."""
    return time.strftime("%Y%m%d-%H%M%S", time.gmtime(clock()))


def _exclude_file(git) -> str:
    """The clone's shared info/exclude, under the common directory the git
    adapter <git> reads - the only one git reads, so a linked worktree writes
    it too. Under "" when the read fails, as the bash writer's is."""
    return (git.git_common_dir() or "") + "/info/exclude"


def exclude_orch_dirs(git) -> None:
    """Keeps every EXCLUDED_DIRS entry out of git status through the clone's
    shared info/exclude, never a tracked .gitignore, read through the git
    adapter <git>; dies as exclude_line does."""
    exclude_line(EXCLUDED_DIRS, git)


def exclude_line(lines: Sequence[str], git) -> None:
    """Makes each of <lines> a line of the clone's shared info/exclude,
    through the git adapter <git>: appends those exclude_missing finds absent,
    making the file's directory first and ending an unterminated last line
    first, so the first line added is never glued onto the user's pattern.
    Does nothing when none is missing; dies naming the missing lines and the
    file when the write fails."""
    missing = exclude_missing(lines, git)
    if not missing:
        return
    path = _exclude_file(git)
    added = "".join(line + "\n" for line in missing).encode("utf-8", "surrogateescape")
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a+b") as f:
            end = f.seek(0, os.SEEK_END)
            if end:
                f.seek(end - 1)
                if f.read(1) != b"\n":
                    added = b"\n" + added
            f.write(added)
    except OSError:
        die("cannot add %s to the git exclude file %s" % (list_join(missing), path))


def exclude_missing(lines: Sequence[str], git) -> List[str]:
    """Each of the non-empty <lines> the clone's shared info/exclude, read
    through the git adapter <git>, lacks as a whole line, in order: every one
    when the file cannot be read."""
    text = read_raw(_exclude_file(git))
    present = set() if text is None else set(text.split("\n"))
    return [line for line in lines if line and line not in present]


def capture(call: Callable[[], Any]) -> Tuple[Any, str, int]:
    """bash's capture: runs <call> with its stderr taken, a death included -
    (its answer, or None when it died; its stderr, byte for byte; 0, or the
    exit it died with). For a caller that words a callee's failure as its
    own, its message quoted through err_line."""
    err = io.StringIO()
    try:
        with redirect_stderr(err):
            answer = call()
    except SystemExit as died:
        code = died.code if isinstance(died.code, int) else 1
        return None, err.getvalue(), code
    return answer, err.getvalue(), 0


def err_line(err: str) -> str:
    """A captured error's first line, everything through its first `orch: `
    dropped, for quoting inside a message of our own."""
    head, found, rest = err.partition("orch: ")
    return (rest if found else head).split("\n", 1)[0]
