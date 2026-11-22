"""The spec concept's module (scripts/orch/spec.sh), kept to the round
directory the spec-review noun works in: the files saying where a spec review
round stands, the working-directory reset, what a round hands the next, and
the round count's parse.

The bash spec module stays the round directory's owner while bash `spec`
reads it (`spec round`, `spec round-dir`): these are copies of its
spec_round_* functions under their bash names, each keeping bash's messages
and the order of its local steps. The golden round directories of
tests/spec_round/ pin the two copies of spec_round_state to each other
(ADR-0067). The saved answer's writers and its loader left bash with the
spec-review noun, and bash spec_round_state only checks that apply-answer
exists, so the golden line bash wrote before its writer went,
tests/spec_round/answer/bash-written, is the bash side of the saved-answer
format, which a round that died under bash still resumes by.

The saved answer (apply-answer) is one shell-quoted line, as bash's `printf
%q` writes it: spec_round_answer_save writes each word with shlex.quote, and
spec_round_answer_load reads it with shlex.split. That reads every line bash
writes but one holding control characters, which %q writes as $'...' and
shlex.split would read as a literal $ and the quoted text: such a line is
refused, as unreadable.
"""
from __future__ import annotations

import glob
import os
import shlex
import shutil
from typing import List, Sequence, Tuple

from orch.common import (ORCH_DIR_NAME, die, plain_positive_number, read_raw, rm_f_or_die,
                         rm_rf_or_die, text_file_write)

# The empty file spec_round_complete writes in a round's directory, as its
# last local step but the answer's clearing: a round counts as complete only
# when its directory holds it.
ROUND_COMPLETE = "round-complete"
# The held-back fundamental items of an autopilot round, written by
# spec_round_hold (spec_round_complete removes it): while it exists the round
# waits for the human's answer.
ROUND_FUNDAMENTAL = "fundamental.md"
# The saved answer of an apply that is running or died in the round's
# directory, written by spec_round_answer_save and cleared by
# spec_round_answer_clear: while it exists the round is applying.
ROUND_APPLY_ANSWER = "apply-answer"
# The file every round's changelog is appended to, read by the next round's
# lenses.
ROUND_SETTLED = "settled.md"
# What a round hands the next: the Implementability lens's code map and the
# settled file, kept by spec_round_dir_reset's carry.
ROUND_CARRIED = ("map-implementability.md", ROUND_SETTLED)
# Where a flow's spec review rounds work, under the orchestrator directory.
ROUNDS_DIR_NAME = "spec-rounds"


def spec_rounds_dir(root: str) -> str:
    """The flow's rounds directory of the checkout at <root>."""
    return "%s/%s/%s" % (root, ORCH_DIR_NAME, ROUNDS_DIR_NAME)


def spec_round_state(directory: str) -> str:
    """The round's state: `applying` while <directory> holds the saved apply
    answer, else `waiting` while it holds fundamental.md, else `open` while it
    holds no round-complete, else `complete`. A missing <directory> is
    open."""
    if os.path.exists(os.path.join(directory, ROUND_APPLY_ANSWER)):
        return "applying"
    if os.path.exists(os.path.join(directory, ROUND_FUNDAMENTAL)):
        return "waiting"
    if not os.path.exists(os.path.join(directory, ROUND_COMPLETE)):
        return "open"
    return "complete"


def spec_round_held(directory: str) -> bool:
    """Whether <directory> holds fundamental.md, the items an autopilot round
    held back - apart from the state, as a resumed apply of a held round is
    `applying` and held at once."""
    return os.path.exists(os.path.join(directory, ROUND_FUNDAMENTAL))


def spec_round_answer_name() -> str:
    """The saved answer's file name, for a caller's message that names it."""
    return ROUND_APPLY_ANSWER


def spec_round_answer_save(
        directory: str, file_options: Sequence[str], args: Sequence[str]) -> None:
    """apply's answer arguments <args> saved to <directory>/apply-answer, one
    shell-quoted line, before the first GitHub write. The argument after each
    of <file_options> is a file, copied into <directory> as
    apply-<option>.copy first and saved as the copy, so a resume never reads a
    file the dead session left elsewhere."""
    saved = []
    file_option = ""
    for arg in args:
        if file_option:
            copy = "%s/apply-%s.copy" % (directory, file_option[2:] if file_option.startswith("--")
                                         else file_option)
            try:
                shutil.copyfile(arg, copy)
            except OSError:
                die("could not copy %s to %s - nothing written to GitHub" % (arg, copy))
            saved.append(copy)
            file_option = ""
            continue
        saved.append(arg)
        if arg in file_options:
            file_option = arg
    line = "".join(shlex.quote(word) + " " for word in saved) + "\n"
    path = "%s/%s" % (directory, ROUND_APPLY_ANSWER)
    text_file_write(path, line, "could not write %s - nothing written to GitHub" % path)


def _ansi_c_quoted(line: str) -> bool:
    """Whether a word of <line> starts with an unquoted $' - the ANSI-C
    quoting bash's %q writes for a word holding control characters, and for
    nothing else, since it writes a literal $ as \\$."""
    quote = ""
    escaped = False
    word_start = True
    for i, char in enumerate(line):
        if escaped:
            escaped, word_start = False, False
            continue
        if quote == "'":
            if char == "'":
                quote = ""
            continue
        if quote == '"':
            if char == "\\":
                escaped = True
            elif char == '"':
                quote = ""
            continue
        if char in " \t\n":
            word_start = True
            continue
        if word_start and char == "$" and line[i + 1:i + 2] == "'":
            return True
        word_start = False
        if char == "\\":
            escaped = True
        elif char in "'\"":
            quote = char
    return False


def spec_round_answer_load(directory: str) -> List[str]:
    """The saved answer's arguments; dies when the file is unreadable, or
    holds a line shlex.split cannot read as bash would."""
    path = "%s/%s" % (directory, ROUND_APPLY_ANSWER)
    unreadable = "%s is unreadable - rerun the round" % path
    text = read_raw(path) if not os.path.isdir(path) else None
    if text is None or _ansi_c_quoted(text):
        die(unreadable)
    try:
        return shlex.split(text)
    except ValueError:
        die(unreadable)


def _remove(path: str) -> bool:
    """rm -f <path>: whether nothing is left there - true when there was
    nothing; a directory is left, as rm without -r leaves it."""
    if not os.path.lexists(path):
        return True
    if os.path.isdir(path) and not os.path.islink(path):
        return False
    try:
        os.remove(path)
    except OSError:
        return False
    return True


def spec_round_answer_clear(directory: str, landed: str) -> None:
    """The saved answer and its file copies removed, at the end of the run
    that no resume continues. <landed> names the GitHub writes that landed,
    for the message."""
    paths = [os.path.join(directory, ROUND_APPLY_ANSWER)]
    paths += sorted(glob.glob(os.path.join(glob.escape(directory), "apply-*.copy")))
    removed = [_remove(path) for path in paths]
    if not all(removed):
        die("could not remove %s/%s - every GitHub write landed: %s"
            % (directory, ROUND_APPLY_ANSWER, landed))


def spec_round_hold(directory: str, blocks: str) -> None:
    """The end of an autopilot round's first run - the held-back fundamental
    items' <blocks> written, byte for byte, to <directory>/fundamental.md: the
    round's save point, which the round's state reads as waiting."""
    path = "%s/%s" % (directory, ROUND_FUNDAMENTAL)
    text_file_write(path, blocks, "could not write %s - nothing written to GitHub" % path)


def _ends_with(path: str, log: str) -> bool:
    """Whether the file at <path> ends with <log> and a newline, as bash's
    `$(tail -c <n>)` compares it, its trailing newlines dropped; false when
    it cannot be read."""
    want = (log + "\n").encode("utf-8", "surrogateescape")
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return False
    return data[-len(want):].rstrip(b"\n") == log.encode("utf-8", "surrogateescape")


def spec_round_complete(directory: str, log: str, landed: str) -> None:
    """The round's local tail once its changelog comment landed, safe to run
    again: <log> appended to settled.md unless it already ends with it, then
    fundamental.md removed, round-complete written, the saved answer
    cleared. <landed> names the GitHub writes, for the messages."""
    settled = "%s/%s" % (directory, ROUND_SETTLED)
    if not os.path.isfile(settled) or not _ends_with(settled, log):
        try:
            with open(settled, "ab") as f:
                f.write((log + "\n").encode("utf-8", "surrogateescape"))
        except OSError:
            die("could not append the changelog to %s - every GitHub write landed: %s"
                % (settled, landed))
    appended = "every GitHub write landed and settled.md is appended: " + landed
    fundamental = "%s/%s" % (directory, ROUND_FUNDAMENTAL)
    rm_f_or_die(fundamental, "could not remove %s - %s" % (fundamental, appended))
    marker = "%s/%s" % (directory, ROUND_COMPLETE)
    text_file_write(marker, "", "could not write %s - %s" % (marker, appended))
    spec_round_answer_clear(directory, landed)


def spec_round_in_flow(directory: str, rounds: str) -> bool:
    """Whether <directory> is under the flow's rounds directory <rounds>, at
    any depth - a flow's round directory, not a standalone review's."""
    path = (directory[:-1] if directory.endswith("/") else directory) + "/"
    return path.startswith(rounds + "/") and len(path) > len(rounds) + 1


def spec_round_dir_reset(directory: str, carry: bool = False) -> None:
    """A round's working directory made ready to run in, for a standalone
    review's begin - a copy of the reset a flow's `spec round-dir` runs, bash
    spec_round_dir_reset. With <carry>, every entry of an existing
    <directory> but the code map and the settled file is deleted in place,
    keeping what a round hands the next; without it <directory> is removed
    whole. Either way it is then created when missing. Dies naming the
    directory when it cannot, where bash's rm, find or mkdir gave its own
    error."""
    unreset = "could not reset the round directory %s" % directory
    if carry and os.path.isdir(directory):
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            die(unreset)
        for name in names:
            if name not in ROUND_CARRIED:
                rm_rf_or_die(os.path.join(directory, name), unreset)
    else:
        rm_rf_or_die(directory, unreset)
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError:
        die(unreset)


def spec_round_count_parse(arg: str) -> Tuple[int, int]:
    """A round and the round count, `<k>/<n>`, two positive whole numbers
    with k no greater than n; dies otherwise."""
    want = ("want <k>/<n>, a round and the round count, two positive whole numbers, got: %s"
            % arg)
    if "/" not in arg:
        die(want)
    k, n = arg.split("/", 1)
    if not plain_positive_number(k) or not plain_positive_number(n):
        die(want)
    if int(k) > int(n):
        die("round %s is past the round count %s" % (k, n))
    return int(k), int(n)
