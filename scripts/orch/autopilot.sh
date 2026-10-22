# shellcheck shell=bash
# autopilot.sh - orch.sh's autopilot command: the clone-scoped autopilot
# settings, the autopilot-session check and the host gate the watcher's verbs
# share. Its tests: scripts/test/orch/autopilot.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The permission modes a headless session may run with, and the numeric
# settings' defaults. Each lives here alone, so set and show validate against
# one list.
AUTOPILOT_MODES="default acceptEdits plan dontAsk bypassPermissions"
AUTOPILOT_CAP_DEFAULT=3
AUTOPILOT_ROUNDS_DEFAULT=2
AUTOPILOT_BUDGET_DEFAULT=3

# autopilot_lookup <name> <value-var> <source-var>: the key
# orchestrator.autopilot.<name> - local config, then global config - into
# <value-var>, and where it came from (local, global or unset) into
# <source-var>. Never validates.
autopilot_lookup() {
  local lookup_key="orchestrator.autopilot.$1" lookup_value
  if lookup_value="$(git config --local --get "$lookup_key" 2>/dev/null)"; then
    printf -v "$2" '%s' "$lookup_value"; printf -v "$3" local
  elif lookup_value="$(git config --global --get "$lookup_key" 2>/dev/null)"; then
    printf -v "$2" '%s' "$lookup_value"; printf -v "$3" global
  else
    printf -v "$2" '%s' ""; printf -v "$3" unset
  fi
}

# autopilot_setting <name>: the effective, validated value of
# orchestrator.autopilot.<name> into AUTOPILOT_VALUE, its source into
# AUTOPILOT_SOURCE (local, global, default or unset). The permission mode and
# the handle fall back to nothing and the repo's owner; the three integers to
# their defaults. Dies naming key and value when a value is out of range.
# The handle's owner is resolved only when the handle is needed.
autopilot_setting() {
  local name="$1" key="orchestrator.autopilot.$1" def=""
  autopilot_lookup "$name" AUTOPILOT_VALUE AUTOPILOT_SOURCE
  case "$name" in
    permission-mode)
      [ "$AUTOPILOT_SOURCE" != unset ] || return 0
      list_has "${AUTOPILOT_MODES// /$'\n'}" "$AUTOPILOT_VALUE" ||
        die "$key is $AUTOPILOT_VALUE - not a permission mode (want ${AUTOPILOT_MODES// /|})" ;;
    handle)
      [ "$AUTOPILOT_SOURCE" = unset ] || return 0
      AUTOPILOT_SOURCE=default
      if repo_resolve; then
        AUTOPILOT_VALUE="$(repo_owner_name "$REPO_NAME")"; AUTOPILOT_VALUE="${AUTOPILOT_VALUE%%/*}"
      else
        die "$REPO_REMEDY (the handle defaults to the repo's owner; or git config $key <handle>)"
      fi ;;
    cap|rounds|budget)
      case "$name" in
        cap) def="$AUTOPILOT_CAP_DEFAULT" ;;
        rounds) def="$AUTOPILOT_ROUNDS_DEFAULT" ;;
        budget) def="$AUTOPILOT_BUDGET_DEFAULT" ;;
      esac
      if [ "$AUTOPILOT_SOURCE" = unset ]; then AUTOPILOT_VALUE="$def"; AUTOPILOT_SOURCE=default; fi
      [[ "$AUTOPILOT_VALUE" =~ ^[0-9]+$ ]] && [ "$((10#$AUTOPILOT_VALUE))" -gt 0 ] ||
        die "$key is $AUTOPILOT_VALUE - it must be a positive integer (git config $key <n>)"
      AUTOPILOT_VALUE="$((10#$AUTOPILOT_VALUE))" ;;
  esac
}

# autopilot_show: one line per setting, key, value and source, as agent show
# prints them. A setting with no value prints "(none)". Dies on a value out of
# range, naming key and value.
autopilot_show() {
  local name
  for name in permission-mode cap handle rounds budget; do
    autopilot_setting "$name"
    printf 'orchestrator.autopilot.%s %s (%s)\n' "$name" "${AUTOPILOT_VALUE:-(none)}" "$AUTOPILOT_SOURCE"
  done
}

# autopilot_active: whether this is an autopilot session - the one reader of
# ORCH_AUTOPILOT, so no skill reads the variable itself.
autopilot_active() { [ "${ORCH_AUTOPILOT:-}" = 1 ]; }

# autopilot_gate: the host and settings gate tick and watch start with. Dies
# on a host other than Claude Code (Junie, or no claude on PATH), then with no
# permission mode set, naming the key.
autopilot_gate() {
  if [ "$(host_detect)" = junie ] || ! command -v claude >/dev/null 2>&1; then
    die "autopilot is Claude Code only (no headless-session fallback on this host; see docs/host-capabilities.md)"
  fi
  autopilot_setting permission-mode
  [ "$AUTOPILOT_SOURCE" != unset ] ||
    die "orchestrator.autopilot.permission-mode is not set - choose how headless sessions run (git config orchestrator.autopilot.permission-mode <${AUTOPILOT_MODES// /|}>)"
}

# autopilot_phase_label <phase>: the label that records an autopilot flow's
# phase on its issue, `orch:<phase>` - the label is the flow's phase record.
autopilot_phase_label() { printf 'orch:%s\n' "$1"; }

# autopilot_block_values <file> <key>: the value of each `<key>: <value>` line
# in <file>'s `## Autopilot` section, trimmed, one per line.
autopilot_block_values() {
  section_body "$1" '## Autopilot' | sed -n "s/^$2:[[:space:]]*\\(.*[^[:space:]]\\)[[:space:]]*\$/\\1/p"
}

# autopilot_block_report <file>: the plan's `## Autopilot` block, in
# handoff_report's lines - `ok ## Autopilot`, or one FAIL line per problem -
# and non-zero when any failed. The block is `Rounds` and `Budget`, each one
# line holding a whole number of 1 or more.
autopilot_block_report() {
  local file="$1" key values failed=0
  if ! grep -qxF '## Autopilot' "$file"; then
    printf 'FAIL missing section: ## Autopilot\n'
    return 1
  fi
  for key in Rounds Budget; do
    values="$(autopilot_block_values "$file" "$key")"
    if [ -z "$values" ]; then
      printf 'FAIL ## Autopilot has no %s line (want "%s: <n>")\n' "$key" "$key"; failed=1
    elif [ "$(wc -l <<<"$values" | tr -d ' ')" -gt 1 ]; then
      printf 'FAIL ## Autopilot repeats its %s line\n' "$key"; failed=1
    elif ! [[ "$values" =~ ^[0-9]+$ ]] || [ "$((10#$values))" -lt 1 ]; then
      printf 'FAIL ## Autopilot %s is %s - it must be a whole number of 1 or more\n' "$key" "$values"; failed=1
    fi
  done
  [ "$failed" = 1 ] || printf 'ok ## Autopilot\n'
  return "$failed"
}

# autopilot_plan_value <Rounds|Budget>: the value of that line of the `##
# Autopilot` block of the flow's issue's newest plan comment, printed as a plain
# integer. Dies when the issue has no plan handoff or its block has no valid
# value.
autopilot_plan_value() {
  local issue file value
  require_issue issue
  file="$(mktemp)" || die "could not create a temp file for the plan comment"
  handoff_comment_fetch "$issue" 01-plan "$file" || { rm -f "$file"; die "issue #$issue has no 01-plan handoff comment"; }
  value="$(autopilot_block_values "$file" "$1")"
  rm -f "$file"
  [[ "$value" =~ ^[0-9]+$ ]] && [ "$((10#$value))" -ge 1 ] ||
    die "issue #$issue's plan comment has no valid ## Autopilot $1 line"
  printf '%s\n' "$((10#$value))"
}

# autopilot_start <issue> <plan-file>: the planning close's last step. Before
# any write it refuses an issue without the ready-for-agent label (checked as
# issue ready checks it) and one that already carries a phase label, then
# validates the plan, ## Autopilot block included. Then it posts the plan
# comment and, last, adds the first phase's label - so a failure after the
# comment leaves the issue unlabelled, never picked up. A re-run on an
# unlabelled issue posts a newer plan comment, which supersedes the earlier.
autopilot_start() {
  # state is the read's throwaway half: only the labels are checked here.
  # shellcheck disable=SC2034
  local issue="$1" file="$2" ready state labels gh_err phase label first
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  [ -f "$file" ] || die "plan file not found: $file"
  ready="$(triage_label_for ready-for-agent)"
  issue_state_labels_read "$issue" state labels gh_err \
    || gh_die "read issue #$issue" "$gh_err"
  list_has "$labels" "$ready" ||
    die "issue #$issue does not carry the '$ready' label - an autopilot flow starts from a ready issue"
  for phase in $PHASES; do
    label="$(autopilot_phase_label "$phase")"
    ! list_has "$labels" "$label" ||
      die "issue #$issue already carries the phase label $label - it is already an autopilot flow"
  done
  handoff_check "$file" "" 01-plan.md autopilot || die "plan $file is not valid - nothing posted"
  handoff_comment_post "$issue" 01-plan "$file"
  first="$(autopilot_phase_label "${PHASES%% *}")"
  capture_err gh_err adapter_issue_relabel "$issue" --add "$first" ||
    die "posted the 01-plan comment on issue #$issue but adding $first failed: $(gh_reason "$gh_err") - the issue is unlabelled, so no watcher picks it up; re-run autopilot start"
}

# autopilot_iso_epoch <YYYY-MM-DDTHH:MM:SSZ>: the UTC timestamp as epoch
# seconds, GNU or BSD date; non-zero for a value neither reads.
autopilot_iso_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

# --- phase moves and the claim's release (#1457) ---------------------------
#
# Every chain of writes an autopilot session makes under its claim ends in the
# release, which deletes orch:running and then, last, the claim ref: a chain
# that fails partway leaves the claim held, and dies naming the writes that
# landed, so the next tick cleans it up as a failure.

AUTOPILOT_RUNNING_LABEL="orch:running"
AUTOPILOT_HUMAN_LABEL="needs-human"

# autopilot_chain_die <landed> <issue> <what> <gh-stderr>: dies for a write of
# a chain that failed, naming the reason and the writes that landed before it.
autopilot_chain_die() {
  die "could not $3 on issue #$2: $(gh_reason "$4") - writes that landed: ${1:-none}; the claim stays held"
}

# autopilot_move_label <issue> <phase> <landed>: <issue>'s phase label made
# the one for <phase> - the other phase labels removed - in one edit.
autopilot_move_label() {
  # state is the read's throwaway half.
  # shellcheck disable=SC2034
  local issue="$1" phase="$2" landed="$3" state labels gh_err p label args=()
  issue_state_labels_read "$issue" state labels gh_err ||
    autopilot_chain_die "$landed" "$issue" "read the labels" "$gh_err"
  for p in $PHASES; do
    label="$(autopilot_phase_label "$p")"
    [ "$p" = "$phase" ] || ! list_has "$labels" "$label" || args+=(--remove "$label")
  done
  capture_err gh_err adapter_issue_relabel "$issue" --add "$(autopilot_phase_label "$phase")" ${args[@]+"${args[@]}"} ||
    autopilot_chain_die "$landed" "$issue" "move the phase label to $(autopilot_phase_label "$phase")" "$gh_err"
}

# autopilot_release <issue> <landed>: finishes a phase - deletes orch:running,
# then the claim ref, last. <landed> names the writes already made, for the
# message of a failure.
autopilot_release() {
  local issue="$1" landed="$2" gh_err
  capture_err gh_err adapter_issue_relabel "$issue" --remove "$AUTOPILOT_RUNNING_LABEL" ||
    autopilot_chain_die "$landed" "$issue" "remove $AUTOPILOT_RUNNING_LABEL" "$gh_err"
  landed="${landed:+$landed, }removed $AUTOPILOT_RUNNING_LABEL"
  capture_err gh_err adapter_claim_delete "$issue" ||
    autopilot_chain_die "$landed" "$issue" "delete the claim ref" "$gh_err"
}

# autopilot_question_marker <phase>: the first line of a question comment.
autopilot_question_marker() { printf '<!-- orch:question %s -->\n' "$1"; }

# autopilot_phase_arg <phase>: dies unless <phase> is a phase a question can be
# asked in - a flow phase other than done.
autopilot_phase_arg() {
  case " $PHASES " in *" $1 "*) ;; *) die "not a flow phase: $1 (want ${PHASES// /|})" ;; esac
  [ "$1" != "done" ] || die "a done flow asks no question"
}

# autopilot_ask <phase> <file>: posts <file> as <phase>'s question comment, the
# configured handle @mentioned, adds needs-human, then releases the claim.
autopilot_ask() {
  local phase="$1" file="$2" issue body gh_err landed
  autopilot_phase_arg "$phase"
  [ -f "$file" ] || die "question file not found: $file"
  require_state
  require_issue issue
  autopilot_setting handle
  body="$(mktemp)" || die "could not create a temp file for the question comment"
  { autopilot_question_marker "$phase"; printf '@%s\n\n' "$AUTOPILOT_VALUE"; cat "$file"; } >"$body"
  capture_err gh_err adapter_issue_comment "$issue" "$body" || { rm -f "$body"; gh_die "post the $phase question on issue #$issue" "$gh_err"; }
  rm -f "$body"
  landed="posted the $phase question comment"
  capture_err gh_err adapter_issue_relabel "$issue" --add "$AUTOPILOT_HUMAN_LABEL" ||
    autopilot_chain_die "$landed" "$issue" "add $AUTOPILOT_HUMAN_LABEL" "$gh_err"
  autopilot_release "$issue" "$landed, added $AUTOPILOT_HUMAN_LABEL"
}

# autopilot_answer <phase> <file>: writes <phase>'s newest question comment,
# marker stripped, and every comment after it to <file>, each later one after a
# `---` line. Dies, writing nothing, when there is no question or no comment
# follows it - the caller re-asks.
autopilot_answer() {
  local phase="$1" file="$2" issue json out
  autopilot_phase_arg "$phase"
  require_state
  require_issue issue
  gh_or_die --out json "read the comments of issue #$issue" adapter_issue_json "$issue"
  out="$(jq -j --arg m "$(autopilot_question_marker "$phase")" '
    (.comments | map(.body | split("\n")[0] | rtrimstr("\r") == ($m | rtrimstr("\n"))) | rindex(true)) as $q
    | if $q == null then "noq" elif $q == (.comments | length) - 1 then "noreply"
      else (.comments[$q:] | map(.body) | .[0] |= (split("\n")[1:] | join("\n")) | join("\n---\n")) end' <<<"$json")" ||
    die "could not read issue #$issue's comments"
  case "$out" in
    noq) die "issue #$issue has no $phase question comment" ;;
    noreply) die "no reply to the $phase question on issue #$issue yet" ;;
  esac
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$out" >"$file"
}

cmd_autopilot() {
  local op="${1:-}"
  shift || true
  case "$op" in
    show)
      [ $# -eq 0 ] || die "usage: orch.sh autopilot show"
      autopilot_show
      ;;
    active)
      [ $# -eq 0 ] || die "usage: orch.sh autopilot active"
      autopilot_active
      ;;
    rounds|budget)
      [ $# -eq 0 ] || die "usage: orch.sh autopilot $op"
      case "$op" in rounds) autopilot_plan_value Rounds ;; budget) autopilot_plan_value Budget ;; esac
      ;;
    start)
      [ $# -eq 2 ] || die "usage: orch.sh autopilot start <issue> <plan-file>"
      autopilot_start "$1" "$2"
      ;;
    ask|answer)
      [ $# -eq 2 ] || die "usage: orch.sh autopilot $op <phase> <file>"
      "autopilot_$op" "$1" "$2"
      ;;
    *) die "unknown autopilot op: ${op:-<none>} (want show|active|rounds|budget|start|ask|answer)" ;;
  esac
}
