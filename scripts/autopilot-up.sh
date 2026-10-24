#!/usr/bin/env bash
#
# autopilot-up.sh - brings the autopilot compose projects up from this
# checkout: docker/.env as the default project and each docker/.env.<name> as
# project <name> (never .env.example). It creates a project not yet created and
# rebuilds one that exists, which is how a plugin update reaches autopilot: the
# plugin is baked into the image at build.
#
# Usage: scripts/autopilot-up.sh [--fresh] [--force] [name...]
#   name     only these projects; `default` means docker/.env
#   --fresh  build with --pull --no-cache, refreshing the base image and
#            Claude Code
#   --force  recreate a project whose container is running a phase session
#
# Prints an `engine:` line, then one summary line per project: env file,
# project name, outcome (created, rebuilt, skipped, failed) and the plugin
# version and checkout commit baked in. A failed project does not stop the
# others; the exit is non-zero when any failed. Never runs a git command that
# changes anything; warns when the checkout has uncommitted changes. Its tests:
# scripts/test/autopilot_up_test.sh.

# shellcheck source=orch/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/orch/common.sh"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker_dir="$root/docker"

fresh=0
force=0
names=()
for arg in "$@"; do
  case "$arg" in
    --fresh) fresh=1 ;;
    --force) force=1 ;;
    -*) die2 "unknown option $arg" ;;
    *) names+=("$arg") ;;
  esac
done

# The busy probe, run by plain sh inside the container so that it works against
# an image built before this script existed: one "<issue> <phase>" line per
# live run pidfile, the phase from the newest log beside run/, or ?.
probe='d="${ORCH_CLONE_DIR:-/home/orch/repo}/.orchestrator/autopilot"
for f in "$d"/run/*.pid; do
  [ -e "$f" ] || continue
  p=$(cat "$f")
  kill -0 "$p" 2>/dev/null || continue
  i=$(basename "$f" .pid)
  l=$(ls -t "$d"/logs/"$i"-*.log 2>/dev/null | sed -n 1p)
  ph="?"
  if [ -n "$l" ]; then
    ph=${l##*/}
    ph=${ph#"$i"-}
    ph=${ph%%-*}
  fi
  echo "$i $ph"
done'

engine="$(docker info --format '{{.Name}}')" || die "docker info failed; is Docker running?"
echo "engine: $engine"

version="$(sed -n '/^[[:space:]]*"version"/{s/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/;p;q;}' \
  "$root/.claude-plugin/plugin.json")"
commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null)" || commit="unknown"
baked="orchestrator ${version:-unknown} @ $commit"
if [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
  warn "warning: the checkout has uncommitted changes; the build uses the working tree"
fi

# Project list: "<file>" per entry, "default" for .env.
if [ "${#names[@]}" -eq 0 ]; then
  names=()
  [ -f "$docker_dir/.env" ] && names+=(default)
  for f in "$docker_dir"/.env.*; do
    [ -f "$f" ] || continue
    n="${f##*/.env.}"
    [ "$n" = example ] && continue
    names+=("$n")
  done
fi

# compose <args>: docker compose for the current project, from docker/, with
# its env file as both the container's settings and the build's args.
compose() {
  (cd "$docker_dir" && ORCH_ENV_FILE="$file" docker compose --env-file "$file" "${pflag[@]}" "$@")
}

# summary_line <outcome> <detail>: the current project's one summary line.
summary_line() { printf '%-13s (%s)  %-8s %s\n' "$file" "$pname" "$1" "$2"; }

failed=0
for name in "${names[@]}"; do
  if [ "$name" = default ]; then
    file=.env
    pflag=()
  else
    file=".env.$name"
    pflag=(-p "$name")
  fi
  if [ ! -f "$docker_dir/$file" ] || [ "$name" = example ]; then
    printf '%s  failed  no env file docker/%s\n' "$name" "$file"
    failed=1
    continue
  fi

  pname="$(compose config | sed -n '/^name:/{s/^name:[[:space:]]*//;p;q;}')"
  [ -n "$pname" ] || pname="${pflag[1]:-docker}"

  existing="$(compose ps -a -q)"
  running="$(compose ps -q)"
  killed=""
  if [ -n "$running" ]; then
    if live="$(compose exec -T autopilot sh -c "$probe")"; then
      if [ -n "$live" ]; then
        sessions="$(printf '%s\n' "$live" | awk 'NF { printf "%s#%s %s", (n++ ? ", " : ""), $1, $2 }')"
        if [ "$force" -eq 0 ]; then
          summary_line skipped "busy: $sessions"
          continue
        fi
        killed="forced: killed $sessions"
      fi
    elif [ "$force" -eq 0 ]; then
      summary_line skipped "busy: unknown (probe failed)"
      continue
    else
      killed="forced: killed unknown (probe failed)"
    fi
  fi

  if [ "$fresh" -eq 1 ] && ! compose build --pull --no-cache >&2; then
    summary_line failed "$baked"
    failed=1
    continue
  fi
  if compose up -d --build >&2; then
    if [ -n "$existing" ]; then outcome=rebuilt; else outcome=created; fi
    summary_line "$outcome" "$baked${killed:+ $killed}"
  else
    summary_line failed "$baked"
    failed=1
  fi
done
exit "$failed"
