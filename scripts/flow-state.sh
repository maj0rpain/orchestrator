# shellcheck shell=bash
# flow-state.sh - the Flow state module: the one owner of the state format of
# a checkout's flow, .orchestrator/state.json - its keys, their defaults,
# reading, the coercing write and the active-flow check - sourced by orch.sh
# and by hook-common.sh.
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
# - Predicates (flow_state_readable, flow_state_active): 0 or 1 is the answer,
#   never an error; jq is silenced, so an absent or unparseable file prints
#   nothing.
# - flow_state_get on a file jq cannot parse: jq's own error and status pass
#   through unchanged.
# - Writers (flow_state_write, flow_state_write_string): non-zero, the state
#   file untouched and no temp file left, when the write fails; an absent
#   state file is a failed write, and nothing is created.
#
# Every function carries the flow_state_ prefix but state_rows and now, so
# none collides with orch.sh's wrappers, which keep today's names. It stays
# bash-3.2 compatible (no namerefs). Its tests: the "Flow state module"
# section of scripts/test/orch/state.sh.

# The directory under a checkout's root holding its flow state. orch.sh marks
# it readonly after sourcing this file.
ORCH_DIR_NAME=".orchestrator"

# Every flow state key, one row each, in the order init seeds them into
# state.json: key|default|seed|owner. state_get, state set and init all read
# it, so adding a key is one row; an arg row also needs its value in cmd_init's
# case, and init dies naming the key without it. state_rows is its one reader:
# lines starting with # are comments, and blank lines are skipped.
#
# default: what state_get returns for a null or missing value. A flow started
#   by an older release lacks keys a fresh one seeds; each reads back as its
#   default. The default applies only to a null or missing value, never to a
#   stored false (jq's `//` would treat false like null).
# seed: the JSON literal init writes, or arg where init supplies the value at
#   run time; the value comes from cmd_init's case.
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
# Seeded here rather than at the review phase because its allowance belongs to
# the flow: one per flow, spent or not, so that one refilled each iteration
# could not become an infinite retry loop.
flake_rerun_used|false|false|-
redo_count|0|0|redo review counts it
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
flow_state_file() { printf '%s/%s/state.json\n' "$1" "$ORCH_DIR_NAME"; }

# flow_state_readable <file>: true when <file> parses as a JSON object.
flow_state_readable() {
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

# flow_state_put <file> <key> <json>: the one state-file write, private to the
# writers below. It stamps updated before it sets the key, so a write of
# updated itself sticks. The temp file sits beside the state file and replaces
# it only when jq succeeds; on any failure it is removed and the status
# returned. Every command runs in a conditional, so a caller's set -e cannot
# stop it before the cleanup.
flow_state_put() {
  local tmp rc
  [ -f "$1" ] || return 1
  tmp="$(mktemp "$1.XXXXXX")" || return
  jq --arg k "$2" --argjson v "$3" --arg now "$(now)" \
    '.updated = $now | .[$k] = $v' "$1" >"$tmp" \
    && mv "$tmp" "$1" \
    || { rc=$?; rm -f "$tmp"; return "$rc"; }
}

# flow_state_write <file> <key> <value>: the coercing writer. "null" stores a
# JSON null, "true" and "false" a boolean, and an all-digit value a number, so
# a key cleared, flagged or counted here reads back the way init seeded it.
# Every other value is stored as a string. Keys are not checked against the
# table: only lookups are.
flow_state_write() {
  case "$3" in
    null|true|false) flow_state_put "$1" "$2" "$3" ;;
    *[!0-9]*|"") flow_state_write_string "$1" "$2" "$3" ;;
    *) flow_state_put "$1" "$2" "$(jq -n --arg v "$3" '$v | tonumber')" ;;
  esac
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
