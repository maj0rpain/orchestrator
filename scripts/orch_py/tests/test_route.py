"""The route noun run in-process against a FakeGit whose config_value answers
are seeded: `route show` prints the default route, orchestrator.route, or
none when it is unset or empty, and refuses an unknown route, an argument, and
an op it does not have - each checked by its stdout, its exit code and its
`orch:` message, as the bash route noun answered."""
from __future__ import annotations

import pytest

from conftest import died_of
from orch import cli, route
from orch.git import FakeGit

KEY = "orchestrator.route"


def orch_route(*argv, value=None):
    """`orch.sh route <argv>` in-process, git config holding <value> for
    orchestrator.route, none when None: its exit code."""
    git = FakeGit(toplevel="/nonexistent/checkout")
    git.seed("config_value", KEY, answer=value)
    return route.run(list(argv), git=git, env={})


@pytest.mark.parametrize("value", [None, ""], ids=["unset", "empty"])
def test_the_route_is_none_when_orchestrator_route_is_unset_or_empty(capsys, value):
    assert orch_route("show", value=value) == 0
    assert capsys.readouterr() == ("none\n", "")


@pytest.mark.parametrize("value", ["flow", "quick", "blueprint", "autopilot"])
def test_a_route_word_set_is_printed(capsys, value):
    assert orch_route("show", value=value) == 0
    assert capsys.readouterr() == ("%s\n" % value, "")


@pytest.mark.parametrize("value", ["sideways", "Flow", "none"])
def test_an_unknown_route_is_refused(capsys, value):
    assert died_of(capsys, lambda: orch_route("show", value=value)) == (
        1, "", "orch: orchestrator.route is %s - it must be one of flow, quick, blueprint"
               " or autopilot (git config orchestrator.route <route>)\n" % value)


def test_show_refuses_an_argument(capsys):
    assert died_of(capsys, lambda: orch_route("show", "extra", value="flow")) == (
        1, "", "orch: usage: orch.sh route show\n")


@pytest.mark.parametrize("argv, named", [(("bogus",), "bogus"), ((), "<none>")],
                         ids=["unknown", "missing"])
def test_an_op_the_noun_does_not_have_is_refused(capsys, argv, named):
    assert died_of(capsys, lambda: orch_route(*argv)) == (
        1, "", "orch: unknown route op: %s (want show)\n" % named)


def test_outside_a_checkout_every_op_dies_first(capsys):
    code, out, err = died_of(
        capsys, lambda: route.run(["show"], git=FakeGit(toplevel=None), env={}))

    assert (code, out) == (1, "")
    assert err.startswith("orch: not inside a git repository")


def test_the_cli_dispatch_registers_the_noun():
    assert "route" in cli.NOUNS
