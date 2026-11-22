"""The glossary noun run in-process in a FakeGit checkout under tmp_path, and
its parser as pure functions over text: the entry grammar - entry shapes,
bullets, numbered lists and unbolded terms, `#` ends, trailing blanks, aliases
and their scoping - terms, show and match against a root GLOSSARY.md, the
absent and entry-less glossaries, and every misuse, each checked by stdout, the
exit code and the `orch:` message the bash glossary noun gave; and show_file,
docs_lint's reader of one entry from any file."""
from __future__ import annotations

import io
import os
import sys

import pytest

from conftest import died_of
from orch import cli, glossary
from orch.git import FakeGit

# The bash suite's fixture glossary. Flow ends at the next term line and holds
# an inner blank line; Round ends at a section heading and has a scoped alias;
# Side checkout ends at a heading followed by prose; Budget ends at end of
# file, after trailing blank lines.
FIXTURE = "\n".join([
    "# Fixture", "", "Intro prose, never an entry.", "", "## Language", "",
    "### Flow and phases", "",
    "**Flow**:", "One run of the pipeline.", "", "A second paragraph about it.",
    "_Avoid_: pipeline run, workflow.", "",
    "**Round**:", "One review of the spec.",
    "_Avoid_: pass, iteration (the review loop's).", "",
    "### Checkouts", "", "Section prose, never printed.", "",
    "**Side checkout**:", "A worktree beside the main one.",
    "_Avoid_: sibling worktree, second checkout (as the general term, or any).", "",
    "## More", "",
    "**Budget**:", "How many iterations a loop may run.", "", "",
]) + "\n"

FLOW = ("**Flow**:\nOne run of the pipeline.\n\nA second paragraph about it.\n"
        "_Avoid_: pipeline run, workflow.\n")
ROUND = "**Round**:\nOne review of the spec.\n_Avoid_: pass, iteration (the review loop's).\n"
SIDE = ("**Side checkout**:\nA worktree beside the main one.\n"
        "_Avoid_: sibling worktree, second checkout (as the general term, or any).\n")
BUDGET = "**Budget**:\nHow many iterations a loop may run.\n"

# The bash suite's bulleted glossary: bullet and star entries, an indented
# alias line, continuation lines, and numbered and unbolded lines that start
# no entry.
SHAPES = "\n".join([
    "# Glossary", "",
    "- **Member**: A filed finding carried by a bundle.",
    "- **Bundle**: One filed finding standing for several.",
    "  _Avoid_: group, cluster (of findings).",
    "- **Sweep**: One pass over the open findings.",
    "  It runs on demand,", "  and on a schedule.", "",
    "# Other", "", "",
    "**Inline**: A definition on the start line.",
    "* **Starred**: A definition after a star bullet.",
    "1. **Numbered**: never an entry.",
    "Plain: never an entry.", "", "",
]) + "\n"

MEMBER = "- **Member**: A filed finding carried by a bundle.\n"
BUNDLE = "- **Bundle**: One filed finding standing for several.\n  _Avoid_: group, cluster (of findings).\n"

NO_ENTRIES = ("orch: GLOSSARY.md has no entries orch.sh can read (an entry starts at a"
              " **Term**: line, optionally bulleted)\n")


def write_glossary(root, text):
    """Writes <text> as the root GLOSSARY.md of the checkout at <root>."""
    (root / "GLOSSARY.md").write_text(text, encoding="utf-8")


def orch_glossary(root, *argv):
    """`orch.sh glossary <argv>` in-process, in the checkout at <root>: its
    exit code, a SystemExit's included."""
    try:
        return glossary.run(list(argv), git=FakeGit(toplevel=str(root)), env={})
    except SystemExit as died:
        return died.code


def text_file(tmp_path, name, text):
    """A file <name> under tmp_path holding <text>: its path, a str."""
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return str(path)


# --- glossary terms -----------------------------------------------------------


def test_terms_with_no_glossary_prints_nothing(root, capsys):
    assert orch_glossary(root, "terms") == 0
    assert capsys.readouterr() == ("", "")


def test_terms_lists_every_term_name_in_glossary_order(root, capsys):
    write_glossary(root, FIXTURE)

    assert orch_glossary(root, "terms") == 0
    assert capsys.readouterr() == ("Flow\nRound\nSide checkout\nBudget\n", "")


def test_terms_reads_the_root_glossary_wherever_it_runs(root, capsys, monkeypatch):
    write_glossary(root, FIXTURE)
    (root / "sub").mkdir()
    (root / "sub" / "GLOSSARY.md").write_text("**Elsewhere**:\nNot the root's.\n")
    monkeypatch.chdir(root / "sub")

    assert orch_glossary(root, "terms") == 0
    assert capsys.readouterr() == ("Flow\nRound\nSide checkout\nBudget\n", "")


def test_terms_over_bulleted_entries_leaves_numbered_and_unbolded_lines_out(root, capsys):
    write_glossary(root, SHAPES)

    assert orch_glossary(root, "terms") == 0
    assert capsys.readouterr() == ("Member\nBundle\nSweep\nInline\nStarred\n", "")


def test_terms_refuses_an_argument(root, capsys):
    write_glossary(root, FIXTURE)

    assert orch_glossary(root, "terms", "extra") == 2
    assert capsys.readouterr() == ("", "orch: usage: orch.sh glossary terms\n")


@pytest.mark.parametrize("argv, op", [((), "<none>"), (("bogus",), "bogus")])
def test_an_unknown_op_is_an_error_naming_the_ops_that_exist(root, capsys, argv, op):
    assert orch_glossary(root, *argv) == 2
    assert capsys.readouterr() == (
        "", "orch: unknown glossary op: %s (want terms|show|match)\n" % op)


def test_outside_a_checkout_every_op_dies_first(capsys):
    code, out, err = died_of(
        capsys, lambda: glossary.run(["terms"], git=FakeGit(toplevel=None), env={}))

    assert (code, out) == (1, "")
    assert err.startswith("orch: not inside a git repository")


def test_the_cli_module_routes_the_glossary_noun_to_this_module(root, capsys, monkeypatch):
    write_glossary(root, FIXTURE)
    monkeypatch.setattr(glossary, "Git", lambda: FakeGit(toplevel=str(root)))

    assert cli.main(["glossary", "terms"]) == 0
    assert capsys.readouterr() == ("Flow\nRound\nSide checkout\nBudget\n", "")


# --- the parser ---------------------------------------------------------------


def test_an_entry_starts_at_a_bold_term_line_bulleted_or_not_with_or_without_a_definition():
    text = "\n".join([
        "**Bare**:", "- **Dashed**: defined here.", "* **Starred**:\ttabbed.",
        "1. **Numbered**: no entry.", "Plain: no entry.", "**Glued**:no space, no entry.",
        "  **Indented**: no entry.", "+ **Plus**: no entry.",
    ]) + "\n"

    assert [entry.term for entry in glossary.parse(text)] == ["Bare", "Dashed", "Starred"]


def test_an_entry_runs_to_the_next_start_or_hash_line_its_trailing_blanks_trimmed():
    text = "\n".join([
        "**One**:", "first", "", "second", "  ", "",
        "**Two**:", "body", "", "#no space after the hash", "never part of an entry",
        "**Three**:", "last", "\t", "",
    ]) + "\n"

    assert [entry.lines for entry in glossary.parse(text)] == [
        ["**One**:", "first", "", "second"],
        ["**Two**:", "body"],
        ["**Three**:", "last"],
    ]


def test_avoid_aliases_split_at_depth_0_commas_cut_at_their_first_parenthesis():
    text = ("**Term**:\n  _Avoid_:  one , two (a note, with a comma), ,three(x)four,"
            " (only a note), five).\n")

    assert glossary.parse(text)[0].aliases == [
        glossary.Alias("one", False),
        glossary.Alias("two", True),
        glossary.Alias("three", True),
        glossary.Alias("five)", False),
    ]


def test_a_text_with_no_entry_start_gives_no_entries():
    assert glossary.parse("# Glossary\n\nTerms used here.\n\n## Flow\n\nTerm: not bold.\n") == []
    assert glossary.parse("") == []


def test_a_last_line_with_no_newline_is_read():
    assert glossary.parse("**Last**:\nno newline")[0].lines == ["**Last**:", "no newline"]


def test_find_takes_a_term_name_before_an_alias_case_ignored():
    entries = glossary.parse("**Alias**:\nThe term.\n\n**Other**:\n_Avoid_: alias, ÉCOLE.\n")

    assert glossary.find(entries, "ALIAS") == (entries[0], False)
    assert glossary.find(entries, "école") == (entries[1], True)
    assert glossary.find(entries, "nonesuch") == (None, False)


def test_match_needs_no_word_character_before_a_mention_unicode_included():
    entries = glossary.parse("**Flow**:\nA run.\n\n**Été**:\nSummer.\n")

    assert glossary.matches(entries, ["_flow and xflow and éflow"]) == []
    assert glossary.matches(entries, ["(flow) l'ÉTÉ"]) == entries
    assert glossary.matches(entries, ["a été"]) == [entries[1]]


# --- glossary show ------------------------------------------------------------


def test_show_with_no_glossary_names_the_missing_file(root, capsys):
    assert orch_glossary(root, "show", "Flow") == 2
    assert capsys.readouterr() == ("", "orch: no GLOSSARY.md at %s\n" % root)


@pytest.mark.parametrize("term, entry", [
    ("Flow", FLOW),
    ("Round", ROUND),
    ("Side checkout", SIDE),
    ("Budget", BUDGET),
    ("SIDE CHECKOUT", SIDE),
])
def test_show_prints_an_entry_whole_and_nothing_else(root, capsys, term, entry):
    write_glossary(root, FIXTURE)

    assert orch_glossary(root, "show", term) == 0
    assert capsys.readouterr() == (entry, "")


def test_show_prints_terms_in_the_order_asked_each_once_one_blank_line_between(root, capsys):
    write_glossary(root, FIXTURE)

    assert orch_glossary(root, "show", "Budget", "Flow", "budget", "workflow") == 0
    assert capsys.readouterr() == (BUDGET + "\n" + FLOW, "# alias of Flow\n")


@pytest.mark.parametrize("term, entry, owner", [
    ("Workflow", FLOW, "Flow"),
    ("iteration", ROUND, "Round"),
    ("second checkout", SIDE, "Side checkout"),
])
def test_an_avoided_alias_scoped_or_not_resolves_saying_whose_it_is(root, capsys, term,
                                                                    entry, owner):
    write_glossary(root, FIXTURE)

    assert orch_glossary(root, "show", term) == 0
    assert capsys.readouterr() == (entry, "# alias of %s\n" % owner)


def test_an_unknown_term_exits_1_after_every_known_entry_warning_once_per_term(root, capsys):
    write_glossary(root, FIXTURE)

    assert orch_glossary(root, "show", "Flow", "Nonesuch", "Budget", "Other") == 1
    assert capsys.readouterr() == (
        FLOW + "\n" + BUDGET,
        "orch: no glossary entry for 'Nonesuch'\norch: no glossary entry for 'Other'\n")


def test_part_of_a_term_name_is_no_match(root, capsys):
    write_glossary(root, FIXTURE)

    assert orch_glossary(root, "show", "checkout") == 1
    assert capsys.readouterr() == ("", "orch: no glossary entry for 'checkout'\n")


def test_show_with_no_term_is_an_error(root, capsys):
    write_glossary(root, FIXTURE)

    assert orch_glossary(root, "show") == 2
    assert capsys.readouterr() == ("", "orch: usage: orch.sh glossary show <term>...\n")


def test_show_succeeds_with_tmpdir_at_an_unusable_directory(root, capsys, monkeypatch,
                                                            tmp_path):
    write_glossary(root, FIXTURE)
    monkeypatch.setenv("TMPDIR", str(tmp_path / "nonexistent-dir"))

    assert orch_glossary(root, "show", "Flow", "Nonesuch") == 1
    assert capsys.readouterr() == (FLOW, "orch: no glossary entry for 'Nonesuch'\n")


@pytest.mark.parametrize("term, entry", [
    ("member", MEMBER),
    ("Bundle", BUNDLE),
    ("Sweep", "- **Sweep**: One pass over the open findings.\n  It runs on demand,\n"
              "  and on a schedule.\n"),
    ("Inline", "**Inline**: A definition on the start line.\n"),
    ("Starred", "* **Starred**: A definition after a star bullet.\n"
                "1. **Numbered**: never an entry.\nPlain: never an entry.\n"),
])
def test_show_prints_bulleted_and_inline_entries_as_written(root, capsys, term, entry):
    write_glossary(root, SHAPES)

    assert orch_glossary(root, "show", term) == 0
    assert capsys.readouterr() == (entry, "")


def test_an_indented_avoided_alias_resolves_to_its_bullet_entry(root, capsys):
    write_glossary(root, SHAPES)

    assert orch_glossary(root, "show", "group") == 0
    assert capsys.readouterr() == (BUNDLE, "# alias of Bundle\n")


def test_show_prints_bytes_that_are_not_utf8_back_as_written(root, monkeypatch):
    (root / "GLOSSARY.md").write_bytes(b"**Caf\xe9**:\nNot UTF-8: \xff.\n")
    out = io.TextIOWrapper(io.BytesIO(), encoding="utf-8")
    monkeypatch.setattr(sys, "stdout", out)

    assert orch_glossary(root, "show", "caf\udce9") == 0
    out.flush()
    assert out.buffer.getvalue() == b"**Caf\xe9**:\nNot UTF-8: \xff.\n"


# --- glossary match -----------------------------------------------------------


def test_match_with_no_glossary_prints_nothing(root, capsys, tmp_path):
    assert orch_glossary(root, "match", text_file(tmp_path, "t.md", "A flow.\n")) == 0
    assert capsys.readouterr() == ("", "")


@pytest.mark.parametrize("text, entry", [
    ("Two flows ran.", FLOW),
    ("the FLOW's branch", FLOW),
    ("open a side\n   checkout here", SIDE),
    ("a sibling worktree", SIDE),
    ("look around", ""),
    ("the next iteration", ""),
    ("a second checkout", ""),
    ("Nothing to see here.", ""),
])
def test_match_prints_the_entries_a_file_mentions(root, capsys, tmp_path, text, entry):
    write_glossary(root, FIXTURE)

    assert orch_glossary(root, "match", text_file(tmp_path, "t.md", text + "\n")) == 0
    assert capsys.readouterr() == (entry, "")


def test_match_over_several_files_prints_glossary_order_each_entry_once(root, capsys,
                                                                       tmp_path):
    write_glossary(root, FIXTURE)
    one = text_file(tmp_path, "one.md", "The budget of a flow.\n")
    two = text_file(tmp_path, "two.md", "Each round of a workflow, and every Flow.\n")

    assert orch_glossary(root, "match", one, two) == 0
    assert capsys.readouterr() == (FLOW + "\n" + ROUND + "\n" + BUDGET, "")


def test_match_finds_bullet_entries_by_term_and_unscoped_indented_alias(root, capsys,
                                                                       tmp_path):
    write_glossary(root, SHAPES)

    assert orch_glossary(root, "match", text_file(tmp_path, "t.md", "Each member of a group.\n")) == 0
    assert capsys.readouterr() == (MEMBER + "\n" + BUNDLE, "")


def test_match_reads_a_file_that_is_not_utf8(root, capsys, tmp_path):
    write_glossary(root, FIXTURE)
    (tmp_path / "t.md").write_bytes(b"\xff\xfe a flow \xe9\n")

    assert orch_glossary(root, "match", str(tmp_path / "t.md")) == 0
    assert capsys.readouterr() == (FLOW, "")


@pytest.mark.parametrize("glossary_text", [None, FIXTURE, "prose only\n", ""])
def test_a_missing_match_file_is_an_error_whatever_the_glossary(root, capsys, tmp_path,
                                                               glossary_text):
    if glossary_text is not None:
        write_glossary(root, glossary_text)
    there = text_file(tmp_path, "t.md", "A flow.\n")
    missing = str(tmp_path / "nonesuch.md")

    assert orch_glossary(root, "match", there, missing) == 2
    assert capsys.readouterr() == ("", "orch: no such file '%s'\n" % missing)


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads any file")
def test_an_unreadable_match_file_is_an_error(root, capsys, tmp_path):
    write_glossary(root, FIXTURE)
    path = text_file(tmp_path, "t.md", "A flow.\n")
    os.chmod(path, 0)

    assert orch_glossary(root, "match", path) == 2
    assert capsys.readouterr() == ("", "orch: no such file '%s'\n" % path)


def test_match_with_no_file_is_an_error(root, capsys):
    assert orch_glossary(root, "match") == 2
    assert capsys.readouterr() == ("", "orch: usage: orch.sh glossary match <file>...\n")


# --- a glossary that gives no entries -----------------------------------------


PROSE = "# Glossary\n\nTerms used here.\n\n## Flow\n\nTerm: not bold.\n"


@pytest.mark.parametrize("glossary_text", [PROSE, ""], ids=["prose", "empty"])
@pytest.mark.parametrize("op", ["terms", "show", "match"])
def test_every_op_on_a_glossary_with_no_entries_is_an_error(root, capsys, tmp_path,
                                                           glossary_text, op):
    write_glossary(root, glossary_text)
    args = {"terms": [], "show": ["Flow"],
            "match": [text_file(tmp_path, "t.md", "A member of a flow.\n")]}[op]

    assert orch_glossary(root, op, *args) == 2
    assert capsys.readouterr() == ("", NO_ENTRIES)


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads any file")
@pytest.mark.parametrize("op", ["terms", "show", "match"])
def test_a_glossary_that_cannot_be_opened_gives_no_entries(root, capsys, tmp_path, op):
    write_glossary(root, FIXTURE)
    os.chmod(root / "GLOSSARY.md", 0)
    args = {"terms": [], "show": ["Flow"],
            "match": [text_file(tmp_path, "t.md", "A flow.\n")]}[op]

    assert orch_glossary(root, op, *args) == 2
    assert capsys.readouterr() == ("", NO_ENTRIES)


# --- show_file ----------------------------------------------------------------


def test_show_file_reads_an_entry_outside_any_git_repo(tmp_path, monkeypatch):
    directory = tmp_path / "fixture"
    directory.mkdir()
    (directory / "GLOSSARY.md").write_text(FIXTURE, encoding="utf-8")
    monkeypatch.chdir(directory)
    monkeypatch.setenv("GIT_CEILING_DIRECTORIES", str(tmp_path))

    assert glossary.show_file(str(directory / "GLOSSARY.md"), "Side checkout") == SIDE
    assert glossary.show_file("GLOSSARY.md", "workflow") == FLOW
    assert glossary.show_file("GLOSSARY.md", "Nonesuch") == ""
    assert glossary.show_file(str(directory / "nonesuch.md"), "Flow") == ""
