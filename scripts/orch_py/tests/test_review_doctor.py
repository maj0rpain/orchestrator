"""Doctor's three review bridges, each called as orch_python_call calls it -
through orch.cli's call_func, in a real repository under tmp_path, the gh
fake on its store - and checked by exactly the data doctor reads: the
terminal-state bridge's classification word, its detail and, for malformed,
the record path; the CI bridge's ci_probe verdict and detail lines; and the
Standards bridge's resolution, its rejected declaration's partial output and
its death with exit 3."""
from __future__ import annotations

import pytest

from conftest import git_repo, hold_flow, record, write
from orch import cli
from orch.review import MALFORMED_SHAPE

INDENT = "      "


@pytest.fixture
def checkout(tmp_path, monkeypatch):
    """A real repository at tmp_path/repo, resolved, its origin on GitHub,
    the process inside it, as doctor runs: its root."""
    root = tmp_path.resolve() / "repo"
    root.mkdir()
    git_repo(root, origin="https://github.com/acme/widgets.git")
    monkeypatch.chdir(str(root))
    return root


def bridge(capsys, func, *args):
    """`orch_python_call --as doctor review <func> <args>`, as orch.__main__
    hands it to call_func: (exit code, stdout, stderr), a death's
    included."""
    try:
        code = cli.call_func(["review", func, *args])
    except SystemExit as died:
        code = died.code
    out, err = capsys.readouterr()
    return code, out, err


# --- the terminal-state bridge ------------------------------------------------


def terminal(capsys, i, budget):
    return bridge(capsys, "doctor_terminal", i, budget)


def test_terminal_bridge_prints_none_for_a_loop_not_started(checkout, capsys):
    assert terminal(capsys, "0", "5") == (0, "none\n", "")


def test_terminal_bridge_prints_pending_short_of_the_budget(checkout, capsys):
    assert terminal(capsys, "2", "5") == (0, "pending\n", "")


def test_terminal_bridge_prints_interrupted_at_the_budget(checkout, capsys):
    assert terminal(capsys, "5", "5") == (0, "interrupted\n", "")


def test_terminal_bridge_prints_ready(checkout, capsys):
    record(checkout, 5, "## Terminal state", "ready")
    assert terminal(capsys, "5", "5") == (0, "ready\n", "")


def test_terminal_bridge_prints_stop_with_its_reason_lines(checkout, capsys):
    record(checkout, 2, "## Terminal state", "stop", "CI failed twice.")
    assert terminal(capsys, "2", "5") == (0, "stop\nCI failed twice.\n", "")


def test_terminal_bridge_prints_malformed_its_shape_then_the_record_path(checkout, capsys):
    path = record(checkout, 5, "## Terminal state", "**stop**")
    assert terminal(capsys, "5", "5") == (0, "malformed\n%s\n%s\n" % (MALFORMED_SHAPE, path), "")


def test_terminal_bridge_prints_unreadable_with_the_directory_it_could_not_make(checkout,
                                                                               capsys):
    (checkout / ".orchestrator").mkdir()
    (checkout / ".orchestrator" / "review").write_text("")
    code, out, err = terminal(capsys, "5", "5")
    assert (code, out.rstrip("\n"), err) == (
        0, "unreadable\ncannot create the review directory %s/.orchestrator/review" % checkout, "")


def test_terminal_bridge_mid_redo_names_the_retired_malformed_record(checkout, capsys):
    hold_flow(checkout, slug="t", phase="review", issue=21, branch="orch/21-t-redo-1",
              redo_count=1)
    path = record(checkout, 5, "## Terminal state", "stopped here", under="pre-redo-1")
    assert terminal(capsys, "5", "5") == (0, "malformed\n%s\n%s\n" % (MALFORMED_SHAPE, path), "")


def test_terminal_bridge_mid_redo_reads_the_retired_stop(checkout, capsys):
    hold_flow(checkout, slug="t", phase="review", issue=21, branch="orch/21-t-redo-1",
              redo_count=1)
    record(checkout, 5, "## Terminal state", "stop - base sync failed.", under="pre-redo-1")
    assert terminal(capsys, "5", "5") == (0, "stop\nbase sync failed.\n", "")


@pytest.mark.parametrize("args", [(), ("5",), ("5", "5", "5")], ids=["none", "one", "three"])
def test_terminal_bridge_dies_with_its_usage_on_wrong_arguments(checkout, capsys, args):
    assert bridge(capsys, "doctor_terminal", *args) == (
        1, "", "orch: usage: orch_python_call review doctor_terminal <iteration> <budget>\n")


# --- the CI bridge ------------------------------------------------------------


@pytest.fixture
def github(checkout, seed, monkeypatch):
    """The gh fake on <seed>'s store, serving the checkout's process."""
    monkeypatch.setenv("ORCH_GH_FAKE_STORE", seed.store)
    return seed


@pytest.mark.parametrize("answer, printed", [
    ("green", "green\n"),
    ("none", "none\n"),
    ("pending", "pending\n"),
    ("failing", "failing\n%sbuild\n" % INDENT),
    ("boom", "unreachable\n%sdial tcp: lookup api.github.com: no such host\n" % INDENT),
])
def test_ci_bridge_prints_the_verdict_and_detail_of_the_required_checks(github, capsys, answer,
                                                                          printed):
    github.checks(40, "required", answer)
    assert bridge(capsys, "doctor_ci", "40") == (0, printed, "")


def test_ci_bridge_reads_the_required_scope_alone(github, capsys):
    github.checks(40, "all", "failing")
    assert bridge(capsys, "doctor_ci", "40") == (0, "none\n", "")


def test_ci_bridge_carries_a_failed_reads_first_line(github, capsys):
    github.fail("adapter_pr_checks", "HTTP 502: Bad Gateway\nsecond line")
    assert bridge(capsys, "doctor_ci", "40") == (0, "unreachable\n%sHTTP 502: Bad Gateway\n"
                                                 % INDENT, "")


@pytest.mark.parametrize("args", [(), ("40", "41")], ids=["none", "two"])
def test_ci_bridge_dies_with_its_usage_on_wrong_arguments(github, capsys, args):
    assert bridge(capsys, "doctor_ci", *args) == (
        1, "", "orch: usage: orch_python_call review doctor_ci <pr>\n")


# --- the Standards bridge -----------------------------------------------------


def standards(capsys):
    return bridge(capsys, "doctor_standards")


def test_standards_bridge_prints_crawled_alone_with_nothing_to_crawl(checkout, capsys):
    assert standards(capsys) == (0, "crawled\n", "")


def test_standards_bridge_prints_crawled_and_the_list(checkout, capsys):
    write(checkout, "docs/rules.md", "rules")
    write(checkout, "CLAUDE.md", "See `docs/rules.md`.")
    assert standards(capsys) == (0, "crawled\nCLAUDE.md\ndocs/rules.md\n", "")


def test_standards_bridge_prints_the_declaring_file_and_its_entries(checkout, capsys):
    write(checkout, "docs/rules.md", "rules")
    write(checkout, "docs/more.md", "more")
    write(checkout, "CLAUDE.md", "Standards: `docs/rules.md`, `docs/more.md`")
    assert standards(capsys) == (0, "declared CLAUDE.md\ndocs/rules.md\ndocs/more.md\n", "")


def test_standards_bridge_on_a_rejected_entry_prints_up_to_it_and_exits_3(checkout, capsys):
    write(checkout, "docs/rules.md", "rules")
    write(checkout, "CLAUDE.md", "Standards: `docs/rules.md`, `docs/missing.md`, `docs/rules.md`")
    assert standards(capsys) == (
        3, "declared CLAUDE.md\ndocs/rules.md\ndocs/missing.md\n",
        "orch: Standards entry `docs/missing.md` names a missing file\n")


def test_standards_bridge_on_a_declaration_with_no_entries_prints_its_file_and_exits_3(
        checkout, capsys):
    write(checkout, "CLAUDE.md", "Standards: none here")
    assert standards(capsys) == (
        3, "declared CLAUDE.md\n",
        "orch: CLAUDE.md declares Standards: with no entries (want backticked paths)\n")


def test_standards_bridge_dies_with_its_usage_on_any_argument(checkout, capsys):
    assert bridge(capsys, "doctor_standards", "x") == (
        1, "", "orch: usage: orch_python_call review doctor_standards\n")
