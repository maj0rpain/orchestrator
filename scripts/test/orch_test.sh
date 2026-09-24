#!/usr/bin/env bash
#
# Tests for scripts/orch.sh.
#
# orch.sh is where silent wrongness hides: `doctor` returning success on a
# deleted branch, a missing triage label, or a handoff with an empty required
# section, are bugs you would experience as generic confusion three phases
# later - or, worse, as a phase that dies once the session that could have
# fixed it has been cleared. Each runs
# against a throwaway git repo in $TMPDIR - nothing here touches a real flow.

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/orch.sh"
GH_ADAPTER_FAKE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh_adapter_fake.sh"
PASS=0
FAIL=0
SKIP=0

# The override outranks every install layout, so one leaking in from the shell
# running the tests would decide every mattpocock lookup below.
unset ORCHESTRATOR_MATTPOCOCK_ROOT
# The same goes for the host signals doctor reads: the shell running the tests
# is often itself a Claude Code or Junie session. Each test names its host.
unset ORCHESTRATOR_HOST CLAUDECODE JUNIE_EXTENSION_ROOT

ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
skip() { printf '  skip %s\n     %s\n' "$1" "$2"; SKIP=$((SKIP + 1)); }

# Git Bash / MSYS2 (and Cygwin) both set OSTYPE this way; used to skip fixtures
# that are known not to work in that environment rather than report a false FAIL.
on_windows_bash() {
  case "$OSTYPE" in msys*|cygwin*) return 0 ;; *) return 1 ;; esac
}
skip_no_jq() { skip "$1" "path_without_jq doesn't work on Windows/Git Bash - see its definition"; }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}
assert_contains() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not contain '$3': $2" ;; esac
}
assert_not_contains() {
  case "$2" in *"$3"*) bad "$1" "output contained '$3': $2" ;; *) ok "$1" ;; esac
}
assert_status() {
  if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "expected exit $3, got $2"; fi
}
# The CI classifier's verdict is its first line and the detail lines below it are
# not the assertion, so most of these read one line out of a captured $out.
assert_first_line() {
  assert_eq "$1" "$(printf '%s\n' "$2" | sed -n 1p)" "$3"
}

# A fresh repo with the tracker precondition satisfied, cwd inside it.
new_repo() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  mkdir -p "$d/docs/agents"
  echo "# tracker" >"$d/docs/agents/issue-tracker.md"
  git -C "$d" add -A
  git -C "$d" commit -qm init
  cd "$d" || exit 1
  printf '%s\n' "$d"
}

writeln() { printf '%s\n' "$@"; }

complete_plan_handoff() {
  writeln '## Decisions' 'Use X.' '' \
          '## Rejected alternatives' 'Y, because Z.' '' \
          '## Constraints' 'Must run offline.' '' \
          '## Open assumptions' 'Assumes W.' '' \
          '## Host fallbacks' 'None (Claude Code).' >"$1"
}

complete_spec_handoff() {
  writeln '## Spec issue' '#1.' '' \
          '## Seams' 'The CLI.' '' \
          '## Spec review changelog' 'Not reviewed.' '' \
          '## Ticket breakdown' '#1.' '' \
          '## Host fallbacks' 'None (Claude Code).' >"$1"
}

complete_implement_handoff() {
  writeln '## PR' '#3.' '' \
          '## Spec issue' '#1.' '' \
          '## Base SHA' 'abc1234.' '' \
          '## Deviations' 'None.' '' \
          '## Verification' 'scripts/test/orch_test.sh' '' \
          '## Host fallbacks' 'None (Claude Code).' >"$1"
}

# --- doctor harness ---------------------------------------------------------

# A fake `gh` on PATH. doctor's severity rules turn on the difference between
# "GitHub said no" and "GitHub could not tell us", and that difference cannot be
# arranged against a real gh. GH_STUB_MODE picks which answer comes back:
#   ok        authenticated, repo resolves, every documented label exists
#   noauth    `gh auth status` fails the way an unauthenticated gh does
#   offline   every call fails with a connection error
#   nolabels  authenticated, but the repo carries none of the documented labels
# GH_STUB_LOG, when set, names a file the stub appends each subcommand to, which
# is how a test asserts that a scope made no network call at all.
#
# `pr checks` answers separately, because the CI classifier is the one caller
# that has to see the answer *change* between calls. GH_STUB_CHECKS and
# GH_STUB_REQUIRED are each a `|`-separated script of answers (green, failing,
# pending, none, boom), consumed one per call with the last repeating and counted
# in the file GH_STUB_CHECKS_N / GH_STUB_REQUIRED_N names. They advance
# independently, because the classifier asks the two probes different questions:
# what branch protection requires, and what ran on the commit.
#
# `label create` and `issue create` are the filing boundary. GH_STUB_FILED names
# a file the stub appends what it was asked for to - label names and flags, the
# issue's title, labels, and body - and `issue create` answers with a fake issue
# URL numbered GH_STUB_ISSUE_NUMBER, or fails when GH_STUB_ISSUE_EXIT says so.
#
# `issue view`, `issue edit`, and `issue comment` are the spec review's hand on
# the issue. `view` answers GH_STUB_BODY verbatim, and fails on demand with
# GH_STUB_VIEW_EXIT (still exercised for real - `init --issue`/`check_flow_issue`
# read state and labels through it too); `edit` and `comment` record the
# number, flags, and body file contents they were handed to GH_STUB_FILED.
#
# `view` also answers `--json state` and `--json labels` independently of the
# body - mirroring the GH_STUB_PR_NUMBER/GH_STUB_PR_STATE split on `pr view`:
# GH_STUB_ISSUE_STATE (default OPEN) and GH_STUB_ISSUE_LABELS (default
# ready-for-agent, one label per line) - so `init --issue` and
# `check_flow_issue` can be tested without disturbing GH_STUB_BODY. The
# combined `--json state,labels` query validate_adopted_issue makes answers
# both together, state on the first line and one label per line after -
# mirroring `pr view`'s own `--json state,isDraft` combined-query case.
#
# `pr create` and `pr view` are pr open's boundary. `create` records its flags
# and body-file contents to GH_STUB_FILED like `issue create`, answering with a
# fake PR URL numbered GH_STUB_PR_NUMBER, or failing when GH_STUB_PR_CREATE_EXIT
# says so. `view` answers GH_STUB_PR_NUMBER when asked `--json number` - the
# call pr open makes to learn the PR it just opened - answers `state` and
# `isDraft` together (GH_STUB_PR_STATE and GH_STUB_PR_DRAFT, default false) for
# check_flow_review_draft's combined query, and falls back to the existing
# `--json state` behaviour (GH_STUB_PR_STATE) for every other query.
#
# `pr close` and `issue close` are redo's boundary. Both record the number and
# `--comment` text to GH_STUB_FILED like every other write above; `issue close`
# fails on demand with GH_STUB_ISSUE_CLOSE_EXIT.
#
# `issue list` is check_sub_issues's way of finding an issue to probe against:
# it answers GH_STUB_ISSUE_LIST (default "1"), empty when explicitly set to
# "" to simulate a repo with no issues. The sub_issues GET it then makes fails
# on demand independently of the POST one ticket_publish uses:
# GH_STUB_SUBISSUE_GET_EXIT.
stub_gh() {
  local d
  d="$(mktemp -d)"
  cat >"$d/gh" <<'GH'
#!/usr/bin/env bash
if [ -n "${GH_STUB_LOG:-}" ]; then printf '%s\n' "$1" >>"$GH_STUB_LOG"; fi
# Records the flags of an issue write to GH_STUB_FILED, the body file's
# contents inlined, so a test asserts what reached gh rather than the exit.
record_flags() {
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
# The `ticket` group's tiny fake GitHub: an issue's open/closed state and its
# sub-issue/blocked-by edges, persisted as files under GH_STUB_DB so they
# survive across the separate `gh` subprocesses one `orch.sh ticket ...` call
# makes. Absent GH_STUB_DB, every issue reads back open with no edges - which
# is what the argument-validation tests below need and nothing more.
api_state() {
  if [ -n "$db" ] && [ -f "$db/state/$1" ]; then cat "$db/state/$1"; else echo open; fi
}
api_blocked_count() {
  local bn=0 bl
  if [ -n "$db" ] && [ -f "$db/blocked_by/$1" ]; then
    while IFS= read -r bl; do
      [ -z "$bl" ] && continue
      [ "$(api_state "$bl")" = open ] && bn=$((bn + 1))
    done <"$db/blocked_by/$1"
  fi
  printf '%s\n' "$bn"
}
# GH_STUB_SUBISSUE_MISS / GH_STUB_BLOCKED_MISS count down how many times the
# corresponding listing still reports empty after a real write - simulating
# the lag ticket_publish's verify-then-die retry exists to survive. Each
# counts independently and persists in GH_STUB_DB across the separate `gh`
# processes one publish call makes.
api_list_sub_issues() {
  local parent="$1" rf remaining out first c
  if [ -n "$db" ]; then
    rf="$db/subissue_miss_remaining"
    remaining="$(cat "$rf" 2>/dev/null)"; [ -n "$remaining" ] || remaining="${GH_STUB_SUBISSUE_MISS:-0}"
    if [ "$remaining" -gt 0 ]; then echo $((remaining - 1)) >"$rf"; echo '[]'; return; fi
  fi
  out="["; first=1
  if [ -n "$db" ] && [ -f "$db/sub_issues/$parent" ]; then
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      [ "$first" = 1 ] || out="$out,"
      first=0
      out="$out{\"number\":$c,\"state\":\"$(api_state "$c")\",\"issue_dependencies_summary\":{\"blocked_by\":$(api_blocked_count "$c")}}"
    done <"$db/sub_issues/$parent"
  fi
  printf '%s]\n' "$out"
}
api_list_blocked_by() {
  local child="$1" rf remaining out first b
  if [ -n "$db" ]; then
    rf="$db/blocked_miss_remaining"
    remaining="$(cat "$rf" 2>/dev/null)"; [ -n "$remaining" ] || remaining="${GH_STUB_BLOCKED_MISS:-0}"
    if [ "$remaining" -gt 0 ]; then echo $((remaining - 1)) >"$rf"; echo '[]'; return; fi
  fi
  out="["; first=1
  if [ -n "$db" ] && [ -f "$db/blocked_by/$child" ]; then
    while IFS= read -r b; do
      [ -z "$b" ] && continue
      [ "$first" = 1 ] || out="$out,"
      first=0
      out="$out{\"number\":$b}"
    done <"$db/blocked_by/$child"
  fi
  printf '%s]\n' "$out"
}
db="${GH_STUB_DB:-}"
if [ "${GH_STUB_MODE:-ok}" = offline ]; then
  echo "dial tcp: lookup api.github.com: no such host" >&2
  exit 1
fi
case "$1" in
  auth)
    if [ "${GH_STUB_MODE:-ok}" = noauth ]; then
      echo "You are not logged into any GitHub hosts." >&2
      exit 1
    fi
    echo "Logged in to github.com" ;;
  # doctor asks nameWithOwner and defaultBranchRef together and reads both
  # lines; default_branch asks defaultBranchRef alone and reads one, so it
  # gets GH_STUB_REPO's last word.
  repo)
    case "$*" in
      *nameWithOwner*) printf '%s\n' ${GH_STUB_REPO-acme/widgets main} ;;
      *) set -- ${GH_STUB_REPO-acme/widgets main}; [ $# -eq 0 ] || printf '%s\n' "${!#}" ;;
    esac ;;
  label)
    if [ "${GH_STUB_MODE:-ok}" = labelfail ]; then exit 1; fi
    if [ "$2" = create ]; then
      shift 2
      if [ -n "${GH_STUB_FILED:-}" ]; then printf 'label create %s\n' "$*" >>"$GH_STUB_FILED"; fi
      exit 0
    fi
    if [ "${GH_STUB_MODE:-ok}" != nolabels ]; then
      printf '%s\n' "${GH_STUB_LABELS-needs-triage
ready-for-agent}"
    fi ;;
  issue)
    case "$2" in
      view)
        shift 2
        if [ -n "${GH_STUB_FILED:-}" ]; then printf 'issue view %s\n' "$*" >>"$GH_STUB_FILED"; fi
        [ "${GH_STUB_VIEW_EXIT:-0}" = 0 ] || { echo "gh stub: issue view refused" >&2; exit "$GH_STUB_VIEW_EXIT"; }
        for a in "$@"; do
          case "$a" in
            # validate_adopted_issue's combined query: state on the first
            # line, then one line per label (none at all if the issue is
            # unlabelled) - the same multi-line shape pr view's isDraft
            # combined query answers with below.
            *state,labels*|*labels,state*)
              printf '%s\n' "${GH_STUB_ISSUE_STATE:-OPEN}"
              if [ -n "${GH_STUB_ISSUE_LABELS-ready-for-agent}" ]; then
                printf '%s\n' "${GH_STUB_ISSUE_LABELS-ready-for-agent}"
              fi
              exit 0 ;;
            state)  printf '%s\n' "${GH_STUB_ISSUE_STATE:-OPEN}"; exit 0 ;;
            labels) printf '%s\n' "${GH_STUB_ISSUE_LABELS-ready-for-agent}"; exit 0 ;;
          esac
        done
        printf '%s\n' "${GH_STUB_BODY-Body of the issue.}"
        exit 0 ;;
      edit|comment)
        op="$2"; shift 2
        if [ -n "${GH_STUB_FILED:-}" ]; then
          printf 'issue %s %s\n' "$op" "$1" >>"$GH_STUB_FILED"
          shift
          record_flags "$@"
        fi
        exit 0 ;;
      close)
        shift 2
        cnum="$1"
        if [ -n "${GH_STUB_FILED:-}" ]; then
          printf 'issue close %s\n' "$1" >>"$GH_STUB_FILED"
          shift
          record_flags "$@"
        fi
        [ "${GH_STUB_ISSUE_CLOSE_EXIT:-0}" = 0 ] || { echo "gh stub: issue close refused" >&2; exit "$GH_STUB_ISSUE_CLOSE_EXIT"; }
        if [ -n "$db" ]; then mkdir -p "$db/state"; echo closed >"$db/state/$cnum"; fi
        exit 0 ;;
      reopen)
        shift 2
        cnum="$1"
        if [ -n "${GH_STUB_FILED:-}" ]; then printf 'issue reopen %s\n' "$1" >>"$GH_STUB_FILED"; fi
        [ "${GH_STUB_ISSUE_REOPEN_EXIT:-0}" = 0 ] || { echo "gh stub: issue reopen refused" >&2; exit "$GH_STUB_ISSUE_REOPEN_EXIT"; }
        if [ -n "$db" ]; then mkdir -p "$db/state"; echo open >"$db/state/$cnum"; fi
        exit 0 ;;
      list)
        shift 2
        if [ -n "${GH_STUB_FILED:-}" ]; then printf 'issue list %s\n' "$*" >>"$GH_STUB_FILED"; fi
        printf '%s\n' "${GH_STUB_ISSUE_LIST-1}"
        exit 0 ;;
      create) ;;
      *) echo "gh stub: unscripted issue op '$2'" >&2; exit 99 ;;
    esac
    shift 2
    if [ -n "${GH_STUB_FILED:-}" ]; then record_flags "$@"; fi
    [ "${GH_STUB_ISSUE_EXIT:-0}" = 0 ] || { echo "gh stub: issue create refused" >&2; exit "$GH_STUB_ISSUE_EXIT"; }
    if [ -n "$db" ]; then
      mkdir -p "$db/state"
      newnum="$(cat "$db/issue_seq" 2>/dev/null)"; [ -n "$newnum" ] || newnum="${GH_STUB_ISSUE_NUMBER:-42}"
      echo $((newnum + 1)) >"$db/issue_seq"
      echo open >"$db/state/$newnum"
      echo "https://github.com/acme/widgets/issues/$newnum"
    else
      echo "https://github.com/acme/widgets/issues/${GH_STUB_ISSUE_NUMBER:-42}"
    fi ;;
  api)
    shift
    api_method=GET; api_jq=""; api_fkey=""; api_fval=""; api_path=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --method)   api_method="$2"; shift 2 ;;
        -f|-F)      api_fkey="${2%%=*}"; api_fval="${2#*=}"; shift 2 ;;
        --jq)       api_jq="$2"; shift 2 ;;
        --paginate) shift ;;
        *)          api_path="$1"; shift ;;
      esac
    done
    if [ -n "${GH_STUB_LOG:-}" ]; then printf 'api %s %s\n' "$api_method" "$api_path" >>"$GH_STUB_LOG"; fi
    api_rest="${api_path#repos/*/issues/}"
    case "$api_rest" in
      */*) api_num="${api_rest%%/*}"; api_sub="${api_rest#*/}" ;;
      *)   api_num="$api_rest"; api_sub="" ;;
    esac
    if [ "$api_sub" = sub_issues ] && [ "$api_method" = POST ] \
        && [ "${GH_STUB_SUBISSUE_POST_EXIT:-0}" != 0 ]; then
      echo "gh stub: sub_issues POST refused" >&2; exit "$GH_STUB_SUBISSUE_POST_EXIT"
    fi
    if [ "$api_sub" = sub_issues ] && [ "$api_method" = GET ] \
        && [ "${GH_STUB_SUBISSUE_GET_EXIT:-0}" != 0 ]; then
      echo "gh stub: sub_issues GET refused" >&2; exit "$GH_STUB_SUBISSUE_GET_EXIT"
    fi
    if [ "$api_sub" = dependencies/blocked_by ] && [ "$api_method" = POST ] \
        && [ "${GH_STUB_BLOCKED_POST_EXIT:-0}" != 0 ]; then
      echo "gh stub: blocked_by POST refused" >&2; exit "$GH_STUB_BLOCKED_POST_EXIT"
    fi
    [ "${GH_STUB_API_EXIT:-0}" = 0 ] || { echo "gh stub: api call refused" >&2; exit "$GH_STUB_API_EXIT"; }
    case "$api_sub" in
      "")
        api_json="$(printf '{"id":%d,"number":%d,"state":"%s","issue_dependencies_summary":{"blocked_by":%s}}' \
          "$((api_num * 1000))" "$api_num" "$(api_state "$api_num")" "$(api_blocked_count "$api_num")")" ;;
      sub_issues)
        if [ "$api_method" = POST ]; then
          if [ -n "$db" ]; then
            mkdir -p "$db/sub_issues" "$db/state"
            child_num=$((api_fval / 1000))
            printf '%s\n' "$child_num" >>"$db/sub_issues/$api_num"
            [ -f "$db/state/$child_num" ] || echo open >"$db/state/$child_num"
          fi
          api_json='{}'
        else
          api_json="$(api_list_sub_issues "$api_num")"
        fi ;;
      dependencies/blocked_by)
        if [ "$api_method" = POST ]; then
          if [ -n "$db" ]; then
            mkdir -p "$db/blocked_by"
            blocker_num=$((api_fval / 1000))
            printf '%s\n' "$blocker_num" >>"$db/blocked_by/$api_num"
          fi
          api_json='{}'
        else
          api_json="$(api_list_blocked_by "$api_num")"
        fi ;;
      *) echo "gh stub: unscripted api path '$api_path'" >&2; exit 99 ;;
    esac
    if [ -n "$api_jq" ]; then printf '%s' "$api_json" | jq -r "$api_jq"; else printf '%s\n' "$api_json"; fi
    ;;
  pr)
    case "$2" in
      ready) exit 0 ;;
      close)
        shift 2
        if [ -n "${GH_STUB_FILED:-}" ]; then
          printf 'pr close %s\n' "$1" >>"$GH_STUB_FILED"
          shift
          record_flags "$@"
        fi
        exit 0 ;;
      checks)
        req=0
        for a in "$@"; do if [ "$a" = --required ]; then req=1; fi; done
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
          green)   echo '[{"bucket":"pass","name":"build","state":"SUCCESS"}]' ;;
          failing) echo '[{"bucket":"fail","name":"build","state":"FAILURE"},{"bucket":"pass","name":"lint","state":"SUCCESS"}]' ;;
          cancel)  echo '[{"bucket":"cancel","name":"build","state":"CANCELLED"}]' ;;
          pending) echo '[{"bucket":"pending","name":"build","state":"IN_PROGRESS"}]'; exit 8 ;;
          # gh documents exit 8 for pending checks, but with --json it answers 0
          # and reports the state in the bucket instead. Both reach the same
          # verdict, and only this arm exercises the one real gh takes.
          pending0) echo '[{"bucket":"pending","name":"build","state":"IN_PROGRESS"}]' ;;
          # Exit 0 with something that is not JSON. jq fails, and the answer
          # must not be read as the empty array that means "no checks".
          garbage) echo 'not json at all' ;;
          none)    echo "no checks reported on the 'topic' branch" >&2; exit 1 ;;
          boom)    echo "dial tcp: lookup api.github.com: no such host" >&2; exit 1 ;;
          # Without this arm a typo in GH_STUB_CHECKS prints nothing and exits 0,
          # which ci_probe reads as a repo with no checks - a test that passes
          # while asserting nothing.
          *)       echo "gh stub: no script named '$answer'" >&2; exit 99 ;;
        esac ;;
      create)
        shift 2
        if [ -n "${GH_STUB_FILED:-}" ]; then printf 'pr create\n' >>"$GH_STUB_FILED"; record_flags "$@"; fi
        [ "${GH_STUB_PR_CREATE_EXIT:-0}" = 0 ] || { echo "gh stub: pr create refused" >&2; exit "$GH_STUB_PR_CREATE_EXIT"; }
        echo "https://github.com/acme/widgets/pull/${GH_STUB_PR_NUMBER:-99}" ;;
      view)
        shift 2
        for a in "$@"; do
          if [ "$a" = number ]; then echo "${GH_STUB_PR_NUMBER:-99}"; exit 0; fi
          case "$a" in
            *isDraft*) printf '%s\n%s\n' "${GH_STUB_PR_STATE:-OPEN}" "${GH_STUB_PR_DRAFT:-false}"; exit 0 ;;
          esac
        done
        echo "${GH_STUB_PR_STATE:-OPEN}" ;;
      *) echo "${GH_STUB_PR_STATE:-OPEN}" ;;
    esac ;;
esac
GH
  chmod +x "$d/gh"
  PATH="$d:$PATH"
}

# A fake mattpocock-skills install under a throwaway HOME holding exactly the
# skills named. The *partial* install is the regression doctor exists to catch,
# and it is unreachable through the extremes: with only all-present and
# all-absent, the per-skill check is exercised by whatever happens to be
# installed on the machine running the tests, which is to say not at all.
stub_mattpocock() {
  local home base s
  home="$(mktemp -d)"
  base="$home/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.3/skills/engineering"
  for s in "$@"; do
    mkdir -p "$base/$s"
    echo "# $s" >"$base/$s/SKILL.md"
  done
  printf '%s\n' "$home"
}

# Add the named skills to HOME ($2) in one install layout ($1), so a lookup can
# be tested against each layout a supported host produces, alone or stacked.
#   claude   - Claude's namespaced, versioned plugin cache
#   junie    - Junie's extension cache, flat skills/<name>
#   agents   - the skills CLI store, each skill recorded in the lockfile
#   override - a checkout that ORCHESTRATOR_MATTPOCOCK_ROOT is pointed at
# `agents-foreign` puts a same-named skill in the skills CLI store but records
# it as belonging to some other plugin.
mp_install() {
  local layout="$1" home="$2" base plugin="mattpocock-skills" s lock
  shift 2
  case "$layout" in
    claude)   base="$home/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.3/skills/engineering" ;;
    junie)    base="$home/.junie/extensions/github-mattpocock-skills/mattpocock-skills/skills" ;;
    agents)   base="$home/.agents/skills" ;;
    agents-foreign) base="$home/.agents/skills"; plugin="someone-elses-skills" ;;
    override) base="$home/mp-checkout/skills/engineering" ;;
  esac
  lock="$home/.agents/.skill-lock.json"
  for s in "$@"; do
    mkdir -p "$base/$s"
    echo "# $s ($layout)" >"$base/$s/SKILL.md"
    case "$layout" in
      agents*)
        [ -f "$lock" ] || echo '{"version":3,"skills":{}}' >"$lock"
        jq --arg n "$s" --arg p "$plugin" \
          '.skills[$n] = {source: "x/y", skillPath: ("skills/" + $n + "/SKILL.md"), pluginName: $p}' \
          "$lock" >"$lock.tmp" && mv "$lock.tmp" "$lock" ;;
    esac
  done
}

# The documented triage-label table, in the shape the setup skill writes it:
# a header row, a separator row, and backticked labels in the second column.
labels_doc() {
  writeln '# Triage Labels' '' \
          '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
          '| -------------------------- | -------------------- | ----------- |' \
          '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
          '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready   |' \
          '' 'Edit the right-hand column to match whatever vocabulary you use.' >"$1"
}

# A repo where every --env check passes, so a test can break exactly one thing
# and attribute the result to it.
healthy_repo() {
  new_repo >/dev/null
  git remote add origin https://github.com/acme/widgets.git
  labels_doc docs/agents/triage-labels.md
  printf '%s\n' ".orchestrator/" >>.git/info/exclude
  stub_gh
  export CLAUDE_PLUGIN_ROOT="$PWD"
  HOME="$(stub_mattpocock to-spec implement code-review handoff)"
  export HOME
  unset GH_STUB_MODE
}

# A PATH with everything orch.sh reaches for except jq. Reporting "jq is
# missing" is the one thing doctor has to do without jq, so the only honest way
# to test it is to actually take jq away.
#
# Known gap: this doesn't work on Windows/Git Bash (MSYS) or Cygwin. `printf`
# has no external binary to `ln -sf` there (it's builtin-only), and MSYS's
# path translation between the trimmed Unix-style PATH and the Windows-side
# resolution needed to launch orch.sh breaks down under it - the invocation
# exits 127 with empty output before orch.sh's own logic ever runs. Callers
# guard with on_windows_bash and skip rather than report a false FAIL - see
# issue #68.
path_without_jq() {
  local d t p
  d="$(mktemp -d)"
  for t in env bash git gh awk sed grep tr cat sort tail head date mktemp mv rm mkdir chmod basename dirname printf; do
    if p="$(command -v "$t" 2>/dev/null)"; then ln -sf "$p" "$d/$t"; fi
  done
  printf '%s\n' "$d"
}

# Marks $1 as pushed to origin without a real push - it only has to make
# "$1@{upstream}" resolve, so that cmd_branch retire's own push/delete (the
# real git I/O the redo review assertions actually check) has something to
# run against. The genuine push/checkout cycle for a redo's
# rename-and-republish is proven once by "redo review"'s first iteration
# and, at the lower branch-retire level, by "branch retire"'s own
# to-retire/to-retire-redo-1 assertions - later redo iterations only need the
# upstream to look real, not a second full round trip to the same bare repo.
stub_pushed_branch() {
  local branch="$1"
  git update-ref "refs/remotes/origin/$branch" "$(git rev-parse "$branch")"
  git branch -q --set-upstream-to="origin/$branch" "$branch"
}

echo "orch.sh tests"

# --- init -------------------------------------------------------------------
echo
echo "init"
new_repo >/dev/null
out="$("$ORCH" init "My Feature!!")"
assert_eq "normalises slug to kebab-case" "$out" "my-feature"
assert_eq "state starts at the spec phase" "$("$ORCH" state get phase)" "spec"
assert_eq "iteration starts at zero" "$("$ORCH" state get iteration)" "0"
assert_eq "issue starts unset" "$("$ORCH" state get issue)" ""
assert_contains "excludes .orchestrator/ without touching .gitignore" \
  "$(cat .git/info/exclude)" ".orchestrator/"
assert_eq "leaves the working tree clean" "$(git status --porcelain)" ""

out="$("$ORCH" init other 2>&1)"; st=$?
assert_status "refuses a second concurrent flow" "$st" 1
assert_contains "explains how to clear the active flow" "$out" "abort"

out="$("$ORCH" init other --bogus 2>&1)"; st=$?
assert_status "rejects an unknown flag" "$st" 1
assert_contains "names the flag it rejected" "$out" "--bogus"

# --- init refuses a dirty working tree ----------------------------------------
# The git-based backstop from ADR-0013: a host with no mechanical trigger for
# the edit guard can still edit source during planning, so flow start is where
# those edits get caught. Only the planning allowlist may be dirty.
echo
echo "init refuses a dirty working tree"
flow_repo="$PWD"
new_repo >/dev/null
echo "code" >stray.sh
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses an untracked file outside the allowlist" "$st" 1
assert_contains "names the untracked path" "$out" "stray.sh"
assert_eq "writes no state when it refuses" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_contains "says how to resolve it" "$out" "Commit, stash, or discard"
assert_contains "says to retry" "$out" "run init again"
assert_contains "names what planning may change" "$out" "docs/adr/"

rm stray.sh
echo "changed" >>docs/agents/issue-tracker.md
echo "base" >src.sh; git add src.sh; git commit -qm src
echo "edit" >>src.sh
mkdir -p lib && echo "new" >lib/deep.sh
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses a tracked modification outside the allowlist" "$st" 1
assert_contains "names the modified path" "$out" "src.sh"
assert_contains "names an untracked file inside a new directory" "$out" "lib/deep.sh"
case "$out" in *issue-tracker.md*) bad "does not name allowlisted paths" "$out" ;;
  *) ok "does not name allowlisted paths" ;; esac

git checkout -q src.sh; rm -r lib
git mv src.sh moved.sh
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses a staged rename" "$st" 1
assert_contains "names the rename's new path" "$out" "moved.sh"
assert_contains "names the rename's old path" "$out" "src.sh"
git mv moved.sh src.sh

# A git status that cannot run is not a clean tree - reading it as one would
# wave through exactly the edits this check exists to catch.
cp .git/index .git/index.bak; echo garbage >.git/index
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses when git status fails" "$st" 1
assert_eq "writes no state when git status fails" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
mv .git/index.bak .git/index

mkdir -p docs/adr && echo "# ADR" >docs/adr/0001-x.md
echo "# glossary" >CONTEXT.md
mkdir -p .scratch && echo "ticket" >.scratch/t.md
mkdir -p sub
out="$(cd sub && "$ORCH" init clean-enough 2>&1)"; st=$?
assert_status "starts with only allowlisted changes, even from a subdirectory" "$st" 0
assert_eq "records the flow" "$("$ORCH" state get slug)" "clean-enough"
cd "$flow_repo" || exit 1

# --- slug -------------------------------------------------------------------
# The same normalisation init applies to its own slug argument, exposed as a
# primitive so the quick-implement skill can call it instead of restating the
# algorithm as prose.
echo
echo "slug"
assert_eq "matches init's own normalisation" "$("$ORCH" slug "My Feature!!")" "my-feature"
out="$("$ORCH" slug "!!!" 2>&1)"; st=$?
assert_status "refuses a slug empty after normalisation" "$st" 1
assert_contains "explains why" "$out" "empty after normalisation"
out="$("$ORCH" slug 2>&1)"; st=$?
assert_status "refuses no argument at all" "$st" 1

# --- state ------------------------------------------------------------------
echo
echo "state"
assert_eq "round-trips a string value" \
  "$("$ORCH" state set branch orch/1-x; "$ORCH" state get branch)" "orch/1-x"
"$ORCH" state set issue 42
assert_eq "coerces a numeric value to a number" "$("$ORCH" state get issue)" "42"
assert_eq "stores issue as JSON number, not string" \
  "$("$ORCH" state get | jq -r '.issue | type')" "number"
"$ORCH" state set issue null
assert_eq "accepts an explicit null" "$("$ORCH" state get | jq -r '.issue | type')" "null"

# --- handoff path -----------------------------------------------------------
echo
echo "handoff path"
assert_contains "spec phase reads the plan handoff"      "$("$ORCH" handoff path spec)"      "01-plan.md"
assert_contains "implement phase reads the spec handoff" "$("$ORCH" handoff path implement)" "02-spec.md"
assert_contains "review phase reads the implement handoff" "$("$ORCH" handoff path review)"  "03-implement.md"

# The review skill consumes this inside command substitutions - `dirname "$(...
# handoff path review)"` - so a phase it cannot resolve has to stop the caller
# rather than hand it the bare handoff directory with a zero status.
out="$("$ORCH" handoff path bogus 2>/dev/null)"; st=$?
assert_status "an unknown phase is an error, not a directory" "$st" 1
assert_eq "and prints no path for a caller to use" "$out" ""

# --- handoff validate -------------------------------------------------------
echo
echo "handoff validate"
h="$("$ORCH" handoff path spec)"
complete_plan_handoff "$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "passes a complete handoff" "$st" 0

writeln '## Decisions' 'Use X.' '' '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "fails when a required section is missing" "$st" 1
assert_contains "names the missing section" "$out" "Rejected alternatives"

# The high-value case: the section the spec writer is most likely to leave as a
# bare heading, which would let already-killed alternatives get re-proposed.
complete_plan_handoff "$h"
writeln '## Decisions' 'Use X.' '' '## Rejected alternatives' '' \
        '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "fails when a required section is present but empty" "$st" 1
assert_contains "reports it as empty, not missing" "$out" "empty section"

writeln '## Decisions' 'Use X.' '' '## Rejected alternatives' '   ' '' \
        '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "treats a whitespace-only section as empty" "$st" 1

# Every phase records the host capability fallbacks it used (#127,
# docs/host-capabilities.md), so a human reading any handoff can see where a
# host did less than Claude Code would have. "None." is an answer; no section
# is not.
for p in spec implement review; do
  hf="$("$ORCH" handoff path "$p")"
  case "$p" in
    spec) complete_plan_handoff "$hf" ;;
    implement) complete_spec_handoff "$hf" ;;
    review) complete_implement_handoff "$hf" ;;
  esac
  grep -v '^## Host fallbacks$' "$hf" | grep -v '^None (Claude Code)\.$' >"$hf.tmp" && mv "$hf.tmp" "$hf"
  out="$("$ORCH" handoff validate "$hf" 2>&1)"; st=$?
  assert_status "$(basename "$hf") without Host fallbacks is incomplete" "$st" 1
  assert_contains "$(basename "$hf") names the missing Host fallbacks" "$out" "Host fallbacks"
done
# A flow started before 1.0.0 has no host_fallbacks in state.json and wrote
# its handoffs without the section; upgrading mid-flow must not fail them.
st_saved="$(cat .orchestrator/state.json)"
jq 'del(.host_fallbacks)' <<<"$st_saved" >.orchestrator/state.json
out="$("$ORCH" handoff validate "$hf" 2>&1)"; st=$?
assert_status "a pre-1.0.0 flow's handoff validates without Host fallbacks" "$st" 0
printf '%s\n' "$st_saved" >.orchestrator/state.json
complete_plan_handoff "$h"

# --- ticket breakdown handoff ------------------------------------------------
# The spec phase's last step publishes tickets as sub-issues of the spec
# issue, so the handoff that follows it must at least name the parent -
# anything less sends implement's `ticket next` query against nothing.
echo
echo "ticket breakdown handoff"
h2="$("$ORCH" handoff path implement)"
writeln '## Spec issue' '#1.' '' '## Seams' 'The CLI.' '' \
        '## Spec review changelog' 'Not reviewed.' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "a spec handoff with no ticket breakdown is incomplete" "$st" 1
assert_contains "names the section implement would have read" "$out" "Ticket breakdown"

writeln '## Spec issue' '#1.' '' '## Seams' 'The CLI.' '' \
        '## Spec review changelog' 'Not reviewed.' '' \
        '## Ticket breakdown' '   ' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "a bare Ticket breakdown heading is no better than none" "$st" 1
assert_contains "reported as empty, not missing" "$out" "empty section"

complete_spec_handoff "$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "passes once the parent issue is recorded" "$st" 0

# A 0/1-ticket breakdown collapses (issue #99/#101): no sub-issue is published,
# so this section names the spec issue itself via a plain-text sentinel rather
# than a parent whose GitHub sub-issues carry the real tickets. It is covered
# today by the same generic non-empty-section check as any other content -
# named explicitly here so the convention doesn't silently rot.
writeln '## Spec issue' '#1.' '' '## Seams' 'The CLI.' '' \
        '## Spec review changelog' 'Not reviewed.' '' \
        '## Ticket breakdown' 'None: work directly against #1.' '' \
        '## Host fallbacks' 'None (Claude Code).' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "the collapsed-case sentinel validates like any other content" "$st" 0

# --- archive ----------------------------------------------------------------
echo
echo "archive"
complete_plan_handoff "$h"
dest="$("$ORCH" archive)"
assert_contains "archive path carries the slug" "$dest" "my-feature"
assert_eq "live state is cleared" "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "gone"
assert_eq "handoff is preserved under archive/" \
  "$([ -f "$dest/handoff/01-plan.md" ] && echo present || echo gone)" "present"
out="$("$ORCH" status 2>&1)"
assert_contains "status reports no active flow afterwards" "$out" "No active flow"
out="$("$ORCH" init second 2>&1)"; st=$?
assert_status "a new flow can start after archiving" "$st" 0

# --- default-branch ---------------------------------------------------------
# The base every feature branch forks from. Getting this wrong is silent: work
# lands on top of the wrong branch and nothing complains until review.
echo
echo "default-branch"
new_repo >/dev/null
STUB="$(mktemp -d)"
cat >"$STUB/gh" <<'GH'
#!/usr/bin/env bash
[ "${GH_STUB_FAIL:-0}" = "1" ] && exit 1
echo "trunk"
GH
chmod +x "$STUB/gh"

# origin/HEAD is a local pointer frozen at clone time; GitHub's answer must win.
git remote add origin https://example.invalid/x/y.git
git checkout -q -b some-feature
git update-ref refs/remotes/origin/some-feature HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/some-feature
assert_eq "prefers GitHub's answer over a stale origin/HEAD" \
  "$(PATH="$STUB:$PATH" "$ORCH" default-branch)" "trunk"
assert_eq "falls back to origin/HEAD when gh cannot answer" \
  "$(PATH="$STUB:$PATH" GH_STUB_FAIL=1 "$ORCH" default-branch)" "some-feature"
git symbolic-ref -d refs/remotes/origin/HEAD
assert_eq "falls back to main when nothing else answers" \
  "$(PATH="$STUB:$PATH" GH_STUB_FAIL=1 "$ORCH" default-branch)" "main"

# --- branch create -----------------------------------------------------------
# Unlike branch off's caller-named branch, this one derives its own name from
# state - slug plus the recorded issue - and records both `branch` and
# `base_sha` for pr open and redo review to read back later via require_branch.
echo
echo "branch create"
new_repo >/dev/null
git remote add origin https://example.invalid/x/y.git
git update-ref "refs/remotes/origin/$(git branch --show-current)" HEAD
git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$(git branch --show-current)"
"$ORCH" init bcreate >/dev/null
"$ORCH" state set issue 11
before_sha="$(git rev-parse HEAD)"
out="$("$ORCH" branch create)"
assert_eq "derives the branch name from slug and the recorded issue" "$out" "orch/11-bcreate"
assert_eq "checks the new branch out" "$(git branch --show-current)" "orch/11-bcreate"
assert_eq "records the branch in state" "$("$ORCH" state get branch)" "orch/11-bcreate"
assert_eq "records the fork point as base_sha" "$("$ORCH" state get base_sha)" "$before_sha"

# --- branch off --------------------------------------------------------------
# A quick implementation keeps no state, so this is the primitive it shares
# with a flow's own branch create: same fetch/checkout-fallback idiom, naming
# and recording left entirely to the caller.
echo
echo "branch off"
new_repo >/dev/null
# default-branch resolves through git symbolic-ref as a fallback, which this
# repo has none of yet - give it one rather than letting the answer depend on
# this machine's git init.defaultBranch.
git remote add origin https://example.invalid/x/y.git
git update-ref "refs/remotes/origin/$(git branch --show-current)" HEAD
git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$(git branch --show-current)"
out="$("$ORCH" branch off "quick/9-widgets")"
assert_eq "prints the branch it made" "$out" "quick/9-widgets"
assert_eq "checks it out" "$(git branch --show-current)" "quick/9-widgets"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"

out="$("$ORCH" branch off "quick/9-widgets" 2>&1)"; st=$?
assert_status "refuses a name that already exists" "$st" 1
assert_contains "names the branch" "$out" "quick/9-widgets already exists"

out="$("$ORCH" branch off 2>&1)"; st=$?
assert_status "refuses with no name" "$st" 1

# --- base --------------------------------------------------------------------
# The checkout-wide base branch setting and its one resolver. A typo here is
# silent in the worst way - work quietly forks from and targets a branch nobody
# will merge - so set must refuse anything origin does not have.
echo
echo "base"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
git remote add origin "$bare"
git push -q origin HEAD:refs/heads/main HEAD:refs/heads/uat
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
# GitHub cannot answer for a local bare origin, so default-branch settles on
# origin/HEAD - pinned above rather than left to this machine's gh.
base_cmd() { PATH="$STUB:$PATH" GH_STUB_FAIL=1 "$ORCH" "$@"; }
base_setting() { git config --get orchestrator.base || echo "<unset>"; }

out="$(base_cmd base show)"; st=$?
assert_status "show succeeds with nothing set" "$st" 0
assert_eq "show names the default branch as the source when nothing is set" "$out" "main (default)"

out="$(base_cmd base set nosuch 2>&1)"; st=$?
assert_status "set refuses a branch missing from origin" "$st" 1
assert_contains "names the missing branch" "$out" "nosuch"
assert_eq "a refused set leaves the config untouched" "$(base_setting)" "<unset>"

out="$(base_cmd base set uat 2>&1)"; st=$?
assert_status "set accepts a branch origin has" "$st" 0
assert_eq "set writes orchestrator.base" "$(base_setting)" "uat"
assert_eq "show names the setting as the source" "$(base_cmd base show)" "uat (set)"
assert_eq "default-branch still names the default branch" "$(base_cmd default-branch)" "main"

wt="$(mktemp -d)/wt"
git worktree add -q "$wt" -b base-wt
assert_eq "every worktree of the clone shares the setting" "$(cd "$wt" && base_cmd base show)" "uat (set)"
git worktree remove --force "$wt"

git remote set-url origin "$(dirname "$bare")/unreachable.git"
out="$(base_cmd base set main 2>&1)"; st=$?
assert_status "set refuses when origin cannot be reached to verify" "$st" 1
assert_eq "an unverified set leaves the config untouched" "$(base_setting)" "uat"
git remote set-url origin "$bare"

out="$(base_cmd base set main 2>&1)"; st=$?
assert_status "set accepts the default branch's own name" "$st" 0
assert_eq "setting the default branch acts as clearing" "$(base_setting)" "<unset>"
assert_eq "show then reports the default source" "$(base_cmd base show)" "main (default)"

base_cmd base set uat >/dev/null
out="$(base_cmd base clear 2>&1)"; st=$?
assert_status "clear succeeds when a setting exists" "$st" 0
assert_eq "clear removes the setting" "$(base_setting)" "<unset>"
out="$(base_cmd base clear 2>&1)"; st=$?
assert_status "clear succeeds when nothing was set" "$st" 0

out="$(base_cmd base 2>&1)"; st=$?
assert_status "refuses a missing verb" "$st" 1
out="$(base_cmd base set 2>&1)"; st=$?
assert_status "set refuses with no branch" "$st" 1
rm -rf "$(dirname "$bare")"

# --- a flow's base branch -------------------------------------------------------
# A flow fixes its base branch at init, so a later `base set` never moves the
# flow's fork point or its PR. uat carries a commit main does not, so where the
# flow branch forked from is visible in its history.
echo
echo "a flow's base branch"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
git remote add origin "$bare"
git push -q origin HEAD:refs/heads/main
git checkout -q -b uat
git commit -q --allow-empty -m "uat only"
git push -q origin uat:refs/heads/uat
git checkout -q -
git branch -q -D uat
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
uat_tip="$(git rev-parse origin/uat)"
main_tip="$(git rev-parse origin/main)"

base_cmd init nobase >/dev/null
assert_eq "init records the default branch as base when nothing is set" \
  "$(base_cmd state get base)" "main"
rm -rf .orchestrator

base_cmd base set uat >/dev/null
base_cmd init flowbase >/dev/null
assert_eq "init records the base branch setting" "$(base_cmd state get base)" "uat"

out="$(base_cmd base set uat 2>&1)"
assert_not_contains "set says nothing more when the active flow already has that base" \
  "$out" "keeps its own base branch"
out="$(base_cmd base set main 2>&1)"; st=$?
assert_status "set still succeeds while a flow with another base is active" "$st" 0
assert_contains "and notes that the active flow keeps its own base branch" \
  "$out" "flowbase keeps its own base branch: uat"
assert_eq "the flow's recorded base is untouched" "$(base_cmd state get base)" "uat"

base_cmd state set issue 7
out="$(base_cmd branch create 2>&1)"; st=$?
assert_status "branch create succeeds" "$st" 0
assert_eq "branch create forks from the recorded base, not the changed setting" \
  "$(git rev-parse HEAD)" "$uat_tip"
assert_eq "base_sha is the recorded base's tip" "$(base_cmd state get base_sha)" "$uat_tip"
assert_contains "status prints the flow's base branch" "$(base_cmd status)" "base:      uat"

body="$(mktemp)"
writeln 'Implements the thing.' >"$body"
filed="$(mktemp)"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" GH_STUB_PR_NUMBER=31 \
  base_cmd pr open "Title" "$body" 2>&1)"; st=$?
assert_status "pr open succeeds" "$st" 0
assert_contains "pr open targets the flow's recorded base" "$(cat "$filed")" "base=uat"
body_recorded="$(sed -n '/^body:$/,$p' "$filed" | tail -n +2)"
assert_first_line "a PR into a non-default base refers to its issue instead of closing it" \
  "$body_recorded" "Refs #7"

# A deleted base branch must not quietly become a fork from a stale local copy.
git update-ref refs/remotes/origin/gone "$main_tip"
git branch -q gone "$main_tip"
base_cmd state set base gone
base_cmd state set issue 8
out="$(base_cmd branch create 2>&1)"; st=$?
assert_status "branch create refuses a base branch origin says is gone" "$st" 1
assert_contains "naming the base branch" "$out" "gone"
assert_eq "and creates no branch" \
  "$(git rev-parse --verify --quiet orch/8-flowbase >/dev/null && echo made || echo none)" "none"

# A flow started before base was recorded forked from the default branch.
legacy="$(mktemp)"
jq 'del(.base)' .orchestrator/state.json >"$legacy"
mv "$legacy" .orchestrator/state.json
assert_contains "status shows the default branch for a state with no base" \
  "$(base_cmd status)" "base:      main"
git checkout -q main
out="$(base_cmd branch create 2>&1)"; st=$?
assert_status "and branch create still forks it" "$st" 0
assert_eq "from the default branch" "$(git rev-parse HEAD)" "$main_tip"
base_cmd base clear >/dev/null
rm -rf "$(dirname "$bare")"

# --- branch retire ------------------------------------------------------------
# The rename-aside a redo uses instead of deleting or force-pushing over a
# discarded attempt's commits. The push/delete-remote-ref assertions reuse the
# bare-repo-as-origin fixture branch create and pr open already use.
echo
echo "branch retire"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
git remote add origin "$bare"
git push -q origin HEAD:refs/heads/main

out="$("$ORCH" branch retire nosuchbranch new 2>&1)"; st=$?
assert_status "refuses a branch that does not exist" "$st" 1
assert_contains "naming it" "$out" "nosuchbranch does not exist"

git branch old-attempt
git branch taken
out="$("$ORCH" branch retire old-attempt taken 2>&1)"; st=$?
assert_status "refuses a destination name already in use" "$st" 1
assert_contains "naming it" "$out" "taken already exists"
git branch -d taken

out="$("$ORCH" branch retire old-attempt old-attempt-redo-1 2>&1)"; st=$?
assert_status "renames a branch with no upstream" "$st" 0
assert_eq "prints the new name" "$out" "old-attempt-redo-1"
assert_eq "the old name is gone locally" \
  "$(git rev-parse --verify --quiet old-attempt >/dev/null 2>&1 && echo present || echo gone)" "gone"
assert_eq "the new name exists" \
  "$(git rev-parse --verify --quiet old-attempt-redo-1 >/dev/null 2>&1 && echo present || echo gone)" "present"

git checkout -q -b to-retire
git push -q -u origin to-retire
out="$("$ORCH" branch retire to-retire to-retire-redo-1 2>&1)"; st=$?
assert_status "renames and republishes a branch with an upstream" "$st" 0
assert_eq "prints the new name" "$out" "to-retire-redo-1"
assert_eq "pushes the new name to origin" \
  "$(git -C "$bare" rev-parse --quiet --verify refs/heads/to-retire-redo-1 >/dev/null && echo present || echo gone)" "present"
# Not optional: a leftover ref under the un-suffixed name is exactly what the
# next implement attempt's branch create/pr open would collide with.
assert_eq "and deletes the old remote ref" \
  "$(git -C "$bare" rev-parse --quiet --verify refs/heads/to-retire >/dev/null && echo present || echo gone)" "gone"

# The fixture gap named in spec review: no test in the suite forces a real
# `git push` to fail, since the gh-stub exit overrides only apply to gh.
# Pointing origin at a path removed out from under it does.
git checkout -q -b to-fail
git push -q -u origin to-fail
rm -rf "$bare"
out="$("$ORCH" branch retire to-fail to-fail-redo-1 2>&1)"; st=$?
assert_status "dies when the push to origin fails" "$st" 1
assert_contains "with a clear reason" "$out" "could not push"
# The local rename happens before the push is even attempted - issue #63:
# without a rollback, a push failure leaves `old` gone locally with nothing
# a retry could find, even though nothing was ever published.
assert_eq "rolls the local rename back so the old name still exists" \
  "$(git rev-parse --verify --quiet to-fail >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and the new name is not left dangling in its place" \
  "$(git rev-parse --verify --quiet to-fail-redo-1 >/dev/null 2>&1 && echo present || echo gone)" "gone"

# Retrying with the same old/new names must succeed once whatever blocked
# the push clears - issue #63 acceptance criterion 1.
bare2="$(mktemp -d)/origin.git"
git init -q --bare "$bare2"
git remote set-url origin "$bare2"
out="$("$ORCH" branch retire to-fail to-fail-redo-1 2>&1)"; st=$?
assert_status "retrying the same rename succeeds once origin is reachable again" "$st" 0
assert_eq "prints the new name" "$out" "to-fail-redo-1"
assert_eq "renames locally" \
  "$(git rev-parse --verify --quiet to-fail-redo-1 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and publishes it" \
  "$(git -C "$bare2" rev-parse --quiet --verify refs/heads/to-fail-redo-1 >/dev/null && echo present || echo gone)" "present"

# Idempotent resume: a previous call whose local rename and remote push both
# already succeeded, but whose remote delete of the old ref did not - the
# "Key interfaces" note in issue #63, that retire must resume rather than
# fail on "$old does not exist" when $old really is gone locally already.
bare3="$(mktemp -d)/origin.git"
git init -q --bare "$bare3"
git remote set-url origin "$bare3"
git checkout -q -b to-resume
git push -q -u origin to-resume
git branch -m to-resume to-resume-redo-1
git push -q -u origin to-resume-redo-1
# The old ref is deliberately left on origin, standing in for the failed
# delete a real partial failure would leave behind.
out="$("$ORCH" branch retire to-resume to-resume-redo-1 2>&1)"; st=$?
assert_status "resumes rather than failing on the already-gone old name" "$st" 0
assert_eq "prints the new name" "$out" "to-resume-redo-1"
assert_eq "and finishes the delete the earlier attempt left undone" \
  "$(git -C "$bare3" rev-parse --quiet --verify refs/heads/to-resume >/dev/null && echo present || echo gone)" "gone"

# A genuine remote failure on that same delete step still has to die, not
# get swallowed by the resume path's tolerance for an already-gone ref.
bare4="$(mktemp -d)/origin.git"
git init -q --bare "$bare4"
git -C "$bare4" symbolic-ref HEAD refs/heads/to-protect
git -C "$bare4" config receive.denyDeleteCurrentBranch refuse
git remote set-url origin "$bare4"
git checkout -q -b to-protect
git push -q -u origin to-protect
out="$("$ORCH" branch retire to-protect to-protect-redo-1 2>&1)"; st=$?
assert_status "dies when the old ref genuinely cannot be deleted" "$st" 1
assert_contains "with a clear reason" "$out" "could not delete origin/to-protect"

out="$("$ORCH" branch retire 2>&1)"; st=$?
assert_status "refuses with the wrong number of arguments" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh branch retire"

# --- branch: unknown op -------------------------------------------------------
out="$("$ORCH" branch bogus 2>&1)"; st=$?
assert_status "branch bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown branch op"
assert_contains "naming all three" "$out" "create|off|retire"

# --- issue publish ------------------------------------------------------------
# The publishing boundary a quick implementation calls instead of hardcoding
# `gh issue create` in skill prose - stateless like branch off, since a quick
# implementation has no flow to record into.
#
# Creation goes through the ORCH_GH_ADAPTER seam here, pointed at the
# in-memory fake rather than stub_gh - GH_STUB_LOG stays empty, proving it
# never spawns a real gh subprocess. The subprocess-real counterpart is the
# "gh adapter (real issue create, subprocess gh)" block right after this one.
echo
echo "issue publish"
healthy_repo
filed="$(mktemp)"
body="$(mktemp)"
writeln 'The shared understanding, written up.' >"$body"
log="$(mktemp)"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" GH_STUB_LOG="$log" GH_STUB_ISSUE_NUMBER=7 \
  "$ORCH" issue publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "publishes" "$st" 0
assert_eq "printing the issue number and nothing else" "$out" "7"
assert_contains "passes the title through" "$(cat "$filed")" "title=Widgets need a handle"
assert_contains "and sends the body file's contents" "$(cat "$filed")" "The shared understanding, written up."
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the create call never reached a real gh subprocess" "$(grep -cx issue "$log")" "0"

out="$("$ORCH" issue publish "" "$body" 2>&1)"; st=$?
assert_status "refuses an empty title" "$st" 1

out="$("$ORCH" issue publish "Title" /nonexistent/body.md 2>&1)"; st=$?
assert_status "refuses a body file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"

out="$("$ORCH" issue publish "Title" 2>&1)"; st=$?
assert_status "refuses with no body file" "$st" 1

out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_ISSUE_EXIT=1 "$ORCH" issue publish "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not create the issue fails the command" "$st" 1
assert_eq "with no number printed for a record to cite" \
  "$(printf '%s\n' "$out" | grep -cx '[0-9][0-9]*')" "0"

# --- mp-skill ---------------------------------------------------------------
# Resolved by glob at runtime, never by pinned version: the version in the cache
# path changes underneath us.
echo
echo "mp-skill"
if "$ORCH" mp-skill >/dev/null 2>&1; then
  assert_contains "resolves to-spec across category dirs" "$("$ORCH" mp-skill to-spec)" "/to-spec/SKILL.md"
  assert_contains "resolves handoff from another category" "$("$ORCH" mp-skill handoff)" "/handoff/SKILL.md"
  out="$("$ORCH" mp-skill definitely-not-a-skill 2>&1)"; st=$?
  assert_status "rejects an unknown skill name" "$st" 1
  assert_contains "names what it could not find" "$out" "definitely-not-a-skill"
else
  echo "  skip (mattpocock-skills not installed)"
fi

# --- mp-skill across host layouts -------------------------------------------
# Each supported host installs mattpocock-skills somewhere else, in another
# shape. The lookup is per skill name, because the skills CLI store has no
# plugin root to hand back - only a directory shared with every other skill.
echo
echo "mp-skill across host layouts"
for layout in claude junie agents; do
  h="$(mktemp -d)"; mp_install "$layout" "$h" to-spec handoff
  out="$(HOME="$h" "$ORCH" mp-skill to-spec 2>&1)"; st=$?
  assert_status "resolves from the $layout layout" "$st" 0
  assert_eq "hands back the $layout layout's SKILL.md" "$(head -1 "$out" 2>/dev/null)" "# to-spec ($layout)"
  assert_contains "says where the $layout layout's skills were found" \
    "$(HOME="$h" "$ORCH" mp-skill 2>&1)" "$h/"
done

h="$(mktemp -d)"; mp_install override "$h" to-spec
out="$(HOME="$h" ORCHESTRATOR_MATTPOCOCK_ROOT="$h/mp-checkout" "$ORCH" mp-skill to-spec 2>&1)"; st=$?
assert_status "resolves from the override" "$st" 0
assert_eq "hands back the override's SKILL.md" "$(head -1 "$out" 2>/dev/null)" "# to-spec (override)"
assert_eq "says the override is where the skills were found" \
  "$(HOME="$h" ORCHESTRATOR_MATTPOCOCK_ROOT="$h/mp-checkout" "$ORCH" mp-skill 2>&1)" "$h/mp-checkout"

# Every layout at once: each one removed in turn exposes the next in line.
h="$(mktemp -d)"
for layout in override claude junie agents; do mp_install "$layout" "$h" to-spec; done
first() { head -1 "$(HOME="$h" "$@" "$ORCH" mp-skill to-spec 2>/dev/null)" 2>/dev/null; }
assert_eq "the override outranks every install" \
  "$(first env ORCHESTRATOR_MATTPOCOCK_ROOT="$h/mp-checkout")" "# to-spec (override)"
assert_eq "Claude's cache outranks Junie's and the skills CLI's" "$(first env)" "# to-spec (claude)"
rm -rf "$h/.claude"
assert_eq "Junie's extension cache outranks the skills CLI's" "$(first env)" "# to-spec (junie)"
rm -rf "$h/.junie"
assert_eq "the skills CLI store is the last resort" "$(first env)" "# to-spec (agents)"

# ~/.agents/skills is shared by every skill the CLI installed. A same-named
# skill that the lockfile does not record as mattpocock-skills' is someone
# else's, and running it in place of mattpocock's would be the worst outcome.
h="$(mktemp -d)"
mp_install agents "$h" to-spec
mp_install agents-foreign "$h" handoff
out="$(HOME="$h" "$ORCH" mp-skill handoff 2>&1)"; st=$?
assert_status "ignores a same-named skill the lockfile gives to another plugin" "$st" 1
mkdir -p "$h/.agents/skills/code-review"; echo "# stray" >"$h/.agents/skills/code-review/SKILL.md"
out="$(HOME="$h" "$ORCH" mp-skill code-review 2>&1)"; st=$?
assert_status "ignores a skill the lockfile does not record at all" "$st" 1

# Only user-level locations count: a repo can ship .agents/skills of its own.
h="$(mktemp -d)"; mp_install agents "$h" to-spec
d="$(mktemp -d)"; mkdir -p "$d/.agents/skills/handoff"; echo "# project" >"$d/.agents/skills/handoff/SKILL.md"
out="$(cd "$d" && HOME="$h" "$ORCH" mp-skill handoff 2>&1)"; st=$?
assert_status "ignores a project-level .agents/skills" "$st" 1

out="$(HOME="$(mktemp -d)" "$ORCH" mp-skill to-spec 2>&1)"; st=$?
assert_status "fails when no layout holds mattpocock-skills" "$st" 1

# --- init --issue -------------------------------------------------------
# Adoption is validated once, immediately, before state.json is written - a bad
# issue number must cost nothing, the same promise branch create and pr open
# already make about their own preconditions.
echo
echo "init --issue"
healthy_repo
out="$("$ORCH" init adopted --issue 42)"
assert_eq "adopts an open, labelled issue" "$out" "adopted"
assert_eq "issue is recorded as a number" "$("$ORCH" state get | jq -r '.issue | type')" "number"
assert_eq "issue value matches the adopted number" "$("$ORCH" state get issue)" "42"

healthy_repo
out="$(GH_STUB_VIEW_EXIT=1 "$ORCH" init nope --issue 99 2>&1)"; st=$?
assert_status "refuses to adopt an issue gh cannot read" "$st" 1
assert_contains "names the issue number" "$out" "99"
assert_eq "no flow is left active after a failed adoption" \
  "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "gone"

healthy_repo
out="$(GH_STUB_ISSUE_STATE=CLOSED "$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "refuses to adopt a closed issue" "$st" 1
assert_contains "says the issue is not open" "$out" "not open"

healthy_repo
out="$(GH_STUB_ISSUE_LABELS=needs-triage "$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "refuses to adopt an issue missing the triage label" "$st" 1
assert_contains "names the missing label" "$out" "ready-for-agent"

# validate_adopted_issue's state and labels come off the same issue, so one
# combined `gh issue view` answers both rather than spending a second
# round-trip on a resource already in hand.
healthy_repo
filed="$(mktemp)"
out="$(GH_STUB_FILED="$filed" "$ORCH" init combined --issue 42)"; st=$?
assert_status "adopts via a single combined gh issue view call" "$st" 0
assert_eq "exactly one issue view call, not two" "$(grep -c '^issue view' "$filed")" "1"
assert_contains "the one call asks for both state and labels together" \
  "$(cat "$filed")" "state,labels"

healthy_repo
out="$("$ORCH" init nope --issue 2>&1)"; st=$?
assert_status "requires a value after --issue" "$st" 1

healthy_repo
out="$("$ORCH" init nope --issue https://github.com/acme/widgets/issues/42 2>&1)"; st=$?
assert_status "refuses a non-numeric --issue value" "$st" 1
assert_contains "says --issue wants a plain number" "$out" "--issue"
assert_eq "no flow is left active after a malformed --issue" \
  "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "gone"

healthy_repo
out="$("$ORCH" init 2>&1)"; st=$?
assert_status "adoption does not change that a slug is still required" "$st" 1

# --- init archives a done flow -----------------------------------------------
# issue #13: a "done" flow already succeeded - nothing downstream reads its
# handoffs - so starting over it is normal pipeline cleanup, not something
# init should still refuse as "active".
echo
echo "init archives a done flow"
healthy_repo
"$ORCH" init first >/dev/null
complete_plan_handoff "$("$ORCH" handoff path spec)"
"$ORCH" state set phase done
out="$("$ORCH" init second)"; st=$?
assert_status "starting over a done flow succeeds" "$st" 0
archived="$(printf '%s\n' "$out" | sed -n '1p')"
assert_contains "prints the archive path first, carrying the old slug" "$archived" "first"
assert_eq "the new slug is the final line" "$(printf '%s\n' "$out" | tail -1)" "second"
assert_eq "exactly two lines - the archive path, then the slug" \
  "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"
assert_eq "the old flow's state is archived under .orchestrator/archive/" \
  "$([ -f "$archived/state.json" ] && echo present || echo gone)" "present"
assert_eq "the archived state still carries the old slug" \
  "$(jq -r .slug "$archived/state.json")" "first"
assert_eq "the new flow's state reflects the new slug" "$("$ORCH" state get slug)" "second"
assert_eq "the new flow starts at the spec phase, not done" "$("$ORCH" state get phase)" "spec"

healthy_repo
out="$("$ORCH" init nothing-to-archive)"
assert_eq "with no prior flow, stdout is still just the slug" "$out" "nothing-to-archive"

healthy_repo
"$ORCH" init stale >/dev/null
"$ORCH" state set phase implement
out="$("$ORCH" init other 2>&1)"; st=$?
assert_status "an implement-phase flow still refuses, same as spec" "$st" 1
assert_contains "names the phase" "$out" "phase: implement"
assert_contains "same message, unchanged" "$out" "One flow at a time"

healthy_repo
"$ORCH" init willfail >/dev/null
"$ORCH" state set phase done
out="$(GH_STUB_VIEW_EXIT=1 "$ORCH" init nope --issue 99 2>&1)"; st=$?
assert_status "a bad --issue adoption over a done flow refuses" "$st" 1
assert_contains "names the issue number" "$out" "99"
assert_eq "the done flow is left untouched, not archived" \
  "$("$ORCH" state get slug)" "willfail"
assert_eq "and still reports done, re-runnable" "$("$ORCH" state get phase)" "done"

# A good --issue adoption over a done flow is the counterpart to the bad one
# just above: validation still runs first, but this time it passes, so the
# done flow must be archived exactly as the no-`--issue` case archives it,
# and the new flow's state must carry the newly adopted issue rather than
# null or the old flow's own issue.
healthy_repo
"$ORCH" init willsucceed --issue 7 >/dev/null
"$ORCH" state set phase done
out="$("$ORCH" init second --issue 42)"; st=$?
assert_status "a valid --issue adoption over a done flow succeeds" "$st" 0
archived="$(printf '%s\n' "$out" | sed -n '1p')"
assert_contains "prints the archive path first, carrying the old slug" "$archived" "willsucceed"
assert_eq "the new slug is the final line" "$(printf '%s\n' "$out" | tail -1)" "second"
assert_eq "exactly two lines - the archive path, then the slug" \
  "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"
assert_eq "the old flow's state is archived under .orchestrator/archive/" \
  "$([ -f "$archived/state.json" ] && echo present || echo gone)" "present"
assert_eq "the archived state still carries the old slug" \
  "$(jq -r .slug "$archived/state.json")" "willsucceed"
assert_eq "the new flow's state records the newly adopted issue, not the old one" \
  "$("$ORCH" state get issue)" "42"

# --- doctor -----------------------------------------------------------------
# The two commands doctor replaces both returned success on the failures that
# actually end flows, so what these assert is the *severity* of each condition,
# not just that it got a mention.
echo
echo "doctor"
healthy_repo

# path_without_jq() builds its restricted PATH from whatever's really on PATH,
# not from repo state, so the same one built here serves every no-jq
# assertion below (in this section and in doctor --flow) instead of
# symlinking the same ~20 tools afresh at each call site.
nojq_path=""
on_windows_bash || nojq_path="$(path_without_jq)"

out="$("$ORCH" doctor --nonsense 2>&1)"; st=$?
assert_status "rejects an unknown flag" "$st" 1
assert_contains "names the flag it rejected" "$out" "--nonsense"

out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "passes a healthy repo" "$st" 0
assert_contains "keeps the ok-line format of the commands it replaces" "$out" "ok    git present"
assert_contains "opens with a bare group header" "$out" "tools"
assert_contains "summarises severities on the last line" \
  "$(printf '%s\n' "$out" | tail -1)" "0 FAIL"

# jq gone is the awkward case: every other part of orch.sh needs it, so the one
# message the user needs most is the one that cannot be printed the usual way.
if on_windows_bash; then
  skip_no_jq "fails when jq is missing"
  skip_no_jq "names jq rather than dying mid-report"
  skip_no_jq "still reaches the summary line without jq"
else
  out="$(PATH="$nojq_path" "$ORCH" doctor --env 2>&1)"; st=$?
  assert_status "fails when jq is missing" "$st" 1
  assert_contains "names jq rather than dying mid-report" "$out" "jq"
  assert_contains "still reaches the summary line without jq" "$out" " FAIL"
fi

# Severity is the behaviour under test, not the wording: "GitHub said no" must
# FAIL and "GitHub could not tell us" must only warn. Written backwards, doctor
# either blocks every flow run away from a good network or waves through the two
# failures it exists to catch, and both look plausible in a passing test suite.
# No healthy_repo() here: nothing above this point wrote to the repo (doctor
# itself never mutates, and the jq-missing checks only scoped PATH to a
# subshell), so the fixture from the top of the section is still clean.
out="$(GH_STUB_MODE=nolabels "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when a documented label is missing from the repo" "$st" 1
assert_contains "names the missing label with its backticks stripped" "$out" "ready-for-agent"
assert_contains "gives the command that creates it" "$out" 'gh label create "ready-for-agent"'
assert_contains "indents the remedy under its FAIL by six spaces" \
  "$out" "$(printf '\n      gh label create')"
assert_eq "strips the backticks the doc writes labels in" \
  "$(printf '%s\n' "$out" | grep -c '`')" "0"
assert_contains "counts one FAIL and no warns" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 1 FAIL"

# Still the fixture from the top of the section - nothing since has written
# anything besides the labels doc this call is about to overwrite anyway.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning |' \
        '| -------------------------- | -------------------- | ------- |' \
        '| `needs-triage`             | `needs triage`       | Look    |' >docs/agents/triage-labels.md
out="$(GH_STUB_LABELS='needs triage' "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a label with a space in it is one label, not two" "$st" 0
out="$(GH_STUB_MODE=nolabels "$ORCH" doctor --env 2>&1)"
assert_contains "quotes a multi-word label in the remedy" "$out" 'gh label create "needs triage"'

# GitHub answered the auth probe and then would not answer this one: an absent
# answer, not a "no", so it warns.
healthy_repo
out="$(GH_STUB_MODE=labelfail "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unlistable label set does not block the flow" "$st" 0
assert_contains "says the labels could not be listed" "$out" "could not be listed"

# The labelfail check above only scoped GH_STUB_MODE to its own command, so
# the repo the healthy_repo() call before it built is still clean here.
out="$(GH_STUB_MODE=offline "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "does not fail merely because GitHub is unreachable" "$st" 0
assert_contains "collapses the checks that needed GitHub into one line" \
  "$out" "checks skipped: GitHub is not reachable"
assert_eq "emits one skip line, not one per skipped check" \
  "$(printf '%s\n' "$out" | grep -c 'skipped:')" "1"
# The skip lines are a group like any other, so they carry a header and a blank
# line rather than trailing loose off the end of the last one.
assert_contains "puts the skipped group under a bare header" \
  "$out" "$(printf '\n\nskipped\nwarn  ')"

out="$(GH_STUB_MODE=noauth "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when gh is not authenticated" "$st" 1
assert_contains "gives the login command" "$out" "gh auth login"
assert_contains "skips the checks that depended on the answer" "$out" "skipped: not authenticated"

out="$(GH_STUB_REPO='acme/widgets ' "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unresolved default branch does not block the flow" "$st" 0
assert_contains "warns that the default branch came from a fallback" "$out" "default branch"

# A partial install is the regression this feature exists to catch: a lookup
# that probes one skill file passes, and the spec phase then dies with the
# context that could have fixed it already cleared.
# No healthy_repo() needed: the offline/noauth/default-branch checks above
# only ever scoped GH_STUB_* to their own command, so the repo is still clean
# going into this one - it's the HOME reassignment right below that dirties it.
HOME="$(stub_mattpocock implement code-review)"; export HOME
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails on a partial mattpocock-skills install" "$st" 1
assert_contains "names one missing skill" "$out" "to-spec"
assert_contains "names the other missing skill" "$out" "handoff"
assert_eq "says nothing about the skills that are present" \
  "$(printf '%s\n' "$out" | grep -c 'code-review')" "0"

out="$(HOME=/nonexistent "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails cleanly when mattpocock-skills is absent" "$st" 1
assert_contains "gives the install command" "$out" "/plugin install mattpocock-skills"
assert_contains "skips the per-skill check rather than deriving a second FAIL" \
  "$out" "1 skill check skipped"

# The fix has to fit the host: a Junie user told to run a Claude /plugin
# command is left exactly as stuck as before. With no host detected, every
# host's method is listed.
out="$(env -u CLAUDE_PLUGIN_ROOT HOME=/nonexistent "$ORCH" doctor --env 2>&1)"
assert_contains "names the Junie install method too" "$out" "Junie"
assert_contains "names the skills CLI install" "$out" "npx skills add mattpocock/skills"
assert_contains "names the override for an install none of these describe" \
  "$out" "ORCHESTRATOR_MATTPOCOCK_ROOT"

# Once the host is known, the fix names only that host's install method.
out="$(HOME=/nonexistent ORCHESTRATOR_HOST=junie "$ORCH" doctor --env 2>&1)"
assert_contains "on Junie, names the Junie install" "$out" "npx skills add mattpocock/skills"
# Neither Junie install is verified end to end, so the line says so (#121).
assert_contains "marks the Junie install unverified" "$out" "(both unverified)"
assert_not_contains "on Junie, does not name a Claude /plugin command" "$out" "/plugin install mattpocock-skills"
out="$(HOME=/nonexistent CLAUDECODE=1 "$ORCH" doctor --env 2>&1)"
assert_contains "on Claude Code, names the /plugin install" "$out" "/plugin install mattpocock-skills"
assert_not_contains "on Claude Code, does not name the Junie install" "$out" "npx skills add"

# The same partial install, in every other layout a host can produce. The
# lookup finding *a* location is not the same as it holding every skill.
for layout in junie agents override; do
  h="$(mktemp -d)"; mp_install "$layout" "$h" implement code-review
  ov=""; if [ "$layout" = override ]; then ov="$h/mp-checkout"; fi
  out="$(HOME="$h" ORCHESTRATOR_MATTPOCOCK_ROOT="$ov" "$ORCH" doctor --env 2>&1)"; st=$?
  assert_status "fails on a partial install in the $layout layout" "$st" 1
  assert_contains "names the $layout layout's missing to-spec" "$out" "missing: to-spec"
  assert_contains "names the $layout layout's missing handoff" "$out" "handoff"
done

# A skill the lockfile gives to another plugin is missing, not present.
h="$(mktemp -d)"; mp_install agents "$h" to-spec implement code-review
mp_install agents-foreign "$h" handoff
out="$(HOME="$h" "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when a skills CLI skill belongs to another plugin" "$st" 1
assert_contains "names the foreign skill as missing" "$out" "missing: handoff"

# Doctor says where the skills were found, in terms of the host that put them
# there - the path alone does not tell a user which install to repair.
h="$(mktemp -d)"
for layout in claude junie agents; do mp_install "$layout" "$h" to-spec implement code-review handoff; done
out="$(HOME="$h" "$ORCH" doctor --env 2>&1)"
assert_contains "reports Claude's plugin cache as the source" "$out" "(Claude Code plugin cache)"
rm -rf "$h/.claude"
out="$(HOME="$h" "$ORCH" doctor --env 2>&1)"
assert_contains "reports Junie's extension cache as the source" "$out" "(Junie extension cache)"
rm -rf "$h/.junie"
out="$(HOME="$h" "$ORCH" doctor --env 2>&1)"
assert_contains "reports the skills CLI store as the source" "$out" "(skills CLI)"
assert_contains "and where that store is" "$out" "mattpocock-skills: ~/.agents/skills"
mp_install override "$h" to-spec implement code-review handoff
out="$(HOME="$h" ORCHESTRATOR_MATTPOCOCK_ROOT="$h/mp-checkout" "$ORCH" doctor --env 2>&1)"
assert_contains "reports the override as the source" "$out" "(ORCHESTRATOR_MATTPOCOCK_ROOT)"

# An override that points nowhere is a typo to report, not a cue to fall back
# to some other install the user evidently did not want.
out="$(HOME="$h" ORCHESTRATOR_MATTPOCOCK_ROOT="$h/nope" "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when the override is not a directory" "$st" 1
assert_contains "names the override that points nowhere" "$out" "ORCHESTRATOR_MATTPOCOCK_ROOT"
assert_contains "and the path it points at" "$out" "/nope"

# Labels are parsed from the doc rather than hardcoded, so the parser is what
# decides whether doctor is right in a repo that customised its vocabulary.
# A narrower table would hand $3 whatever column sits last, so doctor would go
# demanding that the repo create labels named after the Meaning text. Parsing to
# nothing is the honest answer; inventing one is the worst thing a diagnostic
# can do.
# The width belongs to one table, and a doc may hold more than one. A second,
# narrower table's *header* row arrives a line before the separator that would
# correct the width, so without a reset at the end of the block that heading
# gets read out as a label and demanded of the repo.
# This healthy_repo() does earn its keep: the partial-install check above left
# HOME pointed at a mattpocock-skills stub missing two skills, and every
# labels-doc variant below needs the full install so the only FAIL it can
# produce is the one the table shape under test is supposed to cause.
healthy_repo
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
        '' '## Glossary' '' \
        '| Term | Definition |' \
        '| ---- | ---------- |' \
        '| flow | a run       |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "reads only the labels table, not every table in the doc" \
  "$out" "1 triage labels"
assert_eq "does not read a heading out of a second, narrower table" \
  "$(printf '%s\n' "$out" | grep -c 'Definition')" "0"
assert_status "and does not demand the repo create it" "$st" 0

# The width comes from the separator row, because only there is an empty last
# field unambiguous. On a data row it is equally an empty last *cell*, and a row
# that drops its trailing pipe *and* leaves Meaning blank looks exactly like a
# two-column row - so reading the width off that row costs a real label.
# No healthy_repo() here or in the labels-doc variants below: each one only
# ever dirtied the labels doc, and the writeln right after overwrites it
# again before anything reads it, so re-running the whole fixture just to
# replace one file it's about to replace anyway would be pure waste.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning' \
        '| -------------------------- | -------------------- | -------' \
        '| `needs-triage`             | `needs-triage`       |' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an empty last cell does not cost the row its label" "$st" 0
assert_contains "reads both labels, not just the one with a Meaning" "$out" "2 triage labels"

# Markdown lets a row drop its trailing pipe, and the width is read off the
# separator row precisely so that such a doc still parses.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning' \
        '| -------------------------- | -------------------- | -------' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a table without its trailing pipes still parses" "$st" 0
assert_contains "reads both labels out of it" "$out" "2 triage labels"

writeln '# Triage Labels' '' \
        '| Label          | Meaning     |' \
        '| -------------- | ----------- |' \
        '| `needs-triage` | Evaluate it |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails on a table that is not the documented shape" "$st" 1
assert_eq "does not read a label out of some other column" \
  "$(printf '%s\n' "$out" | grep -c 'Evaluate it')" "0"
assert_contains "points at the setup skill instead" "$out" "setup-matt-pocock-skills"

# The width rule now hinges entirely on recognising the separator row, and these
# are the two ways that recognition goes wrong: a separator dressed with
# alignment colons, and a doc that never has one.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| :------------------------- | :------------------: | ----------: |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready   |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an alignment-colon separator is still a separator" "$st" 0
assert_contains "reads the labels under it" "$out" "2 triage labels"

writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a table with no separator row parses to nothing" "$st" 1
assert_eq "reads no label out of a table it never confirmed the width of" \
  "$(printf '%s\n' "$out" | grep -c 'needs-triage')" "0"
assert_contains "points at the setup skill" "$out" "setup-matt-pocock-skills"

writeln '# Triage Labels' '' 'This repo does not use a table.' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when the labels doc parses to no labels" "$st" 1
assert_contains "points at the setup skill" "$out" "setup-matt-pocock-skills"

rm docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when the labels doc is absent entirely" "$st" 1
assert_contains "says the doc is missing rather than that it lists nothing" \
  "$out" "triage-labels.md is missing"

# A label list long enough to fill the page is a list that may be cut off, so
# naming labels as missing from it would be a FAIL derived from not knowing.
# This healthy_repo() is load-bearing: the doc was just deleted above, and
# every check from here through the exclude-line one below needs the default
# labels doc back, with nothing else in between rewriting it.
healthy_repo
out="$(GH_STUB_LABELS="$(seq 1 1000)" "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a label list that filled the page does not FAIL" "$st" 0
assert_contains "names the labels it cannot vouch for" "$out" "cannot confirm:"
assert_contains "names them individually" "$out" "needs-triage, ready-for-agent"

# ...but a page that filled up and still held every documented label answered
# the question. The caveat qualifies a negative; there is no negative here.
# GH_STUB_LABELS above was command-scoped, so the repo is still the one
# healthy_repo() built two checks up.
out="$(GH_STUB_LABELS="$(printf '%s\n' needs-triage ready-for-agent; seq 1 1000)" \
  "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a full page that held every label is still a pass" "$st" 0
assert_contains "does not hedge an answer it actually has" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 0 FAIL"

out="$("$ORCH" doctor --env 2>&1)"
assert_contains "counts only the documented labels, not the header row" \
  "$out" "2 triage labels"

# Escaped pipes (issue #5): markdown's `\|` inside a cell is a literal `|`,
# never a column separator. Without that, an escaped cell shifts every column
# after it for that row - the label column reads a fragment of the escaped
# cell instead of the real label, and the real label is lost entirely.
# GH_STUB_MODE=nolabels makes every documented label print a "gh label
# create" remedy, which is the easiest window onto exactly what triage_labels
# parsed each row down to.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `needs\|triage`       | Evaluate it |' >docs/agents/triage-labels.md
out="$(GH_STUB_MODE=nolabels "$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "an escaped pipe inside the label column becomes a literal pipe" \
  "$out" 'gh label create "needs|triage"'
assert_eq "does not truncate the label at the escaped pipe" \
  "$(printf '%s\n' "$out" | grep -c 'gh label create "needs"')" "0"

# The ticket's own repro: the escape sits in the *other* column (the
# mattpocock-skills name), yet it is column 3 - the label doctor actually
# reads - that comes out corrupted, because the escaped cell shifted it.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `a\|b`                     | `needs-triage`        | do it       |' >docs/agents/triage-labels.md
out="$(GH_STUB_MODE=nolabels "$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "an escaped pipe in the mattpocock-name column does not shift the label column" \
  "$out" 'gh label create "needs-triage"'
assert_eq "does not invent a label out of the shifted fragment" \
  "$(printf '%s\n' "$out" | grep -c 'gh label create "b"')" "0"

# The Meaning column sits after the one doctor reads, so an escape there is
# the least likely to leak - which is exactly why it earns a test locking
# that in, rather than trusting it stays that way by accident.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `needs-triage`        | Look \|out  |' >docs/agents/triage-labels.md
out="$(GH_STUB_MODE=nolabels "$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "an escaped pipe in the meaning column does not corrupt the label column" \
  "$out" 'gh label create "needs-triage"'

# triage_label_for shares the same row-splitting bug: an escape in the
# repo's local label corrupts the very value validate_adopted_issue compares
# against a real issue's labels.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `ready-for-agent`          | `ready\|for-agent`    | AFK-ready   |' >docs/agents/triage-labels.md
out="$(GH_STUB_ISSUE_LABELS=needs-triage "$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "refuses adoption when the escape-restored label is missing" "$st" 1
assert_contains "names the label with its escaped pipe restored, not truncated" \
  "$out" "ready|for-agent"
out="$(GH_STUB_ISSUE_LABELS='ready|for-agent' "$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "adopts once the issue carries the escape-restored label" "$st" 0

# Restores the canonical labels doc and a clean, flow-free repo: the escaped-
# pipe block above both rewrote the doc away from its default shape and left
# an adopted flow active, and the sub-issues section right after this expects
# the plain "fully healthy repo" the earlier healthy_repo() call above had
# left before this block started borrowing it.
healthy_repo

# Issue #39: triage_label_for lacks triage_labels' table-boundary/column-count
# guard, so a second, differently-shaped table elsewhere in the doc can shadow
# the real answer. Placed *before* the real table, with a row that resolves to
# the same role, so a reader with no boundary awareness matches it first and
# never reaches the real table at all.
writeln '# Other Reference' '' \
        '| Role | Other |' \
        '| ready-for-agent | wrong-label |' \
        '' \
        '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| --------------------------- | --------------------- | ----------- |' \
        '| `needs-triage`              | `needs-triage`         | Evaluate it |' \
        '| `ready-for-agent`           | `ready-for-agent`      | AFK-ready   |' >docs/agents/triage-labels.md

out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "list-labels: an unrelated table before the real one still passes" "$st" 0
assert_contains "still reads exactly the two documented labels" "$out" "2 triage labels"
assert_eq "does not read the unrelated table's value in as a label" \
  "$(printf '%s\n' "$out" | grep -c 'wrong-label')" "0"

out="$(GH_STUB_ISSUE_LABELS='wrong-label' "$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "label-for ignores the unrelated table's row rather than matching it" "$st" 1
assert_contains "resolves the role against the real table's label, not the one before it" \
  "$out" "ready-for-agent"

out="$(GH_STUB_ISSUE_LABELS='ready-for-agent' "$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "adopts once the issue carries the real table's label" "$st" 0

# Reset again: the successful adopt above just left a flow active, and the
# sub-issues checks right after this expect the plain flow-free healthy repo.
healthy_repo

# Sub-issues carry no enable/disable setting of their own, so the only
# reliable signal is asking the endpoint against an issue that exists and
# reading whether it answers or 404s. The default stub answers normally, and
# the "fully healthy repo" assertion at the end of this section already
# depends on that, so this is really confirming the ok line it produces.
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "sub-issues supported: still a healthy pass" "$st" 0
assert_contains "reports sub-issues as supported" "$out" "ok    sub-issues supported"

# The endpoint 404ing (or otherwise refusing) reads as "not supported" -
# advisory, so a warn, never a FAIL: the real gate is ticket_publish's own
# verify-then-die, not this probe.
out="$(GH_STUB_SUBISSUE_GET_EXIT=1 "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "unsupported sub-issues does not block the flow" "$st" 0
assert_contains "warns rather than fails when sub-issues are unsupported" \
  "$out" "warn  sub-issues do not appear to be supported"
assert_contains "explains the consequence rather than leaving it silent" \
  "$out" "ticket publish will fail"

# A repo with no issues at all has nothing to probe against - still a warn,
# not a FAIL, and a distinct message from the unsupported case above.
out="$(GH_STUB_ISSUE_LIST= "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "no issue to probe against does not block the flow" "$st" 0
assert_contains "says the probe could not run rather than guessing" \
  "$out" "sub-issues support could not be probed"

# Gated like every other GitHub-backed check: unreachable collapses into the
# shared skip line rather than adding a check-specific one of its own.
out="$(GH_STUB_MODE=offline "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "GitHub unreachable does not block the flow either" "$st" 0
assert_eq "still emits exactly one skip line, not a second for this check" \
  "$(printf '%s\n' "$out" | grep -c 'skipped:')" "1"

# Still the fixture healthy_repo() built for the label-list checks above -
# nothing since has touched anything but $out - so truncating the exclude
# file here is the only new mutation, and it's this test's own setup, not
# leftover state to clean up first.
: >.git/info/exclude
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a missing git exclude line warns without blocking" "$st" 0
assert_contains "counts one warn and no FAILs" \
  "$(printf '%s\n' "$out" | tail -1)" "1 warn, 0 FAIL"
assert_contains "gives a command that adds the exclude line" "$out" "info/exclude"

# The exclude line is still truncated from the check above, so this one does
# need a real reset before layering CLAUDE_PLUGIN_ROOT's own warning on top.
healthy_repo
out="$(env -u CLAUDE_PLUGIN_ROOT CLAUDECODE=1 "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "running orch.sh by hand is not a broken install" "$st" 0
assert_contains "warns about the unset plugin root" "$out" "CLAUDE_PLUGIN_ROOT"

# --- doctor: host (#128) ---
# Reduced enforcement has to be visible: doctor says which host it believes it
# is under and what that host cannot do, in the words of the capabilities
# reference - so the two cannot tell a user different stories.
out="$(env -u CLAUDE_PLUGIN_ROOT CLAUDECODE=1 "$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "detects Claude Code from CLAUDECODE" "$out" "host: Claude Code"
assert_eq "Claude Code lacks no capability" "$(printf '%s\n' "$out" | grep -c 'lacks')" "0"
assert_contains "the plugin root check still warns when Claude Code left it unset" \
  "$out" "warn  CLAUDE_PLUGIN_ROOT"

out="$(env -u CLAUDE_PLUGIN_ROOT JUNIE_EXTENSION_ROOT="$PWD" "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "Junie's missing capabilities warn, never fail" "$st" 0
assert_contains "detects Junie from JUNIE_EXTENSION_ROOT" "$out" "host: Junie"
assert_contains "names the edit guard Junie cannot arm" "$out" "Arm the edit guard"
assert_contains "names the fresh subagent Junie cannot start" "$out" "Start a fresh subagent"
assert_contains "names the forked subagent Junie cannot start" "$out" "Start a forked subagent"
# A human on Junie still starts a skill with /<name>; only the model lacks it.
assert_contains "names only mid-step skill invocation as missing" "$out" "Invoke a skill from a step"
assert_contains "points at the reference for the fallbacks" "$out" "docs/host-capabilities.md"
assert_eq "does not list what Junie can do" \
  "$(printf '%s\n' "$out" | grep -c 'Ask a multiple-choice question')" "0"
# An unconfirmed cell is not a known gap: doctor must not state it as one.
assert_contains "names what is unverified on Junie" "$out" "unverified: Run a plugin command"
assert_eq "does not claim Junie lacks what is only unverified" \
  "$(printf '%s\n' "$out" | grep -o 'lacks: [^;]*' | grep -c 'Run a plugin command')" "0"
assert_contains "an unset plugin root is expected on Junie, not a warning" \
  "$out" "ok    CLAUDE_PLUGIN_ROOT"

out="$(ORCHESTRATOR_HOST=junie "$ORCH" doctor --env 2>&1)"
assert_contains "ORCHESTRATOR_HOST outranks the Claude signals" "$out" "host: Junie"
out="$(ORCHESTRATOR_HOST=vim "$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "names an ORCHESTRATOR_HOST it does not know" "$out" "ORCHESTRATOR_HOST=vim"

out="$(env -u CLAUDE_PLUGIN_ROOT "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "no detectable host is not a broken install" "$st" 0
assert_contains "says the host was not detected" "$out" "host not detected"
assert_contains "and how to name it" "$out" "export ORCHESTRATOR_HOST="

# A skills-only install copies the skills without scripts/, so the relative
# path every skill resolves orch.sh by leads nowhere. doctor runs from an
# orch.sh, so what it can see is such a copy sitting in a user skill store.
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "reports the orch.sh it runs from" "$out" "ok    orch.sh:"
h="$HOME"
mkdir -p "$h/.agents/skills/orch-flow"
touch "$h/.agents/skills/orch-flow/SKILL.md"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "reports a skills-only copy with no orch.sh" "$out" "orch.sh missing"
assert_contains "names the skills CLI copy" "$out" "~/.agents/skills: orch-flow"
# Like the mattpocock remedy, the fix names only the detected host's install.
assert_contains "names the full-plugin install for Claude Code" "$out" "/plugin install orchestrator@orchestrator"
assert_eq "and not Junie's, under Claude Code" \
  "$(printf '%s\n' "$out" | grep -c 'as a Junie extension')" "0"
out="$(env -u CLAUDE_PLUGIN_ROOT JUNIE_EXTENSION_ROOT="$PWD" "$ORCH" doctor --env 2>&1)"
assert_contains "names the full-plugin install for Junie" "$out" "maj0rpain/orchestrator as a Junie extension"
assert_contains "and marks it unverified" "$out" "as a Junie extension (unverified)"
assert_eq "and not Claude Code's, under Junie" \
  "$(printf '%s\n' "$out" | grep -c '/plugin install orchestrator@orchestrator')" "0"
out="$(env -u CLAUDE_PLUGIN_ROOT "$ORCH" doctor --env 2>&1)"
assert_contains "names every host's install when none is detected" "$out" "/plugin install orchestrator@orchestrator"
assert_contains "including Junie's" "$out" "maj0rpain/orchestrator as a Junie extension"
# ~/.junie/skills is not a verified Junie location (#121: verified facts only).
rm -rf "$h/.agents/skills/orch-flow"
mkdir -p "$h/.junie/skills/orch-review"
touch "$h/.junie/skills/orch-review/SKILL.md"
out="$("$ORCH" doctor --env 2>&1)"
assert_eq "does not scan the unverified ~/.junie/skills" \
  "$(printf '%s\n' "$out" | grep -c 'orch.sh missing')" "0"
rm -rf "$h/.junie/skills/orch-review"

# env -u above was scoped to that one command too, so this is still the same
# fully-healthy repo - exactly the state this last check needs to prove out.
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "separates groups with a blank line and a bare header" \
  "$out" "$(printf '\n\nauth & remotes\n')"
assert_contains "a fully healthy repo reports no warns and no FAILs" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 0 FAIL"
# Asserted against the lines actually printed rather than a literal, so adding a
# check to the registry cannot quietly make the count wrong.
assert_eq "the summary's ok count matches the ok lines it printed" \
  "$(printf '%s\n' "$out" | tail -1 | sed 's/ ok,.*//')" \
  "$(printf '%s\n' "$out" | grep -c '^ok    ')"

# --- doctor --flow ----------------------------------------------------------
# An empty answer must never read as a healthy one: --flow is asked explicitly
# about a flow, so no flow is a failure there and a plain statement everywhere
# else.
healthy_repo
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "--flow refuses to answer when there is no flow" "$st" 1
assert_contains "says why it cannot answer" "$out" "no active flow"

out="$("$ORCH" doctor 2>&1)"; st=$?
assert_status "bare doctor is safe to run with no flow" "$st" 0
assert_contains "states there is no flow instead of failing" "$out" "ok    no active flow"
assert_contains "bare doctor covers the environment too" "$out" "tools"

"$ORCH" init flowtest >/dev/null
complete_plan_handoff "$("$ORCH" handoff path spec)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a fresh flow is healthy" "$st" 0
assert_contains "reports the phase" "$out" "phase: spec"
# "published" names only one of the two paths an issue can arrive by (to-spec
# publishing vs. adoption at init, docs/adr/0005) - neutral wording here must
# not imply the other path doesn't exist.
assert_contains "reports no issue recorded yet without implying publication is the only path" \
  "$out" "issue: not recorded yet"
assert_eq "--flow leaves the environment alone" \
  "$(printf '%s\n' "$out" | grep -c '^tools$')" "0"
assert_eq "stays quiet about an upstream before the implement phase" \
  "$(printf '%s\n' "$out" | grep -c 'upstream')" "0"

# /orchestrator:next and /orchestrator:status both run this scope every time, and
# a flow with no PR recorded has nothing to ask GitHub about.
ghlog="$(mktemp)"
GH_STUB_LOG="$ghlog" "$ORCH" doctor --flow >/dev/null 2>&1
assert_eq "a flow with no PR asks GitHub nothing" "$(grep -c . "$ghlog")" "0"

# One unparseable file is one problem. Four checks each reading it again would
# print jq's parse error mid-report and then four ok lines that are not true.
statebak="$(mktemp)"
cp .orchestrator/state.json "$statebak"
printf '%s' '{not json' >.orchestrator/state.json
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when state.json does not parse" "$st" 1
assert_contains "names the file that will not parse" "$out" "not valid JSON"
assert_eq "reports it once rather than once per check" \
  "$(printf '%s\n' "$out" | grep -c '^FAIL')" "1"
assert_eq "claims nothing it could not read" \
  "$(printf '%s\n' "$out" | grep -c '^ok    ')" "0"
assert_eq "does not leak jq's parse error into the report" \
  "$(printf '%s\n' "$out" | grep -c 'parse error')" "0"
cp "$statebak" .orchestrator/state.json

"$ORCH" state set phase nonsense
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "rejects an unknown phase" "$st" 1
assert_contains "names the phase it does not know" "$out" "nonsense"
"$ORCH" state set phase spec

"$ORCH" state set branch orch/9-gone
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the recorded branch is gone" "$st" 1
assert_contains "names the missing branch" "$out" "orch/9-gone"

git checkout -q -b orch/9-gone
"$ORCH" state set phase implement
complete_spec_handoff "$("$ORCH" handoff path implement)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an unpushed branch warns rather than blocking the implement phase" "$st" 0
assert_contains "gives the command that pushes it" "$out" "git push -u origin orch/9-gone"

# branch create forks off origin/<default>, so an unpushed branch already has an
# upstream - just not its own. Accepting any upstream would call a branch nobody
# else can see pushed.
git update-ref refs/remotes/origin/main HEAD
git branch -q --set-upstream-to=origin/main orch/9-gone
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_contains "an upstream pointing at the base branch is still unpushed" \
  "$out" "not on origin yet"

# A handoff with a bare required heading is the failure the next phase would
# experience as running blind, so it has to surface as a FAIL here.
writeln '## Spec issue' '#1' '' '## Seams' '' '## Spec review changelog' 'None.' \
  >"$("$ORCH" handoff path implement)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when a completed phase's handoff has an empty section" "$st" 1
assert_contains "names the handoff" "$out" "02-spec.md"
assert_contains "reports it as empty, not missing" "$out" "empty section"
complete_spec_handoff "$("$ORCH" handoff path implement)"

# check_flow_issue runs unconditionally on state.issue, whichever path put it
# there - adopted at init or published by to-spec - and mirrors check_flow_pr's
# open/closed/unreadable shape.
"$ORCH" state set issue 11
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an open issue is healthy" "$st" 0
assert_contains "reports the open issue" "$out" "issue #11 open"

out="$(GH_STUB_ISSUE_STATE=CLOSED "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the recorded issue has been closed" "$st" 1
assert_contains "names the closed issue" "$out" "issue #11 is closed"
assert_contains "gives the command that reopens it" "$out" "gh issue reopen 11"

out="$(GH_STUB_VIEW_EXIT=1 "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the issue cannot be read from GitHub" "$st" 1
assert_contains "names the unreadable issue" "$out" "issue #11 could not be read from GitHub"
assert_contains "gives the command that re-checks it" "$out" "gh issue view 11"

# The ready-for-agent label is a one-time gate at adoption, not an ongoing flow
# invariant (docs/adr/0005) - a maintainer's later triage housekeeping must not
# stop a flow already running against the issue.
out="$(GH_STUB_ISSUE_LABELS=needs-triage "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an issue whose label was removed after adoption is still healthy" "$st" 0
assert_contains "still reports it open" "$out" "issue #11 open"

# issue #13: pr open always writes `Closes #<issue>`, so a merged flow's issue
# is closed as a matter of course - a done flow reporting that as broken was
# doctor misreporting every successfully-finished flow.
complete_implement_handoff "$("$ORCH" handoff path review)"
"$ORCH" state set phase done
out="$(GH_STUB_ISSUE_STATE=CLOSED "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a closed issue is healthy once the flow is done" "$st" 0
assert_contains "reports it closed instead of failing" "$out" "issue #11 closed"
"$ORCH" state set phase implement

"$ORCH" state set pr 7
out="$(GH_STUB_PR_STATE=CLOSED "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the recorded PR has been closed" "$st" 1
assert_contains "names the closed PR" "$out" "#7"
out="$(GH_STUB_PR_STATE=MERGED "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a merged PR is not a failure" "$st" 0

out="$(GH_STUB_MODE=offline "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an unreachable GitHub does not fail the flow scope" "$st" 0
assert_contains "skips the PR check with its cause" "$out" "skipped: GitHub is not reachable"

# --flow never runs the tools group, so if it skipped every check it has and
# still exited 0, /orchestrator:next would advance a flow nothing had checked.
if on_windows_bash; then
  skip_no_jq "--flow without jq fails rather than reporting a clean bill"
  skip_no_jq "names jq as the reason it cannot answer"
else
  out="$(PATH="$nojq_path" "$ORCH" doctor --flow 2>&1)"; st=$?
  assert_status "--flow without jq fails rather than reporting a clean bill" "$st" 1
  assert_contains "names jq as the reason it cannot answer" "$out" "jq not found"
fi

if on_windows_bash; then
  skip_no_jq "bare doctor without jq fails on the tools check"
  skip_no_jq "collapses every flow check into one line when jq is gone"
else
  out="$(PATH="$nojq_path" "$ORCH" doctor 2>&1)"; st=$?
  assert_status "bare doctor without jq fails on the tools check" "$st" 1
  # The count comes from the registry, so a check appended to it is covered by the
  # gate without anyone remembering to add a preamble - and this number moving is
  # how you find out that happened.
  assert_contains "collapses every flow check into one line when jq is gone" \
    "$out" "10 flow checks skipped: jq is not installed"
fi

# --- pr open -----------------------------------------------------------------
# PR #15 merged without closing #14 because the agent's body opened with a verb
# GitHub does not read as a closer. pr open owns the keyword instead, so no
# agent-chosen wording can leave a spec issue open again.
#
# open_pr's create/view go through the ORCH_GH_ADAPTER seam here, pointed at
# the in-memory fake rather than stub_gh - GH_STUB_LOG stays empty across every
# call below, proving neither ever spawns a real gh subprocess. The
# subprocess-real counterpart is the "gh adapter (real pr create/view,
# subprocess gh)" block right after "pr publish".
echo
echo "pr open"
healthy_repo
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
git remote set-url origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init propen >/dev/null
git checkout -q -b orch/16-propen
"$ORCH" state set branch orch/16-propen
body="$(mktemp)"
writeln 'Implements the thing.' '' 'Some detail.' >"$body"

out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "refuses when state has no issue" "$st" 1
assert_contains "with the guard branch create uses" "$out" \
  "no issue recorded in state - the spec phase must publish one first"

"$ORCH" state set issue 16
filed="$(mktemp)"
log="$(mktemp)"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" GH_STUB_LOG="$log" GH_STUB_REPO=main GH_STUB_PR_NUMBER=23 \
  "$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "opens the PR" "$st" 0
assert_eq "prints the PR number gh answered" "$out" "23"
assert_eq "and records it in state" "$("$ORCH" state get pr)" "23"
body_recorded="$(sed -n '/^body:$/,$p' "$filed" | tail -n +2)"
assert_first_line "the recorded body opens with the closing keyword" \
  "$body_recorded" "Closes #16"
assert_contains "and targets the flow's base, the default branch" "$(cat "$filed")" "base=main"
assert_eq "leaves a blank line before the original body" \
  "$(printf '%s\n' "$body_recorded" | sed -n 2p)" ""
assert_contains "and keeps the agent's original body intact after a blank line" \
  "$body_recorded" "Some detail."
assert_eq "the create/view calls never reached a real gh subprocess" \
  "$(grep -cx pr "$log")" "0"

out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_PR_CREATE_EXIT=1 "$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not open the PR fails it" "$st" 1
assert_contains "naming the branch it would have opened from" "$out" "orch/16-propen"
assert_contains "and the issue it would have closed" "$out" "#16"

# require_branch's die message is the other half of require_field's coverage
# (#79) alongside "refuses when state has no issue" above - a fresh flow with
# an issue recorded but no branch yet is exactly the gap between init and
# branch create.
echo
echo "pr open (missing branch)"
new_repo >/dev/null
"$ORCH" init nobranch >/dev/null
"$ORCH" state set issue 21
body="$(mktemp)"
writeln 'Implements the thing.' >"$body"
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "refuses when state has no branch" "$st" 1
assert_contains "with the exact require_branch die message" "$out" \
  "no branch recorded in state"

# --- pr publish --------------------------------------------------------------
# The publishing boundary a quick implementation calls instead of hardcoding
# `gh pr create` in skill prose - stateless like branch off and issue publish,
# and not a draft like pr open is, since a quick implementation's single-pass
# review already ran before this is called.
echo
echo "pr publish"
new_repo >/dev/null
git remote add origin https://github.com/acme/widgets.git
stub_gh
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
git remote set-url origin "$bare"
git push -q origin HEAD:refs/heads/main
git checkout -q -b quick/16-widgets
body="$(mktemp)"
writeln 'Implements the thing.' '' 'Some detail.' >"$body"

filed="$(mktemp)"
out="$(GH_STUB_FILED="$filed" GH_STUB_REPO=main GH_STUB_PR_NUMBER=23 \
  "$ORCH" pr publish 16 "Title" "$body" 2>&1)"; st=$?
assert_status "opens the PR" "$st" 0
assert_eq "prints the PR number gh answered" "$out" "23"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_contains "opens against the default branch, not as a draft" "$(cat "$filed")" "base=main"
assert_contains "and against the current branch" "$(cat "$filed")" "head=quick/16-widgets"
assert_eq "with no bogus flag=<value> entries for the base/head values" \
  "$(grep -c '^flag=' "$filed")" "0"
body_recorded="$(sed -n '/^body:$/,$p' "$filed" | tail -n +2)"
assert_first_line "the recorded body opens with the closing keyword" \
  "$body_recorded" "Closes #16"
assert_contains "and keeps the agent's original body intact after a blank line" \
  "$body_recorded" "Some detail."
assert_eq "pushes the current branch" \
  "$(git -C "$bare" rev-parse --quiet --verify refs/heads/quick/16-widgets >/dev/null && echo pushed || echo missing)" \
  "pushed"

out="$("$ORCH" pr publish abc "Title" "$body" 2>&1)"; st=$?
assert_status "refuses an issue that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" pr publish 16 "Title" /nonexistent/body.md 2>&1)"; st=$?
assert_status "refuses a body file that does not exist" "$st" 1

out="$(GH_STUB_PR_CREATE_EXIT=1 "$ORCH" pr publish 16 "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not open the PR fails it" "$st" 1
assert_contains "naming the branch it would have opened from" "$out" "quick/16-widgets"
assert_contains "and the issue it would have closed" "$out" "#16"

# --- pr: unknown op -----------------------------------------------------------
out="$("$ORCH" pr bogus 2>&1)"; st=$?
assert_status "pr bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown pr op"
assert_contains "naming both" "$out" "open|publish"

# --- gh adapter (real pr create/view, subprocess gh) -------------------------
# pr open just proved the seam through the in-memory fake, and pr publish
# above already shells out for real (ORCH_GH_ADAPTER unset) since it never
# switched to the fake - this is the narrow assertion that both calls actually
# reach a real gh subprocess rather than merely compiling: one for the create,
# one for the view that reads the PR number back.
echo
echo "gh adapter (real pr create/view, subprocess gh)"
: >"$filed"
log="$(mktemp)"
out="$(GH_STUB_FILED="$filed" GH_STUB_LOG="$log" GH_STUB_REPO=main GH_STUB_PR_NUMBER=24 \
  "$ORCH" pr publish 16 "Title" "$body" 2>&1)"; st=$?
assert_status "shells out for real" "$st" 0
assert_eq "and reads back the number the real gh answered" "$out" "24"
assert_contains "the real adapter invoked gh pr create with the base flag's value" \
  "$(cat "$filed")" "base=main"
assert_contains "and the head flag's value" "$(cat "$filed")" "head=quick/16-widgets"
assert_eq "with no bogus flag=<value> entries for the base/head values" \
  "$(grep -c '^flag=' "$filed")" "0"
assert_eq "gh itself was invoked once for create and once for view, as real subprocesses" \
  "$(grep -cx pr "$log")" "2"

# --- ticket publish -----------------------------------------------------
# The one place the ticket-breakdown feature touches GitHub's native
# sub-issue and issue-dependency APIs, so no skill prose ever calls `gh api`
# on these endpoints directly. Stateless like issue publish/pr publish: the
# stub's GH_STUB_DB is a throwaway fake GitHub, not orch.sh state.
echo
echo "ticket publish"
healthy_repo
db="$(mktemp -d)"
export GH_STUB_DB="$db"
body="$(mktemp)"
writeln 'Build the thing.' >"$body"
filed="$(mktemp)"
out="$(GH_STUB_FILED="$filed" GH_STUB_ISSUE_NUMBER=100 \
  "$ORCH" ticket publish 50 "First ticket" "$body" 2>&1)"; st=$?
assert_status "publishes" "$st" 0
assert_eq "printing the child's issue number and nothing else" "$out" "100"
assert_contains "passes the title through" "$(cat "$filed")" "title=First ticket"
assert_contains "sends the body file's contents" "$(cat "$filed")" "Build the thing."
assert_contains "applies ready-for-agent" "$(cat "$filed")" "label=ready-for-agent"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "links the child as 50's sub-issue" "$("$ORCH" ticket next 50)" "100"

out="$("$ORCH" ticket publish 50 "Second ticket" "$body" --blocked-by 100 2>&1)"; st=$?
assert_status "publishes a ticket blocked by the first" "$st" 0
assert_eq "prints the new child's number" "$out" "101"
assert_eq "the still-blocked ticket is not in the frontier" "$("$ORCH" ticket next 50)" "100"

# GitHub stores a blocking edge once no matter how many times it is asked
# for - a duplicate in --blocked-by must not make the readback's set
# permanently smaller than what was requested and fail verification for a
# link that is actually correct.
out="$("$ORCH" ticket publish 50 "Third ticket" "$body" --blocked-by 100,100 2>&1)"; st=$?
assert_status "a duplicate blocker in the list still verifies and succeeds" "$st" 0

out="$("$ORCH" ticket publish 50 "" "$body" 2>&1)"; st=$?
assert_status "refuses an empty title" "$st" 1

out="$("$ORCH" ticket publish 50 "Title" /nonexistent/body.md 2>&1)"; st=$?
assert_status "refuses a body file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"

out="$("$ORCH" ticket publish abc "Title" "$body" 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by "abc,5" 2>&1)"; st=$?
assert_status "refuses a --blocked-by list with a non-numeric entry" "$st" 1
assert_contains "naming the whole list" "$out" "abc,5"

out="$("$ORCH" ticket publish 50 "Title" "$body" --bogus 2>&1)"; st=$?
assert_status "rejects an unknown flag" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket publish"

out="$("$ORCH" ticket publish 50 2>&1)"; st=$?
assert_status "refuses with no body file" "$st" 1

out="$(GH_STUB_ISSUE_EXIT=1 "$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not create the ticket fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not create the ticket"

out="$(GH_STUB_API_EXIT=1 "$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that cannot read the child's database id fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not read issue"

out="$(GH_STUB_SUBISSUE_POST_EXIT=1 "$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that refuses the sub-issue link fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not link ticket"

out="$(GH_STUB_BLOCKED_POST_EXIT=1 "$ORCH" ticket publish 50 "Title" "$body" --blocked-by 100 2>&1)"; st=$?
assert_status "a gh that refuses the blocking edge fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not add a blocking edge"

# --- ticket publish verify-then-die ---------------------------------------
# Immediately after publishing, ticket_publish reads the links back. One
# retry on a mismatch; a second failure dies naming the ticket, rather than
# falling back to a text-based `Blocked by:` convention nothing downstream
# ever reads. GH_STUB_SUBISSUE_MISS/GH_STUB_BLOCKED_MISS force the mismatch
# by making the readback report stale (empty) data for N calls.
echo
echo "ticket publish verify-then-die"
db="$(mktemp -d)"
out="$(GH_STUB_DB="$db" GH_STUB_ISSUE_NUMBER=200 GH_STUB_SUBISSUE_MISS=1 \
  "$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a sub-issue link that only shows up on the retry still succeeds" "$st" 0
assert_eq "prints the child's number" "$out" "200"

db="$(mktemp -d)"
out="$(GH_STUB_DB="$db" GH_STUB_ISSUE_NUMBER=201 GH_STUB_SUBISSUE_MISS=2 \
  "$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a sub-issue link that never shows up dies rather than falling back" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #201"
assert_contains "not a silent fallback" "$out" "did not verify"

db="$(mktemp -d)"
blocker="$(GH_STUB_DB="$db" GH_STUB_ISSUE_NUMBER=300 "$ORCH" ticket publish 50 "Blocker" "$body")"
out="$(GH_STUB_DB="$db" GH_STUB_BLOCKED_POST_EXIT=0 GH_STUB_BLOCKED_MISS=2 \
  "$ORCH" ticket publish 50 "Blocked" "$body" --blocked-by "$blocker" 2>&1)"; st=$?
assert_status "a blocking edge that never shows up dies rather than falling back" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #301"

# --- ticket next -----------------------------------------------------------
# The parent's open sub-issues with zero open blockers
# (issue_dependencies_summary.blocked_by, which already counts open blockers
# only), in the order they were published.
echo
echo "ticket next"
db="$(mktemp -d)"
export GH_STUB_DB="$db"
a="$(GH_STUB_ISSUE_NUMBER=400 "$ORCH" ticket publish 90 "A" "$body")"
b="$("$ORCH" ticket publish 90 "B" "$body" --blocked-by "$a")"
c="$("$ORCH" ticket publish 90 "C" "$body")"
out="$("$ORCH" ticket next 90)"
assert_eq "open-and-unblocked tickets only, in publish order, excluding the still-blocked one" \
  "$out" "$(printf '%s\n%s' "$a" "$c")"

"$ORCH" ticket close "$a" >/dev/null
out="$("$ORCH" ticket next 90)"
assert_eq "a closed blocker drops out, freeing its dependent" "$out" "$(printf '%s\n%s' "$b" "$c")"

"$ORCH" ticket close "$c" >/dev/null
out="$("$ORCH" ticket next 90)"
assert_eq "a closed ticket itself is no longer in the frontier" "$out" "$b"

out="$("$ORCH" ticket next abc 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" ticket next 2>&1)"; st=$?
assert_status "refuses with no parent" "$st" 1

out="$(GH_STUB_API_EXIT=1 "$ORCH" ticket next 90 2>&1)"; st=$?
assert_status "a gh that cannot list sub-issues fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not list sub-issues"

# --- ticket close ------------------------------------------------------------
echo
echo "ticket close"
db="$(mktemp -d)"
export GH_STUB_DB="$db"
n="$(GH_STUB_ISSUE_NUMBER=500 "$ORCH" ticket publish 90 "Closeable" "$body")"
out="$("$ORCH" ticket close "$n" 2>&1)"; st=$?
assert_status "closes the ticket" "$st" 0
assert_eq "and it drops out of the parent's open sub-issues" \
  "$("$ORCH" ticket next 90)" ""

out="$("$ORCH" ticket close abc 2>&1)"; st=$?
assert_status "refuses a ticket that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$(GH_STUB_ISSUE_CLOSE_EXIT=1 "$ORCH" ticket close "$n" 2>&1)"; st=$?
assert_status "a gh that will not close the ticket fails" "$st" 1
assert_contains "naming what failed" "$out" "gh could not close ticket"

# --- ticket reset ------------------------------------------------------------
# Reopens every sub-issue of <parent> that is currently closed, and only
# those - what redo review needs before handing back to a fresh implement
# phase, whose frontier query would otherwise find nothing.
echo
echo "ticket reset"
db="$(mktemp -d)"
export GH_STUB_DB="$db"
x="$(GH_STUB_ISSUE_NUMBER=600 "$ORCH" ticket publish 90 "X" "$body")"
y="$("$ORCH" ticket publish 90 "Y" "$body")"
z="$("$ORCH" ticket publish 90 "Z" "$body")"
"$ORCH" ticket close "$x" >/dev/null
"$ORCH" ticket close "$y" >/dev/null
out="$("$ORCH" ticket reset 90 2>&1)"; st=$?
assert_status "resets" "$st" 0
assert_eq "reopens exactly the tickets that were closed, and only those" \
  "$("$ORCH" ticket next 90)" "$(printf '%s\n%s\n%s' "$x" "$y" "$z")"

out="$("$ORCH" ticket reset abc 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

"$ORCH" ticket close "$x" >/dev/null
out="$(GH_STUB_ISSUE_REOPEN_EXIT=1 "$ORCH" ticket reset 90 2>&1)"; st=$?
assert_status "a gh that will not reopen a ticket fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not reopen ticket"

out="$(GH_STUB_API_EXIT=1 "$ORCH" ticket reset 90 2>&1)"; st=$?
assert_status "a gh that cannot list sub-issues fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not list sub-issues"

# --- ticket: unknown op ------------------------------------------------------
out="$("$ORCH" ticket bogus 2>&1)"; st=$?
assert_status "ticket bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown ticket op"

unset GH_STUB_DB

# --- review begin -----------------------------------------------------------
# The bound lives in bash precisely so a long session cannot re-remember five as
# six, so what matters here is the refusal, not the counting. The budget is the
# human's number, read from state; a flow that never wrote one runs the default.
echo
echo "review begin"
healthy_repo

# --- issue fetch/update -------------------------------------------------------
# The stateless issue body read/write pair - the same contract
# issue publish/pr publish/ticket publish already offer, extended to a plain
# issue's body. cmd_spec's fetch/update ops (further below) become thin
# wrappers over these, resolving the issue from state exactly as before - so
# this section proves the primitives work given just an issue number, before
# `init reviewtest` below ever writes a state.json into this repo.
#
# Goes through the ORCH_GH_ADAPTER seam here, pointed at the in-memory fake
# rather than stub_gh - GH_STUB_LOG stays empty, proving it never spawns a
# real gh subprocess. The subprocess-real counterpart is folded into the "gh
# adapter (real issue view/edit/comment, subprocess gh)" block further below,
# which already exercises adapter_issue_view/adapter_issue_edit for real - the
# same two functions this primitive calls.
echo
echo "issue fetch/update"
assert_eq "no state.json exists yet in this repo" \
  "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
issue_body="$(mktemp)"
log="$(mktemp)"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_LOG="$log" GH_STUB_BODY="Body of #23." \
  "$ORCH" issue fetch 23 "$issue_body" 2>&1)"; st=$?
assert_status "fetch writes the issue's body to the file, with no state.json present" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "exactly what gh answered" "$(cat "$issue_body")" "Body of #23."
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the view call never reached a real gh subprocess" "$(grep -cx issue "$log")" "0"

rm -f "$issue_body"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_VIEW_EXIT=1 "$ORCH" issue fetch 23 "$issue_body" 2>&1)"; st=$?
assert_status "a gh that will not answer fails the fetch" "$st" 1
assert_contains "naming the issue" "$out" "issue #23"
assert_eq "and leaves no file a caller could mistake for a body" \
  "$([ -e "$issue_body" ] && echo present || echo gone)" "gone"

filed="$(mktemp)"
tricky="$(mktemp)"
writeln '## Solution' '' 'Tracked in #6; see `$HOME` and '"'"'quoted'"'"' text.' >"$tricky"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" GH_STUB_LOG="$log" \
  "$ORCH" issue update 23 "$tricky" 2>&1)"; st=$?
assert_status "update replaces the issue's body, with no state.json present" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_contains "editing the issue number given, not one from state" \
  "$(cat "$filed")" "issue edit 23"
assert_contains "with the file's contents as the body, exactly" \
  "$(cat "$filed")" "Tracked in #6"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the edit call never reached a real gh subprocess" "$(grep -cx issue "$log")" "0"

out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" "$ORCH" issue update 23 /nonexistent/body.md 2>&1)"; st=$?
assert_status "update refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"

out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_EDIT_EXIT=1 "$ORCH" issue update 23 "$tricky" 2>&1)"; st=$?
assert_status "a gh that will not edit fails the update" "$st" 1
assert_contains "naming the issue" "$out" "issue #23"

out="$("$ORCH" issue fetch abc "$issue_body" 2>&1)"; st=$?
assert_status "fetch refuses an issue number that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" issue update abc "$tricky" 2>&1)"; st=$?
assert_status "update refuses the same" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" issue fetch 23 2>&1)"; st=$?
assert_status "fetch refuses with no file" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh issue"

out="$("$ORCH" issue bogus 23 "$tricky" 2>&1)"; st=$?
assert_status "refuses an op it does not have" "$st" 1
assert_contains "naming the three it does" "$out" "fetch|update|publish"

assert_contains "help documents issue fetch" "$("$ORCH" help)" "issue fetch"
assert_contains "and issue update" "$("$ORCH" help)" "issue update"
assert_contains "and issue publish" "$("$ORCH" help)" "issue publish"

assert_eq "still no state.json - this section recorded none" \
  "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"

"$ORCH" init reviewtest >/dev/null
assert_eq "the first iteration is 1" "$("$ORCH" review begin)" "1"
assert_eq "records the iteration in state" "$("$ORCH" state get iteration)" "1"
for i in 2 3 4 5; do
  assert_eq "iteration $i is claimed in order" "$("$ORCH" review begin)" "$i"
done
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "refuses a sixth iteration on the default budget" "$st" 1
assert_contains "names the budget that stopped it" "$out" "budget of 5 iterations"
assert_eq "and does not spend the refused iteration" "$("$ORCH" state get iteration)" "5"

"$ORCH" state set iteration 0
"$ORCH" state set budget 2
assert_eq "a budget of 2 admits the first iteration" "$("$ORCH" review begin)" "1"
assert_eq "and the second" "$("$ORCH" review begin)" "2"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and refuses the third" "$st" 1
assert_contains "naming the budget it honoured" "$out" "budget of 2 iterations"

"$ORCH" state set iteration 0
"$ORCH" state set budget 8
for i in 1 2 3 4 5 6 7 8; do "$ORCH" review begin >/dev/null; done
assert_eq "a budget of 8 runs past the old bound of five" "$("$ORCH" state get iteration)" "8"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and stops at eight" "$st" 1

# A budget nothing can read is the default, not a refusal: the only flows that
# carry one are the ones started before it existed.
"$ORCH" state set iteration 4
"$ORCH" state set budget null
assert_eq "a null budget reads as five" "$("$ORCH" review begin)" "5"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and refuses the sixth" "$st" 1
"$ORCH" state set iteration 4
"$ORCH" state set budget lots
assert_eq "a budget that is not a number reads as five" "$("$ORCH" review begin)" "5"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and refuses the sixth too" "$st" 1
"$ORCH" state set budget null

# --- review path ------------------------------------------------------------
# One flow, one trail: the records sit flat under review/, numbered on across
# every loop the flow runs, so nothing is ever moved aside.
echo
echo "review path"
assert_contains "files the record flat under review/" \
  "$("$ORCH" review path)" "/review/iteration-05.md"
assert_contains "zero-pads an explicit iteration" \
  "$("$ORCH" review path 2)" "/review/iteration-02.md"
assert_eq "creates the directory it names" \
  "$([ -d .orchestrator/review ] && echo present || echo gone)" "present"
out="$("$ORCH" review path nope 2>&1)"; st=$?
assert_status "rejects an iteration that is not a number" "$st" 1

# --- handoff verification ---------------------------------------------------
# The review loop runs the command the implement phase recorded rather than
# sniffing the repo for one, so a handoff without it sends review in blind.
echo
echo "handoff verification"
h3="$("$ORCH" handoff path review)"
writeln '## PR' '#3' '' '## Spec issue' '#1' '' '## Base SHA' 'abc1234' '' \
        '## Deviations' 'None.' >"$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "an implement handoff with no verification command is incomplete" "$st" 1
assert_contains "names the section review would have read" "$out" "Verification"

writeln '## PR' '#3' '' '## Spec issue' '#1' '' '## Base SHA' 'abc1234' '' \
        '## Deviations' 'None.' '' '## Verification' '   ' >"$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "a bare Verification heading is no better than none" "$st" 1
assert_contains "reported as empty, not missing" "$out" "empty section"

complete_implement_handoff "$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "passes once the command is recorded" "$st" 0

# --- the multi-loop machinery is gone ---------------------------------------
# Every loop reads the implement handoff, whatever the flow has been through.
# The old entry points are removed rather than deprecated, so each one has to
# fail loudly: a session that found a path back into them would be driving a
# loop nothing else understands.
echo
echo "the multi-loop machinery is gone"
"$ORCH" state set phase review
"$ORCH" state set iteration 7
assert_contains "review reads the implement handoff however far in the flow is" \
  "$("$ORCH" handoff path review)" "03-implement.md"
"$ORCH" state set iteration 5

out="$("$ORCH" handoff path review-next 2>&1)"; st=$?
assert_status "there is no handoff for a next loop to read" "$st" 1
assert_eq "and no path printed for a caller to use" \
  "$(printf '%s\n' "$out" | grep -c '/handoff/')" "0"

writeln '## PR' '#3' >.orchestrator/handoff/04-review.md
out="$("$ORCH" handoff validate .orchestrator/handoff/04-review.md 2>&1)"; st=$?
assert_status "a review handoff is not a handoff validate knows" "$st" 1
assert_contains "and it says so rather than passing it empty" "$out" "unknown handoff file"
rm .orchestrator/handoff/04-review.md

out="$("$ORCH" review loop-next 2>&1)"; st=$?
assert_status "review loop-next is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown review op"

# --- review file ------------------------------------------------------------
# Filing is mechanism: which labels, what title, which body, and the number
# printed back. The stub records what reached gh, which is the assertion - a
# finding filed with no severity label is a finding triage never finds.
#
# Label creation and issue creation both go through the ORCH_GH_ADAPTER seam
# here, pointed at the in-memory fake (scripts/test/gh_adapter_fake.sh) rather
# than stub_gh - neither ever spawns a subprocess. The subprocess-real
# counterpart of the label-create half lives in "gh adapter (real
# label-create, subprocess gh)" right after this section; the create half's
# in "gh adapter (real issue create, subprocess gh)" beside it.
echo
echo "review file"
filed="$(mktemp)"
body="$(mktemp)"
writeln 'The reviewer said this.' '' 'Axis: Standards' >"$body"
log="$(mktemp)"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" GH_STUB_LOG="$log" GH_STUB_ISSUE_NUMBER=17 \
  "$ORCH" review file major "Comment drifted from the code" --body-file "$body" 2>&1)"; st=$?
assert_status "files a major" "$st" 0
assert_eq "printing the issue number and nothing else" "$out" "17"
assert_contains "creates the severity label" "$(cat "$filed")" "label create review:major"
assert_contains "and the triage label" "$(cat "$filed")" "label create needs-triage"
assert_contains "creating ours over one that exists already" \
  "$(cat "$filed")" "label create review:major --force"
assert_eq "and leaving the repo's own triage label as the repo has it" \
  "$(grep -c 'label create needs-triage --force' "$filed")" "0"
assert_contains "passes the title through unprefixed" \
  "$(cat "$filed")" "title=Comment drifted from the code"
assert_contains "labels the issue with the severity" "$(cat "$filed")" "label=review:major"
assert_contains "and with needs-triage" "$(cat "$filed")" "label=needs-triage"
assert_contains "and sends the body file's contents" "$(cat "$filed")" "The reviewer said this."
assert_eq "the two labels never reached a real gh subprocess" \
  "$(grep -cx label "$log")" "0"
assert_eq "nor did the issue create" \
  "$(grep -cx issue "$log")" "0"

: >"$filed"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" \
  "$ORCH" review file nit "Rename it" --body-file "$body" 2>&1)"; st=$?
assert_status "files a nit" "$st" 0
assert_contains "under the nit label" "$(cat "$filed")" "label=review:nit"

: >"$filed"
out="$(GH_STUB_FILED="$filed" "$ORCH" review file blocking "Wrong" --body-file "$body" 2>&1)"; st=$?
assert_status "refuses a blocking severity - the loop fixes those" "$st" 1
assert_contains "naming what it accepts" "$out" "major"
assert_eq "and nothing reaches gh" "$(grep -c . "$filed")" "0"

out="$(GH_STUB_FILED="$filed" "$ORCH" review file major "" --body-file "$body" 2>&1)"; st=$?
assert_status "refuses an empty title" "$st" 1
assert_eq "before anything reaches gh" "$(grep -c . "$filed")" "0"

out="$(GH_STUB_FILED="$filed" "$ORCH" review file major "Title" --body-file /nonexistent/body.md 2>&1)"; st=$?
assert_status "refuses a body file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and files nothing" "$(grep -c . "$filed")" "0"

out="$(GH_STUB_FILED="$filed" "$ORCH" review file major "Title" "$body" 2>&1)"; st=$?
assert_status "insists on --body-file rather than guessing a positional" "$st" 1

out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" GH_STUB_ISSUE_EXIT=1 \
  "$ORCH" review file major "Title" --body-file "$body" 2>&1)"; st=$?
assert_status "a gh that will not create the issue fails the command" "$st" 1
assert_eq "with no number printed for a record to cite" \
  "$(printf '%s\n' "$out" | grep -cx '[0-9][0-9]*')" "0"

out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" GH_STUB_MODE=labelfail \
  "$ORCH" review file major "Title" --body-file "$body" 2>&1)"; st=$?
assert_status "a gh that will not create the label fails it too" "$st" 1

# The triage label is the repo's vocabulary, read from the doc the spec phase
# labels from: a repo that renamed it must not get a second label the name
# this plugin happens to know.
: >"$filed"
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready   |' >docs/agents/triage-labels.md
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" \
  "$ORCH" review file nit "Rename it" --body-file "$body" 2>&1)"; st=$?
assert_status "files under a renamed triage label" "$st" 0
assert_contains "creating the repo's name for it" "$(cat "$filed")" "label create triage me"
assert_contains "and applying it" "$(cat "$filed")" "label=triage me"
assert_eq "rather than the canonical one" "$(grep -c 'needs-triage' "$filed")" "0"
labels_doc docs/agents/triage-labels.md

# --- gh adapter (real, unset ORCH_GH_ADAPTER) --------------------------------
# The rest of this section proved the seam through the in-memory fake; this is
# the narrow counterpart proving the real half still works - ORCH_GH_ADAPTER
# left unset, so the adapter functions defined in orch.sh itself are the ones
# that run, and each has to actually shell out to the real `gh` subcommand
# with the right arguments rather than merely compile.
echo
echo "gh adapter (real label-create, subprocess gh)"
: >"$filed"
log="$(mktemp)"
out="$(GH_STUB_FILED="$filed" GH_STUB_LOG="$log" GH_STUB_ISSUE_NUMBER=51 \
  "$ORCH" review file major "Shells out for real" --body-file "$body" 2>&1)"; st=$?
assert_status "files through the real adapter" "$st" 0
assert_eq "printing the issue number gh answered" "$out" "51"
assert_contains "the real adapter invoked gh label create for the severity label" \
  "$(cat "$filed")" "label create review:major --force --color d93f0b --description Review finding filed at major severity"
assert_contains "and for the triage label" \
  "$(cat "$filed")" "label create needs-triage --color e4e669 --description Not yet triaged"
assert_eq "gh itself was invoked once per label, as a real subprocess" \
  "$(grep -cx label "$log")" "2"

echo
echo "gh adapter (real issue create, subprocess gh)"
assert_contains "the real adapter invoked gh issue create with the title" \
  "$(cat "$filed")" "title=Shells out for real"
assert_contains "the severity label" "$(cat "$filed")" "label=review:major"
assert_contains "and the body file's contents" "$(cat "$filed")" "The reviewer said this."
assert_eq "gh itself was invoked once for the issue create, as a real subprocess" \
  "$(grep -cx issue "$log")" "1"

: >"$filed"
out="$(GH_STUB_FILED="$filed" GH_STUB_MODE=labelfail \
  "$ORCH" review file major "Title" --body-file "$body" 2>&1)"; st=$?
assert_status "and a real gh that refuses the label still fails the command" "$st" 1

# --- spec ---------------------------------------------------------------------
# The spec review's one hand on GitHub: fetch the body, replace it, comment on
# it. The number comes from state so a review can never touch the wrong issue,
# and the stub records what reached gh so the test asserts the body sent, not
# only that the command exited zero.
#
# View/edit/comment go through the ORCH_GH_ADAPTER seam here, pointed at the
# in-memory fake (scripts/test/gh_adapter_fake.sh) rather than stub_gh - GH_STUB_LOG
# stays empty across every call below, proving none of the three ever spawns a
# real gh subprocess. The subprocess-real counterpart lives in its own "gh
# adapter (real issue view/edit/comment, subprocess gh)" block right after
# this section.
echo
echo "spec"
spec_body="$(mktemp)"
out="$("$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "fetch refuses when state records no issue" "$st" 1
assert_contains "naming the phase that records one" "$out" "spec phase"
out="$("$ORCH" spec update "$spec_body" 2>&1)"; st=$?
assert_status "update refuses too" "$st" 1
assert_contains "for the same reason" "$out" "spec phase"
out="$("$ORCH" spec comment "$spec_body" 2>&1)"; st=$?
assert_status "and comment" "$st" 1
assert_contains "likewise" "$out" "spec phase"

"$ORCH" state set issue 14
filed="$(mktemp)"
# A body with everything a heredoc or a shell quote would mangle: a table, a
# fence, a `#nn` reference. What the lenses read must be what GitHub holds.
tricky="$(mktemp)"
writeln '## Solution' '' \
        '| Lens | Reads |' '|---|---|' '| Fidelity | plan handoff |' '' \
        '```sh' 'orch.sh spec fetch "$file"' '```' '' \
        'Tracked in #6; see `$HOME` and '"'"'quoted'"'"' text.' >"$tricky"
rm -f "$spec_body"
log="$(mktemp)"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" GH_STUB_LOG="$log" \
  GH_STUB_BODY="$(cat "$tricky")" "$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "fetch writes the body to the file" "$st" 0
assert_eq "exactly as gh answered it - table, fence, and #nn survive" \
  "$(cat "$spec_body")" "$(cat "$tricky")"
assert_contains "asking gh for the issue state records" "$(cat "$filed")" "issue view 14"
assert_contains "and for its body alone" "$(cat "$filed")" "--json body"
assert_eq "the view call never reached a real gh subprocess" "$(grep -cx issue "$log")" "0"

# The skill fetches into a fresh directory under .orchestrator/, so the first
# fetch of a review is the one that has to create it.
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" "$ORCH" spec fetch .orchestrator/spec-review/spec.md 2>&1)"; st=$?
assert_status "fetch creates the directory it is told to write into" "$st" 0
assert_eq "and the body lands there" "$(cat .orchestrator/spec-review/spec.md)" "Body of the issue."
rm -rf .orchestrator/spec-review

rm -f "$spec_body"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_VIEW_EXIT=1 "$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "a gh that will not answer fails the fetch" "$st" 1
assert_contains "with the reason" "$out" "issue view refused"
assert_eq "and leaves no file a lens could mistake for a body" \
  "$([ -e "$spec_body" ] && echo present || echo gone)" "gone"

: >"$filed"
log="$(mktemp)"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" GH_STUB_LOG="$log" \
  "$ORCH" spec update "$tricky" 2>&1)"; st=$?
assert_status "update replaces the body" "$st" 0
assert_contains "of the issue state records" "$(cat "$filed")" "issue edit 14"
assert_contains "with the file's contents as the body" \
  "$(cat "$filed")" 'orch.sh spec fetch "$file"'
assert_eq "and prints nothing" "$out" ""
assert_eq "the edit call never reached a real gh subprocess" "$(grep -cx issue "$log")" "0"

: >"$filed"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" "$ORCH" spec update /nonexistent/body.md 2>&1)"; st=$?
assert_status "update refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and nothing reaches gh" "$(grep -c . "$filed")" "0"

out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_EDIT_EXIT=1 "$ORCH" spec update "$tricky" 2>&1)"; st=$?
assert_status "a gh that will not edit fails the update" "$st" 1
assert_contains "with gh's reason" "$out" "issue edit refused"
assert_contains "and the issue it was for" "$out" "issue #14"

: >"$filed"
log="$(mktemp)"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" GH_STUB_LOG="$log" \
  "$ORCH" spec comment "$tricky" 2>&1)"; st=$?
assert_status "comment posts the file" "$st" 0
assert_contains "on the issue state records" "$(cat "$filed")" "issue comment 14"
assert_contains "with the file's contents as the comment" \
  "$(cat "$filed")" "| Fidelity | plan handoff |"
assert_eq "the comment call never reached a real gh subprocess" "$(grep -cx issue "$log")" "0"

: >"$filed"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" "$ORCH" spec comment /nonexistent/body.md 2>&1)"; st=$?
assert_status "comment refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and nothing reaches gh" "$(grep -c . "$filed")" "0"

out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_COMMENT_EXIT=1 "$ORCH" spec comment "$tricky" 2>&1)"; st=$?
assert_status "a gh that will not comment fails it" "$st" 1
assert_contains "with gh's reason" "$out" "issue comment refused"
assert_contains "and the issue it was for" "$out" "issue #14"

out="$("$ORCH" spec publish "$tricky" 2>&1)"; st=$?
assert_status "refuses an op it does not have" "$st" 1
assert_contains "naming the three it does" "$out" "fetch|update|comment"
out="$("$ORCH" spec fetch 2>&1)"; st=$?
assert_status "and a call with no file" "$st" 1
assert_contains "with the usage" "$out" "usage: orch.sh spec"
assert_contains "help documents the spec verb" "$("$ORCH" help)" "spec fetch"

# --- gh adapter (real issue view/edit/comment, subprocess gh) ---------------
# The rest of the "spec" section proved the seam through the in-memory fake;
# this is the narrow counterpart proving the real half still works -
# ORCH_GH_ADAPTER left unset, so the adapter functions defined in orch.sh
# itself are the ones that run, and each has to actually shell out to the
# real `gh issue view`/`edit`/`comment` with the right arguments rather than
# merely compile.
echo
echo "gh adapter (real issue view/edit/comment, subprocess gh)"
: >"$filed"
log="$(mktemp)"
out="$(GH_STUB_FILED="$filed" GH_STUB_LOG="$log" GH_STUB_BODY="Real body." \
  "$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "fetch shells out for real" "$st" 0
assert_eq "and reads back what the real gh answered" "$(cat "$spec_body")" "Real body."
assert_contains "the real adapter invoked gh issue view on the state's issue" \
  "$(cat "$filed")" "issue view 14"
assert_contains "asking for the body alone" "$(cat "$filed")" "--json body"

: >"$filed"
out="$(GH_STUB_FILED="$filed" GH_STUB_LOG="$log" "$ORCH" spec update "$tricky" 2>&1)"; st=$?
assert_status "update shells out for real" "$st" 0
assert_contains "the real adapter invoked gh issue edit on the state's issue" \
  "$(cat "$filed")" "issue edit 14"
assert_contains "with the file's contents as the body" \
  "$(cat "$filed")" 'orch.sh spec fetch "$file"'

: >"$filed"
out="$(GH_STUB_FILED="$filed" GH_STUB_LOG="$log" "$ORCH" spec comment "$tricky" 2>&1)"; st=$?
assert_status "comment shells out for real" "$st" 0
assert_contains "the real adapter invoked gh issue comment on the state's issue" \
  "$(cat "$filed")" "issue comment 14"
assert_contains "with the file's contents as the comment" \
  "$(cat "$filed")" "| Fidelity | plan handoff |"
assert_eq "gh itself was invoked once each for view, edit, and comment, as real subprocesses" \
  "$(grep -cx issue "$log")" "3"

"$ORCH" state set issue null

# --- doctor at the review phase ---------------------------------------------
# Three handoffs are due from review onwards, and only three: a flow started
# under the old loop machinery carries a `loop` key doctor neither reports nor
# touches, and is asked for no handoff a loop would have written.
echo
echo "doctor at the review phase"
complete_plan_handoff "$("$ORCH" handoff path spec)"
complete_spec_handoff "$("$ORCH" handoff path implement)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a review-phase flow with its three handoffs is healthy" "$st" 0
assert_contains "counts the implement handoff among them" "$out" "handoff 03-implement.md complete"

"$ORCH" state set loop 2
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a stray loop key from an older flow still passes" "$st" 0
assert_eq "and earns no mention of a handoff no loop writes any more" \
  "$(printf '%s\n' "$out" | grep -c '04-review.md')" "0"
assert_eq "nor a line reporting the key" \
  "$(printf '%s\n' "$out" | grep -c 'loop: 2')" "0"
assert_eq "and the key is left as it was" "$("$ORCH" state get loop)" "2"

# The per-loop record directories an older flow left behind are the other
# artefact story 37 names: ignored, not moved, and never a reason to fail.
mkdir -p .orchestrator/review/loop-01
: > .orchestrator/review/loop-01/iteration-01.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a stray review/loop-NN/ directory from an older flow still passes" "$st" 0
assert_eq "and earns no line of its own" \
  "$(printf '%s\n' "$out" | grep -c 'loop-01')" "0"
assert_eq "and is left where it was" \
  "$([ -f .orchestrator/review/loop-01/iteration-01.md ] && echo present || echo gone)" "present"

# --- review ready -----------------------------------------------------------
# Marking the PR ready and recording the flow as done are one operation, because
# either half alone is a lie: a `done` flow over a draft PR, or a PR promoted out
# of draft by a flow that still thinks it is reviewing.
#
# Goes through the ORCH_GH_ADAPTER seam here, pointed at the in-memory fake
# rather than stub_gh - GH_STUB_LOG stays empty across both calls, proving
# neither reaches a real gh subprocess. The subprocess-real counterpart is the
# "gh adapter (real pr ready, subprocess gh)" block right after this one.
echo
echo "review ready"
"$ORCH" state set pr 7
log="$(mktemp)"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_LOG="$log" GH_STUB_READY_EXIT=1 "$ORCH" review ready 2>&1)"; st=$?
assert_status "fails when GitHub will not mark the PR ready" "$st" 1
assert_eq "and leaves the phase where it was rather than half-finishing" \
  "$("$ORCH" state get phase)" "review"
ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_LOG="$log" "$ORCH" review ready >/dev/null
assert_eq "records the flow as done once the PR is ready" "$("$ORCH" state get phase)" "done"
assert_eq "and neither call ever reached a real gh subprocess" "$(grep -cx pr "$log")" "0"
"$ORCH" state set phase review

# --- gh adapter (real pr ready, subprocess gh) -------------------------------
# The block above proved the seam through the in-memory fake; this is the
# narrow counterpart proving the real half still works - ORCH_GH_ADAPTER left
# unset, so orch.sh's own adapter_pr_ready runs and has to actually shell out
# to `gh pr ready` rather than merely compile.
echo
echo "gh adapter (real pr ready, subprocess gh)"
log="$(mktemp)"
out="$(GH_STUB_LOG="$log" "$ORCH" review ready 2>&1)"; st=$?
assert_status "shells out for real" "$st" 0
assert_eq "records the flow as done" "$("$ORCH" state get phase)" "done"
assert_eq "the real adapter invoked gh pr ready, as a real subprocess" \
  "$(grep -cx pr "$log")" "1"
"$ORCH" state set phase review

# --- review ci --------------------------------------------------------------
# The classification is what decides whether a PR may be marked ready, so each
# of the four answers is asserted for its exit status as well as its word.
#
# ci_probe's `gh pr checks` calls go through the ORCH_GH_ADAPTER seam here,
# pointed at the in-memory fake rather than stub_gh - a GH_STUB_LOG check right
# after the first call proves it never spawns a real gh subprocess. The
# subprocess-real counterpart, including the required-vs-all-checks
# distinction and the exit-8 handling specifically, is the "gh adapter (real
# pr checks, subprocess gh)" block right after this section.
echo
echo "review ci"
export ORCH_CI_GRACE=0.3 ORCH_CI_TIMEOUT=1 ORCH_CI_INTERVAL=0.05
export ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE"
log="$(mktemp)"
out="$(GH_STUB_LOG="$log" GH_STUB_CHECKS=green "$ORCH" review ci 2>&1)"; st=$?
assert_status "green checks let the loop finish" "$st" 0
assert_first_line "and say so in one word" "$out" "green"
assert_eq "the checks call never reached a real gh subprocess" "$(grep -cx pr "$log")" "0"

out="$(GH_STUB_CHECKS=failing "$ORCH" review ci 2>&1)"; st=$?
assert_status "a failing check stops the loop" "$st" 1
assert_first_line "classified as failing" "$out" "failing"
assert_contains "names the check that failed" "$out" "build"
assert_eq "and not the ones that passed" "$(printf '%s\n' "$out" | grep -c 'lint')" "0"

# A cancelled run is not a run that passed, and it is never going to report. It
# classifies as failing, which is also the arm that offers the flake rerun - the
# right remedy for a check that was killed rather than one that judged the change.
out="$(GH_STUB_CHECKS=cancel "$ORCH" review ci 2>&1)"; st=$?
assert_status "a cancelled check stops the loop too" "$st" 1
assert_first_line "classified as failing rather than waited on" "$out" "failing"
assert_contains "naming the check that was cancelled" "$out" "build"

# Requiring CI in a repo that has none would make the plugin unusable in its own
# repo, which has none.
out="$(GH_STUB_CHECKS=none "$ORCH" review ci 2>&1)"; st=$?
assert_status "a repo with no checks at all is not thereby failing" "$st" 0
assert_first_line "classified as none" "$out" "none"

# The grace period is the whole reason `none` is not concluded on the first
# answer: this is the CI-having repo that would otherwise be called CI-less. It
# is spent on the *required* probe, because gh reports "no required checks"
# whether the repo requires nothing or requires something that has not landed
# yet. Widening to every check on the commit before the grace is out is how an
# unrelated green check gets mistaken for a required one that never arrived - so
# the unfiltered answer here is `failing`, and a green result proves it was never
# consulted. The grace is set well clear of a whole-second wall-clock tick, so
# what the test proves is the second answer winning rather than how fast the
# first one came.
reqn="$(mktemp)"; : >"$reqn"
out="$(ORCH_CI_GRACE=5 GH_STUB_REQUIRED_N="$reqn" GH_STUB_REQUIRED='none|green' \
  GH_STUB_CHECKS=failing "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "a required check that has not registered yet is waited for" "$out" "green"
assert_status "and the loop finishes on the answer it waited for" "$st" 0

# Where branch protection names required checks, those are the checks that
# matter - and a failure outside them is not the flow's business.
out="$(GH_STUB_REQUIRED=green GH_STUB_CHECKS=failing "$ORCH" review ci 2>&1)"; st=$?
assert_status "required checks decide it where branch protection names them" "$st" 0
assert_first_line "so the unfiltered answer is never asked for" "$out" "green"

# ...and where it names none, the answer is every check on the commit, but only
# once the grace has run out.
out="$(ORCH_CI_GRACE=0.2 GH_STUB_REQUIRED=none GH_STUB_CHECKS=green \
  "$ORCH" review ci 2>&1)"; st=$?
assert_status "a repo that requires nothing falls back to every check" "$st" 0
assert_first_line "reading the commit's own checks for its answer" "$out" "green"

out="$(GH_STUB_CHECKS=boom "$ORCH" review ci 2>&1)"; st=$?
assert_status "an API that will not answer stops the loop" "$st" 1
assert_first_line "classified as unreachable" "$out" "unreachable"
assert_contains "carrying the reason it could not be asked" "$out" "dial tcp"

# doctor's "an unreachable API is a warn" rule was written for a read-only
# diagnostic. Here the outcome is an action, so an answer that never arrived
# cannot be treated as a green one.
out="$(ORCH_CI_TIMEOUT=0.2 GH_STUB_CHECKS=pending "$ORCH" review ci 2>&1)"; st=$?
assert_status "checks still pending at the cap stop the loop" "$st" 1
assert_first_line "rather than being read as green" "$out" "unreachable"
assert_contains "and it says the wait ran out" "$out" "still pending"

# The same wait, reached the way real gh reports it. `gh pr checks --json` exits
# 0 whatever the buckets hold, so the exit-8 arm above is the path the stub
# takes and this is the path the live command takes - and until both are
# asserted, the classifier's bucket-reading half ships unexercised.
out="$(ORCH_CI_TIMEOUT=0.2 GH_STUB_CHECKS=pending0 "$ORCH" review ci 2>&1)"; st=$?
assert_status "a pending bucket is a wait even when gh exits 0" "$st" 1
assert_first_line "classified from the bucket rather than the exit status" "$out" "unreachable"
assert_contains "and says the same thing the exit-8 path says" "$out" "still pending"

# The clocks are compared with awk, which compares a number against a
# non-numeric string as strings - so a mistyped knob makes every comparison
# true, and the one command written to be bounded polls GitHub until something
# else kills it. The leash is what makes this assertable: without the fix the
# command never returns on its own.
out="$(ORCH_CI_GRACE=oops timeout 5 "$ORCH" review ci 2>&1)"; st=$?
assert_status "a grace that is not a number stops the command, not the clock" "$st" 1
assert_contains "naming the knob it could not read" "$out" "ORCH_CI_GRACE"

# A zero interval passes for a number and still defeats the bound: `sleep 0`
# returns at once and never advances the clock, so the loop polls as fast as
# GitHub answers for the whole timeout.
out="$(ORCH_CI_INTERVAL=0 timeout 5 "$ORCH" review ci 2>&1)"; st=$?
assert_status "an interval of zero is refused rather than busy-polled" "$st" 1
assert_contains "saying the interval has to be above zero" "$out" "greater than zero"

# The one direction this classifier must never fail in: an answer nobody could
# read is not an answer that there is nothing to read.
out="$(GH_STUB_CHECKS=garbage "$ORCH" review ci 2>&1)"; st=$?
assert_status "output jq cannot parse stops the loop" "$st" 1
assert_first_line "rather than passing as a repo with no checks" "$out" "unreachable"
assert_contains "saying what it could not read" "$out" "could not read"

"$ORCH" state set pr null
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "refuses to classify checks on a PR that does not exist yet" "$st" 1
# require_pr dies inside a command substitution, so what stops the command is
# `set -e` on the assignment rather than the exit itself. Asserting the message
# is what would catch the guard degrading into an empty PR number.
assert_contains "saying which phase was supposed to open it" "$out" "the implement phase opens it"
unset ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL ORCH_GH_ADAPTER

# --- gh adapter (real pr checks, subprocess gh) -------------------------------
# The "review ci" section above proved ci_probe's decision logic through the
# in-memory fake; this is the narrow counterpart proving the real half still
# works - ORCH_GH_ADAPTER left unset, so orch.sh's own adapter_pr_checks runs
# and has to actually shell out to `gh pr checks` with the right arguments.
# Covers what a fake cannot prove on its own: that the required-scope call and
# the all-checks call are two distinct real `gh pr checks` invocations (one
# with --required, one without), and that the exit-8-for-pending path a real
# gh can take is read the same way the exit-0-with-a-pending-bucket path is.
echo
echo "gh adapter (real pr checks, subprocess gh)"
"$ORCH" state set pr 7
export ORCH_CI_GRACE=0.2 ORCH_CI_TIMEOUT=1 ORCH_CI_INTERVAL=0.05
log="$(mktemp)"
out="$(GH_STUB_LOG="$log" GH_STUB_REQUIRED=green GH_STUB_CHECKS=failing "$ORCH" review ci 2>&1)"; st=$?
assert_status "shells out for real and finishes on the required probe" "$st" 0
assert_first_line "reading green from the required-scope call" "$out" "green"
assert_eq "gh pr checks was invoked once, for the required scope only" \
  "$(grep -cx pr "$log")" "1"

# Grace of exactly zero means the very first `float_lt elapsed grace` reads
# false, so the loop widens on the spot instead of ticking first - the one
# grace value that pins the required call at exactly once before it does, so
# the count below proves the two are genuinely separate real `gh` invocations
# rather than however many required retries the grace window happened to fit.
log="$(mktemp)"
out="$(GH_STUB_LOG="$log" ORCH_CI_GRACE=0 GH_STUB_REQUIRED=none GH_STUB_CHECKS=green \
  "$ORCH" review ci 2>&1)"; st=$?
assert_status "and falls back to the all-checks call once the grace runs out" "$st" 0
assert_first_line "reading green from the unfiltered call" "$out" "green"
assert_eq "gh pr checks was invoked twice - once required, once for every check" \
  "$(grep -cx pr "$log")" "2"

log="$(mktemp)"
out="$(GH_STUB_LOG="$log" ORCH_CI_TIMEOUT=0.2 GH_STUB_REQUIRED=pending "$ORCH" review ci 2>&1)"; st=$?
assert_status "a real gh's documented exit-8-for-pending stops the loop at the cap" "$st" 1
assert_first_line "classified as unreachable, same as the fake's exit-8 path" "$out" "unreachable"
assert_contains "saying the wait ran out" "$out" "still pending"
unset ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL
"$ORCH" state set pr null

# --- a flow from before the budget shipped ----------------------------------
# An in-flight flow carries whatever state the version that started it wrote:
# no `budget`, no `loop`, no `flake_rerun_used`. Failing on any absence would
# strand exactly the flows this change was meant to finish.
echo
echo "a flow started before the budget shipped"
healthy_repo
"$ORCH" init legacy >/dev/null
legacy="$(mktemp)"
jq 'del(.budget, .loop, .flake_rerun_used)' .orchestrator/state.json >"$legacy"
mv "$legacy" .orchestrator/state.json
assert_eq "the state it left behind names no budget" "$("$ORCH" state get budget)" ""
assert_eq "review begin still claims an iteration" "$("$ORCH" review begin)" "1"
assert_contains "records land flat under review/" "$("$ORCH" review path)" "/review/iteration-01.md"
assert_contains "and review reads the implement handoff as it always did" \
  "$("$ORCH" handoff path review)" "03-implement.md"
for i in 2 3 4 5; do "$ORCH" review begin >/dev/null; done
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and it runs the default budget" "$st" 1
assert_contains "of five" "$out" "budget of 5 iterations"

"$ORCH" state set phase review
complete_plan_handoff "$("$ORCH" handoff path spec)"
complete_spec_handoff "$("$ORCH" handoff path implement)"
complete_implement_handoff "$("$ORCH" handoff path review)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor does not strand it either" "$st" 0
assert_contains "status reads its budget as the default" "$("$ORCH" status)" "iteration 5 of 5"

# ci and ready need a PR, which a flow this old still records the same way.
"$ORCH" state set pr 3 >/dev/null
out="$(ORCH_CI_GRACE=0.2 ORCH_CI_INTERVAL=0.05 GH_STUB_CHECKS=green \
  "$ORCH" review ci 2>&1)"; st=$?
assert_status "review ci reads its PR from a state with no budget key" "$st" 0
assert_first_line "and classifies it" "$out" "green"
assert_eq "review ready marks the PR and finishes the flow" \
  "$("$ORCH" review ready)" "3"
assert_eq "recording done as it goes" "$("$ORCH" state get phase)" "done"

# --- init seeds the review loop ---------------------------------------------
echo
echo "init seeds the review loop"
healthy_repo
"$ORCH" init seeded >/dev/null
assert_eq "a flow starts with no loop counter" \
  "$("$ORCH" state get | jq -r 'has("loop")')" "false"
assert_eq "and no budget until a human names one" "$("$ORCH" state get budget)" ""
assert_eq "with somewhere to file its records" \
  "$([ -d .orchestrator/review ] && echo present || echo gone)" "present"
assert_eq "and no per-loop directory under it" \
  "$([ -e .orchestrator/review/loop-01 ] && echo present || echo gone)" "gone"
# The flake rerun belongs to the flow, so it is seeded once here and never
# refilled. `state get` reads a JSON false back as empty, which is the shape the
# review skill tests against - spent is "true", and anything else is unspent.
assert_eq "and one flake rerun unspent" \
  "$("$ORCH" state get | jq -r '.flake_rerun_used')" "false"
assert_eq "which reads as unspent through state get" \
  "$("$ORCH" state get flake_rerun_used)" ""
"$ORCH" state set flake_rerun_used true
assert_eq "and as spent once it has been" \
  "$("$ORCH" state get flake_rerun_used)" "true"

# redo_count is what answers "how many times has this flow been redone" once
# a redo has happened - iteration alone no longer can.
assert_eq "a fresh flow has never been redone" "$("$ORCH" state get redo_count)" "0"
assert_eq "recorded as a number, not a string" \
  "$("$ORCH" state get | jq -r '.redo_count | type')" "number"

assert_contains "status names the iteration against the default budget" \
  "$("$ORCH" status)" "iteration 0 of 5"
"$ORCH" state set budget 3
"$ORCH" state set iteration 2
assert_contains "and against the budget once one is set" \
  "$("$ORCH" status)" "iteration 2 of 3"
assert_contains "status shows how many times the flow has been redone" \
  "$("$ORCH" status)" "redo:      0"
"$ORCH" state set redo_count 2
assert_contains "and updates once it has been" "$("$ORCH" status)" "redo:      2"
assert_contains "help documents the review verb" "$("$ORCH" help)" "review begin"
assert_contains "and the CI classifier's outcomes" "$("$ORCH" help)" "review ci"
assert_contains "and filing" "$("$ORCH" help)" "review file"
assert_contains "and the terminal-state classifier" "$("$ORCH" help)" "review terminal"
assert_contains "and retiring a loop's records" "$("$ORCH" help)" "review retire"
assert_contains "help documents issue publish" "$("$ORCH" help)" "issue publish"
assert_contains "and pr publish" "$("$ORCH" help)" "pr publish"
assert_contains "and ticket publish" "$("$ORCH" help)" "ticket publish"
assert_contains "and ticket next" "$("$ORCH" help)" "ticket next"
assert_contains "and ticket close" "$("$ORCH" help)" "ticket close"
assert_contains "and ticket reset" "$("$ORCH" help)" "ticket reset"
assert_contains "and retiring a branch" "$("$ORCH" help)" "branch retire"
assert_contains "and creating one" "$("$ORCH" help)" "branch create"
assert_contains "and forking one for a quick implementation" "$("$ORCH" help)" "branch off"
assert_contains "and opening a draft PR" "$("$ORCH" help)" "pr open"
assert_contains "and redo review" "$("$ORCH" help)" "redo review"
assert_contains "and redo spec" "$("$ORCH" help)" "redo spec"
assert_eq "and no longer the loop machinery" "$("$ORCH" help | grep -c 'loop-next')" "0"

# --- review terminal ----------------------------------------------------
# The one classifier `review terminal` and doctor's check both read - none and
# pending need no iteration file at all, interrupted/ready/stop all do.
echo
echo "review terminal"
healthy_repo
"$ORCH" init terminaltest >/dev/null

out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "no loop yet is not terminal" "$st" 1
assert_first_line "and classifies as none" "$out" "none"

"$ORCH" state set iteration 3
"$ORCH" state set budget 5
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "short of its budget is not terminal" "$st" 1
assert_first_line "and classifies as pending" "$out" "pending"

"$ORCH" state set iteration 5
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "at budget with no iteration record is not terminal" "$st" 1
assert_first_line "classified as interrupted, not pending" "$out" "interrupted"

mkdir -p .orchestrator/review
: >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a record with no Terminal state heading is still interrupted" "$st" 1
assert_first_line "not silently read as done" "$out" "interrupted"

writeln '## Terminal state' '' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "an empty Terminal state section is interrupted too" "$st" 1
assert_first_line "same as a missing one" "$out" "interrupted"

writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a ready heading is terminal" "$st" 0
assert_first_line "and classifies as ready" "$out" "ready"

writeln '## Terminal state' 'stop' 'CI failed twice, flake rerun spent.' \
  >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a stop heading is terminal too" "$st" 0
assert_first_line "classified as stop" "$out" "stop"
assert_contains "carrying the recorded reason on the lines after it" \
  "$out" "CI failed twice, flake rerun spent."

out="$("$ORCH" review terminal extra 2>&1)"; st=$?
assert_status "takes no arguments" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh review terminal"

# --- doctor: review terminal check --------------------------------------
# check_flow_pr's open/closed/unreadable branching is the direct template:
# ok/warn on the classification, and phase-gated silent outside review.
echo
echo "doctor: review terminal check"
healthy_repo
"$ORCH" init doctorterm >/dev/null
complete_plan_handoff "$("$ORCH" handoff path spec)"
complete_spec_handoff "$("$ORCH" handoff path implement)"
"$ORCH" state set phase implement
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "implement phase still passes" "$st" 0
assert_eq "and says nothing about a review loop" \
  "$(printf '%s\n' "$out" | grep -c 'review loop')" "0"

complete_implement_handoff "$("$ORCH" handoff path review)"
"$ORCH" state set phase review
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "no loop yet is healthy" "$st" 0
assert_contains "reports the loop has not started" "$out" "review loop: not started yet"

"$ORCH" state set iteration 2
"$ORCH" state set budget 5
out="$(ORCHESTRATOR_HOST=junie "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "short of budget warns, never fails" "$st" 0
assert_contains "names the iteration and budget" "$out" "iteration 2 of budget 5"
assert_contains "reads as pending, not interrupted" "$out" "hasn't reached its budget yet"
assert_contains "points at next for resuming it" "$out" "/orchestrator:next (or orch-flow's Next phase section) will resume it"
assert_contains "and says redo refuses until it is terminal" "$out" "redo refuses until it reaches a terminal state"

"$ORCH" state set iteration 5
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "at budget with no terminal record warns rather than fails" "$st" 0
assert_contains "reads as interrupted, not pending" "$out" "looks interrupted, not stopped"

mkdir -p .orchestrator/review
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a ready record is healthy" "$st" 0
assert_contains "names it a terminal state" "$out" "review loop at a terminal state: ready"

writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a stop record is healthy too" "$st" 0
assert_contains "names the terminal state and its reason" \
  "$out" "review loop at a terminal state: stop (CI failed twice.)"

# --- doctor: review budget check -----------------------------------------
# review begin's own `die` at budget is what is meant to make an iteration
# past it unreachable - this check is for the state.json that got there some
# other way, not one review begin produced itself.
echo
echo "doctor: review budget check"
"$ORCH" state set iteration 3
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "short of budget is healthy" "$st" 0
assert_contains "reports it within budget" "$out" "review loop iteration (3) within budget (5)"

"$ORCH" state set iteration 6
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "past budget fails" "$st" 1
assert_contains "names the impossible count" "$out" \
  "review loop iteration (6) is past its budget (5)"
assert_contains "and points at abort" "$out" "/orchestrator:abort"
"$ORCH" state set iteration 5

# --- doctor: review ci check ----------------------------------------------
# ci_probe is the loop's own read of the PR's checks, reused rather than a
# second query of the same endpoint - so its five answers are the five cases
# here, not a fresh classification doctor derives on its own.
echo
echo "doctor: review ci check"
"$ORCH" state set pr 40
# A draft PR mid-review agrees with the phase, so the draft check stays quiet
# and only the CI check's own verdict decides the exit status below.
export GH_STUB_PR_DRAFT=true

out="$(GH_STUB_REQUIRED=green "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "green required checks are healthy" "$st" 0
assert_contains "reports it" "$out" "CI: required checks green"

out="$(GH_STUB_REQUIRED=none "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "no required checks reported is not a failure" "$st" 0
assert_contains "reports it" "$out" "CI: no required checks reported"

out="$(GH_STUB_REQUIRED=pending "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "pending required checks are not a failure yet" "$st" 0
assert_contains "reports it" "$out" "CI: required checks still pending"

out="$(GH_STUB_REQUIRED=failing "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a failing required check fails doctor" "$st" 1
assert_contains "names the PR" "$out" "CI: required check(s) failing on PR #40"
assert_contains "carries the failing check's name" "$out" "build"
assert_contains "gives the command that shows it" "$out" "gh pr checks 40"

out="$(GH_STUB_REQUIRED=boom "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an unreachable API warns rather than fails" "$st" 0
assert_contains "reports it" "$out" "CI: could not be read from GitHub for PR #40"
assert_contains "carrying the reason" "$out" "dial tcp"

# --- doctor: review draft check -------------------------------------------
# `review ready` marks the PR ready and records phase: done as one operation,
# so isDraft and phase disagreeing on GitHub's own PR is evidence that
# operation only half landed.
echo
echo "doctor: review draft check"
out="$(GH_STUB_PR_DRAFT=true "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a draft PR mid-review is healthy" "$st" 0
assert_contains "reports it matches phase" "$out" \
  "PR #40 draft state matches phase (review)"

out="$(GH_STUB_PR_DRAFT=false "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a PR marked ready while still in review fails" "$st" 1
assert_contains "names the mismatch" "$out" \
  "PR #40 was marked ready on GitHub but the flow phase is still review"
assert_contains "gives the command that inspects it" "$out" "gh pr view 40"

"$ORCH" state set phase done
out="$(GH_STUB_PR_DRAFT=false "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a ready PR once the flow is done is healthy" "$st" 0
assert_contains "reports it matches phase" "$out" \
  "PR #40 draft state matches phase (done)"

out="$(GH_STUB_PR_DRAFT=true "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a draft PR left behind once the flow is done fails" "$st" 1
assert_contains "names the mismatch" "$out" \
  "PR #40 is still a draft but the flow phase is done"
assert_contains "gives the command that promotes it" "$out" "gh pr ready 40"

out="$(GH_STUB_PR_STATE=MERGED "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a merged PR has nothing left to disagree with" "$st" 0
assert_eq "and says nothing about draft state" \
  "$(printf '%s\n' "$out" | grep -c 'draft state')" "0"
"$ORCH" state set phase review
unset GH_STUB_PR_DRAFT

# --- review retire -------------------------------------------------------
# The archive test's directory-move assertions are the direct template.
echo
echo "review retire"
new_repo >/dev/null
"$ORCH" init retiretest >/dev/null

out="$("$ORCH" review retire 1)"
assert_contains "a no-op with nothing to move still prints the destination" \
  "$out" "/review/pre-redo-1"
assert_eq "and creates no directory for it" \
  "$([ -d .orchestrator/review/pre-redo-1 ] && echo present || echo gone)" "gone"

mkdir -p .orchestrator/review
: >.orchestrator/review/iteration-01.md
: >.orchestrator/review/iteration-02.md
out="$("$ORCH" review retire 1)"
assert_contains "moves every iteration record into pre-redo-N" \
  "$out" "/review/pre-redo-1"
assert_eq "iteration-01 landed under it" \
  "$([ -f .orchestrator/review/pre-redo-1/iteration-01.md ] && echo yes || echo no)" "yes"
assert_eq "iteration-02 landed under it too" \
  "$([ -f .orchestrator/review/pre-redo-1/iteration-02.md ] && echo yes || echo no)" "yes"
assert_eq "and the flat trail is empty afterwards" \
  "$([ -e .orchestrator/review/iteration-01.md ] && echo yes || echo no)" "no"

: >.orchestrator/review/iteration-01.md
out="$("$ORCH" review retire 1 2>&1)"; st=$?
assert_status "dies rather than collide with an existing pre-redo-N" "$st" 1
assert_contains "naming the directory" "$out" "pre-redo-1"

out="$("$ORCH" review retire nope 2>&1)"; st=$?
assert_status "refuses a non-numeric redo count" "$st" 1

out="$("$ORCH" review retire 2>&1)"; st=$?
assert_status "refuses with no argument" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh review retire"

# --- redo review ----------------------------------------------------------
# The full review -> implement transition: three distinct refusals below a
# terminal state, and a full composition above it.
#
# cmd_redo_review's PR close goes through the ORCH_GH_ADAPTER seam here,
# pointed at the in-memory fake rather than stub_gh - a GH_STUB_LOG check
# right after the first successful redo proves it never spawns a real gh
# subprocess. The subprocess-real counterpart is the "gh adapter (real pr
# close, subprocess gh)" block right after this section.
echo
echo "redo review"
export ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE"
healthy_repo
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
git remote set-url origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init redotest >/dev/null

out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "refuses outside the review phase" "$st" 1
assert_contains "naming the reason" "$out" "flow is not at the review phase"

"$ORCH" state set phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redotest
git push -q -u origin orch/21-redotest
"$ORCH" state set branch orch/21-redotest
filed="$(mktemp)"
out="$(GH_STUB_FILED="$filed" GH_STUB_PR_NUMBER=30 "$ORCH" redo review 2>&1)"; st=$?
assert_status "refuses with no loop run yet" "$st" 1
assert_contains "distinct from the other two refusals" "$out" "no review loop has run yet"
assert_eq "and nothing reaches gh" "$(grep -c . "$filed")" "0"

"$ORCH" state set iteration 2
"$ORCH" state set budget 5
out="$(ORCHESTRATOR_HOST=junie "$ORCH" redo review 2>&1)"; st=$?
assert_status "refuses a loop still short of its budget" "$st" 1
assert_contains "pointing at /orchestrator:next instead" "$out" "that's what /orchestrator:next (or orch-flow's Next phase section) is for"
# Claude Code users see the command alone, as before 1.0.0 (#121 story 2).
out="$(ORCHESTRATOR_HOST=claude "$ORCH" redo review 2>&1)"
assert_contains "names the bare command on Claude Code" "$out" "that's what /orchestrator:next is for"
out="$(env -u CLAUDE_PLUGIN_ROOT "$ORCH" redo review 2>&1)"
assert_contains "and the orch-flow section when no host is detected" "$out" "/orchestrator:next (or orch-flow's Next phase section)"

"$ORCH" state set iteration 5
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "refuses a budget-spent loop with no terminal record" "$st" 1
assert_contains "reading as interrupted, distinct from pending" "$out" "looks interrupted, not stopped"

"$ORCH" state set pr 30
"$ORCH" state set base_sha deadbeefcafe
"$ORCH" state set flake_rerun_used true
mkdir -p .orchestrator/review
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md
: >"$filed"
log="$(mktemp)"
base_before="$("$ORCH" state get base)"
out="$(GH_STUB_FILED="$filed" GH_STUB_LOG="$log" "$ORCH" redo review 2>&1)"; st=$?
assert_status "a genuinely terminal loop redoes" "$st" 0
assert_eq "keeps the flow's recorded base branch" "$("$ORCH" state get base)" "$base_before"
assert_eq "prints the new redo count" "$out" "1"
assert_eq "records it in state" "$("$ORCH" state get redo_count)" "1"
assert_eq "resets the iteration for a fresh budget" "$("$ORCH" state get iteration)" "0"
assert_eq "and clears branch, PR, and base SHA" \
  "$("$ORCH" state get branch)$("$ORCH" state get pr)$("$ORCH" state get base_sha)" ""
assert_eq "steps the flow back to implement" "$("$ORCH" state get phase)" "implement"
assert_eq "leaves the one-per-flow flake rerun untouched" \
  "$("$ORCH" state get flake_rerun_used)" "true"
assert_eq "renames the old branch aside" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-1 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and republishes it on origin" \
  "$(git -C "$bare" rev-parse --quiet --verify refs/heads/orch/21-redotest-redo-1 >/dev/null && echo present || echo gone)" "present"
assert_contains "closes the old PR" "$(cat "$filed")" "pr close 30"
assert_contains "with a comment naming the retired branch" \
  "$(cat "$filed")" "orch/21-redotest-redo-1"
assert_eq "the pr close call never reached a real gh subprocess" "$(grep -cx pr "$log")" "0"
assert_eq "moves the old loop's records aside" \
  "$([ -f .orchestrator/review/pre-redo-1/iteration-05.md ] && echo yes || echo no)" "yes"
assert_eq "leaving the flat trail empty" \
  "$([ -e .orchestrator/review/iteration-05.md ] && echo yes || echo no)" "no"

# A second redo in the same flow numbers on rather than overwriting the first.
"$ORCH" state set phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redotest orch/21-redotest-redo-1
stub_pushed_branch orch/21-redotest
"$ORCH" state set branch orch/21-redotest
"$ORCH" state set pr 31
"$ORCH" state set iteration 5
"$ORCH" state set budget 5
mkdir -p .orchestrator/review
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$(GH_STUB_PR_NUMBER=31 "$ORCH" redo review 2>&1)"; st=$?
assert_status "a second stopped loop redoes just as the first did" "$st" 0
assert_eq "and numbers on rather than repeating redo-1" "$out" "2"
assert_eq "naming the branch redo-2" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-2 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "without disturbing redo-1's records" \
  "$([ -f .orchestrator/review/pre-redo-1/iteration-05.md ] && echo yes || echo no)" "yes"
assert_eq "moving the second loop's records into pre-redo-2" \
  "$([ -f .orchestrator/review/pre-redo-2/iteration-05.md ] && echo yes || echo no)" "yes"

"$ORCH" state set phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redotest
stub_pushed_branch orch/21-redotest
"$ORCH" state set branch orch/21-redotest
"$ORCH" state set pr 32
"$ORCH" state set iteration 1
"$ORCH" state set budget 1
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-01.md
out="$(GH_STUB_PR_CLOSE_EXIT=1 GH_STUB_PR_NUMBER=32 "$ORCH" redo review 2>&1)"; st=$?
assert_status "a gh that will not close the PR fails the redo" "$st" 1
assert_contains "naming the reason" "$out" "gh could not close PR #32"
assert_eq "leaving the phase where it was rather than half-finishing" \
  "$("$ORCH" state get phase)" "review"
assert_eq "still renames the branch aside since retire runs before the pr close" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-3 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and never moves the loop's records since gh failed first" \
  "$([ -f .orchestrator/review/iteration-01.md ] && echo yes || echo no)" "yes"
# Issue #63: the rename above is real, so state.branch has to follow it
# rather than keep naming a branch retire already renamed away - otherwise a
# retried redo dies confusingly against a branch that no longer exists.
assert_eq "updates state.branch to the branch retire actually produced" \
  "$("$ORCH" state get branch)" "orch/21-redotest-redo-3"
assert_eq "and records the bumped redo_count so a retry numbers on, not over" \
  "$("$ORCH" state get redo_count)" "3"

# A retry after that failure has to work from the state the failure left
# behind, and must not retire the already-retired branch a second time -
# issue #63 acceptance criterion 3: it should pick up from closing the PR.
out="$(GH_STUB_PR_NUMBER=32 "$ORCH" redo review 2>&1)"; st=$?
assert_status "retrying redo review after the gh failure now succeeds" "$st" 0
assert_eq "reuses redo-3 rather than numbering on to redo-4" "$out" "3"
assert_eq "does not retire the branch a second time" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-4 >/dev/null 2>&1 && echo present || echo gone)" "gone"
assert_eq "leaves redo-3 as the actually-retired branch" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-3 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and clears branch, PR, and base SHA on the now-successful redo" \
  "$("$ORCH" state get branch)$("$ORCH" state get pr)$("$ORCH" state get base_sha)" ""

# A loop that ended by marking the PR ready has already moved the flow to
# phase done, in the same operation that decided "ready" - there is no real
# window where redo could ever see phase: review with a ready terminal
# record. Produced the way the system actually produces it (review ready
# itself, not a hand-crafted state), redo rejects it exactly as it would any
# other done flow, through the same phase gate, not a ready-specific branch.
"$ORCH" state set phase review
"$ORCH" state set pr 33
"$ORCH" state set iteration 1
"$ORCH" state set budget 1
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-01.md
"$ORCH" review ready >/dev/null
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "a loop that ended ready is out of scope for redo, same as any done flow" "$st" 1
assert_contains "the same phase-gate refusal as any other done flow" "$out" "flow is not at the review phase"
unset ORCH_GH_ADAPTER

# --- gh adapter (real pr close, subprocess gh) -------------------------------
# The "redo review" section above proved cmd_redo_review's PR close through
# the in-memory fake; this is the narrow counterpart proving the real half
# still works - ORCH_GH_ADAPTER left unset, so orch.sh's own adapter_pr_close
# runs and has to actually shell out to `gh pr close` with the right PR
# number and comment.
echo
echo "gh adapter (real pr close, subprocess gh)"
healthy_repo
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
git remote set-url origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init redoclose >/dev/null
"$ORCH" state set phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redoclose
git push -q -u origin orch/21-redoclose
"$ORCH" state set branch orch/21-redoclose
"$ORCH" state set pr 34
"$ORCH" state set iteration 1
"$ORCH" state set budget 1
mkdir -p .orchestrator/review
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-01.md
filed="$(mktemp)"
log="$(mktemp)"
out="$(GH_STUB_FILED="$filed" GH_STUB_LOG="$log" "$ORCH" redo review 2>&1)"; st=$?
assert_status "shells out for real" "$st" 0
assert_contains "the real adapter invoked gh pr close on the flow's PR" \
  "$(cat "$filed")" "pr close 34"
assert_eq "gh itself was invoked once for the pr close, as a real subprocess" \
  "$(grep -cx pr "$log")" "1"

# --- redo review reopens tickets -------------------------------------------
# Acceptance criterion from issue #88: a prior implement phase closes every
# ticket of the flow's spec issue as it works the frontier, so a redo back to
# implement has to reopen them - otherwise the redone implement phase's
# frontier query (ticket next) finds nothing and opens an empty PR.
echo
echo "redo review reopens tickets"
healthy_repo
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
git remote set-url origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init tickettest >/dev/null

db="$(mktemp -d)"
export GH_STUB_DB="$db"
body="$(mktemp)"; printf 'Body of the ticket.\n' >"$body"
t1="$("$ORCH" ticket publish 60 "One" "$body")"
t2="$("$ORCH" ticket publish 60 "Two" "$body")"
"$ORCH" ticket close "$t1" >/dev/null
"$ORCH" ticket close "$t2" >/dev/null
assert_eq "frontier is empty once every ticket is closed" "$("$ORCH" ticket next 60)" ""

"$ORCH" state set phase review
"$ORCH" state set issue 60
git checkout -q -b orch/60-tickettest
git push -q -u origin orch/60-tickettest
"$ORCH" state set branch orch/60-tickettest
"$ORCH" state set pr 40
"$ORCH" state set iteration 1
"$ORCH" state set budget 1
mkdir -p .orchestrator/review
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-01.md
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "redo review succeeds with every ticket already closed" "$st" 0
assert_eq "reopens exactly the tickets the flow's implement phase had closed" \
  "$("$ORCH" ticket next 60)" "$(printf '%s\n%s' "$t1" "$t2")"

unset GH_STUB_DB

# --- redo spec --------------------------------------------------------------
# --new-issue's close goes through the ORCH_GH_ADAPTER seam here, pointed at
# the in-memory fake rather than stub_gh - GH_STUB_LOG stays empty, proving it
# never spawns a real gh subprocess. The subprocess-real counterpart is the
# "gh adapter (real issue close, subprocess gh)" block right after this one.
echo
echo "redo spec"
healthy_repo
"$ORCH" init redospec >/dev/null

out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "refuses outside the implement phase" "$st" 1
assert_contains "naming the reason" "$out" "flow is not at the implement phase"

"$ORCH" state set phase implement
"$ORCH" state set issue 40
filed="$(mktemp)"
out="$(GH_STUB_FILED="$filed" "$ORCH" redo spec 2>&1)"; st=$?
assert_status "the default path steps back to spec" "$st" 0
assert_eq "phase becomes spec" "$("$ORCH" state get phase)" "spec"
assert_eq "keeping the existing issue" "$("$ORCH" state get issue)" "40"
assert_eq "and touching gh not at all" "$(grep -c . "$filed")" "0"

"$ORCH" state set phase implement
"$ORCH" state set issue 41
: >"$filed"
log="$(mktemp)"
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_FILED="$filed" GH_STUB_LOG="$log" \
  "$ORCH" redo spec --new-issue 2>&1)"; st=$?
assert_status "--new-issue also steps back to spec" "$st" 0
assert_eq "phase becomes spec" "$("$ORCH" state get phase)" "spec"
assert_eq "clearing the old issue" "$("$ORCH" state get issue)" ""
assert_contains "closes the old issue" "$(cat "$filed")" "issue close 41"
assert_eq "the close call never reached a real gh subprocess" "$(grep -cx issue "$log")" "0"

"$ORCH" state set phase implement
"$ORCH" state set issue 42
out="$(ORCH_GH_ADAPTER="$GH_ADAPTER_FAKE" GH_STUB_ISSUE_CLOSE_EXIT=1 "$ORCH" redo spec --new-issue 2>&1)"; st=$?
assert_status "a gh that will not close the issue fails --new-issue" "$st" 1
assert_eq "leaving the phase where it was rather than half-finishing" \
  "$("$ORCH" state get phase)" "implement"

out="$("$ORCH" redo spec --bogus 2>&1)"; st=$?
assert_status "rejects an unknown flag" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh redo spec"

# --- gh adapter (real issue close, subprocess gh) ---------------------------
# The rest of "redo spec" proved the seam through the in-memory fake; this is
# the narrow counterpart proving the real half still works - ORCH_GH_ADAPTER
# left unset, so the adapter function defined in orch.sh itself is the one
# that runs, and it has to actually shell out to `gh issue close` with the
# right arguments rather than merely compile.
echo
echo "gh adapter (real issue close, subprocess gh)"
"$ORCH" state set phase implement
"$ORCH" state set issue 43
: >"$filed"
log="$(mktemp)"
out="$(GH_STUB_FILED="$filed" GH_STUB_LOG="$log" "$ORCH" redo spec --new-issue 2>&1)"; st=$?
assert_status "--new-issue shells out for real" "$st" 0
assert_contains "the real adapter invoked gh issue close on the old issue" \
  "$(cat "$filed")" "issue close 43"
assert_contains "with the redo comment" \
  "$(cat "$filed")" "This issue was closed by an orchestrator redo"
assert_eq "gh itself was invoked once, as a real subprocess" \
  "$(grep -cx issue "$log")" "1"

# --- skill names (ADR-0014) --------------------------------------------------
# Every orchestrator skill carries the orch- prefix. An old unprefixed name
# left in a skill, command, hook, or doc points a model at a skill that no
# longer exists. CHANGELOG and ADRs record history and may name the old ones;
# scripts/test/ feeds old names in deliberately as negative cases.
echo
echo "skill names (ADR-0014)"
root="$(cd "$(dirname "$ORCH")/.." && pwd)"
old_names='orchestrator:(flow|handoff|review|review-spec|quick-implement)([^a-z-]|$)|skills/(flow|handoff|review|review-spec|quick-implement)/|^name: (flow|handoff|review|review-spec|quick-implement)$'
hits="$(git -C "$root" ls-files -z \
  | grep -zvE '^(CHANGELOG\.md|docs/adr/|scripts/test/)' \
  | (cd "$root" && xargs -0 grep -nE "$old_names" 2>/dev/null))"
assert_eq "no old unprefixed orchestrator skill name outside CHANGELOG/ADR history" "$hits" ""
for d in "$root"/skills/*/; do
  n="$(basename "$d")"
  case "$n" in
    orch-*) ok "skill directory $n carries the orch- prefix" ;;
    *) bad "skill directory $n carries the orch- prefix" "unprefixed skill directory" ;;
  esac
  assert_eq "skill $n declares its directory name" \
    "$(sed -n 's/^name: //p' "$d/SKILL.md" | head -1)" "$n"
done

# --- orch.sh resolution (#123) ------------------------------------------------
# Only Claude Code expands CLAUDE_PLUGIN_ROOT, and only in hooks/hooks.json on
# other hosts, so skill, command, and guidelines text must pair it with the
# relative fallback. The one documented form (README, "Resolving orch.sh") is
# the ORCH= line plus the fallback sentence; any other mention of the variable,
# or a file that runs orch.sh without that pair, is a regression.
# hooks/hooks.json is deliberately out of scope: both hosts expand it there.
echo
echo "orch.sh resolution (#123)"
orch_line='ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"'
fallback='If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh`'
# scan_orch_resolution <plugin root>: print one line per offending file.
scan_orch_resolution() {
  local r="$1" f
  for f in "$r"/skills/*/SKILL.md "$r"/commands/*.md "$r"/guidelines/*; do
    [ -f "$f" ] || continue
    if grep -n 'CLAUDE_PLUGIN_ROOT' "$f" | grep -vF -e "$orch_line" -e "$fallback" | grep -q .; then
      echo "${f#"$r"/}: CLAUDE_PLUGIN_ROOT outside the ORCH= line and its fallback"
    fi
    if grep -qE 'orch\.sh|\$ORCH' "$f"; then
      grep -qxF "$orch_line" "$f" || echo "${f#"$r"/}: uses orch.sh without the ORCH= line"
      grep -qF "$fallback" "$f" || echo "${f#"$r"/}: uses orch.sh without the relative fallback"
    fi
  done
}
assert_eq "every skill and command resolves orch.sh the one documented way" \
  "$(scan_orch_resolution "$root")" ""
# With no full install at all, doctor has no orch.sh to run from, so the skill
# is the one that has to explain the failure (#128).
missing=""
for f in "$root"/skills/*/SKILL.md; do
  grep -qF 'skills-only install' "$f" || missing="$missing ${f#"$root"/}"
done
assert_eq "every skill names the full-plugin install when orch.sh is missing" "$missing" ""
# The Junie install in that stop text is unverified, so it has to say so (#121).
missing=""
for f in "$root"/skills/*/SKILL.md; do
  grep -qF 'as a Junie extension, which is unverified' "$f" || missing="$missing ${f#"$root"/}"
done
assert_eq "every skill marks its Junie install unverified" "$missing" ""
# One stop text, copied into each skill: once the Junie install is verified,
# every copy must change together, so they may not drift apart.
stop_text() { awk '/^If `orch.sh` is at neither path/,/which is unverified\)\.$/' "$1"; }
ref="$(stop_text "$root/skills/orch-flow/SKILL.md")"
assert_contains "orch-flow carries the skills-only stop text" "$ref" "skills-only install"
drift=""
for f in "$root"/skills/*/SKILL.md; do
  [ "$(stop_text "$f")" = "$ref" ] || drift="$drift ${f#"$root"/}"
done
assert_eq "every skill's skills-only stop text matches orch-flow's word for word" "$drift" ""
fixture="$(mktemp -d)"
mkdir -p "$fixture/guidelines"
printf 'Run `${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh status`.\n' >"$fixture/guidelines/orch.md"
assert_contains "the scan covers guidelines/ and flags a bare CLAUDE_PLUGIN_ROOT" \
  "$(scan_orch_resolution "$fixture")" "guidelines/orch.md: CLAUDE_PLUGIN_ROOT outside"
printf '%s\n' '```' "$orch_line" '```' "$fallback two directories above this skill's own directory." \
  >"$fixture/guidelines/orch.md"
assert_eq "the scan accepts the documented form" "$(scan_orch_resolution "$fixture")" ""
rm -rf "$fixture"

# --- host capabilities (#127) -------------------------------------------------
# Skills describe capabilities and point at one reference that maps each
# capability to each host, so a host without Claude Code's tools can still
# follow them. Commands are Claude-only shortcuts and hold no behaviour of
# their own: each routes to an orch-flow section that exists.
echo
echo "host capabilities (#127)"
ref="$root/docs/host-capabilities.md"
if [ -f "$ref" ]; then ok "the host capabilities reference exists"
else bad "the host capabilities reference exists" "no $ref"; fi
header="$(grep -m1 '^| Capability' "$ref" 2>/dev/null)"
assert_contains "it has a Claude Code column" "$header" "| Claude Code |"
assert_contains "it has a Junie column" "$header" "| Junie |"
for cap in 'Invoke a skill from a step' 'Ask a multiple-choice question' 'Start a fresh subagent' \
           'Start a forked subagent' 'Start a fresh session' \
           'Inject context at planning time' 'Arm the edit guard'; do
  row="$(grep -m1 "^| $cap |" "$ref" 2>/dev/null)"
  assert_eq "it has a filled-in row for: $cap" \
    "$(printf '%s\n' "$row" | awk -F'|' 'NF >= 5 && $3 !~ /^ *$/ && $4 !~ /^ *$/ { print "filled" }')" "filled"
done
# scan_capabilities <plugin root>: print one line per offending skill or command.
scan_capabilities() {
  local r="$1" f s
  for f in "$r"/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    grep -qF 'docs/host-capabilities.md' "$f" \
      || echo "${f#"$r"/}: never points at docs/host-capabilities.md"
    grep -niE '(call|use|with) the (Skill|Agent) tool|(call|use|spawn|dispatch)[a-z]* .*the Agent tool' "$f" \
      | sed "s|^|${f#"$r"/}: names a Claude tool as the step: |"
    # Junie has no plugin scope, so a skill names its siblings bare (orch-flow);
    # the Claude-scoped form is only ever the generic orchestrator:<name>.
    grep -nE 'orchestrator:orch-' "$f" \
      | sed "s|^|${f#"$r"/}: names a skill by its Claude-scoped name: |"
    # "Run a plugin command" is Unverified on Junie, so a skill that offers one
    # also says what to offer on a host without plugin commands.
    if grep -qE '/orchestrator:[a-z]' "$f" && ! grep -qF 'no plugin commands' "$f"; then
      echo "${f#"$r"/}: offers a plugin command with no fallback"
    fi
    # A host's column holds only verified facts, so a claim about every host
    # outruns the reference.
    grep -niE 'no host can' "$f" \
      | sed "s|^|${f#"$r"/}: claims a fact for every host: |"
  done
  for f in "$r"/commands/*.md; do
    [ -f "$f" ] || continue
    grep -qE 'orch\.sh|\$ORCH' "$f" && echo "${f#"$r"/}: runs orch.sh itself"
    s="$(grep -oE "orch-flow\` and follow its \*\*[^*]+\*\*" "$f" | sed 's/.*\*\*\(.*\)\*\*/\1/')"
    if [ -z "$s" ]; then echo "${f#"$r"/}: routes to no orch-flow section"
    else grep -qxF "## $s" "$r/skills/orch-flow/SKILL.md" \
      || echo "${f#"$r"/}: routes to a missing orch-flow section: $s"; fi
  done
}
assert_eq "every skill points at the reference, and every command is a thin route" \
  "$(scan_capabilities "$root")" ""
# orch.sh's and doctor.sh's messages reach the model on every host too, so they
# name a flow command only through flow_cmd, which adds the orch-flow section
# for a host with no plugin commands - and every section it names must exist.
assert_eq "the scripts name a plugin command only through flow_cmd" \
  "$(grep -nE '/orchestrator:[a-z]' "$root/scripts/orch.sh" "$root/scripts/doctor.sh" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')" ""
flow_sections="$(awk '/^flow_cmd\(\)/,/^}/' "$root/scripts/orch.sh" | grep -oE 'section="[^"]+"' | sed 's/section="//; s/"$//')"
assert_eq "flow_cmd names four orch-flow sections" "$(printf '%s\n' "$flow_sections" | grep -c .)" "4"
while IFS= read -r s; do
  grep -qxF "## $s" "$root/skills/orch-flow/SKILL.md" \
    && ok "flow_cmd's section exists in orch-flow: $s" \
    || bad "flow_cmd's section exists in orch-flow: $s" "no ## $s"
done <<<"$flow_sections"
fixture="$(mktemp -d)"
mkdir -p "$fixture/skills/orch-x" "$fixture/skills/orch-flow" "$fixture/commands"
printf '## Status\nSee docs/host-capabilities.md.\n' >"$fixture/skills/orch-flow/SKILL.md"
printf 'Call the Skill tool with `x`. See docs/host-capabilities.md.\n' >"$fixture/skills/orch-x/SKILL.md"
printf 'Invoke `orchestrator:orch-flow` and follow its **Doctor** section.\n' >"$fixture/commands/doctor.md"
out="$(scan_capabilities "$fixture")"
assert_contains "the scan flags a Claude tool named as the step" "$out" "orch-x/SKILL.md: names a Claude tool"
printf '## Status\nInvoke `orchestrator:orch-handoff`. See docs/host-capabilities.md.\n' >"$fixture/skills/orch-flow/SKILL.md"
assert_contains "the scan flags a sibling skill named by its Claude scope" \
  "$(scan_capabilities "$fixture")" "orch-flow/SKILL.md: names a skill by its Claude-scoped name"
printf '## Status\nInvoke the `orch-handoff` skill (`orchestrator:<name>` on Claude Code). See docs/host-capabilities.md.\n' >"$fixture/skills/orch-flow/SKILL.md"
assert_contains "the scan flags a command routed to a missing section" "$out" "missing orch-flow section: Doctor"
printf 'Offer `/orchestrator:abort`, so no host can stall. See docs/host-capabilities.md.\n' >"$fixture/skills/orch-x/SKILL.md"
out="$(scan_capabilities "$fixture")"
assert_contains "the scan flags a plugin command offered with no fallback" "$out" "orch-x/SKILL.md: offers a plugin command with no fallback"
assert_contains "the scan flags a fact claimed for every host" "$out" "orch-x/SKILL.md: claims a fact for every host"
printf 'Invoke the skill `x` (see docs/host-capabilities.md).\n' >"$fixture/skills/orch-x/SKILL.md"
printf 'Invoke `orchestrator:orch-flow` and follow its **Status** section.\n' >"$fixture/commands/doctor.md"
printf '%s\n' "$orch_line" >"$fixture/commands/status.md"
out="$(scan_capabilities "$fixture")"
assert_contains "the scan flags a command that runs orch.sh itself" "$out" "commands/status.md: runs orch.sh itself"
rm "$fixture/commands/status.md"
assert_eq "the scan accepts capability phrasing and a thin route" "$(scan_capabilities "$fixture")" ""
rm -rf "$fixture"

# --- Junie planning nudge (#129) ----------------------------------------------
# Junie has no PostToolUse event, so hook-grilling.sh never fires there. A
# guidelines/ file carries its message instead, and it loads in every repo the
# extension is enabled in, so it must stay conditional. The scan checks the
# message's key points survive, not its exact wording.
echo
echo "Junie planning nudge (#129)"
# scan_planning_nudge <plugin root>: print one line per missing key point.
scan_planning_nudge() {
  local r="$1" f
  f="$(ls "$r"/guidelines/*.md 2>/dev/null | head -1)"
  if [ -z "$f" ]; then echo "no guidelines/*.md file"; return; fi
  local label
  while IFS='|' read -r label pattern; do
    grep -qiE "$pattern" "$f" || echo "${f#"$r"/}: missing $label"
  done <<'EOF'
the conditional wording|only when a grilling session is running and no flow is active
the active-flow check|\.orchestrator/state\.json
no implementing during planning|planning artifacts
the flow option|Start the orchestrator flow
the quick option|Quick implementation
the multiple-choice question|AskUserQuestion
the orch-flow skill|`orch-flow`
the orch-quick-implement skill|`orch-quick-implement`
the issue-tracker warning|docs/agents/issue-tracker\.md
the setup fix|setup-matt-pocock-skills
the Invoke a skill from a step fallback as the step|no Skill tool.*read `skills/<name>/SKILL\.md`
EOF
  # Junie's "Invoke a skill from a step" cell is Fallback, so reading SKILL.md is the step,
  # not a branch taken only when a listed skill is missing.
  grep -niE 'if it is not listed' "$f" \
    | sed "s|^|${f#"$r"/}: makes the Invoke a skill from a step fallback conditional: |"
  grep -niE '(call|use|with) the (Skill|Agent) tool' "$f" \
    | sed "s|^|${f#"$r"/}: names a Claude tool as the step: |"
  # A hand-copied allowlist drifts; every entry of the canonical definition must
  # appear, so an addition there fails here until the text catches up.
  local entry
  for entry in $(source "$root/scripts/planning-allowlist.sh"; printf '%s\n' "${PLANNING_ALLOWLIST[@]}"); do
    grep -qF "$entry" "$f" || echo "${f#"$r"/}: missing allowlist entry $entry"
  done
}
assert_eq "the guidelines file carries the grilling hook's key points, conditionally" \
  "$(scan_planning_nudge "$root")" ""
fixture="$(mktemp -d)"
assert_eq "the scan flags a missing guidelines file" \
  "$(scan_planning_nudge "$fixture")" "no guidelines/*.md file"
mkdir -p "$fixture/guidelines"
printf 'Start the orchestrator flow or Quick implementation. Call the Skill tool with `orch-flow`.\n' \
  >"$fixture/guidelines/orch.md"
out="$(scan_planning_nudge "$fixture")"
assert_contains "the scan flags unconditional wording" "$out" "missing the conditional wording"
assert_contains "the scan flags a missing issue-tracker warning" "$out" "missing the issue-tracker warning"
assert_contains "the scan flags a Claude tool named as the step" "$out" "names a Claude tool as the step"
assert_contains "the scan flags a missing Invoke a skill from a step fallback" "$out" "missing the Invoke a skill from a step fallback as the step"
printf 'Pick `orch-flow` from the skills this host lists. If it is not listed, read its SKILL.md.\n' \
  >"$fixture/guidelines/orch.md"
assert_contains "the scan flags a conditional Invoke a skill from a step fallback" \
  "$(scan_planning_nudge "$fixture")" "makes the Invoke a skill from a step fallback conditional"
rm -rf "$fixture"

# --- doctor: base branch check -----------------------------------------------
# A set base branch that has vanished from origin is the one stale setting that
# would send the next flow's fork and PR at nothing, so it FAILs; origin being
# unreachable only means doctor could not tell, so it warns.
echo
echo "doctor: base branch check"
healthy_repo
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a default base branch passes" "$st" 0
assert_contains "reports the default branch as the base branch" "$out" "ok    base branch: main (default)"
assert_contains "keeps the default-branch check" "$out" "ok    default branch: main (from GitHub)"

bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
git push -q "$bare" HEAD:refs/heads/main HEAD:refs/heads/uat
git remote set-url origin "$bare"
git config orchestrator.base uat
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a set base branch origin has passes" "$st" 0
assert_contains "reports the set base branch" "$out" "ok    base branch: uat (set)"

git config orchestrator.base gone
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a set base branch missing from origin fails" "$st" 1
assert_contains "names the missing base branch" "$out" "FAIL  base branch gone"
assert_contains "gives the way out" "$out" "base clear"

git remote set-url origin "$(dirname "$bare")/unreachable.git"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unverifiable base branch does not block the flow" "$st" 0
assert_contains "warns that origin could not be reached" "$out" "warn  base branch gone"
git config --unset orchestrator.base
rm -rf "$(dirname "$bare")"

echo
if [ "$SKIP" -gt 0 ]; then
  echo "$PASS passed, $FAIL failed, $SKIP skipped"
else
  echo "$PASS passed, $FAIL failed"
fi
[ "$FAIL" -eq 0 ]
