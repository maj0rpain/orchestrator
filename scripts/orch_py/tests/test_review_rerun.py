"""The review noun's rerun and ci-log verbs, `review rerun <pr>` and `review
ci-log <pr>`, run in-process through review.run in a FakeGit checkout under
tmp_path, the gh fake on its store - each call checked by its stdout, stderr,
exit code and the reruns it leaves: the cases of the bash review rerun and
review ci-log sections. Both read the counted checks - the required ones
where any are reported, else every check - and need no flow. The autopilot
reset record of a GitHub rate limit is met through rerun: the pause and hit
file an autopilot process writes, nothing in a plain one. Cases run again in
an autopilot session print what the plain one prints."""
from __future__ import annotations

from pathlib import Path

import pytest

from conftest import AUTOPILOT, CLAUDE, NOW, SESSIONS, answered, orch_review
from orch.git import FakeGit
from orch.repo import REPO_REMEDY


def rerun(seed, root, *argv, env=None, git=None):
    return orch_review(seed, root, "rerun", *argv, env=env, git=git)


def ci_log(seed, root, *argv, env=None, git=None):
    return orch_review(seed, root, "ci-log", *argv, env=env, git=git)


# --- review rerun ---------------------------------------------------------------


@SESSIONS
@pytest.mark.parametrize("answer, run", [("failing", "4242"), ("cancel", "5150")],
                         ids=["failed", "cancelled"])
def test_a_failing_actions_check_s_run_is_rerun_printing_its_id(root, seed, capsys, env, answer,
                                                                 run):
    seed.checks(7, "all", answer)

    assert answered(capsys, rerun(seed, root, "7", env=env)) == (0, run + "\n", "")
    assert seed.reruns() == [run]


@SESSIONS
@pytest.mark.parametrize("answer, runs", [("tworuns", ["4242", "4343"]), ("onerun", ["4242"])],
                         ids=["two-runs", "one-run"])
def test_each_distinct_run_is_rerun_once_in_the_order_first_met(root, seed, capsys, env, answer,
                                                                 runs):
    seed.checks(7, "required", answer)

    assert answered(capsys, rerun(seed, root, "7", env=env)) == (
        0, "".join(run + "\n" for run in runs), "")
    assert seed.reruns() == runs


NOT_ACTIONS = "orch: check ext-ci on PR #7 is not a GitHub Actions run - nothing to rerun\n"


@SESSIONS
@pytest.mark.parametrize("answer", ["external", "mixed"])
def test_a_failing_check_that_is_no_actions_run_exits_1_rerunning_nothing(root, seed, capsys,
                                                                          env, answer):
    seed.checks(7, "all", answer)

    assert answered(capsys, rerun(seed, root, "7", env=env)) == (1, "", NOT_ACTIONS)
    assert seed.reruns() == []


def test_a_failing_check_linking_no_run_id_exits_1_rerunning_nothing(root, seed, capsys):
    seed.checks(7, "all", "badrunid")

    assert answered(capsys, rerun(seed, root, "7")) == (
        1, "", "orch: check build on PR #7 links no Actions run id - nothing to rerun\n")
    assert seed.reruns() == []


def test_a_failing_required_check_is_rerun_past_an_optional_outside_status(root, seed, capsys):
    seed.checks(7, "required", "failing")
    seed.checks(7, "all", "external")

    assert answered(capsys, rerun(seed, root, "7")) == (0, "4242\n", "")
    assert seed.reruns() == ["4242"]


def test_with_no_required_check_reported_every_check_is_read_at_once(root, seed, capsys):
    seed.checks(7, "all", "failing")

    code = rerun(seed, root, "7", env=dict(CLAUDE, ORCH_CI_GRACE="600"))

    assert answered(capsys, code) == (0, "4242\n", "")


def test_a_refused_second_rerun_leaves_the_first_started_and_exits_2(root, seed, capsys):
    seed.checks(7, "required", "tworuns")
    seed.fail_after("adapter_run_rerun", 1, "HTTP 403: Resource not accessible by integration")

    assert answered(capsys, rerun(seed, root, "7")) == (
        2, "4242\n", "orch: gh could not rerun the failed jobs of Actions run 4343: HTTP 403:"
                     " Resource not accessible by integration\n")
    assert seed.reruns() == ["4242"]


@pytest.mark.parametrize("stderr, reason", [
    ("HTTP 403: Resource not accessible by integration\nsee https://docs.github.com",
     "HTTP 403: Resource not accessible by integration"),
    ("", "gh gave no reason"),
], ids=["gh-s-first-line", "silent"])
def test_a_rerun_gh_refuses_exits_2_naming_the_run(root, seed, capsys, stderr, reason):
    seed.checks(7, "all", "failing")
    seed.fail("adapter_run_rerun", stderr)

    assert answered(capsys, rerun(seed, root, "7")) == (
        2, "", "orch: gh could not rerun the failed jobs of Actions run 4242: %s\n" % reason)


@SESSIONS
@pytest.mark.parametrize("answer, err", [
    ("green", "orch: PR #7 has no failed or cancelled check to rerun\n"),
    ("none", "orch: PR #7 has no checks to rerun: no checks reported on the 'topic' branch\n"),
    ("empty", "orch: PR #7 has no checks to rerun: no checks reported\n"),
    ("boom", "orch: gh could not read the checks of PR #7: dial tcp: lookup api.github.com:"
             " no such host\n"),
], ids=["no-failing-check", "no-checks", "empty-list", "unreadable"])
def test_nothing_to_rerun_exits_2(root, seed, capsys, env, answer, err):
    seed.checks(7, "all", answer)

    assert answered(capsys, rerun(seed, root, "7", env=env)) == (2, "", err)
    assert seed.reruns() == []


@pytest.mark.parametrize("stderr, reason", [("HTTP 502: Bad Gateway\nsecond", "HTTP 502: Bad Gateway"),
                                            ("", "gh gave no reason")],
                         ids=["gh-s-first-line", "silent"])
def test_a_failed_required_checks_read_never_widens_and_exits_2(root, seed, capsys, stderr,
                                                                reason):
    seed.checks(7, "all", "failing")
    seed.fail_times("adapter_pr_checks", 1, stderr)

    assert answered(capsys, rerun(seed, root, "7")) == (
        2, "", "orch: gh could not read the checks of PR #7: %s\n" % reason)
    assert seed.reruns() == []


@pytest.mark.parametrize("argv, err", [
    ((), "orch: usage: orch.sh review rerun <pr>\n"),
    (("7", "8"), "orch: usage: orch.sh review rerun <pr>\n"),
    (("abc",), "orch: not a PR number: abc\n"),
    (("",), "orch: not a PR number: \n"),
], ids=["none", "two", "not-a-number", "empty"])
def test_a_pr_missing_or_not_a_number_exits_2(root, seed, capsys, argv, err):
    assert answered(capsys, rerun(seed, root, *argv)) == (2, "", err)


def test_no_repo_to_work_on_exits_2_with_the_remedy(root, seed, capsys):
    seed.checks(7, "all", "failing")

    code = rerun(seed, root, "7", git=FakeGit(toplevel=str(root)))

    assert answered(capsys, code) == (2, "", "orch: %s\n" % REPO_REMEDY)
    assert seed.reruns() == []


# --- the autopilot reset record, met through rerun --------------------------------

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


def limited(seed, root, main, env, reset=NOW + 1800):
    """`review rerun 7` under a primary limit whose core pool resets at
    <reset>, the main checkout <main>, in <env>: its exit code."""
    seed.checks(7, "all", "failing")
    seed.ratelimit()
    seed.quota("core", 0, 5000, int(reset))
    git = FakeGit({"origin": "https://github.com/acme/widgets.git"}, toplevel=str(root))
    git.seed("main_checkout", answer=str(main))
    return rerun(seed, root, "7", env=env, git=git)


def limit_death(reset):
    return "orch: gh could not read the checks of PR #7: %s\n" % (LIMIT % reset)


def test_a_session_meeting_a_limit_records_the_pause_and_the_hit_file(root, seed, capsys, main,
                                                                      tmp_path):
    hit = tmp_path / "run" / "7.hit"

    code = limited(seed, root, main, dict(AUTOPILOT, ORCH_AUTOPILOT_HIT_FILE=str(hit)))

    assert answered(capsys, code) == (2, "", limit_death("2027-01-15T08:30:00Z"))
    assert pause_of(main).read_bytes() == GOLDEN.read_bytes()
    assert hit.read_bytes() == GOLDEN.read_bytes()


@pytest.mark.parametrize("flag", ["ORCH_AUTOPILOT_TICK", "ORCH_AUTOPILOT_RUN"])
def test_an_autopilot_process_outside_a_session_records_the_pause_and_no_hit_file(
        root, seed, capsys, main, tmp_path, flag):
    hit = tmp_path / "run" / "7.hit"

    code = limited(seed, root, main, dict(CLAUDE, ORCH_AUTOPILOT_HIT_FILE=str(hit), **{flag: "1"}))

    assert answered(capsys, code) == (2, "", limit_death("2027-01-15T08:30:00Z"))
    assert pause_of(main).read_bytes() == GOLDEN.read_bytes()
    assert not hit.exists()


def test_a_plain_process_meeting_a_limit_records_nothing(root, seed, capsys, main, tmp_path):
    hit = tmp_path / "run" / "7.hit"

    code = limited(seed, root, main, dict(CLAUDE, ORCH_AUTOPILOT_HIT_FILE=str(hit)))

    assert answered(capsys, code) == (2, "", limit_death("2027-01-15T08:30:00Z"))
    assert not (main / ".orchestrator").exists()
    assert not hit.exists()


def test_a_reset_past_the_hour_is_recorded_an_hour_on(root, seed, capsys, main):
    code = limited(seed, root, main, AUTOPILOT, reset=NOW + 7200)

    assert answered(capsys, code) == (2, "", limit_death("2027-01-15T10:00:00Z"))
    assert pause_of(main).read_text() == "2027-01-15T09:00:00Z\n"


def test_a_later_reset_already_recorded_is_kept(root, seed, capsys, main):
    pause_of(main).parent.mkdir(parents=True)
    pause_of(main).write_text("2027-01-15T08:50:00Z\n")

    code = limited(seed, root, main, AUTOPILOT)

    assert answered(capsys, code) == (2, "", limit_death("2027-01-15T08:30:00Z"))
    assert pause_of(main).read_text() == "2027-01-15T08:50:00Z\n"


# --- review ci-log --------------------------------------------------------------


def log_of(lines, first=1):
    """A job log of <lines> lines, "log line <n>" each from <first> on, as
    gh prints it."""
    return "".join("log line %d\n" % n for n in range(first, first + lines))


@SESSIONS
def test_a_failing_actions_job_s_log_is_printed_whole_under_its_check_and_job(root, seed, capsys,
                                                                             env):
    seed.checks(7, "all", "failing")
    seed.job_log(77, log_of(3))

    assert answered(capsys, ci_log(seed, root, "7", env=env)) == (
        0, "check build: failed-step log of job 77\n" + log_of(3), "")


def test_a_long_log_is_cut_to_its_last_200_lines_counting_the_cut(root, seed, capsys):
    seed.checks(7, "all", "failing")
    seed.job_log(77, log_of(250))

    assert answered(capsys, ci_log(seed, root, "7")) == (
        0, "check build: failed-step log of job 77\n[cut: 50 earlier lines of 250]\n"
           + log_of(200, first=51), "")


def test_a_log_of_exactly_200_lines_is_not_cut(root, seed, capsys):
    seed.checks(7, "all", "failing")
    seed.job_log(77, log_of(200))

    assert answered(capsys, ci_log(seed, root, "7")) == (
        0, "check build: failed-step log of job 77\n" + log_of(200), "")


def test_a_log_s_trailing_blank_lines_are_dropped_and_an_empty_log_is_one_blank_line(
        root, seed, capsys):
    seed.checks(7, "required", "tworuns")
    seed.job_log(77, "only\n\n\n")
    seed.job_log(78, "")

    assert answered(capsys, ci_log(seed, root, "7")) == (
        0, "check build: failed-step log of job 77\nonly\n"
           "check test: failed-step log of job 78\n\n", "")


def test_only_the_failing_required_checks_are_read_where_any_are_reported(root, seed, capsys):
    seed.checks(7, "required", "failing")
    seed.checks(7, "all", "tworuns")
    seed.job_log(77, log_of(1))
    seed.job_log(78, log_of(1))

    assert answered(capsys, ci_log(seed, root, "7")) == (
        0, "check build: failed-step log of job 77\n" + log_of(1), "")


def test_an_unreadable_log_is_named_and_the_next_job_goes_on(root, seed, capsys):
    seed.checks(7, "all", "tworuns")
    seed.job_log(78, log_of(1))

    assert answered(capsys, ci_log(seed, root, "7")) == (
        0, "check build: the log of job 77 could not be read: log not found\n"
           "check test: failed-step log of job 78\n" + log_of(1), "")


def test_a_failing_check_that_is_no_actions_job_is_named_and_the_next_goes_on(root, seed,
                                                                              capsys):
    seed.checks(7, "all", "external")
    seed.job_log(77, log_of(1))

    assert answered(capsys, ci_log(seed, root, "7")) == (
        0, "check ext-ci is not a GitHub Actions run - no log to read\n"
           "check build: failed-step log of job 77\n" + log_of(1), "")


@pytest.mark.parametrize("answer", ["green", "none"])
def test_nothing_failing_prints_nothing(root, seed, capsys, answer):
    seed.checks(7, "all", answer)

    assert answered(capsys, ci_log(seed, root, "7")) == (0, "", "")


@SESSIONS
@pytest.mark.parametrize("fail, reason", [
    (None, "dial tcp: lookup api.github.com: no such host"),
    ("HTTP 502: Bad Gateway\nsecond", "HTTP 502: Bad Gateway"),
    ("", "gh gave no reason"),
], ids=["unreachable", "gh-s-first-line", "silent"])
def test_a_failed_checks_read_exits_1_with_gh_s_reason(root, seed, capsys, env, fail, reason):
    seed.checks(7, "all", "boom")
    if fail is not None:
        seed.fail("adapter_pr_checks", fail)

    assert answered(capsys, ci_log(seed, root, "7", env=env)) == (
        1, "", "orch: gh could not read the checks of PR #7: %s\n" % reason)


@pytest.mark.parametrize("argv, err", [
    ((), "orch: usage: orch.sh review ci-log <pr>\n"),
    (("abc",), "orch: not a PR number: abc\n"),
    (("",), "orch: not a PR number: \n"),
], ids=["none", "not-a-number", "empty"])
def test_a_pr_missing_or_not_a_number_exits_1(root, seed, capsys, argv, err):
    assert answered(capsys, ci_log(seed, root, *argv)) == (1, "", err)


def test_ci_log_with_no_repo_to_work_on_exits_1_with_the_remedy(root, seed, capsys):
    code = ci_log(seed, root, "7", git=FakeGit(toplevel=str(root)))

    assert answered(capsys, code) == (1, "", "orch: %s\n" % REPO_REMEDY)
