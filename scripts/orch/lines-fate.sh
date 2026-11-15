# shellcheck shell=bash
# lines-fate.sh - the Lines fate module: a concept module with no orch.sh noun
# of its own, holding what became of a range of a file's lines at a ref since a
# commit filed them - the existence check, the line mapping, the deleted
# ranges, the deleting-commit lookup and its squash walk, and the rule for
# lines that never reached the ref. Only finding triage's scan reads it, through
# lines_fate. It calls git and the primitives no concept owns: no gh adapter and
# nothing of a noun module.
# Sourced by orch.sh, after common.sh and the ROOT block.

# sha> sits at <new ref>, read off the zero-context diff between them. A line
# inside a changed hunk maps to that hunk's start. The awk exits as soon as it
# knows the answer; under pipefail, git diff's SIGPIPE must not fail the call.
map_line() {
  { git -C "$ROOT" diff -U0 "$1" "$2" -- "$3" 2>/dev/null || true; } | awk -v L="$4" '
    /^@@ / {
      split($2, o, ","); split($3, n, ",")
      a = substr(o[1], 2) + 0; b = (2 in o) ? o[2] + 0 : 1
      c = substr(n[1], 2) + 0; d = (2 in n) ? n[2] + 0 : 1
      if (b > 0 && a <= L && L <= a + b - 1) { done = 1; print (c > 0 ? c : 1); exit }
      if ((b > 0 && a + b - 1 < L) || (b == 0 && a < L)) off += d - b
      else exit
    }
    END { if (!done) print L + off }'
}

# deleted_ranges <old sha> <new ref> <file> <start> <end>: the parts of lines
# <start>-<end> of <file> at <old sha> that the zero-context diff to <new ref>
# deletes outright - inside a hunk whose new count is 0 - one "<from>,<to>"
# per part, or nothing. A line a hunk replaces is not deleted by this rule.
deleted_ranges() {
  { git -C "$ROOT" diff -U0 "$1" "$2" -- "$3" 2>/dev/null || true; } | awk -v S="$4" -v E="$5" '
    /^@@ / {
      split($2, o, ","); split($3, n, ",")
      a = substr(o[1], 2) + 0; b = (2 in o) ? o[2] + 0 : 1
      d = (2 in n) ? n[2] + 0 : 1
      if (a > E) exit
      if (b > 0 && d == 0) {
        lo = (a > S) ? a : S; hi = (a + b - 1 < E) ? a + b - 1 : E
        if (lo <= hi) print lo "," hi
      }
    }'
}

# range_differs <old sha> <new ref> <file> <start> <end>: prints 1 when lines
# <start>-<end> of <file> at <old sha> differ from <new ref> - a hunk of the
# zero-context diff removes or replaces one of them, or inserts lines between
# two of them - and nothing otherwise. Lines inserted before the first line
# or after the last do not make the range differ.
range_differs() {
  { git -C "$ROOT" diff -U0 "$1" "$2" -- "$3" 2>/dev/null || true; } | awk -v S="$4" -v E="$5" '
    /^@@ / {
      split($2, o, ",")
      a = substr(o[1], 2) + 0; b = (2 in o) ? o[2] + 0 : 1
      if (a > E) exit
      if ((b > 0 && a + b - 1 >= S) || (b == 0 && a >= S && a < E)) { print 1; exit }
    }'
}

# range_segments <start> <end> <ranges>: the runs of lines <start>-<end> the
# newline-separated "<from>,<to>" <ranges> leave out, one "<from>,<to>" per
# run, or nothing.
range_segments() {
  local l range hit open=false st last
  for ((l = $1; l <= $2; l++)); do
    hit=false
    for range in $3; do
      if [ "$l" -ge "${range%,*}" ] && [ "$l" -le "${range#*,}" ]; then hit=true; break; fi
    done
    if ! $hit; then
      $open || { st="$l"; open=true; }
      last="$l"
    elif $open; then
      printf '%s,%s\n' "$st" "$last"; open=false
    fi
  done
  if $open; then printf '%s,%s\n' "$st" "$last"; fi
}

# held_lines <old sha> <commit> <file> <ranges>: succeeds when <commit> holds
# some line of the newline-separated <ranges>, lines of <file> at <old sha>:
# the zero-context diff from <old sha> to <commit> does not delete it outright.
held_lines() {
  local start end deleted range
  start="${4%%$'\n'*}"; start="${start%%,*}"
  end="${4##*$'\n'}"; end="${end#*,}"
  deleted="$(deleted_ranges "$1" "$2" "$3" "$start" "$end")"
  for range in $4; do
    [ -z "$(range_segments "${range%,*}" "${range#*,}" "$deleted")" ] || return 0
  done
  return 1
}

# merge_base_holds <old sha> <ref> <file> <ranges>: succeeds when the merge
# base of <old sha> and <ref> holds some line of the <ranges>, lines of <file>
# at <old sha>.
merge_base_holds() {
  local base
  base="$(git -C "$ROOT" merge-base "$1" "$2" 2>/dev/null)" && held_lines "$1" "$base" "$3" "$4"
}

# ever_held <old sha> <ref> <file> <ranges>: succeeds when some line of the
# <ranges>, lines of <file> at <old sha>, a commit off <ref>, was held by the
# merge base of the two or by a commit on <ref> since it - fails for lines
# that never reached <ref>. A lookup that fails (no merge base, a log that
# cannot run) succeeds too: it proves nothing about the lines, so the caller
# keeps its stand-in.
ever_held() {
  local old="$1" ref="$2" file="$3" ranges="$4" base commits commit
  base="$(git -C "$ROOT" merge-base "$old" "$ref" 2>/dev/null)" || return 0
  held_lines "$old" "$base" "$file" "$ranges" && return 0
  commits="$(git -C "$ROOT" log --format=%H "$ref" "^$old" -- "$file" 2>/dev/null)" || return 0
  for commit in $commits; do
    held_lines "$old" "$commit" "$file" "$ranges" && return 0
  done
  return 1
}

# squash_deleting_commit <old sha> <ref> <file> <ranges>: the commit on
# <ref>'s first-parent line that deleted the newest of the <ranges> - lines of
# <file> at <old sha>, a commit off <ref>, deleted by <ref> - or nothing. Off
# the default branch, the lines reached it through a squash commit, so the
# deleting commit is the newest one since which every line stays deleted:
# walking back, the one after the first commit that still holds one of them.
squash_deleting_commit() {
  local old="$1" ref="$2" file="$3" ranges="$4" commits commit after=""
  commits="$(git -C "$ROOT" log --first-parent --format=%H "$ref" "^$old" -- "$file" 2>/dev/null)" || return 0
  for commit in $commits; do
    if held_lines "$old" "$commit" "$file" "$ranges"; then printf '%s\n' "$after"; return 0; fi
    after="$commit"
  done
  # No commit since the merge base holds any of them: the merge base held them
  # when the oldest commit touching the file deleted them.
  if merge_base_holds "$old" "$ref" "$file" "$ranges"; then printf '%s\n' "$after"; fi
}

# deleting_commit <old sha> <ref> <file> <ranges>: the commit that deleted
# the <ranges>, lines of <file> at <old sha> that <ref> no longer has - the
# newest such commit when they were deleted by several - or nothing when the
# exact lookup fails. A reverse blame names, for each line, the commit C it
# last existed in, and its deleting commit is the oldest since C to touch the
# file.
deleting_commit() {
  local old="$1" ref="$2" file="$3" ranges="$4" ref_sha range blame_out last_seen last since_last deleter deleters="" commit off_branch=false
  ref_sha="$(git rev-parse --verify -q "$ref^{commit}")" || return 0
  for range in $ranges; do
    blame_out="$(git -C "$ROOT" blame --reverse --porcelain -L "$range" "$old..$ref" -- "$file" 2>/dev/null)" || return 0
    last_seen="$(printf '%s\n' "$blame_out" | grep -E '^[0-9a-f]{40} [0-9]' | cut -d' ' -f1 | sort -u)" || true
    [ -n "$last_seen" ] || return 0
    for last in $last_seen; do
      [ "$last" != "$ref_sha" ] || return 0
      if ! git merge-base --is-ancestor "$last" "$ref" 2>/dev/null; then off_branch=true; continue; fi
      since_last="$(git -C "$ROOT" log --reverse --format=%H "$ref" "^$last" -- "$file" 2>/dev/null)" || return 0
      deleter="${since_last%%$'\n'*}"
      [ -n "$deleter" ] || return 0
      deleters="$deleters $deleter"
    done
  done
  if $off_branch; then
    deleter="$(squash_deleting_commit "$old" "$ref" "$file" "$ranges")"
    [ -n "$deleter" ] || return 0
    deleters="$deleters $deleter"
  fi
  for commit in $(git -C "$ROOT" log --format=%H "$ref" "^$old" -- "$file" 2>/dev/null); do
    if word_listed "$deleters" "$commit"; then printf '%s\n' "$commit"; return 0; fi
  done
}

# scan_line <file:lines> <result> <detail>: the scan's one line, in the
# columns `finding-triage scan` prints. Local to finding_scan_one in effect: it
# reads the issue and PR number and the triage state, n, pr and roles, from
# that call's locals, through bash's dynamic scope, and prints - for an empty

# lines_fate <filed sha> <ref> <file> <start> <end> <result-var> <detail-var>:
# what became of lines <start>-<end> of <file> (repo-root-relative) at <filed
# sha>, a commit already in the clone, at <ref>. Prints nothing; sets the two
# named variables in the caller's shell: the fate - gone (the file is not at
# <ref>), unchanged, changed (the detail is the full SHA of a commit that
# touched or deleted the lines, or stands in for lines that cannot be
# followed) or never-reached (the lines differ only by commits that never
# reached <ref>) - and the detail, empty unless changed. Returns 0 whatever
# git does; each git failure takes its stand-in, as the comments below say.
# Its locals carry a __lf_ prefix so a caller's variable names never collide.
lines_fate() {
  local __lf_old="$1" __lf_ref="$2" __lf_file="$3" __lf_start="$4" __lf_end="$5"
  local __lf_fate="" __lf_detail="" __lf_file_commit __lf_log_out __lf_deleted __lf_seg
  local __lf_new_start __lf_new_end __lf_off_default=false
  local -a __lf_largs=()
  if ! git cat-file -e "$__lf_ref:$__lf_file" 2>/dev/null; then
    __lf_fate=gone
  elif git -C "$ROOT" diff --quiet "$__lf_old" "$__lf_ref" -- "$__lf_file" 2>/dev/null; then
    __lf_fate=unchanged
  else
    # The newest commit since the filing that touched the file: the stand-in
    # when the exact lookup fails.
    __lf_file_commit="$(git -C "$ROOT" log -1 --format=%H "$__lf_ref" "^$__lf_old" -- "$__lf_file" 2>/dev/null)" || true
    # Off the ref's history, a difference no commit on it made is the filed
    # SHA's own commits, never on it: the finding's lines decide, not its file.
    git merge-base --is-ancestor "$__lf_old" "$__lf_ref" 2>/dev/null || __lf_off_default=true
    # Filed lines deleted outright are changed, whatever the lines around them
    # say: named by the commit that deleted them, or, when that lookup fails,
    # by the newest commit touching the file - unless an off-ref SHA's deleted
    # lines no commit on the ref ever held: then the rest of the lines are
    # followed, and a lookup finding no commit is never-reached.
    __lf_deleted="$(deleted_ranges "$__lf_old" "$__lf_ref" "$__lf_file" "$__lf_start" "$__lf_end")"
    if [ -n "$__lf_deleted" ]; then
      if $__lf_off_default && ! ever_held "$__lf_old" "$__lf_ref" "$__lf_file" "$__lf_deleted"; then
        # No commit on the ref ever held the deleted lines: follow the rest.
        for __lf_seg in $(range_segments "$__lf_start" "$__lf_end" "$__lf_deleted"); do
          __lf_new_start="$(map_line "$__lf_old" "$__lf_ref" "$__lf_file" "${__lf_seg%,*}")"
          __lf_new_end="$(map_line "$__lf_old" "$__lf_ref" "$__lf_file" "${__lf_seg#*,}")"
          [ "$__lf_new_end" -ge "$__lf_new_start" ] || __lf_new_end="$__lf_new_start"
          __lf_largs+=(-L "$__lf_new_start,$__lf_new_end:$__lf_file")
        done
        [ "${#__lf_largs[@]}" -ne 0 ] || __lf_fate=never-reached
      else
        __lf_detail="$(deleting_commit "$__lf_old" "$__lf_ref" "$__lf_file" "$__lf_deleted")"
        __lf_detail="${__lf_detail:-$__lf_file_commit}"
        if [ -n "$__lf_detail" ]; then __lf_fate=changed; else __lf_fate=never-reached; fi
      fi
    else
      __lf_new_start="$(map_line "$__lf_old" "$__lf_ref" "$__lf_file" "$__lf_start")"
      __lf_new_end="$(map_line "$__lf_old" "$__lf_ref" "$__lf_file" "$__lf_end")"
      [ "$__lf_new_end" -ge "$__lf_new_start" ] || __lf_new_end="$__lf_new_start"
      __lf_largs=(-L "$__lf_new_start,$__lf_new_end:$__lf_file")
    fi
    if [ -z "$__lf_fate" ]; then
      # The newest commit since the filing that touched the finding's lines.
      # The output is captured whole before filtering and given to grep -m1 as
      # a herestring: piping it into grep -m1 or head could SIGPIPE the writer
      # and pass for a failure under pipefail.
      if __lf_log_out="$(git -C "$ROOT" log -1 --format=%H "${__lf_largs[@]}" "$__lf_ref" "^$__lf_old" 2>/dev/null)"; then
        __lf_detail="$(grep -m1 -Ex '[0-9a-f]{40}' <<<"$__lf_log_out")" || true
        if [ -n "$__lf_detail" ]; then
          __lf_fate=changed
        elif $__lf_off_default && [ -n "$(range_differs "$__lf_old" "$__lf_ref" "$__lf_file" "$__lf_start" "$__lf_end")" ]; then
          # The lines were followed and nothing since the filing touched them,
          # but the lines themselves differ, by commits that never reached the
          # ref.
          __lf_fate=never-reached
        else
          # The file changed only elsewhere.
          __lf_fate=unchanged
        fi
      else
        # A range starting past the file's end can't be followed: the newest
        # commit touching the file stands in.
        __lf_detail="$__lf_file_commit"
        if [ -n "$__lf_detail" ]; then __lf_fate=changed; else __lf_fate=never-reached; fi
      fi
    fi
  fi
  [ "$__lf_fate" = changed ] || __lf_detail=""
  printf -v "$6" '%s' "$__lf_fate"
  printf -v "$7" '%s' "$__lf_detail"
}
