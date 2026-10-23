#!/usr/bin/env bash
#
# Tests for scripts/autopilot-container.sh, the autopilot container's
# entrypoint, run as a process and without Docker.
#
# Each case runs the entrypoint in a controlled environment: HOME at a fresh
# temp directory (so the global git config it writes is real and isolated), a
# fake `gh` first on PATH, a fake orch.sh named by ORCH_SH, and ORCH_CLONE_DIR
# at a temp directory. Real git reads the config back. Only gh and orch.sh are
# faked; the fake gh logs its arguments, answers `api user` with a fixed login
# and id, and makes `repo clone` create a git repo. The fake orch.sh logs its
# PID, working directory and arguments. Assertions are on what the run leaves:
# its exit status, stderr, the logs, the config and the clone directory.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$DIR/autopilot-container.sh"
PASS=0
FAIL=0

# ORCH_TEST_QUIET=1 hides the ok lines; the count, the FAIL lines and the
# summary still print.
ok()  { PASS=$((PASS + 1)); [ -n "${ORCH_TEST_QUIET:-}" ] || printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected nothing, got: $2"; fi; }
assert_status()   { if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "expected exit $3, got exit $2"; fi; }

root="$(mktemp -d)" || {
  echo "autopilot_container_test.sh: cannot create the suite's temp root" >&2; exit 1; }
export TMPDIR="$root"
remove_root() {
  local status=$?
  cd / || :
  rm -rf "$root"
  exit "$status"
}
trap remove_root EXIT
trap 'exit 130' INT TERM


fake_bin="$root/bin"
mkdir "$fake_bin"
cat >"$fake_bin/gh" <<'FAKE'
#!/usr/bin/env bash
# The fake gh: logs its arguments to $GH_LOG; $FAKE_GH_FAIL names the call
# ("setup-git", "api" or "clone") that fails.
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "auth setup-git") [ "${FAKE_GH_FAIL:-}" = setup-git ] && exit 1; exit 0 ;;
  "api user")
    [ "${FAKE_GH_FAIL:-}" = api ] && exit 1
    echo '{"login":"octo","id":4242}'
    exit 0 ;;
  "repo clone")
    if [ "${FAKE_GH_FAIL:-}" = clone ]; then
      mkdir -p "$4" && echo partial >"$4/leftover"
      exit 1
    fi
    git init -q "$4"
    exit 0 ;;
esac
exit 2
FAKE
cat >"$root/orch.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'pid=%s pwd=%s args=%s\n' "$$" "$PWD" "$*" >>"$ORCH_LOG"
FAKE
chmod +x "$fake_bin/gh"


# run_entry <VAR=value>...: runs the entrypoint in a fresh case directory with
# the valid base environment plus the arguments, each overriding the base; a
# VAR= with no value sets it empty, and `-VAR` removes it. Leaves $case_dir,
# $err (stderr), $st, $home, $clone (ORCH_CLONE_DIR unless an argument
# sets it), $gh_log and $orch_log. A case that needs the clone directory
# prepared sets $clone_prep to a command run before it.
run_entry() {
  case_dir="$(mktemp -d "$root/case.XXXXXX")"
  home="$case_dir/home"
  clone="$case_dir/clone"
  gh_log="$case_dir/gh.log"
  orch_log="$case_dir/orch.log"
  mkdir "$home"
  : >"$gh_log"
  : >"$orch_log"
  [ -z "${clone_prep:-}" ] || (eval "$clone_prep")
  local -a envs=(
    "PATH=$fake_bin:$PATH" "HOME=$home" "GH_LOG=$gh_log" "ORCH_LOG=$orch_log"
    "ORCH_SH=$root/orch.sh" "ORCH_CLONE_DIR=$clone" "FAKE_GH_FAIL=${FAKE_GH_FAIL:-}"
    "REPO=owner/name" "GH_TOKEN=tok" "CLAUDE_CODE_OAUTH_TOKEN=oauth"
  )
  local arg entry
  local -a final=()
  for entry in "${envs[@]}"; do
    for arg in "$@"; do
      [ "$arg" = "-${entry%%=*}" ] && continue 2
    done
    final+=("$entry")
  done
  for arg in "$@"; do
    case "$arg" in -*) ;; *) final+=("$arg") ;; esac
  done
  err="$(env -i "${final[@]}" bash "$ENTRY" 2>&1 >/dev/null)"
  st=$?
}
cfg() { HOME="$home" git config --global --get "$1"; }
cfg_set() { HOME="$home" git config --global --get "$1" >/dev/null 2>&1 && echo set || echo unset; }

# >>> checks

refusal() { # <label> <expected message> <VAR=value or -VAR>...
  local label="$1" want="$2"
  shift 2
  run_entry "$@"
  assert_status "$label: exits 1" "$st" 1
  assert_contains "$label: says so" "$err" "orch: $want"
  assert_empty "$label: gh never ran" "$(<"$gh_log")"
  assert_empty "$label: orch.sh never ran" "$(<"$orch_log")"
}
refusal "no REPO" "REPO is not set" -REPO
refusal "empty REPO" "REPO is not set" REPO=
refusal "no GH_TOKEN" "GH_TOKEN is not set" -GH_TOKEN
refusal "empty GH_TOKEN" "GH_TOKEN is not set" GH_TOKEN=
refusal "no Claude credential" "neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY" -CLAUDE_CODE_OAUTH_TOKEN
refusal "empty Claude credentials" "neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY" CLAUDE_CODE_OAUTH_TOKEN= ANTHROPIC_API_KEY=

run_entry -REPO -GH_TOKEN -CLAUDE_CODE_OAUTH_TOKEN
assert_status "all three missing: one exit 1" "$st" 1
assert_eq "all three missing: one line each" "$(printf '%s\n' "$err" | grep -c '^orch: ')" 3
assert_eq "all three missing: nothing but orch lines" "$(printf '%s\n' "$err" | grep -vc '^orch: ')" 0
assert_empty "all three missing: gh never ran" "$(<"$gh_log")"
assert_empty "all three missing: orch.sh never ran" "$(<"$orch_log")"

run_entry -CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY=key
assert_status "the API key alone is accepted" "$st" 0

# The one default run: the artefacts of later checks are asserted after it.
run_entry
default_gh_log="$gh_log" default_home="$home" default_clone="$clone"
assert_status "the OAuth token alone is accepted" "$st" 0
assert_contains "gh auth setup-git is called" "$(<"$gh_log")" "auth setup-git"

FAKE_GH_FAIL=setup-git run_entry
assert_status "a failing gh auth setup-git refuses" "$st" 1
assert_contains "a failing gh auth setup-git names its step" "$err" "orch: gh auth setup-git"
assert_empty "a failing gh auth setup-git leaves orch.sh unrun" "$(<"$orch_log")"

FAKE_GH_FAIL=api run_entry
assert_status "a failing gh api user refuses" "$st" 1
assert_contains "a failing gh api user names its step" "$err" "orch: commit identity"
assert_empty "a failing gh api user leaves orch.sh unrun" "$(<"$orch_log")"

clone_prep='mkdir -p "$clone" && echo x >"$clone/file"' run_entry
assert_status "a non-empty non-git clone dir refuses" "$st" 1
assert_contains "a non-empty non-git clone dir names its step" "$err" "orch: clone"
assert_contains "a non-empty non-git clone dir names the directory" "$err" "$clone"
assert_empty "a non-empty non-git clone dir leaves orch.sh unrun" "$(<"$orch_log")"
assert_eq "a non-empty non-git clone dir is left alone" "$(cat "$clone/file")" x
assert_eq "a non-empty non-git clone dir is not cloned over" "$(grep -c 'repo clone' "$gh_log")" 0


assert_eq "identity name falls back on the token owner's login" "$(HOME="$default_home" git config --global --get user.name)" octo
assert_eq "identity email falls back on the noreply address" "$(HOME="$default_home" git config --global --get user.email)" "4242+octo@users.noreply.github.com"
run_entry ORCH_GIT_NAME=Bot ORCH_GIT_EMAIL=bot@example.com
assert_eq "ORCH_GIT_NAME overrides the name" "$(cfg user.name)" Bot
assert_eq "ORCH_GIT_EMAIL overrides the email" "$(cfg user.email)" bot@example.com
assert_eq "both set: no gh api user call" "$(grep -c '^api user' "$gh_log")" 0
run_entry ORCH_GIT_NAME=Bot
assert_eq "ORCH_GIT_NAME alone: name overridden" "$(cfg user.name)" Bot
assert_eq "ORCH_GIT_NAME alone: email falls back" "$(cfg user.email)" "4242+octo@users.noreply.github.com"
run_entry ORCH_GIT_EMAIL=bot@example.com
assert_eq "ORCH_GIT_EMAIL alone: name falls back" "$(cfg user.name)" octo
assert_eq "ORCH_GIT_EMAIL alone: email overridden" "$(cfg user.email)" bot@example.com


run_entry ORCH_PERMISSION_MODE=acceptEdits ORCH_CAP=3 ORCH_HANDLE=maj0rpain ORCH_ROUNDS=5 ORCH_BUDGET=12
assert_eq "permission-mode is written" "$(cfg orchestrator.autopilot.permission-mode)" acceptEdits
assert_eq "cap is written" "$(cfg orchestrator.autopilot.cap)" 3
assert_eq "handle is written" "$(cfg orchestrator.autopilot.handle)" maj0rpain
assert_eq "rounds is written" "$(cfg orchestrator.autopilot.rounds)" 5
assert_eq "budget is written" "$(cfg orchestrator.autopilot.budget)" 12
assert_eq "permission-mode defaults to bypassPermissions" "$(HOME="$default_home" git config --global --get orchestrator.autopilot.permission-mode)" bypassPermissions
run_entry ORCH_PERMISSION_MODE=
assert_eq "an empty permission mode defaults too" "$(cfg orchestrator.autopilot.permission-mode)" bypassPermissions
for key in cap handle rounds budget; do
  assert_eq "an unset variable leaves $key unset" "$(HOME="$default_home" git config --global --get "orchestrator.autopilot.$key" >/dev/null 2>&1 && echo set || echo unset)" unset
  upper="ORCH_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  run_entry "$upper="
  assert_eq "an empty $upper leaves $key unset" "$(cfg_set "orchestrator.autopilot.$key")" unset
done


assert_contains "first start clones the repo into the clone dir" "$(<"$default_gh_log")" "repo clone owner/name $default_clone"
assert_eq "first start leaves a git clone" "$([ -d "$default_clone/.git" ] && echo yes)" yes
run_entry -HOME "HOME=$default_home" -ORCH_CLONE_DIR "ORCH_CLONE_DIR=$default_clone"
assert_status "second start succeeds" "$st" 0
assert_eq "second start does not clone again" "$(grep -c 'repo clone' "$gh_log")" 0

FAKE_GH_FAIL=clone run_entry
assert_status "a failing clone refuses" "$st" 1
assert_contains "a failing clone names its step" "$err" "orch: clone"
assert_eq "a failing clone leaves the directory" "$([ -d "$clone" ] && echo yes)" yes
assert_empty "a failing clone leaves the directory empty" "$(ls -A "$clone")"
assert_empty "a failing clone leaves orch.sh unrun" "$(<"$orch_log")"


clone_prep=
sh_out="$root/exec.pid"
(
  home_dir="$(mktemp -d "$root/exec.XXXXXX")"
  echo "$home_dir" >"$sh_out.dir"
  echo "$BASHPID" >"$sh_out"
  exec env -i "PATH=$fake_bin:$PATH" "HOME=$home_dir" "GH_LOG=$home_dir/gh.log" \
    "ORCH_LOG=$home_dir/orch.log" "ORCH_SH=$root/orch.sh" \
    "ORCH_CLONE_DIR=$home_dir/clone" REPO=owner/name GH_TOKEN=tok \
    CLAUDE_CODE_OAUTH_TOKEN=oauth bash "$ENTRY" >/dev/null 2>&1
)
entry_pid="$(<"$sh_out")"
exec_dir="$(<"$sh_out.dir")"
exec_line="$(<"$exec_dir/orch.log")"
assert_contains "orch.sh autopilot watch runs" "$exec_line" "args=autopilot watch"
assert_contains "it runs in the clone" "$exec_line" "pwd=$exec_dir/clone"
assert_contains "it runs by exec: its PID is the entrypoint's" "$exec_line" "pid=$entry_pid "
assert_eq "it runs once" "$(wc -l <"$exec_dir/orch.log" | tr -d ' ')" 1

# >>> summary
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
