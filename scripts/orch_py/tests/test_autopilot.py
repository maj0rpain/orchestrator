"""The autopilot noun's core, run in-process through autopilot.run in a
FakeGit checkout under tmp_path, its git config the FakeGit's, against the
gh fake on a tmp_path store: the verb dispatch, each verb's usage refusal
and the unknown-op refusal; the settings verbs (`settings`, `show`) with
their defaults, sources and refusals, the model and effort among them
checked by the agent module in process; `active`; the plan reads (`rounds`,
`budget`); `start`; and `candidates`. Ported from the bash autopilot
sections that held them - autopilot, autopilot rounds, budget and start, and
autopilot candidates - each case run in a plain and an autopilot
(ORCH_AUTOPILOT=1) session."""
from __future__ import annotations

import subprocess
import tempfile

import pytest

from conftest import (CLAUDE, GH_502, SESSIONS, comments_of, died_of, flow_state, labels_doc,
                      labels_of, snapshot, write_labels_doc)
from orch import autopilot
from orch.gh_fake import FakeGh
from orch.git import FakeGit
from orch.handoff import PHASE_TABLE
from orch.repo import RepoPin

ORIGIN = "https://github.com/o/r.git"
VERBS = ("show|settings|active|rounds|budget|start|candidates|tick|watch|run|ask|answer|reenter"
         "|questions|reply|resume|sync|sync-finish|sync-dropped|sync-fail")


def checkout(root, local=None, global_=None, origin=ORIGIN):
    """A FakeGit checkout at <root>, origin <origin> (none when None), its
    local and global git config <local> and <global_>."""
    remotes = {} if origin is None else {"origin": origin}
    return FakeGit(remotes, toplevel=str(root), local_config=local, global_config=global_)


def ap(seed, git, env, *argv):
    """`orch.sh autopilot <argv>` in-process in the checkout of <git>, under
    <env>, on the gh fake on <seed>'s store pinned to <git>'s origin: its exit
    code, a SystemExit's included."""
    gh = FakeGh(seed.store, env, pin=RepoPin(env, git), sleep=lambda _: None)
    try:
        return autopilot.run(list(argv), gh=gh, git=git, env=env)
    except SystemExit as died:
        return died.code


# --- dispatch -------------------------------------------------------------------


@SESSIONS
@pytest.mark.parametrize("op", ["bogus", ""])
def test_an_unknown_op_is_refused_listing_every_verb(root, seed, capsys, env, op):
    code = ap(seed, checkout(root), env, *([op] if op else []))

    assert (code, capsys.readouterr()) == (
        1, ("", "orch: unknown autopilot op: %s (want %s)\n" % (op or "<none>", VERBS)))


# Each verb's arguments refused, with the usage line bash dies with.
USAGES = [
    (["settings", "x"], "usage: orch.sh autopilot settings"),
    (["show", "x"], "usage: orch.sh autopilot show"),
    (["active", "x"], "usage: orch.sh autopilot active"),
    (["rounds", "x"], "usage: orch.sh autopilot rounds"),
    (["budget", "x"], "usage: orch.sh autopilot budget"),
    (["start", "7"], "usage: orch.sh autopilot start <issue> <plan-file>"),
    (["start", "7", "p", "x"], "usage: orch.sh autopilot start <issue> <plan-file>"),
    (["candidates"], "usage: orch.sh autopilot candidates [<n>... | --all | --limit <k>]"),
    (["tick", "x"], "usage: orch.sh autopilot tick"),
    (["watch", "x"], "usage: orch.sh autopilot watch [--every <seconds>]"),
    (["watch", ""], "usage: orch.sh autopilot watch [--every <seconds>]"),
    (["watch", "--every"], "usage: orch.sh autopilot watch [--every <seconds>]"),
    (["watch", "--every", "5", "x"], "usage: orch.sh autopilot watch [--every <seconds>]"),
    (["watch", "--every", "0"], "--every must be a positive whole number of seconds, got: 0"),
    (["watch", "--every", "1.5"], "--every must be a positive whole number of seconds, got: 1.5"),
    (["run"], "usage: orch.sh autopilot run <issue>"),
    (["run", "7", "x"], "usage: orch.sh autopilot run <issue>"),
    (["questions", "x"], "usage: orch.sh autopilot questions"),
    (["reply", "7"], "usage: orch.sh autopilot reply <issue> <file>"),
    (["resume"], "usage: orch.sh autopilot resume <issue>"),
    (["sync"], "usage: orch.sh autopilot sync <issue>"),
    (["sync-finish", "x"], "usage: orch.sh autopilot sync-finish"),
    (["sync-dropped"], "usage: orch.sh autopilot sync-dropped <file>"),
    (["sync-fail"], "usage: orch.sh autopilot sync-fail <reason>"),
    (["sync-fail", "a", "b"], "usage: orch.sh autopilot sync-fail <reason>"),
    (["reenter", "review"], "usage: orch.sh autopilot reenter <phase> <file>"),
    (["ask", "spec"], "usage: orch.sh autopilot ask <phase> <file>"),
    (["answer", "spec", "f", "x"], "usage: orch.sh autopilot answer <phase> <file>"),
]


@SESSIONS
@pytest.mark.parametrize("argv,usage", USAGES, ids=[" ".join(a) for a, _ in USAGES])
def test_each_verb_refuses_arguments_it_does_not_take_with_its_usage_line(
        root, seed, store, capsys, env, argv, usage):
    before = snapshot(store)

    assert (ap(seed, checkout(root), env, *argv), capsys.readouterr()) == (
        1, ("", "orch: %s\n" % usage))
    assert snapshot(store) == before


def test_outside_a_checkout_every_op_dies_as_orch_sh_does(seed, capsys):
    code, out, err = died_of(capsys, lambda: autopilot.run(
        ["settings"], git=FakeGit(), env=CLAUDE))

    assert (code, out) == (1, "")
    assert err.startswith("orch: not inside a git repository (")


# --- settings, show and active ----------------------------------------------------

# The setting names, in the order show prints them.
SETTING_NAMES = ["permission-mode", "cap", "handle", "rounds", "budget", "model", "effort",
                 "auto-sync", "github-reserve"]


def test_the_setting_names_are_held_in_show_order():
    assert list(autopilot.AUTOPILOT_SETTING_NAMES) == SETTING_NAMES


@SESSIONS
def test_settings_prints_the_setting_names_in_order_with_nothing_set(root, seed, capsys, env):
    assert (ap(seed, checkout(root), env, "settings"), capsys.readouterr()) == (
        0, ("".join(name + "\n" for name in SETTING_NAMES), ""))


def key(name):
    return "orchestrator.autopilot." + name


def shown(name, value, source):
    return "orchestrator.autopilot.%s %s (%s)\n" % (name, value, source)


@SESSIONS
def test_show_prints_every_setting_s_default_with_nothing_set(root, seed, capsys, env):
    assert (ap(seed, checkout(root), env, "show"), capsys.readouterr()) == (0, ("".join([
        shown("permission-mode", "(none)", "unset"),
        shown("cap", "3", "default"),
        shown("handle", "o", "default"),
        shown("rounds", "2", "default"),
        shown("budget", "3", "default"),
        shown("model", "(none)", "unset"),
        shown("effort", "(none)", "unset"),
        shown("auto-sync", "true", "default"),
        shown("github-reserve", "20", "default"),
    ]), ""))


@SESSIONS
def test_show_prints_set_values_with_their_source_the_integers_plain(root, seed, capsys, env):
    local = {key("permission-mode"): "acceptEdits", key("cap"): "05", key("handle"): "octo",
             key("rounds"): "4", key("budget"): "7", key("model"): "opus",
             key("auto-sync"): "false", key("github-reserve"): "099"}
    global_ = {key("effort"): "inherit", key("cap"): "9", key("rounds"): "8"}

    assert (ap(seed, checkout(root, local, global_), env, "show"), capsys.readouterr()) == (
        0, ("".join([
            shown("permission-mode", "acceptEdits", "local"),
            shown("cap", "5", "local"),
            shown("handle", "octo", "local"),
            shown("rounds", "4", "local"),
            shown("budget", "7", "local"),
            shown("model", "opus", "local"),
            shown("effort", "inherit", "global"),
            shown("auto-sync", "false", "local"),
            shown("github-reserve", "99", "local"),
        ]), ""))


@pytest.mark.parametrize("env,origin,owner", [
    (dict(CLAUDE, GH_REPO="acme/widgets"), ORIGIN, "acme"),
    (CLAUDE, "git@ghe.example.com:corp/widgets.git", "corp"),
], ids=["GH_REPO", "host-qualified origin"])
def test_the_handle_defaults_to_the_owner_of_the_repo_the_pin_resolves(
        root, seed, capsys, env, origin, owner):
    ap(seed, checkout(root, origin=origin), env, "show")

    assert shown("handle", owner, "default") in capsys.readouterr().out


@SESSIONS
def test_with_no_repo_an_unset_handle_dies_with_the_remedy_and_its_own_fix(
        root, seed, capsys, env):
    assert (ap(seed, checkout(root, origin=None), env, "show"), capsys.readouterr().err) == (
        1, "orch: no GitHub repo to work on: origin is missing or not a GitHub owner/name - set"
           " GH_REPO=<owner>/<repo> (the handle defaults to the repo's owner; or git config"
           " orchestrator.autopilot.handle <handle>)\n")


@SESSIONS
def test_with_no_repo_a_set_handle_resolves_nothing(root, seed, capsys, env):
    git = checkout(root, {key("handle"): "octo"}, origin=None)

    assert ap(seed, git, env, "show") == 0
    assert shown("handle", "octo", "local") in capsys.readouterr().out


@SESSIONS
@pytest.mark.parametrize("mode", ["default", "acceptEdits", "plan", "dontAsk", "bypassPermissions"])
def test_every_permission_mode_is_accepted(root, seed, capsys, env, mode):
    assert ap(seed, checkout(root, {key("permission-mode"): mode}), env, "show") == 0
    assert shown("permission-mode", mode, "local") in capsys.readouterr().out


MODES = "default|acceptEdits|plan|dontAsk|bypassPermissions"
REFUSED = [
    ("permission-mode", "yolo", "not a permission mode (want %s)" % MODES),
    ("permission-mode", "Plan", "not a permission mode (want %s)" % MODES),
    ("cap", "0", "it must be a positive integer (git config orchestrator.autopilot.cap <n>)"),
    ("cap", "-1", "it must be a positive integer (git config orchestrator.autopilot.cap <n>)"),
    ("cap", "many", "it must be a positive integer (git config orchestrator.autopilot.cap <n>)"),
    ("rounds", "0", "it must be a positive integer (git config orchestrator.autopilot.rounds <n>)"),
    ("rounds", "1x", "it must be a positive integer (git config orchestrator.autopilot.rounds <n>)"),
    ("budget", "0", "it must be a positive integer (git config orchestrator.autopilot.budget <n>)"),
    ("budget", "two", "it must be a positive integer (git config orchestrator.autopilot.budget <n>)"),
    ("auto-sync", "yes", "it must be true or false"
                         " (git config orchestrator.autopilot.auto-sync true|false)"),
    ("github-reserve", "100", "it must be an integer from 0 to 99"
                              " (git config orchestrator.autopilot.github-reserve <n>)"),
    ("github-reserve", "", "it must be an integer from 0 to 99"
                           " (git config orchestrator.autopilot.github-reserve <n>)"),
    ("model", "gpt", "not an allowed model (want sonnet|opus|haiku|fable|inherit)"),
    ("model", "Opus", "not an allowed model (want sonnet|opus|haiku|fable|inherit)"),
    ("effort", "extreme", "not an allowed effort (want low|medium|high|xhigh|max|inherit)"),
]


@SESSIONS
@pytest.mark.parametrize("name,value,why", REFUSED, ids=["%s=%s" % r[:2] for r in REFUSED])
def test_show_dies_on_a_value_out_of_range_naming_the_key_and_the_value(
        root, seed, capsys, env, name, value, why):
    git = checkout(root, {key("permission-mode"): "plan", key(name): value})

    code, out, err = died_of(capsys, lambda: autopilot.run(
        ["show"], gh=FakeGh(seed.store, env), git=git, env=env))

    assert (code, err) == (1, "orch: orchestrator.autopilot.%s is %s - %s\n" % (name, value, why))
    assert [line.split(" ")[0] for line in out.splitlines()] == [
        key(before) for before in SETTING_NAMES[:SETTING_NAMES.index(name)]]


@SESSIONS
@pytest.mark.parametrize("name,value,want", [
    ("model", "gpt", "not an allowed model (want sonnet|opus|haiku|fable|inherit)"),
    ("effort", "High", "not an allowed effort (want low|medium|high|xhigh|max|inherit)"),
])
def test_a_refused_model_or_effort_dies_in_process_starting_no_child(
        root, seed, capsys, monkeypatch, env, name, value, want):
    def no_child(*args, **kwargs):
        raise AssertionError("a child process was started: %r" % (args,))

    monkeypatch.setattr(subprocess, "Popen", no_child)
    git = checkout(root, {key(name): value})

    assert (ap(seed, git, env, "show"), capsys.readouterr().err) == (
        1, "orch: orchestrator.autopilot.%s is %s - %s\n" % (name, value, want))


@pytest.mark.parametrize("env,code", [
    ({"ORCH_AUTOPILOT": "1"}, 0),
    ({}, 1),
    ({"ORCH_AUTOPILOT": "0"}, 1),
], ids=["ORCH_AUTOPILOT=1", "unset", "ORCH_AUTOPILOT=0"])
def test_active_exits_0_in_an_autopilot_session_alone_printing_nothing(
        root, seed, capsys, env, code):
    assert (ap(seed, checkout(root), env, "active"), capsys.readouterr()) == (code, ("", ""))


# --- rounds and budget ---------------------------------------------------------


def plan_text(block=None):
    """A complete plan handoff, every required section a placeholder - Host
    fallbacks among them, which a checkout with no flow state requires - with
    the `## Autopilot` block's body <block> when one is given."""
    sections = next(row[3] for row in PHASE_TABLE if row[1] == "01-plan.md") + ("Host fallbacks",)
    text = "".join("## %s\nPlaceholder for %s.\n\n" % (s, s) for s in sections)
    return text if block is None else text + "## Autopilot\n\n%s\n" % block


def plan_comment(seed, n, block):
    """Issue #n's next comment: a plan comment whose block's body is
    <block>."""
    seed.comment(n, "alice", "2026-01-01T00:00:00Z",
                 "<!-- orch:handoff 01-plan -->\n" + plan_text(block), "OWNER")


@pytest.fixture
def planned(root, seed):
    """A flow on issue #7, which is open and ready."""
    flow_state(root, "spec", 7)
    seed.issue(7, "open", "ready-for-agent")


@SESSIONS
def test_rounds_and_budget_print_the_newest_plan_comment_s_values(
        root, seed, capsys, env, planned):
    plan_comment(seed, 7, "Rounds: 4\nBudget: 5")
    plan_comment(seed, 7, "Rounds: 06\nBudget:  5  ")
    git = checkout(root)

    assert (ap(seed, git, env, "rounds"), capsys.readouterr()) == (0, ("6\n", ""))
    assert (ap(seed, git, env, "budget"), capsys.readouterr()) == (0, ("5\n", ""))


@SESSIONS
def test_rounds_with_no_plan_comment_dies_naming_it(root, seed, capsys, env, planned):
    assert (ap(seed, checkout(root), env, "rounds"), capsys.readouterr()) == (
        1, ("", "orch: issue #7 has no 01-plan handoff comment\n"))


@SESSIONS
@pytest.mark.parametrize("block", [
    "Budget: 5", "Rounds: 0\nBudget: 5", "Rounds: two\nBudget: 5", "Rounds: 3\nRounds: 4\nBudget: 5"],
    ids=["no line", "zero", "not a number", "repeated"])
def test_rounds_dies_on_a_block_with_no_valid_rounds_line(
        root, seed, capsys, env, planned, block):
    plan_comment(seed, 7, block)

    assert (ap(seed, checkout(root), env, "rounds"), capsys.readouterr()) == (
        1, ("", "orch: issue #7's plan comment has no valid ## Autopilot Rounds line\n"))


@SESSIONS
def test_budget_dies_on_a_plan_comment_with_no_block(root, seed, capsys, env, planned):
    plan_comment(seed, 7, None)

    assert (ap(seed, checkout(root), env, "budget"), capsys.readouterr()) == (
        1, ("", "orch: issue #7's plan comment has no valid ## Autopilot Budget line\n"))


@SESSIONS
def test_a_failed_comments_read_dies_with_gh_s_reason(root, seed, capsys, env, planned):
    seed.fail("adapter_issue_comments", GH_502)

    assert (ap(seed, checkout(root), env, "budget"), capsys.readouterr()) == (
        1, ("", "orch: gh could not read the comments of issue #7: HTTP 502: Bad Gateway\n"))


@SESSIONS
def test_rounds_with_no_issue_recorded_dies_before_any_read(root, seed, store, capsys, env):
    flow_state(root, "spec", None)

    assert (ap(seed, checkout(root), env, "rounds"), capsys.readouterr()) == (
        1, ("", "orch: no issue recorded in state - the spec phase must publish one first\n"))
    assert read_count(store) == 0


def read_count(store):
    """How many times the store's comments were read."""
    reads = store / "comment_reads"
    return len(reads.read_text().splitlines()) if reads.exists() else 0


# --- start -------------------------------------------------------------------------

PLAN_MARKER = "<!-- orch:handoff 01-plan -->\n"


@pytest.fixture
def plan(tmp_path):
    """A valid plan file holding an `## Autopilot` block: its path."""
    path = tmp_path / "01-plan.md"
    path.write_text(plan_text("Rounds: 4\nBudget: 5"))
    return path


@SESSIONS
def test_start_posts_the_plan_comment_then_adds_the_first_phase_label(
        root, seed, store, capsys, env, plan):
    seed.issue(7, "open", "ready-for-agent")

    assert (ap(seed, checkout(root), env, "start", "7", str(plan)), capsys.readouterr()) == (
        0, ("posted the plan comment on issue #7: https://github.com/o/r/issues/7#issuecomment-1\n"
            "added orch:spec to issue #7\n", ""))
    assert comments_of(store, 7) == [PLAN_MARKER + plan.read_text()]
    assert labels_of(store, 7) == ["ready-for-agent", "orch:spec"]


@SESSIONS
def test_start_with_no_url_from_gh_ends_its_first_line_at_the_issue(
        root, seed, store, capsys, env, plan):
    seed.issue(13, "open", "ready-for-agent")
    (store / "no_comment_url").write_text("")

    assert (ap(seed, checkout(root), env, "start", "13", str(plan)), capsys.readouterr()) == (
        0, ("posted the plan comment on issue #13\nadded orch:spec to issue #13\n", ""))


@SESSIONS
@pytest.mark.parametrize("issue,labels,message", [
    ("8", (), "issue #8 does not carry the 'ready-for-agent' label - an autopilot flow starts"
              " from a ready issue"),
    ("9", ("ready-for-agent", "orch:review"),
     "issue #9 already carries the phase label orch:review - it is already an autopilot flow"),
], ids=["not ready", "already started"])
def test_start_refuses_an_issue_that_is_not_ready_or_already_started_writing_nothing(
        root, seed, store, capsys, env, plan, issue, labels, message):
    seed.issue(int(issue), "open", *labels)
    before = snapshot(store)

    assert (ap(seed, checkout(root), env, "start", issue, str(plan)), capsys.readouterr()) == (
        1, ("", "orch: %s\n" % message))
    assert snapshot(store) == before


@SESSIONS
def test_start_names_the_ready_label_in_the_repo_s_own_words(root, seed, capsys, env, plan):
    write_labels_doc(root, labels_doc(("ready-for-agent", "agent-ok")))
    seed.issue(7, "open", "agent-ok")

    assert ap(seed, checkout(root), env, "start", "7", str(plan)) == 0
    assert capsys.readouterr().out.endswith("added orch:spec to issue #7\n")


@SESSIONS
def test_start_on_a_failed_issue_read_dies_in_one_line_with_gh_s_reason(
        root, seed, capsys, env, plan):
    seed.issue(9, "open", "ready-for-agent")
    seed.fail("adapter_issue_state_labels", GH_502)

    assert (ap(seed, checkout(root), env, "start", "9", str(plan)), capsys.readouterr()) == (
        1, ("", "orch: gh could not read issue #9: HTTP 502: Bad Gateway\n"))


@SESSIONS
def test_start_refuses_a_plan_with_no_autopilot_block_posting_nothing(
        root, seed, store, capsys, env, tmp_path):
    seed.issue(9, "open", "ready-for-agent")
    bad = tmp_path / "bad.md"
    bad.write_text(plan_text())
    before = snapshot(store)

    assert (ap(seed, checkout(root), env, "start", "9", str(bad)), capsys.readouterr()) == (
        1, ("", "FAIL  missing section: ## Autopilot\n"
                "orch: plan %s is not valid - nothing posted\n" % bad))
    assert snapshot(store) == before


@SESSIONS
@pytest.mark.parametrize("issue,message", [
    ("7x", "issue must be a plain issue number, got: 7x"),
    ("", "issue must be a plain issue number, got: "),
], ids=["not a number", "empty"])
def test_start_refuses_an_issue_that_is_not_a_plain_number(
        root, seed, capsys, env, plan, issue, message):
    assert (ap(seed, checkout(root), env, "start", issue, str(plan)), capsys.readouterr()) == (
        1, ("", "orch: %s\n" % message))


@SESSIONS
def test_start_refuses_a_missing_plan_file(root, seed, capsys, env, tmp_path):
    seed.issue(7, "open", "ready-for-agent")
    missing = tmp_path / "nope.md"

    assert (ap(seed, checkout(root), env, "start", "7", str(missing)), capsys.readouterr()) == (
        1, ("", "orch: plan file not found: %s\n" % missing))


@SESSIONS
def test_a_failed_plan_post_dies_with_the_reason_adding_no_label_and_leaving_no_temp_file(
        root, seed, store, capsys, monkeypatch, env, plan, tmp_path):
    seed.issue(7, "open", "ready-for-agent")
    seed.fail("adapter_issue_comment_url", "HTTP 502 post")
    temp = tmp_path / "tmp"
    temp.mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(temp))

    assert (ap(seed, checkout(root), env, "start", "7", str(plan)), capsys.readouterr()) == (
        1, ("", "orch: gh could not post the 01-plan handoff on issue #7: HTTP 502 post\n"))
    assert labels_of(store, 7) == ["ready-for-agent"]
    assert list(temp.iterdir()) == []


@SESSIONS
def test_a_failed_label_add_dies_naming_the_comment_posted_and_a_re_run_labels_it(
        root, seed, store, capsys, env, plan):
    seed.issue(7, "open", "ready-for-agent")
    seed.fail("adapter_issue_relabel", "HTTP 502")
    git = checkout(root)

    assert (ap(seed, git, env, "start", "7", str(plan)), capsys.readouterr()) == (
        1, ("", "orch: posted the 01-plan comment on issue #7 but adding orch:spec failed:"
                " HTTP 502 - the issue is unlabelled, so no watcher picks it up; re-run"
                " autopilot start\n"))
    assert labels_of(store, 7) == ["ready-for-agent"]
    assert comments_of(store, 7) == [PLAN_MARKER + plan.read_text()]

    seed.unfail()
    plan.write_text(plan_text("Rounds: 6\nBudget: 5"))

    assert (ap(seed, git, env, "start", "7", str(plan)), capsys.readouterr()) == (
        0, ("posted the plan comment on issue #7: https://github.com/o/r/issues/7#issuecomment-2\n"
            "added orch:spec to issue #7\n", ""))
    assert len(comments_of(store, 7)) == 2
    assert labels_of(store, 7) == ["ready-for-agent", "orch:spec"]
    flow_state(root, "spec", 7)
    assert (ap(seed, git, env, "rounds"), capsys.readouterr()) == (0, ("6\n", ""))


# --- candidates ------------------------------------------------------------------


class CountingGh(FakeGh):
    """The gh fake, counting its open-issue listings and its per-issue
    state-and-labels reads."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.listings = 0
        self.issue_reads = 0

    def issues_open_rows(self):
        self.listings += 1
        return super().issues_open_rows()

    def issue_state_labels(self, n):
        self.issue_reads += 1
        return super().issue_state_labels(n)


def candidates(seed, root, env, *args, gh=None):
    """`autopilot candidates <args>` on the gh adapter <gh> (the gh fake on
    <seed>'s store when None): its exit code."""
    git = checkout(root)
    gh = FakeGh(seed.store, env, pin=RepoPin(env, git), sleep=lambda _: None) if gh is None else gh
    try:
        return autopilot.run(["candidates"] + list(args), gh=gh, git=git, env=env)
    except SystemExit as died:
        return died.code


@pytest.fixture
def pool(seed):
    """Fourteen issues, one per verdict: #7 a ticket of #1, #12 written by a
    stranger, #11 closed."""
    seed.issue(1, "open", "ready-for-agent")
    seed.issue(2, "open", "needs-triage")
    seed.issue(3, "open", "ready-for-human")
    seed.issue(4, "open", "ready-for-agent", "orch:review")
    seed.issue(5, "open", "wontfix")
    seed.issue(6, "open", "needs-info")
    seed.issue(7, "open", "ready-for-agent")
    seed.sub_issue(1, 7)
    seed.issue(8, "open", "review:high", "needs-triage")
    seed.issue(9, "open", "review:high")
    seed.issue(10, "open", "review:high", "ready-for-human")
    seed.issue(11, "closed", "ready-for-agent")
    seed.issue(12, "open", "ready-for-agent")
    seed.authorship(12, "stranger", "NONE")
    seed.issue(13, "open", "wontfix", "orch:spec")
    seed.issue(14, "open")
    seed.comment(2, "alice", "2026-01-01T00:00:00Z", "a comment")


@SESSIONS
def test_named_issues_get_their_verdicts_in_the_order_named_writing_nothing(
        root, seed, store, capsys, env, pool):
    before = snapshot(store)

    assert (candidates(seed, root, env, "3", "99", "1", "14", "11", "012", "13"),
            capsys.readouterr()) == (0, (
                "3 eligible override\n"
                "99 skip missing\n"
                "1 eligible none\n"
                "14 eligible move\n"
                "11 skip closed\n"
                "12 skip untrusted stranger\n"
                "13 skip phase spec\n", ""))
    assert snapshot(store) == before


@SESSIONS
def test_all_walks_the_open_issues_oldest_first_in_one_listing(
        root, seed, store, capsys, env, pool):
    gh = CountingGh(seed.store, dict(env, ORCH_ISSUE_LIST_LIMIT="14"), sleep=lambda _: None)
    before = snapshot(store)

    assert candidates(seed, root, env, "--all", gh=gh) == 0
    out, err = capsys.readouterr()
    assert [line.split(" ")[0] for line in out.splitlines()] == [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "12", "13", "14"]
    assert err == ""
    assert (gh.listings, gh.issue_reads) == (1, 0)
    assert snapshot(store) == before


@SESSIONS
def test_limit_keeps_the_first_k_eligible_lines_skips_not_counted(
        root, seed, capsys, env, pool):
    gh = CountingGh(seed.store, env, sleep=lambda _: None)

    assert (candidates(seed, root, env, "--limit", "4", gh=gh), capsys.readouterr()) == (0, (
        "1 eligible none\n"
        "2 eligible move\n"
        "3 eligible override\n"
        "4 skip phase review\n"
        "5 skip wontfix\n"
        "6 skip needs-info\n"
        "7 skip ticket #1\n"
        "8 skip untriaged-finding\n"
        "9 skip untriaged-finding\n"
        "10 eligible override\n", ""))
    assert (gh.listings, gh.issue_reads) == (1, 0)


@SESSIONS
def test_named_issues_each_keep_one_direct_read(root, seed, capsys, env, pool):
    gh = CountingGh(seed.store, env, sleep=lambda _: None)

    assert candidates(seed, root, env, "1", "99", gh=gh) == 0
    assert (gh.listings, gh.issue_reads) == (0, 2)


@SESSIONS
def test_past_the_issue_list_limit_the_newest_are_dropped_with_a_warning(
        root, seed, capsys, env, pool):
    gh = FakeGh(seed.store, dict(env, ORCH_ISSUE_LIST_LIMIT="12"), sleep=lambda _: None)

    assert candidates(seed, root, env, "--all", gh=gh) == 0
    out, err = capsys.readouterr()
    assert [line.split(" ")[0] for line in out.splitlines()] == [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "12", "13"]
    assert err == ("orch: the open issues reached the issue-list limit of 12 - the newest past"
                   " it are missing from this list\n")


@SESSIONS
@pytest.mark.parametrize("args,message", [
    ([], "usage: orch.sh autopilot candidates [<n>... | --all | --limit <k>]"),
    (["--all", "1"], "usage: orch.sh autopilot candidates [<n>... | --all | --limit <k>]"),
    (["1", "--all"], "usage: orch.sh autopilot candidates [<n>... | --all | --limit <k>]"),
    (["--limit", "2", "--all"], "usage: orch.sh autopilot candidates [<n>... | --all | --limit <k>]"),
    (["--all", "--limit", "2"], "usage: orch.sh autopilot candidates [<n>... | --all | --limit <k>]"),
    (["--limit"], "usage: orch.sh autopilot candidates [<n>... | --all | --limit <k>]"),
    (["--limit", "1", "5"], "usage: orch.sh autopilot candidates [<n>... | --all | --limit <k>]"),
    (["abc"], "usage: orch.sh autopilot candidates [<n>... | --all | --limit <k>]"),
    (["--limit", "0"], "--limit must be a positive whole number, got: 0"),
    (["--limit", "x"], "--limit must be a positive whole number, got: x"),
], ids=lambda value: " ".join(value) if isinstance(value, list) else None)
def test_a_usage_error_is_refused_reading_nothing(root, seed, store, capsys, env, pool,
                                                  args, message):
    gh = CountingGh(seed.store, env, sleep=lambda _: None)

    assert (candidates(seed, root, env, *args, gh=gh), capsys.readouterr()) == (
        1, ("", "orch: %s\n" % message))
    assert (gh.listings, gh.issue_reads) == (0, 0)


@SESSIONS
@pytest.mark.parametrize("operation,args,message", [
    ("adapter_issue_state_labels", ["1", "2"], "could not read issue #1: HTTP 502: Bad Gateway"),
    ("adapter_issue_authorship", ["1"],
     "could not check the trust of issue #1: HTTP 502: Bad Gateway"),
    ("adapter_issues_open_rows", ["--all"], "gh could not list the open issues: HTTP 502: Bad Gateway"),
    ("adapter_issue_parent", ["5", "2"], "gh could not read issue #2's parent: HTTP 502: Bad Gateway"),
], ids=["issue read", "trust read", "listing", "parent read after an earlier verdict"])
def test_a_failed_read_dies_printing_no_partial_list(root, seed, capsys, env, pool,
                                                      operation, args, message):
    seed.fail(operation, GH_502)

    assert (candidates(seed, root, env, *args), capsys.readouterr()) == (
        1, ("", "orch: %s\n" % message))


@SESSIONS
def test_the_triage_roles_are_read_in_the_repo_s_own_labels(root, seed, capsys, env):
    write_labels_doc(root, labels_doc(("ready-for-agent", "agent-ok"), ("wontfix", "nope")))
    seed.issue(1, "open", "agent-ok")
    seed.issue(2, "open", "nope")
    seed.issue(3, "open", "review:high", "agent-ok")

    assert (candidates(seed, root, env, "1", "2", "3"), capsys.readouterr()) == (0, (
        "1 eligible none\n2 skip wontfix\n3 eligible none\n", ""))
