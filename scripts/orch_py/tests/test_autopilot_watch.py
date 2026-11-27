"""`orch.sh autopilot watch [--every <seconds>]`, run in-process through
autopilot.run in a FakeGit checkout whose git common directory is under
tmp_path: the host and settings gate it starts with, `--every`, the clone's
watch pidfile in liveness's record format (its process start read from a
fake /proc under ORCH_PROC_DIR), the refusal while another watch is alive
and a dead pidfile replaced, each tick a fresh `orch.sh autopilot tick` from
the fake process starter with a failed one warned, the sleep between ticks
from the fake sleep, INT and TERM during a tick and during the sleep, and
the pidfile removed on any other exit. Ported from the bash autopilot watch
section; the end-to-end checks through orch.sh are test_autopilot_cli.py's."""
from __future__ import annotations

import os
import signal
import subprocess

import pytest

from conftest import PROC_START as START, orch_autopilot, proc_add
from orch import autopilot
from orch.git import FakeGit

ORIGIN = "https://github.com/o/r.git"
MODE_KEY = "orchestrator.autopilot.permission-mode"
# The other watch's pid, its process started at START, as this process's is.
OTHER = 4321
TICK = [os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(autopilot.__file__))))), "scripts", "orch.sh"),
    "autopilot", "tick"]


@pytest.fixture
def env(proc, claude_bin):
    return {"ORCHESTRATOR_HOST": "claude", "PATH": str(claude_bin), "ORCH_PROC_DIR": str(proc)}


@pytest.fixture
def common(tmp_path):
    """The clone's git common directory."""
    path = tmp_path / "repo.git"
    path.mkdir()
    return path


@pytest.fixture
def pidfile(common):
    return common / "orchestrator" / "autopilot-watch.pid"


def checkout(root, common, mode="dontAsk"):
    git = FakeGit({"origin": ORIGIN}, toplevel=str(root),
                  local_config={} if mode is None else {MODE_KEY: mode})
    if common is not None:
        git.seed("git_common_dir", answer=str(common))
    return git


class Ended(Exception):
    """What a test's fake sleep raises to end the watch other than by a
    signal."""


class Tick:
    """A started tick: wait() runs <during> once, then answers <code>."""

    def __init__(self, code=0, during=None):
        self.code = code
        self.during = during
        self.waits = 0
        self.termed = False

    def wait(self):
        self.waits += 1
        if self.waits == 1 and self.during is not None:
            self.during()
        return self.code

    def terminate(self):
        self.termed = True


class Starter:
    """The fake process starter: hands out <ticks> in order, keeping each
    start's arguments."""

    def __init__(self, *ticks):
        self.ticks = list(ticks)
        self.starts = []

    def __call__(self, argv, **kwargs):
        self.starts.append((argv, kwargs))
        return self.ticks.pop(0)


class Sleep:
    """The fake sleep: keeps each wait's seconds, and runs the next of
    <steps> - raising Ended once they run out."""

    def __init__(self, *steps):
        self.steps = list(steps)
        self.waits = []

    def __call__(self, seconds):
        self.waits.append(seconds)
        if not self.steps:
            raise Ended()
        step = self.steps.pop(0)
        if step is not None:
            step()


def raising(signum):
    return lambda: signal.raise_signal(signum)


def watch(seed, git, env, starter, sleep, *args):
    """`orch.sh autopilot watch <args>` in-process: its exit code, a
    SystemExit's included."""
    return orch_autopilot(seed, git, env, "watch", *args, starter=starter, sleep=sleep)


# --- --every ---------------------------------------------------------------------


@pytest.mark.parametrize("args,seconds", [((), 60), (("--every", "5"), 5),
                                          (("--every", "007"), 7)],
                         ids=["default", "five", "leading-zeros"])
def test_the_watch_sleeps_every_seconds_between_ticks_60_by_default(
        root, seed, common, env, capsys, args, seconds):
    sleep = Sleep(None)

    with pytest.raises(Ended):
        watch(seed, checkout(root, common), env, Starter(Tick(), Tick()), sleep, *args)

    assert sleep.waits == [seconds, seconds]


@pytest.mark.parametrize("every", ["0", "-1", "abc", "1.5", ""])
def test_every_that_is_no_positive_whole_number_is_refused_starting_nothing(
        root, seed, common, env, pidfile, capsys, every):
    starter = Starter()

    code = watch(seed, checkout(root, common), env, starter, Sleep(), "--every", every)

    assert (code, capsys.readouterr()) == (1, (
        "", "orch: --every must be a positive whole number of seconds, got: %s\n" % every))
    assert (starter.starts, pidfile.exists()) == ([], False)


# --- the gate ----------------------------------------------------------------------


def test_with_no_permission_mode_the_watch_dies_naming_the_key(
        root, seed, common, env, pidfile, capsys):
    starter = Starter()

    code = watch(seed, checkout(root, common, mode=None), env, starter, Sleep())

    assert (code, capsys.readouterr()) == (1, (
        "", "orch: %s is not set - choose how headless sessions run (git config %s "
        "<default|acceptEdits|plan|dontAsk|bypassPermissions>)\n" % (MODE_KEY, MODE_KEY)))
    assert (starter.starts, pidfile.exists()) == ([], False)


@pytest.mark.parametrize("host,path", [("junie", "bin"), ("claude", "empty")])
def test_off_claude_code_or_with_no_claude_on_path_the_watch_dies(
        root, seed, common, env, pidfile, capsys, tmp_path, host, path):
    (tmp_path / "empty").mkdir()
    env = dict(env, ORCHESTRATOR_HOST=host, PATH=str(tmp_path / path))
    starter = Starter()

    code = watch(seed, checkout(root, common), env, starter, Sleep())

    assert (code, capsys.readouterr()) == (1, (
        "", "orch: autopilot is Claude Code only (no headless-session fallback on this host;"
        " see docs/host-capabilities.md)\n"))
    assert (starter.starts, pidfile.exists()) == ([], False)


def test_a_model_outside_claude_code_s_list_is_refused_before_the_pidfile(
        root, seed, common, env, pidfile, capsys):
    git = FakeGit({"origin": ORIGIN}, toplevel=str(root), local_config={
        MODE_KEY: "dontAsk", "orchestrator.autopilot.model": "gpt"})
    git.seed("git_common_dir", answer=str(common))

    code = watch(seed, git, env, Starter(), Sleep())

    assert code == 1
    assert "orchestrator.autopilot.model" in capsys.readouterr().err
    assert not pidfile.exists()


# --- the pidfile -----------------------------------------------------------------


def test_the_pidfile_holds_this_process_s_record_while_the_watch_runs(
        root, seed, common, env, pidfile, capsys):
    seen = []
    starter = Starter(Tick(during=lambda: seen.append(pidfile.read_text())))

    with pytest.raises(Ended):
        watch(seed, checkout(root, common), env, starter, Sleep())

    assert seen == ["%d %s\n" % (os.getpid(), START)]


def test_while_another_watch_is_alive_the_watch_is_refused_naming_its_pid(
        root, seed, common, env, proc, pidfile, capsys):
    proc_add(proc, OTHER, START)
    pidfile.parent.mkdir()
    pidfile.write_text("%d %s\n" % (OTHER, START))
    starter = Starter()

    code = watch(seed, checkout(root, common), env, starter, Sleep())

    assert (code, capsys.readouterr()) == (1, (
        "", "orch: another autopilot watch (pid %d) is already running in this clone\n"
        % OTHER))
    assert (starter.starts, pidfile.read_text()) == ([], "%d %s\n" % (OTHER, START))


@pytest.mark.parametrize("record", ["%d %s\n" % (OTHER, START), "%d 1\n" % OTHER, "garbage", ""],
                         ids=["pid-gone", "pid-reused", "malformed", "empty"])
def test_a_pidfile_whose_process_is_gone_is_replaced(
        root, seed, common, env, proc, pidfile, capsys, record):
    proc_add(proc, OTHER + 1, START)
    if "1\n" in record:
        proc_add(proc, OTHER, "9")
    pidfile.parent.mkdir()
    pidfile.write_text(record)
    seen = []
    starter = Starter(Tick(during=lambda: seen.append(pidfile.read_text())))

    with pytest.raises(Ended):
        watch(seed, checkout(root, common), env, starter, Sleep())

    assert seen == ["%d %s\n" % (os.getpid(), START)]


def test_a_pidfile_directory_that_cannot_be_made_dies_naming_it(
        root, seed, common, env, capsys):
    (common / "orchestrator").write_text("a file\n")
    starter = Starter()

    code = watch(seed, checkout(root, common), env, starter, Sleep())

    assert (code, capsys.readouterr()) == (
        1, ("", "orch: could not create %s/orchestrator\n" % common))
    assert starter.starts == []


def test_with_no_git_common_directory_the_watch_dies(root, seed, env, capsys):
    starter = Starter()

    code = watch(seed, checkout(root, None), env, starter, Sleep())

    assert (code, capsys.readouterr()) == (
        1, ("", "orch: could not find the clone's git common directory\n"))
    assert starter.starts == []


def test_an_unreadable_own_start_time_ends_the_watch_with_exit_1_and_no_pidfile(
        root, seed, common, env, proc, pidfile, capsys):
    (proc / str(os.getpid()) / "stat").write_text("garbage\n")
    starter = Starter()

    code = watch(seed, checkout(root, common), env, starter, Sleep())

    assert (code, capsys.readouterr()) == (
        1, ("", "orch: could not read the start time of pid %d\n" % os.getpid()))
    assert (starter.starts, pidfile.exists()) == ([], False)


# --- the ticks -------------------------------------------------------------------


def test_each_tick_is_a_fresh_orch_sh_autopilot_tick_its_stdout_dropped(
        root, seed, common, env, capsys):
    starter = Starter(Tick(), Tick())

    with pytest.raises(Ended):
        watch(seed, checkout(root, common), env, starter, Sleep(None))

    assert starter.starts == [(TICK, {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL})] * 2
    assert capsys.readouterr() == ("", "")


@pytest.mark.parametrize("code,shown", [(3, 3), (-9, 137)], ids=["exit", "killed"])
def test_a_failed_tick_is_warned_and_the_watch_ticks_again(
        root, seed, common, env, pidfile, capsys, code, shown):
    starter = Starter(Tick(code), Tick())

    with pytest.raises(Ended):
        watch(seed, checkout(root, common), env, starter, Sleep(None), "--every", "5")

    assert len(starter.starts) == 2
    assert capsys.readouterr() == ("", (
        "orch: autopilot watch: the tick failed (exit %d); trying again in 5s\n" % shown))


@pytest.mark.parametrize("error,shown", [(FileNotFoundError, 127), (PermissionError, 126)],
                         ids=["missing", "not-executable"])
def test_a_tick_that_cannot_start_is_warned_as_the_shell_s_exit(
        root, seed, common, env, capsys, error, shown):
    def starter(argv, **kwargs):
        raise error("orch.sh")

    with pytest.raises(Ended):
        watch(seed, checkout(root, common), env, starter, Sleep(), "--every", "5")

    assert capsys.readouterr().err == (
        "orch: autopilot watch: the tick failed (exit %d); trying again in 5s\n" % shown)


# --- INT and TERM ----------------------------------------------------------------

SIGNALS = pytest.mark.parametrize("signum", [signal.SIGINT, signal.SIGTERM],
                                  ids=["INT", "TERM"])


@SIGNALS
def test_a_signal_during_a_tick_terms_it_waits_for_it_and_exits_0(
        root, seed, common, env, pidfile, capsys, signum):
    seen = []
    tick = Tick(code=-15, during=raising(signum))
    tick.terminate = lambda: seen.append(("termed", pidfile.exists()))
    sleep = Sleep()

    code = watch(seed, checkout(root, common), env, Starter(tick), sleep)

    assert (code, capsys.readouterr()) == (0, ("", ""))
    assert (seen, tick.waits, sleep.waits, pidfile.exists()) == (
        [("termed", False)], 2, [], False)


@SIGNALS
def test_a_signal_during_the_sleep_cuts_it_short_and_exits_0(
        root, seed, common, env, pidfile, capsys, signum):
    tick = Tick()
    starter = Starter(tick, Tick())

    code = watch(seed, checkout(root, common), env, starter, Sleep(raising(signum)))

    assert (code, capsys.readouterr()) == (0, ("", ""))
    assert (len(starter.starts), tick.termed, pidfile.exists()) == (1, False, False)


@SIGNALS
def test_the_watch_leaves_the_signal_handlers_as_it_found_them(
        root, seed, common, env, capsys, signum):
    before = signal.getsignal(signum)

    watch(seed, checkout(root, common), env, Starter(Tick()), Sleep(raising(signum)))

    assert signal.getsignal(signum) is before


# --- any other exit ----------------------------------------------------------------


def test_a_watch_ending_other_than_by_int_or_term_removes_its_pidfile(
        root, seed, common, env, pidfile, capsys):
    seen = []
    starter = Starter(Tick(during=lambda: seen.append(pidfile.exists())))

    with pytest.raises(Ended):
        watch(seed, checkout(root, common), env, starter, Sleep())

    assert (seen, pidfile.exists()) == ([True], False)
