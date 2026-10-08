# shellcheck shell=bash
# doctor.sh - diagnostics for the orchestrator plugin, sourced by orch.sh only.
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
# Also home to validate_adopted_issue: validating an adopted issue is the same
# "parse this repo's config and report what's wrong with it" shape as a
# check, and init needs that shape too. The triage-label parser it and the
# checks read lives in triage-labels.sh.
#
# Sourced into orch.sh after its shared mechanism (ROOT, STATE, die, note,
# now, first_line, capture, default_branch, base_setting, origin_has_branch,
# require_state, labels_have, issue_state_labels_read,
# ORCH_DIR_NAME, PHASES, LABEL_LIMIT, HANDOFF_DIR) and triage-labels.sh
# (LABELS_DOC, TRIAGE_ROLES, triage_table_rows, triage_labels,
# triage_label_for, triage_expected_labels) are defined. cmd_doctor is then
# dispatched from main() exactly like any other command.

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
D_REPO_SEEN=""     # "ok" when GitHub answered for the repo, or empty
D_REPO_REASON=""   # gh's first line when that read failed, or empty
D_REPO_BRANCH=""   # the default branch, as GitHub reports it, when valid
D_JQ=""            # "ok", or empty when jq is missing
D_STATE=""         # "ok" when state.json parses, or empty
D_GH_SKIPPED=0
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
  # No remedy: the cause is bare, and its remedy, where one exists, is
  # given once by the check that found it.
  d_warn "$n $noun $word skipped: $cause"
}

d_skip_report() {
  if [ $((D_GH_SKIPPED + D_JQ_SKIPPED)) -eq 0 ]; then return 0; fi
  d_head "skipped"
  d_skip_line "$D_GH_SKIPPED" "GitHub" "$D_GH"
  d_skip_line "$D_JQ_SKIPPED" "flow"   "jq is not installed"
}

# gh_installed: whether a gh binary is on PATH. type -P, not command -v:
# orch.sh's gh guard is a function, which command -v would report as present
# with no gh installed.
gh_installed() { type -P gh >/dev/null 2>&1; }

# Ask GitHub at most once, and only when something actually needs it: `gh auth
# status` doubles as the reachability probe. Telling "not authenticated" from
# "could not connect" is the whole basis of the severity rule, and the only
# signal gh offers for it is the text of the failure.
d_probe_gh() {
  local out
  if [ -n "$D_GH" ]; then return 0; fi
  if ! gh_installed; then D_GH="gh is not installed"; return 0; fi
  # The guard dies with no repo to pin its calls to; ask nothing instead.
  if ! repo_resolve; then D_GH="no GitHub repo to work on"; return 0; fi
  if out="$(adapter_auth_status 2>&1)"; then
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
  local scope="$1" view err
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
  d_probe_gh
  # The same read default_branch makes, validated the same way (#485): an
  # answer that is no branch name - a tool manager's banner around it, or an
  # empty one - is GitHub not having said, never a name to report.
  [ "$D_GH" = ok ] || return 0
  if capture view err adapter_repo_default_branch "$REPO_NAME"; then
    D_REPO_SEEN=ok
    if is_branch_name "$view"; then D_REPO_BRANCH="$view"; fi
  else
    D_REPO_REASON="${err%%$'\n'*}"
  fi
}

# tools ----------------------------------------------------------------------

check_git() {
  if command -v git >/dev/null 2>&1; then d_ok "git present"; return 0; fi
  d_fail "git not found."
  d_remedy "brew install git    # or your platform's package manager"
}

check_gh() {
  if gh_installed; then d_ok "gh present"; return 0; fi
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
# there.
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

# The repo the orchestrator works on (#520), resolved locally through
# repo_resolve - never the dying guard - so a checkout with none is a FAIL here
# while d_gh_gate counts every later GitHub check on the skip line. gh's own
# default repo, which in a fork is the upstream, is only a warn: orch.sh pins
# every call to the resolved repo regardless.
check_gh_repo() {
  local default owner_name
  if ! repo_resolve; then
    d_fail "$REPO_CAUSE"
    d_remedy "export GH_REPO=<owner>/<repo>"
    return 0
  fi
  d_ok "repo: $REPO_NAME ($REPO_SOURCE)"
  # set-default --view reads local git config, so it needs gh but no network.
  # It prints a bare owner/name even for a default off github.com, so it is
  # compared with REPO_NAME's owner/name, any host dropped.
  if gh_installed; then
    default="$(adapter_repo_local_default 2>/dev/null)" || default=""
    default="$(first_line "$default")"
    owner_name="$(repo_owner_name "$REPO_NAME")"
    case "$default" in
      */*) if [ "$default" != "$owner_name" ]; then
             d_warn "gh's default repo is $default; the orchestrator uses $REPO_NAME"
           fi ;;
    esac
  fi
  d_gh_gate || return 0
  if [ -n "$D_REPO_SEEN" ]; then return 0; fi
  d_fail "GitHub cannot see $REPO_NAME - origin may point somewhere you cannot see: ${D_REPO_REASON:-gh gave no reason}"
  d_remedy "git remote set-url origin https://github.com/<owner>/<repo>.git"
}

# Worth its own line because getting it wrong is silent: default_branch falls
# back to a local pointer and then to the literal "main", and a feature branch
# forked from the wrong place looks fine until review.
check_default_branch() {
  d_gh_gate || return 0
  # Silent when the repo itself did not resolve: check_gh_repo has already said
  # so, and a second line derived from the first buries it.
  [ -n "$D_REPO_SEEN" ] || return 0
  if [ -n "$D_REPO_BRANCH" ]; then d_ok "default branch: $D_REPO_BRANCH (from GitHub)"; return 0; fi
  d_warn "default branch not resolved from GitHub - falling back to $(default_branch)."
  d_remedy "git remote set-head origin --auto"
}

# plugin environment ---------------------------------------------------------

# The plugin root doctor runs from: the directory scripts/ sits in, which is
# also where every skill resolves orch.sh and the capabilities reference from.
# Worked out from this file's own path by parameter expansion, as dirname would
# print its directory, so it holds however doctor.sh is sourced.
D_SOURCE="${BASH_SOURCE[0]}"
case "$D_SOURCE" in
  /*/*|[!/]*/*) D_SCRIPTS="${D_SOURCE%/*}" ;;
  /*) D_SCRIPTS="/" ;;
  *) D_SCRIPTS="." ;;
esac
D_PLUGIN="$(CDPATH='' cd -- "$D_SCRIPTS/.." && pwd)"
HOST_REF="docs/host-capabilities.md"

# The one host detector. Prints "claude", "junie", or nothing when no signal
# is present (orch.sh run by hand in a terminal). ORCHESTRATOR_HOST names the
# host outright, for a shell no signal reaches. Junie has two signals:
# JUNIE_EXTENSION_ROOT, which its docs say it expands for extension hooks, and
# JUNIE_SHIM_PATH, which Junie CLI exports to the agent's shell a skill runs
# orch.sh from (orch-bench run j1), where JUNIE_EXTENSION_ROOT is unset. Of the
# variables that shell gets (JUNIE_DATA, JUNIE_SHIM_PATH, JUNIE_TMPDIR),
# JUNIE_SHIM_PATH is the one least likely to be set in a user's own profile.
# Junie is checked before Claude because a Junie started from inside a Claude
# Code terminal inherits CLAUDECODE. The reverse case is accepted: a Claude
# Code started from a Junie shell that inherits JUNIE_SHIM_PATH is detected as
# Junie, and ORCHESTRATOR_HOST=claude fixes it.
host_detect() {
  if [ -n "${ORCHESTRATOR_HOST:-}" ]; then printf '%s\n' "$ORCHESTRATOR_HOST"; return 0; fi
  if [ -n "${JUNIE_EXTENSION_ROOT:-}" ] || [ -n "${JUNIE_SHIM_PATH:-}" ]; then
    printf 'junie\n'; return 0
  fi
  if [ "${CLAUDECODE:-}" = 1 ] || [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then printf 'claude\n'; fi
}

# The host's column header in the capabilities reference.
host_name() {
  case "$1" in
    claude) printf 'Claude Code\n' ;;
    junie)  printf 'Junie CLI\n' ;;
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
# report the case where no full install exists at all. Two user-level stores
# are scanned whatever the host: the one the skills CLI installs into, and
# Claude Code's own. Junie's own skill store is not yet verified, so it is not
# scanned.
check_orch_sh() {
  local store d real names found="" seen=""
  for store in "$HOME/.agents/skills" "$HOME/.claude/skills"; do
    names=""
    for d in "$store"/orch-*/; do
      [ -f "$d/SKILL.md" ] || continue
      # `..` after a symlinked folder resolves physically, so this looks beside
      # the real folder, not beside the link.
      [ -f "$d/../../scripts/orch.sh" ] && continue
      # The skills CLI (checked against v1.7.0) links ~/.claude/skills/<skill>
      # into ~/.agents/skills, so one copy can be reached from both stores:
      # report it once.
      real="$(cd "$d" && pwd -P)" || continue
      if printf '%s\n' "$seen" | grep -qxF "$real"; then continue; fi
      seen="$(d_append "$seen" "$real")"
      d="${d%/}"; names="$(d_append "$names" "${d##*/}")"
    done
    [ -n "$names" ] || continue
    # A warn, not a FAIL: the install running this is whole, and which host
    # picks up the skills-only copy is not something doctor can see.
    d_warn "orch.sh missing beside the orchestrator skills in ${store/#$HOME/\~}: $(d_join "$names") - a skills-only install."
    found=1
  done
  if [ -z "$found" ]; then d_ok "orch.sh: ${D_PLUGIN/#$HOME/\~}/scripts/orch.sh"; return 0; fi
  d_orch_remedy
}

# Names only the detected host's install method - a Junie user told to run a
# Claude /plugin command is no better off. With no host detected, every
# method is listed.
d_orch_remedy() {
  local c1="Claude Code: /plugin marketplace add maj0rpain/orchestrator"
  local c2="             /plugin install orchestrator@orchestrator"
  local junie="Junie:       install maj0rpain/orchestrator as a Junie extension (unverified)"
  local after="then remove the skills-only copy named above."
  case "${D_HOST:-}" in
    claude) d_remedy "$c1" "$c2" "$after" ;;
    junie)  d_remedy "$junie" "$after" ;;
    *)      d_remedy "$c1" "$c2" "$junie" "$after" ;;
  esac
}

# repo config ----------------------------------------------------------------

# `init --issue N`'s one-time gate: the issue must exist, be open, and carry
# this repo's local name for the ready-for-agent role - resolved through
# triage_label_for, never the literal string, so a repo that renamed its
# labels still gets a correct check. Checked once, here, and never again: a
# maintainer's later triage housekeeping must not stop a flow already running
# against the issue (docs/adr/0005).
validate_adopted_issue() {
  local issue="$1" label state labels gh_line
  label="$(triage_label_for ready-for-agent)"
  issue_state_labels_read "$issue" state labels gh_line \
    || die "issue #$issue could not be read from GitHub - check it exists and gh is authenticated: ${gh_line:-gh gave no reason}"
  [ "$state" = OPEN ] || die "issue #$issue is not open - adoption requires an open issue."
  labels_have "$labels" "$label" \
    || die "issue #$issue is missing the '$label' triage label - adoption requires it."
}

# Absent is fine: the canonical names apply. Present but unreadable is a FAIL,
# because a doc that exists was meant to say something.
check_labels_doc() {
  local n
  if [ ! -f "$ROOT/$LABELS_DOC" ]; then
    d_ok "no $LABELS_DOC - the canonical triage label names apply"
    return 0
  fi
  n="$(triage_labels | grep -c .)" || n=0
  if [ "$n" -gt 0 ]; then d_ok "$n triage labels documented in $LABELS_DOC"; return 0; fi
  d_fail "$LABELS_DOC lists no triage labels - the spec phase labels its issue from it."
  d_remedy "fix $LABELS_DOC's table, or delete it to use the canonical names"
}

# The other check that justifies the feature: the spec phase applies a label at
# `gh issue create`, so a label the repo does not have kills the phase after the
# whole orch-to-spec exchange has already been spent.
check_labels_exist() {
  d_gh_gate || return 0
  local want have err gh_line missing="" l n
  want="$(triage_expected_labels)" || want=""
  # Nothing to compare against, and check_labels_doc has already said so. One
  # problem earns one FAIL, never a second derived from the first.
  [ -n "$want" ] || return 0
  if ! capture have err adapter_labels "$LABEL_LIMIT"; then
    # One check, one cause, one warn: GitHub answered the auth probe and then
    # would not answer this, which is an absent answer rather than a "no".
    gh_line="${err%%$'\n'*}"
    d_warn "the repo's labels could not be listed: ${gh_line:-gh gave no reason}"
    return 0
  fi
  while IFS= read -r l; do
    if [ -z "$l" ]; then continue; fi
    if ! labels_have "$have" "$l"; then missing="$(d_append "$missing" "$l")"; fi
  done <<<"$want"
  if [ -z "$missing" ]; then d_ok "every triage label exists on the repo"; return 0; fi
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
# A probe that fails outright (a 5xx, a 403, no connection) is neither answer,
# and says so in gh's own first line (#554).
check_sub_issues() {
  d_gh_gate || return 0
  local probe err gh_line
  if ! capture probe err adapter_sub_issues_supported; then
    gh_line="${err%%$'\n'*}"
    d_warn "sub-issues support could not be probed: ${gh_line:-gh gave no reason}"
    return 0
  fi
  if [ -z "$probe" ]; then
    d_warn "sub-issues support could not be probed - the repo has no issue to test it against."
    return 0
  fi
  if [ "$probe" = yes ]; then
    d_ok "sub-issues supported"
    return 0
  fi
  d_warn "sub-issues do not appear to be supported on this GitHub instance - ticket publish will fail its own verify-then-die check at spec time."
}

check_git_exclude() {
  local ex d missing=()
  # Unguarded, and unreachable: the script died at load time if this were not a
  # git repo, so a check for one could only ever report a world that cannot
  # exist. Not covered by d_run's abort warn either - a check runs as the left
  # operand of ||, which disables errexit for its whole body, so a failure here
  # would carry on with a wrong path rather than stop.
  ex="$(git rev-parse --git-common-dir)/info/exclude"
  for d in "${EXCLUDED_DIRS[@]}"; do
    grep -qxF "$d" "$ex" 2>/dev/null || missing+=("$d")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    d_ok "$(d_join "$(printf '%s\n' "${EXCLUDED_DIRS[@]}")") git-excluded"
    return 0
  fi
  # A warn, not a FAIL: init writes these lines, so it only bites someone who
  # arrived mid-flow in a repo that is not theirs. One warning for every missing
  # line, and a remedy that appends only those.
  d_warn "$(d_join "$(printf '%s\n' "${missing[@]}")") not git-excluded - flow state and planning drafts would show as untracked."
  d_remedy "printf '%s\\n' $(printf "'%s' " "${missing[@]}")>>\"\$(git rev-parse --git-common-dir)/info/exclude\""
}

# The base branch every new flow and quick implementation will fork from and
# target. A setting whose branch has since gone from origin is the one stale
# answer that would send the next fork at nothing, so it FAILs; origin being
# unreachable only means it could not be checked. The default case reuses the
# default branch GitHub already answered in d_probe - the same answer
# base_branch would ask for again - and needs no origin check at all.
check_base_branch() {
  local b st=0
  b="$(base_setting)"
  if [ -z "$b" ]; then
    d_ok "base branch: ${D_REPO_BRANCH:-$(default_branch)} (default)"
    return 0
  fi
  origin_has_branch "$b" || st=$?
  case "$st" in
    0) d_ok "base branch: $b (set)" ;;
    2)
      d_fail "base branch $b is set but no longer exists on origin - new flows would fork from nothing."
      d_remedy "orch.sh base clear" "orch.sh base set <branch>" ;;
    *) d_warn "base branch $b (set) could not be verified - origin is not reachable." ;;
  esac
}

# A finished side checkout left standing is a leftover the sweep has not run
# on: warn on each, with the command that removes it, and say nothing for one
# still in use. The finished test is the sweep's own, side_checkout_finished.
# With no side checkout there is nothing to ask GitHub, so the gate - and a
# skip with GitHub unreachable - only counts once one exists.
check_side_checkouts_finished() {
  local path paths=() found=() verdict branch rc main_root
  mapfile -t paths < <(checkout_paths)
  # checkout_paths lists the main checkout first.
  main_root="${paths[0]-}"
  for path in "${paths[@]}"; do
    [ "$path" != "$main_root" ] && is_side_checkout "$path" && found+=("$path")
  done
  [ "${#found[@]}" -gt 0 ] || return 0
  d_gh_gate || return 0
  for path in "${found[@]}"; do
    rc=0; verdict=""; branch=""
    side_checkout_finished "$path" </dev/null || rc=$?
    case "$rc" in
      0)
        d_warn "side checkout ${path##*/} is finished - its PR is merged, and it is still standing at $path."
        d_remedy "orch.sh side-checkout remove ${path##*/}" ;;
      1) ;;
      *) d_warn "side checkout $(basename "$path") could not be checked: $verdict" ;;
    esac
  done
  return 0
}

ENV_CHECKS="
h_tools  check_git check_gh check_jq check_bash
h_auth   check_origin check_gh_auth check_gh_repo check_default_branch
h_plugin check_host check_plugin_root check_orch_sh
h_repo   check_labels_doc check_labels_exist check_sub_issues check_git_exclude check_base_branch check_side_checkouts_finished
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
  phase="$(state_get phase)"
  case " $PHASES " in
    *" $phase "*) d_ok "phase: $phase" ;;
    *) d_fail "unknown phase: $phase (want one of: $PHASES)"
       d_remedy "$(flow_cmd abort)" ;;
  esac
}

check_flow_branch() {
  local branch
  branch="$(state_get branch)"
  if [ -z "$branch" ]; then d_ok "branch: not created yet"; return 0; fi
  if git rev-parse --verify --quiet "$branch" >/dev/null; then d_ok "branch: $branch"; return 0; fi
  # A done flow stays put until the next init archives it (ADR-0009), and its
  # branch being deleted after the merge is the routine end of a flow, not a
  # broken one - the same reading check_flow_issue gives its closed issue.
  if [ "$(state_get phase)" = "done" ]; then
    d_ok "branch: $branch gone - expected after merge"; return 0
  fi
  d_fail "branch $branch no longer exists - the flow has nothing left to build on."
  d_remedy "$(flow_cmd abort)"
}

# Only from the phase that pushes onwards: before implement, not having pushed
# is correct, and a warning about correct state is how people learn to skim past
# the word.
check_flow_upstream() {
  local phase branch
  phase="$(state_get phase)"
  case "$phase" in implement|review|done) ;; *) return 0 ;; esac
  branch="$(state_get branch)"
  [ -n "$branch" ] || return 0
  # origin/<branch> specifically, not just any upstream: branch create forks off
  # origin/<default>, which leaves that as the upstream until the first push. An
  # ok there would report a branch nobody can see as pushed.
  local upstream=""
  upstream="$(git rev-parse --abbrev-ref --verify --quiet "$branch@{upstream}" 2>/dev/null)" || upstream=""
  if [ "$upstream" = "origin/$branch" ]; then d_ok "upstream: $upstream"; return 0; fi
  # After the merge the remote branch is routinely deleted; a push remedy here
  # would recreate a branch somebody removed on purpose.
  if [ "$phase" = "done" ]; then d_ok "upstream: none - expected after merge"; return 0; fi
  d_warn "branch $branch is not on origin yet."
  d_remedy "git push -u origin $branch"
}

# Unconditional on how the issue arrived - adopted at init or published by
# orch-to-spec, state.json carries no field distinguishing the two, and none is
# needed here: both are just "the flow's spec issue" once a flow is running
# against one. The ready-for-agent label is deliberately not re-checked; it is
# a one-time gate at adoption, not an ongoing flow invariant (docs/adr/0005).
check_flow_issue() {
  # issue_labels is the read's throwaway half: only the state is checked here.
  # shellcheck disable=SC2034
  local issue issue_state="" issue_labels gh_line="" phase
  issue="$(state_get issue)"
  if [ -z "$issue" ]; then d_ok "issue: not recorded yet"; return 0; fi
  d_gh_gate || return 0
  # Only the state line is wanted, yet not from adapter_issue_state: that one
  # answers PULL for a pull request's number, an answer doctor must not accept
  # as the flow's issue state - this case knows OPEN and CLOSED only.
  issue_state_labels_read "$issue" issue_state issue_labels gh_line || issue_state=""
  phase="$(state_get phase)"
  case "$issue_state" in
    OPEN)   d_ok "issue #$issue open" ;;
    CLOSED)
      # pr open always writes `Closes #<issue>`, so a done flow's issue being
      # closed is the expected result of merging, not a broken flow.
      if [ "$phase" = "done" ]; then
        d_ok "issue #$issue closed"
      else
        d_fail "issue #$issue is closed."; d_remedy "gh issue reopen $issue"
      fi
      ;;
    *)      d_fail "issue #$issue could not be read from GitHub: ${gh_line:-gh gave no reason}"
            d_remedy "gh issue view $issue" ;;
  esac
}

check_flow_pr() {
  local pr out pr_state err="" gh_line
  pr="$(state_get pr)"
  if [ -z "$pr" ]; then d_ok "PR: not opened yet"; return 0; fi
  d_gh_gate || return 0
  capture out err adapter_pr_state_draft "$pr" || out=""
  pr_state="${out%%$'\n'*}"
  gh_line="${err%%$'\n'*}"
  case "$pr_state" in
    OPEN)   d_ok "PR #$pr open" ;;
    MERGED) d_ok "PR #$pr merged" ;;
    CLOSED) d_fail "PR #$pr is closed."; d_remedy "gh pr reopen $pr" ;;
    *)      d_fail "PR #$pr could not be read from GitHub: ${gh_line:-gh gave no reason}"
            d_remedy "gh pr view $pr" ;;
  esac
}

# Proactive surface for the same classification `redo review` refuses on -
# a human sees "this loop looks interrupted" before wondering why redo
# won't run. Phase-gated like check_flow_upstream: outside review, there is
# no loop to classify and nothing to say about one.
check_flow_review_terminal() {
  local phase i b terminal word detail
  phase="$(state_get phase)"
  [ "$phase" = review ] || return 0
  i="$(state_get iteration)"
  b="$(review_budget)"
  terminal="$(review_terminal_state)" || true
  lines_split "$terminal" word detail
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
      d_warn "review loop hasn't reached its budget yet (iteration $i of budget $b) - $(flow_cmd next) will resume it; redo refuses until it reaches a terminal state." ;;
    interrupted)
      d_warn "review loop's last iteration ($i of budget $b) has no recorded terminal state - the session looks interrupted, not stopped. $(flow_cmd next) will resume it; redo refuses until it reaches a terminal state." ;;
    # A FAIL, not a warn: the record is there but unreadable, and
    # /orchestrator:next will not rewrite it - only a human editing it will.
    malformed)
      d_fail "review loop's last iteration ($i) has a malformed terminal state - $detail"
      d_remedy "rewrite the first line of $(cmd_review path "$i") in the expected shape above" ;;
  esac
}

# `review begin` dies rather than start an iteration past budget, so this is
# meant to be unreachable - an iteration count past it is not a loop still
# running, it is state.json in a shape nothing produced on a healthy run.
check_flow_review_budget() {
  local phase i b
  phase="$(state_get phase)"
  [ "$phase" = review ] || return 0
  i="$(state_get iteration)"
  b="$(review_budget)"
  if [ "$i" -gt "$b" ]; then
    d_fail "review loop iteration ($i) is past its budget ($b) - the loop's stop enforcement did not hold."
    d_remedy "$(flow_cmd abort)"
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
  local phase pr res verdict detail reason
  phase="$(state_get phase)"
  [ "$phase" = review ] || return 0
  pr="$(state_get pr)"
  [ -n "$pr" ] || return 0
  d_gh_gate || return 0
  res="$(ci_probe "$pr" required)"
  lines_split "$res" verdict detail
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
    # command either. Its detail is gh's reason, carried in the warn rather
    # than printed again below it.
    *) reason="$(trim "$detail")"
       d_warn "CI: could not be read from GitHub for PR #$pr: ${reason:-gh gave no reason}"
       return 0 ;;
  esac
  [ -z "$detail" ] || note "$detail"
}

# `review ready` marks the PR ready and records phase: done as one operation
# precisely so neither half can happen without the other (see `review ready`) -
# so isDraft and phase disagreeing on GitHub's own PR is evidence that
# operation only half landed, not a state a healthy flow reaches on its own.
check_flow_review_draft() {
  local phase pr out err="" gh_line pr_state is_draft rest
  phase="$(state_get phase)"
  case "$phase" in review|done) ;; *) return 0 ;; esac
  pr="$(state_get pr)"
  [ -n "$pr" ] || return 0
  d_gh_gate || return 0
  capture out err adapter_pr_state_draft "$pr" || out=""
  lines_split "$out" pr_state is_draft rest
  if [ -z "$pr_state" ]; then
    gh_line="${err%%$'\n'*}"
    d_warn "PR #$pr draft state could not be read from GitHub: ${gh_line:-gh gave no reason}"
    return 0
  fi
  # A merged or closed PR cannot go back to draft, so only an open PR's flag
  # is a live signal - nothing left there to disagree with the flow's phase.
  [ "$pr_state" = OPEN ] || return 0
  if [ "$phase" = "done" ] && [ "$is_draft" = true ]; then
    d_fail "PR #$pr is still a draft but the flow phase is done - review ready did not take."
    d_remedy "gh pr ready $pr"
  elif [ "$phase" = review ] && [ "$is_draft" = false ]; then
    d_fail "PR #$pr was marked ready on GitHub but the flow phase is still review - state.json fell out of sync."
    d_remedy "gh pr view $pr"
  else
    d_ok "PR #$pr draft state matches phase ($phase)"
  fi
}

# A ticket worktree under this checkout is a run's leftover once its phase is
# not running (ADR-0036): the next implement phase stops on it, and archive
# refuses to move it. Silent when there is none - ticket-worktree list's own
# scope, so another checkout's in-flight tickets never fail this flow.
check_flow_ticket_worktrees() {
  local n path
  while read -r n path; do
    [ -n "$n" ] || continue
    d_fail "ticket worktree $path is left over - a ticket run did not finish."
    d_remedy "orch.sh ticket-worktree remove $n"
  done <<<"$(cmd_ticket_worktree_list)"
}

# Every phase commits and pushes its own work before it ends, so a change
# outside the planning allowlist at a phase boundary is a bug in the phase that
# left it - caught here, at the top of /orchestrator:next, while that phase's
# context still exists. Pure reuse of init's check, so the two never disagree
# about what counts. Silent on a clean tree. dirty_outside_allowlist dies when
# git status cannot run; in its subshell that ends only the subshell, and its
# message becomes this check's FAIL rather than the end of the report.
check_flow_worktree_clean() {
  local dirty err
  if ! capture dirty err dirty_outside_allowlist; then
    d_fail "$(sed -n 's/^orch: //p' <<<"$err" | sed -n 1p)"
    return 0
  fi
  [ -n "$dirty" ] || return 0
  d_fail "the working tree has changes outside the planning allowlist: $(d_join "$dirty")"
  d_remedy "git status"
}

# Pure reuse: what makes a handoff valid lives in handoff_required and
# section_body, and a second statement of it here is how the two answers drift.
# Which handoffs are due is mechanical - phase names what runs *next*, so every
# earlier phase has already written one.
check_flow_handoffs() {
  local phase files f path problems line
  phase="$(state_get phase)"
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
      d_remedy "$(flow_cmd redo)"
      continue
    fi
    problems="$(handoff_report "$path" | grep -v '^ok ' || true)"
    if [ -z "$problems" ]; then d_ok "handoff $f complete"; continue; fi
    while IFS= read -r line; do d_fail "handoff $f: ${line#FAIL }"; done <<<"$problems"
    d_remedy "$(flow_cmd redo)"
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
    # Outside the registry: each reads git alone and prints nothing when clean,
    # so a flow with no ticket worktree and a clean working tree reports
    # exactly what it did before.
    check_flow_ticket_worktrees
    check_flow_worktree_clean
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
  d_remedy "$(flow_cmd abort)"
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
    --env)  scope="env" ;;
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
