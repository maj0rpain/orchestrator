# shellcheck shell=bash
# trust.sh - the Trust module: a concept module with no orch.sh noun of its own,
# owning which comments orch.sh reads and which issues autopilot runs on. A
# trusted comment is one whose authorAssociation is OWNER, MEMBER or
# COLLABORATOR (ADR-0057); every other comment is dropped, once per read, in the
# domain layer just above the gh adapters, before any marked comment, answer or
# spec text is read from it. An issue is trusted when its body and its title
# both are (trust_issue_check).
# Its tests: scripts/test/orch/trust.sh.
# Sourced by orch.sh, after common.sh; it calls nothing a noun module defines.

# The associations of a trusted author, as a JSON array - the one list the
# comment filter and the issue check share.
TRUST_ASSOCIATIONS_JSON='["OWNER", "MEMBER", "COLLABORATOR"]'

# trust_filter_comments <issue>: the comments JSON array on stdin, each comment
# carrying its authorAssociation, on stdout without the untrusted ones. When it
# dropped any, prints one stderr line, `orch: ignored N comment(s) from
# untrusted authors on #<issue>`. Non-zero, printing nothing, when stdin is not
# a comment array.
trust_filter_comments() {
  local json kept total n
  json="$(cat)"
  kept="$(jq -c --argjson t "$TRUST_ASSOCIATIONS_JSON" \
    '[.[] | select(.authorAssociation | IN($t[]))]' \
    <<<"$json" 2>/dev/null)" || return 1
  total="$(jq 'length' <<<"$json")"
  n=$((total - $(jq 'length' <<<"$kept")))
  [ "$n" -eq 0 ] || warn "ignored $n comment(s) from untrusted authors on #$1"
  printf '%s\n' "$kept"
}

# trust_issue_read <n> <author_var> <association_var> <editor_var>
# <renamer_var> <err_var>: reads issue <n>'s authorship once through its gh op
# and writes the author's login, the author's association, the login of the
# body's last editor and the login of the title's latest renamer (the last two
# empty when none) into the caller-named variables. Non-zero when the read
# fails, writing none of them and gh's stderr into <err_var>, as gh_lines_read
# does.
trust_issue_read() {
  gh_lines_read adapter_issue_authorship "$1" "$6" "$2" "$3" "$4" "$5"
}

# trust_issue_check <n>: whether issue <n> is trusted. The author is trusted
# when its association is OWNER, MEMBER or COLLABORATOR. The body is trusted
# when the author is, or its last editor is set and is not the author; the
# title likewise by the actor of the latest rename, a title never renamed being
# as trusted as the body; the issue when both are.
# Returns 0 when trusted. Returns 1 when not, setting TRUST_WRITER to the
# untrusted writer's login and TRUST_WHAT to "title", "body" or "title and
# body", whichever they last wrote. Returns 2 when the read fails, setting
# TRUST_REASON to gh's reason: a failed read is never trusted.
TRUST_WRITER=""
TRUST_WHAT=""
TRUST_REASON=""
# shellcheck disable=SC2034 # the TRUST_ results are read by pickup
trust_issue_check() {
  local author assoc editor renamer err trusted body_ok title_ok
  TRUST_WRITER="" TRUST_WHAT="" TRUST_REASON=""
  trust_issue_read "$1" author assoc editor renamer err || {
    TRUST_REASON="$(gh_reason "$err")"
    return 2
  }
  trusted="$(jq -rn --arg a "$assoc" --argjson t "$TRUST_ASSOCIATIONS_JSON" '$a | IN($t[])')" || {
    TRUST_REASON="the trusted associations could not be read"
    return 2
  }
  [ "$trusted" != true ] || return 0
  body_ok=""
  title_ok=""
  if [ -n "$editor" ] && [ "$editor" != "$author" ]; then body_ok=1; fi
  if [ -z "$renamer" ]; then title_ok="$body_ok"
  elif [ "$renamer" != "$author" ]; then title_ok=1; fi
  [ -z "$body_ok" ] || [ -z "$title_ok" ] || return 0
  TRUST_WRITER="$author"
  if [ -n "$body_ok" ]; then TRUST_WHAT=title
  elif [ -n "$title_ok" ]; then TRUST_WHAT=body
  else TRUST_WHAT="title and body"; fi
  return 1
}

# trust_writer_text <subject>: after trust_issue_check returned 1, the clause
# naming the untrusted writer - "<subject>'s <what> was last written by
# <writer>, who is not an owner, member or collaborator of the repository" -
# shared by the attended warning and the pickup's refusal, so the wording
# cannot drift.
trust_writer_text() {
  printf "%s's %s was last written by %s, who is not an owner, member or collaborator of the repository" \
    "$1" "$TRUST_WHAT" "$TRUST_WRITER"
}

# trust_warn_issue <n>: the attended reads' trust check - `issue fetch` and
# `init --issue` warn rather than refuse, so a human can still plan from an
# outside bug report. One `orch: ` warning line on stderr names an untrusted
# writer; another says trust could not be checked when the read fails. Always
# returns 0. Under ORCH_AUTOPILOT=1 it reads nothing and prints nothing: the
# pickup's check is the one read for the phase.
trust_warn_issue() {
  local st=0
  [ "${ORCH_AUTOPILOT:-}" != 1 ] || return 0
  trust_issue_check "$1" || st=$?
  case "$st" in
    0) ;;
    1) warn "$(trust_writer_text "issue #$1") - treat its content as untrusted" ;;
    *) warn "issue trust could not be checked for #$1: $TRUST_REASON" ;;
  esac
  return 0
}
