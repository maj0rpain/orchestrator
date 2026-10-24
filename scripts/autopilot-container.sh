#!/usr/bin/env bash
#
# autopilot-container.sh - the autopilot container's entrypoint. It checks the
# environment, sets git and `orchestrator.autopilot.*` up from it, clones the
# repo (or reuses the clone) and execs `orch.sh autopilot watch` in the clone.
# Its tests: scripts/test/autopilot_container_test.sh.
#
# Environment: REPO (owner/name), GH_TOKEN, and CLAUDE_CODE_OAUTH_TOKEN or
# ANTHROPIC_API_KEY are required. ORCH_GIT_NAME, ORCH_GIT_EMAIL,
# ORCH_PERMISSION_MODE, ORCH_CAP, ORCH_HANDLE, ORCH_ROUNDS, ORCH_BUDGET,
# ORCH_MODEL, ORCH_EFFORT, ORCH_MODEL_<ROLE>, ORCH_EFFORT_<ROLE> (roles from
# `orch.sh agent roles`, upper-case: IMPLEMENTER, LENS, REVIEWER, FIXER, CLOSER,
# RESOLVER) and ORCH_CLONE_DIR (default /home/orch/repo) are optional; ORCH_SH
# names the installed plugin's orch.sh. A variable set to the empty string
# counts as unset. ORCH_MODEL and ORCH_EFFORT are the phase session's model and
# effort (orchestrator.autopilot.model/effort); a role variable is that role's
# agent setting, written with `agent set --global`, and a role left unset
# inherits the phase session's model and effort. Unset clears: an unset
# ORCH_CAP, ORCH_HANDLE, ORCH_ROUNDS, ORCH_BUDGET, ORCH_MODEL, ORCH_EFFORT or
# role variable clears its global key, so .env is the one source of truth;
# ORCH_PERMISSION_MODE defaults to bypassPermissions instead. Once the clone
# exists the settings are written in it, `orch.sh autopilot show` validates
# them, and a refusal keeps what was written and never starts the watcher.
# The first failing step exits non-zero with an `orch:` line on stderr.

# shellcheck source=orch/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/orch/common.sh"

# 1. Refuse: one line per missing variable, then one exit.
missing=0
for required in REPO GH_TOKEN; do
  if [ -z "${!required:-}" ]; then
    warn "$required is not set"
    missing=1
  fi
done
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  warn "neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set"
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

# 4. Permission mode: a value only, `autopilot show` validates it in step 6.
git config --global orchestrator.autopilot.permission-mode "${ORCH_PERMISSION_MODE:-bypassPermissions}" ||
  die "autopilot settings: cannot write orchestrator.autopilot.permission-mode"

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

# 6. The other settings, from .env alone: a variable set is written, one unset
# or empty clears its global key. orch.sh refuses outside a git repository, so
# this waits for the clone. A refusal exits with its `orch:` line, keeps what
# was already written and never reaches the watcher.
[ -n "${ORCH_SH:-}" ] && [ -f "$ORCH_SH" ] || die "exec: ORCH_SH does not name an orch.sh"
cd "$clone_dir" || die "exec: cannot enter $clone_dir"

# autopilot_set <key> <value>: writes the key; an empty value clears it.
autopilot_set() {
  if [ -z "$2" ]; then git_config_unset global "orchestrator.autopilot.$1" ||
    die "autopilot settings: cannot clear orchestrator.autopilot.$1"
  else git config --global "orchestrator.autopilot.$1" "$2" ||
    die "autopilot settings: cannot write orchestrator.autopilot.$1"; fi
}
autopilot_set cap "${ORCH_CAP:-}"
autopilot_set handle "${ORCH_HANDLE:-}"
autopilot_set rounds "${ORCH_ROUNDS:-}"
autopilot_set budget "${ORCH_BUDGET:-}"
autopilot_set model "${ORCH_MODEL:-}"
autopilot_set effort "${ORCH_EFFORT:-}"

roles="$(bash "$ORCH_SH" agent roles)" || die "agent roles failed"
for role in $roles; do
  upper="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
  for kind in model effort; do
    var="ORCH_$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')_$upper"
    if [ -n "${!var:-}" ]; then
      bash "$ORCH_SH" agent set "$role" "--$kind" "${!var}" --global || exit 1
    else
      bash "$ORCH_SH" agent clear "$role" "--$kind" --global || exit 1
    fi
  done
done

bash "$ORCH_SH" autopilot show >/dev/null || exit 1

# 7. The watcher becomes the main process.
exec bash "$ORCH_SH" autopilot watch
