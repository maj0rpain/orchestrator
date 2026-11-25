"""The init noun, which starts a flow. Its argument parsing, the busy and
planning-allowlist refusals, the adoption gate, the trust warning, the seed
and the folders it makes run in-process against FakeGit and the gh fake, the
dirty list faked through FakeGit's dirty_paths; the archive of a done flow and
the git exclude run against real repositories under tmp_path, since git's
worktree semantics are git's. Every expected message is bash cmd_init's,
verbatim."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from conftest import (ARCHIVE_STAMP, GH_502, archived, committed, done_flow, git_repo, hold_flow,
                      labels_doc, orch_review_pass, run_git, side_checkout, snapshot, state_json,
                      write_labels_doc)
from orch import flow_state, init
from orch.gh_fake import FakeGh
from orch.git import FakeGit, Git
from orch.repo import RepoPin

ORIGIN = {"origin": "https://github.com/acme/widgets.git"}
CLAUDE = {"CLAUDECODE": "1"}
# The clock the seed golden files were made with: 2026-01-02T03:04:05Z,
# archive_clock's time, so a done flow init archives is stamped ARCHIVE_STAMP.
CLOCK = 1767323045.0
USAGE = "orch: usage: orch.sh init <slug> [--issue N]\n"


def checkout_git(root, dirty=(), base="main"):
    """A FakeGit at <root>, its origin a GitHub repo: <dirty> the paths its
    status finds changed, <root>/.git its common directory, and <base> its
    orchestrator.base setting when one is given."""
    git = FakeGit(ORIGIN, toplevel=str(root))
    git.seed("dirty_paths", answer=list(dirty))
    git.seed("git_common_dir", answer=str(root / ".git"))
    if base is not None:
        git.seed("config_value", "orchestrator.base", answer=base)
    return git


def orch_init(seed, git, *argv, env=None):
    """`orch.sh init <argv>` in-process, on the gh fake over <seed>'s store,
    at CLOCK: its exit code, a SystemExit's included."""
    env = dict(CLAUDE) if env is None else env
    pin = RepoPin(env, git)
    gh = FakeGh(seed.store, env, pin=pin, sleep=lambda _: None)
    try:
        return init.run(list(argv), gh=gh, git=git, env=env, pin=pin, clock=lambda: CLOCK)
    except SystemExit as died:
        return died.code


# --- arguments -----------------------------------------------------------------


@pytest.mark.parametrize("argv, err", [
    ((), USAGE),
    (("",), USAGE),
    (("feat", "--issue"), USAGE),
    (("feat", "--issue", ""), USAGE),
    (("feat", "--issue", "x"), "orch: --issue wants a plain issue number, got: x\n"),
    (("feat", "--issue", "https://github.com/acme/widgets/issues/42"),
     "orch: --issue wants a plain issue number, got:"
     " https://github.com/acme/widgets/issues/42\n"),
    (("feat", "--bogus"), "orch: unknown init flag: --bogus (want --issue)\n"),
    (("!!",), "orch: slug is empty after normalisation\n"),
], ids=["no-slug", "empty-slug", "issue-no-value", "issue-empty", "issue-word", "issue-url",
        "unknown-flag", "empty-after-normalising"])
def test_a_usage_error_dies_exit_1_writing_nothing(root, seed, capsys, argv, err):
    assert orch_init(seed, checkout_git(root), *argv) == 1

    assert capsys.readouterr() == ("", err)
    assert not (root / ".orchestrator").exists()


# --- the seed and the folders --------------------------------------------------

SEED_GOLDEN = Path(__file__).resolve().parent / "flow_state" / "seed"


@pytest.mark.parametrize("name, argv", [("no-issue", ()), ("issue", ("--issue", "42"))])
def test_init_writes_bash_init_s_state_file_byte_for_byte_and_prints_the_slug(
        root, seed, capsys, name, argv):
    """The seed golden files are bash init's state.json for slug seed-golden,
    base rélease/2.0 and CLOCK (see test_flow_state)."""
    seed.issue(42, "open", "ready-for-agent")

    assert orch_init(seed, checkout_git(root, base="rélease/2.0"), "Seed Golden", *argv) == 0

    assert capsys.readouterr() == ("seed-golden\n", "")
    assert (root / ".orchestrator" / "state.json").read_bytes() == \
        (SEED_GOLDEN / (name + ".json")).read_bytes()
    assert sorted(p.name for p in (root / ".orchestrator").iterdir()) == \
        ["handoff", "review", "state.json"]
    assert (root / ".git" / "info" / "exclude").read_text() == ".orchestrator/\n.scratch/\n"


def test_with_no_base_setting_the_seed_records_github_s_default_branch(root, seed, capsys):
    seed.default_branch("trunk")
    git = checkout_git(root, base=None)
    git.seed("is_branch_name", "trunk", answer=True)

    assert orch_init(seed, git, "feat") == 0

    assert json.loads((root / ".orchestrator" / "state.json").read_text())["base"] == "trunk"


# --- the planning-allowlist refusal --------------------------------------------

# The planning record redirect as bash wrapped it, fold -s -w 75 under the
# message's five-space indent.
REDIRECT = (
    "     Write the exact wording you intended - the new or replaced text, and where\n"
    "     it goes - into the plan, so the spec carries it verbatim as an\n"
    "     Implementation Decision and it lands with the change it describes. For a\n"
    "     quick implementation, put it in the linked issue's body.\n"
)
OUTSIDE_ONLY = (
    "orch: the working tree has changes outside the planning allowlist:\n"
    "       stray.sh\n"
    "       sub/b.sh\n"
    "     Planning may only change: docs/agents/, .scratch/, .orchestrator/.\n"
    "     Commit, stash, or discard these changes, then run init again.\n"
)
RECORDS_ONLY = (
    "orch: the working tree has changes planning does not make.\n"
    "     Planning records changed (planning does not edit these in place):\n"
    "       GLOSSARY.md\n"
    "       docs/adr/1.md\n"
    + REDIRECT +
    "     Discard or stash these changes, then run init again.\n"
)
BOTH = (
    "orch: the working tree has changes planning does not make.\n"
    "     Planning records changed (planning does not edit these in place):\n"
    "       GLOSSARY.md\n"
    "       docs/adr/1.md\n"
    + REDIRECT +
    "     Changes outside the planning allowlist:\n"
    "       stray.sh\n"
    "     Planning may only change: docs/agents/, .scratch/, .orchestrator/.\n"
    "     Discard or stash the planning records; commit, stash, or discard the other\n"
    "     changes, then run init again.\n"
)


@pytest.mark.parametrize("dirty, err", [
    (["stray.sh", "docs/agents/x.md", "sub/b.sh"], OUTSIDE_ONLY),
    (["GLOSSARY.md", ".scratch/plan.md", "docs/adr/1.md"], RECORDS_ONLY),
    (["GLOSSARY.md", "stray.sh", "docs/adr/1.md"], BOTH),
], ids=["outside-only", "records-only", "both"])
def test_changes_outside_the_allowlist_refuse_in_their_three_message_forms(
        root, seed, capsys, dirty, err):
    assert orch_init(seed, checkout_git(root, dirty), "feat") == 1

    assert capsys.readouterr() == ("", err)
    assert not (root / ".orchestrator").exists()


def test_only_allowlisted_changes_let_init_start(root, seed, capsys):
    dirty = ["docs/agents/x.md", ".scratch/plan.md", ".orchestrator/note"]

    assert orch_init(seed, checkout_git(root, dirty), "feat") == 0
    assert capsys.readouterr() == ("feat\n", "")


def test_a_git_status_that_cannot_run_refuses_with_git_s_own_error_line(root, seed, capsys):
    git = checkout_git(root)
    git.seed("dirty_paths", answer="fatal: index file corrupt")

    assert orch_init(seed, git, "feat") == 1
    assert capsys.readouterr() == (
        "", "orch: git status failed - cannot check the working tree: fatal: index file corrupt\n")
    assert not (root / ".orchestrator").exists()


def test_the_allowlist_refusal_is_given_rather_than_a_rejected_issue_s(root, seed, capsys):
    seed.issue(7, "closed", "ready-for-agent")

    assert orch_init(seed, checkout_git(root, ["stray.sh", "sub/b.sh"]), "feat",
                     "--issue", "7") == 1
    assert capsys.readouterr() == ("", OUTSIDE_ONLY)


# --- the busy-checkout refusal -------------------------------------------------


def test_a_flow_mid_pipeline_refuses_exit_3_before_the_allowlist_check(root, seed, capsys):
    hold_flow(root, slug="my-feature", phase="spec")
    before = state_json(root).read_bytes()

    assert orch_init(seed, checkout_git(root, ["stray.sh"]), "other") == 3
    assert capsys.readouterr() == (
        "", "orch: busy: a flow is mid-pipeline (slug: my-feature, phase: spec)\n"
            "     One flow at a time - finish it, or run /orchestrator:abort.\n")
    assert state_json(root).read_bytes() == before


def test_a_plugin_made_branch_with_no_pr_refuses_exit_3(root, seed, capsys):
    git = checkout_git(root, ["stray.sh"])
    git.seed("current_branch", answer="quick/3-running")
    git.seed("config_value", "branch.quick/3-running.orchestrator-base", answer="main")

    assert orch_init(seed, git, "beside") == 3
    assert capsys.readouterr() == (
        "", "orch: busy: branch quick/3-running has no PR yet\n"
            "     Open its PR, or switch off it.\n")
    assert not (root / ".orchestrator").exists()


# --- the adoption gate ---------------------------------------------------------


@pytest.mark.parametrize("label", ["ready-for-agent", "Ready-For-Agent"])
def test_an_open_issue_carrying_ready_for_agent_is_adopted(root, seed, capsys, label):
    seed.issue(42, "open", "needs-info", label)

    assert orch_init(seed, checkout_git(root), "adopted", "--issue", "42") == 0
    assert capsys.readouterr() == ("adopted\n", "")
    assert json.loads(state_json(root).read_text())["issue"] == 42


def test_a_repo_that_renames_ready_for_agent_adopts_by_its_own_label(root, seed, capsys):
    write_labels_doc(root, labels_doc(("ready-for-agent", "-agent")))
    seed.issue(43, "open", "-agent")

    assert orch_init(seed, checkout_git(root), "dashed", "--issue", "43") == 0
    assert capsys.readouterr() == ("dashed\n", "")


@pytest.mark.parametrize("setup, err", [
    (lambda seed: seed.issue(7, "closed", "ready-for-agent"),
     "orch: issue #7 is not open - adoption requires an open issue.\n"),
    (lambda seed: seed.issue(7, "open", "needs-triage"),
     "orch: issue #7 is missing the 'ready-for-agent' triage label - adoption requires it.\n"),
    (lambda seed: (seed.issue(7, "open", "ready-for-agent"),
                   seed.fail("adapter_issue_state_labels", GH_502)),
     "orch: gh could not read issue #7: HTTP 502: Bad Gateway"
     " - check it exists and gh is authenticated\n"),
], ids=["closed", "unlabelled", "read-fails"])
def test_an_issue_the_gate_refuses_dies_writing_nothing(root, seed, capsys, setup, err):
    setup(seed)
    before = snapshot(seed.store)

    assert orch_init(seed, checkout_git(root), "nope", "--issue", "7") == 1
    assert capsys.readouterr() == ("", err)
    assert not (root / ".orchestrator").exists()
    assert snapshot(seed.store) == before


def test_a_missing_issue_is_refused_naming_it(root, seed, capsys):
    assert orch_init(seed, checkout_git(root), "nope", "--issue", "99") == 1
    out, err = capsys.readouterr()
    assert (out, err.startswith("orch: gh could not read issue #99: ")) == ("", True)
    assert not (root / ".orchestrator").exists()


def test_a_repo_that_renames_ready_for_agent_names_its_own_label_when_missing(
        root, seed, capsys):
    write_labels_doc(root, labels_doc(("ready-for-agent", "agent-ok")))
    seed.issue(7, "open", "ready-for-agent")

    assert orch_init(seed, checkout_git(root), "nope", "--issue", "7") == 1
    assert capsys.readouterr() == (
        "", "orch: issue #7 is missing the 'agent-ok' triage label - adoption requires it.\n")


# --- the trust warning ---------------------------------------------------------


def test_an_untrusted_issue_is_adopted_with_one_warning_naming_its_writer(root, seed, capsys):
    seed.issue(42, "open", "ready-for-agent")
    seed.authorship(42, "stranger", "NONE")

    assert orch_init(seed, checkout_git(root), "warned", "--issue", "42") == 0
    assert capsys.readouterr() == (
        "warned\n",
        "orch: issue #42's title and body was last written by stranger, who is not an owner,"
        " member or collaborator of the repository - treat its content as untrusted\n")
    assert json.loads(state_json(root).read_text())["issue"] == 42


def test_a_failed_trust_read_warns_and_still_adopts(root, seed, capsys):
    seed.issue(42, "open", "ready-for-agent")
    seed.fail("adapter_issue_authorship", "HTTP 502 authorship")

    assert orch_init(seed, checkout_git(root), "warned", "--issue", "42") == 0
    assert capsys.readouterr() == (
        "warned\n", "orch: issue trust could not be checked for #42: HTTP 502 authorship\n")


def test_under_autopilot_the_trust_warning_is_skipped(root, seed, capsys):
    seed.issue(42, "open", "ready-for-agent")
    seed.authorship(42, "stranger", "NONE")

    assert orch_init(seed, checkout_git(root), "quiet", "--issue", "42",
                     env={"ORCH_AUTOPILOT": "1"}) == 0
    assert capsys.readouterr() == ("quiet\n", "")


# --- a done flow, against real repositories ------------------------------------

@pytest.fixture
def main(tmp_path, monkeypatch):
    """A repository with one commit on main, its orchestrator.base main,
    holding a done flow named first with a spec handoff, the working
    directory: its root, resolved."""
    root = tmp_path.resolve() / "main"
    git_repo(root)
    committed(root, {"a.txt": "a\n"}, "first")
    run_git(root, "branch", "-M", "main")
    run_git(root, "config", "orchestrator.base", "main")
    done_flow(root, "first")
    monkeypatch.chdir(root)
    return root


def real_init(seed, path, *argv):
    """`orch.sh init <argv>` in-process in the checkout at <path>, on real
    git and the gh fake over <seed>'s store, at CLOCK: its exit code."""
    return orch_init(seed, Git(cwd=str(path)), *argv)


def slug_of(path):
    """The slug the flow in the checkout at <path> records."""
    return json.loads(state_json(path).read_text())["slug"]


def archived_slug(archive):
    """The slug the flow archived in the directory <archive> records."""
    return json.loads((archive / "state.json").read_text())["slug"]


def test_a_done_flow_is_archived_in_place_its_note_printed_before_the_slug(
        main, seed, capsys):
    assert real_init(seed, main, "second") == 0

    archive = ".orchestrator/archive/%s-first" % ARCHIVE_STAMP
    assert capsys.readouterr() == ("%s\nsecond\n" % archive, "")
    assert sorted(p.name for p in (main / archive).iterdir()) == ["handoff", "state.json"]
    assert archived_slug(main / archive) == "first"
    assert (slug_of(main), json.loads(state_json(main).read_text())["phase"]) == \
        ("second", "spec")
    assert sorted(p.name for p in (main / ".orchestrator").iterdir()) == \
        ["archive", "handoff", "review", "state.json"]


def test_from_a_side_checkout_a_done_flow_moves_into_the_main_checkout_s_archive(
        main, seed, capsys, monkeypatch):
    side = side_checkout(main, "alpha")
    done_flow(side, "side-flow")
    monkeypatch.chdir(side)

    assert real_init(seed, side, "next") == 0

    archive = archived(main, "side-flow")
    assert capsys.readouterr() == ("%s\nnext\n" % archive, "")
    assert archived_slug(archive) == "side-flow"
    assert slug_of(side) == "next"
    assert slug_of(main) == "first"


def test_a_done_flow_with_a_rejected_issue_is_left_in_place(main, seed, capsys):
    before = state_json(main).read_bytes()

    assert real_init(seed, main, "nope", "--issue", "99") == 1

    assert capsys.readouterr()[1].startswith("orch: gh could not read issue #99: ")
    assert state_json(main).read_bytes() == before
    assert not (main / ".orchestrator" / "archive").exists()


def test_a_done_flow_with_a_valid_issue_is_archived_and_the_new_flow_records_it(
        main, seed, capsys):
    seed.issue(42, "open", "ready-for-agent")

    assert real_init(seed, main, "second", "--issue", "42") == 0

    assert capsys.readouterr() == (
        ".orchestrator/archive/%s-first\nsecond\n" % ARCHIVE_STAMP, "")
    assert json.loads(state_json(main).read_text())["issue"] == 42


# --- the git exclude, against real repositories --------------------------------


@pytest.fixture
def fresh(tmp_path, monkeypatch):
    """A repository with one commit on main, its orchestrator.base main and
    no flow, the working directory: its root, resolved."""
    root = tmp_path.resolve() / "fresh"
    git_repo(root)
    committed(root, {"a.txt": "a\n"}, "first")
    run_git(root, "branch", "-M", "main")
    run_git(root, "config", "orchestrator.base", "main")
    monkeypatch.chdir(root)
    return root


def exclude_of(root):
    return root / ".git" / "info" / "exclude"


def test_the_plugin_s_directories_are_excluded_once_across_runs_and_review_pass_begin(
        fresh, seed, capsys):
    git = Git(cwd=str(fresh))
    before = exclude_of(fresh).read_text()

    assert real_init(seed, fresh, "first") == 0
    state_json(fresh).unlink()
    assert real_init(seed, fresh, "second") == 0
    run_git(fresh, "checkout", "-qb", "quick/7-bar")
    assert orch_review_pass(seed, git, "begin", "7") == 0

    assert exclude_of(fresh).read_text() == before + ".orchestrator/\n.scratch/\n"
    assert run_git(fresh, "status", "--porcelain") == ""


@pytest.mark.parametrize("before, after", [
    (".scratch/\n", ".scratch/\n.orchestrator/\n"),
    ("secrets.env", "secrets.env\n.orchestrator/\n.scratch/\n"),
], ids=["scratch-kept", "unterminated"])
def test_an_exclude_file_s_lines_are_kept_and_its_last_line_ended_first(
        fresh, seed, capsys, before, after):
    exclude_of(fresh).write_text(before)

    assert real_init(seed, fresh, "feat") == 0

    assert exclude_of(fresh).read_text() == after
    (fresh / ".scratch").mkdir()
    (fresh / ".scratch" / "plan.md").write_text("plan\n")
    assert run_git(fresh, "status", "--porcelain") == ""


# --- failures ------------------------------------------------------------------


def test_a_seed_that_cannot_be_built_dies_leaving_a_done_flow_unarchived(
        root, seed, capsys, monkeypatch):
    """An arg row the seed has no value for, as a key added to the table
    without one would be."""
    hold_flow(root, slug="first", phase="done")
    before = state_json(root).read_bytes()
    monkeypatch.setattr(flow_state, "STATE_KEYS", flow_state.STATE_KEYS + (("bogus", "", "arg"),))

    assert orch_init(seed, checkout_git(root), "next") == 1
    assert capsys.readouterr() == (
        "", "orch: could not build the state seed - nothing was written\n")
    assert state_json(root).read_bytes() == before
    assert not (root / ".orchestrator" / "archive").exists()


def test_a_done_flow_whose_checkouts_cannot_be_read_dies_left_in_place(root, seed, capsys):
    hold_flow(root, slug="first", phase="done")
    before = state_json(root).read_bytes()

    assert orch_init(seed, checkout_git(root), "next") == 1
    assert capsys.readouterr() == (
        "", "orch: could not read the checkouts - nothing was archived or written\n")
    assert state_json(root).read_bytes() == before
    assert sorted(p.name for p in (root / ".orchestrator").iterdir()) == ["state.json"]


def test_a_state_file_that_cannot_be_written_dies_naming_it(root, seed, capsys):
    state_json(root).mkdir(parents=True)

    assert orch_init(seed, checkout_git(root), "feat") == 1
    assert capsys.readouterr() == ("", "orch: could not write .orchestrator/state.json\n")
    assert state_json(root).is_dir()


def test_a_folder_that_cannot_be_made_prints_mkdir_s_message_and_exits_1(root, seed, capsys):
    (root / ".orchestrator").mkdir()
    (root / ".orchestrator" / "handoff").write_text("")

    assert orch_init(seed, checkout_git(root), "feat") == 1
    assert capsys.readouterr() == (
        "", "mkdir: cannot create directory '%s/.orchestrator/handoff': File exists\n" % root)
    assert (root / ".orchestrator" / "review").is_dir()
    assert not state_json(root).exists()


def test_an_exclude_write_that_fails_dies_keeping_the_done_flow_s_archive(main, seed, capsys):
    """The exclude file a link under a plain file, which git reads as no
    file and no one, root included, can write."""
    exclude_of(main).unlink()
    exclude_of(main).symlink_to(main / "a.txt" / "exclude")

    assert real_init(seed, main, "second") == 1

    assert capsys.readouterr() == (
        "", "orch: cannot add .orchestrator/, .scratch/ to the git exclude file"
            " .git/info/exclude\n")
    archive = archived(main, "first")
    assert archived_slug(archive) == "first"
    assert not state_json(main).exists()
