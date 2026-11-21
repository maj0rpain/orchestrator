"""The Comments module's trusted reader, as finding triage reads it: its
deaths with a hint, and the form that hands the failure's reason back
instead of dying - messages as the bash comments.sh words them."""
from __future__ import annotations

import pytest

from orch import comments
from orch.gh_fake import FakeGh

from conftest import GH_502

WHAT = "read issue #66's comments"
TRUSTED = {"author": "ann", "createdAt": "2026-02-01T00:00:00Z", "body": "Bundled into #63",
           "url": "https://github.com/o/r/issues/66#issuecomment-1"}


def fake(seed):
    return FakeGh(seed.store, {}, sleep=lambda _: None)


def seeded(seed):
    seed.issue(66, "closed")
    seed.comment(66, "ann", "2026-02-01T00:00:00Z", "Bundled into #63")
    seed.comment(66, "eve", "2026-02-02T00:00:00Z", "Bundled into #99", "NONE")


def died(capsys, run):
    with pytest.raises(SystemExit) as death:
        run()
    return death.value.code, capsys.readouterr().err


def test_a_failed_read_dies_with_the_hint_after_gh_s_reason(seed, capsys):
    seeded(seed)
    seed.fail("adapter_issue_comments", GH_502)

    assert died(capsys, lambda: comments.trusted(fake(seed), WHAT, "66",
                                                 hint="no member was touched")) == (
        1, "orch: gh could not read issue #66's comments: HTTP 502: Bad Gateway"
           " - no member was touched\n")


def test_an_answer_that_does_not_parse_dies_without_the_hint(seed, capsys):
    seeded(seed)
    seed.lag("adapter_issue_comments", 1, '{"comments": [1]}')

    assert died(capsys, lambda: comments.trusted(fake(seed), WHAT, "66",
                                                 hint="no member was touched")) == (
        1, "orch: could not read issue #66's comments: its comments did not parse\n")


def test_the_non_dying_read_answers_the_trusted_comments(seed, capsys):
    seeded(seed)

    assert comments.trusted_read(fake(seed), "066") == ([TRUSTED], "")
    assert capsys.readouterr().err == (
        "orch: ignored 1 comment(s) from untrusted authors on #066\n")


def test_the_non_dying_read_hands_back_gh_s_reason_on_a_failed_read(seed, capsys):
    seeded(seed)
    seed.fail("adapter_issue_comments", GH_502)

    assert comments.trusted_read(fake(seed), "66") == (None, "HTTP 502: Bad Gateway")
    assert capsys.readouterr() == ("", "")


@pytest.mark.parametrize("answer", ['{"comments": "not a list"}', '{"comments": [1]}'])
def test_the_non_dying_read_hands_back_no_reason_on_an_answer_that_does_not_parse(seed, answer):
    seeded(seed)
    seed.lag("adapter_issue_comments", 1, answer)

    assert comments.trusted_read(fake(seed), "66") == (None, "")
