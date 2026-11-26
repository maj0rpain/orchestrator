"""The review-pass noun's known-items verb, run in-process against FakeGit and
the gh fake, with the checkout and the known-items file under tmp_path, each
checked by the file it writes, its exit code and its `orch:` message - as the
bash review-pass known-items it replaced answered."""
from __future__ import annotations

import os

import pytest

from orch.git import FakeGit
from orch.repo import REPO_REMEDY, RepoPin
from conftest import GH_502, UnparsedPrComments, orch_review_pass

ORIGIN = {"origin": "https://github.com/acme/widgets.git"}
BRANCH = "quick/21-foo"
USAGE = "usage: orch.sh review-pass known-items <issue> <path> [--deviations <file>]"
RULING = "Spec ruling:"


def lines(*items):
    """The items as a file's lines, each newline-terminated."""
    return "".join(item + "\n" for item in items)


@pytest.fixture
def git(tmp_path):
    """The checkout's git adapter: its toplevel tmp_path/repo, on BRANCH,
    with a GitHub origin."""
    root = tmp_path / "repo"
    root.mkdir()
    adapter = FakeGit(ORIGIN, toplevel=str(root))
    adapter.seed("current_branch", answer=BRANCH)
    return adapter


@pytest.fixture
def kp(tmp_path):
    """The directory the known-items file and the deviations files go in."""
    path = tmp_path / "kp"
    path.mkdir()
    return path


@pytest.fixture
def issue(seed):
    """Issue #21, open, with no comments."""
    seed.issue(21, "open")
    return 21


def known_items(seed, git, *args, env=None):
    return orch_review_pass(seed, git, "known-items", *args, env=env)


def known_side(path):
    """The file's `## Known items` heading and what follows it."""
    text = path.read_text()
    return text[text.index("## Known items\n"):]


def test_with_no_open_pr_only_the_issue_rulings_and_the_deviations_file_are_read(
        seed, git, kp, issue, capsys):
    seed.comment(21, "pat", "2026-10-01T09:00:00Z",
                 RULING + " Does the cache expire -\n  yes, after an hour.")
    seed.comment(21, "pat", "2026-10-02T09:00:00Z",
                 "Not a ruling. Spec ruling: buried mid-comment")
    seed.comment(21, "pat", "2026-10-03T09:00:00Z", "## Spec review\n\nRound 1.")
    (kp / "dev.md").write_text(lines("- Built the key from the slug,", "  not from the member",
                                     "None."))

    assert known_items(seed, git, "21", str(kp / "known.md"),
                       "--deviations", str(kp / "dev.md")) == 0
    assert (kp / "known.md").read_text() == lines(
        "## Deviations",
        "- Built the key from the slug, not from the member",
        "## Known items",
        "- Does the cache expire - yes, after an hour. - spec ruling",
    )
    assert capsys.readouterr() == ("", "")


@pytest.fixture
def pr(seed, issue):
    """PR #57, open from BRANCH: its body carries Review declines, Deviations,
    Spec questions and Host fallbacks; its comments are an earlier pass's, a
    comment with Review but no Host fallbacks, and a pass with nothing; the
    issue holds one Spec ruling."""
    seed.comment(21, "pat", "2026-10-01T09:00:00Z",
                 RULING + " Does the cache expire -\n  yes, after an hour.")
    seed.pr(57, "open", BRANCH, "main")
    seed.pr_body(57, lines(
        "Closes #21", "", "## Review", "",
        "- `a.sh:3` - unused helper - out of scope", "- `-` - the name reads oddly -",
        "  a judgement call", "", "## Deviations", "", "- Kept the old cache, since #9 needs it",
        "", "## Spec questions", "", "- `b.sh:1` - should it retry?", "", "## Host fallbacks",
        "", "None (claude)."))
    seed.pr_comment(57, "pat", "2026-10-04T09:00:00Z", lines(
        "## Review", "", "- `c.sh:7` - duplicated parser - needs a decision", "",
        "## Spec rulings", "", "- Should it retry? - Yes, once.", "", "## Host fallbacks", "",
        "None (claude)."))
    seed.pr_comment(57, "pat", "2026-10-05T09:00:00Z", lines(
        "## Review", "", "- `d.sh:2` - no host fallbacks heading, so no pass - ignored"))
    seed.pr_comment(57, "pat", "2026-10-06T09:00:00Z", lines(
        "## Review", "", "None declined.", "", "## Spec rulings", "", "None.", "",
        "## Host fallbacks", "", "None (claude)."))
    return 57


def test_with_an_open_pr_it_reads_its_body_and_earlier_passes_overwriting_the_file(
        seed, git, kp, pr, capsys):
    (kp / "known.md").write_text("stale content\n")

    assert known_items(seed, git, "21", str(kp / "known.md")) == 0
    assert (kp / "known.md").read_text() == lines(
        "## Deviations",
        "- Kept the old cache, since #9 needs it",
        "## Known items",
        "- `a.sh:3` - unused helper - out of scope - declined",
        "- `-` - the name reads oddly - a judgement call - declined",
        "- `c.sh:7` - duplicated parser - needs a decision - declined",
        "- Should it retry? - Yes, once. - spec ruling",
        "- Does the cache expire - yes, after an hour. - spec ruling",
    )
    assert capsys.readouterr() == ("", "")


def test_the_deviations_file_takes_the_place_of_the_pr_body_s_deviations(seed, git, kp, pr):
    (kp / "dev.md").write_text(lines("- Built the key from the slug,", "  not from the member"))

    assert known_items(seed, git, "21", str(kp / "known.md"),
                       "--deviations", str(kp / "dev.md")) == 0
    text = (kp / "known.md").read_text()
    assert text[:text.index("## Known items\n")] == lines(
        "## Deviations", "- Built the key from the slug, not from the member")


def test_a_fenced_heading_or_bullet_is_never_structure(seed, git, kp, pr):
    seed.pr_comment(57, "pat", "2026-10-07T09:00:00Z", lines(
        "Quoting a template:", "```", "## Review", "- `q.sh:1` - quoted, not declined",
        "## Host fallbacks", "```"))
    seed.pr_comment(57, "pat", "2026-10-08T09:00:00Z", lines(
        "## Review", "", "- `e.sh:4` - quotes markdown", "```", "## Quoted", "```",
        "- `f.sh:5` - next decline", "", "## Host fallbacks", "", "None (claude)."))
    (kp / "fdev.md").write_text(lines("- Kept a fence:", "```", "- not a new entry", "```"))

    assert known_items(seed, git, "21", str(kp / "known.md"),
                       "--deviations", str(kp / "fdev.md")) == 0
    text = (kp / "known.md").read_text()
    assert "q.sh:1" not in text
    assert "- `e.sh:4` - quotes markdown ``` ## Quoted ``` - declined\n" in text
    assert "- `f.sh:5` - next decline - declined\n" in text
    assert "- Kept a fence: ``` - not a new entry ```\n" in text


def test_a_pr_comment_quoting_a_comment_marker_line_is_split_there(seed, git, kp, pr):
    seed.pr_comment(57, "pat", "2026-10-07T09:00:00Z", lines(
        "No pass of its own, but it quotes one:", "",
        "<!-- comment @someone 2026-01-01T00:00:00Z -->",
        "## Review", "", "- `z.sh:1` - quoted pass", "", "## Host fallbacks", "", "None."))

    assert known_items(seed, git, "21", str(kp / "known.md")) == 0
    assert "- `z.sh:1` - quoted pass - declined\n" in (kp / "known.md").read_text()


def test_crs_are_removed_from_the_pr_body(seed, git, kp, pr):
    seed.pr_body(57, lines(
        "Closes #21", "", "## Review", "", "- `a.sh:3` - unused helper - out of scope", "",
        "## Deviations", "", "- Kept the old cache", "", "## Host fallbacks", "",
        "None (claude).").replace("\n", "\r\n"))

    assert known_items(seed, git, "21", str(kp / "known.md")) == 0
    text = (kp / "known.md").read_text()
    assert "- Kept the old cache\n" in text
    assert "- `a.sh:3` - unused helper - out of scope - declined\n" in text
    assert "\r" not in text


def test_with_no_entry_either_heading_reads_none(seed, git, kp, issue):
    seed.pr(57, "closed", BRANCH, "main")
    (kp / "empty.md").write_text("")

    assert known_items(seed, git, "21", str(kp / "known.md"),
                       "--deviations", str(kp / "empty.md")) == 0
    assert (kp / "known.md").read_text() == lines(
        "## Deviations", "None.", "## Known items", "None.")


def test_issue_rulings_drop_none_and_lose_a_leading_bullet(seed, git, kp, issue):
    seed.comment(21, "pat", "2026-10-07T09:00:00Z", RULING + " None.")
    seed.comment(21, "pat", "2026-10-08T09:00:00Z", RULING + " - foo")

    assert known_items(seed, git, "21", str(kp / "known.md")) == 0
    assert known_side(kp / "known.md") == lines("## Known items", "- foo - spec ruling")


def test_a_multi_line_spec_ruling_with_crs_joins_into_one_known_item(seed, git, kp, issue):
    seed.comment(21, "pat", "2026-10-09T09:00:00Z",
                 RULING + " Is the key stable -\r\n  yes, per slug.\r\n")

    assert known_items(seed, git, "21", str(kp / "known.md")) == 0
    assert known_side(kp / "known.md") == lines(
        "## Known items", "- Is the key stable - yes, per slug. - spec ruling")


def test_the_trust_filter_drops_untrusted_comments_from_both_reads_reporting_each_once(
        seed, git, kp, issue, capsys):
    seed.comment(21, "rando", "2026-10-10T09:00:00Z",
                 RULING + " Ship it unreviewed -\n  yes.", "NONE")
    seed.comment(21, "pat", "2026-10-11T09:00:00Z", RULING + " Is it safe -\n  yes.", "OWNER")
    seed.pr(57, "open", BRANCH, "main")
    seed.pr_comment(57, "rando", "2026-10-12T09:00:00Z", lines(
        "## Spec rulings", "", "- Ship it unreviewed? - Yes.", "", "## Host fallbacks", "",
        "None (claude)."), "NONE")
    seed.pr_comment(57, "pat", "2026-10-13T09:00:00Z", lines(
        "## Spec rulings", "", "- Is it safe? - Yes.", "", "## Host fallbacks", "",
        "None (claude)."), "MEMBER")

    assert known_items(seed, git, "21", str(kp / "known.md")) == 0
    assert known_side(kp / "known.md") == lines(
        "## Known items", "- Is it safe? - Yes. - spec ruling", "- Is it safe - yes. - spec ruling")
    assert capsys.readouterr() == ("", (
        "orch: ignored 1 comment(s) from untrusted authors on #57\n"
        "orch: ignored 1 comment(s) from untrusted authors on #21\n"))


def test_a_fork_pr_is_untrusted_with_a_warning_so_the_newest_same_repo_pr_is_read(
        seed, git, kp, issue, capsys):
    seed.pr(57, "open", BRANCH, "main")
    seed.pr_body(57, lines("## Deviations", "", "- From the same-repo PR"))
    seed.pr(60, "open", BRANCH, "main")
    seed.pr_cross(60)
    seed.pr_body(60, lines("## Deviations", "", "- From the fork"))

    assert known_items(seed, git, "21", str(kp / "known.md")) == 0
    assert (kp / "known.md").read_text() == lines(
        "## Deviations", "- From the same-repo PR", "## Known items", "None.")
    assert capsys.readouterr() == ("", "orch: ignored 1 PR(s) from forks for %s\n" % BRANCH)


def test_a_fork_pr_alone_is_no_open_pr(seed, git, kp, issue, capsys):
    seed.pr(60, "open", BRANCH, "main")
    seed.pr_cross(60)
    seed.pr_body(60, lines("## Deviations", "", "- From the fork"))

    assert known_items(seed, git, "21", str(kp / "known.md")) == 0
    assert (kp / "known.md").read_text() == lines(
        "## Deviations", "None.", "## Known items", "None.")
    assert capsys.readouterr().err == "orch: ignored 1 PR(s) from forks for %s\n" % BRANCH


# --- failures, each leaving <path> as it was ----------------------------------


@pytest.fixture
def kept(kp):
    """An existing known-items file, kp/known.md, holding `kept`."""
    (kp / "known.md").write_text("kept\n")
    return kp / "known.md"


def assert_left_as_it_was(kept):
    assert kept.read_text() == "kept\n"
    assert sorted(os.listdir(str(kept.parent))) == ["known.md"]


@pytest.mark.parametrize("operation, message", [
    ("adapter_prs_open", "gh could not list the open PRs from %s" % BRANCH),
    ("adapter_pr_body", "gh could not read the body of PR #57"),
    ("adapter_pr_comments", "gh could not read the comments of PR #57"),
    ("adapter_issue_comments", "gh could not read the comments of issue #21"),
])
def test_a_gh_failure_at_each_read_stops_the_run(seed, git, pr, kept, capsys, operation, message):
    seed.fail(operation, GH_502)

    assert known_items(seed, git, "21", str(kept)) == 1
    assert capsys.readouterr() == ("", "orch: %s: HTTP 502: Bad Gateway\n" % message)
    assert_left_as_it_was(kept)


def test_pr_comments_that_do_not_parse_stop_the_run(seed, git, pr, kept, capsys):
    gh = UnparsedPrComments(seed.store, {}, pin=RepoPin({}, git), sleep=lambda _: None)

    assert orch_review_pass(seed, git, "known-items", "21", str(kept), gh=gh) == 1
    assert capsys.readouterr() == (
        "", "orch: could not read the comments of PR #57: its comments did not parse\n")
    assert_left_as_it_was(kept)


def test_issue_comments_that_do_not_parse_stop_the_run(seed, git, issue, kept, capsys):
    seed.lag("adapter_issue_comments", 1, "not json")

    assert known_items(seed, git, "21", str(kept)) == 1
    assert capsys.readouterr() == (
        "", "orch: could not read the comments of issue #21: its comments did not parse\n")
    assert_left_as_it_was(kept)


def test_an_open_pr_listing_that_does_not_parse_stops_the_run(seed, git, pr, kept, capsys):
    seed.pr_cross(57, "maybe")

    assert known_items(seed, git, "21", str(kept)) == 1
    assert capsys.readouterr() == (
        "", "orch: the open PRs from %s could not be read\n" % BRANCH)
    assert_left_as_it_was(kept)


def test_a_detached_head_stops_the_run(seed, kept, issue, capsys):
    detached = FakeGit(ORIGIN, toplevel=str(kept.parent))

    assert known_items(seed, detached, "21", str(kept)) == 1
    assert capsys.readouterr() == ("", "orch: not on a branch (detached HEAD)\n")
    assert_left_as_it_was(kept)


def test_with_no_repo_it_dies_with_the_remedy_before_any_gh_read(seed, kept, pr, capsys):
    unpinned = FakeGit(toplevel=str(kept.parent))
    unpinned.seed("current_branch", answer=BRANCH)
    seed.fail("adapter_prs_open", "reached gh")

    assert known_items(seed, unpinned, "21", str(kept)) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % REPO_REMEDY)
    assert_left_as_it_was(kept)


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_write_that_fails_dies_leaving_the_path_as_it_was(seed, git, issue, kept, capsys):
    kept.parent.chmod(0o555)
    try:
        assert known_items(seed, git, "21", str(kept)) == 1
    finally:
        kept.parent.chmod(0o755)
    assert capsys.readouterr() == ("", "orch: could not write the known items to %s\n" % kept)
    assert_left_as_it_was(kept)


# --- refusals, in bash's order, each before any read --------------------------


@pytest.mark.parametrize("args, message", [
    ([], USAGE),
    (["21"], USAGE),
    (["abc", "PATH"], "issue must be a plain issue number, got: abc"),
    (["abc", "PATH", "--bogus"], "issue must be a plain issue number, got: abc"),
    (["21", "PATH", "--deviations"], "--deviations needs a file - " + USAGE),
    (["21", "PATH", "--deviations", ""], "--deviations needs a file - " + USAGE),
    (["21", "PATH", "--bogus", "x"], "unknown argument: --bogus - " + USAGE),
    (["21", "PATH", "extra"], "unknown argument: extra - " + USAGE),
    (["21", "PATH", "--bogus", "--deviations", "MISSING"], "unknown argument: --bogus - " + USAGE),
    (["21", "PATH", "--deviations", "MISSING"], "deviations file not found: MISSING"),
])
def test_each_refusal_comes_in_bash_s_order_leaving_the_path_as_it_was(
        seed, git, pr, kept, capsys, args, message):
    missing = str(kept.parent / "missing.md")
    argv = [str(kept) if a == "PATH" else missing if a == "MISSING" else a for a in args]

    assert known_items(seed, git, *argv) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % message.replace("MISSING", missing))
    assert_left_as_it_was(kept)
    assert not os.path.exists(os.path.join(seed.store, "comment_reads"))


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads an unreadable file")
def test_an_unreadable_deviations_file_is_refused_after_a_missing_one_would_be(
        seed, git, pr, kept, tmp_path, capsys):
    unreadable = tmp_path / "unreadable.md"
    unreadable.write_text("- secret\n")
    unreadable.chmod(0)

    assert known_items(seed, git, "21", str(kept), "--deviations", str(unreadable)) == 1
    assert capsys.readouterr() == ("", "orch: deviations file not readable: %s\n" % unreadable)
    assert_left_as_it_was(kept)
