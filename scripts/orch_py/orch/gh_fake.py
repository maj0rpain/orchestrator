"""The gh adapter's in-process fake, on the file store the bash fake keeps.

FakeGh offers the real adapter's operations (orch.gh.Gh) on the directory
ORCH_GH_FAKE_STORE names, in the layout scripts/test/gh_adapter_fake.sh
documents, so what a bash orch.sh process wrote is there for a Python one and
the other way round. orch.gh.adapter() picks it whenever ORCH_GH_FAKE_STORE
is set.

Each operation honours the store's failure files under the bash adapter's
operation name - adapter_<the method's name> - read before the operation
touches the store: fail/<operation>, with its fail/<operation>.after and
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
from orch.gh import GhFailed, IssueRow, Limits

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
    return sorted(names, key=lambda name: int(name) if name.isdigit() else 0)


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

    def _path(self, *parts: object) -> str:
        return os.path.join(self.store, *(str(part) for part in parts))

    def _issue(self, n: int, *parts: str) -> str:
        return self._path("issues", n, *parts)

    def _known(self, n: int) -> None:
        """Fails as `gh issue view` does where the store holds no issue #n."""
        if not os.path.isdir(self._issue(n)):
            raise GhFailed(
                "GraphQL: Could not resolve to an issue or pull request with the"
                " number of %d. (repository.issue)\n" % n
            )

    def _seeded_failure(self, operation: str) -> Optional[str]:
        """The stderr of the failure the store seeds for <operation>, a
        countdown counted; None where none fails it."""
        if operation != "adapter_rate_limit":
            limited = _read(self._path("ratelimit"))
            if limited is not None:
                return limited
        if os.path.isfile(self._path("offline")):
            return OFFLINE
        if os.path.isfile(self._path("noauth")):
            return NOAUTH
        fail = self._path("fail", operation)
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
        lag = self._path("lag", operation)
        if not os.path.isfile(lag) or _countdown(lag + ".after"):
            return None
        if not _countdown(lag):
            return None
        return _read(lag + ".stale") or ""

    def _rate_limit(self) -> str:
        self._fail_raw("adapter_rate_limit")
        quota = _read(self._path("quota"))
        if quota is not None:
            return quota
        reset = int(self.now()) + 3600
        return "core\t5000\t5000\t%d\ngraphql\t5000\t5000\t%d\n" % (reset, reset)

    def _labels(self, n: int) -> List[str]:
        return _lines(self._issue(n, "labels"))

    def _label_canon(self, name: str) -> str:
        """GitHub's casing rule: the name as the repo's labels hold it in any
        casing, else as given."""
        for line in _lines(self._path("labels")):
            known = line.split("\t", 1)[0]
            if known.lower() == name.lower():
                return known
        return name

    def _labels_write(self, n: int, labels: Sequence[str]) -> None:
        _write(self._issue(n, "labels"), "".join(label + "\n" for label in labels))

    def _comment_append(self, directory: str, body: str) -> None:
        k = len(_numbered(directory)) + 1
        _write(os.path.join(directory, str(k), "author"), COMMENT_AUTHOR + "\n")
        _write(os.path.join(directory, str(k), "created"), COMMENT_CREATED + "\n")
        _write(os.path.join(directory, str(k), "association"), "OWNER\n")
        _write(os.path.join(directory, str(k), "body"), body)

    def _comments(self, n: int) -> List[dict]:
        directory = self._issue(n, "comments")
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
        for name in _numbered(self._path("issues")):
            if not name.isdigit() or os.path.exists(self._issue(int(name), "pull")):
                continue
            if _first_line(self._issue(int(name), "state")) == "OPEN":
                numbers.append(int(name))
        return numbers

    def _next_number(self) -> int:
        """The number a new issue takes - next_issue's, or one past the
        highest issue or PR number the store holds - the counter advanced."""
        counter = self._path("next_issue")
        seeded = _slurp(counter)
        if seeded:
            n = real.number_of(seeded)
        else:
            held = [int(name) for kind in ("issues", "prs")
                    for name in _numbered(self._path(kind)) if name.isdigit()]
            n = max(held, default=0) + 1
        _write(counter, "%d\n" % (n + 1))
        return n

    # --- issue operations ---

    def issue_body(self, n: int) -> str:
        self._failing("adapter_issue_body")
        self._known(n)
        return _read(self._issue(n, "body")) or ""

    def issue_json(self, n: int) -> dict:
        self._failing("adapter_issue_json")
        self._known(n)
        return {
            "number": n,
            "title": _slurp(self._issue(n, "title")) or "",
            "body": _read(self._issue(n, "body")) or "",
            "labels": self._labels(n),
        }

    def issue_comments(self, n: int) -> List[dict]:
        _write(self._path("comment_reads"), "x\n", "ab")
        self._failing("adapter_issue_comments")
        stale = self._lagging("adapter_issue_comments")
        if stale is not None:
            return real.parse_comments(stale)
        self._known(n)
        return self._comments(n)

    def issue_state_labels(self, n: int) -> Tuple[str, List[str]]:
        self._failing("adapter_issue_state_labels")
        stale = self._lagging("adapter_issue_state_labels")
        if stale is not None:
            return real.first_and_rest(stale)
        self._known(n)
        return _slurp(self._issue(n, "state")) or "", self._labels(n)

    def issue_state_labels_body(self, n: int) -> Tuple[str, List[str], str]:
        self._failing("adapter_issue_state_labels_body")
        self._known(n)
        body = (_read(self._issue(n, "body")) or "").rstrip("\n")
        return _first_line(self._issue(n, "state")), self._labels(n), body

    def issue_title_labels(self, n: int) -> Tuple[str, List[str]]:
        self._failing("adapter_issue_title_labels")
        stale = self._lagging("adapter_issue_title_labels")
        if stale is not None:
            return real.first_and_rest(stale)
        self._known(n)
        return _slurp(self._issue(n, "title")) or "", self._labels(n)

    def issues_titled_rows(self, label: str) -> List[IssueRow]:
        self._failing("adapter_issues_titled_rows")
        stale = self._lagging("adapter_issues_titled_rows")
        if stale is not None:
            rows = real.parse_titled_rows(stale)
        else:
            limit = min(real.issue_list_limit(self.env), real.ISSUE_SEARCH_CAP)
            labelled = [n for n in self._open_numbers()
                        if label.lower() in (have.lower() for have in self._labels(n))]
            rows = [
                IssueRow(n, _first_line(self._issue(n, "state")),
                         _slurp(self._issue(n, "title")) or "", self._labels(n))
                for n in labelled[:limit]
            ]
        real.labelled_limit_warn(self.env, len(rows), label)
        return rows

    def issue_create(self, title: str, body_file: str, labels: Sequence[str]) -> int:
        self._failing("adapter_issue_create")
        n = self._next_number()
        _write(self._issue(n, "state"), "OPEN\n")
        _write(self._issue(n, "title"), title + "\n")
        _write(self._issue(n, "body"), _read(body_file) or "")
        kept: List[str] = []
        for label in labels:
            if label.lower() not in (have.lower() for have in kept):
                kept.append(self._label_canon(label))
        self._labels_write(n, kept)
        return n

    def issue_body_edit(self, n: int, body_file: str) -> None:
        self._failing("adapter_issue_body_edit")
        self._known(n)
        _write(self._issue(n, "body"), _read(body_file) or "")

    def issue_comment(self, n: int, body_file: str) -> None:
        self._failing("adapter_issue_comment")
        self._known(n)
        self._comment_append(self._issue(n, "comments"), _read(body_file) or "")

    def issue_relabel(
        self, n: int, add: Sequence[str] = (), remove: Sequence[str] = ()
    ) -> None:
        # With nothing named, the real one makes no gh call, so nothing fails.
        if not add and not remove:
            return
        self._failing("adapter_issue_relabel")
        self._known(n)
        dropped = {label.lower() for label in remove}
        labels = [have for have in self._labels(n) if have.lower() not in dropped]
        for label in add:
            if label.lower() not in (have.lower() for have in labels):
                labels.append(self._label_canon(label))
        self._labels_write(n, labels)

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
        if _slurp(self._issue(n, "state")) == "CLOSED":
            return
        if comment:
            self._comment_append(self._issue(n, "comments"), comment)
        _write(self._issue(n, "state"), "CLOSED\n")
        if duplicate_of is not None:
            _write(self._issue(n, "reason"), "duplicate\n")
            _write(self._issue(n, "duplicate_of"), "%d\n" % duplicate_of)
        else:
            _write(self._issue(n, "reason"), (reason or "completed") + "\n")

    # --- sub-issue and dependency operations ---

    def issue_parent(self, n: int) -> Optional[int]:
        self._failing("adapter_issue_parent")
        self._known(n)
        subs = self._path("subs")
        for parent in sorted(os.listdir(subs)) if os.path.isdir(subs) else []:
            if str(n) in real.lines_of(_read(os.path.join(subs, parent)) or ""):
                return int(parent)
        return None

    def _blockers(self, n: int) -> List[int]:
        return [int(line) for line in _lines(self._path("blocked_by", n)) if line.isdigit()]

    def issue_open_blockers(self, n: int) -> Optional[int]:
        self._failing("adapter_issue_open_blockers")
        self._known(n)
        if str(n) in real.lines_of(_read(self._path("no_dependency_summary")) or ""):
            return None
        return sum(1 for b in self._blockers(n)
                   if _first_line(self._issue(b, "state")) == "OPEN")

    def blockers_states(self, n: int) -> List[Tuple[int, str]]:
        self._failing("adapter_blockers_states")
        self._known(n)
        return [(b, _first_line(self._issue(b, "state"))) for b in self._blockers(n)]


class FakeStore:
    """Seeds the store at <store> and reads it back, as the bash suite's
    fake_* helpers do, in their layout."""

    def __init__(self, store: str) -> None:
        self.store = store

    def _path(self, *parts: object) -> str:
        return os.path.join(self.store, *(str(part) for part in parts))

    def issue(self, n: int, state: str, *labels: str) -> None:
        """Issue #n afresh, open or closed, carrying the labels named - no
        title, body or comments."""
        directory = self._path("issues", n)
        shutil.rmtree(directory, ignore_errors=True)
        _write(os.path.join(directory, "state"), state.upper() + "\n")
        self.labels(n, *labels)

    def labels(self, n: int, *labels: str) -> None:
        _write(self._path("issues", n, "labels"), "".join(label + "\n" for label in labels))

    def title(self, n: int, title: str) -> None:
        _write(self._path("issues", n, "title"), title + "\n")

    def body(self, n: int, body: str) -> None:
        _write(self._path("issues", n, "body"), body)

    def comment(self, n: int, author: str, created: str, body: str, association: str = "") -> None:
        """A comment after any issue #n has; its association OWNER unless
        given."""
        directory = self._path("issues", n, "comments")
        k = len(_numbered(directory)) + 1
        _write(os.path.join(directory, str(k), "author"), author + "\n")
        _write(os.path.join(directory, str(k), "created"), created + "\n")
        _write(os.path.join(directory, str(k), "association"), (association or "OWNER") + "\n")
        _write(os.path.join(directory, str(k), "body"), body)

    def next_issue(self, n: int) -> None:
        _write(self._path("next_issue"), "%d\n" % n)

    def fail(self, operation: str, stderr: Optional[str] = None) -> None:
        """Every later call of the operation fails with <stderr>, default
        "fake gh: <operation> failed"; an empty one prints nothing."""
        text = "fake gh: %s failed" % operation if stderr is None else stderr
        _write(self._path("fail", operation), text + "\n" if text else "")

    def fail_times(self, operation: str, times: int, stderr: str = "") -> None:
        """The next <times> calls of the operation fail, then it succeeds."""
        _write(self._path("fail", operation), stderr)
        _write(self._path("fail", operation + ".times"), "%d\n" % times)

    def unfail(self) -> None:
        shutil.rmtree(self._path("fail"), ignore_errors=True)

    def offline(self) -> None:
        _write(self._path("offline"), "")

    def online(self) -> None:
        for name in ("offline", "noauth", "ratelimit"):
            if os.path.exists(self._path(name)):
                os.remove(self._path(name))
