#!/usr/bin/env bash
#
# This repo's ticket verification: affected.sh [--plan] [<ref>]. It maps the
# files changed since the branch's base to the test suites and orch_test.sh
# sections that cover them, always runs the cheap broad checks, and runs the
# full suite (all.sh) wherever a change's reach is unclear. Run all.sh once
# before opening a PR.
#
# The base is the merge-base of HEAD with <ref> when one is given. Otherwise it
# is the merge-base with origin's copy of the branch's base branch, read from
# git config, never through orch.sh: the base recorded for the current branch
# (branch.<b>.orchestrator-base), or for a ticket branch the one recorded for
# the branch it was forked from (branch.<b>.orchestrator-ticket-parent), else
# the checkout's orchestrator.base, else origin's default branch
# (refs/remotes/origin/HEAD). With no base, or no merge-base with it, the
# whole suite runs. A <ref> that does not resolve prints "affected.sh: unknown
# ref <ref>" on stderr, runs nothing and exits 2, --plan included.
#
# The changed set is that range plus uncommitted changes, untracked files
# included. What a changed file selects:
#   scripts/orch/<m>.sh               the sections of scripts/test/orch/<m>.sh
#   scripts/test/orch/<n>.sh          its own sections
#   hook-*.sh, hooks/hooks.json       hooks_test.sh
#   version-bump.sh, autopilot-container.sh, autopilot-up.sh, and the suites
#   themselves, scripts/dev/lens-bench.sh and lens_bench_test.sh included
#                                     their own test file
#   skills, agents, docs, markdown, changelog fragments
#                                     nothing beyond the always-run checks
#   anything else, orch.sh, orch/common.sh, the shared test setup, the
#   runners, the gh fake, test_jobs.sh, report.sh, test_tree.sh
#                                     all.sh (this row wins)
# A deleted module or section file runs all.sh too.
#
# Always run: docs_lint.sh, orch_test.sh's placement sections (test-helper
# placement, gh op placement, marked comment prelude placement), and
# the shellcheck run, at warning severity, on the changed scripts/**/*.sh
# files that still exist. Sections are chosen through orch_test.sh's
# ORCH_TEST_ONLY.
#
# Output is like all.sh's: each part's FAIL lines and one summary line, in a
# fixed order - the suites in all.sh's list order, orch_test.sh carrying the
# placement and selected sections, then shellcheck last. Exits 1 when anything
# failed. --plan prints the selection instead, one item per line in that order
# (each suite, each orch_test.sh section title, each shellcheck file), or the
# single line "all.sh" on the fallback, and runs nothing.
#
# The last stdout line is the verdict (report.sh): "affected.sh: PASS (<n>
# parts)" when the run exits 0, else "affected.sh: FAIL (<part>, <part>, ...)",
# each failed part named by its summary line's prefix, n counting the summary
# lines printed (shellcheck's included, whatever it printed). The full-suite
# fallback ends on all.sh's verdict instead. Usage errors, an unknown ref, an
# invalid ORCH_TEST_POOL_PERCENT, an INT or TERM stop and --plan print none.
# An invalid ORCH_TEST_JOBS is not checked here: the orch_test.sh child fails
# on it, so the run still ends on "affected.sh: FAIL (orch_test.sh)".

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=git_env.sh
source "$dir/git_env.sh"
test_git_env_clear || exit 1
root="$(cd "$dir/../.." && pwd)"

plan=0
ref=""
have_ref=0
for arg in "$@"; do
  case "$arg" in
    --plan) plan=1 ;;
    -*) echo "usage: affected.sh [--plan] [<ref>]" >&2; exit 2 ;;
    *)
      if [ "$have_ref" -eq 1 ]; then
        echo "usage: affected.sh [--plan] [<ref>]" >&2
        exit 2
      fi
      ref="$arg"
      have_ref=1
      ;;
  esac
done

cd "$root" || exit 1
git_raw_paths() { git -c core.quotepath=off "$@"; }

# full_suite: the fallback - the whole of all.sh, or its name on --plan.
full_suite() {
  if [ "$plan" -eq 1 ]; then
    echo "all.sh"
    exit 0
  fi
  exec bash "$dir/all.sh"
}

# resolve_base: prints the commit the changed range starts at (the merge-base),
# or nothing when there is none. A <ref> that does not resolve exits 2.
resolve_base() {
  local target branch name parent
  if [ "$have_ref" -eq 1 ]; then
    target="$(git rev-parse --verify -q "$ref^{commit}")" || {
      echo "affected.sh: unknown ref $ref" >&2
      exit 2
    }
  else
    branch="$(git symbolic-ref -q --short HEAD)" || branch=""
    name=""
    if [ -n "$branch" ]; then
      name="$(git config --get "branch.$branch.orchestrator-base")" || name=""
      if [ -z "$name" ]; then
        parent="$(git config --get "branch.$branch.orchestrator-ticket-parent")" || parent=""
        [ -n "$parent" ] && { name="$(git config --get "branch.$parent.orchestrator-base")" || name=""; }
      fi
    fi
    [ -n "$name" ] || { name="$(git config --get orchestrator.base)" || name=""; }
    if [ -n "$name" ]; then
      target="$(git rev-parse --verify -q "refs/remotes/origin/$name^{commit}")" || return 0
    else
      target="$(git rev-parse --verify -q "refs/remotes/origin/HEAD^{commit}")" || return 0
    fi
  fi
  git merge-base HEAD "$target" 2>/dev/null || true
}

merge_base="$(resolve_base)" || exit $?
[ -n "$merge_base" ] || full_suite

# changed: files present now (tracked changes and untracked); deleted: gone.
changed="$( { git_raw_paths diff --no-renames --name-only --diff-filter=d "$merge_base" --
  git_raw_paths ls-files --others --exclude-standard; } | LC_ALL=C sort -u)"
deleted="$(git_raw_paths diff --no-renames --name-only --diff-filter=D "$merge_base" -- | LC_ALL=C sort -u)"

want=()        # suites to run besides orch_test.sh and docs_lint.sh
sec_files=()   # scripts/test/orch/<n>.sh files whose sections run
sc_files=()    # the lint targets

# classify <file> <present|deleted>: record what the file selects, or run the
# full suite when its reach is unclear.
classify() {
  local f="$1" state="$2" file_name
  file_name="$(basename "$f")"
  case "$f" in
    scripts/orch.sh | scripts/orch/common.sh | scripts/test/orch/common.sh | \
      scripts/test/orch/setup.sh | scripts/test/all.sh | scripts/test/orch_test.sh | \
      scripts/test/affected.sh | scripts/test/test_jobs.sh | scripts/test/report.sh | scripts/test/test_tree.sh | scripts/test/gh_adapter_fake.sh)
      full_suite ;;
    scripts/orch/*.sh)
      [ "$state" = deleted ] && full_suite
      [ -f "scripts/test/orch/$file_name" ] || full_suite
      sec_files+=("scripts/test/orch/$file_name") ;;
    scripts/test/orch/*.sh)
      [ "$state" = deleted ] && full_suite
      sec_files+=("$f") ;;
    scripts/hook-*.sh | hooks/hooks.json) want+=(hooks_test.sh) ;;
    scripts/test/hooks_test.sh) want+=(hooks_test.sh) ;;
    scripts/version-bump.sh | scripts/test/version_bump_test.sh) want+=(version_bump_test.sh) ;;
    scripts/autopilot-container.sh | scripts/test/autopilot_container_test.sh)
      want+=(autopilot_container_test.sh) ;;
    scripts/autopilot-up.sh | scripts/test/autopilot_up_test.sh) want+=(autopilot_up_test.sh) ;;
    scripts/dev/lens-bench.sh | scripts/test/lens_bench_test.sh) want+=(lens_bench_test.sh) ;;
    scripts/test/docs_lint.sh) ;;
    skills/* | agents/* | docs/* | changelog.d/* | *.md) return 0 ;;
    *) full_suite ;;
  esac
  if [ "$state" = present ]; then
    case "$f" in scripts/*.sh) sc_files+=("$f") ;; esac
  fi
}

while IFS= read -r f; do
  [ -n "$f" ] && classify "$f" present
done <<<"$changed"
while IFS= read -r f; do
  [ -n "$f" ] && classify "$f" deleted
done <<<"$deleted"

# shellcheck source=test_tree.sh
source "$dir/test_tree.sh"

# A section file's titles: its `# --- ` lines, read by test_tree.sh's
# SECTION_TITLE_AWK, as orch_test.sh's walk reads them.
titles_of() {
  awk "$SECTION_TITLE_AWK"'/^# --- / { print title($0) }' "$1"
}

# The placement titles come first, then the selected files' sections.
titles=()
add_title() {
  local t
  for t in "${titles[@]}"; do [ "$t" = "$1" ] && return 0; done
  titles+=("$1")
}
harness="scripts/test/orch/harness.sh"
if [ -f "$harness" ]; then
  while IFS= read -r t; do
    case "$t" in
      "test-helper placement ("* | "gh op placement ("* | "marked comment prelude placement ("*)
        add_title "$t" ;;
    esac
  done < <(titles_of "$harness")
fi
if [ "${#sec_files[@]}" -gt 0 ]; then
  while IFS= read -r sf; do
    while IFS= read -r t; do
      add_title "$t"
    done < <(titles_of "$sf")
  done < <(printf '%s\n' "${sec_files[@]}" | LC_ALL=C sort -u)
fi

# The all.sh suite list.
suites_read "$dir/all.sh" "$dir" || {
  echo "affected.sh: $SUITES_ERR" >&2
  exit 1
}
suites=("${SUITES[@]}")

# The suites to run, in all.sh's order: orch_test.sh and docs_lint.sh always.
selected=()
for suite in "${suites[@]}"; do
  case "$suite" in
    orch_test.sh | docs_lint.sh) selected+=("$suite") ;;
    *)
      for w in "${want[@]}"; do
        [ "$w" = "$suite" ] && { selected+=("$suite"); break; }
      done ;;
  esac
done

sc_sorted=()
if [ "${#sc_files[@]}" -gt 0 ]; then
  while IFS= read -r f; do sc_sorted+=("$f"); done < <(printf '%s\n' "${sc_files[@]}" | LC_ALL=C sort -u)
fi

if [ "$plan" -eq 1 ]; then
  for suite in "${selected[@]}"; do
    echo "$suite"
    if [ "$suite" = orch_test.sh ] && [ "${#titles[@]}" -gt 0 ]; then
      printf '%s\n' "${titles[@]}"
    fi
  done
  [ "${#sc_sorted[@]}" -gt 0 ] && printf '%s\n' "${sc_sorted[@]}"
  exit 0
fi

# ORCH_TEST_ONLY for orch_test.sh: an anchored alternation of the titles.
only=""
for t in "${titles[@]}"; do
  esc="$(printf '%s' "$t" | sed 's/[].\\[*^$+?(){}|]/\\&/g')"
  only+="${only:+|}$esc"
done

# shellcheck source=test_jobs.sh
source "$dir/test_jobs.sh"
# shellcheck source=report.sh
source "$dir/report.sh"
test_jobs_lower_priority
test_jobs_pool_init affected.sh || exit 1
export ORCH_TEST_QUIET=1
tmp="$(mktemp -d)" || exit 1
pids=()
trap 'test_jobs_stop_children "${pids[@]}"' INT TERM
trap 'rm -rf "$tmp"' EXIT

for suite in "${selected[@]}"; do
  if [ "$suite" = orch_test.sh ] && [ -n "$only" ]; then
    ORCH_TEST_ONLY="^($only)\$" bash "$dir/$suite" >"$tmp/$suite" &
  else
    unset ORCH_TEST_ONLY
    bash "$dir/$suite" >"$tmp/$suite" &
  fi
  pids+=("$!")
done

have_sc=0
sc_pid=""
if [ "${#sc_sorted[@]}" -gt 0 ] && command -v shellcheck >/dev/null 2>&1; then
  have_sc=1
  test_jobs_slot_wait
  test_jobs_job shellcheck -S warning -f gcc "${sc_sorted[@]}" >"$tmp/shellcheck" 2>&1 &
  sc_pid=$!
  test_jobs_slot_release "$sc_pid"
  pids+=("$sc_pid")
fi

suite_exits=()
for n in "${!selected[@]}"; do
  wait "${pids[$n]}"
  suite_exits+=("$?")
done
sc_status=0
[ "$have_sc" -eq 1 ] && { wait "$sc_pid"; sc_status=$?; }

for n in "${!selected[@]}"; do
  suite="${selected[$n]}"
  report_suite "$suite" "${suite_exits[$n]}" "$(<"$tmp/$suite")"
done

if [ "$have_sc" -eq 1 ]; then
  sc_out="$(<"$tmp/shellcheck")"
  report_shellcheck "$sc_status" "$sc_out"
elif [ "${#sc_sorted[@]}" -gt 0 ]; then
  report_shellcheck_missing
else
  report_shellcheck 0 ""
fi
report_verdict affected.sh
exit $?
