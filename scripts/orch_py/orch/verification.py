"""orch.sh's verification noun (ADR-0067): a shell command line run detached
from the call that started it and waited for in bounded calls (a re-callable
command, ADR-0065).

run(argv) takes the arguments after `verification`, as orch.sh hands them on,
and returns the exit code; a usage error or a failure dies through
orch.common.die, exit 1. Both verbs keep the bash noun's usage lines, stdout,
exit codes and `orch:` messages.

The noun's terms:

- A **run** is one command line in one checkout, run by `bash -c` with the
  checkout as its directory.
- The **store** is the main checkout's .orchestrator/verification/: one
  directory per run, its **record**, named by the object name of the
  checkout's root, its identity token and the command. A record holds root
  and id (the checkout and its token), state (the working-tree state the run
  began on: the git adapter's tree_state), pid (the runner's liveness record,
  `<pid> <start-time>`), out, err, status (written once the run ends) and
  overrun (the ceiling, for a run stopped at it). A record is built whole in
  a dot-named temporary directory in the store and renamed into place, so no
  call sees one without its state, and no lookup or sweep takes the
  temporary directory for a record. The bash noun's grace marks (termed,
  killed, waiting) are never written; in a record a bash runner left they are
  ignored, but that a termed record with no status is stopped by its process
  group even when its leader is dead.
- A checkout's **identity token**, in its own .orchestrator/verification/id,
  is made once: a checkout removed and made again at the same path has none,
  so it is another checkout.
- The **runner** is a Python process the call starts in a session and process
  group of its own, through RUNNER_BOOTSTRAP, a copy of orch.sh's
  orch_python bootstrap that runs this module as __main__ - no noun table,
  verb or help reaches that entry point. It starts the command in its own
  group, so the record's pid names the group that holds both, then ignores
  TERM, so a TERM to the group stops the command and the runner sees it end.
  It waits on the command, never reading its record to decide it is done,
  writes status, and exits; so removing the record, by whoever, never keeps
  it alive. It writes each file to a temporary name inside its record and
  renames it, never making the directory: when the record is gone the write
  fails and the runner exits. When its checkout is already gone it cannot
  start the command, and removes its record and exits.
- The **checkout watch** is the runner's wait on its command, timing out every
  watch interval (ORCH_VERIFICATION_WATCH, default 2 s): after each timeout it
  checks that its checkout root still exists and that the checkout's identity
  token still holds the record's id as the runner read it at its start, kept
  in memory, so a record removed mid-run never reads as a changed token. When
  either check fails, it sends TERM to the group, waits the grace, removes its
  own record, then sends KILL to the group, which ends the runner too: no call
  will ever deliver to a gone checkout, so no verification process outlives
  the checkout it ran in, however the checkout was removed.
- The **ceiling** is git config orchestrator.verification.timeout (default
  3600 s), the runner's own timer on its wait: at the ceiling it sends TERM to
  the group, waits the grace (ORCH_VERIFICATION_GRACE, default 5 s), writes
  overrun and status 1, then sends KILL to the group, which ends the runner
  too; a failed write never skips that KILL. The next call delivers it as
  failed.
- The **orphan sweep**, at the start of every `run`, clears the records of
  checkouts that no longer exist or were made again at their path, stopping a
  live run there first, and removes a temporary directory, or a record still
  with no pid and no status, more than a minute old by its directory's mtime:
  both are left by a call that died partway.

A call blocks ORCH_WAIT_BLOCK seconds (default 570), looking for status every
ORCH_VERIFICATION_INTERVAL seconds (default 0.2). A run that finishes inside
the call is delivered whole, with its status - a command's own 75 as 1 - and
its record removed once printed; one still going leaves stdout empty, says so
on stderr and exits 75, and the same line run again attaches to it. A live
run or a finished result whose state no longer matches is stale: the result
is discarded, the live run stopped and a fresh one started. A record with no
pid and no status, made under a minute ago, is a run still starting: a
matching one is waited on as a live one; a stale one is waited on for its pid,
within the block, then stopped as any stale live run, so its runner is never
left going once its record is removed - a call whose block is spent first
exits 75. One whose runner died leaving no status is removed, and a call
waiting on it dies. A run of another command is left alone. A call that
starts a runner but cannot record its pid sends KILL to its group, as a start
that failed rather than a stop, so no grace; then it removes its record and
dies naming the failure: no record is left without a pid under a live runner.

Every stop - TERM, a grace, KILL to the survivors, a grace - finishes inside
the call that began it, in batches: a `run` stops in at most two (the orphan
sweep's, then a stale run of its own command), `stop` in one, and that time
counts against the block. Process groups are signalled with os.killpg, so no
setsid binary is needed. A runner stays its starter's child until reaped, so
every runner this process starts is kept in RUNNERS and polled before any
liveness or group check: one that ended is never counted alive as a zombie.

`verification stop <checkout>` stops every live run whose checkout root is
<checkout> or one of its ticket worktrees and removes its record, waiting
first, within the block, for the pid of each run still starting; a finished
run's record and another checkout's runs are left, and a group surviving the
KILL keeps its record and makes the call exit 1 after the other runs.
"""
from __future__ import annotations

import os
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from subprocess import DEVNULL, Popen
from typing import Dict, List, Mapping, Optional, Sequence, Set

import orch
from orch.checkout import main_checkout_or_die, ticket_path
from orch.common import (
    ORCH_DIR_NAME,
    die,
    file_write_atomic,
    is_positive_number,
    mkdir_p_or_die,
    plain_number,
    read_text,
    require_poll_knobs,
    warn,
)
from orch.git import Git
from orch.liveness import record_alive, record_of, record_pid
from orch.root import checkout_root
from orch.wait import still_running, wait_block

# The verbs, each a Verification method of its name. docs_lint.sh reads this
# line as the verbs the noun dispatches, so it stays one `OPS = "<verb>|..."`
# line.
OPS = "run|stop"

USAGE = "usage: orch.sh verification run <command> | stop <checkout>"
RUN_USAGE = "usage: orch.sh verification run <command>"
STOP_USAGE = "usage: orch.sh verification stop <checkout>"

# The knobs' defaults: the grace a stopped group has after TERM, and after
# KILL, how often a waiting call looks for status, and how often a runner
# watches its checkout, in seconds.
GRACE_DEFAULT = "5"
INTERVAL_DEFAULT = "0.2"
WATCH_DEFAULT = "2"

CEILING_KEY = "orchestrator.verification.timeout"
CEILING_DEFAULT = "3600"

# How old, in seconds, a temporary directory or a pid-less record is when the
# orphan sweep takes it for one a call left partway.
LEFTOVER_AGE = 60

# How often a stop looks whether its groups are gone, in seconds.
STOP_TURN = 0.05

ENDED = "the run ended without a status - run the same command again"

# The runner's start: orch.sh's orch_python bootstrap, running this module as
# __main__ in place of the package. It drops the empty entry -c puts first on
# sys.path, so nothing in the runner's directory shadows the package, and puts
# its first argument, the package directory (package_dir), first in its
# place: on sys.path, never PYTHONPATH, which splits a path holding a colon,
# so the command sees the call's own PYTHONPATH, as given.
RUNNER_BOOTSTRAP = '''
import sys
if sys.path and sys.path[0] == "":
    del sys.path[0]
sys.path.insert(0, sys.argv.pop(1))
import runpy
runpy.run_module("orch.verification", run_name="__main__", alter_sys=True)
'''

# The runners this process started, each kept until it is reaped.
RUNNERS: List[Popen] = []


def package_dir() -> str:
    """The directory holding the orch package this module was imported from,
    first on the runner's sys.path."""
    return os.path.dirname(os.path.dirname(os.path.abspath(orch.__file__)))


def reap_runners() -> None:
    """Reaps every runner of RUNNERS that has ended."""
    for runner in list(RUNNERS):
        if runner.poll() is not None:
            RUNNERS.remove(runner)


def group_there(group: int) -> bool:
    """Whether the process group <group> still exists, runners reaped
    first."""
    reap_runners()
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def groups_left(groups: Sequence[int], grace: float) -> List[int]:
    """Waits up to <grace> seconds for every group of <groups> to be gone:
    those still there."""
    deadline = time.monotonic() + grace
    while True:
        left = [group for group in groups if group_there(group)]
        now = time.monotonic()
        if not left or now >= deadline:
            return left
        time.sleep(min(STOP_TURN, deadline - now))


def signal_groups(groups: Sequence[int], sig: int) -> None:
    for group in groups:
        try:
            os.killpg(group, sig)
        except OSError:
            pass


def stop_batch(groups: Sequence[int], grace: float) -> Set[int]:
    """Stops every group of <groups> as one batch: TERM to each, a grace for
    all, KILL to the survivors, a grace for them. The groups still there."""
    if not groups:
        return set()
    signal_groups(groups, signal.SIGTERM)
    left = groups_left(groups, grace)
    if left:
        signal_groups(left, signal.SIGKILL)
        left = groups_left(left, grace)
    return set(left)


def record_read(d: str, name: str) -> Optional[str]:
    return read_text(os.path.join(d, name))


def record_has(d: str, name: str) -> bool:
    return os.path.isfile(os.path.join(d, name))


def record_write(d: str, name: str, text: str) -> bool:
    """Writes the record file atomically, never making the record: whether
    it was written."""
    return file_write_atomic(os.path.join(d, name), text, make_directory=False)


def record_remove(d: str) -> None:
    shutil.rmtree(d, ignore_errors=True)


def record_group(d: str) -> Optional[int]:
    """The process group the record names: its pid's; None when it names
    none it could signal alone."""
    pid = record_pid(record_read(d, "pid") or "")
    return pid if pid is not None and pid > 1 else None


def record_old(d: str, now: float) -> bool:
    """Whether the directory was last changed more than LEFTOVER_AGE seconds
    before <now>."""
    try:
        return now - os.stat(d).st_mtime > LEFTOVER_AGE
    except OSError:
        return False


class Verification:
    """The verbs, on the checkout at <root>, through the git adapter <git>,
    with the knobs <env> sets. The call's block counts from its making."""

    def __init__(self, git, env: Mapping[str, str], root: str) -> None:
        self.git = git
        self.env = env
        self.root = root
        self.started = time.monotonic()

    def begin(self) -> None:
        """The setup a verb that stops runs starts with: the block and the
        poll knobs checked, the store found."""
        self.block_text = wait_block(self.env)
        grace = self.env.get("ORCH_VERIFICATION_GRACE", "") or GRACE_DEFAULT
        interval = self.env.get("ORCH_VERIFICATION_INTERVAL", "") or INTERVAL_DEFAULT
        watch = self.env.get("ORCH_VERIFICATION_WATCH", "") or WATCH_DEFAULT
        require_poll_knobs(
            [("ORCH_VERIFICATION_GRACE", grace), ("ORCH_VERIFICATION_INTERVAL", interval)]
        )
        require_poll_knobs([("ORCH_VERIFICATION_WATCH", watch)])
        self.grace_text = grace
        self.watch_text = watch
        self.grace = float(grace)
        self.interval = float(interval)
        self.store = os.path.join(main_checkout_or_die(self.git), ORCH_DIR_NAME, "verification")

    def alive(self, d: str) -> bool:
        reap_runners()
        return record_alive(record_read(d, "pid") or "", self.env)

    def died(self, d: str) -> bool:
        """Whether the run in <d> died leaving no status: its pid record is
        no longer alive, and, read after that, it has no status."""
        return record_has(d, "pid") and not self.alive(d) and not record_has(d, "status")

    def stoppable(self, d: str) -> bool:
        """Whether the run in <d> has a group to stop: no status, a pid
        record, and either a live runner or a bash runner's termed mark (its
        leader may be dead, its group still there)."""
        return (
            not record_has(d, "status") and record_group(d) is not None
            and (record_has(d, "termed") or self.alive(d))
        )

    def starting(self, d: str) -> bool:
        """Whether the record <d> is a run still starting: no pid and no
        status yet, made under LEFTOVER_AGE seconds ago (an older one is a
        leftover of a call that died partway, the orphan sweep's)."""
        return (
            os.path.isdir(d) and not record_has(d, "pid") and not record_has(d, "status")
            and not record_old(d, time.time())
        )

    def still_starting(self, records: Sequence[str]) -> bool:
        """Waits, within the block, for every record of <records> still
        starting to have its pid, so its runner is stopped by its group, never
        left going once its record is removed: whether one is still starting
        when the block is spent."""
        while any(self.starting(d) for d in records):
            left = self.left()
            if left <= 0:
                return True
            time.sleep(min(self.interval, left))
        return False

    def left(self) -> float:
        """The seconds left of the call's block."""
        return float(self.block_text) - (time.monotonic() - self.started)

    def ceiling(self) -> str:
        value = self.git.config_value(CEILING_KEY) or CEILING_DEFAULT
        if not is_positive_number(value):
            die("%s is %s - it must be a positive number of seconds (git config %s <seconds>)"
                % (CEILING_KEY, value, CEILING_KEY))
        return value

    def identity(self) -> str:
        """This checkout's identity token, made the first time it is asked
        for."""
        path = token_path(self.root)
        token = read_text(path)
        if not token:
            if file_write_atomic(path, secrets.token_hex(20) + "\n"):
                token = read_text(path)
            if not token:
                die("could not record this checkout's identity in %s"
                    % os.path.join(self.root, ORCH_DIR_NAME))
        return token

    def clear_orphans(self) -> None:
        """The orphan sweep: one batch stops the live runs of checkouts that
        no longer exist, and their records go, a group surviving the KILL
        warned about by its process group; then the leftovers of calls that
        died partway go."""
        now = time.time()
        orphans: Dict[str, str] = {}
        for name in sorted(os.listdir(self.store)):
            d = os.path.join(self.store, name)
            if not os.path.isdir(d):
                continue
            root, token = record_read(d, "root"), record_read(d, "id")
            if name.startswith(".") or root is None or token is None:
                if record_old(d, now):
                    record_remove(d)
                continue
            if not checkout_holds(root, token):
                orphans[d] = root
            elif not (record_has(d, "pid") or record_has(d, "status")) and record_old(d, now):
                record_remove(d)
        groups = {d: record_group(d) for d in orphans if self.stoppable(d)}
        survivors = stop_batch(list(groups.values()), self.grace)
        for d, root in orphans.items():
            if groups.get(d) in survivors:
                warn("the run in %s (process group %d) could not be stopped - its record is"
                     " dropped, stop it by hand" % (root, groups[d]))
            record_remove(d)

    def run(self, args: List[str]) -> int:
        if len(args) != 1 or not args[0]:
            die(RUN_USAGE)
        command = args[0]
        self.begin()
        ceiling = self.ceiling()
        token = self.identity()
        state = self.git.tree_state()
        if state is None:
            die("could not read the working tree state")
        mkdir_p_or_die(self.store, "could not create %s" % self.store)
        self.clear_orphans()
        key = self.git.text_hash("root %s\nid %s\ncommand %s\n" % (self.root, token, command))
        if key is None:
            die("could not name the record of the run in %s" % self.store)
        d = os.path.join(self.store, key)
        while not self.attached(d, state) and not self.built(d, command, ceiling, token, state):
            pass
        return self.wait(d)

    def attached(self, d: str, state: str) -> bool:
        """Whether the call attaches to the record <d>: a live run, or one
        still starting, on <state>. A stale record, or one whose runner died
        leaving no status, is removed - a stale live run stopped first, the
        call dying when its group survives the KILL, and a stale run still
        starting waited on for its pid first, the call exiting 75 when its
        block is spent before it comes - and False answered, as for no
        record."""
        if not os.path.isdir(d):
            return False
        if record_read(d, "state") == state:
            if not self.died(d):
                return True
        elif self.still_starting([d]):
            sys.exit(still_running(self.block_text))
        elif self.stoppable(d):
            group = record_group(d)
            if stop_batch([group], self.grace):
                die("the stale run of this command (process group %d) could not be stopped"
                    " - stop it by hand" % group)
        record_remove(d)
        return False

    def built(self, d: str, command: str, ceiling: str, token: str, state: str) -> bool:
        """Builds the record <d> whole in a temporary directory, renames it
        into place and starts its runner. False when another call's record
        took the name first: the temporary directory is removed, for the
        call to attach to the winner."""
        try:
            tmp = tempfile.mkdtemp(prefix=".", dir=self.store)
        except OSError:
            die("could not create a record in %s" % self.store)
        for name, text in (("root", self.root), ("id", token), ("state", state)):
            if not record_write(tmp, name, text + "\n"):
                record_remove(tmp)
                die("could not write the record of the run in %s" % tmp)
        try:
            os.rename(tmp, d)
        except OSError:
            record_remove(tmp)
            if os.path.isdir(d):
                return False
            die("could not create the record of the run in %s" % d)
        self.start(d, command, ceiling)
        return True

    def start(self, d: str, command: str, ceiling: str) -> None:
        """Starts the record <d>'s runner and records its pid; when it cannot
        start, removes the record and dies naming the failure. A runner whose
        pid cannot be recorded is sent KILL by its group first, as no call
        could stop it later; when its record is already gone (its runner
        removed it, its checkout gone), the call goes on to wait, and so dies
        saying the run ended."""
        try:
            runner = Popen(
                [sys.executable, "-c", RUNNER_BOOTSTRAP, package_dir(), d,
                 command, ceiling, self.grace_text, self.watch_text],
                stdin=DEVNULL, stdout=DEVNULL, stderr=DEVNULL, start_new_session=True,
                env=dict(self.env), cwd="/",
            )
        except (OSError, subprocess.SubprocessError) as failed:
            record_remove(d)
            die("could not start the run in %s: %s" % (self.root, failed))
        RUNNERS.append(runner)
        record = record_of(runner.pid, self.env)
        if record is None or not record_write(d, "pid", record):
            signal_groups([runner.pid], signal.SIGKILL)
            if os.path.isdir(d):
                record_remove(d)
                die("could not start the run in %s: its runner's pid could not be recorded"
                    % self.root)

    def wait(self, d: str) -> int:
        """Waits for the run in <d> to end, until the block is spent: its
        delivery, or the still-running exit."""
        while True:
            reap_runners()
            if record_has(d, "status"):
                return self.deliver(d)
            if not os.path.isdir(d):
                die(ENDED)
            if self.died(d):
                record_remove(d)
                die(ENDED)
            left = self.left()
            if left <= 0:
                return still_running(self.block_text)
            time.sleep(min(self.interval, left))

    def deliver(self, d: str) -> int:
        """Prints the finished run's stdout and stderr whole and answers its
        status - 1, with an orch: line, for a command that itself exited 75
        and for a run stopped at the ceiling (naming the process group when
        it is still there after a grace) - then forgets the run, only once
        everything was printed."""
        status = record_read(d, "status") or ""
        overrun = record_read(d, "overrun")
        group = record_group(d)
        gone = True
        if overrun is not None and group is not None:
            # The runner's KILL ends the group an instant after it wrote the
            # status; waited for before anything is printed.
            gone = not groups_left([group], self.grace)
        streams = []
        for name in ("out", "err"):
            try:
                with open(os.path.join(d, name), "rb") as f:
                    streams.append(f.read())
            except OSError:
                die("could not read %s" % os.path.join(d, name))
        sys.stdout.flush()
        sys.stdout.buffer.write(streams[0])
        sys.stdout.buffer.flush()
        sys.stderr.flush()
        sys.stderr.buffer.write(streams[1])
        sys.stderr.buffer.flush()
        code = int(status) if plain_number(status) else 1
        if overrun is not None:
            if gone:
                warn("the run was still going after the ceiling of %ss (%s) and was stopped"
                     % (overrun, CEILING_KEY))
            else:
                warn("the run was still going after the ceiling of %ss (%s) and its process"
                     " group %d is left running - stop it by hand" % (overrun, CEILING_KEY, group))
            code = 1
        elif code == 75:
            warn("the command exited 75 - delivered as exit 1, its real status")
            code = 1
        record_remove(d)
        return code

    def stop(self, args: List[str]) -> int:
        if len(args) != 1 or not args[0]:
            die(STOP_USAGE)
        checkout = args[0][:-1] if args[0].endswith("/") else args[0]
        self.begin()
        named: Dict[str, str] = {}
        names = sorted(os.listdir(self.store)) if os.path.isdir(self.store) else []
        for name in names:
            d = os.path.join(self.store, name)
            root = record_read(d, "root")
            if name.startswith(".") or root is None or record_has(d, "status"):
                continue
            if root == checkout or ticket_path(root, checkout):
                named[d] = root
        self.still_starting(list(named))
        groups = {d: record_group(d) for d in named if self.stoppable(d)}
        survivors = stop_batch(list(groups.values()), self.grace)
        code = 0
        for d, root in named.items():
            if groups.get(d) in survivors:
                warn("the run in %s (process group %d) could not be stopped - stop it by hand"
                     % (root, groups[d]))
                code = 1
            else:
                record_remove(d)
        return code


def run(argv: List[str], git=None, env: Optional[Mapping[str, str]] = None) -> int:
    """`orch.sh verification <op> ...`: the real git adapter and the
    process's environment unless a test hands in others. Outside a checkout
    it dies first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    noun = Verification(git, env, checkout_root(git, env))
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die(USAGE)
    return getattr(noun, op)(argv[1:])


# --- the runner ---------------------------------------------------------------


def exit_status(code: int) -> int:
    """A waited command's exit status as bash's $? gives it: 128 plus the
    signal for one a signal ended."""
    return 128 - code if code < 0 else code


def token_path(root: str) -> str:
    """The path of the identity token of the checkout root <root>."""
    return os.path.join(root, ORCH_DIR_NAME, "verification", "id")


def checkout_holds(root: str, token: Optional[str]) -> bool:
    """The checkout watch's and the orphan sweep's check: whether the
    checkout root <root> still exists and its identity token still holds
    <token>."""
    return os.path.isdir(root) and read_text(token_path(root)) == token


def runner_main(argv: List[str]) -> int:
    """The runner, on the record <d>, the command, the ceiling, the grace and
    the watch interval its call hands it. The record's root and id are read
    once, at its start, so a record removed mid-run never reads as a changed
    token."""
    d, command, ceiling, grace, watch = argv
    root, token = record_read(d, "root"), record_read(d, "id")
    if root is None:
        return 1
    try:
        with open(os.path.join(d, "out"), "wb") as out, \
                open(os.path.join(d, "err"), "wb") as err:
            child = Popen(["bash", "-c", command], cwd=root, stdin=DEVNULL, stdout=out,
                          stderr=err)
    except OSError:
        record_remove(d)
        return 1
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    group = os.getpgrp()
    deadline = time.monotonic() + float(ceiling)
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            break
        try:
            code = child.wait(timeout=min(float(watch), left))
        except subprocess.TimeoutExpired:
            if not checkout_holds(root, token):
                # No call will ever deliver to a gone checkout: its record
                # goes before the KILL that ends this runner too.
                signal_groups([group], signal.SIGTERM)
                wait_grace(child, grace)
                try:
                    record_remove(d)
                finally:
                    signal_groups([group], signal.SIGKILL)
                return 1
            continue
        record_write(d, "status", "%d\n" % exit_status(code))
        return 0
    signal_groups([group], signal.SIGTERM)
    wait_grace(child, grace)
    try:
        if record_write(d, "overrun", ceiling + "\n"):
            record_write(d, "status", "1\n")
    finally:
        signal_groups([group], signal.SIGKILL)
    return 1


def wait_grace(child: Popen, grace: str) -> None:
    """Waits the grace for the command <child> to end after a TERM."""
    try:
        child.wait(timeout=float(grace))
    except subprocess.TimeoutExpired:
        pass


if __name__ == "__main__":
    sys.exit(runner_main(sys.argv[1:]))
