"""The Liveness module's writes, called directly beside its reads, which
doctor already calls: the run and tick records, the hit file, the session log
names and their prune, each under a tmp_path main checkout (the watch
pidfile's cases are test_autopilot_watch.py's). Ported from the deleted bash
liveness section. A live record names the pytest process; a gone one a child
that has exited."""
from __future__ import annotations

import os
import re
import subprocess
import time

import pytest

from orch import liveness

ENV: dict = {}


def dead_pid():
    """The pid of a process that has exited."""
    child = subprocess.Popen(["true"])
    child.wait()
    return child.pid


@pytest.fixture
def main(tmp_path):
    """The main checkout: tmp_path/main, its run directory made."""
    path = tmp_path / "main"
    (path / ".orchestrator" / "autopilot" / "run").mkdir(parents=True)
    return str(path)


def run_file(main, name):
    return os.path.join(main, ".orchestrator", "autopilot", "run", name)


def logs(main):
    return os.path.join(main, ".orchestrator", "autopilot", "logs")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def read(path):
    with open(path) as f:
        return f.read()


# --- run and tick records ------------------------------------------------------


def test_run_begin_writes_the_caller_s_record_and_clears_the_tick_record_and_hit_file(main):
    write(run_file(main, "10.tick"), "old\n")
    write(run_file(main, "10.hit"), "x\n")

    assert liveness.run_begin(main, "10", os.getpid(), ENV) is True
    record = read(run_file(main, "10.pid"))
    assert re.fullmatch(r"%d [^\s]+\n" % os.getpid(), record)
    assert liveness.issue_alive(main, "10", ENV) == (True, str(os.getpid()))
    assert not os.path.exists(run_file(main, "10.tick"))
    assert not os.path.exists(run_file(main, "10.hit"))


def unreadable_proc(tmp_path):
    """An ORCH_PROC_DIR holding this process's entry - so it is read as a
    /proc host - and no stat for any pid: every start time is unreadable."""
    proc = tmp_path / "proc"
    (proc / str(os.getpid())).mkdir(parents=True)
    return {"ORCH_PROC_DIR": str(proc)}


def test_run_begin_with_an_unreadable_start_time_fails_keeping_the_tick_record(
        main, tmp_path, capsys):
    write(run_file(main, "11.tick"), "old\n")

    assert liveness.run_begin(main, "11", 4242, unreadable_proc(tmp_path)) is False
    assert capsys.readouterr().err == "orch: could not read the start time of pid 4242\n"
    assert not os.path.exists(run_file(main, "11.pid"))
    assert read(run_file(main, "11.tick")) == "old\n"


def test_run_begin_whose_run_directory_cannot_be_made_dies_naming_it(tmp_path, capsys):
    main = tmp_path / "main"
    write(str(main / ".orchestrator" / "autopilot"), "a file\n")
    run_dir = str(main / ".orchestrator" / "autopilot" / "run")

    with pytest.raises(SystemExit) as died:
        liveness.run_begin(str(main), "5", os.getpid(), ENV)
    assert (died.value.code, capsys.readouterr().err) == (1, "orch: could not create %s\n" % run_dir)


def test_tick_begin_replaces_an_older_tick_record_with_the_caller_s(main):
    write(run_file(main, "12.tick"), "old\n")

    liveness.tick_begin(main, "12", os.getpid(), ENV)

    assert re.fullmatch(r"%d [^\s]+\n" % os.getpid(), read(run_file(main, "12.tick")))


@pytest.mark.parametrize("unreadable_main", [False, True])
def test_a_tick_record_that_cannot_be_written_warns_and_carries_on(
        main, capsys, unreadable_main):
    run_dir = run_file(main, "")
    os.rmdir(run_dir)
    write(run_dir.rstrip("/"), "a file\n")

    liveness.tick_begin(None if unreadable_main else main, "13", os.getpid(), ENV)

    assert capsys.readouterr().err == "orch: could not write the tick record for issue #13\n"


def test_the_run_record_outranks_the_tick_record(main):
    liveness.tick_begin(main, "8", os.getpid(), ENV)
    write(run_file(main, "8.pid"), "%d 1\n" % os.getpid())

    assert liveness.issue_alive(main, "8", ENV)[0] is False
    os.remove(run_file(main, "8.pid"))
    assert liveness.issue_alive(main, "8", ENV) == (True, str(os.getpid()))


def test_run_end_removes_the_record_only_while_it_names_the_caller(main):
    gone = dead_pid()
    liveness.run_begin(main, "14", os.getpid(), ENV)

    liveness.run_end(main, "14", gone, ENV)
    assert os.path.exists(run_file(main, "14.pid"))
    liveness.run_end(main, "14", os.getpid(), ENV)
    assert not os.path.exists(run_file(main, "14.pid"))

    liveness.run_begin(main, "15", os.getpid(), ENV)
    write(run_file(main, "15.pid"), "999\n")
    liveness.run_end(main, "15", os.getpid(), ENV)
    assert read(run_file(main, "15.pid")) == "999\n"


def test_issue_forget_leaves_neither_record(main):
    liveness.tick_begin(main, "23", os.getpid(), ENV)
    liveness.run_begin(main, "23", os.getpid(), ENV)
    write(run_file(main, "23.tick"), "x\n")

    liveness.issue_forget(main, "23")

    assert sorted(os.listdir(run_file(main, ""))) == []


def test_live_issues_lists_only_live_issues_ascending(main):
    liveness.run_begin(main, "20", os.getpid(), ENV)
    liveness.tick_begin(main, "100", os.getpid(), ENV)
    liveness.tick_begin(main, "21", dead_pid(), ENV)
    write(run_file(main, "22.tick"), "x\n")

    assert liveness.live_issues(main, ENV) == ["20", "100"]


# --- the hit file -----------------------------------------------------------------


def test_hit_take_gives_the_hit_file_s_text_and_removes_it(main):
    write(liveness.hit_path(main, "30"), "2030-01-01T00:00:00Z\n")

    assert liveness.hit_path(main, "30") == run_file(main, "30.hit")
    assert liveness.hit_take(main, "30") == "2030-01-01T00:00:00Z\n"
    assert not os.path.exists(run_file(main, "30.hit"))
    assert liveness.hit_take(main, "30") == ""


# --- session logs -----------------------------------------------------------------

STAMPED = 1767323045.0  # 2026-01-02 03:04:05 UTC


def test_log_path_names_issue_phase_and_stamp_making_the_logs_directory(main):
    path = liveness.log_path(main, "30", "spec", lambda: STAMPED)

    assert path == os.path.join(logs(main), "30-spec-20260102-030405.log")
    assert os.path.isdir(logs(main))


def test_log_path_whose_logs_directory_cannot_be_made_dies_naming_it(main, capsys):
    write(logs(main), "a file\n")

    with pytest.raises(SystemExit) as died:
        liveness.log_path(main, "30", "spec", lambda: STAMPED)
    assert (died.value.code, capsys.readouterr().err) == (1, "orch: could not create %s\n"
                                                          % logs(main))


def test_latest_log_picks_the_newest_by_stamp_of_the_phase_or_of_any(main):
    assert liveness.latest_log(main, "30") == ""
    for name in ("30-spec-20260101-000000.log", "30-spec-20990101-000000.log",
                 "30-implement-20990202-000000.log", "300-spec-20991212-000000.log"):
        write(os.path.join(logs(main), name), "")

    assert liveness.latest_log(main, "30", "spec") == os.path.join(
        logs(main), "30-spec-20990101-000000.log")
    assert liveness.latest_log(main, "30") == os.path.join(
        logs(main), "30-implement-20990202-000000.log")
    assert liveness.latest_log(main, "3") == ""


def aged(path, days):
    """<path> written, last modified <days> days ago."""
    write(path, "")
    then = time.time() - days * 86400
    os.utime(path, (then, then))


def test_the_prune_deletes_only_session_logs_older_than_14_days(main):
    old = liveness.log_path(main, "30", "spec", lambda: STAMPED)
    aged(old, 15)
    fresh = os.path.join(logs(main), "31-spec-20260102-030405.log")
    aged(fresh, 13)
    other = os.path.join(logs(main), "notes.txt")
    aged(other, 30)
    odd = os.path.join(logs(main), "x-spec-20260102-030405.log")
    aged(odd, 30)

    assert liveness.logs_prune(main, time.time()) is True
    assert sorted(os.listdir(logs(main))) == ["31-spec-20260102-030405.log", "notes.txt",
                                              "x-spec-20260102-030405.log"]


def test_the_prune_of_no_logs_directory_is_no_failure(main, capsys):
    assert (liveness.logs_prune(main, time.time()), capsys.readouterr().err) == (True, "")


def test_a_logs_path_that_is_no_directory_warns_and_fails(main, capsys):
    write(logs(main), "a file\n")

    assert liveness.logs_prune(main, time.time()) is False
    assert capsys.readouterr().err == (
        "orch: could not prune the session logs: %s is not a directory\n" % logs(main))


def test_a_logs_directory_that_cannot_be_listed_warns_and_fails(main, capsys, monkeypatch):
    os.makedirs(logs(main))

    def unlistable(path):
        raise PermissionError(13, "Permission denied")

    monkeypatch.setattr(liveness.os, "scandir", unlistable)

    assert liveness.logs_prune(main, time.time()) is False
    assert capsys.readouterr().err == (
        "orch: could not prune the session logs: %s could not be listed\n" % logs(main))


def test_a_session_log_that_cannot_be_deleted_warns_and_the_rest_are_pruned(
        main, capsys, monkeypatch):
    stuck = os.path.join(logs(main), "30-spec-20260101-000000.log")
    gone = os.path.join(logs(main), "31-spec-20260101-000000.log")
    aged(stuck, 20)
    aged(gone, 20)
    remove = os.remove

    def refusing(path, *args, **kwargs):
        if path == stuck:
            raise PermissionError(13, "Permission denied")
        remove(path, *args, **kwargs)

    monkeypatch.setattr(liveness.os, "remove", refusing)

    assert liveness.logs_prune(main, time.time()) is False
    assert capsys.readouterr().err == "orch: could not delete the old session log %s\n" % stuck
    assert os.listdir(logs(main)) == ["30-spec-20260101-000000.log"]
