# shellcheck shell=bash
# suite-cost.sh - orch.sh's suite-cost command: the suite cost of each passing
# verification run, recorded clone-wide.
# Its tests: scripts/test/orch/suite-cost.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.
#
# The record is one file under the clone's git common directory, so the main
# checkout, side checkouts and ticket worktrees share it, and it is per machine
# by construction. Its line format is the record's documented interface: five
# tab-separated fields - the full SHA of HEAD when the run started, suffixed
# -dirty (the git describe --dirty convention) when git status --porcelain
# printed anything then, untracked files counting and ignored paths not, the CPU
# seconds (user plus system, children included), the wall seconds, both to two
# places, the UTC time in ISO 8601, and the command, its words joined by single
# spaces (one argument is a shell line run with bash -c, recorded as given).
# history prints it as written, and the tests seed it.
#
# Only a run no other suite-cost run overlapped is recorded. Beside the record,
# the active-runs directory suite-cost.active holds one marker per measured run
# in progress - suite-cost run, check's base run, or one of its confirming runs
# - a file named by the pid of the orch.sh process measuring it; its contended
# mark is a sibling file <pid>.contended. A run first removes its own pid's
# .contended file, left by an earlier run of the same process, then creates its
# marker, then lists the others: it marks each other live one contended. On
# finish it was overlapped when its .contended file exists, or when it saw
# another live marker at start, and it removes its marker and .contended file
# either way. A marker holds the Liveness module's `<pid> <start-time>` record,
# written under a first name the sweep never takes (.<pid>.new), then moved into
# place; a run whose start time cannot be read does not register. A marker
# whose record is empty, malformed, names a pid other than its file name, or
# whose process is gone or has another start time is stale, and so is a
# .contended file whose marker is gone or stale: no contention, and removed by
# the run that finds it. A failed .contended
# write for another run is not retried, and a failed removal is ignored. A run
# that cannot register still runs but is not recorded. No run ever waits for
# another. A measured run interrupted by INT, TERM or HUP removes its marker,
# first-name file, contended mark and timing file, a tree run its worktree too,
# records nothing, warns once and exits 128 plus the signal's number.
# Before each of its measured runs, check looks for a live marker of
# another process, removing stale ones: on one it starts nothing, warns naming
# its pid and is unmeasured.
#
# A verdict check confirmed (both confirming runs succeeded) is stored in a
# second clone-wide file, suite-cost.verdicts beside the record, so a later
# check on an unchanged clean tree prints it and runs nothing. Its line format
# is documented here: seven tab-separated fields - HEAD's clean full SHA, the
# base commit's full SHA, the floor and the growth knobs as in effect, the UTC
# time in ISO 8601, the command (its words joined by single spaces), and the
# verdict line as printed. A line is written only with HEAD clean when check
# started; unmeasured is never stored, nor an ok or off reached without
# confirmation. The newest line matching all of HEAD, base, floor, growth and
# command wins; later runs on HEAD or the base do not invalidate it. A dirty
# tree never reads the file. history does not print it.

SUITE_COST_RUN_USAGE="usage: orch.sh suite-cost run -- <cmd> [args...] | orch.sh suite-cost run -- '<shell line>'"
SUITE_COST_CHECK_USAGE="usage: orch.sh suite-cost check -- <cmd> [args...] | orch.sh suite-cost check -- '<shell line>'"

# check's defaults, read here alone: below the floor (CPU seconds) a baseline
# is compared with nothing, and growth past the threshold (percent) is a
# finding. Set per clone with git config orchestrator.suiteCost.floor and
# orchestrator.suiteCost.growth. A third per-clone key,
# orchestrator.suiteCost.setup, has no default: the install command (npm ci,
# uv sync) a base run or confirming run runs first at the top of its worktree
# (the measured command then runs in the matching directory), read by
# suite_cost_tree_run.
SUITE_COST_FLOOR_DEFAULT=60
SUITE_COST_GROWTH_DEFAULT=15

cmd_suite_cost() {
  local op="${1:-}"
  shift || true
  case "$op" in
    run)
      [ "${1:-}" = "--" ] && [ $# -ge 2 ] || die "$SUITE_COST_RUN_USAGE"
      shift
      suite_cost_args_ok "$@" || die "$SUITE_COST_RUN_USAGE"
      suite_cost_run "$@"
      ;;
    check)
      [ "${1:-}" = "--" ] && [ $# -ge 2 ] || die "$SUITE_COST_CHECK_USAGE"
      shift
      suite_cost_args_ok "$@" || die "$SUITE_COST_CHECK_USAGE"
      suite_cost_check "$@"
      ;;
    history)
      [ $# -eq 0 ] || die "usage: orch.sh suite-cost history"
      suite_cost_history
      ;;
    *) die "unknown suite-cost op: ${op:-<none>} (want run, check or history)" ;;
  esac
}

# suite_cost_record: prints the path of the clone's record, under the git
# common directory, made absolute so it holds wherever the caller runs.
suite_cost_record() {
  local d
  d="$(clone_orchestrator_dir)" || return 1
  printf '%s/suite-cost\n' "$d"
}

# suite_cost_active: prints the path of the clone's active-runs directory,
# suite-cost.active beside the record.
suite_cost_active() {
  local rec
  rec="$(suite_cost_record)" || return 1
  printf '%s.active\n' "$rec"
}

# suite_cost_register: registers this orch.sh process's run as active, before
# it is measured, and sets SUITE_COST_MARK to its marker's path, empty when it
# could not register, and SUITE_COST_SAW_LIVE to 1 when another live run's
# marker was present, else 0. Stale markers and .contended files it finds are
# removed, a .contended file whose marker is gone counting as stale whether or
# not its pid is live.
suite_cost_register() {
  local dir me p
  SUITE_COST_MARK="" SUITE_COST_SAW_LIVE=0
  dir="$(suite_cost_active 2>/dev/null)" || return 0
  me="$dir/$$"
  rm -f -- "$me.contended" 2>/dev/null || true
  mkdir -p -- "$dir" 2>/dev/null || return 0
  # written under a first name the sweep never takes for a marker, then moved
  # into place, so a marker appears complete
  SUITE_COST_FIRST="$dir/.$$.new"
  # the mark is set before the move, so a signal landing as the move returns
  # still finds the marker to remove (a missing file is ignored)
  SUITE_COST_MARK="$me"
  # the first name is created under a silenced redirection, so a directory that
  # cannot be written fails quietly; the writer's own orch: line stays on stderr
  { : >"$SUITE_COST_FIRST"; } 2>/dev/null && liveness_record_write "$$" "$SUITE_COST_FIRST" && mv -f -- "$SUITE_COST_FIRST" "$me" 2>/dev/null || {
    rm -f -- "$SUITE_COST_FIRST" 2>/dev/null || true
    SUITE_COST_FIRST="" SUITE_COST_MARK=""
    return 0
  }
  SUITE_COST_FIRST=""
  while IFS= read -r p; do
    SUITE_COST_SAW_LIVE=1
    : 2>/dev/null >"$dir/$p.contended" || true
  done < <(suite_cost_sweep "$dir")
}

# suite_cost_sweep <dir>: the one pass over the active-runs directory <dir>
# that registration and check's pre-check share. Removes each stale marker or
# .contended file - its marker is gone, or holds no live record of its pid
# (the Liveness module's record-alive rule), whether or not the pid is live -
# and prints the pid of each live marker of
# another process, one per line, in glob order. A .contended file is never
# taken for a marker.
suite_cost_sweep() {
  local dir="$1" f name p
  for f in "$dir"/*; do
    name="${f##*/}"
    p="${name%.contended}"
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" != "$$" ] || continue
    if [ ! -e "$dir/$p" ] || ! liveness_marker_alive "$p" "$dir/$p"; then
      rm -f -- "$f" 2>/dev/null || true
    elif [ "$f" = "$dir/$p" ]; then
      printf '%s\n' "$p"
    fi
  done
}

# suite_cost_live_other: prints the pid of the first live marker of another
# process in the active-runs directory and succeeds, else prints nothing and
# fails. The whole directory is swept, so every stale entry is removed, not
# only those before the first live marker. An unresolvable or unreadable
# directory finds no live run.
suite_cost_live_other() {
  local dir live
  dir="$(suite_cost_active 2>/dev/null)" || return 1
  live="$(suite_cost_sweep "$dir")"
  [ -n "$live" ] || return 1
  printf '%s\n' "${live%%$'\n'*}"
}

# suite_cost_unregister: ends the run suite_cost_register began, removing its
# marker and .contended file, and sets SUITE_COST_ISOLATION to solo, overlapped
# (its .contended file existed, or it saw another live run at start) or
# unregistered (it never had a marker).
suite_cost_unregister() {
  if [ -z "$SUITE_COST_MARK" ]; then
    SUITE_COST_ISOLATION=unregistered
    return 0
  fi
  SUITE_COST_ISOLATION=solo
  if [ "$SUITE_COST_SAW_LIVE" -eq 1 ] || [ -e "$SUITE_COST_MARK.contended" ]; then
    SUITE_COST_ISOLATION=overlapped
  fi
  rm -f -- "$SUITE_COST_MARK" "$SUITE_COST_MARK.contended" 2>/dev/null || true
  SUITE_COST_MARK=""
}

# suite_cost_args_ok <arg>...: succeeds unless the command is one argument
# that is empty or only spaces and tabs, which would run nothing.
suite_cost_args_ok() {
  [ $# -ne 1 ] || [[ "$1" == *[!$' \t']* ]]
}

# suite_cost_exec <cmd> [args...]: starts the command, the one place the rule
# lives: exactly one argument is a shell line, run with plain bash -c; two or
# more are an argument list, run as given. Called by suite_cost_measure and by
# the tests' timer fake. `command` keeps the list off orch.sh's own functions.
suite_cost_exec() {
  if [ $# -eq 1 ]; then
    command bash -c "$1"
  else
    command "$@"
  fi
}

# suite_cost_run <cmd> [args...]: runs the command in the current directory,
# its stdout and stderr passed through, and on exit 0 appends its
# record line, its commit <sha>-dirty when the tree had changes as it started -
# unless another suite-cost run overlapped it, or it could not register as
# active, either of which it warns of. Exits with the command's own status,
# except an interrupted run (INT, TERM or HUP sent to orch.sh), which exits 128
# plus the signal's number and records nothing.
suite_cost_run() {
  local commit_field
  commit_field="$(suite_cost_head_commit)"
  suite_cost_interrupt_arm
  suite_cost_register
  suite_cost_measure "$@"
  suite_cost_unregister
  suite_cost_interrupt_disarm
  if suite_cost_require_solo "this run" "its suite cost is not recorded" && [ "$SUITE_COST_STATUS" -eq 0 ]; then
    if [ -n "$commit_field" ]; then
      suite_cost_append "$commit_field" "$SUITE_COST_CPU" "$SUITE_COST_WALL" "$@"
    else
      warn "HEAD names no commit - this run's suite cost is not recorded"
    fi
  fi
  exit "$SUITE_COST_STATUS"
}

# suite_cost_interrupt_arm [<tmp-dir> <worktree> <start-dir> <label>]: starts
# handling INT, TERM and HUP for a measured run and clears the state the
# handler cleans up. The tree run passes its temporary directory, the worktree
# it is about to add, its starting directory and its name in the removal
# warning, before the add, so a signal as the worktree appears is covered
# (the handler skips a worktree that does not exist); suite-cost run passes
# nothing. The handler runs once the foreground command has returned (bash's
# own rule).
suite_cost_interrupt_arm() {
  SUITE_COST_MARK="" SUITE_COST_FIRST="" SUITE_COST_TIMEFILE="" SUITE_COST_TIMETOKEN=""
  SUITE_COST_TREE_TMP="${1:-}" SUITE_COST_TREE_WT="${2:-}" SUITE_COST_TREE_HERE="${3:-}" SUITE_COST_TREE_LABEL="${4:-}"
  trap 'suite_cost_interrupted 129' HUP
  trap 'suite_cost_interrupted 130' INT
  trap 'suite_cost_interrupted 143' TERM
}

# suite_cost_interrupt_disarm: ends the handling suite_cost_interrupt_arm began.
suite_cost_interrupt_disarm() {
  trap - HUP INT TERM
  SUITE_COST_TREE_TMP="" SUITE_COST_TREE_WT="" SUITE_COST_TREE_HERE="" SUITE_COST_TREE_LABEL=""
}

# suite_cost_tree_remove <label> <worktree> <tmp-dir>: removes a tree run's
# worktree and then its temporary directory. Returns 1, after a warning that
# names the command to remove it, when the worktree could not be removed.
suite_cost_tree_remove() {
  if git worktree remove --force "$2" >/dev/null 2>&1; then
    rmdir "$3" 2>/dev/null || true
    return 0
  fi
  warn "could not remove $1's worktree $2 - remove it with: git worktree remove --force $2"
  return 1
}

# suite_cost_timefile_remove: removes SUITE_COST_TIMEFILE when its first line is
# this run's SUITE_COST_TIMETOKEN, so only a file this run made is removed.
suite_cost_timefile_remove() {
  local first=""
  [ -n "$SUITE_COST_TIMEFILE" ] || return 0
  { read -r first <"$SUITE_COST_TIMEFILE"; } 2>/dev/null || true
  [ "$first" != "$SUITE_COST_TIMETOKEN" ] || rm -f -- "$SUITE_COST_TIMEFILE" 2>/dev/null || true
}

# suite_cost_interrupted <status>: the handler. Warns once that the run was
# interrupted - on the caller's stderr even inside the measuring step, where
# stderr is the timing file and fd 3 is the caller's - after removing the run's
# marker, first-name file, contended mark and timing file (failures ignored),
# for a tree run returning to its starting directory and removing its worktree
# and temporary directory (a failed worktree removal is warned of, naming the
# command), and exits <status>, 128 plus the signal's number. A stderr that
# cannot be written changes neither the cleanup nor the exit. Its first act is
# to ignore HUP, INT and TERM, so a second signal cannot cut the cleanup short.
suite_cost_interrupted() {
  local status="$1"
  trap '' HUP INT TERM
  # A dead stderr must not end the handler early: SIGPIPE from a closed pipe is
  # ignored, a failed write is ignored, and the warning follows the cleanup.
  trap '' PIPE
  [ -z "$SUITE_COST_TIMEFILE" ] || [ ! /dev/fd/2 -ef "$SUITE_COST_TIMEFILE" ] || exec 2>&3
  [ -z "$SUITE_COST_MARK" ] || rm -f -- "$SUITE_COST_MARK" "$SUITE_COST_MARK.contended" 2>/dev/null || true
  [ -z "$SUITE_COST_FIRST" ] || rm -f -- "$SUITE_COST_FIRST" 2>/dev/null || true
  suite_cost_timefile_remove
  if [ -n "$SUITE_COST_TREE_WT" ]; then
    cd "$SUITE_COST_TREE_HERE" 2>/dev/null || true
    if [ -e "$SUITE_COST_TREE_WT" ]; then
      suite_cost_tree_remove "$SUITE_COST_TREE_LABEL" "$SUITE_COST_TREE_WT" "$SUITE_COST_TREE_TMP" || true
    else
      rmdir "$SUITE_COST_TREE_TMP" 2>/dev/null || true
    fi
  fi
  warn "this run was interrupted - its suite cost is not recorded" || true
  exit "$status"
}

# suite_cost_require_solo <subject> <tail>: returns 0 when the run just
# unregistered was solo. Otherwise warns "<subject> could not register as
# active - <tail>" (unregistered) or "<subject> overlapped another suite-cost
# run - <tail>" (overlapped) and returns 1.
suite_cost_require_solo() {
  case "$SUITE_COST_ISOLATION" in
    solo) return 0 ;;
    unregistered) warn "$1 could not register as active - $2" ;;
    *) warn "$1 overlapped another suite-cost run - $2" ;;
  esac
  return 1
}

# suite_cost_head_commit: prints the commit field a run started now would
# record - HEAD's full SHA, suffixed -dirty when git status --porcelain prints
# anything - or nothing when HEAD names no commit.
suite_cost_head_commit() {
  local sha
  sha="$(git rev-parse --verify -q HEAD 2>/dev/null || true)"
  if [ -n "$sha" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    note "$sha-dirty"
  else
    note "$sha"
  fi
}

# suite_cost_measure <cmd> [args...]: runs the command once, its stdout,
# stderr and exit code passed through, and sets SUITE_COST_STATUS to its exit
# code, SUITE_COST_CPU to its CPU seconds (user plus system, children
# included) and SUITE_COST_WALL to its wall seconds, both to two places.
# Measured by bash's own time keyword and TIMEFORMAT, so no GNU-only time is
# needed: the report goes to a temp file while the command's stderr goes
# through fd 3 to the caller's. Starts the command through suite_cost_exec.
# The one step ORCH_SUITE_COST_TIMER's file overrides (see the module's end).
suite_cost_measure() {
  local tf real user sys TIMEFORMAT='%2R %2U %2S'
  SUITE_COST_STATUS=0
  # The handler removes SUITE_COST_TIMEFILE, so it is set to the fresh name
  # before the file is made: a signal landing at any point then finds the path
  # and removes the file, or finds nothing to remove. A name at which anything
  # exists is never set. The file's first line is a token only this step knows,
  # and the handler removes the file only when it reads that token back, so a
  # file some other process made at the name between the check and the create
  # is never removed. The creating subshell ignores HUP, INT and TERM, so the
  # token write always follows the create and the handler never meets an empty
  # file. After 10 names with no create, it dies as it always did.
  local try=0 made=""
  SUITE_COST_TIMETOKEN="$$.$RANDOM$RANDOM"
  while [ "$((try += 1))" -le 10 ]; do
    temp_file_name tf
    [[ -e $tf || -L $tf ]] && continue
    SUITE_COST_TIMEFILE="$tf"
    (trap '' HUP INT TERM; umask 077; set -o noclobber; printf '%s\n' "$SUITE_COST_TIMETOKEN" >"$tf") 2>/dev/null &&
      [[ -f $tf && ! -L $tf ]] && { made=1; break; }
    SUITE_COST_TIMEFILE=""
  done
  [ -n "$made" ] || die "could not make a temp file to time the command"
  { time { suite_cost_exec "$@" 2>&3 3>&- || SUITE_COST_STATUS=$?; }; } 3>&2 2>>"$tf"
  read -r real user sys < <(tail -n 1 "$tf") || true
  rm -f "$tf"
  SUITE_COST_TIMEFILE=""
  # A locale may write the decimal point as a comma.
  SUITE_COST_WALL="${real/,/.}"
  SUITE_COST_CPU="$(LC_ALL=C awk -v u="${user/,/.}" -v s="${sys/,/.}" 'BEGIN { printf "%.2f", u + s }')"
}

# suite_cost_append <commit-field> <cpu> <wall> <cmd> [args...]: appends one
# record line, making the record's directory when missing. An append that fails
# warns and records nothing, returning 0: the run it measured stands.
suite_cost_append() {
  local commit_field="$1" cpu="$2" wall="$3" IFS=' '
  shift 3
  suite_cost_append_line "$(suite_cost_record)" "suite-cost record" "this run's suite cost is not recorded" \
    "$commit_field" "$cpu" "$wall" "$(now)" "$*"
}

# suite_cost_append_line <file> <name> <lost> <field>...: appends the fields
# to <file> as one tab-separated line, making its directory when missing. An
# append that fails warns, naming the file as the <name> and saying <lost>,
# and returns 0: what was measured stands.
suite_cost_append_line() {
  local file="$1" name="$2" lost="$3" IFS=$'\t'
  shift 3
  if ! { mkdir -p "${file%/*}" && printf '%s\n' "$*" >>"$file"; } 2>/dev/null; then
    warn "could not append to the $name $file - $lost"
  fi
  return 0
}

# suite_cost_history: prints the record's lines oldest first, as written, or
# nothing when there is no record.
suite_cost_history() {
  local rec
  rec="$(suite_cost_record)"
  [ ! -e "$rec" ] || cat -- "$rec" || die "could not read the suite-cost record $rec"
}

# suite_cost_knob <key> <default>: prints git config <key>, else <default>,
# dying unless it is a non-negative number - read as parallel show reads
# orchestrator.parallel.
suite_cost_knob() {
  local v
  v="$(git config --get "$1" 2>/dev/null || true)"
  [ -n "$v" ] || v="$2"
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
    die "$1 is $v - it must be a non-negative number (git config $1 <n>)"
  note "$v"
}

# suite_cost_base_commit: prints the base commit - state.base_sha inside a
# flow, else what branch base-sha prints - or fails, its reason on stderr. An
# unreadable state.json fails with the shared warning, never the fallback.
suite_cost_base_commit() {
  orch_load state
  local sha="" fphase fsha
  if [ -f "$STATE" ]; then
    state_get_many_in "$STATE" fphase=phase fsha=base_sha || { warn "$STATE_UNREADABLE_MSG"; return 1; }
    [ "$fphase" = "done" ] || sha="$fsha"
  fi
  if [ -z "$sha" ]; then
    sha="$(cmd_branch_base_sha)" || return 1
  fi
  git rev-parse --verify -q "$sha^{commit}" ||
    { warn "base commit $sha names no commit"; return 1; }
}

# suite_cost_head_sets <head_commit> <base_commit> <clean-file> <dirty-file>:
# writes the head side's two commit sets, one full SHA per line, to the two
# empty files, from one history listing, `git rev-list --topo-order --parents`
# of HEAD and the base commit, read to its end with its exit status checked.
# One awk pass over it, children before parents, closes both over the parent
# edges: <dirty-file> gets every commit reachable from HEAD, <clean-file> those
# less the ones reachable from the base commit. A history git cannot list
# fails.
suite_cost_head_sets() {
  local list="" st=0
  [ -n "$1" ] || return 1
  temp_file_make list || return 1
  if git rev-list --topo-order --parents HEAD "$2" >"$list" 2>/dev/null; then
    sc_head="$1" sc_base="$2" sc_clean="$3" sc_dirty="$4" LC_ALL=C awk '
      BEGIN { H[ENVIRON["sc_head"]] = 1; B[ENVIRON["sc_base"]] = 1 }
      {
        order[++n] = $1
        for (i = 2; i <= NF; i++) {
          if ($1 in H) H[$i] = 1
          if ($1 in B) B[$i] = 1
        }
      }
      END {
        for (i = 1; i <= n; i++) {
          c = order[i]
          if (!(c in H)) continue
          print c >>ENVIRON["sc_dirty"]
          if (!(c in B)) print c >>ENVIRON["sc_clean"]
        }
      }' "$list" || st=$?
  else
    st=1
  fi
  rm -f "$list"
  return "$st"
}

# suite_cost_pick <rec> <want> <clean-set file> <dirty-set file>: one pass over
# the record, to its end. Prints "<commit field>TAB<lowest CPU seconds>" for the
# newest record line of the command <want> on the side the sets give - the
# commit field of the last such line, and the lowest sample among the lines of
# that command whose commit field is exactly that one, so a <sha>-dirty line
# and a <sha> one are never pooled - or fails printing nothing. The command is
# everything after the fourth tab, compared whole. A side's lines are a clean
# one whose commit field is in the clean set, or a dirty one whose commit, less
# -dirty, is in the dirty set; a field in neither belongs to no side, a field
# that is not a full SHA git lists included. The sets are read by the pass as
# files of their own: a long history outgrows one environment string.
# The base side's sets are the base commit alone and an empty dirty set: its
# lines are the clean ones whose commit field is the base commit itself, never
# an ancestor of it, and no git process starts. The head side's sets come from
# suite_cost_head_sets: a clean line whose commit is HEAD or an ancestor of it
# but not the base commit nor an ancestor of it - so a run recorded just before
# its commit still counts - or a dirty line whose commit, less -dirty, is HEAD
# or any ancestor of it, the base commit's included, so a run made before a
# ticket's first commit counts.
suite_cost_pick() {
  [ -e "$1" ] || return 1
  # The strings go through ENVIRON, as awk -v would expand their backslashes.
  sc_want="$2" sc_clean="$3" sc_dirty="$4" LC_ALL=C awk '
    BEGIN { FS = "\t" }
    FILENAME == ENVIRON["sc_clean"] { clean[$0] = 1; next }
    FILENAME == ENVIRON["sc_dirty"] { dirty[$0] = 1; next }
    {
      if (!match($0, /^[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t/)) next
      if (substr($0, RLENGTH + 1) != ENVIRON["sc_want"]) next
      f = $1
      if (f ~ /-dirty$/) ok = (substr(f, 1, length(f) - 6) in dirty)
      else ok = (f in clean)
      if (!ok) next
      pick = f
      if (!(f in low) || $2 + 0 < low[f] + 0) low[f] = $2
    }
    END { if (pick == "") exit 1; printf "%s\t%s\n", pick, low[pick] }' \
    "$3" "$4" "$1"
}

# suite_cost_check <cmd> [args...]: prints one verdict line - off, ok,
# grew <pct> - <finding text>, or unmeasured - comparing the head's lowest
# sample of the command with the baseline's: the lowest CPU seconds on the
# commit of the newest head record, and on that of the newest baseline record.
# The knobs are validated first, so a bad one dies before anything runs. The
# command runs to measure a base commit with no clean record of its own, and
# runs on the head only to confirm a growth: a comparison past the threshold
# measures the head at HEAD and then the base at the baseline sample's commit,
# once each, and compares again before it is reported. The head side pools the
# head confirming run with the head sample only when that sample is on HEAD's
# clean SHA, as a -dirty or ancestor one measured another tree.
suite_cost_check() {
  local floor growth rec want base_commit head_cpu head_sha base_cpu base_sha verdict head_field head_commit clean_head line head_pick base_pick have_base clean_set dirty_set IFS=' '
  floor="$(suite_cost_knob orchestrator.suiteCost.floor "$SUITE_COST_FLOOR_DEFAULT")" || exit 1
  growth="$(suite_cost_knob orchestrator.suiteCost.growth "$SUITE_COST_GROWTH_DEFAULT")" || exit 1
  rec="$(suite_cost_record)" || exit 1
  want="$*"
  base_commit="$(suite_cost_base_commit)" || { note unmeasured; return 0; }
  head_field="$(suite_cost_head_commit)"
  head_commit="${head_field%-dirty}"
  clean_head=""
  [ "$head_field" != "$head_commit" ] || clean_head="$head_commit"
  if [ -n "$clean_head" ] &&
    verdict="$(suite_cost_verdict_find)"; then
    note "$verdict"
    return 0
  fi
  temp_file_make clean_set && temp_file_make dirty_set || { rm -f "$clean_set"; note unmeasured; return 0; }
  head_pick="$(suite_cost_head_sets "$head_commit" "$base_commit" "$clean_set" "$dirty_set" &&
    suite_cost_pick "$rec" "$want" "$clean_set" "$dirty_set")" ||
    { rm -f "$clean_set" "$dirty_set"; note unmeasured; return 0; }
  IFS=$'\t' read -r head_sha head_cpu <<<"$head_pick"
  printf '%s\n' "$base_commit" >"$clean_set"
  : >"$dirty_set"
  base_pick="$(suite_cost_pick "$rec" "$want" "$clean_set" "$dirty_set")" && have_base=1 || have_base=""
  rm -f "$clean_set" "$dirty_set"
  if [ -n "$have_base" ]; then
    IFS=$'\t' read -r base_sha base_cpu <<<"$base_pick"
  else
    suite_cost_tree_run base "$base_commit" "$@" || { note unmeasured; return 0; }
    base_cpu="$SUITE_COST_CPU" base_sha="$base_commit"
  fi
  line="$(suite_cost_verdict_line)"
  case "$line" in
    grew*) ;;
    *) note "$line"; return 0 ;;
  esac
  [ -n "$head_commit" ] || { note unmeasured; return 0; }
  suite_cost_tree_run confirm "$head_commit" "$@" || { note unmeasured; return 0; }
  if [ "$head_sha" = "$head_commit" ]; then
    head_cpu="$(suite_cost_min "$head_cpu" "$SUITE_COST_CPU")"
  else
    head_cpu="$SUITE_COST_CPU"
  fi
  suite_cost_tree_run confirm "$base_sha" "$@" || { note unmeasured; return 0; }
  base_cpu="$(suite_cost_min "$base_cpu" "$SUITE_COST_CPU")"
  line="$(suite_cost_verdict_line)"
  note "$line"
  [ -z "$clean_head" ] || suite_cost_verdict_store "$line"
}

# suite_cost_verdict_line: the one compare block (#1401). Compares head_cpu
# with base_cpu and prints the verdict line - off, ok, or grew <pct> -
# <finding text>. Local to suite_cost_check in effect, reading its locals
# through bash's dynamic scope.
suite_cost_verdict_line() {
  local result
  result="$(suite_cost_compare "$head_cpu" "$base_cpu" "$floor" "$growth")"
  case "$result" in
    grew*) note "$result - suite cost grew ${result#grew }% past the ${growth}% threshold: $head_cpu CPU seconds at the head against $base_cpu at baseline commit $base_sha" ;;
    *) note "$result" ;;
  esac
}

# suite_cost_verdicts: prints the path of the clone's verdict record,
# suite-cost.verdicts beside the suite-cost record.
suite_cost_verdicts() {
  local rec
  rec="$(suite_cost_record)" || return 1
  printf '%s.verdicts\n' "$rec"
}

# The verdict key - HEAD's clean SHA, the base commit, the floor, the growth
# and the command string - is read by suite_cost_verdict_find and
# suite_cost_verdict_store from suite_cost_check's locals clean_head,
# base_commit, floor, growth and want, through bash's dynamic scope, so its
# layout is stated once, in the module header.

# suite_cost_verdict_find: prints the verdict of the newest verdict line with
# exactly the verdict key, or fails printing nothing.
suite_cost_verdict_find() {
  local file out
  file="$(suite_cost_verdicts)" || return 1
  [ -e "$file" ] || return 1
  # The key goes through ENVIRON, as awk -v would expand its backslashes.
  out="$(h="$clean_head" b="$base_commit" f="$floor" g="$growth" c="$want" LC_ALL=C awk -F'\t' '
    $1 == ENVIRON["h"] && $2 == ENVIRON["b"] && $3 == ENVIRON["f"] && $4 == ENVIRON["g"] && $6 == ENVIRON["c"] { v = $7; hit = 1 }
    END { if (hit) print v; else exit 1 }' "$file" 2>/dev/null)" || return 1
  printf '%s\n' "$out"
}

# suite_cost_verdict_store <verdict>: appends one verdict line under the
# verdict key, making the directory when missing. A write that fails warns,
# returning 0: the verdict still prints.
suite_cost_verdict_store() {
  suite_cost_append_line "$(suite_cost_verdicts)" "suite-cost verdict record" "this verdict is not stored" \
    "$clean_head" "$base_commit" "$floor" "$growth" "$(now)" "$want" "$1"
}

# suite_cost_compare <head> <base> <floor> <growth>: prints off when <base> is
# below <floor> or zero (possible only with a zero floor, and no growth to
# measure), else grew <pct> when the growth of <head> over <base>, <pct> as a
# whole percent, is past <growth>, else ok.
suite_cost_compare() {
  if float_lt "$2" "$3" || ! float_lt 0 "$2"; then
    note off
    return 0
  fi
  LC_ALL=C awk -v h="$1" -v b="$2" -v g="$4" \
    'BEGIN { p = (h - b) / b * 100; if (p > g) printf "grew %.0f\n", p; else print "ok" }'
}

# suite_cost_min <a> <b>: prints the lower of two CPU seconds, as written.
suite_cost_min() {
  if float_lt "$2" "$1"; then note "$2"; else note "$1"; fi
}

# suite_cost_tree_run <role> <commit> <cmd> [args...]: measures the command
# once in a temporary detached worktree at <commit>, its output sent to stderr
# so check's stdout stays its verdict, records a pass, and removes the
# worktree whatever happened. <role> is base, for the base run check makes
# when the base commit has no clean record, or confirm, for a confirming run;
# it picks the warnings' wording, a confirming run's naming the growth as
# unconfirmed. The measured command runs in the matching directory: the path
# below the worktree's top that the caller's directory has below its
# checkout's top (the top itself when check was started there). A commit with
# no directory at that path starts no setup and no command, records nothing,
# warns naming the commit and directory, and fails. The worktree holds only
# tracked files, so git config orchestrator.suiteCost.setup, when set and
# non-empty, runs first at the worktree's top with bash -c, untimed and its
# output on stderr; a failing setup measures nothing.
# The run is registered as active from its setup to its end, and a passing run
# another suite-cost run overlapped, or that could not register, is not
# recorded and fails, warning which. With no setup, a base run exiting 127
# names that key. Succeeds, SUITE_COST_CPU set, only when the run passed solo
# and the worktree is gone; a failed removal after a pass keeps the record and
# names the left-over worktree.
suite_cost_tree_run() {
  local role="$1" sha="$2" live tmp wt here="$PWD" status=0 setup setup_status=0 cd_failed=0 ran=0 run_label msg_tail msg_no_worktree subdir
  shift 2
  subdir="$(git rev-parse --show-prefix 2>/dev/null || true)"
  subdir="${subdir%/}"
  if [ "$role" = base ]; then
    run_label="the base run" msg_tail="the suite cost is unmeasured"
    msg_no_worktree="could not add a worktree at base commit $sha - $msg_tail"
  else
    run_label="the confirming run" msg_tail="the growth is unconfirmed"
    msg_no_worktree="could not add a worktree for $run_label at $sha - $msg_tail"
  fi
  if live="$(suite_cost_live_other)"; then
    warn "another suite-cost run (pid $live) is in progress - $msg_tail"
    return 1
  fi
  tmp="$(mktemp -d)" || { warn "could not make a temp directory for $run_label"; return 1; }
  wt="$tmp/$role"
  suite_cost_interrupt_arm "$tmp" "$wt" "$here" "$run_label"
  if ! git worktree add -q --detach "$wt" "$sha" >/dev/null 2>&1; then
    warn "$msg_no_worktree"
    rm -rf "$tmp"
    suite_cost_interrupt_disarm
    return 1
  fi
  if [ -n "$subdir" ] && [ ! -d "$wt/$subdir" ]; then
    warn "commit $sha has no directory $subdir for $run_label - $msg_tail"
    status=1
  fi
  setup="$(git config --get orchestrator.suiteCost.setup 2>/dev/null || true)"
  if [ "$status" -ne 0 ]; then
    :
  elif cd "$wt"; then
    suite_cost_register
    [ -z "$setup" ] || bash -c "$setup" >&2 || setup_status=$?
    [ "$setup_status" -ne 0 ] || cd "$wt/$subdir" || cd_failed=1
    [ "$setup_status" -ne 0 ] || [ "$cd_failed" -ne 0 ] || suite_cost_measure "$@" >&2
    suite_cost_unregister
    cd "$here" || die "could not return to $here"
    ran=1
  else
    status=1
  fi
  local record=0
  if [ "$ran" -eq 1 ]; then
    if [ "$setup_status" -eq 0 ] && [ "$cd_failed" -eq 0 ] && [ "$SUITE_COST_STATUS" -eq 0 ]; then
      if suite_cost_require_solo "$run_label at $sha" "$msg_tail"; then
        record=1
      else
        status=1
      fi
    else
      status=1
      if [ "$setup_status" -ne 0 ]; then
        warn "$run_label's setup ($setup) at $sha exited $setup_status - $msg_tail"
      elif [ "$cd_failed" -ne 0 ]; then
        warn "could not enter directory $subdir at $sha for $run_label - $msg_tail"
      elif [ "$role" = base ] && [ "$SUITE_COST_STATUS" -eq 127 ] && [ -z "$setup" ]; then
        warn "$run_label at $sha exited 127 (command not found) - the base worktree holds only tracked files; if the command needs installed dependencies, set git config orchestrator.suiteCost.setup '<install command>'"
      else
        warn "$run_label at $sha exited $SUITE_COST_STATUS - $msg_tail"
      fi
    fi
  fi
  # the handled window ends after the removal: a signal landing once the
  # worktree is gone only removes the temporary directory (the handler checks
  # the worktree exists), and the handling ends before the record is appended
  suite_cost_tree_remove "$run_label" "$wt" "$tmp" || status=1
  suite_cost_interrupt_disarm
  if [ "$record" -eq 1 ]; then
    suite_cost_append "$sha" "$SUITE_COST_CPU" "$SUITE_COST_WALL" "$@"
  fi
  return "$status"
}

# ORCH_SUITE_COST_TIMER is an opt-in test knob in the same spirit as gh.sh's
# ORCH_GH_ADAPTER: a file sourced immediately after the module's functions are
# defined, which overrides only the step that times a command,
# suite_cost_measure. The command still runs for real - its output, exit
# code, setup, worktrees and active-runs markers are unchanged - and only the
# CPU and wall seconds it reports come from the override; the tests' fake is
# scripts/test/suite_cost_timer_fake.sh. Unset - every normal run - nothing is
# sourced and the real bash time measurement runs. It is not a user setting.
if [ -n "${ORCH_SUITE_COST_TIMER:-}" ]; then
  # shellcheck disable=SC1090 # the timer path is chosen at run time, by tests
  source "$ORCH_SUITE_COST_TIMER"
fi
