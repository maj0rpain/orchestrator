"""`orch.sh autopilot tick`, its first half (its second half, ranking and
Pickup, is test_autopilot_pickup.py's) - the GitHub limit pause check,
the early-pause quota read, the label check, the one read of the claims and
the stale claims released from it, the one read of the done issues, the
merged-PR close, the usage and early pauses, the hourly housekeeping and
sync detection - run in-process through autopilot.run in a FakeGit main
checkout under tmp_path, against the gh fake on a tmp_path store, at a
fixed clock. Each case asserts what the tick leaves behind: its exit code
and messages, the labels, comments, claims and issue states on the store,
and the pause, stamp and log files under the main checkout. Ported from the
bash autopilot sections that held them: autopilot tick and run, the usage
limit, limited issues, the pause store, the label check, sync detection,
the merged-PR close backstop, one read of the done issues, the GitHub limit
pause, contained stops, one read of the claims, the early GitHub pause,
housekeeping's log prune and its sweep."""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

import pytest

from conftest import comments_of, hold_flow, labels_of, read
from orch import autopilot
from orch.gh_fake import FakeGh
from orch.repo import RepoPin
from orch.standing import REDO_PAIRS, label_entries
from test_side_checkout_add_prune import Clone

NOW = 1780315200
API_LIMIT = "API rate limit exceeded for user ID 1."
# A start time the fake /proc gives a live session's process.
START = "424242"
LIVE_PID = 4242


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def stat_of(pid, start):
    """A /proc/<pid>/stat line whose field 22, the process start, is
    <start>."""
    fields = ["S"] + [str(n) for n in range(4, 22)] + [start] + ["0"] * 10
    return "%d (python3 x) %s\n" % (pid, " ".join(fields))


class CountingGh(FakeGh):
    """The gh fake, counting its claim listings, its listings of the
    orch:done issues and its rate-limit pool reads."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.claim_reads = 0
        self.done_reads = 0

    def claim_list(self):
        self.claim_reads += 1
        return super().claim_list()

    def issues_labelled_rows(self, *labels):
        if labels == ("orch:done",):
            self.done_reads += 1
        return super().issues_labelled_rows(*labels)


class Child:
    """A child the fake starter ran to its end: wait() gives its exit, and
    whether it was waited for is kept."""

    def __init__(self, code):
        self.code = code
        self.waited = False

    def wait(self):
        self.waited = True
        return self.code


# The flow phase `orch.sh redo <phase>` steps a flow back to, for each redo
# the phase-redo rule names.
REDO_TO = {redo: labelled for labelled, _, redo in REDO_PAIRS}


class Children:
    """The fake process starter of the tick's children, each kept in
    <calls> as (argv, how it was started) and each the orch.sh beside the
    package's plugin root: `init <slug> --issue <n>` holds a spec-phase flow
    of that issue in its side checkout, `redo <phase>` steps its flow back
    (REDO_TO), and `autopilot run <issue>` does nothing. A noun in <notes>
    writes that to its stderr and succeeds; one in <fails> writes its stderr
    there and exits 1 instead; one in <unstartable> cannot be started at
    all."""

    def __init__(self):
        self.calls = []
        self.started = []
        self.notes = {}
        self.fails = {}
        self.unstartable = set()

    def __call__(self, argv, **how):
        self.calls.append((list(argv), how))
        noun = argv[1]
        if noun in self.unstartable:
            raise FileNotFoundError(2, "No such file or directory", argv[0])
        child = Child(0)
        self.started.append(child)
        if noun in self.fails:
            how["stderr"].write(self.fails[noun].encode())
            child.code = 1
            return child
        if noun in self.notes:
            how["stderr"].write(self.notes[noun].encode())
        if noun == "init":
            hold_flow(Path(how["cwd"]), slug=argv[2], issue=int(argv[4]), phase="spec")
        elif noun == "redo":
            state = json.loads((Path(how["cwd"]) / ".orchestrator" / "state.json").read_text())
            hold_flow(Path(how["cwd"]), **dict(state, phase=REDO_TO[argv[2]]))
        return child

    def of(self, noun):
        """The argv and how of each start of <noun>, in order."""
        return [(argv, how) for argv, how in self.calls if argv[1] == noun]

    def runs(self):
        """The issues an `autopilot run` was started for, in order."""
        return [argv[3] for argv, _ in self.of("autopilot")]


class Ticker:
    """The main checkout at tmp_path with no side checkout, GitHub's
    default branch main, the permission mode acceptEdits, claude on PATH,
    a fake /proc holding this process, the housekeeping stamp fresh, so
    housekeeping runs only where a case removes it, and the fake starter of
    its children."""

    def __init__(self, tmp_path, seed):
        self.clone = Clone(tmp_path, seed, local_config={
            "orchestrator.autopilot.permission-mode": "acceptEdits"})
        self.git = self.clone.git
        self.main = self.clone.main
        self.seed = seed
        self.store = seed.store
        self.proc = tmp_path / "proc"
        (self.proc / str(os.getpid())).mkdir(parents=True)
        (self.proc / str(os.getpid()) / "stat").write_text(stat_of(os.getpid(), START))
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir()
        (bin_dir / "claude").write_text("#!/bin/sh\nexit 0\n")
        (bin_dir / "claude").chmod(0o755)
        self.env = {"ORCHESTRATOR_HOST": "claude", "PATH": str(bin_dir),
                    "ORCH_PROC_DIR": str(self.proc), "ORCH_GH_LIMIT_WAIT": "0",
                    "ORCH_HOST_ID": "this-host"}
        self.clock = lambda: NOW
        self.gh = None
        self.children = Children()
        self.stamp(NOW)

    def set(self, name, value):
        """orchestrator.autopilot.<name> set to <value> in the local
        config."""
        self.git.config_set("local", "orchestrator.autopilot." + name, value)

    def path(self, *parts):
        return os.path.join(self.main, ".orchestrator", "autopilot", *parts)

    def put(self, name, text):
        os.makedirs(os.path.dirname(self.path(name)), exist_ok=True)
        with open(self.path(name), "w") as f:
            f.write(text)

    def text(self, name):
        path = self.path(name)
        if not os.path.isfile(path):
            return None
        with open(path) as f:
            return f.read()

    def stamp(self, text):
        """The housekeeping stamp holding <text>; None removes it."""
        if text is None:
            if os.path.isfile(self.path("housekeeping")):
                os.remove(self.path("housekeeping"))
            return
        self.put("housekeeping", "%s\n" % text)

    def pause(self, name, epoch):
        self.put(name, iso(epoch) + "\n")

    def claim(self, n, host="this-host", phase="spec", live=False):
        """A claim on issue #n by <host> at <phase>; with <live>, a run
        record naming a process the fake /proc holds."""
        self.seed.claim(n, host=host, phase=phase)
        if live:
            (self.proc / str(LIVE_PID + n)).mkdir()
            (self.proc / str(LIVE_PID + n) / "stat").write_text(stat_of(LIVE_PID + n, START))
            self.put("run/%d.pid" % n, "%d %s\n" % (LIVE_PID + n, START))

    def tick(self, *argv, gh_class=None):
        """`orch.sh autopilot tick <argv>` on a counting gh fake (a
        <gh_class> when given): its exit code."""
        self.gh = (gh_class or CountingGh)(self.store, self.env, pin=RepoPin(self.env, self.git),
                             sleep=lambda _: None, now=self.clock)
        try:
            return autopilot.run(["tick", *argv], gh=self.gh, git=self.git, env=self.env,
                                 clock=self.clock, starter=self.children)
        except SystemExit as died:
            return died.code

    def labels(self, n):
        return sorted(labels_of(self.store, n))

    def state(self, n):
        return (read(self.store, "issues", n, "state") or "").strip()


@pytest.fixture
def t(tmp_path, seed, monkeypatch):
    # The tick enters the main checkout, as bash's cd does: the case's
    # directory is restored after it.
    monkeypatch.chdir(tmp_path)
    return Ticker(tmp_path, seed)


# --- the GitHub limit pause -------------------------------------------------------


def test_a_tick_under_a_github_pause_makes_no_github_call_and_says_why_on_stderr(t, capsys):
    t.seed.issue(7, "open", "ready-for-agent", "orch:spec")
    t.pause("github-limit", NOW + 1800)

    assert t.tick() == 0
    assert capsys.readouterr() == (
        "", "orch: GitHub API rate limit: the tick does nothing until %s\n" % iso(NOW + 1800))
    assert t.gh.claim_reads == 0
    assert not os.path.exists(os.path.join(t.store, "labels"))
    assert t.labels(7) == ["orch:spec", "ready-for-agent"]


def test_a_passed_github_pause_is_removed_and_the_tick_goes_on(t):
    t.put("github-limit", "2020-01-01T00:00:00Z\n")

    assert t.tick() == 0
    assert t.text("github-limit") is None
    assert t.gh.claim_reads == 1


def test_a_github_pause_over_an_hour_ahead_is_cut_to_an_hour_warned_and_held(t, capsys):
    t.pause("github-limit", NOW + 7200)

    assert t.tick() == 0
    assert capsys.readouterr().err == (
        "orch: the GitHub pause until %s is more than an hour away, which no GitHub limit"
        " names; it is cut to %s\n"
        "orch: GitHub API rate limit: the tick does nothing until %s\n"
        % (iso(NOW + 7200), iso(NOW + 3600), iso(NOW + 3600)))
    assert t.text("github-limit") == iso(NOW + 3600) + "\n"
    assert t.gh.claim_reads == 0

    t.tick()
    assert "more than an hour away" not in capsys.readouterr().err
    assert t.text("github-limit") == iso(NOW + 3600) + "\n"


def test_an_early_pool_file_over_an_hour_ahead_is_cut_the_same_way(t, capsys):
    t.pause("github-early-core", NOW + 7200)

    assert t.tick() == 0
    err = capsys.readouterr().err
    assert "is more than an hour away, which no GitHub limit names; it is cut to %s" % iso(
        NOW + 3600) in err
    assert err.endswith("orch: GitHub core pool is below the github-reserve: no issue is"
                        " picked up until %s\n" % iso(NOW + 3600))
    assert t.text("github-early-core") == iso(NOW + 3600) + "\n"


def test_the_usage_limit_file_is_never_cut_and_its_note_goes_to_stdout(t, capsys):
    t.pause("limit", NOW + 172800)

    assert t.tick() == 0
    out, err = capsys.readouterr()
    assert out == "usage limit: no issue is picked up until %s\n" % iso(NOW + 172800)
    assert "more than an hour away" not in err
    assert t.text("limit") == iso(NOW + 172800) + "\n"


@pytest.mark.parametrize("text", ["2020-01-01T00:00:00Z\n", "garbage\n"])
def test_a_usage_limit_passed_or_unreadable_is_removed_and_pauses_nothing(t, capsys, text):
    t.put("limit", text)

    assert t.tick() == 0
    assert "usage limit" not in capsys.readouterr().out
    assert t.text("limit") is None


def test_a_limit_file_in_another_clone_s_autopilot_directory_starts_no_pause(t, tmp_path, capsys):
    other = tmp_path / "other" / ".orchestrator" / "autopilot"
    other.mkdir(parents=True)
    (other / "limit").write_text(iso(NOW + 3600) + "\n")
    (other / "github-limit").write_text(iso(NOW + 3600) + "\n")

    assert t.tick() == 0
    assert capsys.readouterr() == ("", "")
    assert t.gh.claim_reads == 1


def test_a_bad_auto_sync_dies_naming_key_and_value_before_any_github_call(t, capsys):
    t.set("auto-sync", "maybe")

    assert t.tick() == 1
    assert capsys.readouterr().err == (
        "orch: orchestrator.autopilot.auto-sync is maybe - it must be true or false (git config"
        " orchestrator.autopilot.auto-sync true|false)\n")
    assert t.gh.claim_reads == 0


def test_a_bad_cap_dies_before_any_github_call(t, capsys):
    t.set("cap", "0")

    assert t.tick() == 1
    assert "orchestrator.autopilot.cap is 0" in capsys.readouterr().err
    assert t.gh.claim_reads == 0


def test_the_github_reserve_is_read_after_the_github_pause_check(t, capsys):
    t.set("github-reserve", "abc")

    assert t.tick() == 1
    assert "orch: orchestrator.autopilot.github-reserve is abc" in capsys.readouterr().err

    t.pause("github-limit", NOW + 1800)
    assert t.tick() == 0
    assert "github-reserve is abc" not in capsys.readouterr().err


@pytest.mark.parametrize("host,path", [("junie", None), ("claude", "empty")])
def test_off_claude_code_or_with_no_claude_on_path_the_tick_dies_before_any_github_call(
        t, tmp_path, capsys, host, path):
    t.env["ORCHESTRATOR_HOST"] = host
    if path:
        (tmp_path / path).mkdir()
        t.env["PATH"] = str(tmp_path / path)

    assert t.tick() == 1
    assert capsys.readouterr().err == (
        "orch: autopilot is Claude Code only (no headless-session fallback on this host;"
        " see docs/host-capabilities.md)\n")
    assert t.gh.claim_reads == 0


def test_the_tick_takes_no_arguments(t, capsys):
    assert t.tick("x") == 1
    assert capsys.readouterr().err == "orch: usage: orch.sh autopilot tick\n"


def test_the_tick_marks_its_process_an_autopilot_tick_for_all_it_starts(t):
    t.tick()

    assert t.env["ORCH_AUTOPILOT_TICK"] == "1"


# --- the label check --------------------------------------------------------------


def store_labels(store):
    return sorted((read(store, "labels") or "").split("\n")[:-1])


def seed_labels(seed, skip=None, **changed):
    """Every standing label, as the label check writes them, but <skip>,
    and each label of <changed>'s keys (underscores for colons) with its
    (colour, description) replaced."""
    for name, colour, description in label_entries():
        if name != skip:
            seed.label(name, *changed.get(name.replace(":", "_"), (colour, description)))


def test_a_repo_with_no_labels_gets_every_standing_label_with_its_colour_and_description(t):
    assert t.tick() == 0
    assert store_labels(t.store) == [
        "needs-human\td93f0b\tWaiting on the human",
        "orch:done\tc2e0c6\tAutopilot flow: done",
        "orch:implement\t0e8a16\tAutopilot flow: implement phase next",
        "orch:limited\tc5def5\tAutopilot session stopped on a usage or GitHub API rate limit;"
        " retried after the reset",
        "orch:review\t5319e7\tAutopilot flow: review phase next",
        "orch:running\tfbca04\tAutopilot session running",
        "orch:spec\t1d76db\tAutopilot flow: spec phase next",
        "orch:sync\t0075ca\tAutopilot: base sync requested on a done flow",
    ]


def test_every_standing_label_present_and_matching_makes_no_label_write(t):
    seed_labels(t.seed)
    t.seed.fail("adapter_label_upsert", "HTTP 500 a label write")

    assert t.tick() == 0


def test_a_label_differing_only_in_name_or_colour_casing_is_left_alone(t):
    seed_labels(t.seed, orch_review=("5319E7", "Autopilot flow: review phase next"))
    labels = os.path.join(t.store, "labels")
    with open(labels) as f:
        text = f.read().replace("orch:spec\t", "ORCH:SPEC\t")
    with open(labels, "w") as f:
        f.write(text)
    t.seed.fail("adapter_label_upsert", "HTTP 500 a label write")

    assert t.tick() == 0


def test_a_drifted_colour_or_description_is_updated_and_a_missing_label_created(t):
    seed_labels(t.seed, skip="orch:sync", orch_review=("000000", "Autopilot flow: review phase next"),
                orch_running=("fbca04", "stale words"))

    assert t.tick() == 0
    assert {"orch:review\t5319e7\tAutopilot flow: review phase next",
            "orch:running\tfbca04\tAutopilot session running",
            "orch:sync\t0075ca\tAutopilot: base sync requested on a done flow"} <= set(
        store_labels(t.store))


@pytest.mark.parametrize("operation,message", [
    ("adapter_labels_detail", "could not read the repo's labels: HTTP 502 - the tick stops"),
    ("adapter_label_upsert", "could not upsert the label orch:spec: HTTP 502 - the tick stops"),
])
def test_a_failed_label_read_or_upsert_stops_the_tick_before_the_claims_read(
        t, capsys, operation, message):
    t.seed.fail(operation, "HTTP 502")

    assert t.tick() == 1
    assert capsys.readouterr().err == "orch: %s\n" % message
    assert t.gh.claim_reads == 0


# --- the claims and stale cleanup ---------------------------------------------------


def test_a_tick_reads_the_claims_once(t):
    t.claim(5)
    t.seed.issue(5, "open", "ready-for-agent", "orch:spec", "orch:running")
    t.claim(6, live=True)

    assert t.tick() == 0
    assert t.gh.claim_reads == 1


def test_a_failed_claims_read_fails_the_tick_naming_it(t, capsys):
    t.seed.fail("adapter_claim_list", "HTTP 502 claims")

    assert t.tick() == 1
    assert capsys.readouterr().err.endswith(
        "orch: could not list the claims on origin: HTTP 502 claims\n")


def test_a_stale_claim_of_this_host_is_a_failure_stop_that_releases_it(t):
    t.seed.issue(5, "open", "ready-for-agent", "orch:spec", "orch:running")
    t.claim(5)

    assert t.tick() == 0
    assert t.labels(5) == ["needs-human", "orch:spec", "ready-for-agent"]
    assert t.seed.claim_held(5) is False
    assert ("Autopilot failed in the spec phase: the session's process (pid unknown) is gone and"
            " the claim was never released - no exit code is known; no session log\n"
            ) in comments_of(t.store, 5)[-1]


def test_a_live_claim_and_another_host_s_claim_are_left_alone(t):
    t.seed.issue(5, "open", "orch:spec", "orch:running")
    t.claim(5, live=True)
    t.seed.issue(6, "open", "orch:spec", "orch:running")
    t.claim(6, host="otherhost")

    assert t.tick() == 0
    assert (t.seed.claim_held(5), t.seed.claim_held(6)) == (True, True)
    assert t.labels(5) == t.labels(6) == ["orch:running", "orch:spec"]


def test_a_stale_stop_names_the_gone_pid_and_quotes_the_session_log_s_backstop_line(t):
    t.seed.issue(10, "open", "orch:review", "orch:running")
    t.claim(10, phase="review")
    t.put("run/10.pid", "999999 1\n")
    log = t.path("logs", "10-review-20250101-000000.log")
    t.put("logs/10-review-20250101-000000.log",
          "noise\n" + autopilot.AUTOPILOT_BACKSTOP_PREFIX + "failure: older\n"
          + autopilot.AUTOPILOT_BACKSTOP_PREFIX + "failure: Autopilot failed; the session"
          " exited with code 3\n")

    assert t.tick() == 0
    assert ('the session\'s process (pid 999999) is gone and the claim was never released -'
            ' the session log says: "the stop chain failed after 3 attempts - failure: Autopilot'
            ' failed; the session exited with code 3"; log: %s\n' % log
            ) in comments_of(t.store, 10)[-1]
    assert t.text("run/10.pid") is None


def test_a_stale_claim_whose_stop_cannot_land_is_contained_and_the_next_still_stopped(
        t, capsys):
    t.claim(5)
    t.seed.issue(6, "open", "orch:spec", "orch:running")
    t.claim(6)

    assert t.tick() == 0
    err = capsys.readouterr().err
    warning = ("orch: could not stop issue #5 - its claim stays held; the next tick tries again;"
               " if the issue is gone for good, delete the claim ref by hand: git push origin"
               " :refs/orch/claims/5\n")
    assert warning in err
    assert err.index("orch: could not ") < err.index(warning)
    assert t.seed.claim_held(5) is True
    assert (t.labels(6), t.seed.claim_held(6)) == (["needs-human", "orch:spec"], False)

    assert t.tick() == 0
    assert warning in capsys.readouterr().err


def test_a_stale_claim_whose_stop_fails_once_keeps_its_records_for_the_next_tick(t):
    t.seed.issue(10, "open", "orch:spec", "orch:running")
    t.claim(10)
    t.put("run/10.pid", "999999 1\n")
    t.put("logs/10-spec-20250101-000000.log", "")
    t.seed.fail_times("adapter_issue_relabel", 1, "HTTP 500 relabel")

    t.tick()
    assert (t.seed.claim_held(10), t.text("run/10.pid")) == (True, "999999 1\n")

    t.tick()
    assert t.seed.claim_held(10) is False
    assert "pid 999999) is gone" in comments_of(t.store, 10)[-1]
    assert "logs/10-spec-20250101-000000.log" in comments_of(t.store, 10)[-1]


def test_a_stale_stop_that_meets_a_github_limit_ends_the_tick(t, capsys):
    t.seed.issue(5, "open", "orch:spec", "orch:running")
    t.claim(5)
    t.seed.issue(6, "open", "orch:spec", "orch:running")
    t.claim(6)
    t.seed.issue(60, "open", "orch:done")
    t.seed.fail_times("adapter_issue_relabel", 1, API_LIMIT)

    assert t.tick() == 0
    err = capsys.readouterr().err
    assert "could not stop issue #5 - its claim stays held" in err
    assert "issue #6" not in err
    assert t.text("github-limit") is not None
    assert (t.seed.claim_held(6), t.labels(6)) == (True, ["orch:running", "orch:spec"])
    assert t.gh.done_reads == 0


def test_a_limited_issue_left_held_by_a_failed_limit_stop_ends_needs_human_not_limited(t):
    t.seed.issue(7, "open", "ready-for-agent", "orch:spec", "orch:running", "orch:limited")
    t.claim(7)

    assert t.tick() == 0
    assert t.labels(7) == ["needs-human", "orch:spec", "ready-for-agent"]
    assert t.seed.claim_held(7) is False


def test_a_paused_tick_still_cleans_stale_claims(t):
    t.pause("limit", NOW + 3600)
    t.seed.issue(9, "open", "orch:spec", "orch:running")
    t.claim(9)

    assert t.tick() == 0
    assert t.labels(9) == ["needs-human", "orch:spec"]


# --- the early GitHub pause --------------------------------------------------------


def test_a_pool_under_the_reserve_records_its_capped_early_pause_and_pauses_the_tick(
        t, capsys):
    t.seed.quota("core", 5000, 5000, NOW + 7100)
    t.seed.quota("graphql", 400, 5000, NOW + 7200)
    t.seed.issue(5, "open", "orch:spec", "orch:running")
    t.claim(5)
    t.stamp(None)

    assert t.tick() == 0
    out, err = capsys.readouterr()
    assert err.endswith("orch: GitHub graphql pool is below the github-reserve: no issue is"
                        " picked up until %s\n" % iso(NOW + 3600))
    assert "usage limit" not in out + err
    assert (t.text("github-early-graphql"), t.text("github-early-core"), t.text("limit")) == (
        iso(NOW + 3600) + "\n", None, None)
    # the early pause still cleans this host's stale claims, from one read
    assert (t.labels(5), t.gh.claim_reads) == (["needs-human", "orch:spec"], 1)
    # and skips housekeeping
    assert t.text("housekeeping") is None


def test_a_github_reserve_of_0_reads_no_pools_and_ignores_a_recorded_early_pause(t, capsys):
    t.set("github-reserve", "0")
    t.seed.quota("graphql", 1, 5000, NOW + 600)
    t.pause("github-early-core", NOW + 600)
    t.stamp(None)

    assert t.tick() == 0
    assert "below the github-reserve" not in capsys.readouterr().err
    assert t.text("github-early-graphql") is None
    assert t.text("housekeeping") == "%d\n" % NOW


@pytest.mark.parametrize("quota", ["fail", "empty"])
def test_a_failed_or_empty_pool_read_pauses_nothing(t, capsys, quota):
    if quota == "fail":
        t.seed.fail("adapter_rate_limit", "HTTP 502")
    else:
        Path(t.store, "quota").write_text("")

    assert t.tick() == 0
    assert "below the github-reserve" not in capsys.readouterr().err
    assert not [name for name in os.listdir(t.path()) if name.startswith("github-early-")]


def test_an_unwritable_early_pause_is_warned_and_pauses_nothing(t, capsys):
    t.seed.quota("core", 1, 5000, NOW + 600)
    os.makedirs(t.path("github-early-core"))

    assert t.tick() == 0
    assert "orch: could not write the early GitHub pause under %s\n" % t.main in (
        capsys.readouterr().err)


# --- the done issues and the merged-PR close ----------------------------------------


def done_merged(t, n, age, created_age=None, base="main", closing=None, cross=False):
    """Issue #n open at orch:done, its PR #(100+n) from orch/<n>-widget
    merged into <base> <age> seconds before NOW with `Closes #<closing>`
    (#n when None), the issue created <created_age> seconds before NOW when
    given."""
    t.seed.issue(n, "open", "orch:done")
    t.seed.pr(100 + n, "merged", "orch/%d-widget" % n, base)
    t.seed.pr_merged(100 + n, iso(NOW - age), n if closing is None else closing)
    if created_age is not None:
        t.seed.issue_created(n, iso(NOW - created_age))
    if cross:
        t.seed.pr_cross(100 + n)


def test_the_close_closes_each_done_issue_whose_pr_github_left_open(t):
    t.seed.default_branch("main\n")
    t.set("auto-sync", "false")
    done_merged(t, 50, 3600)
    done_merged(t, 51, 60)
    done_merged(t, 52, 3600, base="release")
    done_merged(t, 53, 3600, closing=99)
    done_merged(t, 54, 3600)
    t.seed.issue(54, "closed", "orch:done")
    done_merged(t, 55, 3600)
    t.seed.labels(55, "orch:review")
    done_merged(t, 56, 3600)
    t.seed.labels(56, "orch:done", "orch:running")
    done_merged(t, 57, 3600)
    t.seed.labels(57, "orch:done", "orch:sync", "needs-human")
    done_merged(t, 58, 3600, cross=True)

    assert t.tick() == 0
    assert [t.state(n) for n in range(50, 59)] == [
        "CLOSED", "OPEN", "OPEN", "OPEN", "CLOSED", "OPEN", "OPEN", "CLOSED", "OPEN"]
    assert read(t.store, "issues", 50, "reason") == "completed\n"
    assert comments_of(t.store, 50) == [
        "Closed by the orchestrator: PR #150 merged into `main` with `Closes #50`, but GitHub"
        " did not close this issue."]
    assert t.labels(50) == ["orch:done"]
    assert comments_of(t.store, 54) == []
    assert t.gh.done_reads == 1


@pytest.mark.parametrize("operation,warning", [
    ("adapter_prs_merged_closing", "could not read the merged PRs: HTTP 502"),
    ("adapter_issue_created_at",
     "could not read the creation time of issue #50: HTTP 502 - no merged-PR close this tick"),
    ("adapter_issue_close", "could not close issue #50 after PR #150 merged: HTTP 502"),
])
def test_a_failed_read_or_close_warns_closes_nothing_and_the_tick_goes_on(
        t, capsys, operation, warning):
    done_merged(t, 50, 3600)
    t.seed.fail(operation, "HTTP 502")

    assert t.tick() == 0
    assert "orch: %s" % warning in capsys.readouterr().err
    assert t.state(50) == "OPEN"


def test_a_failed_close_keeps_its_issue_for_sync_detection_and_a_closed_one_leaves_it(t):
    done_merged(t, 62, 3600)
    t.seed.pr(262, "open", "orch/62-open", "main")
    t.seed.pr_mergeable(262, "CONFLICTING")
    done_merged(t, 63, 3600)
    t.seed.pr(263, "open", "orch/63-open", "main")
    t.seed.pr_mergeable(263, "CONFLICTING")
    t.seed.fail_after("adapter_issue_close", 1, "HTTP 500")

    assert t.tick() == 0
    assert (t.state(62), t.labels(62)) == ("CLOSED", ["orch:done"])
    # The sync request it got is picked up the same tick and refused: no
    # side checkout holds the issue.
    assert (t.state(63), t.labels(63)) == ("OPEN", ["needs-human", "orch:done", "orch:sync"])


class DyingMergedRead(CountingGh):
    """The gh fake, its merged-PR read dying as a gh that cannot run
    does."""

    def prs_merged_closing(self, base, since):
        from orch.common import die
        die("gh: command not found")


def test_a_death_in_the_close_keeps_the_whole_table_and_the_tick_goes_on(t, capsys):
    done_merged(t, 64, 3600)
    t.seed.pr(264, "open", "orch/64-open", "main")
    t.seed.pr_mergeable(264, "CONFLICTING")

    assert t.tick(gh_class=DyingMergedRead) == 0
    assert "orch: gh: command not found\n" in capsys.readouterr().err
    assert t.state(64) == "OPEN"
    assert t.labels(64) == ["needs-human", "orch:done", "orch:sync"]


def test_a_usage_limit_pause_stops_sync_detection_never_the_close(t, capsys):
    t.pause("limit", NOW + 3600)
    done_merged(t, 59, 3600)
    t.seed.issue(30, "open", "orch:done")
    t.seed.pr(130, "open", "orch/30-widget", "main")
    t.seed.pr_mergeable(130, "CONFLICTING")
    t.seed.fail("adapter_prs_open_mergeability", "HTTP 502")

    assert t.tick() == 0
    assert t.state(59) == "CLOSED"
    assert t.labels(30) == ["orch:done"]
    assert "could not read the PR" not in capsys.readouterr().err


def test_a_failed_done_listing_warns_once_naming_both_passes_and_the_tick_goes_on(t, capsys):
    t.seed.issue(60, "open", "orch:done")
    t.seed.pr(160, "open", "orch/60-open", "main")
    t.seed.pr_mergeable(160, "CONFLICTING")
    t.seed.fail_times("adapter_issues_labelled_rows", 1, "HTTP 502")

    assert t.tick() == 0
    assert capsys.readouterr().err.count(
        "orch: could not list the issues labelled orch:done: HTTP 502 - no merged-PR close or"
        " sync detection this tick\n") == 1
    assert t.labels(60) == ["orch:done"]


def test_the_done_read_at_the_issue_list_limit_acts_on_the_oldest_and_warns(t, capsys):
    t.env["ORCH_ISSUE_LIST_LIMIT"] = "2"
    for n in (70, 71, 72):
        done_merged(t, n, 3600)

    assert t.tick() == 0
    assert ("orch: the open issues labelled orch:done reached the issue-list limit of 2 - the"
            " newest past it are missing from this list\n") in capsys.readouterr().err
    assert [t.state(n) for n in (70, 71, 72)] == ["CLOSED", "CLOSED", "OPEN"]


DAY = 86400


@pytest.mark.parametrize("merged_age,created_age,state", [
    (3600, 7200, "CLOSED"), (7200, 3600, "OPEN"), (3 * DAY, 10 * DAY, "CLOSED")],
    ids=["merged after its creation", "merged before its creation", "days apart"])
def test_a_pr_merged_before_its_issue_was_created_is_not_acted_on(
        t, merged_age, created_age, state):
    done_merged(t, 80, merged_age, created_age=created_age)

    assert t.tick() == 0
    assert t.state(80) == state


def test_the_merged_pr_read_is_bounded_by_the_oldest_issue_not_running(t):
    # #85 is running and the oldest. A read bounded by #86's creation reads
    # #86's PR, merged before #87 was created, but never #87's, merged
    # before #86 was.
    done_merged(t, 85, 3600, created_age=3 * DAY)
    t.seed.labels(85, "orch:done", "orch:running")
    done_merged(t, 86, 3 * DAY // 2, created_age=2 * DAY)
    done_merged(t, 87, 5 * DAY // 2, created_age=DAY)

    assert t.tick() == 0
    assert (t.state(85), t.state(86), t.state(87)) == ("OPEN", "CLOSED", "OPEN")


def test_done_issues_of_different_ages_are_closed_from_one_read_of_each_kind(t, capsys):
    done_merged(t, 83, 4 * DAY, created_age=5 * DAY)
    done_merged(t, 84, 3600, created_age=DAY)
    t.seed.fail_after("adapter_prs_merged_closing", 1, "HTTP 502")
    t.seed.fail_after("adapter_issue_created_at", 1, "HTTP 502")

    assert t.tick() == 0
    assert (t.state(83), t.state(84)) == ("CLOSED", "CLOSED")
    assert "could not read" not in capsys.readouterr().err


def test_with_every_done_issue_running_or_none_no_merged_pr_is_read(t, capsys):
    t.seed.fail("adapter_prs_merged_closing", "HTTP 502")
    t.seed.fail("adapter_issue_created_at", "HTTP 502")
    t.seed.fail("adapter_prs_open_mergeability", "HTTP 502")

    assert t.tick() == 0
    done_merged(t, 88, 3600)
    t.seed.labels(88, "orch:done", "orch:running")
    assert t.tick() == 0
    assert "could not read" not in capsys.readouterr().err


# --- sync detection --------------------------------------------------------------


def done_pr(t, n, state, mergeable, head=None):
    """Issue #n open at orch:done, its PR #(100+n) in <state> from <head>
    (orch/<n>-widget when None) with <mergeable>."""
    t.seed.issue(n, "open", "orch:done")
    t.seed.pr(100 + n, state, head or "orch/%d-widget" % n, "main")
    t.seed.pr_mergeable(100 + n, mergeable)


def test_a_conflicting_open_pr_of_a_done_issue_gets_a_sync_request_and_nothing_else(t, capsys):
    done_pr(t, 30, "open", "CONFLICTING")
    done_pr(t, 31, "open", "UNKNOWN")
    done_pr(t, 32, "open", "MERGEABLE")
    done_pr(t, 33, "closed", "CONFLICTING")
    done_pr(t, 34, "merged", "CONFLICTING")
    for n, label in ((35, "orch:sync"), (36, "needs-human"), (37, "orch:running")):
        done_pr(t, n, "open", "CONFLICTING")
        t.seed.labels(n, "orch:done", label)
    t.seed.issue(38, "open", "orch:done")
    t.seed.pr(138, "open", "orch/380-other", "main")
    t.seed.pr_mergeable(138, "CONFLICTING")
    t.seed.issue(39, "open", "orch:done")
    t.seed.pr(139, "open", "orch/39-widget", "main")
    t.seed.pr_mergeable(139, "CONFLICTING")
    t.seed.pr_cross(139)

    assert t.tick() == 0
    # Each sync request - the one filed and the one already there - is
    # picked up the same tick and refused, as no side checkout holds it.
    assert [t.labels(n) for n in range(30, 40)] == [
        ["needs-human", "orch:done", "orch:sync"], ["orch:done"], ["orch:done"], ["orch:done"],
        ["orch:done"], ["needs-human", "orch:done", "orch:sync"], ["needs-human", "orch:done"],
        ["orch:done", "orch:running"], ["orch:done"], ["orch:done"]]
    assert t.children.runs() == []
    err = capsys.readouterr().err
    assert "orch: ignored 1 PR(s) from forks for the open PRs\n" in err
    assert "issue #38" not in err


def test_an_issue_with_two_open_prs_is_warned_about_and_skipped(t, capsys):
    t.seed.issue(40, "open", "orch:done")
    for n, head in ((140, "orch/40-a"), (240, "orch/40-b")):
        t.seed.pr(n, "open", head, "main")
        t.seed.pr_mergeable(n, "CONFLICTING")

    assert t.tick() == 0
    assert ("orch: issue #40 has 2 open PRs from a branch starting orch/40- - sync detection"
            " skips it\n") in capsys.readouterr().err
    assert t.labels(40) == ["orch:done"]


def test_a_failing_sync_label_write_warns_and_the_next_issue_is_still_tried(t, capsys):
    done_pr(t, 30, "open", "CONFLICTING")
    done_pr(t, 41, "open", "CONFLICTING")
    t.seed.fail("adapter_issue_relabel", "HTTP 500")

    assert t.tick() == 0
    err = capsys.readouterr().err
    assert "orch: could not add orch:sync to issue #30: HTTP 500 - sync detection skips it\n" in err
    assert "orch: could not add orch:sync to issue #41: HTTP 500 - sync detection skips it\n" in err


@pytest.mark.parametrize("break_read,reason", [
    (lambda t: t.seed.fail("adapter_prs_open_mergeability", "HTTP 502"), "HTTP 502"),
    (lambda t: t.seed.pr_cross(130, "maybe"),
     "the open PRs could not be read: a malformed line"),
], ids=["failed", "malformed"])
def test_an_unreadable_pr_listing_warns_per_issue_and_files_nothing(
        t, capsys, break_read, reason):
    done_pr(t, 30, "open", "CONFLICTING")
    break_read(t)

    assert t.tick() == 0
    assert ("orch: could not read the PR of issue #30: %s - sync detection skips it\n"
            % reason) in capsys.readouterr().err
    assert t.labels(30) == ["orch:done"]


def test_with_auto_sync_false_no_sync_request_is_filed_and_no_pr_read(t):
    done_pr(t, 30, "open", "CONFLICTING")
    t.set("auto-sync", "false")
    t.seed.fail("adapter_prs_open_mergeability", "HTTP 502")

    assert t.tick() == 0
    assert t.labels(30) == ["orch:done"]


# --- housekeeping: the stamp and the log prune -----------------------------------

FORTNIGHT_AND_A_DAY = 15 * DAY


def logs_seed(t):
    """An old session log, a fresh one, and an old file that is no session
    log."""
    for name, age in (("5-spec-20240101-000000.log", FORTNIGHT_AND_A_DAY),
                      ("6-spec-20240101-000000.log", 0),
                      ("notes.txt", FORTNIGHT_AND_A_DAY)):
        t.put("logs/" + name, "")
        os.utime(t.path("logs", name), (NOW - age, NOW - age))


def logs_kept(t):
    folder = t.path("logs")
    return sorted(os.listdir(folder)) if os.path.isdir(folder) else []


def test_a_tick_with_no_stamp_prunes_old_session_logs_and_writes_the_stamp(t):
    t.stamp(None)
    logs_seed(t)
    for name in ("5-spec-notes.log", "5-spec-copy.log"):
        t.put("logs/" + name, "")
        os.utime(t.path("logs", name), (NOW - FORTNIGHT_AND_A_DAY,) * 2)

    assert t.tick() == 0
    assert logs_kept(t) == ["5-spec-copy.log", "5-spec-notes.log", "6-spec-20240101-000000.log",
                            "notes.txt"]
    assert t.text("housekeeping") == "%d\n" % NOW


def test_a_fresh_stamp_skips_housekeeping(t):
    t.stamp(NOW - 3600)
    logs_seed(t)

    assert t.tick() == 0
    assert "5-spec-20240101-000000.log" in logs_kept(t)
    assert t.text("housekeeping") == "%d\n" % (NOW - 3600)


@pytest.mark.parametrize("stamp", [NOW - 3601, "garbage", "089", NOW + 7200, 0],
                         ids=["stale", "unparsable", "leading zero", "future", "zero"])
def test_a_stale_unparsable_or_future_stamp_runs_housekeeping_and_rewrites_it(t, stamp):
    t.stamp(stamp)
    logs_seed(t)

    assert t.tick() == 0
    assert logs_kept(t) == ["6-spec-20240101-000000.log", "notes.txt"]
    assert t.text("housekeeping") == "%d\n" % NOW


def test_a_missing_logs_directory_is_no_failure(t, capsys):
    t.stamp(None)

    assert t.tick() == 0
    assert "could not" not in capsys.readouterr().err


def test_a_stamp_that_cannot_be_written_warns_and_skips_housekeeping(t, capsys):
    t.stamp(None)
    os.makedirs(t.path("housekeeping"))
    logs_seed(t)

    assert t.tick() == 0
    assert ("orch: could not write the housekeeping stamp %s: housekeeping is skipped\n"
            % t.path("housekeeping")) in capsys.readouterr().err
    assert "5-spec-20240101-000000.log" in logs_kept(t)


def test_a_logs_path_that_is_no_directory_warns_and_never_fails_the_tick(t, capsys):
    t.stamp(None)
    t.put("logs", "")

    assert t.tick() == 0
    assert ("orch: could not prune the session logs: %s is not a directory\n" % t.path("logs")
            ) in capsys.readouterr().err
    assert t.text("housekeeping") == "%d\n" % NOW


@pytest.mark.skipif(os.geteuid() == 0, reason="permissions do not bite for root")
def test_a_session_log_that_cannot_be_deleted_or_listed_warns_and_never_fails_the_tick(
        t, capsys):
    t.stamp(None)
    logs_seed(t)
    os.chmod(t.path("logs"), 0o555)
    try:
        assert t.tick() == 0
        assert ("orch: could not delete the old session log %s\n"
                % t.path("logs", "5-spec-20240101-000000.log")) in capsys.readouterr().err
        t.stamp(None)
        os.chmod(t.path("logs"), 0)
        assert t.tick() == 0
        assert ("orch: could not prune the session logs: %s could not be listed\n"
                % t.path("logs")) in capsys.readouterr().err
    finally:
        os.chmod(t.path("logs"), 0o755)
    assert t.text("housekeeping") == "%d\n" % NOW


@pytest.mark.parametrize("pause,epoch", [("limit", NOW + 7200), ("github-limit", NOW + 1800)])
def test_a_holding_usage_or_github_pause_skips_housekeeping(t, pause, epoch):
    t.stamp(None)
    logs_seed(t)
    t.pause(pause, epoch)

    assert t.tick() == 0
    assert "5-spec-20240101-000000.log" in logs_kept(t)
    assert t.text("housekeeping") is None


# --- housekeeping: the finished sweep --------------------------------------------


def test_housekeeping_sweeps_a_finished_side_checkout_its_report_on_stderr(t, capsys):
    t.stamp(None)
    done = t.clone.quick("hs-done", 9, 61)
    kept = t.clone.quick("hs-open", 10, 62, state="open")

    assert t.tick() == 0
    out, err = capsys.readouterr()
    assert out == ""
    assert ("skipped %s: no merged PR from quick/10-hs-open into main\nremoved side checkout %s\n"
            "deleted branch quick/9-hs-done\n" % (kept, done)) in err
    assert list(t.git.branches) == ["quick/10-hs-open"]


def test_a_sweep_that_cannot_read_github_removes_nothing_warns_and_the_tick_goes_on(t, capsys):
    t.stamp(None)
    t.clone.quick("hs-done", 9, 61)
    t.seed.fail("adapter_prs_merged", "HTTP 502")
    done_pr(t, 30, "open", "CONFLICTING")

    assert t.tick() == 0
    err = capsys.readouterr().err
    assert "could not read GitHub: HTTP 502" in err
    assert err.count("orch: the finished sweep failed - carrying on\n") == 1
    assert "quick/9-hs-done" in t.git.branches
    assert t.text("housekeeping") == "%d\n" % NOW
    assert t.labels(30) == ["needs-human", "orch:done", "orch:sync"]


def test_a_sweep_that_meets_a_github_limit_writes_the_pause_and_ends_the_tick(t, capsys):
    t.stamp(None)
    t.clone.quick("hs-done", 9, 61)
    t.seed.fail_times("adapter_prs_merged", 1, API_LIMIT)
    done_pr(t, 40, "open", "CONFLICTING")

    assert t.tick() == 0
    assert t.text("github-limit") is not None
    assert t.labels(40) == ["orch:done"]


# --- the pause files' format -------------------------------------------------------

GOLDEN = Path(__file__).resolve().parent / "github_pause" / "github-limit"


def test_a_limit_the_tick_meets_and_an_early_pause_match_the_github_pause_golden_file(t):
    # The golden file holds GOLDEN_NOW + 1800 as a pause file holds it.
    import conftest

    t.clock = lambda: conftest.NOW
    t.seed.quota("graphql", 1, 5000, conftest.NOW + 1800)
    t.tick()
    assert Path(t.path("github-early-graphql")).read_bytes() == GOLDEN.read_bytes()

    t.seed.ratelimit()
    Path(t.store, "quota").write_text("core\t0\t5000\t%d\n" % (conftest.NOW + 1800))
    assert t.tick() == 1
    assert Path(t.path("github-limit")).read_bytes() == GOLDEN.read_bytes()


# --- the tick's directory ----------------------------------------------------------


def test_a_tick_started_in_a_subdirectory_works_from_the_main_checkout(t, tmp_path):
    sub = tmp_path / "sub" / "dir"
    sub.mkdir(parents=True)
    os.chdir(sub)
    t.stamp(None)
    t.clone.quick("hs-done", 9, 61)

    assert t.tick() == 0
    assert os.getcwd() == t.main
    assert t.text("housekeeping") == "%d\n" % NOW
    assert not (sub / ".orchestrator").exists()
    assert os.path.isabs(autopilot.orch_sh()) and os.path.isfile(autopilot.orch_sh())


def test_a_main_checkout_that_cannot_be_read_dies_before_any_github_call(t, capsys):
    t.git.seed("main_checkout", answer=None)

    assert t.tick() == 1
    assert t.gh.claim_reads == 0
