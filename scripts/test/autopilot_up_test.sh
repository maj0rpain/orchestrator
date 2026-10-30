#!/usr/bin/env bash
#
# Tests for scripts/autopilot-up.sh, run as a process and without Docker.
#
# Each case copies the script into a fresh tree (scripts/, docker/ with env
# files, .claude-plugin/plugin.json, a git repo) and runs it with a fake
# `docker` first on PATH. The fake appends each call's argv, cwd and
# ORCH_ENV_FILE to $FAKE_DIR/log and answers from canned files in $FAKE_DIR,
# keyed by project (`default` without -p): info, config.<k>, psa.<k> (ps -a -q),
# ps.<k> (ps -q), probe.<k>, probe-fail.<k> and up-fail.<k>. Assertions are on
# the log, the summary lines and the exit status.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); [ -n "${ORCH_TEST_QUIET:-}" ] || printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
assert_lacks()    { case "$2" in *"$3"*) bad "$1" "unexpected '$3' in: $2" ;; *) ok "$1" ;; esac; }
assert_status()   { if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "expected exit $3, got exit $2"; fi; }

root="$(mktemp -d)" || {
  echo "autopilot_up_test.sh: cannot create the suite's temp root" >&2; exit 1; }
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
cat >"$fake_bin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$*" "$PWD" "${ORCH_ENV_FILE:-}" >>"$FAKE_DIR/log"
if [ "$1" = info ]; then
  [ -f "$FAKE_DIR/info-fail" ] && exit 1
  cat "$FAKE_DIR/info"; exit 0
fi
shift  # compose
key=default
args=("$@")
for i in "${!args[@]}"; do
  [ "${args[$i]}" = -p ] && key="${args[$((i + 1))]}"
done
verb=""
for a in "${args[@]}"; do
  case "$a" in config|ps|exec|up|build) verb="$a"; break ;; esac
done
canned() { [ -f "$FAKE_DIR/$1.$key" ] && cat "$FAKE_DIR/$1.$key"; return 0; }
case "$verb" in
  config) if [ -f "$FAKE_DIR/config.$key" ]; then cat "$FAKE_DIR/config.$key"; else echo "name: $key"; fi ;;
  ps) case " ${args[*]} " in *" -a "*) canned psa ;; *) canned ps ;; esac ;;
  exec) [ -f "$FAKE_DIR/probe-fail.$key" ] && exit 1; canned probe ;;
  up|build) [ -f "$FAKE_DIR/$verb-fail.$key" ] && { echo "compose: $verb failed" >&2; exit 1; }; echo "compose: $verb ok" >&2 ;;
esac
exit 0
FAKE
chmod +x "$fake_bin/docker"

n=0
# new_case [env-file...]: a fresh tree with the named env files in docker/
# (default: .env and .env.example), $case_dir and $FAKE_DIR set.
new_case() {
  n=$((n + 1))
  case_dir="$root/case$n/tree"
  export FAKE_DIR="$root/case$n/fake"
  mkdir -p "$case_dir/scripts/orch" "$case_dir/docker" "$case_dir/.claude-plugin" "$FAKE_DIR"
  cp "$DIR/autopilot-up.sh" "$case_dir/scripts/"
  cp "$DIR/orch/common.sh" "$case_dir/scripts/orch/"
  printf '{\n  "name": "orchestrator",\n  "version": "9.8.7"\n}\n' >"$case_dir/.claude-plugin/plugin.json"
  echo "test-engine" >"$FAKE_DIR/info"
  : >"$FAKE_DIR/log"
  local f
  for f in ${1:-.env .env.example}; do : >"$case_dir/docker/$f"; done
  (cd "$case_dir" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init)
  commit="$(git -C "$case_dir" rev-parse --short HEAD)"
}
# run_up <args>...: runs the script in $case_dir, setting out, err and status.
run_up() {
  : >"$FAKE_DIR/log"
  out="$(cd "$case_dir" && PATH="$fake_bin:$PATH" bash scripts/autopilot-up.sh "$@" 2>"$FAKE_DIR/err")"
  status=$?
  err="$(<"$FAKE_DIR/err")"
  log="$(<"$FAKE_DIR/log")"
}

# >>> checks

# --- discovery and the compose command
new_case ".env .env.work .env.example"
run_up
assert_status "discovery: exits 0" "$status" 0
assert_eq "discovery: engine line first" "$(printf '%s\n' "$out" | head -n 1)" "engine: test-engine"
assert_contains "discovery: default project created" "$out" ".env "
assert_contains "discovery: default summary" "$out" "(default)  created  orchestrator 9.8.7 @ $commit"
assert_contains "discovery: work summary" "$out" "(work)  created  orchestrator 9.8.7 @ $commit"
assert_lacks "discovery: .env.example is no project" "$out$log" "example"
assert_contains "discovery: default up has no -p" "$log" "compose --env-file .env up -d --build|$case_dir/docker|.env"
assert_contains "discovery: named up with -p, from docker/" "$log" "compose --env-file .env.work -p work up -d --build|$case_dir/docker|.env.work"
assert_lacks "discovery: no --pull without --fresh" "$log" "--pull"

# --- selection
new_case ".env .env.work .env.side"
run_up work
assert_contains "named: only work is built" "$log" "-p work up -d --build"
assert_lacks "named: side is not touched" "$log" "side"
assert_lacks "named: default is not touched" "$log" "--env-file .env up"
run_up default
assert_contains "default: names .env" "$log" "--env-file .env up -d --build"
assert_lacks "default: work is not touched" "$log" "-p work"

# --- missing env file
new_case ".env .env.work"
run_up nope work
assert_status "missing: exits non-zero" "$status" 1
assert_contains "missing: failure line" "$out" "nope  failed  no env file docker/.env.nope"
assert_contains "missing: the rest still runs" "$log" "-p work up -d --build"
run_up example
assert_contains "missing: example is no project" "$out" "example  failed  no env file docker/.env.example"

# --- --fresh
new_case ".env"
run_up --fresh
assert_contains "fresh: build with --pull --no-cache" "$log" "build --pull --no-cache"
assert_contains "fresh: still up -d --build" "$log" "up -d --build"

# --- created vs rebuilt
new_case ".env .env.work"
echo abc123 >"$FAKE_DIR/psa.work"
run_up
assert_contains "rebuilt: container exists" "$out" "(work)  rebuilt  orchestrator 9.8.7 @ $commit"
assert_contains "created: no container" "$out" "(default)  created"

# --- project name from config
new_case ".env"
echo "name: custom" >"$FAKE_DIR/config.default"
run_up
assert_contains "name: from config's name: line" "$out" "(custom)"

# --- the probe's own text, run with sh against a fixture clone
probe_text="$(sed -n "/^probe='/,/^done'/p" "$DIR/autopilot-up.sh" | sed "1s/^probe='//;\$s/'\$//")"
sleep 30 &
live_pid=$!
live_start="$(sed 's/^.*) //' "/proc/$live_pid/stat" | cut -d' ' -f20)"
clone="$root/probe-clone"
mkdir -p "$clone/.orchestrator/autopilot/run"
echo "$live_pid $live_start" >"$clone/.orchestrator/autopilot/run/11.pid"
echo "$live_pid 1" >"$clone/.orchestrator/autopilot/run/12.pid"
echo "$live_pid" >"$clone/.orchestrator/autopilot/run/13.pid"
probed="$(ORCH_CLONE_DIR="$clone" sh -c "$probe_text")"
kill "$live_pid" 2>/dev/null
assert_contains "probe: lists a matching start time" "$probed" "11 ?"
assert_lacks "probe: leaves out a different start time" "$probed" "12 "
assert_contains "probe: lists a live bare-pid run" "$probed" "13 ?"

# --- busy
new_case ".env.side"
echo cid >"$FAKE_DIR/psa.side"; echo cid >"$FAKE_DIR/ps.side"
echo "1590 implement" >"$FAKE_DIR/probe.side"
run_up
assert_contains "busy: skipped with the session" "$out" "(side)  skipped  busy: #1590 implement"
assert_lacks "busy: not recreated" "$log" "up -d"
assert_status "busy: a skip is not a failure" "$status" 0
assert_contains "busy: probed with exec -T in the container" "$log" "-p side exec -T autopilot sh -c"
run_up --force
assert_contains "force: rebuilt with the killed line" "$out" "(side)  rebuilt  orchestrator 9.8.7 @ $commit forced: killed #1590 implement"
assert_contains "force: recreated" "$log" "-p side up -d --build"

# --- probe failure
new_case ".env"
echo cid >"$FAKE_DIR/psa.default"; echo cid >"$FAKE_DIR/ps.default"
: >"$FAKE_DIR/probe-fail.default"
run_up
assert_contains "probe failure: skipped" "$out" "skipped  busy: unknown (probe failed)"
assert_lacks "probe failure: not recreated" "$log" "up -d"
run_up --force
assert_contains "probe failure: --force recreates" "$log" "up -d --build"

# --- not running: not probed
new_case ".env"
echo cid >"$FAKE_DIR/psa.default"
run_up
assert_lacks "not running: not probed" "$log" " exec "
assert_contains "not running: rebuilt" "$out" "rebuilt"

# --- idle container
new_case ".env"
echo cid >"$FAKE_DIR/psa.default"; echo cid >"$FAKE_DIR/ps.default"
run_up
assert_contains "idle: probed" "$log" " exec "
assert_contains "idle: rebuilt, nothing killed" "$out" "rebuilt  orchestrator 9.8.7 @ $commit"
assert_lacks "idle: no killed line" "$out" "killed"

# --- failures
new_case ".env .env.work"
: >"$FAKE_DIR/up-fail.default"
run_up
assert_status "failed up: exits non-zero" "$status" 1
assert_contains "failed up: failed line with version and commit" "$out" "(default)  failed   orchestrator 9.8.7 @ $commit"
assert_contains "failed up: later project still runs" "$out" "(work)  created"
assert_contains "failed up: compose output on stderr" "$err" "compose: up failed"

new_case ".env"
rm "$FAKE_DIR/info"; : >"$FAKE_DIR/info-fail"
run_up
assert_status "docker info failure: exits non-zero" "$status" 1
assert_contains "docker info failure: orch: line" "$err" "orch: "
assert_lacks "docker info failure: no project run" "$log" "compose"

# --- dirty checkout
new_case ".env"
run_up
assert_lacks "clean: no warning" "$err" "uncommitted"
echo x >"$case_dir/dirty.txt"
run_up
assert_contains "dirty: warns" "$err" "uncommitted changes"
assert_contains "dirty: still builds" "$log" "up -d --build"
assert_eq "dirty: git status untouched" "$(git -C "$case_dir" status --porcelain)" "?? dirty.txt"

# >>> summary
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
