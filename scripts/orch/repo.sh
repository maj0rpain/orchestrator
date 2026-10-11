# shellcheck shell=bash
# repo.sh - orch.sh's repo and default-branch commands.
# Its tests: scripts/test/orch/repo.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# REPO_SOURCE is read by repo show, below, and by doctor.sh.
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
# <name>, in doctor.sh, its one caller, prints its OWNER/REPO, any host
# dropped.
repo_host() {
  case "$1" in
    */*/*) printf '%s\n' "${1%%/*}" ;;
  esac
}

# repo_pin: pin every later gh call to the repo - when GH_REPO is unset, resolve
# it and export it as GH_REPO, then pin its host (repo_pin_host). Returns 1,
# exporting nothing, when nothing resolves, and never dies: each caller picks
# its own exit, the gh guard's subshell signal or die, review rerun's die2.
repo_pin() {
  if [ -z "${GH_REPO:-}" ]; then
    repo_resolve || return 1
    export GH_REPO="$REPO_NAME"
  fi
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

# gh api fills {owner}/{repo} from GH_REPO but takes its host only from
# GH_HOST, never from GH_REPO's host part (gh 2.102.0). So a HOST/OWNER/REPO
# GH_REPO also exports GH_HOST=HOST; an OWNER/REPO one, a github.com repo,
# leaves GH_HOST as it is.
repo_pin_host() {
  local host
  host="$(repo_host "$GH_REPO")"
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
  local op="${1:-}" host
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
        --host) host="$(repo_host "$REPO_NAME")"; note "${host:-github.com}" ;;
        *) note "$REPO_NAME ($REPO_SOURCE)" ;;
      esac
      ;;
    *) die "unknown repo op: ${op:-<none>} (want show)" ;;
  esac
}
