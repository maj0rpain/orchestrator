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
# shellcheck source=git_env.sh
source "$DIR/test/git_env.sh"
test_git_env_clear || exit 1
# shellcheck source=tally.sh
source "$DIR/test/tally.sh"
ENTRY="$DIR/autopilot-container.sh"

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
# The tally file lands in the temp root, removed with it.
tally_init


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
    if [ "${FAKE_GH_FAIL:-}" = cdfail ]; then rm -rf "$4"; echo notadir >"$4"; exit 0; fi
    if [ "${FAKE_GH_FAIL:-}" = clone ]; then
      mkdir -p "$4" && echo partial >"$4/leftover"
      exit 1
    fi
    git init -q "$4"
    git -C "$4" remote add origin "https://github.com/$3.git"
    exit 0 ;;
esac
exit 2
FAKE
cat >"$root/orch.sh" <<'FAKE'
#!/usr/bin/env bash
# The fake orch.sh: logs pid, directory and arguments; prints a role list for
# `agent roles` and a marker for
# `autopilot show`; and refuses, with an `orch:` line, any call whose arguments
# contain $FAKE_ORCH_FAIL.
printf 'pid=%s pwd=%s host=%s args=%s\n' "$$" "$PWD" "${ORCH_HOST_ID:-}" "$*" >>"$ORCH_LOG"
# `repo show` goes to the real orch.sh, so its origin parser is the one tested.
[ "$1 $2" = "repo show" ] && exec bash "$REAL_ORCH_SH" "$@"
# Each agent set/clear records, in $ORCH_LOG.shadows, "<left> <listed>": how many
# keys of $FAKE_SHADOW_KEYS (one <key>=<value> per line, the keys the case
# seeded) the clone still holds locally at the moment of the call, and how many
# entries the list holds. No pattern is matched.
case "$1 $2" in "agent set"|"agent clear")
  left=0 listed=0
  while IFS= read -r shadow_entry; do
    [ -n "$shadow_entry" ] || continue
    listed=$((listed + 1))
    ! git config --local --get "${shadow_entry%%=*}" >/dev/null 2>&1 || left=$((left + 1))
  done <<<"${FAKE_SHADOW_KEYS:-}"
  echo "$left $listed" >>"$ORCH_LOG.shadows" ;;
esac
if [ -n "${FAKE_ORCH_FAIL:-}" ]; then
  case "$*" in *"$FAKE_ORCH_FAIL"*) echo "orch: refused $*" >&2; exit 1 ;; esac
fi
[ "$*" = "agent roles" ] && printf '%s\n' implementer lens reviewer fixer closer resolver
[ "$*" = "autopilot show" ] && echo autopilot-show-marker
exit 0
FAKE
chmod +x "$fake_bin/gh"


# entry_env <VAR=value>...: makes a fresh case directory and fills the global
# array entry_envs with the valid base environment plus the arguments, each
# overriding the base; a VAR= with no value sets it empty, and `-VAR` removes
# it. Sets $case_dir, $home, $clone (ORCH_CLONE_DIR unless an argument sets
# it), $gh_log and $orch_log. A case that needs the clone directory prepared
# sets $clone_prep to a command run before it.
entry_env() {
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
    "ORCH_SH=$root/orch.sh" "REAL_ORCH_SH=$DIR/orch.sh" "ORCH_CLONE_DIR=$clone"
    "FAKE_GH_FAIL=${FAKE_GH_FAIL:-}" "FAKE_ORCH_FAIL=${FAKE_ORCH_FAIL:-}"
    "FAKE_SHADOW_KEYS=${shadow_list:-}"
    "REPO=owner/name" "GH_TOKEN=tok" "CLAUDE_CODE_OAUTH_TOKEN=oauth"
  )
  local arg entry
  entry_envs=()
  for entry in "${envs[@]}"; do
    for arg in "$@"; do
      [ "$arg" = "-${entry%%=*}" ] && continue 2
    done
    entry_envs+=("$entry")
  done
  for arg in "$@"; do
    case "$arg" in -*) ;; *) entry_envs+=("$arg") ;; esac
  done
}
# run_entry <VAR=value>...: entry_env, then runs the entrypoint under that
# environment. Leaves entry_env's variables, $err (stderr) and $st.
run_entry() {
  entry_env "$@"
  err="$(env -i "${entry_envs[@]}" bash "$ENTRY" 2>&1 >/dev/null)"
  st=$?
}
# cfg <key> [home]: a key's global git config value; home defaults to $home.
cfg() { HOME="${2:-$home}" git config --global --get "$1"; }
# cfg_state <key> [home]: set or unset, for whether the key has a value.
cfg_state() { cfg "$@" >/dev/null 2>&1 && echo set || echo unset; }

# >>> checks

refusal() { # <label> <expected message> <VAR=value or -VAR>...
  local label="$1" want="$2"
  shift 2
  run_entry "$@"
  assert_status "$label: exits 1" "$st" 1
  assert_contains "$label: says so" "$err" "orch: environment: $want"
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
assert_eq "all three missing: one environment line each" "$(printf '%s\n' "$err" | grep -c '^orch: environment: ')" 3
assert_eq "all three missing: nothing but environment lines" "$(printf '%s\n' "$err" | grep -vc '^orch: environment: ')" 0
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
assert_contains "a failing gh auth setup-git names its step" "$err" "orch: credential helper: gh auth setup-git failed"
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


assert_eq "identity name falls back on the token owner's login" "$(cfg user.name "$default_home")" octo
assert_eq "identity email falls back on the noreply address" "$(cfg user.email "$default_home")" "4242+octo@users.noreply.github.com"
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
assert_eq "permission-mode defaults to bypassPermissions" "$(cfg orchestrator.autopilot.permission-mode "$default_home")" bypassPermissions
run_entry ORCH_PERMISSION_MODE=
assert_eq "an empty permission mode defaults too" "$(cfg orchestrator.autopilot.permission-mode)" bypassPermissions
for key in cap handle rounds budget model effort; do
  upper="ORCH_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  assert_eq "an unset variable leaves $key unset on a first start" "$(cfg_state "orchestrator.autopilot.$key" "$default_home")" unset
  # A start that wrote the key, then one with the variable empty.
  run_entry "$upper=1"
  prior_home="$home" prior_clone="$clone"
  assert_eq "$upper writes $key" "$(cfg "orchestrator.autopilot.$key")" 1
  run_entry -HOME "HOME=$prior_home" -ORCH_CLONE_DIR "ORCH_CLONE_DIR=$prior_clone" "$upper="
  assert_eq "an empty $upper clears $key" "$(cfg_state "orchestrator.autopilot.$key")" unset
done

# Model and effort reach their global keys.
run_entry ORCH_MODEL=opus ORCH_EFFORT=high
assert_eq "ORCH_MODEL is written" "$(cfg orchestrator.autopilot.model)" opus
assert_eq "ORCH_EFFORT is written" "$(cfg orchestrator.autopilot.effort)" high

# Role variables: one agent set or agent clear call per role and kind.
run_entry ORCH_MODEL_IMPLEMENTER=opus ORCH_EFFORT_LENS=low ORCH_MODEL_RESOLVER= ORCH_EFFORT_FIXER=high
calls="$(grep -o 'args=agent .*' "$orch_log")"
assert_contains "a role model variable is agent set" "$calls" "args=agent set implementer --model opus --global"
assert_contains "a role effort variable is agent set" "$calls" "args=agent set lens --effort low --global"
assert_contains "another role effort variable is agent set" "$calls" "args=agent set fixer --effort high --global"
assert_contains "an empty role variable is agent clear" "$calls" "args=agent clear resolver --model --global"
assert_contains "an unset role variable is agent clear" "$calls" "args=agent clear reviewer --effort --global"
assert_eq "every role and kind gets exactly one call" "$(printf '%s\n' "$calls" | grep -c 'args=agent \(set\|clear\) ')" 12
assert_contains "the role list comes from agent roles" "$calls" "args=agent roles"

# autopilot show runs in the clone, before the watcher.
show_line="$(grep -n 'args=autopilot show' "$orch_log" | cut -d: -f1)"
watch_line="$(grep -n 'args=autopilot watch' "$orch_log" | cut -d: -f1)"
assert_contains "autopilot show runs in the clone" "$(grep 'args=autopilot show' "$orch_log")" "pwd=$clone "
assert_eq "autopilot show runs before autopilot watch" "$([ -n "$show_line" ] && [ "$show_line" -lt "$watch_line" ] && echo yes)" yes

# A refusal exits with its line and never starts the watcher.
for refused in "agent set implementer" "autopilot show" "agent roles" "agent clear"; do
  FAKE_ORCH_FAIL="$refused" run_entry ORCH_MODEL_IMPLEMENTER=opus ORCH_MODEL=opus
  assert_eq "a refused '$refused' exits non-zero" "$([ "$st" -ne 0 ] && echo yes)" yes
  assert_contains "a refused '$refused' shows its orch line" "$err" "orch: refused $refused"
  assert_eq "a refused '$refused' never runs the watcher" "$(grep -c 'args=autopilot watch' "$orch_log")" 0
done
FAKE_ORCH_FAIL="agent set" run_entry ORCH_MODEL=opus ORCH_MODEL_LENS=low
assert_eq "a refused start keeps what it already wrote" "$(cfg orchestrator.autopilot.model)" opus


# Local keys in a reused clone that would shadow a global key are removed, with
# one warning each, before the global writes, autopilot show and the watcher.
# The shadowing keys the case seeds, once: one <key>=<value> per line. The
# seeding and the fake orch.sh's count both read this list.
shadow_list='orchestrator.autopilot.cap=9
orchestrator.autopilot.permission-mode=plan
orchestrator.autopilot.bogus=x
orchestrator.model.implementer=opus
orchestrator.effort.lens=low
user.name=Stale
user.email=stale@example.com'
local_prep='git init -q "$clone" && git -C "$clone" remote add origin https://github.com/owner/name.git &&
  while IFS= read -r seed; do git -C "$clone" config "${seed%%=*}" "${seed#*=}" || exit 1; done <<<"$shadow_list" &&
  git -C "$clone" config orchestrator.junie.model.implementer keepme'
clone_prep="$local_prep" run_entry ORCH_CAP=2 ORCH_GIT_NAME=Bot ORCH_GIT_EMAIL=bot@example.com -ORCH_PERMISSION_MODE
assert_status "stale local keys: the start succeeds" "$st" 0
assert_empty "stale local keys: no local autopilot key remains" "$(git -C "$clone" config --local --get-regexp '^orchestrator\.autopilot\.')"
assert_empty "stale local keys: no local agent-setting key remains" "$(git -C "$clone" config --local --get-regexp '^orchestrator\.(model|effort)\.')"
assert_empty "stale local keys: no local identity key remains" "$(git -C "$clone" config --local --get-regexp '^user\.(name|email)$')"
assert_eq "stale local keys: the Junie key stays" "$(git -C "$clone" config --local orchestrator.junie.model.implementer)" keepme
assert_eq "stale local keys: global cap follows .env" "$(cfg orchestrator.autopilot.cap)" 2
assert_eq "stale local keys: global permission-mode is the default" "$(cfg orchestrator.autopilot.permission-mode)" bypassPermissions
assert_eq "stale local keys: git in the clone resolves the name" "$(HOME="$home" git -C "$clone" config user.name)" Bot
assert_eq "stale local keys: git in the clone resolves the email" "$(HOME="$home" git -C "$clone" config user.email)" bot@example.com
assert_contains "stale local keys: cap warning names its value" "$err" "orch: removed local orchestrator.autopilot.cap (9) - docker/.env is the one source of truth"
assert_contains "stale local keys: permission-mode warning names its value" "$err" "orch: removed local orchestrator.autopilot.permission-mode (plan)"
assert_contains "stale local keys: unknown key warning names its value" "$err" "orch: removed local orchestrator.autopilot.bogus (x)"
assert_contains "stale local keys: model warning names the raw key" "$err" "orch: removed local orchestrator.model.implementer (opus) - docker/.env is the one source of truth"
assert_contains "stale local keys: effort warning names the raw key" "$err" "orch: removed local orchestrator.effort.lens (low) - docker/.env is the one source of truth"
assert_contains "stale local keys: name warning names its value" "$err" "orch: removed local user.name (Stale) - docker/.env is the one source of truth"
assert_contains "stale local keys: email warning names its value" "$err" "orch: removed local user.email (stale@example.com) - docker/.env is the one source of truth"
assert_eq "stale local keys: one warning per key" "$(printf '%s\n' "$err" | grep -c '^orch: removed local ')" 7
assert_eq "stale local keys: no agent show call" "$(grep -c 'args=agent show' "$orch_log")" 0
assert_eq "stale local keys: no local agent clear" "$(grep 'args=agent clear' "$orch_log" | grep -vc -e '--global')" 0
last_removal="$(printf '%s\n' "$err" | grep -n '^orch: removed local ' | tail -1 | cut -d: -f1)"
marker_at="$(printf '%s\n' "$err" | grep -n '^autopilot-show-marker' | cut -d: -f1)"
assert_eq "removal lines come before the autopilot show output" "$([ -n "$marker_at" ] && [ "$last_removal" -lt "$marker_at" ] && echo yes)" yes
assert_eq "no shadowing local key is left at any global agent write" "$(cut -d' ' -f1 "$orch_log.shadows" | sort -u)" 0
assert_eq "the fake received the whole seeded list at every global agent write" "$(cut -d' ' -f2 "$orch_log.shadows" | sort -u)" "$(printf '%s\n' "$shadow_list" | wc -l | tr -d ' ')"
assert_eq "every global agent write is checked for shadowing keys" "$(wc -l <"$orch_log.shadows" | tr -d ' ')" 12
first_agent_at="$(grep -n 'args=agent \(set\|clear\)' "$orch_log" | sed -n 1p | cut -d: -f1)"
show_at="$(grep -n 'args=autopilot show' "$orch_log" | cut -d: -f1)"
watch_at="$(grep -n 'args=autopilot watch' "$orch_log" | cut -d: -f1)"
assert_eq "global agent writes precede autopilot show and watch" \
  "$([ -n "$first_agent_at" ] && [ "$first_agent_at" -lt "$show_at" ] && [ "$show_at" -lt "$watch_at" ] && echo yes)" yes

run_entry
assert_eq "a clean clone: no removal lines" "$(printf '%s\n' "$err" | grep -c 'removed local')" 0
assert_eq "a clean clone: no local agent clear" "$(grep 'args=agent clear' "$orch_log" | grep -vc -e '--global')" 0

# A directory at .git/config.lock blocks git config writes, so removal fails.
clone_prep="$local_prep"' && mkdir "$clone/.git/config.lock"' run_entry
assert_eq "a failed local removal exits non-zero" "$([ "$st" -ne 0 ] && echo yes)" yes
assert_contains "a failed local removal shows its orch line" "$err" "orch: autopilot settings:"
assert_eq "a failed local removal never runs the watcher" "$(grep -c 'args=autopilot watch' "$orch_log")" 0

shadow_list=
FAKE_ORCH_FAIL="agent roles" run_entry
assert_contains "a refused agent roles names its step" "$err" "orch: autopilot settings: agent roles failed"

FAKE_GH_FAIL=cdfail run_entry
assert_status "a clone directory that cannot be entered refuses" "$st" 1
assert_contains "a clone directory that cannot be entered names its step" "$err" "orch: clone: cannot enter $clone"

assert_contains "first start clones the repo into the clone dir" "$(<"$default_gh_log")" "repo clone owner/name $default_clone"
assert_eq "first start leaves a git clone" "$([ -d "$default_clone/.git" ] && echo yes)" yes
run_entry -HOME "HOME=$default_home" -ORCH_CLONE_DIR "ORCH_CLONE_DIR=$default_clone"
assert_status "second start succeeds" "$st" 0
assert_eq "second start does not clone again" "$(grep -c 'repo clone' "$gh_log")" 0

# A reused clone's origin must name REPO.
mismatch_msg() { # <old> <new>
  echo "orch: clone: $clone is a clone of $1, not REPO=$2; remove the repo volume (docker compose down -v) or run a separate compose project (-p <name>) for the new repo"
}
unreadable_msg() { # <new>
  echo "orch: clone: $clone has an unreadable origin, so it cannot be confirmed as REPO=$1; remove the repo volume (docker compose down -v) or run a separate compose project (-p <name>) for the new repo"
}
clone_prep='git init -q "$clone" && git -C "$clone" remote add origin https://github.com/owner/old-repo.git' \
  run_entry REPO=owner/new-repo
assert_status "a clone of another repo refuses" "$st" 1
assert_eq "a clone of another repo: exactly the mismatch line" "$err" "$(mismatch_msg owner/old-repo owner/new-repo)"
assert_eq "a clone of another repo is not cloned over" "$(grep -c 'repo clone' "$gh_log")" 0
assert_eq "a clone of another repo never runs the agent, show or watch" "$(grep -c 'args=\(agent\|autopilot\)' "$orch_log")" 0
assert_eq "a clone of another repo gets no host id" "$([ -e "$clone/.orchestrator/autopilot/host-id" ] && echo yes || echo no)" no
assert_eq "a clone of another repo keeps its origin" "$(git -C "$clone" remote get-url origin)" https://github.com/owner/old-repo.git

clone_prep='git init -q "$clone" && git -C "$clone" remote add origin https://github.com/owner/old-repo.git' \
  run_entry REPO=owner/new-repo GH_REPO=owner/new-repo
assert_status "a clone of another repo refuses despite GH_REPO" "$st" 1
assert_eq "a clone of another repo despite GH_REPO: the mismatch line" "$err" "$(mismatch_msg owner/old-repo owner/new-repo)"

clone_prep='git init -q "$clone" && git -C "$clone" remote add origin https://github.com/Owner/Name.git' \
  run_entry REPO=owner/name
assert_status "an origin differing only in case is accepted" "$st" 0
assert_eq "an origin differing only in case runs the watcher" "$(grep -c 'args=autopilot watch' "$orch_log")" 1

clone_prep='git init -q "$clone"' run_entry
assert_status "a clone with no origin refuses" "$st" 1
assert_eq "a clone with no origin: the unreadable line" "$err" "$(unreadable_msg owner/name)"
assert_eq "a clone with no origin never runs the watcher" "$(grep -c 'args=autopilot' "$orch_log")" 0

clone_prep='git init -q "$clone" && git -C "$clone" remote add origin /srv/git/some-repo' run_entry
assert_status "a clone with an unparseable origin refuses" "$st" 1
assert_eq "a clone with an unparseable origin: the unreadable line" "$err" "$(unreadable_msg owner/name)"
assert_eq "a clone with an unparseable origin never runs the watcher" "$(grep -c 'args=autopilot' "$orch_log")" 0

run_entry ORCH_SH="$root/missing-orch.sh"
assert_status "a missing orch.sh refuses before the clone" "$st" 1
assert_contains "a missing orch.sh names ORCH_SH" "$err" "orch: clone: ORCH_SH does not name an orch.sh"
assert_eq "a missing orch.sh leaves the repo uncloned" "$(grep -c 'repo clone' "$gh_log")" 0

FAKE_GH_FAIL=clone run_entry
assert_status "a failing clone refuses" "$st" 1
assert_contains "a failing clone names its step" "$err" "orch: clone"
assert_eq "a failing clone leaves the directory" "$([ -d "$clone" ] && echo yes)" yes
assert_empty "a failing clone leaves the directory empty" "$(ls -A "$clone")"
assert_empty "a failing clone leaves orch.sh unrun" "$(<"$orch_log")"


entry_env
sh_out="$root/exec.pid"
(
  echo "$BASHPID" >"$sh_out"
  exec env -i "${entry_envs[@]}" bash "$ENTRY" >/dev/null 2>&1
)
entry_pid="$(<"$sh_out")"
exec_line="$(grep 'args=autopilot watch' "$orch_log")"
assert_contains "orch.sh autopilot watch runs" "$exec_line" "args=autopilot watch"
assert_contains "it runs in the clone" "$exec_line" "pwd=$clone"
assert_contains "it runs by exec: its PID is the entrypoint's" "$exec_line" "pid=$entry_pid "
assert_eq "it runs once" "$(grep -c 'args=autopilot watch' "$orch_log")" 1

# The Dockerfile's lean-session ENV lines, each a whole line.
dockerfile="$DIR/../docker/Dockerfile"
for v in CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING; do
  assert_eq "the Dockerfile sets $v=1" "$(grep -cx "ENV $v=1" "$dockerfile")" 1
done

# The claim identity: written once under the clone, reused on a later start,
# and exported to the watcher as ORCH_HOST_ID.
run_entry
id_file="$clone/.orchestrator/autopilot/host-id"
first_id="$(<"$id_file")"
case "$first_id" in
  autopilot-??????????*) ok "a first start writes autopilot- plus hex to host-id" ;;
  *) bad "a first start writes autopilot- plus hex to host-id" "got '$first_id'" ;;
esac
assert_contains "the watcher gets it as ORCH_HOST_ID" "$(grep 'args=autopilot watch' "$orch_log")" "host=$first_id "
first_clone="$clone"
run_entry "ORCH_CLONE_DIR=$first_clone"
assert_eq "a later start reuses the file" "$(<"$id_file")" "$first_id"
assert_contains "and exports the same value" "$(grep 'args=autopilot watch' "$orch_log")" "host=$first_id "
: >"$id_file"
run_entry "ORCH_CLONE_DIR=$first_clone"
case "$(<"$id_file")" in
  autopilot-?*) ok "an empty host-id is written again" ;;
  *) bad "an empty host-id is written again" "got '$(<"$id_file")'" ;;
esac

# >>> summary
tally_summary
