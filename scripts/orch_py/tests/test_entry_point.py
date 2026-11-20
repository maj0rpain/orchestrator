"""The entry point of `python3 -m orch`: its interpreter check and the
standard-library-only runtime."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

from orch.cli import main

PACKAGE_ROOT = Path(__file__).resolve().parent.parent


def test_a_python_below_3_9_dies_before_doing_anything(monkeypatch, capsys):
    monkeypatch.setattr(sys, "version_info", (3, 8, 10, "final", 0))

    with pytest.raises(SystemExit) as died:
        main(["issue", "fetch", "12"])

    assert died.value.code == 1
    out, err = capsys.readouterr()
    assert out == ""
    assert err == (
        "orch: orch.sh issue needs python3 3.9 or newer (found 3.8.10)"
        " - run orch.sh doctor\n"
    )


def test_python_3_9_passes_the_check(monkeypatch, capsys):
    monkeypatch.setattr(sys, "version_info", (3, 9, 0, "final", 0))

    with pytest.raises(SystemExit) as died:
        main(["no-such-noun"])

    _, err = capsys.readouterr()
    assert "needs python3" not in err
    assert died.value.code == 1


def test_an_unconverted_noun_is_an_unknown_command(capsys):
    with pytest.raises(SystemExit) as died:
        main(["no-such-noun", "verb"])

    assert died.value.code == 1
    assert capsys.readouterr().err == (
        "orch: unknown command: no-such-noun (run 'orch.sh help')\n"
    )


def test_every_module_imports_with_site_packages_disabled():
    script = (
        "import importlib, pkgutil, orch\n"
        "for m in pkgutil.walk_packages(orch.__path__, 'orch.'):\n"
        "    importlib.import_module(m.name)\n"
        "print('imported')\n"
    )
    env = dict(os.environ, PYTHONPATH=str(PACKAGE_ROOT), PYTHONDONTWRITEBYTECODE="1")

    run = subprocess.run(
        [sys.executable, "-S", "-c", script],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        timeout=30,
    )

    assert (run.returncode, run.stdout, run.stderr) == (0, "imported\n", "")


def test_the_issue_noun_is_converted(capsys):
    with pytest.raises(SystemExit) as died:
        main(["issue", "labels"])

    assert died.value.code == 1
    assert capsys.readouterr() == ("", "orch: usage: orch.sh issue labels <n>...\n")
