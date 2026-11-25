"""The converted nouns' dispatch, run by the entry point (orch/__main__.py)
once its interpreter check has passed.

main(argv) takes `<noun> <verb> ...` as orch.sh hands them on. A noun not in
NOUNS dies as orch.sh dies on an unknown command; `-h` and `--help`, help's
option spellings, run help, through ALIASES rather than NOUNS, since call_func
finds a noun's module by its name.
"""
from __future__ import annotations

import importlib
from typing import Callable, Dict, List

from orch.common import die


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


def _help(argv: List[str]) -> int:
    from orch.help import run

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
    "help": _help,
}

# The option spellings main runs as a noun: orch.sh hands them on as given.
ALIASES: Dict[str, str] = {"-h": "help", "--help": "help"}


def main(argv: List[str]) -> int:
    noun = argv[0] if argv else ""
    run = NOUNS.get(ALIASES.get(noun, noun))
    if run is None:
        die("unknown command: %s (run 'orch.sh help')" % noun)
    return run(argv[1:])


def call_func(argv: List[str]) -> int:
    """`orch_python_call [--as <command>] <noun> <func> [<arg>...]`, its
    `--as <command>` already taken off by orch.__main__: runs the named
    function of a converted noun's module with `<arg>...`, returning its exit
    code (0 when it returns None). Refuses an unknown noun or a missing or
    private function."""
    if len(argv) < 2:
        die("usage: orch_python_call [--as <command>] <noun> <func> [<arg>...]")
    noun, name, args = argv[0], argv[1], argv[2:]
    if noun not in NOUNS:
        die("unknown command: %s (run 'orch.sh help')" % noun)
    if not name or name.startswith("_"):
        die("unknown %s function: %s" % (noun, name or "<none>"))
    mod = importlib.import_module("orch." + noun.replace("-", "_"))
    fn = getattr(mod, name, None)
    if not callable(fn):
        die("unknown %s function: %s" % (noun, name))
    result = fn(args)
    return 0 if result is None else result
