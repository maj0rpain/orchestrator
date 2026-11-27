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

# has_line <text> <line>: yes when <line> is one whole line of <text>, else no.
has_line() {
  case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) echo yes ;; *) echo no ;; esac
}

# adapter_stood_in <definitions> <cmd>...: runs <cmd> with ORCH_GH_ADAPTER at a
# stand-in adapter, a temp file that sources the gh adapter fake and then holds
# <definitions> (bash text) verbatim. The file is removed whatever <cmd>'s
# status, and that status is returned. When the mktemp or the write fails,
# nothing runs, any file made is removed, and it returns non-zero.
adapter_stood_in() {
  local defs="$1" adapter st
  shift
  adapter="$(mktemp)" || return 1
  printf 'source %q\n%s\n' "$GH_ADAPTER_FAKE" "$defs" >"$adapter" || { rm -f "$adapter"; return 1; }
  ORCH_GH_ADAPTER="$adapter" "$@"; st=$?
  rm -f "$adapter"
  return "$st"
}

# counted_adapter_run <log> <definitions> <cmd>...: empties <log>, then runs
# <cmd> through adapter_stood_in with COUNT_LOG set to <log>, so <definitions>
# can append a line per adapter read to "$COUNT_LOG". Returns <cmd>'s status.
counted_adapter_run() {
  local log="$1" defs="$2"
  shift 2
  : >"$log"
  COUNT_LOG="$log" adapter_stood_in "$defs" "$@"
}

# counting_defs <adapter-fn> <tag>: definitions that wrap the fake's
# <adapter-fn> so each call appends "<tag> <first-arg>" to "$COUNT_LOG" before
# the fake answers (empty when it gets no argument). Join several with writeln
# for counted_adapter_run.
counting_defs() {
  writeln \
    "eval \"fake_$1_read() \$(declare -f $1 | tail -n +2)\"" \
    "$1() { printf '%s %s\\n' '$2' \"\${1-}\" >>\"\$COUNT_LOG\"; fake_$1_read \"\$@\"; }"
}

# default_reads_run <log> <cmd>...: runs <cmd> with the adapter's default-branch
# read appending a line to <log> per call, so log_count <log> is how many times
# <cmd> asked GitHub for it. It seeds nothing: the caller sets the fake's reply.
default_reads_run() {
  counted_adapter_run "$1" "$(counting_defs adapter_repo_default_branch branch)" "${@:2}"
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

# pr_body_complete <file>: writes to <file> a PR body carrying every piece pr
# open and pr publish require (#1387) - ## Summary, ## Evidence, and ## Merge
# Danger with its **Door:** and **Blast Radius:** lines - its Summary holding
# 'Implements the thing.' and 'Some detail.'.
pr_body_complete() {
  writeln '## Summary' '' 'Implements the thing.' '' 'Some detail.' '' \
    '## Evidence' '' 'make test - pass' '' \
    '## Merge Danger' '' '**Door:** two-way' '**Blast Radius:** the widget module' >"$1"
}

# origin_rejects <bare>: installs a pre-receive hook in the bare origin at
# <bare> that rejects every push, so a push fails with git's real rejection
# stderr, offline (#1300). Removing <bare>/hooks/pre-receive lifts it.
origin_rejects() {
  local hook="$1/hooks/pre-receive"
  printf '%s\n' '#!/bin/sh' 'echo "rejected by test hook" >&2' 'exit 1' >"$hook"
  chmod +x "$hook"
}

# new_repo_with_origin [branch]: new_repo, plus tracking refs for its origin:
# origin/<branch> (default: the checked-out branch) set to HEAD, and
# origin/HEAD pointing at it. Call it in the current shell, never inside $(...):
# new_repo cd's.
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

# col0_names <file>: the names of the functions defined at column 0 of <file>.
col0_names() {
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' "$1" | sed 's/[[:space:]]*()$//'
}

# clash_commits <clash-branch>: from the current branch (or detached HEAD),
# creates <clash-branch> with clash.txt holding its name, and commits
# clash.txt holding "<clash-branch> base" on the starting point, leaving the
# checkout there.
clash_commits() {
  local base
  base="$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)"
  git checkout -q -b "$1"
  echo "$1" >clash.txt && git add clash.txt && git commit -qm "$1"
  git checkout -q "$base"
  echo "$1 base" >clash.txt && git add clash.txt && git commit -qm "$1 base"
}

# on_disk <path>: present or absent, whether anything is at <path>.
on_disk() { if [ -e "$1" ]; then echo present; else echo absent; fi; }
# branch_presence <ref>: present or gone, whether the branch <ref> exists.
branch_presence() { if git rev-parse --verify --quiet "$1" >/dev/null 2>&1; then echo present; else echo gone; fi; }
# exclude_count <line>: how many times <line> appears whole in the current
# clone's shared exclude file, the one every checkout of it reads.
exclude_count() { grep -cxF "$1" "$(git rev-parse --git-common-dir)/info/exclude" || true; }

writeln() { printf '%s\n' "$@"; }
# write_ssh_stub <command run for github-work> <exit status>: an ssh at
# "$ssh_stub_dir", for a PATH ahead of the suite-wide identity one, that runs
# <command> when its last argument is github-work, then exits with <exit status>
# on every call unless <command> exits first, and records every call in
# "$ssh_calls". The dir is made once per shell. In a parallel run each section,
# a process of its own, gets its own dir. In a serial run (ORCH_TEST_JOBS=1)
# every section runs in one shell and they share it, which is safe because each
# write_ssh_stub call overwrites the stub and a section that counts calls
# clears the calls file first.
write_ssh_stub() {
  if [ -z "${ssh_stub_dir:-}" ]; then
    ssh_stub_dir="$(mktemp -d)"
    ssh_calls="$ssh_stub_dir/calls"; : >"$ssh_calls"
  fi
  cat >"$ssh_stub_dir/ssh" <<SSH
#!/usr/bin/env bash
echo "\$*" >>"$ssh_calls"
for h in "\$@"; do :; done
if [ "\$h" = github-work ]; then $1; fi
exit $2
SSH
  chmod +x "$ssh_stub_dir/ssh"
}
# fails_bin lives in the failing-command fixture, scripts/test/fails.sh.

# git_fails_bin <pattern>: a fails_bin for git.
git_fails_bin() { fails_bin git "$1"; }

# worktree_list_fails_bin: a git_fails_bin where git worktree list fails and
# nothing else does, so it fails every checkout_parse reader.
worktree_list_fails_bin() { git_fails_bin '" worktree list "*'; }
# path_without <cmd>: PATH with no <cmd> on it, printed: each directory holding
# one is replaced by a new directory linking every other command there.
path_without() {
  local dir links k=0 kept="" f
  local -a dirs
  IFS=: read -r -a dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    k=$((k + 1))
    if [ -e "$dir/$1" ]; then
      links="$(mktemp -d)"
      for f in "$dir"/*; do
        [ "${f##*/}" = "$1" ] || ln -s "$f" "$links/${f##*/}"
      done
      dir="$links"
    fi
    kept="${kept:+$kept:}$dir"
  done
  printf '%s\n' "$kept"
}
# break_index / restore_index [<checkout>]: make a checkout's working tree
# (default: the current directory) unreadable - git status fails on a garbage
# index - and put the index back. They return non-zero, touching no file, when
# the checkout's git directory cannot be resolved.
break_index() {
  local idx
  idx="$(git -C "${1:-.}" rev-parse --absolute-git-dir)/index" || return 1
  cp "$idx" "$idx.bak" && echo garbage >"$idx"
}
restore_index() {
  local idx
  idx="$(git -C "${1:-.}" rev-parse --absolute-git-dir)/index" || return 1
  mv "$idx.bak" "$idx"
}
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
# rl_event <5h status> <5h utilization> <5h reset> <7d status> <7d utilization>
# <7d reset>: a rate_limit_event line.
rl_event() {
  printf '{"type":"rate_limit_event","rate_limit_info":{"status":"%s","resetsAt":%s,"rateLimitType":"seven_day","utilization":%s,"unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":%s,"status":"%s"},"seven_day":{"utilization":%s,"resetsAt":%s,"status":"%s"}}}}\n' \
    "$4" "$6" "$5" "$2" "$3" "$1" "$5" "$6" "$4"
}
# ndjson_with <line>: a session log of NDJSON lines with <line> as a plain text
# line among them, and a rate_limit_event that rejects nothing.
ndjson_with() {
  printf '%s\n' '{"type":"system","subtype":"init"}' "$(rl_event allowed 0.1 4102444800 allowed 0.1 4102444800)" \
    "$1" '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
}
# live_orch <function> [args...]: calls the function in a background shell that
# sourced orch.sh, from the current directory, and keeps that shell alive, so a
# record the function writes names a running process. Sets LIVE_PID; live_stop
# kills the shell, leaving the record naming a process that is gone.
live_orch() {
  local fifo line
  fifo="$(mktemp -u)"
  mkfifo "$fifo"
  # The child opens the fifo's write end first, so its death before the ready
  # line ends the read with EOF; it closes the end before its long sleep.
  bash -c 'exec 9>"$2"; source "$1"; shift 2; "$@"; echo ready >&9; exec 9>&-; exec sleep 600' _ "$ORCH" "$fifo" "$@" &
  LIVE_PID=$!
  line="$(fifo_read_line 60 "live_orch ready read ($fifo)" "$fifo")"
  rm -f "$fifo"
}
live_stop() { kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null; return 0; }
# marker_of <kind> [<arg>] [retired]: the marked-comment module's first line for
# the kind, so a seeded comment is written as the module writes it.
marker_of() { sourced_orch marked_comment_write "$@"; }

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

# state_truncate [bytes]: cuts the checkout's state file to its first <bytes>
# bytes (40 by default), leaving a file that does not parse as JSON. The cut
# goes through a temp file beside it, moved back over it.
state_truncate() {
  local file
  file="$(flow_state_file "$(git rev-parse --show-toplevel)")"
  head -c "${1:-40}" "$file" >"$file.cut" && mv "$file.cut" "$file"
}

# assert_state_unreadable <label> <want-status> <out> <st>: asserts a command
# run on a truncated state.json (see state_truncate) exited <st> as
# <want-status>, printed the shared unreadable line in <out>, and leaked no jq
# parse error. The one place tests spell that line.
assert_state_unreadable() {
  assert_status "$1 exits $2" "$4" "$2"
  assert_contains "$1 prints the unreadable line" "$3" \
    "orch: state.json cannot be read - run orch.sh doctor --flow"
  assert_not_contains "$1 leaks no jq text" "$3" "parse error"
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

# complete_handoff <file>: a complete handoff at <file>, holding every section
# the Handoff module's phase table requires for its name - read through
# handoff_required in a shell that sourced orch.sh, so the fixture cannot drift
# from the validator - each with a placeholder body, plus Host fallbacks
# whatever the state says. When handoff_required fails, on a name the table
# does not hold, it fails and writes no file.
complete_handoff() {
  local headings heading
  headings="$(sourced_orch handoff_required "$(basename "$1")")" || return 1
  grep -qxF '## Host fallbacks' <<<"$headings" || headings="$headings"$'\n''## Host fallbacks'
  while IFS= read -r heading; do
    writeln "$heading" "Placeholder for ${heading#\#\# }." ''
  done <<<"$headings" >"$1"
}
# plan_file <file> [block]: a complete plan handoff, with the `## Autopilot`
# block's body when one is given.
plan_file() {
  complete_handoff "$1" || return 1
  [ -z "${2:-}" ] || printf '\n## Autopilot\n\n%s\n' "$2" >>"$1"
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

# A repo where every --env check passes, so a test can break exactly one thing
# and attribute the result to it.
healthy_repo() {
  new_repo >/dev/null
  git remote set-url origin https://github.com/acme/widgets.git
  labels_doc docs/agents/triage-labels.md
  # The verification lines check warns of a repo naming no full verification.
  writeln 'Full verification: true test' >CLAUDE.md
  git add CLAUDE.md && git commit -qm 'instructions'
  printf '%s\n' ".orchestrator/" ".scratch/" >>.git/info/exclude
  gh_fixture
  export CLAUDE_PLUGIN_ROOT="$PWD"
  # A throwaway HOME, so no skill store on the machine running the tests
  # reaches doctor's checks.
  seeded_home
}


# fresh_flow <slug>: a section's own starting point - a healthy_repo with a
# flow named <slug> just started in it, at the spec phase, cwd inside it. A
# section that needs a later phase arranges it with state_fixture, or
# review_flow for the review phase.
fresh_flow() { healthy_repo; "$ORCH" init "$1" >/dev/null; }

# fake_flow <slug>: a section's starting point on the store-backed GitHub fake
# - a bare new_repo, fake_github, and a flow named <slug> just started in it,
# cwd inside it. Unlike fresh_flow it brings no healthy_repo environment; the
# section still ends with its own restore_suite_env.
fake_flow() { new_repo >/dev/null; fake_github; "$ORCH" init "$1" >/dev/null; }

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

# fake_pr_head <n> <sha> [commit...]: seeds PR #n's head SHA and its commits,
# oldest first - given none, the head alone, or none when the head is empty.
fake_pr_head() {
  local d="$ORCH_GH_FAKE_STORE/prs/$1"
  printf '%s\n' "$2" >"$d/head_oid"
  shift 2
  rm -f "$d/commits"
  [ $# -eq 0 ] || printf '%s\n' "$@" >"$d/commits"
}

# iso_of <epoch>: epoch seconds as a UTC timestamp, GNU or BSD date.
iso_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# pause_near <file> <seconds>: "near" when <file> holds now + <seconds>, +-10s;
# "unreadable" when it holds no timestamp, else "far: <got> vs <want>".
pause_near() {
  local want got iso
  want="$(( $(date +%s) + $2 ))"; iso="$(cat "$1" 2>/dev/null)"
  got="$(date -u -d "$iso" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$iso" +%s 2>/dev/null)" || { echo unreadable; return; }
  if [ "$(( got - want ))" -ge -10 ] && [ "$(( got - want ))" -le 10 ]; then echo near; else echo "far: $got vs $want"; fi
}

# iso_ago <age-seconds>: the UTC timestamp <age-seconds> before the current
# time.
iso_ago() { iso_of "$(( $(date -u +%s) - $1 ))"; }

# fake_issue_created <n> <age-seconds>: issue #n created <age-seconds> ago, by
# the current time.
fake_issue_created() {
  iso_ago "$2" >"$ORCH_GH_FAKE_STORE/issues/$1/created_at"
}

# fake_pr_merged <n> <age-seconds> [issue...]: PR #n merged <age-seconds> ago,
# by the current time, its closingIssuesReferences the issues given.
fake_pr_merged() {
  local n="$1" age="$2" d
  shift 2
  d="$ORCH_GH_FAKE_STORE/prs/$n"
  iso_ago "$age" >"$d/merged_at"
  : >"$d/closing"
  for i in "$@"; do printf '%s\n' "$i" >>"$d/closing"; done
}

# fake_comment_seed <comments-dir> <author> <created-at> <body> [<association>]:
# the body, byte
# for byte, appended as a comment by the fake's own fake_comment_append, so the
# store's comment layout has one writer.
fake_comment_seed() {
  printf '%s' "$4" |
    bash -c 'source "$1"; fake_comment_append "$2" "$3" "$4" /dev/stdin "$5"' \
      _ "$GH_ADAPTER_FAKE" "$1" "$2" "$3" "${5-}"
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
  fake_issue_relabel "${d##*/}" "$@"
}

# fake_issue_title <n> <title>: seeds issue #n's title.
fake_issue_title() { printf '%s\n' "$2" >"$ORCH_GH_FAKE_STORE/issues/$1/title"; }
# fake_issue_authorship <n> <author> <association> [<editor> [<renamer>]]: sets
# issue #n's author and association, the last editor of its body and the latest
# renamer of its title - the last two empty (never edited, never renamed) unless
# given. The issue is kept as it is otherwise.
fake_issue_authorship() {
  local d="$ORCH_GH_FAKE_STORE/issues/$1"
  printf '%s\n' "$2" >"$d/author"
  printf '%s\n' "$3" >"$d/association"
  printf '%s\n' "${4:-}" >"$d/editor"
  printf '%s\n' "${5:-}" >"$d/renamer"
}

# fake_issue_relabel <n> <label>...: sets issue #n's labels; its state, title,
# body and comments are kept.
fake_issue_relabel() {
  local n="$1"
  shift
  : >"$ORCH_GH_FAKE_STORE/issues/$n/labels"
  [ $# -eq 0 ] || printf '%s\n' "$@" >"$ORCH_GH_FAKE_STORE/issues/$n/labels"
}

# fake_comments_clear <n>: issue #n holds no comments.
fake_comments_clear() { rm -rf "$ORCH_GH_FAKE_STORE/issues/$1/comments"; }

# orch_no_repo <args>...: runs orch.sh with <args> in a fresh origin-less copy
# of the current directory (the section's test repo), over the fixture gh the
# caller made with gh_fixture; orch.sh's output and status pass through. Fails,
# running nothing, when no gh_fixture was made.
orch_no_repo() {
  [ -n "${GH_FIXTURE:-}" ] || { echo "orch_no_repo: make a gh_fixture first" >&2; return 1; }
  (cd "$(mktemp -d)" && cp -R "$OLDPWD/." . && git remote remove origin \
    && PATH="$GH_FIXTURE/bin:$PATH" ORCH_GH_ADAPTER='' "$ORCH" "$@")
}

# fake_comment <n> <author> <created-at> <body> [<association>]: seeds a comment
# on issue #n, after any it has; its association is OWNER unless given.
fake_comment() { fake_comment_seed "$ORCH_GH_FAKE_STORE/issues/$1/comments" "$2" "$3" "$4" "${5-}"; }

# handoff_missing_msg <mode> <issue> <name> [<hint>]: the mode's message for a
# missing handoff <name>; the hint, when given, is the "post it with handoff
# post <hint>" (comment) or "write it <hint>" (file) tail.
handoff_missing_msg() {
  if [ "$1" = comment ]; then
    printf 'orch: issue #%s has no %s handoff comment%s' "$2" "$3" "${4:+ - post it with handoff post $4}"
  else
    printf 'orch: handoff not found: %s/.orchestrator/handoff/%s.md%s' "$PWD" "$3" "${4:+ - write it $4}"
  fi
}

# handoff_doctor_missing_msg <mode> <issue> <name>: doctor's finding for the
# missing handoff <name>.
handoff_doctor_missing_msg() {
  if [ "$1" = comment ]; then
    printf 'handoff %s comment is missing on issue #%s - the phase that writes it has already run.' "$3" "$2"
  else
    printf 'handoff %s.md is missing - the phase that writes it has already run.' "$3"
  fi
}

# Issue #n read back from the store: its state (OPEN or CLOSED), labels
# (sorted, space-separated, one trailing space) and the bodies of its comments,
# in order, one blank line between.
fake_state_of()  { cat "$ORCH_GH_FAKE_STORE/issues/$1/state" 2>/dev/null; }
fake_labels_of() { LC_ALL=C sort "$ORCH_GH_FAKE_STORE/issues/$1/labels" 2>/dev/null | tr '\n' ' '; }
fake_comments_of() { fake_comment_bodies "$ORCH_GH_FAKE_STORE/issues/$1/comments"; }

# fake_claim_seed <issue> [host] [pid] [started] [phase]: seeds a claim on the
# issue, held by this host with pid 1, a start long past and the spec phase
# unless given. A claim
# is a ref on origin; the fake keeps it as a line in the store.
fake_claim_seed() {
  mkdir -p "$ORCH_GH_FAKE_STORE/claims"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "${2:-$(hostname)}" "${3:-1}" "${5:-spec}" "${4:-2026-01-01T00:00:00Z}" \
    >"$ORCH_GH_FAKE_STORE/claims/$1"
}

# fake_claim_held <issue>: held or free, whether the store holds a claim on it.
fake_claim_held() { [ -f "$ORCH_GH_FAKE_STORE/claims/$1" ] && echo held || echo free; }

# tick_fixture: a clone of a bare origin, the gh fake, the permission mode set,
# claude on PATH and the fake session launcher in place. The launcher records
# argv, ORCH_AUTOPILOT, its directory and every issue's labels, then writes the
# output and exits as seeded: $launcher_dir/out and /exit, and, in /release, the
# issues whose claims it releases before exiting.
tick_fixture() {
  sc_clone
  fake_github
  git config orchestrator.autopilot.permission-mode acceptEdits
  launcher_dir="$(mktemp -d)"
  cat >"$launcher_dir/launcher" <<LAUNCHER
#!/bin/sh
{
  printf 'argv:%s\n' "\$*"
  for a in "\$@"; do printf 'arg:%s\n' "\$a"; done
  printf 'autopilot:%s\n' "\${ORCH_AUTOPILOT:-}"
  printf 'explore-plan:%s\n' "\${CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS:-}"
  printf 'bg-wait:%s\n' "\${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-}"
  printf 'dir:%s\n' "\$(pwd -P)"
  for d in "$ORCH_GH_FAKE_STORE"/issues/*/; do
    printf 'labels:%s:%s\n' "\$(basename "\$d")" "\$(LC_ALL=C sort "\$d/labels" | tr '\n' ' ')"
  done
} >>"$launcher_dir/calls"
[ -f "$launcher_dir/out" ] && cat "$launcher_dir/out"
for n in \$(cat "$launcher_dir/release" 2>/dev/null); do rm -f "$ORCH_GH_FAKE_STORE/claims/\$n"; done
exit "\$(cat "$launcher_dir/exit" 2>/dev/null || echo 0)"
LAUNCHER
  chmod +x "$launcher_dir/launcher"
  export ORCH_AUTOPILOT_LAUNCHER="$launcher_dir/launcher" ORCH_AUTOPILOT_FOREGROUND=1
  tickbin="$(mktemp -d)"
  printf '#!/bin/sh\nexit 0\n' >"$tickbin/claude"; chmod +x "$tickbin/claude"
  PATH="$tickbin:$PATH"
}

# dir_snapshot <dir>: every file under <dir>, by its path from <dir>, with its
# checksum, in a fixed order - for a byte-identical comparison with another
# snapshot of the same directory.
dir_snapshot() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r cksum); }

# fake_snapshot: a digest of the whole store, so a test asserts a read-only
# command left it as it was. The read-side files are reads, never writes, so
# they are left out: comment_reads, each PR's evidence_reads, each PR's
# checks/<n>/reads and each checks/<n>/<scope>.n cursor. The fail/ and lag/
# countdowns stay in: a test seeds them, and any operation consumes them.
fake_snapshot() { dir_snapshot "$ORCH_GH_FAKE_STORE" | sed -E '/ \.\/(comment_reads|prs\/[^\/]+\/evidence_reads|checks\/[^\/]+\/(reads|[^\/]+\.n))$/d'; }

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

# fake_pr_comment <n> <author> <created-at> <body> [association]: seeds a
# comment on PR #n, after any it has; the association defaults to OWNER.
fake_pr_comment() { fake_comment_seed "$ORCH_GH_FAKE_STORE/prs/$1/comments" "$2" "$3" "$4" "${5-}"; }

# fake_pr_draft <n>: seeds PR #n as a draft.
fake_pr_draft() { : >"$ORCH_GH_FAKE_STORE/prs/$1/draft"; }

# fake_pr_cross <n> [flag]: seeds PR #n's cross-repository flag - a fork PR
# (true) by default; the fake prints the flag as given, so any other value
# seeds one gh would never print. A PR never seeded is same-repo (false).
fake_pr_cross() { printf '%s\n' "${2:-true}" >"$ORCH_GH_FAKE_STORE/prs/$1/cross_repository"; }

# fake_next_pr <n>: the number the next PR opened takes.
fake_next_pr() { printf '%s\n' "$1" >"$ORCH_GH_FAKE_STORE/next_pr"; }

# PR #n read back from the store: its base branch and body.
fake_pr_base_of()  { cat "$ORCH_GH_FAKE_STORE/prs/$1/base" 2>/dev/null; }
fake_pr_body_of()  { cat "$ORCH_GH_FAKE_STORE/prs/$1/body" 2>/dev/null; }

# fake_label <name> <colour> <description>: seeds a label the repo already
# has. An unseeded store has no labels.
fake_label() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$ORCH_GH_FAKE_STORE/labels"; }

# fake_label_names <name>...: the repo's labels are exactly the names given,
# each with no colour or description - none given, the repo has no labels.
fake_label_names() {
  : >"$ORCH_GH_FAKE_STORE/labels"
  [ $# -eq 0 ] || printf '%s\t\t\n' "$@" >"$ORCH_GH_FAKE_STORE/labels"
}

# fake_labels: the store's labels read back, sorted, one per line as
# "<name><TAB><colour><TAB><description>".
fake_labels() { LC_ALL=C sort "$ORCH_GH_FAKE_STORE/labels" 2>/dev/null || true; }

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

# fake_comment_reads: how many comment-list reads (adapter_issue_comments)
# the fake has answered or refused - 0 for none.
fake_comment_reads() { log_count "$ORCH_GH_FAKE_STORE/comment_reads"; }

# The seeded two-line gh stderr whose first line a death must carry.
GH_502=$'HTTP 502: Bad Gateway\nsecond line'

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

# fake_lag <operation> <n> [stale]: the next n calls of the named operation
# answer stale, as GitHub does for a moment after a write; the call after them
# is current again. An operation that reads answers the stale text given, in
# its own documented shape - or, given none, an empty one.
fake_lag() {
  mkdir -p "$ORCH_GH_FAKE_STORE/lag"
  printf '%s\n' "$2" >"$ORCH_GH_FAKE_STORE/lag/$1"
  if [ $# -ge 3 ]; then printf '%s\n' "$3" >"$ORCH_GH_FAKE_STORE/lag/$1.stale"; fi
}

# fake_checks <n> <required|all> <answer>...: scripts PR #n's checks for the
# scope, answered one per call, the last repeating: green, failing (build
# fails, Actions run 4242; lint passes), cancel (build cancelled, run 5150),
# external (a failing outside-CI check, ext-ci, ahead of build failing in run
# 4242), tworuns (build run 4242, test run 4343), onerun (build and test both
# in run 4242), mixed (build run 4242, then failing ext-ci), comma (one
# failing check named `build (linux, x64)`), pending, none (no checks
# reported) or boom (a connection error). An unscripted scope has no checks.
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
# fake_online: GitHub reachable and authenticated again.
fake_online()  { rm -f "$ORCH_GH_FAKE_STORE/offline" "$ORCH_GH_FAKE_STORE/noauth" "$ORCH_GH_FAKE_STORE/ratelimit"; }
# fake_quota <pool> <remaining> <limit> <reset-epoch>: the pool's line in the
# rate_limit read's answer; the other pool, if unset, is no line at all.
fake_quota() { printf '%s\t%s\t%s\t%s\n' "$@" >>"$ORCH_GH_FAKE_STORE/quota"; }

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

# gh_calls: how many calls the fixture gh on PATH has answered or refused - 0
# for none. A behaviour test on the store-backed fake asserts it stays 0, so
# no command reached a gh subprocess.
gh_calls() { log_count "$GH_FIXTURE/env.log"; }

# orch.sh run with a PATH gh that fails - a fixture gh given no reply - for a
# repo whose origin GitHub cannot answer for (a local bare repo): default-branch
# settles on origin/HEAD, so a test using it pins that rather than leaving it to
# this machine's gh.
GH_FAILING="$(gh_fixture && printf '%s\n' "$GH_FIXTURE/bin")"
# orch_gh_failing <args>...: runs orch.sh with the failing fixture gh first
# on PATH.
orch_gh_failing() { PATH="$GH_FAILING:$PATH" "$ORCH" "$@"; }

# assert_loads_once <label> <cmd> [args...]: runs <cmd> with the load trace on
# and asserts the trace names no module twice, in the main shell or a subshell.
# The command's own status and output are not judged.
assert_loads_once() {
  local label="$1" load_trace
  shift
  load_trace="$(mktemp)"
  ORCH_LOAD_TRACE="$load_trace" "$@" >/dev/null 2>&1 || true
  assert_trace_loads_once "$label" "$load_trace"
  rm -f "$load_trace"
}
# assert_trace_loads_once <label> <trace file>: asserts a load trace, written by
# a run that had ORCH_LOAD_TRACE=<file> on, names no module twice.
assert_trace_loads_once() {
  assert_eq "$1: the load trace names no module twice" \
    "$(awk '{print $1}' "$2" | sort | uniq -d | tr '\n' ' ')" ""
}

# assert_trace_names_no <label> <trace file> <module>...: asserts a load trace,
# written by a run that had ORCH_LOAD_TRACE=<file> on, names none of the given
# modules - a module the run must not load at all.
assert_trace_names_no() {
  local label="$1" trace="$2" mod line n
  shift 2
  local -a lines=()
  mapfile -t lines <"$trace"
  for mod in "$@"; do
    n=0
    for line in "${lines[@]}"; do
      [ "${line%%[[:space:]]*}" = "$mod" ] && n=$((n + 1))
    done
    assert_eq "$label: the load trace names no $mod" "$n" "0"
  done
}

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

# tree_copy <subtree>: a copy of the real <subtree> of the plugin (a path
# under PLUGIN_ROOT, e.g. scripts/test/orch) in a fresh temp directory; prints
# the copy's path, which ends in the subtree's last component.
tree_copy() {
  local dir
  dir="$(mktemp -d)" || return 1
  cp -R "$PLUGIN_ROOT/$1" "$dir/" || return 1
  printf '%s\n' "$dir/${1##*/}"
}

# term_run <stdout file> <stderr file> <pid file>... -- <command>...: starts
# <command> in the background, its output to the two files (one shared open
# file, stderr merged into stdout, when both are the same path), polls (up to 20
# seconds) until every pid file has content, sends TERM to it, and waits. A pid
# file still empty at the limit is reported through bad, naming it; the TERM and
# the wait follow all the same. The command's own pid is the one TERMed, so a
# caller wanting a directory or an unset variable passes `env -u` or `bash -c
# 'cd ...; exec ...'` as the command. Sets term_st (its exit status) and
# term_secs (the seconds it took to return after the TERM).
term_run() {
  local out="$1" err="$2" pid pid_file tries=0 t0 all_written unwritten
  local -a pid_files=()
  shift 2
  while [ "$1" != -- ]; do pid_files+=("$1"); shift; done
  shift
  if [ "$out" = "$err" ]; then
    "$@" >"$out" 2>&1 &
  else
    "$@" >"$out" 2>"$err" &
  fi
  pid=$!
  while [ "$tries" -le 200 ]; do
    all_written=1
    unwritten=""
    for pid_file in "${pid_files[@]}"; do [ -s "$pid_file" ] || { all_written=0; unwritten+=" $pid_file"; }; done
    [ "$all_written" = 1 ] && break
    tries=$((tries + 1))
    sleep 0.1
  done
  if [ "$all_written" != 1 ]; then
    bad "term_run: a pid file stayed empty for the 20-second bound" "still empty:$unwritten"
  fi
  t0=$SECONDS
  kill -TERM "$pid"
  wait "$pid"; term_st=$?
  term_secs=$((SECONDS - t0))
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
