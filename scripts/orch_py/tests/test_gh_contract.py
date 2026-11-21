"""Contract tests of the real gh adapter (ADR-0033): each operation run
against a fixture gh on PATH that answers by exact argv, proving the argv it
hands gh, how it reads the answer, the repo pin and its remedy, the rate-limit
handling and the `gh could not <action>` death."""
from __future__ import annotations

import json

import pytest

from orch.gh import Gh, GhFailed, IssueRow, Unparsed, gh_die, gh_or_die
from orch.git import FakeGit
from orch.repo import REPO_REMEDY, RepoPin

FORK = "https://github.com/fork/widgets.git"
BODY = ["issue", "view", "5", "--json", "body", "--jq", ".body"]
RATE_LIMIT = [
    "api",
    "rate_limit",
    "--jq",
    ".resources | {core, graphql} | to_entries[] | "
    "[.key, .value.remaining, .value.limit, .value.reset] | @tsv",
]
NOW = 1_900_000_000
LIMIT_TAIL = (
    ". An autopilot session ends its turn now and does not retry; the watcher"
    " picks the work up after the reset."
)


def identity_ssh(host):
    return host


def real_gh(fixture_gh, origin=FORK, ssh_lookup=identity_ssh, sleeps=None, **env):
    """The real adapter on the fixture gh, its repo resolved from a fake
    origin (none when <origin> is None) and the environment named."""
    env = dict(env, PATH=fixture_gh.path())
    remotes = {} if origin is None else {"origin": origin}
    pin = RepoPin(env, FakeGit(remotes), ssh_lookup=ssh_lookup)
    slept = sleeps if sleeps is not None else []
    return Gh(pin, env, sleep=slept.append, now=lambda: NOW)


# --- the repo pin ------------------------------------------------------------


def test_every_call_is_pinned_to_the_origin_repo_and_github_com(fixture_gh):
    fixture_gh.reply(BODY, "Body.\n")
    gh = real_gh(fixture_gh, GH_HOST="other.example.com")

    assert gh.issue_body(5) == "Body."
    assert fixture_gh.calls() == [("fork/widgets", "github.com", BODY)]


def test_a_user_set_owner_repo_keeps_the_users_gh_host(fixture_gh):
    fixture_gh.reply(BODY, "Body.\n")

    real_gh(fixture_gh, origin=None, GH_REPO="fork/widgets", GH_HOST="ghe.example.com").issue_body(5)
    real_gh(fixture_gh, origin=None, GH_REPO="fork/widgets").issue_body(5)

    assert fixture_gh.calls() == [
        ("fork/widgets", "ghe.example.com", BODY),
        ("fork/widgets", None, BODY),
    ]


def test_a_host_qualified_origin_pins_its_repo_and_its_host(fixture_gh):
    fixture_gh.reply(BODY, "Body.\n")

    real_gh(fixture_gh, origin="git@ghe.example.com:fork/widgets.git").issue_body(5)

    assert fixture_gh.calls() == [
        ("ghe.example.com/fork/widgets", "ghe.example.com", BODY)
    ]


def test_an_ssh_alias_origin_is_resolved_through_ssh_once(fixture_gh):
    fixture_gh.reply(BODY, "Body.\n")
    asked = []

    def alias(host):
        asked.append(host)
        return "ghe.example.com"

    gh = real_gh(fixture_gh, origin="git@github-work:fork/widgets.git", ssh_lookup=alias)
    gh.issue_body(5)
    gh.issue_body(5)

    assert asked == ["github-work"]
    assert {call[:2] for call in fixture_gh.calls()} == {
        ("ghe.example.com/fork/widgets", "ghe.example.com")
    }


def test_with_no_repo_a_call_dies_with_the_remedy_and_reaches_no_gh(fixture_gh, capsys):
    gh = real_gh(fixture_gh, origin=None)

    with pytest.raises(SystemExit) as died:
        gh.issue_body(5)

    assert died.value.code == 1
    assert capsys.readouterr().err == "orch: " + REPO_REMEDY + "\n"
    assert REPO_REMEDY.endswith("set GH_REPO=<owner>/<repo>")
    assert fixture_gh.calls() == []


def test_pin_answers_whether_a_repo_resolves_without_calling_gh(fixture_gh):
    assert real_gh(fixture_gh).pin() is True
    assert real_gh(fixture_gh, origin=None).pin() is False
    assert real_gh(fixture_gh, origin="/a/local/bare.git").pin() is False
    assert fixture_gh.calls() == []


# --- issue reads -------------------------------------------------------------


def test_issue_body_keeps_carriage_returns_and_drops_only_gh_s_newline(fixture_gh):
    fixture_gh.reply(BODY, "one\r\ntwo\n\n\n")

    assert real_gh(fixture_gh).issue_body(5) == "one\r\ntwo\n\n"


def test_issue_json_is_the_trimmed_issue_object(fixture_gh):
    argv = ["issue", "view", "5", "--json", "number,title,body,labels",
            "--jq", "{number, title, body, labels: [.labels[].name]}"]
    fixture_gh.reply(argv, '{"number":5,"title":"T","body":"B","labels":["bug"]}\n')

    assert real_gh(fixture_gh).issue_json(5) == {
        "number": 5, "title": "T", "body": "B", "labels": ["bug"]
    }


@pytest.mark.parametrize("answer", ["not json\n", "[1, 2]\n"])
def test_issue_json_that_is_not_an_issue_object_is_unparsed(fixture_gh, answer):
    argv = ["issue", "view", "5", "--json", "number,title,body,labels",
            "--jq", "{number, title, body, labels: [.labels[].name]}"]
    fixture_gh.reply(argv, answer)

    with pytest.raises(Unparsed):
        real_gh(fixture_gh).issue_json(5)


def test_issue_comments_are_gh_s_raw_comment_objects(fixture_gh):
    comment = {"author": {"login": "ann"}, "authorAssociation": "OWNER",
               "createdAt": "2026-01-01T00:00:00Z", "body": "Hi", "url": "u"}
    fixture_gh.reply(["issue", "view", "5", "--json", "comments"],
                     '{"comments": [%s]}\n' % json.dumps(comment))

    assert real_gh(fixture_gh).issue_comments(5) == [comment]


@pytest.mark.parametrize("answer", ["nope\n", '{"comments": 3}\n', "[]\n"])
def test_issue_comments_that_are_no_comment_list_are_unparsed(fixture_gh, answer):
    fixture_gh.reply(["issue", "view", "5", "--json", "comments"], answer)

    with pytest.raises(Unparsed):
        real_gh(fixture_gh).issue_comments(5)


def test_issue_state_labels_reads_the_state_then_the_labels(fixture_gh):
    argv = ["issue", "view", "5", "--json", "state,labels",
            "--jq", ".state, (.labels[].name)"]
    fixture_gh.reply(argv, "OPEN\nbug\nready-for-agent\n")
    fixture_gh.reply(["issue", "view", "6", "--json", "state,labels",
                      "--jq", ".state, (.labels[].name)"], "CLOSED\n")
    gh = real_gh(fixture_gh)

    assert gh.issue_state_labels(5) == ("OPEN", ["bug", "ready-for-agent"])
    assert gh.issue_state_labels(6) == ("CLOSED", [])


def test_issue_state_labels_body_splits_on_the_label_count(fixture_gh):
    jq = ".state, (.labels | length), (.labels[].name), .body"
    fixture_gh.reply(["issue", "view", "5", "--json", "state,labels,body", "--jq", jq],
                     "OPEN\n2\nbug\nwip\nline one\nline two\n\n")
    fixture_gh.reply(["issue", "view", "6", "--json", "state,labels,body", "--jq", jq],
                     "OPEN\nmany\n")
    gh = real_gh(fixture_gh)

    assert gh.issue_state_labels_body(5) == ("OPEN", ["bug", "wip"], "line one\nline two")
    with pytest.raises(GhFailed) as failed:
        gh.issue_state_labels_body(6)
    assert failed.value.stderr == "gh answered no label count"


def test_issue_title_labels_reads_the_title_then_the_labels(fixture_gh):
    fixture_gh.reply(["issue", "view", "5", "--json", "title,labels",
                      "--jq", ".title, (.labels[].name)"], "A title\nready-for-agent\n")

    assert real_gh(fixture_gh).issue_title_labels(5) == ("A title", ["ready-for-agent"])


TITLED_JQ = '.[] | .number, (.state + "\\t" + .title), (.labels | length), (.labels[].name)'


def titled_argv(label, limit="1000"):
    return ["issue", "list", "--state", "open", "--label", label, "--search",
            "sort:created-asc", "--limit", limit, "--json", "number,state,title,labels",
            "--jq", TITLED_JQ]


def test_issues_titled_rows_reads_each_count_marked_record(fixture_gh, capsys):
    fixture_gh.reply(titled_argv("ready-for-agent"),
                     "7\nOPEN\tFirst\t tab\n2\nready-for-agent\nbug\n012\nCLOSED\tSecond\n0\n")

    assert real_gh(fixture_gh).issues_titled_rows("ready-for-agent") == [
        IssueRow(7, "OPEN", "First\t tab", ["ready-for-agent", "bug"]),
        IssueRow(12, "CLOSED", "Second", []),
    ]
    assert capsys.readouterr().err == ""


@pytest.mark.parametrize("answer", ["x\nOPEN\tT\n0\n", "7\nOPEN\tT\n3\na\n", "7\n"])
def test_a_titled_listing_that_does_not_parse_fails(fixture_gh, answer):
    fixture_gh.reply(titled_argv("ready-for-agent"), answer)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).issues_titled_rows("ready-for-agent")
    assert failed.value.stderr == "gh answered a listing that does not parse"


def test_a_titled_listing_at_the_issue_list_limit_warns(fixture_gh, capsys):
    fixture_gh.reply(titled_argv("ready", "2"), "1\nOPEN\tA\n0\n2\nOPEN\tB\n0\n")

    rows = real_gh(fixture_gh, ORCH_ISSUE_LIST_LIMIT="2").issues_titled_rows("ready")

    assert [row.number for row in rows] == [1, 2]
    assert capsys.readouterr().err == (
        "orch: the open issues labelled ready reached the issue-list limit of 2"
        " - the newest past it are missing from this list\n"
    )


def test_the_issue_list_limit_stops_at_github_s_search_cap(fixture_gh, capsys):
    fixture_gh.reply(titled_argv("ready", "5000"), "1\nOPEN\tA\n0\n")

    real_gh(fixture_gh, ORCH_ISSUE_LIST_LIMIT="5000").issues_titled_rows("ready")

    assert capsys.readouterr().err == ""


PARENT = ["api", "repos/{owner}/{repo}/issues/5", "--jq", ".parent_issue_url // empty"]


def test_issue_parent_is_the_number_in_the_parent_url_or_none(fixture_gh):
    fixture_gh.reply(PARENT, "https://api.github.com/repos/o/r/issues/12\n")
    fixture_gh.reply(["api", "repos/{owner}/{repo}/issues/6", "--jq",
                      ".parent_issue_url // empty"], "")
    gh = real_gh(fixture_gh)

    assert gh.issue_parent(5) == 12
    assert gh.issue_parent(6) is None


def test_a_parent_url_with_no_issue_number_fails(fixture_gh):
    fixture_gh.reply(PARENT, "https://api.github.com/repos/o/r/issues/\n")

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).issue_parent(5)
    assert failed.value.stderr == (
        "gh api printed a parent URL with no issue number:"
        " https://api.github.com/repos/o/r/issues/"
    )


def test_issue_open_blockers_is_the_summary_count_or_none(fixture_gh):
    jq = '.issue_dependencies_summary.blocked_by // ""'
    fixture_gh.reply(["api", "repos/{owner}/{repo}/issues/5", "--jq", jq], "2\n")
    fixture_gh.reply(["api", "repos/{owner}/{repo}/issues/6", "--jq", jq], "\n")
    gh = real_gh(fixture_gh)

    assert gh.issue_open_blockers(5) == 2
    assert gh.issue_open_blockers(6) is None


def test_blockers_states_lists_each_blocker_and_its_state(fixture_gh):
    fixture_gh.reply(["api", "--paginate", "repos/{owner}/{repo}/issues/5/dependencies/blocked_by",
                      "--jq", '.[] | "\\(.number)\\t\\(.state | ascii_upcase)"'],
                     "3\tOPEN\n4\tCLOSED\n")

    assert real_gh(fixture_gh).blockers_states(5) == [(3, "OPEN"), (4, "CLOSED")]


AUTHORSHIP = [
    "api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-F", "number=5",
    "-f", "query=query($owner: String!, $name: String!, $number: Int!) { repository("
    "owner: $owner, name: $name) { issue(number: $number) { author { login }"
    " authorAssociation editor { login } timelineItems(last: 1, itemTypes:"
    " [RENAMED_TITLE_EVENT]) { nodes { ... on RenamedTitleEvent { actor { login } } } } } } }",
    "--jq", '.data.repository.issue | (.author.login // ""), (.authorAssociation // ""),'
    ' (.editor.login // ""), (.timelineItems.nodes[0].actor.login // "")',
]


@pytest.mark.parametrize("answer, authorship", [
    ("ann\nNONE\nbob\ncid\n", ("ann", "NONE", "bob", "cid")),
    ("ann\nOWNER\n\n\n", ("ann", "OWNER", "", "")),
    ("\n\n\n\n", ("", "", "", "")),
], ids=["all", "never-edited", "ghost"])
def test_issue_authorship_is_the_author_association_editor_and_renamer(fixture_gh, answer, authorship):
    fixture_gh.reply(AUTHORSHIP, answer)

    assert real_gh(fixture_gh).issue_authorship(5) == authorship


# --- issue writes ------------------------------------------------------------


def test_issue_create_files_under_each_label_and_answers_the_number(fixture_gh):
    fixture_gh.reply(["issue", "create", "--title", "T", "--body-file", "b.md",
                      "--label", "ready-for-agent", "--label", "bug"],
                     "Creating issue\nhttps://github.com/fork/widgets/issues/42\n")

    assert real_gh(fixture_gh).issue_create("T", "b.md", ["ready-for-agent", "bug"]) == 42


def test_an_issue_create_that_prints_no_issue_url_fails(fixture_gh):
    fixture_gh.reply(["issue", "create", "--title", "T", "--body-file", "b.md"], "done\n")

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).issue_create("T", "b.md", [])
    assert failed.value.stderr == "gh issue create printed no issue URL: done"


def test_issue_body_edit_and_comment_pass_the_file(fixture_gh):
    fixture_gh.reply(["issue", "edit", "5", "--body-file", "b.md"], "url\n")
    fixture_gh.reply(["issue", "comment", "5", "--body-file", "c.md"], "url\n")
    gh = real_gh(fixture_gh)

    assert gh.issue_body_edit(5, "b.md") is None
    assert gh.issue_comment(5, "c.md") is None
    assert fixture_gh.argvs() == [["issue", "edit", "5", "--body-file", "b.md"],
                                  ["issue", "comment", "5", "--body-file", "c.md"]]


def test_issue_relabel_is_one_edit_and_none_with_nothing_named(fixture_gh):
    argv = ["issue", "edit", "5", "--remove-label", "wip", "--remove-label", "needs-triage",
            "--add-label", "ready-for-agent"]
    fixture_gh.reply(argv)
    gh = real_gh(fixture_gh)

    gh.issue_relabel(5, add=["ready-for-agent"], remove=["wip", "needs-triage"])
    gh.issue_relabel(5)

    assert fixture_gh.argvs() == [argv]


def test_issue_close_as_completed_or_as_a_duplicate(fixture_gh):
    completed = ["issue", "close", "5", "--reason", "completed", "--comment", "Done."]
    duplicate = ["issue", "close", "5", "--comment", "Dup.", "--duplicate-of", "4"]
    fixture_gh.reply(completed)
    fixture_gh.reply(duplicate)
    gh = real_gh(fixture_gh)

    gh.issue_close(5, reason="completed", comment="Done.")
    gh.issue_close(5, comment="Dup.", duplicate_of=4)

    assert fixture_gh.argvs() == [completed, duplicate]


def test_a_failed_write_passes_gh_s_stderr_through(fixture_gh):
    fixture_gh.reply(["issue", "comment", "5", "--body-file", "c.md"],
                     stderr="HTTP 502: Bad Gateway\nsecond line\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).issue_comment(5, "c.md")
    assert failed.value.stderr == "HTTP 502: Bad Gateway\nsecond line\n"


# --- rate limits -------------------------------------------------------------

SECONDARY = "You have exceeded a secondary rate limit. Please wait a few minutes"


def pools(core_left, graphql_left):
    return "core\t%d\t5000\t2000000000\ngraphql\t%d\t5000\t2100000000\n" % (
        core_left, graphql_left)


def limit_failure(gh):
    with pytest.raises(GhFailed) as failed:
        gh.issue_body(5)
    return failed.value.stderr


def test_a_primary_limit_fails_once_naming_the_latest_exhausted_reset(fixture_gh):
    fixture_gh.reply(BODY, stderr="gh: API rate limit exceeded for user ID 1. (HTTP 403)\n", exit=1)
    fixture_gh.reply(RATE_LIMIT, pools(0, 0))
    sleeps = []

    stderr = limit_failure(real_gh(fixture_gh, sleeps=sleeps))

    assert stderr == (
        "orch: GitHub API rate limit reached - it resets at 2036-07-18T13:20:00Z"
        + LIMIT_TAIL + "\n"
    )
    assert fixture_gh.argvs() == [BODY, RATE_LIMIT]
    assert sleeps == []


def test_only_a_pool_at_zero_remaining_sets_the_reset(fixture_gh):
    fixture_gh.reply(BODY, stderr="API rate limit already exceeded\n", exit=1)
    fixture_gh.reply(RATE_LIMIT, pools(0, 12))

    assert "resets at 2033-05-18T03:33:20Z." in limit_failure(real_gh(fixture_gh))


@pytest.mark.parametrize("quota", [
    dict(stdout=pools(3, 4)),
    dict(stderr="HTTP 502: Bad Gateway\n", exit=1),
    dict(stdout=""),
], ids=["no-exhausted-pool", "failed-read", "empty-read"])
def test_with_no_exhausted_pool_to_read_the_reset_is_15_minutes_on(fixture_gh, quota):
    fixture_gh.reply(BODY, stderr="API rate limit exceeded\n", exit=1)
    fixture_gh.reply(RATE_LIMIT, **quota)

    assert "resets at 2030-03-17T18:01:40Z." in limit_failure(real_gh(fixture_gh))


@pytest.mark.parametrize("wording", [SECONDARY, "was submitted too quickly", "HTTP 429: Too Many Requests"])
def test_a_secondary_limit_is_waited_out_and_retried_once(fixture_gh, wording):
    fixture_gh.reply(BODY, stderr=wording + "\n", exit=1)
    fixture_gh.reply(RATE_LIMIT, pools(0, 5))
    sleeps = []

    stderr = limit_failure(real_gh(fixture_gh, sleeps=sleeps))

    assert sleeps == [60.0]
    assert fixture_gh.argvs() == [BODY, BODY, RATE_LIMIT]
    assert stderr.startswith("orch: GitHub API rate limit reached - it resets at 2033-05-18T03:33:20Z.")


def test_a_secondary_limit_the_retry_clears_answers_the_retry(fixture_gh):
    fixture_gh.reply(BODY, "partial\n", SECONDARY + "\n", 1, then=[("Body.\n", "", 0)])
    sleeps = []

    assert real_gh(fixture_gh, sleeps=sleeps, ORCH_GH_LIMIT_WAIT="0.5").issue_body(5) == "Body."
    assert sleeps == [0.5]


def test_a_close_with_a_comment_is_a_compound_write_given_up_at_once(fixture_gh):
    argv = ["issue", "close", "5", "--reason", "completed", "--comment", "done"]
    fixture_gh.reply(argv, stderr=SECONDARY + "\n", exit=1)
    fixture_gh.reply(RATE_LIMIT, pools(0, 5))
    sleeps = []

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh, sleeps=sleeps).issue_close(5, reason="completed", comment="done")

    assert failed.value.stderr.startswith("orch: GitHub API rate limit reached")
    assert fixture_gh.argvs() == [argv, RATE_LIMIT]
    assert sleeps == []


def test_a_bare_close_keeps_the_retry(fixture_gh):
    argv = ["issue", "close", "5", "--reason", "completed"]
    fixture_gh.reply(argv, stderr=SECONDARY + "\n", exit=1, then=[("", "", 0)])

    real_gh(fixture_gh).issue_close(5, reason="completed")

    assert fixture_gh.argvs() == [argv, argv]


def test_a_quota_read_meeting_a_limit_is_made_once(fixture_gh):
    fixture_gh.reply(BODY, stderr="API rate limit exceeded\n", exit=1)
    fixture_gh.reply(RATE_LIMIT, stderr=SECONDARY + "\n", exit=1)
    sleeps = []

    stderr = limit_failure(real_gh(fixture_gh, sleeps=sleeps))

    assert "resets at 2030-03-17T18:01:40Z." in stderr
    assert fixture_gh.argvs() == [BODY, RATE_LIMIT]
    assert sleeps == []


def test_a_failure_that_is_no_limit_passes_through_untouched(fixture_gh):
    fixture_gh.reply(BODY, stderr="HTTP 502: Bad Gateway\n", exit=1)
    sleeps = []

    assert limit_failure(real_gh(fixture_gh, sleeps=sleeps)) == "HTTP 502: Bad Gateway\n"
    assert fixture_gh.argvs() == [BODY]
    assert sleeps == []


# --- the gh could not death --------------------------------------------------


def died_of(capsys, run):
    with pytest.raises(SystemExit) as died:
        run()
    out, err = capsys.readouterr()
    return died.value.code, out, err


def test_a_failed_call_dies_naming_the_action_gh_s_first_line_and_the_hint(fixture_gh, capsys):
    argv = ["issue", "close", "5", "--comment", "Dup.", "--duplicate-of", "4"]
    fixture_gh.reply(argv, stderr="unknown flag: --duplicate-of\nUsage: gh issue close\n", exit=1)
    gh = real_gh(fixture_gh)

    code, out, err = died_of(capsys, lambda: gh_or_die(
        "close issue #5", gh.issue_close, 5, comment="Dup.", duplicate_of=4,
        hint="--duplicate-of needs gh 2.102 or newer"))

    assert (code, out) == (1, "")
    assert err == ("orch: gh could not close issue #5: unknown flag: --duplicate-of"
                   " - --duplicate-of needs gh 2.102 or newer\n")


def test_a_failure_with_an_empty_first_line_dies_saying_gh_gave_no_reason(capsys):
    code, _, err = died_of(capsys, lambda: gh_die("read issue #5", "\nsecond line\n"))

    assert (code, err) == (1, "orch: gh could not read issue #5: gh gave no reason\n")


def test_a_limit_given_up_on_dies_carrying_the_limit_message(fixture_gh, capsys):
    fixture_gh.reply(BODY, stderr="API rate limit exceeded\n", exit=1)
    fixture_gh.reply(RATE_LIMIT, pools(0, 0))
    gh = real_gh(fixture_gh)

    code, _, err = died_of(capsys, lambda: gh_or_die("read the body of issue #5", gh.issue_body, 5))

    assert code == 1
    assert err == ("orch: gh could not read the body of issue #5: orch: GitHub API rate limit"
                   " reached - it resets at 2036-07-18T13:20:00Z" + LIMIT_TAIL + "\n")
