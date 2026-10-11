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

# The main checkout: the first path checkout_paths prints. Fails, printing
# nothing, when checkout_paths fails or prints nothing.
main_checkout() {
  local paths
  paths="$(checkout_paths)" && [ -n "$paths" ] || return 1
  printf '%s\n' "${paths%%$'\n'*}"
}

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

# Whether the worktree at <path> carries the ownership marker.
is_side_checkout() { side_checkout_marker "$1" >/dev/null; }

# Every checkout's path, one per line, the main checkout first: the one reader
# of the paths alone from git worktree list (branch_checkout, which needs the
# `branch ` lines too, keeps its own).
checkout_paths() {
  local list line
  list="$(git worktree list --porcelain)" || return
  while IFS= read -r line; do
    case "$line" in "worktree "*) printf '%s\n' "${line#worktree }" ;; esac
  done <<<"$list"
}

# Whether the checkout at <path> holds a flow.
checkout_has_flow() { [ -f "$(flow_state_file "$1")" ]; }

# What the checkout at <path> holds: its flow (flow <slug> <phase> #<issue>),
# else its checked-out branch (branch <name>), else (no branch).
checkout_holding() {
  local state issue issue_label branch
  state="$(flow_state_file "$1")"
  if [ -f "$state" ]; then
    issue="$(state_get_in "$state" issue)"
    if [ -n "$issue" ]; then issue_label="#$issue"; else issue_label="(no issue)"; fi
    note "flow $(state_get_in "$state" slug) $(state_get_in "$state" phase) $issue_label"
  elif branch="$(git -C "$1" symbolic-ref --quiet --short HEAD)"; then
    note "branch $branch"
  else
    note "(no branch)"
  fi
}

# --- the finished sweep ---
#
# Finished is read from GitHub's PR state, never git ancestry: a squash or
# rebase merge never makes the branch an ancestor of its base (ADR-0037). The
# verdicts below assign to the caller's `verdict` and `branch`, which bash
# scopes dynamically, and return 0 finished, 1 not finished - `verdict` the
# reason - or 2 the verdict could not be read, GitHub or the checkout's own
# git status - `verdict` naming which, and its error.

# finished_flow <state-file>: whether that flow is finished - at done, and its
# recorded PR merged into its own base branch.
finished_flow() {
  local state="$1" phase pr base pr_state _is_draft shown_state _head_oid _head_ref merged_base _commits err
  phase="$(state_get_in "$state" phase)"
  if [ "$phase" != "done" ]; then
    verdict="flow $(state_get_in "$state" slug) is at $phase, not done"; return 1
  fi
  branch="$(state_get_in "$state" branch)"
  [ -n "$branch" ] || { verdict="no branch"; return 1; }
  pr="$(state_get_in "$state" pr)"
  [ -n "$pr" ] || { verdict="no PR recorded"; return 1; }
  base="$(flow_base_in "$state")"
  pr_state_draft_read "$pr" pr_state _is_draft err \
    || { verdict="could not read GitHub: $(gh_reason "$err")"; return 2; }
  if [ "$pr_state" != MERGED ]; then
    state_word shown_state "$pr_state"
    verdict="PR #$pr is $shown_state"; return 1
  fi
  pr_refs_read "$pr" _head_oid _head_ref merged_base _commits err \
    || { verdict="could not read GitHub: $(gh_reason "$err")"; return 2; }
  [ "$merged_base" = "$base" ] || { verdict="PR #$pr merged into $merged_base, not $base"; return 1; }
}

# side_checkout_finished <path>: whether the side checkout there is finished -
# a clean tree, and either a finished flow, or no flow and a PR merged from
# its checked-out branch into the base branch off recorded for it (see
# recorded_base). A git status that cannot run returns 2, as an unreadable
# GitHub does, so the sweep removes nothing on a tree it could not read.
# verdict is read by its callers, side-checkout prune, below, and
# doctor.sh.
# shellcheck disable=SC2034
side_checkout_finished() {
  local path="$1" base prs st err
  st="$(tree_status "$path")" || { verdict="$st"; return 2; }
  if [ -n "$st" ]; then
    verdict="uncommitted changes or untracked files"; return 1
  fi
  if checkout_has_flow "$path"; then
    finished_flow "$(flow_state_file "$path")"; return
  fi
  branch="$(git -C "$path" symbolic-ref --quiet --short HEAD)" \
    || { verdict="no branch"; return 1; }
  base="$(recorded_base "$branch")"
  capture prs err adapter_prs_merged "$branch" "$base" \
    || { verdict="could not read GitHub: $(gh_reason "$err")"; return 2; }
  [ -n "$prs" ] || { verdict="no merged PR from $branch into $base"; return 1; }
}

# archive_root <root>: prints the checkout whose .orchestrator/archive/
# receives the flow in the checkout at <root> - the one computation of the
# rule. A side checkout's flow goes to the main checkout's archive; any other
# checkout, a hand-made worktree included, archives in place. Fails when <root>
# is a side checkout and the main checkout cannot be read.
archive_root() {
  if is_side_checkout "$1"; then main_checkout; else printf '%s\n' "$1"; fi
}

# archive_flow <root> <archive-root>: moves the flow in the checkout at <root>
# into a directory under <archive-root>'s .orchestrator/archive/, and prints
# that directory - relative to this checkout when inside it, else in full.
# <archive-root> is the caller's: a side checkout's flow goes to the main
# checkout's archive; any other checkout, a hand-made worktree included,
# archives in place (see archive_root).
archive_flow() {
  local root="$1" orch="$1/$ORCH_DIR_NAME" home="$2/$ORCH_DIR_NAME" slug dest entry
  refuse_ticket_worktrees "$root"
  slug="$(state_get_in "$(flow_state_file "$root")" slug)"
  dest="$home/archive/$(dir_stamp)-$slug"
  mkdir -p "$dest"
  for entry in "$orch"/*; do
    [ -e "$entry" ] || continue
    # Side checkouts are live worktrees, never part of the flow's files.
    case "$(basename "$entry")" in archive|checkouts) continue ;; esac
    mv "$entry" "$dest/"
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

# side_checkouts_dir <main-root>: where the side checkouts of the main
# checkout at <main-root> live.
side_checkouts_dir() { printf '%s/%s/checkouts\n' "$1" "$ORCH_DIR_NAME"; }

# side_checkout_issue <path>: prints the issue the side checkout at <path>
# records in its marker; returns 1 when it is no side checkout, or its marker
# holds no plain issue number.
side_checkout_issue() {
  local marker issue
  marker="$(side_checkout_marker "$1")" || return 1
  issue="$(cat "$marker" 2>/dev/null)" || return 1
  case "$issue" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$issue"
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
  main_root="$(main_checkout)"
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
  local path issue quick
  while IFS= read -r path; do
    is_side_checkout "$path" || continue
    quick=""
    if issue="$(side_checkout_issue "$path")"; then quick=" quick #$issue"; fi
    note "${path##*/} $path $(checkout_holding "$path")$quick"
  done < <(checkout_paths)
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
  local slug path err here main_root dirs
  here="$(pwd -P)"
  slug="$(normalize_slug "$1")"
  main_root="$(main_checkout)"
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
  if checkout_has_flow "$path"; then
    archive_flow "$path" "$main_root"
  else
    refuse_ticket_worktrees "$path"
  fi
  if ! err="$(git -C "$main_root" worktree remove "$path" 2>&1)"; then
    die "could not remove side checkout $path: ${err%%$'\n'*}"
  fi
  note "removed side checkout $path"
  side_checkout_close_note "$path" "$here"
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
  local here main_root path verdict branch rc unread=0 failed=0
  # archive_out is this entry's archive_flow output - its note, or its error -
  # cleared at the top of each entry so none outlives its own.
  local archive_out remove_err branch_err
  local paths=() finished=()
  here="$(pwd -P)"
  # checkout_paths lists the main checkout first.
  mapfile -t paths < <(checkout_paths)
  main_root="${paths[0]-}"
  # Every step works from the main checkout, so removing the checkout this
  # command ran in leaves the sweep somewhere to stand.
  cd "$main_root" || die "could not enter the main checkout $main_root"
  for path in "${paths[@]}"; do
    rc=0; verdict=""; branch=""
    if [ "$path" = "$main_root" ]; then
      checkout_has_flow "$path" || continue
      finished_flow "$(flow_state_file "$path")" </dev/null || rc=$?
    elif is_side_checkout "$path"; then
      side_checkout_finished "$path" </dev/null || rc=$?
    elif checkout_has_flow "$path"; then
      note "$path: not a side checkout, left alone"; continue
    else
      continue
    fi
    case "$rc" in
      0) finished+=("$path"$'\t'"$branch") ;;
      1) note "skipped $path: $verdict" ;;
      *) warn "could not check $path: $verdict"; unread=$((unread + 1)) ;;
    esac
  done
  [ "$unread" -eq 0 ] || die "$unread checkout(s) could not be checked - nothing was removed"
  [ "${#finished[@]}" -gt 0 ] || { note "no finished side checkouts"; return 0; }
  local entry
  for entry in "${finished[@]}"; do
    path="${entry%%$'\t'*}"; branch="${entry#*$'\t'}"
    archive_out=""
    if [ "$path" = "$main_root" ]; then
      if ! archive_out="$(archive_flow "$path" "$main_root" 2>&1)"; then
        warn "could not archive the main checkout's flow: ${archive_out%%$'\n'*}"; failed=1; continue
      fi
      note "$archive_out"
      note "archived the main checkout's flow in place - $(git -C "$main_root" branch --show-current || true) is still checked out"
      continue
    fi
    if checkout_has_flow "$path" && ! archive_out="$(archive_flow "$path" "$main_root" 2>&1)"; then
      warn "could not archive the flow in side checkout $path: ${archive_out%%$'\n'*} - left as it stands"
      failed=1; continue
    fi
    [ -z "$archive_out" ] || note "$archive_out"
    if ! remove_err="$(git -C "$main_root" worktree remove "$path" 2>&1)"; then
      warn "could not remove side checkout $path: ${remove_err%%$'\n'*} - left as it stands"
      failed=1; continue
    fi
    note "removed side checkout $path"
    side_checkout_close_note "$path" "$here"
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
