# shellcheck shell=bash
# agent.sh - orch.sh's agent command: the agent setting, a model and a
# reasoning effort per role, each its own git config key.
# Its tests: scripts/test/orch/agent.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The roles, in the order show prints them, and the values each key allows:
# exactly the aliases the Agent tool's model parameter accepts and the levels
# its effort parameter takes, in this Claude Code version. Each list lives here
# alone; set and get both validate against it. inherit is allowed for both
# keys and means no setting at all.
AGENT_ROLES="implementer lens reviewer fixer closer resolver"
AGENT_MODELS="sonnet opus haiku fable inherit"
AGENT_EFFORTS="low medium high xhigh max inherit"

# agent_want <list>: the list as an orch: message's allowed values, a|b|c.
agent_want() { printf '%s' "${1// /|}"; }

# agent_listed <list> <word>: whether <word> is one of the space-separated
# <list>'s words, whole - never several of them, nor part of one.
agent_listed() { list_has "${1// /$'\n'}" "$2"; }

# agent_allowed <kind> <value>: whether <value> is allowed for the model or
# effort key.
agent_allowed() {
  local list
  if [ "$1" = model ]; then list="$AGENT_MODELS"; else list="$AGENT_EFFORTS"; fi
  agent_listed "$list" "$2"
}

# agent_values <kind>: the allowed values for the model or effort key, a|b|c.
agent_values() {
  if [ "$1" = model ]; then agent_want "$AGENT_MODELS"; else agent_want "$AGENT_EFFORTS"; fi
}

# agent_require_role <role>: dies unless <role> is one of the roles.
agent_require_role() {
  agent_listed "$AGENT_ROLES" "$1" && return 0
  die "unknown role ${1:-<none>} (want $(agent_want "$AGENT_ROLES"))"
}

# agent_lookup <kind> <role> <value-var> <source-var>: the key
# orchestrator.<kind>.<role> looked up on its own - local config, then global
# config, else inherit - into <value-var>, and where it came from (local,
# global or inherit) into <source-var>. Never validates: show looks at a bad
# value, get refuses it.
agent_lookup() {
  local lookup_key="orchestrator.$1.$2" lookup_value
  if lookup_value="$(git config --local --get "$lookup_key" 2>/dev/null)"; then
    printf -v "$3" '%s' "$lookup_value"; printf -v "$4" local
  elif lookup_value="$(git config --global --get "$lookup_key" 2>/dev/null)"; then
    printf -v "$3" '%s' "$lookup_value"; printf -v "$4" global
  else
    printf -v "$3" inherit; printf -v "$4" inherit
  fi
}

# agent_unset <scope> <key>: removes <key> at local or global scope; a key that
# is not set is no error.
agent_unset() { git config "--$1" --unset-all "$2" 2>/dev/null || true; }

# agent set <role> [--model <m>] [--effort <e>] [--global]: every argument is
# validated before anything is written. inherit clears the key at that scope,
# so a stored inherit can never hide a global value.
agent_set() {
  local usage="usage: orch.sh agent set <role> [--model <m>] [--effort <e>] [--global]"
  local role="${1:-}" model="" effort="" scope=local kind v
  shift || true
  agent_require_role "$role"
  while [ $# -gt 0 ]; do
    case "$1" in
      --model|--effort)
        kind="${1#--}"
        [ $# -ge 2 ] || die "$1 needs a value (want $(agent_values "$kind"))"
        if [ "$kind" = model ]; then
          [ -z "$model" ] || die "$usage"; model="$2"
        else
          [ -z "$effort" ] || die "$usage"; effort="$2"
        fi
        agent_allowed "$kind" "$2" || die "$kind $2 is not allowed (want $(agent_values "$kind"))"
        shift 2 ;;
      --global) [ "$scope" = local ] || die "$usage"; scope=global; shift ;;
      *) die "$usage" ;;
    esac
  done
  [ -n "$model$effort" ] ||
    die "agent set needs --model or --effort (models: $(agent_values model); efforts: $(agent_values effort))"
  for kind in model effort; do
    if [ "$kind" = model ]; then v="$model"; else v="$effort"; fi
    [ -n "$v" ] || continue
    if [ "$v" = inherit ]; then
      agent_unset "$scope" "orchestrator.$kind.$role"
    else
      git config "--$scope" "orchestrator.$kind.$role" "$v"
    fi
  done
}

# agent clear <role> [--model] [--effort] [--global]: both keys, or only those
# named, at local scope or with --global at global scope. Silent, and exit 0
# on a key that is not set.
agent_clear() {
  local usage="usage: orch.sh agent clear <role> [--model] [--effort] [--global]"
  local role="${1:-}" kinds="" scope=local kind
  shift || true
  agent_require_role "$role"
  while [ $# -gt 0 ]; do
    case "$1" in
      --model|--effort) kinds="$kinds ${1#--}" ;;
      --global) scope=global ;;
      *) die "$usage" ;;
    esac
    shift
  done
  [ -n "$kinds" ] || kinds="model effort"
  for kind in $kinds; do agent_unset "$scope" "orchestrator.$kind.$role"; done
}

# agent show: one line per role, in role order - its model and effort, each
# with its source, a disallowed value marked invalid rather than refused.
agent_show() {
  local role kind v src label line
  for role in $AGENT_ROLES; do
    line="$role"
    for kind in model effort; do
      agent_lookup "$kind" "$role" v src
      label="$src"; agent_allowed "$kind" "$v" || label="$src, invalid"
      line="$line $kind $v ($label)"
    done
    printf '%s\n' "$line"
  done
}

# agent get <role>: exactly two lines, model then effort, the effective values.
# A disallowed value is refused, naming its key, its value, the allowed values
# and the clear that removes it - never quietly read as inherit.
agent_get() {
  local role="$1" kind v src flag out=""
  agent_require_role "$role"
  for kind in model effort; do
    agent_lookup "$kind" "$role" v src
    if ! agent_allowed "$kind" "$v"; then
      flag="--$kind"; [ "$src" = global ] && flag="$flag --global"
      die "orchestrator.$kind.$role is $v - not an allowed $kind (want $(agent_values "$kind")) - clear it: orch.sh agent clear $role $flag"
    fi
    out="$out$kind $v"$'\n'
  done
  printf '%s' "$out"
}

# check_agent_settings: doctor's agent settings check, named in its env check
# list and reporting through its reporter trio. One ok line per role, in role
# order, with its effective model and effort and their sources - a disallowed
# effective value marked invalid, as agent show marks it. Each key is also read
# at local and at global scope on its own, so a disallowed value is a FAIL, on
# top of that listing, even where a local value hides it: it would still stop
# a skill in every repo without that local value. The remedy clears that key
# at that scope.
check_agent_settings() {
  local role kind scope v src flag line scoped
  for role in $AGENT_ROLES; do
    line="agent $role:"
    for kind in model effort; do
      agent_lookup "$kind" "$role" v src
      agent_allowed "$kind" "$v" || src="$src, invalid"
      line="$line $kind $v ($src),"
    done
    d_ok "${line%,}"
    for kind in model effort; do
      for scope in local global; do
        scoped="$(git config "--$scope" --get "orchestrator.$kind.$role" 2>/dev/null)" || continue
        agent_allowed "$kind" "$scoped" && continue
        flag="--$kind"; [ "$scope" = global ] && flag="$flag --global"
        d_fail "orchestrator.$kind.$role is $scoped ($scope) - not an allowed $kind (want $(agent_values "$kind"))"
        d_remedy "orch.sh agent clear $role $flag"
      done
    done
  done
  return 0
}

cmd_agent() {
  local op="${1:-}"
  shift || true
  case "$op" in
    set) agent_set "$@" ;;
    show)
      [ $# -eq 0 ] || die "usage: orch.sh agent show"
      agent_show
      ;;
    clear) agent_clear "$@" ;;
    get)
      [ $# -eq 1 ] || die "usage: orch.sh agent get <role>"
      agent_get "$1"
      ;;
    *) die "unknown agent op: ${op:-<none>} (want set|show|clear|get)" ;;
  esac
}
