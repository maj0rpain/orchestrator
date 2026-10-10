# shellcheck shell=bash
# ticket.sh - orch.sh's ticket command: a breakdown's sub-issues and their
# blocked-by edges, and ticket merge.
# Its tests: scripts/test/orch/ticket.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# --- ticket -------------------------------------------------------------
#
# GitHub's native sub-issues and issue dependencies, in one place, so no skill
# or agent prose ever calls `gh api` on these endpoints directly. Every read
# and write goes through the adapter's sub-issue and dependency operations.
# Stateless throughout, like issue publish/pr publish: callable with no
# state.json, since quick implementation keeps none.

# ticket_sub_issues <parent> [die|die2]: the parent's sub-issues as
# adapter_sub_issues prints them - the listing the ticket commands read (#394),
# save ticket_links_verified, which calls adapter_sub_issues itself so a failed
# read can be retried rather than died on. Both failures die through the
# second argument (default die): a parent that is no plain number, refused
# before asking GitHub, and a GitHub that cannot list them.
ticket_sub_issues() {
  local parent="$1" fail="${2:-die}" subs err
  case "$parent" in ''|*[!0-9]*) "$fail" "parent must be a plain issue number, got: $parent" ;; esac
  capture subs err adapter_sub_issues "$parent" \
    || "$fail" "gh could not list sub-issues of #$parent: $(gh_reason "$err")"
  if [ -n "$subs" ]; then printf '%s\n' "$subs"; fi
}

# flag_value_once <usage> <already-given> <argc>: the rule for a flag that
# takes a value, shared by `ticket publish --blocked-by` and `ticket
# block`/`unblock --by`. Prints nothing; dies with <usage> unless this is the
# flag's first appearance (<already-given> empty) and a value follows it
# (<argc>, the caller's "$#", at least 2). Call it directly, never inside
# $(...), so its die exits orch.sh; the caller takes the raw value from its
# own "$2", never through a command substitution, which would strip a
# trailing newline that issue_number_list must still see and refuse.
flag_value_once() {
  [ "$3" -ge 2 ] && [ -z "$2" ] || die "$1"
}

# The one parser of a comma list of issue numbers for every `ticket` command:
# `ticket publish --blocked-by` and `ticket block`/`unblock --by`. Prints the
# numbers one per line, sorted and de-duplicated. Dies naming <flag> and the
# whole list on any entry that is not a plain issue number, an empty one
# included (`1,,2`, `,5`, `5,`). An empty <list> dies too; a caller that
# allows no list checks for it first.
issue_number_list() {
  local flag="$1" list="$2"
  # Digits and commas only, with no comma leading, trailing or doubled - a
  # per-entry loop over a command substitution would lose a trailing empty.
  case "$list" in
    ''|*[!0-9,]*|,*|*,|*,,*) die "$flag must be plain issue numbers, got: $list" ;;
  esac
  # Split at the commas by IFS: the list is digits and commas only, so no
  # entry globs and none is empty.
  local IFS=,
  # shellcheck disable=SC2086
  printf '%s\n' $list | sort -un
}

# ticket_links_verified <line_var> <parent> <child> <want>: 0 only once both
# links read back exactly as published: the parent's sub-issue listing
# contains the child, and the child's blocked-by listing is the same set of
# numbers requested, in any order, both sides de-duplicated. 1 on a mismatch;
# 2 when either read fails, gh's first stderr line - empty when gh printed
# none - written into <line_var>, so a failed read is never reported as a
# mismatch (#843). Read fresh every call, never cached - the caller retries
# this once on either status, and a cached answer would just repeat the same
# verdict. Locals prefixed so no caller's variable name is shadowed.
ticket_links_verified() {
  local __tlv_out __tlv_blockers __tlv_err __tlv_line __tlv_linked=""
  if ! capture __tlv_out __tlv_err adapter_sub_issues "$2"; then
    printf -v "$1" '%s' "${__tlv_err%%$'\n'*}"
    return 2
  fi
  while IFS= read -r __tlv_line; do
    if [ "${__tlv_line%%$'\t'*}" = "$3" ]; then __tlv_linked=1; break; fi
  done <<<"$__tlv_out"
  [ -n "$__tlv_linked" ] || return 1
  if ! capture __tlv_blockers __tlv_err adapter_blockers "$3"; then
    printf -v "$1" '%s' "${__tlv_err%%$'\n'*}"
    return 2
  fi
  if [ -n "$__tlv_blockers" ]; then __tlv_blockers="$(printf '%s\n' "$__tlv_blockers" | sort -un)"; fi
  [ "$__tlv_blockers" = "$(printf '%s\n' "$4" | sort -un)" ]
}

# Publishes a child issue, links it to <parent> as a native sub-issue, adds a
# native blocking edge for every --blocked-by argument, and applies this
# repo's ready-for-agent label - then verifies every link it just wrote by
# reading it back. One retry on a mismatch or a failed read; a second failure dies naming the
# ticket rather than falling back to a text-based `Blocked by:` convention,
# since nothing downstream ever reads that fallback.
cmd_ticket_publish() {
  local usage="usage: orch.sh ticket publish <parent> <title> <body-file> [--blocked-by N,N,...]"
  [ $# -ge 3 ] || die "$usage"
  local parent="$1" title="$2" body_file="$3" blocked_by="" have_blocked_by="" want="" b
  local ready child gh_line="" st=0 err
  shift 3
  # Every argument check runs here, before the first GitHub write. A second
  # --blocked-by is refused, never allowed to replace the first.
  while [ $# -gt 0 ]; do
    case "$1" in
      --blocked-by)
        flag_value_once "$usage" "$have_blocked_by" "$#"
        blocked_by="$2"; have_blocked_by=1; shift 2 ;;
      *) die "$usage" ;;
    esac
  done
  case "$parent" in ''|*[!0-9]*) die "parent must be a plain issue number, got: $parent" ;; esac
  [ -n "$title" ] || die "the title is empty"
  [ -f "$body_file" ] || die "body file not found: $body_file"
  # A wholly empty --blocked-by "" means no blockers. The list comes back
  # de-duplicated: GitHub stores a blocking edge once however often it is
  # requested, so a duplicate would leave the readback's set permanently
  # smaller than $want and fail verification for a correct link.
  if [ -n "$blocked_by" ]; then
    want="$(issue_number_list --blocked-by "$blocked_by")" || exit 1
  fi

  ready="$(triage_label_for ready-for-agent)"
  capture child err adapter_issue_create "$title" "$body_file" "$ready" \
    || die "gh could not create the ticket: $(gh_reason "$err")"

  capture_err err adapter_sub_issue_link "$parent" "$child" \
    || die "gh could not link ticket #$child as a sub-issue of #$parent: $(gh_reason "$err")"

  if [ -n "$want" ]; then
    while IFS= read -r b; do
      capture_err err adapter_blocker_add "$child" "$b" \
        || die "gh could not add a blocking edge from ticket #$child on #$b: $(gh_reason "$err")"
    done <<<"$want"
  fi

  # Either status gets the one retry, and the second attempt decides the
  # death: a failed read dies with gh's reason, a mismatch as unverified.
  ticket_links_verified gh_line "$parent" "$child" "$want" \
    || ticket_links_verified gh_line "$parent" "$child" "$want" \
    || st=$?
  [ "$st" -ne 2 ] || die "gh could not read ticket #$child's links: $(gh_reason "$gh_line")"
  [ "$st" -eq 0 ] \
    || die "ticket #$child's sub-issue/blocked-by links did not verify - checked twice, both failed"

  note "$child"
}

# The parent's open sub-issues with zero open blockers, in the order GitHub
# published them.
cmd_ticket_next() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket next <parent>"
  local subs line n state blockers
  subs="$(ticket_sub_issues "$1")" || exit 1
  while IFS= read -r line; do
    tsv_split "$line" n state blockers
    if [ "$state" = OPEN ] && [ "$blockers" = 0 ]; then note "$n"; fi
  done <<<"$subs"
}

# Every sub-issue of <parent>, open or closed, one "<n> open|closed" line
# each, in the order GitHub published them - how a spec review finds the
# tickets its accepted edits touch without calling a sub-issue endpoint.
cmd_ticket_list() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket list <parent>"
  local subs line n state
  subs="$(ticket_sub_issues "$1")" || exit 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tsv_split "$line" n state
    case "$state" in
      OPEN) state=open ;;
      CLOSED) state=closed ;;
    esac
    printf '%s %s\n' "$n" "$state"
  done <<<"$subs"
}

cmd_ticket_close() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket close <n>"
  local n="$1" err
  case "$n" in ''|*[!0-9]*) die "not a plain issue number: $n" ;; esac
  capture_err err adapter_issue_close "$n" || die "gh could not close ticket #$n: $(gh_reason "$err")"
}

# Reopens every sub-issue of <parent> that is currently closed, and only
# those - the fix `redo review` needs before handing back to a fresh
# implement phase, whose frontier query would otherwise find nothing.
cmd_ticket_reset() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket reset <parent>"
  local subs line n state err
  subs="$(ticket_sub_issues "$1")" || exit 1
  while IFS= read -r line; do
    tsv_split "$line" n state
    [ "$state" = CLOSED ] && [ -n "$n" ] || continue
    capture_err err adapter_issue_reopen "$n" \
      || die "gh could not reopen ticket #$n: $(gh_reason "$err")"
  done <<<"$subs"
}

# Prints <n>'s parent issue number, or nothing (still exit 0) when <n> is
# not a sub-issue. Every gh failure is a real one (see adapter_issue_parent).
cmd_ticket_parent() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket parent <n>"
  local n="$1" err
  case "$n" in ''|*[!0-9]*) die "not a plain issue number: $n" ;; esac
  capture_err err adapter_issue_parent "$n" \
    || die "gh could not read issue #$n's parent: $(gh_reason "$err")"
}

# Whether <parent> already has a ticket breakdown, decided by structure
# rather than prose (ADR-0028): `sub-issues` when it has at least one,
# open or closed; `collapsed` when it has none but its body carries a line
# that is exactly `## Ticket` outside a code fence, the heading a
# 0-1-ticket collapse appends under; exit 1 and no output when neither.
# Sub-issues win when both hold.
# A body edited on the web arrives with CRLF line ends, so a trailing CR
# does not stop the heading's line from matching. A GitHub it cannot read, a
# usage error, or a parent that is not a plain number exits 2 (die2), never 1:
# a caller reading 1 as "no breakdown" would publish a second one.
cmd_ticket_exists() {
  [ $# -eq 1 ] || die2 "usage: orch.sh ticket exists <parent>"
  local parent="$1" subs body err
  subs="$(ticket_sub_issues "$parent" die2)" || exit "$?"
  if [ -n "$subs" ]; then
    printf 'sub-issues\n'
    return 0
  fi
  capture body err adapter_issue_body "$parent" \
    || die2 "gh could not read issue #$parent's body: $(gh_reason "$err")"
  if printf '%s\n' "$body" | has_ticket_heading; then
    printf 'collapsed\n'
    return 0
  fi
  return 1
}

# The fixed heading line a collapsed ticket breakdown sits under (ADR-0012).
TICKET_HEADING='## Ticket'

# True when the body on stdin has a line that is exactly TICKET_HEADING outside
# a code fence, CRLF ends allowed - the test `ticket exists` uses, and the line
# `strip_ticket_sections` cuts from.
has_ticket_heading() {
  awk -v heading="$TICKET_HEADING" '
    { l = $0; sub(/\r$/, "", l) }
    !fence && l == heading { found = 1 }
    l ~ /^(```|~~~)/ { fence = !fence }
    END { exit !found }
  '
}

# The body on stdin with every `## Ticket` section removed - the heading line
# `ticket exists` detects, outside a code fence, through the line before the
# next `#` or `##` heading outside a code fence, or the end of the body - and
# the blank lines a section at the end leaves behind trimmed. Every other
# line is kept byte for byte, CRLF ends and trailing blank lines included.
strip_ticket_sections() {
  awk -v heading="$TICKET_HEADING" '
    { l = $0; sub(/\r$/, "", l) }
    skip && !fence && l ~ /^##?([ \t]|$)/ && l != heading { skip = 0 }
    !fence && l == heading { skip = 1; next }
    l ~ /^(```|~~~)/ { fence = !fence }
    skip { next }
    l == "" { held = held $0 "\n"; next }
    { printf "%s%s\n", held, $0; held = "" }
    END { if (!skip) printf "%s", held }
  '
}

# Retires <parent>'s ticket breakdown so nothing later picks it up again
# (issue #334): every sub-issue is closed as not planned if still open,
# commented on, and unlinked from <parent> - unlinked last, so a run that
# dies part-way still finds what it has not finished, and a ticket that
# already carries the retirement comment is not commented on again - and
# every `## Ticket` section is cut from <parent>'s body. Afterwards `ticket
# exists <parent>` exits 1. A breakdown already retired has nothing to list
# and no section to cut, so a repeat writes nothing. Any GitHub failure dies.
cmd_ticket_retire() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket retire <parent>"
  local parent="$1" subs n state comments msg old_msg comment_file err
  subs="$(ticket_sub_issues "$parent")" || exit 1
  msg="This ticket was retired: its spec, #$parent, changed and will be broken down into tickets again."
  # The wording a retire posted before a spec review could retire too: a
  # ticket carrying it from a run that died part-way is already commented on.
  old_msg="This ticket was retired by an orchestrator redo: its spec, #$parent, is being redone and will be broken down into tickets again."
  while IFS=$'\t' read -r n state _; do
    [ -z "$n" ] && continue
    if [ "$state" = OPEN ]; then
      capture_err err adapter_issue_close "$n" --reason "not planned" --comment "$msg" \
        || die "gh could not close ticket #$n: $(gh_reason "$err")"
    else
      capture comments err adapter_issue_comments "$n" \
        || die "gh could not read ticket #$n's comments: $(gh_reason "$err")"
      if ! grep -qF -e "$msg" -e "$old_msg" <<<"$comments"; then
        comment_file="$(mktemp)"
        printf '%s\n' "$msg" >"$comment_file"
        capture_err err adapter_issue_comment "$n" "$comment_file" \
          || { rm -f "$comment_file"; die "gh could not comment on ticket #$n: $(gh_reason "$err")"; }
        rm -f "$comment_file"
      fi
    fi
    capture_err err adapter_sub_issue_unlink "$parent" "$n" \
      || die "gh could not unlink ticket #$n from #$parent: $(gh_reason "$err")"
  done <<<"$subs"
  # A body with no `## Ticket` line outside a code fence comes back
  # unchanged, so it is not written.
  issue_body_rewrite "$parent" "gh could not read issue #$parent's body" \
    "gh could not remove the ## Ticket section from #$parent" strip_ticket_sections
}

# issue_body_rewrite <n> <read-msg> <write-msg> <filter> [<arg>...]: issue
# <n>'s body through <filter> (stdin to stdout) and back. The body is read
# into a file, never through $(...), which would drop its trailing newlines,
# so the bytes the filter keeps go back unchanged - the same round trip
# `issue fetch` and `issue update` make. A body with no final newline gets
# none back; a result byte-identical to the body is not written. A failed
# read dies with <read-msg>, a failed write with <write-msg>, each followed by
# gh's reason; capture_err takes the stderr while the body still streams to
# its file, and neither death leaves a temp file.
issue_body_rewrite() {
  local n="$1" read_msg="$2" write_msg="$3" body result out err
  shift 3
  body="$(mktemp)"
  capture_err err adapter_issue_body "$n" >"$body" \
    || { rm -f "$body"; die "$read_msg: $(gh_reason "$err")"; }
  result="$(mktemp)"
  "$@" <"$body" >"$result"
  # A filter command may end its last line with a newline; a body that had
  # no final newline gets none back.
  if [ -s "$body" ] && [ -n "$(tail -c 1 "$body")" ]; then
    out="$(cat "$result"; printf x)"; out="${out%x}"
    printf '%s' "${out%$'\n'}" >"$result"
  fi
  if cmp -s "$body" "$result"; then rm -f "$body" "$result"; return 0; fi
  rm -f "$body"
  capture_err err adapter_issue_body_edit "$n" "$result" \
    || { rm -f "$result"; die "$write_msg: $(gh_reason "$err")"; }
  rm -f "$result"
}

# Dies, before any write, unless ticket <n> is open, is a sub-issue, and
# every --by issue is its sibling: a sub-issue of the same parent. A closed
# blocker is allowed - an edge to a finished ticket is still a record. The
# state is the issue noun's own read (#496); a pull request's number passes it
# and is refused as no sub-issue.
ticket_edge_preconditions() {
  local n="$1" by="$2" state parent b bp err
  capture state err adapter_issue_state "$n" \
    || die "gh could not read ticket #$n: $(gh_reason "$err")"
  [ "$state" != CLOSED ] || die "ticket #$n is closed - its blocking edges can no longer change anything"
  capture parent err adapter_issue_parent "$n" \
    || die "gh could not read issue #$n's parent: $(gh_reason "$err")"
  [ -n "$parent" ] || die "#$n is not a sub-issue, so it is no ticket of a breakdown"
  while IFS= read -r b; do
    capture bp err adapter_issue_parent "$b" \
      || die "gh could not read issue #$b's parent, a blocker of ticket #$n: $(gh_reason "$err")"
    [ "$bp" = "$parent" ] \
      || die "#$b is not a sub-issue of #$parent, ticket #$n's parent - edges never cross breakdowns"
  done <<<"$by"
}

# Ticket <n>'s blocker numbers, read fresh from its native blocked-by
# listing, one per line, sorted and de-duplicated: edges are a set. A gh
# failure dies naming the ticket, with gh's reason.
ticket_blockers() {
  local have err
  capture have err adapter_blockers "$1" \
    || die "gh could not read ticket #$1's blockers: $(gh_reason "$err")"
  if [ -n "$have" ]; then printf '%s\n' "$have" | sort -un; fi
}

# Verify-then-die (ADR-0011): ticket <n>'s blocked-by listing, read back
# fresh, must be exactly the set <want>. A mismatch is re-read once; a second
# mismatch dies naming the ticket. Never falls back to body text.
ticket_edges_verify() {
  local n="$1" want="$2" have
  have="$(ticket_blockers "$n")" || exit 1
  [ "$have" = "$want" ] && return 0
  have="$(ticket_blockers "$n")" || exit 1
  [ "$have" = "$want" ] \
    || die "ticket #$n's blocking edges did not verify - checked twice, both failed"
}

# The heading of a ticket body's section listing its blockers - kept in line
# with the native edges for human readers; no command reads it.
BLOCKED_BY_HEADING='## Blocked by'

# The body on stdin with its first `## Blocked by` section outside a code
# fence - the heading through the line before the next `#` or `##` heading
# outside a code fence, or the end of the body; `###` does not end it -
# rewritten as: the heading, a blank line, one `- #<n>` line per blocker in
# <blockers> (or `None (can start immediately)` when empty), then a blank line
# if another heading follows. The section's lines end the way its heading's
# line did, CRLF included. With no such section, one is appended after one
# blank line. Every other line is kept byte for byte.
rewrite_blocked_by_section() {
  awk -v heading="$BLOCKED_BY_HEADING" -v blockers="$1" '
    function section(eol,   i, n, b) {
      printf "%s%s%s", heading, eol, eol
      n = split(blockers, b, "\n")
      if (blockers == "") printf "None (can start immediately)%s", eol
      else for (i = 1; i <= n; i++) printf "- #%s%s", b[i], eol
    }
    { l = $0; cr = ($0 ~ /\r$/) ? "\r" : ""; sub(/\r$/, "", l); last = l; lastcr = cr }
    skip && !fence && l ~ /^##?([ \t]|$)/ { skip = 0; printf "%s\n", seol }
    !done && !fence && l == heading { seol = cr; section(cr "\n"); skip = 1; done = 1; next }
    l ~ /^(```|~~~)/ { fence = !fence }
    skip { next }
    { print }
    END {
      if (!done) {
        if (NR > 0 && last != "") printf "%s\n", lastcr
        section(lastcr "\n")
      }
    }
  '
}

# blockers_union <before> <by>: the blocker set after `ticket block` - every
# number in either list, one per line, sorted and de-duplicated.
blockers_union() {
  printf '%s\n%s\n' "$1" "$2" | sed '/^$/d' | sort -un
}

# blockers_difference <before> <by>: the blocker set after `ticket unblock` -
# every number in <before> that is not in <by>, one per line.
blockers_difference() {
  printf '%s\n' "$1" | grep -vxF -f <(printf '%s\n' "$2") || true
}

# `ticket block` and `ticket unblock`'s one driver: `ticket <verb> <n> --by
# N,N,...`. The arguments are checked before anything touches GitHub: <n>
# and every --by entry plain issue numbers, --by required and given once - a
# second --by would otherwise replace the first - and the --by list sorted
# and de-duplicated, as `ticket publish --blocked-by` does. Then the
# preconditions, the current edges, one adapter write per edge that needs
# it, verify-then-die (ADR-0011) against the wanted set, and the `## Blocked
# by` rewrite through issue_body_rewrite. The write is not read back -
# ADR-0011 governs the edges, not the body. Only the verb varies, and the one
# `case` up front binds all of it: block skips edges already present, adds
# the rest and wants the union; unblock skips edges already absent, removes
# the rest and wants the difference. Either re-run is idempotent.
ticket_edges_change() {
  local verb="$1" usage n="" by="" have_by="" before want b present err
  local skip_present edge_op edge_word want_fn
  case "$verb" in
    block)
      skip_present=1; edge_op=adapter_blocker_add; edge_word=add
      want_fn=blockers_union ;;
    unblock)
      skip_present=""; edge_op=adapter_blocker_remove; edge_word=remove
      want_fn=blockers_difference ;;
    *) die "unknown ticket edge verb: ${verb:-<none>} (want block|unblock)" ;;
  esac
  usage="usage: orch.sh ticket $verb <n> --by N,N,..."
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) flag_value_once "$usage" "$have_by" "$#"; by="$2"; have_by=1; shift 2 ;;
      -*)   die "$usage" ;;
      *)    [ -z "$n" ] || die "$usage"; n="$1"; shift ;;
    esac
  done
  [ -n "$n" ] || die "$usage"
  [ -n "$have_by" ] || die "$usage"
  case "$n" in *[!0-9]*) die "not a plain issue number: $n" ;; esac
  [ -n "$by" ] || die "--by must be plain issue numbers, got nothing"
  by="$(issue_number_list --by "$by")" || exit 1
  ticket_edge_preconditions "$n" "$by"
  before="$(ticket_blockers "$n")" || exit 1
  while IFS= read -r b; do
    present=""
    case $'\n'"$before"$'\n' in *$'\n'"$b"$'\n'*) present=1 ;; esac
    [ "$present" != "$skip_present" ] || continue
    capture_err err "$edge_op" "$n" "$b" \
      || die "gh could not $edge_word a blocking edge from ticket #$n on #$b: $(gh_reason "$err")"
  done <<<"$by"
  want="$("$want_fn" "$before" "$by")"
  ticket_edges_verify "$n" "$want"
  issue_body_rewrite "$n" "gh could not read ticket #$n's body" \
    "gh could not rewrite ticket #$n's ## Blocked by section" \
    rewrite_blocked_by_section "$want"
}

# Adds a native blocking edge on <n> for every --by issue it lacks.
cmd_ticket_block() { ticket_edges_change block "$@"; }

# Removes the native blocking edge on <n> for every --by issue it has.
cmd_ticket_unblock() { ticket_edges_change unblock "$@"; }

cmd_ticket() {
  local op="${1:-}"
  shift || true
  case "$op" in
    publish) cmd_ticket_publish "$@" ;;
    next)    cmd_ticket_next "$@" ;;
    list)    cmd_ticket_list "$@" ;;
    close)   cmd_ticket_close "$@" ;;
    reset)   cmd_ticket_reset "$@" ;;
    parent)  cmd_ticket_parent "$@" ;;
    exists)  cmd_ticket_exists "$@" ;;
    retire)  cmd_ticket_retire "$@" ;;
    block)   cmd_ticket_block "$@" ;;
    unblock) cmd_ticket_unblock "$@" ;;
    merge)   cmd_ticket_merge "$@" ;;
    *) die "unknown ticket op: ${op:-<none>} (want publish|next|list|close|reset|parent|exists|retire|block|unblock|merge)" ;;
  esac
}

# The checkout that has <branch> checked out, or nothing: the first worktree
# git lists on refs/heads/<branch>.
branch_checkout() {
  local line path=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      "branch refs/heads/$1") note "$path"; return 0 ;;
    esac
  done < <(git worktree list --porcelain)
}

# Lands ticket <n>'s branch on the branch it was forked from: rebases it onto
# that branch's tip inside the ticket worktree, then fast-forwards that branch
# in whichever checkout has it - so history stays linear. Every refusal (exit
# 1) runs before anything moves. Exit 3 means a rebase conflict only: it is
# aborted, leaving both branches at their prior tips. A rebase that fails any
# other way is aborted too and exits 1, naming git's first line; so does an
# abort that fails, which leaves the ticket worktree mid-rebase.
cmd_ticket_merge() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket merge <n>"
  local n path branch parent parent_checkout rebase_err unmerged said
  # rebase_out is set by capture and only git's stderr is read.
  # shellcheck disable=SC2034
  local rebase_out
  ticket_worktree_resolve "$1"
  parent="$(forked_from_branch "$branch")" \
    || die "branch $branch records no forked-from branch"
  require_clean_tree "$path" \
    "ticket worktree $path is dirty - commit or discard its changes first"
  parent_checkout="$(branch_checkout "$parent")"
  [ -n "$parent_checkout" ] \
    || die "$parent, the branch $branch was forked from, is checked out nowhere - check it out first"
  require_clean_tree "$parent_checkout" \
    "$parent_checkout, the checkout of $parent, is dirty - commit or discard its changes first"
  if ! capture rebase_out rebase_err git -C "$path" rebase -q "$parent"; then
    # A conflict is a rebase stopped with unmerged paths; anything else - a
    # refusing hook, say - is a plain failure, named by git's first line.
    unmerged="$(git -C "$path" diff --name-only --diff-filter=U 2>/dev/null)" || unmerged=""
    if rebase_in_progress "$path"; then
      git -C "$path" rebase --abort >/dev/null 2>&1 \
        || die "could not abort the rebase in ticket worktree $path - it is left mid-rebase"
    fi
    if [ -n "$unmerged" ]; then
      warn "rebasing $branch onto $parent hit a conflict - aborted; both branches are as they were"
      exit 3
    fi
    said="${rebase_err%%$'\n'*}"
    die "rebasing $branch onto $parent failed: ${said:-git gave no reason}"
  fi
  git -C "$parent_checkout" merge -q --ff-only "$branch" \
    || die "could not fast-forward $parent to $branch in $parent_checkout"
}
