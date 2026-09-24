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
#   GH_STUB_FILED            when set, appended with "label create <args...>",
#                             the same line shape stub_gh writes, so an
#                             assertion against GH_STUB_FILED does not care
#                             which fake produced it
adapter_label_create() {
  if [ "${GH_STUB_MODE:-ok}" = labelfail ]; then return 1; fi
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
# /pull/ url into.
adapter_issue_view() {
  if [ -n "${GH_STUB_FILED:-}" ]; then printf 'issue view %s\n' "$*" >>"$GH_STUB_FILED"; fi
  if [ "${GH_STUB_VIEW_EXIT:-0}" != 0 ]; then
    echo "gh stub: issue view refused" >&2
    return "$GH_STUB_VIEW_EXIT"
  fi
  local a
  for a in "$@"; do
    case "$a" in
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
  if [ -n "${GH_STUB_FILED:-}" ]; then
    printf 'issue %s %s\n' "$op" "$n" >>"$GH_STUB_FILED"
    shift
    fake_record_flags "$@"
  fi
  if [ "$op" = edit ]; then st="${GH_STUB_EDIT_EXIT:-0}"; else st="${GH_STUB_COMMENT_EXIT:-0}"; fi
  if [ "$st" != 0 ]; then
    echo "gh stub: issue $op refused" >&2
    return "$st"
  fi
  return 0
}
adapter_issue_edit()    { fake_issue_write edit "$@"; }
adapter_issue_comment() { fake_issue_write comment "$@"; }

# adapter_issue_create - mirrors stub_gh's `issue create` branch: records the
# flags (fake_record_flags) to GH_STUB_FILED when set, fails on
# GH_STUB_ISSUE_EXIT, otherwise answers a fake issue URL numbered
# GH_STUB_ISSUE_NUMBER (default 42) - the same shape review file/issue publish
# already parse the trailing number out of.
adapter_issue_create() {
  if [ -n "${GH_STUB_FILED:-}" ]; then fake_record_flags "$@"; fi
  if [ "${GH_STUB_ISSUE_EXIT:-0}" != 0 ]; then
    echo "gh stub: issue create refused" >&2
    return "$GH_STUB_ISSUE_EXIT"
  fi
  printf 'https://github.com/acme/widgets/issues/%s\n' "${GH_STUB_ISSUE_NUMBER:-42}"
  return 0
}

# adapter_issue_close - mirrors stub_gh's `issue close` branch: logs "issue
# close <n>" plus the flags (fake_record_flags, so a --comment reaches
# GH_STUB_FILED the same way pr close's does) to GH_STUB_FILED when set, and
# fails on GH_STUB_ISSUE_CLOSE_EXIT.
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
# Logs nothing to GH_STUB_FILED - stub_gh's own `pr view` branch does not
# either.
adapter_pr_view() {
  local a
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
