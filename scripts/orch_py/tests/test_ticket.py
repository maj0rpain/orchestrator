"""The ticket module's listing reads and body reads, as the bash ticket
module's copies answer them: a breakdown's sub-issue listing read from the gh
fake's store, its gh failure through the store's failure injection under the
bash operation name, and the `## Blocked by` and `## Ticket` reads of a body,
code fences and CRLF ends included."""
from __future__ import annotations

import pytest

from conftest import GH_502, died_of, fake
from orch.gh import SubIssue
from orch.ticket import (blocked_by_section_numbers, has_ticket_heading, strip_ticket_sections,
                         ticket_listing_state, ticket_sub_issues)


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
