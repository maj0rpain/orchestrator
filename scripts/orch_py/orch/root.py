"""orch.sh's ROOT block, for a converted noun: every command runs inside a
checkout. Outside one it dies before doing anything, exit 1, with the message
orch.sh gives there: the working directory, and a remedy naming the checkout
OLDPWD is in when it is in one - an agent whose working directory drifted
into a mktemp directory still has OLDPWD (#1523).
"""
from __future__ import annotations

import os
from typing import Mapping

from orch.common import die

GENERIC_TARGET = "the repo's checkout (its root or a worktree)"


def working_directory(env: Mapping[str, str]) -> str:
    """The working directory as bash's $PWD names it: PWD from <env> when it
    is an absolute path to the process's working directory, else that
    directory itself."""
    here = os.getcwd()
    pwd = env.get("PWD", "")
    try:
        if os.path.isabs(pwd) and os.path.samefile(pwd, here):
            return pwd
    except OSError:
        pass
    return here


def checkout_root(git, env: Mapping[str, str]) -> str:
    """The root of the checkout the git adapter <git> runs in; outside one,
    dies as orch.sh does."""
    root = git.toplevel()
    if root is not None:
        return root
    target = GENERIC_TARGET
    came = env.get("OLDPWD", "")
    if came:
        came_from = git.toplevel_at(came)
        if came_from is not None:
            target = "the checkout you came from, %s," % came_from
    die(
        "not inside a git repository (%s) - cd into %s and run orch.sh there;"
        " a mktemp path is for files, not the working directory"
        % (working_directory(env), target)
    )
