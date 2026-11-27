"""The doctor noun, driven through doctor.run as orch.sh hands it its
arguments: its report on stdout - each group under its header, every check's
ok, warn and FAIL line and its remedies, the skip report and the tally - and
its exit code. The tools it looks for are stubs on a PATH under tmp_path, the
checkout a FakeGit, and GitHub the gh fake on its store."""
from __future__ import annotations

import os
import platform
import re
import subprocess
import time
from pathlib import Path

import pytest

from conftest import (GH_502, died_of, exclude_orchestrator, git_repo, hold_flow, record,
                      run_git)
from orch import cli, doctor
from orch.autopilot import epoch_iso
from orch.gh_fake import FakeGh
from orch.git import FakeGit, Worktree
from orch.repo import REPO_CAUSE, REPO_MISSING, RepoPin
from orch.review import MALFORMED_SHAPE
from orch.triage_labels import TRIAGE_ROLES

ORIGIN = "https://github.com/acme/widgets.git"
RUNNING_BASH = "5.2.21"
INDENT = "      "
TOOLS = ("git", "gh", "jq")
# The plugin root a run reports from, under the HOME it runs with, and the
# setup doc its remedies name.
HOME = "home"
PLUGIN = "home/plugin"
EXCLUDED = ".orchestrator/\n.scratch/\n"


def stub_path(tmp_path, *names, bash_prints=None):
    """A PATH holding only an executable stub for each of <names>, and a
    `bash` printing <bash_prints> when one is given."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    stubs = {name: "exit 0" for name in names}
    if bash_prints is not None:
        stubs["bash"] = "printf '%%s\\n' '%s'" % bash_prints
    for name, body in stubs.items():
        stub = bin_dir / name
        stub.write_text("#!/bin/sh\n%s\n" % body)
        stub.chmod(0o755)
    return str(bin_dir)


def checkout_git(tmp_path, origin=ORIGIN, origin_head=None, exclude=EXCLUDED, **kwargs):
    """A FakeGit checkout at tmp_path, <origin> its origin remote (none when
    None) and origin/HEAD naming <origin_head>; main, develop and trunk are
    branch names. Its common directory is tmp_path/git-dir, its info/exclude
    holding <exclude> (none when None); <kwargs> go to FakeGit. Its working
    tree is clean, and it is the clone's one worktree."""
    git = FakeGit(remotes={} if origin is None else {"origin": origin}, toplevel=str(tmp_path),
                  **kwargs)
    for name in ("main", "develop", "trunk"):
        git.seed("is_branch_name", name, answer=True)
    git.seed("origin_head_branch", answer=origin_head)
    common = tmp_path / "git-dir"
    (common / "info").mkdir(parents=True, exist_ok=True)
    if exclude is not None:
        (common / "info" / "exclude").write_text(exclude)
    git.seed("git_common_dir", answer=str(common))
    git.seed("dirty_paths", answer=[])
    git.seed("worktree_list", answer=[Worktree(str(tmp_path), "main")])
    return git


def healthy(seed):
    """The GitHub a healthy repo has for doctor: default branch main, every
    canonical triage label, and one issue for the sub-issues probe to ask
    about."""
    seed.default_branch("main\n")
    seed.label_names(*TRIAGE_ROLES)
    seed.issue(1, "open")


def doctor_env(tmp_path, *tools, **extra):
    """The environment a run takes: a PATH of stubs for <tools> (git, gh and
    jq when none are named), the bash orch.sh ran under, HOME, and <extra>."""
    env = {"PATH": stub_path(tmp_path, *(tools or TOOLS)), "ORCH_RUNNING_BASH": RUNNING_BASH,
           "HOME": str(tmp_path / HOME)}
    env.update(extra)
    return env


def no_ssh_lookup(host):
    return host


class Run:
    """One doctor.run: its exit code, its stdout and the gh fake it ran on."""

    def __init__(self, code, out, gh):
        self.code = code
        self.out = out
        self.gh = gh

    def group(self, title):
        """The group under <title>: its header and every line up to the blank
        line ending it."""
        lines = self.out.split("\n")
        start = lines.index(title)
        end = lines.index("", start)
        return "\n".join(lines[start:end]) + "\n"

    def last(self):
        return self.out.rstrip("\n").split("\n")[-1]


def orch_doctor(capsys, seed, tmp_path, *argv, git=None, env=None, gh_class=FakeGh,
                ssh_lookup=no_ssh_lookup, plugin=None, err=""):
    """`orch.sh doctor <argv>` in-process in the checkout <git> (checkout_git's
    when None), under <env> (doctor_env's when None), the gh fake of
    <gh_class> on <seed>'s store pinned to the checkout's repo, run from the
    plugin root <plugin> (tmp_path/PLUGIN when None), printing <err> on
    stderr."""
    git = checkout_git(tmp_path) if git is None else git
    env = doctor_env(tmp_path) if env is None else env
    if plugin is None:
        plugin = str(tmp_path / PLUGIN)
        os.makedirs(plugin, exist_ok=True)
    pin = RepoPin(env, git, ssh_lookup=ssh_lookup)
    gh = gh_class(seed.store, env, pin=pin, sleep=lambda _: None)
    code = doctor.run(list(argv), gh=gh, git=git, env=env, pin=pin, plugin=plugin)
    out, printed = capsys.readouterr()
    assert printed == err
    return Run(code, out, gh)


# --- arguments ----------------------------------------------------------------


@pytest.mark.parametrize("argv, message", [
    (["--env", "--flow"], "orch: usage: orch.sh doctor [--env|--flow]\n"),
    (["--nonsense"], "orch: unknown doctor flag: --nonsense (want --env or --flow)\n"),
])
def test_doctor_refuses_an_extra_argument_and_an_unknown_flag(
        capsys, seed, tmp_path, argv, message):
    git = checkout_git(tmp_path)
    env = {"PATH": stub_path(tmp_path, *TOOLS)}

    assert died_of(capsys, lambda: doctor.run(argv, gh=FakeGh(seed.store, env), git=git,
                                              env=env)) == (1, "", message)


def test_the_cli_runs_doctor_with_its_arguments(capsys):
    assert died_of(capsys, lambda: cli.main(["doctor", "--nonsense"])) == (
        1, "", "orch: unknown doctor flag: --nonsense (want --env or --flow)\n")


def cli_answer(capsys, argv):
    """cli.main(<argv>)'s exit code, a SystemExit's included, stdout and
    stderr."""
    try:
        code = cli.main(argv)
    except SystemExit as died:
        code = died.code
    out, err = capsys.readouterr()
    return code, out, err


@pytest.mark.parametrize("argv", [["--env"], ["--flow"], ["--nonsense"], ["--env", "--flow"]],
                         ids=["env", "flow", "unknown-flag", "extra-argument"])
def test_health_answers_every_argument_as_doctor_does(capsys, seed, tmp_path, monkeypatch, argv):
    healthy(seed)
    repo = tmp_path / "repo"
    git_repo(repo, ORIGIN)
    hold_flow(repo, slug="x", phase="spec", issue=1)
    monkeypatch.chdir(str(repo))
    for name, value in (("ORCH_GH_FAKE_STORE", seed.store), ("HOME", str(tmp_path / HOME)),
                        ("ORCH_RUNNING_BASH", RUNNING_BASH)):
        monkeypatch.setenv(name, value)

    doctor_said = cli_answer(capsys, ["doctor", *argv])

    assert doctor_said[0] in (0, 1) and (doctor_said[1] or doctor_said[2])
    assert cli_answer(capsys, ["health", *argv]) == doctor_said


@pytest.mark.parametrize("argv", [[], [""], ["--env"]])
def test_doctor_and_doctor_env_run_the_environment_groups(capsys, seed, tmp_path, argv):
    healthy(seed)

    run = orch_doctor(capsys, seed, tmp_path, *argv)

    assert run.out.startswith("tools\n")
    assert run.code == 0


def test_doctor_flow_runs_no_environment_group(capsys, seed, tmp_path):
    flow(tmp_path)

    run = orch_doctor(capsys, seed, tmp_path, "--flow")

    assert run.out.startswith("flow state\n")
    assert run.code == 0


def test_doctor_outside_a_checkout_dies_as_orch_sh_does(capsys, seed, tmp_path, monkeypatch):
    monkeypatch.chdir(str(tmp_path))
    env = {"PATH": stub_path(tmp_path, *TOOLS)}

    code, out, err = died_of(capsys, lambda: doctor.run(
        [], gh=FakeGh(seed.store, env), git=FakeGit(), env=env))

    assert (code, out) == (1, "")
    assert err.startswith("orch: not inside a git repository")


# --- tools --------------------------------------------------------------------


def python3_line():
    return "ok    python3 " + platform.python_version()


def test_the_tools_group_finds_git_gh_jq_python3_and_the_running_bash(capsys, seed, tmp_path):
    healthy(seed)

    assert orch_doctor(capsys, seed, tmp_path).group("tools") == "\n".join([
        "tools",
        "ok    git present",
        "ok    gh present",
        "ok    jq present",
        python3_line(),
        "ok    bash " + RUNNING_BASH,
    ]) + "\n"


def test_each_missing_tool_fails_with_its_install_remedy(capsys, seed, tmp_path):
    env = {"PATH": stub_path(tmp_path), "ORCH_RUNNING_BASH": RUNNING_BASH,
           "HOME": str(tmp_path / HOME)}

    run = orch_doctor(capsys, seed, tmp_path, "--env", env=env)

    assert run.group("tools") == "\n".join([
        "tools",
        "FAIL  git not found.",
        INDENT + "brew install git    # or your platform's package manager",
        "FAIL  gh not found - the spec phase publishes the issue and the PR through it.",
        INDENT + "brew install gh    # or your platform's package manager",
        "FAIL  jq not found - orch.sh reads and writes state.json with it.",
        INDENT + "brew install jq    # or your platform's package manager",
        python3_line(),
        "ok    bash " + RUNNING_BASH,
    ]) + "\n"
    assert run.code == 1


def test_the_bash_check_asks_the_bash_on_path_when_orch_sh_named_none(capsys, seed, tmp_path):
    healthy(seed)
    env = doctor_env(tmp_path, *TOOLS, PATH=stub_path(tmp_path, *TOOLS, bash_prints="4.4.23"))
    del env["ORCH_RUNNING_BASH"]

    run = orch_doctor(capsys, seed, tmp_path, "--env", env=env)

    assert run.group("tools").endswith("ok    bash 4.4.23\n")


# --- auth & remotes -------------------------------------------------------------


def test_the_auth_group_names_origin_the_login_the_repo_and_github_s_default_branch(
        capsys, seed, tmp_path):
    healthy(seed)

    run = orch_doctor(capsys, seed, tmp_path)

    assert run.group("auth & remotes") == "\n".join([
        "auth & remotes",
        "ok    origin: " + ORIGIN,
        "ok    gh authenticated",
        "ok    repo: acme/widgets (origin)",
        "ok    default branch: main (from GitHub)",
    ]) + "\n"
    assert "skipped" not in run.out


def test_the_repo_line_names_gh_repo_when_the_caller_set_it(capsys, seed, tmp_path):
    healthy(seed)
    env = doctor_env(tmp_path, GH_REPO="fork/widgets")

    run = orch_doctor(capsys, seed, tmp_path, env=env)

    assert "ok    repo: fork/widgets (GH_REPO)\n" in run.group("auth & remotes")


def test_no_origin_and_no_repo_fail_with_their_remedies_and_skip_github_unasked(
        capsys, seed, tmp_path):
    healthy(seed)

    run = orch_doctor(capsys, seed, tmp_path, git=checkout_git(tmp_path, origin=None),
                      gh_class=GhReads)

    assert run.group("auth & remotes") == "\n".join([
        "auth & remotes",
        "FAIL  no origin remote - the flow pushes the branch and opens the PR there.",
        INDENT + "git remote add origin https://github.com/<owner>/<repo>.git",
        "FAIL  " + REPO_CAUSE,
        INDENT + "export GH_REPO=<owner>/<repo>",
    ]) + "\n"
    assert run.group("skipped") == (
        "skipped\nwarn  4 GitHub checks skipped: %s\n" % REPO_MISSING)
    assert run.gh.asked == []
    assert run.code == 1


def test_offline_the_github_checks_are_skipped_on_one_line_never_failed(
        capsys, seed, tmp_path):
    healthy(seed)
    seed.offline()

    run = orch_doctor(capsys, seed, tmp_path)

    assert run.group("auth & remotes") == "\n".join([
        "auth & remotes",
        "ok    origin: " + ORIGIN,
        "ok    repo: acme/widgets (origin)",
    ]) + "\n"
    assert "\n\nskipped\nwarn  5 GitHub checks skipped: GitHub is not reachable\n\n" in run.out
    assert "FAIL  " not in run.out
    assert run.code == 0


def test_without_gh_the_github_checks_are_skipped_naming_it(capsys, seed, tmp_path):
    env = doctor_env(tmp_path, "git", "jq")

    run = orch_doctor(capsys, seed, tmp_path, env=env)

    assert run.group("skipped") == "skipped\nwarn  5 GitHub checks skipped: gh is not installed\n"


@pytest.mark.parametrize("extra, host", [
    ({}, "github.com"),
    ({"GH_REPO": "ghe.example.com/acme/widgets"}, "ghe.example.com"),
    ({"GH_HOST": "other.example.com"}, "github.com"),
    ({"GH_REPO": "acme/widgets", "GH_HOST": "ghe.example.com"}, "ghe.example.com"),
])
def test_an_unauthenticated_gh_fails_naming_the_host_gh_targets(
        capsys, seed, tmp_path, extra, host):
    healthy(seed)
    seed.noauth()
    env = doctor_env(tmp_path, **extra)

    run = orch_doctor(capsys, seed, tmp_path, env=env)

    assert ("FAIL  gh is not authenticated to %s.\n%sgh auth login --hostname %s\n"
            % (host, INDENT, host)) in run.group("auth & remotes")
    assert run.group("skipped") == "skipped\nwarn  4 GitHub checks skipped: not authenticated\n"
    assert run.code == 1


HINT = "came from origin's SSH URL and may be an SSH Host alias."


@pytest.mark.parametrize("origin", [
    "git@github-work:acme/widgets.git",
    "ssh://git@github-work/acme/widgets.git",
])
def test_an_ssh_alias_origin_gets_the_alias_hint_beside_the_auth_fail(
        capsys, seed, tmp_path, origin):
    seed.noauth()

    run = orch_doctor(capsys, seed, tmp_path, git=checkout_git(tmp_path, origin=origin))

    assert run.group("auth & remotes").startswith("\n".join([
        "auth & remotes",
        "ok    origin: " + origin,
        "FAIL  gh is not authenticated to github-work.",
        INDENT + "gh auth login --hostname github-work",
        "warn  the host github-work " + HINT,
        INDENT + "export GH_REPO=acme/widgets",
        "ok    repo: github-work/acme/widgets (origin)",
    ]) + "\n")


def test_offline_an_ssh_alias_origin_keeps_its_skip_and_gets_the_hint(capsys, seed, tmp_path):
    seed.offline()

    run = orch_doctor(capsys, seed, tmp_path,
                      git=checkout_git(tmp_path, origin="git@github-work:acme/widgets.git"))

    assert "warn  the host github-work " + HINT in run.out
    assert "skipped: GitHub is not reachable" in run.out
    assert "FAIL  " not in run.out
    assert run.code == 0


@pytest.mark.parametrize("origin, extra, lookup", [
    ("https://ghe.example.com/acme/widgets.git", {}, no_ssh_lookup),
    ("ssh://git@github-work/acme/widgets.git", {"GH_REPO": "acme/widgets"}, no_ssh_lookup),
    ("git@github-work:acme/widgets.git", {}, lambda host: "github.com"),
])
def test_no_alias_hint_without_an_untranslated_ssh_origin_host(
        capsys, seed, tmp_path, origin, extra, lookup):
    seed.noauth()
    env = doctor_env(tmp_path, **extra)

    run = orch_doctor(capsys, seed, tmp_path, git=checkout_git(tmp_path, origin=origin), env=env,
                      ssh_lookup=lookup)

    assert HINT not in run.out
    assert "FAIL  gh is not authenticated to " in run.out


def test_a_passing_probe_gives_no_alias_hint(capsys, seed, tmp_path):
    healthy(seed)

    run = orch_doctor(capsys, seed, tmp_path,
                      git=checkout_git(tmp_path, origin="git@ghe.example.com:acme/widgets.git"))

    assert HINT not in run.out
    assert "ok    gh authenticated\n" in run.out


def test_a_differing_gh_default_repo_warns_and_a_matching_one_says_nothing(
        capsys, seed, tmp_path):
    healthy(seed)
    seed.local_default("upstream/widgets")

    differing = orch_doctor(capsys, seed, tmp_path)
    seed.local_default("acme/widgets")
    matching = orch_doctor(capsys, seed, tmp_path)

    assert ("ok    repo: acme/widgets (origin)\n"
            "warn  gh's default repo is upstream/widgets; the orchestrator uses acme/widgets\n"
            ) in differing.group("auth & remotes")
    assert differing.code == 0
    assert "gh's default repo" not in matching.out


def test_a_matching_gh_default_repo_on_another_host_says_nothing(capsys, seed, tmp_path):
    healthy(seed)
    seed.local_default("acme/widgets")
    env = doctor_env(tmp_path, GH_REPO="ghe.example.com/acme/widgets")

    assert "gh's default repo" not in orch_doctor(capsys, seed, tmp_path, env=env).out


@pytest.mark.parametrize("stderr, reason", [
    ("HTTP 404: Not Found\nsecond line", "HTTP 404: Not Found"),
    ("", "gh gave no reason"),
])
def test_a_repo_github_will_not_show_fails_with_gh_s_first_line(
        capsys, seed, tmp_path, stderr, reason):
    seed.fail("adapter_repo_default_branch", stderr)

    run = orch_doctor(capsys, seed, tmp_path)

    assert run.group("auth & remotes").endswith(
        "ok    repo: acme/widgets (origin)\n"
        "FAIL  GitHub cannot see acme/widgets - origin may point somewhere you cannot see: %s\n"
        "%sgit remote set-url origin https://github.com/<owner>/<repo>.git\n" % (reason, INDENT))
    assert run.code == 1


@pytest.mark.parametrize("answer, origin_head, fallback", [
    ("\n", "develop", "develop"),
    ("mise ~/.config/mise/config.toml tools: gh@2.102.0\nmain\n", "develop", "develop"),
    ("\n", None, "main"),
])
def test_a_default_branch_github_did_not_name_warns_with_the_local_fallback(
        capsys, seed, tmp_path, answer, origin_head, fallback):
    healthy(seed)
    seed.default_branch(answer)

    run = orch_doctor(capsys, seed, tmp_path,
                      git=checkout_git(tmp_path, origin_head=origin_head))

    assert run.group("auth & remotes").endswith(
        "warn  default branch not resolved from GitHub - falling back to %s.\n"
        "%sgit remote set-head origin --auto\n" % (fallback, INDENT))
    assert "mise" not in run.out
    assert run.code == 0


class GhReads(FakeGh):
    """The gh fake, keeping each GitHub read doctor makes, in order, in
    asked."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.asked = []

    def auth_status(self, host):
        self.asked.append("auth_status")
        return super().auth_status(host)

    def repo_default_branch(self, repo):
        self.asked.append("repo_default_branch")
        return super().repo_default_branch(repo)

    def labels(self, limit):
        self.asked.append("labels")
        return super().labels(limit)

    def sub_issues_supported(self):
        self.asked.append("sub_issues_supported")
        return super().sub_issues_supported()


@pytest.mark.parametrize("prepare", [healthy, lambda seed: seed.default_branch("\n"),
                                     lambda seed: seed.fail("adapter_repo_default_branch")])
def test_doctor_asks_github_each_answer_once_per_run(capsys, seed, tmp_path, prepare):
    prepare(seed)

    run = orch_doctor(capsys, seed, tmp_path, gh_class=GhReads)

    assert run.gh.asked == ["auth_status", "repo_default_branch", "labels",
                            "sub_issues_supported"]


def test_unauthenticated_doctor_never_reads_the_default_branch(capsys, seed, tmp_path):
    healthy(seed)
    seed.noauth()

    run = orch_doctor(capsys, seed, tmp_path, gh_class=GhReads)

    assert run.gh.asked == ["auth_status"]


# --- plugin environment ---------------------------------------------------------

CAPABILITIES = """# Host capabilities

| Capability | Claude Code | Junie CLI | Antigravity CLI |
| --- | --- | --- | --- |
| Invoke a skill from a step | The Skill tool. | None. **Fallback**. | None. **Fallback**. |
| Run a long command | Bash. | Unknown. **Unverified**. | Its shell. |
| Start a fresh session | /clear. | None. **Fallback**. | Unknown. **Unverified**. |
"""
HOST_REMEDY = INDENT + "export ORCHESTRATOR_HOST=claude    # or junie, antigravity"
REPO_ROOT = Path(__file__).resolve().parents[3]


def capabilities_plugin(tmp_path):
    """The plugin root, its capabilities reference CAPABILITIES."""
    plugin = tmp_path / PLUGIN
    (plugin / "docs").mkdir(parents=True, exist_ok=True)
    (plugin / "docs" / "host-capabilities.md").write_text(CAPABILITIES)
    return str(plugin)


ORCH_SH_OK = "ok    orch.sh: ~/plugin/scripts/orch.sh"


@pytest.mark.parametrize("extra, lines", [
    ({"CLAUDECODE": "1", "CLAUDE_PLUGIN_ROOT": "/p"}, [
        "ok    host: Claude Code",
        "ok    CLAUDE_PLUGIN_ROOT set",
    ]),
    ({"CLAUDECODE": "1"}, [
        "ok    host: Claude Code",
        "warn  CLAUDE_PLUGIN_ROOT is not set under Claude Code - orch.sh was run by hand, not"
        " through a plugin command.",
    ]),
    ({"JUNIE_EXTENSION_ROOT": "/j"}, [
        "warn  host: Junie CLI lacks: Invoke a skill from a step, Start a fresh session;"
        " unverified: Run a long command - fallbacks in docs/host-capabilities.md",
        "ok    CLAUDE_PLUGIN_ROOT unset - Junie expands it only in hooks; skills use the"
        " relative path.",
    ]),
    ({"ANTIGRAVITY_AGENT": "1"}, [
        "warn  host: Antigravity CLI lacks: Invoke a skill from a step; unverified: Start a"
        " fresh session - fallbacks in docs/host-capabilities.md",
        "ok    CLAUDE_PLUGIN_ROOT unset - Antigravity sets PLUGIN_ROOT only in hooks; skills use"
        " the relative path.",
    ]),
    ({}, [
        "warn  host not detected - which capabilities are missing is unknown.",
        HOST_REMEDY,
        "ok    CLAUDE_PLUGIN_ROOT unset - only Claude Code sets it; skills use the relative"
        " path.",
    ]),
    ({"ORCHESTRATOR_HOST": "vim", "CLAUDECODE": "1"}, [
        "warn  ORCHESTRATOR_HOST=vim names no supported host.",
        HOST_REMEDY,
        "ok    CLAUDE_PLUGIN_ROOT unset - only Claude Code sets it; skills use the relative"
        " path.",
    ]),
])
def test_the_plugin_environment_group_names_the_host_its_gaps_and_its_plugin_root(
        capsys, seed, tmp_path, extra, lines):
    healthy(seed)
    plugin = capabilities_plugin(tmp_path)

    run = orch_doctor(capsys, seed, tmp_path, "--env", env=doctor_env(tmp_path, **extra),
                      plugin=plugin)

    assert run.group("plugin environment") == "\n".join(
        ["plugin environment", *lines, ORCH_SH_OK]) + "\n"


def test_a_host_with_only_unverified_capabilities_is_warned_of_them_alone(
        capsys, seed, tmp_path):
    plugin = capabilities_plugin(tmp_path)
    reference = Path(plugin) / "docs" / "host-capabilities.md"
    reference.write_text(CAPABILITIES.replace("| None. **Fallback**. |\n", "| None. |\n"))

    run = orch_doctor(capsys, seed, tmp_path, "--env",
                      env=doctor_env(tmp_path, ANTIGRAVITY_AGENT="1"), plugin=plugin)

    assert ("warn  host: Antigravity CLI unverified: Start a fresh session - fallbacks in"
            " docs/host-capabilities.md\n") in run.out


def test_the_host_gaps_are_read_from_the_plugin_s_own_reference(capsys, seed, tmp_path):
    claude = orch_doctor(capsys, seed, tmp_path, "--env",
                         env=doctor_env(tmp_path, CLAUDECODE="1"), plugin=str(REPO_ROOT))
    junie = orch_doctor(capsys, seed, tmp_path, "--env",
                        env=doctor_env(tmp_path, JUNIE_SHIM_PATH="/j"), plugin=str(REPO_ROOT))

    assert "ok    host: Claude Code\n" in claude.out
    lacks = re.search(r"^warn  host: Junie CLI lacks: ([^;]*);", junie.out, re.M).group(1)
    assert "Start a fresh subagent" in lacks.split(", ")


def test_doctor_names_the_orch_sh_of_its_own_plugin_root_by_default(capsys, seed, tmp_path):
    git = checkout_git(tmp_path)
    env = doctor_env(tmp_path)

    doctor.run(["--env"], gh=FakeGh(seed.store, env, pin=RepoPin(env, git)), git=git, env=env)

    assert "ok    orch.sh: %s/scripts/orch.sh\n" % REPO_ROOT in capsys.readouterr().out


def skill(tmp_path, store, name):
    """A skill folder <name> holding a SKILL.md in the user-level skill store
    <store>, under HOME."""
    folder = tmp_path / HOME / store / name
    folder.mkdir(parents=True)
    (folder / "SKILL.md").write_text("---\nname: %s\n---\n" % name)
    return folder


ALL_INSTALLS = [
    "Claude Code: /plugin marketplace add maj0rpain/orchestrator",
    "             /plugin install orchestrator@orchestrator",
    "Junie:       install maj0rpain/orchestrator as a Junie extension (unverified)",
    "Antigravity: agy plugin install <path-to-orchestrator-clone>",
    "then remove the skills-only copy named above.",
]


def test_skills_only_copies_warn_once_per_store_with_every_host_s_install(
        capsys, seed, tmp_path):
    skill(tmp_path, ".agents/skills", "orch-flow")
    skill(tmp_path, ".agents/skills", "orch-review")
    skill(tmp_path, ".claude/skills", "orch-flow")
    skill(tmp_path, ".gemini/config/skills", "orch-spec")
    skill(tmp_path, ".junie/skills", "orch-review")
    skill(tmp_path, ".claude/skills", "other-skill")
    (tmp_path / HOME / ".claude/skills/orch-empty").mkdir()

    run = orch_doctor(capsys, seed, tmp_path, "--env")

    assert run.group("plugin environment").endswith("\n".join([
        "warn  orch.sh missing beside the orchestrator skills in ~/.agents/skills: orch-flow,"
        " orch-review - a skills-only install.",
        "warn  orch.sh missing beside the orchestrator skills in ~/.claude/skills: orch-flow"
        " - a skills-only install.",
        "warn  orch.sh missing beside the orchestrator skills in ~/.gemini/config/skills:"
        " orch-spec - a skills-only install.",
    ] + [INDENT + line for line in ALL_INSTALLS]) + "\n")


@pytest.mark.parametrize("extra, installs", [
    ({"CLAUDECODE": "1"}, [ALL_INSTALLS[0], ALL_INSTALLS[1], ALL_INSTALLS[4]]),
    ({"JUNIE_EXTENSION_ROOT": "/j"}, [ALL_INSTALLS[2], ALL_INSTALLS[4]]),
    ({"ANTIGRAVITY_AGENT": "1"}, [ALL_INSTALLS[3], ALL_INSTALLS[4]]),
])
def test_a_skills_only_copy_s_remedy_names_only_the_detected_host_s_install(
        capsys, seed, tmp_path, extra, installs):
    skill(tmp_path, ".agents/skills", "orch-flow")

    run = orch_doctor(capsys, seed, tmp_path, "--env", env=doctor_env(tmp_path, **extra))

    assert run.group("plugin environment").endswith("\n".join(
        ["warn  orch.sh missing beside the orchestrator skills in ~/.agents/skills: orch-flow"
         " - a skills-only install."] + [INDENT + line for line in installs]) + "\n")


def test_a_copy_linked_into_a_second_store_is_reported_once_where_it_lives(
        capsys, seed, tmp_path):
    skill(tmp_path, ".agents/skills", "orch-review")
    (tmp_path / HOME / ".claude/skills").mkdir(parents=True)
    os.symlink("../../.agents/skills/orch-review", str(tmp_path / HOME / ".claude/skills/orch-review"))

    run = orch_doctor(capsys, seed, tmp_path, "--env")

    assert run.out.count("orch.sh missing") == 1
    assert "skills in ~/.agents/skills: orch-review - " in run.out


def test_a_skill_linked_from_a_full_checkout_is_no_skills_only_copy(capsys, seed, tmp_path):
    full = tmp_path / "full"
    (full / "scripts").mkdir(parents=True)
    (full / "scripts" / "orch.sh").write_text("")
    real = skill(tmp_path, "../full/skills", "orch-flow")
    (tmp_path / HOME / ".claude/skills").mkdir(parents=True)
    os.symlink(str(real), str(tmp_path / HOME / ".claude/skills/orch-flow"))

    run = orch_doctor(capsys, seed, tmp_path, "--env")

    assert "orch.sh missing" not in run.out
    assert ORCH_SH_OK + "\n" in run.out


# --- repo config: triage labels -------------------------------------------------

LABELS_DOC = "docs/agents/triage-labels.md"


def labels_doc(tmp_path, *rows):
    """The checkout's triage-labels doc: a role table of <rows>, each a
    (role, label) pair."""
    doc = tmp_path / LABELS_DOC
    doc.parent.mkdir(parents=True, exist_ok=True)
    doc.write_text("\n".join(["# Triage Labels", "", "| Role | Label | Meaning |",
                              "| --- | --- | --- |"]
                             + ["| `%s` | `%s` | m |" % row for row in rows]) + "\n")


def repo_config(run):
    return run.group("repo config")


def test_a_healthy_repo_s_labels_doc_and_labels_report_ok(capsys, seed, tmp_path):
    healthy(seed)

    run = orch_doctor(capsys, seed, tmp_path)

    assert repo_config(run).startswith("\n".join([
        "repo config",
        "ok    no docs/agents/triage-labels.md - the canonical triage label names apply",
        "ok    every triage label exists on the repo",
    ]) + "\n")


def test_a_documented_label_missing_from_the_repo_fails_with_its_create_command(
        capsys, seed, tmp_path):
    healthy(seed)
    seed.label_names("needs-triage")
    labels_doc(tmp_path, ("needs-triage", "needs-triage"), ("needs-info", "needs info"),
               ("ready-for-agent", "agent go"))

    run = orch_doctor(capsys, seed, tmp_path)

    assert repo_config(run).startswith("\n".join([
        "repo config",
        "ok    3 triage labels documented in docs/agents/triage-labels.md",
        "FAIL  triage labels missing from the repo: needs info, agent go",
        INDENT + 'gh label create "needs info"',
        INDENT + 'gh label create "agent go"',
    ]) + "\n")
    assert run.code == 1


def test_with_no_labels_doc_the_canonical_names_are_checked(capsys, seed, tmp_path):
    healthy(seed)
    seed.label_names("needs-triage")

    run = orch_doctor(capsys, seed, tmp_path)

    assert ("FAIL  triage labels missing from the repo: needs-info, ready-for-agent,"
            " ready-for-human, wontfix\n") in run.out
    assert 'gh label create "needs-triage"' not in run.out
    assert run.out.count("gh label create") == 4


def test_a_triage_label_the_repo_holds_in_another_casing_exists(capsys, seed, tmp_path):
    healthy(seed)
    seed.label_names("Needs-Triage", "READY-for-agent")
    labels_doc(tmp_path, ("needs-triage", "needs-triage"), ("ready-for-agent", "ready-for-agent"))

    run = orch_doctor(capsys, seed, tmp_path)

    assert "ok    every triage label exists on the repo\n" in run.out
    assert run.code == 0


def test_a_labels_doc_that_lists_no_labels_fails_once_and_asks_github_nothing(
        capsys, seed, tmp_path):
    healthy(seed)
    doc = tmp_path / LABELS_DOC
    doc.parent.mkdir(parents=True)
    doc.write_text("# Triage Labels\n\nThis repo does not use a table.\n")

    run = orch_doctor(capsys, seed, tmp_path, gh_class=GhReads)

    assert repo_config(run).startswith("\n".join([
        "repo config",
        "FAIL  docs/agents/triage-labels.md lists no triage labels - the spec phase labels its"
        " issue from it.",
        INDENT + "fix docs/agents/triage-labels.md's table, or delete it to use the canonical"
        " names",
        "ok    ",
    ]))
    assert "labels" not in run.gh.asked
    assert run.code == 1


@pytest.mark.parametrize("names, line", [
    ([str(n) for n in range(1, 1001)],
     "warn  the repo has more than 1000 labels - cannot confirm: needs-triage, needs-info,"
     " ready-for-agent, ready-for-human, wontfix"),
    (list(TRIAGE_ROLES) + [str(n) for n in range(1, 1001)],
     "ok    every triage label exists on the repo"),
])
def test_a_label_page_that_filled_up_only_vouches_for_the_labels_it_holds(
        capsys, seed, tmp_path, names, line):
    healthy(seed)
    seed.label_names(*names)

    run = orch_doctor(capsys, seed, tmp_path)

    assert line + "\n" in run.out
    assert run.code == 0


@pytest.mark.parametrize("fail, reason", [
    (lambda seed: seed.fail("adapter_labels", "HTTP 403: Forbidden\nsecond line"),
     "HTTP 403: Forbidden"),
    (lambda seed: seed.fail_times("adapter_labels", 5), "gh gave no reason"),
])
def test_a_label_listing_github_will_not_answer_warns_with_gh_s_reason(
        capsys, seed, tmp_path, fail, reason):
    healthy(seed)
    fail(seed)

    run = orch_doctor(capsys, seed, tmp_path)

    assert "warn  the repo's labels could not be listed: %s\n" % reason in run.out
    assert run.code == 0


# --- repo config: Standards, glossary and ADRs -----------------------------------

SETUP_REMEDY = INDENT + "see docs/repo-setup.md under the plugin root"


def write(tmp_path, name, text):
    path = tmp_path / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def line_of(run, prefix):
    """The report's line opening with <prefix>, and the remedy lines under
    it."""
    lines = run.out.split("\n")
    start = next(i for i, line in enumerate(lines) if line.startswith(prefix))
    end = start + 1
    while lines[end].startswith(INDENT):
        end += 1
    return "\n".join(lines[start:end]) + "\n"


@pytest.mark.parametrize("files, line", [
    ({}, "ok    no Standards: declaration and nothing to crawl - the reviewers apply the smell"
         " baseline alone"),
    ({"docs/rules.md": "rules\n", "CLAUDE.md": "See `docs/rules.md`.\n"},
     "ok    no Standards: declaration - the list is crawled: CLAUDE.md, docs/rules.md"),
    ({"docs/rules.md": "rules\n", "docs/more.md": "more\n",
      "CLAUDE.md": "Standards: `docs/rules.md`, `docs/more.md`\n"},
     "ok    Standards declared in CLAUDE.md: docs/rules.md, docs/more.md"),
])
def test_the_standards_check_names_the_declaration_or_the_crawl(
        capsys, seed, tmp_path, files, line):
    for name, text in files.items():
        write(tmp_path, name, text)

    run = orch_doctor(capsys, seed, tmp_path, "--env")

    assert line + "\n" in repo_config(run)


@pytest.mark.parametrize("declaration, lines", [
    ("Standards: `docs/missing.md`\n", [
        "FAIL  Standards entry `docs/missing.md` names a missing file",
        INDENT + "change the entry `docs/missing.md` in the Standards: paragraph of CLAUDE.md to"
        " a repo-relative path of a file in the repo, with at most one #Heading that matches"
        " once - or delete the paragraph to have the reviewers crawl the standards documents",
        SETUP_REMEDY,
    ]),
    ("Standards: none here\n", [
        "FAIL  CLAUDE.md declares Standards: with no entries (want backticked paths)",
        INDENT + "list backticked repo-relative paths in the Standards: paragraph of CLAUDE.md -"
        " or delete the paragraph to have the reviewers crawl the standards documents",
        SETUP_REMEDY,
    ]),
])
def test_a_rejected_standards_declaration_fails_with_the_resolution_s_own_message(
        capsys, seed, tmp_path, declaration, lines):
    healthy(seed)
    write(tmp_path, "CLAUDE.md", declaration)

    run = orch_doctor(capsys, seed, tmp_path, "--env")

    assert line_of(run, "FAIL  ") == "\n".join(lines) + "\n"
    assert run.code == 1


GLOSSARY_REMEDY = (INDENT + 'write each entry as a **Term**: line, e.g. "**Doctor**: the'
                   ' diagnostic command." (optionally after a "- " bullet)')


@pytest.mark.parametrize("glossary, lines", [
    (None, ["ok    no GLOSSARY.md - no glossary is read, so the Consistency lens reads none and"
            " the reviewers' glossary parse check does not run"]),
    ("**Alpha**: one.\n\n- **Beta**: two.\n", ["ok    2 glossary entries read from GLOSSARY.md"]),
    ("**Alpha** - one.\n\n**Beta** - two.\n", [
        "FAIL  GLOSSARY.md has no entries orch.sh can read (an entry starts at a **Term**: line,"
        " optionally bulleted)",
        GLOSSARY_REMEDY,
        SETUP_REMEDY,
    ]),
])
def test_the_glossary_check_counts_the_entries_or_fails_with_the_parse_error(
        capsys, seed, tmp_path, glossary, lines):
    healthy(seed)
    if glossary is not None:
        write(tmp_path, "GLOSSARY.md", glossary)

    run = orch_doctor(capsys, seed, tmp_path, "--env")

    assert "\n" + "\n".join(lines) + "\n" in repo_config(run)
    assert run.code == (1 if len(lines) > 1 else 0)


class NoChildProcess(Exception):
    """What starting a child process raises, in a test that allows none."""


def test_the_standards_and_glossary_checks_start_no_child_process(
        capsys, seed, tmp_path, monkeypatch):
    write(tmp_path, "docs/rules.md", "rules\n")
    write(tmp_path, "CLAUDE.md", "Standards: `docs/rules.md`\n")
    write(tmp_path, "GLOSSARY.md", "**Alpha**: one.\n")

    def refuse(*args, **kwargs):
        raise NoChildProcess()

    monkeypatch.setattr(subprocess, "Popen", refuse)

    run = orch_doctor(capsys, seed, tmp_path, "--env")

    assert "ok    Standards declared in CLAUDE.md: docs/rules.md\n" in run.out
    assert "ok    1 glossary entries read from GLOSSARY.md\n" in run.out
    assert "could not run" not in run.out


ADR_REMEDY = (INDENT + "remove docs/adr and create it as a directory of Markdown files, or delete"
              " it to have no ADRs read")


def test_the_adr_check_counts_the_markdown_files_directly_in_docs_adr(capsys, seed, tmp_path):
    absent = orch_doctor(capsys, seed, tmp_path, "--env")
    for name in ("0001-a.md", "0002-b.md", "nested/0003.md", "notes.txt", ".hidden.md"):
        write(tmp_path, "docs/adr/" + name, "x\n")

    run = orch_doctor(capsys, seed, tmp_path, "--env")

    assert "ok    no docs/adr - no ADRs are read\n" in absent.out
    assert "ok    docs/adr holds 2 ADRs\n" in run.out


@pytest.mark.parametrize("make", [
    lambda adr: adr.write_text("x\n"),
    lambda adr: os.symlink("gone", str(adr)),
])
def test_a_docs_adr_that_is_no_directory_fails(capsys, seed, tmp_path, make):
    (tmp_path / "docs").mkdir()
    make(tmp_path / "docs" / "adr")

    run = orch_doctor(capsys, seed, tmp_path, "--env")

    assert line_of(run, "FAIL  docs/adr") == "\n".join([
        "FAIL  docs/adr exists and is no directory - the skills and the spec review read ADRs"
        " from it.",
        ADR_REMEDY,
        SETUP_REMEDY,
    ]) + "\n"
    assert run.code == 1


# --- repo config: sub-issues, git exclude and the base branch ---------------------


@pytest.mark.parametrize("prepare, line", [
    (lambda seed: None, "ok    sub-issues supported"),
    (lambda seed: seed.no_sub_issues(),
     "warn  sub-issues do not appear to be supported on this GitHub instance - breakdown"
     " publish will fail at its sub-issue listing read (ticket_link) at spec time."),
    (lambda seed: seed.fail("adapter_sub_issues_supported", GH_502),
     "warn  sub-issues support could not be probed: HTTP 502: Bad Gateway"),
    (lambda seed: seed.fail_times("adapter_sub_issues_supported", 5),
     "warn  sub-issues support could not be probed: gh gave no reason"),
])
def test_the_sub_issues_probe_reports_support_and_only_ever_warns(
        capsys, seed, tmp_path, prepare, line):
    healthy(seed)
    prepare(seed)

    run = orch_doctor(capsys, seed, tmp_path)

    assert line + "\n" in repo_config(run)
    assert run.code == 0


def test_a_repo_with_no_issue_cannot_be_probed_for_sub_issues(capsys, seed, tmp_path):
    seed.default_branch("main\n")
    seed.label_names(*TRIAGE_ROLES)

    run = orch_doctor(capsys, seed, tmp_path)

    assert ("warn  sub-issues support could not be probed - the repo has no issue to test it"
            " against.\n") in repo_config(run)


EXCLUDE_TAIL = '; }>>"$(git rev-parse --git-common-dir)/info/exclude"'


@pytest.mark.parametrize("exclude, lines", [
    (EXCLUDED, ["ok    .orchestrator/, .scratch/ git-excluded"]),
    (None, ["warn  .orchestrator/, .scratch/ not git-excluded - flow state and planning drafts"
            " would show as untracked.",
            INDENT + "{ echo; printf '%s\\n' '.orchestrator/' '.scratch/' " + EXCLUDE_TAIL]),
    (".orchestrator/\n", [
        "warn  .scratch/ not git-excluded - flow state and planning drafts would show as"
        " untracked.",
        INDENT + "{ echo; printf '%s\\n' '.scratch/' " + EXCLUDE_TAIL]),
])
def test_the_git_exclude_check_names_only_the_missing_lines(
        capsys, seed, tmp_path, exclude, lines):
    healthy(seed)
    run = orch_doctor(capsys, seed, tmp_path, "--env",
                      git=checkout_git(tmp_path, exclude=exclude))

    assert "\n" + "\n".join(lines) + "\n" in repo_config(run)
    assert run.code == 0


def test_running_the_git_exclude_remedy_clears_the_warning(capsys, seed, tmp_path):
    repo = tmp_path / "clone"
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    exclude = repo / ".git" / "info" / "exclude"
    exclude.write_text("secrets.env")
    git = checkout_git(tmp_path)
    git.seed("git_common_dir", answer=str(repo / ".git"))

    remedy = line_of(orch_doctor(capsys, seed, tmp_path, "--env", git=git),
                     "warn  .orchestrator/").split("\n")[1].strip()
    subprocess.run(["bash", "-c", remedy], cwd=str(repo), check=True)
    run = orch_doctor(capsys, seed, tmp_path, "--env", git=git)

    assert exclude.read_text() == "secrets.env\n.orchestrator/\n.scratch/\n"
    assert "ok    .orchestrator/, .scratch/ git-excluded\n" in run.out


@pytest.mark.parametrize("prepare, origin_head, line", [
    (healthy, None, "ok    base branch: main (default)"),
    (lambda seed: seed.offline(), "develop", "ok    base branch: develop (default)"),
])
def test_with_no_base_setting_the_default_branch_is_the_base(
        capsys, seed, tmp_path, prepare, origin_head, line):
    prepare(seed)

    run = orch_doctor(capsys, seed, tmp_path, "--env",
                      git=checkout_git(tmp_path, origin_head=origin_head))

    assert line + "\n" in repo_config(run)


@pytest.mark.parametrize("on_origin, lines, code", [
    (True, ["ok    base branch: uat (set)"], 0),
    (False, ["FAIL  base branch uat is set but no longer exists on origin - new flows would fork"
             " from nothing.", INDENT + "orch.sh base clear", INDENT + "orch.sh base set <branch>"],
     1),
    (None, ["warn  base branch uat (set) could not be verified - origin is not reachable."], 0),
])
def test_a_set_base_branch_is_checked_on_origin(capsys, seed, tmp_path, on_origin, lines, code):
    healthy(seed)
    git = checkout_git(tmp_path, local_config={"orchestrator.base": "uat"})
    git.seed("origin_has_branch", "uat", answer=on_origin)

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=git)

    assert "\n" + "\n".join(lines) + "\n" in repo_config(run)
    assert run.code == code


# --- repo config: verification lines and commands ---------------------------------


def verification(capsys, seed, tmp_path, files, *tools):
    """The verification lines' report, every line from the Ticket
    verification's to the agent settings check's first, with <files> written
    to the checkout and <tools> stubs on PATH beside git, gh and jq."""
    for name, text in files.items():
        write(tmp_path, name, text)
    run = orch_doctor(capsys, seed, tmp_path, "--env",
                      env=doctor_env(tmp_path, *(TOOLS + tools)))
    group = repo_config(run).split("\n")
    start = next(i for i, line in enumerate(group) if "Ticket verification" in line)
    end = next(i for i, line in enumerate(group) if line.startswith("ok    agent "))
    return "\n".join(group[start:end]) + "\n"


def setup_doc(tmp_path):
    return str(tmp_path / PLUGIN / "docs" / "repo-setup.md")


NO_TICKET = "ok    no 'Ticket verification:' line - tickets run the full verification (ADR-0058)"
NO_BRANCH = ("ok    no 'Branch verification:' line - the combined-branch check runs the full"
             " verification")


def test_a_full_verification_alone_is_ok_with_its_command_and_the_fallbacks(
        capsys, seed, tmp_path):
    assert verification(capsys, seed, tmp_path, {"CLAUDE.md": "Full verification: true test\n"}
                        ) == "\n".join([
        NO_TICKET,
        "ok    Full verification: true test (CLAUDE.md)",
        "ok    Full verification command: true",
        NO_BRANCH,
    ]) + "\n"


def test_each_verification_line_is_reported_with_its_file_and_command(capsys, seed, tmp_path):
    files = {"CLAUDE.md": "Ticket verification: vctool quick\nBranch verification: vctool b\n",
             "AGENTS.md": "Full verification:   vctool all  \n"}

    assert verification(capsys, seed, tmp_path, files, "vctool") == "\n".join([
        "ok    Ticket verification: vctool quick (CLAUDE.md)",
        "ok    Ticket verification command: vctool",
        "ok    Full verification: vctool all (AGENTS.md)",
        "ok    Full verification command: vctool",
        "ok    Branch verification: vctool b (CLAUDE.md)",
        "ok    Branch verification command: vctool",
    ]) + "\n"


def test_no_full_verification_warns_with_the_line_to_add(capsys, seed, tmp_path):
    report = verification(capsys, seed, tmp_path, {})

    assert report == "\n".join([
        NO_TICKET,
        "warn  no 'Full verification:' line in CLAUDE.md, AGENTS.md or CONTRIBUTING.md - the"
        " agents' fallback is not defined by the code.",
        INDENT + "add the line 'Full verification: <command>' to CLAUDE.md - see "
        + setup_doc(tmp_path),
        NO_BRANCH,
    ]) + "\n"


@pytest.mark.parametrize("files, bare", [
    ({"CLAUDE.md": "Ticket verification:\nFull verification: true test\n"}, "CLAUDE.md"),
    ({"CLAUDE.md": "Ticket verification:  \n", "CONTRIBUTING.md": "Ticket verification: true\n"},
     "CLAUDE.md"),
    ({"CLAUDE.md": "Ticket verification: true\n", "CONTRIBUTING.md": "Ticket verification:\n"},
     "CONTRIBUTING.md"),
])
def test_a_verification_line_with_no_command_fails_as_the_label_s_only_line(
        capsys, seed, tmp_path, files, bare):
    report = verification(capsys, seed, tmp_path, files)

    assert [line for line in report.split("\n") if "Ticket verification" in line] == [
        "FAIL  %s has a 'Ticket verification:' line with no command." % bare,
        INDENT + "write the command after 'Ticket verification:' in %s, or remove the line - see %s"
        % (bare, setup_doc(tmp_path)),
    ]


@pytest.mark.parametrize("files, first, other", [
    ({"CLAUDE.md": "Ticket verification: true test\n",
      "CONTRIBUTING.md": "Ticket verification: true other\n"},
     ("true test", "CLAUDE.md"), ("true other", "CONTRIBUTING.md")),
    ({"CLAUDE.md": "Ticket verification: true a\nTicket verification: true a\n"
                   "Ticket verification: true b\nTicket verification: true c\n"},
     ("true a", "CLAUDE.md"), ("true b", "CLAUDE.md")),
])
def test_a_label_named_twice_with_different_commands_warns_and_uses_the_first(
        capsys, seed, tmp_path, files, first, other):
    report = verification(capsys, seed, tmp_path, files)

    assert report.startswith("\n".join([
        "warn  Ticket verification is named twice with different commands: '%s' in %s and '%s'"
        " in %s - the first, '%s', is the one used." % (first + other + first[:1]),
        INDENT + "remove the line 'Ticket verification: %s' from %s, or make it match - see %s"
        % (other + (setup_doc(tmp_path),)),
        "ok    Ticket verification command: true",
    ]) + "\n")


def test_verification_lines_in_a_fenced_block_or_not_opening_a_line_are_not_read(
        capsys, seed, tmp_path):
    files = {"CLAUDE.md": "```\nFull verification: make fenced\nTicket verification:\n```\n"
                          "- Ticket verification: nosuchtool\nFull verification: true test\n"}

    report = verification(capsys, seed, tmp_path, files)

    assert report.startswith(NO_TICKET + "\nok    Full verification: true test (CLAUDE.md)\n")


@pytest.mark.parametrize("command, line", [
    ("nosuchtool-3346 --all",
     "warn  Ticket verification command nosuchtool-3346 (from CLAUDE.md) is not installed."),
    ("FOO=1 BAR=2 vctool test", "ok    Ticket verification command: vctool"),
    ("`vctool test`", "ok    Ticket verification command: vctool"),
    ("scripts/vc-run.sh", "ok    Ticket verification command: scripts/vc-run.sh"),
    ("scripts/vc-missing.sh",
     "warn  Ticket verification command scripts/vc-missing.sh (from CLAUDE.md) is not"
     " installed."),
    ("scripts/vc-plain.sh",
     "warn  Ticket verification command scripts/vc-plain.sh (from CLAUDE.md) is not installed."),
    ("if true; then true; fi", "ok    Ticket verification command: if"),
    ("cd /tmp", "ok    Ticket verification command: cd"),
    ("die", "warn  Ticket verification command die (from CLAUDE.md) is not installed."),
    ("1X=2 vctool", "warn  Ticket verification command 1X=2 (from CLAUDE.md) is not installed."),
])
def test_the_first_command_word_of_a_verification_line_is_looked_up(
        capsys, seed, tmp_path, command, line):
    write(tmp_path, "scripts/vc-run.sh", "#!/bin/sh\nexit 0\n")
    (tmp_path / "scripts" / "vc-run.sh").chmod(0o755)
    write(tmp_path, "scripts/vc-plain.sh", "#!/bin/sh\nexit 0\n")

    report = verification(capsys, seed, tmp_path,
                          {"CLAUDE.md": "Ticket verification: %s\n" % command}, "vctool")

    assert report.split("\n")[1] == line


@pytest.mark.parametrize("text", ["Ticket verification: ``", "Ticket verification: FOO=1 BAR=2"])
def test_a_verification_line_leaving_no_command_word_prints_no_command_line(
        capsys, seed, tmp_path, text):
    report = verification(capsys, seed, tmp_path, {"CLAUDE.md": text + "\n"})

    assert report.split("\n")[1].startswith("warn  no 'Full verification:'")


def test_the_first_file_in_the_agents_reading_order_wins(capsys, seed, tmp_path):
    files = {"CONTRIBUTING.md": "Ticket verification: nosuchtool-c\n",
             "AGENTS.md": "Ticket verification: nosuchtool-a\n"}

    report = verification(capsys, seed, tmp_path, files)

    assert report.startswith("\n".join([
        "warn  Ticket verification is named twice with different commands: 'nosuchtool-a' in"
        " AGENTS.md and 'nosuchtool-c' in CONTRIBUTING.md - the first, 'nosuchtool-a', is the"
        " one used.",
    ]))
    assert "command nosuchtool-a (from AGENTS.md) is not installed.\n" in report
    assert "nosuchtool-c (from" not in report


# --- a check that raises, and the tally -----------------------------------------


class LocalDefaultRaises(FakeGh):
    """The gh fake, its local default read raising what no gh failure is."""

    def repo_local_default(self):
        raise RuntimeError("boom")


def test_a_check_that_raises_could_not_run_and_every_later_check_still_reports(
        capsys, seed, tmp_path):
    healthy(seed)

    run = orch_doctor(capsys, seed, tmp_path, gh_class=LocalDefaultRaises)

    assert run.group("auth & remotes").endswith(
        "ok    repo: acme/widgets (origin)\n"
        "warn  check_gh_repo could not run.\n"
        "ok    default branch: main (from GitHub)\n")
    assert run.code == 0


def tally(run):
    """The tally the report's lines add up to."""
    counts = [len(re.findall(r"^%s" % re.escape(word), run.out, re.M))
              for word in ("ok    ", "warn  ", "FAIL  ")]
    return "%d ok, %d warn, %d FAIL" % tuple(counts)


@pytest.mark.parametrize("prepare, code", [
    (healthy, 0),
    (lambda seed: (healthy(seed), seed.local_default("upstream/widgets")), 0),
    (lambda seed: (healthy(seed), seed.offline()), 0),
    (lambda seed: seed.noauth(), 1),
])
def test_the_tally_counts_each_severity_and_only_a_fail_fails_doctor(
        capsys, seed, tmp_path, prepare, code):
    prepare(seed)

    run = orch_doctor(capsys, seed, tmp_path)

    assert run.out.endswith("\n\n" + tally(run) + "\n")
    assert run.code == code


# --- flow state -----------------------------------------------------------------

CLAUDE_ABORT = "/orchestrator:abort"


def test_bare_doctor_with_no_flow_states_there_is_none(capsys, seed, tmp_path):
    healthy(seed)

    run = orch_doctor(capsys, seed, tmp_path)

    assert run.group("flow state") == "flow state\nok    no active flow\n"
    assert run.code == 0


def test_doctor_flow_with_no_flow_refuses_to_answer(capsys, seed, tmp_path):
    env = {"PATH": stub_path(tmp_path, *TOOLS), "ORCHESTRATOR_HOST": "claude"}

    assert died_of(capsys, lambda: doctor.run(["--flow"], gh=FakeGh(seed.store, env),
                                              git=checkout_git(tmp_path), env=env)) == (
        1, "", "orch: no active flow (.orchestrator/state.json not found)."
               " Run /orchestrator:start first.\n")


def flow_env(tmp_path, *tools, **extra):
    """doctor_env's environment on Claude Code, <extra> added."""
    return doctor_env(tmp_path, *tools, **dict({"ORCHESTRATOR_HOST": "claude"}, **extra))


# Each handoff's required sections, as a complete one holds them.
HANDOFF_SECTIONS = {
    "01-plan.md": ("Decisions", "Rejected alternatives", "Constraints", "Open assumptions"),
    "02-spec.md": ("Spec issue",),
    "03-implement.md": ("PR", "Spec issue", "Base SHA", "Deviations", "Verification"),
}
# The handoffs a flow at each phase has written.
HANDOFFS_AT = {
    "spec": ("01-plan.md",),
    "implement": ("01-plan.md", "02-spec.md"),
    "review": ("01-plan.md", "02-spec.md", "03-implement.md"),
    "done": ("01-plan.md", "02-spec.md", "03-implement.md"),
}


def complete_handoff(path, name):
    """A complete <name> handoff at <path>, a Path, every section filled."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join("## %s\n\nfilled\n\n" % heading for heading in HANDOFF_SECTIONS[name]))


def flow(tmp_path, phase="spec", handoffs=None, **state):
    """A flow at <phase> in the checkout at tmp_path, <state> its other keys,
    with every handoff due at <phase> complete (<handoffs> instead, when
    given)."""
    hold_flow(tmp_path, **dict({"slug": "x", "phase": phase}, **state))
    for name in HANDOFFS_AT.get(phase, ()) if handoffs is None else handoffs:
        complete_handoff(tmp_path / ".orchestrator" / "handoff" / name, name)


def flow_doctor(capsys, seed, tmp_path, *argv, git=None, env=None, gh_class=FakeGh, err=""):
    """`orch.sh doctor --flow` (or <argv>) on Claude Code: orch_doctor's
    run."""
    return orch_doctor(capsys, seed, tmp_path, *(argv or ("--flow",)), git=git,
                       env=flow_env(tmp_path) if env is None else env, gh_class=gh_class,
                       err=err)


def flow_lines(run):
    """The flow state group's lines but its header."""
    return run.group("flow state").split("\n")[1:-1]


def test_a_fresh_flow_at_spec_is_healthy(capsys, seed, tmp_path):
    flow(tmp_path)

    run = flow_doctor(capsys, seed, tmp_path)

    assert flow_lines(run) == [
        "ok    phase: spec",
        "ok    issue: not recorded yet",
        "ok    branch: not created yet",
        "ok    PR: not opened yet",
        "ok    handoff 01-plan.md complete",
    ]
    assert run.code == 0


def test_a_flow_with_no_pr_asks_github_nothing(capsys, seed, tmp_path):
    flow(tmp_path)
    seed.offline()

    run = flow_doctor(capsys, seed, tmp_path, gh_class=GhReads)

    assert "skipped" not in run.out
    assert run.gh.asked == []


@pytest.mark.parametrize("argv", [[], ["--flow"]])
@pytest.mark.parametrize("raw", ["{not json", "[1]", '{"phase": "spec", "issue": 7'])
def test_a_state_file_that_is_no_json_object_is_one_fail_with_the_abort_remedy(
        capsys, seed, tmp_path, argv, raw):
    healthy(seed)
    (tmp_path / ".orchestrator").mkdir()
    (tmp_path / ".orchestrator" / "state.json").write_text(raw)

    run = (flow_doctor(capsys, seed, tmp_path, *argv) if argv
           else orch_doctor(capsys, seed, tmp_path, env=flow_env(tmp_path)))

    assert run.group("flow state") == "\n".join([
        "flow state",
        "FAIL  .orchestrator/state.json is not exactly one JSON object.",
        INDENT + CLAUDE_ABORT,
    ]) + "\n"
    assert run.code == 1


def test_without_jq_bare_doctor_counts_every_flow_check_skipped(capsys, seed, tmp_path):
    healthy(seed)
    flow(tmp_path)

    run = orch_doctor(capsys, seed, tmp_path, env=flow_env(tmp_path, "git", "gh"))

    assert run.group("flow state") == "flow state\n"
    assert "warn  11 flow checks skipped: jq is not installed\n" in run.group("skipped")
    assert run.code == 1


def test_without_jq_doctor_flow_fails_on_its_jq_check(capsys, seed, tmp_path):
    flow(tmp_path)

    run = flow_doctor(capsys, seed, tmp_path, env=flow_env(tmp_path, "git", "gh"))

    assert run.group("flow state") == "\n".join([
        "flow state",
        "FAIL  jq not found - orch.sh reads and writes state.json with it.",
        INDENT + "brew install jq    # or your platform's package manager",
    ]) + "\n"
    assert "skipped" not in run.out
    assert run.code == 1


@pytest.mark.parametrize("phase", ["nonsense", "spec implement", ""])
def test_an_unknown_phase_fails_naming_it_and_the_table_s_phases(capsys, seed, tmp_path, phase):
    flow(tmp_path, phase=phase)

    run = flow_doctor(capsys, seed, tmp_path)

    assert flow_lines(run)[:2] == [
        "FAIL  unknown phase: %s (want one of: spec implement review done)" % phase,
        INDENT + CLAUDE_ABORT,
    ]
    assert run.code == 1


def test_a_recorded_branch_that_is_gone_fails_with_the_abort_remedy(capsys, seed, tmp_path):
    flow(tmp_path, branch="orch/9-gone")

    run = flow_doctor(capsys, seed, tmp_path)

    assert ("FAIL  branch orch/9-gone no longer exists - the flow has nothing left to build on.\n"
            + INDENT + CLAUDE_ABORT + "\n") in run.out
    assert run.code == 1


def branch_git(tmp_path, branch, upstream=None):
    """checkout_git's checkout holding <branch>, tracking <upstream>."""
    git = checkout_git(tmp_path)
    git.branches[branch] = upstream
    return git


def test_before_implement_the_upstream_is_not_checked(capsys, seed, tmp_path):
    flow(tmp_path, branch="orch/9-x")

    run = flow_doctor(capsys, seed, tmp_path, git=branch_git(tmp_path, "orch/9-x"))

    assert "ok    branch: orch/9-x\n" in run.out
    assert "upstream" not in run.out
    assert run.code == 0


@pytest.mark.parametrize("upstream", [None, "refs/remotes/origin/main"])
def test_from_implement_an_unpushed_branch_warns_with_the_push_remedy(
        capsys, seed, tmp_path, upstream):
    flow(tmp_path, phase="implement", branch="orch/9-x")

    run = flow_doctor(capsys, seed, tmp_path, git=branch_git(tmp_path, "orch/9-x", upstream))

    assert ("ok    branch: orch/9-x\n"
            "warn  branch orch/9-x is not on origin yet.\n"
            + INDENT + "git push -u origin refs/heads/orch/9-x:refs/heads/orch/9-x\n") in run.out
    assert run.code == 0


def test_a_branch_tracking_its_own_origin_branch_reports_its_upstream(capsys, seed, tmp_path):
    flow(tmp_path, phase="implement", branch="orch/9-x")

    run = flow_doctor(capsys, seed, tmp_path,
                      git=branch_git(tmp_path, "orch/9-x", "refs/remotes/origin/orch/9-x"))

    assert "ok    upstream: origin/orch/9-x\n" in run.out


def test_a_pushed_branch_beside_a_local_origin_branch_still_reports_its_upstream(
        capsys, seed, tmp_path):
    """A local branch named origin/<branch> makes the upstream's short name
    ambiguous (#1331). It is made after the push, since made first it makes
    `git push -u` itself fail."""
    bare = tmp_path / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", str(bare)], check=True,
                   stdin=subprocess.DEVNULL)
    root = tmp_path.resolve() / "repo"
    root.mkdir()
    git = git_repo(root, origin=ORIGIN)
    exclude_orchestrator(root)
    run_git(root, "config", "remote.origin.pushurl", str(bare))
    run_git(root, "checkout", "-q", "-b", "orch/11-x")
    run_git(root, "commit", "-q", "--allow-empty", "-m", "first")
    run_git(root, "push", "-q", "-u", "origin", "orch/11-x")
    run_git(root, "branch", "-q", "origin/orch/11-x")
    seed.issue(11, "open")
    flow(root, phase="implement", issue=11, branch="orch/11-x")

    run = orch_doctor(capsys, seed, root, "--flow", git=git, env=flow_env(tmp_path))

    assert "ok    upstream: origin/orch/11-x" in flow_lines(run)
    assert "git push -u origin" not in run.out


@pytest.mark.parametrize("local", [False, True])
def test_a_done_flow_s_branch_gone_is_the_routine_end_of_a_flow(capsys, seed, tmp_path, local):
    seed.issue(11, "closed")
    flow(tmp_path, phase="done", branch="orch/9-merged", issue=11)
    git = branch_git(tmp_path, "orch/9-merged") if local else checkout_git(tmp_path)

    run = flow_doctor(capsys, seed, tmp_path, git=git)

    assert ("ok    branch: orch/9-merged" + ("" if local else " gone - expected after merge")
            + "\n") in run.out
    assert "ok    upstream: none - expected after merge\n" in run.out
    assert "ok    issue #11 closed\n" in run.out
    assert run.code == 0


def test_outside_done_a_branch_gone_still_fails(capsys, seed, tmp_path):
    seed.issue(11, "open")
    flow(tmp_path, phase="review", branch="orch/9-merged", issue=11, iteration=0)

    run = flow_doctor(capsys, seed, tmp_path)

    assert "FAIL  branch orch/9-merged no longer exists" in run.out


@pytest.mark.parametrize("state, labels, line", [
    ("open", ("ready-for-agent",), "ok    issue #11 open"),
    ("open", ("needs-triage",), "ok    issue #11 open"),
])
def test_an_open_issue_is_healthy_whatever_its_labels(capsys, seed, tmp_path, state, labels, line):
    seed.issue(11, state, *labels)
    flow(tmp_path, issue=11)

    run = flow_doctor(capsys, seed, tmp_path)

    assert flow_lines(run)[1] == line
    assert run.code == 0


def test_a_closed_issue_fails_before_done_with_the_reopen_remedy(capsys, seed, tmp_path):
    seed.issue(11, "closed")
    flow(tmp_path, issue=11)

    run = flow_doctor(capsys, seed, tmp_path)

    assert flow_lines(run)[1:3] == ["FAIL  issue #11 is closed.", INDENT + "gh issue reopen 11"]
    assert run.code == 1


@pytest.mark.parametrize("stderr, reason", [(GH_502, "HTTP 502: Bad Gateway"),
                                            ("", "gh gave no reason")])
def test_an_issue_github_will_not_read_fails_with_gh_s_first_line(
        capsys, seed, tmp_path, stderr, reason):
    seed.issue(11, "open")
    seed.fail("adapter_issue_state_labels", stderr)
    flow(tmp_path, issue=11)

    run = flow_doctor(capsys, seed, tmp_path)

    assert flow_lines(run)[1:3] == ["FAIL  issue #11 could not be read from GitHub: " + reason,
                                    INDENT + "gh issue view 11"]
    assert run.code == 1


@pytest.mark.parametrize("state, lines, code", [
    ("open", ["ok    PR #7 open"], 0),
    ("merged", ["ok    PR #7 merged"], 0),
    ("closed", ["FAIL  PR #7 is closed.", INDENT + "gh pr reopen 7"], 1),
])
def test_the_pr_check_reads_the_recorded_pr_s_state(capsys, seed, tmp_path, state, lines, code):
    seed.pr(7, state, "orch/9-x", "main")
    flow(tmp_path, pr=7)

    run = flow_doctor(capsys, seed, tmp_path)

    assert flow_lines(run)[3:3 + len(lines)] == lines
    assert run.code == code


@pytest.mark.parametrize("stderr, reason", [(GH_502, "HTTP 502: Bad Gateway"),
                                            ("", "gh gave no reason")])
def test_a_pr_github_will_not_read_fails_with_gh_s_first_line(
        capsys, seed, tmp_path, stderr, reason):
    seed.pr(7, "open", "orch/9-x", "main")
    seed.fail("adapter_pr_state_draft", stderr)
    flow(tmp_path, pr=7)

    run = flow_doctor(capsys, seed, tmp_path)

    assert flow_lines(run)[3:5] == ["FAIL  PR #7 could not be read from GitHub: " + reason,
                                    INDENT + "gh pr view 7"]
    assert run.code == 1


def test_offline_the_flow_s_github_checks_are_skipped_never_failed(capsys, seed, tmp_path):
    seed.issue(11, "open")
    seed.pr(7, "open", "orch/9-x", "main")
    seed.offline()
    flow(tmp_path, issue=11, pr=7)

    run = flow_doctor(capsys, seed, tmp_path)

    assert run.group("skipped") == (
        "skipped\nwarn  3 GitHub checks skipped: GitHub is not reachable\n")
    assert run.code == 0


# --- the review group -------------------------------------------------------------

NEXT = "/orchestrator:next"
REDO_REFUSES = "redo refuses until it reaches a terminal state."


def test_outside_review_nothing_is_said_of_a_review_loop(capsys, seed, tmp_path):
    flow(tmp_path, phase="implement", iteration=2, budget=5)

    run = flow_doctor(capsys, seed, tmp_path)

    assert "review loop" not in run.out
    assert run.code == 0


@pytest.mark.parametrize("iteration, records, lines, code", [
    (0, {}, ["ok    review loop: not started yet",
             "ok    review loop iteration (0) within budget (5)"], 0),
    (2, {}, ["warn  review loop hasn't reached its budget yet (iteration 2 of budget 5) - %s will"
             " resume it; %s" % (NEXT, REDO_REFUSES),
             "ok    review loop iteration (2) within budget (5)"], 0),
    (2, {2: ("## Terminal state", "stop - base sync failed.")},
     ["ok    review loop at a terminal state: stop (base sync failed.)",
      "ok    review loop iteration (2) within budget (5)"], 0),
    (5, {}, ["warn  review loop's last iteration (5 of budget 5) has no recorded terminal state -"
             " the session looks interrupted, not stopped. %s will resume it; %s"
             % (NEXT, REDO_REFUSES),
             "ok    review loop iteration (5) within budget (5)"], 0),
    (5, {5: ("## Terminal state", "ready")},
     ["ok    review loop at a terminal state: ready",
      "ok    review loop iteration (5) within budget (5)"], 0),
    (5, {5: ("## Terminal state", "stop", "CI failed twice.")},
     ["ok    review loop at a terminal state: stop (CI failed twice.)",
      "ok    review loop iteration (5) within budget (5)"], 0),
    (6, {}, ["warn  review loop's last iteration (6 of budget 5) has no recorded terminal state -"
             " the session looks interrupted, not stopped. %s will resume it; %s"
             % (NEXT, REDO_REFUSES),
             "FAIL  review loop iteration (6) is past its budget (5) - the loop's stop"
             " enforcement did not hold."], 1),
])
def test_the_review_loop_s_terminal_state_and_budget_at_review(
        capsys, seed, tmp_path, iteration, records, lines, code):
    flow(tmp_path, phase="review", iteration=iteration, budget=5)
    for i, texts in records.items():
        record(tmp_path, i, *texts)

    run = flow_doctor(capsys, seed, tmp_path)

    assert [line for line in flow_lines(run) if "review loop" in line] == lines
    assert run.code == code


def test_a_loop_past_its_budget_gets_the_abort_remedy(capsys, seed, tmp_path):
    flow(tmp_path, phase="review", iteration=6, budget=5)

    run = flow_doctor(capsys, seed, tmp_path)

    assert ("is past its budget (5) - the loop's stop enforcement did not hold.\n"
            + INDENT + CLAUDE_ABORT + "\n") in run.out


@pytest.mark.parametrize("budget", ["", "abc", None])
def test_an_empty_or_uncountable_budget_reads_as_the_default_of_five(
        capsys, seed, tmp_path, budget):
    flow(tmp_path, phase="review", iteration=2, budget=budget)

    run = flow_doctor(capsys, seed, tmp_path)

    assert "(iteration 2 of budget 5)" in run.out
    assert "ok    review loop iteration (2) within budget (5)\n" in run.out


def test_a_malformed_record_fails_naming_its_shape_and_the_record_to_rewrite(
        capsys, seed, tmp_path):
    flow(tmp_path, phase="review", iteration=5, budget=5)
    path = record(tmp_path, 5, "## Terminal state", "**stop**", "CI failed twice.")

    run = flow_doctor(capsys, seed, tmp_path)

    assert ("FAIL  review loop's last iteration (5) has a malformed terminal state - %s\n"
            "%srewrite the first line of %s in the expected shape above\n"
            % (MALFORMED_SHAPE, INDENT, path)) in run.out
    assert run.code == 1


@pytest.mark.parametrize("texts, said", [
    (("stop - base sync failed.",),
     "ok    review loop at a terminal state: stop (base sync failed.)"),
    (("stopped here",), INDENT + "rewrite the first line of {path} in the expected shape above"),
])
def test_mid_redo_the_retired_record_is_read_and_named(capsys, seed, tmp_path, texts, said):
    seed.issue(21, "open")
    flow(tmp_path, phase="review", iteration=5, budget=5, issue=21, slug="t",
         branch="orch/21-t-redo-1", redo_count=1)
    path = record(tmp_path, 5, "## Terminal state", *texts, under="pre-redo-1")

    run = flow_doctor(capsys, seed, tmp_path, git=branch_git(tmp_path, "orch/21-t-redo-1"))

    assert said.format(path=path) + "\n" in run.out
    assert "looks interrupted" not in run.out


def test_report_files_change_nothing_said_of_the_loop(capsys, seed, tmp_path):
    flow(tmp_path, phase="review", iteration=5, budget=5)
    record(tmp_path, 5, "## Terminal state", "stop", "CI failed twice.")
    record(tmp_path, 5, "## Terminal state", "ready", report="standards")
    record(tmp_path, 5, "## Terminal state", "ready", report="spec")

    run = flow_doctor(capsys, seed, tmp_path)

    assert "ok    review loop at a terminal state: stop (CI failed twice.)\n" in run.out


def test_a_review_directory_that_cannot_be_made_is_the_terminal_check_s_one_fail(
        capsys, seed, tmp_path):
    flow(tmp_path, phase="review", iteration=5, budget=5)
    (tmp_path / ".orchestrator" / "review").write_text("")

    run = flow_doctor(capsys, seed, tmp_path)

    assert [line for line in flow_lines(run) if line.startswith("FAIL")] == [
        "FAIL  review loop's terminal state cannot be read: cannot create the review directory"
        " %s/.orchestrator/review" % tmp_path]
    assert "could not run" not in run.out
    assert run.code == 1


def ci_flow(seed, tmp_path, answer=None, phase="review", draft=True, state="open"):
    """A review flow with PR #40 recorded, open and a draft by default, its
    required checks answering <answer>."""
    seed.pr(40, state, "orch/9-x", "main")
    if draft:
        seed.pr_draft(40)
    if answer is not None:
        seed.checks(40, "required", answer)
    flow(tmp_path, phase=phase, iteration=0, budget=5, pr=40, branch="orch/9-x")


def ci_doctor(capsys, seed, tmp_path, **kwargs):
    return flow_doctor(capsys, seed, tmp_path,
                       git=branch_git(tmp_path, "orch/9-x", "refs/remotes/origin/orch/9-x"),
                       **kwargs)


@pytest.mark.parametrize("answer, lines, code", [
    ("green", ["ok    CI: required checks green"], 0),
    ("none", ["ok    CI: no required checks reported"], 0),
    ("pending", ["ok    CI: required checks still pending"], 0),
    ("failing", ["FAIL  CI: required check(s) failing on PR #40.", INDENT + "gh pr checks 40",
                 INDENT + "build"], 1),
    ("boom", ["warn  CI: could not be read from GitHub for PR #40: dial tcp: lookup"
              " api.github.com: no such host"], 0),
])
def test_the_ci_check_reports_the_required_checks_verdict(
        capsys, seed, tmp_path, answer, lines, code):
    ci_flow(seed, tmp_path, answer)

    run = ci_doctor(capsys, seed, tmp_path)

    found = flow_lines(run)
    start = next(i for i, line in enumerate(found) if "CI: " in line)
    assert found[start:start + len(lines)] == lines
    assert run.code == code


@pytest.mark.parametrize("stderr, reason", [(GH_502, "HTTP 502: Bad Gateway"),
                                            ("", "gh gave no reason")])
def test_a_failed_checks_read_warns_with_gh_s_first_line_once(
        capsys, seed, tmp_path, stderr, reason):
    ci_flow(seed, tmp_path, "green")
    seed.fail("adapter_pr_checks", stderr)

    run = ci_doctor(capsys, seed, tmp_path)

    assert "warn  CI: could not be read from GitHub for PR #40: %s\n" % reason in run.out
    assert run.out.count(reason) == 1
    assert run.code == 0


@pytest.mark.parametrize("phase, draft, state, line, code", [
    ("review", True, "open", "ok    PR #40 draft state matches phase (review)", 0),
    ("review", False, "open", "FAIL  PR #40 was marked ready on GitHub but the flow phase is still"
                              " review - state.json fell out of sync.", 1),
    ("done", False, "open", "ok    PR #40 draft state matches phase (done)", 0),
    ("done", True, "open", "FAIL  PR #40 is still a draft but the flow phase is done - review"
                           " ready did not take.", 1),
])
def test_the_draft_check_holds_the_pr_s_draft_flag_to_the_phase(
        capsys, seed, tmp_path, phase, draft, state, line, code):
    ci_flow(seed, tmp_path, "green", phase=phase, draft=draft, state=state)

    run = ci_doctor(capsys, seed, tmp_path)

    assert line + "\n" in run.out
    assert run.code == code


@pytest.mark.parametrize("phase, finding, remedy", [
    ("review", "was marked ready on GitHub", "gh pr view 40"),
    ("done", "is still a draft", "orch.sh pr ready    # on orch/9-x"),
])
def test_each_draft_mismatch_has_its_remedy(capsys, seed, tmp_path, phase, finding, remedy):
    ci_flow(seed, tmp_path, "green", phase=phase, draft=phase == "done")

    found = flow_lines(ci_doctor(capsys, seed, tmp_path))

    assert finding in found[found.index(INDENT + remedy) - 1]


def test_a_merged_pr_s_draft_flag_is_not_checked(capsys, seed, tmp_path):
    ci_flow(seed, tmp_path, phase="done", state="merged")

    run = ci_doctor(capsys, seed, tmp_path)

    assert "draft" not in run.out
    assert run.code == 0


@pytest.mark.parametrize("stderr, reason", [(GH_502, "HTTP 502: Bad Gateway"),
                                            ("", "gh gave no reason")])
def test_an_unreadable_draft_state_warns_and_the_pr_check_fails(
        capsys, seed, tmp_path, stderr, reason):
    ci_flow(seed, tmp_path, "green")
    seed.fail("adapter_pr_state_draft", stderr)

    run = ci_doctor(capsys, seed, tmp_path)

    assert "FAIL  PR #40 could not be read from GitHub: %s\n" % reason in run.out
    assert "warn  PR #40 draft state could not be read from GitHub: %s\n" % reason in run.out


def phase_reports(capsys, seed, tmp_path, phase):
    """The checks a doctor --flow run at <phase> reported, among the
    phase-listed ones and check_flow_pr, each one set up to have something
    to say."""
    ci_flow(seed, tmp_path, "green", phase=phase)
    out = ci_doctor(capsys, seed, tmp_path).out
    said = {
        "upstream": "upstream: " in out,
        "terminal": "review loop: not started" in out,
        "budget": "review loop iteration (" in out,
        "ci": "CI: " in out,
        "draft": "draft state" in out or "still a draft" in out,
        "pr": "PR #40 open" in out,
    }
    return [name for name, reported in said.items() if reported]


@pytest.mark.parametrize("phase, reported", [
    ("spec", ["pr"]),
    ("implement", ["upstream", "pr"]),
    ("review", ["upstream", "terminal", "budget", "ci", "draft", "pr"]),
    ("done", ["upstream", "draft", "pr"]),
    ("bogus", ["pr"]),
])
def test_each_phase_listed_check_runs_only_in_its_phases(capsys, seed, tmp_path, phase, reported):
    assert phase_reports(capsys, seed, tmp_path, phase) == reported


@pytest.mark.parametrize("phases, phase", [("implemnt+", "implement"), ("reveiw", "review")],
                         ids=["plus-element", "plain-element"])
def test_a_phase_list_naming_a_phase_the_table_lacks_dies_naming_its_entry(
        capsys, phases, phase):
    entry = doctor.Check("a", lambda d: None, phases)

    code, _, err = died_of(capsys, lambda: doctor.entries_at([entry], phase))

    assert (code, err) == (1, "orch: a:%s: no such phase in the phase table: %s\n"
                           % (phases, phases.rstrip("+")))


# --- the autopilot phase label ----------------------------------------------------


def label_doctor(capsys, seed, tmp_path, phase, *labels, **extra):
    """doctor --flow on a flow at <phase> recording issue #7, which carries
    <labels>, under <extra> added to the environment."""
    seed.issue(7, "open", "ready-for-agent", *labels)
    flow(tmp_path, phase=phase, issue=7)
    return flow_doctor(capsys, seed, tmp_path, env=flow_env(tmp_path, **extra))


@pytest.mark.parametrize("phase, labels, lines", [
    ("spec", ("orch:spec",), ["ok    phase label: orch:spec"]),
    ("implement", ("Orch:Implement",), ["ok    phase label: orch:implement"]),
    ("spec", ("orch:implement",), [
        "warn  issue #7 is labelled orch:implement, but this checkout last moved to phase spec.",
        INDENT + "relabel the issue orch:spec; the watcher refuses this disagreement"]),
    ("spec", ("orch:review", "orch:spec"), [
        "warn  issue #7 is labelled orch:spec orch:review, but this checkout last moved to phase"
        " spec.",
        INDENT + "relabel the issue orch:spec; the watcher refuses this disagreement"]),
    ("implement", ("orch:spec",), [
        "warn  issue #7 is labelled orch:spec, but this checkout last moved to phase implement.",
        INDENT + "the watcher will run /orchestrator:redo spec"]),
    ("review", ("orch:implement",), [
        "warn  issue #7 is labelled orch:implement, but this checkout last moved to phase review.",
        INDENT + "the watcher will run /orchestrator:redo review"]),
])
def test_the_phase_label_is_held_to_the_recorded_phase(capsys, seed, tmp_path, phase, labels,
                                                       lines):
    run = label_doctor(capsys, seed, tmp_path, phase, *labels)

    found = flow_lines(run)
    assert found[-len(lines):] == lines


def test_an_interactive_flow_s_missing_phase_label_is_not_mentioned(capsys, seed, tmp_path):
    run = label_doctor(capsys, seed, tmp_path, "spec")

    assert "phase label" not in run.out
    assert run.code == 0


def test_a_failed_label_read_is_the_issue_check_s_to_report(capsys, seed, tmp_path):
    seed.fail("adapter_issue_state_labels", GH_502)

    run = label_doctor(capsys, seed, tmp_path, "spec", "orch:implement")

    assert "phase label" not in run.out
    assert "is labelled" not in run.out
    assert run.out.count("HTTP 502") == 1


def test_an_autopilot_session_refuses_an_issue_with_no_phase_label(capsys, seed, tmp_path):
    run = label_doctor(capsys, seed, tmp_path, "spec", ORCH_AUTOPILOT="1")

    assert flow_lines(run)[-2:] == [
        "FAIL  issue #7 carries no phase label - an autopilot session needs the flow's phase"
        " recorded on its issue.",
        INDENT + "gh issue edit 7 --add-label orch:spec"]
    assert run.code == 1


def test_an_autopilot_session_refuses_a_flow_with_no_issue(capsys, seed, tmp_path):
    flow(tmp_path)

    run = flow_doctor(capsys, seed, tmp_path, env=flow_env(tmp_path, ORCH_AUTOPILOT="1"))

    assert flow_lines(run)[-2:] == [
        "FAIL  autopilot session, but no issue is recorded - the flow's phase has no label to"
        " live on.",
        INDENT + CLAUDE_ABORT]
    assert run.code == 1


# --- the handoffs -----------------------------------------------------------------

REDO = "/orchestrator:redo"


def test_a_missing_handoff_fails_with_the_redo_remedy(capsys, seed, tmp_path):
    flow(tmp_path, phase="implement", handoffs=["02-spec.md"])

    run = flow_doctor(capsys, seed, tmp_path)

    assert flow_lines(run)[-3:] == [
        "FAIL  handoff 01-plan.md is missing - the phase that writes it has already run.",
        INDENT + REDO,
        "ok    handoff 02-spec.md complete"]
    assert "no issue is recorded" not in run.out
    assert run.code == 1


def test_a_handoff_with_an_empty_section_fails_naming_it(capsys, seed, tmp_path):
    flow(tmp_path, phase="implement", handoffs=["01-plan.md"])
    (tmp_path / ".orchestrator" / "handoff" / "02-spec.md").write_text("## Spec issue\n\n")

    run = flow_doctor(capsys, seed, tmp_path)

    assert flow_lines(run)[-2:] == ["FAIL  handoff 02-spec.md: empty section: ## Spec issue",
                                    INDENT + REDO]
    assert run.code == 1


def test_markers_and_older_flows_leftovers_are_no_handoffs(capsys, seed, tmp_path):
    flow(tmp_path, phase="review", iteration=0, loop=2)
    healthy_out = flow_doctor(capsys, seed, tmp_path).out
    handoffs = tmp_path / ".orchestrator" / "handoff"
    (handoffs / "spec-paused").write_text("7\n")
    (handoffs / "spec-round").write_text("7 1 2\n")
    (tmp_path / ".orchestrator" / "review" / "loop-01").mkdir(parents=True)
    (tmp_path / ".orchestrator" / "review" / "loop-01" / "iteration-01.md").write_text("")

    run = flow_doctor(capsys, seed, tmp_path)

    assert run.out == healthy_out
    assert "04-review.md" not in run.out and "loop" not in run.out.replace("review loop", "")
    assert run.code == 0


PLAN_AUTOPILOT = "## Autopilot\n\nRounds: 2\nBudget: 3\n"


def handoff_comment(seed, stem, body, created="2026-01-01T00:00:00Z"):
    """Issue #7's <stem> handoff comment holding <body>."""
    seed.comment(7, "someone", created, "<!-- orch:handoff %s -->\n%s" % (stem, body))


def complete_text(name):
    return "".join("## %s\n\nfilled\n\n" % heading for heading in HANDOFF_SECTIONS[name])


def autopilot_flow(seed, tmp_path, posted=("01-plan", "02-spec")):
    """An autopilot flow at implement on issue #7, labelled orch:implement,
    its <posted> handoff comments complete."""
    seed.issue(7, "open", "orch:implement")
    for stem in posted:
        handoff_comment(seed, stem, complete_text(stem + ".md")
                        + (PLAN_AUTOPILOT if stem == "01-plan" else ""))
    flow(tmp_path, phase="implement", issue=7, handoffs=())


def autopilot_doctor(capsys, seed, tmp_path, gh_class=FakeGh, err=""):
    return flow_doctor(capsys, seed, tmp_path, env=flow_env(tmp_path, ORCH_AUTOPILOT="1"),
                       gh_class=gh_class, err=err)


def handoff_lines(run):
    return [line for line in flow_lines(run) if "handoff" in line]


def test_an_autopilot_flow_s_handoffs_are_its_posted_comments(capsys, seed, tmp_path):
    autopilot_flow(seed, tmp_path)

    run = autopilot_doctor(capsys, seed, tmp_path)

    assert handoff_lines(run) == ["ok    handoff 01-plan.md complete",
                                  "ok    handoff 02-spec.md complete"]
    assert run.code == 0


def test_a_handoff_comment_missing_fails_naming_the_issue(capsys, seed, tmp_path):
    autopilot_flow(seed, tmp_path, posted=("02-spec",))

    run = autopilot_doctor(capsys, seed, tmp_path)

    assert flow_lines(run)[-4:-1] == [
        "FAIL  handoff 01-plan comment is missing on issue #7 - the phase that writes it has"
        " already run.",
        INDENT + REDO,
        "ok    handoff 02-spec.md complete"]
    assert run.code == 1


def test_a_retired_handoff_comment_reads_as_missing(capsys, seed, tmp_path):
    autopilot_flow(seed, tmp_path)
    handoff_comment(seed, "01-plan retired", "Retired by a redo.", created="2030-01-01T00:00:00Z")

    run = autopilot_doctor(capsys, seed, tmp_path)

    assert ("FAIL  handoff 01-plan comment is missing on issue #7 - the phase that writes it has"
            " already run.\n") in run.out
    assert run.code == 1


def test_an_incomplete_newest_handoff_comment_is_flagged(capsys, seed, tmp_path):
    autopilot_flow(seed, tmp_path)
    handoff_comment(seed, "02-spec", "## Decisions\n", created="2030-01-01T00:00:00Z")

    run = autopilot_doctor(capsys, seed, tmp_path)

    assert "FAIL  handoff 02-spec.md: missing section: ## Spec issue\n" in run.out


def test_an_autopilot_flow_with_no_issue_cannot_read_its_handoff_comments(
        capsys, seed, tmp_path):
    flow(tmp_path, phase="implement", handoffs=())

    run = autopilot_doctor(capsys, seed, tmp_path)

    assert ("FAIL  autopilot session, but no issue is recorded - the handoff comments cannot be"
            " read.\n" + INDENT + CLAUDE_ABORT + "\n") in run.out
    assert "is missing" not in run.out
    assert run.code == 1


@pytest.mark.parametrize("prepare, reason", [
    (lambda seed: seed.fail("adapter_issue_comments", "HTTP 502 comments"), "HTTP 502 comments"),
    (lambda seed: seed.lag("adapter_issue_comments", 1, "not json"),
     "gh's output is not a comment list"),
])
def test_handoff_comments_that_cannot_be_read_are_one_fail_with_no_remedy(
        capsys, seed, tmp_path, prepare, reason):
    autopilot_flow(seed, tmp_path)
    autopilot_doctor(capsys, seed, tmp_path)
    prepare(seed)

    run = autopilot_doctor(capsys, seed, tmp_path)

    assert handoff_lines(run) == ["FAIL  could not read issue #7's handoff comments: " + reason]
    assert REDO not in run.out
    assert run.code == 1


def test_handoff_comment_copies_that_cannot_be_written_are_one_fail(capsys, seed, tmp_path):
    autopilot_flow(seed, tmp_path)
    scratch = tmp_path / ".orchestrator" / "scratch"
    scratch.mkdir(parents=True)
    scratch.chmod(0o555)
    try:
        # Each copy's own line on stderr, as handoff_comment_write prints it.
        run = autopilot_doctor(capsys, seed, tmp_path, err="".join(
            "orch: could not write %s/%s\n" % (scratch, name) for name in HANDOFFS_AT["implement"]))
    finally:
        scratch.chmod(0o755)

    assert handoff_lines(run) == [
        "FAIL  could not write the copies of issue #7's handoff comments to %s" % scratch]
    assert run.code == 1


def test_two_due_handoff_comments_cost_one_comment_read(capsys, seed, tmp_path):
    autopilot_flow(seed, tmp_path)

    autopilot_doctor(capsys, seed, tmp_path)

    assert (tmp_path / "store" / "comment_reads").read_text() == "x\n"


def test_offline_the_handoff_comments_are_skipped_never_failed(capsys, seed, tmp_path):
    autopilot_flow(seed, tmp_path)
    seed.offline()

    run = autopilot_doctor(capsys, seed, tmp_path)

    assert handoff_lines(run) == []
    assert run.group("skipped") == (
        "skipped\nwarn  3 GitHub checks skipped: GitHub is not reachable\n")
    assert run.code == 0


# --- the working tree and ticket worktrees ----------------------------------------


def dirty_git(tmp_path, answer):
    """checkout_git's checkout, git status answering <answer>: the dirty
    paths, or git's error line."""
    git = checkout_git(tmp_path)
    git.seed("dirty_paths", answer=answer)
    return git


def test_changes_outside_the_planning_allowlist_fail_naming_each_path(capsys, seed, tmp_path):
    flow(tmp_path)

    run = flow_doctor(capsys, seed, tmp_path, git=dirty_git(
        tmp_path, ["lib/left-behind.sh", "docs/agents/notes.md", "stray.txt"]))

    assert flow_lines(run)[-2:] == [
        "FAIL  the working tree has changes outside the planning allowlist:"
        " lib/left-behind.sh, stray.txt",
        INDENT + "git status"]
    assert run.code == 1


def test_changes_inside_the_planning_allowlist_are_not_reported(capsys, seed, tmp_path):
    flow(tmp_path)

    run = flow_doctor(capsys, seed, tmp_path,
                      git=dirty_git(tmp_path, ["docs/agents/notes.md", ".scratch/plan.md"]))

    assert "planning allowlist" not in run.out
    assert run.code == 0


def test_a_git_status_that_cannot_run_is_a_fail_and_the_report_goes_on(capsys, seed, tmp_path):
    flow(tmp_path)

    run = flow_doctor(capsys, seed, tmp_path,
                      git=dirty_git(tmp_path, "fatal: index file smaller than expected"))

    assert flow_lines(run)[0] == "ok    phase: spec"
    assert flow_lines(run)[-1] == ("FAIL  git status failed - cannot check the working tree:"
                                   " fatal: index file smaller than expected")
    assert run.last() == "5 ok, 0 warn, 1 FAIL"


def worktrees_git(tmp_path, *others):
    """checkout_git's checkout, ticket worktree 12 under it and each of
    <others>' paths another worktree of the clone."""
    git = checkout_git(tmp_path)
    git.seed("worktree_list", answer=[
        Worktree(str(tmp_path), "main"),
        Worktree(str(tmp_path / ".orchestrator" / "worktrees" / "t12"), "main--t12"),
    ] + [Worktree(path, None) for path in others])
    return git


LEFTOVER = ["FAIL  ticket worktree {root}/.orchestrator/worktrees/t12 is left over - a ticket run"
            " did not finish.", INDENT + "orch.sh ticket-worktree remove 12"]


def leftover(tmp_path):
    return [line.format(root=tmp_path) for line in LEFTOVER]


@pytest.mark.parametrize("argv", [[], ["--flow"]])
def test_a_leftover_ticket_worktree_of_this_checkout_alone_fails(capsys, seed, tmp_path, argv):
    healthy(seed)
    flow(tmp_path)
    git = worktrees_git(tmp_path, "/elsewhere/.orchestrator/worktrees/t13")

    run = orch_doctor(capsys, seed, tmp_path, *argv, git=git, env=flow_env(tmp_path))

    assert flow_lines(run)[-2:] == leftover(tmp_path)
    assert "t13" not in run.out
    assert run.code == 1


@pytest.mark.parametrize("argv, prepare, tools", [
    ([], lambda tmp_path: None, TOOLS),
    ([], lambda tmp_path: write_state(tmp_path, "{not json"), TOOLS),
    (["--flow"], lambda tmp_path: write_state(tmp_path, "{not json"), TOOLS),
    ([], flow, ("git", "gh")),
    (["--flow"], flow, ("git", "gh")),
])
def test_the_ticket_worktree_check_runs_whatever_the_flow_s_state(
        capsys, seed, tmp_path, argv, prepare, tools):
    healthy(seed)
    prepare(tmp_path)

    run = orch_doctor(capsys, seed, tmp_path, *argv, git=worktrees_git(tmp_path),
                      env=flow_env(tmp_path, *tools))

    assert flow_lines(run)[-2:] == leftover(tmp_path)
    assert run.code == 1


def write_state(tmp_path, raw):
    (tmp_path / ".orchestrator").mkdir(exist_ok=True)
    (tmp_path / ".orchestrator" / "state.json").write_text(raw)


def test_with_no_ticket_worktree_nothing_is_said_of_them(capsys, seed, tmp_path):
    flow(tmp_path)

    assert "ticket worktree" not in flow_doctor(capsys, seed, tmp_path).out


def test_a_worktree_listing_that_cannot_be_read_is_the_check_s_one_fail(capsys, seed, tmp_path):
    flow(tmp_path)
    git = checkout_git(tmp_path)
    git.seed("worktree_list", answer=None)

    run = flow_doctor(capsys, seed, tmp_path, git=git)

    assert [line for line in run.out.split("\n") if line.startswith("FAIL")] == [
        "FAIL  could not read the checkouts - git worktree list failed"]
    assert "could not run" not in run.out
    assert run.last() == "5 ok, 0 warn, 1 FAIL"
    assert run.code == 1


# --- a failed read in a former bridge target, and one read per answer ---------------


class ChecksDie(FakeGh):
    """The gh fake, its checks read dying as the real adapter's guard does
    with no repo to pin the call to."""

    def pr_checks(self, n, scope):
        from orch.common import die
        die("no repo to pin the checks read to")


def test_a_ci_read_that_dies_is_the_ci_check_s_one_fail(capsys, seed, tmp_path):
    ci_flow(seed, tmp_path)

    run = ci_doctor(capsys, seed, tmp_path, gh_class=ChecksDie)

    assert [line for line in flow_lines(run) if "CI" in line or "checks" in line] == [
        "FAIL  no repo to pin the checks read to"]
    assert "could not run" not in run.out
    assert run.code == 1


class FlowReads(FakeGh):
    """The gh fake, counting its flow issue and flow PR reads in reads."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.reads = {"issue": 0, "pr": 0}

    def issue_state_labels(self, n):
        self.reads["issue"] += 1
        return super().issue_state_labels(n)

    def pr_state_draft(self, n):
        self.reads["pr"] += 1
        return super().pr_state_draft(n)


def reads_flow(seed, tmp_path, phase="review", issue_state="open", pr_state="open",
               labels=("orch:review",), **state):
    seed.issue(7, issue_state, "ready-for-agent", *labels)
    seed.pr(40, pr_state, "orch/9-x", "main")
    seed.pr_draft(40)
    seed.checks(40, "required", "green")
    flow(tmp_path, **dict({"phase": phase, "issue": 7, "pr": 40, "branch": "orch/9-x",
                           "iteration": 0}, **state))


def reads_doctor(capsys, seed, tmp_path, **extra):
    return ci_doctor(capsys, seed, tmp_path, gh_class=FlowReads,
                     env=flow_env(tmp_path, **extra))


@pytest.mark.parametrize("phase, issue_state, pr_state, labels", [
    ("review", "open", "open", ("orch:review",)),
    ("implement", "open", "open", ("orch:implement",)),
    ("done", "closed", "merged", ("orch:done",)),
])
def test_the_flow_issue_and_pr_are_each_read_once_per_run(
        capsys, seed, tmp_path, phase, issue_state, pr_state, labels):
    reads_flow(seed, tmp_path, phase, issue_state, pr_state, labels)

    run = reads_doctor(capsys, seed, tmp_path)

    assert run.gh.reads == {"issue": 1, "pr": 1}
    assert "phase label: orch:%s\n" % phase in run.out


def test_an_autopilot_flow_with_no_phase_label_reads_its_issue_once(capsys, seed, tmp_path):
    reads_flow(seed, tmp_path, labels=())

    run = reads_doctor(capsys, seed, tmp_path, ORCH_AUTOPILOT="1")

    assert "FAIL  issue #7 carries no phase label" in run.out
    assert run.gh.reads["issue"] == 1


@pytest.mark.parametrize("operation, read", [("adapter_issue_state_labels", "issue"),
                                             ("adapter_pr_state_draft", "pr")])
def test_a_failing_read_is_reached_once(capsys, seed, tmp_path, operation, read):
    reads_flow(seed, tmp_path)
    seed.fail(operation, GH_502)

    run = reads_doctor(capsys, seed, tmp_path)

    assert run.gh.reads[read] == 1
    assert "could not be read from GitHub: HTTP 502: Bad Gateway" in run.out


def test_offline_neither_the_issue_nor_the_pr_is_read(capsys, seed, tmp_path):
    reads_flow(seed, tmp_path)
    seed.offline()

    run = reads_doctor(capsys, seed, tmp_path)

    assert run.gh.reads == {"issue": 0, "pr": 0}
    assert run.out.count("skipped:") == 1


@pytest.mark.parametrize("unset, reads", [("pr", {"issue": 1, "pr": 0}),
                                          ("issue", {"issue": 0, "pr": 1})])
def test_what_is_not_recorded_is_not_read(capsys, seed, tmp_path, unset, reads):
    reads_flow(seed, tmp_path, **{unset: None})

    assert reads_doctor(capsys, seed, tmp_path).gh.reads == reads


def test_a_deleted_flow_branch_beside_a_same_named_tag_still_fails(capsys, seed, tmp_path):
    root = tmp_path.resolve() / "repo"
    root.mkdir()
    git = git_repo(root, origin=ORIGIN)
    exclude_orchestrator(root)
    run_git(root, "commit", "-q", "--allow-empty", "-m", "first")
    run_git(root, "tag", "orch/11-gone")
    seed.issue(11, "open")
    flow(root, phase="implement", issue=11, branch="orch/11-gone")

    run = orch_doctor(capsys, seed, root, "--flow", git=git, env=flow_env(tmp_path))

    assert ("FAIL  branch orch/11-gone no longer exists - the flow has nothing left to build"
            " on.") in flow_lines(run)
    assert run.code == 1


# --- repo config: agent settings --------------------------------------------------


def agent_lines(run):
    """The repo config group's agent settings lines: from its first `agent `
    line to its end."""
    lines = repo_config(run).split("\n")[:-1]
    start = next(i for i, line in enumerate(lines) if line.startswith("ok    agent "))
    return lines[start:]


def test_the_agent_settings_check_lists_each_role_and_fails_a_disallowed_value(
        capsys, seed, tmp_path, monkeypatch):
    healthy(seed)
    git = checkout_git(tmp_path, local_config={"orchestrator.effort.implementer": "high",
                                               "orchestrator.model.fixer": "gpt"},
                       global_config={"orchestrator.model.reviewer": "haiku"})

    def refuse(*args, **kwargs):
        raise NoChildProcess()

    monkeypatch.setattr(subprocess, "Popen", refuse)

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=git)

    lines = agent_lines(run)
    assert lines[:4] == [
        "ok    agent implementer: model inherit (inherit), effort high (local)",
        "ok    agent lens: model inherit (inherit), effort inherit (inherit)",
        "ok    agent reviewer: model haiku (global), effort inherit (inherit)",
        "ok    agent fixer: model gpt (local, invalid), effort inherit (inherit)",
    ]
    assert ("FAIL  orchestrator.model.fixer is gpt (local) - not an allowed model"
            " (want sonnet|opus|haiku|fable|inherit)") in lines
    assert INDENT + "orch.sh agent clear fixer --model" in lines
    assert "ok    agent junie auditor: model inherit (inherit), effort inherit (inherit)" in lines
    assert "could not run" not in run.out
    assert run.code == 1


def test_a_model_junie_did_not_recognise_fails_with_its_allowed_names(capsys, seed, tmp_path):
    healthy(seed)
    logs = tmp_path / HOME / ".junie" / "logs"
    logs.mkdir(parents=True)
    (logs / "log-a.log").write_text(
        "WARN Unrecognized 'model' value 'bad-model', falling back to default."
        " Allowed LLM names: gpt-5, claude-opus-5-5\n")
    git = checkout_git(tmp_path, local_config={"orchestrator.junie.model.fixer": "bad-model"})

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=git)

    lines = agent_lines(run)
    found = lines.index("FAIL  Junie did not recognise model bad-model, set for fixer (local) - it"
                        " fell back to the session model")
    assert lines[found - 1] == "ok    junie session: cannot tell (no Junie session index)"
    assert lines[found + 1:found + 3] == [
        INDENT + "Allowed LLM names: gpt-5, claude-opus-5-5",
        INDENT + "orch.sh agent set fixer --host junie --model <id>",
    ]
    assert run.code == 1


def test_agent_settings_that_cannot_be_read_are_the_check_s_one_fail(capsys, seed, tmp_path):
    from orch.common import die

    healthy(seed)
    git = checkout_git(tmp_path)
    # Its scoped config read dying, as a git that cannot read its config
    # file would.
    git.config_regexp = lambda scope, pattern: die("could not read the %s git config" % scope)

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=git)

    assert repo_config(run).endswith("FAIL  could not read the local git config\n")
    assert run.code == 1


# --- repo config: finished side checkouts ---------------------------------------


def linked_worktree(tmp_path, path, marker=None):
    """A linked worktree of the clone at <path>, a Path: its git pointer
    naming a git folder under tmp_path/git-dir/worktrees that holds a HEAD
    and, where <marker> is given, the side-checkout ownership marker holding
    it, its name the path's below tmp_path. Its path, as a str."""
    gitdir = tmp_path / "git-dir" / "worktrees" / "-".join(path.relative_to(tmp_path).parts)
    gitdir.mkdir(parents=True)
    (gitdir / "HEAD").write_text("ref: refs/heads/x\n")
    if marker is not None:
        (gitdir / "orchestrator-side-checkout").write_text(marker)
    path.mkdir(parents=True)
    (path / ".git").write_text("gitdir: %s\n" % gitdir)
    return str(path)


class SideCheckouts:
    """The checkout at tmp_path and its side checkouts, each added by add:
    a FakeGit listing them all, every tree clean, and each branch's tip a
    commit of its own."""

    def __init__(self, tmp_path, **kwargs):
        self.tmp_path = tmp_path
        self.git = checkout_git(tmp_path, **kwargs)
        self.worktrees = [Worktree(str(tmp_path), "main")]
        self.git.seed("worktree_list", answer=self.worktrees)

    def add(self, name, branch, tip=None, marker="7\n"):
        """Side checkout <name> on <branch>, its tip <tip> (a SHA made from
        the name when None): its path."""
        path = linked_worktree(self.tmp_path, self.tmp_path / ".orchestrator" / "checkouts" / name,
                               marker)
        self.worktrees.append(Worktree(path, branch))
        self.git.seed("status_at", path, answer="")
        self.git.seed("branch_at", path, answer=branch)
        self.tip(branch, tip or sha_of(name))
        return path

    def tip(self, branch, sha):
        """<branch>'s tip <sha>, a commit the clone holds."""
        self.git.seed("resolve_commit", "refs/heads/" + branch, answer=sha)
        self.git.commits[sha] = {}

    def merged(self, seed, n, branch, head, base="main"):
        """PR #n merged from <branch> into <base>, its head <head>, a commit
        the clone holds."""
        seed.pr(n, "merged", branch, base)
        seed.pr_head(n, head)
        self.git.commits[head] = {}


def sha_of(name):
    return (name.encode().hex() * 40)[:40]


def finished_lines(run):
    """The report's lines naming a side checkout, and each one's remedy."""
    lines = run.out.split("\n")
    return [line for i, line in enumerate(lines)
            if line.startswith(("warn  side checkout ", "FAIL  could not read the checkouts"))
            or (line.startswith(INDENT + "orch.sh side-checkout remove")
                and lines[i - 1].startswith("warn  side checkout "))]


def finished_warn(tmp_path, name):
    return ["warn  side checkout %s is finished - its PR is merged, and it is still standing at"
            " %s/.orchestrator/checkouts/%s." % (name, tmp_path, name),
            INDENT + "orch.sh side-checkout remove " + name]


def test_finished_side_checkouts_warn_with_their_remove_command_and_others_say_nothing(
        capsys, seed, tmp_path):
    healthy(seed)
    sides = SideCheckouts(tmp_path)
    sides.add("dfin", "quick/20-dfin")
    sides.merged(seed, 60, "quick/20-dfin", sha_of("dfin"))
    sides.add("dopen", "quick/21-dopen")
    seed.pr(61, "open", "quick/21-dopen", "main")
    dflow = sides.add("dflow", "orch/dflow-flow")
    hold_flow(Path(dflow), slug="dflow-flow", phase="done", branch="orch/dflow-flow", pr="62")
    sides.merged(seed, 62, "orch/dflow-flow", sha_of("dflow"))
    sides.add("dun", "quick/22-dun", tip=sha_of("dun-follow-up"))
    sides.merged(seed, 63, "quick/22-dun", sha_of("dun"))
    sides.git.seed("ancestry", sha_of("dun-follow-up"), sha_of("dun"), answer=False)
    dnd = sides.add("dnd", "orch/dnd-flow")
    hold_flow(Path(dnd), slug="dnd-flow", phase="implement", branch="orch/dnd-flow", pr="64")
    sides.merged(seed, 64, "orch/dnd-flow", sha_of("dnd"))

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git)

    assert finished_lines(run) == finished_warn(tmp_path, "dfin") + finished_warn(tmp_path, "dflow")
    assert run.code == 0


def test_a_tip_an_ancestor_of_a_merged_head_is_finished_and_one_never_pushed_is_not(
        capsys, seed, tmp_path):
    healthy(seed)
    sides = SideCheckouts(tmp_path)
    sides.add("behind", "quick/30-behind")
    sides.merged(seed, 70, "quick/30-behind", sha_of("behind-head"))
    sides.git.seed("ancestry", sha_of("behind"), sha_of("behind-head"), answer=True)
    sides.add("unfetched", "quick/31-unfetched")
    seed.pr(71, "merged", "quick/31-unfetched", "main")
    seed.pr_head(71, sha_of("not-here"))

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git)

    assert finished_lines(run) == finished_warn(tmp_path, "behind")


def test_a_dirty_tree_is_not_finished_and_one_git_cannot_read_is_warned_unchecked(
        capsys, seed, tmp_path):
    from orch.git import GitFailure

    healthy(seed)
    sides = SideCheckouts(tmp_path)
    dirty = sides.add("dirty", "quick/40-dirty")
    sides.merged(seed, 80, "quick/40-dirty", sha_of("dirty"))
    sides.git.seed("status_at", dirty, answer="?? new.txt\n")
    broken = sides.add("broken", "quick/41-broken")
    sides.git.seed("status_at", broken, answer=GitFailure(128, "fatal: index file corrupt\nmore"))

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git)

    assert finished_lines(run) == [
        "warn  side checkout broken could not be checked: git status failed - cannot check the"
        " working tree: fatal: index file corrupt"]
    assert run.code == 0


def test_a_side_checkout_github_cannot_answer_for_is_warned_unchecked(capsys, seed, tmp_path):
    healthy(seed)
    sides = SideCheckouts(tmp_path)
    sides.add("quick", "quick/50-quick")
    flowing = sides.add("flowing", "orch/51-flowing")
    hold_flow(Path(flowing), slug="flowing", phase="done", branch="orch/51-flowing", pr="90")
    seed.fail("adapter_prs_merged", GH_502)
    seed.fail("adapter_pr_state_draft", GH_502)

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git)

    assert finished_lines(run) == [
        "warn  side checkout quick could not be checked: could not read GitHub: HTTP 502: Bad"
        " Gateway",
        "warn  side checkout flowing could not be checked: could not read GitHub: HTTP 502: Bad"
        " Gateway"]
    assert run.code == 0


def test_a_flow_with_no_recorded_base_is_held_to_the_default_branch(capsys, seed, tmp_path):
    healthy(seed)
    sides = SideCheckouts(tmp_path)
    into_main = sides.add("into-main", "orch/60-main")
    hold_flow(Path(into_main), slug="m", phase="done", branch="orch/60-main", pr="91")
    sides.merged(seed, 91, "orch/60-main", sha_of("into-main"))
    elsewhere = sides.add("elsewhere", "orch/61-uat")
    hold_flow(Path(elsewhere), slug="u", phase="done", branch="orch/61-uat", pr="92")
    sides.merged(seed, 92, "orch/61-uat", sha_of("elsewhere"), base="uat")
    recorded = sides.add("recorded", "orch/62-uat")
    hold_flow(Path(recorded), slug="r", phase="done", branch="orch/62-uat", pr="93", base="uat")
    sides.merged(seed, 93, "orch/62-uat", sha_of("recorded"), base="uat")

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git)

    assert finished_lines(run) == (finished_warn(tmp_path, "into-main")
                                   + finished_warn(tmp_path, "recorded"))


def test_a_fork_pr_from_the_branch_never_finishes_a_side_checkout(capsys, seed, tmp_path):
    healthy(seed)
    sides = SideCheckouts(tmp_path)
    sides.add("forked", "quick/70-forked")
    sides.merged(seed, 95, "quick/70-forked", sha_of("forked"))
    seed.pr_cross(95)

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git,
                      err="orch: ignored 1 PR(s) from forks for quick/70-forked\n")

    assert finished_lines(run) == []


def test_checkouts_that_cannot_be_listed_fail_the_finished_check(capsys, seed, tmp_path):
    healthy(seed)
    git = checkout_git(tmp_path)
    git.seed("worktree_list", answer=None)

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=git)

    assert finished_lines(run) == [
        "FAIL  could not read the checkouts - git worktree list failed, so no side checkout could"
        " be checked."]
    assert run.code == 1


def skipped_github(run):
    found = re.search(r"^warn  (\d+) GitHub checks? skipped", run.out, re.M)
    return int(found.group(1)) if found else 0


def test_offline_a_side_checkout_is_one_more_skipped_github_check(capsys, seed, tmp_path):
    healthy(seed)
    seed.offline()
    without = skipped_github(orch_doctor(capsys, seed, tmp_path, "--env"))
    sides = SideCheckouts(tmp_path)
    sides.add("dfin", "quick/20-dfin")
    sides.merged(seed, 60, "quick/20-dfin", sha_of("dfin"))

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git)

    assert finished_lines(run) == []
    assert skipped_github(run) == without + 1
    assert run.code == 0


@pytest.mark.parametrize("prepare", [healthy,
                                     lambda seed: (healthy(seed),
                                                   seed.fail("adapter_repo_default_branch"))])
def test_with_side_checkouts_doctor_s_only_default_branch_read_is_its_probe_s(
        capsys, seed, tmp_path, prepare):
    prepare(seed)
    sides = SideCheckouts(tmp_path)
    for name, n in (("one", 60), ("two", 61)):
        dflow = sides.add(name, "orch/%s" % name)
        hold_flow(Path(dflow), slug=name, phase="done", branch="orch/" + name, pr=str(n))
        sides.merged(seed, n, "orch/" + name, sha_of(name))
    sides.add("quick", "quick/62-quick")

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git, gh_class=GhReads)

    assert run.gh.asked.count("repo_default_branch") == 1
    assert finished_lines(run)[:2] == finished_warn(tmp_path, "one")


# --- repo config: autopilot claims ------------------------------------------------

ME = "this-host"


def claims_git(tmp_path):
    """checkout_git's checkout, the main checkout git names."""
    git = checkout_git(tmp_path)
    git.seed("main_checkout", answer=str(tmp_path))
    return git


def run_record(tmp_path, issue, text, kind="pid"):
    """Issue <issue>'s run (or tick) record under the main checkout at
    tmp_path, holding <text>."""
    run_dir = tmp_path / ".orchestrator" / "autopilot" / "run"
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / ("%s.%s" % (issue, kind))).write_text(text)


def claim_lines(run):
    """The report's claim lines, each with its remedy."""
    lines = run.out.split("\n")
    return [line for i, line in enumerate(lines)
            if re.match(r"warn  issue #\d+ (is|has been) claimed", line)
            or (line.startswith(INDENT) and re.match(r"warn  issue #\d+ (is|has been) claimed",
                                                     lines[i - 1]))]


def claims_doctor(capsys, seed, tmp_path, git=None, **extra):
    return orch_doctor(capsys, seed, tmp_path, "--env",
                       git=claims_git(tmp_path) if git is None else git,
                       env=doctor_env(tmp_path, ORCH_HOST_ID=ME, **extra))


def test_old_claims_of_other_hosts_and_dead_claims_of_this_one_warn_with_their_remedies(
        capsys, seed, tmp_path):
    healthy(seed)
    seed.claim(7, host="otherhost", pid=5, started="2020-01-01T00:00:00Z")
    seed.claim(8, host="otherhost", pid=5, started=epoch_iso(int(time.time())))
    seed.claim(9, host=ME, pid=5, started="2020-01-01T00:00:00Z")
    seed.claim(10, host=ME, pid=5, started="2020-01-01T00:00:00Z", phase="review")
    run_record(tmp_path, 10, "999999999 gone\n")
    seed.claim(11, host=ME, pid=5, started="2020-01-01T00:00:00Z")
    run_record(tmp_path, 11, "999999998 gone\n", kind="tick")
    seed.claim(12, host="thirdhost", pid=6, started="2020-01-01T00:00:00Z")

    run = claims_doctor(capsys, seed, tmp_path)

    assert claim_lines(run) == [
        "warn  issue #7 has been claimed by otherhost (pid 5, phase spec) since"
        " 2020-01-01T00:00:00Z - more than a day.",
        INDENT + "if that session is gone, run orch.sh autopilot tick on otherhost",
        "warn  issue #9 is claimed by this host (phase spec), but its process is gone (no"
        " record).",
        INDENT + "orch.sh autopilot tick",
        "warn  issue #10 is claimed by this host (phase review), but its process is gone (pid"
        " 999999999).",
        INDENT + "orch.sh autopilot tick",
        "warn  issue #11 is claimed by this host (phase spec), but its process is gone (pid"
        " 999999998).",
        INDENT + "orch.sh autopilot tick",
        "warn  issue #12 has been claimed by thirdhost (pid 6, phase spec) since"
        " 2020-01-01T00:00:00Z - more than a day.",
        INDENT + "if that session is gone, run orch.sh autopilot tick on thirdhost",
    ]
    assert "refs/orch/claims" not in run.out
    assert run.code == 0


def test_a_claim_whose_process_runs_adds_no_warning(capsys, seed, tmp_path):
    from orch.liveness import record_of

    healthy(seed)
    seed.claim(9, host=ME, pid=os.getpid())
    run_record(tmp_path, 9, record_of(os.getpid(), {}))

    assert claim_lines(claims_doctor(capsys, seed, tmp_path)) == []


def test_with_the_main_checkout_unreadable_only_other_hosts_claims_are_named(
        capsys, seed, tmp_path):
    healthy(seed)
    seed.claim(9, host=ME)
    seed.claim(7, host="otherhost", pid=5, started="2020-01-01T00:00:00Z")

    run = claims_doctor(capsys, seed, tmp_path, git=checkout_git(tmp_path))

    assert [line for line in claim_lines(run) if not line.startswith(INDENT)] == [
        "warn  issue #7 has been claimed by otherhost (pid 5, phase spec) since"
        " 2020-01-01T00:00:00Z - more than a day."]


def test_without_orch_host_id_this_host_is_its_hostname(capsys, seed, tmp_path):
    import socket

    healthy(seed)
    seed.claim(9)
    seed.claim(6, host=ME, started="2020-01-01T00:00:00Z")
    env = doctor_env(tmp_path)

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=claims_git(tmp_path), env=env)

    assert socket.gethostname() != ME
    assert [line for line in claim_lines(run) if not line.startswith(INDENT)] == [
        "warn  issue #6 has been claimed by %s (pid 1, phase spec) since 2020-01-01T00:00:00Z -"
        " more than a day." % ME,
        "warn  issue #9 is claimed by this host (phase spec), but its process is gone (no"
        " record)."]


def test_claims_origin_cannot_list_are_not_reported(capsys, seed, tmp_path):
    healthy(seed)
    seed.claim(7, host="otherhost", started="2020-01-01T00:00:00Z")
    seed.fail("adapter_claim_list", "HTTP 502 claims")

    run = claims_doctor(capsys, seed, tmp_path)

    assert claim_lines(run) == []
    assert "could not run" not in run.out
    assert run.code == 0


# --- repo config: autopilot side-checkout flows -----------------------------------


def side_flow(tmp_path, sides, name="7-side-flow", issue="7", phase="spec", state=None):
    """A side checkout <name> whose marker records <issue>, holding a flow
    at <phase> (<state> written as its state file instead, when given): its
    path."""
    path = sides.add(name, "orch/" + name, marker=issue + "\n")
    if state is None:
        hold_flow(Path(path), slug=name, phase=phase, issue=int(issue) if issue else None)
    else:
        write_state(Path(path), state)
    return path


def side_label_lines(run):
    """The report's side-checkout phase label lines, each with its
    remedy."""
    lines = run.out.split("\n")
    said = re.compile(r"(ok    phase label of #|warn  issue #\d+ is labelled .* its side checkout)")
    return [line for i, line in enumerate(lines)
            if said.match(line) or (line.startswith(INDENT) and said.match(lines[i - 1]))]


@pytest.mark.parametrize("labels, lines", [
    (("orch:spec",), ["ok    phase label of #7: orch:spec"]),
    (("Orch:Spec",), ["ok    phase label of #7: orch:spec"]),
    (("orch:implement",), [
        "warn  issue #7 is labelled orch:implement, but its side checkout 7-side-flow last moved"
        " to phase spec.",
        INDENT + "relabel the issue orch:spec; the watcher refuses this disagreement"]),
    (("orch:review", "orch:spec"), [
        "warn  issue #7 is labelled orch:spec orch:review, but its side checkout 7-side-flow last"
        " moved to phase spec.",
        INDENT + "relabel the issue orch:spec; the watcher refuses this disagreement"]),
])
def test_a_side_checkout_flow_s_phase_label_is_held_to_its_recorded_phase(
        capsys, seed, tmp_path, labels, lines):
    healthy(seed)
    seed.issue(7, "open", "ready-for-agent", *labels)
    sides = SideCheckouts(tmp_path)
    side_flow(tmp_path, sides)

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git, env=flow_env(tmp_path))

    assert side_label_lines(run) == lines
    assert repo_config(run).endswith("\n".join(lines) + "\n")


def test_a_side_flow_labelled_one_step_back_gets_the_redo_the_watcher_will_run(
        capsys, seed, tmp_path):
    healthy(seed)
    seed.issue(7, "open", "orch:spec")
    sides = SideCheckouts(tmp_path)
    side_flow(tmp_path, sides, phase="implement")

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git, env=flow_env(tmp_path))

    assert side_label_lines(run) == [
        "warn  issue #7 is labelled orch:spec, but its side checkout 7-side-flow last moved to"
        " phase implement.",
        INDENT + "the watcher will run /orchestrator:redo spec"]


def test_side_flows_that_cannot_be_judged_are_passed_over_silently(capsys, seed, tmp_path):
    healthy(seed)
    seed.issue(7, "open", "orch:implement")
    sides = SideCheckouts(tmp_path)
    side_flow(tmp_path, sides, name="truncated", state='{"phase": "spec", "issue"')
    side_flow(tmp_path, sides, name="unmarked", issue="")
    side_flow(tmp_path, sides, name="unread", issue="8")
    seed.fail("adapter_issue_state_labels", GH_502)

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git, env=flow_env(tmp_path))

    assert side_label_lines(run) == []
    assert "parse error" not in run.out
    assert "could not run" not in run.out


def test_doctor_in_a_side_checkout_leaves_its_own_flow_to_the_flow_checks(
        capsys, seed, tmp_path):
    healthy(seed)
    seed.issue(7, "open", "orch:implement")
    sides = SideCheckouts(tmp_path)
    path = side_flow(tmp_path, sides)
    sides.git.root = path

    run = orch_doctor(capsys, seed, Path(path), "--env", git=sides.git,
                      env=flow_env(tmp_path))

    assert side_label_lines(run) == []


def test_offline_side_flows_are_one_more_skipped_github_check(capsys, seed, tmp_path):
    healthy(seed)
    seed.offline()
    sides = SideCheckouts(tmp_path)
    without = skipped_github(orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git))
    side_flow(tmp_path, sides)
    side_flow(tmp_path, sides, name="8-other", issue="8")

    run = orch_doctor(capsys, seed, tmp_path, "--env", git=sides.git)

    # One for the finished check, one for the two side flows.
    assert skipped_github(run) == without + 2
    assert side_label_lines(run) == []


# --- git calls per worktree -------------------------------------------------------


class CountingGit:
    """<git>, a FakeGit, counting every method call made on it."""

    def __init__(self, git):
        self._git = git
        self.calls = 0

    def __getattr__(self, name):
        attr = getattr(self._git, name)
        if not callable(attr):
            return attr

        def counted(*args, **kwargs):
            self.calls += 1
            return attr(*args, **kwargs)

        return counted


def plain_worktree_calls(capsys, seed, tmp_path, n):
    """The FakeGit calls doctor --env makes in a clone with <n> plain
    worktrees beside its checkout, their git pointers under tmp_path."""
    git = checkout_git(tmp_path)
    worktrees = [Worktree(str(tmp_path), "main")]
    for i in range(n):
        path = linked_worktree(tmp_path, tmp_path / "plain" / str(n) / ("w%d" % i))
        worktrees.append(Worktree(path, "pw-%d-%d" % (n, i)))
    git.seed("worktree_list", answer=worktrees)
    counting = CountingGit(git)
    orch_doctor(capsys, seed, tmp_path, "--env", git=counting)
    return counting.calls


def test_five_plain_worktrees_cost_doctor_as_many_git_calls_as_two(capsys, seed, tmp_path):
    healthy(seed)

    two = plain_worktree_calls(capsys, seed, tmp_path, 2)
    five = plain_worktree_calls(capsys, seed, tmp_path, 5)

    assert five == two


# --- the whole report -------------------------------------------------------------


def headers(run):
    """The report's group headers, in order: its first line and each line
    after a blank one, the tally's line left out."""
    lines = run.out.rstrip("\n").split("\n")
    return [lines[0]] + [lines[i + 1] for i, line in enumerate(lines[:-2]) if not line]


def test_bare_doctor_prints_every_group_and_the_repo_config_tail_in_today_s_order(
        capsys, seed, tmp_path):
    healthy(seed)
    seed.offline()
    sides = SideCheckouts(tmp_path)
    sides.git.seed("main_checkout", answer=str(tmp_path))
    side_flow(tmp_path, sides)
    seed.claim(9, host="otherhost", pid=5, started="2020-01-01T00:00:00Z")
    flow(tmp_path)

    run = orch_doctor(capsys, seed, tmp_path, git=sides.git, env=flow_env(tmp_path))

    assert headers(run) == ["tools", "auth & remotes", "plugin environment", "repo config",
                            "flow state", "skipped"]
    assert re.fullmatch(r"\d+ ok, \d+ warn, \d+ FAIL", run.last())


def test_the_repo_config_group_ends_on_agents_side_checkouts_claims_and_side_flows(
        capsys, seed, tmp_path):
    healthy(seed)
    seed.issue(7, "open", "orch:implement")
    sides = SideCheckouts(tmp_path)
    sides.git.seed("main_checkout", answer=str(tmp_path))
    side_flow(tmp_path, sides)
    sides.add("dfin", "quick/20-dfin")
    sides.merged(seed, 60, "quick/20-dfin", sha_of("dfin"))
    seed.claim(9, host="otherhost", pid=5, started="2020-01-01T00:00:00Z")

    run = orch_doctor(capsys, seed, tmp_path, git=sides.git, env=flow_env(tmp_path))

    tail = repo_config(run).split("\n")[-8:-1]
    assert tail == [
        "ok    agent junie auditor: model inherit (inherit), effort inherit (inherit)",
        *finished_warn(tmp_path, "dfin"),
        "warn  issue #9 has been claimed by otherhost (pid 5, phase spec) since"
        " 2020-01-01T00:00:00Z - more than a day.",
        INDENT + "if that session is gone, run orch.sh autopilot tick on otherhost",
        "warn  issue #7 is labelled orch:implement, but its side checkout 7-side-flow last moved"
        " to phase spec.",
        INDENT + "relabel the issue orch:spec; the watcher refuses this disagreement",
    ]
