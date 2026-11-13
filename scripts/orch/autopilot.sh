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
AUTOPILOT_GITHUB_RESERVE_DEFAULT=20

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
# the handle fall back to nothing and the repo's owner; the four integers
# (github-reserve ranges 0-99) to their defaults; the model and effort stay
# unset, checked against the agent setting's Claude Code lists. Dies naming key
# and value when a value is out of range.
# The handle's owner is resolved only when the handle is needed.
autopilot_setting() {
  local name="$1" key="orchestrator.autopilot.$1" def="" owner_name
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
        owner_name="$(repo_owner_name "$REPO_NAME")"; AUTOPILOT_VALUE="${owner_name%%/*}"
      else
        die "$REPO_REMEDY (the handle defaults to the repo's owner; or git config $key <handle>)"
      fi ;;
    model|effort)
      [ "$AUTOPILOT_SOURCE" != unset ] || return 0
      agent_allowed "$name" "$AUTOPILOT_VALUE" ||
        die "$key is $AUTOPILOT_VALUE - not an allowed $name (want $(agent_values "$name"))" ;;
    auto-sync)
      if [ "$AUTOPILOT_SOURCE" = unset ]; then AUTOPILOT_VALUE=true; AUTOPILOT_SOURCE=default; fi
      case "$AUTOPILOT_VALUE" in
        true|false) ;;
        *) die "$key is $AUTOPILOT_VALUE - it must be true or false (git config $key true|false)" ;;
      esac ;;
    github-reserve)
      if [ "$AUTOPILOT_SOURCE" = unset ]; then AUTOPILOT_VALUE="$AUTOPILOT_GITHUB_RESERVE_DEFAULT"; AUTOPILOT_SOURCE=default; fi
      case "$AUTOPILOT_VALUE" in
        ""|*[!0-9]*) def=bad ;;
        *) [ "$((10#$AUTOPILOT_VALUE))" -le 99 ] || def=bad ;;
      esac
      [ "$def" != bad ] ||
        die "$key is $AUTOPILOT_VALUE - it must be an integer from 0 to 99 (git config $key <n>)"
      AUTOPILOT_VALUE="$((10#$AUTOPILOT_VALUE))" ;;
    cap|rounds|budget)
      case "$name" in
        cap) def="$AUTOPILOT_CAP_DEFAULT" ;;
        rounds) def="$AUTOPILOT_ROUNDS_DEFAULT" ;;
        budget) def="$AUTOPILOT_BUDGET_DEFAULT" ;;
      esac
      if [ "$AUTOPILOT_SOURCE" = unset ]; then AUTOPILOT_VALUE="$def"; AUTOPILOT_SOURCE=default; fi
      is_positive_int "$AUTOPILOT_VALUE" ||
        die "$key is $AUTOPILOT_VALUE - it must be a positive integer (git config $key <n>)"
      AUTOPILOT_VALUE="$((10#$AUTOPILOT_VALUE))" ;;
  esac
}

# autopilot_show: one line per setting, key, value and source, as agent show
# prints them. A setting with no value prints "(none)". Dies on a value out of
# range, naming key and value.
autopilot_show() {
  local name
  for name in permission-mode cap handle rounds budget model effort auto-sync github-reserve; do
    autopilot_setting "$name"
    printf 'orchestrator.autopilot.%s %s (%s)\n' "$name" "${AUTOPILOT_VALUE:-(none)}" "$AUTOPILOT_SOURCE"
  done
}

# autopilot_active: whether this is an autopilot session - the one reader of
# ORCH_AUTOPILOT, so no skill reads the variable itself.
autopilot_active() { [ "${ORCH_AUTOPILOT:-}" = 1 ]; }

# autopilot_gate: the host and settings gate tick and watch start with. Dies
# on a host other than Claude Code (Junie, or no claude on PATH), then with no
# permission mode set, naming the key, then on a model or effort outside its
# list, before any issue is claimed: a run's own check dies with its output
# discarded.
autopilot_gate() {
  local name
  if [ "$(host_detect)" = junie ] || ! command -v claude >/dev/null 2>&1; then
    die "autopilot is Claude Code only (no headless-session fallback on this host; see docs/host-capabilities.md)"
  fi
  autopilot_mode_require
  for name in model effort; do autopilot_setting "$name"; done
}

# autopilot_mode_require: sets AUTOPILOT_VALUE to the permission mode, dying,
# naming the key and its remedy, when none is set.
autopilot_mode_require() {
  autopilot_setting permission-mode
  [ "$AUTOPILOT_SOURCE" != unset ] ||
    die "orchestrator.autopilot.permission-mode is not set - choose how headless sessions run (git config orchestrator.autopilot.permission-mode <${AUTOPILOT_MODES// /|}>)"
}

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
  if [ "$(section_count "$file" '## Autopilot')" -eq 0 ]; then
    printf 'FAIL missing section: ## Autopilot\n'
    return 1
  fi
  for key in Rounds Budget; do
    values="$(autopilot_block_values "$file" "$key")"
    if [ -z "$values" ]; then
      printf 'FAIL ## Autopilot has no %s line (want "%s: <n>")\n' "$key" "$key"; failed=1
    elif [ "$(wc -l <<<"$values" | tr -d ' ')" -gt 1 ]; then
      printf 'FAIL ## Autopilot repeats its %s line\n' "$key"; failed=1
    elif ! is_positive_int "$values"; then
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
  local issue file value st
  require_issue issue
  file="$(mktemp)" || die "could not create a temp file for the plan comment"
  st=0
  handoff_comment_fetch "$issue" 01-plan "$file" || st=$?
  [ "$st" -eq 0 ] || rm -f "$file"
  handoff_comment_status "$st" "$issue" 01-plan
  value="$(autopilot_block_values "$file" "$1")"
  rm -f "$file"
  is_positive_int "$value" ||
    die "issue #$issue's plan comment has no valid ## Autopilot $1 line"
  printf '%s\n' "$((10#$value))"
}

# autopilot_iso_epoch <YYYY-MM-DDTHH:MM:SSZ>: the UTC timestamp as epoch
# seconds, GNU or BSD date; non-zero for a value neither reads.
autopilot_iso_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

# autopilot_phase_arg <phase> [die-fn]: dies, through die-fn (default die),
# unless <phase> is a phase a question can be asked in - a flow phase other
# than done.
autopilot_phase_arg() {
  local die_fn="${2:-die}"
  word_listed "$PHASES" "$1" || "$die_fn" "not a flow phase: $1 (want ${PHASES// /|})"
  [ "$1" != "done" ] || "$die_fn" "a done flow asks no question"
}

# autopilot_file_text <var> <what> <file>: sets <var> to <file>'s text; dies,
# naming <what>, when <file> is missing or unreadable.
autopilot_file_text() {
  [ -f "$3" ] || die "$2 file not found: $3"
  file_read "$1" "$3" || die "could not read $3"
}

# autopilot_ask <phase> <file>: posts <file> as <phase>'s question comment, the
# configured handle @mentioned, adds needs-human, then releases the claim.
autopilot_ask() {
  local phase="$1" file="$2" text
  autopilot_phase_arg "$phase"
  autopilot_file_text text question "$file"
  standing_ask "$phase" "$text"
}

# autopilot_reenter <phase> <file>: the automatic re-entry of a review loop
# whose stop asks nothing: <file> posted as a re-entry comment, the claim
# released. Only the review phase re-enters, refused before any write.
autopilot_reenter() {
  local phase="$1" file="$2" text issue
  [ "$phase" = review ] || die "only the review phase re-enters automatically, got: $phase"
  autopilot_file_text text re-entry "$file"
  require_state
  require_issue issue
  standing_reenter "$issue" "$phase" "$text"
}

# The three ends of a sync session, each a Standing transition the orch-sync
# skill's autopilot branch calls. The issue comes from flow state, as ask's.

# autopilot_sync_finish: orch:sync removed, the claim released.
autopilot_sync_finish() {
  local issue
  require_state
  require_issue issue
  standing_sync_finish "$issue"
}

# autopilot_sync_dropped <file>: the dropped-intent stop; <file> lists the
# intents the resolver dropped, with a link to the Merge resolutions comment.
# The repo's auto-sync setting picks the comment's what-happens-next wording.
autopilot_sync_dropped() {
  local file="$1" issue text auto_sync
  autopilot_file_text text dropped-intents "$file"
  require_state
  require_issue issue
  # The merge is pushed, so a bad auto-sync value must not kill the stop: the
  # read runs in a subshell, its die line on stderr serves as the warning, and
  # the stop takes false.
  auto_sync="$(autopilot_setting auto-sync && printf %s "$AUTOPILOT_VALUE")" || auto_sync=false
  standing_sync_dropped "$issue" "$text" "$auto_sync"
}

# autopilot_sync_fail <reason>: the failure stop, orch:sync kept.
autopilot_sync_fail() {
  local issue
  [ -n "$1" ] || die "a sync failure needs a reason"
  require_state
  require_issue issue
  standing_stop "$issue" failure "$STANDING_SYNC_PHASE" "$1"
}

# autopilot_answer <phase> <file>: writes <phase>'s newest question comment,
# marker stripped, and every comment after it to <file>, each later one after a
# `---` line. Exits 1, writing nothing, when no reply follows the question, or
# the phase was re-entered automatically (a re-entry comment newer than its
# newest question, or one and no question) - the caller re-asks, or carries on
# - and 2 on any other failure, so a failed read is never taken for no reply.
autopilot_answer() {
  local phase="$1" file="$2" issue out first rest
  autopilot_phase_arg "$phase" die2
  require_state die2
  require_issue issue die2
  if ! timeline_read "$issue"; then
    [ -n "$TIMELINE_REASON" ] || die2 "could not read issue #$issue's comments"
    gh_die --exit 2 "read the comments of issue #$issue" "$TIMELINE_REASON"
  fi
  ! timeline_reentered "$phase" || die "issue #$issue was re-entered automatically in $phase - no reply to read"
  timeline_question "$phase" || die2 "issue #$issue has no $phase question comment"
  timeline_replied "$phase" || die "no reply to the $phase question on issue #$issue yet"
  # The stripped body is read with a sentinel so its trailing newlines survive
  # into the `---` join.
  first="$(timeline_body "$TIMELINE_Q_INDEX"; printf x)"
  first="${first%x}"
  rest="$(timeline_answers "$phase")"
  out="$(printf '%s' "$first$rest")"  # as before, trailing newlines go; the file gets one
  file_write_atomic "$file" "$out"$'\n' 2>/dev/null || die2 "could not write $file"
}

# --- questions, reply and resume (#1571) ------------------------------------
#
# The verbs behind /orchestrator:questions. They hold no flow state: the issue
# comes from the arguments, the repo from the checkout's origin.

# autopilot_resume <issue>: removes needs-human from the issue, and nothing
# else.
autopilot_resume() {
  local issue="$1"
  is_positive_int "$issue" || die "not an issue number: $issue"
  standing_human_guard "$issue"
  standing_resume "$issue" || gh_die "remove $STANDING_HUMAN_LABEL from issue #$issue" "$STANDING_REASON"
}

# autopilot_sync <issue>: files a sync request on an open orch:done issue,
# through the Standing sync request transition - refused, with an `orch: `
# message, for an issue that is closed, not at orch:done or already carrying
# orch:sync.
autopilot_sync() {
  local issue="$1"
  is_positive_int "$issue" || die "not an issue number: $issue"
  standing_read "$issue" || gh_die "read issue #$issue" "$STANDING_REASON"
  [ "$STANDING_STATE" = OPEN ] || die "issue #$issue is closed"
  standing_is_done ||
    die "issue #$issue is not at $(standing_phase_label "done") - a sync request needs a done flow"
  [ "$STANDING_SYNC" = 0 ] || die "issue #$issue already carries $STANDING_SYNC_LABEL"
  standing_sync_request "$issue" || gh_die "add $STANDING_SYNC_LABEL to issue #$issue" "$STANDING_REASON"
}

# autopilot_reply <issue> <file>: posts <file> as a comment on the issue, then
# removes needs-human - refused unless the label is still on and no reply - any
# comment but a re-entry comment - follows the issue's newest question comment.
autopilot_reply() {
  local issue="$1" file="$2"
  is_positive_int "$issue" || die "not an issue number: $issue"
  [ -f "$file" ] || die "reply file not found: $file"
  [ -s "$file" ] || die "reply file is empty: $file"
  standing_human_guard "$issue"
  timeline_read_or_die "$issue"
  timeline_question || die "issue #$issue has no question comment to reply to"
  ! timeline_replied || die "a reply already follows the newest question on issue #$issue"
  gh_or_die "post the reply on issue #$issue" adapter_issue_comment "$issue" "$file"
  standing_resume "$issue" || die "the reply comment landed on issue #$issue, but $STANDING_HUMAN_LABEL could not be removed: $STANDING_REASON"
}

# autopilot_questions: one tab-separated line per open needs-human issue that
# carries a phase label other than orch:done, or sits at orch:done stopped by a
# sync (phase sync): the issue, its kind (question,
# replied or stop), the phase, and the URL of the comment the kind is about.
# The newest of the issue's question comments and stop comments decides the
# kind. Prints one line saying so when nothing is listed; dies, printing
# nothing, when any read fails.
autopilot_questions() {
  local list n phase row kind lines="" q_phase stop_phase
  list="$(standing_human_issues)" || exit $?
  for n in $(printf '%s\n' "$list" | sort -n); do
    standing_read "$n" || gh_die "read the labels of issue #$n" "$STANDING_REASON"
    phase="$STANDING_PHASE"
    timeline_read_or_die "$n"
    timeline_question || true
    timeline_stop || true
    q_phase="$TIMELINE_Q_PHASE" stop_phase="$TIMELINE_STOP_PHASE"
    if [ -z "$phase" ]; then
      # a done issue is listed only when a sync stopped it: orch:sync is still
      # on it (a failure stop), or its newest stop comment is a sync stop
      standing_is_done || continue
      if standing_is_sync || [ "$TIMELINE_STOP_PHASE" = "$STANDING_SYNC_PHASE" ]; then
        phase="$STANDING_SYNC_PHASE" q_phase="$STANDING_SYNC_PHASE" stop_phase="$STANDING_SYNC_PHASE"
      else
        continue
      fi
    fi
    if [ -n "$TIMELINE_Q_INDEX" ] && { [ -z "$TIMELINE_STOP_INDEX" ] || [ "$TIMELINE_Q_INDEX" -gt "$TIMELINE_STOP_INDEX" ]; }; then
      if timeline_replied; then kind="replied"; else kind="question"; fi
      row="$n"$'\t'"$kind"$'\t'"$q_phase"$'\t'"$TIMELINE_Q_URL"
    elif [ -n "$TIMELINE_STOP_INDEX" ]; then
      row="$n"$'\tstop\t'"$stop_phase"$'\t'"$TIMELINE_STOP_URL"
    else
      row="$n"$'\tstop\t'"$phase"$'\t'
    fi
    lines+="$row"$'\n'
  done
  if [ -n "$lines" ]; then printf '%s' "$lines"; else printf 'nothing pending: no open %s issue of an autopilot flow\n' "$STANDING_HUMAN_LABEL"; fi
}

# --- tick and run (#1458) ---------------------------------------------------
#
# One pass of the watcher, and the wrapper around one headless session. Every
# write under a claim ends in the Standing module's release.

# autopilot_dir <main-root>: where a clone's autopilot files live - the run
# records, the session logs, the limit files (limit, github-limit,
# github-early-<pool>) and the per-issue hit marks - under its main checkout.
autopilot_dir() { printf '%s/%s/autopilot\n' "$1" "$ORCH_DIR_NAME"; }

# autopilot_epoch_iso <epoch>: epoch seconds as a UTC timestamp, GNU or BSD
# date.
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

# autopilot_labels_ensure: the labels exist with their colour and
# description. Reads the repo's labels once and upserts only those missing or
# drifted in colour or description (names compared case-insensitively); with
# nothing drifted it writes nothing. A failed read or upsert dies, stopping
# the tick.
autopilot_labels_ensure() {
  local name colour description gh_err have _read_err
  capture have _read_err adapter_labels_detail 1000 ||
    die "could not read the repo's labels: $(gh_reason "$_read_err") - the tick stops"
  while IFS='|' read -r name colour description; do
    ! awk -F '\t' -v n="$name" -v c="$colour" -v d="$description" '
      tolower($1) == tolower(n) && tolower($2) == tolower(c) && $3 == d { found = 1 }
      END { exit !found }' <<<"$have" || continue
    capture_err gh_err adapter_label_upsert "$name" "$colour" "$description" ||
      die "could not upsert the label $name: $(gh_reason "$gh_err") - the tick stops"
  done <<<"$(standing_label_entries)"
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
# issue has no plan comment. Non-zero, the reason on stderr, where a read, the
# write of its copy or the post fails; a failed write posts no plan.
autopilot_post_minimal_plan() {
  local issue="$1" file st=0
  file="$(mktemp)" || { echo "could not create a temp file" >&2; return 1; }
  handoff_comment_fetch "$issue" 01-plan "$file" || st=$?
  if [ "$st" -eq 0 ]; then rm -f "$file"; return 0; fi
  if [ "$st" -ne 1 ]; then rm -f "$file"; return "$st"; fi
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

# autopilot_short_slug <title>: prints the normalised title as whole
# hyphen-separated words of at most 40 characters in all. A first word over 40
# on its own is cut at 40, so the slug is never empty; a title that normalises
# to nothing gives `untitled`.
autopilot_short_slug() {
  local norm word slug="" next
  norm="$(normalize_slug "$1" 2>/dev/null)" || { printf 'untitled\n'; return 0; }
  while [ -n "$norm" ]; do
    word="${norm%%-*}"
    case "$norm" in *-*) norm="${norm#*-}" ;; *) norm="" ;; esac
    next="${slug:+$slug-}$word"
    if [ "${#next}" -le 40 ]; then slug="$next"; continue; fi
    [ -n "$slug" ] || slug="${word:0:40}"
    break
  done
  printf '%s\n' "$slug"
}

# Pickup's reason channel: a step that fails sets PICKUP_REASON and returns 1,
# and autopilot_pickup_fail turns it into the stop's kind and text. Stderr is
# the tick's log and is never read for a step that sets its own reason.
PICKUP_REASON=""
PICKUP_KIND=""
PICKUP_TEXT=""

# autopilot_pickup_reason <stderr-text>: sets PICKUP_REASON from a failed
# step's stderr: its last `orch: ` line, kept whole, else its last non-empty
# line, else "the step gave no reason". Every other line goes on to stderr.
autopilot_pickup_reason() {
  local line n=0 i pick lastorch=-1 lastany=-1 lines=()
  if [ -n "$1" ]; then
    while IFS= read -r line; do
      lines+=("$line")
      [ -z "$line" ] || lastany=$n
      case "$line" in 'orch: '*) lastorch=$n ;; esac
      n=$((n + 1))
    done <<<"$1"
  fi
  if [ "$lastorch" -ge 0 ]; then pick=$lastorch; else pick=$lastany; fi
  if [ "$pick" -lt 0 ]; then PICKUP_REASON="the step gave no reason"; return 0; fi
  PICKUP_REASON="${lines[$pick]}"
  for ((i = 0; i < n; i++)); do
    [ "$i" -eq "$pick" ] || printf '%s\n' "${lines[$i]}" >&2
  done
}

# autopilot_pickup_settle <status> <stderr-text>: the tail of a captured step.
# A success passes every stderr line on; a failure sets PICKUP_REASON (see
# autopilot_pickup_reason) and returns 1.
autopilot_pickup_settle() {
  if [ "$1" -eq 0 ]; then
    [ -z "$2" ] || printf '%s' "$2" >&2
    return 0
  fi
  autopilot_pickup_reason "$2"
  return 1
}

# autopilot_pickup_contained <command...>: runs the command contained, so a die
# inside it fails only the step and a cd never reaches the tick's shell. A
# failure sets PICKUP_REASON (see autopilot_pickup_reason) and returns 1; a
# success passes every stderr line on. When the stderr's temp file cannot be
# made, the command is not run and the reason says so.
autopilot_pickup_contained() {
  local err st=0
  capture_err err "$@" || st=$?
  autopilot_pickup_settle "$st" "$err"
}

# autopilot_pickup_fail <kind> <detail>: records a failed step's stop - <kind>
# (refusal or failure) and the text "<detail>: <PICKUP_REASON>" - and returns 1.
autopilot_pickup_fail() {
  PICKUP_KIND="$1"
  PICKUP_TEXT="$2: $PICKUP_REASON"
  return 1
}

# autopilot_pickup_side_find <issue>: finds the issue's side checkout, into
# pickup's side - empty when it has none. It never fails.
autopilot_pickup_side_find() {
  side="$(side_checkout_for_issue "$1")" || side=""
}

# autopilot_pickup_side_title <issue>: the step reading the title of an issue
# with no side checkout, into pickup's title.
autopilot_pickup_side_title() {
  # labels is the read's throwaway half.
  # shellcheck disable=SC2034
  local labels gh_err
  issue_title_labels_read "$1" title labels gh_err || {
    PICKUP_REASON="$(gh_reason "$gh_err")"
    return 1
  }
}

# autopilot_pickup_side_add <issue> <title>: the step adding the issue's side
# checkout, into pickup's side. It tries, in order, <slug>, <slug>-<issue>,
# <slug>-<issue>-2, <slug>-<issue>-3 and so on, and takes the first with no
# entry of that name in the side checkouts directory.
autopilot_pickup_side_add() {
  local issue="$1" slug err st=0 dir stem n=1
  slug="$(autopilot_short_slug "$2")"
  dir="$(side_checkouts_dir "$(main_checkout)")"
  # a clash with any entry of the directory moves on to the next name
  if [ -e "$dir/$slug" ]; then
    slug="$slug-$issue"
    stem="$slug"
    while [ -e "$dir/$slug" ]; do
      n=$((n + 1))
      slug="$stem-$n"
    done
  fi
  capture side err cmd_side_checkout_add "$slug" --issue "$issue" || st=$?
  autopilot_pickup_settle "$st" "$err"
}

# autopilot_pickup_init <issue> <side>: the step initialising a side checkout
# that holds no flow yet.
autopilot_pickup_init() {
  checkout_has_flow "$2" || ORCH_AUTOPILOT=1 autopilot_orch_in "$2" init "$(basename "$2")" --issue "$1"
}

# autopilot_pickup_trust <issue>: the step refusing an untrusted issue - the
# first of pickup, before any side checkout, init or plan comment, so it runs
# before every phase. An untrusted one is a refusal naming the writer and
# whether they last wrote the title or the body; a failed read is a failure
# naming the read (it fails closed).
autopilot_pickup_trust() {
  local st=0
  trust_issue_check "$1" || st=$?
  case "$st" in
    0) return 0 ;;
    1)
      PICKUP_KIND=refusal
      PICKUP_TEXT="$(trust_writer_text "the issue") - an owner, member or collaborator must edit it before autopilot runs on it"
      ;;
    *)
      PICKUP_REASON="$TRUST_REASON"
      autopilot_pickup_fail failure "step trust read failed"
      ;;
  esac
  return 1
}

# autopilot_pickup_recorded <side>: the step reading the side checkout's
# recorded phase, into pickup's recorded. An unreadable state.json earns its
# plain reason; any other failure, the read-failed one.
autopilot_pickup_recorded() {
  local state_file rc=0
  state_file="$(flow_state_file "$1")"
  recorded="$(state_get_in "$state_file" phase)" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  if [ "$rc" -eq 2 ]; then
    PICKUP_REASON="state.json in $1 cannot be read - run orch.sh doctor --flow"
  else
    PICKUP_REASON="could not read the phase recorded in $state_file"
  fi
  return 1
}

# autopilot_read_die <key> <side> <status>: dies over a failed read of <key>
# from <side>'s state.json; only status 2, the unreadable file, earns the
# plain reason.
autopilot_read_die() {
  if [ "$3" -eq 2 ]; then
    die "could not read the recorded $1 of $2 - state.json cannot be read"
  fi
  die "could not read the recorded $1 of $2"
}

# autopilot_pickup_redo <side> <redo>: the step redoing a phase.
autopilot_pickup_redo() {
  ORCH_AUTOPILOT=1 autopilot_orch_in "$1" redo "$2"
}

# autopilot_pickup_steps <issue> <phase> <limited>: Pickup's steps in order, up
# to the session's start. The first that fails leaves PICKUP_KIND and
# PICKUP_TEXT and returns 1.
autopilot_pickup_steps() {
  local issue="$1" phase="$2" limited="$3" side="" title="" recorded redo sync=0
  [ "$phase" != "$STANDING_SYNC_PHASE" ] || sync=1
  autopilot_pickup_trust "$issue" || return 1
  autopilot_pickup_side_find "$issue"
  if [ "$sync" = 1 ]; then
    # a sync adds no side checkout, runs no init, posts no plan comment
    # and runs no redo
    if [ -z "$side" ]; then
      PICKUP_KIND=refusal
      PICKUP_TEXT="no side checkout on this host holds issue #$issue - run $(plugin_cmd sync "the orch-sync skill") where it lives"
      return 1
    fi
  else
    if [ -z "$side" ]; then
      autopilot_pickup_side_title "$issue" || autopilot_pickup_fail failure "step side-checkout add failed: could not read the issue's title" || return 1
      autopilot_pickup_side_add "$issue" "$title" || autopilot_pickup_fail failure "step side-checkout add failed" || return 1
    fi
    autopilot_pickup_contained autopilot_pickup_init "$issue" "$side" || autopilot_pickup_fail failure "step init failed" || return 1
    autopilot_pickup_contained autopilot_post_minimal_plan "$issue" || autopilot_pickup_fail failure "step minimal plan comment failed" || return 1
  fi
  autopilot_pickup_recorded "$side" || autopilot_pickup_fail failure "step reading the recorded phase failed" || return 1
  if [ "$sync" = 1 ]; then
    if [ -n "$recorded" ] && [ "$recorded" != "done" ]; then
      PICKUP_KIND=refusal
      PICKUP_TEXT="the issue carries a sync request, but its side checkout records phase $recorded, not done"
      return 1
    fi
  elif [ "$recorded" != "$phase" ]; then
    redo="$(standing_redo_phase "$phase" "$recorded")" || {
      PICKUP_KIND=refusal
      PICKUP_TEXT="the issue is labelled $(standing_phase_label "$phase"), but its side checkout last moved to phase $recorded - only $(standing_redo_rule) is a redo"
      return 1
    }
    autopilot_pickup_contained autopilot_pickup_redo "$side" "$redo" || autopilot_pickup_fail refusal "redo $redo refused" || return 1
  fi
  standing_begin "$issue" "$limited" || {
    PICKUP_KIND=failure
    PICKUP_TEXT="$STANDING_REASON"
    return 1
  }
}

# autopilot_github_paused: succeeds when a GitHub pause holds; says nothing.
autopilot_github_paused() {
  local main_root
  main_root="$(main_checkout_or_die 2>/dev/null)" &&
    autopilot_pause_until "$main_root" github >/dev/null 2>&1
}

# autopilot_pickup <issue> <phase> [limited]: steps 2 to 5 of a tick for a
# claimed issue. A refusal or a failed step ends in one standing_stop and
# returns 0: the claim is released, the tick goes on. A step that failed on a
# GitHub API rate limit - a GitHub pause holds once it has failed - deletes only
# the claim ref (a git push: no stop, no label, nothing counted); if that push
# fails the claim stays held for stale cleanup. The pause ends the tick.
autopilot_pickup() {
  autopilot_pickup_steps "$1" "$2" "${3:-}" || {
    if autopilot_github_paused; then
      standing_claim_drop "$1" >/dev/null 2>&1 ||
        warn "could not delete the claim ref on issue #$1; it stays held for stale cleanup"
      return 0
    fi
    standing_stop "$1" "$PICKUP_KIND" "$2" "$PICKUP_TEXT"
    return 0
  }
  autopilot_spawn_run "$1"
}

# autopilot_cleanup_stale: every claim of this host whose process is gone is a
# failure: needs-human, a comment, then the claim released. The process is the
# Liveness module's to name, and both of the issue's records go with the claim.
# Other hosts' claims are never touched.
autopilot_cleanup_stale() {
  local issue phase log detail me gone_pid backstop
  me="$(standing_host_id)"
  standing_claims_read
  for issue in ${STANDING_CLAIM_ISSUES[@]+"${STANDING_CLAIM_ISSUES[@]}"}; do
    [ "${STANDING_CLAIM_HOST[$issue]}" = "$me" ] || continue
    phase="${STANDING_CLAIM_PHASE[$issue]}"
    gone_pid="$(liveness_issue_alive "$issue")" && continue
    detail="the session's process (pid ${gone_pid:-unknown}) is gone and the claim was never released - no exit code is known"
    log="$(liveness_latest_log "$issue" "$phase")" || true
    backstop=""
    [ -z "$log" ] || backstop="$(P="$AUTOPILOT_BACKSTOP_PREFIX" awk 'index($0, ENVIRON["P"]) == 1' "$log" 2>/dev/null | tail -1)" || true
    if [ -n "$backstop" ]; then detail="${detail%% - no exit code is known} - the session log says: \"${backstop#autopilot run: }\""; fi
    if [ -n "$log" ]; then detail="$detail; log: $log"; else detail="$detail; no session log"; fi
    standing_stop "$issue" failure "$phase" "$detail"
    liveness_issue_forget "$issue"
  done
}

# The pause stores: the usage limit file (autopilot_usage_pause_file), the
# GitHub limit file (autopilot_github_pause_file) and one early GitHub file per
# pool (autopilot_github_early_file). Each path is built by its helper; a file
# is written through autopilot_pause_put (autopilot_pause_extend for the usage
# file) and read through autopilot_pause_epoch or autopilot_pause_until.

# autopilot_usage_pause_file <main>: the usage limit file under <main>.
autopilot_usage_pause_file() { printf '%s/limit\n' "$(autopilot_dir "$1")"; }

# autopilot_pause_epoch <file>: the reset recorded in the limit file <file> as
# epoch seconds; 0 when the file is missing or its text does not parse.
autopilot_pause_epoch() {
  local text
  text="$(cat "$1" 2>/dev/null)" || text=""
  autopilot_iso_epoch "$text" || echo 0
}

# autopilot_github_pause_file <main>: the GitHub limit file under <main>, the
# pause a GitHub API rate limit writes (#2577).
autopilot_github_pause_file() { printf '%s/github-limit\n' "$(autopilot_dir "$1")"; }

# gh_limit_record <reset>: in an autopilot process - a tick or the session
# wrapper, each by a flag of its own, or a session (ORCH_AUTOPILOT=1) - writes
# the GitHub pause, extended only to the later of two resets; in a session,
# which has the wrapper's hit file path, writes the reset there too. An
# interactive call writes nothing. Never fails: a write that fails is a warning.
gh_limit_record() {
  local main_root
  [ "${ORCH_AUTOPILOT:-}" = 1 ] || [ -n "${ORCH_AUTOPILOT_TICK:-}${ORCH_AUTOPILOT_RUN:-}" ] || return 0
  if main_root="$(main_checkout_or_die 2>/dev/null)" && [ -n "$main_root" ]; then
    autopilot_pause_put "$(autopilot_github_pause_file "$main_root")" "$1" ||
      warn "could not write the GitHub limit pause under $main_root"
  else
    warn "could not write the GitHub limit pause: the main checkout is unreadable"
  fi
  if [ "${ORCH_AUTOPILOT:-}" = 1 ] && [ -n "${ORCH_AUTOPILOT_HIT_FILE:-}" ]; then
    autopilot_pause_put "$ORCH_AUTOPILOT_HIT_FILE" "$1" ||
      warn "could not write the GitHub limit hit file $ORCH_AUTOPILOT_HIT_FILE"
  fi
  return 0
}

# autopilot_github_early_file <main> <pool>: the early GitHub pause's file for
# <pool> (core or graphql) under <main>: pickup paused, before any limit is hit,
# while the pool is below the github-reserve (#2577).
autopilot_github_early_file() { printf '%s/github-early-%s\n' "$(autopilot_dir "$1")" "$2"; }

# autopilot_github_quota: GitHub's core and graphql pools, one per line as
# "<pool> <remaining> <limit> <reset>", the reset in epoch seconds; fails,
# printing nothing, when the read fails. The read is not itself guarded by the
# limit handler and costs no quota.
autopilot_github_quota() {
  local out
  out="$(GH_LIMIT_READING=1 adapter_rate_limit 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  tr '\t' ' ' <<<"$out"
}

# autopilot_github_early <main>: the early GitHub pause. Reads the pools and,
# for each with less than github-reserve percent of its limit left, records its
# reset in the pool's early file (kept if later). A reserve of 0 reads nothing,
# and the tick then ignores a recorded early pause; a failed read pauses
# nothing.
autopilot_github_early() {
  local quota pool remaining limit reset
  autopilot_setting github-reserve
  [ "$AUTOPILOT_VALUE" -gt 0 ] || return 0
  quota="$(autopilot_github_quota)" || return 0
  while read -r pool remaining limit reset; do
    case "$pool" in core|graphql) ;; *) continue ;; esac
    case "$remaining$limit$reset" in *[!0-9]*|'') continue ;; esac
    [ "$limit" -gt 0 ] && [ "$((remaining * 100))" -lt "$((AUTOPILOT_VALUE * limit))" ] || continue
    [ "$reset" -gt "$(date +%s)" ] || continue
    autopilot_pause_put "$(autopilot_github_early_file "$1" "$pool")" "$reset" ||
      warn "could not write the early GitHub pause under $1"
  done <<<"$quota"
}

# autopilot_github_usage <before>: the change in core and graphql usage since
# <before> (autopilot_github_quota's output at session start) as one line, "core
# <n>, graphql <m>"; fails, printing nothing, when either read failed. A pool
# that reset meanwhile counts as no usage.
autopilot_github_usage() {
  local after pool n line="" b_used a_used
  [ -n "$1" ] || return 1
  after="$(autopilot_github_quota)" || return 1
  for pool in core graphql; do
    b_used="$(awk -v p="$pool" '$1 == p { print $3 - $2 }' <<<"$1")"
    a_used="$(awk -v p="$pool" '$1 == p { print $3 - $2 }' <<<"$after")"
    case "$b_used$a_used" in ''|*[!0-9-]*) return 1 ;; esac
    [ -n "$b_used" ] && [ -n "$a_used" ] || return 1
    n=$((a_used - b_used)); [ "$n" -ge 0 ] || n=0
    line="${line:+$line, }$pool $n"
  done
  printf '%s\n' "$line"
}

# autopilot_pause_until <main> [github|core|graphql]: whether a limit pauses
# pickup: the usage limit, with "github" the GitHub API rate limit, or with a
# pool its early GitHub pause. While the limit
# file's reset time is in the future it prints one line naming it and returns
# 0; once it has passed, the file is removed and it returns 1.
autopilot_pause_until() {
  local file epoch what="usage limit: no issue is picked up until"
  case "${2:-}" in
    github)
      file="$(autopilot_github_pause_file "$1")"
      what="GitHub API rate limit: the tick does nothing until" ;;
    core|graphql)
      file="$(autopilot_github_early_file "$1" "$2")"
      what="GitHub $2 pool is below the github-reserve: no issue is picked up until" ;;
    *)
      file="$(autopilot_usage_pause_file "$1")" ;;
  esac
  [ -f "$file" ] || return 1
  epoch="$(autopilot_pause_epoch "$file")"
  if [ "$epoch" -gt "$(date +%s)" ]; then
    # The GitHub pauses go to stderr: the watcher discards each tick's stdout
    # but keeps its stderr, so the container log says why the watcher is idle.
    case "${2:-}" in
      github|core|graphql) warn "$what $(cat "$file")" ;;
      *) note "$what $(cat "$file")" ;;
    esac
    return 0
  fi
  rm -f "$file"
  return 1
}

# autopilot_pause_put <file> <epoch>: records <epoch> (epoch seconds) in <file>
# as one UTC ISO timestamp, keeping a reset already there that is later and
# replacing one that is earlier or does not parse. Fails, silently, when the
# file cannot be written.
autopilot_pause_put() {
  local file="$1" new_epoch="$2" old_epoch
  if [ -f "$file" ]; then
    old_epoch="$(autopilot_pause_epoch "$file")"
    [ "$old_epoch" -lt "$new_epoch" ] || return 0
  fi
  { mkdir -p "$(dirname "$file")" && autopilot_epoch_iso "$new_epoch" >"$file"; } 2>/dev/null
}

# autopilot_pause_extend <file> <epoch> <log> [<what>]: records <epoch> as the
# reset of the limit file <file>, by autopilot_pause_put's rule; <what>
# ("GitHub") prefixes "limit file" in a failure's note. A failed write is noted
# in <log> and on stderr, and is no failure of the caller.
autopilot_pause_extend() {
  local file="$1" log="$3" msg
  if ! autopilot_pause_put "$file" "$2"; then
    msg="autopilot run: could not write the ${4:+$4 }limit file $file"
    warn "$msg"
    printf '%s\n' "$msg" >>"$log"
  fi
  return 0
}

# autopilot_flow_issues: the open issues carrying a phase label other than
# orch:done, or orch:sync, deduplicated and oldest first, one number per line.
autopilot_flow_issues() {
  local label out gh_err all="" labels=() phase
  for phase in $PHASES; do
    [ "$phase" != "done" ] || continue
    labels+=("$(standing_phase_label "$phase")")
  done
  labels+=("$STANDING_SYNC_LABEL")
  for label in "${labels[@]}"; do
    capture out gh_err adapter_issues_labelled "$label" ||
      die "could not list the issues labelled $label: $(gh_reason "$gh_err")"
    all="$all$out"$'\n'
  done
  printf '%s' "$all" | grep -v '^$' | sort -nu || true
}

# autopilot_verdict <issue> <named> <var>: the quick autopilot's verdict on one
# issue, into <var>: `eligible <none|move|override>` or `skip <reason>`, the
# first exclusion in the fixed order (closed, missing, untrusted, phase,
# wontfix, needs-info, ticket, untriaged-finding). <named> is true for an issue
# the caller named, the only kind that can be `missing`: gh's not-found reason
# for a listed one, like any other failed read, dies. Writes nothing.
autopilot_verdict() {
  local issue="$1" named="$2" state labels err parent phase label role st=0 ready human
  if ! issue_state_labels_read "$issue" state labels err; then
    if [ "$named" = true ] && gh_issue_not_found "$err"; then
      printf -v "$3" '%s' "skip missing"
      return 0
    fi
    die "could not read issue #$issue: $(gh_reason "$err")"
  fi
  if [ "$state" != OPEN ]; then printf -v "$3" '%s' "skip closed"; return 0; fi
  trust_issue_check "$issue" || st=$?
  case "$st" in
    0) ;;
    1) printf -v "$3" 'skip untrusted %s' "$TRUST_WRITER"; return 0 ;;
    *) die "could not check the trust of issue #$issue: $TRUST_REASON" ;;
  esac
  for phase in $(standing_phase_labels_in "$labels"); do
    printf -v "$3" 'skip phase %s' "$phase"
    return 0
  done
  for role in wontfix needs-info; do
    label="$(triage_label_for "$role")"
    if label_listed "$labels" "$label"; then printf -v "$3" 'skip %s' "$role"; return 0; fi
  done
  gh_or_die --out parent "read issue #$issue's parent" adapter_issue_parent "$issue"
  if [ -n "$parent" ]; then printf -v "$3" 'skip ticket #%s' "$parent"; return 0; fi
  ready="$(triage_label_for ready-for-agent)"
  human="$(triage_label_for ready-for-human)"
  # A filed finding finding triage has not yet triaged: the issue triage gate.
  if finding_untriaged "$labels"; then
    printf -v "$3" '%s' "skip untriaged-finding"
    return 0
  fi
  if label_listed "$labels" "$ready"; then printf -v "$3" '%s' "eligible none"
  elif label_listed "$labels" "$human"; then printf -v "$3" '%s' "eligible override"
  else printf -v "$3" '%s' "eligible move"; fi
}

# autopilot_candidates_run <arg>...: orch.sh autopilot candidates. One line per
# issue, `<n> eligible <none|move|override>` or `<n> skip <reason>`: the named
# issues in the order named, or with --all / --limit <k> every open issue
# oldest first (--limit keeping the first k eligible lines). Every read comes
# before the first line is printed, so a failed read leaves no partial list.
autopilot_candidates_run() {
  local usage="usage: orch.sh autopilot candidates [<n>... | --all | --limit <k>]"
  local mode="" limit="" issues=() arg
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --all) [ -z "$mode" ] || die "$usage"; mode=all ;;
      --limit)
        [ -z "$mode" ] || die "$usage"
        [ $# -gt 0 ] || die "$usage"
        is_positive_int "$1" || die "--limit must be a positive whole number, got: $1"
        mode=limit; limit="$((10#$1))"; shift ;;
      ''|*[!0-9]*) die "$usage" ;;
      *) [ -z "$mode" ] || [ "$mode" = named ] || die "$usage"; mode=named; issues+=("$((10#$arg))") ;;
    esac
  done
  [ -n "$mode" ] || die "$usage"
  local out n verdict report="" eligible=0 named=false
  if [ "$mode" = named ]; then
    named=true
  else
    gh_or_die --out out "list the open issues" adapter_issues_open_oldest
    while IFS= read -r n; do [ -z "$n" ] || issues+=("$n"); done <<<"$out"
    if [ "${#issues[@]}" -ge "$ISSUE_LIST_LIMIT" ]; then
      warn "the open issues reached the issue-list limit of $ISSUE_LIST_LIMIT - the newest past it are missing from this list"
    fi
  fi
  for n in ${issues[@]+"${issues[@]}"}; do
    if [ "$mode" = limit ] && [ "$eligible" -ge "$limit" ]; then break; fi
    autopilot_verdict "$n" "$named" verdict
    case "$verdict" in eligible*) eligible=$((eligible + 1)) ;; esac
    report="$report$n $verdict"$'\n'
  done
  printf '%s' "$report"
}

# autopilot_done_read <table-var>: the tick's one read of the open orch:done
# issues. Lists the issues labelled orch:done once, reads each once, and writes
# into the caller-named <table-var> the done table: one line per issue that
# reads OPEN and still at orch:done, `<issue> <running> <sync> <human>`, each
# flag 0 or 1. A failed listing warns once and leaves the table empty; a failed
# read warns once and leaves that issue out. Neither stops the tick.
autopilot_done_read() {
  local _out _err _issue _table="" _label
  _label="$(standing_phase_label "done")"
  printf -v "$1" '%s' ""
  capture _out _err adapter_issues_labelled "$_label" || {
    warn "could not list the issues labelled $_label: $(gh_reason "$_err") - no merged-PR close or sync detection this tick"
    return 0
  }
  while IFS= read -r _issue; do
    [ -n "$_issue" ] || continue
    standing_read "$_issue" || {
      warn "could not read issue #$_issue: $STANDING_REASON - the merged-PR close and sync detection skip it"
      continue
    }
    [ "$STANDING_STATE" = OPEN ] || continue
    standing_is_done || continue
    _table="$_table$_issue $STANDING_RUNNING $STANDING_SYNC $STANDING_HUMAN"$'\n'
  done <<<"$_out"
  printf -v "$1" '%s' "$_table"
}

# autopilot_sync_detect <table>: the sync request auto-detection, from the
# done table autopilot_done_read took (it reads no issue itself). When the table
# is not empty, reads the repo's open PRs once, then files a sync request,
# through the Standing transition, on every issue in it carrying none of
# orch:sync, needs-human and orch:running whose one open same-repository PR
# (head branch `orch/<issue>-`) is CONFLICTING. An issue with no such PR is
# skipped silently, one with several warned about; a failed read or write warns
# and skips that issue only.
autopilot_sync_detect() {
  local raw="" prs="" gh_err issue running sync human pr_lines head_prefix count reason=""
  [ -n "$1" ] || return 0
  if capture raw gh_err adapter_prs_open_mergeability; then
    prs="$(printf '%s\n' "$raw" | trust_filter_prs "the open PRs")" || reason="the open PRs could not be read: a malformed line"
  else
    reason="$(gh_reason "$gh_err")"
  fi
  while read -r issue running sync human; do
    [ -n "$issue" ] || continue
    [ "$sync" = 0 ] && [ "$human" = 0 ] && [ "$running" = 0 ] || continue
    if [ -n "$reason" ]; then
      warn "could not read the PR of issue #$issue: $reason - sync detection skips it"
      continue
    fi
    head_prefix="$(branch_name_flow "$issue" "")"
    pr_lines="$(printf '%s\n' "$prs" | awk -F'\t' -v p="$head_prefix" 'index($2, p) == 1')"
    count="$(printf '%s' "$pr_lines" | grep -c . || true)"
    [ "$count" -ne 0 ] || continue
    if [ "$count" -gt 1 ]; then
      warn "issue #$issue has $count open PRs from a branch starting $head_prefix - sync detection skips it"
      continue
    fi
    [ "$(printf '%s' "$pr_lines" | cut -f3)" = CONFLICTING ] || continue
    standing_sync_request "$issue" ||
      warn "could not add $STANDING_SYNC_LABEL to issue #$issue: $STANDING_REASON - sync detection skips it"
  done <<<"$1"
}

# autopilot_close_missed <table> <table-var>: the merged-PR backstop (#2478),
# run every tick whatever the auto-sync setting, from the done table
# autopilot_done_read took (it reads no issue itself). When the table is not
# empty, reads the PRs merged into the default branch once, and closes - through
# pr_close_missed - each issue in it not carrying orch:running whose newest
# merged PR from `orch/<issue>-` should have closed it. orch:sync and
# needs-human do not stop it. A failed read or close warns and skips, never
# stopping the tick. Writes into the caller-named <table-var> the table minus
# every issue it closed: the whole table when the merged-PR read fails.
autopilot_close_missed() {
  local prs issue running sync human default kept=""
  printf -v "$2" '%s' "$1"
  [ -n "$1" ] || return 0
  pr_merged_closing_read default prs "no merged-PR close this tick" || return 0
  while read -r issue running sync human; do
    [ -n "$issue" ] || continue
    if [ "$running" = 0 ] &&
      pr_close_newest "$issue" "$default" \
        "$(printf '%s\n' "$prs" | awk -F'\t' -v p="$(branch_name_flow "$issue" "")" 'index($2, p) == 1')"; then
      continue
    fi
    kept="$kept$issue $running $sync $human"$'\n'
  done <<<"$1"
  printf -v "$2" '%s' "$kept"
}

# autopilot_rank <phase word>: the pickup rank of a session's phase word, lowest
# first: a sync request 0, then the phases in reverse order of the phase table
# (review 1, implement 2, spec 3), the phase furthest along first. done is not
# picked up and has no rank.
autopilot_rank() {
  local phase i=0 n=0
  [ "$1" != "$STANDING_SYNC_PHASE" ] || { printf '0'; return; }
  for phase in $PHASES; do
    [ "$phase" = "done" ] || n=$((n + 1))
  done
  for phase in $PHASES; do
    [ "$phase" != "done" ] || continue
    [ "$phase" != "$1" ] || { printf '%s' "$((n - i))"; return; }
    i=$((i + 1))
  done
  printf '%s' "$((n + 1))"
}

# autopilot_tick: one pass - the GitHub-limit pause check (while it holds the
# tick ends there, making no GitHub call, not even closing merged PRs), the
# early-pause quota read (autopilot_github_early), labels,
# stale claims, one read of the done issues (autopilot_done_read), the
# merged-PR close (which needs no session, so the usage-limit and early pauses
# never hold it), the three limit-pause checks (usage, core, graphql), sync
# detection (when auto-sync is true), then pickup (see the spec's One tick),
# the tick ending after any pickup that leaves a GitHub pause holding.
# The one done read feeds both passes: sync detection gets the done table
# minus the issues the close closed. Every candidate is read before the first
# claim, the unpickable ones dropped, and the rest taken by rank - sync
# requests,
# then the phases furthest along first, oldest issue first within a rank. A
# phase is claimed while the claim count is below the cap, a sync request
# while it is below the cap plus the sync slots (half the cap, rounded down);
# the first phase issue not claimed for the cap ends the tick. A claim
# create that fails for a reason other than a lost race stops the tick, naming
# it.
autopilot_tick() {
  local main_root cap count issue gh_err phase rc flow_issues limited_arg auto_sync
  local ranked="" slots limit limited done_table
  autopilot_setting cap; cap="$AUTOPILOT_VALUE"
  autopilot_setting auto-sync; auto_sync="$AUTOPILOT_VALUE"
  main_root="$(main_checkout_or_die)" || exit $?
  cd "$main_root" || die "could not enter the main checkout $main_root"
  if autopilot_pause_until "$main_root" github; then return 0; fi
  autopilot_github_early "$main_root"
  autopilot_labels_ensure
  autopilot_cleanup_stale
  autopilot_done_read done_table
  autopilot_close_missed "$done_table" done_table
  if autopilot_pause_until "$main_root"; then return 0; fi
  # A reserve of 0 turns the early pause off, a recorded one included.
  autopilot_setting github-reserve
  if [ "$AUTOPILOT_VALUE" -gt 0 ]; then
    if autopilot_pause_until "$main_root" core; then return 0; fi
    if autopilot_pause_until "$main_root" graphql; then return 0; fi
  fi
  if [ "$auto_sync" = true ]; then autopilot_sync_detect "$done_table"; fi
  standing_claims_read
  count="${#STANDING_CLAIM_ISSUES[@]}"
  slots=$((cap / 2))
  flow_issues="$(autopilot_flow_issues)"
  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    standing_read "$issue" ||
      die "could not read issue #$issue: $STANDING_REASON"
    standing_pickable || continue
    phase="$(standing_session_phase)"
    ranked="$ranked$(autopilot_rank "$phase") $issue $phase $STANDING_LIMITED"$'\n'
  done <<<"$flow_issues"
  ranked="$(printf '%s' "$ranked" | sort -k1,1n -k2,2n)"
  while read -r _ issue phase limited; do
    [ -n "$issue" ] || continue
    if [ "$phase" = "$STANDING_SYNC_PHASE" ]; then limit=$((cap + slots)); else limit="$cap"; fi
    if [ "$count" -ge "$limit" ]; then
      [ "$phase" = "$STANDING_SYNC_PHASE" ] && continue
      break
    fi
    rc=0
    capture_err gh_err standing_claim "$issue" "$phase" "$$" || rc=$?
    case "$rc" in
      0) ;;
      2) continue ;;
      *) die "could not claim issue #$issue: $(gh_reason "$gh_err") - the tick stops" ;;
    esac
    liveness_tick_begin "$issue"
    count=$((count + 1))
    limited_arg=""
    if [ "$limited" = 1 ]; then limited_arg=limited; fi
    autopilot_pickup "$issue" "$phase" "$limited_arg"
    if autopilot_pause_until "$main_root" github; then return 0; fi
  done <<<"$ranked"
}

# autopilot_session_end <issue> <phase> <log> <rc> <mine>: applies the whole
# consequence of a phase session's end. <mine> is the claim fields read before
# the session ("" when there was none). It reads origin's claims again: the
# session is held when the issue has a claim and either <mine> is empty or the
# claim's fields equal <mine>, else released (the claim was released, or the
# next phase's took its place). It reads the log once, with session_log_read.
# The outcome is released (not held, whatever the log holds), else limited
# (session_log_read says the session stopped on a usage limit), else
# GitHub-limited (the issue's hit file names a reset), else failure. The hit
# file is removed once read, whatever the outcome. A GitHub-limited outcome
# extends the GitHub pause to the hit file's reset.
# The limit pause is the reset the session named, or one hour on; the early
# pause is the five-hour window's resetsAt when its utilization is 0.9 or more,
# whatever the outcome; all are epoch seconds. The usage pause store is
# extended once, with the later of the two. Then every stop goes through
# autopilot_stop_attempts: the released note, the limit stop or the failure
# stop, retried up to AUTOPILOT_STOP_ATTEMPTS times, with a backstop line in the
# log; it returns 1, the claim held, when the chain gives up. It dies, before
# any write, when the checkout or the claims cannot be read.
autopilot_session_end() {
  local issue="$1" phase="$2" log="$3" rc="$4" mine="$5" main_root claim_after held=0 reply detail
  local outcome=failure limit="" pause released_note hit_text hit_epoch=0
  main_root="$(main_checkout_or_die)" || exit $?
  standing_claims_read
  if claim_after="$(standing_claim_fields "$issue")" && { [ -z "$mine" ] || [ "$claim_after" = "$mine" ]; }; then held=1; fi
  session_log_read "$log"
  hit_text="$(liveness_hit_take "$issue")" || exit $?
  [ -z "$hit_text" ] || hit_epoch="$(autopilot_iso_epoch "$hit_text")" || hit_epoch=0
  if [ "$held" = 0 ]; then
    outcome=released
  elif [ "$SESSION_LOG_LIMITED" = 1 ]; then
    outcome=limited
    limit="${SESSION_LOG_RESET:-$(( $(date +%s) + 3600 ))}"
  elif [ "$hit_epoch" -gt 0 ]; then
    outcome=github
  fi
  # One write: the later of the two pauses.
  pause="$SESSION_LOG_EARLY"
  if [ -n "$limit" ] && { [ -z "$pause" ] || [ "$limit" -gt "$pause" ]; }; then pause="$limit"; fi
  if [ -n "$pause" ]; then autopilot_pause_extend "$(autopilot_usage_pause_file "$main_root")" "$pause" "$log"; fi
  if [ "$outcome" = github ]; then
    autopilot_pause_extend "$(autopilot_github_pause_file "$main_root")" "$hit_epoch" "$log" GitHub
  fi
  case "$outcome" in
    released)
      released_note="autopilot run: issue #$issue's session exited $rc with its claim released"
      note "$released_note"
      printf '%s\n' "$released_note" >>"$log"
      return 0 ;;
    limited)
      autopilot_stop_attempts "$log" "the session exited with code $rc" standing_limit_stop "$issue" "$phase" "${SESSION_LOG_RESET:+$(autopilot_epoch_iso "$SESSION_LOG_RESET")}" "$(autopilot_epoch_iso "$limit")" "$rc" "$log"
      return ;;
    github)
      autopilot_stop_attempts "$log" "the session exited with code $rc" standing_limit_stop "$issue" "$phase" "$(autopilot_epoch_iso "$hit_epoch")" "$(autopilot_epoch_iso "$hit_epoch")" "$rc" "$log" github
      return ;;
  esac
  reply="$SESSION_LOG_REPLY"
  detail="the session exited with code $rc; "
  [ -z "$reply" ] || detail+="it ended on: *$reply*; "
  autopilot_stop_attempts "$log" "the session exited with code $rc" standing_stop "$issue" failure "$phase" "${detail}log: $log"
}

# autopilot_github_pause_wait [<seconds>]: sleeps until a GitHub pause that
# holds has passed, else <seconds> (none by default); ORCH_GH_LIMIT_WAIT, the
# guard's test knob, replaces the wait either way.
autopilot_github_pause_wait() {
  local wait="${1:-0}" main_root
  if autopilot_github_paused; then
    main_root="$(main_checkout_or_die)"
    wait="$(( $(autopilot_pause_epoch "$(autopilot_github_pause_file "$main_root")") - $(date +%s) ))"
  fi
  sleep "${ORCH_GH_LIMIT_WAIT:-$wait}"
}

AUTOPILOT_STOP_ATTEMPTS=3
AUTOPILOT_BACKSTOP_PREFIX="autopilot run: the stop chain failed after $AUTOPILOT_STOP_ATTEMPTS attempts - "

# autopilot_stop_attempts <log> <closing> <command>...: the wrapper's stop
# chain, run
# up to three times, each attempt in a subshell so a death ends the attempt; the
# claim and the run record are kept throughout. The attempts share one state
# file (standing.sh's resumable chain), so each resumes from the first write
# that did not land. Before the second and third it waits for a GitHub pause
# when one holds, else 60, then 300 seconds; ORCH_GH_LIMIT_WAIT, the guard's
# test knob, shortens every wait, the pause wait included. When the last
# attempt fails it writes one backstop line to <log> - the stop's kind, its
# first line and <closing>, the clause that ends it - for stale cleanup to
# quote, and returns 1.
autopilot_stop_attempts() {
  local log="$1" closing="$2" state attempt line kind first
  shift 2
  state="$(mktemp)" || die "could not create a temp file for the stop chain's state"
  for ((attempt = 1; attempt <= AUTOPILOT_STOP_ATTEMPTS; attempt++)); do
    if [ "$attempt" -gt 1 ]; then
      autopilot_github_pause_wait $(( attempt == 2 ? 60 : 300 ))
    fi
    if ( STANDING_STATE_FILE="$state"; "$@" ); then rm -f "$state"; return 0; fi
  done
  # shellcheck disable=SC2034 # standing_state_get reads it
  line="$(STANDING_STATE_FILE="$state"; standing_state_get stop)" || line="stop"$'\t'"no stop text was built"
  rm -f "$state"
  kind="${line%%$'\t'*}" first="${line#*$'\t'}"
  printf '%s%s: %s; %s\n' "$AUTOPILOT_BACKSTOP_PREFIX" "$kind" "$first" "$closing" >>"$log"
  return 1
}

# The tools a headless phase session gets: those the plugin's skills and agents
# use.
AUTOPILOT_TOOLS="Agent,Skill,Bash,Read,Edit,Write,Grep,Glob,SendMessage"
# Its system prompt addition: it is told it is headless, as print mode turns
# AskUserQuestion off and a question asked in chat is never answered.
AUTOPILOT_SYSTEM_PROMPT='You are a headless orchestrator autopilot session: no human reads this conversation, and no tool asks one. Never end your turn on a question. Where a skill offers an autopilot branch (`orch.sh autopilot active` exits 0, which it does in this session), take that branch. Where a decision truly needs the human, post it with `orch.sh autopilot ask <phase> <file>` and stop. When an `orch:` message says the GitHub API rate limit was reached, end your turn at once: do not retry or wait, the watcher picks the work up after the reset.'
# Its settings: no bundled skills, and no plugin-authoring, a built-in plugin
# that disableBundledSkills leaves listed.
AUTOPILOT_SETTINGS='{"disableBundledSkills":true,"enabledPlugins":{"plugin-authoring@builtin":false}}'
# How long, in ms, print mode waits for background tasks after a session's last
# turn: a ticket subagent outlives its 10-minute default, and a finite ceiling
# (2 hours) still ends a hung session, which then goes through the existing
# failure handling. Not 0: nothing else limits a session, so a hung subagent
# would hold its claim forever.
AUTOPILOT_BG_WAIT_MS=7200000

# autopilot_review_budget_record <side>: records the plan's Budget as <side>'s
# review budget, each read and write orch.sh run in <side>, so the plan is read
# for that checkout's issue. Run it contained (autopilot_pickup_contained): it
# changes directory, and a failed step fails with the step's own reason.
autopilot_review_budget_record() {
  local budget
  cd "$1" || return
  budget="$("$(autopilot_self)" autopilot budget)" || return
  autopilot_orch_in "$1" state set budget "$budget"
}

# autopilot_claim_release_only <issue> <fallback phase> <closing>: the claim
# release after a read that met a GitHub limit, no session having run. The log
# is named by the claim's own phase, else <fallback phase>. It waits out the
# GitHub pause, then runs standing_claim_release through autopilot_stop_attempts
# with <closing> ending its backstop line; the chain's failure is ignored.
autopilot_claim_release_only() {
  local issue="$1" phase log
  standing_claims_read --quiet || true
  phase="${STANDING_CLAIM_PHASE[$issue]:-$2}"
  log="$(liveness_log_path "$issue" "$phase")" || exit $?
  autopilot_github_pause_wait
  autopilot_stop_attempts "$log" "$3" standing_claim_release "$issue" || true
}

# autopilot_run <issue>: the session wrapper a tick starts: runs the headless
# session in the issue's side checkout, its output in the session log, and
# hands over to autopilot_session_end once it exits.
autopilot_run() {
  local issue="$1" main_root side recorded phase mode launcher log prompt rc=0 mine name iteration hit usage_before usage flags=()
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  autopilot_mode_require; mode="$AUTOPILOT_VALUE"
  main_root="$(main_checkout_or_die)" || exit $?
  side="$(side_checkout_for_issue "$issue")" || die "no side checkout records issue #$issue"
  recorded="$(state_get_in "$(flow_state_file "$side")" phase)" || autopilot_read_die phase "$side" $?
  # Marked before the start-up read: a GitHub limit it meets writes the pause.
  export ORCH_AUTOPILOT_RUN=1
  # The run record is made once, before the start-up read, so stale cleanup sees
  # a live session throughout. A later run of the same issue may have replaced
  # it by the time this one exits: liveness_run_end removes it only while it
  # still names this run.
  liveness_run_begin "$issue" || exit 1
  # shellcheck disable=SC2064
  trap "liveness_run_end '$issue'" EXIT
  # a sync request is told by orch:sync on a done issue; its phase word is sync
  if ! standing_read "$issue"; then
    # A read that met a GitHub limit (a pause holds once it has failed) runs no
    # session and makes no stop: only the claim is released, through the retry
    # chain. Any other failure dies as before.
    if autopilot_github_paused; then
      autopilot_claim_release_only "$issue" "$recorded" "no session ran: the start-up read met a GitHub limit"
      return 0
    fi
    gh_die "read issue #$issue" "$STANDING_REASON"
  fi
  prompt="Run the orchestrator:orch-flow skill's Next phase in this checkout: do the phase it names, and stop when the phase is finished."
  phase="$recorded"
  if [ "$recorded" = "done" ] && standing_is_sync; then
    phase="$(standing_session_phase)"
    prompt="Run the orchestrator:orch-sync skill's autopilot branch in this checkout: sync the branch with its base, and stop when the sync is finished."
  fi
  hit="$(liveness_hit_path "$issue")" || exit $?
  # The claim this run was started for: a session that releases it may exit
  # after the next phase's claim is made, and that one is not this run's to
  # fail.
  standing_claims_read
  mine="$(standing_claim_fields "$issue")" || mine=""
  if [ "$phase" = review ]; then
    iteration="$(state_get_in "$(flow_state_file "$side")" iteration)" || autopilot_read_die iteration "$side" $?
    if [ "$iteration" = 0 ]; then
      # A first-loop review session is not asked its budget: the plan's is
      # recorded, over any left by a loop before a redo.
      autopilot_pickup_contained autopilot_review_budget_record "$side" ||
        { standing_stop "$issue" failure review "could not record the plan's Budget as the review budget: $PICKUP_REASON"; return 0; }
    fi
  fi
  for name in model effort; do
    autopilot_setting "$name"
    if [ "$AUTOPILOT_SOURCE" != unset ] && [ "$AUTOPILOT_VALUE" != inherit ]; then flags+=("--$name" "$AUTOPILOT_VALUE"); fi
  done
  log="$(liveness_log_path "$issue" "$phase")" || exit $?
  usage_before="$(autopilot_github_quota)" || usage_before=""
  launcher="${ORCH_AUTOPILOT_LAUNCHER:-claude}"
  ( cd "$side" && ORCH_AUTOPILOT=1 ORCH_AUTOPILOT_HIT_FILE="$hit" CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS=1 CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$AUTOPILOT_BG_WAIT_MS" "$launcher" -p "$prompt" --permission-mode "$mode" ${flags[@]+"${flags[@]}"} \
      --tools "$AUTOPILOT_TOOLS" --settings "$AUTOPILOT_SETTINGS" \
      --strict-mcp-config --exclude-dynamic-system-prompt-sections \
      --append-system-prompt "$AUTOPILOT_SYSTEM_PROMPT" \
      --output-format stream-json --verbose ) >"$log" 2>&1 || rc=$?
  if usage="$(autopilot_github_usage "$usage_before")"; then printf 'autopilot run: GitHub API usage this session: %s\n' "$usage" >>"$log"; fi
  autopilot_session_end "$issue" "$phase" "$log" "$rc" "$mine"
}

# --- watch (#1459) ------------------------------------------------------------

AUTOPILOT_WATCH_EVERY_DEFAULT=60

# autopilot_watch_stop_child: the watch's INT/TERM step for what it is waiting
# on, the running tick or the sleep: sends it TERM and waits for it to exit.
AUTOPILOT_WATCH_CHILD=""
autopilot_watch_stop_child() {
  [ -z "$AUTOPILOT_WATCH_CHILD" ] && return 0
  kill -TERM "$AUTOPILOT_WATCH_CHILD" 2>/dev/null || true
  wait "$AUTOPILOT_WATCH_CHILD" 2>/dev/null || true
}

# autopilot_watch <seconds>: repeats tick every <seconds> until interrupted.
# Refuses while another watch of this clone is alive, replaces a pidfile whose
# pid is dead, reports a failed tick on stderr and carries on, and removes its
# pidfile when interrupted. Each tick is a fresh orch.sh process, so a tick
# that dies takes nothing else with it.
autopilot_watch() {
  local every="$1" rc
  liveness_watch_begin || return 1
  trap "liveness_watch_end; autopilot_watch_stop_child; exit 0" INT TERM
  trap "liveness_watch_end" EXIT
  while :; do
    rc=0
    "$(autopilot_self)" autopilot tick >/dev/null &
    AUTOPILOT_WATCH_CHILD=$!
    wait "$AUTOPILOT_WATCH_CHILD" || rc=$?
    AUTOPILOT_WATCH_CHILD=""
    [ "$rc" = 0 ] || warn "autopilot watch: the tick failed (exit $rc); trying again in ${every}s"
    sleep "$every" &
    AUTOPILOT_WATCH_CHILD=$!
    wait "$AUTOPILOT_WATCH_CHILD" || true
    AUTOPILOT_WATCH_CHILD=""
  done
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
      standing_start "$1" "$2"
      ;;
    candidates) autopilot_candidates_run "$@" ;;
    tick)
      [ $# -eq 0 ] || die "usage: orch.sh autopilot tick"
      autopilot_gate
      export ORCH_AUTOPILOT_TICK=1
      autopilot_tick
      ;;
    watch)
      local every="$AUTOPILOT_WATCH_EVERY_DEFAULT"
      case "${1:-}" in
        "") ;;
        --every)
          [ $# -eq 2 ] || die "usage: orch.sh autopilot watch [--every <seconds>]"
          every="$2"; shift 2 ;;
        *) die "usage: orch.sh autopilot watch [--every <seconds>]" ;;
      esac
      [ $# -eq 0 ] || die "usage: orch.sh autopilot watch [--every <seconds>]"
      is_positive_int "$every" ||
        die "--every must be a positive whole number of seconds, got: $every"
      autopilot_gate
      autopilot_watch "$((10#$every))"
      ;;
    run)
      [ $# -eq 1 ] || die "usage: orch.sh autopilot run <issue>"
      autopilot_run "$1"
      ;;
    questions)
      [ $# -eq 0 ] || die "usage: orch.sh autopilot questions"
      autopilot_questions
      ;;
    reply)
      [ $# -eq 2 ] || die "usage: orch.sh autopilot reply <issue> <file>"
      autopilot_reply "$1" "$2"
      ;;
    resume)
      [ $# -eq 1 ] || die "usage: orch.sh autopilot resume <issue>"
      autopilot_resume "$1"
      ;;
    sync)
      [ $# -eq 1 ] || die "usage: orch.sh autopilot sync <issue>"
      autopilot_sync "$1"
      ;;
    sync-finish)
      [ $# -eq 0 ] || die "usage: orch.sh autopilot sync-finish"
      autopilot_sync_finish
      ;;
    sync-dropped)
      [ $# -eq 1 ] || die "usage: orch.sh autopilot sync-dropped <file>"
      autopilot_sync_dropped "$1"
      ;;
    sync-fail)
      [ $# -eq 1 ] || die "usage: orch.sh autopilot sync-fail <reason>"
      autopilot_sync_fail "$1"
      ;;
    reenter)
      [ $# -eq 2 ] || die "usage: orch.sh autopilot reenter <phase> <file>"
      autopilot_reenter "$1" "$2"
      ;;
    ask|answer)
      [ $# -eq 2 ] || die "usage: orch.sh autopilot $op <phase> <file>"
      "autopilot_$op" "$1" "$2"
      ;;
    *) die "unknown autopilot op: ${op:-<none>} (want show|active|rounds|budget|start|candidates|tick|watch|run|ask|answer|reenter|questions|reply|resume|sync|sync-finish|sync-dropped|sync-fail)" ;;
  esac
}
