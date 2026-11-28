# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# git_fails_bin <pattern>: a fails_bin (the failing-command fixture,
# scripts/test/fails.sh) for git.
git_fails_bin() { fails_bin git "$1"; }

# worktree_list_fails_bin: a git_fails_bin where git worktree list fails and
# nothing else does, so it fails every checkout_parse reader.
worktree_list_fails_bin() { git_fails_bin '" worktree list "*'; }

# fresh_dir: a new empty directory's physical path, as git records it.
fresh_dir() { (cd "$(mktemp -d)" && pwd -P); }

# --- checkout (#1078) ---------------------------------------------------------
# The Checkout module's reads of the repo's checkouts: the main checkout.
# Checked against real temporary checkouts, through what each prints.
echo
echo "checkout"
new_repo >/dev/null
top="$(pwd -P)"
side="$(fresh_dir)/side"
git worktree add -q --detach "$side"

assert_eq "main_checkout prints the main checkout from a side checkout" \
  "$(cd "$side" && sourced_orch main_checkout)" "$top"

# main_checkout_or_die: what main_checkout prints, or the message for when git
# worktree list fails.
worktree_list_fails="$(worktree_list_fails_bin)"
assert_eq "main_checkout_or_die prints the main checkout" \
  "$(cd "$side" && sourced_orch main_checkout_or_die)" "$top"
out="$(PATH="$worktree_list_fails:$PATH" sourced_orch main_checkout_or_die 2>&1)"; st=$?
assert_status "main_checkout_or_die dies on a failed walk" "$st" 1
assert_contains "main_checkout_or_die names the walk failure" "$out" \
  "orch: could not read the checkouts - git worktree list failed"

# Cost: git's own trace counts the processes a lookup spawns. GIT_TRACE is
# exported only after orch.sh is sourced, whose own rev-parse is not counted.
trace_file="$(mktemp)"
(cd "$side" && sourced_orch_script 'export GIT_TRACE="$1"; shift; "$@"' "$trace_file" main_checkout) \
  >/dev/null
assert_eq "main_checkout spawns one git process" \
  "$(grep -c "trace: built-in: git " "$trace_file")" "1"
out="$(PATH="$worktree_list_fails:$PATH" sourced_orch main_checkout 2>/dev/null)"; st=$?
assert_status "main_checkout fails on a failed walk" "$st" 1
assert_eq "and main_checkout prints nothing" "$out" ""
