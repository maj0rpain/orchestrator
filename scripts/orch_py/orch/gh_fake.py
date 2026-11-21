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

import os
import shutil
import time
from typing import Callable, List, Mapping, Optional, Sequence, Tuple

from orch import gh as real
from orch.common import plain_number
from orch.gh import GhFailed, IssueRow, LabelledBody, Limits

# The author and timestamp of every comment the fake's own operations write.
COMMENT_AUTHOR = "fake-gh"
COMMENT_CREATED = "2026-01-01T00:00:00Z"
OFFLINE = "dial tcp: lookup api.github.com: no such host\n"
NOAUTH = "HTTP 401: Bad credentials (https://api.github.com/graphql)\n"


def _read(path: str) -> Optional[str]:
    """The file's contents byte for byte, or None where it is unreadable."""
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "surrogateescape")
    except OSError:
        return None


def _write(path: str, text: str, mode: str = "wb") -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode) as f:
        f.write(text.encode("utf-8", "surrogateescape"))


def _slurp(path: str) -> Optional[str]:
    """The file's contents less trailing newlines, as "$(cat)" reads it; None
    where it is unreadable."""
    text = _read(path)
    return None if text is None else text.rstrip("\n")


def _first_line(path: str) -> str:
    """The file's first line; "" where it is missing or empty."""
    lines = real.lines_of(_read(path) or "")
    return lines[0] if lines else ""


def _lines(path: str) -> List[str]:
    """The file's non-empty lines; none where it is unreadable."""
    return [line for line in real.lines_of(_read(path) or "") if line]


def _countdown(path: str) -> bool:
    """True while the count the file holds is above zero, counting it down
    by one; False where it is absent or at zero."""
    text = _read(path)
    if text is None:
        return False
    count = real.number_of(text)
    if count <= 0:
        return False
    _write(path, "%d\n" % (count - 1))
    return True


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
    pin() as the real adapter's does, else the repo is taken as resolved."""

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
        self.limits = Limits(env, self._rate_limit, sleep, now)

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
            limited = _read(_store_path(self.store, "ratelimit"))
            if limited is not None:
                return limited
        if os.path.isfile(_store_path(self.store, "offline")):
            return OFFLINE
        if os.path.isfile(_store_path(self.store, "noauth")):
            return NOAUTH
        fail = _store_path(self.store, "fail", operation)
        stderr = _read(fail)
        if stderr is None or _countdown(fail + ".after"):
            return None
        times = _read(fail + ".times")
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
        return _read(lag + ".stale") or ""

    def _rate_limit(self) -> str:
        self._fail_raw("adapter_rate_limit")
        quota = _read(_store_path(self.store, "quota"))
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

    def _comments(self, n: int) -> List[dict]:
        directory = _issue_path(self.store, n, "comments")
        comments = []
        for k in _numbered(directory):
            comment = os.path.join(directory, k)
            comments.append({
                "author": {"login": _slurp(os.path.join(comment, "author")) or ""},
                "authorAssociation": _slurp(os.path.join(comment, "association")) or "OWNER",
                "createdAt": _slurp(os.path.join(comment, "created")) or "",
                "body": _read(os.path.join(comment, "body")) or "",
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

    def _next_number(self) -> int:
        """The number a new issue takes - next_issue's, or one past the
        highest issue or PR number the store holds - the counter advanced."""
        counter = _store_path(self.store, "next_issue")
        seeded = _slurp(counter)
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
        return _read(_issue_path(self.store, n, "body")) or ""

    def issue_json(self, n: int) -> dict:
        self._failing("adapter_issue_json")
        self._known(n)
        return {
            "number": n,
            "title": _slurp(_issue_path(self.store, n, "title")) or "",
            "body": _read(_issue_path(self.store, n, "body")) or "",
            "labels": self._labels(n),
        }

    def issue_comments(self, n: int) -> List[dict]:
        _write(_store_path(self.store, "comment_reads"), "x\n", "ab")
        self._failing("adapter_issue_comments")
        stale = self._lagging("adapter_issue_comments")
        if stale is not None:
            return real.parse_comments(stale)
        self._known(n)
        return self._comments(n)

    def issue_authorship(self, n: int) -> Tuple[str, str, str, str]:
        """The stored authorship; absent, fake-gh as OWNER, the body never
        edited nor the title renamed."""
        self._failing("adapter_issue_authorship")
        self._known(n)

        def stored(name: str, absent: str) -> str:
            value = _slurp(_issue_path(self.store, n, name))
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
        return _slurp(_issue_path(self.store, n, "state")) or ""

    def issue_state_labels(self, n: int) -> Tuple[str, List[str]]:
        self._failing("adapter_issue_state_labels")
        stale = self._lagging("adapter_issue_state_labels")
        if stale is not None:
            return real.first_and_rest(stale)
        self._known(n)
        return _slurp(_issue_path(self.store, n, "state")) or "", self._labels(n)

    def issue_state_labels_body(self, n: int) -> Tuple[str, List[str], str]:
        self._failing("adapter_issue_state_labels_body")
        self._known(n)
        body = (_read(_issue_path(self.store, n, "body")) or "").rstrip("\n")
        return _first_line(_issue_path(self.store, n, "state")), self._labels(n), body

    def issue_title_labels(self, n: int) -> Tuple[str, List[str]]:
        self._failing("adapter_issue_title_labels")
        stale = self._lagging("adapter_issue_title_labels")
        if stale is not None:
            return real.first_and_rest(stale)
        self._known(n)
        return _slurp(_issue_path(self.store, n, "title")) or "", self._labels(n)

    def issues_titled_rows(self, label: str) -> List[IssueRow]:
        self._failing("adapter_issues_titled_rows")
        stale = self._lagging("adapter_issues_titled_rows")
        if stale is not None:
            rows = real.parse_titled_rows(stale)
        else:
            rows = [
                IssueRow(n, _first_line(_issue_path(self.store, n, "state")),
                         _slurp(_issue_path(self.store, n, "title")) or "", self._labels(n))
                for n in self._labelled_open(label)
            ]
        real.labelled_limit_warn(self.env, len(rows), label)
        return rows

    def issues_labelled_bodies(self, *labels: str) -> List[LabelledBody]:
        self._failing("adapter_issues_labelled_bodies")
        rows = [
            LabelledBody(n, self._labels(n),
                         (_read(_issue_path(self.store, n, "body")) or "").rstrip("\n"))
            for n in self._labelled_open(*labels)
        ]
        real.labelled_limit_warn(self.env, len(rows), *labels)
        return rows

    def issue_create(self, title: str, body_file: str, labels: Sequence[str]) -> int:
        self._failing("adapter_issue_create")
        n = self._next_number()
        _write(_issue_path(self.store, n, "state"), "OPEN\n")
        _write(_issue_path(self.store, n, "title"), title + "\n")
        _write(_issue_path(self.store, n, "body"), _read(body_file) or "")
        kept: List[str] = []
        for label in labels:
            if not real.label_listed(kept, label):
                kept.append(self._label_canon(label))
        _labels_write(self.store, n, kept)
        return n

    def issue_body_edit(self, n: int, body_file: str) -> None:
        self._failing("adapter_issue_body_edit")
        self._known(n)
        _write(_issue_path(self.store, n, "body"), _read(body_file) or "")

    def issue_comment(self, n: int, body_file: str) -> None:
        self._failing("adapter_issue_comment")
        self._known(n)
        self._comment_append(_issue_path(self.store, n, "comments"), _read(body_file) or "")

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
        if _slurp(_issue_path(self.store, n, "state")) == "CLOSED":
            return
        if comment:
            self._comment_append(_issue_path(self.store, n, "comments"), comment)
        _write(_issue_path(self.store, n, "state"), "CLOSED\n")
        if duplicate_of is not None:
            _write(_issue_path(self.store, n, "reason"), "duplicate\n")
            _write(_issue_path(self.store, n, "duplicate_of"), "%d\n" % duplicate_of)
        else:
            _write(_issue_path(self.store, n, "reason"), (reason or "completed") + "\n")

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

    # --- repo operations ---

    def repo_default_branch(self, repo: str) -> str:
        """The stored default_branch answer less its trailing newlines; a
        store with none fails it, as gh does for a repo it cannot resolve."""
        self._failing("adapter_repo_default_branch")
        answer = _slurp(_store_path(self.store, "default_branch"))
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
            if str(n) in real.lines_of(_read(os.path.join(subs, parent)) or ""):
                return int(parent)
        return None

    def _blockers(self, n: int) -> List[int]:
        return [int(line) for line in _lines(_store_path(self.store, "blocked_by", n))
                if plain_number(line)]

    def issue_open_blockers(self, n: int) -> Optional[int]:
        self._failing("adapter_issue_open_blockers")
        self._known(n)
        if str(n) in real.lines_of(_read(_store_path(self.store, "no_dependency_summary")) or ""):
            return None
        return sum(1 for b in self._blockers(n)
                   if _first_line(_issue_path(self.store, b, "state")) == "OPEN")

    def blockers_states(self, n: int) -> List[Tuple[int, str]]:
        self._failing("adapter_blockers_states")
        self._known(n)
        return [(b, _first_line(_issue_path(self.store, b, "state"))) for b in self._blockers(n)]


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

    def default_branch(self, answer: str) -> None:
        """The repo's default branch as GitHub answers it, byte for byte, as
        fake_default_branch seeds it."""
        _write(_store_path(self.store, "default_branch"), answer)

    def next_issue(self, n: int) -> None:
        _write(_store_path(self.store, "next_issue"), "%d\n" % n)

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

    def offline(self) -> None:
        _write(_store_path(self.store, "offline"), "")

    def online(self) -> None:
        for name in ("offline", "noauth", "ratelimit"):
            if os.path.exists(_store_path(self.store, name)):
                os.remove(_store_path(self.store, name))
