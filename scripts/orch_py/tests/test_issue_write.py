"""The issue noun's write verbs - update, comment, publish, triage and close -
run in-process against the gh fake on a tmp_path store: each checked by its
stdout, its exit code, its `orch:` message and the GitHub state the store
holds afterwards."""
from __future__ import annotations

import os

import pytest

from conftest import GH_502, orch_issue, write_labels_doc
from orch.gh import label_listed
from orch.git import FakeGit


class Noun:
    """`orch.sh issue ...` in-process: the fake gh on <seed>'s store, a fake
    checkout at <root> - its triage-labels doc written by labels_doc() - and
    <env> for the host the messages name."""

    def __init__(self, seed, root, capsys):
        self.seed = seed
        self.root = root
        self.capsys = capsys
        self.env = {}

    def labels_doc(self, *rows):
        """The repo's triage-labels doc, mapping each (role, label) row."""
        lines = [
            "# Triage Labels",
            "",
            "| Label in mattpocock/skills | Label in our tracker | Meaning |",
            "| -------------------------- | -------------------- | ------- |",
        ]
        lines += ["| `%s` | `%s` | Meant |" % row for row in rows]
        write_labels_doc(self.root, "\n".join(lines) + "\n")

    def __call__(self, *argv):
        """(exit code, stdout, stderr) of `orch.sh issue <argv>`."""
        code = orch_issue(self.seed, *argv, git=FakeGit(toplevel=str(self.root)),
                          env=self.env)
        out, err = self.capsys.readouterr()
        return code, out, err


@pytest.fixture
def orch(seed, tmp_path, capsys):
    root = tmp_path / "repo"
    root.mkdir()
    return Noun(seed, root, capsys)


def read(store, *parts):
    """A file of the store, or None where it is absent."""
    path = os.path.join(str(store), *(str(part) for part in parts))
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as f:
        return f.read()


def snapshot(store):
    """Every file the store holds, with its contents - but the comment-read
    counter, which a read bumps."""
    files = {}
    for directory, _, names in os.walk(str(store)):
        for name in names:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, str(store))
            if relative != "comment_reads":
                with open(path, "rb") as f:
                    files[relative] = f.read()
    return files


@pytest.fixture
def body(tmp_path):
    path = tmp_path / "body.md"
    path.write_text("## Solution\n\nTracked in #6; see `$HOME` and 'quoted' text.\n")
    return path


# --- update ---------------------------------------------------------------


def test_update_replaces_the_issue_body_with_the_file_exactly(orch, seed, store, body):
    seed.issue(23, "open")
    seed.body(23, "Body of #23.")

    assert orch("update", "23", str(body)) == (0, "", "")
    assert read(store, "issues", 23, "body") == body.read_text()


@pytest.mark.parametrize("op", ["update", "comment"])
@pytest.mark.parametrize(
    "args",
    [["23"], ["23", "{body}", "extra"], ["23", "{body}", "--json"],
     ["23", "{body}", "--with-spec-review"]],
    ids=["no-file", "extra", "fetch-flag", "comments-flag"],
)
def test_a_wrong_shape_is_the_ops_flagless_usage_line_writing_nothing(
    orch, seed, store, body, op, args
):
    seed.issue(23, "open")
    before = snapshot(store)

    code, out, err = orch(op, *(a.format(body=body) for a in args))

    assert (code, out, err) == (1, "", "orch: usage: orch.sh issue %s <n> <file>\n" % op)
    assert snapshot(store) == before


@pytest.mark.parametrize("op", ["update", "comment"])
def test_an_issue_that_is_not_a_plain_number_is_refused_naming_it(orch, seed, store, body, op):
    seed.issue(23, "open")
    before = snapshot(store)

    assert orch(op, "abc", str(body)) == (
        1, "",
        "orch: issue must be a plain issue number, got: abc"
        " (usage: orch.sh issue %s <n> <file>)\n" % op,
    )
    assert snapshot(store) == before


@pytest.mark.parametrize("op", ["update", "comment"])
def test_a_body_file_that_does_not_exist_is_refused_naming_it(orch, seed, store, op):
    seed.issue(23, "open")
    before = snapshot(store)

    assert orch(op, "23", "/nonexistent/body.md") == (
        1, "", "orch: body file not found: /nonexistent/body.md\n"
    )
    assert snapshot(store) == before


@pytest.mark.parametrize(
    "op, operation, what",
    [("update", "adapter_issue_body_edit", "replace the body of issue #23"),
     ("comment", "adapter_issue_comment", "comment on issue #23")],
)
@pytest.mark.parametrize(
    "stderr, reason", [(GH_502, "HTTP 502: Bad Gateway"), ("", "gh gave no reason")],
    ids=["reason", "silent"],
)
def test_a_failed_write_dies_with_ghs_first_line(
    orch, seed, body, op, operation, what, stderr, reason
):
    seed.issue(23, "open")
    seed.fail(operation, stderr)

    assert orch(op, "23", str(body)) == (
        1, "", "orch: gh could not %s: %s\n" % (what, reason)
    )


# --- comment ----------------------------------------------------------------


def test_comment_posts_the_file_on_the_issue_exactly(orch, seed, store, body):
    seed.issue(23, "open")

    assert orch("comment", "23", str(body)) == (0, "", "")
    assert read(store, "issues", 23, "comments", 1, "body") == body.read_text()
    assert read(store, "issues", 23, "comments", 2, "body") is None


# --- publish ----------------------------------------------------------------

TITLE = "Widgets need a handle"


def published(store, out):
    """The issue the printed number names: its state, title, body and labels."""
    n = int(out)
    return (
        read(store, "issues", n, "state"),
        read(store, "issues", n, "title"),
        read(store, "issues", n, "body"),
        read(store, "issues", n, "labels"),
    )


def test_publish_files_the_issue_under_ready_for_agent_printing_its_number(
    orch, seed, store, body
):
    seed.next_issue(7)

    assert orch("publish", TITLE, str(body)) == (0, "7\n", "")
    assert published(store, "7") == (
        "OPEN\n", TITLE + "\n", body.read_text(), "ready-for-agent\n"
    )


@pytest.mark.parametrize("label", ["agent go", "-agent"])
def test_publish_applies_the_repos_name_for_ready_for_agent(orch, store, body, label):
    orch.labels_doc(("needs-triage", "needs-triage"), ("ready-for-agent", label))

    code, out, err = orch("publish", TITLE, str(body))

    assert (code, err) == (0, "")
    assert published(store, out)[3] == label + "\n"


@pytest.mark.parametrize(
    "args, message",
    [(["", "{body}"], "the title is empty"),
     ([TITLE, "/nonexistent/body.md"], "body file not found: /nonexistent/body.md"),
     ([TITLE], "usage: orch.sh issue publish <title> <body-file>"),
     ([TITLE, "{body}", "extra"], "usage: orch.sh issue publish <title> <body-file>")],
    ids=["empty-title", "no-body-file", "one-argument", "three-arguments"],
)
def test_publish_refuses_bad_input_filing_nothing(orch, store, body, args, message):
    before = snapshot(store)

    assert orch("publish", *(a.format(body=body) for a in args)) == (
        1, "", "orch: " + message + "\n"
    )
    assert snapshot(store) == before


@pytest.mark.parametrize(
    "stderr, reason", [(GH_502, "HTTP 502: Bad Gateway"), ("", "gh gave no reason")],
    ids=["reason", "silent"],
)
def test_a_failed_create_dies_printing_no_number(orch, seed, body, stderr, reason):
    seed.fail("adapter_issue_create", stderr)

    assert orch("publish", TITLE, str(body)) == (
        1, "", "orch: gh could not create the issue: %s\n" % reason
    )


UNVERIFIED = (
    "orch: issue #9's title and 'ready-for-agent' label did not verify"
    " - checked twice, both failed\n"
)


@pytest.mark.parametrize(
    "stale",
    [None, "Widgets need a handle\nbug\nready-for-agent"],
    ids=["once-stale", "extra-labels"],
)
def test_a_publish_readback_right_on_its_retry_or_with_extra_labels_verifies(
    orch, seed, body, stale
):
    seed.next_issue(9)
    if stale is None:
        seed.lag("adapter_issue_title_labels", 1)
    else:
        seed.lag("adapter_issue_title_labels", 2, stale)

    assert orch("publish", TITLE, str(body)) == (0, "9\n", "")


@pytest.mark.parametrize(
    "stale",
    [None, "Something else\nready-for-agent", "Widgets need a handle\nneeds-triage"],
    ids=["stale-twice", "wrong-title", "no-ready-label"],
)
def test_a_publish_readback_wrong_twice_dies_unverified(orch, seed, body, stale):
    seed.next_issue(9)
    if stale is None:
        seed.lag("adapter_issue_title_labels", 2)
    else:
        seed.lag("adapter_issue_title_labels", 2, stale)

    assert orch("publish", TITLE, str(body)) == (1, "", UNVERIFIED)


@pytest.mark.parametrize(
    "stderr, reason", [(GH_502, "HTTP 502: Bad Gateway"), ("", "gh gave no reason")],
    ids=["reason", "silent"],
)
def test_a_publish_readback_that_fails_twice_dies_with_ghs_reason(
    orch, seed, body, stderr, reason
):
    seed.next_issue(9)
    seed.fail("adapter_issue_title_labels", stderr)

    assert orch("publish", TITLE, str(body)) == (
        1, "", "orch: gh could not read issue #9: %s\n" % reason
    )


def test_a_publish_readback_that_fails_once_then_answers_verifies(orch, seed, body):
    seed.next_issue(9)
    seed.fail_times("adapter_issue_title_labels", 1)

    assert orch("publish", TITLE, str(body)) == (0, "9\n", "")


def test_the_second_publish_readback_decides_a_failure_then_a_mismatch(orch, seed, body):
    seed.next_issue(9)
    seed.fail_times("adapter_issue_title_labels", 1, GH_502)
    seed.lag("adapter_issue_title_labels", 1, "")

    assert orch("publish", TITLE, str(body)) == (1, "", UNVERIFIED)


def test_the_second_publish_readback_decides_a_mismatch_then_a_failure(orch, seed, body):
    seed.next_issue(9)
    seed.lag("adapter_issue_title_labels", 1, "")
    seed.fail_after("adapter_issue_title_labels", 1, GH_502)

    assert orch("publish", TITLE, str(body)) == (
        1, "", "orch: gh could not read issue #9: HTTP 502: Bad Gateway\n"
    )


# --- triage -----------------------------------------------------------------

RENAMED = (
    ("needs-triage", "triage me"), ("needs-info", "more info"),
    ("ready-for-agent", "agent go"), ("ready-for-human", "human go"), ("wontfix", "nope"),
)
TRIAGE_COMMENT = "An orchestrator planning session triaged this issue to `%s`.\n"


def labels_of(store, n):
    return (read(store, "issues", n, "labels") or "").split("\n")[:-1]


def comments_of(store, n):
    """The bodies of issue #n's comments, in order."""
    bodies = []
    k = 1
    while read(store, "issues", n, "comments", k, "body") is not None:
        bodies.append(read(store, "issues", n, "comments", k, "body"))
        k += 1
    return bodies


@pytest.mark.parametrize(
    "labels, left",
    [(["needs-triage", "bug"], ["bug", "ready-for-agent"]),
     (["Needs-Triage", "bug"], ["bug", "ready-for-agent"]),
     (["needs-info"], ["ready-for-agent"]),
     ([], ["ready-for-agent"])],
    ids=["needs-triage", "mixed-case", "needs-info", "unlabelled"],
)
def test_triage_moves_an_open_issue_to_ready_for_agent_with_one_comment(
    orch, seed, store, labels, left
):
    seed.issue(40, "open", *labels)

    assert orch("triage", "40") == (0, "", "")
    assert labels_of(store, 40) == left
    assert comments_of(store, 40) == [TRIAGE_COMMENT % "ready-for-agent"]


@pytest.mark.parametrize(
    "labels", [["ready-for-agent", "bug"], ["review:nit", "ready-for-agent"]],
    ids=["issue", "finding"],
)
def test_triage_of_an_issue_already_ready_changes_nothing(orch, seed, store, labels):
    seed.issue(43, "open", *labels)
    before = snapshot(store)

    assert orch("triage", "43") == (0, "", "")
    assert snapshot(store) == before


@pytest.mark.parametrize(
    "labels, held",
    [(["wontfix"], "wontfix"), (["ready-for-human"], "ready-for-human"),
     (["ready-for-human", "wontfix"], "wontfix"),
     (["review:major", "bug", "ready-for-human"], "ready-for-human"),
     (["review:major", "wontfix"], "wontfix")],
    ids=["wontfix", "ready-for-human", "both", "human-finding", "wontfix-finding"],
)
def test_a_held_label_asks_for_a_decision_exit_2_printing_it(orch, seed, store, labels, held):
    seed.issue(44, "open", *labels)
    before = snapshot(store)

    assert orch("triage", "44") == (2, held + "\n", "")
    assert snapshot(store) == before


@pytest.mark.parametrize(
    "labels, left",
    [(["wontfix"], ["ready-for-agent"]), (["ready-for-human"], ["ready-for-agent"]),
     (["review:major", "bug", "ready-for-human"], ["review:major", "bug", "ready-for-agent"])],
    ids=["wontfix", "ready-for-human", "finding"],
)
def test_override_triages_a_held_issue(orch, seed, store, labels, left):
    seed.issue(44, "open", *labels)

    assert orch("triage", "44", "--override") == (0, "", "")
    assert labels_of(store, 44) == left
    assert comments_of(store, 44) == [TRIAGE_COMMENT % "ready-for-agent"]


@pytest.mark.parametrize(
    "labels, flag, finding",
    [(["needs-triage", "review:major"], None, "review:major"),
     (["needs-triage", "review:minor"], None, "review:minor"),
     (["review:major"], None, "review:major"),
     (["review:major", "needs-info"], None, "review:major"),
     (["review:major", "needs-triage"], "--override", "review:major"),
     (["review:major"], "--override", "review:major"),
     (["Review:Nit", "review:major"], None, "Review:Nit")],
    ids=["major", "minor", "bare", "needs-info", "override", "bare-override", "first-named"],
)
def test_a_filed_finding_not_yet_triaged_is_refused_naming_finding_triage(
    orch, seed, store, labels, flag, finding
):
    seed.issue(45, "open", *labels)
    orch.env = {"CLAUDECODE": "1"}
    before = snapshot(store)

    assert orch("triage", "45", *([flag] if flag else [])) == (
        1, "",
        "orch: issue #45 is a filed finding (%s) not yet triaged - triage it with"
        " /orchestrator:finding-triage\n" % finding,
    )
    assert snapshot(store) == before


def test_off_claude_code_the_finding_gate_names_the_finding_triage_skill(orch, seed):
    seed.issue(45, "open", "needs-triage", "review:major")
    orch.env = {"ORCHESTRATOR_HOST": "junie", "CLAUDECODE": "1"}

    assert orch("triage", "45")[2] == (
        "orch: issue #45 is a filed finding (review:major) not yet triaged - triage it with"
        " /orchestrator:finding-triage (or the orch-finding-triage skill)\n"
    )


def test_a_closed_issue_is_refused(orch, seed, store):
    seed.issue(46, "closed", "needs-triage")
    before = snapshot(store)

    assert orch("triage", "46") == (
        1, "",
        "orch: issue #46 is not open - only an open issue is triaged to 'ready-for-agent'\n",
    )
    assert snapshot(store) == before


def test_a_failed_read_dies_changing_nothing(orch, seed, store):
    seed.issue(47, "open", "needs-triage")
    seed.fail("adapter_issue_state_labels", GH_502)
    before = snapshot(store)

    assert orch("triage", "47") == (
        1, "", "orch: gh could not read issue #47: HTTP 502: Bad Gateway\n"
    )
    assert snapshot(store) == before


def test_a_failed_relabel_dies_posting_no_comment(orch, seed, store):
    seed.issue(48, "open", "needs-triage")
    seed.fail("adapter_issue_relabel", GH_502)

    assert orch("triage", "48") == (
        1, "", "orch: gh could not relabel issue #48: HTTP 502: Bad Gateway\n"
    )
    assert comments_of(store, 48) == []


def test_a_triage_readback_stale_once_verifies_without_relabelling_again(orch, seed, store):
    seed.issue(49, "open", "needs-triage")
    seed.lag_after("adapter_issue_state_labels", 1, 1, "OPEN\nneeds-triage")
    # A second relabel would fail, so a re-read that relabelled again cannot
    # pass.
    seed.fail_after("adapter_issue_relabel", 1)

    assert orch("triage", "49") == (0, "", "")
    assert labels_of(store, 49) == ["ready-for-agent"]
    assert comments_of(store, 49) == [TRIAGE_COMMENT % "ready-for-agent"]


def test_a_verify_reread_that_fails_once_then_answers_verifies(orch, seed, store):
    seed.issue(57, "open", "needs-triage")
    seed.fail_after("adapter_issue_state_labels", 1)
    seed.fail_times("adapter_issue_state_labels", 1)

    assert orch("triage", "57") == (0, "", "")
    assert comments_of(store, 57) == [TRIAGE_COMMENT % "ready-for-agent"]


TRIAGE_UNVERIFIED = (
    "orch: issue #50's 'ready-for-agent' label did not verify - checked twice, both failed\n"
)


@pytest.mark.parametrize(
    "seeding, message",
    [(lambda s: s.lag_after("adapter_issue_state_labels", 1, 2,
                            "OPEN\nneeds-triage\nready-for-agent"),
      TRIAGE_UNVERIFIED),
     (lambda s: s.fail_after("adapter_issue_state_labels", 1, GH_502),
      "orch: gh could not read issue #50: HTTP 502: Bad Gateway\n"),
     (lambda s: s.fail_after("adapter_issue_state_labels", 1, ""),
      "orch: gh could not read issue #50: gh gave no reason\n"),
     (lambda s: (s.fail_after("adapter_issue_state_labels", 1, GH_502),
                 s.fail_times("adapter_issue_state_labels", 1, GH_502),
                 s.lag_after("adapter_issue_state_labels", 1, 1, "OPEN\nneeds-triage")),
      TRIAGE_UNVERIFIED),
     (lambda s: (s.lag_after("adapter_issue_state_labels", 1, 1, "OPEN\nneeds-triage"),
                 s.fail_after("adapter_issue_state_labels", 2, GH_502)),
      "orch: gh could not read issue #50: HTTP 502: Bad Gateway\n")],
    ids=["stale-twice", "fails-twice", "silent-twice", "fail-then-stale", "stale-then-fail"],
)
def test_a_relabel_that_does_not_verify_dies_leaving_it_and_posting_no_comment(
    orch, seed, store, seeding, message
):
    seed.issue(50, "open", "needs-triage")
    seeding(seed)

    assert orch("triage", "50") == (1, "", message)
    assert labels_of(store, 50) == ["ready-for-agent"]
    assert comments_of(store, 50) == []


@pytest.mark.parametrize(
    "stderr, reason", [(GH_502, "HTTP 502: Bad Gateway"), ("", "gh gave no reason")],
    ids=["reason", "silent"],
)
def test_a_failed_triage_comment_only_warns_the_relabel_standing(
    orch, seed, store, stderr, reason
):
    seed.issue(51, "open", "needs-triage")
    seed.fail("adapter_issue_comment", stderr)

    assert orch("triage", "51") == (
        0, "",
        "orch: warning: issue #51 is labelled ready-for-agent, but gh could not post"
        " the triage comment on it: %s\n" % reason,
    )
    assert labels_of(store, 51) == ["ready-for-agent"]
    assert comments_of(store, 51) == []


def test_triage_under_renamed_labels_moves_to_the_repos_names(orch, seed, store):
    orch.labels_doc(*RENAMED)
    seed.issue(53, "open", "triage me", "needs-triage")

    assert orch("triage", "53") == (0, "", "")
    assert labels_of(store, 53) == ["needs-triage", "agent go"]
    assert comments_of(store, 53) == [TRIAGE_COMMENT % "agent go"]


@pytest.mark.parametrize(
    "labels, answer",
    [(["nope"], (2, "nope\n", "")), (["human go", "review:major"], (2, "human go\n", "")),
     (["agent go"], (0, "", ""))],
    ids=["wontfix", "human-finding", "ready"],
)
def test_renamed_held_and_ready_labels_are_read_by_the_repos_names(
    orch, seed, store, labels, answer
):
    orch.labels_doc(*RENAMED)
    seed.issue(54, "open", *labels)
    before = snapshot(store)

    assert orch("triage", "54") == answer
    assert snapshot(store) == before


def test_a_finding_under_the_renamed_needs_triage_is_refused(orch, seed, store):
    orch.labels_doc(*RENAMED)
    seed.issue(67, "open", "triage me", "review:major")

    code, out, err = orch("triage", "67", "--override")

    assert (code, out) == (1, "")
    assert err.startswith("orch: issue #67 is a filed finding (review:major) not yet triaged")


@pytest.mark.parametrize(
    "args",
    [["abc"], ["40", "--force"], [], ["40", "41"], ["40", "--check", "--override"],
     ["40", "--override", "--check"], ["-"]],
    ids=["not-a-number", "unknown-flag", "no-issue", "two-issues", "check-override",
         "override-check", "dash"],
)
def test_triage_usage_errors_write_nothing(orch, seed, store, args):
    seed.issue(40, "open", "needs-triage")
    before = snapshot(store)

    assert orch("triage", *args) == (
        1, "", "orch: usage: orch.sh issue triage <n> [--override | --check]\n"
    )
    assert snapshot(store) == before


# --- triage --check ---------------------------------------------------------


@pytest.mark.parametrize(
    "labels, said",
    [(["ready-for-agent", "bug"], "ready"), (["needs-triage", "bug"], "movable"),
     ([], "movable"), (["wontfix"], "wontfix"), (["ready-for-human"], "ready-for-human"),
     (["ready-for-human", "wontfix"], "wontfix"), (["ready-for-agent", "wontfix"], "ready"),
     (["review:major", "bug", "ready-for-human"], "ready-for-human"),
     (["Ready-For-Agent", "bug"], "ready"), (["Wontfix"], "wontfix")],
    ids=["ready", "needs-triage", "unlabelled", "wontfix", "ready-for-human", "both-held",
         "ready-beside-held", "labelled-finding", "mixed-case-ready", "mixed-case-held"],
)
def test_check_says_what_the_write_would_do_writing_nothing(orch, seed, store, labels, said):
    seed.issue(70, "open", *labels)
    before = snapshot(store)

    assert orch("triage", "70", "--check") == (0, said + "\n", "")
    assert snapshot(store) == before


@pytest.mark.parametrize(
    "labels, said",
    [(["agent go"], "ready"), (["human go", "nope"], "nope"), (["human go"], "human go"),
     (["triage me", "ready-for-agent"], "movable")],
    ids=["ready", "held-wontfix", "held-human", "upstream-name"],
)
def test_check_reads_the_repos_renamed_labels(orch, seed, store, labels, said):
    orch.labels_doc(*RENAMED)
    seed.issue(89, "open", *labels)

    assert orch("triage", "89", "--check") == (0, said + "\n", "")


@pytest.mark.parametrize(
    "state, labels, seeding, message",
    [("closed", ["needs-triage"], None,
      "orch: issue #78 is not open - only an open issue is triaged to 'ready-for-agent'"),
     ("open", ["needs-triage", "review:major"], None,
      "orch: issue #78 is a filed finding (review:major) not yet triaged - triage it with"
      " /orchestrator:finding-triage (or the orch-finding-triage skill)"),
     ("open", ["needs-triage"], lambda s: s.fail("adapter_issue_state_labels", GH_502),
      "orch: gh could not read issue #78: HTTP 502: Bad Gateway")],
    ids=["closed", "filed-finding", "failed-read"],
)
def test_check_dies_where_the_write_would_writing_nothing(
    orch, seed, store, state, labels, seeding, message
):
    seed.issue(78, state, *labels)
    if seeding:
        seeding(seed)
    before = snapshot(store)

    assert orch("triage", "78", "--check") == (1, "", message + "\n")
    assert snapshot(store) == before


@pytest.mark.parametrize(
    "labels",
    [["ready-for-agent"], ["wontfix"], ["ready-for-human"], ["ready-for-human", "wontfix"],
     ["ready-for-agent", "ready-for-human"], ["needs-triage"], ["needs-info", "bug"]],
)
def test_check_and_the_write_agree_on_every_label_set(orch, seed, store, labels):
    seed.issue(82, "open", *labels)
    _, said, _ = orch("triage", "82", "--check")
    before = snapshot(store)

    code, out, _ = orch("triage", "82")

    if said == "ready\n":
        assert (code, snapshot(store)) == (0, before)
    elif said == "movable\n":
        assert (code, label_listed(labels_of(store, 82), "ready-for-agent")) == (0, True)
    else:
        assert (code, out, snapshot(store)) == (2, said, before)


# --- close ------------------------------------------------------------------

CLOSE_USAGE = (
    "usage: orch.sh issue close <n> (--completed | --duplicate-of <m>) --comment-file <file>"
)


@pytest.fixture
def close_comment(tmp_path):
    path = tmp_path / "close.md"
    path.write_text("Done by #854: all three findings fixed.\n\n")
    return path


def test_close_completed_closes_with_the_file_as_its_comment(orch, seed, store, close_comment):
    seed.issue(80, "open", "ready-for-agent", "bug")

    assert orch("close", "80", "--completed", "--comment-file", str(close_comment)) == (0, "", "")
    assert (read(store, "issues", 80, "state"), read(store, "issues", 80, "reason")) == (
        "CLOSED\n", "completed\n"
    )
    assert comments_of(store, 80) == ["Done by #854: all three findings fixed."]
    assert labels_of(store, 80) == ["ready-for-agent", "bug"]


def test_close_duplicate_of_closes_as_a_duplicate_of_the_other(orch, seed, store, close_comment):
    seed.issue(81, "open")
    seed.issue(82, "open")

    assert orch("close", "81", "--duplicate-of", "82", "--comment-file", str(close_comment)) == (
        0, "", ""
    )
    assert [read(store, "issues", 81, f) for f in ("state", "reason", "duplicate_of")] == [
        "CLOSED\n", "duplicate\n", "82\n"
    ]
    assert comments_of(store, 81) == ["Done by #854: all three findings fixed."]
    assert read(store, "issues", 82, "state") == "OPEN\n"


@pytest.mark.parametrize(
    "args, message",
    [(["8x3", "--completed", "--comment-file", "{c}"],
      "issue must be a plain issue number, got: 8x3 (%s)" % CLOSE_USAGE),
     (["--completed", "--comment-file", "{c}"], CLOSE_USAGE),
     (["83", "--duplicate-of", "#82", "--comment-file", "{c}"],
      "--duplicate-of must be a plain issue number, got: #82 (%s)" % CLOSE_USAGE),
     (["83", "--duplicate-of", "", "--comment-file", "{c}"],
      "--duplicate-of must be a plain issue number, got:  (%s)" % CLOSE_USAGE),
     (["83", "--duplicate-of", "83", "--comment-file", "{c}"],
      "issue #83 cannot be a duplicate of itself"),
     (["83", "--comment-file", "{c}"],
      "give one of --completed or --duplicate-of (%s)" % CLOSE_USAGE),
     (["83", "--completed", "--duplicate-of", "82", "--comment-file", "{c}"],
      "give one of --completed or --duplicate-of, not both (%s)" % CLOSE_USAGE),
     (["83", "--completed"], "--comment-file is required (%s)" % CLOSE_USAGE),
     (["83", "--completed", "--comment-file", "/nonexistent/comment.md"],
      "comment file not found: /nonexistent/comment.md"),
     (["83", "--completed", "--comment-file", "{empty}"], "comment file is empty: {empty}"),
     (["83", "--completed", "--reason", "x", "--comment-file", "{c}"],
      "unknown option: --reason (%s)" % CLOSE_USAGE),
     (["83", "--comment-file", "{c}", "--duplicate-of"],
      "--duplicate-of needs a value (%s)" % CLOSE_USAGE),
     (["83", "--completed", "--comment-file"], "--comment-file needs a value (%s)" % CLOSE_USAGE),
     (["83", "84", "--completed", "--comment-file", "{c}"], CLOSE_USAGE)],
    ids=["not-a-number", "no-issue", "duplicate-not-a-number", "duplicate-empty",
         "duplicate-of-itself", "neither", "both", "no-comment-file", "comment-file-missing",
         "comment-file-empty", "unknown-option", "duplicate-no-value", "comment-file-no-value",
         "second-issue"],
)
def test_close_refuses_bad_input_closing_nothing(
    orch, seed, store, tmp_path, close_comment, args, message
):
    empty = tmp_path / "empty.md"
    empty.write_text("")
    seed.issue(83, "open")
    before = snapshot(store)
    paths = {"c": close_comment, "empty": empty}

    assert orch("close", *(a.format(**paths) for a in args)) == (
        1, "", "orch: " + message.format(**paths) + "\n"
    )
    assert snapshot(store) == before


@pytest.mark.parametrize(
    "args, message",
    [(["--completed"], "orch: gh could not close issue #83: HTTP 502: Bad Gateway"),
     (["--duplicate-of", "82"],
      "orch: gh could not close issue #83: HTTP 502: Bad Gateway"
      " - --duplicate-of needs gh 2.102 or newer")],
    ids=["completed", "duplicate"],
)
def test_a_failed_close_dies_with_ghs_first_line_leaving_the_issue_open(
    orch, seed, store, close_comment, args, message
):
    seed.issue(83, "open")
    seed.fail("adapter_issue_close", GH_502)

    assert orch("close", "83", *args, "--comment-file", str(close_comment)) == (
        1, "", message + "\n"
    )
    assert read(store, "issues", 83, "state") == "OPEN\n"
    assert comments_of(store, 83) == []
