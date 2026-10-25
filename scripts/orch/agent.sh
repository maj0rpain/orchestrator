# shellcheck shell=bash
# agent.sh - orch.sh's agent command: the agent setting, a model and a
# reasoning effort per role, each its own git config key.
# Its tests: scripts/test/orch/agent.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The roles, in the order show prints them. The list lives here alone.
AGENT_ROLES="implementer lens reviewer fixer closer resolver"

# The host table: every site reads these arrays, so a host or an allowed list
# is a table entry and no site switches on a host or a kind. Keyed by host
# (claude, junie) or by <host>.<kind> (kind model or effort).
#
# The git config key prefix: <prefix>.<kind>.<role>. Junie's keys live beside
# the Claude Code ones.
declare -A AGENT_HOST_KEY=([claude]=orchestrator [junie]=orchestrator.junie)
# What prefixes a role's line in agent show and the doctor.
declare -A AGENT_HOST_LINE=([claude]="" [junie]="junie ")
# What a clear naming this host's key needs before --model|--effort.
declare -A AGENT_HOST_CLEAR=([claude]="" [junie]=" --host junie")
# The hosts that keep copies agent sync writes.
declare -A AGENT_HOST_SYNCS=([junie]=1)
# The hosts a --host flag names.
AGENT_FLAG_HOSTS="junie"
# The values each key allows: exactly the aliases the Agent tool's model
# parameter accepts and the levels its effort parameter takes, in this Claude
# Code version. inherit is allowed for every key and means no setting at all.
declare -A AGENT_ALLOWED=(
  [claude.model]="sonnet opus haiku fable inherit"
  [claude.effort]="low medium high xhigh max inherit"
  [junie.effort]="low medium high inherit"
)
# A key with a pattern in place of a list: allowed when it is inherit or
# matches the pattern as a whole (a Junie LLM name or custom:<profile-id>). The
# pattern cannot tell an alias from an LLM name, so the note, a printf format
# taking the pattern, warns against aliases.
declare -A AGENT_PATTERN=([junie.model]='[A-Za-z0-9._:/-]+')
declare -A AGENT_NOTE=([junie.model]="inherit or a name matching %s - use the names Junie's /model picker and --model flag take; aliases resolve unpredictably")

# agent_pipe_list <list>: the space-separated list as a|b|c, for an orch:
# message's allowed values.
agent_pipe_list() { printf '%s' "${1// /|}"; }

# agent_allowed <kind> <value> [<host>]: whether <value> is allowed for the
# model or effort key, of Claude Code or of <host>.
agent_allowed() {
  local k="${3:-claude}.$1"
  if [ -n "${AGENT_PATTERN[$k]+x}" ]; then
    [ "$2" = inherit ] && return 0
    [[ "$2" =~ ^${AGENT_PATTERN[$k]}$ ]]
    return
  fi
  word_listed "${AGENT_ALLOWED[$k]}" "$2"
}

# agent_values <kind> [<host>]: the allowed values for the model or effort key,
# a|b|c; for a key with a pattern, the pattern and its note.
agent_values() {
  local k="${2:-claude}.$1"
  if [ -n "${AGENT_NOTE[$k]+x}" ]; then
    # shellcheck disable=SC2059 # the note is the format, taking the pattern
    printf "${AGENT_NOTE[$k]}" "${AGENT_PATTERN[$k]}"
  else
    agent_pipe_list "${AGENT_ALLOWED[$k]}"
  fi
}

# agent_host <arg>...: the host named by a --host flag among the arguments -
# a flag host, or claude when there is none - on stdout. A missing value or
# any other value is refused, naming it. The one parser of --host: each
# command reads it first, so the value is validated before the rest.
agent_host() {
  while [ $# -gt 0 ]; do
    if [ "$1" = --host ]; then
      [ $# -ge 2 ] || die "--host needs a value (want $(agent_pipe_list "$AGENT_FLAG_HOSTS"))"
      word_listed "$AGENT_FLAG_HOSTS" "$2" ||
        die "host $2 is not allowed (want $(agent_pipe_list "$AGENT_FLAG_HOSTS"))"
      printf '%s' "$2"; return
    fi
    shift
  done
  printf claude
}

# agent_key <var> <host> <kind> <role>: the git config key of the setting,
# into <var>.
agent_key() { printf -v "$1" '%s.%s.%s' "${AGENT_HOST_KEY[$2]}" "$3" "$4"; }

# The agent settings' git config, read once per scope per process: one
# associative array per scope, filled lazily and dropped by every write.
declare -A AGENT_CACHE_LOCAL=() AGENT_CACHE_GLOBAL=()
AGENT_CACHE_LOADED=""

# agent_cache_drop: forgets the cache, so the next lookup reloads it.
agent_cache_drop() { AGENT_CACHE_LOADED=""; }

# agent_cache_load: fills both scopes' arrays unless already loaded. The last
# record of a key wins; a record with no newline is a key with no value; a
# value loses its trailing newlines, as a command substitution strips them.
agent_cache_load() {
  [ -z "$AGENT_CACHE_LOADED" ] || return 0
  local scope rec k v
  AGENT_CACHE_LOCAL=(); AGENT_CACHE_GLOBAL=()
  for scope in local global; do
    while IFS= read -r -d '' rec; do
      if [[ "$rec" == *$'\n'* ]]; then k="${rec%%$'\n'*}"; v="${rec#*$'\n'}"
      else k="$rec"; v=""; fi
      while [[ "$v" == *$'\n' ]]; do v="${v%$'\n'}"; done
      if [ "$scope" = local ]; then AGENT_CACHE_LOCAL["$k"]="$v"
      else AGENT_CACHE_GLOBAL["$k"]="$v"; fi
    done < <(git config "--$scope" -z --get-regexp '^orchestrator\.(junie\.)?(model|effort)\.' 2>/dev/null)
  done
  AGENT_CACHE_LOADED=1
}

# agent_scoped <scope> <key> <var>: the value stored at <scope> for <key> into
# <var>; fails when the key is not set there.
agent_scoped() {
  agent_cache_load
  if [ "$1" = local ]; then
    [ -n "${AGENT_CACHE_LOCAL[$2]+x}" ] || return 1
    printf -v "$3" '%s' "${AGENT_CACHE_LOCAL[$2]}"
  else
    [ -n "${AGENT_CACHE_GLOBAL[$2]+x}" ] || return 1
    printf -v "$3" '%s' "${AGENT_CACHE_GLOBAL[$2]}"
  fi
}

# agent_clear_cmd <host> <kind> <role> <scope>: the clear that removes the
# <kind> key of <role> for <host> at <scope> - the remedy of a disallowed value.
agent_clear_cmd() {
  printf 'orch.sh agent clear %s%s --%s' "$3" "${AGENT_HOST_CLEAR[$1]}" "$2"
  [ "$4" != global ] || printf ' --global'
}

# agent_role_values <host> <role> <sep>: <role>'s effective model and effort for
# <host>, each with its source - a disallowed value marked invalid rather than
# refused - as model <v> (<label>)<sep> effort <v> (<label>). Show and the
# doctor both print it.
agent_role_values() {
  local kind v src label out=""
  for kind in model effort; do
    agent_lookup "$kind" "$2" v src "$1"
    label="$src"; agent_allowed "$kind" "$v" "$1" || label="$src, invalid"
    [ -z "$out" ] || out="$out$3 "
    out="$out$kind $v ($label)"
  done
  printf '%s' "$out"
}

# agent_require_role <role>: dies unless <role> is one of the roles.
agent_require_role() {
  word_listed "$AGENT_ROLES" "$1" && return 0
  die "unknown role ${1:-<none>} (want $(agent_pipe_list "$AGENT_ROLES"))"
}

# agent_lookup <kind> <role> <value-var> <source-var> [<host>]: the key
# orchestrator.<kind>.<role> (orchestrator.junie.<kind>.<role> for host junie)
# looked up on its own - local config, then global config, else inherit - into
# <value-var>, and where it came from (local, global or inherit) into
# <source-var>. Never validates: show looks at a bad value, get refuses it.
agent_lookup() {
  local lookup_key lookup_value
  agent_key lookup_key "${5:-claude}" "$1" "$2"
  if agent_scoped local "$lookup_key" lookup_value; then
    printf -v "$3" '%s' "$lookup_value"; printf -v "$4" local
  elif agent_scoped global "$lookup_key" lookup_value; then
    printf -v "$3" '%s' "$lookup_value"; printf -v "$4" global
  else
    printf -v "$3" inherit; printf -v "$4" inherit
  fi
}

# agent_unset <scope> <key>: removes <key> at local or global scope; a key that
# is not set (git config's exit 5) is no error; any other failure dies naming
# the key.
agent_unset() {
  agent_cache_drop
  git_config_unset "$1" "$2" 2>/dev/null || die "cannot clear $2 at $1 scope"
}

# agent_write <scope> <key> <value>: drops the cache, then writes the key; a
# failed write fails the caller.
agent_write() { agent_cache_drop; git config "--$1" "$2" "$3"; }

# agent set <role> [--model <m>] [--effort <e>] [--global]: every argument is
# validated before anything is written. inherit clears the key at that scope,
# so a stored inherit can never hide a global value.
agent_set() {
  local usage="usage: orch.sh agent set <role> [--model <m>] [--effort <e>] [--global] [--host junie]"
  local role="${1:-}" scope=local kind v host seen_host="" key
  local -A vals=()
  shift || true
  agent_require_role "$role"
  host="$(agent_host "$@")" || exit 1
  while [ $# -gt 0 ]; do
    case "$1" in
      --model|--effort)
        kind="${1#--}"
        [ $# -ge 2 ] || die "$1 needs a value (want $(agent_values "$kind" "$host"))"
        [ -z "${vals[$kind]:-}" ] || die "$usage"
        vals[$kind]="$2"
        agent_allowed "$kind" "$2" "$host" || die "$kind $2 is not allowed (want $(agent_values "$kind" "$host"))"
        shift 2 ;;
      --host) [ -z "$seen_host" ] || die "$usage"; seen_host=1; shift 2 ;;
      --global) [ "$scope" = local ] || die "$usage"; scope=global; shift ;;
      *) die "$usage" ;;
    esac
  done
  [ -n "${vals[model]:-}${vals[effort]:-}" ] ||
    die "agent set needs --model or --effort (models: $(agent_values model "$host"); efforts: $(agent_values effort "$host"))"
  for kind in model effort; do
    v="${vals[$kind]:-}"
    [ -n "$v" ] || continue
    agent_key key "$host" "$kind" "$role"
    if [ "$v" = inherit ]; then agent_unset "$scope" "$key"
    else agent_write "$scope" "$key" "$v"; fi
  done
  if [ -n "${AGENT_HOST_SYNCS[$host]+x}" ]; then agent_sync; fi
}

# agent clear <role> [--model] [--effort] [--global]: both keys, or only those
# named, at local scope or with --global at global scope. Silent, and exit 0
# on a key that is not set.
agent_clear() {
  local usage="usage: orch.sh agent clear <role> [--model] [--effort] [--global] [--host junie]"
  local role="${1:-}" kinds="" scope=local kind host seen_host="" key
  shift || true
  agent_require_role "$role"
  host="$(agent_host "$@")" || exit 1
  while [ $# -gt 0 ]; do
    case "$1" in
      --model|--effort) kinds="$kinds ${1#--}" ;;
      --global) scope=global ;;
      --host)
        [ -z "$seen_host" ] || die "$usage"
        seen_host=1
        shift ;;
      *) die "$usage" ;;
    esac
    shift
  done
  [ -n "$kinds" ] || kinds="model effort"
  for kind in $kinds; do agent_key key "$host" "$kind" "$role"; agent_unset "$scope" "$key"; done
  if [ -n "${AGENT_HOST_SYNCS[$host]+x}" ]; then agent_sync; fi
}

# agent_show_host <host>: one line per role, in role order - its model and
# effort, each with its source, a disallowed value marked invalid rather than
# refused. The Junie lines are prefixed junie.
agent_show_host() {
  local role
  agent_cache_load
  for role in $AGENT_ROLES; do
    printf '%s%s %s\n' "${AGENT_HOST_LINE[$1]}" "$role" "$(agent_role_values "$1" "$role" "")"
  done
}

# agent show: Claude Code's six lines, then Junie's six.
agent_show() { agent_show_host claude; agent_show_host junie; }

# agent get <role> [--host junie]: exactly two lines, model then effort, the
# effective values. A disallowed value is refused, naming its key, its value,
# the allowed values and the clear that removes it - never quietly read as
# inherit.
agent_get() {
  local role="$1" host="$2" kind v src out="" key
  agent_require_role "$role"
  for kind in model effort; do
    agent_lookup "$kind" "$role" v src "$host"
    if ! agent_allowed "$kind" "$v" "$host"; then
      agent_key key "$host" "$kind" "$role"
      die "$key is $v - not an allowed $kind (want $(agent_values "$kind" "$host")) - clear it: $(agent_clear_cmd "$host" "$kind" "$role" "$src")"
    fi
    out="$out$kind $v"$'\n'
  done
  printf '%s' "$out"
}

# The marker sync puts on the line right after a copy's opening ---, and the
# exclude line that keeps the copies out of git.
AGENT_COPY_MARKER="# written by orch.sh agent sync"
AGENT_COPY_EXCLUDE=".junie/agents/orch-*.md"

# The shape of the log line Junie writes when it runs an orch agent, as
# custom_agent_<name><tail> regex parts: agent_junie_session builds its three
# patterns from them.
AGENT_JUNIE_RUN_NAME='orch-[A-Za-z0-9-]*'
AGENT_JUNIE_RUN_TAIL='_[0-9]* with parameters'

# agent_role_of <agent>: the role a plugin agent's name belongs to, empty for
# an agent no role covers.
agent_role_of() {
  case "$1" in
    orch-implementer) echo implementer ;;
    orch-lens-*) echo lens ;;
    orch-reviewer-*) echo reviewer ;;
    orch-fixer) echo fixer ;;
    orch-closer) echo closer ;;
    orch-resolver) echo resolver ;;
  esac
}

# agent_copy_marked <file>: whether <file> carries the marker - on the line
# right after its opening --- and nowhere else.
agent_copy_marked() {
  [ "$(sed -n 1p "$1")" = "---" ] && [ "$(sed -n 2p "$1")" = "$AGENT_COPY_MARKER" ]
}

# agent_copy_content <agent-file> <model> <effort>: what sync writes for a
# plugin agent: the file with the marker, then model: and reasoningLevel:
# (each only when not inherit) right after its opening ---.
agent_copy_content() {
  awk -v marker="$AGENT_COPY_MARKER" -v model="$2" -v effort="$3" '
    NR == 1 {
      print
      print marker
      if (model != "inherit") print "model: " model
      if (effort != "inherit") print "reasoningLevel: " effort
      next
    }
    { print }' "$1"
}

# agent_sync_plan: what agent sync would change in this checkout's
# .junie/agents/, without changing it - the one comparison sync and doctor
# share. Sets AGENT_PLAN_PLUGIN (the plugin root), AGENT_PLAN_DIR,
# AGENT_PLAN_WANT (the copies that should exist, one name per line),
# AGENT_PLAN_REFUSED (the unmarked orch-*.md in the way of a copy,
# space-separated), AGENT_PLAN_WRITES (name|model|effort|missing|stale per copy
# to write; | because a custom: model holds a colon) and AGENT_PLAN_DELETES
# (marked copies no longer wanted, one name per line).
agent_sync_plan() {
  # src_model and src_effort receive agent_lookup's source and go unread here.
  # shellcheck disable=SC2034
  local file copy name role m e copy_model copy_effort src_model src_effort content target state
  AGENT_PLAN_PLUGIN="$(CDPATH='' cd -- "$ORCH_SCRIPTS/.." && pwd)"
  AGENT_PLAN_DIR="$ROOT/.junie/agents"
  AGENT_PLAN_WANT="" AGENT_PLAN_REFUSED="" AGENT_PLAN_WRITES=() AGENT_PLAN_DELETES=""
  for file in "$AGENT_PLAN_PLUGIN"/agents/orch-*.md; do
    [ -e "$file" ] || continue
    name="$(basename "$file" .md)"
    role="$(agent_role_of "$name")"
    [ -n "$role" ] || continue
    agent_lookup model "$role" m src_model junie
    agent_lookup effort "$role" e src_effort junie
    copy_model="$m" copy_effort="$e"
    agent_allowed model "$m" junie || copy_model=inherit
    agent_allowed effort "$e" junie || copy_effort=inherit
    [ "$copy_model$copy_effort" = inheritinherit ] && continue
    AGENT_PLAN_WANT="$AGENT_PLAN_WANT$name"$'\n'
    target="$AGENT_PLAN_DIR/$name.md"
    state=missing
    content="$(agent_copy_content "$file" "$copy_model" "$copy_effort"; echo x)"
    if [ -e "$target" ]; then
      if ! agent_copy_marked "$target"; then AGENT_PLAN_REFUSED="$AGENT_PLAN_REFUSED $name.md"; continue; fi
      [ "$(cat "$target"; echo x)" = "$content" ] && continue
      state=stale
    fi
    AGENT_PLAN_WRITES+=("$name|$copy_model|$copy_effort|$state")
  done
  AGENT_PLAN_REFUSED="${AGENT_PLAN_REFUSED# }"
  for copy in "$AGENT_PLAN_DIR"/orch-*.md; do
    [ -e "$copy" ] || continue
    name="$(basename "$copy" .md)"
    agent_copy_marked "$copy" || continue
    list_has "$AGENT_PLAN_WANT" "$name" && continue
    AGENT_PLAN_DELETES="$AGENT_PLAN_DELETES$name"$'\n'
  done
}

# agent sync: brings the checkout's .junie/agents/ copies up to date with the
# Junie setting. Nothing is changed when an unmarked orch-*.md is in the way of
# a copy it would write: that is refused by name, after the whole plan is made.
agent_sync() {
  local dir name m e state w
  agent_sync_plan
  dir="$AGENT_PLAN_DIR"
  [ -z "$AGENT_PLAN_REFUSED" ] ||
    die "agent sync: $AGENT_PLAN_REFUSED in $dir carries no sync marker - not written by orch.sh agent sync, so left alone; rename or remove it, then rerun orch.sh agent sync"
  if [ -n "$AGENT_PLAN_WANT" ]; then exclude_line "$AGENT_COPY_EXCLUDE" || die "agent sync: cannot add $AGENT_COPY_EXCLUDE to the git exclude file $(git rev-parse --git-common-dir)/info/exclude"; fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    rm -f -- "$dir/$name.md" || die "agent sync: cannot delete $dir/$name.md"
  done <<<"$AGENT_PLAN_DELETES"
  for w in ${AGENT_PLAN_WRITES[@]+"${AGENT_PLAN_WRITES[@]}"}; do
    IFS="|" read -r name m e state <<<"$w"
    mkdir -p "$dir" || die "agent sync: cannot create $dir"
    agent_copy_content "$AGENT_PLAN_PLUGIN/agents/$name.md" "$m" "$e" >"$dir/$name.md" ||
      die "agent sync: cannot write $dir/$name.md"
  done
}

# agent_junie_session_cannot_tell <reason>: doctor's one ok line when Junie's
# files cannot say what the agents ran on. Never a FAIL.
agent_junie_session_cannot_tell() { d_ok "junie session: cannot tell ($1)"; }

# agent_junie_ran <agent> <model> <effort>: whether what <agent> ran on
# agrees with its role's Junie setting - a model is compared only when set,
# and matches when equal to it or it followed by - and more; an effort is
# compared only when set. Prints the line's set-part, (set model <v>, effort
# <v>), on stdout; the status is the verdict.
agent_junie_ran() {
  # src_model and src_effort receive agent_lookup's source and go unread here.
  # shellcheck disable=SC2034
  local role set_model set_effort src_model src_effort mismatch=0
  role="$(agent_role_of "$1")"
  set_model=inherit; set_effort=inherit
  if [ -n "$role" ]; then
    agent_lookup model "$role" set_model src_model junie
    agent_lookup effort "$role" set_effort src_effort junie
  fi
  printf '(set model %s, effort %s)' "$set_model" "$set_effort"
  if [ "$set_model" != inherit ] && [ "$2" != "$set_model" ] && [ "${2#"$set_model"-}" = "$2" ]; then mismatch=1; fi
  if [ "$set_effort" != inherit ] && [ "$3" != "$set_effort" ]; then mismatch=1; fi
  return "$mismatch"
}

# agent_junie_newest_log [<session id>]: prints the path of the newest
# $HOME/.junie/logs/log-*.log by modification time, only among those naming
# the session id when one is given; nothing when none qualifies.
agent_junie_newest_log() {
  local sid="${1:-}" f log=""
  for f in "$HOME"/.junie/logs/log-*.log; do
    [ -f "$f" ] || continue
    [ -z "$sid" ] || grep -aqF -- "$sid" "$f" 2>/dev/null || continue
    if [ -z "$log" ] || [ "$f" -nt "$log" ]; then log="$f"; fi
  done
  [ -z "$log" ] || printf '%s\n' "$log"
}

# agent_junie_field <line> <word>: the value after <word>= in a Junie log
# line, up to a space, comma or closing parenthesis; nothing when absent.
agent_junie_field() {
  printf '%s' "$1" | sed -n "s/.*[^A-Za-z]$2=\\([^ ,)]*\\).*/\\1/p"
}

# agent_junie_session: doctor's best-effort report of what each orch-* agent
# ran on in the last Junie session for this checkout, read from Junie's own
# files under $HOME/.junie: the sessions/index.jsonl entry with the greatest
# updatedAt whose projectDir is this checkout's root, then the one
# logs/log-*.log holding its sessionId; events.jsonl is not read. Each
# agent's last "Executing agent custom_agent_<agent>_<n> with parameters"
# line gives its model= and its effort (effort= unless null, else
# reasoningEffort= unless null, else inherited). A file that is missing or
# does not parse gives one ok line saying it cannot tell, never a FAIL.
agent_junie_session() {
  local index="$HOME/.junie/sessions/index.jsonl" sid log lines agent line model effort set_part report="" ran_line report_line word v kind
  command -v jq >/dev/null 2>&1 || { agent_junie_session_cannot_tell "jq is not installed"; return 0; }
  [ -f "$index" ] || { agent_junie_session_cannot_tell "no Junie session index"; return 0; }
  sid="$(jq -rs --arg d "$ROOT" 'map(select(.projectDir == $d)) | sort_by(.updatedAt) | last | .sessionId // empty' "$index" 2>/dev/null)" ||
    { agent_junie_session_cannot_tell "the session index does not parse"; return 0; }
  [ -n "$sid" ] || { agent_junie_session_cannot_tell "no session for this checkout"; return 0; }
  log="$(agent_junie_newest_log "$sid")"
  [ -n "$log" ] || { agent_junie_session_cannot_tell "no log names session $sid"; return 0; }
  lines="$(grep -a "Executing agent custom_agent_$AGENT_JUNIE_RUN_NAME$AGENT_JUNIE_RUN_TAIL" "$log" 2>/dev/null)" || true
  [ -n "$lines" ] || { agent_junie_session_cannot_tell "the log holds no agent runs"; return 0; }
  while IFS= read -r agent; do
    line="$(printf '%s\n' "$lines" | grep -a "custom_agent_$agent$AGENT_JUNIE_RUN_TAIL" | tail -1)"
    model="$(agent_junie_field "$line" model)"
    [ -n "$model" ] || { agent_junie_session_cannot_tell "the log does not parse"; return 0; }
    effort=inherited
    for word in effort reasoningEffort; do
      v="$(agent_junie_field "$line" "$word")"
      if [ -n "$v" ] && [ "$v" != null ]; then effort="$v"; break; fi
    done
    ran_line="junie $agent ran model $model, effort $effort"
    if set_part="$(agent_junie_ran "$agent" "$model" "$effort")"; then
      report="$report"$'\n'"ok|$ran_line $set_part"
    else
      report="$report"$'\n'"warn|$ran_line $set_part"
    fi
  done < <(printf '%s\n' "$lines" | sed -n "s/.*custom_agent_\\($AGENT_JUNIE_RUN_NAME\\)$AGENT_JUNIE_RUN_TAIL.*/\\1/p" | awk '!seen[$0]++')
  while IFS='|' read -r kind report_line; do
    [ -n "$kind" ] || continue
    if [ "$kind" = ok ]; then d_ok "$report_line"; else d_warn "$report_line"; fi
  done <<<"$report"
}

# agent_junie_unrecognized: doctor's best-effort FAIL on Junie's own
# Unrecognized 'model' value line, from the most recent log
# (logs/log-*.log modified last) whether or not a session was found: when the
# value is a role's effective Junie model, it names the role, prints the
# log's Allowed LLM names and gives the agent set that fixes it. No log, or
# no such role, prints nothing.
agent_junie_unrecognized() {
  local log value line role v src names
  log="$(agent_junie_newest_log)"
  [ -n "$log" ] || return 0
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    line="$(grep -aF "Unrecognized 'model' value '$value'" "$log" | tail -1)"
    names="$(printf '%s' "$line" | sed -n 's/.*\(Allowed LLM names:.*\)/\1/p')"
    for role in $AGENT_ROLES; do
      agent_lookup model "$role" v src junie
      [ "$v" = "$value" ] || continue
      d_fail "Junie did not recognise model $value, set for $role ($src) - it fell back to the session model"
      [ -z "$names" ] || d_remedy "$names"
      d_remedy "orch.sh agent set $role --host junie --model <id>"
    done
  done < <(sed -n "s/.*Unrecognized 'model' value '\\([^']*\\)'.*/\\1/p" "$log" 2>/dev/null | awk '!seen[$0]++')
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
  check_agent_settings_host claude
  agent_junie_session
  agent_junie_unrecognized
  check_junie_agent_settings
  return 0
}

# check_agent_settings_host <host>: one ok line per role, with its effective
# model and effort for <host> and their sources - a disallowed effective value
# marked invalid - then a FAIL for each disallowed stored value, read at each
# scope on its own. Junie's lines are named agent junie <role>.
check_agent_settings_host() {
  local host="$1" role kind scope scoped key
  agent_cache_load
  for role in $AGENT_ROLES; do
    d_ok "agent ${AGENT_HOST_LINE[$host]}$role: $(agent_role_values "$host" "$role" ",")"
    for kind in model effort; do
      agent_key key "$host" "$kind" "$role"
      for scope in local global; do
        agent_scoped "$scope" "$key" scoped || continue
        agent_allowed "$kind" "$scoped" "$host" && continue
        d_fail "$key is $scoped ($scope) - not an allowed $kind (want $(agent_values "$kind" "$host"))"
        d_remedy "$(agent_clear_cmd "$host" "$kind" "$role" "$scope")"
      done
    done
  done
}

# check_junie_agent_settings: the Junie half of check_agent_settings: the
# per-role lines of check_agent_settings_host junie, and a WARN when this
# checkout's .junie/agents/ copies are not what agent sync would leave - the
# plan sync itself makes, so the two cannot disagree.
check_junie_agent_settings() {
  check_agent_settings_host junie
  agent_sync_plan
  local missing="" stale="" extra="" w name rest drift
  for w in ${AGENT_PLAN_WRITES[@]+"${AGENT_PLAN_WRITES[@]}"}; do
    name="${w%%|*}"; rest="${w##*|}"
    if [ "$rest" = missing ]; then missing="$missing $name.md"; else stale="$stale $name.md"; fi
  done
  while IFS= read -r name; do
    [ -n "$name" ] && extra="$extra $name.md"
  done <<<"$AGENT_PLAN_DELETES"
  [ -z "$missing$stale$extra$AGENT_PLAN_REFUSED" ] && return 0
  drift="Junie agent copies in $AGENT_PLAN_DIR are not what agent sync would leave:"
  [ -z "$missing" ] || drift="$drift missing$missing;"
  [ -z "$stale" ] || drift="$drift stale$stale;"
  [ -z "$extra" ] || drift="$drift extra$extra;"
  [ -z "$AGENT_PLAN_REFUSED" ] || drift="$drift $AGENT_PLAN_REFUSED carries no sync marker and is in the way;"
  d_warn "${drift%;}"
  d_remedy "orch.sh agent sync"
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
    roles)
      [ $# -eq 0 ] || die "usage: orch.sh agent roles"
      printf '%s\n' $AGENT_ROLES
      ;;
    sync)
      [ $# -eq 0 ] || die "usage: orch.sh agent sync"
      agent_sync
      ;;
    get)
      local get_usage="usage: orch.sh agent get <role> [--host junie]" get_host
      if [ $# -eq 1 ] || { [ $# -ge 2 ] && [ $# -le 3 ] && [ "$2" = --host ]; }; then
        get_host="$(agent_host "${@:2}")" || exit 1
        agent_get "$1" "$get_host"
      else die "$get_usage"; fi
      ;;
    *) die "unknown agent op: ${op:-<none>} (want set|show|clear|get|sync|roles)" ;;
  esac
}
