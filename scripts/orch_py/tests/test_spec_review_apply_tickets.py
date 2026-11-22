"""The spec-review noun's apply --tickets, run in-process against FakeGit and
the gh fake's store: the pause before any GitHub write when an applied edit
meets a ticket breakdown, then the --tickets rerun - ticket text edits, then
edges, then the body, then any retire, then the changelog comment - every
ticket-step refusal before any write, a failure at each GitHub write naming
what landed, and --resume across the ticket writes. The cases and messages
are the ones the bash spec-review apply section's ticket step pinned; the
fixture batch is test_spec_review_apply.py's."""
from __future__ import annotations

import os

import pytest

from conftest import comments_of, edit, flow_state, read, snapshot
from test_spec_review_apply import (AUTOPILOT, BODY, CLEAN, apply, batch_edit, on_disk,
                                    refused, resume, round_dir)

T20 = "## What to build\n\nBuild alpha.\n\n## Blocked by\n\nNone (can start immediately)\n"
T21 = "## What to build\n\nBuild gamma.\n\n## Blocked by\n\n- #20\n"

# The fixture tickets.md, bash's srt_dir's: item 1 on line 2 (its anchor on
# 4), item 2 on 10, item 3 on 11, item 4 on 12 (its anchor on 14), item 5 on
# 19 and the @@ closed line on 20.
TICKETS = """@@ recommend apply
@@ item 1 ticket 20 apply
@@ summary #20 builds alpha prime
@@ anchor
Build alpha.
@@ replace
Build alpha prime.
@@ end

@@ item 2 unblock 21 by 20 apply
@@ item 3 block 20 by 21 apply
@@ item 4 ticket 21 decline gamma is unchanged
@@ summary #21 builds gamma twice
@@ anchor
Build gamma.
@@ replace
Build gamma twice.
@@ end
@@ item 5 block 21 by 20 decline already there
@@ closed 22 the gamma API
"""

TICKETS_SECTION = """### Tickets
- (1) #20 builds alpha prime
- (2) #21 no longer blocked by #20
- (3) #20 now blocked by #21
- (4) "Build gamma twice." - declined as recommended: gamma is unchanged
- (5) "block #21 by #20" - declined as recommended: already there
- #22 closed, built against the earlier spec: the gamma API
"""

RETIRED_SECTION = """### Tickets
- retired, to be broken down again
- #22 closed, built against the earlier spec: the gamma API
"""

WRITES = """ticket #20's body
unblock #21 by #20
block #20 by #21
the body of issue #14
the changelog comment on issue #14
"""


def tickets_dir(root, seed, name="round", tickets=TICKETS):
    """The fixture round directory, with #14 broken down into open #20 and
    #21 (#21 blocked by #20) and closed #22, and tickets.md drafted."""
    d = round_dir(root, seed, name)
    seed.issue(20, "open")
    seed.body(20, T20)
    seed.issue(21, "open")
    seed.body(21, T21)
    seed.issue(22, "closed")
    for n in (20, 21, 22):
        seed.sub_issue(14, n)
    seed.blocked_by(21, 20)
    (d / "tickets.md").write_text(tickets)
    return d


def fetch(d):
    """The tickets' bodies fetched into ticket-<n>.md, as the session
    fetches them after the pause."""
    (d / "ticket-20.md").write_text(T20)
    (d / "ticket-21.md").write_text(T21)


def body(store, n):
    return read(store, "issues", n, "body")


def outcome(d, store):
    """Everything a ticket run leaves: the round's files and the bodies
    published."""
    files = [read(d, name) for name in ("spec.md", "ticket-20.md", "ticket-21.md",
                                         "changelog.md")]
    return files + [body(store, n) for n in (14, 20, 21)]


def ticket_files(d):
    return [read(d, name) for name in ("spec.md", "ticket-20.md", "ticket-21.md",
                                       "changelog.md")]


def ticket_refused(capsys, root, seed, store, d, *args, env=None):
    """refused, the ticket files unchanged too: its stderr."""
    before = ticket_files(d)
    err = refused(capsys, root, seed, store, d, "", *args, env=env)
    assert ticket_files(d) == before
    return err


# --- the pause --------------------------------------------------------------------------


def test_an_applied_edit_and_a_breakdown_pause_with_exit_3_before_any_github_write(
        root, seed, store, capsys):
    d = tickets_dir(root, seed)
    before = snapshot(store)

    assert apply(root, seed, d, "recommended") == 3
    assert capsys.readouterr().out == "sub-issues\n"
    assert snapshot(store) == before
    assert read(d, "spec.md") == CLEAN
    assert [on_disk(d / n) for n in ("apply-answer", "changelog.md", "settled.md")] == [
        "absent"] * 3
    assert apply(root, seed, d, "recommended") == 3


def test_with_the_breakdown_gone_the_rerun_applies_from_the_fetched_copy_once(root, seed,
                                                                             store):
    d = tickets_dir(root, seed)
    apply(root, seed, d, "recommended")
    os.remove(str(store / "subs" / "14"))

    assert apply(root, seed, d, "recommended") == 0
    assert read(d, "spec.md") == CLEAN


def test_a_collapsed_breakdown_pauses_too(root, seed, capsys):
    d = round_dir(root, seed)
    seed.body(14, BODY + "\n## Ticket\n\nThe one ticket.\n")

    assert apply(root, seed, d, "recommended") == 3
    assert capsys.readouterr().out == "collapsed\n"


def test_a_pause_clears_a_resumed_run_s_saved_answer(root, seed, store):
    d = tickets_dir(root, seed)
    os.remove(str(store / "subs" / "14"))
    seed.fail("adapter_issue_body_edit")
    apply(root, seed, d, "recommended")
    seed.unfail()
    for n in (20, 21, 22):
        seed.sub_issue(14, n)

    assert resume(root, seed, d) == 3
    assert on_disk(d / "apply-answer") == "absent"


@pytest.mark.parametrize("operation, message", [
    ("adapter_sub_issues", "ticket exists #14 exited 2: gh could not list sub-issues of #14: fake"
                           " gh: adapter_sub_issues failed - nothing written"),
    ("adapter_issue_body", "ticket exists #14 exited 2: gh could not read issue #14's body: fake"
                           " gh: adapter_issue_body failed - nothing written"),
])
def test_a_ticket_exists_failure_is_refused_before_any_write(root, seed, store, capsys,
                                                            operation, message):
    d = round_dir(root, seed)
    seed.fail(operation)

    assert refused(capsys, root, seed, store, d, "", "recommended") == "orch: %s\n" % message
    assert on_disk(d / "changelog.md") == "absent"


def test_the_autopilot_hold_run_takes_no_pause_and_the_reply_run_does(root, seed, store):
    d = tickets_dir(root, seed)
    batch_edit(d, "@@ item 3 consistency decision A material",
               "@@ item 3 consistency decision A fundamental")
    assert apply(root, seed, d, "recommended", env=AUTOPILOT) == 0
    assert on_disk(d / "fundamental.md") == "present"
    before = snapshot(store)

    assert apply(root, seed, d, "3B", env=AUTOPILOT) == 3
    assert snapshot(store) == before
    assert on_disk(d / "fundamental.md") == "present"
    fetch(d)
    assert apply(root, seed, d, "3B", "--tickets", "recommended", env=AUTOPILOT) == 0
    assert len(comments_of(store, 14)) == 1


# --- the --tickets rerun -------------------------------------------------------------------


def test_the_tickets_rerun_edits_tickets_then_edges_then_the_body_then_comments(root, seed,
                                                                               store):
    d = tickets_dir(root, seed)
    apply(root, seed, d, "recommended")
    fetch(d)

    assert apply(root, seed, d, "recommended", "--tickets", "recommended") == 0
    assert read(d, "ticket-20.fetched.md") == T20
    assert read(d, "ticket-20.md") == T20.replace("Build alpha.", "Build alpha prime.")
    assert body(store, 20) == T20.replace("Build alpha.", "Build alpha prime.").replace(
        "None (can start immediately)", "- #21")
    assert body(store, 21) == T21.replace("- #20", "None (can start immediately)")
    assert (read(store, "blocked_by", 20), read(store, "blocked_by", 21)) == ("21\n", "")
    assert body(store, 14) == CLEAN
    assert read(d, "changelog.md").endswith("\n\n" + TICKETS_SECTION)
    assert comments_of(store, 14) == [read(d, "changelog.md")]
    assert read(d, "applied.log") == WRITES


def test_a_clean_tickets_run_gives_the_pause_and_rerun_s_result(root, seed, store, tmp_path):
    d = tickets_dir(root, seed)
    apply(root, seed, d, "recommended")
    fetch(d)
    apply(root, seed, d, "recommended", "--tickets", "recommended")
    after = outcome(d, store)
    (store / "subs" / "14").unlink()
    d = tickets_dir(root, seed, "clean")
    fetch(d)

    assert apply(root, seed, d, "recommended", "--tickets", "recommended") == 0
    assert outcome(d, store) == after


@pytest.mark.parametrize("answer", ["1, 2, 4", " 1 ,2,  4 "])
def test_an_other_ticket_list_edits_before_its_edge_with_its_reasons(root, seed, store, answer):
    d = tickets_dir(root, seed)
    fetch(d)
    (d / "treasons").write_text("5: the edge stays\n")

    assert apply(root, seed, d, "recommended", "--tickets", answer, "--ticket-reasons",
                 str(d / "treasons")) == 0
    assert body(store, 21) == T21.replace("Build gamma.", "Build gamma twice.").replace(
        "- #20", "None (can start immediately)")
    assert read(store, "blocked_by", 20) is None
    log = read(d, "changelog.md")
    assert "- (4) #21 builds gamma twice\n" in log
    assert '- (3) "block #20 by #21" - declined\n' in log
    assert '- (5) "block #21 by #20" - the edge stays\n' in log
    assert read(d, "applied.log").startswith(
        "ticket #20's body\nticket #21's body\nunblock #21 by #20\n")


def test_none_writes_no_ticket_and_quotes_a_declined_text_edit(root, seed, store):
    d = tickets_dir(root, seed)
    fetch(d)
    (d / "treasons").write_text("1: alpha is fine\n")

    assert apply(root, seed, d, "recommended", "--tickets", "none", "--ticket-reasons",
                 str(d / "treasons")) == 0
    assert body(store, 20) == T20
    assert '- (1) "Build alpha prime." - alpha is fine\n' in read(d, "changelog.md")
    assert read(d, "applied.log") == (
        "the body of issue #14\nthe changelog comment on issue #14\n")


@pytest.mark.parametrize("how", ["retire", "recommended"])
def test_a_retire_runs_after_the_publish_editing_no_ticket(root, seed, store, how):
    d = tickets_dir(root, seed)
    fetch(d)
    if how == "recommended":
        edit(d / "tickets.md", "@@ recommend apply", "@@ recommend retire")

    assert apply(root, seed, d, "recommended", "--tickets", how) == 0
    assert read(store, "subs", 14) == ""
    assert (read(store, "issues", 20, "state"), read(store, "issues", 20, "reason")) == (
        "CLOSED\n", "not planned\n")
    assert "Build alpha." in body(store, 20)
    assert read(d, "applied.log") == (
        "the body of issue #14\nthe retire of #14's ticket breakdown\n"
        "the changelog comment on issue #14\n")
    assert read(d, "changelog.md").endswith("\n" + RETIRED_SECTION)


def test_a_resume_after_a_landed_retire_keeps_reporting_the_retire(root, seed, store, capsys):
    d = tickets_dir(root, seed)
    fetch(d)
    seed.fail_after("adapter_issue_comment", 1)
    assert apply(root, seed, d, "recommended", "--tickets", "retire") == 1
    seed.unfail()
    assert "the retire of #14's ticket breakdown\n" in read(d, "applied.log")

    assert resume(root, seed, d) == 0
    assert read(d, "changelog.md").endswith("\n" + RETIRED_SECTION)
    assert len([c for c in comments_of(store, 14) if c.startswith("## Spec review")]) == 1


def test_a_retire_answer_is_not_refused_for_a_ticket_outside_the_breakdown(root, seed, store):
    d = tickets_dir(root, seed, tickets="@@ recommend retire\n@@ item 1 ticket 99 apply\n"
                                        "@@ summary s\n@@ anchor\nnightly\n@@ replace\nhourly\n"
                                        "@@ end\n")
    seed.issue(99, "open")
    seed.body(99, "Unrelated issue: nightly backup job.")

    assert apply(root, seed, d, "recommended", "--tickets", "retire") == 0
    assert body(store, 99) == "Unrelated issue: nightly backup job."


def test_none_affected_is_recorded_and_writes_no_ticket(root, seed, store):
    d = tickets_dir(root, seed, tickets="@@ none-affected\n")

    assert apply(root, seed, d, "recommended", "--tickets", "recommended") == 0
    assert read(d, "changelog.md").endswith("### Tickets\nNone - no ticket affected\n")
    assert body(store, 20) == T20


def test_unattended_pauses_too_and_takes_only_tickets_recommended(root, seed, store, capsys):
    d = tickets_dir(root, seed)
    assert apply(root, seed, d, "recommended", "--unattended") == 3
    fetch(d)
    assert "--unattended takes only --tickets recommended" in ticket_refused(
        capsys, root, seed, store, d, "recommended", "--unattended", "--tickets", "all")

    assert apply(root, seed, d, "recommended", "--unattended", "--tickets", "recommended") == 0
    assert read(store, "blocked_by", 20) == "21\n"


def test_every_file_option_is_copied_so_a_resume_reads_the_copies(root, seed, store, tmp_path):
    d = tickets_dir(root, seed)
    fetch(d)
    sources = {}
    for name, text in (("reasons", "2: the plan chose this\n"),
                       ("treasons", "5: the edge stays\n"), ("hosts", "fell back\n")):
        (tmp_path / name).mkdir()
        sources[name] = tmp_path / name / name
        sources[name].write_text(text)
    seed.fail("adapter_issue_comment")
    assert apply(root, seed, d, "recommended", "--reasons", str(sources["reasons"]),
                 "--tickets", "1, 2, 4", "--ticket-reasons", str(sources["treasons"]),
                 "--host-fallbacks", str(sources["hosts"])) == 1
    seed.unfail()
    assert str(tmp_path) not in read(d, "apply-answer").replace(str(d), "")
    assert [on_disk(d / ("apply-%s.copy" % o)) for o in ("reasons", "ticket-reasons",
                                                          "host-fallbacks")] == ["present"] * 3
    for path in sources.values():
        path.unlink()

    assert resume(root, seed, d) == 0
    assert "**Host fallbacks:** fell back" in comments_of(store, 14)[0]


def test_a_tickets_rerun_from_an_all_crlf_tickets_md_stores_no_cr(root, seed, store):
    d = tickets_dir(root, seed, tickets=TICKETS.replace("\n", "\r\n"))
    fetch(d)

    assert apply(root, seed, d, "recommended", "--tickets", "recommended") == 0
    assert "Build alpha prime." in body(store, 20)
    assert "\r" not in body(store, 20)


COLLAPSED_TICKETS = ("@@ recommend apply\n@@ item 1 section apply\n@@ summary The ticket builds"
                     " alpha prime first\n@@ anchor\nBuild the spec.\n@@ replace\nBuild the spec,"
                     " alpha prime first.\n@@ end\n")


def collapsed_dir(root, seed):
    """The fixture with #14's breakdown collapsed into its body, and a ##
    Ticket item drafted."""
    d = round_dir(root, seed)
    spec_body = BODY + "\n## Ticket\n\nBuild the spec.\n"
    (d / "spec.md").write_text(spec_body)
    seed.body(14, spec_body)
    (d / "tickets.md").write_text(COLLAPSED_TICKETS)
    return d


def test_a_collapsed_ticket_edit_is_published_with_the_body(root, seed, store):
    d = collapsed_dir(root, seed)

    assert apply(root, seed, d, "recommended", "--tickets", "recommended") == 0
    assert body(store, 14) == CLEAN + "\n## Ticket\n\nBuild the spec, alpha prime first.\n"
    assert read(d, "applied.log") == (
        "the body of issue #14\nthe changelog comment on issue #14\n")
    assert read(d, "changelog.md").endswith("- (1) The ticket builds alpha prime first\n")


# --- refusals before any write ------------------------------------------------------------


def test_tickets_md_missing_is_refused(root, seed, store, capsys):
    d = tickets_dir(root, seed)
    os.remove(str(d / "tickets.md"))

    assert ticket_refused(capsys, root, seed, store, d, "recommended", "--tickets",
                          "recommended") == (
        "orch: tickets.md not found in %s - --tickets answers the ticket items it holds\n" % d)


@pytest.mark.parametrize("tickets, answer, reasons, message", [
    ("@@ item 1 ticket 20 apply\n", "recommended", None,
     "tickets.md line 1: @@ recommend comes first: @@ recommend apply or @@ recommend retire"),
    ("@@ recommend apply\n@@ item 1 ticket 20 apply\n@@ anchor\nx\n@@ replace\ny\n@@ end\n",
     "recommended", None, "tickets.md line 2: item 1 has no @@ summary"),
    (TICKETS, "1, 9", None,
     "the --tickets answer names ticket item 9, which tickets.md does not have"),
    (TICKETS, "1,", None,
     "the --tickets answer '1,' is not recommended, all, none, retire or a list such as 1, 3 -"
     " '' is no ticket item"),
    (TICKETS, "1, 1", None, "the --tickets answer names ticket item 1 twice"),
    (TICKETS, "none", "one: why\n",
     "--ticket-reasons line 1: want <n>: <reason>, got 'one: why'"),
    (TICKETS, "recommended", "1: why\n",
     "--ticket-reasons line 1 names ticket item 1, which the --tickets answer does not decline"),
    (TICKETS, "none", "9: why\n",
     "--ticket-reasons line 1 names ticket item 9, which tickets.md does not have"),
])
def test_a_ticket_file_answer_or_reason_refused_before_any_write(
        root, seed, store, capsys, tickets, answer, reasons, message):
    d = tickets_dir(root, seed, tickets=tickets)
    fetch(d)
    flags = ["--tickets", answer]
    if reasons is not None:
        (d / "treasons").write_text(reasons)
        flags += ["--ticket-reasons", str(d / "treasons")]

    assert ticket_refused(capsys, root, seed, store, d, "recommended", *flags) == (
        "orch: %s\n" % message)


def test_a_malformed_edge_item_and_a_crowded_none_affected_are_refused(root, seed, store,
                                                                       capsys):
    for tickets in ("@@ recommend apply\n@@ item 1 block 20 21 apply\n",
                    "@@ none-affected\n@@ closed 22 x\n"):
        d = tickets_dir(root, seed, name="round-%d" % len(tickets), tickets=tickets)
        fetch(d)
        assert "orch: tickets.md line 2" in ticket_refused(
            capsys, root, seed, store, d, "recommended", "--tickets", "recommended")


def test_a_ticket_item_with_no_ticket_file_takes_no_fetched_copy(root, seed, store, capsys):
    d = tickets_dir(root, seed)

    assert ticket_refused(capsys, root, seed, store, d, "recommended", "--tickets",
                          "recommended") == (
        "orch: tickets.md line 2: ticket item 1: ticket-20.md not found in %s - fetch each"
        " ticket a ticket item names into it - nothing written\n" % d)
    fetch(d)
    edit(d / "tickets.md", "Build alpha.\n@@ replace", "Nowhere.\n@@ replace")
    ticket_refused(capsys, root, seed, store, d, "recommended", "--tickets", "recommended")
    assert read(d, "ticket-20.fetched.md") == T20


def test_an_unreadable_ticket_copy_is_refused_naming_its_tickets_md_line(root, seed, store,
                                                                         capsys):
    d = tickets_dir(root, seed)
    fetch(d)
    (d / "ticket-20.fetched.md").mkdir()

    assert ticket_refused(capsys, root, seed, store, d, "recommended", "--tickets",
                          "recommended") == (
        "orch: tickets.md line 2: ticket item 1: could not read %s/ticket-20.fetched.md -"
        " nothing written\n" % d)


@pytest.mark.parametrize("in_flow", [False, True])
@pytest.mark.parametrize("old, new, answer, message", [
    ("Build alpha.\n@@ replace", "Nowhere.\n@@ replace", "recommended",
     "tickets.md line 4: ticket item 1 (#20): its anchor matches no text in the body"),
    ("Build gamma.\n@@ replace", "Nowhere.\n@@ replace", "recommended",
     "tickets.md line 14: ticket item 4 (#21): its anchor matches no text in the body"),
    ("@@ item 1 ticket", "@@ item 1 ticket", "all",
     "tickets.md line 19: ticket item 5: #21 is already blocked by #20"),
    ("@@ item 2 unblock 21 by 20 apply", "@@ item 2 unblock 20 by 21 apply", "recommended",
     "tickets.md line 10: ticket item 2: #20 is not blocked by #21"),
    ("@@ item 5 block 21 by 20 ", "@@ item 5 block 99 by 20 ", "recommended",
     "tickets.md line 19: ticket item 5: #99 is not a ticket of #14's breakdown"),
    ("@@ item 1 ticket 20 apply", "@@ item 1 ticket 99 apply", "recommended",
     "tickets.md line 2: ticket item 1: #99 is not a ticket of #14's breakdown"),
    ("@@ item 4 ticket 21 decline ", "@@ item 4 ticket 99 decline ", "recommended",
     "tickets.md line 12: ticket item 4: #99 is not a ticket of #14's breakdown"),
    ("@@ item 1 ticket 20 apply", "@@ item 1 ticket 22 apply", "recommended",
     "tickets.md line 2: ticket item 1: #22 is a closed ticket of #14's breakdown"),
    ("@@ item 5 block 21 by 20 ", "@@ item 5 block 22 by 20 ", "recommended",
     "tickets.md line 19: ticket item 5: #22 is a closed ticket of #14's breakdown"),
    ("@@ closed 22 ", "@@ closed 99 ", "recommended",
     "tickets.md line 20: #99 is not a ticket of #14's breakdown"),
    ("@@ closed 22 ", "@@ closed 20 ", "recommended",
     "tickets.md line 20: #20 is an open ticket of #14's breakdown"),
    ("@@ item 1 ticket 20 apply\n@@ summary #20 builds alpha prime\n@@ anchor\nBuild alpha.",
     "@@ item 1 section apply\n@@ summary s\n@@ anchor\nAlpha line.", "recommended",
     "tickets.md line 2: ticket item 1: a ## Ticket item, but #14's breakdown is sub-issues"),
])
def test_every_ticket_step_error_names_its_line_and_writes_nothing(
        root, seed, store, capsys, in_flow, old, new, answer, message):
    if in_flow:
        flow_state(root, "spec", "14")
    d = tickets_dir(root, seed)
    fetch(d)
    seed.issue(99, "open")
    seed.body(99, "Unrelated issue: nightly backup job.")
    edit(d / "tickets.md", old, new)
    before = ticket_files(d)
    store_before = snapshot(store)

    issue = None if in_flow else "14"
    assert apply(root, seed, d, "recommended", "--tickets", answer, issue=issue) == 1
    assert capsys.readouterr().err == "orch: %s - nothing written\n" % message
    assert ticket_files(d) == before
    assert snapshot(store) == store_before


def test_the_first_ticket_step_failure_is_an_item_before_a_closed_line(root, seed, capsys):
    d = tickets_dir(root, seed)
    fetch(d)
    edit(d / "tickets.md", "@@ item 1 ticket 20 apply", "@@ item 1 ticket 99 apply")
    edit(d / "tickets.md", "@@ closed 22 ", "@@ closed 99 ")

    assert apply(root, seed, d, "recommended", "--tickets", "recommended") == 1
    assert capsys.readouterr().err == (
        "orch: tickets.md line 2: ticket item 1: #99 is not a ticket of #14's breakdown -"
        " nothing written\n")


@pytest.mark.parametrize("old, new, message", [
    ("@@ item 1 section apply", "@@ item 1 section decline not now",
     "tickets.md line 4: ticket item 1 (## Ticket): its anchor matches no text in the body"),
    ("@@ item 1 section apply", "@@ item 1 section apply",
     "tickets.md line 4: ticket item 1 (## Ticket): its anchor matches no text in the body"),
    ("@@ item 1 section apply\n@@ summary The ticket builds alpha prime first\n@@ anchor\n"
     "Nowhere.", "@@ item 1 ticket 20 apply\n@@ summary s\n@@ anchor\nNowhere.",
     "tickets.md line 2: ticket item 1: #20 is not a ticket of #14's breakdown"),
])
def test_a_collapsed_breakdown_s_ticket_step_errors(root, seed, store, capsys, old, new,
                                                    message):
    d = collapsed_dir(root, seed)
    edit(d / "tickets.md", "Build the spec.\n@@ replace", "Nowhere.\n@@ replace")
    edit(d / "tickets.md", old, new)

    err = refused(capsys, root, seed, store, d, "", "recommended", "--tickets", "recommended")
    assert err == "orch: %s - nothing written\n" % message


def test_a_collapsed_ticket_anchor_on_text_the_batch_replaced_is_refused(root, seed, store,
                                                                        capsys):
    d = collapsed_dir(root, seed)
    edit(d / "tickets.md", "Build the spec.\n@@ replace", "Alpha line.\n@@ replace")

    assert "ticket item 1 (## Ticket): its anchor matches no text" in refused(
        capsys, root, seed, store, d, "", "recommended", "--tickets", "recommended")


def test_an_edge_whose_blocker_is_closed_is_added(root, seed, store):
    d = tickets_dir(root, seed)
    fetch(d)
    edit(d / "tickets.md", "@@ item 3 block 20 by 21 apply", "@@ item 3 block 20 by 22 apply")

    assert apply(root, seed, d, "recommended", "--tickets", "recommended") == 0
    assert "22" in read(store, "blocked_by", 20).split()


# --- a failed ticket-step write -------------------------------------------------------------


@pytest.mark.parametrize("in_flow", [False, True])
@pytest.mark.parametrize("how, operation, after, message", [
    ("recommended", "adapter_issue_body_edit", 0,
     "could not write ticket #20's body: gh could not replace the body of issue #20: fake gh:"
     " adapter_issue_body_edit failed - already landed: nothing"),
    ("recommended", "adapter_blocker_remove", 0,
     "could not write unblock #21 by #20: gh could not remove a blocking edge from ticket #21 on"
     " #20: fake gh: adapter_blocker_remove failed - already landed: ticket #20's body"),
    ("recommended", "adapter_blocker_add", 0,
     "could not write block #20 by #21: gh could not add a blocking edge from ticket #20 on #21:"
     " fake gh: adapter_blocker_add failed - already landed: ticket #20's body; unblock #21 by"
     " #20"),
    ("recommended", "adapter_issue_body_edit", 3,
     "could not write the body of issue #14: gh could not replace the body of issue #14: fake"
     " gh: adapter_issue_body_edit failed - already landed: ticket #20's body; unblock #21 by"
     " #20; block #20 by #21"),
    ("retire", "adapter_issue_close", 0,
     "could not write the retire of #14's ticket breakdown: gh could not close ticket #20: fake"
     " gh: adapter_issue_close failed - already landed: the body of issue #14"),
    ("retire", "adapter_sub_issue_unlink", 0,
     "could not write the retire of #14's ticket breakdown: gh could not unlink ticket #20 from"
     " #14: fake gh: adapter_sub_issue_unlink failed - already landed: the body of issue #14"),
    ("recommended", "adapter_issue_comment", 0,
     "could not write the changelog comment on issue #14: gh could not comment on issue #14:"
     " fake gh: adapter_issue_comment failed - already landed: ticket #20's body; unblock #21"
     " by #20; block #20 by #21; the body of issue #14"),
])
def test_a_failed_ticket_step_write_stops_apply_naming_what_landed(
        root, seed, capsys, in_flow, how, operation, after, message):
    if in_flow:
        flow_state(root, "spec", "14")
    d = tickets_dir(root, seed)
    fetch(d)
    seed.fail_after(operation, after)

    assert apply(root, seed, d, "recommended", "--tickets", how,
                 issue=None if in_flow else "14") == 1
    assert capsys.readouterr().err == (
        "orch: %s; %s/changelog.md is kept, and the review stops here\n" % (message, d))
    assert on_disk(d / "changelog.md") == "present"


@pytest.mark.parametrize("operation, after", [
    ("adapter_issue_state", 0), ("adapter_issue_parent", 0), ("adapter_blockers", 0),
    ("adapter_issue_body", 0),
])
def test_a_failed_read_inside_a_ticket_write_stops_apply_too(root, seed, capsys, operation,
                                                            after):
    d = tickets_dir(root, seed)
    fetch(d)
    # The ticket text write reads nothing; the reads are the edges'.
    seed.fail_after(operation, after)

    assert apply(root, seed, d, "recommended", "--tickets", "recommended") == 1
    err = capsys.readouterr().err
    assert err.startswith("orch: could not write unblock #21 by #20: gh could not ")
    assert "already landed: ticket #20's body;" in err


def test_a_resume_after_a_failed_edge_skips_the_ticket_writes_that_landed(root, seed, store):
    d = tickets_dir(root, seed)
    fetch(d)
    seed.fail("adapter_blocker_add")
    assert apply(root, seed, d, "recommended", "--unattended", "--tickets", "recommended") == 1
    seed.unfail()
    seed.fail("adapter_blocker_remove")

    assert resume(root, seed, d) == 0
    assert read(d, "applied.log") == WRITES
    assert read(store, "blocked_by", 20) == "21\n"


def test_a_resume_skips_every_write_a_bash_written_applied_log_records(root, seed, store):
    d = tickets_dir(root, seed)
    fetch(d)
    seed.fail("adapter_issue_comment")
    assert apply(root, seed, d, "recommended", "--tickets", "recommended") == 1
    seed.unfail()
    # bash's labels for the writes that landed, word for word.
    (d / "applied.log").write_text(
        "ticket #20's body\nunblock #21 by #20\nblock #20 by #21\nthe body of issue #14\n")
    for operation in ("adapter_issue_body_edit", "adapter_blocker_add",
                      "adapter_blocker_remove", "adapter_issue_state"):
        seed.fail(operation)

    assert resume(root, seed, d) == 0
    assert comments_of(store, 14) == [read(d, "changelog.md")]
    assert read(d, "applied.log") == WRITES
