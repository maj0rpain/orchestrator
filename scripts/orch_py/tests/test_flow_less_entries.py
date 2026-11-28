"""The flow-less entries classification: every top-level .orchestrator/<name>
the code builds, in the bash scripts and the Python package, is on the Python
FLOW_LESS_ENTRIES or among the flow's own entries, and every listed entry is
built somewhere. A scan of the source text, so a new entry is classified the
day it is written."""
from __future__ import annotations

import re
import shutil
from pathlib import Path

import pytest

from orch.side_checkout import FLOW_LESS_ENTRIES

SCRIPTS = Path(__file__).resolve().parents[2]

# The flow's own top-level entries: archive_flow moves each into the archive.
FLOW_OWN = ("state.json", "handoff", "review", "scratch", "spec-rounds", "worktrees")

RULE = ("The rule: an entry a command creates for work that belongs to no flow goes on "
        "FLOW_LESS_ENTRIES (scripts/orch_py/orch/side_checkout.py); every other entry is "
        "the flow's and goes on the test's list of the flow's own entries.")

BASH_ENTRY = re.compile(r"\$\{?(?:ORCH|ORCH_DIR_NAME|home)\}?/[a-z][a-z.-]*")
BASH_PRINTF = re.compile(r"printf '%s/(?:%s/)?[a-z]")
BASH_PRINTF_ENTRY = re.compile(r"'%s/(?:%s/)?[a-z][a-z.-]*")
BASH_NAMES_ORCH = re.compile(r"\$\{?ORCH(?:_DIR_NAME)?(?:[^A-Za-z_]|$)")
PY_JOIN = re.compile(r'ORCH_DIR_NAME, *"([a-z][a-z.-]*)"')
PY_ORCH_DIR = re.compile(r'orch_dir \+ "/([a-z][a-z.-]*)"')
PY_FORMAT = re.compile(r'"%s/%s/[a-z]')
PY_FORMAT_ENTRY = re.compile(r'"%s/%s/[a-z][a-z.-]*')


def source_lines(paths):
    for path in paths:
        yield from path.read_text(encoding="utf-8", errors="replace").splitlines()


def last_part(match: str) -> str:
    return match.rsplit("/", 1)[1]


def built_entries(scripts: Path) -> set:
    """Every top-level .orchestrator/<name> the code under <scripts> builds:
    in orch.sh, flow-state.sh and orch/*.sh as $ORCH/<name>,
    $ORCH_DIR_NAME/<name>, $home/<name>, or a printf format '%s/<name>' or
    '%s/%s/<name>' on a line naming $ORCH or $ORCH_DIR_NAME; in the Python
    package's orch_py/orch/*.py as a join's ORCH_DIR_NAME, "<name>", a format
    "%s/%s/<name>" on a line naming ORCH_DIR_NAME, or orch_dir + "/<name>",
    the orchestrator directory handed in."""
    bash = [scripts / "orch.sh", scripts / "flow-state.sh", *sorted((scripts / "orch").glob("*.sh"))]
    python = sorted((scripts / "orch_py" / "orch").glob("*.py"))
    found = set()
    for line in source_lines(p for p in bash if p.is_file()):
        found.update(last_part(m) for m in BASH_ENTRY.findall(line))
        if BASH_PRINTF.search(line) and BASH_NAMES_ORCH.search(line):
            found.update(last_part(m) for m in BASH_PRINTF_ENTRY.findall(line))
    for line in source_lines(python):
        found.update(PY_JOIN.findall(line))
        found.update(PY_ORCH_DIR.findall(line))
        if PY_FORMAT.search(line) and "ORCH_DIR_NAME" in line:
            found.update(last_part(m) for m in PY_FORMAT_ENTRY.findall(line))
    return found


def classification_report(scripts: Path, flow_less) -> str:
    """One line per entry the code builds that is on neither <flow_less> nor
    the flow's own entries, and per listed entry never built, then the rule;
    empty when every entry is classified."""
    found = built_entries(scripts)
    listed = set(flow_less) | set(FLOW_OWN)
    lines = [".orchestrator/%s is built by orch.sh but is on neither FLOW_LESS_ENTRIES nor "
             "the flow's own entries" % name for name in sorted(found - listed)]
    lines += ["listed entry %s was never found in the scan" % name for name in sorted(listed - found)]
    return "\n".join(lines + [RULE]) if lines else ""


def scripts_copy(tmp_path: Path) -> Path:
    """The scanned files of the scripts directory, copied under tmp_path."""
    root = tmp_path / "scripts"
    (root / "orch").mkdir(parents=True)
    (root / "orch_py" / "orch").mkdir(parents=True)
    for name in ("orch.sh", "flow-state.sh"):
        if (SCRIPTS / name).is_file():
            shutil.copy(SCRIPTS / name, root / name)
    for f in (SCRIPTS / "orch").glob("*.sh"):
        shutil.copy(f, root / "orch" / f.name)
    for f in (SCRIPTS / "orch_py" / "orch").glob("*.py"):
        shutil.copy(f, root / "orch_py" / "orch" / f.name)
    return root


def test_every_top_level_orchestrator_entry_the_code_builds_is_classified():
    assert classification_report(SCRIPTS, FLOW_LESS_ENTRIES) == ""


@pytest.mark.parametrize("where, line, name", [
    ("orch/common.sh", 'newthing_dir() { printf "%s\\n" "$ORCH/brandnew"; }', "brandnew"),
    ("orch/common.sh", "printf '%s/bashformat' \"$ORCH_DIR_NAME\"", "bashformat"),
    ("orch_py/orch/checkout.py", 'PY_NEW = os.path.join("/", ORCH_DIR_NAME, "pynew")', "pynew"),
    ("orch_py/orch/checkout.py", 'PY_FMT = "%s/%s/pyformat/%s" % ("/", ORCH_DIR_NAME, 1)',
     "pyformat"),
    ("orch_py/orch/checkout.py", 'PY_DIR = orch_dir + "/pyorchdir"', "pyorchdir"),
])
def test_an_unclassified_entry_fails_the_classification(tmp_path, where, line, name):
    root = scripts_copy(tmp_path)
    with open(root / where, "a", encoding="utf-8") as f:
        f.write(line + "\n")

    assert classification_report(root, FLOW_LESS_ENTRIES).splitlines()[0] == (
        ".orchestrator/%s is built by orch.sh but is on neither FLOW_LESS_ENTRIES nor "
        "the flow's own entries" % name)


def test_a_listed_entry_the_code_never_builds_fails_the_classification():
    report = classification_report(SCRIPTS, FLOW_LESS_ENTRIES + ("neverbuilt",))

    assert report.splitlines()[0] == "listed entry neverbuilt was never found in the scan"


def test_the_classification_failure_names_the_python_list():
    report = classification_report(SCRIPTS, FLOW_LESS_ENTRIES + ("neverbuilt",))

    assert report.splitlines()[-1] == (
        "The rule: an entry a command creates for work that belongs to no flow goes on "
        "FLOW_LESS_ENTRIES (scripts/orch_py/orch/side_checkout.py); every other entry is "
        "the flow's and goes on the test's list of the flow's own entries.")
