"""The review-pass noun: a review pass's start, for a quick implementation's
step 6 and a standalone review pass alike. run() is the noun's entry point.

begin's guard and numbered report prefix each have one right answer, so they
live here rather than in skill prose. It needs no flow state and may run
where init never did, so it excludes the orchestrator directories itself. It
reads state.json only when one exists (the Flow state reader,
orch/flow_state.py), and never writes it: a branch or issue an active flow
holds belongs to that flow (ADR-0029). It never wipes - each pass takes the
next number, so a second pass on a branch never overwrites the first. Its
checks run in the bash verb's order, every one before any write: the usage,
the plain number, the current branch, the recorded base, the flow-holding
guard; then the exclude lines, the pass directory and the prefix.

known-items builds the pass's known-items file, also with no flow state:
`## Deviations`, the PR body's Deviations or the --deviations file's entries
in their place, then `## Known items`: the declines under Review in the PR
body and in each PR comment that is an earlier pass's (REVIEW_PASS_HEADINGS),
tagged declined, then the Spec rulings lines of every PR comment and each of
the spec issue's Spec ruling comments, joined into one entry - tagged spec
ruling. With no open PR, only the issue's rulings and the --deviations file
are read. CRs are removed from every text read. Its refusals come in the bash
verb's order, every one before the write, and the file is built aside and
moved into place, so a refused or failed run leaves <path> as it was.

Bash keeps serving `orch.sh review-pass` until the cutover.
"""
from __future__ import annotations

import os
import re
from typing import List, Mapping, Optional

from orch.base import recorded_base_into
from orch.checkout import current_branch_or_die
from orch import comments
from orch.common import ORCH_DIR_NAME, die, exclude_orch_dirs, plain_number, read_raw
from orch.flow_state import (
    STATE_UNREADABLE_MSG,
    StateUnreadable,
    flow_holding_phase,
    flow_state_file,
)
from orch.gh import adapter, gh_or_die
from orch.git import Git
from orch.handoff import section_count
from orch.host import flow_cmd
from orch.known_items import known_items_write, section_entries_append, text_entries_append
from orch.marked_comment import SPEC_RULING, NotText, marked_comment_texts
from orch.pr import current_open_pr
from orch.repo import RepoPin
from orch.root import checkout_root

# The verbs. docs_lint.sh reads a converted noun's verbs from this line, so it
# stays one `OPS = "<verb>|..."` line.
OPS = "begin|known-items"

PREFIX = "iteration-"

KNOWN_ITEMS_USAGE = "usage: orch.sh review-pass known-items <issue> <path> [--deviations <file>]"
# A review pass's earlier pass, as standalone step 2 recognises one: a text
# carrying both a Review and a Host fallbacks heading.
REVIEW_PASS_HEADINGS = ("## Review", "## Host fallbacks")
_BLANK_ENDS = re.compile(r"^\s+|\s+$")


def has_headings(text: str, *headings: str) -> bool:
    """Whether <text> has every <heading> as a line of its own outside any
    code fence."""
    return all(section_count(text, heading) > 0 for heading in headings)


def spec_ruling_entries(texts: List[str]) -> List[str]:
    """The entry of each Spec ruling text, in order: its lines trimmed, the
    blank ones dropped, and the rest joined by single spaces - "" for a text
    with none."""
    return [
        " ".join(line for line in (_BLANK_ENDS.sub("", line) for line in text.split("\n"))
                 if line)
        for text in texts
    ]


def next_iteration(directory: str) -> int:
    """One past the largest number of an iteration-<digits>-<rest> name in
    <directory>, read as decimal; 1 when there is none. Any other name is
    skipped, as bash's iteration-[0-9]*-* glob and digits check skip it."""
    largest = 0
    for name in os.listdir(directory):
        rest = name[len(PREFIX):]
        if not name.startswith(PREFIX) or not plain_number(rest[:1]) or "-" not in rest[1:]:
            continue
        number = rest.split("-", 1)[0]
        if plain_number(number) and os.path.exists(os.path.join(directory, name)):
            largest = max(largest, int(number, 10))
    return largest + 1


def begin(argv: List[str], gh, git, pin, env: Mapping[str, str], root: str) -> int:
    """`review-pass begin <issue>`: prints the next numbered report prefix,
    <root>/.orchestrator/review-pass/<branch>/iteration-NN, making the
    directory, unless the current branch is its own base or an active flow
    holds the branch or <issue>."""
    if len(argv) != 1:
        die("usage: orch.sh review-pass begin <issue>")
    issue = argv[0]
    if not plain_number(issue):
        die("issue must be a plain issue number, got: %s" % issue)
    branch = current_branch_or_die(git)
    if branch == recorded_base_into(gh, git, pin, branch):
        die("%s is the base branch - a review pass reviews a branch's change against it;"
            " check out the change's branch" % branch)
    try:
        hold = flow_holding_phase(flow_state_file(root), branch, issue)
    except StateUnreadable:
        die(STATE_UNREADABLE_MSG)
    if hold is not None:
        if hold.phase in ("implement", "review"):
            die("the active flow holds issue #%s at phase %s - this change belongs to that"
                " flow's review loop; run %s" % (hold.issue, hold.phase, flow_cmd(env, "next")))
        if hold.phase == "spec":
            die("the active flow holds issue #%s at phase spec - its change has not been"
                " built yet; run %s" % (hold.issue, flow_cmd(env, "next")))
        die("the active flow holds issue #%s at phase '%s', which is not a flow phase -"
            " refusing to review it; run orch.sh doctor --flow" % (hold.issue, hold.phase))
    exclude_orch_dirs(git)
    directory = os.path.join(root, ORCH_DIR_NAME, "review-pass", branch)
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError:
        die("cannot make the review pass directory %s" % directory)
    print("%s/%s%02d" % (directory, PREFIX, next_iteration(directory)))
    return 0


def known_items(argv: List[str], gh, git) -> int:
    """`review-pass known-items <issue> <path> [--deviations <file>]`:
    writes the pass's known-items file to <path>, overwriting it."""
    if len(argv) < 2:
        die(KNOWN_ITEMS_USAGE)
    issue, path, rest = argv[0], argv[1], argv[2:]
    if not plain_number(issue):
        die("issue must be a plain issue number, got: %s" % issue)
    devfile = ""
    while rest:
        if rest[0] != "--deviations":
            die("unknown argument: %s - %s" % (rest[0], KNOWN_ITEMS_USAGE))
        if len(rest) < 2 or not rest[1]:
            die("--deviations needs a file - " + KNOWN_ITEMS_USAGE)
        devfile, rest = rest[1], rest[2:]
    if devfile:
        if not os.path.isfile(devfile):
            die("deviations file not found: %s" % devfile)
        if not os.access(devfile, os.R_OK):
            die("deviations file not readable: %s" % devfile)

    deviations = declined = rulings = ""
    pr = current_open_pr(gh, git, code=1)
    if pr is not None:
        body = gh_or_die("read the body of PR #%d" % pr, gh.pr_body, pr).replace("\r", "")
        text = comments.rendered(gh, "read the comments of PR #%d" % pr, str(pr), kind="pr")
        text = (text + "\n" if text else "").replace("\r", "")
        if not devfile:
            deviations += section_entries_append(body, "## Deviations")
        declined += section_entries_append(body, "## Review", "declined")
        for comment in comments.split(text):
            if has_headings(comment, *REVIEW_PASS_HEADINGS):
                declined += section_entries_append(comment, "## Review", "declined")
            rulings += section_entries_append(comment, "## Spec rulings", "spec ruling")
    if devfile:
        deviations += text_entries_append((read_raw(devfile) or "").replace("\r", ""))
    issue_comments = comments.trusted(gh, "read the comments of issue #" + issue, issue)
    try:
        texts = marked_comment_texts(SPEC_RULING, issue_comments)
    except NotText:
        die("could not read the comments of issue #%s" % issue)
    rulings += text_entries_append("".join(
        entry + "\n" for entry in spec_ruling_entries(texts)), "spec ruling")
    known_items_write(path, deviations, declined + rulings)
    return 0


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    pin=None,
) -> int:
    """`orch.sh review-pass <op> ...`: the real adapters and the process's
    environment unless a test hands in others. Outside a checkout it dies
    first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die("unknown review-pass op: %s (want %s)" % (op or "<none>", OPS))
    pin = RepoPin(env, git) if pin is None else pin
    gh = adapter(env, pin=pin) if gh is None else gh
    if op == "known-items":
        return known_items(argv[1:], gh, git)
    return begin(argv[1:], gh, git, pin, env, root)
