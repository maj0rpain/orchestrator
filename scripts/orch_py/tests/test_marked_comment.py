"""The Marked comment module's writer, marked_comment_write: the line each kind
opens with, and each refusal's message and exit status, as the bash writer gave
them before it went (#4266)."""
from __future__ import annotations

import pytest

from orch.marked_comment import marked_comment_write

CASES = [
    (("handoff", "03-implement", "retired"), "<!-- orch:handoff 03-implement retired -->\nstatus 0\n"),
    (("handoff", "03-implement"), "<!-- orch:handoff 03-implement -->\nstatus 0\n"),
    (("limited", "spec", "github"), "<!-- orch:limited spec github -->\nstatus 0\n"),
    (("spec-review",), "## Spec review\nstatus 0\n"),
    (("spec-ruling",), "Spec ruling:\nstatus 0\n"),
    (("spec-review", "x"), "orch: marked comment: spec-review takes no argument\nstatus 1\n"),
    (("spec-review", ""), "orch: marked comment: spec-review takes no argument\nstatus 1\n"),
    (("nope", "x"), "orch: marked comment: unknown kind: nope\nstatus 1\n"),
    (("question", "a b"),
     "orch: marked comment: question needs an argument without whitespace\nstatus 1\n"),
    (("question", ""),
     "orch: marked comment: question needs an argument without whitespace\nstatus 1\n"),
    (("question",),
     "orch: marked comment: question needs an argument without whitespace\nstatus 1\n"),
    (("question", "x", "retired"), "orch: marked comment: only a handoff can be retired\nstatus 1\n"),
    (("handoff", "x", "github"),
     "orch: marked comment: only a limited comment takes a cause\nstatus 1\n"),
    (("handoff", "x", "bogus"), "orch: marked comment: unknown tag: bogus\nstatus 1\n"),
]


@pytest.mark.parametrize("args, answer", CASES)
def test_a_marked_comment_line_or_refusal_is_the_one_bash_gave_for_the_same_arguments(
        capsys, args, answer):
    try:
        python = marked_comment_write(*args) + "status 0\n"
    except SystemExit as died:
        python = capsys.readouterr().err + "status %s\n" % died.code

    assert python == answer
