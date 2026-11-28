"""`orch.sh autopilot run <issue>`, the session wrapper a tick starts, run
in-process through autopilot.run in a FakeGit main checkout under tmp_path
holding issue #7's side checkout, against the gh fake on a tmp_path store,
with a fake process starter standing in for the headless session the
ORCH_AUTOPILOT_LAUNCHER names and for the post-session `verification stop`
child. Each case asserts what the run leaves behind: the session it started,
the labels, comments and claim on the store, the pause files, the run record
and the session log. Ported from the bash sections that held run: autopilot
tick and run, autopilot session end, the budget and the final reply, a
start-up read that meets a GitHub limit, the session log's GitHub usage
line, the sync request's session, and the Session log module's reads."""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

import pytest

from conftest import (SideCheckouts, comments_of, hold_flow, iso, labels_of, marker_of,
                      orch_autopilot, snapshot)
from orch import autopilot
from orch.git import FakeGit
from test_autopilot import ORIGIN, plan_comment

LAUNCHER = "fake-claude"
NOW = int(time.time())
R1, R2, R3 = NOW + 3600, NOW + 7200, NOW + 90000
HEADLESS_PROMPT = (
    "You are a headless orchestrator autopilot session: no human reads this conversation, and"
    " no tool asks one. Never end your turn on a question. Where a skill offers an autopilot"
    " branch (`orch.sh autopilot active` exits 0, which it does in this session), take that"
    " branch. Where a decision truly needs the human, post it with `orch.sh autopilot ask"
    " <phase> <file>` and stop. When an `orch:` message says the GitHub API rate limit was"
    " reached, end your turn at once: do not retry or wait, the watcher picks the work up after"
    " the reset.")
HUMAN = ["needs-human", "orch:spec", "ready-for-agent"]
LIMITED = ["orch:limited", "orch:spec", "ready-for-agent"]
RUNNING = ["orch:running", "orch:spec", "ready-for-agent"]
API_LIMIT = "API rate limit exceeded for user ID 1."


def epoch_of(text):
    import calendar
    return calendar.timegm(time.strptime(text.strip(), "%Y-%m-%dT%H:%M:%SZ"))


def rl_event(five_status, five_use, five_reset, seven_status, seven_use, seven_reset):
    """A rate_limit_event line: the seven-day window at the top level and
    both windows under unifiedWindows, a reset of None written as null."""
    windows = {"five_hour": {"utilization": five_use, "resetsAt": five_reset,
                             "status": five_status},
               "seven_day": {"utilization": seven_use, "resetsAt": seven_reset,
                             "status": seven_status}}
    return json.dumps({"type": "rate_limit_event", "rate_limit_info": {
        "status": seven_status, "resetsAt": seven_reset, "rateLimitType": "seven_day",
        "utilization": seven_use, "unifiedWindows": windows}})


def ndjson_with(line):
    """A session log of NDJSON lines with <line> as a plain text line among
    them, and a rate_limit_event that rejects nothing."""
    return "\n".join(['{"type":"system","subtype":"init"}',
                      rl_event("allowed", 0.1, 4102444800, "allowed", 0.1, 4102444800), line,
                      '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
                      ]) + "\n"


def result_log(text):
    """A log ending in a result event whose text is <text>."""
    return '{"type":"system","subtype":"init"}\n' + json.dumps(
        {"type": "result", "subtype": "success", "result": text}) + "\n"


class Started:
    """A child the fake starter ran to its end: wait() gives its exit."""

    def __init__(self, code):
        self.code = code

    def wait(self):
        return self.code


class Starter:
    """The fake process starter. A session - argv[0] the launcher - writes
    <out> to its log, runs <effect> (given the env it was started with),
    releases the claims of <release>, and exits <exit>. The `verification
    stop` child writes <stop_err> to its stderr and exits <stop_exit>.
    Every start is kept in <calls>: (argv, cwd, env)."""

    def __init__(self, store):
        self.store = store
        self.calls = []
        self.out = ""
        self.exit = 0
        self.release = []
        self.effect = None
        self.stop_exit = 0
        self.stop_err = ""

    def __call__(self, argv, cwd=None, env=None, stdin=None, stdout=None, stderr=None):
        self.calls.append((list(argv), cwd, dict(env or {})))
        if argv[0] == LAUNCHER:
            stdout.write(self.out.encode())
            stdout.flush()
            if self.effect:
                self.effect(env)
            for n in self.release:
                os.remove(os.path.join(self.store, "claims", str(n)))
            return Started(self.exit)
        stderr.write(self.stop_err.encode())
        stderr.flush()
        return Started(self.stop_exit)

    def sessions(self):
        return [call for call in self.calls if call[0][0] == LAUNCHER]

    def stops(self):
        return [call for call in self.calls if call[0][0] != LAUNCHER]


class Wrapper:
    """Issue #7 running its spec phase in its side checkout end-7 under the
    main checkout tmp_path: the issue open at orch:spec, ready-for-agent and
    orch:running, its claim held, the permission mode acceptEdits."""

    def __init__(self, tmp_path, store, seed):
        self.main = str(tmp_path)
        self.store = str(store)
        self.seed = seed
        self.config = {"orchestrator.autopilot.permission-mode": "acceptEdits"}
        self.git = FakeGit({"origin": ORIGIN}, toplevel=self.main, local_config=self.config)
        self.git.seed("main_checkout", answer=self.main)
        self.side = SideCheckouts(tmp_path, self.git).add("end-7", "orch/7-end")
        self.state(phase="spec")
        seed.issue(7, "open", "ready-for-agent", "orch:spec", "orch:running")
        seed.claim(7)
        self.env = {"ORCHESTRATOR_HOST": "claude", "ORCH_AUTOPILOT_LAUNCHER": LAUNCHER,
                    "ORCH_GH_LIMIT_WAIT": "0"}
        self.starter = Starter(self.store)
        self.clock = lambda: NOW

    def state(self, **state):
        hold_flow(Path(self.side), slug="end-7", issue=7, **state)

    def path(self, *parts):
        return os.path.join(self.main, ".orchestrator", "autopilot", *parts)

    def run(self, *argv, git=None):
        """`orch.sh autopilot run <argv>` (7 when none): its exit code."""
        return orch_autopilot(self.seed, self.git if git is None else git, self.env, "run",
                              *(argv or ("7",)), clock=self.clock, starter=self.starter)

    def logs(self):
        folder = self.path("logs")
        return sorted(os.listdir(folder)) if os.path.isdir(folder) else []

    def log(self):
        """The text of the newest session log."""
        with open(self.path("logs", self.logs()[-1])) as f:
            return f.read()

    def log_path(self):
        return self.path("logs", self.logs()[-1])

    def limit(self):
        """The usage limit file's text, None when there is none."""
        return file_text(self.path("limit"))

    def github_limit(self):
        return file_text(self.path("github-limit"))

    def labels(self):
        return sorted(labels_of(self.store, 7))

    def last_comment(self):
        comments = comments_of(self.store, 7)
        return comments[-1] if comments else ""


def file_text(path):
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        return f.read()


@pytest.fixture
def w(tmp_path, store, seed):
    return Wrapper(tmp_path, store, seed)


# --- the session ----------------------------------------------------------------


def test_the_session_runs_the_launcher_in_the_side_checkout_with_the_lean_flags(w):
    w.env["CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"] = "600000"
    w.starter.release = [7]

    assert w.run() == 0
    [(argv, cwd, env)] = w.starter.sessions()
    assert argv == [
        LAUNCHER, "-p", "Run the orchestrator:orch-flow skill's Next phase in this checkout: do"
        " the phase it names, and stop when the phase is finished.",
        "--permission-mode", "acceptEdits",
        "--tools", "Agent,Skill,Bash,Read,Edit,Write,Grep,Glob,SendMessage",
        "--settings", '{"disableBundledSkills":true,"enabledPlugins":{"plugin-authoring@builtin"'
        ':false}}',
        "--strict-mcp-config", "--exclude-dynamic-system-prompt-sections",
        "--append-system-prompt", HEADLESS_PROMPT, "--output-format", "stream-json", "--verbose"]
    assert cwd == w.side
    assert (env["ORCH_AUTOPILOT"], env["CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS"],
            env["CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"], env["ORCH_AUTOPILOT_HIT_FILE"]) == (
        "1", "1", "7200000", w.path("run", "7.hit"))


def test_a_session_that_released_its_claim_leaves_the_issue_one_log_and_no_run_record(w):
    w.starter.release = [7]

    assert w.run() == 0
    assert w.labels() == RUNNING
    assert w.seed.claim_held(7) is False
    assert not os.path.exists(w.path("run", "7.pid"))
    assert w.logs() == ["7-spec-%s.log" % time.strftime("%Y%m%d-%H%M%S", time.gmtime(NOW))]


@pytest.mark.parametrize("model,effort,flags", [
    ("opus", "inherit", ["--model", "opus"]),
    ("opus", "high", ["--model", "opus", "--effort", "high"]),
    ("inherit", "low", ["--effort", "low"]),
])
def test_a_set_model_and_effort_reach_the_launch_and_inherit_passes_neither(
        w, model, effort, flags):
    w.config.update({"orchestrator.autopilot.model": model,
                     "orchestrator.autopilot.effort": effort})
    w.git = FakeGit({"origin": ORIGIN}, toplevel=w.main, local_config=w.config)
    w.git.seed("main_checkout", answer=w.main)
    w.side = SideCheckouts(Path(w.main), w.git).add("end-8", "orch/7-end8")
    w.state(phase="spec")

    w.run()

    argv = w.starter.sessions()[0][0]
    assert argv[argv.index("acceptEdits") + 1:argv.index("--tools")] == flags


def test_a_session_that_exits_with_its_claim_held_is_a_failure_stop(w):
    w.starter.out = "session output line\n"
    w.starter.exit = 3

    assert w.run() == 0
    assert w.labels() == HUMAN
    assert w.seed.claim_held(7) is False
    assert "session output line" in w.log()
    assert ("Autopilot failed in the spec phase: the session exited with code 3; log: %s\n"
            % w.log_path()) in w.last_comment()
    assert w.limit() is None


def test_a_session_killed_by_a_signal_reports_128_plus_the_signal_as_the_shell_does(w):
    w.starter.exit = -9

    assert w.run() == 0
    assert ("Autopilot failed in the spec phase: the session exited with code 137; log: %s\n"
            % w.log_path()) in w.last_comment()


def test_a_released_claim_and_a_non_zero_exit_is_no_failure_noted_in_the_log(w, capsys):
    w.starter.release = [7]
    w.starter.exit = 3

    assert w.run() == 0
    assert w.labels() == RUNNING
    assert comments_of(w.store, 7) == []
    note = "autopilot run: issue #7's session exited 3 with its claim released"
    assert note in w.log()
    assert capsys.readouterr().out == note + "\n"


def test_the_session_s_verification_runs_are_stopped_by_a_child_orch_sh_in_the_side_checkout(
        w):
    w.starter.exit = 3

    w.run()

    [(argv, cwd, _)] = w.starter.stops()
    assert argv == [autopilot.orch_sh(), "verification", "stop", w.side]
    assert cwd == w.side
    assert os.path.isfile(autopilot.orch_sh())


def test_a_failed_post_session_stop_is_a_log_line_and_changes_nothing_else(w, tmp_path):
    w.starter.exit = 3
    w.starter.stop_err = "orch: the group survived KILL\n"
    w.starter.stop_exit = 1

    assert w.run() == 0
    assert ("orch: the group survived KILL\n"
            "autopilot run: could not stop every verification run of %s\n" % w.side) in w.log()
    assert w.labels() == HUMAN
    assert w.seed.claim_held(7) is False


def test_a_sync_request_runs_the_sync_prompt_under_the_sync_phase_word(w):
    w.state(phase="done")
    w.seed.issue(7, "open", "orch:done", "orch:sync", "orch:running")
    w.starter.release = [7]

    w.run()

    assert "orch-sync skill's autopilot branch" in w.starter.sessions()[0][0][2]
    assert w.logs()[0].startswith("7-sync-")


# --- refusals and liveness failures -----------------------------------------------


@pytest.mark.parametrize("issue", ["", "7a", "-1", "#7"])
def test_an_issue_that_is_not_a_plain_number_is_refused(w, capsys, issue):
    assert w.run(issue) == 1
    assert capsys.readouterr().err == "orch: issue must be a plain issue number, got: %s\n" % issue
    assert w.starter.calls == []


def test_no_side_checkout_recording_the_issue_dies(w, capsys):
    assert w.run("8") == 1
    assert capsys.readouterr().err == "orch: no side checkout records issue #8\n"


def test_no_permission_mode_dies_naming_the_key(w, capsys):
    del w.config["orchestrator.autopilot.permission-mode"]
    git = FakeGit({"origin": ORIGIN}, toplevel=w.main, local_config=w.config)

    assert w.run(git=git) == 1
    assert capsys.readouterr().err == (
        "orch: orchestrator.autopilot.permission-mode is not set - choose how headless sessions"
        " run (git config orchestrator.autopilot.permission-mode"
        " <default|acceptEdits|plan|dontAsk|bypassPermissions>)\n")


def test_a_run_record_that_cannot_be_written_ends_run_with_exit_1_before_any_session(
        w, tmp_path, capsys):
    proc = tmp_path / "proc"
    (proc / str(os.getpid())).mkdir(parents=True)
    w.env["ORCH_PROC_DIR"] = str(proc)

    assert w.run() == 1
    assert capsys.readouterr().err == "orch: could not read the start time of pid %d\n" % os.getpid()
    assert w.starter.calls == []
    assert w.seed.claim_held(7) is True


def test_a_logs_directory_that_cannot_be_made_dies_before_any_session_the_record_removed(
        w, capsys):
    os.makedirs(w.path())
    with open(w.path("logs"), "w") as f:
        f.write("a file\n")

    assert w.run() == 1
    assert capsys.readouterr().err == "orch: could not create %s\n" % w.path("logs")
    assert w.starter.calls == []
    assert not os.path.exists(w.path("run", "7.pid"))
    assert w.seed.claim_held(7) is True
    assert w.labels() == RUNNING


def test_an_unreadable_recorded_phase_dies_naming_the_side_checkout(w, capsys):
    with open(os.path.join(w.side, ".orchestrator", "state.json"), "w") as f:
        f.write("{broken\n")

    assert w.run() == 1
    assert capsys.readouterr().err == (
        "orch: could not read the recorded phase of %s - state.json cannot be read\n" % w.side)


# --- the start-up read ------------------------------------------------------------


def test_a_start_up_read_that_meets_a_github_limit_only_releases_the_claim(w):
    w.seed.fail_times("adapter_issue_state_labels", 1, API_LIMIT)

    assert w.run() == 0
    assert w.labels() == ["orch:spec", "ready-for-agent"]
    assert w.seed.claim_held(7) is False
    assert comments_of(w.store, 7) == []
    assert w.starter.calls == []
    assert w.github_limit() is not None
    assert not os.path.exists(w.path("run", "7.pid"))


def test_a_github_limited_start_up_with_an_unreadable_claim_list_still_releases(w):
    w.seed.fail_times("adapter_issue_state_labels", 1, API_LIMIT)
    w.seed.fail("adapter_claim_list", "HTTP 500 list")

    w.run()

    assert w.seed.claim_held(7) is False


def test_a_start_up_read_that_fails_for_another_reason_dies_the_claim_held(w, capsys):
    w.seed.fail_times("adapter_issue_state_labels", 1, "HTTP 500")

    assert w.run() == 1
    assert capsys.readouterr().err == "orch: gh could not read issue #7: HTTP 500\n"
    assert w.seed.claim_held(7) is True
    assert not os.path.exists(w.path("run", "7.pid"))


def test_a_start_up_release_that_fails_every_attempt_writes_a_backstop_in_the_claim_s_log(w):
    w.seed.claim(7, phase="sync")
    w.seed.fail_times("adapter_issue_state_labels", 1, API_LIMIT)
    w.seed.fail("adapter_issue_relabel", "HTTP 500 relabel")

    assert w.run() == 0
    assert w.seed.claim_held(7) is True
    assert w.logs()[0].startswith("7-sync-")
    assert w.log().splitlines()[-1] == (
        "autopilot run: the stop chain failed after 3 attempts - claim release: could not release"
        " the claim; no session ran: the start-up read met a GitHub limit")


# --- the review budget ------------------------------------------------------------


@pytest.fixture
def budgeted(w):
    """A plan comment of Budget 6 on issue #7."""
    plan_comment(w.seed, 7, "Rounds: 2\nBudget: 6")
    return w


def budget_of(w):
    with open(os.path.join(w.side, ".orchestrator", "state.json")) as f:
        return json.load(f).get("budget")


@pytest.mark.parametrize("phase,iteration,before,after", [
    ("review", 0, None, 6),
    ("review", 0, 4, 6),
    ("review", 2, 4, 4),
    ("implement", 0, None, None),
])
def test_a_first_loop_review_run_records_the_plan_s_budget_and_starts_its_session(
        budgeted, phase, iteration, before, after):
    w = budgeted
    w.state(phase=phase, iteration=iteration, budget=before)
    w.seed.labels(7, "ready-for-agent", "orch:" + phase, "orch:running")

    w.run()

    assert budget_of(w) == after
    assert len(w.starter.sessions()) == 1


def test_an_unreadable_plan_budget_stops_the_issue_with_the_reader_s_own_cause(budgeted):
    w = budgeted
    w.seed.comment(7, "alice", "2026-01-01T00:00:01Z",
                   "<!-- orch:handoff 01-plan -->\n## Autopilot\n\nRounds: 2\nBudget: lots\n",
                   "OWNER")
    w.state(phase="review", iteration=0, budget=4)

    assert w.run() == 0
    assert w.starter.calls == []
    assert w.labels() == HUMAN
    assert ("could not record the plan's Budget as the review budget: orch: issue #7's plan"
            " comment has no valid ## Autopilot Budget line") in w.last_comment()
    assert w.seed.claim_held(7) is False
    assert budget_of(w) == 4


def test_a_budget_read_that_meets_a_github_limit_only_releases_the_claim(budgeted):
    w = budgeted
    w.state(phase="review", iteration=0, budget=4)
    before = comments_of(w.store, 7)
    w.seed.fail_times("adapter_issue_comments", 2, API_LIMIT)

    assert w.run() == 0
    assert w.seed.claim_held(7) is False
    assert comments_of(w.store, 7) == before
    assert "needs-human" not in w.labels()
    assert w.starter.calls == []
    assert w.github_limit() is not None


def test_a_budget_limit_whose_release_fails_every_attempt_writes_a_backstop(budgeted):
    w = budgeted
    w.state(phase="review", iteration=0, budget=4)
    w.seed.fail_times("adapter_issue_comments", 2, API_LIMIT)
    w.seed.fail("adapter_issue_relabel", "HTTP 500 relabel")

    assert w.run() == 0
    assert w.seed.claim_held(7) is True
    assert w.log().splitlines()[-1].endswith(
        "claim release: could not release the claim; no session ran: the first-loop review's"
        " budget record met a GitHub limit")


def test_an_unreadable_budget_whose_stop_fails_every_attempt_writes_a_backstop(budgeted):
    w = budgeted
    w.seed.comment(7, "alice", "2026-01-01T00:00:01Z",
                   "<!-- orch:handoff 01-plan -->\n## Autopilot\n\nRounds: 2\nBudget: lots\n",
                   "OWNER")
    w.state(phase="review", iteration=0, budget=4)
    w.seed.fail("adapter_issue_relabel", "HTTP 500 relabel")

    assert w.run() == 0
    assert w.seed.claim_held(7) is True
    last = w.log().splitlines()[-1]
    assert "could not record the plan's Budget as the review budget" in last
    assert last.endswith("; no session ran")


def test_an_unreadable_budget_whose_stop_write_fails_once_still_stops(budgeted):
    w = budgeted
    w.seed.comment(7, "alice", "2026-01-01T00:00:01Z",
                   "<!-- orch:handoff 01-plan -->\n## Autopilot\n\nRounds: 2\nBudget: lots\n",
                   "OWNER")
    w.state(phase="review", iteration=0, budget=4)
    w.seed.fail_times("adapter_issue_comment", 1, "HTTP 500 comment")

    w.run()

    assert "could not record the plan's Budget" in w.last_comment()
    assert "needs-human" in w.labels()
    assert w.seed.claim_held(7) is False


def test_the_final_reply_of_an_exit_0_session_is_quoted_collapsed_and_cut(w):
    w.starter.out = result_log("x" * 300 + "\n\n  " + "y" * 300)

    w.run()

    assert ("the session exited with code 0; it ended on: *%s %s…*; log: "
            % ("x" * 300, "y" * 199)) in w.last_comment()


# --- the GitHub usage line --------------------------------------------------------


def usage_after(w):
    """The session spends 10 core and 50 graphql calls."""
    def effect(env):
        os.remove(os.path.join(w.store, "quota"))
        w.seed.quota("core", 4990, 5000, 9999999999)
        w.seed.quota("graphql", 4900, 5000, 9999999999)
    return effect


def test_the_session_log_says_how_much_core_and_graphql_usage_changed(w):
    w.seed.quota("core", 5000, 5000, 9999999999)
    w.seed.quota("graphql", 4950, 5000, 9999999999)
    w.starter.release = [7]
    w.starter.effect = usage_after(w)

    w.run()

    assert "autopilot run: GitHub API usage this session: core 10, graphql 50\n" in w.log()


def test_a_failed_rate_limit_read_at_the_start_writes_no_usage_line(w):
    w.seed.fail("adapter_rate_limit", "HTTP 502")
    w.starter.release = [7]

    def effect(env):
        w.seed.unfail()
        usage_after(w)(env)

    w.seed.quota("core", 5000, 5000, 9999999999)
    w.starter.effect = effect

    w.run()

    assert "GitHub API usage" not in w.log()


def test_an_empty_rate_limit_read_writes_no_usage_line(w):
    with open(os.path.join(w.store, "quota"), "w"):
        pass
    w.starter.release = [7]

    w.run()

    assert "GitHub API usage" not in w.log()


def test_a_failed_rate_limit_read_at_the_end_writes_no_usage_line(w):
    w.seed.quota("core", 5000, 5000, 9999999999)
    w.seed.quota("graphql", 4950, 5000, 9999999999)
    w.starter.release = [7]
    w.starter.effect = lambda env: w.seed.fail("adapter_rate_limit", "HTTP 502")

    w.run()

    assert "GitHub API usage" not in w.log()


# --- the session end: what the log says ---------------------------------------------


def ended(w, log, code=1):
    """A run whose held session writes <log> and exits <code>: run's exit
    code."""
    w.starter.out = log
    w.starter.exit = code
    return w.run()


def kind(w):
    """What the issue was left with: limited, failure or released."""
    labels = w.labels()
    if labels == LIMITED:
        return "limited"
    if labels == HUMAN:
        return "failure"
    return "released"


def test_usage_limit_reached_with_an_epoch_is_a_limit_stop_at_that_reset(w):
    ended(w, ndjson_with("Claude AI usage limit reached|%d" % R2))

    assert (kind(w), w.limit()) == ("limited", iso(R2) + "\n")
    assert "which resets %s" % iso(R2) in w.last_comment()


@pytest.mark.parametrize("wording", ["Claude Opus usage limit reached", "5-hour limit reached",
                                     "Weekly limit reached"])
def test_a_limit_message_with_no_reset_falls_back_to_a_one_hour_pause(w, wording):
    ended(w, ndjson_with(wording))

    assert kind(w) == "limited"
    assert w.limit() == iso(NOW + 3600) + "\n"
    assert ("it gave no reset time, so the watcher falls back to a one-hour limit pause, until %s."
            % iso(NOW + 3600)) in w.last_comment()
    assert "resets" not in w.last_comment()


@pytest.mark.parametrize("wording", ["iteration limit reached", "API rate limit reached, retrying"])
def test_other_limit_wordings_are_a_failure_with_no_limit_file(w, wording):
    ended(w, ndjson_with(wording))

    assert (kind(w), w.limit()) == ("failure", None)
    assert ("Autopilot failed in the spec phase: the session exited with code 1; log: %s\n"
            % w.log_path()) in w.last_comment()


@pytest.mark.parametrize("reply,quoted", [
    ("How many review iterations? 3, 5 or 8", "How many review iterations? 3, 5 or 8"),
    ("x" * 500, "x" * 500),
    ("x" * 500 + "y", "x" * 500 + "…"),
    ("one\n\n  two\tthree", "one two three"),
])
def test_an_exit_0_session_s_final_reply_is_quoted(w, reply, quoted):
    ended(w, result_log(reply), 0)

    assert ("the session exited with code 0; it ended on: *%s*; log: %s"
            % (quoted, w.log_path())) in w.last_comment()


def test_an_empty_final_reply_keeps_the_plain_failure_comment(w):
    ended(w, result_log(""), 0)

    assert "it ended on" not in w.last_comment()
    assert "the session exited with code 0; log: %s" % w.log_path() in w.last_comment()


def test_resets_3pm_is_a_limit_stop_at_15_00_local_within_the_next_day(w):
    ended(w, ndjson_with("5-hour limit reached ∙ resets 3pm"))

    reset = epoch_of(w.limit())
    assert kind(w) == "limited"
    assert time.localtime(reset).tm_hour == 15
    assert NOW < reset <= NOW + 86400 + 3600
    assert "which resets %s" % w.limit().strip() in w.last_comment()


def test_resets_mon_9am_is_a_monday_at_09_00_local_within_the_next_week(w):
    ended(w, ndjson_with("Weekly limit reached ∙ resets Mon 9am"))

    reset = epoch_of(w.limit())
    assert kind(w) == "limited"
    assert (time.localtime(reset).tm_wday, time.localtime(reset).tm_hour) == (0, 9)
    assert NOW < reset <= NOW + 7 * 86400 + 3600


def test_limit_wording_only_in_assistant_text_or_tool_results_is_a_failure(w):
    ended(w, '{"type":"assistant","message":{"content":[{"type":"text","text":"Claude AI usage'
             ' limit reached"}]}}\n{"type":"user","message":{"content":[{"type":"tool_result",'
             '"content":"Weekly limit reached"}]}}\n')

    assert (kind(w), w.limit()) == ("failure", None)


def test_a_limit_message_in_the_last_result_event_is_a_limit_stop(w):
    ended(w, '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}\n'
             + json.dumps({"type": "result", "is_error": True,
                           "result": "Claude AI usage limit reached|%d" % R2}) + "\n")

    assert (kind(w), w.limit()) == ("limited", iso(R2) + "\n")


def test_a_plain_text_line_is_read_with_the_result_text(w):
    ended(w, '{"type":"result","result":"all done"}\nplain Claude AI usage limit reached|%d\n' % R2)

    assert (kind(w), w.limit()) == ("limited", iso(R2) + "\n")


def test_a_result_text_is_read_after_the_plain_lines_so_its_resets_time_wins(w):
    ended(w, '{"type":"result","result":"5-hour limit reached \\u2219 resets 3pm"}\n'
             'Claude AI usage limit reached|%d\n' % R1)

    reset = epoch_of(w.limit())
    assert reset != R1
    assert time.localtime(reset).tm_hour == 15


@pytest.mark.parametrize("log,outcome,limit", [
    ("stderr noise line\n" + rl_event("rejected", 1, R1, "allowed_warning", 0.8, R3)
     + "\nanother note\n", "limited", R1),
    (rl_event("rejected", 1, R1, "rejected", 0.8, R3) + "\n", "limited", R3),
    (rl_event("rejected", 1, R1, "allowed", 0.8, R3) + "\n"
     + rl_event("allowed", 0.5, R1, "allowed", 0.8, R3) + "\n", "failure", None),
    (rl_event("allowed", 0.9, R1, "allowed", 0.2, R3) + "\n", "failure", R1),
    ('{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":%d,'
     '"rateLimitType":"five_hour","utilization":0.95}}\n' % R1, "failure", R1),
    (rl_event("allowed", 0.89, R1, "allowed", 0.2, R3) + "\n", "failure", None),
    (rl_event("allowed", 0.5, R1, "allowed_warning", 0.97, R3) + "\n", "failure", None),
    (rl_event("allowed", 0.95, R3, "allowed", 0.2, R3) + "\nClaude AI usage limit reached|%d\n"
     % R1, "limited", R3),
    (rl_event("allowed", 0.95, R1, "allowed", 0.2, R3) + "\nClaude AI usage limit reached|%d\n"
     % R3, "limited", R3),
], ids=["rejecting-five-hour", "latest-rejecting", "rejecting-then-allowed", "early-0.9",
        "early-top-level", "early-0.89", "seven-day-high", "early-later", "limit-later"])
def test_the_rate_limit_events_decide_the_stop_and_the_limit_file(w, log, outcome, limit):
    ended(w, log)

    assert (kind(w), w.limit()) == (outcome, iso(limit) + "\n" if limit else None)


def test_a_rejecting_event_names_its_reset_in_the_comment_while_an_early_pause_is_later(w):
    ended(w, rl_event("allowed", 0.95, R3, "allowed", 0.2, R3)
           + "\nClaude AI usage limit reached|%d\n" % R1)

    assert "which resets %s" % iso(R1) in w.last_comment()


def test_a_rejecting_event_with_no_resets_at_falls_back_to_the_hour(w):
    ended(w, rl_event("rejected", 1, None, "allowed", 0.2, None) + "\n"
           + "Claude AI usage limit reached|%d\n" % R2)

    assert (kind(w), w.limit()) == ("limited", iso(NOW + 3600) + "\n")


def test_no_reset_with_a_later_early_pause_keeps_the_hour_fallback_in_the_comment(w):
    far = NOW + 14400
    ended(w, rl_event("allowed", 0.9, far, "allowed", 0.2, far)
           + "\nClaude AI usage limit reached\n")

    assert "falls back to a one-hour limit pause, until %s" % iso(NOW + 3600) in w.last_comment()
    assert iso(far) not in w.last_comment()
    assert w.limit() == iso(far) + "\n"


@pytest.mark.parametrize("recorded,kept", [(iso(R2), iso(R2)), (iso(NOW - 100), iso(R1)),
                                           ("garbage", iso(R1))],
                         ids=["later-kept", "earlier-replaced", "unreadable-replaced"])
def test_the_pause_store_keeps_a_later_time_and_replaces_an_earlier_or_unreadable_one(
        w, recorded, kept):
    os.makedirs(w.path())
    with open(w.path("limit"), "w") as f:
        f.write(recorded + "\n")

    ended(w, ndjson_with("Claude AI usage limit reached|%d" % R1))

    assert w.limit() == kept + "\n"


def test_a_failed_limit_file_write_is_noted_once_and_changes_no_outcome(w, capsys):
    os.makedirs(w.path("limit"))

    code = ended(w, rl_event("allowed", 0.95, R1, "rejected", 1, R3) + "\n")

    err = capsys.readouterr().err
    note = "autopilot run: could not write the limit file %s" % w.path("limit")
    assert code == 0
    assert err.count(note) == 1
    assert note in w.log()
    assert kind(w) == "limited"
    assert w.seed.claim_held(7) is False


def test_a_failed_early_pause_write_is_noted_and_the_failure_stop_stands(w, capsys):
    os.makedirs(w.path("limit"))

    ended(w, rl_event("allowed", 0.95, R1, "allowed", 0.2, R3) + "\n", 3)

    assert "could not write the limit file" in capsys.readouterr().err
    assert kind(w) == "failure"


# --- the session end: the held rule -------------------------------------------------


def test_a_claim_the_session_released_is_no_stop_and_writes_no_limit_file(w, capsys):
    w.starter.release = [7]

    ended(w, ndjson_with("Claude AI usage limit reached|%d" % R2))

    assert (kind(w), w.limit(), comments_of(w.store, 7)) == ("released", None, [])
    assert "autopilot run: issue #7's session exited 1 with its claim released" in w.log()


def test_the_next_phase_s_claim_taken_by_the_session_is_released(w):
    w.starter.effect = lambda env: w.seed.claim(7, started="2026-02-02T00:00:00Z", phase="plan")

    ended(w, ndjson_with("Claude AI usage limit reached|%d" % R2))

    assert (kind(w), w.limit(), w.seed.claim_held(7)) == ("released", None, True)


def test_no_claim_before_the_session_but_one_after_is_held(w):
    os.remove(os.path.join(w.store, "claims", "7"))
    w.starter.effect = lambda env: w.seed.claim(7)

    ended(w, ndjson_with("Claude AI usage limit reached|%d" % R2))

    assert kind(w) == "limited"


def test_released_over_a_rejecting_log_writes_only_the_early_pause(w):
    w.starter.release = [7]

    ended(w, rl_event("rejected", 0.95, R1, "allowed", 0.2, R3) + "\n")

    assert (kind(w), w.limit(), comments_of(w.store, 7)) == ("released", iso(R1) + "\n", [])


def test_a_first_limit_stop_is_retry_1_of_2_naming_the_log(w):
    ended(w, ndjson_with("Claude AI usage limit reached|%d" % R2))

    assert "retry 1 of 2, started once the limit pause has passed" in w.last_comment()
    assert w.log_path() in w.last_comment()


# --- the session end: a GitHub limit the session hit ---------------------------------


def hit(w, text):
    """A session that writes <text> to the hit file it was handed."""
    def effect(env):
        with open(env["ORCH_AUTOPILOT_HIT_FILE"], "w") as f:
            f.write(text)
    return effect


def test_a_hit_file_naming_a_reset_is_a_github_limit_stop_extending_the_github_pause(w):
    w.starter.effect = hit(w, iso(NOW + 1800) + "\n")

    ended(w, "the session ended\n")

    assert comments_of(w.store, 7)[0].split("\n", 1)[0] == marker_of("limited", "spec", "github")
    assert (w.github_limit(), w.limit()) == (iso(NOW + 1800) + "\n", None)
    assert not os.path.exists(w.path("run", "7.hit"))


def test_a_hit_file_naming_a_reset_days_out_pauses_github_for_an_hour_only(w):
    w.starter.effect = hit(w, iso(NOW + 172800) + "\n")

    ended(w, "the session ended\n")

    assert w.github_limit() == iso(NOW + 3600) + "\n"
    assert iso(NOW + 172800) not in "".join(comments_of(w.store, 7))


def test_a_hit_file_naming_no_reset_is_a_plain_failure_and_is_removed(w):
    w.starter.effect = hit(w, "not a time\n")

    ended(w, "the session ended\n")

    assert kind(w) == "failure"
    assert not os.path.exists(w.path("run", "7.hit"))


def test_a_released_session_leaves_no_github_pause(w):
    w.starter.effect = hit(w, iso(NOW + 1800) + "\n")
    w.starter.release = [7]

    ended(w, "the session ended\n")

    assert (w.github_limit(), os.path.exists(w.path("run", "7.hit"))) == (None, False)


def test_a_usage_limit_outranks_the_hit_file(w):
    w.starter.effect = hit(w, iso(NOW + 1800) + "\n")

    ended(w, ndjson_with("Claude AI usage limit reached|%d" % R1))

    assert (kind(w), w.github_limit(), os.path.exists(w.path("run", "7.hit"))) == (
        "limited", None, False)


# --- the session end: stops that cannot land ------------------------------------------


def test_the_third_limit_stop_in_a_row_still_writes_the_limit_file(w):
    for second in (0, 1):
        w.seed.comment(7, "o", "2026-01-01T00:00:0%dZ" % second,
                       marker_of("limited", "spec") + "\nstopped")

    ended(w, ndjson_with("Claude AI usage limit reached|%d" % R2))

    assert w.limit() == iso(R2) + "\n"
    assert w.labels() == HUMAN


def test_unreadable_comments_still_write_the_limit_file(w):
    w.seed.fail("adapter_issue_comments", "HTTP 500 comments")

    assert ended(w, ndjson_with("Claude AI usage limit reached|%d" % R2)) == 1
    assert w.limit() == iso(R2) + "\n"


def test_claims_that_cannot_be_read_at_the_end_die_touching_nothing(w, capsys):
    w.seed.fail_after("adapter_claim_list", 1, "HTTP 500 claims")
    before = snapshot(w.store)

    assert ended(w, ndjson_with("Claude AI usage limit reached|%d" % R2)) == 1
    assert "could not list the claims on origin" in capsys.readouterr().err
    assert {k: v for k, v in snapshot(w.store).items() if not k.startswith("fail")} == {
        k: v for k, v in before.items() if not k.startswith("fail")}
    assert w.limit() is None


def test_a_failed_comment_is_retried_and_the_stop_lands_once(w):
    w.seed.fail_times("adapter_issue_comment", 1, "HTTP 500 comment")

    code = ended(w, ndjson_with("Claude AI usage limit reached|%d" % R2))

    markers = [c for c in comments_of(w.store, 7) if c.startswith(marker_of("limited", "spec"))]
    assert (len(markers), kind(w), w.seed.claim_held(7), code) == (1, "limited", False, 0)


def test_a_timeline_read_that_meets_a_limit_ends_in_a_limit_stop_on_a_later_attempt(w):
    w.seed.fail_times("adapter_issue_comments", 1, "API rate limit exceeded")

    ended(w, ndjson_with("Claude AI usage limit reached|%d" % R2))

    assert kind(w) == "limited"


def test_a_stop_whose_every_attempt_fails_keeps_the_claim_and_writes_one_backstop(w):
    w.seed.fail("adapter_issue_relabel", "HTTP 500 relabel")

    code = ended(w, ndjson_with("Claude AI usage limit reached|%d" % R2))

    assert (w.seed.claim_held(7), code) == (True, 1)
    assert w.log().count("the stop chain failed after 3 attempts") == 1
    assert w.log().splitlines()[-1].startswith(
        "autopilot run: the stop chain failed after 3 attempts - limit stop: The session stopped"
        " on a usage limit")
    assert w.log().splitlines()[-1].endswith("; the session exited with code 1")
