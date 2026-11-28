"""The base concept's module, holding the default-branch lookup, as the bash
side's default_branch_resolve and default_branch_seed find it, the base
branch in effect now, as its base_branch_into reads it, the base a branch
belongs to, and the base and base-SHA keys a branch records them under, with
their getters, their setters and the record of both together - the one
place those keys are spelled, the bash copies gone with the bash branch noun
- and the default-branch noun (ADR-0067), `orch.sh default-branch [--sha]`,
run_default_branch, beside the lookup it prints, with the bash noun's usage
line, output, exit codes and `orch: ` messages, which orch.sh's
converted-noun case runs; the later `base` noun grows it rather than moving
it.

GitHub is asked first, and only when the repo pin resolves: origin/HEAD is a
local pointer frozen at clone time, which in a clone taken while a feature
branch was checked out names that branch. It is the fallback for a repo gh
cannot answer for, and the literal guess main the last. Each candidate counts
only when it is a valid branch name, so noise in gh's answer - or a failed
gh call - falls through to the next (#465).
"""
from __future__ import annotations

import os
from typing import Callable, List, Mapping, NamedTuple, Optional

from orch.common import die, stdout_write
from orch.gh import GhFailed, adapter_of
from orch.git import Git, GitFailure
from orch.repo import RepoPin
from orch.root import checkout_root

# The sources the lookup answers from, as bash's DEFAULT_BRANCH_SOURCE names
# them.
GITHUB = "github"
ORIGIN_HEAD = "origin-head"
FALLBACK = "fallback"


class DefaultBranch(NamedTuple):
    """The default branch's name, and the source it came from: github,
    origin-head or fallback."""

    name: str
    source: str


def default_branch(gh, git, pin) -> DefaultBranch:
    """The default branch: GitHub's answer through the gh adapter <gh>, asked
    only when the repo pin <pin> resolves, when it is a valid branch name;
    else the branch origin/HEAD names in the checkout <git> reads; else main.
    Never fails: a failed gh call falls through, silently."""
    repo = pin.resolve()
    if repo is not None:
        try:
            answer = gh.repo_default_branch(repo.name)
        except GhFailed:
            answer = ""
        if answer and git.is_branch_name(answer):
            return DefaultBranch(answer, GITHUB)
    return default_branch_local(git)


def default_branch_local(git) -> DefaultBranch:
    """The default branch without asking GitHub, the lookup's local
    fallback: the branch origin/HEAD names in the checkout <git> reads, else
    main."""
    head = git.origin_head_branch()
    if head and git.is_branch_name(head):
        return DefaultBranch(head, ORIGIN_HEAD)
    return DefaultBranch("main", FALLBACK)


def branch_base_key(branch: str) -> str:
    """The git config key recording the base branch <branch> was made off."""
    return "branch.%s.orchestrator-base" % branch


def branch_base_get(git, branch: str) -> Optional[str]:
    """The base recorded for <branch> in git config, read through the git
    adapter <git>; None when none is recorded."""
    return git.config_value(branch_base_key(branch))


def branch_base_sha_key(branch: str) -> str:
    """The git config key recording <branch>'s base SHA: its base branch's
    tip when it branched, or at its latest base sync."""
    return "branch.%s.orchestrator-base-sha" % branch


def branch_base_sha_get(git, branch: str) -> Optional[str]:
    """The base SHA recorded for <branch> in git config, read through the
    git adapter <git>; None when none is recorded."""
    return git.config_value(branch_base_sha_key(branch))


def branch_base_set(git, branch: str, base: str) -> Optional[GitFailure]:
    """Records <base> as the base branch <branch> was made off, in the
    repository's own config: None when it wrote, else git's status and
    stderr."""
    return git.config_set("local", branch_base_key(branch), base)


def branch_base_sha_set(git, branch: str, sha: str) -> Optional[GitFailure]:
    """Records <sha> as <branch>'s base SHA, in the repository's own config:
    None when it wrote, else git's status and stderr."""
    return git.config_set("local", branch_base_sha_key(branch), sha)


def record_branch_base(git, branch: str, base: str, sha: str) -> Optional[GitFailure]:
    """Records <base> and <sha> as branch <branch>'s base and base SHA
    together in its git config, where branch sync and branch base-sha read
    them: None when both wrote, else the first write's failure, the base SHA
    left unwritten when the base's write failed."""
    return branch_base_set(git, branch, base) or branch_base_sha_set(git, branch, sha)


def base_setting(git) -> str:
    """The checkout's orchestrator.base setting; empty when it is unset."""
    return git.config_value("orchestrator.base") or ""


def base_in_effect(git, default: Callable[[], str]) -> str:
    """The base branch in effect now: the base setting, else the default
    branch the callable <default> answers, asked only when the setting is
    unset. The one home of that rule."""
    return base_setting(git) or default()


def base_branch_into(gh, git, pin) -> str:
    """The base branch in effect now, bash base_branch_into: base_in_effect,
    the default branch read by default_branch, through the gh adapter <gh>
    and the repo pin <pin>. Never fails."""
    return base_in_effect(git, lambda: default_branch(gh, git, pin).name)


def recorded_base_into(gh, git, pin, branch: str) -> str:
    """The base branch <branch> belongs to: recorded_base_of, the default
    branch read by default_branch, through the gh adapter <gh> and the repo
    pin <pin>. Never fails."""
    return recorded_base_of(git, branch, lambda: default_branch(gh, git, pin).name)


def recorded_base_of(git, branch: str, default: Callable[[], str]) -> str:
    """The base branch <branch> belongs to: the one recorded for it, else
    the base branch in effect now (base_in_effect), the default branch the
    callable <default> answers - for a caller that already holds it, as
    bash's seeded default-branch memo is, so the rule asks GitHub nothing of
    its own."""
    recorded = branch_base_get(git, branch)
    if recorded is not None:
        return recorded
    return base_in_effect(git, default)


def run_default_branch(argv: List[str], gh=None, git=None,
                       env: Optional[Mapping[str, str]] = None, pin=None) -> int:
    """`orch.sh default-branch [--sha]`: the default branch's name, or with
    --sha the default SHA - the full SHA of refs/remotes/origin/<default> as
    it stands. --sha never fetches: finding triage reads it right after its
    scan's fetch set that ref, so it names the remote tip the scan used. The
    real adapters and the process's environment unless a test hands in
    others; outside a checkout it dies first, as orch.sh does."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    checkout_root(git, env)
    if argv and argv != ["--sha"]:
        die("usage: orch.sh default-branch [--sha]")
    pin = RepoPin(env, git) if pin is None else pin
    default = default_branch(adapter_of(gh, env, pin)(), git, pin).name
    if not argv:
        stdout_write(default + "\n")
        return 0
    ref = "refs/remotes/origin/" + default
    sha = git.resolve_commit(ref)
    if sha is None:
        die("no %s - fetch the default branch first" % ref)
    stdout_write(sha + "\n")
    return 0
