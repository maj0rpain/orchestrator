"""finding-triage scan in-process, against the gh adapter's fake on a tmp_path
store and FakeGit, with a fake Lines fate function: no repository. Each case
is checked by the scan's stdout, its exit code and its `orch:` message, as
the bash noun prints them."""
from __future__ import annotations

import pytest

from conftest import CHECKOUT, GH_502, checkout, labels_doc
from orch import finding_triage
from orch.gh_fake import FakeGh
from orch.git import FakeGit
from orch.lines_fate import Fate
from orch.repo import RepoPin

HEAD = "a" * 40
FIX = "f" * 40
UNREACHABLE = "0123456789abcdef0123456789abcdef01234567"
USAGE = "orch: usage: orch.sh finding-triage scan [--all] [<issue> | --pr <n>]\n"
ORIGIN = {"origin": "https://github.com/acme/widgets.git"}
REF = "refs/remotes/origin/main"


def body(location, pr="7"):
    """A filed finding's body in the closer's shape, its **Location:** line
    <location>; with no **PR:** line when <pr> is None."""
    lines = ["## Finding", "", "> The reviewer said this.", "", "**Axis:** Standards", "",
             "**Severity:** nit - a reason.", "", "**Location:** " + location, ""]
    if pr is not None:
        lines += ["**PR:** https://github.com/acme/widgets/pull/" + pr, ""]
    return "\n".join(lines + ["**Why not fixed in the loop:** found in the final iteration.\n"])


def finding(seed, n, labels, location, pr="7", state="open"):
    """Issue #n in the store, carrying <labels>, its body a filed finding's
    naming <location> and PR <pr>."""
    seed.issue(n, state, *labels)
    seed.body(n, body(location, pr))


def repo(toplevel=CHECKOUT):
    """The checkout: origin acme/widgets, origin/HEAD naming main, main
    fetched, and the filing commit HEAD resolved."""
    git = FakeGit(ORIGIN, toplevel=toplevel)
    git.seed("is_branch_name", "main", answer=True)
    git.seed("origin_head_branch", answer="main")
    git.seed("fetch_default_branch", "main", answer=True)
    git.seed("resolve_commit", HEAD, answer=HEAD)
    return git


class Fates:
    """A fake Lines fate function: each path's fate, unchanged where none is
    given, and the (filed SHA, ref, path, start, end) of every call."""

    def __init__(self, fates=None):
        self.fates = dict(fates or {})
        self.calls = []

    def __call__(self, git, filed_sha, ref, path, start, end):
        self.calls.append((filed_sha, ref, path, start, end))
        return self.fates.get(path, Fate("unchanged", ""))


def scan(seed, *argv, git=None, fate=None, env=None):
    """`orch.sh finding-triage scan <argv>` in-process: its exit code, a
    SystemExit's included."""
    env = {} if env is None else env
    git = repo() if git is None else git
    pin = RepoPin(env, git)
    gh = FakeGh(seed.store, env, pin=pin, sleep=lambda _: None)
    try:
        return finding_triage.run(["scan", *argv], gh=gh, git=git, env=env, pin=pin,
                                  fate=Fates() if fate is None else fate)
    except SystemExit as died:
        return died.code


def lines(out):
    return out.splitlines()


def test_each_finding_prints_its_six_tab_separated_columns_in_issue_order(seed, capsys):
    finding(seed, 4, ["review:nit", "needs-triage"], "`src/gone.sh:1` at " + HEAD)
    finding(seed, 2, ["review:major", "needs-triage", "bug"], "`src/app.sh:3` at " + HEAD)
    finding(seed, 1, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + HEAD)
    fate = Fates({"src/app.sh": Fate("changed", FIX), "src/gone.sh": Fate("gone", "")})

    assert scan(seed, fate=fate) == 0
    assert capsys.readouterr() == ("".join([
        "1\t7\tsrc/other.sh:2\tunchanged\t-\tneeds-triage\n",
        "2\t7\tsrc/app.sh:3\tchanged\t%s\tneeds-triage\n" % FIX,
        "4\t7\tsrc/gone.sh:1\tgone\t-\tneeds-triage\n",
    ]), "")


def test_the_fate_is_asked_of_the_resolved_sha_at_the_fetched_default_branch(seed, capsys):
    short = HEAD[:10]
    finding(seed, 3, ["review:nit", "needs-triage"], "`src/app.sh:40-41` (and `:41`) at " + short)
    git = repo()
    git.seed("resolve_commit", short, answer=HEAD)
    fate = Fates()

    assert scan(seed, git=git, fate=fate) == 0
    assert fate.calls == [(HEAD, REF, "src/app.sh", 40, 41)]
    assert capsys.readouterr().out == "3\t7\tsrc/app.sh:40-41\tunchanged\t-\tneeds-triage\n"


def test_the_default_branch_is_github_s_answer_when_it_names_one(seed, capsys):
    seed.default_branch("trunk\n")
    finding(seed, 1, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + HEAD)
    git = repo()
    git.seed("is_branch_name", "trunk", answer=True)
    git.seed("fetch_default_branch", "trunk", answer=True)
    fate = Fates()

    assert scan(seed, git=git, fate=fate) == 0
    assert fate.calls[0][1] == "refs/remotes/origin/trunk"


def test_lines_that_never_reached_the_default_branch_are_unknown(seed, capsys):
    short = HEAD[:10]
    finding(seed, 11, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + short, pr="11")
    git = repo()
    git.seed("resolve_commit", short, answer=HEAD)

    assert scan(seed, git=git, fate=Fates({"src/other.sh": Fate("never-reached", "")})) == 0
    assert capsys.readouterr().out == (
        "11\t11\tsrc/other.sh:2\tunknown\tno commit on the default branch since %s touched"
        " src/other.sh:2 - the difference is commits that never reached it\tneeds-triage\n"
        % short)


def test_a_body_with_no_location_line_is_unknown_with_no_location(seed, capsys):
    seed.issue(6, "open", "review:nit", "needs-triage")
    seed.body(6, "A finding written by hand, with no labelled lines.\n")

    assert scan(seed) == 0
    assert capsys.readouterr().out == (
        "6\t-\t-\tunknown\tbody does not parse: no **Location:** line naming"
        " `<file>:<line>` at <SHA>\tneeds-triage\n")


def test_a_body_with_no_pr_line_is_unknown_naming_the_missing_line(seed, capsys):
    finding(seed, 16, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + HEAD, pr=None)

    assert scan(seed) == 0
    assert capsys.readouterr().out == (
        "16\t-\tsrc/other.sh:2\tunknown\tbody does not parse: no **PR:** line ending in a"
        " pull request URL\tneeds-triage\n")


def test_a_sha_still_unreachable_after_fetching_the_pr_head_is_unknown(seed, capsys):
    finding(seed, 5, ["review:major", "needs-triage"], "`src/app.sh:3` at " + UNREACHABLE)
    fate = Fates()

    assert scan(seed, fate=fate) == 0
    assert fate.calls == []
    assert capsys.readouterr().out == (
        "5\t7\tsrc/app.sh:3\tunknown\thead SHA %s is unreachable, even after fetching"
        " refs/pull/7/head\tneeds-triage\n" % UNREACHABLE)


class PrHeadGit(FakeGit):
    """A checkout where only PR <pr>'s head ref holds commit <sha>: it
    resolves once that ref is fetched."""

    def __init__(self, pr, sha, **kwargs):
        super().__init__(**kwargs)
        self.pr, self.sha = pr, sha
        self.fetched = []

    def fetch_pr_head(self, pr):
        self.fetched.append(pr)
        if pr == self.pr:
            self.seed("resolve_commit", self.sha, answer=self.sha)
        return pr == self.pr


def test_a_sha_only_the_pr_head_holds_is_fetched_once_and_scanned(seed, capsys):
    pr_head = "b" * 40
    finding(seed, 7, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + pr_head, pr="8")
    git = PrHeadGit("8", pr_head, remotes=ORIGIN, toplevel=CHECKOUT)
    git.seed("is_branch_name", "main", answer=True)
    git.seed("origin_head_branch", answer="main")
    git.seed("fetch_default_branch", "main", answer=True)
    fate = Fates()

    assert scan(seed, git=git, fate=fate) == 0
    assert git.fetched == ["8"]
    assert fate.calls == [(pr_head, REF, "src/other.sh", 2, 2)]
    assert capsys.readouterr().out == "7\t8\tsrc/other.sh:2\tunchanged\t-\tneeds-triage\n"


def test_only_open_untriaged_filed_findings_are_listed(seed, capsys):
    finding(seed, 1, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + HEAD)
    finding(seed, 8, ["review:nit", "ready-for-agent"], "`src/other.sh:2` at " + HEAD)
    finding(seed, 9, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + HEAD, state="closed")
    finding(seed, 10, ["needs-triage"], "`src/other.sh:2` at " + HEAD)
    finding(seed, 12, ["review:blocking", "needs-triage"], "`src/other.sh:2` at " + HEAD)

    assert scan(seed) == 0
    assert [line.split("\t")[0] for line in lines(capsys.readouterr().out)] == ["1"]


def test_a_finding_with_two_filed_severities_is_scanned_once(seed, capsys):
    finding(seed, 44, ["review:major", "review:nit", "needs-triage"], "`src/other.sh:2` at " + HEAD)

    assert scan(seed) == 0
    assert capsys.readouterr().out == "44\t7\tsrc/other.sh:2\tunchanged\t-\tneeds-triage\n"


def test_an_empty_listing_prints_nothing(seed, capsys):
    assert scan(seed) == 0
    assert capsys.readouterr() == ("", "")


def test_pr_keeps_only_the_findings_filed_from_that_pr(seed, capsys):
    finding(seed, 1, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + HEAD)
    finding(seed, 7, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + HEAD, pr="8")
    seed.issue(6, "open", "review:nit", "needs-triage")
    seed.body(6, "No labelled lines.\n")

    assert scan(seed, "--pr", "8") == 0
    assert capsys.readouterr().out == "7\t8\tsrc/other.sh:2\tunchanged\t-\tneeds-triage\n"


def test_all_lists_every_open_filed_finding_with_its_triage_state(seed, capsys):
    finding(seed, 20, ["review:nit"], "`src/other.sh:2` at " + HEAD)
    finding(seed, 21, ["review:major", "ready-for-human", "bug", "needs-info"],
            "`src/other.sh:2` at " + HEAD)
    finding(seed, 22, ["review:nit", "wontfix"], "`src/other.sh:2` at " + HEAD)
    finding(seed, 23, ["review:nit", "ready-for-agent", "needs-triage"], "`src/other.sh:2` at " + HEAD)
    finding(seed, 24, ["review:nit", "wontfix"], "`src/other.sh:2` at " + HEAD, state="closed")

    assert scan(seed, "--all") == 0
    assert [line.split("\t")[::5] for line in lines(capsys.readouterr().out)] == [
        ["20", "-"], ["21", "needs-info,ready-for-human"], ["22", "wontfix"],
        ["23", "needs-triage,ready-for-agent"]]


def test_the_triage_state_names_the_repo_s_own_labels(seed, tmp_path, capsys):
    git = checkout(tmp_path, labels_doc(("needs-triage", "triage"), ("ready-for-agent", "agent")))
    scanning = repo(toplevel=git.toplevel())
    finding(seed, 23, ["review:nit", "agent", "triage"], "`src/other.sh:2` at " + HEAD)
    finding(seed, 1, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + HEAD)

    assert scan(seed, git=scanning) == 0
    assert capsys.readouterr().out == "23\t7\tsrc/other.sh:2\tunchanged\t-\ttriage,agent\n"


def test_an_explicit_finding_is_scanned_alone(seed, capsys):
    finding(seed, 1, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + HEAD)
    finding(seed, 2, ["review:major", "needs-triage"], "`src/app.sh:3` at " + HEAD)
    seed.fail("adapter_issues_labelled_bodies", GH_502)

    assert scan(seed, "2") == 0
    assert capsys.readouterr().out == "2\t7\tsrc/app.sh:3\tunchanged\t-\tneeds-triage\n"


@pytest.mark.parametrize("argv", [["--all", "8"], ["8", "--all"]])
def test_all_takes_an_explicit_finding_already_triaged(seed, capsys, argv):
    finding(seed, 8, ["review:nit", "ready-for-agent"], "`src/other.sh:2` at " + HEAD)

    assert scan(seed, *argv) == 0
    assert capsys.readouterr().out == "8\t7\tsrc/other.sh:2\tunchanged\t-\tready-for-agent\n"


@pytest.mark.parametrize("all_", [[], ["--all"]])
def test_an_explicit_finding_that_is_not_open_is_refused(seed, capsys, all_):
    finding(seed, 9, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + HEAD, state="closed")

    assert scan(seed, *all_, "9") == 1
    assert capsys.readouterr() == (
        "", "orch: issue #9 is not open - finding triage takes open filed findings only\n")


@pytest.mark.parametrize("labels", [["needs-triage"], ["review:blocking", "needs-triage"]])
def test_an_explicit_issue_with_no_filed_severity_is_refused(seed, capsys, labels):
    finding(seed, 10, labels, "`src/other.sh:2` at " + HEAD)

    assert scan(seed, "10") == 1
    assert capsys.readouterr() == ("", (
        "orch: issue #10 is not a filed finding - it carries no review:<severity> label for"
        " a filed severity (review:major or review:nit)\n"))


def test_an_explicit_finding_not_in_triage_is_refused_naming_the_repo_s_label(seed, tmp_path,
                                                                             capsys):
    git = repo(toplevel=checkout(tmp_path, labels_doc(("needs-triage", "triage"))).toplevel())
    finding(seed, 8, ["review:nit", "ready-for-agent"], "`src/other.sh:2` at " + HEAD)

    assert scan(seed, "8", git=git) == 1
    assert capsys.readouterr() == (
        "", "orch: issue #8 is not in triage - it carries no 'triage' label\n")


def test_a_failed_explicit_read_dies_naming_the_issue(seed, capsys):
    finding(seed, 2, ["review:major", "needs-triage"], "`src/app.sh:3` at " + HEAD)
    seed.fail("adapter_issue_state_labels_body", GH_502)

    assert scan(seed, "2") == 1
    assert capsys.readouterr() == ("", "orch: gh could not read issue #2: HTTP 502: Bad Gateway\n")


@pytest.mark.parametrize("all_", [[], ["--all"]])
def test_a_listing_gh_cannot_read_dies_naming_it(seed, capsys, all_):
    seed.fail("adapter_issues_labelled_bodies", GH_502)

    assert scan(seed, *all_) == 1
    assert capsys.readouterr() == (
        "", "orch: gh could not list the review:major findings: HTTP 502: Bad Gateway\n")


@pytest.mark.parametrize("argv", [
    ["--all", "--all"], ["--all", "--pr"], ["--pr", ""], ["--pr", "8", "--pr", "9"],
    ["--all", "x"], ["--pr", "x"], ["2", "--pr", "8"], ["--all", "8", "--pr", "21"],
    ["2", "3"], [""], ["-1"],
])
def test_a_bad_call_is_a_usage_error_before_any_read(seed, capsys, argv):
    seed.fail("adapter_issues_labelled_bodies", GH_502)
    seed.fail("adapter_issue_state_labels_body", GH_502)

    assert scan(seed, *argv) == 1
    assert capsys.readouterr() == ("", USAGE)


def test_a_failed_fetch_of_the_default_branch_dies_before_any_line(seed, capsys):
    finding(seed, 1, ["review:nit", "needs-triage"], "`src/other.sh:2` at " + HEAD)
    git = repo()
    git.seed("fetch_default_branch", "main", answer=False)

    assert scan(seed, git=git) == 1
    assert capsys.readouterr() == ("", "orch: could not fetch origin/main\n")


@pytest.mark.parametrize("argv", [[], ["prune"]])
def test_an_unknown_verb_dies_with_the_noun_s_usage(seed, capsys, argv):
    env = {}
    git = repo()
    pin = RepoPin(env, git)
    gh = FakeGh(seed.store, env, pin=pin, sleep=lambda _: None)
    with pytest.raises(SystemExit) as died:
        finding_triage.run(argv, gh=gh, git=git, env=env, pin=pin)

    assert died.value.code == 1
    assert capsys.readouterr() == (
        "", "orch: usage: orch.sh finding-triage <scan|apply|bundle> ...\n")
