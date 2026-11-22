"""The parallel noun run in-process against a FakeGit whose config_value
answers are seeded: `parallel show` prints the clone's parallel cap,
orchestrator.parallel in base 10, or 3 when it is unset, and refuses a value
that is not a positive integer, an argument, and an op it does not have - each
checked by its stdout, its exit code and its `orch:` message, as the bash
parallel noun answered."""
from __future__ import annotations

import pytest

from conftest import died_of
from orch import cli, parallel
from orch.git import FakeGit

KEY = "orchestrator.parallel"


def orch_parallel(*argv, value=None):
    """`orch.sh parallel <argv>` in-process, git config holding <value> for
    orchestrator.parallel, none when None: its exit code."""
    git = FakeGit(toplevel="/nonexistent/checkout")
    git.seed("config_value", KEY, answer=value)
    return parallel.run(list(argv), git=git, env={})


def test_the_cap_is_3_when_orchestrator_parallel_is_unset(capsys):
    assert orch_parallel("show") == 0
    assert capsys.readouterr() == ("3\n", "")


@pytest.mark.parametrize("value", ["5", "1"])
def test_the_cap_is_orchestrator_parallel_s_value_when_set(capsys, value):
    assert orch_parallel("show", value=value) == 0
    assert capsys.readouterr() == ("%s\n" % value, "")


def test_a_cap_with_leading_zeros_prints_in_base_10(capsys):
    assert orch_parallel("show", value="007") == 0
    assert capsys.readouterr() == ("7\n", "")


@pytest.mark.parametrize("value", ["0", "00", "-2", "three", "2x"])
def test_a_cap_that_is_not_a_positive_integer_is_refused(capsys, value):
    assert died_of(capsys, lambda: orch_parallel("show", value=value)) == (
        1, "", "orch: orchestrator.parallel is %s - it must be a positive integer"
               " (git config orchestrator.parallel <n>)\n" % value)


def test_show_refuses_an_argument(capsys):
    assert died_of(capsys, lambda: orch_parallel("show", "extra", value="5")) == (
        1, "", "orch: usage: orch.sh parallel show\n")


@pytest.mark.parametrize("argv, named", [(("bogus",), "bogus"), ((), "<none>")],
                         ids=["unknown", "missing"])
def test_an_op_the_noun_does_not_have_is_refused(capsys, argv, named):
    assert died_of(capsys, lambda: orch_parallel(*argv)) == (
        1, "", "orch: unknown parallel op: %s (want show)\n" % named)


def test_outside_a_checkout_every_op_dies_first(capsys):
    code, out, err = died_of(
        capsys, lambda: parallel.run(["show"], git=FakeGit(toplevel=None), env={}))

    assert (code, out) == (1, "")
    assert err.startswith("orch: not inside a git repository")


def test_the_cli_dispatch_registers_the_noun():
    assert "parallel" in cli.NOUNS
