"""The spec-review noun's wait verb, run in-process against FakeGit and a
FakeClock - its sleep advancing its clock, so no test sleeps - with the
round directory and the orchestrator directory's wait/ folder under
tmp_path, each call checked by its stdout, its exit code, its `orch:` lines
and the stored total it leaves - as the bash spec-review wait answered."""
from __future__ import annotations

import os

import pytest

from orch import wait
from conftest import FakeClock, orch_spec_review

FAST = {"ORCH_SPEC_REVIEW_WAIT_TIMEOUT": "1", "ORCH_SPEC_REVIEW_WAIT_INTERVAL": "0.05"}
USAGE = "orch: usage: orch.sh spec-review wait <dir> <lens>...\n"
UNKNOWN = ("orch: unknown lens 'clarity'"
           " (want one of: fidelity consistency testability implementability)\n")


@pytest.fixture
def lenses(tmp_path):
    """A round directory, outside the checkout, as a mktemp one is."""
    path = tmp_path.resolve() / "round"
    path.mkdir()
    return path


def back(directory, lens, text):
    (directory / ("lens-%s.md" % lens)).write_text(text)


def call(root, *args, env=None, clock=None):
    clock = FakeClock() if clock is None else clock
    return orch_spec_review(root, "wait", *(str(a) for a in args), env=dict(FAST, **(env or {})),
                            clock=clock, sleep=clock.sleep)


def total_of(root, directory, *names):
    """The stored total's file of the wait on <directory> and <names>."""
    key = "spec-review wait %s %s" % (directory, " ".join(names))
    return root / ".orchestrator" / "wait" / wait.blob_hash(key)


def wait_folder(root):
    folder = root / ".orchestrator" / "wait"
    return sorted(os.listdir(str(folder))) if folder.is_dir() else []


# --- the summary ------------------------------------------------------------------


def test_every_named_lens_back_prints_the_summary_in_the_order_named(root, lenses, capsys):
    back(lenses, "testability", "@@ finding 1\nOne.\n@@ finding 2\nTwo.\n")
    back(lenses, "consistency", "@@ none\n")
    back(lenses, "implementability", "neither kind of line\n")

    assert call(root, lenses, "testability", "consistency", "implementability") == 0

    assert capsys.readouterr() == (
        "lenses back: testability 2, consistency 0, implementability 0\n", "")
    assert wait_folder(root) == []


def test_an_empty_findings_file_is_back_counting_0_under_a_trailing_slash(root, lenses, capsys):
    back(lenses, "implementability", "")

    assert call(root, "%s/" % lenses, "implementability") == 0

    assert capsys.readouterr().out == "lenses back: implementability 0\n"


def test_only_the_named_lenses_are_waited_for(root, lenses, capsys):
    back(lenses, "consistency", "@@ none\n")

    assert call(root, lenses, "consistency") == 0

    assert capsys.readouterr().out == "lenses back: consistency 0\n"


def test_a_file_that_appears_during_the_wait_ends_it_with_its_count(root, lenses, capsys):
    def arrive(sleeps):
        if sleeps == 6:
            back(lenses, "fidelity", "@@ finding 1\nLate.\n")
    clock = FakeClock(on_sleep=arrive)

    assert call(root, lenses, "fidelity", env={"ORCH_SPEC_REVIEW_WAIT_TIMEOUT": "5"},
                clock=clock) == 0

    assert capsys.readouterr() == ("lenses back: fidelity 1\n", "")
    assert len(clock.slept) == 6
    assert wait_folder(root) == []


# --- the timeout ----------------------------------------------------------------------


def test_a_lens_missing_past_the_timeout_fails_naming_only_it(root, lenses, capsys):
    for lens in ("testability", "consistency", "implementability"):
        back(lenses, lens, "@@ none\n")

    assert call(root, lenses, "testability", "fidelity", "consistency", "implementability") == 1

    assert capsys.readouterr() == ("", "orch: lenses not back after 1s: fidelity\n")
    assert wait_folder(root) == []


def test_two_missing_lenses_are_named_in_the_order_named(root, lenses, capsys):
    back(lenses, "testability", "@@ none\n")

    assert call(root, lenses, "consistency", "testability", "fidelity") == 1

    assert capsys.readouterr().err == "orch: lenses not back after 1s: consistency fidelity\n"


# --- the refusals -----------------------------------------------------------------------


def test_an_unknown_lens_is_refused_naming_the_four(root, lenses, capsys):
    assert call(root, lenses, "testability", "clarity") == 1

    assert capsys.readouterr() == ("", UNKNOWN)


@pytest.mark.parametrize("lens", ["consistency testability", ""], ids=["two-in-one", "empty"])
def test_a_lens_is_matched_whole(root, lenses, capsys, lens):
    assert call(root, lenses, lens) == 1

    assert "unknown lens '%s'" % lens in capsys.readouterr().err


def test_a_missing_directory_is_refused_naming_it(root, lenses, capsys):
    assert call(root, lenses / "nowhere", "testability") == 1

    assert capsys.readouterr() == ("", "orch: no such directory: %s/nowhere\n" % lenses)


def test_the_directory_is_checked_before_the_lenses(root, lenses, capsys):
    assert call(root, lenses / "nowhere", "clarity") == 1

    assert "no such directory" in capsys.readouterr().err


@pytest.mark.parametrize("args", [(), ("dir",)], ids=["none", "no-lens"])
def test_a_wait_with_no_lens_names_is_refused_with_the_usage(root, lenses, capsys, args):
    assert call(root, *(lenses if a == "dir" else a for a in args)) == 1

    assert capsys.readouterr() == ("", USAGE)


@pytest.mark.parametrize("knob, value, message", [
    ("ORCH_SPEC_REVIEW_WAIT_TIMEOUT", "soon", "ORCH_SPEC_REVIEW_WAIT_TIMEOUT is not a number: soon"),
    ("ORCH_SPEC_REVIEW_WAIT_INTERVAL", "often",
     "ORCH_SPEC_REVIEW_WAIT_INTERVAL is not a number: often"),
    ("ORCH_SPEC_REVIEW_WAIT_INTERVAL", "0.0",
     "ORCH_SPEC_REVIEW_WAIT_INTERVAL must be greater than zero: 0.0"),
    ("ORCH_WAIT_BLOCK", "0", "ORCH_WAIT_BLOCK must be greater than zero: 0"),
    ("ORCH_WAIT_BLOCK", "abc", "ORCH_WAIT_BLOCK is not a number: abc"),
])
def test_a_bad_knob_is_refused_naming_it_before_any_total_is_stored(
        root, lenses, capsys, knob, value, message):
    assert call(root, lenses, "fidelity", env={knob: value}) == 1

    assert capsys.readouterr() == ("", "orch: %s\n" % message)
    assert wait_folder(root) == []


def test_an_unknown_lens_is_refused_before_the_knobs(root, lenses, capsys):
    assert call(root, lenses, "clarity", env={"ORCH_SPEC_REVIEW_WAIT_TIMEOUT": "soon"}) == 1

    assert capsys.readouterr().err == UNKNOWN


def test_empty_knobs_take_their_defaults(root, lenses, capsys):
    clock = FakeClock()
    env = {"ORCH_SPEC_REVIEW_WAIT_TIMEOUT": "", "ORCH_SPEC_REVIEW_WAIT_INTERVAL": "",
           "ORCH_WAIT_BLOCK": ""}

    assert call(root, lenses, "fidelity", env=env, clock=clock) == 75

    assert capsys.readouterr().err == "orch: still running after 570s - run the same command again\n"
    assert set(clock.slept) == {5}


def test_a_wait_folder_that_cannot_be_created_is_refused(root, lenses, capsys):
    (root / ".orchestrator").mkdir()
    (root / ".orchestrator" / "wait").write_text("a file\n")

    assert call(root, lenses, "fidelity") == 1

    assert capsys.readouterr() == ("", "orch: could not create %s/.orchestrator/wait\n" % root)


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_stored_total_that_cannot_be_written_is_refused(root, lenses, capsys):
    folder = root / ".orchestrator" / "wait"
    folder.mkdir(parents=True)
    folder.chmod(0o555)
    try:
        assert call(root, lenses, "fidelity") == 1
    finally:
        folder.chmod(0o755)

    assert capsys.readouterr() == ("", "orch: could not store the wait\n")


# --- the re-callable wait ----------------------------------------------------------------

BLOCKED = {"ORCH_SPEC_REVIEW_WAIT_TIMEOUT": "2", "ORCH_WAIT_BLOCK": "0.2"}
STILL = "orch: still running after 0.2s - run the same command again\n"


def test_a_wait_not_over_within_its_block_exits_75_keeping_its_total(root, lenses, capsys):
    assert call(root, lenses, "fidelity", env=BLOCKED) == 75

    assert capsys.readouterr() == ("", STILL)
    assert total_of(root, lenses, "fidelity").read_text() == "1800000000\n0.200\n"


def test_the_same_line_run_again_goes_on_from_the_stored_total_to_the_timeout(
        root, lenses, capsys):
    clock = FakeClock()
    codes = []
    while not codes or codes[-1] == 75:
        codes.append(call(root, lenses, "fidelity", env=BLOCKED, clock=clock))
        if codes[-1] == 75:
            capsys.readouterr()

    assert codes == [75] * (len(codes) - 1) + [1]
    assert 2 <= len(codes) <= 12
    assert capsys.readouterr() == ("", "orch: lenses not back after 2s: fidelity\n")
    assert wait_folder(root) == []


def test_after_the_timeout_a_new_total_starts(root, lenses):
    total = total_of(root, lenses, "fidelity")
    total.parent.mkdir(parents=True)
    total.write_text("1800000000\n5\n")
    (total.parent / (total.name + ".limited")).write_text("")
    assert call(root, lenses, "fidelity", env=BLOCKED) == 1

    assert wait_folder(root) == []
    assert call(root, lenses, "fidelity", env=BLOCKED) == 75


def test_a_delivered_wait_forgets_its_total_and_its_mark(root, lenses, capsys):
    total = total_of(root, lenses, "fidelity")
    total.parent.mkdir(parents=True)
    total.write_text("1800000000\n1.900\n")
    (total.parent / (total.name + ".limited")).write_text("")
    back(lenses, "fidelity", "@@ none\n")

    assert call(root, lenses, "fidelity", env=BLOCKED) == 0

    assert capsys.readouterr().out == "lenses back: fidelity 0\n"
    assert wait_folder(root) == []


def test_other_lenses_keep_a_total_of_their_own(root, lenses):
    clock = FakeClock()
    for _ in range(3):
        call(root, lenses, "fidelity", "testability", env=BLOCKED, clock=clock)

    assert call(root, lenses, "consistency", env=BLOCKED, clock=clock) == 75
    assert total_of(root, lenses, "consistency").read_text().endswith("\n0.200\n")
    assert total_of(root, lenses, "fidelity", "testability").read_text().endswith("\n0.600\n")


def test_a_stored_total_whose_lines_are_not_numbers_starts_afresh(root, lenses):
    total = total_of(root, lenses, "fidelity")
    total.parent.mkdir(parents=True)
    total.write_text("soon\nlater\n")

    assert call(root, lenses, "fidelity", env=BLOCKED) == 75

    assert total.read_text() == "1800000000\n0.200\n"


def test_the_key_names_the_directory_resolved(root, lenses, tmp_path):
    link = tmp_path / "link"
    link.symlink_to(lenses)

    assert call(root, link, "fidelity", env=BLOCKED) == 75

    assert total_of(root, lenses, "fidelity").is_file()
