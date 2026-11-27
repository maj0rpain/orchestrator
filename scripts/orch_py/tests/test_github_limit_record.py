"""The autopilot reset record of a GitHub API rate limit given up on: in an
autopilot process the gh adapter's limit handling writes the GitHub limit
pause under the main checkout, replacing an earlier or unreadable reset
recorded, and in a session the wrapper's hit file too, each failed write
joined onto the one limit line after " - ". Met through the gh fake on its
store, the main checkout a FakeGit's, the clock handed in - and the pause
file pinned to github_pause/github-limit, a golden file autopilot's bash
tick section reads too (ADR-0067): the reset NOW + 1800 as the pause file
holds it. Which processes write the pause and the hit file, the reset capped
at an hour and a later reset already recorded kept are test_review_rerun.py's
cases, met through `review rerun`."""
from __future__ import annotations

from pathlib import Path

import pytest

from orch.gh import GhFailed
from orch.gh_fake import FakeGh
from orch.git import FakeGit
from orch.repo import RepoPin

from conftest import NOW, orch_issue

GOLDEN = Path(__file__).resolve().parent / "github_pause" / "github-limit"
LIMIT = ("orch: GitHub API rate limit reached - it resets at %s. An autopilot session ends"
         " its turn now and does not retry; the watcher picks the work up after the reset.")


@pytest.fixture
def main(tmp_path):
    """The main checkout's root, tmp_path/main."""
    path = tmp_path / "main"
    path.mkdir()
    return path


def pause_of(main):
    return main / ".orchestrator" / "autopilot" / "github-limit"


def limited_gh(seed, main, env, reset=NOW + 1800, unreadable=False):
    """The gh fake on <seed>'s store under a primary limit whose core pool
    resets at <reset>, issue #5 open, in <env>, its main checkout <main> - or
    one that cannot be read."""
    seed.issue(5, "open")
    seed.ratelimit()
    seed.quota("core", 0, 5000, int(reset))
    git = FakeGit({"origin": "https://github.com/fork/widgets.git"})
    if not unreadable:
        git.seed("main_checkout", answer=str(main))
    return FakeGh(seed.store, env, pin=RepoPin(env, git), sleep=lambda _: None, now=lambda: NOW)


def limited(seed, main, env, **kwargs):
    """The stderr issue #5's body read fails with, through limited_gh."""
    with pytest.raises(GhFailed) as failed:
        limited_gh(seed, main, env, **kwargs).issue_body(5)
    return failed.value.stderr


@pytest.mark.parametrize("text", ["2027-01-15T08:10:00Z\n", "soon\n", ""],
                         ids=["earlier", "unreadable", "empty"])
def test_an_earlier_or_unreadable_reset_recorded_is_replaced(seed, main, text):
    pause_of(main).parent.mkdir(parents=True)
    pause_of(main).write_text(text)

    limited(seed, main, {"ORCH_AUTOPILOT_RUN": "1"})

    assert pause_of(main).read_bytes() == GOLDEN.read_bytes()


def test_a_failed_pause_write_is_joined_onto_the_limit_line(seed, main):
    pause_of(main).mkdir(parents=True)

    stderr = limited(seed, main, {"ORCH_AUTOPILOT": "1"})

    assert stderr == (LIMIT % "2027-01-15T08:30:00Z"
                      + " - could not write the GitHub limit pause under %s\n" % main)


def test_an_unreadable_main_checkout_is_joined_onto_the_limit_line(seed, main):
    stderr = limited(seed, main, {"ORCH_AUTOPILOT_TICK": "1"}, unreadable=True)

    assert stderr == (LIMIT % "2027-01-15T08:30:00Z" + " - could not write the GitHub limit"
                      " pause: the main checkout is unreadable\n")


def test_both_failed_writes_are_joined_in_order(seed, main, tmp_path):
    hit = tmp_path / "5.hit"
    hit.mkdir()
    pause_of(main).mkdir(parents=True)

    stderr = limited(seed, main, {"ORCH_AUTOPILOT": "1", "ORCH_AUTOPILOT_HIT_FILE": str(hit)})

    assert stderr == (LIMIT % "2027-01-15T08:30:00Z"
                      + " - could not write the GitHub limit pause under %s;" % main
                      + " could not write the GitHub limit hit file %s\n" % hit)


def test_a_converted_noun_meeting_a_limit_in_a_session_records_the_pause(
        seed, main, tmp_path, capsys):
    hit = tmp_path / "run" / "5.hit"
    env = {"ORCH_AUTOPILOT": "1", "ORCH_AUTOPILOT_HIT_FILE": str(hit)}
    gh = limited_gh(seed, main, env)

    code = orch_issue(seed, "fetch", "5", str(tmp_path / "body.md"), gh=gh, env=env)

    assert code == 1
    assert (LIMIT % "2027-01-15T08:30:00Z") in capsys.readouterr().err
    assert pause_of(main).read_bytes() == GOLDEN.read_bytes()
    assert hit.read_bytes() == GOLDEN.read_bytes()
