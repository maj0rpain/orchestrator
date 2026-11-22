"""The host orch.sh runs under, as the bash side's host.sh detects it, and
the plugin commands a message names for it (common.sh's plugin_cmd), a flow
command's among them (common.sh's flow_cmd).
"""
from __future__ import annotations

from typing import Mapping

from orch.common import die

# Each flow command's fallback: the orch-flow section it routes to.
FLOW_SECTIONS = {
    "start": "Starting a flow",
    "next": "Next phase",
    "redo": "Redo",
    "abort": "Abort",
    "finish": "Finish",
}


def host_detect(env: Mapping[str, str]) -> str:
    """"claude", "junie", or "" when no signal is present (orch.sh run by hand
    in a terminal). ORCHESTRATOR_HOST names the host outright; Junie is
    checked before Claude, since a Junie started from a Claude Code terminal
    inherits CLAUDECODE."""
    if env.get("ORCHESTRATOR_HOST", ""):
        return env["ORCHESTRATOR_HOST"]
    if env.get("JUNIE_EXTENSION_ROOT", "") or env.get("JUNIE_SHIM_PATH", ""):
        return "junie"
    if env.get("CLAUDECODE", "") == "1" or env.get("CLAUDE_PLUGIN_ROOT", ""):
        return "claude"
    return ""


def plugin_cmd(env: Mapping[str, str], command: str, fallback: str) -> str:
    """The plugin command <command> as the host names it: the slash command
    alone on Claude Code, else with <fallback>, what to run in its place."""
    if host_detect(env) == "claude":
        return "/orchestrator:" + command
    return "/orchestrator:%s (or %s)" % (command, fallback)


def flow_cmd(env: Mapping[str, str], command: str) -> str:
    """The flow command <command> as the host names it, its fallback the
    orch-flow section it routes to; dies on a command that is none."""
    section = FLOW_SECTIONS.get(command)
    if section is None:
        die("flow_cmd: unknown command: " + command)
    return plugin_cmd(env, command, "orch-flow's %s section" % section)


def finding_triage_cmd(env: Mapping[str, str]) -> str:
    """Finding triage, its fallback the skill the command runs, since finding
    triage is no orch-flow section."""
    return plugin_cmd(env, "finding-triage", "the orch-finding-triage skill")
