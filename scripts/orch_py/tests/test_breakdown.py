"""The breakdown noun run in-process against the gh adapter's fake on a
tmp_path store and a FakeGit checkout under tmp_path: breakdown publish - the
draft's parse and publishing order with bash's messages, the tickets created,
linked, blocked and verified, the save point a resume reads, bash's layout
included, and every death on and off GitHub - and breakdown state, read from
the save point and GitHub, with both verbs' argument refusals and the unknown
op's - each checked by its stdout, its exit code and its `orch:` message, as
the bash breakdown noun answered, and by the store and save point it left."""
from __future__ import annotations

import os
from pathlib import Path

import pytest

from conftest import (GH_502, blockers_of, died_of, labels_doc, labels_of, read, snapshot,
                      write_labels_doc)
from orch import breakdown, cli
from orch.gh_fake import FakeGh
from orch.git import FakeGit
from orch.repo import REPO_REMEDY, RepoPin

# The checkout's origin: a GitHub repo, so the Repo resolves.
ORIGIN = {"origin": "https://github.com/o/r.git"}


def orch_breakdown(root, seed, *argv, remotes=ORIGIN, fake_gh=FakeGh):
    """`orch.sh breakdown <argv>` in-process, in the checkout at <root> with
    <remotes> as its remotes, with the gh fake - a <fake_gh> - on <seed>'s
    store pinned to that checkout's origin: its exit code, a SystemExit's
    included."""
    git = FakeGit(remotes, toplevel=str(root))
    pin = RepoPin({}, git)
    gh = fake_gh(seed.store, {}, pin=pin, sleep=lambda _: None)
    try:
        return breakdown.run(list(argv), gh=gh, git=git, env={}, pin=pin)
    except SystemExit as died:
        return died.code


def save_point(root, parent, *names):
    """Spec issue <parent>'s save point under <root>, holding an empty file
    for each of <names>."""
    directory = root / ".orchestrator" / "breakdown" / str(parent)
    directory.mkdir(parents=True)
    for name in names:
        (directory / name).write_text("")
    return directory


# --- breakdown state ----------------------------------------------------------


def test_a_spec_with_no_saved_draft_and_no_tickets_has_no_breakdown(root, seed, capsys):
    seed.issue(50, "open")

    assert orch_breakdown(root, seed, "state", "50") == 0
    assert capsys.readouterr() == ("none\n", "")


def test_a_spec_with_no_saved_draft_whose_tickets_exist_is_complete(root, seed, capsys):
    seed.issue(50, "open")
    seed.issue(60, "open")
    seed.sub_issue(50, 60)

    assert orch_breakdown(root, seed, "state", "50") == 0
    assert capsys.readouterr() == ("complete\n", "")


def test_a_collapsed_breakdown_with_no_saved_draft_is_complete(root, seed, capsys):
    seed.issue(50, "open")
    seed.body(50, "The spec.\n\n## Ticket\n\nBuild it.\n")

    assert orch_breakdown(root, seed, "state", "50") == 0
    assert capsys.readouterr() == ("complete\n", "")


def test_a_saved_draft_with_no_published_marker_is_partial(root, seed, capsys):
    save_point(root, 50, "draft.md")
    seed.offline()

    assert orch_breakdown(root, seed, "state", "50") == 0
    assert capsys.readouterr() == ("partial\n", "")


def test_the_published_marker_is_complete(root, seed, capsys):
    save_point(root, 50, "draft.md", "published")
    seed.offline()

    assert orch_breakdown(root, seed, "state", "50") == 0
    assert capsys.readouterr() == ("complete\n", "")


@pytest.mark.parametrize("operation, message", [
    ("adapter_sub_issues", "orch: gh could not list sub-issues of #50: HTTP 502: Bad Gateway\n"),
    ("adapter_issue_body", "orch: gh could not read issue #50's body: HTTP 502: Bad Gateway\n"),
])
def test_a_github_state_cannot_read_exits_2_never_none(root, seed, capsys, operation, message):
    seed.issue(50, "open")
    seed.fail(operation, GH_502)

    assert orch_breakdown(root, seed, "state", "50") == 2
    assert capsys.readouterr() == ("", message)


def test_state_with_no_repo_and_an_empty_save_point_exits_2_naming_the_remedy(
        root, seed, capsys):
    seed.issue(50, "open")

    assert orch_breakdown(root, seed, "state", "50", remotes={}) == 2
    assert capsys.readouterr() == ("", "orch: %s\n" % REPO_REMEDY)


@pytest.mark.parametrize("names, answer", [
    (("draft.md",), "partial\n"),
    (("draft.md", "published"), "complete\n"),
])
def test_state_with_no_repo_answers_from_the_save_point_first(root, seed, capsys, names,
                                                             answer):
    save_point(root, 50, *names)

    assert orch_breakdown(root, seed, "state", "50", remotes={}) == 0
    assert capsys.readouterr() == (answer, "")


# --- breakdown publish --------------------------------------------------------

# A three-ticket draft: 2 is blocked by 1, 3 by 2 and 1.
DRAFT = """\
@@ ticket 1 First
Body one.
@@ end
@@ ticket 2 Second
@@ blocked-by 1
Body two.
@@ end
@@ ticket 3 Third
@@ blocked-by 2,1
Body three.
@@ end
"""


@pytest.fixture
def spec(seed):
    """Spec issue #50, open, and the store's next issue #100."""
    seed.issue(50, "open")
    seed.next_issue(100)
    return seed


def draft_file(tmp_path, text, name="draft.md"):
    """<text> written as a draft file under tmp_path, byte for byte: its path."""
    path = tmp_path / name
    path.write_bytes(text.encode())
    return str(path)


def subs_of(seed, parent):
    """The numbers the store lists as <parent>'s sub-issues, in link order."""
    return (read(seed.store, "subs", parent) or "").split()


def body_of(seed, n):
    return read(seed.store, "issues", n, "body")


def test_a_clean_publish_creates_links_and_blocks_every_ticket_in_publishing_order(
        root, spec, tmp_path, capsys):
    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, DRAFT)) == 0

    assert capsys.readouterr() == ("100\n101\n102\n", "")
    directory = root / ".orchestrator" / "breakdown" / "50"
    assert (directory / "draft.md").read_text() == DRAFT
    assert (directory / "published").read_text() == ""
    assert (directory / "numbers").read_text() == (
        "1 100 created\n1 100 linked\n2 101 created\n2 101 linked\n"
        "3 102 created\n3 102 linked\n")
    assert [read(spec.store, "issues", n, "title") for n in (100, 101, 102)] == [
        "First\n", "Second\n", "Third\n"]
    assert [labels_of(spec.store, n) for n in (100, 101, 102)] == [["ready-for-agent"]] * 3
    assert subs_of(spec, 50) == ["100", "101", "102"]
    assert [blockers_of(spec.store, n) for n in (100, 101, 102)] == [[], ["100"], ["100", "101"]]
    assert [body_of(spec, n) for n in (100, 101, 102)] == [
        "Body one.\n\n## Blocked by\n\nNone (can start immediately)\n",
        "Body two.\n\n## Blocked by\n\n- #100\n",
        "Body three.\n\n## Blocked by\n\n- #100\n- #101\n",
    ]


def test_a_repo_that_renames_ready_for_agent_creates_every_ticket_under_its_label(
        root, spec, tmp_path, capsys):
    write_labels_doc(root, labels_doc(("ready-for-agent", "agent: go")))

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, DRAFT)) == 0

    assert [labels_of(spec.store, n) for n in (100, 101, 102)] == [["agent: go"]] * 3


def test_a_ticket_s_blocked_by_prose_is_rewritten_from_its_blocking_edges(
        root, spec, tmp_path, capsys):
    text = ("@@ ticket 1 First\nBody one.\n\n## Blocked by\n\nNothing, it is the root.\n@@ end\n"
            "@@ ticket 2 Second\n@@ blocked-by 1\nBody two.\n\n## Blocked by\n\n"
            "- The ticket \"First\" of this breakdown.\n@@ end\n")

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, text)) == 0

    assert [body_of(spec, n) for n in (100, 101)] == [
        "Body one.\n\n## Blocked by\n\nNone (can start immediately)\n",
        "Body two.\n\n## Blocked by\n\n- #100\n",
    ]


def test_escaped_grammar_lines_publish_as_body_lines_losing_one_backslash(
        root, spec, tmp_path, capsys):
    text = ("@@ ticket 1 First\n\\@@ blocked-by 1\n\\@@ end\n\\@@ ticket 9 x\n\\\\@@ x\n"
            "\\a @@ y\n@@x\n@@-1\n@@ end\n@@ ticket 2 Second\nTwo.\n@@ end\n")

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, text)) == 0

    assert capsys.readouterr().out == "100\n101\n"
    assert subs_of(spec, 50) == ["100", "101"]
    assert blockers_of(spec.store, 100) == []
    assert body_of(spec, 100) == (
        "@@ blocked-by 1\n@@ end\n@@ ticket 9 x\n\\@@ x\n\\a @@ y\n@@x\n@@-1\n"
        "\n## Blocked by\n\nNone (can start immediately)\n")


def test_a_crlf_draft_publishes_as_its_lf_form_and_is_saved_byte_for_byte(
        root, spec, tmp_path, capsys):
    text = ("@@ ticket 1 Alpha\r\nBody line.\r\n\\@@ end\r\n@@ end \t\r\n\r\n"
            "@@ ticket 2 Beta\r\n@@ blocked-by 1\r\nBeta body.\r\n@@ end\r\n")
    draft = draft_file(tmp_path, text)

    assert orch_breakdown(root, spec, "publish", "50", draft) == 0

    assert capsys.readouterr().out == "100\n101\n"
    assert [read(spec.store, "issues", n, "title") for n in (100, 101)] == ["Alpha\n", "Beta\n"]
    assert body_of(spec, 100).startswith("Body line.\n@@ end\n\n## Blocked by")
    assert blockers_of(spec.store, 101) == ["100"]
    assert (root / ".orchestrator/breakdown/50/draft.md").read_bytes() == text.encode()


def test_an_empty_blocked_by_list_means_no_blockers(root, spec, tmp_path, capsys):
    text = "@@ ticket 1 A\n@@ blocked-by \nx\n@@ end\n"

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, text)) == 0

    assert blockers_of(spec.store, 100) == []


def test_blockers_keep_the_draft_s_text_de_duplicated_by_number(root, spec, tmp_path, capsys):
    # 01 and 1 are one number but two positions: sort -un keeps the first.
    text = "@@ ticket 01 A\nx\n@@ end\n@@ ticket 2 B\n@@ blocked-by 01,1\ny\n@@ end\n"

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, text)) == 0

    assert blockers_of(spec.store, 101) == ["100"]


def test_tickets_publish_blockers_first_and_otherwise_in_draft_order(
        root, spec, tmp_path, capsys):
    # Each pass runs in draft order and emits a ticket whose blockers were
    # emitted earlier, in that pass too: 2, 3 and 4, then 1.
    text = ("@@ ticket 1 One\n@@ blocked-by 3\nx\n@@ end\n@@ ticket 2 Two\nx\n@@ end\n"
            "@@ ticket 3 Three\n@@ blocked-by 2\nx\n@@ end\n@@ ticket 4 Four\nx\n@@ end\n")

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, text)) == 0

    assert capsys.readouterr().out == "100\n101\n102\n103\n"
    assert [read(spec.store, "issues", n, "title") for n in (100, 101, 102, 103)] == [
        "Two\n", "Three\n", "Four\n", "One\n"]
    assert blockers_of(spec.store, 103) == ["101"]


# Repeats test_spec_review_check_tickets.py's HINT on purpose: the spec keeps
# the spec review tests unchanged.
HINT = " - a body line starting with @@ is written \\@@"


@pytest.mark.parametrize("text, message", [
    ("@@ ticket x A\nb\n@@ end\n", "line 1: ticket position is not a plain number: x"),
    ("@@ ticket  5 A\nb\n@@ end\n", "line 1: ticket position is not a plain number: "),
    ("@@ ticket 1\tA\n@@ end\n", "line 1: ticket position is not a plain number: 1\tA"),
    ("@@ ticket 1\nb\n@@ end\n", "line 1: ticket 1 has no title"),
    ("@@ ticket 1   \nb\n@@ end\n", "line 1: ticket 1 has no title"),
    ("@@ ticket 1 A\n@@ end\n\n@@ ticket 1 B\n@@ end\n", "line 4: ticket 1 appears twice"),
    ("intro\n@@ ticket 1 A\n@@ end\n", "line 1: text outside a ticket block"),
    ("@@ ticket 1 A\n@@ end\n@@ end\n", "line 3: text outside a ticket block"),
    ("@@ ticket 1 A\nok\n@@ end\n@@ ticket 2 B\n@@ note hi\n@@ end\n",
     "line 5: stray grammar line inside ticket 2: @@ note hi" + HINT),
    ("@@ ticket 1 A\n@@\n@@ end\n", "line 2: stray grammar line inside ticket 1: @@" + HINT),
    ("@@ ticket 1 A\n@@ ticket\n@@ end\n",
     "line 2: stray grammar line inside ticket 1: @@ ticket" + HINT),
    ("@@ ticket 1 A\n@@ blocked-by\n@@ end\n",
     "line 2: stray grammar line inside ticket 1: @@ blocked-by" + HINT),
    ("@@ ticket 1 A\n\n@@ blocked-by 2\n@@ end\n",
     "line 3: stray grammar line inside ticket 1: @@ blocked-by 2" + HINT),
    ("@@ ticket 1 A\n@@ blocked-by 2\n@@ blocked-by 3\n@@ end\n",
     "line 3: stray grammar line inside ticket 1: @@ blocked-by 3" + HINT),
    ("@@ ticket 1 A\nx\n@@ end\r\r\n",
     "line 3: stray grammar line inside ticket 1: @@ end\r" + HINT),
    ("@@ ticket 1 A\r\nok\r\n@@ foo\r\n@@ end\r\n",
     "line 3: stray grammar line inside ticket 1: @@ foo" + HINT),
    ("@@ ticket 1 A\nok\n@@ end\n@@ ticket 2 B\n@@ ticket 3 C\n@@ end\n",
     "line 5: @@ ticket inside an unfinished block" + HINT),
    ("@@ ticket 1 A\n@@ end\n@@ ticket 2 B\nbody\n", "ticket 2 has no @@ end"),
    ("", "no ticket blocks"),
    ("\n \t\n\n", "no ticket blocks"),
])
def test_a_malformed_draft_dies_naming_its_line_and_saves_nothing(
        root, spec, tmp_path, capsys, text, message):
    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, text)) == 1

    assert capsys.readouterr() == ("", "orch: the breakdown draft is malformed: %s\n" % message)
    assert not (root / ".orchestrator").exists()
    assert read(spec.store, "issues", 100, "title") is None


@pytest.mark.parametrize("text, message", [
    ("@@ ticket 1 A\n@@ blocked-by 1\nx\n@@ end\n", "ticket 1 is blocked by itself"),
    ("@@ ticket 1 A\n@@ blocked-by 7\nx\n@@ end\n",
     "ticket 1 is blocked by 7, which is no ticket of the draft"),
    ("@@ ticket 1 A\nx\n@@ end\n@@ ticket 2 B\n@@ blocked-by 01\nx\n@@ end\n",
     "ticket 2 is blocked by 01, which is no ticket of the draft"),
    # Checked in draft order: ticket 1's unknown blocker before ticket 2's
    # self-block.
    ("@@ ticket 1 A\n@@ blocked-by 9\n@@ end\n@@ ticket 2 B\n@@ blocked-by 2\n@@ end\n",
     "ticket 1 is blocked by 9, which is no ticket of the draft"),
    ("@@ ticket 1 A\n@@ blocked-by 2\nx\n@@ end\n@@ ticket 2 B\n@@ blocked-by 1\ny\n@@ end\n",
     "the breakdown draft's blocked-by edges form a cycle"),
    ("@@ ticket 1 A\nx\n@@ end\n@@ ticket 2 B\n@@ blocked-by 1,,2\n@@ end\n",
     "ticket-2 blocked-by must be plain issue numbers, got: 1,,2"),
    ("@@ ticket 1 A\nx\n@@ end\n@@ ticket 2 B\n@@ blocked-by 1, 2\n@@ end\n",
     "ticket-2 blocked-by must be plain issue numbers, got: 1, 2"),
    ("@@ ticket 1 A\n@@ blocked-by  \n@@ end\n",
     "ticket-1 blocked-by must be plain issue numbers, got:  "),
])
def test_a_draft_whose_blockers_cannot_be_ordered_creates_and_saves_nothing(
        root, spec, tmp_path, capsys, text, message):
    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, text)) == 1

    assert capsys.readouterr() == ("", "orch: %s\n" % message)
    assert not (root / ".orchestrator").exists()
    assert read(spec.store, "issues", 100, "title") is None


def published(root, parent=50):
    """Spec issue <parent>'s save point under <root>: its numbers file's text
    (None when absent) and whether its published marker is there."""
    directory = root / ".orchestrator" / "breakdown" / str(parent)
    numbers = directory / "numbers"
    return (numbers.read_text() if numbers.is_file() else None,
            (directory / "published").is_file())


def saved(root, seed, text, numbers, *created):
    """A save point as a run of either version left it: <text> saved as
    spec #50's draft.md and <numbers> as its numbers file, and each of
    <created> - (number, title, linked, blockers) - in the store, linked as
    #50's sub-issue when <linked>, blocked by <blockers>."""
    directory = save_point(root, 50)
    (directory / "draft.md").write_bytes(text.encode())
    (directory / "numbers").write_text(numbers)
    for n, title, linked, blockers in created:
        seed.issue(n, "open", "ready-for-agent")
        seed.title(n, title)
        seed.body(n, "Body.\n")
        if linked:
            seed.sub_issue(50, n)
        seed.blocked_by(n, *blockers)
    seed.next_issue(max(n for n, *_ in created) + 1)


def test_a_saved_draft_wins_over_the_draft_given(root, spec, tmp_path, capsys):
    save_point(root, 50)
    (root / ".orchestrator/breakdown/50/draft.md").write_text(DRAFT)
    other = draft_file(tmp_path, "@@ ticket 1 Other\nx\n@@ end\n", "other.md")

    assert orch_breakdown(root, spec, "publish", "50", other) == 0

    assert capsys.readouterr().out == "100\n101\n102\n"
    assert read(spec.store, "issues", 100, "title") == "First\n"
    assert (root / ".orchestrator/breakdown/50/draft.md").read_text() == DRAFT


def test_a_resume_links_a_ticket_recorded_created_and_never_creates_it_again(
        root, spec, tmp_path, capsys):
    saved(root, spec, DRAFT, "1 100 created\n1 100 linked\n2 101 created\n",
          (100, "First", True, ()), (101, "Second", False, ()))

    assert orch_breakdown(root, spec, "publish", "50", "/nonexistent") == 0

    assert capsys.readouterr() == ("100\n101\n102\n", "")
    assert subs_of(spec, 50) == ["100", "101", "102"]
    assert [read(spec.store, "issues", n, "title") for n in (101, 102, 103)] == [
        "Second\n", "Third\n", None]
    assert blockers_of(spec.store, 101) == ["100"]
    assert blockers_of(spec.store, 102) == ["100", "101"]
    assert published(root) == (
        "1 100 created\n1 100 linked\n2 101 created\n2 101 linked\n3 102 created\n"
        "3 102 linked\n", True)


def test_the_last_numbers_line_for_a_position_wins(root, spec, tmp_path, capsys):
    # Ticket 1's last line says linked, so it is skipped; ticket 2's says
    # created, so it is linked again.
    saved(root, spec, DRAFT, "1 100 created\n2 101 linked\n1 100 linked\n2 101 created\n",
          (100, "First", True, ()), (101, "Second", False, ()))
    spec.fail("adapter_issue_body", "body read")

    assert orch_breakdown(root, spec, "publish", "50", "/nonexistent") == 1
    spec.unfail()
    assert capsys.readouterr().err == (
        "orch: gh could not read ticket #101's body: body read\n"
        "orch: ticket 2 of the draft (#101): the link failed\n")
    assert subs_of(spec, 50) == ["100", "101"]


def test_the_numbers_print_in_the_order_their_positions_first_appear_in_the_numbers_file(
        root, spec, tmp_path, capsys):
    # A bash-format save point whose numbers file names ticket 2 before
    # ticket 1: the output follows the file, not the publishing order.
    saved(root, spec, DRAFT, "2 101 created\n1 100 created\n1 100 linked\n2 101 linked\n",
          (100, "First", True, ()), (101, "Second", True, (100,)))

    assert orch_breakdown(root, spec, "publish", "50", "/nonexistent") == 0

    assert capsys.readouterr() == ("101\n100\n102\n", "")
    assert published(root) == (
        "2 101 created\n1 100 created\n1 100 linked\n2 101 linked\n3 102 created\n"
        "3 102 linked\n", True)


def test_a_resume_writes_only_the_links_and_edges_that_never_landed(
        root, spec, tmp_path, capsys):
    saved(root, spec, DRAFT,
          "1 100 created\n1 100 linked\n2 101 created\n2 101 linked\n3 102 created\n",
          (100, "First", True, ()), (101, "Second", True, (100,)),
          (102, "Third", True, (100,)))
    spec.fail("adapter_sub_issue_link")
    spec.fail_after("adapter_blocker_add", 1)

    assert orch_breakdown(root, spec, "publish", "50", "/nonexistent") == 0

    assert capsys.readouterr() == ("100\n101\n102\n", "")
    assert subs_of(spec, 50) == ["100", "101", "102"]
    assert blockers_of(spec.store, 102) == ["100", "101"]
    assert published(root)[1]


def test_a_rerun_of_a_published_breakdown_creates_and_writes_nothing(
        root, spec, tmp_path, capsys):
    draft = draft_file(tmp_path, DRAFT)
    assert orch_breakdown(root, spec, "publish", "50", draft) == 0
    capsys.readouterr()
    before = snapshot(spec.store)

    assert orch_breakdown(root, spec, "publish", "50", draft) == 0

    assert capsys.readouterr() == ("100\n101\n102\n", "")
    assert snapshot(spec.store) == before


def test_a_failed_create_dies_naming_its_position(root, spec, tmp_path, capsys):
    spec.fail("adapter_issue_create", GH_502)

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, DRAFT)) == 1

    assert capsys.readouterr() == ("", "orch: gh could not create the ticket: HTTP 502: Bad"
                                       " Gateway\norch: ticket 1 of the draft: the create"
                                       " failed\n")
    assert published(root) == (None, False)


LINK_FAILED = "orch: ticket %s of the draft (#%s): the link failed\n"


@pytest.mark.parametrize("operation, after, k, n, message, numbers", [
    ("adapter_sub_issue_link", 1, "2", 101,
     "gh could not link ticket #101 as a sub-issue of #50: HTTP 502: Bad Gateway",
     "1 100 created\n1 100 linked\n2 101 created\n"),
    ("adapter_blocker_add", 0, "2", 101,
     "gh could not add a blocking edge from ticket #101 on #100: HTTP 502: Bad Gateway",
     "1 100 created\n1 100 linked\n2 101 created\n"),
    ("adapter_sub_issues", 0, "1", 100,
     "gh could not list sub-issues of #50: HTTP 502: Bad Gateway", "1 100 created\n"),
    # Ticket 1's read-back reads its blockers once; ticket 2's own read is
    # the second.
    ("adapter_blockers", 1, "2", 101,
     "gh could not read ticket #101's blockers: HTTP 502: Bad Gateway",
     "1 100 created\n1 100 linked\n2 101 created\n"),
    # The read-back's two attempts both fail.
    ("adapter_sub_issues", 1, "1", 100,
     "gh could not read ticket #100's links: HTTP 502: Bad Gateway", "1 100 created\n"),
    ("adapter_issue_body", 0, "1", 100,
     "gh could not read ticket #100's body: HTTP 502: Bad Gateway", "1 100 created\n"),
    ("adapter_issue_body_edit", 0, "1", 100,
     "gh could not rewrite ticket #100's ## Blocked by section: HTTP 502: Bad Gateway",
     "1 100 created\n"),
])
def test_a_failed_link_step_dies_with_its_own_message_then_the_link_failed_line(
        root, spec, tmp_path, capsys, operation, after, k, n, message, numbers):
    spec.fail_after(operation, after, GH_502)

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, DRAFT)) == 1

    assert capsys.readouterr() == ("", "orch: %s\n%s" % (message, LINK_FAILED % (k, n)))
    assert published(root) == (numbers, False)


def test_a_ticket_left_created_by_a_failed_link_is_linked_by_the_rerun(
        root, spec, tmp_path, capsys):
    draft = draft_file(tmp_path, DRAFT)
    spec.fail_after("adapter_sub_issue_link", 1)
    assert orch_breakdown(root, spec, "publish", "50", draft) == 1
    spec.unfail()
    capsys.readouterr()

    assert orch_breakdown(root, spec, "publish", "50", draft) == 0

    assert capsys.readouterr() == ("100\n101\n102\n", "")
    assert subs_of(spec, 50) == ["100", "101", "102"]
    assert blockers_of(spec.store, 101) == ["100"]


def test_links_that_never_read_back_die_as_unverified(root, spec, tmp_path, capsys):
    # The listing before the link answers; both read-backs answer stale.
    spec.lag_after("adapter_sub_issues", 1, 2)

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, DRAFT)) == 1

    assert capsys.readouterr() == (
        "", "orch: ticket #100's sub-issue/blocked-by links did not verify - checked twice,"
            " both failed\n" + LINK_FAILED % ("1", 100))
    assert published(root) == ("1 100 created\n", False)


@pytest.mark.parametrize("operation", ["lag", "fail"])
def test_a_read_back_that_misses_once_then_verifies_publishes(
        root, spec, tmp_path, capsys, operation):
    if operation == "lag":
        spec.lag_after("adapter_sub_issues", 1, 1)
    else:
        spec.fail_times("adapter_sub_issues", 1, GH_502)
        (Path(spec.store) / "fail" / "adapter_sub_issues.after").write_text("1\n")

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, DRAFT)) == 0

    assert capsys.readouterr() == ("100\n101\n102\n", "")
    assert subs_of(spec, 50) == ["100", "101", "102"]


# --- publish's deaths outside GitHub -------------------------------------------


def test_a_missing_draft_file_dies_naming_it(root, spec, tmp_path, capsys):
    missing = str(tmp_path / "missing.md")

    assert orch_breakdown(root, spec, "publish", "50", missing) == 1

    assert capsys.readouterr() == ("", "orch: draft file not found: %s\n" % missing)
    assert not (root / ".orchestrator").exists()


def test_a_save_point_that_cannot_be_made_dies_creating_nothing(root, spec, tmp_path, capsys):
    (root / ".orchestrator").mkdir()
    (root / ".orchestrator" / "breakdown").write_text("")
    directory = "%s/.orchestrator/breakdown/50" % root

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, DRAFT)) == 1

    assert capsys.readouterr() == ("", "orch: could not create %s\n" % directory)
    assert read(spec.store, "issues", 100, "title") is None


def test_a_draft_that_cannot_be_saved_dies_creating_nothing(root, spec, tmp_path, capsys):
    directory = save_point(root, 50)
    (directory / "draft.md").mkdir()

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, DRAFT)) == 1

    assert capsys.readouterr() == (
        "", "orch: could not save the breakdown draft to %s/draft.md\n" % directory)
    assert os.listdir(directory) == ["draft.md"]
    assert not (directory / "draft.md").is_file()
    assert read(spec.store, "issues", 100, "title") is None


def test_an_unwritable_numbers_file_dies_at_the_created_record_before_any_link(
        root, spec, tmp_path, capsys):
    directory = save_point(root, 50)
    (directory / "numbers").mkdir()

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, DRAFT)) == 1

    assert capsys.readouterr() == (
        "", "orch: could not write ticket #100's created record to %s/numbers\n" % directory)
    assert read(spec.store, "issues", 100, "title") == "First\n"
    assert subs_of(spec, 50) == []


class NumbersLostAtTheRewrite(FakeGh):
    """The gh fake, but the `## Blocked by` rewrite - the link's last write -
    leaves the numbers file a directory, so the linked record cannot be
    written."""

    numbers = ""

    def issue_body_edit(self, n, body_file):
        super().issue_body_edit(n, body_file)
        os.remove(self.numbers)
        os.mkdir(self.numbers)


def test_an_unwritable_numbers_file_dies_at_the_linked_record_and_the_rerun_relinks(
        root, spec, tmp_path, capsys):
    directory = save_point(root, 50)
    numbers = str(directory / "numbers")
    NumbersLostAtTheRewrite.numbers = numbers
    draft = draft_file(tmp_path, "@@ ticket 1 Only\nx\n@@ end\n")

    assert orch_breakdown(root, spec, "publish", "50", draft,
                          fake_gh=NumbersLostAtTheRewrite) == 1

    assert capsys.readouterr() == (
        "", "orch: could not write ticket #100's linked record to %s\n" % numbers)
    assert not (directory / "published").exists()
    os.rmdir(numbers)
    (directory / "numbers").write_text("1 100 created\n")
    for operation in ("adapter_issue_create", "adapter_sub_issue_link"):
        spec.fail(operation, "written again")

    assert orch_breakdown(root, spec, "publish", "50", draft) == 0

    assert capsys.readouterr() == ("100\n", "")
    assert published(root) == ("1 100 created\n1 100 linked\n", True)
    assert subs_of(spec, 50) == ["100"]
    assert body_of(spec, 100) == "x\n\n## Blocked by\n\nNone (can start immediately)\n"


def test_a_published_marker_that_cannot_be_written_dies(root, spec, tmp_path, capsys):
    directory = save_point(root, 50)
    (directory / "published").mkdir()

    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, DRAFT)) == 1

    assert capsys.readouterr() == (
        "", "orch: could not write the published marker %s/published\n" % directory)
    assert subs_of(spec, 50) == ["100", "101", "102"]


def test_publish_with_no_repo_dies_with_the_remedy_after_saving_the_draft(
        root, spec, tmp_path, capsys):
    assert orch_breakdown(root, spec, "publish", "50", draft_file(tmp_path, DRAFT),
                          remotes={}) == 1

    assert capsys.readouterr() == ("", "orch: %s\n" % REPO_REMEDY)
    assert (root / ".orchestrator/breakdown/50/draft.md").read_text() == DRAFT
    assert read(spec.store, "issues", 100, "title") is None
    assert published(root) == (None, False)


# --- the refusals -------------------------------------------------------------

STATE_USAGE = "orch: usage: orch.sh breakdown state <parent>\n"
PUBLISH_USAGE = "orch: usage: orch.sh breakdown publish <parent> <draft-file>\n"


@pytest.mark.parametrize("argv, code, message", [
    (("state",), 2, STATE_USAGE),
    (("state", "50", "51"), 2, STATE_USAGE),
    (("state", "abc"), 2, "orch: parent must be a plain issue number, got: abc\n"),
    (("state", ""), 2, "orch: parent must be a plain issue number, got: \n"),
    (("publish",), 1, PUBLISH_USAGE),
    (("publish", "50"), 1, PUBLISH_USAGE),
    (("publish", "50", "d.md", "x"), 1, PUBLISH_USAGE),
    (("publish", "5a", "d.md"), 1, "orch: parent must be a plain issue number, got: 5a\n"),
    (("publish", "", "d.md"), 1, "orch: parent must be a plain issue number, got: \n"),
    ((), 1, "orch: unknown breakdown op: <none> (want publish|state)\n"),
    (("open", "50"), 1, "orch: unknown breakdown op: open (want publish|state)\n"),
])
def test_misuse_is_refused_before_any_read(root, seed, capsys, argv, code, message):
    seed.offline()

    assert orch_breakdown(root, seed, *argv, remotes={}) == code
    assert capsys.readouterr() == ("", message)


def test_the_cli_module_routes_the_breakdown_noun_to_this_module(root, seed, capsys,
                                                                 monkeypatch):
    monkeypatch.setattr(breakdown, "Git", lambda: FakeGit(toplevel=str(root)))

    assert died_of(capsys, lambda: cli.main(["breakdown", "state"])) == (2, "", STATE_USAGE)
