"""The wait module's stored total of a re-callable wait, against a clock and
a sleep the test hands in, with the orchestrator directory under tmp_path -
and against the golden stored-total files of wait/, which the bash wait
section reads and advances too, with the same expected values (ADR-0067):
wait/stored-total is a total with 1.2 s slept, its first call's epoch second
far in the future so the slept total alone counts, and
wait/stored-total.advanced the same total after one call of 1-second ticks
under a 5-second block."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from orch import wait
from conftest import NOW, died_of
from conftest import FakeClock as Clock

GOLDEN = Path(__file__).resolve().parent / "wait"
# The fixed key the golden total is stored under.
KEY = "spec-review wait /golden/round fidelity testability"

def opened(tmp_path, block="5", clock=None, key=KEY):
    clock = Clock() if clock is None else clock
    return wait.StoredTotal.open(str(tmp_path / ".orchestrator"), key, block,
                                 clock=clock, sleep=clock.sleep)


def stored_at(tmp_path, golden, key=KEY):
    """The golden file <golden> stored as the total of <key>: its path."""
    path = tmp_path / ".orchestrator" / "wait" / wait.blob_hash(key)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((GOLDEN / golden).read_bytes())
    return path


def test_the_key_s_blob_hash_is_git_hash_object_s():
    hashed = subprocess.run(["git", "hash-object", "--stdin"], input=KEY.encode(),
                            stdout=subprocess.PIPE, check=True).stdout.decode().strip()

    assert wait.blob_hash(KEY) == hashed == "f4c1ada8b0ffdf5cf70c6db3a8c2f75d827aac30"


def test_the_golden_total_is_read_as_its_seconds_slept(tmp_path):
    stored_at(tmp_path, "stored-total")

    assert opened(tmp_path).taken() == 1.2


def test_the_golden_total_advanced_by_one_call_is_the_advanced_golden(tmp_path):
    path = stored_at(tmp_path, "stored-total")
    total = opened(tmp_path, block="5", clock=Clock(NOW + 0.5))

    ticks = 0
    while total.tick("1"):
        ticks += 1

    assert ticks == 4
    assert path.read_bytes() == (GOLDEN / "stored-total.advanced").read_bytes()


def test_a_new_total_is_stored_at_once_from_the_first_call(tmp_path):
    total = opened(tmp_path)

    assert total.file == str(tmp_path / ".orchestrator" / "wait" / wait.blob_hash(KEY))
    assert Path(total.file).read_text() == "1800000000\n0\n"
    assert total.taken() == 0


def test_the_wall_clock_since_the_first_call_counts_when_it_is_the_larger(tmp_path):
    stored_at(tmp_path, "stored-total")
    path = tmp_path / ".orchestrator" / "wait" / wait.blob_hash(KEY)
    path.write_text("1799999990\n1.200\n")

    assert opened(tmp_path).taken() == 10


@pytest.mark.parametrize("text", ["", "x\n0\n", "1\n", "1\nsoon\n", "-1\n0\n", "1.5\n0\n"],
                         ids=["empty", "start", "one-line", "slept", "negative", "point"])
def test_a_total_whose_lines_are_not_numbers_starts_afresh(tmp_path, text):
    path = stored_at(tmp_path, "stored-total")
    path.write_text(text)

    total = opened(tmp_path)

    assert path.read_text() == "1800000000\n0\n"
    assert total.taken() == 0


def test_a_tick_sleeps_the_interval_and_a_call_ends_once_its_block_is_spent(tmp_path):
    clock = Clock()
    total = opened(tmp_path, block="1", clock=clock)

    assert total.tick("0.3") is True
    assert total.tick("0.3") is True
    assert total.tick("0.3") is True
    assert total.tick("0.3") is False

    assert clock.slept == [0.3, 0.3, 0.3, 0.1]
    assert Path(total.file).read_text() == "1800000000\n1.000\n"


def test_a_tick_never_sleeps_past_the_block(tmp_path):
    clock = Clock()
    total = opened(tmp_path, block="0.5", clock=clock)

    assert total.tick("6") is False
    assert clock.slept == [0.5]


def test_the_next_call_goes_on_from_the_stored_total(tmp_path):
    first = opened(tmp_path, block="1")
    while first.tick("0.5"):
        pass

    assert opened(tmp_path, block="1", clock=Clock(NOW + 1)).taken() == 1


def test_forget_removes_the_total_and_its_limited_mark(tmp_path):
    total = opened(tmp_path)
    Path(total.mark).write_text("")

    total.forget()

    assert sorted(p.name for p in (tmp_path / ".orchestrator" / "wait").iterdir()) == []
    assert total.mark == total.file + ".limited"


def test_a_wait_folder_that_cannot_be_created_dies_naming_it(tmp_path, capsys):
    (tmp_path / ".orchestrator").mkdir()
    (tmp_path / ".orchestrator" / "wait").write_text("a file\n")

    code, out, err = died_of(capsys, lambda: opened(tmp_path))

    assert (code, out, err) == (
        1, "", "orch: could not create %s/.orchestrator/wait\n" % tmp_path)


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_total_that_cannot_be_stored_dies(tmp_path, capsys):
    folder = tmp_path / ".orchestrator" / "wait"
    folder.mkdir(parents=True)
    folder.chmod(0o555)
    try:
        code, out, err = died_of(capsys, lambda: opened(tmp_path))
    finally:
        folder.chmod(0o755)

    assert (code, out, err) == (1, "", "orch: could not store the wait\n")
