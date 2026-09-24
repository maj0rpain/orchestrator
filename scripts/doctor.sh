# doctor.sh - diagnostics for the orchestrator plugin, sourced by orch.sh.
#
# One diagnostic replacing the two health checks that came before it. Scopes
# are named for the content they cover, never for the caller that asks -
# `--env` and `--flow`, not `--preflight` and `--status` - so a check's home
# does not move when a caller changes.
#
# Every check reports through the reporter trio and always returns 0: the
# exit status comes from the FAIL counter alone. doctor is the thing you run
# when the world is already broken, so no single check may abort the report.
#
# Also home to triage_table_rows/triage_labels/triage_label_for/
# validate_adopted_issue: reading the triage-labels doc and validating an
# adopted issue is the same "parse this repo's config and report what's wrong
# with it" shape as a check, and init and review file are the two other
# places that shape is needed - so it lives here rather than forking a second
# copy of the label-table parser.
#
# Sourced into orch.sh after its shared mechanism (ROOT, STATE, die, note,
# now, first_line, default_branch, require_state, mp_location, mp_skill_path,
# ORCH_DIR_NAME, PHASES, LABELS_DOC, LABEL_LIMIT, HANDOFF_DIR) is defined.
# cmd_doctor is then dispatched from main() exactly like any other command.

D_OK=0
D_WARN=0
D_FAIL=0
D_GROUPS=0

d_head() { if [ "$D_GROUPS" -gt 0 ]; then note ""; fi; D_GROUPS=$((D_GROUPS + 1)); note "$1"; }
d_ok()   { note "ok    $1"; D_OK=$((D_OK + 1)); }
d_warn() { note "warn  $1"; D_WARN=$((D_WARN + 1)); }
d_fail() { note "FAIL  $1"; D_FAIL=$((D_FAIL + 1)); }

# Remedies are commands, verbatim, never prose: a fix you have to translate out
# of a sentence before you can run it is a fix you postpone.
d_remedy() { local l; for l in "$@"; do note "      $l"; done; }

h_tools()  { d_head "tools"; }
h_auth()   { d_head "auth & remotes"; }
h_plugin() { d_head "plugin environment"; }
h_repo()   { d_head "repo config"; }
h_flow()   { d_head "flow state"; }

# Lists inside doctor are newline-separated, never space-separated: a triage
# label may legally contain a space, and splitting one on whitespace is how a
# diagnostic ends up telling you to create a label called "needs".
d_append() {
  if [ -n "$1" ]; then printf '%s\n%s' "$1" "$2"; else printf '%s' "$2"; fi
}

# Newline-separated in, comma-separated out: a list reads better in a sentence.
d_join() {
  local out="" x
  while IFS= read -r x; do
    if [ -z "$x" ]; then continue; fi
    if [ -n "$out" ]; then out="$out, $x"; else out="$x"; fi
  done <<<"$1"
  printf '%s\n' "$out"
}

# Gates. A check whose answer is unavailable reports *skip* rather than a FAIL it
# derived from not knowing, and the skipped group collapses into a single warn
# naming the cause - N warns, or worse N invented FAILs, would bury the one real
# problem underneath them.
D_GH=""            # "ok", or the reason GitHub could not be asked
D_REPO_NAME=""     # owner/name, as GitHub resolves it
D_REPO_BRANCH=""   # the default branch, as GitHub reports it
D_MP=""            # where mattpocock-skills was found, or empty
D_MP_KIND=""       # which kind of location that is - see mp_location
D_JQ=""            # "ok", or empty when jq is missing
D_STATE=""         # "ok" when state.json parses, or empty
D_GH_SKIPPED=0
D_MP_SKIPPED=0
D_JQ_SKIPPED=0

# A check that needed an answer it could not get counts itself as skipped and
# says nothing of its own, so the group collapses to one line. $1 is the gate's
# answer - "ok" opens it - and $2 names the counter the shut gate collects into.
# Indirect assignment rather than a nameref: bash 3.2 has none, and the bash
# check below promises this file still runs there.
d_gate() {
  if [ "$1" = ok ]; then return 0; fi
  printf -v "$2" '%d' "$(( ${!2} + 1 ))"
  return 1
}

d_gh_gate() { d_probe_gh; d_gate "$D_GH" D_GH_SKIPPED; }

d_skip_line() {
  local n="$1" noun="$2" cause="$3" word="checks"
  if [ "$n" -eq 0 ]; then return 0; fi
  if [ "$n" -eq 1 ]; then word="check"; fi
  # No remedy: reconnecting to a network is not a command.
  d_warn "$n $noun $word skipped: $cause"
}

d_skip_report() {
  if [ $((D_GH_SKIPPED + D_MP_SKIPPED + D_JQ_SKIPPED)) -eq 0 ]; then return 0; fi
  d_head "skipped"
  d_skip_line "$D_GH_SKIPPED" "GitHub" "$D_GH"
  d_skip_line "$D_MP_SKIPPED" "skill"  "mattpocock-skills is not installed"
  d_skip_line "$D_JQ_SKIPPED" "flow"   "jq is not installed"
}

# Ask GitHub at most once, and only when something actually needs it: `gh auth
# status` doubles as the reachability probe. Telling "not authenticated" from
# "could not connect" is the whole basis of the severity rule, and the only
# signal gh offers for it is the text of the failure.
d_probe_gh() {
  local out
  if [ -n "$D_GH" ]; then return 0; fi
  if ! command -v gh >/dev/null 2>&1; then D_GH="gh is not installed"; return 0; fi
  if out="$(gh auth status 2>&1)"; then
    D_GH=ok
  else
    case "$out" in
      *"dial tcp"*|*"lookup "*|*"connection refused"*|*"network is unreachable"*|*imeout*)
        D_GH="GitHub is not reachable" ;;
      *) D_GH="not authenticated" ;;
    esac
  fi
}

d_probe() {
  local scope="$1" view
  if command -v jq >/dev/null 2>&1; then D_JQ=ok; fi
  # A state file that does not parse invalidates every flow check at once.
  # Settled here so that d_run_flow can report it once, ahead of the list, and
  # the checks that would each have run jq at the same broken file never run.
  if [ "$scope" != env ] && [ "$D_JQ" = ok ] && [ -f "$STATE" ] \
     && jq -e . "$STATE" >/dev/null 2>&1; then
    D_STATE=ok
  fi
  # The flow scope runs on every /orchestrator:next and every status, and a flow
  # with no PR recorded has nothing to ask GitHub. It reaches gh through
  # d_gh_gate instead, which probes on first use, so that run costs no round trip.
  if [ "$scope" = flow ]; then return 0; fi
  if D_MP="$(mp_location)"; then
    D_MP_KIND="${D_MP%%$'\t'*}"; D_MP="${D_MP#*$'\t'}"
  else
    D_MP=""
  fi
  d_probe_gh
  if [ "$D_GH" = ok ]; then
    view="$(gh repo view --json nameWithOwner,defaultBranchRef \
      --jq '.nameWithOwner, (.defaultBranchRef.name // "")' 2>/dev/null)" || view=""
    D_REPO_NAME="$(first_line "$view")"
    D_REPO_BRANCH="$(printf '%s\n' "$view" | sed -n 2p)"
  fi
}

# tools ----------------------------------------------------------------------

check_git() {
  if command -v git >/dev/null 2>&1; then d_ok "git present"; return 0; fi
  d_fail "git not found."
  d_remedy "brew install git    # or your platform's package manager"
}

check_gh() {
  if command -v gh >/dev/null 2>&1; then d_ok "gh present"; return 0; fi
  d_fail "gh not found - the spec phase publishes the issue and the PR through it."
  d_remedy "brew install gh    # or your platform's package manager"
}

# Every state operation in this file needs jq, which makes "jq is missing" the
# one message that has to survive without it.
check_jq() {
  if [ "$D_JQ" = ok ]; then d_ok "jq present"; return 0; fi
  d_fail "jq not found - orch.sh reads and writes state.json with it."
  d_remedy "brew install jq    # or your platform's package manager"
}

# A warn, not a FAIL: macOS still ships 3.2 as /bin/bash, and the flow works
# there - mp_location avoids arrays precisely so that it keeps doing so.
check_bash() {
  if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then d_ok "bash ${BASH_VERSION%%(*}"; return 0; fi
  d_warn "bash ${BASH_VERSION%%(*} - orch.sh is written for 4.0 and up."
  d_remedy "brew install bash"
}

# auth & remotes -------------------------------------------------------------

check_origin() {
  local url
  if url="$(git remote get-url origin 2>/dev/null)" && [ -n "$url" ]; then
    d_ok "origin: $url"
    return 0
  fi
  d_fail "no origin remote - the flow pushes the branch and opens the PR there."
  d_remedy "git remote add origin https://github.com/<owner>/<repo>.git"
}

check_gh_auth() {
  case "$D_GH" in
    ok) d_ok "gh authenticated" ;;
    "not authenticated")
      d_fail "gh is not authenticated."
      d_remedy "gh auth login" ;;
    *) d_gate "$D_GH" D_GH_SKIPPED || true ;;
  esac
}

check_gh_repo() {
  d_gh_gate || return 0
  if [ -n "$D_REPO_NAME" ]; then d_ok "repo: $D_REPO_NAME"; return 0; fi
  d_fail "gh cannot resolve this repo - origin may point somewhere you cannot see."
  d_remedy "git remote set-url origin https://github.com/<owner>/<repo>.git"
}

# Worth its own line because getting it wrong is silent: default_branch falls
# back to a local pointer and then to the literal "main", and a feature branch
# forked from the wrong place looks fine until review.
check_default_branch() {
  d_gh_gate || return 0
  # Silent when the repo itself did not resolve: check_gh_repo has already said
  # so, and a second line derived from the first buries it.
  [ -n "$D_REPO_NAME" ] || return 0
  if [ -n "$D_REPO_BRANCH" ]; then d_ok "default branch: $D_REPO_BRANCH (from GitHub)"; return 0; fi
  d_warn "default branch not resolved from GitHub - falling back to $(default_branch)."
  d_remedy "git remote set-head origin --auto"
}

# plugin environment ---------------------------------------------------------

# Names only the detected host's install method - a Junie user told to run a
# Claude /plugin command is no better off. With no host detected, every
# method is listed. check_host sets D_HOST and runs earlier in the same group.
# The Junie line names the two installs #121 found on a real machine: the
# skills CLI store (user story 5) and a Claude plugin installed as a Junie
# extension (the Problem Statement). Neither command is verified end to end.
d_mp_remedy() {
  local c1="Claude Code: /plugin marketplace add anthropics/claude-plugins"
  local c2="             /plugin install mattpocock-skills"
  local junie="Junie:       npx skills add mattpocock/skills    # or install mattpocock/skills as a Junie extension"
  local elsewhere="Elsewhere:   export ORCHESTRATOR_MATTPOCOCK_ROOT=/path/to/mattpocock-skills"
  case "${D_HOST:-}" in
    claude) d_remedy "$c1" "$c2" "$elsewhere" ;;
    junie)  d_remedy "$junie" "$elsewhere" ;;
    *)      d_remedy "$c1" "$c2" "$junie" "$elsewhere" ;;
  esac
}

d_mp_source() {
  case "$D_MP_KIND" in
    override) printf 'ORCHESTRATOR_MATTPOCOCK_ROOT' ;;
    claude)   printf 'Claude Code plugin cache' ;;
    junie)    printf 'Junie extension cache' ;;
    agents)   printf 'skills CLI' ;;
  esac
}

check_mattpocock() {
  if [ -n "$D_MP" ]; then d_ok "mattpocock-skills: ${D_MP/#$HOME/\~} ($(d_mp_source))"; return 0; fi
  # The override is authoritative, so the lookup never looked past it - saying
  # "not installed" would send the user to reinstall what may well be there.
  if [ -n "${ORCHESTRATOR_MATTPOCOCK_ROOT:-}" ]; then
    d_fail "ORCHESTRATOR_MATTPOCOCK_ROOT points at $ORCHESTRATOR_MATTPOCOCK_ROOT, which is not a directory."
    d_remedy "unset ORCHESTRATOR_MATTPOCOCK_ROOT    # or point it at a mattpocock-skills checkout"
    return 0
  fi
  d_fail "mattpocock-skills is not installed - the flow reads its skills directly."
  d_mp_remedy
}

# The check that justifies the feature. mp_location settles where the skills
# are from whatever it finds there first, so a partial or restructured install
# passes it and the flow then dies at the phase that needed the missing skill -
# by which point the session that could have fixed it has been cleared.
MP_SKILLS="to-spec implement code-review handoff"

check_skills() {
  d_gate "${D_MP:+ok}" D_MP_SKIPPED || return 0
  local name missing=""
  for name in $MP_SKILLS; do
    mp_skill_path "$D_MP_KIND" "$D_MP" "$name" >/dev/null || missing="$(d_append "$missing" "$name")"
  done
  if [ -z "$missing" ]; then d_ok "every skill the flow reads resolves"; return 0; fi
  d_fail "mattpocock skills missing: $(d_join "$missing") (looked in: $(d_mp_source))"
  d_mp_remedy
}

# The plugin root doctor runs from: the directory scripts/ sits in, which is
# also where every skill resolves orch.sh and the capabilities reference from.
D_PLUGIN="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_REF="docs/host-capabilities.md"

# The one host detector. Prints "claude", "junie", or nothing when no signal
# is present (orch.sh run by hand in a terminal). ORCHESTRATOR_HOST names the
# host outright, for a shell no signal reaches. Junie's signal is the variable
# its docs say it expands for extension hooks; that it also reaches the shell a
# skill runs orch.sh from is unverified, which is what the override is for.
# Junie is checked before Claude because a Junie started from inside a Claude
# Code terminal inherits CLAUDECODE, never the other way round.
host_detect() {
  if [ -n "${ORCHESTRATOR_HOST:-}" ]; then printf '%s\n' "$ORCHESTRATOR_HOST"; return 0; fi
  if [ -n "${JUNIE_EXTENSION_ROOT:-}" ]; then printf 'junie\n'; return 0; fi
  if [ "${CLAUDECODE:-}" = 1 ] || [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then printf 'claude\n'; fi
}

# The host's column header in the capabilities reference.
host_name() {
  case "$1" in
    claude) printf 'Claude Code\n' ;;
    junie)  printf 'Junie\n' ;;
  esac
}

# The capabilities whose cell in a host's column carries a marker (Fallback or
# Unverified), read from the reference itself rather than restated here, so
# doctor and the table can never disagree. One per line.
host_marked() {
  [ -f "$D_PLUGIN/$HOST_REF" ] || return 0
  awk -F'|' -v host="$1" -v mark="**$2**" '
    function trim(x) { gsub(/^ +| +$/, "", x); return x }
    /^\| *Capability *\|/ { for (i = 2; i < NF; i++) if (trim($i) == host) col = i; next }
    col && /^\|/ && index($col, mark) { print trim($2) }
  ' "$D_PLUGIN/$HOST_REF"
}

D_HOST=""
check_host() {
  local name lacks unverified detail=""
  D_HOST="$(host_detect)"
  if [ -z "$D_HOST" ]; then
    d_warn "host not detected - which capabilities are missing is unknown."
    d_remedy "export ORCHESTRATOR_HOST=claude    # or junie"
    return 0
  fi
  name="$(host_name "$D_HOST")"
  if [ -z "$name" ]; then
    d_warn "ORCHESTRATOR_HOST=$D_HOST names no supported host."
    d_remedy "export ORCHESTRATOR_HOST=claude    # or junie"
    D_HOST=""
    return 0
  fi
  lacks="$(host_marked "$name" Fallback)"
  unverified="$(host_marked "$name" Unverified)"
  if [ -z "$lacks$unverified" ]; then d_ok "host: $name"; return 0; fi
  # Not a failure: the flow runs on this host, with the documented fallbacks.
  # A warn keeps the reduced enforcement in front of the user instead. An
  # unverified cell is reported apart, so doctor never states it as a gap.
  if [ -n "$lacks" ]; then detail="lacks: $(d_join "$lacks")"; fi
  if [ -n "$unverified" ]; then
    detail="${detail:+$detail; }unverified: $(d_join "$unverified")"
  fi
  d_warn "host: $name $detail - fallbacks in $HOST_REF"
}

# Only Claude Code sets CLAUDE_PLUGIN_ROOT, so whether its absence means
# anything depends on the host check above, which runs first.
check_plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then d_ok "CLAUDE_PLUGIN_ROOT set"; return 0; fi
  # No remedy on any host, because nothing is broken: every skill falls back to
  # the orch.sh two directories above its own.
  case "$D_HOST" in
    junie)  d_ok "CLAUDE_PLUGIN_ROOT unset - Junie expands it only in hooks; skills use the relative path." ;;
    claude) d_warn "CLAUDE_PLUGIN_ROOT is not set under Claude Code - orch.sh was run by hand, not through a plugin command." ;;
    *)      d_ok "CLAUDE_PLUGIN_ROOT unset - only Claude Code sets it; skills use the relative path." ;;
  esac
}

# A skills-only install copies the skills without scripts/, so the orch.sh two
# directories above a skill is not there and every step that runs it fails.
# doctor itself runs from an orch.sh, so it can only see such a copy sitting in
# a user-level skill store beside the full install; the skills themselves
# report the case where no full install exists at all. The store is the
# user-level one the skills CLI installs into; Junie's own skill store is not
# yet verified, so it is not scanned.
check_orch_sh() {
  local store="$HOME/.agents/skills" d names=""
  for d in "$store"/orch-*/; do
    [ -f "$d/SKILL.md" ] || continue
    [ -f "$d/../../scripts/orch.sh" ] && continue
    d="${d%/}"; names="$(d_append "$names" "${d##*/}")"
  done
  if [ -z "$names" ]; then d_ok "orch.sh: ${D_PLUGIN/#$HOME/\~}/scripts/orch.sh"; return 0; fi
  # A warn, not a FAIL: the install running this is whole, and which host picks
  # up the skills-only copy is not something doctor can see.
  d_warn "orch.sh missing beside the orchestrator skills in ${store/#$HOME/\~}: $(d_join "$names") - a skills-only install."
  d_orch_remedy
}

# Names only the detected host's install method, like d_mp_remedy.
d_orch_remedy() {
  local c1="Claude Code: /plugin marketplace add maj0rpain/orchestrator"
  local c2="             /plugin install orchestrator@orchestrator"
  local junie="Junie:       install maj0rpain/orchestrator as a Junie extension"
  local after="then remove the skills-only copy named above."
  case "${D_HOST:-}" in
    claude) d_remedy "$c1" "$c2" "$after" ;;
    junie)  d_remedy "$junie" "$after" ;;
    *)      d_remedy "$c1" "$c2" "$junie" "$after" ;;
  esac
}

# repo config ----------------------------------------------------------------

check_tracker_doc() {
  if [ -f "$ROOT/docs/agents/issue-tracker.md" ]; then d_ok "issue tracker configured"; return 0; fi
  d_fail "docs/agents/issue-tracker.md is missing - to-spec and code-review both read it."
  d_remedy "/mattpocock-skills:setup-matt-pocock-skills"
}

# The one place that knows how to read a row out of the triage-label table:
# where it starts and ends, which rows belong to it, and how to clean a cell
# once split out. Emits "role<TAB>name" for every valid data row - the left
# column (the mattpocock/skills role name) and the right column (this repo's
# local label for it) - so triage_labels and triage_label_for always agree on
# what the table contains, including correctly ignoring any other table
# elsewhere in the doc (#39).
triage_table_rows() {
  [ -f "$ROOT/$LABELS_DOC" ] || return 0
  awk -F'|' '
    # One cleanup for any cell pulled out of a split row: restore pipes
    # masked below, strip backticks, trim the pad markdown tables pad cells
    # with - shared so l and r can never drift into cleaning a cell two
    # different ways.
    function clean(s) {
      gsub(/\001/, "|", s)
      gsub(/`/, "", s)
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    # A table ends where the pipes stop. Without this, cols still holds the
    # previous table width when the next table begins - a header row arrives a
    # line before the separator that would correct it - so a narrower second
    # table anywhere in the doc leaks its heading out as a label name.
    !/^[[:space:]]*\|/ { cols = 0 }
    /^[[:space:]]*\|/ {
      # `\|` is the markdown escape for a literal pipe, never a column
      # separator. Mask it before the field split and restore it after, or an
      # escaped cell shifts every column after it for that row (#5).
      line = $0
      gsub(/\\\|/, "\001", line)
      $0 = line
      l = clean($2)
      r = clean($3)
      # The separator row settles the width for the whole table, and only it
      # can. Every separator cell holds a dash run, so an empty field at the
      # end of that row is unambiguously the one a trailing pipe leaves behind
      # - whereas on a data row an empty last field is equally well an empty
      # last cell, and guessing there costs a real label. Markdown lets a row
      # drop its trailing pipe; the leading one the match already requires.
      if (r ~ /^:?-+:?$/) {
        last = $NF
        sub(/^[[:space:]]+/, "", last)
        sub(/[[:space:]]+$/, "", last)
        cols = NF - 1
        if (last == "") cols--
        next
      }
      # cols stays 0 until the separator row, which drops the header with it.
      # Under three columns this is a table of some other shape, where $3 is
      # whichever column happens to sit last and its Meaning text would be read
      # out as a label name and demanded of the repo. A diagnostic may fail to
      # parse a doc; it may not invent an answer from one.
      if (cols < 3) next
      print l "\t" r
    }' "$ROOT/$LABELS_DOC"
}

# Parsed, never hardcoded. That file documents its right-hand column as editable,
# so a hardcoded list of the five canonical names would make doctor confidently
# wrong in exactly the repos that customised themselves - the worst thing a
# diagnostic can be. A thin filter over triage_table_rows: every row's local
# label name, skipping rows that left it blank.
triage_labels() {
  triage_table_rows | awk -F'\t' '$2 != "" { print $2 }'
}

# The local name for one of the five triage roles - the right-hand column of
# the row whose left-hand column names it. A repo that customised its
# vocabulary customised this, and filing under the canonical name there would
# create a second label the repo's triage never reads. The role name itself is
# the answer where the doc is missing or does not list it. Also a thin filter
# over triage_table_rows, so it shares triage_labels' table-boundary and
# column-count guard rather than risking a second table elsewhere in the doc.
triage_label_for() {
  local role="$1" name=""
  name="$(triage_table_rows | awk -F'\t' -v role="$role" '
    $1 == role && $2 != "" { print $2; exit }')"
  printf '%s\n' "${name:-$role}"
}

# `init --issue N`'s one-time gate: the issue must exist, be open, and carry
# this repo's local name for the ready-for-agent role - resolved through
# triage_label_for, never the literal string, so a repo that renamed its
# labels still gets a correct check. Checked once, here, and never again: a
# maintainer's later triage housekeeping must not stop a flow already running
# against the issue (docs/adr/0005).
validate_adopted_issue() {
  local issue="$1" label out state labels
  label="$(triage_label_for ready-for-agent)"
  out="$(gh issue view "$issue" --json state,labels --jq '.state, (.labels[].name)' 2>/dev/null)" \
    || die "issue #$issue could not be read from GitHub - check it exists and gh is authenticated."
  state="$(first_line "$out")"
  labels="$(printf '%s\n' "$out" | tail -n +2)"
  [ "$state" = OPEN ] || die "issue #$issue is not open - adoption requires an open issue."
  printf '%s\n' "$labels" | grep -qxF "$label" \
    || die "issue #$issue is missing the '$label' triage label - adoption requires it."
}

check_labels_doc() {
  local n
  if [ ! -f "$ROOT/$LABELS_DOC" ]; then
    d_fail "$LABELS_DOC is missing - the spec phase labels its issue from it."
    d_remedy "/mattpocock-skills:setup-matt-pocock-skills"
    return 0
  fi
  n="$(triage_labels | grep -c .)" || n=0
  if [ "$n" -gt 0 ]; then d_ok "$n triage labels documented in $LABELS_DOC"; return 0; fi
  d_fail "$LABELS_DOC lists no triage labels - the spec phase labels its issue from it."
  d_remedy "/mattpocock-skills:setup-matt-pocock-skills"
}

# The other check that justifies the feature: the spec phase applies a label at
# `gh issue create`, so a label the repo does not have kills the phase after the
# whole to-spec exchange has already been spent.
check_labels_exist() {
  d_gh_gate || return 0
  local want have missing="" l n
  want="$(triage_labels)" || want=""
  # Nothing to compare against, and check_labels_doc has already said so. One
  # problem earns one FAIL, never a second derived from the first.
  [ -n "$want" ] || return 0
  if ! have="$(gh label list --limit "$LABEL_LIMIT" --json name --jq '.[].name' 2>/dev/null)"; then
    # One check, one cause, one warn: GitHub answered the auth probe and then
    # would not answer this, which is an absent answer rather than a "no".
    d_warn "the repo's labels could not be listed."
    return 0
  fi
  while IFS= read -r l; do
    if [ -z "$l" ]; then continue; fi
    if ! printf '%s\n' "$have" | grep -qxF "$l"; then missing="$(d_append "$missing" "$l")"; fi
  done <<<"$want"
  if [ -z "$missing" ]; then d_ok "every documented triage label exists on the repo"; return 0; fi
  # Found every one of them is a definitive answer whatever the page held, so
  # the cut-off caveat only ever qualifies a *negative*: a label named as
  # missing because it fell past the boundary is exactly the FAIL that teaches
  # someone to stop reading the word.
  n="$(printf '%s\n' "$have" | grep -c .)" || n=0
  if [ "$n" -ge "$LABEL_LIMIT" ]; then
    d_warn "the repo has more than $LABEL_LIMIT labels - cannot confirm: $(d_join "$missing")"
    return 0
  fi
  d_fail "triage labels missing from the repo: $(d_join "$missing")"
  # Quoted, because a label that needs quoting is exactly the one you would
  # paste wrong.
  while IFS= read -r l; do d_remedy "gh label create \"$l\""; done <<<"$missing"
}

# Sub-issues carry no separate enable/disable setting - they are a bundled,
# GA part of Issues on github.com - so the only reliable way to know whether
# this GitHub instance supports them is to ask the endpoint against an issue
# that exists and read whether it answers or 404s. warn, never FAIL: the
# real gate is ticket_publish's own verify-then-die, not this advisory probe
# - a repo that fails it should be told at setup, not discover it mid-flow.
check_sub_issues() {
  d_gh_gate || return 0
  local probe
  probe="$(gh issue list --state all --limit 1 --json number \
    --jq '.[0].number // empty' 2>/dev/null)" || probe=""
  if [ -z "$probe" ]; then
    d_warn "sub-issues support could not be probed - the repo has no issue to test it against."
    return 0
  fi
  if gh api "repos/{owner}/{repo}/issues/$probe/sub_issues" >/dev/null 2>&1; then
    d_ok "sub-issues supported"
    return 0
  fi
  d_warn "sub-issues do not appear to be supported on this GitHub instance - ticket publish will fail its own verify-then-die check at spec time."
}

check_git_exclude() {
  local ex
  # Unguarded, and unreachable: the script died at load time if this were not a
  # git repo, so a check for one could only ever report a world that cannot
  # exist. Not covered by d_run's abort warn either - a check runs as the left
  # operand of ||, which disables errexit for its whole body, so a failure here
  # would carry on with a wrong path rather than stop.
  ex="$(git rev-parse --git-dir)/info/exclude"
  if grep -qxF "$ORCH_DIR_NAME/" "$ex" 2>/dev/null; then
    d_ok "$ORCH_DIR_NAME/ is git-excluded"
    return 0
  fi
  # A warn, not a FAIL: init writes this line, so it only bites someone who
  # arrived mid-flow in a repo that is not theirs.
  d_warn "$ORCH_DIR_NAME/ is not git-excluded - flow state would show as untracked."
  d_remedy "printf '%s\\n' '$ORCH_DIR_NAME/' >>\"\$(git rev-parse --git-dir)/info/exclude\""
}

ENV_CHECKS="
h_tools  check_git check_gh check_jq check_bash
h_auth   check_origin check_gh_auth check_gh_repo check_default_branch
h_plugin check_host check_plugin_root check_orch_sh check_mattpocock check_skills
h_repo   check_tracker_doc check_labels_doc check_labels_exist check_sub_issues check_git_exclude
"

# flow state -----------------------------------------------------------------

# Every check below reads state.json through jq, so a missing jq and a file that
# will not parse each settle all of them at once. Both are decided in d_run_flow,
# before any of them runs, rather than in a preamble each check has to remember:
# a check that forgot would run jq at a broken file and report a confident wrong
# ok, and the review group added for #2 is exactly such an append to the list.
# Reaching a check at all is now the proof that its preconditions held.

check_state_phase() {
  local phase
  phase="$(jq -r '.phase // ""' "$STATE")"
  case " $PHASES " in
    *" $phase "*) d_ok "phase: $phase" ;;
    *) d_fail "unknown phase: $phase (want one of: $PHASES)"
       d_remedy "/orchestrator:abort" ;;
  esac
}

check_flow_branch() {
  local branch
  branch="$(jq -r '.branch // ""' "$STATE")"
  if [ -z "$branch" ]; then d_ok "branch: not created yet"; return 0; fi
  if git rev-parse --verify --quiet "$branch" >/dev/null; then d_ok "branch: $branch"; return 0; fi
  d_fail "branch $branch no longer exists - the flow has nothing left to build on."
  d_remedy "/orchestrator:abort"
}

# Only from the phase that pushes onwards: before implement, not having pushed
# is correct, and a warning about correct state is how people learn to skim past
# the word.
check_flow_upstream() {
  local phase branch
  phase="$(jq -r '.phase // ""' "$STATE")"
  case "$phase" in implement|review|done) ;; *) return 0 ;; esac
  branch="$(jq -r '.branch // ""' "$STATE")"
  [ -n "$branch" ] || return 0
  # origin/<branch> specifically, not just any upstream: branch create forks off
  # origin/<default>, which leaves that as the upstream until the first push. An
  # ok there would report a branch nobody can see as pushed.
  local upstream=""
  upstream="$(git rev-parse --abbrev-ref --verify --quiet "$branch@{upstream}" 2>/dev/null)" || upstream=""
  if [ "$upstream" = "origin/$branch" ]; then d_ok "upstream: $upstream"; return 0; fi
  d_warn "branch $branch is not on origin yet."
  d_remedy "git push -u origin $branch"
}

# Unconditional on how the issue arrived - adopted at init or published by
# to-spec, state.json carries no field distinguishing the two, and none is
# needed here: both are just "the flow's spec issue" once a flow is running
# against one. The ready-for-agent label is deliberately not re-checked; it is
# a one-time gate at adoption, not an ongoing flow invariant (docs/adr/0005).
check_flow_issue() {
  local issue issue_state phase
  issue="$(jq -r '.issue // ""' "$STATE")"
  if [ -z "$issue" ]; then d_ok "issue: not recorded yet"; return 0; fi
  d_gh_gate || return 0
  issue_state="$(gh issue view "$issue" --json state --jq .state 2>/dev/null)" || issue_state=""
  phase="$(jq -r '.phase // ""' "$STATE")"
  case "$issue_state" in
    OPEN)   d_ok "issue #$issue open" ;;
    CLOSED)
      # pr open always writes `Closes #<issue>`, so a done flow's issue being
      # closed is the expected result of merging, not a broken flow.
      if [ "$phase" = done ]; then
        d_ok "issue #$issue closed"
      else
        d_fail "issue #$issue is closed."; d_remedy "gh issue reopen $issue"
      fi
      ;;
    *)      d_fail "issue #$issue could not be read from GitHub."; d_remedy "gh issue view $issue" ;;
  esac
}

check_flow_pr() {
  local pr pr_state
  pr="$(jq -r '.pr // ""' "$STATE")"
  if [ -z "$pr" ]; then d_ok "PR: not opened yet"; return 0; fi
  d_gh_gate || return 0
  pr_state="$(gh pr view "$pr" --json state --jq .state 2>/dev/null)" || pr_state=""
  case "$pr_state" in
    OPEN)   d_ok "PR #$pr open" ;;
    MERGED) d_ok "PR #$pr merged" ;;
    CLOSED) d_fail "PR #$pr is closed."; d_remedy "gh pr reopen $pr" ;;
    *)      d_fail "PR #$pr could not be read from GitHub."; d_remedy "gh pr view $pr" ;;
  esac
}

# Proactive surface for the same classification `redo review` refuses on -
# a human sees "this loop looks interrupted" before wondering why redo
# won't run. Phase-gated like check_flow_upstream: outside review, there is
# no loop to classify and nothing to say about one.
check_flow_review_terminal() {
  local phase i b terminal word detail
  phase="$(jq -r '.phase // ""' "$STATE")"
  [ "$phase" = review ] || return 0
  i="$(jq -r '.iteration // 0' "$STATE")"
  b="$(review_budget)"
  terminal="$(review_terminal_state)" || true
  word="$(first_line "$terminal")"
  detail="$(printf '%s\n' "$terminal" | tail -n +2)"
  case "$word" in
    none)  d_ok "review loop: not started yet" ;;
    ready) d_ok "review loop at a terminal state: ready" ;;
    stop)  d_ok "review loop at a terminal state: stop ($(first_line "$detail"))" ;;
    # Both warn rather than FAIL: /orchestrator:next resumes either one, and a
    # FAIL here would block the one command that can move a mid-flight loop
    # forward. The two read as distinct situations, not one "interrupted"
    # message covering both: a loop still short of its budget is proceeding
    # normally, where one whose last iteration recorded nothing looks like the
    # session that was driving it simply died.
    pending)
      d_warn "review loop hasn't reached its budget yet (iteration $i of budget $b) - /orchestrator:next will resume it; /orchestrator:redo refuses until it reaches a terminal state." ;;
    interrupted)
      d_warn "review loop's last iteration ($i of budget $b) has no recorded terminal state - the session looks interrupted, not stopped. /orchestrator:next will resume it; /orchestrator:redo refuses until it reaches a terminal state." ;;
  esac
}

# `review begin` dies rather than start an iteration past budget, so this is
# meant to be unreachable - an iteration count past it is not a loop still
# running, it is state.json in a shape nothing produced on a healthy run.
check_flow_review_budget() {
  local phase i b
  phase="$(jq -r '.phase // ""' "$STATE")"
  [ "$phase" = review ] || return 0
  i="$(jq -r '.iteration // 0' "$STATE")"
  b="$(review_budget)"
  if [ "$i" -gt "$b" ]; then
    d_fail "review loop iteration ($i) is past its budget ($b) - the loop's stop enforcement did not hold."
    d_remedy "/orchestrator:abort"
    return 0
  fi
  d_ok "review loop iteration ($i) within budget ($b)"
}

# The loop requires CI green (with one flake rerun) before it marks the PR
# ready, so ci_probe's own classification is the loop's read of exactly this -
# reused rather than a second query of the same endpoint. Doctor asks once and
# reports what it sees now; the grace/timeout widening in `review ci` belongs
# to the live loop deciding whether to keep polling, which a snapshot has no
# business doing. required, not all: branch protection's required set is what
# the loop itself waits on once one is named.
check_flow_review_ci() {
  local phase pr res verdict detail
  phase="$(jq -r '.phase // ""' "$STATE")"
  [ "$phase" = review ] || return 0
  pr="$(jq -r '.pr // ""' "$STATE")"
  [ -n "$pr" ] || return 0
  d_gh_gate || return 0
  res="$(ci_probe "$pr" required)"
  verdict="$(first_line "$res")"
  detail="$(printf '%s\n' "$res" | tail -n +2)"
  case "$verdict" in
    green)   d_ok "CI: required checks green" ;;
    none)    d_ok "CI: no required checks reported" ;;
    pending) d_ok "CI: required checks still pending" ;;
    failing)
      d_fail "CI: required check(s) failing on PR #$pr."
      d_remedy "gh pr checks $pr"
      ;;
    # ci_probe's only other word - a failing round trip. Not fixable from here,
    # so no remedy: reconnecting to a network, or GitHub answering, is not a
    # command either.
    *) d_warn "CI: could not be read from GitHub for PR #$pr." ;;
  esac
  [ -z "$detail" ] || note "$detail"
}

# `review ready` marks the PR ready and records phase: done as one operation
# precisely so neither half can happen without the other (see `review ready`) -
# so isDraft and phase disagreeing on GitHub's own PR is evidence that
# operation only half landed, not a state a healthy flow reaches on its own.
check_flow_review_draft() {
  local phase pr out pr_state is_draft
  phase="$(jq -r '.phase // ""' "$STATE")"
  case "$phase" in review|done) ;; *) return 0 ;; esac
  pr="$(jq -r '.pr // ""' "$STATE")"
  [ -n "$pr" ] || return 0
  d_gh_gate || return 0
  out="$(gh pr view "$pr" --json state,isDraft --jq '.state, .isDraft' 2>/dev/null)" || out=""
  pr_state="$(first_line "$out")"
  is_draft="$(printf '%s\n' "$out" | sed -n 2p)"
  if [ -z "$pr_state" ]; then
    d_warn "PR #$pr draft state could not be read from GitHub."
    return 0
  fi
  # A merged or closed PR cannot go back to draft, so only an open PR's flag
  # is a live signal - nothing left there to disagree with the flow's phase.
  [ "$pr_state" = OPEN ] || return 0
  if [ "$phase" = done ] && [ "$is_draft" = true ]; then
    d_fail "PR #$pr is still a draft but the flow phase is done - review ready did not take."
    d_remedy "gh pr ready $pr"
  elif [ "$phase" = review ] && [ "$is_draft" = false ]; then
    d_fail "PR #$pr was marked ready on GitHub but the flow phase is still review - state.json fell out of sync."
    d_remedy "gh pr view $pr"
  else
    d_ok "PR #$pr draft state matches phase ($phase)"
  fi
}

# Pure reuse: what makes a handoff valid lives in handoff_required and
# section_body, and a second statement of it here is how the two answers drift.
# Which handoffs are due is mechanical - phase names what runs *next*, so every
# earlier phase has already written one.
check_flow_handoffs() {
  local phase files f path problems line
  phase="$(jq -r '.phase // ""' "$STATE")"
  case "$phase" in
    spec)        files="01-plan.md" ;;
    implement)   files="01-plan.md 02-spec.md" ;;
    review|done) files="01-plan.md 02-spec.md 03-implement.md" ;;
    *) return 0 ;;
  esac
  for f in $files; do
    path="$HANDOFF_DIR/$f"
    if [ ! -f "$path" ]; then
      d_fail "handoff $f is missing - the phase that writes it has already run."
      d_remedy "/orchestrator:redo"
      continue
    fi
    problems="$(handoff_report "$path" | grep -v '^ok ' || true)"
    if [ -z "$problems" ]; then d_ok "handoff $f complete"; continue; fi
    while IFS= read -r line; do d_fail "handoff $f: ${line#FAIL }"; done <<<"$problems"
    d_remedy "/orchestrator:redo"
  done
}

FLOW_CHECKS="
h_flow check_state_phase check_flow_issue check_flow_branch check_flow_upstream check_flow_pr check_flow_review_terminal check_flow_review_budget check_flow_review_ci check_flow_review_draft check_flow_handoffs
"

# A registry's entries, one per line. Splitting a whitespace-separated list is
# where a stray glob character would silently drop a check, so globbing goes off
# across the split and is *restored* rather than switched on - a caller may have
# its own set -f window, and handing globbing back inside one is the very thing
# the window exists to prevent. bash cannot return an argument list from a
# function, so the entries come back newline-separated and callers read them;
# that also keeps this dance in one place rather than at every call site.
d_entries() {
  local glob
  case "$-" in *f*) glob=off ;; *) glob=on ;; esac
  set -f
  set -- $1
  if [ "$glob" = on ]; then set +f; fi
  if [ $# -gt 0 ]; then printf '%s\n' "$@"; fi
}

# How many checks a registry stands for, so a skip line can say so without
# anyone keeping the number in their head. Headers are not checks.
d_count() {
  local n=0 e
  while IFS= read -r e; do
    case "$e" in ""|h_*) ;; *) n=$((n + 1)) ;; esac
  done <<<"$(d_entries "$1")"
  printf '%s\n' "$n"
}

# The gate the flow checks used to carry one at a time, hoisted to the list.
d_run_flow() {
  if [ "$D_JQ" = ok ] && [ "$D_STATE" = ok ]; then
    d_run "$FLOW_CHECKS"
    return 0
  fi
  # Neither path below reaches a check, so neither gets the header out of the
  # registry the way the dispatch above does - and a skip line or a FAIL still
  # belongs under "flow state" like everything else.
  h_flow
  if [ "$D_JQ" != ok ]; then
    D_JQ_SKIPPED=$((D_JQ_SKIPPED + $(d_count "$FLOW_CHECKS")))
    return 0
  fi
  # One problem earns one FAIL. Every check reads this file, so there is nothing
  # left to say about it and nothing that could be said honestly.
  d_fail "$ORCH_DIR_NAME/state.json is not valid JSON."
  d_remedy "/orchestrator:abort"
}

d_run() {
  local entry
  while IFS= read -r entry; do
    if [ -z "$entry" ]; then continue; fi
    # Catches a check that returns non-zero, and nothing else: being the left
    # operand of || suppresses errexit for the whole body, so a check that hits
    # a failing command does not abort here - it carries on with whatever state
    # that left behind. Every check is written to return 0, which is why this
    # arm stays quiet in practice; keeping errexit live while still collecting
    # a status needs the check launched as a background job and waited on, and
    # that waits for the review group in #2 to give it something to protect.
    "$entry" || d_warn "$entry could not run."
  done <<<"$(d_entries "$1")"
}

cmd_doctor() {
  local scope=both
  [ $# -le 1 ] || die "usage: orch.sh doctor [--env|--flow]"
  case "${1:-}" in
    "")     scope=both ;;
    --env)  scope=env ;;
    --flow) scope=flow ;;
    *)      die "unknown doctor flag: $1 (want --env or --flow)" ;;
  esac

  d_probe "$scope"
  if [ "$scope" != flow ]; then d_run "$ENV_CHECKS"; fi
  if [ "$scope" != env ]; then
    # --flow asks about a flow specifically, so having none is a failure there.
    # Bare doctor did not ask, so it states the absence and carries on: an empty
    # answer must never be mistaken for a healthy one.
    if [ "$scope" = flow ]; then require_state; fi
    if [ ! -f "$STATE" ]; then
      h_flow
      d_ok "no active flow"
    elif [ "$scope" = flow ] && [ "$D_JQ" != ok ]; then
      # --flow never runs the tools group, so nothing else here would report the
      # jq that every check below needs. Skipping all five and still exiting 0
      # is the one answer a diagnostic must never give - and /orchestrator:next
      # gates on exactly that exit code.
      d_run "h_flow check_jq"
    else
      d_run_flow
    fi
  fi

  d_skip_report
  note ""
  note "$D_OK ok, $D_WARN warn, $D_FAIL FAIL"
  [ "$D_FAIL" -eq 0 ] || return 1
}
