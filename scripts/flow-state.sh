# shellcheck shell=bash
# flow-state.sh - the Flow state module: the one owner of the state format of
# a checkout's flow, .orchestrator/state.json - its keys, their defaults,
# reading (one key per jq, or several in one), its writers and the active-flow
# check - sourced by orch.sh and by hook-common.sh.
#
# It needs nothing from orch.sh, so the hooks can source it alone, as they do
# host.sh: every function takes the state file's path as an argument, none
# reads $ROOT or $STATE, none calls die, and none prints a diagnostic of its
# own - only a reader's value, a builder's JSON (flow_state_json,
# flow_state_pairs_json, flow_state_seed) and flow_state_file's path reach
# stdout. Every outcome is a status:
#
# - Key lookups (flow_state_key_field, and flow_state_get before it reads):
#   1 for a key outside the table, 2 for a programming error such as an
#   unknown column.
# - Predicates (flow_state_readable, flow_state_active): 0 or 1 is the answer,
#   never an error; jq is silenced, so an absent or unparseable file prints
#   nothing.
# - flow_state_get on a file jq cannot parse: jq's own error and status pass
#   through unchanged.
# - flow_state_get_many: 1 for a key outside the table and 2 for a malformed
#   <var>=<key>, both before any jq, assigning and printing nothing; an
#   absent, unparseable or non-object file fails inside its one jq. On any
#   failure nothing is assigned.
# - flow_state_resolve_many_arg: 1 for a key outside the table and 2 for a
#   malformed <var>=<key>, which is caller input, not a programming error.
# - flow_state_pairs_json: 2 for a dangling --string or a key with no value,
#   caller input; any other non-zero status for a value that will not convert,
#   whichever its one walk meets first. Either way it prints nothing.
# - flow_state_merge: non-zero, the file untouched and no temp file left, for
#   an absent file or a failed replace.
# - Writers (flow_state_write, flow_state_write_string, flow_state_write_many,
#   flow_state_create): non-zero, the state file untouched and no temp file
#   left, when the write fails. flow_state_write, flow_state_write_string and
#   flow_state_write_many change an existing state file: an absent one is a
#   failed write, and nothing is created. flow_state_write_many takes
#   --string before a pair to store that pair's value as a JSON string, as
#   flow_state_write_string does; a malformed pair list is a failed write.
#   flow_state_create is the one writer that creates the file, or replaces it
#   whole.
# - flow_state_seed: 2 for an arg row it has no value for, a programming
#   error, and 1 when jq cannot build the seed. Either way it prints
#   nothing.
#
# Every function carries the flow_state_ prefix but state_rows and now, so
# none collides with orch.sh's wrappers, which keep today's names. It stays
# bash-3.2 compatible (no namerefs). Its tests: the "Flow state module"
# section of scripts/test/orch/state.sh.

# The directory under a checkout's root holding its flow state. It lives here
# because where the state file sits is the one fact orch.sh and the hooks
# share: the hooks reach it only through flow_state_file, and orch.sh builds
# its other .orchestrator/ paths on it - so it changes only when the state file
# moves, never for a reason outside the state format. orch.sh marks it
# readonly after sourcing this file; it is assigned plainly here because the
# test setup sources this file too.
ORCH_DIR_NAME=".orchestrator"

# Every flow state key, one row each, in the order init seeds them into
# state.json: key|default|seed|owner. state_get, state set and init all read
# it, so adding a key is one row; an arg row also needs its value in
# flow_state_seed's case, and without it init dies "could not build the state
# seed". state_rows is its one reader: lines starting with # are comments, and
# blank lines are skipped.
#
# default: what state_get returns for a null or missing value. A flow started
#   by an older release lacks keys a fresh one seeds; each reads back as its
#   default. The default applies only to a null or missing value, never to a
#   stored false (jq's `//` would treat false like null).
# seed: the JSON literal init writes, or arg where init supplies the value at
#   run time; the value comes from flow_state_seed's case.
# owner: - for a key state set may write (state_key_settable); otherwise the
#   reason it refuses, printed as "state set refuses <key>: <owner>".
STATE_KEYS='slug||arg|init seeds it
# phase_write spec sets the phase straight after init seeds it.
phase||null|use phase advance (review ready and redo also move it)
# Seeded from --issue when given; state.json carries no field for whether it
# was adopted or published - nothing downstream needs that distinction
# recorded (ADR-0005).
issue||arg|-
# When a flow base may change: see the header of base_set_flow.
base||arg|init seeds it
branch||null|branch create records it
pr||null|pr open records it
base_sha||null|branch create records it
# Null until the review loop asks a human for one; review begin reads null as
# the default.
budget||null|-
iteration|0|0|review begin counts it
# Seeded here, at flow level, because redo and a re-entry leave it alone and a
# later loop renews it: one per loop, spent or not, renewed by review begin at
# the first iteration of each loop, so that one refilled each iteration could
# not become an infinite retry loop.
flake_rerun_used|false|false|-
redo_count|0|0|a redo that retires a branch counts it
# Marks a flow whose handoffs must record Host fallbacks (see
# host_fallbacks_required); an older flow without it reads false.
host_fallbacks|false|true|init seeds it
created||arg|init seeds it
updated||arg|every state change stamps it'

# Prints each data row of STATE_KEYS as key|default|seed|owner, in table
# order: the only reader of $STATE_KEYS, so every other reader skips the same
# comment and blank lines.
state_rows() {
  local k d s o
  while IFS='|' read -r k d s o; do
    case "$k" in '#'*|'') continue ;; esac
    printf '%s|%s|%s|%s\n' "$k" "$d" "$s" "$o"
  done <<EOF
$STATE_KEYS
EOF
}

# The created and updated timestamp: ISO-8601, UTC, to the second.
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# flow_state_key_field <key> <column>: prints column <column> (default, seed
# or owner) of <key>'s row. An unknown key prints nothing and returns 1; an
# unknown column is a programming error, not caller input, and returns 2, so
# it is never read as an unknown key.
flow_state_key_field() {
  local k d s o
  case "$2" in
    default|seed|owner) ;;
    *) return 2 ;;
  esac
  while IFS='|' read -r k d s o; do
    [ "$k" = "$1" ] || continue
    case "$2" in
      default) printf '%s\n' "$d" ;;
      seed)    printf '%s\n' "$s" ;;
      owner)   printf '%s\n' "$o" ;;
    esac
    return 0
  done <<EOT
$(state_rows)
EOT
  return 1
}

# flow_state_file <root>: prints the state file path of the checkout at <root>.
# One trailing / is stripped from <root>, so a repo at / gets
# /.orchestrator/state.json.
flow_state_file() { printf '%s/%s/state.json\n' "${1%/}" "$ORCH_DIR_NAME"; }

# flow_state_readable <file>: true when <file> parses as a JSON object.
flow_state_readable() {
  # jq -e also exits 2 or 5 (usage, parse error); a predicate answers 0 or 1.
  jq -e 'type == "object"' "$1" >/dev/null 2>&1 || return 1
}

# flow_state_get <file> <key>: prints <key>'s value in <file>, or the table's
# default for a null or missing value - never for a stored false (jq's `//`
# would treat false like null).
flow_state_get() {
  local default
  default="$(flow_state_key_field "$2" default)" || return
  jq -r --arg k "$2" --arg d "$default" '.[$k] | if . == null then $d else . end | tostring' "$1"
}

# flow_state_resolve_many_arg <var>=<key> <rows> <prefix>: the one check of a
# multi-key read's argument, die-free and silent. <rows> is state_rows's output.
# Returns 2 for a malformed argument (no =, or an empty <var>) and 1 for a key
# outside the table. On success it sets <prefix>var, <prefix>key and
# <prefix>def - the var, the key and the key's table default - through
# printf -v, so the caller names the variables and none of the caller's own is
# shadowed. Its locals carry the __fsrma_ prefix. No nameref: bash 3.2.
flow_state_resolve_many_arg() {
  local __fsrma_var __fsrma_key __fsrma_k __fsrma_d
  case "$1" in *=*) ;; *) return 2 ;; esac
  __fsrma_var="${1%%=*}"
  __fsrma_key="${1#*=}"
  [ -n "$__fsrma_var" ] || return 2
  while IFS='|' read -r __fsrma_k __fsrma_d _ _; do
    [ "$__fsrma_k" = "$__fsrma_key" ] || continue
    printf -v "${3}var" '%s' "$__fsrma_var"
    printf -v "${3}key" '%s' "$__fsrma_key"
    printf -v "${3}def" '%s' "$__fsrma_d"
    return 0
  done <<<"$2"
  return 1
}

# flow_state_get_many <file> <var>=<key>...: reads every <key> in one jq,
# applies each key's table default as flow_state_get does (the defaults come
# from one pass over the key table, not a subshell per key), and assigns the
# values to the caller's variables <var> through printf -v. Its locals carry
# the __fsgm_ prefix, so a caller may name an out-variable anything but one of
# those: a <var> named like a local (__fsgm_a_var, __fsgm_rc...) assigns the
# local, and the value never reaches the caller. Values
# travel NUL-separated and are read back with read -r -d '', byte for byte; a
# NUL inside a value is dropped by the jq. A key outside the table returns 1
# and a malformed <var>=<key> (no =, or an empty <var>) returns 2, both before
# any jq, by flow_state_resolve_many_arg; a failed read - an absent,
# unparseable or non-object file, null included - returns the jq's status. On
# any failure nothing is assigned.
#
# jq's output goes through a temp file on purpose; do not read it directly.
# This module is sourced by the hooks and stays bash 3.2-compatible. On bash
# 3.2 a process substitution's exit status cannot be read (wait on one needs
# bash 4.4) and a $(...) capture cannot hold the NUL separators, so a direct
# read would lose the jq status this function returns on a failed read.
flow_state_get_many() {
  local __fsgm_file="$1" __fsgm_arg __fsgm_kd="" __fsgm_a_var __fsgm_a_key __fsgm_a_def \
    __fsgm_tmp __fsgm_rc __fsgm_i __fsgm_n=0 __fsgm_rows
  local __fsgm_vars=() __fsgm_vals=()
  shift
  __fsgm_rows="$(state_rows)" || return
  for __fsgm_arg in "$@"; do
    flow_state_resolve_many_arg "$__fsgm_arg" "$__fsgm_rows" __fsgm_a_ || return
    __fsgm_kd="${__fsgm_kd:+$__fsgm_kd$'\n'}$__fsgm_a_key|$__fsgm_a_def"
    __fsgm_vars[__fsgm_n]="$__fsgm_a_var"
    __fsgm_n=$((__fsgm_n + 1))
  done
  [ "$__fsgm_n" -gt 0 ] || return 0
  __fsgm_tmp="$(mktemp)" || return
  jq -j --arg kd "$__fsgm_kd" '. as $o
    | if ($o | type) != "object" then error("not an object") else
      ($kd | split("\n")[] | split("|") as $p
        | ($o[$p[0]] | if . == null then $p[1] else . end | tostring
          | split("\u0000") | join("")), "\u0000") end' \
    "$__fsgm_file" >"$__fsgm_tmp" || { __fsgm_rc=$?; rm -f "$__fsgm_tmp"; return "$__fsgm_rc"; }
  for ((__fsgm_i = 0; __fsgm_i < __fsgm_n; __fsgm_i++)); do
    IFS= read -r -d '' "__fsgm_vals[$__fsgm_i]" || { rm -f "$__fsgm_tmp"; return 1; }
  done <"$__fsgm_tmp"
  rm -f "$__fsgm_tmp"
  for ((__fsgm_i = 0; __fsgm_i < __fsgm_n; __fsgm_i++)); do
    printf -v "${__fsgm_vars[$__fsgm_i]}" '%s' "${__fsgm_vals[$__fsgm_i]}"
  done
}

# flow_state_replace <file> <jq-arg>...: replaces <file> whole with what jq
# prints given <jq-arg>..., private to the writers below. The temp file sits
# beside <file> and replaces it only when jq succeeds; on any failure it is
# removed and the status returned. Every command runs in a conditional, so a
# caller's set -e cannot stop it before the cleanup.
flow_state_replace() {
  local file="$1" tmp rc
  shift
  tmp="$(mktemp "$file.XXXXXX")" || return
  jq "$@" >"$tmp" \
    && mv "$tmp" "$file" \
    || { rc=$?; rm -f "$tmp"; return "$rc"; }
}

# flow_state_merge <file> <json-object>: the one write of keys. It stamps
# updated before it sets the object's keys, so a write of updated itself
# sticks. An absent <file> is a failure.
flow_state_merge() {
  [ -f "$1" ] || return 1
  flow_state_replace "$1" --argjson o "$2" --arg now "$(now)" \
    '.updated = $now | . + $o' "$1"
}

# flow_state_put <file> <key> <json>: sets one key through flow_state_merge.
flow_state_put() {
  local obj
  obj="$(jq -nc --arg k "$2" --argjson v "$3" '{($k): $v}')" || return
  flow_state_merge "$1" "$obj"
}

# flow_state_seed <slug> <issue> <base>: prints the JSON init seeds a new
# flow's state file with, built in one pass over the key table in table order:
# a constant row gives its seed literal, and an arg row the value its case arm
# below gives - an empty <issue> seeds null, any other a number. An arg row
# with no arm returns 2 and prints nothing, rather than seed null.
flow_state_seed() {
  local k s v fields="" seed
  while IFS='|' read -r k _ s _; do
    v="$s"
    if [ "$s" = arg ]; then
      case "$k" in
        slug)    v='$slug' ;;
        issue)   v='(if $issue == "" then null else ($issue | tonumber) end)' ;;
        base)    v='$base' ;;
        created|updated) v='$now' ;;
        *) return 2 ;;
      esac
    fi
    fields="${fields:+$fields,}\"$k\":$v"
  done <<EOT
$(state_rows)
EOT
  seed="$(jq -n --arg slug "$1" --arg issue "$2" --arg base "$3" --arg now "$(now)" \
    "{$fields}" 2>/dev/null)" || return 1
  printf '%s\n' "$seed"
}

# flow_state_create <file> <json>: writes <json> to <file>, creating it or
# replacing it whole - init's write of a new flow's seed - through
# flow_state_replace, so a failed write leaves <file> untouched and no temp
# file. The write goes through jq, so <json> that does not parse is a failed
# write.
flow_state_create() {
  flow_state_replace "$1" . <<<"$2" 2>/dev/null
}

# flow_state_write <file> <key> <value>: the coercing writer. "null" stores a
# JSON null, "true" and "false" a boolean, and an all-digit value a number, so
# a key cleared, flagged or counted here reads back the way init seeded it.
# Every other value is stored as a string. Keys are not checked against the
# table: only lookups are.
flow_state_write() {
  flow_state_put "$1" "$2" "$(flow_state_json "$3")"
}

# flow_state_json <value>: prints <value> as flow_state_write stores it: null,
# true and false literally, an all-digit value as a number, anything else as a
# JSON string.
flow_state_json() {
  case "$1" in
    null|true|false) printf '%s\n' "$1" ;;
    *[!0-9]*|"") jq -n --arg v "$1" '$v' ;;
    *) jq -n --arg v "$1" '$v | tonumber' ;;
  esac
}

# flow_state_pairs_json [--string] <key> <value> [[--string] <key> <value>]...:
# the one walk of the multi-key pair grammar, die-free and silent. Prints the
# pairs as one JSON object: each value coerced as flow_state_json does, or a
# JSON string after --string, as flow_state_write_string stores it. Returns 2
# for a dangling --string or a key with no value, and any other non-zero
# status for a value that will not convert, whichever the walk meets first;
# it prints nothing then.
flow_state_pairs_json() {
  local obj='{}' k v str
  while [ $# -gt 0 ]; do
    str=""
    if [ "$1" = --string ]; then str=1; shift; fi
    [ $# -ge 2 ] || return 2
    k="$1"
    if [ -n "$str" ]; then
      v="$(jq -n --arg v "$2" '$v' 2>/dev/null)" || return 1
    else
      v="$(flow_state_json "$2" 2>/dev/null)" || return 1
    fi
    obj="$(jq -n --argjson o "$obj" --arg k "$k" --argjson v "$v" '$o + {($k): $v}' 2>/dev/null)" || return 1
    shift 2
  done
  printf '%s\n' "$obj"
}

# flow_state_write_many <file> [--string] <key> <value> [[--string] <key>
# <value>]...: sets every key in one replace, the pairs read by
# flow_state_pairs_json and merged by flow_state_merge, which stamps updated.
# A failure - a malformed pair list, a value that will not convert, or a
# failed replace - leaves <file> untouched and no temp file.
flow_state_write_many() {
  local file="$1" obj
  shift
  obj="$(flow_state_pairs_json "$@")" || return
  flow_state_merge "$file" "$obj"
}

# flow_state_write_string <file> <key> <value>: stores <value> as a JSON
# string, always - a branch can bear any name flow_state_write would coerce,
# and a base is always a string, as init stores it.
flow_state_write_string() {
  flow_state_put "$1" "$2" "$(jq -n --arg v "$3" '$v')"
}

# flow_state_active <file>: whether <file> names an active flow. An absent
# file means no flow, and so does phase exactly "done": finished work waiting
# for the next init to archive it (ADR-0009). Anything else - an unreadable
# file, or one with no phase - is a running flow.
flow_state_active() {
  [ -f "$1" ] || return 1
  [ "$(flow_state_get "$1" phase 2>/dev/null)" != "done" ]
}
