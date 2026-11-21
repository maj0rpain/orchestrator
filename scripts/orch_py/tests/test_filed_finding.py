"""The Filed finding module's additions for finding triage: the filed
severities and their label test, the category table and its label create,
the other category, and the body parse, read as the bash filed-finding.sh
reads a filed finding's issue body."""
from __future__ import annotations

import pytest

from orch import filed_finding
from orch.filed_finding import FindingBody, finding_body_parse
from conftest import fake

SHA = "0123456789abcdef0123456789abcdef01234567"
URL = "https://github.com/acme/widgets/pull/42"
EMPTY = FindingBody("", "", "", "", "", "", "", "", "", "")


def lines(*text):
    return "\n".join(text) + "\n"


# A filed finding's body as review file renders it.
RENDERED = lines(
    "> The reviewer said this.", "", "**Axis:** Standards", "",
    "**Severity:** nit - a reason.", "", "**Location:** `src/app.sh:7` at " + SHA, "",
    "**PR:** " + URL, "", "**Why not fixed in the loop:** found in the final iteration.", "",
)
# The closer's format before rendering, written by hand: no trailing blank
# line, a PR URL with a trailing slash and spaces.
LEGACY = lines(
    "## Finding", "", "> The reviewer said this.", "", "**Axis:** Standards", "",
    "**Severity:** nit - a reason.", "", "**Location:** `src/app.sh:3` at " + SHA, "",
    "**PR:** " + URL + "/  ", "", "**Why not fixed in the loop:** found in the final iteration.",
)


def without(body, label):
    return "".join(line for line in body.splitlines(True) if not line.startswith(label))


# --- severities and categories --------------------------------------------


def test_the_filed_severities_are_major_and_nit_in_order():
    assert filed_finding.FILED_SEVERITIES == ("major", "nit")


@pytest.mark.parametrize("labels, filed", [
    (["bug", "review:nit"], True),
    (["Review:MAJOR"], True),
    (["review:blocking"], False),
    (["review:"], False),
    (["nit", "major"], False),
    ([], False),
])
def test_a_filed_severity_label_is_a_review_label_at_a_filed_severity(labels, filed):
    assert filed_finding.has_filed_severity_label(labels) is filed


@pytest.mark.parametrize("category, other", [
    ("bug", "enhancement"), ("enhancement", "bug"), ("documentation", None), ("Bug", None),
])
def test_the_other_category_is_the_one_triage_drops(category, other):
    assert filed_finding.category_other(category) == other


def test_the_category_table_holds_each_category_s_colour_and_description():
    assert filed_finding.FILED_CATEGORIES == (
        ("bug", "d73a4a", "Something isn't working"),
        ("enhancement", "a2eeef", "New feature or request"),
        ("documentation", "0075ca", "Improvements or additions to documentation"),
    )


def test_the_category_label_is_created_where_missing_with_its_colour_and_description(
        store, seed):
    gh = fake(seed)

    assert filed_finding.category_label_ensure(gh, "enhancement") is True
    assert (store / "labels").read_text() == "enhancement\ta2eeef\tNew feature or request\n"


def test_a_category_label_that_exists_is_left_as_it_is_and_the_failed_create_forgiven(
        store, seed, capsys):
    (store / "labels").write_text("Bug\tffffff\tours\n")
    gh = fake(seed)

    assert filed_finding.category_label_ensure(gh, "bug") is True
    seed.fail("adapter_label_create", "HTTP 502: Bad Gateway")
    assert filed_finding.category_label_ensure(gh, "documentation") is True

    assert (store / "labels").read_text() == "Bug\tffffff\tours\n"
    assert capsys.readouterr() == ("", "")


def test_an_unknown_category_creates_no_label(store, seed):
    assert filed_finding.category_label_ensure(fake(seed), "question") is False
    assert not (store / "labels").exists()


# --- the body parse --------------------------------------------------------


def test_a_rendered_body_parses_back_to_every_part():
    assert finding_body_parse(RENDERED) == FindingBody(
        axis="standards", severity="nit", reason="a reason.", file="src/app.sh", line="7",
        sha=SHA, pr=URL, pr_number="42", why="found in the final iteration.", question="")


def test_a_range_and_a_spec_question_parse_back():
    body = lines("Spans lines.", "", "**Axis:** Spec", "", "**Severity:** major - misses the spec",
                 "", "**Location:** `lib/x.sh:10-20` at " + SHA, "", "**PR:** " + URL, "",
                 "**Why not fixed in the loop:** it is a spec question", "",
                 "**Spec question:** Should it?")

    assert finding_body_parse(body) == FindingBody(
        "spec", "major", "misses the spec", "lib/x.sh", "10-20", SHA, URL, "42",
        "it is a spec question", "Should it?")


def test_a_severity_reason_holding_a_dash_splits_at_the_first_one():
    parsed = finding_body_parse("**Severity:**  nit - cheap - but noisy - fix \n")

    assert (parsed.severity, parsed.reason) == ("nit", "cheap - but noisy - fix")


def test_a_severity_with_no_reason_is_the_whole_value():
    assert finding_body_parse("**Severity:** major\r\n")[1:3] == ("major", "")


def test_a_legacy_body_parses_to_the_same_fields():
    assert finding_body_parse(LEGACY) == FindingBody(
        "standards", "nit", "a reason.", "src/app.sh", "3", SHA, URL + "/", "42",
        "found in the final iteration.", "")


def test_a_missing_field_is_left_empty_and_the_rest_filled():
    no_loc = finding_body_parse(without(LEGACY, "**Location:**"))
    no_pr = finding_body_parse(without(LEGACY, "**PR:**"))
    no_axis_why = finding_body_parse(without(without(LEGACY, "**Axis:**"), "**Why not"))

    assert (no_loc.file, no_loc.line, no_loc.sha, no_loc.pr_number) == ("", "", "", "42")
    assert (no_pr.pr, no_pr.pr_number, no_pr.file) == ("", "", "src/app.sh")
    assert (no_axis_why.axis, no_axis_why.why, no_axis_why.severity) == ("", "", "nit")


def test_a_body_quoting_location_and_pr_lines_parses_from_the_first_of_each():
    quoting = lines("The reviewer quoted:", "**Location:** `old/file.sh:9` at abc123",
                    "**PR:** https://github.com/acme/widgets/pull/5", "") + LEGACY

    parsed = finding_body_parse(quoting)

    assert (parsed.file, parsed.line, parsed.sha, parsed.pr, parsed.pr_number) == (
        "old/file.sh", "9", "abc123", "https://github.com/acme/widgets/pull/5", "5")


@pytest.mark.parametrize("first", [
    "**Location:** somewhere", "**Location:** `suite` at " + SHA, "**Location:** `a.sh:2` nowhere",
], ids=["no-backticks", "no-line", "no-sha"])
def test_a_first_location_line_that_does_not_parse_leaves_location_empty(first):
    parsed = finding_body_parse(lines(first, "") + LEGACY)

    assert (parsed.file, parsed.line, parsed.sha) == ("", "", "")


def test_pr_comes_from_the_first_line_matching_the_whole_pr_rule():
    parsed = finding_body_parse(lines("**PR:** not a link", "") + LEGACY)

    assert (parsed.pr, parsed.pr_number) == (URL + "/", "42")


def test_the_sha_is_the_hex_run_of_the_line_s_last_at():
    parsed = finding_body_parse("**Location:** `a.sh:2` at deadbeef, rebased at %s\n" % SHA)

    assert (parsed.file, parsed.line, parsed.sha) == ("a.sh", "2", SHA)


def test_a_body_with_no_labelled_lines_leaves_every_field_empty():
    assert finding_body_parse("nothing labelled here") == EMPTY
    assert finding_body_parse("") == EMPTY
