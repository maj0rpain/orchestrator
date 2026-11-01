#!/usr/bin/env bash
#
# Sourced by every suite runner in all.sh's suites list, as its second code
# line, so a suite started from a git hook never acts on the caller's
# repository. Defines one name list and one function, and runs nothing.
#
# TEST_GIT_ENV_IDENTITY: the six commit-identity variables, the one list of
# them - test_git_env_clear unsets them, and the isolation section checks them.
TEST_GIT_ENV_IDENTITY=(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
  GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE)
#
# test_git_env_clear: unsets every variable `git rev-parse --local-env-vars`
# prints (GIT_DIR, GIT_INDEX_FILE, ... - git's own list, read at runtime), and
# the TEST_GIT_ENV_IDENTITY variables. Other GIT_* knobs, GIT_TRACE and
# GIT_SSH_COMMAND among them, stay. When git exits non-zero or prints nothing
# it prints "<runner>: cannot list git's repo-local variables" on stderr and
# returns 1, for the runner to exit on.
test_git_env_clear() {
  local runner vars name
  runner="$(basename "${BASH_SOURCE[1]:-$0}")"
  vars="$(git rev-parse --local-env-vars)" && [ -n "$vars" ] || {
    echo "$runner: cannot list git's repo-local variables" >&2
    return 1
  }
  while IFS= read -r name; do
    [ -n "$name" ] && unset "$name"
  done <<<"$vars"
  unset "${TEST_GIT_ENV_IDENTITY[@]}"
}
