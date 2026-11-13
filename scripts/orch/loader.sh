#!/usr/bin/env bash
#
# The module loader, always loaded beside common.sh: orch_load sources a module
# of scripts/orch/ once per shell, and orch_load_all loads every module in the
# order orch.sh has always sourced them. Neither common.sh nor this file names
# a function a module defines.
#
# ORCH_LOAD_TRACE=<file> makes every module load append "<module> <depth>" to
# that file, depth being BASH_SUBSHELL (0 for the main shell). Unset, nothing
# is written; a failed append is ignored.

# The modules already sourced in this shell, by name without .sh. Declared
# global (-g) because orch_load runs this file's callers' sourcing inside a
# function, where a plain declare would make a module's array local.
declare -gA ORCH_LOADED=()
# The directory the modules sit in: this file's own.
ORCH_MODULE_DIR="${BASH_SOURCE[0]%/*}"

# orch_load <module>: sources scripts/orch/<module>.sh unless this shell has
# already, tracing the load when ORCH_LOAD_TRACE names a file. An unknown name
# stops with exit 1.
orch_load() {
  local name="$1"
  [ -z "${ORCH_LOADED[$name]:-}" ] || return 0
  case "$name" in
    ''|common|loader|*/*) die "orch_load: no module $name" ;;
  esac
  [ -f "$ORCH_MODULE_DIR/$name.sh" ] || die "orch_load: no module $name"
  ORCH_LOADED[$name]=1
  if [ -n "${ORCH_LOAD_TRACE:-}" ]; then
    { printf '%s %s\n' "$name" "$BASH_SUBSHELL" >>"$ORCH_LOAD_TRACE"; } 2>/dev/null || true
  fi
  # shellcheck source=/dev/null
  source "$ORCH_MODULE_DIR/$name.sh"
}

# orch_modules: prints every module's name, one per line, in the C-locale
# order of the names without .sh (issue before issue-timeline). Sorted in bash,
# so no process is spawned.
orch_modules() {
  local LC_ALL=C f name i j tmp
  local -a names=()
  for f in "$ORCH_MODULE_DIR"/*.sh; do
    name="${f##*/}"
    name="${name%.sh}"
    case "$name" in common|loader) continue ;; esac
    names+=("$name")
  done
  for ((i = 1; i < ${#names[@]}; i++)); do
    tmp="${names[i]}"
    for ((j = i - 1; j >= 0; j--)); do
      [[ "${names[j]}" > "$tmp" ]] || break
      names[j + 1]="${names[j]}"
    done
    names[j + 1]="$tmp"
  done
  printf '%s\n' "${names[@]}"
}

# orch_load_all: loads every module, in orch_modules' order.
orch_load_all() {
  local m
  while IFS= read -r m; do orch_load "$m"; done < <(orch_modules)
}
