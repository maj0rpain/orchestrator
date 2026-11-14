# shellcheck shell=bash
# repo.sh - orch.sh's repo and default-branch commands.
# Its tests: scripts/test/orch/repo.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# repo_resolve: resolves the Repo once per shell and memoises the whole answer
# in plain (never exported) shell variables, repo_resolve their one writer:
# REPO_NAME and REPO_SOURCE (GH_REPO or origin; read by repo show,
# repo_pinned_host and doctor.sh), REPO_ORIGIN_SSH (1 when the Repo came from an
# origin in an SSH form, else empty), REPO_MEMO_STATUS (the outcome, 0 or 1, a
# failed resolution too; empty until the first resolve) and REPO_MEMO_HOST (the
# host the repo pins). The memo lives in the shell that resolves: a later
# resolve there, or in a subshell forked from it afterwards, returns the same
# answer and status without starting a process. A subshell's own resolve dies
# with it and never reaches its parent.
# shellcheck disable=SC2034
repo_resolve() {
  local url
  if [ -n "${REPO_MEMO_STATUS:-}" ]; then return "$REPO_MEMO_STATUS"; fi
  REPO_NAME=""
  REPO_SOURCE=""
  REPO_ORIGIN_SSH=""
  REPO_MEMO_HOST=""
  if [ -n "${GH_REPO:-}" ]; then
    REPO_NAME="$GH_REPO"
    REPO_SOURCE=GH_REPO
    REPO_MEMO_HOST="$(repo_host "$REPO_NAME")"
    REPO_MEMO_STATUS=0
    return 0
  fi
  if url="$(git remote get-url origin 2>/dev/null)" \
    && REPO_NAME="$(repo_from_url "$url")"; then
    REPO_SOURCE=origin
    if [ "$(repo_url_form "$url")" = ssh ]; then REPO_ORIGIN_SSH=1; fi
    REPO_MEMO_HOST="$(repo_host "$REPO_NAME")"
    REPO_MEMO_HOST="${REPO_MEMO_HOST:-github.com}"
    REPO_MEMO_STATUS=0
    return 0
  fi
  REPO_NAME=""
  REPO_MEMO_STATUS=1
  return 1
}

# The one parser of a [HOST/]OWNER/REPO repo name, as repo_resolve sets
# REPO_NAME. repo_host <name> prints its explicit host, or nothing for an
# OWNER/REPO name, whose host is the implicit github.com; repo_owner_name
# <name>, below, prints its OWNER/REPO, any host dropped.
repo_host() {
  case "$1" in
    */*/*) printf '%s\n' "${1%%/*}" ;;
  esac
}

# repo_owner_name <name>: the OWNER/REPO of a [HOST/]OWNER/REPO repo name, as
# repo_resolve sets REPO_NAME, any host dropped - repo_host's twin.
repo_owner_name() {
  case "$1" in
    */*/*) printf '%s\n' "${1#*/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# repo_pin: pin every later gh call to the repo - resolve it, export it as
# GH_REPO when that is unset, then pin its host (repo_pin_host). Returns 1,
# exporting nothing, when nothing resolves, and never dies: each caller picks
# its own exit: the gh guard's subshell signal or die, or review ci-log's die
# (exit 1), or die2 in a command that reserves exit 1 and so resolves the repo
# itself (review rerun, issue ready, ticket exists, the open-PR reader,
# autopilot answer).
repo_pin() {
  local preset="${GH_REPO:-}"
  repo_resolve || return 1
  if [ -z "$preset" ]; then export GH_REPO="$REPO_NAME"; fi
  repo_pin_host
}

# repo_url_form <url>: the form of a clone URL, printed - "ssh" for the two SSH
# forms (ssh://... and git's scp-like [user@]host:path, which has no "://" and
# no "/" before its first ":"), "plain" for https://, http:// and git://, and
# nothing for any other string.
repo_url_form() {
  local url="$1"
  case "$url" in
    ssh://*) echo ssh ;;
    https://*|http://*|git://*) echo plain ;;
    *://*) ;;
    *:*)
      case "${url%%:*}" in
        */*) ;;
        *) echo ssh ;;
      esac
      ;;
  esac
}

# repo_ssh_host <host>: the hostname `ssh -G` resolves <host> to, or <host>
# as written when ssh is missing, fails or prints no hostname line.
repo_ssh_host() {
  local out line
  out="$(ssh -G -- "$1" </dev/null 2>/dev/null)" || { printf '%s\n' "$1"; return; }
  line="$(printf '%s\n' "$out" | sed -n 's/^hostname //p;/^hostname /q')"
  printf '%s\n' "${line:-$1}"
}

# repo_from_url <url>: [HOST/]OWNER/REPO from a clone URL in any of its forms -
# https://host/o/r, [user@]host:o/r (git's scp-like form, the user optional),
# ssh://[user@]host[:port]/o/r - with or without .git. For the two SSH forms
# the host is first translated through `ssh -G` (an ssh config alias becomes
# its real hostname; left as written when ssh gives none). Every host is then
# normalised as gh does: lowercased, and *.github.com becomes github.com,
# which is left implicit, as gh -R expects; any other host is kept. A URL with
# no host, a host starting with "-", or not exactly owner/name fails.
repo_from_url() {
  local url="$1" host path form
  form="$(repo_url_form "$url")"
  case "$form" in
    ssh|plain) ;;
    *) return 1 ;;
  esac
  case "$url" in
    *://*)
      url="${url#*://}"
      host="${url%%/*}"
      path="${url#*/}"
      [ "$path" != "$url" ] || return 1
      host="${host##*@}"
      host="${host%%:*}"
      ;;
    *)
      host="${url%%:*}"
      host="${host##*@}"
      path="${url#*:}"
      ;;
  esac
  path="${path%/}"
  path="${path%.git}"
  case "$path" in
    */*/*|/*|*/|"") return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  case "$host" in ""|-*) return 1 ;; esac
  if [ "$form" = ssh ]; then host="$(repo_ssh_host "$host")"; fi
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  case "$host" in *.github.com) host=github.com ;; esac
  if [ "$host" = github.com ]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$host" "$path"
  fi
}

# repo_gh_host: the GitHub host gh targets for the resolved repo (not the
# glossary's Host, the agent CLI), read from the memo
# repo_resolve memoises. The one rule, followed by the gh guard's pin, doctor's
# GitHub probe and repo show --host: the repo's pinned host (repo_pinned_host);
# else (a user-set OWNER/REPO GH_REPO) the user's GH_HOST, or github.com when
# unset, as gh does.
repo_gh_host() {
  local host
  host="$(repo_pinned_host)"
  printf '%s\n' "${host:-${GH_HOST:-github.com}}"
}

# repo_pinned_host: the host the repo itself decides, which the gh guard pins -
# the repo name's explicit host; else github.com for a repo resolved from
# origin; else nothing, for a user-set OWNER/REPO GH_REPO, whose host is the
# user's own GH_HOST.
repo_pinned_host() {
  repo_resolve || return 0
  if [ -n "$REPO_MEMO_HOST" ]; then printf '%s\n' "$REPO_MEMO_HOST"; fi
}

# gh api fills {owner}/{repo} from GH_REPO but takes its host only from
# GH_HOST, never from GH_REPO's host part (gh 2.102.0). So the pin exports the
# repo's pinned host as GH_HOST; for a user-set OWNER/REPO GH_REPO it leaves the
# user's GH_HOST as it is, set or unset. It reads the memo
# repo_resolve memoised.
repo_pin_host() {
  local host
  host="$(repo_pinned_host)"
  if [ -n "$host" ]; then export GH_HOST="$host"; fi
}
# The USR1 trap that dies with REPO_REMEDY is set by orch.sh itself, so a module
# loaded on demand is not what a signalled main shell waits on.

# default-branch [--sha]: the default branch's name, or with --sha the default
# SHA - the full SHA of refs/remotes/origin/<default> as it stands. --sha never
# fetches: finding triage reads it right after its scan's fetch set that ref,
# so it names the remote tip the scan used.
cmd_default_branch() {
  local usage="usage: orch.sh default-branch [--sha]" default ref sha
  [ $# -eq 0 ] && { default_branch; return; }
  [ $# -eq 1 ] && [ "$1" = --sha ] || die "$usage"
  default="$(default_branch)"
  ref="refs/remotes/origin/$default"
  sha="$(git rev-parse --verify -q "$ref^{commit}")" \
    || die "no $ref - fetch the default branch first"
  printf '%s\n' "$sha"
}

cmd_repo() {
  local op="${1:-}"
  shift || true
  case "$op" in
    show)
      case "$*" in
        ""|--name|--host) ;;
        *) die "usage: orch.sh repo show [--name|--host]" ;;
      esac
      repo_resolve || die "$REPO_REMEDY"
      case "${1:-}" in
        --name) note "$REPO_NAME" ;;
        --host) note "$(repo_gh_host)" ;;
        *) note "$REPO_NAME ($REPO_SOURCE)" ;;
      esac
      ;;
    *) die "unknown repo op: ${op:-<none>} (want show)" ;;
  esac
}
