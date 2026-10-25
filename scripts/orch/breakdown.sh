# shellcheck shell=bash
# breakdown.sh - orch.sh's breakdown command: a spec's approved ticket
# breakdown, kept as a save point so a spec phase that died mid-publish
# finishes it on restart.
# Its tests: scripts/test/orch/breakdown.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.
#
# The save point is .orchestrator/breakdown/<parent>/: draft.md, the approved
# draft; numbers, one `<k> <number> created|linked` line per ticket, the last
# line for <k> winning; and published, the marker written last. The draft has
# one block per ticket, in draft order:
#   @@ ticket <k> <title>
#   @@ blocked-by <k>,<k>,...      (optional; blockers by draft position)
#   <body>
#   @@ end

# breakdown_dir <parent>: the parent's breakdown save point directory.
breakdown_dir() { printf '%s/breakdown/%s' "$ORCH" "$1"; }

# breakdown_parse <draft> <out-dir>: splits the draft into <out-dir>/<k>.title,
# <k>.blocked and <k>.body, and lists the positions in draft order in
# <out-dir>/order. Dies on a malformed draft.
breakdown_parse() {
  local err
  err="$(awk -v dir="$2" '
    function fail(m) { print "line " NR ": " m; bad = 1; exit 1 }
    /^@@ ticket / {
      if (inb) fail("@@ ticket inside an unfinished block")
      line = $0; sub(/^@@ ticket /, "", line)
      k = line; sub(/ .*/, "", k)
      title = line; sub(/^[^ ]* */, "", title)
      if (k !~ /^[0-9]+$/) fail("ticket position is not a plain number: " k)
      if (title == "") fail("ticket " k " has no title")
      if (k in seen) fail("ticket " k " appears twice")
      seen[k] = 1; inb = 1; first = 1
      print k > (dir "/order")
      print title > (dir "/" k ".title"); close(dir "/" k ".title")
      printf "" > (dir "/" k ".blocked"); close(dir "/" k ".blocked")
      body = dir "/" k ".body"; printf "" > body
      next
    }
    /^@@ blocked-by / && inb && first {
      line = $0; sub(/^@@ blocked-by /, "", line)
      print line > (dir "/" k ".blocked"); close(dir "/" k ".blocked")
      first = 0; next
    }
    /^@@ end[ \t]*$/ && inb { close(body); inb = 0; next }
    inb { first = 0; print > body; next }
    $0 !~ /^[ \t]*$/ { fail("text outside a ticket block") }
    END { if (!bad && inb) { print "ticket " k " has no @@ end"; exit 1 } }
  ' "$1" 2>&1 >/dev/null)" || die "the breakdown draft is malformed: ${err:-no ticket blocks}"
  [ -s "$2/order" ] || die "the breakdown draft is malformed: no ticket blocks"
}

# breakdown_order <dir>: the positions in publishing order, one per line -
# draft order, each ticket after its blockers. Dies on a blocker that names
# no ticket, on a ticket blocked by itself, and on a cycle.
breakdown_order() {
  local dir="$1" k b list pending emitted="" rest progressed ok
  pending="$(cat "$dir/order")"
  while IFS= read -r k; do
    list="$(cat "$dir/$k.blocked")"
    [ -n "$list" ] || continue
    list="$(issue_number_list "ticket-$k blocked-by" "$list")" || exit 1
    while IFS= read -r b; do
      [ "$b" != "$k" ] || die "ticket $k is blocked by itself"
      [ -f "$dir/$b.title" ] || die "ticket $k is blocked by $b, which is no ticket of the draft"
    done <<<"$list"
    printf '%s\n' "$list" >"$dir/$k.blocked"
  done <<<"$pending"
  while [ -n "$pending" ]; do
    rest=""; progressed=""
    while IFS= read -r k; do
      ok=1
      while IFS= read -r b; do
        [ -z "$b" ] || list_has "$emitted" "$b" || ok=""
      done <"$dir/$k.blocked"
      if [ -n "$ok" ]; then
        emitted+="$k"$'\n'; progressed=1
        note "$k"
      else
        rest+="$k"$'\n'
      fi
    done <<<"$pending"
    [ -n "$progressed" ] || die "the breakdown draft's blocked-by edges form a cycle"
    pending="$rest"
  done
}

# breakdown_number <numbers-file> <k>: the last line for <k> as number and
# status, or nothing.
breakdown_number() {
  [ -f "$1" ] || return 0
  awk -v k="$2" '$1 == k { n = $2; s = $3 } END { if (n != "") print n, s }' "$1"
}

# ticket_record <numbers-file> <k> <n> created|linked: appends one line to a
# breakdown's numbers file. A failed write dies.
ticket_record() {
  printf '%s %s %s\n' "$2" "$3" "$4" >>"$1" \
    || die "could not write ticket #$3's $4 record to $1"
}

# breakdown_publish_in <parent> <draft> <tmp>: breakdown publish's work, run in
# a subshell so the caller can remove <tmp> however it ends.
breakdown_publish_in() {
  local parent="$1" draft="$2" tmp="$3" dir saved numbers k rec n status b want list title order
  dir="$(breakdown_dir "$parent")"
  saved="$dir/draft.md"
  # A saved draft always wins over the one given.
  if [ ! -f "$saved" ]; then
    [ -f "$draft" ] || die "draft file not found: $draft"
    breakdown_parse "$draft" "$tmp"
    breakdown_order "$tmp" >/dev/null
    mkdir -p "$dir" || die "could not create $dir"
    cp "$draft" "$saved.tmp" && mv "$saved.tmp" "$saved" \
      || die "could not save the breakdown draft to $saved"
    rm -rf "$tmp"; mkdir -p "$tmp"
  fi
  breakdown_parse "$saved" "$tmp"
  numbers="$dir/numbers"
  order="$(breakdown_order "$tmp")" || exit 1
  while IFS= read -r k; do
    rec="$(breakdown_number "$numbers" "$k")"
    n="${rec%% *}"; status="${rec#* }"
    [ "$status" != linked ] || continue
    want=""
    list="$(cat "$tmp/$k.blocked")"
    if [ -n "$list" ]; then
      while IFS= read -r b; do
        want="${want:+$want,}$(breakdown_number "$numbers" "$b" | cut -d' ' -f1)"
      done <<<"$list"
    fi
    if [ -n "$rec" ]; then
      # Created but not linked: link it, never create another.
      (ticket_link_and_verify "$parent" "$n" "$(tr ',' '\n' <<<"$want")" adopt) \
        || die "ticket $k of the draft (#$n): the link failed"
      ticket_record "$numbers" "$k" "$n" linked
    else
      title="$(cat "$tmp/$k.title")"
      (cmd_ticket_publish "$parent" "$title" "$tmp/$k.body" \
        ${want:+--blocked-by "$want"} --record "$numbers" "$k") >/dev/null \
        || die "ticket $k of the draft: the publish failed"
    fi
  done <<<"$order"
  : >"$dir/published" || die "could not write the published marker $dir/published"
  # The numbers, in publishing order.
  awk '!seen[$1]++ { print $2 }' "$numbers"
}

# breakdown publish <parent> <draft-file>.
cmd_breakdown_publish() {
  [ $# -eq 2 ] || die "usage: orch.sh breakdown publish <parent> <draft-file>"
  case "$1" in ''|*[!0-9]*) die "parent must be a plain issue number, got: $1" ;; esac
  local tmp st=0
  tmp="$(mktemp -d)"
  (breakdown_publish_in "$1" "$2" "$tmp") || st=$?
  rm -rf "$tmp"
  exit "$st"
}

# breakdown state <parent>: complete, partial or none. With no draft saved,
# `ticket exists` decides. A failed read exits 2, never read as none.
cmd_breakdown_state() {
  [ $# -eq 1 ] || die2 "usage: orch.sh breakdown state <parent>"
  case "$1" in ''|*[!0-9]*) die2 "parent must be a plain issue number, got: $1" ;; esac
  local dir st=0
  dir="$(breakdown_dir "$1")"
  if [ -f "$dir/published" ]; then note complete; return 0; fi
  if [ -f "$dir/draft.md" ]; then note partial; return 0; fi
  (cmd_ticket_exists "$1" >/dev/null) || st=$?
  case "$st" in
    0) note complete ;;
    1) note none ;;
    *) exit 2 ;;
  esac
}

cmd_breakdown() {
  local op="${1:-}"
  shift || true
  case "$op" in
    publish) cmd_breakdown_publish "$@" ;;
    state)   cmd_breakdown_state "$@" ;;
    *) die "unknown breakdown op: ${op:-<none>} (want publish|state)" ;;
  esac
}
