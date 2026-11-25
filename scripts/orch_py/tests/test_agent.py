"""The agent noun run in-process on FakeGit and tmp_path: immutable HostSpec
table, canonical roles and name shapes, scoped config caching, all six CLI
verbs (set, show, clear, get, sync, roles), partial-mutation order on errors,
shared agent_sync_plan, and .junie/agents/ copy-sync."""
from __future__ import annotations

import io
import os
import sys

import pytest

from conftest import died_of
from orch import agent, cli
from orch.git import FakeGit


class CountingGit(FakeGit):
    """FakeGit that records the scope of every config_regexp call."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.regexp_calls = []

    def config_regexp(self, scope, pattern):
        self.regexp_calls.append(scope)
        return super().config_regexp(scope, pattern)


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


def test_show_prints_non_utf8_config_bytes_verbatim(root, monkeypatch):
    git = FakeGit(
        toplevel=str(root),
        local_config={"orchestrator.model.fixer": "bad\udcffval"},
    )
    out = io.TextIOWrapper(io.BytesIO(), encoding="utf-8")
    monkeypatch.setattr(sys, "stdout", out)

    assert orch_agent(git, "show") == 0
    out.flush()
    assert b"fixer model bad\xffval (local, invalid) effort inherit (inherit)\n" in out.buffer.getvalue()


def test_get_refusal_prints_non_utf8_config_bytes_verbatim(root, monkeypatch):
    git = FakeGit(
        toplevel=str(root),
        local_config={"orchestrator.model.fixer": "bad\udcffval"},
    )
    err = io.TextIOWrapper(io.BytesIO(), encoding="utf-8", errors="backslashreplace")
    monkeypatch.setattr(sys, "stderr", err)

    assert orch_agent(git, "get", "fixer") == 1
    err.flush()
    assert err.buffer.getvalue().startswith(
        b"orch: orchestrator.model.fixer is bad\xffval - not an allowed model"
    )


def test_config_cache_loads_each_scope_once_per_run(root, capsys):
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
    plan = agent.agent_sync_plan(str(root), agent.ConfigCache(git), "junie", str(plugin))
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


# --- bridges: docs linter, autopilot, and doctor ------------------------------


def test_name_shapes_emits_ordered_role_glob_ere_lines_and_covers_all_roles(capsys):
    assert agent.name_shapes() == 0
    out, err = capsys.readouterr()
    assert err == ""
    assert out == (
        "implementer\torch-implementer\torch-implementer\n"
        "lens\torch-lens-*\torch-lens-[a-z]+\n"
        "reviewer\torch-reviewer-*\torch-reviewer-[a-z]+\n"
        "fixer\torch-fixer\torch-fixer\n"
        "closer\torch-closer\torch-closer\n"
        "resolver\torch-resolver\torch-resolver\n"
        "auditor\torch-*-auditor\torch-[a-z]+-auditor\n"
    )
    rows = [line.split("\t") for line in out.splitlines()]
    assert [role for role, _, _ in rows] == list(agent.AGENT_ROLES)
    assert [(role, glob) for role, glob, _ in rows] == list(agent.AGENT_NAME_SHAPES)

    # Dispatches via orch_python_call (cli.call_func) and refuses extra args.
    assert cli.call_func(["agent", "name_shapes"]) == 0
    assert capsys.readouterr() == (out, "")
    assert died_of(capsys, lambda: cli.call_func(["agent", "name_shapes", "extra"])) == (
        1, "", "orch: usage: orch_python_call agent name_shapes\n"
    )


def test_validate_autopilot_checks_claude_model_and_effort_and_preserves_error_message(capsys):
    for model in ("sonnet", "opus", "haiku", "fable", "inherit"):
        assert cli.call_func(
            ["agent", "validate_autopilot", "model", model, "orchestrator.autopilot.model"]
        ) == 0
        assert capsys.readouterr() == ("", "")

    for effort in ("low", "medium", "high", "xhigh", "max", "inherit"):
        assert cli.call_func(
            ["agent", "validate_autopilot", "effort", effort, "orchestrator.autopilot.effort"]
        ) == 0
        assert capsys.readouterr() == ("", "")

    for bad_model in ("gpt", "Opus", "opus haiku", "", "opus\nsonnet"):
        assert died_of(
            capsys,
            lambda v=bad_model: cli.call_func(
                ["agent", "validate_autopilot", "model", v, "orchestrator.autopilot.model"]
            ),
        ) == (
            1, "",
            "orch: orchestrator.autopilot.model is %s - not an allowed model"
            " (want sonnet|opus|haiku|fable|inherit)\n" % bad_model,
        )

    for bad_effort in ("extreme", "High", ""):
        assert died_of(
            capsys,
            lambda v=bad_effort: cli.call_func(
                ["agent", "validate_autopilot", "effort", v, "orchestrator.autopilot.effort"]
            ),
        ) == (
            1, "",
            "orch: orchestrator.autopilot.effort is %s - not an allowed effort"
            " (want low|medium|high|xhigh|max|inherit)\n" % bad_effort,
        )

    # The error message names the key it is handed.
    assert died_of(
        capsys,
        lambda: cli.call_func(["agent", "validate_autopilot", "model", "gpt", "custom.key"]),
    ) == (
        1, "",
        "orch: custom.key is gpt - not an allowed model"
        " (want sonnet|opus|haiku|fable|inherit)\n",
    )

    # Usage refusals for wrong arity or unknown setting kind.
    for bad_args in ([], ["model"], ["model", "opus"], ["bogus", "opus", "k"],
                     ["model", "opus", "k", "extra"]):
        assert died_of(
            capsys, lambda a=bad_args: agent.validate_autopilot(a)
        ) == (
            1, "",
            "orch: usage: orch_python_call agent validate_autopilot <model|effort> <value> <key>\n",
        )


def doctor_records(capsys, git, home, plugin_root):
    """Runs agent.check_settings in-process and parses NUL-delimited
    `<kind>\\t<message>\\0` records, asserting clean exit 0 and empty stderr."""
    code = agent.check_settings(
        [],
        git=git,
        env={"HOME": str(home)},
        plugin_root=str(plugin_root),
    )
    out, err = capsys.readouterr()
    assert (code, err) == (0, "")
    assert out.endswith("\0")
    records = []
    for raw in out[:-1].split("\0"):
        kind, sep, msg = raw.partition("\t")
        assert sep == "\t"
        assert kind in ("ok", "warn", "fail", "remedy")
        records.append((kind, msg))
    return records


def test_check_settings_emits_nul_records_for_host_settings_per_scope_validation_and_multiline_values(
    root, tmp_path, capsys, monkeypatch
):
    home = tmp_path / "home"
    home.mkdir()
    empty_plugin = tmp_path / "no-agents"
    git = FakeGit(
        toplevel=str(root),
        local_config=[
            ("orchestrator.effort.implementer", "high"),
            ("orchestrator.model.fixer", "gpt"),
            ("orchestrator.effort.closer", "low"),
            ("orchestrator.model.resolver", "opus\nsonnet"),
            ("orchestrator.effort.auditor", None),
            ("orchestrator.junie.effort.implementer", "high"),
            ("orchestrator.junie.model.fixer", "my model"),
            ("orchestrator.junie.effort.closer", "low"),
        ],
        global_config={
            "orchestrator.model.reviewer": "haiku",
            "orchestrator.effort.closer": "huge",
            "orchestrator.junie.model.reviewer": "gpt-5",
            "orchestrator.junie.effort.closer": "huge",
        },
    )

    records = doctor_records(capsys, git, home, empty_plugin)

    assert ("ok", "agent implementer: model inherit (inherit), effort high (local)") in records
    assert ("ok", "agent reviewer: model haiku (global), effort inherit (inherit)") in records
    assert ("ok", "agent fixer: model gpt (local, invalid), effort inherit (inherit)") in records
    assert (
        "fail",
        "orchestrator.model.fixer is gpt (local) - not an allowed model"
        " (want sonnet|opus|haiku|fable|inherit)",
    ) in records
    assert ("remedy", "orch.sh agent clear fixer --model") in records

    # Hidden global invalid value still fails even when local overrides it cleanly.
    assert ("ok", "agent closer: model inherit (inherit), effort low (local)") in records
    assert (
        "fail",
        "orchestrator.effort.closer is huge (global) - not an allowed effort"
        " (want low|medium|high|xhigh|max|inherit)",
    ) in records
    assert ("remedy", "orch.sh agent clear closer --effort --global") in records

    # Multi-line git config value preserves internal newlines losslessly in NUL records.
    assert (
        "ok",
        "agent resolver: model opus\nsonnet (local, invalid), effort inherit (inherit)",
    ) in records
    assert (
        "fail",
        "orchestrator.model.resolver is opus\nsonnet (local) - not an allowed model"
        " (want sonnet|opus|haiku|fable|inherit)",
    ) in records
    assert ("remedy", "orch.sh agent clear resolver --model") in records

    # Valueless config key reports empty value cleanly.
    assert ("ok", "agent auditor: model inherit (inherit), effort  (local, invalid)") in records
    assert (
        "fail",
        "orchestrator.effort.auditor is  (local) - not an allowed effort"
        " (want low|medium|high|xhigh|max|inherit)",
    ) in records

    # Junie settings listing and per-scope validation with exact remedies.
    assert ("ok", "agent junie implementer: model inherit (inherit), effort high (local)") in records
    assert ("ok", "agent junie reviewer: model gpt-5 (global), effort inherit (inherit)") in records
    assert ("ok", "agent junie auditor: model inherit (inherit), effort inherit (inherit)") in records
    assert (
        "fail",
        "orchestrator.junie.model.fixer is my model (local) - not an allowed model"
        " (want inherit or a name matching [A-Za-z0-9._:/-]+"
        " - use the names Junie's /model picker and --model flag take;"
        " aliases resolve unpredictably)",
    ) in records
    assert ("remedy", "orch.sh agent clear fixer --host junie --model") in records
    assert (
        "fail",
        "orchestrator.junie.effort.closer is huge (global) - not an allowed effort"
        " (want low|medium|high|inherit)",
    ) in records
    assert ("remedy", "orch.sh agent clear closer --host junie --effort --global") in records

    # Dispatches via cli.call_func, refuses extra args, and refuses outside checkout.
    monkeypatch.setattr(agent, "Git", lambda: FakeGit(toplevel=str(root)))
    monkeypatch.setenv("HOME", str(home))
    assert cli.call_func(["agent", "check_settings"]) == 0
    out, err = capsys.readouterr()
    assert err == "" and out.endswith("\0")

    assert died_of(capsys, lambda: cli.call_func(["agent", "check_settings", "extra"])) == (
        1, "", "orch: usage: orch_python_call agent check_settings\n"
    )
    code, out, err = died_of(
        capsys, lambda: agent.check_settings([], git=FakeGit(toplevel=None), env={})
    )
    assert (code, out) == (1, "") and err.startswith("orch: not inside a git repository")


def write_junie_index(home, entries):
    """Writes <entries> (dicts or raw strings) to <home>/.junie/sessions/index.jsonl."""
    import json

    sessions = home / ".junie" / "sessions"
    sessions.mkdir(parents=True, exist_ok=True)
    lines = [
        entry if isinstance(entry, str) else json.dumps(entry)
        for entry in entries
    ]
    (sessions / "index.jsonl").write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def write_junie_log(home, filename, text, mtime=None):
    """Writes <text> to <home>/.junie/logs/<filename> with optional mtime."""
    logs = home / ".junie" / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    path = logs / filename
    path.write_text(text, encoding="utf-8")
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


def test_check_settings_junie_session_reports_dated_matches_mismatches_and_cannot_tell_without_jq(
    root, tmp_path, capsys, monkeypatch
):
    # Empty PATH proves stdlib json / pure Python parsing with zero jq or external tools.
    monkeypatch.setenv("PATH", "")
    empty_plugin = tmp_path / "no-agents"
    home = tmp_path / "home"
    home.mkdir()

    write_junie_index(home, [
        {"sessionId": "new", "projectDir": str(root), "createdAt": "1", "updatedAt": "20"},
        {"sessionId": "old", "projectDir": str(root), "createdAt": "1", "updatedAt": "10"},
    ])
    write_junie_log(
        home, "log-a.log",
        "session old\n"
        "x INFO Executing agent custom_agent_orch-reviewer-spec_1 with parameters"
        " AgentParams(model=gpt-4, effort=null, reasoningEffort=low)\n",
        mtime=100,
    )
    write_junie_log(
        home, "log-b-old.log",
        "session new\n"
        "x INFO Executing agent custom_agent_orch-reviewer-spec_1 with parameters"
        " AgentParams(model=old-log-model, effort=null, reasoningEffort=low)\n",
        mtime=100,
    )
    write_junie_log(
        home, "log-b.log",
        "session new\n"
        "x INFO Executing agent custom_agent_orch-reviewer-spec_1 with parameters"
        " AgentParams(model=gpt-5-2025-08-07, xmodel=ignored, effort=null, reasoningEffort=high)\n"
        "x INFO Executing agent custom_agent_orch-fixer_1 with parameters"
        " AgentParams(model=claude-opus-5-5, effort=medium, reasoningEffort=null)\n"
        "x INFO Executing agent custom_agent_orch-fixer_2 with parameters"
        " AgentParams(model=claude-opus-5-5, effort=low, reasoningEffort=null)\n"
        "x INFO Executing agent custom_agent_orch-autopilot-planner_1 with parameters"
        " AgentParams(model=gpt-5, effort=null, reasoningEffort=null)\n",
        mtime=200,
    )
    git = FakeGit(
        toplevel=str(root),
        local_config={
            "orchestrator.junie.model.reviewer": "gpt-5",
            "orchestrator.junie.effort.reviewer": "high",
        },
    )

    records = doctor_records(capsys, git, home, empty_plugin)
    claude_auditor_idx = records.index(
        ("ok", "agent auditor: model inherit (inherit), effort inherit (inherit)")
    )
    junie_impl_idx = records.index(
        ("ok", "agent junie implementer: model inherit (inherit), effort inherit (inherit)")
    )
    session_records = records[claude_auditor_idx + 1:junie_impl_idx]
    assert session_records == [
        ("ok", "junie orch-reviewer-spec ran model gpt-5-2025-08-07, effort high (set model gpt-5, effort high)"),
        ("ok", "junie orch-fixer ran model claude-opus-5-5, effort low (set model inherit, effort inherit)"),
        ("ok", "junie orch-autopilot-planner ran model gpt-5, effort inherited (set model inherit, effort inherit)"),
    ]

    # Model or effort mismatch (including prefix without '-' like gpt-50 vs gpt-5) warns.
    git_mismatch = FakeGit(
        toplevel=str(root),
        local_config={
            "orchestrator.junie.model.reviewer": "gpt-4",
            "orchestrator.junie.effort.reviewer": "low",
        },
    )
    records = doctor_records(capsys, git_mismatch, home, empty_plugin)
    assert (
        "warn",
        "junie orch-reviewer-spec ran model gpt-5-2025-08-07, effort high (set model gpt-4, effort low)",
    ) in records

    git_prefix_mismatch = FakeGit(
        toplevel=str(root),
        local_config={
            "orchestrator.junie.model.reviewer": "gpt",
            "orchestrator.junie.effort.reviewer": "high",
        },
    )
    # "gpt" matches "gpt-5-2025-08-07" (followed by '-'), whereas "gpt-5-2" does NOT.
    assert (
        "ok",
        "junie orch-reviewer-spec ran model gpt-5-2025-08-07, effort high (set model gpt, effort high)",
    ) in doctor_records(capsys, git_prefix_mismatch, home, empty_plugin)

    git_non_dash_prefix = FakeGit(
        toplevel=str(root),
        local_config={
            "orchestrator.junie.model.reviewer": "gpt-5-202",
            "orchestrator.junie.effort.reviewer": "high",
        },
    )
    assert (
        "warn",
        "junie orch-reviewer-spec ran model gpt-5-2025-08-07, effort high (set model gpt-5-202, effort high)",
    ) in doctor_records(capsys, git_non_dash_prefix, home, empty_plugin)

    # All cannot-tell reasons stay ok (never fail), with no jq-not-installed branch.
    clean_git = FakeGit(toplevel=str(root))

    h_missing = tmp_path / "h_missing"
    h_missing.mkdir()
    assert ("ok", "junie session: cannot tell (no Junie session index)") in doctor_records(
        capsys, clean_git, h_missing, empty_plugin
    )

    h_empty = tmp_path / "h_empty"
    write_junie_index(h_empty, [])
    assert ("ok", "junie session: cannot tell (no session for this checkout)") in doctor_records(
        capsys, clean_git, h_empty, empty_plugin
    )

    h_other = tmp_path / "h_other"
    write_junie_index(h_other, [{"sessionId": "s1", "projectDir": "/elsewhere", "updatedAt": "5"}])
    assert ("ok", "junie session: cannot tell (no session for this checkout)") in doctor_records(
        capsys, clean_git, h_other, empty_plugin
    )

    h_malformed = tmp_path / "h_malformed"
    write_junie_index(h_malformed, ["not json"])
    assert ("ok", "junie session: cannot tell (the session index does not parse)") in doctor_records(
        capsys, clean_git, h_malformed, empty_plugin
    )

    h_nonobj = tmp_path / "h_nonobj"
    write_junie_index(h_nonobj, ["123"])
    assert ("ok", "junie session: cannot tell (the session index does not parse)") in doctor_records(
        capsys, clean_git, h_nonobj, empty_plugin
    )

    h_nolog = tmp_path / "h_nolog"
    write_junie_index(h_nolog, [{"sessionId": "lost", "projectDir": str(root), "updatedAt": "5"}])
    assert ("ok", "junie session: cannot tell (no log names session lost)") in doctor_records(
        capsys, clean_git, h_nolog, empty_plugin
    )

    h_noruns = tmp_path / "h_noruns"
    write_junie_index(h_noruns, [{"sessionId": "g", "projectDir": str(root), "updatedAt": "5"}])
    write_junie_log(h_noruns, "log-g.log", "g\ngarbage\n")
    assert ("ok", "junie session: cannot tell (the log holds no agent runs)") in doctor_records(
        capsys, clean_git, h_noruns, empty_plugin
    )

    # Unparseable run line (missing model=) aborts session report atomically (drops earlier valid agent).
    h_badrun = tmp_path / "h_badrun"
    write_junie_index(h_badrun, [{"sessionId": "b", "projectDir": str(root), "updatedAt": "5"}])
    write_junie_log(
        h_badrun, "log-b.log",
        "b\n"
        "INFO Executing agent custom_agent_orch-fixer_1 with parameters AgentParams(model=gpt-5, effort=low)\n"
        "INFO Executing agent custom_agent_orch-closer_1 with parameters AgentParams(effort=low)\n",
    )
    badrun_records = doctor_records(capsys, clean_git, h_badrun, empty_plugin)
    assert ("ok", "junie session: cannot tell (the log does not parse)") in badrun_records
    assert not any("junie orch-fixer ran model" in msg for _, msg in badrun_records)


def test_check_settings_junie_unrecognized_model_fails_with_allowed_names_and_remedy(
    root, tmp_path, capsys
):
    empty_plugin = tmp_path / "no-agents"
    home = tmp_path / "home"
    home.mkdir()

    # Older log has an unrecognized model; newer log does not -> no failure.
    write_junie_log(
        home, "log-old.log",
        "WARN Unrecognized 'model' value 'old-model', falling back to default."
        " Allowed LLM names: a, b\n",
        mtime=100,
    )
    write_junie_log(home, "log-new.log", "nothing\n", mtime=200)
    git_old = FakeGit(
        toplevel=str(root), local_config={"orchestrator.junie.model.fixer": "old-model"}
    )
    records = doctor_records(capsys, git_old, home, empty_plugin)
    assert not any("did not recognise" in msg for _, msg in records)

    # Newest log has unrecognized values (including duplicate using last line's Allowed LLM names,
    # and one without Allowed LLM names); runs even with no session index.
    write_junie_log(
        home, "log-new.log",
        "WARN Unrecognized 'model' value 'bad-model', falling back to default."
        " Allowed LLM names: stale-list\n"
        "WARN Unrecognized 'model' value 'bad-model', falling back to default."
        " Allowed display names: X. Allowed LLM names: gpt-5, claude-opus-5-5\n"
        "WARN Unrecognized 'model' value 'plain-bad', falling back to default.\n",
        mtime=200,
    )

    # Unset value gives no failure.
    records = doctor_records(capsys, FakeGit(toplevel=str(root)), home, empty_plugin)
    assert not any("did not recognise" in msg for _, msg in records)

    # Local match fails with Allowed LLM names from last line + agent set remedy;
    # global match fails with (global); hidden global match gives no failure;
    # line without Allowed LLM names omits that remedy.
    git = FakeGit(
        toplevel=str(root),
        local_config={
            "orchestrator.junie.model.fixer": "bad-model",
            "orchestrator.junie.model.closer": "good",
            "orchestrator.junie.model.auditor": "plain-bad",
        },
        global_config={
            "orchestrator.junie.model.lens": "bad-model",
            "orchestrator.junie.model.closer": "bad-model",
        },
    )
    records = doctor_records(capsys, git, home, empty_plugin)
    session_idx = records.index(("ok", "junie session: cannot tell (no Junie session index)"))
    junie_impl_idx = records.index(
        ("ok", "agent junie implementer: model inherit (inherit), effort inherit (inherit)")
    )
    unrec_records = records[session_idx + 1:junie_impl_idx]
    assert unrec_records == [
        ("fail", "Junie did not recognise model bad-model, set for lens (global) - it fell back to the session model"),
        ("remedy", "Allowed LLM names: gpt-5, claude-opus-5-5"),
        ("remedy", "orch.sh agent set lens --host junie --model <id>"),
        ("fail", "Junie did not recognise model bad-model, set for fixer (local) - it fell back to the session model"),
        ("remedy", "Allowed LLM names: gpt-5, claude-opus-5-5"),
        ("remedy", "orch.sh agent set fixer --host junie --model <id>"),
        ("fail", "Junie did not recognise model plain-bad, set for auditor (local) - it fell back to the session model"),
        ("remedy", "orch.sh agent set auditor --host junie --model <id>"),
    ]


def test_check_settings_with_empty_home_reads_root_junie_not_the_cwd(
    root, tmp_path, capsys, monkeypatch
):
    # bash read "$HOME"/.junie/..., so an empty HOME means /.junie/..., never
    # a .junie/ under the working directory.
    cwd = tmp_path / "cwd"
    cwd.mkdir()
    write_junie_index(cwd, [
        {"sessionId": "s", "projectDir": str(root), "createdAt": "1", "updatedAt": "2"},
    ])
    write_junie_log(
        cwd, "log-a.log",
        "session s\n"
        "WARN Unrecognized 'model' value 'bad-model', falling back to default.\n",
    )
    monkeypatch.chdir(cwd)
    git = FakeGit(toplevel=str(root), local_config={"orchestrator.junie.model.fixer": "bad-model"})

    records = doctor_records(capsys, git, "", tmp_path / "no-agents")
    assert ("ok", "junie session: cannot tell (no Junie session index)") in records
    assert not any("did not recognise" in msg for _, msg in records)


def test_check_settings_junie_copy_drift_warns_via_shared_sync_plan(root, tmp_path, capsys):
    plugin = fake_plugin(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    git, _ = git_with_exclude(
        root,
        local_config={"orchestrator.junie.effort.implementer": "high"},
        global_config={"orchestrator.junie.model.reviewer": "gpt-5"},
    )
    copies_dir = root / ".junie" / "agents"

    # 1. Missing copies warn with agent sync remedy after Junie role lines.
    records = doctor_records(capsys, git, home, plugin)
    junie_auditor_idx = records.index(
        ("ok", "agent junie auditor: model inherit (inherit), effort inherit (inherit)")
    )
    assert records[junie_auditor_idx + 1:] == [
        (
            "warn",
            "Junie agent copies in %s are not what agent sync would leave:"
            " missing orch-implementer.md orch-reviewer-spec.md orch-reviewer-standards.md"
            % copies_dir,
        ),
        ("remedy", "orch.sh agent sync"),
    ]

    # 2. Once agent sync runs, no drift warning is emitted.
    assert orch_agent(git, "sync", plugin_root=str(plugin)) == 0
    capsys.readouterr()
    records = doctor_records(capsys, git, home, plugin)
    assert not any("Junie agent copies" in msg for _, msg in records)

    # 3. Hand edit triggers stale warning.
    with open(copies_dir / "orch-implementer.md", "a", encoding="utf-8") as f:
        f.write("# hand edit\n")
    records = doctor_records(capsys, git, home, plugin)
    assert (
        "warn",
        "Junie agent copies in %s are not what agent sync would leave: stale orch-implementer.md"
        % copies_dir,
    ) in records
    assert ("remedy", "orch.sh agent sync") in records

    # 4. Unsetting a role's config leaves an extra marked copy.
    git.config_unset("local", "orchestrator.junie.effort.implementer")
    records = doctor_records(capsys, git, home, plugin)
    assert (
        "warn",
        "Junie agent copies in %s are not what agent sync would leave: extra orch-implementer.md"
        % copies_dir,
    ) in records
    assert orch_agent(git, "sync", plugin_root=str(plugin)) == 0
    capsys.readouterr()

    # 5. Unmarked files in the way are named together.
    (copies_dir / "orch-reviewer-spec.md").write_text("mine\n", encoding="utf-8")
    (copies_dir / "orch-reviewer-standards.md").write_text("mine too\n", encoding="utf-8")
    records = doctor_records(capsys, git, home, plugin)
    assert (
        "warn",
        "Junie agent copies in %s are not what agent sync would leave:"
        " orch-reviewer-spec.md orch-reviewer-standards.md carries no sync marker and is in the way"
        % copies_dir,
    ) in records

    # 6. Combined missing, stale, extra, and refused drift formats in exact order.
    git.config_set("local", "orchestrator.junie.model.closer", "gpt-5")
    git.config_set("local", "orchestrator.junie.model.fixer", "gpt-5")
    (copies_dir / "orch-fixer.md").write_text(
        "---\n%s\nname: orch-fixer\n---\nstale\n" % agent.AGENT_COPY_MARKER, encoding="utf-8"
    )
    (copies_dir / "orch-gone.md").write_text(
        "---\n%s\nname: orch-gone\n---\n" % agent.AGENT_COPY_MARKER, encoding="utf-8"
    )
    records = doctor_records(capsys, git, home, plugin)
    assert (
        "warn",
        "Junie agent copies in %s are not what agent sync would leave:"
        " missing orch-closer.md;"
        " stale orch-fixer.md;"
        " extra orch-gone.md;"
        " orch-reviewer-spec.md orch-reviewer-standards.md carries no sync marker and is in the way"
        % copies_dir,
    ) in records
    assert ("remedy", "orch.sh agent sync") in records
