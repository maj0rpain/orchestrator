# shellcheck shell=bash
# comments.sh - the Comments module: a concept module with no orch.sh noun of
# its own, owning how an issue's or a PR's comments are read for orch.sh: the
# one reader of the trusted comments (comments_trusted_read). The comments a
# converted noun renders are rendered in the Python package (orch/comments.py).
# No function here passes a comment-sized value as a command-line argument: a
# comment list travels through stdin, here-strings and `printf -v` alone.
# Its tests: scripts/test/orch/comments.sh.
# Sourced by orch.sh, after common.sh.

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
