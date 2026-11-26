"""The gh adapter's fake on the shared file store: a store seeded by the bash
suite's own helpers reads the same through the Python fake, what the Python
fake writes reads back through the bash helpers, and the store's failure
files inject failures under the bash adapter's operation names."""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

import pytest

from orch.gh import Check, Gh, GhFailed, IssueRow, LabelledBody, SubIssue, adapter
from orch.gh_fake import FakeGh, FakeStore
from orch.git import FakeGit
from orch.repo import RepoPin

SCRIPTS = Path(__file__).resolve().parents[2]
BASH_FAKE = SCRIPTS / "test" / "gh_adapter_fake.sh"
# The bash suite's store helpers, by the file that defines each.
BASH_HELPERS = {
    SCRIPTS / "test" / "orch" / "setup.sh": [
        "fake_issue", "fake_issue_authorship", "fake_issue_relabel", "fake_issue_title",
        "fake_comment_seed", "fake_comment", "fake_comment_bodies", "fake_label",
        "fake_fail", "fake_fail_after", "fake_fail_times",
        "fake_unfail", "fake_offline", "fake_online", "fake_quota", "fake_lag",
        "fake_state_of", "fake_labels_of", "fake_comments_of",
        "fake_pr", "fake_pr_comment", "fake_pr_cross", "fake_labels",
        "fake_default_branch", "fake_claim_seed", "fake_claim_held",
        "fake_pr_draft", "fake_pr_head", "fake_pr_merged", "fake_issue_created", "iso_of",
        "iso_ago", "fake_next_pr", "fake_checks", "fake_pr_base_of", "fake_pr_body_of",
        "fake_pr_draft_of",
    ],
    SCRIPTS / "test" / "orch" / "gh.sh": ["fake_ratelimit", "fake_duplicate_of",
                                          "fake_issue_body", "fake_pr_comments_of"],
    SCRIPTS / "test" / "orch" / "autopilot.sh": ["fake_reason_of"],
    SCRIPTS / "test" / "orch" / "review.sh": ["fake_title_of", "fake_body_of",
                                              "fake_next_issue"],
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


def test_a_bash_seeded_store_s_sub_issues_and_blockers_read_as_the_bash_fake_answers(store):
    bash_answer = bash(store, r"""
for n in 10 11 12 13 14 15; do fake_issue $n open; done
fake_issue 13 closed
adapter_sub_issue_link 10 12
adapter_sub_issue_link 10 11
adapter_sub_issue_link 10 13
adapter_blocker_add 11 14
adapter_blocker_add 11 13
adapter_blocker_add 11 15
adapter_sub_issues 10
echo --
adapter_sub_issues 14
echo --
adapter_blockers 11
echo --
adapter_blockers 12
""")
    gh = fake(store)

    assert bash_answer == "12\tOPEN\t0\n11\tOPEN\t2\n13\tCLOSED\t0\n--\n--\n14\n13\n15\n--\n"
    assert gh.sub_issues(10) == [SubIssue(12, "OPEN", 0), SubIssue(11, "OPEN", 2),
                                 SubIssue(13, "CLOSED", 0)]
    assert gh.sub_issues(14) == []
    assert (gh.blockers(11), gh.blockers(12)) == ([14, 13, 15], [])


def test_python_seeded_sub_issues_and_blockers_read_back_through_the_bash_fake(store):
    py = FakeStore(str(store))
    for n in (10, 11, 12):
        py.issue(n, "open")
    py.sub_issue(10, 11)
    py.sub_issue(10, 12)
    py.blocked_by(12, 11)

    assert bash(store, "adapter_sub_issues 10; adapter_blockers 12") == (
        "11\tOPEN\t0\n12\tOPEN\t1\n11\n")
    assert fake(store).sub_issues(10) == [SubIssue(11, "OPEN", 0), SubIssue(12, "OPEN", 1)]


def test_a_lagging_sub_issue_listing_answers_the_stale_listing(store):
    bash(store, r"""
for n in 10 11; do fake_issue $n open; done
adapter_sub_issue_link 10 11
fake_lag adapter_sub_issues 1 ''
""")
    gh = fake(store)

    assert gh.sub_issues(10) == []
    assert gh.sub_issues(10) == [SubIssue(11, "OPEN", 0)]


@pytest.mark.parametrize("call", [lambda gh: gh.sub_issues(99), lambda gh: gh.blockers(99)])
def test_a_sub_issue_or_blocker_read_of_an_issue_the_store_lacks_fails(store, call):
    with pytest.raises(GhFailed) as failed:
        call(fake(store))

    assert "Could not resolve to an issue or pull request with the number of 99" in (
        failed.value.stderr)


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


# --- the operations finding triage adds ---------------------------------------


def test_the_bodies_listing_reads_the_open_issues_carrying_every_label_from_a_bash_seeded_store(
        store, capsys):
    bash(store, r"""
fake_issue 7 open review:nit Needs-Triage; fake_issue_body 7 $'Seventh\r\nbody\n\n'
fake_issue 3 open REVIEW:NIT needs-triage wip
fake_issue 4 closed review:nit needs-triage
fake_issue 5 open review:nit
fake_issue 9 open review:nit needs-triage; : >"$ORCH_GH_FAKE_STORE/issues/9/pull"
""")

    answer = fake(store).issues_labelled_bodies("review:nit", "needs-triage")

    assert answer == [
        LabelledBody(3, ["REVIEW:NIT", "needs-triage", "wip"], ""),
        LabelledBody(7, ["review:nit", "Needs-Triage"], "Seventh\r\nbody"),
    ]
    assert capsys.readouterr().err == ""


def test_the_bodies_listing_is_cut_at_the_limit_warning_with_every_label(store, capsys):
    bash(store, "for n in 1 2 3; do fake_issue $n open review:major needs-triage; done")

    rows = fake(store, ORCH_ISSUE_LIST_LIMIT="2").issues_labelled_bodies(
        "review:major", "needs-triage")

    assert [row.number for row in rows] == [1, 2]
    assert capsys.readouterr().err == (
        "orch: the open issues labelled review:major and needs-triage reached the"
        " issue-list limit of 2 - the newest past it are missing from this list\n"
    )


def test_issue_state_answers_as_the_bash_fake_pull_for_a_pull_request(store):
    bash_answer = bash(store, r"""
fake_issue 5 open; fake_issue 6 closed
fake_issue 7 open; : >"$ORCH_GH_FAKE_STORE/issues/7/pull"
fake_pr 8 open
for n in 5 6 7 8; do adapter_issue_state $n; done
""")
    gh = fake(store)

    assert [gh.issue_state(n) for n in (5, 6, 7, 8)] == bash_answer.split() == [
        "OPEN", "CLOSED", "PULL", "PULL"]
    with pytest.raises(GhFailed) as failed:
        gh.issue_state(9)
    assert "Could not resolve to an issue or pull request with the number of 9" in failed.value.stderr


def test_label_create_adds_a_missing_label_and_fails_on_one_in_any_casing(store):
    bash(store, "fake_label Bug d73a4a 'Something is wrong'")
    gh = fake(store)

    gh.label_create("finding-bundle", "c5def5", "Several filed findings worked as one")
    with pytest.raises(GhFailed) as failed:
        gh.label_create("BUG", "000000", "x")

    assert failed.value.stderr == (
        'label with name "BUG" already exists; use `--force` to update its color'
        " and description\n"
    )
    assert bash(store, "fake_labels") == (
        "Bug\td73a4a\tSomething is wrong\n"
        "finding-bundle\tc5def5\tSeveral filed findings worked as one\n"
    )


def test_repo_default_branch_is_the_stored_answer_and_fails_with_none(store):
    gh = fake(store)
    with pytest.raises(GhFailed) as failed:
        gh.repo_default_branch("acme/gone")
    bash(store, "fake_default_branch $'trunk\\n'")

    assert failed.value.stderr == (
        "GraphQL: Could not resolve to a Repository with the name 'acme/gone'. (repository)\n")
    assert gh.repo_default_branch("acme/widgets") == "trunk"


@pytest.mark.parametrize("operation, call", [
    ("adapter_issues_labelled_bodies", lambda gh: gh.issues_labelled_bodies("review:nit")),
    ("adapter_issue_state", lambda gh: gh.issue_state(5)),
    ("adapter_label_create", lambda gh: gh.label_create("bug", "d73a4a", "d")),
    ("adapter_repo_default_branch", lambda gh: gh.repo_default_branch("acme/widgets")),
    ("adapter_issues_open_titles", lambda gh: gh.issues_open_titles()),
    ("adapter_prs_open", lambda gh: gh.prs_open("topic")),
    ("adapter_pr_body", lambda gh: gh.pr_body(6)),
    ("adapter_pr_comments", lambda gh: gh.pr_comments(6)),
    ("adapter_sub_issues", lambda gh: gh.sub_issues(5)),
    ("adapter_blockers", lambda gh: gh.blockers(5)),
    ("adapter_sub_issue_link", lambda gh: gh.sub_issue_link(5, 7)),
    ("adapter_sub_issue_unlink", lambda gh: gh.sub_issue_unlink(5, 7)),
    ("adapter_blocker_add", lambda gh: gh.blocker_add(5, 7)),
    ("adapter_blocker_remove", lambda gh: gh.blocker_remove(5, 7)),
    ("adapter_claim_delete", lambda gh: gh.claim_delete(5)),
    ("adapter_issue_reopen", lambda gh: gh.issue_reopen(5)),
    ("adapter_pr_close", lambda gh: gh.pr_close(6, "Closed.")),
    ("adapter_issue_created_at", lambda gh: gh.issue_created_at(5)),
    ("adapter_pr_create", lambda gh: gh.pr_create("main", "topic", "T", "/dev/null")),
    ("adapter_pr_labels", lambda gh: gh.pr_labels(6)),
    ("adapter_pr_refs", lambda gh: gh.pr_refs(6)),
    ("adapter_pr_state_draft", lambda gh: gh.pr_state_draft(6)),
    ("adapter_pr_ready", lambda gh: gh.pr_ready(6)),
    ("adapter_pr_draft", lambda gh: gh.pr_draft(6)),
    ("adapter_pr_comment", lambda gh: gh.pr_comment(6, "/dev/null")),
    ("adapter_pr_body_edit", lambda gh: gh.pr_body_edit(6, "/dev/null")),
    ("adapter_pr_title_edit", lambda gh: gh.pr_title_edit(6, "T")),
    ("adapter_pr_label_add", lambda gh: gh.pr_label_add(6, "bug")),
    ("adapter_pr_diff", lambda gh: gh.pr_diff(6)),
    ("adapter_pr_checks", lambda gh: gh.pr_checks(6, "all")),
    ("adapter_prs_open_bodies", lambda gh: gh.prs_open_bodies()),
    ("adapter_prs_merged_closing",
     lambda gh: gh.prs_merged_closing("main", "2026-01-01T00:00:00Z")),
    ("adapter_prs_merged_bodies", lambda gh: gh.prs_merged_bodies("main")),
])
def test_the_added_operations_fail_under_the_bash_operation_names(store, operation, call):
    bash(store, "fake_issue 5 open review:nit; fake_issue 7 open; fake_default_branch trunk; "
                "fake_pr 6 open topic main; "
                "fake_fail %s 'HTTP 502: Bad Gateway'" % operation)

    with pytest.raises(GhFailed) as failed:
        call(fake(store))

    assert failed.value.stderr == "HTTP 502: Bad Gateway\n"


# --- the claim delete -------------------------------------------------------------


def test_a_claim_the_bash_seeder_wrote_is_freed_by_the_python_fake(store):
    bash(store, "fake_claim_seed 5; fake_claim_seed 6")

    assert fake(store).claim_delete(5) is None
    assert bash(store, "fake_claim_held 5; fake_claim_held 6") == "free\nheld\n"


def test_a_claim_already_gone_counts_as_freed(store):
    gh = fake(store)

    assert gh.claim_delete(5) is None
    bash(store, "fake_claim_seed 5")
    gh.claim_delete(5)
    assert gh.claim_delete(5) is None
    assert bash(store, "fake_claim_held 5") == "free\n"


def test_a_claim_the_python_seeder_wrote_reads_back_as_the_bash_fake_holds_it(store):
    seed = FakeStore(str(store))
    seed.claim(5)
    bash(store, "fake_claim_seed 6")

    assert bash(store, "fake_claim_held 5") == "held\n"
    assert (store / "claims" / "5").read_text() == (store / "claims" / "6").read_text().replace(
        "6\t", "5\t", 1)
    assert (seed.claim_held(5), seed.claim_held(6), seed.claim_held(7)) == (True, True, False)
    fake(store).claim_delete(6)
    assert seed.claim_held(6) is False


# --- the operation audit adds --------------------------------------------------


def test_the_open_titles_of_a_bash_seeded_store_read_as_the_bash_fake_lists_them(store):
    bash_answer = bash(store, r"""
fake_issue 3 open; fake_issue_title 3 'Oldest'
fake_issue 12 open bug; fake_issue_title 12 $'Newest\t tab'
fake_issue 7 closed; fake_issue_title 7 'Closed'
fake_issue 9 open; fake_issue_title 9 'A pull'; : >"$ORCH_GH_FAKE_STORE/issues/9/pull"
fake_issue 5 open
adapter_issues_open_titles
""")

    assert fake(store).issues_open_titles() == [(12, "Newest\t tab"), (5, ""), (3, "Oldest")]
    assert bash_answer == "12\tNewest\t tab\n5\t\n3\tOldest\n"


# --- the PR reads review-pass known-items adds --------------------------------


def test_the_prs_of_a_bash_seeded_store_read_as_the_bash_fake_answers_them(store):
    bash_answer = bash(store, r"""
fake_pr 4 open topic main
fake_pr 9 open topic trunk; fake_pr_cross 9
fake_pr 12 open topic main; fake_pr_cross 12 maybe
fake_pr 7 closed topic main
fake_pr 8 open other main
printf '%s' $'Body\r\nline\n' >"$ORCH_GH_FAKE_STORE/prs/4/body"
fake_pr_comment 4 ann 2026-03-01T00:00:00Z 'First.'
fake_pr_comment 4 bob 2026-03-02T00:00:00Z $'Second\n' NONE
adapter_prs_open topic; echo
adapter_prs_open topic main; echo
adapter_pr_body 4 | od -An -c | tr -s ' '
adapter_pr_comments 4 | jq -c '.comments[]'
adapter_pr_comments 9 | jq -c '.comments'
""")
    gh = fake(store)

    assert gh.prs_open("topic") == ["12\tmaybe", "9\ttrue", "4\tfalse"]
    assert gh.prs_open("topic", "main") == ["12\tmaybe", "4\tfalse"]
    assert gh.pr_body(4) == "Body\r\nline\n"
    assert gh.pr_body(9) == ""
    comments = gh.pr_comments(4)
    assert comments == [
        {"author": {"login": "ann"}, "authorAssociation": "OWNER",
         "createdAt": "2026-03-01T00:00:00Z", "body": "First.",
         "url": "https://github.com/o/r/issues/4#issuecomment-1"},
        {"author": {"login": "bob"}, "authorAssociation": "NONE",
         "createdAt": "2026-03-02T00:00:00Z", "body": "Second\n",
         "url": "https://github.com/o/r/issues/4#issuecomment-2"},
    ]
    assert gh.pr_comments(9) == []
    bash_lines = bash_answer.split("\n")
    assert bash_lines[:6] == ["12\tmaybe", "9\ttrue", "4\tfalse", "", "12\tmaybe", "4\tfalse"]
    assert bash_lines[7] == " B o d y \\r \\n l i n e \\n \\n"
    assert [json.loads(line) for line in bash_lines[8:10]] == comments
    assert bash_lines[10] == "[]"


def test_a_pr_number_the_store_does_not_hold_fails_as_gh_does(store):
    for read in (lambda gh: gh.pr_body(9), lambda gh: gh.pr_comments(9)):
        with pytest.raises(GhFailed) as failed:
            read(fake(store))

        assert failed.value.stderr == (
            "GraphQL: Could not resolve to a PullRequest with the number of 9."
            " (repository.pullRequest)\n"
        )


def test_prs_seeded_by_the_python_seeders_read_back_through_the_bash_fake(store):
    seed = FakeStore(str(store))
    seed.pr(4, "open", "topic", "main")
    seed.pr(9, "open", "topic", "main")
    seed.pr_cross(9)
    seed.pr_body(4, "Body\r\n")
    seed.pr_comment(4, "ann", "2026-03-01T00:00:00Z", "Hi.", "NONE")

    assert bash(store, r"""
adapter_prs_open topic
adapter_pr_body 4 | od -An -c | tr -s ' '
adapter_pr_comments 4 | jq -c '.comments[0] | [.author.login, .authorAssociation, .createdAt, .body]'
""") == '9\ttrue\n4\tfalse\n B o d y \\r \\n \\n\n["ann","NONE","2026-03-01T00:00:00Z","Hi."]\n'


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


def test_a_python_reopen_reads_back_open_with_no_close_reason_through_the_bash_helpers(store):
    bash(store, "fake_issue 5 open; fake_issue 6 open; adapter_issue_close 6 --reason 'not planned'")
    gh = fake(store)
    gh.issue_close(5, comment="Dup.", duplicate_of=6)

    gh.issue_reopen(5)
    gh.issue_reopen(6)

    assert bash(store, r"""
for n in 5 6; do printf '%s|%s|%s\n' "$(fake_state_of $n)" "$(fake_reason_of $n)" \
  "$(fake_duplicate_of $n)"; done
""") == "OPEN||\nOPEN||\n"


def test_a_python_pr_close_comments_an_open_pr_and_leaves_a_closed_one_as_it_is(store):
    bash(store, "fake_pr 4 open topic main; fake_pr 5 closed old main; "
                "fake_pr_comment 5 ann 2026-02-01T00:00:00Z 'Earlier.'")
    gh = fake(store)

    gh.pr_close(4, "Closed by a redo.\n\nSee `orch/7-x-redo-1`.\n")
    gh.pr_close(4, "Closed again.")
    gh.pr_close(5, "Never posted.")

    assert bash(store, r"""
for n in 4 5; do cat "$ORCH_GH_FAKE_STORE/prs/$n/state"; fake_pr_comments_of $n; echo '|'; done
""") == "CLOSED\nClosed by a redo.\n\nSee `orch/7-x-redo-1`.\n|\nCLOSED\nEarlier.|\n"


def test_a_pr_close_gives_up_at_a_first_secondary_limit(store):
    bash(store, "fake_pr 4 open topic main; fake_fail_times adapter_pr_close 1 '%s'" % SECONDARY)

    with pytest.raises(GhFailed):
        fake(store).pr_close(4, "Closed.")

    assert bash(store, 'cat "$ORCH_GH_FAKE_STORE/prs/4/state"; fake_pr_comments_of 4') == "OPEN\n"


def test_python_unlinks_and_edge_writes_read_back_through_the_bash_fake(store):
    bash(store, r"""
for n in 10 11 12 13 14; do fake_issue $n open; done
adapter_sub_issue_link 10 11
adapter_sub_issue_link 10 12
adapter_blocker_add 12 13
""")
    gh = fake(store)

    gh.sub_issue_unlink(10, 11)
    gh.blocker_add(12, 14)
    gh.blocker_add(12, 14)
    gh.blocker_remove(12, 13)
    gh.blocker_remove(11, 13)

    assert bash(store, "adapter_sub_issues 10; echo --; adapter_blockers 12; echo --; "
                       "adapter_blockers 11") == "12\tOPEN\t1\n--\n14\n--\n"


def test_python_sub_issue_links_list_once_in_link_order_and_read_back_through_the_bash_fake(
        store):
    py = FakeStore(str(store))
    for n in (10, 11, 12):
        py.issue(n, "open")
    gh = fake(store)

    gh.sub_issue_link(10, 12)
    gh.sub_issue_link(10, 11)
    gh.sub_issue_link(10, 12)

    assert gh.sub_issues(10) == [SubIssue(12, "OPEN", 0), SubIssue(11, "OPEN", 0)]
    assert bash(store, "adapter_sub_issues 10") == "12\tOPEN\t0\n11\tOPEN\t0\n"


@pytest.mark.parametrize("call", [
    lambda gh: gh.sub_issue_link(10, 99), lambda gh: gh.sub_issue_link(99, 10),
    lambda gh: gh.sub_issue_unlink(10, 99), lambda gh: gh.sub_issue_unlink(99, 10),
    lambda gh: gh.blocker_add(10, 99), lambda gh: gh.blocker_remove(99, 10),
])
def test_a_link_unlink_or_edge_write_naming_an_issue_the_store_lacks_fails(store, call):
    FakeStore(str(store)).issue(10, "open")

    with pytest.raises(GhFailed) as failed:
        call(fake(store))

    assert "Could not resolve to an issue or pull request with the number of 99" in (
        failed.value.stderr)


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


def test_the_python_default_branch_seeder_answers_the_bash_fake_byte_for_byte(store):
    FakeStore(str(store)).default_branch("trunk\n")

    assert bash(store, "adapter_repo_default_branch acme/widgets | od -An -c | tr -s ' '") == (
        " t r u n k \\n\n")


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


def test_a_lag_the_python_seeder_sets_after_current_reads_the_bash_fake_honours(store):
    seed = FakeStore(str(store))
    seed.issue(5, "open", "ready")
    seed.title(5, "Current")
    seed.lag_after("adapter_issue_title_labels", 1, 1, "Stale\nold-label")

    assert bash(store, r"""
for _ in 1 2 3; do adapter_issue_title_labels 5 | paste -sd ' ' -; done
""") == "Current ready\nStale old-label\nCurrent ready\n"


# --- the operations the pr noun adds ------------------------------------------


def test_the_pr_reads_of_a_bash_seeded_store_read_as_the_bash_fake_answers_them(store):
    bash_answer = bash(store, r"""
fake_pr 4 open topic main; fake_pr_draft 4; fake_pr_head 4 abc123
printf 'bug\nNeeds Human\n' >"$ORCH_GH_FAKE_STORE/prs/4/labels"
printf 'diff --git a/x b/x\n+y\n' >"$ORCH_GH_FAKE_STORE/prs/4/diff"
fake_pr 5 merged other next
fake_issue 7 open; fake_issue_created 7 0
printf '2026-03-01T12:00:00Z\n' >"$ORCH_GH_FAKE_STORE/issues/7/created_at"
fake_issue 8 open
adapter_pr_labels 4; echo '|'
adapter_pr_labels 5; echo '|'
adapter_pr_refs 4; adapter_pr_refs 5; echo '|'
adapter_pr_state_draft 4; adapter_pr_state_draft 5; echo '|'
adapter_pr_diff 4; adapter_pr_diff 5; echo '|'
adapter_issue_created_at 7; adapter_issue_created_at 8
""")
    gh = fake(store)

    assert gh.pr_labels(4) == ["bug", "Needs Human"]
    assert gh.pr_labels(5) == []
    assert gh.pr_refs(4) == ("abc123", "topic", "main")
    assert gh.pr_refs(5) == ("0" * 40, "other", "next")
    assert gh.pr_state_draft(4) == ("OPEN", True)
    assert gh.pr_state_draft(5) == ("MERGED", False)
    assert gh.pr_diff(4) == "diff --git a/x b/x\n+y\n"
    assert gh.pr_diff(5) == ""
    assert gh.issue_created_at(7) == "2026-03-01T12:00:00Z"
    assert gh.issue_created_at(8) == "1970-01-01T00:00:00Z"
    assert bash_answer == (
        "bug\nNeeds Human\n|\n|\n"
        "abc123\ntopic\nmain\n%s\nother\nnext\n|\n"
        "OPEN\ntrue\nMERGED\nfalse\n|\n"
        "diff --git a/x b/x\n+y\n|\n"
        "2026-03-01T12:00:00Z\n1970-01-01T00:00:00Z\n" % ("0" * 40))


def test_the_pr_listings_of_a_bash_seeded_store_read_as_the_bash_fake_lists_them(store):
    bash_answer = bash(store, r"""
fake_pr 4 open topic main; printf 'Refs #3\r\n\nBody\t"q"' >"$ORCH_GH_FAKE_STORE/prs/4/body"
fake_pr 9 open fork main; fake_pr_cross 9
fake_pr 6 closed old main
fake_pr 10 merged orch/5-x main; fake_pr_merged 10 0 5 7
printf '2026-03-02T00:00:00Z\n' >"$ORCH_GH_FAKE_STORE/prs/10/merged_at"
printf 'Closes #5' >"$ORCH_GH_FAKE_STORE/prs/10/body"
fake_pr 11 merged quick/6-y main; fake_pr_cross 11
printf '2026-03-01T00:00:00Z\n' >"$ORCH_GH_FAKE_STORE/prs/11/merged_at"
fake_pr 12 merged orch/8-z main
printf '2026-02-28T23:59:59Z\n' >"$ORCH_GH_FAKE_STORE/prs/12/merged_at"
printf 'Refs #8' >"$ORCH_GH_FAKE_STORE/prs/12/body"
fake_pr 13 merged orch/9-w next
adapter_prs_open_bodies; echo '|'
adapter_prs_merged_closing main 2026-03-01T00:00:00Z; echo '|'
adapter_prs_merged_bodies main
""")
    gh = fake(store)

    open_bodies = ['9\t""\ttrue', '4\t"Refs #3\\r\\n\\nBody\\t\\"q\\""\tfalse']
    merged = ["11\tquick/6-y\t2026-03-01T00:00:00Z\t\ttrue",
              "10\torch/5-x\t2026-03-02T00:00:00Z\t5,7\tfalse"]
    assert gh.prs_open_bodies() == open_bodies
    assert gh.prs_merged_closing("main", "2026-03-01T00:00:00Z") == merged
    assert gh.prs_merged_bodies("main") == "Refs #8\n\nCloses #5\n"
    assert bash_answer == "\n".join(
        open_bodies + ["|"] + merged + ["|", "Refs #8", "", "Closes #5", ""])


@pytest.mark.parametrize("answer", [
    "green", "failing", "cancel", "external", "tworuns", "onerun", "mixed", "badrunid",
    "comma", "pending", "none", "empty"])
def test_each_scripted_checks_answer_reads_as_the_bash_fake_answers_it(store, answer):
    bash_answer = bash(store, "fake_checks 4 all %s; adapter_pr_checks 4 all 2>/dev/null" % answer)

    assert "".join("\t".join(check) + "\n" for check in fake(store).pr_checks(4, "all")) == (
        bash_answer)


def test_a_checks_script_answers_one_per_call_the_last_repeating_an_unscripted_scope_none(store):
    bash(store, "fake_checks 4 required pending green")
    gh = fake(store)
    runs = "https://github.com/acme/widgets/actions/runs"

    answers = [gh.pr_checks(4, "required") for _ in range(3)]

    green = [Check("pass", "build", runs + "/1/job/1")]
    assert answers == [[Check("pending", "build", "")], green, green]
    assert gh.pr_checks(4, "all") == []
    assert (store / "checks" / "4" / "reads").read_text() == "read\n" * 4


def test_a_boom_or_unknown_checks_answer_fails(store):
    bash(store, "fake_checks 4 all boom; fake_checks 5 all bogus")

    with pytest.raises(GhFailed) as boom:
        fake(store).pr_checks(4, "all")
    with pytest.raises(GhFailed) as bogus:
        fake(store).pr_checks(5, "all")

    assert boom.value.stderr == "dial tcp: lookup api.github.com: no such host\n"
    assert bogus.value.stderr == "gh fake: no checks answer named 'bogus'\n"


def test_python_pr_writes_read_back_through_the_bash_helpers(store, tmp_path):
    bash(store, r"""
fake_label Needs-Human 0e8a16 ''
fake_pr 4 open topic main; fake_pr_draft 4
printf 'bug\n' >"$ORCH_GH_FAKE_STORE/prs/4/labels"
fake_pr 5 open other main
fake_next_pr 40
printf 'Dropped\n' >"$ORCH_GH_FAKE_STORE/pr_label_drops"
""")
    body = tmp_path / "body.md"
    body.write_bytes(b"Closes #3\r\n")
    note = tmp_path / "note.md"
    note.write_text("A note.")
    gh = fake(store)

    created = gh.pr_create("main", "orch/3-x", "New PR", str(body), draft=True,
                           labels=["needs-human", "dropped", "bug"])
    plain = gh.pr_create("next", "quick/4-y", "Plain", str(note))
    gh.pr_ready(4)
    gh.pr_draft(5)
    gh.pr_comment(4, str(note))
    gh.pr_body_edit(4, str(body))
    gh.pr_title_edit(4, "Retitled")
    gh.pr_label_add(4, "BUG")
    gh.pr_label_add(4, "needs-human")

    assert (created, plain) == (40, 41)
    assert bash(store, r"""
for n in 40 41 4 5; do
  d="$ORCH_GH_FAKE_STORE/prs/$n"
  printf '%s|%s|%s|%s|%s|' "$(cat "$d/state")" "$(cat "$d/head")" "$(fake_pr_base_of $n)" \
    "$(cat "$d/title" 2>/dev/null)" "$(fake_pr_draft_of $n)"
  printf '%s|%s|%s\n' "$(fake_pr_body_of $n | od -An -c | tr -s ' ')" \
    "$(paste -sd ' ' "$d/labels" 2>/dev/null)" "$(fake_pr_comments_of $n)"
done
adapter_pr_state_draft 40 | paste -sd ' ' -
""") == (
        "OPEN|orch/3-x|main|New PR|yes| C l o s e s # 3 \\r \\n|Needs-Human bug|\n"
        "OPEN|quick/4-y|next|Plain|no| A n o t e .||\n"
        "OPEN|topic|main|Retitled|no| C l o s e s # 3 \\r \\n|bug Needs-Human|A note.\n"
        "OPEN|other|main||yes|||\n"
        "OPEN true\n"
    )


def test_python_seeded_prs_checks_and_creation_times_read_back_through_the_bash_fake(store):
    seed = FakeStore(str(store))
    seed.issue(7, "open")
    seed.issue_created(7, "2026-03-01T12:00:00Z")
    seed.pr(4, "open", "topic", "main")
    seed.pr_draft(4)
    seed.pr_labels(4, "bug", "wip")
    seed.pr_head(4, "abc123")
    seed.pr_diff(4, "+y\n")
    seed.pr(10, "merged", "orch/7-x", "main")
    seed.pr_merged(10, "2026-03-02T00:00:00Z", 7, 9)
    seed.checks(4, "required", "failing", "green")
    seed.next_pr(50)

    assert bash(store, r"""
adapter_issue_created_at 7
adapter_pr_state_draft 4 | paste -sd ' ' -
adapter_pr_labels 4 | paste -sd ' ' -
adapter_pr_refs 4 | paste -sd ' ' -
adapter_pr_diff 4
adapter_prs_merged_closing main 2026-03-01T00:00:00Z
adapter_pr_checks 4 required; adapter_pr_checks 4 required; adapter_pr_checks 4 required
cat "$ORCH_GH_FAKE_STORE/next_pr"
""") == (
        "2026-03-01T12:00:00Z\nOPEN true\nbug wip\nabc123 topic main\n+y\n"
        "10\torch/7-x\t2026-03-02T00:00:00Z\t7,9\tfalse\n"
        "fail\tbuild\thttps://github.com/acme/widgets/actions/runs/4242/job/77\n"
        "pass\tlint\thttps://github.com/acme/widgets/actions/runs/1/job/1\n"
        + "pass\tbuild\thttps://github.com/acme/widgets/actions/runs/1/job/1\n" * 2
        + "50\n"
    )


def test_a_pr_create_carrying_a_label_gives_up_at_a_first_secondary_limit(store, tmp_path):
    bash(store, "fake_fail_times adapter_pr_create 1 '%s'" % SECONDARY)
    body = tmp_path / "body.md"
    body.write_text("Body")
    sleeps = []

    with pytest.raises(GhFailed):
        fake(store, sleeps=sleeps).pr_create("main", "topic", "T", str(body), labels=["bug"])

    assert sleeps == []
    assert not (store / "prs").exists()


# --- the factory and the pin ---------------------------------------------------


def test_the_fake_is_the_adapter_whenever_a_store_is_set(store, tmp_path):
    assert isinstance(adapter({"ORCH_GH_FAKE_STORE": str(store)}, cwd=str(tmp_path)), FakeGh)
    assert isinstance(adapter({"ORCH_GH_FAKE_STORE": ""}, cwd=str(tmp_path)), Gh)
    assert isinstance(adapter({}, cwd=str(tmp_path)), Gh)


def test_the_adapter_pins_by_the_repo_pin_handed_in(store, tmp_path):
    origin = RepoPin({}, FakeGit({"origin": "https://github.com/o/r.git"}))
    none = RepoPin({}, FakeGit())

    assert adapter({"ORCH_GH_FAKE_STORE": str(store)}, pin=origin).pin() is True
    assert adapter({"ORCH_GH_FAKE_STORE": str(store)}, pin=none).pin() is False
    assert adapter({}, cwd=str(tmp_path), pin=origin).pin() is True
    assert adapter({}, cwd=str(tmp_path), pin=none).pin() is False


def test_the_fake_pins_as_the_repo_pin_it_is_given(store):
    with_origin = RepoPin({}, FakeGit({"origin": "https://github.com/o/r.git"}))
    without = RepoPin({}, FakeGit())

    assert FakeGh(str(store), {}, pin=with_origin).pin() is True
    assert FakeGh(str(store), {}, pin=without).pin() is False
    assert FakeGh(str(store), {}).pin() is True
