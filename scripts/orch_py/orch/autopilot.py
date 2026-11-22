"""The autopilot concept's module (scripts/orch/autopilot.sh), kept to what
the Python nouns read: whether this is an autopilot session.
"""
from __future__ import annotations

from typing import Mapping


def autopilot_active(env: Mapping[str, str]) -> bool:
    """Whether <env> is an autopilot session's - the one reader of
    ORCH_AUTOPILOT, so no skill reads the variable itself."""
    return env.get("ORCH_AUTOPILOT", "") == "1"
