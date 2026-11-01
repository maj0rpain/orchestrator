# shellcheck shell=bash
# trust.sh - the Trust module: a concept module with no orch.sh noun of its own,
# owning which comments orch.sh reads. A trusted comment is one whose
# authorAssociation is OWNER, MEMBER or COLLABORATOR (ADR-0057); every other
# comment is dropped, once per read, in the domain layer just above the gh
# adapters, before any marked comment, answer or spec text is read from it.
# Its tests: scripts/test/orch/trust.sh.
# Sourced by orch.sh, after common.sh; it calls nothing a noun module defines.

# trust_filter_comments <issue>: the comments JSON array on stdin, each comment
# carrying its authorAssociation, on stdout without the untrusted ones. When it
# dropped any, prints one stderr line, `orch: ignored N comment(s) from
# untrusted authors on #<issue>`. Non-zero, printing nothing, when stdin is not
# a comment array.
trust_filter_comments() {
  local json kept total n
  json="$(cat)"
  kept="$(jq -c '[.[] | select(.authorAssociation | IN("OWNER", "MEMBER", "COLLABORATOR"))]' \
    <<<"$json" 2>/dev/null)" || return 1
  total="$(jq 'length' <<<"$json")"
  n=$((total - $(jq 'length' <<<"$kept")))
  [ "$n" -eq 0 ] || warn "ignored $n comment(s) from untrusted authors on #$1"
  printf '%s\n' "$kept"
}
