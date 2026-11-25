"""The entry point of `python3 -m orch`: its interpreter check and the
standard-library-only runtime."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from conftest import died_of
from orch.__main__ import main

PACKAGE_ROOT = Path(__file__).resolve().parent.parent


def test_a_python_below_3_9_dies_before_doing_anything(monkeypatch, capsys):
    monkeypatch.setattr(sys, "version_info", (3, 8, 10, "final", 0))

    assert died_of(capsys, lambda: main(["issue", "fetch", "12"])) == (
        1, "",
        "orch: orch.sh issue needs python3 3.9 or newer (found 3.8.10)"
        " - run orch.sh doctor\n",
    )


def test_python_3_9_passes_the_check(monkeypatch, capsys):
    monkeypatch.setattr(sys, "version_info", (3, 9, 0, "final", 0))

    code, _, err = died_of(capsys, lambda: main(["no-such-noun"]))

    assert "needs python3" not in err
    assert code == 1


def test_an_unconverted_noun_is_an_unknown_command(capsys):
    assert died_of(capsys, lambda: main(["no-such-noun", "verb"])) == (
        1, "", "orch: unknown command: no-such-noun (run 'orch.sh help')\n"
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
    assert died_of(capsys, lambda: main(["issue", "labels"])) == (
        1, "", "orch: usage: orch.sh issue labels <n>...\n")


def test_the_finding_triage_noun_is_converted(capsys):
    assert died_of(capsys, lambda: main(["finding-triage", "scan", "--all", "--all"])) == (
        1, "", "orch: usage: orch.sh finding-triage scan [--all] [<issue> | --pr <n>]\n")


def test_the_spec_review_noun_is_routed_to_its_module(capsys):
    assert died_of(capsys, lambda: main(["spec-review", "wipe"])) == (
        1, "", "orch: unknown spec-review op: wipe (want begin|check|apply|wait|prompt)\n")


def test_call_mode_below_python_3_9_dies_naming_the_noun(monkeypatch, capsys):
    monkeypatch.setattr(sys, "version_info", (3, 8, 10, "final", 0))

    assert died_of(capsys, lambda: main(["--call", "agent", "check_settings"])) == (
        1, "",
        "orch: orch.sh agent needs python3 3.9 or newer (found 3.8.10)"
        " - run orch.sh doctor\n",
    )


def test_call_mode_below_python_3_9_dies_naming_the_command_given_by_as(monkeypatch, capsys):
    monkeypatch.setattr(sys, "version_info", (3, 8, 10, "final", 0))

    assert died_of(capsys, lambda: main(
        ["--call", "--as", "autopilot", "agent", "validate_autopilot"])) == (
        1, "",
        "orch: orch.sh autopilot needs python3 3.9 or newer (found 3.8.10)"
        " - run orch.sh doctor\n",
    )


def test_call_mode_with_as_dispatches_the_noun_after_it(capsys):
    assert died_of(capsys, lambda: main(["--call", "--as", "autopilot", "issue", "run", "labels"])) == (
        1, "", "orch: usage: orch.sh issue labels <n>...\n")


def test_call_mode_dispatches_a_named_function_on_a_converted_noun(capsys):
    assert died_of(capsys, lambda: main(["--call", "issue", "run", "labels"])) == (
        1, "", "orch: usage: orch.sh issue labels <n>...\n")
    assert died_of(capsys, lambda: main(["--call", "spec-review", "run", "wipe"])) == (
        1, "", "orch: unknown spec-review op: wipe (want begin|check|apply|wait|prompt)\n")


def test_call_mode_refuses_missing_args_unknown_noun_and_unknown_or_private_function(capsys):
    usage = "orch: usage: orch_python_call [--as <command>] <noun> <func> [<arg>...]\n"
    assert died_of(capsys, lambda: main(["--call"])) == (1, "", usage)
    assert died_of(capsys, lambda: main(["--call", "route"])) == (1, "", usage)
    assert died_of(capsys, lambda: main(["--call", "--as"])) == (1, "", usage)
    assert died_of(capsys, lambda: main(["--call", "--as", "autopilot", "route"])) == (
        1, "", usage)
    assert died_of(capsys, lambda: main(["--call", "no-such-noun", "run"])) == (
        1, "", "orch: unknown command: no-such-noun (run 'orch.sh help')\n")
    assert died_of(capsys, lambda: main(["--call", "route", "no_such_fn"])) == (
        1, "", "orch: unknown route function: no_such_fn\n")
    assert died_of(capsys, lambda: main(["--call", "route", "_private"])) == (
        1, "", "orch: unknown route function: _private\n")
