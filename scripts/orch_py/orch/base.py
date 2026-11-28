"""The base concept's module and the base noun (ADR-0067), holding the
default-branch lookup, the base branch in effect now, as base_branch_into
reads it, the base a branch belongs to, and the base and base-SHA keys a branch records them under, with their getters, their setters
and the record of both together - the one place those keys are spelled, the
bash copies gone with the bash branch noun - the default-branch noun,
`orch.sh default-branch [--sha]`, run_default_branch, beside the lookup it
prints, and the base noun's run: `base set` (its --flow form included),
`base show` and `base clear`, with the base note, require_on_origin's checks
and every usage line, unknown-op line and message of the bash noun, its bash
body gone. orch.sh hands both nouns to the package. The base noun reads
the Flow state module, which imports this one for its readers, so its verbs
import it when they run.

GitHub is asked first, and only when the repo pin resolves: origin/HEAD is a
local pointer frozen at clone time, which in a clone taken while a feature
branch was checked out names that branch. It is the fallback for a repo gh
cannot answer for, and the literal guess main the last. Each candidate counts
only when it is a valid branch name, so noise in gh's answer - or a failed
gh call - falls through to the next (#465).
"""
from __future__ import annotations

import os
import sys
from typing import Callable, List, Mapping, NamedTuple, Optional

from orch.common import die, stdout_write
from orch.gh import GhFailed, adapter_of
from orch.git import Git, GitFailure, git_failed
from orch.host import flow_cmd
from orch.repo import RepoPin
from orch.root import checkout_root

# The sources the lookup answers from, named as the bash lookup named them.
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


# The base noun's verbs.
OPS = "set|show|clear"


def run(argv: List[str], gh=None, git=None, env: Optional[Mapping[str, str]] = None,
        pin=None) -> int:
    """`orch.sh base <op>`: the real adapters and the process's environment
    unless a test hands in others. Outside a checkout it dies first, as
    orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op, rest = (argv[0], argv[1:]) if argv else ("", [])
    pin = RepoPin(env, git) if pin is None else pin
    gh_of = adapter_of(gh, env, pin)
    if op == "set":
        return set_verb(rest, gh_of, git, pin, root, env)
    if op == "show":
        if rest:
            die("usage: orch.sh base show")
    elif op == "clear":
        if rest:
            die("usage: orch.sh base clear")
        git.config_unset("local", "orchestrator.base")
    else:
        die("unknown base op: %s (want %s)" % (op or "<none>", OPS))
    base_note(git, lambda: default_branch(gh_of(), git, pin).name)
    return 0


def base_note(git, default: Callable[[], str]) -> None:
    """Prints the base note, "<base> (<source>)": the base branch in effect
    now (base_in_effect, <default> answering the default branch), its source
    `set` when the base setting is set, else `default`."""
    source = "set" if base_setting(git) else "default"
    stdout_write("%s (%s)\n" % (base_in_effect(git, default), source))


SET_USAGE = "usage: orch.sh base set <branch> [--flow]"


def set_verb(argv: List[str], gh_of, git, pin, root: str, env: Mapping[str, str]) -> int:
    """`base set <branch> [--flow]`, --flow before or after the one branch
    name, anything else a usage error. Plain, it sets the checkout's base
    setting once origin has the branch, unsetting it instead when the branch
    is the default branch GitHub or origin/HEAD named - storing that would
    pin today's default and outlive a rename of it - but never on the main
    fallback, a guess rather than the default's name. It prints the base
    note, then, beside an active flow whose own base differs from the base
    now in effect, says the flow keeps it: the setting reaches only flows
    started after it. An existing state file is read once, before origin is
    asked, which doubles as its readability check. The default branch is
    read at most once, as bash's memo read it."""
    from orch.flow_state import STATE_UNREADABLE_MSG, flow_state_file, flow_state_get_many
    branch, flow = "", False
    for arg in argv:
        if arg == "--flow" and not flow:
            flow = True
        elif not branch and arg != "--flow":
            branch = arg
        else:
            die(SET_USAGE)
    if not branch:
        die(SET_USAGE)
    state_file = flow_state_file(root)
    if flow:
        return set_flow(branch, git, state_file, env)
    state = {"phase": "done", "base": "", "slug": ""}
    if os.path.isfile(state_file):
        state = flow_state_get_many(state_file, ("phase", "base", "slug"))
        if state is None:
            die(STATE_UNREADABLE_MSG)
    require_on_origin(git, branch)
    found = default_branch(gh_of(), git, pin)
    if branch == found.name and found.source != FALLBACK:
        git.config_unset("local", "orchestrator.base")
    else:
        failure = git.config_set("local", "orchestrator.base", branch)
        if git_failed(failure):
            sys.exit(failure.code)
    base_note(git, lambda: found.name)
    if state["phase"] != "done":
        # The flow base fallback, over the run's one default-branch read.
        kept = state["base"] or found.name
        if kept != base_in_effect(git, lambda: found.name):
            stdout_write("note: the active flow %s keeps its own base branch: %s\n"
                         % (state["slug"], kept))
    return 0


def require_on_origin(git, branch: str) -> None:
    """Dies unless origin answers that it has <branch> - the one check both
    `base set` and `base set --flow` make before writing anything."""
    has = git.origin_has_branch(branch)
    if has is False:
        die("branch %s does not exist on origin - push it first, or check the name" % branch)
    if has is None:
        die("could not reach origin to check that branch %s exists - nothing was set" % branch)


def set_flow(branch: str, git, state_file: str, env: Mapping[str, str]) -> int:
    """`base set <branch> --flow`: records <branch> as the active flow's own
    base in <state_file>, literally, the default branch's own name included -
    a flow's base is pinned, unlike the checkout setting. A flow's base is
    fixed when init seeds it, so its fork point and PR target cannot move
    under it; this is the one exception, the explicit correction, allowed
    only while the flow has no branch - before it first branches, or after a
    redo retires that branch. The checks run in a fixed order, the first that
    fails reported and nothing written unless all pass: a flow to correct,
    its state readable, the flow not done, no branch, a valid branch name,
    origin's answer that it has it."""
    from orch.flow_state import STATE_UNREADABLE_MSG, flow_state_get_many, state_write_many
    if not os.path.isfile(state_file):
        die("no active flow - nothing was set")
    state = flow_state_get_many(state_file, ("branch", "slug", "phase"))
    if state is None:
        die(STATE_UNREADABLE_MSG)
    if state["phase"] == "done":
        die("no active flow - nothing was set")
    if state["branch"]:
        held = "flow %s already has branch %s - its base can " % (state["slug"], state["branch"])
        if state["phase"] == "review":
            die(held + "change again once %s retires it" % flow_cmd(env, "redo"))
        die(held + "no longer change; abort to start again on another base")
    if not git.is_branch_name(branch):
        die("%s is not a valid branch name - nothing was set" % branch)
    require_on_origin(git, branch)
    state_write_many(state_file, [("base", branch, True)])
    stdout_write("%s (flow)\n" % branch)
    return 0
