"""orch.sh's issue noun (ADR-0067): the stateless issue ops on an issue
given its number: the reads (fetch, comments, labels, ready and next) and the
writes (update, comment, publish, triage and close).

run(argv) takes the arguments after `issue`, as orch.sh hands them on, and
returns the exit code; a usage error or a failed gh call dies through
orch.common.die. Every verb keeps the bash noun's usage lines, the order it
checks its arguments in, its stdout, its exit codes and its `orch:` messages,
and checks every argument before its first gh call, so no write lands before
a usage error.

`issue update` stays a dumb "replace the body with these exact bytes"
primitive: fold-in choreography belongs in the calling skill's prose.
"""
from __future__ import annotations

import json
import os
import tempfile
from typing import List, Mapping, Optional

from orch import audit, comments, marked_comment, standing, trust
from orch.common import die, file_write_atomic, list_join, plain_number, state_word, warn
from orch.filed_finding import finding_untriaged, review_labels
from orch.gh import (
    GhFailed,
    Unparsed,
    adapter,
    gh_or_die,
    gh_reason,
    label_listed,
    verify_twice,
)
from orch.git import Git
from orch.host import finding_triage_cmd
from orch.repo import REPO_REMEDY
from orch.root import checkout_root
from orch.triage_labels import TRIAGE_ROLES, TriageLabels

# The verbs, each an Issue method of its name: the dispatch table, in the
# unknown-op message's order. docs_lint.sh reads this line as the verbs the
# noun dispatches, so it stays one `OPS = "<verb>|..."` line.
OPS = "fetch|update|comment|comments|publish|triage|ready|next|labels|close"


class Issue:
    """The verbs, on the gh adapter <gh>, in the checkout <git> reads, with
    <env> naming the host and the knobs."""

    def __init__(self, gh, git, env: Mapping[str, str]) -> None:
        self.gh = gh
        self.git = git
        self.env = env
        self.triage_labels = TriageLabels(git.toplevel)

    def file_op(self, op: str, flag: str, args: List[str]) -> str:
        """The shared check of `issue <op> <n> <file> [<flag>]`: exactly the
        issue and the file, or <flag> alone third where the op has one; the
        issue a plain number. Returns the issue, as given."""
        usage = "usage: orch.sh issue %s <n> <file>%s" % (op, " [%s]" % flag if flag else "")
        if not (len(args) == 2 or (flag and len(args) == 3 and args[2] == flag)):
            die(usage)
        if not plain_number(args[0]):
            die("issue must be a plain issue number, got: %s (%s)" % (args[0], usage))
        return args[0]

    # --- the reads ---

    def fetch(self, args: List[str]) -> int:
        """Writes the issue's body to the file as plain multi-line text, every
        carriage return removed and gh's one newline kept - what agents read -
        then, for an audit-filed body, prints its drift line. With --json it
        writes the issue as one JSON line instead: number, title, body (byte
        for byte), labels and the trusted comments, each {author, createdAt,
        body}. Either way the trust warning comes first, and a failed read
        leaves the file as it was."""
        n = self.file_op("fetch", "--json", args)
        path, as_json = args[1], len(args) == 3
        trust.warn_issue(self.gh, int(n), self.env)
        if as_json:
            text = self.published_json(n) + "\n"
            if not file_write_atomic(path, text):
                die("could not write %s" % path)
            return 0
        body = gh_or_die("read the body of issue #%s" % n, self.gh.issue_body, int(n))
        text = body.replace("\r", "") + "\n"
        if not file_write_atomic(path, text):
            die("could not create a temp file beside %s" % path)
        if audit.MARKER in text:
            line = audit.drift_line(text, self.git)
            if line is not None:
                print(line)
        return 0

    def published_json(self, n: str) -> str:
        """Issue #n as `fetch --json` publishes it, on one line, escaped as
        jq -c escapes it."""
        try:
            published = dict(gh_or_die("read issue #%s" % n, self.gh.issue_json, int(n)))
        except Unparsed:
            die("could not read issue #%s: it did not parse" % n)
        kept = comments.trusted(self.gh, "read the comments of issue #%s" % n, int(n))
        published["comments"] = [
            {field: c.get(field) for field in ("author", "createdAt", "body")} for c in kept
        ]
        # jq escapes DEL, which Python's encoder leaves as it is; a DEL can
        # only stand inside a string.
        return json.dumps(published, ensure_ascii=False, separators=(",", ":")) \
            .replace("\x7f", "\\u007f")

    def comments(self, args: List[str]) -> int:
        """Writes the issue's trusted comments to the file in the rendered
        shape, and by default without the spec review's own changelogs
        (--with-spec-review keeps them); no comments is an empty file. The
        file is written only once the read has succeeded."""
        n = self.file_op("comments", "--with-spec-review", args)
        path, keep_reviews = args[1], len(args) == 3
        kept = comments.trusted(self.gh, "read the comments of issue #%s" % n, int(n))
        try:
            text = comments.render(kept if keep_reviews else marked_comment.drop_spec_reviews(kept))
        except marked_comment.NotText:
            die("could not read the comments of issue #%s" % n)
        text = text.rstrip("\n")
        if not file_write_atomic(path, text + "\n" if text else ""):
            die("could not write the comments of issue #%s to %s" % (n, path))
        return 0

    # --- issue labels ---

    def labels(self, args: List[str]) -> int:
        """One line per issue, in the order named: its number, open or closed,
        then its labels joined by ", ". Every number is checked before any
        read; a failed read dies naming the issue, after the lines already
        printed, and no later issue is read."""
        usage = "usage: orch.sh issue labels <n>..."
        if not args:
            die(usage)
        for n in args:
            if not plain_number(n):
                die("issue must be a plain issue number, got: %s (%s)" % (n, usage))
        for n in args:
            state, labels = gh_or_die("read issue #%s" % n, self.gh.issue_state_labels, int(n))
            joined = list_join(labels)
            print("%s %s%s" % (n, state_word(state), " " + joined if joined else ""))
        return 0

    # --- issue ready ---

    def ready(self, args: List[str]) -> int:
        """0 when the issue carries the repo's ready-for-agent label, 1 when it
        does not; a usage error, no repo or a failed read exits 2, so 1 stays a
        meaningful "no"."""
        usage = "usage: orch.sh issue ready <n>"
        if len(args) != 1:
            die(usage, 2)
        n = args[0]
        if not plain_number(n):
            die("issue must be a plain issue number, got: %s (%s)" % (n, usage), 2)
        if not self.gh.pin():
            die(REPO_REMEDY, 2)
        ready = self.triage_labels.label("ready-for-agent")
        _, labels = gh_or_die("read issue #%s" % n, self.gh.issue_state_labels, int(n), code=2)
        return 0 if label_listed(labels, ready) else 1

    # --- issue next ---

    def next(self, args: List[str]) -> int:
        """Prints the Next issue as <number><TAB><title> and exits 0: the
        oldest issue listed open (its state as GitHub answered it) carrying
        the ready-for-agent role's label and no phase label, that is no
        sub-issue and has no open blocker. Prints nothing and exits 1 when
        none qualifies; a usage error, no repo or a failed read exits 2 with
        nothing on stdout. The parent and blocker reads run for the label
        test's survivors in listing order, stopping at the first that
        qualifies; with no dependency summary, the blocked-by listing is read."""
        if args:
            die("usage: orch.sh issue next", 2)
        if not self.gh.pin():
            die(REPO_REMEDY, 2)
        ready = self.triage_labels.label("ready-for-agent")
        rows = gh_or_die("list the open issues labelled %s" % ready,
                         self.gh.issues_titled_rows, ready, code=2)
        for row in rows:
            if row.state != "OPEN" or standing.phase_labels_in(row.labels):
                continue
            n = row.number
            if gh_or_die("read the parent of issue #%d" % n,
                         self.gh.issue_parent, n, code=2) is not None:
                continue
            blockers = "read the blockers of issue #%d" % n
            open_count = gh_or_die(blockers, self.gh.issue_open_blockers, n, code=2)
            if open_count is None:
                states = gh_or_die(blockers, self.gh.blockers_states, n, code=2)
                open_count = sum(1 for _, state in states if state == "OPEN")
            if open_count == 0:
                print("%d\t%s" % (n, row.title))
                return 0
        return 1

    # --- the writes ---

    def update(self, args: List[str]) -> int:
        n = self.file_op("update", "", args)
        path = args[1]
        if not os.path.isfile(path):
            die("body file not found: " + path)
        # --body-file, never --body: an issue body carries tables, fences and
        # `#nn` references, which a shell mangles.
        gh_or_die("replace the body of issue #" + n, self.gh.issue_body_edit, int(n), path)
        return 0

    def comment(self, args: List[str]) -> int:
        """The stateless counterpart to spec comment: a standalone spec review
        posts its summary on whatever issue it was pointed at."""
        n = self.file_op("comment", "", args)
        path = args[1]
        if not os.path.isfile(path):
            die("body file not found: " + path)
        gh_or_die("comment on issue #" + n, self.gh.issue_comment, int(n), path)
        return 0

    def publish(self, args: List[str]) -> int:
        """The publishing boundary a spec and a quick implementation call:
        files the issue under the ready-for-agent role's label, then reads
        its title and labels back - one retry on a mismatch or a failed read,
        a second failure dying naming the issue, so a half-published spec
        never reaches the next step - and prints its number."""
        if len(args) != 2:
            die("usage: orch.sh issue publish <title> <body-file>")
        title, body_file = args
        if not title:
            die("the title is empty")
        if not os.path.isfile(body_file):
            die("body file not found: " + body_file)
        ready = self.triage_labels.label("ready-for-agent")
        n = gh_or_die("create the issue", self.gh.issue_create, title, body_file, [ready])

        def verified() -> bool:
            got, labels = self.gh.issue_title_labels(n)
            return got == title and label_listed(labels, ready)

        verify_twice(
            "read issue #%d" % n,
            "issue #%d's title and '%s' label did not verify - checked twice, both failed"
            % (n, ready),
            verified,
        )
        print(n)
        return 0

    def triage(self, args: List[str]) -> int:
        """`issue triage <n> [--override | --check]`: moves an open issue to
        the repo's ready-for-agent label, so init --issue can adopt it - the
        planning close's one write to GitHub. One relabel adds ready-for-agent
        and removes the other triage-role labels the issue carries, the
        labels are read back through verify_twice, and one comment names the
        label it now carries. A held label - wontfix ahead of ready-for-human
        - is the human's to reverse: without --override it is printed, exit
        2, and nothing is written. --check writes nothing: the same read and
        role walk, then ready, the held label or movable on stdout."""
        usage = "usage: orch.sh issue triage <n> [--override | --check]"
        n = ""
        override = check = False
        for arg in args:
            if arg == "--override":
                override = True
            elif arg == "--check":
                check = True
            elif arg.startswith("-") or n:
                die(usage)
            else:
                n = arg
        if not plain_number(n) or (check and override):
            die(usage)
        ready = self.triage_labels.label("ready-for-agent")

        state, labels = gh_or_die("read issue #" + n, self.gh.issue_state_labels, int(n))
        if state != "OPEN":
            die("issue #%s is not open - only an open issue is triaged to '%s'" % (n, ready))
        # One walk over the triage roles the issue carries: whether
        # ready-for-agent is among them, the held label, and every other one,
        # to remove.
        is_ready = False
        held = {"wontfix": "", "ready-for-human": ""}
        removed = []
        for role in TRIAGE_ROLES:
            label = self.triage_labels.label(role)
            if not label_listed(labels, label):
                continue
            if role == "ready-for-agent":
                is_ready = True
                continue
            if role in held:
                held[role] = label
            removed.append(label)
        held_label = held["wontfix"] or held["ready-for-human"]
        # A filed finding not yet triaged comes back through finding triage
        # first, which checks it against the default branch (ADR-0031); the
        # gate reads labels, not history, and --override does not bypass it.
        if finding_untriaged(labels, self.triage_labels):
            die(
                "issue #%s is a filed finding (%s) not yet triaged - triage it with %s"
                % (n, review_labels(labels)[0], finding_triage_cmd(self.env))
            )
        if check:
            print("ready" if is_ready else held_label or "movable")
            return 0
        # Already ready: nothing to move, and no comment to leave as noise.
        if is_ready:
            return 0
        if held_label and not override:
            print(held_label)
            return 2

        gh_or_die("relabel issue #" + n, self.gh.issue_relabel, int(n), add=[ready], remove=removed)

        def verified() -> bool:
            _, now = self.gh.issue_state_labels(int(n))
            return label_listed(now, ready) and not any(label_listed(now, gone) for gone in removed)

        # Either death leaves the relabel standing and posts no comment.
        verify_twice(
            "read issue #" + n,
            "issue #%s's '%s' label did not verify - checked twice, both failed" % (n, ready),
            verified,
        )
        self.triage_comment(n, ready)
        return 0

    def triage_comment(self, n: str, ready: str) -> None:
        """Posts the comment naming the label issue #<n> now carries; a
        failure only warns, the relabel already verified."""
        try:
            fd, path = tempfile.mkstemp()
        except OSError:
            die("could not create a temp file for the triage comment on issue #" + n)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write("An orchestrator planning session triaged this issue to `%s`.\n" % ready)
            self.gh.issue_comment(int(n), path)
        except GhFailed as failed:
            warn(
                "warning: issue #%s is labelled %s, but gh could not post the triage"
                " comment on it: %s" % (n, ready, gh_reason(failed.stderr))
            )
        finally:
            os.remove(path)

    def close(self, args: List[str]) -> int:
        """`issue close <n> (--completed | --duplicate-of <m>) --comment-file
        <file>`: the planning close's done-close - closes issue <n> as
        completed, or as a duplicate of <m>, the file's contents its closing
        comment. One gh call, the comment riding on the close; it reads
        nothing back and leaves the labels alone."""
        usage = (
            "usage: orch.sh issue close <n> (--completed | --duplicate-of <m>)"
            " --comment-file <file>"
        )
        n = ""
        completed = False
        dup: Optional[str] = None
        path: Optional[str] = None
        i = 0
        while i < len(args):
            arg = args[i]
            if arg in ("--duplicate-of", "--comment-file"):
                if i + 1 >= len(args):
                    die("%s needs a value (%s)" % (arg, usage))
                if arg == "--duplicate-of":
                    dup = args[i + 1]
                else:
                    path = args[i + 1]
                i += 2
                continue
            if arg == "--completed":
                completed = True
            elif arg.startswith("-"):
                die("unknown option: %s (%s)" % (arg, usage))
            elif n:
                die(usage)
            else:
                n = arg
            i += 1
        if not n:
            die(usage)
        if not plain_number(n):
            die("issue must be a plain issue number, got: %s (%s)" % (n, usage))
        if completed and dup is not None:
            die("give one of --completed or --duplicate-of, not both (%s)" % usage)
        if not completed and dup is None:
            die("give one of --completed or --duplicate-of (%s)" % usage)
        if dup is not None:
            if not plain_number(dup):
                die("--duplicate-of must be a plain issue number, got: %s (%s)" % (dup, usage))
            if dup == n:
                die("issue #%s cannot be a duplicate of itself" % n)
        if path is None:
            die("--comment-file is required (%s)" % usage)
        if not os.path.isfile(path):
            die("comment file not found: " + path)
        if os.path.getsize(path) == 0:
            die("comment file is empty: " + path)

        # As "$(cat)" reads it: every trailing newline dropped.
        with open(path, "rb") as f:
            comment = f.read().decode("utf-8", "surrogateescape").rstrip("\n")
        if dup is not None:
            gh_or_die(
                "close issue #" + n, self.gh.issue_close, int(n),
                comment=comment, duplicate_of=int(dup),
                hint="--duplicate-of needs gh 2.102 or newer",
            )
        else:
            gh_or_die("close issue #" + n, self.gh.issue_close, int(n),
                      reason="completed", comment=comment)
        return 0


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
) -> int:
    """`orch.sh issue <op> ...`: the real adapters and the process's
    environment unless a test hands in fakes. Outside a checkout it dies
    first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    checkout_root(git, env)
    noun = Issue(adapter(env) if gh is None else gh, git, env)
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die("unknown issue op: %s (want %s)" % (op or "<none>", OPS))
    return getattr(noun, op)(argv[1:])
