# shellcheck shell=bash
# standing.sh - the Standing module, a concept module with no noun: where an
# autopilot flow's issue stands. It owns the label set (the phase labels,
# orch:running, needs-human, orch:limited), the phase-label helpers, the label
# table a tick upserts, the host id, the read of an issue's Standing, the
# claim record's parsing and the claim transition. Its tests:
# scripts/test/orch/standing.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

STANDING_RUNNING_LABEL="orch:running"
STANDING_HUMAN_LABEL="needs-human"
STANDING_LIMITED_LABEL="orch:limited"

# standing_phase_label <phase>: the label that records an autopilot flow's
# phase on its issue, `orch:<phase>` - the label is the flow's phase record.
standing_phase_label() { printf 'orch:%s\n' "$1"; }

# standing_running_label: the label of a running session, for a remedy that
# prints it.
standing_running_label() { printf '%s\n' "$STANDING_RUNNING_LABEL"; }

# standing_human_label: the label of an issue waiting on the human, for a
# message that prints it.
standing_human_label() { printf '%s\n' "$STANDING_HUMAN_LABEL"; }

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

# standing_read <issue>: reads the issue's state and labels once into
# STANDING_STATE (OPEN or CLOSED), STANDING_LABELS (every label, one per line),
# STANDING_PHASE (the live phase: the first phase other than done whose label is
# present, in table order; empty when none), STANDING_PHASE_LABELS (the text of
# every phase label, in table order) and STANDING_RUNNING, STANDING_HUMAN and
# STANDING_LIMITED, each 0 or 1. Non-zero when the read fails: the reason on
# stderr and in STANDING_REASON. Call it in the current shell, never inside
# capture_err or $(...).
STANDING_REASON=""
# shellcheck disable=SC2034 # the variables are the module's read, used by its callers
standing_read() {
  local gh_err
  if ! issue_state_labels_read "$1" STANDING_STATE STANDING_LABELS gh_err; then
    STANDING_REASON="$(gh_reason "$gh_err")"
    printf '%s\n' "$STANDING_REASON" >&2
    return 1
  fi
  STANDING_PHASE="$(standing_live_phase "$STANDING_LABELS")"
  STANDING_PHASE_LABELS="$(standing_phase_labels_text "$STANDING_LABELS")"
  STANDING_RUNNING=0 STANDING_HUMAN=0 STANDING_LIMITED=0
  ! list_has "$STANDING_LABELS" "$STANDING_RUNNING_LABEL" || STANDING_RUNNING=1
  ! list_has "$STANDING_LABELS" "$STANDING_HUMAN_LABEL" || STANDING_HUMAN=1
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
  standing_read "$1" 2>/dev/null || gh_die "read issue #$1" "$STANDING_REASON"
  [ "$STANDING_STATE" = OPEN ] || die "issue #$1 is closed"
  [ "$STANDING_HUMAN" = 1 ] || die "issue #$1 does not carry $STANDING_HUMAN_LABEL"
}

# standing_resume <issue> [replied]: removes needs-human. A failed removal dies
# with the message of its caller: with replied (autopilot reply, whose reply
# comment has landed), that comment's; without it, autopilot resume's.
standing_resume() {
  local issue="$1" gh_err
  capture_err gh_err adapter_issue_relabel "$issue" --remove "$STANDING_HUMAN_LABEL" && return 0
  if [ "${2:-}" = replied ]; then
    die "the reply comment landed on issue #$issue, but $STANDING_HUMAN_LABEL could not be removed: $(gh_reason "$gh_err")"
  fi
  gh_die "remove $STANDING_HUMAN_LABEL from issue #$issue" "$gh_err"
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
