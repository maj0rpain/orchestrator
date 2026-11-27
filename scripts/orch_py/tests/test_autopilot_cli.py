"""`orch.sh autopilot watch`, `tick` and `run` end to end: the real orch.sh
run as a command, in a clone of a bare origin under tmp_path, against the gh
fake's store (ORCH_GH_FAKE_STORE), with claude on PATH and a fake session
launcher (ORCH_AUTOPILOT_LAUNCHER). They check what the in-process cases
cannot: that orch.sh execs python3, so the watch pidfile and a run record
name the processes orch.sh started; the watch's refusal while another watch
of the clone is alive, a dead pidfile replaced, and INT and TERM stopping a
tick held mid-run by the store's hold/<operation> fifo and a sleep between
ticks; and the detached run a tick starts outliving the tick and a Ctrl-C at
its process group."""
from __future__ import annotations

import os
import signal
import subprocess
from pathlib import Path

import pytest

from conftest import GLOBAL_CONFIG, comments_of, labels_of, origin_clone, run_git, until
from orch import liveness

SCRIPTS = Path(__file__).resolve().parents[2]
ORCH_SH = str(SCRIPTS / "orch.sh")
# How long a tick, which starts orch.sh children of its own, may take.
TICK_BOUND = 60.0


@pytest.fixture
def clone(tmp_path):
    """A clone of a bare origin holding main, its permission mode set: its
    path."""
    root = tmp_path / "clone"
    origin_clone(tmp_path / "origin.git", root, branch="main")
    run_git(root, "commit", "-q", "--allow-empty", "-m", "first")
    run_git(root, "push", "-q", "origin", "HEAD:refs/heads/main")
    run_git(root, "config", "orchestrator.autopilot.permission-mode", "acceptEdits")
    for key, value in (("user.name", "t"), ("user.email", "t@t"), ("commit.gpgsign", "false")):
        run_git(root, "config", key, value)
    return root


@pytest.fixture
def env(tmp_path, seed):
    """The environment every orch.sh call runs in: HOME under tmp_path and
    no other global git config, the repo pinned, the gh fake's store, the
    Claude Code host and a claude on PATH."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "claude").write_text("#!/bin/sh\nexit 0\n")
    (bin_dir / "claude").chmod(0o755)
    env = dict(os.environ, HOME=str(tmp_path), GH_REPO="acme/widgets",
               ORCH_GH_FAKE_STORE=seed.store, ORCHESTRATOR_HOST="claude",
               PATH="%s%s%s" % (bin_dir, os.pathsep, os.environ["PATH"]))
    for name in GLOBAL_CONFIG + ("ORCH_AUTOPILOT_FOREGROUND", "ORCH_AUTOPILOT"):
        env.pop(name, None)
    return env


@pytest.fixture
def pidfile(clone):
    """The clone's watch pidfile."""
    return clone / ".git" / "orchestrator" / "autopilot-watch.pid"


class Processes:
    """The processes a test started, each killed at its end if still
    running."""

    def __init__(self):
        self.started = []
        self.pids = []

    def start(self, argv, cwd, env, **how):
        proc = subprocess.Popen(argv, cwd=str(cwd), env=env, stdin=subprocess.DEVNULL, **how)
        self.started.append(proc)
        return proc

    def end(self):
        for pid in self.pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        for proc in self.started:
            if proc.poll() is None:
                proc.kill()
            proc.wait()


@pytest.fixture
def procs():
    started = Processes()
    yield started
    started.end()


def watch(procs, clone, env, tmp_path, *args):
    """`orch.sh autopilot watch <args>` started in <clone>, its stderr in
    tmp_path/watch.err: the process."""
    err = open(str(tmp_path / "watch.err"), "w")
    try:
        return procs.start([ORCH_SH, "autopilot", "watch", *args], clone, env,
                           stdout=subprocess.DEVNULL, stderr=err)
    finally:
        err.close()


def record_of(pid):
    """The record liveness writes for the live process <pid>."""
    return "%d %s\n" % (pid, liveness.proc_start(pid, os.environ))


def args_of(pid):
    """The live process <pid>'s arguments, read from /proc rather than ps,
    which a container may lack: one space between each."""
    raw = Path("/proc/%d/cmdline" % pid).read_bytes()
    return " ".join(raw.decode().rstrip("\0").split("\0"))


def alive(pid):
    """Whether the process <pid> runs, a zombie counted as gone."""
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    try:
        stat = Path("/proc/%d/stat" % pid).read_text()
    except OSError:
        return False
    # The state is the first word after the command name's closing paren.
    return stat.rsplit(") ", 1)[-1].split()[0] != "Z"


def held_tick(seed):
    """Parks the tick's label write on the store's hold fifo: the held
    file, which the parked call writes its pid to."""
    os.makedirs(os.path.join(seed.store, "hold"))
    os.mkfifo(os.path.join(seed.store, "hold", "adapter_label_upsert"))
    return Path(seed.store) / "held"


def failed_ticks(tmp_path, count):
    """Whether the watch has reported <count> failed ticks."""
    path = tmp_path / "watch.err"
    return path.is_file() and path.read_text().count("the tick failed") >= count


# --- watch ---------------------------------------------------------------------


@pytest.mark.parametrize("signum", [signal.SIGTERM, signal.SIGINT], ids=["term", "int"])
def test_a_watch_stopped_mid_tick_removes_its_pidfile_ends_the_tick_and_exits_0(
        tmp_path, clone, env, seed, pidfile, procs, signum):
    held = held_tick(seed)
    watcher = watch(procs, clone, env, tmp_path, "--every", "1")

    assert until(lambda: held.is_file() and held.read_text().strip().isdigit(), TICK_BOUND)
    tick = int(held.read_text())
    procs.pids.append(tick)
    # The pidfile names the very process orch.sh started, which execed
    # python3, and the tick is a fresh `orch.sh autopilot tick` process.
    assert pidfile.read_text() == record_of(watcher.pid)
    assert args_of(tick).endswith("autopilot tick")

    watcher.send_signal(signum)

    assert watcher.wait(TICK_BOUND) == 0
    assert not pidfile.exists()
    assert until(lambda: not alive(tick))


@pytest.mark.parametrize("signum", [signal.SIGTERM, signal.SIGINT], ids=["term", "int"])
def test_a_watch_stopped_in_its_sleep_after_a_failed_tick_exits_0_at_once(
        tmp_path, clone, env, seed, pidfile, procs, signum):
    seed.fail("adapter_label_upsert", "HTTP 500 label")
    watcher = watch(procs, clone, env, tmp_path, "--every", "300")
    assert until(lambda: failed_ticks(tmp_path, 1), TICK_BOUND)

    watcher.send_signal(signum)

    assert watcher.wait(10) == 0
    assert not pidfile.exists()
    assert (tmp_path / "watch.err").read_text() == (
        "orch: could not upsert the label orch:spec: HTTP 500 label - the tick stops\n"
        "orch: autopilot watch: the tick failed (exit 1); trying again in 300s\n")


def test_a_second_watch_of_the_clone_is_refused_naming_the_live_one(
        tmp_path, clone, env, seed, pidfile, procs):
    held = held_tick(seed)
    watcher = watch(procs, clone, env, tmp_path)
    assert until(held.is_file, TICK_BOUND)
    procs.pids.append(int(held.read_text()))
    record = pidfile.read_text()

    second = subprocess.run([ORCH_SH, "autopilot", "watch"], cwd=str(clone), env=env,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=TICK_BOUND)

    assert (second.returncode, second.stdout, second.stderr.decode()) == (
        1, b"", "orch: another autopilot watch (pid %d) is already running in this clone\n"
        % watcher.pid)
    assert pidfile.read_text() == record


def test_a_watch_replaces_a_pidfile_whose_process_is_gone(
        tmp_path, clone, env, seed, pidfile, procs):
    gone = subprocess.Popen(["true"])
    gone.wait()
    pidfile.parent.mkdir(parents=True)
    pidfile.write_text("%d 1\n" % gone.pid)
    seed.fail("adapter_label_upsert", "HTTP 500 label")

    watcher = watch(procs, clone, env, tmp_path, "--every", "300")

    assert until(lambda: failed_ticks(tmp_path, 1), TICK_BOUND)
    assert pidfile.read_text() == record_of(watcher.pid)
    assert watcher.poll() is None
    watcher.terminate()
    assert watcher.wait(TICK_BOUND) == 0
    assert not pidfile.exists()


# --- a tick's detached run -------------------------------------------------------

LAUNCHER = """#!/bin/sh
echo $$ >"{marker}.tmp" && mv "{marker}.tmp" "{marker}"
n=0
while [ ! -f "{release}" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
exit 0
"""


def test_a_tick_starts_the_run_detached_and_the_run_outlives_the_tick_and_its_group_s_int(
        tmp_path, clone, env, seed, procs):
    seed.issue(7, "open", "ready-for-agent", "orch:spec")
    seed.title(7, "Add the widget")
    marker, release, ticked = tmp_path / "launched", tmp_path / "release", tmp_path / "ticked"
    launcher = tmp_path / "launcher"
    launcher.write_text(LAUNCHER.format(marker=marker, release=release))
    launcher.chmod(0o755)
    env["ORCH_AUTOPILOT_LAUNCHER"] = str(launcher)
    # The tick runs in a process group of its own, as under a watch started
    # from a terminal, its group kept alive past the tick by the shell that
    # leads it, so an INT can reach the group once the tick has exited. INT
    # takes its default action there, as in a terminal's foreground group,
    # even where this test runs as a background job that ignores it.
    group = procs.start(["/bin/sh", "-c", '"$@"; echo $? >"$0"; exec sleep 60', str(ticked),
                         ORCH_SH, "autopilot", "tick"], clone, env, start_new_session=True,
                        preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run_record = clone / ".orchestrator" / "autopilot" / "run" / "7.pid"

    assert until(lambda: ticked.is_file() and ticked.read_text() != "", TICK_BOUND)
    assert ticked.read_text() == "0\n"
    assert until(lambda: marker.is_file() and run_record.is_file(), TICK_BOUND)
    record = run_record.read_text()
    run, session = int(record.split()[0]), int(marker.read_text())
    procs.pids += [run, session]
    # The run record names a live process whose arguments are `autopilot run
    # 7`, at the start time it records: the process orch.sh started.
    assert liveness.record_alive(record, os.environ)
    assert record == record_of(run)
    assert args_of(run).endswith("autopilot run 7")
    assert os.getpgid(run) != group.pid

    os.killpg(group.pid, signal.SIGINT)
    group.wait(10)

    assert alive(run) and alive(session)
    release.write_text("")
    assert until(lambda: not run_record.exists(), TICK_BOUND)
    # The session ran its course: it exited 0, not of the INT, with its
    # claim still held, which the run, alive to its end, settles as a
    # failure.
    assert comments_of(seed.store, 7)[-1].startswith(
        "<!-- orch:failure spec -->\nAutopilot failed in the spec phase: the session exited"
        " with code 0; log: ")
    assert "needs-human" in labels_of(seed.store, 7)
