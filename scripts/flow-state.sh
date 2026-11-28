# shellcheck shell=bash
# flow-state.sh - the Flow state module: the one owner of the state format of
# a checkout's flow, .orchestrator/state.json - its keys, their defaults,
# reading (one key per jq, or several in one) and the active-flow check -
# sourced by orch.sh and by hook-common.sh. It writes nothing: the Python
# package's Flow state module, scripts/orch_py/orch/flow_state.py, makes every
# write of the file, copies flow_state_get_many's rules and the key table's
# key, default and seed columns, and writes a new flow's seed for Python init,
# the only writer that creates the file. The golden state.json files in
# scripts/orch_py/tests/flow_state/ pin the two: those under read/ and refused/
# the readers, which the flow-state section reads through flow_state_get_many
# too, and those under seed/, which only pytest reads, the seed to the bytes
# bash init wrote.
#
# It needs nothing from orch.sh, so the hooks can source it alone, as they do
# host.sh: every function takes the state file's path as an argument, none
# reads $ROOT or $STATE, none calls die, and none prints a diagnostic of its
# own - only a reader's value and flow_state_file's path reach stdout. Every
# outcome is a status:
#
# - Key lookups (flow_state_key_field, and flow_state_get before it reads):
#   1 for a key outside the table, 2 for a programming error such as an
#   unknown column.
# - Predicates (flow_state_active): 0 or 1 is the answer,
#   never an error; jq is silenced, so an absent or unparseable file prints
#   nothing.
# - flow_state_get on a file jq cannot parse: jq's own error and status pass
#   through unchanged.
# - flow_state_get_many: 1 for a key outside the table and 2 for a malformed
#   <var>=<key>, both before any jq, assigning and printing nothing; every
#   failed read returns 1: anything but exactly one JSON object inside its one
#   jq, or a missing or wrong sentinel, a short read or a record after it. On
#   any failure nothing is assigned.
# - flow_state_resolve_many_arg: 1 for a key outside the table and 2 for a
#   malformed <var>=<key>, which is caller input, not a programming error.
#
# Every function carries the flow_state_ prefix but state_rows. It stays
# bash-3.2 compatible (no namerefs). Its tests: the "Flow state module"
# section of scripts/test/orch/flow-state.sh.

# The directory under a checkout's root holding its flow state. It lives here
# because where the state file sits is the one fact orch.sh and the hooks
# share: the hooks reach it only through flow_state_file, and orch.sh builds
# its other .orchestrator/ paths on it - so it changes only when the state file
# moves, never for a reason outside the state format. It is assigned plainly,
# since the hooks and the tests source this file.
ORCH_DIR_NAME=".orchestrator"

# Every flow state key, one row each, in the order init seeds them into
# state.json: key|default|seed. state_get reads it, so adding a key is one row
# here and one in the Python Flow state module's STATE_KEYS, which Python init
# seeds from and whose owner column state set reads; an arg row also needs its
# value in that module's _SEED_ARGS, and without it init dies "could not build
# the state seed". The seed column is the shared format's bash record, which
# pytest's parity test pins Python's to. state_rows is its one reader: lines
# starting with # are comments, and blank lines are skipped.
#
# default: what state_get returns for a null or missing value. A flow started
#   by an older release lacks keys a fresh one seeds; each reads back as its
#   default. The default applies only to a null or missing value, never to a
#   stored false (jq's `//` would treat false like null).
# seed: the JSON literal init writes, or arg where init supplies the value at
#   run time; Python init writes it (orch/flow_state.py's _SEED_ARGS).
STATE_KEYS='slug||arg
# init records the spec phase straight after it seeds the file.
phase||null
# Seeded from --issue when given; state.json carries no field for whether it
# was adopted or published - nothing downstream needs that distinction
# recorded (ADR-0005).
issue||arg
# When a flow base may change: see the docstring of set_flow in orch/base.py.
base||arg
branch||null
pr||null
base_sha||null
# Null until the review loop asks a human for one; review begin reads null as
# the default.
budget||null
iteration|0|0
# Seeded here, at flow level, because redo and a re-entry leave it alone and a
# later loop renews it: one per loop, spent or not, renewed by review begin at
# the first iteration of each loop, so that one refilled each iteration could
# not become an infinite retry loop.
flake_rerun_used|false|false
redo_count|0|0
# Marks a flow whose handoffs must record Host fallbacks (handoff.py reads
# it); an older flow without it reads false.
host_fallbacks|false|true
created||arg
updated||arg'

# Prints each data row of STATE_KEYS as key|default|seed, in table order: the
# only reader of $STATE_KEYS, so every other reader skips the same comment and
# blank lines.
state_rows() {
  local k d s
  while IFS='|' read -r k d s; do
    case "$k" in '#'*|'') continue ;; esac
    printf '%s|%s|%s\n' "$k" "$d" "$s"
  done <<EOF
$STATE_KEYS
EOF
}

# flow_state_key_field <key> <column>: prints column <column> (default or
# seed) of <key>'s row. An unknown key prints nothing and returns 1; an
# unknown column is a programming error, not caller input, and returns 2, so
# it is never read as an unknown key.
flow_state_key_field() {
  local k d s
  case "$2" in
    default|seed) ;;
    *) return 2 ;;
  esac
  while IFS='|' read -r k d s; do
    [ "$k" = "$1" ] || continue
    case "$2" in
      default) printf '%s\n' "$d" ;;
      seed)    printf '%s\n' "$s" ;;
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
  while IFS='|' read -r __fsrma_k __fsrma_d _; do
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
# those: a <var> named like a local (__fsgm_a_var, __fsgm_i...) assigns the
# local, and the value never reaches the caller. Values
# travel NUL-separated and are read back with read -r -d '', byte for byte; a
# NUL inside a value is dropped by the jq. A key outside the table returns 1
# and a malformed <var>=<key> (no =, or an empty <var>) returns 2, both before
# any jq, by flow_state_resolve_many_arg; a failed read - an absent file, one
# that is not exactly one JSON object (null, trailing text or a second value
# included), a missing sentinel, or a short read - returns 1.
# On any failure nothing is assigned.
#
# The one jq slurps the file and refuses anything but exactly one JSON object
# (trailing text, null, an empty or truncated file all fail), and writes a
# closing sentinel record after every value, only on success. The values are
# read straight from a process substitution, whose exit status bash 3.2 cannot
# read (wait on one needs bash 4.4), so the sentinel is the only proof the jq
# finished: a missing or wrong sentinel, a short read or any record after it
# is a failed read. The loop reads to EOF and never leaves early. This module
# is sourced by the hooks and stays bash 3.2-compatible: no nameref, mapfile
# or declare -A.
flow_state_get_many() {
  local __fsgm_file="$1" __fsgm_arg __fsgm_kd="" __fsgm_a_var __fsgm_a_key __fsgm_a_def \
    __fsgm_i __fsgm_n=0 __fsgm_rows __fsgm_rec __fsgm_seen=0 __fsgm_end=""
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
  while IFS= read -r -d '' __fsgm_rec || [ -n "$__fsgm_rec" ]; do
    if [ "$__fsgm_seen" -lt "$__fsgm_n" ]; then
      __fsgm_vals[__fsgm_seen]="$__fsgm_rec"
    elif [ "$__fsgm_seen" -eq "$__fsgm_n" ]; then
      __fsgm_end="$__fsgm_rec"
    fi
    __fsgm_seen=$((__fsgm_seen + 1))
  done < <(jq -sj --arg kd "$__fsgm_kd" \
    'if length != 1 or (.[0] | type) != "object" then error("not one object") else
      .[0] as $o
      | ($kd | split("\n")[] | split("|") as $p
        | ($o[$p[0]] | if . == null then $p[1] else . end | tostring
          | split("\u0000") | join("")), "\u0000"),
        "flow-state-end\u0000" end' \
    "$__fsgm_file")
  [ "$__fsgm_seen" -eq $((__fsgm_n + 1)) ] && [ "$__fsgm_end" = flow-state-end ] || return 1
  for ((__fsgm_i = 0; __fsgm_i < __fsgm_n; __fsgm_i++)); do
    printf -v "${__fsgm_vars[$__fsgm_i]}" '%s' "${__fsgm_vals[$__fsgm_i]}"
  done
}

# flow_state_active <file>: whether <file> names an active flow. An absent
# file means no flow, and so does phase exactly "done": finished work waiting
# for the next init to archive it (ADR-0009). Anything else - an unreadable
# file, or one with no phase - is a running flow.
flow_state_active() {
  [ -f "$1" ] || return 1
  [ "$(flow_state_get "$1" phase 2>/dev/null)" != "done" ]
}
