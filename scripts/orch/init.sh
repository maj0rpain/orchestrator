# shellcheck shell=bash

# The git-based backstop from ADR-0013. Where no host hook arms the edit
# guard, planning can edit source unhindered; flow start is where that gets
# caught, before any state exists. Runs against $ROOT, this working tree's own
# top level, so a flow started inside a worktree (ADR-0008) is judged by that
# worktree's changes and not by the checkout it was forked from.
require_clean_outside_allowlist() {
  local dirty records="" outside="" path msg outside_block
  dirty="$(dirty_outside_allowlist)" || exit 1
  [ -z "$dirty" ] && return 0
  while IFS= read -r path; do
    if planning_record "$path"; then
      records+="$path"$'\n'
    else
      outside+="$path"$'\n'
    fi
  done <<<"$dirty"
  outside_block="$(printf '%s' "$outside" | sed 's/^/       /')
     Planning may only change: $(planning_allowlist_text)."
  # With only source paths dirty, the message is exactly as before the
  # planning records (#186) got their own block.
  if [ -z "$records" ]; then
    die "the working tree has changes outside the planning allowlist:
$outside_block
     Commit, stash, or discard these changes, then run init again."
  fi
  # The redirect is one long sentence pair shared with the guard; wrapped here
  # to the message's own indent and width.
  msg="the working tree has changes planning does not make.
     Planning records changed (planning does not edit these in place):
$(printf '%s' "$records" | sed 's/^/       /')
$(planning_record_redirect | fold -s -w 75 | sed 's/ *$//; s/^/     /')"
  # Committing a record from planning is the option ADR-0022 rejects, so
  # records are only ever discarded or stashed once their wording has moved.
  if [ -z "$outside" ]; then
    die "$msg
     Discard or stash these changes, then run init again."
  fi
  die "$msg
     Changes outside the planning allowlist:
$outside_block
     Discard or stash the planning records; commit, stash, or discard the other
     changes, then run init again."
}

# `init --issue N`'s one-time gate: the issue must exist, be open, and carry
# this repo's local name for the ready-for-agent role - resolved through
# triage_label_for, never the literal string, so a repo that renamed its
# labels still gets a correct check. Checked once, here, and never again: a
# maintainer's later triage housekeeping must not stop a flow already running
# against the issue (docs/adr/0005).
validate_adopted_issue() {
  local issue="$1" label state labels gh_line
  label="$(triage_label_for ready-for-agent)"
  issue_state_labels_read "$issue" state labels gh_line \
    || die "issue #$issue could not be read from GitHub - check it exists and gh is authenticated: $(gh_reason "$gh_line")"
  [ "$state" = OPEN ] || die "issue #$issue is not open - adoption requires an open issue."
  labels_have "$labels" "$label" \
    || die "issue #$issue is missing the '$label' triage label - adoption requires it."
}

cmd_init() {
  local usage="usage: orch.sh init <slug> [--issue N]"
  local slug="${1:-}" issue=""
  [ -n "$slug" ] || die "$usage"
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue)
        issue="${2:-}"
        [ -n "$issue" ] || die "$usage"
        case "$issue" in
          ''|*[!0-9]*) die "--issue wants a plain issue number, got: $issue" ;;
        esac
        shift 2 ;;
      *) die "unknown init flag: $1 (want --issue)" ;;
    esac
  done
  slug="$(normalize_slug "$slug")"
  # A "done" flow already succeeded - its handoffs are read by no later phase,
  # so it is not "active" in any sense that matters. init archives it and
  # proceeds instead of refusing; every other phase still blocks a second flow.
  local archive_note=""
  refuse_beside_active_flow
  require_clean_outside_allowlist
  # Adoption is validated before anything is written, mirroring how
  # branch create and pr open die on their own preconditions rather than
  # letting a whole phase run against an issue that cannot back it. Validating
  # before archiving a done flow means a bad --issue leaves it untouched and
  # re-runnable rather than archived for nothing.
  [ -z "$issue" ] || validate_adopted_issue "$issue"
  # The whole seed is built before a done flow is archived or anything is
  # written, so a lookup that dies leaves the previous state untouched. It is
  # built in one pass over STATE_KEYS, in table order: a constant row gives its
  # seed literal, and an arg row the jq expression its case arm gives, typed
  # here. An arg row with no arm dies naming the key rather than seed null.
  # For base, see the header of base_set_flow.
  local k s v fields="" seed
  while IFS='|' read -r k _ s _; do
    v="$s"
    if [ "$s" = arg ]; then
      case "$k" in
        slug)    v='$slug' ;;
        issue)   v='(if $issue == "" then null else ($issue | tonumber) end)' ;;
        base)    v='$base' ;;
        created|updated) v='$now' ;;
        *) die "init has no value for arg state key: $k" ;;
      esac
    fi
    fields="${fields:+$fields,}\"$k\":$v"
  done <<EOF
$(state_rows)
EOF
  seed="$(jq -n --arg slug "$slug" --arg now "$(now)" --arg issue "$issue" --arg base "$(base_branch)" \
    "{$fields}")" || die "could not build the state seed - nothing was written"
  # archive_flow, not cmd_archive: in a side checkout the old flow moves to the
  # main checkout's archive, but the worktree stays - the new flow lives here.
  if [ -f "$STATE" ]; then
    archive_note="$(archive_flow "$ROOT")" || exit 1
  fi
  mkdir -p "$HANDOFF_DIR" "$REVIEW_DIR"
  exclude_orch_dirs
  printf '%s\n' "$seed" >"$STATE"
  phase_write spec
  [ -z "$archive_note" ] || note "$archive_note"
  note "$slug"
}
