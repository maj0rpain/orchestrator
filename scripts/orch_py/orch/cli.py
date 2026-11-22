"""The converted nouns' dispatch, run by the entry point (orch/__main__.py)
once its interpreter check has passed.

main(argv) takes `<noun> <verb> ...` as orch.sh hands them on. A noun not in
NOUNS dies as orch.sh dies on an unknown command.
"""
from __future__ import annotations

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
}


def main(argv: List[str]) -> int:
    noun = argv[0] if argv else ""
    run = NOUNS.get(noun)
    if run is None:
        die("unknown command: %s (run 'orch.sh help')" % noun)
    return run(argv[1:])
