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

# --- tick and run (#1458) ---------------------------------------------------
#
# One pass of the watcher, and the wrapper around one headless session. Every
# write under a claim ends in autopilot_release, as above.

# The six labels a tick ensures, one `name|colour|description` each.
AUTOPILOT_LABELS=(
  "orch:spec|1d76db|Autopilot flow: spec phase next"
  "orch:implement|0e8a16|Autopilot flow: implement phase next"
  "orch:review|5319e7|Autopilot flow: review phase next"
  "orch:done|c2e0c6|Autopilot flow: done"
  "orch:running|fbca04|Autopilot session running"
  "needs-human|d93f0b|Waiting on the human"
)

# Claude Code's usage-limit message, as grep -Ei reads it: the one pattern for
# it. The part after a `|`, when the message has one, is the reset time as
# epoch seconds.
AUTOPILOT_LIMIT_PATTERN='usage limit reached(\|[0-9]+)?'

# autopilot_dir <main-root>: where a clone's autopilot files live - the run
# pidfiles, the session logs and the limit file - under its main checkout.
autopilot_dir() { printf '%s/%s/autopilot\n' "$1" "$ORCH_DIR_NAME"; }

# autopilot_pid_alive <pid>: whether a process of that pid is running.
autopilot_pid_alive() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && { kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1; }
}

# autopilot_epoch_iso <epoch>: epoch seconds as a UTC timestamp, GNU or BSD date.
autopilot_epoch_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# autopilot_self: the absolute path of this orch.sh.
autopilot_self() { printf '%s/orch.sh\n' "$(cd "$ORCH_SCRIPTS" && pwd)"; }

# autopilot_orch_in <dir> <orch.sh args>...: runs orch.sh itself in <dir>,
# stdout dropped and stderr left for the caller's capture.
autopilot_orch_in() {
  local dir="$1"
  shift
  cd "$dir" && "$(autopilot_self)" "$@" >/dev/null
}

# autopilot_labels_ensure: the six labels exist with their colour and
# description. A failed upsert dies naming the label, stopping the tick.
autopilot_labels_ensure() {
  local entry name colour description gh_err
  for entry in "${AUTOPILOT_LABELS[@]}"; do
    IFS='|' read -r name colour description <<<"$entry"
    capture_err gh_err adapter_label_upsert "$name" "$colour" "$description" ||
      die "could not upsert the label $name: $(gh_reason "$gh_err") - the tick stops"
  done
}

# autopilot_claims_read <var>: the claims on origin, adapter_claim_list's
# lines, into <var>. Dies, naming the failure, where they cannot be read.
autopilot_claims_read() {
  local gh_err claims_text
  capture claims_text gh_err adapter_claim_list || die "could not list the claims on origin: $(gh_reason "$gh_err")"
  printf -v "$1" '%s' "$claims_text"
}

# autopilot_stop <issue> <refusal|failure> <phase> <detail>: ends a phase that
# will not run, or did not finish: adds needs-human, comments - the comment
# names the phase and <detail> - then releases the claim, last.
autopilot_stop() {
  local issue="$1" kind="$2" phase="$3" detail="$4" body gh_err
  capture_err gh_err adapter_issue_relabel "$issue" --add "$AUTOPILOT_HUMAN_LABEL" ||
    autopilot_chain_die "" "$issue" "add $AUTOPILOT_HUMAN_LABEL" "$gh_err"
  body="$(mktemp)" || die "could not create a temp file for the $kind comment"
  case "$kind" in
    refusal) printf 'Autopilot refused to run the %s phase: %s\n\nThe issue is labelled %s. Remove the label once this is settled and the watcher picks the phase up again.\n' \
      "$phase" "$detail" "$AUTOPILOT_HUMAN_LABEL" >"$body" ;;
    *) printf 'Autopilot failed in the %s phase: %s\n\nThe issue is labelled %s; nothing is retried automatically. Remove the label to have the watcher start the phase again.\n' \
      "$phase" "$detail" "$AUTOPILOT_HUMAN_LABEL" >"$body" ;;
  esac
  capture_err gh_err adapter_issue_comment "$issue" "$body" || {
    rm -f "$body"
    autopilot_chain_die "added $AUTOPILOT_HUMAN_LABEL" "$issue" "post the $kind comment" "$gh_err"
  }
  rm -f "$body"
  autopilot_release "$issue" "added $AUTOPILOT_HUMAN_LABEL, posted the $kind comment"
}

# autopilot_find_side_checkout <issue>: prints the path of the side checkout
# whose marker records <issue>; returns 1 when there is none.
autopilot_find_side_checkout() {
  local list kind _flow _branch path
  list="$(checkouts)" || return 1
  while read -r kind _flow _branch path; do
    [ "$kind" = side ] || continue
    if [ "$(side_checkout_issue "$path" 2>/dev/null)" = "$1" ]; then printf '%s\n' "$path"; return 0; fi
  done <<<"$list"
  return 1
}

# autopilot_minimal_plan <file>: the plan a hand-labelled issue gets: the repo
# defaults, a Decision saying the issue is reviewed as it stands, and None
# elsewhere.
autopilot_minimal_plan() {
  local heading rounds budget
  autopilot_setting rounds; rounds="$AUTOPILOT_VALUE"
  autopilot_setting budget; budget="$AUTOPILOT_VALUE"
  {
    while IFS= read -r heading; do
      printf '%s\n\n' "$heading"
      case "$heading" in
        '## Decisions') printf 'This issue was adopted to be reviewed as it stands: no spec was written for it.\n\n' ;;
        *) printf 'None\n\n' ;;
      esac
    done <<<"$(handoff_required 01-plan.md)"
    printf '## Autopilot\n\nRounds: %s\nBudget: %s\n' "$rounds" "$budget"
  } >"$1"
}

# autopilot_post_minimal_plan <issue>: posts the minimal plan comment when the
# issue has no plan comment. Non-zero, the reason on stderr, where a read or
# the post fails.
autopilot_post_minimal_plan() {
  local issue="$1" file
  file="$(mktemp)" || { echo "could not create a temp file" >&2; return 1; }
  if handoff_comment_fetch "$issue" 01-plan "$file"; then rm -f "$file"; return 0; fi
  autopilot_minimal_plan "$file"
  handoff_check "$file" "" 01-plan.md autopilot >&2 || { rm -f "$file"; echo "the minimal plan does not validate" >&2; return 1; }
  handoff_comment_post "$issue" 01-plan "$file" || { rm -f "$file"; return 1; }
  rm -f "$file"
}

# autopilot_spawn_run <issue>: starts `autopilot run <issue>` detached, from
# the main checkout. ORCH_AUTOPILOT_FOREGROUND=1, set by tests, waits for it.
autopilot_spawn_run() {
  if [ "${ORCH_AUTOPILOT_FOREGROUND:-}" = 1 ]; then
    "$(autopilot_self)" autopilot run "$1" >/dev/null 2>&1 || true
  else
    ( nohup "$(autopilot_self)" autopilot run "$1" >/dev/null 2>&1 </dev/null & )
  fi
}

# autopilot_pickup <issue> <phase>: steps 2 to 5 of a tick for a claimed issue.
# A refusal or a failed write ends in autopilot_stop and returns 0: the claim is
# released, the tick goes on.
autopilot_pickup() {
  local issue="$1" phase="$2" side slug title labels gh_err recorded state redo
  side="$(autopilot_find_side_checkout "$issue")" || side=""
  if [ -z "$side" ]; then
    # labels is the read's throwaway half.
    issue_title_labels_read "$issue" title labels gh_err || {
      autopilot_stop "$issue" failure "$phase" "step side-checkout add failed: could not read the issue's title: $(gh_reason "$gh_err")"
      return 0
    }
    slug="$(normalize_slug "$issue-$title")"
    capture side gh_err cmd_side_checkout_add "$slug" --issue "$issue" || {
      autopilot_stop "$issue" failure "$phase" "step side-checkout add failed: $(gh_reason "$gh_err")"
      return 0
    }
  fi
  slug="$(basename "$side")"
  if ! checkout_has_flow "$side"; then
    capture_err gh_err autopilot_orch_in "$side" init "$slug" --issue "$issue" || {
      autopilot_stop "$issue" failure "$phase" "step init failed: $(gh_reason "$gh_err")"
      return 0
    }
  fi
  capture_err gh_err autopilot_post_minimal_plan "$issue" || {
    autopilot_stop "$issue" failure "$phase" "step minimal plan comment failed: $(gh_reason "$gh_err")"
    return 0
  }
  state="$(flow_state_file "$side")"
  recorded="$(state_get_in "$state" phase)" || {
    autopilot_stop "$issue" failure "$phase" "step reading the recorded phase failed"
    return 0
  }
  if [ "$recorded" != "$phase" ]; then
    case "$phase:$recorded" in
      implement:review) redo=review ;;
      spec:implement) redo=spec ;;
      *) autopilot_stop "$issue" refusal "$phase" "the issue is labelled $(autopilot_phase_label "$phase"), but its side checkout last moved to phase $recorded - only a step back from review to implement or from implement to spec is a redo"
         return 0 ;;
    esac
    ORCH_AUTOPILOT=1 capture_err gh_err autopilot_orch_in "$side" redo "$redo" || {
      autopilot_stop "$issue" refusal "$phase" "redo $redo refused: $(gh_reason "$gh_err")"
      return 0
    }
  fi
  capture_err gh_err adapter_issue_relabel "$issue" --add "$AUTOPILOT_RUNNING_LABEL" || {
    autopilot_stop "$issue" failure "$phase" "step adding $AUTOPILOT_RUNNING_LABEL failed: $(gh_reason "$gh_err")"
    return 0
  }
  autopilot_spawn_run "$issue"
}

# autopilot_cleanup_stale <main>: every claim of this host whose process is
# gone is a failure: needs-human, a comment, then the claim released. The pid
# is the run pidfile's, or - with none - the claim's own tick pid. Other hosts'
# claims are never touched.
autopilot_cleanup_stale() {
  local main="$1" claims issue host pid phase _started pidfile
  autopilot_claims_read claims
  while IFS=$'\t' read -r issue host pid phase _started; do
    [ -n "$issue" ] && [ "$host" = "$(hostname)" ] || continue
    pidfile="$(autopilot_dir "$main")/run/$issue.pid"
    [ ! -f "$pidfile" ] || pid="$(cat "$pidfile")"
    ! autopilot_pid_alive "$pid" || continue
    autopilot_stop "$issue" failure "$phase" "the session's process (pid ${pid:-unknown}) is gone and the claim was never released - no exit code or log to name"
    rm -f "$pidfile"
  done <<<"$claims"
}

# autopilot_limit_paused <main>: whether a usage limit pauses pickup. While the
# limit file's reset time is in the future it prints one line naming it and
# returns 0; once it has passed, the file is removed and it returns 1.
autopilot_limit_paused() {
  local file reset epoch
  file="$(autopilot_dir "$1")/limit"
  [ -f "$file" ] || return 1
  reset="$(cat "$file")"
  epoch="$(autopilot_iso_epoch "$reset")" || epoch=0
  if [ "$epoch" -gt "$(date +%s)" ]; then
    note "usage limit: no issue is picked up until $reset"
    return 0
  fi
  rm -f "$file"
  return 1
}

# autopilot_candidates: the open issues carrying a phase label other than
# orch:done, oldest first, one number per line.
autopilot_candidates() {
  local phase out gh_err all=""
  for phase in $PHASES; do
    [ "$phase" != "done" ] || continue
    capture out gh_err adapter_issues_labelled "$(autopilot_phase_label "$phase")" ||
      die "could not list the issues labelled $(autopilot_phase_label "$phase"): $(gh_reason "$gh_err")"
    all="$all$out"$'\n'
  done
  printf '%s' "$all" | grep -v '^$' | sort -nu || true
}

# autopilot_tick: one pass - labels, stale claims, then pickup (see the spec's
# One tick). A claim create that fails for a reason other than a lost race
# stops the tick, naming it.
autopilot_tick() {
  local main cap claims count issue state labels gh_err phase p rc candidates
  autopilot_setting cap; cap="$AUTOPILOT_VALUE"
  main="$(main_checkout)" || die "could not read the checkouts - git worktree list failed"
  cd "$main" || die "could not enter the main checkout $main"
  autopilot_labels_ensure
  autopilot_cleanup_stale "$main"
  if autopilot_limit_paused "$main"; then return 0; fi
  autopilot_claims_read claims
  count="$(grep -c . <<<"$claims" || true)"
  candidates="$(autopilot_candidates)"
  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    [ "$count" -lt "$cap" ] || break
    issue_state_labels_read "$issue" state labels gh_err ||
      die "could not read issue #$issue: $(gh_reason "$gh_err")"
    [ "$state" = OPEN ] || continue
    ! list_has "$labels" "$AUTOPILOT_RUNNING_LABEL" || continue
    ! list_has "$labels" "$AUTOPILOT_HUMAN_LABEL" || continue
    phase=""
    for p in $PHASES; do
      [ "$p" != "done" ] || continue
      if list_has "$labels" "$(autopilot_phase_label "$p")"; then phase="$p"; break; fi
    done
    [ -n "$phase" ] || continue
    rc=0
    capture_err gh_err adapter_claim_create "$issue" "$phase" "$$" || rc=$?
    case "$rc" in
      0) ;;
      2) continue ;;
      *) die "could not claim issue #$issue: $(gh_reason "$gh_err") - the tick stops" ;;
    esac
    count=$((count + 1))
    autopilot_pickup "$issue" "$phase"
  done <<<"$candidates"
}

# autopilot_limit_reset <log>: returns 0 when <log> holds Claude Code's
# usage-limit message, printing its reset time as a UTC timestamp when the
# message gives one; 1 when it does not.
autopilot_limit_reset() {
  local hit
  hit="$(grep -Eio "$AUTOPILOT_LIMIT_PATTERN" "$1" | tail -n 1)" || true
  [ -n "$hit" ] || return 1
  case "$hit" in
    *'|'*) autopilot_epoch_iso "${hit##*|}" ;;
  esac
  return 0
}

# autopilot_run <issue>: the session wrapper a tick starts: runs the headless
# session in the issue's side checkout, its output in the session log, and
# when the claim is still held at its exit, runs the failure handling. A
# session that released its claim is left alone whatever its exit code.
autopilot_run() {
  local issue="$1" main side phase mode launcher dir log pidfile prompt rc=0 claims held=0 reset detail line
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  autopilot_setting permission-mode; mode="$AUTOPILOT_VALUE"
  [ "$AUTOPILOT_SOURCE" != unset ] || die "orchestrator.autopilot.permission-mode is not set"
  main="$(main_checkout)" || die "could not read the checkouts - git worktree list failed"
  side="$(autopilot_find_side_checkout "$issue")" || die "no side checkout records issue #$issue"
  phase="$(state_get_in "$(flow_state_file "$side")" phase)" || die "could not read the recorded phase of $side"
  dir="$(autopilot_dir "$main")"
  mkdir -p "$dir/run" "$dir/logs" || die "could not create $dir"
  pidfile="$dir/run/$issue.pid"
  printf '%s\n' "$$" >"$pidfile"
  # shellcheck disable=SC2064
  trap "rm -f '$pidfile'" EXIT
  log="$dir/logs/$issue-$phase-$(date -u +%Y%m%dT%H%M%SZ).log"
  launcher="${ORCH_AUTOPILOT_LAUNCHER:-claude}"
  prompt="Run the orchestrator:orch-flow skill's Next phase in this checkout: do the phase it names, and stop when the phase is finished."
  ( cd "$side" && ORCH_AUTOPILOT=1 "$launcher" -p "$prompt" --permission-mode "$mode" ) >"$log" 2>&1 || rc=$?
  autopilot_claims_read claims
  while IFS=$'\t' read -r line _; do
    [ "$line" != "$issue" ] || held=1
  done <<<"$claims"
  if [ "$held" = 0 ]; then
    note "autopilot run: issue #$issue's session exited $rc with its claim released"
    return 0
  fi
  detail="the session exited with code $rc; log: $log"
  if reset="$(autopilot_limit_reset "$log")"; then
    [ -n "$reset" ] || reset="$(autopilot_epoch_iso "$(( $(date +%s) + 3600 ))")"
    printf '%s\n' "$reset" >"$dir/limit"
    detail="the session stopped on a usage limit (resets $reset) and exited with code $rc; log: $log"
  fi
  autopilot_stop "$issue" failure "$phase" "$detail"
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
    tick)
      [ $# -eq 0 ] || die "usage: orch.sh autopilot tick"
      autopilot_gate
      autopilot_tick
      ;;
    run)
      [ $# -eq 1 ] || die "usage: orch.sh autopilot run <issue>"
      autopilot_run "$1"
      ;;
    ask|answer)
      [ $# -eq 2 ] || die "usage: orch.sh autopilot $op <phase> <file>"
      "autopilot_$op" "$1" "$2"
      ;;
    *) die "unknown autopilot op: ${op:-<none>} (want show|active|rounds|budget|start|tick|run|ask|answer)" ;;
  esac
}
