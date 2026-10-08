#!/usr/bin/env bash
#
# Tests for scripts/orch.sh.
#
# orch.sh is where silent wrongness hides: `doctor` returning success on a
# deleted branch, a missing triage label, or a handoff with an empty required
# section, are bugs you would experience as generic confusion three phases
# later - or, worse, as a phase that dies once the session that could have
# fixed it has been cleared. Each runs
# against a throwaway git repo in $TMPDIR.
#
# What keeps the suite off a real flow is the harness below, not section
# order: before any section runs it cd's into a fresh `mktemp -d` directory
# that is no git repo, points HOME (and SUITE_HOME, which sections restore)
# at a fresh temp directory, and unsets CLAUDE_PLUGIN_ROOT - exiting non-zero
# if it cannot. A section run on its own that forgets to arrange its own repo
# then fails against an empty directory instead of the caller's checkout. The
# isolation section, the suite's first, asserts all of this.

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/orch.sh"
GH_ADAPTER_FAKE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh_adapter_fake.sh"
PLUGIN_ROOT="$(cd "$(dirname "$ORCH")/.." && pwd)"
SUITE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# The section filter. With ORCH_TEST_ONLY=<ERE> set, the suite runs only the
# shared setup (from the `# >>> shared setup` line to the isolation section),
# the isolation section, every `# ---` section from isolation on whose title -
# the text after `# --- `, trailing dashes dropped - matches under grep -E, and
# the summary (from the `# >>> summary` line). The text is extracted from this
# file and eval'd in this shell, so the paths above are computed once, here,
# and no file is written. A pattern that matches no section exits 1, printing
# every section title, one per line.
if [ -n "${ORCH_TEST_ONLY:-}" ]; then
  # section_awk <mode> [keep]: list the section titles (mode "titles"), or
  # print the text to run (mode "text"), keeping the sections whose 1-based
  # positions appear in keep, a comma-wrapped list such as ",1,4,".
  section_awk() {
    awk -v mode="$1" -v keep="${2:-}" '
      function title(s) { sub(/^# --- /, "", s); sub(/[ -]+$/, "", s); return s }
      phase == 0 && $0 == "# >>> shared setup" { phase = 1; next }
      phase == 0 { next }
      $0 == "# >>> summary" { phase = 3 }
      phase == 1 && /^# --- / && title($0) == "isolation" { phase = 2 }
      phase == 2 && /^# --- / {
        n++
        on = index(keep, "," n ",") > 0
        if (mode == "titles") print title($0)
      }
      mode == "text" && (phase == 1 || phase == 3 || (phase == 2 && on))
    ' "$SUITE_SCRIPT"
  }
  only_titles="$(section_awk titles)"
  only_keep=",1,$(printf '%s\n' "$only_titles" | grep -nE -- "$ORCH_TEST_ONLY" | cut -d: -f1 | tr '\n' ',')"
  if [ "$only_keep" = ",1," ]; then
    echo "orch_test.sh: ORCH_TEST_ONLY='$ORCH_TEST_ONLY' matches no section; the sections are:" >&2
    printf '%s\n' "$only_titles"
    exit 1
  fi
  eval "$(section_awk text "$only_keep")"
  exit $?
fi

# >>> shared setup
PASS=0
FAIL=0
SKIP=0

# The host signals doctor reads: the shell running the tests is often itself
# a Claude Code or Junie session. Each test names its host.
unset ORCHESTRATOR_HOST CLAUDECODE JUNIE_EXTENSION_ROOT JUNIE_SHIM_PATH

# ORCH, GH_ADAPTER_FAKE and PLUGIN_ROOT derive from this script's location, so
# they are computed before the cd below. CALLER_HOME keeps the HOME the suite
# started with, only for the isolation section to check HOME differs from it.
# XDG_CONFIG_HOME and GIT_CONFIG_GLOBAL go too: git would otherwise still read
# the caller's global config through them.
CALLER_HOME="$HOME"
SUITE_CWD="$(mktemp -d)" && cd "$SUITE_CWD" || {
  echo "orch_test.sh: cannot cd into a fresh temp directory" >&2; exit 1; }
SUITE_HOME="$(mktemp -d)" || {
  echo "orch_test.sh: cannot create a temp HOME" >&2; exit 1; }
export HOME="$SUITE_HOME"
unset CLAUDE_PLUGIN_ROOT XDG_CONFIG_HOME GIT_CONFIG_GLOBAL

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
bad()  { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
skip() { printf '  skip %s\n     %s\n' "$1" "$2"; SKIP=$((SKIP + 1)); }

# Git Bash / MSYS2 (and Cygwin) both set OSTYPE this way; used to skip fixtures
# that are known not to work in that environment rather than report a false FAIL.
on_windows_bash() {
  case "$OSTYPE" in msys*|cygwin*) return 0 ;; *) return 1 ;; esac
}
skip_no_jq() { skip "$1" "path_without_jq doesn't work on Windows/Git Bash - see its definition"; }

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
# repo, so it names one through GH_REPO, as a caller would (#520); the stub
# gh answers for acme/widgets. restore_suite_env unsets it again.
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
# archived_count <top> <slug>: how many archive directories for <slug> the main
# checkout at <top> holds.
archived_count() { find "$1/.orchestrator/archive" -maxdepth 1 -name "*-$2" 2>/dev/null | wc -l | tr -d ' '; }

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

# A PATH with everything orch.sh reaches for except jq. Reporting "jq is
# missing" is the one thing doctor has to do without jq, so the only honest way
# to test it is to actually take jq away.
#
# Known gap: this doesn't work on Windows/Git Bash (MSYS) or Cygwin. `printf`
# has no external binary to `ln -sf` there (it's builtin-only), and MSYS's
# path translation between the trimmed Unix-style PATH and the Windows-side
# resolution needed to launch orch.sh breaks down under it - the invocation
# exits 127 with empty output before orch.sh's own logic ever runs. Callers
# guard with on_windows_bash and skip rather than report a false FAIL - see
# issue #68.
path_without_jq() {
  local d t p
  d="$(mktemp -d)"
  for t in env bash git gh awk sed grep tr cat sort tail head date mktemp mv rm mkdir chmod basename dirname printf; do
    if p="$(command -v "$t" 2>/dev/null)"; then ln -sf "$p" "$d/$t"; fi
  done
  printf '%s\n' "$d"
}

# Marks $1 as pushed to origin without a real push - it only has to make
# "$1@{upstream}" resolve, so that cmd_branch retire's own push/delete (the
# real git I/O the redo review assertions actually check) has something to
# run against. The genuine push/checkout cycle for a redo's
# rename-and-republish is proven once by "redo review"'s first iteration
# and, at the lower branch-retire level, by "branch retire"'s own
# to-retire/to-retire-redo-1 assertions - later redo iterations only need the
# upstream to look real, not a second full round trip to the same bare repo.
stub_pushed_branch() {
  local branch="$1"
  git update-ref "refs/remotes/origin/$branch" "$(git rev-parse "$branch")"
  git branch -q --set-upstream-to="origin/$branch" "$branch"
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

# pushed_head <branch> [<seconds ago>]: pushes HEAD to <branch> on a bare
# origin and prints its SHA; given an age, backdates the push's reflog entry.
pushed_head() {
  local bare sha
  bare="$(mktemp -d)"
  git init -q --bare "$bare"
  bare_origin "$bare"
  git update-ref -d "refs/remotes/origin/$1" 2>/dev/null || true
  git push -q origin "HEAD:refs/heads/$1" 2>/dev/null
  sha="$(git rev-parse HEAD)"
  if [ -n "${2:-}" ]; then
    git update-ref -d "refs/remotes/origin/$1"
    GIT_COMMITTER_DATE="@$(( $(date +%s) - $2 )) +0000" \
      git update-ref -m 'update by push' "refs/remotes/origin/$1" "$sha"
  fi
  printf '%s\n' "$sha"
}

# review_ci_flow <slug>: a review ci section's starting point - review_flow
# <slug> with PR #7 recorded in state and open from topic onto main in the
# store-backed fake (fake_github), the base tip's one check run as the CI
# evidence that keeps the grace, and the CI knobs short: ORCH_CI_GRACE=0.3,
# ORCH_CI_TIMEOUT=1, ORCH_CI_INTERVAL=0.05. A section that calls it ends with
# restore_suite_env ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL.
review_ci_flow() {
  review_flow "$1"
  state_fixture pr 7
  export ORCH_CI_GRACE=0.3 ORCH_CI_TIMEOUT=1 ORCH_CI_INTERVAL=0.05
  fake_github
  fake_pr 7 open topic main
  fake_check_run main
}

# ticket_fixture: a ticket section's starting point - a healthy_repo with the
# store-backed fake GitHub (fake_github), no issue in it yet. Leaves the global
# body (a ticket body file reading "Build the thing.") set, and whatever
# healthy_repo and fake_github export. A section that calls it ends with
# restore_suite_env.
ticket_fixture() {
  healthy_repo
  fake_github
  body="$(mktemp)"
  writeln 'Build the thing.' >"$body"
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

# fake_issue_title <n> <title>: seeds issue #n's title.
fake_issue_title() { printf '%s\n' "$2" >"$ORCH_GH_FAKE_STORE/issues/$1/title"; }

# fake_comment <n> <author> <created-at> <body>: seeds a comment on issue #n,
# after any it has.
fake_comment() {
  local d k
  d="$ORCH_GH_FAKE_STORE/issues/$1/comments"
  mkdir -p "$d"
  k=$(( $(find "$d" -mindepth 1 -maxdepth 1 | wc -l) + 1 ))
  mkdir "$d/$k"
  printf '%s\n' "$2" >"$d/$k/author"
  printf '%s\n' "$3" >"$d/$k/created"
  printf '%s' "$4" >"$d/$k/body"
}

# fake_pull <n>: seeds #n as an open pull request, which gh's issue reads
# answer for too.
fake_pull() { fake_issue "$1" open; : >"$ORCH_GH_FAKE_STORE/issues/$1/pull"; }

# fake_next_issue <n>: the number the next issue created takes.
fake_next_issue() { printf '%s\n' "$1" >"$ORCH_GH_FAKE_STORE/next_issue"; }

# Issue #n read back from the store: its state (OPEN or CLOSED), closing
# reason, title, body, labels (sorted, space-separated, one trailing space)
# and the bodies of its comments, in order, one blank line between.
fake_state_of()  { cat "$ORCH_GH_FAKE_STORE/issues/$1/state" 2>/dev/null; }
fake_reason_of() { cat "$ORCH_GH_FAKE_STORE/issues/$1/reason" 2>/dev/null; }
fake_title_of()  { cat "$ORCH_GH_FAKE_STORE/issues/$1/title" 2>/dev/null; }
fake_body_of()   { cat "$ORCH_GH_FAKE_STORE/issues/$1/body" 2>/dev/null; }
fake_labels_of() { sort "$ORCH_GH_FAKE_STORE/issues/$1/labels" 2>/dev/null | tr '\n' ' '; }
fake_comments_of() {
  local d="$ORCH_GH_FAKE_STORE/issues/$1/comments" k first=1
  [ -d "$d" ] || return 0
  for k in $(ls "$d" | sort -n); do
    [ "$first" = 1 ] || printf '\n\n'
    first=0
    cat "$d/$k/body"
  done
}

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

# fake_pr_body <n> <text>: seeds PR #n's body, byte for byte.
fake_pr_body() { printf '%s' "$2" >"$ORCH_GH_FAKE_STORE/prs/$1/body"; }

# fake_pr_comment <n> <author> <created-at> <body>: seeds a comment on PR #n,
# after any it has.
fake_pr_comment() {
  local d k
  d="$ORCH_GH_FAKE_STORE/prs/$1/comments"
  mkdir -p "$d"
  k=$(( $(find "$d" -mindepth 1 -maxdepth 1 | wc -l) + 1 ))
  mkdir "$d/$k"
  printf '%s\n' "$2" >"$d/$k/author"
  printf '%s\n' "$3" >"$d/$k/created"
  printf '%s' "$4" >"$d/$k/body"
}

# fake_pr_draft <n>: seeds PR #n as a draft.
fake_pr_draft() { : >"$ORCH_GH_FAKE_STORE/prs/$1/draft"; }

# fake_pr_head <n> <sha> [commit...]: seeds PR #n's head SHA and its commits,
# oldest first - given none, the head alone.
fake_pr_head() {
  local d="$ORCH_GH_FAKE_STORE/prs/$1"
  printf '%s\n' "$2" >"$d/head_oid"
  shift 2
  rm -f "$d/commits"
  [ $# -eq 0 ] || printf '%s\n' "$@" >"$d/commits"
}

# fake_next_pr <n>: the number the next PR opened takes.
fake_next_pr() { printf '%s\n' "$1" >"$ORCH_GH_FAKE_STORE/next_pr"; }

# PR #n read back from the store: its state (OPEN, CLOSED or MERGED), head and
# base branches, title, body, whether it is a draft (yes or no), and the bodies
# of its comments, in order, one blank line between.
fake_pr_state_of() { cat "$ORCH_GH_FAKE_STORE/prs/$1/state" 2>/dev/null; }
fake_pr_head_of()  { cat "$ORCH_GH_FAKE_STORE/prs/$1/head" 2>/dev/null; }
fake_pr_base_of()  { cat "$ORCH_GH_FAKE_STORE/prs/$1/base" 2>/dev/null; }
fake_pr_title_of() { cat "$ORCH_GH_FAKE_STORE/prs/$1/title" 2>/dev/null; }
fake_pr_body_of()  { cat "$ORCH_GH_FAKE_STORE/prs/$1/body" 2>/dev/null; }
fake_pr_draft_of() { [ -f "$ORCH_GH_FAKE_STORE/prs/$1/draft" ] && echo yes || echo no; }
fake_pr_comments_of() {
  local d="$ORCH_GH_FAKE_STORE/prs/$1/comments" k first=1
  [ -d "$d" ] || return 0
  for k in $(ls "$d" | sort -n); do
    [ "$first" = 1 ] || printf '\n\n'
    first=0
    cat "$d/$k/body"
  done
}

# fake_prs: every PR number the store holds, in order, space-separated.
fake_prs() { ls "$ORCH_GH_FAKE_STORE/prs" 2>/dev/null | sort -n | tr '\n' ' '; }

# fake_label <name> <colour> <description>: seeds a label the repo already
# has. An unseeded store has no labels.
fake_label() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$ORCH_GH_FAKE_STORE/labels"; }

# fake_labels: the store's labels read back, sorted, one per line as
# "<name><TAB><colour><TAB><description>".
fake_labels() { sort "$ORCH_GH_FAKE_STORE/labels" 2>/dev/null || true; }

# fake_fail <operation> [stderr]: every later call of the named adapter
# operation fails, non-zero, with stderr (default "fake gh: <operation>
# failed") as gh's own error.
fake_fail() {
  mkdir -p "$ORCH_GH_FAKE_STORE/fail"
  printf '%s\n' "${2:-fake gh: $1 failed}" >"$ORCH_GH_FAKE_STORE/fail/$1"
}

# fake_fail_after <operation> <n> [stderr]: fake_fail, but the next n calls of
# the operation still succeed - a run of writes that dies part-way.
fake_fail_after() {
  fake_fail "$1" "${3:-}"
  printf '%s\n' "$2" >"$ORCH_GH_FAKE_STORE/fail/$1.after"
}

# fake_fail_times <operation> <n> [stderr]: the next n calls of the operation
# fail, then it succeeds again - a transient failure. stderr defaults to none.
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

# The edges read back from the store: a parent's sub-issues in link order, and
# #n's blockers sorted by number - each space-separated, nothing for none.
fake_sub_issues_of() { paste -sd ' ' "$ORCH_GH_FAKE_STORE/subs/$1" 2>/dev/null || true; }
fake_blockers_of() { sort -n "$ORCH_GH_FAKE_STORE/blocked_by/$1" 2>/dev/null | paste -sd ' ' -; }

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

# fake_required_checks <branch> <context>...: classic branch protection on the
# branch, requiring the checks named.
fake_required_checks() {
  local b="$1"
  shift
  mkdir -p "$ORCH_GH_FAKE_STORE/protection"
  printf '%s\n' "$@" >"$ORCH_GH_FAKE_STORE/protection/$b"
}

# fake_rules <branch> <type>...: the rules the repo's rulesets apply to the
# branch, by type.
fake_rules() {
  local b="$1"
  shift
  mkdir -p "$ORCH_GH_FAKE_STORE/rules"
  printf '%s\n' "$@" >"$ORCH_GH_FAKE_STORE/rules/$b"
}

# fake_check_run <ref> / fake_status <ref>: the ref - a SHA, or a branch name
# for its tip - has a check run, or a commit status. fake_unreadable_ref <ref>:
# both reads of the ref fail.
fake_check_run() { printf '%s\n' "$1" >>"$ORCH_GH_FAKE_STORE/check_runs"; }
fake_status() { printf '%s\n' "$1" >>"$ORCH_GH_FAKE_STORE/statuses"; }
fake_unreadable_ref() { printf '%s\n' "$1" >>"$ORCH_GH_FAKE_STORE/unreadable_refs"; }

# fake_ci_reset: no checks scripted, nothing required, no rules, and no ref
# with a check run or status - every CI signal absent.
fake_ci_reset() {
  rm -rf "$ORCH_GH_FAKE_STORE/checks" "$ORCH_GH_FAKE_STORE/protection" "$ORCH_GH_FAKE_STORE/rules" \
    "$ORCH_GH_FAKE_STORE/check_runs" "$ORCH_GH_FAKE_STORE/statuses" "$ORCH_GH_FAKE_STORE/unreadable_refs"
}

# fake_default_branch <answer>: seeds gh's answer to the repo's default branch,
# byte for byte, so a test can seed a polluted or empty one.
fake_default_branch() { printf '%s' "$1" >"$ORCH_GH_FAKE_STORE/default_branch"; }

# fake_reruns: the Actions run ids rerun, read back, space-separated, in order.
fake_reruns() { tr '\n' ' ' 2>/dev/null <"$ORCH_GH_FAKE_STORE/reruns" | sed 's/ $//'; }

# fake_label_names <name>...: the repo's labels are exactly the names given,
# each with no colour or description - none given, the repo has no labels.
fake_label_names() {
  : >"$ORCH_GH_FAKE_STORE/labels"
  [ $# -eq 0 ] || printf '%s\t\t\n' "$@" >"$ORCH_GH_FAKE_STORE/labels"
}

# fake_local_default <owner/name>: gh's own local default repo for the
# checkout; given an empty one, none is set.
fake_local_default() {
  if [ -n "$1" ]; then printf '%s\n' "$1" >"$ORCH_GH_FAKE_STORE/local_default"
  else rm -f "$ORCH_GH_FAKE_STORE/local_default"; fi
}

# fake_no_sub_issues: the sub-issues endpoint refuses every issue, as on a
# GitHub that does not support them.
fake_no_sub_issues() { : >"$ORCH_GH_FAKE_STORE/no_sub_issues"; }

# fake_offline: every operation fails with a connection error, as with GitHub
# unreachable. fake_noauth: gh is not authenticated - the auth status fails
# saying so, every other operation as unauthorised. fake_online undoes both.
fake_offline() { : >"$ORCH_GH_FAKE_STORE/offline"; }
fake_noauth()  { : >"$ORCH_GH_FAKE_STORE/noauth"; }
fake_online()  { rm -f "$ORCH_GH_FAKE_STORE/offline" "$ORCH_GH_FAKE_STORE/noauth"; }

# doctor_github: fake_github, seeded as the GitHub a healthy repo has for
# doctor - the default labels doc's two labels, default branch main, and one
# open issue for the sub-issues probe to ask about.
doctor_github() {
  fake_github
  fake_label_names needs-triage ready-for-agent
  fake_default_branch main
  fake_issue 1 open
}

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

# gh_reply <exit> <stdout> <stderr> <argv...>: the canned reply the fixture gh
# answers to exactly that argv.
gh_reply() {
  local r
  r="$(mktemp -d "$GH_FIXTURE/replies/XXXXXX")"
  printf '%s' "$1" >"$r/exit"
  printf '%s' "$2" >"$r/stdout"
  printf '%s' "$3" >"$r/stderr"
  shift 3
  printf '%s\0' "$@" >"$r/argv"
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

# path_without_jq() builds its restricted PATH from whatever's really on PATH,
# not from repo state, so the one built here serves every no-jq assertion
# (in doctor and in doctor --flow) instead of symlinking the same ~20 tools
# afresh at each call site. Its gh is a fixture gh, made in the subshell so
# the suite's own PATH is left alone. Empty on Windows/Git Bash, where callers
# skip.
nojq_path=""
on_windows_bash || nojq_path="$(gh_fixture && path_without_jq)"

echo "orch.sh tests"

# --- isolation --------------------------------------------------------------
echo
echo "isolation"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  bad "the suite starts outside any git work tree" "cwd $(pwd) is inside one"
else
  ok "the suite starts outside any git work tree"
fi
assert_eq "HOME is the suite's own HOME" "$HOME" "$SUITE_HOME"
assert_ne "HOME is not the HOME the suite started with" "$HOME" "$CALLER_HOME"
assert_eq "CLAUDE_PLUGIN_ROOT is unset" "${CLAUDE_PLUGIN_ROOT-unset}" "unset"
assert_eq "no caller git config is reachable" \
  "${XDG_CONFIG_HOME-unset} ${GIT_CONFIG_GLOBAL-unset}" "unset unset"
assert_eq "cwd is the harness's fresh temp directory" "$(pwd)" "$SUITE_CWD"

# --- init -------------------------------------------------------------------
echo
echo "init"
new_repo >/dev/null
out="$("$ORCH" init "My Feature!!")"
assert_eq "normalises slug to kebab-case" "$out" "my-feature"
assert_eq "state starts at the spec phase" "$("$ORCH" state get phase)" "spec"
assert_eq "iteration starts at zero" "$("$ORCH" state get iteration)" "0"
assert_eq "issue starts unset" "$("$ORCH" state get issue)" ""
assert_contains "excludes .orchestrator/ without touching .gitignore" \
  "$(cat .git/info/exclude)" ".orchestrator/"
assert_eq "leaves the working tree clean" "$(git status --porcelain)" ""
assert_eq "excludes .orchestrator/ exactly once" "$(exclude_count .orchestrator/)" "1"
assert_eq "excludes .scratch/ exactly once" "$(exclude_count .scratch/)" "1"

# #720: a flow mid-pipeline is refused with its own exit code, 3, so a skill
# can tell "a flow is active" apart from every other init failure.
out="$("$ORCH" init other 2>&1)"; st=$?
assert_status "refuses a second concurrent flow with exit 3" "$st" 3
assert_contains "explains how to clear the active flow" "$out" "abort"
assert_contains "with the message unchanged" "$out" "a flow is already active (slug: my-feature, phase: spec)."

out="$("$ORCH" init other --bogus 2>&1)"; st=$?
assert_status "rejects an unknown flag" "$st" 1
assert_contains "names the flag it rejected" "$out" "--bogus"

out="$("$ORCH" init 2>&1)"; st=$?
assert_status "a missing slug keeps its usage exit code" "$st" 1
assert_contains "printing the usage" "$out" "usage: orch.sh init"

out="$("$ORCH" init other --issue x 2>&1)"; st=$?
assert_status "a malformed --issue keeps its exit code" "$st" 1

# --- init git-excludes the plugin's directories once ---------------------------
echo
echo "init git-excludes the plugin's directories once"
new_repo >/dev/null
"$ORCH" init first >/dev/null
rm -rf .orchestrator
"$ORCH" init second >/dev/null
assert_eq "a second init leaves .orchestrator/ excluded once" "$(exclude_count .orchestrator/)" "1"
assert_eq "a second init leaves .scratch/ excluded once" "$(exclude_count .scratch/)" "1"
git checkout -q -b quick/7-bar
"$ORCH" review-pass begin 7 >/dev/null
assert_eq "init then review-pass begin leaves .orchestrator/ excluded once" "$(exclude_count .orchestrator/)" "1"
assert_eq "init then review-pass begin leaves .scratch/ excluded once" "$(exclude_count .scratch/)" "1"

new_repo >/dev/null
printf '%s\n' ".scratch/" >>.git/info/exclude
"$ORCH" init third >/dev/null
assert_eq "a .scratch/ line already present is not written again" "$(exclude_count .scratch/)" "1"
assert_eq "and .orchestrator/ is still added beside it" "$(exclude_count .orchestrator/)" "1"
mkdir -p .scratch && echo plan >.scratch/plan.md
assert_eq "an untracked .scratch/ stays out of git status" "$(git status --porcelain)" ""

# --- init refuses a dirty working tree ----------------------------------------
# The git-based backstop from ADR-0013: a host with no mechanical trigger for
# the edit guard can still edit source during planning, so flow start is where
# those edits get caught. Only the planning allowlist may be dirty.
echo
echo "init refuses a dirty working tree"
new_repo >/dev/null
echo "code" >stray.sh
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses an untracked file outside the allowlist" "$st" 1
assert_contains "names the untracked path" "$out" "stray.sh"
assert_eq "writes no state when it refuses" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_contains "says how to resolve it" "$out" "Commit, stash, or discard"
assert_contains "says to retry" "$out" "run init again"
assert_contains "names what planning may change" "$out" "docs/agents/"
assert_not_contains "source-only refusal has no records block" "$out" "Planning records changed"

rm stray.sh
echo "changed" >>docs/agents/triage-labels.md
echo "base" >src.sh; git add src.sh; git commit -qm src
echo "edit" >>src.sh
mkdir -p lib && echo "new" >lib/deep.sh
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses a tracked modification outside the allowlist" "$st" 1
assert_contains "names the modified path" "$out" "src.sh"
assert_contains "names an untracked file inside a new directory" "$out" "lib/deep.sh"
case "$out" in *triage-labels.md*) bad "does not name allowlisted paths" "$out" ;;
  *) ok "does not name allowlisted paths" ;; esac

git checkout -q src.sh; rm -r lib
git mv src.sh moved.sh
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses a staged rename" "$st" 1
assert_contains "names the rename's new path" "$out" "moved.sh"
assert_contains "names the rename's old path" "$out" "src.sh"
git mv moved.sh src.sh

# A git status that cannot run is not a clean tree - reading it as one would
# wave through exactly the edits this check exists to catch.
cp .git/index .git/index.bak; echo garbage >.git/index
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses when git status fails" "$st" 1
assert_eq "writes no state when git status fails" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
mv .git/index.bak .git/index

# The glossary and ADRs are planning records: a dirty one refuses init with
# the guard's redirect, under its own heading (#186).
echo "# glossary" >GLOSSARY.md
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses a dirty GLOSSARY.md" "$st" 1
assert_contains "heads the records block" "$out" "Planning records changed (planning does not edit these in place):
       GLOSSARY.md"
# The redirect is wrapped for the terminal, so its phrases are checked with
# the line breaks and indentation flattened out.
flat="$(printf '%s' "$out" | flat_text)"
assert_contains "gives the records redirect" "$flat" "into the plan, so the spec carries it verbatim"
assert_contains "gives the quick-implementation redirect" "$flat" "For a quick implementation, put it in the linked issue's body."
assert_eq "wraps the redirect for the terminal" \
  "$(printf '%s\n' "$out" | awk 'length > 80' | wc -l | tr -d ' ')" "0"
assert_not_contains "records-only refusal has no source block" "$out" "Changes outside the planning allowlist:"
# Committing a record from planning is the option ADR-0022 rejects, so a
# records-only refusal never offers it.
assert_not_contains "records-only refusal never says to commit" "$out" "Commit"
assert_contains "says to discard or stash the records" "$out" "Discard or stash these changes, then run init again."
assert_eq "writes no state for a dirty record" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
rm GLOSSARY.md

# The legacy glossary names stay records, for repos not yet renamed (#461).
for f in CONTEXT.md CONTEXT-MAP.md; do
  echo "# glossary" >"$f"
  out="$("$ORCH" init dirty 2>&1)"; st=$?
  assert_status "refuses a dirty legacy $f" "$st" 1
  assert_contains "lists legacy $f under the records heading" "$out" "Planning records changed (planning does not edit these in place):
       $f"
  rm "$f"
done

mkdir -p docs/adr && echo "# ADR" >docs/adr/0001-x.md
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses a dirty ADR" "$st" 1
assert_contains "lists the ADR under the records heading" "$out" "Planning records changed (planning does not edit these in place):
       docs/adr/0001-x.md"

echo "code" >stray.sh
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses both dirty lists" "$st" 1
assert_contains "lists the record under the records heading" "$out" "Planning records changed (planning does not edit these in place):
       docs/adr/0001-x.md"
assert_contains "lists the source path under its own heading" "$out" "Changes outside the planning allowlist:
       stray.sh"
assert_contains "tells the records apart in the resolution line" "$out" "Discard or stash the planning records; commit, stash, or discard the other
     changes, then run init again."
case "$out" in *"allowlist:"*docs/adr/0001-x.md*) bad "does not list the record under the source heading" "$out" ;;
  *) ok "does not list the record under the source heading" ;; esac
rm -r stray.sh docs/adr

mkdir -p .scratch && echo "ticket" >.scratch/t.md
mkdir -p sub
out="$(cd sub && "$ORCH" init clean-enough 2>&1)"; st=$?
assert_status "starts with only allowlisted changes, even from a subdirectory" "$st" 0
assert_eq "records the flow" "$("$ORCH" state get slug)" "clean-enough"

# --- slug -------------------------------------------------------------------
# The same normalisation init applies to its own slug argument, exposed as a
# primitive so the quick-implement skill can call it instead of restating the
# algorithm as prose.
echo
echo "slug"
new_repo >/dev/null
assert_eq "matches init's own normalisation" "$("$ORCH" slug "My Feature!!")" "my-feature"
out="$("$ORCH" slug "!!!" 2>&1)"; st=$?
assert_status "refuses a slug empty after normalisation" "$st" 1
assert_contains "explains why" "$out" "empty after normalisation"
out="$("$ORCH" slug 2>&1)"; st=$?
assert_status "refuses no argument at all" "$st" 1

# --- state ------------------------------------------------------------------
echo
echo "state"
new_repo >/dev/null
"$ORCH" init state >/dev/null
assert_eq "round-trips a string value" \
  "$("$ORCH" state set budget unbounded; "$ORCH" state get budget)" "unbounded"
"$ORCH" state set budget 3
assert_eq "sets budget" "$("$ORCH" state get budget)" "3"
"$ORCH" state set flake_rerun_used true
assert_eq "sets flake_rerun_used" "$("$ORCH" state get flake_rerun_used)" "true"
"$ORCH" state set budget null
"$ORCH" state set flake_rerun_used false
before="$("$ORCH" state get phase)"
out="$("$ORCH" state set phase review 2>&1)"; st=$?
assert_status "refuses to set phase" "$st" 1
assert_eq "naming phase advance as its owner, in full" "$out" \
  "orch: state set refuses phase: use phase advance (review ready and redo also move it)"
assert_eq "and leaves the phase as it was" "$("$ORCH" state get phase)" "$before"
# Each refusal is pinned as its whole line, so a change to any wording fails.
for pair in "branch|branch create records it" "base_sha|branch create records it" \
            "pr|pr open records it" "iteration|review begin counts it" \
            "redo_count|redo review counts it" "slug|init seeds it" \
            "base|init seeds it" "created|init seeds it" \
            "host_fallbacks|init seeds it" "updated|every state change stamps it" \
            "bogus|settable keys are issue, budget, flake_rerun_used"; do
  key="${pair%%|*}"; owner="${pair#*|}"
  out="$("$ORCH" state set "$key" 1 2>&1)"; st=$?
  assert_status "refuses to set $key" "$st" 1
  assert_eq "naming what owns $key, in full" "$out" "orch: state set refuses $key: $owner"
done
"$ORCH" state set issue 42
assert_eq "coerces a numeric value to a number" "$("$ORCH" state get issue)" "42"
assert_eq "stores issue as JSON number, not string" \
  "$("$ORCH" state get | jq -r '.issue | type')" "number"
"$ORCH" state set issue null
assert_eq "accepts an explicit null" "$("$ORCH" state get | jq -r '.issue | type')" "null"
for b in true false; do
  "$ORCH" state set flake_rerun_used "$b"
  assert_eq "stores flake_rerun_used $b as a JSON boolean" \
    "$("$ORCH" state get | jq -r '.flake_rerun_used | type')" "boolean"
  assert_eq "reads flake_rerun_used $b back as $b" "$("$ORCH" state get flake_rerun_used)" "$b"
done
for pair in unbounded:string 3:number null:null; do
  "$ORCH" state set budget "${pair%%:*}"
  assert_eq "stores budget ${pair%%:*} as a JSON ${pair#*:}" \
    "$("$ORCH" state get | jq -r '.budget | type')" "${pair#*:}"
done
"$ORCH" state set budget false
assert_eq "reads a stored false back as false, not the key's default" \
  "$("$ORCH" state get budget)" "false"
# Digits with a trailing newline are not all digits, so they are stored as a
# string. jq's regex `$` used to match before the newline, and the set then
# died on tonumber's error (#711).
"$ORCH" state set budget $'12\n'; st=$?
assert_status "accepts digits with a trailing newline" "$st" 0
assert_eq "stores them as a JSON string" \
  "$("$ORCH" state get | jq -r '.budget | type')" "string"
assert_eq "and leaves the rest of state.json intact" "$("$ORCH" state get slug)" "state"

# --- handoff path -----------------------------------------------------------
echo
echo "handoff path"
new_repo >/dev/null
"$ORCH" init handoff-path >/dev/null
assert_contains "spec phase reads the plan handoff"      "$("$ORCH" handoff path spec)"      "01-plan.md"
assert_contains "implement phase reads the spec handoff" "$("$ORCH" handoff path implement)" "02-spec.md"
assert_contains "review phase reads the implement handoff" "$("$ORCH" handoff path review)"  "03-implement.md"

# The review skill consumes this inside command substitutions - `dirname "$(...
# handoff path review)"` - so a phase it cannot resolve has to stop the caller
# rather than hand it the bare handoff directory with a zero status.
out="$("$ORCH" handoff path bogus 2>/dev/null)"; st=$?
assert_status "an unknown phase is an error, not a directory" "$st" 1
assert_eq "and prints no path for a caller to use" "$out" ""

# --- handoff validate -------------------------------------------------------
echo
echo "handoff validate"
new_repo >/dev/null
"$ORCH" init handoff-validate >/dev/null
h="$("$ORCH" handoff path spec)"
complete_plan_handoff "$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "passes a complete handoff" "$st" 0

writeln '## Decisions' 'Use X.' '' '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "fails when a required section is missing" "$st" 1
assert_contains "names the missing section" "$out" "Rejected alternatives"

# The high-value case: the section the spec writer is most likely to leave as a
# bare heading, which would let already-killed alternatives get re-proposed.
complete_plan_handoff "$h"
writeln '## Decisions' 'Use X.' '' '## Rejected alternatives' '' \
        '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "fails when a required section is present but empty" "$st" 1
assert_contains "reports it as empty, not missing" "$out" "empty section"

writeln '## Decisions' 'Use X.' '' '## Rejected alternatives' '   ' '' \
        '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "treats a whitespace-only section as empty" "$st" 1

# A missing file is reported the way an invalid one is - a FAIL line on stdout
# and exit 1, no die - so a reader of FAIL lines sees what phase advance prints.
out="$("$ORCH" handoff validate "$h.missing" 2>/dev/null)"; st=$?
assert_status "fails on a missing handoff" "$st" 1
assert_eq "reports it as a FAIL line on stdout" "$out" "FAIL  handoff not found: $h.missing"

# Every phase records the host capability fallbacks it used (#127,
# docs/host-capabilities.md), so a human reading any handoff can see where a
# host did less than Claude Code would have. "None." is an answer; no section
# is not.
for p in spec implement review; do
  hf="$("$ORCH" handoff path "$p")"
  case "$p" in
    spec) complete_plan_handoff "$hf" ;;
    implement) complete_spec_handoff "$hf" ;;
    review) complete_implement_handoff "$hf" ;;
  esac
  grep -v '^## Host fallbacks$' "$hf" | grep -v '^None (Claude Code)\.$' >"$hf.tmp" && mv "$hf.tmp" "$hf"
  out="$("$ORCH" handoff validate "$hf" 2>&1)"; st=$?
  assert_status "$(basename "$hf") without Host fallbacks is incomplete" "$st" 1
  assert_contains "$(basename "$hf") names the missing Host fallbacks" "$out" "Host fallbacks"
done
# A flow started before 1.0.0 has no host_fallbacks in state.json and wrote
# its handoffs without the section; upgrading mid-flow must not fail them.
st_saved="$(cat .orchestrator/state.json)"
jq 'del(.host_fallbacks)' <<<"$st_saved" >.orchestrator/state.json
out="$("$ORCH" handoff validate "$hf" 2>&1)"; st=$?
assert_status "a pre-1.0.0 flow's handoff validates without Host fallbacks" "$st" 0
printf '%s\n' "$st_saved" >.orchestrator/state.json
complete_plan_handoff "$h"

# --- handoff section --------------------------------------------------------
# The review loop's driver reads Rejected alternatives and Deviations through
# this rather than reading whole handoffs, so it has to print exactly one
# section's body and nothing of its neighbours.
echo
echo "handoff section"
new_repo >/dev/null
"$ORCH" init handoff-section >/dev/null
h="$("$ORCH" handoff path spec)"
complete_plan_handoff "$h"
out="$("$ORCH" handoff section "$h" "Rejected alternatives" 2>&1)"; st=$?
assert_status "prints a named section" "$st" 0
assert_eq "prints only that section's body" "$out" "Y, because Z."

hi="$("$ORCH" handoff path review)"
complete_implement_handoff "$hi"
assert_eq "reads Deviations out of an implement handoff" \
  "$("$ORCH" handoff section "$hi" Deviations)" "None."

hs="$(mktemp)"
writeln '## Decisions' '' '' 'Use X.' '' 'And Y.' '   ' '' \
        '## Rejected alternatives' '  ' '' \
        '## Constraints' 'Must run offline.' >"$hs"
out="$("$ORCH" handoff section "$hs" Decisions)"
assert_eq "trims leading and trailing blank lines, keeps inner ones" \
  "$out" "$(writeln 'Use X.' '' 'And Y.')"
assert_not_contains "does not bleed into the next section" "$out" "Constraints"
out="$("$ORCH" handoff section "$hs" Constraints)"
assert_eq "reads the last section to end of file" "$out" "Must run offline."

out="$("$ORCH" handoff section "$hs" "Rejected alternatives" 2>&1)"; st=$?
assert_status "a whitespace-only section exits 0" "$st" 0
assert_eq "and prints nothing" "$out" ""
cp "$hs" "$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"
assert_contains "handoff validate reports that same section as empty" \
  "$out" "empty section: ## Rejected alternatives"
complete_plan_handoff "$h"

out="$("$ORCH" handoff section "$h" "Open questions" 2>&1)"; st=$?
assert_status "a missing heading is an error" "$st" 1
assert_contains "naming the heading" "$out" "Open questions"

# A handoff with two identical sections is malformed: refuse it rather than
# print both bodies joined as if they were one section (see issue #168).
hd="$(mktemp)"
writeln '## X' 'First.' '## Y' 'Between.' '## X' 'Second.' >"$hd"
out="$("$ORCH" handoff section "$hd" X 2>&1)"; st=$?
assert_status "a repeated heading is an error" "$st" 1
assert_contains "naming the repeated heading and the file" "$out" "repeated section: ## X in $hd"
assert_not_contains "and printing no body" "$out" "First."
assert_not_contains "nor the second body" "$out" "Second."
rm -f "$hd"

# The match is on the whole `## <heading>` line: a prefix is not the section.
out="$("$ORCH" handoff section "$h" "Rejected" 2>&1)"; st=$?
assert_status "a heading prefix does not match" "$st" 1

out="$("$ORCH" handoff section "$hs.missing" Decisions 2>&1)"; st=$?
assert_status "a missing file is an error" "$st" 1
assert_contains "naming the file" "$out" "$hs.missing"

out="$("$ORCH" handoff section "$h" 2>&1)"; st=$?
assert_status "too few arguments is an error" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh handoff section <file> <heading>"
out="$("$ORCH" handoff section "$h" Decisions extra 2>&1)"; st=$?
assert_status "too many arguments is an error" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh handoff section <file> <heading>"

assert_contains "orch.sh help lists handoff section" "$("$ORCH" help)" "handoff section"
out="$("$ORCH" handoff bogus 2>&1)"
assert_contains "an unknown handoff op lists section" "$out" "want path|validate|section"
rm -f "$hs" "$hi"

# --- ticket breakdown handoff ------------------------------------------------
# The spec phase's last step publishes tickets as sub-issues of the spec
# issue, so the handoff that follows it must at least name the parent -
# anything less sends implement's `ticket next` query against nothing.
echo
echo "ticket breakdown handoff"
new_repo >/dev/null
"$ORCH" init ticket-breakdown >/dev/null
h2="$("$ORCH" handoff path implement)"
writeln '## Spec issue' '#1.' '' '## Seams' 'The CLI.' '' \
        '## Spec review changelog' 'Not reviewed.' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "a spec handoff with no ticket breakdown is incomplete" "$st" 1
assert_contains "names the section implement would have read" "$out" "Ticket breakdown"

writeln '## Spec issue' '#1.' '' '## Seams' 'The CLI.' '' \
        '## Spec review changelog' 'Not reviewed.' '' \
        '## Ticket breakdown' '   ' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "a bare Ticket breakdown heading is no better than none" "$st" 1
assert_contains "reported as empty, not missing" "$out" "empty section"

complete_spec_handoff "$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "passes once the parent issue is recorded" "$st" 0

# A 0/1-ticket breakdown collapses (issue #99/#101): no sub-issue is published,
# so this section names the spec issue itself via a plain-text sentinel rather
# than a parent whose GitHub sub-issues carry the real tickets. It is covered
# today by the same generic non-empty-section check as any other content -
# named explicitly here so the convention doesn't silently rot.
writeln '## Spec issue' '#1.' '' '## Seams' 'The CLI.' '' \
        '## Spec review changelog' 'Not reviewed.' '' \
        '## Ticket breakdown' 'None: work directly against #1.' '' \
        '## Host fallbacks' 'None (Claude Code).' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "the collapsed-case sentinel validates like any other content" "$st" 0

# --- handoff templates -------------------------------------------------------
# The templates in the orch-handoff skill are what every phase copies, so one
# missing a section handoff validate requires, or with a placeholder left
# empty, would fail every flow at its boundary. Each template block is written
# under its own file name and validated once, against a state that requires
# Host fallbacks: the largest required set. No run without Host fallbacks is
# needed. That set is the same headings minus `## Host fallbacks`, and validate
# fails only on a required heading that is missing or empty, so a template that
# passes the larger set passes the smaller one too. A no-state run would repeat
# this one, since Host fallbacks is required when there is no state file. Its
# own repo keeps this flow's state untouched.
echo
echo "handoff templates"
HANDOFF_SKILL="$PLUGIN_ROOT/skills/orch-handoff/SKILL.md"
tpl_repo="$(new_repo)"
mkdir -p "$tpl_repo/.orchestrator"
printf '{"host_fallbacks": true}\n' >"$tpl_repo/.orchestrator/state.json"
for tpl in 01-plan.md 02-spec.md 03-implement.md; do
  # The markdown fence under the template's `### \`<file>\`` heading.
  awk -v f="$tpl" '
    index($0, "### `" f "`") == 1 { under = 1; next }
    under && /^```markdown$/      { inside = 1; next }
    inside && /^```$/             { exit }
    inside                        { print }' "$HANDOFF_SKILL" >"$tpl_repo/$tpl"
  out="$(cd "$tpl_repo" && bash "$ORCH" handoff validate "$tpl" 2>&1)"; st=$?
  if [ "$st" -eq 0 ]; then ok "the $tpl template validates when Host fallbacks is required"
  else bad "the $tpl template validates when Host fallbacks is required" "$(flat_text <<<"$out")"; fi
done
rm -rf "$tpl_repo"

# --- archive ----------------------------------------------------------------
echo
echo "archive"
new_repo >/dev/null
"$ORCH" init my-feature >/dev/null
h="$("$ORCH" handoff path spec)"
complete_plan_handoff "$h"
dest="$("$ORCH" archive)"
assert_contains "archive path carries the slug" "$dest" "my-feature"
assert_eq "archive names its directory <YYYYMMDD-HHMMSS>-<slug>" \
  "$(printf '%s\n' "$dest" | grep -c '^\.orchestrator/archive/[0-9]\{8\}-[0-9]\{6\}-my-feature$')" "1"
assert_eq "live state is cleared" "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "gone"
assert_eq "handoff is preserved under archive/" \
  "$([ -f "$dest/handoff/01-plan.md" ] && echo present || echo gone)" "present"
out="$("$ORCH" status 2>&1)"
assert_contains "status reports no active flow afterwards" "$out" "No active flow"
out="$("$ORCH" init second 2>&1)"; st=$?
assert_status "a new flow can start after archiving" "$st" 0

# #622: moving a ticket worktree would break git's record of it, so archive
# refuses while any is left under this checkout, naming each, and moves nothing.
new_repo >/dev/null
"$ORCH" init my-feature >/dev/null
git checkout -q -b orch/1-my-feature
top="$(git rev-parse --show-toplevel)"
"$ORCH" ticket-worktree add 4 >/dev/null
"$ORCH" ticket-worktree add 5 >/dev/null
out="$("$ORCH" archive 2>&1)"; st=$?
assert_status "archive refuses while a ticket worktree exists" "$st" 1
assert_contains "naming the first" "$out" "$top/.orchestrator/worktrees/t4"
assert_contains "naming the second" "$out" "$top/.orchestrator/worktrees/t5"
assert_contains "with ticket-worktree remove as the remedy" "$out" "ticket-worktree remove"
assert_eq "and moves nothing: the state stays" \
  "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "present"
assert_eq "no archive directory is made" \
  "$([ -e .orchestrator/archive ] && echo present || echo absent)" "absent"
assert_eq "the ticket worktrees stay where git recorded them" \
  "$(git -C .orchestrator/worktrees/t4 rev-parse --show-toplevel)" "$top/.orchestrator/worktrees/t4"
"$ORCH" ticket-worktree remove 4
"$ORCH" ticket-worktree remove 5
out="$("$ORCH" archive)"; st=$?
assert_status "with the ticket worktrees removed, archive moves the flow as before" "$st" 0
assert_eq "live state is cleared" "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "gone"

# --- repo show ----------------------------------------------------------------
# The GitHub repo orch.sh works on (#520): GH_REPO when the caller set it, else
# the checkout's origin - never gh's own default, which in a fork is upstream.
echo
echo "repo show"
new_repo >/dev/null
unset GH_REPO
assert_eq "a fresh test repo resolves to its github.com origin" \
  "$("$ORCH" repo show)" "o/r (origin)"
for url in https://github.com/acme/widgets.git https://github.com/acme/widgets \
           git@github.com:acme/widgets.git git@github.com:acme/widgets \
           ssh://git@github.com/acme/widgets.git ssh://git@github.com/acme/widgets; do
  git remote set-url origin "$url"
  assert_eq "origin $url resolves to acme/widgets" "$("$ORCH" repo show --name)" "acme/widgets"
done
for url in https://ghe.example.com/acme/widgets.git git@ghe.example.com:acme/widgets \
           ssh://git@ghe.example.com/acme/widgets.git; do
  git remote set-url origin "$url"
  assert_eq "origin $url keeps its host" "$("$ORCH" repo show --name)" "ghe.example.com/acme/widgets"
done
git remote set-url origin https://github.com/acme/widgets.git
assert_eq "GH_REPO wins over origin" "$(GH_REPO=fork/widgets "$ORCH" repo show)" "fork/widgets (GH_REPO)"
assert_eq "repo show --name prints GH_REPO bare" \
  "$(GH_REPO=fork/widgets "$ORCH" repo show --name)" "fork/widgets"
assert_eq "repo show names origin as the source" "$("$ORCH" repo show)" "acme/widgets (origin)"
out="$("$ORCH" repo show extra 2>&1)"; st=$?
assert_status "repo show refuses a stray argument" "$st" 1
assert_eq "naming both of its flags" "$out" "orch: usage: orch.sh repo show [--name|--host]"
out="$("$ORCH" repo show --name --host 2>&1)"; st=$?
assert_status "repo show refuses both flags at once" "$st" 1
assert_eq "repo show --host prints github.com for an OWNER/REPO repo" \
  "$("$ORCH" repo show --host)" "github.com"
assert_eq "repo show --host prints the explicit host of a HOST/OWNER/REPO repo" \
  "$(GH_REPO=ghe.example.com/fork/widgets "$ORCH" repo show --host)" "ghe.example.com"
git remote set-url origin git@ghe.example.com:acme/widgets.git
assert_eq "repo show --host reads the host from origin too" \
  "$("$ORCH" repo show --host)" "ghe.example.com"
git remote set-url origin https://github.com/acme/widgets.git
assert_contains "help lists --host under repo show" "$("$ORCH" help)" "repo show [--name|--host]"

# No GH_REPO and no usable origin: local commands still work, repo show fails.
git remote remove origin
"$ORCH" init norepo >/dev/null 2>&1
out="$("$ORCH" state get phase 2>&1)"; st=$?
assert_status "state get works with no repo to resolve" "$st" 0
for args in "" "--name" "--host"; do
  err="$(mktemp)"
  label="repo show${args:+ $args}"
  # shellcheck disable=SC2086 # an empty args is no argument at all, and "a b" is two
  out="$("$ORCH" repo show $args 2>"$err")"; st=$?
  assert_status "$label exits 1 with no repo" "$st" 1
  assert_eq "$label prints nothing on stdout with no repo" "$out" ""
  assert_eq "$label dies with the repo remedy" "$(cat "$err")" \
    "orch: no GitHub repo to work on: origin is missing or not a GitHub owner/name - set GH_REPO=<owner>/<repo>"
  rm -f "$err"
done
git remote add origin https://example.invalid/notgithub
out="$("$ORCH" repo show 2>/dev/null)"; st=$?
assert_status "an origin with no owner/name path does not resolve" "$st" 1

# --- default-branch ---------------------------------------------------------
# The base every feature branch forks from. Getting this wrong is silent: work
# lands on top of the wrong branch and nothing complains until review.
echo
echo "default-branch"
new_repo >/dev/null

# GitHub's answer comes from the store-backed fake (fake_default_branch); a
# store with none seeded is a repo gh cannot answer for.
fake_github

# origin/HEAD is a local pointer frozen at clone time; GitHub's answer must win.
git remote set-url origin https://example.invalid/x/y.git
git checkout -q -b some-feature
git update-ref refs/remotes/origin/some-feature HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/some-feature
fake_default_branch $'trunk\n'
assert_eq "prefers GitHub's answer over a stale origin/HEAD" "$("$ORCH" default-branch)" "trunk"
rm -f "$ORCH_GH_FAKE_STORE/default_branch"
assert_eq "falls back to origin/HEAD when gh cannot answer" "$("$ORCH" default-branch)" "some-feature"
git symbolic-ref -d refs/remotes/origin/HEAD
assert_eq "falls back to main when nothing else answers" "$("$ORCH" default-branch)" "main"

# A tool manager's shim (mise) can print a status line on stdout around gh's
# own answer (#465). Neither a two-line answer nor a failed gh's output may
# become the default branch: only a valid branch name is ever resolved.
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/some-feature
fake_default_branch $'mise ~/.config/mise/config.toml tools: gh@2.102.0\ntrunk\n'
assert_eq "falls back past a gh answer polluted by a banner line" "$("$ORCH" default-branch)" "some-feature"
fake_default_branch $'trunk\n'
fake_fail adapter_repo_default_branch
assert_eq "ignores the output of a gh that failed" "$("$ORCH" default-branch)" "some-feature"
fake_unfail
fake_default_branch $'\n'
assert_eq "an empty name from gh is no valid branch name" "$("$ORCH" default-branch)" "some-feature"
rm -f "$ORCH_GH_FAKE_STORE/default_branch"
git update-ref refs/remotes/origin/-dash HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/-dash
assert_eq "falls back to main past an origin/HEAD that is no valid branch name" \
  "$("$ORCH" default-branch)" "main"
git symbolic-ref -d refs/remotes/origin/HEAD
git update-ref -d refs/remotes/origin/-dash
restore_suite_env

# MISE_QUIET reaches every process orch.sh runs, the gh binary included, so a
# child process of orch.sh's own shell sees it.
assert_eq "gh run from orch.sh sees MISE_QUIET=1" \
  "$(env -u MISE_QUIET bash -c 'source "$1"; command printenv MISE_QUIET' _ "$ORCH")" "1"

# origin/HEAD names a branch that is not `main`, so an origin/HEAD fallback
# cannot pass for the final literal-`main` one.
new_repo_with_origin some-feature
fake_github
export GH_REPO=acme/widgets
fake_default_branch $'mise ~/.config/mise/config.toml tools: gh@2.102.0\ntrunk\n'
"$ORCH" init banner >/dev/null
recorded="$("$ORCH" state get base)"
assert_eq "init records origin/HEAD's branch as the base" "$recorded" "some-feature"
restore_suite_env

# --sha prints the default SHA: the full SHA of origin/<default> as it stands,
# without fetching - the remote-tracking tip the last fetch set.
new_repo >/dev/null
git checkout -q -B main
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin main
git fetch -q origin
fake_github
fake_default_branch $'main\n'
fetched_tip="$(git rev-parse HEAD)"
out="$("$ORCH" default-branch --sha 2>&1)"; st=$?
assert_status "--sha succeeds" "$st" 0
assert_eq "--sha prints the remote-tracking tip's full SHA" "$out" "$fetched_tip"
moved="$(git -C "$bare" -c user.email=test@example.com -c user.name=Test commit-tree "main^{tree}" -p main -m "moved on")"
git -C "$bare" update-ref refs/heads/main "$moved"
assert_ne "the remote's tip has moved on" "$(git -C "$bare" rev-parse main)" "$fetched_tip"
assert_eq "--sha does not fetch: a remote tip that moved since is not reported" \
  "$("$ORCH" default-branch --sha 2>&1)" "$fetched_tip"
assert_eq "and the remote-tracking ref is left where it was" "$(git rev-parse origin/main)" "$fetched_tip"
assert_eq "plain default-branch still prints the name" "$("$ORCH" default-branch 2>&1)" "main"
git update-ref -d refs/remotes/origin/main
out="$("$ORCH" default-branch --sha 2>&1)"; st=$?
assert_status "--sha fails when the remote-tracking ref is missing" "$st" 1
assert_contains "naming the ref" "$out" "refs/remotes/origin/main"
for arg in --name extra; do
  out="$("$ORCH" default-branch "$arg" 2>&1)"; st=$?
  assert_status "refuses any argument but --sha ($arg)" "$st" 1
  assert_eq "with its usage ($arg)" "$out" "orch: usage: orch.sh default-branch [--sha]"
done
out="$("$ORCH" default-branch --sha extra 2>&1)"; st=$?
assert_status "refuses an argument after --sha" "$st" 1
assert_eq "with its usage" "$out" "orch: usage: orch.sh default-branch [--sha]"
restore_suite_env

# --- branch create -----------------------------------------------------------
# Unlike branch off's caller-named branch, this one derives its own name from
# state - slug plus the recorded issue - and records both `branch` and
# `base_sha` for pr open and redo review to read back later via require_branch.
echo
echo "branch create"
new_repo_with_origin
orch_gh_failing init bcreate >/dev/null
orch_gh_failing state set issue 11
before_sha="$(git rev-parse HEAD)"
out="$(orch_gh_failing branch create)"
assert_eq "derives the branch name from slug and the recorded issue" "$out" "orch/11-bcreate"
assert_eq "checks the new branch out" "$(git branch --show-current)" "orch/11-bcreate"
assert_eq "records the branch in state" "$(orch_gh_failing state get branch)" "orch/11-bcreate"
assert_eq "records the fork point as base_sha" "$(orch_gh_failing state get base_sha)" "$before_sha"

# --- branch off --------------------------------------------------------------
# A quick implementation keeps no state, so this is the primitive it shares
# with a flow's own branch create: same fetch/checkout-fallback idiom, naming
# and recording left entirely to the caller.
echo
echo "branch off"
# default-branch resolves through git symbolic-ref as a fallback - give the
# repo one rather than letting the answer depend on this machine's git
# init.defaultBranch.
new_repo_with_origin
out="$(orch_gh_failing branch off "quick/9-widgets")"
assert_eq "prints the branch it made" "$out" "quick/9-widgets"
assert_eq "checks it out" "$(git branch --show-current)" "quick/9-widgets"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"

out="$(orch_gh_failing branch off "quick/9-widgets" 2>&1)"; st=$?
assert_status "refuses a name that already exists" "$st" 1
assert_contains "names the branch" "$out" "quick/9-widgets already exists"

out="$(orch_gh_failing branch off 2>&1)"; st=$?
assert_status "refuses with no name" "$st" 1

# #720: a quick implementation must never move an active flow's checkout off
# its branch, so branch off refuses beside a flow mid-pipeline exactly as init
# does - same exit code 3, same message - and checks nothing out.
for phase in spec implement review; do
  new_repo_with_origin
  orch_gh_failing init busy >/dev/null
  state_fixture phase "$phase"
  before="$(git branch --show-current)"
  out="$(orch_gh_failing branch off quick/4-beside 2>&1)"; st=$?
  assert_status "refuses beside a flow at $phase with exit 3" "$st" 3
  assert_contains "with init's message ($phase)" "$out" "a flow is already active (slug: busy, phase: $phase)."
  assert_contains "and init's remedy ($phase)" "$out" "One flow at a time"
  assert_eq "checks nothing out ($phase)" "$(git branch --show-current)" "$before"
  assert_eq "creates no branch ($phase)" \
    "$(git rev-parse --verify --quiet refs/heads/quick/4-beside >/dev/null && echo made || echo none)" "none"
done

new_repo_with_origin
orch_gh_failing init finished >/dev/null
state_fixture phase "done"
out="$(orch_gh_failing branch off quick/4-after)"; st=$?
assert_status "a done flow does not block branch off" "$st" 0
assert_eq "which checks the branch out as before" "$(git branch --show-current)" "quick/4-after"

# --- base --------------------------------------------------------------------
# The checkout-wide base branch setting and its one resolver. A typo here is
# silent in the worst way - work quietly forks from and targets a branch nobody
# will merge - so set must refuse anything origin does not have.
echo
echo "base"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main HEAD:refs/heads/uat
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
# orch_gh_failing's gh cannot answer, so default-branch settles on origin/HEAD -
# pinned above rather than left to this machine's gh.
base_setting() { git config --get orchestrator.base || echo "<unset>"; }

out="$(orch_gh_failing base show)"; st=$?
assert_status "show succeeds with nothing set" "$st" 0
assert_eq "show names the default branch as the source when nothing is set" "$out" "main (default)"

out="$(orch_gh_failing base set nosuch 2>&1)"; st=$?
assert_status "set refuses a branch missing from origin" "$st" 1
assert_contains "names the missing branch" "$out" "nosuch"
assert_eq "a refused set leaves the config untouched" "$(base_setting)" "<unset>"

out="$(orch_gh_failing base set uat 2>&1)"; st=$?
assert_status "set accepts a branch origin has" "$st" 0
assert_eq "set writes orchestrator.base" "$(base_setting)" "uat"
assert_eq "show names the setting as the source" "$(orch_gh_failing base show)" "uat (set)"
assert_eq "default-branch still names the default branch" "$(orch_gh_failing default-branch)" "main"

wt="$(mktemp -d)/wt"
git worktree add -q "$wt" -b base-wt
assert_eq "every worktree of the clone shares the setting" "$(cd "$wt" && orch_gh_failing base show)" "uat (set)"
git worktree remove --force "$wt"

git remote set-url origin "$(dirname "$bare")/unreachable.git"
out="$(orch_gh_failing base set main 2>&1)"; st=$?
assert_status "set refuses when origin cannot be reached to verify" "$st" 1
assert_eq "an unverified set leaves the config untouched" "$(base_setting)" "uat"
bare_origin "$bare"

out="$(orch_gh_failing base set main 2>&1)"; st=$?
assert_status "set accepts the default branch's own name" "$st" 0
assert_eq "setting the default branch acts as clearing" "$(base_setting)" "<unset>"
assert_eq "show then reports the default source" "$(orch_gh_failing base show)" "main (default)"

orch_gh_failing base set uat >/dev/null
out="$(orch_gh_failing base clear 2>&1)"; st=$?
assert_status "clear succeeds when a setting exists" "$st" 0
assert_eq "clear removes the setting" "$(base_setting)" "<unset>"
out="$(orch_gh_failing base clear 2>&1)"; st=$?
assert_status "clear succeeds when nothing was set" "$st" 0

out="$(orch_gh_failing base 2>&1)"; st=$?
assert_status "refuses a missing verb" "$st" 1
out="$(orch_gh_failing base set 2>&1)"; st=$?
assert_status "set refuses with no branch" "$st" 1
rm -rf "$(dirname "$bare")"

# --- parallel show -------------------------------------------------------------
# The clone's parallel cap: how many ticket subagents a frontier runs at once.
# The default lives here alone, so the skills never read git config themselves.
echo
echo "parallel show"
new_repo >/dev/null

out="$("$ORCH" parallel show 2>&1)"; st=$?
assert_status "parallel show succeeds with orchestrator.parallel unset" "$st" 0
assert_eq "the cap is 3 when orchestrator.parallel is unset" "$out" "3"

git config orchestrator.parallel 5
out="$("$ORCH" parallel show 2>&1)"; st=$?
assert_status "parallel show succeeds with a positive cap set" "$st" 0
assert_eq "the cap is orchestrator.parallel's value when set" "$out" "5"
git config orchestrator.parallel 1
assert_eq "a cap of 1, sequential, is a valid setting" "$("$ORCH" parallel show 2>&1)" "1"

for v in 0 -2 three 2x; do
  git config --unset-all orchestrator.parallel; git config orchestrator.parallel "$v"
  out="$("$ORCH" parallel show 2>&1)"; st=$?
  assert_status "parallel show dies on orchestrator.parallel=$v" "$st" 1
  assert_contains "naming the key" "$out" "orchestrator.parallel"
  assert_contains "and the value $v" "$out" "$v"
done
git config --unset orchestrator.parallel

out="$("$ORCH" parallel show extra 2>&1)"; st=$?
assert_status "parallel show refuses an argument" "$st" 1
assert_contains "with its usage line" "$out" "usage: orch.sh parallel show"
out="$("$ORCH" parallel bogus 2>&1)"; st=$?
assert_status "parallel bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown parallel op"

out="$("$ORCH" help 2>&1)"
assert_contains "parallel show is in the usage text" "$out" "parallel show"
assert_contains "beside base show" "$(printf '%s\n' "$out" | grep -A3 '^  base clear' | tr '\n' ' ')" "parallel show"
assert_contains "the CLI conventions' noun table has a parallel row" \
  "$(grep '^| `parallel`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`show`'

# --- a flow's base branch -------------------------------------------------------
# A flow fixes its base branch at init, so a later `base set` never moves the
# flow's fork point or its PR. uat carries a commit main does not, so where the
# flow branch forked from is visible in its history.
echo
echo "a flow's base branch"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
git checkout -q -b uat
git commit -q --allow-empty -m "uat only"
git push -q origin uat:refs/heads/uat
git checkout -q -
git branch -q -D uat
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
uat_tip="$(git rev-parse origin/uat)"
main_tip="$(git rev-parse origin/main)"

orch_gh_failing init nobase >/dev/null
assert_eq "init records the default branch as base when nothing is set" \
  "$(orch_gh_failing state get base)" "main"
rm -rf .orchestrator

orch_gh_failing base set uat >/dev/null
orch_gh_failing init flowbase >/dev/null
assert_eq "init records the base branch setting" "$(orch_gh_failing state get base)" "uat"

out="$(orch_gh_failing base set uat 2>&1)"
assert_not_contains "set says nothing more when the active flow already has that base" \
  "$out" "keeps its own base branch"
out="$(orch_gh_failing base set main 2>&1)"; st=$?
assert_status "set still succeeds while a flow with another base is active" "$st" 0
assert_contains "and notes that the active flow keeps its own base branch" \
  "$out" "flowbase keeps its own base branch: uat"
assert_eq "the flow's recorded base is untouched" "$(orch_gh_failing state get base)" "uat"

# base set --flow: the explicit correction of the flow's own base, allowed only
# while the flow has no branch. The checkout's setting is never its target.
checkout_setting() { git config --get orchestrator.base || echo "<unset>"; }
orch_gh_failing base set uat >/dev/null
out="$(orch_gh_failing base set main --flow 2>&1)"; st=$?
assert_status "base set --flow accepts the flag after the branch name" "$st" 0
assert_eq "and reports the flow's new base" "$out" "main (flow)"
assert_eq "storing the default branch's own name literally" "$(orch_gh_failing state get base)" "main"
assert_eq "leaving the checkout's base branch setting unchanged" "$(checkout_setting)" "uat"
orch_gh_failing base clear >/dev/null
out="$(orch_gh_failing base set --flow uat 2>&1)"; st=$?
assert_status "base set --flow accepts the flag before the branch name" "$st" 0
assert_eq "in the spec phase it prints the branch and its flow source" "$out" "uat (flow)"
assert_eq "state get base reads the corrected base" "$(orch_gh_failing state get base)" "uat"
assert_eq "and the unset checkout setting stays unset" "$(checkout_setting)" "<unset>"
for name in null 007; do
  git push -q origin "HEAD:refs/heads/$name"
  orch_gh_failing base set "$name" --flow >/dev/null
  assert_eq "base set --flow stores a branch named $name literally" \
    "$(orch_gh_failing state get base)" "$name"
done
state_fixture updated "sentinel"
orch_gh_failing base set uat --flow >/dev/null
assert_ne "base set --flow stamps updated" "$(orch_gh_failing state get updated)" "sentinel"

for args in "" "--flow" "uat main --flow" "uat --flow --flow" "uat --flaw"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  out="$(orch_gh_failing base set $args 2>&1)"; st=$?
  assert_status "base set refuses the arguments '$args'" "$st" 1
  assert_contains "with its usage line" "$out" "usage: orch.sh base set <branch> [--flow]"
done
out="$(orch_gh_failing base show --flow 2>&1)"; st=$?
assert_status "base show refuses --flow" "$st" 1
assert_contains "with its usage error" "$out" "usage: orch.sh base show"
out="$(orch_gh_failing base clear --flow 2>&1)"; st=$?
assert_status "base clear refuses --flow" "$st" 1
assert_contains "with its usage error" "$out" "usage: orch.sh base clear"

out="$(orch_gh_failing base set 'bad..name' --flow 2>&1)"; st=$?
assert_status "base set --flow refuses an invalid branch name" "$st" 1
assert_contains "saying nothing was set" "$out" "bad..name is not a valid branch name - nothing was set"
assert_eq "leaving the flow's base unchanged" "$(orch_gh_failing state get base)" "uat"
out="$(orch_gh_failing base set nosuch --flow 2>&1)"; st=$?
assert_status "base set --flow refuses a branch missing from origin" "$st" 1
assert_contains "with plain base set's message" "$out" \
  "branch nosuch does not exist on origin - push it first, or check the name"
assert_eq "leaving the flow's base unchanged" "$(orch_gh_failing state get base)" "uat"
git remote set-url origin "$(dirname "$bare")/unreachable.git"
out="$(orch_gh_failing base set main --flow 2>&1)"; st=$?
assert_status "base set --flow refuses when origin cannot be reached" "$st" 1
assert_contains "with plain base set's message" "$out" \
  "could not reach origin to check that branch main exists - nothing was set"
assert_eq "leaving the flow's base unchanged" "$(orch_gh_failing state get base)" "uat"
out="$(orch_gh_failing base set 'bad..name' --flow 2>&1)"
assert_contains "an invalid name is refused before origin is contacted" "$out" \
  "bad..name is not a valid branch name - nothing was set"
bare_origin "$bare"

# A flow init recorded on the default branch, corrected to uat before it
# branches: only the correction can make branch create fork from uat's tip,
# since neither the init-recorded base nor the unset checkout setting names it.
rm -rf .orchestrator
orch_gh_failing init flowbase >/dev/null
assert_eq "a flow started with nothing set records the default branch" \
  "$(orch_gh_failing state get base)" "main"
orch_gh_failing base set uat --flow >/dev/null
orch_gh_failing state set issue 7
out="$(orch_gh_failing branch create 2>&1)"; st=$?
assert_status "branch create succeeds" "$st" 0
assert_eq "the flow's next branch create forks from the corrected base's tip" \
  "$(git rev-parse HEAD)" "$uat_tip"

out="$(orch_gh_failing base set main --flow 2>&1)"; st=$?
assert_status "base set --flow refuses once the flow has a branch" "$st" 1
assert_contains "outside the review phase saying to abort" "$out" \
  "flow flowbase already has branch orch/7-flowbase - its base can no longer change; abort to start again on another base"
assert_eq "leaving the flow's base unchanged" "$(orch_gh_failing state get base)" "uat"
out="$(orch_gh_failing base set 'bad..name' --flow 2>&1)"
assert_contains "a branched flow given an invalid name reports the branch refusal" "$out" \
  "flow flowbase already has branch orch/7-flowbase"
assert_eq "base_sha is the recorded base's tip" "$(orch_gh_failing state get base_sha)" "$uat_tip"
assert_contains "status prints the flow's base branch" "$(orch_gh_failing status)" "base:      uat"

body="$(mktemp)"
writeln 'Implements the thing.' >"$body"
fake_github
fake_next_pr 31
out="$(orch_gh_failing pr open "Title" "$body" 2>&1)"; st=$?
assert_status "pr open succeeds" "$st" 0
assert_eq "pr open targets the flow's recorded base" "$(fake_pr_base_of 31)" "uat"
assert_first_line "a PR into a non-default base refers to its issue instead of closing it" \
  "$(fake_pr_body_of 31)" "Refs #7"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

# A deleted base branch must not quietly become a fork from a stale local copy.
git update-ref refs/remotes/origin/gone "$main_tip"
git branch -q gone "$main_tip"
state_fixture base gone
orch_gh_failing state set issue 8
out="$(orch_gh_failing branch create 2>&1)"; st=$?
assert_status "branch create refuses a base branch origin says is gone" "$st" 1
assert_contains "naming the base branch and the correction" "$out" \
  "base branch gone does not exist on origin - push it, or point this flow at another base: orch.sh base set <branch> --flow"
assert_eq "and creates no branch" \
  "$(git rev-parse --verify --quiet orch/8-flowbase >/dev/null && echo made || echo none)" "none"

# A flow started before base was recorded forked from the default branch.
legacy="$(mktemp)"
jq 'del(.base)' .orchestrator/state.json >"$legacy"
mv "$legacy" .orchestrator/state.json
assert_contains "status shows the default branch for a state with no base" \
  "$(orch_gh_failing status)" "base:      main"
git checkout -q main
out="$(orch_gh_failing branch create 2>&1)"; st=$?
assert_status "and branch create still forks it" "$st" 0
assert_eq "from the default branch" "$(git rev-parse HEAD)" "$main_tip"
orch_gh_failing base clear >/dev/null

# A done flow, or none at all, is no active flow to correct.
state_fixture phase "done"
out="$(orch_gh_failing base set uat --flow 2>&1)"; st=$?
assert_status "base set --flow refuses a done flow" "$st" 1
assert_contains "as no active flow" "$out" "no active flow - nothing was set"
assert_eq "leaving its base unchanged" "$(orch_gh_failing state get base)" ""
rm -rf .orchestrator
out="$(orch_gh_failing base set uat --flow 2>&1)"; st=$?
assert_status "base set --flow refuses with no state.json" "$st" 1
assert_contains "as no active flow" "$out" "no active flow - nothing was set"
out="$(orch_gh_failing base set 'bad..name' --flow 2>&1)"
assert_contains "no state.json plus an invalid name reports no active flow" "$out" \
  "no active flow - nothing was set"
assert_eq "and never touches the checkout setting" "$(checkout_setting)" "<unset>"
assert_contains "orch.sh help lists base set --flow" "$(orch_gh_failing help)" "base set <branch> --flow"
rm -rf "$(dirname "$bare")"

# --- a quick implementation's base branch --------------------------------------
# A quick implementation keeps no state.json, so branch off records the base
# branch it forked from on the branch itself - pr publish then targets that
# base even if the setting moved in the meantime, and falls back to the setting
# for a branch created before anything was recorded.
echo
echo "a quick implementation's base branch"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
git checkout -q -b uat
git commit -q --allow-empty -m "uat only"
git push -q origin uat:refs/heads/uat
git checkout -q -
git branch -q -D uat
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
uat_tip="$(git rev-parse origin/uat)"
main_tip="$(git rev-parse origin/main)"
recorded_base() { git config --get "branch.$1.orchestrator-base" || echo "<unset>"; }

orch_gh_failing base set uat >/dev/null
out="$(orch_gh_failing branch off quick/5-uat 2>&1)"; st=$?
assert_status "branch off succeeds" "$st" 0
assert_eq "branch off forks from the base branch in effect" "$(git rev-parse HEAD)" "$uat_tip"
assert_eq "and records it on the branch" "$(recorded_base quick/5-uat)" "uat"

git checkout -q main
orch_gh_failing base clear >/dev/null
orch_gh_failing branch off quick/6-main >/dev/null
assert_eq "with nothing set, branch off forks from the default branch" "$(git rev-parse HEAD)" "$main_tip"
assert_eq "and records the default branch" "$(recorded_base quick/6-main)" "main"

body="$(mktemp)"
writeln 'Implements the thing.' >"$body"
git checkout -q quick/5-uat
fake_github
fake_next_pr 41
out="$(orch_gh_failing pr publish 5 "Title" "$body" 2>&1)"; st=$?
assert_status "pr publish succeeds" "$st" 0
assert_eq "pr publish targets the recorded base over the changed setting" \
  "$(fake_pr_base_of 41)" "uat"
assert_first_line "a quick PR into a non-default base refers to its issue" \
  "$(fake_pr_body_of 41)" "Refs #5"

# A branch made before branch off recorded anything publishes to the setting.
git checkout -q -b quick/7-legacy "$main_tip"
orch_gh_failing base set uat >/dev/null
out="$(orch_gh_failing pr publish 7 "Title" "$body" 2>&1)"; st=$?
assert_status "pr publish succeeds with nothing recorded" "$st" 0
assert_eq "and falls back to the base branch setting" "$(fake_pr_base_of "$out")" "uat"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

# A deleted base branch must not quietly become a fork from a stale local copy.
git update-ref refs/remotes/origin/gone "$main_tip"
git config orchestrator.base gone
out="$(orch_gh_failing branch off quick/8-gone 2>&1)"; st=$?
assert_status "branch off refuses a base branch origin says is gone" "$st" 1
assert_contains "naming the base branch" "$out" \
  "base branch gone does not exist on origin - push it, or start again on another base branch"
assert_not_contains "never pointing at a flow's correction" "$out" "--flow"
assert_eq "and records nothing for the branch it did not make" "$(recorded_base quick/8-gone)" "<unset>"
orch_gh_failing base clear >/dev/null
rm -rf "$(dirname "$bare")"

# --- a quick implementation's base SHA (#243) ---------------------------------
# branch off records the base branch's tip at the moment of branching, the same
# meaning a flow's base_sha has, so a quick implementation's reviewers get a
# fixed point that a later merge of the base cannot shrink. A branch made before
# that was recorded falls back to the merge-base with its base branch.
echo
echo "a quick implementation's base SHA (#243)"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
branched_tip="$(git rev-parse origin/main)"
orch_gh_failing branch off quick/1-sha >/dev/null
assert_eq "branch off records the base branch's tip as the base SHA" \
  "$(git config --get branch.quick/1-sha.orchestrator-base-sha)" "$branched_tip"
git commit -q --allow-empty -m "work on the branch"

# The base branch moves on and the branch merges it in.
git checkout -q -b advance "$branched_tip"
git commit -q --allow-empty -m "main moves on"
git push -q origin advance:refs/heads/main
git fetch -q origin
moved_tip="$(git rev-parse origin/main)"
git checkout -q quick/1-sha
git branch -q -D advance
git merge -q --no-edit origin/main
assert_eq "the recorded base SHA is unchanged after the base branch moves on" \
  "$(git config --get branch.quick/1-sha.orchestrator-base-sha)" "$branched_tip"
out="$(orch_gh_failing branch base-sha 2>&1)"; st=$?
assert_status "branch base-sha succeeds" "$st" 0
assert_eq "branch base-sha prints the recorded base SHA" "$out" "$branched_tip"

git config --unset branch.quick/1-sha.orchestrator-base-sha
assert_eq "without a recorded SHA it prints the merge-base with the base branch" \
  "$(orch_gh_failing branch base-sha)" "$(git merge-base HEAD origin/main)"
assert_eq "which here is the base branch's tip it merged" "$(orch_gh_failing branch base-sha)" "$moved_tip"

# No remote-tracking ref for the recorded base branch: the local one answers.
git branch -q localbase "$branched_tip"
git config branch.quick/1-sha.orchestrator-base localbase
assert_eq "with no remote-tracking ref it uses the local base branch" \
  "$(orch_gh_failing branch base-sha)" "$branched_tip"

# Neither key: the base branch in effect, as pr publish does.
git checkout -q -b uat "$branched_tip"
git commit -q --allow-empty -m "uat only"
git push -q origin uat:refs/heads/uat
git fetch -q origin
uat_tip="$(git rev-parse origin/uat)"
git checkout -q -b quick/2-legacy uat
git commit -q --allow-empty -m "legacy work"
git config orchestrator.base uat
assert_eq "with neither key it uses the base branch setting" \
  "$(orch_gh_failing branch base-sha)" "$uat_tip"
git config --unset orchestrator.base
assert_eq "and the default branch when nothing is set" \
  "$(orch_gh_failing branch base-sha)" "$branched_tip"

git checkout -q --detach
out="$(orch_gh_failing branch base-sha 2>&1)"; st=$?
assert_status "refuses a detached HEAD" "$st" 1
assert_contains "saying so" "$out" "detached HEAD"
out="$(orch_gh_failing branch base-sha extra 2>&1)"; st=$?
assert_status "refuses arguments" "$st" 1
assert_contains "with the usage" "$out" "usage: orch.sh branch base-sha"
assert_contains "help documents branch base-sha" "$("$ORCH" help)" "branch base-sha"
rm -rf "$(dirname "$bare")"

# --- review-pass begin (#342) --------------------------------------------------
# A review pass's start: the guard and the numbered report prefix each have one
# right answer, so they live here. Needs no flow state, may run where init never
# did, and never wipes: a second pass on a branch never overwrites the first.
echo
echo "review-pass begin (#342)"
new_repo >/dev/null
top="$(git rev-parse --show-toplevel)"
git config orchestrator.base trunk
git checkout -q -b trunk
git checkout -q -b quick/12-foo
rp_dir="$top/.orchestrator/review-pass/quick/12-foo"
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "with no state file it proceeds" "$st" 0
assert_eq "printing the absolute iteration-01 prefix, the slashed branch as nested directories" \
  "$out" "$rp_dir/iteration-01"
assert_eq "creating the branch's directory" "$([ -d "$rp_dir" ] && echo yes || echo no)" "yes"
assert_eq "records no state" "$([ -f "$top/.orchestrator/state.json" ] && echo yes || echo no)" "no"
assert_contains "git-excludes .orchestrator/" "$(cat "$(git rev-parse --git-common-dir)/info/exclude")" ".orchestrator/"
assert_contains "git-excludes .scratch/" "$(cat "$(git rev-parse --git-common-dir)/info/exclude")" ".scratch/"
assert_eq "and leaves the working tree clean" "$(git status --porcelain)" ""
echo first >"$rp_dir/iteration-01-spec.md"
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "a second pass succeeds" "$st" 0
assert_eq "numbered iteration-02 once a report for 01 exists" "$out" "$rp_dir/iteration-02"
assert_eq "leaving the 01 report in place" "$(cat "$rp_dir/iteration-01-spec.md" 2>&1)" "first"
echo third >"$rp_dir/iteration-03-standards.md"
echo stray >"$rp_dir/iteration-09.md"
echo stray >"$rp_dir/notes-11-x.md"
out="$("$ORCH" review-pass begin 12 2>&1)"
assert_eq "one past the highest number, over a gap, ignoring stray files" "$out" "$rp_dir/iteration-04"

rp_state="$top/.orchestrator/state.json"
rp_flow() { printf '{"slug":"x","phase":"%s","issue":%s,"branch":%s}\n' "$1" "$2" "$3" >"$rp_state"; }
rp_next="/orchestrator:next (or orch-flow's Next phase section)"
for p in implement review; do
  rp_flow "$p" 12 '"orch/12-x"'
  before="$(cksum <"$rp_state")"
  out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
  assert_status "an active flow holding the issue at $p refuses it" "$st" 1
  assert_eq "naming the next command at $p" "$out" \
    "orch: the active flow holds issue #12 at phase $p - this change belongs to that flow's review loop; run $rp_next"
  assert_eq "state.json byte-identical at $p" "$(cksum <"$rp_state")" "$before"
done
rp_flow review 30 '"quick/12-foo"'
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "an active flow holding the current branch under another issue refuses it" "$st" 1
assert_eq "naming the flow's own issue" "$out" \
  "orch: the active flow holds issue #30 at phase review - this change belongs to that flow's review loop; run $rp_next"
rp_flow spec 12 null
before="$(cksum <"$rp_state")"
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "a flow at spec holding the issue refuses it" "$st" 1
assert_eq "with the spec-phase message" "$out" \
  "orch: the active flow holds issue #12 at phase spec - its change has not been built yet; run $rp_next"
assert_eq "state.json byte-identical at spec" "$(cksum <"$rp_state")" "$before"
rp_flow bogus 12 null
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "a phase outside PHASES refuses it" "$st" 1
assert_eq "pointing at doctor --flow" "$out" \
  "orch: the active flow holds issue #12 at phase 'bogus', which is not a flow phase - refusing to review it; run orch.sh doctor --flow"
rp_flow "done" 12 '"quick/12-foo"'
before="$(cksum <"$rp_state")"
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "a done flow holding the issue and branch is allowed" "$st" 0
assert_eq "printing the next prefix" "$out" "$rp_dir/iteration-04"
assert_eq "state.json byte-identical after begin" "$(cksum <"$rp_state")" "$before"
rp_flow implement 14 '"orch/14-x"'
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "an active flow on another issue and branch lets it through" "$st" 0
rm -f "$rp_state"

for args in "" "abc" "12x" "../12" "12 13"; do
  # shellcheck disable=SC2086 # word splitting is the point: "12 13" is two args
  out="$("$ORCH" review-pass begin $args 2>&1)"; st=$?
  assert_status "refuses begin '$args'" "$st" 1
done
out="$("$ORCH" review-pass begin 2>&1)"
assert_contains "a missing number gets the usage" "$out" "usage: orch.sh review-pass begin <issue>"
out="$("$ORCH" review-pass begin abc 2>&1)"
assert_contains "a non-numeric issue is named" "$out" "issue must be a plain issue number"
out="$("$ORCH" review-pass wipe 12 2>&1)"; st=$?
assert_status "refuses an op it does not have" "$st" 1
assert_contains "naming the one it does" "$out" "want begin"
git checkout -q trunk
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "refuses the base branch" "$st" 1
assert_contains "saying so" "$out" "is the base branch"
git checkout -q --detach
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "refuses a detached HEAD" "$st" 1
assert_contains "saying so" "$out" "not on a branch (detached HEAD)"
out="$("$ORCH" quick path 2>&1)"; st=$?
assert_status "quick path is gone" "$st" 1
assert_contains "as an unknown command" "$out" "unknown command: quick"
help="$("$ORCH" help)"
assert_contains "help documents review-pass begin" "$help" "review-pass begin <issue>"
assert_not_contains "help no longer mentions quick path" "$help" "quick path"

# --- branch retire ------------------------------------------------------------
# The rename-aside a redo uses instead of deleting or force-pushing over a
# discarded attempt's commits. The push/delete-remote-ref assertions reuse the
# bare-repo-as-origin fixture branch create and pr open already use.
echo
echo "branch retire"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main

out="$(orch_gh_failing branch retire nosuchbranch new 2>&1)"; st=$?
assert_status "refuses a branch that does not exist" "$st" 1
assert_contains "naming it" "$out" "nosuchbranch does not exist"

git branch old-attempt
git branch taken
out="$(orch_gh_failing branch retire old-attempt taken 2>&1)"; st=$?
assert_status "refuses a destination name already in use" "$st" 1
assert_contains "naming it" "$out" "taken already exists"
git branch -d taken

out="$(orch_gh_failing branch retire old-attempt old-attempt-redo-1 2>&1)"; st=$?
assert_status "renames a branch with no upstream" "$st" 0
assert_eq "prints the new name" "$out" "old-attempt-redo-1"
assert_eq "the old name is gone locally" \
  "$(git rev-parse --verify --quiet old-attempt >/dev/null 2>&1 && echo present || echo gone)" "gone"
assert_eq "the new name exists" \
  "$(git rev-parse --verify --quiet old-attempt-redo-1 >/dev/null 2>&1 && echo present || echo gone)" "present"

git checkout -q -b to-retire
git push -q -u origin to-retire
out="$(orch_gh_failing branch retire to-retire to-retire-redo-1 2>&1)"; st=$?
assert_status "renames and republishes a branch with an upstream" "$st" 0
assert_eq "prints the new name" "$out" "to-retire-redo-1"
assert_eq "pushes the new name to origin" \
  "$(git -C "$bare" rev-parse --quiet --verify refs/heads/to-retire-redo-1 >/dev/null && echo present || echo gone)" "present"
# Not optional: a leftover ref under the un-suffixed name is exactly what the
# next implement attempt's branch create/pr open would collide with.
assert_eq "and deletes the old remote ref" \
  "$(git -C "$bare" rev-parse --quiet --verify refs/heads/to-retire >/dev/null && echo present || echo gone)" "gone"

# The fixture gap named in spec review: no test in the suite forces a real
# `git push` to fail, since the gh-stub exit overrides only apply to gh.
# Pointing origin at a path removed out from under it does.
git checkout -q -b to-fail
git push -q -u origin to-fail
rm -rf "$bare"
out="$(orch_gh_failing branch retire to-fail to-fail-redo-1 2>&1)"; st=$?
assert_status "dies when the push to origin fails" "$st" 1
assert_contains "with a clear reason" "$out" "could not push"
# The local rename happens before the push is even attempted - issue #63:
# without a rollback, a push failure leaves `old` gone locally with nothing
# a retry could find, even though nothing was ever published.
assert_eq "rolls the local rename back so the old name still exists" \
  "$(git rev-parse --verify --quiet to-fail >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and the new name is not left dangling in its place" \
  "$(git rev-parse --verify --quiet to-fail-redo-1 >/dev/null 2>&1 && echo present || echo gone)" "gone"

# Retrying with the same old/new names must succeed once whatever blocked
# the push clears - issue #63 acceptance criterion 1.
bare2="$(mktemp -d)/origin.git"
git init -q --bare "$bare2"
bare_origin "$bare2"
out="$(orch_gh_failing branch retire to-fail to-fail-redo-1 2>&1)"; st=$?
assert_status "retrying the same rename succeeds once origin is reachable again" "$st" 0
assert_eq "prints the new name" "$out" "to-fail-redo-1"
assert_eq "renames locally" \
  "$(git rev-parse --verify --quiet to-fail-redo-1 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and publishes it" \
  "$(git -C "$bare2" rev-parse --quiet --verify refs/heads/to-fail-redo-1 >/dev/null && echo present || echo gone)" "present"

# Idempotent resume: a previous call whose local rename and remote push both
# already succeeded, but whose remote delete of the old ref did not - the
# "Key interfaces" note in issue #63, that retire must resume rather than
# fail on "$old does not exist" when $old really is gone locally already.
bare3="$(mktemp -d)/origin.git"
git init -q --bare "$bare3"
bare_origin "$bare3"
git checkout -q -b to-resume
git push -q -u origin to-resume
git branch -m to-resume to-resume-redo-1
git push -q -u origin to-resume-redo-1
# The old ref is deliberately left on origin, standing in for the failed
# delete a real partial failure would leave behind.
out="$(orch_gh_failing branch retire to-resume to-resume-redo-1 2>&1)"; st=$?
assert_status "resumes rather than failing on the already-gone old name" "$st" 0
assert_eq "prints the new name" "$out" "to-resume-redo-1"
assert_eq "and finishes the delete the earlier attempt left undone" \
  "$(git -C "$bare3" rev-parse --quiet --verify refs/heads/to-resume >/dev/null && echo present || echo gone)" "gone"

# A genuine remote failure on that same delete step still has to die, not
# get swallowed by the resume path's tolerance for an already-gone ref.
bare4="$(mktemp -d)/origin.git"
git init -q --bare "$bare4"
git -C "$bare4" symbolic-ref HEAD refs/heads/to-protect
git -C "$bare4" config receive.denyDeleteCurrentBranch refuse
bare_origin "$bare4"
git checkout -q -b to-protect
git push -q -u origin to-protect
out="$(orch_gh_failing branch retire to-protect to-protect-redo-1 2>&1)"; st=$?
assert_status "dies when the old ref genuinely cannot be deleted" "$st" 1
assert_contains "with a clear reason" "$out" "could not delete origin/to-protect"

out="$(orch_gh_failing branch retire 2>&1)"; st=$?
assert_status "refuses with the wrong number of arguments" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh branch retire"

# --- branch: unknown op -------------------------------------------------------
new_repo >/dev/null
out="$(orch_gh_failing branch bogus 2>&1)"; st=$?
assert_status "branch bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown branch op"
assert_contains "naming all four" "$out" "create|off|base-sha|retire"

# --- issue publish ------------------------------------------------------------
# The publishing boundary a quick implementation calls instead of hardcoding
# `gh issue create` in skill prose - stateless like branch off, since a quick
# implementation has no flow to record into.
#
# Creation goes through the store-backed fake (fake_github), and what it filed
# is read back from the store - the fixture gh's log stays empty, proving it never
# spawns a real gh subprocess. The real operation is pinned in "gh adapter
# contract".
echo
echo "issue publish"
healthy_repo
fake_github
body="$(mktemp)"
writeln 'The shared understanding, written up.' >"$body"
: >"$GH_FIXTURE/env.log"
fake_next_issue 7
out="$("$ORCH" issue publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "publishes" "$st" 0
assert_eq "printing the issue number and nothing else" "$out" "7"
assert_eq "filing an open issue" "$(fake_state_of 7)" "OPEN"
assert_eq "under the title given" "$(fake_title_of 7)" "Widgets need a handle"
assert_eq "with the body file's contents" "$(fake_body_of 7)" "The shared understanding, written up."
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the create call never reached a real gh subprocess" "$(gh_calls)" "0"

fake_github
out="$("$ORCH" issue publish "" "$body" 2>&1)"; st=$?
assert_status "refuses an empty title" "$st" 1

out="$("$ORCH" issue publish "Title" /nonexistent/body.md 2>&1)"; st=$?
assert_status "refuses a body file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"

out="$("$ORCH" issue publish "Title" 2>&1)"; st=$?
assert_status "refuses with no body file" "$st" 1
assert_eq "filing nothing for any of them" "$(fake_issues)" ""

fake_fail adapter_issue_create "HTTP 502: Bad Gateway"
out="$("$ORCH" issue publish "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not create the issue fails the command" "$st" 1
assert_contains "passing gh's reason through" "$out" "HTTP 502: Bad Gateway"
assert_eq "with no number printed for a record to cite" \
  "$(printf '%s\n' "$out" | grep -cx '[0-9][0-9]*')" "0"
restore_suite_env

# --- issue publish verify-then-die -------------------------------------------
# The spec a flow or a quick implementation works from gets the guarantee
# ticket publish gives its tickets: created under the ready-for-agent role's
# label, then read back - title and labels - with one retry on a mismatch and
# a death naming the issue on the second. fake_lag makes the readback stale
# for N calls, answering nothing, or the stale title and labels it is given.
echo
echo "issue publish verify-then-die"
healthy_repo
fake_github
body="$(mktemp)"
writeln 'The shared understanding, written up.' >"$body"
publish() { "$ORCH" issue publish "$@"; }

fake_next_issue 8
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "publishes with the canonical labels" "$st" 0
assert_eq "printing the issue number and nothing else" "$out" "8"
assert_eq "applies ready-for-agent" "$(fake_labels_of 8)" "ready-for-agent "

writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
        '| `ready-for-agent`          | `agent go`           | AFK-ready   |' >docs/agents/triage-labels.md
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "publishes under a renamed ready-for-agent label" "$st" 0
assert_eq "applying the repo's name for it, rather than the canonical one" "$(fake_labels_of "$out")" "agent go "

rm docs/agents/triage-labels.md
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "publishes with no labels doc at all" "$st" 0
assert_eq "applying the canonical ready-for-agent name" "$(fake_labels_of "$out")" "ready-for-agent "
labels_doc docs/agents/triage-labels.md

fake_next_issue 9
fake_lag adapter_issue_title_labels 1
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "a readback that is stale once, then right, succeeds" "$st" 0
assert_eq "printing the issue number" "$out" "9"

fake_next_issue 10
fake_lag adapter_issue_title_labels 2
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "a readback stale twice dies" "$st" 1
assert_contains "naming the issue" "$out" "issue #10"
assert_contains "saying it did not verify" "$out" "did not verify"
assert_eq "with no number printed for a record to cite" \
  "$(printf '%s\n' "$out" | grep -cx '[0-9][0-9]*')" "0"

fake_next_issue 11
fake_lag adapter_issue_title_labels 2 "$(writeln "Something else" ready-for-agent)"
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "a title that reads back wrong fails verification" "$st" 1
assert_contains "naming the issue" "$out" "issue #11"

fake_next_issue 12
fake_lag adapter_issue_title_labels 2 "$(writeln "Widgets need a handle" needs-triage)"
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "a label set missing ready-for-agent fails verification" "$st" 1
assert_contains "naming the issue" "$out" "issue #12"

fake_next_issue 13
fake_lag adapter_issue_title_labels 2 "$(writeln "Widgets need a handle" bug ready-for-agent)"
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "extra labels beside ready-for-agent still verify" "$st" 0
restore_suite_env

# --- issue triage -------------------------------------------------------------
# The planning close's one write to GitHub (#571): an open issue moved to the
# repo's ready-for-agent label, so init --issue can adopt it. Run against the
# store-backed fake; what it did is read back from the store.
echo
echo "issue triage"
healthy_repo
fake_github
triage() { "$ORCH" issue triage "$@"; }
comment_count() { ls "$ORCH_GH_FAKE_STORE/issues/$1/comments" 2>/dev/null | wc -l | tr -d ' '; }

fake_issue 40 open needs-triage bug
out="$(triage 40 2>&1)"; st=$?
assert_status "triages a needs-triage issue" "$st" 0
assert_eq "leaving ready-for-agent and no other triage label" "$(fake_labels_of 40)" "bug ready-for-agent "
assert_eq "with exactly one comment" "$(comment_count 40)" "1"
assert_contains "naming ready-for-agent in it" "$(fake_comments_of 40)" "ready-for-agent"

fake_issue 41 open needs-info
out="$(triage 41 2>&1)"; st=$?
assert_status "triages a needs-info issue" "$st" 0
assert_eq "leaving ready-for-agent alone" "$(fake_labels_of 41)" "ready-for-agent "
assert_eq "with exactly one comment" "$(comment_count 41)" "1"

fake_issue 42 open
out="$(triage 42 2>&1)"; st=$?
assert_status "triages an unlabelled issue" "$st" 0
assert_eq "leaving ready-for-agent alone" "$(fake_labels_of 42)" "ready-for-agent "
assert_eq "with exactly one comment" "$(comment_count 42)" "1"

fake_issue 43 open ready-for-agent bug
before="$(fake_snapshot)"
out="$(triage 43 2>&1)"; st=$?
assert_status "an issue already ready-for-agent is a no-op" "$st" 0
assert_eq "relabelling nothing and posting no comment" "$(fake_snapshot)" "$before"

for held in wontfix ready-for-human; do
  fake_issue 44 open "$held"
  before="$(fake_snapshot)"
  out="$(triage 44 2>&1)"; st=$?
  assert_status "$held without --override asks for a decision, exit 2" "$st" 2
  assert_contains "printing the label it found" "$out" "$held"
  assert_eq "changing nothing" "$(fake_snapshot)" "$before"
  out="$(triage 44 --override 2>&1)"; st=$?
  assert_status "$held with --override is triaged" "$st" 0
  assert_eq "replaced by ready-for-agent" "$(fake_labels_of 44)" "ready-for-agent "
  assert_eq "with exactly one comment" "$(comment_count 44)" "1"
done

fake_issue 45 open needs-triage review:major
before="$(fake_snapshot)"
out="$(triage 45 2>&1)"; st=$?
assert_status "a filed finding is refused" "$st" 1
assert_contains "naming the issue" "$out" "issue #45"
assert_contains "saying it is not yet triaged" "$out" "not yet triaged"
assert_contains "pointing at finding triage" "$out" "/orchestrator:finding-triage"
out="$(ORCHESTRATOR_HOST=junie "$ORCH" issue triage 45 2>&1)"
assert_contains "naming the finding-triage skill off Claude Code" "$out" "orch-finding-triage skill"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"

fake_issue 52 open needs-triage review:minor
before="$(fake_snapshot)"
out="$(triage 52 2>&1)"; st=$?
assert_status "a finding under any review:<severity> label is refused" "$st" 1
assert_contains "naming the issue" "$out" "issue #52"
assert_contains "saying it is not yet triaged" "$out" "not yet triaged"
assert_contains "pointing at finding triage" "$out" "/orchestrator:finding-triage"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"

# A finding carrying one of finding triage's own labels has been checked
# against the default branch (ADR-0031), so it takes the ordinary path (#586).
fake_issue 60 open review:major bug ready-for-human
before="$(fake_snapshot)"
out="$(triage 60 2>&1)"; st=$?
assert_status "a ready-for-human finding without --override asks for a decision, exit 2" "$st" 2
assert_eq "printing the label it found" "$out" "ready-for-human"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"
out="$(triage 60 --override 2>&1)"; st=$?
assert_status "a ready-for-human finding with --override is triaged" "$st" 0
assert_eq "keeping its severity and category beside ready-for-agent" \
  "$(fake_labels_of 60)" "bug ready-for-agent review:major "
assert_eq "with exactly one comment" "$(comment_count 60)" "1"

fake_issue 61 open review:major wontfix
before="$(fake_snapshot)"
out="$(triage 61 2>&1)"; st=$?
assert_status "a wontfix finding without --override asks for a decision, exit 2" "$st" 2
assert_eq "printing the label it found" "$out" "wontfix"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"

fake_issue 62 open review:nit ready-for-agent
before="$(fake_snapshot)"
out="$(triage 62 2>&1)"; st=$?
assert_status "a finding already ready-for-agent is a no-op" "$st" 0
assert_eq "relabelling nothing and posting no comment" "$(fake_snapshot)" "$before"

# Refused: labels that do not show finding triage ran on it, --override or not.
for case in "63|review:major" "64|review:major needs-info" \
            "65|review:major needs-triage|--override" "66|review:major|--override"; do
  n="${case%%|*}"; rest="${case#*|}"; flag="${rest#*|}"; [ "$flag" != "$rest" ] || flag=""
  # shellcheck disable=SC2086 # the labels split into separate arguments
  fake_issue "$n" open ${rest%%|*}
  before="$(fake_snapshot)"
  # shellcheck disable=SC2086 # an empty flag is no argument at all
  out="$(triage "$n" $flag 2>&1)"; st=$?
  assert_status "a finding labelled '${rest%%|*}' ${flag:-without --override} is refused" "$st" 1
  assert_contains "naming the issue" "$out" "issue #$n"
  assert_contains "saying it is not yet triaged" "$out" "not yet triaged"
  assert_contains "pointing at finding triage" "$out" "/orchestrator:finding-triage"
  assert_eq "changing nothing" "$(fake_snapshot)" "$before"
done

fake_issue 46 closed needs-triage
before="$(fake_snapshot)"
out="$(triage 46 2>&1)"; st=$?
assert_status "a closed issue is refused" "$st" 1
assert_contains "naming the issue" "$out" "issue #46"
assert_eq "changing nothing and posting no comment" "$(fake_snapshot)" "$before"

fake_issue 47 open needs-triage
fake_fail adapter_issue_state_labels "HTTP 502: Bad Gateway"
before="$(fake_snapshot)"
out="$(triage 47 2>&1)"; st=$?
assert_status "a failed read dies" "$st" 1
assert_contains "naming the issue" "$out" "issue #47"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"
fake_unfail

fake_issue 48 open needs-triage
fake_fail adapter_issue_relabel "HTTP 502: Bad Gateway"
out="$(triage 48 2>&1)"; st=$?
assert_status "a failed relabel dies" "$st" 1
assert_contains "naming the issue" "$out" "issue #48"
assert_eq "posting no comment" "$(comment_count 48)" "0"
fake_unfail

# The readback lags after the first read, which answered current. A second
# relabel would fail (fake_fail_after), so a re-read that relabelled again
# could not pass.
fake_issue 49 open needs-triage
fake_lag_after adapter_issue_state_labels 1 1 "$(writeln OPEN needs-triage)"
fake_fail_after adapter_issue_relabel 1
out="$(triage 49 2>&1)"; st=$?
assert_status "a readback stale once, then right, succeeds" "$st" 0
assert_eq "re-reading without relabelling again" "$(fake_labels_of 49)" "ready-for-agent "
assert_eq "with exactly one comment" "$(comment_count 49)" "1"
fake_unfail

fake_issue 50 open needs-triage
fake_lag_after adapter_issue_state_labels 1 2 "$(writeln OPEN needs-triage ready-for-agent)"
out="$(triage 50 2>&1)"; st=$?
assert_status "a readback stale twice dies" "$st" 1
assert_contains "naming the issue" "$out" "issue #50"
assert_eq "posting no comment" "$(comment_count 50)" "0"

fake_issue 51 open needs-triage
fake_fail adapter_issue_comment "HTTP 502: Bad Gateway"
errf="$(mktemp)"
triage 51 >/dev/null 2>"$errf"; st=$?
assert_status "a failed comment after a verified relabel still exits 0" "$st" 0
assert_eq "warning on stderr, naming the issue" "$(grep '^orch: ' "$errf")" \
  "orch: warning: issue #51 is labelled ready-for-agent, but gh could not post the triage comment on it"
assert_eq "the relabel standing" "$(fake_labels_of 51)" "ready-for-agent "
rm -f "$errf"
fake_unfail

writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' \
        '| `needs-info`               | `more info`          | Waiting     |' \
        '| `ready-for-agent`          | `agent go`           | AFK-ready   |' \
        '| `ready-for-human`          | `human go`           | Needs human |' \
        '| `wontfix`                  | `nope`               | Not doing   |' >docs/agents/triage-labels.md
fake_issue 53 open "triage me" needs-triage
out="$(triage 53 2>&1)"; st=$?
assert_status "triages under renamed labels" "$st" 0
assert_eq "removing the repo's name for needs-triage, adding its ready-for-agent" \
  "$(fake_labels_of 53)" "agent go needs-triage "
assert_contains "naming the local label in the comment" "$(fake_comments_of 53)" "agent go"
fake_issue 54 open nope
out="$(triage 54 2>&1)"; st=$?
assert_status "a renamed wontfix asks for a decision" "$st" 2
assert_eq "printing the repo's name for it" "$out" "nope"
fake_issue 55 open "agent go"
before="$(fake_snapshot)"
out="$(triage 55 2>&1)"; st=$?
assert_status "a renamed ready-for-agent is a no-op" "$st" 0
assert_eq "changing nothing" "$(fake_snapshot)" "$before"
fake_issue 67 open "triage me" review:major
before="$(fake_snapshot)"
out="$(triage 67 --override 2>&1)"; st=$?
assert_status "a finding under the renamed needs-triage is refused" "$st" 1
assert_contains "saying it is not yet triaged" "$out" "not yet triaged"
assert_contains "naming the issue" "$out" "issue #67"
assert_contains "pointing at finding triage" "$out" "/orchestrator:finding-triage"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"
fake_issue 68 open "human go" review:major
out="$(triage 68 2>&1)"; st=$?
assert_status "a finding under the renamed ready-for-human asks for a decision" "$st" 2
assert_eq "printing the repo's name for it" "$out" "human go"
labels_doc docs/agents/triage-labels.md

out="$(triage abc 2>&1)"; st=$?
assert_status "a non-numeric issue is a usage error" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh issue triage"
out="$(triage 40 --force 2>&1)"; st=$?
assert_status "an unknown flag is a usage error" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh issue triage"
out="$(triage 2>&1)"; st=$?
assert_status "no issue at all is a usage error" "$st" 1
out="$("$ORCH" issue bogus 2>&1)"
assert_contains "the unknown-op message lists triage" "$out" "|triage"
assert_contains "help documents issue triage" "$("$ORCH" help)" "issue triage <n> [--override]"
restore_suite_env

# --- issue ready --------------------------------------------------------------
# The spec skill's rewrite-mode check (#705): does an issue carry the repo's
# ready-for-agent label? Exit 0 yes, 1 no, 2 when GitHub could not be read.
echo
echo "issue ready"
healthy_repo
fake_github
ready() { "$ORCH" issue ready "$@"; }

fake_issue 70 open ready-for-agent bug
ready 70 >/dev/null 2>&1; st=$?
assert_status "an issue carrying ready-for-agent is ready" "$st" 0

fake_issue 71 open needs-triage bug
out="$(ready 71 2>&1)"; st=$?
assert_status "an issue carrying neither label is not ready" "$st" 1
assert_eq "and says nothing" "$out" ""

fake_issue 72 open
ready 72 >/dev/null 2>&1; st=$?
assert_status "an unlabelled issue is not ready" "$st" 1

writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `ready-for-agent`          | `agent go`           | AFK-ready   |' >docs/agents/triage-labels.md
fake_issue 73 open "agent go"
ready 73 >/dev/null 2>&1; st=$?
assert_status "an issue carrying the repo's mapped name is ready" "$st" 0
fake_issue 74 open needs-triage
ready 74 >/dev/null 2>&1; st=$?
assert_status "under a mapping, an issue carrying neither is not ready" "$st" 1
labels_doc docs/agents/triage-labels.md

fake_fail adapter_issue_state_labels
out="$(ready 70 2>&1)"; st=$?
assert_status "a gh failure exits 2" "$st" 2
assert_contains "with an orch: message naming the issue" "$out" "orch: gh could not read issue #70"
fake_unfail

out="$(ready abc 2>&1)"; st=$?
assert_status "a non-numeric issue is a usage error" "$st" 2
assert_contains "with a usage line" "$out" "usage: orch.sh issue ready <n>"
out="$(ready 2>&1)"; st=$?
assert_status "no issue at all is a usage error" "$st" 2
assert_contains "with a usage line" "$out" "usage: orch.sh issue ready <n>"
out="$(ready 70 71 2>&1)"; st=$?
assert_status "a second argument is a usage error" "$st" 2
out="$("$ORCH" issue bogus 2>&1)"
assert_contains "the unknown-op message lists ready" "$out" "|ready"
assert_contains "help documents issue ready" "$("$ORCH" help)" "issue ready <n>"
assert_contains "the CLI conventions' noun table lists issue ready" \
  "$(grep '^| `issue`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`ready`'
restore_suite_env

# --- mp-skill ---------------------------------------------------------------
# The plugin reads no upstream skill any more (ADR-0028), so the resolver is gone.
echo
echo "mp-skill"
new_repo >/dev/null
out="$("$ORCH" mp-skill to-spec 2>&1)"; st=$?
assert_status "mp-skill is an unknown command" "$st" 1
assert_contains "and says so" "$out" "unknown command: mp-skill"

# --- init --issue -------------------------------------------------------
# Adoption is validated once, immediately, before state.json is written - a bad
# issue number must cost nothing, the same promise branch create and pr open
# already make about their own preconditions.
echo
echo "init --issue"
healthy_repo
fake_github
fake_issue 42 open ready-for-agent
out="$("$ORCH" init adopted --issue 42)"
assert_eq "adopts an open, labelled issue" "$out" "adopted"
assert_eq "issue is recorded as a number" "$("$ORCH" state get | jq -r '.issue | type')" "number"
assert_eq "issue value matches the adopted number" "$("$ORCH" state get issue)" "42"

healthy_repo
out="$("$ORCH" init nope --issue 99 2>&1)"; st=$?
assert_status "refuses to adopt an issue gh cannot read" "$st" 1
assert_contains "names the issue number" "$out" "99"
assert_eq "no flow is left active after a failed adoption" \
  "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "gone"

healthy_repo
fake_issue 7 closed ready-for-agent
out="$("$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "refuses to adopt a closed issue" "$st" 1
assert_contains "says the issue is not open" "$out" "not open"

healthy_repo
fake_issue 7 open needs-triage
out="$("$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "refuses to adopt an issue missing the triage label" "$st" 1
assert_contains "names the missing label" "$out" "ready-for-agent"

# validate_adopted_issue's state and labels come off the same issue, so one
# read answers both: adapter_issue_state_labels, whose single gh call is
# pinned in "gh adapter contract".

healthy_repo
out="$("$ORCH" init nope --issue 2>&1)"; st=$?
assert_status "requires a value after --issue" "$st" 1

healthy_repo
out="$("$ORCH" init nope --issue https://github.com/acme/widgets/issues/42 2>&1)"; st=$?
assert_status "refuses a non-numeric --issue value" "$st" 1
assert_contains "says --issue wants a plain number" "$out" "--issue"
assert_eq "no flow is left active after a malformed --issue" \
  "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "gone"

healthy_repo
out="$("$ORCH" init 2>&1)"; st=$?
assert_status "adoption does not change that a slug is still required" "$st" 1
restore_suite_env

# --- init archives a done flow -----------------------------------------------
# issue #13: a "done" flow already succeeded - nothing downstream reads its
# handoffs - so starting over it is normal pipeline cleanup, not something
# init should still refuse as "active".
echo
echo "init archives a done flow"
fresh_flow first
complete_plan_handoff "$("$ORCH" handoff path spec)"
state_fixture phase "done"
out="$("$ORCH" init second)"; st=$?
assert_status "starting over a done flow succeeds" "$st" 0
archived="$(printf '%s\n' "$out" | sed -n '1p')"
assert_contains "prints the archive path first, carrying the old slug" "$archived" "first"
assert_eq "the new slug is the final line" "$(printf '%s\n' "$out" | tail -1)" "second"
assert_eq "exactly two lines - the archive path, then the slug" \
  "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"
assert_eq "the old flow's state is archived under .orchestrator/archive/" \
  "$([ -f "$archived/state.json" ] && echo present || echo gone)" "present"
assert_eq "the archived state still carries the old slug" \
  "$(jq -r .slug "$archived/state.json")" "first"
assert_eq "the new flow's state reflects the new slug" "$("$ORCH" state get slug)" "second"
assert_eq "the new flow starts at the spec phase, not done" "$("$ORCH" state get phase)" "spec"

# #622: init's archive of a done flow refuses the same way archive does.
fresh_flow first
complete_plan_handoff "$("$ORCH" handoff path spec)"
state_fixture phase "done"
git checkout -q -b orch/1-first
top="$(git rev-parse --show-toplevel)"
"$ORCH" ticket-worktree add 6 >/dev/null
out="$("$ORCH" init second 2>&1)"; st=$?
assert_status "init over a done flow refuses while a ticket worktree exists" "$st" 1
assert_contains "naming it" "$out" "$top/.orchestrator/worktrees/t6"
assert_contains "with ticket-worktree remove as the remedy" "$out" "ticket-worktree remove"
assert_eq "the done flow is left in place" "$("$ORCH" state get slug)" "first"
assert_eq "nothing is archived" \
  "$([ -e .orchestrator/archive ] && echo present || echo absent)" "absent"
"$ORCH" ticket-worktree remove 6

healthy_repo
out="$("$ORCH" init nothing-to-archive)"
assert_eq "with no prior flow, stdout is still just the slug" "$out" "nothing-to-archive"

fresh_flow stale
state_fixture phase implement
out="$("$ORCH" init other 2>&1)"; st=$?
assert_status "an implement-phase flow still refuses with exit 3, same as spec" "$st" 3
assert_contains "names the phase" "$out" "phase: implement"
assert_contains "same message, unchanged" "$out" "One flow at a time"

state_fixture phase review
out="$("$ORCH" init other 2>&1)"; st=$?
assert_status "a review-phase flow refuses with exit 3 too" "$st" 3
assert_contains "naming the review phase" "$out" "phase: review"
assert_eq "the active flow is left in place" "$("$ORCH" state get slug)" "stale"

fresh_flow willfail
fake_github
state_fixture phase "done"
out="$("$ORCH" init nope --issue 99 2>&1)"; st=$?
assert_status "a bad --issue adoption over a done flow refuses" "$st" 1
assert_contains "names the issue number" "$out" "99"
assert_eq "the done flow is left untouched, not archived" \
  "$("$ORCH" state get slug)" "willfail"
assert_eq "and still reports done, re-runnable" "$("$ORCH" state get phase)" "done"

# A good --issue adoption over a done flow is the counterpart to the bad one
# just above: validation still runs first, but this time it passes, so the
# done flow must be archived exactly as the no-`--issue` case archives it,
# and the new flow's state must carry the newly adopted issue rather than
# null or the old flow's own issue.
healthy_repo
fake_issue 7 open ready-for-agent
fake_issue 42 open ready-for-agent
"$ORCH" init willsucceed --issue 7 >/dev/null
state_fixture phase "done"
out="$("$ORCH" init second --issue 42)"; st=$?
assert_status "a valid --issue adoption over a done flow succeeds" "$st" 0
archived="$(printf '%s\n' "$out" | sed -n '1p')"
assert_contains "prints the archive path first, carrying the old slug" "$archived" "willsucceed"
assert_eq "the new slug is the final line" "$(printf '%s\n' "$out" | tail -1)" "second"
assert_eq "exactly two lines - the archive path, then the slug" \
  "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"
assert_eq "the old flow's state is archived under .orchestrator/archive/" \
  "$([ -f "$archived/state.json" ] && echo present || echo gone)" "present"
assert_eq "the archived state still carries the old slug" \
  "$(jq -r .slug "$archived/state.json")" "willsucceed"
assert_eq "the new flow's state records the newly adopted issue, not the old one" \
  "$("$ORCH" state get issue)" "42"
restore_suite_env

# --- doctor -----------------------------------------------------------------
# The two commands doctor replaces both returned success on the failures that
# actually end flows, so what these assert is the *severity* of each condition,
# not just that it got a mention.
echo
echo "doctor"
healthy_repo
doctor_github

out="$("$ORCH" doctor --nonsense 2>&1)"; st=$?
assert_status "rejects an unknown flag" "$st" 1
assert_contains "names the flag it rejected" "$out" "--nonsense"

out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "passes a healthy repo" "$st" 0
assert_contains "keeps the ok-line format of the commands it replaces" "$out" "ok    git present"
assert_contains "opens with a bare group header" "$out" "tools"
assert_contains "summarises severities on the last line" \
  "$(printf '%s\n' "$out" | tail -1)" "0 FAIL"

# jq gone is the awkward case: every other part of orch.sh needs it, so the one
# message the user needs most is the one that cannot be printed the usual way.
if on_windows_bash; then
  skip_no_jq "fails when jq is missing"
  skip_no_jq "names jq rather than dying mid-report"
  skip_no_jq "still reaches the summary line without jq"
else
  out="$(PATH="$nojq_path" "$ORCH" doctor --env 2>&1)"; st=$?
  assert_status "fails when jq is missing" "$st" 1
  assert_contains "names jq rather than dying mid-report" "$out" "jq"
  assert_contains "still reaches the summary line without jq" "$out" " FAIL"
fi

# Severity is the behaviour under test, not the wording: "GitHub said no" must
# FAIL and "GitHub could not tell us" must only warn. Written backwards, doctor
# either blocks every flow run away from a good network or waves through the two
# failures it exists to catch, and both look plausible in a passing test suite.
# No healthy_repo() here: nothing above this point wrote to the repo (doctor
# itself never mutates, and the jq-missing checks only scoped PATH to a
# subshell), so the fixture from the top of the section is still clean.
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when a documented label is missing from the repo" "$st" 1
assert_contains "names the missing label with its backticks stripped" "$out" "ready-for-agent"
assert_contains "gives the command that creates it" "$out" 'gh label create "ready-for-agent"'
assert_contains "indents the remedy under its FAIL by six spaces" \
  "$out" "$(printf '\n      gh label create')"
assert_eq "strips the backticks the doc writes labels in" \
  "$(printf '%s\n' "$out" | grep -c '`')" "0"
assert_contains "counts one FAIL and no warns" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 1 FAIL"

# Still the fixture from the top of the section - nothing since has written
# anything besides the labels doc this call is about to overwrite anyway.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning |' \
        '| -------------------------- | -------------------- | ------- |' \
        '| `needs-triage`             | `needs triage`       | Look    |' >docs/agents/triage-labels.md
fake_label_names 'needs triage'
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a label with a space in it is one label, not two" "$st" 0
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "quotes a multi-word label in the remedy" "$out" 'gh label create "needs triage"'

# GitHub answered the auth probe and then would not answer this one: an absent
# answer, not a "no", so it warns.
healthy_repo
doctor_github
fake_fail adapter_labels
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unlistable label set does not block the flow" "$st" 0
assert_contains "says the labels could not be listed" "$out" "could not be listed"

# The repo the healthy_repo() call before the labels check built is still
# clean here; only its failing label listing is undone.
fake_unfail
fake_offline
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "does not fail merely because GitHub is unreachable" "$st" 0
assert_contains "collapses the checks that needed GitHub into one line" \
  "$out" "checks skipped: GitHub is not reachable"
assert_eq "emits one skip line, not one per skipped check" \
  "$(printf '%s\n' "$out" | grep -c 'skipped:')" "1"
# The skip lines are a group like any other, so they carry a header and a blank
# line rather than trailing loose off the end of the last one.
assert_contains "puts the skipped group under a bare header" \
  "$out" "$(printf '\n\nskipped\nwarn  ')"

fake_online
fake_noauth
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when gh is not authenticated" "$st" 1
assert_contains "gives the login command" "$out" "gh auth login"
assert_contains "skips the checks that depended on the answer" "$out" "skipped: not authenticated"
fake_online

fake_default_branch ''
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unresolved default branch does not block the flow" "$st" 0
assert_contains "warns that the default branch came from a fallback" "$out" "default branch"

# GitHub's answer is validated as default_branch validates it (#485): a tool
# manager's banner around the name is no branch name, so doctor falls back as
# default_branch does rather than reporting the banner as the branch.
fake_default_branch "$(printf 'mise ~/.config/mise/config.toml tools: gh@2.102.0\nmain\n')"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a polluted default branch does not block the flow" "$st" 0
assert_contains "warns the default branch was not resolved from GitHub" \
  "$out" "warn  default branch not resolved from GitHub"
assert_not_contains "and never reports the banner as the branch" "$out" "mise"
fake_default_branch main

# doctor reports the repo the orchestrator works on (#520): resolved locally,
# with its source, and never gh's own default, which in a fork is the upstream.
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "the repo line names the resolved repo and its source" \
  "$out" "ok    repo: acme/widgets (origin)"
out="$(GH_REPO=fork/widgets "$ORCH" doctor --env 2>&1)"
assert_contains "the repo line names GH_REPO when the caller set it" \
  "$out" "ok    repo: fork/widgets (GH_REPO)"
# Which repo doctor's operations are pinned to, and the repo view's
# positional repo, are the operations' own, pinned in "gh adapter contract".
fake_local_default upstream/widgets
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a differing gh default repo does not block the flow" "$st" 0
assert_contains "warns naming gh's default repo and the one in use" "$out" \
  "warn  gh's default repo is upstream/widgets; the orchestrator uses acme/widgets"
fake_local_default acme/widgets
out="$("$ORCH" doctor --env 2>&1)"
assert_not_contains "a matching gh default repo raises no warn" "$out" "gh's default repo"
# gh repo set-default --view prints a bare owner/name even for a default on a
# host other than github.com (gh 2.102.0), so the same repo there is no warn.
out="$(GH_REPO=ghe.example.com/acme/widgets "$ORCH" doctor --env 2>&1)"
assert_not_contains "a matching gh default repo on another host raises no warn" "$out" "gh's default repo"
fake_local_default ""
# No repo at all: a FAIL with the remedy, and doctor carries on past it - the
# later GitHub checks counted on the skip line, no gh call made at all. The
# real adapter runs here, over a fixture gh that logs every call it gets.
savepath="$PATH"; gh_fixture; PATH="$savepath"
out="$(cd "$(mktemp -d)" && cp -R "$OLDPWD/." . && git remote remove origin \
  && PATH="$GH_FIXTURE/bin:$PATH" ORCH_GH_ADAPTER='' "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "no resolvable repo fails doctor" "$st" 1
assert_contains "names the missing repo as a FAIL" "$out" "FAIL  no GitHub repo to work on"
assert_contains "gives the GH_REPO remedy" "$out" "GH_REPO=<owner>/<repo>"
assert_contains "counts the later GitHub checks on the skip line" \
  "$out" "GitHub checks skipped: no GitHub repo to work on"
assert_contains "still reaches the summary line" "$(printf '%s\n' "$out" | tail -1)" " FAIL"
assert_eq "makes no gh call without a repo to pin it to" "$(cat "$GH_FIXTURE/env.log" 2>/dev/null | wc -l | tr -d ' ')" "0"
unset GH_FIXTURE

# The plugin depends on no other plugin (ADR-0028): doctor says nothing of
# mattpocock-skills, and the old override pointing nowhere changes nothing.
# No healthy_repo() needed: the checks above put back each GitHub condition
# they seeded, so the repo is still clean.
out="$("$ORCH" doctor --env 2>&1)"; st=$?
out_mp="$(ORCHESTRATOR_MATTPOCOCK_ROOT=/nonexistent "$ORCH" doctor --env 2>&1)"; st_mp=$?
assert_eq "the old mattpocock override changes no exit status" "$st_mp" "$st"
assert_eq "nor any line of the output" "$out_mp" "$out"
assert_not_contains "says nothing of mattpocock-skills" "$out" "mattpocock"

# Setup is optional: a repo with no docs/agents/ at all is a working repo, its
# labels the five canonical names.
canonical_labels="$(printf '%s\n' needs-triage needs-info ready-for-agent ready-for-human wontfix)"
healthy_repo
doctor_github
rm -rf docs/agents
# shellcheck disable=SC2086 # one label per word
fake_label_names $canonical_labels
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a repo with no docs/agents/ passes" "$st" 0
assert_not_contains "and names no mattpocock" "$out" "mattpocock"
assert_not_contains "nor its setup skill" "$out" "setup-matt-pocock-skills"
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "with no labels doc, the canonical names are checked on the repo" "$st" 1
for l in needs-triage needs-info ready-for-agent ready-for-human wontfix; do
  assert_contains "and a missing $l is named" "$out" "gh label create \"$l\""
done
fake_label_names needs-triage
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a repo missing only some canonical labels fails" "$st" 1
assert_not_contains "and does not name the ones it has" "$out" 'gh label create "needs-triage"'

# A present doc still wins: a renamed label is checked under its local name.
healthy_repo
doctor_github
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `ready-for-agent`          | `agent go`           | AFK-ready   |' >docs/agents/triage-labels.md
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a renamed-label doc is still checked" "$st" 1
assert_contains "under the repo's own label name" "$out" 'gh label create "agent go"'
assert_not_contains "not the canonical one" "$out" 'gh label create "ready-for-agent"'

# Labels are parsed from the doc rather than hardcoded, so the parser is what
# decides whether doctor is right in a repo that customised its vocabulary.
# A narrower table would hand $3 whatever column sits last, so doctor would go
# demanding that the repo create labels named after the Meaning text. Parsing to
# nothing is the honest answer; inventing one is the worst thing a diagnostic
# can do.
# The width belongs to one table, and a doc may hold more than one. A second,
# narrower table's *header* row arrives a line before the separator that would
# correct the width, so without a reset at the end of the block that heading
# gets read out as a label and demanded of the repo.
# This healthy_repo() does earn its keep: the renamed-label check above left a
# one-row doc behind, and every labels-doc variant below needs a clean repo so
# the only FAIL it can produce is the one the table shape under test causes.
healthy_repo
doctor_github
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
        '' '## Glossary' '' \
        '| Term | Definition |' \
        '| ---- | ---------- |' \
        '| flow | a run       |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "reads only the labels table, not every table in the doc" \
  "$out" "1 triage labels"
assert_eq "does not read a heading out of a second, narrower table" \
  "$(printf '%s\n' "$out" | grep -c 'Definition')" "0"
assert_status "and does not demand the repo create it" "$st" 0

# The width comes from the separator row, because only there is an empty last
# field unambiguous. On a data row it is equally an empty last *cell*, and a row
# that drops its trailing pipe *and* leaves Meaning blank looks exactly like a
# two-column row - so reading the width off that row costs a real label.
# No healthy_repo() here or in the labels-doc variants below: each one only
# ever dirtied the labels doc, and the writeln right after overwrites it
# again before anything reads it, so re-running the whole fixture just to
# replace one file it's about to replace anyway would be pure waste.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning' \
        '| -------------------------- | -------------------- | -------' \
        '| `needs-triage`             | `needs-triage`       |' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an empty last cell does not cost the row its label" "$st" 0
assert_contains "reads both labels, not just the one with a Meaning" "$out" "2 triage labels"

# Markdown lets a row drop its trailing pipe, and the width is read off the
# separator row precisely so that such a doc still parses.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning' \
        '| -------------------------- | -------------------- | -------' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a table without its trailing pipes still parses" "$st" 0
assert_contains "reads both labels out of it" "$out" "2 triage labels"

writeln '# Triage Labels' '' \
        '| Label          | Meaning     |' \
        '| -------------- | ----------- |' \
        '| `needs-triage` | Evaluate it |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails on a table that is not the documented shape" "$st" 1
assert_eq "does not read a label out of some other column" \
  "$(printf '%s\n' "$out" | grep -c 'Evaluate it')" "0"
assert_contains "says to fix the table or delete it" "$out" "delete it to use the canonical names"

# The width rule now hinges entirely on recognising the separator row, and these
# are the two ways that recognition goes wrong: a separator dressed with
# alignment colons, and a doc that never has one.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| :------------------------- | :------------------: | ----------: |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready   |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an alignment-colon separator is still a separator" "$st" 0
assert_contains "reads the labels under it" "$out" "2 triage labels"

writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a table with no separator row parses to nothing" "$st" 1
assert_eq "reads no label out of a table it never confirmed the width of" \
  "$(printf '%s\n' "$out" | grep -c 'needs-triage')" "0"
assert_contains "says to fix the table or delete it" "$out" "delete it to use the canonical names"

writeln '# Triage Labels' '' 'This repo does not use a table.' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when the labels doc parses to no labels" "$st" 1
assert_contains "says to fix the table or delete it" "$out" "delete it to use the canonical names"

rm docs/agents/triage-labels.md
# shellcheck disable=SC2086 # one label per word
fake_label_names $canonical_labels
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "passes when the labels doc is absent entirely" "$st" 0
assert_not_contains "and does not call the doc missing" "$out" "triage-labels.md is missing"

# A label list long enough to fill the page is a list that may be cut off, so
# naming labels as missing from it would be a FAIL derived from not knowing.
# This healthy_repo() is load-bearing: the doc was just deleted above, and
# every check from here through the exclude-line one below needs the default
# labels doc back, with nothing else in between rewriting it.
healthy_repo
doctor_github
# shellcheck disable=SC2046 # one label per word
fake_label_names $(seq 1 1000)
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a label list that filled the page does not FAIL" "$st" 0
assert_contains "names the labels it cannot vouch for" "$out" "cannot confirm:"
assert_contains "names them individually" "$out" "needs-triage, ready-for-agent"

# ...but a page that filled up and still held every documented label answered
# the question. The caveat qualifies a negative; there is no negative here.
# The repo is still the one healthy_repo() built two checks up.
# shellcheck disable=SC2046 # one label per word
fake_label_names needs-triage ready-for-agent $(seq 1 1000)
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a full page that held every label is still a pass" "$st" 0
assert_contains "does not hedge an answer it actually has" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 0 FAIL"

out="$("$ORCH" doctor --env 2>&1)"
assert_contains "counts only the documented labels, not the header row" \
  "$out" "2 triage labels"

# Escaped pipes (issue #5): markdown's `\|` inside a cell is a literal `|`,
# never a column separator. Without that, an escaped cell shifts every column
# after it for that row - the label column reads a fragment of the escaped
# cell instead of the real label, and the real label is lost entirely.
# A repo with no labels makes every documented label print a "gh label
# create" remedy, which is the easiest window onto exactly what triage_labels
# parsed each row down to.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `needs\|triage`       | Evaluate it |' >docs/agents/triage-labels.md
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "an escaped pipe inside the label column becomes a literal pipe" \
  "$out" 'gh label create "needs|triage"'
assert_eq "does not truncate the label at the escaped pipe" \
  "$(printf '%s\n' "$out" | grep -c 'gh label create "needs"')" "0"

# The ticket's own repro: the escape sits in the *other* column (the
# mattpocock-skills name), yet it is column 3 - the label doctor actually
# reads - that comes out corrupted, because the escaped cell shifted it.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `a\|b`                     | `needs-triage`        | do it       |' >docs/agents/triage-labels.md
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "an escaped pipe in the mattpocock-name column does not shift the label column" \
  "$out" 'gh label create "needs-triage"'
assert_eq "does not invent a label out of the shifted fragment" \
  "$(printf '%s\n' "$out" | grep -c 'gh label create "b"')" "0"

# The Meaning column sits after the one doctor reads, so an escape there is
# the least likely to leak - which is exactly why it earns a test locking
# that in, rather than trusting it stays that way by accident.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `needs-triage`        | Look \|out  |' >docs/agents/triage-labels.md
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "an escaped pipe in the meaning column does not corrupt the label column" \
  "$out" 'gh label create "needs-triage"'

# triage_label_for shares the same row-splitting bug: an escape in the
# repo's local label corrupts the very value validate_adopted_issue compares
# against a real issue's labels.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `ready-for-agent`          | `ready\|for-agent`    | AFK-ready   |' >docs/agents/triage-labels.md
fake_issue 7 open needs-triage
out="$("$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "refuses adoption when the escape-restored label is missing" "$st" 1
assert_contains "names the label with its escaped pipe restored, not truncated" \
  "$out" "ready|for-agent"
fake_issue 7 open 'ready|for-agent'
out="$("$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "adopts once the issue carries the escape-restored label" "$st" 0

# Restores the canonical labels doc and a clean, flow-free repo: the escaped-
# pipe block above both rewrote the doc away from its default shape and left
# an adopted flow active, and the sub-issues section right after this expects
# the plain "fully healthy repo" the earlier healthy_repo() call above had
# left before this block started borrowing it.
healthy_repo
doctor_github

# Issue #39: triage_label_for lacks triage_labels' table-boundary/column-count
# guard, so a second, differently-shaped table elsewhere in the doc can shadow
# the real answer. Placed *before* the real table, with a row that resolves to
# the same role, so a reader with no boundary awareness matches it first and
# never reaches the real table at all.
writeln '# Other Reference' '' \
        '| Role | Other |' \
        '| ready-for-agent | wrong-label |' \
        '' \
        '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| --------------------------- | --------------------- | ----------- |' \
        '| `needs-triage`              | `needs-triage`         | Evaluate it |' \
        '| `ready-for-agent`           | `ready-for-agent`      | AFK-ready   |' >docs/agents/triage-labels.md

out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "list-labels: an unrelated table before the real one still passes" "$st" 0
assert_contains "still reads exactly the two documented labels" "$out" "2 triage labels"
assert_eq "does not read the unrelated table's value in as a label" \
  "$(printf '%s\n' "$out" | grep -c 'wrong-label')" "0"

fake_issue 7 open wrong-label
out="$("$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "label-for ignores the unrelated table's row rather than matching it" "$st" 1
assert_contains "resolves the role against the real table's label, not the one before it" \
  "$out" "ready-for-agent"

fake_issue 7 open ready-for-agent
out="$("$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "adopts once the issue carries the real table's label" "$st" 0

# Reset again: the successful adopt above just left a flow active, and the
# sub-issues checks right after this expect the plain flow-free healthy repo.
healthy_repo
doctor_github

# Sub-issues carry no enable/disable setting of their own, so the only
# reliable signal is asking the endpoint against an issue that exists and
# reading whether it answers or 404s. doctor_github's issue answers, and
# the "fully healthy repo" assertion at the end of this section already
# depends on that, so this is really confirming the ok line it produces.
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "sub-issues supported: still a healthy pass" "$st" 0
assert_contains "reports sub-issues as supported" "$out" "ok    sub-issues supported"

# The endpoint 404ing (or otherwise refusing) reads as "not supported" -
# advisory, so a warn, never a FAIL: the real gate is ticket_publish's own
# verify-then-die, not this probe.
fake_no_sub_issues
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "unsupported sub-issues does not block the flow" "$st" 0
assert_contains "warns rather than fails when sub-issues are unsupported" \
  "$out" "warn  sub-issues do not appear to be supported"
assert_contains "explains the consequence rather than leaving it silent" \
  "$out" "ticket publish will fail"

# A repo with no issues at all has nothing to probe against - still a warn,
# not a FAIL, and a distinct message from the unsupported case above.
fake_github
fake_label_names needs-triage ready-for-agent
fake_default_branch main
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "no issue to probe against does not block the flow" "$st" 0
assert_contains "says the probe could not run rather than guessing" \
  "$out" "sub-issues support could not be probed"

# Gated like every other GitHub-backed check: unreachable collapses into the
# shared skip line rather than adding a check-specific one of its own.
doctor_github
fake_offline
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "GitHub unreachable does not block the flow either" "$st" 0
assert_eq "still emits exactly one skip line, not a second for this check" \
  "$(printf '%s\n' "$out" | grep -c 'skipped:')" "1"

fake_online

# Still the fixture healthy_repo() built for the label-list checks above -
# nothing since has touched anything but $out - so truncating the exclude
# file here is the only new mutation, and it's this test's own setup, not
# leftover state to clean up first.
: >.git/info/exclude
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a missing git exclude line warns without blocking" "$st" 0
assert_contains "counts one warn and no FAILs" \
  "$(printf '%s\n' "$out" | tail -1)" "1 warn, 0 FAIL"
assert_contains "gives a command that adds the exclude line" "$out" "info/exclude"
assert_contains "one warning names both missing lines" "$out" "warn  .orchestrator/, .scratch/ not git-excluded"
remedy="$(printf '%s\n' "$out" | grep -A1 'not git-excluded' | sed -n '2s/^ *//p')"
eval "$remedy"
assert_eq "the remedy for both writes .orchestrator/ once" "$(exclude_count .orchestrator/)" "1"
assert_eq "the remedy for both writes .scratch/ once" "$(exclude_count .scratch/)" "1"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "running the remedy clears the warning" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 0 FAIL"

printf '%s\n' ".orchestrator/" >.git/info/exclude
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a missing .scratch/ line alone warns without blocking" "$st" 0
assert_contains "and counts as one warn" "$(printf '%s\n' "$out" | tail -1)" "1 warn, 0 FAIL"
assert_contains "the warning names .scratch/ alone" "$out" "warn  .scratch/ not git-excluded"
remedy="$(printf '%s\n' "$out" | grep -A1 'not git-excluded' | sed -n '2s/^ *//p')"
assert_contains "the remedy names .scratch/" "$remedy" ".scratch/"
assert_not_contains "the remedy leaves .orchestrator/ alone" "$remedy" ".orchestrator/"
eval "$remedy"
assert_eq "the remedy appends .scratch/" "$(exclude_count .scratch/)" "1"
assert_eq "without repeating .orchestrator/" "$(exclude_count .orchestrator/)" "1"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "and clears the warning" "$(printf '%s\n' "$out" | tail -1)" "0 warn, 0 FAIL"
: >.git/info/exclude

# The exclude line is still truncated from the check above, so this one does
# need a real reset before layering CLAUDE_PLUGIN_ROOT's own warning on top.
healthy_repo
doctor_github
out="$(env -u CLAUDE_PLUGIN_ROOT CLAUDECODE=1 "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "running orch.sh by hand is not a broken install" "$st" 0
assert_contains "warns about the unset plugin root" "$out" "CLAUDE_PLUGIN_ROOT"
restore_suite_env

# --- doctor: host (#128) ---
# Reduced enforcement has to be visible: doctor says which host it believes it
# is under and what that host cannot do, in the words of the capabilities
# reference - so the two cannot tell a user different stories.
healthy_repo
doctor_github
out="$(env -u CLAUDE_PLUGIN_ROOT CLAUDECODE=1 "$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "detects Claude Code from CLAUDECODE" "$out" "host: Claude Code"
assert_eq "Claude Code lacks no capability" "$(printf '%s\n' "$out" | grep -c 'lacks')" "0"
assert_contains "the plugin root check still warns when Claude Code left it unset" \
  "$out" "warn  CLAUDE_PLUGIN_ROOT"

out="$(env -u CLAUDE_PLUGIN_ROOT JUNIE_EXTENSION_ROOT="$PWD" "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "Junie's missing capabilities warn, never fail" "$st" 0
assert_contains "detects Junie CLI from JUNIE_EXTENSION_ROOT" "$out" "host: Junie CLI"
# The edit guard does not arm on Junie (ADR-0025): planning there is a nudge,
# backstopped at flow start, so the row is a Fallback - a gap, not Unverified.
assert_contains "names the edit guard as lacking on Junie" \
  "$(printf '%s\n' "$out" | grep -o 'lacks: [^;]*')" "Arm the edit guard"
assert_eq "does not call the edit guard unverified on Junie" \
  "$(printf '%s\n' "$out" | grep -o 'unverified: .*' | grep -c 'Arm the edit guard')" "0"
# Junie's UserPromptSubmit hook now delivers the planning message (#202).
assert_eq "does not claim Junie lacks planning-time context" \
  "$(printf '%s\n' "$out" | grep -c 'Inject context at planning time')" "0"
# Junie CLI loads the plugin's agents/ (#200), but its capability filter hides
# them, so a native start usually fails: the cell is a Fallback, not
# Unverified (#203).
assert_contains "names the fresh subagent Junie cannot use" \
  "$(printf '%s\n' "$out" | grep -o 'lacks: [^;]*')" "Start a fresh subagent"
assert_eq "does not call the fresh subagent unverified on Junie" \
  "$(printf '%s\n' "$out" | grep -o 'unverified: .*' | grep -c 'Start a fresh subagent')" "0"
assert_contains "names the forked subagent Junie cannot start" "$out" "Start a forked subagent"
# Junie cannot start a background subagent, so it builds the frontier one
# ticket at a time (ADR-0036): a gap, not Unverified.
assert_contains "names the background subagent Junie cannot start" \
  "$(printf '%s\n' "$out" | grep -o 'lacks: [^;]*')" "Start a background subagent"
# A human on Junie still starts a skill with /<name>; only the model lacks it.
assert_contains "names only mid-step skill invocation as missing" "$out" "Invoke a skill from a step"
assert_contains "points at the reference for the fallbacks" "$out" "docs/host-capabilities.md"
assert_eq "does not list what Junie can do" \
  "$(printf '%s\n' "$out" | grep -c 'Ask a multiple-choice question')" "0"
# An unconfirmed cell is not a known gap: doctor must not state it as one.
assert_contains "names what is unverified on Junie" \
  "$(printf '%s\n' "$out" | grep -o 'unverified: .*')" "Run a plugin command"
assert_eq "does not claim Junie lacks what is only unverified" \
  "$(printf '%s\n' "$out" | grep -o 'lacks: [^;]*' | grep -c 'Run a plugin command')" "0"
assert_contains "an unset plugin root is expected on Junie, not a warning" \
  "$out" "ok    CLAUDE_PLUGIN_ROOT"

# Junie CLI's agent shell has no JUNIE_EXTENSION_ROOT; JUNIE_SHIM_PATH is what
# it exports there (orch-bench run j1).
out="$(env -u CLAUDE_PLUGIN_ROOT JUNIE_SHIM_PATH="$PWD" "$ORCH" doctor --env 2>&1)"
assert_contains "detects Junie CLI from JUNIE_SHIM_PATH" "$out" "host: Junie CLI"
# A Junie started from inside a Claude Code terminal inherits CLAUDECODE.
out="$(env -u CLAUDE_PLUGIN_ROOT JUNIE_SHIM_PATH="$PWD" CLAUDECODE=1 "$ORCH" doctor --env 2>&1)"
assert_contains "JUNIE_SHIM_PATH outranks CLAUDECODE" "$out" "host: Junie CLI"

out="$(ORCHESTRATOR_HOST=junie "$ORCH" doctor --env 2>&1)"
assert_contains "ORCHESTRATOR_HOST outranks the Claude signals" "$out" "host: Junie"
out="$(ORCHESTRATOR_HOST=vim "$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "names an ORCHESTRATOR_HOST it does not know" "$out" "ORCHESTRATOR_HOST=vim"

out="$(env -u CLAUDE_PLUGIN_ROOT "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "no detectable host is not a broken install" "$st" 0
assert_contains "says the host was not detected" "$out" "host not detected"
assert_contains "and how to name it" "$out" "export ORCHESTRATOR_HOST="

# A skills-only install copies the skills without scripts/, so the relative
# path every skill resolves orch.sh by leads nowhere. doctor runs from an
# orch.sh, so what it can see is such a copy sitting in a user skill store.
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "reports the orch.sh it runs from" "$out" "ok    orch.sh:"
h="$HOME"
mkdir -p "$h/.agents/skills/orch-flow"
touch "$h/.agents/skills/orch-flow/SKILL.md"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "reports a skills-only copy with no orch.sh" "$out" "orch.sh missing"
# shellcheck disable=SC2088 # the literal ~ path doctor prints, not a path to expand
assert_contains "names the skills CLI copy" "$out" "~/.agents/skills: orch-flow"
# The fix names only the detected host's install.
assert_contains "names the full-plugin install for Claude Code" "$out" "/plugin install orchestrator@orchestrator"
assert_eq "and not Junie's, under Claude Code" \
  "$(printf '%s\n' "$out" | grep -c 'as a Junie extension')" "0"
out="$(env -u CLAUDE_PLUGIN_ROOT JUNIE_EXTENSION_ROOT="$PWD" "$ORCH" doctor --env 2>&1)"
assert_contains "names the full-plugin install for Junie" "$out" "maj0rpain/orchestrator as a Junie extension"
assert_contains "and marks it unverified" "$out" "as a Junie extension (unverified)"
assert_eq "and not Claude Code's, under Junie" \
  "$(printf '%s\n' "$out" | grep -c '/plugin install orchestrator@orchestrator')" "0"
out="$(env -u CLAUDE_PLUGIN_ROOT "$ORCH" doctor --env 2>&1)"
assert_contains "names every host's install when none is detected" "$out" "/plugin install orchestrator@orchestrator"
assert_contains "including Junie's" "$out" "maj0rpain/orchestrator as a Junie extension"
# ~/.junie/skills is not a verified Junie location (#121: verified facts only).
rm -rf "$h/.agents/skills/orch-flow"
mkdir -p "$h/.junie/skills/orch-review"
touch "$h/.junie/skills/orch-review/SKILL.md"
out="$("$ORCH" doctor --env 2>&1)"
assert_eq "does not scan the unverified ~/.junie/skills" \
  "$(printf '%s\n' "$out" | grep -c 'orch.sh missing')" "0"
rm -rf "$h/.junie/skills/orch-review"

# ~/.claude/skills is Claude Code's user-level store: a stray copy there shows
# up beside the plugin's own orchestrator:orch-flow as a plain orch-flow.
mkdir -p "$h/.claude/skills/orch-flow"
touch "$h/.claude/skills/orch-flow/SKILL.md"
out="$("$ORCH" doctor --env 2>&1)"
# shellcheck disable=SC2088 # the literal ~ path doctor prints, not a path to expand
assert_contains "names a stray copy in Claude Code's user skill store" "$out" "~/.claude/skills: orch-flow"
# Stray copies in both stores: one warning per store, one remedy.
mkdir -p "$h/.agents/skills/orch-review"
touch "$h/.agents/skills/orch-review/SKILL.md"
out="$("$ORCH" doctor --env 2>&1)"
# shellcheck disable=SC2088 # the literal ~ path doctor prints, not a path to expand
assert_contains "names the skills CLI store's copy too" "$out" "~/.agents/skills: orch-review"
assert_eq "warns once per store that holds a copy" \
  "$(printf '%s\n' "$out" | grep -c 'orch.sh missing')" "2"
assert_eq "and gives the remedy once" \
  "$(printf '%s\n' "$out" | grep -c '/plugin install orchestrator@orchestrator')" "1"
rm -rf "$h/.claude/skills/orch-flow"
# The skills CLI installs into ~/.agents/skills and links Claude Code's store
# to it: ~/.claude/skills/<skill> -> ../../.agents/skills/<skill>. One copy,
# one report.
ln -s ../../.agents/skills/orch-review "$h/.claude/skills/orch-review"
out="$("$ORCH" doctor --env 2>&1)"
assert_eq "reports a copy reached by a link only once" \
  "$(printf '%s\n' "$out" | grep -c 'orch.sh missing')" "1"
# shellcheck disable=SC2088 # the literal ~ path doctor prints, not a path to expand
assert_contains "under the store that holds it" "$out" "~/.agents/skills: orch-review"
rm -f "$h/.claude/skills/orch-review"
rm -rf "$h/.agents/skills/orch-review"
# A link into a full checkout has orch.sh beside the real folder.
full="$(mktemp -d)"
mkdir -p "$full/skills/orch-flow" "$full/scripts"
touch "$full/skills/orch-flow/SKILL.md" "$full/scripts/orch.sh"
ln -s "$full/skills/orch-flow" "$h/.claude/skills/orch-flow"
out="$("$ORCH" doctor --env 2>&1)"
assert_eq "does not report a link into a full checkout" \
  "$(printf '%s\n' "$out" | grep -c 'orch.sh missing')" "0"
assert_contains "and says orch.sh is fine" "$out" "ok    orch.sh:"
rm -f "$h/.claude/skills/orch-flow"; rm -rf "$full"
# ~/.claude/skills exists but holds no orch-* skill: ok, as before.
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "an existing store with no copies is ok" "$out" "ok    orch.sh:"

# env -u above was scoped to that one command too, so this is still the same
# fully-healthy repo - exactly the state this last check needs to prove out.
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "separates groups with a blank line and a bare header" \
  "$out" "$(printf '\n\nauth & remotes\n')"
assert_contains "a fully healthy repo reports no warns and no FAILs" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 0 FAIL"
# Asserted against the lines actually printed rather than a literal, so adding a
# check to the registry cannot quietly make the count wrong.
assert_eq "the summary's ok count matches the ok lines it printed" \
  "$(printf '%s\n' "$out" | tail -1 | sed 's/ ok,.*//')" \
  "$(printf '%s\n' "$out" | grep -c '^ok    ')"
restore_suite_env

# --- doctor --flow ----------------------------------------------------------
# An empty answer must never read as a healthy one: --flow is asked explicitly
# about a flow, so no flow is a failure there and a plain statement everywhere
# else.
healthy_repo
doctor_github
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "--flow refuses to answer when there is no flow" "$st" 1
assert_contains "says why it cannot answer" "$out" "no active flow"

out="$("$ORCH" doctor 2>&1)"; st=$?
assert_status "bare doctor is safe to run with no flow" "$st" 0
assert_contains "states there is no flow instead of failing" "$out" "ok    no active flow"
assert_contains "bare doctor covers the environment too" "$out" "tools"

"$ORCH" init flowtest >/dev/null
complete_plan_handoff "$("$ORCH" handoff path spec)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a fresh flow is healthy" "$st" 0
assert_contains "reports the phase" "$out" "phase: spec"
# "published" names only one of the two paths an issue can arrive by (orch-to-spec
# publishing vs. adoption at init, docs/adr/0005) - neutral wording here must
# not imply the other path doesn't exist.
assert_contains "reports no issue recorded yet without implying publication is the only path" \
  "$out" "issue: not recorded yet"
assert_eq "--flow leaves the environment alone" \
  "$(printf '%s\n' "$out" | grep -c '^tools$')" "0"
assert_eq "stays quiet about an upstream before the implement phase" \
  "$(printf '%s\n' "$out" | grep -c 'upstream')" "0"

# /orchestrator:next and /orchestrator:status both run this scope every time, and
# a flow with no PR recorded has nothing to ask GitHub about.
# GitHub unreachable shows it: one question would put a skip line in the report.
fake_offline
out="$("$ORCH" doctor --flow 2>&1)"
assert_not_contains "a flow with no PR asks GitHub nothing" "$out" "skipped"
fake_online

# One unparseable file is one problem. Four checks each reading it again would
# print jq's parse error mid-report and then four ok lines that are not true.
statebak="$(mktemp)"
cp .orchestrator/state.json "$statebak"
printf '%s' '{not json' >.orchestrator/state.json
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when state.json does not parse" "$st" 1
assert_contains "names the file that will not parse" "$out" "not valid JSON"
assert_eq "reports it once rather than once per check" \
  "$(printf '%s\n' "$out" | grep -c '^FAIL')" "1"
assert_eq "claims nothing it could not read" \
  "$(printf '%s\n' "$out" | grep -c '^ok    ')" "0"
assert_eq "does not leak jq's parse error into the report" \
  "$(printf '%s\n' "$out" | grep -c 'parse error')" "0"
cp "$statebak" .orchestrator/state.json

state_fixture phase nonsense
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "rejects an unknown phase" "$st" 1
assert_contains "names the phase it does not know" "$out" "nonsense"
state_fixture phase spec

state_fixture branch orch/9-gone
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the recorded branch is gone" "$st" 1
assert_contains "names the missing branch" "$out" "orch/9-gone"

git checkout -q -b orch/9-gone
state_fixture phase implement
complete_spec_handoff "$("$ORCH" handoff path implement)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an unpushed branch warns rather than blocking the implement phase" "$st" 0
assert_contains "gives the command that pushes it" "$out" "git push -u origin orch/9-gone"

# branch create forks off origin/<default>, so an unpushed branch already has an
# upstream - just not its own. Accepting any upstream would call a branch nobody
# else can see pushed.
git update-ref refs/remotes/origin/main HEAD
git branch -q --set-upstream-to=origin/main orch/9-gone
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_contains "an upstream pointing at the base branch is still unpushed" \
  "$out" "not on origin yet"

# A handoff with a bare required heading is the failure the next phase would
# experience as running blind, so it has to surface as a FAIL here.
writeln '## Spec issue' '#1' '' '## Seams' '' '## Spec review changelog' 'None.' \
  >"$("$ORCH" handoff path implement)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when a completed phase's handoff has an empty section" "$st" 1
assert_contains "names the handoff" "$out" "02-spec.md"
assert_contains "reports it as empty, not missing" "$out" "empty section"
complete_spec_handoff "$("$ORCH" handoff path implement)"

# check_flow_issue runs unconditionally on state.issue, whichever path put it
# there - adopted at init or published by orch-to-spec - and mirrors check_flow_pr's
# open/closed/unreadable shape.
"$ORCH" state set issue 11
fake_issue 11 open ready-for-agent
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an open issue is healthy" "$st" 0
assert_contains "reports the open issue" "$out" "issue #11 open"

fake_issue 11 closed ready-for-agent
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the recorded issue has been closed" "$st" 1
assert_contains "names the closed issue" "$out" "issue #11 is closed"
assert_contains "gives the command that reopens it" "$out" "gh issue reopen 11"

fake_fail adapter_issue_state_labels
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the issue cannot be read from GitHub" "$st" 1
assert_contains "names the unreadable issue" "$out" "issue #11 could not be read from GitHub"
assert_contains "gives the command that re-checks it" "$out" "gh issue view 11"

# The ready-for-agent label is a one-time gate at adoption, not an ongoing flow
# invariant (docs/adr/0005) - a maintainer's later triage housekeeping must not
# stop a flow already running against the issue.
fake_unfail
fake_issue 11 open needs-triage
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an issue whose label was removed after adoption is still healthy" "$st" 0
assert_contains "still reports it open" "$out" "issue #11 open"

# issue #13: pr open always writes `Closes #<issue>`, so a merged flow's issue
# is closed as a matter of course - a done flow reporting that as broken was
# doctor misreporting every successfully-finished flow.
complete_implement_handoff "$("$ORCH" handoff path review)"
state_fixture phase "done"
fake_issue 11 closed
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a closed issue is healthy once the flow is done" "$st" 0
assert_contains "reports it closed instead of failing" "$out" "issue #11 closed"

# issue #415: a merged flow stays in done until the next init archives it
# (ADR-0009), and deleting its branch after the merge is routine. Neither the
# local nor the origin branch being gone is a problem then, and a push remedy
# would recreate a branch somebody just deleted on purpose.
assert_done_branch_gone_ok() {
  local label="$1" out="$2"
  assert_contains "$label: branch reports ok" "$out" "ok    branch: "
  assert_contains "$label: upstream reports ok" "$out" "ok    upstream: "
  assert_not_contains "$label: no missing-branch FAIL" "$out" "no longer exists"
  assert_not_contains "$label: no unpushed warning" "$out" "not on origin yet"
  assert_not_contains "$label: no push remedy" "$out" "git push -u origin"
}
state_fixture branch orch/9-merged
out="$("$ORCH" doctor --flow 2>&1)"
assert_done_branch_gone_ok "done, branch gone locally and on origin" "$out"
assert_contains "names the branch as gone after merge" "$out" \
  "branch: orch/9-merged gone - expected after merge"
assert_contains "names no upstream as expected after merge" "$out" \
  "upstream: none - expected after merge"

state_fixture branch orch/9-gone
out="$("$ORCH" doctor --flow 2>&1)"
assert_done_branch_gone_ok "done, local branch kept but origin branch gone" "$out"

git update-ref refs/remotes/origin/orch/9-merged HEAD
state_fixture branch orch/9-merged
out="$("$ORCH" doctor --flow 2>&1)"
assert_done_branch_gone_ok "done, local branch gone but origin branch kept" "$out"

# Outside done, the same states are still what they were: a review flow with
# its branch gone has nothing to build on, and an unpushed one still needs it.
fake_issue 11 open
state_fixture phase review
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a review flow with its branch gone still fails" "$st" 1
assert_contains "still says it no longer exists" "$out" "orch/9-merged no longer exists"
assert_contains "still gives the abort remedy" "$out" "/orchestrator:abort"
git update-ref -d refs/remotes/origin/orch/9-merged

state_fixture branch orch/9-gone
out="$("$ORCH" doctor --flow 2>&1)"
assert_contains "an unpushed review flow still warns" "$out" "not on origin yet"
assert_contains "and still gives the push remedy" "$out" "git push -u origin orch/9-gone"
state_fixture phase implement

state_fixture pr 7
fake_pr 7 closed orch/9-gone main
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the recorded PR has been closed" "$st" 1
assert_contains "names the closed PR" "$out" "#7"
fake_pr 7 merged orch/9-gone main
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a merged PR is not a failure" "$st" 0

fake_offline
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an unreachable GitHub does not fail the flow scope" "$st" 0
assert_contains "skips the PR check with its cause" "$out" "skipped: GitHub is not reachable"
fake_online

# #622: a ticket worktree left over by an interrupted run is a FAIL naming it,
# with ticket-worktree remove as the remedy - but only this checkout's own.
tw_top="$(git rev-parse --show-toplevel)"
out="$("$ORCH" doctor --flow 2>&1)"
assert_not_contains "with no ticket worktree, doctor --flow says nothing of them" "$out" "ticket worktree"
"$ORCH" ticket-worktree add 12 >/dev/null
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a leftover ticket worktree fails doctor --flow" "$st" 1
assert_contains "reports it as a FAIL naming it" "$out" \
  "FAIL  ticket worktree $tw_top/.orchestrator/worktrees/t12 is left over"
assert_contains "with ticket-worktree remove <n> as the remedy" "$out" "orch.sh ticket-worktree remove 12"
"$ORCH" ticket-worktree remove 12
tw_linked="$(mktemp -d)/linked"
git worktree add -q -b orch/9-other "$tw_linked"
(cd "$tw_linked" && "$ORCH" ticket-worktree add 13 >/dev/null)
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "another checkout's ticket worktree does not fail doctor --flow" "$st" 0
assert_not_contains "nor is it reported" "$out" "t13"
(cd "$tw_linked" && "$ORCH" ticket-worktree remove 13)
git worktree remove "$tw_linked"
git branch -q -D orch/9-other

# #721: every phase commits its own work before ending, so a change outside the
# planning allowlist at a phase boundary is a bug in the phase that left it -
# caught by doctor --flow, at the top of every /orchestrator:next.
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a clean tree passes doctor --flow" "$st" 0
assert_not_contains "a clean tree reports nothing about the working tree" "$out" "planning allowlist"
mkdir -p lib
printf 'x\n' >lib/left-behind.sh
printf 'x\n' >stray.txt
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "changes outside the planning allowlist fail doctor --flow" "$st" 1
assert_contains "the FAIL lists the paths outside the allowlist" "$out" \
  "FAIL  the working tree has changes outside the planning allowlist: lib/left-behind.sh, stray.txt"
rm -rf lib stray.txt
mkdir -p docs/agents .scratch
printf 'x\n' >docs/agents/notes.md
printf 'x\n' >.scratch/plan.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "changes inside the planning allowlist pass doctor --flow" "$st" 0
assert_not_contains "and are not reported" "$out" "planning allowlist"
rm -rf docs/agents/notes.md .scratch
# A git status that cannot run is a FAIL naming git's error, never the end of
# the report: doctor is what you run when the world is already broken.
idxbak="$(mktemp)"
cp "$(git rev-parse --git-dir)/index" "$idxbak"
printf 'garbage' >"$(git rev-parse --git-dir)/index"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
cp "$idxbak" "$(git rev-parse --git-dir)/index"
assert_status "a failing git status fails doctor --flow" "$st" 1
assert_contains "the FAIL names git's error" "$out" \
  "FAIL  git status failed - cannot check the working tree: "
assert_contains "and quotes it" "$out" "index file"
assert_contains "the rest of doctor still runs" "$out" "phase: implement"
assert_contains "and reaches its summary" "$(printf '%s\n' "$out" | tail -1)" " FAIL"

# --flow never runs the tools group, so if it skipped every check it has and
# still exited 0, /orchestrator:next would advance a flow nothing had checked.
if on_windows_bash; then
  skip_no_jq "--flow without jq fails rather than reporting a clean bill"
  skip_no_jq "names jq as the reason it cannot answer"
else
  out="$(PATH="$nojq_path" "$ORCH" doctor --flow 2>&1)"; st=$?
  assert_status "--flow without jq fails rather than reporting a clean bill" "$st" 1
  assert_contains "names jq as the reason it cannot answer" "$out" "jq not found"
fi

if on_windows_bash; then
  skip_no_jq "bare doctor without jq fails on the tools check"
  skip_no_jq "collapses every flow check into one line when jq is gone"
else
  out="$(PATH="$nojq_path" "$ORCH" doctor 2>&1)"; st=$?
  assert_status "bare doctor without jq fails on the tools check" "$st" 1
  # The count comes from the registry, so a check appended to it is covered by the
  # gate without anyone remembering to add a preamble - and this number moving is
  # how you find out that happened.
  assert_contains "collapses every flow check into one line when jq is gone" \
    "$out" "10 flow checks skipped: jq is not installed"
fi
restore_suite_env

# --- pr open -----------------------------------------------------------------
# PR #15 merged without closing #14 because the agent's body opened with a verb
# GitHub does not read as a closer. pr open owns the keyword instead, so no
# agent-chosen wording can leave a spec issue open again.
#
# open_pr's create goes through the store-backed fake (fake_github), and the
# PR it opened is read back from the store - the fixture gh's log stays empty, proving
# it never spawns a real gh subprocess. The real operation is pinned in "gh
# adapter contract".
echo
echo "pr open"
healthy_repo
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init propen >/dev/null
git checkout -q -b orch/16-propen
state_fixture branch orch/16-propen
body="$(mktemp)"
writeln 'Implements the thing.' '' 'Some detail.' >"$body"

out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "refuses when state has no issue" "$st" 1
assert_contains "with the guard branch create uses" "$out" \
  "no issue recorded in state - the spec phase must publish one first"

"$ORCH" state set issue 16
fake_github
fake_next_pr 23
: >"$GH_FIXTURE/env.log"
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "opens the PR" "$st" 0
assert_eq "prints the PR number GitHub gave it" "$out" "23"
assert_eq "and records it in state" "$("$ORCH" state get pr)" "23"
assert_eq "opening it as a draft" "$(fake_pr_draft_of 23)" "yes"
assert_eq "from the flow's branch" "$(fake_pr_head_of 23)" "orch/16-propen"
assert_eq "under the title given" "$(fake_pr_title_of 23)" "Title"
body_recorded="$(fake_pr_body_of 23)"
assert_first_line "the recorded body opens with the closing keyword" \
  "$body_recorded" "Closes #16"
assert_eq "and targets the flow's base, the default branch" "$(fake_pr_base_of 23)" "main"
assert_eq "leaves a blank line before the original body" \
  "$(printf '%s\n' "$body_recorded" | sed -n 2p)" ""
assert_contains "and keeps the agent's original body intact after a blank line" \
  "$body_recorded" "Some detail."
assert_eq "the create call never reached a real gh subprocess" \
  "$(gh_calls)" "0"

fake_fail adapter_pr_create 'a pull request for branch "orch/16-propen" into branch "main" already exists'
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not open the PR fails it" "$st" 1
assert_contains "passing gh's reason through" "$out" "already exists"
assert_contains "naming the branch it would have opened from" "$out" "orch/16-propen"
assert_contains "and the issue it would have closed" "$out" "#16"
assert_eq "opening nothing" "$(fake_prs)" "23 "
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

# require_branch's die message is the other half of require_field's coverage
# (#79) alongside "refuses when state has no issue" above - a fresh flow with
# an issue recorded but no branch yet is exactly the gap between init and
# branch create.
echo
echo "pr open (missing branch)"
new_repo >/dev/null
"$ORCH" init nobranch >/dev/null
"$ORCH" state set issue 21
body="$(mktemp)"
writeln 'Implements the thing.' >"$body"
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "refuses when state has no branch" "$st" 1
assert_contains "with the exact require_branch die message" "$out" \
  "no branch recorded in state"
restore_suite_env

# --- pr publish --------------------------------------------------------------
# The publishing boundary a quick implementation calls instead of hardcoding
# `gh pr create` in skill prose - stateless like branch off and issue publish,
# and not a draft like pr open is, since a quick implementation's review pass
# already ran before this is called.
echo
echo "pr publish"
new_repo >/dev/null
git remote set-url origin https://github.com/acme/widgets.git
gh_fixture
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
git checkout -q -b quick/16-widgets
body="$(mktemp)"
writeln 'Implements the thing.' '' 'Some detail.' >"$body"

fake_github
fake_next_pr 23
out="$("$ORCH" pr publish 16 "Title" "$body" 2>&1)"; st=$?
assert_status "opens the PR" "$st" 0
assert_eq "prints the PR number GitHub gave it" "$out" "23"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "opens against the default branch" "$(fake_pr_base_of 23)" "main"
assert_eq "not as a draft" "$(fake_pr_draft_of 23)" "no"
assert_eq "and from the current branch" "$(fake_pr_head_of 23)" "quick/16-widgets"
body_recorded="$(fake_pr_body_of 23)"
assert_first_line "the recorded body opens with the closing keyword" \
  "$body_recorded" "Closes #16"
assert_contains "and keeps the agent's original body intact after a blank line" \
  "$body_recorded" "Some detail."
assert_eq "pushes the current branch" \
  "$(git -C "$bare" rev-parse --quiet --verify refs/heads/quick/16-widgets >/dev/null && echo pushed || echo missing)" \
  "pushed"

out="$("$ORCH" pr publish abc "Title" "$body" 2>&1)"; st=$?
assert_status "refuses an issue that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" pr publish 16 "Title" /nonexistent/body.md 2>&1)"; st=$?
assert_status "refuses a body file that does not exist" "$st" 1

fake_fail adapter_pr_create
out="$("$ORCH" pr publish 16 "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not open the PR fails it" "$st" 1
assert_contains "naming the branch it would have opened from" "$out" "quick/16-widgets"
assert_contains "and the issue it would have closed" "$out" "#16"
restore_suite_env

# --- pr: unknown op -----------------------------------------------------------
new_repo >/dev/null
out="$("$ORCH" pr bogus 2>&1)"; st=$?
assert_status "pr bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown pr op"
assert_contains "naming both" "$out" "open|publish"

# --- every gh call pinned to the repo (#520) -----------------------------------
# A fork whose gh default points upstream: origin is the fork, GH_REPO unset,
# ORCH_GH_ADAPTER unset so the real adapter operations run, against the fixture
# gh. Every call that reaches it must carry the fork - none may fall back to
# gh's default. The argv each operation hands gh is pinned in "gh adapter
# contract"; this is the guard's own resolution of the repo, from origin.
echo
echo "every gh call pinned to the repo"
new_repo >/dev/null
unset GH_REPO GH_HOST
git remote set-url origin https://github.com/fork/widgets.git
gh_fixture
body="$(mktemp)"
writeln 'Some body.' >"$body"
fetched="$(mktemp)"
# pinned_replies <repo>: the fixture's answers to every call below, for the
# repo named - gh repo view alone takes it in its argv.
pinned_replies() {
  gh_reply 0 $'Some body.\n' '' issue view 5 --json body --jq .body
  gh_reply 0 '' '' issue edit 5 --body-file "$body"
  gh_reply 0 '' '' api 'repos/{owner}/{repo}/issues/50' --jq '.parent_issue_url // empty'
  gh_reply 0 $'main\n' '' repo view "$1" --json defaultBranchRef --jq .defaultBranchRef.name
  gh_reply 0 '[{"bucket":"fail","name":"build","link":"https://github.com/x/y/actions/runs/4242/job/1"}]' '' \
    pr checks 7 --json bucket,name,link
  gh_reply 0 '' '' run rerun 4242 --failed
}
pinned_replies fork/widgets
for args in "issue fetch 5 $fetched" "issue update 5 $body" "ticket parent 50" "base show" "review rerun 7"; do
  # shellcheck disable=SC2086 # each args string is a word list on purpose
  out="$(env -u ORCH_GH_ADAPTER "$ORCH" $args 2>&1)"; st=$?
  assert_status "$args runs in the fork" "$st" 0
done
assert_contains "the rerun reached gh pinned to the fork" \
  "$(cat "$GH_FIXTURE/env.log")" "GH_REPO=fork/widgets GH_HOST=<unset> run rerun 4242 --failed"
assert_contains "gh repo view got the fork as its positional argument" \
  "$(cat "$GH_FIXTURE/env.log")" "GH_REPO=fork/widgets GH_HOST=<unset> repo view fork/widgets "
assert_eq "every gh call carried the fork, and a github.com repo leaves GH_HOST unset" \
  "$(grep -cv '^GH_REPO=fork/widgets GH_HOST=<unset> ' "$GH_FIXTURE/env.log")" "0"
assert_eq "command gh appears in orch.sh and doctor.sh only inside the guard" \
  "$(cat "$ORCH" "$(dirname "$ORCH")/doctor.sh" | grep -c '\bcommand gh\b')" "1"
assert_contains "and that one is the gh guard's own" \
  "$(sed -n '/^gh() {$/,/^}$/p' "$ORCH")" 'command gh "$@"'

# No usable repo: the first command that reaches GitHub dies naming GH_REPO,
# in the parent shell (issue fetch) or in a command substitution (ticket
# parent) alike.
git remote remove origin
: >"$GH_FIXTURE/env.log"
for args in "issue fetch 5 $fetched" "ticket parent 50"; do
  # shellcheck disable=SC2086 # each args string is a word list on purpose
  out="$(env -u ORCH_GH_ADAPTER "$ORCH" $args 2>&1)"; st=$?
  assert_status "$args dies with no repo" "$st" 1
  assert_contains "$args names GH_REPO as the remedy" "$out" "GH_REPO=<owner>/<repo>"
done
assert_eq "and nothing reached gh unpinned" "$(cat "$GH_FIXTURE/env.log")" ""
out="$("$ORCH" slug "Some title" 2>&1)"; st=$?
assert_status "a local-only command is unaffected" "$st" 0

# A host other than github.com: gh api takes its host from GH_HOST, not from
# GH_REPO's host part, so every call - gh api's included - must carry both.
git remote add origin git@ghe.example.com:fork/widgets.git
pinned_replies ghe.example.com/fork/widgets
for args in "issue fetch 5 $fetched" "ticket parent 50" "base show" "review rerun 7"; do
  # shellcheck disable=SC2086 # each args string is a word list on purpose
  out="$(env -u ORCH_GH_ADAPTER "$ORCH" $args 2>&1)"; st=$?
  assert_status "$args runs on the repo's own host" "$st" 0
done
assert_contains "gh api was among the calls" "$(cat "$GH_FIXTURE/env.log")" \
  "GH_HOST=ghe.example.com api "
assert_eq "every gh call carried the host-qualified repo and its host" \
  "$(grep -cv '^GH_REPO=ghe.example.com/fork/widgets GH_HOST=ghe.example.com ' "$GH_FIXTURE/env.log")" "0"
restore_suite_env GH_HOST GH_FIXTURE

# --- pr release -----------------------------------------------------------------
# The release PR carries the base branch back into the default branch and
# closes every still-open issue whose work reached it - read from the bodies of
# the PRs merged into the base branch, never remembered by a human. Every
# GitHub call goes through the store-backed fake; the real operations are
# pinned in "gh adapter contract".
echo
echo "pr release"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main HEAD:refs/heads/uat
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
body="$(mktemp)"
writeln 'Ships the uat project.' '' 'Some detail.' >"$body"
release() { orch_gh_failing pr release "$@"; }
# The issues the merged PRs below refer to: #3 and #8 already closed, #62 a
# pull request, not an issue.
fake_github
for n in 5 6 7 9; do fake_issue "$n" open; done
fake_issue 3 closed
fake_issue 8 closed
fake_pull 62

out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "refuses when the base branch is the default branch" "$st" 1
assert_contains "naming it" "$out" "main"
assert_eq "and opens no PR" "$(fake_prs)" ""

orch_gh_failing base set uat >/dev/null
# Open PRs that are not a release PR: from uat into another base, and from
# another branch into main.
fake_pr 55 open uat staging
fake_pr 56 open topic main
fake_pr 57 open uat main
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "refuses while a release PR is already open" "$st" 1
assert_contains "printing that PR's number" "$out" "#57"
assert_eq "and opens no second one" "$(fake_prs)" "55 56 57 "
fake_pr 57 closed uat main
fake_fail adapter_prs_merged_bodies "HTTP 502: Bad Gateway"
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "with the release PR closed, only open PRs from uat into main counted" "$st" 1
assert_contains "it goes on to read the merged PRs" "$out" "gh could not list the PRs merged into uat"
rm -rf "$ORCH_GH_FAKE_STORE/prs" "$ORCH_GH_FAKE_STORE/fail"

# Every reference the merged PRs make is to an issue that is already closed.
# A PR merged into another base refers to an open issue, and does not count.
fake_pr 60 merged topic uat
fake_pr_body 60 "Refs #3"
fake_pr 61 merged topic uat
fake_pr_body 61 "No references here."
fake_pr 66 merged topic main
fake_pr_body 66 "Closes #5"
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "refuses when no referenced issue is still open" "$st" 1
assert_contains "saying there is nothing to close" "$out" "nothing to close"
assert_eq "and opens no PR" "$(fake_prs)" "60 61 66 "

fake_next_pr 70
out="$(release --force "Release" "$body" 2>&1)"; st=$?
assert_status "--force releases with nothing to close" "$st" 0
assert_eq "printing the PR number" "$out" "70"
assert_eq "with the caller's body alone" "$(fake_pr_body_of 70)" "$(cat "$body")"
rm -rf "$ORCH_GH_FAKE_STORE/prs"

# Hand-written PRs into uat count too: every keyword, in any case, anywhere in
# the body. #5 is referenced twice and #8 is already closed. Other closing
# forms (fix, closed) are prose, not references, and #62 is an open PR, not
# an issue.
fake_pr 62 merged topic uat
fake_pr_body 62 $'Refs #5\n\nImplements it.'
fake_pr 63 merged topic uat
fake_pr_body 63 $'Summary first.\n\nThis closes #6 and FIXES #7.'
fake_pr 64 merged topic uat
fake_pr_body 64 $'resolves #9\nAlso Refs #5, and Closes #8.\nIt prefixes #4 with nothing.'
fake_pr 65 merged topic uat
fake_pr_body 65 'A quick fix #12, closed #13. Refs #62, an open PR.'
fake_next_pr 71
out="$(release "Release uat" "$body" 2>&1)"; st=$?
assert_status "opens the release PR" "$st" 0
assert_eq "prints its number" "$out" "71"
assert_eq "one Closes line per still-open issue, deduplicated, above the caller's body" \
  "$(fake_pr_body_of 71)" "$(writeln 'Closes #5' 'Closes #6' 'Closes #7' 'Closes #9' '' 'Ships the uat project.' '' 'Some detail.')"
assert_eq "from the base branch" "$(fake_pr_head_of 71)" "uat"
assert_eq "into the default branch" "$(fake_pr_base_of 71)" "main"
assert_eq "with the caller's title" "$(fake_pr_title_of 71)" "Release uat"
assert_eq "not as a draft" "$(fake_pr_draft_of 71)" "no"
assert_eq "and pushes nothing" "$(git -C "$bare" for-each-ref --format='%(refname)' | sort | tr '\n' ' ')" \
  "refs/heads/main refs/heads/uat "

fake_pr 71 closed uat main
fake_fail adapter_pr_create
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "a gh that will not open the PR fails it" "$st" 1
assert_contains "naming both branches" "$out" "from uat into main"

out="$(release "Release" 2>&1)"; st=$?
assert_status "refuses a missing body file argument" "$st" 1
assert_contains "with its usage" "$out" "pr release [--force] <title> <body-file>"
orch_gh_failing base clear >/dev/null
rm -rf "$(dirname "$bare")"
restore_suite_env

# --- pr comment (#343) ----------------------------------------------------------
# A stateless post on the current branch's open PR, so a standalone review pass
# records its declines without calling gh itself. Three outcomes, like ticket
# exists: 0 posted (printing the PR), 1 only for no open PR, 2 for the rest.
echo
echo "pr comment (#343)"
new_repo >/dev/null
git checkout -q -b quick/12-foo
body="$(mktemp)"
writeln '## Review' '' '- `a.sh:3` - declined: out of scope.' >"$body"
prc() { "$ORCH" pr comment "$@"; }
fake_github
# Open PRs that are not this branch's: one from another branch, and a closed
# one from this branch.
fake_pr 50 open quick/99-other main
fake_pr 51 closed quick/12-foo main

out="$(prc "$body" 2>/dev/null)"; st=$?
assert_status "no open PR exits 1" "$st" 1
assert_eq "printing nothing" "$out" ""
assert_eq "and posts nothing" "$(fake_pr_comments_of 50)$(fake_pr_comments_of 51)" ""

fake_pr 57 open quick/12-foo main
out="$(prc "$body" 2>&1)"; st=$?
assert_status "posts on the branch's open PR" "$st" 0
assert_eq "printing the PR number" "$out" "57"
assert_eq "commenting on that PR, with the file's contents" "$(fake_pr_comments_of 57)" "$(cat "$body")"

fake_fail adapter_prs_open
err="$(prc "$body" 2>&1 >/dev/null)"; st=$?
assert_status "a GitHub that cannot be read exits 2" "$st" 2
[ -n "$err" ] && ok "with a reason on stderr" || bad "with a reason on stderr" "stderr was empty"
rm -rf "$ORCH_GH_FAKE_STORE/fail"

fake_fail adapter_pr_comment
err="$(prc "$body" 2>&1 >/dev/null)"; st=$?
assert_status "a failed post exits 2" "$st" 2
assert_contains "naming the PR" "$err" "#57"
rm -rf "$ORCH_GH_FAKE_STORE/fail"

err="$(prc /nonexistent/body.md 2>&1 >/dev/null)"; st=$?
assert_status "a missing file exits 2" "$st" 2
assert_contains "naming it" "$err" "/nonexistent/body.md"

err="$(prc 2>&1 >/dev/null)"; st=$?
assert_status "no file argument exits 2" "$st" 2
assert_contains "with its usage" "$err" "usage: orch.sh pr comment <file>"

git checkout -q --detach
err="$(prc "$body" 2>&1 >/dev/null)"; st=$?
assert_status "a detached HEAD exits 2" "$st" 2
assert_contains "saying so" "$err" "detached HEAD"

# Each exit-2 failure pinned byte for byte: the exact stderr line with its
# `orch: ` prefix, exit 2, and nothing on stdout (#347). Where gh itself
# failed, the fake's own complaint precedes it, so orch's line is the last.
errf="$(mktemp)"
out="$(prc "$body" 2>"$errf")"; st=$?
assert_status "detached HEAD: exit 2" "$st" 2
assert_eq "detached HEAD: exact stderr" "$(cat "$errf")" "orch: not on a branch (detached HEAD)"
assert_eq "detached HEAD: empty stdout" "$out" ""
git checkout -q quick/12-foo

out="$(prc 2>"$errf")"; st=$?
assert_status "no file argument: exit 2" "$st" 2
assert_eq "no file argument: exact stderr" "$(cat "$errf")" "orch: usage: orch.sh pr comment <file>"
assert_eq "no file argument: empty stdout" "$out" ""

out="$(prc /nonexistent/body.md 2>"$errf")"; st=$?
assert_status "missing file: exit 2" "$st" 2
assert_eq "missing file: exact stderr" "$(cat "$errf")" "orch: body file not found: /nonexistent/body.md"
assert_eq "missing file: empty stdout" "$out" ""

fake_fail adapter_prs_open
out="$(prc "$body" 2>"$errf")"; st=$?
assert_status "unreadable PR list: exit 2" "$st" 2
assert_eq "unreadable PR list: exact stderr" "$(tail -n 1 "$errf")" "orch: gh could not list the open PRs from quick/12-foo"
assert_eq "unreadable PR list: empty stdout" "$out" ""
rm -rf "$ORCH_GH_FAKE_STORE/fail"

fake_fail adapter_pr_comment
out="$(prc "$body" 2>"$errf")"; st=$?
assert_status "failed post: exit 2" "$st" 2
assert_eq "failed post: exact stderr" "$(tail -n 1 "$errf")" "orch: gh could not comment on PR #57"
assert_eq "failed post: empty stdout" "$out" ""
rm -f "$errf"
assert_eq "no failed call posted anything" "$(fake_pr_comments_of 57)" "$(cat "$body")"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

help="$("$ORCH" help)"
assert_contains "help documents pr comment" "$help" "pr comment <file>"

# --- pr fetch / pr update (#444) -----------------------------------------------
# The PR counterpart of issue fetch/update, on the current branch's open PR, so
# the fixer corrects a PR body without calling gh itself. pr update refuses a
# body that would drop the Closes/Refs line pr open/pr publish wrote.
echo
echo "pr fetch / pr update (#444)"
new_repo >/dev/null
git checkout -q -b orch/12-foo
fake_github
prb() { "$ORCH" pr "$@"; }
# set_pr_body <line>...: PR #57's body, one line each, as writeln writes it.
set_pr_body() { fake_pr_body 57 "$(writeln "$@")"$'\n'; }

out_file="$(mktemp -d)/body.md"
out="$(prb fetch "$out_file" 2>&1)"; st=$?
assert_status "pr fetch with no open PR fails" "$st" 1
assert_contains "saying so" "$out" "no open PR"
newbody="$(mktemp)"
writeln 'Closes #12' '' 'Adds nothing new.' >"$newbody"
out="$(prb update "$newbody" 2>&1)"; st=$?
assert_status "pr update with no open PR fails" "$st" 1

fake_pr 56 open orch/99-other main
fake_pr_body 56 "Closes #99"
fake_pr 57 open orch/12-foo main
set_pr_body 'Closes #12' '' 'Adds `quote_meta`, needed for meta#ts.'
out="$(prb fetch "$out_file" 2>&1)"; st=$?
assert_status "pr fetch succeeds" "$st" 0
assert_eq "pr fetch writes the current branch's open PR's body to the file" \
  "$(cat "$out_file")" "$(writeln 'Closes #12' '' 'Adds `quote_meta`, needed for meta#ts.')"

out="$(prb update "$newbody" 2>&1)"; st=$?
assert_status "pr update succeeds" "$st" 0
assert_eq "pr update replaces that PR's body with the file" "$(fake_pr_body_of 57)" "$(cat "$newbody")"
assert_eq "and no other" "$(fake_pr_body_of 56)" "Closes #99"
prb fetch "$out_file" >/dev/null 2>&1
assert_eq "a fetch after the update reads the new body back" "$(cat "$out_file")" "$(cat "$newbody")"

set_pr_body 'Refs #12' '' 'Into uat.'
writeln 'Refs #12' '' 'Into uat, corrected.' >"$newbody"
out="$(prb update "$newbody" 2>&1)"; st=$?
assert_status "pr update keeps a Refs line too" "$st" 0
assert_eq "replacing the body" "$(fake_pr_body_of 57)" "$(cat "$newbody")"

set_pr_body 'Closes #12' '' 'Original body.'
before="$(fake_pr_body_of 57)"
for bad_first in 'Adds nothing new.' 'Closes #13' 'Refs #12' ''; do
  { printf '%s\n' "$bad_first"; printf '\nCorrected body.\n'; } >"$newbody"
  err="$(prb update "$newbody" 2>&1 >/dev/null)"; st=$?
  assert_status "pr update refuses a first line of '$bad_first'" "$st" 1
  assert_eq "leaving the body unchanged ('$bad_first')" "$(fake_pr_body_of 57)" "$before"
  assert_contains "naming the line it must keep ('$bad_first')" "$err" "Closes #12"
done

set_pr_body 'Hand-edited, no issue line.'
writeln 'Hand-edited, no issue line.' '' 'More.' >"$newbody"
err="$(prb update "$newbody" 2>&1 >/dev/null)"; st=$?
assert_status "pr update refuses when the PR's body has no Closes/Refs first line" "$st" 1
assert_eq "leaving that body unchanged" "$(fake_pr_body_of 57)" "$(writeln 'Hand-edited, no issue line.')"

set_pr_body 'Closes #12'
err="$(prb update /nonexistent/body.md 2>&1 >/dev/null)"; st=$?
assert_status "pr update refuses a missing file" "$st" 1
assert_contains "naming it" "$err" "/nonexistent/body.md"

err="$(prb fetch 2>&1 >/dev/null)"; st=$?
assert_status "pr fetch with no file argument fails" "$st" 1
assert_contains "with its usage" "$err" "usage: orch.sh pr fetch <file>"
err="$(prb update 2>&1 >/dev/null)"; st=$?
assert_contains "pr update with no file argument gives its usage" "$err" "usage: orch.sh pr update <file>"

writeln 'Closes #12' '' 'x' >"$newbody"
fake_fail adapter_pr_body_edit
err="$(prb update "$newbody" 2>&1 >/dev/null)"; st=$?
assert_status "a failed edit fails" "$st" 1
assert_contains "naming the PR" "$err" "#57"
fake_fail adapter_pr_body
err="$(prb fetch "$out_file" 2>&1 >/dev/null)"; st=$?
assert_status "a failed read fails" "$st" 1
assert_contains "naming the PR" "$err" "#57"
assert_eq "leaving the body as it was" "$(fake_pr_body_of 57)" "$(writeln 'Closes #12')"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

help="$("$ORCH" help)"
assert_contains "help documents pr fetch" "$help" "pr fetch <file>"
assert_contains "help documents pr update" "$help" "pr update <file>"

# --- pr comments (#418) --------------------------------------------------------
# Every comment on the current branch's open PR, in issue comments' format, so a
# standalone review pass reads earlier passes' declines without calling gh
# itself. Three outcomes, like pr comment: 0 written, 1 only for no open PR, 2
# when GitHub cannot be read.
echo
echo "pr comments (#418)"
new_repo >/dev/null
git checkout -q -b quick/18-foo
prcs() { "$ORCH" pr comments "$@"; }
fake_github
pr_comments="$(mktemp -d)/comments.md"

printf 'known content\n' >"$pr_comments"
fake_pr 56 open quick/99-other main
fake_pr_comment 56 pat 2026-10-01T09:00:00Z "Not this one."
out="$(prcs "$pr_comments" 2>/dev/null)"; st=$?
assert_status "no open PR exits 1" "$st" 1
assert_eq "printing nothing" "$out" ""
assert_eq "and writing nothing" "$(cat "$pr_comments")" "known content"

fake_pr 57 open quick/18-foo main
out="$(prcs "$pr_comments" 2>&1)"; st=$?
assert_status "a PR with no comments still succeeds" "$st" 0
assert_eq "leaving an empty file" "$(wc -c <"$pr_comments" | tr -d ' ')" "0"

fake_pr_comment 57 pat 2026-10-01T09:00:00Z $'## Review\n\n- `a.sh:3` - unused helper - declined: out of scope.\n\n## Host fallbacks\n\nNone.'
fake_pr_comment 57 bot 2026-10-02T10:00:00Z "LGTM"
out="$(prcs "$pr_comments" 2>&1)"; st=$?
assert_status "pr comments writes the current branch's open PR's comments" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "in issue comments' format: each opened by its author-and-date marker" \
  "$(cat "$pr_comments")" "$(writeln '<!-- comment @pat 2026-10-01T09:00:00Z -->' \
    '## Review' '' '- `a.sh:3` - unused helper - declined: out of scope.' '' '## Host fallbacks' '' 'None.' '' \
    '<!-- comment @bot 2026-10-02T10:00:00Z -->' 'LGTM')"

printf 'known content\n' >"$pr_comments"
fake_fail adapter_prs_open
err="$(prcs "$pr_comments" 2>&1 >/dev/null)"; st=$?
assert_status "an unreadable PR list exits 2" "$st" 2
assert_eq "and writes nothing" "$(cat "$pr_comments")" "known content"
rm -rf "$ORCH_GH_FAKE_STORE/fail"

fake_fail adapter_pr_comments
err="$(prcs "$pr_comments" 2>&1 >/dev/null)"; st=$?
assert_status "unreadable comments exit 2" "$st" 2
assert_contains "naming the PR" "$err" "PR #57"
assert_eq "leaving the file that was already there unchanged" "$(cat "$pr_comments")" "known content"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

err="$(prcs 2>&1 >/dev/null)"; st=$?
assert_status "no file argument exits 2" "$st" 2
assert_contains "with its usage" "$err" "usage: orch.sh pr comments <file>"

assert_contains "help documents pr comments" "$("$ORCH" help)" "pr comments <file>"
rm -f "$pr_comments"

# --- ticket publish -----------------------------------------------------
# The one place the ticket-breakdown feature files a ticket and writes its
# sub-issue link and blocked-by edges, so no skill prose ever calls `gh api`
# on these endpoints directly. Stateless like issue publish/pr publish: the
# store-backed fake is the GitHub it writes to, not orch.sh state.
echo
echo "ticket publish"
ticket_fixture
fake_issue 50 open
fake_next_issue 100
out="$("$ORCH" ticket publish 50 "First ticket" "$body" 2>&1)"; st=$?
assert_status "publishes" "$st" 0
assert_eq "printing the child's issue number and nothing else" "$out" "100"
assert_eq "passes the title through" "$(fake_title_of 100)" "First ticket"
assert_eq "sends the body file's contents" "$(fake_body_of 100)" "Build the thing."
assert_eq "applies ready-for-agent" "$(fake_labels_of 100)" "ready-for-agent "
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "links the child as 50's sub-issue" "$(fake_sub_issues_of 50)" "100"

out="$("$ORCH" ticket publish 50 "Second ticket" "$body" --blocked-by 100 2>&1)"; st=$?
assert_status "publishes a ticket blocked by the first" "$st" 0
assert_eq "prints the new child's number" "$out" "101"
assert_eq "adding its blocking edge" "$(fake_blockers_of 101)" "100"
assert_eq "the still-blocked ticket is not in the frontier" "$("$ORCH" ticket next 50)" "100"

# GitHub stores a blocking edge once no matter how many times it is asked
# for - a duplicate in --blocked-by must not make the readback's set
# permanently smaller than what was requested and fail verification for a
# link that is actually correct.
out="$("$ORCH" ticket publish 50 "Third ticket" "$body" --blocked-by 100,100 2>&1)"; st=$?
assert_status "a duplicate blocker in the list still verifies and succeeds" "$st" 0
assert_eq "adding the edge once" "$(fake_blockers_of 102)" "100"

before="$(fake_snapshot)"
out="$("$ORCH" ticket publish 50 "" "$body" 2>&1)"; st=$?
assert_status "refuses an empty title" "$st" 1

out="$("$ORCH" ticket publish 50 "Title" /nonexistent/body.md 2>&1)"; st=$?
assert_status "refuses a body file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"

out="$("$ORCH" ticket publish abc "Title" "$body" 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by "abc,5" 2>&1)"; st=$?
assert_status "refuses a --blocked-by list with a non-numeric entry" "$st" 1
assert_contains "naming the whole list" "$out" "abc,5"

for list in "1,,2" ",5" "5,"; do
  out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by "$list" 2>&1)"; st=$?
  assert_status "refuses a --blocked-by list with an empty entry: $list" "$st" 1
  assert_contains "naming the whole list" "$out" "--blocked-by must be plain issue numbers, got: $list"
done

out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by 100 --blocked-by "" 2>&1)"; st=$?
assert_status "refuses a repeated --blocked-by, an empty one included" "$st" 1
assert_contains "with publish's usage line" "$out" "usage: orch.sh ticket publish"

out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by 2>&1)"; st=$?
assert_status "refuses a --blocked-by with no value" "$st" 1
assert_contains "with publish's usage line" "$out" "usage: orch.sh ticket publish"

out="$("$ORCH" ticket publish 50 "Title" "$body" --bogus 2>&1)"; st=$?
assert_status "rejects an unknown flag" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket publish"

out="$("$ORCH" ticket publish 50 2>&1)"; st=$?
assert_status "refuses with no body file" "$st" 1
assert_eq "none of the refusals wrote anything to GitHub" "$(fake_snapshot)" "$before"

fake_fail adapter_issue_create
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not create the ticket fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not create the ticket"
fake_unfail

fake_fail adapter_sub_issue_link "HTTP 422: Sub issue may only have one parent"
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that refuses the sub-issue link fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not link ticket #103 as a sub-issue of #50"
assert_contains "with gh's reason" "$out" "HTTP 422"
fake_unfail

fake_fail adapter_blocker_add
out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by 100 2>&1)"; st=$?
assert_status "a gh that refuses the blocking edge fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not add a blocking edge from ticket #104 on #100"
fake_unfail

out="$("$ORCH" ticket publish 50 "Unblocked" "$body" --blocked-by "" 2>&1)"; st=$?
assert_status "an empty --blocked-by still publishes" "$st" 0
assert_eq "printing the child's number" "$out" "105"
assert_eq "with no blockers" "$(fake_blockers_of 105)" ""
restore_suite_env

# --- ticket publish verify-then-die ---------------------------------------
# Immediately after publishing, ticket_publish reads the links back (ADR-0011).
# One retry on a mismatch; a second failure dies naming the ticket, rather
# than falling back to a text-based `Blocked by:` convention nothing
# downstream ever reads. fake_lag makes a readback answer stale (empty) for N
# calls.
echo
echo "ticket publish verify-then-die"
ticket_fixture
fake_issue 50 open
fake_next_issue 200
fake_lag adapter_sub_issues 1
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a sub-issue link that only shows up on the retry still succeeds" "$st" 0
assert_eq "prints the child's number" "$out" "200"

fake_lag adapter_sub_issues 2
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a sub-issue link that never shows up dies rather than falling back" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #201"
assert_contains "not a silent fallback" "$out" "did not verify"
assert_eq "the link it wrote stays, for a human to see" "$(fake_sub_issues_of 50)" "200 201"

fake_next_issue 300
blocker="$("$ORCH" ticket publish 50 "Blocker" "$body")"
fake_lag adapter_blockers 2
out="$("$ORCH" ticket publish 50 "Blocked" "$body" --blocked-by "$blocker" 2>&1)"; st=$?
assert_status "a blocking edge that never shows up dies rather than falling back" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #301"
assert_contains "not a silent fallback" "$out" "did not verify"

fake_fail_times adapter_blockers 1
out="$("$ORCH" ticket publish 50 "Blocked" "$body" --blocked-by "$blocker" 2>&1)"; st=$?
assert_status "a transient blocked-by read failure is retried, not died on" "$st" 0
assert_eq "printing only the child's number, no stray stderr" "$out" "302"
assert_eq "its edge is in place" "$(fake_blockers_of 302)" "$blocker"

fake_fail adapter_blockers
out="$("$ORCH" ticket publish 50 "Blocked" "$body" --blocked-by "$blocker" 2>&1)"; st=$?
assert_status "a blocked-by read that fails twice dies" "$st" 1
assert_contains "with the verify message" "$out" \
  "ticket #303's sub-issue/blocked-by links did not verify - checked twice, both failed"
assert_not_contains "never the block/unblock read message" "$out" "could not read ticket"
restore_suite_env

# --- ticket next -----------------------------------------------------------
# The parent's open sub-issues with zero open blockers, in the order they were
# published.
echo
echo "ticket next"
ticket_fixture
fake_issue 90 open
fake_next_issue 400
a="$("$ORCH" ticket publish 90 "A" "$body")"
b="$("$ORCH" ticket publish 90 "B" "$body" --blocked-by "$a")"
c="$("$ORCH" ticket publish 90 "C" "$body")"
out="$("$ORCH" ticket next 90)"
assert_eq "open-and-unblocked tickets only, in publish order, excluding the still-blocked one" \
  "$out" "$(printf '%s\n%s' "$a" "$c")"

"$ORCH" ticket close "$a" >/dev/null
out="$("$ORCH" ticket next 90)"
assert_eq "a closed blocker drops out, freeing its dependent" "$out" "$(printf '%s\n%s' "$b" "$c")"

"$ORCH" ticket close "$c" >/dev/null
out="$("$ORCH" ticket next 90)"
assert_eq "a closed ticket itself is no longer in the frontier" "$out" "$b"

out="$("$ORCH" ticket next abc 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" ticket next 2>&1)"; st=$?
assert_status "refuses with no parent" "$st" 1

fake_fail adapter_sub_issues
out="$("$ORCH" ticket next 90 2>&1)"; st=$?
assert_status "a gh that cannot list sub-issues fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not list sub-issues of #90"
restore_suite_env

# --- ticket list -------------------------------------------------------------
# Every sub-issue of <parent>, open or closed, one "<n> open|closed" line
# each in publish order - what a spec review reads to find the tickets its
# accepted edits touch, without calling a sub-issue endpoint itself.
echo
echo "ticket list"
ticket_fixture
fake_issue 90 open
fake_issue 91 open
fake_next_issue 450
a="$("$ORCH" ticket publish 90 "A" "$body")"
b="$("$ORCH" ticket publish 90 "B" "$body" --blocked-by "$a")"
"$ORCH" ticket close "$a" >/dev/null
out="$("$ORCH" ticket list 90)"
assert_eq "lists every sub-issue with its state, closed ones included, in publish order" \
  "$out" "$(printf '450 closed\n451 open')"

assert_eq "a parent with no sub-issues lists nothing" "$("$ORCH" ticket list 91)" ""

out="$("$ORCH" ticket list abc 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

fake_fail adapter_sub_issues
out="$("$ORCH" ticket list 90 2>&1)"; st=$?
assert_status "a gh that cannot list sub-issues fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not list sub-issues of #90"
restore_suite_env

# --- ticket close ------------------------------------------------------------
echo
echo "ticket close"
ticket_fixture
fake_issue 90 open
fake_next_issue 500
n="$("$ORCH" ticket publish 90 "Closeable" "$body")"
out="$("$ORCH" ticket close "$n" 2>&1)"; st=$?
assert_status "closes the ticket" "$st" 0
assert_eq "closing it" "$(fake_state_of "$n")" "CLOSED"
assert_eq "and it drops out of the parent's open sub-issues" \
  "$("$ORCH" ticket next 90)" ""

out="$("$ORCH" ticket close abc 2>&1)"; st=$?
assert_status "refuses a ticket that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

fake_fail adapter_issue_close
out="$("$ORCH" ticket close "$n" 2>&1)"; st=$?
assert_status "a gh that will not close the ticket fails" "$st" 1
assert_contains "naming what failed" "$out" "gh could not close ticket"
restore_suite_env

# --- ticket reset ------------------------------------------------------------
# Reopens every sub-issue of <parent> that is currently closed, and only
# those - what redo review needs before handing back to a fresh implement
# phase, whose frontier query would otherwise find nothing.
echo
echo "ticket reset"
ticket_fixture
fake_issue 90 open
fake_next_issue 600
x="$("$ORCH" ticket publish 90 "X" "$body")"
y="$("$ORCH" ticket publish 90 "Y" "$body")"
z="$("$ORCH" ticket publish 90 "Z" "$body")"
"$ORCH" ticket close "$x" >/dev/null
"$ORCH" ticket close "$y" >/dev/null
out="$("$ORCH" ticket reset 90 2>&1)"; st=$?
assert_status "resets" "$st" 0
assert_eq "reopens exactly the tickets that were closed, and only those" \
  "$(fake_state_of "$x") $(fake_state_of "$y") $(fake_state_of "$z")" "OPEN OPEN OPEN"
assert_eq "in the frontier again" \
  "$("$ORCH" ticket next 90)" "$(printf '%s\n%s\n%s' "$x" "$y" "$z")"

out="$("$ORCH" ticket reset abc 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

"$ORCH" ticket close "$x" >/dev/null
fake_fail adapter_issue_reopen
out="$("$ORCH" ticket reset 90 2>&1)"; st=$?
assert_status "a gh that will not reopen a ticket fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not reopen ticket #$x"
fake_unfail

fake_fail adapter_sub_issues
out="$("$ORCH" ticket reset 90 2>&1)"; st=$?
assert_status "a gh that cannot list sub-issues fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not list sub-issues of #90"
restore_suite_env

# --- ticket parent -----------------------------------------------------------
# The implementer's way to find its spec issue without calling the sub-issue
# endpoints itself: a sub-issue prints its parent's number, an issue with no
# parent prints nothing and still succeeds, and any gh failure is a failure.
echo
echo "ticket parent"
ticket_fixture
fake_issue 95 open
fake_next_issue 700
k="$("$ORCH" ticket publish 95 "Kid" "$body")"
out="$("$ORCH" ticket parent "$k" 2>&1)"; st=$?
assert_status "a sub-issue's parent lookup succeeds" "$st" 0
assert_eq "printing the parent's number" "$out" "95"

out="$("$ORCH" ticket parent 95 2>&1)"; st=$?
assert_status "an issue with no parent still succeeds" "$st" 0
assert_eq "printing nothing" "$out" ""

fake_fail adapter_issue_parent
out="$("$ORCH" ticket parent "$k" 2>&1)"; st=$?
assert_status "a gh that cannot read the issue fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not read issue #$k"
fake_unfail

out="$("$ORCH" ticket parent abc 2>&1)"; st=$?
assert_status "refuses a ticket that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" ticket parent 2>&1)"; st=$?
assert_status "refuses with no ticket" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket parent"

out="$("$ORCH" help 2>&1)"
assert_contains "ticket parent is in the usage text" "$out" "ticket parent <n>"
restore_suite_env

# --- ticket exists -----------------------------------------------------------
# "Already broken down" decided by structure, not prose: a blueprint's spec
# issue carries sub-issues, or - when its breakdown collapsed into it - a line
# that is exactly `## Ticket` outside a code fence.
echo
echo "ticket exists"
ticket_fixture
for p in 96 97 98 99; do fake_issue "$p" open; done
fake_next_issue 800
"$ORCH" ticket publish 96 "Open kid" "$body" >/dev/null
out="$("$ORCH" ticket exists 96 2>&1)"; st=$?
assert_status "an issue with a sub-issue has a breakdown" "$st" 0
assert_eq "printing sub-issues" "$out" "sub-issues"

closed_kid="$("$ORCH" ticket publish 97 "Closed kid" "$body")"
"$ORCH" ticket close "$closed_kid"
out="$("$ORCH" ticket exists 97 2>&1)"; st=$?
assert_status "an issue whose only sub-issue is closed still has a breakdown" "$st" 0
assert_eq "printing sub-issues" "$out" "sub-issues"

fake_issue_body 96 "$(writeln 'The spec.' '' '## Ticket' '' 'Build it.')"
out="$("$ORCH" ticket exists 96 2>&1)"; st=$?
assert_status "sub-issues and the heading together" "$st" 0
assert_eq "print sub-issues, which wins" "$out" "sub-issues"

fake_issue_body 98 "$(writeln 'The spec.' '' '## Ticket' '' 'Build it.')"
out="$("$ORCH" ticket exists 98 2>&1)"; st=$?
assert_status "a collapsed breakdown, the heading and no sub-issues" "$st" 0
assert_eq "prints collapsed" "$out" "collapsed"

fake_issue_body 99 'The spec, no breakdown yet.'
out="$("$ORCH" ticket exists 99 2>&1)"; st=$?
assert_status "an issue with neither has no breakdown" "$st" 1
assert_eq "and prints nothing" "$out" ""

fake_issue_body 99 "$(writeln 'The spec.' '' '### Ticket' '' 'Not the heading.')"
out="$("$ORCH" ticket exists 99 2>&1)"; st=$?
assert_status "a ### Ticket heading is not the collapse heading" "$st" 1
assert_eq "and prints nothing" "$out" ""

fake_issue_body 99 'The spec mentions ## Ticket mid-line.'
out="$("$ORCH" ticket exists 99 2>&1)"; st=$?
assert_status "a mid-line ## Ticket is not the collapse heading" "$st" 1
assert_eq "and prints nothing" "$out" ""

fake_issue_body 99 "$(writeln 'The spec quotes the format:' '```md' '## Ticket' '```')"
out="$("$ORCH" ticket exists 99 2>&1)"; st=$?
assert_status "a ## Ticket inside a code fence is not the collapse heading" "$st" 1
assert_eq "and prints nothing" "$out" ""

# An unreadable GitHub is not "no breakdown": a caller that read exit 1 as
# "neither" would publish a second breakdown, so a gh failure dies with 2.
fake_fail adapter_sub_issues
out="$("$ORCH" ticket exists 98 2>&1)"; st=$?
assert_status "a gh that cannot list sub-issues dies with 2, not no-breakdown's 1" "$st" 2
assert_contains "naming what failed" "$out" "gh could not list sub-issues of #98"
fake_unfail

fake_fail adapter_issue_body
out="$("$ORCH" ticket exists 98 2>&1)"; st=$?
assert_status "a gh that cannot read the issue dies with 2, not no-breakdown's 1" "$st" 2
assert_not_contains "never printing a verdict" "$out" "collapsed"
fake_unfail

# The same two failures pinned byte for byte: exact last line of stderr,
# exit 2, empty stdout (#347).
errf="$(mktemp)"
fake_fail adapter_sub_issues
out="$("$ORCH" ticket exists 98 2>"$errf")"; st=$?
assert_status "unlistable sub-issues: exit 2" "$st" 2
assert_eq "unlistable sub-issues: exact stderr" "$(tail -n 1 "$errf")" "orch: gh could not list sub-issues of #98"
assert_eq "unlistable sub-issues: empty stdout" "$out" ""
fake_unfail

fake_fail adapter_issue_body
out="$("$ORCH" ticket exists 98 2>"$errf")"; st=$?
assert_status "unreadable body: exit 2" "$st" 2
assert_eq "unreadable body: exact stderr" "$(tail -n 1 "$errf")" "orch: gh could not read issue #98's body"
assert_eq "unreadable body: empty stdout" "$out" ""
fake_unfail
rm -f "$errf"

out="$("$ORCH" ticket exists abc 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" ticket exists 2>&1)"; st=$?
assert_status "refuses with no parent" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket exists"

out="$("$ORCH" help 2>&1)"
assert_contains "ticket exists is in the usage text" "$out" "ticket exists <parent>"
restore_suite_env

# --- ticket block ------------------------------------------------------------
# Adds native blocking edges to a published, open ticket, verifies them by
# reading the target's blocked-by list back (ADR-0011's verify-then-die), and
# rewrites the body's `## Blocked by` section to match. Idempotent, so a run
# that died part-way is finished by running it again.
echo
echo "ticket block"
ticket_fixture
for p in 96 97 199; do fake_issue "$p" open; done
fake_next_issue 800
ba="$("$ORCH" ticket publish 96 "A" "$body")"
bb="$("$ORCH" ticket publish 96 "B" "$body")"
bc="$("$ORCH" ticket publish 96 "C" "$body")"
bd="$("$ORCH" ticket publish 96 "D" "$body")"
out="$("$ORCH" ticket block "$bb" --by "$ba" 2>&1)"; st=$?
assert_status "blocking one ticket on a sibling succeeds" "$st" 0
assert_eq "adding the edge" "$(fake_blockers_of "$bb")" "$ba"
assert_eq "after block, ticket next no longer lists the target while its blocker is open" \
  "$("$ORCH" ticket next 96)" "$(printf '%s\n%s\n%s' "$ba" "$bc" "$bd")"

fake_fail adapter_blocker_add
out="$("$ORCH" ticket block "$bb" --by "$ba" 2>&1)"; st=$?
assert_status "blocking on an edge already present succeeds, writing no edge" "$st" 0
assert_eq "the edge is still there once" "$(fake_blockers_of "$bb")" "$ba"
fake_unfail

out="$("$ORCH" ticket block "$bd" --by "$bc,$ba,$bc" 2>&1)"; st=$?
assert_status "blocking on several siblings, one repeated, succeeds" "$st" 0
assert_eq "adding each edge once" "$(fake_blockers_of "$bd")" "$ba $bc"

out="$("$ORCH" ticket block abc --by "$ba" 2>&1)"; st=$?
assert_status "refuses a target that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"
out="$("$ORCH" ticket block "$bc" --by "$ba,x1" 2>&1)"; st=$?
assert_status "refuses a --by list with a non-numeric entry" "$st" 1
assert_contains "naming the list" "$out" "$ba,x1"
out="$("$ORCH" ticket block "$bc" --by "$ba,,$ba" 2>&1)"; st=$?
assert_status "refuses a --by list with an empty entry" "$st" 1
assert_contains "naming the list" "$out" "--by must be plain issue numbers, got: $ba,,$ba"
out="$("$ORCH" ticket block "$bc" --by "" 2>&1)"; st=$?
assert_status "refuses an empty --by" "$st" 1
assert_contains "saying it got nothing" "$out" "--by must be plain issue numbers, got nothing"
out="$("$ORCH" ticket block "$bc" 2>&1)"; st=$?
assert_status "refuses a missing --by" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket block"
out="$("$ORCH" ticket block --by "$ba" 2>&1)"; st=$?
assert_status "refuses a missing target" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket block"
out="$("$ORCH" ticket block "$bc" --by "$ba" --by "$bb" 2>&1)"; st=$?
assert_status "refuses a repeated --by" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket block"
assert_eq "none of the refusals wrote an edge" "$(fake_blockers_of "$bc")" ""

be="$("$ORCH" ticket publish 96 "E" "$body")"
bx="$("$ORCH" ticket publish 97 "Elsewhere" "$body")"
"$ORCH" ticket close "$be" >/dev/null
out="$("$ORCH" ticket block "$be" --by "$ba" 2>&1)"; st=$?
assert_status "refuses a closed target" "$st" 1
assert_contains "naming it" "$out" "ticket #$be is closed"
out="$("$ORCH" ticket block 96 --by "$ba" 2>&1)"; st=$?
assert_status "refuses a target that is not a sub-issue" "$st" 1
assert_contains "naming it" "$out" "#96 is not a sub-issue"
out="$("$ORCH" ticket block "$bc" --by "$ba,$bx" 2>&1)"; st=$?
assert_status "refuses a --by issue under another parent" "$st" 1
assert_contains "naming it" "$out" "#$bx is not a sub-issue of #96"
out="$("$ORCH" ticket block "$bc" --by 96 2>&1)"; st=$?
assert_status "refuses a --by issue with no parent" "$st" 1
assert_contains "naming it" "$out" "#96 is not a sub-issue of #96"
assert_eq "the refusals wrote no edge, not even the sibling one" \
  "$(fake_blockers_of "$be")$(fake_blockers_of 96)$(fake_blockers_of "$bc")" ""
out="$("$ORCH" ticket block "$bc" --by "$be" 2>&1)"; st=$?
assert_status "accepts a closed blocker" "$st" 0
assert_eq "adding its edge" "$(fake_blockers_of "$bc")" "$be"

# The readback lags only after the read ahead of the write answered current.
bf="$("$ORCH" ticket publish 96 "F" "$body")"
bg="$("$ORCH" ticket publish 96 "G" "$body")"
fake_lag_after adapter_blockers 1 1 999999
out="$("$ORCH" ticket block "$bf" --by "$ba" 2>&1)"; st=$?
assert_status "a readback that is wrong once and right on the retry succeeds" "$st" 0
fake_lag_after adapter_blockers 1 2 999999
out="$("$ORCH" ticket block "$bg" --by "$ba" 2>&1)"; st=$?
assert_status "a readback that is wrong twice dies" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #$bg's blocking edges did not verify"
fake_fail adapter_blocker_add "HTTP 422: Validation Failed"
out="$("$ORCH" ticket block "$bf" --by "$bb" 2>&1)"; st=$?
assert_status "a gh that refuses the edge write fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not add a blocking edge from ticket #$bf on #$bb"
assert_contains "with gh's reason" "$out" "HTTP 422"
fake_unfail
fake_fail adapter_blockers
out="$("$ORCH" ticket block "$bf" --by "$bb" 2>&1)"; st=$?
assert_status "a gh that cannot read the blockers fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not read ticket #$bf's blockers"
fake_unfail
fake_fail adapter_issue_state
out="$("$ORCH" ticket block "$bf" --by "$bb" 2>&1)"; st=$?
assert_status "a gh that cannot read the target fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not read ticket #$bf"
fake_unfail
fake_fail_after adapter_issue_parent 1
out="$("$ORCH" ticket block "$bf" --by "$bb" 2>&1)"; st=$?
assert_status "a gh that cannot read a blocker's parent fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "a blocker of ticket #$bf"
fake_unfail
assert_eq "none of the failures added the edge" "$(fake_blockers_of "$bf")" "$ba"

# The body rewrite, driven by no-op runs: $bb is blocked by $ba alone and
# $bd by $ba and $bc, so each run below writes no edge and only brings the
# body's section in line. Each body is seeded as gh's read of it answers.
fake_body_read "$bd" 'Intro\n\n## Blocked by\n\n- #999\nold\n\n### Detail\nx\n\n## After\nTail.\n'
out="$("$ORCH" ticket block "$bd" --by "$ba" 2>&1)"; st=$?
assert_status "a no-op run with a stale section succeeds" "$st" 0
assert_eq "replaces a section in the middle of the body, a ### heading inside it included" \
  "$(fake_body_of "$bd" | od -c)" \
  "$(printf 'Intro\n\n## Blocked by\n\n- #%s\n- #%s\n\n## After\nTail.\n' "$ba" "$bc" | od -c)"

fake_body_read "$bb" 'Intro\n\n## Blocked by\n\nNone (can start immediately)\n'
"$ORCH" ticket block "$bb" --by "$ba" >/dev/null 2>&1
assert_eq "replaces a section at the end of the body" \
  "$(fake_body_of "$bb" | od -c)" "$(printf 'Intro\n\n## Blocked by\n\n- #%s\n' "$ba" | od -c)"

fake_body_read "$bb" 'Intro\n\nMore.\n'
"$ORCH" ticket block "$bb" --by "$ba" >/dev/null 2>&1
assert_eq "appends a missing section after one blank line" \
  "$(fake_body_of "$bb" | od -c)" "$(printf 'Intro\n\nMore.\n\n## Blocked by\n\n- #%s\n' "$ba" | od -c)"

fake_body_read "$bb" 'Intro\n\n## Blocked by\n\nNone\n# Top\nTail.\n'
"$ORCH" ticket block "$bb" --by "$ba" >/dev/null 2>&1
assert_eq "a # heading ends the section" \
  "$(fake_body_of "$bb" | od -c)" "$(printf 'Intro\n\n## Blocked by\n\n- #%s\n\n# Top\nTail.\n' "$ba" | od -c)"

fake_body_read "$bb" 'Intro\r\n\r\n## Blocked by\r\n\r\nNone\r\n\r\n## After\r\nTail.\r\n'
"$ORCH" ticket block "$bb" --by "$ba" >/dev/null 2>&1
assert_eq "a CRLF body keeps its CRLF lines, the rewritten section in kind" \
  "$(fake_body_of "$bb" | od -c)" "$(printf 'Intro\r\n\r\n## Blocked by\r\n\r\n- #%s\r\n\r\n## After\r\nTail.\r\n' "$ba" | od -c)"

fake_body_read "$bb" 'Intro\n\n```md\n## Blocked by\n\n- #1\n```\n'
"$ORCH" ticket block "$bb" --by "$ba" >/dev/null 2>&1
assert_eq "a fenced ## Blocked by is ignored and a real section appended" \
  "$(fake_body_of "$bb" | od -c)" "$(printf 'Intro\n\n```md\n## Blocked by\n\n- #1\n```\n\n## Blocked by\n\n- #%s\n' "$ba" | od -c)"

fake_body_read "$bb" '## Blocked by\n\n```\n## Not a heading\n```\n\n## After\nTail.\n'
"$ORCH" ticket block "$bb" --by "$ba" >/dev/null 2>&1
assert_eq "a fenced ## line inside the section does not end it" \
  "$(fake_body_of "$bb" | od -c)" "$(printf '## Blocked by\n\n- #%s\n\n## After\nTail.\n' "$ba" | od -c)"

fake_body_read "$bb" '## Blocked by\n\n- #%s\n' "$ba"
fake_fail adapter_issue_body_edit
out="$("$ORCH" ticket block "$bb" --by "$ba" 2>&1)"; st=$?
assert_status "a run with nothing to change succeeds, writing no body when the result is byte-identical" "$st" 0
fake_unfail

# Ascending means numeric: #98 sorts before #100.
fake_next_issue 98
s98="$("$ORCH" ticket publish 199 "S98" "$body")"
s99="$("$ORCH" ticket publish 199 "S99" "$body")"
s100="$("$ORCH" ticket publish 199 "S100" "$body")"
"$ORCH" ticket block "$s99" --by "$s100,$s98" >/dev/null 2>&1
assert_eq "lists the blockers sorted ascending by number" \
  "$(fake_body_of "$s99")" "$(printf 'Build the thing.\n\n## Blocked by\n\n- #98\n- #100')"

# Any gh failure dies naming the ticket; edges already written stay, and the
# same command run again finishes the job.
fake_next_issue 820
bh="$("$ORCH" ticket publish 96 "H" "$body")"
fake_body_read "$bh" 'Intro\n'
fake_fail adapter_issue_body
out="$("$ORCH" ticket block "$bh" --by "$ba" 2>&1)"; st=$?
assert_status "a gh that cannot read the body fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not read ticket #$bh's body"
assert_eq "the edge it wrote stays" "$(fake_blockers_of "$bh")" "$ba"
fake_unfail
fake_fail adapter_issue_body_edit
out="$("$ORCH" ticket block "$bh" --by "$ba" 2>&1)"; st=$?
assert_status "a gh that cannot write the body fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not rewrite ticket #$bh's ## Blocked by section"
fake_unfail
out="$("$ORCH" ticket block "$bh" --by "$ba" 2>&1)"; st=$?
assert_status "re-running after the body failures succeeds" "$st" 0
assert_eq "finishing the body" "$(fake_body_of "$bh")" "$(printf 'Intro\n\n## Blocked by\n\n- #%s' "$ba")"

bi="$("$ORCH" ticket publish 96 "I" "$body")"
fake_fail_after adapter_blocker_add 1
out="$("$ORCH" ticket block "$bi" --by "$ba,$bb" 2>&1)"; st=$?
assert_status "a multi-edge run that dies part-way fails" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #$bi"
assert_eq "keeping the edge it wrote" "$(fake_blockers_of "$bi")" "$ba"
fake_fail_after adapter_blocker_add 1
out="$("$ORCH" ticket block "$bi" --by "$ba,$bb" 2>&1)"; st=$?
assert_status "re-running the same command succeeds, adding only the missing edge" "$st" 0
fake_unfail
assert_eq "both edges in place" "$(fake_blockers_of "$bi")" "$ba $bb"
assert_contains "and bringing the body in line" "$(fake_body_of "$bi")" "$(printf -- '- #%s\n- #%s' "$ba" "$bb")"

out="$("$ORCH" help 2>&1)"
assert_contains "ticket block is in the usage text" "$out" "ticket block <n> --by N,N,..."

restore_suite_env

# --- ticket unblock ----------------------------------------------------------
# Removes native blocking edges from a published, open ticket, verifies the
# rest by reading them back (ADR-0011), and rewrites the body's `## Blocked
# by` section to match. Idempotent, so a run that died part-way is finished
# by running it again.
echo
echo "ticket unblock"
ticket_fixture
for p in 96 97; do fake_issue "$p" open; done
fake_next_issue 900
ua="$("$ORCH" ticket publish 96 "A" "$body")"
ub="$("$ORCH" ticket publish 96 "B" "$body")"
uc="$("$ORCH" ticket publish 96 "C" "$body")"
ud="$("$ORCH" ticket publish 96 "D" "$body")"
"$ORCH" ticket block "$ud" --by "$ua,$ub,$uc" >/dev/null 2>&1
out="$("$ORCH" ticket unblock "$ud" --by "$ub" 2>&1)"; st=$?
assert_status "unblocking one edge succeeds" "$st" 0
assert_eq "removing that edge alone" "$(fake_blockers_of "$ud")" "$ua $uc"
assert_eq "and bringing the body in line" \
  "$(fake_body_of "$ud")" "$(printf 'Build the thing.\n\n## Blocked by\n\n- #%s\n- #%s' "$ua" "$uc")"
out="$("$ORCH" ticket unblock "$ud" --by "$uc,$ua,$uc" 2>&1)"; st=$?
assert_status "unblocking several edges, one repeated, succeeds" "$st" 0
assert_eq "removing each of them" "$(fake_blockers_of "$ud")" ""
assert_eq "removing the last edge writes None (can start immediately)" \
  "$(fake_body_of "$ud")" "$(printf 'Build the thing.\n\n## Blocked by\n\nNone (can start immediately)')"
assert_eq "after unblock, ticket next lists the target again" \
  "$("$ORCH" ticket next 96)" "$(printf '%s\n%s\n%s\n%s' "$ua" "$ub" "$uc" "$ud")"

fake_body_read "$ud" 'Intro\n\n## Blocked by\n\n- #%s\n' "$ua"
fake_fail adapter_blocker_remove
out="$("$ORCH" ticket unblock "$ud" --by "$ua" 2>&1)"; st=$?
assert_status "unblocking an edge already absent succeeds, writing no edge" "$st" 0
fake_unfail
assert_eq "still bringing the body section in line" \
  "$(fake_body_of "$ud" | od -c)" "$(printf 'Intro\n\n## Blocked by\n\nNone (can start immediately)\n' | od -c)"

out="$("$ORCH" ticket unblock abc --by "$ua" 2>&1)"; st=$?
assert_status "refuses a target that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"
out="$("$ORCH" ticket unblock "$uc" --by "$ua,x1" 2>&1)"; st=$?
assert_status "refuses a --by list with a non-numeric entry" "$st" 1
assert_contains "naming the list" "$out" "$ua,x1"
out="$("$ORCH" ticket unblock "$uc" --by "$ua,,$ua" 2>&1)"; st=$?
assert_status "refuses a --by list with an empty entry" "$st" 1
assert_contains "naming the list" "$out" "--by must be plain issue numbers, got: $ua,,$ua"
out="$("$ORCH" ticket unblock "$uc" --by "" 2>&1)"; st=$?
assert_status "refuses an empty --by" "$st" 1
assert_contains "saying it got nothing" "$out" "--by must be plain issue numbers, got nothing"
out="$("$ORCH" ticket unblock "$uc" 2>&1)"; st=$?
assert_status "refuses a missing --by" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket unblock"
out="$("$ORCH" ticket unblock --by "$ua" 2>&1)"; st=$?
assert_status "refuses a missing target" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket unblock"
out="$("$ORCH" ticket unblock "$uc" --by "$ua" --by "$ub" 2>&1)"; st=$?
assert_status "refuses a repeated --by" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket unblock"

ue="$("$ORCH" ticket publish 96 "E" "$body")"
ux="$("$ORCH" ticket publish 97 "Elsewhere" "$body")"
uf="$("$ORCH" ticket publish 96 "F" "$body")"
"$ORCH" ticket block "$ue" --by "$ua" >/dev/null 2>&1
"$ORCH" ticket block "$uf" --by "$ua,$ub" >/dev/null 2>&1
"$ORCH" ticket close "$ue" >/dev/null
out="$("$ORCH" ticket unblock "$ue" --by "$ua" 2>&1)"; st=$?
assert_status "refuses a closed target" "$st" 1
assert_contains "naming it" "$out" "ticket #$ue is closed"
assert_eq "leaving its edge" "$(fake_blockers_of "$ue")" "$ua"
out="$("$ORCH" ticket unblock 96 --by "$ua" 2>&1)"; st=$?
assert_status "refuses a target that is not a sub-issue" "$st" 1
assert_contains "naming it" "$out" "#96 is not a sub-issue"
out="$("$ORCH" ticket unblock "$uf" --by "$ua,$ux" 2>&1)"; st=$?
assert_status "refuses a --by issue under another parent" "$st" 1
assert_contains "naming it" "$out" "#$ux is not a sub-issue of #96"
assert_eq "the refusal removed no edge, not even the sibling one" \
  "$(fake_blockers_of "$uf")" "$ua $ub"
"$ORCH" ticket block "$uf" --by "$ue" >/dev/null 2>&1
out="$("$ORCH" ticket unblock "$uf" --by "$ue" 2>&1)"; st=$?
assert_status "accepts a closed blocker" "$st" 0
assert_eq "removing its edge" "$(fake_blockers_of "$uf")" "$ua $ub"

# The readback lags only after the read ahead of the write answered current.
fake_lag_after adapter_blockers 1 1 999999
out="$("$ORCH" ticket unblock "$uf" --by "$ub" 2>&1)"; st=$?
assert_status "a readback that is wrong once and right on the retry succeeds" "$st" 0
assert_eq "having removed the edge" "$(fake_blockers_of "$uf")" "$ua"
fake_lag_after adapter_blockers 1 2 999999
out="$("$ORCH" ticket unblock "$uf" --by "$ua" 2>&1)"; st=$?
assert_status "a readback that is wrong twice dies" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #$uf's blocking edges did not verify"

ug="$("$ORCH" ticket publish 96 "G" "$body")"
"$ORCH" ticket block "$ug" --by "$ua,$ub" >/dev/null 2>&1
fake_fail adapter_blocker_remove
out="$("$ORCH" ticket unblock "$ug" --by "$ua" 2>&1)"; st=$?
assert_status "a gh that refuses the edge removal fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not remove a blocking edge from ticket #$ug on #$ua"
fake_unfail
fake_fail adapter_blockers
out="$("$ORCH" ticket unblock "$ug" --by "$ua" 2>&1)"; st=$?
assert_status "a gh that cannot read the blockers fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not read ticket #$ug's blockers"
fake_unfail
fake_fail adapter_issue_state
out="$("$ORCH" ticket unblock "$ug" --by "$ua" 2>&1)"; st=$?
assert_status "a gh that cannot read the target fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not read ticket #$ug"
fake_unfail
assert_eq "none of the failures removed an edge" "$(fake_blockers_of "$ug")" "$ua $ub"

fake_fail adapter_issue_body
out="$("$ORCH" ticket unblock "$ug" --by "$ub" 2>&1)"; st=$?
assert_status "a gh that cannot read the body fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not read ticket #$ug's body"
assert_eq "the edge it removed stays removed" "$(fake_blockers_of "$ug")" "$ua"
fake_unfail
fake_fail adapter_issue_body_edit
out="$("$ORCH" ticket unblock "$ug" --by "$ub" 2>&1)"; st=$?
assert_status "a gh that cannot write the body fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not rewrite ticket #$ug's ## Blocked by section"
assert_eq "the edge stays removed" "$(fake_blockers_of "$ug")" "$ua"
fake_unfail
out="$("$ORCH" ticket unblock "$ug" --by "$ub" 2>&1)"; st=$?
assert_status "re-running after the body failures succeeds" "$st" 0
assert_eq "finishing the body" "$(fake_body_of "$ug")" "$(printf 'Build the thing.\n\n## Blocked by\n\n- #%s' "$ua")"

uh="$("$ORCH" ticket publish 96 "H" "$body")"
"$ORCH" ticket block "$uh" --by "$ua,$ub,$uc" >/dev/null 2>&1
fake_fail_after adapter_blocker_remove 1
out="$("$ORCH" ticket unblock "$uh" --by "$ua,$ub" 2>&1)"; st=$?
assert_status "a multi-edge run that dies part-way fails" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #$uh"
assert_eq "the edge it removed stays removed" "$(fake_blockers_of "$uh")" "$ub $uc"
fake_fail_after adapter_blocker_remove 1
out="$("$ORCH" ticket unblock "$uh" --by "$ua,$ub" 2>&1)"; st=$?
assert_status "re-running the same command succeeds, removing only the edge still present" "$st" 0
fake_unfail
assert_eq "leaving the other edge" "$(fake_blockers_of "$uh")" "$uc"
assert_eq "and bringing the body in line" \
  "$(fake_body_of "$uh")" "$(printf 'Build the thing.\n\n## Blocked by\n\n- #%s' "$uc")"

out="$("$ORCH" help 2>&1)"
assert_contains "ticket unblock is in the usage text" "$out" "ticket unblock <n> --by N,N,..."

restore_suite_env

# --- ticket: unknown op ------------------------------------------------------
new_repo >/dev/null
out="$("$ORCH" ticket bogus 2>&1)"; st=$?
assert_status "ticket bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown ticket op"

# --- ticket-worktree (#619) ----------------------------------------------------
# A ticket's own worktree on its own ticket branch, under the checkout's
# .orchestrator/worktrees/. Checked through what git shows afterwards -
# branches, tips, worktrees, the exclude file - never orch.sh's internals.
echo
echo "ticket-worktree"
# tw_repo: a fresh repo with a bare origin it has pushed to, on a feature
# branch, cwd inside it. Call it in the current shell: new_repo cd's.
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

tw_repo
top="$(git rev-parse --show-toplevel)"
tip="$(git rev-parse HEAD)"
out="$("$ORCH" ticket-worktree add 7)"; st=$?
assert_status "add succeeds" "$st" 0
assert_eq "add prints the worktree's absolute path" "$out" "$top/.orchestrator/worktrees/t7"
assert_eq "the worktree is a top level of its own" \
  "$(git -C "$out" rev-parse --show-toplevel)" "$top/.orchestrator/worktrees/t7"
assert_eq "it is checked out on <current-branch>--t<n>" \
  "$(git -C "$out" branch --show-current)" "orch/5-feature--t7"
assert_eq "the ticket branch forks from the current branch's tip" \
  "$(git rev-parse orch/5-feature--t7)" "$tip"
assert_eq "the forked-from branch is recorded on the ticket branch" \
  "$(git config --get branch.orch/5-feature--t7.orchestrator-ticket-parent)" "orch/5-feature"
assert_eq "the current checkout stays on its branch" "$(git branch --show-current)" "orch/5-feature"
assert_eq "add excludes .orchestrator/" "$(exclude_count .orchestrator/)" "1"
assert_eq "add excludes .scratch/" "$(exclude_count .scratch/)" "1"
assert_eq "the ticket worktree stays out of git status" "$(git status --porcelain)" ""

"$ORCH" ticket-worktree add 8 >/dev/null
assert_eq "a second add writes .orchestrator/ no second time" "$(exclude_count .orchestrator/)" "1"
assert_eq "a second add writes .scratch/ no second time" "$(exclude_count .scratch/)" "1"

out="$("$ORCH" ticket-worktree list)"; st=$?
assert_status "list succeeds" "$st" 0
assert_eq "list prints <n> <path> for each ticket worktree" "$out" \
  "$(printf '7 %s\n8 %s' "$top/.orchestrator/worktrees/t7" "$top/.orchestrator/worktrees/t8")"

out="$("$ORCH" ticket-worktree add 7 2>&1)"; st=$?
assert_status "add refuses an existing worktree" "$st" 1
assert_contains "naming it" "$out" ".orchestrator/worktrees/t7"

git worktree remove "$top/.orchestrator/worktrees/t8"
out="$("$ORCH" ticket-worktree add 8 2>&1)"; st=$?
assert_status "add refuses an existing ticket branch" "$st" 1
assert_contains "naming the branch" "$out" "orch/5-feature--t8 already exists"
assert_eq "and adds no worktree" "$([ -e .orchestrator/worktrees/t8 ] && echo present || echo absent)" "absent"
git branch -q -D orch/5-feature--t8

out="$("$ORCH" ticket-worktree add 0 2>&1)"; st=$?
assert_status "add refuses a ticket number that is not a positive integer" "$st" 1
out="$("$ORCH" ticket-worktree add 2>&1)"; st=$?
assert_status "add refuses a missing ticket number" "$st" 1

git checkout -q --detach
out="$("$ORCH" ticket-worktree add 9 2>&1)"; st=$?
assert_status "add refuses a detached HEAD" "$st" 1
git checkout -q orch/5-feature

# A failed git worktree add: .orchestrator/worktrees is a file, so no
# worktree can be made under it.
tw_repo
mkdir -p .orchestrator && : >.orchestrator/worktrees
out="$("$ORCH" ticket-worktree add 3 2>&1)"; st=$?
assert_status "add dies when the worktree cannot be added" "$st" 1
assert_eq "and leaves no ticket branch behind" \
  "$(git branch --list 'orch/5-feature--t3')" ""
assert_eq "nor its recorded parent" \
  "$(git config --get branch.orch/5-feature--t3.orchestrator-ticket-parent)" ""
assert_eq "nor any worktree" "$(git worktree list | wc -l | tr -d ' ')" "1"
assert_eq "it still wrote the exclude entry first" "$(exclude_count .orchestrator/)" "1"

tw_repo
out="$("$ORCH" ticket-worktree list)"; st=$?
assert_status "list with no ticket worktrees exits 0" "$st" 0
assert_eq "and prints nothing" "$out" ""

# From a linked worktree: the exclude entry lands in the clone's shared
# info/exclude, and the ticket worktree under the linked checkout's own top
# level; each checkout lists only its own.
tw_repo
main_top="$(git rev-parse --show-toplevel)"
linked="$(mktemp -d)/linked"
git worktree add -q -b orch/6-other "$linked"
"$ORCH" ticket-worktree add 2 >/dev/null
cd "$linked" || exit 1
out="$("$ORCH" ticket-worktree add 4)"; st=$?
assert_status "add succeeds from a linked worktree" "$st" 0
assert_eq "under the linked checkout's own top level" "$out" "$linked/.orchestrator/worktrees/t4"
assert_eq "it writes the clone's shared info/exclude" \
  "$(exclude_count .orchestrator/)" "1"
assert_eq "and keeps the linked checkout's git status clean" "$(git status --porcelain)" ""
assert_eq "the linked checkout lists only its own ticket worktree" \
  "$("$ORCH" ticket-worktree list)" "4 $linked/.orchestrator/worktrees/t4"
cd "$main_top" || exit 1
assert_eq "the main checkout ignores the linked checkout's ticket worktree" \
  "$("$ORCH" ticket-worktree list)" "2 $main_top/.orchestrator/worktrees/t2"

# remove
tw_repo
wt="$("$ORCH" ticket-worktree add 7)"
out="$("$ORCH" ticket-worktree remove 7)"; st=$?
assert_status "remove of a merged, clean ticket succeeds" "$st" 0
assert_eq "it removes the worktree" "$([ -e "$wt" ] && echo present || echo absent)" "absent"
assert_eq "and git no longer records it" "$(git worktree list | wc -l | tr -d ' ')" "1"
assert_eq "it deletes the ticket branch" "$(git branch --list 'orch/5-feature--t7')" ""
assert_eq "remove then list prints nothing" "$("$ORCH" ticket-worktree list)" ""

wt="$("$ORCH" ticket-worktree add 7)"
echo dirty >"$wt/README.md"
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove refuses a dirty worktree" "$st" 1
assert_contains "saying it is dirty" "$out" "dirty"
assert_eq "leaving the worktree in place" "$([ -f "$wt/README.md" ] && cat "$wt/README.md")" "dirty"
assert_eq "and the branch" \
  "$(git rev-parse --verify --quiet refs/heads/orch/5-feature--t7 >/dev/null && echo present)" "present"
out="$("$ORCH" ticket-worktree remove 7 --unmerged 2>&1)"; st=$?
assert_status "remove --unmerged still refuses a dirty worktree" "$st" 1
assert_eq "leaving the worktree in place" "$([ -f "$wt/README.md" ] && cat "$wt/README.md")" "dirty"
assert_eq "and the branch" \
  "$(git rev-parse --verify --quiet refs/heads/orch/5-feature--t7 >/dev/null && echo present)" "present"
git -C "$wt" checkout -q -- README.md
echo new >"$wt/untracked.txt"
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "an untracked file counts as dirty" "$st" 1
rm "$wt/untracked.txt"

git -C "$wt" commit -q --allow-empty -m "ticket work"
ticket_tip="$(git rev-parse orch/5-feature--t7)"
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove refuses an unmerged branch" "$st" 1
assert_contains "saying it is unmerged" "$out" "not merged"
assert_eq "leaving the worktree in place" "$([ -d "$wt" ] && echo present || echo absent)" "present"
assert_eq "and the branch at its tip" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
out="$("$ORCH" ticket-worktree remove 7 --unmerged)"; st=$?
assert_status "remove --unmerged discards a clean worktree's unmerged branch" "$st" 0
assert_eq "removing the worktree" "$([ -e "$wt" ] && echo present || echo absent)" "absent"
assert_eq "and the branch" "$(git branch --list 'orch/5-feature--t7')" ""

# Merged into its forked-from branch, but not into the branch the invoking
# checkout has checked out: merged is judged against the forked-from branch
# alone, so remove succeeds rather than refusing after the worktree is gone.
wt="$("$ORCH" ticket-worktree add 7)"
git -C "$wt" commit -q --allow-empty -m "ticket work"
git merge -q --ff-only orch/5-feature--t7
git checkout -q -b orch/5-elsewhere HEAD~1
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove of a ticket merged into its forked-from branch but not HEAD succeeds" "$st" 0
assert_eq "removing the worktree" "$([ -e "$wt" ] && echo present || echo absent)" "absent"
assert_eq "and the branch" "$(git branch --list 'orch/5-feature--t7')" ""
git checkout -q orch/5-feature

out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove refuses a ticket with no worktree" "$st" 1
out="$("$ORCH" ticket-worktree remove 7 --bogus 2>&1)"; st=$?
assert_status "remove refuses an unknown flag" "$st" 1
out="$("$ORCH" ticket-worktree bogus 2>&1)"; st=$?
assert_status "ticket-worktree bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown ticket-worktree op"

out="$("$ORCH" help 2>&1)"
assert_contains "ticket-worktree add is in the usage text" "$out" "ticket-worktree add <n>"
assert_contains "ticket-worktree list is in the usage text" "$out" "ticket-worktree list"
assert_contains "ticket-worktree remove is in the usage text" "$out" "ticket-worktree remove <n> [--unmerged]"
assert_contains "the CLI conventions' noun table has a ticket-worktree row" \
  "$(grep '^| `ticket-worktree`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" \
  '`add`, `list`, `remove`'
restore_suite_env

# --- side-checkout (#722) ------------------------------------------------------
# A side checkout: a worktree the plugin makes under the main checkout's
# .orchestrator/checkouts/<slug>, on no branch at origin/<base>, carrying the
# ownership marker in its own git folder. Checked through what git and the
# file system show afterwards, against a real clone of a bare origin.
echo
echo "side-checkout"
# sc_marker <path>: whether the worktree at <path> carries the ownership marker.
sc_marker() {
  if [ -f "$(git -C "$1" rev-parse --absolute-git-dir)/orchestrator-side-checkout" ]; then
    echo marked; else echo unmarked; fi
}

sc_clone
top="$(git rev-parse --show-toplevel)"
# origin's main moves on after the clone, so only a fetch lands add on its tip.
git -C "$sc_seed" commit -q --allow-empty -m "main moves on"
git -C "$sc_seed" push -q "$sc_origin" HEAD:refs/heads/main
moved_tip="$(git -C "$sc_seed" rev-parse HEAD)"
out="$(orch_gh_failing side-checkout add alpha)"; st=$?
assert_status "add succeeds" "$st" 0
assert_eq "add prints the side checkout's path" "$out" "$top/.orchestrator/checkouts/alpha"
assert_eq "the side checkout is a worktree of its own" \
  "$(git -C "$out" rev-parse --show-toplevel)" "$top/.orchestrator/checkouts/alpha"
assert_eq "on no branch" "$(git -C "$out" branch --show-current)" ""
assert_eq "at origin/<base>'s tip, freshly fetched" "$(git -C "$out" rev-parse HEAD)" "$moved_tip"
assert_eq "carrying the ownership marker" "$(sc_marker "$out")" "marked"
assert_eq "the marker is empty" \
  "$(wc -c <"$(git -C "$out" rev-parse --absolute-git-dir)/orchestrator-side-checkout" | tr -d ' ')" "0"
assert_eq "the main checkout stays on its branch" "$(git branch --show-current)" "main"
assert_eq "in a fresh clone, git status in the main checkout shows nothing new" \
  "$(git status --porcelain)" ""
assert_eq "add excludes .orchestrator/" "$(exclude_count .orchestrator/)" "1"

out="$(orch_gh_failing side-checkout add alpha 2>&1)"; st=$?
assert_status "add refuses an existing path" "$st" 1
assert_contains "naming it" "$out" "$top/.orchestrator/checkouts/alpha"
mkdir -p .orchestrator/checkouts/stray
out="$(orch_gh_failing side-checkout add stray 2>&1)"; st=$?
assert_status "add refuses a path that exists without being a worktree" "$st" 1
assert_eq "and makes no worktree there" "$(git worktree list | wc -l | tr -d ' ')" "2"
rmdir .orchestrator/checkouts/stray

# The base branch in effect, not the checkout's branch.
git -C "$sc_seed" push -q "$sc_origin" HEAD~1:refs/heads/uat
uat_tip="$(git -C "$sc_seed" rev-parse HEAD~1)"
git config orchestrator.base uat
out="$(orch_gh_failing side-checkout add on-uat)"
assert_eq "add forks from the base branch in effect" "$(git -C "$out" rev-parse HEAD)" "$uat_tip"
git worktree remove "$out"

# A failed fetch dies before any worktree exists.
git config orchestrator.base nosuch
out="$(orch_gh_failing side-checkout add nofetch 2>&1)"; st=$?
assert_status "add dies when the base branch cannot be fetched" "$st" 1
assert_contains "naming the base branch" "$out" "nosuch"
assert_eq "leaving no side checkout" "$(on_disk .orchestrator/checkouts/nofetch)" "absent"
assert_eq "nor any worktree" "$(git worktree list | wc -l | tr -d ' ')" "2"
git config --unset orchestrator.base

# A failed marker write takes the fresh worktree back out: a post-checkout hook
# makes the marker's name a directory, so no file can be written there.
writeln '#!/bin/sh' 'mkdir "$(git rev-parse --absolute-git-dir)/orchestrator-side-checkout"' 'exit 0' \
  >.git/hooks/post-checkout
chmod +x .git/hooks/post-checkout
out="$(orch_gh_failing side-checkout add nomarker 2>&1)"; st=$?
assert_status "add dies when the marker cannot be written" "$st" 1
assert_eq "leaving no side checkout" "$(on_disk .orchestrator/checkouts/nomarker)" "absent"
assert_eq "nor any worktree" "$(git worktree list | wc -l | tr -d ' ')" "2"
rm .git/hooks/post-checkout

# list: marked worktrees only, each with its flow or its branch.
out="$(orch_gh_failing side-checkout list)"; st=$?
assert_status "list succeeds" "$st" 0
assert_eq "a side checkout before a branch is made lists (no branch)" "$out" \
  "alpha $top/.orchestrator/checkouts/alpha (no branch)"
beta="$(orch_gh_failing side-checkout add beta)"
git -C "$beta" checkout -q -b quick/3-beta
gamma="$(orch_gh_failing side-checkout add gamma)"
(cd "$gamma" && orch_gh_failing init gamma-flow >/dev/null && orch_gh_failing state set issue 12)
delta="$(orch_gh_failing side-checkout add delta)"
(cd "$delta" && orch_gh_failing init delta-flow >/dev/null)
# Neither a hand-made worktree, even one holding a flow, nor a ticket worktree
# is a side checkout.
hand="$(mktemp -d)/hand"
git worktree add -q -b hand "$hand"
(cd "$hand" && orch_gh_failing init hand-flow >/dev/null)
orch_gh_failing ticket-worktree add 4 >/dev/null
# git lists linked worktrees in no fixed order, so the lines are sorted.
out="$(orch_gh_failing side-checkout list | sort)"
assert_eq "list prints each side checkout's flow, branch, or (no branch)" "$out" \
  "$(writeln "alpha $top/.orchestrator/checkouts/alpha (no branch)" \
             "beta $top/.orchestrator/checkouts/beta branch quick/3-beta" \
             "delta $top/.orchestrator/checkouts/delta flow delta-flow spec (no issue)" \
             "gamma $top/.orchestrator/checkouts/gamma flow gamma-flow spec #12")"
assert_not_contains "never a hand-made worktree" "$out" "$hand"
assert_not_contains "never a ticket worktree" "$out" "worktrees/t4"
assert_eq "from a side checkout, list prints the same" "$(cd "$beta" && orch_gh_failing side-checkout list | sort)" "$out"
assert_eq "add from a side checkout still nests under the main checkout" \
  "$(cd "$beta" && orch_gh_failing side-checkout add epsilon)" "$top/.orchestrator/checkouts/epsilon"
git worktree remove "$top/.orchestrator/checkouts/epsilon"
orch_gh_failing ticket-worktree remove 4 --unmerged
assert_eq "git status in the main checkout still shows nothing new" "$(git status --porcelain)" ""

# archive and init over a done flow in the main checkout skip checkouts/.
orch_gh_failing init main-flow >/dev/null
dest="$(orch_gh_failing archive)"; st=$?
assert_status "archive in the main checkout succeeds beside side checkouts" "$st" 0
assert_eq "it moves no side checkout into the archive" "$(on_disk "$dest/checkouts")" "absent"
assert_eq "checkouts/ stays in place" "$(on_disk .orchestrator/checkouts/alpha)" "present"
assert_eq "each side checkout stays where git recorded it" \
  "$(git -C .orchestrator/checkouts/gamma rev-parse --show-toplevel)" "$top/.orchestrator/checkouts/gamma"
assert_eq "with its flow untouched" "$(cd "$gamma" && orch_gh_failing state get slug)" "gamma-flow"
orch_gh_failing init done-flow >/dev/null
state_fixture phase "done"
out="$(orch_gh_failing init next-flow)"; st=$?
assert_status "init over a done flow succeeds beside side checkouts" "$st" 0
archived="$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "it archives no side checkout" "$(on_disk "$archived/checkouts")" "absent"
assert_eq "each side checkout stays where git recorded it" \
  "$(git -C .orchestrator/checkouts/beta branch --show-current)" "quick/3-beta"
assert_eq "and side-checkout list is unchanged" "$(orch_gh_failing side-checkout list | wc -l | tr -d ' ')" "4"

out="$(orch_gh_failing side-checkout add 2>&1)"; st=$?
assert_status "add refuses a missing slug" "$st" 1
out="$(orch_gh_failing side-checkout list extra 2>&1)"; st=$?
assert_status "list refuses arguments" "$st" 1
out="$(orch_gh_failing side-checkout bogus 2>&1)"; st=$?
assert_status "side-checkout bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown side-checkout op"
out="$(orch_gh_failing help 2>&1)"
assert_contains "side-checkout add is in the usage text" "$out" "side-checkout add <slug>"
assert_contains "side-checkout list is in the usage text" "$out" "side-checkout list"
assert_contains "the CLI conventions' noun table has a side-checkout row" \
  "$(grep '^| `side-checkout`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`add`, `list`'
restore_suite_env

# --- status lists every checkout (#725) ----------------------------------------
# status keeps its full detail on this checkout's flow, then lists one line
# for every other checkout holding a flow, and every side checkout without
# one. Checked through status's output against real worktrees of a clone.
echo
echo "status lists every checkout"
# st_others: the lines status prints under "other checkouts:", sorted - git
# lists linked worktrees in no fixed order.
st_others() { sed -n '/^other checkouts:$/,$p' | sed 1d | sort; }

sc_clone
top="$(git rev-parse --show-toplevel)"
out="$(orch_gh_failing status)"
assert_eq "with no flow and no other checkout, status prints only the no-flow line" \
  "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
assert_contains "and that line is the no-flow line" "$out" "No active flow."
orch_gh_failing init main-flow >/dev/null
orch_gh_failing state set issue 7
alone="$(orch_gh_failing status)"
assert_not_contains "with no other checkout, status lists none" "$alone" "other checkouts"
# Ticket worktrees hold no flow and carry no marker.
orch_gh_failing ticket-worktree add 4 >/dev/null
assert_eq "a ticket worktree never appears" "$(orch_gh_failing status)" "$alone"

alpha="$(orch_gh_failing side-checkout add alpha)"
beta="$(orch_gh_failing side-checkout add beta)"
git -C "$beta" checkout -q -b quick/3-beta
gamma="$(orch_gh_failing side-checkout add gamma)"
(cd "$gamma" && orch_gh_failing init gamma-flow >/dev/null && orch_gh_failing state set issue 12)
hand="$(mktemp -d)/hand"
git worktree add -q -b hand "$hand"
(cd "$hand" && orch_gh_failing init hand-flow >/dev/null)
# A hand-made worktree with no flow is not the plugin's to list.
bare_hand="$(mktemp -d)/bare-hand"
git worktree add -q -b bare-hand "$bare_hand"

out="$(orch_gh_failing status)"; st=$?
assert_status "status in the main checkout succeeds" "$st" 0
assert_eq "it keeps its full detail on this checkout's flow" \
  "$(printf '%s\n' "$out" | sed '/^other checkouts:$/,$d')" "$alone"
assert_eq "it lists each side checkout and each hand-made worktree holding a flow" \
  "$(printf '%s\n' "$out" | st_others)" \
  "$(writeln "  $alpha (no branch)" \
             "  $beta branch quick/3-beta" \
             "  $gamma flow gamma-flow spec #12" \
             "  $hand flow hand-flow spec (no issue)" | sort)"
assert_not_contains "never a hand-made worktree without a flow" "$out" "$bare_hand"
assert_not_contains "never a ticket worktree" "$out" "worktrees/t4"

out="$(cd "$gamma" && orch_gh_failing status)"
assert_contains "status in a side checkout shows its own flow in full" "$out" "flow:      gamma-flow"
assert_contains "with its own issue" "$out" "issue:     12"
assert_eq "and lists the others, the main checkout's flow among them" \
  "$(printf '%s\n' "$out" | st_others)" \
  "$(writeln "  $top flow main-flow spec #7" \
             "  $alpha (no branch)" \
             "  $beta branch quick/3-beta" \
             "  $hand flow hand-flow spec (no issue)" | sort)"

orch_gh_failing ticket-worktree remove 4 --unmerged
orch_gh_failing archive >/dev/null
out="$(orch_gh_failing status)"
assert_eq "with no flow here, status prints No active flow. first" \
  "$(printf '%s\n' "$out" | sed -n 1p | cut -c1-15)" "No active flow."
assert_eq "and still lists the others" "$(printf '%s\n' "$out" | st_others | wc -l | tr -d ' ')" "4"

# A quick implementation in the main checkout keeps no state and carries no
# marker, so it never appears.
git checkout -q -b quick/9-main
out="$(cd "$beta" && orch_gh_failing status)"
assert_not_contains "a quick implementation in the main checkout never appears" "$out" "$top "
assert_not_contains "nor its branch" "$out" "quick/9-main"
restore_suite_env

# --- side-checkout archive and remove (#724) -----------------------------------
# git worktree remove deletes ignored files, .orchestrator/ included, so a side
# checkout's flow is archived into the main checkout before its worktree goes.
# Checked through the archive and worktrees left on disk, and the output.
echo
echo "side-checkout archive and remove"

sc_clone
top="$(git rev-parse --show-toplevel)"

# archive in a clean side checkout, run from inside it.
alpha="$(orch_gh_failing side-checkout add alpha)"
(cd "$alpha" && orch_gh_failing init alpha-flow >/dev/null)
complete_plan_handoff "$(cd "$alpha" && orch_gh_failing handoff path spec)"
out="$(cd "$alpha" && orch_gh_failing archive 2>&1)"; st=$?
assert_status "archive in a clean side checkout succeeds" "$st" 0
assert_eq "it leaves the archive in the main checkout's .orchestrator/archive/" \
  "$(archived_count "$top" alpha-flow)" "1"
assert_eq "with the flow's handoffs in it" \
  "$(on_disk "$(find "$top/.orchestrator/archive" -maxdepth 1 -name '*-alpha-flow')/handoff/01-plan.md")" "present"
assert_contains "it prints the archive's full path" "$out" "$top/.orchestrator/archive/"
assert_eq "the worktree is gone from disk" "$(on_disk "$alpha")" "absent"
assert_not_contains "and from git's list" "$(git worktree list)" "$alpha"
assert_contains "it tells the human to close the session" "$out" "close this session"

# archive in a dirty side checkout: the archive succeeds, the worktree stays.
beta="$(orch_gh_failing side-checkout add beta)"
(cd "$beta" && orch_gh_failing init beta-flow >/dev/null)
echo wip >"$beta/wip.txt"
out="$(cd "$beta" && orch_gh_failing archive 2>&1)"; st=$?
assert_status "archive in a dirty side checkout succeeds" "$st" 0
assert_eq "it archives into the main checkout" "$(archived_count "$top" beta-flow)" "1"
assert_eq "and leaves the worktree in place" "$(on_disk "$beta/wip.txt")" "present"
assert_contains "reporting why it was kept" "$out" "kept side checkout $beta"
assert_contains "naming the remove command" "$out" "side-checkout remove beta"
assert_not_contains "and never tells the human to close the session" "$out" "close this session"
assert_eq "no flow is left in it" "$(on_disk "$beta/.orchestrator/state.json")" "absent"

# init over a done flow in a side checkout archives to the main checkout and
# keeps the worktree, where the new flow lives.
gamma="$(orch_gh_failing side-checkout add gamma)"
(cd "$gamma" && orch_gh_failing init old-flow >/dev/null && state_fixture phase "done")
out="$(cd "$gamma" && orch_gh_failing init new-flow 2>&1)"; st=$?
assert_status "init over a done flow in a side checkout succeeds" "$st" 0
assert_eq "it archives the old flow into the main checkout" "$(archived_count "$top" old-flow)" "1"
assert_eq "and nothing into the side checkout's own archive" \
  "$(on_disk "$gamma/.orchestrator/archive")" "absent"
assert_eq "the worktree stays" "$(git -C "$gamma" rev-parse --show-toplevel)" "$gamma"
assert_eq "holding the new flow" "$(cd "$gamma" && orch_gh_failing state get slug)" "new-flow"

# archive in a hand-made worktree archives in place and leaves it.
hand="$(mktemp -d)/hand"
git worktree add -q -b hand "$hand"
(cd "$hand" && orch_gh_failing init hand-flow >/dev/null)
out="$(cd "$hand" && orch_gh_failing archive 2>&1)"; st=$?
assert_status "archive in a hand-made worktree succeeds" "$st" 0
assert_eq "it archives in place" "$(archived_count "$hand" hand-flow)" "1"
assert_eq "not into the main checkout" "$(archived_count "$top" hand-flow)" "0"
assert_eq "the worktree stays" "$(git -C "$hand" rev-parse --show-toplevel)" "$hand"
assert_not_contains "with no removal reported" "$out" "side checkout"

# side-checkout remove: every refusal before anything moves.
out="$(orch_gh_failing side-checkout remove nosuch 2>&1)"; st=$?
assert_status "remove refuses an unknown slug" "$st" 1
assert_contains "naming it" "$out" "no side checkout nosuch"
unmarked="$top/.orchestrator/checkouts/unmarked"
git worktree add -q --detach "$unmarked"
(cd "$unmarked" && orch_gh_failing init unmarked-flow >/dev/null)
out="$(orch_gh_failing side-checkout remove unmarked 2>&1)"; st=$?
assert_status "remove refuses a worktree without the marker" "$st" 1
assert_contains "saying it is left alone" "$out" "left alone"
assert_eq "its flow is not moved" "$(on_disk "$unmarked/.orchestrator/state.json")" "present"
assert_eq "nor its worktree removed" "$(on_disk "$unmarked")" "present"
(cd "$gamma" && git checkout -q -b quick/5-gamma)
echo wip >"$gamma/wip.txt"
out="$(orch_gh_failing side-checkout remove gamma 2>&1)"; st=$?
assert_status "remove refuses untracked files" "$st" 1
assert_contains "naming the side checkout" "$out" "$gamma"
assert_eq "its flow is not moved" "$(archived_count "$top" new-flow)" "0"
rm "$gamma/wip.txt"
echo changed >>"$gamma/$(git -C "$gamma" ls-files | head -1)"
out="$(orch_gh_failing side-checkout remove gamma 2>&1)"; st=$?
assert_status "remove refuses uncommitted changes" "$st" 1
assert_eq "its flow is not moved" "$(archived_count "$top" new-flow)" "0"
git -C "$gamma" checkout -q -- .
# A git status that cannot run is a refusal naming git's error, never a clean
# tree.
gidx="$(git -C "$gamma" rev-parse --absolute-git-dir)/index"
cp "$gidx" "$gidx.bak"
printf 'garbage' >"$gidx"
out="$(orch_gh_failing side-checkout remove gamma 2>&1)"; st=$?
mv "$gidx.bak" "$gidx"
assert_status "remove refuses when git status cannot run" "$st" 1
assert_contains "naming git's error" "$out" "git status failed - cannot check the working tree: "
assert_eq "its flow is not moved" "$(archived_count "$top" new-flow)" "0"
assert_eq "nor its worktree removed" "$(on_disk "$gamma")" "present"

# remove archives the flow into the main checkout, removes the worktree, and
# keeps the branch.
out="$(orch_gh_failing side-checkout remove gamma 2>&1)"; st=$?
assert_status "remove succeeds on a clean side checkout" "$st" 0
assert_eq "it archives the flow into the main checkout" "$(archived_count "$top" new-flow)" "1"
assert_eq "the worktree is gone" "$(on_disk "$gamma")" "absent"
assert_not_contains "and from git's list" "$(git worktree list)" "$gamma"
assert_eq "the branch is kept" \
  "$(git rev-parse --verify --quiet refs/heads/quick/5-gamma >/dev/null && echo kept || echo gone)" "kept"
assert_not_contains "run from the main checkout, no close-the-session message" "$out" "close this session"

# remove of a side checkout holding no flow, run from inside it.
delta="$(orch_gh_failing side-checkout add delta)"
out="$(cd "$delta" && orch_gh_failing side-checkout remove delta 2>&1)"; st=$?
assert_status "remove from inside the side checkout succeeds" "$st" 0
assert_eq "the worktree is gone" "$(on_disk "$delta")" "absent"
assert_contains "and the session is told to close" "$out" "close this session"

# A failing git worktree remove: the archive stands, and remove exits 1. A
# locked worktree is one git refuses to remove without force.
eps="$(orch_gh_failing side-checkout add eps)"
(cd "$eps" && orch_gh_failing init eps-flow >/dev/null)
git worktree lock "$eps"
out="$(orch_gh_failing side-checkout remove eps 2>&1)"; st=$?
assert_status "remove exits 1 when the worktree cannot be removed" "$st" 1
assert_contains "reporting the failure" "$out" "could not remove side checkout $eps"
assert_eq "the archive stands" "$(archived_count "$top" eps-flow)" "1"
assert_eq "the worktree stays" "$(on_disk "$eps")" "present"
git worktree unlock "$eps"

out="$(orch_gh_failing side-checkout remove 2>&1)"; st=$?
assert_status "remove refuses a missing slug" "$st" 1
assert_contains "side-checkout remove is in the usage text" "$(orch_gh_failing help)" "side-checkout remove <slug>"
restore_suite_env

# --- side-checkout prune (#726) -----------------------------------------------
# The finished sweep behind /orchestrator:finish: a side checkout whose PR
# GitHub reports merged into its base, whose tree is clean, and whose flow -
# if any - is at done, is archived into the main checkout, removed, and its
# local branch deleted. Checked through the worktrees, branches and archives
# left on disk, and the report, against the store-backed GitHub fake.
echo
echo "side-checkout prune"
sp_branch() { if git rev-parse --verify --quiet "refs/heads/$1" >/dev/null; then echo kept; else echo gone; fi; }
# sp_branch_off <path> <branch>: puts the side checkout at <path> on a new
# branch with one commit of its own, never merged into main locally - as a
# squash merge on GitHub leaves it.
sp_branch_off() {
  git -C "$1" checkout -q -b "$2"
  git -C "$1" commit -q --allow-empty -m "work on $2"
}

sc_clone
fake_github
top="$(git rev-parse --show-toplevel)"
# Offline while arranging, so each add's own sweep leaves the arrangement be.
fake_offline

# A finished flow side checkout, its PR squash-merged.
fl="$(orch_gh_failing side-checkout add fl)"
(cd "$fl" && orch_gh_failing init fl-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/fl-flow && state_fixture pr 41)
sp_branch_off "$fl" orch/fl-flow
fake_pr 41 merged orch/fl-flow main
# A finished quick-implementation side checkout.
qk="$(orch_gh_failing side-checkout add qk)"
sp_branch_off "$qk" quick/7-qk
fake_pr 42 merged quick/7-qk main
# An open PR.
op="$(orch_gh_failing side-checkout add op)"
sp_branch_off "$op" quick/8-op
fake_pr 43 open quick/8-op main
# A dirty tree, its PR merged.
dt="$(orch_gh_failing side-checkout add dt)"
sp_branch_off "$dt" quick/9-dt
fake_pr 44 merged quick/9-dt main
echo wip >"$dt/wip.txt"
# A flow not at done.
nd="$(orch_gh_failing side-checkout add nd)"
(cd "$nd" && orch_gh_failing init nd-flow >/dev/null && state_fixture phase implement)
# A finished side checkout whose PR was a true merge: its branch is an
# ancestor of main.
tm="$(orch_gh_failing side-checkout add tm)"
sp_branch_off "$tm" quick/17-tm
git merge -q --no-ff --no-edit quick/17-tm
fake_pr 56 merged quick/17-tm main
# A side checkout still on no branch.
nb="$(orch_gh_failing side-checkout add nb)"
# The main checkout's own finished flow.
orch_gh_failing init main-flow >/dev/null
git checkout -q -b orch/main-flow
state_fixture phase "done"; state_fixture branch orch/main-flow; state_fixture pr 45
fake_pr 45 merged orch/main-flow main
# A hand-made worktree holding a finished flow.
hand="$(mktemp -d)/hand"
git worktree add -q -b orch/hand-flow "$hand" main
(cd "$hand" && orch_gh_failing init hand-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/hand-flow && state_fixture pr 46)
fake_pr 46 merged orch/hand-flow main

# GitHub unreachable: nothing is removed.
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune fails when GitHub cannot be read" "$st" 1
assert_contains "saying nothing was removed" "$out" "nothing was removed"
assert_contains "reporting the first unreadable checkout with its reason" "$out" "could not check $fl: could not read GitHub"
assert_contains "and the second, not only the last" "$out" "could not check $qk: could not read GitHub"
assert_eq "the finished flow side checkout stays" "$(on_disk "$fl")" "present"
assert_eq "the finished quick side checkout stays" "$(on_disk "$qk")" "present"
assert_eq "its branch stays" "$(sp_branch quick/7-qk)" "kept"
assert_eq "the main checkout's flow is not archived" "$(on_disk "$top/.orchestrator/state.json")" "present"
fake_online

out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune succeeds" "$st" 0
assert_eq "the finished flow side checkout is gone" "$(on_disk "$fl")" "absent"
assert_not_contains "and from git's list" "$(git worktree list)" "$fl"
assert_eq "its flow archived into the main checkout" "$(archived_count "$top" fl-flow)" "1"
assert_eq "its squash-merged local branch is gone" "$(sp_branch orch/fl-flow)" "gone"
assert_eq "the finished quick side checkout is gone" "$(on_disk "$qk")" "absent"
assert_eq "its local branch is gone" "$(sp_branch quick/7-qk)" "gone"
assert_eq "the true-merged side checkout is gone" "$(on_disk "$tm")" "absent"
assert_eq "its merged local branch is gone" "$(sp_branch quick/17-tm)" "gone"
assert_contains "the removals are reported" "$out" "removed side checkout $qk"
assert_eq "an open PR's side checkout stays" "$(on_disk "$op")" "present"
assert_contains "skipped with its reason" "$out" "skipped $op: no merged PR from quick/8-op into main"
assert_eq "a dirty side checkout stays" "$(on_disk "$dt/wip.txt")" "present"
assert_eq "with its branch" "$(sp_branch quick/9-dt)" "kept"
assert_contains "skipped with its reason" "$out" "skipped $dt: uncommitted changes or untracked files"
assert_eq "a flow not at done stays" "$(on_disk "$nd/.orchestrator/state.json")" "present"
assert_contains "skipped with its reason" "$out" "skipped $nd: flow nd-flow is at implement, not done"
assert_eq "a side checkout on no branch stays" "$(on_disk "$nb")" "present"
assert_contains "skipped with its reason" "$out" "skipped $nb: no branch"
assert_eq "the main checkout's finished flow is archived in place" "$(archived_count "$top" main-flow)" "1"
assert_eq "its state is gone" "$(on_disk "$top/.orchestrator/state.json")" "absent"
assert_eq "its branch is still checked out" "$(git branch --show-current)" "orch/main-flow"
assert_contains "which is reported" "$out" "orch/main-flow is still checked out"
assert_eq "the live side checkouts were not moved by that archive" "$(on_disk "$op")" "present"
assert_eq "a hand-made worktree's flow is untouched" "$(on_disk "$hand/.orchestrator/state.json")" "present"
assert_eq "and the worktree stays" "$(on_disk "$hand")" "present"
assert_eq "with its branch" "$(sp_branch orch/hand-flow)" "kept"
assert_contains "reported as left alone" "$out" "$hand: not a side checkout, left alone"

# A failure after the archive is reported, that checkout stays, and the sweep
# moves on. A locked worktree is one git refuses to remove without force.
fake_offline
lk="$(orch_gh_failing side-checkout add lk)"
(cd "$lk" && orch_gh_failing init lk-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/lk-flow && state_fixture pr 47)
sp_branch_off "$lk" orch/lk-flow
fake_pr 47 merged orch/lk-flow main
git worktree lock "$lk"
q2="$(orch_gh_failing side-checkout add q2)"
sp_branch_off "$q2" quick/10-q2
fake_pr 48 merged quick/10-q2 main
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune exits 1 when a removal fails" "$st" 1
assert_contains "reporting the failure" "$out" "could not remove side checkout $lk"
assert_eq "the archive stands" "$(archived_count "$top" lk-flow)" "1"
assert_eq "the locked worktree stays" "$(on_disk "$lk")" "present"
assert_eq "with its branch" "$(sp_branch orch/lk-flow)" "kept"
assert_eq "the sweep moves on to the next" "$(on_disk "$q2")" "absent"
git worktree unlock "$lk"

# Each removal reports only its own archive: a flowless side checkout swept
# right after the main checkout's finished flow does not repeat that archive.
fake_offline
orch_gh_failing init main-again >/dev/null
state_fixture phase "done"; state_fixture branch orch/main-flow; state_fixture pr 51
fake_pr 51 merged orch/main-flow main
q5="$(orch_gh_failing side-checkout add q5)"
sp_branch_off "$q5" quick/13-q5
fake_pr 52 merged quick/13-q5 main
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune succeeds over the main flow and a flowless side checkout" "$st" 0
assert_eq "the flowless side checkout is gone" "$(on_disk "$q5")" "absent"
assert_eq "the main checkout's archive is reported once" \
  "$(printf '%s\n' "$out" | grep -c -- '-main-again$')" "1"

# A side checkout whose git status cannot run is never called finished: prune
# removes nothing, naming git's error.
fake_offline
q6="$(orch_gh_failing side-checkout add q6)"
sp_branch_off "$q6" quick/14-q6
fake_pr 53 merged quick/14-q6 main
fake_online
q6idx="$(git -C "$q6" rev-parse --absolute-git-dir)/index"
cp "$q6idx" "$q6idx.bak"
printf 'garbage' >"$q6idx"
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
mv "$q6idx.bak" "$q6idx"
assert_status "prune fails when a side checkout's git status cannot run" "$st" 1
assert_contains "naming git's error" "$out" "git status failed - cannot check the working tree: "
assert_contains "and that nothing was removed" "$out" "nothing was removed"
assert_eq "the side checkout stays" "$(on_disk "$q6")" "present"
assert_eq "with its branch" "$(sp_branch quick/14-q6)" "kept"
orch_gh_failing side-checkout prune >/dev/null 2>&1

# A quick implementation is finished by a PR into the base branch off recorded
# for it, not the base in effect now.
git push -q origin main:refs/heads/uat
fake_offline
orch_gh_failing base set uat >/dev/null
rb="$(orch_gh_failing side-checkout add rb)"
(cd "$rb" && orch_gh_failing branch off quick/15-rb >/dev/null)
git -C "$rb" commit -q --allow-empty -m "work on rb"
rm2="$(orch_gh_failing side-checkout add rm2)"
(cd "$rm2" && orch_gh_failing branch off quick/16-rm2 >/dev/null)
git -C "$rm2" commit -q --allow-empty -m "work on rm2"
orch_gh_failing base set main >/dev/null
fake_pr 54 merged quick/15-rb uat
fake_pr 55 merged quick/16-rm2 main
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune succeeds after the base setting moved" "$st" 0
assert_eq "a PR merged into the recorded base finishes its side checkout" "$(on_disk "$rb")" "absent"
assert_eq "a PR merged into the base in effect now, not the recorded one, does not" \
  "$(on_disk "$rm2")" "present"
assert_contains "skipped naming the recorded base" "$out" "skipped $rm2: no merged PR from quick/16-rm2 into uat"

# side-checkout add runs the sweep first.
q3="$(orch_gh_failing side-checkout add q3)"
sp_branch_off "$q3" quick/11-q3
fake_pr 49 merged quick/11-q3 main
out="$(orch_gh_failing side-checkout add after 2>/dev/null)"; st=$?
assert_status "add succeeds after its sweep" "$st" 0
assert_eq "printing only the new path on stdout" "$out" "$top/.orchestrator/checkouts/after"
assert_eq "the sweep removed the finished side checkout" "$(on_disk "$q3")" "absent"
# ... and carries on when the sweep fails.
q4="$(orch_gh_failing side-checkout add q4)"
sp_branch_off "$q4" quick/12-q4
fake_pr 50 merged quick/12-q4 main
fake_offline
out="$(orch_gh_failing side-checkout add after2 2>&1)"; st=$?
assert_status "add carries on when its sweep fails" "$st" 0
assert_contains "reporting the failed sweep" "$out" "the finished sweep failed"
assert_eq "making the side checkout" "$(on_disk "$top/.orchestrator/checkouts/after2")" "present"
assert_eq "and removing nothing" "$(on_disk "$q4")" "present"
fake_online

out="$(orch_gh_failing side-checkout prune extra 2>&1)"; st=$?
assert_status "prune takes no arguments" "$st" 1
assert_contains "side-checkout prune is in the usage text" "$(orch_gh_failing help)" "side-checkout prune"
assert_contains "the CLI conventions' noun table names prune" \
  "$(grep '^| `side-checkout`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`prune`'
restore_suite_env

# --- doctor --env: finished side checkouts (#727) -----------------------------
# A finished side checkout left standing is a leftover, so doctor --env warns
# on each one - never a FAIL - with the exact remove command, and says nothing
# for one still in use. The finished test is the sweep's own; GitHub
# unreachable skips the check into the GitHub skipped warn.
echo
echo "doctor --env finished side checkouts"
sc_clone
doctor_github
mkdir -p docs/agents
labels_doc docs/agents/triage-labels.md
gh_fixture
export CLAUDE_PLUGIN_ROOT="$PWD"
HOME="$(mktemp -d)"; export HOME
fake_offline
dfin="$(orch_gh_failing side-checkout add dfin 2>/dev/null)"
git -C "$dfin" checkout -q -b quick/20-dfin
git -C "$dfin" commit -q --allow-empty -m "work on dfin"
fake_pr 60 merged quick/20-dfin main
dopen="$(orch_gh_failing side-checkout add dopen 2>/dev/null)"
git -C "$dopen" checkout -q -b quick/21-dopen
git -C "$dopen" commit -q --allow-empty -m "work on dopen"
fake_pr 61 open quick/21-dopen main
dflow="$(orch_gh_failing side-checkout add dflow 2>/dev/null)"
(cd "$dflow" && orch_gh_failing init dflow-flow >/dev/null \
  && git checkout -q -b orch/dflow-flow \
  && state_fixture phase "done" && state_fixture branch orch/dflow-flow && state_fixture pr 62)
fake_pr 62 merged orch/dflow-flow main
dnd="$(orch_gh_failing side-checkout add dnd 2>/dev/null)"
(cd "$dnd" && orch_gh_failing init dnd-flow >/dev/null && state_fixture phase implement)
fake_online
git remote set-url origin https://github.com/acme/widgets.git

out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "doctor --env passes with finished side checkouts standing" "$st" 0
assert_contains "warns on a finished quick side checkout" "$out" "warn  side checkout dfin is finished"
assert_contains "naming the exact remove command" "$out" \
  "$(printf '\n      orch.sh side-checkout remove dfin')"
assert_contains "warns on a finished flow side checkout" "$out" "warn  side checkout dflow is finished"
assert_contains "naming its remove command" "$out" "orch.sh side-checkout remove dflow"
assert_not_contains "says nothing for an open PR's side checkout" "$out" "side checkout dopen"
assert_not_contains "says nothing for a flow not at done" "$out" "side checkout dnd"
assert_contains "and prints no FAIL" "$(printf '%s\n' "$out" | tail -1)" " 0 FAIL"
out_in="$(cd "$dopen" && "$ORCH" doctor --env 2>&1)"
assert_contains "warns the same from inside a side checkout" "$out_in" "orch.sh side-checkout remove dfin"

fake_offline
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "doctor --env passes when GitHub is unreachable" "$st" 0
assert_not_contains "printing no FAIL line" "$out" "FAIL  "
assert_contains "and a FAIL count of zero" "$(printf '%s\n' "$out" | tail -1)" " 0 FAIL"
assert_not_contains "and no finished warning it could not check" "$out" "is finished"
assert_contains "counting the check in the GitHub skipped warn" "$out" "GitHub checks skipped: GitHub is not reachable"
skip_n() { printf '%s\n' "$1" | sed -n 's/^warn  \([0-9]*\) GitHub checks\{0,1\} skipped.*/\1/p'; }
with_n="$(skip_n "$out")"
for p in "$dfin" "$dopen" "$dflow" "$dnd"; do git worktree remove --force "$p"; done
without_n="$(skip_n "$("$ORCH" doctor --env 2>&1)")"
assert_eq "as one more skipped check than with no side checkouts" "$with_n" "$((without_n + 1))"
fake_online
restore_suite_env

# --- review ready's pointer to /orchestrator:finish (#727) ---------------------
# review ready's stdout stays the PR number alone everywhere; in a side
# checkout it points the human at /orchestrator:finish on stderr, for after the
# PR merges.
echo
echo "review ready's finish pointer"
sc_clone
fake_github
top="$(git rev-parse --show-toplevel)"
fake_offline
rr="$(orch_gh_failing side-checkout add rr 2>/dev/null)"
fake_online
(cd "$rr" && orch_gh_failing init rr-flow >/dev/null && state_fixture phase review && state_fixture pr 70)
fake_pr 70 open orch/rr-flow main
fake_pr_draft 70
err_f="$(mktemp)"
out="$(cd "$rr" && orch_gh_failing review ready 2>"$err_f")"; st=$?
assert_status "review ready succeeds in a side checkout" "$st" 0
assert_eq "printing only the PR number on stdout" "$out" "70"
assert_contains "pointing at /orchestrator:finish on stderr" "$(cat "$err_f")" "/orchestrator:finish"

orch_gh_failing init rr-main >/dev/null
state_fixture phase review; state_fixture pr 71
fake_pr 71 open orch/rr-main main
fake_pr_draft 71
out="$(orch_gh_failing review ready 2>"$err_f")"; st=$?
assert_status "review ready succeeds in the main checkout" "$st" 0
assert_eq "printing only the PR number on stdout there too" "$out" "71"
assert_not_contains "with no /orchestrator:finish pointer" "$(cat "$err_f")" "/orchestrator:finish"
restore_suite_env

# --- ticket merge (#621) -------------------------------------------------------
# Lands a ticket branch on the branch it was forked from: rebase inside the
# ticket worktree, then fast-forward the forked-from branch wherever it is
# checked out. Checked through branches, tips and exit status.
echo
echo "ticket merge"
# tm_commit <dir> <file> <content>: commit <content> to <file> in <dir>.
tm_commit() { echo "$3" >"$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -qm "$2: $3"; }
# tm_rebasing <dir>: "yes" when a rebase is in progress in <dir>'s checkout.
tm_rebasing() {
  local d
  for d in rebase-merge rebase-apply; do
    [ ! -e "$(git -C "$1" rev-parse --git-path "$d")" ] || { echo yes; return; }
  done
  echo no
}

tw_repo
wt="$("$ORCH" ticket-worktree add 7)"
tm_commit "$wt" ticket.txt one
tm_commit "$wt" ticket2.txt two
tm_commit . other.txt landed-first
flow_tip="$(git rev-parse orch/5-feature)"
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge of a clean ticket succeeds" "$st" 0
assert_eq "the forked-from branch now holds the ticket's commits" \
  "$(git log --format=%s orch/5-feature -3 | tr '\n' '|')" "ticket2.txt: two|ticket.txt: one|other.txt: landed-first|"
assert_eq "on top of its prior tip" "$(git rev-parse orch/5-feature~2)" "$flow_tip"
assert_eq "with no merge commit" "$(git rev-list --merges orch/5-feature | wc -l | tr -d ' ')" "0"
assert_eq "the forked-from branch's tip is the ticket branch's" \
  "$(git rev-parse orch/5-feature)" "$(git rev-parse orch/5-feature--t7)"
assert_eq "its checkout's working tree is updated too" "$(cat ticket2.txt)" "two"
assert_eq "and left clean" "$(git status --porcelain)" ""
out="$("$ORCH" ticket-worktree remove 7)"; st=$?
assert_status "a merged ticket's worktree then removes without --unmerged" "$st" 0

# Conflict: both sides change the same line.
tw_repo
wt="$("$ORCH" ticket-worktree add 7)"
tm_commit "$wt" feature.txt from-ticket
tm_commit . feature.txt from-flow
flow_tip="$(git rev-parse orch/5-feature)"
ticket_tip="$(git rev-parse orch/5-feature--t7)"
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge exits 3 on a rebase conflict" "$st" 3
assert_contains "saying it conflicted" "$out" "conflict"
assert_eq "the forked-from branch stays at its prior tip" "$(git rev-parse orch/5-feature)" "$flow_tip"
assert_eq "the ticket branch stays at its prior tip" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
assert_eq "no rebase is left in progress" "$(tm_rebasing "$wt")" "no"
assert_eq "the ticket worktree is left clean" "$(git -C "$wt" status --porcelain)" ""
assert_eq "and the flow's checkout too" "$(git status --porcelain)" ""

# Refusals: each exits 1 and changes nothing.
tw_repo
wt="$("$ORCH" ticket-worktree add 7)"
tm_commit "$wt" ticket.txt one
tm_commit . other.txt landed-first
flow_tip="$(git rev-parse orch/5-feature)"
ticket_tip="$(git rev-parse orch/5-feature--t7)"
echo dirty >"$wt/README.md"
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge refuses a dirty ticket worktree" "$st" 1
assert_contains "naming it dirty" "$out" "dirty"
assert_eq "leaving the forked-from branch" "$(git rev-parse orch/5-feature)" "$flow_tip"
assert_eq "and the ticket branch" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
assert_eq "and the ticket worktree's change" "$(cat "$wt/README.md")" "dirty"
git -C "$wt" checkout -q -- README.md

echo dirty >README.md
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge refuses a dirty forked-from checkout" "$st" 1
assert_contains "naming it dirty" "$out" "dirty"
assert_eq "leaving the forked-from branch" "$(git rev-parse orch/5-feature)" "$flow_tip"
assert_eq "and the ticket branch" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
assert_eq "and the checkout's change" "$(cat README.md)" "dirty"
git checkout -q -- README.md

git checkout -q --detach
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge refuses a forked-from branch checked out nowhere" "$st" 1
assert_contains "naming the branch" "$out" "orch/5-feature"
assert_eq "leaving the forked-from branch" "$(git rev-parse orch/5-feature)" "$flow_tip"
assert_eq "and the ticket branch" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
git checkout -q orch/5-feature

out="$("$ORCH" ticket merge 9 2>&1)"; st=$?
assert_status "merge refuses a ticket with no ticket worktree" "$st" 1
out="$("$ORCH" ticket merge 2>&1)"; st=$?
assert_status "merge refuses a missing ticket number" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket merge <n>"

# The forked-from branch checked out in a linked worktree (an ADR-0008 flow
# checkout): the merge fast-forwards it there.
tw_repo
main_top="$(git rev-parse --show-toplevel)"
linked="$(mktemp -d)/linked"
git worktree add -q -b orch/6-other "$linked"
cd "$linked" || exit 1
wt="$("$ORCH" ticket-worktree add 4)"
tm_commit "$wt" ticket.txt four
tm_commit . other.txt landed-first
out="$("$ORCH" ticket merge 4 2>&1)"; st=$?
assert_status "merge succeeds when the forked-from branch is in a linked worktree" "$st" 0
assert_eq "fast-forwarding it there" "$(git -C "$linked" rev-parse HEAD)" "$(git rev-parse orch/6-other--t4)"
assert_eq "linearly" "$(git -C "$linked" log --format=%s -2 | tr '\n' '|')" "ticket.txt: four|other.txt: landed-first|"
assert_eq "updating its working tree" "$(cat "$linked/ticket.txt")" "four"
assert_eq "and leaving the main checkout's branch alone" \
  "$(git -C "$main_top" branch --show-current)" "orch/5-feature"
cd "$main_top" || exit 1

out="$("$ORCH" help 2>&1)"
assert_contains "ticket merge is in the usage text" "$out" "ticket merge <n>"
assert_contains "the CLI conventions' noun table lists merge among ticket's verbs" \
  "$(grep '^| `ticket` ' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`merge`'
restore_suite_env

# --- review begin -----------------------------------------------------------
# The bound lives in bash precisely so a long session cannot re-remember five as
# six, so what matters here is the refusal, not the counting. The budget is the
# human's number, read from state; a flow that never wrote one runs the default.
echo
echo "review begin"
healthy_repo

# --- issue fetch/update -------------------------------------------------------
# The stateless issue body read/write pair - the same contract
# issue publish/pr publish/ticket publish already offer, extended to a plain
# issue's body. cmd_spec's fetch/update ops (further below) become thin
# wrappers over these, resolving the issue from state exactly as before - so
# this section proves the primitives work given just an issue number, before
# `init reviewtest` below ever writes a state.json into this repo.
#
# Goes through the store-backed fake (fake_github), what each op wrote read
# back from the store - the fixture gh's log stays empty, proving it never spawns a real
# gh subprocess. The real operations are pinned in "gh adapter contract".
echo
echo "issue fetch/update"
healthy_repo
fake_github
fake_issue 23 open
fake_issue_body 23 "Body of #23."
assert_eq "no state.json exists yet in this repo" \
  "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
issue_body="$(mktemp)"
: >"$GH_FIXTURE/env.log"
out="$("$ORCH" issue fetch 23 "$issue_body" 2>&1)"; st=$?
assert_status "fetch writes the issue's body to the file, with no state.json present" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "exactly what GitHub holds" "$(cat "$issue_body")" "Body of #23."
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the view call never reached a real gh subprocess" "$(gh_calls)" "0"

rm -f "$issue_body"
out="$("$ORCH" issue fetch 404 "$issue_body" 2>&1)"; st=$?
assert_status "an issue gh cannot read fails the fetch" "$st" 1
assert_contains "naming the issue" "$out" "issue #404"
assert_eq "and leaves no file a caller could mistake for a body" \
  "$([ -e "$issue_body" ] && echo present || echo gone)" "gone"

tricky="$(mktemp)"
writeln '## Solution' '' 'Tracked in #6; see `$HOME` and '"'"'quoted'"'"' text.' >"$tricky"
out="$("$ORCH" issue update 23 "$tricky" 2>&1)"; st=$?
assert_status "update replaces the issue's body, with no state.json present" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "the issue number given, not one from state, holds the file's contents, exactly" \
  "$(fake_body_of 23)" "$(cat "$tricky")"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the edit call never reached a real gh subprocess" "$(gh_calls)" "0"

out="$("$ORCH" issue update 23 /nonexistent/body.md 2>&1)"; st=$?
assert_status "update refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"

fake_fail adapter_issue_body_edit "HTTP 403: Resource not accessible by integration"
out="$("$ORCH" issue update 23 "$tricky" 2>&1)"; st=$?
assert_status "a gh that will not edit fails the update" "$st" 1
assert_contains "with gh's reason" "$out" "HTTP 403"
assert_contains "naming the issue" "$out" "issue #23"

# issue comment is the stateless counterpart to spec comment, the way issue
# fetch/update are to spec fetch/update: a standalone spec review posts its
# summary on whatever issue it was pointed at, with no flow to ask.
out="$("$ORCH" issue comment 23 "$tricky" 2>&1)"; st=$?
assert_status "comment posts the file on the issue, with no state.json present" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "on the issue number given, not one from state, the file's contents as the comment, exactly" \
  "$(fake_comments_of 23)" "$(cat "$tricky")"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the comment call never reached a real gh subprocess" "$(gh_calls)" "0"

out="$("$ORCH" issue comment 23 /nonexistent/body.md 2>&1)"; st=$?
assert_status "comment refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and posts nothing" "$(fake_comments_of 23)" "$(cat "$tricky")"

fake_fail adapter_issue_comment "fake gh: issue comment refused"
out="$("$ORCH" issue comment 23 "$tricky" 2>&1)"; st=$?
assert_status "a gh that will not comment fails it" "$st" 1
assert_contains "with gh's reason" "$out" "issue comment refused"
assert_contains "naming the issue" "$out" "issue #23"

out="$("$ORCH" issue comment abc "$tricky" 2>&1)"; st=$?
assert_status "comment refuses an issue number that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" issue comment 23 2>&1)"; st=$?
assert_status "comment refuses with no file" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh issue comment"

out="$("$ORCH" issue 2>&1)"; st=$?
assert_status "refuses no op at all" "$st" 1
assert_contains "listing comment among the ops it has" "$out" "comment"

out="$("$ORCH" issue fetch abc "$issue_body" 2>&1)"; st=$?
assert_status "fetch refuses an issue number that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" issue update abc "$tricky" 2>&1)"; st=$?
assert_status "update refuses the same" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" issue fetch 23 2>&1)"; st=$?
assert_status "fetch refuses with no file" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh issue"

out="$("$ORCH" issue bogus 23 "$tricky" 2>&1)"; st=$?
assert_status "refuses an op it does not have" "$st" 1
assert_contains "naming the six it does" "$out" "fetch|update|comment|comments|publish|triage"

assert_contains "help documents issue fetch" "$("$ORCH" help)" "issue fetch"
assert_contains "and issue update" "$("$ORCH" help)" "issue update"
assert_contains "and issue publish" "$("$ORCH" help)" "issue publish"
assert_contains "and issue comment" "$("$ORCH" help)" "issue comment"

# issue comments: every comment on an issue, each opened by a marker line
# naming its author and timestamp, so the spec review reads the issue's
# comments alongside its body (issue #361). The marker's own format is
# COMMENTS_JQ's, pinned in "gh adapter contract".
fake_issue 24 open
fake_comment 24 triage-bot 2026-09-01T10:00:00Z "$(writeln '## Agent brief' '' 'Do the `$HOME` thing in #6.')"
fake_comment 24 pat 2026-09-02T11:30:00Z "$(writeln 'Also: the second line' '\\ stays unescaped.')"
issue_comments="$(mktemp)"
: >"$GH_FIXTURE/env.log"
out="$("$ORCH" issue comments 24 "$issue_comments" 2>&1)"; st=$?
assert_status "comments writes the issue's comments to the file, with no state.json present" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "each comment in order, opened by its author-and-date marker, one blank line between" \
  "$(cat "$issue_comments")" "$(writeln '<!-- comment @triage-bot 2026-09-01T10:00:00Z -->' \
    '## Agent brief' '' 'Do the `$HOME` thing in #6.' '' \
    '<!-- comment @pat 2026-09-02T11:30:00Z -->' 'Also: the second line' '\\ stays unescaped.')"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the view call never reached a real gh subprocess" "$(gh_calls)" "0"

fake_issue 25 open
out="$("$ORCH" issue comments 25 "$issue_comments" 2>&1)"; st=$?
assert_status "an issue with no comments still succeeds" "$st" 0
assert_eq "leaving an empty file" "$(wc -c <"$issue_comments" | tr -d ' ')" "0"

printf 'known content\n' >"$issue_comments"
fake_fail adapter_issue_comments "fake gh: issue view refused"
out="$("$ORCH" issue comments 24 "$issue_comments" 2>&1)"; st=$?
assert_status "a gh that will not answer fails the comments fetch" "$st" 1
assert_contains "naming the issue" "$out" "issue #24"
assert_eq "and leaves the file that was already there byte-identical" \
  "$(od -c "$issue_comments")" "$(printf 'known content\n' | od -c)"

out="$("$ORCH" issue comments abc "$issue_comments" 2>&1)"; st=$?
assert_status "comments refuses an issue number that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"
assert_contains "with a usage line" "$out" "usage: orch.sh issue"

out="$("$ORCH" issue comments 23 2>&1)"; st=$?
assert_status "comments refuses with no file" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh issue comments"

assert_contains "help documents issue comments" "$("$ORCH" help)" "issue comments"
rm -f "$issue_comments"

assert_eq "still no state.json - this section recorded none" \
  "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"

"$ORCH" init reviewtest >/dev/null
assert_eq "the first iteration is 1" "$("$ORCH" review begin)" "1"
assert_eq "records the iteration in state" "$("$ORCH" state get iteration)" "1"
for i in 2 3 4 5; do
  assert_eq "iteration $i is claimed in order" "$("$ORCH" review begin)" "$i"
done
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "refuses a sixth iteration on the default budget" "$st" 1
assert_contains "names the budget that stopped it" "$out" "budget of 5 iterations"
assert_eq "and does not spend the refused iteration" "$("$ORCH" state get iteration)" "5"

state_fixture iteration 0
"$ORCH" state set budget 2
assert_eq "a budget of 2 admits the first iteration" "$("$ORCH" review begin)" "1"
assert_eq "and the second" "$("$ORCH" review begin)" "2"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and refuses the third" "$st" 1
assert_contains "naming the budget it honoured" "$out" "budget of 2 iterations"

state_fixture iteration 0
"$ORCH" state set budget 8
for i in 1 2 3 4 5 6 7 8; do "$ORCH" review begin >/dev/null; done
assert_eq "a budget of 8 runs past the old bound of five" "$("$ORCH" state get iteration)" "8"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and stops at eight" "$st" 1

# A budget nothing can read is the default, not a refusal: the only flows that
# carry one are the ones started before it existed.
state_fixture iteration 4
"$ORCH" state set budget null
assert_eq "a null budget reads as five" "$("$ORCH" review begin)" "5"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and refuses the sixth" "$st" 1
state_fixture iteration 4
"$ORCH" state set budget lots
assert_eq "a budget that is not a number reads as five" "$("$ORCH" review begin)" "5"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and refuses the sixth too" "$st" 1
"$ORCH" state set budget null
restore_suite_env

# --- review path ------------------------------------------------------------
# One flow, one trail: the records sit flat under review/, numbered on across
# every loop the flow runs, so nothing is ever moved aside.
echo
echo "review path"
fresh_flow reviewpath
state_fixture iteration 5
assert_contains "files the record flat under review/" \
  "$("$ORCH" review path)" "/review/iteration-05.md"
assert_contains "zero-pads an explicit iteration" \
  "$("$ORCH" review path 2)" "/review/iteration-02.md"
assert_eq "creates the directory it names" \
  "$([ -d .orchestrator/review ] && echo present || echo gone)" "present"
out="$("$ORCH" review path nope 2>&1)"; st=$?
assert_status "rejects an iteration that is not a number" "$st" 1
restore_suite_env

# --- handoff verification ---------------------------------------------------
# The review loop runs the command the implement phase recorded rather than
# sniffing the repo for one, so a handoff without it sends review in blind.
echo
echo "handoff verification"
fresh_flow handoffverify
h3="$("$ORCH" handoff path review)"
writeln '## PR' '#3' '' '## Spec issue' '#1' '' '## Base SHA' 'abc1234' '' \
        '## Deviations' 'None.' >"$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "an implement handoff with no verification command is incomplete" "$st" 1
assert_contains "names the section review would have read" "$out" "Verification"

writeln '## PR' '#3' '' '## Spec issue' '#1' '' '## Base SHA' 'abc1234' '' \
        '## Deviations' 'None.' '' '## Verification' '   ' >"$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "a bare Verification heading is no better than none" "$st" 1
assert_contains "reported as empty, not missing" "$out" "empty section"

complete_implement_handoff "$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "passes once the command is recorded" "$st" 0

# A failing verification is recorded where it belongs - under Verification,
# with the ticket that reported it - and Deviations keeps only deviations.
writeln '## PR' '#3.' '' '## Spec issue' '#1.' '' '## Base SHA' 'abc1234.' '' \
        '## Deviations' 'None.' '' \
        '## Verification' 'bash scripts/test/orch_test.sh' 'fail - ticket #12' '' \
        '## Host fallbacks' 'None (Claude Code).' >"$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "a Verification section recording a failure and its ticket validates" "$st" 0
assert_eq "its first line is still the bare command the review loop runs" \
  "$("$ORCH" handoff section "$h3" Verification | head -n 1)" "bash scripts/test/orch_test.sh"
restore_suite_env

# --- the multi-loop machinery is gone ---------------------------------------
# Every loop reads the implement handoff, whatever the flow has been through.
# The old entry points are removed rather than deprecated, so each one has to
# fail loudly: a session that found a path back into them would be driving a
# loop nothing else understands.
echo
echo "the multi-loop machinery is gone"
fresh_flow multiloop
state_fixture phase review
state_fixture iteration 7
assert_contains "review reads the implement handoff however far in the flow is" \
  "$("$ORCH" handoff path review)" "03-implement.md"
state_fixture iteration 5

out="$("$ORCH" handoff path review-next 2>&1)"; st=$?
assert_status "there is no handoff for a next loop to read" "$st" 1
assert_eq "and no path printed for a caller to use" \
  "$(printf '%s\n' "$out" | grep -c '/handoff/')" "0"

writeln '## PR' '#3' >.orchestrator/handoff/04-review.md
out="$("$ORCH" handoff validate .orchestrator/handoff/04-review.md 2>&1)"; st=$?
assert_status "a review handoff is not a handoff validate knows" "$st" 1
assert_contains "and it says so rather than passing it empty" "$out" "unknown handoff file"
rm .orchestrator/handoff/04-review.md

out="$("$ORCH" review loop-next 2>&1)"; st=$?
assert_status "review loop-next is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown review op"
restore_suite_env

# --- is_filed_severity ------------------------------------------------------

echo "is_filed_severity"
new_repo >/dev/null
# Sourced rather than run: the helper is the one answer to "is this severity
# filed", and sourcing orch.sh defines its functions without running main.
filed_sev() { bash -c 'source "$1" && is_filed_severity "$2"' _ "$ORCH" "$1"; }
filed_sev major; assert_status "accepts major" "$?" 0
filed_sev nit; assert_status "accepts nit" "$?" 0
filed_sev blocking; assert_status "refuses blocking - it is always fixed, never filed" "$?" 1
filed_sev ""; assert_status "refuses an empty severity" "$?" 1

# --- review file ------------------------------------------------------------

# Filing is mechanism: which labels, what title, which body, and the number
# printed back. What reached GitHub is the assertion - a finding filed with no
# severity label is a finding triage never finds.
#
# Labels and issue both go to the store-backed fake (fake_github) and are read
# back from its store - neither ever spawns a subprocess. The real operations
# are pinned in "gh adapter contract" after this section.
echo
echo "review file"
fresh_flow reviewfile
fake_github
body="$(mktemp)"
writeln 'The reviewer said this.' '' 'Axis: Standards' >"$body"
: >"$GH_FIXTURE/env.log"
tab="$(printf '\t')"
fake_label review:major ffffff "An older description"
fake_label needs-triage 000000 "The repo's own"
fake_next_issue 17
out="$("$ORCH" review file major "Comment drifted from the code" --axis standards \
  --body-file "$body" 2>&1)"; st=$?
assert_status "files a major" "$st" 0
assert_eq "printing the issue number and nothing else" "$out" "17"
assert_contains "making the severity label ours over one that exists already" "$(fake_labels)" \
  "review:major${tab}d93f0b${tab}Review finding filed at major severity"
assert_contains "and leaving the repo's own triage label as the repo has it" "$(fake_labels)" \
  "needs-triage${tab}000000${tab}The repo's own"
assert_contains "and creating the category label the repo lacks" "$(fake_labels)" \
  "enhancement${tab}a2eeef${tab}New feature or request"
assert_eq "passes the title through unprefixed" "$(fake_title_of 17)" "Comment drifted from the code"
assert_eq "labels the issue with the severity, needs-triage and the category" \
  "$(fake_labels_of 17)" "enhancement needs-triage review:major "
assert_eq "and sends the body file's contents" "$(fake_body_of 17)" "$(cat "$body")"
assert_eq "neither the labels nor the issue create reached a real gh subprocess" \
  "$(gh_calls)" "0"

fake_github
out="$("$ORCH" review file nit "Rename it" --axis standards --body-file "$body" 2>&1)"; st=$?
assert_status "files a nit" "$st" 0
assert_contains "under the nit label" "$(fake_labels_of "$out")" "review:nit "
assert_contains "creating it" "$(fake_labels)" "review:nit${tab}c5def5${tab}Review finding filed at nit severity"
assert_contains "and the triage label a repo without one lacks" "$(fake_labels)" \
  "needs-triage${tab}e4e669${tab}Not yet triaged"

# The category is the axis's: a Spec finding is a defect against what was
# asked for, a Standards finding an improvement on how it was built.
fake_github
out="$("$ORCH" review file major "Misses a criterion" --axis spec --body-file "$body" 2>&1)"; st=$?
assert_status "files a Spec finding" "$st" 0
assert_eq "labelled bug, and not enhancement" "$(fake_labels_of "$out")" "bug needs-triage review:major "
assert_contains "creating bug with GitHub's default colour and description" \
  "$(fake_labels)" "bug${tab}d73a4a${tab}Something isn't working"
assert_not_contains "and no enhancement label" "$(fake_labels)" "enhancement${tab}"

fake_github
out="$("$ORCH" review file nit "Rename it" --axis Standards --body-file "$body" 2>&1)"; st=$?
assert_status "files a Standards finding, whatever the axis's case" "$st" 0
assert_eq "labelled enhancement, and not bug" "$(fake_labels_of "$out")" "enhancement needs-triage review:nit "
assert_contains "creating enhancement with GitHub's default colour and description" \
  "$(fake_labels)" "enhancement${tab}a2eeef${tab}New feature or request"

# A category label that cannot be created - most often because the repo has
# it already - does not stop the filing, and the repo's own is left as it is.
fake_github
fake_label bug 123456 "The repo's own bug"
fake_label enhancement 654321 "The repo's own enhancement"
fake_next_issue 23
out="$("$ORCH" review file major "Misses a criterion" --axis spec --body-file "$body" 2>&1)"; st=$?
assert_status "a category label the repo has already does not stop filing" "$st" 0
assert_eq "the number is still printed" "$out" "23"
assert_contains "and the issue still carries the label" "$(fake_labels_of 23)" "bug "
assert_contains "never over the repo's own bug label" "$(fake_labels)" "bug${tab}123456${tab}The repo's own bug"
out="$("$ORCH" review file nit "Rename it" --axis standards --body-file "$body" 2>&1)"; st=$?
assert_contains "nor over its own enhancement label" "$(fake_labels)" \
  "enhancement${tab}654321${tab}The repo's own enhancement"

fake_github
fake_fail adapter_label_create "HTTP 502: Bad Gateway"
fake_next_issue 24
out="$("$ORCH" review file major "Misses a criterion" --axis spec --body-file "$body" 2>&1)"; st=$?
assert_status "nor does one gh fails to create for another reason" "$st" 0
assert_eq "the number alone printed, gh's error kept out of it" "$out" "24"

fake_github
out="$("$ORCH" review file major "Title" --body-file "$body" 2>&1)"; st=$?
assert_status "refuses a finding with no axis" "$st" 1
assert_contains "naming the axis" "$out" "--axis"
assert_eq "and files nothing" "$(fake_issues)" ""
assert_eq "nor creates a label" "$(fake_labels)" ""

out="$("$ORCH" review file major "Title" --axis style --body-file "$body" 2>&1)"; st=$?
assert_status "refuses an unknown axis" "$st" 1
assert_contains "naming it" "$out" "style"
assert_contains "and what it accepts" "$out" "spec or standards"
assert_eq "in exactly these words" "$out" "orch: not a review axis: style (want spec or standards)"
assert_eq "and files nothing" "$(fake_issues)" ""
assert_eq "nor creates a label" "$(fake_labels)" ""

out="$("$ORCH" review file blocking "Wrong" --axis spec --body-file "$body" 2>&1)"; st=$?
assert_status "refuses a blocking severity - the loop fixes those" "$st" 1
assert_contains "naming what it accepts" "$out" "major"
assert_contains "saying blocking is always fixed, never filed" "$out" "blocking is always fixed, never filed"
assert_not_contains "without claiming the loop fixes blocking only" "$out" "the loop fixes blocking)"
for sev in $(bash -c 'source "$1" && printf "%s\n" "$FILED_SEVERITIES"' _ "$ORCH"); do
  assert_contains "naming filed severity $sev, read from FILED_SEVERITIES" "$out" "$sev"
done
assert_eq "and nothing reaches gh" "$(fake_issues)" ""
assert_eq "not even a label" "$(fake_labels)" ""

out="$("$ORCH" review file major "" --axis spec --body-file "$body" 2>&1)"; st=$?
assert_status "refuses an empty title" "$st" 1
assert_eq "before anything reaches gh" "$(fake_issues)" ""
assert_eq "a label included" "$(fake_labels)" ""

out="$("$ORCH" review file major "Title" --axis spec --body-file /nonexistent/body.md 2>&1)"; st=$?
assert_status "refuses a body file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and files nothing" "$(fake_issues)" ""
assert_eq "nor creates a label" "$(fake_labels)" ""

out="$("$ORCH" review file major "Title" --axis spec "$body" 2>&1)"; st=$?
assert_status "insists on --body-file rather than guessing a positional" "$st" 1

fake_fail adapter_issue_create "HTTP 502: Bad Gateway"
out="$("$ORCH" review file major "Title" --axis spec --body-file "$body" 2>&1)"; st=$?
assert_status "a gh that will not create the issue fails the command" "$st" 1
assert_contains "passing gh's reason through" "$out" "HTTP 502: Bad Gateway"
assert_eq "with no number printed for a record to cite" \
  "$(printf '%s\n' "$out" | grep -cx '[0-9][0-9]*')" "0"

fake_github
fake_fail adapter_label_upsert "HTTP 403: Resource not accessible by integration"
out="$("$ORCH" review file major "Title" --axis spec --body-file "$body" 2>&1)"; st=$?
assert_status "a gh that will not create the label fails it too" "$st" 1
assert_contains "passing gh's reason through" "$out" "HTTP 403: Resource not accessible by integration"
assert_contains "and naming the label" "$out" "gh could not create label review:major"
assert_eq "filing no issue" "$(fake_issues)" ""

# The triage label is the repo's vocabulary, read from the doc the spec phase
# labels from: a repo that renamed it must not get a second label the name
# this plugin happens to know.
fake_github
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready   |' >docs/agents/triage-labels.md
out="$("$ORCH" review file nit "Rename it" --axis standards --body-file "$body" 2>&1)"; st=$?
assert_status "files under a renamed triage label" "$st" 0
assert_contains "creating the repo's name for it" "$(fake_labels)" "triage me${tab}e4e669${tab}Not yet triaged"
assert_eq "and applying it rather than the canonical one" \
  "$(fake_labels_of "$out")" "enhancement review:nit triage me "
assert_not_contains "nor creating it" "$(fake_labels)" "needs-triage"
labels_doc docs/agents/triage-labels.md
restore_suite_env

# --- gh fake (#280) --------------------------------------------------------------
# The store-backed fake's own helpers: the store fake_github makes, the seeds
# that land in it in the layout documented at the top of gh_adapter_fake.sh,
# and the lag countdown an operation answers stale by.
echo
echo "gh fake"
fake_github
first_store="$ORCH_GH_FAKE_STORE"
assert_eq "fake_github points orch.sh at the fake" "$ORCH_GH_ADAPTER" "$GH_ADAPTER_FAKE"
assert_eq "with an empty store" "$(find "$first_store" -mindepth 1 | wc -l | tr -d ' ')" "0"
fake_github
assert_ne "a fresh store each time" "$ORCH_GH_FAKE_STORE" "$first_store"
fake_issue 12 open ready-for-agent "needs triage"
assert_eq "fake_issue seeds the issue's state as gh reports it" \
  "$(cat "$ORCH_GH_FAKE_STORE/issues/12/state")" "OPEN"
assert_eq "and its labels, one per line" \
  "$(cat "$ORCH_GH_FAKE_STORE/issues/12/labels")" "$(printf 'ready-for-agent\nneeds triage')"
fake_issue 13 closed
assert_eq "an issue seeded with no labels has none" \
  "$(cat "$ORCH_GH_FAKE_STORE/issues/13/state")|$(cat "$ORCH_GH_FAKE_STORE/issues/13/labels")" "CLOSED|"
lagging() { bash -c 'source "$1"; fake_lagging "$2"' _ "$GH_ADAPTER_FAKE" "$1"; }
fake_lag adapter_issue_body 2
lagging adapter_issue_body; assert_status "a lagged operation answers stale" "$?" 0
lagging adapter_issue_body; assert_status "for as many calls as fake_lag asked" "$?" 0
lagging adapter_issue_body; assert_status "and current after them" "$?" 1
lagging adapter_label_create; assert_status "an operation with no lag is current" "$?" 1
restore_suite_env
assert_eq "restore_suite_env undoes fake_github" \
  "${ORCH_GH_ADAPTER-unset} ${ORCH_GH_FAKE_STORE-unset}" "unset unset"

# --- gh adapter contract (#280) ------------------------------------------------
# Each real adapter operation, run against the fixture gh: the exact argv it
# hands gh, the plain text it prints, and a failure - non-zero, gh's stderr
# passed through. The behaviour tests fake these same operations, so these are
# what keeps the fake honest about the real ones.
echo
echo "gh adapter contract"
new_repo >/dev/null
gh_fixture
export GH_REPO=acme/widgets
sev_desc="Review finding filed at major severity"

gh_reply 0 'Label "review:major" created' '' \
  label create review:major --force --color d93f0b --description "$sev_desc"
out="$(contract adapter_label_upsert review:major d93f0b "$sev_desc" 2>&1)"; st=$?
assert_status "label upsert: creates or updates the label with --force" "$st" 0
assert_eq "printing nothing" "$out" ""
assert_contains "pinned to the resolved repo" "$(cat "$GH_FIXTURE/env.log")" \
  "GH_REPO=acme/widgets GH_HOST=<unset> label create review:major --force"

gh_reply 1 '' 'HTTP 403: Resource not accessible by integration' \
  label create review:nit --force --color c5def5 --description "Review finding filed at nit severity"
out="$(contract adapter_label_upsert review:nit c5def5 "Review finding filed at nit severity" 2>&1)"; st=$?
assert_status "label upsert: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Resource not accessible by integration"

gh_reply 0 '' '' label create "triage me" --color e4e669 --description "Not yet triaged"
out="$(contract adapter_label_create "triage me" e4e669 "Not yet triaged" 2>&1)"; st=$?
assert_status "label create: creates a missing label, never with --force" "$st" 0
assert_eq "printing nothing" "$out" ""

gh_reply 1 '' 'label with name "bug" already exists; use `--force` to update its color and description' \
  label create bug --color d73a4a --description "Something isn't working"
out="$(contract adapter_label_create bug d73a4a "Something isn't working" 2>&1)"; st=$?
assert_status "label create: a label that exists fails it" "$st" 1
assert_contains "passing gh's stderr through" "$out" 'label with name "bug" already exists'

: >"$GH_FIXTURE/env.log"
export GH_REPO=ghe.example.com/acme/widgets
gh_reply 0 '' '' label create enhancement --color a2eeef --description "New feature or request"
contract adapter_label_create enhancement a2eeef "New feature or request" >/dev/null 2>&1
assert_contains "a repo on another host pins gh's host too" "$(cat "$GH_FIXTURE/env.log")" \
  "GH_REPO=ghe.example.com/acme/widgets GH_HOST=ghe.example.com label create enhancement"
export GH_REPO=acme/widgets
unset GH_HOST

# The issue operations. Each read prints what gh's own --jq printed, so its
# reply here is that already-formatted text.
gh_reply 0 $'## Problem\n\nTracked in #6.\n' '' issue view 23 --json body --jq .body
out="$(contract adapter_issue_body 23 2>&1)"; st=$?
assert_status "issue body: reads the body" "$st" 0
assert_eq "printing it as it is" "$out" "$(printf '## Problem\n\nTracked in #6.')"
gh_reply 1 '' 'GraphQL: Could not resolve to an issue or pull request with the number of 404.' \
  issue view 404 --json body --jq .body
out="$(contract adapter_issue_body 404 2>&1)"; st=$?
assert_status "issue body: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" \
  "GraphQL: Could not resolve to an issue or pull request with the number of 404."

comments_jq="$(bash -c 'source "$1"; printf "%s" "$COMMENTS_JQ"' _ "$ORCH")"
gh_reply 0 $'<!-- comment @pat 2026-09-02T11:30:00Z -->\nA follow-up.\n' '' \
  issue view 23 --json comments --jq "$comments_jq"
out="$(contract adapter_issue_comments 23 2>&1)"; st=$?
assert_status "issue comments: reads the comments through COMMENTS_JQ" "$st" 0
assert_eq "printing what it formatted" "$out" "$(writeln '<!-- comment @pat 2026-09-02T11:30:00Z -->' 'A follow-up.')"
# COMMENTS_JQ itself, run on gh-shaped JSON: what the fixture's canned reply
# above stands in for.
comments_json='{"comments":[{"author":{"login":"triage-bot"},"createdAt":"2026-09-01T10:00:00Z","body":"## Agent brief\n\nDo the `$HOME` thing in #6."},{"author":{"login":"pat"},"createdAt":"2026-09-02T11:30:00Z","body":"Also: the second line\n\\\\ stays unescaped."}]}'
assert_eq "COMMENTS_JQ opens each comment with its author-and-date marker, one blank line between" \
  "$(printf '%s' "$comments_json" | jq -r "$comments_jq")" \
  "$(writeln '<!-- comment @triage-bot 2026-09-01T10:00:00Z -->' \
    '## Agent brief' '' 'Do the `$HOME` thing in #6.' '' \
    '<!-- comment @pat 2026-09-02T11:30:00Z -->' 'Also: the second line' '\\ stays unescaped.')"
assert_eq "and prints nothing at all for no comments" \
  "$(printf '%s' '{"comments":[]}' | jq -r "$comments_jq" | wc -c | tr -d ' ')" "0"

gh_reply 0 $'OPEN\nreview:nit\nneeds-triage\n' '' issue view 23 --json state,labels --jq '.state, (.labels[].name)'
out="$(contract adapter_issue_state_labels 23 2>&1)"; st=$?
assert_status "issue state and labels: reads both" "$st" 0
assert_eq "the state first, then one label per line" "$out" "$(writeln OPEN review:nit needs-triage)"

gh_reply 0 $'Widgets need a handle\nready-for-agent\n' '' \
  issue view 23 --json title,labels --jq '.title, (.labels[].name)'
out="$(contract adapter_issue_title_labels 23 2>&1)"; st=$?
assert_status "issue title and labels: reads both" "$st" 0
assert_eq "the title first, then one label per line" "$out" "$(writeln 'Widgets need a handle' ready-for-agent)"

gh_reply 0 $'PULL\n' '' \
  issue view 62 --json state,url --jq 'if (.url | test("/pull/")) then "PULL" else .state end'
out="$(contract adapter_issue_state 62 2>&1)"; st=$?
assert_status "issue state: reads the state" "$st" 0
assert_eq "PULL for a pull request's number" "$out" "PULL"

gh_reply 0 $'3\n9\n' '' \
  issue list --state open --label review:nit --label "triage me" --limit 1000 --json number --jq '.[].number'
out="$(contract adapter_issues_labelled review:nit "triage me" 2>&1)"; st=$?
assert_status "issues labelled: lists the open issues carrying every label" "$st" 0
assert_eq "one number per line" "$out" "$(writeln 3 9)"

ibody="$(mktemp)"
writeln 'The body.' >"$ibody"
gh_reply 0 $'https://github.com/acme/widgets/issues/17\n' '' \
  issue create --title "Rename it" --body-file "$ibody" --label review:nit --label "triage me"
out="$(contract adapter_issue_create "Rename it" "$ibody" review:nit "triage me" 2>&1)"; st=$?
assert_status "issue create: files the issue under every label" "$st" 0
assert_eq "printing its number alone" "$out" "17"
gh_reply 0 $'https://github.com/acme/widgets/issues/18\n' '' \
  issue create --title "Unlabelled" --body-file "$ibody"
out="$(contract adapter_issue_create "Unlabelled" "$ibody" 2>&1)"; st=$?
assert_status "issue create: files an issue with no label" "$st" 0
assert_eq "printing its number" "$out" "18"
gh_reply 0 $'Something went sideways\n' '' issue create --title "No URL" --body-file "$ibody"
out="$(contract adapter_issue_create "No URL" "$ibody" 2>/dev/null)"; st=$?
assert_status "issue create: gh output with no issue URL fails it" "$st" 1
assert_eq "printing no number" "$out" ""
gh_reply 1 '' 'could not add label: review:nit not found' issue create --title "Refused" --body-file "$ibody"
out="$(contract adapter_issue_create "Refused" "$ibody" 2>&1)"; st=$?
assert_status "issue create: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "could not add label: review:nit not found"

gh_reply 0 'https://github.com/acme/widgets/issues/23' '' issue edit 23 --body-file "$ibody"
out="$(contract adapter_issue_body_edit 23 "$ibody" 2>&1)"; st=$?
assert_status "issue body edit: replaces the body from the file" "$st" 0
assert_eq "printing nothing" "$out" ""

gh_reply 0 'https://github.com/acme/widgets/issues/23#issuecomment-1' '' issue comment 23 --body-file "$ibody"
out="$(contract adapter_issue_comment 23 "$ibody" 2>&1)"; st=$?
assert_status "issue comment: posts the file as a comment" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 403: Resource not accessible by integration' issue comment 24 --body-file "$ibody"
out="$(contract adapter_issue_comment 24 "$ibody" 2>&1)"; st=$?
assert_status "issue comment: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Resource not accessible by integration"

gh_reply 0 'https://github.com/acme/widgets/issues/23' '' \
  issue edit 23 --remove-label "triage me" --remove-label bug --add-label afk --add-label enhancement
out="$(contract adapter_issue_relabel 23 "afk,enhancement" "triage me,bug" 2>&1)"; st=$?
assert_status "issue relabel: removes and adds in one edit" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 0 '' '' issue edit 24 --add-label wontfix
out="$(contract adapter_issue_relabel 24 wontfix "" 2>&1)"; st=$?
assert_status "issue relabel: with nothing to remove, only adds" "$st" 0

gh_reply 0 'Closed issue #23' '' issue close 23 --reason completed
out="$(contract adapter_issue_close 23 completed 2>&1)"; st=$?
assert_status "issue close: closes with the reason given" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 0 '' '' issue close 24 --reason "not planned" --comment "Retired."
out="$(contract adapter_issue_close 24 "not planned" "Retired." 2>&1)"; st=$?
assert_status "issue close: with a reason and a comment" "$st" 0
gh_reply 0 '' '' issue close 25 --comment "Redone."
out="$(contract adapter_issue_close 25 "" "Redone." 2>&1)"; st=$?
assert_status "issue close: with a comment and gh's default reason" "$st" 0
gh_reply 1 '' 'HTTP 502: Bad Gateway' issue close 26
out="$(contract adapter_issue_close 26 2>&1)"; st=$?
assert_status "issue close: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"
gh_reply 0 'Reopened issue #23' '' issue reopen 23
out="$(contract adapter_issue_reopen 23 2>&1)"; st=$?
assert_status "issue reopen: reopens the issue" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' issue reopen 26
out="$(contract adapter_issue_reopen 26 2>&1)"; st=$?
assert_status "issue reopen: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"
assert_eq "every issue operation was pinned to the resolved repo" \
  "$(grep ' issue ' "$GH_FIXTURE/env.log" | grep -cv '^GH_REPO=acme/widgets GH_HOST=<unset> issue ')" "0"

# The PR operations, the same way: each read's reply is what gh's own --jq
# printed.
gh_reply 0 $'https://github.com/acme/widgets/pull/31\n' '' \
  pr create --draft --base main --head orch/16-x --title "Add it" --body-file "$ibody"
out="$(contract adapter_pr_create main orch/16-x "Add it" "$ibody" true 2>&1)"; st=$?
assert_status "pr create: opens a draft PR from head into base" "$st" 0
assert_eq "printing its number alone" "$out" "31"
gh_reply 0 $'https://github.com/acme/widgets/pull/32\n' '' \
  pr create --base main --head uat --title "Release" --body-file "$ibody"
out="$(contract adapter_pr_create main uat "Release" "$ibody" 2>&1)"; st=$?
assert_status "pr create: opens a PR that is not a draft" "$st" 0
assert_eq "printing its number" "$out" "32"
gh_reply 0 $'Warning: 1 uncommitted change\n' '' \
  pr create --base main --head no-url --title "No URL" --body-file "$ibody"
out="$(contract adapter_pr_create main no-url "No URL" "$ibody" 2>/dev/null)"; st=$?
assert_status "pr create: gh output with no PR URL fails it" "$st" 1
assert_eq "printing no number" "$out" ""
gh_reply 1 '' 'a pull request for branch "dup" into branch "main" already exists' \
  pr create --base main --head dup --title "Dup" --body-file "$ibody"
out="$(contract adapter_pr_create main dup "Dup" "$ibody" 2>&1)"; st=$?
assert_status "pr create: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" 'a pull request for branch "dup" into branch "main" already exists'

gh_reply 0 $'Closes #12\n\nAdds it.\n' '' pr view 57 --json body --jq .body
out="$(contract adapter_pr_body 57 2>&1)"; st=$?
assert_status "pr body: reads the body" "$st" 0
assert_eq "printing it as it is" "$out" "$(writeln 'Closes #12' '' 'Adds it.')"
gh_reply 1 '' 'no pull requests found for 404' pr view 404 --json body --jq .body
out="$(contract adapter_pr_body 404 2>&1)"; st=$?
assert_status "pr body: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "no pull requests found for 404"

gh_reply 0 $'<!-- comment @pat 2026-10-01T09:00:00Z -->\nLGTM\n' '' \
  pr view 57 --json comments --jq "$comments_jq"
out="$(contract adapter_pr_comments 57 2>&1)"; st=$?
assert_status "pr comments: reads the comments through COMMENTS_JQ" "$st" 0
assert_eq "printing what it formatted" "$out" "$(writeln '<!-- comment @pat 2026-10-01T09:00:00Z -->' 'LGTM')"

refs_jq='(.headRefOid // ""), (.headRefName // ""), (.baseRefName // ""), ((.commits // [])[].oid)'
gh_reply 0 $'bbbb\ntopic\nmain\naaaa\nbbbb\n' '' \
  pr view 57 --json headRefOid,headRefName,baseRefName,commits --jq "$refs_jq"
out="$(contract adapter_pr_refs 57 2>&1)"; st=$?
assert_status "pr refs: reads the PR's head, base and commits" "$st" 0
assert_eq "head SHA, head branch, base branch, then one commit per line, oldest first" \
  "$out" "$(writeln bbbb topic main aaaa bbbb)"
assert_eq "its --jq prints an empty line for a field GitHub leaves null" \
  "$(printf '%s' '{"headRefOid":null,"headRefName":"topic","baseRefName":"main","commits":null}' | jq -r "$refs_jq")" \
  "$(writeln '' topic main)"
gh_reply 1 '' 'HTTP 502: Bad Gateway' \
  pr view 58 --json headRefOid,headRefName,baseRefName,commits --jq "$refs_jq"
out="$(contract adapter_pr_refs 58 2>&1)"; st=$?
assert_status "pr refs: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 '✓ Pull request acme/widgets#57 is marked as "ready for review"' '' pr ready 57
out="$(contract adapter_pr_ready 57 2>&1)"; st=$?
assert_status "pr ready: marks the PR ready" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 403: Resource not accessible by integration' pr ready 58
out="$(contract adapter_pr_ready 58 2>&1)"; st=$?
assert_status "pr ready: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Resource not accessible by integration"

gh_reply 0 $'OPEN\ntrue\n' '' pr view 57 --json state,isDraft --jq '.state, .isDraft'
out="$(contract adapter_pr_state_draft 57 2>&1)"; st=$?
assert_status "pr state draft: reads the PR's state and draft flag" "$st" 0
assert_eq "the state, then true or false" "$out" "$(writeln OPEN true)"
gh_reply 1 '' 'GraphQL: Could not resolve to a PullRequest with the number of 58.' \
  pr view 58 --json state,isDraft --jq '.state, .isDraft'
out="$(contract adapter_pr_state_draft 58 2>&1)"; st=$?
assert_status "pr state draft: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "GraphQL: Could not resolve to a PullRequest with the number of 58."

gh_reply 0 $'57\n' '' pr list --head quick/12-foo --state open --json number --jq '.[].number'
out="$(contract adapter_prs_open quick/12-foo 2>&1)"; st=$?
assert_status "prs open: lists the open PRs from a branch" "$st" 0
assert_eq "one number per line" "$out" "57"
gh_reply 0 '' '' pr list --head uat --base main --state open --json number --jq '.[].number'
out="$(contract adapter_prs_open uat main 2>&1)"; st=$?
assert_status "prs open: lists the open PRs from a branch into a base" "$st" 0
assert_eq "nothing at all for none" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' pr list --head down --state open --json number --jq '.[].number'
out="$(contract adapter_prs_open down 2>&1)"; st=$?
assert_status "prs open: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 $'61\n' '' pr list --head quick/12-foo --base main --state merged --json number --jq '.[].number'
out="$(contract adapter_prs_merged quick/12-foo main 2>&1)"; st=$?
assert_status "prs merged: lists the merged PRs from a branch into a base" "$st" 0
assert_eq "one number per line" "$out" "61"
gh_reply 1 '' 'HTTP 502: Bad Gateway' pr list --head down --base main --state merged --json number --jq '.[].number'
out="$(contract adapter_prs_merged down main 2>&1)"; st=$?
assert_status "prs merged: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 $'Refs #5\n\nImplements it.\nFixes #6\n' '' \
  pr list --base uat --state merged --limit 1000 --json body --jq '.[].body'
out="$(contract adapter_prs_merged_bodies uat 2>&1)"; st=$?
assert_status "prs merged bodies: reads the bodies of the PRs merged into a base" "$st" 0
assert_eq "each body followed by a newline" "$out" "$(writeln 'Refs #5' '' 'Implements it.' 'Fixes #6')"

gh_reply 0 '✓ Closed pull request acme/widgets#30' '' pr close 30 --comment "Redone."
out="$(contract adapter_pr_close 30 "Redone." 2>&1)"; st=$?
assert_status "pr close: closes the PR with a comment" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' pr close 31 --comment "Redone."
out="$(contract adapter_pr_close 31 "Redone." 2>&1)"; st=$?
assert_status "pr close: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 'https://github.com/acme/widgets/pull/57#issuecomment-1' '' pr comment 57 --body-file "$ibody"
out="$(contract adapter_pr_comment 57 "$ibody" 2>&1)"; st=$?
assert_status "pr comment: posts the file as a comment" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 403: Resource not accessible by integration' pr comment 58 --body-file "$ibody"
out="$(contract adapter_pr_comment 58 "$ibody" 2>&1)"; st=$?
assert_status "pr comment: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Resource not accessible by integration"

gh_reply 0 'https://github.com/acme/widgets/pull/57' '' pr edit 57 --body-file "$ibody"
out="$(contract adapter_pr_body_edit 57 "$ibody" 2>&1)"; st=$?
assert_status "pr body edit: replaces the body from the file" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' pr edit 58 --body-file "$ibody"
out="$(contract adapter_pr_body_edit 58 "$ibody" 2>&1)"; st=$?
assert_status "pr body edit: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"
assert_eq "every PR operation was pinned to the resolved repo" \
  "$(grep ' pr ' "$GH_FIXTURE/env.log" | grep -cv '^GH_REPO=acme/widgets GH_HOST=<unset> pr ')" "0"

# The CI operations. These parse gh's JSON themselves, so each reply here is
# gh's raw answer.
checks_tsv() { printf '%s\t%s\t%s\n' "$@"; }
runs=https://github.com/acme/widgets/actions/runs
gh_reply 0 "[{\"bucket\":\"fail\",\"name\":\"build\",\"link\":\"$runs/4242/job/77\"},{\"bucket\":\"pass\",\"name\":\"lint\",\"link\":null}]" '' \
  pr checks 57 --required --json bucket,name,link
out="$(contract adapter_pr_checks 57 required 2>&1)"; st=$?
assert_status "pr checks: reads the required checks" "$st" 0
assert_eq "one check per line, bucket, name and link as TSV, an empty link for none" \
  "$out" "$(checks_tsv fail build "$runs/4242/job/77" pass lint '')"
gh_reply 0 '[{"bucket":"pass","name":"build","link":"x"}]' '' pr checks 57 --json bucket,name,link
out="$(contract adapter_pr_checks 57 all 2>&1)"; st=$?
assert_status "pr checks: reads every check, without --required" "$st" 0
assert_eq "in the same shape" "$out" "$(checks_tsv pass build x)"
gh_reply 8 '[{"bucket":"pending","name":"build","link":"y"}]' '' pr checks 60 --json bucket,name,link
out="$(contract adapter_pr_checks 60 all 2>&1)"; st=$?
assert_status "pr checks: gh's exit 8 for pending checks is absorbed" "$st" 0
assert_eq "its answer read like an exit 0's" "$out" "$(checks_tsv pending build y)"
gh_reply 8 '' '' pr checks 61 --json bucket,name,link
out="$(contract adapter_pr_checks 61 all 2>&1)"; st=$?
assert_status "pr checks: an exit 8 with nothing readable still succeeds" "$st" 0
assert_eq "as one pending check with no name or link" "$out" "$(checks_tsv pending '' '')"
gh_reply 1 '' "no checks reported on the 'topic' branch" pr checks 62 --json bucket,name,link
out="$(contract adapter_pr_checks 62 all 2>&1)"; st=$?
assert_status "pr checks: no checks reported succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 1 '' "no required checks reported on the 'topic' branch" pr checks 62 --required --json bucket,name,link
out="$(contract adapter_pr_checks 62 required 2>&1)"; st=$?
assert_status "pr checks: no required checks reported succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 0 '[]' '' pr checks 63 --json bucket,name,link
out="$(contract adapter_pr_checks 63 all 2>&1)"; st=$?
assert_status "pr checks: an empty list succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 0 'not json at all' '' pr checks 64 --json bucket,name,link
out="$(contract adapter_pr_checks 64 all 2>&1)"; st=$?
assert_status "pr checks: an answer jq cannot read fails it, never reads as no checks" "$st" 1
assert_eq "saying what it could not read" "$out" "gh pr checks answered with something jq could not read"
gh_reply 1 '' 'dial tcp: lookup api.github.com: no such host' pr checks 65 --json bucket,name,link
out="$(contract adapter_pr_checks 65 all 2>&1)"; st=$?
assert_status "pr checks: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "dial tcp: lookup api.github.com: no such host"

prot="repos/{owner}/{repo}/branches/main/protection/required_status_checks"
gh_reply 0 '{"strict":false,"contexts":["build","lint"],"checks":[{"context":"build","app_id":null}]}' '' api "$prot"
out="$(contract adapter_branch_required_checks main 2>&1)"; st=$?
assert_status "branch required checks: reads classic protection" "$st" 0
assert_eq "each required context once, one per line" "$out" "$(writeln build lint)"
gh_reply 1 '{"message":"Branch not protected","status":"404"}' 'gh: Branch not protected (HTTP 404)' \
  api "repos/{owner}/{repo}/branches/open/protection/required_status_checks"
out="$(contract adapter_branch_required_checks open 2>&1)"; st=$?
assert_status "branch required checks: GitHub's 404 for an unprotected branch succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 1 '{"message":"Not Found","status":"404"}' 'gh: Not Found (HTTP 404)' \
  api "repos/{owner}/{repo}/branches/hidden/protection/required_status_checks"
out="$(contract adapter_branch_required_checks hidden 2>&1)"; st=$?
assert_status "branch required checks: a bare 404 Not Found fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "gh: Not Found (HTTP 404)"
gh_reply 0 '{"strict":true}' '' api "repos/{owner}/{repo}/branches/loose/protection/required_status_checks"
out="$(contract adapter_branch_required_checks loose 2>&1)"; st=$?
assert_status "branch required checks: protection requiring no checks succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""

gh_reply 0 '[{"type":"deletion"},{"type":"required_status_checks","parameters":{}}]' '' \
  api "repos/{owner}/{repo}/rules/branches/main"
out="$(contract adapter_branch_rules main 2>&1)"; st=$?
assert_status "branch rules: reads the rules on a branch" "$st" 0
assert_eq "one rule type per line" "$out" "$(writeln deletion required_status_checks)"
gh_reply 0 '[]' '' api "repos/{owner}/{repo}/rules/branches/bare"
out="$(contract adapter_branch_rules bare 2>&1)"; st=$?
assert_status "branch rules: a branch no ruleset touches succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' api "repos/{owner}/{repo}/rules/branches/down"
out="$(contract adapter_branch_rules down 2>&1)"; st=$?
assert_status "branch rules: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 '{"total_count":3,"check_runs":[{"name":"build"}]}' '' \
  api 'repos/{owner}/{repo}/commits/aaaa/check-runs?per_page=1'
out="$(contract adapter_commit_has_check_runs aaaa 2>&1)"; st=$?
assert_status "commit has check runs: reads a commit's check runs" "$st" 0
assert_eq "yes where it has any" "$out" "yes"
gh_reply 0 '{"total_count":0,"check_runs":[]}' '' api 'repos/{owner}/{repo}/commits/bbbb/check-runs?per_page=1'
assert_eq "commit has check runs: no where it has none" "$(contract adapter_commit_has_check_runs bbbb 2>&1)" "no"
gh_reply 1 '' 'gh: Server Error (HTTP 502)' api 'repos/{owner}/{repo}/commits/cccc/check-runs?per_page=1'
out="$(contract adapter_commit_has_check_runs cccc 2>&1)"; st=$?
assert_status "commit has check runs: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "gh: Server Error (HTTP 502)"
gh_reply 0 'not json' '' api 'repos/{owner}/{repo}/commits/dddd/check-runs?per_page=1'
out="$(contract adapter_commit_has_check_runs dddd 2>&1)"; st=$?
assert_status "commit has check runs: an answer jq cannot read fails it" "$st" 1

gh_reply 0 '{"state":"success","total_count":1,"statuses":[{"context":"ci/legacy"}]}' '' \
  api "repos/{owner}/{repo}/commits/aaaa/status"
out="$(contract adapter_commit_has_statuses aaaa 2>&1)"; st=$?
assert_status "commit has statuses: reads a commit's combined status" "$st" 0
assert_eq "yes where it has any" "$out" "yes"
gh_reply 0 '{"state":"pending","total_count":0,"statuses":[]}' '' api "repos/{owner}/{repo}/commits/main/status"
assert_eq "commit has statuses: no where it has none" "$(contract adapter_commit_has_statuses main 2>&1)" "no"
gh_reply 1 '' 'gh: Server Error (HTTP 502)' api "repos/{owner}/{repo}/commits/cccc/status"
out="$(contract adapter_commit_has_statuses cccc 2>&1)"; st=$?
assert_status "commit has statuses: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "gh: Server Error (HTTP 502)"

gh_reply 0 '✓ Requested rerun of failed jobs' '' run rerun 4242 --failed
out="$(contract adapter_run_rerun 4242 2>&1)"; st=$?
assert_status "run rerun: reruns the run's failed jobs" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 403: Resource not accessible by integration' run rerun 4243 --failed
out="$(contract adapter_run_rerun 4243 2>&1)"; st=$?
assert_status "run rerun: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Resource not accessible by integration"
assert_eq "every CI operation was pinned to the resolved repo" \
  "$(grep -E ' (pr checks|api|run rerun) ' "$GH_FIXTURE/env.log" | grep -cv '^GH_REPO=acme/widgets GH_HOST=<unset> ')" "0"

# The sub-issue and dependency operations. These run gh api, whose --jq the
# operation owns, so each reply here is what that --jq printed. The writes
# take GitHub's database id, which the operation reads itself.
subs="repos/{owner}/{repo}/issues/50/sub_issues"
subs_jq="$(bash -c 'source "$1"; printf "%s" "$SUB_ISSUES_JQ"' _ "$ORCH")"
gh_reply 0 $'51\tOPEN\t0\n52\tCLOSED\t1\n' '' api --paginate "$subs" --jq "$subs_jq"
out="$(contract adapter_sub_issues 50 2>&1)"; st=$?
assert_status "sub-issues: lists a parent's sub-issues" "$st" 0
assert_eq "one per line: number, OPEN or CLOSED, and its open blockers, as TSV" \
  "$out" "$(printf '51\tOPEN\t0\n52\tCLOSED\t1')"
# The --jq itself, run on gh-shaped JSON: what the canned reply above stands
# in for. GitHub can leave the dependency summary off an issue; its blocker
# field is then empty, not a count.
assert_eq "its --jq reads GitHub's listing, a missing dependency summary as an empty blocker field" \
  "$(printf '%s' '[{"number":51,"state":"open","issue_dependencies_summary":{"blocked_by":0}},{"number":52,"state":"closed","issue_dependencies_summary":{"blocked_by":2}},{"number":53,"state":"open"}]' \
    | jq -r "$subs_jq")" "$(printf '51\tOPEN\t0\n52\tCLOSED\t2\n53\tOPEN\t')"
gh_reply 0 '' '' api --paginate "repos/{owner}/{repo}/issues/49/sub_issues" --jq "$subs_jq"
out="$(contract adapter_sub_issues 49 2>&1)"; st=$?
assert_status "sub-issues: a parent with none succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' api --paginate "repos/{owner}/{repo}/issues/48/sub_issues" --jq "$subs_jq"
out="$(contract adapter_sub_issues 48 2>&1)"; st=$?
assert_status "sub-issues: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 $'51000\n' '' api "repos/{owner}/{repo}/issues/51" --jq .id
gh_reply 0 '{}' '' api --method POST "$subs" -F sub_issue_id=51000
out="$(contract adapter_sub_issue_link 50 51 2>&1)"; st=$?
assert_status "sub-issue link: links the child by its database id" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 0 $'53000\n' '' api "repos/{owner}/{repo}/issues/53" --jq .id
gh_reply 1 '' 'HTTP 422: Sub issue may only have one parent' api --method POST "$subs" -F sub_issue_id=53000
out="$(contract adapter_sub_issue_link 50 53 2>&1)"; st=$?
assert_status "sub-issue link: a refused link fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 422: Sub issue may only have one parent"
gh_reply 1 '' 'HTTP 404: Not Found' api "repos/{owner}/{repo}/issues/404" --jq .id
out="$(contract adapter_sub_issue_link 50 404 2>&1)"; st=$?
assert_status "sub-issue link: a child gh cannot read fails it" "$st" 1
assert_eq "passing gh's stderr through, with no link attempted" "$out" "HTTP 404: Not Found"

gh_reply 0 '{}' '' api --method DELETE "repos/{owner}/{repo}/issues/50/sub_issue" -F sub_issue_id=51000
out="$(contract adapter_sub_issue_unlink 50 51 2>&1)"; st=$?
assert_status "sub-issue unlink: unlinks the child by its database id" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 403: Resource not accessible by integration' \
  api --method DELETE "repos/{owner}/{repo}/issues/50/sub_issue" -F sub_issue_id=53000
out="$(contract adapter_sub_issue_unlink 50 53 2>&1)"; st=$?
assert_status "sub-issue unlink: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Resource not accessible by integration"

gh_reply 0 $'https://api.github.com/repos/acme/widgets/issues/50\n' '' \
  api "repos/{owner}/{repo}/issues/51" --jq '.parent_issue_url // empty'
out="$(contract adapter_issue_parent 51 2>&1)"; st=$?
assert_status "issue parent: reads a sub-issue's parent" "$st" 0
assert_eq "printing its number alone, off the parent's URL" "$out" "50"
gh_reply 0 '' '' api "repos/{owner}/{repo}/issues/50" --jq '.parent_issue_url // empty'
out="$(contract adapter_issue_parent 50 2>&1)"; st=$?
assert_status "issue parent: an issue with no parent succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 0 $'https://api.github.com/repos/acme/widgets/issues/\n' '' \
  api "repos/{owner}/{repo}/issues/52" --jq '.parent_issue_url // empty'
out="$(contract adapter_issue_parent 52 2>&1)"; st=$?
assert_status "issue parent: a parent URL with no number fails it" "$st" 1
assert_contains "saying what it could not read" "$out" "no issue number"
gh_reply 1 '' 'HTTP 404: Not Found' api "repos/{owner}/{repo}/issues/404" --jq '.parent_issue_url // empty'
out="$(contract adapter_issue_parent 404 2>&1)"; st=$?
assert_status "issue parent: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 404: Not Found"

blocked="repos/{owner}/{repo}/issues/52/dependencies/blocked_by"
gh_reply 0 $'53\n51\n' '' api --paginate "$blocked" --jq '.[].number'
out="$(contract adapter_blockers 52 2>&1)"; st=$?
assert_status "blockers: lists an issue's blocked-by edges" "$st" 0
assert_eq "one blocker number per line, in GitHub's order" "$out" "$(writeln 53 51)"
gh_reply 1 '' 'HTTP 502: Bad Gateway' api --paginate "repos/{owner}/{repo}/issues/404/dependencies/blocked_by" --jq '.[].number'
out="$(contract adapter_blockers 404 2>&1)"; st=$?
assert_status "blockers: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 '{}' '' api --method POST "$blocked" -F issue_id=51000
out="$(contract adapter_blocker_add 52 51 2>&1)"; st=$?
assert_status "blocker add: adds the edge by the blocker's database id" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 422: Validation Failed' api --method POST "$blocked" -F issue_id=53000
out="$(contract adapter_blocker_add 52 53 2>&1)"; st=$?
assert_status "blocker add: a refused edge fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 422: Validation Failed"
out="$(contract adapter_blocker_add 52 404 2>&1)"; st=$?
assert_status "blocker add: a blocker gh cannot read fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 404: Not Found"

gh_reply 0 '{}' '' api --method DELETE "$blocked/51000"
out="$(contract adapter_blocker_remove 52 51 2>&1)"; st=$?
assert_status "blocker remove: removes the edge by the blocker's database id" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 404: Not Found' api --method DELETE "$blocked/53000"
out="$(contract adapter_blocker_remove 52 53 2>&1)"; st=$?
assert_status "blocker remove: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 404: Not Found"
assert_eq "every sub-issue and dependency operation was pinned to the resolved repo" \
  "$(grep -E ' api .*issues/' "$GH_FIXTURE/env.log" | grep -cv '^GH_REPO=acme/widgets GH_HOST=<unset> ')" "0"

# The repo operation. `gh repo view` ignores GH_REPO, so the operation names
# the repo it is handed in gh's argv, never leaving it to the guard's pin.
gh_reply 0 $'trunk\n' '' repo view acme/widgets --json defaultBranchRef --jq .defaultBranchRef.name
out="$(contract adapter_repo_default_branch acme/widgets 2>&1)"; st=$?
assert_status "repo default branch: reads the repo's default branch" "$st" 0
assert_eq "printing the bare branch name" "$out" "trunk"
assert_contains "naming the repo positionally, as gh repo view needs" "$(cat "$GH_FIXTURE/env.log")" \
  "GH_REPO=acme/widgets GH_HOST=<unset> repo view acme/widgets --json defaultBranchRef"
gh_reply 1 '' "GraphQL: Could not resolve to a Repository with the name 'acme/gone'. (repository)" \
  repo view acme/gone --json defaultBranchRef --jq .defaultBranchRef.name
out="$(contract adapter_repo_default_branch acme/gone 2>&1)"; st=$?
assert_status "repo default branch: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" \
  "GraphQL: Could not resolve to a Repository with the name 'acme/gone'. (repository)"

# The doctor-only operations (#551). Each case that asks gh the same argv as
# another runs in its own command substitution, with its own fixture gh, since
# the fixture answers one reply per argv.
gh_reply 0 $'github.com\n  Logged in to github.com account acme (keyring)\n' '' auth status
out="$(contract adapter_auth_status 2>&1)"; st=$?
assert_status "auth status: succeeds where gh is authenticated" "$st" 0
assert_contains "printing gh's own report" "$out" "Logged in to github.com"
assert_contains "pinned to the resolved repo" "$(cat "$GH_FIXTURE/env.log")" \
  "GH_REPO=acme/widgets GH_HOST=<unset> auth status"
out="$(gh_fixture; gh_reply 1 '' 'You are not logged into any GitHub hosts. To log in, run: gh auth login' auth status
  contract adapter_auth_status 2>&1)"; st=$?
assert_status "auth status: an unauthenticated gh fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "You are not logged into any GitHub hosts. To log in, run: gh auth login"

gh_reply 0 $'upstream/widgets\n' '' repo set-default --view
out="$(contract adapter_repo_local_default 2>&1)"; st=$?
assert_status "repo local default: reads gh's local default repo" "$st" 0
assert_eq "printing its owner/name" "$out" "upstream/widgets"
# gh 2.102.0 answers "none set" on stderr, exit 0.
out="$(gh_fixture; gh_reply 0 '' 'X No default remote repository has been set.' repo set-default --view
  contract adapter_repo_local_default 2>/dev/null)"; st=$?
assert_status "repo local default: none set succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
out="$(gh_fixture; gh_reply 1 '' 'not a git repository' repo set-default --view
  contract adapter_repo_local_default 2>&1)"; st=$?
assert_status "repo local default: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "not a git repository"

gh_reply 0 $'bug\nneeds-triage\n' '' label list --limit 1000 --json name --jq '.[].name'
out="$(contract adapter_labels 1000 2>&1)"; st=$?
assert_status "labels: lists the repo's label names" "$st" 0
assert_eq "one name per line" "$out" "$(writeln bug needs-triage)"
gh_reply 0 '' '' label list --limit 5 --json name --jq '.[].name'
out="$(contract adapter_labels 5 2>&1)"; st=$?
assert_status "labels: a repo with none succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' label list --limit 7 --json name --jq '.[].name'
out="$(contract adapter_labels 7 2>&1)"; st=$?
assert_status "labels: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

probe_list=(issue list --state all --limit 1 --json number --jq '.[0].number // empty')
gh_reply 0 $'7\n' '' "${probe_list[@]}"
gh_reply 0 '[]' '' api "repos/{owner}/{repo}/issues/7/sub_issues"
out="$(contract adapter_sub_issues_supported 2>&1)"; st=$?
assert_status "sub-issues supported: probes the sub-issues endpoint on an issue" "$st" 0
assert_eq "yes where it answers" "$out" "yes"
out="$(gh_fixture; gh_reply 0 $'8\n' '' "${probe_list[@]}"
  gh_reply 1 '' 'HTTP 404: Not Found' api "repos/{owner}/{repo}/issues/8/sub_issues"
  contract adapter_sub_issues_supported 2>/dev/null)"; st=$?
assert_status "sub-issues supported: an endpoint that refuses succeeds" "$st" 0
assert_eq "printing no" "$out" "no"
out="$(gh_fixture; gh_reply 0 '' '' "${probe_list[@]}"; contract adapter_sub_issues_supported 2>&1)"; st=$?
assert_status "sub-issues supported: a repo with no issue succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
out="$(gh_fixture; gh_reply 1 '' 'HTTP 502: Bad Gateway' "${probe_list[@]}"
  contract adapter_sub_issues_supported 2>&1)"; st=$?
assert_status "sub-issues supported: a gh failure listing issues fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"
assert_eq "every doctor operation was pinned to the resolved repo" \
  "$(grep -E ' (auth status|repo set-default|label list|issue list --state all|api repos/[{]owner[}]/[{]repo[}]/issues/7/)' "$GH_FIXTURE/env.log" \
    | grep -cv '^GH_REPO=acme/widgets GH_HOST=<unset> ')" "0"
rm -f "$ibody"
restore_suite_env GH_FIXTURE GH_HOST

# --- finding-triage scan -------------------------------------------------------
# The scan sorts each open filed finding still in needs-triage against the
# default branch: whether the code its **Location:** names, at the PR's head
# SHA, has changed since. The issues come from the store-backed fake
# (fake_github); the git side is a real fixture: a bare origin, a
# local clone that holds only the filing-time commit, and a second clone that
# pushes everything after it, so the scan has to fetch the default branch to
# see it.
echo
echo "finding-triage scan"
new_repo >/dev/null
git checkout -q -B main
seq_lines() { local i; for i in $(seq 1 "$2"); do echo "$1 line $i"; done; }
mkdir -p src
seq_lines app 12 >src/app.sh
seq_lines other 4 >src/other.sh
seq_lines gone 3 >src/gone.sh
git add -A && git commit -qm "the reviewed code"
head_sha="$(git rev-parse HEAD)"
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin main
git -C "$bare" symbolic-ref HEAD refs/heads/main
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
# Everything after the filing, made in a second clone and pushed: a fix on
# app.sh's line 3, then an unrelated edit further down the same file, then
# gone.sh deleted - and, under refs/pull/8/head alone, a PR head commit the
# local clone has never seen, as a squash merge leaves it.
work="$(mktemp -d)/work"
git clone -q "$bare" "$work"
git -C "$work" config user.email test@example.com
git -C "$work" config user.name Test
git -C "$work" checkout -q main
sed -i 's/^app line 3$/app line 3, fixed/' "$work/src/app.sh"
git -C "$work" commit -qam "fix line 3"
fix_sha="$(git -C "$work" rev-parse HEAD)"
sed -i 's/^app line 11$/app line 11, reworded/' "$work/src/app.sh"
git -C "$work" commit -qam "reword line 11"
reword_sha="$(git -C "$work" rev-parse HEAD)"
git -C "$work" rm -q src/gone.sh
git -C "$work" commit -qm "drop gone.sh"
git -C "$work" push -q origin main
git -C "$work" checkout -q -b pr8 "$head_sha"
echo "notes" >"$work/notes.txt"
git -C "$work" add notes.txt
git -C "$work" commit -qm "a later PR head"
pr_head_sha="$(git -C "$work" rev-parse HEAD)"
git -C "$work" push -q origin HEAD:refs/pull/8/head
origin_main="$(git -C "$bare" rev-parse main)"

fake_github
# finding <n> <labels, comma-separated> <location line|-> [pr] [state]: one
# issue in the fake's store, its body in the closer's filed shape.
finding() {
  local labels=()
  IFS=, read -r -a labels <<<"$2"
  fake_issue "$1" "${5:-open}" "${labels[@]}"
  if [ "$3" = - ]; then
    fake_issue_body "$1" "$(writeln 'A finding written by hand, with no labelled lines.')"
  else
    fake_issue_body "$1" "$(writeln '## Finding' '' '> The reviewer said this.' '' '**Axis:** Standards' '' \
      '**Severity:** nit - a reason.' '' "**Location:** $3" '' \
      "**PR:** https://github.com/acme/widgets/pull/${4:-7}" '' \
      '**Why not fixed in the loop:** found in the final iteration.')"
  fi
}
finding 1 "review:nit,needs-triage" "\`src/other.sh:2\` at $head_sha"
finding 2 "review:major,needs-triage,bug" "\`src/app.sh:3\` at $head_sha"
finding 3 "review:nit,needs-triage" "\`src/app.sh:40\` (and \`:41\`) at $head_sha"
finding 4 "review:nit,needs-triage" "\`src/gone.sh:1\` at $head_sha"
finding 5 "review:major,needs-triage" "\`src/app.sh:3\` at 0123456789abcdef0123456789abcdef01234567"
finding 6 "review:nit,needs-triage" -
finding 7 "review:nit,needs-triage" "\`src/other.sh:2\` at $pr_head_sha" 8
finding 8 "review:nit,ready-for-agent" "\`src/other.sh:2\` at $head_sha"
finding 9 "review:nit,needs-triage" "\`src/other.sh:2\` at $head_sha" 7 CLOSED
finding 10 "needs-triage" "\`src/other.sh:2\` at $head_sha"
scan() { orch_gh_failing finding-triage scan "$@"; }
# line_of <n> <out>: the scan's line for issue n.
line_of() { printf '%s\n' "$2" | awk -F'\t' -v n="$1" '$1 == n'; }
field_of() { line_of "$1" "$3" | cut -f"$2"; }

before_refs="$(git for-each-ref refs/heads)"
before_head="$(git rev-parse HEAD) $(git symbolic-ref -q HEAD)"
before_tree="$(git status --porcelain)"
before_store="$(fake_snapshot)"
out="$(scan 2>&1)"; st=$?
assert_status "scans the open filed findings" "$st" 0
assert_eq "one tab-separated line of five fields per finding" \
  "$(printf '%s\n' "$out" | awk -F'\t' 'NF != 5' | wc -l | tr -d ' ')" "0"
assert_eq "an unchanged file's finding: issue, PR, location, result, empty detail" \
  "$(line_of 1 "$out")" "$(printf '1\t7\tsrc/other.sh:2\tunchanged\t')"
assert_eq "a finding whose lines a later commit fixed is changed" "$(field_of 2 4 "$out")" "changed"
assert_eq "naming that commit's full SHA, not the newer one elsewhere in the file" \
  "$(field_of 2 5 "$out")" "$fix_sha"
assert_eq "a line range the file no longer reaches is changed too" "$(field_of 3 4 "$out")" "changed"
assert_eq "naming the newest commit touching the file" "$(field_of 3 5 "$out")" "$reword_sha"
assert_eq "a deleted file's finding is gone" "$(field_of 4 4 "$out")" "gone"
assert_eq "with no detail" "$(field_of 4 5 "$out")" ""
assert_eq "an unreachable head SHA is unknown" "$(field_of 5 4 "$out")" "unknown"
assert_contains "saying the SHA was unreachable" "$(field_of 5 5 "$out")" "unreachable"
assert_eq "a body without the labelled lines is unknown" "$(field_of 6 4 "$out")" "unknown"
assert_contains "saying the body does not parse" "$(field_of 6 5 "$out")" "Location"
assert_eq "a SHA only the PR's head ref holds is fetched, not unknown" "$(field_of 7 4 "$out")" "unchanged"
assert_eq "naming that PR" "$(field_of 7 2 "$out")" "8"
assert_eq "an already triaged finding is not scanned" "$(line_of 8 "$out")" ""
assert_eq "nor a closed one" "$(line_of 9 "$out")" ""
assert_eq "nor an issue that is not a filed finding" "$(line_of 10 "$out")" ""
# Every result path's exact line, pinned byte for byte.
assert_eq "a changed finding's exact line" \
  "$(line_of 2 "$out")" "$(printf '2\t7\tsrc/app.sh:3\tchanged\t%s' "$fix_sha")"
assert_eq "a gone finding's exact line" \
  "$(line_of 4 "$out")" "$(printf '4\t7\tsrc/gone.sh:1\tgone\t')"
assert_eq "an unreachable head SHA's exact line" "$(line_of 5 "$out")" \
  "$(printf '5\t7\tsrc/app.sh:3\tunknown\thead SHA 0123456789abcdef0123456789abcdef01234567 is unreachable, even after fetching refs/pull/7/head')"
assert_eq "a body with no Location line: its exact line" "$(line_of 6 "$out")" \
  "$(printf '6\t-\t-\tunknown\tbody does not parse: no **Location:** line naming `<file>:<line>` at <SHA>')"
assert_eq "the findings come in issue order" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "1 2 3 4 5 6 7 "
assert_ne "lists the major findings still in needs-triage" "$(line_of 5 "$out")" ""
assert_ne "and the nit ones" "$(line_of 6 "$out")" ""
assert_eq "writes nothing to GitHub" "$(fake_snapshot)" "$before_store"
assert_eq "fetches the default branch first" "$(git rev-parse origin/main)" "$origin_main"
assert_eq "and leaves the branches as they were" "$(git for-each-ref refs/heads)" "$before_refs"
assert_eq "HEAD too" "$(git rev-parse HEAD) $(git symbolic-ref -q HEAD)" "$before_head"
assert_eq "and the working tree" "$(git status --porcelain)" "$before_tree"

out="$(scan --pr 8 2>&1)"; st=$?
assert_status "narrows to one source PR" "$st" 0
assert_eq "scanning only that PR's findings" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "7 "

out="$(scan 2 2>&1)"; st=$?
assert_status "scans one explicit finding" "$st" 0
assert_eq "and only it" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "2 "
out="$(scan 9 2>&1)"; st=$?
assert_status "refuses an explicit finding that is closed" "$st" 1
assert_contains "saying so" "$out" "not open"
out="$(scan 8 2>&1)"; st=$?
assert_status "refuses one already triaged" "$st" 1
assert_contains "naming the missing triage label" "$out" "needs-triage"
out="$(scan 10 2>&1)"; st=$?
assert_status "refuses an issue that is not a filed finding" "$st" 1
assert_contains "naming the missing severity label" "$out" "review:"
out="$(scan 2 --pr 8 2>&1)"; st=$?
assert_status "takes an issue or a PR, not both" "$st" 1

# A blocking finding is fixed in the loop, never filed: an explicit issue
# labelled review:blocking is not a filed finding.
finding 12 "review:blocking,needs-triage" "\`src/other.sh:2\` at $head_sha"
out="$(scan 12 2>&1)"; st=$?
assert_status "refuses an explicit issue whose severity is never filed" "$st" 1
assert_contains "naming the filed severities" "$out" "review:major"
fake_issue 12 closed

# A PR head that edited the file and never reached the default branch: the
# file differs, yet no commit since the filing touched it there, so the scan
# names no commit older than the filing.
git -C "$work" checkout -q -b pr11 "$head_sha"
sed -i 's/^other line 2$/other line 2, on the PR only/' "$work/src/other.sh"
git -C "$work" commit -qam "an unmerged PR edit"
unmerged_sha="$(git -C "$work" rev-parse HEAD)"
git -C "$work" push -q origin HEAD:refs/pull/11/head
finding 11 "review:nit,needs-triage" "\`src/other.sh:2\` at $unmerged_sha" 11
out="$(scan 11 2>&1)"; st=$?
assert_status "scans a finding filed on a PR edit that never landed" "$st" 0
assert_eq "it is unknown, not changed by a commit older than the filing" "$(field_of 11 4 "$out")" "unknown"
assert_contains "saying no commit since the filing touched the file" "$(field_of 11 5 "$out")" "no commit"
assert_eq "its exact line" "$(line_of 11 "$out")" \
  "$(printf '11\t11\tsrc/other.sh:2\tunknown\tno commit on the default branch since %s touched src/other.sh - the difference is commits that never reached it' "$unmerged_sha")"
fake_issue 11 closed

# A finding whose lines the scan follows to the default branch, where later
# commits touched only other lines of its file (line 3's fix, line 11's
# reword): its lines are unchanged, so no commit is named.
finding 14 "review:nit,needs-triage" "\`src/app.sh:6\` at $head_sha" 14
out="$(scan 14 2>&1)"; st=$?
assert_status "scans a finding whose file changed only elsewhere" "$st" 0
assert_eq "its followed, untouched lines are unchanged, with empty detail" \
  "$(line_of 14 "$out")" "$(printf '14\t14\tsrc/app.sh:6\tunchanged\t')"
fake_issue 14 closed

# A body with its **Location:** line but no **PR:** line does not parse either.
fake_issue 16 open review:nit needs-triage
fake_issue_body 16 "$(writeln '## Finding' '' "**Location:** \`src/other.sh:2\` at $head_sha")"
out="$(scan 16 2>&1)"; st=$?
assert_status "scans a finding whose body names no PR" "$st" 0
assert_eq "it is unknown, its exact line naming the missing PR line" "$(line_of 16 "$out")" \
  "$(printf '16\t-\tsrc/other.sh:2\tunknown\tbody does not parse: no **PR:** line ending in a pull request URL')"
fake_issue 16 closed

# A finding whose file later gets hunks both before and after its line, with
# far more diff after the matching hunk than a pipe buffer holds: the line
# mapping stops reading the diff early, and the scan must still finish. Lines
# inserted above the finding shift it; only the commit that touched the
# shifted line is the answer, the bulk rewrite below it is not.
git -C "$work" checkout -q main
seq_lines "big file" 6000 >"$work/src/big.sh"
git -C "$work" add src/big.sh
git -C "$work" commit -qm "a big file"
big_sha="$(git -C "$work" rev-parse HEAD)"
{ seq_lines inserted 5; cat "$work/src/big.sh"; } >"$work/big.tmp" && mv "$work/big.tmp" "$work/src/big.sh"
git -C "$work" commit -qam "insert five lines on top"
sed -i 's/^big file line 10$/big file line 10, fixed/' "$work/src/big.sh"
git -C "$work" commit -qam "fix the shifted line"
shifted_fix_sha="$(git -C "$work" rev-parse HEAD)"
sed -i '200,$ s/$/, rewritten in bulk/' "$work/src/big.sh"
git -C "$work" commit -qam "rewrite everything below"
git -C "$work" push -q origin main
finding 13 "review:nit,needs-triage" "\`src/big.sh:10\` at $big_sha" 13
out="$(scan 13 2>&1)"; st=$?
assert_status "scans a finding whose file has a large diff after its line" "$st" 0
assert_eq "it is changed" "$(field_of 13 4 "$out")" "changed"
assert_eq "naming the commit that touched the shifted line" "$(field_of 13 5 "$out")" "$shifted_fix_sha"
fake_issue 13 closed

# Each severity's list is cut off at the issue-list limit; a list that
# reaches it may be missing findings past it, and the scan says so on stderr
# while it carries on. Open in needs-triage here: two major findings (2, 5)
# and five nit ones (1, 3, 4, 6, 7).
err="$(mktemp)"
out="$(ORCH_ISSUE_LIST_LIMIT=5 scan 2>"$err")"; st=$?
assert_status "a list at the issue-list limit does not stop the scan" "$st" 0
assert_contains "warns that the nit list reached the limit, naming the label and the limit" "$(cat "$err")" \
  "orch: review:nit findings reached the issue-list limit of 5 - any past it are missing from this scan"
assert_not_contains "but not the major list, below it" "$(cat "$err")" "review:major"
assert_eq "and still prints its lines" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "1 2 3 4 5 6 7 "
out="$(ORCH_ISSUE_LIST_LIMIT=6 scan 2>"$err")"; st=$?
assert_status "scans with every list one below the limit" "$st" 0
assert_not_contains "and gives no warning" "$(cat "$err")" "issue-list limit"
rm -f "$err"

# The triage label is the repo's name for the role, as review file files it.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' >docs/agents/triage-labels.md
finding 15 "review:nit,triage me" "\`src/other.sh:2\` at $head_sha"
out="$(scan 2>&1)"
assert_eq "lists under the repo's own name for needs-triage, and only it" \
  "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "15 "
rm docs/agents/triage-labels.md
restore_suite_env

# --- finding-triage apply ------------------------------------------------------
# Apply is finding triage's one write to GitHub: the comment, with the AI
# disclaimer on top, then the labels and, for the closing outcomes, the close.
# The store-backed fake (fake_github) applies each comment, label edit and
# close to the issue it holds, so what an outcome leaves on the issue is read
# back from the issue itself, as is the category label apply creates.
echo
echo "finding-triage apply"
new_repo >/dev/null
fake_github
tab="$(printf '\t')"
comment="$(mktemp)"
writeln 'Fixed by abc1234 on main.' >"$comment"
disclaimer='> *This was generated by AI during triage.*'
# triaged <n> <labels, comma-separated>: one filed finding in the fake's store.
triaged() {
  local labels=()
  IFS=, read -r -a labels <<<"$2"
  fake_issue "$1" open "${labels[@]}"
  fake_issue_body "$1" '**Axis:** Spec'
}
apply() { orch_gh_failing finding-triage apply "$@"; }

for outcome in close-fixed wontfix ready-for-agent ready-for-human; do
  triaged 2 "review:major,needs-triage,bug"
  case "$outcome" in
    close-fixed|wontfix) out="$(apply 2 "$outcome" --comment-file "$comment" 2>&1)"; st=$? ;;
    *) out="$(apply 2 "$outcome" --category bug --comment-file "$comment" 2>&1)"; st=$? ;;
  esac
  assert_status "applies $outcome" "$st" 0
  assert_eq "posting the comment under the AI disclaimer ($outcome)" \
    "$(fake_comments_of 2)" "$(writeln "$disclaimer" '' 'Fixed by abc1234 on main.')"
done

triaged 2 "review:major,needs-triage,bug"
out="$(apply 2 close-fixed --comment-file "$comment" 2>&1)"; st=$?
assert_status "closes a fixed finding" "$st" 0
assert_eq "closed" "$(fake_state_of 2)" "CLOSED"
assert_eq "as completed" "$(fake_reason_of 2)" "completed"
assert_eq "out of needs-triage, with no state label added" "$(fake_labels_of 2)" "bug review:major "

triaged 3 "review:nit,needs-triage,enhancement"
out="$(apply 3 wontfix --comment-file "$comment" 2>&1)"; st=$?
assert_status "closes a finding as wontfix" "$st" 0
assert_eq "closed" "$(fake_state_of 3)" "CLOSED"
assert_eq "as not planned" "$(fake_reason_of 3)" "not planned"
assert_eq "out of needs-triage and into wontfix" "$(fake_labels_of 3)" "enhancement review:nit wontfix "

triaged 2 "review:major,needs-triage,bug"
out="$(apply 2 ready-for-agent --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_status "sends a finding to an agent" "$st" 0
assert_eq "out of needs-triage, into ready-for-agent, its severity and category kept" \
  "$(fake_labels_of 2)" "bug ready-for-agent review:major "
assert_eq "and left open" "$(fake_state_of 2)" "OPEN"

triaged 2 "review:major,needs-triage,bug"
out="$(apply 2 ready-for-human --category enhancement --comment-file "$comment" 2>&1)"; st=$?
assert_status "sends a finding to a human, flipping its category" "$st" 0
assert_eq "leaving exactly the one category asked for" \
  "$(fake_labels_of 2)" "enhancement ready-for-human review:major "
assert_contains "creating that category's label with GitHub's default colour and description" \
  "$(fake_labels)" "enhancement${tab}a2eeef${tab}New feature or request"

# A finding already out of needs-triage leaves apply nothing to remove: a
# close needs no relabel, and a relabel removes nothing.
triaged 5 "review:minor,bug"
fake_fail adapter_issue_relabel
out="$(apply 5 close-fixed --comment-file "$comment" 2>&1)"; st=$?
assert_status "closes a fixed finding not in needs-triage, with no relabel" "$st" 0
assert_eq "its labels as they were" "$(fake_labels_of 5)" "bug review:minor "
assert_eq "as completed" "$(fake_state_of 5) $(fake_reason_of 5)" "CLOSED completed"
fake_github
triaged 5 "review:minor,bug"
out="$(apply 5 wontfix --comment-file "$comment" 2>&1)"; st=$?
assert_status "closes a finding not in needs-triage as wontfix" "$st" 0
assert_eq "into wontfix" "$(fake_labels_of 5)" "bug review:minor wontfix "
triaged 5 "review:minor,bug"
out="$(apply 5 ready-for-agent --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_status "sends a finding not in needs-triage to an agent" "$st" 0
assert_eq "into ready-for-agent" "$(fake_labels_of 5)" "bug ready-for-agent review:minor "

# A finding filed before categories were has none: apply gives it one.
triaged 4 "review:nit,needs-triage"
out="$(apply 4 ready-for-agent --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_status "categorises a finding filed with no category" "$st" 0
assert_eq "with the one asked for" "$(fake_labels_of 4)" "bug ready-for-agent review:nit "

for outcome in ready-for-agent ready-for-human; do
  triaged 2 "review:major,needs-triage,bug"
  before_store="$(fake_snapshot)"
  out="$(apply 2 "$outcome" --comment-file "$comment" 2>&1)"; st=$?
  assert_status "refuses $outcome with no category" "$st" 1
  assert_contains "naming --category ($outcome)" "$out" "--category"
  assert_eq "touching nothing ($outcome)" "$(fake_snapshot)" "$before_store"
done
for outcome in close-fixed wontfix; do
  before_store="$(fake_snapshot)"
  out="$(apply 2 "$outcome" --category bug --comment-file "$comment" 2>&1)"; st=$?
  assert_status "refuses a category on $outcome" "$st" 1
  assert_contains "naming --category ($outcome)" "$out" "--category"
  assert_eq "touching nothing ($outcome)" "$(fake_snapshot)" "$before_store"
done
out="$(apply 2 ready-for-agent --category feature --comment-file "$comment" 2>&1)"; st=$?
assert_status "refuses a category that is neither bug nor enhancement" "$st" 1
assert_eq "in exactly these words" "$out" "orch: unknown --category 'feature' - expected bug or enhancement"
out="$(apply 2 ready-for-human --category "" --comment-file "$comment" 2>&1)"; st=$?
assert_status "refuses an empty category" "$st" 1
assert_eq "in its own words" "$out" "orch: ready-for-human needs --category <bug|enhancement>"
out="$(apply 2 promote --comment-file "$comment" 2>&1)"; st=$?
assert_status "refuses an unknown outcome" "$st" 1
out="$(apply 2 close-fixed 2>&1)"; st=$?
assert_status "refuses no comment file" "$st" 1
out="$(apply 2 close-fixed --comment-file /nonexistent/comment.md 2>&1)"; st=$?
assert_status "refuses a comment file that is not there" "$st" 1

# A category label gh will not create - most often because the repo has it -
# does not stop apply, and the repo's own is never overwritten.
triaged 2 "review:major,needs-triage,bug"
fake_label bug 123456 "The repo's own bug"
out="$(apply 2 ready-for-agent --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_status "a category label the repo has already does not stop apply" "$st" 0
assert_eq "the labels are still applied" "$(fake_labels_of 2)" "bug ready-for-agent review:major "
assert_contains "and the repo's own is left as it is" "$(fake_labels)" "bug${tab}123456${tab}The repo's own bug"

# Any other failed gh call does, with the reason.
for op in adapter_issue_state_labels adapter_issue_comment adapter_issue_relabel adapter_issue_close; do
  fake_github
  triaged 2 "review:major,needs-triage,bug"
  fake_fail "$op" "HTTP 502: Bad Gateway"
  out="$(apply 2 wontfix --comment-file "$comment" 2>&1)"; st=$?
  assert_status "dies when gh fails ($op)" "$st" 1
  assert_contains "saying gh failed on the issue ($op)" "$out" "gh could not"
  assert_contains "with gh's reason ($op)" "$out" "HTTP 502: Bad Gateway"
done

# Every state label is the repo's name for the role.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' \
        '| `ready-for-agent`          | `afk`                | Agent it    |' \
        '| `wontfix`                  | `nope`               | Not doing   |' >docs/agents/triage-labels.md
triaged 2 "review:major,triage me,bug"
out="$(apply 2 ready-for-agent --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_eq "moves a finding between the repo's own triage labels" "$(fake_labels_of 2)" "afk bug review:major "
triaged 3 "review:nit,triage me,enhancement"
out="$(apply 3 wontfix --comment-file "$comment" 2>&1)"; st=$?
assert_eq "wontfix included" "$(fake_labels_of 3)" "enhancement nope review:nit "
rm docs/agents/triage-labels.md
restore_suite_env

# --- spec ---------------------------------------------------------------------
# The spec review's one hand on GitHub: fetch the body, replace it, comment on
# it. The number comes from state so a review can never touch the wrong issue,
# and the store-backed fake (fake_github) holds what reached GitHub, so the
# test reads the body sent back, not only that the command exited zero -
# the fixture gh's log stays empty across every call below, proving none of them ever
# spawns a real gh subprocess. The real operations are pinned in "gh adapter
# contract".
echo
echo "spec"
fresh_flow spectest
fake_github
state_fixture phase review
spec_body="$(mktemp)"
out="$("$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "fetch refuses when state records no issue" "$st" 1
assert_contains "naming the phase that records one" "$out" "spec phase"
out="$("$ORCH" spec update "$spec_body" 2>&1)"; st=$?
assert_status "update refuses too" "$st" 1
assert_contains "for the same reason" "$out" "spec phase"
out="$("$ORCH" spec comment "$spec_body" 2>&1)"; st=$?
assert_status "and comment" "$st" 1
assert_contains "likewise" "$out" "spec phase"

"$ORCH" state set issue 14
fake_issue 14 open
fake_issue 15 open
# A body with everything a heredoc or a shell quote would mangle: a table, a
# fence, a `#nn` reference. What the lenses read must be what GitHub holds.
tricky="$(mktemp)"
writeln '## Solution' '' \
        '| Lens | Reads |' '|---|---|' '| Fidelity | plan handoff |' '' \
        '```sh' 'orch.sh spec fetch "$file"' '```' '' \
        'Tracked in #6; see `$HOME` and '"'"'quoted'"'"' text.' >"$tricky"
rm -f "$spec_body"
: >"$GH_FIXTURE/env.log"
fake_issue_body 14 "$(cat "$tricky")"
fake_issue_body 15 "Not the flow's issue."
untouched_15="$(fake_snapshot | grep '/issues/15/')"
out="$("$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "fetch writes the body to the file" "$st" 0
assert_eq "of the issue state records, exactly as GitHub holds it - table, fence, and #nn survive" \
  "$(cat "$spec_body")" "$(cat "$tricky")"
assert_eq "the view call never reached a real gh subprocess" "$(gh_calls)" "0"

# The skill fetches into a fresh directory under .orchestrator/, so the first
# fetch of a review is the one that has to create it.
out="$("$ORCH" spec fetch .orchestrator/spec-review/spec.md 2>&1)"; st=$?
assert_status "fetch creates the directory it is told to write into" "$st" 0
assert_eq "and the body lands there" "$(cat .orchestrator/spec-review/spec.md)" "$(cat "$tricky")"
rm -rf .orchestrator/spec-review

rm -f "$spec_body"
fake_fail adapter_issue_body "fake gh: issue view refused"
out="$("$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "a gh that will not answer fails the fetch" "$st" 1
assert_contains "with the reason" "$out" "issue view refused"
assert_eq "and leaves no file a lens could mistake for a body" \
  "$([ -e "$spec_body" ] && echo present || echo gone)" "gone"

: >"$GH_FIXTURE/env.log"
fake_issue_body 14 "The old body."
out="$("$ORCH" spec update "$tricky" 2>&1)"; st=$?
assert_status "update replaces the body" "$st" 0
assert_eq "of the issue state records, with the file's contents" "$(fake_body_of 14)" "$(cat "$tricky")"
assert_eq "and no other" "$(fake_snapshot | grep '/issues/15/')" "$untouched_15"
assert_eq "and prints nothing" "$out" ""
assert_eq "the edit call never reached a real gh subprocess" "$(gh_calls)" "0"

before_store="$(fake_snapshot)"
out="$("$ORCH" spec update /nonexistent/body.md 2>&1)"; st=$?
assert_status "update refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and nothing reaches gh" "$(fake_snapshot)" "$before_store"

fake_fail adapter_issue_body_edit "fake gh: issue edit refused"
out="$("$ORCH" spec update "$tricky" 2>&1)"; st=$?
assert_status "a gh that will not edit fails the update" "$st" 1
assert_contains "with gh's reason" "$out" "issue edit refused"
assert_contains "and the issue it was for" "$out" "issue #14"

: >"$GH_FIXTURE/env.log"
out="$("$ORCH" spec comment "$tricky" 2>&1)"; st=$?
assert_status "comment posts the file" "$st" 0
assert_eq "on the issue state records, with the file's contents as the comment" \
  "$(fake_comments_of 14)" "$(cat "$tricky")"
assert_eq "and no other" "$(fake_snapshot | grep '/issues/15/')" "$untouched_15"
assert_eq "the comment call never reached a real gh subprocess" "$(gh_calls)" "0"

before_store="$(fake_snapshot)"
out="$("$ORCH" spec comment /nonexistent/body.md 2>&1)"; st=$?
assert_status "comment refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and nothing reaches gh" "$(fake_snapshot)" "$before_store"

fake_fail adapter_issue_comment "fake gh: issue comment refused"
out="$("$ORCH" spec comment "$tricky" 2>&1)"; st=$?
assert_status "a gh that will not comment fails it" "$st" 1
assert_contains "with gh's reason" "$out" "issue comment refused"
assert_contains "and the issue it was for" "$out" "issue #14"

# state.json outlives the flow it records: at phase done, the issue it names
# is finished work, so the flow-bound spec ops refuse it and point at the
# stateless issue ops for whatever issue the caller actually meant.
prior_phase="$("$ORCH" state get phase)"
state_fixture phase "done"
fake_github
fake_issue 14 open
fake_issue_body 14 "The flow's spec."
for op in fetch update comment; do
  before_store="$(fake_snapshot)"
  out="$("$ORCH" spec "$op" "$tricky" 2>&1)"; st=$?
  assert_status "spec $op refuses once the flow is done" "$st" 1
  assert_contains "naming the flow's issue" "$out" "issue #14"
  assert_contains "and pointing at issue $op for another issue" "$out" "issue $op <n>"
  assert_eq "and nothing reaches gh" "$(fake_snapshot)" "$before_store"
done
state_fixture phase spec
spec_scratch="$(mktemp)"
out="$("$ORCH" spec fetch "$spec_scratch" 2>&1)"; st=$?
assert_status "spec fetch still works at phase spec" "$st" 0
out="$("$ORCH" spec update "$tricky" 2>&1)"; st=$?
assert_status "spec update still works at phase spec" "$st" 0
assert_eq "on the flow's issue" "$(fake_body_of 14)" "$(cat "$tricky")"
out="$("$ORCH" spec comment "$tricky" 2>&1)"; st=$?
assert_status "spec comment still works at phase spec" "$st" 0
assert_eq "on the flow's issue" "$(fake_comments_of 14)" "$(cat "$tricky")"
rm -f "$spec_scratch"
state_fixture phase "$prior_phase"

# spec comments: the active flow's spec issue's comments, the number from
# state (issue #361).
spec_comments="$(mktemp)"
fake_github
fake_issue 14 open
fake_comment 14 pat 2026-09-02T11:30:00Z "A follow-up."
fake_issue 15 open
fake_comment 15 pat 2026-09-02T11:31:00Z "Not the flow's issue."
out="$("$ORCH" spec comments "$spec_comments" 2>&1)"; st=$?
assert_status "spec comments writes the flow issue's comments" "$st" 0
assert_eq "of the issue state records, each opened by its marker line" "$(cat "$spec_comments")" \
  "$(writeln '<!-- comment @pat 2026-09-02T11:30:00Z -->' 'A follow-up.')"
state_fixture phase "done"
: >"$spec_comments"
out="$("$ORCH" spec comments "$spec_comments" 2>&1)"; st=$?
assert_status "spec comments refuses once the flow is done" "$st" 1
assert_contains "naming the flow's issue" "$out" "issue #14"
assert_contains "and pointing at issue comments for another issue" "$out" "issue comments <n>"
assert_eq "and reads nothing into the file" "$(wc -c <"$spec_comments" | tr -d ' ')" "0"
state_fixture phase "$prior_phase"
rm -f "$spec_comments"
assert_contains "help documents spec comments" "$("$ORCH" help)" "spec comments"
out="$("$ORCH" spec 2>&1)"; st=$?
assert_status "spec with no op refuses" "$st" 1
assert_contains "naming the missing op as <none>" "$out" "unknown spec op: <none>"
assert_contains "and listing the ops, comments among them" "$out" "fetch|update|comment|comments"

out="$("$ORCH" spec publish "$tricky" 2>&1)"; st=$?
assert_status "refuses an op it does not have" "$st" 1
assert_contains "naming the four it does" "$out" "fetch|update|comment|comments"
out="$("$ORCH" spec fetch 2>&1)"; st=$?
assert_status "and a call with no file" "$st" 1
assert_contains "with the usage" "$out" "usage: orch.sh spec"
assert_contains "help documents the spec verb" "$("$ORCH" help)" "spec fetch"
assert_contains "help says the spec ops refuse once the flow is done" "$("$ORCH" help)" "refusing once the flow is done"
assert_contains "and points at issue <op> for any other issue" "$("$ORCH" help)" "issue <op> <n> <file>"
restore_suite_env

# --- doctor at the review phase ---------------------------------------------
# Three handoffs are due from review onwards, and only three: a flow started
# under the old loop machinery carries a `loop` key doctor neither reports nor
# touches, and is asked for no handoff a loop would have written.
echo
echo "doctor at the review phase"
review_flow reviewdoctor
doctor_github
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a review-phase flow with its three handoffs is healthy" "$st" 0
assert_contains "counts the implement handoff among them" "$out" "handoff 03-implement.md complete"

state_fixture loop 2
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a stray loop key from an older flow still passes" "$st" 0
assert_eq "and earns no mention of a handoff no loop writes any more" \
  "$(printf '%s\n' "$out" | grep -c '04-review.md')" "0"
assert_eq "nor a line reporting the key" \
  "$(printf '%s\n' "$out" | grep -c 'loop: 2')" "0"
assert_eq "and the key is left as it was" "$("$ORCH" state get | jq -r .loop)" "2"

# The per-loop record directories an older flow left behind are the other
# artefact story 37 names: ignored, not moved, and never a reason to fail.
mkdir -p .orchestrator/review/loop-01
: > .orchestrator/review/loop-01/iteration-01.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a stray review/loop-NN/ directory from an older flow still passes" "$st" 0
assert_eq "and earns no line of its own" \
  "$(printf '%s\n' "$out" | grep -c 'loop-01')" "0"
assert_eq "and is left where it was" \
  "$([ -f .orchestrator/review/loop-01/iteration-01.md ] && echo present || echo gone)" "present"
restore_suite_env

# --- review ready -----------------------------------------------------------
# Marking the PR ready and recording the flow as done are one operation, because
# either half alone is a lie: a `done` flow over a draft PR, or a PR promoted out
# of draft by a flow that still thinks it is reviewing.
#
# Goes through the store-backed fake (fake_github) - the fixture gh's log stays empty
# across both calls, proving neither reaches a real gh subprocess. The real
# operation is pinned in "gh adapter contract".
echo
echo "review ready"
review_flow reviewready
state_fixture pr 7
fake_github
fake_pr 7 open orch/1-reviewready main
fake_pr_draft 7
: >"$GH_FIXTURE/env.log"
fake_fail adapter_pr_ready
out="$("$ORCH" review ready 2>&1)"; st=$?
assert_status "fails when GitHub will not mark the PR ready" "$st" 1
assert_eq "and leaves the phase where it was rather than half-finishing" \
  "$("$ORCH" state get phase)" "review"
assert_eq "with the PR still a draft" "$(fake_pr_draft_of 7)" "yes"
rm -rf "$ORCH_GH_FAKE_STORE/fail"
"$ORCH" review ready >/dev/null
assert_eq "records the flow as done once the PR is ready" "$("$ORCH" state get phase)" "done"
assert_eq "the PR no longer a draft" "$(fake_pr_draft_of 7)" "no"
assert_eq "and neither call ever reached a real gh subprocess" "$(gh_calls)" "0"
state_fixture phase review
restore_suite_env

# --- review ci --------------------------------------------------------------
# The classification is what decides whether a PR may be marked ready, so each
# of the four answers is asserted for its exit status as well as its word.
#
# Every GitHub read here goes through the store-backed fake: fake_checks
# scripts the checks each scope answers, call by call, and the base tip's one
# check run (fake_check_run main) is the CI evidence that keeps the grace,
# until a case below says otherwise. How the real operations read gh -
# --required, exit 8 for pending, an answer jq cannot read - is pinned by
# their contract tests in "gh adapter contract".
echo
echo "review ci"
review_ci_flow reviewci
: >"$GH_FIXTURE/env.log"
fake_checks 7 all green
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "green checks let the loop finish" "$st" 0
assert_first_line "and say so in one word" "$out" "green"
assert_eq "the checks call never reached a real gh subprocess" "$(gh_calls)" "0"

fake_checks 7 all failing
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "a failing check stops the loop" "$st" 1
assert_first_line "classified as failing" "$out" "failing"
assert_contains "names the check that failed" "$out" "build"
assert_eq "and not the ones that passed" "$(printf '%s\n' "$out" | grep -c 'lint')" "0"

# A cancelled run is not a run that passed, and it is never going to report. It
# classifies as failing, which is also the arm that offers the flake rerun - the
# right remedy for a check that was killed rather than one that judged the change.
fake_checks 7 all cancel
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "a cancelled check stops the loop too" "$st" 1
assert_first_line "classified as failing rather than waited on" "$out" "failing"
assert_contains "naming the check that was cancelled" "$out" "build"

# Requiring CI in a repo that has none would make the plugin unusable in its own
# repo, which has none.
fake_checks 7 all none
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "a repo with no checks at all is not thereby failing" "$st" 0
assert_first_line "classified as none" "$out" "none"

# The grace period is the whole reason `none` is not concluded on the first
# answer: this is the CI-having repo that would otherwise be called CI-less. It
# is spent on the *required* probe, because gh reports "no required checks"
# whether the repo requires nothing or requires something that has not landed
# yet. Widening to every check on the commit before the grace is out is how an
# unrelated green check gets mistaken for a required one that never arrived - so
# the unfiltered answer here is `failing`, and a green result proves it was never
# consulted. The grace is set well clear of a whole-second wall-clock tick, so
# what the test proves is the second answer winning rather than how fast the
# first one came.
fake_checks 7 required none green
fake_checks 7 all failing
out="$(ORCH_CI_GRACE=5 "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "a required check that has not registered yet is waited for" "$out" "green"
assert_status "and the loop finishes on the answer it waited for" "$st" 0

# Where branch protection names required checks, those are the checks that
# matter - and a failure outside them is not the flow's business.
fake_checks 7 required green
fake_checks 7 all failing
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "required checks decide it where branch protection names them" "$st" 0
assert_first_line "so the unfiltered answer is never asked for" "$out" "green"

# ...and where it names none, the answer is every check on the commit, but only
# once the grace has run out.
fake_checks 7 required none
fake_checks 7 all green
out="$(ORCH_CI_GRACE=0.2 "$ORCH" review ci 2>&1)"; st=$?
assert_status "a repo that requires nothing falls back to every check" "$st" 0
assert_first_line "reading the commit's own checks for its answer" "$out" "green"

fake_checks 7 all boom
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "an API that will not answer stops the loop" "$st" 1
assert_first_line "classified as unreachable" "$out" "unreachable"
assert_contains "carrying the reason it could not be asked" "$out" "dial tcp"

# doctor's "an unreachable API is a warn" rule was written for a read-only
# diagnostic. Here the outcome is an action, so an answer that never arrived
# cannot be treated as a green one.
fake_checks 7 all pending
out="$(ORCH_CI_TIMEOUT=0.2 "$ORCH" review ci 2>&1)"; st=$?
assert_status "checks still pending at the cap stop the loop" "$st" 1
assert_first_line "rather than being read as green" "$out" "unreachable"
assert_contains "and it says the wait ran out" "$out" "still pending"

# The clocks are compared with awk, which compares a number against a
# non-numeric string as strings - so a mistyped knob makes every comparison
# true, and the one command written to be bounded polls GitHub until something
# else kills it. The leash is what makes this assertable: without the fix the
# command never returns on its own.
out="$(ORCH_CI_GRACE=oops timeout 5 "$ORCH" review ci 2>&1)"; st=$?
assert_status "a grace that is not a number stops the command, not the clock" "$st" 1
assert_contains "naming the knob it could not read" "$out" "ORCH_CI_GRACE"

# A zero interval passes for a number and still defeats the bound: `sleep 0`
# returns at once and never advances the clock, so the loop polls as fast as
# GitHub answers for the whole timeout.
out="$(ORCH_CI_INTERVAL=0 timeout 5 "$ORCH" review ci 2>&1)"; st=$?
assert_status "an interval of zero is refused rather than busy-polled" "$st" 1
assert_contains "saying the interval has to be above zero" "$out" "greater than zero"

# The one direction this classifier must never fail in: an answer nobody could
# read is not an answer that there is nothing to read. adapter_pr_checks fails
# on one (its contract test), and that failure's reason is what review ci says.
fake_fail adapter_pr_checks "gh pr checks answered with something jq could not read"
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "checks nobody could read stop the loop" "$st" 1
assert_first_line "rather than passing as a repo with no checks" "$out" "unreachable"
assert_contains "saying what it could not read" "$out" "could not read"
rm -rf "$ORCH_GH_FAKE_STORE/fail"
restore_suite_env ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL

# --- the grace counts from the push (issue #475) ---
# review ci runs when the loop ends, usually minutes after the fixer's last
# push, so a grace counted from the call is a minute paid for nothing. It
# counts from the push instead: the newest reflog entry of the head branch's
# remote-tracking ref that set it to the PR's head SHA. The anchor is real git
# - a push to a local bare remote, its entry rewritten under a past committer
# date - while the PR's head and branch come from the fake adapter.
review_ci_flow gracepush
head_sha="$(pushed_head topic 3600)"
fake_pr_head 7 "$head_sha"

# With the push an hour old, the grace is long spent: the first answer of
# nothing required widens at once, and nothing at all reported is `none`. A
# grace counted from the call would wait for the green the second answer holds.
fake_checks 7 required none green
fake_checks 7 all none
out="$(ORCH_CI_GRACE=5 "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "an old push with nothing reported is none without waiting the grace" "$out" "none"
assert_status "and none still lets the loop finish" "$st" 0

# The grace is measured from that one push alone: an entry for another SHA
# says nothing about when this head arrived, so the grace counts from the call.
fake_checks 7 required none green
fake_pr_head 7 1111111111111111111111111111111111111111
out="$(ORCH_CI_GRACE=5 "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "with no reflog entry for the head SHA, the grace counts from the call" "$out" "green"
fake_pr_head 7 "$head_sha"

# A PR whose head branch has no remote-tracking ref at all is the same case.
fake_checks 7 required none green
fake_pr 7 open elsewhere main
fake_pr_head 7 "$head_sha"
out="$(ORCH_CI_GRACE=5 "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "nor with no remote-tracking ref for the head branch" "$out" "green"
fake_pr 7 open topic main
fake_pr_head 7 "$head_sha"

# The timeout keeps counting from the call: an hour-old push is no reason to
# give up on checks that are still running now.
fake_checks 7 required pending green
out="$(ORCH_CI_TIMEOUT=5 "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "the timeout counts from the call even when the push is old" "$out" "green"

# A fresh push still waits: nothing required yet, and the green that arrives
# within the grace wins over the unfiltered failure.
head_sha="$(pushed_head topic)"
fake_pr_head 7 "$head_sha"
fake_checks 7 required none green
fake_checks 7 all failing
out="$(ORCH_CI_GRACE=5 "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "a fresh push still waits the grace before widening" "$out" "green"
restore_suite_env ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL

# --- the grace is skipped on no evidence of CI (issue #476) ---
# Zero checks straight after a push is ambiguous only where the repo might have
# CI. With no workflow in the head, nothing required on the base, and no check
# or status on an earlier PR commit or the base tip, there is nothing to wait
# for, and `none` arrives without the grace. Each case below uses a fresh push,
# so the grace is unspent: `none`, then `green`, on the required probe tells the
# two apart, green meaning the grace was waited and none that it was skipped.
# ci_absent: every CI signal absent, and the checks scripted that way - the
# store each case below turns one signal back on in.
ci_absent() {
  fake_ci_reset
  fake_checks 7 required none green
  fake_checks 7 all none
}
# no_ci <expected first line> <name>: one review ci call, on PR #7 as the store
# holds it - by default, a single-commit PR whose head is head_sha.
no_ci() {
  out="$(ORCH_CI_GRACE=5 "$ORCH" review ci 2>&1)"; st=$?
  assert_first_line "$2" "$out" "$1"
}
review_ci_flow nocievidence
head_sha="$(pushed_head topic)"
fake_pr_head 7 "$head_sha"
ci_absent
no_ci none "with no evidence of CI anywhere, none arrives without the grace"
assert_status "and lets the loop finish" "$st" 0
assert_contains "saying it found no CI signals" "$out" "no CI signals found"
assert_contains "naming the signals it looked for" "$out" "no workflow files in the head"

# The other path to none: the grace waited and ran out with nothing reported.
fake_ci_reset
fake_check_run main
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_first_line "evidence of CI keeps the grace, and none still comes after it" "$out" "none"
assert_contains "saying the grace ran out" "$out" "grace ran out"
assert_eq "and not that no signals were found" "$(printf '%s\n' "$out" | grep -c 'no CI signals')" "0"

# The pre-check replaces only the wait: the unfiltered probe still runs, so a
# check already reported on the head gives its verdict, not none.
ci_absent; fake_checks 7 all failing
no_ci failing "with no evidence of CI, a check reported on the head still decides it"
ci_absent; fake_checks 7 all green
no_ci green "and a green one reads green"

# Each signal alone keeps the grace.
wf_index="$(mktemp -u)"
GIT_INDEX_FILE="$wf_index" git read-tree HEAD
GIT_INDEX_FILE="$wf_index" git update-index --add --cacheinfo \
  "100644,$(printf 'on: push\n' | git hash-object -w --stdin),.github/workflows/ci.yml"
wf_sha="$(git commit-tree "$(GIT_INDEX_FILE="$wf_index" git write-tree)" -p HEAD -m 'add CI')"
fake_pr_head 7 "$wf_sha"
ci_absent
no_ci green "a workflow file in the head's tree keeps the grace"
# git ls-tree reads its pathspec from the current directory: from a
# subdirectory, the workflow must still be seen, not read as absent.
mkdir -p wf-subdir
ci_absent
out="$(cd wf-subdir && ORCH_CI_GRACE=5 "$ORCH" review ci 2>&1)"
assert_first_line "and so does one seen from a subdirectory" "$out" "green"
rmdir wf-subdir
fake_pr_head 7 "$head_sha"
ci_absent; fake_required_checks main build
no_ci green "required checks from classic branch protection keep the grace"
ci_absent; fake_rules main required_status_checks
no_ci green "required checks from a ruleset keep the grace"
ci_absent; fake_rules main deletion
no_ci none "a ruleset that requires no checks is not evidence of CI"
earlier=2222222222222222222222222222222222222222
fake_pr_head 7 "$head_sha" "$earlier" "$head_sha"
ci_absent; fake_check_run "$earlier"
no_ci green "a check-run on an earlier PR commit keeps the grace"
ci_absent; fake_status "$earlier"
no_ci green "a commit status on an earlier PR commit keeps the grace"
fake_pr_head 7 "$head_sha"
ci_absent; fake_check_run main
no_ci green "a check-run on the base tip keeps the grace"
ci_absent; fake_status main
no_ci green "a commit status on the base tip keeps the grace"

# A single-commit PR has no earlier commit: the head's own checks are what the
# probes read, not evidence the grace is worth waiting for.
ci_absent; fake_check_run "$head_sha"; fake_status "$head_sha"
no_ci none "a single-commit PR has no earlier-commit signal"

# A signal that cannot be read counts as CI - a protection read GitHub refused
# with anything but its 404 for an unprotected branch included, which
# adapter_branch_required_checks fails on (its contract test).
ci_absent; fake_fail adapter_branch_required_checks "gh: Not Found (HTTP 404)"
no_ci green "a protection read that fails keeps the grace"
rm -rf "$ORCH_GH_FAKE_STORE/fail"
ci_absent; fake_fail adapter_branch_rules
no_ci green "a ruleset read that fails keeps the grace"
rm -rf "$ORCH_GH_FAKE_STORE/fail"
ci_absent; fake_unreadable_ref main
no_ci green "a base-tip read that fails keeps the grace"
fake_pr_head 7 "$head_sha" "$earlier" "$head_sha"
ci_absent; fake_unreadable_ref "$earlier"
no_ci green "an earlier commit's read that fails keeps the grace"
fake_pr_head 7 3333333333333333333333333333333333333333
ci_absent
no_ci green "a head this clone does not hold keeps the grace"
fake_pr_head 7 "$head_sha"
ci_absent; fake_fail adapter_pr_refs
no_ci green "a PR that will not say what its head is keeps the grace"
rm -rf "$ORCH_GH_FAKE_STORE/fail"

state_fixture pr null
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "refuses to classify checks on a PR that does not exist yet" "$st" 1
# require_pr dies inside a command substitution, so what stops the command is
# `set -e` on the assignment rather than the exit itself. Asserting the message
# is what would catch the guard degrading into an empty PR number.
assert_contains "saying which phase was supposed to open it" "$out" "the implement phase opens it"
restore_suite_env ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL

# --- review rerun -------------------------------------------------------------
# The flow's one flake rerun (#525): the failed jobs of the Actions run behind
# the PR's first failed or cancelled check, taken from that check's link. Exit 0
# is the only answer that spends the rerun; 1 is "no Actions run to rerun" and
# 2 everything else. Stateless: the PR is named on the command line.
echo
echo "review rerun"
new_repo >/dev/null
fake_github
fake_checks 7 all failing
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a failed Actions check is rerun" "$st" 0
assert_eq "printing the run it reran" "$out" "4242"
assert_eq "the run id taken from the failing check's link" "$(fake_reruns)" "4242"

rm -f "$ORCH_GH_FAKE_STORE/reruns"
fake_checks 7 all cancel
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a cancelled Actions check is rerun too" "$st" 0
assert_eq "from the cancelled check's run" "$(fake_reruns)" "5150"

rm -f "$ORCH_GH_FAKE_STORE/reruns"
fake_checks 7 all external
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a first failing check that is no Actions run has nothing to rerun" "$st" 1
assert_eq "warning that the check is no Actions run" "$out" \
  "orch: check ext-ci on PR #7 is not a GitHub Actions run - nothing to rerun"
assert_eq "and reruns nothing, not even a later Actions run" "$(fake_reruns)" ""

fake_checks 7 all badrunid
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a failing check linking no Actions run id has nothing to rerun" "$st" 1
assert_eq "warning that the check links no run id" "$out" \
  "orch: check build on PR #7 links no Actions run id - nothing to rerun"
assert_eq "and reruns nothing" "$(fake_reruns)" ""

fake_checks 7 all boom
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a GitHub that cannot be read is exit 2" "$st" 2
assert_contains "carrying gh's reason" "$out" "dial tcp"
fake_checks 7 all green
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "no failed or cancelled check is exit 2" "$st" 2
assert_contains "saying there is nothing failed to rerun" "$out" "no failed or cancelled check"
fake_checks 7 all none
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "no checks at all is exit 2" "$st" 2
assert_contains "saying gh reported no checks" "$out" "gh could not read the checks of PR #7: no checks reported"
fake_checks 7 all failing
fake_fail adapter_run_rerun
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a rerun gh refuses is exit 2" "$st" 2
assert_contains "naming the run" "$out" "4242"
rm -rf "$ORCH_GH_FAKE_STORE/fail"
out="$("$ORCH" review rerun 2>&1)"; st=$?
assert_status "no PR is a usage error, exit 2" "$st" 2
out="$("$ORCH" review rerun abc 2>&1)"; st=$?
assert_status "a PR that is not a number is a usage error, exit 2" "$st" 2
git remote remove origin
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "no repo to work on is exit 2, not the guard's 1" "$st" 2
assert_eq "dying with the repo remedy" "$out" \
  "orch: no GitHub repo to work on: origin is missing or not a GitHub owner/name - set GH_REPO=<owner>/<repo>"
assert_contains "help documents review rerun" "$("$ORCH" help)" "review rerun <pr>"
restore_suite_env

# --- a flow from before the budget shipped ----------------------------------
# An in-flight flow carries whatever state the version that started it wrote:
# no `budget`, no `loop`, no `flake_rerun_used`. Failing on any absence would
# strand exactly the flows this change was meant to finish.
echo
echo "a flow started before the budget shipped"
fresh_flow legacy
legacy="$(mktemp)"
jq 'del(.budget, .loop, .flake_rerun_used)' .orchestrator/state.json >"$legacy"
mv "$legacy" .orchestrator/state.json
assert_eq "the state it left behind names no budget" "$("$ORCH" state get budget)" ""
assert_eq "review begin still claims an iteration" "$("$ORCH" review begin)" "1"
assert_contains "records land flat under review/" "$("$ORCH" review path)" "/review/iteration-01.md"
assert_contains "and review reads the implement handoff as it always did" \
  "$("$ORCH" handoff path review)" "03-implement.md"
for i in 2 3 4 5; do "$ORCH" review begin >/dev/null; done
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and it runs the default budget" "$st" 1
assert_contains "of five" "$out" "budget of 5 iterations"

state_fixture phase review
complete_plan_handoff "$("$ORCH" handoff path spec)"
complete_spec_handoff "$("$ORCH" handoff path implement)"
complete_implement_handoff "$("$ORCH" handoff path review)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor does not strand it either" "$st" 0
assert_contains "status reads its budget as the default" "$("$ORCH" status)" "iteration 5 of 5"

# ci and ready need a PR, which a flow this old still records the same way.
state_fixture pr 3
fake_github
fake_pr 3 open orch/legacy main
fake_pr_draft 3
fake_checks 3 all green
out="$(ORCH_CI_GRACE=0.2 ORCH_CI_INTERVAL=0.05 "$ORCH" review ci 2>&1)"; st=$?
assert_status "review ci reads its PR from a state with no budget key" "$st" 0
assert_first_line "and classifies it" "$out" "green"
assert_eq "review ready marks the PR and finishes the flow" \
  "$("$ORCH" review ready)" "3"
assert_eq "recording done as it goes" "$("$ORCH" state get phase)" "done"
assert_eq "with the PR no longer a draft" "$(fake_pr_draft_of 3)" "no"
restore_suite_env

# --- init seeds the review loop ---------------------------------------------
echo
echo "init seeds the review loop"
fresh_flow seeded
assert_eq "a flow starts with no loop counter" \
  "$("$ORCH" state get | jq -r 'has("loop")')" "false"
assert_eq "and no budget until a human names one" "$("$ORCH" state get budget)" ""
assert_eq "with somewhere to file its records" \
  "$([ -d .orchestrator/review ] && echo present || echo gone)" "present"
assert_eq "and no per-loop directory under it" \
  "$([ -e .orchestrator/review/loop-01 ] && echo present || echo gone)" "gone"
# The flake rerun belongs to the flow, so it is seeded once here and never
# refilled. `state get` reads it back as "false" - the review skill tests only
# for "true", so spent is "true" and anything else is unspent.
assert_eq "and one flake rerun unspent" \
  "$("$ORCH" state get | jq -r '.flake_rerun_used')" "false"
assert_eq "which reads as unspent through state get" \
  "$("$ORCH" state get flake_rerun_used)" "false"
"$ORCH" state set flake_rerun_used true
assert_eq "and as spent once it has been" \
  "$("$ORCH" state get flake_rerun_used)" "true"

# redo_count is what answers "how many times has this flow been redone" once
# a redo has happened - iteration alone no longer can.
assert_eq "a fresh flow has never been redone" "$("$ORCH" state get redo_count)" "0"
assert_eq "recorded as a number, not a string" \
  "$("$ORCH" state get | jq -r '.redo_count | type')" "number"

assert_contains "status names the iteration against the default budget" \
  "$("$ORCH" status)" "iteration 0 of 5"
"$ORCH" state set budget 3
state_fixture iteration 2
assert_contains "and against the budget once one is set" \
  "$("$ORCH" status)" "iteration 2 of 3"
assert_contains "status shows how many times the flow has been redone" \
  "$("$ORCH" status)" "redo:      0"
state_fixture redo_count 2
assert_contains "and updates once it has been" "$("$ORCH" status)" "redo:      2"
assert_contains "help documents the review verb" "$("$ORCH" help)" "review begin"
assert_contains "and the CI classifier's outcomes" "$("$ORCH" help)" "review ci"
assert_contains "and filing" "$("$ORCH" help)" "review file"
assert_contains "with the finding's axis" "$("$ORCH" help)" "review file <major|nit> <title> --axis <spec|standards> --body-file <file>"
assert_contains "and finding triage's scan" "$("$ORCH" help)" "finding-triage scan [<issue> | --pr <n>]"
assert_contains "and its apply, in both forms" "$("$ORCH" help)" "finding-triage apply <issue> <close-fixed|wontfix> --comment-file <file>"
assert_contains "the open one with its category" "$("$ORCH" help)" "--category <bug|enhancement> --comment-file <file>"
assert_contains "and the terminal-state classifier" "$("$ORCH" help)" "review terminal"
assert_contains "and retiring a loop's records" "$("$ORCH" help)" "review retire"
assert_contains "help documents issue publish" "$("$ORCH" help)" "issue publish"
assert_contains "and pr publish" "$("$ORCH" help)" "pr publish"
assert_contains "and pr release" "$("$ORCH" help)" "pr release [--force] <title> <body-file>"
assert_contains "and ticket publish" "$("$ORCH" help)" "ticket publish"
assert_contains "and ticket next" "$("$ORCH" help)" "ticket next"
assert_contains "and ticket close" "$("$ORCH" help)" "ticket close"
assert_contains "and ticket reset" "$("$ORCH" help)" "ticket reset"
assert_contains "and retiring a branch" "$("$ORCH" help)" "branch retire"
assert_contains "and creating one" "$("$ORCH" help)" "branch create"
assert_contains "and forking one for a quick implementation" "$("$ORCH" help)" "branch off"
assert_contains "and opening a draft PR" "$("$ORCH" help)" "pr open"
assert_contains "and redo review" "$("$ORCH" help)" "redo review"
assert_contains "and redo spec" "$("$ORCH" help)" "redo spec"
assert_eq "and no longer the loop machinery" "$("$ORCH" help | grep -c 'loop-next')" "0"
restore_suite_env

# --- state get reads every key with its default -----------------------------
# A state file written by an older flow lacks keys a fresh one seeds; each key
# still reads back as what an absent value has always meant.
echo
echo "state get defaults"
fresh_flow sparse
jq 'del(.iteration, .redo_count, .host_fallbacks, .flake_rerun_used, .budget)' \
  .orchestrator/state.json >state.tmp && mv state.tmp .orchestrator/state.json
assert_eq "an absent iteration reads as 0" "$("$ORCH" state get iteration)" "0"
assert_eq "an absent redo_count reads as 0" "$("$ORCH" state get redo_count)" "0"
assert_eq "an absent host_fallbacks reads as false" "$("$ORCH" state get host_fallbacks)" "false"
assert_eq "an absent flake_rerun_used reads as false" "$("$ORCH" state get flake_rerun_used)" "false"
assert_eq "an absent budget reads as empty" "$("$ORCH" state get budget)" ""
out="$("$ORCH" state get nonsense 2>&1)"; st=$?
assert_status "a key outside the schema is refused" "$st" 1
assert_contains "naming the key" "$out" "nonsense"
complete_plan_handoff "$("$ORCH" handoff path spec)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor --flow passes a state file lacking those keys" "$st" 0
# The string keys read back empty when missing too. phase goes only now: the
# doctor --flow check above would fail a state file lacking it.
jq 'del(.slug, .phase, .issue, .base, .branch, .pr, .base_sha, .created, .updated)' \
  .orchestrator/state.json >state.tmp && mv state.tmp .orchestrator/state.json
for key in slug phase issue base branch pr base_sha created updated; do
  out="$("$ORCH" state get "$key" 2>&1)"; st=$?
  assert_status "an absent $key still reads" "$st" 0
  assert_eq "an absent $key reads as empty" "$out" ""
done
restore_suite_env

# --- state.json schema ------------------------------------------------------
# What a fresh init writes, pinned: every key it seeds reads back through
# state get, and the raw file holds exactly these keys, in this order, with
# these seeds. A change to the state-key schema that alters state.json or loses
# a key's default fails here.
echo
echo "state.json schema"
fresh_flow schema
for key in $(jq -r 'keys_unsorted[]' .orchestrator/state.json); do
  "$ORCH" state get "$key" >/dev/null 2>&1; st=$?
  assert_status "state get reads $key, which init writes" "$st" 0
done
assert_eq "slug, base, created and updated are non-empty strings" \
  "$(jq -c '[.slug, .base, .created, .updated] | map(type == "string" and . != "")' .orchestrator/state.json)" \
  "[true,true,true,true]"
assert_eq "state.json holds the pinned keys, order and seeds" \
  "$(jq -c '.slug = "S" | .base = "B" | .created = "C" | .updated = "U"' .orchestrator/state.json)" \
  '{"slug":"S","phase":"spec","issue":null,"base":"B","branch":null,"pr":null,"base_sha":null,"budget":null,"iteration":0,"flake_rerun_used":false,"redo_count":0,"host_fallbacks":true,"created":"C","updated":"U"}'
restore_suite_env

# --- review terminal ----------------------------------------------------
# The one classifier `review terminal` and doctor's check both read - none and
# pending need no iteration file at all, interrupted/ready/stop all do.
echo
echo "review terminal"
fresh_flow terminaltest

out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "no loop yet is not terminal" "$st" 1
assert_first_line "and classifies as none" "$out" "none"

state_fixture iteration 3
"$ORCH" state set budget 5
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "short of its budget is not terminal" "$st" 1
assert_first_line "and classifies as pending" "$out" "pending"

state_fixture iteration 5
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "at budget with no iteration record is not terminal" "$st" 1
assert_first_line "classified as interrupted, not pending" "$out" "interrupted"

mkdir -p .orchestrator/review
: >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a record with no Terminal state heading is still interrupted" "$st" 1
assert_first_line "not silently read as done" "$out" "interrupted"

writeln '## Terminal state' '' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "an empty Terminal state section is interrupted too" "$st" 1
assert_first_line "same as a missing one" "$out" "interrupted"

writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a ready heading is terminal" "$st" 0
assert_first_line "and classifies as ready" "$out" "ready"

# The driver writes `## CI` at termination, before the closer's `## Filed` and
# its own `## Terminal state`. Only the last is read: a CI answer never
# classifies a loop on its own.
writeln '## CI' 'failing' 'build: failed' '' '## Filed' 'None' '' \
  '## Terminal state' 'ready' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a CI section before Terminal state leaves it terminal" "$st" 0
assert_first_line "classified from Terminal state, not CI" "$out" "ready"

writeln '## CI' 'green' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a CI section with no Terminal state is not terminal" "$st" 1
assert_first_line "still classified as interrupted" "$out" "interrupted"

writeln '## Terminal state' 'stop' 'CI failed twice, flake rerun spent.' \
  >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a stop heading is terminal too" "$st" 0
assert_first_line "classified as stop" "$out" "stop"
assert_contains "carrying the recorded reason on the lines after it" \
  "$out" "CI failed twice, flake rerun spent."

# Per-reviewer report files sit beside the records under a suffixed name, and
# records are addressed only by their exact iteration-NN.md name - so a report
# never changes a classification, even one that reads like a record.
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05-standards.md
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05-spec.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "report files beside a stop record leave it terminal" "$st" 0
assert_first_line "still classified as stop, not read from a report" "$out" "stop"
assert_contains "review path still names the record, not a report" \
  "$("$ORCH" review path 5)" "/review/iteration-05.md"
rm .orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "report files with no record are not terminal" "$st" 1
assert_first_line "classified as interrupted" "$out" "interrupted"
assert_contains "and review path still names the missing record" \
  "$("$ORCH" review path)" "/review/iteration-05.md"
rm .orchestrator/review/iteration-05-standards.md .orchestrator/review/iteration-05-spec.md

# A record written as ordinary markdown reads the way it was meant (#604):
# blank lines under the heading, whitespace around the first line, and a stop
# with its reason on the same line all classify, never as interrupted.
writeln '## Terminal state' '' 'stop' 'CI never ran on the reviewed head.' \
  >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a blank line under the heading still reads stop" "$st" 0
assert_first_line "classified as stop, not interrupted" "$out" "stop"
assert_eq "with the reason intact below it" \
  "$(printf '%s\n' "$out" | tail -n +2)" "CI never ran on the reviewed head."

writeln '## Terminal state' '   ' '' 'ready' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "whitespace-only lines under the heading still read ready" "$st" 0
assert_first_line "classified as ready" "$out" "ready"

writeln '## Terminal state' '  ready  ' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "whitespace around ready is tolerated" "$st" 0
assert_eq "and prints the bare word" "$out" "ready"

writeln '## Terminal state' '  stop  ' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "whitespace around stop is tolerated" "$st" 0
assert_eq "and prints stop and its reason" "$out" "$(printf 'stop\nCI failed twice.')"

for line in 'stop - CI failed twice.' 'stop – CI failed twice.' 'stop — CI failed twice.' \
  'stop: CI failed twice.' 'stop:CI failed twice.' 'stop-CI failed twice.' \
  '  stop - CI failed twice.  '; do
  writeln '## Terminal state' "$line" 'The flake rerun is spent.' \
    >.orchestrator/review/iteration-05.md
  out="$("$ORCH" review terminal 2>&1)"; st=$?
  assert_status "'$line' on one line is stop" "$st" 0
  assert_eq "'$line' prints its reason first, then the lines below" "$out" \
    "$(printf 'stop\nCI failed twice.\nThe flake rerun is spent.')"
done

writeln '## Terminal state' 'stop -' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a separator with nothing after it is still stop" "$st" 0
assert_eq "with an empty reason" "$out" "stop"

writeln '## Terminal state' 'stop -' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a bare separator with a reason below is stop" "$st" 0
assert_eq "reading the reason from below" "$out" "$(printf 'stop\nCI failed twice.')"

writeln '## Terminal state' '   ' '	' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a whitespace-only section is not terminal" "$st" 1
assert_first_line "and still classifies as interrupted" "$out" "interrupted"

for line in 'Stop' '**stop**' 'ready - all green' 'done' 'stopped' 'stop CI failed'; do
  writeln '## Terminal state' '' "$line" 'CI failed twice.' >.orchestrator/review/iteration-05.md
  out="$("$ORCH" review terminal 2>&1)"; st=$?
  assert_status "'$line' is not terminal" "$st" 1
  assert_first_line "'$line' classifies as malformed, not interrupted" "$out" "malformed"
  assert_contains "'$line' prints the expected shape" "$out" "expected: first line"
done

out="$("$ORCH" review terminal extra 2>&1)"; st=$?
assert_status "takes no arguments" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh review terminal"
restore_suite_env

# --- doctor: review terminal check --------------------------------------
# check_flow_pr's open/closed/unreadable branching is the direct template:
# ok/warn on the classification, and phase-gated silent outside review.
echo
echo "doctor: review terminal check"
fresh_flow doctorterm
doctor_github
complete_plan_handoff "$("$ORCH" handoff path spec)"
complete_spec_handoff "$("$ORCH" handoff path implement)"
state_fixture phase implement
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "implement phase still passes" "$st" 0
assert_eq "and says nothing about a review loop" \
  "$(printf '%s\n' "$out" | grep -c 'review loop')" "0"

complete_implement_handoff "$("$ORCH" handoff path review)"
state_fixture phase review
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "no loop yet is healthy" "$st" 0
assert_contains "reports the loop has not started" "$out" "review loop: not started yet"

state_fixture iteration 2
"$ORCH" state set budget 5
out="$(ORCHESTRATOR_HOST=junie "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "short of budget warns, never fails" "$st" 0
assert_contains "names the iteration and budget" "$out" "iteration 2 of budget 5"
assert_contains "reads as pending, not interrupted" "$out" "hasn't reached its budget yet"
assert_contains "points at next for resuming it" "$out" "/orchestrator:next (or orch-flow's Next phase section) will resume it"
assert_contains "and says redo refuses until it is terminal" "$out" "redo refuses until it reaches a terminal state"

state_fixture iteration 5
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "at budget with no terminal record warns rather than fails" "$st" 0
assert_contains "reads as interrupted, not pending" "$out" "looks interrupted, not stopped"

mkdir -p .orchestrator/review
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a ready record is healthy" "$st" 0
assert_contains "names it a terminal state" "$out" "review loop at a terminal state: ready"

writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a stop record is healthy too" "$st" 0
assert_contains "names the terminal state and its reason" \
  "$out" "review loop at a terminal state: stop (CI failed twice.)"

writeln '## Terminal state' '**stop**' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a malformed record fails, since next will not fix it" "$st" 1
assert_contains "with a FAIL line naming it malformed" "$out" "FAIL  review loop's last iteration (5) has a malformed terminal state"
assert_contains "printing the expected shape" "$out" "expected: first line"
assert_contains "and the rewrite remedy" "$out" "rewrite the first line of"
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md

# Report files change nothing doctor says about the loop either.
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05-standards.md
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05-spec.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "report files beside a stop record stay healthy" "$st" 0
assert_contains "still reading the stop from the record" \
  "$out" "review loop at a terminal state: stop (CI failed twice.)"
mv .orchestrator/review/iteration-05.md .orchestrator/review/stop.saved
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "report files with no record warn rather than fail" "$st" 0
assert_contains "and read as interrupted" "$out" "looks interrupted, not stopped"
mv .orchestrator/review/stop.saved .orchestrator/review/iteration-05.md
rm .orchestrator/review/iteration-05-standards.md .orchestrator/review/iteration-05-spec.md
restore_suite_env

# --- doctor: review budget check -----------------------------------------
# review begin's own `die` at budget is what is meant to make an iteration
# past it unreachable - this check is for the state.json that got there some
# other way, not one review begin produced itself.
echo
echo "doctor: review budget check"
review_flow doctorbudget
doctor_github
"$ORCH" state set budget 5
state_fixture iteration 3
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "short of budget is healthy" "$st" 0
assert_contains "reports it within budget" "$out" "review loop iteration (3) within budget (5)"

state_fixture iteration 6
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "past budget fails" "$st" 1
assert_contains "names the impossible count" "$out" \
  "review loop iteration (6) is past its budget (5)"
assert_contains "and points at abort" "$out" "/orchestrator:abort"
state_fixture iteration 5
restore_suite_env

# --- doctor: review ci check ----------------------------------------------
# ci_probe is the loop's own read of the PR's checks, reused rather than a
# second query of the same endpoint - so its five answers are the five cases
# here, not a fresh classification doctor derives on its own.
echo
echo "doctor: review ci check"
review_flow doctorci
doctor_github
state_fixture pr 40
# A draft PR mid-review agrees with the phase, so the draft check stays quiet
# and only the CI check's own verdict decides the exit status below.
fake_pr 40 open orch/doctorci main
fake_pr_draft 40

fake_checks 40 required green
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "green required checks are healthy" "$st" 0
assert_contains "reports it" "$out" "CI: required checks green"

fake_checks 40 required none
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "no required checks reported is not a failure" "$st" 0
assert_contains "reports it" "$out" "CI: no required checks reported"
# review ci's none detail (issue #476) is added in review ci, not ci_probe,
# so doctor's own none line is unchanged and carries neither path's detail.
assert_eq "without review ci's none detail" \
  "$(printf '%s\n' "$out" | grep -c 'no CI signals\|grace ran out')" "0"

fake_checks 40 required pending
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "pending required checks are not a failure yet" "$st" 0
assert_contains "reports it" "$out" "CI: required checks still pending"

fake_checks 40 required failing
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a failing required check fails doctor" "$st" 1
assert_contains "names the PR" "$out" "CI: required check(s) failing on PR #40"
assert_contains "carries the failing check's name" "$out" "build"
assert_contains "gives the command that shows it" "$out" "gh pr checks 40"

fake_checks 40 required boom
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an unreachable API warns rather than fails" "$st" 0
assert_contains "reports it" "$out" "CI: could not be read from GitHub for PR #40"
assert_contains "carrying the reason" "$out" "dial tcp"
restore_suite_env

# --- doctor: review draft check -------------------------------------------
# `review ready` marks the PR ready and records phase: done as one operation,
# so isDraft and phase disagreeing on GitHub's own PR is evidence that
# operation only half landed.
echo
echo "doctor: review draft check"
review_flow doctordraft
doctor_github
state_fixture pr 40
fake_pr 40 open orch/doctordraft main
fake_pr_draft 40
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a draft PR mid-review is healthy" "$st" 0
assert_contains "reports it matches phase" "$out" \
  "PR #40 draft state matches phase (review)"

fake_pr 40 open orch/doctordraft main
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a PR marked ready while still in review fails" "$st" 1
assert_contains "names the mismatch" "$out" \
  "PR #40 was marked ready on GitHub but the flow phase is still review"
assert_contains "gives the command that inspects it" "$out" "gh pr view 40"

state_fixture phase "done"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a ready PR once the flow is done is healthy" "$st" 0
assert_contains "reports it matches phase" "$out" \
  "PR #40 draft state matches phase (done)"

fake_pr_draft 40
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a draft PR left behind once the flow is done fails" "$st" 1
assert_contains "names the mismatch" "$out" \
  "PR #40 is still a draft but the flow phase is done"
assert_contains "gives the command that promotes it" "$out" "gh pr ready 40"

fake_pr 40 merged orch/doctordraft main
fake_pr_draft 40
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a merged PR has nothing left to disagree with" "$st" 0
assert_eq "and says nothing about draft state" \
  "$(printf '%s\n' "$out" | grep -c 'draft state')" "0"
state_fixture phase review
restore_suite_env

# --- review retire -------------------------------------------------------
# The archive test's directory-move assertions are the direct template.
echo
echo "review retire"
new_repo >/dev/null
"$ORCH" init retiretest >/dev/null

out="$("$ORCH" review retire 1)"
assert_contains "a no-op with nothing to move still prints the destination" \
  "$out" "/review/pre-redo-1"
assert_eq "and creates no directory for it" \
  "$([ -d .orchestrator/review/pre-redo-1 ] && echo present || echo gone)" "gone"

mkdir -p .orchestrator/review
: >.orchestrator/review/iteration-01.md
: >.orchestrator/review/iteration-02.md
out="$("$ORCH" review retire 1)"
assert_contains "moves every iteration record into pre-redo-N" \
  "$out" "/review/pre-redo-1"
assert_eq "iteration-01 landed under it" \
  "$([ -f .orchestrator/review/pre-redo-1/iteration-01.md ] && echo yes || echo no)" "yes"
assert_eq "iteration-02 landed under it too" \
  "$([ -f .orchestrator/review/pre-redo-1/iteration-02.md ] && echo yes || echo no)" "yes"
assert_eq "and the flat trail is empty afterwards" \
  "$([ -e .orchestrator/review/iteration-01.md ] && echo yes || echo no)" "no"

# The per-reviewer report files ride along with their records.
: >.orchestrator/review/iteration-03.md
: >.orchestrator/review/iteration-03-standards.md
: >.orchestrator/review/iteration-03-spec.md
"$ORCH" review retire 2 >/dev/null
for f in iteration-03.md iteration-03-standards.md iteration-03-spec.md; do
  assert_eq "$f landed in pre-redo-2" \
    "$([ -f ".orchestrator/review/pre-redo-2/$f" ] && echo yes || echo no)" "yes"
  assert_eq "$f left the flat trail" \
    "$([ -e ".orchestrator/review/$f" ] && echo yes || echo no)" "no"
done

: >.orchestrator/review/iteration-01.md
out="$("$ORCH" review retire 1 2>&1)"; st=$?
assert_status "dies rather than collide with an existing pre-redo-N" "$st" 1
assert_contains "naming the directory" "$out" "pre-redo-1"

out="$("$ORCH" review retire nope 2>&1)"; st=$?
assert_status "refuses a non-numeric redo count" "$st" 1

out="$("$ORCH" review retire 2>&1)"; st=$?
assert_status "refuses with no argument" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh review retire"

# --- redo review ----------------------------------------------------------
# The full review -> implement transition: three distinct refusals below a
# terminal state, and a full composition above it.
#
# cmd_redo_review's PR close goes through the store-backed fake (fake_github)
# - a check of the fixture gh's log right after the first successful redo proves it never
# spawns a real gh subprocess. The real operation is pinned in "gh adapter
# contract".
echo
echo "redo review"
healthy_repo
fake_github
fake_issue 21 open
for n in 30 31 32 33; do fake_pr "$n" open orch/21-redotest main; done
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init redotest >/dev/null

out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "refuses outside the review phase" "$st" 1
assert_contains "naming the reason" "$out" "flow is not at the review phase"

state_fixture phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redotest
git push -q -u origin orch/21-redotest
state_fixture branch orch/21-redotest
state_fixture pr 30
store_before="$(fake_snapshot)"
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "refuses with no loop run yet" "$st" 1
assert_contains "distinct from the other two refusals" "$out" "no review loop has run yet"
assert_eq "and nothing reaches GitHub" "$(fake_snapshot)" "$store_before"

state_fixture iteration 2
"$ORCH" state set budget 5
out="$(ORCHESTRATOR_HOST=junie "$ORCH" redo review 2>&1)"; st=$?
assert_status "refuses a loop still short of its budget" "$st" 1
assert_contains "pointing at /orchestrator:next instead" "$out" "that's what /orchestrator:next (or orch-flow's Next phase section) is for"
# Claude Code users see the command alone, as before 1.0.0 (#121 story 2).
out="$(ORCHESTRATOR_HOST=claude "$ORCH" redo review 2>&1)"
assert_contains "names the bare command on Claude Code" "$out" "that's what /orchestrator:next is for"
out="$(env -u CLAUDE_PLUGIN_ROOT "$ORCH" redo review 2>&1)"
assert_contains "and the orch-flow section when no host is detected" "$out" "/orchestrator:next (or orch-flow's Next phase section)"

state_fixture iteration 5
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "refuses a budget-spent loop with no terminal record" "$st" 1
assert_contains "reading as interrupted, distinct from pending" "$out" "looks interrupted, not stopped"

# A malformed record is refused before anything moves, with the rewrite to do.
mkdir -p .orchestrator/review
writeln '## Terminal state' 'Stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" redo review 2>&1 >/dev/null)"; st=$?
assert_status "refuses a malformed terminal record" "$st" 1
assert_contains "saying to rewrite the record's first line" "$out" "rewrite the first line of"
assert_contains "quoting the expected shape" "$out" "expected: first line"
assert_eq "leaving the phase, branch, and redo count unchanged" \
  "$("$ORCH" state get phase) $("$ORCH" state get branch) $("$ORCH" state get redo_count)" \
  "review orch/21-redotest 0"
rm .orchestrator/review/iteration-05.md

state_fixture pr 30
state_fixture base_sha deadbeefcafe
"$ORCH" state set flake_rerun_used true
mkdir -p .orchestrator/review
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md
: >"$GH_FIXTURE/env.log"
base_before="$("$ORCH" state get base)"
writeln '# plan' >.orchestrator/handoff/01-plan.md
writeln '# implement' >.orchestrator/handoff/03-implement.md
plan_before="$(cat .orchestrator/handoff/01-plan.md)"
git push -q origin HEAD:refs/heads/redo-base
out="$(ORCHESTRATOR_HOST=claude "$ORCH" base set redo-base --flow 2>&1)"; st=$?
assert_status "base set --flow refuses a branched flow at the review phase" "$st" 1
assert_contains "naming redo as the way back on Claude Code" "$out" \
  "flow redotest already has branch orch/21-redotest - its base can change again once /orchestrator:redo retires it"
assert_eq "leaving the flow's base unchanged" "$("$ORCH" state get base)" "$base_before"
out="$(ORCHESTRATOR_HOST=junie "$ORCH" base set redo-base --flow 2>&1)"
assert_contains "and with the orch-flow section on another host" "$out" \
  "flow redotest already has branch orch/21-redotest - its base can change again once /orchestrator:redo (or orch-flow's Redo section) retires it"
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "a genuinely terminal loop redoes" "$st" 0
assert_eq "keeps the flow's recorded base branch" "$("$ORCH" state get base)" "$base_before"
assert_eq "prints the new redo count" "$out" "1"
assert_eq "records it in state" "$("$ORCH" state get redo_count)" "1"
assert_eq "resets the iteration for a fresh budget" "$("$ORCH" state get iteration)" "0"
assert_eq "and clears branch, PR, and base SHA" \
  "$("$ORCH" state get branch)$("$ORCH" state get pr)$("$ORCH" state get base_sha)" ""
assert_eq "steps the flow back to implement" "$("$ORCH" state get phase)" "implement"
assert_eq "leaves the one-per-flow flake rerun untouched" \
  "$("$ORCH" state get flake_rerun_used)" "true"
assert_eq "renames the old branch aside" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-1 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and republishes it on origin" \
  "$(git -C "$bare" rev-parse --quiet --verify refs/heads/orch/21-redotest-redo-1 >/dev/null && echo present || echo gone)" "present"
assert_eq "closes the old PR" "$(fake_pr_state_of 30)" "CLOSED"
assert_contains "with a comment naming the retired branch" \
  "$(fake_pr_comments_of 30)" "orch/21-redotest-redo-1"
assert_eq "the pr close call never reached a real gh subprocess" "$(gh_calls)" "0"
assert_eq "moves the old loop's records aside" \
  "$([ -f .orchestrator/review/pre-redo-1/iteration-05.md ] && echo yes || echo no)" "yes"
assert_eq "leaving the flat trail empty" \
  "$([ -e .orchestrator/review/iteration-05.md ] && echo yes || echo no)" "no"
assert_eq "retires the stale implement handoff under the same redo number" \
  "$(cat .orchestrator/handoff/pre-redo-1/03-implement.md)" "# implement"
assert_eq "leaving no implement handoff behind" \
  "$([ -e .orchestrator/handoff/03-implement.md ] && echo yes || echo no)" "no"
assert_eq "and the plan handoff untouched" "$(cat .orchestrator/handoff/01-plan.md)" "$plan_before"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "phase advance then refuses to leave implement" "$st" 1
assert_contains "for want of the implement handoff" "$out" "/.orchestrator/handoff/03-implement.md before leaving the implement phase"
out="$("$ORCH" base set redo-base --flow 2>&1)"; st=$?
assert_status "base set --flow succeeds again once redo review retired the branch" "$st" 0
assert_eq "recording the corrected base" "$("$ORCH" state get base)" "redo-base"

# A second redo in the same flow numbers on rather than overwriting the first.
state_fixture phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redotest orch/21-redotest-redo-1
stub_pushed_branch orch/21-redotest
state_fixture branch orch/21-redotest
state_fixture pr 31
state_fixture iteration 5
"$ORCH" state set budget 5
mkdir -p .orchestrator/review
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "a second stopped loop redoes just as the first did" "$st" 0
assert_eq "and numbers on rather than repeating redo-1" "$out" "2"
assert_eq "naming the branch redo-2" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-2 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "without disturbing redo-1's records" \
  "$([ -f .orchestrator/review/pre-redo-1/iteration-05.md ] && echo yes || echo no)" "yes"
assert_eq "moving the second loop's records into pre-redo-2" \
  "$([ -f .orchestrator/review/pre-redo-2/iteration-05.md ] && echo yes || echo no)" "yes"

state_fixture phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redotest
stub_pushed_branch orch/21-redotest
state_fixture branch orch/21-redotest
state_fixture pr 32
state_fixture iteration 1
"$ORCH" state set budget 1
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-01.md
fake_fail adapter_pr_close
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "a gh that will not close the PR fails the redo" "$st" 1
assert_eq "leaving the PR open" "$(fake_pr_state_of 32)" "OPEN"
assert_contains "naming the reason" "$out" "gh could not close PR #32"
assert_eq "leaving the phase where it was rather than half-finishing" \
  "$("$ORCH" state get phase)" "review"
assert_eq "still renames the branch aside since retire runs before the pr close" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-3 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and never moves the loop's records since gh failed first" \
  "$([ -f .orchestrator/review/iteration-01.md ] && echo yes || echo no)" "yes"
# Issue #63: the rename above is real, so state.branch has to follow it
# rather than keep naming a branch retire already renamed away - otherwise a
# retried redo dies confusingly against a branch that no longer exists.
assert_eq "updates state.branch to the branch retire actually produced" \
  "$("$ORCH" state get branch)" "orch/21-redotest-redo-3"
assert_eq "and records the bumped redo_count so a retry numbers on, not over" \
  "$("$ORCH" state get redo_count)" "3"

# A retry after that failure has to work from the state the failure left
# behind, and must not retire the already-retired branch a second time -
# issue #63 acceptance criterion 3: it should pick up from closing the PR.
rm -rf "$ORCH_GH_FAKE_STORE/fail"
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "retrying redo review after the gh failure now succeeds" "$st" 0
assert_eq "closing the PR this time" "$(fake_pr_state_of 32)" "CLOSED"
assert_eq "reuses redo-3 rather than numbering on to redo-4" "$out" "3"
assert_eq "does not retire the branch a second time" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-4 >/dev/null 2>&1 && echo present || echo gone)" "gone"
assert_eq "leaves redo-3 as the actually-retired branch" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-3 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and clears branch, PR, and base SHA on the now-successful redo" \
  "$("$ORCH" state get branch)$("$ORCH" state get pr)$("$ORCH" state get base_sha)" ""

# A loop that ended by marking the PR ready has already moved the flow to
# phase done, in the same operation that decided "ready" - there is no real
# window where redo could ever see phase: review with a ready terminal
# record. Produced the way the system actually produces it (review ready
# itself, not a hand-crafted state), redo rejects it exactly as it would any
# other done flow, through the same phase gate, not a ready-specific branch.
state_fixture phase review
state_fixture pr 33
state_fixture iteration 1
"$ORCH" state set budget 1
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-01.md
"$ORCH" review ready >/dev/null
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "a loop that ended ready is out of scope for redo, same as any done flow" "$st" 1
assert_contains "the same phase-gate refusal as any other done flow" "$out" "flow is not at the review phase"
assert_eq "leaving the ready PR open" "$(fake_pr_state_of 33)" "OPEN"
restore_suite_env

# --- redo review refuses a taken handoff destination ------------------------
# Issue #304: the implement handoff retires into exactly the pre-redo-N/ that
# pairs with review/pre-redo-N/, or redo stops naming it - never a suffixed
# pre-redo-N-2/. The destination is pre-created, so no clock is involved.
echo
echo "redo review refuses a taken handoff destination"
healthy_repo
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init redotaken >/dev/null
state_fixture phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redotaken
git push -q -u origin orch/21-redotaken
state_fixture branch orch/21-redotaken
state_fixture pr 35
state_fixture iteration 1
"$ORCH" state set budget 1
mkdir -p .orchestrator/review .orchestrator/handoff/pre-redo-1
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-01.md
writeln '# older implement' >.orchestrator/handoff/pre-redo-1/03-implement.md
writeln '# implement' >.orchestrator/handoff/03-implement.md
fake_github
fake_issue 21 open
fake_pr 35 open orch/21-redotaken main
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "a destination already holding the handoff fails the redo" "$st" 1
assert_contains "naming the destination" "$out" "pre-redo-1"
assert_eq "leaving the live implement handoff in place" \
  "$(cat .orchestrator/handoff/03-implement.md 2>/dev/null)" "# implement"
assert_eq "and the retired one untouched" \
  "$(cat .orchestrator/handoff/pre-redo-1/03-implement.md)" "# older implement"
assert_eq "never retiring into a suffixed pre-redo-1-2" \
  "$([ -e .orchestrator/handoff/pre-redo-1-2 ] && echo present || echo gone)" "gone"
restore_suite_env

# --- redo review reopens tickets -------------------------------------------
# Acceptance criterion from issue #88: a prior implement phase closes every
# ticket of the flow's spec issue as it works the frontier, so a redo back to
# implement has to reopen them - otherwise the redone implement phase's
# frontier query (ticket next) finds nothing and opens an empty PR.
echo
echo "redo review reopens tickets"
healthy_repo
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init tickettest >/dev/null

fake_github
fake_issue 60 open
fake_pr 40 open orch/60-tickettest main
body="$(mktemp)"; printf 'Body of the ticket.\n' >"$body"
t1="$("$ORCH" ticket publish 60 "One" "$body")"
t2="$("$ORCH" ticket publish 60 "Two" "$body")"
"$ORCH" ticket close "$t1" >/dev/null
"$ORCH" ticket close "$t2" >/dev/null
assert_eq "frontier is empty once every ticket is closed" "$("$ORCH" ticket next 60)" ""

state_fixture phase review
"$ORCH" state set issue 60
git checkout -q -b orch/60-tickettest
git push -q -u origin orch/60-tickettest
state_fixture branch orch/60-tickettest
state_fixture pr 40
state_fixture iteration 1
"$ORCH" state set budget 1
mkdir -p .orchestrator/review
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-01.md
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "redo review succeeds with every ticket already closed" "$st" 0
assert_eq "reopens exactly the tickets the flow's implement phase had closed" \
  "$("$ORCH" ticket next 60)" "$(printf '%s\n%s' "$t1" "$t2")"

restore_suite_env

# --- redo spec --------------------------------------------------------------
# --new-issue's close goes through the store-backed fake (fake_github), the
# closed issue read back from its store - the fixture gh's log stays empty, proving it
# never spawns a real gh subprocess. The real operation is pinned in "gh
# adapter contract".
echo
echo "redo spec"
fresh_flow redospec

out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "refuses outside the implement phase" "$st" 1
assert_contains "naming the reason" "$out" "flow is not at the implement phase"

state_fixture phase implement
"$ORCH" state set issue 40
state_fixture redo_count 2
writeln '# plan' >.orchestrator/handoff/01-plan.md
writeln '# spec' >.orchestrator/handoff/02-spec.md
writeln '# implement' >.orchestrator/handoff/03-implement.md
fake_github
fake_issue 40 open
before="$(fake_snapshot)"
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "the default path steps back to spec" "$st" 0
assert_eq "phase becomes spec" "$("$ORCH" state get phase)" "spec"
assert_eq "keeping the existing issue" "$("$ORCH" state get issue)" "40"
assert_eq "and, with no breakdown to retire, writing nothing to GitHub" "$(fake_snapshot)" "$before"
retired="$(ls -d .orchestrator/handoff/pre-redo-spec-* 2>/dev/null)"
assert_eq "retires the handoffs into one timestamped directory" \
  "$(printf '%s\n' "$retired" | grep -c '^\.orchestrator/handoff/pre-redo-spec-[0-9]\{8\}-[0-9]\{6\}$')" "1"
assert_eq "holding the stale spec handoff" "$(cat "$retired/02-spec.md" 2>/dev/null)" "# spec"
assert_eq "and the stale implement handoff" "$(cat "$retired/03-implement.md" 2>/dev/null)" "# implement"
assert_eq "leaving neither behind" \
  "$(ls .orchestrator/handoff/02-spec.md .orchestrator/handoff/03-implement.md 2>/dev/null)" ""
assert_eq "the plan handoff untouched" "$(cat .orchestrator/handoff/01-plan.md)" "# plan"
assert_eq "without bumping redo_count" "$("$ORCH" state get redo_count)" "2"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "phase advance then refuses to leave spec" "$st" 1
assert_contains "for want of the spec handoff" "$out" "/.orchestrator/handoff/02-spec.md before leaving the spec phase"

state_fixture phase implement
"$ORCH" state set issue 41
# Clear the first run's directory so a second run in the same second does not
# meet a taken destination, which retire_handoffs refuses (#304).
rm -rf .orchestrator/handoff/pre-redo-spec-*
writeln '# spec again' >.orchestrator/handoff/02-spec.md
: >"$GH_FIXTURE/env.log"
fake_github
fake_issue 41 open
out="$("$ORCH" redo spec --new-issue 2>&1)"; st=$?
assert_status "--new-issue also steps back to spec" "$st" 0
# shellcheck disable=SC2010 # counts what the glob matched; ls prints nothing when it matches none
assert_eq "with no implement handoff, retires the spec handoff alone" \
  "$(ls .orchestrator/handoff/pre-redo-spec-*/02-spec.md 2>/dev/null | grep -c .) $(ls .orchestrator/handoff/pre-redo-spec-*/03-implement.md 2>/dev/null | grep -c .)" "1 0"
assert_eq "phase becomes spec" "$("$ORCH" state get phase)" "spec"
assert_eq "clearing the old issue" "$("$ORCH" state get issue)" ""
assert_eq "closes the old issue" "$(fake_state_of 41)" "CLOSED"
assert_contains "saying why, in a comment on it" "$(fake_comments_of 41)" \
  "This issue was closed by an orchestrator redo because the spec itself needed to change."
assert_eq "the close call never reached a real gh subprocess" "$(gh_calls)" "0"

state_fixture phase implement
"$ORCH" state set issue 42
fake_issue 42 open
fake_fail adapter_issue_close "HTTP 502: Bad Gateway"
out="$("$ORCH" redo spec --new-issue 2>&1)"; st=$?
assert_status "a gh that will not close the issue fails --new-issue" "$st" 1
assert_contains "passing gh's reason through" "$out" "HTTP 502: Bad Gateway"
assert_eq "leaving the phase where it was rather than half-finishing" \
  "$("$ORCH" state get phase)" "implement"

out="$("$ORCH" redo spec --bogus 2>&1)"; st=$?
assert_status "rejects an unknown flag" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh redo spec"
restore_suite_env

# --- redo spec retires the ticket breakdown (#334) ---------------------------
# A spec redone because it had to change gets a fresh breakdown: the default
# path retires the kept issue's old one before stepping back, so the spec
# phase's `ticket exists` answers 1 and orch-to-tickets runs again.
echo
echo "redo spec retires the ticket breakdown (#334)"
fresh_flow redospecbreakdown
fake_github
for p in 50 51 52 53 54 55 56 57 58; do fake_issue "$p" open; done
tbody="$(mktemp)"
writeln 'A ticket.' >"$tbody"
fake_next_issue 900
rt1="$("$ORCH" ticket publish 50 "One" "$tbody")"
rt2="$("$ORCH" ticket publish 50 "Two" "$tbody")"
rt3="$("$ORCH" ticket publish 50 "Three" "$tbody")"
"$ORCH" ticket close "$rt2" >/dev/null
fake_issue_body 50 'The spec of #50.'
redo_spec_at() {
  state_fixture phase implement
  "$ORCH" state set issue "$1"
  rm -rf .orchestrator/handoff/pre-redo-spec-*
  writeln '# spec' >.orchestrator/handoff/02-spec.md
  writeln '# implement' >.orchestrator/handoff/03-implement.md
}
redo_spec_at 50
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a sub-issue breakdown: redo spec succeeds" "$st" 0
assert_eq "the parent is left with no sub-issues" "$(fake_sub_issues_of 50)" ""
retire_msg="This ticket was retired: its spec, #50, changed and will be broken down into tickets again."
for t in "$rt1" "$rt2" "$rt3"; do
  assert_eq "old ticket #$t is closed" "$(fake_state_of "$t")" "CLOSED"
  assert_contains "old ticket #$t carries the retirement comment, naming a changed spec" \
    "$(fake_comments_of "$t")" "$retire_msg"
  assert_eq "old ticket #$t carries no comment in the old redo wording" \
    "$(fake_comments_of "$t" | grep -c "retired by an orchestrator redo")" "0"
done
assert_eq "an open old ticket is closed as not planned" "$(fake_reason_of "$rt1")" "not planned"
out="$("$ORCH" ticket exists 50 2>&1)"; st=$?
assert_status "ticket exists then finds no breakdown" "$st" 1
assert_eq "phase becomes spec" "$("$ORCH" state get phase)" "spec"
assert_eq "keeping the issue" "$("$ORCH" state get issue)" "50"
out="$("$ORCH" ticket reset 50 2>&1)"; st=$?
assert_eq "a later ticket reset reopens none of the old tickets" \
  "$(fake_state_of "$rt1") $(fake_state_of "$rt2") $(fake_state_of "$rt3")" "CLOSED CLOSED CLOSED"

# Each body below is seeded as gh's read of it answers.
fake_body_read 51 'Intro\r\n\r\n## Ticket\r\n\r\n### What to build\r\nBuild.\r\n\r\n## After\r\nTail.\r\n'
redo_spec_at 51
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a collapsed CRLF breakdown: redo spec succeeds" "$st" 0
assert_eq "the ## Ticket section is gone and the rest of the CRLF body is unchanged" \
  "$(fake_body_of 51 | od -c)" "$(printf 'Intro\r\n\r\n## After\r\nTail.\r\n' | od -c)"
out="$("$ORCH" ticket exists 51 2>&1)"; st=$?
assert_status "ticket exists then finds no breakdown" "$st" 1

fake_body_read 52 '%s\n' 'The spec.' '' '## Ticket' '' '```sh' '# not a heading' '```' 'Build it.'
redo_spec_at 52
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a collapsed breakdown at the body's end: redo spec succeeds" "$st" 0
assert_eq "drops the section and the blank line before it, a fenced # line included" \
  "$(fake_body_of 52 | od -c)" "$(writeln 'The spec.' | od -c)"

before="$(fake_snapshot)"
out="$("$ORCH" ticket retire 50 2>&1)"; st=$?
assert_status "retiring an already-retired sub-issue breakdown succeeds" "$st" 0
out="$("$ORCH" ticket retire 52 2>&1)"; st=$?
assert_status "retiring an already-retired collapsed breakdown succeeds" "$st" 0
assert_eq "and writes nothing to GitHub" "$(fake_snapshot)" "$before"

rt4="$("$ORCH" ticket publish 53 "Four" "$tbody")"
redo_spec_at 53
fake_fail adapter_sub_issue_unlink
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a gh that will not unlink a ticket fails redo spec" "$st" 1
assert_contains "naming what failed" "$out" "gh could not unlink ticket #$rt4"
assert_eq "leaving the phase at implement" "$("$ORCH" state get phase)" "implement"
assert_eq "and the handoffs in place" "$(cat .orchestrator/handoff/02-spec.md .orchestrator/handoff/03-implement.md)" \
  "$(printf '# spec\n# implement')"
fake_unfail
fake_fail adapter_sub_issues
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a gh that cannot list sub-issues fails redo spec" "$st" 1
assert_eq "leaving the phase at implement" "$("$ORCH" state get phase)" "implement"
fake_unfail
fake_issue_body 54 "$(writeln 'Spec.' '' '## Ticket' 'Build.')"
redo_spec_at 54
fake_fail adapter_issue_body_edit
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a gh that will not rewrite the body fails redo spec" "$st" 1
assert_eq "leaving the phase at implement" "$("$ORCH" state get phase)" "implement"
fake_unfail
redo_spec_at 53
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a re-run after the failure resumes and succeeds" "$st" 0
assert_eq "retiring the ticket it could not unlink before" \
  "$(fake_sub_issues_of 53) $(fake_state_of "$rt4")" " CLOSED"

assert_eq "without commenting on it a second time" \
  "$(fake_comments_of "$rt4" | grep -cxF "This ticket was retired: its spec, #53, changed and will be broken down into tickets again.")" "1"

# A closed ticket still linked to its parent, carrying a comment in the old
# redo wording: the state a retire that died part-way under the old wording
# leaves. A retire now treats that comment as already posted.
rt5="$("$ORCH" ticket publish 55 "Five" "$tbody")"
"$ORCH" ticket close "$rt5" >/dev/null
fake_comment "$rt5" fake-gh 2026-01-01T00:00:00Z \
  "This ticket was retired by an orchestrator redo: its spec, #55, is being redone and will be broken down into tickets again."
fake_fail adapter_issue_comment
out="$("$ORCH" ticket retire 55 2>&1)"; st=$?
assert_status "a closed, linked ticket with an old-wording comment: retire succeeds, posting no second comment" "$st" 0
fake_unfail
assert_eq "leaving its one old-wording comment alone" "$(fake_comments_of "$rt5" | grep -c .)" "1"
assert_eq "and unlinking it" "$(fake_sub_issues_of 55)" ""
out="$("$ORCH" ticket exists 55 2>&1)"; st=$?
assert_status "ticket exists then finds no breakdown" "$st" 1

fake_issue_body 56 "$(writeln 'Intro' '```md' '## Ticket' 'example' '```' '' '## Ticket' 'Build.')"
out="$("$ORCH" ticket retire 56 2>&1)"; st=$?
assert_status "a body with a fenced ## Ticket example: retire succeeds" "$st" 0
assert_eq "cutting only the real section, the fenced example kept" \
  "$(fake_body_of 56 | od -c)" "$(writeln 'Intro' '```md' '## Ticket' 'example' '```' | od -c)"
out="$("$ORCH" ticket exists 56 2>&1)"; st=$?
assert_status "ticket exists then ignores the fenced example" "$st" 1
fake_issue_body 57 "$(writeln 'Intro' '```md' '## Ticket' '```')"
fake_fail adapter_issue_body_edit
out="$("$ORCH" ticket retire 57 2>&1)"; st=$?
assert_status "a body whose only ## Ticket is fenced: retire succeeds, writing nothing to GitHub" "$st" 0
fake_unfail
out="$("$ORCH" ticket exists 57 2>&1)"; st=$?
assert_status "ticket exists finds no breakdown in a fenced ## Ticket alone" "$st" 1
fake_body_read 58 'Spec.\n\n## Ticket\nBuild.\n\n## After\nTail.\n\n\n'
"$ORCH" ticket retire 58 >/dev/null 2>&1
assert_eq "trailing blank lines after the section are kept" \
  "$(fake_body_of 58 | od -c)" "$(printf 'Spec.\n\n## After\nTail.\n\n\n' | od -c)"
fake_body_read 58 'Spec, no ticket heading.\n'
fake_fail adapter_issue_body_edit
out="$("$ORCH" ticket retire 58 2>&1)"; st=$?
assert_status "a body with no ## Ticket heading: retire succeeds, writing nothing to GitHub" "$st" 0
fake_unfail

errf="$(mktemp)"
fake_issue_body 58 "$(writeln 'Spec.' '' '## Ticket' 'Build.')"
fake_fail adapter_issue_body
out="$("$ORCH" ticket retire 58 2>"$errf")"; st=$?
assert_status "a gh that cannot read the body fails ticket retire" "$st" 1
assert_eq "naming the body read: exact stderr" "$(tail -n 1 "$errf")" "orch: gh could not read issue #58's body"
fake_unfail
fake_fail adapter_issue_body_edit
out="$("$ORCH" ticket retire 58 2>"$errf")"; st=$?
assert_status "a gh that cannot write the body fails ticket retire" "$st" 1
assert_eq "naming the section cut: exact stderr" "$(tail -n 1 "$errf")" "orch: gh could not remove the ## Ticket section from #58"
fake_unfail
rm -f "$errf"

rt5="$("$ORCH" ticket publish 55 "Five" "$tbody")"
redo_spec_at 55
out="$("$ORCH" redo spec --new-issue 2>&1)"; st=$?
assert_status "--new-issue still steps back to spec" "$st" 0
assert_eq "without retiring the closed issue's tickets" \
  "$(fake_sub_issues_of 55) $(fake_state_of "$rt5")" "$rt5 OPEN"

out="$("$ORCH" help 2>&1)"
assert_contains "ticket retire is in the usage text" "$out" "ticket retire <parent>"
restore_suite_env

# --- spec-review begin (#224) ------------------------------------------------
# A standalone spec review's guard and working-directory reset have one right
# answer each, so they live here: refuse an issue an active flow holds, and
# otherwise hand back an emptied .orchestrator/spec-review/<n>/.
echo
echo "spec-review begin (#224)"
new_repo >/dev/null
top="$(git rev-parse --show-toplevel)"
sr_dir="$top/.orchestrator/spec-review/14"
mkdir -p "$sr_dir/sub"
echo stale >"$sr_dir/spec.md"
echo stale >"$sr_dir/sub/changelog.md"
out="$("$ORCH" spec-review begin 14 2>&1)"; st=$?
assert_status "with no state file it proceeds" "$st" 0
assert_eq "printing the working directory and nothing else" "$out" "$sr_dir/"
assert_eq "which exists and is empty" "$(ls -A "$sr_dir" 2>&1)" ""
[ -f "$top/.orchestrator/state.json" ] && bad "writes no state file" "state.json appeared" \
  || ok "writes no state file"
out="$("$ORCH" spec-review begin 15 2>&1)"; st=$?
assert_status "a directory that was never there is created" "$st" 0
assert_eq "empty" "$(ls -A "$top/.orchestrator/spec-review/15" 2>&1)" ""

sr_state="$top/.orchestrator/state.json"
sr_flow() { printf '{"slug":"x","phase":"%s","issue":%s,"branch":null}\n' "$1" "$2" >"$sr_state"; }
sr_seed() { mkdir -p "$sr_dir"; echo keep >"$sr_dir/spec.md"; }
for p in spec implement review; do
  sr_flow "$p" 14; sr_seed
  before="$(cksum <"$sr_state")"
  out="$("$ORCH" spec-review begin 14 2>&1)"; st=$?
  assert_status "an active flow on 14 at $p refuses 14" "$st" 1
  if [ "$p" = spec ]; then
    assert_contains "pointing at next at $p" "$out" "/orchestrator:next"
    assert_contains "because the spec phase will review it" "$out" "spec phase"
  else
    assert_contains "pointing at redo at $p" "$out" "/orchestrator:redo"
    assert_contains "because the tickets build from it at $p" "$out" "cannot change behind the flow"
  fi
  assert_contains "naming the issue at $p" "$out" "#14"
  assert_eq "leaving the directory untouched at $p" "$(cat "$sr_dir/spec.md" 2>&1)" "keep"
  assert_eq "and state.json byte-for-byte unchanged at $p" "$(cksum <"$sr_state")" "$before"
done

# State never holds any other phase; a corrupt one is refused, not guessed at.
sr_flow bogus 14; sr_seed
out="$("$ORCH" spec-review begin 14 2>&1)"; st=$?
assert_status "a phase outside PHASES refuses 14" "$st" 1
assert_contains "pointing at doctor" "$out" "doctor --flow"
assert_eq "leaving the directory untouched" "$(cat "$sr_dir/spec.md" 2>&1)" "keep"

sr_flow implement 14; sr_seed
before="$(cksum <"$sr_state")"
out="$("$ORCH" spec-review begin 15 2>&1)"; st=$?
assert_status "an active flow on 14 lets 15 through" "$st" 0
assert_eq "printing 15's directory" "$out" "$top/.orchestrator/spec-review/15/"
assert_eq "leaving 14's directory alone" "$(cat "$sr_dir/spec.md" 2>&1)" "keep"
assert_eq "state.json unchanged by a pass" "$(cksum <"$sr_state")" "$before"

sr_flow "done" 14; sr_seed
before="$(cksum <"$sr_state")"
out="$("$ORCH" spec-review begin 14 2>&1)"; st=$?
assert_status "a done flow on 14 lets 14 through" "$st" 0
assert_eq "printing its directory" "$out" "$sr_dir/"
assert_eq "wiped" "$(ls -A "$sr_dir" 2>&1)" ""
assert_eq "state.json unchanged by a done-flow pass" "$(cksum <"$sr_state")" "$before"

rm -f "$sr_state"
sr_seed
for args in "" "abc" "14x" "../14" "14 15"; do
  # shellcheck disable=SC2086 # word splitting is the point: "14 15" is two args
  out="$("$ORCH" spec-review begin $args 2>&1)"; st=$?
  assert_status "refuses begin '$args'" "$st" 1
  assert_eq "and deletes nothing for '$args'" "$(cat "$sr_dir/spec.md" 2>&1)" "keep"
done
out="$("$ORCH" spec-review begin 2>&1)"
assert_contains "a missing number gets the usage" "$out" "usage: orch.sh spec-review begin <n>"
out="$("$ORCH" spec-review begin abc 2>&1)"
assert_contains "a non-numeric number is named" "$out" "plain issue number"
out="$("$ORCH" spec-review wipe 14 2>&1)"; st=$?
assert_status "refuses an op it does not have" "$st" 1
assert_contains "naming the one it does" "$out" "want begin"
assert_contains "help documents spec-review begin" "$("$ORCH" help)" "spec-review begin <n>"

# --- quick implementation runs an unattended spec review (#237) -------------
# A quick implementation runs an unattended standalone spec review before any flow
# exists, so spec-review begin needs no state.
echo
echo "quick implementation runs an unattended spec review (#237)"
new_repo >/dev/null
top="$(git rev-parse --show-toplevel)"
out="$("$ORCH" spec-review begin 21 2>&1)"; st=$?
assert_status "spec-review begin with no flow state succeeds" "$st" 0
assert_eq "and prints the working directory" "$out" "$top/.orchestrator/spec-review/21/"

# --- doctor: base branch check -----------------------------------------------
# A set base branch that has vanished from origin is the one stale setting that
# would send the next flow's fork and PR at nothing, so it FAILs; origin being
# unreachable only means doctor could not tell, so it warns.
echo
echo "doctor: base branch check"
healthy_repo
doctor_github
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a default base branch passes" "$st" 0
assert_contains "reports the default branch as the base branch" "$out" "ok    base branch: main (default)"
assert_contains "keeps the default-branch check" "$out" "ok    default branch: main (from GitHub)"

bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
git push -q "$bare" HEAD:refs/heads/main HEAD:refs/heads/uat
bare_origin "$bare"
git config orchestrator.base uat
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a set base branch origin has passes" "$st" 0
assert_contains "reports the set base branch" "$out" "ok    base branch: uat (set)"

git config orchestrator.base gone
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a set base branch missing from origin fails" "$st" 1
assert_contains "names the missing base branch" "$out" "FAIL  base branch gone"
assert_contains "gives the way out" "$out" "base clear"

git remote set-url origin "$(dirname "$bare")/unreachable.git"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unverifiable base branch does not block the flow" "$st" 0
assert_contains "warns that origin could not be reached" "$out" "warn  base branch gone"
git config --unset orchestrator.base
rm -rf "$(dirname "$bare")"
restore_suite_env

# --- phase advance / phase boundary ------------------------------------------
# A phase is left only once the handoff it writes for the next one is valid
# (#279): advance is the one place that rule is enforced, so a model that skips
# the prose cannot skip it.
echo
echo "phase advance"
new_repo >/dev/null
"$ORCH" init advancing >/dev/null
export ORCHESTRATOR_HOST=claude

out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at spec with no spec handoff" "$st" 1
assert_contains "names the missing handoff" "$out" "02-spec.md"
assert_contains "prints a FAIL line for it" "$out" "FAIL  handoff not found:"
assert_contains "dies with only the remedy" "$out" "02-spec.md before leaving the spec phase"
assert_not_contains "without repeating that it was not found" "$(printf '%s\n' "$out" | grep '^orch:')" "handoff not found"
assert_eq "leaves the phase at spec" "$("$ORCH" state get phase)" "spec"

"$ORCH" state set issue 7
hs2="$("$ORCH" handoff path implement)"
writeln '## Spec issue' '#7.' '' '## Seams' '' '## Spec review changelog' 'None.' '' \
        '## Ticket breakdown' '#7.' '' '## Host fallbacks' 'None.' >"$hs2"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at spec with an invalid spec handoff" "$st" 1
assert_contains "prints the FAIL lines" "$out" "FAIL  empty section: ## Seams"
assert_eq "and leaves the phase at spec" "$("$ORCH" state get phase)" "spec"

complete_spec_handoff "$hs2"
"$ORCH" state set issue null
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at spec with no issue recorded" "$st" 1
assert_contains "naming the missing issue" "$out" "no issue recorded"
assert_eq "and leaves the phase at spec" "$("$ORCH" state get phase)" "spec"

"$ORCH" state set issue 7
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "advances spec to implement with a valid handoff and an issue" "$st" 0
assert_eq "records the implement phase" "$("$ORCH" state get phase)" "implement"
assert_contains "prints the boundary naming the spec handoff" "$out" \
  "Phase spec complete. Handoff written to $hs2."
assert_contains "with the Claude Code Next line" "$out" "Next: /clear, then /orchestrator:next"

out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at implement with no implement handoff" "$st" 1
assert_contains "names the missing handoff" "$out" "03-implement.md"
assert_eq "leaves the phase at implement" "$("$ORCH" state get phase)" "implement"

hi2="$("$ORCH" handoff path review)"
complete_implement_handoff "$hi2"
for field in branch base_sha pr; do
  state_fixture branch orch/7-advancing
  state_fixture base_sha abc1234
  state_fixture pr 3
  state_fixture "$field" null
  out="$("$ORCH" phase advance 2>&1)"; st=$?
  assert_status "refuses at implement with no $field recorded" "$st" 1
  case "$field" in
    branch)   want="no branch recorded" ;;
    base_sha) want="no base SHA recorded" ;;
    pr)       want="no PR recorded" ;;
  esac
  assert_contains "naming the missing $field" "$out" "$want"
  assert_eq "and leaves the phase at implement (no $field)" "$("$ORCH" state get phase)" "implement"
done

state_fixture pr 3
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "advances implement to review with a valid handoff and the fields" "$st" 0
assert_eq "records the review phase" "$("$ORCH" state get phase)" "review"
assert_contains "prints the boundary naming the implement handoff" "$out" \
  "Phase implement complete. Handoff written to $hi2."

out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at review" "$st" 1
assert_contains "pointing at review ready" "$out" "review ready"
assert_eq "and leaves the phase at review" "$("$ORCH" state get phase)" "review"

state_fixture phase "done"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at done" "$st" 1
assert_eq "and leaves the phase at done" "$("$ORCH" state get phase)" "done"

out="$("$ORCH" phase advance extra 2>&1)"; st=$?
assert_status "advance takes no arguments" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh phase advance"

echo
echo "phase boundary"
state_fixture phase spec
out="$("$ORCH" phase boundary 2>&1)"; st=$?
assert_status "prints at flow start" "$st" 0
assert_eq "names the plan handoff and the Claude Code Next line" "$out" \
  "$(printf 'Phase plan complete. Handoff written to %s.\n\n  Next: /clear, then /orchestrator:next' "$("$ORCH" handoff path spec)")"
state_fixture phase review
out="$(ORCHESTRATOR_HOST=junie "$ORCH" phase boundary 2>&1)"
assert_eq "on Junie names the Junie Next line" "$out" \
  "$(printf 'Phase implement complete. Handoff written to %s.\n\n  Next: /new, then ask for the next phase with /orch-flow' "$hi2")"
out="$(ORCHESTRATOR_HOST=other "$ORCH" phase boundary 2>&1)"
assert_eq "on an unknown host names the fresh-session Next line" "$out" \
  "$(printf 'Phase implement complete. Handoff written to %s.\n\n  Next: a fresh session, then /orchestrator:next (or orch-flow'"'"'s Next phase section)' "$hi2")"
state_fixture phase "done"
out="$("$ORCH" phase boundary 2>&1)"; st=$?
assert_status "refuses once the flow is done" "$st" 1
out="$("$ORCH" phase bogus 2>&1)"; st=$?
assert_status "an unknown phase op is an error" "$st" 1
assert_contains "naming the ops it wants" "$out" "advance|boundary"
unset ORCHESTRATOR_HOST

# --- the section filter (ORCH_TEST_ONLY, #612) ----------------------------------
# The suite run as a child process under a filter, asserted on its stdout and
# exit status. The child starts inside a git repo, so its isolation section
# shows the harness holds under a filter too.
echo
echo "the section filter (ORCH_TEST_ONLY, #612)"
new_repo >/dev/null
out="$(ORCH_TEST_QUIET='' ORCH_TEST_ONLY='^isolation$' bash "$SUITE_SCRIPT" 2>&1)"; st=$?
assert_status "a filter matching only isolation passes" "$st" 0
assert_eq "runs the isolation section" "$(printf '%s\n' "$out" | grep -cx 'isolation')" "1"
assert_eq "runs no other section" "$(printf '%s\n' "$out" | grep -cxE 'init|slug|doctor')" "0"
assert_eq "counts only what ran in the summary" "$(printf '%s\n' "$out" | tail -n 1)" \
  "6 passed, 0 failed"
assert_contains "keeps the cwd isolation, started from a git repo" "$out" \
  "ok   the suite starts outside any git work tree"
assert_contains "keeps the HOME isolation" "$out" "ok   HOME is the suite's own HOME"

out="$(ORCH_TEST_QUIET='' ORCH_TEST_ONLY='^ticket (block|unblock)$' bash "$SUITE_SCRIPT" 2>/dev/null)"
assert_eq "matches titles without their trailing dashes" \
  "$(printf '%s\n' "$out" | grep -cxE 'ticket block|ticket unblock')" "2"
assert_eq "runs isolation alongside the matched sections" \
  "$(printf '%s\n' "$out" | grep -cx 'isolation')" "1"
assert_eq "skips the sections the pattern does not match" \
  "$(printf '%s\n' "$out" | grep -cxE 'ticket close|ticket reset')" "0"

out="$(ORCH_TEST_ONLY='^no such section$' bash "$SUITE_SCRIPT" 2>/dev/null)"; st=$?
assert_status "a pattern matching no section exits 1" "$st" 1
assert_eq "lists the sections from isolation on" "$(printf '%s\n' "$out" | sed -n 1p)" "isolation"
assert_eq "lists a sub-section as a title of its own" \
  "$(printf '%s\n' "$out" | grep -cxF 'doctor: host (#128)')" "1"
assert_eq "lists titles without trailing dashes" "$(printf '%s\n' "$out" | grep -c -- '-$')" "0"
assert_eq "lists no shared-setup header" \
  "$(printf '%s\n' "$out" | grep -cE 'doctor harness|fixture gh')" "0"
assert_eq "runs nothing" "$(printf '%s\n' "$out" | grep -c 'passed')" "0"

# --- quiet mode (ORCH_TEST_QUIET, #614) ----------------------------------------
# A filtered, quiet child run of this suite, and one quiet run each of the
# other two suites. Quiet mode hides the ok lines only: the counts, headers,
# FAIL/skip lines with their detail, and the summary all stay. hooks_test.sh
# and docs_lint.sh are judged on their ok lines alone, not on their status.
echo
echo "quiet mode (ORCH_TEST_QUIET, #614)"
out="$(ORCH_TEST_QUIET=1 ORCH_TEST_ONLY='^isolation$' bash "$SUITE_SCRIPT" 2>&1)"; st=$?
assert_status "a quiet, filtered run passes" "$st" 0
assert_eq "prints no ok line" "$(printf '%s\n' "$out" | grep -c '^  ok ')" "0"
assert_eq "still prints the section header" "$(printf '%s\n' "$out" | grep -cx 'isolation')" "1"
assert_eq "still counts every pass in the summary" "$(printf '%s\n' "$out" | tail -n 1)" \
  "6 passed, 0 failed"
# A copy of the scripts tree whose isolation section gains a failing and a
# skipped check, so the FAIL and skip lines are seen kept under quiet mode.
quiet_dir="$(mktemp -d)"
cp -R "$PLUGIN_ROOT/scripts" "$quiet_dir/"
awk '{ print } $0 == "echo \"isolation\"" {
  print "bad \"a planted failure\" \"its detail line\""
  print "skip \"a planted skip\" \"its reason line\"" }' "$SUITE_SCRIPT" \
  >"$quiet_dir/scripts/test/orch_test.sh"
out="$(ORCH_TEST_QUIET=1 ORCH_TEST_ONLY='^isolation$' \
  bash "$quiet_dir/scripts/test/orch_test.sh" 2>&1)"; st=$?
assert_status "a quiet run with a failure exits 1" "$st" 1
assert_contains "keeps a FAIL line with its detail line" "$out" \
  "$(printf '  FAIL a planted failure\n     its detail line')"
assert_contains "keeps a skip line with its reason line" "$out" \
  "$(printf '  skip a planted skip\n     its reason line')"
assert_eq "summarises the hidden passes, the failure and the skip" \
  "$(printf '%s\n' "$out" | tail -n 1)" "6 passed, 1 failed, 1 skipped"
assert_eq "still prints no ok line beside a failure" "$(printf '%s\n' "$out" | grep -c '^  ok ')" "0"
rm -rf "$quiet_dir"
for quiet_suite in hooks_test.sh docs_lint.sh; do
  out="$(ORCH_TEST_QUIET=1 bash "$(dirname "$SUITE_SCRIPT")/$quiet_suite" 2>&1)"
  assert_eq "$quiet_suite prints no ok line when quiet" \
    "$(printf '%s\n' "$out" | grep -c '^  ok ')" "0"
  assert_contains "$quiet_suite still prints its summary when quiet" "$out" " passed, "
done
out="$(ORCH_TEST_QUIET='' ORCH_TEST_ONLY='^isolation$' bash "$SUITE_SCRIPT" 2>&1)"
assert_eq "without quiet mode, prints every ok line" \
  "$(printf '%s\n' "$out" | grep -c '^  ok ')" "6"

# --- all.sh, the single entry point (#615) ----------------------------------
# A copy of all.sh in <tmp>/scripts/test/ beside three stub suites, never the
# real ones, so <tmp> is the repo root: orch_test.sh's stub fails, the other
# two pass. Each stub logs whether ORCH_TEST_ONLY and ORCH_TEST_QUIET reached
# it, and VERSION_BASE. One planted shell file each in <tmp>/scripts/ and
# <tmp>/scripts/test/ is there for the lint step to find. Every run sets or
# unsets CI and runs on a PATH of only the tools all.sh and the stubs need,
# plus a stub shellcheck when the case wants one - the real one never runs.
echo
echo "all.sh, the single entry point (#615)"
all_root="$(mktemp -d)"
all_dir="$all_root/scripts/test"
all_bin="$all_root/bin"
mkdir -p "$all_dir" "$all_bin"
cp "$(dirname "$SUITE_SCRIPT")/all.sh" "$all_dir/"
for all_tool in bash dirname awk tail; do
  ln -s "$(command -v "$all_tool")" "$all_bin/$all_tool"
done
echo 'echo planted' >"$all_root/scripts/lint_me.sh"
echo 'echo planted' >"$all_dir/lint_me.sh"
for all_suite in orch_test.sh hooks_test.sh docs_lint.sh; do
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"$all_suite only=\${ORCH_TEST_ONLY-unset} quiet=\${ORCH_TEST_QUIET-unset} base=\${VERSION_BASE-unset}\" >>\"\$(dirname \"\$0\")/log\""
    echo 'echo; echo "a section header"'
    if [ "$all_suite" = orch_test.sh ]; then
      echo "printf '  FAIL a stub failure\n     its detail line\n  FAIL another failure\n     its own detail\n'"
      echo 'echo; echo "2 passed, 2 failed"; exit 1'
    else
      echo 'echo; echo "7 passed, 0 failed"'
    fi
  } >"$all_dir/$all_suite"
done
# all_sc_stub <exit> [<stdout line>...]: put a stub shellcheck on all.sh's
# PATH that logs its arguments, prints the lines and exits <exit>.
all_sc_stub() {
  local code="$1" line
  shift
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"\$*\" >>'$all_root/sc_args'"
    for line in "$@"; do printf 'echo %q\n' "$line"; done
    echo "exit $code"
  } >"$all_bin/shellcheck"
  chmod +x "$all_bin/shellcheck"
}
all_bash="$(command -v bash)"
all_finding1='scripts/lint_me.sh:1:1: warning: a planted finding [SC2034]'
all_finding2='scripts/test/lint_me.sh:2:5: error: another finding [SC2086]'

all_sc_stub 0
out="$(unset CI; ORCH_TEST_ONLY='^isolation$' VERSION_BASE=9.9.9 PATH="$all_bin" "$all_bash" "$all_dir/all.sh" 2>&1)"; st=$?
assert_status "exits non-zero when a suite failed" "$st" 1
assert_eq "runs every suite after the first one fails" "$(wc -l <"$all_dir/log" | tr -d ' ')" "3"
assert_eq "runs the suites in order" "$(cut -d' ' -f1 "$all_dir/log" | tr '\n' ' ')" \
  "orch_test.sh hooks_test.sh docs_lint.sh "
assert_eq "unsets ORCH_TEST_ONLY for every suite" "$(grep -c 'only=unset' "$all_dir/log")" "3"
assert_eq "sets ORCH_TEST_QUIET=1 for every suite" "$(grep -c 'quiet=1 ' "$all_dir/log")" "3"
assert_eq "passes VERSION_BASE through to every suite" "$(grep -c 'base=9.9.9$' "$all_dir/log")" "3"
assert_contains "prints a suite's FAIL lines with their detail lines" "$out" \
  "$(printf '  FAIL a stub failure\n     its detail line\n  FAIL another failure\n     its own detail')"
assert_eq "prints one summary line per suite" \
  "$(printf '%s\n' "$out" | grep -E '^[a-z_]+\.sh: [0-9]+ passed')" \
  "$(printf 'orch_test.sh: 2 passed, 2 failed\nhooks_test.sh: 7 passed, 0 failed\ndocs_lint.sh: 7 passed, 0 failed')"
assert_eq "prints no section header" "$(printf '%s\n' "$out" | grep -c 'a section header')" "0"
assert_eq "still prints the shellcheck summary after a failing suite" \
  "$(printf '%s\n' "$out" | tail -n 1)" "shellcheck: 0 findings"
assert_eq "runs shellcheck at warning severity in gcc format on every shell file" \
  "$(cat "$all_root/sc_args" 2>/dev/null)" \
  "-S warning -f gcc scripts/lint_me.sh scripts/test/all.sh scripts/test/docs_lint.sh scripts/test/hooks_test.sh scripts/test/lint_me.sh scripts/test/orch_test.sh"

rm -f "$all_dir/log"
sed -i.bak 's/; exit 1$//; s/2 failed/0 failed/; /FAIL/d' "$all_dir/orch_test.sh"
rm -f "$all_dir/orch_test.sh.bak"
out="$(unset CI; VERSION_BASE='' PATH="$all_bin" "$all_bash" "$all_dir/all.sh" 2>&1)"; st=$?
assert_status "exits 0 when every suite passed and shellcheck is clean" "$st" 0
assert_eq "passes an empty VERSION_BASE through as set" "$(grep -c 'base=$' "$all_dir/log")" "3"
assert_eq "prints shellcheck: 0 findings when shellcheck is clean" \
  "$(printf '%s\n' "$out" | tail -n 1)" "shellcheck: 0 findings"

rm -f "$all_dir/log"
all_sc_stub 1 "$all_finding1" "$all_finding2"
out="$(unset CI VERSION_BASE; PATH="$all_bin" "$all_bash" "$all_dir/all.sh" 2>&1)"; st=$?
assert_eq "leaves an unset VERSION_BASE unset" "$(grep -c 'base=unset$' "$all_dir/log")" "3"
assert_eq "prints no FAIL line when every suite passed" "$(printf '%s\n' "$out" | grep -c FAIL)" "0"
assert_status "exits non-zero on a shellcheck finding" "$st" 1
assert_contains "prints each finding, then shellcheck: N findings" "$out" \
  "$(printf '%s\n%s\nshellcheck: 2 findings' "$all_finding1" "$all_finding2")"
assert_eq "a finding still lets every suite's summary print first" \
  "$(printf '%s\n' "$out" | grep -E '^[a-z_]+\.sh: ')" \
  "$(printf 'orch_test.sh: 2 passed, 0 failed\nhooks_test.sh: 7 passed, 0 failed\ndocs_lint.sh: 7 passed, 0 failed')"

all_sc_stub 2
sed -i.bak '/^exit 2$/i echo "a bad .shellcheckrc" >&2' "$all_bin/shellcheck"
out="$(unset CI; PATH="$all_bin" "$all_bash" "$all_dir/all.sh" 2>&1)"; st=$?
assert_status "exits non-zero when shellcheck fails with no finding" "$st" 1
assert_contains "prints shellcheck's output, then its exit status" "$out" \
  "$(printf 'a bad .shellcheckrc\nshellcheck: failed (exit 2)')"

rm -f "$all_bin/shellcheck" "$all_bin/shellcheck.bak"
out="$(unset CI; PATH="$all_bin" "$all_bash" "$all_dir/all.sh" 2>&1)"; st=$?
assert_eq "says shellcheck was skipped when it is not installed" \
  "$(printf '%s\n' "$out" | tail -n 1)" "shellcheck: not installed - skipped"
assert_status "a missing shellcheck does not fail the run outside CI" "$st" 0
out="$(CI=true PATH="$all_bin" "$all_bash" "$all_dir/all.sh" 2>&1)"; st=$?
assert_status "a missing shellcheck fails the run in CI" "$st" 1
assert_eq "still says shellcheck was skipped in CI" \
  "$(printf '%s\n' "$out" | tail -n 1)" "shellcheck: not installed - skipped"
rm -rf "$all_root"

# >>> summary
echo
if [ "$SKIP" -gt 0 ]; then
  echo "$PASS passed, $FAIL failed, $SKIP skipped"
else
  echo "$PASS passed, $FAIL failed"
fi
[ "$FAIL" -eq 0 ]
