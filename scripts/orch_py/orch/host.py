"""The host orch.sh runs under, as the bash side's host.sh detects it, kept
to what the Python nouns use: the plugin commands a message names for it
(common.sh's plugin_cmd), a flow command's among them (common.sh's
flow_cmd), and the block that ends a session naming the fresh one to start
in the host's own words (next_phase_cmd and print_next_block, whose bash
copies went with the bash phase noun), which the phase noun's boundary and
the spec noun's pause and pause --round print.
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
    """"claude", "junie", "antigravity", or "" when no signal is present
    (orch.sh run by hand in a terminal). ORCHESTRATOR_HOST names the host
    outright; Antigravity and Junie are checked before Claude, since a
    session started from a Claude Code terminal inherits CLAUDECODE."""
    if env.get("ORCHESTRATOR_HOST", ""):
        return env["ORCHESTRATOR_HOST"]
    if env.get("ANTIGRAVITY_AGENT", "") or env.get("ANTIGRAVITY_CONVERSATION_ID", ""):
        return "antigravity"
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


def next_phase_cmd(env: Mapping[str, str]) -> str:
    """How to start the next phase in a fresh session, in the host's own
    words: the Next line of a block that ends a session. Junie's and
    Antigravity's fresh-session wordings are their own, not a flow_cmd name
    (docs/host-capabilities.md, "Start a fresh session"); every other host
    gets flow_cmd's."""
    host = host_detect(env)
    if host == "claude":
        return "/clear, then " + flow_cmd(env, "next")
    if host == "junie":
        return "/new, then ask for the next phase with /orch-flow"
    if host == "antigravity":
        return "/clear, then ask for the next phase with /orch-flow"
    return "a fresh session, then " + flow_cmd(env, "next")


def print_next_block(env: Mapping[str, str], headline: str) -> None:
    """Prints a block that ends a session: <headline>, a blank line, then the
    indented Next line naming the fresh session to start
    (next_phase_cmd)."""
    print("%s\n\n  Next: %s" % (headline, next_phase_cmd(env)))
