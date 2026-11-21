"""orch.sh's finding-triage noun (ADR-0067): finding triage's scan, apply and
bundle, on the issues a review loop filed (ADR-0031).

run(argv) takes the arguments after `finding-triage`, as orch.sh hands them
on, and returns the exit code; a usage error, a refusal or a failed gh call
dies through orch.common.die, every death exit 1. Every verb keeps the bash
noun's usage lines, the order it checks its arguments in, its stdout and its
`orch:` messages.

The scan reads what became of each finding's lines through a Lines fate
function it is handed - orch.lines_fate's own unless a test hands in another -
and every git command through the git adapter's named operations.
"""
from __future__ import annotations

import os
from typing import Callable, Dict, List, Mapping, Optional, Tuple

from orch.base import default_branch
from orch.common import die, plain_number
from orch.filed_finding import FILED_SEVERITIES, finding_body_parse, has_filed_severity_label
from orch.gh import adapter, gh_or_die, label_listed, open_issue_read
from orch.git import Git
from orch.lines_fate import NEVER_REACHED, lines_fate
from orch.repo import RepoPin
from orch.root import checkout_root
from orch.triage_labels import TRIAGE_ROLES, TriageLabels

# The verbs, each a FindingTriage method of its name. docs_lint.sh reads this
# line as the verbs the noun dispatches, so it stays one `OPS = "<verb>|..."`
# line.
OPS = "scan|apply|bundle"

SCAN_USAGE = "usage: orch.sh finding-triage scan [--all] [<issue> | --pr <n>]"

NO_LOCATION = "body does not parse: no **Location:** line naming `<file>:<line>` at <SHA>"
NO_PR = "body does not parse: no **PR:** line ending in a pull request URL"


class FindingTriage:
    """The verbs, on the gh adapter <gh>, in the checkout <git> reads, its
    repo pinned by <pin>, with <env> naming the host and the knobs and
    <fate> the Lines fate function the scan reads."""

    def __init__(self, gh, git, env: Mapping[str, str], pin, fate: Callable) -> None:
        self.gh = gh
        self.git = git
        self.env = env
        self.pin = pin
        self.fate = fate
        self.triage_labels = TriageLabels(git.toplevel)

    def triage_state(self, labels: List[str]) -> str:
        """The triage-role labels among <labels>, each by the repo's label
        for its role, comma-joined in TRIAGE_ROLES order - or - for none."""
        held = [label for label in map(self.triage_labels.label, TRIAGE_ROLES)
                if label_listed(labels, label)]
        return ",".join(held) or "-"

    # --- scan ---

    def scan(self, args: List[str]) -> int:
        """Read-only. Sorts each open filed finding still in needs-triage -
        or, with --all, whatever its triage label - against
        origin/<default>, one tab-separated line apiece, in issue order:
        <issue> <pr> <file>:<line> <result> <detail> <triage state>."""
        every, issue, pr_filter = scan_args(args)
        triage = self.triage_labels.label("needs-triage")
        # A listed finding is read by its listing, labels and body together;
        # an explicit one by its single read, where it is checked.
        found: Dict[int, Tuple[List[str], str]] = {}
        if issue:
            labels, body = open_issue_read(
                self.gh, issue,
                "issue #%s is not open - finding triage takes open filed findings only" % issue,
                body=True)
            if not has_filed_severity_label(labels):
                die("issue #%s is not a filed finding - it carries no review:<severity> label"
                    " for a filed severity (%s)"
                    % (issue, " or ".join("review:" + sev for sev in FILED_SEVERITIES)))
            if not every and not label_listed(labels, triage):
                die("issue #%s is not in triage - it carries no '%s' label" % (issue, triage))
            found[int(issue)] = (labels, body)
        else:
            others = [] if every else [triage]
            for sev in FILED_SEVERITIES:
                listed = gh_or_die("list the review:%s findings" % sev,
                                   self.gh.issues_labelled_bodies, "review:" + sev, *others)
                for row in listed:
                    found[row.number] = (row.labels, row.body)
        branch = default_branch(self.gh, self.git, self.pin).name
        if not self.git.fetch_default_branch(branch):
            die("could not fetch origin/" + branch)
        ref = "refs/remotes/origin/" + branch
        for n in sorted(found):
            labels, body = found[n]
            line = self.scan_one(n, body, ref, self.triage_state(labels), pr_filter)
            if line is not None:
                print(line)
        return 0

    def scan_one(self, n: int, body: str, ref: str, roles: str,
                 pr_filter: str) -> Optional[str]:
        """The scan's line for one finding; None when <pr_filter> is given
        and the body names another PR."""
        finding = finding_body_parse(body)
        pr, path, lines, sha = finding.pr_number, finding.file, finding.line, finding.sha
        if pr_filter and pr != pr_filter:
            return None
        location, detail = "%s:%s" % (path, lines), ""
        if not path:
            location, result, detail = "-", "unknown", NO_LOCATION
        elif not pr:
            result, detail = "unknown", NO_PR
        else:
            resolved = self.git.resolve_commit(sha)
            if resolved is None:
                # A squash merge leaves the PR's head commit off every branch:
                # the PR's own head ref is fetched, once, in case it holds it.
                self.git.fetch_pr_head(pr)
                resolved = self.git.resolve_commit(sha)
            if resolved is None:
                result = "unknown"
                detail = "head SHA %s is unreachable, even after fetching refs/pull/%s/head" % (
                    sha, pr)
            else:
                start, _, end = lines.partition("-")
                result, detail = self.fate(self.git, resolved, ref, path, int(start),
                                           int(end or start))
                if result == NEVER_REACHED:
                    result = "unknown"
                    detail = ("no commit on the default branch since %s touched %s:%s - the"
                              " difference is commits that never reached it" % (sha, path, lines))
        return "\t".join([str(n), pr or "-", location, result, detail or "-", roles])


def scan_args(args: List[str]) -> Tuple[bool, str, str]:
    """scan's arguments, as the bash verb reads them: whether --all is
    given, the explicit issue and the --pr filter, each "" when not given.
    Dies with the usage on any other shape, or on an issue or a PR that is
    not a plain number."""
    every, pr_filter, rest = False, "", []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--all":
            if every:
                die(SCAN_USAGE)
            every = True
        elif arg == "--pr":
            if pr_filter or i + 1 >= len(args) or not args[i + 1]:
                die(SCAN_USAGE)
            pr_filter = args[i + 1]
            i += 1
        else:
            rest.append(arg)
        i += 1
    if len(rest) > 1 or (rest and (pr_filter or not rest[0])):
        die(SCAN_USAGE)
    issue = rest[0] if rest else ""
    if (issue or pr_filter) and not plain_number(issue + pr_filter):
        die(SCAN_USAGE)
    return every, issue, pr_filter


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    pin=None,
    fate: Callable = lines_fate,
) -> int:
    """`orch.sh finding-triage <op> ...`: the real adapters, the process's
    environment and the real Lines fate unless a test hands in others.
    Outside a checkout it dies first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    checkout_root(git, env)
    pin = RepoPin(env, git) if pin is None else pin
    noun = FindingTriage(adapter(env, pin=pin) if gh is None else gh, git, env, pin, fate)
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die("usage: orch.sh finding-triage <scan|apply|bundle> ...")
    return getattr(noun, op)(argv[1:])
