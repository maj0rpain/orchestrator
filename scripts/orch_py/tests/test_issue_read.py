"""The issue noun's read verbs - fetch, comments, labels, ready and next - run
in-process against the gh adapter's fake on a tmp_path store, each checked by
its stdout, its exit code, its `orch:` message and the store afterwards."""
from __future__ import annotations

import pytest

from orch import issue
from orch.gh import Unparsed
from orch.gh_fake import FakeGh, FakeStore
from orch.git import FakeGit
from orch.repo import REPO_REMEDY, RepoPin

GH_502 = "HTTP 502: Bad Gateway\nsecond line"


@pytest.fixture
def store(tmp_path):
    path = tmp_path / "store"
    path.mkdir()
    return FakeStore(str(path))


def orch_issue(store, *argv, git=None, env=None, pin=None):
    """`orch.sh issue <argv>` on the store: its exit code. <pin> is the repo
    pin, a resolved one when None."""
    env = {} if env is None else env
    gh = FakeGh(store.store, env, pin=pin, sleep=lambda _: None)
    try:
        return issue.run(list(argv), gh=gh, git=git or FakeGit(), env=env)
    except SystemExit as died:
        return died.code


def content(path):
    """The file's contents byte for byte: no newline translation."""
    return path.read_bytes().decode("utf-8")


# --- issue labels ------------------------------------------------------------


def test_labels_prints_the_number_state_and_labels_of_one_issue(store, capsys):
    store.issue(90, "open", "bug", "orch:running")

    assert orch_issue(store, "labels", "90") == 0
    assert capsys.readouterr() == ("90 open bug, orch:running\n", "")


def test_labels_prints_several_issues_in_the_order_named(store, capsys):
    store.issue(90, "open", "bug", "orch:running")
    store.issue(91, "closed", "ready-for-agent")
    store.issue(92, "open")

    assert orch_issue(store, "labels", "92", "90", "91") == 0
    assert capsys.readouterr().out == (
        "92 open\n90 open bug, orch:running\n91 closed ready-for-agent\n"
    )


def test_labels_with_no_number_is_a_usage_error(store, capsys):
    assert orch_issue(store, "labels") == 1
    assert capsys.readouterr() == ("", "orch: usage: orch.sh issue labels <n>...\n")


def test_labels_refuses_a_number_that_is_not_plain_before_any_read(store, capsys):
    store.issue(90, "open", "bug")
    store.fail("adapter_issue_state_labels")

    assert orch_issue(store, "labels", "90", "abc") == 1
    assert capsys.readouterr() == ("", (
        "orch: issue must be a plain issue number, got: abc"
        " (usage: orch.sh issue labels <n>...)\n"
    ))


def test_a_failed_labels_read_dies_after_the_lines_already_printed(store, capsys):
    store.issue(90, "open", "bug", "orch:running")
    store.issue(91, "closed")
    store.issue(92, "open")
    store.fail_after("adapter_issue_state_labels", 1, GH_502)

    assert orch_issue(store, "labels", "90", "91", "92") == 1
    assert capsys.readouterr() == (
        "90 open bug, orch:running\n",
        "orch: gh could not read issue #91: HTTP 502: Bad Gateway\n",
    )


# --- issue ready -------------------------------------------------------------

MAPPED_DOC = (
    "# Triage Labels\n\n"
    "| Label in mattpocock/skills | Label in our tracker | Meaning     |\n"
    "| -------------------------- | -------------------- | ----------- |\n"
    "| `ready-for-agent`          | `agent go`           | AFK-ready   |\n"
)


def checkout(tmp_path, labels_doc=None):
    """A checkout's git adapter, rooted at tmp_path/repo, holding <labels_doc>
    as its triage-labels doc when one is given."""
    root = tmp_path / "repo"
    (root / "docs" / "agents").mkdir(parents=True)
    if labels_doc is not None:
        (root / "docs" / "agents" / "triage-labels.md").write_text(labels_doc)
    return FakeGit(toplevel=str(root))


@pytest.mark.parametrize("label", ["ready-for-agent", "Ready-For-Agent"])
def test_an_issue_carrying_the_ready_label_in_any_case_is_ready(store, capsys, label):
    store.issue(70, "open", label, "bug")

    assert orch_issue(store, "ready", "70") == 0
    assert capsys.readouterr() == ("", "")


@pytest.mark.parametrize("labels", [("needs-triage", "bug"), ()], ids=["other", "none"])
def test_an_issue_without_the_ready_label_is_not_ready_and_says_nothing(store, capsys, labels):
    store.issue(71, "open", *labels)

    assert orch_issue(store, "ready", "71") == 1
    assert capsys.readouterr() == ("", "")


def test_ready_honours_the_repo_s_mapped_ready_label(store, tmp_path):
    git = checkout(tmp_path, MAPPED_DOC)
    store.issue(73, "open", "agent go")
    store.issue(74, "open", "ready-for-agent")

    assert orch_issue(store, "ready", "73", git=git) == 0
    assert orch_issue(store, "ready", "74", git=git) == 1


def test_a_failed_ready_read_exits_2_naming_the_issue(store, capsys):
    store.issue(70, "open", "ready-for-agent")
    store.fail("adapter_issue_state_labels", GH_502)

    assert orch_issue(store, "ready", "70") == 2
    assert capsys.readouterr() == (
        "", "orch: gh could not read issue #70: HTTP 502: Bad Gateway\n"
    )


@pytest.mark.parametrize("args, message", [
    ((), "usage: orch.sh issue ready <n>"),
    (("70", "71"), "usage: orch.sh issue ready <n>"),
    (("abc",), "issue must be a plain issue number, got: abc (usage: orch.sh issue ready <n>)"),
])
def test_a_ready_usage_error_exits_2(store, capsys, args, message):
    assert orch_issue(store, "ready", *args) == 2
    assert capsys.readouterr() == ("", "orch: %s\n" % message)


def test_ready_with_no_repo_exits_2_with_the_remedy_alone(store, capsys):
    store.issue(70, "open")

    assert orch_issue(store, "ready", "70", pin=RepoPin({}, FakeGit())) == 2
    assert capsys.readouterr() == ("", "orch: %s\n" % REPO_REMEDY)


# --- issue next --------------------------------------------------------------


def titled(store, n, title, state, *labels):
    store.issue(n, state, *labels)
    store.title(n, title)


def test_next_is_the_oldest_open_ready_issue_with_no_phase_label_parent_or_open_blocker(store, capsys):
    titled(store, 100, "Old phase", "open", "ready-for-agent", "orch:spec")
    titled(store, 101, "Old done", "open", "ready-for-agent", "orch:done")
    titled(store, 102, "Old sub", "open", "ready-for-agent")
    titled(store, 103, "Old blocked", "open", "ready-for-agent")
    titled(store, 104, "Old triage", "open", "needs-triage")
    titled(store, 105, "Old closed", "closed", "ready-for-agent")
    titled(store, 106, "The parent", "open", "ready-for-agent")
    titled(store, 107, "Newer", "open", "ready-for-agent")
    titled(store, 108, "Blocker", "open", "needs-triage")
    store.sub_issue(106, 102)
    store.blocked_by(103, 108)

    assert orch_issue(store, "next") == 0
    assert capsys.readouterr() == ("106\tThe parent\n", "")


def test_an_issue_whose_only_blocker_is_closed_is_next(store, capsys):
    titled(store, 110, "Closed blocker", "open", "ready-for-agent")
    titled(store, 111, "Blocker", "closed", "needs-triage")
    store.blocked_by(110, 111)

    assert orch_issue(store, "next") == 0
    assert capsys.readouterr().out == "110\tClosed blocker\n"


def test_with_no_dependency_summary_the_blocked_by_listing_decides(store, capsys):
    titled(store, 120, "No summary, open blocker", "open", "ready-for-agent")
    titled(store, 121, "No summary, closed blocker", "open", "ready-for-agent")
    titled(store, 122, "Open blocker", "open", "needs-triage")
    titled(store, 123, "Closed blocker", "closed", "needs-triage")
    store.blocked_by(120, 122)
    store.blocked_by(121, 123)
    store.no_dependency_summary(120)
    store.no_dependency_summary(121)

    assert orch_issue(store, "next") == 0
    assert capsys.readouterr().out == "121\tNo summary, closed blocker\n"

    store.blocked_by(120)
    assert orch_issue(store, "next") == 0
    assert capsys.readouterr().out == "120\tNo summary, open blocker\n"


def test_needs_human_and_a_review_label_do_not_stop_an_issue_being_next(store, capsys):
    titled(store, 130, "Review and human", "open", "ready-for-agent", "needs-human", "review:high")

    assert orch_issue(store, "next") == 0
    assert capsys.readouterr().out == "130\tReview and human\n"


def test_with_nothing_qualifying_next_exits_1_saying_nothing(store, capsys):
    titled(store, 131, "Only triage", "open", "needs-triage")
    titled(store, 132, "Only human", "open", "ready-for-human")

    assert orch_issue(store, "next") == 1
    assert capsys.readouterr() == ("", "")


def test_next_honours_the_repo_s_mapped_ready_label(store, capsys, tmp_path):
    titled(store, 133, "Mapped", "open", "agent go")
    titled(store, 134, "Default name", "open", "ready-for-agent")

    assert orch_issue(store, "next", git=checkout(tmp_path, MAPPED_DOC)) == 0
    assert capsys.readouterr().out == "133\tMapped\n"


def test_a_closed_issue_a_late_listing_still_carries_is_never_next(store, capsys):
    titled(store, 160, "Closed a moment ago", "closed", "ready-for-agent")
    titled(store, 161, "Still open", "open", "ready-for-agent")
    store.lag("adapter_issues_titled_rows", 1, (
        "160\nCLOSED\tClosed a moment ago\n1\nready-for-agent\n"
        "161\nOPEN\tStill open\n1\nready-for-agent"
    ))

    assert orch_issue(store, "next") == 0
    assert capsys.readouterr().out == "161\tStill open\n"


@pytest.mark.parametrize("operation, message", [
    ("adapter_issues_titled_rows", "list the open issues labelled ready-for-agent"),
    ("adapter_issue_parent", "read the parent of issue #140"),
    ("adapter_issue_open_blockers", "read the blockers of issue #140"),
])
def test_a_failed_next_read_exits_2_with_nothing_on_stdout(store, capsys, operation, message):
    titled(store, 140, "Only", "open", "ready-for-agent")
    store.fail(operation, GH_502)

    assert orch_issue(store, "next") == 2
    assert capsys.readouterr() == (
        "", "orch: gh could not %s: HTTP 502: Bad Gateway\n" % message
    )


def test_a_failed_blocked_by_listing_exits_2(store, capsys):
    titled(store, 120, "No summary", "open", "ready-for-agent")
    store.no_dependency_summary(120)
    store.fail("adapter_blockers_states", GH_502)

    assert orch_issue(store, "next") == 2
    assert capsys.readouterr() == (
        "", "orch: gh could not read the blockers of issue #120: HTTP 502: Bad Gateway\n"
    )


def test_an_argument_to_next_is_a_usage_error_exiting_2(store, capsys):
    assert orch_issue(store, "next", "extra") == 2
    assert capsys.readouterr() == ("", "orch: usage: orch.sh issue next\n")


def test_next_with_no_repo_exits_2_with_the_remedy(store, capsys):
    assert orch_issue(store, "next", pin=RepoPin({}, FakeGit())) == 2
    assert capsys.readouterr() == ("", "orch: %s\n" % REPO_REMEDY)


@pytest.mark.parametrize("limit, warned", [("3", True), ("4", False)])
def test_a_listing_reaching_the_issue_list_limit_warns(store, capsys, limit, warned):
    for n in (150, 151, 152):
        titled(store, n, "Phased", "open", "ready-for-agent", "orch:plan")

    assert orch_issue(store, "next", env={"ORCH_ISSUE_LIST_LIMIT": limit}) == 0
    assert ("reached the issue-list limit of 3" in capsys.readouterr().err) is warned


# --- issue comments ----------------------------------------------------------

COMMENTS_USAGE = "usage: orch.sh issue comments <n> <file> [--with-spec-review]"


def changelogs(store):
    """Issue #960: two spec review changelogs among other comments."""
    store.issue(960, "open")
    store.comment(960, "pat", "2026-09-03T09:00:00Z", "## Spec review\nRound 1 of 1\n\nNothing changed.")
    store.comment(960, "triage-bot", "2026-09-03T10:00:00Z", "A follow-up that quotes\n## Spec review\nlower down.")
    store.comment(960, "pat", "2026-09-03T11:00:00Z", "## Spec review \r\nRound 1 of 2")
    store.comment(960, "sam", "2026-09-03T12:00:00Z", "## Spec reviewer notes\nNot a changelog.")


def test_comments_writes_each_comment_opened_by_its_author_and_date_marker(store, capsys, tmp_path):
    store.issue(24, "open")
    store.comment(24, "triage-bot", "2026-09-01T10:00:00Z", "## Agent brief\n\nDo the `$HOME` thing in #6.")
    store.comment(24, "pat", "2026-09-02T11:30:00Z", "Also: the second line\n\\ stays unescaped.\n\n")
    out = tmp_path / "comments.md"

    assert orch_issue(store, "comments", "24", str(out)) == 0
    assert capsys.readouterr() == ("", "")
    assert content(out) == (
        "<!-- comment @triage-bot 2026-09-01T10:00:00Z -->\n"
        "## Agent brief\n\nDo the `$HOME` thing in #6.\n\n"
        "<!-- comment @pat 2026-09-02T11:30:00Z -->\n"
        "Also: the second line\n\\ stays unescaped.\n"
    )


def test_an_issue_with_no_comments_writes_an_empty_file(store, tmp_path):
    store.issue(25, "open")
    out = tmp_path / "comments.md"
    out.write_text("old\n")

    assert orch_issue(store, "comments", "25", str(out)) == 0
    assert content(out) == ""


def test_comments_leaves_out_the_spec_review_s_changelogs(store, tmp_path):
    changelogs(store)
    out = tmp_path / "comments.md"

    assert orch_issue(store, "comments", "960", str(out)) == 0
    assert content(out) == (
        "<!-- comment @triage-bot 2026-09-03T10:00:00Z -->\n"
        "A follow-up that quotes\n## Spec review\nlower down.\n\n"
        "<!-- comment @sam 2026-09-03T12:00:00Z -->\n"
        "## Spec reviewer notes\nNot a changelog.\n"
    )


def test_only_changelogs_leave_an_empty_file(store, tmp_path):
    store.issue(961, "open")
    store.comment(961, "pat", "2026-09-03T09:00:00Z", "## Spec review\nRound 1 of 2")
    store.comment(961, "pat", "2026-09-03T10:00:00Z", "## Spec review\nRound 2 of 2")
    out = tmp_path / "comments.md"

    assert orch_issue(store, "comments", "961", str(out)) == 0
    assert content(out) == ""


def test_with_spec_review_the_changelogs_are_kept(store, tmp_path):
    changelogs(store)
    out = tmp_path / "comments.md"

    assert orch_issue(store, "comments", "960", str(out), "--with-spec-review") == 0
    assert content(out) == (
        "<!-- comment @pat 2026-09-03T09:00:00Z -->\n"
        "## Spec review\nRound 1 of 1\n\nNothing changed.\n\n"
        "<!-- comment @triage-bot 2026-09-03T10:00:00Z -->\n"
        "A follow-up that quotes\n## Spec review\nlower down.\n\n"
        "<!-- comment @pat 2026-09-03T11:00:00Z -->\n"
        "## Spec review \r\nRound 1 of 2\n\n"
        "<!-- comment @sam 2026-09-03T12:00:00Z -->\n"
        "## Spec reviewer notes\nNot a changelog.\n"
    )


def untrusted(store):
    """Issue #962: an owner's comment and two strangers', a changelog among
    them."""
    store.issue(962, "open", "bug")
    store.title(962, "Trust")
    store.comment(962, "owner", "2026-09-04T09:00:00Z", "Owner note.", "OWNER")
    store.comment(962, "rando", "2026-09-04T12:00:00Z", "Stranger note.", "NONE")
    store.comment(962, "rando", "2026-09-04T15:00:00Z", "## Spec review\nRound 9 of 9", "NONE")


@pytest.mark.parametrize("flag", [(), ("--with-spec-review",)], ids=["default", "with-spec-review"])
def test_comments_drops_untrusted_authors_saying_how_many_once(store, capsys, tmp_path, flag):
    untrusted(store)
    store.comment(962, "member", "2026-09-04T16:00:00Z", "Member note.", "MEMBER")
    store.comment(962, "collab", "2026-09-04T17:00:00Z", "Collaborator note.", "COLLABORATOR")
    out = tmp_path / "comments.md"

    assert orch_issue(store, "comments", "962", str(out), *flag) == 0
    assert capsys.readouterr() == (
        "", "orch: ignored 2 comment(s) from untrusted authors on #962\n"
    )
    assert content(out) == (
        "<!-- comment @owner 2026-09-04T09:00:00Z -->\nOwner note.\n\n"
        "<!-- comment @member 2026-09-04T16:00:00Z -->\nMember note.\n\n"
        "<!-- comment @collab 2026-09-04T17:00:00Z -->\nCollaborator note.\n"
    )


@pytest.mark.parametrize("flag", [(), ("--with-spec-review",)], ids=["default", "with-spec-review"])
def test_a_failed_comments_read_dies_leaving_the_file_as_it_was(store, capsys, tmp_path, flag):
    store.issue(24, "open")
    store.fail("adapter_issue_comments", GH_502)
    out = tmp_path / "comments.md"
    out.write_text("known content\n")

    assert orch_issue(store, "comments", "24", str(out), *flag) == 1
    assert capsys.readouterr() == (
        "", "orch: gh could not read the comments of issue #24: HTTP 502: Bad Gateway\n"
    )
    assert content(out) == "known content\n"
    assert sorted(p.name for p in tmp_path.iterdir()) == ["comments.md", "store"]


def test_a_comments_answer_that_does_not_parse_dies_naming_its_cause(store, capsys, tmp_path):
    store.issue(24, "open")
    store.lag("adapter_issue_comments", 1, "not json")
    out = tmp_path / "comments.md"
    out.write_text("known content\n")

    assert orch_issue(store, "comments", "24", str(out)) == 1
    assert capsys.readouterr() == (
        "", "orch: could not read the comments of issue #24: its comments did not parse\n"
    )
    assert content(out) == "known content\n"


@pytest.mark.parametrize("args", [
    ("24", "--with-spec-review", "FILE"),
    ("24", "FILE", "--with-spec-reviw"),
    ("24", "FILE", "--with-spec-review", "extra"),
    ("24", "FILE", "--json"),
    ("24",),
])
def test_comments_refuses_a_misplaced_or_unknown_flag_writing_nothing(store, capsys, tmp_path, args):
    out = tmp_path / "comments.md"

    assert orch_issue(store, "comments", *(str(out) if a == "FILE" else a for a in args)) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % COMMENTS_USAGE)
    assert not out.exists()


def test_comments_refuses_an_issue_number_that_is_not_plain(store, capsys, tmp_path):
    assert orch_issue(store, "comments", "abc", str(tmp_path / "c.md")) == 1
    assert capsys.readouterr() == (
        "", "orch: issue must be a plain issue number, got: abc (%s)\n" % COMMENTS_USAGE
    )


# --- issue fetch -------------------------------------------------------------

FETCH_USAGE = "usage: orch.sh issue fetch <n> <file> [--json]"


@pytest.mark.parametrize("body, written", [
    ("Body of #23.", "Body of #23.\n"),
    ("Body of #23.\n\n", "Body of #23.\n\n\n"),
    ("# Spec\r\n\r\nAlpha line.\r\nBeta line.\r\n", "# Spec\n\nAlpha line.\nBeta line.\n\n"),
    ("Alpha line.\r\nBeta line.", "Alpha line.\nBeta line.\n"),
], ids=["lf", "trailing-newlines", "crlf", "crlf-no-final-newline"])
def test_fetch_writes_the_body_with_lf_lines_and_one_newline_added(store, capsys, tmp_path, body, written):
    store.issue(23, "open")
    store.body(23, body)
    out = tmp_path / "body.md"

    assert orch_issue(store, "fetch", "23", str(out)) == 0
    assert capsys.readouterr() == ("", "")
    assert content(out) == written


@pytest.mark.parametrize("stderr, reason", [
    (GH_502, "HTTP 502: Bad Gateway"), ("", "gh gave no reason"),
], ids=["reason", "silent"])
def test_a_failed_body_read_dies_leaving_the_target_and_no_temp_file(store, capsys, tmp_path, stderr, reason):
    store.issue(23, "open")
    store.fail("adapter_issue_body", stderr)
    out = tmp_path / "body.md"
    out.write_text("Body of #23.\n")

    assert orch_issue(store, "fetch", "23", str(out)) == 1
    assert capsys.readouterr() == (
        "", "orch: gh could not read the body of issue #23: %s\n" % reason
    )
    assert content(out) == "Body of #23.\n"
    assert sorted(p.name for p in tmp_path.iterdir()) == ["body.md", "store"]


def test_fetch_of_an_issue_gh_cannot_read_writes_no_file(store, capsys, tmp_path):
    out = tmp_path / "body.md"

    assert orch_issue(store, "fetch", "404", str(out)) == 1
    assert "orch: gh could not read the body of issue #404: " in capsys.readouterr().err
    assert not out.exists()


def json_issue(store):
    store.issue(27, "open", "ready-for-agent", "bug")
    store.title(27, "Widgets need a handle")
    store.body(27, "## What to build\n\nA `$HOME` handle for #6.\r\nDEL \x7f here.")
    store.comment(27, "pat", "2026-09-02T11:30:00Z", "Also: \\ stays unescaped.\n")


def test_fetch_json_writes_the_trimmed_issue_object_on_one_line(store, capsys, tmp_path):
    json_issue(store)
    out = tmp_path / "issue.json"
    out.write_text("old contents\n")

    assert orch_issue(store, "fetch", "27", str(out), "--json") == 0
    assert capsys.readouterr() == ("", "")
    assert content(out) == (
        '{"number":27,"title":"Widgets need a handle",'
        '"body":"## What to build\\n\\nA `$HOME` handle for #6.\\r\\nDEL \\u007f here.",'
        '"labels":["ready-for-agent","bug"],'
        '"comments":[{"author":"pat","createdAt":"2026-09-02T11:30:00Z",'
        '"body":"Also: \\\\ stays unescaped.\\n"}]}\n'
    )


def test_fetch_json_of_an_issue_with_no_comments_has_an_empty_comments_array(store, tmp_path):
    store.issue(28, "open", "bug")
    out = tmp_path / "issue.json"

    assert orch_issue(store, "fetch", "28", str(out), "--json") == 0
    assert content(out) == '{"number":28,"title":"","body":"","labels":["bug"],"comments":[]}\n'


def test_fetch_json_drops_untrusted_authors_comments_saying_so(store, capsys, tmp_path):
    untrusted(store)
    out = tmp_path / "issue.json"

    assert orch_issue(store, "fetch", "962", str(out), "--json") == 0
    assert capsys.readouterr() == (
        "", "orch: ignored 2 comment(s) from untrusted authors on #962\n"
    )
    assert content(out) == (
        '{"number":962,"title":"Trust","body":"","labels":["bug"],"comments":'
        '[{"author":"owner","createdAt":"2026-09-04T09:00:00Z","body":"Owner note."}]}\n'
    )


@pytest.mark.parametrize("operation, message", [
    ("adapter_issue_json", "gh could not read issue #27: HTTP 502: Bad Gateway"),
    ("adapter_issue_comments", "gh could not read the comments of issue #27: HTTP 502: Bad Gateway"),
])
def test_a_failed_fetch_json_read_dies_leaving_the_file_as_it_was(store, capsys, tmp_path, operation, message):
    json_issue(store)
    store.fail(operation, GH_502)
    out = tmp_path / "issue.json"
    out.write_text("old contents\n")

    assert orch_issue(store, "fetch", "27", str(out), "--json") == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % message)
    assert content(out) == "old contents\n"


def test_a_failed_fetch_json_read_into_no_file_leaves_none(store, tmp_path):
    json_issue(store)
    store.fail("adapter_issue_json", GH_502)
    out = tmp_path / "issue.json"

    assert orch_issue(store, "fetch", "27", str(out), "--json") == 1
    assert not out.exists()


class UnparsedIssue(FakeGh):
    """The fake, but answering an issue that is no issue object."""

    def issue_json(self, n):
        raise Unparsed("not an issue object")


def test_an_issue_answer_that_does_not_parse_fails_fetch_json(store, capsys, tmp_path):
    json_issue(store)
    out = tmp_path / "issue.json"
    out.write_text("old contents\n")

    try:
        code = issue.run(["fetch", "27", str(out), "--json"],
                         gh=UnparsedIssue(store.store, {}), git=FakeGit(), env={})
    except SystemExit as died:
        code = died.code

    assert code == 1
    assert capsys.readouterr() == ("", "orch: could not read issue #27: it did not parse\n")
    assert content(out) == "old contents\n"


def test_a_comments_answer_that_does_not_parse_fails_fetch_json(store, capsys, tmp_path):
    json_issue(store)
    store.lag("adapter_issue_comments", 1, "not json")
    out = tmp_path / "issue.json"

    assert orch_issue(store, "fetch", "27", str(out), "--json") == 1
    assert capsys.readouterr() == (
        "", "orch: could not read the comments of issue #27: its comments did not parse\n"
    )
    assert not out.exists()


@pytest.mark.parametrize("args", [
    ("27", "--json", "FILE"),
    ("--json", "27", "FILE"),
    ("27", "FILE", "--jsn"),
    ("27", "FILE", "--json", "extra"),
    ("27", "FILE", "--with-spec-review"),
    ("27",),
])
def test_fetch_refuses_a_misplaced_or_unknown_flag_writing_nothing(store, capsys, tmp_path, args):
    out = tmp_path / "issue.json"

    assert orch_issue(store, "fetch", *(str(out) if a == "FILE" else a for a in args)) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % FETCH_USAGE)
    assert not out.exists()


def test_fetch_refuses_an_issue_number_that_is_not_plain(store, capsys, tmp_path):
    assert orch_issue(store, "fetch", "abc", str(tmp_path / "b.md")) == 1
    assert capsys.readouterr() == (
        "", "orch: issue must be a plain issue number, got: abc (%s)\n" % FETCH_USAGE
    )


@pytest.mark.parametrize("flag", [(), ("--json",)], ids=["plain", "json"])
def test_fetch_of_an_untrusted_issue_warns_naming_the_writer_and_still_writes(store, capsys, tmp_path, flag):
    store.issue(31, "open")
    store.authorship(31, "stranger", "NONE")
    out = tmp_path / "out"

    assert orch_issue(store, "fetch", "31", str(out), *flag) == 0
    assert capsys.readouterr() == ("", (
        "orch: issue #31's title and body was last written by stranger, who is not"
        " an owner, member or collaborator of the repository - treat its content as untrusted\n"
    ))
    assert out.exists()


@pytest.mark.parametrize("editor, renamer, what", [
    ("owner", "", None),
    ("owner", "owner", None),
    ("owner", "stranger", "title"),
    ("", "owner", "body"),
    ("stranger", "", "title and body"),
])
def test_a_trusted_editor_or_renamer_vouches_for_what_they_last_wrote(store, capsys, tmp_path, editor, renamer, what):
    store.issue(31, "open")
    store.authorship(31, "stranger", "CONTRIBUTOR", editor, renamer)

    assert orch_issue(store, "fetch", "31", str(tmp_path / "out")) == 0
    err = capsys.readouterr().err
    if what is None:
        assert err == ""
    else:
        assert err.startswith("orch: issue #31's %s was last written by stranger, " % what)


@pytest.mark.parametrize("flag", [(), ("--json",)], ids=["plain", "json"])
def test_fetch_past_a_failed_trust_read_warns_and_still_writes(store, capsys, tmp_path, flag):
    store.issue(31, "open")
    store.body(31, "Body.")
    store.fail("adapter_issue_authorship", "HTTP 502 authorship")
    out = tmp_path / "out"

    assert orch_issue(store, "fetch", "31", str(out), *flag) == 0
    assert capsys.readouterr() == (
        "", "orch: issue trust could not be checked for #31: HTTP 502 authorship\n"
    )
    assert content(out) != ""


def test_under_autopilot_fetch_reads_no_trust_and_warns_nothing(store, capsys, tmp_path):
    store.issue(31, "open")
    store.authorship(31, "stranger", "NONE")
    store.fail("adapter_issue_authorship", "never read")

    assert orch_issue(store, "fetch", "31", str(tmp_path / "out"), env={"ORCH_AUTOPILOT": "1"}) == 0
    assert capsys.readouterr() == ("", "")


# --- issue fetch: the drift line ---------------------------------------------

SHA = "0123456789abcdef0123456789abcdef01234567"


def audit_body(sha, *locations):
    """An audit-filed body, as the audit module renders one."""
    return "A finding.\n\n" + "".join("**Location:** `%s`\n\n" % l for l in locations) \
        + "**Audited at:** %s\n\n" % sha


def audited_repo(**changed):
    """A fake checkout whose HEAD differs from the audited commit SHA in the
    files named, a.md, b.md and c.md held by both."""
    base = {"a.md": "a", "b.md": "b", "c.md": "c"}
    return FakeGit(commits={SHA: base, "head": dict(base, **changed)}, head="head")


def fetched_drift(store, tmp_path, body, git, *flag):
    store.issue(23, "open")
    store.body(23, body)
    out = tmp_path / "out.md"
    code = orch_issue(store, "fetch", "23", str(out), *flag, git=git)
    return code, out


@pytest.mark.parametrize("locations, changed, files", [
    (("a.md:1", "b.md:2-3"), {}, "none"),
    (("a.md:1", "b.md:2-3"), {"a.md": "changed"}, "a.md"),
    (("b.md:1", "a.md:1", "c.md:1"), {"a.md": "x", "c.md": "x"}, "a.md, c.md"),
    (("c.md:1", "a.md:1", "c.md:5-6"), {"a.md": "x", "c.md": "x"}, "c.md, a.md"),
    (("gone.md:1", "b.md:1"), {"gone.md": "new"}, "gone.md"),
], ids=["none", "one-of-two", "body-order", "listed-once", "absent-at-the-audit"])
def test_an_audit_filed_body_prints_which_cited_files_changed(store, capsys, tmp_path, locations, changed, files):
    body = audit_body(SHA, *locations)

    code, out = fetched_drift(store, tmp_path, body, audited_repo(**changed))

    assert code == 0
    assert capsys.readouterr() == ("cited files changed since %s: %s\n" % (SHA, files), "")
    assert content(out) == body + "\n"


@pytest.mark.parametrize("git, reason", [
    (FakeGit(commits={SHA: {}}), "no commit on HEAD"),
    (FakeGit(commits={"head": {}}, head="head"), "commit not in this clone"),
    (FakeGit(commits={SHA: {}, "head": {}}, head="head", diff_fails=True), "git comparison failed"),
], ids=["unborn", "not-in-clone", "failed"])
def test_a_comparison_that_cannot_be_made_says_why_and_still_writes(store, capsys, tmp_path, git, reason):
    code, out = fetched_drift(store, tmp_path, audit_body(SHA, "a.md:1"), git)

    assert code == 0
    assert capsys.readouterr().out == "cited files changed since %s: unknown (%s)\n" % (SHA, reason)
    assert "**Audited at:**" in content(out)


@pytest.mark.parametrize("body", [
    "Just text.",
    "see the **Audited at:** %s line\n\n**Location:** `a.md:1`" % SHA,
    "**Audited at:** %s\n\n**Audited at:** %s\n\n**Location:** `a.md:1`" % (SHA, SHA),
    "**Audited at:** zzzz\n\n**Location:** `a.md:1`",
    "**Audited at:** \n\n**Location:** `a.md:1`",
    "**Audited at:** %s\n\n**Location:** `a.md`\n\n**Location:** a.md:1\n\n**Location:** `:1`" % SHA,
], ids=["ordinary", "marker-mid-line", "two-audited-lines", "not-hex", "no-sha", "no-well-formed-location"])
def test_any_other_body_prints_nothing_more(store, capsys, tmp_path, body):
    code, _ = fetched_drift(store, tmp_path, body, audited_repo(**{"a.md": "x"}))

    assert code == 0
    assert capsys.readouterr() == ("", "")


def test_fetch_json_of_an_audit_filed_body_prints_no_drift_line(store, capsys, tmp_path):
    code, _ = fetched_drift(store, tmp_path, audit_body(SHA, "a.md:1"),
                            audited_repo(**{"a.md": "x"}), "--json")

    assert code == 0
    assert capsys.readouterr() == ("", "")


# --- the noun ----------------------------------------------------------------


@pytest.mark.parametrize("argv, op", [(("bogus", "23"), "bogus"), ((), "<none>")])
def test_an_op_the_noun_lacks_dies_listing_the_ops(store, capsys, argv, op):
    assert orch_issue(store, *argv) == 1
    assert capsys.readouterr() == ("", (
        "orch: unknown issue op: %s"
        " (want fetch|update|comment|comments|publish|triage|ready|next|labels|close)\n" % op
    ))
