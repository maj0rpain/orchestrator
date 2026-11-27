# shellcheck shell=bash
# trust.sh - the Trust module: a concept module with no orch.sh noun of its own.
# Its fork-PR filter and issue trust check are kept here with no bash caller;
# the Python copy, orch/trust.py, decides which PRs orch.sh takes for its own
# and which issue authors it trusts. A PR is its own when its head branch lives
# in the repo (isCrossRepository false); a fork PR is dropped (orch/trust.py's
# trust_filter_prs, the bash copy below kept beside it). Which comments
# orch.sh reads - those whose authorAssociation is OWNER, MEMBER or
# COLLABORATOR (ADR-0057) - is decided by orch/trust.py's filter_comments.
# Which issues autopilot runs on is decided by the Python copy, orch/trust.py's
# issue_check: an issue is trusted when its body and its title both are. The
# bash copy below (trust_issue_check) has no caller left.
# Its tests: scripts/test/orch/trust.sh.
# Sourced by orch.sh, after common.sh.

# The associations of a trusted author, as space-separated words, which the
# issue check reads.
TRUST_ASSOCIATIONS="OWNER MEMBER COLLABORATOR"

# trust_filter_prs <subject>: an adapter's PR lines on stdin, each
# `<number>[\t<field>...]\t<isCrossRepository>`, on stdout as the same lines
# without the flag and without the fork PRs (flag `true`), in order. <subject>
# is the branch or `#<issue>` the PRs were looked up for. When it dropped any,
# prints one stderr line, `orch: ignored N PR(s) from forks for <subject>`.
# Non-zero, printing nothing, when a line's first field is not a PR number or
# its last is neither `true` nor `false`. No bash caller is left: the converted
# nouns filter through orch/trust.py's copy.
trust_filter_prs() {
  local kept_and_count n kept
  kept_and_count="$(awk -F'\t' -v OFS='\t' '
    NF == 0 { next }
    $1 !~ /^[0-9]+$/ || NF < 2 || ($NF != "true" && $NF != "false") { exit 1 }
    $NF == "true" { dropped++; next }
    { NF--; print }
    END { print dropped + 0 }
  ')" || return 1
  n="${kept_and_count##*$'\n'}"
  kept=""
  [ "$kept_and_count" = "$n" ] || kept="${kept_and_count%$'\n'*}"
  [ "$n" -eq 0 ] || warn "ignored $n PR(s) from forks for $1"
  [ -z "$kept" ] || printf '%s\n' "$kept"
}

# trust_issue_read <n> <author> <assoc> <editor> <renamer> <err>:
# reads issue <n>'s authorship once through its gh op
# and writes the author's login, the author's association, the login of the
# body's last editor and the login of the title's latest renamer (the last two
# empty when none) into the caller-named variables <author>, <assoc>,
# <editor> and <renamer>. Non-zero when the read fails, writing none of them
# and gh's stderr into <err>, as gh_lines_read does.
trust_issue_read() {
  gh_lines_read adapter_issue_authorship "$1" "$6" "$2" "$3" "$4" "$5"
}

TRUST_WRITER=""
TRUST_WHAT=""
TRUST_REASON=""
# The TRUST_ results were read by the bash pickup, gone with the bash
# autopilot noun.
# shellcheck disable=SC2034

# trust_issue_check <n>: whether issue <n> is trusted. The author is trusted
# when its association is OWNER, MEMBER or COLLABORATOR. The body is trusted
# when the author is, or its last editor is set and is not the author; the
# title likewise by the actor of the latest rename, a title never renamed being
# as trusted as the body; the issue when both are.
# Returns 0 when trusted. Returns 1 when not, setting TRUST_WRITER to the
# untrusted writer's login and TRUST_WHAT to "title", "body" or "title and
# body", whichever they last wrote. Returns 2 when the read fails, setting
# TRUST_REASON to gh's reason: a failed read is never trusted.
trust_issue_check() {
  local author assoc editor renamer err body_ok title_ok
  TRUST_WRITER="" TRUST_WHAT="" TRUST_REASON=""
  trust_issue_read "$1" author assoc editor renamer err || {
    TRUST_REASON="$(gh_reason "$err")"
    return 2
  }
  ! word_listed "$TRUST_ASSOCIATIONS" "$assoc" || return 0
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
# <writer>, who is not an owner, member or collaborator of the repository".
# No bash caller is left: the pickup's refusal and the attended warning `init
# --issue` and `issue fetch` print, all converted nouns, word it through
# orch/trust.py's copy.
trust_writer_text() {
  printf "%s's %s was last written by %s, who is not an owner, member or collaborator of the repository" \
    "$1" "$TRUST_WHAT" "$TRUST_WRITER"
}

