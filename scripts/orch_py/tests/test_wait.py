"""The wait module's handling of a GitHub rate limit inside a re-callable
wait, against a clock and a sleep the test hands in, with the orchestrator
directory under tmp_path: the provisional guard of a read made before the
wait's key is known and its check, the ORCH_WAIT_BLOCK knob check, the
limited mark that ends a call as still running, and the decision whether a
limit wait fits in what is left of the block."""
from __future__ import annotations

import os
from pathlib import Path

import pytest

from orch import wait
from conftest import NOW, died_of
from conftest import FakeClock as Clock

KEY = "review ci 4 0123abc"


def orch_dir(tmp_path):
    return str(tmp_path / ".orchestrator")


def guarded(tmp_path, block="5", clock=None, name="4"):
    clock = Clock() if clock is None else clock
    return wait.Guard.open(orch_dir(tmp_path), name, block, clock=clock, sleep=clock.sleep)


def opened(tmp_path, block="5", clock=None, key=KEY):
    clock = Clock() if clock is None else clock
    return wait.StoredTotal.open(orch_dir(tmp_path), key, block, clock=clock, sleep=clock.sleep)


# --- the provisional guard ---------------------------------------------------


def test_the_guard_marks_under_its_provisional_name_and_clears_an_old_mark(tmp_path):
    folder = tmp_path / ".orchestrator" / "wait"
    folder.mkdir(parents=True)
    (folder / "pending-4.limited").write_text("")

    guard = guarded(tmp_path)

    assert guard.mark == str(folder / "pending-4.limited")
    assert not Path(guard.mark).exists()
    assert guard.check() is True


# --- the limited mark ----------------------------------------------------------


def test_a_limit_the_block_could_not_hold_ends_the_call_storing_the_total(tmp_path):
    clock = Clock()
    total = opened(tmp_path, block="5", clock=clock)
    assert total.tick("1") is True

    assert total.limit_fits(60) is False
    assert Path(total.mark).exists()
    assert total.limited_check() is False

    assert not Path(total.mark).exists()
    assert Path(total.file).read_text() == "1800000000\n1.000\n"


def test_with_no_mark_left_the_limited_check_goes_on(tmp_path):
    total = opened(tmp_path)

    assert total.limited_check() is True
    assert Path(total.file).read_text() == "1800000000\n0\n"


def test_the_total_s_mark_ends_the_call_a_guard_opened_before_it(tmp_path):
    clock = Clock()
    guard = guarded(tmp_path, block="5", clock=clock)
    clock.now += 3

    total = wait.StoredTotal.open(orch_dir(tmp_path), KEY, "5", clock=clock, sleep=clock.sleep,
                                  call_start=guard.call_start)

    assert total.limit_fits(60) is False
    assert clock.slept == [2]
    assert total.limited_check() is False


# --- the fits decision ---------------------------------------------------------


@pytest.mark.parametrize("spent, seconds", [(0, 60), (10, 50)], ids=["roomy", "exactly"])
def test_a_limit_wait_the_rest_of_the_block_holds_fits_with_no_sleep_and_no_mark(
        tmp_path, spent, seconds):
    clock = Clock()
    total = opened(tmp_path, block="60", clock=clock)
    clock.now += spent

    assert total.limit_fits(seconds) is True
    assert clock.slept == []
    assert not Path(total.mark).exists()


def test_a_call_whose_block_is_spent_marks_the_limit_without_sleeping(tmp_path):
    clock = Clock()
    total = opened(tmp_path, block="5", clock=clock)
    clock.now += 7

    assert total.limit_fits(1) is False
    assert clock.slept == []
    assert Path(total.mark).exists()


def test_the_rest_of_a_fractional_block_is_slept_as_awk_prints_it(tmp_path):
    clock = Clock()
    guard = guarded(tmp_path, block="0.25", clock=clock)

    assert guard.limit_fits(60) is False
    assert clock.slept == [0.25]


def test_a_mark_that_cannot_be_written_still_answers_that_the_wait_does_not_fit(tmp_path):
    clock = Clock()
    guard = guarded(tmp_path, block="5", clock=clock)
    Path(guard.mark).mkdir()

    assert guard.limit_fits(60) is False
    assert clock.slept == [5]


# --- the ORCH_WAIT_BLOCK knob check ------------------------------------------


@pytest.mark.parametrize("env, block", [({}, "570"), ({"ORCH_WAIT_BLOCK": ""}, "570"),
                                        ({"ORCH_WAIT_BLOCK": "0.5"}, "0.5")],
                         ids=["unset", "empty", "set"])
def test_the_block_is_the_knob_s_text_else_its_default(env, block):
    assert wait.wait_block(env, code=2) == block


@pytest.mark.parametrize("value, message", [
    ("soon", "ORCH_WAIT_BLOCK is not a number: soon"),
    ("0", "ORCH_WAIT_BLOCK must be greater than zero: 0"),
], ids=["not-a-number", "zero"])
@pytest.mark.parametrize("code", [1, 2], ids=["die", "die2"])
def test_a_bad_block_dies_through_the_dier_given(capsys, value, message, code):
    died = died_of(capsys, lambda: wait.wait_block({"ORCH_WAIT_BLOCK": value}, code=code))

    assert died == (code, "", "orch: %s\n" % message)


# --- a failed key, folder or total write -----------------------------------------


def test_a_wait_that_cannot_be_keyed_dies_making_no_folder(tmp_path, capsys):
    code, out, err = died_of(capsys, lambda: opened(tmp_path, key="review ci \ud800"))

    assert (code, out, err) == (1, "", "orch: could not key the wait\n")
    assert not (tmp_path / ".orchestrator").exists()


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_total_that_cannot_be_stored_at_the_block_s_end_dies_leaving_the_old_total(
        tmp_path, capsys):
    clock = Clock()
    total = opened(tmp_path, block="1", clock=clock)
    folder = tmp_path / ".orchestrator" / "wait"
    folder.chmod(0o555)
    try:
        code, out, err = died_of(capsys, lambda: total.tick("5"))
    finally:
        folder.chmod(0o755)

    assert (code, out, err) == (1, "", "orch: could not store the wait\n")
    assert sorted(p.name for p in folder.iterdir()) == [Path(total.file).name]
    assert Path(total.file).read_text() == "1800000000\n0\n"
