"""The autopilot noun's question, reply and re-entry verbs - `questions`,
`reply`, `resume`, `ask`, `answer` and `reenter` - run in-process through
autopilot.run in a FakeGit checkout under tmp_path, against the gh fake on a
tmp_path store: their output, comments, labels, claims, messages and exit
codes. Ported from the bash autopilot sections that held them - autopilot
ask and answer, autopilot reenter, autopilot questions, reply and resume,
the phase argument, answer on a truncated state.json, the label casing,
answer with no repo, and the session ops' issue read."""
from __future__ import annotations

import os

import pytest

from conftest import (AUTOPILOT, CLAUDE, GH_502, SESSIONS, comments_of, flow_state, hold_flow,
                      labels_of, read, snapshot, state_json)
from orch import autopilot
from orch.gh import Gh
from orch.marked_comment import marked_comment_write
from orch.repo import REPO_REMEDY, RepoPin
from test_autopilot import ap, checkout

QUESTION = "1. Keep it? Recommended: yes\n\nReply like `1: A`.\n"
REPLY_FORMAT = ("Reply in one comment like `1: A, 2: recommended, 3: <free text>`"
                " (`all: recommended` accepts everything).\n")


def marker_of(kind, phase, tag=""):
    """The hidden marker line a comment of <kind> in <phase> opens with,
    without its newline."""
    return marked_comment_write(kind, phase, tag).rstrip("\n")


def text_file(tmp_path, name, text):
    """<text> written to tmp_path/<name>: its path, a str."""
    path = tmp_path / name
    path.write_text(text)
    return str(path)


def comment_reads(store):
    """How many times the gh fake read an issue's comments."""
    return (read(store, "comment_reads") or "").count("\n")


def held(seed, n, *labels):
    """Issue #n open, carrying <labels>, its claim held."""
    seed.issue(n, "open", *labels)
    seed.claim(n)


def run_ap(seed, root, env, *argv):
    return ap(seed, checkout(root), env, *argv)


# --- ask ------------------------------------------------------------------------


@pytest.fixture
def asking(root, seed):
    """The flow's issue #7 at orch:spec, its session running under its
    claim; the flow state records it."""
    flow_state(root, "spec", 7)
    held(seed, 7, "ready-for-agent", "orch:spec", "orch:running")


def test_ask_posts_the_marked_question_to_the_handle_adds_needs_human_and_releases(
        root, seed, store, capsys, tmp_path, asking):
    q = text_file(tmp_path, "q.md", QUESTION)

    assert (run_ap(seed, root, AUTOPILOT, "ask", "spec", q), capsys.readouterr()) == (0, ("", ""))
    assert comments_of(store, 7) == [
        "<!-- orch:question spec -->\n@o\n\n" + QUESTION + "\n" + REPLY_FORMAT]
    assert sorted(labels_of(store, 7)) == ["needs-human", "orch:spec", "ready-for-agent"]
    assert seed.claim_held(7) is False


def test_ask_mentions_the_handle_setting_when_one_is_set(root, seed, store, tmp_path, asking):
    git = checkout(root, local={"orchestrator.autopilot.handle": "maintainer"})

    assert ap(seed, git, AUTOPILOT, "ask", "spec", text_file(tmp_path, "q.md", "Q\n")) == 0
    assert comments_of(store, 7)[0].split("\n")[1] == "@maintainer"


def test_ask_adds_needs_human_in_the_repo_s_casing(root, seed, store, tmp_path, asking):
    seed.label_names("Needs-Human", "orch:spec", "orch:running", "ready-for-agent")

    assert run_ap(seed, root, AUTOPILOT, "ask", "spec", text_file(tmp_path, "q.md", "Q\n")) == 0
    assert sorted(labels_of(store, 7)) == ["Needs-Human", "orch:spec", "ready-for-agent"]


def test_ask_failing_partway_dies_naming_the_writes_that_landed_the_claim_held(
        root, seed, capsys, tmp_path, asking):
    seed.fail("adapter_issue_relabel", "HTTP 500")

    assert (run_ap(seed, root, AUTOPILOT, "ask", "spec", text_file(tmp_path, "q.md", "Q\n")),
            capsys.readouterr()) == (1, ("", "orch: could not add needs-human on issue #7:"
                                             " HTTP 500 - writes that landed: posted the spec"
                                             " question comment; the claim stays held\n"))
    assert seed.claim_held(7) is True


def test_ask_whose_temp_body_file_cannot_be_made_dies_before_any_write(
        root, seed, store, capsys, tmp_path, monkeypatch, asking):
    q = text_file(tmp_path, "q.md", "Q\n")
    monkeypatch.setattr("tempfile.tempdir", str(tmp_path / "missing"))

    assert (run_ap(seed, root, AUTOPILOT, "ask", "spec", q), capsys.readouterr()) == (
        1, ("", "orch: could not create a temp file to post the spec question comment - writes"
                " that landed: none; the claim stays held\n"))
    assert (seed.claim_held(7), comments_of(store, 7), labels_of(store, 7)) == (
        True, [], ["ready-for-agent", "orch:spec", "orch:running"])


@pytest.mark.parametrize("fail", [None, "adapter_issue_comment"], ids=["posted", "failed post"])
def test_ask_leaves_no_temp_body_file_behind(root, seed, tmp_path, monkeypatch, asking, fail):
    q = text_file(tmp_path, "q.md", "Q\n")
    temp = tmp_path / "temp"
    temp.mkdir()
    monkeypatch.setattr("tempfile.tempdir", str(temp))
    if fail:
        seed.fail(fail, "HTTP 500")

    run_ap(seed, root, AUTOPILOT, "ask", "spec", q)

    assert os.listdir(str(temp)) == []


@SESSIONS
@pytest.mark.parametrize("op", ["ask", "answer"])
@pytest.mark.parametrize("phase, refusal", [
    ("bogus", "not a flow phase: bogus (want spec|implement|review|done)"),
    ("spec implement", "not a flow phase: spec implement (want spec|implement|review|done)"),
    ("done", "a done flow asks no question"),
], ids=["unknown", "two adjacent phases", "done"])
def test_a_phase_no_question_is_asked_in_is_refused_before_any_read(
        root, seed, store, capsys, tmp_path, asking, env, op, phase, refusal):
    before = snapshot(store)

    assert (run_ap(seed, root, env, op, phase, text_file(tmp_path, "f.md", "Q\n")),
            capsys.readouterr()) == ({"ask": 1, "answer": 2}[op], ("", "orch: %s\n" % refusal))
    assert snapshot(store) == before


def test_ask_with_a_missing_question_file_is_refused(root, seed, capsys, tmp_path, asking):
    missing = str(tmp_path / "none.md")

    assert (run_ap(seed, root, AUTOPILOT, "ask", "spec", missing), capsys.readouterr()) == (
        1, ("", "orch: question file not found: %s\n" % missing))


# --- answer ---------------------------------------------------------------------


@pytest.fixture
def asked(root, seed, tmp_path, asking):
    """Issue #7 asked the spec question QUESTION: the answer file's path,
    holding `old answer`."""
    assert run_ap(seed, root, AUTOPILOT, "ask", "spec", text_file(tmp_path, "q.md", QUESTION)) == 0
    return text_file(tmp_path, "ans.md", "old answer\n")


@SESSIONS
def test_answer_with_no_reply_exits_1_leaving_the_answer_file(root, seed, capsys, asked, env):
    assert (run_ap(seed, root, env, "answer", "spec", asked), capsys.readouterr()) == (
        1, ("", "orch: no reply to the spec question on issue #7 yet\n"))
    assert open(asked).read() == "old answer\n"


@SESSIONS
def test_answer_writes_the_question_then_each_later_comment_after_a_rule(
        root, seed, capsys, asked, env):
    seed.comment(7, "o", "2026-01-02T00:00:00Z", "1: A")
    seed.comment(7, "o", "2026-01-03T00:00:00Z", "thanks")

    assert (run_ap(seed, root, env, "answer", "spec", asked), capsys.readouterr()) == (
        0, ("", ""))
    assert open(asked).read() == (
        "@o\n\n" + QUESTION + "\n" + REPLY_FORMAT + "\n---\n1: A\n---\nthanks\n")


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_answer_into_a_read_only_directory_exits_2_leaving_the_file(
        root, seed, capsys, tmp_path, asked):
    seed.comment(7, "o", "2026-01-02T00:00:00Z", "1: A")
    directory = tmp_path / "ro"
    directory.mkdir()
    kept = text_file(directory, "ans.md", "keep\n")
    os.chmod(str(directory), 0o555)
    try:
        assert (run_ap(seed, root, CLAUDE, "answer", "spec", kept), capsys.readouterr()) == (
            2, ("", "orch: could not write %s\n" % kept))
        assert open(kept).read() == "keep\n"
    finally:
        os.chmod(str(directory), 0o755)


def test_answer_for_a_phase_never_asked_exits_2_never_no_reply_s_1(
        root, seed, capsys, asked):
    assert (run_ap(seed, root, CLAUDE, "answer", "implement", asked), capsys.readouterr()) == (
        2, ("", "orch: issue #7 has no implement question comment\n"))
    assert open(asked).read() == "old answer\n"


@pytest.mark.parametrize("break_read, message", [
    (lambda seed: seed.fail("adapter_issue_comments", "HTTP 500"),
     "orch: gh could not read the comments of issue #7: HTTP 500\n"),
    (lambda seed: seed.lag("adapter_issue_comments", 1, "not json"),
     "orch: could not read issue #7's comments\n"),
], ids=["failed", "unparseable"])
def test_a_comments_read_that_fails_exits_2_never_no_reply_s_1(
        root, seed, capsys, asked, break_read, message):
    break_read(seed)

    assert (run_ap(seed, root, CLAUDE, "answer", "spec", asked), capsys.readouterr()) == (
        2, ("", message))


def test_a_question_ending_in_noreply_is_read_as_any_other(root, seed, capsys, tmp_path):
    flow_state(root, "spec", 8)
    seed.issue(8, "open", "ready-for-agent", "orch:spec")
    seed.comment(8, "o", "2026-01-01T00:00:00Z",
                 marker_of("question", "spec") + "\nKeep it? noreply")
    ans = text_file(tmp_path, "ans.md", "")

    assert run_ap(seed, root, CLAUDE, "answer", "spec", ans) == 1
    assert "no reply" in capsys.readouterr().err
    seed.comment(8, "o", "2026-01-02T00:00:00Z", "1: A")
    assert run_ap(seed, root, CLAUDE, "answer", "spec", ans) == 0
    assert open(ans).read() == "Keep it? noreply\n---\n1: A\n"


@pytest.fixture
def reviewed(root, seed):
    """Issue #80 at orch:review under its claim, the flow's issue."""
    flow_state(root, "review", 80)
    held(seed, 80, "orch:review", "orch:running")


@pytest.mark.parametrize("comments, code", [
    ((("question", "q"), ("reentry", "r")), 1),
    ((("reentry", "r"),), 1),
    ((("reentry", "r"), ("question", "q"), (None, "1: A")), 0),
    ((("question", "q"), ("reentry", "r"), (None, "1: A")), 1),
], ids=["re-entry after the question", "re-entry and no question", "question after the re-entry",
        "a reply after the re-entry"])
def test_answer_after_an_automatic_re_entry_exits_1_writing_nothing(
        root, seed, capsys, tmp_path, reviewed, comments, code):
    for day, (kind, text) in enumerate(comments, 1):
        body = marker_of(kind, "review") + "\n" + text if kind else text
        seed.comment(80, "o", "2026-01-0%dT00:00:00Z" % day, body)
    ans = text_file(tmp_path, "ans.md", "keep\n")

    assert run_ap(seed, root, CLAUDE, "answer", "review", ans) == code
    err = capsys.readouterr().err
    if code:
        assert err == ("orch: issue #80 was re-entered automatically in review - no reply to"
                       " read\n")
        assert open(ans).read() == "keep\n"


def test_answer_on_a_truncated_state_json_exits_2_with_the_unreadable_line(
        root, seed, capsys, tmp_path, asked):
    state = state_json(root)
    state.write_text(state.read_text()[:10])

    assert (run_ap(seed, root, AUTOPILOT, "answer", "spec", asked), capsys.readouterr()) == (
        2, ("", "orch: state.json cannot be read - run orch.sh doctor --flow\n"))


# --- answer with no repo ------------------------------------------------------------


def no_repo(root):
    return checkout(root, origin=None)


def test_answer_with_no_repo_exits_2_with_the_remedy_alone_calling_no_gh(
        root, seed, store, capsys, tmp_path):
    flow_state(root, "spec", 7)
    ans = text_file(tmp_path, "ans.md", "old answer\n")

    assert (ap(seed, no_repo(root), CLAUDE, "answer", "spec", ans), capsys.readouterr()) == (
        2, ("", "orch: %s\n" % REPO_REMEDY))
    assert (comment_reads(store), open(ans).read()) == (0, "old answer\n")


@pytest.mark.parametrize("state, phase, refusal", [
    ({"slug": "x", "phase": "spec", "issue": None}, "spec",
     "no issue recorded in state - the spec phase must publish one first"),
    ({"slug": "x", "phase": "spec", "issue": 7}, "bogus",
     "not a flow phase: bogus (want spec|implement|review|done)"),
    (None, "spec", "no active flow (.orchestrator/state.json not found). Run"),
], ids=["no issue recorded", "a bad phase", "no flow state"])
def test_with_no_repo_answer_s_own_refusal_wins_over_the_remedy(
        root, seed, capsys, tmp_path, state, phase, refusal):
    if state is not None:
        hold_flow(root, **state)

    assert ap(seed, no_repo(root), CLAUDE, "answer", phase, text_file(tmp_path, "a.md", "")) == 2
    err = capsys.readouterr().err
    assert err.startswith("orch: " + refusal) and REPO_REMEDY not in err


# --- the session ops' issue read --------------------------------------------------


@pytest.mark.parametrize("argv, code", [
    (("ask", "spec"), 1),
    (("answer", "spec"), 2),
    (("reenter", "review"), 1),
])
def test_a_session_op_with_no_issue_recorded_refuses_making_no_gh_call(
        root, seed, store, capsys, tmp_path, argv, code):
    hold_flow(root, slug="x", phase="spec", issue=None)
    seed.issue(7, "open", "orch:spec")
    before = snapshot(store)

    assert (run_ap(seed, root, AUTOPILOT, *argv, text_file(tmp_path, "f.md", "text\n")),
            capsys.readouterr()) == (code, ("", "orch: no issue recorded in state - the spec"
                                                " phase must publish one first\n"))
    assert (snapshot(store), comment_reads(store)) == (before, 0)


def test_answer_and_reenter_each_read_the_issue_s_comments_once(
        root, seed, store, tmp_path, reviewed):
    seed.comment(80, "o", "2026-01-01T00:00:00Z", marker_of("question", "review") + "\nq")
    seed.comment(80, "o", "2026-01-02T00:00:00Z", "1: A")

    assert run_ap(seed, root, CLAUDE, "answer", "review", text_file(tmp_path, "a.md", "")) == 0
    assert comment_reads(store) == 1
    assert run_ap(seed, root, AUTOPILOT, "reenter", "review",
                  text_file(tmp_path, "r.md", "again\n")) == 0
    assert comment_reads(store) == 2


# --- reenter --------------------------------------------------------------------

RE_TEXT = "Stop: final iteration not clean. Filed #99.\n"


def reenter(seed, root, tmp_path, phase="review"):
    return run_ap(seed, root, AUTOPILOT, "reenter", phase, text_file(tmp_path, "re.md", RE_TEXT))


def newest_comment(store, n):
    return comments_of(store, n)[-1]


def test_reenter_posts_the_marked_re_entry_comment_and_releases_the_claim(
        root, seed, store, capsys, tmp_path, reviewed):
    assert (reenter(seed, root, tmp_path), capsys.readouterr()) == (0, ("", ""))
    assert comments_of(store, 80) == [
        "<!-- orch:reentry review -->\n" + RE_TEXT + "\n\nThe watcher starts another review"
        " loop.\n"]
    assert (labels_of(store, 80), seed.claim_held(80)) == (["orch:review"], False)


def test_with_one_earlier_re_entry_it_re_enters_again(root, seed, store, tmp_path, reviewed):
    seed.comment(80, "o", "2026-01-01T00:00:00Z", marker_of("reentry", "review") + "\nfirst")

    assert reenter(seed, root, tmp_path) == 0
    assert newest_comment(store, 80).startswith("<!-- orch:reentry review -->\n")
    assert labels_of(store, 80) == ["orch:review"]


def test_with_two_earlier_re_entries_it_asks_instead(root, seed, store, tmp_path, reviewed):
    seed.comment(80, "o", "2026-01-01T00:00:00Z", marker_of("reentry", "review") + "\nfirst")
    seed.comment(80, "o", "2026-01-02T00:00:00Z", marker_of("limited", "review") + "\nwait")
    seed.comment(80, "o", "2026-01-03T00:00:00Z", marker_of("reentry", "review") + "\nsecond")

    assert reenter(seed, root, tmp_path) == 0
    assert newest_comment(store, 80) == (
        "<!-- orch:question review -->\n@o\n\n" + RE_TEXT + "\n\nThis follows two automatic"
        " re-entries of the review loop, so it asks instead of starting another.\n\n"
        + REPLY_FORMAT)
    assert (sorted(labels_of(store, 80)), seed.claim_held(80)) == (
        ["needs-human", "orch:review"], False)


@pytest.mark.parametrize("association, opening", [
    ("OWNER", "<!-- orch:reentry review -->"),
    ("NONE", "<!-- orch:question review -->"),
], ids=["a trusted reply ends the count", "an untrusted reply does not"])
def test_the_re_entry_count_reads_only_trusted_comments(
        root, seed, store, tmp_path, reviewed, association, opening):
    seed.comment(80, "o", "2026-01-01T00:00:00Z", marker_of("reentry", "review") + "\na")
    seed.comment(80, "o", "2026-01-02T00:00:00Z", marker_of("reentry", "review") + "\nb")
    seed.comment(80, "someone", "2026-01-03T00:00:00Z", "a reply", association)

    assert reenter(seed, root, tmp_path) == 0
    assert newest_comment(store, 80).split("\n")[0] == opening


def test_reenter_failing_partway_dies_naming_the_writes_that_landed_the_claim_held(
        root, seed, capsys, tmp_path, reviewed):
    seed.fail("adapter_claim_delete", "HTTP 500")

    assert (reenter(seed, root, tmp_path), capsys.readouterr()) == (
        1, ("", "orch: could not delete the claim ref on issue #80: HTTP 500 - writes that"
                " landed: posted the review re-entry comment, removed orch:running; the claim"
                " stays held\n"))
    assert seed.claim_held(80) is True


def test_a_failed_comments_read_writes_nothing(root, seed, store, tmp_path, reviewed):
    seed.fail("adapter_issue_comments", "HTTP 500")

    reenter(seed, root, tmp_path)

    assert (comments_of(store, 80), labels_of(store, 80)) == ([], ["orch:review", "orch:running"])


def test_a_phase_other_than_review_is_refused_before_any_write(
        root, seed, store, capsys, tmp_path, reviewed):
    before = snapshot(store)

    assert (reenter(seed, root, tmp_path, "implement"), capsys.readouterr()) == (
        1, ("", "orch: only the review phase re-enters automatically, got: implement\n"))
    assert snapshot(store) == before


# --- questions ------------------------------------------------------------------


def question_of(phase):
    return marker_of("question", phase) + "\n@o\n\n1. Keep it? Recommended: yes\n"


def url_of(n, k):
    return "https://github.com/o/r/issues/%d#issuecomment-%d" % (n, k)


@SESSIONS
def test_questions_with_nothing_labelled_needs_human_says_nothing_is_pending(
        root, seed, capsys, env):
    assert (run_ap(seed, root, env, "questions"), capsys.readouterr()) == (
        0, ("nothing pending: no open needs-human issue of an autopilot flow\n", ""))


@SESSIONS
def test_questions_lists_each_pending_issue_s_kind_phase_and_comment(
        root, seed, capsys, env):
    seed.issue(11, "open", "needs-human", "orch:spec")
    seed.comment(11, "o", "2026-01-01T00:00:00Z", question_of("spec"))
    # several earlier questions: only the newest counts, across phases
    seed.issue(12, "open", "needs-human", "orch:review")
    for day, phase in enumerate(("spec", "implement", "review"), 1):
        seed.comment(12, "o", "2026-01-0%dT00:00:00Z" % day, question_of(phase))
    seed.issue(13, "open", "needs-human", "orch:implement")
    seed.comment(13, "o", "2026-01-01T00:00:00Z", question_of("implement"))
    seed.comment(13, "h", "2026-01-02T00:00:00Z", "1: A")
    # a stop whose phase differs from the label's
    seed.issue(14, "open", "needs-human", "orch:review")
    seed.comment(14, "o", "2026-01-01T00:00:00Z", marker_of("failure", "implement") + "\nx")
    # neither comment: the earliest labelled phase
    seed.issue(15, "open", "needs-human", "orch:review", "orch:implement")
    seed.issue(16, "open", "needs-human", "orch:spec")
    seed.comment(16, "o", "2026-01-01T00:00:00Z", question_of("spec"))
    seed.comment(16, "o", "2026-01-02T00:00:00Z", marker_of("refusal", "spec") + "\nno plan")
    seed.issue(17, "open", "needs-human", "orch:spec")
    seed.comment(17, "o", "2026-01-01T00:00:00Z", marker_of("refusal", "spec") + "\nno plan")
    seed.comment(17, "o", "2026-01-09T00:00:00Z", question_of("spec"))
    # left out: no phase label, orch:done, closed, and not needs-human
    seed.issue(18, "open", "needs-human", "ready-for-agent")
    seed.issue(19, "open", "needs-human", "orch:done")
    seed.issue(20, "closed", "needs-human", "orch:spec")
    seed.issue(21, "open", "orch:spec")
    seed.comment(21, "o", "2026-01-01T00:00:00Z", question_of("spec"))
    # a question only a re-entry comment follows is still a question
    seed.issue(26, "open", "needs-human", "orch:spec")
    seed.comment(26, "o", "2026-01-01T00:00:00Z", question_of("spec"))
    seed.comment(26, "o", "2026-01-02T00:00:00Z", marker_of("reentry", "spec") + "\nagain")
    # an issue re-entered automatically, not waiting on the human
    seed.issue(83, "open", "orch:review")
    seed.comment(83, "o", "2026-01-01T00:00:00Z", marker_of("reentry", "review") + "\nr")

    assert (run_ap(seed, root, env, "questions"), capsys.readouterr()) == (0, ("".join(
        "\t".join(row) + "\n" for row in [
            ("11", "question", "spec", url_of(11, 1)),
            ("12", "question", "review", url_of(12, 3)),
            ("13", "replied", "implement", url_of(13, 1)),
            ("14", "stop", "implement", url_of(14, 1)),
            ("15", "stop", "implement", ""),
            ("16", "stop", "spec", url_of(16, 2)),
            ("17", "question", "spec", url_of(17, 2)),
            ("26", "question", "spec", url_of(26, 1)),
        ]), ""))


@pytest.mark.parametrize("labels, stop_phase, row", [
    (("needs-human", "orch:done", "orch:sync"), "sync", "stop\tsync"),
    (("needs-human", "orch:done"), "sync", "stop\tsync"),
    (("needs-human", "orch:done", "orch:sync"), None, "stop\tsync"),
    (("needs-human", "orch:done"), "review", None),
], ids=["a failed sync", "a sync's dropped intents", "orch:sync, no stop comment",
        "a done flow's old stop"])
def test_a_done_issue_is_listed_only_when_a_sync_stopped_it(
        root, seed, capsys, labels, stop_phase, row):
    seed.issue(40, "open", *labels)
    if stop_phase:
        seed.comment(40, "o", "2026-01-01T00:00:00Z", marker_of("failure", stop_phase) + "\nx")

    assert run_ap(seed, root, CLAUDE, "questions") == 0
    out = capsys.readouterr().out
    if row is None:
        assert out.startswith("nothing pending")
    else:
        assert out.startswith("40\t" + row + "\t")


def test_questions_at_the_issue_list_limit_warns_and_lists_the_oldest(root, seed, capsys):
    for n in (31, 32, 33):
        seed.issue(n, "open", "needs-human", "orch:spec")

    assert run_ap(seed, root, dict(CLAUDE, ORCH_ISSUE_LIST_LIMIT="2"), "questions") == 0
    assert capsys.readouterr() == (
        "31\tstop\tspec\t\n32\tstop\tspec\t\n",
        "orch: the open issues labelled needs-human reached the issue-list limit of 2 - the"
        " newest past it are missing from this list\n")
    assert run_ap(seed, root, dict(CLAUDE, ORCH_ISSUE_LIST_LIMIT="4"), "questions") == 0
    assert capsys.readouterr().err == ""


@pytest.mark.parametrize("break_read, message", [
    (lambda seed: seed.fail("adapter_issue_comments", GH_502),
     "orch: gh could not read the comments of issue #11: HTTP 502: Bad Gateway\n"),
    (lambda seed: seed.lag("adapter_issue_comments", 1, "not json"),
     "orch: could not read issue #11's comments\n"),
    (lambda seed: seed.fail("adapter_issues_labelled_rows", "HTTP 502"),
     "orch: gh could not list the needs-human issues: HTTP 502\n"),
], ids=["a failed comments read", "unparseable comments", "a failed listing"])
def test_questions_dies_on_a_failed_read_listing_nothing(root, seed, capsys, break_read, message):
    for n in (11, 12):
        seed.issue(n, "open", "needs-human", "orch:spec")
    break_read(seed)

    assert (run_ap(seed, root, CLAUDE, "questions"), capsys.readouterr()) == (1, ("", message))


# --- resume ---------------------------------------------------------------------


@SESSIONS
@pytest.mark.parametrize("human", ["needs-human", "Needs-Human"])
def test_resume_removes_only_needs_human_in_any_casing(root, seed, store, capsys, env, human):
    seed.issue(30, "open", human, "orch:spec")

    assert (run_ap(seed, root, env, "resume", "30"), capsys.readouterr()) == (0, ("", ""))
    assert labels_of(store, 30) == ["orch:spec"]


@pytest.mark.parametrize("seeding, issue, message", [
    (lambda seed: seed.issue(30, "open", "orch:spec"), "30",
     "orch: issue #30 does not carry needs-human\n"),
    (lambda seed: seed.issue(31, "closed", "needs-human", "orch:spec"), "31",
     "orch: issue #31 is closed\n"),
    (lambda seed: None, "x", "orch: not an issue number: x\n"),
    (lambda seed: (seed.issue(32, "open", "needs-human", "orch:spec"),
                   seed.fail("adapter_issue_relabel", "HTTP 500")), "32",
     "orch: gh could not remove needs-human from issue #32: HTTP 500\n"),
    (lambda seed: (seed.issue(33, "open", "needs-human", "orch:spec"),
                   seed.fail("adapter_issue_state_labels", "HTTP 502")), "33",
     "orch: gh could not read issue #33: HTTP 502\n"),
], ids=["without the label", "closed", "not a number", "a failed write", "a failed read"])
def test_resume_refuses_with_its_message(root, seed, store, capsys, seeding, issue, message):
    seeding(seed)

    assert (run_ap(seed, root, CLAUDE, "resume", issue), capsys.readouterr()) == (
        1, ("", message))


def test_resume_on_a_missing_issue_dies(root, seed, capsys):
    assert run_ap(seed, root, CLAUDE, "resume", "999") == 1
    assert capsys.readouterr().err.startswith("orch: gh could not read issue #999: ")


def test_resume_with_no_repo_dies_with_the_remedy(root, capsys):
    git = checkout(root, origin=None)

    with pytest.raises(SystemExit) as died:
        autopilot.run(["resume", "5"], gh=Gh(RepoPin(CLAUDE, git), CLAUDE), git=git, env=CLAUDE)
    assert (died.value.code, capsys.readouterr()) == (1, ("", "orch: %s\n" % REPO_REMEDY))


# --- reply ----------------------------------------------------------------------

REPLY = "1: Yes, keep it\n"


@pytest.fixture
def reply_file(tmp_path):
    return text_file(tmp_path, "r.md", REPLY)


def questioned(seed, n, *labels):
    """Issue #n open, carrying <labels>, a spec question comment on it."""
    seed.issue(n, "open", *labels)
    seed.comment(n, "o", "2026-01-01T00:00:00Z", question_of("spec"))


@SESSIONS
@pytest.mark.parametrize("human", ["needs-human", "Needs-Human"])
def test_reply_posts_the_file_and_removes_needs_human(
        root, seed, store, capsys, reply_file, env, human):
    questioned(seed, 40, human, "orch:spec")

    assert (run_ap(seed, root, env, "reply", "40", reply_file), capsys.readouterr()) == (
        0, ("", ""))
    assert (comments_of(store, 40)[-1], labels_of(store, 40)) == (REPLY, ["orch:spec"])


def test_reply_posts_when_only_a_re_entry_comment_follows_the_question(
        root, seed, store, reply_file):
    questioned(seed, 940, "needs-human", "orch:spec")
    seed.comment(940, "o", "2026-01-02T00:00:00Z", marker_of("reentry", "spec") + "\nagain")

    assert run_ap(seed, root, CLAUDE, "reply", "940", reply_file) == 0
    assert (comments_of(store, 940)[-1], labels_of(store, 940)) == (REPLY, ["orch:spec"])


def test_a_reply_whose_label_removal_fails_says_the_comment_landed(
        root, seed, store, capsys, reply_file):
    questioned(seed, 41, "needs-human", "orch:spec")
    seed.fail("adapter_issue_relabel", "HTTP 500")

    assert (run_ap(seed, root, CLAUDE, "reply", "41", reply_file), capsys.readouterr()) == (
        1, ("", "orch: the reply comment landed on issue #41, but needs-human could not be"
                " removed: HTTP 500\n"))
    assert comments_of(store, 41)[-1] == REPLY


def test_a_failed_reply_post_leaves_the_label(root, seed, store, capsys, reply_file):
    questioned(seed, 42, "needs-human", "orch:spec")
    seed.fail("adapter_issue_comment", "HTTP 500")

    assert (run_ap(seed, root, CLAUDE, "reply", "42", reply_file), capsys.readouterr()) == (
        1, ("", "orch: gh could not post the reply on issue #42: HTTP 500\n"))
    assert labels_of(store, 42) == ["needs-human", "orch:spec"]


def refusal_seeds(seed):
    seed.issue(43, "open", "orch:spec")
    seed.comment(43, "o", "2026-01-01T00:00:00Z", question_of("spec"))
    questioned(seed, 44, "needs-human", "orch:spec")
    seed.comment(44, "h", "2026-01-02T00:00:00Z", "1: A")
    seed.issue(45, "open", "needs-human", "orch:spec")
    questioned(seed, 46, "needs-human", "orch:spec")
    questioned(seed, 47, "needs-human", "orch:spec")


@pytest.mark.parametrize("issue, file, setup, message", [
    ("43", "r", None, "orch: issue #43 does not carry needs-human\n"),
    ("44", "r", None, "orch: a reply already follows the newest question on issue #44\n"),
    ("45", "r", None, "orch: issue #45 has no question comment to reply to\n"),
    ("46", "missing", None, "orch: reply file not found: {file}\n"),
    ("46", "empty", None, "orch: reply file is empty: {file}\n"),
    ("47", "r", lambda seed: seed.lag("adapter_issue_comments", 1, "not json"),
     "orch: could not read issue #47's comments\n"),
    ("47", "r", lambda seed: seed.fail("adapter_issue_comments", "HTTP 500 comments"),
     "orch: gh could not read the comments of issue #47: HTTP 500 comments\n"),
    ("x", "r", None, "orch: not an issue number: x\n"),
], ids=["no needs-human", "already replied", "no question", "a missing file", "an empty file",
        "unparseable comments", "a failed comments read", "not a number"])
def test_reply_refusals_post_nothing_and_keep_the_label(
        root, seed, store, capsys, tmp_path, issue, file, setup, message):
    refusal_seeds(seed)
    path = {"r": text_file(tmp_path, "r.md", REPLY), "missing": str(tmp_path / "none.md"),
            "empty": text_file(tmp_path, "e.md", "")}[file]
    before = snapshot(store)
    if setup:
        setup(seed)

    assert (run_ap(seed, root, CLAUDE, "reply", issue, path), capsys.readouterr()) == (
        1, ("", message.format(file=path)))
    assert {name: text for name, text in snapshot(store).items()
            if not name.startswith(("lag/", "fail/"))} == before
