"""The triage-label mapping: which rows of the repo's triage-labels doc are
read, and what each role's label is."""
from __future__ import annotations

import pytest

from orch.triage_labels import TriageLabels

HEADER = (
    "| Label in mattpocock/skills | Label in our tracker | Meaning |\n"
    "| --- | --- | --- |\n"
)


def mapping(tmp_path, doc):
    if doc is not None:
        path = tmp_path / "docs" / "agents" / "triage-labels.md"
        path.parent.mkdir(parents=True)
        path.write_text(doc)
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
