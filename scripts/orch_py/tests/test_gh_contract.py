"""Contract tests of the real gh adapter (ADR-0033): each gh operation run
against a fixture gh on PATH that answers by exact argv, proving the argv it
hands gh, how it reads the answer, the repo pin and its remedy, the rate-limit
handling and the `gh could not <action>` death. The claim list and the claim
delete, the two git-backed operations, run instead against a real bare origin
under tmp_path."""
from __future__ import annotations

import json
import os

import pytest

from orch.gh import (Check, ClaimRow, Gh, GhFailed, IssueRow, LabelledBody, StateRow, SubIssue,
                     Unparsed, gh_die, gh_issue_not_found, gh_or_die)
from orch.git import FakeGit
from orch.repo import REPO_REMEDY, RepoPin

from conftest import died_of, git_identity, origin_clone, run_git

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

    code, _, err = died_of(capsys, lambda: gh.issue_body(5))

    assert (code, err) == (1, "orch: " + REPO_REMEDY + "\n")
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


ISSUE_JSON = ["issue", "view", "5", "--json", "number,title,body,labels",
              "--jq", "{number, title, body, labels: [.labels[].name]}"]


def test_issue_json_is_the_trimmed_issue_object(fixture_gh):
    fixture_gh.reply(ISSUE_JSON, '{"number":5,"title":"T","body":"B","labels":["bug"]}\n')

    assert real_gh(fixture_gh).issue_json(5) == {
        "number": 5, "title": "T", "body": "B", "labels": ["bug"]
    }


@pytest.mark.parametrize("answer", ["not json\n", "[1, 2]\n"])
def test_issue_json_that_is_not_an_issue_object_is_unparsed(fixture_gh, answer):
    fixture_gh.reply(ISSUE_JSON, answer)

    with pytest.raises(Unparsed):
        real_gh(fixture_gh).issue_json(5)


COMMENTS = ["issue", "view", "5", "--json", "comments"]


def test_issue_comments_are_gh_s_raw_comment_objects(fixture_gh):
    comment = {"author": {"login": "ann"}, "authorAssociation": "OWNER",
               "createdAt": "2026-01-01T00:00:00Z", "body": "Hi", "url": "u"}
    fixture_gh.reply(COMMENTS, '{"comments": [%s]}\n' % json.dumps(comment))

    assert real_gh(fixture_gh).issue_comments(5) == [comment]


@pytest.mark.parametrize("answer", ["nope\n", '{"comments": 3}\n', "[]\n"])
def test_issue_comments_that_are_no_comment_list_are_unparsed(fixture_gh, answer):
    fixture_gh.reply(COMMENTS, answer)

    with pytest.raises(Unparsed):
        real_gh(fixture_gh).issue_comments(5)


def state_labels_argv(number):
    return ["issue", "view", str(number), "--json", "state,labels",
            "--jq", ".state, (.labels[].name)"]


def test_issue_state_labels_reads_the_state_then_the_labels(fixture_gh):
    fixture_gh.reply(state_labels_argv(5), "OPEN\nbug\nready-for-agent\n")
    fixture_gh.reply(state_labels_argv(6), "CLOSED\n")
    gh = real_gh(fixture_gh)

    assert gh.issue_state_labels(5) == ("OPEN", ["bug", "ready-for-agent"])
    assert gh.issue_state_labels(6) == ("CLOSED", [])


def state_labels_body_argv(number):
    return ["issue", "view", str(number), "--json", "state,labels,body",
            "--jq", ".state, (.labels | length), (.labels[].name), .body"]


def test_issue_state_labels_body_splits_on_the_label_count(fixture_gh):
    fixture_gh.reply(state_labels_body_argv(5), "OPEN\n2\nbug\nwip\nline one\nline two\n\n")
    fixture_gh.reply(state_labels_body_argv(6), "OPEN\nmany\n")
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


OPEN_ROWS_JQ = ".[] | .number, .state, (.labels | length), (.labels[].name)"


def open_rows_argv(limit="1000"):
    return ["issue", "list", "--state", "open", "--search", "sort:created-asc", "--limit", limit,
            "--json", "number,state,labels", "--jq", OPEN_ROWS_JQ]


def test_issues_open_rows_reads_each_count_marked_record(fixture_gh, capsys):
    fixture_gh.reply(open_rows_argv(), "7\nOPEN\n2\nready-for-agent\nbug\n012\nCLOSED\n0\n")

    assert real_gh(fixture_gh).issues_open_rows() == [
        StateRow(7, "OPEN", ["ready-for-agent", "bug"]),
        StateRow(12, "CLOSED", []),
    ]
    assert capsys.readouterr().err == ""


@pytest.mark.parametrize("answer", ["x\nOPEN\n0\n", "7\nOPEN\n3\na\n", "7\n"])
def test_an_open_rows_listing_that_does_not_parse_fails(fixture_gh, answer):
    fixture_gh.reply(open_rows_argv(), answer)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).issues_open_rows()
    assert failed.value.stderr == "gh answered a listing that does not parse"


def test_an_open_rows_listing_at_the_issue_list_limit_warns(fixture_gh, capsys):
    fixture_gh.reply(open_rows_argv("2"), "1\nOPEN\n0\n2\nOPEN\n0\n")

    assert len(real_gh(fixture_gh, ORCH_ISSUE_LIST_LIMIT="2").issues_open_rows()) == 2
    assert capsys.readouterr().err == (
        "orch: the open issues reached the issue-list limit of 2"
        " - the newest past it are missing from this list\n"
    )


def labelled_rows_argv(*labels, limit="1000"):
    argv = ["issue", "list", "--state", "open"]
    for label in labels:
        argv += ["--label", label]
    return argv + ["--search", "sort:created-asc", "--limit", limit,
                   "--json", "number,state,labels", "--jq", OPEN_ROWS_JQ]


def test_issues_labelled_rows_lists_the_issues_carrying_every_label_named(fixture_gh, capsys):
    fixture_gh.reply(labelled_rows_argv("needs-human", "orch:spec"),
                     "7\nOPEN\n2\nneeds-human\norch:spec\n")

    assert real_gh(fixture_gh).issues_labelled_rows("needs-human", "orch:spec") == [
        StateRow(7, "OPEN", ["needs-human", "orch:spec"])]
    assert capsys.readouterr().err == ""


def test_a_labelled_rows_listing_at_the_issue_list_limit_warns_naming_its_labels(
        fixture_gh, capsys):
    fixture_gh.reply(labelled_rows_argv("needs-human", limit="2"), "1\nOPEN\n0\n2\nOPEN\n0\n")

    assert len(real_gh(fixture_gh, ORCH_ISSUE_LIST_LIMIT="2").issues_labelled_rows(
        "needs-human")) == 2
    assert capsys.readouterr().err == (
        "orch: the open issues labelled needs-human reached the issue-list limit of 2"
        " - the newest past it are missing from this list\n"
    )


def test_a_labelled_rows_listing_that_does_not_parse_fails(fixture_gh):
    fixture_gh.reply(labelled_rows_argv("needs-human"), "7\nOPEN\n3\na\n")

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).issues_labelled_rows("needs-human")
    assert failed.value.stderr == "gh answered a listing that does not parse"


def state_argv(number):
    return ["issue", "view", str(number), "--json", "state,url",
            "--jq", 'if (.url | test("/pull/")) then "PULL" else .state end']


def test_issue_state_is_open_closed_or_pull_for_a_pull_request(fixture_gh):
    fixture_gh.reply(state_argv(5), "OPEN\n")
    fixture_gh.reply(state_argv(62), "PULL\n")
    gh = real_gh(fixture_gh)

    assert (gh.issue_state(5), gh.issue_state(62)) == ("OPEN", "PULL")


BODIES_JQ = ('.[] | .number, (.labels | length), (.labels[].name),'
             ' ((.body | indices("\\n") | length) + 1), .body')


def bodies_argv(*labels, limit="1000"):
    argv = ["issue", "list", "--state", "open"]
    for label in labels:
        argv += ["--label", label]
    return argv + ["--search", "sort:created-asc", "--limit", limit,
                   "--json", "number,labels,body", "--jq", BODIES_JQ]


def test_issues_labelled_bodies_reads_each_record_with_its_labels_and_body(fixture_gh, capsys):
    fixture_gh.reply(bodies_argv("review:nit", "triage me"),
                     "3\n1\nreview:nit\n2\nline one\r\nline two\n"
                     "012\n0\n1\n\n"
                     "9\n2\nreview:nit\ntriage me\n4\nlast\n\n")

    assert real_gh(fixture_gh).issues_labelled_bodies("review:nit", "triage me") == [
        LabelledBody(3, ["review:nit"], "line one\r\nline two"),
        LabelledBody(12, [], ""),
        LabelledBody(9, ["review:nit", "triage me"], "last"),
    ]
    assert capsys.readouterr().err == ""


@pytest.mark.parametrize("answer", [
    "x\n0\n1\nbody\n", "3\nmany\n", "3\n2\nreview:nit\n", "3\n0\n", "3\n0\nlines\nbody\n",
], ids=["number", "label-count", "labels-run-out", "no-line-count", "line-count"])
def test_a_bodies_listing_that_does_not_parse_fails(fixture_gh, answer):
    fixture_gh.reply(bodies_argv("review:nit"), answer)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).issues_labelled_bodies("review:nit")
    assert failed.value.stderr == "gh answered a listing that does not parse"


def test_a_bodies_listing_at_the_issue_list_limit_warns_naming_every_label(fixture_gh, capsys):
    fixture_gh.reply(bodies_argv("review:major", "needs-triage", limit="2"),
                     "1\n0\n1\nA\n2\n0\n1\nB\n")

    rows = real_gh(fixture_gh, ORCH_ISSUE_LIST_LIMIT="2").issues_labelled_bodies(
        "review:major", "needs-triage")

    assert [row.number for row in rows] == [1, 2]
    assert capsys.readouterr().err == (
        "orch: the open issues labelled review:major and needs-triage reached the"
        " issue-list limit of 2 - the newest past it are missing from this list\n"
    )


def parent_argv(number):
    return ["api", "repos/{owner}/{repo}/issues/%d" % number, "--jq", ".parent_issue_url // empty"]


def test_issue_parent_is_the_number_in_the_parent_url_or_none(fixture_gh):
    fixture_gh.reply(parent_argv(5), "https://api.github.com/repos/o/r/issues/12\n")
    fixture_gh.reply(parent_argv(6), "")
    gh = real_gh(fixture_gh)

    assert gh.issue_parent(5) == 12
    assert gh.issue_parent(6) is None


def test_a_parent_url_with_no_issue_number_fails(fixture_gh):
    fixture_gh.reply(parent_argv(5), "https://api.github.com/repos/o/r/issues/\n")

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).issue_parent(5)
    assert failed.value.stderr == (
        "gh api printed a parent URL with no issue number:"
        " https://api.github.com/repos/o/r/issues/"
    )


def open_blockers_argv(number):
    return ["api", "repos/{owner}/{repo}/issues/%d" % number,
            "--jq", '.issue_dependencies_summary.blocked_by // ""']


def test_issue_open_blockers_is_the_summary_count_or_none(fixture_gh):
    fixture_gh.reply(open_blockers_argv(5), "2\n")
    fixture_gh.reply(open_blockers_argv(6), "\n")
    gh = real_gh(fixture_gh)

    assert gh.issue_open_blockers(5) == 2
    assert gh.issue_open_blockers(6) is None


def test_blockers_states_lists_each_blocker_and_its_state(fixture_gh):
    fixture_gh.reply(["api", "--paginate", "repos/{owner}/{repo}/issues/5/dependencies/blocked_by",
                      "--jq", '.[] | "\\(.number)\\t\\(.state | ascii_upcase)"'],
                     "3\tOPEN\n4\tCLOSED\n")

    assert real_gh(fixture_gh).blockers_states(5) == [(3, "OPEN"), (4, "CLOSED")]


SUB_ISSUES = ["api", "--paginate", "repos/{owner}/{repo}/issues/5/sub_issues", "--jq",
              '.[] | "\\(.number)\\t\\(.state | ascii_upcase)\\t'
              '\\(.issue_dependencies_summary.blocked_by // "")"']


def test_sub_issues_lists_each_with_its_state_and_open_blocker_count_or_none(fixture_gh):
    fixture_gh.reply(SUB_ISSUES, "11\tOPEN\t2\n12\tCLOSED\t\n")

    assert real_gh(fixture_gh).sub_issues(5) == [
        SubIssue(11, "OPEN", 2), SubIssue(12, "CLOSED", None)]


@pytest.mark.parametrize("answer", ["x\tOPEN\t0\n", "11\tOPEN\tmany\n", "11\n"])
def test_a_sub_issue_listing_that_does_not_parse_fails(fixture_gh, answer):
    fixture_gh.reply(SUB_ISSUES, answer)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).sub_issues(5)
    assert failed.value.stderr == ("gh answered a sub-issue that does not parse: "
                                   + answer.rstrip("\n"))


BLOCKERS = ["api", "--paginate", "repos/{owner}/{repo}/issues/5/dependencies/blocked_by",
            "--jq", ".[].number"]


def test_blockers_lists_each_blocker_s_number_in_github_s_order(fixture_gh):
    fixture_gh.reply(BLOCKERS, "4\n3\n")

    assert real_gh(fixture_gh).blockers(5) == [4, 3]


def test_a_blocker_listing_that_does_not_parse_fails(fixture_gh):
    fixture_gh.reply(BLOCKERS, "4\nnull\n")

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).blockers(5)
    assert failed.value.stderr == "gh answered a blocker that does not parse: null"


def api_id_argv(number):
    return ["api", "repos/{owner}/{repo}/issues/%d" % number, "--jq", ".id"]


LINK = ["api", "--method", "POST", "repos/{owner}/{repo}/issues/5/sub_issues",
        "-F", "sub_issue_id=9007"]
UNLINK = ["api", "--method", "DELETE", "repos/{owner}/{repo}/issues/5/sub_issue",
          "-F", "sub_issue_id=9007"]
BLOCKER_ADD = ["api", "--method", "POST", "repos/{owner}/{repo}/issues/5/dependencies/blocked_by",
               "-F", "issue_id=9007"]
BLOCKER_REMOVE = ["api", "--method", "DELETE",
                  "repos/{owner}/{repo}/issues/5/dependencies/blocked_by/9007"]


@pytest.mark.parametrize("call, write", [
    (lambda gh: gh.sub_issue_link(5, 7), LINK),
    (lambda gh: gh.sub_issue_unlink(5, 7), UNLINK),
    (lambda gh: gh.blocker_add(5, 7), BLOCKER_ADD),
    (lambda gh: gh.blocker_remove(5, 7), BLOCKER_REMOVE),
])
def test_a_link_unlink_or_edge_write_names_the_other_issue_by_its_api_id(fixture_gh, call, write):
    fixture_gh.reply(api_id_argv(7), "9007\n")
    fixture_gh.reply(write, "{}\n")

    assert call(real_gh(fixture_gh)) is None
    assert fixture_gh.argvs() == [api_id_argv(7), write]


@pytest.mark.parametrize("call", [
    lambda gh: gh.sub_issue_link(5, 7), lambda gh: gh.blocker_add(5, 7)])
def test_a_link_or_edge_write_whose_api_id_read_fails_makes_no_write(fixture_gh, call):
    fixture_gh.reply(api_id_argv(7), stderr="HTTP 404: Not Found\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        call(real_gh(fixture_gh))
    assert failed.value.stderr == "HTTP 404: Not Found\n"
    assert fixture_gh.argvs() == [api_id_argv(7)]


def test_a_failed_sub_issue_link_write_passes_gh_s_stderr_through(fixture_gh):
    fixture_gh.reply(api_id_argv(7), "9007\n")
    fixture_gh.reply(LINK, stderr="HTTP 422: Sub issue may only have one parent\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).sub_issue_link(5, 7)
    assert failed.value.stderr == "HTTP 422: Sub issue may only have one parent\n"
    assert fixture_gh.argvs() == [api_id_argv(7), LINK]


OPEN_TITLES = ["api", "--paginate", "repos/{owner}/{repo}/issues?state=open&per_page=100",
               "--jq", '.[] | select(has("pull_request") | not) | "\\(.number)\\t\\(.title)"']


def test_issues_open_titles_lists_each_open_issue_s_number_and_title(fixture_gh):
    fixture_gh.reply(OPEN_TITLES, "9\tNewest\t tab\n3\tOldest\n")

    assert real_gh(fixture_gh).issues_open_titles() == [(9, "Newest\t tab"), (3, "Oldest")]


def test_an_open_titles_listing_that_does_not_parse_fails(fixture_gh):
    fixture_gh.reply(OPEN_TITLES, "9\tNewest\nx\tOdd\n")

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).issues_open_titles()
    assert failed.value.stderr == "gh answered a listing that does not parse"


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


BODY_EDIT = ["issue", "edit", "5", "--body-file", "b.md"]
COMMENT = ["issue", "comment", "5", "--body-file", "c.md"]


def test_issue_body_edit_and_comment_pass_the_file(fixture_gh):
    fixture_gh.reply(BODY_EDIT, "url\n")
    fixture_gh.reply(COMMENT, "url\n")
    gh = real_gh(fixture_gh)

    assert gh.issue_body_edit(5, "b.md") is None
    assert gh.issue_comment(5, "c.md") is None
    assert fixture_gh.argvs() == [BODY_EDIT, COMMENT]


@pytest.mark.parametrize("answer,url", [
    ("https://github.com/o/r/issues/5#issuecomment-9\nmore\n",
     "https://github.com/o/r/issues/5#issuecomment-9"),
    ("", ""),
], ids=["a URL", "none"])
def test_issue_comment_url_posts_the_file_and_answers_the_first_line_gh_printed(
        fixture_gh, answer, url):
    fixture_gh.reply(COMMENT, answer)

    assert real_gh(fixture_gh).issue_comment_url(5, "c.md") == url
    assert fixture_gh.argvs() == [COMMENT]


def test_issue_relabel_is_one_edit_and_none_with_nothing_named(fixture_gh):
    argv = ["issue", "edit", "5", "--remove-label", "wip", "--remove-label", "needs-triage",
            "--add-label", "ready-for-agent"]
    fixture_gh.reply(argv)
    gh = real_gh(fixture_gh)

    gh.issue_relabel(5, add=["ready-for-agent"], remove=["wip", "needs-triage"])
    gh.issue_relabel(5)

    assert fixture_gh.argvs() == [argv]


CLOSE_DUPLICATE = ["issue", "close", "5", "--comment", "Dup.", "--duplicate-of", "4"]


def test_issue_close_as_completed_or_as_a_duplicate(fixture_gh):
    completed = ["issue", "close", "5", "--reason", "completed", "--comment", "Done."]
    fixture_gh.reply(completed)
    fixture_gh.reply(CLOSE_DUPLICATE)
    gh = real_gh(fixture_gh)

    gh.issue_close(5, reason="completed", comment="Done.")
    gh.issue_close(5, comment="Dup.", duplicate_of=4)

    assert fixture_gh.argvs() == [completed, CLOSE_DUPLICATE]


def test_issue_reopen_names_the_issue_alone(fixture_gh):
    reopen = ["issue", "reopen", "5"]
    fixture_gh.reply(reopen, "url\n")
    gh = real_gh(fixture_gh)

    assert gh.issue_reopen(5) is None
    assert fixture_gh.argvs() == [reopen]


def test_a_failed_write_passes_gh_s_stderr_through(fixture_gh):
    fixture_gh.reply(COMMENT, stderr="HTTP 502: Bad Gateway\nsecond line\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).issue_comment(5, "c.md")
    assert failed.value.stderr == "HTTP 502: Bad Gateway\nsecond line\n"


LABEL_CREATE = ["label", "create", "bug", "--color", "d73a4a",
                "--description", "Something isn't working"]


def test_label_create_creates_a_missing_label_never_with_force(fixture_gh):
    fixture_gh.reply(LABEL_CREATE, "created\n")

    assert real_gh(fixture_gh).label_create("bug", "d73a4a", "Something isn't working") is None
    assert fixture_gh.argvs() == [LABEL_CREATE]


def test_label_create_of_a_label_that_exists_fails_with_gh_s_stderr(fixture_gh):
    exists = ('label with name "bug" already exists; use `--force` to update its color'
              " and description\n")
    fixture_gh.reply(LABEL_CREATE, stderr=exists, exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).label_create("bug", "d73a4a", "Something isn't working")
    assert failed.value.stderr == exists


LABEL_UPSERT = ["label", "create", "review:major", "--force", "--color", "d93f0b",
                "--description", "Review finding filed at major severity"]


def test_label_upsert_creates_or_rewrites_the_label_with_force(fixture_gh):
    fixture_gh.reply(LABEL_UPSERT, "updated\n")

    assert real_gh(fixture_gh).label_upsert(
        "review:major", "d93f0b", "Review finding filed at major severity") is None
    assert fixture_gh.argvs() == [LABEL_UPSERT]


def test_a_failed_label_upsert_passes_gh_s_stderr_through(fixture_gh):
    fixture_gh.reply(LABEL_UPSERT, stderr="HTTP 502: Bad Gateway\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).label_upsert(
            "review:major", "d93f0b", "Review finding filed at major severity")
    assert failed.value.stderr == "HTTP 502: Bad Gateway\n"


# --- repo operations ---------------------------------------------------------


def default_branch_argv(repo):
    return ["repo", "view", repo, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"]


def test_repo_default_branch_names_the_repo_in_the_argv(fixture_gh):
    fixture_gh.reply(default_branch_argv("acme/widgets"), "trunk\n")

    assert real_gh(fixture_gh).repo_default_branch("acme/widgets") == "trunk"
    assert fixture_gh.calls() == [
        ("fork/widgets", "github.com", default_branch_argv("acme/widgets"))]


def test_a_repo_gh_cannot_resolve_fails_its_default_branch_read(fixture_gh):
    gone = "GraphQL: Could not resolve to a Repository with the name 'acme/gone'. (repository)\n"
    fixture_gh.reply(default_branch_argv("acme/gone"), stderr=gone, exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).repo_default_branch("acme/gone")
    assert failed.value.stderr == gone


LOCAL_DEFAULT = ["repo", "set-default", "--view"]


def test_repo_local_default_reads_the_first_line_gh_prints(fixture_gh):
    fixture_gh.reply(LOCAL_DEFAULT, "upstream/widgets\nsecond line\n")

    assert real_gh(fixture_gh).repo_local_default() == "upstream/widgets"
    assert fixture_gh.calls() == [("fork/widgets", "github.com", LOCAL_DEFAULT)]


def test_a_checkout_with_no_gh_default_repo_reads_as_none(fixture_gh):
    fixture_gh.reply(LOCAL_DEFAULT, stderr="no default repository has been set\n")

    assert real_gh(fixture_gh).repo_local_default() == ""


def auth_status_argv(host):
    return ["auth", "status", "--active", "--hostname", host]


def test_auth_status_asks_about_the_active_account_on_the_host(fixture_gh):
    fixture_gh.reply(auth_status_argv("ghe.example.com"), "Logged in to ghe.example.com\n")

    assert real_gh(fixture_gh).auth_status("ghe.example.com") is None
    assert fixture_gh.calls() == [
        ("fork/widgets", "github.com", auth_status_argv("ghe.example.com"))]


def test_a_failed_auth_status_passes_gh_s_report_through(fixture_gh):
    report = "X Failed to log in to github.com account octo\n- dial tcp: i/o timeout\n"
    fixture_gh.reply(auth_status_argv("github.com"), "github.com\n", stderr=report, exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).auth_status("github.com")
    assert (failed.value.stdout, failed.value.stderr) == ("github.com\n", report)


def labels_argv(limit):
    return ["label", "list", "--limit", str(limit), "--json", "name", "--jq", ".[].name"]


def test_labels_lists_the_repo_s_label_names_up_to_the_limit(fixture_gh):
    fixture_gh.reply(labels_argv(1000), "needs triage\nReady-For-Agent\n")

    assert real_gh(fixture_gh).labels(1000) == ["needs triage", "Ready-For-Agent"]
    assert fixture_gh.calls() == [("fork/widgets", "github.com", labels_argv(1000))]


def test_a_repo_with_no_labels_lists_none(fixture_gh):
    fixture_gh.reply(labels_argv(1000), "")

    assert real_gh(fixture_gh).labels(1000) == []


def test_a_failed_label_listing_passes_gh_s_stderr_through(fixture_gh):
    fixture_gh.reply(labels_argv(1000), stderr="HTTP 403: Forbidden\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).labels(1000)
    assert failed.value.stderr == "HTTP 403: Forbidden\n"


NEWEST_ISSUE = ["issue", "list", "--state", "all", "--limit", "1", "--json", "number", "--jq",
                ".[0].number // empty"]
PROBED_SUB_ISSUES = ["api", "repos/{owner}/{repo}/issues/41/sub_issues"]


def test_sub_issue_support_asks_the_endpoint_of_the_newest_issue(fixture_gh):
    fixture_gh.reply(NEWEST_ISSUE, "41\n")
    fixture_gh.reply(PROBED_SUB_ISSUES, "[]\n")

    assert real_gh(fixture_gh).sub_issues_supported() is True
    assert fixture_gh.calls() == [("fork/widgets", "github.com", NEWEST_ISSUE),
                                  ("fork/widgets", "github.com", PROBED_SUB_ISSUES)]


def test_an_endpoint_answering_404_has_no_sub_issue_support(fixture_gh):
    fixture_gh.reply(NEWEST_ISSUE, "41\n")
    fixture_gh.reply(PROBED_SUB_ISSUES, stderr="gh: Not Found (HTTP 404)\n", exit=1)

    assert real_gh(fixture_gh).sub_issues_supported() is False


def test_a_repo_with_no_issue_cannot_be_probed_for_sub_issue_support(fixture_gh):
    fixture_gh.reply(NEWEST_ISSUE, "")

    assert real_gh(fixture_gh).sub_issues_supported() is None
    assert fixture_gh.calls() == [("fork/widgets", "github.com", NEWEST_ISSUE)]


@pytest.mark.parametrize("replies", [
    [(NEWEST_ISSUE, "", "HTTP 502: Bad Gateway\n", 1)],
    [(NEWEST_ISSUE, "41\n", "", 0), (PROBED_SUB_ISSUES, "", "HTTP 502: Bad Gateway\n", 1)],
])
def test_a_sub_issue_probe_failing_any_other_way_passes_gh_s_stderr_through(fixture_gh, replies):
    for argv, stdout, stderr, code in replies:
        fixture_gh.reply(argv, stdout, stderr=stderr, exit=code)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).sub_issues_supported()
    assert failed.value.stderr == "HTTP 502: Bad Gateway\n"


# --- PR operations -----------------------------------------------------------


def prs_open_argv(head, *base):
    return ["pr", "list", "--head", head, *base, "--state", "open",
            "--json", "number,isCrossRepository",
            "--jq", '.[] | "\\(.number)\\t\\(.isCrossRepository)"']


def test_prs_open_lists_each_open_pr_from_the_head_with_its_fork_flag_unfiltered(fixture_gh):
    fixture_gh.reply(prs_open_argv("topic"), "12\ttrue\n4\tfalse\n")
    fixture_gh.reply(prs_open_argv("topic", "--base", "main"), "4\tfalse\n")
    fixture_gh.reply(prs_open_argv("none"), "")
    gh = real_gh(fixture_gh)

    assert gh.prs_open("topic") == ["12\ttrue", "4\tfalse"]
    assert gh.prs_open("topic", "main") == ["4\tfalse"]
    assert gh.prs_open("none") == []


def prs_merged_argv(head, base):
    return ["pr", "list", "--head", head, "--base", base, "--state", "merged",
            "--json", "number,headRefOid,isCrossRepository",
            "--jq", '.[] | "\\(.number)\\t\\(.headRefOid)\\t\\(.isCrossRepository)"']


def test_prs_merged_lists_each_merged_pr_from_the_head_into_the_base_unfiltered(fixture_gh):
    fixture_gh.reply(prs_merged_argv("quick/12-foo", "main"),
                     "61\tabc123\ttrue\n62\tdef456\tfalse\n")
    fixture_gh.reply(prs_merged_argv("none", "main"), "")
    gh = real_gh(fixture_gh)

    assert gh.prs_merged("quick/12-foo", "main") == ["61\tabc123\ttrue", "62\tdef456\tfalse"]
    assert gh.prs_merged("none", "main") == []


PR_BODY = ["pr", "view", "4", "--json", "body", "--jq", ".body"]


def test_pr_body_keeps_carriage_returns_and_drops_only_gh_s_newline(fixture_gh):
    fixture_gh.reply(PR_BODY, "Body\r\nline\n\n")

    assert real_gh(fixture_gh).pr_body(4) == "Body\r\nline\n"


PR_COMMENTS = ["pr", "view", "4", "--json", "comments"]


def test_pr_comments_are_gh_s_raw_comment_objects(fixture_gh):
    comment = {"author": {"login": "ann"}, "authorAssociation": "OWNER",
               "createdAt": "2026-01-01T00:00:00Z", "body": "Hi", "url": "u"}
    fixture_gh.reply(PR_COMMENTS, '{"comments": [%s]}\n' % json.dumps(comment))

    assert real_gh(fixture_gh).pr_comments(4) == [comment]


@pytest.mark.parametrize("answer", ["nope\n", '{"comments": 3}\n'])
def test_pr_comments_that_are_no_comment_list_are_unparsed(fixture_gh, answer):
    fixture_gh.reply(PR_COMMENTS, answer)

    with pytest.raises(Unparsed):
        real_gh(fixture_gh).pr_comments(4)


PR_CREATE_TAIL = ["--base", "main", "--head", "topic", "--title", "T", "--body-file", "b.md"]


def test_pr_create_opens_a_draft_carrying_each_label_and_answers_the_number(fixture_gh):
    fixture_gh.reply(["pr", "create", "--draft", "--label", "bug", "--label", "ready",
                      *PR_CREATE_TAIL],
                     "Creating pull request\nhttps://github.com/fork/widgets/pull/17\n")
    fixture_gh.reply(["pr", "create", *PR_CREATE_TAIL], "https://github.com/fork/widgets/pull/18\n")
    gh = real_gh(fixture_gh)

    assert gh.pr_create("main", "topic", "T", "b.md", draft=True, labels=["bug", "ready"]) == 17
    assert gh.pr_create("main", "topic", "T", "b.md") == 18


def test_a_pr_create_that_prints_no_pr_url_fails(fixture_gh):
    fixture_gh.reply(["pr", "create", *PR_CREATE_TAIL],
                     "https://github.com/fork/widgets/issues/17\n")

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).pr_create("main", "topic", "T", "b.md")
    assert failed.value.stderr == (
        "gh pr create printed no PR URL: https://github.com/fork/widgets/issues/17\n")


def test_a_pr_create_carrying_a_label_is_a_compound_write_given_up_at_once(fixture_gh):
    labelled = ["pr", "create", "--label", "bug", *PR_CREATE_TAIL]
    bare = ["pr", "create", *PR_CREATE_TAIL]
    fixture_gh.reply(labelled, stderr=SECONDARY + "\n", exit=1)
    fixture_gh.reply(bare, stderr=SECONDARY + "\n", exit=1,
                     then=[("https://github.com/fork/widgets/pull/18\n", "", 0)])
    fixture_gh.reply(RATE_LIMIT, pools(0, 5))
    sleeps = []
    gh = real_gh(fixture_gh, sleeps=sleeps)

    with pytest.raises(GhFailed) as failed:
        gh.pr_create("main", "topic", "T", "b.md", labels=["bug"])
    assert gh.pr_create("main", "topic", "T", "b.md") == 18

    assert failed.value.stderr.startswith("orch: GitHub API rate limit reached")
    assert fixture_gh.argvs() == [labelled, RATE_LIMIT, bare, bare]
    assert sleeps == [60.0]


def test_pr_labels_lists_each_label_name(fixture_gh):
    fixture_gh.reply(["pr", "view", "4", "--json", "labels", "--jq", ".labels[].name"],
                     "bug\nNeeds Human\n")
    fixture_gh.reply(["pr", "view", "5", "--json", "labels", "--jq", ".labels[].name"], "")
    gh = real_gh(fixture_gh)

    assert gh.pr_labels(4) == ["bug", "Needs Human"]
    assert gh.pr_labels(5) == []


def refs_argv(number):
    return ["pr", "view", str(number), "--json", "headRefOid,headRefName,baseRefName",
            "--jq", '(.headRefOid // ""), (.headRefName // ""), (.baseRefName // "")']


def test_pr_refs_reads_the_head_sha_head_branch_and_base_each_empty_where_unset(fixture_gh):
    fixture_gh.reply(refs_argv(4), "abc123\ntopic\nmain\n")
    fixture_gh.reply(refs_argv(5), "\ntopic\n\n")
    gh = real_gh(fixture_gh)

    assert gh.pr_refs(4) == ("abc123", "topic", "main")
    assert gh.pr_refs(5) == ("", "topic", "")


def url_head_argv(number):
    return ["pr", "view", str(number), "--json", "url,headRefOid",
            "--jq", '(.url // ""), (.headRefOid // "")']


def test_pr_url_head_reads_the_url_then_the_head_sha_each_empty_where_unset(fixture_gh):
    fixture_gh.reply(url_head_argv(57), "https://github.com/acme/widgets/pull/57\nbbbb\n")
    fixture_gh.reply(url_head_argv(58), "\n\n")
    gh = real_gh(fixture_gh)

    assert gh.pr_url_head(57) == ("https://github.com/acme/widgets/pull/57", "bbbb")
    assert gh.pr_url_head(58) == ("", "")


def test_a_failed_pr_url_head_read_passes_gh_s_stderr_through(fixture_gh):
    fixture_gh.reply(url_head_argv(58), stderr="HTTP 502: Bad Gateway\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).pr_url_head(58)
    assert failed.value.stderr == "HTTP 502: Bad Gateway\n"


def state_draft_argv(number):
    return ["pr", "view", str(number), "--json", "state,isDraft", "--jq", ".state, .isDraft"]


def test_pr_state_draft_reads_the_state_and_whether_it_is_a_draft(fixture_gh):
    fixture_gh.reply(state_draft_argv(4), "OPEN\ntrue\n")
    fixture_gh.reply(state_draft_argv(5), "MERGED\nfalse\n")
    fixture_gh.reply(state_draft_argv(6), "CLOSED\nnull\n")
    gh = real_gh(fixture_gh)

    assert gh.pr_state_draft(4) == ("OPEN", True)
    assert gh.pr_state_draft(5) == ("MERGED", False)
    assert gh.pr_state_draft(6) == ("CLOSED", False)


def test_pr_diff_is_the_diff_as_gh_prints_it(fixture_gh):
    fixture_gh.reply(["pr", "diff", "4"], "diff --git a/x b/x\r\n+y\n\n")

    assert real_gh(fixture_gh).pr_diff(4) == "diff --git a/x b/x\r\n+y\n\n"


@pytest.mark.parametrize("call, write", [
    (lambda gh: gh.pr_ready(4), ["pr", "ready", "4"]),
    (lambda gh: gh.pr_draft(4), ["pr", "ready", "4", "--undo"]),
    (lambda gh: gh.pr_comment(4, "c.md"), ["pr", "comment", "4", "--body-file", "c.md"]),
    (lambda gh: gh.pr_body_edit(4, "b.md"), ["pr", "edit", "4", "--body-file", "b.md"]),
    (lambda gh: gh.pr_title_edit(4, "A title"), ["pr", "edit", "4", "--title", "A title"]),
    (lambda gh: gh.pr_label_add(4, "Needs Human"),
     ["pr", "edit", "4", "--add-label", "Needs Human"]),
], ids=["ready", "draft", "comment", "body-edit", "title-edit", "label-add"])
def test_a_pr_write_hands_gh_its_one_argv_and_answers_nothing(fixture_gh, call, write):
    fixture_gh.reply(write, "https://github.com/fork/widgets/pull/4\n")

    assert call(real_gh(fixture_gh)) is None
    assert fixture_gh.argvs() == [write]


def test_a_failed_pr_write_passes_gh_s_stderr_through(fixture_gh):
    fixture_gh.reply(["pr", "ready", "4"], stderr="HTTP 502: Bad Gateway\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).pr_ready(4)
    assert failed.value.stderr == "HTTP 502: Bad Gateway\n"


def open_bodies_argv(limit="1000"):
    return ["pr", "list", "--state", "open", "--limit", limit,
            "--json", "number,body,isCrossRepository",
            "--jq", '.[] | "\\(.number)\\t\\(.body | @json)\\t\\(.isCrossRepository)"']


def test_prs_open_bodies_lists_every_open_pr_its_body_json_encoded_unfiltered(fixture_gh):
    fixture_gh.reply(open_bodies_argv(), '12\t"Refs #3\\r\\n\\nBody"\ttrue\n4\t""\tfalse\n')
    fixture_gh.reply(open_bodies_argv("7"), "")

    assert real_gh(fixture_gh).prs_open_bodies() == ['12\t"Refs #3\\r\\n\\nBody"\ttrue',
                                                     '4\t""\tfalse']
    assert real_gh(fixture_gh, ORCH_ISSUE_LIST_LIMIT="7").prs_open_bodies() == []


MERGED_CLOSING_JQ = ('.[] | "\\(.number)\\t\\(.headRefName)\\t\\(.mergedAt)\\t'
                     '\\([.closingIssuesReferences[].number] | map(tostring) | join(","))\\t'
                     '\\(.isCrossRepository)"')


def test_prs_merged_closing_lists_the_prs_merged_into_the_base_since_a_time(fixture_gh):
    argv = ["pr", "list", "--base", "main", "--state", "merged",
            "--search", "merged:>=2026-03-01T00:00:00Z sort:created-desc", "--limit", "1000",
            "--json", "number,headRefName,mergedAt,closingIssuesReferences,isCrossRepository",
            "--jq", MERGED_CLOSING_JQ]
    fixture_gh.reply(argv, "9\torch/5-x\t2026-03-02T00:00:00Z\t5,7\tfalse\n"
                           "8\tquick/6-y\t2026-03-01T00:00:00Z\t\ttrue\n")

    assert real_gh(fixture_gh).prs_merged_closing("main", "2026-03-01T00:00:00Z") == [
        "9\torch/5-x\t2026-03-02T00:00:00Z\t5,7\tfalse",
        "8\tquick/6-y\t2026-03-01T00:00:00Z\t\ttrue",
    ]


def test_prs_merged_bodies_is_every_merged_pr_s_body_each_ending_in_a_newline(fixture_gh):
    fixture_gh.reply(["pr", "list", "--base", "next", "--state", "merged", "--limit", "1000",
                      "--json", "body", "--jq", ".[].body"],
                     "Closes #3\n\nOne.\nRefs #4\n")

    assert real_gh(fixture_gh).prs_merged_bodies("next") == "Closes #3\n\nOne.\nRefs #4\n"


def test_issue_created_at_is_the_creation_time_gh_answers(fixture_gh):
    fixture_gh.reply(["issue", "view", "5", "--json", "createdAt", "--jq", ".createdAt"],
                     "2026-03-01T12:00:00Z\n")

    assert real_gh(fixture_gh).issue_created_at(5) == "2026-03-01T12:00:00Z"


def checks_argv(number, *required):
    return ["pr", "checks", str(number), *required, "--json", "bucket,name,link"]


RUNS = "https://github.com/acme/widgets/actions/runs"


def test_pr_checks_reads_the_required_or_every_check_each_bucket_name_and_link(fixture_gh):
    fixture_gh.reply(checks_argv(4, "--required"),
                     '[{"bucket":"fail","name":"build","link":"%s/4242/job/77"}]\n' % RUNS)
    fixture_gh.reply(checks_argv(4),
                     '[{"bucket":"pass","name":"lint","link":null},'
                     '{"bucket":"pending","name":"test","link":"%s/1/job/1"}]\n' % RUNS)
    gh = real_gh(fixture_gh)

    assert gh.pr_checks(4, "required") == [Check("fail", "build", RUNS + "/4242/job/77")]
    assert gh.pr_checks(4, "all") == [Check("pass", "lint", ""),
                                      Check("pending", "test", RUNS + "/1/job/1")]


@pytest.mark.parametrize("answer, checks", [
    ('[{"bucket":"pending","name":"build","link":""}]\n', [Check("pending", "build", "")]),
    ("[]\n", [Check("pending", "", "")]),
    ("not json\n", [Check("pending", "", "")]),
], ids=["readable", "empty", "unreadable"])
def test_pr_checks_exiting_8_for_pending_checks_is_read_as_an_answer(fixture_gh, answer, checks):
    fixture_gh.reply(checks_argv(4), answer, exit=8)

    assert real_gh(fixture_gh).pr_checks(4, "all") == checks


@pytest.mark.parametrize("stderr", [
    "no checks reported on the 'topic' branch\n",
    "no required checks reported on the 'topic' branch\n",
    "\n",
], ids=["no-checks", "no-required-checks", "empty-list"])
def test_pr_checks_with_none_reported_answers_none(fixture_gh, stderr):
    fixture_gh.reply(checks_argv(4, "--required"), stderr=stderr, exit=0 if stderr == "\n" else 1)

    assert real_gh(fixture_gh).pr_checks(4, "required") == []


@pytest.mark.parametrize("stderr, reported", [
    ("no checks reported on the 'topic' branch\n", "no checks reported on the 'topic' branch\n"),
    ("\n", ""),
], ids=["gh-says-none", "empty-list"])
def test_pr_checks_answering_none_keeps_gh_s_own_line_saying_so(fixture_gh, stderr, reported):
    fixture_gh.reply(checks_argv(4), stderr=stderr, exit=0 if stderr == "\n" else 1)

    assert real_gh(fixture_gh).pr_checks(4, "all").reported == reported


def test_pr_checks_whose_answer_does_not_parse_fail(fixture_gh):
    fixture_gh.reply(checks_argv(4), "<html>\n")

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).pr_checks(4, "all")
    assert failed.value.stderr == "gh pr checks answered with something jq could not read\n"


def test_a_failed_pr_checks_read_passes_gh_s_stderr_through(fixture_gh):
    fixture_gh.reply(checks_argv(4), stderr="HTTP 502: Bad Gateway\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).pr_checks(4, "all")
    assert failed.value.stderr == "HTTP 502: Bad Gateway\n"


# --- the CI-evidence reads ---------------------------------------------------

API_UNPARSED = "gh api answered with something jq could not read\n"


def protection_argv(branch):
    return ["api", "repos/{owner}/{repo}/branches/%s/protection/required_status_checks" % branch]


def test_branch_required_checks_lists_each_required_context_once_sorted(fixture_gh):
    fixture_gh.reply(protection_argv("main"),
                     '{"strict":false,"contexts":["lint","build"],'
                     '"checks":[{"context":"build","app_id":null},{"context":"test"}]}\n')
    fixture_gh.reply(protection_argv("loose"), '{"strict":true}\n')
    gh = real_gh(fixture_gh)

    assert gh.branch_required_checks("main") == ["build", "lint", "test"]
    assert gh.branch_required_checks("loose") == []


@pytest.mark.parametrize("stdout, stderr", [
    ('{"message":"Branch not protected","status":"404"}', "gh: Branch not protected (HTTP 404)\n"),
    ("", "gh: Branch not protected (HTTP 404)\n"),
    ('{"message":"Branch not protected","status":"404"}', ""),
], ids=["both", "stderr-alone", "stdout-alone"])
def test_an_unprotected_branch_requires_no_checks(fixture_gh, stdout, stderr):
    fixture_gh.reply(protection_argv("open"), stdout, stderr, exit=1)

    assert real_gh(fixture_gh).branch_required_checks("open") == []


def test_a_bare_not_found_fails_the_required_checks_read_with_gh_s_stderr(fixture_gh):
    fixture_gh.reply(protection_argv("hidden"), '{"message":"Not Found","status":"404"}',
                     "gh: Not Found (HTTP 404)\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).branch_required_checks("hidden")
    assert failed.value.stderr == "gh: Not Found (HTTP 404)\n"


def rules_argv(branch):
    return ["api", "repos/{owner}/{repo}/rules/branches/%s" % branch]


def test_branch_rules_lists_the_type_of_each_rule_on_the_branch(fixture_gh):
    fixture_gh.reply(rules_argv("main"),
                     '[{"type":"deletion"},{"type":"required_status_checks","parameters":{}}]\n')
    fixture_gh.reply(rules_argv("bare"), "[]\n")
    gh = real_gh(fixture_gh)

    assert gh.branch_rules("main") == ["deletion", "required_status_checks"]
    assert gh.branch_rules("bare") == []


def test_a_failed_branch_rules_read_passes_gh_s_stderr_through(fixture_gh):
    fixture_gh.reply(rules_argv("down"), stderr="HTTP 502: Bad Gateway\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).branch_rules("down")
    assert failed.value.stderr == "HTTP 502: Bad Gateway\n"


COMMITS_CHECKED_QUERY = (
    "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner,"
    " name: $name) { pullRequest(number: $number) { baseRef { target { ... on Commit {"
    " statusCheckRollup { contexts { totalCount } } } } } commits(first: 100) { nodes {"
    " commit { oid statusCheckRollup { contexts { totalCount } } } } } } } }"
)


def commits_checked_argv(number):
    return ["api", "graphql", "-F", "owner={owner}", "-F", "name={repo}",
            "-F", "number=%d" % number, "-f", "query=" + COMMITS_CHECKED_QUERY]


def rollup(count):
    return "null" if count is None else '{"contexts":{"totalCount":%d}}' % count


def commits_checked_answer(base, *commits):
    """The GraphQL answer for a base ref whose tip's rollup counts <base>
    contexts ("none" for no base ref), then each (oid, count) commit."""
    base_ref = "null" if base == "none" else '{"target":{"statusCheckRollup":%s}}' % rollup(base)
    nodes = ",".join('{"commit":{"oid":"%s","statusCheckRollup":%s}}' % (oid, rollup(count))
                     for oid, count in commits)
    return ('{"data":{"repository":{"pullRequest":{"baseRef":%s,"commits":{"nodes":[%s]}}}}}\n'
            % (base_ref, nodes))


def test_pr_commits_checked_answers_the_base_tip_then_each_commit_in_one_graphql_read(fixture_gh):
    fixture_gh.reply(commits_checked_argv(31),
                     commits_checked_answer(None, ("aaaa", None), ("bbbb", 0), ("cccc", 4)))

    assert real_gh(fixture_gh).pr_commits_checked(31) == (
        "no", [("aaaa", "no"), ("bbbb", "no"), ("cccc", "yes")])
    assert fixture_gh.argvs() == [commits_checked_argv(31)]


def test_a_base_tip_with_a_check_is_yes_and_a_pr_with_no_base_ref_answers_empty(fixture_gh):
    fixture_gh.reply(commits_checked_argv(31), commits_checked_answer(2))
    fixture_gh.reply(commits_checked_argv(32), commits_checked_answer("none", ("aaaa", None)))
    gh = real_gh(fixture_gh)

    assert gh.pr_commits_checked(31) == ("yes", [])
    assert gh.pr_commits_checked(32) == ("", [("aaaa", "no")])


def test_a_failed_pr_commits_checked_read_passes_gh_s_stderr_through(fixture_gh):
    fixture_gh.reply(commits_checked_argv(31), stderr="gh: Server Error (HTTP 502)\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).pr_commits_checked(31)
    assert failed.value.stderr == "gh: Server Error (HTTP 502)\n"


@pytest.mark.parametrize("call, argv", [
    (lambda gh: gh.branch_required_checks("main"), protection_argv("main")),
    (lambda gh: gh.branch_rules("main"), rules_argv("main")),
    (lambda gh: gh.pr_commits_checked(31), commits_checked_argv(31)),
], ids=["required-checks", "rules", "commits-checked"])
@pytest.mark.parametrize("answer", ["not json\n", '"a string"\n'], ids=["not-json", "no-object"])
def test_a_ci_evidence_answer_that_does_not_parse_fails(fixture_gh, call, argv, answer):
    fixture_gh.reply(argv, answer)

    with pytest.raises(GhFailed) as failed:
        call(real_gh(fixture_gh))
    assert failed.value.stderr == API_UNPARSED


# --- Actions runs ------------------------------------------------------------


def test_run_rerun_reruns_the_run_s_failed_jobs_and_answers_nothing(fixture_gh):
    fixture_gh.reply(["run", "rerun", "4242", "--failed"], "✓ Requested rerun of failed jobs\n")

    assert real_gh(fixture_gh).run_rerun(4242) is None
    assert fixture_gh.argvs() == [["run", "rerun", "4242", "--failed"]]


def test_a_refused_run_rerun_passes_gh_s_stderr_through(fixture_gh):
    fixture_gh.reply(["run", "rerun", "4243", "--failed"],
                     stderr="HTTP 403: Resource not accessible by integration\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).run_rerun(4243)
    assert failed.value.stderr == "HTTP 403: Resource not accessible by integration\n"


def test_job_failed_log_is_the_failed_steps_log_as_gh_prints_it(fixture_gh):
    fixture_gh.reply(["run", "view", "--job", "77", "--log-failed"],
                     "build\tstep\tline one\r\nline two\n\n")

    assert real_gh(fixture_gh).job_failed_log(77) == "build\tstep\tline one\r\nline two\n\n"


def test_a_job_log_gh_cannot_read_passes_gh_s_stderr_through(fixture_gh):
    fixture_gh.reply(["run", "view", "--job", "78", "--log-failed"],
                     stderr="failed to get run log: log not found\n", exit=1)

    with pytest.raises(GhFailed) as failed:
        real_gh(fixture_gh).job_failed_log(78)
    assert failed.value.stderr == "failed to get run log: log not found\n"


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


def test_a_pr_close_posts_its_comment_and_is_a_compound_write_given_up_at_once(fixture_gh):
    argv = ["pr", "close", "4", "--comment", "Closed by a redo.\n\nSee `orch/7-x-redo-1`."]
    fixture_gh.reply(argv, "", stderr=SECONDARY + "\n", exit=1, then=[("", "", 0)])
    fixture_gh.reply(RATE_LIMIT, pools(0, 5))
    sleeps = []
    gh = real_gh(fixture_gh, sleeps=sleeps)

    with pytest.raises(GhFailed) as failed:
        gh.pr_close(4, "Closed by a redo.\n\nSee `orch/7-x-redo-1`.")
    closed = gh.pr_close(4, "Closed by a redo.\n\nSee `orch/7-x-redo-1`.")

    assert failed.value.stderr.startswith("orch: GitHub API rate limit reached")
    assert closed is None
    assert fixture_gh.argvs() == [argv, RATE_LIMIT, argv]
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


class OpenWait:
    """A re-callable wait the limit handling asks whether a limit wait fits:
    it answers <fits> and records each wait asked about."""

    def __init__(self, fits):
        self.fits = fits
        self.asked = []

    def limit_fits(self, seconds):
        self.asked.append(seconds)
        return self.fits


def test_a_limit_wait_the_open_wait_cannot_hold_gives_up_quietly(fixture_gh):
    fixture_gh.reply(BODY, stderr=SECONDARY + "\n", exit=1)
    sleeps = []
    gh = real_gh(fixture_gh, sleeps=sleeps, ORCH_GH_LIMIT_WAIT="30")
    gh.limits.wait = OpenWait(fits=False)

    assert limit_failure(gh) == ""
    assert gh.limits.wait.asked == [30.0]
    assert fixture_gh.argvs() == [BODY]
    assert sleeps == []


def test_a_limit_wait_the_open_wait_holds_is_waited_out_and_retried(fixture_gh):
    fixture_gh.reply(BODY, stderr=SECONDARY + "\n", exit=1, then=[("Body.\n", "", 0)])
    sleeps = []
    gh = real_gh(fixture_gh, sleeps=sleeps)
    gh.limits.wait = OpenWait(fits=True)

    assert gh.issue_body(5) == "Body."
    assert gh.limits.wait.asked == [60.0]
    assert sleeps == [60.0]


def test_a_no_wait_call_gives_up_at_once_on_a_first_secondary_limit(fixture_gh):
    fixture_gh.reply(BODY, stderr=SECONDARY + "\n", exit=1)
    fixture_gh.reply(RATE_LIMIT, pools(0, 5))
    sleeps = []
    gh = real_gh(fixture_gh, sleeps=sleeps)
    gh.limits.no_wait = True

    stderr = limit_failure(gh)

    assert stderr == ("orch: GitHub API rate limit reached - it resets at 2033-05-18T03:33:20Z"
                      + LIMIT_TAIL + "\n")
    assert fixture_gh.argvs() == [BODY, RATE_LIMIT]
    assert sleeps == []


# --- the gh could not death --------------------------------------------------


def test_a_failed_call_dies_naming_the_action_gh_s_first_line_and_the_hint(fixture_gh, capsys):
    fixture_gh.reply(CLOSE_DUPLICATE, stderr="unknown flag: --duplicate-of\nUsage: gh issue close\n",
                     exit=1)
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


# --- the claim delete ------------------------------------------------------------


@pytest.fixture
def claimed(tmp_path):
    """A clone of a bare origin under tmp_path, origin holding a claim on #5:
    (origin's path, the real adapter on the clone)."""
    origin, root = tmp_path / "origin.git", tmp_path / "clone"
    git = origin_clone(origin, root)
    run_git(root, "commit", "-q", "--allow-empty", "-m", "claim")
    run_git(root, "push", "-q", "origin", "HEAD:refs/orch/claims/5")
    return origin, Gh(RepoPin({}, git), {})


def origin_gone(origin):
    """Moves the bare repository at <origin> aside, so its URL no longer
    resolves: one rename, never a delete, since the pushes into it may have
    started git's background maintenance there, and a delete racing that
    maintenance fails on the files it removes."""
    os.rename(str(origin), "%s.gone" % origin)


def claims_on(origin):
    return run_git(origin, "for-each-ref", "--format=%(refname)", "refs/orch/claims/")


def test_a_held_claim_is_deleted_from_origin(claimed):
    origin, gh = claimed

    assert gh.claim_delete(5) is None
    assert claims_on(origin) == ""


def test_a_claim_origin_does_not_hold_counts_as_freed(claimed):
    origin, gh = claimed

    assert gh.claim_delete(9) is None
    assert claims_on(origin) == "refs/orch/claims/5"


def test_any_other_push_failure_fails_the_delete_with_git_s_reason(claimed):
    origin, gh = claimed
    origin_gone(origin)

    with pytest.raises(GhFailed) as failed:
        gh.claim_delete(5)

    assert failed.value.stderr == "fatal: '%s' does not appear to be a git repository\n" % origin


# --- the claim list -------------------------------------------------------------


def claim_pushed(root, n, host, pid, phase, started):
    """A claim on issue #<n> pushed to origin from the clone at <root>, its
    commit message as adapter_claim_create writes it."""
    run_git(root, "commit", "-q", "--allow-empty", "-m", "orch claim %d" % n, "-m",
            "host: %s\npid: %s\nphase: %s\nstarted: %s" % (host, pid, phase, started))
    run_git(root, "push", "-q", "origin", "HEAD:refs/orch/claims/%d" % n)


@pytest.fixture
def claims(tmp_path):
    """A clone of a bare origin under tmp_path, origin holding claims on
    #12, #5 and #9, made in that order: (origin's path, the clone's path,
    the real adapter on the clone)."""
    origin, root = tmp_path / "origin.git", tmp_path / "clone"
    git = origin_clone(origin, root)
    claim_pushed(root, 12, "thirdhost", 7, "review", "2020-01-01T00:00:00Z")
    claim_pushed(root, 5, "otherhost", 5, "spec", "2021-01-01T00:00:00Z")
    claim_pushed(root, 9, "myhost", 1, "implement", "2022-01-01T00:00:00Z")
    return origin, root, Gh(RepoPin({}, git), {})


def test_the_claim_list_reads_each_claim_s_message_in_issue_order(claims):
    _, _, gh = claims

    assert gh.claim_list() == [
        ClaimRow("5", "otherhost", "5", "spec", "2021-01-01T00:00:00Z"),
        ClaimRow("9", "myhost", "1", "implement", "2022-01-01T00:00:00Z"),
        ClaimRow("12", "thirdhost", "7", "review", "2020-01-01T00:00:00Z"),
    ]


def test_the_claim_list_prunes_a_claim_freed_since_the_last_fetch(claims):
    origin, root, gh = claims
    gh.claim_list()
    run_git(origin, "update-ref", "-d", "refs/orch/claims/9")

    assert [row.issue for row in gh.claim_list()] == ["5", "12"]


def test_a_claim_message_missing_a_field_reads_it_as_empty(claims):
    _, root, gh = claims
    run_git(root, "commit", "-q", "--allow-empty", "-m", "orch claim 3", "-m", "host: lone")
    run_git(root, "push", "-q", "origin", "HEAD:refs/orch/claims/3")

    assert gh.claim_list()[0] == ClaimRow("3", "lone", "", "", "")


def test_a_claim_list_origin_cannot_answer_fails_with_git_s_reason(claims):
    origin, _, gh = claims
    origin_gone(origin)

    with pytest.raises(GhFailed) as failed:
        gh.claim_list()

    assert failed.value.stderr.startswith(
        "fatal: '%s' does not appear to be a git repository\n" % origin)


def test_gh_issue_not_found_reads_gh_s_missing_issue_reason():
    assert gh_issue_not_found("GraphQL: Could not resolve to an issue or pull request with the"
                              " number of 99. (repository.issue)\n")
    assert not gh_issue_not_found("HTTP 502: Bad Gateway\n")


# --- the claim create -------------------------------------------------------------


def test_a_claim_create_pushes_a_claim_the_claim_list_reads_back(claims):
    _, root, gh = claims
    git_identity(root)

    assert gh.claim_create(7, "review", 42, "thishost", "2026-03-04T05:06:07Z") is True
    assert ClaimRow("7", "thishost", "42", "review", "2026-03-04T05:06:07Z") in gh.claim_list()


def test_a_claim_create_on_an_issue_origin_holds_a_claim_on_loses_the_race(claims):
    _, root, gh = claims
    git_identity(root)

    assert gh.claim_create(5, "review", 42, "thishost", "2026-03-04T05:06:07Z") is False
    assert ClaimRow("5", "otherhost", "5", "spec", "2021-01-01T00:00:00Z") in gh.claim_list()


def test_a_claim_create_origin_cannot_take_fails_with_git_s_reason(claims):
    origin, root, gh = claims
    git_identity(root)
    origin_gone(origin)

    with pytest.raises(GhFailed) as failed:
        gh.claim_create(7, "spec", 1, "thishost", "2026-03-04T05:06:07Z")

    assert failed.value.stderr == "fatal: '%s' does not appear to be a git repository\n" % origin
