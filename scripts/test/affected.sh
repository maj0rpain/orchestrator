#!/usr/bin/env bash
#
# This repo's ticket and branch verification: affected.sh [--plan] [<ref>] or
# affected.sh --row <path>... It maps the files changed since the branch's base
# to the test suites and orch_test.sh sections that cover them, always runs
# the cheap broad checks, and runs the full suite (all.sh) wherever a change's
# reach is unclear. CI is the one place the whole suite always runs.
#
# The base is the merge-base of HEAD with <ref> when one is given. On a ticket
# branch that records branch.<b>.orchestrator-ticket-parent it is the
# merge-base of HEAD with that parent branch as the local repository has it,
# never origin's copy, so a ticket verifies its own diff; with the parent
# missing locally, or no merge-base with it, the base is found as follows, as
# on any other branch. Otherwise it is the merge-base with origin's copy of
# the branch's base branch, read from
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
#   scripts/test/orch/<n>.sh          its own sections (common.sh's included)
#   hook-*.sh, hooks/hooks.json       hooks_test.sh
#   version-bump.sh, autopilot-container.sh, autopilot-up.sh, and the suites
#   themselves, scripts/dev/lens-bench.sh and lens_bench_test.sh included
#                                     their own test file
#   the lens bench's fixture directories (scripts/dev/lens-bench/,
#   scripts/test/lens-bench/), markdown files included
#                                     lens_bench_test.sh (wins over *.md)
#   flow-state.sh                     the core set, plus the state, init and
#                                     side-checkout sections
#   host.sh                           the core set, plus the doctor sections
#   bash-walk.sh                      hooks_test.sh
#   paste-guard.sh                    hooks_test.sh, plus the spec-review
#                                     sections
#   planning-allowlist.sh             hooks_test.sh, plus the doctor sections
#   triage-labels.sh                  hooks_test.sh, plus the doctor and issue
#                                     sections
#   scripts/dev/ other than the lens bench, hook-edit-width.sh, width.sh
#                                     the harness section file's sections
#   hook-edit-width.sh, width.sh, shell_code.awk
#                                     the harness sections, plus hooks_test.sh
#   docker/, .dockerignore            autopilot_container_test.sh and
#                                     autopilot_up_test.sh
#   .claude-plugin/                   version_bump_test.sh, autopilot_up_test.sh
#   .shellcheckrc                     shellcheck over every scripts/**/*.sh,
#                                     plus the harness sections
#   skills, agents, docs, markdown, changelog fragments, the durations file
#   (section-durations.tsv) and the budget file (suite-budget, beside it), the
#   workflow files, .gitignore, .gitattributes, .ignore, LICENSE and
#   .claude/settings.json
#                                     nothing beyond the always-run checks
#   anything else                     all.sh
#   scripts/test/orch/setup.sh, counting.sh, fifo.sh, tally.sh
#                                     function by function: each function whose
#                                     code differs from the base selects the
#                                     sections of every section file, and every
#                                     suite but orch_test.sh, that calls it,
#                                     directly or through another of these
#                                     helpers (a removed one selects the files
#                                     that still call it); and the core set when
#                                     orch_test.sh or nothing calls it.
#                                     Code outside any function runs all.sh; a
#                                     change to comments or blank lines alone
#                                     selects nothing more
#   the gh fake (gh_adapter_fake.sh)  function by function, as above, operations
#                                     first: a changed function selects the
#                                     sections of the gh section file and of
#                                     the section file of every scripts/orch/
#                                     module whose code calls the adapter_*
#                                     operation of that name, or any operation
#                                     that calls the function; and, as a shared
#                                     helper does, the section files and suites
#                                     that call it directly or through those;
#                                     the core set when nothing reaches it.
#                                     Code outside any function runs all.sh; a
#                                     change to comments or blank lines alone
#                                     selects nothing more
# The whole suite (all.sh) runs for exactly these cases: code outside any
# function in a shared test support file or the gh fake; a path no row names; a
# module with no section file of its own; no base, or no merge-base with it.
# The core set is the sections of the harness and loader section files and
# every suite but orch_test.sh. It is selected, together with the rest of the
# diff's selection, by orch.sh, orch/common.sh (plus its own section file),
# orch/loader.sh, orch_test.sh, all.sh, affected.sh, test_jobs.sh, report.sh,
# test_tree.sh, git_env.sh, and a deleted module or section file.
#
# --row <path>...: runs nothing and prints "<path>", a tab, and "named" when a
# row other than the catch-all takes the path, or "none" for a path only the
# catch-all takes and for a scripts/orch/ module with no section file of its
# own. It exits 0 either way, matches a path by name whether or not it exists,
# and is refused (exit 2) beside --plan or a <ref>.
#
# The base worked out above, a ticket branch's own included, is handed to
# docs_lint.sh in DOCS_LINT_BASE, the
# docs lint's own base setting for its suite budget rules, on the narrow
# selection and on the full-suite fallback alike (all.sh passes it through to
# its docs_lint.sh). With no base the setting is unset, never inherited.
#
# ORCH_TEST_SHARD is unset at start: a ticket verification is never split, its
# fallback to the full verification (all.sh) included.
#
# Always run: docs_lint.sh, orch_test.sh's placement sections (test-helper
# placement, gh op placement, marked comment prelude placement, comment
# reader placement), and the shellcheck run, at warning severity, on the
# changed scripts/**/*.sh files that still exist. Sections are chosen through
# orch_test.sh's ORCH_TEST_ONLY.
#
# Each suite other than orch_test.sh holds a slot of the job pool while it runs
# (test_jobs.sh's suite start, as all.sh's suites do), waiting for one when none
# is free: they start first, in selection order, then orch_test.sh, which holds
# none (its sections take their own), then shellcheck.
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
# invalid ORCH_TEST_POOL_PERCENT, an INT or TERM stop, --plan and
# --row print none.
# An invalid ORCH_TEST_JOBS is not checked here: the orch_test.sh child fails
# on it, so the run still ends on "affected.sh: FAIL (orch_test.sh)".

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=git_env.sh
source "$dir/git_env.sh"
test_git_env_clear || exit 1
# A ticket verification is never split, its full-suite fallback included.
unset ORCH_TEST_SHARD
root="$(cd "$dir/../.." && pwd)"

plan=0
row=0
row_paths=()
usage="usage: affected.sh [--plan] [<ref>] | affected.sh --row <path>..."
ref=""
have_ref=0
for arg in "$@"; do
  case "$arg" in
    --row) row=1 ;;
    --plan) plan=1 ;;
    -*) echo "$usage" >&2; exit 2 ;;
    *)
      if [ "$row" -eq 1 ]; then
        row_paths+=("$arg")
        continue
      fi
      if [ "$have_ref" -eq 1 ]; then
        echo "$usage" >&2
        exit 2
      fi
      ref="$arg"
      have_ref=1
      ;;
  esac
done

if [ "$row" -eq 1 ] && { [ "$plan" -eq 1 ] || [ "$have_ref" -eq 1 ] || [ "${#row_paths[@]}" -eq 0 ]; }; then
  echo "$usage" >&2
  exit 2
fi

cd "$root" || exit 1
git_raw_paths() { git -c core.quotepath=off "$@"; }

# full_suite: the fallback - the whole of all.sh, or its name on --plan.
full_suite() {
  # A row of its own names the path, though it runs the whole suite.
  [ "$row" -eq 1 ] && exit 0
  if [ "$plan" -eq 1 ]; then
    echo "all.sh"
    exit 0
  fi
  if [ -n "${merge_base:-}" ]; then export DOCS_LINT_BASE="$merge_base"; else unset DOCS_LINT_BASE; fi
  exec bash "$dir/all.sh"
}

# resolve_base: prints the commit the changed range starts at (the merge-base),
# or nothing when there is none. A <ref> that does not resolve exits 2.
resolve_base() {
  local target branch name parent own
  if [ "$have_ref" -eq 1 ]; then
    target="$(git rev-parse --verify -q "$ref^{commit}")" || {
      echo "affected.sh: unknown ref $ref" >&2
      exit 2
    }
  else
    branch="$(git symbolic-ref -q --short HEAD)" || branch=""
    name=""
    if [ -n "$branch" ]; then
      parent="$(git config --get "branch.$branch.orchestrator-ticket-parent")" || parent=""
      if [ -n "$parent" ] && target="$(git rev-parse --verify -q "refs/heads/$parent^{commit}")"; then
        own="$(git merge-base HEAD "$target" 2>/dev/null)" || own=""
        [ -n "$own" ] && { printf '%s\n' "$own"; return 0; }
      fi
      name="$(git config --get "branch.$branch.orchestrator-base")" || name=""
      if [ -z "$name" ]; then
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

# shellcheck source=test_tree.sh
source "$dir/test_tree.sh"

want=()        # suites to run besides orch_test.sh and docs_lint.sh
sec_files=()   # scripts/test/orch/<n>.sh files whose sections run
sc_files=()    # the lint targets
core=0         # 1 when the core set is selected
sc_all=0       # 1 when every file the full verification lints is a lint target

# sections_of <name>...: select the sections of scripts/test/orch/<name>.sh.
sections_of() {
  local n
  for n in "$@"; do sec_files+=("scripts/test/orch/$n.sh"); done
}

# unnamed: a path only the catch-all row takes, or a scripts/orch/ module with
# no section file of its own: the whole suite, or in the --row form the exit
# status ROW_NONE.
ROW_NONE=77
unnamed() {
  [ "$row" -eq 1 ] && exit "$ROW_NONE"
  full_suite
}

# The shared test support: the files whose functions select by call.
SUPPORT_FILES=(scripts/test/orch/setup.sh scripts/test/counting.sh scripts/test/fifo.sh scripts/test/tally.sh)

# SUPPORT_AWK reads files each introduced by a "@@FILE" line. A function is a
# column-0 `name() {` line to the next column-0 `}` line, or that line alone
# when it does not end in `{`; its body leaves out comment-only and blank lines.
# Mode diff (two files, old then new) prints the names of the functions whose
# body differs or that only one holds, and "@top" when the code outside any
# function differs. Mode closure prints the names in -v seeds and every
# function of the files that calls one, directly or through another.
SUPPORT_AWK='
  function words(s) { gsub(/[^A-Za-z0-9_]+/, " ", s); return " " s " " }
  BEGIN { fi = (mode == "diff") ? 0 : 1 }
  /^@@FILE/ { if (mode == "diff") fi++; infn = 0; next }
  {
    if (infn) {
      if ($0 !~ /^[ \t]*(#.*)?$/) body[fi, name] = body[fi, name] "\n" $0
      if ($0 ~ /^}/) infn = 0
      next
    }
    if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/) {
      name = $0; sub(/\(.*/, "", name)
      names[name] = 1; body[fi, name] = $0
      infn = ($0 ~ /\{[ \t]*$/)
      next
    }
    if ($0 !~ /^[ \t]*(#.*)?$/) top[fi] = top[fi] "\n" $0
  }
  END {
    if (mode == "diff") {
      if (top[1] != top[2]) print "@top"
      for (n in names)
        if (((1, n) in body) != ((2, n) in body) || body[1, n] != body[2, n]) print n
      exit
    }
    n_seeds = split(seeds, seed_list, " ")
    for (i = 1; i <= n_seeds; i++) reached[seed_list[i]] = 1
    for (n in names) w[n] = words(body[1, n])
    do {
      grew = 0
      for (n in names) {
        if (n in reached) continue
        for (r in reached)
          if (index(w[n], " " r " ")) { reached[n] = 1; grew = 1; break }
      }
    } while (grew)
    for (r in reached) print r
  }'

GH_FAKE=scripts/test/gh_adapter_fake.sh

# suites_load: reads all.sh's suite list into suites, once, and with it what
# support_select needs: the support files present, and the files that call
# their functions (every suite but orch_test.sh, every section file but
# setup.sh).
suites=()
SUPPORT_PRESENT=()
SUPPORT_CALLERS=()
suites_loaded=0
suites_load() {
  local w sf
  [ "$suites_loaded" -eq 1 ] && return 0
  suites_read "$dir/all.sh" "$dir" || {
    echo "affected.sh: $SUITES_ERR" >&2
    exit 1
  }
  suites=("${SUITES[@]}")
  suites_loaded=1
  for sf in "${SUPPORT_FILES[@]}"; do [ -f "$sf" ] && SUPPORT_PRESENT+=("$sf"); done
  for w in "${suites[@]}"; do [ "$w" = orch_test.sh ] || SUPPORT_CALLERS+=("$dir/$w"); done
  for sf in scripts/test/orch/*.sh; do
    [ "$sf" = scripts/test/orch/setup.sh ] || SUPPORT_CALLERS+=("$sf")
  done
}

# files_calling <alternation> <file>...: the files holding a non-comment line
# that calls one of the names in the alternation (a|b), each printed once.
files_calling() {
  local re="(^|[^A-Za-z0-9_])($1)([^A-Za-z0-9_]|\$)"
  shift
  awk -v re="$re" 'FNR == 1 { done = 0 } !done && $0 !~ /^[ \t]*#/ && $0 ~ re { print FILENAME; done = 1 }' "$@"
}

# support_select <file> <present|deleted>: one of SUPPORT_FILES, or the gh fake,
# changed. Each function whose code differs between the base (merge_base)
# selects the sections of the section files and the suites that call it, and the
# core set when orch_test.sh calls it or nothing does; code outside any function
# runs the whole suite.
support_select() {
  local f="$1" state="$2" diffed name reached alt hits sf sn ops n closure_input
  local -a support_present
  suites_load
  support_present=("${SUPPORT_PRESENT[@]}")
  diffed="$(awk -v mode=diff "$SUPPORT_AWK" <(
    echo @@FILE; git show "$merge_base:$f" 2>/dev/null || true
    echo @@FILE; if [ "$state" = present ]; then cat "$f"; fi))"
  [ -n "$diffed" ] || return 0
  case $'\n'"$diffed"$'\n' in *$'\n@top\n'*) full_suite ;; esac
  # The gh fake's functions also reach through the fake's own.
  if [ "$f" = "$GH_FAKE" ] && [ -f "$GH_FAKE" ]; then support_present+=("$GH_FAKE"); fi
  closure_input="$(for sf in "${support_present[@]}"; do echo @@FILE; cat "$sf"; done)"
  while IFS= read -r name; do
    reached="$(awk -v mode=closure -v seeds="$name" "$SUPPORT_AWK" <<<"$closure_input")"
    alt="${reached//$'\n'/|}"
    if [ -n "$(files_calling "$alt" "$dir/orch_test.sh")" ]; then
      core=1
    fi
    ops=""
    if [ "$f" = "$GH_FAKE" ]; then
      # An adapter operation reached: the gh section file, and the section file
      # of every module whose code calls it.
      while IFS= read -r n; do
        case "$n" in adapter_*) ops="${ops:+$ops|}$n" ;; esac
      done <<<"$reached"
      if [ -n "$ops" ]; then
        sections_of gh
        while IFS= read -r sf; do
          [ -n "$sf" ] || continue
          sn="${sf##*/}"
          sections_of "${sn%.sh}"
        done < <(files_calling "$ops" scripts/orch/*.sh)
      fi
    fi
    hits="$(files_calling "$alt" "${SUPPORT_CALLERS[@]}")"
    if [ -z "$hits" ]; then [ -n "$ops" ] || core=1; continue; fi
    while IFS= read -r sf; do
      case "$sf" in
        scripts/test/orch/*.sh) sn="${sf##*/}"; sections_of "${sn%.sh}" ;;
        *) want+=("${sf##*/}") ;;
      esac
    done <<<"$hits"
  done <<<"$diffed"
}

# classify <file> <present|deleted>: record what the file selects, or run the
# full suite when its reach is unclear.
classify() {
  local f="$1" state="$2" file_name
  file_name="${f##*/}"
  # The core set: the harness and loader section files' sections and every
  # suite but orch_test.sh, together with whatever the rest of the diff selects.
  case "$f" in
    scripts/orch.sh | scripts/orch/common.sh | scripts/orch/loader.sh | scripts/test/git_env.sh | \
      scripts/test/all.sh | scripts/test/orch_test.sh | scripts/test/affected.sh | \
      scripts/test/test_jobs.sh | scripts/test/report.sh | scripts/test/test_tree.sh)
      core=1 ;;
    scripts/orch/*.sh | scripts/test/orch/*.sh)
      [ "$state" = deleted ] && core=1 ;;
  esac
  case "$f" in
    scripts/test/gh_adapter_fake.sh | scripts/test/orch/setup.sh | scripts/test/counting.sh | scripts/test/fifo.sh | scripts/test/tally.sh)
      support_select "$f" "$state" ;;
    scripts/orch.sh | scripts/test/all.sh | scripts/test/orch_test.sh | scripts/test/affected.sh | \
      scripts/test/test_jobs.sh | scripts/test/report.sh | scripts/test/test_tree.sh | scripts/test/git_env.sh) ;;
    scripts/flow-state.sh) core=1; sections_of state init side-checkout ;;
    scripts/host.sh) core=1; sections_of doctor ;;
    scripts/bash-walk.sh) want+=(hooks_test.sh) ;;
    scripts/paste-guard.sh) want+=(hooks_test.sh); sections_of spec-review ;;
    scripts/planning-allowlist.sh) want+=(hooks_test.sh); sections_of doctor ;;
    scripts/triage-labels.sh) want+=(hooks_test.sh); sections_of doctor issue ;;
    scripts/orch/*.sh)
      if [ "$state" != deleted ]; then
        [ -f "scripts/test/orch/$file_name" ] || unnamed
        sec_files+=("scripts/test/orch/$file_name")
      fi ;;
    scripts/test/orch/*.sh)
      [ "$state" = deleted ] || sec_files+=("$f") ;;
    scripts/hook-*.sh | hooks/hooks.json) want+=(hooks_test.sh) ;;
    scripts/test/hooks_test.sh) want+=(hooks_test.sh) ;;
    scripts/version-bump.sh | scripts/test/version_bump_test.sh) want+=(version_bump_test.sh) ;;
    scripts/autopilot-container.sh | scripts/test/autopilot_container_test.sh)
      want+=(autopilot_container_test.sh) ;;
    scripts/autopilot-up.sh | scripts/test/autopilot_up_test.sh) want+=(autopilot_up_test.sh) ;;
    scripts/dev/lens-bench.sh | scripts/test/lens_bench_test.sh | \
      scripts/dev/lens-bench/* | scripts/test/lens-bench/*)
      want+=(lens_bench_test.sh) ;;
    scripts/dev/hook-edit-width.sh | scripts/dev/width.sh | scripts/test/shell_code.awk)
      want+=(hooks_test.sh); sections_of harness ;;
    scripts/dev/*) sections_of harness ;;
    docker/* | .dockerignore) want+=(autopilot_container_test.sh autopilot_up_test.sh) ;;
    .claude-plugin/*) want+=(version_bump_test.sh autopilot_up_test.sh) ;;
    .shellcheckrc) sc_all=1; sections_of harness ;;
    .github/workflows/* | .gitignore | .gitattributes | .ignore | LICENSE | .claude/settings.json) return 0 ;;
    scripts/test/docs_lint.sh) ;;
    scripts/test/section-durations.tsv | scripts/test/suite-budget) return 0 ;;
    skills/* | agents/* | docs/* | changelog.d/* | *.md) return 0 ;;
    *) unnamed ;;
  esac
  if [ "$state" = present ]; then
    case "$f" in scripts/*.sh) sc_files+=("$f") ;; esac
  fi
}

# Row form: print each path with `named` or `none`, run nothing.
if [ "$row" -eq 1 ]; then
  for f in "${row_paths[@]}"; do
    status=0
    (classify "$f" present) >/dev/null 2>&1 || status=$?
    if [ "$status" -eq "$ROW_NONE" ]; then
      printf '%s\tnone\n' "$f"
    else
      printf '%s\tnamed\n' "$f"
    fi
  done
  exit 0
fi

merge_base="$(resolve_base)" || exit $?
[ -n "$merge_base" ] || full_suite

# changed: files present now (tracked changes and untracked); deleted: gone.
changed="$( { git_raw_paths diff --no-renames --name-only --diff-filter=d "$merge_base" --
  git_raw_paths ls-files --others --exclude-standard; } | LC_ALL=C sort -u)"
deleted="$(git_raw_paths diff --no-renames --name-only --diff-filter=D "$merge_base" -- | LC_ALL=C sort -u)"

while IFS= read -r f; do
  [ -n "$f" ] && classify "$f" present
done <<<"$changed"
while IFS= read -r f; do
  [ -n "$f" ] && classify "$f" deleted
done <<<"$deleted"

if [ "$core" -eq 1 ]; then
  sections_of harness loader
fi
if [ "$sc_all" -eq 1 ]; then
  shellcheck_files "$root"
  for f in "${SHELLCHECK_FILES[@]}"; do sc_files+=("${f#"$root/"}"); done
fi

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
      "test-helper placement ("* | "gh op placement ("* | "marked comment prelude placement ("* | "comment reader placement ("*)
        add_title "$t" ;;
    esac
  done < <(titles_of "$harness")
fi
if [ "${#sec_files[@]}" -gt 0 ]; then
  while IFS= read -r sf; do
    [ -f "$sf" ] || continue
    while IFS= read -r t; do
      add_title "$t"
    done < <(titles_of "$sf")
  done < <(printf '%s\n' "${sec_files[@]}" | LC_ALL=C sort -u)
fi

suites_load
# The suites to run, in all.sh's order: orch_test.sh and docs_lint.sh always.
selected=()
for suite in "${suites[@]}"; do
  case "$suite" in
    orch_test.sh | docs_lint.sh) selected+=("$suite") ;;
    *)
      [ "$core" -eq 1 ] && { selected+=("$suite"); continue; }
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
if [ "${#titles[@]}" -gt 0 ]; then
  only="$(printf '%s\n' "${titles[@]}" | titles_regex)"
fi

# shellcheck source=test_jobs.sh
source "$dir/test_jobs.sh"
# shellcheck source=report.sh
source "$dir/report.sh"
test_jobs_lower_priority
test_jobs_pool_init affected.sh || exit 1
export ORCH_TEST_QUIET=1
unset DOCS_LINT_RECORDING
tmp="$(mktemp -d)" || exit 1
pids=()
trap 'test_jobs_stop_children "${pids[@]}"' INT TERM
trap 'rm -rf "$tmp"' EXIT

# The suites other than orch_test.sh start first, in selection order, each under
# its slot, then orch_test.sh with none; pids and the report stay in selection
# order.
start_order=()
for suite_n in "${!selected[@]}"; do
  [ "${selected[$suite_n]}" = orch_test.sh ] || start_order+=("$suite_n")
done
for suite_n in "${!selected[@]}"; do
  [ "${selected[$suite_n]}" = orch_test.sh ] && start_order+=("$suite_n")
done
for suite_n in "${start_order[@]}"; do
  suite="${selected[$suite_n]}"
  if [ "$suite" = orch_test.sh ] && [ -n "$only" ]; then
    ORCH_TEST_ONLY="$only" test_jobs_suite_start "$tmp/$suite" bash "$dir/$suite"
  elif [ "$suite" = docs_lint.sh ]; then
    unset ORCH_TEST_ONLY
    test_jobs_slot_wait
    DOCS_LINT_BASE="$merge_base" test_jobs_suite_start "$tmp/$suite" bash "$dir/$suite"
  else
    unset ORCH_TEST_ONLY
    [ "$suite" = orch_test.sh ] || test_jobs_slot_wait
    test_jobs_suite_start "$tmp/$suite" bash "$dir/$suite"
  fi
  pids[suite_n]="$TEST_JOBS_SUITE_PID"
done

have_sc=0
sc_pid=""
if [ "${#sc_sorted[@]}" -gt 0 ] && command -v shellcheck >/dev/null 2>&1; then
  have_sc=1
  test_jobs_slot_wait
  test_jobs_job "${SHELLCHECK_CMD[@]}" "${sc_sorted[@]}" >"$tmp/shellcheck" 2>&1 &
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
