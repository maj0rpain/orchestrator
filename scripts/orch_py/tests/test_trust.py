"""The Trust module's comment filter, by the comment's author association:
the cases the bash trust section asserts through `pr comments`, pinned on
the Python filter itself - which associations it keeps, which it drops, a
lower-case and an empty association among them, and its one message."""
from __future__ import annotations

import pytest

from orch import trust

TRUSTED = ("OWNER", "MEMBER", "COLLABORATOR")
UNTRUSTED = ("CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR", "FIRST_TIMER", "MANNEQUIN", "NONE",
             "owner", "")


def written_by(association):
    """A comment whose author association is <association>."""
    return {"author": "someone", "createdAt": "2026-09-01T10:00:00Z",
            "body": "written by %s" % (association or "empty"),
            "authorAssociation": association}


@pytest.mark.parametrize("association", TRUSTED)
def test_a_trusted_association_s_comment_is_kept(association):
    assert trust.filter_comments("9", [written_by(association)]) == [written_by(association)]


@pytest.mark.parametrize("association", UNTRUSTED, ids=[a or "empty" for a in UNTRUSTED])
def test_any_other_association_s_comment_is_dropped(association, capsys):
    assert trust.filter_comments("9", [written_by(association)]) == []


def test_the_dropped_ones_are_reported_once_naming_the_issue_as_given(capsys):
    every = [written_by(a) for a in TRUSTED + UNTRUSTED]

    trust.filter_comments("09", every)

    assert capsys.readouterr() == (
        "", "orch: ignored 7 comment(s) from untrusted authors on #09\n")
