"""The spec-review noun's apply, run in-process against FakeGit and the gh
fake's store, with the checkout and its round directory under tmp_path: a
round's answer applied to the body as fetched, the body published when it
changed, the changelog written, posted and appended to settled.md, the
round-complete marker, the autopilot hold and its reply, the saved answer
and --resume, flow mode and standalone mode. Each call is checked by its exit
code, its `orch:` lines, the files it leaves in the round directory and what
reached the store; the cases, messages and changelogs are the ones the bash
spec-review apply sections pinned. The ticket step is test_spec_review_apply_tickets.py's."""
from __future__ import annotations

import json
import os
import subprocess

import pytest

from conftest import comments_of, orch_spec_review, read, snapshot

BODY = """# Spec

Alpha line.
Beta line.
Gamma line.
Delta line.
Twice.
Twice.
"""

# The fixture batch, bash's sra_dir's: line 6 opens item 1, 18 item 2, 27
# item 3 (its options on 31 and 38), 45 item 4 and 55 item 5; 57 is its last.
BATCH = """@@ lens fidelity ran
@@ lens consistency ran
@@ lens testability ran
@@ lens implementability not-run timed out twice

@@ item 1 consolidation apply material
@@ comment @alice 2026-01-02T00:00:00Z
@@ quote
Alpha should say
alpha prime.
@@ summary Folded in @alice's comment on Alpha
@@ anchor
Alpha line.
@@ replace
Alpha prime line.
@@ end
@@ why The comment asks for alpha prime
@@ item 2 contradicts-the-plan decline material the plan chose this
@@ finding fidelity 1
@@ summary Reverse the plan on Beta
@@ anchor
Beta line.
@@ replace
Beta reversed.
@@ end
@@ why Beta follows the plan's reversal
@@ item 3 consistency decision A material
@@ finding consistency 1
@@ finding testability 1
@@ why Gamma must agree with the summary
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
@@ item 4 testability apply minor
@@ finding testability 2
@@ summary Insert a test note after Delta
@@ anchor
Delta line.
@@ replace
Delta line.
Test note.
@@ end

@@ item 5 testability resolved
@@ finding testability 3
@@ resolved-by 4
"""

LENSES = {
    "fidelity": "@@ finding 1\nThe spec reverses the plan's\nchoice of beta.\n",
    "consistency": "@@ finding 1\nGamma contradicts the summary.\n",
    "testability": "@@ finding 1\nGamma is untestable.\n@@ finding 2\nDelta has no test.\n\n"
                   "@@ finding 3\nDelta needs a note.\n",
}

# The body the recommended answer leaves.
CLEAN = """# Spec

Alpha prime line.
Beta line.
Gamma line (kept).
Delta line.
Test note.
Twice.
Twice.
"""

LOG = """## Spec review
Round 1 of 2

### Consolidation
- (1) Folded in @alice's comment on Alpha

### Fidelity
- (2) "The spec reverses the plan's choice of beta." - spec departs from the plan: declined as recommended: the plan chose this

### Consistency
- (3) decision: took A - Keep gamma

### Testability
- (3) decision: took A - Keep gamma
- (4) Insert a test note after Delta
- (5) resolved by (4)

### Implementability
not run - timed out twice

### Tickets
None - no ticket breakdown
"""

AUTOPILOT = {"ORCH_AUTOPILOT": "1"}
FORMS = "is not recommended, all, none or a list of departures such as 3B, -4, +2"
USAGE_HEAD = "(usage: orch.sh spec-review apply <dir>"
ROOT_USER = os.geteuid() == 0


def round_dir(root, seed, name="round", batch=BATCH, body=BODY):
    """A fresh round directory holding the fixture spec, batch and lens
    files, with issue #14 reset to the fixture body."""
    d = root / name
    d.mkdir()
    (d / "spec.md").write_text(body)
    (d / "batch.md").write_text(batch)
    for lens, text in LENSES.items():
        (d / ("lens-%s.md" % lens)).write_text(text)
    seed.issue(14, "open")
    seed.body(14, body)
    return d


def batch_edit(d, old, new):
    """<d>/batch.md with its one line <old> made <new>, or dropped when <new>
    is None."""
    lines = (d / "batch.md").read_text().split("\n")
    assert lines.count(old) == 1, old
    i = lines.index(old)
    lines[i:i + 1] = [] if new is None else [new]
    (d / "batch.md").write_text("\n".join(lines))


def batch_line(d, lineno, new):
    """<d>/batch.md with its line <lineno>, numbered from 1, made <new>."""
    lines = (d / "batch.md").read_text().split("\n")
    lines[lineno - 1] = new
    (d / "batch.md").write_text("\n".join(lines))


def batch_drop(d, first, last):
    """<d>/batch.md less its lines <first> to <last>, numbered from 1."""
    lines = (d / "batch.md").read_text().split("\n")
    del lines[first - 1:last]
    (d / "batch.md").write_text("\n".join(lines))


def apply(root, seed, d, *args, env=None, issue="14", rnd="1/2"):
    """`spec-review apply <d> <args> --round <rnd> --issue <issue>`, no
    --issue when <issue> is None: its exit code."""
    tail = ["--round", rnd] + ([] if issue is None else ["--issue", issue])
    return orch_spec_review(root, "apply", str(d), *args, *tail, seed=seed, env=env)


def resume(root, seed, d, env=None, rnd="1/2"):
    return orch_spec_review(root, "apply", str(d), "--resume", "--round", rnd, seed=seed,
                            env=env)


def on_disk(path):
    return "present" if os.path.lexists(str(path)) else "absent"


def body_of(store):
    return read(store, "issues", 14, "body")


def kept(d):
    """What a refusal must leave as it was: spec.md, changelog.md and
    settled.md."""
    return [read(d, name) for name in ("spec.md", "changelog.md", "settled.md")]


def refused(capsys, root, seed, store, d, want, *args, env=None):
    """apply is refused, naming <want>, with spec.md, changelog.md and
    settled.md as they were and the store untouched: its stderr."""
    before, store_before = kept(d), snapshot(store)
    capsys.readouterr()
    assert apply(root, seed, d, *args, env=env) == 1
    out, err = capsys.readouterr()
    assert want in err
    assert out == ""
    assert kept(d) == before
    assert snapshot(store) == store_before
    return err


def flow(root, phase="spec", issue="14"):
    state = root / ".orchestrator" / "state.json"
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps({"slug": "sra", "phase": phase, "issue": issue}) + "\n")
    return state


# --- the recommended answer ---------------------------------------------------------


def test_recommended_applies_publishes_and_posts_the_changelog(root, seed, store):
    d = round_dir(root, seed)

    assert apply(root, seed, d, "recommended") == 0
    assert read(d, "spec.md") == CLEAN
    assert body_of(store) == CLEAN
    assert read(d, "spec.fetched.md") == BODY
    assert read(d, "changelog.md") == LOG
    assert comments_of(store, 14) == [LOG]
    assert read(d, "applied.log") == "the body of issue #14\nthe changelog comment on issue #14\n"
    assert read(d, "settled.md") == LOG
    assert read(d, "round-complete") == ""
    assert on_disk(d / "apply-answer") == "absent"


def test_a_rerun_once_a_write_landed_is_refused_naming_the_writes(root, seed, store, capsys):
    d = round_dir(root, seed)
    apply(root, seed, d, "recommended")
    os.remove(str(d / "round-complete"))

    err = refused(capsys, root, seed, store, d, "", "recommended")
    assert err == (
        "orch: %s/applied.log records writes that already landed: the body of issue #14; the"
        " changelog comment on issue #14 - this review stopped at a failed write; apply"
        " refuses to run again\n" % d)


def test_a_second_round_appends_its_changelog_after_the_first(root, seed):
    d = round_dir(root, seed)
    (d / "settled.md").write_text(LOG)

    assert apply(root, seed, d, "recommended", rnd="2/2") == 0
    assert read(d, "settled.md") == LOG + LOG.replace("Round 1 of 2", "Round 2 of 2")


# --- the answer forms ----------------------------------------------------------------


def test_all_applies_the_recommend_decline_item_too(root, seed):
    d = round_dir(root, seed)

    assert apply(root, seed, d, "all") == 0
    assert "Beta reversed." in read(d, "spec.md")
    assert "- (2) Reverse the plan on Beta\n" in read(d, "changelog.md")


def test_none_writes_no_body_and_quotes_each_declined_item(root, seed, store):
    d = round_dir(root, seed)
    (d / "reasons").write_text("1: the comment is stale\n")
    seed.fail("adapter_issue_body_edit")

    assert apply(root, seed, d, "none", "--reasons", str(d / "reasons")) == 0
    log = read(d, "changelog.md")
    assert read(d, "spec.md") == BODY
    assert body_of(store) == BODY
    assert '- (1) "Alpha should say alpha prime." - the comment is stale\n' in log
    assert ('- (3) "Gamma contradicts the summary." / "Gamma is untestable." - left undecided\n'
            in log)
    assert '- (4) "Delta has no test." - declined\n' in log
    assert log.endswith("### Tickets\nNot checked - no edit applied\n")
    assert comments_of(store, 14) == [log]
    assert read(d, "applied.log") == "the changelog comment on issue #14\n"


def test_an_override_answer_names_only_its_departures(root, seed, store):
    d = round_dir(root, seed)
    (d / "reasons").write_text("\n1: the comment is stale\n")

    assert apply(root, seed, d, "3B, -1", "--reasons", str(d / "reasons")) == 0
    assert read(d, "spec.md") == BODY.replace("Gamma line.", "Gamma dropped.").replace(
        "Delta line.\n", "Delta line.\nTest note.\n")
    log = read(d, "changelog.md")
    assert "- (3) decision: took B - Drop gamma\n" in log
    assert '- (1) "Alpha should say alpha prime." - the comment is stale\n' in log
    assert ('- (2) "The spec reverses the plan\'s choice of beta." - spec departs from the plan:'
            ' declined as recommended: the plan chose this\n') in log
    assert "- (4) Insert a test note after Delta\n" in log
    assert comments_of(store, 14) == [log]


@pytest.mark.parametrize("answer", ["-3, +2, -4", "  -3 ,+2 ,  -4  "])
def test_plus_applies_a_recommend_decline_and_minus_leaves_a_decision_undecided(
        root, seed, answer):
    d = round_dir(root, seed)

    assert apply(root, seed, d, answer) == 0
    assert read(d, "spec.md") == BODY.replace("Alpha line.", "Alpha prime line.").replace(
        "Beta line.", "Beta reversed.")
    log = read(d, "changelog.md")
    assert "- (2) Reverse the plan on Beta\n" in log
    assert sum(1 for line in log.split("\n")
               if line.startswith("- (3) ") and line.endswith(" - left undecided")) == 2
    assert '- (4) "Delta has no test." - declined\n' in log
    assert "- (5) resolved by (4)\n" in log


def test_a_departure_matching_the_recommendation_is_recorded_as_recommended(root, seed):
    d = round_dir(root, seed)

    assert apply(root, seed, d, "3A, -2") == 0
    assert (read(d, "changelog.md"), read(d, "spec.md")) == (LOG, CLEAN)


def test_a_single_dash_answer_after_the_directory_is_the_answer(root, seed):
    d = round_dir(root, seed)

    assert apply(root, seed, d, "-4") == 0
    assert "Test note." not in read(d, "spec.md")


@pytest.mark.parametrize("answer", ["all", "+2"])
def test_a_minor_recommend_decline_item_applied_is_untagged(root, seed, answer):
    d = round_dir(root, seed)
    batch_edit(d, "@@ item 2 contradicts-the-plan decline material the plan chose this",
               "@@ item 2 fidelity decline minor the plan chose this")
    batch_edit(d, "@@ why Beta follows the plan's reversal", "")

    assert apply(root, seed, d, answer) == 0
    assert "- (2) Reverse the plan on Beta\n" in read(d, "changelog.md")
    assert "- (2) Reverse the plan on Beta\n" in read(d, "settled.md")


def test_an_unattended_changelog_with_minor_items_tags_none(root, seed):
    d = round_dir(root, seed)
    batch_edit(d, "@@ item 2 contradicts-the-plan decline material the plan chose this",
               "@@ item 2 fidelity decline minor the plan chose this")
    batch_edit(d, "@@ why Beta follows the plan's reversal", "")

    assert apply(root, seed, d, "recommended", "--unattended") == 0
    log = read(d, "changelog.md")
    assert "minor)" not in log
    assert "- (4) Insert a test note after Delta\n" in log
    assert ('- (2) "The spec reverses the plan\'s choice of beta." - declined as recommended:'
            ' the plan chose this\n') in log


@pytest.mark.parametrize("answer, message", [
    ("2, 3", "the answer '2, 3' %s - '2' is not <n><letter>, -<n> or +<n>" % FORMS),
    ("3", "the answer '3' %s - '3' is not <n><letter>, -<n> or +<n>" % FORMS),
    ("1;2", "the answer '1;2' %s - '1;2' is not <n><letter>, -<n> or +<n>" % FORMS),
    ("-", "the answer '-' %s - '-' is not <n><letter>, -<n> or +<n>" % FORMS),
    ("+3B", "the answer '+3B' %s - '+3B' is not <n><letter>, -<n> or +<n>" % FORMS),
    ("3AB", "the answer '3AB' %s - '3AB' is not <n><letter>, -<n> or +<n>" % FORMS),
    ("-4,", "the answer '-4,' %s - '' is not <n><letter>, -<n> or +<n>" % FORMS),
    ("-1, -9", "the answer names item 9, which batch.md does not have"),
    ("9A", "the answer names item 9, which batch.md does not have"),
    ("3C", "the answer gives item 3 option C, which it does not have"),
    ("3c", "the answer gives item 3 option C, which it does not have"),
    ("4B", "the answer gives item 4 the letter B, but item 4 is no decision item"),
    ("+3", "the answer names +3, but item 3 is a decision item: name its option, as 3A"),
    ("+4", "the answer names +4, but item 4 is not recommended for decline"),
    ("-5", "the answer names item 5, which is resolved by item 4 and takes no answer"),
    ("+5", "the answer names item 5, which is resolved by item 4 and takes no answer"),
    ("5A", "the answer names item 5, which is resolved by item 4 and takes no answer"),
    ("-4 , -4", "the answer names item 4 twice"),
    ("3B, -3", "the answer names item 3 twice"),
    ("3B, 3Z", "the answer names item 3 twice"),
    ("-2, -2", "the answer names item 2 twice"),
])
def test_an_answer_refused_before_any_write(root, seed, store, capsys, answer, message):
    d = round_dir(root, seed)
    (d / "changelog.md").write_text("old log\n")

    assert refused(capsys, root, seed, store, d, "", answer) == "orch: %s\n" % message


# --- the arguments -------------------------------------------------------------------


def test_an_unknown_long_option_is_refused_though_the_answer_may_begin_with_a_dash(
        root, seed, store, capsys):
    d = round_dir(root, seed)

    err = refused(capsys, root, seed, store, d, "", "-4", "--bogus")
    assert err.startswith("orch: unknown option: --bogus " + USAGE_HEAD)
    assert orch_spec_review(root, "apply", "-x", str(d), "-4", "--round", "1/2", "--issue", "14",
                            seed=seed) == 1
    assert capsys.readouterr().err.startswith("orch: unknown option: -x " + USAGE_HEAD)


@pytest.mark.parametrize("argv, message", [
    (["apply"], "usage: orch.sh spec-review apply"),
    (["apply", "{d}", "recommended", "--issue", "14"], "--round <k>/<n> is required"),
    (["apply", "{d}", "recommended", "--round", "1x/2", "--issue", "14"],
     "want <k>/<n>, a round and the round count, two positive whole numbers, got: 1x/2"),
    (["apply", "{d}", "recommended", "--round", "3/2", "--issue", "14"],
     "round 3 is past the round count 2"),
    (["apply", "{d}", "recommended", "--round", "1/2", "--issue", "1x"],
     "--issue must be a plain issue number, got: 1x"),
    (["apply", "{d}", "recommended", "--round"], "--round needs a value"),
    (["apply", "{d}", "recommended", "--round", "1/2", "--issue", "14", "--tickets", "1B"],
     "--tickets wants recommended, all, none, retire or a list such as 1, 3, got: 1B"),
    (["apply", "{d}", "recommended", "--round", "1/2", "--issue", "14", "--ticket-reasons", "f"],
     "--ticket-reasons goes with --tickets: it holds the ticket answer's decline reasons"),
    (["apply", "{d}", "recommended", "--round", "1/1", "--unattended"],
     "--unattended needs --issue: an unattended spec review is a standalone one"),
    (["apply", "{d}", "all", "--round", "1/2", "--issue", "14", "--unattended"],
     "--unattended takes only the answer recommended, got: all"),
    (["apply", "{d}", "recommended", "--round", "1/2", "--issue", "14", "--unattended",
      "--tickets", "all"], "--unattended takes only --tickets recommended, got: all"),
    (["apply", "{d}/nowhere", "recommended", "--round", "1/2", "--issue", "14"],
     "no such directory: {d}/nowhere"),
    (["apply", "{d}", "recommended", "extra", "--round", "1/2"], "usage: orch.sh spec-review"),
])
def test_the_arguments_refused_before_any_write(root, seed, store, capsys, argv, message):
    d = round_dir(root, seed)
    before = snapshot(store)

    assert orch_spec_review(root, *[a.replace("{d}", str(d)) for a in argv], seed=seed) == 1
    assert message.replace("{d}", str(d)) in capsys.readouterr().err
    assert snapshot(store) == before
    assert on_disk(d / "spec.fetched.md") == "absent"


@pytest.mark.parametrize("name", ["spec.md", "batch.md"])
def test_a_round_directory_missing_its_spec_or_batch_is_refused(root, seed, capsys, name):
    d = round_dir(root, seed)
    os.remove(str(d / name))

    assert apply(root, seed, d, "recommended") == 1
    assert capsys.readouterr().err == "orch: %s not found in %s\n" % (name, d)


# --- the batch file and the lens files ------------------------------------------------


@pytest.mark.parametrize("change, message", [
    (lambda d: (d / "batch.md").write_text(BATCH + "stray text\n"),
     "batch.md line 58: text outside an @@ anchor, @@ replace or @@ quote block"),
    (lambda d: batch_edit(d, "@@ summary Insert a test note after Delta", None),
     "batch.md line 45: item 4 has no @@ summary"),
    (lambda d: batch_edit(d, "@@ summary Insert a test note after Delta",
                          "@@ summary " + " ".join("w%d" % i for i in range(1, 32))),
     "batch.md line 47: item 4's @@ summary has 31 words, more than 30"),
    (lambda d: (d / "batch.md").write_text(BATCH + "@@ end\n"),
     "batch.md line 58: a resolved item takes no @@ anchor, @@ replace or @@ end"),
    (lambda d: batch_drop(d, 21, 25),
     "batch.md line 18: item 2 has no @@ anchor/@@ replace/@@ end block - a decline item still"
     " carries the edit it declines"),
    (lambda d: batch_drop(d, 48, 53),
     "batch.md line 45: item 4 has no @@ anchor/@@ replace/@@ end block"),
    (lambda d: batch_drop(d, 14, 14),
     "batch.md line 15: expected @@ replace to end the anchor begun on line 12, got '@@ end' -"
     " a body line starting with @@ is written \\@@"),
    (lambda d: batch_drop(d, 40, 44),
     "batch.md line 38: item 3 option B has no @@ anchor/@@ replace/@@ end block - an option"
     " not recommended still carries the edit it would make"),
    (lambda d: batch_drop(d, 33, 37),
     "batch.md line 31: item 3 option A has no @@ anchor/@@ replace/@@ end block"),
    (lambda d: batch_edit(d, "@@ item 4 testability apply minor",
                          "@@ item 4 testability apply major"),
     "batch.md line 45: item 4's mark must be material or minor, got 'major'"),
    (lambda d: batch_edit(d, "@@ why The comment asks for alpha prime", ""),
     "batch.md line 6: item 1 has no @@ why"),
    (lambda d: os.remove(str(d / "lens-consistency.md")),
     "lens-consistency.md not found in {d} - lens consistency is marked ran in batch.md"),
    (lambda d: (d / "lens-consistency.md").write_text("@@ finding 1\nx\n@@ finding 3\ny\n"),
     "lens-consistency.md line 3: expected @@ finding 2, got '@@ finding 3'"),
    (lambda d: batch_line(d, 49, "Nowhere line."),
     "batch.md line 48: item 4: its anchor matches no text in the body - nothing applied,"
     " nothing written"),
    (lambda d: batch_line(d, 49, "Twice."),
     "batch.md line 48: item 4: its anchor matches more than one place in the body - nothing"
     " applied, nothing written"),
])
@pytest.mark.parametrize("flags", [(), ("--unattended",)])
def test_a_malformed_batch_or_lens_file_refused_before_any_write(
        root, seed, store, capsys, change, message, flags):
    d = round_dir(root, seed)
    (d / "settled.md").write_text("earlier round\n")
    change(d)

    err = refused(capsys, root, seed, store, d, "", "recommended", *flags)
    assert err == "orch: %s\n" % message.replace("{d}", str(d))


def test_a_corrected_batch_rerun_applies_from_the_fetched_copy(root, seed, capsys):
    d = round_dir(root, seed)
    batch_line(d, 49, "Nowhere line.")
    assert apply(root, seed, d, "recommended") == 1
    batch_line(d, 49, "Delta line.")

    assert apply(root, seed, d, "recommended") == 0
    assert read(d, "spec.md") == CLEAN


def test_the_fundamental_mark_is_refused_outside_autopilot(root, seed, store, capsys):
    d = round_dir(root, seed)
    batch_edit(d, "@@ item 3 consistency decision A material",
               "@@ item 3 consistency decision A fundamental")

    assert "got 'fundamental'" in refused(capsys, root, seed, store, d, "", "recommended")


def test_escaped_grammar_lines_publish_unescaped_from_a_crlf_batch(root, seed, store):
    body = "# Spec\n\nAlpha line.\n@@ note <text>\n\\@@ keep\nOmega.\n"
    batch = ("@@ lens fidelity ran\n@@ lens consistency not-run timed out\n"
             "@@ lens testability not-run timed out\n@@ lens implementability not-run timed"
             " out\n\n@@ item 1 fidelity apply minor\n@@ finding fidelity 1\n@@ summary Reword"
             " the quoted line\n@@ anchor\n\\@@ note <text>\n@@ replace\n\\@@ remark <text>\n"
             "@@ end\n").replace("\n", "\r\n")
    d = round_dir(root, seed, batch=batch, body=body)
    (d / "lens-fidelity.md").write_text("@@ finding 1\nReword.\n")
    for lens in ("consistency", "testability"):
        os.remove(str(d / ("lens-%s.md" % lens)))

    assert apply(root, seed, d, "recommended") == 0
    assert body_of(store) == body.replace("@@ note <text>", "@@ remark <text>")


# --- --reasons and --host-fallbacks ----------------------------------------------------


@pytest.mark.parametrize("answer, reasons, message", [
    ("none", "one: why\n", "--reasons line 1: want <n>: <reason>, got 'one: why'"),
    ("none", "\n4:why\n", "--reasons line 2: want <n>: <reason>, got '4:why'"),
    ("none", "4: \n", "--reasons line 1: want <n>: <reason>, got '4: '"),
    ("none", "9: why\n", "--reasons line 1 names item 9, which batch.md does not have"),
    ("recommended", "4: why\n", "--reasons line 1 names item 4, which the answer does not decline"),
    ("-1", "4: why\n", "--reasons line 1 names item 4, which the answer does not decline"),
    ("+2", "2: why\n", "--reasons line 1 names item 2, which the answer does not decline"),
    ("none", "4: why\r\n4: again\n", "--reasons line 2 names item 4 a second time"),
])
def test_a_reasons_file_refused_before_any_write(root, seed, store, capsys, answer, reasons,
                                                 message):
    d = round_dir(root, seed)
    (d / "reasons").write_text(reasons)

    err = refused(capsys, root, seed, store, d, "", answer, "--reasons", str(d / "reasons"))
    assert err == "orch: %s\n" % message


def test_a_reasons_file_not_found_is_refused(root, seed, store, capsys):
    d = round_dir(root, seed)

    assert refused(capsys, root, seed, store, d, "", "none", "--reasons", str(d / "gone")) == (
        "orch: --reasons file not found: %s/gone\n" % d)


def test_unattended_with_host_fallbacks_writes_its_own_changelog(root, seed):
    d = round_dir(root, seed)
    batch_edit(d, "@@ lens fidelity ran", "@@ lens fidelity standalone")
    batch_drop(d, 18, 26)
    os.remove(str(d / "lens-fidelity.md"))
    (d / "hosts").write_text("AskUserQuestion fell back\n  to a plain question\n\n")

    assert apply(root, seed, d, "recommended", "--unattended", "--host-fallbacks",
                 str(d / "hosts")) == 0
    assert read(d, "changelog.md") == """## Spec review
Round 1 of 2
Unattended spec review, run from a quick implementation: applied as recommended.

### Consolidation
- (1) Folded in @alice's comment on Alpha

### Fidelity
not run - standalone review, no plan to check against

### Consistency
- decision (3): took A - Keep gamma, as recommended

### Testability
- decision (3): took A - Keep gamma, as recommended
- (4) Insert a test note after Delta
- (5) resolved by (4)

### Implementability
not run - timed out twice

### Tickets
None - no ticket breakdown

**Host fallbacks:** AskUserQuestion fell back to a plain question
"""
    assert read(d, "settled.md") == read(d, "changelog.md")


@pytest.mark.parametrize("make, message", [
    (lambda path: None, "--host-fallbacks file not found: {f}"),
    (lambda path: path.mkdir(), "--host-fallbacks file not found: {f}"),
    (lambda path: path.write_text("\n \n\n"), "--host-fallbacks file is empty: {f}"),
])
def test_a_host_fallbacks_file_refused_before_any_write(root, seed, store, capsys, make, message):
    d = round_dir(root, seed)
    make(d / "hosts")

    err = refused(capsys, root, seed, store, d, "", "recommended", "--host-fallbacks",
                  str(d / "hosts"))
    assert err == "orch: %s\n" % message.replace("{f}", str(d / "hosts"))


@pytest.mark.skipif(ROOT_USER, reason="root reads any file")
def test_an_unreadable_host_fallbacks_file_is_refused_with_its_own_message(
        root, seed, store, capsys):
    d = round_dir(root, seed)
    (d / "hosts").write_text("host\n")
    (d / "hosts").chmod(0)

    err = refused(capsys, root, seed, store, d, "", "recommended", "--host-fallbacks",
                  str(d / "hosts"))
    assert err == "orch: --host-fallbacks file is unreadable: %s/hosts\n" % d


# --- the GitHub writes, their failures and --resume --------------------------------------


@pytest.mark.parametrize("in_flow", [False, True])
@pytest.mark.parametrize("operation, message", [
    ("adapter_issue_body_edit",
     "could not write the body of issue #14: gh could not replace the body of issue #14: fake"
     " gh: adapter_issue_body_edit failed - already landed: nothing"),
    ("adapter_issue_comment",
     "could not write the changelog comment on issue #14: gh could not comment on issue #14:"
     " fake gh: adapter_issue_comment failed - already landed: the body of issue #14"),
])
def test_a_failed_github_write_stops_apply_naming_what_landed(root, seed, capsys, in_flow,
                                                              operation, message):
    d = round_dir(root, seed)
    (d / "settled.md").write_text("earlier round\n")
    if in_flow:
        flow(root)
    seed.fail(operation)

    assert apply(root, seed, d, "recommended", issue=None if in_flow else "14") == 1
    assert capsys.readouterr().err == (
        "orch: %s; %s/changelog.md is kept, and the review stops here\n" % (message, d))
    assert read(d, "changelog.md") == LOG
    assert read(d, "settled.md") == "earlier round\n"
    assert on_disk(d / "round-complete") == "absent"
    assert on_disk(d / "apply-answer") == "present"


def test_resume_reruns_with_the_saved_answer_skipping_what_landed(root, seed, store, capsys,
                                                                 tmp_path):
    d = round_dir(root, seed)
    source = tmp_path / "source"
    source.mkdir()
    (source / "reasons.src").write_text("2: the plan chose this\n")
    (d / "settled.md").write_text("earlier round\n")
    seed.fail("adapter_issue_comment")
    assert apply(root, seed, d, "recommended", "--reasons", str(source / "reasons.src")) == 1
    seed.unfail()
    assert str(source) not in read(d, "apply-answer")
    assert read(d, "apply-reasons.copy") == "2: the plan chose this\n"
    (source / "reasons.src").unlink()
    capsys.readouterr()

    assert apply(root, seed, d, "recommended") == 1
    assert capsys.readouterr().err == (
        "orch: %s/apply-answer holds the answer of an apply that died - run spec-review apply"
        " %s --resume --round 1/2 to resume it\n" % (d, d))
    assert resume(root, seed, d, rnd="2/2") == 1
    assert capsys.readouterr().err == (
        "orch: --resume --round 2/2: the saved answer in %s is for round 1/2\n" % d)

    assert resume(root, seed, d) == 0
    log = LOG.replace("declined as recommended: the plan chose this", "the plan chose this")
    assert comments_of(store, 14) == [log]
    assert body_of(store) == CLEAN
    assert read(d, "settled.md") == "earlier round\n" + log
    assert on_disk(d / "round-complete") == "present"
    assert [on_disk(d / name) for name in ("apply-answer", "apply-reasons.copy")] == [
        "absent", "absent"]


@pytest.mark.parametrize("argv, message", [
    (["--resume", "--round", "1/2"], "--resume: {d} holds no apply-answer - there is no apply to"
                                     " resume; run apply with its answer"),
    (["--resume", "--round", "1/2", "--issue", "14"],
     "--resume takes only <dir> and --round <k>/<n>, got: --issue"),
    (["--resume"], "usage: orch.sh spec-review apply"),
    (["--resume", "--round"], "--round needs a value"),
])
def test_a_resume_with_no_apply_to_resume_is_refused(root, seed, capsys, argv, message):
    d = round_dir(root, seed)

    assert orch_spec_review(root, "apply", str(d), *argv, seed=seed) == 1
    assert message.replace("{d}", str(d)) in capsys.readouterr().err


def test_a_bash_written_saved_answer_resumes(root, seed, store, monkeypatch):
    monkeypatch.chdir(str(root))
    d = round_dir(root, seed)
    (d / "apply-reasons.copy").write_text("1: the comment is stale\n")
    # bash's `printf '%q '` of the answer and its arguments, a relative copy
    # path among them.
    line = "3B\\,\\ -1 --round 1/2 --reasons round/apply-reasons.copy --issue 14 \n"
    assert subprocess.run(
        ["bash", "-c", "printf '%q ' '3B, -1' --round 1/2 --reasons round/apply-reasons.copy"
                       " --issue 14; echo"], stdout=subprocess.PIPE, check=True,
        stdin=subprocess.DEVNULL).stdout.decode() == line
    (d / "apply-answer").write_text(line)

    assert orch_spec_review(root, "apply", "round", "--resume", "--round", "1/2", seed=seed) == 0
    log = read(d, "changelog.md")
    assert "- (3) decision: took B - Drop gamma\n" in log
    assert '- (1) "Alpha should say alpha prime." - the comment is stale\n' in log
    assert comments_of(store, 14) == [log]
    assert on_disk(d / "apply-answer") == "absent"


def test_a_saved_answer_bash_wrote_in_ansi_c_quotes_is_refused(root, seed, capsys):
    d = round_dir(root, seed)
    (d / "apply-answer").write_text("$'a\\tb' --round 1/2 --issue 14 \n")

    assert resume(root, seed, d) == 1
    assert capsys.readouterr().err == (
        "orch: %s/apply-answer is unreadable - rerun the round\n" % d)


# The five applied.log labels bash spec_review_write logged, word for word.
BASH_LOG = """ticket #20's body
unblock #21 by #20
block #20 by #21
the body of issue #14
the retire of #14's ticket breakdown
the changelog comment on issue #14
"""


def test_a_bash_written_applied_log_with_the_changelog_landed_runs_only_the_local_tail(
        root, seed, store, capsys):
    d = round_dir(root, seed)
    seed.fail("adapter_issue_comment")
    apply(root, seed, d, "recommended")
    seed.unfail()
    (d / "applied.log").write_text(BASH_LOG)
    (d / "settled.md").mkdir()
    before = snapshot(store)
    capsys.readouterr()

    assert resume(root, seed, d) == 1
    assert capsys.readouterr().err == (
        "orch: could not append the changelog to %s/settled.md - every GitHub write landed:"
        " ticket #20's body; unblock #21 by #20; block #20 by #21; the body of issue #14; the"
        " retire of #14's ticket breakdown; the changelog comment on issue #14\n" % d)
    (d / "settled.md").rmdir()
    assert resume(root, seed, d) == 0
    assert snapshot(store) == before
    assert read(d, "settled.md") == LOG
    assert on_disk(d / "apply-answer") == "absent"


def test_a_tail_only_resume_with_no_changelog_md_is_refused(root, seed, capsys):
    d = round_dir(root, seed)
    seed.fail("adapter_issue_comment")
    apply(root, seed, d, "recommended")
    (d / "applied.log").write_text("the changelog comment on issue #14\n")
    os.remove(str(d / "changelog.md"))
    capsys.readouterr()

    assert resume(root, seed, d) == 1
    assert capsys.readouterr().err == "orch: changelog.md not found in %s\n" % d


@pytest.mark.skipif(ROOT_USER, reason="root reads any file")
def test_a_tail_only_resume_with_an_unreadable_changelog_md_names_what_landed(
        root, seed, store, capsys):
    d = round_dir(root, seed)
    (d / "settled.md").mkdir()
    apply(root, seed, d, "recommended")
    (d / "settled.md").rmdir()
    (d / "changelog.md").chmod(0)
    before = snapshot(store)
    capsys.readouterr()

    assert resume(root, seed, d) == 1
    (d / "changelog.md").chmod(0o600)
    assert capsys.readouterr().err == (
        "orch: could not read %s/changelog.md - every GitHub write landed: the body of issue"
        " #14; the changelog comment on issue #14\n" % d)
    assert [on_disk(d / n) for n in ("settled.md", "round-complete", "apply-answer")] == [
        "absent", "absent", "present"]
    assert snapshot(store) == before


def test_a_write_that_landed_but_applied_log_could_not_record_says_so(root, seed, store, capsys):
    d = round_dir(root, seed)
    (d / "applied.log").symlink_to(str(root / "nowhere" / "applied.log"))

    assert apply(root, seed, d, "recommended") == 1
    assert capsys.readouterr().err == (
        "orch: the body of issue #14 landed, but %s/applied.log could not record it\n" % d)
    assert body_of(store) == CLEAN


# --- the round's local steps -------------------------------------------------------------


@pytest.mark.parametrize("make, message", [
    (lambda d: (d / "changelog.md").mkdir(),
     "could not write {d}/changelog.md - nothing written to GitHub"),
    (lambda d: (d / "apply-reasons.copy").mkdir(),
     "could not copy {d}/reasons to {d}/apply-reasons.copy - nothing written to GitHub"),
])
def test_a_local_step_before_the_first_write_that_fails_writes_nothing_to_github(
        root, seed, store, capsys, make, message):
    d = round_dir(root, seed)
    (d / "reasons").write_text("")
    make(d)
    before = snapshot(store)

    assert apply(root, seed, d, "recommended", "--reasons", str(d / "reasons")) == 1
    assert capsys.readouterr().err == "orch: %s\n" % message.replace("{d}", str(d))
    assert snapshot(store) == before


@pytest.mark.skipif(ROOT_USER, reason="root writes any file")
@pytest.mark.parametrize("env, locked, message", [
    ({}, "dir", "could not write {d}/apply-answer - nothing written to GitHub"),
    ({}, "spec.md", "could not write {d}/spec.md - nothing written to GitHub"),
    (AUTOPILOT, "dir", "could not write {d}/fundamental.md - nothing written to GitHub"),
])
def test_a_local_write_refused_by_the_file_system_writes_nothing_to_github(
        root, seed, store, capsys, env, locked, message):
    d = round_dir(root, seed)
    if env:
        batch_edit(d, "@@ item 3 consistency decision A material",
                   "@@ item 3 consistency decision A fundamental")
    (d / "spec.fetched.md").write_text(BODY)
    target = d if locked == "dir" else d / locked
    target.chmod(0o555 if locked == "dir" else 0o444)
    before = snapshot(store)

    try:
        code = apply(root, seed, d, "recommended", env=env)
    finally:
        target.chmod(0o755 if locked == "dir" else 0o644)
    assert code == 1
    assert capsys.readouterr().err == "orch: %s\n" % message.replace("{d}", str(d))
    assert snapshot(store) == before


@pytest.mark.parametrize("make, message", [
    (lambda d: (d / "settled.md").mkdir(),
     "could not append the changelog to {d}/settled.md - every GitHub write landed: {landed}"),
    (lambda d: (d / "fundamental.md").mkdir() or (d / "fundamental.md" / "x").write_text(""),
     "could not remove {d}/fundamental.md - every GitHub write landed and settled.md is"
     " appended: {landed}"),
    (lambda d: (d / "round-complete").mkdir(),
     "could not write {d}/round-complete - every GitHub write landed and settled.md is"
     " appended: {landed}"),
])
def test_a_local_step_after_every_write_that_fails_names_what_landed_and_resumes(
        root, seed, store, capsys, make, message):
    d = round_dir(root, seed)
    make(d)

    assert apply(root, seed, d, "recommended") == 1
    landed = "the body of issue #14; the changelog comment on issue #14"
    assert capsys.readouterr().err == "orch: %s\n" % message.replace("{d}", str(d)).replace(
        "{landed}", landed)
    assert comments_of(store, 14) == [LOG]
    for name in ("settled.md", "fundamental.md", "round-complete"):
        path = d / name
        if path.is_dir():
            for child in path.iterdir():
                child.unlink()
            path.rmdir()
    assert resume(root, seed, d) == 0
    assert comments_of(store, 14) == [LOG]
    assert read(d, "settled.md") == LOG
    assert on_disk(d / "round-complete") == "present"


def test_a_saved_answer_that_cannot_be_cleared_leaves_the_round_complete(root, seed, capsys):
    d = round_dir(root, seed)
    (d / "apply-stale.copy").mkdir()

    assert apply(root, seed, d, "recommended") == 1
    assert capsys.readouterr().err == (
        "orch: could not remove %s/apply-answer - every GitHub write landed: the body of issue"
        " #14; the changelog comment on issue #14\n" % d)
    assert [on_disk(d / n) for n in ("round-complete", "apply-answer")] == ["present", "absent"]
    assert read(d, "settled.md") == LOG


# --- the autopilot hold ------------------------------------------------------------------


def fundamental_dir(root, seed, name="round"):
    """The fixture with item 3, a decision, marked fundamental."""
    d = round_dir(root, seed, name)
    batch_edit(d, "@@ item 3 consistency decision A material",
               "@@ item 3 consistency decision A fundamental")
    return d


def test_the_hold_run_writes_fundamental_md_and_nothing_to_github(root, seed, store):
    d = fundamental_dir(root, seed)
    before = snapshot(store)

    assert apply(root, seed, d, "recommended", env=AUTOPILOT) == 0
    assert snapshot(store) == before
    assert (read(d, "spec.md"), read(d, "spec.fetched.md")) == (BODY, BODY)
    held = BATCH.split("@@ item 3 ")[1].split("@@ item 4 ")[0]
    assert read(d, "fundamental.md") == "".join(
        line + "\n" for line in BATCH.split("\n")[:4]) + (
        "@@ item 3 " + held).replace("decision A material", "decision A fundamental")
    assert [on_disk(d / n) for n in ("apply-answer", "round-complete", "settled.md")] == [
        "absent"] * 3


def test_a_held_item_followed_by_another_keeps_its_trailing_blank_line(root, seed):
    d = round_dir(root, seed)
    batch_edit(d, "@@ item 4 testability apply minor", "@@ item 4 testability apply fundamental")
    batch_edit(d, "@@ finding testability 2", "@@ finding testability 2\n@@ why held back")

    assert apply(root, seed, d, "recommended", env=AUTOPILOT) == 0
    assert read(d, "fundamental.md").endswith("Test note.\n@@ end\n\n")


@pytest.mark.parametrize("answer, message", [
    ("3C", "the answer gives item 3 option C, which it does not have"),
    ("-4", "the answer names item 4, which is not a fundamental item - the resumed answer"
           " names only fundamental items, the rest being taken as recommended"),
])
def test_the_reply_run_refuses_an_answer_the_held_items_cannot_take(
        root, seed, store, capsys, answer, message):
    d = fundamental_dir(root, seed)
    apply(root, seed, d, "recommended", env=AUTOPILOT)

    assert refused(capsys, root, seed, store, d, "", answer, env=AUTOPILOT) == (
        "orch: %s\n" % message)


def test_the_hold_run_refuses_an_answer_naming_a_held_item(root, seed, store, capsys):
    d = fundamental_dir(root, seed)

    assert refused(capsys, root, seed, store, d, "", "3B", env=AUTOPILOT) == (
        "orch: the answer names item 3, a fundamental item held back for the human's reply -"
        " it takes no answer in this run\n")


def test_the_reply_run_applies_the_whole_batch_and_posts_one_changelog(root, seed, store):
    d = fundamental_dir(root, seed)
    apply(root, seed, d, "recommended", env=AUTOPILOT)

    assert apply(root, seed, d, "3B", env=AUTOPILOT) == 0
    assert read(d, "spec.md").split("\n")[4] == "Gamma dropped."
    assert body_of(store) == read(d, "spec.md")
    [log] = comments_of(store, 14)
    assert "- (1) Folded in @alice's comment on Alpha\n" in log
    assert "- (3) decision: took B - Drop gamma\n" in log
    assert read(d, "settled.md").count("## Spec review\n") == 1
    assert on_disk(d / "fundamental.md") == "absent"
    assert on_disk(d / "round-complete") == "present"


def test_a_reply_run_whose_changelog_failed_resumes_keeping_fundamental_md(root, seed, store,
                                                                          capsys):
    d = fundamental_dir(root, seed)
    apply(root, seed, d, "recommended", env=AUTOPILOT)
    seed.fail("adapter_issue_comment")
    assert apply(root, seed, d, "3B", env=AUTOPILOT) == 1
    seed.unfail()
    assert "already landed: the body of issue #14;" in capsys.readouterr().err
    assert apply(root, seed, d, "3B", env=AUTOPILOT) == 1
    assert "--resume" in capsys.readouterr().err
    assert on_disk(d / "fundamental.md") == "present"

    assert resume(root, seed, d, env=AUTOPILOT) == 0
    assert len(comments_of(store, 14)) == 1
    assert on_disk(d / "fundamental.md") == "absent"
    assert on_disk(d / "round-complete") == "present"


# The #1915 reproduction: a minor edit rewrites text a fundamental item
# anchors; the reply run applies the batch in batch order.
NIGHTLY = "Exports run nightly and write one file."
NIGHTLY_ITEMS = """@@ item 1 consistency apply fundamental
@@ finding consistency 1
@@ summary Run exports nightly in one place
@@ anchor
Exports run nightly
@@ replace
Exports run nightly (kept)
@@ end
@@ why Keep the schedule
@@ item 2 testability apply minor
@@ finding testability 1
@@ summary Reword nightly
@@ anchor
nightly
@@ replace
each night
@@ end
""" + "".join("""@@ item %d %s decline material not wanted
@@ finding %s %d
@@ summary Leave %s %d be
@@ anchor
write one file
@@ replace
write one file
@@ end
@@ why Out of scope
""" % (n, lens, lens, k, lens, k) for n, lens, k in (
    (3, "fidelity", 1), (4, "testability", 2), (5, "testability", 3)))


@pytest.mark.parametrize("answer, published", [
    ("recommended", "Exports run each night (kept) and write one file."),
    ("-1", "Exports run each night and write one file."),
    ("none", "Exports run each night and write one file."),
])
def test_the_reply_run_applies_the_batch_in_batch_order(root, seed, store, answer, published):
    batch = "".join(line + "\n" for line in BATCH.split("\n")[:5]) + NIGHTLY_ITEMS
    d = round_dir(root, seed, batch=batch, body=NIGHTLY)
    assert apply(root, seed, d, "recommended", env=AUTOPILOT) == 0
    assert (read(d, "spec.md"), body_of(store)) == (NIGHTLY, NIGHTLY)

    assert apply(root, seed, d, answer, env=AUTOPILOT) == 0
    assert body_of(store) == published
    [log] = comments_of(store, 14)
    if answer != "recommended":
        assert '- (1) "Gamma contradicts the summary." - declined\n' in log


def test_an_attended_apply_of_a_held_round_completes_it(root, seed):
    d = fundamental_dir(root, seed)
    apply(root, seed, d, "recommended", env=AUTOPILOT)
    batch_edit(d, "@@ item 3 consistency decision A fundamental",
               "@@ item 3 consistency decision A material")

    assert apply(root, seed, d, "recommended") == 0
    assert on_disk(d / "round-complete") == "present"
    assert on_disk(d / "fundamental.md") == "absent"


# --- flow mode ---------------------------------------------------------------------------


def test_flow_mode_applies_on_the_flow_s_issue(root, seed, store):
    flow(root)
    d = round_dir(root, seed)

    assert apply(root, seed, d, "recommended", issue=None, rnd="1/1") == 0
    assert body_of(store) == CLEAN
    assert "Round 1 of 1" in comments_of(store, 14)[0]


@pytest.mark.parametrize("state, message", [
    (None, "no active flow (.orchestrator/state.json not found). Run /orchestrator:start"
           " first."),
    ("", "no issue recorded in state - the spec phase must publish one first"),
    ("done", "the flow on issue #14 is done - spec-review apply acts only on an active flow's"
             " issue; for another issue use --issue <n>"),
    ("truncated", "state.json cannot be read - run orch.sh doctor --flow"),
])
def test_flow_mode_refuses_before_any_write(root, seed, store, capsys, state, message):
    if state == "":
        flow(root, issue="")
    elif state == "done":
        flow(root, phase="done")
    elif state == "truncated":
        flow(root).write_text('{"phase": "spec", "iss')
    d = round_dir(root, seed)
    before = snapshot(store)

    assert apply(root, seed, d, "recommended", issue=None, env={"CLAUDECODE": "1"}) == 1
    assert capsys.readouterr().err == "orch: %s\n" % message
    assert snapshot(store) == before
    assert on_disk(d / "spec.fetched.md") == "absent"


def test_issue_mode_never_reads_state_json(root, seed, store):
    flow(root, phase="done").write_text('{"phase": "do')
    d = round_dir(root, seed)

    assert apply(root, seed, d, "recommended") == 0
    assert body_of(store) == CLEAN
