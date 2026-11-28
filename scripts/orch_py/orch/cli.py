"""The converted nouns' dispatch, run by the entry point (orch/__main__.py)
once its interpreter check has passed.

main(argv) takes `<noun> <verb> ...` as orch.sh hands them on. It resolves
the checkout root first, through orch.root, so every noun dies outside a git
repository before it runs - help, slug and an unknown noun included. No noun
runs help, as a bare orch.sh always has. A noun not in NOUNS dies
"unknown command: <noun> (run 'orch.sh help')"; `-h` and `--help`, help's
option spellings, run help, and `health` runs doctor, through ALIASES rather
than NOUNS.

main ends a run of a noun in SIGPIPE_NOUNS (an alias by the noun it runs)
whose stdout pipe is closed before it is all written as SIGPIPE ended bash's
printf and cat: silently, with no Python traceback or flush warning. Every other
noun ends such a run as it did before those nouns were converted.
"""
from __future__ import annotations

import os
import signal
import sys
from typing import Callable, Dict, List, Mapping, Optional

from orch.common import die
from orch.git import Git
from orch.root import checkout_root


def _issue(argv: List[str]) -> int:
    # Imported on call, so a run loads only the noun it runs.
    from orch.issue import run

    return run(argv)


def _finding_triage(argv: List[str]) -> int:
    from orch.finding_triage import run

    return run(argv)


def _verification(argv: List[str]) -> int:
    from orch.verification import run

    return run(argv)


def _audit(argv: List[str]) -> int:
    from orch.audit import run

    return run(argv)


def _review_pass(argv: List[str]) -> int:
    from orch.review_pass import run

    return run(argv)


def _spec(argv: List[str]) -> int:
    from orch.spec import run

    return run(argv)


def _spec_review(argv: List[str]) -> int:
    from orch.spec_review import run

    return run(argv)


def _breakdown(argv: List[str]) -> int:
    from orch.breakdown import run

    return run(argv)


def _glossary(argv: List[str]) -> int:
    from orch.glossary import run

    return run(argv)


def _parallel(argv: List[str]) -> int:
    from orch.parallel import run

    return run(argv)


def _route(argv: List[str]) -> int:
    from orch.route import run

    return run(argv)


def _agent(argv: List[str]) -> int:
    from orch.agent import run

    return run(argv)


def _slug(argv: List[str]) -> int:
    from orch.slug import run

    return run(argv)


def _status(argv: List[str]) -> int:
    from orch.status import run

    return run(argv)


def _archive(argv: List[str]) -> int:
    from orch.archive import run

    return run(argv)


def _init(argv: List[str]) -> int:
    from orch.init import run

    return run(argv)


def _phase(argv: List[str]) -> int:
    from orch.phase import run

    return run(argv)


def _handoff(argv: List[str]) -> int:
    from orch.handoff import run

    return run(argv)


def _redo(argv: List[str]) -> int:
    from orch.redo import run

    return run(argv)


def _ticket(argv: List[str]) -> int:
    from orch.ticket import run

    return run(argv)


def _ticket_worktree(argv: List[str]) -> int:
    from orch.ticket_worktree import run

    return run(argv)


def _pr(argv: List[str]) -> int:
    from orch.pr import run

    return run(argv)


def _review(argv: List[str]) -> int:
    from orch.review import run

    return run(argv)


def _doctor(argv: List[str]) -> int:
    from orch.doctor import run

    return run(argv)


def _help(argv: List[str]) -> int:
    from orch.help import run

    return run(argv)


def _autopilot(argv: List[str]) -> int:
    from orch.autopilot import run

    return run(argv)


def _side_checkout(argv: List[str]) -> int:
    from orch.side_checkout import run

    return run(argv)


def _branch(argv: List[str]) -> int:
    from orch.branch import run

    return run(argv)


def _repo(argv: List[str]) -> int:
    from orch.repo import run

    return run(argv)


def _default_branch(argv: List[str]) -> int:
    from orch.base import run_default_branch

    return run_default_branch(argv)


def _base(argv: List[str]) -> int:
    from orch.base import run

    return run(argv)


def _state(argv: List[str]) -> int:
    from orch.state import run

    return run(argv)


# The converted nouns: each takes the arguments after the noun and returns its
# exit code.
NOUNS: Dict[str, Callable[[List[str]], int]] = {
    "issue": _issue,
    "finding-triage": _finding_triage,
    "verification": _verification,
    "audit": _audit,
    "review-pass": _review_pass,
    "spec-review": _spec_review,
    "spec": _spec,
    "breakdown": _breakdown,
    "glossary": _glossary,
    "parallel": _parallel,
    "route": _route,
    "agent": _agent,
    "slug": _slug,
    "status": _status,
    "archive": _archive,
    "init": _init,
    "phase": _phase,
    "handoff": _handoff,
    "redo": _redo,
    "ticket": _ticket,
    "ticket-worktree": _ticket_worktree,
    "pr": _pr,
    "review": _review,
    "doctor": _doctor,
    "help": _help,
    "autopilot": _autopilot,
    "side-checkout": _side_checkout,
    "branch": _branch,
    "repo": _repo,
    "default-branch": _default_branch,
    "base": _base,
    "state": _state,
}

# The other spellings main runs as a noun - help's option spellings and
# doctor's alias health: orch.sh hands them on as given.
ALIASES: Dict[str, str] = {"-h": "help", "--help": "help", "health": "doctor"}

# The nouns converted with init and after it, each keeping its bash noun's
# silent SIGPIPE death on a closed stdout pipe; a noun converted before them
# keeps its flush failure there, as it always ended.
SIGPIPE_NOUNS = frozenset({"init", "slug", "status", "archive", "help", "phase", "handoff",
                           "redo", "ticket", "ticket-worktree", "pr", "review", "doctor",
                           "autopilot", "side-checkout", "branch", "repo",
                           "default-branch", "base", "state"})


def _sigpipe_as_bash(run: Callable[[List[str]], int], argv: List[str]) -> int:
    """run(<argv>) and its exit code, stdout flushed before it returns. Python
    ignores SIGPIPE, so a write into a pipe whose reader is gone raises
    BrokenPipeError where bash died of the signal: die of it too, so the
    shell sees bash's status and nothing is printed."""
    try:
        code = run(argv)
        sys.stdout.flush()
        return code
    except BrokenPipeError:
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGPIPE)
        raise


def main(argv: List[str], git=None, env: Optional[Mapping[str, str]] = None) -> int:
    """Runs the noun <argv> names, help when it names none or its first
    argument is empty (bash's ${1:-help}), once the checkout root resolves
    through the git adapter <git> (a real one when None) and the environment
    <env> (os.environ when None): outside a checkout every noun dies first,
    help and an unknown noun included, as the bash orch.sh made it."""
    checkout_root(Git() if git is None else git, os.environ if env is None else env)
    noun = (argv[0] if argv else "") or "help"
    name = ALIASES.get(noun, noun)
    run = NOUNS.get(name)
    if run is None:
        die("unknown command: %s (run 'orch.sh help')" % noun)
    if name in SIGPIPE_NOUNS:
        return _sigpipe_as_bash(run, argv[1:])
    return run(argv[1:])

