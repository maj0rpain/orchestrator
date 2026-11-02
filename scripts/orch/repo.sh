# shellcheck shell=bash
# repo.sh - orch.sh's repo and default-branch commands.
# Its tests: scripts/test/orch/repo.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# REPO_SOURCE is read by repo show and repo_pinned_host, below, and so by
# every gh call's pin and by doctor.sh.
# shellcheck disable=SC2034
repo_resolve() {
  local url
  REPO_NAME=""
  REPO_SOURCE=""
  if [ -n "${GH_REPO:-}" ]; then
    REPO_NAME="$GH_REPO"
    REPO_SOURCE=GH_REPO
    return 0
  fi
  url="$(git remote get-url origin 2>/dev/null)" || return 1
  REPO_NAME="$(repo_from_url "$url")" || { REPO_NAME=""; return 1; }
  REPO_SOURCE=origin
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
# its own exit, the gh guard's subshell signal or die, review rerun's die2.
repo_pin() {
  local preset="${GH_REPO:-}"
  repo_resolve || return 1
  if [ -z "$preset" ]; then export GH_REPO="$REPO_NAME"; fi
  repo_pin_host
}

# repo_from_url <url>: [HOST/]OWNER/REPO from a clone URL in any of its three
# forms - https://host/o/r, git@host:o/r, ssh://[user@]host[:port]/o/r - with
# or without .git. github.com is left implicit, as gh -R expects; any other
# host is kept. A URL with no host or not exactly owner/name fails.
repo_from_url() {
  local url="$1" host path
  case "$url" in
    https://*|http://*|ssh://*|git://*)
      url="${url#*://}"
      host="${url%%/*}"
      path="${url#*/}"
      [ "$path" != "$url" ] || return 1
      host="${host##*@}"
      host="${host%%:*}"
      ;;
    *@*:*)
      host="${url%%:*}"
      host="${host##*@}"
      path="${url#*:}"
      ;;
    *) return 1 ;;
  esac
  path="${path%/}"
  path="${path%.git}"
  case "$path" in
    */*/*|/*|*/|"") return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  [ -n "$host" ] || return 1
  if [ "$host" = github.com ]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$host" "$path"
  fi
}

# repo_gh_host: the GitHub host gh targets for the resolved repo (not the
# glossary's Host, the agent CLI), read from REPO_NAME and REPO_SOURCE as
# repo_resolve sets them. The one rule, followed by the gh guard's pin, doctor's
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
  local host
  host="$(repo_host "$REPO_NAME")"
  if [ -n "$host" ]; then printf '%s\n' "$host"
  elif [ "$REPO_SOURCE" = origin ]; then printf '%s\n' github.com
  fi
}

# gh api fills {owner}/{repo} from GH_REPO but takes its host only from
# GH_HOST, never from GH_REPO's host part (gh 2.102.0). So the pin exports the
# repo's pinned host as GH_HOST; for a user-set OWNER/REPO GH_REPO it leaves the
# user's GH_HOST as it is, set or unset. It reads REPO_NAME and REPO_SOURCE as
# repo_pin's repo_resolve set them.
repo_pin_host() {
  local host
  host="$(repo_pinned_host)"
  if [ -n "$host" ]; then export GH_HOST="$host"; fi
}
trap 'die "$REPO_REMEDY"' USR1

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
