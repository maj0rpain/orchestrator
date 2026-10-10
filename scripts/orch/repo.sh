# shellcheck shell=bash
# repo.sh - orch.sh's repo and default-branch commands.
# Its tests: scripts/test/orch/repo.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

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
