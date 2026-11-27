"""`review file`, review.run in-process in a FakeGit checkout under tmp_path
with its flow state, filing to the gh fake's store: the cases of the bash
review file section - the finding filed under its labels with its rendered
body and its number alone printed, every guard in bash's order with nothing
written to GitHub, the PR's head SHA check, the round trip refusal, and a
failed label ensure or issue create. Its usage line and the no-flow refusal
are test_review_noun.py's."""
from __future__ import annotations

import os
import tempfile

import pytest

from conftest import (AUTOPILOT, CLAUDE, GH_502, SESSIONS, hold_flow, labels_doc, orch_review,
                      read, snapshot, write_labels_doc)

PR_URL = "https://ghe.example.com/x/y/pull/7"
USAGE = ("orch: usage: orch.sh review file <major|nit> <title> --axis <spec|standards>"
         " --finding-file <f> --severity-reason <r> --location <<file>:<line>> --why <reason>"
         " [--spec-question <q>]\n")


@pytest.fixture
def finding(tmp_path):
    """The finding's text, two paragraphs and trailing blank lines: its
    path."""
    path = tmp_path / "finding.md"
    path.write_text("The reviewer said this.\n\nIt spans two paragraphs.\n\n\n\n")
    return str(path)


@pytest.fixture
def parts(finding):
    """review file's flag/value pairs, a Standards finding at scripts/a.sh:12."""
    return ["--axis", "standards", "--finding-file", finding,
            "--severity-reason", "Misleads a reader", "--location", "scripts/a.sh:12",
            "--why", "found in the final iteration"]


@pytest.fixture
def filing(root, seed):
    """A flow on issue #3 with PR #7 recorded, PR #7 open from topic onto
    main in the store, its url and head SHA seeded to differ from anything
    the checkout holds."""
    hold_flow(root, slug="x", phase="review", issue=3, pr=7)
    seed.pr(7, "open", "topic", "main")
    seed.pr_url(7, PR_URL)
    seed.pr_head(7, "abc1234")


def with_flag(parts, flag, *value):
    """<parts> with <flag>'s value replaced by <value>, or, given none,
    <flag> and its value dropped."""
    out = []
    for i in range(0, len(parts), 2):
        if parts[i] != flag:
            out += parts[i:i + 2]
        elif value:
            out += [flag, value[0]]
    return out


def repo_labels(store):
    """The repo's labels in the store, one (name, colour, description) each,
    in the store's order."""
    return [tuple(line.split("\t")) for line in (read(store, "labels") or "").splitlines()]


def issue_labels(store, n):
    return sorted((read(store, "issues", n, "labels") or "").splitlines())


def lines(*text):
    return "".join(line + "\n" for line in text)


# --- filing -------------------------------------------------------------------


@SESSIONS
def test_a_major_is_filed_under_its_labels_its_body_rendered_and_its_number_alone_printed(
        root, seed, store, filing, parts, capsys, env):
    (store / "labels").write_text("review:major\tffffff\tAn older description\n"
                                  "needs-triage\t000000\tThe repo's own\n")
    seed.next_issue(17)

    assert orch_review(seed, root, "file", "major", "Comment drifted from the code", *parts,
                       env=env) == 0
    assert capsys.readouterr() == ("17\n", "")
    assert repo_labels(store) == [
        ("needs-triage", "000000", "The repo's own"),
        ("review:major", "d93f0b", "Review finding filed at major severity"),
        ("enhancement", "a2eeef", "New feature or request")]
    assert read(store, "issues", 17, "title") == "Comment drifted from the code\n"
    assert issue_labels(store, 17) == ["enhancement", "needs-triage", "review:major"]
    assert read(store, "issues", 17, "body") == lines(
        "The reviewer said this.", "", "It spans two paragraphs.", "", "**Axis:** Standards", "",
        "**Severity:** major - Misleads a reader", "", "**Location:** `scripts/a.sh:12` at abc1234",
        "", "**PR:** " + PR_URL, "", "**Why not fixed in the loop:** found in the final iteration",
        "")


def test_flags_in_any_order_a_spec_question_a_range_and_padded_values_file_trimmed(
        root, seed, store, filing, finding, capsys):
    seed.next_issue(18)

    assert orch_review(seed, root, "file", "major", "Misses a criterion",
                       "--why", "  it is a spec question  ",
                       "--spec-question", " Should it archive first? ",
                       "--location", "scripts/a.sh:12-20",
                       "--severity-reason", "Misses a criterion - the second one",
                       "--finding-file", finding, "--axis", "SPEC") == 0
    assert capsys.readouterr() == ("18\n", "")
    assert read(store, "issues", 18, "body") == lines(
        "The reviewer said this.", "", "It spans two paragraphs.", "", "**Axis:** Spec", "",
        "**Severity:** major - Misses a criterion - the second one", "",
        "**Location:** `scripts/a.sh:12-20` at abc1234", "", "**PR:** " + PR_URL, "",
        "**Why not fixed in the loop:** it is a spec question", "",
        "**Spec question:** Should it archive first?", "")
    assert issue_labels(store, 18) == ["bug", "needs-triage", "review:major"]


def test_an_upper_case_hex_head_files_as_given(root, seed, store, filing, parts, capsys):
    seed.pr_head(7, "ABC1234")

    assert orch_review(seed, root, "file", "major", "Title", *parts) == 0
    n = capsys.readouterr().out.strip()
    assert "**Location:** `scripts/a.sh:12` at ABC1234\n" in read(store, "issues", n, "body")


def test_a_nit_files_making_its_label_and_the_triage_label_a_repo_lacks(
        root, seed, store, filing, parts, capsys):
    assert orch_review(seed, root, "file", "nit", "Rename it", *parts) == 0
    n = capsys.readouterr().out.strip()
    assert issue_labels(store, n) == ["enhancement", "needs-triage", "review:nit"]
    assert repo_labels(store) == [
        ("review:nit", "c5def5", "Review finding filed at nit severity"),
        ("needs-triage", "e4e669", "Not yet triaged"),
        ("enhancement", "a2eeef", "New feature or request")]
    assert "**Severity:** nit - Misleads a reader\n" in read(store, "issues", n, "body")


@pytest.mark.parametrize("axis, category", [("spec", "bug"), ("Standards", "enhancement")])
def test_the_category_is_the_axis_s_whatever_its_case(root, seed, store, filing, parts, capsys,
                                                        axis, category):
    assert orch_review(seed, root, "file", "major", "T", *with_flag(parts, "--axis", axis)) == 0
    n = capsys.readouterr().out.strip()
    assert issue_labels(store, n) == sorted([category, "needs-triage", "review:major"])
    assert [label[0] for label in repo_labels(store)] == ["review:major", "needs-triage",
                                                          category]


def test_a_category_label_the_repo_has_is_left_as_it_is_and_still_applied(
        root, seed, store, filing, parts, capsys):
    (store / "labels").write_text("bug\t123456\tThe repo's own bug\n")
    seed.next_issue(23)

    assert orch_review(seed, root, "file", "major", "T", *with_flag(parts, "--axis", "spec")) == 0
    assert capsys.readouterr() == ("23\n", "")
    assert ("bug", "123456", "The repo's own bug") in repo_labels(store)
    assert "bug" in issue_labels(store, 23)


def test_a_category_label_gh_fails_to_create_for_another_reason_does_not_stop_filing(
        root, seed, store, filing, parts, capsys):
    seed.fail("adapter_label_create", "HTTP 502: Bad Gateway")
    seed.next_issue(24)

    assert orch_review(seed, root, "file", "major", "T", *parts) == 0
    assert capsys.readouterr() == ("24\n", "")


def test_the_triage_label_is_the_repo_s_renamed_one(root, seed, store, filing, parts, capsys):
    write_labels_doc(root, labels_doc(("needs-triage", "triage me"),
                                      ("ready-for-agent", "ready-for-agent")))

    assert orch_review(seed, root, "file", "nit", "Rename it", *parts) == 0
    n = capsys.readouterr().out.strip()
    assert issue_labels(store, n) == ["enhancement", "review:nit", "triage me"]
    assert ("triage me", "e4e669", "Not yet triaged") in repo_labels(store)
    assert "needs-triage" not in [label[0] for label in repo_labels(store)]


# --- the guards, in order, before any write -----------------------------------


@pytest.mark.parametrize("drop, add", [
    ("--axis", []), ("--finding-file", []), ("--severity-reason", []), ("--location", []),
    ("--why", []), (None, ["--why", "again"]), (None, ["--frobnicate", "x"]),
    (None, ["--spec-question"]), (None, ["--body-file", "x"]), (None, ["--sha", "abc1234"]),
    (None, ["--pr", "https://github.com/o/r/pull/7"]),
    (None, ["--spec-question", "   "]),
], ids=["no-axis", "no-finding-file", "no-severity-reason", "no-location", "no-why",
        "repeated", "unknown", "no-value", "body-file", "sha", "pr", "empty-question"])
def test_a_flag_wrong_refuses_with_the_usage_line_writing_nothing(
        root, seed, store, filing, parts, capsys, drop, add):
    before = snapshot(store)
    args = with_flag(parts, drop) if drop else list(parts)

    assert orch_review(seed, root, "file", "major", "Title", *args, *add) == 1
    assert capsys.readouterr() == ("", USAGE)
    assert snapshot(store) == before


@pytest.mark.parametrize("flag", ["--axis", "--finding-file", "--severity-reason", "--location",
                                  "--why"])
def test_an_empty_value_refuses_with_the_usage_line(root, seed, store, filing, parts, capsys,
                                                    flag):
    before = snapshot(store)

    assert orch_review(seed, root, "file", "major", "Title", *with_flag(parts, flag, "   ")) == 1
    assert capsys.readouterr() == ("", USAGE)
    assert snapshot(store) == before


def test_a_positional_in_place_of_a_flag_is_refused_with_the_usage_line(
        root, seed, filing, finding, capsys):
    assert orch_review(seed, root, "file", "major", "Title", "--axis", "spec", finding) == 1
    assert capsys.readouterr() == ("", USAGE)


@pytest.mark.parametrize("axis", ["style", "suite-cost"])
def test_an_axis_that_is_none_is_refused_naming_both(root, seed, store, filing, parts, capsys,
                                                    axis):
    before = snapshot(store)

    assert orch_review(seed, root, "file", "major", "T", *with_flag(parts, "--axis", axis)) == 1
    assert capsys.readouterr() == (
        "", "orch: not a review axis: %s (want spec or standards)\n" % axis)
    assert snapshot(store) == before


def test_blocking_is_refused_as_never_filed_before_the_axis(root, seed, store, filing, parts,
                                                            capsys):
    before = snapshot(store)

    assert orch_review(seed, root, "file", "blocking", "Wrong",
                       *with_flag(parts, "--axis", "style")) == 1
    assert capsys.readouterr() == (
        "", "orch: not a severity that gets filed: blocking (want major or nit - blocking is"
            " always fixed, never filed)\n")
    assert snapshot(store) == before


@pytest.mark.parametrize("title, text, message", [
    ("", "x\n", "the title is empty"),
    ("T", None, "finding file not found: %s"),
    ("T", "  \n\t\n\n", "finding file is empty: %s"),
    ("T", "", "finding file is empty: %s"),
], ids=["no-title", "missing", "whitespace", "empty"])
def test_the_title_and_the_finding_file_are_checked_before_the_location(
        root, seed, store, filing, parts, tmp_path, capsys, title, text, message):
    path = tmp_path / "given.md"
    if text is not None:
        path.write_text(text)
    args = with_flag(with_flag(parts, "--finding-file", str(path)), "--location", "suite")
    before = snapshot(store)

    assert orch_review(seed, root, "file", "major", title, *args) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % (message.replace("%s", str(path))))
    assert snapshot(store) == before


@pytest.mark.parametrize("location", ["suite", "scripts/a.sh", "scripts/a.sh:", ":12",
                                      "scripts/a.sh:x", "scripts/a.sh:12-", "scripts/a.sh:-3",
                                      "scripts/a.sh:1-2-3"])
def test_a_location_that_is_none_is_refused_before_github_is_read(
        root, seed, store, filing, parts, capsys, location):
    seed.fail("adapter_pr_url_head", GH_502)
    before = snapshot(store)

    assert orch_review(seed, root, "file", "major", "T",
                       *with_flag(parts, "--location", location)) == 1
    assert capsys.readouterr() == (
        "", "orch: not a location: %s (want <file>:<line> or <file>:<start>-<end>)\n" % location)
    assert snapshot(store) == before


def test_no_pr_in_state_is_refused_in_require_value_s_words(root, seed, store, parts, capsys):
    hold_flow(root, slug="x", phase="review", issue=3)
    before = snapshot(store)

    assert orch_review(seed, root, "file", "major", "T", *parts) == 1
    assert capsys.readouterr() == (
        "", "orch: no PR recorded in state - the implement phase opens it\n")
    assert snapshot(store) == before


def test_a_pr_github_cannot_read_dies_with_gh_s_first_line(root, seed, store, filing, parts,
                                                            capsys):
    seed.fail("adapter_pr_url_head", GH_502)
    before = snapshot(store)

    assert orch_review(seed, root, "file", "major", "T", *parts) == 1
    assert capsys.readouterr() == (
        "", "orch: gh could not read the URL and head of PR #7, recorded in state:"
            " HTTP 502: Bad Gateway\n")
    assert snapshot(store) == before


@pytest.mark.parametrize("sha", ["HEAD", ""])
def test_a_pr_head_that_is_not_hex_is_refused_naming_it(root, seed, store, filing, parts, capsys,
                                                       sha):
    seed.pr_head(7, sha)
    before = snapshot(store)

    assert orch_review(seed, root, "file", "major", "T", *parts) == 1
    assert capsys.readouterr() == ("", "orch: not a sha: %s (want a hex commit SHA)\n" % sha)
    assert snapshot(store) == before


# --- the round trip -----------------------------------------------------------


def test_a_pr_url_without_a_pull_number_does_not_parse_back(root, seed, store, filing, parts,
                                                           capsys):
    seed.pr_url(7, "https://ghe.example.com/x/y/issues/7")
    before = snapshot(store)

    assert orch_review(seed, root, "file", "major", "T", *parts) == 1
    assert capsys.readouterr() == (
        "", "orch: the rendered body does not parse back: pr (given"
            " 'https://ghe.example.com/x/y/issues/7', parsed '')\n")
    assert snapshot(store) == before


def test_a_value_holding_a_newline_does_not_parse_back_naming_the_field(
        root, seed, store, filing, parts, capsys):
    before = snapshot(store)

    assert orch_review(seed, root, "file", "major", "T",
                       *with_flag(parts, "--why", "one line\nand another")) == 1
    assert capsys.readouterr() == (
        "", "orch: the rendered body does not parse back: why (given 'one line\nand another',"
            " parsed 'one line')\n")
    assert snapshot(store) == before


def test_a_finding_quoting_a_labelled_line_does_not_parse_back(root, seed, store, filing, parts,
                                                              tmp_path, capsys):
    quoting = tmp_path / "quoting.md"
    quoting.write_text("It reads the line\n**Axis:** Spec\nas the axis.\n")

    assert orch_review(seed, root, "file", "major", "T",
                       *with_flag(parts, "--finding-file", str(quoting))) == 1
    assert capsys.readouterr() == (
        "", "orch: the rendered body does not parse back: axis (given 'standards', parsed"
            " 'spec')\n")
    assert read(store, "labels") is None


def test_a_location_file_holding_a_backtick_does_not_parse_back(root, seed, store, filing, parts,
                                                               capsys):
    assert orch_review(seed, root, "file", "major", "T",
                       *with_flag(parts, "--location", "scripts/a`b.sh:12")) == 1
    assert capsys.readouterr() == (
        "", "orch: the rendered body does not parse back: file (given 'scripts/a`b.sh',"
            " parsed 'b.sh')\n")
    assert read(store, "labels") is None


# --- failed writes --------------------------------------------------------------


def test_a_failed_issue_create_dies_printing_no_number_the_labels_ensured_left(
        root, seed, store, filing, parts, capsys):
    seed.fail("adapter_issue_create", GH_502)

    assert orch_review(seed, root, "file", "major", "T", *parts) == 1
    assert capsys.readouterr() == ("", "orch: gh could not create the issue: HTTP 502: Bad Gateway\n")
    assert not os.path.isdir(os.path.join(str(store), "issues"))
    assert [label[0] for label in repo_labels(store)] == ["review:major", "needs-triage",
                                                          "enhancement"]


def test_a_failed_severity_label_ensure_dies_before_any_other_label_or_the_issue(
        root, seed, store, filing, parts, capsys):
    seed.fail("adapter_label_upsert", GH_502)

    assert orch_review(seed, root, "file", "major", "T", *parts) == 1
    assert capsys.readouterr() == (
        "", "orch: gh could not create label review:major: HTTP 502: Bad Gateway\n")
    assert read(store, "labels") is None
    assert not os.path.isdir(os.path.join(str(store), "issues"))


@pytest.mark.parametrize("case", ["filed", "refused", "failed"])
def test_the_body_s_temp_file_is_gone_on_every_exit(root, seed, filing, parts, tmp_path,
                                                    monkeypatch, capsys, case):
    empty = tmp_path / "tmp"
    empty.mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(empty))
    quoting = tmp_path / "quoting.md"
    quoting.write_text("**Axis:** Spec\n")
    if case == "failed":
        seed.fail("adapter_issue_create", GH_502)
    args = with_flag(parts, "--finding-file", str(quoting)) if case == "refused" else parts

    assert orch_review(seed, root, "file", "major", "T", *args) == (0 if case == "filed" else 1)
    assert os.listdir(str(empty)) == []


def test_an_autopilot_session_files_as_a_plain_one(root, seed, store, filing, parts, capsys):
    runs = []
    for env in (CLAUDE, AUTOPILOT):
        seed.next_issue(40)
        code = orch_review(seed, root, "file", "major", "T", *parts, env=env)
        runs.append((code, capsys.readouterr()))

    assert runs[0] == runs[1] == (0, ("40\n", ""))
