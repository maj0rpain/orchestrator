"""The agent noun run in-process on FakeGit and tmp_path: immutable HostSpec
table, canonical roles and name shapes, scoped config caching, all six CLI
verbs (set, show, clear, get, sync, roles), partial-mutation order on errors,
shared agent_sync_plan, and .junie/agents/ copy-sync."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import died_of
from orch import agent, cli
from orch.git import FakeGit


def orch_agent(git, *argv, env=None, plugin_root=None):
    """`orch.sh agent <argv>` in-process, in the checkout of <git>: its exit
    code, a SystemExit's included."""
    try:
        return agent.run(
            list(argv),
            git=git,
            env={} if env is None else env,
            plugin_root=plugin_root,
        )
    except SystemExit as died:
        return died.code


# --- HostSpec table, roles, CLI routing, checkout guard -----------------------


def test_host_spec_table_is_immutable_and_models_claude_and_junie_only():
    assert tuple(agent.HOST_SPECS.keys()) == ("claude", "junie")
    claude = agent.HOST_SPECS["claude"]
    junie = agent.HOST_SPECS["junie"]

    assert (claude.key_prefix, claude.line_prefix, claude.clear_flag) == ("orchestrator", "", "")
    assert (claude.flag_host, claude.syncs_copies) == (False, False)
    assert (junie.key_prefix, junie.line_prefix, junie.clear_flag) == (
        "orchestrator.junie", "junie ", " --host junie"
    )
    assert (junie.flag_host, junie.syncs_copies) == (True, True)
    assert claude.rules["model"].allowed == ("sonnet", "opus", "haiku", "fable", "inherit")
    assert claude.rules["effort"].allowed == ("low", "medium", "high", "xhigh", "max", "inherit")
    assert junie.rules["effort"].allowed == ("low", "medium", "high", "inherit")
    assert junie.rules["model"].pattern == "[A-Za-z0-9._:/-]+"
    assert junie.rules["model"].note is not None

    with pytest.raises(TypeError):
        agent.HOST_SPECS["antigravity"] = junie  # type: ignore[index]
    with pytest.raises(AttributeError):
        junie.syncs_copies = False  # type: ignore[misc]
    with pytest.raises(TypeError):
        junie.rules["model"] = claude.rules["model"]  # type: ignore[index]


def test_roles_lists_canonical_roles_and_refuses_extra_arguments(root, capsys):
    git = FakeGit(toplevel=str(root))

    assert orch_agent(git, "roles") == 0
    assert capsys.readouterr() == (
        "implementer\nlens\nreviewer\nfixer\ncloser\nresolver\nauditor\n", ""
    )

    assert orch_agent(git, "roles", "extra") == 1
    assert capsys.readouterr() == ("", "orch: usage: orch.sh agent roles\n")


def test_cli_routes_agent_noun_and_refuses_unknown_or_missing_op(root, capsys, monkeypatch):
    monkeypatch.setattr(agent, "Git", lambda: FakeGit(toplevel=str(root)))

    assert cli.main(["agent", "roles"]) == 0
    assert capsys.readouterr() == (
        "implementer\nlens\nreviewer\nfixer\ncloser\nresolver\nauditor\n", ""
    )

    assert died_of(capsys, lambda: cli.main(["agent"])) == (
        1, "", "orch: unknown agent op: <none> (want set|show|clear|get|sync|roles)\n"
    )
    assert died_of(capsys, lambda: cli.main(["agent", "bogus"])) == (
        1, "", "orch: unknown agent op: bogus (want set|show|clear|get|sync|roles)\n"
    )


def test_outside_a_checkout_dies_first(capsys):
    code, out, err = died_of(
        capsys, lambda: agent.run(["roles"], git=FakeGit(toplevel=None), env={})
    )

    assert (code, out) == (1, "")
    assert err.startswith("orch: not inside a git repository")


# --- agent get, agent show, and scoped config caching -------------------------


def test_get_resolves_local_global_and_inherit_per_key_for_both_hosts(root, capsys):
    git = FakeGit(
        toplevel=str(root),
        local_config=[
            ("orchestrator.model.fixer", "opus"),
            ("orchestrator.effort.closer", "xhigh"),
            ("orchestrator.model.resolver", "opus"),
            ("orchestrator.model.resolver", "sonnet"),
            ("orchestrator.junie.model.implementer", "custom:my/profile.1"),
            ("orchestrator.junie.effort.reviewer", "low"),
        ],
        global_config={
            "orchestrator.model.fixer": "sonnet",
            "orchestrator.effort.fixer": "max",
            "orchestrator.model.closer": "fable",
            "orchestrator.junie.model.reviewer": "gpt-5",
        },
    )

    assert orch_agent(git, "get", "implementer") == 0
    assert capsys.readouterr() == ("model inherit\neffort inherit\n", "")

    assert orch_agent(git, "get", "fixer") == 0
    assert capsys.readouterr() == ("model opus\neffort max\n", "")

    assert orch_agent(git, "get", "closer") == 0
    assert capsys.readouterr() == ("model fable\neffort xhigh\n", "")

    assert orch_agent(git, "get", "resolver") == 0
    assert capsys.readouterr() == ("model sonnet\neffort inherit\n", "")

    assert orch_agent(git, "get", "implementer", "--host", "junie") == 0
    assert capsys.readouterr() == ("model custom:my/profile.1\neffort inherit\n", "")

    assert orch_agent(git, "get", "reviewer", "--host", "junie") == 0
    assert capsys.readouterr() == ("model gpt-5\neffort low\n", "")

    assert orch_agent(git, "get", "lens", "--host", "junie") == 0
    assert capsys.readouterr() == ("model inherit\neffort inherit\n", "")


def test_get_refuses_disallowed_values_with_key_allowed_values_and_clear_remedy(root, capsys):
    git = FakeGit(
        toplevel=str(root),
        local_config=[
            ("orchestrator.effort.resolver", "gpt"),
            ("orchestrator.model.reviewer", "opus haiku"),
            ("orchestrator.effort.auditor", None),
            ("orchestrator.model.fixer", "opus\nsonnet"),
            ("orchestrator.junie.effort.fixer", "xhigh"),
        ],
        global_config={
            "orchestrator.model.lens": "gpt-5",
            "orchestrator.junie.model.closer": "bad model",
        },
    )

    assert orch_agent(git, "get", "resolver") == 1
    assert capsys.readouterr() == (
        "",
        "orch: orchestrator.effort.resolver is gpt - not an allowed effort"
        " (want low|medium|high|xhigh|max|inherit)"
        " - clear it: orch.sh agent clear resolver --effort\n",
    )

    assert orch_agent(git, "get", "lens") == 1
    assert capsys.readouterr() == (
        "",
        "orch: orchestrator.model.lens is gpt-5 - not an allowed model"
        " (want sonnet|opus|haiku|fable|inherit)"
        " - clear it: orch.sh agent clear lens --model --global\n",
    )

    assert orch_agent(git, "get", "reviewer") == 1
    out, err = capsys.readouterr()
    assert out == ""
    assert "orch: orchestrator.model.reviewer is opus haiku - not an allowed model" in err

    assert orch_agent(git, "get", "auditor") == 1
    out, err = capsys.readouterr()
    assert out == ""
    assert "orch: orchestrator.effort.auditor is  - not an allowed effort" in err

    assert orch_agent(git, "get", "fixer") == 1
    out, err = capsys.readouterr()
    assert out == ""
    assert "orch: orchestrator.model.fixer is opus\nsonnet - not an allowed model" in err

    assert orch_agent(git, "get", "fixer", "--host", "junie") == 1
    assert capsys.readouterr() == (
        "",
        "orch: orchestrator.junie.effort.fixer is xhigh - not an allowed effort"
        " (want low|medium|high|inherit)"
        " - clear it: orch.sh agent clear fixer --host junie --effort\n",
    )

    assert orch_agent(git, "get", "closer", "--host", "junie") == 1
    out, err = capsys.readouterr()
    assert out == ""
    assert "orch: orchestrator.junie.model.closer is bad model - not an allowed model" in err
    assert "[A-Za-z0-9._:/-]+" in err
    assert "aliases resolve unpredictably" in err
    assert "clear it: orch.sh agent clear closer --host junie --model --global\n" in err


def test_get_validates_flag_shape_host_and_role_in_order(root, capsys):
    git = FakeGit(toplevel=str(root))

    assert orch_agent(git, "get") == 1
    assert capsys.readouterr() == ("", "orch: usage: orch.sh agent get <role> [--host junie]\n")

    assert orch_agent(git, "get", "lens", "--host", "junie", "--host", "junie") == 1
    assert capsys.readouterr() == ("", "orch: usage: orch.sh agent get <role> [--host junie]\n")

    assert orch_agent(git, "get", "lens", "--global") == 1
    assert capsys.readouterr() == ("", "orch: usage: orch.sh agent get <role> [--host junie]\n")

    assert orch_agent(git, "get", "lens", "--host") == 1
    assert capsys.readouterr() == ("", "orch: --host needs a value (want junie)\n")

    assert orch_agent(git, "get", "bogus", "--host", "codex") == 1
    assert capsys.readouterr() == ("", "orch: host codex is not allowed (want junie)\n")

    assert orch_agent(git, "get", "implementor") == 1
    assert capsys.readouterr() == (
        "",
        "orch: unknown role implementor"
        " (want implementer|lens|reviewer|fixer|closer|resolver|auditor)\n",
    )

    assert orch_agent(git, "get", "lens reviewer") == 1
    assert capsys.readouterr() == (
        "",
        "orch: unknown role lens reviewer"
        " (want implementer|lens|reviewer|fixer|closer|resolver|auditor)\n",
    )


def test_show_lists_all_roles_for_claude_then_junie_marking_invalid_values(root, capsys):
    git = FakeGit(
        toplevel=str(root),
        local_config=[
            ("orchestrator.model.implementer", "opus"),
            ("orchestrator.effort.implementer", "high"),
            ("orchestrator.model.reviewer", "haiku"),
            ("orchestrator.effort.reviewer", "low"),
            ("orchestrator.effort.closer", "xhigh"),
            ("orchestrator.effort.resolver", None),
            ("orchestrator.model.auditor", "opus\nsonnet"),
            ("orchestrator.junie.model.implementer", "custom:my/profile.1"),
            ("orchestrator.junie.model.lens", "gpt-5"),
            ("orchestrator.junie.effort.lens", "medium"),
            ("orchestrator.junie.effort.reviewer", "low"),
            ("orchestrator.junie.effort.fixer", "extreme"),
        ],
        global_config={
            "orchestrator.model.fixer": "sonnet",
            "orchestrator.model.closer": "fable",
            "orchestrator.junie.model.reviewer": "gpt-5",
            "orchestrator.junie.model.closer": "bad model",
        },
    )

    assert orch_agent(git, "show") == 0
    assert capsys.readouterr() == (
        "implementer model opus (local) effort high (local)\n"
        "lens model inherit (inherit) effort inherit (inherit)\n"
        "reviewer model haiku (local) effort low (local)\n"
        "fixer model sonnet (global) effort inherit (inherit)\n"
        "closer model fable (global) effort xhigh (local)\n"
        "resolver model inherit (inherit) effort  (local, invalid)\n"
        "auditor model opus\nsonnet (local, invalid) effort inherit (inherit)\n"
        "junie implementer model custom:my/profile.1 (local) effort inherit (inherit)\n"
        "junie lens model gpt-5 (local) effort medium (local)\n"
        "junie reviewer model gpt-5 (global) effort low (local)\n"
        "junie fixer model inherit (inherit) effort extreme (local, invalid)\n"
        "junie closer model bad model (global, invalid) effort inherit (inherit)\n"
        "junie resolver model inherit (inherit) effort inherit (inherit)\n"
        "junie auditor model inherit (inherit) effort inherit (inherit)\n",
        "",
    )

    assert orch_agent(git, "show", "extra") == 1
    assert capsys.readouterr() == ("", "orch: usage: orch.sh agent show\n")


def test_config_cache_loads_each_scope_once_per_run(root, capsys):
    class CountingGit(FakeGit):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.regexp_calls = []

        def config_regexp(self, scope, pattern):
            self.regexp_calls.append(scope)
            return super().config_regexp(scope, pattern)

    git = CountingGit(toplevel=str(root), local_config={"orchestrator.model.lens": "opus"})

    assert orch_agent(git, "show") == 0
    capsys.readouterr()
    assert git.regexp_calls == ["local", "global"]

    git.regexp_calls.clear()
    assert orch_agent(git, "get", "lens") == 0
    capsys.readouterr()
    assert git.regexp_calls == ["local", "global"]


# --- agent set and agent clear ------------------------------------------------


def test_set_writes_local_and_global_and_unsets_on_inherit(root, tmp_path, capsys):
    git = FakeGit(toplevel=str(root))
    empty_plugin = str(tmp_path / "no-agents")

    assert orch_agent(git, "set", "implementer", "--model", "opus", "--effort", "high") == 0
    assert capsys.readouterr() == ("", "")
    assert git.config_regexp("local", r"^orchestrator\.") == {
        "orchestrator.model.implementer": "opus",
        "orchestrator.effort.implementer": "high",
    }
    assert git.config_regexp("global", r"^orchestrator\.") == {}

    assert orch_agent(git, "set", "fixer", "--model", "sonnet", "--effort", "max", "--global") == 0
    assert git.config_regexp("global", r"^orchestrator\.") == {
        "orchestrator.model.fixer": "sonnet",
        "orchestrator.effort.fixer": "max",
    }
    assert orch_agent(git, "set", "fixer", "--model", "opus") == 0
    assert orch_agent(git, "set", "fixer", "--model", "inherit") == 0
    assert "orchestrator.model.fixer" not in git.config_regexp("local", r"^orchestrator\.")
    assert orch_agent(git, "get", "fixer") == 0
    assert capsys.readouterr() == ("model sonnet\neffort max\n", "")

    assert orch_agent(git, "set", "fixer", "--effort", "inherit", "--global") == 0
    assert git.config_regexp("global", r"^orchestrator\.") == {
        "orchestrator.model.fixer": "sonnet",
    }

    # --host junie works with --host either before or after --model/--effort.
    assert orch_agent(
        git, "set", "lens", "--model", "gpt-5", "--effort", "medium", "--host", "junie",
        plugin_root=empty_plugin,
    ) == 0
    assert orch_agent(
        git, "set", "implementer", "--host", "junie", "--model", "custom:my/profile.1",
        plugin_root=empty_plugin,
    ) == 0
    assert git.config_regexp("local", r"^orchestrator\.junie\.") == {
        "orchestrator.junie.model.lens": "gpt-5",
        "orchestrator.junie.effort.lens": "medium",
        "orchestrator.junie.model.implementer": "custom:my/profile.1",
    }
    assert "orchestrator.model.lens" not in git.config_regexp("local", r"^orchestrator\.")


def test_set_validates_flags_and_values_in_order_without_mutating_config(root, capsys):
    git = FakeGit(
        toplevel=str(root),
        local_config={"orchestrator.model.implementer": "opus"},
        global_config={"orchestrator.effort.fixer": "high"},
    )
    before = (
        git.config_regexp("local", r"."),
        git.config_regexp("global", r"."),
    )

    cases = [
        (["set"],
         "orch: unknown role <none> (want implementer|lens|reviewer|fixer|closer|resolver|auditor)\n"),
        (["set", "implementor", "--model", "opus"],
         "orch: unknown role implementor (want implementer|lens|reviewer|fixer|closer|resolver|auditor)\n"),
        (["set", "lens reviewer", "--model", "opus"],
         "orch: unknown role lens reviewer (want implementer|lens|reviewer|fixer|closer|resolver|auditor)\n"),
        (["set", "lens", "--model", "gpt"],
         "orch: model gpt is not allowed (want sonnet|opus|haiku|fable|inherit)\n"),
        (["set", "lens", "--effort", "huge"],
         "orch: effort huge is not allowed (want low|medium|high|xhigh|max|inherit)\n"),
        (["set", "lens", "--model", "opus haiku"],
         "orch: model opus haiku is not allowed (want sonnet|opus|haiku|fable|inherit)\n"),
        (["set", "lens", "--effort", "low\nmedium"],
         "orch: effort low\nmedium is not allowed (want low|medium|high|xhigh|max|inherit)\n"),
        (["set", "lens"],
         "orch: agent set needs --model or --effort (models: sonnet|opus|haiku|fable|inherit;"
         " efforts: low|medium|high|xhigh|max|inherit)\n"),
        (["set", "lens", "--model", "sonnet", "--effort", "bogus"],
         "orch: effort bogus is not allowed (want low|medium|high|xhigh|max|inherit)\n"),
        (["set", "lens", "--model"],
         "orch: --model needs a value (want sonnet|opus|haiku|fable|inherit)\n"),
        (["set", "lens", "--model", "opus", "--model"],
         "orch: --model needs a value (want sonnet|opus|haiku|fable|inherit)\n"),
        (["set", "lens", "--model", "opus", "--model", "haiku"],
         "orch: usage: orch.sh agent set <role> [--model <m>] [--effort <e>] [--global] [--host junie]\n"),
        (["set", "implementer", "--model", "bogus", "--global", "--global"],
         "orch: model bogus is not allowed (want sonnet|opus|haiku|fable|inherit)\n"),
        (["set", "implementer", "--effort", "bad", "--model"],
         "orch: effort bad is not allowed (want low|medium|high|xhigh|max|inherit)\n"),
        (["set", "implementer", "--effort", "bad", "--model", "bad"],
         "orch: effort bad is not allowed (want low|medium|high|xhigh|max|inherit)\n"),
        (["set", "lens", "--host", "codex", "--model", "opus"],
         "orch: host codex is not allowed (want junie)\n"),
        (["set", "lens", "--host"],
         "orch: --host needs a value (want junie)\n"),
        (["set", "lens", "--host", "junie", "--host", "junie", "--model", "gpt-5"],
         "orch: usage: orch.sh agent set <role> [--model <m>] [--effort <e>] [--global] [--host junie]\n"),
        (["set", "lens", "--host", "junie", "--effort", "xhigh"],
         "orch: effort xhigh is not allowed (want low|medium|high|inherit)\n"),
        (["set", "lens", "--host", "junie", "--model", "GPT 5"],
         "orch: model GPT 5 is not allowed (want inherit or a name matching [A-Za-z0-9._:/-]+"
         " - use the names Junie's /model picker and --model flag take; aliases resolve unpredictably)\n"),
        (["set", "lens", "--host", "junie", "--model", "a;b"],
         "orch: model a;b is not allowed (want inherit or a name matching [A-Za-z0-9._:/-]+"
         " - use the names Junie's /model picker and --model flag take; aliases resolve unpredictably)\n"),
        (["set", "lens", "--host", "junie", "--model", "gpt\nx"],
         "orch: model gpt\nx is not allowed (want inherit or a name matching [A-Za-z0-9._:/-]+"
         " - use the names Junie's /model picker and --model flag take; aliases resolve unpredictably)\n"),
        (["set", "lens", "--unknown"],
         "orch: usage: orch.sh agent set <role> [--model <m>] [--effort <e>] [--global] [--host junie]\n"),
    ]
    for argv, expected_err in cases:
        assert orch_agent(git, *argv) == 1
        assert capsys.readouterr() == ("", expected_err)
        assert (git.config_regexp("local", r"."), git.config_regexp("global", r".")) == before


def test_set_applies_model_then_effort_and_aborts_on_write_or_unset_error_without_rollback(
    root, capsys
):
    # Even when --effort is passed first on CLI, model writes first; if effort
    # fails, model stays written (no rollback).
    git = FakeGit(
        toplevel=str(root),
        config_write_fails=[("local", "orchestrator.effort.implementer")],
    )
    assert orch_agent(git, "set", "implementer", "--effort", "high", "--model", "opus") == 1
    out, err = capsys.readouterr()
    assert out == ""
    assert err.startswith("orch: ")
    assert "orchestrator.effort.implementer" in err
    assert "local" in err
    assert git.config_regexp("local", r"^orchestrator\.") == {
        "orchestrator.model.implementer": "opus",
    }

    # If model write fails, effort is not written.
    git2 = FakeGit(
        toplevel=str(root),
        config_write_fails=[("global", "orchestrator.model.fixer")],
    )
    assert orch_agent(
        git2, "set", "fixer", "--effort", "low", "--model", "haiku", "--global"
    ) == 1
    out, err = capsys.readouterr()
    assert out == ""
    assert err.startswith("orch: ")
    assert "orchestrator.model.fixer" in err
    assert "global" in err
    assert git2.config_regexp("global", r"^orchestrator\.") == {}

    # If inherit unset fails on model, exact cannot clear message and effort is skipped.
    git3 = FakeGit(
        toplevel=str(root),
        local_config={"orchestrator.model.lens": "opus"},
        config_write_fails=[("local", "orchestrator.model.lens")],
    )
    assert orch_agent(git3, "set", "lens", "--effort", "high", "--model", "inherit") == 1
    assert capsys.readouterr() == (
        "", "orch: cannot clear orchestrator.model.lens at local scope\n"
    )
    assert git3.config_regexp("local", r"^orchestrator\.") == {
        "orchestrator.model.lens": "opus",
    }

    # If model write succeeds and effort inherit unset fails, model stays written.
    git4 = FakeGit(
        toplevel=str(root),
        local_config={"orchestrator.effort.lens": "high"},
        config_write_fails=[("local", "orchestrator.effort.lens")],
    )
    assert orch_agent(git4, "set", "lens", "--effort", "inherit", "--model", "sonnet") == 1
    assert capsys.readouterr() == (
        "", "orch: cannot clear orchestrator.effort.lens at local scope\n"
    )
    assert git4.config_regexp("local", r"^orchestrator\.") == {
        "orchestrator.model.lens": "sonnet",
        "orchestrator.effort.lens": "high",
    }


def test_clear_unsets_in_flag_order_or_canonical_order_and_aborts_on_error_without_rollback(
    root, tmp_path, capsys
):
    empty_plugin = str(tmp_path / "no-agents")
    git = FakeGit(
        toplevel=str(root),
        local_config={
            "orchestrator.model.implementer": "opus",
            "orchestrator.effort.implementer": "high",
            "orchestrator.model.closer": "fable",
            "orchestrator.effort.closer": "xhigh",
            "orchestrator.junie.model.lens": "gpt-5",
            "orchestrator.junie.effort.lens": "medium",
        },
        global_config={
            "orchestrator.model.closer": "sonnet",
            "orchestrator.junie.model.reviewer": "gpt-5",
        },
    )

    assert orch_agent(git, "clear", "implementer", "--effort") == 0
    assert capsys.readouterr() == ("", "")
    assert git.config_regexp("local", r"^orchestrator\..*\.implementer$") == {
        "orchestrator.model.implementer": "opus",
    }

    # Clear with no kind flags removes both local keys, leaving global alone.
    assert orch_agent(git, "clear", "closer") == 0
    assert git.config_regexp("local", r"^orchestrator\..*\.closer$") == {}
    assert git.config_regexp("global", r"^orchestrator\..*\.closer$") == {
        "orchestrator.model.closer": "sonnet",
    }

    # Clear on already-unset keys exits 0 silently.
    assert orch_agent(git, "clear", "closer") == 0
    assert capsys.readouterr() == ("", "")

    # Clear --global removes global keys.
    assert orch_agent(git, "clear", "closer", "--global") == 0
    assert git.config_regexp("global", r"^orchestrator\..*\.closer$") == {}

    # Clear --host junie removes only Junie keys.
    assert orch_agent(git, "clear", "lens", "--host", "junie", "--model", plugin_root=empty_plugin) == 0
    assert git.config_regexp("local", r"^orchestrator\.junie\..*\.lens$") == {
        "orchestrator.junie.effort.lens": "medium",
    }
    assert orch_agent(git, "clear", "reviewer", "--host", "junie", "--global", plugin_root=empty_plugin) == 0
    assert git.config_regexp("global", r"^orchestrator\.junie\.") == {}
    assert git.config_regexp("local", r"^orchestrator\.model\.implementer$") == {
        "orchestrator.model.implementer": "opus",
    }

    # Refusals leave config untouched.
    assert orch_agent(git, "clear", "implementor") == 1
    assert "want implementer|lens|reviewer|fixer|closer|resolver|auditor" in capsys.readouterr()[1]
    assert orch_agent(git, "clear", "implementer", "--host", "codex") == 1
    assert capsys.readouterr() == ("", "orch: host codex is not allowed (want junie)\n")
    assert git.config_regexp("local", r"^orchestrator\.model\.implementer$") == {
        "orchestrator.model.implementer": "opus",
    }
    assert orch_agent(git, "clear", "lens", "--host") == 1
    assert capsys.readouterr() == ("", "orch: --host needs a value (want junie)\n")
    assert orch_agent(git, "clear", "lens", "--host", "junie", "--host", "junie") == 1
    assert capsys.readouterr() == (
        "", "orch: usage: orch.sh agent clear <role> [--model] [--effort] [--global] [--host junie]\n"
    )

    # Flag order with no rollback: --effort --model unsets effort first, then fails on model.
    git_flag = FakeGit(
        toplevel=str(root),
        local_config={
            "orchestrator.model.fixer": "opus",
            "orchestrator.effort.fixer": "high",
        },
        config_write_fails=[("local", "orchestrator.model.fixer")],
    )
    assert orch_agent(git_flag, "clear", "fixer", "--effort", "--model") == 1
    assert capsys.readouterr() == (
        "", "orch: cannot clear orchestrator.model.fixer at local scope\n"
    )
    assert git_flag.config_regexp("local", r"^orchestrator\.") == {
        "orchestrator.model.fixer": "opus",
    }

    # Default canonical order with no rollback: no kind flags unsets model first, then fails on effort.
    git_default = FakeGit(
        toplevel=str(root),
        global_config={
            "orchestrator.model.fixer": "opus",
            "orchestrator.effort.fixer": "high",
        },
        config_write_fails=[("global", "orchestrator.effort.fixer")],
    )
    assert orch_agent(git_default, "clear", "fixer", "--global") == 1
    assert capsys.readouterr() == (
        "", "orch: cannot clear orchestrator.effort.fixer at global scope\n"
    )
    assert git_default.config_regexp("global", r"^orchestrator\.") == {
        "orchestrator.effort.fixer": "high",
    }

    # When first key fails in default order, second key is NOT unset.
    git_first = FakeGit(
        toplevel=str(root),
        local_config={
            "orchestrator.model.fixer": "opus",
            "orchestrator.effort.fixer": "high",
        },
        config_write_fails=[("local", "orchestrator.model.fixer")],
    )
    assert orch_agent(git_first, "clear", "fixer") == 1
    assert capsys.readouterr() == (
        "", "orch: cannot clear orchestrator.model.fixer at local scope\n"
    )
    assert git_first.config_regexp("local", r"^orchestrator\.") == {
        "orchestrator.model.fixer": "opus",
        "orchestrator.effort.fixer": "high",
    }


def test_config_cache_invalidates_on_write_and_unset(root):
    class CountingGit(FakeGit):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.regexp_calls = []

        def config_regexp(self, scope, pattern):
            self.regexp_calls.append(scope)
            return super().config_regexp(scope, pattern)

    git = CountingGit(toplevel=str(root))
    cache = agent.ConfigCache(git)

    assert cache.lookup("model", "lens") == ("inherit", "inherit")
    assert git.regexp_calls == ["local", "global"]

    # Second lookup uses cache.
    assert cache.lookup("effort", "lens") == ("inherit", "inherit")
    assert git.regexp_calls == ["local", "global"]

    # Write drops cache; next lookup reloads once.
    cache.write("local", "orchestrator.model.lens", "opus")
    assert cache.lookup("model", "lens") == ("opus", "local")
    assert git.regexp_calls == ["local", "global", "local", "global"]

    # Unset drops cache; next lookup reloads once.
    cache.unset("local", "orchestrator.model.lens")
    assert cache.lookup("model", "lens") == ("inherit", "inherit")
    assert git.regexp_calls == ["local", "global", "local", "global", "local", "global"]


# --- name shapes, copy marker, agent_sync_plan, and agent sync ----------------


def fake_plugin(tmp_path):
    """A minimal plugin tree under tmp_path/plugin with sample agents/orch-*.md."""
    plugin = tmp_path / "plugin"
    agents_dir = plugin / "agents"
    agents_dir.mkdir(parents=True)
    for name in (
        "orch-implementer",
        "orch-lens-consistency",
        "orch-lens-fidelity",
        "orch-reviewer-spec",
        "orch-reviewer-standards",
        "orch-fixer",
        "orch-closer",
        "orch-resolver",
        "orch-doc-auditor",
        "orch-code-auditor",
        "orch-test-auditor",
        "orch-autopilot-planner",
    ):
        (agents_dir / (name + ".md")).write_text(
            "---\nname: %s\n---\n\nBody of %s.\n" % (name, name),
            encoding="utf-8",
        )
    return plugin


def git_with_exclude(root, common_dir=None, **kwargs):
    """A FakeGit at <root> with git_common_dir seeded to <common_dir> (or root/.git)."""
    common = root / ".git" if common_dir is None else common_dir
    common.mkdir(parents=True, exist_ok=True)
    git = FakeGit(toplevel=str(root), **kwargs)
    git.seed("git_common_dir", answer=str(common))
    return git, common


def test_name_shapes_cover_exact_roles_and_resolve_agent_names():
    assert {role for role, _ in agent.AGENT_NAME_SHAPES} == set(agent.AGENT_ROLES)
    assert agent.agent_role_of("orch-implementer") == "implementer"
    assert agent.agent_role_of("orch-lens-consistency") == "lens"
    assert agent.agent_role_of("orch-reviewer-spec") == "reviewer"
    assert agent.agent_role_of("orch-fixer") == "fixer"
    assert agent.agent_role_of("orch-closer") == "closer"
    assert agent.agent_role_of("orch-resolver") == "resolver"
    assert agent.agent_role_of("orch-doc-auditor") == "auditor"
    assert agent.agent_role_of("orch-code-auditor") == "auditor"
    assert agent.agent_role_of("orch-test-auditor") == "auditor"
    assert agent.agent_role_of("orch-autopilot-planner") is None
    assert agent.agent_role_of("orch-nothing-covers-this") is None
    assert agent.agent_role_of("orch-lens-") is None
    assert agent.agent_role_of("orch-lens-x\n") is None


def test_agent_copy_marked_recognises_second_line_and_is_quiet_on_unreadable_or_dir(
    tmp_path, capsys
):
    marked = tmp_path / "marked.md"
    marked.write_text("---\n%s\nbody\n" % agent.AGENT_COPY_MARKER, encoding="utf-8")
    noeol = tmp_path / "noeol.md"
    noeol.write_text("---\n%s" % agent.AGENT_COPY_MARKER, encoding="utf-8")
    late = tmp_path / "late.md"
    late.write_text("---\nname: x\n%s\n" % agent.AGENT_COPY_MARKER, encoding="utf-8")
    missing = tmp_path / "none.md"
    directory = tmp_path / "dir.md"
    directory.mkdir()

    assert agent.agent_copy_marked(str(marked)) is True
    assert agent.agent_copy_marked(str(noeol)) is True
    assert agent.agent_copy_marked(str(late)) is False
    assert agent.agent_copy_marked(str(missing)) is False
    assert agent.agent_copy_marked(str(directory)) is False
    assert capsys.readouterr() == ("", "")

    if os.geteuid() != 0:
        unreadable = tmp_path / "unreadable.md"
        unreadable.write_text("---\n%s\n" % agent.AGENT_COPY_MARKER, encoding="utf-8")
        unreadable.chmod(0)
        try:
            assert agent.agent_copy_marked(str(unreadable)) is False
            assert capsys.readouterr() == ("", "")
        finally:
            unreadable.chmod(0o644)


def test_sync_writes_updates_prunes_copies_and_updates_git_exclude(root, tmp_path, capsys):
    plugin = fake_plugin(tmp_path)
    git, common = git_with_exclude(root)
    copies_dir = root / ".junie" / "agents"

    # Sync with nothing set succeeds, writes no copies, creates no dir, touches no exclude.
    assert orch_agent(git, "sync", plugin_root=str(plugin)) == 0
    assert capsys.readouterr() == ("", "")
    assert not copies_dir.exists()
    assert not (common / "info" / "exclude").exists()

    # Sync rejects extra arguments.
    assert orch_agent(git, "sync", "extra", plugin_root=str(plugin)) == 1
    assert capsys.readouterr() == ("", "orch: usage: orch.sh agent sync\n")

    # Set Junie model & effort writes copy with marker, model, reasoningLevel, and exclude.
    assert orch_agent(
        git, "set", "implementer", "--host", "junie", "--model", "gpt-5", "--effort", "high",
        plugin_root=str(plugin),
    ) == 0
    assert sorted(p.name for p in copies_dir.iterdir()) == ["orch-implementer.md"]
    assert (copies_dir / "orch-implementer.md").read_text(encoding="utf-8") == (
        "---\n"
        "# written by orch.sh agent sync\n"
        "model: gpt-5\n"
        "reasoningLevel: high\n"
        "name: orch-implementer\n"
        "---\n\n"
        "Body of orch-implementer.\n"
    )
    exclude_lines = (common / "info" / "exclude").read_text(encoding="utf-8").splitlines()
    assert exclude_lines.count(".junie/agents/orch-*.md") == 1

    # Second sync is idempotent: does not duplicate exclude and does not rewrite unchanged copy.
    os.utime(copies_dir / "orch-implementer.md", (978307200, 978307200))
    assert orch_agent(git, "sync", plugin_root=str(plugin)) == 0
    assert int((copies_dir / "orch-implementer.md").stat().st_mtime) == 978307200
    assert (common / "info" / "exclude").read_text(encoding="utf-8").splitlines().count(
        ".junie/agents/orch-*.md"
    ) == 1

    # Lens writes all lens copies; model-only omits reasoningLevel; Claude keys never produce copies.
    assert orch_agent(
        git, "set", "lens", "--host", "junie", "--model", "claude-opus-5-5",
        plugin_root=str(plugin),
    ) == 0
    assert orch_agent(git, "set", "reviewer", "--model", "opus", "--effort", "high",
                      plugin_root=str(plugin)) == 0
    assert sorted(p.name for p in copies_dir.iterdir()) == [
        "orch-implementer.md",
        "orch-lens-consistency.md",
        "orch-lens-fidelity.md",
    ]
    assert "reasoningLevel:" not in (copies_dir / "orch-lens-fidelity.md").read_text(encoding="utf-8")

    # Tampered content and extra trailing newlines are detected as stale and rewritten.
    with open(copies_dir / "orch-implementer.md", "a", encoding="utf-8") as f:
        f.write("tampered\n")
    assert orch_agent(git, "sync", plugin_root=str(plugin)) == 0
    assert "tampered" not in (copies_dir / "orch-implementer.md").read_text(encoding="utf-8")

    with open(copies_dir / "orch-implementer.md", "a", encoding="utf-8") as f:
        f.write("\n\n")
    plan = agent.agent_sync_plan(git, str(root), plugin_root=str(plugin))
    assert [(w.name, w.model, w.effort, w.state) for w in plan.writes] == [
        ("orch-implementer", "gpt-5", "high", "stale")
    ]
    assert orch_agent(git, "sync", plugin_root=str(plugin)) == 0

    # Custom profile IDs with colons write whole and stay current on re-sync.
    assert orch_agent(
        git, "set", "implementer", "--host", "junie", "--model", "custom:my/profile.1",
        "--effort", "low", plugin_root=str(plugin),
    ) == 0
    impl_text = (copies_dir / "orch-implementer.md").read_text(encoding="utf-8")
    assert "model: custom:my/profile.1\nreasoningLevel: low\n" in impl_text
    os.utime(copies_dir / "orch-implementer.md", (978307200, 978307200))
    assert orch_agent(git, "sync", plugin_root=str(plugin)) == 0
    assert int((copies_dir / "orch-implementer.md").stat().st_mtime) == 978307200

    # Invalid stored Junie model with valid effort writes effort-only copy (no model:).
    git.config_set("local", "orchestrator.junie.model.closer", "bad model")
    git.config_set("local", "orchestrator.junie.effort.closer", "low")
    assert orch_agent(git, "sync", plugin_root=str(plugin)) == 0
    closer_text = (copies_dir / "orch-closer.md").read_text(encoding="utf-8")
    assert "model:" not in closer_text
    assert "reasoningLevel: low\n" in closer_text
    assert orch_agent(git, "clear", "closer", "--host", "junie", plugin_root=str(plugin)) == 0
    assert not (copies_dir / "orch-closer.md").exists()

    # Auditor setting writes all three auditor copies and clear prunes them all.
    assert orch_agent(
        git, "set", "auditor", "--host", "junie", "--model", "gpt-5", "--effort", "low",
        plugin_root=str(plugin),
    ) == 0
    for aud in ("orch-doc-auditor.md", "orch-code-auditor.md", "orch-test-auditor.md"):
        assert "reasoningLevel: low" in (copies_dir / aud).read_text(encoding="utf-8")
    assert orch_agent(git, "clear", "auditor", "--host", "junie", plugin_root=str(plugin)) == 0
    for aud in ("orch-doc-auditor.md", "orch-code-auditor.md", "orch-test-auditor.md"):
        assert not (copies_dir / aud).exists()

    # Pruning removes cleared roles and removed plugin agents, leaving non-orch and
    # wrongly-marked files alone.
    assert orch_agent(git, "clear", "lens", "--host", "junie", plugin_root=str(plugin)) == 0
    (copies_dir / "orch-gone.md").write_text(
        "---\n%s\nname: orch-gone\n---\n" % agent.AGENT_COPY_MARKER, encoding="utf-8"
    )
    assert orch_agent(git, "sync", plugin_root=str(plugin)) == 0
    assert sorted(p.name for p in copies_dir.iterdir()) == ["orch-implementer.md"]

    (copies_dir / "notes.md").write_text("mine\n", encoding="utf-8")
    (copies_dir / "orch-gone.md").write_text(
        "---\nname: orch-gone\n%s\n---\n" % agent.AGENT_COPY_MARKER, encoding="utf-8"
    )
    assert orch_agent(git, "clear", "implementer", "--host", "junie", plugin_root=str(plugin)) == 0
    assert sorted(p.name for p in copies_dir.iterdir()) == ["notes.md", "orch-gone.md"]


def test_sync_writes_exclude_to_common_git_dir_in_linked_worktree(tmp_path, capsys):
    plugin = fake_plugin(tmp_path)
    main_git = tmp_path / "main" / ".git"
    wt_root = tmp_path / "linked-wt"
    wt_root.mkdir()
    git, common = git_with_exclude(
        wt_root,
        common_dir=main_git,
        local_config={"orchestrator.junie.model.closer": "gpt-5"},
    )

    assert orch_agent(git, "sync", plugin_root=str(plugin)) == 0
    assert capsys.readouterr() == ("", "")
    assert (common / "info" / "exclude").read_text(encoding="utf-8").splitlines() == [
        ".junie/agents/orch-*.md"
    ]
    assert not (wt_root / ".git").exists()
    assert (wt_root / ".junie" / "agents" / "orch-closer.md").is_file()


def test_sync_refuses_all_unmarked_conflicts_before_mutating_disk_or_exclude(
    root, tmp_path, capsys
):
    plugin = fake_plugin(tmp_path)
    git, common = git_with_exclude(
        root,
        local_config={
            "orchestrator.junie.model.implementer": "gpt-5",
            "orchestrator.junie.model.reviewer": "gpt-5",
            "orchestrator.junie.model.closer": "gpt-5",
        },
    )
    copies_dir = root / ".junie" / "agents"
    copies_dir.mkdir(parents=True)
    # One stale marked copy that would be deleted, two unmarked files in the way,
    # and a directory at a target path (treated quietly as unmarked).
    (copies_dir / "orch-fixer.md").write_text(
        "---\n%s\n---\n" % agent.AGENT_COPY_MARKER, encoding="utf-8"
    )
    (copies_dir / "orch-reviewer-spec.md").write_text("hand made\n", encoding="utf-8")
    (copies_dir / "orch-reviewer-standards.md").write_text("hand made too\n", encoding="utf-8")
    (copies_dir / "orch-closer.md").mkdir()

    assert orch_agent(git, "sync", plugin_root=str(plugin)) == 1
    out, err = capsys.readouterr()
    assert out == ""
    assert err == (
        "orch: agent sync: orch-closer.md orch-reviewer-spec.md orch-reviewer-standards.md"
        " in %s carries no sync marker - not written by orch.sh agent sync, so left alone;"
        " rename or remove it, then rerun orch.sh agent sync\n" % copies_dir
    )
    # Nothing mutated: no exclude written, no implementer written, stale fixer kept,
    # unmarked files untouched.
    assert not (common / "info" / "exclude").exists()
    assert not (copies_dir / "orch-implementer.md").exists()
    assert (copies_dir / "orch-fixer.md").is_file()
    assert (copies_dir / "orch-reviewer-spec.md").read_text(encoding="utf-8") == "hand made\n"
    assert (copies_dir / "orch-closer.md").is_dir()

    # On set/clear --host junie with a conflict, config mutation still lands, then sync fails.
    assert orch_agent(
        git, "set", "resolver", "--host", "junie", "--model", "gpt-5", plugin_root=str(plugin)
    ) == 1
    _, err = capsys.readouterr()
    assert "orch-reviewer-spec.md" in err
    assert git.config_regexp("local", r"^orchestrator\.junie\.model\.resolver$") == {
        "orchestrator.junie.model.resolver": "gpt-5",
    }

    assert orch_agent(
        git, "clear", "resolver", "--host", "junie", plugin_root=str(plugin)
    ) == 1
    _, err = capsys.readouterr()
    assert "orch-reviewer-spec.md" in err
    assert git.config_regexp("local", r"^orchestrator\.junie\.model\.resolver$") == {}

    # An unreadable file at a planned target path is also treated quietly as unmarked.
    if os.geteuid() != 0:
        unreadable_root = tmp_path / "unreadable-repo"
        unreadable_root.mkdir()
        ugit, ucommon = git_with_exclude(
            unreadable_root, local_config={"orchestrator.junie.model.closer": "gpt-5"}
        )
        udir = unreadable_root / ".junie" / "agents"
        udir.mkdir(parents=True)
        ufile = udir / "orch-closer.md"
        ufile.write_text("---\n%s\n---\n" % agent.AGENT_COPY_MARKER, encoding="utf-8")
        ufile.chmod(0)
        try:
            assert orch_agent(ugit, "sync", plugin_root=str(plugin)) == 1
            out, err = capsys.readouterr()
            assert out == ""
            assert err == (
                "orch: agent sync: orch-closer.md in %s carries no sync marker"
                " - not written by orch.sh agent sync, so left alone; rename or remove it,"
                " then rerun orch.sh agent sync\n" % udir
            )
            assert not (ucommon / "info" / "exclude").exists()
        finally:
            ufile.chmod(0o644)


def test_set_and_clear_skip_trailing_sync_on_config_error(root, tmp_path, capsys):
    plugin = fake_plugin(tmp_path)
    # Even with a valid Junie key already present (which would normally trigger a copy write),
    # a failed config_set or config_unset aborts before trailing sync.
    git_set = FakeGit(
        toplevel=str(root),
        config_write_fails=[("local", "orchestrator.junie.effort.implementer")],
    )
    git_set.seed("git_common_dir", answer=str(root / ".git"))
    assert orch_agent(
        git_set, "set", "implementer", "--host", "junie", "--model", "gpt-5", "--effort", "high",
        plugin_root=str(plugin),
    ) == 1
    _, err = capsys.readouterr()
    assert "orchestrator.junie.effort.implementer" in err
    assert git_set.config_regexp("local", r"^orchestrator\.junie\.") == {
        "orchestrator.junie.model.implementer": "gpt-5",
    }
    assert not (root / ".junie" / "agents").exists()

    # Same for clear --host junie when config_unset fails on the second key.
    git_clear, _ = git_with_exclude(
        root,
        local_config={
            "orchestrator.junie.model.implementer": "gpt-5",
            "orchestrator.junie.effort.implementer": "high",
        },
        config_write_fails=[("local", "orchestrator.junie.effort.implementer")],
    )
    copies_dir = root / ".junie" / "agents"
    copies_dir.mkdir(parents=True)
    stale = copies_dir / "orch-gone.md"
    stale.write_text("---\n%s\n---\n" % agent.AGENT_COPY_MARKER, encoding="utf-8")

    assert orch_agent(
        git_clear, "clear", "implementer", "--host", "junie", plugin_root=str(plugin)
    ) == 1
    assert capsys.readouterr() == (
        "", "orch: cannot clear orchestrator.junie.effort.implementer at local scope\n"
    )
    # model was cleared before effort failed, and trailing sync did NOT run to delete stale.
    assert git_clear.config_regexp("local", r"^orchestrator\.junie\.") == {
        "orchestrator.junie.effort.implementer": "high",
    }
    assert stale.is_file()


def test_sync_fails_fast_with_exact_messages_on_exclude_delete_create_and_write_errors(
    tmp_path, capsys
):
    plugin = fake_plugin(tmp_path)

    # 1. Exclude write failure: info/exclude is a directory -> exclude_line's own single orch: line.
    r1 = tmp_path / "r1"
    r1.mkdir()
    git1, c1 = git_with_exclude(r1, local_config={"orchestrator.junie.model.closer": "gpt-5"})
    (c1 / "info" / "exclude").mkdir(parents=True)
    assert orch_agent(git1, "sync", plugin_root=str(plugin)) == 1
    out, err = capsys.readouterr()
    assert out == ""
    assert err == (
        "orch: cannot add .junie/agents/orch-*.md to the git exclude file %s/info/exclude\n" % c1
    )
    assert not (r1 / ".junie" / "agents").exists()

    # 2. Directory creation failure: .junie/agents is a regular file.
    r3 = tmp_path / "r3"
    r3.mkdir()
    git3, _ = git_with_exclude(r3, local_config={"orchestrator.junie.model.closer": "gpt-5"})
    (r3 / ".junie").mkdir()
    (r3 / ".junie" / "agents").write_text("blocker\n", encoding="utf-8")
    assert orch_agent(git3, "sync", plugin_root=str(plugin)) == 1
    assert capsys.readouterr() == (
        "", "orch: agent sync: cannot create %s\n" % (r3 / ".junie" / "agents")
    )

    if os.geteuid() != 0:
        # 3. Stale delete failure: read-only .junie/agents dir blocks unlink before any write.
        r2 = tmp_path / "r2"
        r2.mkdir()
        git2, _ = git_with_exclude(r2, local_config={"orchestrator.junie.model.closer": "gpt-5"})
        d2 = r2 / ".junie" / "agents"
        d2.mkdir(parents=True)
        stale = d2 / "orch-gone.md"
        stale.write_text("---\n%s\n---\n" % agent.AGENT_COPY_MARKER, encoding="utf-8")
        d2.chmod(0o555)
        try:
            assert orch_agent(git2, "sync", plugin_root=str(plugin)) == 1
            assert capsys.readouterr() == ("", "orch: agent sync: cannot delete %s\n" % stale)
            assert not (d2 / "orch-closer.md").exists()
        finally:
            d2.chmod(0o755)

        # 4. Copy write failure: read-only .junie/agents dir blocks creating the first copy
        # and aborts before the second.
        r4 = tmp_path / "r4"
        r4.mkdir()
        git4, _ = git_with_exclude(
            r4, local_config={"orchestrator.junie.model.lens": "gpt-5"}
        )
        d4 = r4 / ".junie" / "agents"
        d4.mkdir(parents=True)
        target = d4 / "orch-lens-consistency.md"
        d4.chmod(0o555)
        try:
            assert orch_agent(git4, "sync", plugin_root=str(plugin)) == 1
            assert capsys.readouterr() == ("", "orch: agent sync: cannot write %s\n" % target)
            assert not (d4 / "orch-lens-fidelity.md").exists()
        finally:
            d4.chmod(0o755)


def test_default_plugin_root_resolves_symlinked_install(tmp_path):
    real_root = Path(agent.default_plugin_root())
    assert (real_root / "agents" / "orch-implementer.md").is_file()

    # Symlink the plugin root elsewhere and import orch.agent through the symlink:
    # default_plugin_root() resolves through the symlink back to the real plugin root.
    link = tmp_path / "linked-plugin"
    link.symlink_to(real_root)
    env = dict(
        os.environ,
        PYTHONPATH=str(link / "scripts" / "orch_py"),
        PYTHONDONTWRITEBYTECODE="1",
    )
    proc = subprocess.run(
        [sys.executable, "-S", "-c", "from orch.agent import default_plugin_root; print(default_plugin_root())"],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        timeout=30,
    )
    assert (proc.returncode, proc.stderr) == (0, "")
    assert Path(proc.stdout.strip()) == real_root
