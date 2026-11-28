"""The gh adapter's fake on the file store: a store FakeStore seeded, or
the layout scripts/test/gh_adapter_fake.sh documents written raw, reads
through FakeGh as gh would answer, what FakeGh writes lands in that layout,
and the store's failure files inject failures under the adapter's operation
names. The expected answers are the ones the bash fake gave on the same
store, while it had operations."""
from __future__ import annotations

import os
import threading
from pathlib import Path

import pytest

from conftest import until
from orch.gh import Check, Gh, GhFailed, IssueRow, LabelledBody, StateRow, SubIssue, adapter
from orch.gh_fake import FakeGh, FakeStore
from orch.git import FakeGit
from orch.repo import RepoPin

SECONDARY = "You have exceeded a secondary rate limit."
NOW = 1_900_000_000


def fake(store, sleeps=None, **env):
    slept = sleeps if sleeps is not None else []
    return FakeGh(str(store), env, sleep=slept.append, now=lambda: NOW)


def held(store, *parts):
    """The text of the store file at <parts>, "" where it is absent."""
    path = Path(store).joinpath(*(str(p) for p in parts))
    return path.read_bytes().decode() if path.is_file() else ""


def pull(store, n):
    """Marks the store's issue #n a pull request."""
    (store / "issues" / str(n) / "pull").write_text("")


def comment_bodies(store, kind, n):
    """The bodies of the comments the store holds on issue or PR #n, in
    order."""
    directory = store / kind / str(n) / "comments"
    if not directory.is_dir():
        return []
    return [(directory / k / "body").read_bytes().decode()
            for k in sorted(os.listdir(str(directory)), key=int)]


# --- reads of a seeded store ----------------------------------------------------


def test_an_issue_seeded_in_the_store_reads_as_gh_answers(seed, store):
    seed.issue(5, "open", "bug", "ready-for-agent")
    seed.title(5, "A title")
    seed.body(5, "line one\r\nline two\n")
    seed.comment(5, "ann", "2026-02-01T00:00:00Z", "First.")
    seed.comment(5, "bob", "2026-02-02T00:00:00Z", "Second\n", "NONE")
    seed.issue(6, "closed")
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


def test_the_titled_listing_is_the_open_issues_carrying_the_label_oldest_first(
        seed, store, capsys):
    seed.issue(7, "open", "Ready-For-Agent")
    seed.title(7, "Seventh")
    seed.issue(3, "open", "ready-for-agent", "wip")
    seed.title(3, "Third")
    seed.issue(4, "closed", "ready-for-agent")
    seed.issue(8, "open", "bug")
    seed.issue(9, "open", "ready-for-agent")
    pull(store, 9)

    assert fake(store).issues_titled_rows("ready-for-agent") == [
        IssueRow(3, "OPEN", "Third", ["ready-for-agent", "wip"]),
        IssueRow(7, "OPEN", "Seventh", ["Ready-For-Agent"]),
    ]
    assert capsys.readouterr().err == ""


def test_the_titled_listing_is_cut_at_the_issue_list_limit_with_a_warning(seed, store, capsys):
    for n in (1, 2, 3):
        seed.issue(n, "open", "ready")

    rows = fake(store, ORCH_ISSUE_LIST_LIMIT="2").issues_titled_rows("ready")

    assert [row.number for row in rows] == [1, 2]
    assert "reached the issue-list limit of 2" in capsys.readouterr().err


def test_sub_issues_and_blockers_seeded_in_the_store_read_as_gh_answers(seed, store):
    for n in (10, 11, 12, 13, 14, 15):
        seed.issue(n, "open")
    seed.issue(13, "closed")
    seed.sub_issue(10, 12)
    seed.sub_issue(10, 11)
    seed.sub_issue(10, 13)
    seed.blocked_by(11, 14, 13, 15)
    gh = fake(store)

    assert gh.sub_issues(10) == [SubIssue(12, "OPEN", 0), SubIssue(11, "OPEN", 2),
                                 SubIssue(13, "CLOSED", 0)]
    assert gh.sub_issues(14) == []
    assert (gh.blockers(11), gh.blockers(12)) == ([14, 13, 15], [])


def test_a_parent_and_open_blockers_read_from_the_store_none_without_a_summary(seed, store):
    for n in (10, 11, 12, 13, 14):
        seed.issue(n, "open")
    seed.issue(13, "closed")
    seed.sub_issue(10, 11)
    seed.blocked_by(12, 13, 14)
    seed.no_dependency_summary(11)
    gh = fake(store)

    assert (gh.issue_parent(11), gh.issue_parent(12)) == (10, None)
    assert (gh.issue_open_blockers(12), gh.issue_open_blockers(11)) == (1, None)
    assert gh.blockers_states(12) == [(13, "CLOSED"), (14, "OPEN")]
    assert gh.blockers_states(11) == []


def test_a_lagging_sub_issue_listing_answers_the_stale_listing(seed, store):
    for n in (10, 11):
        seed.issue(n, "open")
    seed.sub_issue(10, 11)
    seed.lag("adapter_sub_issues", 1, "")
    gh = fake(store)

    assert gh.sub_issues(10) == []
    assert gh.sub_issues(10) == [SubIssue(11, "OPEN", 0)]


@pytest.mark.parametrize("call", [lambda gh: gh.sub_issues(99), lambda gh: gh.blockers(99)])
def test_a_sub_issue_or_blocker_read_of_an_issue_the_store_lacks_fails(store, call):
    with pytest.raises(GhFailed) as failed:
        call(fake(store))

    assert "Could not resolve to an issue or pull request with the number of 99" in (
        failed.value.stderr)


def test_authorship_seeded_in_the_store_reads_as_gh_answers(seed, store):
    seed.issue(5, "open")
    seed.authorship(5, "ann", "NONE", "bob")
    seed.issue(6, "open")
    seed.issue(7, "open")
    seed.authorship(7, "ann", "NONE", "", "cid")
    gh = fake(store)

    assert (gh.issue_authorship(5), gh.issue_authorship(6), gh.issue_authorship(7)) == (
        ("ann", "NONE", "bob", ""), ("fake-gh", "OWNER", "", ""), ("ann", "NONE", "", "cid"))


# --- the operations finding triage adds ---------------------------------------


def test_the_bodies_listing_reads_the_open_issues_carrying_every_label(seed, store, capsys):
    seed.issue(7, "open", "review:nit", "Needs-Triage")
    seed.body(7, "Seventh\r\nbody\n\n")
    seed.issue(3, "open", "REVIEW:NIT", "needs-triage", "wip")
    seed.issue(4, "closed", "review:nit", "needs-triage")
    seed.issue(5, "open", "review:nit")
    seed.issue(9, "open", "review:nit", "needs-triage")
    pull(store, 9)

    answer = fake(store).issues_labelled_bodies("review:nit", "needs-triage")

    assert answer == [
        LabelledBody(3, ["REVIEW:NIT", "needs-triage", "wip"], ""),
        LabelledBody(7, ["review:nit", "Needs-Triage"], "Seventh\r\nbody"),
    ]
    assert capsys.readouterr().err == ""


def test_the_bodies_listing_is_cut_at_the_limit_warning_with_every_label(seed, store, capsys):
    for n in (1, 2, 3):
        seed.issue(n, "open", "review:major", "needs-triage")

    rows = fake(store, ORCH_ISSUE_LIST_LIMIT="2").issues_labelled_bodies(
        "review:major", "needs-triage")

    assert [row.number for row in rows] == [1, 2]
    assert capsys.readouterr().err == (
        "orch: the open issues labelled review:major and needs-triage reached the"
        " issue-list limit of 2 - the newest past it are missing from this list\n"
    )


def test_issue_state_answers_pull_for_a_pull_request(seed, store):
    seed.issue(5, "open")
    seed.issue(6, "closed")
    seed.issue(7, "open")
    pull(store, 7)
    seed.pr(8, "open", "topic", "main")
    gh = fake(store)

    assert [gh.issue_state(n) for n in (5, 6, 7, 8)] == ["OPEN", "CLOSED", "PULL", "PULL"]
    with pytest.raises(GhFailed) as failed:
        gh.issue_state(9)
    assert "Could not resolve to an issue or pull request with the number of 9" in failed.value.stderr


def test_label_create_adds_a_missing_label_and_fails_on_one_in_any_casing(seed, store):
    seed.label("Bug", "d73a4a", "Something is wrong")
    gh = fake(store)

    gh.label_create("finding-bundle", "c5def5", "Several filed findings worked as one")
    with pytest.raises(GhFailed) as failed:
        gh.label_create("BUG", "000000", "x")

    assert failed.value.stderr == (
        'label with name "BUG" already exists; use `--force` to update its color'
        " and description\n"
    )
    assert held(store, "labels") == (
        "Bug\td73a4a\tSomething is wrong\n"
        "finding-bundle\tc5def5\tSeveral filed findings worked as one\n"
    )


def test_label_upsert_rewrites_a_label_in_its_casing_and_adds_a_missing_one(seed, store):
    seed.label("Bug", "d73a4a", "Something is wrong")
    seed.label("nit", "c5def5", "Small")
    gh = fake(store)

    gh.label_upsert("BUG", "ffffff", "Rewritten")
    gh.label_upsert("review:major", "d93f0b", "Review finding filed at major severity")

    assert (store / "labels").read_text() == (
        "nit\tc5def5\tSmall\n"
        "Bug\tffffff\tRewritten\n"
        "review:major\td93f0b\tReview finding filed at major severity\n"
    )


def test_a_label_upsert_seeded_to_fail_writes_nothing(store, seed):
    seed.fail("adapter_label_upsert", "HTTP 502: Bad Gateway\n")

    with pytest.raises(GhFailed):
        fake(store).label_upsert("review:nit", "c5def5", "x")
    assert not (store / "labels").exists()


def test_a_fifo_at_hold_parks_the_operation_until_a_line_is_written_to_it(store):
    """A call of the operation writes its process's pid
    to `held` and waits, before touching the store, until something is
    written to the fifo hold/<operation>."""
    (store / "hold").mkdir()
    os.mkfifo(str(store / "hold" / "adapter_label_upsert"))
    call = threading.Thread(target=fake(store).label_upsert, args=("nit", "c5def5", "Small"),
                            daemon=True)
    call.start()

    assert until(lambda: (store / "held").is_file()
                 and (store / "held").read_text() == "%d\n" % os.getpid())
    assert call.is_alive() and not (store / "labels").exists()
    with open(str(store / "hold" / "adapter_label_upsert"), "w") as release:
        release.write("x\n")
    call.join(5)

    assert not call.is_alive()
    assert (store / "labels").read_text() == "nit\tc5def5\tSmall\n"


def test_repo_default_branch_is_the_stored_answer_and_fails_with_none(seed, store):
    gh = fake(store)
    with pytest.raises(GhFailed) as failed:
        gh.repo_default_branch("acme/gone")
    seed.default_branch("trunk\n")

    assert failed.value.stderr == (
        "GraphQL: Could not resolve to a Repository with the name 'acme/gone'. (repository)\n")
    assert gh.repo_default_branch("acme/widgets") == "trunk"
    assert held(store, "default_branch") == "trunk\n"


def test_the_local_default_the_python_seeder_stores_reads_back(store):
    seed = FakeStore(str(store))
    assert fake(store).repo_local_default() == ""
    seed.local_default("upstream/widgets")

    assert fake(store).repo_local_default() == "upstream/widgets"


def test_noauth_fails_the_auth_status_with_gh_s_login_report_and_the_rest_as_unauthorised(
        seed, store):
    seed.issue(5, "open")
    seed.noauth()
    gh = fake(store)

    with pytest.raises(GhFailed) as status:
        gh.auth_status("github.com")
    with pytest.raises(GhFailed) as body:
        gh.issue_body(5)

    assert status.value.stderr == (
        "You are not logged into any GitHub hosts. To log in, run: gh auth login\n")
    assert body.value.stderr == "HTTP 401: Bad credentials (https://api.github.com/graphql)\n"


def test_the_label_names_the_python_seeder_stores_list_back_up_to_the_limit(store):
    assert fake(store).labels(1000) == []
    FakeStore(str(store)).label_names("needs triage", "Ready-For-Agent", "wontfix")

    assert fake(store).labels(2) == ["needs triage", "Ready-For-Agent"]


def test_label_names_seeded_raw_list_the_same(store):
    (store / "labels").write_text("bug\t\t\nneeds info\t\t\n")

    assert fake(store).labels(1000) == ["bug", "needs info"]


@pytest.mark.parametrize("seeding, answer", [
    ("", None),
    ("issue", True),
    ("refused", False),
])
def test_sub_issue_support_answers_from_the_store(seed, store, seeding, answer):
    if seeding:
        seed.issue(1, "open")
    if seeding == "refused":
        seed.no_sub_issues()

    assert fake(store).sub_issues_supported() is answer


@pytest.mark.parametrize("operation, call", [
    ("adapter_issues_labelled_bodies", lambda gh: gh.issues_labelled_bodies("review:nit")),
    ("adapter_issue_state", lambda gh: gh.issue_state(5)),
    ("adapter_label_create", lambda gh: gh.label_create("bug", "d73a4a", "d")),
    ("adapter_repo_default_branch", lambda gh: gh.repo_default_branch("acme/widgets")),
    ("adapter_issues_open_titles", lambda gh: gh.issues_open_titles()),
    ("adapter_prs_open", lambda gh: gh.prs_open("topic")),
    ("adapter_prs_merged", lambda gh: gh.prs_merged("topic", "main")),
    ("adapter_pr_body", lambda gh: gh.pr_body(6)),
    ("adapter_pr_comments", lambda gh: gh.pr_comments(6)),
    ("adapter_sub_issues", lambda gh: gh.sub_issues(5)),
    ("adapter_blockers", lambda gh: gh.blockers(5)),
    ("adapter_sub_issue_link", lambda gh: gh.sub_issue_link(5, 7)),
    ("adapter_sub_issue_unlink", lambda gh: gh.sub_issue_unlink(5, 7)),
    ("adapter_blocker_add", lambda gh: gh.blocker_add(5, 7)),
    ("adapter_blocker_remove", lambda gh: gh.blocker_remove(5, 7)),
    ("adapter_claim_delete", lambda gh: gh.claim_delete(5)),
    ("adapter_issues_labelled_rows", lambda gh: gh.issues_labelled_rows("needs-human")),
    ("adapter_issues_any_labelled_rows", lambda gh: gh.issues_any_labelled_rows("needs-human")),
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
    ("adapter_pr_url_head", lambda gh: gh.pr_url_head(6)),
    ("adapter_branch_required_checks", lambda gh: gh.branch_required_checks("main")),
    ("adapter_branch_rules", lambda gh: gh.branch_rules("main")),
    ("adapter_pr_commits_checked", lambda gh: gh.pr_commits_checked(6)),
    ("adapter_run_rerun", lambda gh: gh.run_rerun(4242)),
    ("adapter_job_failed_log", lambda gh: gh.job_failed_log(77)),
    ("adapter_repo_local_default", lambda gh: gh.repo_local_default()),
    ("adapter_auth_status", lambda gh: gh.auth_status("github.com")),
    ("adapter_labels", lambda gh: gh.labels(1000)),
    ("adapter_labels_detail", lambda gh: gh.labels_detail(1000)),
    ("adapter_prs_open_mergeability", lambda gh: gh.prs_open_mergeability()),
    ("adapter_sub_issues_supported", lambda gh: gh.sub_issues_supported()),
])
def test_the_added_operations_fail_under_the_adapter_operation_names(seed, store, operation, call):
    seed.issue(5, "open", "review:nit")
    seed.issue(7, "open")
    seed.default_branch("trunk\n")
    seed.pr(6, "open", "topic", "main")
    seed.fail(operation, "HTTP 502: Bad Gateway")

    with pytest.raises(GhFailed) as failed:
        call(fake(store))

    assert failed.value.stderr == "HTTP 502: Bad Gateway\n"


# --- the claim delete -------------------------------------------------------------


def test_a_seeded_claim_is_freed_by_the_fake(seed, store):
    seed.claim(5)
    seed.claim(6)

    assert fake(store).claim_delete(5) is None
    assert (seed.claim_held(5), seed.claim_held(6)) == (False, True)


def test_a_claim_already_gone_counts_as_freed(seed, store):
    gh = fake(store)

    assert gh.claim_delete(5) is None
    seed.claim(5)
    gh.claim_delete(5)
    assert gh.claim_delete(5) is None
    assert seed.claim_held(5) is False


def test_a_seeded_claim_is_laid_out_as_one_tsv_line(seed, store):
    seed.claim(5, host="thishost")

    assert held(store, "claims", 5) == "5\tthishost\t1\tspec\t2026-01-01T00:00:00Z\n"
    assert (seed.claim_held(5), seed.claim_held(7)) == (True, False)


# --- the operation audit adds --------------------------------------------------


def test_the_open_titles_read_newest_first_leaving_out_closed_issues_and_pulls(seed, store):
    seed.issue(3, "open")
    seed.title(3, "Oldest")
    seed.issue(12, "open", "bug")
    seed.title(12, "Newest\t tab")
    seed.issue(7, "closed")
    seed.title(7, "Closed")
    seed.issue(9, "open")
    seed.title(9, "A pull")
    pull(store, 9)
    seed.issue(5, "open")

    assert fake(store).issues_open_titles() == [(12, "Newest\t tab"), (5, ""), (3, "Oldest")]


# --- the PR reads review-pass known-items adds --------------------------------


def test_the_prs_seeded_in_the_store_read_as_gh_answers_them(seed, store):
    seed.pr(4, "open", "topic", "main")
    seed.pr(9, "open", "topic", "trunk")
    seed.pr_cross(9)
    seed.pr(12, "open", "topic", "main")
    seed.pr_cross(12, "maybe")
    seed.pr(7, "closed", "topic", "main")
    seed.pr(8, "open", "other", "main")
    seed.pr_body(4, "Body\r\nline\n")
    seed.pr_comment(4, "ann", "2026-03-01T00:00:00Z", "First.")
    seed.pr_comment(4, "bob", "2026-03-02T00:00:00Z", "Second\n", "NONE")
    gh = fake(store)

    assert gh.prs_open("topic") == ["12\tmaybe", "9\ttrue", "4\tfalse"]
    assert gh.prs_open("topic", "main") == ["12\tmaybe", "4\tfalse"]
    assert gh.pr_body(4) == "Body\r\nline\n"
    assert gh.pr_body(9) == ""
    assert gh.pr_comments(4) == [
        {"author": {"login": "ann"}, "authorAssociation": "OWNER",
         "createdAt": "2026-03-01T00:00:00Z", "body": "First.",
         "url": "https://github.com/o/r/issues/4#issuecomment-1"},
        {"author": {"login": "bob"}, "authorAssociation": "NONE",
         "createdAt": "2026-03-02T00:00:00Z", "body": "Second\n",
         "url": "https://github.com/o/r/issues/4#issuecomment-2"},
    ]
    assert gh.pr_comments(9) == []


def test_the_merged_prs_read_newest_first_with_their_heads(seed, store):
    seed.pr(4, "merged", "topic", "main")
    seed.pr(9, "merged", "topic", "main")
    seed.pr_cross(9)
    seed.pr_head(9, "abc123")
    seed.pr(12, "merged", "topic", "trunk")
    seed.pr(7, "open", "topic", "main")
    seed.pr(8, "merged", "other", "main")

    assert fake(store).prs_merged("topic", "main") == [
        "9\tabc123\ttrue", "4\t%s\tfalse" % ("0" * 40)]


def test_a_pr_number_the_store_does_not_hold_fails_as_gh_does(store):
    for read in (lambda gh: gh.pr_body(9), lambda gh: gh.pr_comments(9)):
        with pytest.raises(GhFailed) as failed:
            read(fake(store))

        assert failed.value.stderr == (
            "GraphQL: Could not resolve to a PullRequest with the number of 9."
            " (repository.pullRequest)\n"
        )


def test_the_pr_seeders_write_the_store_layout(seed, store):
    seed.pr(4, "open", "topic", "main")
    seed.pr_body(4, "Body\r\n")
    seed.pr_comment(4, "ann", "2026-03-01T00:00:00Z", "Hi.", "NONE")

    assert [held(store, "prs", 4, name) for name in ("state", "head", "base", "body")] == [
        "OPEN\n", "topic\n", "main\n", "Body\r\n"]
    assert [held(store, "prs", 4, "comments", 1, name)
            for name in ("author", "association", "created", "body")] == [
        "ann\n", "NONE\n", "2026-03-01T00:00:00Z\n", "Hi."]


# --- writes the store holds -----------------------------------------------------


def test_the_fake_s_issue_writes_land_in_the_store_layout(seed, store, tmp_path):
    seed.issue(5, "open", "wip", "needs-triage")
    seed.issue(6, "open")
    seed.issue(7, "closed")
    seed.label("Ready-For-Agent", "0e8a16", "")
    seed.next_issue(40)
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
    assert [(held(store, "issues", n, "state"), held(store, "issues", n, "title"),
             held(store, "issues", n, "labels"), held(store, "issues", n, "reason"),
             held(store, "issues", n, "duplicate_of"), held(store, "issues", n, "body"),
             comment_bodies(store, "issues", n)) for n in (40, 5, 6, 7)] == [
        ("OPEN\n", "New issue\n", "Ready-For-Agent\nbug\n", "", "", "New body\r\n", []),
        ("CLOSED\n", "", "Ready-For-Agent\n", "completed\n", "", "New body\r\n",
         ["A note.", "Done."]),
        ("CLOSED\n", "", "", "duplicate\n", "5\n", "", ["Dup."]),
        ("CLOSED\n", "", "", "", "", "", []),
    ]
    assert held(store, "next_issue") == "41\n"


def test_a_reopen_leaves_the_issue_open_with_no_close_reason(seed, store):
    seed.issue(5, "open")
    seed.issue(6, "open")
    gh = fake(store)
    gh.issue_close(6, reason="not planned")
    gh.issue_close(5, comment="Dup.", duplicate_of=6)

    gh.issue_reopen(5)
    gh.issue_reopen(6)

    assert [(held(store, "issues", n, "state"), held(store, "issues", n, "reason"),
             held(store, "issues", n, "duplicate_of")) for n in (5, 6)] == [
        ("OPEN\n", "", ""), ("OPEN\n", "", "")]


def test_a_pr_close_comments_an_open_pr_and_leaves_a_closed_one_as_it_is(seed, store):
    seed.pr(4, "open", "topic", "main")
    seed.pr(5, "closed", "old", "main")
    seed.pr_comment(5, "ann", "2026-02-01T00:00:00Z", "Earlier.")
    gh = fake(store)

    gh.pr_close(4, "Closed by a redo.\n\nSee `orch/7-x-redo-1`.\n")
    gh.pr_close(4, "Closed again.")
    gh.pr_close(5, "Never posted.")

    assert [(held(store, "prs", n, "state"), comment_bodies(store, "prs", n))
            for n in (4, 5)] == [
        ("CLOSED\n", ["Closed by a redo.\n\nSee `orch/7-x-redo-1`.\n"]),
        ("CLOSED\n", ["Earlier."])]


def test_a_pr_close_gives_up_at_a_first_secondary_limit(seed, store):
    seed.pr(4, "open", "topic", "main")
    seed.fail_times("adapter_pr_close", 1, SECONDARY)

    with pytest.raises(GhFailed):
        fake(store).pr_close(4, "Closed.")

    assert (held(store, "prs", 4, "state"), comment_bodies(store, "prs", 4)) == ("OPEN\n", [])


def test_unlinks_and_edge_writes_land_in_the_store(seed, store):
    for n in (10, 11, 12, 13, 14):
        seed.issue(n, "open")
    seed.sub_issue(10, 11)
    seed.sub_issue(10, 12)
    seed.blocked_by(12, 13)
    gh = fake(store)

    gh.sub_issue_unlink(10, 11)
    gh.blocker_add(12, 14)
    gh.blocker_add(12, 14)
    gh.blocker_remove(12, 13)
    gh.blocker_remove(11, 13)

    assert gh.sub_issues(10) == [SubIssue(12, "OPEN", 1)]
    assert (gh.blockers(12), gh.blockers(11)) == ([14], [])
    assert (held(store, "subs", 10), held(store, "blocked_by", 12)) == ("12\n", "14\n")


def test_sub_issue_links_list_once_in_link_order(seed, store):
    for n in (10, 11, 12):
        seed.issue(n, "open")
    gh = fake(store)

    gh.sub_issue_link(10, 12)
    gh.sub_issue_link(10, 11)
    gh.sub_issue_link(10, 12)

    assert gh.sub_issues(10) == [SubIssue(12, "OPEN", 0), SubIssue(11, "OPEN", 0)]
    assert held(store, "subs", 10) == "12\n11\n"


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


def test_a_new_issue_with_no_next_number_seeded_takes_one_past_the_highest(seed, store, tmp_path):
    seed.issue(12, "open")
    (store / "prs" / "30").mkdir(parents=True)
    body = tmp_path / "body.md"
    body.write_text("")

    assert fake(store).issue_create("T", str(body), []) == 31


# --- failure files, under the adapter's operation names -----------------------


def test_fail_files_fail_the_named_operation(seed, store):
    seed.issue(5, "open")
    seed.fail("adapter_issue_body", "HTTP 502: Bad Gateway\nsecond line")
    seed.fail("adapter_issue_comment")
    gh = fake(store)

    with pytest.raises(GhFailed) as body:
        gh.issue_body(5)
    with pytest.raises(GhFailed) as comment:
        gh.issue_comment(5, "/dev/null")

    assert body.value.stderr == "HTTP 502: Bad Gateway\nsecond line\n"
    assert comment.value.stderr == "fake gh: adapter_issue_comment failed\n"
    assert gh.issue_state_labels(5) == ("OPEN", [])


def test_a_fail_after_countdown_lets_the_first_calls_through(seed, store):
    seed.issue(5, "open")
    seed.fail_after("adapter_issue_state_labels", 2, "boom")
    gh = fake(store)

    answers = [gh.issue_state_labels(5), gh.issue_state_labels(5)]
    with pytest.raises(GhFailed):
        gh.issue_state_labels(5)

    assert answers == [("OPEN", []), ("OPEN", [])]


def test_a_fail_times_countdown_is_a_failure_that_lifts_itself(seed, store):
    seed.issue(5, "open")
    seed.fail_times("adapter_issue_parent", 2, "HTTP 502")
    gh = fake(store)

    failures = []
    for _ in range(2):
        with pytest.raises(GhFailed) as failed:
            gh.issue_parent(5)
        failures.append(failed.value.stderr)

    assert failures == ["HTTP 502", "HTTP 502"]
    assert gh.issue_parent(5) is None
    assert not (store / "fail" / "adapter_issue_parent").exists()


def test_offline_fails_every_operation_with_a_connection_error(seed, store):
    seed.issue(5, "open")
    seed.offline()

    with pytest.raises(GhFailed) as failed:
        fake(store).issue_open_blockers(5)

    assert failed.value.stderr == "dial tcp: lookup api.github.com: no such host\n"


def test_a_rate_limit_flag_fails_through_the_limit_handler_with_the_seeded_quota(seed, store):
    seed.issue(5, "open")
    seed.quota("core", 0, 5000, 2000000000)
    seed.quota("graphql", 7, 5000, 2100000000)
    seed.ratelimit()

    with pytest.raises(GhFailed) as failed:
        fake(store).issue_body(5)

    assert failed.value.stderr.startswith(
        "orch: GitHub API rate limit reached - it resets at 2033-05-18T03:33:20Z.")


def test_a_secondary_limit_flag_is_waited_out_once_then_given_up_on(seed, store):
    seed.issue(5, "open")
    seed.ratelimit(SECONDARY)
    sleeps = []

    with pytest.raises(GhFailed) as failed:
        fake(store, sleeps, ORCH_GH_LIMIT_WAIT="1").issue_body(5)

    assert sleeps == [1.0]
    assert "secondary rate limit" not in failed.value.stderr
    assert failed.value.stderr.startswith("orch: GitHub API rate limit reached")


def test_a_failing_quota_read_leaves_the_reset_15_minutes_on(seed, store):
    seed.issue(5, "open")
    seed.ratelimit("was submitted too quickly")
    seed.fail_times("adapter_rate_limit", 1, "HTTP 502: Bad Gateway")

    with pytest.raises(GhFailed) as failed:
        fake(store).issue_body(5)

    assert "resets at 2030-03-17T18:01:40Z." in failed.value.stderr


def test_a_secondary_limit_the_retry_clears_answers(seed, store):
    seed.issue(5, "open")
    seed.body(5, "Body.")
    seed.fail_times("adapter_issue_body", 1, SECONDARY)

    assert fake(store).issue_body(5) == "Body."


def test_a_close_with_a_comment_gives_up_at_a_first_secondary_limit(seed, store):
    seed.issue(5, "open")
    seed.fail_times("adapter_issue_close", 1, SECONDARY)
    gh = fake(store)

    with pytest.raises(GhFailed):
        gh.issue_close(5, reason="completed", comment="done")
    state = held(store, "issues", 5, "state")
    seed.fail_times("adapter_issue_close", 1, SECONDARY)
    gh.issue_close(5, reason="completed")

    assert state == "OPEN\n"
    assert held(store, "issues", 5, "state") == "CLOSED\n"


def test_a_relabel_naming_nothing_cannot_fail(seed, store):
    seed.issue(5, "open")
    seed.fail("adapter_issue_relabel")

    assert fake(store).issue_relabel(5) is None


def test_each_comment_list_read_is_logged(seed, store):
    seed.issue(5, "open")
    seed.fail("adapter_issue_comments")
    gh = fake(store)

    for _ in range(2):
        with pytest.raises(GhFailed):
            gh.issue_comments(5)

    assert (store / "comment_reads").read_text() == "x\nx\n"


# --- the seeders write the store layout ----------------------------------------


def test_the_issue_seeders_write_the_store_layout(seed, store):
    seed.issue(5, "open", "bug", "ready-for-agent")
    seed.title(5, "A title")
    seed.body(5, "Body\r\n")
    seed.comment(5, "ann", "2026-02-01T00:00:00Z", "Hi.", "NONE")
    seed.issue(6, "closed")
    seed.next_issue(30)

    assert [held(store, "issues", 5, name) for name in ("state", "title", "labels", "body")] == [
        "OPEN\n", "A title\n", "bug\nready-for-agent\n", "Body\r\n"]
    assert [held(store, "issues", 5, "comments", 1, name)
            for name in ("author", "association", "created", "body")] == [
        "ann\n", "NONE\n", "2026-02-01T00:00:00Z\n", "Hi."]
    assert (held(store, "issues", 6, "state"), held(store, "next_issue")) == ("CLOSED\n", "30\n")


def test_the_seeded_failures_fail_and_lift_as_seeded(seed, store):
    seed.issue(5, "open")
    seed.fail("adapter_issue_body", "HTTP 502")
    seed.fail_times("adapter_issue_state_labels", 1, "transient")
    gh = fake(store)

    with pytest.raises(GhFailed) as body:
        gh.issue_body(5)
    with pytest.raises(GhFailed) as first:
        gh.issue_state_labels(5)

    assert (body.value.stderr, first.value.stderr) == ("HTTP 502\n", "transient")
    assert gh.issue_state_labels(5) == ("OPEN", [])

    seed.unfail()
    seed.offline()
    with pytest.raises(GhFailed):
        fake(store).issue_body(5)
    seed.online()
    assert fake(store).issue_body(5) == ""


def test_a_lag_seeded_after_current_reads_answers_current_stale_then_current(seed, store):
    seed.issue(5, "open", "ready")
    seed.title(5, "Current")
    seed.lag_after("adapter_issue_title_labels", 1, 1, "Stale\nold-label")
    gh = fake(store)

    assert [gh.issue_title_labels(5) for _ in range(3)] == [
        ("Current", ["ready"]), ("Stale", ["old-label"]), ("Current", ["ready"])]


# --- the operations the pr noun adds ------------------------------------------


def test_the_pr_reads_of_a_seeded_store_read_as_gh_answers_them(seed, store):
    seed.pr(4, "open", "topic", "main")
    seed.pr_draft(4)
    seed.pr_head(4, "abc123")
    seed.pr_labels(4, "bug", "Needs Human")
    seed.pr_diff(4, "diff --git a/x b/x\n+y\n")
    seed.pr(5, "merged", "other", "next")
    seed.issue(7, "open")
    seed.issue_created(7, "2026-03-01T12:00:00Z")
    seed.issue(8, "open")
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


def test_the_pr_listings_of_a_seeded_store_read_as_gh_lists_them(seed, store):
    seed.pr(4, "open", "topic", "main")
    seed.pr_body(4, 'Refs #3\r\n\nBody\t"q"')
    seed.pr(9, "open", "fork", "main")
    seed.pr_cross(9)
    seed.pr(6, "closed", "old", "main")
    seed.pr(10, "merged", "orch/5-x", "main")
    seed.pr_merged(10, "2026-03-02T00:00:00Z", 5, 7)
    seed.pr_body(10, "Closes #5")
    seed.pr(11, "merged", "quick/6-y", "main")
    seed.pr_cross(11)
    seed.pr_merged(11, "2026-03-01T00:00:00Z")
    seed.pr(12, "merged", "orch/8-z", "main")
    seed.pr_merged(12, "2026-02-28T23:59:59Z")
    seed.pr_body(12, "Refs #8")
    seed.pr(13, "merged", "orch/9-w", "next")
    gh = fake(store)

    assert gh.prs_open_bodies() == ['9\t""\ttrue', '4\t"Refs #3\\r\\n\\nBody\\t\\"q\\""\tfalse']
    assert gh.prs_merged_closing("main", "2026-03-01T00:00:00Z") == [
        "11\tquick/6-y\t2026-03-01T00:00:00Z\t\ttrue",
        "10\torch/5-x\t2026-03-02T00:00:00Z\t5,7\tfalse"]
    assert gh.prs_merged_bodies("main") == "Refs #8\n\nCloses #5\n"


def test_the_label_details_and_open_mergeability_of_a_seeded_store(seed, store):
    seed.label("Bug", "d73a4a", "Something is wrong")
    seed.label("bare", "ededed", "")
    seed.pr(4, "open", "orch/3-x", "main")
    seed.pr_mergeable(4, "CONFLICTING")
    seed.pr(9, "open", "fork", "main")
    seed.pr_cross(9)
    seed.pr(6, "closed", "orch/6-z", "main")
    seed.pr_mergeable(6, "CONFLICTING")
    gh = fake(store)

    one = [("Bug", "d73a4a", "Something is wrong")]
    assert (gh.labels_detail(1), gh.labels_detail(1000)) == (one, one + [("bare", "ededed", "")])
    assert gh.prs_open_mergeability() == ["9\tfork\tUNKNOWN\ttrue",
                                          "4\torch/3-x\tCONFLICTING\tfalse"]
    assert (held(store, "labels"), held(store, "prs", 4, "mergeable")) == (
        "Bug\td73a4a\tSomething is wrong\nbare\tededed\t\n", "CONFLICTING\n")


RUNS = "https://github.com/acme/widgets/actions/runs"
EXT_CI = "https://ci.example.com/build/9"
# What each scripted checks answer reads as, in adapter_pr_checks's TSV shape:
# the bash fake's answers when it still had the operation.
SCRIPTED_CHECKS = {
    "green": "pass\tbuild\t%s/1/job/1\n" % RUNS,
    "failing": "fail\tbuild\t%s/4242/job/77\npass\tlint\t%s/1/job/1\n" % (RUNS, RUNS),
    "cancel": "cancel\tbuild\t%s/5150/job/9\n" % RUNS,
    "external": "pass\tlint\t%s/1/job/1\nfail\text-ci\t%s\nfail\tbuild\t%s/4242/job/77\n"
                % (RUNS, EXT_CI, RUNS),
    "tworuns": "fail\tbuild\t%s/4242/job/77\nfail\ttest\t%s/4343/job/78\n" % (RUNS, RUNS),
    "onerun": "fail\tbuild\t%s/4242/job/77\nfail\ttest\t%s/4242/job/78\n" % (RUNS, RUNS),
    "mixed": "fail\tbuild\t%s/4242/job/77\nfail\text-ci\t%s\n" % (RUNS, EXT_CI),
    "badrunid": "fail\tbuild\t%s/12abc\n" % RUNS,
    "comma": "fail\tbuild (linux, x64)\t%s/4242/job/77\n" % RUNS,
    "pending": "pending\tbuild\t\n",
    "none": "",
    "empty": "",
}


@pytest.mark.parametrize("answer", sorted(SCRIPTED_CHECKS))
def test_each_scripted_checks_answer_reads_as_its_checks(seed, store, answer):
    seed.checks(4, "all", answer)

    assert "".join("\t".join(check) + "\n" for check in fake(store).pr_checks(4, "all")) == (
        SCRIPTED_CHECKS[answer])


@pytest.mark.parametrize("scope, answer, says", [
    ("all", "none", "no checks reported on the 'topic' branch\n"),
    ("all", "empty", ""),
    ("required", "green", "no checks reported on the 'topic' branch\n"),
], ids=["none", "empty", "unscripted"])
def test_no_checks_carry_gh_s_no_checks_line_but_an_empty_list(seed, store, scope, answer, says):
    seed.checks(4, scope, answer)

    assert fake(store).pr_checks(4, "all").reported == says


def test_a_checks_script_answers_one_per_call_the_last_repeating_an_unscripted_scope_none(
        seed, store):
    seed.checks(4, "required", "pending", "green")
    gh = fake(store)

    answers = [gh.pr_checks(4, "required") for _ in range(3)]

    green = [Check("pass", "build", RUNS + "/1/job/1")]
    assert answers == [[Check("pending", "build", "")], green, green]
    assert gh.pr_checks(4, "all") == []
    assert (store / "checks" / "4" / "reads").read_text() == "read\n" * 4


def test_a_boom_or_unknown_checks_answer_fails(seed, store):
    seed.checks(4, "all", "boom")
    seed.checks(5, "all", "bogus")

    with pytest.raises(GhFailed) as boom:
        fake(store).pr_checks(4, "all")
    with pytest.raises(GhFailed) as bogus:
        fake(store).pr_checks(5, "all")

    assert boom.value.stderr == "dial tcp: lookup api.github.com: no such host\n"
    assert bogus.value.stderr == "gh fake: no checks answer named 'bogus'\n"


def test_the_fake_s_pr_writes_land_in_the_store_layout(seed, store, tmp_path):
    seed.label("Needs-Human", "0e8a16", "")
    seed.pr(4, "open", "topic", "main")
    seed.pr_draft(4)
    seed.pr_labels(4, "bug")
    seed.pr(5, "open", "other", "main")
    seed.next_pr(40)
    (store / "pr_label_drops").write_text("Dropped\n")
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
    assert [(held(store, "prs", n, "state"), held(store, "prs", n, "head"),
             held(store, "prs", n, "base"), held(store, "prs", n, "title"),
             (store / "prs" / str(n) / "draft").exists(), held(store, "prs", n, "body"),
             held(store, "prs", n, "labels"), comment_bodies(store, "prs", n))
            for n in (40, 41, 4, 5)] == [
        ("OPEN\n", "orch/3-x\n", "main\n", "New PR\n", True, "Closes #3\r\n",
         "Needs-Human\nbug\n", []),
        ("OPEN\n", "quick/4-y\n", "next\n", "Plain\n", False, "A note.", "", []),
        ("OPEN\n", "topic\n", "main\n", "Retitled\n", False, "Closes #3\r\n",
         "bug\nNeeds-Human\n", ["A note."]),
        ("OPEN\n", "other\n", "main\n", "", True, "", "", []),
    ]
    assert gh.pr_state_draft(40) == ("OPEN", True)


def test_the_pr_seeders_write_merges_creation_times_and_the_next_number(seed, store):
    seed.issue(7, "open")
    seed.issue_created(7, "2026-03-01T12:00:00Z")
    seed.pr(4, "open", "topic", "main")
    seed.pr_labels(4, "bug", "wip")
    seed.pr_head(4, "abc123")
    seed.pr(10, "merged", "orch/7-x", "main")
    seed.pr_merged(10, "2026-03-02T00:00:00Z", 7, 9)
    seed.next_pr(50)

    assert [held(store, *parts) for parts in (
        ("issues", 7, "created_at"), ("prs", 4, "labels"), ("prs", 4, "head_oid"),
        ("prs", 10, "merged_at"), ("prs", 10, "closing"), ("next_pr",))] == [
        "2026-03-01T12:00:00Z\n", "bug\nwip\n", "abc123\n", "2026-03-02T00:00:00Z\n",
        "7\n9\n", "50\n"]


def test_a_seeded_checks_script_is_laid_out_one_answer_per_line(seed, store):
    seed.checks(4, "required", "failing", "green")

    assert (store / "checks" / "4" / "required").read_text() == "failing\ngreen\n"
    assert [fake(store).pr_checks(4, "required") for _ in range(3)] == [
        [Check("fail", "build", RUNS + "/4242/job/77"), Check("pass", "lint", RUNS + "/1/job/1")],
        [Check("pass", "build", RUNS + "/1/job/1")],
        [Check("pass", "build", RUNS + "/1/job/1")],
    ]


# --- the review noun's reads and its rerun -------------------------------------

HEAD = "a" * 40
EARLIER = "b" * 40


def test_the_review_reads_of_a_store_written_raw_answer_as_the_store_holds_them(store):
    # The store as its layout writes it, raw.
    for n, head, base in ((7, "topic", "main"), (8, "other", "next"), (9, "bare", "main")):
        pr = store / "prs" / str(n)
        pr.mkdir(parents=True)
        (pr / "state").write_text("OPEN\n")
        (pr / "head").write_text(head + "\n")
        (pr / "base").write_text(base + "\n")
    (store / "prs" / "7" / "head_oid").write_text(HEAD + "\n")
    (store / "prs" / "7" / "commits").write_text("%s\n%s\n" % (EARLIER, HEAD))
    (store / "prs" / "7" / "url").write_text("https://ghe.example.com/x/y/pull/7\n")
    (store / "prs" / "9" / "head_oid").write_text("")
    for name in ("protection", "rules", "job_logs"):
        (store / name).mkdir()
    (store / "protection" / "main").write_text("build\nlint\n")
    (store / "rules" / "main").write_text("deletion\nrequired_status_checks\n")
    (store / "check_runs").write_text("main\n%s\n" % EARLIER)
    (store / "statuses").write_text("next\n")
    (store / "job_logs" / "77").write_text("build\tstep\tline one\n")
    gh = fake(store)

    assert gh.pr_url_head(7) == ("https://ghe.example.com/x/y/pull/7", HEAD)
    assert gh.pr_url_head(8) == ("https://github.com/o/r/pull/8", "0" * 40)
    assert gh.branch_required_checks("main") == ["build", "lint"]
    assert gh.branch_required_checks("open") == []
    assert gh.branch_rules("main") == ["deletion", "required_status_checks"]
    assert gh.branch_rules("bare") == []
    assert gh.pr_commits_checked(7) == ("yes", [(EARLIER, "yes"), (HEAD, "no")])
    assert gh.pr_commits_checked(8) == ("yes", [("0" * 40, "no")])
    assert gh.pr_commits_checked(9) == ("yes", [])
    assert gh.job_failed_log(77) == "build\tstep\tline one\n"


def test_seeded_review_reads_write_the_store_layout(seed, store):
    seed.pr(7, "open", "topic", "main")
    seed.pr_head(7, HEAD, EARLIER, HEAD)
    seed.pr(8, "open", "other", "next")
    seed.pr_head(8, HEAD, EARLIER)
    seed.pr_head(8, "")
    seed.pr_url(7, "https://ghe.example.com/x/y/pull/7")
    seed.required_checks("main", "build", "lint")
    seed.rules("main", "required_status_checks")
    seed.check_run(EARLIER)
    seed.status("main")
    seed.job_log(77, "log line 1\nlog line 2\n")
    gh = fake(store)

    assert [held(store, *parts) for parts in (
        ("prs", 7, "url"), ("prs", 7, "head_oid"), ("prs", 7, "commits"),
        ("protection", "main"), ("rules", "main"), ("check_runs",), ("statuses",),
        ("job_logs", 77))] == [
        "https://ghe.example.com/x/y/pull/7\n", HEAD + "\n", "%s\n%s\n" % (EARLIER, HEAD),
        "build\nlint\n", "required_status_checks\n", EARLIER + "\n", "main\n",
        "log line 1\nlog line 2\n"]
    assert gh.pr_url_head(7) == ("https://ghe.example.com/x/y/pull/7", HEAD)
    assert gh.branch_required_checks("main") == ["build", "lint"]
    assert gh.branch_rules("main") == ["required_status_checks"]
    assert gh.job_failed_log(77) == "log line 1\nlog line 2\n"
    assert gh.pr_commits_checked(7) == ("yes", [(EARLIER, "yes"), (HEAD, "no")])
    assert gh.pr_commits_checked(8) == ("no", [])


def test_a_pr_s_evidence_read_is_logged_and_its_raw_answer_or_missing_base_ref_honoured(store):
    seed = FakeStore(str(store))
    seed.pr(7, "open", "topic", "main")
    seed.pr_head(7, HEAD)
    seed.pr(8, "open", "other", "main")
    seed.check_run("main")
    seed.no_base_ref(7)
    seed.evidence_raw(8, "no", EARLIER + "\tmaybe", "not-a-sha")
    gh = fake(store)

    assert gh.pr_commits_checked(7) == ("", [(HEAD, "no")])
    assert gh.pr_commits_checked(8) == ("no", [(EARLIER, "maybe"), ("not-a-sha", "")])
    assert gh.pr_commits_checked(8) == ("no", [(EARLIER, "maybe"), ("not-a-sha", "")])
    assert (seed.evidence_reads(7), seed.evidence_reads(8)) == (1, 2)


def test_a_review_read_of_a_pr_the_store_lacks_fails_as_gh_does(store):
    gh = fake(store)

    for call in (lambda: gh.pr_url_head(5), lambda: gh.pr_commits_checked(5)):
        with pytest.raises(GhFailed) as failed:
            call()
        assert "Could not resolve to a PullRequest with the number of 5" in failed.value.stderr


def test_python_reruns_are_kept_in_order_in_the_store_layout(store):
    seed = FakeStore(str(store))
    gh = fake(store)

    gh.run_rerun(4242)
    gh.run_rerun(4343)
    gh.run_rerun(5150)

    assert seed.reruns() == ["4242", "4343", "5150"]
    assert (store / "reruns").read_text() == "4242\n4343\n5150\n"


def test_a_job_log_the_store_lacks_cannot_be_read(store):
    with pytest.raises(GhFailed) as failed:
        fake(store).job_failed_log(78)

    assert failed.value.stderr == "log not found\n"


def test_a_pr_create_carrying_a_label_gives_up_at_a_first_secondary_limit(seed, store, tmp_path):
    seed.fail_times("adapter_pr_create", 1, SECONDARY)
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


def test_issue_comment_url_answers_the_posted_comment_s_url(seed, store, tmp_path):
    seed.issue(5, "open")
    seed.comment(5, "alice", "2026-01-01T00:00:00Z", "first")
    note = tmp_path / "note.md"
    note.write_text("A note.")
    gh = fake(store)

    assert gh.issue_comment_url(5, str(note)) == "https://github.com/o/r/issues/5#issuecomment-2"
    (store / "no_comment_url").write_text("")
    assert gh.issue_comment_url(5, str(note)) == ""
    assert comment_bodies(store, "issues", 5) == ["first", "A note.", "A note."]


def test_issues_open_rows_lists_the_open_issues_oldest_first(seed, store, capsys):
    seed.issue(3, "open", "bug")
    seed.issue(1, "open")
    seed.issue(2, "closed")

    assert fake(store).issues_open_rows() == [StateRow(1, "OPEN", []),
                                              StateRow(3, "OPEN", ["bug"])]
    assert fake(store, ORCH_ISSUE_LIST_LIMIT="1").issues_open_rows() == [StateRow(1, "OPEN", [])]
    assert capsys.readouterr().err == ("orch: the open issues reached the issue-list limit of 1"
                                       " - the newest past it are missing from this list\n")


def test_issues_labelled_rows_lists_the_open_issues_carrying_every_label(seed, store, capsys):
    seed.issue(3, "open", "needs-human", "orch:spec")
    seed.issue(1, "open", "Needs-Human")
    seed.issue(2, "closed", "needs-human")
    seed.issue(4, "open", "orch:spec")

    assert fake(store).issues_labelled_rows("needs-human") == [
        StateRow(1, "OPEN", ["Needs-Human"]), StateRow(3, "OPEN", ["needs-human", "orch:spec"])]
    assert fake(store).issues_labelled_rows("needs-human", "orch:spec") == [
        StateRow(3, "OPEN", ["needs-human", "orch:spec"])]
    assert fake(store, ORCH_ISSUE_LIST_LIMIT="1").issues_labelled_rows("needs-human") == [
        StateRow(1, "OPEN", ["Needs-Human"])]
    assert capsys.readouterr().err == (
        "orch: the open issues labelled needs-human reached the issue-list limit of 1"
        " - the newest past it are missing from this list\n")


def test_issues_any_labelled_rows_lists_the_open_issues_carrying_any_label(seed, store, capsys):
    seed.issue(3, "open", "orch:spec")
    seed.issue(1, "open", "Orch:Sync", "orch:done")
    seed.issue(2, "closed", "orch:spec")
    seed.issue(4, "open", "bug")

    assert fake(store).issues_any_labelled_rows("orch:spec", "orch:sync") == [
        StateRow(1, "OPEN", ["Orch:Sync", "orch:done"]), StateRow(3, "OPEN", ["orch:spec"])]
    assert fake(store, ORCH_ISSUE_LIST_LIMIT="1").issues_any_labelled_rows(
        "orch:spec", "orch:sync") == [StateRow(1, "OPEN", ["Orch:Sync", "orch:done"])]
    assert capsys.readouterr().err == (
        "orch: the open issues labelled orch:spec or orch:sync reached the issue-list limit of 1"
        " - the newest past it are missing from this list\n")


def test_a_claim_the_fake_creates_is_held_as_one_tsv_line(seed, store):
    gh = fake(store)

    assert gh.claim_create(5, "review", 42, "thishost", "2026-03-04T05:06:07Z") is True

    assert seed.claim_held(5) is True
    assert (store / "claims" / "5").read_text() == "5\tthishost\t42\treview\t2026-03-04T05:06:07Z\n"


def test_a_claim_create_on_a_held_claim_loses_the_race_leaving_it_as_it_was(seed, store):
    seed.claim(5)
    held_claim = (store / "claims" / "5").read_text()

    assert fake(store).claim_create(5, "review", 42, "thishost", "2026-03-04T05:06:07Z") is False
    assert (store / "claims" / "5").read_text() == held_claim


def test_a_claim_create_fails_as_seeded(store):
    FakeStore(str(store)).fail("adapter_claim_create", "HTTP 500")

    with pytest.raises(GhFailed) as failed:
        fake(store).claim_create(5, "spec", 1, "thishost", "2026-03-04T05:06:07Z")

    assert (failed.value.stderr, (store / "claims" / "5").exists()) == ("HTTP 500\n", False)
