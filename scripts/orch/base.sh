# shellcheck shell=bash

base_source() { if [ -n "$(base_setting)" ]; then echo set; else echo default; fi; }

# Dies unless origin answers that it has branch $1 - the one check both
# `base set` and `base set --flow` make before writing anything.
require_on_origin() {
  local st=0
  origin_has_branch "$1" || st=$?
  case "$st" in
    0) ;;
    2) die "branch $1 does not exist on origin - push it first, or check the name" ;;
    *) die "could not reach origin to check that branch $1 exists - nothing was set" ;;
  esac
}

# A flow's base is fixed when init seeds it: no redo and no change to the
# checkout setting rewrites it, so its fork point and PR target cannot move
# under it. base set --flow is the one exception: the explicit correction of
# the active flow's own base, allowed only while the flow has no branch -
# before it first branches, or after redo review retires that branch. The
# checks run in a fixed order and the first that fails is reported; nothing is
# written unless all pass. The name is stored literally, the default branch's
# own included: a flow's base is pinned, unlike the checkout setting.
base_set_flow() {
  local b="$1" branch slug
  flow_active || die "no active flow - nothing was set"
  branch="$(state_get branch)"
  if [ -n "$branch" ]; then
    slug="$(state_get slug)"
    if [ "$(state_get phase)" = review ]; then
      die "flow $slug already has branch $branch - its base can change again once $(flow_cmd redo) retires it"
    fi
    die "flow $slug already has branch $branch - its base can no longer change; abort to start again on another base"
  fi
  is_branch_name "$b" || die "$b is not a valid branch name - nothing was set"
  require_on_origin "$b"
  state_write_string base "$b"
  note "$b (flow)"
}

cmd_base() {
  local op="${1:-}" b="" flow=0 a
  shift || true
  case "$op" in
    set)
      # --flow may come before or after the one branch name; anything else is
      # a usage error.
      for a in "$@"; do
        if [ "$a" = --flow ] && [ "$flow" -eq 0 ]; then flow=1
        elif [ -z "$b" ] && [ "$a" != --flow ]; then b="$a"
        else die "usage: orch.sh base set <branch> [--flow]"
        fi
      done
      [ -n "$b" ] || die "usage: orch.sh base set <branch> [--flow]"
      if [ "$flow" -eq 1 ]; then base_set_flow "$b"; return; fi
      require_on_origin "$b"
      # The default branch's own name is no setting at all: storing it would
      # pin today's default and outlive a rename of it.
      if [ "$b" = "$(default_branch)" ]; then
        git config --unset orchestrator.base 2>/dev/null || true
      else
        git config orchestrator.base "$b"
      fi
      note "$(base_branch) ($(base_source))"
      # The setting only reaches flows started after it; say so rather than
      # let the active flow's PR surprise anyone by targeting its old base.
      if flow_active; then
        local fb; fb="$(flow_base)"
        [ "$fb" = "$(base_branch)" ] ||
          note "note: the active flow $(state_get slug) keeps its own base branch: $fb"
      fi
      ;;
    show)
      [ $# -eq 0 ] || die "usage: orch.sh base show"
      note "$(base_branch) ($(base_source))"
      ;;
    clear)
      [ $# -eq 0 ] || die "usage: orch.sh base clear"
      git config --unset orchestrator.base 2>/dev/null || true
      note "$(base_branch) ($(base_source))"
      ;;
    *) die "unknown base op: ${op:-<none>} (want set|show|clear)" ;;
  esac
}
