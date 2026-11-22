"""The spec-review noun's check --tickets, run in-process against FakeGit
with the checkout and its round directory under tmp_path: the round's
tickets.md validated as apply --tickets would take the all answer - its
grammar, every text anchor against the copy apply would edit, every edge
against its ticket's ## Blocked by - with nothing written but view.md and no
GitHub read. Each call is checked by its stdout, its exit code, its `orch:`
lines and the view.md it saves, removes or leaves; the expected views and
messages are the ones the bash spec-review check --tickets section pins."""
from __future__ import annotations

import os

import pytest

from conftest import orch_spec_review

UNATTENDED_TAIL = " - unattended: not a turn-final reply; go straight on to apply"

T20 = """## What to build

Build alpha.

## Blocked by

None (can start immediately)"""

T21 = """## What to build

Build gamma.

## Blocked by

- #20"""

# The fixture tickets.md, bash's srct_dir's. Its @@ anchor lines: item 1 on
# 4, item 4 on 14.
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
@@ closed 22 the gamma API
"""

VIEW = """## The ticket items

### Item 1 - #20

**Recommendation:** apply

**Current**

```
Build alpha.
```

**Proposed**

```
Build alpha prime.
```

### Item 2 - unblock #21 by #20

**Recommendation:** apply

### Item 3 - block #20 by #21

**Recommendation:** apply

### Item 4 - #21

**Recommendation:** recommend decline - gamma is unchanged

**Current**

```
Build gamma.
```

**Proposed**

```
Build gamma twice.
```

### Closed tickets

- #22 - the gamma API

**Recommended answer:** apply
"""

NONE_VIEW = "## The ticket items\n\nNo open ticket is affected.\n"


@pytest.fixture
def root(tmp_path):
    path = tmp_path.resolve() / "repo"
    path.mkdir()
    return path


def tickets_dir(root, name="round", tickets=TICKETS, spec="# Spec\n\nAlpha line.\n"):
    """A fresh round directory after the pause: spec.md, #20 and #21 fetched
    into ticket-<n>.md, and <tickets> drafted as tickets.md."""
    d = root / name
    d.mkdir()
    (d / "spec.md").write_text(spec)
    (d / "ticket-20.md").write_text(T20)
    (d / "ticket-21.md").write_text(T21)
    (d / "tickets.md").write_text(tickets)
    return d


def snapshot(d):
    """Every file under <d>, by its path under <d>, with its bytes."""
    files = {}
    for here, _, names in os.walk(str(d)):
        for name in names:
            path = os.path.join(here, name)
            with open(path, "rb") as f:
                files[os.path.relpath(path, str(d))] = f.read()
    return files


def without_view(files):
    return {name: data for name, data in files.items() if name != "view.md"}


def nudge(d):
    return (" - end your turn on one plain-text reply, no tool call: the view above word for"
            " word, then the question with its answer words spelled out; it is saved in"
            " %s/view.md" % d)


def passes(items, anchors):
    return ("tickets.md passes: %d items, %d anchors, each matching once, and the all answer"
            " applies cleanly" % (items, anchors))


def refused(*lines):
    return "".join("orch: %s\n" % line for line in lines)


def check(root, *args, env=None):
    return orch_spec_review(root, "check", *(str(a) for a in args), "--tickets", env=env)


def assert_passes(root, capsys, d, view, line, *args):
    """check --tickets on <d> exits 0 with exactly <view> on stdout and
    <line>, the pass line, on stderr, saving <view> to view.md and changing
    nothing else."""
    before = without_view(snapshot(d))

    assert check(root, d, *args) == 0

    assert capsys.readouterr() == (view, line + "\n")
    assert (d / "view.md").read_text() == view
    assert without_view(snapshot(d)) == before


# --- a clean ticket batch -------------------------------------------------------


def test_a_ticket_batch_passes_with_its_view_and_the_pass_line(root, capsys):
    d = tickets_dir(root)

    assert_passes(root, capsys, d, VIEW, passes(4, 2) + nudge(d))
    assert not (d / "ticket-20.fetched.md").exists()


def assert_refused(root, capsys, d, err, *args):
    """check --tickets on <d> exits 1 with exactly <err> on stderr, nothing
    on stdout and <d> as it was."""
    before = snapshot(d)

    assert check(root, d, *args) == 1

    assert capsys.readouterr() == ("", err)
    assert snapshot(d) == before


SECTION_TICKETS = """@@ recommend retire
@@ item 1 section apply
@@ summary The ticket builds alpha first
@@ anchor
Build the spec.
@@ replace
Build the spec, alpha first.
@@ end
"""

SECTION_VIEW = """## The ticket items

### Item 1 - the `## Ticket` section

**Recommendation:** apply

**Current**

```
Build the spec.
```

**Proposed**

```
Build the spec, alpha first.
```

### Closed tickets

None

**Recommended answer:** retire - the ticket breakdown retired, to be broken down again
"""


def test_a_collapsed_breakdown_s_ticket_item_is_anchored_on_spec_md(root, capsys):
    d = tickets_dir(root, tickets=SECTION_TICKETS,
                    spec="# Spec\n\n## Ticket\n\nBuild the spec.\n")

    assert_passes(root, capsys, d, SECTION_VIEW, passes(1, 1) + nudge(d))


def test_a_ticket_item_anchor_spec_md_lacks_is_refused(root, capsys):
    d = tickets_dir(root, tickets=SECTION_TICKETS.replace("Build the spec.\n@@ replace",
                                                          "Nowhere.\n@@ replace"),
                    spec="# Spec\n\n## Ticket\n\nBuild the spec.\n")

    assert_refused(root, capsys, d, refused(
        "tickets.md line 4: ticket item 1 (## Ticket): its anchor matches no text in the body"))


# --- @@ none-affected -----------------------------------------------------------


def test_none_affected_prints_the_stub_and_names_none(root, capsys):
    d = tickets_dir(root, tickets="@@ none-affected\n", spec="# Spec\n")

    assert check(root, d) == 0

    assert capsys.readouterr() == (NONE_VIEW, "tickets.md passes: no open ticket affected\n")
    assert not (d / "view.md").exists()


@pytest.mark.parametrize("args", [[], ["--unattended"]])
def test_none_affected_removes_an_earlier_view_md_with_no_tail(root, capsys, args):
    d = tickets_dir(root, tickets="@@ none-affected\n", spec="# Spec\n")
    (d / "view.md").write_text("an earlier batch view\n")

    assert check(root, d, *args) == 0

    assert capsys.readouterr() == (NONE_VIEW, "tickets.md passes: no open ticket affected\n")
    assert not (d / "view.md").exists()


def test_a_view_md_that_cannot_be_removed_fails_none_affected(root, capsys):
    d = tickets_dir(root, tickets="@@ none-affected\n", spec="# Spec\n")
    (d / "view.md" / "held").mkdir(parents=True)

    assert check(root, d) == 1

    assert capsys.readouterr() == ("", refused("could not remove %s/view.md" % d))
    assert (d / "view.md" / "held").is_dir()


# --- the copy apply would edit ----------------------------------------------------


def test_an_anchor_is_checked_against_the_fetched_copy_when_one_exists(root, capsys):
    d = tickets_dir(root)
    (d / "ticket-20.fetched.md").write_text(T20)
    (d / "ticket-20.md").write_text("Rewritten.\n")

    assert check(root, d) == 0
    capsys.readouterr()


def test_an_anchor_ticket_md_has_but_the_fetched_copy_lacks_is_refused(root, capsys):
    d = tickets_dir(root)
    (d / "ticket-20.fetched.md").write_text("Rewritten.\n")

    assert_refused(root, capsys, d, refused(
        "tickets.md line 4: ticket item 1 (#20): its anchor matches no text in the body"))


# --- view.md (#1293) ----------------------------------------------------------------


def test_a_pass_overwrites_an_earlier_view_md(root, capsys):
    d = tickets_dir(root)
    (d / "view.md").write_text("an earlier batch view\n")

    assert_passes(root, capsys, d, VIEW, passes(4, 2) + nudge(d))


def test_a_relative_dir_s_pass_line_names_view_md_by_absolute_path(root, capsys, monkeypatch):
    d = tickets_dir(root)
    monkeypatch.chdir(str(root))

    assert check(root, "round") == 0

    assert capsys.readouterr().err == passes(4, 2) + nudge("%s/round" % root) + "\n"
    assert (d / "view.md").read_text() == VIEW


def test_a_view_md_that_cannot_be_written_fails_before_any_view(root, capsys):
    d = tickets_dir(root)
    (d / "view.md").mkdir()

    assert check(root, d) == 1

    assert capsys.readouterr() == ("", refused("could not write %s/view.md" % d))


def test_unattended_ends_the_pass_line_in_its_own_tail_with_the_same_view(root, capsys):
    d = tickets_dir(root)

    assert_passes(root, capsys, d, VIEW, passes(4, 2) + UNATTENDED_TAIL, "--unattended")


def test_a_failing_check_leaves_an_earlier_view_md_as_it_was(root, capsys):
    d = tickets_dir(root, tickets=TICKETS.replace("Build alpha.\n@@", "Nowhere.\n@@"))
    (d / "view.md").write_text("an earlier view\n")

    assert_refused(root, capsys, d, refused(
        "tickets.md line 4: ticket item 1 (#20): its anchor matches no text in the body"))


def test_check_tickets_reads_no_github(root, capsys, seed):
    seed.offline()
    d = tickets_dir(root)

    assert orch_spec_review(root, "check", str(d), "--tickets", seed=seed) == 0
    assert capsys.readouterr().out == VIEW


# --- refusals -----------------------------------------------------------------------

HINT = " - a body line starting with @@ is written \\@@"


def lines_of(text, changes):
    """<text>'s lines rewritten as one sed run rewrites them: <changes> maps a
    line number to the lines that take its place, [] deleting it."""
    out = []
    for number, line in enumerate(text.split("\n"), 1):
        out += changes.get(number, [line])
    return "\n".join(out)


@pytest.mark.parametrize("tickets, err", [
    (TICKETS.replace("Build alpha.\n@@", "Nowhere.\n@@"),
     ["tickets.md line 4: ticket item 1 (#20): its anchor matches no text in the body"]),
    (TICKETS.replace("Build alpha.\n@@", "##\n@@"),
     ["tickets.md line 4: ticket item 1 (#20): its anchor matches more than one place in the"
      " body"]),
    (TICKETS.replace("Build alpha.\n@@", "Nowhere.\n@@").replace("Build gamma.\n@@",
                                                                  "Nowhere.\n@@"),
     ["tickets.md line 4: ticket item 1 (#20): its anchor matches no text in the body",
      "tickets.md line 14: ticket item 4 (#21): its anchor matches no text in the body"]),
    (TICKETS + "@@ bogus\n", ["tickets.md line 20: unknown line '@@ bogus'"]),
    (lines_of(TICKETS, {6: []}),
     ["tickets.md line 7: expected @@ replace to end the anchor begun on line 4, got '@@ end'"
      + HINT]),
    (lines_of(TICKETS, {8: []}),
     ["tickets.md line 9: expected @@ end to end the replacement begun on line 6, got"
      " '@@ item 2 unblock 21 by 20 apply'" + HINT]),
    (lines_of(TICKETS, {8: [], 10: ["@@ item 2 unblock 21 by 20 apply\r"]}),
     ["tickets.md line 9: expected @@ end to end the replacement begun on line 6, got"
      " '@@ item 2 unblock 21 by 20 apply'" + HINT]),
    (TICKETS + "@@ bogus\r\n", ["tickets.md line 20: unknown line '@@ bogus'"]),
    (TICKETS + "@@\r\n", ["tickets.md line 20: unknown line '@@ '"]),
    (TICKETS.replace("@@ item 3 block 20 by 21 apply", "@@ item 3 block 21 by 20 apply"),
     ["tickets.md line 11: ticket item 3: #21 is already blocked by #20"]),
    (TICKETS.replace("@@ item 2 unblock 21 by 20 apply", "@@ item 2 unblock 20 by 21 apply"),
     ["tickets.md line 10: ticket item 2: #20 is not blocked by #21"]),
    # The shared @@ block reader (#2568).
    (lines_of(TICKETS, {5: ["  "]}), ["tickets.md line 4: the anchor is empty"]),
    ("@@ recommend apply\n@@ item 1 ticket 20 apply\n@@ summary x\n@@ anchor\nBuild alpha.\n",
     ["tickets.md line 4: the @@ anchor block is never ended"]),
    ("@@ recommend apply\n@@ item 1 ticket 20 apply\n@@ summary x\n@@ anchor\nBuild alpha.\n"
     "@@ replace\nNew.\n", ["tickets.md line 6: the @@ replace block is never ended"]),
    (TICKETS + "@@ replace\n", ["tickets.md line 20: @@ replace with no @@ anchor open"]),
    (TICKETS + "@@ end\n", ["tickets.md line 20: @@ end with no @@ anchor open"]),
    # check --tickets collects too (#3456): content violations first, then the
    # anchor problems; an incomplete item's anchor is not checked.
    (lines_of(TICKETS, {3: [], 14: [], 15: [], 16: [], 17: [], 18: []})
     + "@@ item 5 ticket 20 apply\n@@ summary #20 again\n@@ anchor\nNowhere.\n@@ replace\n"
       "Somewhere.\n@@ end\n",
     ["tickets.md line 2: item 1 has no @@ summary",
      "tickets.md line 11: item 4 has no @@ anchor/@@ replace/@@ end block",
      "tickets.md line 16: ticket item 5 (#20): its anchor matches no text in the body"]),
    # A structure violation stops the run after the content violations before
    # it.
    (lines_of(TICKETS, {3: []}) + "@@ bogus\n",
     ["tickets.md line 2: item 1 has no @@ summary",
      "tickets.md line 19: unknown line '@@ bogus'"]),
])
def test_a_ticket_batch_violation_is_refused_naming_its_line(root, capsys, tickets, err):
    d = tickets_dir(root, tickets=tickets)

    assert_refused(root, capsys, d, refused(*err))


@pytest.mark.parametrize("tickets, err", [
    ("@@ item 1 ticket 20 apply\n",
     "line 1: @@ recommend comes first: @@ recommend apply or @@ recommend retire"),
    ("@@\n", "line 1: @@ recommend comes first: @@ recommend apply or @@ recommend retire"),
    ("@@ recommend apply\n@@ recommend apply\n", "line 2: @@ recommend comes first, and only once"),
    ("@@ recommend apply\n@@ none-affected\n",
     "line 2: @@ none-affected comes first, and only once"),
    ("@@ recommend maybe\n", "line 1: @@ recommend wants apply or retire, got 'maybe'"),
    ("@@ recommend\n", "line 1: @@ recommend wants apply or retire, got ''"),
    ("@@ none-affected now\n", "line 1: @@ none-affected takes nothing after it"),
    ("@@ none-affected\n@@ closed 22 x\n", "line 2: @@ none-affected stands alone in its file"),
    ("@@ none-affected\n\nstray\n", "line 3: text outside an @@ anchor or @@ replace block"),
    ("@@ recommend apply\n@@ item 0 ticket 20 apply\n",
     "line 2: item number must be a positive number, got '0'"),
    ("@@ recommend apply\n@@ item 01 ticket 20 apply\n",
     "line 2: item number must be a positive number, got '01'"),
    ("@@ recommend apply\n@@ item\n", "line 2: item number must be a positive number, got ''"),
    ("@@ recommend apply\n@@ item 1 block 20 by 21 apply\n@@ item 1 block 21 by 22 apply\n",
     "line 3: a second item 1"),
    ("@@ recommend apply\n@@ item 1 block 20 21 apply\n",
     "line 2: @@ item 1 block wants <t> by <b>"),
    ("@@ recommend apply\n@@ item 1 unblock 20 by x apply\n",
     "line 2: @@ item 1 unblock wants <t> by <b>, each a plain issue number"),
    ("@@ recommend apply\n@@ item 1 block 20 by 20 apply\n",
     "line 2: @@ item 1: a ticket never blocks itself"),
    ("@@ recommend apply\n@@ item 1 block x by 20 apply\n",
     "line 2: @@ item 1 block wants a plain issue number, got 'x'"),
    ("@@ recommend apply\n@@ item 1 ticket #20 apply\n",
     "line 2: @@ item 1 ticket wants a plain issue number, got '#20'"),
    ("@@ recommend apply\n@@ item 1 retitle 20 apply\n",
     "line 2: item 1 wants ticket <t>, section, block <t> by <b> or unblock <t> by <b>"),
    ("@@ recommend apply\n@@ item 1 ticket 20 apply now\n",
     "line 2: @@ item 1 ... apply takes nothing after it"),
    ("@@ recommend apply\n@@ item 1 section decline\n",
     "line 2: @@ item 1 ... decline needs a reason"),
    ("@@ recommend apply\n@@ item 1 block 20 by 21 maybe\n",
     "line 2: item 1's recommendation must be apply or decline <reason>"),
    ("@@ recommend apply\n@@ summary s\n", "line 2: @@ summary outside an item"),
    ("@@ recommend apply\n@@ closed 22 x\n@@ anchor\n", "line 3: @@ anchor outside an item"),
    ("@@ recommend apply\n@@ item 1 block 20 by 21 apply\n@@ summary s\n",
     "line 3: an edge item carries no @@ summary"),
    ("@@ recommend apply\n@@ item 1 ticket 20 apply\n@@ summary\n",
     "line 3: @@ summary needs its line"),
    ("@@ recommend apply\n@@ item 1 ticket 20 apply\n@@ summary s\n@@ summary t\n",
     "line 4: a second @@ summary for this item"),
    ("@@ recommend apply\n@@ item 1 ticket 20 apply\n@@ anchor x\n",
     "line 3: @@ anchor takes nothing after it; the anchor is the lines below it"),
    ("@@ recommend apply\n@@ item 1 ticket 20 apply\n@@ summary s\n@@ anchor\nBuild alpha.\n"
     "@@ replace\nx\n@@ end\n@@ anchor\n", "line 9: a second @@ anchor for this item"),
    ("@@ recommend apply\n@@ closed x gone\n",
     "line 2: @@ closed wants <t> <what changed>, t a plain issue number"),
    ("@@ recommend apply\n@@ closed 22\n", "line 2: @@ closed 22 needs what changed"),
])
def test_each_ticket_grammar_refusal_is_bash_s(root, capsys, tickets, err):
    d = tickets_dir(root, tickets=tickets)

    assert_refused(root, capsys, d, refused("tickets.md " + err))


def test_an_empty_tickets_md_is_refused(root, capsys):
    d = tickets_dir(root, tickets="\n  \n")

    assert_refused(root, capsys, d, refused(
        "tickets.md is empty - it holds @@ recommend and the ticket items, or @@ none-affected"))


def test_a_closed_line_ends_the_item_before_it_checking_it(root, capsys):
    d = tickets_dir(root, tickets="@@ recommend apply\n@@ item 1 ticket 20 apply\n"
                                  "@@ closed 22 the gamma API\n")

    assert_refused(root, capsys, d, refused(
        "tickets.md line 2: item 1 has no @@ summary",
        "tickets.md line 2: item 1 has no @@ anchor/@@ replace/@@ end block"))


def test_a_missing_ticket_file_is_named_by_each_item_needing_it(root, capsys):
    d = tickets_dir(root)
    (d / "ticket-20.md").unlink()

    assert_refused(root, capsys, d, refused(
        "tickets.md line 2: ticket item 1: ticket-20.md not found in %s - fetch each ticket a"
        " ticket item names into it" % d,
        "tickets.md line 11: ticket item 3: ticket-20.md not found in %s - fetch each ticket a"
        " ticket item names into it" % d))


def test_a_ticket_copy_that_cannot_be_read_stops_naming_its_item(root, capsys):
    d = tickets_dir(root)
    (d / "ticket-20.fetched.md").mkdir()

    assert_refused(root, capsys, d, refused(
        "tickets.md line 2: ticket item 1: could not read %s/ticket-20.fetched.md - nothing"
        " written" % d))


def test_an_unreadable_copy_reports_the_content_violations_first(root, capsys):
    d = tickets_dir(root, tickets=lines_of(TICKETS, {13: []}))
    (d / "ticket-20.fetched.md").mkdir()

    assert_refused(root, capsys, d, refused(
        "tickets.md line 12: item 4 has no @@ summary",
        "tickets.md line 2: ticket item 1: could not read %s/ticket-20.fetched.md - nothing"
        " written" % d))


def test_no_tickets_md_and_no_spec_md_are_refused(root, capsys):
    d = tickets_dir(root)
    (d / "tickets.md").unlink()
    assert_refused(root, capsys, d, refused("tickets.md not found in %s" % d))
    d = tickets_dir(root, name="other")
    (d / "spec.md").unlink()
    assert_refused(root, capsys, d, refused("spec.md not found in %s" % d))


def test_a_missing_directory_is_refused(root, capsys):
    assert check(root, root / "nowhere/") == 1

    assert capsys.readouterr() == ("", refused("no such directory: %s/nowhere" % root))


def test_crlf_on_every_line_passes_as_its_lf_twin(root, capsys):
    d = tickets_dir(root, tickets=TICKETS.replace("\n", "\r\n"))

    assert_passes(root, capsys, d, VIEW, passes(4, 2) + nudge(d))


def test_a_blocked_by_section_inside_a_fence_or_after_its_end_lists_no_blocker(root, capsys):
    d = tickets_dir(root, tickets="@@ recommend apply\n@@ item 1 unblock 21 by 20 apply\n")
    (d / "ticket-21.md").write_text("## What to build\n\n```\n## Blocked by\n\n- #20\n```\n\n"
                                    "## Blocked by\n\nNone (can start immediately)\n\n## Notes\n\n"
                                    "- #20\n")

    assert_refused(root, capsys, d, refused(
        "tickets.md line 2: ticket item 1: #21 is not blocked by #20"))


def test_a_crlf_ticket_s_blocked_by_section_reads_as_its_lf_twin(root, capsys):
    d = tickets_dir(root, tickets="@@ recommend apply\n@@ item 1 block 21 by 20 apply\n")
    (d / "ticket-21.md").write_text(T21.replace("\n", "\r\n"))

    assert_refused(root, capsys, d, refused(
        "tickets.md line 2: ticket item 1: #21 is already blocked by #20"))


# --- escaped block lines (#1945) ----------------------------------------------------


def escaped_dir(root, block):
    """A round dir whose #20 holds grammar-like lines, and a tickets.md item
    on it carrying <block>."""
    d = tickets_dir(root, tickets="@@ recommend apply\n@@ item 1 ticket 20 apply\n"
                                  "@@ summary Reword\n%s\n" % block)
    (d / "ticket-20.md").write_text("## What to build\n\nBuild alpha.\n@@ note <text>\n"
                                    "\\@@ keep\n\\x stays\n@@x stays\n\n## Blocked by\n\n"
                                    "None (can start immediately)")
    return d


def test_escaped_lines_in_an_anchor_and_replacement_render_unescaped(root, capsys):
    d = escaped_dir(root, "@@ anchor\n\\@@ note <text>\n\\\\@@ keep\n\\x stays\n@@x stays\n"
                          "@@ replace\n\\@@ remark <text>\n@@-1 new\n@@ end")

    assert check(root, d) == 0

    out = capsys.readouterr().out
    assert "\n@@ remark <text>\n" in out
    assert "\n@@-1 new\n" in out
    assert "\\@@ remark" not in out


def test_an_escaped_anchor_with_an_empty_replacement_passes(root, capsys):
    d = escaped_dir(root, "@@ anchor\n\\@@ note <text>\n@@ replace\n@@ end")

    assert check(root, d) == 0
    capsys.readouterr()


@pytest.mark.parametrize("block, err", [
    ("@@ anchor\n@@ note <text>\n@@ replace\nNew.\n@@ end",
     "tickets.md line 5: expected @@ replace to end the anchor begun on line 4, got"
     " '@@ note <text>'" + HINT),
    ("@@ anchor\nAlpha.\n@@ replace\n@@ note <text>\n@@ end",
     "tickets.md line 7: expected @@ end to end the replacement begun on line 6, got"
     " '@@ note <text>'" + HINT),
])
def test_an_unescaped_at_line_inside_a_block_is_refused_with_the_hint(root, capsys, block, err):
    d = escaped_dir(root, block)

    assert_refused(root, capsys, d, refused(err))
