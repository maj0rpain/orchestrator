"""The ticket noun's entry, run in-process in a FakeGit checkout under
tmp_path against the gh fake on a tmp_path store - the cases of the bash
ticket sections for the verbs the Python noun takes: the verb dispatch and
its unknown-op refusal, every usage line, `publish` (its argument checks
before any write, the second --blocked-by refusal, the verify-then-die arms
and the `## Blocked by` rewrite), `next` and `list` ordering, `report save`
and `report show` in bash's layout, `parent`, and the verbs already in
Python - `exists` (the no-repo exit 2, #3050), `block`, `unblock`, `retire`
(the save point and the untrusted comments, #334) and `reset` - through the
entry, where test_ticket.py's function-level cases do not already reach
them; and the refuse_open_tickets bridge pr open and pr publish call."""
from __future__ import annotations

import os
from pathlib import Path

import pytest

from conftest import (AUTOPILOT, CLAUDE, GH_502, blockers_of, comments_of, died_of, fake,
                      labels_of, read, snapshot)
from orch import ticket
from orch.git import FakeGit
from orch.repo import REPO_REMEDY

# A report as bash's `ticket report save 4152` wrote it, byte for byte - a
# non-UTF-8 byte included - copied verbatim from .orchestrator/reports/.
BASH_REPORT = Path(__file__).resolve().parent / "ticket_report" / "4152.md"

OPS = "publish|next|list|close|reset|parent|exists|retire|report|block|unblock|merge|reclaim"


def orch_ticket(root, seed, *argv, env=None, gh=None, git=None):
    """`orch.sh ticket <argv>` in-process in the checkout at <root>, on
    <seed>'s store unless <gh> is given, under <env> (Claude Code's plain
    session when None): its exit code."""
    return ticket.run(list(argv), gh=fake(seed) if gh is None else gh,
                      git=FakeGit(toplevel=str(root)) if git is None else git,
                      env=CLAUDE if env is None else env)


# --- the dispatch -------------------------------------------------------------------


@pytest.mark.parametrize("argv, shown", [((), "<none>"), (("bogus",), "bogus"), (("",), "<none>")])
def test_an_unknown_op_is_refused_naming_every_op(root, seed, capsys, argv, shown):
    seed.offline()

    assert died_of(capsys, lambda: orch_ticket(root, seed, *argv)) == (
        1, "", "orch: unknown ticket op: %s (want %s)\n" % (shown, OPS))


# --- ticket next and ticket list -----------------------------------------------------


@pytest.fixture
def published(seed):
    """#90's breakdown in the order GitHub published it: open #452, open
    #450 blocked by open #451, closed #453 and open #454, blocked by closed
    #453 alone."""
    for n in (90, 450, 451, 452, 453, 454):
        seed.issue(n, "open")
    seed.issue(453, "closed")
    for n in (452, 450, 451, 453, 454):
        seed.sub_issue(90, n)
    seed.blocked_by(450, 451)
    seed.blocked_by(454, 453)


@pytest.mark.parametrize("env", [CLAUDE, AUTOPILOT], ids=["plain", "autopilot"])
def test_next_prints_the_open_unblocked_tickets_in_publish_order(root, seed, capsys, published,
                                                                 env):
    assert orch_ticket(root, seed, "next", "90", env=env) == 0

    assert capsys.readouterr() == ("452\n451\n454\n", "")


def test_list_prints_every_sub_issue_with_its_state_in_publish_order(root, seed, capsys,
                                                                     published):
    seed.issue(91, "open")

    assert orch_ticket(root, seed, "list", "90") == 0
    assert orch_ticket(root, seed, "list", "91") == 0

    assert capsys.readouterr() == ("452 open\n450 open\n451 open\n453 closed\n454 open\n", "")


@pytest.mark.parametrize("verb", ["next", "list"])
@pytest.mark.parametrize("parent", ["abc", ""])
def test_next_and_list_refuse_a_parent_that_is_no_plain_number(root, seed, capsys, verb, parent):
    seed.offline()

    assert died_of(capsys, lambda: orch_ticket(root, seed, verb, parent)) == (
        1, "", "orch: parent must be a plain issue number, got: %s\n" % parent)


@pytest.mark.parametrize("verb", ["next", "list"])
def test_next_and_list_die_when_github_cannot_list_the_sub_issues(root, seed, capsys, published,
                                                                  verb):
    seed.fail("adapter_sub_issues", GH_502)

    assert died_of(capsys, lambda: orch_ticket(root, seed, verb, "90")) == (
        1, "", "orch: gh could not list sub-issues of #90: HTTP 502: Bad Gateway\n")


# --- ticket parent --------------------------------------------------------------------


@pytest.mark.parametrize("n, printed", [("700", "95\n"), ("95", "")])
def test_parent_prints_the_parent_or_nothing_for_no_sub_issue(root, seed, capsys, n, printed):
    seed.issue(95, "open")
    seed.issue(700, "open")
    seed.sub_issue(95, 700)

    assert orch_ticket(root, seed, "parent", n) == 0

    assert capsys.readouterr() == (printed, "")


@pytest.mark.parametrize("stderr, reason", [(None, "fake gh: adapter_issue_parent failed"),
                                            (GH_502, "HTTP 502: Bad Gateway")])
def test_a_parent_github_cannot_read_dies_printing_nothing(root, seed, capsys, stderr, reason):
    seed.issue(700, "open")
    seed.fail("adapter_issue_parent", stderr)

    assert died_of(capsys, lambda: orch_ticket(root, seed, "parent", "700")) == (
        1, "", "orch: gh could not read issue #700's parent: %s\n" % reason)


def test_parent_refuses_a_ticket_that_is_no_plain_number(root, seed, capsys):
    seed.offline()

    assert died_of(capsys, lambda: orch_ticket(root, seed, "parent", "abc")) == (
        1, "", "orch: not a plain issue number: abc\n")


# --- ticket report --------------------------------------------------------------------


def saved_report(root, n):
    """The path of ticket <n>'s saved report under the checkout at <root>, a
    Path."""
    return root / ".orchestrator" / "reports" / ("%s.md" % n)


def test_a_saved_report_shows_byte_for_byte_and_a_resave_replaces_it(root, seed,
                                                                       capsysbinary, tmp_path):
    seed.offline()
    report = tmp_path / "report.md"
    report.write_bytes(b"Ticket: #1\n")
    assert orch_ticket(root, seed, "report", "save", "700", str(report)) == 0
    report.write_bytes(b"Ticket: #2\ncaf\xc3\xa9 \xff")
    assert orch_ticket(root, seed, "report", "save", "700", str(report)) == 0
    assert capsysbinary.readouterr() == (b"", b"")

    assert orch_ticket(root, seed, "report", "show", "700") == 0

    assert capsysbinary.readouterr() == (b"Ticket: #2\ncaf\xc3\xa9 \xff", b"")
    assert sorted(p.name for p in saved_report(root, 700).parent.iterdir()) == ["700.md"]


def test_a_report_bash_saved_reads_back_through_show(root, seed, capsysbinary):
    seed.offline()
    saved_report(root, 4152).parent.mkdir(parents=True)
    saved_report(root, 4152).write_bytes(BASH_REPORT.read_bytes())

    assert orch_ticket(root, seed, "report", "show", "4152") == 0

    assert capsysbinary.readouterr() == (BASH_REPORT.read_bytes(), b"")


def test_show_with_no_report_saved_dies(root, seed, capsys):
    seed.offline()

    assert died_of(capsys, lambda: orch_ticket(root, seed, "report", "show", "700")) == (
        1, "", "orch: no saved report for ticket #700\n")


@pytest.mark.parametrize("name, content", [("missing.md", None), ("empty.md", b"")])
def test_a_missing_or_empty_report_file_is_refused_writing_nothing(root, seed, capsys, tmp_path,
                                                                  name, content):
    seed.offline()
    saved_report(root, 700).parent.mkdir(parents=True)
    saved_report(root, 700).write_bytes(b"kept\n")
    report = tmp_path / name
    if content is not None:
        report.write_bytes(content)

    assert died_of(capsys, lambda: orch_ticket(root, seed, "report", "save", "700",
                                               str(report))) == (
        1, "", "orch: report file %s is missing or empty - nothing saved\n" % report)
    assert saved_report(root, 700).read_bytes() == b"kept\n"
    assert not saved_report(root, 701).exists()


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_report_that_cannot_be_saved_dies_naming_the_ticket(root, seed, capsys, tmp_path):
    seed.offline()
    report = tmp_path / "report.md"
    report.write_text("R\n")
    reports = saved_report(root, 700).parent
    reports.mkdir(parents=True)
    reports.chmod(0o555)
    try:
        assert died_of(capsys, lambda: orch_ticket(root, seed, "report", "save", "700",
                                                   str(report))) == (
            1, "", "orch: could not save ticket #700's report\n")
    finally:
        reports.chmod(0o755)
    assert list(reports.iterdir()) == []


def test_a_reports_folder_that_cannot_be_made_dies_naming_it(root, seed, capsys, tmp_path):
    seed.offline()
    report = tmp_path / "report.md"
    report.write_text("R\n")
    (root / ".orchestrator").write_text("a file, not a folder\n")

    assert died_of(capsys, lambda: orch_ticket(root, seed, "report", "save", "700",
                                               str(report))) == (
        1, "", "orch: could not create %s/.orchestrator/reports\n" % root)


@pytest.mark.parametrize("argv", [("save", "x1", "f"), ("save", "", "f"), ("show", "x1")])
def test_report_refuses_a_ticket_that_is_no_plain_number(root, seed, capsys, argv):
    seed.offline()

    assert died_of(capsys, lambda: orch_ticket(root, seed, "report", *argv)) == (
        1, "", "orch: not a plain issue number: %s\n" % argv[1])


# --- ticket publish -------------------------------------------------------------------

PUBLISH_USAGE = ("usage: orch.sh ticket publish <parent> <title> <body-file>"
                 " [--blocked-by N,N,...]")
UNBLOCKED = "Build the thing.\n\n## Blocked by\n\nNone (can start immediately)\n"


@pytest.fixture
def body(tmp_path):
    """A ticket body file reading "Build the thing.": its path, a str."""
    path = tmp_path / "body.md"
    path.write_text("Build the thing.\n")
    return str(path)


@pytest.fixture
def parent(seed):
    """Open #50, the parent the tickets publish under, its next new issue
    #100."""
    seed.issue(50, "open")
    seed.next_issue(100)


def test_publish_creates_labels_links_and_prints_the_new_ticket(root, seed, store, capsys, body,
                                                               parent):
    assert orch_ticket(root, seed, "publish", "50", "First ticket", body) == 0

    assert capsys.readouterr() == ("100\n", "")
    assert read(store, "issues", 100, "title") == "First ticket\n"
    assert read(store, "issues", 100, "body") == UNBLOCKED
    assert labels_of(store, 100) == ["ready-for-agent"]
    assert read(store, "subs", 50) == "100\n"
    assert not (root / ".orchestrator").exists()


def test_publish_adds_each_blocking_edge_once_and_lists_them_ascending(root, seed, store, capsys,
                                                                       body, parent):
    for title in ("A", "B"):
        orch_ticket(root, seed, "publish", "50", title, body)

    assert orch_ticket(root, seed, "publish", "50", "C", body, "--blocked-by", "101,100,101") == 0

    assert capsys.readouterr() == ("100\n101\n102\n", "")
    assert blockers_of(store, 102) == ["100", "101"]
    assert read(store, "issues", 102, "body") == (
        "Build the thing.\n\n## Blocked by\n\n- #100\n- #101\n")


def test_publish_with_an_empty_blocked_by_publishes_unblocked(root, seed, store, capsys, body,
                                                              parent):
    assert orch_ticket(root, seed, "publish", "50", "Unblocked", body, "--blocked-by", "") == 0

    assert capsys.readouterr() == ("100\n", "")
    assert blockers_of(store, 100) == []


@pytest.mark.parametrize("argv, message", [
    (("50", "", "{body}"), "the title is empty"),
    (("50", "Title", "/nonexistent/body.md"), "body file not found: /nonexistent/body.md"),
    (("abc", "Title", "{body}"), "parent must be a plain issue number, got: abc"),
    (("50", "Title", "{body}", "--blocked-by", "abc,5"),
     "--blocked-by must be plain issue numbers, got: abc,5"),
    (("50", "Title", "{body}", "--blocked-by", "1,,2"),
     "--blocked-by must be plain issue numbers, got: 1,,2"),
    (("50", "Title", "{body}", "--blocked-by", ",5"),
     "--blocked-by must be plain issue numbers, got: ,5"),
    (("50", "Title", "{body}", "--blocked-by", "5,"),
     "--blocked-by must be plain issue numbers, got: 5,"),
    (("50", "Title", "{body}", "--blocked-by", "5\n"),
     "--blocked-by must be plain issue numbers, got: 5\n"),
    # A second --blocked-by is refused, never allowed to replace the first.
    (("50", "Title", "{body}", "--blocked-by", "100", "--blocked-by", ""), PUBLISH_USAGE),
    (("50", "Title", "{body}", "--blocked-by", "", "--blocked-by", "100"), PUBLISH_USAGE),
    (("50", "Title", "{body}", "--blocked-by"), PUBLISH_USAGE),
    (("50", "Title", "{body}", "--bogus"), PUBLISH_USAGE),
    (("50", "Third", "{body}", "--record", "/tmp/x", "3"), PUBLISH_USAGE),
    (("50", "Title"), PUBLISH_USAGE),
    ((), PUBLISH_USAGE),
])
def test_publish_refuses_bad_arguments_before_any_write(root, seed, store, capsys, body, parent,
                                                        argv, message):
    before = snapshot(store)

    assert died_of(capsys, lambda: orch_ticket(
        root, seed, "publish", *(arg.format(body=body) for arg in argv))) == (
        1, "", "orch: %s\n" % message)
    assert snapshot(store) == before


@pytest.mark.parametrize("operation, blocked, message", [
    ("adapter_issue_create", (), "gh could not create the ticket: HTTP 502: Bad Gateway"),
    ("adapter_sub_issues", (), "gh could not list sub-issues of #50: HTTP 502: Bad Gateway"),
    ("adapter_sub_issue_link", (),
     "gh could not link ticket #100 as a sub-issue of #50: HTTP 502: Bad Gateway"),
    ("adapter_blocker_add", ("--blocked-by", "99"),
     "gh could not add a blocking edge from ticket #100 on #99: HTTP 502: Bad Gateway"),
])
def test_a_publish_github_fails_dies_naming_the_step(root, seed, capsys, body, parent, operation,
                                                     blocked, message):
    seed.issue(99, "open")
    seed.sub_issue(50, 99)
    seed.fail(operation, GH_502)

    assert died_of(capsys, lambda: orch_ticket(root, seed, "publish", "50", "T", body,
                                               *blocked)) == (1, "", "orch: %s\n" % message)


def test_a_failed_pre_link_listing_leaves_the_ticket_created_and_unlinked(root, seed, store,
                                                                         capsys, body, parent):
    seed.fail("adapter_sub_issues")

    died_of(capsys, lambda: orch_ticket(root, seed, "publish", "50", "Third", body))

    assert (read(store, "issues", 100, "title"), read(store, "subs", 50)) == ("Third\n", None)


# --- ticket publish verify-then-die -----------------------------------------------------
# ticket_link reads the links back (ADR-0011): one retry on a mismatch or a
# failed read, the second attempt deciding the death. A lag makes a read-back
# answer stale (empty) for its count.


def fail_times_after(seed, operation, after, times, stderr):
    """The store's <operation> failing <times> times with <stderr>, but only
    once <after> calls of it have answered."""
    seed.fail_times(operation, times, stderr)
    with open(os.path.join(seed.store, "fail", operation + ".after"), "w") as f:
        f.write("%d\n" % after)


def blocker(seed):
    """Open #99, a sibling under #50 the tickets publish blocked by."""
    seed.issue(99, "open")
    seed.sub_issue(50, 99)


@pytest.mark.parametrize("arm", [
    lambda seed: seed.lag("adapter_sub_issues", 2),
    lambda seed: fail_times_after(seed, "adapter_sub_issues", 1, 1, GH_502),
    lambda seed: (blocker(seed), fail_times_after(seed, "adapter_blockers", 1, 1, GH_502)),
], ids=["stale-once", "sub-issues-failed-once", "blockers-failed-once"])
def test_a_link_read_back_wrong_once_is_retried_and_publishes(root, seed, store, capsys, body,
                                                              parent, arm):
    blocked = ("--blocked-by", "99") if arm(seed) else ()

    assert orch_ticket(root, seed, "publish", "50", "T", body, *blocked) == 0

    assert capsys.readouterr() == ("100\n", "")
    assert "100" in read(store, "subs", 50).split()


NOT_VERIFIED = ("ticket #100's sub-issue/blocked-by links did not verify - checked twice, both"
                " failed")


@pytest.mark.parametrize("arm, blocked, message", [
    # The pre-link read, then both read-backs.
    (lambda seed: seed.lag("adapter_sub_issues", 3), (), NOT_VERIFIED),
    # The pre-add read, then both read-backs.
    (lambda seed: seed.lag("adapter_blockers", 3), ("--blocked-by", "99"), NOT_VERIFIED),
    (lambda seed: seed.fail_after("adapter_blockers", 1), ("--blocked-by", "99"),
     "gh could not read ticket #100's links: fake gh: adapter_blockers failed"),
    (lambda seed: seed.fail_after("adapter_sub_issues", 1, GH_502), (),
     "gh could not read ticket #100's links: HTTP 502: Bad Gateway"),
    (lambda seed: seed.fail_after("adapter_blockers", 1, GH_502), ("--blocked-by", "99"),
     "gh could not read ticket #100's links: HTTP 502: Bad Gateway"),
    (lambda seed: seed.fail_after("adapter_sub_issues", 1, ""), (),
     "gh could not read ticket #100's links: gh gave no reason"),
    # A failed read, then a mismatch: the mismatch decides.
    (lambda seed: (fail_times_after(seed, "adapter_sub_issues", 1, 1, GH_502),
                   seed.lag("adapter_sub_issues", 2)), (), NOT_VERIFIED),
    # A mismatch, then a failed read: the failed read decides.
    (lambda seed: (seed.lag("adapter_sub_issues", 2),
                   seed.fail_after("adapter_sub_issues", 2, GH_502)), (),
     "gh could not read ticket #100's links: HTTP 502: Bad Gateway"),
], ids=["links-stale", "blockers-stale", "blockers-failed", "links-failed-502",
        "blockers-failed-502", "links-failed-silent", "failed-then-stale", "stale-then-failed"])
def test_links_that_do_not_read_back_twice_die_leaving_the_draft(root, seed, store, capsys, body,
                                                                 parent, arm, blocked, message):
    blocker(seed)
    arm(seed)

    assert died_of(capsys, lambda: orch_ticket(root, seed, "publish", "50", "T", body,
                                               *blocked)) == (1, "", "orch: %s\n" % message)
    seed.unfail()
    assert read(store, "issues", 100, "body") == "Build the thing.\n"
    assert read(store, "subs", 50) == "99\n100\n"


# --- ticket publish rewrites ## Blocked by (#3115) ------------------------------------


def test_publish_rewrites_the_draft_s_blocked_by_section_from_the_verified_edges(
        root, seed, store, capsys, tmp_path, parent):
    draft = tmp_path / "draft.md"
    draft.write_text("Intro.\n\n## Blocked by\n\nNone (can start immediately)")
    for title in ("A", "B"):
        orch_ticket(root, seed, "publish", "50", title, str(draft))

    orch_ticket(root, seed, "publish", "50", "C", str(draft), "--blocked-by", "101,100")

    assert capsys.readouterr() == ("100\n101\n102\n", "")
    # No blockers: the draft's section already reads None, so no body is written.
    assert read(store, "issues", 100, "body") == (
        "Intro.\n\n## Blocked by\n\nNone (can start immediately)")
    assert read(store, "issues", 102, "body") == "Intro.\n\n## Blocked by\n\n- #100\n- #101\n"


def test_a_failed_rewrite_dies_leaving_the_ticket_linked_with_its_edge(root, seed, store, capsys,
                                                                       body, parent):
    blocker(seed)
    seed.fail("adapter_issue_body_edit", GH_502)

    assert died_of(capsys, lambda: orch_ticket(root, seed, "publish", "50", "E", body,
                                               "--blocked-by", "99")) == (
        1, "", "orch: gh could not rewrite ticket #100's ## Blocked by section:"
               " HTTP 502: Bad Gateway\n")
    assert (read(store, "subs", 50), blockers_of(store, 100)) == ("99\n100\n", ["99"])
    assert read(store, "issues", 100, "body") == "Build the thing.\n"


# --- ticket exists ----------------------------------------------------------------------


@pytest.mark.parametrize("parent, code, printed", [
    ("96", 0, "sub-issues\n"), ("98", 0, "collapsed\n"), ("99", 1, "")])
def test_exists_prints_the_breakdown_s_kind_or_exits_1_for_none(root, seed, capsys, parent, code,
                                                                printed):
    for n in (96, 98, 99, 800):
        seed.issue(n, "open")
    seed.sub_issue(96, 800)
    seed.body(98, "The spec.\n\n## Ticket\n\nBuild it.\n")
    seed.body(99, "The spec, no breakdown yet.")

    assert orch_ticket(root, seed, "exists", parent) == code

    assert capsys.readouterr() == (printed, "")


@pytest.mark.parametrize("argv", [(), ("1", "2")])
def test_exists_refuses_a_parent_count_but_one_with_2(root, seed, capsys, argv):
    seed.offline()

    assert died_of(capsys, lambda: orch_ticket(root, seed, "exists", *argv)) == (
        2, "", "orch: usage: orch.sh ticket exists <parent>\n")


def no_repo(root, seed, *argv):
    """`orch.sh ticket <argv>` in a checkout with no origin and no GH_REPO,
    the gh fake on <seed>'s store made by the noun itself, which pins it to
    no repo: its exit code."""
    return ticket.run(list(argv), git=FakeGit(toplevel=str(root)),
                      env=dict(CLAUDE, ORCH_GH_FAKE_STORE=seed.store))


@pytest.mark.parametrize("argv, message", [
    (("50",), REPO_REMEDY),
    ((), "usage: orch.sh ticket exists <parent>"),
    (("abc",), "parent must be a plain issue number, got: abc"),
])
def test_exists_with_no_repo_exits_2_and_a_refusal_wins_over_the_remedy(root, seed, capsys, argv,
                                                                        message):
    # Offline: a gh call would die with another message.
    seed.offline()

    assert died_of(capsys, lambda: no_repo(root, seed, "exists", *argv)) == (
        2, "", "orch: %s\n" % message)


# --- ticket block and ticket unblock ----------------------------------------------------


@pytest.fixture
def siblings(seed):
    """#96's open tickets #801 and #802, #802 blocked by #801, each body
    reading UNBLOCKED's text."""
    seed.issue(96, "open")
    for n in (801, 802, 803):
        seed.issue(n, "open")
        seed.body(n, UNBLOCKED)
        seed.sub_issue(96, n)
    seed.blocked_by(802, 801)


def test_block_and_unblock_change_the_edges_printing_nothing(root, seed, store, capsys, siblings):
    assert orch_ticket(root, seed, "block", "803", "--by", "802,801") == 0
    assert orch_ticket(root, seed, "unblock", "--by", "801", "803") == 0

    assert capsys.readouterr() == ("", "")
    assert blockers_of(store, 803) == ["802"]
    assert read(store, "issues", 803, "body") == "Build the thing.\n\n## Blocked by\n\n- #802\n"


@pytest.mark.parametrize("verb", ["block", "unblock"])
@pytest.mark.parametrize("argv", [
    ("803",),
    ("--by", "801"),
    ("803", "--by", "801", "--by", "802"),
    ("803", "--by"),
    ("803", "--by", "801", "-x"),
    ("803", "804", "--by", "801"),
    ("", "--by", "801"),
    (),
])
def test_an_edge_change_s_bad_arguments_are_refused_with_its_usage_before_any_write(
        root, seed, store, capsys, siblings, verb, argv):
    before = snapshot(store)

    assert died_of(capsys, lambda: orch_ticket(root, seed, verb, *argv)) == (
        1, "", "orch: usage: orch.sh ticket %s <n> --by N,N,...\n" % verb)
    assert snapshot(store) == before


@pytest.mark.parametrize("verb", ["block", "unblock"])
def test_an_edge_change_s_empty_by_is_refused_as_nothing(root, seed, store, capsys, siblings,
                                                        verb):
    assert died_of(capsys, lambda: orch_ticket(root, seed, verb, "803", "--by", "")) == (
        1, "", "orch: --by must be plain issue numbers, got nothing\n")


# --- ticket retire ----------------------------------------------------------------------


def test_retire_removes_the_parent_s_save_point_and_report_keeping_another_s(root, seed, capsys):
    seed.issue(50, "open")
    for folder in ("breakdown/50", "breakdown/51", "reports"):
        (root / ".orchestrator" / folder).mkdir(parents=True)
    for name in ("breakdown/50/draft.md", "breakdown/51/draft.md", "reports/50.md"):
        (root / ".orchestrator" / name).write_text("x\n")

    assert orch_ticket(root, seed, "retire", "50") == 0

    assert capsys.readouterr() == ("", "")
    assert sorted(p.relative_to(root / ".orchestrator").as_posix()
                  for p in (root / ".orchestrator").rglob("*")) == [
        "breakdown", "breakdown/51", "breakdown/51/draft.md", "reports"]


def test_retire_ignores_a_stranger_s_copy_of_the_retire_comment(root, seed, store, capsys):
    message = ("This ticket was retired: its spec, #70, changed and will be broken down into"
               " tickets again.")
    seed.issue(70, "open")
    seed.issue(700, "closed")
    seed.sub_issue(70, 700)
    seed.comment(700, "rando", "2026-09-05T09:00:00Z", message, "NONE")

    assert orch_ticket(root, seed, "retire", "70") == 0

    assert capsys.readouterr() == (
        "", "orch: ignored 1 comment(s) from untrusted authors on #700\n")
    assert comments_of(store, 700) == [message, message + "\n"]


# --- ticket reset -----------------------------------------------------------------------


def test_reset_through_the_noun_reopens_the_closed_and_drops_their_reports(root, seed, store,
                                                                          capsys):
    seed.issue(90, "open")
    for n, state in ((600, "closed"), (601, "closed"), (602, "open")):
        seed.issue(n, state)
        seed.sub_issue(90, n)
    saved_report(root, 90).parent.mkdir(parents=True)
    for n in (90, 600, 602):
        saved_report(root, n).write_text("R\n")

    assert orch_ticket(root, seed, "reset", "90") == 0

    assert capsys.readouterr() == ("", "")
    assert [read(store, "issues", n, "state") for n in (600, 601, 602)] == ["OPEN\n"] * 3
    assert sorted(p.name for p in saved_report(root, 90).parent.iterdir()) == ["602.md"]


# --- usage lines ------------------------------------------------------------------------


@pytest.mark.parametrize("argv, usage", [
    (("next",), "usage: orch.sh ticket next <parent>"),
    (("next", "90", "91"), "usage: orch.sh ticket next <parent>"),
    (("list",), "usage: orch.sh ticket list <parent>"),
    (("list", "90", "91"), "usage: orch.sh ticket list <parent>"),
    (("parent",), "usage: orch.sh ticket parent <n>"),
    (("parent", "1", "2"), "usage: orch.sh ticket parent <n>"),
    (("reset",), "usage: orch.sh ticket reset <parent>"),
    (("reset", "90", "91"), "usage: orch.sh ticket reset <parent>"),
    (("retire",), "usage: orch.sh ticket retire <parent>"),
    (("retire", "90", "91"), "usage: orch.sh ticket retire <parent>"),
    (("report",), "usage: orch.sh ticket report save <n> <file> | show <n>"),
    (("report", "bogus", "1"), "usage: orch.sh ticket report save <n> <file> | show <n>"),
    (("report", "save", "1"), "usage: orch.sh ticket report save <n> <file> | show <n>"),
    (("report", "save", "1", "f", "g"), "usage: orch.sh ticket report save <n> <file> | show <n>"),
    (("report", "show"), "usage: orch.sh ticket report save <n> <file> | show <n>"),
    (("report", "show", "1", "2"), "usage: orch.sh ticket report save <n> <file> | show <n>"),
])
def test_each_verb_refuses_a_wrong_argument_count_with_its_usage_line(root, seed, capsys, argv,
                                                                      usage):
    seed.offline()

    assert died_of(capsys, lambda: orch_ticket(root, seed, *argv)) == (
        1, "", "orch: %s\n" % usage)


# --- the refuse_open_tickets bridge -----------------------------------------------------


@pytest.fixture
def spec_with_tickets(seed):
    """Spec #40's breakdown: open #41, closed #42 and open #43, blocked by
    #41."""
    seed.issue(40, "open")
    for n, state in ((41, "open"), (42, "closed"), (43, "open")):
        seed.issue(n, state)
        seed.sub_issue(40, n)
    seed.blocked_by(43, 41)


def bridge(monkeypatch, seed, *args):
    """`orch_python_call --as pr ticket refuse_open_tickets <args>` as
    orch.__main__ hands it to call_func, on <seed>'s store pinned to
    acme/widgets: its exit code."""
    from orch import cli

    monkeypatch.setenv("ORCH_GH_FAKE_STORE", seed.store)
    monkeypatch.setenv("GH_REPO", "acme/widgets")
    return cli.call_func(["ticket", "refuse_open_tickets", *args])


def test_the_bridge_refuses_a_spec_with_open_tickets_naming_them(monkeypatch, seed, capsys,
                                                                 spec_with_tickets):
    assert died_of(capsys, lambda: bridge(monkeypatch, seed, "40", "pr open")) == (
        1, "", "orch: #40 still has open tickets: #41 #43 - run the driver loop (orch.sh ticket"
               " next 40) or close them, then run pr open again\n")


def test_the_bridge_passes_a_spec_whose_tickets_are_all_closed(monkeypatch, seed, capsys,
                                                               spec_with_tickets):
    seed.issue(41, "closed")
    seed.issue(43, "closed")

    assert bridge(monkeypatch, seed, "40", "pr publish") == 0

    assert capsys.readouterr() == ("", "")


@pytest.mark.parametrize("args", [(), ("40",), ("40", "pr open", "x")])
def test_the_bridge_refuses_an_argument_count_but_two_with_its_usage(monkeypatch, seed, capsys,
                                                                     args):
    seed.offline()

    assert died_of(capsys, lambda: bridge(monkeypatch, seed, *args)) == (
        1, "", "orch: usage: orch_python_call ticket refuse_open_tickets <issue> <command>\n")


def test_next_never_reads_a_ticket_with_no_dependency_summary_as_unblocked(root, seed, capsys,
                                                                           published):
    # GitHub's answer for #90, #454 with its open-blocker count left empty.
    seed.lag("adapter_sub_issues", 1, "452\tOPEN\t0\n454\tOPEN\t")

    assert orch_ticket(root, seed, "next", "90") == 0

    assert capsys.readouterr() == ("452\n", "")
