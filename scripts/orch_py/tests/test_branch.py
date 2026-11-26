"""The branch concept module: the branch keys the busy checkout's branch
signal reads, through FakeGit's config answers, as bash's branch.sh reads
them from git config, the branch kinds and names, branch retire's arms, on
FakeGit's local branches and seeded origin answers, and the discard rule's
own-branch proof, its discards in a real repository."""
from __future__ import annotations

import pytest

from conftest import committed, died_of, git_repo, run_git
from orch.branch import (branch_is_retired, branch_issue_of, branch_kind, branch_name_ticket,
                         branch_pr_get, branch_pr_set, branch_records_base, branch_retire,
                         discard_own_branch_work, forked_from_branch, forked_from_set)
from orch.git import FakeGit, Git

B = "orch/12-foo"


def configured(**keys):
    """A FakeGit whose git config holds <keys>, each a key of branch B's
    named by its orchestrator- suffix, - for _."""
    git = FakeGit()
    for suffix, value in keys.items():
        git.seed("config_value", "branch.%s.orchestrator-%s" % (B, suffix.replace("_", "-")),
                 answer=value)
    return git


def test_a_branch_s_recorded_pr_is_its_pr():
    assert branch_pr_get(configured(pr="41"), B) == "41"


def test_a_branch_recording_no_pr_has_none():
    assert branch_pr_get(configured(), B) is None


def test_a_branch_s_pr_is_recorded_under_its_key_and_read_back():
    git = FakeGit()

    assert branch_pr_set(git, B, "41") is None
    assert git.config_regexp("local", "orchestrator-pr$") == {
        "branch.%s.orchestrator-pr" % B: "41"}
    assert branch_pr_get(git, B) == "41"


def test_a_pr_that_cannot_be_recorded_on_its_branch_says_so():
    assert branch_pr_set(FakeGit(config_write_fails=["local"]), B, "41") is not None


@pytest.mark.parametrize("value, retired", [("true", True), ("false", False), (None, False)],
                         ids=["true", "false", "unset"])
def test_a_branch_is_retired_only_when_its_retired_key_is_true(value, retired):
    assert branch_is_retired(configured(retired=value), B) is retired


@pytest.mark.parametrize("keys, records", [
    ({"base": "main"}, True),
    ({}, False),
    ({"base": "main", "ticket_parent": "orch/12-foo"}, False),
    ({"ticket_parent": "orch/12-foo"}, False),
], ids=["flow-or-quick", "foreign", "ticket-with-base", "ticket"])
def test_only_a_flow_or_quick_branch_records_a_base(keys, records):
    assert branch_records_base(configured(**keys), B) is records


# --- branch kinds and names ------------------------------------------------------------


@pytest.mark.parametrize("name, keys, kind", [
    (B, {"ticket_parent": "orch/12-foo", "base": "main"}, "ticket"),
    (B, {"base": "main"}, "flow"),
    (B + "-redo-2", {"base": "main"}, "flow"),
    ("orch/x-foo", {"base": "main"}, "quick"),
    ("quick/12-foo", {"base": "main"}, "quick"),
    ("feature", {"base": "main"}, "quick"),
    (B, {}, "foreign"),
], ids=["ticket", "flow", "redo", "orch-not-a-flow-name", "quick", "any-name", "foreign"])
def test_a_branch_s_kind_is_read_from_its_config_and_its_name(name, keys, kind):
    git = FakeGit()
    for suffix, value in keys.items():
        git.seed("config_value", "branch.%s.orchestrator-%s" % (name, suffix.replace("_", "-")),
                 answer=value)

    assert branch_kind(git, name) == kind


@pytest.mark.parametrize("name, issue", [
    ("orch/12-foo", "12"), ("quick/7-bar-baz", "7"), ("orch/12-foo-redo-1", "12"),
    ("orch/12", None), ("orch/12-", None), ("orch/-foo", None), ("orch/1x-foo", None),
    ("quick/", None), ("feature/12-foo", None), ("12-foo", None),
])
def test_a_flow_or_quick_branch_name_gives_its_issue(name, issue):
    assert branch_issue_of(name) == issue


def test_a_ticket_branch_is_named_for_its_forked_from_branch_and_its_ticket():
    assert branch_name_ticket(B, "5") == B + "--t5"


def test_a_ticket_branch_s_forked_from_branch_is_recorded_under_its_key_and_read_back():
    git = FakeGit()

    assert forked_from_set(git, B + "--t5", B) is None
    assert git.config_regexp("local", "orchestrator-ticket-parent$") == {
        "branch.%s--t5.orchestrator-ticket-parent" % B: B}
    assert forked_from_branch(git, B + "--t5") == B


def test_a_forked_from_branch_that_cannot_be_recorded_says_so():
    assert forked_from_set(FakeGit(config_write_fails=["local"]), B + "--t5", B) is not None


# --- the own-branch discard -----------------------------------------------------------

AUTOPILOT = {"ORCH_AUTOPILOT": "1"}
QUICK = "quick/12-foo"


@pytest.fixture
def dirty(tmp_path):
    """A repository on QUICK, recording a base, with a stray untracked file:
    its root, resolved."""
    root = tmp_path.resolve() / "repo"
    git_repo(root)
    committed(root, {"a.txt": "a\n"}, "first")
    run_git(root, "checkout", "-qb", QUICK)
    run_git(root, "config", "branch.%s.orchestrator-base" % QUICK, "main")
    (root / "stray.py").write_text("x\n")
    return root


@pytest.mark.parametrize("recorded, active", [(QUICK, True), (QUICK, False), ("", False)],
                         ids=["the-flow-s-active", "the-flow-s-done", "a-quick-branch"])
def test_the_caller_s_own_branch_is_discarded_on(dirty, recorded, active):
    git = Git(cwd=str(dirty))

    discard_own_branch_work(git, str(dirty), AUTOPILOT, "ticket reclaim", QUICK, recorded, active)

    assert git.status_at(str(dirty)) == ""


def test_with_an_active_flow_another_branch_is_refused_by_the_flow_branch_proof(capsys):
    assert died_of(capsys, lambda: discard_own_branch_work(
        FakeGit(), "/repo", AUTOPILOT, "ticket reclaim", QUICK, B, True)) == (
        1, "", "orch: ticket reclaim: the current branch %s is not the flow's branch %s"
        " - nothing was discarded\n" % (QUICK, B))


def test_with_no_active_flow_a_branch_not_a_quick_one_is_refused(capsys):
    assert died_of(capsys, lambda: discard_own_branch_work(
        configured(base="main"), "/repo", AUTOPILOT, "ticket reclaim", B, "", False)) == (
        1, "", "orch: ticket reclaim: no active flow, and %s is not a quick implementation's"
        " branch - nothing was discarded\n" % B)


# --- branch retire -------------------------------------------------------------------

NEW = B + "-redo-1"
RETIRED_KEY = "branch.%s.orchestrator-retired" % NEW
PUSH = ("origin", "refs/heads/%s:refs/heads/%s" % (NEW, NEW))
DELETE = ("origin", "refs/heads/" + B)
REJECTED = "! [remote rejected] %s (pre-receive hook declined)" % B
RERUN = "rerun orch.sh branch retire %s %s" % (B, NEW)


def retiring(*names, upstream="refs/remotes/origin/" + B, origin=None, push=None,
             delete=None, **fake):
    """A FakeGit holding local branches <names>, B tracking <upstream>, origin
    answering <origin> for B, the tracking push of NEW <push> and the delete
    of B <delete>, each answer seeded only when given."""
    git = FakeGit(branches={name: upstream if name == B else None for name in names}, **fake)
    for op, args, answer in (("origin_has_branch", (B,), origin), ("push_set_upstream", PUSH, push),
                             ("remote_delete", DELETE, delete)):
        if answer is not None:
            git.seed(op, *args, answer=answer)
    return git


def landed(*names, **answers):
    """retiring's FakeGit, its push and its delete both landing."""
    git = retiring(*names, **answers)
    git.seed("push_set_upstream", *PUSH, answer=None)
    git.seed("remote_delete", *DELETE, answer=None)
    return git


def retired(git):
    """The retirement key's local value on <git>, None when unrecorded."""
    return git.config_regexp("local", r"orchestrator-retired$").get(RETIRED_KEY)


def after(git):
    """Which of B and NEW exist locally on <git>, and the retirement record."""
    return git.branch_exists(B), git.branch_exists(NEW), retired(git)


def test_a_fresh_retire_renames_pushes_deletes_and_records_printing_the_new_name(capsys):
    git = landed(B)

    branch_retire(git, B, NEW)

    assert (after(git), capsys.readouterr()) == ((False, True, "true"), (NEW + "\n", ""))


def test_a_local_only_branch_is_renamed_and_recorded_with_no_remote_step(capsys):
    # Neither push is seeded: a remote step tried would die on it.
    git = retiring(B, upstream=None)

    branch_retire(git, B, NEW)

    assert (after(git), capsys.readouterr().out) == ((False, True, "true"), NEW + "\n")


@pytest.mark.parametrize("names, message", [
    ((B, NEW), "branch %s already exists" % NEW),
    ((), "branch %s does not exist" % B),
], ids=["both", "neither"])
def test_a_retire_with_both_or_neither_name_dies_changing_nothing(capsys, names, message):
    git = retiring(*names)

    assert died_of(capsys, lambda: branch_retire(git, B, NEW)) == (1, "", "orch: %s\n" % message)
    assert after(git) == (B in names, NEW in names, None)


def test_a_resumed_retire_whose_old_name_origin_still_has_finishes_its_remote_steps(capsys):
    git = landed(NEW, origin=True)

    branch_retire(git, B, NEW)

    assert (after(git), capsys.readouterr().out) == ((False, True, "true"), NEW + "\n")


def test_a_resumed_retire_whose_old_name_origin_lacks_only_records(capsys):
    git = retiring(NEW, origin=False)

    branch_retire(git, B, NEW)

    assert (after(git), capsys.readouterr().out) == ((False, True, "true"), NEW + "\n")


def test_a_resumed_retire_origin_cannot_answer_for_dies_changing_nothing(capsys):
    git = retiring(NEW)

    assert died_of(capsys, lambda: branch_retire(git, B, NEW)) == (1, "", (
        "orch: could not reach origin to check whether %s is still there - nothing was"
        " changed; %s\n" % (B, RERUN)))
    assert after(git) == (False, True, None)


def test_a_fresh_retire_whose_push_fails_undoes_its_rename_and_dies(capsys):
    git = retiring(B, push=REJECTED)

    assert died_of(capsys, lambda: branch_retire(git, B, NEW)) == (
        1, "", "orch: could not push %s to origin: %s\n" % (NEW, REJECTED))
    assert (after(git), git.branch_upstream(B)) == ((True, False, None), "refs/remotes/origin/" + B)


def test_a_resumed_retire_whose_push_fails_dies_leaving_the_rename_be(capsys):
    git = retiring(NEW, origin=True, push=REJECTED)

    assert died_of(capsys, lambda: branch_retire(git, B, NEW)) == (
        1, "", "orch: could not push %s to origin: %s\n" % (NEW, REJECTED))
    assert after(git) == (False, True, None)


def test_a_failed_delete_of_an_old_name_origin_no_longer_has_carries_on(capsys):
    git = landed(B, origin=False)
    git.seed("remote_delete", *DELETE, answer=REJECTED)

    branch_retire(git, B, NEW)

    assert (after(git), capsys.readouterr().out) == ((False, True, "true"), NEW + "\n")


@pytest.mark.parametrize("origin, message", [
    (True, "could not delete origin/%s: %s" % (B, REJECTED)),
    (None, "could not confirm origin/%s is gone: could not ask origin whether it is still there"
           " after its delete failed (%s); %s is pushed but its retirement is not recorded; %s"
           % (B, REJECTED, NEW, RERUN)),
], ids=["still-there", "not-answered"])
def test_a_failed_delete_origin_still_has_or_cannot_answer_for_dies_unrecorded(
        capsys, origin, message):
    git = landed(B, origin=origin)
    git.seed("remote_delete", *DELETE, answer=REJECTED)

    assert died_of(capsys, lambda: branch_retire(git, B, NEW)) == (1, "", "orch: %s\n" % message)
    assert after(git) == (False, True, None)


def test_a_retirement_record_git_refuses_dies_with_only_its_own_line_naming_key_and_rerun(
        capsys):
    # The fake's blocked write answers git's lock refusal; bash's branch
    # retire silenced it, so only the orch: line reaches stderr.
    git = retiring(B, upstream=None, config_write_fails=[("local", RETIRED_KEY)])

    assert died_of(capsys, lambda: branch_retire(git, B, NEW)) == (1, "", (
        "orch: could not record %s - %s is retired; %s to record it\n" % (RETIRED_KEY, NEW, RERUN)))
    assert after(git) == (False, True, None)


def test_a_rename_git_refuses_ends_the_retire_with_git_s_status_and_stderr(capsys, tmp_path):
    git = git_repo(tmp_path / "repo")
    run_git(tmp_path / "repo", "commit", "-q", "--allow-empty", "-m", "one")
    run_git(tmp_path / "repo", "branch", "-m", B)

    code, out, err = died_of(capsys, lambda: branch_retire(git, B, "bad..name"))

    # Its first line alone: the hints git prints after it vary by version.
    assert (code, out, err.split("\n")[0]) == (
        128, "", "fatal: 'bad..name' is not a valid branch name")
    assert (git.branch_exists(B), retired(git)) == (True, None)
