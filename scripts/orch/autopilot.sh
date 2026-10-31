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
# their defaults; the model and effort stay unset, checked against the agent
# setting's Claude Code lists. Dies naming key and value when a value is out of
# range.
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
  for name in permission-mode cap handle rounds budget model effort; do
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
  local issue file value
  require_issue issue
  file="$(mktemp)" || die "could not create a temp file for the plan comment"
  handoff_comment_fetch "$issue" 01-plan "$file" || { rm -f "$file"; handoff_comment_missing "$issue" 01-plan; }
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

# autopilot_ask <phase> <file>: posts <file> as <phase>'s question comment, the
# configured handle @mentioned, adds needs-human, then releases the claim.
autopilot_ask() {
  local phase="$1" file="$2" text
  autopilot_phase_arg "$phase"
  [ -f "$file" ] || die "question file not found: $file"
  file_read text "$file" || die "could not read $file"
  standing_ask "$phase" "$text"
}

# autopilot_timeline_read <issue> [2]: timeline_read, dying when it cannot -
# status 1, or 2 when the second argument is 2. Each caller module words its own
# read failure (handoff.sh has handoff_timeline_read), so the two look alike.
autopilot_timeline_read() {
  local issue="$1" code="${2-1}"
  timeline_read "$issue" && return 0
  if [ -z "$TIMELINE_REASON" ]; then
    if [ "$code" = 2 ]; then die2 "could not read issue #$issue's comments"; fi
    die "could not read issue #$issue's comments"
  fi
  if [ "$code" = 2 ]; then gh_die --exit 2 "read the comments of issue #$issue" "$TIMELINE_REASON"; fi
  gh_die "read the comments of issue #$issue" "$TIMELINE_REASON"
}

# autopilot_answer <phase> <file>: writes <phase>'s newest question comment,
# marker stripped, and every comment after it to <file>, each later one after a
# `---` line. Exits 1, writing nothing, when no comment follows the question -
# the caller re-asks, or carries on - and 2 on any other failure, so a failed
# read is never taken for no reply.
autopilot_answer() {
  local phase="$1" file="$2" issue out first rest q
  autopilot_phase_arg "$phase" die2
  require_state die2
  require_issue issue die2
  autopilot_timeline_read "$issue" 2
  q="$(timeline_question "$phase")" || die2 "issue #$issue has no $phase question comment"
  timeline_replied "$phase" || die "no reply to the $phase question on issue #$issue yet"
  # The stripped body is read with a sentinel so its trailing newlines survive
  # into the `---` join.
  first="$(timeline_body "${q%%$'\t'*}"; printf x)"
  first="${first%x}"
  rest="$(timeline_answers "$phase")"
  out="$(printf '%s' "$first$rest")"  # as before, trailing newlines go; the file gets one
  mkdir -p "$(dirname "$file")" || die2 "could not create the directory of $file"
  printf '%s\n' "$out" >"$file" || die2 "could not write $file"
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

# autopilot_reply <issue> <file>: posts <file> as a comment on the issue, then
# removes needs-human - refused unless the label is still on and no comment
# follows the issue's newest question comment.
autopilot_reply() {
  local issue="$1" file="$2"
  is_positive_int "$issue" || die "not an issue number: $issue"
  [ -f "$file" ] || die "reply file not found: $file"
  [ -s "$file" ] || die "reply file is empty: $file"
  standing_human_guard "$issue"
  autopilot_timeline_read "$issue"
  timeline_question >/dev/null || die "issue #$issue has no question comment to reply to"
  ! timeline_replied || die "a comment already follows the newest question on issue #$issue"
  gh_or_die "post the reply on issue #$issue" adapter_issue_comment "$issue" "$file"
  standing_resume "$issue" || die "the reply comment landed on issue #$issue, but $STANDING_HUMAN_LABEL could not be removed: $STANDING_REASON"
}

# autopilot_questions: one tab-separated line per open needs-human issue that
# carries a phase label other than orch:done: the issue, its kind (question,
# replied or stop), the phase, and the URL of the comment the kind is about.
# The newest of the issue's question comments and stop comments decides the
# kind. Prints one line saying so when nothing is listed; dies, printing
# nothing, when any read fails.
autopilot_questions() {
  local list n phase q s qi si row kind q_phase url lines=""
  list="$(standing_human_issues)" || exit $?
  for n in $(printf '%s\n' "$list" | sort -n); do
    standing_read "$n" || gh_die "read the labels of issue #$n" "$STANDING_REASON"
    phase="$STANDING_PHASE"
    [ -n "$phase" ] || continue
    autopilot_timeline_read "$n"
    q="$(timeline_question)" || q=""
    s="$(timeline_stop)" || s=""
    qi="${q%%$'\t'*}" si="${s%%$'\t'*}"
    if [ -n "$q" ] && { [ -z "$s" ] || [ "$qi" -gt "$si" ]; }; then
      if timeline_replied; then kind="replied"; else kind="question"; fi
      IFS=$'\t' read -r _ q_phase url <<<"$q"
      row="$n"$'\t'"$kind"$'\t'"$q_phase"$'\t'"$url"
    elif [ -n "$s" ]; then
      IFS=$'\t' read -r _ _ q_phase url <<<"$s"
      row="$n"$'\tstop\t'"$q_phase"$'\t'"$url"
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

# Claude Code's usage-limit messages, as grep -Ei reads it: the one pattern for
# them, anchored on its own wordings - "usage limit reached", "<N>-hour limit
# reached", "weekly limit reached" - so another "limit reached" (an iteration
# limit, an API rate limit, test output) is no usage limit. After the wording
# a message may carry its reset time, as `|<epoch seconds>` or as
# `∙ resets <time>`; the others carry none.
AUTOPILOT_LIMIT_PATTERN='(usage|[0-9]+-hour|weekly) limit reached(\|[0-9]+|[^|]{0,8}resets [^|]*)?'

# autopilot_dir <main-root>: where a clone's autopilot files live - the run
# records, the session logs and the limit file - under its main checkout.
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
# description. A failed upsert dies naming the label, stopping the tick.
autopilot_labels_ensure() {
  local name colour description gh_err
  while IFS='|' read -r name colour description; do
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
  local file err st=0
  file="$(mktemp)" || {
    PICKUP_REASON="could not create a temp file for the step's stderr"
    return 1
  }
  ( "$@" ) 2>"$file" || st=$?
  file_read err "$file" || err=""
  rm -f "$file"
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
# checkout, into pickup's side.
autopilot_pickup_side_add() {
  local issue="$1" slug err st=0
  slug="$(autopilot_short_slug "$2")"
  # a clash with any entry of the side checkouts directory takes the issue
  [ ! -e "$(side_checkouts_dir "$(main_checkout)")/$slug" ] || slug="$slug-$issue"
  capture side err cmd_side_checkout_add "$slug" --issue "$issue" || st=$?
  autopilot_pickup_settle "$st" "$err"
}

# autopilot_pickup_init <issue> <side>: the step initialising a side checkout
# that holds no flow yet.
autopilot_pickup_init() {
  checkout_has_flow "$2" || autopilot_orch_in "$2" init "$(basename "$2")" --issue "$1"
}

# autopilot_pickup_recorded <side>: the step reading the side checkout's
# recorded phase, into pickup's recorded. The read's own stderr goes on to the
# tick's.
autopilot_pickup_recorded() {
  local state_file
  state_file="$(flow_state_file "$1")"
  recorded="$(state_get_in "$state_file" phase)" || {
    PICKUP_REASON="could not read the phase recorded in $state_file"
    return 1
  }
}

# autopilot_pickup_redo <side> <redo>: the step redoing a phase.
autopilot_pickup_redo() {
  ORCH_AUTOPILOT=1 autopilot_orch_in "$1" redo "$2"
}

# autopilot_pickup_steps <issue> <phase> <limited>: Pickup's steps in order, up
# to the session's start. The first that fails leaves PICKUP_KIND and
# PICKUP_TEXT and returns 1.
autopilot_pickup_steps() {
  local issue="$1" phase="$2" limited="$3" side="" title="" recorded redo
  autopilot_pickup_side_find "$issue"
  if [ -z "$side" ]; then
    autopilot_pickup_side_title "$issue" || autopilot_pickup_fail failure "step side-checkout add failed: could not read the issue's title" || return 1
    autopilot_pickup_side_add "$issue" "$title" || autopilot_pickup_fail failure "step side-checkout add failed" || return 1
  fi
  autopilot_pickup_contained autopilot_pickup_init "$issue" "$side" || autopilot_pickup_fail failure "step init failed" || return 1
  autopilot_pickup_contained autopilot_post_minimal_plan "$issue" || autopilot_pickup_fail failure "step minimal plan comment failed" || return 1
  autopilot_pickup_recorded "$side" || autopilot_pickup_fail failure "step reading the recorded phase failed" || return 1
  if [ "$recorded" != "$phase" ]; then
    redo="$(standing_redo_phase "$phase" "$recorded")" || {
      PICKUP_KIND=refusal
      PICKUP_TEXT="the issue is labelled $(standing_phase_label "$phase"), but its side checkout last moved to phase $recorded - only a step back from review to implement or from implement to spec is a redo"
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

# autopilot_pickup <issue> <phase> [limited]: steps 2 to 5 of a tick for a
# claimed issue. A refusal or a failed step ends in one standing_stop and
# returns 0: the claim is released, the tick goes on.
autopilot_pickup() {
  autopilot_pickup_steps "$1" "$2" "${3:-}" || {
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
  local issue phase log detail me gone_pid
  me="$(standing_host_id)"
  standing_claims_read
  for issue in ${STANDING_CLAIM_ISSUES[@]+"${STANDING_CLAIM_ISSUES[@]}"}; do
    [ "${STANDING_CLAIM_HOST[$issue]}" = "$me" ] || continue
    phase="${STANDING_CLAIM_PHASE[$issue]}"
    gone_pid="$(liveness_issue_alive "$issue")" && continue
    detail="the session's process (pid ${gone_pid:-unknown}) is gone and the claim was never released - no exit code is known"
    log="$(liveness_latest_log "$issue" "$phase")" || true
    if [ -n "$log" ]; then detail="$detail; log: $log"; else detail="$detail; no session log"; fi
    standing_stop "$issue" failure "$phase" "$detail"
    liveness_issue_forget "$issue"
  done
}

# The pause store: the limit file is reached only through autopilot_pause_extend
# and autopilot_pause_until, so no other function builds or reads its path.

# autopilot_pause_epoch <file>: the reset recorded in the limit file <file> as
# epoch seconds; 0 when the file is missing or its text does not parse.
autopilot_pause_epoch() {
  local text
  text="$(cat "$1" 2>/dev/null)" || text=""
  autopilot_iso_epoch "$text" || echo 0
}

# autopilot_pause_until <main>: whether a usage limit pauses pickup. While the
# limit file's reset time is in the future it prints one line naming it and
# returns 0; once it has passed, the file is removed and it returns 1.
autopilot_pause_until() {
  local file epoch
  file="$(autopilot_dir "$1")/limit"
  [ -f "$file" ] || return 1
  epoch="$(autopilot_pause_epoch "$file")"
  if [ "$epoch" -gt "$(date +%s)" ]; then
    note "usage limit: no issue is picked up until $(cat "$file")"
    return 0
  fi
  rm -f "$file"
  return 1
}

# autopilot_pause_extend <main> <iso> <log>: records the UTC timestamp <iso>
# as the limit file's reset under <main>, keeping one already there that is
# later and replacing one that is earlier or does not parse. A failed write is
# noted in <log> and on stderr, and is no failure of the caller.
autopilot_pause_extend() {
  local file log="$3" old_epoch new_epoch msg
  file="$(autopilot_dir "$1")/limit"
  new_epoch="$(autopilot_iso_epoch "$2")" || new_epoch=0
  if [ -f "$file" ]; then
    old_epoch="$(autopilot_pause_epoch "$file")"
    [ "$old_epoch" -lt "$new_epoch" ] || return 0
  fi
  if ! { printf '%s\n' "$2" >"$file"; } 2>/dev/null; then
    msg="autopilot run: could not write the limit file $file"
    warn "$msg"
    printf '%s\n' "$msg" >>"$log"
  fi
  return 0
}

# autopilot_candidates: the open issues carrying a phase label other than
# orch:done, oldest first, one number per line.
autopilot_candidates() {
  local phase out gh_err all=""
  for phase in $PHASES; do
    [ "$phase" != "done" ] || continue
    capture out gh_err adapter_issues_labelled "$(standing_phase_label "$phase")" ||
      die "could not list the issues labelled $(standing_phase_label "$phase"): $(gh_reason "$gh_err")"
    all="$all$out"$'\n'
  done
  printf '%s' "$all" | grep -v '^$' | sort -nu || true
}

# autopilot_tick: one pass - labels, stale claims, then pickup (see the spec's
# One tick). A claim create that fails for a reason other than a lost race
# stops the tick, naming it.
autopilot_tick() {
  local main_root cap count issue gh_err phase rc candidates limited_arg
  autopilot_setting cap; cap="$AUTOPILOT_VALUE"
  main_root="$(main_checkout_or_die)" || exit $?
  cd "$main_root" || die "could not enter the main checkout $main_root"
  autopilot_labels_ensure
  autopilot_cleanup_stale
  if autopilot_pause_until "$main_root"; then return 0; fi
  standing_claims_read
  count="${#STANDING_CLAIM_ISSUES[@]}"
  candidates="$(autopilot_candidates)"
  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    [ "$count" -lt "$cap" ] || break
    standing_read "$issue" ||
      die "could not read issue #$issue: $STANDING_REASON"
    standing_pickable || continue
    phase="$STANDING_PHASE"
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
    if [ "$STANDING_LIMITED" = 1 ]; then limited_arg=limited; fi
    autopilot_pickup "$issue" "$phase" "$limited_arg"
  done <<<"$candidates"
}

# autopilot_resets_epoch <text>: the next moment, in local time and as epoch
# seconds, of the `resets [<weekday>] <h>[:<mm>]<am|pm>` time in <text>, such
# as "resets 3pm" or "resets Mon 9am"; non-zero, nothing printed, when <text>
# holds none. A time already past today is the same time tomorrow, or, with a
# weekday, a week on at most.
autopilot_resets_epoch() {
  local text re day="" h m ap now_epoch since target_since target clock shift_secs ahead cur i d
  text="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  re='resets[[:space:]]+(([a-z]{3})[a-z]*[[:space:]]+)?([0-9]{1,2})(:([0-9]{2}))?[[:space:]]*(am|pm)'
  [[ "$text" =~ $re ]] || return 1
  day="${BASH_REMATCH[2]}"; h="$((10#${BASH_REMATCH[3]}))"; m="$((10#${BASH_REMATCH[5]:-0}))"; ap="${BASH_REMATCH[6]}"
  [ "$h" -ge 1 ] && [ "$h" -le 12 ] && [ "$m" -le 59 ] || return 1
  [ "$ap" = pm ] && [ "$h" -ne 12 ] && h=$((h + 12))
  [ "$ap" = am ] && [ "$h" -eq 12 ] && h=0
  now_epoch="$(date +%s)"
  since="$(( 10#$(date +%H) * 3600 + 10#$(date +%M) * 60 + 10#$(date +%S) ))"
  target="$(( now_epoch - since + h * 3600 + m * 60 ))"
  if [ -n "$day" ]; then
    ahead=""
    cur="$(date +%u)"
    i=0
    for d in mon tue wed thu fri sat sun; do
      i=$((i + 1))
      [ "$d" != "$day" ] || ahead="$(( (i - cur + 7) % 7 ))"
    done
    [ -n "$ahead" ] || return 1
    target=$((target + ahead * 86400))
    [ "$target" -gt "$now_epoch" ] || target=$((target + 7 * 86400))
  else
    [ "$target" -gt "$now_epoch" ] || target=$((target + 86400))
  fi
  # A clock change between now and then shifts the hour: pull the target back to
  # the wanted local time of day.
  clock="$(date -d "@$target" +%H:%M:%S 2>/dev/null || date -r "$target" +%H:%M:%S)"
  target_since="$(( 10#${clock:0:2} * 3600 + 10#${clock:3:2} * 60 + 10#${clock:6:2} ))"
  shift_secs="$(( h * 3600 + m * 60 - target_since ))"
  [ "$shift_secs" -le 43200 ] || shift_secs=$((shift_secs - 86400))
  [ "$shift_secs" -ge -43200 ] || shift_secs=$((shift_secs + 86400))
  printf '%s\n' "$((target + shift_secs))"
}

# autopilot_log_last_event <log> <type>: the last line of <log> that parses as a
# JSON object of that "type", compact; nothing when there is none. The log is
# NDJSON with plain-text lines mixed in, which this skips.
autopilot_log_last_event() {
  jq -cR --arg type "$2" 'fromjson? | select(type == "object" and .type == $type)' "$1" 2>/dev/null | tail -n 1
}

# autopilot_log_text <log>: the text of <log> the usage-limit message parse
# reads: its lines that do not parse as JSON, and the result text of its last
# result event - never an assistant message or a tool result.
autopilot_log_text() {
  jq -rR '. as $line | try (fromjson | empty) catch $line' "$1" 2>/dev/null || true
  autopilot_log_last_event "$1" result | jq -r '.result // empty | strings' 2>/dev/null || true
}

# autopilot_event_rejecting_reset <event>: returns 0 when the rate_limit_event
# has a window - the top level one or one under unifiedWindows - whose status is
# neither allowed nor allowed_warning, printing the latest resetsAt among them
# as epoch seconds (nothing when none carries one); 1 when it has none.
autopilot_event_rejecting_reset() {
  local out
  out="$(jq -r '.rate_limit_info // {} | [., (.unifiedWindows // {} | .[])]
    | map(select(type == "object" and ((.status // "allowed") | IN("allowed", "allowed_warning") | not)))
    | if length == 0 then "none" else ([.[].resetsAt | numbers | floor] | max // "") end' <<<"$1" 2>/dev/null)" || return 1
  [ "$out" != none ] || return 1
  printf '%s\n' "$out"
}

# autopilot_event_five_hour_reset <event>: the five_hour window's resetsAt, as
# epoch seconds, when its utilization is 0.9 or more; non-zero otherwise.
autopilot_event_five_hour_reset() {
  local out
  out="$(jq -r '.rate_limit_info // {} | (if .rateLimitType == "five_hour" then . else .unifiedWindows.five_hour end) // {} | select((.utilization | numbers) >= 0.9) | .resetsAt | numbers | floor' <<<"$1" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# autopilot_limit_reset <log>: returns 0 when <log> text (autopilot_log_text)
# holds Claude Code's usage-limit message, printing its reset time as a UTC
# timestamp when the message gives one - an epoch, or a `resets <time>` that
# autopilot_resets_epoch reads; 1 when the log holds no usage-limit message.
autopilot_limit_reset() {
  local hit epoch
  hit="$(autopilot_log_text "$1" | grep -Eio "$AUTOPILOT_LIMIT_PATTERN" | tail -n 1)" || true
  [ -n "$hit" ] || return 1
  case "$hit" in
    *'|'*) autopilot_epoch_iso "${hit##*|}" ;;
    *)
      if epoch="$(autopilot_resets_epoch "$hit")"; then autopilot_epoch_iso "$epoch"; fi ;;
  esac
  return 0
}

# autopilot_session_end <issue> <phase> <log> <rc> <mine>: applies the whole
# consequence of a phase session's end. <mine> is the claim fields read before
# the session ("" when there was none). It reads origin's claims again: the
# session is held when the issue has a claim and either <mine> is empty or the
# claim's fields equal <mine>, else released (the claim was released, or the
# next phase's took its place). The outcome is released (not held, whatever the
# log holds), else limited (the log's last rate_limit_event has a rejecting
# window, or failing that its text holds the usage-limit message), else
# failure. The limit pause is the reset the session named, or one hour on; the
# early pause is the five-hour window's resetsAt when its utilization is 0.9 or
# more, whatever the outcome. The pause store is extended once, with the later
# of the two. Then it gives the released note, the limit stop or the failure
# stop. It dies, before any write, when the checkout or the claims cannot be
# read.
autopilot_session_end() {
  local issue="$1" phase="$2" log="$3" rc="$4" mine="$5" main_root claim_after held=0
  local event="" early_epoch reject_epoch outcome=failure reset="" early="" limit="" pause released_note
  main_root="$(main_checkout_or_die)" || exit $?
  standing_claims_read
  if claim_after="$(standing_claim_fields "$issue")" && { [ -z "$mine" ] || [ "$claim_after" = "$mine" ]; }; then held=1; fi
  event="$(autopilot_log_last_event "$log" rate_limit_event)"
  if [ -n "$event" ] && early_epoch="$(autopilot_event_five_hour_reset "$event")"; then
    early="$(autopilot_epoch_iso "$early_epoch")"
  fi
  if [ "$held" = 0 ]; then
    outcome=released
  else
    if [ -n "$event" ] && reject_epoch="$(autopilot_event_rejecting_reset "$event")"; then
      outcome=limited
      [ -z "$reject_epoch" ] || reset="$(autopilot_epoch_iso "$reject_epoch")"
    elif reset="$(autopilot_limit_reset "$log")"; then
      outcome=limited
    fi
    if [ "$outcome" = limited ]; then
      limit="$reset"
      [ -n "$limit" ] || limit="$(autopilot_epoch_iso "$(( $(date +%s) + 3600 ))")"
    fi
  fi
  # One write: the later of the two pauses.
  pause="$early"
  if [ -n "$limit" ] && { [ -z "$pause" ] || [ "$(autopilot_iso_epoch "$limit")" -gt "$(autopilot_iso_epoch "$pause")" ]; }; then pause="$limit"; fi
  if [ -n "$pause" ]; then autopilot_pause_extend "$main_root" "$pause" "$log"; fi
  case "$outcome" in
    released)
      released_note="autopilot run: issue #$issue's session exited $rc with its claim released"
      note "$released_note"
      printf '%s\n' "$released_note" >>"$log"
      return 0 ;;
    limited)
      standing_limit_stop "$issue" "$phase" "$reset" "$limit" "$rc" "$log"
      return 0 ;;
  esac
  standing_stop "$issue" failure "$phase" "the session exited with code $rc; log: $log"
}

# The tools a headless phase session gets: those the plugin's skills and agents
# use.
AUTOPILOT_TOOLS="Agent,Skill,Bash,Read,Edit,Write,Grep,Glob,SendMessage,AskUserQuestion"
# Its settings: no bundled skills, and no plugin-authoring, a built-in plugin
# that disableBundledSkills leaves listed.
AUTOPILOT_SETTINGS='{"disableBundledSkills":true,"enabledPlugins":{"plugin-authoring@builtin":false}}'
# How long, in ms, print mode waits for background tasks after a session's last
# turn: a ticket subagent outlives its 10-minute default, and a finite ceiling
# (2 hours) still ends a hung session, which then goes through the existing
# failure handling. Not 0: nothing else limits a session, so a hung subagent
# would hold its claim forever.
AUTOPILOT_BG_WAIT_MS=7200000

# autopilot_run <issue>: the session wrapper a tick starts: runs the headless
# session in the issue's side checkout, its output in the session log, and
# hands over to autopilot_session_end once it exits.
autopilot_run() {
  local issue="$1" main_root side phase mode launcher log prompt rc=0 mine name flags=()
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  autopilot_mode_require; mode="$AUTOPILOT_VALUE"
  main_root="$(main_checkout_or_die)" || exit $?
  side="$(side_checkout_for_issue "$issue")" || die "no side checkout records issue #$issue"
  phase="$(state_get_in "$(flow_state_file "$side")" phase)" || die "could not read the recorded phase of $side"
  liveness_run_begin "$issue" || exit 1
  # A later run of the same issue may have replaced the record by the time this
  # one exits: liveness_run_end removes it only while it still names this run.
  # shellcheck disable=SC2064
  trap "liveness_run_end '$issue'" EXIT
  # The claim this run was started for: a session that releases it may exit
  # after the next phase's claim is made, and that one is not this run's to
  # fail.
  standing_claims_read
  mine="$(standing_claim_fields "$issue")" || mine=""
  for name in model effort; do
    autopilot_setting "$name"
    if [ "$AUTOPILOT_SOURCE" != unset ] && [ "$AUTOPILOT_VALUE" != inherit ]; then flags+=("--$name" "$AUTOPILOT_VALUE"); fi
  done
  log="$(liveness_log_path "$issue" "$phase")" || exit $?
  launcher="${ORCH_AUTOPILOT_LAUNCHER:-claude}"
  prompt="Run the orchestrator:orch-flow skill's Next phase in this checkout: do the phase it names, and stop when the phase is finished."
  ( cd "$side" && ORCH_AUTOPILOT=1 CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS=1 CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$AUTOPILOT_BG_WAIT_MS" "$launcher" -p "$prompt" --permission-mode "$mode" ${flags[@]+"${flags[@]}"} \
      --tools "$AUTOPILOT_TOOLS" --settings "$AUTOPILOT_SETTINGS" \
      --strict-mcp-config --exclude-dynamic-system-prompt-sections \
      --output-format stream-json --verbose ) >"$log" 2>&1 || rc=$?
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
    tick)
      [ $# -eq 0 ] || die "usage: orch.sh autopilot tick"
      autopilot_gate
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
    ask|answer)
      [ $# -eq 2 ] || die "usage: orch.sh autopilot $op <phase> <file>"
      "autopilot_$op" "$1" "$2"
      ;;
    *) die "unknown autopilot op: ${op:-<none>} (want show|active|rounds|budget|start|tick|watch|run|ask|answer|questions|reply|resume)" ;;
  esac
}
