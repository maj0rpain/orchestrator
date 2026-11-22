"""The spec-review noun's check verb without --tickets, run in-process
against FakeGit with the checkout and its round directory under tmp_path:
each call checked by its stdout, its exit code, its `orch:` lines and the
view.md it saves or leaves, as the bash spec-review check answers. The
expected views are the ones the bash spec-review check sections pin, so the
Python views match bash's for the same batch."""
from __future__ import annotations

import os
import re
from pathlib import Path

import pytest

from conftest import orch_issue, orch_spec_review
from orch import spec_review

USAGE = "usage: orch.sh spec-review check <dir> [--tickets | --full <n>...]"
UNATTENDED_TAIL = " - unattended: not a turn-final reply; go straight on to apply"
BASH_MODULE = Path(__file__).resolve().parents[2] / "orch" / "spec-review.sh"

SRC_BODY = """# Spec

Alpha line.
Beta line.
Gamma line.
Delta line.
Twice.
Twice.
"""

# The fixture batch, bash's src_dir's. Its @@ anchor lines: item 1 on 9,
# item 2 on 18, item 3's options A and B on 29 and 36.
SRC_BATCH = """@@ lens fidelity ran
@@ lens consistency ran
@@ lens testability ran
@@ lens implementability not-run timed out

@@ item 1 fidelity apply minor
@@ finding fidelity 1
@@ summary Alpha primed
@@ anchor
Alpha line.
@@ replace
Alpha prime line.
@@ end

@@ item 2 consistency decline material the plan chose this
@@ finding consistency 1
@@ summary Beta reversed
@@ anchor
Beta line.
@@ replace
Beta reversed.
@@ end
@@ why Beta contradicts the plan
@@ item 3 testability decision A material
@@ finding testability 1
@@ why Gamma must be testable
@@ option A Keep gamma
@@ summary Gamma kept
@@ anchor
Gamma line.
@@ replace
Gamma line (kept).
@@ end
@@ option B Drop gamma
@@ summary Gamma dropped
@@ anchor
Gamma line.
@@ replace
Gamma dropped.
@@ end
@@ item 4 testability resolved
@@ finding testability 2
@@ resolved-by 3
"""

SRC_VIEW = """## The batch

### Lenses

- Fidelity: ran
- Consistency: ran
- Testability: ran
- Implementability: not run - timed out

- **2** - **Consistency** - Beta reversed (recommend decline: the plan chose this) - Beta contradicts the plan
- **3** - **Testability** (decision, option A recommended) - Gamma must be testable
  - Option A - Keep gamma (recommended): Gamma kept
  - Option B - Drop gamma: Gamma dropped

### Minor edits

- **1** - Fidelity: Alpha primed
- **4** - Testability: resolved by item 3
"""


@pytest.fixture
def root(tmp_path):
    path = tmp_path.resolve() / "repo"
    path.mkdir()
    return path


def round_dir(root, name="round"):
    """A fresh round directory under <root>, holding the fixture body, batch
    and lens files."""
    d = root / name
    d.mkdir()
    (d / "spec.md").write_text(SRC_BODY)
    (d / "batch.md").write_text(SRC_BATCH)
    (d / "lens-fidelity.md").write_text("@@ finding 1\nAlpha is stale.\n")
    (d / "lens-consistency.md").write_text("@@ finding 1\nBeta contradicts the plan.\n")
    (d / "lens-testability.md").write_text(
        "@@ finding 1\nGamma is untestable.\n@@ finding 2\nGamma again.\n")
    return d


def rewrite(path, changes):
    """<path>'s lines rewritten as one sed run rewrites them: <changes> maps
    a line number of the file as it was to the lines that take its place -
    [] deletes it, and ... in the list stands for the line itself."""
    lines = path.read_text().split("\n")
    out = []
    for number, line in enumerate(lines, 1):
        out += [line if part is ... else part for part in changes.get(number, [line])]
    path.write_text("\n".join(out))


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


def passes(items, anchors, body="spec.md"):
    return ("batch.md passes: %d items, %d anchors, each matching once in %s, and the all"
            " answer applies cleanly" % (items, anchors, body))


def check(root, *args, env=None):
    return orch_spec_review(root, "check", *(str(a) for a in args), env=env)


def assert_passes(root, capsys, d, view, line, *args):
    """check on <d> with <args> exits 0 with exactly <view> on stdout and
    <line>, the pass line, on stderr, saving <view> to view.md and changing
    nothing else."""
    before = without_view(snapshot(d))

    assert check(root, d, *args) == 0

    assert capsys.readouterr() == (view, line + "\n")
    assert (d / "view.md").read_text() == view
    assert without_view(snapshot(d)) == before


def assert_refused(root, capsys, d, err, *args):
    """check on <d> with <args> exits 1 with exactly <err> on stderr, nothing
    on stdout and <d> as it was."""
    before = snapshot(d)

    assert check(root, d, *args) == 1

    assert capsys.readouterr() == ("", err)
    assert snapshot(d) == before


# --- a clean batch --------------------------------------------------------------


def test_a_clean_batch_passes_with_its_compact_view_and_the_pass_line(root, capsys):
    d = round_dir(root)

    assert_passes(root, capsys, d, SRC_VIEW, passes(4, 4) + nudge(d))
    assert not (d / "spec.fetched.md").exists()


def test_a_lone_decision_item_counts_an_anchor_for_each_option(root, capsys):
    d = round_dir(root)
    (d / "batch.md").write_text("""@@ lens fidelity ran
@@ lens consistency not-run timed out
@@ lens testability not-run timed out
@@ lens implementability not-run timed out

@@ item 1 fidelity decision B material
@@ finding fidelity 1
@@ why Alpha and Delta are stale
@@ option A Prime alpha
@@ summary Alpha primed
@@ anchor
Alpha line.
@@ replace
Alpha prime line.
@@ end
@@ option B Prime delta
@@ summary Delta primed
@@ anchor
Delta line.
@@ replace
Delta prime line.
@@ end
@@ option C Prime beta
@@ summary Beta primed
@@ anchor
Beta line.
@@ replace
Beta prime line.
@@ end
""")

    assert check(root, d) == 0

    assert capsys.readouterr().err == passes(1, 3) + nudge(d) + "\n"


def test_the_implementability_map_is_never_parsed(root, capsys):
    d = round_dir(root)
    (d / "map-implementability.md").write_text(
        "@@ item 9 bogus\n@@ finding nowhere 7\n@@ lens implementability ran\n")

    assert_passes(root, capsys, d, SRC_VIEW, passes(4, 4) + nudge(d))


def test_a_resolved_item_alone_makes_the_minor_edits_list(root, capsys):
    d = round_dir(root)
    rewrite(d / "batch.md", {6: ["@@ item 1 fidelity apply material"],
                             14: ["@@ why Alpha is stale"]})

    assert check(root, d) == 0

    assert capsys.readouterr().out.split("\n\n### Minor edits\n\n")[1] == (
        "- **4** - Testability: resolved by item 3\n")


def test_a_batch_with_nothing_minor_or_resolved_has_no_minor_edits_heading(root, capsys):
    d = round_dir(root)
    rewrite(d / "batch.md", {6: ["@@ item 1 fidelity apply material"],
                             14: ["@@ why Alpha is stale"],
                             25: [..., "@@ finding testability 2"],
                             41: [], 42: [], 43: []})

    assert check(root, d) == 0

    assert "Minor edits" not in capsys.readouterr().out


def test_a_minor_recommend_decline_line_carries_its_reason(root, capsys):
    d = round_dir(root)
    rewrite(d / "batch.md", {15: ["@@ item 2 consistency decline minor the plan chose this"],
                             23: [""]})

    assert check(root, d) == 0

    assert ("- **2** - Consistency: Beta reversed - recommend decline: the plan chose this\n"
            in capsys.readouterr().out)


WORKED_BODY = """# Widget export

## Problem Statement

Exports time out on large widgets.

## Solution

The export streams each widget in pages of 100.
The export writes one file.

## Testing Decisions

- One seam: the `widget export` CLI.
"""

WORKED_BATCH = """@@ lens fidelity standalone
@@ lens consistency ran
@@ lens testability ran
@@ lens implementability ran

@@ item 1 consolidation apply material
@@ summary Failed pages are retried once
@@ why A page that fails once should not fail the whole export
@@ comment @alice 2026-10-01T09:00:00Z
@@ quote
A failed page should be retried once before the export gives up.
@@ anchor
The export streams each widget in pages of 100.
@@ replace
The export streams each widget in pages of 100.
A failed page is retried once before the export fails.
@@ end

@@ item 2 testability apply material
@@ finding testability 1
@@ summary The seam's test runs against a fake store
@@ why The seam names no store to test against
@@ anchor
- One seam: the `widget export` CLI.
@@ replace
- One seam: the `widget export` CLI, end to end, against a fake store.
@@ end

@@ item 3 consistency decline minor the glossary's term is widget, as the body says
@@ finding consistency 1
@@ summary Widgets renamed items
@@ anchor
Exports time out on large widgets.
@@ replace
Exports time out on large items.
@@ end

@@ item 4 implementability decision B material
@@ finding implementability 1
@@ why One file cannot hold the largest exports
@@ option A One file
@@ summary The export writes one compressed file
@@ anchor
The export writes one file.
@@ replace
The export writes one compressed file.
@@ end
@@ option B One file per widget
@@ summary The export writes one file per widget
@@ anchor
The export writes one file.
@@ replace
The export writes one file per widget.
@@ end

@@ item 5 implementability resolved
@@ finding implementability 2
@@ resolved-by 4
"""


def test_the_worked_example_s_view(root, capsys):
    d = root / "round"
    d.mkdir()
    (d / "spec.md").write_text(WORKED_BODY)
    (d / "batch.md").write_text(WORKED_BATCH)
    (d / "lens-consistency.md").write_text(
        "@@ finding 1\nThe body says widget where the glossary says item.\n")
    (d / "lens-testability.md").write_text(
        "@@ finding 1\nThe seam names no store to test against.\n")
    (d / "lens-implementability.md").write_text(
        "@@ finding 1\nOne file cannot hold the largest exports.\nThe store caps a file at 2 GB.\n"
        "@@ finding 2\nOne file is written before every page is fetched.\n")

    assert_passes(root, capsys, d, """## The batch

### Lenses

- Fidelity: not run - standalone review, no plan to check against
- Consistency: ran
- Testability: ran
- Implementability: ran

- **1** - **Consolidation** - Failed pages are retried once (apply) - A page that fails once should not fail the whole export
- **2** - **Testability** - The seam's test runs against a fake store (apply) - The seam names no store to test against
- **4** - **Implementability** (decision, option B recommended) - One file cannot hold the largest exports
  - Option A - One file: The export writes one compressed file
  - Option B - One file per widget (recommended): The export writes one file per widget

### Minor edits

- **3** - Consistency: Widgets renamed items - recommend decline: the glossary's term is widget, as the body says
- **5** - Implementability: resolved by item 4
""", passes(5, 5) + nudge(d))


def test_a_flow_batch_shows_a_fenced_edit_as_its_summary_and_reason_alone(root, capsys):
    d = root / "round"
    d.mkdir()
    (d / "spec.md").write_text("# Sync\n\nRun sync nightly:\n```sh\norch sync\n```\n")
    (d / "batch.md").write_text("""@@ lens fidelity ran
@@ lens consistency ran
@@ lens testability not-run timed out twice
@@ lens implementability ran

@@ item 1 contradicts-the-plan apply material
@@ finding fidelity 1
@@ summary Sync runs hourly, as the plan decided
@@ why The plan decided hourly
@@ anchor
Run sync nightly:
```sh
orch sync
```
@@ replace
Run sync hourly:
```sh
orch sync --hourly
```
@@ end
""")
    (d / "lens-fidelity.md").write_text("@@ finding 1\nThe plan decided hourly; the spec says nightly.\n")
    (d / "lens-consistency.md").write_text("@@ none\n")
    (d / "lens-implementability.md").write_text("@@ none\n")

    assert_passes(root, capsys, d, """## The batch

### Lenses

- Fidelity: ran
- Consistency: ran
- Testability: not run - timed out twice
- Implementability: ran

- **1** - **Contradicts the plan** - Sync runs hourly, as the plan decided (apply) - The plan decided hourly
""", passes(1, 1) + nudge(d))


def test_a_malformed_state_json_does_not_matter_and_github_is_never_reached(root, capsys):
    d = round_dir(root)
    (root / ".orchestrator").mkdir()
    (root / ".orchestrator" / "state.json").write_text("{not json")

    # No gh adapter is handed in: a gh call would reach the real-gh guard.
    assert check(root, d) == 0


def test_the_body_read_is_spec_fetched_md_when_it_exists(root, capsys):
    d = round_dir(root)
    (d / "spec.md").write_text(SRC_BODY.replace("Alpha line.", "Alpha prime line."))
    (d / "spec.fetched.md").write_text(SRC_BODY)

    assert check(root, d) == 0

    assert capsys.readouterr().err == passes(4, 4, "spec.fetched.md") + nudge(d) + "\n"


def test_an_anchor_spec_md_has_but_spec_fetched_md_lacks_is_refused(root, capsys):
    d = round_dir(root)
    (d / "spec.fetched.md").write_text(SRC_BODY.replace("Alpha line.", "Alpha moved."))

    assert_refused(root, capsys, d,
                   "orch: batch.md line 9: item 1: its anchor matches no text in the body\n")


# --- literal item numbers (#1339) ---------------------------------------------------


def test_every_item_is_listed_under_its_literal_batch_md_number(root, capsys):
    d = root / "round"
    d.mkdir()
    (d / "spec.md").write_text("# Spec\n\n" + "".join(
        "Line %s.\n" % w for w in ("one", "two", "three", "four", "five", "seven", "eight",
                                   "nine", "ten")))
    minor = "@@ item {n} {lens} apply minor\n@@ finding {lens} {k}\n@@ summary {W} edited\n" \
        "@@ anchor\nLine {w}.\n@@ replace\nLine {w}, edited.\n@@ end\n"
    material = "@@ item {n} {lens} apply material\n@@ finding {lens} {k}\n@@ summary {W} edited\n" \
        "@@ why {W} is stale\n@@ anchor\nLine {w}.\n@@ replace\nLine {w}, edited.\n@@ end\n"
    (d / "batch.md").write_text(
        "@@ lens fidelity ran\n@@ lens consistency ran\n@@ lens testability ran\n"
        "@@ lens implementability ran\n\n"
        + material.format(n=1, lens="fidelity", k=1, W="One", w="one")
        + minor.format(n=2, lens="fidelity", k=2, W="Two", w="two")
        + "@@ item 3 consistency decline material the plan chose three\n"
          "@@ finding consistency 1\n@@ summary Three edited\n@@ why Three contradicts the plan\n"
          "@@ anchor\nLine three.\n@@ replace\nLine three, edited.\n@@ end\n"
        + "@@ item 4 consistency decline minor the body says four\n@@ finding consistency 2\n"
          "@@ summary Four edited\n@@ anchor\nLine four.\n@@ replace\nLine four, edited.\n@@ end\n"
        + "@@ item 5 testability decision B material\n@@ finding testability 1\n"
          "@@ why Five is untestable\n@@ option A Keep five\n@@ summary Five kept\n@@ anchor\n"
          "Line five.\n@@ replace\nLine five, kept.\n@@ end\n@@ option B Drop five\n"
          "@@ summary Five dropped\n@@ anchor\nLine five.\n@@ replace\nLine five, dropped.\n"
          "@@ end\n"
        + "@@ item 6 testability resolved\n@@ finding testability 2\n@@ resolved-by 5\n"
        + minor.format(n=7, lens="implementability", k=1, W="Seven", w="seven")
        + minor.format(n=8, lens="implementability", k=2, W="Eight", w="eight")
        + minor.format(n=9, lens="implementability", k=3, W="Nine", w="nine")
        + material.format(n=10, lens="implementability", k=4, W="Ten", w="ten"))
    (d / "lens-fidelity.md").write_text("@@ finding 1\nOne.\n@@ finding 2\nTwo.\n")
    (d / "lens-consistency.md").write_text("@@ finding 1\nThree.\n@@ finding 2\nFour.\n")
    (d / "lens-testability.md").write_text("@@ finding 1\nFive.\n@@ finding 2\nSix.\n")
    (d / "lens-implementability.md").write_text(
        "@@ finding 1\nSeven.\n@@ finding 2\nEight.\n@@ finding 3\nNine.\n@@ finding 4\nTen.\n")

    assert check(root, d) == 0

    out = capsys.readouterr().out
    assert out == """## The batch

### Lenses

- Fidelity: ran
- Consistency: ran
- Testability: ran
- Implementability: ran

- **1** - **Fidelity** - One edited (apply) - One is stale
- **3** - **Consistency** - Three edited (recommend decline: the plan chose three) - Three contradicts the plan
- **5** - **Testability** (decision, option B recommended) - Five is untestable
  - Option A - Keep five: Five kept
  - Option B - Drop five (recommended): Five dropped
- **10** - **Implementability** - Ten edited (apply) - Ten is stale

### Minor edits

- **2** - Fidelity: Two edited
- **4** - Consistency: Four edited - recommend decline: the body says four
- **6** - Testability: resolved by item 5
- **7** - Implementability: Seven edited
- **8** - Implementability: Eight edited
- **9** - Implementability: Nine edited
"""
    assert not re.search(r"(?m)^[0-9]+\. ", out)


# --- the batch's violations ---------------------------------------------------------

W30 = "  ".join("w%d" % k for k in range(1, 31))
W31 = W30 + "\tw31"


def refused(*lines):
    return "".join("orch: %s\n" % line for line in lines)


@pytest.mark.parametrize("changes, err", [
    # Marks.
    ({6: ["@@ item 1 fidelity apply"]},
     ["batch.md line 6: @@ item 1 ... apply needs its mark, material or minor"]),
    ({15: ["@@ item 2 consistency decline the plan chose this"]},
     ["batch.md line 15: item 2's mark must be material or minor, got 'the'"]),
    ({6: ["@@ item 1 fidelity apply major"]},
     ["batch.md line 6: item 1's mark must be material or minor, got 'major'"]),
    ({41: ["@@ item 4 testability resolved minor"]},
     ["batch.md line 41: @@ item 4 ... a resolved item carries no mark"]),
    ({24: ["@@ item 3 testability decision A minor"]},
     ["batch.md line 24: decision item 3 is always material, never minor"]),
    ({6: ["@@ item 1 contradicts-the-plan apply minor"]},
     ["batch.md line 6: contradicts-the-plan item 1 is always material, never minor"]),
    ({15: ["@@ item 2 consistency decline fundamental the plan chose this"]},
     ["batch.md line 15: item 2's mark must be material or minor, got 'fundamental' - the mark"
      " is accepted only in an autopilot flow"]),
    # @@ why (#1248).
    ({23: [""]}, ["batch.md line 15: item 2 has no @@ why"]),
    ({26: []}, ["batch.md line 24: item 3 has no @@ why"]),
    ({23: ["@@ why"]}, ["batch.md line 23: @@ why needs its line"]),
    ({14: ["@@ why Alpha is stale"]}, ["batch.md line 14: a minor item carries no @@ why"]),
    ({43: [..., "@@ why Gamma again"]}, ["batch.md line 44: a resolved item carries no @@ why"]),
    ({26: [], 27: [..., "@@ why Gamma must be testable"]},
     ["batch.md line 27: @@ why belongs to the item, never under an @@ option"]),
    ({16: [..., "@@ why Beta again"]}, ["batch.md line 24: a second @@ why for this item"]),
    # The summary cap (#1352).
    ({17: ["@@ summary " + W31]},
     ["batch.md line 17: item 2's @@ summary has 31 words, more than 30"]),
    ({35: ["@@ summary " + W31]},
     ["batch.md line 35: item 3 option B's @@ summary has 31 words, more than 30"]),
    # Anchors: each problem once, every one in one run, each naming its line.
    ({10: ["Twice."]},
     ["batch.md line 9: item 1: its anchor matches more than one place in the body"]),
    ({10: [..., "Beta line."]},
     ["batch.md line 19: item 2: its anchor no longer matches exactly once after the earlier"
      " items' edits"]),
    ({37: ["Nowhere either."]},
     ["batch.md line 36: item 3 option B: its anchor matches no text in the body"]),
    ({10: ["Nowhere."], 19: ["Twice."], 37: ["Nowhere either."]},
     ["batch.md line 9: item 1: its anchor matches no text in the body",
      "batch.md line 18: item 2: its anchor matches more than one place in the body",
      "batch.md line 36: item 3 option B: its anchor matches no text in the body"]),
    ({19: ["Nowhere."]}, ["batch.md line 18: item 2: its anchor matches no text in the body"]),
    # One run reports every violation it can stand behind (#3456).
    ({17: ["@@ summary " + W31], 35: ["@@ summary " + W31]},
     ["batch.md line 17: item 2's @@ summary has 31 words, more than 30",
      "batch.md line 35: item 3 option B's @@ summary has 31 words, more than 30"]),
    ({10: ["Nowhere."], 16: ["@@ finding consistency 2"], 17: ["@@ summary " + W31], 23: []},
     ["batch.md line 17: item 2's @@ summary has 31 words, more than 30",
      "batch.md line 15: item 2 has no @@ why",
      "batch.md line 16: cites finding 2 of lens consistency, but lens-consistency.md holds 1",
      "batch.md leaves findings uncited: consistency 1 - every lens finding goes in the batch,"
      " if only as a recommend-decline item",
      "batch.md line 9: item 1: its anchor matches no text in the body"]),
    ({10: ["Nowhere."], 16: ["@@ finding consistency 2"], 42: ["@@ finding testability 3"]},
     ["batch.md line 16: cites finding 2 of lens consistency, but lens-consistency.md holds 1",
      "batch.md line 42: cites finding 3 of lens testability, but lens-testability.md holds 2",
      "batch.md leaves findings uncited: consistency 1, testability 2 - every lens finding goes"
      " in the batch, if only as a recommend-decline item",
      "batch.md line 9: item 1: its anchor matches no text in the body"]),
    ({6: ["@@ item 1 fidelity apply minor", "@@ finding fidelity 1"],
      8: [], 9: [], 10: [], 11: [], 12: [], 13: []},
     ["batch.md line 6: item 1 has no @@ summary",
      "batch.md line 6: item 1 has no @@ anchor/@@ replace/@@ end block"]),
    ({17: ["@@ summary " + W31], 23: ["@@ bogus"]},
     ["batch.md line 17: item 2's @@ summary has 31 words, more than 30",
      "batch.md line 23: unknown line '@@ bogus'"]),
    ({2: [], 17: ["@@ summary " + W31]},
     ["batch.md line 16: item 2's @@ summary has 31 words, more than 30",
      "batch.md: no @@ lens line for consistency - every lens in the table has one"]),
    ({7: ["@@ bogus"], 17: ["@@ summary " + W31]}, ["batch.md line 7: unknown line '@@ bogus'"]),
    # Grammar: the first error only.
    ({7: ["@@ bogus"], 16: ["@@ bogus"]}, ["batch.md line 7: unknown line '@@ bogus'"]),
    # Citations.
    ({42: ["@@ finding testability 3"]},
     ["batch.md line 42: cites finding 3 of lens testability, but lens-testability.md holds 2",
      "batch.md leaves findings uncited: testability 2 - every lens finding goes in the batch,"
      " if only as a recommend-decline item"]),
    ({2: []}, ["batch.md: no @@ lens line for consistency - every lens in the table has one"]),
    # The @@ block reader (#2568).
    ({10: ["  "]}, ["batch.md line 9: the anchor is empty"]),
])
def test_a_batch_violation_is_refused_naming_its_line(root, capsys, changes, err):
    d = round_dir(root)
    rewrite(d / "batch.md", changes)

    assert_refused(root, capsys, d, refused(*err))


# Every other refusal of the batch and of a lens findings file, each line as
# the bash spec-review check prints it for the same batch. A lens file given
# as None is removed.
@pytest.mark.parametrize("changes, lenses, err", [
    ({16: [..., "@@ lens fidelity ran"]}, {},
     ["batch.md line 17: the @@ lens lines come first, before any item"]),
    ({1: ["@@ lens clarity ran"]}, {},
     ["batch.md line 1: unknown lens 'clarity' (want one of: fidelity consistency"
      " testability implementability)"]),
    ({2: ["@@ lens fidelity ran"]}, {},
     ["batch.md line 2: a second @@ lens line for fidelity"]),
    ({1: ["@@ lens fidelity ran now"]}, {},
     ["batch.md line 1: @@ lens fidelity ran takes nothing after it"]),
    ({2: ["@@ lens consistency standalone"]}, {},
     ["batch.md line 2: only fidelity can be standalone"]),
    ({4: ["@@ lens implementability not-run"]}, {},
     ["batch.md line 4: @@ lens implementability not-run needs a reason"]),
    ({4: ["@@ lens implementability skipped"]}, {},
     ["batch.md line 4: @@ lens implementability wants ran, not-run <reason> or"
      " standalone"]),
    ({6: ["@@ item 0 fidelity apply minor"]}, {},
     ["batch.md line 6: item number must be a positive number, got '0'"]),
    ({6: ["@@ item 01 fidelity apply minor"]}, {},
     ["batch.md line 6: item number must be a positive number, got '01'"]),
    ({15: ["@@ item 1 consistency decline material the plan chose this"]}, {},
     ["batch.md line 15: a second item 1"]),
    ({6: ["@@ item 1 clarity apply minor"]}, {},
     ["batch.md line 6: unknown group 'clarity' (want consolidation, a lens, or"
      " contradicts-the-plan)"]),
    ({6: ["@@ item 1 fidelity apply minor now"]}, {},
     ["batch.md line 6: @@ item 1 ... apply takes nothing after its mark"]),
    ({41: ["@@ item 4 testability resolved because"]}, {},
     ["batch.md line 41: @@ item 4 ... resolved takes nothing after it"]),
    ({15: ["@@ item 2 consistency decline material"]}, {},
     ["batch.md line 15: @@ item 2 ... decline needs a reason after its mark"]),
    ({24: ["@@ item 3 testability decision a material"]}, {},
     ["batch.md line 24: @@ item 3 ... decision needs the recommended option's letter,"
      " A to Z"]),
    ({24: ["@@ item 3 testability decision A material now"]}, {},
     ["batch.md line 24: @@ item 3 ... decision takes nothing after its mark"]),
    ({6: ["@@ item 1 fidelity accept minor"]}, {},
     ["batch.md line 6: item 1's recommendation must be apply <mark>, decline <mark>"
      " <reason>, decision <letter> <mark> or resolved"]),
    ({8: ["@@ summary"]}, {},
     ["batch.md line 8: @@ summary needs its line"]),
    ({43: [..., "@@ summary Resolved"]}, {},
     ["batch.md line 44: a resolved item carries no @@ summary"]),
    ({26: [..., "@@ summary Gamma"]}, {},
     ["batch.md line 27: a decision item's summaries go under its options"]),
    ({8: [..., "@@ summary Again"]}, {},
     ["batch.md line 9: a second @@ summary for this item"]),
    ({28: [..., "@@ summary Again"]}, {},
     ["batch.md line 29: a second @@ summary for this option"]),
    ({7: ["@@ finding fidelity"]}, {},
     ["batch.md line 7: @@ finding wants <lens> <k>, k a positive number"]),
    ({7: ["@@ finding fidelity 1 2"]}, {},
     ["batch.md line 7: @@ finding wants <lens> <k>"]),
    ({7: ["@@ finding fidelity 0"]}, {},
     ["batch.md line 7: @@ finding wants <lens> <k>, k a positive number"]),
    ({7: ["@@ comment alice 2026"]}, {},
     ["batch.md line 7: @@ comment wants @<login> <createdAt>"]),
    ({7: ["@@ comment @alice"]}, {},
     ["batch.md line 7: @@ comment wants @<login> <createdAt>"]),
    ({7: ["@@ comment @alice 2026-01-01T00:00:00Z"]}, {},
     ["batch.md line 8: @@ comment must be followed by @@ quote"]),
    ({7: [..., "@@ quote"]}, {},
     ["batch.md line 8: @@ quote must follow @@ comment"]),
    ({7: [..., "@@ comment @alice 2026", "@@ quote now"]}, {},
     ["batch.md line 9: @@ quote takes nothing after it; the quote is the lines below"
      " it"]),
    ({43: [..., "@@ comment @alice 2026"]}, {},
     ["batch.md line 44: @@ comment must be followed by @@ quote"]),
    ({43: [..., "@@ resolved-by 3"]}, {},
     ["batch.md line 44: a second @@ resolved-by"]),
    ({8: [..., "@@ resolved-by 3"]}, {},
     ["batch.md line 9: @@ resolved-by belongs to a resolved item"]),
    ({43: ["@@ resolved-by 9"]}, {},
     ["batch.md line 43: @@ resolved-by names '9', which is no earlier item"]),
    ({43: ["@@ resolved-by 4"]}, {},
     ["batch.md line 43: @@ resolved-by names '4', which is no earlier item"]),
    ({43: ["@@ resolved-by"]}, {},
     ["batch.md line 43: @@ resolved-by names '', which is no earlier item"]),
    ({8: [..., "@@ option A x"]}, {},
     ["batch.md line 9: @@ option belongs to a decision item"]),
    ({27: ["@@ option a Keep gamma"]}, {},
     ["batch.md line 27: @@ option wants <letter> <label>, the letter A to Z"]),
    ({27: ["@@ option A"]}, {},
     ["batch.md line 27: @@ option A needs a label"]),
    ({34: ["@@ option A Drop gamma"]}, {},
     ["batch.md line 34: a second option A"]),
    ({9: ["@@ anchor now"]}, {},
     ["batch.md line 9: @@ anchor takes nothing after it; the anchor is the lines"
      " below it"]),
    ({43: [..., "@@ anchor"]}, {},
     ["batch.md line 44: a resolved item takes no @@ anchor, @@ replace or @@ end"]),
    ({43: [..., "@@ replace"]}, {},
     ["batch.md line 44: a resolved item takes no @@ anchor, @@ replace or @@ end"]),
    ({26: [..., "@@ anchor"]}, {},
     ["batch.md line 27: a decision item's anchors go under its options"]),
    ({33: [..., "@@ anchor"]}, {},
     ["batch.md line 34: a second @@ anchor for this option"]),
    ({13: [..., "@@ anchor"]}, {},
     ["batch.md line 14: a second @@ anchor for this item"]),
    ({5: ["@@ summary x"]}, {},
     ["batch.md line 5: @@ summary outside an item"]),
    ({5: ["stray"]}, {},
     ["batch.md line 5: text outside an @@ anchor, @@ replace or @@ quote block"]),
    ({43: []}, {},
     ["batch.md line 41: resolved item 4 has no @@ resolved-by line"]),
    ({34: [], 35: [], 36: [], 37: [], 38: [], 39: [], 40: []}, {},
     ["batch.md line 24: decision item 3 needs at least two @@ option blocks"]),
    ({24: ["@@ item 3 testability decision C material"]}, {},
     ["batch.md line 24: decision item 3 recommends option C, which it does not have"]),
    ({35: []}, {},
     ["batch.md line 34: item 3 option B has no @@ summary"]),
    ({36: [], 37: [], 38: [], 39: [], 40: []}, {},
     ["batch.md line 34: item 3 option B has no @@ anchor/@@ replace/@@ end block - an"
      " option not recommended still carries the edit it would make"]),
    ({29: [], 30: [], 31: [], 32: [], 33: []}, {},
     ["batch.md line 27: item 3 option A has no @@ anchor/@@ replace/@@ end block"]),
    ({18: [], 19: [], 20: [], 21: [], 22: []}, {},
     ["batch.md line 15: item 2 has no @@ anchor/@@ replace/@@ end block - a decline"
      " item still carries the edit it declines"]),
    ({6: ["@@ item 1 consolidation apply minor"]}, {},
     ["batch.md line 6: consolidation item 1 cites no @@ comment"]),
    ({7: []}, {},
     ["batch.md line 6: item 1 cites no @@ finding",
      "batch.md leaves findings uncited: fidelity 1 - every lens finding goes in the"
      " batch, if only as a recommend-decline item"]),
    ({7: ["@@ finding clarity 1"]}, {},
     ["batch.md line 7: unknown lens 'clarity'",
      "batch.md leaves findings uncited: fidelity 1 - every lens finding goes in the"
      " batch, if only as a recommend-decline item"]),
    ({7: ["@@ finding implementability 1"]}, {},
     ["batch.md line 7: cites lens implementability, which did not run",
      "batch.md leaves findings uncited: fidelity 1 - every lens finding goes in the"
      " batch, if only as a recommend-decline item"]),
    ({6: ["@@ item 1 implementability apply minor"]}, {},
     ["batch.md line 6: item 1 is in group implementability, which did not run"]),
    ({}, {"fidelity": None},
     ["lens-fidelity.md not found in {d} - lens fidelity is marked ran in batch.md"]),
    ({}, {"consistency": "@@ none\n@@ none\n"},
     ["lens-consistency.md line 2: @@ none stands alone in its file"]),
    ({}, {"consistency": "@@ finding 1\nx\n@@ none\n"},
     ["lens-consistency.md line 3: @@ none stands alone in its file"]),
    ({}, {"consistency": "@@ none\n@@ finding 1\nx\n"},
     ["lens-consistency.md line 2: @@ none stands alone in its file"]),
    ({}, {"consistency": "@@ finding 1\n\n@@ finding 2\nx\n"},
     ["lens-consistency.md line 3: finding 1 is empty"]),
    ({}, {"consistency": "@@ finding 2\nx\n"},
     ["lens-consistency.md line 1: expected @@ finding 1, got '@@ finding 2'"]),
    ({}, {"consistency": "@@ finding 1\nx\n@@ bogus\n"},
     ["lens-consistency.md line 3: unknown line '@@ bogus' (want @@ finding <k> or @@"
      " none)"]),
    ({}, {"consistency": "@@ finding 1\n  \n"},
     ["lens-consistency.md line 2: finding 1 is empty"]),
    ({}, {"consistency": ""},
     ["lens-consistency.md holds no @@ finding and no @@ none"]),
    ({}, {"consistency": "\n\n"},
     ["lens-consistency.md holds no @@ finding and no @@ none"]),
    ({}, {"consistency": "@@ none\nx\n"},
     ["lens-consistency.md line 2: text before the first @@ finding"]),
])
def test_every_batch_and_lens_file_refusal_is_bash_s(root, capsys, changes, lenses, err):
    d = round_dir(root)
    rewrite(d / "batch.md", changes)
    for lens, text in lenses.items():
        path = d / ("lens-%s.md" % lens)
        if text is None:
            path.unlink()
        else:
            path.write_text(text)

    assert_refused(root, capsys, d, refused(*(line.format(d=d) for line in err)))


def test_thirty_word_summaries_pass(root, capsys):
    d = round_dir(root)
    rewrite(d / "batch.md", {17: ["@@ summary " + W30], 35: ["@@ summary " + W30]})

    assert check(root, d) == 0


def test_the_fundamental_mark_is_read_as_material_in_an_autopilot_flow(root, capsys):
    d = round_dir(root)
    rewrite(d / "batch.md", {15: ["@@ item 2 consistency decline fundamental the plan chose this"]})

    assert check(root, d, env={"ORCH_AUTOPILOT": "1"}) == 0

    assert capsys.readouterr().out == SRC_VIEW


def test_a_resolved_item_refuses_the_fundamental_mark_in_an_autopilot_flow(root, capsys):
    d = round_dir(root)
    rewrite(d / "batch.md", {41: ["@@ item 4 testability resolved fundamental"]})

    assert check(root, d, env={"ORCH_AUTOPILOT": "1"}) == 1

    assert capsys.readouterr().err == refused(
        "batch.md line 41: @@ item 4 ... a resolved item carries no mark")


def test_a_malformed_lens_file_is_refused(root, capsys):
    d = round_dir(root)
    (d / "lens-consistency.md").write_text("preamble\n@@ finding 1\nx\n")

    assert_refused(root, capsys, d,
                   refused("lens-consistency.md line 1: text before the first @@ finding"))


def test_a_malformed_lens_file_after_a_content_violation_prints_both(root, capsys):
    d = round_dir(root)
    rewrite(d / "batch.md", {17: ["@@ summary " + W31]})
    (d / "lens-consistency.md").write_text("preamble\n@@ finding 1\nx\n")

    assert_refused(root, capsys, d, refused(
        "batch.md line 17: item 2's @@ summary has 31 words, more than 30",
        "lens-consistency.md line 1: text before the first @@ finding"))


def test_no_batch_md_is_refused(root, capsys):
    d = round_dir(root)
    (d / "batch.md").unlink()

    assert_refused(root, capsys, d, refused("batch.md not found in %s" % d))


# --- every finding cited (#1914) ----------------------------------------------------


def test_a_batch_leaving_findings_uncited_is_refused_naming_each_in_lens_order(root, capsys):
    d = root / "round"
    d.mkdir()
    (d / "spec.md").write_text("# Spec\n\nAlpha line.\nBeta line.\nGamma line.\n")
    (d / "batch.md").write_text("""@@ lens fidelity not-run timed out
@@ lens consistency ran
@@ lens testability ran
@@ lens implementability not-run timed out

@@ item 1 consistency apply minor
@@ finding consistency 1
@@ summary Alpha primed
@@ anchor
Alpha line.
@@ replace
Alpha prime line.
@@ end
""")
    (d / "lens-consistency.md").write_text("@@ finding 1\nFinding 1.\n@@ finding 2\nFinding 2.\n")
    (d / "lens-testability.md").write_text("@@ finding 1\nFinding 1.\n")

    assert_refused(root, capsys, d, refused(
        "batch.md leaves findings uncited: consistency 2, testability 1 - every lens finding"
        " goes in the batch, if only as a recommend-decline item"))


# --- CRLF ---------------------------------------------------------------------------


def crlf(path):
    """<path> with CR on every line."""
    path.write_text(path.read_text().replace("\n", "\r\n"))


def append(path, text):
    with open(str(path), "a") as f:
        f.write(text)


def test_a_batch_with_crlf_on_every_line_passes_as_its_lf_twin(root, capsys):
    d = round_dir(root)
    crlf(d / "batch.md")

    assert_passes(root, capsys, d, SRC_VIEW, passes(4, 4) + nudge(d))


@pytest.mark.parametrize("changes, tail, err", [
    ({13: []}, "",
     "batch.md line 14: expected @@ end to end the replacement begun on line 11, got '@@ item 2"
     " consistency decline material the plan chose this' - a body line starting with @@ is"
     " written \\@@"),
    ({}, "@@ bogus\n", "batch.md line 44: unknown line '@@ bogus'"),
    ({}, "@@\n", "batch.md line 44: unknown line '@@ '"),
    ({19: ["Nowhere."]}, "", "batch.md line 18: item 2: its anchor matches no text in the body"),
])
def test_a_crlf_batch_is_refused_as_its_lf_twin_quoting_no_cr(root, capsys, changes, tail, err):
    d = round_dir(root)
    rewrite(d / "batch.md", changes)
    append(d / "batch.md", tail)
    crlf(d / "batch.md")

    assert_refused(root, capsys, d, refused(err))


def consolidation_quote_dir(root):
    """The fixture batch with item 1 a material consolidation item folding
    in one comment."""
    d = round_dir(root)
    rewrite(d / "batch.md", {
        6: ["@@ item 1 consolidation apply material"],
        7: [..., "@@ comment @alice 2026-01-02T00:00:00Z", "@@ quote", "Alpha should say",
            "alpha prime."],
        13: [..., "@@ why Alpha folds in the comment"]})
    return d


CONSOLIDATION_FULL_1 = """
### Item 1 - Consolidation

**Recommendation:** apply

**Finding** (Fidelity 1):

> Alpha is stale.

**Comment** by @alice, 2026-01-02T00:00:00Z:

> Alpha should say
> alpha prime.

**Current**

```
Alpha line.
```

**Proposed**

```
Alpha prime line.
```
"""


def test_a_comment_s_quote_renders_in_full(root, capsys):
    d = consolidation_quote_dir(root)

    assert_passes(root, capsys, d, CONSOLIDATION_FULL_1, passes(4, 4) + nudge(d), "--full", 1)


def test_a_crlf_quote_renders_as_its_lf_twin_with_no_cr(root, capsys):
    d = consolidation_quote_dir(root)
    crlf(d / "batch.md")

    assert_passes(root, capsys, d, CONSOLIDATION_FULL_1, passes(4, 4) + nudge(d), "--full", 1)


def test_a_body_fetched_from_crlf_matches_a_two_line_anchor(root, seed, capsys):
    d = root / "round"
    d.mkdir()
    seed.issue(14, "open")
    seed.body(14, "# Spec\r\n\r\nAlpha line.\r\nBeta line.\r\n")
    assert orch_issue(seed, "fetch", "14", str(d / "spec.md")) == 0
    (d / "batch.md").write_text("""@@ lens fidelity ran
@@ lens consistency not-run timed out
@@ lens testability not-run timed out
@@ lens implementability not-run timed out

@@ item 1 fidelity apply minor
@@ finding fidelity 1
@@ summary Merge the two lines
@@ anchor
Alpha line.
Beta line.
@@ replace
Alpha and Beta line.
@@ end
""")
    (d / "lens-fidelity.md").write_text("@@ finding 1\nMerge them.\n")
    capsys.readouterr()

    assert check(root, d) == 0

    assert capsys.readouterr().err == passes(1, 1) + nudge(d) + "\n"


# --- escaped @@ lines (#1945) and the block reader (#2568) --------------------------

SRE_BODY = "# Spec\n\nAlpha line.\n@@ note <text>\n\\@@ keep\n\\x stays\n@@x stays\n@@-1 stays\nOmega.\n"
SRE_ITEM = "@@ item 1 fidelity apply minor\n@@ finding fidelity 1\n@@ summary Reword the quoted line"


def sre_dir(root, items):
    """A one-lens round directory holding the escape cases' body, the fixed
    lens lines, <items> and one lens finding."""
    d = root / "round"
    d.mkdir()
    (d / "spec.md").write_text(SRE_BODY)
    (d / "batch.md").write_text(
        "@@ lens fidelity ran\n@@ lens consistency not-run timed out\n"
        "@@ lens testability not-run timed out\n@@ lens implementability not-run timed out\n\n"
        + items + "\n")
    (d / "lens-fidelity.md").write_text("@@ finding 1\nReword.\n")
    return d


def quote_item(line):
    return "\n".join(["@@ item 1 consolidation apply minor", "@@ comment @bob 2026-01-01T00:00:00Z",
                      "@@ quote", line, "@@ summary Add a line", "@@ anchor", "Alpha line.",
                      "@@ replace", "Alpha line.", "Beta.", "@@ end"])


QUOTE_TAIL = ("\n@@ anchor\nAlpha line.\n@@ replace\nNew.\n@@ end\n"
              "@@ comment @bob 2026-01-01T00:00:00Z\n@@ quote")


def test_an_escaped_anchor_and_replacement_render_unescaped_and_crlf_as_lf(root, capsys):
    d = sre_dir(root, SRE_ITEM + "\n@@ anchor\n\\@@ note <text>\n@@ replace\n\\@@ remark <text>\n"
                "@@ end")
    view = """
### Item 1 - Fidelity

**Recommendation:** apply

**Finding** (Fidelity 1):

> Reword.

**Current**

```
@@ note <text>
```

**Proposed**

```
@@ remark <text>
```
"""
    assert_passes(root, capsys, d, view, passes(1, 1) + nudge(d), "--full", 1)
    crlf(d / "batch.md")

    assert_passes(root, capsys, d, view, passes(1, 1) + nudge(d), "--full", 1)


def test_backslash_forms_that_are_not_an_escaped_at_line_stay(root, capsys):
    d = sre_dir(root, SRE_ITEM + "\n@@ anchor\n\\\\@@ keep\n\\x stays\n@@x stays\n@@-1 stays\n"
                "@@ replace\n\\\\\\@@ kept\n\\y stays\n@@z\n@@ end")

    assert check(root, d, "--full", 1) == 0

    out = capsys.readouterr().out
    assert "```\n\\@@ keep\n\\x stays\n@@x stays\n@@-1 stays\n```" in out
    assert "```\n\\\\@@ kept\n\\y stays\n@@z\n```" in out


def test_an_escaped_quote_line_folds_in_unescaped(root, capsys):
    d = sre_dir(root, quote_item("\\@@ note <text>"))
    (d / "lens-fidelity.md").write_text("@@ none\n")

    assert check(root, d, "--full", 1) == 0

    out = capsys.readouterr().out
    assert "> @@ note <text>\n" in out
    assert "\\@@" not in out


def test_an_unescaped_at_line_in_a_quote_ends_it_empty_with_no_escape_hint(root, capsys):
    d = sre_dir(root, quote_item("@@ note <text>"))
    (d / "lens-fidelity.md").write_text("@@ none\n")

    assert_refused(root, capsys, d, refused("batch.md line 8: the quote is empty"))


def test_a_quote_running_to_end_of_file_passes(root, capsys):
    d = sre_dir(root, SRE_ITEM + QUOTE_TAIL + "\nQuoted words.")

    assert check(root, d, "--full", 1) == 0

    assert "> Quoted words.\n" in capsys.readouterr().out


@pytest.mark.parametrize("items, err", [
    (SRE_ITEM + "\n@@ anchor\n@@ note <text>\n@@ replace\nNew.\n@@ end",
     "batch.md line 10: expected @@ replace to end the anchor begun on line 9, got '@@ note"
     " <text>' - a body line starting with @@ is written \\@@"),
    (SRE_ITEM + "\n@@ anchor\nAlpha line.\n@@ replace\n@@ note <text>\n@@ end",
     "batch.md line 12: expected @@ end to end the replacement begun on line 11, got '@@ note"
     " <text>' - a body line starting with @@ is written \\@@"),
    (SRE_ITEM + "\n@@ anchor\nAlpha line.", "batch.md line 9: the @@ anchor block is never ended"),
    (SRE_ITEM + "\n@@ anchor\nAlpha line.\n@@ replace\nNew.",
     "batch.md line 11: the @@ replace block is never ended"),
    (SRE_ITEM + "\n@@ replace", "batch.md line 9: @@ replace with no @@ anchor open"),
    (SRE_ITEM + "\n@@ end", "batch.md line 9: @@ end with no @@ anchor open"),
    (SRE_ITEM + QUOTE_TAIL + "\n  ", "batch.md line 15: the quote is empty"),
    (quote_item("   "), "batch.md line 8: the quote is empty"),
])
def test_a_malformed_block_is_refused_naming_its_line(root, capsys, items, err):
    d = sre_dir(root, items)

    assert_refused(root, capsys, d, refused(err))


# --- --full -------------------------------------------------------------------------

FULL_4_1_2 = """
### Item 4 - Testability

**Recommendation:** resolved by item 3

**Finding** (Testability 2):

> Gamma again.

### Item 1 - Fidelity

**Recommendation:** apply

**Finding** (Fidelity 1):

> Alpha is stale.

**Current**

```
Alpha line.
```

**Proposed**

```
Alpha prime line.
```

### Item 2 - Consistency

**Recommendation:** recommend decline - the plan chose this

**Finding** (Consistency 1):

> Beta contradicts the plan.

**Current**

```
Beta line.
```

**Proposed**

```
Beta reversed.
```
"""


def test_full_prints_the_named_items_in_full_in_the_order_named(root, capsys):
    d = round_dir(root)

    assert_passes(root, capsys, d, FULL_4_1_2, passes(4, 4) + nudge(d), "--full", 4, 1, 2)
    assert not (d / "spec.fetched.md").exists()


def test_full_option_headings_carry_the_compact_view_s_label_and_mark(root, capsys):
    d = round_dir(root)

    assert check(root, d, "--full", 3) == 0

    out = capsys.readouterr().out
    assert re.findall(r"(?m)^#### .*$", out) == ["#### Option A - Keep gamma (recommended)",
                                                "#### Option B - Drop gamma"]
    assert "### Item 2" not in out
    assert "### Lenses" not in out


@pytest.mark.parametrize("args, err", [
    (["--full"], "--full needs at least one item number (%s)" % USAGE),
    (["--full", "9"], "--full 9: batch.md has no item 9"),
    (["--full", "2", "two"], "--full two: batch.md has no item two"),
    (["--full", "2", "--tickets"], "--full and --tickets do not combine (%s)" % USAGE),
    (["--tickets", "--full", "2"], "--full and --tickets do not combine (%s)" % USAGE),
    (["--full", "1", "--unattended"], "--full and --unattended do not combine (%s)" % USAGE),
    (["--unattended", "--full", "9"], "--full and --unattended do not combine (%s)" % USAGE),
])
def test_a_full_refusal_leaves_an_earlier_view_md_as_it_was(root, capsys, args, err):
    d = round_dir(root)
    (d / "view.md").write_text("an earlier view\n")

    assert_refused(root, capsys, d, refused(err), *args)


def test_full_on_a_bad_batch_refuses_as_check_does(root, capsys):
    d = round_dir(root)
    rewrite(d / "batch.md", {17: ["@@ summary " + W31]})
    (d / "view.md").write_text("old view\n")

    assert_refused(root, capsys, d,
                   refused("batch.md line 17: item 2's @@ summary has 31 words, more than 30"),
                   "--full", 1, 2)


# --- --unattended -------------------------------------------------------------------


def test_unattended_ends_the_pass_line_in_its_own_tail_with_the_same_view(root, capsys):
    d = round_dir(root)

    assert_passes(root, capsys, d, SRC_VIEW, passes(4, 4) + UNATTENDED_TAIL, "--unattended")


def test_a_failing_unattended_check_fails_as_without_the_flag(root, capsys):
    d = round_dir(root)
    (d / "batch.md").write_text("@@ item 1 material\n")
    (d / "view.md").write_text("an earlier view\n")
    assert check(root, d) == 1
    plain = capsys.readouterr()

    assert_refused(root, capsys, d, plain.err, "--unattended")


# --- view.md (#1293) ----------------------------------------------------------------


def test_full_overwrites_the_batch_view_s_view_md(root, capsys):
    d = round_dir(root)
    assert check(root, d) == 0
    capsys.readouterr()

    assert check(root, d, "--full", 2, 1) == 0

    out, err = capsys.readouterr()
    assert (d / "view.md").read_text() == out
    assert "## The batch" not in out
    assert "### Item 2 - Consistency" in out
    assert err == passes(4, 4) + nudge(d) + "\n"


def test_a_relative_dir_s_pass_line_names_view_md_by_absolute_path(root, capsys, monkeypatch):
    d = round_dir(root)
    monkeypatch.chdir(str(root))

    assert check(root, "round") == 0

    assert capsys.readouterr().err == passes(4, 4) + nudge("%s/round" % root) + "\n"
    assert (d / "view.md").read_text() == SRC_VIEW


def test_a_failing_check_after_a_passing_one_leaves_the_earlier_view_md(root, capsys):
    d = round_dir(root)
    assert check(root, d) == 0
    capsys.readouterr()
    rewrite(d / "batch.md", {19: ["Nowhere."]})

    assert_refused(root, capsys, d,
                   refused("batch.md line 18: item 2: its anchor matches no text in the body"))
    assert (d / "view.md").read_text() == SRC_VIEW


@pytest.mark.parametrize("args", [[], ["--full", "1"]])
def test_a_view_md_that_cannot_be_written_fails_before_any_view(root, capsys, args):
    d = round_dir(root)
    (d / "view.md").mkdir()

    assert check(root, d, *args) == 1

    assert capsys.readouterr() == ("", refused("could not write %s/view.md" % d))


# --- the arguments ------------------------------------------------------------------


@pytest.mark.parametrize("args, err", [
    ([], USAGE),
    (["{d}", "{d}"], USAGE),
    (["--full", "1", "{d}"], USAGE),
    (["{d}", "--bogus"], "unknown option: --bogus (%s)" % USAGE),
])
def test_a_usage_refusal(root, capsys, args, err):
    d = round_dir(root)

    assert check(root, *(a.format(d=d) for a in args)) == 1

    assert capsys.readouterr() == ("", refused(err))


def test_a_missing_directory_and_a_missing_body_are_refused(root, capsys):
    assert check(root, root / "nowhere/") == 1
    assert capsys.readouterr().err == refused("no such directory: %s/nowhere" % root)
    d = round_dir(root)
    (d / "spec.md").unlink()

    assert_refused(root, capsys, d, refused("spec.md not found in %s" % d))


# --- the nudge ----------------------------------------------------------------------


def bash_nudge_format():
    """The printf format of bash spec_review_nudge, in the bash spec-review
    module."""
    text = BASH_MODULE.read_text(encoding="utf-8")
    body = text.split("\nspec_review_nudge() {\n", 1)[1]
    return re.search(r"printf '([^']*)'", body).group(1)


@pytest.mark.skipif(not BASH_MODULE.exists(), reason="the bash spec-review module is gone")
def test_the_nudge_s_words_match_bash_spec_review_nudge_word_for_word():
    assert spec_review.NUDGE == bash_nudge_format()
