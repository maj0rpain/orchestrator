# shellcheck shell=bash
# base.sh - the default-branch reader the bash nouns left call:
# default_branch_into, which state.sh's flow-base fallback reads. The reader
# sets a caller-named variable in the caller's own shell, so the first read
# memoises the answer (DEFAULT_BRANCH, DEFAULT_BRANCH_SOURCE) for the rest of
# that shell, with nothing to arrange beforehand. A reader that runs inside a
# $(...) subshell memoises only for that subshell, which never hands its
# variables back. default_branch_seed is the memo's one writer;
# default_branch_local is the memo-free local fallback under it. The base and
# default-branch nouns are Python (ADR-0067), in orch/base.py beside the Python
# copies of these readers.
# Its tests: scripts/test/orch/base.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# default_branch_local: prints origin/HEAD's branch (read in full, never
# --short: a local branch named origin/<b> makes the short name
# remotes/origin/<b>; valid branch names only), else the literal guess main.
# Returns 0 when origin/HEAD named the branch, 1 when it fell back to main.
# Never asks GitHub and sets no memo variable: the one home of the local
# fallback rule, used by default_branch_seed. Its Python copy is
# orch.base's default_branch_local, which doctor reads.
default_branch_local() {
  local head_ref b
  head_ref="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || head_ref=""
  b="${head_ref#refs/remotes/origin/}"
  if is_branch_name "$b"; then printf '%s\n' "$b"; return 0; fi
  printf '%s\n' main
  return 1
}

# default_branch_seed [<github-answer>]: the one writer of the default-branch
# memo. Sets DEFAULT_BRANCH (the name) and DEFAULT_BRANCH_SOURCE in the current
# shell: github (the answer, when it is a valid branch name), else origin-head
# (origin/HEAD, via default_branch_local) or fallback (the literal guess main,
# also via default_branch_local). Asks GitHub nothing and ignores any existing
# memo.
default_branch_seed() {
  local answer="${1:-}" b
  if is_branch_name "$answer"; then
    b="$answer"
    DEFAULT_BRANCH_SOURCE=github
  elif b="$(default_branch_local)"; then
    DEFAULT_BRANCH_SOURCE=origin-head
  else
    DEFAULT_BRANCH_SOURCE=fallback
  fi
  DEFAULT_BRANCH="$b"
}

# default_branch_resolve: seeds the memo through default_branch_seed, with
# GitHub's answer when it can get one.
# Private to the readers. Memoised in the shell that runs it: it returns at
# once, asking nothing, when DEFAULT_BRANCH_SOURCE is already set in the
# current shell.
#
# Ask GitHub first. refs/remotes/origin/HEAD is a *local cached pointer* frozen
# at clone time - in a clone taken while a feature branch was checked out it
# names that branch, which would silently base every feature branch off the
# wrong place. It is a fallback for repos gh cannot answer for, not the primary
# source. Each candidate counts only when it is a valid branch name, so noise
# around gh's answer - or a failed gh's output - falls through to the next
# (#465).
#
# GitHub is asked only when the repo resolves - adapter_repo_default_branch
# takes it positionally, since `gh repo view` ignores GH_REPO - and a checkout
# with none falls through to the local pointer rather than dying: the answer
# has always been best-effort, as it is for its Python copy, orch/base.py's
# default_branch, which init, base show and default-branch ask before anything
# needs GitHub.
default_branch_resolve() {
  local b=""
  [ -z "${DEFAULT_BRANCH_SOURCE:-}" ] || return 0
  if repo_resolve; then
    b="$(adapter_repo_default_branch "$REPO_NAME" 2>/dev/null)" || b=""
  fi
  default_branch_seed "$b"
}

# default_branch_into <var> [<source-var>]: sets <var> to the default branch's
# name and, with a second variable, <source-var> to the memo's source (github,
# origin-head or fallback), in the caller's shell. Never fails.
default_branch_into() {
  default_branch_resolve
  printf -v "$1" '%s' "$DEFAULT_BRANCH"
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$DEFAULT_BRANCH_SOURCE"; fi
  return 0
}

# Whether $1 is a valid branch name (git check-ref-format --branch rejects an
# empty one).
is_branch_name() {
  git check-ref-format --branch "$1" >/dev/null 2>&1
}
