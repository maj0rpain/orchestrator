"""The Marked comment module's writer, marked_comment_write, pinned to bash's
by running each argument list through both: the line each kind opens with,
and each refusal's message and exit status."""
from __future__ import annotations

from pathlib import Path

import pytest

from conftest import bash_sourced
from orch.marked_comment import marked_comment_write

SCRIPTS = Path(__file__).resolve().parents[2]

# The bash writer on the argument list after the modules, its stdout and
# stderr together, then its status.
BASH_RUN = r'''
source "$1"
orch_load marked-comment
shift
st=0
( marked_comment_write "$@" ) 2>&1 || st=$?
printf 'status %s\n' "$st"
'''

CASES = [
    ("handoff", "03-implement", "retired"),
    ("handoff", "03-implement"),
    ("limited", "spec", "github"),
    ("spec-review",),
    ("spec-ruling",),
    ("spec-review", "x"),
    ("spec-review", ""),
    ("nope", "x"),
    ("question", "a b"),
    ("question", ""),
    ("question",),
    ("question", "x", "retired"),
    ("handoff", "x", "github"),
    ("handoff", "x", "bogus"),
]


@pytest.mark.parametrize("args", CASES)
def test_a_marked_comment_line_or_refusal_is_bash_s_for_the_same_arguments(capsys, args):
    bash = bash_sourced(SCRIPTS / "orch" / "common.sh", BASH_RUN, SCRIPTS / "orch" / "loader.sh",
                        *args)
    try:
        python = marked_comment_write(*args) + "status 0\n"
    except SystemExit as died:
        python = capsys.readouterr().err + "status %s\n" % died.code

    assert python == bash
