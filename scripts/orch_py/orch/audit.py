"""The audit module (scripts/orch/audit.sh): the audit noun's begin verb,
which makes an audit run's working directory (ADR-0064), and an audit-filed
body's drift line, which the issue noun reads. orch.sh still runs the noun's
verbs from the bash module; run() is the Python noun they move to.

begin's checks all come before the run directory is made, and a write
failing after it is made removes it again; the git exclude lines already
written stay, as in bash.

An audit-filed body has exactly one **Audited at:** line, its value
hexadecimal, and at least one well-formed **Location:** line. Its drift line
says which of the cited files changed since the audited commit: compared
tree to tree with HEAD, so no ancestry is needed, uncommitted changes are not
counted, and a renamed file is listed as the path the body cites. The body is
untrusted: only a hexadecimal value reaches git as the commit, and every path
reaches it as a literal one (orch.git).
"""
from __future__ import annotations

import os
import re
import shutil
import time
from typing import Callable, List, Mapping, Optional, Tuple

from orch.common import ORCH_DIR_NAME, die, dir_stamp, exclude_orch_dirs
from orch.filed_finding import FILED_CATEGORIES
from orch.git import Git
from orch.root import checkout_root

# The verbs, each a function of VERBS. docs_lint.sh reads a converted noun's
# verbs from this line, so it stays one `OPS = "<verb>|..."` line.
OPS = "begin"

# The kinds of audit `audit begin` takes, one per audit skill.
AUDIT_KINDS = ("code", "docs", "tests")

MARKER = "**Audited at:**"
LOCATION = "**Location:**"
_LOCATION_LINE = re.compile(r"\*\*Location:\*\* `([^`]*)`")
_HEX = re.compile(r"[0-9a-fA-F]+")
_LINES = re.compile(r"[0-9]+(-[0-9]+)?")
_SPACE = " \t\n\r\f\v"


def audit_file_usage() -> str:
    """The one-finding form's usage line, its categories the filed-finding
    list's, in order."""
    return (
        "usage: orch.sh audit file <title> --category <%s> --finding-file <f>"
        " --location <<file>:<line>|<file>:<start>-<end>> [--location ...]"
        % "|".join(name for name, _, _ in FILED_CATEGORIES)
    )


def audit_usage() -> str:
    """The usage text naming every form of the audit command, one per
    line."""
    return (
        "usage: orch.sh audit begin <%s>\n"
        "   or: orch.sh audit report <dir> <out.html>\n"
        "   or: orch.sh audit file --run <dir> <numbers>\n"
        "   or: %s" % ("|".join(AUDIT_KINDS), audit_file_usage()[len("usage: "):])
    )


def audit_begin(argv: List[str], git, root: str, clock: Callable[[], float]) -> int:
    """`audit begin <kind>`: makes <root>/.orchestrator/audit/<kind>-<stamp>/,
    the stamp <clock>'s UTC time, git-excluded through the git adapter <git>,
    records the kind and the HEAD commit in its `record` file, and prints its
    absolute path and nothing else. The directory is never reused. Reads and
    writes no flow state."""
    if len(argv) != 1 or argv[0] not in AUDIT_KINDS:
        die(audit_usage())
    kind = argv[0]
    sha = git.resolve_commit("HEAD")
    if sha is None:
        die("cannot read the HEAD commit")
    audits = os.path.join(root, ORCH_DIR_NAME, "audit")
    run_dir = os.path.join(audits, "%s-%s" % (kind, dir_stamp(clock)))
    if os.path.exists(run_dir):
        die("the audit run directory already exists: %s" % run_dir)
    try:
        os.makedirs(audits, exist_ok=True)
        os.mkdir(run_dir)
    except OSError:
        die("cannot make the audit run directory %s" % run_dir)
    made = False
    try:
        exclude_orch_dirs(git)
        try:
            with open(os.path.join(run_dir, "record"), "w", encoding="utf-8") as f:
                f.write("kind %s\ncommit %s\n" % (kind, sha))
        except OSError:
            die("cannot write the audit run record in %s" % run_dir)
        made = True
    finally:
        if not made:
            shutil.rmtree(run_dir, ignore_errors=True)
    print(run_dir)
    return 0


VERBS = {"begin": audit_begin}


def run(
    argv: List[str],
    git=None,
    env: Optional[Mapping[str, str]] = None,
    clock: Callable[[], float] = time.time,
) -> int:
    """`orch.sh audit <op> ...`: the real git adapter, the process's
    environment and the system clock unless a test hands in others. Outside
    a checkout it dies first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die(audit_usage())
    return VERBS[op](argv[1:], git, root, clock)


def body_parse(body: str) -> Tuple[List[str], List[str]]:
    """Every **Location:** line's backticked location, in order ("" for a
    line carrying none), and every **Audited at:** line's trimmed value."""
    locations, shas = [], []
    for line in body.split("\n"):
        if line.startswith(LOCATION):
            match = _LOCATION_LINE.fullmatch(line)
            locations.append(match.group(1) if match else "")
        elif line.startswith(MARKER):
            shas.append(line[len(MARKER):].strip(_SPACE))
    return locations, shas


def location_ok(location: str) -> bool:
    """Whether <location> is <file>:<line> or <file>:<start>-<end>, split at
    its last colon."""
    file, colon, lines = location.rpartition(":")
    return bool(colon and file) and _LINES.fullmatch(lines) is not None


def drift_line(body: str, git) -> Optional[str]:
    """The drift line of an audit-filed body - `cited files changed since
    <sha>: ` then none, the changed files joined by ", " in body order, each
    once, or unknown (<reason>) - read through the git adapter <git>; None
    for any other body."""
    locations, shas = body_parse(body)
    if len(shas) != 1 or not _HEX.fullmatch(shas[0]):
        return None
    sha = shas[0]
    cited: List[str] = []
    for location in locations:
        if location_ok(location):
            file = location.rpartition(":")[0]
            if file not in cited:
                cited.append(file)
    if not cited:
        return None
    prefix = "cited files changed since %s:" % sha
    changed = git.changed_paths(sha, cited)
    if changed is None:
        if not git.has_head_commit():
            reason = "no commit on HEAD"
        elif not git.has_commit(sha):
            reason = "commit not in this clone"
        else:
            reason = "git comparison failed"
        return "%s unknown (%s)" % (prefix, reason)
    listed = [file for file in cited if file in changed]
    return "%s %s" % (prefix, ", ".join(listed) if listed else "none")
