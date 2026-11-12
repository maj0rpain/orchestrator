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
  label_listed "$labels" "$want" || return 1
  for l in "$@"; do
    ! label_listed "$labels" "$l" || return 1
  done
}

# open_issue_read [--hint <h>] <n> <not-open message> <labels_var>
# [<body_var>]: reads issue <n> once through the gh adapter - its body too,
# only when <body_var> is given - and writes its labels (one per line,
# possibly none) and its body into the caller-named variables. A failed read
# dies through gh_die "read issue #<n>", with --hint passed on as given; an
# issue that is not OPEN dies with <not-open message>, verbatim, since the
# callers' messages are not one shape. It checks no label: each caller keeps
# its own label test.
# Out-params through `printf -v`, its locals prefixed so no caller's variable
# name is shadowed.
open_issue_read() {
  local __oir_hint=() __oir_state __oir_labels __oir_body __oir_err
  if [ "${1-}" = --hint ]; then
    die_opt_check open_issue_read $# "$@"
    __oir_hint=(--hint "$2"); shift 2
  fi
  if [ $# -ge 4 ]; then
    issue_state_labels_body_read "$1" __oir_state __oir_labels __oir_body __oir_err \
      || gh_die ${__oir_hint[@]+"${__oir_hint[@]}"} "read issue #$1" "$__oir_err"
  else
    issue_state_labels_read "$1" __oir_state __oir_labels __oir_err \
      || gh_die ${__oir_hint[@]+"${__oir_hint[@]}"} "read issue #$1" "$__oir_err"
  fi
  [ "$__oir_state" = OPEN ] || die "$2"
  printf -v "$3" '%s' "$__oir_labels"
  [ $# -lt 4 ] || printf -v "$4" '%s' "$__oir_body"
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

# The issue's body as plain multi-line text: what agents read, with the Read
# tool, beside `issue comments` (#1143). With --json, the issue's title, body,
# labels and comments as ISSUE_JSON_JQ's object - the machine form, for
# scripts: compact JSON puts the whole issue on one line, which Read cuts off.
cmd_issue_fetch() {
  local issue="$1" file="$2" as_json="${3:-}"
  trust_warn_issue "$issue"
  if [ -n "$as_json" ]; then
    local json
    issue_json_trusted "read issue #$issue" "$issue" json
    file_write_atomic "$file" "$json"$'\n' || die "could not write $file"
    return
  fi
  gh_or_die --file "$file" "read the body of issue #$issue" \
    issue_body_lf "$issue"
}

# issue_body_lf <n>: issue <n>'s body on stdout with every carriage return
# removed, so GitHub's web-UI CRLF lines reach the spec review as LF. A failed
# read fails the pipeline, stderr untouched. Plain fetch only:
# adapter_issue_body stays byte-exact for the ticket module's CRLF-preserving
# rewrites.
issue_body_lf() (
  set -o pipefail
  adapter_issue_body "$1" | tr -d '\r'
)

# issue_json_trusted <what> <n> <var>: issue <n> as ISSUE_JSON_JQ's object minus
# the comments of untrusted authors (Trust module), authorAssociation deleted
# from the rest, so the published shape is unchanged; assigned to <var>. A gh
# failure dies as "gh could not <what>". Run in the caller's shell, never under
# capture, so the trust filter's stderr line reaches the real stderr.
issue_json_trusted() {
  local __ijt_raw __ijt_kept __ijt_out
  gh_or_die --out __ijt_raw "$1" adapter_issue_json "$2"
  __ijt_kept="$(comments_trust_filter "$2" <<<"$__ijt_raw")" \
    || die "could not read the comments of issue #$2: its comments did not parse"
  __ijt_out="$(jq -c --argjson c "$__ijt_kept" '.comments = ($c | map(del(.authorAssociation)))' <<<"$__ijt_raw")" \
    || die "could not read the comments of issue #$2"
  printf -v "$3" '%s' "$__ijt_out"
}

# comments_trust_filter <n>: a raw comment object (adapter_issue_comments' or an
# issue's) on stdin, on stdout its comments kept to the trusted authors' (Trust
# module) as a compact JSON array; the Trust filter's stderr line names `#<n>`,
# the issue or PR number. Non-zero when stdin does not parse, its jq error
# silenced.
comments_trust_filter() {
  jq -c .comments 2>/dev/null | trust_filter_comments "$1"
}

# comments_render: a JSON array of comments on stdin, on stdout rendered through
# COMMENTS_RENDER_JQ with each author's login - nothing for none, no
# placeholder for a dropped comment.
comments_render() {
  jq -r "$COMMENTS_RENDER_JQ"' render_comments(.author.login)'
}

# comments_render_trusted <n>: adapter_issue_comments' raw JSON on stdin, on
# stdout the comments of trusted authors rendered through COMMENTS_RENDER_JQ as
# it renders them - nothing for none, no placeholder for a dropped
# comment. Non-zero when stdin is not a comment object. <n> is the issue or PR
# number; the trust filter's stderr line names `#<n>`.
comments_render_trusted() {
  comments_trust_filter "$1" | comments_render
}

# comments_trusted [--exit 2] [--hint <h>] <adapter> <what> <n> <var>: issue or
# PR <n>'s comments, read by <adapter> (adapter_issue_comments or
# adapter_pr_comments), kept to the trusted authors' (Trust module) as a JSON
# array, assigned to <var>; the Trust filter's stderr line names <n>. A gh
# failure dies as "gh could not <what>" (--hint passed on to gh_or_die, never
# added to the parse failure); a comment object that does not parse dies as
# "could not <what>: its comments did not parse", both with status 1, or status
# 2 under --exit 2 (a caller that reserves exit 1, like pr comments; also passed
# on to gh_or_die). The options are die_opt_check's and may come in either
# order. Out-params through `printf -v`, its locals prefixed so no caller's
# variable name is shadowed.
comments_trusted() {
  comments_read keep "$@"
}

# comments_rendered [--exit 2] [--hint <h>] <adapter> <what> <n> <var>:
# comments_trusted's comments rendered through COMMENTS_RENDER_JQ as
# comments_render_trusted renders them, assigned to <var>; no placeholder for a
# dropped comment. Its failures, --exit and --hint are comments_trusted's.
comments_rendered() {
  comments_read render "$@"
}

# comments_read <keep|render> [--exit 2] [--hint <h>] <adapter> <what> <n>
# <var>: comments_trusted (keep) and comments_rendered (render), with their one
# option parser.
comments_read() {
  local __cr_mode="$1" __cr_opts=() __cr_exit=() __cr_raw __cr_kept __cr_out
  shift
  while [ "${1-}" = --hint ] || [ "${1-}" = --exit ]; do
    die_opt_check comments_trusted $# "$@"
    [ "$1" != --exit ] || __cr_exit=(--exit 2)
    __cr_opts+=("$1" "$2"); shift 2
  done
  gh_or_die ${__cr_opts[@]+"${__cr_opts[@]}"} --out __cr_raw "$2" "$1" "$3"
  __cr_kept="$(comments_trust_filter "$3" <<<"$__cr_raw")" \
    || die_hinted ${__cr_exit[@]+"${__cr_exit[@]}"} "could not $2: its comments did not parse"
  if [ "$__cr_mode" = render ]; then
    __cr_out="$(comments_render <<<"$__cr_kept")" \
      || die_hinted ${__cr_exit[@]+"${__cr_exit[@]}"} "could not $2: its comments did not parse"
  else
    __cr_out="$__cr_kept"
  fi
  printf -v "$4" '%s' "$__cr_out"
}

# The comments `issue comments` writes (#1116), from the issue's comments,
# filtered or not as the caller chooses (the spec review's own changelogs, the
# marked comments of kind spec-review, are dropped by default and kept with
# --with-spec-review): rendered through COMMENTS_RENDER_JQ, as every comments
# read renders them; nothing at all when none is left. It reads ISSUE_JSON_JQ's
# object, whose author is already the login.
ISSUE_COMMENTS_KEPT_JQ="$COMMENTS_RENDER_JQ"' .comments | render_comments(.author)'

# Every comment on the issue but the untrusted authors', and by default but the
# spec review's own changelogs, in the rendered shape - so the spec review reads
# the comments beside the body without its earlier rounds. Filtered here rather
# than in the adapter, from the issue's trusted structured read, never by
# splitting the joined text. No comments is an empty file, not an error; the
# file is written only once the read has succeeded. With --with-spec-review
# (#1921; orch-questions passes it) the changelogs are kept, the one difference.
cmd_issue_comments() {
  local issue="$1" file="$2" keep_reviews="${3:-}" json text
  issue_json_trusted "read the comments of issue #$issue" "$issue" json
  if [ -n "$keep_reviews" ]; then
    text="$(jq -r "$ISSUE_COMMENTS_KEPT_JQ" <<<"$json")"
  else
    text="$(marked_comment_drop spec-review <<<"$json" | jq -r "$ISSUE_COMMENTS_KEPT_JQ")"
  fi \
    || die "could not read the comments of issue #$issue"
  # $(...) drops the trailing newline jq -r printed; put it back unless empty.
  file_write_atomic "$file" "${text:+$text$'\n'}" \
    || die "could not write the comments of issue #$issue to $file"
}

cmd_issue_update() {
  local issue="$1" file="$2"
  [ -f "$file" ] || die "body file not found: $file"
  # --body-file, never --body: an issue body carries tables, fences, and
  # `#nn` references, and a heredoc through a shell is where those get
  # mangled.
  gh_or_die "replace the body of issue #$issue" \
    adapter_issue_body_edit "$issue" "$file"
}

cmd_issue_comment() {
  local issue="$1" file="$2"
  [ -f "$file" ] || die "body file not found: $file"
  gh_or_die "comment on issue #$issue" adapter_issue_comment "$issue" "$file"
}

cmd_issue() {
  local op="${1:-}"
  shift || true
  case "$op" in
    fetch|update|comment|comments)
      # The op's one optional flag is named here and nowhere else (--json for
      # fetch, --with-spec-review for comments, none for the rest); the usage
      # line and the argument check both read it. The flag is only the third
      # argument; any other shape is a usage error.
      local flag
      case "$op" in
        fetch) flag=--json ;;
        comments) flag=--with-spec-review ;;
        *) flag="" ;;
      esac
      local usage="usage: orch.sh issue $op <n> <file>${flag:+ [$flag]}"
      [ $# -eq 2 ] \
        || { [ -n "$flag" ] && [ $# -eq 3 ] && [ "$3" = "$flag" ]; } \
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
  local issue="" completed=false dup="" dup_given=false file="" file_given=false
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
    gh_or_die --hint "--duplicate-of needs gh 2.102 or newer" "close issue #$issue" \
      adapter_issue_close "$issue" --duplicate-of "$dup" --comment "$comment"
  else
    gh_or_die "close issue #$issue" \
      adapter_issue_close "$issue" --reason completed --comment "$comment"
  fi
}

# issue ready <n>: exit 0 when issue <n> carries the repo's ready-for-agent
# label, 1 when it does not - so exit 1 is a meaningful "no", and a usage
# error or a gh failure exits 2 (die2), as ticket exists does. The spec
# skill's rewrite mode reads it to warn when a rewritten issue lacks the label.
cmd_issue_ready() {
  local usage="usage: orch.sh issue ready <n>"
  [ $# -eq 1 ] || die2 "$usage"
  # state is the read's throwaway half: only the labels are checked here.
  # shellcheck disable=SC2034
  local issue="$1" ready state labels gh_err
  case "$issue" in ''|*[!0-9]*) die2 "issue must be a plain issue number, got: $issue ($usage)" ;; esac
  ready="$(triage_label_for ready-for-agent)"
  issue_state_labels_read "$issue" state labels gh_err \
    || gh_die --exit 2 "read issue #$issue" "$gh_err"
  label_listed "$labels" "$ready"
}

# issue_publish_verified <err_var> <n> <title> <label>: 0 only once the
# created issue reads back with the title it was given and the
# ready-for-agent role's label among its labels; 1 on a mismatch; 2 when the
# read fails, gh's stderr written into <err_var>, so a failed read is never
# reported as a mismatch. Read fresh every call, never cached -
# verify_twice retries this once on either status.
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
  local title="$1" body_file="$2" ready n
  [ -n "$title" ] || die "the title is empty"
  [ -f "$body_file" ] || die "body file not found: $body_file"
  ready="$(triage_label_for ready-for-agent)"
  gh_or_die --out n "create the issue" \
    adapter_issue_create "$title" "$body_file" "$ready"
  verify_twice "read issue #$n" \
    "issue #$n's title and '$ready' label did not verify - checked twice, both failed" \
    issue_publish_verified "$n" "$title" "$ready"
  note "$n"
}

# issue_triage_verified <err_var> <n> <ready> [removed-label...]: 0 only
# once the issue reads back carrying <ready> and none of the removed labels;
# 1 on a mismatch; 2 when the read fails, gh's stderr written into
# <err_var>. Read fresh every call, never cached - verify_twice
# re-reads once on either status. Locals prefixed so no caller's variable name
# is shadowed.
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
  local issue="" override=false check=false ready labels role label removed=() remove_opts=()
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

  open_issue_read "$issue" "issue #$issue is not open - only an open issue is triaged to '$ready'" labels
  # One walk over the triage roles the issue carries: whether ready-for-agent
  # is among them, the held label - wontfix ahead of ready-for-human, which is
  # not their order in TRIAGE_ROLES - and every other one, to remove.
  local is_ready=false wontfix_label="" human_label="" held
  for role in $TRIAGE_ROLES; do
    label="$(triage_label_for "$role")"
    label_listed "$labels" "$label" || continue
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
  # review:<severity> label marks a finding, not only the severities filed
  # today.
  local finding
  if finding_untriaged "$labels"; then
    finding="$(review_labels "$labels" | sed -n 1p)"
    die "issue #$issue is a filed finding ($finding) not yet triaged - triage it with $(finding_triage_cmd)"
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

  local err
  gh_or_die "relabel issue #$issue" \
    adapter_issue_relabel "$issue" --add "$ready" ${remove_opts[@]+"${remove_opts[@]}"}
  # Either death leaves the relabel standing and posts no comment.
  verify_twice "read issue #$issue" \
    "issue #$issue's '$ready' label did not verify - checked twice, both failed" \
    issue_triage_verified "$issue" "$ready" ${removed[@]+"${removed[@]}"}

  local tmp
  tmp="$(mktemp)" || die "could not create a temp file for the triage comment on issue #$issue"
  printf 'An orchestrator planning session triaged this issue to `%s`.\n' "$ready" >"$tmp"
  capture_err err adapter_issue_comment "$issue" "$tmp" \
    || warn "warning: issue #$issue is labelled $ready, but gh could not post the triage comment on it: $(gh_reason "$err")"
  rm -f "$tmp"
}
