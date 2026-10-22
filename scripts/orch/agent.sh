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

# Junie's keys live beside the Claude Code ones, as
# orchestrator.junie.<kind>.<role>. A Junie model is allowed when it matches
# this pattern as a whole (a Junie LLM name or custom:<profile-id>), or is
# inherit; a Junie effort is one of these. The pattern cannot tell an alias
# from an LLM name, so the refusal warns against aliases.
AGENT_JUNIE_MODEL_PATTERN='[A-Za-z0-9._:/-]+'
AGENT_JUNIE_EFFORTS="low medium high inherit"

# agent_want <list>: the list as an orch: message's allowed values, a|b|c.
agent_want() { printf '%s' "${1// /|}"; }

# agent_listed <list> <word>: whether <word> is one of the space-separated
# <list>'s words, whole - never several of them, nor part of one.
agent_listed() { list_has "${1// /$'\n'}" "$2"; }

# agent_allowed <kind> <value> [<host>]: whether <value> is allowed for the
# model or effort key, of Claude Code or, with <host> junie, of Junie.
agent_allowed() {
  local list
  if [ "${3:-}" = junie ]; then
    if [ "$1" = model ]; then
      [ "$2" = inherit ] && return 0
      [[ "$2" =~ ^${AGENT_JUNIE_MODEL_PATTERN}$ ]]
      return
    fi
    list="$AGENT_JUNIE_EFFORTS"
  elif [ "$1" = model ]; then list="$AGENT_MODELS"; else list="$AGENT_EFFORTS"; fi
  agent_listed "$list" "$2"
}

# agent_values <kind> [<host>]: the allowed values for the model or effort key,
# a|b|c; for a Junie model, the pattern and what to use instead of an alias.
agent_values() {
  if [ "${2:-}" = junie ]; then
    if [ "$1" = model ]; then
      printf 'inherit or a name matching %s - use the names Junie'"'"'s /model picker and --model flag take; aliases resolve unpredictably' \
        "$AGENT_JUNIE_MODEL_PATTERN"
    else
      agent_want "$AGENT_JUNIE_EFFORTS"
    fi
  elif [ "$1" = model ]; then agent_want "$AGENT_MODELS"; else agent_want "$AGENT_EFFORTS"; fi
}

# agent_host <arg>...: the host named by a --host flag among the arguments -
# junie, or claude when there is none - on stdout. Any other value is refused,
# naming it.
agent_host() {
  while [ $# -gt 0 ]; do
    if [ "$1" = --host ]; then
      [ $# -ge 2 ] || die "--host needs a value (want junie)"
      [ "$2" = junie ] || die "host $2 is not allowed (want junie)"
      printf junie; return 0
    fi
    shift
  done
  printf claude
}

# agent_key <host> <kind> <role>: the git config key of the setting.
agent_key() {
  if [ "$1" = junie ]; then printf 'orchestrator.junie.%s.%s' "$2" "$3"
  else printf 'orchestrator.%s.%s' "$2" "$3"; fi
}

# agent_host_flag <host>: what a clear naming this host's key needs before
# --model|--effort, empty for Claude Code.
agent_host_flag() { [ "$1" = junie ] && printf ' --host junie' || true; }

# agent_require_role <role>: dies unless <role> is one of the roles.
agent_require_role() {
  agent_listed "$AGENT_ROLES" "$1" && return 0
  die "unknown role ${1:-<none>} (want $(agent_want "$AGENT_ROLES"))"
}

# agent_lookup <kind> <role> <value-var> <source-var> [<host>]: the key
# orchestrator.<kind>.<role> (orchestrator.junie.<kind>.<role> for host junie) looked up on its own - local config, then global
# config, else inherit - into <value-var>, and where it came from (local,
# global or inherit) into <source-var>. Never validates: show looks at a bad
# value, get refuses it.
agent_lookup() {
  local lookup_key lookup_value
  lookup_key="$(agent_key "${5:-claude}" "$1" "$2")"
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
  local usage="usage: orch.sh agent set <role> [--model <m>] [--effort <e>] [--global] [--host junie]"
  local role="${1:-}" model="" effort="" scope=local kind v host seen_host=""
  shift || true
  agent_require_role "$role"
  host="$(agent_host "$@")" || exit 1
  while [ $# -gt 0 ]; do
    case "$1" in
      --model|--effort)
        kind="${1#--}"
        [ $# -ge 2 ] || die "$1 needs a value (want $(agent_values "$kind" "$host"))"
        if [ "$kind" = model ]; then
          [ -z "$model" ] || die "$usage"; model="$2"
        else
          [ -z "$effort" ] || die "$usage"; effort="$2"
        fi
        agent_allowed "$kind" "$2" "$host" || die "$kind $2 is not allowed (want $(agent_values "$kind" "$host"))"
        shift 2 ;;
      --host) [ -z "$seen_host" ] || die "$usage"; seen_host=1; shift 2 ;;
      --global) [ "$scope" = local ] || die "$usage"; scope=global; shift ;;
      *) die "$usage" ;;
    esac
  done
  [ -n "$model$effort" ] ||
    die "agent set needs --model or --effort (models: $(agent_values model "$host"); efforts: $(agent_values effort "$host"))"
  for kind in model effort; do
    if [ "$kind" = model ]; then v="$model"; else v="$effort"; fi
    [ -n "$v" ] || continue
    if [ "$v" = inherit ]; then
      agent_unset "$scope" "$(agent_key "$host" "$kind" "$role")"
    else
      git config "--$scope" "$(agent_key "$host" "$kind" "$role")" "$v"
    fi
  done
}

# agent clear <role> [--model] [--effort] [--global]: both keys, or only those
# named, at local scope or with --global at global scope. Silent, and exit 0
# on a key that is not set.
agent_clear() {
  local usage="usage: orch.sh agent clear <role> [--model] [--effort] [--global] [--host junie]"
  local role="${1:-}" kinds="" scope=local kind host seen_host=""
  shift || true
  agent_require_role "$role"
  host="$(agent_host "$@")" || exit 1
  while [ $# -gt 0 ]; do
    case "$1" in
      --model|--effort) kinds="$kinds ${1#--}" ;;
      --global) scope=global ;;
      --host) [ -z "$seen_host" ] || die "$usage"; seen_host=1; shift ;;
      *) die "$usage" ;;
    esac
    shift
  done
  [ -n "$kinds" ] || kinds="model effort"
  for kind in $kinds; do agent_unset "$scope" "$(agent_key "$host" "$kind" "$role")"; done
}

# agent_show_host <host>: one line per role, in role order - its model and
# effort, each with its source, a disallowed value marked invalid rather than
# refused. The Junie lines are prefixed junie.
agent_show_host() {
  local role kind v src label line
  for role in $AGENT_ROLES; do
    line="$role"; [ "$1" = junie ] && line="junie $role"
    for kind in model effort; do
      agent_lookup "$kind" "$role" v src "$1"
      label="$src"; agent_allowed "$kind" "$v" "$1" || label="$src, invalid"
      line="$line $kind $v ($label)"
    done
    printf '%s\n' "$line"
  done
}

# agent show: Claude Code's six lines, then Junie's six.
agent_show() { agent_show_host claude; agent_show_host junie; }

# agent get <role> [--host junie]: exactly two lines, model then effort, the effective values.
# A disallowed value is refused, naming its key, its value, the allowed values
# and the clear that removes it - never quietly read as inherit.
agent_get() {
  local role="$1" host="$2" kind v src flag out=""
  agent_require_role "$role"
  for kind in model effort; do
    agent_lookup "$kind" "$role" v src "$host"
    if ! agent_allowed "$kind" "$v" "$host"; then
      flag="$(agent_host_flag "$host") --$kind"; [ "$src" = global ] && flag="$flag --global"
      die "$(agent_key "$host" "$kind" "$role") is $v - not an allowed $kind (want $(agent_values "$kind" "$host")) - clear it: orch.sh agent clear $role$flag"
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
      local get_usage="usage: orch.sh agent get <role> [--host junie]"
      if [ $# -eq 1 ]; then agent_get "$1" claude
      elif [ $# -eq 3 ] && [ "$2" = --host ]; then
        local get_host
        get_host="$(agent_host "$@")" || exit 1
        agent_get "$1" "$get_host"
      else die "$get_usage"; fi
      ;;
    *) die "unknown agent op: ${op:-<none>} (want set|show|clear|get)" ;;
  esac
}
