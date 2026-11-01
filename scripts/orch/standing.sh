# shellcheck shell=bash
# standing.sh - the Standing module, a concept module with no noun: where an
# autopilot flow's issue stands. It owns the label set (the phase labels,
# orch:running, needs-human, orch:limited), the phase-label helpers, the label
# table a tick upserts, the host id, the read of an issue's Standing, the
# claim record's parsing, the claim transition and every other write to it
# (start, finish, pause, ask, stop, limit-stop, resume). Its tests:
# scripts/test/orch/standing.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

STANDING_RUNNING_LABEL="orch:running"
STANDING_HUMAN_LABEL="needs-human"
STANDING_LIMITED_LABEL="orch:limited"

# standing_phase_label <phase>: the label that records an autopilot flow's
# phase on its issue, `orch:<phase>` - the label is the flow's phase record.
standing_phase_label() { printf 'orch:%s\n' "$1"; }

# standing_phase_labels_in <labels>: the phases, one per line in table order,
# whose labels are among <labels>.
standing_phase_labels_in() {
  local p
  for p in $PHASES; do
    ! list_has "$1" "$(standing_phase_label "$p")" || printf '%s\n' "$p"
  done
}

# standing_phase_labels_text <labels>: the phase labels (`orch:<phase>`) among
# <labels>, joined by single spaces in table order; nothing when there are none.
standing_phase_labels_text() {
  local p text=""
  for p in $(standing_phase_labels_in "$1"); do
    text="${text:+$text }$(standing_phase_label "$p")"
  done
  printf '%s' "$text"
}

# standing_live_phase <labels>: the first phase other than done whose label is
# among <labels>, in table order; nothing when there is none.
standing_live_phase() {
  local p
  for p in $(standing_phase_labels_in "$1"); do
    [ "$p" != "done" ] || continue
    printf '%s\n' "$p"
    return 0
  done
}

# standing_label_entries: the labels a tick ensures, one
# `name|colour|description` each: a label per phase of the table, then the
# running, human and limited labels.
standing_label_entries() {
  local p colour what
  for p in $PHASES; do
    what="$p phase next"
    case "$p" in
      spec) colour=1d76db ;;
      implement) colour=0e8a16 ;;
      review) colour=5319e7 ;;
      *) colour=c2e0c6; what="$p" ;;
    esac
    printf '%s|%s|Autopilot flow: %s\n' "$(standing_phase_label "$p")" "$colour" "$what"
  done
  printf '%s|fbca04|Autopilot session running\n' "$STANDING_RUNNING_LABEL"
  printf '%s|d93f0b|Waiting on the human\n' "$STANDING_HUMAN_LABEL"
  printf '%s|c5def5|Autopilot session stopped on a usage limit; retried after the reset\n' "$STANDING_LIMITED_LABEL"
}

# standing_host_id: the identity a claim records as its host - ORCH_HOST_ID
# when set and non-empty (the container entrypoint sets it, kept in the repo
# volume across recreates), else the hostname.
standing_host_id() {
  if [ -n "${ORCH_HOST_ID:-}" ]; then printf '%s\n' "$ORCH_HOST_ID"; else hostname; fi
}

# --- the read -------------------------------------------------------------

STANDING_REASON=""

# standing_read <issue>: reads the issue's state and labels once into
# STANDING_STATE (OPEN or CLOSED), STANDING_LABELS (every label, one per line),
# STANDING_PHASE (the live phase: the first phase other than done whose label is
# present, in table order; empty when none), STANDING_PHASE_LABELS (the text of
# every phase label, in table order) and STANDING_RUNNING, STANDING_HUMAN and
# STANDING_LIMITED, each 0 or 1. Non-zero when the read fails: the reason only
# in STANDING_REASON, printing nothing, for a caller that words its own death.
# Call it in the current shell, never inside capture_err or $(...).
standing_read() {
  local gh_err
  if ! issue_state_labels_read "$1" STANDING_STATE STANDING_LABELS gh_err; then
    STANDING_REASON="$(gh_reason "$gh_err")"
    return 1
  fi
  STANDING_PHASE="$(standing_live_phase "$STANDING_LABELS")"
  STANDING_PHASE_LABELS="$(standing_phase_labels_text "$STANDING_LABELS")"
  STANDING_RUNNING=0 STANDING_HUMAN=0 STANDING_LIMITED=0
  ! list_has "$STANDING_LABELS" "$STANDING_RUNNING_LABEL" || STANDING_RUNNING=1
  ! list_has "$STANDING_LABELS" "$STANDING_HUMAN_LABEL" || STANDING_HUMAN=1
  # the variables are the module's read, used by its callers
  # shellcheck disable=SC2034
  ! list_has "$STANDING_LABELS" "$STANDING_LIMITED_LABEL" || STANDING_LIMITED=1
}

# standing_pickable: the label half of the Pickup rule, from the last read:
# the issue is open, has a live phase, and is neither running nor waiting on
# the human. The limit pause is the tick's own check.
standing_pickable() {
  [ "$STANDING_STATE" = OPEN ] && [ -n "$STANDING_PHASE" ] &&
    [ "$STANDING_RUNNING" = 0 ] && [ "$STANDING_HUMAN" = 0 ]
}

# standing_label_verdict <labels> <phase> <verdict-var> <text-var>: whether the
# phase labels among <labels> agree with the recorded <phase>: none when there
# is no phase label, agrees when the one carried is the label of <phase>, else
# disagrees. The phase-label text goes into <text-var>.
standing_label_verdict() {
  local text
  text="$(standing_phase_labels_text "$1")"
  printf -v "$4" '%s' "$text"
  if [ -z "$text" ]; then printf -v "$3" none
  elif [ "$text" = "$(standing_phase_label "$2")" ]; then printf -v "$3" agrees
  else printf -v "$3" disagrees
  fi
}

# STANDING_REDO_PAIRS: the one source of the phase-redo rule - space-separated
# rows `labelled:recorded:redo`, the redo being the `orch.sh redo` argument for
# a flow labelled <labelled> whose checkout last moved to <recorded>. Read at
# each call, never at source time, so a test can set it.
STANDING_REDO_PAIRS="implement:review:review spec:implement:spec"

# standing_redo_phase <labelled> <recorded>: the phase-redo rule. Prints the
# `orch.sh redo` argument that steps a flow labelled <labelled> back to that
# phase from the <recorded> phase its checkout last moved to, per
# STANDING_REDO_PAIRS: review for implement:review, spec for spec:implement.
# Any other pair is no redo: prints nothing and returns 1.
standing_redo_phase() {
  local row labelled recorded redo
  for row in $STANDING_REDO_PAIRS; do
    IFS=: read -r labelled recorded redo <<<"$row"
    if [ "$labelled:$recorded" = "$1:$2" ]; then
      printf '%s\n' "$redo"
      return 0
    fi
  done
  return 1
}

# standing_redo_rule: the phase-redo rule as one clause, from
# STANDING_REDO_PAIRS: "a step back from review to implement or from implement
# to spec". Each pair reads "from <recorded> to <labelled>".
standing_redo_rule() {
  local row labelled recorded redo rule=""
  for row in $STANDING_REDO_PAIRS; do
    IFS=: read -r labelled recorded redo <<<"$row"
    rule="${rule:+$rule or }from $recorded to $labelled"
  done
  printf 'a step back %s\n' "$rule"
}

# standing_human_issues: the open or closed issues carrying needs-human, one
# number per line; dies, naming the failure, where they cannot be listed.
standing_human_issues() {
  local list
  gh_or_die --out list "list the $STANDING_HUMAN_LABEL issues" adapter_issues_labelled "$STANDING_HUMAN_LABEL"
  printf '%s\n' "$list"
}

# standing_human_guard <issue>: reads the issue and dies unless it is open and
# carries needs-human.
standing_human_guard() {
  standing_read "$1" || gh_die "read issue #$1" "$STANDING_REASON"
  [ "$STANDING_STATE" = OPEN ] || die "issue #$1 is closed"
  [ "$STANDING_HUMAN" = 1 ] || die "issue #$1 does not carry $STANDING_HUMAN_LABEL"
}

# standing_resume <issue>: removes needs-human. Returns 0, or 1 with the reason
# in STANDING_REASON when the removal fails, printing nothing: each caller
# dies with its own message. A single write, not a chain: it leaves
# STANDING_LANDED alone.
standing_resume() {
  local gh_err
  capture_err gh_err adapter_issue_relabel "$1" --remove "$STANDING_HUMAN_LABEL" && return 0
  STANDING_REASON="$(gh_reason "$gh_err")"
  return 1
}

# --- transitions ------------------------------------------------------------
#
# Every write to Standing goes through one transition below: begin,
# start, finish, pause, ask, stop, limit-stop and resume. Begin and resume are
# single writes; the others are chains. A chain of writes a
# session makes under its claim ends in the release - deletes orch:running and
# then, last, the claim ref - which is internal to this module: a chain that
# fails partway leaves the claim held, and dies naming the writes that landed,
# so the next tick cleans it up as a failure. STANDING_LANDED accumulates those
# writes; each chain transition (start, finish, pause, ask, stop and limit-stop)
# resets it at its start, and begin and resume neither reset nor add to it.

STANDING_LANDED=""

# standing_chain_die <issue> <what> <gh-stderr>: dies for a write of a chain
# that failed, naming the reason and the writes that landed before it.
standing_chain_die() {
  die "could not $2 on issue #$1: $(gh_reason "$3") - writes that landed: ${STANDING_LANDED:-none}; the claim stays held"
}

# standing_landed_add <write>: notes a write that landed.
standing_landed_add() { STANDING_LANDED="${STANDING_LANDED:+$STANDING_LANDED, }$1"; }

# standing_release <issue>: deletes orch:running, then the claim ref, last.
standing_release() {
  local issue="$1" gh_err
  capture_err gh_err adapter_issue_relabel "$issue" --remove "$STANDING_RUNNING_LABEL" ||
    standing_chain_die "$issue" "remove $STANDING_RUNNING_LABEL" "$gh_err"
  standing_landed_add "removed $STANDING_RUNNING_LABEL"
  capture_err gh_err adapter_claim_delete "$issue" ||
    standing_chain_die "$issue" "delete the claim ref" "$gh_err"
}

# standing_move_label <issue> <phase>: <issue>'s phase label made the one for
# <phase> - the other phase labels removed - in one edit.
standing_move_label() {
  # state is the read's throwaway half.
  # shellcheck disable=SC2034
  local issue="$1" phase="$2" state labels gh_err p args=()
  issue_state_labels_read "$issue" state labels gh_err ||
    standing_chain_die "$issue" "read the labels" "$gh_err"
  for p in $(standing_phase_labels_in "$labels"); do
    [ "$p" = "$phase" ] || args+=(--remove "$(standing_phase_label "$p")")
  done
  capture_err gh_err adapter_issue_relabel "$issue" --add "$(standing_phase_label "$phase")" ${args[@]+"${args[@]}"} ||
    standing_chain_die "$issue" "move the phase label to $(standing_phase_label "$phase")" "$gh_err"
}

# standing_start <issue> <plan-file>: the planning close's last step. Before
# any write it refuses an issue without the ready-for-agent label (checked as
# issue ready checks it) and one that already carries a phase label, then
# validates the plan, ## Autopilot block included. Then it posts the plan
# comment and, last, adds the first phase's label - so a failure after the
# comment leaves the issue unlabelled, never picked up. A re-run on an
# unlabelled issue posts a newer plan comment, which supersedes the earlier.
standing_start() {
  local issue="$1" file="$2" ready gh_err first
  STANDING_LANDED=""
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  [ -f "$file" ] || die "plan file not found: $file"
  ready="$(triage_label_for ready-for-agent)"
  standing_read "$issue" || gh_die "read issue #$issue" "$STANDING_REASON"
  list_has "$STANDING_LABELS" "$ready" ||
    die "issue #$issue does not carry the '$ready' label - an autopilot flow starts from a ready issue"
  [ -z "$STANDING_PHASE_LABELS" ] ||
    die "issue #$issue already carries the phase label ${STANDING_PHASE_LABELS%% *} - it is already an autopilot flow"
  handoff_check "$file" "" 01-plan.md autopilot || die "plan $file is not valid - nothing posted"
  handoff_comment_post "$issue" 01-plan "$file" || exit 1
  first="$(standing_phase_label "${PHASES%% *}")"
  capture_err gh_err adapter_issue_relabel "$issue" --add "$first" ||
    die "posted the 01-plan comment on issue #$issue but adding $first failed: $(gh_reason "$gh_err") - the issue is unlabelled, so no watcher picks it up; re-run autopilot start"
}

# standing_begin <issue> [limited]: pickup's last step - removes
# orch:limited when <limited> is given, then adds orch:running. It never dies
# and does not stop the issue: a failed write returns 1 with the write's step
# wording, "step removing orch:limited failed: <reason>" or "step adding
# orch:running failed: <reason>", in STANDING_REASON and printing nothing.
standing_begin() {
  local issue="$1" gh_err
  if [ -n "${2:-}" ]; then
    capture_err gh_err adapter_issue_relabel "$issue" --remove "$STANDING_LIMITED_LABEL" || {
      STANDING_REASON="step removing $STANDING_LIMITED_LABEL failed: $(gh_reason "$gh_err")"
      return 1
    }
  fi
  capture_err gh_err adapter_issue_relabel "$issue" --add "$STANDING_RUNNING_LABEL" || {
    STANDING_REASON="step adding $STANDING_RUNNING_LABEL failed: $(gh_reason "$gh_err")"
    return 1
  }
}

# standing_finish <issue> <phase> <reason>: a finished phase's close under its
# claim - the phase label moved to <phase>, then the recorded phase, then the
# claim released. <reason> names what was done, and seeds the writes that
# landed. The label moves before state.json records the phase, so a failure
# between the two leaves the label one step ahead, never behind.
standing_finish() {
  STANDING_LANDED="${3:-}"
  standing_move_label "$1" "$2"
  phase_write "$2"
  standing_landed_add "moved the phase label to $(standing_phase_label "$2"), recorded phase $2"
  standing_release "$1"
}

# standing_pause <issue> <reason>: ends a session's turn with the phase
# unchanged - the claim released, nothing else. <reason> seeds the writes that
# landed.
standing_pause() {
  STANDING_LANDED="${2:-}"
  standing_release "$1"
}

# standing_ask <phase> <text>: reads the issue from flow state, posts <text> as
# <phase>'s question comment - the hidden marker line, the configured handle
# @mentioned, <text>, then the reply instructions - adds needs-human, then
# releases the claim.
standing_ask() {
  local phase="$1" text="$2" issue body gh_err
  STANDING_LANDED=""
  require_state
  require_issue issue
  autopilot_setting handle
  body="$(mktemp)" || die "could not create a temp file for the question comment"
  { marked_comment_write question "$phase"; printf '@%s\n\n' "$AUTOPILOT_VALUE"; printf '%s' "$text"
    printf '\nReply in one comment like `1: A, 2: recommended, 3: <free text>` (`all: recommended` accepts everything).\n'; } >"$body"
  capture_err gh_err adapter_issue_comment "$issue" "$body" || { rm -f "$body"; gh_die "post the $phase question on issue #$issue" "$gh_err"; }
  rm -f "$body"
  standing_landed_add "posted the $phase question comment"
  capture_err gh_err adapter_issue_relabel "$issue" --add "$STANDING_HUMAN_LABEL" ||
    standing_chain_die "$issue" "add $STANDING_HUMAN_LABEL" "$gh_err"
  standing_landed_add "added $STANDING_HUMAN_LABEL"
  standing_release "$issue"
}

# standing_stop_write <issue> <kind> <text> <label> [<remove-label>]: the write
# chain of a stop: adds <label> (removing <remove-label> when given), posts
# <text> as the <kind> comment, then releases the claim, last.
standing_stop_write() {
  local issue="$1" kind="$2" text="$3" label="$4" remove="${5:-}" body gh_err relabel=()
  relabel=(--add "$label")
  [ -z "$remove" ] || relabel+=(--remove "$remove")
  capture_err gh_err adapter_issue_relabel "$issue" "${relabel[@]}" ||
    standing_chain_die "$issue" "add $label" "$gh_err"
  standing_landed_add "added $label"
  body="$(mktemp)" || die "could not create a temp file for the $kind comment"
  printf '%s' "$text" >"$body"
  capture_err gh_err adapter_issue_comment "$issue" "$body" || {
    rm -f "$body"
    standing_chain_die "$issue" "post the $kind comment" "$gh_err"
  }
  rm -f "$body"
  standing_landed_add "posted the $kind comment"
  standing_release "$issue"
}

# standing_stop <issue> <refusal|failure> <phase> <detail>: ends a phase that
# will not run, or did not finish: adds needs-human, comments - the comment
# opens with the hidden marker line, then names the phase and <detail> - then
# releases the claim, last. The marker is written first: a refusal of the
# writer dies before any label, comment or claim is touched.
standing_stop() {
  local issue="$1" kind="$2" phase="$3" detail="$4" text marker
  STANDING_LANDED=""
  marker="$(marked_comment_write "$kind" "$phase")" || exit 1
  case "$kind" in
    refusal) printf -v text '%s\nAutopilot refused to run the %s phase: %s\n\nThe issue is labelled %s. Remove the label once this is settled and the watcher picks the phase up again.\n' \
      "$marker" "$phase" "$detail" "$STANDING_HUMAN_LABEL" ;;
    *) printf -v text '%s\nAutopilot failed in the %s phase: %s\n\nThe issue is labelled %s; nothing is retried automatically except a usage-limit stop labelled `%s`. Remove the label to have the watcher start the phase again.\n' \
      "$marker" "$phase" "$detail" "$STANDING_HUMAN_LABEL" "$STANDING_LIMITED_LABEL" ;;
  esac
  standing_stop_write "$issue" "$kind" "$text" "$STANDING_HUMAN_LABEL" "$STANDING_LIMITED_LABEL"
}

# standing_limit_stop <issue> <phase> <reset> <pause> <rc> <log>: ends a
# phase whose session stopped on a usage limit. With fewer than two such stops
# of the phase before it, adds orch:limited, comments, then releases the claim;
# the third in a row, and a stop whose comments cannot be read, take the
# failure path. The reset is empty when the session named none; the pause is
# the time written to the limit file: the reset, else the one-hour fallback.
standing_limit_stop() {
  local issue="$1" phase="$2" reset="$3" pause="$4" rc="$5" log="$6" count text when=" (the session gave no reset time)" at stopped marker
  STANDING_LANDED=""
  [ -z "$reset" ] || when=" (resets $reset)"
  stopped="the session stopped on a usage limit$when and exited with code $rc"
  { timeline_read "$issue" && count="$(timeline_limit_count "$phase")"; } || {
    standing_stop "$issue" failure "$phase" "$stopped, and the issue's comments could not be read to count the stops in a row; log: $log"
    return 0
  }
  if [ "$count" -ge 2 ]; then
    standing_stop "$issue" failure "$phase" "$stopped, the third in a row in the $phase phase; log: $log"
    return 0
  fi
  marker="$(marked_comment_write limited "$phase")" || exit 1
  at="; it gave no reset time, so the watcher falls back to a one-hour limit pause, until $pause"
  [ -z "$reset" ] || at=", which resets $reset"
  printf -v text '%s\nThe session stopped on a usage limit in the %s phase%s.\n\nThe issue is labelled %s; retry %s of 2, started once the limit pause has passed.\n\nLog: %s\n' \
    "$marker" "$phase" "$at" "$STANDING_LIMITED_LABEL" "$((count + 1))" "$log"
  standing_stop_write "$issue" "limit stop" "$text" "$STANDING_LIMITED_LABEL"
}

# --- claims -----------------------------------------------------------------

# The claims on origin, read by standing_claims_read: STANDING_CLAIM_ISSUES
# lists the issue numbers in the adapter's order; the others are keyed by issue.
STANDING_CLAIM_ISSUES=()
declare -A STANDING_CLAIM_HOST=() STANDING_CLAIM_PID=() STANDING_CLAIM_PHASE=() STANDING_CLAIM_STARTED=()

# standing_claims_read [--quiet]: reads the claims on origin once into the
# arrays above, replacing the last read. Where origin cannot be read it dies
# naming the failure, or with --quiet returns 1 and says nothing.
standing_claims_read() {
  local gh_err text issue host pid phase started
  STANDING_CLAIM_ISSUES=()
  STANDING_CLAIM_HOST=() STANDING_CLAIM_PID=() STANDING_CLAIM_PHASE=() STANDING_CLAIM_STARTED=()
  if ! capture text gh_err adapter_claim_list; then
    [ "${1:-}" != --quiet ] || return 1
    die "could not list the claims on origin: $(gh_reason "$gh_err")"
  fi
  while IFS=$'\t' read -r issue host pid phase started; do
    [ -n "$issue" ] || continue
    STANDING_CLAIM_ISSUES+=("$issue")
    STANDING_CLAIM_HOST[$issue]="$host"
    STANDING_CLAIM_PID[$issue]="$pid"
    STANDING_CLAIM_PHASE[$issue]="$phase"
    STANDING_CLAIM_STARTED[$issue]="$started"
  done <<<"$text"
}

# standing_claim_fields <issue>: the last read's claim on <issue> as its four
# fields (host, pid, phase, started) joined by tabs, for comparing a claim
# before and after; nothing, and non-zero, when none is held.
standing_claim_fields() {
  [ -n "${STANDING_CLAIM_HOST[$1]+x}" ] || return 1
  printf '%s\t%s\t%s\t%s\n' "${STANDING_CLAIM_HOST[$1]}" "${STANDING_CLAIM_PID[$1]}" \
    "${STANDING_CLAIM_PHASE[$1]}" "${STANDING_CLAIM_STARTED[$1]}"
}

# standing_claim <issue> <phase> <pid>: creates the claim ref, recording this
# host's id. Exit status: 0 taken, 2 lost race, 1 any other failure, the
# reason on stderr.
standing_claim() {
  adapter_claim_create "$1" "$2" "$3" "$(standing_host_id)"
}
