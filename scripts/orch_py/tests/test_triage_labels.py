"""The triage-label mapping: which rows of the repo's triage-labels doc are
read, and what each role's label is."""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from conftest import write_labels_doc
from orch.triage_labels import TRIAGE_ROLES, TriageLabels

TRIAGE_LABELS_SH = Path(__file__).resolve().parents[2] / "triage-labels.sh"

HEADER = (
    "| Label in mattpocock/skills | Label in our tracker | Meaning |\n"
    "| --- | --- | --- |\n"
)


def mapping(tmp_path, doc):
    if doc is not None:
        write_labels_doc(tmp_path, doc)
    return TriageLabels(lambda: str(tmp_path))


def test_a_role_the_doc_maps_takes_the_repos_label(tmp_path):
    labels = mapping(tmp_path, HEADER + "| `ready-for-agent` | `agent go` | AFK |\n")

    assert labels.label("ready-for-agent") == "agent go"
    assert labels.label("wontfix") == "wontfix"


@pytest.mark.parametrize(
    "doc",
    [None, "", HEADER + "| `ready-for-agent` |  | AFK |\n",
     "| Role | Label |\n| --- | --- |\n| ready-for-agent | agent go |\n"],
    ids=["no-doc", "empty-doc", "blank-label", "two-columns"],
)
def test_a_role_with_no_label_read_is_its_own_label(tmp_path, doc):
    assert mapping(tmp_path, doc).label("ready-for-agent") == "ready-for-agent"


def test_no_checkout_leaves_every_role_its_own_label():
    assert TriageLabels(lambda: None).label("ready-for-agent") == "ready-for-agent"


def test_an_escaped_pipe_stays_in_its_cell(tmp_path):
    labels = mapping(tmp_path, HEADER + "| `wontfix` | `no\\|way` | Not doing |\n")

    assert labels.label("wontfix") == "no|way"


def test_a_row_without_its_trailing_pipe_is_read(tmp_path):
    labels = mapping(tmp_path, HEADER + "| ready-for-agent | agent go | AFK\n")

    assert labels.label("ready-for-agent") == "agent go"


def test_a_table_naming_no_role_ahead_of_the_role_table_is_skipped(tmp_path):
    doc = (
        "| Thing | Other | Note |\n| --- | --- | --- |\n| colour | blue | sky |\n\n"
        + HEADER + "| ready-for-agent | agent go | AFK |\n"
    )

    assert mapping(tmp_path, doc).label("ready-for-agent") == "agent go"


def test_nothing_after_the_role_table_is_read(tmp_path):
    doc = (
        HEADER + "| needs-triage | triage me | Evaluate |\n\n"
        + HEADER + "| ready-for-agent | agent go | AFK |\n"
    )
    labels = mapping(tmp_path, doc)

    assert labels.label("needs-triage") == "triage me"
    assert labels.label("ready-for-agent") == "ready-for-agent"


def test_every_role_reads_as_the_bash_parser_reads_it(tmp_path):
    docs = [
        HEADER + "| `ready-for-agent` | `agent go` | AFK |\n| wontfix | no\\|pe | x |\n",
        "| Role | Label |\n| --- | --- |\n| ready-for-agent | two-col |\n",
        "| a | b | c |\n| :-: | --: | - |\n| needs-info | ask |\r\n| needs-triage | t | x |\n\n"
        + HEADER + "| ready-for-human | late | x |\n",
    ]
    roots = [tmp_path / str(i) for i in range(len(docs))]
    for root, doc in zip(roots, docs):
        mapping(root, doc)
    script = (
        'source "$1"; shift\n'
        'for ROOT in "$@"; do for r in $TRIAGE_ROLES; do triage_label_for "$r"; done; done\n'
    )
    run = subprocess.run(
        ["bash", "-c", script, "_", str(TRIAGE_LABELS_SH), *map(str, roots)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, timeout=30, check=True,
    )

    python = [TriageLabels(lambda root=root: str(root)).label(role)
              for root in roots for role in TRIAGE_ROLES]
    assert python == run.stdout.decode().split("\n")[:-1]
