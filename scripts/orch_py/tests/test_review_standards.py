"""`review standards` (#1532), review.run in-process in a FakeGit checkout
under tmp_path holding fixture standards documents - the cases of the bash
review standards section: the declaration, the two-hop crawl, backticks
across a line break, links against the file's directory, fences and
headings, symlinks leaving the repo, and every declared-entry refusal, each
checked by the one line printed. Its usage line is test_review_noun.py's."""
from __future__ import annotations

import os
from pathlib import Path

import pytest

from conftest import AUTOPILOT, CLAUDE, answered, orch_review

PLUGIN_ROOT = Path(__file__).resolve().parents[3]


def standards(seed, root, capsys, env=None):
    """`orch.sh review standards` in the checkout at <root>, through
    orch_review: (exit code, stdout, stderr), a death's included."""
    return answered(capsys, orch_review(seed, root, "standards", env=env))


def printed(seed, root, capsys):
    """The one line `review standards` prints, asserting it exits 0 with
    nothing on stderr."""
    code, out, err = standards(seed, root, capsys)
    assert (code, err) == (0, "")
    return out


def write(root, relative, *lines, raw=None):
    """<lines>, each ending in a newline - or <raw> as it is - written to
    <root>/<relative>, its directories made."""
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(line + "\n" for line in lines) if raw is None else raw)
    return path


@pytest.fixture
def docs(root):
    """The checkout's empty standards documents: docs/agents/{c,p,q}.md,
    docs/deep/third.md and CONTRIBUTING.md."""
    for name in ("docs/agents/c.md", "docs/agents/p.md", "docs/agents/q.md",
                 "docs/deep/third.md", "CONTRIBUTING.md"):
        write(root, name, raw="")
    return root


def test_a_repo_with_no_standards_document_prints_none(root, capsys, seed):
    assert printed(seed, root, capsys) == "Standards: none\n"


# --- the crawl ----------------------------------------------------------------


def test_the_crawl_lists_both_root_agent_files_then_two_hops_each_once_and_no_third(
        root, docs, tmp_path, capsys, seed):
    # Each refused mention names a file that would exist were its filter to
    # fail: the path clamped at the root, the absolute path or the URL read as
    # relative.
    write(root, "outside/out.md", raw="")
    write(root, "etc/x.md", raw="")
    write(root, "docs/agents/etc/x.md", raw="")
    write(root, "docs/agents/https:/example.com/README.md", raw="")
    write(root, "CLAUDE.md", "# claude",
          "See `docs/agents/a.md` and [the guide](docs/agents/missing.md).",
          "Also `AGENTS.md`, `CONTRIBUTING.md#develop` and `docs/agents/` itself.")
    write(root, "AGENTS.md", "# agents", "Read [c](docs/agents/c.md#section) first.")
    write(root, "docs/agents/a.md", "# a", "Then [b](b.md#top), `CONTRIBUTING.md` again,",
          "[out](../../../outside/out.md), [abs](/etc/x.md),",
          "[url](https://example.com/README.md), `/etc/x.md` and `docs/agents/gone.md`.")
    write(root, "docs/agents/b.md", "# b",
          "A third hop: [third](../deep/third.md), `docs/deep/third.md`.")

    assert printed(seed, root, capsys) == (
        "Standards: CLAUDE.md, AGENTS.md, docs/agents/a.md, CONTRIBUTING.md, docs/agents/c.md,"
        " docs/agents/b.md\n")


def test_only_claude_md_is_listed_when_agents_md_is_missing(root, docs, capsys, seed):
    write(root, "CLAUDE.md", "# claude", "Nothing to follow.")

    assert printed(seed, root, capsys) == "Standards: CLAUDE.md\n"


def test_with_no_root_agent_file_coding_standards_then_contributing_are_crawled(root, docs,
                                                                               capsys, seed):
    write(root, "CONTRIBUTING.md", "# contributing", "See [the standards](docs/agents/a.md).")
    write(root, "CODING_STANDARDS.md", "# coding", "Plain.")
    write(root, "docs/agents/a.md", "Then [b](b.md#top).")
    write(root, "docs/agents/b.md", raw="")

    assert printed(seed, root, capsys) == (
        "Standards: CODING_STANDARDS.md, CONTRIBUTING.md, docs/agents/a.md, docs/agents/b.md\n")


def test_a_path_holding_a_comma_is_listed_whole(root, docs, capsys, seed):
    write(root, "docs/agents/a,b.md", raw="")
    write(root, "CONTRIBUTING.md", "See [the pair](docs/agents/a,b.md) and `docs/agents/c.md`.")

    assert printed(seed, root, capsys) == (
        "Standards: CONTRIBUTING.md, docs/agents/a,b.md, docs/agents/c.md\n")


def test_a_link_in_angle_brackets_with_a_title_is_read_to_its_first_space(root, docs, capsys,
                                                                         seed):
    write(root, "CLAUDE.md", 'See [p](<docs/agents/p.md> "the p doc").')

    assert printed(seed, root, capsys) == "Standards: CLAUDE.md, docs/agents/p.md\n"


@pytest.mark.parametrize("text, want", [
    (("# claude", "A span `wrapped", "over a line` then `docs/agents/p.md` here."), "p"),
    (("# claude", "An open tick ` here.", "", "Next `docs/agents/q.md` and a stray ` tick."), "q"),
    (("# claude", "```sh", "echo hi", "```", "", "Then `docs/agents/p.md`."), "p"),
    (("# claude", "## The `x", "See `docs/agents/p.md`."), "p"),
    (("# claude", "```sh", "# run `orch.sh branch", "# retire <old> <new>` then see"
      " `docs/agents/p.md`", "```"), "p"),
], ids=["wrapped-span", "open-tick", "fence-before", "heading-tick", "fenced-hash"])
def test_backticks_pair_per_paragraph_never_across_a_blank_line_or_a_heading(root, docs, capsys,
                                                                            text, want, seed):
    write(root, "CLAUDE.md", *text)

    assert printed(seed, root, capsys) == "Standards: CLAUDE.md, docs/agents/%s.md\n" % want


def test_a_crlf_blank_line_ends_a_paragraph(root, docs, capsys, seed):
    write(root, "CLAUDE.md", raw="# claude\r\nAn open tick ` here.\r\n\r\n"
                                 "Next `docs/agents/q.md` and a stray ` tick.\r\n")

    assert printed(seed, root, capsys) == "Standards: CLAUDE.md, docs/agents/q.md\n"


def test_a_fence_under_and_over_a_paragraph_line_keeps_each_path_in_its_own_paragraph(
        root, docs, capsys, seed):
    write(root, "CLAUDE.md", "# claude", "See `docs/agents/q.md` and a stray ` tick", "```sh",
          "a stray ` tick", "", "run `docs/agents/p.md`", "```",
          "then `docs/agents/c.md` and a stray ` tick")

    assert printed(seed, root, capsys) == (
        "Standards: CLAUDE.md, docs/agents/q.md, docs/agents/p.md, docs/agents/c.md\n")


# --- the declaration ----------------------------------------------------------


def test_a_declaration_replaces_the_crawl_in_its_order_wrapped_whole_first_paragraph_only(
        root, docs, capsys, seed):
    write(root, "CLAUDE.md", "# claude", "See `docs/agents/p.md`.", "",
          "Standards: `docs/agents/q.md`, then prose", "wrapped with `docs/agents/c.md`.", "",
          "Standards: `docs/agents/p.md`")

    assert printed(seed, root, capsys) == "Standards: docs/agents/q.md, docs/agents/c.md\n"


@pytest.mark.parametrize("files, want", [
    ({"CLAUDE.md": "# claude\nNothing.\n", "AGENTS.md": "Standards: `docs/agents/p.md`\n"},
     "Standards: docs/agents/p.md\n"),
    ({"CLAUDE.md": "Standards: `docs/agents/q.md`\n",
      "AGENTS.md": "Standards: `docs/agents/p.md`\n"}, "Standards: docs/agents/q.md\n"),
    ({"CONTRIBUTING.md": "Standards: `docs/agents/q.md`\n"}, "Standards: docs/agents/q.md\n"),
    ({"CONTRIBUTING.md": "Standards: `docs/agents/q.md`\n",
      "CODING_STANDARDS.md": "Standards: `docs/agents/p.md`\n"}, "Standards: docs/agents/p.md\n"),
    ({"CONTRIBUTING.md": "Standards: `docs/agents/q.md`\n", "CODING_STANDARDS.md": "# coding\n"},
     "Standards: docs/agents/q.md\n"),
    ({"CONTRIBUTING.md": "Standards: `docs/agents/q.md`\n", "CLAUDE.md": "# claude\n"},
     "Standards: CLAUDE.md\n"),
    ({"CONTRIBUTING.md": "# claude\nStandards: `docs/agents/q.md`\n"},
     "Standards: docs/agents/q.md\n"),
], ids=["agents-after-claude", "claude-wins", "contributing", "coding-wins", "coding-silent",
        "claude-present-crawls", "under-a-heading"])
def test_the_first_root_file_declaring_wins(root, docs, capsys, files, want, seed):
    for name, text in files.items():
        write(root, name, raw=text)

    assert printed(seed, root, capsys) == want


@pytest.mark.parametrize("text", [
    "```\nx\n\nStandards: `docs/agents/p.md`\n```\n",
    "```\nStandards: `docs/agents/p.md`\n```\n",
    "```\n~~~\n\nStandards: `docs/agents/p.md`\n```\n",
    "####### seven\nStandards: `docs/agents/p.md`\n",
], ids=["fenced-after-blank", "after-the-fence", "tilde-inside-backticks", "seven-hashes"])
def test_a_standards_line_in_a_fence_or_under_no_heading_is_no_declaration(root, docs, capsys,
                                                                          text, seed):
    write(root, "CONTRIBUTING.md", raw=text)

    assert printed(seed, root, capsys) == "Standards: CONTRIBUTING.md, docs/agents/p.md\n"


def test_a_crlf_blank_line_ends_a_declaration_paragraph(root, docs, capsys, seed):
    write(root, "CONTRIBUTING.md",
          raw="Standards: `docs/agents/q.md`\r\n\r\nSee `docs/agents/nope.md`.\r\n")

    assert printed(seed, root, capsys) == "Standards: docs/agents/q.md\n"


def test_a_crlf_declaration_wrapping_from_its_first_line_keeps_no_cr_in_its_span(root, docs,
                                                                                capsys, seed):
    write(root, "docs/agents/wrap.md", raw="# A B\n")
    write(root, "CLAUDE.md", raw="Standards: `docs/agents/wrap.md#A\r\nB`\r\n")

    assert printed(seed, root, capsys) == "Standards: docs/agents/wrap.md#A B\n"


def test_heading_entries_print_as_declared_the_closed_heading_and_backslashes_literal(
        root, docs, capsys, seed):
    write(root, "docs/agents/h.md", "# Top", "", "## Develop ##", "text", "### Sub")
    write(root, "docs/agents/bs.md", "# Top", "## a\\b", "## c\\\\d")
    write(root, "CONTRIBUTING.md", "Standards: `docs/agents/h.md#Develop`, `docs/agents/h.md#Sub`,"
          " `docs/agents/bs.md#a\\b`, `docs/agents/bs.md#c\\\\d`")

    assert printed(seed, root, capsys) == (
        "Standards: docs/agents/h.md#Develop, docs/agents/h.md#Sub, docs/agents/bs.md#a\\b,"
        " docs/agents/bs.md#c\\\\d\n")


def test_a_symlink_to_a_file_inside_the_repo_resolves(root, docs, capsys, seed):
    os.symlink("q.md", str(root / "docs/agents/in.md"))
    write(root, "CONTRIBUTING.md", "Standards: `docs/agents/in.md`")

    assert printed(seed, root, capsys) == "Standards: docs/agents/in.md\n"


@pytest.mark.parametrize("entry, reason", [
    ("docs/agents/nope.txt", "names a missing file"),
    ("/etc/passwd", "is an absolute path (want a repo-relative path)"),
    ("https://example.com/a", "is a URL (want a repo-relative path)"),
    ("../outside.md", "leaves the repo (want a path inside it)"),
    ("docs/adir", "is not a regular file"),
    ("docs/agents/out.md", "leaves the repo (want a path inside it)"),
    ("docs/agents/h.md#develop", "names a missing heading"),
    ("docs/agents/h.md#Fenced", "names a missing heading"),
    ("docs/agents/h.md#Blanked", "names a missing heading"),
    ("docs/agents/h.md#Twice", "names an ambiguous heading (matches 2 times)"),
], ids=["missing", "absolute", "url", "dotdot", "directory", "symlink-out", "case",
        "fenced", "fenced-after-blank", "ambiguous"])
def test_each_declared_entry_that_does_not_resolve_dies_naming_it_after_a_valid_one(
        root, docs, capsys, entry, reason, seed):
    (root / "docs/adir").mkdir()
    os.symlink("/etc/passwd", str(root / "docs/agents/out.md"))
    write(root, "docs/agents/h.md", "# Top", "", "## Develop ##", "text", "### Sub", "", "```",
          "# Fenced", "", "# Blanked", "", "```", "## Twice", "## Twice")
    write(root, "CONTRIBUTING.md", "Standards: `docs/agents/p.md`, `%s`" % entry)

    assert standards(seed, root, capsys) == (
        1, "", "orch: Standards entry `%s` %s\n" % (entry, reason))


def test_a_declaration_with_no_entries_dies_saying_so(root, docs, capsys, seed):
    write(root, "CONTRIBUTING.md", "Standards: nothing backticked")

    assert standards(seed, root, capsys) == (
        1, "", "orch: CONTRIBUTING.md declares Standards: with no entries (want backticked"
               " paths)\n")


# --- symlinks leaving the repo (#2177) ----------------------------------------


@pytest.fixture
def outside(tmp_path):
    """A standards document outside the checkout, mentioning one inside."""
    path = tmp_path / "outside.md"
    path.write_text("# outside\nSee `docs/agents/p.md`.\n")
    return str(path)


def test_a_first_hop_mention_symlinked_out_of_the_repo_is_left_off(root, docs, outside, capsys,
                                                                    seed):
    write(root, "CLAUDE.md", "# claude", "See `docs/agents/lnk.md` and `docs/agents/p.md`.")
    os.symlink(outside, str(root / "docs/agents/lnk.md"))

    assert printed(seed, root, capsys) == "Standards: CLAUDE.md, docs/agents/p.md\n"


def test_a_second_hop_mention_symlinked_out_of_the_repo_is_left_off(root, docs, outside, capsys,
                                                                     seed):
    write(root, "CLAUDE.md", "# claude", "See `docs/agents/hop.md`.")
    write(root, "docs/agents/hop.md", "See `docs/agents/lnk.md`.")
    os.symlink(outside, str(root / "docs/agents/lnk.md"))

    assert printed(seed, root, capsys) == "Standards: CLAUDE.md, docs/agents/hop.md\n"


def test_a_mention_symlinked_to_a_file_inside_the_repo_is_still_listed(root, docs, capsys, seed):
    write(root, "CLAUDE.md", "# claude", "See `docs/agents/hop.md`.")
    write(root, "docs/agents/hop.md", "See `docs/agents/inlnk.md`.")
    os.symlink("p.md", str(root / "docs/agents/inlnk.md"))

    assert printed(seed, root, capsys) == (
        "Standards: CLAUDE.md, docs/agents/hop.md, docs/agents/inlnk.md\n")


@pytest.mark.parametrize("links", [("CLAUDE.md",), ("AGENTS.md",), ("CONTRIBUTING.md",)])
def test_a_root_file_symlinked_out_of_the_repo_is_left_off(root, outside, capsys, links, seed):
    for name in links:
        os.symlink(outside, str(root / name))

    assert printed(seed, root, capsys) == "Standards: none\n"


def test_with_both_root_agent_files_symlinked_out_the_fallback_runs(root, docs, outside, capsys,
                                                                     seed):
    os.symlink(outside, str(root / "CLAUDE.md"))
    os.symlink(outside, str(root / "AGENTS.md"))
    write(root, "CONTRIBUTING.md", "# contributing", "See `docs/agents/q.md`.")

    assert printed(seed, root, capsys) == "Standards: CONTRIBUTING.md, docs/agents/q.md\n"


# --- this repo, and an autopilot session ----------------------------------------


def test_the_plugin_root_s_own_declaration_resolves_to_its_three_entries(capsys, seed):
    assert printed(seed, PLUGIN_ROOT, capsys) == (
        "Standards: CONTRIBUTING.md#Develop, docs/agents/cli-conventions.md,"
        " docs/agents/coding-standards.md\n")


@pytest.mark.parametrize("text", ["Standards: `docs/agents/q.md`\n",
                                  "Standards: `docs/agents/gone.md`\n"], ids=["ok", "refused"])
def test_an_autopilot_session_resolves_as_a_plain_one(root, docs, capsys, text, seed):
    write(root, "CONTRIBUTING.md", raw=text)

    assert standards(seed, root, capsys, AUTOPILOT) == standards(seed, root, capsys, CLAUDE)


def test_a_rejected_declaration_prints_nothing_on_stdout(root, docs, capsys, seed):
    write(root, "CONTRIBUTING.md", "Standards: `docs/agents/q.md`, `docs/agents/gone.md`")

    assert standards(seed, root, capsys)[1] == ""
