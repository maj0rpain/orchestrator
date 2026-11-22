"""The ticket module's listing reads, body reads and commands, as the bash
ticket module's copies answer them: a breakdown's sub-issue listing read from
the gh fake's store, the `## Blocked by` and `## Ticket` reads and rewrites of
a body, code fences and CRLF ends included, and `ticket exists`, `ticket
block`, `ticket unblock` and `ticket retire` against the store, each gh
failure through the store's failure injection under the bash operation
name."""
from __future__ import annotations

import os

import pytest

from conftest import GH_502, blockers_of, comments_of, died_of, fake, read, snapshot
from orch.gh import SubIssue
from orch.repo import REPO_REMEDY
from orch.ticket import (blocked_by_section_numbers, has_ticket_heading,
                         rewrite_blocked_by_section, strip_ticket_sections, ticket_block,
                         ticket_exists, ticket_listing_state, ticket_retire, ticket_sub_issues,
                         ticket_unblock)


# --- the sub-issue listing ----------------------------------------------------------


def test_a_breakdown_s_sub_issues_are_listed_in_link_order(seed):
    for n in (10, 11, 12, 13):
        seed.issue(n, "open")
    seed.issue(12, "closed")
    seed.sub_issue(10, 12)
    seed.sub_issue(10, 11)
    seed.blocked_by(11, 12, 13)

    assert ticket_sub_issues(fake(seed), "10") == [SubIssue(12, "CLOSED", 0),
                                                   SubIssue(11, "OPEN", 1)]


@pytest.mark.parametrize("code", [1, 2])
def test_a_listing_github_cannot_answer_dies_in_the_gh_failure_grammar(seed, capsys, code):
    seed.issue(10, "open")
    seed.fail("adapter_sub_issues", GH_502)

    assert died_of(capsys, lambda: ticket_sub_issues(fake(seed), "10", code=code)) == (
        code, "", "orch: gh could not list sub-issues of #10: HTTP 502: Bad Gateway\n")


@pytest.mark.parametrize("parent", ["", "#10", "1x"])
def test_a_parent_that_is_no_plain_number_is_refused_before_github(seed, capsys, parent):
    seed.offline()

    assert died_of(capsys, lambda: ticket_sub_issues(fake(seed), parent, code=2)) == (
        1, "", "orch: parent must be a plain issue number, got: %s\n" % parent)


def test_a_listing_state_is_its_row_s_state_matched_as_text(seed):
    listing = [SubIssue(20, "OPEN", 0), SubIssue(22, "CLOSED", None)]

    assert [ticket_listing_state(listing, n) for n in ("20", "22", "21", "020")] == [
        "OPEN", "CLOSED", "", ""]


# --- the ## Blocked by section --------------------------------------------------------


@pytest.mark.parametrize("body, numbers", [
    ("## What to build\n\nx\n\n## Blocked by\n\n- #20\n- #7 (the API)\n", ["20", "7"]),
    ("## Blocked by\n\nNone (can start immediately)\n", []),
    ("## What to build\n\n- #20\n", []),
    # A `###` heading does not end the section; a `##` one does.
    ("## Blocked by\n\n- #1\n### Why\n- #2\n## Notes\n- #3\n", ["1", "2"]),
    # A heading inside a code fence is text; only the first section counts.
    ("```\n## Blocked by\n- #1\n```\n## Blocked by\n- #2\n## Blocked by\n- #3\n", ["2"]),
    ("## Blocked by\r\n\r\n- #20\r\n- #21\r\n", ["20", "21"]),
    ("## Blocked by\n- #021\n-  #5\n", ["021"]),
])
def test_the_blocked_by_section_lists_its_numbers_as_written(body, numbers):
    assert blocked_by_section_numbers(body) == numbers


# --- the ## Ticket heading ------------------------------------------------------------


@pytest.mark.parametrize("body, has", [
    ("# Spec\n\n## Ticket\n\nBuild it.\n", True),
    ("# Spec\r\n\r\n## Ticket\r\n", True),
    ("# Spec\n\n## Ticket", True),
    ("# Spec\n\n## Tickets\n\n## Ticket x\n", False),
    ("# Spec\n\n~~~\n## Ticket\n~~~\n", False),
    ("", False),
])
def test_the_ticket_heading_is_found_only_whole_and_outside_a_fence(body, has):
    assert has_ticket_heading(body) is has


@pytest.mark.parametrize("body, stripped", [
    # A section at the end goes, with the blank lines before it.
    ("# Spec\n\nBody.\n\n## Ticket\n\nBuild it.\n\n", "# Spec\n\nBody.\n"),
    # A section before the next heading goes; the heading keeps its blank lines.
    ("# Spec\n\n## Ticket\n\nBuild it.\n\n## Notes\nN.\n", "# Spec\n\n## Notes\nN.\n"),
    # A `###` heading is inside the section; a heading in a fence is text.
    ("A\n## Ticket\n### Sub\n```\n## Notes\n```\n# Next\nB\n", "A\n# Next\nB\n"),
    # Every section goes; CRLF lines are kept as they were.
    ("A\r\n## Ticket\r\nx\r\n## Mid\r\n\r\n## Ticket\r\ny\r\n", "A\r\n## Mid\r\n"),
    # No section: the body as awk prints it, trailing blank lines kept.
    ("A\n\nB\n\n\n", "A\n\nB\n\n\n"),
    ("A\nB", "A\nB\n"),
])
def test_strip_ticket_sections_cuts_every_section_keeping_every_other_line(body, stripped):
    assert strip_ticket_sections(body) == stripped


# --- ticket exists ----------------------------------------------------------------------


def test_an_issue_with_sub_issues_has_a_sub_issue_breakdown_whatever_its_body(seed):
    for n in (14, 20):
        seed.issue(n, "open")
    seed.issue(21, "closed")
    seed.sub_issue(14, 21)
    seed.body(14, "The spec.\n\n## Ticket\n\nBuild it.\n")

    assert ticket_exists(fake(seed), "14") == "sub-issues"


@pytest.mark.parametrize("body, kind", [
    ("The spec.\n\n## Ticket\n\nBuild it.\n", "collapsed"),
    ("The spec, no breakdown yet.", None),
    ("The spec.\n\n### Ticket\n", None),
    ("The spec quotes the format:\n```md\n## Ticket\n```\n", None),
])
def test_an_issue_with_no_sub_issues_is_collapsed_only_under_a_ticket_heading(seed, body, kind):
    seed.issue(14, "open")
    seed.body(14, body)

    assert ticket_exists(fake(seed), "14") == kind


@pytest.mark.parametrize("operation, message", [
    ("adapter_sub_issues", "orch: gh could not list sub-issues of #14: HTTP 502: Bad Gateway\n"),
    ("adapter_issue_body", "orch: gh could not read issue #14's body: HTTP 502: Bad Gateway\n"),
])
def test_a_github_ticket_exists_cannot_read_dies_with_2_never_no_breakdown_s_1(
        seed, capsys, operation, message):
    seed.issue(14, "open")
    seed.fail(operation, GH_502)

    assert died_of(capsys, lambda: ticket_exists(fake(seed), "14")) == (2, "", message)


def test_ticket_exists_with_no_repo_to_pin_dies_with_2_naming_the_remedy(seed, capsys):
    class Unpinned:
        def resolve(self):
            return None

    seed.issue(14, "open")
    gh = fake(seed)
    gh.repo_pin = Unpinned()

    assert died_of(capsys, lambda: ticket_exists(gh, "14")) == (2, "", "orch: %s\n" % REPO_REMEDY)


def test_ticket_exists_refuses_a_parent_that_is_no_plain_number_with_2(seed, capsys):
    seed.offline()

    assert died_of(capsys, lambda: ticket_exists(fake(seed), "abc")) == (
        2, "", "orch: parent must be a plain issue number, got: abc\n")


# --- ticket block and ticket unblock --------------------------------------------------

UNBLOCKED = "Build the thing.\n\n## Blocked by\n\nNone (can start immediately)\n"


def breakdown(seed, *tickets, parent=96):
    """Open tickets of <parent>'s breakdown, each with UNBLOCKED's body."""
    seed.issue(parent, "open")
    for n in tickets:
        seed.issue(n, "open")
        seed.body(n, UNBLOCKED)
        seed.sub_issue(parent, n)


def test_block_adds_each_missing_edge_once_and_rewrites_the_blocked_by_section(seed, store):
    breakdown(seed, 801, 802, 803, 804)
    seed.blocked_by(804, 801)

    ticket_block(fake(seed), "804", "803,802,803")

    assert blockers_of(store, 804) == ["801", "802", "803"]
    assert read(store, "issues", 804, "body") == (
        "Build the thing.\n\n## Blocked by\n\n- #801\n- #802\n- #803\n")


def test_block_on_an_edge_already_there_writes_no_edge(seed, store):
    breakdown(seed, 801, 802)
    seed.blocked_by(802, 801)
    seed.fail("adapter_blocker_add")

    ticket_block(fake(seed), "802", "801")

    assert blockers_of(store, 802) == ["801"]
    assert read(store, "issues", 802, "body") == (
        "Build the thing.\n\n## Blocked by\n\n- #801\n")


def test_unblock_removes_each_edge_named_and_writes_none_once_the_last_goes(seed, store):
    breakdown(seed, 801, 802, 803)
    seed.blocked_by(803, 801, 802)

    ticket_unblock(fake(seed), "803", "802")
    assert blockers_of(store, 803) == ["801"]
    assert read(store, "issues", 803, "body") == "Build the thing.\n\n## Blocked by\n\n- #801\n"

    seed.fail("adapter_blocker_remove")
    ticket_unblock(fake(seed), "803", "802")
    seed.unfail()
    ticket_unblock(fake(seed), "803", "801")
    assert blockers_of(store, 803) == []
    assert read(store, "issues", 803, "body") == UNBLOCKED


def test_an_edge_on_a_closed_blocker_is_still_a_record(seed, store):
    breakdown(seed, 801, 802)
    seed.issue(801, "closed")

    ticket_block(fake(seed), "802", "801")

    assert blockers_of(store, 802) == ["801"]


@pytest.mark.parametrize("n, by, message", [
    ("abc", "801", "not a plain issue number: abc"),
    ("802", "", "--by must be plain issue numbers, got nothing"),
    ("802", "801,,801", "--by must be plain issue numbers, got: 801,,801"),
    ("802", "801,x1", "--by must be plain issue numbers, got: 801,x1"),
    ("802", "5\n", "--by must be plain issue numbers, got: 5\n"),
    ("803", "801", "ticket #803 is closed - its blocking edges can no longer change anything"),
    ("96", "801", "#96 is not a sub-issue, so it is no ticket of a breakdown"),
    ("802", "801,900", "#900 is not a sub-issue of #96, ticket #802's parent - edges never cross"
                       " breakdowns"),
])
@pytest.mark.parametrize("command", [ticket_block, ticket_unblock])
def test_an_edge_change_refused_before_any_write(seed, store, capsys, command, n, by, message):
    breakdown(seed, 801, 802, 803)
    seed.issue(803, "closed")
    seed.issue(97, "open")
    seed.issue(900, "open")
    seed.sub_issue(97, 900)
    before = snapshot(store)

    assert died_of(capsys, lambda: command(fake(seed), n, by)) == (1, "", "orch: %s\n" % message)
    assert snapshot(store) == before


@pytest.mark.parametrize("operation, after, message", [
    ("adapter_issue_state", 0, "gh could not read ticket #802: HTTP 502: Bad Gateway"),
    ("adapter_issue_parent", 0, "gh could not read issue #802's parent: HTTP 502: Bad Gateway"),
    ("adapter_issue_parent", 1,
     "gh could not read issue #801's parent, a blocker of ticket #802: HTTP 502: Bad Gateway"),
    ("adapter_blockers", 0, "gh could not read ticket #802's blockers: HTTP 502: Bad Gateway"),
    ("adapter_blocker_add", 0,
     "gh could not add a blocking edge from ticket #802 on #801: HTTP 502: Bad Gateway"),
    ("adapter_blockers", 1, "gh could not read ticket #802's blockers: HTTP 502: Bad Gateway"),
    ("adapter_issue_body", 0, "gh could not read ticket #802's body: HTTP 502: Bad Gateway"),
    ("adapter_issue_body_edit", 0,
     "gh could not rewrite ticket #802's ## Blocked by section: HTTP 502: Bad Gateway"),
])
def test_a_block_github_fails_dies_naming_the_step(seed, capsys, operation, after, message):
    breakdown(seed, 801, 802)
    seed.fail_after(operation, after, GH_502)

    assert died_of(capsys, lambda: ticket_block(fake(seed), "802", "801")) == (
        1, "", "orch: %s\n" % message)


def test_an_unblock_whose_edge_removal_fails_dies_naming_it(seed, capsys):
    breakdown(seed, 801, 802)
    seed.blocked_by(802, 801)
    seed.fail("adapter_blocker_remove", GH_502)

    assert died_of(capsys, lambda: ticket_unblock(fake(seed), "802", "801")) == (
        1, "", "orch: gh could not remove a blocking edge from ticket #802 on #801:"
               " HTTP 502: Bad Gateway\n")


def test_a_read_back_wrong_once_is_retried_and_wrong_twice_dies(seed, store, capsys):
    breakdown(seed, 801, 802, 803)
    seed.lag_after("adapter_blockers", 1, 1, "999999")
    ticket_block(fake(seed), "802", "801")
    assert blockers_of(store, 802) == ["801"]

    seed.lag_after("adapter_blockers", 1, 2, "999999")
    assert died_of(capsys, lambda: ticket_block(fake(seed), "803", "801")) == (
        1, "", "orch: ticket #803's blocking edges did not verify - checked twice, both"
               " failed\n")
    assert read(store, "issues", 803, "body") == UNBLOCKED


@pytest.mark.parametrize("body, rewritten", [
    ("Intro\n\n## Blocked by\n\n- #999\nold\n\n### Detail\nx\n\n## After\nTail.\n",
     "Intro\n\n## Blocked by\n\n- #1\n- #2\n\n## After\nTail.\n"),
    ("Intro\n\nMore.\n", "Intro\n\nMore.\n\n## Blocked by\n\n- #1\n- #2\n"),
    ("Intro\n\n## Blocked by\n\nNone\n# Top\nTail.\n",
     "Intro\n\n## Blocked by\n\n- #1\n- #2\n\n# Top\nTail.\n"),
    ("Intro\r\n\r\n## Blocked by\r\n\r\nNone\r\n\r\n## After\r\nTail.\r\n",
     "Intro\r\n\r\n## Blocked by\r\n\r\n- #1\r\n- #2\r\n\r\n## After\r\nTail.\r\n"),
    ("Intro\n\n```md\n## Blocked by\n\n- #1\n```\n",
     "Intro\n\n```md\n## Blocked by\n\n- #1\n```\n\n## Blocked by\n\n- #1\n- #2\n"),
    ("## Blocked by\n\n```\n## Not a heading\n```\n\n## After\nTail.\n",
     "## Blocked by\n\n- #1\n- #2\n\n## After\nTail.\n"),
    ("", "## Blocked by\n\n- #1\n- #2\n"),
])
def test_the_blocked_by_rewrite_replaces_the_first_unfenced_section_or_appends_one(
        body, rewritten):
    assert rewrite_blocked_by_section(body, [1, 2]) == rewritten


def test_the_blocked_by_rewrite_of_no_blockers_reads_none():
    assert rewrite_blocked_by_section("A\n## Blocked by\n- #1\n", []) == (
        "A\n## Blocked by\n\nNone (can start immediately)\n")


def test_a_rewrite_leaving_the_body_byte_identical_writes_no_body(seed):
    breakdown(seed, 801, 802)
    seed.blocked_by(802, 801)
    seed.body(802, "## Blocked by\n\n- #801")
    seed.fail("adapter_issue_body_edit")

    ticket_block(fake(seed), "802", "801")


# --- ticket retire ----------------------------------------------------------------------

RETIRED = ("This ticket was retired: its spec, #14, changed and will be broken down into"
           " tickets again.")
RETIRED_BY_REDO = ("This ticket was retired by an orchestrator redo: its spec, #14, is being"
                   " redone and will be broken down into tickets again.")


@pytest.fixture
def retiring(seed, tmp_path):
    """#14's breakdown: open #20, closed #21, closed #22 already commented on
    in the redo wording, a ## Ticket section in #14's body, saved reports
    and a breakdown save point under the checkout at tmp_path/repo."""
    seed.issue(14, "open")
    seed.body(14, "# Spec\n\nBody.\n\n## Ticket\n\nBuild it.\n")
    seed.issue(20, "open")
    seed.issue(21, "closed")
    seed.issue(22, "closed")
    seed.comment(22, "fake-gh", "2026-01-01T00:00:00Z", RETIRED_BY_REDO)
    for n in (20, 21, 22):
        seed.sub_issue(14, n)
    root = tmp_path / "repo"
    (root / ".orchestrator" / "reports").mkdir(parents=True)
    for n in (14, 20, 99):
        (root / ".orchestrator" / "reports" / ("%d.md" % n)).write_text("report\n")
    (root / ".orchestrator" / "breakdown" / "14").mkdir(parents=True)
    (root / ".orchestrator" / "breakdown" / "14" / "order").write_text("1\n")
    return root


def test_retire_closes_comments_unlinks_and_cuts_the_breakdown(seed, store, retiring):
    ticket_retire(fake(seed), "14", str(retiring))

    assert (read(store, "issues", 20, "state"), read(store, "issues", 20, "reason")) == (
        "CLOSED\n", "not planned\n")
    assert comments_of(store, 20) == [RETIRED]
    assert comments_of(store, 21) == [RETIRED + "\n"]
    assert comments_of(store, 22) == [RETIRED_BY_REDO]
    assert read(store, "subs", 14) == ""
    assert read(store, "issues", 14, "body") == "# Spec\n\nBody.\n"
    assert sorted(os.listdir(str(retiring / ".orchestrator" / "reports"))) == ["99.md"]
    assert not (retiring / ".orchestrator" / "breakdown" / "14").exists()


def test_a_retire_run_again_writes_nothing(seed, store, retiring):
    ticket_retire(fake(seed), "14", str(retiring))
    before = snapshot(store)

    ticket_retire(fake(seed), "14", str(retiring))

    assert snapshot(store) == before


def test_a_retired_ticket_already_carrying_the_retire_wording_is_not_commented_again(
        seed, store, retiring):
    seed.comment(21, "fake-gh", "2026-01-01T00:00:00Z", RETIRED + "\n")

    ticket_retire(fake(seed), "14", str(retiring))

    assert comments_of(store, 21) == [RETIRED + "\n"]


@pytest.mark.parametrize("operation, after, message", [
    ("adapter_sub_issues", 0, "gh could not list sub-issues of #14: HTTP 502: Bad Gateway"),
    ("adapter_issue_close", 0, "gh could not close ticket #20: HTTP 502: Bad Gateway"),
    ("adapter_issue_comments", 0, "gh could not read ticket #21's comments: HTTP 502: Bad Gateway"),
    ("adapter_issue_comment", 0, "gh could not comment on ticket #21: HTTP 502: Bad Gateway"),
    ("adapter_sub_issue_unlink", 0, "gh could not unlink ticket #20 from #14: HTTP 502: Bad Gateway"),
    ("adapter_issue_body", 0, "gh could not read issue #14's body: HTTP 502: Bad Gateway"),
    ("adapter_issue_body_edit", 0,
     "gh could not remove the ## Ticket section from #14: HTTP 502: Bad Gateway"),
])
def test_a_retire_github_fails_dies_naming_the_step(seed, capsys, retiring, operation, after,
                                                    message):
    seed.fail_after(operation, after, GH_502)

    assert died_of(capsys, lambda: ticket_retire(fake(seed), "14", str(retiring))) == (
        1, "", "orch: %s\n" % message)


def test_a_saved_report_that_cannot_be_removed_dies_before_the_unlink(seed, store, capsys,
                                                                      retiring):
    (retiring / ".orchestrator" / "reports" / "20.md").unlink()
    (retiring / ".orchestrator" / "reports" / "20.md").mkdir()

    assert died_of(capsys, lambda: ticket_retire(fake(seed), "14", str(retiring))) == (
        1, "", "orch: could not remove ticket #20's saved report\n")
    assert read(store, "subs", 14) == "20\n21\n22\n"


def test_a_breakdown_save_point_that_cannot_be_removed_dies_naming_it(seed, capsys, retiring,
                                                                      monkeypatch):
    def refused(*_, **__):
        raise PermissionError("refused")

    monkeypatch.setattr("shutil.rmtree", refused)

    assert died_of(capsys, lambda: ticket_retire(fake(seed), "14", str(retiring))) == (
        1, "", "orch: could not remove the breakdown save point of #14\n")
