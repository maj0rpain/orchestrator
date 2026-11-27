"""The doctor noun, driven through doctor.run as orch.sh hands it its
arguments: its report on stdout - each group under its header, every check's
ok, warn and FAIL line and its remedies, the skip report and the tally - and
its exit code. The tools it looks for are stubs on a PATH under tmp_path, the
checkout a FakeGit, and GitHub the gh fake on its store."""
from __future__ import annotations

import platform
import re

import pytest

from conftest import died_of
from orch import cli, doctor
from orch.gh_fake import FakeGh
from orch.git import FakeGit
from orch.repo import REPO_CAUSE, REPO_MISSING, RepoPin

ORIGIN = "https://github.com/acme/widgets.git"
RUNNING_BASH = "5.2.21"
INDENT = "      "
TOOLS = ("git", "gh", "jq")


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


def checkout_git(tmp_path, origin=ORIGIN, origin_head=None):
    """A FakeGit checkout at tmp_path, <origin> its origin remote (none when
    None) and origin/HEAD naming <origin_head>; main, develop and trunk are
    branch names."""
    git = FakeGit(remotes={} if origin is None else {"origin": origin}, toplevel=str(tmp_path))
    for name in ("main", "develop", "trunk"):
        git.seed("is_branch_name", name, answer=True)
    git.seed("origin_head_branch", answer=origin_head)
    return git


def healthy(seed):
    """The GitHub a healthy repo has for doctor: default branch main."""
    seed.default_branch("main\n")


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
                ssh_lookup=no_ssh_lookup):
    """`orch.sh doctor <argv>` in-process in the checkout <git> (checkout_git's
    when None), under <env> (git, gh and jq on PATH and the bash orch.sh ran
    under when None), the gh fake of <gh_class> on <seed>'s store pinned to
    the checkout's repo."""
    git = checkout_git(tmp_path) if git is None else git
    if env is None:
        env = {"PATH": stub_path(tmp_path, *TOOLS), "ORCH_RUNNING_BASH": RUNNING_BASH}
    pin = RepoPin(env, git, ssh_lookup=ssh_lookup)
    gh = gh_class(seed.store, env, pin=pin, sleep=lambda _: None)
    code = doctor.run(list(argv), gh=gh, git=git, env=env, pin=pin)
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
    env = {"PATH": stub_path(tmp_path), "ORCH_RUNNING_BASH": RUNNING_BASH}

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
    env = {"PATH": stub_path(tmp_path, *TOOLS, bash_prints="4.4.23")}

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
    env = {"PATH": stub_path(tmp_path, *TOOLS), "ORCH_RUNNING_BASH": RUNNING_BASH,
           "GH_REPO": "fork/widgets"}

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
        "skipped\nwarn  2 GitHub checks skipped: %s\n" % REPO_MISSING)
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
    assert "\n\nskipped\nwarn  3 GitHub checks skipped: GitHub is not reachable\n\n" in run.out
    assert "FAIL  " not in run.out
    assert run.code == 0


def test_without_gh_the_github_checks_are_skipped_naming_it(capsys, seed, tmp_path):
    env = {"PATH": stub_path(tmp_path, "git", "jq"), "ORCH_RUNNING_BASH": RUNNING_BASH}

    run = orch_doctor(capsys, seed, tmp_path, env=env)

    assert run.group("skipped") == "skipped\nwarn  3 GitHub checks skipped: gh is not installed\n"


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
    env = dict({"PATH": stub_path(tmp_path, *TOOLS), "ORCH_RUNNING_BASH": RUNNING_BASH}, **extra)

    run = orch_doctor(capsys, seed, tmp_path, env=env)

    assert ("FAIL  gh is not authenticated to %s.\n%sgh auth login --hostname %s\n"
            % (host, INDENT, host)) in run.group("auth & remotes")
    assert run.group("skipped") == "skipped\nwarn  2 GitHub checks skipped: not authenticated\n"
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
    env = dict({"PATH": stub_path(tmp_path, *TOOLS), "ORCH_RUNNING_BASH": RUNNING_BASH}, **extra)

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
    env = {"PATH": stub_path(tmp_path, *TOOLS), "ORCH_RUNNING_BASH": RUNNING_BASH,
           "GH_REPO": "ghe.example.com/acme/widgets"}

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


@pytest.mark.parametrize("prepare", [healthy, lambda seed: seed.default_branch("\n"),
                                     lambda seed: seed.fail("adapter_repo_default_branch")])
def test_doctor_asks_github_each_answer_once_per_run(capsys, seed, tmp_path, prepare):
    prepare(seed)

    run = orch_doctor(capsys, seed, tmp_path, gh_class=GhReads)

    assert run.gh.asked == ["auth_status", "repo_default_branch"]


def test_unauthenticated_doctor_never_reads_the_default_branch(capsys, seed, tmp_path):
    healthy(seed)
    seed.noauth()

    run = orch_doctor(capsys, seed, tmp_path, gh_class=GhReads)

    assert run.gh.asked == ["auth_status"]


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
