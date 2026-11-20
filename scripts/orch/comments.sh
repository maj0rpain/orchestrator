# shellcheck shell=bash
# comments.sh - the Comments module: a concept module with no orch.sh noun of
# its own, owning how an issue's or a PR's comments are read for orch.sh: the
# one reader of the trusted comments (comments_trusted_read), the two dying
# wrappers over it (comments_trusted, comments_rendered), the one definition of
# the rendered shape (COMMENTS_RENDER_JQ), the render step (comments_render)
# and the split of a rendered file into one file per comment (comments_split).
# No adapter renders: the adapters answer raw JSON, and rendering happens here,
# after the trust filter (Trust module).
# No function here passes a comment-sized value as a command-line argument: a
# comment list travels through stdin, here-strings and `printf -v` alone.
# Its tests: scripts/test/orch/comments.sh.
# Sourced by orch.sh, after common.sh.

# The shape every comment read renders in: each comment opened by a marker line
# naming its author and gh's ISO-8601 timestamp, one blank line between
# comments and bodies unescaped; nothing at all for none. render_comments turns
# an array of normalised comments (author a login string, as
# comments_trusted_read assigns them) into the joined text.
COMMENTS_RENDER_JQ='def render_comments: [.[] | "<!-- comment @\(.author) \(.createdAt) -->\n\(.body)"] | select(length > 0) | join("\n\n");'

# comments_trusted_read <issue|pr> <n> <out_var> <err_var>: issue or PR <n>'s
# comments, read through adapter_issue_comments or adapter_pr_comments, as one
# JSON array of the trusted authors' (Trust module) comments, each
# {author, createdAt, body, url} with author the login as a string and no
# authorAssociation, assigned to <out_var>. It never dies of its own: on success
# it returns 0 with <err_var> empty; on a kind other than issue or pr it returns
# 1 with both <out_var> and <err_var> empty (no gh call was made, so no gh
# reason exists); on a gh failure it returns 1 with <out_var> empty and gh's
# reason (gh_reason) in <err_var>; on an answer that is not a comment list it
# returns 1 with both empty. A Repo that cannot be resolved dies too, in gh's
# guard, which is not trapped here. It runs in the caller's shell, so the Trust
# filter's stderr line, `#<n>` naming the issue or PR, reaches the real stderr.
# Locals prefixed so no caller's variable name is shadowed.
comments_trusted_read() {
  local __ctr_kind="$1" __ctr_n="$2" __ctr_raw __ctr_gh_err __ctr_filtered __ctr_kept
  printf -v "$3" '%s' ''
  printf -v "$4" '%s' ''
  case "$__ctr_kind" in
    issue) gh_capture __ctr_raw __ctr_gh_err adapter_issue_comments "$__ctr_n" ;;
    pr) gh_capture __ctr_raw __ctr_gh_err adapter_pr_comments "$__ctr_n" ;;
    *) return 1 ;;
  esac || {
    printf -v "$4" '%s' "$(gh_reason "$__ctr_gh_err")"
    return 1
  }
  __ctr_filtered="$(jq -c '.comments | map({author: .author.login, authorAssociation, createdAt, body, url})' \
    2>/dev/null <<<"$__ctr_raw" | trust_filter_comments "$__ctr_n")" || return 1
  [ -n "$__ctr_filtered" ] || return 1
  __ctr_kept="$(jq -c 'map(del(.authorAssociation))' <<<"$__ctr_filtered")" || return 1
  printf -v "$3" '%s' "$__ctr_kept"
}

# comments_render: the normalised comments array on stdin (what
# comments_trusted_read assigns), on stdout rendered through
# COMMENTS_RENDER_JQ - nothing for none, no placeholder for a dropped comment.
# Non-zero when stdin is not a comment array.
comments_render() {
  jq -r "$COMMENTS_RENDER_JQ"' render_comments'
}

# comments_trusted [--exit 2] [--hint <h>] <issue|pr> <what> <n> <var>: issue or
# PR <n>'s trusted comments as a JSON array (comments_trusted_read's), assigned
# to <var>; the Trust filter's stderr line names <n>. A gh failure dies as "gh
# could not <what>" (--hint passed on to gh_die, never added to the parse
# failure); a comment object that does not parse dies as "could not <what>: its
# comments did not parse", both with status 1, or status 2 under --exit 2 (a
# caller that reserves exit 1, like pr comments). The options are
# die_opt_check's and may come in either order. A kind other than issue or pr is
# a misuse: it dies as "comments_trusted: unknown kind: <kind> (want issue|pr)"
# with status 1, even under --exit 2, before any gh call.
comments_trusted() {
  local __ct_opts=() __ct_exit=() __ct_err __ct_out
  while [ "${1-}" = --hint ] || [ "${1-}" = --exit ]; do
    die_opt_check comments_trusted $# "$@"
    [ "$1" != --exit ] || __ct_exit=(--exit 2)
    __ct_opts+=("$1" "$2"); shift 2
  done
  case "$1" in issue | pr) ;; *) die "comments_trusted: unknown kind: $1 (want issue|pr)" ;; esac
  comments_trusted_read "$1" "$3" __ct_out __ct_err || {
    [ -z "$__ct_err" ] || gh_die ${__ct_opts[@]+"${__ct_opts[@]}"} "$2" "$__ct_err"
    die_hinted ${__ct_exit[@]+"${__ct_exit[@]}"} "could not $2: its comments did not parse"
  }
  printf -v "$4" '%s' "$__ct_out"
}

# comments_rendered [--exit 2] [--hint <h>] <issue|pr> <what> <n> <var>:
# comments_trusted's comments rendered by comments_render, assigned to <var>;
# no placeholder for a dropped comment. Its failures (a kind misuse included),
# --exit and --hint are comments_trusted's.
comments_rendered() {
  local __cd_opts=() __cd_exit=() __cd_kept __cd_out
  while [ "${1-}" = --hint ] || [ "${1-}" = --exit ]; do
    die_opt_check comments_rendered $# "$@"
    [ "$1" != --exit ] || __cd_exit=(--exit 2)
    __cd_opts+=("$1" "$2"); shift 2
  done
  comments_trusted ${__cd_opts[@]+"${__cd_opts[@]}"} "$1" "$2" "$3" __cd_kept
  __cd_out="$(comments_render <<<"$__cd_kept")" \
    || die_hinted ${__cd_exit[@]+"${__cd_exit[@]}"} "could not $2: its comments did not parse"
  printf -v "$4" '%s' "$__cd_out"
}

# comments_split <file> <dir>: splits <file>, comments in its rendered shape,
# into one file per comment under <dir>, numbered from 1 in order, each holding
# the comment's body alone. A comment opens at its marker line, the one
# COMMENTS_RENDER_JQ renders.
comments_split() {
  awk -v d="$2" '
    /^<!-- comment @[^ ]* [^ ]* -->$/ { if (out != "") close(out); out = d "/" (++k); printf "" >out; next }
    out != "" { print >out }' "$1"
}
