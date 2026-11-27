"""The review noun's ci verb, `review ci [--no-wait] [<pr>]`, run in-process
through review.run in a FakeGit checkout under tmp_path, with flow state and
the wait store there, the gh fake on its store and a FakeClock - its sleep
advancing its clock, so no test sleeps - each call checked by its stdout,
stderr, exit code and the files it leaves: the cases of the bash review ci,
grace-from-the-push (#475), --no-wait, no-CI-evidence (#476) and review ci
<pr> sections, and the rate limits met inside it. Cases run again in an
autopilot session print what the plain one prints."""
from __future__ import annotations

import os
import subprocess

import pytest

from conftest import (AUTOPILOT, CLAUDE, GITHUB_ORIGIN, NOW, SESSIONS, FakeClock, answered,
                      hold_flow, orch_review, snapshot)
from orch.gh_fake import FakeGh
from orch.git import FakeGit
from orch.repo import REPO_REMEDY

# review_ci_flow's short knobs.
KNOBS = {"ORCH_CI_GRACE": "0.3", "ORCH_CI_TIMEOUT": "1", "ORCH_CI_INTERVAL": "0.05"}
HEAD = "a" * 40
EARLIER = "2" * 40
NEWER = "4" * 40
TRACKING = "refs/remotes/origin/topic"
INDENT = "      "


def checkout(root):
    """The FakeGit of the checkout at <root>, its origin on GitHub."""
    return FakeGit(GITHUB_ORIGIN, toplevel=str(root))


def ci(root, seed, *argv, env=None, clock=None, git=None, gh=None):
    """`orch.sh review ci <argv>` through orch_review, under Claude Code's
    plain session with KNOBS and <env> over them: its exit code."""
    env = dict(dict(CLAUDE, **KNOBS), **(env or {}))
    return orch_review(seed, root, "ci", *argv, env=env, clock=clock, git=git, gh=gh)


@pytest.fixture
def bare_flow(root, seed):
    """A flow at review with PR #7 recorded, open from topic onto main in
    the store, and no CI signal anywhere."""
    hold_flow(root, slug="reviewci", phase="review", issue=3, pr=7)
    seed.pr(7, "open", "topic", "main")
    return root


@pytest.fixture
def flow(bare_flow, seed):
    """review_ci_flow: bare_flow, the base tip's one check run as the CI
    evidence that keeps the grace."""
    seed.check_run("main")
    return bare_flow


def wait_dir(root):
    return root / ".orchestrator" / "wait"


def waits(root):
    """The names the wait store holds, sorted; none where it is absent."""
    return sorted(os.listdir(str(wait_dir(root)))) if wait_dir(root).is_dir() else []


def key_of(text):
    """The stored total's file name for the wait <text> names, as git
    hashes it."""
    return subprocess.run(["git", "hash-object", "--stdin"], input=text.encode(),
                          stdout=subprocess.PIPE, check=True).stdout.decode().strip()


def still(block):
    return "orch: still running after %ss - run the same command again\n" % block


def pushed(git, head, age):
    """<head> pushed to origin's topic <age> seconds before NOW, by the
    remote-tracking ref's reflog."""
    git.seed("ref_exists", TRACKING, answer=True)
    git.seed("reflog_dates", TRACKING, answer=[(head, int(NOW) - age)])


# --- the verdicts ---------------------------------------------------------------


@SESSIONS
@pytest.mark.parametrize("answer, code, out", [
    ("green", 0, "green\n"),
    ("failing", 1, "failing\n%sbuild\n" % INDENT),
    ("cancel", 1, "failing\n%sbuild\n" % INDENT),
    ("none", 0, "none\n%snothing reported before the 0.3s grace ran out\n" % INDENT),
    ("boom", 1, "unreachable\n%sdial tcp: lookup api.github.com: no such host\n" % INDENT),
], ids=["green", "failing", "cancel", "none", "unreachable"])
def test_each_verdict_prints_its_word_and_detail_lines_with_its_exit(flow, seed, capsys, env,
                                                                      answer, code, out):
    seed.checks(7, "all", answer)

    assert answered(capsys, ci(flow, seed, env=env)) == (code, out, "")


# --- the required-then-counted widening ------------------------------------------


def test_a_required_check_not_yet_registered_is_waited_for_inside_the_grace(flow, seed, capsys):
    seed.checks(7, "required", "none", "green")
    seed.checks(7, "all", "failing")

    assert answered(capsys, ci(flow, seed, env={"ORCH_CI_GRACE": "5"})) == (0, "green\n", "")


def test_required_checks_decide_it_where_branch_protection_names_them(flow, seed, capsys):
    seed.checks(7, "required", "green")
    seed.checks(7, "all", "failing")

    assert answered(capsys, ci(flow, seed)) == (0, "green\n", "")


def test_a_repo_requiring_nothing_widens_to_every_check_once_the_grace_is_out(flow, seed,
                                                                               capsys):
    seed.checks(7, "required", "none")
    seed.checks(7, "all", "green")

    assert answered(capsys, ci(flow, seed, env={"ORCH_CI_GRACE": "0.2"})) == (0, "green\n", "")


@SESSIONS
def test_checks_still_pending_at_the_timeout_are_unreachable(flow, seed, capsys, env):
    seed.checks(7, "all", "pending")

    assert answered(capsys, ci(flow, seed, env=dict(env, ORCH_CI_TIMEOUT="0.2"))) == (
        1, "unreachable\n%schecks were still pending after 0.2s\n" % INDENT, "")
    assert waits(flow) == []


def test_checks_nobody_could_read_are_unreachable_not_none(flow, seed, capsys):
    seed.fail("adapter_pr_checks", "gh pr checks answered with something jq could not read")

    assert answered(capsys, ci(flow, seed)) == (
        1, "unreachable\n%sgh pr checks answered with something jq could not read\n" % INDENT, "")


# --- the grace counts from the push (#475) --------------------------------------


@pytest.fixture
def pushed_flow(flow, seed):
    """flow, PR #7's head HEAD, pushed an hour ago: its git adapter."""
    seed.pr_head(7, HEAD)
    git = checkout(flow)
    pushed(git, HEAD, 3600)
    return git


@pytest.mark.parametrize("argv", [(), ("--no-wait",)], ids=["waiting", "no-wait"])
def test_an_old_push_with_nothing_reported_is_none_without_waiting_the_grace(flow, seed, capsys,
                                                                            pushed_flow, argv):
    seed.checks(7, "required", "none", "green")
    seed.checks(7, "all", "none")
    clock = FakeClock()

    code = ci(flow, seed, *argv, env={"ORCH_CI_GRACE": "5"}, git=pushed_flow, clock=clock)

    assert answered(capsys, code) == (
        0, "none\n%snothing reported before the 5s grace ran out\n" % INDENT, "")
    assert clock.slept == []


def test_a_reflog_entry_for_another_sha_leaves_the_grace_counting_from_the_call(
        flow, seed, capsys, pushed_flow):
    seed.checks(7, "required", "none", "green")
    seed.pr_head(7, "1" * 40)

    code = ci(flow, seed, env={"ORCH_CI_GRACE": "5"}, git=pushed_flow)

    assert answered(capsys, code) == (0, "green\n", "")


def test_no_remote_tracking_ref_for_the_head_branch_leaves_the_grace_counting_from_the_call(
        flow, seed, capsys, pushed_flow):
    seed.checks(7, "required", "none", "green")
    seed.pr(7, "open", "elsewhere", "main")
    seed.pr_head(7, HEAD)

    code = ci(flow, seed, env={"ORCH_CI_GRACE": "5"}, git=pushed_flow)

    assert answered(capsys, code) == (0, "green\n", "")


def test_the_timeout_counts_from_the_call_even_when_the_push_is_old(flow, seed, capsys,
                                                                   pushed_flow):
    seed.checks(7, "required", "pending", "green")

    code = ci(flow, seed, env={"ORCH_CI_TIMEOUT": "5"}, git=pushed_flow)

    assert answered(capsys, code) == (0, "green\n", "")


def test_a_push_younger_than_the_grace_still_waits_it_before_widening(flow, seed, capsys):
    seed.pr_head(7, HEAD)
    git = checkout(flow)
    pushed(git, HEAD, 60)
    seed.checks(7, "required", "none", "green")
    seed.checks(7, "all", "failing")

    assert answered(capsys, ci(flow, seed, env={"ORCH_CI_GRACE": "600"}, git=git)) == (
        0, "green\n", "")


# --- the grace is skipped on no evidence of CI (#476) -----------------------------

NO_SIGNALS = ("none\n%sno CI signals found: no workflow files in the head, no required checks on"
              " main, no checks or statuses on earlier PR commits or the main tip\n" % INDENT)
GRACE_OUT = "none\n%snothing reported before the 0.3s grace ran out\n" % INDENT


def evidence_git(root, head=HEAD, workflows=()):
    """The checkout's git adapter holding commit <head>, pushed 60 seconds
    before NOW, whose tree lists <workflows> under .github/workflows/ - its
    listing unreadable where None."""
    git = FakeGit(GITHUB_ORIGIN, toplevel=str(root), commits={head: {}})
    pushed(git, head, 60)
    git.seed("tree_names", head, ".github/workflows/",
             answer=None if workflows is None else list(workflows))
    return git


@pytest.fixture
def evidence_flow(bare_flow, seed):
    """bare_flow, PR #7's head HEAD."""
    seed.pr_head(7, HEAD)
    return bare_flow


def no_ci(root, seed, capsys, git=None):
    """One review ci call on evidence_flow's PR #7, every CI signal
    absent but what the test seeds, under a 600s grace: (exit, stdout,
    stderr). The required probe answers none then green, so green means
    the grace was waited and none that it was skipped."""
    seed.checks(7, "required", "none", "green")
    seed.checks(7, "all", "none")
    git = evidence_git(root) if git is None else git
    return answered(capsys, ci(root, seed, env={"ORCH_CI_GRACE": "600"}, git=git))


@SESSIONS
def test_with_no_evidence_of_ci_anywhere_none_arrives_without_the_grace(bare_flow, seed, capsys,
                                                                        env):
    seed.pr_head(7, HEAD)
    seed.checks(7, "required", "none", "green")
    seed.checks(7, "all", "none")
    clock = FakeClock()

    code = ci(bare_flow, seed, env=dict(env, ORCH_CI_GRACE="600"), git=evidence_git(bare_flow),
              clock=clock)

    assert answered(capsys, code) == (0, NO_SIGNALS, "")
    assert clock.slept == []


def test_evidence_of_ci_keeps_the_grace_and_none_still_comes_after_it(flow, seed, capsys):
    seed.pr_head(7, HEAD)
    seed.checks(7, "all", "none")
    git = FakeGit(GITHUB_ORIGIN, toplevel=str(flow), commits={HEAD: {}})
    git.seed("tree_names", HEAD, ".github/workflows/", answer=[])

    assert answered(capsys, ci(flow, seed, git=git)) == (0, GRACE_OUT, "")


@pytest.mark.parametrize("answer, out", [("failing", "failing\n%sbuild\n" % INDENT),
                                         ("green", "green\n")], ids=["failing", "green"])
def test_with_no_evidence_of_ci_a_check_reported_on_the_head_still_decides_it(
        bare_flow, seed, capsys, answer, out):
    seed.pr_head(7, HEAD)
    seed.checks(7, "required", "none", "green")
    seed.checks(7, "all", answer)

    code = ci(bare_flow, seed, env={"ORCH_CI_GRACE": "600"}, git=evidence_git(bare_flow))

    assert answered(capsys, code) == (0 if answer == "green" else 1, out, "")


# Each signal present, absent and unreadable. Present or unreadable keeps the
# grace (green); absent skips it (none).
@pytest.mark.parametrize("workflows, kept", [
    ([".github/workflows/ci.yml"], True),
    ([".github/workflows/ci.yaml"], True),
    ([".github/workflows/notes.txt"], False),
    ([".github/workflows/a.yml"] + [".github/workflows/b-%05d.txt" % i for i in range(10000)],
     True),
    (None, True),
], ids=["yml", "yaml", "not-a-workflow", "first-of-many", "unreadable"])
def test_a_workflow_file_in_the_head_s_tree_keeps_the_grace(evidence_flow, seed, capsys,
                                                            workflows,
                                                            kept):
    git = evidence_git(evidence_flow, workflows=workflows)

    assert no_ci(evidence_flow, seed, capsys, git=git) == (
        0, "green\n" if kept else NO_SIGNALS, "")


def test_a_head_this_clone_does_not_hold_keeps_the_grace(evidence_flow, seed, capsys):
    git = FakeGit(GITHUB_ORIGIN, toplevel=str(evidence_flow))
    pushed(git, HEAD, 60)

    assert no_ci(evidence_flow, seed, capsys, git=git) == (0, "green\n", "")


@pytest.mark.parametrize("signal, kept", [
    (lambda seed: seed.required_checks("main", "build"), True),
    (lambda seed: seed.rules("main", "required_status_checks"), True),
    (lambda seed: seed.rules("main", "deletion"), False),
    (lambda seed: seed.rules("main", "required_status_checks",
                             *("filler_rule_type_%05d" % i for i in range(10000))), True),
    (lambda seed: seed.fail("adapter_branch_required_checks", "gh: Not Found (HTTP 404)"), True),
    (lambda seed: seed.fail("adapter_branch_rules"), True),
], ids=["classic", "ruleset", "ruleset-without-checks", "ruleset-among-many",
        "protection-unreadable", "rules-unreadable"])
def test_required_checks_on_the_base_keep_the_grace(evidence_flow, seed, capsys, signal, kept):
    signal(seed)

    assert no_ci(evidence_flow, seed, capsys) == (0, "green\n" if kept else NO_SIGNALS, "")


@pytest.mark.parametrize("signal, kept", [
    (lambda seed: seed.check_run(EARLIER), True),
    (lambda seed: seed.status(EARLIER), True),
    (lambda seed: seed.evidence_raw(7, "no", EARLIER + "\tmaybe", HEAD + "\tno"), True),
    (lambda seed: seed.evidence_raw(7, "no", "not-a-sha\tno", HEAD + "\tno"), True),
    (lambda seed: seed.fail("adapter_pr_commits_checked", "gh: Server Error (HTTP 502)"), True),
    (lambda seed: None, False),
], ids=["check-run", "status", "not-yes-or-no", "not-a-sha", "unreadable", "absent"])
def test_a_check_on_an_earlier_pr_commit_keeps_the_grace(evidence_flow, seed, capsys, signal,
                                                        kept):
    seed.pr_head(7, HEAD, EARLIER, "5" * 40, HEAD)
    signal(seed)

    assert no_ci(evidence_flow, seed, capsys) == (0, "green\n" if kept else NO_SIGNALS, "")


def test_several_earlier_commits_and_no_evidence_give_none_from_one_evidence_read(
        evidence_flow, seed, capsys):
    seed.pr_head(7, HEAD, EARLIER, "5" * 40, "6" * 40, HEAD)

    assert no_ci(evidence_flow, seed, capsys) == (0, NO_SIGNALS, "")
    assert seed.evidence_reads(7) == 1


@pytest.mark.parametrize("signal, kept", [
    (lambda seed: seed.check_run("main"), True),
    (lambda seed: seed.status("main"), True),
    (lambda seed: seed.no_base_ref(7), True),
    (lambda seed: (seed.check_run(HEAD), seed.status(HEAD)), False),
], ids=["check-run", "status", "unreadable", "head-only"])
def test_a_check_on_the_base_tip_keeps_the_grace(evidence_flow, seed, capsys, signal, kept):
    signal(seed)

    assert no_ci(evidence_flow, seed, capsys) == (0, "green\n" if kept else NO_SIGNALS, "")


@pytest.mark.parametrize("lines, kept", [
    ((HEAD + "\tno", NEWER + "\tyes"), True),
    ((HEAD + "\tyes", NEWER + "\tno"), False),
], ids=["newer-checked", "refs-head-checked"])
def test_a_commit_newer_than_the_refs_head_is_judged_as_an_earlier_one(evidence_flow, seed,
                                                                      capsys,
                                                                      lines, kept):
    seed.evidence_raw(7, "no", *lines)

    assert no_ci(evidence_flow, seed, capsys) == (0, "green\n" if kept else NO_SIGNALS, "")


def test_a_pr_that_will_not_say_what_its_head_is_keeps_the_grace(evidence_flow, seed, capsys):
    seed.fail("adapter_pr_refs")

    assert no_ci(evidence_flow, seed, capsys) == (0, "green\n", "")


# --- the stored total across calls ----------------------------------------------

SPEND = {"ORCH_CI_GRACE": "0", "ORCH_CI_TIMEOUT": "2", "ORCH_WAIT_BLOCK": "0.5"}


@SESSIONS
def test_a_wait_not_over_within_its_block_exits_75_storing_its_total(flow, seed, capsys, env):
    seed.checks(7, "all", "pending")
    seed.pr_head(7, HEAD)

    code = ci(flow, seed, env=dict(env, **SPEND))

    assert answered(capsys, code) == (75, "", still("0.5"))
    total = wait_dir(flow) / key_of("review ci 7 " + HEAD)
    assert waits(flow) == [total.name]
    assert total.read_text() == "%d\n0.500\n" % NOW


def test_the_calls_go_on_to_the_total_s_timeout_and_forget_it(flow, seed, capsys):
    seed.checks(7, "all", "pending")
    seed.pr_head(7, HEAD)
    clock = FakeClock()
    codes = []
    while not codes or codes[-1] == 75 and len(codes) < 30:
        codes.append(ci(flow, seed, env=SPEND, clock=clock))
        out, err = capsys.readouterr()

    assert (codes[-1], out, err) == (
        1, "unreachable\n%schecks were still pending after 2s\n" % INDENT, "")
    assert codes[:-1] == [75] * 4
    assert waits(flow) == []


def test_a_delivered_wait_is_forgotten_so_the_next_starts_its_own_total(flow, seed, capsys):
    seed.pr_head(7, HEAD)
    clock = FakeClock()
    seed.checks(7, "all", "pending")
    ci(flow, seed, env=SPEND, clock=clock)
    seed.checks(7, "all", "green")
    assert ci(flow, seed, env=SPEND, clock=clock) == 0
    seed.checks(7, "all", "pending")
    capsys.readouterr()

    code = ci(flow, seed, env=dict(SPEND, ORCH_CI_TIMEOUT="0.9"), clock=clock)

    assert answered(capsys, code) == (75, "", still("0.5"))


def test_a_new_head_commit_starts_its_own_total_and_the_old_one_keeps_its_own(flow, seed,
                                                                            capsys):
    seed.checks(7, "all", "pending")
    clock = FakeClock()
    seed.pr_head(7, "d" * 40)
    for _ in range(3):
        ci(flow, seed, env=dict(SPEND, ORCH_CI_TIMEOUT="100"), clock=clock)
    seed.pr_head(7, "e" * 40)
    probe = dict(SPEND, ORCH_CI_TIMEOUT="1")

    assert ci(flow, seed, env=probe, clock=clock) == 75
    seed.pr_head(7, "d" * 40)
    assert ci(flow, seed, env=probe, clock=clock) == 1


def test_a_head_that_cannot_be_read_keys_the_total_by_the_pr_alone(flow, seed, capsys):
    seed.checks(7, "all", "pending")
    seed.fail("adapter_pr_refs")
    clock = FakeClock()

    codes = [ci(flow, seed, env=SPEND, clock=clock) for _ in range(5)]

    assert codes == [75, 75, 75, 75, 1]
    assert capsys.readouterr().out.endswith("checks were still pending after 2s\n")


# --- the provisional guard and rate limits in the wait ----------------------------

SECONDARY = "You have exceeded a secondary rate limit."
LIMIT_LINE = ("orch: GitHub API rate limit reached - it resets at 2027-01-15T08:15:00Z. An"
              " autopilot session ends its turn now and does not retry; the watcher picks the"
              " work up after the reset.")


@SESSIONS
def test_a_limit_met_reading_the_refs_ends_the_call_as_still_running_storing_no_total(
        flow, seed, capsys, env):
    seed.ratelimit(SECONDARY)
    clock = FakeClock()

    code = ci(flow, seed, env=dict(env, ORCH_GH_LIMIT_WAIT="30", ORCH_CI_GRACE="0",
                                   ORCH_CI_TIMEOUT="100", ORCH_WAIT_BLOCK="5"), clock=clock)

    assert answered(capsys, code) == (75, "", still("5"))
    assert (clock.slept, waits(flow)) == ([5.0], [])


def test_a_limit_the_block_cannot_hold_leaves_the_total_stored_and_exits_75_quietly(
        flow, seed, capsys):
    seed.fail("adapter_pr_checks", SECONDARY)
    clock = FakeClock()

    code = ci(flow, seed, env={"ORCH_GH_LIMIT_WAIT": "30", "ORCH_CI_GRACE": "0",
                               "ORCH_WAIT_BLOCK": "5"}, clock=clock)

    assert answered(capsys, code) == (75, "", still("5"))
    zeros = "0" * 40
    assert clock.slept == [5.0]
    assert waits(flow) == [key_of("review ci 7 " + zeros)]


def test_a_secondary_limit_the_block_can_hold_is_slept_and_retried(flow, seed, capsys):
    seed.fail_times("adapter_pr_checks", 1, SECONDARY + "\n")
    seed.checks(7, "all", "green")
    clock = FakeClock()

    code = ci(flow, seed, env={"ORCH_GH_LIMIT_WAIT": "30", "ORCH_CI_GRACE": "0"}, clock=clock)

    assert answered(capsys, code) == (0, "green\n", "")
    assert clock.slept == [30.0]


def test_a_primary_limit_prints_the_one_limit_line_as_unreachable(flow, seed, capsys):
    seed.ratelimit()

    code = ci(flow, seed, "7", env={"ORCH_CI_GRACE": "0"})

    assert answered(capsys, code) == (
        1, "unreachable\n      could not read PR #7: %s\n" % LIMIT_LINE, "")


# --- failed wait writes -----------------------------------------------------------


class SurrogateHead(FakeGh):
    """The gh fake, PR #7's head SHA a text no byte string spells."""

    def pr_refs(self, n):
        return "\ud800", "topic", "main"


def test_a_wait_that_cannot_be_keyed_dies_printing_no_verdict(flow, seed, capsys):
    env = dict(CLAUDE, **KNOBS)
    seed.checks(7, "all", "green")
    gh = SurrogateHead(seed.store, env, sleep=lambda _: None)

    assert answered(capsys, ci(flow, seed, gh=gh)) == (1, "", "orch: could not key the wait\n")
    assert waits(flow) == []


def test_a_wait_folder_that_cannot_be_made_dies_printing_no_verdict(flow, seed, capsys):
    wait_dir(flow).write_text("a file\n")
    seed.checks(7, "all", "green")

    assert answered(capsys, ci(flow, seed)) == (
        1, "", "orch: could not create %s/.orchestrator/wait\n" % flow)


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_total_that_cannot_be_stored_dies_printing_no_verdict_and_leaving_no_total(
        flow, seed, capsys):
    wait_dir(flow).mkdir()
    wait_dir(flow).chmod(0o555)
    seed.checks(7, "all", "green")
    try:
        code = ci(flow, seed)
    finally:
        wait_dir(flow).chmod(0o755)

    assert answered(capsys, code) == (1, "", "orch: could not store the wait\n")
    assert waits(flow) == []


# --- refusals ---------------------------------------------------------------------


NO_FLOW = ("orch: no active flow (.orchestrator/state.json not found). Run /orchestrator:start"
           " first.\n")


@pytest.mark.parametrize("knobs, message", [
    ({"ORCH_CI_GRACE": "oops"}, "ORCH_CI_GRACE is not a number: oops"),
    ({"ORCH_CI_TIMEOUT": "oops"}, "ORCH_CI_TIMEOUT is not a number: oops"),
    ({"ORCH_CI_INTERVAL": "0"}, "ORCH_CI_INTERVAL must be greater than zero: 0"),
    ({"ORCH_WAIT_BLOCK": "0"}, "ORCH_WAIT_BLOCK must be greater than zero: 0"),
], ids=["grace", "timeout", "interval", "block"])
def test_a_knob_the_wait_cannot_read_is_refused_at_exit_2(flow, seed, capsys, knobs, message):
    seed.checks(7, "all", "green")

    assert answered(capsys, ci(flow, seed, env=knobs)) == (2, "", "orch: %s\n" % message)
    assert waits(flow) == []


def test_a_grace_that_is_no_number_is_refused_under_no_wait(flow, seed, capsys):
    assert answered(capsys, ci(flow, seed, "--no-wait", "7", env={"ORCH_CI_GRACE": "oops"})) == (
        2, "", "orch: ORCH_CI_GRACE is not a number: oops\n")


@pytest.mark.parametrize("argv, message", [
    (("7x",), "not a PR number: 7x"), (("",), "not a PR number: "),
    (("7", "8"), "usage: orch.sh review ci [--no-wait] [<pr>]"),
], ids=["not-a-number", "empty", "extra"])
def test_a_pr_argument_that_is_no_number_is_refused_at_exit_2(root, seed, capsys, argv, message):
    assert answered(capsys, ci(root, seed, *argv)) == (2, "", "orch: %s\n" % message)


@pytest.mark.parametrize("pr", ["", None], ids=["missing", "null"])
def test_a_flow_state_with_no_pr_is_refused_at_exit_2(root, seed, capsys, pr):
    hold_flow(root, slug="x", phase="review", issue=3, **({} if pr == "" else {"pr": pr}))

    assert answered(capsys, ci(root, seed)) == (
        2, "", "orch: no PR recorded in state - the implement phase opens it\n")


def test_a_recorded_pr_that_is_no_number_goes_to_gh_as_it_is_and_ends_unreachable(root, seed,
                                                                                capsys):
    hold_flow(root, slug="x", phase="review", issue=3, pr="seven")
    seed.fail("adapter_pr_checks", 'no pull requests found for branch "seven"')

    assert answered(capsys, ci(root, seed)) == (
        1, 'unreachable\n%sno pull requests found for branch "seven"\n' % INDENT, "")


def test_no_flow_state_is_refused_at_exit_2(root, seed, capsys):
    assert answered(capsys, ci(root, seed)) == (2, "", NO_FLOW)


def test_no_repo_to_pin_is_refused_at_exit_2(flow, seed, capsys):
    git = FakeGit(toplevel=str(flow))

    assert answered(capsys, ci(flow, seed, git=git)) == (2, "", "orch: %s\n" % REPO_REMEDY)


# --- review ci <pr> ------------------------------------------------------------------


@pytest.fixture
def by_pr(root, seed):
    """No flow state; PR #7 open from topic onto main with head HEAD, the
    base tip's check run as evidence of CI."""
    seed.check_run("main")
    seed.pr(7, "open", "topic", "main")
    seed.pr_head(7, HEAD)
    return root


BY_PR = {"ORCH_CI_GRACE": "0", "ORCH_CI_TIMEOUT": "1.5", "ORCH_WAIT_BLOCK": "0.4"}


@SESSIONS
def test_a_pr_number_reads_its_pr_with_no_flow_state(by_pr, seed, capsys, env):
    seed.checks(7, "all", "green")

    assert answered(capsys, ci(by_pr, seed, "7", env=dict(env, **BY_PR))) == (0, "green\n", "")


@pytest.mark.parametrize("argv", [("7", "--no-wait"), ("--no-wait", "7")], ids=["after", "before"])
def test_no_wait_combines_with_a_pr_number_in_either_order(by_pr, seed, capsys, argv):
    seed.checks(7, "all", "pending")

    assert answered(capsys, ci(by_pr, seed, *argv, env=BY_PR)) == (0, "pending\n", "")


def test_a_waiting_call_by_pr_number_stores_its_total_under_the_flow_form_s_key(by_pr, seed,
                                                                               capsys):
    seed.checks(7, "all", "pending")

    code = ci(by_pr, seed, "7", env=dict(BY_PR, ORCH_CI_INTERVAL="1"))

    assert answered(capsys, code) == (75, "", still("0.4"))
    assert waits(by_pr) == [key_of("review ci 7 " + HEAD)]
    before = snapshot(wait_dir(by_pr))
    ci(by_pr, seed, "7", "--no-wait", env=BY_PR)
    assert snapshot(wait_dir(by_pr)) == before


@SESSIONS
@pytest.mark.parametrize("argv", [("99", "--no-wait"), ("99",)], ids=["no-wait", "waiting"])
def test_a_pr_given_by_number_that_cannot_be_read_is_unreachable(by_pr, seed, capsys, env, argv):
    code = ci(by_pr, seed, *argv, env=dict(env, **BY_PR))

    assert answered(capsys, code) == (
        1, "unreachable\n%scould not read PR #99: GraphQL: Could not resolve to a PullRequest"
           " with the number of 99. (repository.pullRequest)\n" % INDENT, "")
    assert waits(by_pr) == []


# --- review ci --no-wait ------------------------------------------------------------


NO_WAIT = {"ORCH_CI_GRACE": "0", "ORCH_CI_TIMEOUT": "100"}


@SESSIONS
@pytest.mark.parametrize("answer, code, out", [
    ("green", 0, "green\n"),
    ("failing", 1, "failing\n%sbuild\n" % INDENT),
    ("none", 0, "none\n%snothing reported before the 0s grace ran out\n" % INDENT),
    ("pending", 0, "pending\n"),
], ids=["green", "failing", "none", "pending"])
def test_no_wait_makes_one_pass_writing_nothing(flow, seed, capsys, env, answer, code, out):
    seed.checks(7, "all", answer)
    before = snapshot(flow / ".orchestrator")
    clock = FakeClock()

    assert answered(capsys, ci(flow, seed, "--no-wait", env=dict(env, **NO_WAIT),
                               clock=clock)) == (code, out, "")
    assert (snapshot(flow / ".orchestrator"), clock.slept) == (before, [])
    assert not wait_dir(flow).exists()


def test_no_wait_prints_pending_inside_the_grace_without_waiting_it(flow, seed, capsys):
    seed.checks(7, "required", "none", "green")
    seed.checks(7, "all", "failing")
    clock = FakeClock()

    code = ci(flow, seed, "--no-wait", env={"ORCH_CI_GRACE": "600"}, clock=clock)

    assert (answered(capsys, code), clock.slept) == ((0, "pending\n", ""), [])


def test_no_wait_reads_no_total_an_earlier_waiting_call_spent(flow, seed, capsys):
    seed.pr_head(7, "b" * 40)
    seed.checks(7, "all", "pending")
    clock = FakeClock()
    ci(flow, seed, env={"ORCH_CI_GRACE": "0", "ORCH_CI_TIMEOUT": "100", "ORCH_WAIT_BLOCK": "0.3"},
       clock=clock)
    capsys.readouterr()
    before = snapshot(wait_dir(flow))

    code = ci(flow, seed, "--no-wait", env={"ORCH_CI_GRACE": "0", "ORCH_CI_TIMEOUT": "0.1"},
              clock=clock)

    assert answered(capsys, code) == (0, "pending\n", "")
    assert snapshot(wait_dir(flow)) == before


def test_no_wait_gives_a_secondary_limit_up_at_once_writing_nothing(flow, seed, capsys,
                                                                    tmp_path):
    seed.checks(7, "all", "pending")
    seed.ratelimit(SECONDARY)
    before = snapshot(flow / ".orchestrator")
    clock = FakeClock()
    git = checkout(flow)
    git.seed("main_checkout", answer=str(flow))

    code = ci(flow, seed, "--no-wait", env={"ORCH_GH_LIMIT_WAIT": "30"}, clock=clock, git=git)

    assert answered(capsys, code) == (1, "unreachable\n%s%s\n" % (INDENT, LIMIT_LINE), "")
    assert (clock.slept, snapshot(flow / ".orchestrator")) == ([], before)
    assert not (flow / ".orchestrator" / "autopilot").exists()


# --- rate limits in an autopilot process --------------------------------------------


@pytest.fixture
def main(tmp_path):
    """The main checkout's root, tmp_path/main."""
    path = tmp_path / "main"
    path.mkdir()
    return path


def pause_of(main):
    return main / ".orchestrator" / "autopilot" / "github-limit"


def autopilot_git(root, main):
    git = checkout(root)
    git.seed("main_checkout", answer=str(main))
    return git


@pytest.mark.parametrize("argv, limit", [(("--no-wait",), SECONDARY), ((), None)],
                         ids=["no-wait-secondary", "waiting-primary"])
def test_an_autopilot_session_records_the_pause_and_the_hit_file(flow, seed, capsys, main,
                                                                 tmp_path, argv, limit):
    seed.checks(7, "all", "pending")
    seed.ratelimit(*(() if limit is None else (limit,)))
    hit = tmp_path / "hit"
    env = dict(AUTOPILOT, ORCH_AUTOPILOT_HIT_FILE=str(hit), ORCH_GH_LIMIT_WAIT="30")

    code = ci(flow, seed, *argv, env=env, git=autopilot_git(flow, main))

    assert answered(capsys, code) == (1, "unreachable\n%s%s\n" % (INDENT, LIMIT_LINE), "")
    assert (pause_of(main).read_text(), hit.read_text()) == ("2027-01-15T08:15:00Z\n",) * 2


@pytest.mark.parametrize("argv, limit", [(("7", "--no-wait"), SECONDARY), (("7",), None)],
                         ids=["no-wait-secondary", "waiting-primary"])
def test_a_pause_that_cannot_be_written_is_joined_onto_the_limit_line(by_pr, seed, capsys, main,
                                                                      argv, limit):
    seed.ratelimit(*(() if limit is None else (limit,)))
    pause_of(main).mkdir(parents=True)
    env = dict(AUTOPILOT, ORCH_GH_LIMIT_WAIT="30")

    code = ci(by_pr, seed, *argv, env=env, git=autopilot_git(by_pr, main))

    assert answered(capsys, code) == (
        1, "unreachable\n%scould not read PR #7: %s - could not write the GitHub limit pause"
           " under %s\n" % (INDENT, LIMIT_LINE, main), "")
