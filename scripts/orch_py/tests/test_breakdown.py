"""The breakdown noun run in-process against the gh adapter's fake on a
tmp_path store and a FakeGit checkout under tmp_path: breakdown state, read
from the save point and GitHub, and both verbs' argument refusals with the
unknown op's - each checked by its stdout, its exit code and its `orch:`
message, as the bash breakdown noun answered."""
from __future__ import annotations

import pytest

from conftest import GH_502, died_of
from orch import breakdown, cli
from orch.gh_fake import FakeGh
from orch.git import FakeGit
from orch.repo import REPO_REMEDY, RepoPin

# The checkout's origin: a GitHub repo, so the Repo resolves.
ORIGIN = {"origin": "https://github.com/o/r.git"}


def orch_breakdown(root, seed, *argv, remotes=ORIGIN):
    """`orch.sh breakdown <argv>` in-process, in the checkout at <root> with
    <remotes> as its remotes, with the gh fake on <seed>'s store pinned to
    that checkout's origin: its exit code, a SystemExit's included."""
    git = FakeGit(remotes, toplevel=str(root))
    pin = RepoPin({}, git)
    gh = FakeGh(seed.store, {}, pin=pin, sleep=lambda _: None)
    try:
        return breakdown.run(list(argv), gh=gh, git=git, env={}, pin=pin)
    except SystemExit as died:
        return died.code


def save_point(root, parent, *names):
    """Spec issue <parent>'s save point under <root>, holding an empty file
    for each of <names>."""
    directory = root / ".orchestrator" / "breakdown" / str(parent)
    directory.mkdir(parents=True)
    for name in names:
        (directory / name).write_text("")
    return directory


# --- breakdown state ----------------------------------------------------------


def test_a_spec_with_no_saved_draft_and_no_tickets_has_no_breakdown(root, seed, capsys):
    seed.issue(50, "open")

    assert orch_breakdown(root, seed, "state", "50") == 0
    assert capsys.readouterr() == ("none\n", "")


def test_a_spec_with_no_saved_draft_whose_tickets_exist_is_complete(root, seed, capsys):
    seed.issue(50, "open")
    seed.issue(60, "open")
    seed.sub_issue(50, 60)

    assert orch_breakdown(root, seed, "state", "50") == 0
    assert capsys.readouterr() == ("complete\n", "")


def test_a_collapsed_breakdown_with_no_saved_draft_is_complete(root, seed, capsys):
    seed.issue(50, "open")
    seed.body(50, "The spec.\n\n## Ticket\n\nBuild it.\n")

    assert orch_breakdown(root, seed, "state", "50") == 0
    assert capsys.readouterr() == ("complete\n", "")


def test_a_saved_draft_with_no_published_marker_is_partial(root, seed, capsys):
    save_point(root, 50, "draft.md")
    seed.offline()

    assert orch_breakdown(root, seed, "state", "50") == 0
    assert capsys.readouterr() == ("partial\n", "")


def test_the_published_marker_is_complete(root, seed, capsys):
    save_point(root, 50, "draft.md", "published")
    seed.offline()

    assert orch_breakdown(root, seed, "state", "50") == 0
    assert capsys.readouterr() == ("complete\n", "")


@pytest.mark.parametrize("operation, message", [
    ("adapter_sub_issues", "orch: gh could not list sub-issues of #50: HTTP 502: Bad Gateway\n"),
    ("adapter_issue_body", "orch: gh could not read issue #50's body: HTTP 502: Bad Gateway\n"),
])
def test_a_github_state_cannot_read_exits_2_never_none(root, seed, capsys, operation, message):
    seed.issue(50, "open")
    seed.fail(operation, GH_502)

    assert orch_breakdown(root, seed, "state", "50") == 2
    assert capsys.readouterr() == ("", message)


def test_state_with_no_repo_and_an_empty_save_point_exits_2_naming_the_remedy(
        root, seed, capsys):
    seed.issue(50, "open")

    assert orch_breakdown(root, seed, "state", "50", remotes={}) == 2
    assert capsys.readouterr() == ("", "orch: %s\n" % REPO_REMEDY)


@pytest.mark.parametrize("names, answer", [
    (("draft.md",), "partial\n"),
    (("draft.md", "published"), "complete\n"),
])
def test_state_with_no_repo_answers_from_the_save_point_first(root, seed, capsys, names,
                                                             answer):
    save_point(root, 50, *names)

    assert orch_breakdown(root, seed, "state", "50", remotes={}) == 0
    assert capsys.readouterr() == (answer, "")


# --- the refusals -------------------------------------------------------------

STATE_USAGE = "orch: usage: orch.sh breakdown state <parent>\n"
PUBLISH_USAGE = "orch: usage: orch.sh breakdown publish <parent> <draft-file>\n"


@pytest.mark.parametrize("argv, code, message", [
    (("state",), 2, STATE_USAGE),
    (("state", "50", "51"), 2, STATE_USAGE),
    (("state", "abc"), 2, "orch: parent must be a plain issue number, got: abc\n"),
    (("state", ""), 2, "orch: parent must be a plain issue number, got: \n"),
    (("publish",), 1, PUBLISH_USAGE),
    (("publish", "50"), 1, PUBLISH_USAGE),
    (("publish", "50", "d.md", "x"), 1, PUBLISH_USAGE),
    (("publish", "5a", "d.md"), 1, "orch: parent must be a plain issue number, got: 5a\n"),
    (("publish", "", "d.md"), 1, "orch: parent must be a plain issue number, got: \n"),
    ((), 1, "orch: unknown breakdown op: <none> (want publish|state)\n"),
    (("open", "50"), 1, "orch: unknown breakdown op: open (want publish|state)\n"),
])
def test_misuse_is_refused_before_any_read(root, seed, capsys, argv, code, message):
    seed.offline()

    assert orch_breakdown(root, seed, *argv, remotes={}) == code
    assert capsys.readouterr() == ("", message)


def test_the_cli_module_routes_the_breakdown_noun_to_this_module(root, seed, capsys,
                                                                 monkeypatch):
    monkeypatch.setattr(breakdown, "Git", lambda: FakeGit(toplevel=str(root)))

    assert died_of(capsys, lambda: cli.main(["breakdown", "state"])) == (2, "", STATE_USAGE)
