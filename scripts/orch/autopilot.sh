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
  handoff_comment_fetch "$issue" 01-plan "$file" || { rm -f "$file"; handoff_missing "$issue" 01-plan; }
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

# autopilot_answer <phase> <file>: writes <phase>'s newest question comment,
# marker stripped, and every comment after it to <file>, each later one after a
# `---` line. Exits 1, writing nothing, when no comment follows the question -
# the caller re-asks, or carries on - and 2 on any other failure, so a failed
# read is never taken for no reply.
autopilot_answer() {
  local phase="$1" file="$2" issue json out first rest rc=0
  autopilot_phase_arg "$phase" die2
  require_state die2
  require_issue issue die2
  gh_or_die --exit 2 --out json "read the comments of issue #$issue" adapter_issue_json "$issue"
  # The stripped body is read with a sentinel so its trailing newlines survive
  # into the `---` join.
  first="$(marked_comment_body question "$phase" <<<"$json"; rc=$?; printf x; exit "$rc")" || rc=$?
  [ "$rc" -ne 1 ] || die2 "issue #$issue has no $phase question comment"
  [ "$rc" -eq 0 ] || die2 "could not read issue #$issue's comments"
  first="${first%x}"
  rc=0
  marked_comment_follows question "$phase" <<<"$json" || rc=$?
  [ "$rc" -ne 1 ] || die "no reply to the $phase question on issue #$issue yet"
  [ "$rc" -eq 0 ] || die2 "could not read issue #$issue's comments"
  rest="$(marked_comment_at -j '
    marked_comment_list[$i + 1:] | map("\n---\n" + .body) | join("")' question "$phase" <<<"$json")" || die2 "could not read issue #$issue's comments"
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
  local issue="$1" file="$2" json rc
  is_positive_int "$issue" || die "not an issue number: $issue"
  [ -f "$file" ] || die "reply file not found: $file"
  [ -s "$file" ] || die "reply file is empty: $file"
  standing_human_guard "$issue"
  gh_or_die --out json "read the comments of issue #$issue" adapter_issue_comments_json "$issue"
  marked_comment_newest question <<<"$json" >/dev/null || die "issue #$issue has no question comment to reply to"
  rc=0
  marked_comment_follows question <<<"$json" || rc=$?
  [ "$rc" -ne 2 ] || die "could not read issue #$issue's comments"
  [ "$rc" -ne 0 ] || die "a comment already follows the newest question on issue #$issue"
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
  local list n phase json line lines=""
  list="$(standing_human_issues)" || exit $?
  for n in $(printf '%s\n' "$list" | sort -n); do
    standing_read "$n" || gh_die "read the labels of issue #$n" "$STANDING_REASON"
    phase="$STANDING_PHASE"
    [ -n "$phase" ] || continue
    gh_or_die --out json "read the comments of issue #$n" adapter_issue_comments_json "$n"
    line="$(jq -r --arg n "$n" --arg phase "$phase" "$(marked_comment_jq)$STANDING_STOP_JQ"'
      marked_comment_list | length as $len
      | marked_comment_entries as $e
      | ($e | map(select(.info.kind == "question")) | last) as $q
      | ($e | map(select(.info | standing_is_stop)) | last) as $s
      | if $q != null and ($s == null or $q.key > $s.key) then
          [$n, (if $q.key == $len - 1 then "question" else "replied" end), $q.info.arg, $q.c.url]
        elif $s != null then [$n, "stop", $s.info.arg, $s.c.url]
        else [$n, "stop", $phase, ""] end
      | @tsv' <<<"$json")" || die "could not read issue #$n's comments"
    lines+="$line"$'\n'
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
# pidfiles, the session logs and the limit file - under its main checkout.
autopilot_dir() { printf '%s/%s/autopilot\n' "$1" "$ORCH_DIR_NAME"; }

# autopilot_proc_start <pid>: the process's start time as one whitespace-free
# token - /proc/<pid>/stat field 22 under $ORCH_PROC_DIR (default /proc), else
# `ps -o lstart=` with its spaces turned to underscores. Fails when unreadable.
autopilot_proc_start() {
  local pid="$1" root="${ORCH_PROC_DIR:-/proc}" stat rest t
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if [ -r "$root/$pid/stat" ]; then
    stat="$(cat "$root/$pid/stat" 2>/dev/null)" || stat=""
    rest="${stat##*) }"
    # shellcheck disable=SC2086
    set -- $rest
    # after the command name, field 22 is the 20th word
    [ -n "${20:-}" ] || return 1
    printf '%s\n' "${20}"
    return 0
  fi
  t="$(ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
  t="$(printf '%s' "$t" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/_/g')"
  [ -n "$t" ] || return 1
  printf '%s\n' "$t"
}

# autopilot_pid_write <pid> <file>: writes the process's record,
# `<pid> <start-time>`, to the file. Fails with an orch: line when the start
# time cannot be read.
autopilot_pid_write() {
  local pid="$1" file="$2" start
  start="$(autopilot_proc_start "$pid")" || { warn "could not read the start time of pid $pid"; return 1; }
  printf '%s %s\n' "$pid" "$start" >"$file"
}

# autopilot_record_alive <record>: whether the record's process is running with
# the recorded start time. A bare-pid or malformed record is stale.
autopilot_record_alive() {
  local pid start extra now
  read -r pid start extra <<<"${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] && [ -n "$start" ] && [ -z "${extra:-}" ] || return 1
  now="$(autopilot_proc_start "$pid")" || return 1
  [ "$now" = "$start" ]
}

# autopilot_record_is_me <record>: whether the record names the calling
# process ($$).
autopilot_record_is_me() {
  [ "${1%% *}" = "$$" ] && autopilot_record_alive "$1"
}

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

# autopilot_in_subshell <command...>: runs the command in a subshell, so a die
# inside it fails only the step and a cd never reaches the tick's shell.
autopilot_in_subshell() { ( "$@" ); }

# autopilot_pickup_step <issue> <phase> <kind> <detail> <command...>:
# runs one step of pickup in pickup's own shell, so the command may set pickup's
# variables; a step that sets none runs through autopilot_in_subshell.
# A failed step stops the issue through standing_stop as <kind>
# (refusal or failure) and returns 1. The stop detail is "<detail>: <reason>",
# the reason the first line of the command's stderr ("gh gave no reason" when
# it said nothing). When the stderr's temp file cannot be made, the command is
# not run and the stop's reason says so. The command's fd 3 is the tick's own
# stderr, for a step whose stderr is no part of the stop wording.
autopilot_pickup_step() {
  local issue="$1" phase="$2" kind="$3" detail="$4" errf err
  shift 4
  errf="$(mktemp)" || {
    standing_stop "$issue" "$kind" "$phase" "$detail: could not create a temp file for the step's stderr"
    return 1
  }
  if "$@" 3>&2 2>"$errf"; then rm -f "$errf"; return 0; fi
  file_read err "$errf" || err=""
  rm -f "$errf"
  standing_stop "$issue" "$kind" "$phase" "$detail: $(gh_reason "$err")"
  return 1
}

# autopilot_pickup_side_find <issue>: finds the issue's side checkout, into
# pickup's side - empty when it has none. It never fails, so pickup calls it
# directly, outside autopilot_pickup_step.
autopilot_pickup_side_find() {
  side="$(side_checkout_for_issue "$1")" || side=""
}

# autopilot_pickup_side_title <issue>: the step reading the title of an issue
# with no side checkout, into pickup's title; its reason goes on stderr.
autopilot_pickup_side_title() {
  # labels is the read's throwaway half.
  # shellcheck disable=SC2034
  local labels gh_err
  issue_title_labels_read "$1" title labels gh_err || {
    echo "$gh_err" >&2
    return 1
  }
}

# autopilot_pickup_side_add <issue> <title>: the step adding the issue's side
# checkout, into pickup's side; its reason goes on stderr. The slug and
# main-checkout lookups send theirs to fd 3, the tick's, never the stop.
autopilot_pickup_side_add() {
  local issue="$1" slug gh_err
  slug="$(autopilot_short_slug "$2" 2>&3)"
  # a clash with any entry of the side checkouts directory takes the issue
  [ ! -e "$(side_checkouts_dir "$(main_checkout 2>&3)")/$slug" ] || slug="$slug-$issue"
  capture side gh_err cmd_side_checkout_add "$slug" --issue "$issue" || {
    echo "$gh_err" >&2
    return 1
  }
}

# autopilot_pickup_init <issue> <side>: the step initialising a side checkout
# that holds no flow yet.
autopilot_pickup_init() {
  checkout_has_flow "$2" || autopilot_orch_in "$2" init "$(basename "$2")" --issue "$1"
}

# autopilot_pickup_recorded <side>: the step reading the side checkout's
# recorded phase, into pickup's recorded.
autopilot_pickup_recorded() {
  recorded="$(state_get_in "$(flow_state_file "$1")" phase)"
}

# autopilot_pickup_redo <side> <redo>: the step redoing a phase.
autopilot_pickup_redo() {
  ORCH_AUTOPILOT=1 autopilot_orch_in "$1" redo "$2"
}

# autopilot_pickup <issue> <phase> [limited]: steps 2 to 5 of a tick for a
# claimed issue. A refusal or a failed step ends in standing_stop and returns
# 0: the claim is released, the tick goes on.
autopilot_pickup() {
  local issue="$1" phase="$2" limited="${3:-}" side="" title="" recorded redo begin_err
  autopilot_pickup_side_find "$issue"
  if [ -z "$side" ]; then
    autopilot_pickup_step "$issue" "$phase" failure "step side-checkout add failed: could not read the issue's title" autopilot_pickup_side_title "$issue" || return 0
    autopilot_pickup_step "$issue" "$phase" failure "step side-checkout add failed" autopilot_pickup_side_add "$issue" "$title" || return 0
  fi
  autopilot_pickup_step "$issue" "$phase" failure "step init failed" autopilot_in_subshell autopilot_pickup_init "$issue" "$side" || return 0
  autopilot_pickup_step "$issue" "$phase" failure "step minimal plan comment failed" autopilot_in_subshell autopilot_post_minimal_plan "$issue" || return 0
  autopilot_pickup_step "$issue" "$phase" failure "step reading the recorded phase failed" autopilot_pickup_recorded "$side" || return 0
  if [ "$recorded" != "$phase" ]; then
    redo="$(standing_redo_phase "$phase" "$recorded")" || {
      standing_stop "$issue" refusal "$phase" "the issue is labelled $(standing_phase_label "$phase"), but its side checkout last moved to phase $recorded - only a step back from review to implement or from implement to spec is a redo"
      return 0
    }
    autopilot_pickup_step "$issue" "$phase" refusal "redo $redo refused" autopilot_in_subshell autopilot_pickup_redo "$side" "$redo" || return 0
  fi
  capture_err begin_err standing_begin "$issue" "$limited" || {
    standing_stop "$issue" failure "$phase" "$(gh_reason "$begin_err")"
    return 0
  }
  autopilot_spawn_run "$issue"
}

# autopilot_tick_record <issue>: right after a tick takes a claim, writes its
# own record to run/<issue>.tick, overwriting an older one. A failed write warns
# and carries on: with no record, the claim's process counts as gone.
autopilot_tick_record() {
  local dir
  dir="$(autopilot_dir "$(pwd)")/run"
  { mkdir -p "$dir" && autopilot_pid_write "$$" "$dir/$1.tick"; } 2>/dev/null ||
    warn "could not write the tick record for issue #$1"
  return 0
}

# autopilot_cleanup_stale <main-root>: every claim of this host whose process is
# gone is a failure: needs-human, a comment, then the claim released. The
# process is named by the run pidfile's record or - with none - the tick's
# run/<issue>.tick record; with neither, it counts as gone. Both files go with
# the claim. Other hosts' claims are never touched.
autopilot_cleanup_stale() {
  local main_root="$1" issue phase run_dir pidfile tickfile record log detail me gone_pid
  me="$(standing_host_id)"
  run_dir="$(autopilot_dir "$main_root")/run"
  standing_claims_read
  for issue in ${STANDING_CLAIM_ISSUES[@]+"${STANDING_CLAIM_ISSUES[@]}"}; do
    [ "${STANDING_CLAIM_HOST[$issue]}" = "$me" ] || continue
    phase="${STANDING_CLAIM_PHASE[$issue]}"
    pidfile="$run_dir/$issue.pid" tickfile="$run_dir/$issue.tick"
    record=""
    if [ -f "$pidfile" ]; then record="$(cat "$pidfile")"
    elif [ -f "$tickfile" ]; then record="$(cat "$tickfile")"; fi
    gone_pid="${record%% *}"
    ! autopilot_record_alive "$record" || continue
    detail="the session's process (pid ${gone_pid:-unknown}) is gone and the claim was never released - no exit code is known"
    log="$(ls -1 "$(autopilot_dir "$main_root")/logs/$issue-$phase-"*.log 2>/dev/null | tail -n 1)" || true
    if [ -n "$log" ]; then detail="$detail; log: $log"; else detail="$detail; no session log"; fi
    standing_stop "$issue" failure "$phase" "$detail"
    rm -f "$pidfile" "$tickfile"
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
  autopilot_cleanup_stale "$main_root"
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
    autopilot_tick_record "$issue"
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

# autopilot_session_end <log> <held> <outcome_var> <reset_var> <early_var>
# <limit_var>: how a phase session ended, each result set with printf -v in the
# caller's variable of the name given. <held> is 1 while the session's claim is
# still held, 0 once released. The outcome is released (<held> is 0, whatever
# the log holds), else limited (the log's last rate_limit_event has a rejecting
# window, or failing that its text holds the usage-limit message), else
# failure. The reset is the reset the session named as a UTC timestamp, empty
# unless limited or when none is named. The early pause is the five-hour
# window's resetsAt as a UTC timestamp when its utilization is 0.9 or more,
# whatever the outcome, else empty. The limit pause is set only when limited:
# the reset, or one hour on. It makes no GitHub call and writes nothing.
autopilot_session_end() {
  local session_end_log="$1" session_end_held="$2" session_end_event="" session_end_early_epoch session_end_reject_epoch
  local session_end_outcome=failure session_end_reset="" session_end_early="" session_end_limit=""
  session_end_event="$(autopilot_log_last_event "$session_end_log" rate_limit_event)"
  if [ -n "$session_end_event" ] && session_end_early_epoch="$(autopilot_event_five_hour_reset "$session_end_event")"; then
    session_end_early="$(autopilot_epoch_iso "$session_end_early_epoch")"
  fi
  if [ "$session_end_held" = 0 ]; then
    session_end_outcome=released
  else
    if [ -n "$session_end_event" ] && session_end_reject_epoch="$(autopilot_event_rejecting_reset "$session_end_event")"; then
      session_end_outcome=limited
      [ -z "$session_end_reject_epoch" ] || session_end_reset="$(autopilot_epoch_iso "$session_end_reject_epoch")"
    elif session_end_reset="$(autopilot_limit_reset "$session_end_log")"; then
      session_end_outcome=limited
    fi
    if [ "$session_end_outcome" = limited ]; then
      session_end_limit="$session_end_reset"
      [ -n "$session_end_limit" ] || session_end_limit="$(autopilot_epoch_iso "$(( $(date +%s) + 3600 ))")"
    fi
  fi
  printf -v "$3" '%s' "$session_end_outcome"
  printf -v "$4" '%s' "$session_end_reset"
  printf -v "$5" '%s' "$session_end_early"
  printf -v "$6" '%s' "$session_end_limit"
  return 0
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
# when the claim is still held at its exit, runs the failure handling. A
# session that released its claim is left alone whatever its exit code.
autopilot_run() {
  local issue="$1" main_root side phase mode launcher dir log pidfile prompt rc=0 held=0 outcome reset early limit detail released_note mine claim_after name flags=()
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  autopilot_mode_require; mode="$AUTOPILOT_VALUE"
  main_root="$(main_checkout_or_die)" || exit $?
  side="$(side_checkout_for_issue "$issue")" || die "no side checkout records issue #$issue"
  phase="$(state_get_in "$(flow_state_file "$side")" phase)" || die "could not read the recorded phase of $side"
  dir="$(autopilot_dir "$main_root")"
  mkdir -p "$dir/run" "$dir/logs" || die "could not create $dir"
  pidfile="$dir/run/$issue.pid"
  autopilot_pid_write "$$" "$pidfile" || exit 1
  rm -f "$dir/run/$issue.tick"
  # A later run of the same issue may have replaced the pidfile by the time this
  # one exits: remove it only while it still names this run.
  # shellcheck disable=SC2064
  trap "! autopilot_record_is_me \"\$(cat '$pidfile' 2>/dev/null)\" || rm -f '$pidfile'" EXIT
  # The claim this run was started for: a session that releases it may exit
  # after the next phase's claim is made, and that one is not this run's to
  # fail.
  standing_claims_read
  mine="$(standing_claim_fields "$issue")" || mine=""
  for name in model effort; do
    autopilot_setting "$name"
    if [ "$AUTOPILOT_SOURCE" != unset ] && [ "$AUTOPILOT_VALUE" != inherit ]; then flags+=("--$name" "$AUTOPILOT_VALUE"); fi
  done
  log="$dir/logs/$issue-$phase-$(dir_stamp).log"
  launcher="${ORCH_AUTOPILOT_LAUNCHER:-claude}"
  prompt="Run the orchestrator:orch-flow skill's Next phase in this checkout: do the phase it names, and stop when the phase is finished."
  ( cd "$side" && ORCH_AUTOPILOT=1 CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS=1 CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$AUTOPILOT_BG_WAIT_MS" "$launcher" -p "$prompt" --permission-mode "$mode" ${flags[@]+"${flags[@]}"} \
      --tools "$AUTOPILOT_TOOLS" --settings "$AUTOPILOT_SETTINGS" \
      --strict-mcp-config --exclude-dynamic-system-prompt-sections \
      --output-format stream-json --verbose ) >"$log" 2>&1 || rc=$?
  standing_claims_read
  if claim_after="$(standing_claim_fields "$issue")" && { [ -z "$mine" ] || [ "$claim_after" = "$mine" ]; }; then held=1; fi
  autopilot_session_end "$log" "$held" outcome reset early limit
  # The early pause, then the limit pause: the pause store keeps the later.
  if [ -n "$early" ]; then autopilot_pause_extend "$main_root" "$early" "$log"; fi
  if [ -n "$limit" ]; then autopilot_pause_extend "$main_root" "$limit" "$log"; fi
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
  detail="the session exited with code $rc; log: $log"
  standing_stop "$issue" failure "$phase" "$detail"
}

# --- watch (#1459) ------------------------------------------------------------

AUTOPILOT_WATCH_EVERY_DEFAULT=60

# autopilot_watch_pidfile: the clone's watch pidfile, under the git common
# directory beside the suite-cost record, so every worktree of the clone
# reaches the same one.
autopilot_watch_pidfile() {
  local d
  d="$(clone_orchestrator_dir)" || return 1
  printf '%s/autopilot-watch.pid\n' "$d"
}

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
  local every="$1" pidfile other rc
  pidfile="$(autopilot_watch_pidfile)" || return 1
  if [ -f "$pidfile" ]; then
    other="$(cat "$pidfile" 2>/dev/null)" || other=""
    ! autopilot_record_alive "$other" ||
      die "another autopilot watch (pid ${other%% *}) is already running in this clone"
  fi
  mkdir -p "$(dirname "$pidfile")" || die "could not create $(dirname "$pidfile")"
  autopilot_pid_write "$$" "$pidfile" || return 1
  # shellcheck disable=SC2064
  trap "rm -f '$pidfile'; autopilot_watch_stop_child; exit 0" INT TERM
  # shellcheck disable=SC2064
  trap "rm -f '$pidfile'" EXIT
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
