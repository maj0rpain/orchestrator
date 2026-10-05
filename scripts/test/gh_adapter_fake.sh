# The in-memory half of the ORCH_GH_ADAPTER seam.
#
# Sourced into orch.sh's own process via ORCH_GH_ADAPTER, this redefines the
# adapter functions orch.sh calls instead of shelling out to `gh` - so a test
# exercises orch.sh's decision logic without spawning a subprocess for every
# GitHub call. Parameterized by the same GH_STUB_* vocabulary orch_test.sh's
# subprocess fake (`stub_gh`) already answers to, so a test switches between
# the two fakes without learning a second vocabulary, and an assertion written
# against one reads the other's output too.
#
# Label creation was the first primitive covered - the narrowest slice that
# proved the seam works end to end (issue #91, first of the #78 breakdown).
# The issue-resource primitives below (view/edit/comment/create/close, issue
# #92) extend it the same way: each addition keeps mirroring whatever
# GH_STUB_* variable already drives that call's subprocess behaviour in
# stub_gh, rather than inventing a parallel vocabulary.
#
# adapter_label_create - mirrors stub_gh's `label create` branch:
#   GH_STUB_MODE=labelfail   fails the call, like a `gh` that cannot create it
#   GH_STUB_LABEL_FAIL=<name> fails the call for that one label alone, so a
#                             test can refuse the category label and still
#                             see the rest of the filing go through
#   GH_STUB_FILED            when set, appended with "label create <args...>",
#                             the same line shape stub_gh writes, so an
#                             assertion against GH_STUB_FILED does not care
#                             which fake produced it
adapter_label_create() {
  if [ "${GH_STUB_MODE:-ok}" = labelfail ]; then return 1; fi
  if [ -n "${GH_STUB_LABEL_FAIL:-}" ] && [ "$1" = "$GH_STUB_LABEL_FAIL" ]; then return 1; fi
  if [ -n "${GH_STUB_FILED:-}" ]; then printf 'label create %s\n' "$*" >>"$GH_STUB_FILED"; fi
  return 0
}

# Shared by every issue-write primitive below - mirrors stub_gh's own
# record_flags: title/label/body-file/comment flags are appended to
# GH_STUB_FILED with the body-file's contents inlined, everything else as a
# bare flag=value line, so an assertion reads either fake's GH_STUB_FILED the
# same way.
fake_record_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)     printf 'title=%s\n' "$2" >>"$GH_STUB_FILED"; shift ;;
      --label)     printf 'label=%s\n' "$2" >>"$GH_STUB_FILED"; shift ;;
      --base)      printf 'base=%s\n' "$2" >>"$GH_STUB_FILED"; shift ;;
      --head)      printf 'head=%s\n' "$2" >>"$GH_STUB_FILED"; shift ;;
      --body-file) { printf 'body:\n'; cat "$2"; } >>"$GH_STUB_FILED"; shift ;;
      --comment)   { printf 'comment:\n%s\n' "$2"; } >>"$GH_STUB_FILED"; shift ;;
      --add-label)    printf 'add-label=%s\n' "$2" >>"$GH_STUB_FILED"; shift ;;
      --remove-label) printf 'remove-label=%s\n' "$2" >>"$GH_STUB_FILED"; shift ;;
      --reason)       printf 'reason=%s\n' "$2" >>"$GH_STUB_FILED"; shift ;;
      *)           printf 'flag=%s\n' "$1" >>"$GH_STUB_FILED" ;;
    esac
    shift
  done
}

# adapter_issue_view - mirrors stub_gh's `issue view` branch: logs "issue view
# <args...>" to GH_STUB_FILED when set, fails on GH_STUB_VIEW_EXIT, answers
# GH_STUB_ISSUE_STATE/GH_STUB_ISSUE_LABELS when asked for those fields, and
# GH_STUB_BODY (default "Body of the issue.") otherwise - the same three
# answers stub_gh gives, so cmd_spec fetch reads either fake identically.
# GH_STUB_CLOSED_ISSUES, a space-separated list of issue numbers, answers
# CLOSED for those issues' state alone, so pr release can see a mix of open
# and closed issues in one run (issue #139). pr release asks for state,url;
# a number in GH_STUB_PR_NUMBERS answers PULL there, as its --jq turns a PR's
# /pull/ url into. Asked for comments with GH_STUB_COMMENTS_JSON set - raw
# gh-shaped JSON, {"comments":[{"author":{"login":..},"createdAt":..,"body":..}]}
# - it applies the request's own --jq with real jq, as adapter_pr_list does,
# so the formatting under test is orch.sh's; unset, it answers as before.
adapter_issue_view() {
  if [ -n "${GH_STUB_FILED:-}" ]; then printf 'issue view %s\n' "$*" >>"$GH_STUB_FILED"; fi
  if [ "${GH_STUB_VIEW_EXIT:-0}" != 0 ]; then
    echo "gh stub: issue view refused" >&2
    return "$GH_STUB_VIEW_EXIT"
  fi
  local a prev="" q=""
  for a in "$@"; do
    if [ "$prev" = --jq ]; then q="$a"; fi
    prev="$a"
  done
  if [ -n "${GH_STUB_FINDINGS:-}" ] && [ -d "$GH_STUB_FINDINGS/$1" ]; then
    fake_finding_json "$1" | jq -r "${q:-.}"
    return
  fi
  for a in "$@"; do
    case "$a" in
      comments)
        if [ -n "${GH_STUB_COMMENTS_JSON:-}" ]; then
          printf '%s' "$GH_STUB_COMMENTS_JSON" | jq -r "${q:-.}"
          return
        fi ;;
      title,labels) fake_readback; return 0 ;;
      state|state,url)
        case " ${GH_STUB_PR_NUMBERS:-} " in
          *" $1 "*) [ "$a" = state,url ] && { printf 'PULL\n'; return 0; } ;;
        esac
        case " ${GH_STUB_CLOSED_ISSUES:-} " in
          *" $1 "*) printf 'CLOSED\n' ;;
          *)        printf '%s\n' "${GH_STUB_ISSUE_STATE:-OPEN}" ;;
        esac
        return 0 ;;
      labels) printf '%s\n' "${GH_STUB_ISSUE_LABELS-ready-for-agent}"; return 0 ;;
    esac
  done
  printf '%s\n' "${GH_STUB_BODY-Body of the issue.}"
  return 0
}

# GH_STUB_FINDINGS names a directory of issues, one subdirectory per number
# holding its body, its labels (one per line) and, optionally, its state
# (default OPEN) - so one run can mix issues with different bodies and labels,
# as finding triage's scan needs. An issue there answers adapter_issue_view
# as gh-shaped JSON - number, state, labels, body - through the request's own
# --jq, and adapter_issue_list lists them.
fake_finding_json() {
  local d="$GH_STUB_FINDINGS/$1"
  jq -n --argjson n "$1" \
    --arg state "$(cat "$d/state" 2>/dev/null || echo OPEN)" \
    --arg labels "$(cat "$d/labels" 2>/dev/null)" \
    --rawfile body "$d/body" \
    '{number: $n, state: $state, body: $body,
      labels: [$labels | split("\n")[] | select(. != "") | {name: .}]}'
}

# adapter_issue_list - logs "issue list <args...>" to GH_STUB_FILED when set,
# fails on GH_STUB_ISSUE_LIST_EXIT, and answers a JSON array of the issues in
# GH_STUB_FINDINGS that carry every --label asked for, in the --state asked
# for (default open), through the caller's own --jq - the filter gh applies
# server side.
adapter_issue_list() {
  local state=open q="" labels=() d n json="[]" l keep
  if [ -n "${GH_STUB_FILED:-}" ]; then printf 'issue list %s\n' "$*" >>"$GH_STUB_FILED"; fi
  if [ "${GH_STUB_ISSUE_LIST_EXIT:-0}" != 0 ]; then
    echo "gh stub: issue list refused" >&2
    return "$GH_STUB_ISSUE_LIST_EXIT"
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state="$2"; shift ;;
      --label) labels+=("$2"); shift ;;
      --jq)    q="$2"; shift ;;
    esac
    shift
  done
  for d in "${GH_STUB_FINDINGS:-/nonexistent}"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    keep=1
    for l in "${labels[@]}"; do grep -qxF -- "$l" "$d/labels" 2>/dev/null || keep=0; done
    case "$state" in
      all) ;;
      *) [ "$(cat "$d/state" 2>/dev/null || echo OPEN)" = "$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')" ] || keep=0 ;;
    esac
    [ "$keep" = 1 ] || continue
    json="$(jq --argjson x "$(fake_finding_json "$n")" '. + [$x]' <<<"$json")"
  done
  if [ -n "$q" ]; then printf '%s' "$json" | jq -r "$q"; else printf '%s\n' "$json"; fi
}

# adapter_issue_edit / adapter_issue_comment - mirror stub_gh's `issue
# edit`/`issue comment` branch's logging shape: "issue <op> <n>" plus the
# flags (fake_record_flags) to GH_STUB_FILED when set. Failing on demand with
# GH_STUB_EDIT_EXIT/GH_STUB_COMMENT_EXIT respectively is this fake's own job now
# - once cmd_spec's update/comment fully moved onto this adapter (#94), no live
# test left a caller for stub_gh's own copy of that check, so it was retired.
fake_issue_write() {
  local op="$1" n st
  shift
  n="$1"
  shift
  if [ -n "${GH_STUB_FILED:-}" ]; then
    printf 'issue %s %s\n' "$op" "$n" >>"$GH_STUB_FILED"
    fake_record_flags "$@"
  fi
  if [ "$op" = edit ]; then st="${GH_STUB_EDIT_EXIT:-0}"; else st="${GH_STUB_COMMENT_EXIT:-0}"; fi
  if [ "$st" != 0 ]; then
    echo "gh stub: issue $op refused" >&2
    return "$st"
  fi
  if [ "$op" = edit ]; then fake_finding_relabel "$n" "$@"; fi
  return 0
}

# An edit of an issue in the GH_STUB_FINDINGS store applies its --add-label
# and --remove-label flags to the labels it holds, as gh would, so a test reads
# what an edit left on the issue back from the issue itself.
fake_finding_relabel() {
  local f="${GH_STUB_FINDINGS:-/nonexistent}/$1/labels"
  [ -f "$f" ] || return 0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --add-label)    grep -qxF -- "$2" "$f" || printf '%s\n' "$2" >>"$f"; shift ;;
      --remove-label) { grep -vxF -- "$2" "$f" || true; } >"$f.tmp"; mv "$f.tmp" "$f"; shift ;;
    esac
    shift
  done
}
adapter_issue_edit()    { fake_issue_write edit "$@"; }
adapter_issue_comment() { fake_issue_write comment "$@"; }

# issue publish's readback: the title on the first line, then one line per
# label - by default exactly what the last adapter_issue_create in this
# process was given, kept in GH_FAKE_DIR because creation runs in a command
# substitution whose variables never reach the parent. GH_STUB_READBACK_MISS
# answers stale (an empty title, no labels) for that many calls first, the
# lag verify-then-die's retry exists to survive; GH_STUB_READBACK_TITLE and
# GH_STUB_READBACK_LABELS (newline-separated) override the answer for good.
GH_FAKE_DIR="$(mktemp -d)"
fake_readback() {
  local rf="$GH_FAKE_DIR/readback_miss_remaining" remaining labels
  remaining="$(cat "$rf" 2>/dev/null)"; [ -n "$remaining" ] || remaining="${GH_STUB_READBACK_MISS:-0}"
  if [ "$remaining" -gt 0 ]; then echo $((remaining - 1)) >"$rf"; printf '\n'; return 0; fi
  printf '%s\n' "${GH_STUB_READBACK_TITLE-$(cat "$GH_FAKE_DIR/created_title" 2>/dev/null)}"
  labels="${GH_STUB_READBACK_LABELS-$(cat "$GH_FAKE_DIR/created_labels" 2>/dev/null)}"
  if [ -n "$labels" ]; then printf '%s\n' "$labels"; fi
}

# adapter_issue_create - mirrors stub_gh's `issue create` branch: records the
# flags (fake_record_flags) to GH_STUB_FILED when set, fails on
# GH_STUB_ISSUE_EXIT, otherwise answers a fake issue URL numbered
# GH_STUB_ISSUE_NUMBER (default 42) - the same shape review file/issue publish
# already parse the trailing number out of. Remembers its title and labels
# for fake_readback above.
adapter_issue_create() {
  if [ -n "${GH_STUB_FILED:-}" ]; then fake_record_flags "$@"; fi
  if [ "${GH_STUB_ISSUE_EXIT:-0}" != 0 ]; then
    echo "gh stub: issue create refused" >&2
    return "$GH_STUB_ISSUE_EXIT"
  fi
  : >"$GH_FAKE_DIR/created_labels"
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) printf '%s\n' "$2" >"$GH_FAKE_DIR/created_title"; shift ;;
      --label) printf '%s\n' "$2" >>"$GH_FAKE_DIR/created_labels"; shift ;;
    esac
    shift
  done
  printf 'https://github.com/acme/widgets/issues/%s\n' "${GH_STUB_ISSUE_NUMBER:-42}"
  return 0
}

# adapter_issue_close - mirrors stub_gh's `issue close` branch: logs "issue
# close <n>" plus the flags (fake_record_flags, so a --comment reaches
# GH_STUB_FILED the same way pr close's does) to GH_STUB_FILED when set, and
# fails on GH_STUB_ISSUE_CLOSE_EXIT. An issue in the GH_STUB_FINDINGS store is
# closed there too.
adapter_issue_close() {
  local n="$1"
  if [ -n "${GH_STUB_FILED:-}" ]; then
    printf 'issue close %s\n' "$n" >>"$GH_STUB_FILED"
    shift
    fake_record_flags "$@"
  fi
  if [ "${GH_STUB_ISSUE_CLOSE_EXIT:-0}" != 0 ]; then
    echo "gh stub: issue close refused" >&2
    return "$GH_STUB_ISSUE_CLOSE_EXIT"
  fi
  if [ -n "${GH_STUB_FINDINGS:-}" ] && [ -d "$GH_STUB_FINDINGS/$n" ]; then
    printf 'CLOSED\n' >"$GH_STUB_FINDINGS/$n/state"
  fi
  return 0
}

# The PR-resource primitives (issue #93, third of the #78 breakdown):
# open_pr's create/view, ci_probe's checks, cmd_review ready's ready, and
# cmd_redo_review's close. Each mirrors the same-named branch under stub_gh's
# `pr)` dispatch, reusing every GH_STUB_* variable that already drives it
# there rather than inventing a parallel vocabulary.

# adapter_pr_create - mirrors stub_gh's `pr create` branch: records "pr
# create" plus the flags (fake_record_flags) to GH_STUB_FILED when set, fails
# on GH_STUB_PR_CREATE_EXIT, otherwise answers a fake PR URL numbered
# GH_STUB_PR_NUMBER (default 99) - the same shape open_pr parses the trailing
# number out of.
adapter_pr_create() {
  if [ -n "${GH_STUB_FILED:-}" ]; then
    printf 'pr create\n' >>"$GH_STUB_FILED"
    fake_record_flags "$@"
  fi
  if [ "${GH_STUB_PR_CREATE_EXIT:-0}" != 0 ]; then
    echo "gh stub: pr create refused" >&2
    return "$GH_STUB_PR_CREATE_EXIT"
  fi
  printf 'https://github.com/acme/widgets/pull/%s\n' "${GH_STUB_PR_NUMBER:-99}"
  return 0
}

# adapter_pr_view - mirrors stub_gh's `pr view` branch: answers
# GH_STUB_PR_NUMBER when asked `--json number` (the call open_pr makes to
# learn the PR it just opened), answers state and isDraft together
# (GH_STUB_PR_STATE and GH_STUB_PR_DRAFT, default false) when asked for
# isDraft, and falls back to GH_STUB_PR_STATE alone for every other query.
# Asked `--json body` (pr fetch's and pr update's read, issue #444), it
# answers the body held in the file GH_STUB_PR_BODY names through the caller's
# own --jq, the same way the real gh applies it, and fails on
# GH_STUB_PR_BODY_EXIT. Asked `--json comments` (pr comments' read, issue
# #418), it applies the caller's own --jq to GH_STUB_PR_COMMENTS_JSON - the
# same gh-shaped JSON GH_STUB_COMMENTS_JSON holds for an issue - and fails on
# GH_STUB_PR_COMMENTS_EXIT. Logs nothing to GH_STUB_FILED - stub_gh's own
# `pr view` branch does not either.
adapter_pr_view() {
  local a q=""
  if [ "${2:-}" = --json ] && [ "${3:-}" = comments ]; then
    if [ "${GH_STUB_PR_COMMENTS_EXIT:-0}" != 0 ]; then
      echo "gh stub: pr view refused" >&2
      return "$GH_STUB_PR_COMMENTS_EXIT"
    fi
    [ "${4:-}" = --jq ] && q="${5:-}"
    printf '%s' "${GH_STUB_PR_COMMENTS_JSON:?gh stub: GH_STUB_PR_COMMENTS_JSON is unset}" | jq -r "${q:-.}"
    return
  fi
  if [ "${2:-}" = --json ] && [ "${3:-}" = body ]; then
    if [ "${GH_STUB_PR_BODY_EXIT:-0}" != 0 ]; then
      echo "gh stub: pr view refused" >&2
      return "$GH_STUB_PR_BODY_EXIT"
    fi
    [ "${4:-}" = --jq ] && q="${5:-}"
    jq -n --rawfile b "${GH_STUB_PR_BODY:?gh stub: GH_STUB_PR_BODY is unset}" '{body: $b}' | jq -r "${q:-.}"
    return
  fi
  for a in "$@"; do
    if [ "$a" = number ]; then
      printf '%s\n' "${GH_STUB_PR_NUMBER:-99}"
      return 0
    fi
    case "$a" in
      *isDraft*)
        printf '%s\n%s\n' "${GH_STUB_PR_STATE:-OPEN}" "${GH_STUB_PR_DRAFT:-false}"
        return 0 ;;
    esac
  done
  printf '%s\n' "${GH_STUB_PR_STATE:-OPEN}"
  return 0
}

# adapter_pr_refs - review ci's read of the PR's head, base and commits
# (issues #475, #476), mirroring stub_gh's `pr view --json headRefOid,...`
# arm: answers GH_STUB_PR_HEAD_OID (default forty zeros, a SHA no reflog or
# object store holds), GH_STUB_PR_HEAD_REF (default topic),
# GH_STUB_PR_BASE_REF (default main) and GH_STUB_PR_COMMITS (space-separated
# SHAs, oldest first; default the head alone, a single-commit PR) as the JSON
# object gh would, and fails on GH_STUB_PR_REFS_EXIT.
adapter_pr_refs() {
  if [ "${GH_STUB_PR_REFS_EXIT:-0}" != 0 ]; then
    echo "gh stub: pr view refused" >&2
    return "$GH_STUB_PR_REFS_EXIT"
  fi
  local o="${GH_STUB_PR_HEAD_OID:-0000000000000000000000000000000000000000}"
  jq -cn --arg o "$o" \
    --arg h "${GH_STUB_PR_HEAD_REF:-topic}" --arg b "${GH_STUB_PR_BASE_REF:-main}" \
    --arg c "${GH_STUB_PR_COMMITS-$o}" \
    '{headRefOid: $o, headRefName: $h, baseRefName: $b,
      commits: [$c | splits(" +") | select(. != "") | {oid: .}]}'
}

# review ci's CI-evidence reads (issue #476). The fakes default to exactly one
# signal present - a check-run on the base branch tip - so a grace test that
# says nothing about evidence keeps the grace; a test opts into each absence.
#
# adapter_branch_protection - the base branch's classic required status
# checks. GH_STUB_PROTECTION picks gh api's answer: none (default) is the 404
# `Branch not protected` GitHub gives an unprotected branch, required a 200
# naming one context, notfound the bare 404 `Not Found` of a token without
# access, boom a failed round trip.
adapter_branch_protection() {
  case "${GH_STUB_PROTECTION:-none}" in
    none)     printf '%s\n' '{"message":"Branch not protected","status":"404"}'
              echo "gh: Branch not protected (HTTP 404)" >&2; return 1 ;;
    required) printf '%s\n' '{"strict":false,"contexts":["build"],"checks":[{"context":"build","app_id":null}]}' ;;
    notfound) printf '%s\n' '{"message":"Not Found","status":"404"}'
              echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
    boom)     echo "dial tcp: lookup api.github.com: no such host" >&2; return 1 ;;
    *)        echo "gh stub: no protection named '$GH_STUB_PROTECTION'" >&2; return 99 ;;
  esac
}

# adapter_branch_rules - the rules every ruleset applies to the base branch.
# GH_STUB_RULES: none (default) is the `[]` of a branch no ruleset touches,
# required a required_status_checks rule, other a ruleset rule that requires
# no checks, boom a failed round trip.
adapter_branch_rules() {
  case "${GH_STUB_RULES:-none}" in
    none)     printf '%s\n' '[]' ;;
    required) printf '%s\n' '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]' ;;
    other)    printf '%s\n' '[{"type":"deletion"}]' ;;
    boom)     echo "dial tcp: lookup api.github.com: no such host" >&2; return 1 ;;
    *)        echo "gh stub: no rules named '$GH_STUB_RULES'" >&2; return 99 ;;
  esac
}

# adapter_commit_check_runs / adapter_commit_statuses - the check-runs and
# the combined commit status of one ref (a SHA, or the base branch's name for
# its tip). GH_STUB_CHECKED_REFS (default main, the base tip) and
# GH_STUB_STATUSED_REFS (default none) are space-separated lists of the refs
# that have one; a ref in GH_STUB_REF_READ_FAIL fails both reads.
fake_ref_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
adapter_commit_check_runs() {
  if fake_ref_in "$1" "${GH_STUB_REF_READ_FAIL:-}"; then echo "gh: Server Error (HTTP 502)" >&2; return 1; fi
  if fake_ref_in "$1" "${GH_STUB_CHECKED_REFS-main}"; then
    printf '%s\n' '{"total_count":1,"check_runs":[{"name":"build"}]}'
  else
    printf '%s\n' '{"total_count":0,"check_runs":[]}'
  fi
}
adapter_commit_statuses() {
  if fake_ref_in "$1" "${GH_STUB_REF_READ_FAIL:-}"; then echo "gh: Server Error (HTTP 502)" >&2; return 1; fi
  if fake_ref_in "$1" "${GH_STUB_STATUSED_REFS:-}"; then
    printf '%s\n' '{"state":"success","total_count":1,"statuses":[{"context":"ci/legacy"}]}'
  else
    printf '%s\n' '{"state":"pending","total_count":0,"statuses":[]}'
  fi
}

# adapter_pr_checks - mirrors stub_gh's `pr checks` branch, the trickiest one
# to replicate faithfully in-memory: ci_probe calls this once per poll tick,
# many times within the same process, so a plain shell variable counter would
# not match stub_gh's cross-subprocess behaviour where GH_STUB_CHECKS_N /
# GH_STUB_REQUIRED_N name a file the count is persisted to. This fake reads
# and writes the same file, so a test that sets GH_STUB_REQUIRED_N to advance
# a script across separate `orch.sh` invocations behaves identically whichever
# adapter is in play.
#
# GH_STUB_REQUIRED (when --required is among the arguments) or GH_STUB_CHECKS
# otherwise is a `|`-separated script of answers - green, failing, cancel,
# pending, pending0, garbage, none, boom - consumed one per call with the last
# one repeating once the script runs out.
#
# `pending` returns exit 8 with a pending bucket in its JSON, the real gh
# pr checks documents but that our JSON-asking calls never actually take
# (ci_probe's `8)` arm exists only against that documented case); `pending0`
# is the path real `gh pr checks --json` actually takes - exit 0 with the
# pending bucket carrying the answer instead. Getting the two exits right is
# what proves ci_probe's own bucket classification, not just its exit-status
# read, still drives the verdict.
adapter_pr_checks() {
  local a req=0 script counter i answer
  for a in "$@"; do
    if [ "$a" = --required ]; then req=1; fi
  done
  if [ "$req" = 1 ]; then
    script="${GH_STUB_REQUIRED:-none}"; counter="${GH_STUB_REQUIRED_N:-}"
  else
    script="${GH_STUB_CHECKS:-green}"; counter="${GH_STUB_CHECKS_N:-}"
  fi
  i=1
  if [ -n "$counter" ]; then
    i=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$i" >"$counter"
  fi
  answer="$(printf '%s' "$script" | awk -F'|' -v i="$i" '{ print (i <= NF) ? $i : $NF }')"
  case "$answer" in
    green)    printf '%s\n' '[{"bucket":"pass","name":"build","state":"SUCCESS"}]' ;;
    failing)  printf '%s\n' '[{"bucket":"fail","name":"build","state":"FAILURE"},{"bucket":"pass","name":"lint","state":"SUCCESS"}]' ;;
    cancel)   printf '%s\n' '[{"bucket":"cancel","name":"build","state":"CANCELLED"}]' ;;
    pending)  printf '%s\n' '[{"bucket":"pending","name":"build","state":"IN_PROGRESS"}]'; return 8 ;;
    pending0) printf '%s\n' '[{"bucket":"pending","name":"build","state":"IN_PROGRESS"}]' ;;
    garbage)  printf '%s\n' 'not json at all' ;;
    none)     echo "no checks reported on the 'topic' branch" >&2; return 1 ;;
    boom)     echo "dial tcp: lookup api.github.com: no such host" >&2; return 1 ;;
    *)        echo "gh stub: no script named '$answer'" >&2; return 99 ;;
  esac
  return 0
}

# adapter_pr_ready - mirrors stub_gh's `pr ready` branch's shape (logs
# nothing). Failing on demand with GH_STUB_READY_EXIT is this fake's own job
# now - no live test left a caller for stub_gh's own copy of that check once
# cmd_review's ready op fully moved onto this adapter (#94), so it was retired.
adapter_pr_ready() {
  return "${GH_STUB_READY_EXIT:-0}"
}

# adapter_pr_close - mirrors stub_gh's `pr close` branch: logs "pr close <n>"
# plus the flags (fake_record_flags, so a --comment reaches GH_STUB_FILED the
# same way issue close's does) to GH_STUB_FILED when set. Failing on demand
# with GH_STUB_PR_CLOSE_EXIT is this fake's own job now - stub_gh's own copy of
# that check lost its last caller once cmd_redo_review's close fully moved onto
# this adapter (#94), so it was retired.
adapter_pr_close() {
  local n="$1"
  if [ -n "${GH_STUB_FILED:-}" ]; then
    printf 'pr close %s\n' "$n" >>"$GH_STUB_FILED"
    shift
    fake_record_flags "$@"
  fi
  if [ "${GH_STUB_PR_CLOSE_EXIT:-0}" != 0 ]; then
    echo "gh stub: pr close refused" >&2
    return "$GH_STUB_PR_CLOSE_EXIT"
  fi
  return 0
}

# adapter_pr_list - pr release's two reads (issue #139): logs "pr list
# <args...>" to GH_STUB_FILED when set, fails on GH_STUB_PR_LIST_EXIT, and
# answers the JSON array for the --state it was asked for -
# GH_STUB_PR_LIST_OPEN or GH_STUB_PR_LIST_MERGED, each default "[]" - through
# the caller's own --jq, the same way the real gh applies it. Filtering by
# --base/--head is gh's job, not the fake's: a test asserts on the flags.
adapter_pr_list() {
  local state="" q="" json
  if [ -n "${GH_STUB_FILED:-}" ]; then printf 'pr list %s\n' "$*" >>"$GH_STUB_FILED"; fi
  if [ "${GH_STUB_PR_LIST_EXIT:-0}" != 0 ]; then
    echo "gh stub: pr list refused" >&2
    return "$GH_STUB_PR_LIST_EXIT"
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state="$2"; shift ;;
      --jq)    q="$2"; shift ;;
    esac
    shift
  done
  case "$state" in
    open)   json="${GH_STUB_PR_LIST_OPEN:-[]}" ;;
    merged) json="${GH_STUB_PR_LIST_MERGED:-[]}" ;;
    *)      echo "gh stub: unscripted pr list state '$state'" >&2; return 99 ;;
  esac
  if [ -n "$q" ]; then printf '%s' "$json" | jq -r "$q"; else printf '%s\n' "$json"; fi
}

# adapter_pr_comment - pr comment's post (issue #343): logs "pr comment <n>"
# plus the flags (fake_record_flags, so the --body-file's contents reach
# GH_STUB_FILED under body:) when set, and fails on GH_STUB_PR_COMMENT_EXIT.
adapter_pr_comment() {
  local n="$1"
  if [ -n "${GH_STUB_FILED:-}" ]; then
    printf 'pr comment %s\n' "$n" >>"$GH_STUB_FILED"
    shift
    fake_record_flags "$@"
  fi
  if [ "${GH_STUB_PR_COMMENT_EXIT:-0}" != 0 ]; then
    echo "gh stub: pr comment refused" >&2
    return "$GH_STUB_PR_COMMENT_EXIT"
  fi
  return 0
}

# adapter_pr_edit - pr update's replacement of a PR's body (issue #444): logs
# "pr edit <n>" plus the flags (fake_record_flags) to GH_STUB_FILED when set,
# fails on GH_STUB_PR_EDIT_EXIT, and otherwise writes the --body-file's
# contents into the GH_STUB_PR_BODY file, so a test reads the edit back from
# the PR itself.
adapter_pr_edit() {
  local n="$1"
  shift
  if [ -n "${GH_STUB_FILED:-}" ]; then
    printf 'pr edit %s\n' "$n" >>"$GH_STUB_FILED"
    fake_record_flags "$@"
  fi
  if [ "${GH_STUB_PR_EDIT_EXIT:-0}" != 0 ]; then
    echo "gh stub: pr edit refused" >&2
    return "$GH_STUB_PR_EDIT_EXIT"
  fi
  while [ $# -gt 0 ]; do
    case "$1" in --body-file) cat "$2" >"${GH_STUB_PR_BODY:?gh stub: GH_STUB_PR_BODY is unset}"; shift ;; esac
    shift
  done
  return 0
}
