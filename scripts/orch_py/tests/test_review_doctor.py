"""The three review reads doctor's review checks take in process, each called
directly on a plain directory under tmp_path, the gh fake on its store, and
checked by exactly the data doctor reads: review_terminal_report's
classification word, its detail and, for malformed, the record path;
ci_probe's verdict and detail lines over the required checks; and
standards_resolve_source's lines, with a rejected declaration's partial
output and its death."""
from __future__ import annotations

import pytest

from conftest import fake, hold_flow, record, write
from orch.review import MALFORMED_SHAPE, ci_probe, review_terminal_report, standards_resolve_source

INDENT = "      "


@pytest.fixture
def checkout(tmp_path):
    """The checkout's root, a plain directory at tmp_path/repo, resolved:
    the reads take the root and start no git."""
    root = tmp_path.resolve() / "repo"
    root.mkdir()
    return root


# --- the terminal-state read ---------------------------------------------------


def terminal(root, i, budget):
    """review_terminal_report's lines, each ended by a newline."""
    return "".join(line + "\n" for line in review_terminal_report(str(root), i, budget))


def test_terminal_state_is_none_for_a_loop_not_started(checkout):
    assert terminal(checkout, "0", "5") == "none\n"


def test_terminal_state_is_pending_short_of_the_budget(checkout):
    assert terminal(checkout, "2", "5") == "pending\n"


def test_terminal_state_is_interrupted_at_the_budget(checkout):
    assert terminal(checkout, "5", "5") == "interrupted\n"


def test_terminal_state_is_ready(checkout):
    record(checkout, 5, "## Terminal state", "ready")
    assert terminal(checkout, "5", "5") == "ready\n"


def test_terminal_state_is_stop_with_its_reason_lines(checkout):
    record(checkout, 2, "## Terminal state", "stop", "CI failed twice.")
    assert terminal(checkout, "2", "5") == "stop\nCI failed twice.\n"


def test_terminal_state_is_malformed_its_shape_then_the_record_path(checkout):
    path = record(checkout, 5, "## Terminal state", "**stop**")
    assert terminal(checkout, "5", "5") == "malformed\n%s\n%s\n" % (MALFORMED_SHAPE, path)


def test_terminal_state_is_unreadable_with_the_directory_it_could_not_make(checkout):
    (checkout / ".orchestrator").mkdir()
    (checkout / ".orchestrator" / "review").write_text("")
    assert terminal(checkout, "5", "5").rstrip("\n") == (
        "unreadable\ncannot create the review directory %s/.orchestrator/review" % checkout)


def test_terminal_state_mid_redo_names_the_retired_malformed_record(checkout):
    hold_flow(checkout, slug="t", phase="review", issue=21, branch="orch/21-t-redo-1",
              redo_count=1)
    path = record(checkout, 5, "## Terminal state", "stopped here", under="pre-redo-1")
    assert terminal(checkout, "5", "5") == "malformed\n%s\n%s\n" % (MALFORMED_SHAPE, path)


def test_terminal_state_mid_redo_reads_the_retired_stop(checkout):
    hold_flow(checkout, slug="t", phase="review", issue=21, branch="orch/21-t-redo-1",
              redo_count=1)
    record(checkout, 5, "## Terminal state", "stop - base sync failed.", under="pre-redo-1")
    assert terminal(checkout, "5", "5") == "stop\nbase sync failed.\n"


# --- the CI read ---------------------------------------------------------------


def ci(seed, pr):
    """ci_probe's lines over PR <pr>'s required checks, each ended by a
    newline."""
    return "".join(line + "\n" for line in ci_probe(fake(seed), pr, "required"))


@pytest.mark.parametrize("answer, printed", [
    ("green", "green\n"),
    ("none", "none\n"),
    ("pending", "pending\n"),
    ("failing", "failing\n%sbuild\n" % INDENT),
    ("boom", "unreachable\n%sdial tcp: lookup api.github.com: no such host\n" % INDENT),
])
def test_ci_probe_gives_the_verdict_and_detail_of_the_required_checks(seed, answer, printed):
    seed.checks(40, "required", answer)
    assert ci(seed, 40) == printed


def test_ci_probe_reads_the_required_scope_alone(seed):
    seed.checks(40, "all", "failing")
    assert ci(seed, 40) == "none\n"


def test_ci_probe_carries_a_failed_reads_first_line(seed):
    seed.fail("adapter_pr_checks", "HTTP 502: Bad Gateway\nsecond line")
    assert ci(seed, 40) == "unreachable\n%sHTTP 502: Bad Gateway\n" % INDENT


# --- the Standards resolution --------------------------------------------------


def standards(root, capsys):
    """(exit code, stdout, stderr) of standards_resolve_source printing each
    line it emits: 0 when it returns, a death's code otherwise."""
    try:
        standards_resolve_source(str(root), print)
    except SystemExit as died:
        out, err = capsys.readouterr()
        return died.code, out, err
    out, err = capsys.readouterr()
    return 0, out, err


def test_standards_resolution_prints_crawled_alone_with_nothing_to_crawl(checkout, capsys):
    assert standards(checkout, capsys) == (0, "crawled\n", "")


def test_standards_resolution_prints_crawled_and_the_list(checkout, capsys):
    write(checkout, "docs/rules.md", "rules")
    write(checkout, "CLAUDE.md", "See `docs/rules.md`.")
    assert standards(checkout, capsys) == (0, "crawled\nCLAUDE.md\ndocs/rules.md\n", "")


def test_standards_resolution_prints_the_declaring_file_and_its_entries(checkout, capsys):
    write(checkout, "docs/rules.md", "rules")
    write(checkout, "docs/more.md", "more")
    write(checkout, "CLAUDE.md", "Standards: `docs/rules.md`, `docs/more.md`")
    assert standards(checkout, capsys) == (0, "declared CLAUDE.md\ndocs/rules.md\ndocs/more.md\n", "")


def test_standards_resolution_on_a_rejected_entry_prints_up_to_it_and_dies(checkout, capsys):
    write(checkout, "docs/rules.md", "rules")
    write(checkout, "CLAUDE.md", "Standards: `docs/rules.md`, `docs/missing.md`, `docs/rules.md`")
    assert standards(checkout, capsys) == (
        1, "declared CLAUDE.md\ndocs/rules.md\ndocs/missing.md\n",
        "orch: Standards entry `docs/missing.md` names a missing file\n")


def test_standards_resolution_on_a_declaration_with_no_entries_prints_its_file_and_dies(
        checkout, capsys):
    write(checkout, "CLAUDE.md", "Standards: none here")
    assert standards(checkout, capsys) == (
        1, "declared CLAUDE.md\n",
        "orch: CLAUDE.md declares Standards: with no entries (want backticked paths)\n")
