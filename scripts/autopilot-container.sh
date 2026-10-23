#!/usr/bin/env bash
#
# autopilot-container.sh - the autopilot container's entrypoint. It checks the
# environment, sets git and `orchestrator.autopilot.*` up from it, clones the
# repo (or reuses the clone) and execs `orch.sh autopilot watch` in the clone.
# Its tests: scripts/test/autopilot_container_test.sh.
#
# Environment: REPO (owner/name), GH_TOKEN, and CLAUDE_CODE_OAUTH_TOKEN or
# ANTHROPIC_API_KEY are required. ORCH_GIT_NAME, ORCH_GIT_EMAIL,
# ORCH_PERMISSION_MODE, ORCH_CAP, ORCH_HANDLE, ORCH_ROUNDS, ORCH_BUDGET and
# ORCH_CLONE_DIR (default /home/orch/repo) are optional; ORCH_SH names the
# installed plugin's orch.sh. A variable set to the empty string counts as
# unset. The first failing step exits non-zero with an `orch:` line on stderr.

die() {
  printf 'orch: %s\n' "$*" >&2
  exit 1
}

# 1. Refuse: one line per missing variable, then one exit.
missing=0
for required in REPO GH_TOKEN; do
  if [ -z "${!required:-}" ]; then
    printf 'orch: %s is not set\n' "$required" >&2
    missing=1
  fi
done
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo 'orch: neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set' >&2
  missing=1
fi
[ "$missing" -eq 0 ] || exit 1

# 2. gh as git's HTTPS credential helper.
gh auth setup-git || die "gh auth setup-git failed"

# 3. Commit identity; each key falls back on its own to the token owner.
git_name="${ORCH_GIT_NAME:-}"
git_email="${ORCH_GIT_EMAIL:-}"
if [ -z "$git_name" ] || [ -z "$git_email" ]; then
  user_json="$(gh api user)" || die "commit identity: gh api user failed"
  login="$(jq -r '.login // empty' <<<"$user_json")"
  user_id="$(jq -r '.id // empty' <<<"$user_json")"
  [ -n "$login" ] && [ -n "$user_id" ] ||
    die "commit identity: gh api user returned no login or id"
  [ -n "$git_name" ] || git_name="$login"
  [ -n "$git_email" ] || git_email="$user_id+$login@users.noreply.github.com"
fi
git config --global user.name "$git_name" || die "commit identity: cannot write user.name"
git config --global user.email "$git_email" || die "commit identity: cannot write user.email"

# 4. Autopilot settings: values only, the watcher validates them.
autopilot_set() {
  git config --global "orchestrator.autopilot.$1" "$2" ||
    die "autopilot settings: cannot write orchestrator.autopilot.$1"
}
autopilot_set permission-mode "${ORCH_PERMISSION_MODE:-bypassPermissions}"
[ -z "${ORCH_CAP:-}" ] || autopilot_set cap "$ORCH_CAP"
[ -z "${ORCH_HANDLE:-}" ] || autopilot_set handle "$ORCH_HANDLE"
[ -z "${ORCH_ROUNDS:-}" ] || autopilot_set rounds "$ORCH_ROUNDS"
[ -z "${ORCH_BUDGET:-}" ] || autopilot_set budget "$ORCH_BUDGET"

# 5. Clone, or reuse the clone.
clone_dir="${ORCH_CLONE_DIR:-/home/orch/repo}"
if [ -e "$clone_dir/.git" ]; then
  :
elif [ ! -d "$clone_dir" ] || [ -z "$(ls -A "$clone_dir")" ]; then
  if ! gh repo clone "$REPO" "$clone_dir"; then
    if [ -d "$clone_dir" ]; then
      find "$clone_dir" -mindepth 1 -delete
    fi
    die "clone: gh repo clone $REPO failed"
  fi
else
  die "clone: $clone_dir is not empty and is not a git clone"
fi

# 6. The watcher becomes the main process.
[ -n "${ORCH_SH:-}" ] && [ -f "$ORCH_SH" ] || die "exec: ORCH_SH does not name an orch.sh"
cd "$clone_dir" || die "exec: cannot enter $clone_dir"
exec bash "$ORCH_SH" autopilot watch
