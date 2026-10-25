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
  local name="$1" key="orchestrator.autopilot.$1" def="" owner
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
        owner="$(repo_owner_name "$REPO_NAME")"; AUTOPILOT_VALUE="${owner%%/*}"
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

# autopilot_phase_label <phase>: the label that records an autopilot flow's
# phase on its issue, `orch:<phase>` - the label is the flow's phase record.
autopilot_phase_label() { printf 'orch:%s\n' "$1"; }

# autopilot_phase_labels_in <labels>: the phases, one per line in table order,
# whose labels are among <labels>.
autopilot_phase_labels_in() {
  local p
  for p in $PHASES; do
    ! list_has "$1" "$(autopilot_phase_label "$p")" || printf '%s\n' "$p"
  done
}

# autopilot_live_phase <labels>: the first phase other than done whose label is
# among <labels>, in table order; nothing when there is none.
autopilot_live_phase() {
  local p
  for p in $(autopilot_phase_labels_in "$1"); do
    [ "$p" != "done" ] || continue
    printf '%s\n' "$p"
    return 0
  done
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
  handoff_comment_fetch "$issue" 01-plan "$file" || { rm -f "$file"; die "issue #$issue has no 01-plan handoff comment"; }
  value="$(autopilot_block_values "$file" "$1")"
  rm -f "$file"
  is_positive_int "$value" ||
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
  local issue="$1" file="$2" ready state labels gh_err phase first
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  [ -f "$file" ] || die "plan file not found: $file"
  ready="$(triage_label_for ready-for-agent)"
  issue_state_labels_read "$issue" state labels gh_err \
    || gh_die "read issue #$issue" "$gh_err"
  list_has "$labels" "$ready" ||
    die "issue #$issue does not carry the '$ready' label - an autopilot flow starts from a ready issue"
  for phase in $(autopilot_phase_labels_in "$labels"); do
    die "issue #$issue already carries the phase label $(autopilot_phase_label "$phase") - it is already an autopilot flow"
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
AUTOPILOT_LIMITED_LABEL="orch:limited"

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
  local issue="$1" phase="$2" landed="$3" state labels gh_err p args=()
  issue_state_labels_read "$issue" state labels gh_err ||
    autopilot_chain_die "$landed" "$issue" "read the labels" "$gh_err"
  for p in $(autopilot_phase_labels_in "$labels"); do
    [ "$p" = "$phase" ] || args+=(--remove "$(autopilot_phase_label "$p")")
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

# autopilot_phase_move <issue> <phase> <landed>: a finished phase's close under
# its claim - the phase label moved to <phase>, then the recorded phase, then
# the claim released. The label moves before state.json records the phase, so
# a failure between the two leaves the label one step ahead, never behind.
autopilot_phase_move() {
  autopilot_move_label "$1" "$2" "$3"
  phase_write "$2"
  autopilot_release "$1" "${3:+$3, }moved the phase label to $(autopilot_phase_label "$2"), recorded phase $2"
}

# The first line of a question comment opens with this, then the phase, then
# " -->".
AUTOPILOT_QUESTION_PREFIX='<!-- orch:question '

# What a refusal or failure comment opens with, before the phase; autopilot_stop
# writes them and stop_phase below reads them back.
AUTOPILOT_REFUSAL_OPENING='Autopilot refused to run the '
AUTOPILOT_FAILURE_OPENING='Autopilot failed in the '

# The jq definitions every reader of a comment list shares, so the question
# marker test is written once: question_comment is true for a comment whose
# first line is a question marker (of $phase, or of any phase when $phase is
# empty); stop_phase is the phase a refusal or failure comment names, else null.
AUTOPILOT_COMMENT_JQ='
  def first_line: .body | split("\n")[0] | rtrimstr("\r");
  def question_comment($phase):
    first_line | startswith($prefix) and endswith(" -->")
      and ($phase == "" or . == $prefix + $phase + " -->");
  def newest_question($phase): map(question_comment($phase)) | rindex(true);
  def question_phase: first_line | ltrimstr($prefix) | rtrimstr(" -->");
  def stop_phase:
    first_line | first(capture("^(?:'"$AUTOPILOT_REFUSAL_OPENING|$AUTOPILOT_FAILURE_OPENING"')(?<p>[^ ]+) phase") | .p) // null;
'

# autopilot_question_marker <phase>: the first line of a question comment.
autopilot_question_marker() { printf '%s%s -->\n' "$AUTOPILOT_QUESTION_PREFIX" "$1"; }

# autopilot_phase_arg <phase> [die-fn]: dies, through die-fn (default die),
# unless <phase> is a phase a question can be asked in - a flow phase other
# than done.
autopilot_phase_arg() {
  local die_fn="${2:-die}"
  case " $PHASES " in *" $1 "*) ;; *) "$die_fn" "not a flow phase: $1 (want ${PHASES// /|})" ;; esac
  [ "$1" != "done" ] || "$die_fn" "a done flow asks no question"
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
  { autopilot_question_marker "$phase"; printf '@%s\n\n' "$AUTOPILOT_VALUE"; cat "$file"
    printf '\nReply in one comment like `1: A, 2: recommended, 3: <free text>` (`all: recommended` accepts everything).\n'; } >"$body"
  capture_err gh_err adapter_issue_comment "$issue" "$body" || { rm -f "$body"; gh_die "post the $phase question on issue #$issue" "$gh_err"; }
  rm -f "$body"
  landed="posted the $phase question comment"
  capture_err gh_err adapter_issue_relabel "$issue" --add "$AUTOPILOT_HUMAN_LABEL" ||
    autopilot_chain_die "$landed" "$issue" "add $AUTOPILOT_HUMAN_LABEL" "$gh_err"
  autopilot_release "$issue" "$landed, added $AUTOPILOT_HUMAN_LABEL"
}

# autopilot_answer <phase> <file>: writes <phase>'s newest question comment,
# marker stripped, and every comment after it to <file>, each later one after a
# `---` line. Exits 1, writing nothing, when no comment follows the question -
# the caller re-asks, or carries on - and 2 on any other failure, so a failed
# read is never taken for no reply.
autopilot_answer() {
  local phase="$1" file="$2" issue json out
  autopilot_phase_arg "$phase" die2
  require_state die2
  require_issue issue die2
  gh_or_die --exit 2 --out json "read the comments of issue #$issue" adapter_issue_json "$issue"
  out="$(jq -j --arg prefix "$AUTOPILOT_QUESTION_PREFIX" --arg phase "$phase" "$AUTOPILOT_COMMENT_JQ"'
    (.comments | newest_question($phase)) as $q
    | if $q == null then "noq" elif $q == (.comments | length) - 1 then "noreply"
      else (.comments[$q:] | map(.body) | .[0] |= (split("\n")[1:] | join("\n")) | join("\n---\n")) end' <<<"$json")" ||
    die2 "could not read issue #$issue's comments"
  case "$out" in
    noq) die2 "issue #$issue has no $phase question comment" ;;
    noreply) die "no reply to the $phase question on issue #$issue yet" ;;
  esac
  mkdir -p "$(dirname "$file")" || die2 "could not create the directory of $file"
  printf '%s\n' "$out" >"$file" || die2 "could not write $file"
}

# --- questions, reply and resume (#1571) ------------------------------------
#
# The verbs behind /orchestrator:questions. They hold no flow state: the issue
# comes from the arguments, the repo from the checkout's origin.

# autopilot_human_labelled <issue>: dies unless the issue is open and carries
# needs-human.
autopilot_human_labelled() {
  # state is read with the labels.
  local issue="$1" state labels gh_err
  issue_state_labels_read "$issue" state labels gh_err || gh_die "read issue #$issue" "$gh_err"
  [ "$state" = OPEN ] || die "issue #$issue is closed"
  list_has "$labels" "$AUTOPILOT_HUMAN_LABEL" || die "issue #$issue does not carry $AUTOPILOT_HUMAN_LABEL"
}

# autopilot_resume <issue>: removes needs-human from the issue, and nothing
# else.
autopilot_resume() {
  local issue="$1"
  is_positive_int "$issue" || die "not an issue number: $issue"
  autopilot_human_labelled "$issue"
  gh_or_die "remove $AUTOPILOT_HUMAN_LABEL from issue #$issue" adapter_issue_relabel "$issue" --remove "$AUTOPILOT_HUMAN_LABEL"
}

# autopilot_reply <issue> <file>: posts <file> as a comment on the issue, then
# removes needs-human - refused unless the label is still on and no comment
# follows the issue's newest question comment.
autopilot_reply() {
  local issue="$1" file="$2" json verdict gh_err
  is_positive_int "$issue" || die "not an issue number: $issue"
  [ -f "$file" ] || die "reply file not found: $file"
  [ -s "$file" ] || die "reply file is empty: $file"
  autopilot_human_labelled "$issue"
  gh_or_die --out json "read the comments of issue #$issue" adapter_issue_comments_json "$issue"
  verdict="$(jq -r --arg prefix "$AUTOPILOT_QUESTION_PREFIX" "$AUTOPILOT_COMMENT_JQ"'
    newest_question("") as $q
    | if $q == null then "noq" elif $q != length - 1 then "followed" else "ok" end' <<<"$json")" ||
    die "could not read issue #$issue's comments"
  case "$verdict" in
    noq) die "issue #$issue has no question comment to reply to" ;;
    followed) die "a comment already follows the newest question on issue #$issue" ;;
  esac
  gh_or_die "post the reply on issue #$issue" adapter_issue_comment "$issue" "$file"
  capture_err gh_err adapter_issue_relabel "$issue" --remove "$AUTOPILOT_HUMAN_LABEL" ||
    die "the reply comment landed on issue #$issue, but $AUTOPILOT_HUMAN_LABEL could not be removed: $(gh_reason "$gh_err")"
}

# autopilot_questions: one tab-separated line per open needs-human issue that
# carries a phase label other than orch:done: the issue, its kind (question,
# replied or stop), the phase, and the URL of the comment the kind is about.
# The newest of the issue's question comments and stop comments decides the
# kind. Prints one line saying so when nothing is listed; dies, printing
# nothing, when any read fails.
autopilot_questions() {
  local list n state labels phase json line lines="" gh_err
  gh_or_die --out list "list the $AUTOPILOT_HUMAN_LABEL issues" adapter_issues_labelled "$AUTOPILOT_HUMAN_LABEL"
  for n in $(printf '%s\n' "$list" | sort -n); do
    issue_state_labels_read "$n" state labels gh_err || gh_die "read the labels of issue #$n" "$gh_err"
    phase="$(autopilot_live_phase "$labels")"
    [ -n "$phase" ] || continue
    gh_or_die --out json "read the comments of issue #$n" adapter_issue_comments_json "$n"
    line="$(jq -r --arg prefix "$AUTOPILOT_QUESTION_PREFIX" --arg n "$n" --arg phase "$phase" "$AUTOPILOT_COMMENT_JQ"'
      newest_question("") as $qi | (if $qi == null then null else .[$qi] end) as $q
      | (to_entries | map(select(.value | stop_phase != null)) | last) as $s
      | if $q != null and ($s == null or $qi > $s.key) then
          [$n, (if $qi == length - 1 then "question" else "replied" end), ($q | question_phase), $q.url]
        elif $s != null then [$n, "stop", ($s.value | stop_phase), $s.value.url]
        else [$n, "stop", $phase, ""] end
      | @tsv' <<<"$json")" || die "could not read issue #$n's comments"
    lines+="$line"$'\n'
  done
  if [ -n "$lines" ]; then printf '%s' "$lines"; else printf 'nothing pending: no open %s issue of an autopilot flow\n' "$AUTOPILOT_HUMAN_LABEL"; fi
}

# --- tick and run (#1458) ---------------------------------------------------
#
# One pass of the watcher, and the wrapper around one headless session. Every
# write under a claim ends in autopilot_release, as above.

# autopilot_label_entries: the labels a tick ensures, one
# `name|colour|description` each: a label per phase of the table, then the
# running and human labels.
autopilot_label_entries() {
  local p colour what
  for p in $PHASES; do
    what="$p phase next"
    case "$p" in
      spec) colour=1d76db ;;
      implement) colour=0e8a16 ;;
      review) colour=5319e7 ;;
      *) colour=c2e0c6; what="$p" ;;
    esac
    printf '%s|%s|Autopilot flow: %s\n' "$(autopilot_phase_label "$p")" "$colour" "$what"
  done
  printf '%s|fbca04|Autopilot session running\n' "$AUTOPILOT_RUNNING_LABEL"
  printf '%s|d93f0b|Waiting on the human\n' "$AUTOPILOT_HUMAN_LABEL"
  printf '%s|c5def5|Autopilot session stopped on a usage limit; retried after the reset\n' "$AUTOPILOT_LIMITED_LABEL"
}

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

# autopilot_pid_alive <pid>: whether a process of that pid is running.
autopilot_pid_alive() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && { kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1; }
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
  done <<<"$(autopilot_label_entries)"
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
  capture_err gh_err adapter_issue_relabel "$issue" --add "$AUTOPILOT_HUMAN_LABEL" --remove "$AUTOPILOT_LIMITED_LABEL" ||
    autopilot_chain_die "" "$issue" "add $AUTOPILOT_HUMAN_LABEL" "$gh_err"
  body="$(mktemp)" || die "could not create a temp file for the $kind comment"
  case "$kind" in
    refusal) printf '%s%s phase: %s\n\nThe issue is labelled %s. Remove the label once this is settled and the watcher picks the phase up again.\n' \
      "$AUTOPILOT_REFUSAL_OPENING" "$phase" "$detail" "$AUTOPILOT_HUMAN_LABEL" >"$body" ;;
    *) printf '%s%s phase: %s\n\nThe issue is labelled %s; nothing is retried automatically except a usage-limit stop labelled `%s`. Remove the label to have the watcher start the phase again.\n' \
      "$AUTOPILOT_FAILURE_OPENING" "$phase" "$detail" "$AUTOPILOT_HUMAN_LABEL" "$AUTOPILOT_LIMITED_LABEL" >"$body" ;;
  esac
  capture_err gh_err adapter_issue_comment "$issue" "$body" || {
    rm -f "$body"
    autopilot_chain_die "added $AUTOPILOT_HUMAN_LABEL" "$issue" "post the $kind comment" "$gh_err"
  }
  rm -f "$body"
  autopilot_release "$issue" "added $AUTOPILOT_HUMAN_LABEL, posted the $kind comment"
}

# The first line of a limit stop comment opens with this, then the phase, then
# " -->".
AUTOPILOT_LIMITED_PREFIX='<!-- orch:limited '

# autopilot_limit_count <issue> <phase> <var>: the limit stop comments of
# <phase> before now, into <var>, counted newest first up to the first refusal,
# failure or question comment, handoff comment, or limit stop comment of
# another phase; other comments are skipped. Non-zero when the comments cannot
# be read.
autopilot_limit_count() {
  local json gh_err n
  capture json gh_err adapter_issue_comments_json "$1" || return 1
  n="$(jq -r --arg prefix "$AUTOPILOT_QUESTION_PREFIX" --arg lprefix "$AUTOPILOT_LIMITED_PREFIX" --arg phase "$2" "$AUTOPILOT_COMMENT_JQ"'
    def limit_phase: first_line | if startswith($lprefix) and endswith(" -->") then ltrimstr($lprefix) | rtrimstr(" -->") else null end;
    def handoff: first_line | startswith("<!-- orch:handoff ");
    reduce (reverse[]) as $c ({n: 0, done: false};
      if .done then .
      elif ($c | stop_phase != null or question_comment("") or handoff) then .done = true
      elif ($c | limit_phase) != null then
        if ($c | limit_phase) == $phase then .n += 1 else .done = true end
      else . end) | .n' <<<"$json")" || return 1
  printf -v "$3" '%s' "$n"
}

# autopilot_limit_stop <issue> <phase> <reset> <rc> <log>: ends a phase whose
# session stopped on a usage limit. With fewer than two such stops of the phase
# before it, adds orch:limited, comments, then releases the claim; the third in
# a row, and a stop whose comments cannot be read, take the failure path.
autopilot_limit_stop() {
  local issue="$1" phase="$2" reset="$3" rc="$4" log="$5" count body gh_err when="" landed
  [ -z "$reset" ] || when=" (resets $reset)"
  autopilot_limit_count "$issue" "$phase" count || {
    autopilot_stop "$issue" failure "$phase" "the session stopped on a usage limit$when and exited with code $rc, and the issue's comments could not be read to count the stops in a row; log: $log"
    return 0
  }
  if [ "$count" -ge 2 ]; then
    autopilot_stop "$issue" failure "$phase" "the session stopped on a usage limit$when and exited with code $rc, the third in a row in the $phase phase; log: $log"
    return 0
  fi
  capture_err gh_err adapter_issue_relabel "$issue" --add "$AUTOPILOT_LIMITED_LABEL" ||
    autopilot_chain_die "" "$issue" "add $AUTOPILOT_LIMITED_LABEL" "$gh_err"
  body="$(mktemp)" || die "could not create a temp file for the limit stop comment"
  printf '%s%s -->\nThe session stopped on a usage limit in the %s phase, which resets %s.\n\nThe issue is labelled %s; retry %s of 2, started once the limit pause has passed.\n\nLog: %s\n' \
    "$AUTOPILOT_LIMITED_PREFIX" "$phase" "$phase" "${reset:-at an unknown time}" "$AUTOPILOT_LIMITED_LABEL" "$((count + 1))" "$log" >"$body"
  capture_err gh_err adapter_issue_comment "$issue" "$body" || {
    rm -f "$body"
    autopilot_chain_die "added $AUTOPILOT_LIMITED_LABEL" "$issue" "post the limit stop comment" "$gh_err"
  }
  rm -f "$body"
  landed="added $AUTOPILOT_LIMITED_LABEL, posted the limit stop comment"
  autopilot_release "$issue" "$landed"
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

# autopilot_pickup <issue> <phase>: steps 2 to 5 of a tick for a claimed issue.
# A refusal or a failed write ends in autopilot_stop and returns 0: the claim is
# released, the tick goes on.
autopilot_pickup() {
  local issue="$1" phase="$2" limited="${3:-}" side slug title labels gh_err recorded state redo
  if [ -n "$limited" ]; then
    capture_err gh_err adapter_issue_relabel "$issue" --remove "$AUTOPILOT_LIMITED_LABEL" || {
      autopilot_stop "$issue" failure "$phase" "step removing $AUTOPILOT_LIMITED_LABEL failed: $(gh_reason "$gh_err")"
      return 0
    }
  fi
  side="$(side_checkout_for_issue "$issue")" || side=""
  if [ -z "$side" ]; then
    # labels is the read's throwaway half.
    issue_title_labels_read "$issue" title labels gh_err || {
      autopilot_stop "$issue" failure "$phase" "step side-checkout add failed: could not read the issue's title: $(gh_reason "$gh_err")"
      return 0
    }
    slug="$(autopilot_short_slug "$title")"
    # a clash with any entry of the side checkouts directory takes the issue
    [ ! -e "$(side_checkouts_dir "$(main_checkout)")/$slug" ] || slug="$slug-$issue"
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

# autopilot_host_id: the identity a claim records as its host - ORCH_HOST_ID
# when set and non-empty (the container entrypoint sets it, kept in the repo
# volume across recreates), else the hostname.
autopilot_host_id() {
  if [ -n "${ORCH_HOST_ID:-}" ]; then printf '%s\n' "$ORCH_HOST_ID"; else hostname; fi
}

# autopilot_cleanup_stale <main-root>: every claim of this host whose process is
# gone is a failure: needs-human, a comment, then the claim released. The pid
# is the run pidfile's, or - with none - the claim's own tick pid. Other hosts'
# claims are never touched.
autopilot_cleanup_stale() {
  local main_root="$1" claims issue host tick_pid run_pid phase _started pidfile log detail
  autopilot_claims_read claims
  while IFS=$'\t' read -r issue host tick_pid phase _started; do
    [ -n "$issue" ] && [ "$host" = "$(autopilot_host_id)" ] || continue
    pidfile="$(autopilot_dir "$main_root")/run/$issue.pid"
    run_pid=""
    [ ! -f "$pidfile" ] || run_pid="$(cat "$pidfile")"
    ! autopilot_pid_alive "${run_pid:-$tick_pid}" || continue
    detail="the session's process (pid ${run_pid:-${tick_pid:-unknown}}) is gone and the claim was never released - no exit code is known"
    log="$(ls -1 "$(autopilot_dir "$main_root")/logs/$issue-$phase-"*.log 2>/dev/null | tail -n 1)" || true
    if [ -n "$log" ]; then detail="$detail; log: $log"; else detail="$detail; no session log"; fi
    autopilot_stop "$issue" failure "$phase" "$detail"
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
  local main_root cap claims count issue state labels gh_err phase rc candidates
  autopilot_setting cap; cap="$AUTOPILOT_VALUE"
  main_root="$(main_checkout)" || die "could not read the checkouts - git worktree list failed"
  cd "$main_root" || die "could not enter the main checkout $main_root"
  autopilot_labels_ensure
  autopilot_cleanup_stale "$main_root"
  if autopilot_limit_paused "$main_root"; then return 0; fi
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
    phase="$(autopilot_live_phase "$labels")"
    [ -n "$phase" ] || continue
    rc=0
    capture_err gh_err adapter_claim_create "$issue" "$phase" "$$" || rc=$?
    case "$rc" in
      0) ;;
      2) continue ;;
      *) die "could not claim issue #$issue: $(gh_reason "$gh_err") - the tick stops" ;;
    esac
    count=$((count + 1))
    if list_has "$labels" "$AUTOPILOT_LIMITED_LABEL"; then autopilot_pickup "$issue" "$phase" limited; else autopilot_pickup "$issue" "$phase"; fi
  done <<<"$candidates"
}

# autopilot_resets_epoch <text>: the next moment, in local time and as epoch
# seconds, of the `resets [<weekday>] <h>[:<mm>]<am|pm>` time in <text>, such
# as "resets 3pm" or "resets Mon 9am"; non-zero, nothing printed, when <text>
# holds none. A time already past today is the same time tomorrow, or, with a
# weekday, a week on at most.
autopilot_resets_epoch() {
  local text re day="" h m ap now_epoch since target clock shift_secs ahead cur i d
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
  since="$(( 10#${clock:0:2} * 3600 + 10#${clock:3:2} * 60 + 10#${clock:6:2} ))"
  shift_secs="$(( h * 3600 + m * 60 - since ))"
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
    | if length == 0 then "none" else ([.[].resetsAt | numbers] | max // "" | tostring | sub("\\..*$"; "")) end' <<<"$1" 2>/dev/null)" || return 1
  [ "$out" != none ] || return 1
  printf '%s\n' "$out"
}

# autopilot_event_five_hour_reset <event>: the five_hour window's resetsAt, as
# epoch seconds, when its utilization is 0.9 or more; non-zero otherwise.
autopilot_event_five_hour_reset() {
  local out
  out="$(jq -r '.rate_limit_info.unifiedWindows.five_hour // {} | select((.utilization | numbers) >= 0.9) | .resetsAt | numbers | floor' <<<"$1" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# autopilot_limit_write <dir> <log> <reset>: records the UTC timestamp <reset>
# as the limit file's reset in <dir>, keeping one already there that is later
# and replacing one that is earlier or does not parse. A failed write is noted
# in <log> and on stderr, and is no failure of the caller.
autopilot_limit_write() {
  local file="$1/limit" log="$2" old old_epoch new_epoch msg
  new_epoch="$(autopilot_iso_epoch "$3")" || new_epoch=0
  if [ -f "$file" ]; then
    old="$(cat "$file" 2>/dev/null)" || old=""
    old_epoch="$(autopilot_iso_epoch "$old")" || old_epoch=0
    [ "$old_epoch" -lt "$new_epoch" ] || return 0
  fi
  if ! { printf '%s\n' "$3" >"$file"; } 2>/dev/null; then
    msg="autopilot run: could not write the limit file $file"
    warn "$msg"
    printf '%s\n' "$msg" >>"$log"
  fi
  return 0
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
  local issue="$1" main_root side phase mode launcher dir log pidfile prompt rc=0 claims held=0 reset detail line mine name event epoch limited flags=()
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  autopilot_mode_require; mode="$AUTOPILOT_VALUE"
  main_root="$(main_checkout)" || die "could not read the checkouts - git worktree list failed"
  side="$(side_checkout_for_issue "$issue")" || die "no side checkout records issue #$issue"
  phase="$(state_get_in "$(flow_state_file "$side")" phase)" || die "could not read the recorded phase of $side"
  dir="$(autopilot_dir "$main_root")"
  mkdir -p "$dir/run" "$dir/logs" || die "could not create $dir"
  pidfile="$dir/run/$issue.pid"
  printf '%s\n' "$$" >"$pidfile"
  # A later run of the same issue may have replaced the pidfile by the time this
  # one exits: remove it only while it still names this run.
  # shellcheck disable=SC2064
  trap "[ \"\$(cat '$pidfile' 2>/dev/null)\" != '$$' ] || rm -f '$pidfile'" EXIT
  # The claim this run was started for: a session that releases it may exit
  # after the next phase's claim is made, and that one is not this run's to
  # fail.
  autopilot_claims_read claims
  mine=""
  while IFS= read -r line; do
    case "$line" in "$issue"$'\t'*) mine="$line" ;; esac
  done <<<"$claims"
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
  autopilot_claims_read claims
  while IFS= read -r line; do
    case "$line" in "$issue"$'\t'*) [ -z "$mine" ] || [ "$line" = "$mine" ] || continue; held=1 ;; esac
  done <<<"$claims"
  # The early pause: a session ending with its five-hour usage at 90% or more
  # pauses pickup until that window resets, whatever its outcome.
  event="$(autopilot_log_last_event "$log" rate_limit_event)"
  if [ -n "$event" ] && epoch="$(autopilot_event_five_hour_reset "$event")"; then
    autopilot_limit_write "$dir" "$log" "$(autopilot_epoch_iso "$epoch")"
  fi
  if [ "$held" = 0 ]; then
    detail="autopilot run: issue #$issue's session exited $rc with its claim released"
    note "$detail"
    printf '%s\n' "$detail" >>"$log"
    return 0
  fi
  detail="the session exited with code $rc; log: $log"
  limited=0; reset=""
  if [ -n "$event" ] && epoch="$(autopilot_event_rejecting_reset "$event")"; then
    limited=1
    [ -z "$epoch" ] || reset="$(autopilot_epoch_iso "$epoch")"
  elif reset="$(autopilot_limit_reset "$log")"; then
    limited=1
  fi
  if [ "$limited" = 1 ]; then
    [ -n "$reset" ] || reset="$(autopilot_epoch_iso "$(( $(date +%s) + 3600 ))")"
    autopilot_limit_write "$dir" "$log" "$reset"
    autopilot_limit_stop "$issue" "$phase" "$reset" "$rc" "$log"
    return 0
  fi
  autopilot_stop "$issue" failure "$phase" "$detail"
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

# autopilot_watch <seconds>: repeats tick every <seconds> until interrupted.
# Refuses while another watch of this clone is alive, replaces a pidfile whose
# pid is dead, reports a failed tick on stderr and carries on, and removes its
# pidfile when interrupted. Each tick is a fresh orch.sh process, so a tick
# that dies takes nothing else with it.
autopilot_watch() {
  local every="$1" pidfile other rc nap=""
  pidfile="$(autopilot_watch_pidfile)" || return 1
  if [ -f "$pidfile" ]; then
    other="$(cat "$pidfile" 2>/dev/null)" || other=""
    ! autopilot_pid_alive "$other" ||
      die "another autopilot watch (pid $other) is already running in this clone"
  fi
  mkdir -p "$(dirname "$pidfile")" || die "could not create $(dirname "$pidfile")"
  printf '%s\n' "$$" >"$pidfile"
  # shellcheck disable=SC2064
  trap "rm -f '$pidfile'; [ -z \"\${nap:-}\" ] || kill \"\$nap\" 2>/dev/null; exit 0" INT TERM
  # shellcheck disable=SC2064
  trap "rm -f '$pidfile'" EXIT
  while :; do
    rc=0
    "$(autopilot_self)" autopilot tick >/dev/null || rc=$?
    [ "$rc" = 0 ] || warn "autopilot watch: the tick failed (exit $rc); trying again in ${every}s"
    sleep "$every" &
    nap=$!
    wait "$nap" || true
    nap=""
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
      autopilot_start "$1" "$2"
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
