"""The open-issue read beside the gh adapter's state reads: one read of an
issue's labels, and its body when asked, refusing one that is not open -
messages as the bash open_issue_read words them."""
from __future__ import annotations

import pytest

from orch.gh import open_issue_read
from orch.gh_fake import FakeGh

from conftest import GH_502

NOT_OPEN = "issue #5 is not open - finding triage takes open filed findings only"


def fake(seed):
    return FakeGh(seed.store, {}, sleep=lambda _: None)


def died(capsys, run):
    with pytest.raises(SystemExit) as death:
        run()
    return death.value.code, capsys.readouterr()


def test_an_open_issue_answers_its_labels_and_its_body_when_asked(seed):
    seed.issue(5, "open", "review:nit", "needs-triage")
    seed.body(5, "The finding.\n\n")
    gh = fake(seed)

    assert open_issue_read(gh, "5", NOT_OPEN) == (["review:nit", "needs-triage"], "")
    assert open_issue_read(gh, "5", NOT_OPEN, body=True) == (
        ["review:nit", "needs-triage"], "The finding.")


def test_an_issue_that_is_not_open_dies_with_the_message_given(seed, capsys):
    seed.issue(5, "closed", "review:nit")

    assert died(capsys, lambda: open_issue_read(fake(seed), "5", NOT_OPEN, body=True)) == (
        1, ("", "orch: " + NOT_OPEN + "\n"))


@pytest.mark.parametrize("body, operation", [
    (False, "adapter_issue_state_labels"), (True, "adapter_issue_state_labels_body"),
])
def test_a_failed_read_dies_naming_the_issue_as_given_and_the_hint(seed, capsys, body, operation):
    seed.issue(47, "open")
    seed.fail(operation, GH_502)

    assert died(capsys, lambda: open_issue_read(fake(seed), "047", NOT_OPEN, body=body,
                                                hint="no member was touched")) == (
        1, ("", "orch: gh could not read issue #047: HTTP 502: Bad Gateway"
                " - no member was touched\n"))


def test_a_failed_read_with_no_hint_dies_with_gh_s_reason_alone(seed, capsys):
    seed.fail("adapter_issue_state_labels", GH_502)

    assert died(capsys, lambda: open_issue_read(fake(seed), "5", NOT_OPEN)) == (
        1, ("", "orch: gh could not read issue #5: HTTP 502: Bad Gateway\n"))
