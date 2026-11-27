"""The wait concept's module, as far as a converted re-callable command
(ADR-0065) needs it: the block a call waits at most, ORCH_WAIT_BLOCK seconds
(default 570, under a host tool call's 600), and the line a call ends on when
its block is spent with no outcome, as the bash side's wait.sh spells them;
and the stored total of a re-callable wait (GLOSSARY.md) that polls against
a total counted from its first call, as wait.sh keeps it.

The stored total is the file $ORCH/wait/<key>, <key> the git blob hash of the
text naming the wait, holding two lines: the epoch second of the first call,
and the seconds slept so far across every call. What has elapsed is the
larger of that and the wall clock since the first call, in whole seconds, so
a sub-second interval still advances. Beside it sits its ".limited" mark,
which forget removes with it. The golden files of tests/wait/ pin the two
copies' reading and advancing of it to each other (ADR-0067).

A GitHub rate limit met inside a re-callable wait is wait.sh's too: the
open wait (OpenWait) decides whether a limit wait fits in what is left of
the block, and when it does not, sleeps the rest and leaves its mark, which
the wait's check then ends the call on as still running. The stored total
is one open wait; the provisional guard (Guard), "pending-<name>.limited"
under the wait folder, is the other, for a read made before the wait's key
is known, and ends the call storing no total. gh.py's Limits asks the open
wait it is handed.
"""
from __future__ import annotations

import hashlib
import os
import time
from typing import Callable, Mapping, Optional

from orch.common import die, file_lines, file_write_atomic, is_number, plain_number
from orch.common import mkdir_p_or_die, require_poll_knobs, rm_f, warn

# A call's block in seconds when ORCH_WAIT_BLOCK is unset or empty.
WAIT_BLOCK_DEFAULT = "570"

# The exit of a call whose block ended with its wait not over.
STILL_RUNNING = 75


def wait_block(env: Mapping[str, str], code: int = 1) -> str:
    """ORCH_WAIT_BLOCK as <env> sets it, else its default, checked as a poll
    knob, wait_block_check: its text, as the still-running line names it. A
    bad value dies exit <code>, 2 for a command that dies through die2."""
    block = env.get("ORCH_WAIT_BLOCK", "") or WAIT_BLOCK_DEFAULT
    require_poll_knobs([("ORCH_WAIT_BLOCK", block)], code)
    return block


def still_running(block: str) -> int:
    """Says on stderr that the call's wait is not over, after <block>
    seconds: STILL_RUNNING, the exit for the caller to end with."""
    warn("still running after %ss - run the same command again" % block)
    return STILL_RUNNING


def blob_hash(text: str) -> str:
    """The git blob hash of <text>, as `git hash-object --stdin` prints it
    in a SHA-1 repository, with no git call; UnicodeEncodeError for text
    no byte string spells, a lone surrogate."""
    data = text.encode("utf-8", "surrogateescape")
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def _awk_number(value: float) -> str:
    """<value> as awk prints a computed number: an integer as one, any
    other through OFMT, %.6g."""
    return "%d" % value if value == int(value) else "%.6g" % value


class OpenWait:
    """What a call's open re-callable wait holds for a GitHub rate limit met
    inside it: its ".limited" mark (wait.sh's WAIT_MARK), the block, and the
    call's start (WAIT_CALL_START) the block is measured from. <clock> and
    <sleep> are the time and the sleep a test hands in. The gh adapter's
    Limits asks limit_fits before it waits a limit out."""

    def __init__(self, mark: str, block: str, clock: Callable[[], float],
                 sleep: Callable[[float], None], call_start: int) -> None:
        self.mark = mark
        self.block = block
        self.clock = clock
        self.sleep = sleep
        self.call_start = call_start

    def _elapsed(self, start: int, slept: str) -> float:
        """wait_elapsed: the larger of the wall clock since <start> and
        <slept>."""
        return max(float(int(self.clock()) - start), float(slept))

    def limit_fits(self, seconds: float) -> bool:
        """wait_limit_fits <seconds>: whether a limit wait of <seconds> fits
        in what is left of the block. When it does not, sleeps the rest of
        the block, leaves the mark (an unwritable one not checked) and
        answers False, for the call to end as still running."""
        spent = self._elapsed(self.call_start, "0")
        left = float(_awk_number(min(seconds, float(self.block) - spent)))
        if not left < seconds:
            return True
        if 0 < left:
            self.sleep(left)
        try:
            with open(self.mark, "w"):
                pass
        except OSError:
            pass
        return False

    def _marked(self) -> bool:
        """Whether a limit left the mark, consuming it."""
        if not os.path.exists(self.mark):
            return False
        rm_f(self.mark)
        return True


class Guard(OpenWait):
    """The provisional guard of a read that runs before the wait's key is
    known, wait.sh's wait_guard: its mark is "pending-<name>.limited" under
    the wait folder, and no total is stored."""

    @classmethod
    def open(cls, orch_dir: str, name: str, block: str,
             clock: Callable[[], float] = time.time,
             sleep: Callable[[float], None] = time.sleep) -> "Guard":
        """wait_guard <name>: the guard opened, the wait folder under
        <orch_dir> made and any old mark cleared."""
        call_start = int(clock())
        folder = orch_dir + "/wait"
        mkdir_p_or_die(folder, "could not create " + folder)
        guard = cls("%s/pending-%s.limited" % (folder, name), block, clock, sleep, call_start)
        rm_f(guard.mark)
        return guard

    def check(self) -> bool:
        """wait_guard_check: False, the mark consumed, when a limit the block
        could not hold left it - for the caller to end on still_running,
        storing nothing; True otherwise."""
        return not self._marked()


class StoredTotal(OpenWait):
    """An open wait's stored total: wait.sh's WAIT_FILE, WAIT_MARK (the
    file's ".limited" mark), WAIT_START, WAIT_SLEPT and WAIT_BLOCKED, the
    call's start its WAIT_CALL_START. <block> is ORCH_WAIT_BLOCK's checked
    text, <clock> and <sleep> the time and the sleep a test hands in."""

    def __init__(self, path: str, start: str, slept: str, block: str,
                 clock: Callable[[], float], sleep: Callable[[float], None],
                 call_start: int) -> None:
        super().__init__(path + ".limited", block, clock, sleep, call_start)
        self.file = path
        self.start = start
        self.slept = slept
        self.blocked = "0"

    @classmethod
    def open(cls, orch_dir: str, key: str, block: str,
             clock: Callable[[], float] = time.time,
             sleep: Callable[[float], None] = time.sleep,
             call_start: Optional[int] = None) -> "StoredTotal":
        """wait_open: finds or creates the stored total for the wait <key>
        names under <orch_dir>/wait, a total whose lines are not numbers
        started afresh - 0 slept from now - and stored at once. The call's
        block is measured from <call_start>, a guard's opened before it,
        else from now. Dies when the key, the folder or the total cannot be
        made."""
        if call_start is None:
            call_start = int(clock())
        try:
            hashed = blob_hash(key)
        except UnicodeEncodeError:
            die("could not key the wait")
        folder = orch_dir + "/wait"
        mkdir_p_or_die(folder, "could not create " + folder)
        path = "%s/%s" % (folder, hashed)
        lines = file_lines(path) if os.path.isfile(path) else []
        start = lines[0] if lines else ""
        slept = lines[1] if len(lines) > 1 else ""
        fresh = not plain_number(start) or not is_number(slept)
        if fresh:
            start, slept = "%d" % int(clock()), "0"
        total = cls(path, start, slept, block, clock, sleep, call_start)
        if fresh:
            total._store()
        return total

    def taken(self) -> float:
        """wait_taken: the open wait's elapsed time."""
        return self._elapsed(int(self.start), self.slept)

    def forget(self) -> None:
        """wait_forget: the stored total and its mark removed, once a call
        delivers an outcome."""
        for path in (self.file, self.mark):
            rm_f(path)

    def _spent(self) -> float:
        """wait_block_spent: what this call has blocked."""
        return self._elapsed(self.call_start, self.blocked)

    def _store(self) -> bool:
        """wait_store_and_exit's store, and open's of a fresh total: the
        start and the seconds slept written to the file, then False, for
        tick's caller to end the call as still running; dies when the total
        cannot be stored."""
        if not file_write_atomic(self.file, "%s\n%s\n" % (self.start, self.slept)):
            die("could not store the wait")
        return False

    def limited_check(self) -> bool:
        """wait_limited_check: False, the mark consumed and the total
        stored, when a limit the block could not hold left the mark - for
        the caller to end on still_running; True otherwise. Called after
        each probe of a poll loop."""
        return self._store() if self._marked() else True

    def tick(self, interval: str) -> bool:
        """wait_tick <interval>: one turn of a poll loop's wait. True once
        it slept <interval>, or what is left of the block when that is less,
        adding it to the seconds slept; False, the total stored, when the
        call has blocked its block - before the sleep or by it - for the
        caller to end on still_running."""
        block = float(self.block)
        spent = self._spent()
        if not spent < block:
            return self._store()
        nap = _awk_number(min(float(interval), block - spent))
        self.sleep(float(nap))
        self.slept = "%.3f" % (float(self.slept) + float(nap))
        self.blocked = "%.3f" % (float(self.blocked) + float(nap))
        if not self._spent() < block:
            return self._store()
        return True
