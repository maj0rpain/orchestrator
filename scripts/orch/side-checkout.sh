# shellcheck shell=bash
# side-checkout.sh - orch.sh's side-checkout command, the finished sweep
# (side-checkout prune) included.
# Its tests: scripts/test/orch/side-checkout.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# A side checkout: a worktree the plugin makes under the main checkout's
# .orchestrator/checkouts/, so a second flow or a quick implementation runs
# beside the work in this checkout, in a session of its own (ADR-0037). The
# ownership marker in the worktree's own git folder - which git deletes with
# the worktree - is what makes it one; a flow's state file is not, since a
# hand-made worktree can hold a flow too.

# The ownership marker's file name, in the worktree's own git folder.
readonly SIDE_CHECKOUT_MARKER="orchestrator-side-checkout"

# side_checkout_marked <git-dir>: whether the git folder <git-dir> holds the
# ownership marker - the one place the marker's presence is tested.
side_checkout_marked() { [ -f "$1/$SIDE_CHECKOUT_MARKER" ]; }

# side_checkout_marker <path>: prints the ownership marker's path for the
# worktree at <path>; returns 1 when it carries none.
side_checkout_marker() {
  local gd
  gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" \
    && side_checkout_marked "$gd" && printf '%s\n' "$gd/$SIDE_CHECKOUT_MARKER"
}

# is_side_checkout <path>: whether the checkout holding <path> is a side
# checkout, as the walk classifies it (see checkout_kind) - a ticket worktree
# carrying a copied marker is none. False when the walk fails.
is_side_checkout() { [ "$(checkout_kind "$1")" = side ]; }

# --- the finished sweep ---
#
# Finished is read from GitHub's PR state, never git ancestry: a squash or
# rebase merge never makes the branch an ancestor of its base (ADR-0037). The
# verdicts below assign to the caller's `verdict` and `branch`, which bash
# scopes dynamically, and return 0 finished, 1 not finished - `verdict` the
# reason - or 2 the verdict could not be read, GitHub or the checkout's own
# git status - `verdict` naming which, and its error.

# finished_flow <state-file>: whether that flow is finished - at done, and its
# recorded PR merged into its own base branch. It also assigns the caller's
# `merged_prs`: the merged PR's number, a tab, its head SHA - the one line
# side_checkout_finished judges the branch tip against.
finished_flow() {
  local state="$1" phase pr base pr_state _is_draft shown_state merged_head _head_ref merged_base _commits err
  phase="$(state_get_in "$state" phase)"
  if [ "$phase" != "done" ]; then
    verdict="flow $(state_get_in "$state" slug) is at $phase, not done"; return 1
  fi
  branch="$(state_get_in "$state" branch)"
  [ -n "$branch" ] || { verdict="no branch"; return 1; }
  pr="$(state_get_in "$state" pr)"
  [ -n "$pr" ] || { verdict="no PR recorded"; return 1; }
  base="$(flow_base_in "$state")" \
    || { verdict="could not read the base branch from $state"; return 2; }
  pr_state_draft_read "$pr" pr_state _is_draft err \
    || { verdict="could not read GitHub: $(gh_reason "$err")"; return 2; }
  if [ "$pr_state" != MERGED ]; then
    state_word shown_state "$pr_state"
    verdict="PR #$pr is $shown_state"; return 1
  fi
  pr_refs_read "$pr" merged_head _head_ref merged_base _commits err \
    || { verdict="could not read GitHub: $(gh_reason "$err")"; return 2; }
  [ "$merged_base" = "$base" ] || { verdict="PR #$pr merged into $merged_base, not $base"; return 1; }
  # shellcheck disable=SC2034 # read by side_checkout_finished
  merged_prs="$pr"$'\t'"$merged_head"
}

# tip_covered <path> <branch> <merged-prs>: whether the branch's local tip is
# held by a merged PR - equal to its head SHA or an ancestor of it. The
# merged PRs are lines of a number, a tab and a head SHA, newest first; any
# covering head is enough. Returns 0 covered; 1 not, `verdict` naming the
# newest PR whose head is missing from this repo (the sweep never fetches), or
# else the newest PR; 2 when git cannot judge a head that is present.
tip_covered() {
  local path="$1" branch="$2" prs="$3" tip n head rc first_n="" first_head="" miss_n="" miss_head=""
  tip="$(git -C "$path" rev-parse --verify -q "refs/heads/$branch^{commit}")" \
    || { verdict="could not read the tip of $branch"; return 2; }
  while IFS=$'\t' read -r n head; do
    [ -n "$n" ] || continue
    [ -n "$first_n" ] || { first_n="$n"; first_head="$head"; }
    if [ -z "$head" ] || ! git -C "$path" cat-file -e "$head^{commit}" 2>/dev/null; then
      [ -n "$miss_n" ] || { miss_n="$n"; miss_head="$head"; }
      continue
    fi
    [ "$tip" != "$head" ] || return 0
    rc=0; git -C "$path" merge-base --is-ancestor "$tip" "$head" 2>/dev/null || rc=$?
    case "$rc" in
      0) return 0 ;;
      1) ;;
      *) verdict="could not compare $branch with PR #$n's head ${head:0:7}"; return 2 ;;
    esac
  done <<<"$prs"
  if [ -n "$miss_n" ]; then
    verdict="$branch: PR #$miss_n's head ${miss_head:0:7} is not in this repo - fetch it to let the sweep judge"
  else
    verdict="$branch has commits past PR #$first_n's merged head ${first_head:0:7}"
  fi
  return 1
}

# side_checkout_finished <path>: whether the side checkout there is finished -
# a clean tree, and either a finished flow, or no flow and a PR merged from
# its checked-out branch into the base branch off recorded for it (see
# recorded_base) - and the branch's tip held by a merged PR (tip_covered), so
# the sweep's branch -D never drops a commit. A git status that cannot run
# returns 2, as an unreadable GitHub does, so the sweep removes nothing on a
# tree it could not read.
# verdict is read by its callers, side-checkout prune, below, and
# doctor.sh.
# shellcheck disable=SC2034
side_checkout_finished() {
  local path="$1" base prs st err merged_prs=""
  st="$(tree_status "$path")" || { verdict="$st"; return 2; }
  if [ -n "$st" ]; then
    verdict="uncommitted changes or untracked files"; return 1
  fi
  if checkout_has_flow "$path"; then
    finished_flow "$(flow_state_file "$path")" || return
    tip_covered "$path" "$branch" "$merged_prs"; return
  fi
  branch="$(checkout_branch "$path")" \
    || { verdict="no branch"; return 1; }
  base="$(recorded_base "$branch")"
  capture prs err adapter_prs_merged "$branch" "$base" \
    || { verdict="could not read GitHub: $(gh_reason "$err")"; return 2; }
  [ -n "$prs" ] || { verdict="no merged PR from $branch into $base"; return 1; }
  tip_covered "$path" "$branch" "$prs"
}

# archive_root <root>: prints the checkout whose .orchestrator/archive/
# receives the flow in the checkout at <root> - the one computation of the
# rule. A side checkout's flow goes to the main checkout's archive; any other
# checkout, a ticket or hand-made worktree included, archives in place. Reads
# the walk's kind itself, so it fails, printing nothing, when the walk fails or
# when <root> is a side checkout and the main checkout cannot be read - never
# archiving a side checkout's flow in place.
archive_root() {
  local kind
  kind="$(checkout_kind "$1")" || return 1
  if [ "$kind" = side ]; then main_checkout; else printf '%s\n' "$1"; fi
}

# FLOW_LESS_ENTRIES: the top-level entries under .orchestrator/ that belong
# to no flow, which archive_flow leaves in place: the archive itself, the side
# checkouts, and the working directories of a standalone spec review
# (spec-review/<n>/, an unattended one included) and of a review pass
# (review-pass/<branch>/). The rule: an entry a command creates for work that
# belongs to no flow goes on this list; every other entry is the flow's, a
# spec phase's freely named round directories and a flow's spec review round
# directories (spec-rounds/<k>/) included. The round marker lives in the
# handoff folder, so it goes with it.
FLOW_LESS_ENTRIES=(archive checkouts spec-review review-pass)

# archive_flow <root> <archive-root>: moves the flow in the checkout at <root>
# into a directory under <archive-root>'s .orchestrator/archive/, and prints
# that directory - relative to this checkout when inside it, else in full.
# <archive-root> is the caller's: a side checkout's flow goes to the main
# checkout's archive; any other checkout, a hand-made worktree included,
# archives in place (see archive_root).
#
# Every step checks its own status, since its callers run it where errexit is
# off: a failed slug read, archive-directory creation or move dies naming the
# path. state.json moves last, so a move failing partway leaves the flow
# recognisable where it stands - the entries already moved stay in the new
# archive directory, the rest in place, the message naming both - and a rerun
# archives what is left into a fresh directory. There is no rollback.
archive_flow() {
  local root="$1" orch="$1/$ORCH_DIR_NAME" home="$2/$ORCH_DIR_NAME" state slug dest entry kept i
  local entries=() moved
  state="$(flow_state_file "$root")"
  refuse_ticket_worktrees "$root"
  slug="$(state_get_in "$state" slug)" || die "could not read the flow's slug from $state - nothing was archived"
  dest="$home/archive/$(dir_stamp)-$slug"
  mkdir -p "$dest" 2>/dev/null || die "could not create the archive directory $dest - nothing was archived"
  for entry in "$orch"/*; do
    [ -e "$entry" ] || continue
    for kept in "${FLOW_LESS_ENTRIES[@]}"; do
      [ "$(basename "$entry")" = "$kept" ] && continue 2
    done
    [ "$entry" = "$state" ] || entries+=("$entry")
  done
  [ ! -e "$state" ] || entries+=("$state")
  for i in "${!entries[@]}"; do
    if ! mv "${entries[i]}" "$dest/" 2>/dev/null; then
      moved="${entries[*]:0:i}"
      die "could not move ${entries[i]} into $dest - moved there: ${moved:-nothing}; left in place: ${entries[*]:i}"
    fi
  done
  note "${dest#"$ROOT"/}"
}

# Tells the human to close the session when this command ran in <here>, inside
# <path>, a worktree just removed: the session's working directory is gone.
side_checkout_close_note() {
  case "$2/" in
    "$1"/*) note "This session's working directory was that side checkout, and it is gone - close this session." ;;
  esac
}

# side_checkout_remove_worktree <path> <main-root> <here> <die|warn>: removes
# the side checkout at <path>, through the main checkout at <main-root>, never
# with force - the one site of a side checkout's teardown and of its refusal
# message. Then notes the removal and, when <here> (the directory the command
# ran in, read before the removal) was inside <path>, tells the human to close
# the session. A refusal dies under `die`; under `warn` it warns and returns 1.
side_checkout_remove_worktree() {
  local path="$1" main_root="$2" here="$3" policy="$4" err msg
  if ! err="$(git -C "$main_root" worktree remove "$path" 2>&1)"; then
    msg="could not remove side checkout $path: ${err%%$'\n'*} - left as it stands. Commit or discard its changes, then run orch.sh side-checkout remove $(basename "$path")."
    if [ "$policy" = die ]; then die "$msg"; fi
    warn "$msg"; return 1
  fi
  note "removed side checkout $path"
  side_checkout_close_note "$path" "$here"
}

# side_checkout_archive_and_remove <path> <main-root> <here> <policy>: the one
# site of ADR-0037's order - the flow in the side checkout at <path>, if any,
# is archived into the main checkout at <main-root> first, and only then is the
# worktree removed (see side_checkout_remove_worktree for <here> and
# <policy>). archive_flow runs in a subshell, its output kept in the caller's
# `archive_out` (bash scopes it dynamically), and noted on success. Returns 0
# removed, 1 removal refused under `warn`, 2 the archive failed - nothing
# removed, whatever the policy.
side_checkout_archive_and_remove() {
  local path="$1" main_root="$2" here="$3" policy="$4"
  archive_out=""
  if checkout_has_flow "$path"; then
    archive_out="$(archive_flow "$path" "$main_root" 2>&1)" || return 2
    note "$archive_out"
  fi
  side_checkout_remove_worktree "$path" "$main_root" "$here" "$policy"
}

# side_checkout_archive_and_remove_or_exit <path> <main-root> <here> <policy>:
# the CLI callers' shape of side_checkout_archive_and_remove - a failed archive
# relays its kept error through die, everything through its first `orch: `
# stripped so it carries one prefix; otherwise it returns the helper's status
# (0 removed, 1 removal refused under `warn`).
side_checkout_archive_and_remove_or_exit() {
  local archive_out rc=0
  side_checkout_archive_and_remove "$@" || rc=$?
  if [ "$rc" -eq 2 ]; then die "${archive_out#*orch: }"; fi
  return "$rc"
}

# side_checkouts_dir <main-root>: where the side checkouts of the main
# checkout at <main-root> live.
side_checkouts_dir() { printf '%s/%s/checkouts\n' "$1" "$ORCH_DIR_NAME"; }

# side_checkout_issue <path>: prints the issue the side checkout at <path>
# records in its marker; returns 1 when it is no side checkout - a ticket
# worktree carrying a copied marker included, checked before the marker is
# read - or its marker holds no plain issue number.
side_checkout_issue() {
  local marker issue
  is_side_checkout "$1" || return 1
  marker="$(side_checkout_marker "$1")" || return 1
  issue="$(cat "$marker" 2>/dev/null)" || return 1
  case "$issue" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$issue"
}

# side_checkout_for_issue <issue>: prints the path of the side checkout
# whose marker records <issue>; returns 1 when there is none.
side_checkout_for_issue() {
  local list kind _flow _branch path
  list="$(checkouts)" || return 1
  while read -r kind _flow _branch path; do
    [ "$kind" = side ] || continue
    if [ "$(side_checkout_issue "$path" 2>/dev/null)" = "$1" ]; then printf '%s\n' "$path"; return 0; fi
  done <<<"$list"
  return 1
}

# Adds a worktree on no branch at origin/<base>, the base branch in effect,
# freshly fetched: git refuses one branch in two worktrees, and the main
# checkout usually holds the base. --issue N is written into the marker, so a
# session opened there picks up the quick implementation's issue. A bad
# --issue or a failed fetch dies before any worktree exists; a failed marker
# write takes the fresh worktree back out.
cmd_side_checkout_add() {
  local usage="usage: orch.sh side-checkout add <slug> [--issue N]"
  local slug="${1:-}" issue="" path base gd main_root
  [ -n "$slug" ] || die "$usage"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue)
        issue="${2:-}"
        [ -n "$issue" ] || die "$usage"
        case "$issue" in
          *[!0-9]*) die "--issue wants a plain issue number, got: $issue" ;;
        esac
        shift 2 ;;
      *) die "unknown side-checkout add flag: $1 (want --issue)" ;;
    esac
  done
  slug="$(normalize_slug "$slug")"
  main_root="$(main_checkout_or_die)" || exit $?
  # The sweep first, its report on stderr so stdout stays the path alone. A
  # failed sweep never stops add; it may have removed the checkout this ran
  # in, so add carries on from the main checkout.
  ( cmd_side_checkout_prune ) >&2 \
    || warn "the finished sweep failed - carrying on with add"
  cd "$main_root" || die "could not enter the main checkout $main_root"
  path="$(side_checkouts_dir "$main_root")/$slug"
  [ ! -e "$path" ] || die "side checkout $path already exists"
  exclude_orch_dirs
  base="$(base_branch)"
  git fetch --quiet origin "$base" 2>/dev/null \
    || die "could not fetch base branch $base from origin - no side checkout was made"
  git worktree add -q --detach "$path" "origin/$base" \
    || die "could not add side checkout $path"
  if ! gd="$(git -C "$path" rev-parse --absolute-git-dir)" \
     || ! printf '%s' "${issue:+$issue$'\n'}" 2>/dev/null >"$gd/$SIDE_CHECKOUT_MARKER"; then
    # A freshly added worktree holds nothing of anyone's, so no force is needed.
    git worktree remove "$path" 2>/dev/null || true
    die "could not write the side-checkout marker - removed $path again"
  fi
  note "$path"
}

# Prints one line per side checkout - worktrees carrying the marker, and no
# other: <slug> <path>, then what it holds (see checkout_holding).
cmd_side_checkout_list() {
  [ $# -eq 0 ] || die "usage: orch.sh side-checkout list"
  local list kind _flow _branch path issue quick
  list="$(checkouts_or_die)" || exit $?
  while read -r kind _flow _branch path; do
    [ "$kind" = side ] || continue
    quick=""
    if issue="$(side_checkout_issue "$path")"; then quick=" quick #$issue"; fi
    note "${path##*/} $path $(checkout_holding "$path")$quick"
  done <<<"$list"
}

# Prints the issue the current side checkout records (see side-checkout add
# --issue); exits 1 in a checkout that is no side checkout or records none,
# and 2 on a usage error, so a caller never reads one as the other.
cmd_side_checkout_issue() {
  [ $# -eq 0 ] || die2 "usage: orch.sh side-checkout issue"
  side_checkout_issue "$(pwd -P)" \
    || die "this checkout is no side checkout recording an issue"
}

# Removes side checkout <slug> by hand, never with force. Every refusal - an
# unknown slug, a worktree without the marker, uncommitted changes or
# untracked files, a ticket worktree left inside it - runs before anything
# moves. Then any flow is archived into the main checkout, and the worktree is
# removed; if that still fails, the archive stands and remove exits 1. The
# branch is left in place.
cmd_side_checkout_remove() {
  [ $# -eq 1 ] || die "usage: orch.sh side-checkout remove <slug>"
  local slug path here main_root dirs
  here="$(pwd -P)"
  slug="$(normalize_slug "$1")"
  main_root="$(main_checkout_or_die)" || exit $?
  path="$(side_checkouts_dir "$main_root")/$slug"
  # One rev-parse for both reads: the top level on the first line, the git
  # folder that holds the marker (see side_checkout_marked) on the second.
  dirs="$(git -C "$path" rev-parse --show-toplevel --absolute-git-dir 2>/dev/null)" || dirs=""
  [ "${dirs%%$'\n'*}" = "$path" ] \
    || die "no side checkout $slug at $path"
  side_checkout_marked "${dirs#*$'\n'}" \
    || die "$path carries no side-checkout marker - it is not the plugin's to remove, so it is left alone"
  require_clean_tree "$path" \
    "side checkout $path has uncommitted changes or untracked files - commit or discard them first; it is never removed with force"
  # archive_flow refuses ticket worktrees itself before anything moves, so
  # the refusal runs here only when there is no flow to archive.
  checkout_has_flow "$path" || refuse_ticket_worktrees "$path"
  side_checkout_archive_and_remove_or_exit "$path" "$main_root" "$here" die
}

# The sweep behind /orchestrator:finish. Every verdict is read first, so a
# GitHub that cannot be read removes nothing at all. Then each finished side
# checkout, in git's order, has its flow archived into the main checkout, its
# worktree removed - never with force - and its local branch deleted with -D,
# which -d would refuse for a squash merge; a failure is reported, that
# checkout left as it stands, and the sweep moves on. The main checkout's
# finished flow is archived in place, its branch left checked out. A hand-made
# worktree holding a flow is reported and left alone.
cmd_side_checkout_prune() {
  [ $# -eq 0 ] || die "usage: orch.sh side-checkout prune"
  local here main_root path line entry verdict branch rc teardown_rc unread=0 failed=0
  # archive_out is the main checkout entry's archive_flow output - its note,
  # or its error - cleared at the top of each entry so none outlives its own;
  # a side checkout's is cleared by side_checkout_archive_and_remove.
  local archive_out branch_err
  local list kind flow _branch walk=() finished=()
  here="$(pwd -P)"
  # The walk lists the main checkout first.
  list="$(checkouts)" && main_root="$(checkouts_main "$list")" \
    || die "could not read the checkouts - nothing was removed"
  mapfile -t walk <<<"$list"
  # Every step works from the main checkout, so removing the checkout this
  # command ran in leaves the sweep somewhere to stand.
  cd "$main_root" || die "could not enter the main checkout $main_root"
  for line in "${walk[@]}"; do
    read -r kind flow _branch path <<<"$line"
    rc=0; verdict=""; branch=""
    case "$kind" in
      main)
        [ "$flow" = 1 ] || continue
        finished_flow "$(flow_state_file "$path")" </dev/null || rc=$? ;;
      side)
        side_checkout_finished "$path" </dev/null || rc=$? ;;
      *)
        [ "$flow" = 1 ] || continue
        note "$path: not a side checkout, left alone"; continue ;;
    esac
    case "$rc" in
      0) finished+=("$path"$'\t'"$branch") ;;
      1) note "skipped $path: $verdict" ;;
      *) warn "could not check $path: $verdict"; unread=$((unread + 1)) ;;
    esac
  done
  [ "$unread" -eq 0 ] || die "$unread checkout(s) could not be checked - nothing was removed"
  [ "${#finished[@]}" -gt 0 ] || { note "no finished side checkouts"; return 0; }
  for entry in "${finished[@]}"; do
    path="${entry%%$'\t'*}"; branch="${entry#*$'\t'}"
    archive_out=""
    if [ "$path" = "$main_root" ]; then
      if ! archive_out="$(archive_flow "$path" "$main_root" 2>&1)"; then
        warn "could not archive the main checkout's flow: $(err_line "$archive_out")"; failed=1; continue
      fi
      note "$archive_out"
      note "archived the main checkout's flow in place - $(checkout_branch "$main_root" || true) is still checked out"
      continue
    fi
    teardown_rc=0
    side_checkout_archive_and_remove "$path" "$main_root" "$here" warn || teardown_rc=$?
    case "$teardown_rc" in
      0) ;;
      2) warn "could not archive the flow in side checkout $path: $(err_line "$archive_out") - left as it stands"
         failed=1; continue ;;
      *) failed=1; continue ;;
    esac
    if ! branch_err="$(git -C "$main_root" branch -D -q "$branch" 2>&1)"; then
      warn "could not delete branch $branch: ${branch_err%%$'\n'*}"; failed=1; continue
    fi
    note "deleted branch $branch"
  done
  [ "$failed" -eq 0 ] || exit 1
}

cmd_side_checkout() {
  local op="${1:-}"
  shift || true
  case "$op" in
    add)    cmd_side_checkout_add "$@" ;;
    list)   cmd_side_checkout_list "$@" ;;
    remove) cmd_side_checkout_remove "$@" ;;
    prune)  cmd_side_checkout_prune "$@" ;;
    issue)  cmd_side_checkout_issue "$@" ;;
    *) die "unknown side-checkout op: ${op:-<none>} (want add|list|remove|prune|issue)" ;;
  esac
}
