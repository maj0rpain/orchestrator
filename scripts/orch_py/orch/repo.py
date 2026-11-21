"""The repo pin (#520): the repo every gh call is pinned to, as the bash
side's repo.sh resolves it.

GH_REPO when the caller set it, else the [HOST/]OWNER/REPO parsed from the
checkout's origin remote - never gh's own default repo, which in a fork is the
upstream. The pin hands gh GH_REPO (when the caller left it unset) and, by the
one host rule, GH_HOST whenever the repo itself decides its host: the repo
name's explicit host, or github.com for a repo resolved from origin. A
user-set OWNER/REPO GH_REPO keeps the user's own GH_HOST, set or unset.
"""
from __future__ import annotations

import subprocess
from typing import Callable, Dict, Mapping, NamedTuple, Optional

REPO_MISSING = "no GitHub repo to work on"
REPO_CAUSE = REPO_MISSING + ": origin is missing or not a GitHub owner/name"
REPO_REMEDY = REPO_CAUSE + " - set GH_REPO=<owner>/<repo>"


class Repo(NamedTuple):
    """A resolved repo: its [HOST/]OWNER/REPO name, where it came from
    (GH_REPO or origin), and the host it pins, empty for none."""

    name: str
    source: str
    host: str


def ssh_host(host: str) -> str:
    """The hostname `ssh -G` resolves <host> to, or <host> as written when ssh
    is missing, fails or prints no hostname line."""
    try:
        run = subprocess.run(
            ["ssh", "-G", "--", host],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return host
    if run.returncode != 0:
        return host
    for line in run.stdout.decode("utf-8", "replace").split("\n"):
        if line.startswith("hostname "):
            return line[len("hostname "):] or host
    return host


def url_form(url: str) -> str:
    """"ssh" for the two SSH forms (ssh://... and git's scp-like
    [user@]host:path), "plain" for https://, http:// and git://, "" for any
    other string."""
    if url.startswith("ssh://"):
        return "ssh"
    if url.startswith(("https://", "http://", "git://")):
        return "plain"
    if "://" in url:
        return ""
    if ":" in url and "/" not in url.split(":", 1)[0]:
        return "ssh"
    return ""


def repo_host(name: str) -> str:
    """The explicit host of a [HOST/]OWNER/REPO name; "" for OWNER/REPO."""
    return name.split("/", 1)[0] if name.count("/") >= 2 else ""


def repo_from_url(url: str, lookup: Callable[[str], str] = ssh_host) -> Optional[str]:
    """[HOST/]OWNER/REPO from a clone URL in any of its forms, with or without
    .git; None for a URL with no host, a host starting with "-", or a path
    that is not exactly owner/name. An SSH form's host is first translated
    through <lookup> (`ssh -G`); every host is then lowercased, *.github.com
    becomes github.com, and github.com is left implicit."""
    form = url_form(url)
    if not form:
        return None
    if "://" in url:
        rest = url.split("://", 1)[1]
        if "/" not in rest:
            return None
        host, path = rest.split("/", 1)
        host = host.rsplit("@", 1)[-1].split(":", 1)[0]
    else:
        host, path = url.split(":", 1)
        host = host.rsplit("@", 1)[-1]
    if path.endswith("/"):
        path = path[:-1]
    if path.endswith(".git"):
        path = path[: -len(".git")]
    if path.count("/") != 1 or path.startswith("/") or path.endswith("/"):
        return None
    if not host or host.startswith("-"):
        return None
    if form == "ssh":
        host = lookup(host)
    host = host.lower()
    if host.endswith(".github.com"):
        host = "github.com"
    return path if host == "github.com" else "%s/%s" % (host, path)


class RepoPin:
    """Resolves the repo once and memoises the answer, a failed resolution
    too. <git> is the git adapter the origin is read through; <ssh_lookup>
    translates an SSH form's host."""

    def __init__(
        self,
        env: Mapping[str, str],
        git,
        ssh_lookup: Callable[[str], str] = ssh_host,
    ) -> None:
        self.env = env
        self.git = git
        self.ssh_lookup = ssh_lookup
        self._resolved = False
        self._repo: Optional[Repo] = None

    def resolve(self) -> Optional[Repo]:
        if not self._resolved:
            self._repo = self._resolve()
            self._resolved = True
        return self._repo

    def _resolve(self) -> Optional[Repo]:
        preset = self.env.get("GH_REPO", "")
        if preset:
            return Repo(preset, "GH_REPO", repo_host(preset))
        url = self.git.origin_url()
        if url is None:
            return None
        name = repo_from_url(url, self.ssh_lookup)
        if name is None:
            return None
        return Repo(name, "origin", repo_host(name) or "github.com")

    def gh_env(self) -> Optional[Dict[str, str]]:
        """The environment a pinned gh call runs with: the pin's own, with
        GH_REPO set when it was unset and GH_HOST set to the host the repo
        pins, if any; None when no repo resolves."""
        repo = self.resolve()
        if repo is None:
            return None
        env = dict(self.env)
        if not env.get("GH_REPO"):
            env["GH_REPO"] = repo.name
        if repo.host:
            env["GH_HOST"] = repo.host
        return env
