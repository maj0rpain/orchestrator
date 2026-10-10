# shellcheck shell=bash

# --- parallel ----------------------------------------------------------------
# The clone's parallel cap: how many ticket subagents one frontier runs at once,
# 1 meaning sequential. Read here alone, so the default lives in one place and
# the skills never call git config; it is set with git config orchestrator.parallel.
PARALLEL_DEFAULT=3
cmd_parallel() {
  local op="${1:-}" v
  shift || true
  case "$op" in
    show)
      [ $# -eq 0 ] || die "usage: orch.sh parallel show"
      v="$(git config --get orchestrator.parallel 2>/dev/null || true)"
      [ -n "$v" ] || v="$PARALLEL_DEFAULT"
      [[ "$v" =~ ^[0-9]+$ ]] && [ "$((10#$v))" -gt 0 ] ||
        die "orchestrator.parallel is $v - it must be a positive integer (git config orchestrator.parallel <n>)"
      note "$((10#$v))"
      ;;
    *) die "unknown parallel op: ${op:-<none>} (want show)" ;;
  esac
}
