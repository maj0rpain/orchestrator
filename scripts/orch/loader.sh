#!/usr/bin/env bash
#
# The module loader, always loaded beside common.sh: orch_load sources a module
# of scripts/orch/ once per shell, and orch_load_all loads every module in the
# order orch.sh has always sourced them. Neither common.sh nor this file names
# a function a module defines.
#
# orch_stubs, which orch.sh calls when run as a command, makes loading lazy: it
# scans the module files for functions defined at column 0 (`name() {` or
# `name() (`) and defines a one-line stub for each, calling orch_stub for its
# module. The first call loads the module, whose definitions replace its stubs,
# and runs the real function. A stub called in a subshell loads in that subshell
# only. The table is cached in one file per plugin copy under
# ~/.cache/orchestrator/, named from the absolute path of this directory, and
# used only when strictly newer than every module file and the directory itself
# (so an edit, an added module and a removed one each rebuild it). A rebuild is
# written to a temporary file beside the cache and moved into place; any failure
# of the cache (HOME unset, a directory or file not creatable, readable or
# writable) leaves the start going on with the table built in memory, silently.
# The cache file is readable and writable by its owner only.
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

# orch_stub_scan: sets ORCH_STUB_DEFS to the stub table: one stub definition
# per function the module files define at column 0. A function two modules
# define belongs to the later one in the file order, as loading every module
# would leave it.
orch_stub_scan() {
  local name mod defs=''
  local -A owner=()
  while IFS=: read -r mod name; do
    mod="${mod##*/}"
    owner[${name%%(*}]="${mod%.sh}"
  done < <(grep -HoE '^[A-Za-z_][A-Za-z0-9_]*\(\) [{(]' "$ORCH_MODULE_DIR"/*.sh)
  for name in "${!owner[@]}"; do
    mod="${owner[$name]}"
    case "$mod" in common|loader) continue ;; esac
    defs+="$name() { orch_stub $mod $name \"\$@\"; }"$'\n'
  done
  ORCH_STUB_DEFS="$defs"
}

# orch_stub_cache_file: sets ORCH_STUB_CACHE to this plugin copy's cache file,
# named from the absolute path of its modules' directory, and fails with it
# empty when HOME is unset or empty. The path's % and / are escaped, so no two
# copies share a name.
orch_stub_cache_file() {
  local dir name
  ORCH_STUB_CACHE=''
  [ -n "${HOME:-}" ] || return 1
  dir="$(CDPATH='' cd -- "$ORCH_MODULE_DIR" 2>/dev/null && pwd -P)" || return 1
  name="${dir//%/%25}"
  name="${name//\//%2F}"
  ORCH_STUB_CACHE="$HOME/.cache/orchestrator/$name.stubs"
}

# orch_stub_cache_fresh: succeeds when the cache file is strictly newer than
# every module file and the modules' directory.
orch_stub_cache_fresh() {
  local f
  [ -f "$ORCH_STUB_CACHE" ] || return 1
  [ "$ORCH_STUB_CACHE" -nt "$ORCH_MODULE_DIR" ] || return 1
  for f in "$ORCH_MODULE_DIR"/*.sh; do
    [ "$ORCH_STUB_CACHE" -nt "$f" ] || return 1
  done
}

# orch_stub_cache_write: writes ORCH_STUB_DEFS to the cache file through a
# temporary file unique to this start, moved into place in one step. Any failure
# removes the temporary file, prints nothing and returns 1.
orch_stub_cache_write() {
  local tmp
  [ -n "${ORCH_STUB_CACHE:-}" ] || return 1
  [ ! -d "$ORCH_STUB_CACHE" ] || return 1
  (umask 077; mkdir -p "${ORCH_STUB_CACHE%/*}") 2>/dev/null || return 1
  tmp="$(umask 077; mktemp "$ORCH_STUB_CACHE.XXXXXX" 2>/dev/null)" || return 1
  if { printf '%s' "$ORCH_STUB_DEFS" >"$tmp"; } 2>/dev/null \
    && chmod 600 "$tmp" 2>/dev/null \
    && mv -f -- "$tmp" "$ORCH_STUB_CACHE" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  return 1
}

# orch_stubs: defines a stub for every function the module files define at
# column 0, in one eval, from the cache when it is fresh and else from a scan,
# which is then written to the cache. ORCH_STUB_FROM_CACHE is 1 when the table
# was read from the cache file.
orch_stubs() {
  local defs=''
  ORCH_STUB_FROM_CACHE=''
  ORCH_STUB_REBUILT=''
  if orch_stub_cache_file && orch_stub_cache_fresh \
    && { defs="$(<"$ORCH_STUB_CACHE")"; } 2>/dev/null && [ -n "$defs" ]; then
    ORCH_STUB_FROM_CACHE=1
  else
    orch_stub_scan
    defs="$ORCH_STUB_DEFS"
    orch_stub_cache_write || true
  fi
  eval "$defs"
}

# orch_stub_owner <function>: prints the module that now defines the function
# at column 0, and fails when none does.
orch_stub_owner() {
  local f found=''
  for f in "$ORCH_MODULE_DIR"/*.sh; do
    case "${f##*/}" in common.sh|loader.sh) continue ;; esac
    if grep -qE "^$1\\(\\) [{(]" "$f"; then found="${f##*/}"; fi
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "${found%.sh}"
}

# orch_stub_die <function>: stops with the stub table's message, ending with
# the cache file to remove when the table was read from it.
orch_stub_die() {
  local tail=''
  if [ -n "${ORCH_STUB_FROM_CACHE:-}" ] && [ -n "${ORCH_STUB_CACHE:-}" ]; then
    tail=" - remove $ORCH_STUB_CACHE and run again"
  fi
  die "$1 is in the stub table but no module defines it$tail"
}

# orch_stub <module> <function> [args...]: what a stub runs. Loads the module,
# then calls the real function with the arguments, returning its status. When
# the module did not define the function, the table was wrong: it is rebuilt
# once and written to the cache, then another module that defines the function
# is loaded and the call goes on, else the command stops.
orch_stub() {
  local mod="$1" fn="$2" other
  shift 2
  orch_load "$mod"
  if [[ "$(declare -f "$fn")" == *"orch_stub "* ]]; then
    if [ -z "${ORCH_STUB_REBUILT:-}" ]; then
      ORCH_STUB_REBUILT=1
      orch_stub_scan
      orch_stub_cache_write || true
    fi
    other="$(orch_stub_owner "$fn")" || other=''
    if [ -z "$other" ] || [ "$other" = "$mod" ]; then
      orch_stub_die "$fn"
    fi
    orch_load "$other"
    if [[ "$(declare -f "$fn")" == *"orch_stub "* ]]; then
      orch_stub_die "$fn"
    fi
  fi
  "$fn" "$@"
}
