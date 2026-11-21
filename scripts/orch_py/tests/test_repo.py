"""The repo pin's reading of an origin URL, and the ssh lookup an SSH form's
host goes through."""
from __future__ import annotations

import stat

import pytest

from orch.git import FakeGit
from orch.repo import RepoPin, repo_from_url, ssh_host


def identity(host):
    return host


@pytest.mark.parametrize("url, name", [
    ("https://github.com/fork/widgets.git", "fork/widgets"),
    ("https://github.com/fork/widgets/", "fork/widgets"),
    ("http://GitHub.com/fork/widgets", "fork/widgets"),
    ("git://github.com/fork/widgets.git", "fork/widgets"),
    ("https://user@ghe.example.com/fork/widgets.git", "ghe.example.com/fork/widgets"),
    ("git@github.com:fork/widgets.git", "fork/widgets"),
    ("github.com:fork/widgets", "fork/widgets"),
    ("ssh://git@ssh.github.com:443/fork/widgets.git", "fork/widgets"),
    ("git@GHE.Example.com:fork/widgets.git", "ghe.example.com/fork/widgets"),
    ("/srv/git/widgets.git", None),
    ("file:///srv/git/fork/widgets.git", None),
    ("https://github.com/fork", None),
    ("https://github.com/a/fork/widgets", None),
    ("https://github.com", None),
    ("-oProxyCommand=x:fork/widgets", None),
    ("git@:fork/widgets", None),
    ("./fork:widgets", None),
])
def test_an_origin_url_reads_as_its_repo_name(url, name):
    assert repo_from_url(url, identity) == name


def test_an_ssh_form_s_host_is_translated_and_a_plain_one_is_not():
    asked = []

    def alias(host):
        asked.append(host)
        return "ghe.example.com"

    assert repo_from_url("git@work:fork/widgets.git", alias) == "ghe.example.com/fork/widgets"
    assert repo_from_url("https://work/fork/widgets.git", alias) == "work/fork/widgets"
    assert asked == ["work"]


def test_a_preset_gh_repo_wins_over_origin_and_pins_its_own_host():
    origin = FakeGit({"origin": "https://github.com/fork/widgets.git"})

    assert RepoPin({"GH_REPO": "ghe.example.com/o/r"}, origin).gh_env() == {
        "GH_REPO": "ghe.example.com/o/r", "GH_HOST": "ghe.example.com"}
    assert RepoPin({"GH_REPO": ""}, origin).gh_env() == {
        "GH_REPO": "fork/widgets", "GH_HOST": "github.com"}
    assert RepoPin({}, FakeGit()).gh_env() is None


def fixture_ssh(tmp_path, monkeypatch, script):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    ssh = bin_dir / "ssh"
    ssh.write_text("#!/bin/sh\n" + script)
    ssh.chmod(ssh.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("PATH", "%s:/usr/bin:/bin" % bin_dir)


def test_ssh_host_reads_the_hostname_ssh_resolves(tmp_path, monkeypatch):
    fixture_ssh(tmp_path, monkeypatch,
                '[ "$1 $2 $3" = "-G -- work" ] || exit 9\n'
                'printf "user git\\nhostname ghe.example.com\\nhostname other\\n"\n')

    assert ssh_host("work") == "ghe.example.com"


@pytest.mark.parametrize("script", ["exit 255\n", 'echo "user git"\n', 'echo "hostname "\n'],
                         ids=["fails", "no-hostname", "empty-hostname"])
def test_ssh_host_keeps_the_host_as_written_where_ssh_gives_none(tmp_path, monkeypatch, script):
    fixture_ssh(tmp_path, monkeypatch, script)

    assert ssh_host("work") == "work"


def test_ssh_host_keeps_the_host_as_written_without_ssh(tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", str(tmp_path))

    assert ssh_host("work") == "work"
