"""`review known-items <path> <loop boundary>`, review.run in-process in a
FakeGit checkout under tmp_path with its flow state, handoffs and review
records - the cases of the bash review known-items sections: each heading's
sources and tags, None, the boundary refusal, a refused run leaving the file
as it was, a failed write, and an autopilot flow's handoffs read from their
comments (#1457). Its usage line and the no-flow refusal are
test_review_noun.py's."""
from __future__ import annotations

import os

import pytest

from conftest import (AUTOPILOT, CLAUDE, GH_502, answered, hold_flow, lines, orch_review, record,
                      write)


PLAN = lines("## Decisions", "Placeholder.", "", "## Rejected alternatives", "",
             "- Driver-side matching made cheaper", "  - the waste is the reviewers' output",
             "A bare line of its own", "", "## Constraints", "None")
IMPLEMENT = lines("## PR", "#7", "## Deviations", "", "- Built the key from the slug,",
                  "  not from the member", "- None of the cache was kept", "## Verification",
                  "ok")


@pytest.fixture
def known(root):
    """A flow on issue #7 holding the plan and implement handoffs and three
    review records, with a reviewer's report and an empty one beside the
    third: the known-items path, holding stale content."""
    hold_flow(root, slug="x", phase="review", issue=7)
    write(root, ".orchestrator/handoff/01-plan.md", raw=PLAN)
    write(root, ".orchestrator/handoff/03-implement.md", raw=IMPLEMENT)
    record(root, 1, raw=lines(
        "# Review iteration 1", "## Waiting to be filed", "",
        "- Standards/nit: `a.sh:3` an old loop nit - final iteration", "## Filed", "",
        "- #41 nit: a.sh:3 old loop nit"))
    record(root, 2, raw=lines(
        "# Review iteration 2", "## Waiting to be filed", "None", "## Filed", "None."))
    record(root, 3, raw=lines(
        "# Review iteration 3", "## Waiting to be filed", "",
        "- Spec/major: `b.sh:10` the parser is duplicated - needs a decision",
        "- Standards/nit: - the name reads oddly - not mechanical", "## Filed", "",
        "- #99 major: b.sh:1 never read below the boundary"))
    record(root, 3, report="spec", raw="")
    record(root, 3, report="standards", raw=lines(
        "## Waiting to be filed", "- Standards/nit: `x.sh:1` a report, not a record - x"))
    return write(root, "known.md", raw="stale content\n")


def test_every_source_lands_under_its_heading_with_its_tag_overwriting_the_file(root, seed,
                                                                                known, capsys):
    assert orch_review(seed, root, "known-items", str(known), "2") == 0
    assert capsys.readouterr() == ("", "")
    assert known.read_text() == lines(
        "## Deviations",
        "- Built the key from the slug, not from the member",
        "- None of the cache was kept",
        "## Known items",
        "- Spec/major: `b.sh:10` the parser is duplicated - needs a decision"
        " - waiting to be filed, iteration 03",
        "- Standards/nit: - the name reads oddly - not mechanical"
        " - waiting to be filed, iteration 03",
        "- #41 nit: a.sh:3 old loop nit - filed #41",
        "- Driver-side matching made cheaper - the waste is the reviewers' output"
        " - rejected alternative",
        "- A bare line of its own - rejected alternative")


def test_a_boundary_with_no_record_above_it_reads_every_record_as_filed(root, seed, known):
    assert orch_review(seed, root, "known-items", str(known), "3") == 0
    text = known.read_text()
    assert "waiting to be filed" not in text
    assert "- #99 major: b.sh:1 never read below the boundary - filed #99\n" in text


def test_the_boundary_is_read_in_base_10(root, seed, known):
    assert orch_review(seed, root, "known-items", str(known), "08") == 0
    assert "waiting to be filed" not in known.read_text()


def test_a_filed_entry_with_no_issue_number_is_tagged_filed_alone(root, seed, known):
    record(root, 2, raw=lines("## Filed", "- nit: never filed by number"))

    assert orch_review(seed, root, "known-items", str(known), "3") == 0
    assert "- nit: never filed by number - filed\n" in known.read_text()


def test_a_sites_bullet_waiting_to_be_filed_is_one_whole_known_item(root, seed, known):
    record(root, 4, raw=lines(
        "# Review iteration 4", "## Waiting to be filed", "",
        "- Standards/nit: `a.sh:3` the helper is copied per script Sites: `a.sh:3`, `b.sh:9`."
        " - needs a decision (`a.sh:3`); loop-authored lines (`b.sh:9`)",
        "## Filed", "None."))

    assert orch_review(seed, root, "known-items", str(known), "3") == 0
    assert ("- Standards/nit: `a.sh:3` the helper is copied per script Sites: `a.sh:3`,"
            " `b.sh:9`. - needs a decision (`a.sh:3`); loop-authored lines (`b.sh:9`)"
            " - waiting to be filed, iteration 04\n") in known.read_text()


def test_a_fenced_heading_does_not_cut_a_filed_entry_short(root, seed, known):
    record(root, 4, raw=lines(
        "# Review iteration 4", "## Filed", "", "- #41 nit: quoted template", "```",
        "## Heading", "```", "- #42 nit: next"))

    assert orch_review(seed, root, "known-items", str(known), "4") == 0
    text = known.read_text()
    assert "- #41 nit: quoted template ``` ## Heading ``` - filed #41\n" in text
    assert "- #42 nit: next - filed #42\n" in text


def test_sources_that_all_say_none_read_none_under_both_headings(root, seed, known):
    write(root, ".orchestrator/handoff/01-plan.md", raw=lines("## Rejected alternatives", "None."))
    write(root, ".orchestrator/handoff/03-implement.md", raw=lines("## Deviations", "- None"))
    for name in ("iteration-01.md", "iteration-03.md"):
        os.remove(str(root / ".orchestrator/review" / name))

    assert orch_review(seed, root, "known-items", str(known), "0") == 0
    assert known.read_text() == lines("## Deviations", "None.", "## Known items", "None.")


def test_a_flow_with_no_review_directory_reads_no_record(root, seed, capsys):
    hold_flow(root, slug="x", phase="review", issue=7)
    write(root, ".orchestrator/handoff/01-plan.md", raw=PLAN)
    write(root, ".orchestrator/handoff/03-implement.md", raw=lines("## Deviations", "None"))
    path = root / "known.md"

    assert orch_review(seed, root, "known-items", str(path), "0") == 0
    assert path.read_text() == lines(
        "## Deviations", "None.", "## Known items",
        "- Driver-side matching made cheaper - the waste is the reviewers' output"
        " - rejected alternative",
        "- A bare line of its own - rejected alternative")


@pytest.mark.parametrize("boundary", ["two", "-1", ""])
def test_a_boundary_that_is_no_number_is_refused_leaving_the_file_as_it_was(root, seed, known,
                                                                            capsys, boundary):
    known.write_text("kept\n")

    assert answered(capsys, orch_review(seed, root, "known-items", str(known), boundary)) == (
        1, "", "orch: not a loop boundary: %s (want the iteration read before the loop's"
               " first)\n" % boundary)
    assert known.read_text() == "kept\n"


@pytest.mark.parametrize("handoff", ["03-implement", "01-plan"])
def test_a_missing_handoff_is_refused_writing_no_file(root, seed, known, capsys, handoff):
    os.remove(str(root / ".orchestrator/handoff" / (handoff + ".md")))
    fresh = root / "fresh.md"

    assert answered(capsys, orch_review(seed, root, "known-items", str(fresh), "0")) == (
        1, "", "orch: handoff not found: %s/.orchestrator/handoff/%s.md\n" % (root, handoff))
    assert not fresh.exists()


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_failed_write_dies_leaving_the_existing_file_as_it_was(root, seed, known, capsys):
    known.write_text("kept\n")
    os.chmod(str(root), 0o555)
    try:
        code, out, err = answered(capsys, orch_review(seed, root, "known-items", str(known), "2"))
    finally:
        os.chmod(str(root), 0o755)

    assert (code, out, err) == (1, "", "orch: could not write the known items to %s\n" % known)
    assert known.read_text() == "kept\n"


def test_the_records_are_read_in_name_order(root, seed, known):
    record(root, 10, raw=lines("## Waiting to be filed", "- ten"))
    record(root, 4, raw=lines("## Waiting to be filed", "- four"))

    assert orch_review(seed, root, "known-items", str(known), "3") == 0
    text = known.read_text()
    assert text.index("- four - waiting to be filed, iteration 04") < text.index(
        "- ten - waiting to be filed, iteration 10")


# --- an autopilot flow's handoffs are comments (#1457) ------------------------


@pytest.fixture
def commented(root, seed):
    """An autopilot flow on issue #7, its handoff directory gone, its plan
    and implement handoffs posted as comments on the issue."""
    hold_flow(root, slug="x", phase="review", issue=7)
    seed.issue(7, "open", "ready-for-agent", "orch:review", "orch:running")
    seed.comment(7, "o", "2026-01-01T00:00:00Z", "<!-- orch:handoff 01-plan -->\n" + lines(
        "## Decisions", "None", "", "## Rejected alternatives", "", "- Polling the PR",
        "  - too slow"))
    seed.comment(7, "o", "2026-01-02T00:00:00Z", "<!-- orch:handoff 03-implement -->\n" + lines(
        "## PR", "#7", "## Deviations", "", "- Kept the cache", "## Verification", "ok"))
    (root / ".orchestrator" / "review").mkdir()


def test_an_autopilot_flow_reads_its_handoffs_from_the_issue_s_comments(root, seed, commented,
                                                                       capsys):
    path = root / "known.md"

    assert orch_review(seed, root, "known-items", str(path), "0", env=AUTOPILOT) == 0
    assert capsys.readouterr() == ("", "")
    assert path.read_text() == lines(
        "## Deviations", "- Kept the cache", "## Known items",
        "- Polling the PR - too slow - rejected alternative")


def test_an_autopilot_flow_whose_comments_cannot_be_read_writes_no_file(root, seed, commented,
                                                                       capsys):
    seed.fail("adapter_issue_comments", GH_502)
    path = root / "known.md"

    code, out, err = answered(capsys, orch_review(seed, root, "known-items", str(path), "0",
                                                  env=AUTOPILOT))
    assert (code, out, err.startswith("orch: ")) == (1, "", True)
    assert not path.exists()


def test_an_autopilot_session_refuses_a_boundary_as_a_plain_one(root, seed, known, capsys):
    runs = [answered(capsys, orch_review(seed, root, "known-items", str(known), "x", env=env))
            for env in (CLAUDE, AUTOPILOT)]

    assert runs[0] == runs[1] == (
        1, "", "orch: not a loop boundary: x (want the iteration read before the loop's"
               " first)\n")
    assert known.read_text() == "stale content\n"
