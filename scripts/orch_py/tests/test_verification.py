"""The verification noun (a re-callable command, ADR-0065), in-process: `run`
and `stop` driven through orch.verification.run against real repositories in
tmp_path and real tiny subprocesses, with the block, grace, ceiling and poll
knobs turned down to fractions of a second. Process lifetime is the behaviour
under test, so no process is faked; a group surviving the KILL, which no
real process can show, is made with os.killpg monkeypatched to signal
nothing."""
from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import threading
import time

import pytest

from conftest import (
    VERIFICATION_KNOBS,
    committed,
    git_repo,
    gone,
    path_without,
    run_git as git,
    until,
    verification_records as records,
    verification_store as store,
    worktree_add,
)
from orch import verification
from orch.git import Git

# The knobs every call runs under unless a test sets its own: a block long
# enough to deliver a quick run, over the shared short grace and fast poll.
KNOBS = dict(VERIFICATION_KNOBS, ORCH_WAIT_BLOCK="10")


def one_commit_repo(root):
    """A repository at <root> with one commit: its root, resolved as git
    names it."""
    git_repo(root)
    committed(root, {"README.md": "readme\n"}, "first")
    return root.resolve()


@pytest.fixture
def repo(tmp_path):
    """A repository at tmp_path/repo with one commit: its root, resolved as
    git names it."""
    return one_commit_repo(tmp_path / "repo")


@pytest.fixture(scope="module")
def refusing_repo(tmp_path_factory):
    """A repository with one commit shared by the module's cases that never
    touch the store - the refusal cases and the stop with no run: its
    root."""
    return one_commit_repo(tmp_path_factory.mktemp("refusing") / "repo")


# os.killpg as it is before any test fakes it, for the teardown to stop every
# group whatever the test faked.
REAL_KILLPG = os.killpg


@pytest.fixture(autouse=True)
def no_runner_left():
    """Every runner a test started is stopped with its group once it ends,
    through the real killpg, each waited for at most 5 s: a teardown after a
    failed test runs with no per-test timeout."""
    yield
    for runner in list(verification.RUNNERS):
        try:
            REAL_KILLPG(runner.pid, signal.SIGKILL)
        except OSError:
            pass
        runner.wait(timeout=5)
    del verification.RUNNERS[:]


def verify(root, *argv, **knobs):
    """`orch.sh verification <argv>` in-process in the checkout at <root>,
    under KNOBS with <knobs> over them: its exit code, a SystemExit's
    included."""
    env = dict(os.environ, **KNOBS)
    env.update(knobs)
    try:
        return verification.run(list(argv), git=Git(cwd=str(root)), env=env)
    except SystemExit as died:
        return died.code


def the_record(root):
    """The one record in the store of <root>."""
    names = records(root)
    assert len(names) == 1, names
    return store(root) / names[0]


def gated(tmp_path, tail="echo done", gate="gate"):
    """A command line that logs one start to tmp_path/starts, waits for
    tmp_path/<gate> to exist, then runs <tail>."""
    return 'echo start >>"%s"; while [ ! -f "%s" ]; do sleep 0.02; done; %s' % (
        tmp_path / "starts", tmp_path / gate, tail)


def starts(tmp_path):
    path = tmp_path / "starts"
    return len(path.read_text().splitlines()) if path.exists() else 0


def group_of(record):
    return int((record / "pid").read_text().split()[0])


def test_a_run_finishing_inside_the_call_is_delivered_whole_with_its_status(repo, capsys):
    code = verify(repo, "run", "echo out; echo err >&2; exit 3")

    out, err = capsys.readouterr()
    assert (code, out, err) == (3, "out\n", "err\n")


def test_a_run_still_going_exits_75_and_the_same_line_again_attaches(repo, tmp_path, capsys):
    command = gated(tmp_path)

    first = verify(repo, "run", command, ORCH_WAIT_BLOCK="0.2")
    first_out = capsys.readouterr()
    assert until(lambda: starts(tmp_path) == 1)
    again = verify(repo, "run", command, ORCH_WAIT_BLOCK="0.2")
    capsys.readouterr()
    (tmp_path / "gate").write_text("")
    delivered = verify(repo, "run", command)

    assert (first, tuple(first_out)) == (
        75, ("", "orch: still running after 0.2s - run the same command again\n"))
    assert (again, delivered, capsys.readouterr().out, starts(tmp_path)) == (75, 0, "done\n", 1)
    assert records(repo) == []


def test_a_command_s_own_75_is_delivered_as_1(repo, capsys):
    code = verify(repo, "run", "exit 75")

    assert (code, capsys.readouterr().err) == (
        1, "orch: the command exited 75 - delivered as exit 1, its real status\n")


def test_a_run_past_the_ceiling_is_delivered_as_1_with_its_message(repo, capsys):
    git(repo, "config", "orchestrator.verification.timeout", "0.3")

    code = verify(repo, "run", "echo partial; sleep 30")

    out, err = capsys.readouterr()
    assert (code, out, err) == (1, "partial\n", "orch: the run was still going after the ceiling"
                                " of 0.3s (orchestrator.verification.timeout) and was stopped\n")


def test_a_run_nobody_waits_on_is_stopped_at_its_ceiling_and_the_next_call_fails_it(
        repo, tmp_path, capsys):
    git(repo, "config", "orchestrator.verification.timeout", "0.3")
    command = "trap 'echo TERM >\"%s\"; exit 0' TERM; echo partial; while :; do sleep 0.02; done" \
        % (tmp_path / "termed")

    running = verify(repo, "run", command, ORCH_WAIT_BLOCK="0.05")
    record = the_record(repo)
    assert until(lambda: (record / "status").exists())
    capsys.readouterr()
    code = verify(repo, "run", command)

    out, err = capsys.readouterr()
    assert (running, code, out, (tmp_path / "termed").read_text()) == (75, 1, "partial\n", "TERM\n")
    assert "after the ceiling of 0.3s" in err


@pytest.mark.parametrize("knob, value, message", [
    ("ORCH_WAIT_BLOCK", "0", "ORCH_WAIT_BLOCK must be greater than zero: 0"),
    ("ORCH_WAIT_BLOCK", "x", "ORCH_WAIT_BLOCK is not a number: x"),
    ("ORCH_VERIFICATION_GRACE", "-1", "ORCH_VERIFICATION_GRACE is not a number: -1"),
    ("ORCH_VERIFICATION_INTERVAL", "0.0", "ORCH_VERIFICATION_INTERVAL must be greater than zero: 0.0"),
    ("ORCH_VERIFICATION_INTERVAL", "1.2.3", "ORCH_VERIFICATION_INTERVAL is not a number: 1.2.3"),
    ("ORCH_VERIFICATION_WATCH", "0", "ORCH_VERIFICATION_WATCH must be greater than zero: 0"),
    ("ORCH_VERIFICATION_WATCH", "-2", "ORCH_VERIFICATION_WATCH is not a number: -2"),
])
@pytest.mark.parametrize("verb", ["run", "stop"])
def test_a_knob_out_of_range_is_refused(refusing_repo, capsys, verb, knob, value, message):
    code = verify(refusing_repo, verb, "true" if verb == "run" else str(refusing_repo),
                  **{knob: value})

    assert (code, capsys.readouterr().err, records(refusing_repo)) == (
        1, "orch: %s\n" % message, [])


def test_a_grace_of_zero_is_a_number(repo, capsys):
    assert verify(repo, "run", "true", ORCH_VERIFICATION_GRACE="0") == 0


@pytest.fixture
def ceiling_unset_after(refusing_repo):
    """<refusing_repo>, its orchestrator.verification.timeout, which the test
    sets, unset again once the test ends, so no other case sharing it meets
    the key."""
    yield refusing_repo
    git(refusing_repo, "config", "--unset", "orchestrator.verification.timeout")


@pytest.mark.parametrize("ceiling", ["abc", "0", "-1", "1.2.3"])
def test_a_ceiling_that_is_no_positive_number_is_refused_naming_its_key(
        ceiling_unset_after, capsys, ceiling):
    repo = ceiling_unset_after
    git(repo, "config", "orchestrator.verification.timeout", ceiling)

    code = verify(repo, "run", "true")

    assert (code, capsys.readouterr().err) == (
        1, "orch: orchestrator.verification.timeout is %s - it must be a positive number of"
           " seconds (git config orchestrator.verification.timeout <seconds>)\n" % ceiling)


@pytest.mark.parametrize("argv, usage", [
    ((), "usage: orch.sh verification run <command> | stop <checkout>"),
    (("go",), "usage: orch.sh verification run <command> | stop <checkout>"),
    (("run",), "usage: orch.sh verification run <command>"),
    (("run", ""), "usage: orch.sh verification run <command>"),
    (("run", "a", "b"), "usage: orch.sh verification run <command>"),
    (("stop",), "usage: orch.sh verification stop <checkout>"),
])
def test_a_usage_error_exits_1_with_the_usage_line(refusing_repo, capsys, argv, usage):
    assert (verify(refusing_repo, *argv), capsys.readouterr().err) == (1, "orch: %s\n" % usage)


def started(capsys, root, tmp_path, command, at=None, **knobs):
    """Starts <command> as a live run in the checkout <root> (a call that
    exits 75), under <knobs> over KNOBS, and waits for its start: its record,
    the one new in the store of the main checkout <at> (<root> when None).
    What the call printed is dropped, so a test's capsys reads only the calls
    after it."""
    main = root if at is None else at
    before, count = set(records(main)), starts(tmp_path)
    knobs.setdefault("ORCH_WAIT_BLOCK", "0.05")
    assert verify(root, "run", command, **knobs) == 75
    assert until(lambda: starts(tmp_path) == count + 1)
    capsys.readouterr()
    (name,) = set(records(main)) - before
    return store(main) / name


def test_a_stale_live_run_is_stopped_inside_the_call_and_a_fresh_one_started(
        repo, tmp_path, capsys):
    command = gated(tmp_path) + "; true"
    trapped = "trap 'echo TERM >>\"%s\"; exit 0' TERM; %s" % (tmp_path / "log", command)
    old = group_of(started(capsys, repo, tmp_path, trapped))
    (repo / "README.md").write_text("edited\n")

    code = verify(repo, "run", trapped, ORCH_WAIT_BLOCK="0.05")

    assert (code, gone(old), (tmp_path / "log").read_text()) == (75, True, "TERM\n")
    assert until(lambda: starts(tmp_path) == 2)


def test_a_stale_live_run_ignoring_term_is_killed_inside_the_call(repo, tmp_path, capsys):
    command = "trap '' TERM; " + gated(tmp_path)
    old = group_of(started(capsys, repo, tmp_path, command))
    (repo / "new.txt").write_text("untracked\n")

    code = verify(repo, "run", command, ORCH_WAIT_BLOCK="0.05")

    assert (code, gone(old)) == (75, True)


def test_a_run_of_another_command_is_left_alone(repo, tmp_path, capsys):
    command = gated(tmp_path)
    group = group_of(started(capsys, repo, tmp_path, command))

    other = verify(repo, "run", "echo other")
    other_out = capsys.readouterr().out
    attached = verify(repo, "run", command, ORCH_WAIT_BLOCK="0.05")

    assert (other, other_out, attached, gone(group), starts(tmp_path)) == (
        0, "other\n", 75, False, 1)


def test_a_call_waiting_on_a_run_whose_runner_died_dies_saying_so(repo, capsys):
    code = verify(repo, "run", "kill -KILL 0")

    assert (code, capsys.readouterr().err, records(repo)) == (
        1, "orch: the run ended without a status - run the same command again\n", [])


def test_a_run_whose_runner_died_is_met_by_a_fresh_run(repo, tmp_path, capsys):
    command = gated(tmp_path, '[ -f "%s" ] || { : >"%s"; kill -KILL 0; }; echo done'
                    % (tmp_path / "killed", tmp_path / "killed"))
    group = group_of(started(capsys, repo, tmp_path, command))
    (tmp_path / "gate").write_text("")
    assert until(lambda: gone(group))

    code = verify(repo, "run", command)

    assert (code, capsys.readouterr().out, starts(tmp_path)) == (0, "done\n", 2)


@pytest.fixture
def side(repo, tmp_path):
    """A side checkout of <repo> at tmp_path/side, and its ticket worktree
    t5: their roots."""
    path = worktree_add(repo, (tmp_path / "side").resolve(), "-b", "side")
    ticket = worktree_add(repo, path / ".orchestrator" / "worktrees" / "t5", "-b", "t5")
    return path, ticket


@pytest.fixture
def wt(repo, tmp_path):
    """A worktree of <repo> at tmp_path/wt, on its own branch wt: its root,
    resolved as git names it."""
    return worktree_add(repo, (tmp_path / "wt").resolve(), "-b", "wt")


def test_stop_stops_the_live_runs_of_a_checkout_and_its_ticket_worktrees(
        repo, side, tmp_path, capsys):
    side_root, ticket = side
    own = started(capsys, side_root, tmp_path, gated(tmp_path, "echo side"), at=repo)
    ticket_run = started(capsys, ticket, tmp_path, gated(tmp_path, "echo ticket"), at=repo)
    other = started(capsys, repo, tmp_path, gated(tmp_path, "echo main"))
    finished = started(capsys, side_root, tmp_path, gated(tmp_path, "true", "finish"), at=repo)
    groups = [group_of(record) for record in (own, ticket_run, other)]
    (tmp_path / "finish").write_text("")
    assert until(lambda: (finished / "status").exists())

    code = verify(repo, "stop", str(side_root) + "/")

    assert (code, [gone(group) for group in groups]) == (0, [True, True, False])
    assert records(repo) == sorted([other.name, finished.name])


def test_stop_with_no_live_run_is_a_no_op(refusing_repo, capsys):
    assert (verify(refusing_repo, "stop", str(refusing_repo)), records(refusing_repo)) == (0, [])


def signalling_nothing_to(monkeypatch, group):
    """os.killpg signals nothing to <group>, which so survives every KILL,
    and every other group as it does."""
    real = os.killpg

    def killpg(target, sig):
        if target != group:
            real(target, sig)

    monkeypatch.setattr(os, "killpg", killpg)


def test_stop_exits_1_after_the_other_runs_when_a_group_survives_the_kill(
        repo, side, tmp_path, capsys, monkeypatch):
    side_root, ticket = side
    survivor = started(capsys, side_root, tmp_path, gated(tmp_path, "echo side"), at=repo)
    stopped = started(capsys, ticket, tmp_path, gated(tmp_path, "echo ticket"), at=repo)
    group, stopped_group = group_of(survivor), group_of(stopped)
    signalling_nothing_to(monkeypatch, group)

    code = verify(repo, "stop", str(side_root), ORCH_VERIFICATION_GRACE="0.1")

    assert (code, capsys.readouterr().err) == (
        1, "orch: the run in %s (process group %d) could not be stopped - stop it by hand\n"
        % (side_root, group))
    assert (records(repo), gone(stopped_group)) == ([survivor.name], True)
    assert [mark for mark in ("termed", "killed", "waiting") if (survivor / mark).exists()] == []


def test_a_stale_live_run_whose_group_survives_the_kill_is_refused(
        repo, tmp_path, capsys, monkeypatch):
    command = gated(tmp_path)
    record = started(capsys, repo, tmp_path, command)
    group = group_of(record)
    signalling_nothing_to(monkeypatch, group)
    (repo / "README.md").write_text("edited\n")

    code = verify(repo, "run", command, ORCH_VERIFICATION_GRACE="0.1")

    assert (code, capsys.readouterr().err) == (
        1, "orch: the stale run of this command (process group %d) could not be stopped"
           " - stop it by hand\n" % group)
    assert (records(repo), starts(tmp_path)) == ([record.name], 1)

# A watch interval no test outlasts, so the orphan sweep, never the runner's own
# checkout watch, is what stops a run in a removed checkout.
SWEPT_FIRST = {"ORCH_VERIFICATION_WATCH": "600"}


def test_the_orphan_sweep_stops_a_live_run_in_a_removed_checkout_and_drops_its_record(
        repo, wt, tmp_path, capsys):
    group = group_of(started(capsys, wt, tmp_path, gated(tmp_path), at=repo, **SWEPT_FIRST))
    git(repo, "worktree", "remove", "--force", str(wt))

    code = verify(repo, "run", "true")

    assert (code, gone(group), records(repo)) == (0, True, [])


def test_the_orphan_sweep_drops_a_record_whose_group_survives_the_kill_warning_of_it(
        repo, wt, tmp_path, capsys, monkeypatch):
    group = group_of(started(capsys, wt, tmp_path, gated(tmp_path), at=repo, **SWEPT_FIRST))
    git(repo, "worktree", "remove", "--force", str(wt))
    signalling_nothing_to(monkeypatch, group)

    code = verify(repo, "run", "true", ORCH_VERIFICATION_GRACE="0.1")

    assert (code, capsys.readouterr().err, records(repo)) == (
        0, "orch: the run in %s (process group %d) could not be stopped - its record is"
           " dropped, stop it by hand\n" % (wt, group), [])


def test_a_checkout_made_again_at_its_path_is_never_handed_the_old_result(
        repo, wt, tmp_path, capsys):
    command = gated(tmp_path, "echo done $(cat %s)" % (tmp_path / "round"))
    (tmp_path / "round").write_text("old\n")
    record = started(capsys, wt, tmp_path, command, at=repo)
    (tmp_path / "gate").write_text("")
    assert until(lambda: (record / "status").exists())
    git(repo, "worktree", "remove", "--force", str(wt))
    git(repo, "worktree", "add", "-q", str(wt), "wt")
    (tmp_path / "round").write_text("new\n")

    code = verify(wt, "run", command)

    assert (code, capsys.readouterr().out, starts(tmp_path)) == (0, "done new\n", 2)


def bash_record(root, command, main=None, **files):
    """A record of <command> in the checkout <root>, in the store of the main
    checkout <main> (<root> when None), as a call names and writes it: its
    root, its checkout's identity token (made, as bash makes one, when the
    checkout has none), the checkout's state now, and <files>, each file name
    mapped to its text, or to None for a file left out. Its directory."""
    token_file = store(root) / "id"
    if not token_file.exists():
        token_file.parent.mkdir(parents=True, exist_ok=True)
        token_file.write_text("a-bash-token\n")
    token = token_file.read_text().strip()
    key = subprocess.run(
        ["git", "hash-object", "--stdin"], cwd=str(root), check=True, stdout=subprocess.PIPE,
        input=("root %s\nid %s\ncommand %s\n" % (root, token, command)).encode(),
    ).stdout.decode().strip()
    record = store(root if main is None else main) / key
    record.mkdir(parents=True)
    texts = {"root": "%s\n" % root, "id": token + "\n",
             "state": Git(cwd=str(root)).tree_state() + "\n"}
    texts.update(files)
    for name, text in texts.items():
        if text is not None:
            (record / name).write_text(text)
    return record


def backdated(path):
    """<path>, its mtime set two minutes back."""
    then = time.time() - 120
    os.utime(str(path), (then, then))
    return path


def test_the_orphan_sweep_removes_old_leftovers_of_calls_that_died_partway(repo, capsys):
    old_tmp = store(repo) / ".old-tmp"
    old_tmp.mkdir(parents=True)
    (old_tmp / "root").write_text("%s\n" % repo)
    backdated(old_tmp)
    fresh_tmp = store(repo) / ".fresh-tmp"
    fresh_tmp.mkdir()
    old_pidless = backdated(bash_record(repo, "old"))
    fresh_pidless = bash_record(repo, "fresh")
    old_finished = backdated(bash_record(repo, "finished", out="", err="", status="0\n"))

    code = verify(repo, "run", "true")

    assert (code, old_tmp.exists(), fresh_tmp.exists()) == (0, False, True)
    assert records(repo) == sorted([fresh_pidless.name, old_finished.name])
    assert old_pidless.name not in records(repo)


def test_a_failed_runner_start_removes_its_record_and_dies_naming_the_failure(
        repo, capsys, monkeypatch):
    def refused(*args, **kwargs):
        raise OSError("no room for a process")

    monkeypatch.setattr(verification, "Popen", refused)

    code = verify(repo, "run", "true")

    assert (code, capsys.readouterr().err, records(repo)) == (
        1, "orch: could not start the run in %s: no room for a process\n" % repo, [])
    assert [path.name for path in store(repo).iterdir() if path.is_dir()] == []


def test_a_matching_record_with_no_pid_is_a_run_starting_and_is_waited_on(
        repo, tmp_path, capsys):
    command = gated(tmp_path)
    record = bash_record(repo, command)

    code = verify(repo, "run", command, ORCH_WAIT_BLOCK="0.2")

    assert (code, starts(tmp_path), records(repo)) == (75, 0, [record.name])


def test_a_call_losing_the_rename_attaches_to_the_winner(repo, tmp_path, capsys, monkeypatch):
    real = os.rename

    def planted_first(source, target):
        winner = os.path.join(os.path.dirname(target), ".winner")
        shutil.copytree(source, winner)
        for name, text in (("out", "winner\n"), ("err", ""), ("status", "0\n")):
            with open(os.path.join(winner, name), "w") as f:
                f.write(text)
        real(winner, target)
        real(source, target)

    monkeypatch.setattr(os, "rename", planted_first)

    code = verify(repo, "run", gated(tmp_path))

    assert (code, capsys.readouterr().out, starts(tmp_path), verification.RUNNERS) == (
        0, "winner\n", 0, [])
    assert [path.name for path in store(repo).iterdir() if path.is_dir()] == []


def proc_record(pid):
    """The liveness record of <pid> as orch/liveness.py's record_of builds
    it and record_write writes it: the pid and field 22 of its /proc stat."""
    with open("/proc/%d/stat" % pid) as f:
        start = f.read().rsplit(") ", 1)[1].split()[19]
    return "%d %s\n" % (pid, start)


# Starts `bash -c <argv[1]>` as its own session's leader, prints its pid and
# exits, so the group is never this process's child: like a bash runner's, its
# ended members are reaped by init, never left as zombies here.
LAUNCHER = """
import subprocess, sys
leader = subprocess.Popen(["bash", "-c", sys.argv[1]], start_new_session=True,
                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL)
print(leader.pid)
"""


@pytest.fixture
def planted():
    """Starts process groups a bash runner could have left: each one's
    leader's pid. Each is killed when the test ends."""
    groups = []

    def plant(command):
        pid = int(subprocess.run(
            [sys.executable, "-c", LAUNCHER, command], check=True, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
        ).stdout)
        groups.append(pid)
        return pid

    yield plant
    for group in groups:
        try:
            REAL_KILLPG(group, signal.SIGKILL)
        except OSError:
            pass


@pytest.mark.skipif(not os.path.isdir("/proc/self"), reason="bash records /proc start times")
def test_a_bash_left_live_record_is_attached_to_then_stopped_once_stale(
        repo, tmp_path, capsys, planted):
    command = gated(tmp_path)
    leader = planted("exec sleep 30")
    bash_record(repo, command, pid=proc_record(leader), out="", err="")

    attached = verify(repo, "run", command, ORCH_WAIT_BLOCK="0.1")
    attached_group = gone(leader)
    (repo / "README.md").write_text("edited\n")
    stale = verify(repo, "run", command, ORCH_WAIT_BLOCK="0.1")

    assert (attached, attached_group, stale, gone(leader)) == (75, False, 75, True)
    assert until(lambda: starts(tmp_path) == 1)


def pid_written_late(record, pid):
    """Writes <pid> as the pid of <record> 0.2 s on, as a call starting the
    record's runner does once Popen returns, unless by then the record has
    gone or holds another state than its planted stale one: the timer."""
    def write():
        try:
            if (record / "state").read_text() != "stale\n":
                return
            (record / ".pid").write_text(pid)
            os.rename(str(record / ".pid"), str(record / "pid"))
        except OSError:
            pass

    timer = threading.Timer(0.2, write)
    timer.start()
    return timer


@pytest.mark.skipif(not os.path.isdir("/proc/self"), reason="the pid is a /proc start time")
@pytest.mark.parametrize("verb", ["run", "stop"])
def test_a_stale_record_still_starting_has_its_runner_stopped_once_its_pid_is_there(
        repo, capsys, planted, verb):
    leader = planted("exec sleep 30")
    record = bash_record(repo, "true", state="stale\n")
    timer = pid_written_late(record, proc_record(leader))

    code = verify(repo, verb, "true" if verb == "run" else str(repo))
    timer.join()

    assert (code, gone(leader), records(repo)) == (0, True, [])


def test_a_runner_whose_pid_cannot_be_recorded_is_stopped_and_its_record_removed(
        repo, tmp_path, capsys, monkeypatch):
    # A proc directory holding this process alone: no runner's start time
    # can be read from it.
    (tmp_path / "proc" / str(os.getpid())).mkdir(parents=True)
    runners = []
    real = verification.Popen

    def recorded(*args, **kwargs):
        runner = real(*args, **kwargs)
        runners.append(runner.pid)
        return runner

    monkeypatch.setattr(verification, "Popen", recorded)

    code = verify(repo, "run", gated(tmp_path), ORCH_PROC_DIR=str(tmp_path / "proc"))

    assert (code, capsys.readouterr().err, records(repo)) == (
        1, "orch: could not start the run in %s: its runner's pid could not be recorded\n"
        % repo, [])
    assert until(lambda: gone(runners[0]))


def test_a_bash_left_finished_matching_record_is_delivered(repo, capsys):
    bash_record(repo, "true", pid="99999999 x\n", out="bash out\n", err="bash err\n",
                status="4\n", termed="1700000000\n", killed="1700000000\n")

    code = verify(repo, "run", "true")

    assert (code, tuple(capsys.readouterr()), records(repo)) == (
        4, ("bash out\n", "bash err\n"), [])


def test_a_stale_finished_result_is_discarded_and_the_run_made_again(repo, tmp_path, capsys):
    command = 'echo start >>"%s"; echo done $(cat README.md)' % (tmp_path / "starts")
    bash_record(repo, command, pid="99999999 x\n", out="bash out\n", err="", status="0\n")
    (repo / "README.md").write_text("edited\n")

    code = verify(repo, "run", command)

    assert (code, capsys.readouterr().out, starts(tmp_path), records(repo)) == (
        0, "done edited\n", 1, [])


def test_a_bash_left_termed_record_is_stopped_by_its_group_though_its_leader_died(
        repo, capsys, planted):
    leader = planted("sleep 30 & exit 0")
    assert until(lambda: not os.path.exists("/proc/%d" % leader))
    bash_record(repo, "true", state="stale\n", pid="%d x\n" % leader, out="", err="",
                termed="1700000000\n", waiting="1700000000\n")
    there = not gone(leader)

    code = verify(repo, "run", "true")

    assert (there, code, gone(leader)) == (True, 0, True)


def test_a_record_removed_once_its_status_is_there_never_keeps_its_runner(
        repo, tmp_path, capsys):
    record = started(capsys, repo, tmp_path, gated(tmp_path, "true"))
    group = group_of(record)
    (tmp_path / "gate").write_text("")
    assert until(lambda: (record / "status").exists(), bound=5)
    shutil.rmtree(str(record))

    assert until(lambda: gone(group), bound=2)


def test_a_record_removed_under_a_command_ignoring_term_is_killed_at_the_ceiling(
        repo, tmp_path, capsys):
    git(repo, "config", "orchestrator.verification.timeout", "0.5")
    record = started(capsys, repo, tmp_path, "trap '' TERM; " + gated(tmp_path),
                     )
    group = group_of(record)
    shutil.rmtree(str(record))

    assert until(lambda: gone(group), bound=0.5 + 0.3 + 1)
    assert record.exists() is False


def test_a_run_is_delivered_with_no_setsid_on_the_path(repo, tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("PATH", path_without(tmp_path, "setsid"))
    assert shutil.which("setsid") is None

    code = verify(repo, "run", "echo ok")

    assert (code, capsys.readouterr().out) == (0, "ok\n")


# A watch interval short enough for a runner to look at its checkout many times
# inside a test.
FAST_WATCH = "0.05"


def trapping(tmp_path):
    """A command line that logs one start, and, on TERM, writes TERM to
    tmp_path/termed and keeps running: only a KILL ends it."""
    return "trap 'echo TERM >\"%s\"' TERM; %s" % (tmp_path / "termed", gated(tmp_path))


# How a runner its checkout watch stopped is seen: TERM first, the group still
# there just after it, then the group gone and the record removed after the
# grace.
WATCH_STOPPED = (True, True, True, False)


def watch_stop(tmp_path, record, group):
    """How the runner of <record>, its group <group>, ended: whether TERM
    came, the group was there just after it, the group went, and the record
    is still there."""
    termed = until(lambda: (tmp_path / "termed").exists())
    there = not gone(group)
    return (termed, there, until(lambda: gone(group)), record.exists())


def test_a_runner_whose_checkout_root_is_removed_stops_its_command_and_its_record(
        repo, wt, tmp_path, capsys):
    record = started(capsys, wt, tmp_path, trapping(tmp_path), at=repo,
                     ORCH_VERIFICATION_WATCH=FAST_WATCH)
    group = group_of(record)

    shutil.rmtree(str(wt))

    assert watch_stop(tmp_path, record, group) == WATCH_STOPPED


def test_a_runner_whose_identity_token_is_rewritten_stops_and_its_waiting_call_dies(
        repo, tmp_path, capsys):
    knobs = {"ORCH_WAIT_BLOCK": "30", "ORCH_VERIFICATION_WATCH": FAST_WATCH}
    waited = []
    waiting = threading.Thread(
        target=lambda: waited.append(verify(repo, "run", trapping(tmp_path), **knobs)))
    waiting.start()
    assert until(lambda: starts(tmp_path) == 1 and (the_record(repo) / "pid").exists())
    record = the_record(repo)
    group = group_of(record)

    (store(repo) / "id").write_text("another-token\n")

    assert watch_stop(tmp_path, record, group) == WATCH_STOPPED
    waiting.join(timeout=5)
    assert (waited, capsys.readouterr().err) == (
        [1], "orch: the run ended without a status - run the same command again\n")


def test_a_record_removed_mid_run_never_reads_as_a_changed_token(repo, tmp_path, capsys):
    record = started(capsys, repo, tmp_path, gated(tmp_path, ': >"%s"; sleep 0.3; : >"%s"'
                                                   % (tmp_path / "gated", tmp_path / "ended")),
                     ORCH_VERIFICATION_WATCH=FAST_WATCH)
    group = group_of(record)
    shutil.rmtree(str(record))

    (tmp_path / "gate").write_text("")

    assert until(lambda: gone(group))
    assert ((tmp_path / "ended").exists(), record.exists(), records(repo)) == (True, False, [])


def test_a_runner_whose_checkout_is_gone_before_its_command_starts_removes_its_record(
        tmp_path):
    record = tmp_path / "store" / "record"
    record.mkdir(parents=True)
    for name, text in (("root", tmp_path / "gone"), ("id", "token"), ("state", "state")):
        (record / name).write_text("%s\n" % text)

    runner = subprocess.run(
        [sys.executable, "-c", verification.RUNNER_BOOTSTRAP, verification.package_dir(),
         str(record), "true", "10", "0.1", FAST_WATCH],
        stdin=subprocess.DEVNULL,
        timeout=10)

    assert (runner.returncode, record.exists()) == (1, False)
