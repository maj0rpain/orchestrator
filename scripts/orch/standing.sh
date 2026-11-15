# shellcheck shell=bash
# standing.sh - the Standing module, a concept module with no noun: where an
# autopilot flow's issue stands. It owns the label set (the phase labels,
# orch:running, needs-human, orch:limited), the phase-label helpers, the label
# table a tick upserts, the host id, the read of an issue's Standing, the
# claim record's parsing, the claim transition and every other write to it
# (begin, sync request, start, finish, pause, ask, stop, reenter, sync finish,
# sync dropped, limit-stop, resume). Its tests:
# scripts/test/orch/standing.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

STANDING_RUNNING_LABEL="orch:running"
STANDING_HUMAN_LABEL="needs-human"
STANDING_LIMITED_LABEL="orch:limited"
# The sync request: not a phase label - an issue carrying it keeps orch:done.
STANDING_SYNC_LABEL="orch:sync"

# standing_phase_label <phase>: the label that records an autopilot flow's
# phase on its issue, `orch:<phase>` - the label is the flow's phase record.
standing_phase_label() { printf 'orch:%s\n' "$1"; }

# standing_phase_labels_in <labels>: the phases, one per line in table order,
# whose labels are among <labels>.
standing_phase_labels_in() {
  orch_load handoff
  local p
  for p in $PHASES; do
    ! label_listed "$1" "$(standing_phase_label "$p")" || printf '%s\n' "$p"
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
# running, human, limited and sync labels.
standing_label_entries() {
  orch_load handoff
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
  printf '%s|c5def5|Autopilot session stopped on a usage or GitHub API rate limit; retried after the reset\n' "$STANDING_LIMITED_LABEL"
  printf '%s|0075ca|Autopilot: base sync requested on a done flow\n' "$STANDING_SYNC_LABEL"
}

# standing_host_id: the identity a claim records as its host - ORCH_HOST_ID
# when set and non-empty (the container entrypoint sets it, kept in the repo
# volume across recreates), else the hostname.
standing_host_id() {
  if [ -n "${ORCH_HOST_ID:-}" ]; then printf '%s\n' "$ORCH_HOST_ID"; else hostname; fi
}

# --- the read -------------------------------------------------------------

STANDING_REASON=""

# standing_set <state> <labels>: fills the label half of Standing from a state
# and labels, with no GitHub call: STANDING_STATE (OPEN or CLOSED),
# STANDING_LABELS (every label, one per line), STANDING_PHASE (the live phase:
# the first phase other than done whose label is present, in table order; empty
# when none), STANDING_PHASE_LABELS (the text of every phase label, in table
# order) and STANDING_RUNNING, STANDING_HUMAN, STANDING_LIMITED and
# STANDING_SYNC, each 0 or 1. Call it in the current shell.
standing_set() {
  STANDING_STATE="$1" STANDING_LABELS="$2"
  STANDING_PHASE="$(standing_live_phase "$STANDING_LABELS")"
  STANDING_PHASE_LABELS="$(standing_phase_labels_text "$STANDING_LABELS")"
  STANDING_RUNNING=0 STANDING_HUMAN=0 STANDING_LIMITED=0 STANDING_SYNC=0
  # the variable is the module's read, used by its callers
  # shellcheck disable=SC2034
  ! label_listed "$STANDING_LABELS" "$STANDING_SYNC_LABEL" || STANDING_SYNC=1
  ! label_listed "$STANDING_LABELS" "$STANDING_RUNNING_LABEL" || STANDING_RUNNING=1
  ! label_listed "$STANDING_LABELS" "$STANDING_HUMAN_LABEL" || STANDING_HUMAN=1
  # the variables are the module's read, used by its callers
  # shellcheck disable=SC2034
  ! label_listed "$STANDING_LABELS" "$STANDING_LIMITED_LABEL" || STANDING_LIMITED=1
}

# standing_read <issue>: reads the issue's state and labels once and fills
# Standing's label half from them through standing_set. Non-zero when the read
# fails: the reason only in STANDING_REASON, printing nothing, for a caller that
# words its own death.
# Call it in the current shell, never inside capture_err or $(...).
standing_read() {
  local gh_err state labels
  if ! issue_state_labels_read "$1" state labels gh_err; then
    STANDING_REASON="$(gh_reason "$gh_err")"
    return 1
  fi
  standing_set "$state" "$labels"
}

# The phase word of a sync request: where a transition takes a phase argument
# for a sync, it takes this.
STANDING_SYNC_PHASE="sync"

# standing_is_done: whether the last read carries orch:done.
standing_is_done() {
  label_listed "$STANDING_LABELS" "$(standing_phase_label "done")"
}

# standing_is_sync: whether the last read is a sync request - orch:sync on an
# issue at orch:done. An issue with a live phase label is its phase's, and one
# with orch:sync but no orch:done is no sync request.
standing_is_sync() {
  [ "$STANDING_SYNC" = 1 ] && [ -z "$STANDING_PHASE" ] && standing_is_done
}

# standing_session_phase: the phase word of the session the last read starts:
# sync for a sync request, else the live phase.
standing_session_phase() {
  if standing_is_sync; then printf '%s' "$STANDING_SYNC_PHASE"; else printf '%s' "$STANDING_PHASE"; fi
}

# standing_pickable: the label half of the Pickup rule, from the last read:
# the issue is open, has a live phase or is a sync request, and is neither
# running nor waiting on the human. The limit pause is the tick's own check.
standing_pickable() {
  [ "$STANDING_STATE" = OPEN ] && { [ -n "$STANDING_PHASE" ] || standing_is_sync; } &&
    [ "$STANDING_RUNNING" = 0 ] && [ "$STANDING_HUMAN" = 0 ]
}

# standing_phase_text <phase>: how a stop comment names what stopped - "the
# <phase> phase", or "the sync" for a sync request, which is no phase.
standing_phase_text() {
  if [ "$1" = "$STANDING_SYNC_PHASE" ]; then printf 'the sync'; else printf 'the %s phase' "$1"; fi
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

# standing_human_guard <issue>: reads the issue and dies unless it is open and
# carries needs-human.
standing_human_guard() {
  standing_read "$1" || gh_die "read issue #$1" "$STANDING_REASON"
  [ "$STANDING_STATE" = OPEN ] || die "issue #$1 is closed"
  [ "$STANDING_HUMAN" = 1 ] || die "issue #$1 does not carry $STANDING_HUMAN_LABEL"
}

# standing_relabel_one <issue> <flag> <label>: one label write - <flag>
# (--add or --remove) <label> on <issue>. Returns 0, or 1 with the reason in
# STANDING_REASON when the write fails, printing nothing: each caller words its
# own death or warning. A single write, not a chain: it leaves STANDING_LANDED
# alone.
standing_relabel_one() {
  local gh_err
  gh_capture_err gh_err adapter_issue_relabel "$1" "$2" "$3" && return 0
  STANDING_REASON="$(gh_reason "$gh_err")"
  return 1
}

# standing_resume <issue>: removes needs-human, one write, through
# standing_relabel_one.
standing_resume() {
  standing_relabel_one "$1" --remove "$STANDING_HUMAN_LABEL"
}

# --- transitions ------------------------------------------------------------
#
# Every write to Standing goes through one transition: begin, sync request,
# start, finish, pause, ask, stop, reenter, sync finish, sync dropped,
# limit-stop, claim release, claim drop and resume. Begin, sync request, claim
# drop and resume are single writes; the others are chains. A chain of writes a
# session makes under its claim ends in the release - deletes orch:running and
# then, last, the claim ref - which is internal to this module: a chain that
# fails partway leaves the claim held, and dies naming the writes that landed;
# the session wrapper retries a stop chain (see the resumable chain below), and
# a claim still held after that is cleaned up by a later tick as a failure.
# STANDING_LANDED accumulates those writes. Every chain transition begins
# through standing_chain_start, so no chain inherits an earlier chain's writes;
# start holds no claim and does not. Every adapter write of a chain goes through
# standing_chain_step. Outside it stay finish's write of the phase to flow
# state, start, begin, the single writes through standing_relabel_one (sync
# request, resume) and the claim drop.

STANDING_LANDED=""
# The temp body file of a comment in flight, so a death removes it too; cleared
# once the post's step returns and by standing_chain_start.
STANDING_BODY_FILE=""

# standing_landed_die <what failed>: removes the comment body file in flight, if
# any, then dies with the clause, the writes that landed and that the claim
# stays held.
standing_landed_die() {
  [ -z "$STANDING_BODY_FILE" ] || rm -f "$STANDING_BODY_FILE"
  die "$1 - writes that landed: ${STANDING_LANDED:-none}; the claim stays held"
}

# standing_chain_die <issue> <what> <gh-stderr>: dies for a write of a chain
# that failed, naming the reason and the writes that landed before it.
standing_chain_die() {
  standing_landed_die "could not $2 on issue #$1: $(gh_reason "$3")"
}

# standing_timeline_read_or_die <issue> <purpose>: reads the issue's comments,
# else dies with the landed writes, naming what the read was for and why it
# failed.
standing_timeline_read_or_die() {
  orch_load issue-timeline
  timeline_read "$1" ||
    standing_landed_die "could not read issue #$1's comments to $2: ${TIMELINE_REASON:-the comments could not be read}"
}

# The resumable chain (#2695). The session wrapper runs a stop chain up to three
# times, each attempt in a subshell of its own, so a death ends the attempt and
# not the wrapper. STANDING_STATE_FILE, set only inside an attempt, is the
# wrapper's record of what the attempts did, one TSV line each: `landed <write>`
# for a write whose call succeeded, `tried <write>` before a comment's call (it
# may have landed though the call failed), `plan <value>` for what the first
# successful timeline read fixed, and `stop <kind> <first line>` for the
# wrapper's backstop line. A chain transition starts from the writes that landed
# (STANDING_DONE) and skips them; with no state file nothing is recorded.
# standing_chain_step is the one place an adapter write is run, skipped and
# noted, apart from a comment standing_chain_comment's look finds already
# landed (and finish's own phase record, which is no adapter write), and
# standing_chain_comment the one place a try is recorded.
STANDING_STATE_FILE=""
STANDING_DONE=()

# standing_state_put <key> <value>: records the line; nothing without a file.
standing_state_put() {
  [ -z "$STANDING_STATE_FILE" ] || printf '%s\t%s\n' "$1" "$2" >>"$STANDING_STATE_FILE"
}

# standing_state_get <key>: prints the value of the newest <key> line; fails
# when there is none.
standing_state_get() {
  local key value rc=1 out=""
  [ -s "${STANDING_STATE_FILE:-}" ] || return 1
  while IFS=$'\t' read -r key value; do
    [ "$key" != "$1" ] || { out="$value"; rc=0; }
  done <"$STANDING_STATE_FILE"
  [ "$rc" -ne 0 ] || printf '%s\n' "$out"
  return "$rc"
}

# standing_chain_start [<seed>]: begins every chain transition. It clears
# STANDING_LANDED, the skip list (STANDING_DONE) and STANDING_BODY_FILE, puts a
# non-empty <seed> first on STANDING_LANDED, then, when STANDING_STATE_FILE is
# set, takes up the writes earlier attempts landed. The seed is a reason, not a
# write: it is not skipped and not recorded in the state file.
standing_chain_start() {
  local key value
  STANDING_LANDED="${1:-}" STANDING_DONE=() STANDING_BODY_FILE=""
  [ -s "${STANDING_STATE_FILE:-}" ] || return 0
  while IFS=$'\t' read -r key value; do
    [ "$key" = landed ] || continue
    STANDING_DONE+=("$value")
    STANDING_LANDED="${STANDING_LANDED:+$STANDING_LANDED, }$value"
  done <"$STANDING_STATE_FILE"
}

# standing_landed_has <write>: whether an earlier attempt landed <write>.
standing_landed_has() {
  local done_write
  for done_write in ${STANDING_DONE[@]+"${STANDING_DONE[@]}"}; do
    [ "$done_write" != "$1" ] || return 0
  done
  return 1
}

# standing_landed_add <write>: notes a write that landed.
standing_landed_add() {
  STANDING_LANDED="${STANDING_LANDED:+$STANDING_LANDED, }$1"
  STANDING_DONE+=("$1")
  standing_state_put landed "$1"
}

# standing_stop_note <kind> <text>: records the stop's kind and the first line
# of <text> that is not its hidden marker, for the wrapper's backstop line.
standing_stop_note() {
  local line first=""
  while IFS= read -r line; do
    case "$line" in ''|'<!--'*) continue ;; esac
    first="$line"; break
  done <<<"$2"
  standing_state_put stop "$1"$'\t'"$first"
}

# standing_chain_step <landed-name> <failure-what> <issue> <adapter command...>:
# the one holder of the chain-write rule for adapter writes (a comment
# standing_chain_comment's look finds landed is skipped and noted there). A
# write already landed is skipped and its command not run; otherwise the
# complete command runs, its stderr captured, and a failure dies as a chain
# does ("could not <failure-what> on issue #<issue>: <reason> - writes that
# landed: ...; the claim stays held"); a success notes <landed-name> as
# landed. The step adds no argument to the command, so the issue appears both
# as <issue> and inside it.
standing_chain_step() {
  local landed="$1" what="$2" issue="$3" gh_err
  shift 3
  ! standing_landed_has "$landed" || return 0
  gh_capture_err gh_err "$@" || standing_chain_die "$issue" "$what" "$gh_err"
  standing_landed_add "$landed"
}

# standing_chain_relabel <issue> (<flag> <label>)...: a label edit of a chain,
# one edit for all its pairs, <flag> being --add or --remove. The landed name
# ("added <label>" / "removed <label>") and the failure wording ("add <label>" /
# "remove <label>") are derived from the pairs, in argument order, joined by
# ", ", and the edit goes through standing_chain_step.
standing_chain_relabel() {
  local issue="$1" landed="" what="" past verb
  shift
  local args=("$@")
  while [ "$#" -gt 0 ]; do
    verb=add past=added
    [ "$1" != --remove ] || { verb=remove; past=removed; }
    landed="${landed:+$landed, }$past $2"
    what="${what:+$what, }$verb $2"
    shift 2
  done
  standing_chain_step "$landed" "$what" "$issue" adapter_issue_relabel "$issue" "${args[@]}"
}

# standing_comment_call <issue> <body-file>: posts the comment in <body-file>,
# then removes the file, whatever the post returned. The step runs it, and dies
# inside itself on a failed post, so the removal is done here and not after the
# step call. It runs in a subshell, so standing_chain_comment, not this, clears
# STANDING_BODY_FILE.
standing_comment_call() {
  local rc=0
  adapter_issue_comment "$1" "$2" || rc=$?
  rm -f "$2"
  return "$rc"
}

# standing_chain_comment <landed-name> <failure-what> <issue> <text>: posts
# <text> as a comment of a chain, once only. A comment already landed is
# skipped. When the state file records that an earlier attempt tried it, the
# issue's comments are read first: a trusted comment whose body is <text>,
# trailing whitespace aside, counts as landed with no post, and a failed read
# dies with no post. Otherwise the try is recorded, then the post goes through
# standing_chain_step. The temp body file is removed on every path. This is the
# one place a try is recorded. See the resumable chain comment.
standing_chain_comment() {
  local landed="$1" what="$2" issue="$3" body
  ! standing_landed_has "$landed" || return 0
  # An earlier attempt's call failed and may have landed: look first, and post
  # nothing when the look fails.
  if [ -s "${STANDING_STATE_FILE:-}" ] && grep -qxF "tried"$'\t'"$landed" "$STANDING_STATE_FILE"; then
    standing_timeline_read_or_die "$issue" "check for this stop's comment"
    if timeline_has_body "$4"; then
      standing_landed_add "$landed"
      return 0
    fi
  fi
  temp_file_make body || die "could not create a temp file to $what"
  STANDING_BODY_FILE="$body"
  printf '%s' "$4" >"$body"
  standing_state_put tried "$landed"
  standing_chain_step "$landed" "$what" "$issue" standing_comment_call "$issue" "$body"
  STANDING_BODY_FILE=""
}

# standing_release <issue>: deletes orch:running, then the claim ref, last,
# through the step.
standing_release() {
  local issue="$1"
  standing_chain_relabel "$issue" --remove "$STANDING_RUNNING_LABEL"
  standing_chain_step "deleted the claim ref" "delete the claim ref" "$issue" adapter_claim_delete "$issue"
}

# standing_claim_release <issue>: a chain transition that only releases the
# claim - orch:running removed, then the claim ref deleted - with no comment, no
# other label and nothing counted.
standing_claim_release() {
  standing_chain_start
  standing_stop_note "claim release" "could not release the claim"
  standing_release "$1"
}

# standing_claim_drop <issue>: a single write that only deletes the claim ref,
# for a pickup that has not added orch:running: no label, no comment, nothing
# counted. A failed push leaves the claim held.
standing_claim_drop() {
  adapter_claim_delete "$1"
}

# standing_move_label <issue> <phase>: <issue>'s phase label made the one for
# <phase> - the other phase labels removed - in one edit, through the step: an
# edit an earlier attempt landed is skipped, and a landed one is noted as
# "moved the phase label to <label>".
standing_move_label() {
  # state is the read's throwaway half.
  # shellcheck disable=SC2034
  local issue="$1" phase="$2" state labels gh_err p label args=()
  issue_state_labels_read "$issue" state labels gh_err ||
    standing_chain_die "$issue" "read the labels" "$gh_err"
  for p in $(standing_phase_labels_in "$labels"); do
    [ "$p" = "$phase" ] || args+=(--remove "$(standing_phase_label "$p")")
  done
  label="$(standing_phase_label "$phase")"
  standing_chain_step "moved the phase label to $label" "move the phase label to $label" "$issue" \
    adapter_issue_relabel "$issue" --add "$label" ${args[@]+"${args[@]}"}
}

# standing_start <issue> <plan-file>: the planning close's last step. Before
# any write it refuses an issue without the ready-for-agent label (checked as
# issue ready checks it) and one that already carries a phase label, then
# validates the plan, ## Autopilot block included. Then it posts the plan
# comment and, last, adds the first phase's label - so a failure after the
# comment leaves the issue unlabelled, never picked up. A re-run on an
# unlabelled issue posts a newer plan comment, which supersedes the earlier.
standing_start() {
  orch_load handoff
  local issue="$1" file="$2" ready gh_err first
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  [ -f "$file" ] || die "plan file not found: $file"
  triage_label_into ready ready-for-agent
  standing_read "$issue" || gh_die "read issue #$issue" "$STANDING_REASON"
  label_listed "$STANDING_LABELS" "$ready" ||
    die "issue #$issue does not carry the '$ready' label - an autopilot flow starts from a ready issue"
  [ -z "$STANDING_PHASE_LABELS" ] ||
    die "issue #$issue already carries the phase label ${STANDING_PHASE_LABELS%% *} - it is already an autopilot flow"
  handoff_check "$file" "" 01-plan.md autopilot || die "plan $file is not valid - nothing posted"
  handoff_comment_post "$issue" 01-plan "$file" || exit 1
  first="$(standing_phase_label "${PHASES%% *}")"
  gh_capture_err gh_err adapter_issue_relabel "$issue" --add "$first" ||
    die "posted the 01-plan comment on issue #$issue but adding $first failed: $(gh_reason "$gh_err") - the issue is unlabelled, so no watcher picks it up; re-run autopilot start"
}

# standing_sync_request <issue>: the sync request transition - adds orch:sync,
# one write, through standing_relabel_one: returns 0, or 1 with the reason in
# STANDING_REASON.
standing_sync_request() {
  standing_relabel_one "$1" --add "$STANDING_SYNC_LABEL"
}

# standing_begin <issue> [limited]: pickup's last step - removes
# orch:limited when <limited> is given, then adds orch:running. It never dies
# and does not stop the issue: a failed write returns 1 with the write's step
# wording, "step removing orch:limited failed: <reason>" or "step adding
# orch:running failed: <reason>", in STANDING_REASON and printing nothing.
standing_begin() {
  local issue="$1" gh_err
  if [ -n "${2:-}" ]; then
    gh_capture_err gh_err adapter_issue_relabel "$issue" --remove "$STANDING_LIMITED_LABEL" || {
      STANDING_REASON="step removing $STANDING_LIMITED_LABEL failed: $(gh_reason "$gh_err")"
      return 1
    }
  fi
  gh_capture_err gh_err adapter_issue_relabel "$issue" --add "$STANDING_RUNNING_LABEL" || {
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
  standing_chain_start "${3:-}"
  standing_move_label "$1" "$2"
  phase_write_try "$2" ||
    standing_landed_die "could not record phase $2 in $STATE"
  standing_landed_add "recorded phase $2"
  standing_release "$1"
}

# standing_pause <issue> <reason>: ends a session's turn with the phase
# unchanged - the claim released, nothing else. <reason> seeds the writes that
# landed.
standing_pause() {
  standing_chain_start "${2:-}"
  standing_release "$1"
}

# standing_ask <phase> <text>: reads the issue from flow state, posts <text> as
# <phase>'s question comment - the hidden marker line, the configured handle
# @mentioned, <text>, then the reply instructions - adds needs-human, then
# releases the claim.
standing_ask() {
  local phase="$1" text="$2" issue marker body
  standing_chain_start
  require_issue issue
  autopilot_setting handle
  marker="$(marked_comment_write question "$phase")" || exit 1
  printf -v body '%s\n@%s\n\n%s\nReply in one comment like `1: A, 2: recommended, 3: <free text>` (`all: recommended` accepts everything).\n' \
    "$marker" "$AUTOPILOT_VALUE" "$text"
  standing_chain_comment "posted the $phase question comment" "post the $phase question comment" "$issue" "$body"
  standing_chain_relabel "$issue" --add "$STANDING_HUMAN_LABEL"
  standing_release "$issue"
}

# standing_reenter <issue> <phase> <text>: the automatic re-entry transition,
# under the claim. With fewer than two re-entry comments of <phase> in a row
# it posts <text> as a re-entry comment - no @mention, no label change - then
# releases the claim; with two or more it asks instead, noting that. A
# timeline that cannot be read dies with the claim held and no write, for the
# session wrapper to sort.
standing_reenter() {
  local issue="$1" phase="$2" text="$3" count body
  standing_chain_start
  standing_timeline_read_or_die "$issue" "count the automatic re-entries in a row"
  count="$(timeline_reentry_count "$phase")"
  if [ "$count" -ge 2 ]; then
    standing_ask "$phase" "$text"$'\n\nThis follows two automatic re-entries of the '"$phase"$' loop, so it asks instead of starting another.\n'
    return 0
  fi
  printf -v body '%s\n\nThe watcher starts another %s loop.\n' "$text" "$phase"
  body="$(marked_comment_write reentry "$phase")"$'\n'"$body"
  standing_chain_comment "posted the $phase re-entry comment" "post the re-entry comment" "$issue" "$body"
  standing_release "$issue"
}

# standing_stop_write <issue> <kind> <text> <label> [<remove-label>]:
# the write chain of a stop: adds <label> (removing <remove-label> when given),
# posts <text> as the <kind> comment, then releases the claim, last. The label
# edit is one call to standing_chain_relabel.
standing_stop_write() {
  local issue="$1" kind="$2" text="$3" label="$4" remove="${5:-}"
  standing_stop_note "$kind" "$text"
  standing_chain_relabel "$issue" --add "$label" ${remove:+--remove "$remove"}
  standing_chain_comment "posted the $kind comment" "post the $kind comment" "$issue" "$text"
  standing_release "$issue"
}

# standing_stop <issue> <refusal|failure> <phase> <detail>: ends a phase that
# will not run, or did not finish: adds needs-human, comments - the comment
# opens with the hidden marker line, then names the phase and <detail> - then
# releases the claim, last. The marker is written first: a refusal of the
# writer dies before any label, comment or claim is touched.
standing_stop() {
  local issue="$1" kind="$2" phase="$3" detail="$4" text marker what
  standing_chain_start
  marker="$(marked_comment_write "$kind" "$phase")" || exit 1
  what="$(standing_phase_text "$phase")"
  case "$kind" in
    refusal) printf -v text '%s\nAutopilot refused to run %s: %s\n\nThe issue is labelled %s. Remove the label once this is settled and the watcher picks %s up again.\n' \
      "$marker" "$what" "$detail" "$STANDING_HUMAN_LABEL" "$what" ;;
    *) printf -v text '%s\nAutopilot failed in %s: %s\n\nThe issue is labelled %s; nothing is retried automatically except a usage-limit stop labelled `%s`. Remove the label to have the watcher start %s again.\n' \
      "$marker" "$what" "$detail" "$STANDING_HUMAN_LABEL" "$STANDING_LIMITED_LABEL" "$what" ;;
  esac
  standing_stop_write "$issue" "$kind" "$text" "$STANDING_HUMAN_LABEL" "$STANDING_LIMITED_LABEL"
}

# standing_sync_finish <issue>: a finished sync's close under its claim -
# orch:sync removed, then the claim released. orch:done stays and no phase is
# recorded: the issue is a plain done flow again.
standing_sync_finish() {
  standing_chain_start
  standing_chain_relabel "$1" --remove "$STANDING_SYNC_LABEL"
  standing_release "$1"
}

# standing_sync_dropped <issue> <intents> <auto_sync>: the dropped-intent
# stop of a sync whose merge was pushed: orch:sync removed and needs-human
# added in one edit, a failure-kind stop comment marked with the phase word
# sync listing <intents>, then the claim released, last. The stop asks
# nothing; <auto_sync>, true or false, picks what the comment says follows.
# The caller reads the setting and passes it in.
standing_sync_dropped() {
  local issue="$1" intents="$2" auto_sync="$3" marker text next
  standing_chain_start
  marker="$(marked_comment_write failure "$STANDING_SYNC_PHASE")" || exit 1
  if [ "$auto_sync" = true ]; then
    next="Once the label is gone, the watcher files a new sync request by itself whenever the PR conflicts with its base; or run \`orch.sh autopilot sync $issue\` to sync now."
  else
    next="To sync again, run \`orch.sh autopilot sync $issue\`."
  fi
  printf -v text '%s\nThe sync pushed its merge, but its resolver dropped these intents:\n\n%s\n\nNo reply is needed. Review the dropped intents; if you accept them, remove %s. To reject one, restore it on the branch first, then remove the label. The issue no longer carries %s. %s\n' \
    "$marker" "$intents" "$STANDING_HUMAN_LABEL" "$STANDING_SYNC_LABEL" "$next"
  standing_stop_write "$issue" failure "$text" "$STANDING_HUMAN_LABEL" "$STANDING_SYNC_LABEL"
}

# standing_limit_stop <issue> <phase> <reset> <pause> <rc> <log> [github]: ends
# a phase whose session stopped on a limit - a usage limit, or with "github" a
# GitHub API rate limit. With fewer than two limit stops of the phase before
# it, whatever their causes, a usage-limit stop adds orch:limited, comments,
# then releases the claim; a GitHub limit stop adds no label (it is written
# only once its reset has passed): it comments, removes orch:running, then
# releases the claim. The third in a row takes the failure path, naming the
# cause; a stop whose comments cannot be read fails the attempt, so the wrapper
# retries it. The reset is empty when the session named none; the pause is the
# time written to the limit file: the reset, else the one-hour fallback.
standing_limit_stop() {
  orch_load issue-timeline
  local issue="$1" phase="$2" reset="$3" pause="$4" rc="$5" log="$6" cause="${7:-}"
  local count plan text when=" (the session gave no reset time)" at stopped marker what="a usage limit"
  standing_chain_start
  [ -z "$reset" ] || when=" (resets $reset)"
  [ -z "$cause" ] || what="the GitHub API rate limit"
  stopped="the session stopped on $what$when and exited with code $rc"
  # The first read that succeeds fixes the stop's kind and count for every
  # later attempt. A read that fails, on a GitHub limit or for any other
  # reason, fixes nothing: the attempt fails, and a later one reads again.
  plan="$(standing_state_get plan)" || {
    timeline_read "$issue" || {
      standing_stop_note "limit stop" "$stopped"
      standing_landed_die "could not read issue #$issue's comments to count the stops in a row: ${TIMELINE_REASON:-the comments could not be read}"
    }
    count="$(timeline_limit_count "$phase")"
    if [ "$count" -ge 2 ]; then plan=third; else plan="count:$count"; fi
    standing_state_put plan "$plan"
  }
  case "$plan" in
    third)
      standing_stop "$issue" failure "$phase" "$stopped, the third in a row in $(standing_phase_text "$phase"); log: $log"
      return 0 ;;
  esac
  count="${plan#count:}"
  marker="$(marked_comment_write limited "$phase" $cause)" || exit 1
  if [ -n "$cause" ]; then
    printf -v text '%s\nThe session stopped on the GitHub API rate limit in %s, which resets %s.\n\nRetry %s of 2: the issue is picked up again by the next tick, no label is added.\n\nLog: %s\n' \
      "$marker" "$(standing_phase_text "$phase")" "${reset:-$pause}" "$((count + 1))" "$log"
    standing_stop_note "limit stop" "$text"
    standing_chain_comment "posted the limit stop comment" "post the limit stop comment" "$issue" "$text"
    standing_release "$issue"
    return
  fi
  at="; it gave no reset time, so the watcher falls back to a one-hour limit pause, until $pause"
  [ -z "$reset" ] || at=", which resets $reset"
  printf -v text '%s\nThe session stopped on a usage limit in %s%s.\n\nThe issue is labelled %s; retry %s of 2, started once the limit pause has passed.\n\nLog: %s\n' \
    "$marker" "$(standing_phase_text "$phase")" "$at" "$STANDING_LIMITED_LABEL" "$((count + 1))" "$log"
  standing_stop_write "$issue" "limit stop" "$text" "$STANDING_LIMITED_LABEL"
}

# --- claims -----------------------------------------------------------------

# The claims on origin, read by standing_claims_read: STANDING_CLAIM_ISSUES
# lists the issue numbers in the adapter's order; the others are keyed by issue.
STANDING_CLAIM_ISSUES=()
declare -gA STANDING_CLAIM_HOST=() STANDING_CLAIM_PID=() STANDING_CLAIM_PHASE=() STANDING_CLAIM_STARTED=()

# standing_claims_read [--quiet]: reads the claims on origin once into the
# arrays above, replacing the last read. Where origin cannot be read it dies
# naming the failure, or with --quiet returns 1 and says nothing.
standing_claims_read() {
  local gh_err text issue host pid phase started
  STANDING_CLAIM_ISSUES=()
  STANDING_CLAIM_HOST=() STANDING_CLAIM_PID=() STANDING_CLAIM_PHASE=() STANDING_CLAIM_STARTED=()
  if ! gh_capture text gh_err adapter_claim_list; then
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
