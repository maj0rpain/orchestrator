"""The slug noun run in-process: `slug <text>` prints the text's normalized
slug - ASCII letters lowercased, every run of anything but a-z and 0-9 one
hyphen, hyphens trimmed - and dies with the bash noun's usage line given no
text, and with its message when nothing survives, each checked by stdout, exit
code and `orch:` message as the bash slug noun answered them."""
from __future__ import annotations

import pytest

from conftest import died_of
from orch import slug


@pytest.mark.parametrize("text, expected", [
    ("My Feature!!", "my-feature"),
    ("--Fix_the BUG 42--", "fix-the-bug-42"),
    # Bash's tr and sed knew no letter past ASCII: each is a separator.
    ("Café Ünïcode", "caf-n-code"),
    # Bash's sed read the text a line at a time, so a newline stays.
    ("two\nLines here\n", "two\nlines-here"),
], ids=["punctuation", "underscores-and-digits", "non-ascii", "two-lines"])
def test_slug_prints_the_normalized_slug(capsys, text, expected):
    assert slug.run([text]) == 0
    assert capsys.readouterr() == (expected + "\n", "")


def test_slug_refuses_a_text_with_nothing_left_after_normalisation(capsys):
    assert died_of(capsys, lambda: slug.run(["!!!"])) == (
        1, "", "orch: slug is empty after normalisation\n")


@pytest.mark.parametrize("argv", [[], [""]], ids=["no-text", "empty-text"])
def test_slug_with_no_text_dies_with_the_usage_line(capsys, argv):
    assert died_of(capsys, lambda: slug.run(argv)) == (1, "", "orch: usage: orch.sh slug <text>\n")
