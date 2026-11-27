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
from pathlib import Path

import pytest

from conftest import GH_502, died_of
from orch import cli, doctor
from orch.gh_fake import FakeGh
from orch.git import FakeGit
from orch.repo import REPO_CAUSE, REPO_MISSING, RepoPin
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
    holding <exclude> (none when None); <kwargs> go to FakeGit."""
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
                ssh_lookup=no_ssh_lookup, plugin=None):
    """`orch.sh doctor <argv>` in-process in the checkout <git> (checkout_git's
    when None), under <env> (doctor_env's when None), the gh fake of
    <gh_class> on <seed>'s store pinned to the checkout's repo, run from the
    plugin root <plugin> (tmp_path/PLUGIN when None)."""
    git = checkout_git(tmp_path) if git is None else git
    env = doctor_env(tmp_path) if env is None else env
    if plugin is None:
        plugin = str(tmp_path / PLUGIN)
        os.makedirs(plugin, exist_ok=True)
    pin = RepoPin(env, git, ssh_lookup=ssh_lookup)
    gh = gh_class(seed.store, env, pin=pin, sleep=lambda _: None)
    code = doctor.run(list(argv), gh=gh, git=git, env=env, pin=pin, plugin=plugin)
    out, err = capsys.readouterr()
    assert err == ""
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


@pytest.mark.parametrize("argv", [[], [""], ["--env"]])
def test_doctor_and_doctor_env_run_the_environment_groups(capsys, seed, tmp_path, argv):
    healthy(seed)

    run = orch_doctor(capsys, seed, tmp_path, *argv)

    assert run.out.startswith("tools\n")
    assert run.code == 0


def test_doctor_flow_runs_no_environment_group(capsys, seed, tmp_path):
    run = orch_doctor(capsys, seed, tmp_path, "--flow")

    assert "tools\n" not in run.out
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
    verification's to the end of the repo config group, with <files> written
    to the checkout and <tools> stubs on PATH beside git, gh and jq."""
    for name, text in files.items():
        write(tmp_path, name, text)
    run = orch_doctor(capsys, seed, tmp_path, "--env",
                      env=doctor_env(tmp_path, *(TOOLS + tools)))
    group = repo_config(run).split("\n")
    start = next(i for i, line in enumerate(group) if "Ticket verification" in line)
    return "\n".join(group[start:])


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
