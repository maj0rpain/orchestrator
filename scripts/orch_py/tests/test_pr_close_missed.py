"""The merged-PR backstop (#2477, #2478) of the pr noun: the newest-merge
pick (#3074) and pr_close_missed's four statuses, then its two callers -
close_missed_rows, which autopilot's tick calls in process, and the
close_missed_finish bridge side-checkout's sweep calls, as orch_python_call
hands it its arguments - on the gh fake's store, the cases of the bash
`pr: PR-line pick and newest merge` section among them."""
from __future__ import annotations

import pytest

from conftest import GH_502, GITHUB_ORIGIN, comments_of, died_of, fake, read
from orch import pr
from orch.gh import GhFailed
from orch.gh_fake import FakeGh
from orch.git import FakeGit

TAB = "\t"


def line(*fields):
    """A merged-PR line as the backstop's read gives it, fields tab-joined."""
    return TAB.join(fields)


# --- the newest-merge pick (#3074) ----------------------------------------------------


def test_the_newest_merge_is_the_line_with_the_latest_timestamp():
    lines = [line("1", "h", "2025-01-01T00:00:00Z", "a"),
             line("2", "h", "2025-03-01T00:00:00Z", "b"),
             line("3", "h", "2025-02-01T00:00:00Z", "c")]

    assert pr.newest_merge(lines) == ("2", "2025-03-01T00:00:00Z", "b")


def test_of_equal_merge_timestamps_the_earlier_line_is_the_newest():
    lines = [line("4", "h", "2025-03-01T00:00:00Z", "a"),
             line("2", "h", "2025-03-01T00:00:00Z", "b")]

    assert pr.newest_merge(lines) == ("4", "2025-03-01T00:00:00Z", "a")


def test_a_blank_line_and_a_line_with_no_timestamp_are_never_the_newest():
    assert pr.newest_merge(["", line("5", "h"), line("6", "h", "", "x"), ""]) is None


# --- pr_close_missed's four statuses --------------------------------------------------

# The clock the backstop ages a merge against: 2026-06-01T12:00:00Z.
NOW = 1780315200
HOUR_AGO = "2026-06-01T11:00:00Z"
MINUTE_AGO = "2026-06-01T11:59:00Z"
CLOSE_COMMENT = ("Closed by the orchestrator: PR #%d merged into `main` with `Closes #%d`, but"
                 " GitHub did not close this issue.")


def close_missed(seed, issue, merged_at, closing):
    """pr_close_missed on issue <issue> and its PR #(100+issue) merged into
    main at <merged_at>, its closing issues <closing>, at NOW: its status."""
    return pr.pr_close_missed(fake(seed), str(issue), str(100 + issue), merged_at, closing,
                              "main", NOW)


def test_an_issue_its_pr_should_have_closed_is_closed_as_completed_with_a_comment(seed, capsys):
    seed.issue(50, "open", "orch:done")

    assert close_missed(seed, 50, HOUR_AGO, "12,50") == 0

    assert capsys.readouterr() == ("", "")
    assert (read(seed.store, "issues", 50, "state"), read(seed.store, "issues", 50, "reason")) \
        == ("CLOSED\n", "completed\n")
    assert comments_of(seed.store, 50) == [CLOSE_COMMENT % (150, 50)]
    assert read(seed.store, "issues", 50, "labels") == "orch:done\n"


@pytest.mark.parametrize("closing", ["", "5", "500,150", "5,0"],
                         ids=["none", "other", "longer", "part"])
def test_a_closing_list_not_naming_the_issue_is_a_silent_skip(seed, capsys, closing):
    seed.issue(50, "open")

    assert close_missed(seed, 50, HOUR_AGO, closing) == 1

    assert capsys.readouterr() == ("", "")
    assert read(seed.store, "issues", 50, "state") == "OPEN\n"


def test_a_merge_timestamp_that_does_not_read_is_a_silent_skip(seed, capsys):
    seed.issue(50, "open")

    assert close_missed(seed, 50, "yesterday", "50") == 1

    assert capsys.readouterr() == ("", "")
    assert read(seed.store, "issues", 50, "state") == "OPEN\n"


def test_a_merge_inside_the_grace_period_leaves_the_issue_open_for_the_caller_to_warn(seed, capsys):
    seed.issue(50, "open")

    assert close_missed(seed, 50, MINUTE_AGO, "50") == 3
    # A second short of five minutes is still inside it.
    assert close_missed(seed, 50, "2026-06-01T11:55:01Z", "50") == 3

    assert capsys.readouterr() == ("", "")
    assert read(seed.store, "issues", 50, "state") == "OPEN\n"
    # Five minutes to the second is past it.
    assert close_missed(seed, 50, "2026-06-01T11:55:00Z", "50") == 0


def test_a_failed_close_warns_naming_the_issue_and_the_pr(seed, capsys):
    seed.issue(50, "open")
    seed.fail("adapter_issue_close", GH_502)

    assert close_missed(seed, 50, HOUR_AGO, "50") == 2

    assert capsys.readouterr() == (
        "", "orch: could not close issue #50 after PR #150 merged: HTTP 502: Bad Gateway\n")
    assert read(seed.store, "issues", 50, "state") == "OPEN\n"


# --- the tick's close, close_missed_rows (#2478) ----------------------------------------


@pytest.fixture
def github(seed):
    """The repo's default branch main."""
    seed.default_branch("main\n")
    return seed


def checkout():
    """A checkout with origin on acme/widgets, main a valid branch name."""
    git = FakeGit(remotes=GITHUB_ORIGIN)
    git.seed("is_branch_name", "main", answer=True)
    return git


def merged(seed, issue, merged_at, *closing, n=None, head=None, base="main"):
    """Open orch:done issue <issue> and its PR #<n> (100+issue when None)
    from <head> (orch/<issue>-widget when None) merged into <base> at
    <merged_at>, closing <closing> (<issue> alone when none is given)."""
    n = 100 + issue if n is None else n
    seed.issue(issue, "open", "orch:done")
    seed.pr(n, "merged", "orch/%d-widget" % issue if head is None else head, base)
    seed.pr_merged(n, merged_at, *(closing or (issue,)))


def tick(seed, table, gh=None):
    """close_missed_rows on the done <table>, its `<issue> <running> <sync>
    <human>` lines, as autopilot's tick calls it, against <gh> (the gh fake
    on <seed>'s store when None), at NOW: the rows it kept, as lines of the
    same shape."""
    rows = [text.split() for text in table.splitlines()]
    kept = pr.close_missed_rows(rows, gh=fake(seed) if gh is None else gh,
                                git=checkout(), env={}, now=lambda: NOW)
    return "".join(" ".join(row) + "\n" for row in kept)


def state_of(seed, n):
    return read(seed.store, "issues", n, "state")


def test_a_tick_keeps_the_done_table_less_exactly_the_issues_it_closed(github, capsys):
    merged(github, 50, HOUR_AGO)
    merged(github, 51, MINUTE_AGO)
    merged(github, 52, HOUR_AGO)
    merged(github, 53, HOUR_AGO)
    merged(github, 54, HOUR_AGO, 99)
    merged(github, 55, HOUR_AGO, base="release")
    merged(github, 56, HOUR_AGO, head="orch/560-other")
    merged(github, 57, HOUR_AGO, n=157, head="orch/57-a")
    merged(github, 57, MINUTE_AGO, n=257, head="orch/57-b")
    table = ("50 0 0 0\n51 0 0 0\n52 1 0 0\n53 0 1 1\n54 0 0 0\n55 0 0 0\n56 0 0 0\n"
             "57 0 0 0\n")

    kept = tick(github, table)

    assert (kept, capsys.readouterr().err) == (
        "51 0 0 0\n52 1 0 0\n54 0 0 0\n55 0 0 0\n56 0 0 0\n57 0 0 0\n", "")
    assert comments_of(github.store, 50) == [CLOSE_COMMENT % (150, 50)]
    # orch:sync and needs-human do not stop the close.
    assert state_of(github, 53) == "CLOSED\n"
    for n in (51, 52, 54, 55, 56, 57):
        assert state_of(github, n) == "OPEN\n"


def test_a_fork_pr_is_not_the_issues_pr(github, capsys):
    merged(github, 50, HOUR_AGO)
    github.pr_cross(150)

    kept = tick(github, "50 0 0 0\n")

    assert (kept, capsys.readouterr().err) == (
        "50 0 0 0\n", "orch: ignored 1 PR(s) from forks for the merged PRs\n")
    assert state_of(github, 50) == "OPEN\n"


def test_a_tick_whose_every_issue_is_running_reads_nothing(github, capsys):
    merged(github, 50, HOUR_AGO)
    github.fail("adapter_issue_created_at", GH_502)
    github.fail("adapter_prs_merged_closing", GH_502)

    kept = tick(github, "50 1 0 0\n51 1 1 0\n")

    assert (kept, capsys.readouterr().err) == ("50 1 0 0\n51 1 1 0\n", "")


def test_the_one_read_is_bounded_by_the_first_issue_not_running(github, capsys):
    # #85 is running and the oldest; #86's creation bounds the read, so #87's
    # PR, merged after #85 was created but before #86 was, is never read,
    # while #86's, merged before #87 was created, is.
    merged(github, 85, HOUR_AGO)
    github.issue_created(85, "2026-05-29T12:00:00Z")
    merged(github, 86, "2026-05-31T00:00:00Z")
    github.issue_created(86, "2026-05-30T12:00:00Z")
    merged(github, 87, "2026-05-30T00:00:00Z")
    github.issue_created(87, "2026-05-31T12:00:00Z")

    kept = tick(github, "85 1 0 0\n86 0 0 0\n87 0 0 0\n")

    assert (kept, capsys.readouterr().err) == ("85 1 0 0\n87 0 0 0\n", "")
    assert (state_of(github, 86), state_of(github, 87)) == ("CLOSED\n", "OPEN\n")


@pytest.mark.parametrize("failing,warning", [
    ("adapter_issue_created_at", "could not read the creation time of issue #50: HTTP 502: Bad"
                                 " Gateway"),
    ("adapter_prs_merged_closing", "could not read the merged PRs: HTTP 502: Bad Gateway"),
], ids=["created", "merged"])
def test_a_failed_read_keeps_the_whole_table_with_its_warning(github, capsys, failing, warning):
    merged(github, 50, HOUR_AGO)
    github.fail(failing, GH_502)

    kept = tick(github, "50 0 0 0\n51 1 0 0\n")

    assert (kept, capsys.readouterr().err) == (
        "50 0 0 0\n51 1 0 0\n", "orch: %s - no merged-PR close this tick\n" % warning)
    assert state_of(github, 50) == "OPEN\n"


def test_a_malformed_merged_pr_line_keeps_the_whole_table_with_its_warning(github, capsys):
    merged(github, 50, HOUR_AGO)
    github.pr_cross(150, "maybe")

    kept = tick(github, "50 0 0 0\n")

    assert (kept, capsys.readouterr().err) == (
        "50 0 0 0\n", "orch: the merged PRs could not be read: a malformed line - no merged-PR"
                       " close this tick\n")


class CloseFailing(FakeGh):
    """The gh fake, whose close of issue <n> alone fails with GH_502."""

    def __init__(self, seed, n):
        super().__init__(seed.store, {}, sleep=lambda _: None)
        self.failing = n

    def issue_close(self, n, *args, **kwargs):
        if n == self.failing:
            raise GhFailed(GH_502)
        return super().issue_close(n, *args, **kwargs)


def test_a_failed_close_keeps_its_issue_while_the_others_close(github, capsys):
    for n in (50, 51, 52):
        merged(github, n, HOUR_AGO)

    kept = tick(github, "50 0 0 0\n51 0 0 0\n52 0 0 0\n", gh=CloseFailing(github, 51))

    assert (kept, capsys.readouterr().err) == (
        "51 0 0 0\n", "orch: could not close issue #51 after PR #151 merged: HTTP 502: Bad Gateway\n")
    assert [state_of(github, n) for n in (50, 51, 52)] == ["CLOSED\n", "OPEN\n", "CLOSED\n"]


# --- the close_missed_finish bridge (#2477) -------------------------------------------

FINISH_USAGE = "orch: usage: orch_python_call pr close_missed_finish <issue> <pr> <branch>\n"
GRACE_WARNING = ("orch: issue #%d is still open: PR #%d merged less than 5 minutes ago - GitHub"
                 " may yet close it, and no later sweep will check\n")


def finish(seed, *args, gh=None):
    """close_missed_finish <args> as orch_python_call hands them on, against
    <gh> (the gh fake on <seed>'s store when None), at NOW: its exit
    code."""
    result = pr.close_missed_finish(list(args), gh=fake(seed) if gh is None else gh,
                                    git=checkout(), env={}, now=lambda: NOW)
    return 0 if result is None else result


def test_a_finished_flow_closes_its_issue_through_its_recorded_pr(github, capsys):
    merged(github, 601, HOUR_AGO, n=701, head="orch/601-ff")
    # A newer merge from the flow's branch is not the recorded PR.
    merged(github, 601, MINUTE_AGO, n=801, head="orch/601-ff")

    assert finish(github, "601", "701", "orch/601-ff") == 0

    assert capsys.readouterr() == ("", "")
    assert comments_of(github.store, 601) == [CLOSE_COMMENT % (701, 601)]


def test_a_flow_less_checkout_closes_its_issue_through_the_newest_merge_from_its_branch(
        github, capsys):
    merged(github, 602, "2026-06-01T10:00:00Z", n=702, head="quick/602-fq")
    merged(github, 602, HOUR_AGO, n=802, head="quick/602-fq")
    # Newer still, but from another branch.
    merged(github, 602, "2026-06-01T11:30:00Z", n=902, head="quick/602-other")

    assert finish(github, "602", "", "quick/602-fq") == 0

    assert capsys.readouterr() == ("", "")
    assert comments_of(github.store, 602) == [CLOSE_COMMENT % (802, 602)]


def test_a_merge_inside_the_grace_period_warns_and_leaves_the_issue_open(github, capsys):
    merged(github, 603, MINUTE_AGO, n=703, head="quick/603-fg")

    assert finish(github, "603", "", "quick/603-fg") == 0

    assert capsys.readouterr() == ("", GRACE_WARNING % (603, 703))
    assert state_of(github, 603) == "OPEN\n"


def test_a_closing_list_not_naming_the_issue_closes_nothing_silently(github, capsys):
    merged(github, 609, HOUR_AGO, 99, n=709, head="quick/609-fn")

    assert finish(github, "609", "", "quick/609-fn") == 0

    assert capsys.readouterr() == ("", "")
    assert state_of(github, 609) == "OPEN\n"


def test_a_failed_close_warns_and_still_exits_0(github, capsys):
    merged(github, 607, HOUR_AGO, n=707, head="quick/607-fc")
    github.fail("adapter_issue_close", GH_502)

    assert finish(github, "607", "707", "quick/607-fc") == 0

    assert capsys.readouterr() == (
        "", "orch: could not close issue #607 after PR #707 merged: HTTP 502: Bad Gateway\n")


@pytest.mark.parametrize("failing,warning", [
    ("adapter_issue_created_at", "could not read the creation time of issue #612: HTTP 502: Bad"
                                 " Gateway"),
    ("adapter_prs_merged_closing", "could not read the merged PRs: HTTP 502: Bad Gateway"),
], ids=["created", "merged"])
def test_a_failed_read_warns_closes_nothing_and_exits_0(github, capsys, failing, warning):
    merged(github, 612, HOUR_AGO, n=712, head="quick/612-fk")
    github.fail(failing, GH_502)

    assert finish(github, "612", "", "quick/612-fk") == 0

    assert capsys.readouterr() == (
        "", "orch: %s - no merged-PR close for issue #612\n" % warning)
    assert state_of(github, 612) == "OPEN\n"


@pytest.mark.parametrize("args", [(), ("612", ""), ("612", "", "quick/612-a", "x"),
                                  ("x", "", "quick/612-a"), ("612", "7x", "orch/612-a")],
                         ids=["none", "two", "four", "issue", "pr"])
def test_the_finish_bridge_dies_with_its_usage_line_on_bad_arguments(github, capsys, args):
    assert died_of(capsys, lambda: finish(github, *args)) == (1, "", FINISH_USAGE)
