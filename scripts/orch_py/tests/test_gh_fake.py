"""The gh adapter's fake on the shared file store: a store seeded by the bash
suite's own helpers reads the same through the Python fake, what the Python
fake writes reads back through the bash helpers, and the store's failure
files inject failures under the bash adapter's operation names."""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

from orch.gh import Gh, GhFailed, IssueRow, adapter
from orch.gh_fake import FakeGh, FakeStore
from orch.git import FakeGit
from orch.repo import RepoPin

SCRIPTS = Path(__file__).resolve().parents[2]
BASH_FAKE = SCRIPTS / "test" / "gh_adapter_fake.sh"
# The bash suite's store helpers, by the file that defines each.
BASH_HELPERS = {
    SCRIPTS / "test" / "orch" / "setup.sh": [
        "fake_issue", "fake_issue_authorship", "fake_issue_relabel", "fake_issue_title",
        "fake_issue_body",
        "fake_comment_seed", "fake_comment", "fake_comment_bodies", "fake_label",
        "fake_next_issue", "fake_fail", "fake_fail_after", "fake_fail_times",
        "fake_unfail", "fake_offline", "fake_online", "fake_quota", "fake_lag",
        "fake_state_of", "fake_reason_of", "fake_duplicate_of",
        "fake_title_of", "fake_body_of", "fake_labels_of", "fake_comments_of",
    ],
    SCRIPTS / "test" / "orch" / "gh.sh": ["fake_ratelimit"],
    SCRIPTS / "test" / "orch" / "ticket.sh": ["fake_lag_after"],
}
SECONDARY = "You have exceeded a secondary rate limit."
NOW = 1_900_000_000


def bash_definitions(path, names):
    """The definitions of the named functions in the bash file at <path>: a
    one-line `name() { ...; }`, or the lines from `name() {` to the first
    line that is `}`."""
    lines = path.read_text().split("\n")
    found = {}
    for i, line in enumerate(lines):
        match = re.match(r"^([a-z_]+)\(\) *\{", line)
        if not match or match.group(1) not in names:
            continue
        if line.rstrip().endswith("}") and line.count("{") == line.count("}"):
            found[match.group(1)] = line
            continue
        end = lines.index("}", i)
        found[match.group(1)] = "\n".join(lines[i:end + 1])
    missing = set(names) - set(found)
    assert not missing, "no definition of %s in %s" % (sorted(missing), path)
    return "\n".join(found[name] for name in names)


HELPERS = "\n".join(bash_definitions(path, names) for path, names in BASH_HELPERS.items())


def bash(store, script):
    """<script> run by bash with the bash suite's store helpers and the bash
    fake's own operations defined, on <store>; its stdout."""
    run = subprocess.run(
        ["bash", "-c", 'source "$1"\n' + HELPERS + "\n" + script, "_", str(BASH_FAKE)],
        env={"PATH": "/usr/local/bin:/usr/bin:/bin", "ORCH_GH_FAKE_STORE": str(store),
             "GH_ADAPTER_FAKE": str(BASH_FAKE)},
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    assert run.returncode == 0, run.stderr.decode()
    return run.stdout.decode()


@pytest.fixture
def store(tmp_path):
    path = tmp_path / "store"
    path.mkdir()
    return path


def fake(store, sleeps=None, **env):
    slept = sleeps if sleeps is not None else []
    return FakeGh(str(store), env, sleep=slept.append, now=lambda: NOW)


# --- reads of a store the bash helpers seeded ---------------------------------


def test_an_issue_seeded_by_the_bash_helpers_reads_the_same(store):
    bash(store, r"""
fake_issue 5 open bug ready-for-agent
fake_issue_title 5 'A title'
fake_issue_body 5 $'line one\r\nline two\n'
fake_comment 5 ann 2026-02-01T00:00:00Z 'First.'
fake_comment 5 bob 2026-02-02T00:00:00Z $'Second\n' NONE
fake_issue 6 closed
""")
    gh = fake(store)

    assert gh.issue_body(5) == "line one\r\nline two\n"
    assert gh.issue_json(5) == {"number": 5, "title": "A title",
                                "body": "line one\r\nline two\n",
                                "labels": ["bug", "ready-for-agent"]}
    assert gh.issue_comments(5) == [
        {"author": {"login": "ann"}, "authorAssociation": "OWNER",
         "createdAt": "2026-02-01T00:00:00Z", "body": "First.",
         "url": "https://github.com/o/r/issues/5#issuecomment-1"},
        {"author": {"login": "bob"}, "authorAssociation": "NONE",
         "createdAt": "2026-02-02T00:00:00Z", "body": "Second\n",
         "url": "https://github.com/o/r/issues/5#issuecomment-2"},
    ]
    assert gh.issue_state_labels(5) == ("OPEN", ["bug", "ready-for-agent"])
    assert gh.issue_state_labels_body(5) == ("OPEN", ["bug", "ready-for-agent"],
                                             "line one\r\nline two")
    assert gh.issue_title_labels(5) == ("A title", ["bug", "ready-for-agent"])
    assert gh.issue_state_labels(6) == ("CLOSED", [])
    assert gh.issue_json(6) == {"number": 6, "title": "", "body": "", "labels": []}
    assert gh.issue_comments(6) == []


def test_a_number_the_store_does_not_hold_fails_as_gh_does(store):
    with pytest.raises(GhFailed) as failed:
        fake(store).issue_title_labels(9)

    assert failed.value.stderr == (
        "GraphQL: Could not resolve to an issue or pull request with the number"
        " of 9. (repository.issue)\n"
    )


def test_the_titled_listing_is_the_open_issues_carrying_the_label_oldest_first(store, capsys):
    bash(store, r"""
fake_issue 7 open Ready-For-Agent; fake_issue_title 7 'Seventh'
fake_issue 3 open ready-for-agent wip; fake_issue_title 3 'Third'
fake_issue 4 closed ready-for-agent
fake_issue 8 open bug
fake_issue 9 open ready-for-agent; : >"$ORCH_GH_FAKE_STORE/issues/9/pull"
""")

    assert fake(store).issues_titled_rows("ready-for-agent") == [
        IssueRow(3, "OPEN", "Third", ["ready-for-agent", "wip"]),
        IssueRow(7, "OPEN", "Seventh", ["Ready-For-Agent"]),
    ]
    assert capsys.readouterr().err == ""


def test_the_titled_listing_is_cut_at_the_issue_list_limit_with_a_warning(store, capsys):
    bash(store, "for n in 1 2 3; do fake_issue $n open ready; done")

    rows = fake(store, ORCH_ISSUE_LIST_LIMIT="2").issues_titled_rows("ready")

    assert [row.number for row in rows] == [1, 2]
    assert "reached the issue-list limit of 2" in capsys.readouterr().err


def test_sub_issues_and_blockers_linked_by_the_bash_fake_read_the_same(store):
    bash(store, r"""
for n in 10 11 12 13 14; do fake_issue $n open; done
fake_issue 13 closed
adapter_sub_issue_link 10 11
adapter_blocker_add 12 13
adapter_blocker_add 12 14
printf '%s\n' 11 >>"$ORCH_GH_FAKE_STORE/no_dependency_summary"
""")
    gh = fake(store)

    assert (gh.issue_parent(11), gh.issue_parent(12)) == (10, None)
    assert (gh.issue_open_blockers(12), gh.issue_open_blockers(11)) == (1, None)
    assert gh.blockers_states(12) == [(13, "CLOSED"), (14, "OPEN")]
    assert gh.blockers_states(11) == []


def test_authorship_seeded_by_the_bash_helpers_reads_as_the_bash_fake_answers(store):
    answers = bash(store, r"""
fake_issue 5 open
fake_issue_authorship 5 ann NONE bob
fake_issue 6 open
adapter_issue_authorship 5
adapter_issue_authorship 6
""")
    gh = fake(store)

    assert answers == "ann\nNONE\nbob\n\nfake-gh\nOWNER\n\n\n"
    assert (gh.issue_authorship(5), gh.issue_authorship(6)) == (
        ("ann", "NONE", "bob", ""), ("fake-gh", "OWNER", "", "")
    )


def test_python_seeded_sub_issues_blockers_and_authorship_read_back_through_the_bash_fake(store):
    py = FakeStore(str(store))
    for n in (10, 11, 12, 13):
        py.issue(n, "open")
    py.sub_issue(10, 11)
    py.blocked_by(12, 13)
    py.no_dependency_summary(11)
    py.authorship(12, "ann", "NONE", "", "cid")

    assert bash(store, r"""
adapter_issue_parent 11
adapter_issue_open_blockers 12
adapter_issue_open_blockers 11
adapter_blockers_states 12
adapter_issue_authorship 12
""") == "10\n1\n13\tOPEN\nann\nNONE\n\ncid\n"


# --- writes the bash helpers read back ---------------------------------------


def test_python_writes_read_back_through_the_bash_helpers(store, tmp_path):
    bash(store, r"""
fake_issue 5 open wip needs-triage
fake_issue 6 open
fake_issue 7 closed
fake_label Ready-For-Agent 0e8a16 ''
fake_next_issue 40
""")
    body = tmp_path / "body.md"
    body.write_bytes(b"New body\r\n")
    note = tmp_path / "note.md"
    note.write_text("A note.")
    gh = fake(store)

    created = gh.issue_create("New issue", str(body), ["ready-for-agent", "bug"])
    gh.issue_body_edit(5, str(body))
    gh.issue_comment(5, str(note))
    gh.issue_relabel(5, add=["ready-for-agent"], remove=["WIP", "needs-triage"])
    gh.issue_close(6, comment="Dup.", duplicate_of=5)
    gh.issue_close(5, reason="completed", comment="Done.")
    gh.issue_close(7, reason="completed", comment="Never posted.")

    assert created == 40
    assert bash(store, r"""
for n in 40 5 6 7; do
  printf '%s|%s|%s|%s|%s|' "$(fake_state_of $n)" "$(fake_title_of $n)" "$(fake_labels_of $n)" \
    "$(fake_reason_of $n)" "$(fake_duplicate_of $n)"
  printf '%s|%s\n' "$(fake_body_of $n | od -An -c | tr -s ' ')" "$(fake_comments_of $n | tr '\n' '/')"
done
fake_next_issue_after=$(cat "$ORCH_GH_FAKE_STORE/next_issue"); echo "next $fake_next_issue_after"
""") == (
        "OPEN|New issue|Ready-For-Agent bug |||"
        " N e w b o d y \\r \\n|\n"
        "CLOSED||Ready-For-Agent |completed|| N e w b o d y \\r \\n|A note.//Done.\n"
        "CLOSED|||duplicate|5||Dup.\n"
        "CLOSED||||||\n"
        "next 41\n"
    )


def test_a_new_issue_with_no_next_number_seeded_takes_one_past_the_highest(store, tmp_path):
    bash(store, "fake_issue 12 open; mkdir -p \"$ORCH_GH_FAKE_STORE/prs/30\"")
    body = tmp_path / "body.md"
    body.write_text("")

    assert fake(store).issue_create("T", str(body), []) == 31


# --- failure files, under the bash adapter's operation names -----------------


def test_fail_files_seeded_by_the_bash_helpers_fail_the_named_operation(store):
    bash(store, r"""
fake_issue 5 open
fake_fail adapter_issue_body $'HTTP 502: Bad Gateway\nsecond line'
fake_fail adapter_issue_comment
""")
    gh = fake(store)

    with pytest.raises(GhFailed) as body:
        gh.issue_body(5)
    with pytest.raises(GhFailed) as comment:
        gh.issue_comment(5, "/dev/null")

    assert body.value.stderr == "HTTP 502: Bad Gateway\nsecond line\n"
    assert comment.value.stderr == "fake gh: adapter_issue_comment failed\n"
    assert gh.issue_state_labels(5) == ("OPEN", [])


def test_a_fail_after_countdown_lets_the_first_calls_through(store):
    bash(store, "fake_issue 5 open; fake_fail_after adapter_issue_state_labels 2 boom")
    gh = fake(store)

    answers = [gh.issue_state_labels(5), gh.issue_state_labels(5)]
    with pytest.raises(GhFailed):
        gh.issue_state_labels(5)

    assert answers == [("OPEN", []), ("OPEN", [])]


def test_a_fail_times_countdown_is_a_failure_that_lifts_itself(store):
    bash(store, "fake_issue 5 open; fake_fail_times adapter_issue_parent 2 'HTTP 502'")
    gh = fake(store)

    failures = []
    for _ in range(2):
        with pytest.raises(GhFailed) as failed:
            gh.issue_parent(5)
        failures.append(failed.value.stderr)

    assert failures == ["HTTP 502", "HTTP 502"]
    assert gh.issue_parent(5) is None
    assert not (store / "fail" / "adapter_issue_parent").exists()


def test_offline_fails_every_operation_with_a_connection_error(store):
    bash(store, "fake_issue 5 open; fake_offline")

    with pytest.raises(GhFailed) as failed:
        fake(store).issue_open_blockers(5)

    assert failed.value.stderr == "dial tcp: lookup api.github.com: no such host\n"


def test_a_rate_limit_flag_fails_through_the_limit_handler_with_the_seeded_quota(store):
    bash(store, r"""
fake_issue 5 open
fake_quota core 0 5000 2000000000
fake_quota graphql 7 5000 2100000000
fake_ratelimit
""")

    with pytest.raises(GhFailed) as failed:
        fake(store).issue_body(5)

    assert failed.value.stderr.startswith(
        "orch: GitHub API rate limit reached - it resets at 2033-05-18T03:33:20Z.")


def test_a_secondary_limit_flag_is_waited_out_once_then_given_up_on(store):
    bash(store, "fake_issue 5 open; fake_ratelimit '%s'" % SECONDARY)
    sleeps = []

    with pytest.raises(GhFailed) as failed:
        fake(store, sleeps, ORCH_GH_LIMIT_WAIT="1").issue_body(5)

    assert sleeps == [1.0]
    assert "secondary rate limit" not in failed.value.stderr
    assert failed.value.stderr.startswith("orch: GitHub API rate limit reached")


def test_a_failing_quota_read_leaves_the_reset_15_minutes_on(store):
    bash(store, r"""
fake_issue 5 open
fake_ratelimit 'was submitted too quickly'
fake_fail_times adapter_rate_limit 1 'HTTP 502: Bad Gateway'
""")

    with pytest.raises(GhFailed) as failed:
        fake(store).issue_body(5)

    assert "resets at 2030-03-17T18:01:40Z." in failed.value.stderr


def test_a_secondary_limit_the_retry_clears_answers(store):
    bash(store, "fake_issue 5 open; fake_issue_body 5 Body.; "
                "fake_fail_times adapter_issue_body 1 '%s'" % SECONDARY)

    assert fake(store).issue_body(5) == "Body."


def test_a_close_with_a_comment_gives_up_at_a_first_secondary_limit(store):
    bash(store, "fake_issue 5 open; fake_fail_times adapter_issue_close 1 '%s'" % SECONDARY)
    gh = fake(store)

    with pytest.raises(GhFailed):
        gh.issue_close(5, reason="completed", comment="done")
    state = bash(store, "fake_state_of 5")
    bash(store, "fake_fail_times adapter_issue_close 1 '%s'" % SECONDARY)
    gh.issue_close(5, reason="completed")

    assert state == "OPEN\n"
    assert bash(store, "fake_state_of 5") == "CLOSED\n"


def test_a_relabel_naming_nothing_cannot_fail(store):
    bash(store, "fake_issue 5 open; fake_fail adapter_issue_relabel")

    assert fake(store).issue_relabel(5) is None


def test_a_lagging_read_answers_stale_for_the_calls_seeded(store):
    bash(store, r"""
fake_issue 5 open ready; fake_issue_title 5 Current
fake_lag_after adapter_issue_title_labels 1 1 $'Stale\nold-label'
""")
    gh = fake(store)

    assert [gh.issue_title_labels(5) for _ in range(3)] == [
        ("Current", ["ready"]), ("Stale", ["old-label"]), ("Current", ["ready"])]


def test_each_comment_list_read_is_logged(store):
    bash(store, "fake_issue 5 open; fake_fail adapter_issue_comments")
    gh = fake(store)

    for _ in range(2):
        with pytest.raises(GhFailed):
            gh.issue_comments(5)

    assert (store / "comment_reads").read_text() == "x\nx\n"


# --- the Python seeders write the bash layout ---------------------------------


def test_a_store_seeded_by_the_python_seeders_reads_back_through_the_bash_helpers(store):
    seed = FakeStore(str(store))
    seed.issue(5, "open", "bug", "ready-for-agent")
    seed.title(5, "A title")
    seed.body(5, "Body\r\n")
    seed.comment(5, "ann", "2026-02-01T00:00:00Z", "Hi.", "NONE")
    seed.issue(6, "closed")
    seed.next_issue(30)

    assert bash(store, r"""
printf '%s|%s|%s|%s|' "$(fake_state_of 5)" "$(fake_title_of 5)" "$(fake_labels_of 5)" "$(fake_comments_of 5)"
printf '%s|%s|' "$(fake_body_of 5 | od -An -c | tr -s ' ')" "$(fake_state_of 6)"
adapter_issue_comments 5 | jq -c '.comments[0] | [.author.login, .authorAssociation, .createdAt]'
cat "$ORCH_GH_FAKE_STORE/next_issue"
""") == ('OPEN|A title|bug ready-for-agent |Hi.| B o d y \\r \\n|CLOSED|'
         '["ann","NONE","2026-02-01T00:00:00Z"]\n30\n')


def test_the_python_seeders_set_failures_the_bash_fake_honours(store):
    seed = FakeStore(str(store))
    seed.issue(5, "open")
    seed.fail("adapter_issue_body", "HTTP 502")
    seed.fail_times("adapter_issue_state_labels", 1, "transient")

    assert bash(store, r"""
adapter_issue_body 5 2>&1 >/dev/null; echo "body $?"
adapter_issue_state_labels 5 2>&1; echo "first $?"
adapter_issue_state_labels 5; echo "second $?"
""") == "HTTP 502\nbody 1\ntransientfirst 1\nOPEN\nsecond 0\n"

    seed.unfail()
    seed.offline()
    with pytest.raises(GhFailed):
        fake(store).issue_body(5)
    seed.online()
    assert fake(store).issue_body(5) == ""


# --- the factory and the pin ---------------------------------------------------


def test_the_fake_is_the_adapter_whenever_a_store_is_set(store, tmp_path):
    assert isinstance(adapter({"ORCH_GH_FAKE_STORE": str(store)}, cwd=str(tmp_path)), FakeGh)
    assert isinstance(adapter({"ORCH_GH_FAKE_STORE": ""}, cwd=str(tmp_path)), Gh)
    assert isinstance(adapter({}, cwd=str(tmp_path)), Gh)


def test_the_fake_pins_as_the_repo_pin_it_is_given(store):
    with_origin = RepoPin({}, FakeGit({"origin": "https://github.com/o/r.git"}))
    without = RepoPin({}, FakeGit())

    assert FakeGh(str(store), {}, pin=with_origin).pin() is True
    assert FakeGh(str(store), {}, pin=without).pin() is False
    assert FakeGh(str(store), {}).pin() is True
