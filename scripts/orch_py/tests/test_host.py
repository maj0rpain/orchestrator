"""Tests for orch.host: host detection, command wording, and session-end blocks."""
from __future__ import annotations

import pytest

from orch import host


@pytest.mark.parametrize("env, expected", [
    ({}, ""),
    ({"CLAUDECODE": "1"}, "claude"),
    ({"CLAUDECODE": "0"}, ""),
    ({"CLAUDE_PLUGIN_ROOT": "/p"}, "claude"),
    ({"JUNIE_EXTENSION_ROOT": "/j"}, "junie"),
    ({"JUNIE_SHIM_PATH": "/j/shim"}, "junie"),
    ({"JUNIE_SHIM_PATH": "/j/shim", "CLAUDECODE": "1"}, "junie"),
    ({"ANTIGRAVITY_AGENT": "1"}, "antigravity"),
    ({"ANTIGRAVITY_CONVERSATION_ID": "abc"}, "antigravity"),
    ({"ANTIGRAVITY_AGENT": "1", "JUNIE_SHIM_PATH": "/j", "CLAUDECODE": "1"}, "antigravity"),
    ({"ORCHESTRATOR_HOST": "claude", "ANTIGRAVITY_AGENT": "1"}, "claude"),
    ({"ORCHESTRATOR_HOST": "antigravity", "CLAUDECODE": "1"}, "antigravity"),
    ({"ORCHESTRATOR_HOST": "junie", "CLAUDECODE": "1"}, "junie"),
], ids=[
    "empty",
    "claudecode",
    "claudecode-zero",
    "claude-plugin-root",
    "junie-extension-root",
    "junie-shim-path",
    "junie-over-claude",
    "antigravity-agent",
    "antigravity-conversation-id",
    "antigravity-over-junie-and-claude",
    "override-claude-over-antigravity",
    "override-antigravity-over-claude",
    "override-junie-over-claude",
])
def test_host_detect(env, expected):
    assert host.host_detect(env) == expected


@pytest.mark.parametrize("env, expected", [
    ({"CLAUDECODE": "1"}, "/orchestrator:next"),
    ({"ORCHESTRATOR_HOST": "junie"}, "/orchestrator:next (or orch-flow's Next phase section)"),
    ({"ANTIGRAVITY_AGENT": "1"}, "/orchestrator:next (or orch-flow's Next phase section)"),
    ({}, "/orchestrator:next (or orch-flow's Next phase section)"),
], ids=["claude", "junie", "antigravity", "empty"])
def test_flow_cmd(env, expected):
    assert host.flow_cmd(env, "next") == expected


@pytest.mark.parametrize("env, expected", [
    ({"CLAUDECODE": "1"}, "/clear, then /orchestrator:next"),
    ({"ORCHESTRATOR_HOST": "junie"}, "/new, then ask for the next phase with /orch-flow"),
    ({"ANTIGRAVITY_AGENT": "1"}, "/clear, then ask for the next phase with /orch-flow"),
    ({"ORCHESTRATOR_HOST": "antigravity"}, "/clear, then ask for the next phase with /orch-flow"),
    ({}, "a fresh session, then /orchestrator:next (or orch-flow's Next phase section)"),
], ids=["claude", "junie", "antigravity-signal", "antigravity-override", "empty"])
def test_next_phase_cmd(env, expected):
    assert host.next_phase_cmd(env) == expected


def test_finding_triage_cmd_on_antigravity():
    assert host.finding_triage_cmd({"ANTIGRAVITY_AGENT": "1"}) == (
        "/orchestrator:finding-triage (or the orch-finding-triage skill)"
    )


def test_print_next_block_on_antigravity(capsys):
    host.print_next_block({"ANTIGRAVITY_AGENT": "1"}, "Paused.")
    assert capsys.readouterr() == (
        "Paused.\n\n  Next: /clear, then ask for the next phase with /orch-flow\n",
        "",
    )
