# shellcheck shell=bash
# shellcheck disable=SC2034 # its assignments are read by the section files, linted apart
# The orch.sh suite's shared setup and summary, which scripts/test/orch_test.sh
# reads and evals; never run on its own. The shared setup runs from the
# `# >>> shared setup` line to the `# >>> summary` line, before any section; the
# summary runs from the `# >>> summary` line to the end of the file, after them.
# The `# ---` blocks inside the shared setup are setup, not sections.
# >>> shared setup
PASS=0
FAIL=0
SKIP=0

# The host signals doctor reads: the shell running the tests is often itself
# a Claude Code or Junie session. Each test names its host.
unset ORCHESTRATOR_HOST CLAUDECODE JUNIE_EXTENSION_ROOT JUNIE_SHIM_PATH

# ORCH, GH_ADAPTER_FAKE and PLUGIN_ROOT are set by scripts/test/orch_test.sh,
# the runner, from its own location, before the cd below. CALLER_HOME keeps
# the HOME the suite started with, only for the isolation section to check
# HOME differs from it. XDG_CONFIG_HOME and GIT_CONFIG_GLOBAL go too: git
# would otherwise still read the caller's global config through them.
CALLER_HOME="$HOME"
SUITE_CWD="$(mktemp -d)" && cd "$SUITE_CWD" || {
  echo "orch_test.sh: cannot cd into a fresh temp directory" >&2; exit 1; }
SUITE_HOME="$(mktemp -d)" || {
  echo "orch_test.sh: cannot create a temp HOME" >&2; exit 1; }
export HOME="$SUITE_HOME"
unset CLAUDE_PLUGIN_ROOT XDG_CONFIG_HOME GIT_CONFIG_GLOBAL

# The real-gh guard: a stub gh, first on PATH before SUITE_PATH is captured so
# restore_suite_env keeps it, that appends its arguments to GH_GUARD_LOG, in
# this setup's own temp directory, and exits 1. It is a guard, not a fake: it
# answers nothing, so a section that reaches gh without fake_github or the
# fixture gh (both of which win over it) fails, and the summary turns each
# logged call into one FAIL naming it.
GH_GUARD_DIR="$(mktemp -d)" && mkdir "$GH_GUARD_DIR/bin" &&
  GH_GUARD_LOG="$GH_GUARD_DIR/calls.log" && : >"$GH_GUARD_LOG" || {
  echo "orch_test.sh: cannot create the real-gh guard's log" >&2; exit 1; }
cat >"$GH_GUARD_DIR/bin/gh" <<GH || exit 1
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" | tr '\n' ' ' | sed 's/ \$//' >>"$GH_GUARD_LOG"
echo >>"$GH_GUARD_LOG"
echo "orch_test.sh: a section called the real gh: gh \$*" >&2
exit 1
GH
chmod +x "$GH_GUARD_DIR/bin/gh" || exit 1
PATH="$GH_GUARD_DIR/bin:$PATH"

# The environment every section starts from. healthy_repo exports HOME and
# CLAUDE_PLUGIN_ROOT and puts the fixture gh on PATH, so a section that calls
# it, or that calls gh_fixture itself, ends with restore_suite_env, leaving the
# next section the environment it had - fake_github's two exports and
# gh_fixture's GH_FIXTURE included. A section that exported more names passes
# them to restore_suite_env to unset them too.
SUITE_PATH="$PATH"
restore_suite_env() {
  unset CLAUDE_PLUGIN_ROOT GH_REPO GH_FIXTURE ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE "$@"
  HOME="$SUITE_HOME"; PATH="$SUITE_PATH"
}

# ORCH_TEST_QUIET=1 hides the ok lines; the count, FAIL and skip lines,
# section headers and the summary still print.
ok()   { PASS=$((PASS + 1)); [ -n "${ORCH_TEST_QUIET:-}" ] || printf '  ok   %s\n' "$1"; }
bad()  { print_fail "$1" "$2"; FAIL=$((FAIL + 1)); }
skip() { printf '  skip %s\n     %s\n' "$1" "$2"; SKIP=$((SKIP + 1)); }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}
assert_ne() {
  if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "expected anything but '$3'"; fi
}
assert_contains() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not contain '$3': $2" ;; esac
}
assert_not_contains() {
  case "$2" in *"$3"*) bad "$1" "output contained '$3': $2" ;; *) ok "$1" ;; esac
}
assert_status() {
  if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "expected exit $3, got $2"; fi
}
# The CI classifier's verdict is its first line and the detail lines below it are
# not the assertion, so most of these read one line out of a captured $out.
assert_first_line() {
  assert_eq "$1" "$(printf '%s\n' "$2" | sed -n 1p)" "$3"
}

# A fresh repo with one commit, an empty docs/agents/ for a labels doc and an
# origin of https://github.com/o/r.git (so it resolves to the repo o/r), cwd
# inside it. No setup is required of it (ADR-0028).
new_repo() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  mkdir -p "$d/docs/agents"
  echo "# repo" >"$d/README.md"
  git -C "$d" add -A
  git -C "$d" commit -qm init
  git -C "$d" remote add origin https://github.com/o/r.git
  cd "$d" || exit 1
  printf '%s\n' "$d"
}

# bare_origin <path>: point origin at a local bare repo. A path names no GitHub
# repo, so it names one through GH_REPO, as a caller would (#520); neither
# the fixture gh nor the adapter fake checks the repo; the fixture logs
# GH_REPO in env.log. restore_suite_env unsets it again.
bare_origin() { git remote set-url origin "$1"; export GH_REPO=acme/widgets; }

# new_repo_with_origin [branch]: new_repo, plus tracking refs for its origin:
# origin/<branch> (default: the checked-out branch) set to HEAD, and
# origin/HEAD pointing at it. Call it in the current shell, never inside $(...): new_repo cd's.
new_repo_with_origin() {
  new_repo >/dev/null
  local b="${1:-$(git branch --show-current)}"
  git update-ref "refs/remotes/origin/$b" HEAD
  git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$b"
}

# tw_repo: a fresh repo with a bare origin it has pushed to, on a feature
# branch, cwd inside it. Used by the ticket-worktree and ticket merge
# sections. Call it in the current shell: new_repo cd's.
tw_repo() {
  local bare
  new_repo >/dev/null
  bare="$(mktemp -d)/origin.git"
  git init -q --bare "$bare"
  bare_origin "$bare"
  git push -q origin HEAD 2>/dev/null
  git checkout -q -b orch/5-feature
  echo work >feature.txt && git add feature.txt && git commit -qm feature
}

# sc_clone: a fresh clone of a bare origin holding main, cwd inside it, with no
# exclude entries yet. Call it in the current shell: it cd's. sc_seed is the
# repo the origin was pushed from, kept to move origin's main on.
sc_clone() {
  local clone
  new_repo >/dev/null
  sc_seed="$PWD"
  sc_origin="$(mktemp -d)/origin.git"
  git init -q --bare "$sc_origin"
  git -C "$sc_seed" push -q "$sc_origin" HEAD:refs/heads/main
  git -C "$sc_origin" symbolic-ref HEAD refs/heads/main
  clone="$(mktemp -d)/clone"
  git clone -q "$sc_origin" "$clone"
  cd "$clone" || exit 1
  git config user.email test@example.com
  git config user.name Test
  export GH_REPO=acme/widgets
}

# on_disk <path>: present or absent, whether anything is at <path>.
on_disk() { if [ -e "$1" ]; then echo present; else echo absent; fi; }
# exclude_count <line>: how many times <line> appears whole in the current
# clone's shared exclude file, the one every checkout of it reads.
exclude_count() { grep -cxF "$1" "$(git rev-parse --git-common-dir)/info/exclude" || true; }

writeln() { printf '%s\n' "$@"; }
# flat_text: stdin on one line with every whitespace run collapsed to one
# space.
flat_text() { tr -s ' \t\n' '   '; }

# state_fixture <key> <value>: arrange state.json directly, for the keys
# `state set` refuses (phase, branch, pr, iteration, ...) - each owned by a
# command whose guard a test's setup has to step around. It stores values the
# way orch.sh's own writer does: "null" as null, "true" and "false" as a
# boolean, all digits as a number, anything else as a string.
state_fixture() {
  local f tmp
  f="$(git rev-parse --show-toplevel)/.orchestrator/state.json"
  tmp="$(mktemp)"
  jq --arg k "$1" --arg v "$2" '
    .[$k] = (if $v == "null" then null
             elif $v == "true" then true
             elif $v == "false" then false
             elif ($v | test("^[0-9]+$")) then ($v | tonumber)
             else $v end)' "$f" >"$tmp" && mv "$tmp" "$f"
}

complete_plan_handoff() {
  writeln '## Decisions' 'Use X.' '' \
          '## Rejected alternatives' 'Y, because Z.' '' \
          '## Constraints' 'Must run offline.' '' \
          '## Open assumptions' 'Assumes W.' '' \
          '## Host fallbacks' 'None (Claude Code).' >"$1"
}

complete_spec_handoff() {
  writeln '## Spec issue' '#1.' '' \
          '## Seams' 'The CLI.' '' \
          '## Spec review changelog' 'Not reviewed.' '' \
          '## Ticket breakdown' '#1.' '' \
          '## Host fallbacks' 'None (Claude Code).' >"$1"
}

complete_implement_handoff() {
  writeln '## PR' '#3.' '' \
          '## Spec issue' '#1.' '' \
          '## Base SHA' 'abc1234.' '' \
          '## Deviations' 'None.' '' \
          '## Verification' 'scripts/test/orch_test.sh' '' \
          '## Host fallbacks' 'None (Claude Code).' >"$1"
}

# --- doctor harness ---------------------------------------------------------

# The documented triage-label table, in the shape the setup skill writes it:
# a header row, a separator row, and backticked labels in the second column.
labels_doc() {
  writeln '# Triage Labels' '' \
          '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
          '| -------------------------- | -------------------- | ----------- |' \
          '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
          '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready   |' \
          '' 'Edit the right-hand column to match whatever vocabulary you use.' >"$1"
}

# A repo where every --env check passes, so a test can break exactly one thing
# and attribute the result to it.
healthy_repo() {
  new_repo >/dev/null
  git remote set-url origin https://github.com/acme/widgets.git
  labels_doc docs/agents/triage-labels.md
  printf '%s\n' ".orchestrator/" ".scratch/" >>.git/info/exclude
  gh_fixture
  export CLAUDE_PLUGIN_ROOT="$PWD"
  # A throwaway HOME, so no skill store on the machine running the tests
  # reaches doctor's checks.
  HOME="$(mktemp -d)"
  export HOME
}


# fresh_flow <slug>: a section's own starting point - a healthy_repo with a
# flow named <slug> just started in it, at the spec phase, cwd inside it. A
# section that needs a later phase arranges it with state_fixture, or
# review_flow for the review phase.
fresh_flow() { healthy_repo; "$ORCH" init "$1" >/dev/null; }

# review_flow <slug>: fresh_flow, then on to the review phase - leaves a flow
# named <slug> at the review phase with the plan, spec and implement handoffs
# complete, cwd inside it, and whatever healthy_repo exports.
review_flow() {
  fresh_flow "$1"
  complete_plan_handoff "$("$ORCH" handoff path spec)"
  complete_spec_handoff "$("$ORCH" handoff path implement)"
  complete_implement_handoff "$("$ORCH" handoff path review)"
  state_fixture phase review
}

# --- the store-backed gh fake (#280) ------------------------------------------
#
# fake_github: a behaviour test's GitHub. It creates a fresh, empty store and
# exports ORCH_GH_ADAPTER, naming the fake (scripts/test/gh_adapter_fake.sh)
# every orch.sh the test runs sources in place of the real adapter, and
# ORCH_GH_FAKE_STORE, naming the store, a directory, so what one orch.sh
# process wrote is there for the next. restore_suite_env unsets both. The
# store's layout is documented at the top of the fake; the helpers below are a
# test's only hand on it.
fake_github() {
  ORCH_GH_FAKE_STORE="$(mktemp -d)" || return 1
  export ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" ORCH_GH_FAKE_STORE
}

# fake_comment_seed <comments-dir> <author> <created-at> <body>: the body, byte
# for byte, appended as a comment by the fake's own fake_comment_append, so the
# store's comment layout has one writer.
fake_comment_seed() {
  printf '%s' "$4" |
    bash -c 'source "$1"; fake_comment_append "$2" "$3" "$4" /dev/stdin' \
      _ "$GH_ADAPTER_FAKE" "$1" "$2" "$3"
}

# fake_comment_bodies <comments-dir>: the bodies of the directory's comments,
# in order, one blank line between; nothing for none.
fake_comment_bodies() {
  local d="$1" k first=1
  [ -d "$d" ] || return 0
  for k in $(ls "$d" | sort -n); do
    [ "$first" = 1 ] || printf '\n\n'
    first=0
    cat "$d/$k/body"
  done
}

# fake_issue <n> <state> [labels...]: seeds issue #n afresh, open or closed,
# carrying the labels named - no title, body or comments.
fake_issue() {
  local d="$ORCH_GH_FAKE_STORE/issues/$1"
  rm -rf "$d"
  mkdir -p "$d"
  printf '%s\n' "$2" | tr '[:lower:]' '[:upper:]' >"$d/state"
  shift 2
  : >"$d/labels"
  [ $# -eq 0 ] || printf '%s\n' "$@" >"$d/labels"
}

# fake_issue_body <n> <text>: seeds issue #n's body, byte for byte.
fake_issue_body() { printf '%s' "$2" >"$ORCH_GH_FAKE_STORE/issues/$1/body"; }

# fake_comment <n> <author> <created-at> <body>: seeds a comment on issue #n,
# after any it has.
fake_comment() { fake_comment_seed "$ORCH_GH_FAKE_STORE/issues/$1/comments" "$2" "$3" "$4"; }

# fake_next_issue <n>: the number the next issue created takes.
fake_next_issue() { printf '%s\n' "$1" >"$ORCH_GH_FAKE_STORE/next_issue"; }

# Issue #n read back from the store: its state (OPEN or CLOSED), closing
# reason, the issue a duplicate close named, title, body, labels (sorted,
# space-separated, one trailing space) and the bodies of its comments, in
# order, one blank line between.
fake_state_of()  { cat "$ORCH_GH_FAKE_STORE/issues/$1/state" 2>/dev/null; }
fake_reason_of() { cat "$ORCH_GH_FAKE_STORE/issues/$1/reason" 2>/dev/null; }
fake_duplicate_of() { cat "$ORCH_GH_FAKE_STORE/issues/$1/duplicate_of" 2>/dev/null; }
fake_title_of()  { cat "$ORCH_GH_FAKE_STORE/issues/$1/title" 2>/dev/null; }
fake_body_of()   { cat "$ORCH_GH_FAKE_STORE/issues/$1/body" 2>/dev/null; }
fake_labels_of() { sort "$ORCH_GH_FAKE_STORE/issues/$1/labels" 2>/dev/null | tr '\n' ' '; }
fake_comments_of() { fake_comment_bodies "$ORCH_GH_FAKE_STORE/issues/$1/comments"; }

# fake_issues: every issue number the store holds, in order, space-separated.
fake_issues() { ls "$ORCH_GH_FAKE_STORE/issues" 2>/dev/null | sort -n | tr '\n' ' '; }

# fake_snapshot: a digest of the whole store, so a test asserts a read-only
# command left it as it was.
fake_snapshot() {
  (cd "$ORCH_GH_FAKE_STORE" && find . -type f -print0 | sort -z | xargs -0 -r cksum)
}

# fake_pr <n> <state> <head> <base>: seeds PR #n afresh, open, closed or
# merged, from the head branch into the base - no body, comments or commits,
# and not a draft.
fake_pr() {
  local d="$ORCH_GH_FAKE_STORE/prs/$1"
  rm -rf "$d"
  mkdir -p "$d"
  printf '%s\n' "$2" | tr '[:lower:]' '[:upper:]' >"$d/state"
  printf '%s\n' "$3" >"$d/head"
  printf '%s\n' "$4" >"$d/base"
}

# fake_pr_draft <n>: seeds PR #n as a draft.
fake_pr_draft() { : >"$ORCH_GH_FAKE_STORE/prs/$1/draft"; }

# fake_next_pr <n>: the number the next PR opened takes.
fake_next_pr() { printf '%s\n' "$1" >"$ORCH_GH_FAKE_STORE/next_pr"; }

# PR #n read back from the store: its base branch, body, whether it is a draft
# (yes or no), and the bodies of its comments, in order, one blank line
# between.
fake_pr_base_of()  { cat "$ORCH_GH_FAKE_STORE/prs/$1/base" 2>/dev/null; }
fake_pr_body_of()  { cat "$ORCH_GH_FAKE_STORE/prs/$1/body" 2>/dev/null; }
fake_pr_draft_of() { [ -f "$ORCH_GH_FAKE_STORE/prs/$1/draft" ] && echo yes || echo no; }
fake_pr_comments_of() { fake_comment_bodies "$ORCH_GH_FAKE_STORE/prs/$1/comments"; }

# fake_label <name> <colour> <description>: seeds a label the repo already
# has. An unseeded store has no labels.
fake_label() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$ORCH_GH_FAKE_STORE/labels"; }

# fake_labels: the store's labels read back, sorted, one per line as
# "<name><TAB><colour><TAB><description>".
fake_labels() { sort "$ORCH_GH_FAKE_STORE/labels" 2>/dev/null || true; }

# fake_fail <operation> [stderr]: every later call of the named adapter
# operation fails, non-zero, with stderr (default "fake gh: <operation>
# failed") as gh's own error. An explicit empty stderr seeds a failure that
# prints nothing.
fake_fail() {
  mkdir -p "$ORCH_GH_FAKE_STORE/fail"
  if [ -n "${2-x}" ]; then
    printf '%s\n' "${2-fake gh: $1 failed}" >"$ORCH_GH_FAKE_STORE/fail/$1"
  else
    : >"$ORCH_GH_FAKE_STORE/fail/$1"
  fi
}

# fake_fail_after <operation> <n> [stderr]: fake_fail, but the next n calls of
# the operation still succeed - a run of writes that dies part-way. The stderr
# passes through to fake_fail as given, omitted or empty.
fake_fail_after() {
  fake_fail "$1" "${@:3}"
  printf '%s\n' "$2" >"$ORCH_GH_FAKE_STORE/fail/$1.after"
}

# fake_fail_times <operation> <n> [stderr]: the next n calls of the operation
# fail, then it succeeds again - a transient failure. It writes the fail file
# itself rather than through fake_fail, so stderr defaults to empty, not to
# fake_fail's message: a failure a retry absorbs leaves nothing a test reads.
fake_fail_times() {
  mkdir -p "$ORCH_GH_FAKE_STORE/fail"
  printf '%s' "${3-}" >"$ORCH_GH_FAKE_STORE/fail/$1"
  printf '%s\n' "$2" >"$ORCH_GH_FAKE_STORE/fail/$1.times"
}

# fake_unfail: every operation fake_fail named succeeds again.
fake_unfail() { rm -rf "$ORCH_GH_FAKE_STORE/fail"; }

# fake_sub_issue <parent> <child>...: seeds each child as a sub-issue of the
# parent, after any it has.
fake_sub_issue() {
  local p="$1"
  shift
  mkdir -p "$ORCH_GH_FAKE_STORE/subs"
  printf '%s\n' "$@" >>"$ORCH_GH_FAKE_STORE/subs/$p"
}

# fake_blocker <n> <blocker>...: seeds #n as blocked by each blocker.
fake_blocker() {
  local n="$1"
  shift
  mkdir -p "$ORCH_GH_FAKE_STORE/blocked_by"
  printf '%s\n' "$@" >>"$ORCH_GH_FAKE_STORE/blocked_by/$n"
}

# fake_sub_issues_of <parent>: the parent's sub-issues read back from the
# store, in link order, space-separated - nothing for none.
fake_sub_issues_of() { paste -sd ' ' "$ORCH_GH_FAKE_STORE/subs/$1" 2>/dev/null || true; }

# fake_lag <operation> <n> [stale]: the next n calls of the named operation
# answer stale, as GitHub does for a moment after a write; the call after them
# is current again. An operation that reads answers the stale text given, in
# its own documented shape - or, given none, an empty one.
fake_lag() {
  mkdir -p "$ORCH_GH_FAKE_STORE/lag"
  printf '%s\n' "$2" >"$ORCH_GH_FAKE_STORE/lag/$1"
  if [ $# -ge 3 ]; then printf '%s\n' "$3" >"$ORCH_GH_FAKE_STORE/lag/$1.stale"; fi
}

# fake_lag_after <operation> <k> <n> [stale]: fake_lag, but only once k calls
# of the operation have answered current - a readback that lags after the
# reads ahead of a write did not.
fake_lag_after() {
  local op="$1" k="$2"
  shift 2
  fake_lag "$op" "$@"
  printf '%s\n' "$k" >"$ORCH_GH_FAKE_STORE/lag/$op.after"
}

# fake_body_read <n> <format> [arg...]: seeds issue #n's body so that a read
# of it - the stored body, then a newline, as gh's --jq .body prints it -
# answers exactly what printf prints, which ends in a newline.
fake_body_read() {
  local n="$1" t
  shift
  # shellcheck disable=SC2059 # the format string is the caller's first argument, by design
  t="$(printf "$@"; printf x)"
  t="${t%x}"
  printf '%s' "${t%$'\n'}" >"$ORCH_GH_FAKE_STORE/issues/$n/body"
}

# fake_checks <n> <required|all> <answer>...: scripts PR #n's checks for the
# scope, answered one per call, the last repeating: green, failing (build
# fails, Actions run 4242; lint passes), cancel (build cancelled, run 5150),
# external (a failing outside-CI check, ext-ci, ahead of build failing in run
# 4242), pending, none (no checks reported) or boom (a connection error). An
# unscripted scope has no checks.
fake_checks() {
  local d="$ORCH_GH_FAKE_STORE/checks/$1" scope="$2"
  shift 2
  mkdir -p "$d"
  printf '%s\n' "$@" >"$d/$scope"
  rm -f "$d/$scope.n"
}

# fake_default_branch <answer>: seeds gh's answer to the repo's default branch,
# byte for byte, so a test can seed a polluted or empty one.
fake_default_branch() { printf '%s' "$1" >"$ORCH_GH_FAKE_STORE/default_branch"; }

# fake_offline: every operation fails with a connection error, as with GitHub
# unreachable. fake_online undoes it, and doctor.sh's fake_noauth too.
fake_offline() { : >"$ORCH_GH_FAKE_STORE/offline"; }
fake_online()  { rm -f "$ORCH_GH_FAKE_STORE/offline" "$ORCH_GH_FAKE_STORE/noauth"; }

# --- the fixture gh (adapter contract tests, #280) -----------------------------
#
# gh_fixture: puts a fixture `gh` on PATH for the real adapter operations'
# contract tests, and leaves its directory in GH_FIXTURE. It holds no logic and
# parses no flags: each call looks its whole argv up, byte for byte, among the
# replies gh_reply registered, and answers that reply's stdout, stderr and exit
# status. An argv with no reply fails, exit 127, naming the argv on stderr. Every
# call appends "GH_REPO=<repo> GH_HOST=<host> <argv>" to $GH_FIXTURE/env.log
# (<unset> for an unset one), so a test asserts which repo a call was pinned to.
# A section that calls it ends with restore_suite_env GH_FIXTURE.
gh_fixture() {
  GH_FIXTURE="$(mktemp -d)" || return 1
  export GH_FIXTURE
  mkdir "$GH_FIXTURE/bin" "$GH_FIXTURE/replies"
  cat >"$GH_FIXTURE/bin/gh" <<'GH'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")/.." && pwd)"
printf 'GH_REPO=%s GH_HOST=%s %s\n' "${GH_REPO-<unset>}" "${GH_HOST-<unset>}" "$*" >>"$d/env.log"
argv="$(mktemp)"
printf '%s\0' "$@" >"$argv"
for r in "$d"/replies/*/; do
  [ -f "$r/argv" ] || continue
  if cmp -s "$argv" "$r/argv"; then
    rm -f "$argv"
    cat "$r/stdout"
    cat "$r/stderr" >&2
    exit "$(cat "$r/exit")"
  fi
done
rm -f "$argv"
printf 'fixture gh: no reply for:' >&2
printf ' %q' "$@" >&2
printf '\n' >&2
exit 127
GH
  chmod +x "$GH_FIXTURE/bin/gh"
  PATH="$GH_FIXTURE/bin:$PATH"
}

# gh_calls: how many calls the fixture gh on PATH has answered or refused - 0
# for none. A behaviour test on the store-backed fake asserts it stays 0, so
# no command reached a gh subprocess.
gh_calls() {
  if [ -f "$GH_FIXTURE/env.log" ]; then wc -l <"$GH_FIXTURE/env.log" | tr -d ' '; else echo 0; fi
}

# contract <operation> [args...]: runs one real adapter operation, orch.sh
# sourced with ORCH_GH_ADAPTER unset, against whatever gh is on PATH.
contract() { env -u ORCH_GH_ADAPTER bash -c 'source "$1"; shift; "$@"' _ "$ORCH" "$@"; }

# orch.sh run with a PATH gh that fails - a fixture gh given no reply - for a
# repo whose origin GitHub cannot answer for (a local bare repo): default-branch
# settles on origin/HEAD, so a test using it pins that rather than leaving it to
# this machine's gh.
GH_FAILING="$(gh_fixture && printf '%s\n' "$GH_FIXTURE/bin")"
orch_gh_failing() { PATH="$GH_FAILING:$PATH" "$ORCH" "$@"; }

# sc_add <slug> [args...]: makes a fixture side checkout quietly. add runs the
# finished sweep first and reports it on stderr, so that stderr is held back:
# discarded when add succeeds, printed when it fails. The new path passes
# through on stdout, and add's exit status is returned.
sc_add() {
  local err st
  err="$(mktemp)"
  orch_gh_failing side-checkout add "$@" 2>"$err"; st=$?
  [ "$st" -eq 0 ] || cat "$err" >&2
  rm -f "$err"
  return "$st"
}

# The missing-repo wording, built the way orch.sh builds REPO_MISSING,
# REPO_CAUSE and REPO_REMEDY - but spelled out here, never read from orch.sh,
# so a wording change there that the suite does not mirror still fails a test.
repo_missing="no GitHub repo to work on"
repo_cause="$repo_missing: origin is missing or not a GitHub owner/name"
repo_remedy="$repo_cause - set GH_REPO=<owner>/<repo>"

# shellcheck disable=SC2154 # set by orch_test.sh, the runner that evals this file
[ -n "$orch_child_counts" ] || echo "orch.sh tests"

# >>> summary
# Each call the real-gh guard logged is one FAIL naming it.
while IFS= read -r gh_guard_call; do
  bad "a section called the real gh" "$gh_guard_call"
done <"$GH_GUARD_LOG"
# A child of the parallel runner hands its counts on instead of printing them.
# shellcheck disable=SC2154 # set by orch_test.sh, the runner that evals this file
if [ -n "$orch_child_counts" ]; then
  echo "$PASS $FAIL $SKIP" >"$orch_child_counts"
else
  print_summary "$PASS" "$FAIL" "$SKIP"
fi
[ "$FAIL" -eq 0 ]
