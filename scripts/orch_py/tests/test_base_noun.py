"""`orch.sh base set|show|clear` and the noun's dispatch, called in-process
through the base module's run, against FakeGit, the gh fake and a tmp_path
state.json: the checkout's base branch setting, the base note, a flow's own
base (`base set --flow`) and the active-flow note. Each message, exit code
and order of checks is the bash noun's, verbatim."""
from __future__ import annotations

import json
import os

import pytest

from conftest import (GH_502, GITHUB_ORIGIN, CountingGh, fake, hold_flow, origin_main_clone,
                      outcome, run_git, state_json, worktree_add)

from orch import base as module
from orch.git import FakeGit, Git


def checkout(tmp_path, **config):
    """A FakeGit at tmp_path with the acme/widgets origin, its local config
    holding <config> (each key's . spelled __)."""
    local = {key.replace("__", "."): value for key, value in config.items()}
    return FakeGit(GITHUB_ORIGIN, toplevel=str(tmp_path), local_config=local)


def orch(capsys, seed, git, *argv, env=None, gh=None):
    """`orch.sh base <argv>` in-process, through <git> and the gh fake over
    <seed>'s store (or <gh>): (exit code, stdout, stderr)."""
    gh = fake(seed) if gh is None else gh
    return outcome(capsys, lambda: module.run(list(argv), gh=gh, git=git,
                                              env={} if env is None else env))


# --- the dispatch ----------------------------------------------------------------------


@pytest.mark.parametrize("argv, named", [(("bogus",), "bogus"), ((), "<none>")],
                         ids=["unknown", "missing"])
def test_an_unknown_or_missing_op_is_refused_naming_the_three(tmp_path, seed, capsys, argv,
                                                              named):
    assert orch(capsys, seed, checkout(tmp_path), *argv) == (
        1, "", "orch: unknown base op: %s (want set|show|clear)\n" % named)


def on_origin_head(git, name="main"):
    """<git> with origin/HEAD naming <name>, a valid branch name: the
    default branch a gh that cannot answer settles on."""
    git.seed("origin_head_branch", answer=name)
    git.seed("is_branch_name", name, answer=True)
    return git


def setting(git):
    """The checkout's orchestrator.base, "<unset>" when none is set."""
    return git.config_value("orchestrator.base") or "<unset>"


# --- show and clear --------------------------------------------------------------------


def test_show_names_the_default_branch_as_the_source_when_nothing_is_set(tmp_path, seed,
                                                                          capsys):
    assert orch(capsys, seed, on_origin_head(checkout(tmp_path)), "show") == (
        0, "main (default)\n", "")


def test_show_names_the_setting_as_the_source(tmp_path, seed, capsys):
    git = on_origin_head(checkout(tmp_path, orchestrator__base="uat"))

    assert orch(capsys, seed, git, "show") == (0, "uat (set)\n", "")


def test_a_stored_main_survives_github_later_answering_develop(tmp_path, seed, capsys):
    seed.default_branch("develop")
    git = checkout(tmp_path, orchestrator__base="main")
    git.seed("is_branch_name", "develop", answer=True)

    assert orch(capsys, seed, git, "show") == (0, "main (set)\n", "")


@pytest.mark.parametrize("before", ["uat", None], ids=["set", "unset"])
def test_clear_removes_the_setting_and_prints_the_base_it_falls_back_to(tmp_path, seed, capsys,
                                                                        before):
    git = on_origin_head(checkout(tmp_path, **({"orchestrator__base": before} if before else {})))

    assert orch(capsys, seed, git, "clear") == (0, "main (default)\n", "")
    assert setting(git) == "<unset>"


@pytest.mark.parametrize("op", ["show", "clear"])
def test_show_and_clear_refuse_any_argument_with_their_usage_line(tmp_path, seed, capsys, op):
    git = on_origin_head(checkout(tmp_path, orchestrator__base="uat"))

    assert orch(capsys, seed, git, op, "--flow") == (1, "", "orch: usage: orch.sh base %s\n" % op)
    assert setting(git) == "uat"


# --- set -------------------------------------------------------------------------------

SET_USAGE = "orch: usage: orch.sh base set <branch> [--flow]\n"
MISSING = "orch: branch %s does not exist on origin - push it first, or check the name\n"
UNREACHABLE = "orch: could not reach origin to check that branch %s exists - nothing was set\n"
UNREADABLE = "orch: state.json cannot be read - run orch.sh doctor --flow\n"


def on_origin(git, *names):
    """<git> with origin answering that it has each of <names>, each a valid
    branch name."""
    for name in names:
        git.seed("origin_has_branch", name, answer=True)
        git.seed("is_branch_name", name, answer=True)
    return git


@pytest.mark.parametrize("args", [(), ("--flow",), ("uat", "main", "--flow"),
                                  ("uat", "--flow", "--flow"), ("uat", "--flaw")],
                         ids=["none", "flag-alone", "two-names", "two-flags", "misspelt-flag"])
def test_set_refuses_its_arguments_with_its_usage_line(tmp_path, seed, capsys, args):
    git = on_origin(on_origin_head(checkout(tmp_path)), "uat")

    assert orch(capsys, seed, git, "set", *args) == (1, "", SET_USAGE)
    assert setting(git) == "<unset>"


def test_every_worktree_of_the_clone_shares_the_setting(tmp_path, seed, capsys):
    """Against real repositories under tmp_path, origin a local bare one, so
    the setting is read back as git keeps it for the whole clone."""
    root, _ = origin_main_clone(tmp_path, {"a.txt": "a\n"})
    run_git(root, "push", "-q", "origin", "HEAD:refs/heads/uat")
    wt = worktree_add(root, tmp_path / "wt", "-b", "base-wt")

    assert orch(capsys, seed, Git(str(root)), "set", "uat") == (0, "uat (set)\n", "")
    assert orch(capsys, seed, Git(str(wt)), "show") == (0, "uat (set)\n", "")


def test_set_refuses_a_branch_missing_from_origin_leaving_the_config_untouched(tmp_path, seed,
                                                                              capsys):
    git = on_origin_head(checkout(tmp_path))
    git.seed("origin_has_branch", "nosuch", answer=False)

    assert orch(capsys, seed, git, "set", "nosuch") == (1, "", MISSING % "nosuch")
    assert setting(git) == "<unset>"


def test_set_refuses_when_origin_cannot_be_reached_to_verify(tmp_path, seed, capsys):
    git = on_origin_head(checkout(tmp_path, orchestrator__base="uat"))
    git.seed("origin_has_branch", "main", answer=None)

    assert orch(capsys, seed, git, "set", "main") == (1, "", UNREACHABLE % "main")
    assert setting(git) == "uat"


def test_set_accepts_a_branch_origin_has_writing_orchestrator_base(tmp_path, seed, capsys):
    git = on_origin(on_origin_head(checkout(tmp_path)), "uat")

    assert orch(capsys, seed, git, "set", "uat") == (0, "uat (set)\n", "")
    assert setting(git) == "uat"


def test_setting_the_default_branch_origin_head_names_acts_as_clearing(tmp_path, seed, capsys):
    git = on_origin(on_origin_head(checkout(tmp_path, orchestrator__base="uat")), "main")

    assert orch(capsys, seed, git, "set", "main") == (0, "main (default)\n", "")
    assert setting(git) == "<unset>"


def test_a_guessed_main_is_stored_as_a_setting(tmp_path, seed, capsys):
    """With gh failing and origin/HEAD gone, the only main is the fallback
    literal, so setting it is stored, not cleared."""
    git = on_origin(checkout(tmp_path), "main")

    assert orch(capsys, seed, git, "set", "main") == (0, "main (set)\n", "")
    assert setting(git) == "main"


def test_github_s_main_clears_the_setting(tmp_path, seed, capsys):
    seed.default_branch("main")
    git = on_origin(checkout(tmp_path, orchestrator__base="uat"), "main")

    assert orch(capsys, seed, git, "set", "main") == (0, "main (default)\n", "")
    assert setting(git) == "<unset>"


def test_a_failed_config_write_ends_the_run_with_git_s_status_and_stderr(tmp_path, seed, capsys):
    git = on_origin(on_origin_head(checkout(tmp_path)), "uat")
    git.config_write_fails.add("local")

    assert orch(capsys, seed, git, "set", "uat") == (
        255, "", "error: could not lock config file .git/config: File exists\n")
    assert setting(git) == "<unset>"


def counting(seed):
    """The gh fake over <seed>'s store, counting its default-branch asks."""
    return CountingGh(seed.store, {}, sleep=lambda _: None)


def test_set_beside_a_base_less_flow_asks_github_for_the_default_branch_once(tmp_path, seed,
                                                                            capsys):
    """One run asks GitHub for the default branch once, however many times its
    check, its output line and its active-flow note read it."""
    hold_flow(tmp_path, slug="counted", phase="spec")
    seed.default_branch("main")
    git = on_origin(checkout(tmp_path, orchestrator__base="uat"), "main")
    gh = counting(seed)

    assert orch(capsys, seed, git, "set", "main", gh=gh) == (0, "main (default)\n", "")
    assert len(gh.default_asks) == 1
    assert setting(git) == "<unset>"


@pytest.mark.parametrize("head, line", [(True, "main (default)\n"), (False, "main (set)\n")],
                         ids=["origin-head-present", "origin-head-deleted"])
def test_set_with_the_default_branch_read_failing_asks_it_once(tmp_path, seed, capsys, head, line):
    hold_flow(tmp_path, slug="counted", phase="spec")
    seed.fail("adapter_repo_default_branch", GH_502)
    git = on_origin(checkout(tmp_path), "main")
    if head:
        on_origin_head(git)
    gh = counting(seed)

    assert orch(capsys, seed, git, "set", "main", gh=gh) == (0, line, "")
    assert len(gh.default_asks) == 1


def test_set_says_nothing_more_when_the_active_flow_already_has_that_base(tmp_path, seed, capsys):
    hold_flow(tmp_path, slug="flowbase", phase="spec", base="uat")
    git = on_origin(on_origin_head(checkout(tmp_path)), "uat")

    assert orch(capsys, seed, git, "set", "uat") == (0, "uat (set)\n", "")


def test_set_notes_that_an_active_flow_with_another_base_keeps_its_own(tmp_path, seed, capsys):
    state = hold_flow(tmp_path, slug="flowbase", phase="spec", base="uat")
    before = state.read_text()
    git = on_origin(on_origin_head(checkout(tmp_path, orchestrator__base="uat")), "main")

    assert orch(capsys, seed, git, "set", "main") == (
        0, "main (default)\nnote: the active flow flowbase keeps its own base branch: uat\n", "")
    assert state.read_text() == before


def test_set_beside_a_done_flow_gives_no_note(tmp_path, seed, capsys):
    hold_flow(tmp_path, slug="flowbase", phase="done", base="uat")
    git = on_origin(on_origin_head(checkout(tmp_path)), "main")

    assert orch(capsys, seed, git, "set", "main") == (0, "main (default)\n", "")


def test_set_on_a_truncated_state_json_dies_leaving_orchestrator_base_unchanged(tmp_path, seed,
                                                                               capsys):
    state_json(tmp_path).parent.mkdir()
    state_json(tmp_path).write_text('{"slug": "basetrunc", "pha')
    git = on_origin(on_origin_head(checkout(tmp_path, orchestrator__base="keep")), "uat")

    assert orch(capsys, seed, git, "set", "uat") == (1, "", UNREADABLE)
    assert setting(git) == "keep"


# --- set --flow ------------------------------------------------------------------------

NO_FLOW = "orch: no active flow - nothing was set\n"
STAMP = "sentinel"


def flow_at(tmp_path, phase="spec", branch=None, base="main"):
    """state.json of the flow flowbase on issue 7 at <phase>, holding <branch>
    and recorded on <base>, updated stamped STAMP: its path."""
    return hold_flow(tmp_path, slug="flowbase", phase=phase, issue=7, base=base, branch=branch,
                     updated=STAMP)


def state_of(state):
    """The state file <state>'s object."""
    return json.loads(state.read_text())


@pytest.mark.parametrize("args", [("main", "--flow"), ("--flow", "main")],
                         ids=["flag-after", "flag-before"])
def test_set_flow_records_the_flow_s_base_leaving_the_checkout_setting(tmp_path, seed, capsys,
                                                                       args):
    state = flow_at(tmp_path, base="uat")
    git = on_origin(on_origin_head(checkout(tmp_path, orchestrator__base="uat")), "main")

    assert orch(capsys, seed, git, "set", *args) == (0, "main (flow)\n", "")
    recorded = state_of(state)
    assert (recorded["base"], setting(git)) == ("main", "uat")
    assert recorded["updated"] != STAMP


@pytest.mark.parametrize("name", ["null", "007"])
def test_set_flow_stores_the_name_literally(tmp_path, seed, capsys, name):
    state = flow_at(tmp_path)
    git = on_origin(checkout(tmp_path), name)

    assert orch(capsys, seed, git, "set", name, "--flow") == (0, name + " (flow)\n", "")
    assert state_of(state)["base"] == name


def refused(capsys, seed, git, state, name, err, env=None):
    """`base set <name> --flow` refused with <err>, exit 1, the state file
    <state> (None for none) and the checkout setting left as they were."""
    before = state.read_text() if state else None
    assert orch(capsys, seed, git, "set", name, "--flow", env=env) == (1, "", err)
    assert (state.read_text() if state else None, setting(git)) == (before, "<unset>")
    return True


@pytest.mark.parametrize("name", ["uat", "bad..name"])
def test_set_flow_with_no_state_json_is_no_active_flow(tmp_path, seed, capsys, name):
    assert refused(capsys, seed, on_origin(checkout(tmp_path), "uat"), None, name, NO_FLOW)


def test_set_flow_refuses_a_done_flow_as_no_active_flow(tmp_path, seed, capsys):
    state = flow_at(tmp_path, phase="done")
    assert refused(capsys, seed, on_origin(checkout(tmp_path), "uat"), state, "uat", NO_FLOW)


def test_set_flow_on_a_truncated_state_json_dies_unreadable(tmp_path, seed, capsys):
    state = state_json(tmp_path)
    state.parent.mkdir()
    state.write_text('{"slug": "basetrunc", "pha')
    assert refused(capsys, seed, on_origin(checkout(tmp_path), "uat"), state, "uat", UNREADABLE)


BRANCHED = "orch: flow flowbase already has branch orch/7-flowbase - its base can "


@pytest.mark.parametrize("name", ["main", "bad..name"])
def test_set_flow_refuses_once_the_flow_has_a_branch_saying_to_abort(tmp_path, seed, capsys,
                                                                     name):
    state = flow_at(tmp_path, branch="orch/7-flowbase")
    assert refused(capsys, seed, on_origin(checkout(tmp_path), "main"), state, name,
                   BRANCHED + "no longer change; abort to start again on another base\n")


@pytest.mark.parametrize("host, redo", [
    ("claude", "/orchestrator:redo"),
    ("junie", "/orchestrator:redo (or orch-flow's Redo section)")])
def test_set_flow_at_the_review_phase_names_redo_as_the_way_back(tmp_path, seed, capsys, host,
                                                                 redo):
    state = flow_at(tmp_path, phase="review", branch="orch/7-flowbase")
    assert refused(capsys, seed, on_origin(checkout(tmp_path), "main"), state, "main",
                   BRANCHED + "change again once %s retires it\n" % redo,
                   env={"ORCHESTRATOR_HOST": host})


def test_set_flow_refuses_an_invalid_branch_name_before_origin_is_asked(tmp_path, seed, capsys):
    state = flow_at(tmp_path)
    git = checkout(tmp_path)
    git.seed("origin_has_branch", "bad..name", answer=True)
    assert refused(capsys, seed, git, state, "bad..name",
                   "orch: bad..name is not a valid branch name - nothing was set\n")


@pytest.mark.parametrize("answer, err", [(False, MISSING % "nosuch"),
                                         (None, UNREACHABLE % "nosuch")],
                         ids=["missing", "unreachable"])
def test_set_flow_makes_plain_set_s_origin_check(tmp_path, seed, capsys, answer, err):
    state = flow_at(tmp_path)
    git = checkout(tmp_path)
    git.seed("is_branch_name", "nosuch", answer=True)
    git.seed("origin_has_branch", "nosuch", answer=answer)
    assert refused(capsys, seed, git, state, "nosuch", err)


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_failed_state_write_dies_leaving_the_flow_unchanged(tmp_path, seed, capsys):
    state = flow_at(tmp_path)
    git = on_origin(checkout(tmp_path), "uat")
    os.chmod(str(state.parent), 0o555)
    try:
        assert refused(capsys, seed, git, state, "uat",
                       "orch: could not record base in %s - the flow is unchanged\n" % state)
    finally:
        os.chmod(str(state.parent), 0o755)
