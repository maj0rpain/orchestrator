"""The branch concept module: the branch keys the busy checkout's branch
signal reads, through FakeGit's config answers, as bash's branch.sh reads
them from git config."""
from __future__ import annotations

import pytest

from orch.branch import branch_is_retired, branch_pr_get, branch_records_base
from orch.git import FakeGit

B = "orch/12-foo"


def configured(**keys):
    """A FakeGit whose git config holds <keys>, each a key of branch B's
    named by its orchestrator- suffix, - for _."""
    git = FakeGit()
    for suffix, value in keys.items():
        git.seed("config_value", "branch.%s.orchestrator-%s" % (B, suffix.replace("_", "-")),
                 answer=value)
    return git


def test_a_branch_s_recorded_pr_is_its_pr():
    assert branch_pr_get(configured(pr="41"), B) == "41"


def test_a_branch_recording_no_pr_has_none():
    assert branch_pr_get(configured(), B) is None


@pytest.mark.parametrize("value, retired", [("true", True), ("false", False), (None, False)],
                         ids=["true", "false", "unset"])
def test_a_branch_is_retired_only_when_its_retired_key_is_true(value, retired):
    assert branch_is_retired(configured(retired=value), B) is retired


@pytest.mark.parametrize("keys, records", [
    ({"base": "main"}, True),
    ({}, False),
    ({"base": "main", "ticket_parent": "orch/12-foo"}, False),
    ({"ticket_parent": "orch/12-foo"}, False),
], ids=["flow-or-quick", "foreign", "ticket-with-base", "ticket"])
def test_only_a_flow_or_quick_branch_records_a_base(keys, records):
    assert branch_records_base(configured(**keys), B) is records
