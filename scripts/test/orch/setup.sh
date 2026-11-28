# shellcheck shell=bash
# shellcheck disable=SC2034 # its assignments are read by the section files, linted apart
# The orch.sh suite's shared setup and summary, which scripts/test/orch_test.sh
# reads and evals; never run on its own. The shared setup runs from the
# `# >>> shared setup` line to the `# >>> summary` line, before any section; the
# summary runs from the `# >>> summary` line to the end of the file, after them.
# The `# ---` blocks inside the shared setup are setup, not sections.
# >>> shared setup

# The host signals doctor reads: the shell running the tests is often itself
# a Claude Code, Junie or Antigravity session. Each test names its host.
unset ORCHESTRATOR_HOST CLAUDECODE JUNIE_EXTENSION_ROOT JUNIE_SHIM_PATH \
  ANTIGRAVITY_AGENT ANTIGRAVITY_CONVERSATION_ID

# The caller's ORCH_* knobs: a suite started from an autopilot session exports
# ORCH_AUTOPILOT, ORCH_SH, ORCH_MODEL*, ORCH_EFFORT* and more. Every exported
# ORCH_* goes, by prefix, but ORCH_TEST_*, the suite's own knobs.
while IFS= read -r setup_var; do
  case "$setup_var" in ORCH_TEST_*) ;; ORCH_*) unset "$setup_var" ;; esac
done < <(compgen -e)
unset setup_var

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
# The suite HOME starts with the stub cache of the tree under test: a copy of
# the runner's seed (orch_test.sh), a file of its own, mode 600. No seed, or a
# copy that fails, leaves HOME without it.
# shellcheck disable=SC2154 # orch_seed_dir is set by orch_test.sh, the runner
if [ -n "${orch_seed_dir:-}" ]; then
  mkdir -p "$HOME/.cache/orchestrator" 2>/dev/null &&
    cp "$orch_seed_dir"/* "$HOME/.cache/orchestrator/" 2>/dev/null &&
    chmod 600 "$HOME/.cache/orchestrator"/* 2>/dev/null ||
    rm -rf "$HOME/.cache"
fi
# GH_REPO and GH_HOST go too: they are the gh variables orch.sh reads to resolve
# the Repo and its GitHub host, so a caller's value would change what orch.sh
# resolves in every section.
unset CLAUDE_PLUGIN_ROOT XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GH_REPO GH_HOST

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

# The suite-wide identity ssh stub, beside the guard: for `ssh -G -- <host>` it
# answers `hostname <host>`, reading the host as its last argument, so no
# section reads the machine's ssh config. A section needing an alias, a failure
# or a hostname-less answer puts its own stub ahead of it.
cat >"$GH_GUARD_DIR/bin/ssh" <<'SSH' || exit 1
#!/usr/bin/env bash
for h in "$@"; do :; done
echo "hostname $h"
SSH
chmod +x "$GH_GUARD_DIR/bin/ssh" || exit 1
PATH="$GH_GUARD_DIR/bin:$PATH"

# The environment every section starts from. healthy_repo exports HOME and
# CLAUDE_PLUGIN_ROOT and puts the fixture gh on PATH, so a section that calls
# it, or that calls gh_fixture itself, ends with restore_suite_env, leaving the
# next section the environment it had - fake_github's two exports and
# gh_fixture's GH_FIXTURE included. A section that exported more names passes
# them to restore_suite_env to unset them too.
SUITE_PATH="$PATH"
# No test waits out the real GitHub rate-limit backoff (60 and 300 seconds).
export ORCH_GH_LIMIT_WAIT=0
restore_suite_env() {
  unset CLAUDE_PLUGIN_ROOT GH_REPO GH_FIXTURE ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE "$@"
  HOME="$SUITE_HOME"; PATH="$SUITE_PATH"
}

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
# The CI classifier's verdict is its first line and the detail lines below it
# are not the assertion, so most of these read one line out of a captured $out.
assert_first_line() {
  assert_eq "$1" "$(printf '%s\n' "$2" | sed -n 1p)" "$3"
}

# log_count <log> [<tag>]: the lines in <log>, only those starting with "<tag> "
# when a tag is given; 0 for a <log> that is absent, in both forms.
log_count() {
  [ -f "$1" ] || { echo 0; return 0; }
  if [ -n "${2:-}" ]; then grep -c "^$2 " "$1" || true; else wc -l <"$1" | tr -d ' '; fi
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

# fresh_bare_origin <var>: make a fresh bare repo, point origin at it through
# bare_origin and store its path in <var>. Pushes nothing; each caller pushes
# the refs it needs. It prints nothing and is called in the current shell, never
# inside $(...): a command substitution would drop both the <var> assignment and
# bare_origin's GH_REPO export.
fresh_bare_origin() {
  local fbo_dir
  fbo_dir="$(mktemp -d)/origin.git"
  git init -q --bare "$fbo_dir"
  bare_origin "$fbo_dir"
  printf -v "$1" '%s' "$fbo_dir"
}

# col0_names <file>: the names of the functions defined at column 0 of <file>.
col0_names() {
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' "$1" | sed 's/[[:space:]]*()$//'
}

# on_disk <path>: present or absent, whether anything is at <path>.
on_disk() { if [ -e "$1" ]; then echo present; else echo absent; fi; }

writeln() { printf '%s\n' "$@"; }
# sourced_orch <function> [args...]: the function's output, called in a shell
# that sourced orch.sh, with its status. It sets ORCH_SOURCE_LAZY=1 before the
# source line, so the modules load on demand, as orch.sh does as a command and
# the suite's shells cost less to start; the eval form, `sourced_orch eval
# <code>`, loads every module, since code evaluated there may name or replace
# any function. Outside the loader's section file, the one place a test sets
# that variable.
sourced_orch() {
  local lazy=1
  [ "${1:-}" != eval ] || lazy=''
  bash -c '[ -z "$2" ] || ORCH_SOURCE_LAZY=1; source "$1"; shift 2; "$@"' _ "$ORCH" "$lazy" "$@"
}
# sourced_orch_script <script> [<arg>...]: runs <script> in a child bash that
# has sourced orch.sh with every module loaded, never on demand, as the script
# may redefine or name any function; <arg>... are its positional parameters
# $1....
sourced_orch_script() { local s="$1"; shift; bash -c 'source "$1"; shift; '"$s" _ "$ORCH" "$@"; }
# NTH_MAKE_FAKE: shell source, for sourced_orch_script, that makes
# temp_file_make fail on its PK_NTH-th call, counted in the file PK_COUNT, and
# work otherwise.
NTH_MAKE_FAKE='real_make=$(declare -f temp_file_make); temp_file_make() { local n=0; [ ! -e "$PK_COUNT" ] || n=$(<"$PK_COUNT"); n=$((n+1)); echo "$n" >"$PK_COUNT"; [ "$n" -ne "$PK_NTH" ] || return 1; eval "${real_make/temp_file_make/real_temp_file_make}"; real_temp_file_make "$@"; }; '

# The Flow state module, sourced so state_fixture writes through orch.sh's own
# writer: a fixture can then never store a value orch.sh would not write.
# shellcheck source=../../flow-state.sh
source "${ORCH%/*}/flow-state.sh" || {
  echo "orch_test.sh: cannot source the Flow state module" >&2; exit 1; }

# state_fixture <key> <value>: arrange state.json directly, for the keys
# `state set` refuses (phase, branch, pr, iteration, ...) - each owned by a
# command whose guard a test's setup has to step around. It writes through the
# Flow state module's coercing writer, flow_state_write, on the checkout's
# state file, and returns its status: a failed write leaves the file untouched
# and fails the arrangement.
state_fixture() {
  flow_state_write "$(flow_state_file "$(git rev-parse --show-toplevel)")" "$1" "$2"
}

# state_fixture_drop <key>...: deletes each named key from the checkout's
# state file in place, as a flow started by an older release lacks keys a
# fresh one seeds. Raw jq, not the Flow state module: the module has no delete
# operation - one only tests would use. The temp file sits beside the state
# file and replaces it only when jq succeeds.
state_fixture_drop() {
  local file tmp
  file="$(flow_state_file "$(git rev-parse --show-toplevel)")"
  tmp="$(mktemp "$file.XXXXXX")" || return
  jq 'reduce $ARGS.positional[] as $k (.; del(.[$k]))' "$file" --args "$@" >"$tmp" \
    && mv "$tmp" "$file" \
    || { rm -f "$tmp"; return 1; }
}

# SHELL_CODE_AWK: the one rule of what counts as code in a shell file, an awk
# function library an awk scanner includes by concatenation (awk
# "$SHELL_CODE_AWK"'...'), kept in its own file, scripts/test/shell_code.awk,
# which docs_lint.sh loads too; its header comment states the interface.
SHELL_CODE_AWK="$(<"$PLUGIN_ROOT/scripts/test/shell_code.awk")"
[ -n "$SHELL_CODE_AWK" ] || {
  echo "setup.sh: scripts/test/shell_code.awk is missing or empty" >&2; exit 1; }

# shell_code <file>...: prints the code view of the files, in order, one
# output line per input line - each line's comment dropped, so a comment-only
# line prints empty, and strings, substitutions and heredoc bodies kept whole.
# The entry point for a bash scanner; an awk scanner includes SHELL_CODE_AWK.
shell_code() {
  awk "$SHELL_CODE_AWK"'{ shell_code_line($0); print sc_code }' "$@"
}

# layer_calls <defs-file>... -- <code-file>...: the calls a layer check finds
# - each name defined at column 0 (col0_names) of the defs files that the code
# view (shell_code) of the code files names as a whole word, sorted and
# deduped. A name in a comment is no call; one in a quoted literal is. It
# filters nothing: a caller drops its own exemptions from the output.
layer_calls() {
  local defs=() code def name
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do defs+=("$1"); shift; done
  shift
  code="$(shell_code "$@")"
  for def in "${defs[@]}"; do col0_names "$def"; done | sort -u \
    | while IFS= read -r name; do
        if grep -qw -- "$name" <<<"$code"; then printf '%s\n' "$name"; fi
      done
}

# layer_upcalls <scripts-dir> <file> <skipped>...: the module functions an
# always-loaded file calls. <file> is a name under <scripts-dir>/orch/
# (common.sh or loader.sh); the defs are every file there but the skipped base
# names (e.g. gh.sh), and the output is layer_calls' for <file> alone.
layer_upcalls() {
  local dir="$1" file="$2" f base skipped defs=()
  shift 2
  for f in "$dir"/orch/*.sh; do
    base="${f##*/}"
    for skipped in "$@"; do [ "$base" = "$skipped" ] && continue 2; done
    defs+=("$f")
  done
  layer_calls "${defs[@]}" -- "$dir/orch/$file"
}

# --- a seeded HOME -----------------------------------------------------------

# seeded_home: gives the calling shell a throwaway HOME (exported) that starts
# with its own copy of the run's seed, the stub cache of the tree under test, so
# isolating a test costs no cache rebuild. Prints nothing and succeeds; a run
# with no seed, or a copy that fails, leaves the HOME without a cache file.
seeded_home() {
  HOME="$(mktemp -d)" || return 1
  export HOME
  # shellcheck disable=SC2154 # orch_seed_dir is set by orch_test.sh, the runner
  if [ -n "${orch_seed_dir:-}" ]; then
    mkdir -p "$HOME/.cache/orchestrator" 2>/dev/null &&
      cp "$orch_seed_dir"/* "$HOME/.cache/orchestrator/" 2>/dev/null &&
      chmod 600 "$HOME/.cache/orchestrator"/* 2>/dev/null ||
      rm -rf "$HOME/.cache"
  fi
  return 0
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
  fake_issue_relabel "${d##*/}" "$@"
}

# fake_issue_relabel <n> <label>...: sets issue #n's labels; its state, title,
# body and comments are kept.
fake_issue_relabel() {
  local n="$1"
  shift
  : >"$ORCH_GH_FAKE_STORE/issues/$n/labels"
  [ $# -eq 0 ] || printf '%s\n' "$@" >"$ORCH_GH_FAKE_STORE/issues/$n/labels"
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

# The seeded two-line gh stderr whose first line a death must carry.
GH_502=$'HTTP 502: Bad Gateway\nsecond line'

# fake_unfail: every operation fake_fail named succeeds again.
fake_unfail() { rm -rf "$ORCH_GH_FAKE_STORE/fail"; }

# --- the fixture gh (adapter contract tests, #280) ----------------------------
#
# gh_fixture: puts a fixture `gh` on PATH for the real adapter operations'
# contract tests, and leaves its directory in GH_FIXTURE. It holds no logic and
# parses no flags: each call looks its whole argv up among the replies gh_reply
# registered, and answers that reply's stdout, stderr and exit status. A reply
# lives in replies/<key>, keyed by its argv's checksum - the one formula, in the
# fixture's `key` script, which gh_reply calls too - so a call finds it with one
# direct lookup, and a cmp against the stored argv keeps the match exact, byte
# for byte. Registering an argv again replaces its reply: the later one wins. A
# checksum collision is a loud failure, not a second slot: the later
# registration takes the key, and the other argv answers 127. An argv with no
# reply fails, exit 127, naming the argv on stderr. Every
# call appends "GH_REPO=<repo> GH_HOST=<host> <argv>" to $GH_FIXTURE/env.log
# (<unset> for an unset one), so a test asserts which repo a call was pinned to.
# It also appends the name of every inherited variable starting REPO_ to
# $GH_FIXTURE/repo_vars.log: the repo memo is never exported, so it stays empty.
# Those two log lines are written once, by $GH_FIXTURE/log.sh, which the
# fixture gh sources; any other gh a section puts on PATH to stand in for the
# fixture gh, logging its calls to env.log as exists_gh's does, sources it too.
# A gh that keeps its own call log instead, such as limit_once_gh's, does not.
# A section that calls it ends with restore_suite_env GH_FIXTURE.
gh_fixture() {
  GH_FIXTURE="$(mktemp -d)" || return 1
  export GH_FIXTURE
  mkdir "$GH_FIXTURE/bin" "$GH_FIXTURE/replies"
  cat >"$GH_FIXTURE/key" <<'KEY'
#!/usr/bin/env bash
# key <argv...>: the replies directory name for that argv - the cksum of its
# arguments, NUL-terminated, its space turned into -.
printf '%s\0' "$@" | cksum | tr ' ' -
KEY
  cat >"$GH_FIXTURE/log.sh" <<LOG
# log.sh: sourced by a gh, it logs that gh's call; \$* is the gh's own argv.
printf 'GH_REPO=%s GH_HOST=%s %s\n' "\${GH_REPO-<unset>}" "\${GH_HOST-<unset>}" "\$*" >>"$GH_FIXTURE/env.log"
compgen -v REPO_ >>"$GH_FIXTURE/repo_vars.log"
LOG
  cat >"$GH_FIXTURE/bin/gh" <<'GH'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")/.." && pwd)"
. "$d/log.sh"
r="$d/replies/$("$d/key" "$@")"
if [ -f "$r/argv" ] && printf '%s\0' "$@" | cmp -s - "$r/argv"; then
  cat "$r/stdout"
  cat "$r/stderr" >&2
  exit "$(cat "$r/exit")"
fi
printf 'fixture gh: no reply for:' >&2
printf ' %q' "$@" >&2
printf '\n' >&2
exit 127
GH
  chmod +x "$GH_FIXTURE/key" "$GH_FIXTURE/bin/gh"
  PATH="$GH_FIXTURE/bin:$PATH"
}

# The missing-repo wording, built the way orch.sh builds REPO_MISSING,
# REPO_CAUSE and REPO_REMEDY - but spelled out here, never read from orch.sh,
# so a wording change there that the suite does not mirror still fails a test.
repo_missing="no GitHub repo to work on"
repo_cause="$repo_missing: origin is missing or not a GitHub owner/name"
repo_remedy="$repo_cause - set GH_REPO=<owner>/<repo>"

# tree_copy <subtree>: a copy of the real <subtree> of the plugin (a path
# under PLUGIN_ROOT, e.g. scripts/test/orch) in a fresh temp directory; prints
# the copy's path, which ends in the subtree's last component.
tree_copy() {
  local dir
  dir="$(mktemp -d)" || return 1
  cp -R "$PLUGIN_ROOT/$1" "$dir/" || return 1
  printf '%s\n' "$dir/${1##*/}"
}

# >>> summary
# Each call the real-gh guard logged is one FAIL naming it.
while IFS= read -r gh_guard_call; do
  bad "a section called the real gh" "$gh_guard_call"
done <"$GH_GUARD_LOG"
tally_read
# A parallel child or the sequential run's subshell hands its counts on to the
# runner, which prints them; orch_test.sh always sets the counts file.
# shellcheck disable=SC2154 # set by orch_test.sh, the runner that evals this file
echo "$PASS $FAIL $SKIP" >"$orch_counts_file"
[ "$FAIL" -eq 0 ]
