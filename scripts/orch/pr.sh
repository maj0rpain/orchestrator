# shellcheck shell=bash
# pr.sh - orch.sh's pr command: open, publish, release, comment and the
# stateless PR reads and writes, draft and ready among them.
# Its tests: scripts/test/orch/pr.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# Pushing a branch and opening a PR against it has exactly one right answer -
# push, then prefix the body with the issue line - Closes into the default
# branch, so GitHub links the PR as a closer (no agent-chosen wording can leave
# the issue open again), Refs into any other base - then create the PR - so
# pr open (a flow's own, draft, recorded into state) and pr publish (a quick
# implementation's, not a draft, recording nothing) share it rather
# than each hand-rolling the push/issue-line/gh-pr-create idiom.
# Once the PR exists, it records the number on the branch as
# branch.<b>.orchestrator-pr (#1200), so a busy check can tell, locally and
# without GitHub, that the branch's work is handed off. A failed write only
# warns: the PR is open either way, and the branch merely stays busy.
# Any labels after the draft flag reach gh pr create through the adapter
# (#1299), so the PR carries them from creation; pr_labels_check reads them
# back once the caller has recorded the PR.
open_pr() {
  local branch="$1" base="$2" issue="$3" title="$4" body_file="$5" draft="$6" tmp pr err why keyword=Closes create_opts=() label
  shift 6
  [ "$draft" != true ] || create_opts=(--draft)
  for label; do create_opts+=(--label "$label"); done
  # A bare push would rely on set -e, which bash turns off inside the $(...)
  # every caller runs open_pr in (#1300), so the status is checked here.
  git_push why -q -u origin "$branch" \
    || die "could not push branch $branch to origin - no PR was opened: $why"
  # GitHub only acts on a closing keyword when the PR merges into the default
  # branch, so a PR into any other base branch refers to its issue instead of
  # claiming to close it - the release PR is what closes it.
  [ "$base" = "$(default_branch)" ] || keyword=Refs
  # open_pr runs in $(...), where errexit is off (#1327), so the temp body's
  # creation and write are checked here: an unreadable body file would
  # otherwise open the PR with only its closing line.
  tmp="$(mktemp)" || die "could not create a temp file for the PR body - no PR was opened"
  { printf '%s #%s\n\n' "$keyword" "$issue" && cat "$body_file"; } >"$tmp" || {
    rm -f "$tmp"
    die "could not write the PR body from $body_file - no PR was opened"
  }
  if ! capture pr err adapter_pr_create "$base" "$branch" "$title" "$tmp" ${create_opts[@]+"${create_opts[@]}"}; then
    rm -f "$tmp"
    gh_die "open the PR for branch $branch (issue #$issue)" "$err"
  fi
  rm -f "$tmp"
  git config "branch.$branch.orchestrator-pr" "$pr" \
    || warn "could not record PR #$pr on branch $branch - it counts as busy until you switch off it"
  printf '%s\n' "$pr"
}

# pr_label_value <usage> <option-names> --label [value...]: dies, naming
# --label, unless it is followed by a label name - a value neither empty nor
# one of <option-names>, a space-separated list. Any other name is taken as
# given: gh refuses one the repo does not have, before it opens the PR.
pr_label_value() {
  local name
  [ -n "${4:-}" ] || die "--label needs a label name - $1"
  for name in $2; do
    [ "$4" != "$name" ] || die "--label needs a label name - $1"
  done
}

# pr_labels_check <pr> <label>...: with labels named, reads PR <pr>'s labels
# back and dies, naming the PR and each label it lacks - or, where the read
# fails, relaying gh's reason. gh adds the labels in a separate mutation after
# the create (#1299), so a create that succeeded does not prove they landed.
# Called only once the PR is recorded, so the record survives either death.
pr_labels_check() {
  local pr="$1" have err label missing="" count=0
  shift
  [ $# -gt 0 ] || return 0
  capture have err adapter_pr_labels "$pr" \
    || gh_die "read the labels of PR #$pr, open and recorded on its branch" "$err"
  for label; do
    list_has "$have" "$label" && continue
    missing="${missing:+$missing, }'$label'"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || return 0
  [ "$count" -gt 1 ] || die "PR #$pr is open but lacks the label $missing - add it by hand"
  die "PR #$pr is open but lacks the labels $missing - add them by hand"
}

# pr_body_check <body-file> <heading>...: dies, naming in one message every
# piece of the PR-writing standard (#1387) the body lacks or gets wrong, unless
# it has an exact `## <heading>` line for each <heading> - and, when Merge
# Danger is one of them, exactly one `**Door:**` line reading one-way or
# two-way and a `**Blast Radius:**` line with a value, both under
# ## Merge Danger before the next H2. Structure only, never wording or order
# (ADR-0027): lines inside fenced code blocks are skipped, so a Summary visual
# can neither satisfy nor break it. Run before any push or create, so a
# refusal leaves nothing behind for the caller to undo.
pr_body_check() {
  local body_file="$1" required problems
  shift
  required="$(IFS='|'; printf '%s' "$*")"
  problems="$(awk -v required="$required" '
    function run(s, c,   n) { n = 0; while (substr(s, n + 1, 1) == c) n++; return n }
    function add(p) { out = out (out == "" ? "" : "; ") p }
    function value(s) { sub(/^[ \t]+/, "", s); return s }
    {
      line = $0; sub(/[ \t\r]+$/, "", line)
      s = line; sub(/^ ? ? ?/, "", s); c = substr(s, 1, 1)
      if (fence != "") {
        if (c == fence && run(s, c) >= fence_len && run(s, c) == length(s)) fence = ""
        next
      }
      if ((c == "`" || c == "~") && run(s, c) >= 3) { fence = c; fence_len = run(s, c); next }
      if (line ~ /^## /) { section = substr(line, 4); seen[section] = 1; next }
      if (section != "Merge Danger") next
      if (index(line, "**Door:**") == 1) {
        doors++; v = value(substr(line, 10))
        if (v == "") bad_doors[++bad] = "an empty **Door:** value"
        else if (v != "one-way" && v != "two-way") bad_doors[++bad] = "**Door:** value \047" v "\047 is not one-way or two-way"
      } else if (index(line, "**Blast Radius:**") == 1) {
        blasts++
        if (value(substr(line, 18)) == "") empty_blast = 1
      }
    }
    END {
      n = split(required, req, "|")
      for (i = 1; i <= n; i++) {
        if (!(req[i] in seen)) add("no ## " req[i] " heading")
        if (req[i] != "Merge Danger") continue
        if (!doors) add("no **Door:** line under ## Merge Danger")
        for (j = 1; j <= bad; j++) add(bad_doors[j])
        if (doors > 1) add("a second **Door:** line under ## Merge Danger")
        if (!blasts) add("no **Blast Radius:** line under ## Merge Danger")
        else if (empty_blast) add("an empty **Blast Radius:** value")
      }
      print out
    }' "$body_file" 2>/dev/null)" \
    || die "could not read the PR body from $body_file - no PR was opened"
  [ -z "$problems" ] ||
    die "the PR body does not meet the PR-writing standard - no PR was opened: $problems"
}

cmd_pr_open() {
  require_state
  local usage="usage: orch.sh pr open <title> <body-file> [--label <name>]..." labels=()
  [ $# -ge 2 ] || die "$usage"
  local title="$1" body_file="$2" issue branch base pr
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) pr_label_value "$usage" --label "$@"; labels+=("$2"); shift 2 ;;
      *) die "unknown option: $1 - $usage" ;;
    esac
  done
  [ -f "$body_file" ] || die "body file not found: $body_file"
  pr_body_check "$body_file" Summary Evidence "Merge Danger"
  require_issue issue
  require_branch branch
  base="$(flow_base)" || die "cannot read the flow's base branch from $STATE"
  # Draft is the honest signal: the review loop has not run yet, so marking it
  # ready is the loop's success condition rather than a comment nobody reads.
  pr="$(open_pr "$branch" "$base" "$issue" "$title" "$body_file" true ${labels[@]+"${labels[@]}"})"
  state_write pr "$pr"
  pr_labels_check "$pr" ${labels[@]+"${labels[@]}"}
  note "$pr"
}

# The PR-opening boundary a quick implementation calls instead of hardcoding
# `gh pr create` in skill prose - the same reason `issue publish` owns its own
# `gh issue create` rather than leaving it to skill prose. Stateless like
# branch off and issue publish: the caller has no flow to record into, and no
# draft to promote later, since a quick implementation's review pass already
# ran before this is called - unless that pass met a spec question (#967):
# --draft then opens it as a draft, held until a human rules on the question.
# --label, repeatable, opens it carrying each label named (#1299).
cmd_pr_publish() {
  local usage="usage: orch.sh pr publish <issue> <title> <body-file> [--draft] [--label <name>]..." draft=false labels=()
  [ $# -ge 3 ] || die "$usage"
  local issue="$1" title="$2" body_file="$3" branch base pr
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --draft) draft=true; shift ;;
      --label) pr_label_value "$usage" "--draft --label" "$@"; labels+=("$2"); shift 2 ;;
      *) die "unknown option: $1 - $usage" ;;
    esac
  done
  [ -f "$body_file" ] || die "body file not found: $body_file"
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  pr_body_check "$body_file" Summary Evidence "Merge Danger"
  current_branch_or_die
  base="$(recorded_base "$branch")"
  pr="$(open_pr "$branch" "$base" "$issue" "$title" "$body_file" "$draft" ${labels[@]+"${labels[@]}"})"
  pr_labels_check "$pr" ${labels[@]+"${labels[@]}"}
  note "$pr"
}

# The release PR: carries the base branch in effect back into the default
# branch. Stateless like pr publish, and pushes nothing - the base branch is
# already on origin.
cmd_pr_release() {
  local usage="usage: orch.sh pr release [--force] <title> <body-file>" force=false
  if [ "${1:-}" = --force ]; then force=true; shift; fi
  [ $# -eq 2 ] || die "$usage"
  local title="$1" body_file="$2" base default
  [ -n "$title" ] || die "the title is empty"
  [ -f "$body_file" ] || die "body file not found: $body_file"
  # Only Summary: a release PR carries PRs already reviewed (#1387).
  pr_body_check "$body_file" Summary
  base="$(base_branch)"
  default="$(default_branch)"
  [ "$base" != "$default" ] ||
    die "the base branch is the default branch ($default) - there is nothing to release; set another with base set"
  local open
  gh_or_die --out open "list the open PRs from $base into $default" \
    adapter_prs_open "$base" "$default"
  [ -z "$open" ] || die "a release PR from $base into $default is already open: #${open%%$'\n'*}"
  # Read from the merged PRs' bodies rather than GitHub's closing-issue links:
  # GitHub only links closing keywords on PRs into the default branch, and a
  # Refs line never links at all. Refs, Closes, Fixes and Resolves count, in
  # any case and anywhere in the body - not every closing form GitHub knows,
  # so prose such as "a quick fix #12" is never mistaken for a reference.
  local bodies refs n state issues="" tmp pr err
  gh_or_die --out bodies "list the PRs merged into $base" \
    adapter_prs_merged_bodies "$base"
  refs="$(printf '%s\n' "$bodies" |
    grep -ioE '(^|[^[:alnum:]_])(refs|closes|fixes|resolves):?[[:space:]]+#[0-9]+' |
    grep -oE '[0-9]+$' | sort -nu)" || true
  # gh issue view answers for a PR number too, so a reference to a PR reads
  # as PULL and is dropped - only still-open issues get a Closes line.
  for n in $refs; do
    gh_or_die --out state "read the state of issue #$n" adapter_issue_state "$n"
    [ "$state" != OPEN ] || issues="$issues $n"
  done
  [ -n "$issues" ] || [ "$force" = true ] ||
    die "nothing to close: no PR merged into $base refers to a still-open issue - pass --force to release anyway"
  tmp="$(mktemp)"
  {
    for n in $issues; do printf 'Closes #%s\n' "$n"; done
    [ -z "$issues" ] || printf '\n'
    cat "$body_file"
  } >"$tmp"
  # Not a draft: nothing after this would ever mark it ready.
  if ! capture pr err adapter_pr_create "$default" "$base" "$title" "$tmp"; then
    rm -f "$tmp"
    gh_die "open the release PR from $base into $default" "$err"
  fi
  rm -f "$tmp"
  note "$pr"
}

# A stateless post on the current branch's open PR, the PR counterpart of
# issue comment - for a standalone review pass, which records its declines
# there. Three outcomes: 0 posted (printing the PR number), 1 only when the
# branch has no open PR, and 2 for everything else - GitHub unreadable, a
# failed post, a usage error, a missing file, a detached HEAD. The exit-2
# cases go through die2, since die exits 1 and a caller reading 1 would take
# a failure for "no PR". The GitHub-unreadable and usage-error rules are
# shared with ticket exists: a GitHub that cannot be read, or a usage error,
# exits 2, never 1.
cmd_pr_comment() {
  [ $# -eq 1 ] || die2 "usage: orch.sh pr comment <file>"
  local file="$1" pr
  [ -f "$file" ] || die2 "body file not found: $file"
  pr="$(current_open_pr)" || return $?
  gh_or_die --exit 2 "comment on PR #$pr" adapter_pr_comment "$pr" "$file"
  printf '%s\n' "$pr"
}

# pr draft and pr ready (#967): the current branch's open PR turned into a
# draft, or marked ready, for a standalone review pass whose spec questions
# hold the PR or no longer do. Stateless, with pr comment's exit codes: 0 done,
# a PR already in that state included, saying so - so the caller reads no draft
# state; 1 only when the branch has no open PR; 2 for everything else, a
# refusal included. A branch an active flow holds is refused: its PR changes
# state only through the review loop (review ready and its Ready conditions).
cmd_pr_draft() {
  [ $# -eq 0 ] || die2 "usage: orch.sh pr draft"
  local out pr is_draft
  out="$(open_pr_draft_flag)" || exit $?
  lines_split "$out" pr is_draft
  if [ "$is_draft" = true ]; then
    note "PR #$pr is already a draft"
    return 0
  fi
  gh_or_die --exit 2 "turn PR #$pr into a draft" adapter_pr_draft "$pr"
  note "PR #$pr is now a draft"
}

cmd_pr_ready() {
  [ $# -eq 0 ] || die2 "usage: orch.sh pr ready"
  local out pr is_draft
  out="$(open_pr_draft_flag)" || exit $?
  lines_split "$out" pr is_draft
  if [ "$is_draft" != true ]; then
    note "PR #$pr is already ready"
    return 0
  fi
  gh_or_die --exit 2 "mark PR #$pr ready" adapter_pr_ready "$pr"
  note "PR #$pr is now ready"
}

# pr draft's and pr ready's shared front: refuses a branch an active flow
# holds, then prints the current branch's open PR number and its draft flag
# (true or false), one per line. Returns 1, printing nothing, when the branch
# has no open PR, as current_open_pr does.
open_pr_draft_flag() {
  local branch phase pr _pr_state is_draft err rc=0
  current_branch_or_die die2
  phase="$(flow_holding_phase "$branch")" || rc=$?
  case "$rc" in
    0) die2 "the active flow holds $branch at phase $phase - its PR changes state only through the review loop" ;;
    1) ;;
    *) die2 "state.json cannot be read - run orch.sh doctor --flow" ;;
  esac
  pr="$(current_open_pr)" || return $?
  pr_state_draft_read "$pr" _pr_state is_draft err \
    || gh_die --exit 2 "read PR #$pr" "$err"
  printf '%s\n%s\n' "$pr" "$is_draft"
}

# The current branch's open PR number, for pr comment, pr comments, pr fetch
# and pr update.
# Returns 1, printing nothing, when the branch has no open PR; every other
# failure - a detached HEAD, a GitHub that cannot be read - goes through die2,
# so a caller in a subshell can tell "no PR" apart from an error and map each
# to its own exit code.
current_open_pr() {
  local branch open
  current_branch_or_die die2
  gh_or_die --exit 2 --out open "list the open PRs from $branch" \
    adapter_prs_open "$branch"
  [ -n "$open" ] || return 1
  printf '%s\n' "${open%%$'\n'*}"
}

# The PR pr fetch and pr update work on. Unlike pr comment, no open PR is an
# ordinary failure here, since both run where a PR is known to exist; a caller
# maps every failure to exit 1.
required_open_pr() {
  current_open_pr \
    || die "no open PR for branch $(checkout_branch)"
}

# The PR counterpart of issue fetch.
cmd_pr_fetch() {
  [ $# -eq 1 ] || die "usage: orch.sh pr fetch <file>"
  local file="$1" pr
  pr="$(required_open_pr)" || exit 1
  gh_or_die --file "$file" "read the body of PR #$pr" adapter_pr_body "$pr"
}

# The PR counterpart of issue comments (issue #418), so a standalone review
# pass reads earlier passes' declines. Exits as pr comment does: 1, writing
# nothing, only when the branch has no open PR, and 2 for everything else -
# GitHub unreadable, a usage error, a detached HEAD - with the file untouched.
cmd_pr_comments() {
  [ $# -eq 1 ] || die2 "usage: orch.sh pr comments <file>"
  local file="$1" pr
  pr="$(current_open_pr)" || return $?
  gh_or_die --exit 2 --file "$file" "read the comments of PR #$pr" \
    adapter_pr_comments "$pr"
}

# The PR counterpart of issue update, with one guard issue update has no need
# for: the body's first line is the Closes/Refs line open_pr wrote, and a
# correction must never drop or change it, so a file that does not open with
# exactly that line is refused and the body left as it was.
cmd_pr_update() {
  [ $# -eq 1 ] || die "usage: orch.sh pr update <file>"
  local file="$1" pr current line
  [ -f "$file" ] || die "body file not found: $file"
  pr="$(required_open_pr)" || exit 1
  gh_or_die --out current "read the body of PR #$pr" adapter_pr_body "$pr"
  line="$(printf '%s\n' "$current" | sed -n '1{s/\r$//;p;}')"
  grep -qE '^(Closes|Refs) #[0-9]+$' <<<"$line" \
    || die "PR #$pr's body does not open with a Closes/Refs #<issue> line, so there is no issue line to keep - refusing to replace it"
  [ "$(sed -n '1{s/\r$//;p;}' "$file")" = "$line" ] \
    || die "$file must open with PR #$pr's issue line, '$line' - refusing to replace the body"
  gh_or_die "replace the body of PR #$pr" adapter_pr_body_edit "$pr" "$file"
}

cmd_pr() {
  local op="${1:-}"
  shift || true
  case "$op" in
    open)    cmd_pr_open "$@" ;;
    publish) cmd_pr_publish "$@" ;;
    release) cmd_pr_release "$@" ;;
    comment) cmd_pr_comment "$@" ;;
    comments) cmd_pr_comments "$@" ;;
    fetch)   cmd_pr_fetch "$@" ;;
    update)  cmd_pr_update "$@" ;;
    draft)   cmd_pr_draft "$@" ;;
    ready)   cmd_pr_ready "$@" ;;
    *) die "unknown pr op: ${op:-<none>} (want open|publish|release|comment|comments|fetch|update|draft|ready)" ;;
  esac
}
