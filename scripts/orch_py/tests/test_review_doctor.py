"""Two of the review reads doctor's review checks take in process, each
called directly on a plain directory under tmp_path, the gh fake on its
store, and checked by exactly the data doctor reads: ci_probe's verdict and
detail lines over the required checks; and standards_resolve_source's lines,
with a rejected declaration's partial output and its death. The third,
review_terminal_report, has doctor as its one caller, so test_doctor.py's
review loop cases test it through doctor."""
from __future__ import annotations

import pytest

from conftest import fake, write
from orch.review import ci_probe, standards_resolve_source

INDENT = "      "


@pytest.fixture
def checkout(tmp_path):
    """The checkout's root, a plain directory at tmp_path/repo, resolved:
    the reads take the root and start no git."""
    root = tmp_path.resolve() / "repo"
    root.mkdir()
    return root


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
