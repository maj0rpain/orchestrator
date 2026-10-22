# shellcheck shell=bash
# known-items.sh - the Known items module: a concept module with no orch.sh
# noun of its own, holding what builds a known-items file - splitting a
# record's text into entries, appending them as tagged bullets, and writing
# the file - that review known-items and review-pass known-items read. Its
# tests: scripts/test/orch/known-items.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# section_entries <file> <heading>: the entries under <heading> in <file>, as
# handoff.sh's section_body reads them and text_entries splits them. The
# known-items builders copy these, and do no matching.
section_entries() {
  section_body "$1" "$2" | text_entries
}

# text_entries: the entries of the text on stdin, one per line - each
# top-level `- ` bullet joined with its indented continuation lines by single
# spaces, its leading `- ` stripped, and each non-blank line at the margin that
# is no bullet as an entry of its own. An entry reading None, None. or None
# declined. is a source saying it has nothing, and is dropped.
text_entries() {
  awk '
    function flush() {
      if (entry != "" && entry !~ /^None( declined)?\.?$/) print entry
      entry = ""; bullet = 0
    }
    { sub(/[[:space:]]+$/, "") }
    /^$/ { next }
    /^- / { flush(); entry = substr($0, 3); sub(/^[[:space:]]+/, "", entry); bullet = 1; next }
    /^[[:space:]]/ {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (bullet) entry = entry " " line; else { flush(); entry = line; flush() }
      next
    }
    { flush(); entry = $0; flush() }
    END { flush() }'
}

# section_entries_append <var> <file> <heading> [<tag>]: appends to <var> one
# `- ` bullet line per entry under <heading> in <file>, each ending ` - <tag>`
# when <tag> is given.
section_entries_append() {
  entries_append_from "$1" "${4:-}" < <(section_entries "$2" "$3")
}

# text_entries_append <var> <file> [<tag>]: section_entries_append for every
# entry of the whole of <file>, as text_entries splits them.
text_entries_append() {
  entries_append_from "$1" "${3:-}" < <(text_entries <"$2")
}

# entries_append_from <var> <tag>: the appenders' one loop - appends to <var>
# one `- ` bullet line per entry line on stdin, each ending ` - <tag>` when
# <tag> is non-empty.
entries_append_from() {
  local _ea_entry _ea_tag="${2:+ - $2}"
  while IFS= read -r _ea_entry; do
    printf -v "$1" '%s- %s%s\n' "${!1-}" "$_ea_entry" "$_ea_tag"
  done
}

# known_items_write <path> <deviations> <known>: writes a known-items file to
# <path>, overwriting it - `## Deviations` then `## Known items`, each heading's
# bullet lines, or None. when it has none. Built beside <path> and moved into
# place, so a failed write leaves <path> as it was.
known_items_write() {
  local path="$1" deviations="$2" known="$3" tmp
  [ -n "$deviations" ] || deviations=$'None.\n'
  [ -n "$known" ] || known=$'None.\n'
  tmp="$(mktemp "$path.XXXXXX")" || die "could not create a temp file beside $path"
  printf '## Deviations\n%s## Known items\n%s' "$deviations" "$known" >"$tmp" \
    || { rm -f "$tmp"; die "could not write the known items"; }
  mv "$tmp" "$path" || { rm -f "$tmp"; die "could not write the known items to $path"; }
}
