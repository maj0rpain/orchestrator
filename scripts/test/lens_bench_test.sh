#!/usr/bin/env bash
#
# Tests for scripts/dev/lens-bench.sh, the lens benchmark.
#
# The measure cases run `lens-bench.sh measure` on output directories laid out
# as `lens-bench.sh run` writes them - the committed, hand-built fixture under
# scripts/test/lens-bench/, or a copy of it with a file taken away - and
# asserts only what the run prints and its exit status. The failure modes
# worth catching: a split message counted twice, coverage judged by anything
# but the overlap rule, a summary over the wrong values, a turn labelled or a
# result's cost attributed to the wrong kind, and a broken directory measured
# instead of refused.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=git_env.sh
source "$DIR/test/git_env.sh"
test_git_env_clear || exit 1
BENCH="$DIR/dev/lens-bench.sh"
FIXTURE="$DIR/test/lens-bench"
PASS=0
FAIL=0

# ORCH_TEST_QUIET=1 hides the ok lines; the count, the FAIL lines,
# section headers and the summary still print.
ok()  { PASS=$((PASS + 1)); [ -n "${ORCH_TEST_QUIET:-}" ] || printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
assert_lacks()    { case "$2" in *"$3"*) bad "$1" "unexpected '$3' in: $2" ;; *) ok "$1" ;; esac; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }
assert_status()   { if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "expected exit $3, got exit $2"; fi; }

# The temp root, created before anything else: TMPDIR is exported as it, so
# every mktemp below lands inside it. The EXIT trap leaves the root, removes
# it, and keeps the exit status. An INT or TERM exits 130 through that trap.
bench_root="$(mktemp -d)" || {
  echo "lens_bench_test.sh: cannot create the suite's temp root" >&2; exit 1; }
export TMPDIR="$bench_root"
bench_remove_root() {
  local status=$?
  cd / || :
  rm -rf "$bench_root"
  exit "$status"
}
trap bench_remove_root EXIT
trap 'exit 130' INT TERM

# >>> checks

# run_bench <args...>: runs the tool, $bench_script when set, else $BENCH; its
# stdout lands in $out, its stderr in $err, its exit status in $st.
run_bench() {
  out="$(bash "${bench_script:-$BENCH}" "$@" 2>"$bench_root/stderr")"; st=$?
  err="$(<"$bench_root/stderr")"
}

echo "lens-bench tests"

echo
echo "usage errors"
for usage_case in "" "measure" "bogus" "measure -x" "seed implementability"; do
  # shellcheck disable=SC2086 # each case's words are its arguments
  run_bench $usage_case
  assert_status "'$usage_case' exits 2" "$st" 2
  assert_contains "'$usage_case' prints the usage line" "$err" "usage: lens-bench.sh measure <dir>..."
  assert_lacks "'$usage_case' offers no seed subcommand" "$err" "seed"
  assert_empty "'$usage_case' prints nothing on stdout" "$out"
done

# has_line <test> <output> <line>: <line> is one whole line of <output>.
has_line() {
  if grep -qxF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "no line '$3' in: $2"; fi
}

echo
echo "per-run rows"
run_bench measure "$FIXTURE/with-baseline"
assert_status "measuring a directory exits 0" "$st" 0
assert_empty "measuring a directory prints nothing on stderr" "$err"
has_line "heads the report with the directory" "$out" "## $FIXTURE/with-baseline"
has_line "names the lens, revision and model" "$out" \
  "Lens implementability, revision 0123456789abcdef0123456789abcdef01234567, model claude-opus-5-5"
has_line "a split message counts as one turn and its input once" "$out" \
  "| run-1 | 3 | 3468 | 2 2 0 | 3 2 | 11 | 18 2 7 4 11 | 3/5 |"
has_line "a run with no ranged read shows none" "$out" \
  "| run-2 | 2 | 300 | 1 0 | - | 3 | 5 5 1 | 2/5 |"
has_line "a run with no tool call and no map has one turn of no calls" "$out" \
  "| run-3 | 1 | 2000 | 0 | - | - | - | 0/5 |"
assert_lacks "prints no row for a missing run" "$out" "| run-4 |"

echo
echo "coverage"
# with-baseline/map.md: a.sh:10 (old format), a.sh:20-30, a.sh:40-45,
# b.sh:5-8, and c.sh:100 followed by a second location, c.sh:200.
has_line "counts each baseline line's first location alone" "$out" "Baseline map: 5 locations"
# run-1's map: a.sh:8-25 merges a.sh:10 and a.sh:20-30; a.sh:41-42 and
# a.sh:44-50 split a.sh:40-45; d.sh:5-8 has b.sh:5-8's range in another file;
# c.sh:195-205 overlaps only the ignored c.sh:200.
assert_contains "a merged entry covers both, a split pair one, another file's and an ignored location none" \
  "$out" "| 18 2 7 4 11 | 3/5 |"
# run-2's map: a.sh:11-15 misses the one-line a.sh:10; b.sh:1-5 meets
# b.sh:5-8 at one line; c.sh:100-100 is c.sh:100.
assert_contains "an old-format entry is one line, and a range meeting it at one line overlaps" \
  "$out" "| 5 5 1 | 2/5 |"
assert_contains "a run with no map covers nothing and shows no widths" "$out" "| - | 0/5 |"

echo
echo "the per-directory summary"
has_line "summarises over every run" "$out" "Summary over 3 runs:"
has_line "turns: mean, median, minimum, maximum" "$out" "| Turns | 2 | 2 | 1 | 3 |"
has_line "input: a mean apart from the median, to one decimal place" "$out" \
  "| Input | 1922.7 | 2000 | 300 | 3468 |"
has_line "coverage: a run with no map counts as 0" "$out" "| Coverage | 1.7/5 | 2/5 | 0/5 | 3/5 |"

echo
echo "no baseline map"
run_bench measure "$FIXTURE/no-baseline/"
assert_status "a directory with no baseline map exits 0" "$st" 0
has_line "heads the report with the directory, its trailing slash dropped" "$out" \
  "## $FIXTURE/no-baseline"
has_line "says there is no baseline map" "$out" "Baseline map: none, so no coverage"
has_line "a row has no coverage" "$out" "| run-1 | 2 | 300 | 1 0 | - | 3 | 5 5 1 |"
has_line "a run with no map shows no widths and no coverage" "$out" "| run-2 | 1 | 100 | 0 | - | - | - |"
assert_lacks "the table has no coverage column" "$out" "Coverage"
has_line "an even number of runs takes the median between the middle two" "$out" \
  "| Turns | 1.5 | 1.5 | 1 | 2 |"
has_line "the summary has input" "$out" "| Input | 200 | 200 | 100 | 300 |"

echo
echo "the summary rounds half up"
# Four runs of 1, 1, 1 and 2 turns: a mean of 1.25, an exact tie at one decimal.
run_bench measure "$FIXTURE/tie"
has_line "a mean tied at 1.25 prints 1.3" "$out" "| Turns | 1.3 | 1 | 1 | 2 |"

echo
echo "more than one directory"
run_bench measure "$FIXTURE/with-baseline" "$FIXTURE/no-baseline"
assert_status "two directories exit 0" "$st" 0
assert_eq "reports each directory under its own heading, in order" \
  "$(grep -E '^## ' <<<"$out")" \
  "$(printf '## %s\n## %s' "$FIXTURE/with-baseline" "$FIXTURE/no-baseline")"
has_line "each directory has its own summary" "$out" "Summary over 2 runs:"

echo
echo "the diagnosis: turn labels"
# diagnosis/spec.md names `alpha.sh` and `beta`, and a fenced block whose
# backticks name nothing. run-1's five turns, of context 1000, 1400, 1600,
# 2000 and 2100: the spec's Read and a Glob for alpha.sh (mixed); a ranged
# Read of alpha.sh and a Grep for beta, one message split over two lines
# (named); a whole Read of other.sh and a Write (unnamed); then two turns with
# no tool call (unnamed). run-2: a Grep for gamma, then a reply (500, 600).
run_bench measure "$FIXTURE/diagnosis"
assert_status "measuring the diagnosis fixture exits 0" "$st" 0
has_line "labels each turn, and the shares of turns and of input add up to the whole" "$out" \
  "| run-1 | 1 (20%) | 1 (20%) | 3 (60%) | 1400 (17.3%) | 1000 (12.3%) | 5700 (70.4%) |"
has_line "a run whose every turn locates nothing named is all unnamed" "$out" \
  "| run-2 | 0 (0%) | 0 (0%) | 2 (100%) | 0 (0%) | 0 (0%) | 1100 (100%) |"
has_line "the labels are summed per directory" "$out" \
  "| All runs | 1 (14.3%) | 1 (14.3%) | 5 (71.4%) | 1400 (15.2%) | 1000 (10.9%) | 6800 (73.9%) |"

echo
echo "the diagnosis: carried cost by kind"
has_line "kinds are columns, each other tool by its name" "$out" \
  "| Run | Fixed base | The spec | Ranged reads | Whole reads | Grep/Glob | Write | Assistant output |"
# run-1: the base is 1000 x 5 turns. Turn 2's growth of 400 splits 300:100
# between the spec and the Glob, times the 4 turns left; turn 3's 200 splits
# 150:50 between the ranged Read and the Grep, times 3; turn 4's 400 splits
# 60:20 between the whole Read and the Write, times 2; turn 5's 100 has no
# result before it, so it is assistant output, times 1.
has_line "growth is split by characters, carried over the turns left, and the base is the first turn's context times the turns" "$out" \
  "| run-1 | 5000 (61.7%) | 1200 (14.8%) | 450 (5.6%) | 600 (7.4%) | 550 (6.8%) | 200 (2.5%) | 100 (1.2%) |"
has_line "a kind a run never used is 0" "$out" \
  "| run-2 | 1000 (90.9%) | 0 (0%) | 0 (0%) | 0 (0%) | 100 (9.1%) | 0 (0%) | 0 (0%) |"
has_line "the carried cost is summed per directory" "$out" \
  "| All runs | 6000 (65.2%) | 1200 (13%) | 450 (4.9%) | 600 (6.5%) | 650 (7.1%) | 200 (2.2%) | 100 (1.1%) |"
run_bench measure "$FIXTURE/no-baseline"
has_line "a directory whose runs use no other tool has no column for one" "$out" \
  "| Run | Fixed base | The spec | Ranged reads | Whole reads | Grep/Glob | Assistant output |"

echo
echo "the diagnosis: code spans"
# A copy of the diagnosis fixture whose spec adds the double-backtick span
# ``x `gamma` y``: one name, `x `gamma` y`, so run-2's Grep for gamma, which
# does not contain it, still locates nothing named.
cp -R "$FIXTURE/diagnosis" "$bench_root/spans"
printf '\nAlso ``x `gamma` y``.\n' >>"$bench_root/spans/spec.md"
run_bench measure "$bench_root/spans"
has_line "a double-backtick span is one name, not the single-backtick spans inside it" "$out" \
  "| run-2 | 0 (0%) | 0 (0%) | 2 (100%) | 0 (0%) | 0 (0%) | 1100 (100%) |"

# A copy whose spec adds an indented code block naming `gamma`: a code block
# holds no spans, so run-2's Grep for gamma still locates nothing named.
cp -R "$FIXTURE/diagnosis" "$bench_root/indented"
printf '\n    `gamma` in an indented code block\n' >>"$bench_root/indented/spec.md"
run_bench measure "$bench_root/indented"
has_line "an indented code block names nothing" "$out" \
  "| run-2 | 0 (0%) | 0 (0%) | 2 (100%) | 0 (0%) | 0 (0%) | 1100 (100%) |"
# A list item's indented continuation is the item's text, not a code block.
cp -R "$FIXTURE/diagnosis" "$bench_root/item"
printf '\n- an item\n\n    naming `gamma`\n' >>"$bench_root/item/spec.md"
run_bench measure "$bench_root/item"
has_line "a list item's indented paragraph names what it backticks" "$out" \
  "| run-2 | 1 (50%) | 0 (0%) | 1 (50%) | 500 (45.5%) | 0 (0%) | 600 (54.5%) |"
# A paragraph line opening with `#c` is no heading, so the span opened on the
# line before closes on it, `b #c`, and the backtick after gamma is literal.
cp -R "$FIXTURE/diagnosis" "$bench_root/hash"
printf '\na `b\n#c` gamma ` d\n' >>"$bench_root/hash/spec.md"
run_bench measure "$bench_root/hash"
has_line "a line opening with # and no space continues the paragraph" "$out" \
  "| run-2 | 0 (0%) | 0 (0%) | 2 (100%) | 0 (0%) | 0 (0%) | 1100 (100%) |"
# A fence at a nested list item's content column opens a fenced code block,
# which holds no spans, though it sits four spaces in.
cp -R "$FIXTURE/diagnosis" "$bench_root/item-fence"
printf '\n- an item\n  - a sub-item\n    ```\n    gamma\n    ```\n' >>"$bench_root/item-fence/spec.md"
run_bench measure "$bench_root/item-fence"
has_line "a fenced code block in a list item names nothing" "$out" \
  "| run-2 | 0 (0%) | 0 (0%) | 2 (100%) | 0 (0%) | 0 (0%) | 1100 (100%) |"

echo
echo "the diagnosis: matching names"
# names_measure <dir> <spans>: a copy of the diagnosis fixture, named <dir>,
# whose spec also gives the code spans <spans>, measured.
names_measure() {
  cp -R "$FIXTURE/diagnosis" "$bench_root/$1"
  printf '\nAlso %s.\n' "$2" >>"$bench_root/$1/spec.md"
  run_bench measure "$bench_root/$1"
}
# `d` and `-` are in every path the runs read, `/d/repo/other.sh`, and `j`
# and `@@` are no code: none is a name a call can locate.
names_measure short '`d`, `-`, `j` and `@@`'
has_line "a span shorter than 3 characters, or with no letter, digit or underscore, locates nothing" "$out" \
  "| run-1 | 1 (20%) | 1 (20%) | 3 (60%) | 1400 (17.3%) | 1000 (12.3%) | 5700 (70.4%) |"
# `repo` is a directory of other.sh's path but not a path itself, and
# `her.sh` ends that path but not after a `/`.
names_measure paths '`repo` and `her.sh`'
has_line "a Read locates only a path-like name its path is, or ends in after a slash" "$out" \
  "| run-1 | 1 (20%) | 1 (20%) | 3 (60%) | 1400 (17.3%) | 1000 (12.3%) | 5700 (70.4%) |"
# run-2's one call is a Grep for gamma, its first turn of 500.
names_measure part '`gam`'
has_line "a Grep locates a name only as a whole token of its pattern" "$out" \
  "| run-2 | 0 (0%) | 0 (0%) | 2 (100%) | 0 (0%) | 0 (0%) | 1100 (100%) |"
names_measure whole '`gamma`'
has_line "a Grep whose pattern is a name locates it" "$out" \
  "| run-2 | 1 (50%) | 0 (0%) | 1 (50%) | 500 (45.5%) | 0 (0%) | 600 (54.5%) |"

# broken <name> <file under with-baseline>: a copy of with-baseline, named
# <name>, with <file> removed. Prints its path.
broken() {
  local copy="$bench_root/$1"
  cp -R "$FIXTURE/with-baseline" "$copy"
  rm -rf "${copy:?}/$2"
  printf '%s\n' "$copy"
}
# refused <test> <dir> <named>: measuring <dir> after the good fixture exits
# 1, names <named> on stderr and prints no report.
refused() {
  run_bench measure "$FIXTURE/no-baseline" "$2"
  assert_status "$1: exits 1" "$st" 1
  assert_contains "$1: names it" "$err" "$3"
  assert_empty "$1: prints no report" "$out"
}

echo
echo "refusals"
refused "a directory that does not exist" "$bench_root/nowhere" "$bench_root/nowhere"
for file in lens revision model spec.md; do
  d="$(broken "no-$file" "$file")"
  refused "a directory missing its $file" "$d" "$d/$file"
done
d="$(broken no-transcript run-2/transcript.jsonl)"
refused "a run subdirectory with no transcript" "$d" "$d/run-2/transcript.jsonl"
d="$(broken slash-no-lens lens)"
refused "a directory given with a trailing slash names its missing file once-slashed" \
  "$d/" "$d/lens: missing"
d="$(broken slash-no-transcript run-2/transcript.jsonl)"
refused "a directory given with a trailing slash names its missing transcript once-slashed" \
  "$d/" "$d/run-2/transcript.jsonl: missing"
d="$(broken slashes-no-lens lens)"
refused "a directory given with several trailing slashes names its missing file once-slashed" \
  "$d//" "$d/lens: missing"

echo
echo "run: usage errors"
mkdir "$bench_root/usage"
cd "$bench_root/usage" || exit 1
for usage_case in "run" "run implementability" "run implementability --definition HEAD" \
  "run implementability --out x" "run implementability --definition HEAD --out x -n" \
  "run implementability --definition HEAD --out x -n 0" \
  "run implementability --definition HEAD --out x -n two" \
  "run implementability --definition HEAD --out x --model" \
  "run implementability --definition HEAD --out x --bogus" \
  "run implementability extra --definition HEAD --out x"; do
  # shellcheck disable=SC2086 # each case's words are its arguments
  run_bench $usage_case
  assert_status "'$usage_case' exits 2" "$st" 2
  assert_contains "'$usage_case' prints the run usage line" "$err" \
    "lens-bench.sh run <lens> --definition <rev> --out <dir> [-n N] [--model M]"
done
assert_eq "a usage error creates no output directory" "$(ls -A)" ""
cd "$OLDPWD" || exit 1

# A scratch repo holding the tool and an implementability fixture, so run's
# checks read a history of the suite's own making: its first commit has no
# lens definition and is the fixture's snapshot, its second adds one.
bench_repo="$bench_root/repo"
bench_git() { git -C "$bench_repo" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$bench_repo/scripts/dev/lens-bench/implementability" "$bench_repo/agents"
cp "$BENCH" "$bench_repo/scripts/dev/lens-bench.sh"
git init -q "$bench_repo"
echo snapshot >"$bench_repo/README"
bench_git add README
bench_git commit -qm snapshot
no_definition="$(bench_git rev-parse HEAD)"
cat >"$bench_repo/agents/orch-lens-implementability.md" <<'DEF'
---
name: orch-lens-implementability
description: The test lens.
tools: [Read, Grep, Glob, Write]
---

# Test lens

Read the spec.
DEF
bench_git add agents
bench_git commit -qm definition
definition="$(bench_git rev-parse HEAD)"
bench_fixture="$bench_repo/scripts/dev/lens-bench/implementability"
printf 'The `spec` body.\n' >"$bench_fixture/spec.md"
printf 'a.sh:1 the baseline\n' >"$bench_fixture/map.md"
printf '%s\n' "${no_definition:0:7}" >"$bench_fixture/snapshot"
BENCH_COPY="$bench_repo/scripts/dev/lens-bench.sh"

# run_copy <args...>: run_bench, on the scratch repo's copy of the tool.
run_copy() { bench_script="$BENCH_COPY" run_bench "$@"; }
# worktrees: how many worktrees the scratch repo has, its main one counted.
worktrees() { bench_git worktree list | awk 'END { print NR }'; }
# leftovers: the tool's temporary directories still under the temp root.
leftovers() { find "$bench_root" -maxdepth 1 -name 'lens-bench.*' | awk 'END { print NR }'; }

# run_refused <test> <named> <args...>: run exits 1 naming <named>, and leaves
# no worktree and no temporary directory behind, nor the output directory its
# --out names unless that existed before.
run_refused() {
  local name="$1" named="$2" out_dir="" existed="" arg prev=""
  shift 2
  for arg in "$@"; do
    [ "$prev" != --out ] || out_dir="$arg"
    prev="$arg"
  done
  [ ! -e "$out_dir" ] || existed=1
  run_copy run "$@"
  assert_status "$name: exits 1" "$st" 1
  [ -n "$existed" ] ||
    assert_eq "$name: creates no output directory" "$([ -e "$out_dir" ] && echo yes)" ""
  assert_contains "$name: names it" "$err" "$named"
  assert_eq "$name: creates no worktree" "$(worktrees)" 1
  assert_eq "$name: leaves no temporary directory" "$(leftovers)" 0
}

echo
echo "run: refusals before claude starts"
run_refused "an unknown lens" "nosuch" nosuch --definition "$definition" --out "$bench_root/out-a"
run_refused "a lens name that climbs out" "..: unknown lens, no fixture directory" .. --definition "$definition" --out "$bench_root/out-e"
run_refused "a lens name with a slash" "a/b: unknown lens, no fixture directory" \
  a/b --definition "$definition" --out "$bench_root/out-f"
run_refused "a revision without the lens's definition" "agents/orch-lens-implementability.md" \
  implementability --definition "$no_definition" --out "$bench_root/out-b"
run_refused "a revision that does not exist" "nosuchrev" \
  implementability --definition nosuchrev --out "$bench_root/out-c"
mkdir "$bench_root/out-d"
run_refused "an output directory that already exists" "$bench_root/out-d" \
  implementability --definition "$definition" --out "$bench_root/out-d"
assert_eq "an existing output directory: is left empty" "$(ls -A "$bench_root/out-d")" ""

# A fake claude on PATH, standing in for the live one past run's checks: it
# logs its working directory to $bench_root/claude.cwd.<call>, the commit
# checked out there to claude.head.<call>, and its
# arguments as a JSON array to $bench_root/claude.args.<call>, writes
# a map to the prompt's map path, leaves a lens-new transcript under
# $HOME/.claude/projects/ and prints its session id. Its Nth call, counted in
# $bench_root/claude.calls, fails when FAKE_CLAUDE_FAIL is N, and leaves no
# transcript when FAKE_CLAUDE_NO_TRANSCRIPT is N.
mkdir -p "$bench_root/bin" "$bench_root/home"
cat >"$bench_root/bin/claude" <<'FAKE'
#!/usr/bin/env bash
calls="$(($(cat "$BENCH_ROOT/claude.calls" 2>/dev/null || echo 0) + 1))"
echo "$calls" >"$BENCH_ROOT/claude.calls"
echo "$PWD" >"$BENCH_ROOT/claude.cwd.$calls"
git rev-parse HEAD >"$BENCH_ROOT/claude.head.$calls"
jq -n '$ARGS.positional' --args -- "$@" >"$BENCH_ROOT/claude.args.$calls"
[ "${FAKE_CLAUDE_FAIL:-}" != "$calls" ] || exit 3
prompt="$2"
printf 'a.sh:1-3 found\n' >"$(sed -n 5p <<<"$prompt")"
if [ "${FAKE_CLAUDE_NO_TRANSCRIPT:-}" != "$calls" ]; then
  sub="$HOME/.claude/projects/-fake/session-$calls/subagents"
  mkdir -p "$sub"
  printf '{"type":"assistant","n":%s}\n' "$calls" >"$sub/agent-a$calls.jsonl"
  echo '{"agentType":"lens-new"}' >"$sub/agent-a$calls.meta.json"
  echo '{"type":"assistant"}' >"$sub/agent-other.jsonl"
fi
printf '{"session_id":"session-%s"}\n' "$calls"
FAKE
chmod +x "$bench_root/bin/claude"

# fake_run <args...>: run_copy run, with the fake claude, its call count reset.
fake_run() {
  rm -rf "$bench_root"/claude.calls "$bench_root"/claude.cwd.* "$bench_root"/claude.head.* \
    "$bench_root"/claude.args.* \
    "$bench_root/home/.claude"
  PATH="$bench_root/bin:$PATH" HOME="$bench_root/home" BENCH_ROOT="$bench_root" \
    run_copy run "$@"
}

echo
echo "run: collecting runs (fake claude)"
fake_run implementability --definition "${definition:0:7}" --out "$bench_root/runs" -n 2
assert_status "two runs exit 0" "$st" 0
assert_eq "records the lens" "$(cat "$bench_root/runs/lens")" implementability
assert_eq "records the revision as its full SHA" "$(cat "$bench_root/runs/revision")" "$definition"
assert_eq "records the default model" "$(cat "$bench_root/runs/model")" claude-opus-5-5
assert_eq "copies the fixture's spec body" "$(cat "$bench_root/runs/spec.md")" 'The `spec` body.'
assert_eq "copies the fixture's baseline map" "$(cat "$bench_root/runs/map.md")" "a.sh:1 the baseline"
assert_eq "collects one subdirectory per run" "$(cd "$bench_root/runs" && ls -d run-*)" \
  "$(printf 'run-1\nrun-2')"
assert_eq "copies the lens-new transcript of each run's session" \
  "$(cat "$bench_root/runs/run-2/transcript.jsonl")" '{"type":"assistant","n":2}'
assert_eq "copies the map the lens wrote" "$(cat "$bench_root/runs/run-1/map.md")" "a.sh:1-3 found"
assert_eq "removes the worktree after the runs" "$(worktrees)" 1
assert_eq "removes its temporary directory after the runs" "$(leftovers)" 0
args="$(cat "$bench_root/claude.args.1")"
# arg_after <flag>: the argument after <flag> in claude's first call.
arg_after() { jq -r --arg f "$1" '. as $a | (index($f)) as $i | $a[$i + 1]' <<<"$args"; }
prompt="$(arg_after -p)"
assert_eq "starts claude from the snapshot worktree, the prompt's repo root" \
  "$(cat "$bench_root/claude.cwd.1")" "$(sed -n 4p <<<"$prompt")"
assert_eq "the worktree has the snapshot checked out" "$(cat "$bench_root/claude.head.1")" \
  "$no_definition"
assert_eq "pins the model" "$(arg_after --model)" claude-opus-5-5
agents="$(arg_after --agents)"
assert_eq "defines the definition as the agent lens-new" \
  "$(jq -c '."lens-new" | {description, tools, model}' <<<"$agents")" \
  '{"description":"The test lens.","tools":["Read","Grep","Glob","Write"],"model":"claude-opus-5-5"}'
assert_eq "gives lens-new the definition's body as its prompt" \
  "$(jq -r '."lens-new".prompt' <<<"$agents")" "$(printf '# Test lens\n\nRead the spec.')"
assert_eq "asks the session to start lens-new with the paths and nothing else" \
  "$(sed -n 1p <<<"$prompt")" \
  "Start the lens-new subagent with exactly this prompt and nothing else, then reply with its reply:"
assert_eq "gives the six paths, each run's under the standard names" \
  "$(sed -n '2p;3p;5p;6p;7p' <<<"$prompt" | sed 's|.*/||')" \
  "$(printf 'spec.md\ncomments.md\nmap-implementability.md\nsettled.md\nlens-implementability.md')"
assert_eq "the prompt is those seven lines" "$(wc -l <<<"$prompt" | tr -d ' ')" 7

fake_run implementability --definition "$definition" --out "$bench_root/runs-model" -n 1 --model m-1
assert_eq "--model pins another model" "$(cat "$bench_root/runs-model/model")" m-1

echo
echo "run: a failing run (fake claude)"
FAKE_CLAUDE_FAIL=2 fake_run implementability --definition "$definition" --out "$bench_root/runs-fail" -n 3
assert_status "a failed claude -p exits 1" "$st" 1
assert_contains "a failed claude -p names the run" "$err" "run-2"
assert_eq "a failed claude -p keeps the finished runs and removes its own" \
  "$(cd "$bench_root/runs-fail" && ls -d run-*)" run-1
assert_eq "a failed claude -p starts no later run" "$(cat "$bench_root/claude.calls")" 2
assert_eq "a failed claude -p removes the worktree" "$(worktrees)" 1
assert_eq "a failed claude -p removes its temporary directory" "$(leftovers)" 0
FAKE_CLAUDE_NO_TRANSCRIPT=2 fake_run implementability --definition "$definition" \
  --out "$bench_root/runs-lost" -n 3
assert_status "a missing transcript exits 1" "$st" 1
assert_contains "a missing transcript names the run" "$err" "run-2"
assert_eq "a missing transcript keeps the finished runs and removes its own" \
  "$(cd "$bench_root/runs-lost" && ls -d run-*)" run-1
assert_eq "a missing transcript removes the worktree" "$(worktrees)" 1

# >>> summary
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
