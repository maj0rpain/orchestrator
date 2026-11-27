"""The gh adapter's in-process fake, on the file store the bash fake keeps.

FakeGh offers the real adapter's operations (orch.gh.Gh) on the directory
ORCH_GH_FAKE_STORE names, in the layout scripts/test/gh_adapter_fake.sh
documents, so what a bash orch.sh process wrote is there for a Python one and
the other way round. orch.gh.adapter() picks it whenever ORCH_GH_FAKE_STORE
is set.

Each operation honours the store's failure files under the bash adapter's
operation name - adapter_<the method's name>, kept by an operation whose bash
counterpart is gone, as adapter_issues_labelled_bodies is - read before the
operation touches the store: fail/<operation>, with its fail/<operation>.after and
fail/<operation>.times countdowns, offline, ratelimit and noauth. A failure
goes through the real adapter's rate-limit handling (orch.gh.Limits), the
rate_limit read answering from the store's quota. The reads the bash fake
lets lag (lag/<operation>, .after and .stale) lag here too, the stale answer
read in the shape the real operation reads gh's. Not honoured: hold/, a fifo
that parks a bash call.

FakeStore seeds and reads back the store as the bash suite's fake_* helpers
do, for a test that runs orch.sh on it.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import time
from typing import Callable, List, Mapping, Optional, Sequence, Tuple

from orch import gh as real
from orch.common import file_lines, plain_number, read_raw, read_text
from orch.gh import Check, Checks, GhFailed, IssueRow, LabelledBody, Limits

# The author and timestamp of every comment the fake's own operations write.
COMMENT_AUTHOR = "fake-gh"
COMMENT_CREATED = "2026-01-01T00:00:00Z"
OFFLINE = "dial tcp: lookup api.github.com: no such host\n"
NOAUTH = "HTTP 401: Bad credentials (https://api.github.com/graphql)\n"
# What the store answers for an issue's creation or a PR's merge time it does
# not hold, and for a PR's head SHA.
EPOCH = "1970-01-01T00:00:00Z"
NO_HEAD_OID = "0" * 40
_RUNS = "https://github.com/acme/widgets/actions/runs"
_EXT_CI = "https://ci.example.com/build/9"
# gh's line where a PR has no checks, as bash fake_no_checks prints it.
NO_CHECKS = "no checks reported on the 'topic' branch\n"
# The checks each scripted answer stands for, as fake_checks_answer prints
# them; boom is a connection error, and none and empty no checks at all -
# none with gh's NO_CHECKS line, empty with no word from gh.
CHECKS_ANSWERS = {
    "green": [Check("pass", "build", _RUNS + "/1/job/1")],
    "failing": [Check("fail", "build", _RUNS + "/4242/job/77"),
                Check("pass", "lint", _RUNS + "/1/job/1")],
    "cancel": [Check("cancel", "build", _RUNS + "/5150/job/9")],
    "external": [Check("pass", "lint", _RUNS + "/1/job/1"), Check("fail", "ext-ci", _EXT_CI),
                 Check("fail", "build", _RUNS + "/4242/job/77")],
    "tworuns": [Check("fail", "build", _RUNS + "/4242/job/77"),
                Check("fail", "test", _RUNS + "/4343/job/78")],
    "onerun": [Check("fail", "build", _RUNS + "/4242/job/77"),
               Check("fail", "test", _RUNS + "/4242/job/78")],
    "mixed": [Check("fail", "build", _RUNS + "/4242/job/77"), Check("fail", "ext-ci", _EXT_CI)],
    "badrunid": [Check("fail", "build", _RUNS + "/12abc")],
    "comma": [Check("fail", "build (linux, x64)", _RUNS + "/4242/job/77")],
    "pending": [Check("pending", "build", "")],
    "none": [],
    "empty": [],
}


def _write(path: str, text: str, mode: str = "wb") -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode) as f:
        f.write(text.encode("utf-8", "surrogateescape"))


def _first_line(path: str) -> str:
    """The file's first line; "" where it is missing or empty."""
    lines = file_lines(path)
    return lines[0] if lines else ""


def _lines(path: str) -> List[str]:
    """The file's non-empty lines; none where it is unreadable."""
    return [line for line in file_lines(path) if line]


def _countdown(path: str) -> bool:
    """True while the count the file holds is above zero, counting it down
    by one; False where it is absent or at zero."""
    text = read_raw(path)
    if text is None:
        return False
    count = real.number_of(text)
    if count <= 0:
        return False
    _write(path, "%d\n" % (count - 1))
    return True


def _line_append_once(path: str, n: int) -> None:
    """<n> appended to the file as a line of its own, unless a line already
    holds it - the counterpart of _lines_drop."""
    if str(n) not in _lines(path):
        _write(path, "%d\n" % n, "ab")


def _lines_drop(path: str, line: str) -> None:
    """Every line of the file that is exactly <line> dropped, as the bash
    fake's fake_lines_drop drops it; nothing where the file is absent."""
    text = read_raw(path)
    if text is None:
        return
    _write(path, "".join(kept + "\n" for kept in real.lines_of(text) if kept != line))


def _numbered(directory: str) -> List[str]:
    """The names of the directory's entries, in numeric order."""
    try:
        names = os.listdir(directory)
    except OSError:
        return []
    return sorted(names, key=lambda name: int(name) if plain_number(name) else 0)


def _store_path(store: str, *parts: object) -> str:
    """The path of <parts> under the store at <store>, in the fake_* layout."""
    return os.path.join(store, *(str(part) for part in parts))


def _issue_path(store: str, n: int, *parts: str) -> str:
    """The path of <parts> under issue #n's directory in the store."""
    return _store_path(store, "issues", n, *parts)


def _pr_path(store: str, n: int, *parts: str) -> str:
    """The path of <parts> under PR #n's directory in the store."""
    return _store_path(store, "prs", n, *parts)


def _labels_write(store: str, n: int, labels: Sequence[str]) -> None:
    """Issue #n's labels in the store at <store>: exactly <labels>, one a
    line, in order."""
    _write(_issue_path(store, n, "labels"), "".join(label + "\n" for label in labels))


def _comment_write(directory: str, author: str, created: str, association: str,
                   body: str) -> None:
    """A comment after any <directory> holds: the next number's directory,
    with its author, created, association and body files."""
    comment = os.path.join(directory, str(len(_numbered(directory)) + 1))
    _write(os.path.join(comment, "author"), author + "\n")
    _write(os.path.join(comment, "created"), created + "\n")
    _write(os.path.join(comment, "association"), association + "\n")
    _write(os.path.join(comment, "body"), body)


class FakeGh:
    """The fake operations on the store at <store>. <env> holds the knobs
    the rate-limit handling and the listing read; <pin>, when given, answers
    pin() as the real adapter's does and its git adapter the main checkout an
    autopilot process's limit record is written under, else the repo is
    taken as resolved and the main checkout as unreadable."""

    def __init__(
        self,
        store: str,
        env: Mapping[str, str],
        pin=None,
        sleep: Callable[[float], None] = time.sleep,
        now: Callable[[], float] = time.time,
    ) -> None:
        self.store = store
        self.env = env
        self.repo_pin = pin
        self.now = now
        self.limits = Limits(env, self._rate_limit, sleep, now,
                             pin.git.main_checkout if pin is not None else lambda: None)

    def pin(self) -> bool:
        return self.repo_pin is None or self.repo_pin.resolve() is not None

    # --- the store ---

    def _known(self, n: int) -> None:
        """Fails as `gh issue view` does where the store holds no issue #n."""
        if not os.path.isdir(_issue_path(self.store, n)):
            raise GhFailed(
                "GraphQL: Could not resolve to an issue or pull request with the"
                " number of %d. (repository.issue)\n" % n
            )

    def _seeded_failure(self, operation: str) -> Optional[str]:
        """The stderr of the failure the store seeds for <operation>, a
        countdown counted; None where none fails it."""
        if operation != "adapter_rate_limit":
            limited = read_raw(_store_path(self.store, "ratelimit"))
            if limited is not None:
                return limited
        if os.path.isfile(_store_path(self.store, "offline")):
            return OFFLINE
        if os.path.isfile(_store_path(self.store, "noauth")):
            return NOAUTH
        fail = _store_path(self.store, "fail", operation)
        stderr = read_raw(fail)
        if stderr is None or _countdown(fail + ".after"):
            return None
        times = read_raw(fail + ".times")
        if times is not None:
            if real.number_of(times) <= 1:
                os.remove(fail)
                os.remove(fail + ".times")
            else:
                _write(fail + ".times", "%d\n" % (real.number_of(times) - 1))
        return stderr

    def _fail_raw(self, operation: str) -> None:
        stderr = self._seeded_failure(operation)
        if stderr is not None:
            raise GhFailed(stderr)

    def _failing(self, operation: str, compound: bool = False) -> None:
        """Raises the seeded failure of <operation>, through the rate-limit
        handling: a secondary limit seeded is waited out and the failure files
        read again, once - unless the call is a <compound> write."""
        self.limits.run(lambda: self._fail_raw(operation), compound)

    def _lagging(self, operation: str) -> Optional[str]:
        """The stale answer while the operation's lag countdown is above zero,
        counting it down ("" where fake_lag gave none); else None."""
        lag = _store_path(self.store, "lag", operation)
        if not os.path.isfile(lag) or _countdown(lag + ".after"):
            return None
        if not _countdown(lag):
            return None
        return read_raw(lag + ".stale") or ""

    def _rate_limit(self) -> str:
        self._fail_raw("adapter_rate_limit")
        quota = read_raw(_store_path(self.store, "quota"))
        if quota is not None:
            return quota
        reset = int(self.now()) + 3600
        return "core\t5000\t5000\t%d\ngraphql\t5000\t5000\t%d\n" % (reset, reset)

    def _labels(self, n: int) -> List[str]:
        return _lines(_issue_path(self.store, n, "labels"))

    def _label_canon(self, name: str) -> str:
        """GitHub's casing rule: the name as the repo's labels hold it in any
        casing, else as given."""
        for line in _lines(_store_path(self.store, "labels")):
            known = line.split("\t", 1)[0]
            if real.label_listed([known], name):
                return known
        return name

    def _comment_append(self, directory: str, body: str) -> None:
        _comment_write(directory, COMMENT_AUTHOR, COMMENT_CREATED, "OWNER", body)

    def _pr_known(self, n: int) -> None:
        """Fails as `gh pr view` does where the store holds no PR #n."""
        if not os.path.isdir(_pr_path(self.store, n)):
            raise GhFailed(
                "GraphQL: Could not resolve to a PullRequest with the number of %d."
                " (repository.pullRequest)\n" % n
            )

    def _comments(self, n: int, directory: str) -> List[dict]:
        """The comments under <directory>, numerically ordered, as gh's raw
        objects; each url names issue #n, as the bash fake's do for an issue
        and a PR alike."""
        comments = []
        for k in _numbered(directory):
            comment = os.path.join(directory, k)
            comments.append({
                "author": {"login": read_text(os.path.join(comment, "author")) or ""},
                "authorAssociation": read_text(os.path.join(comment, "association")) or "OWNER",
                "createdAt": read_text(os.path.join(comment, "created")) or "",
                "body": read_raw(os.path.join(comment, "body")) or "",
                "url": "https://github.com/o/r/issues/%d#issuecomment-%s" % (n, k),
            })
        return comments

    def _open_numbers(self) -> List[int]:
        """The open issues the store holds, pull requests left out, oldest
        first."""
        numbers = []
        for name in _numbered(_store_path(self.store, "issues")):
            if not plain_number(name) or os.path.exists(_issue_path(self.store, int(name), "pull")):
                continue
            if _first_line(_issue_path(self.store, int(name), "state")) == "OPEN":
                numbers.append(int(name))
        return numbers

    def _labelled_open(self, *labels: str) -> List[int]:
        """The open issues carrying every label, cut at the search limit as a
        labelled listing is."""
        limit = min(real.issue_list_limit(self.env), real.ISSUE_SEARCH_CAP)
        return [n for n in self._open_numbers()
                if all(real.label_listed(self._labels(n), label) for label in labels)][:limit]

    def _next_number(self, counter_name: str = "next_issue") -> int:
        """The number a new issue takes - or a new PR, under next_pr - the
        counter's, or one past the highest issue or PR number the store
        holds, the two sharing GitHub's numbering; the counter advanced."""
        counter = _store_path(self.store, counter_name)
        seeded = read_text(counter)
        if seeded:
            n = real.number_of(seeded)
        else:
            held = [int(name) for kind in ("issues", "prs")
                    for name in _numbered(_store_path(self.store, kind)) if plain_number(name)]
            n = max(held, default=0) + 1
        _write(counter, "%d\n" % (n + 1))
        return n

    # --- issue operations ---

    def issue_body(self, n: int) -> str:
        self._failing("adapter_issue_body")
        self._known(n)
        return read_raw(_issue_path(self.store, n, "body")) or ""

    def issue_json(self, n: int) -> dict:
        self._failing("adapter_issue_json")
        self._known(n)
        return {
            "number": n,
            "title": read_text(_issue_path(self.store, n, "title")) or "",
            "body": read_raw(_issue_path(self.store, n, "body")) or "",
            "labels": self._labels(n),
        }

    def issue_comments(self, n: int) -> List[dict]:
        _write(_store_path(self.store, "comment_reads"), "x\n", "ab")
        self._failing("adapter_issue_comments")
        stale = self._lagging("adapter_issue_comments")
        if stale is not None:
            return real.parse_comments(stale)
        self._known(n)
        return self._comments(n, _issue_path(self.store, n, "comments"))

    def issue_authorship(self, n: int) -> Tuple[str, str, str, str]:
        """The stored authorship; absent, fake-gh as OWNER, the body never
        edited nor the title renamed."""
        self._failing("adapter_issue_authorship")
        self._known(n)

        def stored(name: str, absent: str) -> str:
            value = read_text(_issue_path(self.store, n, name))
            return absent if value is None else value

        return (stored("author", COMMENT_AUTHOR), stored("association", "OWNER"),
                stored("editor", ""), stored("renamer", ""))

    def issue_state(self, n: int) -> str:
        """PULL for a PR the store holds or an issue number marked pull, the
        stored state otherwise."""
        self._failing("adapter_issue_state")
        if os.path.isdir(_store_path(self.store, "prs", n)):
            return "PULL"
        self._known(n)
        if os.path.exists(_issue_path(self.store, n, "pull")):
            return "PULL"
        return read_text(_issue_path(self.store, n, "state")) or ""

    def issue_created_at(self, n: int) -> str:
        """The stored created_at; the epoch where unset."""
        self._failing("adapter_issue_created_at")
        self._known(n)
        created = read_text(_issue_path(self.store, n, "created_at"))
        return EPOCH if created is None else created

    def issue_state_labels(self, n: int) -> Tuple[str, List[str]]:
        self._failing("adapter_issue_state_labels")
        stale = self._lagging("adapter_issue_state_labels")
        if stale is not None:
            return real.first_and_rest(stale)
        self._known(n)
        return read_text(_issue_path(self.store, n, "state")) or "", self._labels(n)

    def issue_state_labels_body(self, n: int) -> Tuple[str, List[str], str]:
        self._failing("adapter_issue_state_labels_body")
        self._known(n)
        body = read_text(_issue_path(self.store, n, "body")) or ""
        return _first_line(_issue_path(self.store, n, "state")), self._labels(n), body

    def issue_title_labels(self, n: int) -> Tuple[str, List[str]]:
        self._failing("adapter_issue_title_labels")
        stale = self._lagging("adapter_issue_title_labels")
        if stale is not None:
            return real.first_and_rest(stale)
        self._known(n)
        return read_text(_issue_path(self.store, n, "title")) or "", self._labels(n)

    def issues_titled_rows(self, label: str) -> List[IssueRow]:
        self._failing("adapter_issues_titled_rows")
        stale = self._lagging("adapter_issues_titled_rows")
        if stale is not None:
            rows = real.parse_titled_rows(stale)
        else:
            rows = [
                IssueRow(n, _first_line(_issue_path(self.store, n, "state")),
                         read_text(_issue_path(self.store, n, "title")) or "", self._labels(n))
                for n in self._labelled_open(label)
            ]
        real.labelled_limit_warn(self.env, len(rows), label)
        return rows

    def issues_open_titles(self) -> List[Tuple[int, str]]:
        self._failing("adapter_issues_open_titles")
        return [(n, read_text(_issue_path(self.store, n, "title")) or "")
                for n in reversed(self._open_numbers())]

    def issues_labelled_bodies(self, *labels: str) -> List[LabelledBody]:
        self._failing("adapter_issues_labelled_bodies")
        rows = [
            LabelledBody(n, self._labels(n),
                         read_text(_issue_path(self.store, n, "body")) or "")
            for n in self._labelled_open(*labels)
        ]
        real.labelled_limit_warn(self.env, len(rows), *labels)
        return rows

    def issue_create(self, title: str, body_file: str, labels: Sequence[str]) -> int:
        self._failing("adapter_issue_create")
        n = self._next_number()
        _write(_issue_path(self.store, n, "state"), "OPEN\n")
        _write(_issue_path(self.store, n, "title"), title + "\n")
        _write(_issue_path(self.store, n, "body"), read_raw(body_file) or "")
        kept: List[str] = []
        for label in labels:
            if not real.label_listed(kept, label):
                kept.append(self._label_canon(label))
        _labels_write(self.store, n, kept)
        return n

    def issue_body_edit(self, n: int, body_file: str) -> None:
        self._failing("adapter_issue_body_edit")
        self._known(n)
        _write(_issue_path(self.store, n, "body"), read_raw(body_file) or "")

    def issue_comment(self, n: int, body_file: str) -> None:
        self._failing("adapter_issue_comment")
        self._known(n)
        self._comment_append(_issue_path(self.store, n, "comments"), read_raw(body_file) or "")

    def issue_relabel(
        self, n: int, add: Sequence[str] = (), remove: Sequence[str] = ()
    ) -> None:
        # With nothing named, the real one makes no gh call, so nothing fails.
        if not add and not remove:
            return
        self._failing("adapter_issue_relabel")
        self._known(n)
        labels = [have for have in self._labels(n) if not real.label_listed(remove, have)]
        for label in add:
            if not real.label_listed(labels, label):
                labels.append(self._label_canon(label))
        _labels_write(self.store, n, labels)

    def issue_close(
        self,
        n: int,
        reason: str = "",
        comment: str = "",
        duplicate_of: Optional[int] = None,
    ) -> None:
        """Closes the stored issue, as GitHub does: closing one already
        CLOSED succeeds and leaves it as it is, with no comment."""
        self._failing("adapter_issue_close", compound=bool(comment))
        self._known(n)
        if read_text(_issue_path(self.store, n, "state")) == "CLOSED":
            return
        if comment:
            self._comment_append(_issue_path(self.store, n, "comments"), comment)
        _write(_issue_path(self.store, n, "state"), "CLOSED\n")
        if duplicate_of is not None:
            _write(_issue_path(self.store, n, "reason"), "duplicate\n")
            _write(_issue_path(self.store, n, "duplicate_of"), "%d\n" % duplicate_of)
        else:
            _write(_issue_path(self.store, n, "reason"), (reason or "completed") + "\n")

    def issue_reopen(self, n: int) -> None:
        """The stored issue OPEN again, its close reason and duplicate gone."""
        self._failing("adapter_issue_reopen")
        self._known(n)
        _write(_issue_path(self.store, n, "state"), "OPEN\n")
        for name in ("reason", "duplicate_of"):
            path = _issue_path(self.store, n, name)
            if os.path.lexists(path):
                os.remove(path)

    # --- label operations ---

    def label_create(self, name: str, colour: str, description: str) -> None:
        """The label added to the store where it has none of that name in
        any casing; one it has fails the call, as gh does, left as it is."""
        self._failing("adapter_label_create")
        labels = _store_path(self.store, "labels")
        if any(real.label_listed([line.split("\t", 1)[0]], name) for line in _lines(labels)):
            raise GhFailed(
                'label with name "%s" already exists; use `--force` to update its color'
                " and description\n" % name
            )
        _write(labels, "%s\t%s\t%s\n" % (name, colour, description), "ab")

    def label_upsert(self, name: str, colour: str, description: str) -> None:
        """The label, created or rewritten, in the store: named as the
        store holds it in any casing, moved to the end, as the bash fake's
        fake_label_put does."""
        self._failing("adapter_label_upsert")
        labels = _store_path(self.store, "labels")
        name = self._label_canon(name)
        kept = "".join(line + "\n" for line in file_lines(labels)
                       if line.split("\t", 1)[0] != name)
        _write(labels, "%s%s\t%s\t%s\n" % (kept, name, colour, description))

    # --- repo operations ---

    def repo_default_branch(self, repo: str) -> str:
        """The stored default_branch answer less its trailing newlines; a
        store with none fails it, as gh does for a repo it cannot resolve."""
        self._failing("adapter_repo_default_branch")
        answer = read_text(_store_path(self.store, "default_branch"))
        if answer is None:
            raise GhFailed(
                "GraphQL: Could not resolve to a Repository with the name '%s'."
                " (repository)\n" % repo
            )
        return answer

    # --- sub-issue and dependency operations ---

    def issue_parent(self, n: int) -> Optional[int]:
        self._failing("adapter_issue_parent")
        self._known(n)
        subs = _store_path(self.store, "subs")
        for parent in sorted(os.listdir(subs)) if os.path.isdir(subs) else []:
            if str(n) in file_lines(os.path.join(subs, parent)):
                return int(parent)
        return None

    def _blockers(self, n: int) -> List[int]:
        return [int(line) for line in _lines(_store_path(self.store, "blocked_by", n))
                if plain_number(line)]

    def _open_count(self, n: int) -> int:
        """How many of #n's stored blockers are still open."""
        return sum(1 for b in self._blockers(n)
                   if _first_line(_issue_path(self.store, b, "state")) == "OPEN")

    def sub_issues(self, parent: int) -> List[real.SubIssue]:
        """The stored sub-issues, in link order, each with its stored state
        and its count of open blockers."""
        self._failing("adapter_sub_issues")
        stale = self._lagging("adapter_sub_issues")
        if stale is not None:
            return real.parse_sub_issues(stale)
        self._known(parent)
        return [real.SubIssue(int(n), _first_line(_issue_path(self.store, int(n), "state")),
                              self._open_count(int(n)))
                for n in _lines(_store_path(self.store, "subs", parent)) if plain_number(n)]

    def blockers(self, n: int) -> List[int]:
        self._failing("adapter_blockers")
        stale = self._lagging("adapter_blockers")
        if stale is not None:
            return real.parse_numbers(stale, real.blocker_unparsed)
        self._known(n)
        return self._blockers(n)

    def sub_issue_link(self, parent: int, child: int) -> None:
        """The child appended to the parent's stored sub-issues, once."""
        self._failing("adapter_sub_issue_link")
        self._known(parent)
        self._known(child)
        _line_append_once(_store_path(self.store, "subs", parent), child)

    def sub_issue_unlink(self, parent: int, child: int) -> None:
        """The child dropped from the parent's stored sub-issues."""
        self._failing("adapter_sub_issue_unlink")
        self._known(parent)
        self._known(child)
        _lines_drop(_store_path(self.store, "subs", parent), str(child))

    def blocker_add(self, n: int, blocker: int) -> None:
        """The blocker appended to #n's stored blockers, once - GitHub stores
        an edge once however often it is asked for."""
        self._failing("adapter_blocker_add")
        self._known(n)
        self._known(blocker)
        _line_append_once(_store_path(self.store, "blocked_by", n), blocker)

    def blocker_remove(self, n: int, blocker: int) -> None:
        """The blocker dropped from #n's stored blockers."""
        self._failing("adapter_blocker_remove")
        self._known(n)
        self._known(blocker)
        _lines_drop(_store_path(self.store, "blocked_by", n), str(blocker))

    def issue_open_blockers(self, n: int) -> Optional[int]:
        self._failing("adapter_issue_open_blockers")
        self._known(n)
        if str(n) in file_lines(_store_path(self.store, "no_dependency_summary")):
            return None
        return self._open_count(n)

    def blockers_states(self, n: int) -> List[Tuple[int, str]]:
        self._failing("adapter_blockers_states")
        self._known(n)
        return [(b, _first_line(_issue_path(self.store, b, "state"))) for b in self._blockers(n)]


    # --- PR operations ---

    def prs_open(self, head: str, base: str = "") -> List[str]:
        """The open PRs from <head>, into <base> where one is named, newest
        first, each `<number><TAB><flag>`, the flag the stored
        cross_repository file as stored, false where unset."""
        self._failing("adapter_prs_open")
        return ["%s\t%s" % (name, self._cross(d)) for name, d in self._prs("OPEN")
                if read_text(os.path.join(d, "head")) == head
                and (not base or read_text(os.path.join(d, "base")) == base)]

    def _prs(self, state: str):
        """The stored PRs in <state>, newest first: each number and
        directory."""
        for name in reversed(_numbered(_store_path(self.store, "prs"))):
            directory = _pr_path(self.store, name)
            if os.path.isdir(directory) and read_text(os.path.join(directory, "state")) == state:
                yield name, directory

    def _cross(self, directory: str) -> str:
        """The PR's cross_repository flag as stored; false where unset."""
        cross = read_text(os.path.join(directory, "cross_repository"))
        return "false" if cross is None else cross

    def prs_open_bodies(self) -> List[str]:
        """Every open PR, newest first, each `<number><TAB><body><TAB><flag>`,
        the stored body JSON-encoded as jq -Rs encodes it (an empty string
        where unset), the flag as prs_open answers it."""
        self._failing("adapter_prs_open_bodies")
        return ["%s\t%s\t%s" % (name, json.dumps(read_raw(os.path.join(d, "body")) or "",
                                                 ensure_ascii=False), self._cross(d))
                for name, d in self._prs("OPEN")]

    def prs_merged_closing(self, base: str, since: str) -> List[str]:
        """The merged PRs into <base> merged at or after <since>, newest
        first, each `<number><TAB><head><TAB><mergedAt><TAB><closing><TAB>
        <flag>` - the stored merged_at (the epoch where unset), the stored
        closing numbers comma-joined, the flag as prs_open answers it."""
        self._failing("adapter_prs_merged_closing")
        rows = []
        for name, d in self._prs("MERGED"):
            if read_text(os.path.join(d, "base")) != base:
                continue
            merged_at = read_text(os.path.join(d, "merged_at"))
            merged_at = EPOCH if merged_at is None else merged_at
            if merged_at < since:
                continue
            rows.append("\t".join([name, read_text(os.path.join(d, "head")) or "", merged_at,
                                   ",".join(file_lines(os.path.join(d, "closing"))),
                                   self._cross(d)]))
        return rows

    def prs_merged_bodies(self, base: str) -> str:
        """The stored body of every merged PR into <base>, newest first,
        each followed by a newline."""
        self._failing("adapter_prs_merged_bodies")
        return "".join((read_raw(os.path.join(d, "body")) or "") + "\n"
                       for _, d in self._prs("MERGED")
                       if read_text(os.path.join(d, "base")) == base)

    def pr_create(self, base: str, head: str, title: str, body_file: str,
                  draft: bool = False, labels: Sequence[str] = ()) -> int:
        """A new open PR, numbered as next_pr sets (else one past the
        highest issue or PR number held), a draft under <draft>, carrying
        each label named in the repo's casing but those pr_label_drops
        lists - as a gh whose label mutation did not land."""
        self._failing("adapter_pr_create", compound=bool(labels))
        n = self._next_number("next_pr")
        for name, value in (("state", "OPEN"), ("base", base), ("head", head), ("title", title)):
            _write(_pr_path(self.store, n, name), value + "\n")
        _write(_pr_path(self.store, n, "body"), read_raw(body_file) or "")
        if draft:
            _write(_pr_path(self.store, n, "draft"), "")
        drops = _lines(_store_path(self.store, "pr_label_drops"))
        kept: List[str] = []
        for label in labels:
            if not real.label_listed(drops, label) and not real.label_listed(kept, label):
                kept.append(self._label_canon(label))
        _write(_pr_path(self.store, n, "labels"), "".join(label + "\n" for label in kept))
        return n

    def pr_labels(self, n: int) -> List[str]:
        self._failing("adapter_pr_labels")
        self._pr_known(n)
        return _lines(_pr_path(self.store, n, "labels"))

    def _head_oid(self, n: int) -> str:
        """PR #n's head SHA, the store's one head rule: its head_oid as
        stored, empty included (GitHub's null head), forty zeros where
        absent."""
        oid = read_text(_pr_path(self.store, n, "head_oid"))
        return NO_HEAD_OID if oid is None else oid

    def pr_refs(self, n: int) -> Tuple[str, str, str]:
        """The stored head SHA (_head_oid), head and base."""
        self._failing("adapter_pr_refs")
        self._pr_known(n)
        return (self._head_oid(n),
                read_text(_pr_path(self.store, n, "head")) or "",
                read_text(_pr_path(self.store, n, "base")) or "")

    def pr_url_head(self, n: int) -> Tuple[str, str]:
        """The stored url - https://github.com/o/r/pull/<n> where none is
        stored - and the head SHA (_head_oid)."""
        self._failing("adapter_pr_url_head")
        self._pr_known(n)
        url = _pr_path(self.store, n, "url")
        stored = _first_line(url) if os.path.isfile(url) else "https://github.com/o/r/pull/%d" % n
        return stored, self._head_oid(n)

    def pr_state_draft(self, n: int) -> Tuple[str, bool]:
        self._failing("adapter_pr_state_draft")
        self._pr_known(n)
        return (read_text(_pr_path(self.store, n, "state")) or "",
                os.path.isfile(_pr_path(self.store, n, "draft")))

    def pr_ready(self, n: int) -> None:
        """The stored PR no longer a draft."""
        self._failing("adapter_pr_ready")
        self._pr_known(n)
        if os.path.lexists(_pr_path(self.store, n, "draft")):
            os.remove(_pr_path(self.store, n, "draft"))

    def pr_draft(self, n: int) -> None:
        """The stored PR a draft."""
        self._failing("adapter_pr_draft")
        self._pr_known(n)
        _write(_pr_path(self.store, n, "draft"), "")

    def pr_comment(self, n: int, body_file: str) -> None:
        self._failing("adapter_pr_comment")
        self._pr_known(n)
        self._comment_append(_pr_path(self.store, n, "comments"), read_raw(body_file) or "")

    def pr_body_edit(self, n: int, body_file: str) -> None:
        self._failing("adapter_pr_body_edit")
        self._pr_known(n)
        _write(_pr_path(self.store, n, "body"), read_raw(body_file) or "")

    def pr_title_edit(self, n: int, title: str) -> None:
        self._failing("adapter_pr_title_edit")
        self._pr_known(n)
        _write(_pr_path(self.store, n, "title"), title + "\n")

    def pr_label_add(self, n: int, label: str) -> None:
        """The label appended to the stored ones in the repo's casing,
        unless the PR carries it in any casing."""
        self._failing("adapter_pr_label_add")
        self._pr_known(n)
        labels = _lines(_pr_path(self.store, n, "labels"))
        if not real.label_listed(labels, label):
            _write(_pr_path(self.store, n, "labels"), self._label_canon(label) + "\n", "ab")

    def pr_diff(self, n: int) -> str:
        self._failing("adapter_pr_diff")
        self._pr_known(n)
        return read_raw(_pr_path(self.store, n, "diff")) or ""

    def pr_checks(self, n: int, scope: str) -> Checks:
        """The next answer of the script fake_checks seeded for the PR and
        scope - one per call, the last repeating once the script runs out -
        each read logged in checks/<n>/reads. An unscripted scope has no
        checks, gh's NO_CHECKS line saying so."""
        self._failing("adapter_pr_checks")
        directory = _store_path(self.store, "checks", n)
        _write(os.path.join(directory, "reads"), "read\n", "ab")
        script = os.path.join(directory, scope)
        if not os.path.isfile(script):
            return Checks(reported=NO_CHECKS)
        answers = file_lines(script)
        i = real.number_of(read_raw(script + ".n") or "") + 1
        _write(script + ".n", "%d\n" % i)
        answer = answers[i - 1] if i <= len(answers) else ""
        if not answer:
            answer = answers[-1] if answers else ""
        if answer == "boom":
            raise GhFailed(OFFLINE)
        if answer not in CHECKS_ANSWERS:
            raise GhFailed("gh fake: no checks answer named '%s'\n" % answer)
        return Checks(CHECKS_ANSWERS[answer], NO_CHECKS if answer == "none" else "")

    def pr_body(self, n: int) -> str:
        self._failing("adapter_pr_body")
        self._pr_known(n)
        return read_raw(_pr_path(self.store, n, "body")) or ""

    def pr_comments(self, n: int) -> List[dict]:
        self._failing("adapter_pr_comments")
        self._pr_known(n)
        return self._comments(n, _pr_path(self.store, n, "comments"))

    def pr_close(self, n: int, comment: str) -> None:
        """The stored PR CLOSED, <comment> appended by fake-gh - but closing
        one already CLOSED succeeds and appends no comment, as GitHub does.
        The bash fake's other arm, an open PR whose head branch is gone from
        origin closed with no comment, is not copied: it reads origin with
        git in the working directory, which an in-process fake has none of."""
        self._failing("adapter_pr_close", compound=True)
        self._pr_known(n)
        if read_text(_pr_path(self.store, n, "state")) == "CLOSED":
            return
        self._comment_append(_pr_path(self.store, n, "comments"), comment)
        _write(_pr_path(self.store, n, "state"), "CLOSED\n")

    # --- CI-evidence operations ---

    def _stored_lines(self, *parts: object) -> List[str]:
        """The lines of the store file at <parts>, as the bash fake's `cat`
        prints them and a capture reads them; none where it is absent."""
        return real.lines_of((read_raw(_store_path(self.store, *parts)) or "").rstrip("\n"))

    def branch_required_checks(self, branch: str) -> List[str]:
        """The contexts stored under protection/<branch>; none for an
        unprotected branch."""
        self._failing("adapter_branch_required_checks")
        return self._stored_lines("protection", branch)

    def branch_rules(self, branch: str) -> List[str]:
        """The rule types stored under rules/<branch>; none for none."""
        self._failing("adapter_branch_rules")
        return self._stored_lines("rules", branch)

    def pr_commits_checked(self, n: int) -> real.CommitsChecked:
        """The base tip's answer, then each commit's: a ref has a check run
        or a status where check_runs or statuses lists it, the base tip
        being the PR's stored base branch name. The PR's commits are its
        stored commits, else its head alone where that is not empty. Each
        read is logged in evidence_reads; the PR's evidence_raw, where
        stored, is the whole answer in the lines the real read's jq prints;
        no_base_ref leaves the base tip's answer empty."""
        self._failing("adapter_pr_commits_checked")
        self._pr_known(n)
        _write(_pr_path(self.store, n, "evidence_reads"), "read\n", "ab")
        raw = read_raw(_pr_path(self.store, n, "evidence_raw"))
        if raw is not None:
            return real.parse_commits_checked(raw)
        listed = file_lines(_store_path(self.store, "check_runs"))
        listed += file_lines(_store_path(self.store, "statuses"))

        def checked(ref: str) -> str:
            return "yes" if ref in listed else "no"

        if os.path.isfile(_pr_path(self.store, n, "no_base_ref")):
            base = ""
        else:
            base = checked(read_text(_pr_path(self.store, n, "base")) or "")
        if os.path.isfile(_pr_path(self.store, n, "commits")):
            commits = self._stored_lines("prs", n, "commits")
        else:
            commits = [self._head_oid(n)] if self._head_oid(n) else []
        return base, [(sha, checked(sha)) for sha in commits]

    # --- GitHub Actions operations ---

    def run_rerun(self, run: int) -> None:
        """The run appended to reruns."""
        self._failing("adapter_run_rerun")
        _write(_store_path(self.store, "reruns"), "%d\n" % run, "ab")

    def job_failed_log(self, job: int) -> str:
        """The log stored under job_logs/<job>; a job with none stored fails,
        as gh does for a log it cannot read."""
        self._failing("adapter_job_failed_log")
        log = read_raw(_store_path(self.store, "job_logs", job))
        if log is None:
            raise GhFailed("log not found\n")
        return log

    # --- claim operations ---

    def claim_delete(self, n: int) -> None:
        """The claim on #n removed from the store; none there is freed all
        the same."""
        self._failing("adapter_claim_delete")
        path = _store_path(self.store, "claims", n)
        if os.path.lexists(path):
            os.remove(path)


class FakeStore:
    """Seeds the store at <store> and reads it back, as the bash suite's
    fake_* helpers do, in their layout."""

    def __init__(self, store: str) -> None:
        self.store = store

    def issue(self, n: int, state: str, *labels: str) -> None:
        """Issue #n afresh, open or closed, carrying the labels named - no
        title, body or comments."""
        directory = _issue_path(self.store, n)
        shutil.rmtree(directory, ignore_errors=True)
        _write(os.path.join(directory, "state"), state.upper() + "\n")
        self.labels(n, *labels)

    def labels(self, n: int, *labels: str) -> None:
        _labels_write(self.store, n, labels)

    def title(self, n: int, title: str) -> None:
        _write(_issue_path(self.store, n,"title"), title + "\n")

    def body(self, n: int, body: str) -> None:
        _write(_issue_path(self.store, n,"body"), body)

    def comment(self, n: int, author: str, created: str, body: str, association: str = "") -> None:
        """A comment after any issue #n has; its association OWNER unless
        given."""
        _comment_write(_issue_path(self.store, n,"comments"), author, created,
                       association or "OWNER", body)

    def authorship(
        self, n: int, author: str, association: str, editor: str = "", renamer: str = ""
    ) -> None:
        """Issue #n's author and association, the body's last editor and the
        title's latest renamer, as fake_issue_authorship seeds them."""
        for name, value in (("author", author), ("association", association),
                            ("editor", editor), ("renamer", renamer)):
            _write(_issue_path(self.store, n,name), value + "\n")

    def sub_issue(self, parent: int, child: int) -> None:
        """Issue #child a sub-issue of #parent."""
        _write(_store_path(self.store, "subs", parent), "%d\n" % child, "ab")

    def blocked_by(self, n: int, *blockers: int) -> None:
        """Issue #n blocked by the issues named, in that order; none named, an
        empty blocked-by list."""
        _write(_store_path(self.store, "blocked_by", n), "".join("%d\n" % b for b in blockers))

    def no_dependency_summary(self, n: int) -> None:
        """GitHub leaves #n's dependency summary off, so only its blocked-by
        listing answers."""
        _write(_store_path(self.store, "no_dependency_summary"), "%d\n" % n, "ab")

    def pr(self, n: int, state: str, head: str, base: str) -> None:
        """PR #n afresh, open, closed or merged, from <head> into <base> - no
        body or comments, same-repo."""
        directory = _pr_path(self.store, n)
        shutil.rmtree(directory, ignore_errors=True)
        _write(os.path.join(directory, "state"), state.upper() + "\n")
        _write(os.path.join(directory, "head"), head + "\n")
        _write(os.path.join(directory, "base"), base + "\n")

    def pr_body(self, n: int, body: str) -> None:
        _write(_pr_path(self.store, n, "body"), body)

    def pr_draft(self, n: int) -> None:
        """PR #n a draft."""
        _write(_pr_path(self.store, n, "draft"), "")

    def pr_labels(self, n: int, *labels: str) -> None:
        """PR #n's labels: exactly <labels>, one a line, in order."""
        _write(_pr_path(self.store, n, "labels"), "".join(label + "\n" for label in labels))

    def pr_head(self, n: int, oid: str, *commits: str) -> None:
        """PR #n's head SHA and its commits, oldest first, as fake_pr_head
        seeds them - given none, the head alone, or none when the head is
        empty."""
        _write(_pr_path(self.store, n, "head_oid"), oid + "\n")
        path = _pr_path(self.store, n, "commits")
        if os.path.lexists(path):
            os.remove(path)
        if commits:
            _write(path, "".join(sha + "\n" for sha in commits))

    def pr_url(self, n: int, url: str) -> None:
        """PR #n's canonical URL, the one pr_url_head answers."""
        _write(_pr_path(self.store, n, "url"), url + "\n")

    def required_checks(self, branch: str, *contexts: str) -> None:
        """Classic branch protection on <branch>, requiring the checks
        named."""
        _write(_store_path(self.store, "protection", branch),
               "".join(context + "\n" for context in contexts))

    def rules(self, branch: str, *types: str) -> None:
        """The rules the repo's rulesets apply to <branch>, by type."""
        _write(_store_path(self.store, "rules", branch), "".join(t + "\n" for t in types))

    def check_run(self, ref: str) -> None:
        """<ref> - a SHA, or a branch name for its tip - has a check run."""
        _write(_store_path(self.store, "check_runs"), ref + "\n", "ab")

    def status(self, ref: str) -> None:
        """<ref> - a SHA, or a branch name for its tip - has a commit
        status."""
        _write(_store_path(self.store, "statuses"), ref + "\n", "ab")

    def no_base_ref(self, n: int) -> None:
        """PR #n's evidence read has no answer for the base tip."""
        _write(_pr_path(self.store, n, "no_base_ref"), "")

    def evidence_raw(self, n: int, *lines: str) -> None:
        """PR #n's evidence read answers <lines>, as its jq prints them, in
        place of the answer the store would build."""
        _write(_pr_path(self.store, n, "evidence_raw"), "".join(line + "\n" for line in lines))

    def evidence_reads(self, n: int) -> int:
        """How many times PR #n's evidence read was made."""
        return len(file_lines(_pr_path(self.store, n, "evidence_reads")))

    def job_log(self, job: int, log: str) -> None:
        """Actions job <job>'s failed-step log, byte for byte."""
        _write(_store_path(self.store, "job_logs", job), log)

    def reruns(self) -> List[str]:
        """The Actions run ids rerun, in order."""
        return file_lines(_store_path(self.store, "reruns"))

    def pr_diff(self, n: int, diff: str) -> None:
        _write(_pr_path(self.store, n, "diff"), diff)

    def pr_merged(self, n: int, merged_at: str, *closing: int) -> None:
        """PR #n merged at the UTC timestamp <merged_at>, its
        closingIssuesReferences the issues given, as fake_pr_merged seeds
        them."""
        _write(_pr_path(self.store, n, "merged_at"), merged_at + "\n")
        _write(_pr_path(self.store, n, "closing"), "".join("%d\n" % i for i in closing))

    def issue_created(self, n: int, created_at: str) -> None:
        """Issue #n created at the UTC timestamp <created_at>."""
        _write(_issue_path(self.store, n, "created_at"), created_at + "\n")

    def checks(self, n: int, scope: str, *answers: str) -> None:
        """PR #n's checks for <scope>, required or all, scripted as
        fake_checks scripts them: one answer a call, the last repeating."""
        script = _store_path(self.store, "checks", n, scope)
        _write(script, "".join(answer + "\n" for answer in answers))
        if os.path.lexists(script + ".n"):
            os.remove(script + ".n")

    def next_pr(self, n: int) -> None:
        _write(_store_path(self.store, "next_pr"), "%d\n" % n)

    def pr_comment(self, n: int, author: str, created: str, body: str,
                   association: str = "") -> None:
        """A comment after any PR #n has; its association OWNER unless
        given."""
        _comment_write(_pr_path(self.store, n, "comments"), author, created,
                       association or "OWNER", body)

    def pr_cross(self, n: int, flag: str = "true") -> None:
        """PR #n's cross-repository flag, a fork PR's by default, stored as
        given."""
        _write(_pr_path(self.store, n, "cross_repository"), flag + "\n")

    def default_branch(self, answer: str) -> None:
        """The repo's default branch as GitHub answers it, byte for byte, as
        fake_default_branch seeds it."""
        _write(_store_path(self.store, "default_branch"), answer)

    def next_issue(self, n: int) -> None:
        _write(_store_path(self.store, "next_issue"), "%d\n" % n)

    def claim(self, n: int) -> None:
        """A claim on issue #n, held by this host with pid 1, a start long
        past and the spec phase, as fake_claim_seed seeds it."""
        _write(_store_path(self.store, "claims", n),
               "%d\t%s\t1\tspec\t2026-01-01T00:00:00Z\n" % (n, socket.gethostname()))

    def claim_held(self, n: int) -> bool:
        """Whether the store holds a claim on issue #n, as fake_claim_held
        reads it."""
        return os.path.isfile(_store_path(self.store, "claims", n))

    def fail(self, operation: str, stderr: Optional[str] = None) -> None:
        """Every later call of the operation fails with <stderr>, default
        "fake gh: <operation> failed"; an empty one prints nothing."""
        text = "fake gh: %s failed" % operation if stderr is None else stderr
        _write(_store_path(self.store, "fail", operation), text + "\n" if text else "")

    def fail_times(self, operation: str, times: int, stderr: str = "") -> None:
        """The next <times> calls of the operation fail, then it succeeds."""
        _write(_store_path(self.store, "fail", operation), stderr)
        _write(_store_path(self.store, "fail", operation + ".times"), "%d\n" % times)

    def fail_after(self, operation: str, after: int, stderr: Optional[str] = None) -> None:
        """fail, but only once <after> calls of the operation have answered."""
        self.fail(operation, stderr)
        _write(_store_path(self.store, "fail", operation + ".after"), "%d\n" % after)

    def fail_times_after(self, operation: str, after: int, times: int, stderr: str = "") -> None:
        """fail_times, but only once <after> calls of the operation have
        answered."""
        self.fail_times(operation, times, stderr)
        _write(_store_path(self.store, "fail", operation + ".after"), "%d\n" % after)

    def lag(self, operation: str, times: int, stale: Optional[str] = None) -> None:
        """The next <times> reads of the operation answer <stale>, in the
        shape gh prints it - nothing where none is given - then current."""
        _write(_store_path(self.store, "lag", operation), "%d\n" % times)
        if stale is not None:
            _write(_store_path(self.store, "lag", operation + ".stale"), stale + "\n")

    def lag_after(
        self, operation: str, after: int, times: int, stale: Optional[str] = None
    ) -> None:
        """lag, but only once <after> reads of the operation have answered
        current."""
        self.lag(operation, times, stale)
        _write(_store_path(self.store, "lag", operation + ".after"), "%d\n" % after)

    def unfail(self) -> None:
        shutil.rmtree(_store_path(self.store, "fail"), ignore_errors=True)

    def ratelimit(self, stderr: str = "API rate limit exceeded for user ID 1.") -> None:
        """Every operation but the quota read fails with <stderr>, bash
        fake_ratelimit."""
        _write(_store_path(self.store, "ratelimit"), stderr + "\n")

    def quota(self, pool: str, remaining: int, limit: int, reset: int) -> None:
        """The quota read answers one more pool line, bash fake_quota."""
        _write(_store_path(self.store, "quota"),
               "%s\t%d\t%d\t%d\n" % (pool, remaining, limit, reset), "ab")

    def offline(self) -> None:
        _write(_store_path(self.store, "offline"), "")

    def online(self) -> None:
        for name in ("offline", "noauth", "ratelimit"):
            if os.path.exists(_store_path(self.store, name)):
                os.remove(_store_path(self.store, name))
