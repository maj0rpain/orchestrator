"""The spec noun run in-process against the gh adapter's fake on a tmp_path
store and a FakeGit checkout under tmp_path: the four reads and writes of the
flow's issue (fetch, update, comment, comments), the pause that stops the
spec phase's session, the round directory a flow's spec review round works
in (round-dir) with the round marker a resumed one reads (round), and the
pause after a spec review round, with its claim release in an autopilot
flow, each checked by its stdout, its exit code, its `orch:` message, the
markers and round directories it leaves and the store afterwards."""
from __future__ import annotations

import builtins
import os

import pytest

from conftest import GH_502, comments_of, died_of, flow_state, labels_of, read, snapshot
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
    assert not (root / ".orchestrator" / "spec-rounds").exists()


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
    assert not (root / ".orchestrator" / "spec-rounds").exists()


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
@pytest.mark.parametrize("argv", VERBS[:6] + [("round",)], ids=VERB_IDS[:6] + ["round"])
def test_each_verb_opens_the_state_file_exactly_once(root, seed, capsys, tmp_path, monkeypatch,
                                                     argv, phase):
    state = flow_state(root, phase, 14)
    (root / ".orchestrator" / "handoff").mkdir()
    (root / ".orchestrator" / "handoff" / "spec-round").write_text("14 1 2\n")
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


# --- round-dir -----------------------------------------------------------------


def rounds_of(root):
    return root / ".orchestrator" / "spec-rounds"


def round_marker(root):
    return root / ".orchestrator" / "handoff" / "spec-round"


def test_round_dir_prints_round_k_s_directory_created_empty_after_writing_the_marker(
        root, seed, capsys):
    flow_state(root, "spec", 21)

    assert orch_spec(root, seed, "round-dir", "1/2") == 0
    assert capsys.readouterr() == ("%s/1/\n" % rounds_of(root), "")
    assert os.listdir(str(rounds_of(root) / "1")) == []
    assert round_marker(root).read_text() == "21 1 2\n"


def write_files(directory, files):
    """<files>, by name, written into <directory>, made as needed; a name
    ending in / is a directory."""
    directory.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def tree(directory):
    """Every path under <directory>, relative, with each file's text."""
    return {os.path.relpath(os.path.join(at, name), str(directory)):
            open(os.path.join(at, name)).read()
            for at, _, names in os.walk(str(directory)) for name in names}


def test_round_dir_empties_a_populated_round_directory(root, seed):
    flow_state(root, "spec", 21)
    write_files(rounds_of(root) / "1", {"changelog.md": "stale\n", "settled.md": "stale\n",
                                        "sub/x": "stale\n"})

    assert orch_spec(root, seed, "round-dir", "1/2") == 0
    assert os.listdir(str(rounds_of(root) / "1")) == []


def test_round_dir_1_deletes_every_other_round_s_directory(root, seed):
    flow_state(root, "spec", 21)
    write_files(rounds_of(root) / "2", {"changelog.md": "stale\n"})
    write_files(rounds_of(root) / "3", {"map-implementability.md": "stale\n"})
    write_files(rounds_of(root), {"stray": "stale\n"})

    assert orch_spec(root, seed, "round-dir", "1/2") == 0
    assert os.listdir(str(rounds_of(root))) == ["1"]


ROUND_1 = {"map-implementability.md": "the code map\n", "settled.md": "round 1 changelog\n",
           "changelog.md": "round 1 changelog\n", "agent-lens": "model opus\neffort high\n",
           "round-complete": ""}


def test_a_later_round_dir_copies_in_the_lens_setting_code_map_and_settled_file(
        root, seed, capsys):
    flow_state(root, "spec", 21)
    write_files(rounds_of(root) / "1", ROUND_1)
    write_files(rounds_of(root) / "2", {"spec.md": "stale\n"})

    assert orch_spec(root, seed, "round-dir", "2/2") == 0
    assert capsys.readouterr() == ("%s/2/\n" % rounds_of(root), "")
    assert tree(rounds_of(root) / "2") == {
        "agent-lens": "model opus\neffort high\n", "map-implementability.md": "the code map\n",
        "settled.md": "round 1 changelog\n"}
    assert tree(rounds_of(root) / "1") == ROUND_1
    assert round_marker(root).read_text() == "21 2 2\n"


@pytest.mark.parametrize("left", ["agent-lens", "map-implementability.md", "settled.md"])
def test_a_later_round_dir_copies_each_carried_file_only_when_it_exists(root, seed, left):
    flow_state(root, "spec", 21)
    write_files(rounds_of(root) / "1", {left: "kept\n", "changelog.md": "not carried\n"})
    write_files(rounds_of(root) / "3", {"changelog.md": "round 3\n"})

    assert orch_spec(root, seed, "round-dir", "2/3") == 0
    assert tree(rounds_of(root) / "2") == {left: "kept\n"}
    assert tree(rounds_of(root) / "3") == {"changelog.md": "round 3\n"}


def test_a_later_round_dir_with_nothing_to_carry_leaves_its_directory_empty(root, seed, capsys):
    flow_state(root, "spec", 21)

    assert orch_spec(root, seed, "round-dir", "3/3") == 0
    assert capsys.readouterr() == ("%s/3/\n" % rounds_of(root), "")
    assert os.listdir(str(rounds_of(root) / "3")) == []


def round_files(root):
    """Every path under the rounds directory and the round marker's text, so a
    refusal is checked to have created and deleted nothing."""
    marker = round_marker(root)
    return tree(rounds_of(root)), marker.read_text() if marker.exists() else None


WANT_K_N = "want <k>/<n>, a round and the round count, two positive whole numbers, got: %s"


@pytest.mark.parametrize("arg", ["", "1", "0/2", "1/0", "a/2", "1/b", "1/2/3", "/2", "1/",
                                 "-1/2", "1 /2", "01/2", "1/02"])
def test_round_dir_refuses_a_malformed_round_count_touching_nothing(root, seed, capsys, arg):
    flow_state(root, "spec", 21)
    write_files(rounds_of(root) / "2", {"changelog.md": "round 2\n"})
    before = round_files(root)

    assert orch_spec(root, seed, "round-dir", arg) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % (WANT_K_N % arg))
    assert round_files(root) == before


@pytest.mark.parametrize("arg, message", [
    ("3/2", "round 3 is past the round count 2"),
    ("2/1", "round 2 is past the round count 1"),
], ids=["3/2", "2/1"])
def test_round_dir_refuses_a_round_past_the_count(root, seed, capsys, arg, message):
    flow_state(root, "spec", 21)
    before = round_files(root)

    assert orch_spec(root, seed, "round-dir", arg) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % message)
    assert round_files(root) == before


@pytest.mark.parametrize("args", [(), ("1/2", "2/2")], ids=["none", "two"])
@pytest.mark.parametrize("phase, issue", [("spec", 21), ("implement", None)],
                         ids=["spec", "no-issue"])
def test_round_dir_takes_exactly_one_argument_before_the_phase_refusals(
        root, seed, capsys, args, phase, issue):
    flow_state(root, phase, issue)

    assert orch_spec(root, seed, "round-dir", *args) == 1
    assert capsys.readouterr() == ("", "orch: usage: orch.sh spec round-dir <k>/<n>\n")
    assert round_files(root) == ({}, None)


@pytest.mark.parametrize("phase, issue, message", [
    ("spec", None, "no issue recorded in state - the spec phase must publish one first"),
    ("done", 21, "the flow on issue #21 is done - spec round-dir acts only on an active flow"),
    ("implement", 21,
     "spec round-dir runs only in the spec phase - the flow is at phase implement"),
    ("done", None, "no issue recorded in state - the spec phase must publish one first"),
], ids=["no-issue", "done", "implement", "no-issue-before-done"])
def test_round_dir_refuses_outside_an_active_spec_phase_touching_nothing(
        root, seed, capsys, phase, issue, message):
    flow_state(root, phase, issue)
    write_files(rounds_of(root) / "2", {"changelog.md": "round 2\n"})
    before = round_files(root)

    assert orch_spec(root, seed, "round-dir", "1/2") == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % message)
    assert round_files(root) == before


def test_round_dir_checks_the_round_count_before_the_phase(root, seed, capsys):
    flow_state(root, "implement", 21)

    assert orch_spec(root, seed, "round-dir", "3/2") == 1
    assert capsys.readouterr() == ("", "orch: round 3 is past the round count 2\n")


def test_round_dir_run_twice_gives_the_same_result(root, seed, capsys):
    flow_state(root, "spec", 21)
    write_files(rounds_of(root) / "1", ROUND_1)

    assert orch_spec(root, seed, "round-dir", "2/3") == 0
    first = capsys.readouterr(), tree(rounds_of(root)), round_marker(root).read_text()
    assert orch_spec(root, seed, "round-dir", "2/3") == 0
    assert (capsys.readouterr(), tree(rounds_of(root)), round_marker(root).read_text()) == first


def test_a_round_dir_whose_marker_cannot_be_written_prints_no_path(root, seed, capsys):
    flow_state(root, "spec", 21)
    round_marker(root).mkdir(parents=True)

    assert orch_spec(root, seed, "round-dir", "1/2") == 1
    assert capsys.readouterr() == ("", "orch: cannot write %s\n" % round_marker(root))


# A read-only directory does not stop root.
AS_ROOT = pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")


@pytest.mark.parametrize("blocked", ["rounds", pytest.param("round", marks=AS_ROOT)])
def test_a_round_directory_that_cannot_be_prepared_dies_before_the_marker(
        root, seed, capsys, blocked):
    flow_state(root, "spec", 21)
    if blocked == "rounds":
        write_files(root / ".orchestrator", {"spec-rounds": "a file, not a folder\n"})
    else:
        write_files(rounds_of(root), {"1": "a file, not a folder\n"})
        (rounds_of(root)).chmod(0o555)

    try:
        assert orch_spec(root, seed, "round-dir", "1/2") == 1
    finally:
        if rounds_of(root).is_dir():
            rounds_of(root).chmod(0o755)
    assert capsys.readouterr() == (
        "", "orch: could not reset the round directory %s/1\n" % rounds_of(root))
    assert not round_marker(root).exists()


@AS_ROOT
def test_a_round_1_sweep_that_cannot_delete_a_round_dies_before_the_marker(root, seed, capsys):
    flow_state(root, "spec", 21)
    write_files(rounds_of(root) / "2" / "deep", {"changelog.md": "round 2\n"})
    (rounds_of(root) / "2" / "deep").chmod(0o555)

    try:
        assert orch_spec(root, seed, "round-dir", "1/2") == 1
    finally:
        (rounds_of(root) / "2" / "deep").chmod(0o755)
    assert capsys.readouterr() == (
        "", "orch: could not reset the round directory %s/1\n" % rounds_of(root))
    assert not round_marker(root).exists()


@AS_ROOT
def test_a_carried_file_that_cannot_be_copied_dies_naming_it_before_the_marker(
        root, seed, capsys):
    flow_state(root, "spec", 21)
    write_files(rounds_of(root) / "1", {"settled.md": "round 1 changelog\n"})
    (rounds_of(root) / "1" / "settled.md").chmod(0o000)

    try:
        assert orch_spec(root, seed, "round-dir", "2/2") == 1
    finally:
        (rounds_of(root) / "1" / "settled.md").chmod(0o644)
    assert capsys.readouterr() == (
        "", "orch: cannot copy round 1's settled.md into %s/2\n" % rounds_of(root))
    assert not round_marker(root).exists()


# --- round ---------------------------------------------------------------------


def write_marker(root, text):
    round_marker(root).parent.mkdir(parents=True, exist_ok=True)
    round_marker(root).write_text(text)


@pytest.mark.parametrize("files, printed", [
    ({}, "1 2"),
    ({"settled.md": "carried in\n"}, "1 2"),
    ({"apply-answer": ""}, "1 2 applying"),
    ({"fundamental.md": ""}, "1 2 waiting"),
    ({"fundamental.md": "", "apply-answer": ""}, "1 2 applying"),
    ({"round-complete": ""}, "2 2"),
    ({"round-complete": "", "fundamental.md": ""}, "1 2 waiting"),
], ids=["open", "carried-only", "applying", "waiting", "applying-held", "complete",
        "complete-but-held"])
def test_round_says_where_the_marker_s_round_stands(root, seed, capsys, files, printed):
    flow_state(root, "spec", 21)
    write_marker(root, "21 1 2\n")
    write_files(rounds_of(root) / "1", files)

    assert orch_spec(root, seed, "round") == 0
    assert capsys.readouterr() == (printed + "\n", "")


@pytest.mark.parametrize("files, printed", [
    ({}, "2 2"),
    ({"round-complete": ""}, "done 2"),
], ids=["open", "complete"])
def test_round_on_the_last_round_says_done_once_it_is_complete(root, seed, capsys, files,
                                                               printed):
    flow_state(root, "spec", 21)
    write_marker(root, "21 2 2\n")
    write_files(rounds_of(root) / "2", files)

    assert orch_spec(root, seed, "round") == 0
    assert capsys.readouterr() == (printed + "\n", "")


def test_round_reads_the_marker_round_dir_wrote(root, seed, capsys):
    flow_state(root, "spec", 21)
    assert orch_spec(root, seed, "round-dir", "1/1") == 0
    capsys.readouterr()

    assert orch_spec(root, seed, "round") == 0
    assert capsys.readouterr() == ("1 1\n", "")


@pytest.mark.parametrize("marker", [None, "22 1 2\n"], ids=["no-marker", "another-issue"])
def test_round_exits_1_printing_nothing_with_no_marker_for_the_flow(root, seed, capsys, marker):
    flow_state(root, "spec", 21)
    if marker is not None:
        write_marker(root, marker)

    assert orch_spec(root, seed, "round") == 1
    assert capsys.readouterr() == ("", "")


def test_a_round_marker_that_is_a_directory_is_no_marker(root, seed, capsys):
    flow_state(root, "spec", 21)
    round_marker(root).mkdir(parents=True)

    assert orch_spec(root, seed, "round") == 1
    assert capsys.readouterr() == ("", "")


RERUN = "want <issue> <k> <n>; rerun orch.sh spec round-dir <k>/<n>"


@pytest.mark.parametrize("text, line", [
    ("\n", ""), ("garbage\n", "garbage"), ("21\n", "21"), ("21 1\n", "21 1"),
    ("21 3 2\n", "21 3 2"), ("21 0 2\n", "21 0 2"), ("21 a 2\n", "21 a 2"),
    ("x 1 2\n", "x 1 2"), ("21 1 2 9\n", "21 1 2 9"), ("21 01 2\n", "21 01 2"),
    ("21 1 2\r\n", "21 1 2\r"),
], ids=["blank", "garbage", "issue-only", "no-count", "past-count", "zero", "word-round",
        "word-issue", "extra", "leading-zero", "carriage-return"])
def test_a_malformed_round_marker_exits_2_naming_it_and_the_rerun(root, seed, capsys, text, line):
    flow_state(root, "spec", 21)
    write_marker(root, text)

    assert orch_spec(root, seed, "round") == 2
    assert capsys.readouterr() == ("", "orch: malformed round marker %s: '%s' - %s\n"
                                   % (round_marker(root), line, RERUN))


def test_an_empty_round_marker_exits_2_saying_it_is_empty(root, seed, capsys):
    flow_state(root, "spec", 21)
    write_marker(root, "")

    assert orch_spec(root, seed, "round") == 2
    assert capsys.readouterr() == ("", "orch: malformed round marker %s: it is empty - %s\n"
                                   % (round_marker(root), RERUN))


@pytest.mark.parametrize("text", ["21 1 2", "  21\t1  2  \n", "21 1 2\nmore\n"],
                         ids=["no-newline", "blanks", "second-line"])
def test_a_round_marker_is_read_as_bash_reads_its_first_line(root, seed, capsys, text):
    flow_state(root, "spec", 21)
    write_marker(root, text)

    assert orch_spec(root, seed, "round") == 0
    assert capsys.readouterr() == ("1 2\n", "")


@pytest.mark.parametrize("phase, issue, message", [
    ("spec", None, "no issue recorded in state - the spec phase must publish one first"),
    ("done", 21, "the flow on issue #21 is done - spec round acts only on an active flow"),
    ("implement", 21, "spec round runs only in the spec phase - the flow is at phase implement"),
], ids=["no-issue", "done", "implement"])
def test_round_exits_2_outside_an_active_spec_phase(root, seed, capsys, phase, issue, message):
    flow_state(root, phase, issue)
    write_marker(root, "21 1 2\n")

    assert orch_spec(root, seed, "round") == 2
    assert capsys.readouterr() == ("", "orch: %s\n" % message)


@pytest.mark.parametrize("state", ["missing", "spec", "truncated"])
def test_round_refuses_an_argument_first_exiting_2(root, seed, capsys, state):
    if state != "missing":
        written = flow_state(root, "spec", 21)
        if state == "truncated":
            written.write_text(written.read_text()[:20])

    assert orch_spec(root, seed, "round", "extra") == 2
    assert capsys.readouterr() == ("", "orch: usage: orch.sh spec round\n")


def test_round_exits_2_with_no_state_file(root, seed, capsys):
    assert orch_spec(root, seed, "round") == 2
    assert capsys.readouterr() == ("", NO_FLOW)


def test_round_exits_2_on_a_truncated_state_file(root, seed, capsys):
    state = flow_state(root, "spec", 21)
    state.write_text(state.read_text()[:20])
    write_marker(root, "21 1 2\n")

    assert orch_spec(root, seed, "round") == 2
    assert capsys.readouterr() == ("", UNREADABLE)


# --- pause --round ---------------------------------------------------------------

ROUND_BLOCK = ("Spec review round %d of %d applied. Round %d runs in a fresh session.\n\n"
               "  Next: %s\n")
CLAUDE_NEXT = "/clear, then /orchestrator:next"
AUTOPILOT = {"ORCHESTRATOR_HOST": "claude", "ORCH_AUTOPILOT": "1"}
PAUSE_USAGE = "orch: usage: orch.sh spec pause [--round <k>/<n>]\n"


@pytest.mark.parametrize("k, n, env, next_line", [
    (1, 3, {"CLAUDECODE": "1"}, CLAUDE_NEXT),
    (2, 3, {"ORCHESTRATOR_HOST": "junie"}, "/new, then ask for the next phase with /orch-flow"),
    (4, 12, {}, "a fresh session, then /orchestrator:next (or orch-flow's Next phase section)"),
], ids=["claude", "junie", "other"])
def test_pause_round_writes_the_marker_naming_the_next_round_then_prints_the_block(
        root, seed, capsys, k, n, env, next_line):
    state = flow_state(root, "spec", 21)
    recorded = state.read_text()

    assert orch_spec(root, seed, "pause", "--round", "%d/%d" % (k, n), env=env) == 0
    assert capsys.readouterr() == (ROUND_BLOCK % (k, n, k + 1, next_line), "")
    assert round_marker(root).read_text() == "21 %d %d\n" % (k + 1, n)
    assert not paused_marker(root).exists()
    assert state.read_text() == recorded


def test_pause_round_overwrites_a_round_marker_already_there(root, seed, capsys):
    flow_state(root, "spec", 21)
    round_marker(root).parent.mkdir(parents=True)
    round_marker(root).write_text("21 2 3\n")

    assert orch_spec(root, seed, "pause", "--round", "2/3") == 0
    assert round_marker(root).read_text() == "21 3 3\n"


# Each refusal before the phase refusals, at a phase and with no issue that
# the phase refusals would refuse too: the usage, the round-count parse, the
# last round, in that order.
@pytest.mark.parametrize("args, message", [
    ((), PAUSE_USAGE),
    (("1/2", "extra"), PAUSE_USAGE),
    (("a/2", "extra"), PAUSE_USAGE),
    (("a/2",), "orch: want <k>/<n>, a round and the round count, two positive whole numbers,"
               " got: a/2\n"),
    (("02/3",), "orch: want <k>/<n>, a round and the round count, two positive whole numbers,"
                " got: 02/3\n"),
    (("3/2",), "orch: round 3 is past the round count 2\n"),
    (("2/2",), "orch: round 2 is the last of 2 - the last round never pauses; go on to the"
               " ticket breakdown\n"),
], ids=["no-round", "extra", "extra-before-parse", "malformed", "leading-zero", "past",
        "last"])
@pytest.mark.parametrize("phase, issue", [("spec", 21), ("implement", None), ("done", 21)],
                         ids=["spec", "no-issue", "done"])
def test_pause_round_refuses_its_argument_before_the_phase_refusals(
        root, seed, store, capsys, args, message, phase, issue):
    flow_state(root, phase, issue)
    seed.issue(21, "open", "orch:running")
    seed.claim(21)
    before = snapshot(store)

    assert orch_spec(root, seed, "pause", "--round", *args, env=AUTOPILOT) == 1
    assert capsys.readouterr() == ("", message)
    assert not round_marker(root).parent.exists()
    assert snapshot(store) == before


@pytest.mark.parametrize("phase, issue, message", [
    ("spec", None, "no issue recorded in state - the spec phase must publish one first"),
    ("done", 21, "the flow on issue #21 is done - spec pause acts only on an active flow"),
    ("implement", 21, "spec pause runs only in the spec phase - the flow is at phase implement"),
    ("done", None, "no issue recorded in state - the spec phase must publish one first"),
    ("implement", None, "no issue recorded in state - the spec phase must publish one first"),
], ids=["no-issue", "done", "implement", "no-issue-before-done", "no-issue-before-phase"])
def test_pause_round_refuses_outside_an_active_spec_phase_writing_nothing(
        root, seed, store, capsys, phase, issue, message):
    flow_state(root, phase, issue)
    seed.issue(21, "open", "orch:running")
    seed.claim(21)
    before = snapshot(store)

    assert orch_spec(root, seed, "pause", "--round", "1/2", env=AUTOPILOT) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % message)
    assert not round_marker(root).parent.exists()
    assert snapshot(store) == before


@pytest.mark.parametrize("argv, message", [
    ((), "orch: no active flow (.orchestrator/state.json not found). Run /orchestrator:start"
         " first.\n"),
    (("truncated",), UNREADABLE)], ids=["no-state", "truncated"])
def test_pause_round_without_a_readable_state_file_is_refused_before_any_write(
        root, seed, store, capsys, argv, message):
    if argv:
        state = flow_state(root, "spec", 21)
        state.write_text(state.read_text()[:20])
    seed.issue(21, "open", "orch:running")
    seed.claim(21)
    before = snapshot(store)

    assert orch_spec(root, seed, "pause", "--round", "1/2", env=AUTOPILOT) == 1
    assert capsys.readouterr() == ("", message)
    assert not (root / ".orchestrator" / "handoff").exists()
    assert snapshot(store) == before


@pytest.mark.parametrize("phase", ["spec", "implement", "done"])
def test_pause_round_opens_the_state_file_exactly_once(root, seed, capsys, monkeypatch, phase):
    state = flow_state(root, phase, 21)
    seed.issue(21, "open", "orch:running")
    seed.claim(21)
    opens = Opens(monkeypatch, state)

    orch_spec(root, seed, "pause", "--round", "1/2", env=AUTOPILOT)

    assert opens.count == 1


@pytest.fixture
def autopilot_flow(root, seed):
    """An autopilot flow at phase spec on issue #21, which carries
    orch:running and whose claim is held."""
    flow_state(root, "spec", 21)
    seed.issue(21, "open", "ready-for-agent", "orch:spec", "orch:running")
    seed.claim(21)


def test_pause_round_in_autopilot_releases_the_claim_then_prints_the_block(
        root, seed, store, capsys, autopilot_flow):
    assert orch_spec(root, seed, "pause", "--round", "1/2", env=AUTOPILOT) == 0
    assert capsys.readouterr() == (ROUND_BLOCK % (1, 2, 2, CLAUDE_NEXT), "")
    assert round_marker(root).read_text() == "21 2 2\n"
    assert labels_of(store, 21) == ["ready-for-agent", "orch:spec"]
    assert seed.claim_held(21) is False


def test_pause_round_in_autopilot_counts_a_claim_already_gone_as_freed(
        root, seed, store, capsys, autopilot_flow):
    FakeGh(seed.store, {}).claim_delete(21)

    assert orch_spec(root, seed, "pause", "--round", "1/2", env=AUTOPILOT) == 0
    assert capsys.readouterr() == (ROUND_BLOCK % (1, 2, 2, CLAUDE_NEXT), "")
    assert labels_of(store, 21) == ["ready-for-agent", "orch:spec"]
    assert seed.claim_held(21) is False


def test_a_failed_relabel_dies_with_the_marker_landed_trying_no_claim_delete(
        root, seed, store, capsys, autopilot_flow):
    seed.fail("adapter_issue_relabel", GH_502)

    assert orch_spec(root, seed, "pause", "--round", "1/2", env=AUTOPILOT) == 1
    assert capsys.readouterr() == (
        "", "orch: could not remove orch:running on issue #21: HTTP 502: Bad Gateway - writes"
            " that landed: wrote the round marker; the claim stays held\n")
    assert round_marker(root).read_text() == "21 2 2\n"
    assert labels_of(store, 21) == ["ready-for-agent", "orch:spec", "orch:running"]
    assert seed.claim_held(21) is True


def test_a_failed_claim_delete_dies_with_the_relabel_landed_and_the_claim_held(
        root, seed, store, capsys, autopilot_flow):
    seed.fail("adapter_claim_delete", "HTTP 500")

    assert orch_spec(root, seed, "pause", "--round", "1/2", env=AUTOPILOT) == 1
    assert capsys.readouterr() == (
        "", "orch: could not delete the claim ref on issue #21: HTTP 500 - writes that landed:"
            " wrote the round marker, removed orch:running; the claim stays held\n")
    assert labels_of(store, 21) == ["ready-for-agent", "orch:spec"]
    assert seed.claim_held(21) is True


@pytest.mark.parametrize("env", [AUTOPILOT, {"ORCHESTRATOR_HOST": "claude"}],
                         ids=["autopilot", "not-autopilot"])
def test_a_round_marker_that_cannot_be_written_dies_releasing_nothing(
        root, seed, store, capsys, autopilot_flow, env):
    round_marker(root).mkdir(parents=True)
    before = snapshot(store)

    assert orch_spec(root, seed, "pause", "--round", "1/2", env=env) == 1
    assert capsys.readouterr() == (
        "", "orch: cannot write %s/.orchestrator/handoff/spec-round\n" % root)
    assert snapshot(store) == before


def test_pause_round_outside_autopilot_leaves_the_label_and_the_claim(
        root, seed, store, capsys, autopilot_flow):
    before = snapshot(store)

    assert orch_spec(root, seed, "pause", "--round", "1/2", env={"ORCHESTRATOR_HOST": "claude",
                                                                 "ORCH_AUTOPILOT": "0"}) == 0
    assert capsys.readouterr() == (ROUND_BLOCK % (1, 2, 2, CLAUDE_NEXT), "")
    assert snapshot(store) == before
    assert seed.claim_held(21) is True
