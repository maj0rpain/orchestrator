# shellcheck shell=bash
# issue.sh - orch.sh's issue command: the stateless issue ops, publish, triage,
# ready and close.
# Its tests: scripts/test/orch/issue.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# labels_verified <labels> <want> [absent-label...]: whether the
# newline-separated <labels> carry <want> and none of the absent labels.
# A pure check: each read-back verifier does its own read and hands the labels
# here, so publish and triage judge their labels the same way.
labels_verified() {
  local labels="$1" want="$2" l
  shift 2
  labels_have "$labels" "$want" || return 1
  for l in "$@"; do
    ! labels_have "$labels" "$l" || return 1
  done
}

# has_review_label <labels>: whether any label marks a review finding, at any
# severity - filed today or not.
has_review_label() {
  [ -n "$(review_labels "$1")" ]
}

# The four stateless issue ops - fetch, comments, update and comment - on an
# issue given just its number: the same contract issue publish/pr
# publish/ticket publish already offer, extended to a plain issue. spec.sh's
# fetch/comments/update/comment ops are thin wrappers over all four,
# resolving the issue number from state, so flow's stateful spec access and
# quick implementation's stateless issue access share one tested code path
# instead of two independently-maintained copies. comment is stateless
# because a standalone spec review posts its summary on whatever issue it was
# pointed at, with no flow to resolve one from.
#
# `issue update` stays a dumb "replace the body with these exact bytes"
# primitive - fold-in choreography like fetch-then-append-then-write for
# merging ticket content into a parent belongs in the calling skill's prose,
# not here.

# With --json, the issue's title, body, labels and comments as ISSUE_JSON_JQ's
# object, so a fresh agent reads the whole issue with one pinned call.
cmd_issue_fetch() {
  local issue="$1" file="$2" as_json="${3:-}"
  if [ -n "$as_json" ]; then
    fetch_into "$file" "issue #$issue" adapter_issue_json "$issue"
    return
  fi
  fetch_into "$file" "the body of issue #$issue" \
    adapter_issue_body "$issue"
}

# Every comment on the issue, in COMMENTS_JQ's shape - so the spec review reads
# the comments beside the body. No comments is an empty file, not an error.
cmd_issue_comments() {
  local issue="$1" file="$2"
  fetch_into "$file" "the comments of issue #$issue" \
    adapter_issue_comments "$issue"
}

cmd_issue_update() {
  local issue="$1" file="$2" err
  [ -f "$file" ] || die "body file not found: $file"
  # --body-file, never --body: an issue body carries tables, fences, and
  # `#nn` references, and a heredoc through a shell is where those get
  # mangled.
  capture_err err adapter_issue_body_edit "$issue" "$file" \
    || die "gh could not replace the body of issue #$issue: $(gh_reason "$err")"
}

cmd_issue_comment() {
  local issue="$1" file="$2" err
  [ -f "$file" ] || die "body file not found: $file"
  capture_err err adapter_issue_comment "$issue" "$file" \
    || die "gh could not comment on issue #$issue: $(gh_reason "$err")"
}

cmd_issue() {
  local op="${1:-}"
  shift || true
  case "$op" in
    fetch|update|comment|comments)
      local usage="usage: orch.sh issue $op <n> <file>"
      [ "$op" = fetch ] && usage="usage: orch.sh issue fetch <n> <file> [--json]"
      # For fetch alone, --json only as the third argument; any other shape is
      # a usage error.
      [ $# -eq 2 ] || { [ "$op" = fetch ] && [ $# -eq 3 ] && [ "$3" = --json ]; } \
        || die "$usage"
      case "$1" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $1 ($usage)" ;; esac
      "cmd_issue_$op" "$@"
      ;;
    publish) cmd_issue_publish "$@" ;;
    triage) cmd_issue_triage "$@" ;;
    ready) cmd_issue_ready "$@" ;;
    close) cmd_issue_close "$@" ;;
    *) die "unknown issue op: ${op:-<none>} (want fetch|update|comment|comments|publish|triage|ready|close)" ;;
  esac
}

# issue close <n> (--completed | --duplicate-of <m>) --comment-file <file>:
# the planning close's done-close (#985) - closes issue <n> as completed, or
# as a duplicate of <m>, the file's contents its closing comment. One gh call,
# the comment riding on the close, so a failed close never leaves a comment on
# a still-open issue, as redo's close does. Bad input dies before any gh call.
# Like ticket close it reads nothing back, and like issue comment it posts the
# comment as given and leaves the labels alone.
cmd_issue_close() {
  local usage="usage: orch.sh issue close <n> (--completed | --duplicate-of <m>) --comment-file <file>"
  local issue="" completed=false dup="" dup_given=false file="" file_given=false err
  while [ $# -gt 0 ]; do
    case "$1" in
      --completed) completed=true; shift ;;
      --duplicate-of)
        [ $# -ge 2 ] || die "$1 needs a value ($usage)"
        dup="$2"; dup_given=true; shift 2 ;;
      --comment-file)
        [ $# -ge 2 ] || die "$1 needs a value ($usage)"
        file="$2"; file_given=true; shift 2 ;;
      -*) die "unknown option: $1 ($usage)" ;;
      *) [ -z "$issue" ] || die "$usage"; issue="$1"; shift ;;
    esac
  done
  [ -n "$issue" ] || die "$usage"
  case "$issue" in *[!0-9]*) die "issue must be a plain issue number, got: $issue ($usage)" ;; esac
  [ "$completed" = true ] && [ "$dup_given" = true ] \
    && die "give one of --completed or --duplicate-of, not both ($usage)"
  [ "$completed" = true ] || [ "$dup_given" = true ] \
    || die "give one of --completed or --duplicate-of ($usage)"
  if [ "$dup_given" = true ]; then
    case "$dup" in ''|*[!0-9]*) die "--duplicate-of must be a plain issue number, got: $dup ($usage)" ;; esac
    [ "$dup" != "$issue" ] || die "issue #$issue cannot be a duplicate of itself"
  fi
  [ "$file_given" = true ] || die "--comment-file is required ($usage)"
  [ -f "$file" ] || die "comment file not found: $file"
  [ -s "$file" ] || die "comment file is empty: $file"

  local comment
  comment="$(cat "$file")"
  if [ "$dup_given" = true ]; then
    capture_err err adapter_issue_close "$issue" --duplicate-of "$dup" --comment "$comment" \
      || die "gh could not close issue #$issue: $(gh_reason "$err") - --duplicate-of needs gh 2.102 or newer"
  else
    capture_err err adapter_issue_close "$issue" --reason completed --comment "$comment" \
      || die "gh could not close issue #$issue: $(gh_reason "$err")"
  fi
}

# issue ready <n>: exit 0 when issue <n> carries the repo's ready-for-agent
# label, 1 when it does not - so exit 1 is a meaningful "no", and a usage
# error or a gh failure exits 2 (die2), as ticket exists does. The spec
# skill's rewrite mode reads it to warn when a rewritten issue lacks the label.
cmd_issue_ready() {
  local usage="usage: orch.sh issue ready <n>"
  [ $# -eq 1 ] || die2 "$usage"
  local issue="$1" ready state labels gh_err
  case "$issue" in ''|*[!0-9]*) die2 "issue must be a plain issue number, got: $issue ($usage)" ;; esac
  ready="$(triage_label_for ready-for-agent)"
  issue_state_labels_read "$issue" state labels gh_err \
    || die2 "gh could not read issue #$issue: $(gh_reason "$gh_err")"
  labels_have "$labels" "$ready"
}

# issue_publish_verified <err_var> <n> <title> <label>: 0 only once the
# created issue reads back with the title it was given and the
# ready-for-agent role's label among its labels; 1 on a mismatch; 2 when the
# read fails, gh's stderr written into <err_var>, so a failed read is never
# reported as a mismatch. Read fresh every call, never cached - the caller
# retries this once on either status, as ticket_links_verified's caller does.
# Locals prefixed so no caller's variable name is shadowed.
issue_publish_verified() {
  local __ipv_err __ipv_title __ipv_labels
  if ! issue_title_labels_read "$2" __ipv_title __ipv_labels __ipv_err; then
    printf -v "$1" '%s' "$__ipv_err"
    return 2
  fi
  [ "$__ipv_title" = "$3" ] || return 1
  labels_verified "$__ipv_labels" "$4" || return 1
}

# The publishing boundary a spec and a quick implementation call instead of
# hardcoding `gh issue create` in skill prose - the same reason `review file`
# owns its own `gh issue create` rather than leaving it to whichever skill
# files a finding. Stateless like branch off: the caller may have no flow to
# record into, so the title and body are its own and nothing here remembers
# them. Verify-then-die like ticket publish: the issue is created under the
# ready-for-agent role's label (an agent works it next), then its title and
# labels are read back - one retry on a mismatch or a failed read, a second
# failure dies naming the issue, so a half-published spec never reaches the
# next step.
cmd_issue_publish() {
  [ $# -eq 2 ] || die "usage: orch.sh issue publish <title> <body-file>"
  local title="$1" body_file="$2" ready n err gh_err="" st=0
  [ -n "$title" ] || die "the title is empty"
  [ -f "$body_file" ] || die "body file not found: $body_file"
  ready="$(triage_label_for ready-for-agent)"
  capture n err adapter_issue_create "$title" "$body_file" "$ready" \
    || die "gh could not create the issue: $(gh_reason "$err")"
  # The second attempt's status decides the death: 2 a failed read, 1 a
  # mismatch.
  issue_publish_verified gh_err "$n" "$title" "$ready" \
    || issue_publish_verified gh_err "$n" "$title" "$ready" \
    || st=$?
  [ "$st" -ne 2 ] || die "gh could not read issue #$n: $(gh_reason "$gh_err")"
  [ "$st" -eq 0 ] \
    || die "issue #$n's title and '$ready' label did not verify - checked twice, both failed"
  note "$n"
}

# issue_triage_verified <err_var> <n> <ready> [removed-label...]: 0 only
# once the issue reads back carrying <ready> and none of the removed labels;
# 1 on a mismatch; 2 when the read fails, gh's stderr written into
# <err_var>. Read fresh every call, never cached - the caller re-reads once
# on either status, as issue publish's does. Locals prefixed so no caller's
# variable name is shadowed.
issue_triage_verified() {
  local __itv_err="$1" __itv_n="$2" __itv_ready="$3" __itv_state __itv_labels
  shift 3
  issue_state_labels_read "$__itv_n" __itv_state __itv_labels "$__itv_err" || return 2
  labels_verified "$__itv_labels" "$__itv_ready" "$@" || return 1
}

# issue triage <n> [--override]: moves an open issue to the repo's
# ready-for-agent label, so init --issue can adopt it - the planning close's
# one write to GitHub (#571). One relabel adds ready-for-agent and removes
# whichever other triage-role labels the issue carries, then the labels are
# read back (ADR-0011), and one comment names the label it now carries.
# With --check it writes nothing: the same read and role walk, then one line
# on stdout - ready, the held label, or movable - for the planning hook's
# interviewed-issue step to ask its question from (#989).
cmd_issue_triage() {
  local usage="usage: orch.sh issue triage <n> [--override | --check]"
  local issue="" override=false check=false ready state labels gh_err role label removed=() remove_opts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --override) override=true ;;
      --check) check=true ;;
      -*) die "$usage" ;;
      *) [ -z "$issue" ] || die "$usage"; issue="$1" ;;
    esac
    shift
  done
  case "$issue" in ''|*[!0-9]*) die "$usage" ;; esac
  [ "$check" = false ] || [ "$override" = false ] || die "$usage"
  ready="$(triage_label_for ready-for-agent)"

  issue_state_labels_read "$issue" state labels gh_err \
    || die "gh could not read issue #$issue: $(gh_reason "$gh_err")"
  [ "$state" = OPEN ] \
    || die "issue #$issue is not open - only an open issue is triaged to '$ready'"
  # One walk over the triage roles the issue carries: whether ready-for-agent
  # is among them, the held label - wontfix ahead of ready-for-human, which is
  # not their order in TRIAGE_ROLES - and every other one, to remove.
  local is_ready=false wontfix_label="" human_label="" held
  for role in $TRIAGE_ROLES; do
    label="$(triage_label_for "$role")"
    labels_have "$labels" "$label" || continue
    case "$role" in
      ready-for-agent) is_ready=true; continue ;;
      wontfix) wontfix_label="$label" ;;
      ready-for-human) human_label="$label" ;;
    esac
    removed+=("$label")
  done
  held="${wontfix_label:-$human_label}"
  # A filed finding not yet triaged comes back into the pipeline through
  # finding triage first, which checks it against the default branch
  # (ADR-0031). Only the labels finding triage itself applies - ready-for-agent,
  # ready-for-human, wontfix - show it ran; after that the finding is an
  # ordinary issue, and the interview settles what ready-for-human waited on.
  # The gate reads labels, not history, and --override does not bypass it. Any
  # review:<severity> label marks a finding, not only the severities filed today.
  local finding
  if has_review_label "$labels"; then
    finding="$(review_labels "$labels" | sed -n 1p)"
    [ "$is_ready" = true ] || [ -n "$held" ] \
      || die "issue #$issue is a filed finding ($finding) not yet triaged - triage it with $(finding_triage_cmd)"
  fi
  # --check stops here, before any write, saying what the write would do.
  if [ "$check" = true ]; then
    if [ "$is_ready" = true ]; then note ready
    elif [ -n "$held" ]; then note "$held"
    else note movable
    fi
    return 0
  fi
  # Already ready: nothing to move, and no comment to leave as noise.
  if [ "$is_ready" = true ]; then return 0; fi
  # A deliberate triage decision is the human's to reverse: exit 2 is no
  # failure but a request for that decision, the label found on stdout.
  if [ "$override" = false ] && [ -n "$held" ]; then
    note "$held"
    exit 2
  fi
  for label in ${removed[@]+"${removed[@]}"}; do remove_opts+=(--remove "$label"); done

  local st=0 err
  capture_err err adapter_issue_relabel "$issue" --add "$ready" ${remove_opts[@]+"${remove_opts[@]}"} \
    || die "gh could not relabel issue #$issue: $(gh_reason "$err")"
  # The second attempt's status decides the death: 2 a failed read, 1 a
  # mismatch. Either way the relabel stands and no comment is posted.
  issue_triage_verified gh_err "$issue" "$ready" ${removed[@]+"${removed[@]}"} \
    || issue_triage_verified gh_err "$issue" "$ready" ${removed[@]+"${removed[@]}"} \
    || st=$?
  [ "$st" -ne 2 ] || die "gh could not read issue #$issue: $(gh_reason "$gh_err")"
  [ "$st" -eq 0 ] \
    || die "issue #$issue's '$ready' label did not verify - checked twice, both failed"

  local tmp
  tmp="$(mktemp)"
  printf 'An orchestrator planning session triaged this issue to `%s`.\n' "$ready" >"$tmp"
  capture_err err adapter_issue_comment "$issue" "$tmp" \
    || warn "warning: issue #$issue is labelled $ready, but gh could not post the triage comment on it: $(gh_reason "$err")"
  rm -f "$tmp"
}
