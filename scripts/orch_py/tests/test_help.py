"""The help noun run in-process: `help` prints orch.sh's command list, byte
for byte the text of help/golden.txt - bash cmd_help's output, captured from
`orch.sh help` before the bash noun was deleted - whatever arguments follow
it, as cmd_help ignored them. The entries the deleted bash sections pinned are
checked here by name too, so a regenerated golden file cannot drop one
unnoticed."""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from orch import help as help_noun

GOLDEN = Path(__file__).resolve().parent / "help" / "golden.txt"
FILED_FINDING_SH = Path(__file__).resolve().parents[2] / "orch" / "filed-finding.sh"


def help_text(capsys, *argv):
    """`orch.sh help <argv>` in-process: its stdout, after checking it exits 0
    and prints nothing on stderr."""
    assert help_noun.run(list(argv)) == 0
    out, err = capsys.readouterr()
    assert err == ""
    return out


@pytest.mark.parametrize("argv", [(), ("extra", "words")], ids=["bare", "ignored-arguments"])
def test_help_prints_the_golden_text_byte_for_byte(capsys, argv):
    assert help_text(capsys, *argv).encode("utf-8") == GOLDEN.read_bytes()


@pytest.mark.parametrize("entry", [
    "review begin", "review ci", "review file", "review terminal", "review retire",
    "finding-triage scan [--all] [<issue> | --pr <n>]",
    "--all: every open review:<severity> finding",
    "TAB <detail> TAB <state>",
    "finding-triage apply <issue> <close-fixed|wontfix> --comment-file <file>",
    "--category <bug|enhancement> --comment-file <file>",
    "issue publish", "pr publish", "pr release [--force] <title> <body-file>", "pr open",
    "ticket publish", "ticket next", "ticket close", "ticket reset",
    "branch retire", "branch create", "branch off", "redo review", "redo spec",
])
def test_help_documents_the_entry(capsys, entry):
    assert entry in help_text(capsys)


def test_help_gives_review_file_the_finding_s_parts_as_flags(capsys):
    """The severities and axes come from the bash Filed finding tables that
    review file reads, so help names the ones review file takes."""
    tables = subprocess.run(
        ["bash", "-c", 'source "$1"; printf "%s\\n%s" "${FILED_SEVERITIES// /|}" "${FILED_AXES// /|}"',
         "_", str(FILED_FINDING_SH)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, check=True, timeout=30,
    ).stdout.decode()
    severities, axes = tables.split("\n")
    out = help_text(capsys)
    lines = out.splitlines()
    first = next(i for i, line in enumerate(lines) if line.startswith("  review file "))

    assert ("review file <%s> <title> --axis <%s> --finding-file <f> --severity-reason <r>"
            " --location <<file>:<line>> --why <reason> [--spec-question <q>]"
            % (severities, axes)) in " ".join(out.split())
    assert "--body-file" not in "\n".join(lines[first:first + 4])


def test_help_names_none_of_the_retired_loop_machinery(capsys):
    assert "loop-next" not in help_text(capsys)
