"""The spec noun run in-process against the gh adapter's fake on a tmp_path
store and a FakeGit checkout under tmp_path: the four reads and writes of the
flow's issue (fetch, update, comment, comments) and the pause that stops the
spec phase's session, each checked by its stdout, its exit code, its `orch:`
message, the markers it leaves and the store afterwards."""
from __future__ import annotations

import builtins
import os

import pytest

from conftest import comments_of, died_of, flow_state, read, snapshot
from orch import cli, spec
from orch.gh_fake import FakeGh
from orch.git import FakeGit


def orch_spec(root, seed, *argv, env=None, git=None):
    """`orch.sh spec <argv>` in-process, in the checkout at <root> (a
    FakeGit's toplevel unless <git> is given), under <env> (empty when None),
    with the gh fake on <seed>'s store: its exit code, a SystemExit's
    included."""
    env = {} if env is None else env
    gh = FakeGh(seed.store, env, sleep=lambda _: None)
    try:
        return spec.run(list(argv), gh=gh, git=git or FakeGit(toplevel=str(root)), env=env)
    except SystemExit as died:
        return died.code


# --- the noun's top-level refusal ---------------------------------------------

UNKNOWN = "(want fetch|update|comment|comments|pause|round|round-dir)"


@pytest.mark.parametrize("argv, named", [((), "<none>"), (("publish", "f"), "publish")],
                         ids=["missing", "unknown"])
def test_an_op_the_noun_does_not_have_is_refused_naming_the_ops(root, seed, capsys, argv, named):
    flow_state(root, "spec", 14)

    assert orch_spec(root, seed, *argv) == 1
    assert capsys.readouterr() == ("", "orch: unknown spec op: %s %s\n" % (named, UNKNOWN))


def test_the_cli_module_routes_the_spec_noun_to_this_module(root, capsys, monkeypatch):
    monkeypatch.setattr(spec, "Git", lambda: FakeGit(toplevel=str(root)))
    monkeypatch.setenv("CLAUDECODE", "1")

    assert died_of(capsys, lambda: cli.main(["spec", "pause"])) == (
        1, "", "orch: no active flow (.orchestrator/state.json not found)."
        " Run /orchestrator:start first.\n")


# --- the entry read ------------------------------------------------------------

# Every verb this module serves, as a caller runs it, the unknown op among
# them: each makes the entry read before anything else.
VERBS = [("fetch", "{file}"), ("update", "{file}"), ("comment", "{file}"),
         ("comments", "{file}"), ("pause",), ("round-dir", "1/2"), ("publish", "{file}")]
VERB_IDS = ["fetch", "update", "comment", "comments", "pause", "round-dir", "unknown"]
NO_FLOW = ("orch: no active flow (.orchestrator/state.json not found). Run /orchestrator:start"
           " (or orch-flow's Starting a flow section) first.\n")
UNREADABLE = "orch: state.json cannot be read - run orch.sh doctor --flow\n"


def filled(argv, path):
    return [str(path) if arg == "{file}" else arg for arg in argv]


@pytest.mark.parametrize("argv", VERBS, ids=VERB_IDS)
def test_with_no_state_file_every_verb_says_there_is_no_active_flow(root, seed, store, capsys,
                                                                    tmp_path, argv):
    seed.issue(14, "open")
    seed.body(14, "The spec.")
    before = snapshot(store)

    assert orch_spec(root, seed, *filled(argv, tmp_path / "body.md")) == 1
    assert capsys.readouterr() == ("", NO_FLOW)
    assert snapshot(store) == before
    assert not (root / ".orchestrator" / "handoff").exists()


@pytest.mark.parametrize("argv", VERBS, ids=VERB_IDS)
def test_a_truncated_state_file_is_refused_as_unreadable_before_any_write(root, seed, store,
                                                                          capsys, tmp_path, argv):
    state = flow_state(root, "spec", 14)
    state.write_text(state.read_text()[:20])
    seed.issue(14, "open")
    seed.body(14, "The spec.")
    body = tmp_path / "body.md"
    body.write_text("A new body.\n")
    before = snapshot(store)

    assert orch_spec(root, seed, *filled(argv, body)) == 1
    assert capsys.readouterr() == ("", UNREADABLE)
    assert snapshot(store) == before
    assert not (root / ".orchestrator" / "handoff").exists()


class Opens:
    """Counts the opens of one file, by any route: builtins.open and
    os.open."""

    def __init__(self, monkeypatch, path):
        self.path = os.path.realpath(str(path))
        self.count = 0
        real_open, real_os_open = builtins.open, os.open

        def counted(file, *args, **kwargs):
            self._seen(file)
            return real_open(file, *args, **kwargs)

        def os_counted(file, *args, **kwargs):
            self._seen(file)
            return real_os_open(file, *args, **kwargs)

        monkeypatch.setattr(builtins, "open", counted)
        monkeypatch.setattr(os, "open", os_counted)

    def _seen(self, file):
        if isinstance(file, (str, bytes, os.PathLike)) \
                and os.path.realpath(os.fsdecode(file)) == self.path:
            self.count += 1


@pytest.mark.parametrize("phase", ["spec", "implement", "done"])
@pytest.mark.parametrize("argv", VERBS[:5], ids=VERB_IDS[:5])
def test_each_verb_opens_the_state_file_exactly_once(root, seed, capsys, tmp_path, monkeypatch,
                                                     argv, phase):
    state = flow_state(root, phase, 14)
    seed.issue(14, "open")
    seed.body(14, "The spec.")
    body = tmp_path / "body.md"
    body.write_text("A new body.\n")
    opens = Opens(monkeypatch, state)

    orch_spec(root, seed, *filled(argv, body))

    assert opens.count == 1


# --- fetch, update, comment, comments -----------------------------------------

ISSUE_OPS = ["fetch", "update", "comment", "comments"]
# A body with everything a heredoc or a shell quote would mangle: a table, a
# fence, a `#nn` reference and quotes. What the lenses read must be what
# GitHub holds.
TRICKY = ("## Solution\n\n| Lens | Reads |\n|---|---|\n| Fidelity | plan handoff |\n\n"
          "```sh\norch.sh spec fetch \"$file\"\n```\n\n"
          "Tracked in #6; see `$HOME` and 'quoted' text.")


@pytest.fixture
def flow(root, seed):
    """A flow at phase spec on issue #14, its body TRICKY, beside issue #15,
    which is not the flow's."""
    flow_state(root, "spec", 14)
    seed.issue(14, "open")
    seed.body(14, TRICKY)
    seed.issue(15, "open")
    seed.body(15, "Not the flow's issue.")
    seed.comment(15, "pat", "2026-09-02T11:31:00Z", "Not the flow's issue.")


def issue_15(store):
    return {name: data for name, data in snapshot(store).items()
            if name.startswith("issues/15/")}


@pytest.mark.parametrize("op", ISSUE_OPS)
@pytest.mark.parametrize("args", [(), ("a.md", "b.md")], ids=["no-file", "two-files"])
def test_an_issue_op_takes_exactly_one_file(root, seed, store, capsys, flow, op, args):
    before = snapshot(store)

    assert orch_spec(root, seed, op, *args) == 1
    assert capsys.readouterr() == (
        "", "orch: usage: orch.sh spec <fetch|update|comment|comments> <file>\n")
    assert snapshot(store) == before


@pytest.mark.parametrize("op", ISSUE_OPS)
def test_an_issue_op_refuses_when_no_issue_is_recorded_naming_the_spec_phase(
        root, seed, store, capsys, tmp_path, op):
    flow_state(root, "review", None)
    body = tmp_path / "body.md"
    body.write_text("A body.\n")

    assert orch_spec(root, seed, op, str(body)) == 1
    assert capsys.readouterr() == (
        "", "orch: no issue recorded in state - the spec phase must publish one first\n")
    assert snapshot(store) == {}


@pytest.mark.parametrize("op", ISSUE_OPS)
def test_an_issue_op_refuses_a_done_flow_pointing_at_the_stateless_issue_op(
        root, seed, store, capsys, tmp_path, flow, op):
    flow_state(root, "done", 14)
    body = tmp_path / "body.md"
    body.write_text("")
    before = snapshot(store)

    assert orch_spec(root, seed, op, str(body)) == 1
    assert capsys.readouterr() == ("", (
        "orch: the flow on issue #14 is done - spec %s acts only on an active flow's issue;"
        " for another issue use orch.sh issue %s <n> <file>\n" % (op, op)))
    assert snapshot(store) == before
    assert body.read_text() == ""


@pytest.mark.parametrize("phase", ["spec", "review"])
def test_fetch_writes_the_flow_issue_s_body_exactly(root, seed, capsys, tmp_path, flow, phase):
    flow_state(root, phase, 14)
    out = tmp_path / "spec.md"

    assert orch_spec(root, seed, "fetch", str(out)) == 0
    assert capsys.readouterr() == ("", "")
    assert out.read_bytes().decode() == TRICKY + "\n"


def test_fetch_creates_the_directory_it_writes_into(root, seed, flow):
    out = root / ".orchestrator" / "spec-review" / "spec.md"

    assert orch_spec(root, seed, "fetch", str(out)) == 0
    assert out.read_bytes().decode() == TRICKY + "\n"


def test_a_failed_fetch_dies_with_gh_s_reason_writing_no_file(root, seed, capsys, tmp_path, flow):
    seed.fail("adapter_issue_body", "fake gh: issue view refused")
    out = tmp_path / "spec.md"

    assert orch_spec(root, seed, "fetch", str(out)) == 1
    assert "issue view refused" in capsys.readouterr().err
    assert not out.exists()


def test_fetch_of_an_audit_filed_body_prints_its_drift_line(root, seed, capsys, tmp_path, flow):
    sha = "0123456789abcdef0123456789abcdef01234567"
    seed.body(14, "A finding.\n\n**Location:** `README.md:1`\n\n**Audited at:** %s\n\n" % sha)
    tree = {"README.md": "readme"}
    git = FakeGit(toplevel=str(root), commits={sha: tree, "head": dict(tree)}, head="head")

    assert orch_spec(root, seed, "fetch", str(tmp_path / "spec.md"), git=git) == 0
    assert capsys.readouterr() == ("cited files changed since %s: none\n" % sha, "")


def test_update_replaces_the_flow_issue_s_body_alone(root, seed, store, capsys, tmp_path, flow):
    seed.body(14, "The old body.")
    body = tmp_path / "body.md"
    body.write_text(TRICKY)
    untouched = issue_15(store)

    assert orch_spec(root, seed, "update", str(body)) == 0
    assert capsys.readouterr() == ("", "")
    assert read(store, "issues", 14, "body") == TRICKY
    assert issue_15(store) == untouched


def test_a_failed_update_names_gh_s_reason_and_the_issue(root, seed, capsys, tmp_path, flow):
    seed.fail("adapter_issue_body_edit", "fake gh: issue edit refused")
    body = tmp_path / "body.md"
    body.write_text(TRICKY)

    assert orch_spec(root, seed, "update", str(body)) == 1
    err = capsys.readouterr().err
    assert "issue edit refused" in err and "issue #14" in err


@pytest.mark.parametrize("op", ["update", "comment"])
def test_a_write_of_a_missing_file_names_it_and_reaches_no_gh(root, seed, store, capsys, flow, op):
    before = snapshot(store)

    assert orch_spec(root, seed, op, "/nonexistent/body.md") == 1
    assert capsys.readouterr() == ("", "orch: body file not found: /nonexistent/body.md\n")
    assert snapshot(store) == before


def test_comment_posts_the_file_on_the_flow_issue_alone(root, seed, store, capsys, tmp_path, flow):
    body = tmp_path / "body.md"
    body.write_text(TRICKY)
    untouched = issue_15(store)

    assert orch_spec(root, seed, "comment", str(body)) == 0
    assert capsys.readouterr() == ("", "")
    assert comments_of(store, 14) == [TRICKY]
    assert issue_15(store) == untouched


def test_comments_writes_the_flow_issue_s_comments_without_review_changelogs(
        root, seed, capsys, tmp_path, flow):
    seed.comment(14, "pat", "2026-09-02T11:00:00Z", "## Spec review\nRound 1 of 1")
    seed.comment(14, "pat", "2026-09-02T11:30:00Z", "A follow-up.")
    seed.comment(14, "sam", "2026-09-02T11:40:00Z",
                 "A note that quotes\n## Spec review\nlower down.")
    out = tmp_path / "comments.md"

    assert orch_spec(root, seed, "comments", str(out)) == 0
    assert capsys.readouterr() == ("", "")
    assert out.read_text() == (
        "<!-- comment @pat 2026-09-02T11:30:00Z -->\nA follow-up.\n\n"
        "<!-- comment @sam 2026-09-02T11:40:00Z -->\nA note that quotes\n## Spec review\n"
        "lower down.\n")


# --- pause ---------------------------------------------------------------------

BLOCK = "Spec #21 written. The spec review runs in a fresh session.\n\n  Next: %s\n"


def paused_marker(root):
    return root / ".orchestrator" / "handoff" / "spec-paused"


@pytest.mark.parametrize("env, next_line", [
    ({"CLAUDECODE": "1"}, "/clear, then /orchestrator:next"),
    ({"ORCHESTRATOR_HOST": "junie"}, "/new, then ask for the next phase with /orch-flow"),
    ({}, "a fresh session, then /orchestrator:next (or orch-flow's Next phase section)"),
], ids=["claude", "junie", "other"])
def test_pause_writes_the_marker_then_prints_the_block_with_the_host_s_next_line(
        root, seed, capsys, env, next_line):
    flow_state(root, "spec", 21)

    assert orch_spec(root, seed, "pause", env=env) == 0
    assert capsys.readouterr() == (BLOCK % next_line, "")
    assert paused_marker(root).read_text() == "21\n"


def test_pause_overwrites_a_marker_already_there_leaving_the_phase(root, seed, capsys):
    state = flow_state(root, "spec", 21)
    paused_marker(root).parent.mkdir(parents=True)
    paused_marker(root).write_text("99\n")
    recorded = state.read_text()

    assert orch_spec(root, seed, "pause", env={"CLAUDECODE": "1"}) == 0
    assert paused_marker(root).read_text() == "21\n"
    assert state.read_text() == recorded


@pytest.mark.parametrize("phase, issue, message", [
    ("spec", None, "no issue recorded in state - the spec phase must publish one first"),
    ("done", 21, "the flow on issue #21 is done - spec pause acts only on an active flow"),
    ("implement", 21, "spec pause runs only in the spec phase - the flow is at phase implement"),
    ("review", 21, "spec pause runs only in the spec phase - the flow is at phase review"),
    ("done", None, "no issue recorded in state - the spec phase must publish one first"),
    ("implement", None, "no issue recorded in state - the spec phase must publish one first"),
], ids=["no-issue", "done", "implement", "review", "no-issue-before-done",
        "no-issue-before-phase"])
def test_pause_refuses_outside_an_active_spec_phase_writing_no_marker(
        root, seed, capsys, phase, issue, message):
    flow_state(root, phase, issue)

    assert orch_spec(root, seed, "pause") == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % message)
    assert not paused_marker(root).parent.exists()


@pytest.mark.parametrize("phase, issue", [("spec", 21), ("done", 21), ("implement", None)],
                         ids=["spec", "done", "no-issue"])
def test_pause_refuses_an_argument_before_the_phase_refusals(root, seed, capsys, phase, issue):
    flow_state(root, phase, issue)

    assert orch_spec(root, seed, "pause", "extra") == 1
    assert capsys.readouterr() == ("", "orch: usage: orch.sh spec pause [--round <k>/<n>]\n")
    assert not paused_marker(root).parent.exists()


def test_a_handoff_folder_that_cannot_be_created_dies_naming_it_with_no_block(root, seed, capsys):
    flow_state(root, "spec", 21)
    (root / ".orchestrator" / "handoff").write_text("a file, not a folder\n")

    assert orch_spec(root, seed, "pause") == 1
    assert capsys.readouterr() == (
        "", "orch: cannot create %s/.orchestrator/handoff\n" % root)


def test_a_marker_that_cannot_be_written_dies_naming_it_with_no_block(root, seed, capsys):
    flow_state(root, "spec", 21)
    paused_marker(root).mkdir(parents=True)

    assert orch_spec(root, seed, "pause") == 1
    assert capsys.readouterr() == (
        "", "orch: cannot write %s/.orchestrator/handoff/spec-paused\n" % root)
