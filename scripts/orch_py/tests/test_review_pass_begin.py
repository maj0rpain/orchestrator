"""The review-pass noun's begin verb, run in-process against FakeGit and the
gh fake, with the checkout, its state.json, its pass directory and its git
exclude file under tmp_path, each checked by its stdout, its exit code, its
`orch:` message and the files it leaves - as the bash review-pass begin it
replaced answered."""
from __future__ import annotations


import pytest

from orch.git import FakeGit
from conftest import GITHUB_ORIGIN, flow_state, orch_review_pass, state_json, write

BRANCH = "quick/12-foo"
USAGE = "orch: usage: orch.sh review-pass begin <issue>\n"
OFF_CLAUDE_NEXT = "/orchestrator:next (or orch-flow's Next phase section)"
ON_CLAUDE = {"CLAUDECODE": "1"}


@pytest.fixture
def root(tmp_path):
    """The checkout's root, tmp_path/repo, holding a .git directory."""
    path = tmp_path / "repo"
    (path / ".git").mkdir(parents=True)
    return path


def checkout_git(root, branch=BRANCH, base="trunk"):
    """The checkout's git adapter: its toplevel <root>, on <branch> (a
    detached HEAD when None), its common directory <root>/.git, and
    <base> recorded as the branch's base in git config when given."""
    git = FakeGit(GITHUB_ORIGIN, toplevel=str(root))
    git.seed("git_common_dir", answer=str(root / ".git"))
    if branch is not None:
        git.seed("current_branch", answer=branch)
    if base is not None:
        git.seed("config_value", "branch.%s.orchestrator-base" % branch, answer=base)
    return git


def pass_dir(root, branch=BRANCH):
    return root / ".orchestrator" / "review-pass" / branch


def begin(seed, git, *args, env=None):
    return orch_review_pass(seed, git, "begin", *args, env=env)


# --- the refusals before anything is written ---------------------------------


@pytest.mark.parametrize("args", [(), ("12", "13")], ids=["none", "two"])
def test_begin_takes_exactly_one_issue(root, seed, capsys, args):
    assert begin(seed, checkout_git(root), *args) == 1

    assert capsys.readouterr() == ("", USAGE)
    assert not (root / ".orchestrator").exists()


@pytest.mark.parametrize("issue", ["abc", "12x", "../12", "", "-1"])
def test_begin_refuses_an_issue_that_is_not_a_plain_number(root, seed, capsys, issue):
    assert begin(seed, checkout_git(root), issue) == 1

    assert capsys.readouterr() == (
        "", "orch: issue must be a plain issue number, got: %s\n" % issue)


def test_the_plain_number_check_comes_before_the_branch_s(root, seed, capsys):
    assert begin(seed, checkout_git(root, branch=None), "abc") == 1

    assert "plain issue number" in capsys.readouterr().err


@pytest.mark.parametrize("op", ["wipe", ""])
def test_an_op_the_noun_does_not_have_is_refused_naming_the_ones_it_does(root, seed, capsys, op):
    argv = (op,) if op else ()

    assert orch_review_pass(seed, checkout_git(root), *argv) == 1

    assert capsys.readouterr() == (
        "", "orch: unknown review-pass op: %s (want begin|known-items)\n" % (op or "<none>"))


def test_begin_refuses_a_detached_head(root, seed, capsys):
    assert begin(seed, checkout_git(root, branch=None), "12") == 1

    assert capsys.readouterr() == ("", "orch: not on a branch (detached HEAD)\n")
    assert not (root / ".orchestrator").exists()


BASE_REFUSAL = (
    "orch: %s is the base branch - a review pass reviews a branch's change against it;"
    " check out the change's branch\n")


def test_begin_refuses_a_branch_whose_recorded_base_is_itself(root, seed, capsys):
    assert begin(seed, checkout_git(root, base=BRANCH), "12") == 1

    assert capsys.readouterr() == ("", BASE_REFUSAL % BRANCH)
    assert not (root / ".orchestrator").exists()


def test_with_no_recorded_base_the_base_setting_is_the_base(root, seed, capsys):
    git = checkout_git(root, base=None)
    git.seed("config_value", "orchestrator.base", answer=BRANCH)

    assert begin(seed, git, "12") == 1

    assert capsys.readouterr() == ("", BASE_REFUSAL % BRANCH)


def test_a_recorded_base_wins_over_the_base_setting(root, seed, capsys):
    git = checkout_git(root, base="trunk")
    git.seed("config_value", "orchestrator.base", answer=BRANCH)

    assert begin(seed, git, "12") == 0


def test_with_no_base_setting_github_s_default_branch_is_the_base(root, seed, capsys):
    seed.default_branch("develop")
    git = checkout_git(root, branch="develop", base=None)
    git.seed("is_branch_name", "develop", answer=True)

    assert begin(seed, git, "12") == 1

    assert capsys.readouterr() == ("", BASE_REFUSAL % "develop")


def test_with_no_github_answer_origin_head_s_branch_is_the_base(root, seed, capsys):
    git = checkout_git(root, branch="develop", base=None)
    git.seed("origin_head_branch", answer="develop")
    git.seed("is_branch_name", "develop", answer=True)

    assert begin(seed, git, "12") == 1

    assert capsys.readouterr() == ("", BASE_REFUSAL % "develop")


def test_with_nothing_answering_main_is_the_base(root, seed, capsys):
    assert begin(seed, checkout_git(root, branch="main", base=None), "12") == 1

    assert capsys.readouterr() == ("", BASE_REFUSAL % "main")


def test_the_base_branch_refusal_comes_before_the_state_read(root, seed, capsys):
    write(root, ".orchestrator/state.json", raw="{\n")

    assert begin(seed, checkout_git(root, base=BRANCH), "12") == 1

    assert capsys.readouterr().err == BASE_REFUSAL % BRANCH


# --- the flow-holding guard ------------------------------------------------------


def review_loop_refusal(issue, phase, next_cmd):
    return ("orch: the active flow holds issue #%s at phase %s - this change belongs to that"
            " flow's review loop; run %s\n" % (issue, phase, next_cmd))


@pytest.mark.parametrize("env, next_cmd", [({}, OFF_CLAUDE_NEXT), (ON_CLAUDE, "/orchestrator:next")],
                         ids=["off-claude", "on-claude"])
@pytest.mark.parametrize("phase", ["implement", "review"])
def test_an_active_flow_holding_the_issue_refuses_it_naming_the_next_phase_command(
        root, seed, capsys, phase, env, next_cmd):
    flow_state(root, phase, 12, "orch/12-x")
    before = state_json(root).read_bytes()

    assert begin(seed, checkout_git(root), "12", env=env) == 1

    assert capsys.readouterr() == ("", review_loop_refusal(12, phase, next_cmd))
    assert state_json(root).read_bytes() == before
    assert not pass_dir(root).exists()


def test_an_active_flow_holding_the_branch_under_another_issue_names_its_own_issue(
        root, seed, capsys):
    flow_state(root, "review", 30, BRANCH)

    assert begin(seed, checkout_git(root), "12") == 1

    assert capsys.readouterr() == ("", review_loop_refusal(30, "review", OFF_CLAUDE_NEXT))


@pytest.mark.parametrize("env, next_cmd", [({}, OFF_CLAUDE_NEXT), (ON_CLAUDE, "/orchestrator:next")],
                         ids=["off-claude", "on-claude"])
def test_a_flow_at_spec_holding_the_issue_refuses_it_as_not_yet_built(
        root, seed, capsys, env, next_cmd):
    flow_state(root, "spec", 12, None)
    before = state_json(root).read_bytes()

    assert begin(seed, checkout_git(root), "12", env=env) == 1

    assert capsys.readouterr() == (
        "", "orch: the active flow holds issue #12 at phase spec - its change has not been"
            " built yet; run %s\n" % next_cmd)
    assert state_json(root).read_bytes() == before


def test_a_phase_that_is_no_flow_phase_refuses_it_pointing_at_doctor(root, seed, capsys):
    flow_state(root, "bogus", 12, None)

    assert begin(seed, checkout_git(root), "12", env=ON_CLAUDE) == 1

    assert capsys.readouterr() == (
        "", "orch: the active flow holds issue #12 at phase 'bogus', which is not a flow phase"
            " - refusing to review it; run orch.sh doctor --flow\n")


def test_a_done_flow_holding_the_issue_and_branch_holds_nothing(root, seed, capsys):
    flow_state(root, "done", 12, BRANCH)
    before = state_json(root).read_bytes()

    assert begin(seed, checkout_git(root), "12") == 0

    assert capsys.readouterr() == ("%s/iteration-01\n" % pass_dir(root), "")
    assert state_json(root).read_bytes() == before


def test_an_active_flow_on_another_issue_and_branch_lets_it_through(root, seed, capsys):
    flow_state(root, "implement", 14, "orch/14-x")
    before = state_json(root).read_bytes()

    assert begin(seed, checkout_git(root), "12") == 0

    assert capsys.readouterr() == ("%s/iteration-01\n" % pass_dir(root), "")
    assert state_json(root).read_bytes() == before


def test_an_unreadable_state_file_refuses_it(root, seed, capsys):
    write(root, ".orchestrator/state.json", raw="{\n")

    assert begin(seed, checkout_git(root), "12") == 1

    assert capsys.readouterr() == (
        "", "orch: state.json cannot be read - run orch.sh doctor --flow\n")
    assert not pass_dir(root).exists()


def test_with_no_state_file_begin_works_and_writes_none(root, seed, capsys):
    assert begin(seed, checkout_git(root), "12") == 0

    assert capsys.readouterr() == ("%s/iteration-01\n" % pass_dir(root), "")
    assert not state_json(root).exists()


# --- the writes ----------------------------------------------------------------


def exclude_of(root):
    return root / ".git" / "info" / "exclude"


def test_begin_excludes_the_plugin_s_directories(root, seed, capsys):
    assert begin(seed, checkout_git(root), "12") == 0

    assert exclude_of(root).read_text() == ".orchestrator/\n.scratch/\n"


def test_a_hold_refusal_writes_no_exclude_line(root, seed, capsys):
    flow_state(root, "review", 12, BRANCH)

    assert begin(seed, checkout_git(root), "12") == 1

    assert not exclude_of(root).exists()


def test_a_failed_exclude_write_exits_1_with_nothing_on_stdout(root, seed, capsys):
    exclude_of(root).mkdir(parents=True)

    assert begin(seed, checkout_git(root), "12") == 1

    assert capsys.readouterr() == (
        "", "orch: cannot add .orchestrator/, .scratch/ to the git exclude file %s\n"
            % exclude_of(root))
    assert not pass_dir(root).exists()


def test_a_pass_directory_that_cannot_be_made_exits_1_with_nothing_on_stdout(root, seed, capsys):
    (root / ".orchestrator").mkdir()
    (root / ".orchestrator" / "review-pass").write_text("in the way\n")

    assert begin(seed, checkout_git(root), "12") == 1

    assert capsys.readouterr() == (
        "", "orch: cannot make the review pass directory %s\n" % pass_dir(root))


# --- the numbered prefix ---------------------------------------------------------


def reports(root, *names, branch=BRANCH):
    """Writes each named report in the branch's pass directory."""
    pass_dir(root, branch).mkdir(parents=True, exist_ok=True)
    for name in names:
        (pass_dir(root, branch) / name).write_text("x\n")


def prefix(seed, root, capsys, branch=BRANCH):
    """The prefix a begin on <branch> prints, the run's stderr asserted
    empty."""
    assert begin(seed, checkout_git(root, branch=branch), "12") == 0
    out, err = capsys.readouterr()
    assert err == ""
    return out


def test_a_first_pass_is_iteration_01_in_the_branch_s_nested_directory(root, seed, capsys):
    assert prefix(seed, root, capsys) == "%s/iteration-01\n" % pass_dir(root)
    assert pass_dir(root).is_dir()


def test_a_next_pass_takes_the_next_number_leaving_the_earlier_report(root, seed, capsys):
    reports(root, "iteration-01-spec.md")

    assert prefix(seed, root, capsys) == "%s/iteration-02\n" % pass_dir(root)
    assert (pass_dir(root) / "iteration-01-spec.md").read_text() == "x\n"


def test_the_number_is_one_past_the_highest_over_a_gap_skipping_stray_names(root, seed, capsys):
    reports(root, "iteration-01-spec.md", "iteration-03-standards.md", "iteration-09.md",
            "notes-11-x.md", "iteration-1x-notes.md", "iteration-7")

    assert prefix(seed, root, capsys) == "%s/iteration-04\n" % pass_dir(root)


def test_leading_zeros_are_read_as_decimal(root, seed, capsys):
    reports(root, "iteration-08-spec.md", "iteration-09-spec.md")

    assert prefix(seed, root, capsys) == "%s/iteration-10\n" % pass_dir(root)


def test_the_numbering_rises_past_99(root, seed, capsys):
    reports(root, "iteration-99-spec.md", "iteration-100-spec.md")

    assert prefix(seed, root, capsys) == "%s/iteration-101\n" % pass_dir(root)
