#!/usr/bin/env bash
# lens-bench.sh run <lens> --definition <rev> --out <dir> [-n N] [--model M]
# lens-bench.sh measure <dir>...
#
# The lens benchmark. `run` starts N headless runs (default 5) of one lens
# definition, `agents/orch-lens-<lens>.md` read at git revision <rev>, on model
# M (default claude-opus-5-5), against the lens's fixture,
# scripts/dev/lens-bench/<lens>/, and collects them into <dir>, which it
# creates. `measure` turns one or more such directories into a Markdown report
# on stdout.
#
# A fixture holds `spec.md`, the spec body the lens reads; `map.md`, the
# baseline map, when it has one; and `snapshot`, one line, the commit `run`
# checks out in a temporary git worktree for the lens to explore. Each run
# reads its six paths - spec body, comments file, repo root (the worktree),
# map file, settled file and findings file - from a run directory of its own,
# `spec.md`, `comments.md`, `map-<lens>.md`, `settled.md` and `lens-<lens>.md`;
# round 1 has no map or settled file, so those two do not exist. `claude -p`
# runs from the worktree, defining the definition as the agent `lens-new` and
# asking the session to start it with the six paths. The worktree is removed
# when the runs end or fail.
#
# A directory holds `lens`, `revision` (the full SHA) and `model`, one line
# each; `spec.md`, the fixture's spec body; `map.md`, the fixture's baseline
# map, when it has one; and one subdirectory per run, `run-1` to `run-N`, each
# holding `transcript.jsonl`, the lens agent's transcript, and `map.md`, the
# map the lens wrote, when it wrote one.
#
# Per directory, the report gives one row per run - turns (unique assistant
# message ids), total input tokens (input + cache read + cache creation,
# counted once per unique assistant message id), tool calls per turn, the
# lines each ranged Read returned, the characters each Grep returned, each map
# entry's range width and, with a baseline map, coverage - then the mean,
# median, minimum and maximum of turns, input and coverage over its runs.
#
# Coverage counts the baseline locations a run's map covers: an entry for the
# same file whose line range overlaps the location's. A map line's location is
# its first `<path>:<start>-<end>` or `<path>:<line>`, the latter the one-line
# range `<line>-<line>`; anything after it on the line is ignored. A run with
# no map has coverage 0 where there is a baseline map.
#
# Then the diagnosis, per run and summed over the directory's runs. Each code
# span (backticked text) in `spec.md`, as CommonMark reads one, is a name the
# spec gives. A Read locates spec-named code when its path is a path-like name
# (one with no space that holds a `/` or ends in an extension), or ends in `/`
# and one; a Grep or Glob, when its pattern holds a name of 3 or more
# characters, one of them a letter, digit or underscore, as a whole token, with
# no letter, digit or underscore either side. A turn is `named` when all its
# calls do, `mixed` when some do, and `unnamed` when none do or it makes no
# call; the report gives each label's share of turns and of input. Beside it,
# the carried cost by kind: a tool result's kind is `the spec` for the Read of
# the first path in the lens's prompt, a ranged read for any other Read passing
# offset or limit, a whole read for one passing neither, Grep/Glob for both, and
# any other tool by its name. A turn's growth over the previous turn's context
# is split among the results read since then by character count, or is assistant
# output when there are none, and is carried over the turns left from that turn
# on; the fixed base is the first turn's context times the number of turns.
#
# A repo-development tool: it does not ship to users. Usage errors exit 2.
# `run` exits 1 naming the problem, having created no output directory and no
# worktree, on an unknown lens (no fixture directory), a revision with no
# definition of the lens, or an output directory that already exists; when a
# run's `claude -p` fails or leaves no lens transcript, it exits 1 naming the
# run, removing that run's subdirectory and keeping the runs before it.
# `measure` exits 1 naming it on a missing directory, a directory missing its
# lens, revision or model file or its spec body, or a run with no transcript,
# before any report is printed.
set -euo pipefail

usage() {
  printf 'usage: %s run <lens> --definition <rev> --out <dir> [-n N] [--model M]\n' "${0##*/}" >&2
  printf 'usage: %s measure <dir>...\n' "${0##*/}" >&2
  exit 2
}

fail() {
  printf 'lens-bench.sh: %s\n' "$1" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The temporary directory `run` holds its worktree of the repo run_repo and
# its run directories in, and the output run subdirectory `run` is writing,
# both removed on exit.
run_tmp="" run_partial="" run_repo=""
run_cleanup() {
  local status=$?
  if [ -n "$run_tmp" ]; then
    git -C "$run_repo" worktree remove --force "$run_tmp/repo" 2>/dev/null || :
    rm -rf "$run_tmp"
    git -C "$run_repo" worktree prune 2>/dev/null || :
  fi
  [ -z "$run_partial" ] || rm -rf "$run_partial"
  exit "$status"
}

# snapshot_worktree <snapshot>: arms run_cleanup, makes run_tmp, and checks
# <snapshot> out of run_repo in a detached worktree at $run_tmp/repo.
snapshot_worktree() {
  trap run_cleanup EXIT
  trap 'exit 130' INT TERM
  run_tmp="$(mktemp -d "${TMPDIR:-/tmp}/lens-bench.XXXXXX")"
  git -C "$run_repo" worktree add --quiet --detach "$run_tmp/repo" "$1" >/dev/null 2>&1 ||
    fail "$1: cannot check out the snapshot in a worktree"
}

# lens_fixture <lens>: the path of <lens>'s committed fixture directory,
# failing when there is none.
lens_fixture() {
  local fixture="$SCRIPT_DIR/lens-bench/$1" shaped=1
  # A bad-shaped name counts as missing: . and .. would resolve to a directory.
  case "$1" in
    */* | .*) shaped="" ;;
  esac
  [ -n "$shaped" ] && [ -d "$fixture" ] || fail "$1: unknown lens, no fixture directory $fixture"
  printf '%s\n' "$fixture"
}

# no_trailing_slashes <path>: <path> without its trailing slashes, so every
# message names one path; a lone / stays itself.
no_trailing_slashes() {
  local path="$1"
  while [[ "$path" == */ && "$path" != / ]]; do path="${path%/}"; done
  printf '%s\n' "$path"
}

# frontmatter <file> <key>: the value of <key> in <file>'s frontmatter, one
# pair of surrounding quotes dropped.
frontmatter() {
  awk -v key="$2" '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside && index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\x27.*\x27$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "$1"
}

# body <file>: <file> after its frontmatter, leading blank lines dropped.
body() {
  awk '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside { if ($0 == "---") inside = 0; next }
    !started && $0 == "" { next }
    { started = 1; print }' "$1"
}

# lens_transcript <session>: the lens agent's transcript in <session>'s
# subagents directory: the one whose meta names agent type lens-new, or the
# only one there is. Prints nothing when there is none.
lens_transcript() {
  local projects="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" t found="" count=0
  for t in "$projects"/*/"$1"/subagents/agent-*.jsonl; do
    [ -f "$t" ] || continue
    count=$((count + 1))
    if [ -f "${t%.jsonl}.meta.json" ] &&
      [ "$(jq -r '.agentType // empty' "${t%.jsonl}.meta.json" 2>/dev/null)" = lens-new ]; then
      printf '%s\n' "$t"
      return
    fi
    found="$t"
  done
  [ "$count" -ne 1 ] || printf '%s\n' "$found"
}

cmd_run() {
  local lens="" rev="" out="" n=5 model=claude-opus-5-5
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --definition) [ "$#" -ge 2 ] || usage; rev="$2"; shift 2 ;;
      --out) [ "$#" -ge 2 ] || usage; out="$2"; shift 2 ;;
      -n) [ "$#" -ge 2 ] || usage; n="$2"; shift 2 ;;
      --model) [ "$#" -ge 2 ] || usage; model="$2"; shift 2 ;;
      -*) usage ;;
      *) [ -z "$lens" ] || usage; lens="$1"; shift ;;
    esac
  done
  [ -n "$lens" ] && [ -n "$rev" ] && [ -n "$out" ] && [ -n "$model" ] || usage
  case "$n" in '' | *[!0-9]* | 0*) usage ;; esac

  # Every check before anything is created.
  local fixture
  fixture="$(lens_fixture "$lens")" || exit
  [ -f "$fixture/spec.md" ] || fail "$fixture/spec.md: missing"
  [ -f "$fixture/snapshot" ] || fail "$fixture/snapshot: missing"
  run_repo="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)" || fail "$SCRIPT_DIR: not in a git repo"
  local sha definition="agents/orch-lens-$lens.md" snapshot_ref snapshot
  sha="$(git -C "$run_repo" rev-parse --verify --quiet "$rev^{commit}")" ||
    fail "$rev: not a commit"
  git -C "$run_repo" cat-file -e "$sha:$definition" 2>/dev/null ||
    fail "$rev: no $definition at that revision"
  snapshot_ref="$(<"$fixture/snapshot")"
  snapshot="$(git -C "$run_repo" rev-parse --verify --quiet "$snapshot_ref^{commit}")" ||
    fail "$fixture/snapshot: $snapshot_ref is not a commit"
  [ ! -e "$out" ] && [ ! -L "$out" ] || fail "$out: already exists"
  command -v claude >/dev/null || fail "claude: not on PATH"

  snapshot_worktree "$snapshot"
  local agent="$run_tmp/definition.md" agents worktree="$run_tmp/repo"
  git -C "$run_repo" show "$sha:$definition" >"$agent"
  agents="$(jq -n \
    --arg description "$(frontmatter "$agent" description)" \
    --arg tools "$(frontmatter "$agent" tools)" \
    --arg prompt "$(body "$agent")" \
    --arg model "$model" \
    '{"lens-new": {description: $description,
      tools: ($tools | ltrimstr("[") | rtrimstr("]") | split(",")
              | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))),
      prompt: $prompt, model: $model}}')"

  mkdir -p "$out"
  printf '%s\n' "$lens" >"$out/lens"
  printf '%s\n' "$sha" >"$out/revision"
  printf '%s\n' "$model" >"$out/model"
  cp "$fixture/spec.md" "$out/spec.md"
  [ ! -f "$fixture/map.md" ] || cp "$fixture/map.md" "$out/map.md"

  local i dir prompt reply session transcript
  for ((i = 1; i <= n; i++)); do
    dir="$run_tmp/run-$i"
    mkdir "$dir"
    cp "$fixture/spec.md" "$dir/spec.md"
    : >"$dir/comments.md"
    prompt="Start the lens-new subagent with exactly this prompt and nothing else, then reply with its reply:"
    prompt+=$'\n'"$dir/spec.md"$'\n'"$dir/comments.md"$'\n'"$worktree"
    prompt+=$'\n'"$dir/map-$lens.md"$'\n'"$dir/settled.md"$'\n'"$dir/lens-$lens.md"
    printf 'run-%s of %s...\n' "$i" "$n" >&2
    run_partial="$out/run-$i"
    reply="$(cd "$worktree" && claude -p "$prompt" --model "$model" --agents "$agents" \
      --permission-mode acceptEdits --add-dir "$dir" --output-format json)" ||
      fail "run-$i: claude -p failed"
    session="$(jq -r '.session_id // empty' <<<"$reply" 2>/dev/null)" || session=""
    [ -n "$session" ] || fail "run-$i: claude -p printed no session id"
    transcript="$(lens_transcript "$session")"
    [ -n "$transcript" ] || fail "run-$i: no lens transcript for session $session"
    mkdir "$run_partial"
    cp "$transcript" "$run_partial/transcript.jsonl"
    [ ! -f "$dir/map-$lens.md" ] || cp "$dir/map-$lens.md" "$run_partial/map.md"
    run_partial=""
  done
  printf '%s: %s runs\n' "$out" "$n" >&2
}

# runs_of <dir>: the names of <dir>'s run subdirectories, run-1 first, in
# numeric order.
runs_of() {
  local run
  for run in "$1"/run-*/; do
    [ -d "$run" ] || continue
    run="${run%/}"
    printf '%s\n' "${run##*/}"
  done | sort -t- -k2,2n
}

# locations <map>: one `<path> <start> <end>` line per line of <map> that
# opens with a location, `<path>:<start>-<end>` or `<path>:<line>`, after any
# list marker or backtick; anything after the first location is ignored.
locations() {
  awk '
    {
      line = $0
      sub(/^[[:space:]]*([-*][[:space:]]+)?`?/, "", line)
      if (!match(line, /^[^[:space:]`:]+:[0-9]+(-[0-9]+)?/)) next
      loc = substr(line, 1, RLENGTH)
      n = split(loc, part, ":")
      path = part[1]
      for (i = 2; i < n; i++) path = path ":" part[i]
      split(part[n], range, "-")
      print path, range[1], (range[2] == "" ? range[1] : range[2])
    }' "$1"
}

# widths <map>: each of <map>'s entries' range widths, space-separated, or -
# when it has none.
widths() {
  locations "$1" | awk '{ w = w (NR > 1 ? " " : "") ($3 - $2 + 1) } END { print (w == "" ? "-" : w) }'
}

# overlap <baseline> <map>: how many of <baseline>'s locations an entry of
# <map> covers, then how many of <map>'s entries cover none of them, space
# separated. An entry covers a location for the same path whose line range
# overlaps the location's.
overlap() {
  awk '
    FNR == NR { path[NR] = $1; from[NR] = $2; to[NR] = $3; n = NR; next }
    { hit_any = 0
      for (i = 1; i <= n; i++)
        if ($1 == path[i] && $2 <= to[i] && from[i] <= $3) { hit[i] = 1; hit_any = 1 }
      if (!hit_any) outside++ }
    END { c = 0; for (i in hit) c++; print c, outside + 0 }' \
    <(locations "$1") <(locations "$2")
}

# covered <baseline> <map>: how many of <baseline>'s locations an entry of
# <map> covers.
covered() {
  overlap "$1" "$2" | cut -d' ' -f1
}

# SPANS_AWK reads a Markdown file's spans, as CommonMark reads them, and
# prints each as `<kind><TAB><text>`, in the order they open, the kind `code`
# or `bold`. A code span: a run of N backticks opens a span that only a run of
# exactly N closes, a run with no such closer is literal, a backslash-escaped
# backtick opens nothing, a line ending inside a span is a space, and one
# leading and one trailing space are dropped when both are there and the span
# is not all spaces. A bold span: `**` opening and closing on one line, both
# outside code spans and not backslash-escaped; its text keeps any code span
# inside it, which is a code span too. A span lies within one block - a
# paragraph, a list item or a heading (one to six #s, then a space, a tab or
# the line's end) - and a code block, fenced or indented, holds none.
# Indentation is measured from the content column of the list item holding
# the line, if any: a fence opens or closes within three columns of it, and a
# line four or more columns past it is an indented code block's when no
# paragraph is open for it to continue.
SPANS_AWK='
  function run_end(s, i, n) { while (i <= n && substr(s, i, 1) == "`") i++; return i }
  # span_close(s, i, n): where the code span the backtick run at i opens
  # closes, or 0 when the run is literal.
  function span_close(s, i, n,   j, k, e, m) {
    j = run_end(s, i, n); m = j - i
    for (k = j; k <= n; k = e) {
      if (substr(s, k, 1) != "`") { e = k + 1; continue }
      e = run_end(s, k, n)
      if (e - k == m) return k
    }
    return 0
  }
  # bold_close(s, i, n): where the bold span opening at i closes on its
  # line, or 0 when it does not.
  function bold_close(s, i, n,   k, c, e) {
    for (k = i + 2; k <= n; ) {
      c = substr(s, k, 1)
      if (c == "\n") return 0
      if (c == "\\") { k += 2; continue }
      if (c == "`") {
        e = span_close(s, k, n)
        if (e) { k = e + (run_end(s, k, n) - k); continue }
        k = run_end(s, k, n); continue
      }
      if (substr(s, k, 2) == "**") return (k > i + 2 && index(substr(s, i, k - i), "\n") == 0) ? k : 0
      k++
    }
    return 0
  }
  function flush(   s, n, i, j, m, closer, span) {
    s = block; block = ""; n = length(s); i = 1
    split("", shut)
    while (i <= n) {
      if (substr(s, i, 1) == "\\") { i += 2; continue }
      if (substr(s, i, 2) == "**") {
        if (i in shut) { i += 2; continue }
        closer = bold_close(s, i, n)
        if (closer) { print "bold\t" substr(s, i + 2, closer - i - 2); shut[closer] = 1; i += 2; continue }
        i += 2; continue
      }
      if (substr(s, i, 1) != "`") { i++; continue }
      j = run_end(s, i, n); m = j - i
      closer = span_close(s, i, n)
      if (!closer) { i = j; continue }
      span = substr(s, j, closer - j)
      gsub(/\n/, " ", span)
      if (span ~ /^ .* $/ && span !~ /^ +$/) span = substr(span, 2, length(span) - 2)
      print "code\t" span
      i = closer + m
    }
  }
  function add(line) { block = (block == "" ? line : block "\n" line) }
  function indent(s,   i, c) {
    for (i = 1; i <= length(s); i++) {
      if (substr(s, i, 1) == " ") c++
      else if (substr(s, i, 1) == "\t") c += 4 - c % 4
      else break
    }
    return c + 0
  }
  function open_fence(s, at) { match(s, /^(`+|~+)/); fence = substr(s, 1, RLENGTH); fence_col = at }
  BEGIN {
    fence_re = "^(```|~~~)"
    heading_re = "^#(#?#?#?#?#?)([ \t]|$)"
    item_re = "^([-*+]|[0-9]+[.)])([ \t]|$)"
  }
  { ind = indent($0); rest = $0; sub(/^[ \t]+/, "", rest) }
  fence != "" {
    if (rest != "" && ind < fence_col) fence = ""
    else {
      if (ind - fence_col <= 3 && index(rest, fence) == 1 && rest ~ /^(`+|~+)[ \t]*$/) fence = ""
      next
    }
  }
  rest == "" { flush(); next }
  {
    opens = rest ~ fence_re || rest ~ heading_re || rest ~ item_re
    if (block == "" || opens) while (depth && ind < col[depth]) depth--
    base = depth ? col[depth] : 0
  }
  ind - base >= 4 && block == "" { next }
  ind - base <= 3 && rest ~ fence_re { flush(); open_fence(rest, base); next }
  ind - base <= 3 && rest ~ heading_re { flush(); add(rest); flush(); next }
  ind - base <= 3 && match(rest, item_re) {
    flush(); marker = RLENGTH - (RLENGTH > 1 && substr(rest, RLENGTH) ~ /[ \t]/)
    body = substr(rest, marker + 1); gap = indent(body); sub(/^[ \t]+/, "", body)
    col[++depth] = ind + marker + (body == "" || gap > 4 ? 1 : gap)
    if (body ~ fence_re) { open_fence(body, col[depth]); next }
    add(rest); next
  }
  { add(rest) }
  END { flush() }'

# code_spans <file>: each code span in Markdown <file>, one per line, read
# as SPANS_AWK reads them.
code_spans() {
  awk "$SPANS_AWK" "$1" | sed -n 's/^code\t//p'
}

# The jq definitions the transcript programs and the report share: num, a
# number to one decimal place (a whole number as is, any other rounded half
# up); text, a message content's text; total_input, a usage's input tokens,
# cached ones counted; ranged_read, whether a tool use is a Read passing
# offset or limit; and turns, applied to a slurped transcript: its first user
# prompt carrying no tool result, its turns, one per assistant message id,
# each with its context (total input), tool uses and the tool results that
# arrived since the previous turn, and every tool result'"'"'s text by tool-use
# id.
JQ_PRELUDE='
  def num: if . == floor then tostring else (. * 10 + 0.5 | floor) / 10 | tostring end;
  def text: if type == "string" then .
    elif type == "array" then map(if type == "object" then (.text // "") else tostring end) | join("")
    else "" end;
  def total_input: (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0);
  def ranged_read: .name == "Read" and (.input | has("offset") or has("limit"));
  def turns:
    reduce .[] as $m ({prompt: null, turns: [], at: {}, pending: [], results: {}};
      ($m.message // {}) as $msg
      | if $m.type == "assistant" and $msg.id != null then
          $msg.id as $id
          | (if .at | has($id) then .
             else .at[$id] = (.turns | length)
               | .turns += [{context: ($msg.usage // {} | total_input),
                   uses: [], results: .pending}]
               | .pending = [] end)
          | .at[$id] as $i
          | reduce (($msg.content // [])[]? | select(type == "object" and .type == "tool_use")) as $u
              (.; .turns[$i].uses += [$u])
        elif $m.type == "user" then
          (if .prompt == null and (($msg.content | type) == "string"
               or ([($msg.content // [])[]? | select(type == "object" and .type == "tool_result")] | length) == 0)
           then .prompt = ($msg.content | text) else . end)
          | if ($msg.content | type) == "array" then
              reduce ($msg.content[] | select(type == "object" and .type == "tool_result")) as $r
                (.; .pending += [{id: $r.tool_use_id, text: ($r.content | text)}]
                    | .results[$r.tool_use_id] = ($r.content | text))
            else . end
        else . end)
    | {prompt, turns, results};
'

# The per-run measures of one transcript, tab-separated: turns, total input,
# then the space-separated tool calls per turn, ranged Read line counts and
# Grep result characters, each - when empty.
TRANSCRIPT_JQ="$JQ_PRELUDE"'
  def listed: map(tostring) | join(" ") | if . == "" then "-" else . end;
  turns as $t
  | [ ($t.turns | length),
      ([$t.turns[].context] | add // 0),
      ([$t.turns[] | .uses | length] | listed),
      ([$t.turns[].uses[] | select(ranged_read)
        | ($t.results[.id] // "") | [splits("\n")]
        | map(select(test("^ *[0-9]+(\t|→)"))) | length] | listed),
      ([$t.turns[].uses[] | select(.name == "Grep") | ($t.results[.id] // "") | length] | listed)
    ] | @tsv'

# The diagnosis of one transcript, as one JSON object: per label, its turns
# and their input, and per kind, the carried cost. $names is the spec's names,
# $run the run's name. A turn's context is its total input; the results that
# came in since the previous turn are the ones read after its last line.
DIAGNOSIS_JQ="$JQ_PRELUDE"'
  def has_word_char: test("[A-Za-z0-9_]");
  def pathlike: test("^\\S+$") and (test("/") or test("\\.[A-Za-z0-9]+$"));
  def token_in($t): . as $n | ($n | length) as $l
    | any($t | indices($n)[]; . as $i
        | ($i == 0 or ($t[$i - 1:$i] | has_word_char | not))
          and ($i + $l == ($t | length) or ($t[$i + $l:$i + $l + 1] | has_word_char | not)));
  def family: if .name == "Read" then "read"
    elif .name == "Grep" or .name == "Glob" then "search" else .name end;
  def located: family as $f
    | if $f == "read" then .input.file_path as $path
      | ($path | type) == "string"
        and any($names[] | select(pathlike); . as $n | $path == $n or ($path | endswith("/" + $n)))
    elif $f == "search" then .input.pattern as $pattern
      | ($pattern | type) == "string"
        and any($names[] | select(length >= 3 and has_word_char); token_in($pattern))
    else false end;
  def tag: [.uses[] | located] as $l
    | if ($l | all) and ($l | length) > 0 then "named"
      elif ($l | any) then "mixed" else "unnamed" end;
  turns as $s
  | (reduce $s.turns[].uses[] as $u ({}; .[$u.id] = $u)) as $by_id
  | (($s.prompt // "") | split("\n") | map(select(. != "")) | .[0] // "" | gsub("^\\s+|\\s+$"; "")) as $spec
  | def kind: ($by_id[.id] // {name: "unknown", input: {}}) as $u
      | ($u | family) as $f
      | if $f == "read" then
          if $u.input.file_path == $spec then "the spec"
          elif ($u | ranged_read) then "ranged reads"
          else "whole reads" end
        elif $f == "search" then "Grep/Glob"
        else $u.name end;
    ($s.turns | length) as $n
  | {run: $run,
     turns: (reduce ($s.turns[] | tag) as $l ({named: 0, mixed: 0, unnamed: 0}; .[$l] += 1)),
     input: (reduce ($s.turns[] | [tag, .context]) as $t ({named: 0, mixed: 0, unnamed: 0}; .[$t[0]] += $t[1])),
     carried: (reduce range(1; $n) as $i
       ({"fixed base": (if $n > 0 then $s.turns[0].context * $n else 0 end), "the spec": 0,
         "ranged reads": 0, "whole reads": 0, "Grep/Glob": 0, "assistant output": 0};
        ($s.turns[$i].context - $s.turns[$i - 1].context) as $growth
        | ($n - $i) as $left
        | ($s.turns[$i].results | map({id, chars: (.text | length)})) as $rs
        | ([$rs[].chars] | add // 0) as $chars
        | if ($rs | length) == 0 then .["assistant output"] += $growth * $left
          else reduce $rs[] as $r (.;
            .[$r | kind] += $growth * $left
              * (if $chars > 0 then $r.chars / $chars else 1 / ($rs | length) end))
          end))}'

# The diagnosis tables of one directory, from its runs' diagnoses: each
# label's share of turns and of input, then the carried cost by kind, one row
# per run and one summed over them. Every other tool is a column by its name.
REPORT_JQ="$JQ_PRELUDE"'
  def cell($whole): "\(. + 0.5 | floor) (\(if $whole == 0 then 0 else . * 100 / $whole end | num)%)";
  def sum: reduce .[] as $o ({}; reduce ($o | to_entries[]) as $e (.; .[$e.key] += $e.value));
  ["fixed base", "the spec", "ranged reads", "whole reads", "Grep/Glob"] as $first
  | ([.[].carried | keys[]] | unique
     - $first - ["assistant output"]) as $tools
  | ($first + $tools + ["assistant output"]) as $kinds
  | (. + [{run: "All runs", turns: (map(.turns) | sum), input: (map(.input) | sum),
           carried: (map(.carried) | sum)}]) as $rows
  | "Diagnosis: each turn is named when all its tool calls target a name the spec gives (a backticked span), unnamed when none does or it makes none, and mixed otherwise.",
    "",
    "| Run | Named turns | Mixed turns | Unnamed turns | Named input | Mixed input | Unnamed input |",
    "|---|---|---|---|---|---|---|",
    ($rows[] | (.turns | add) as $t | (.input | add) as $i
      | "| \(.run) | \(.turns.named | cell($t)) | \(.turns.mixed | cell($t)) | \(.turns.unnamed | cell($t)) | \(.input.named | cell($i)) | \(.input.mixed | cell($i)) | \(.input.unnamed | cell($i)) |"),
    "",
    "Carried cost by kind: each tool result carries its share of the next turn'"'"'s growth over the turns left, and the fixed base is the first turn'"'"'s context over every turn.",
    "",
    "| Run | \($kinds | map((.[:1] | ascii_upcase) + .[1:]) | join(" | ")) |",
    "|\($kinds | map("---|") | join(""))---|",
    ($rows[] | .carried as $c | ([$c[]] | add) as $w
      | "| \(.run) | \([$kinds[] | ($c[.] // 0) | cell($w)] | join(" | ")) |")'

# summary_row <label> [<total>]: reads numbers, one per line, and prints
# their Markdown summary row: mean, median, minimum and maximum, each as
# <value>/<total> when a total is given. Prints nothing on no numbers.
summary_row() {
  jq -rs --arg label "$1" --arg total "${2:-}" "$JQ_PRELUDE"'
    if length == 0 then empty else
      sort as $v | ($v | length) as $n
      | [($v | add) / $n,
         (if $n % 2 == 1 then $v[($n - 1) / 2] else ($v[$n / 2 - 1] + $v[$n / 2]) / 2 end),
         $v[0], $v[-1]]
      | map(num + (if $total == "" then "" else "/" + $total end))
      | "| \($label) | \(join(" | ")) |"
    end'
}

cmd_measure() {
  [ "$#" -ge 1 ] || usage
  local arg
  for arg in "$@"; do
    case "$arg" in -*) usage ;; esac
  done
  local dirs=() dir file run first baseline total turns_all input_all cover_all
  local diagnoses names transcript measures turns input calls reads greps map
  local map_widths row cover runs
  for arg in "$@"; do
    dirs+=("$(no_trailing_slashes "$arg")")
  done

  # Every directory is checked before anything is printed.
  for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || fail "$dir: no such directory"
    for file in lens revision model spec.md; do
      [ -f "$dir/$file" ] || fail "$dir/$file: missing"
    done
    while IFS= read -r run; do
      [ -f "$dir/$run/transcript.jsonl" ] || fail "$dir/$run/transcript.jsonl: missing"
    done < <(runs_of "$dir")
  done

  first=1
  for dir in "${dirs[@]}"; do
    [ "$first" -eq 1 ] || echo
    first=0
    baseline=""
    [ -f "$dir/map.md" ] && baseline="$dir/map.md"
    printf '## %s\n\n' "$dir"
    printf 'Lens %s, revision %s, model %s\n\n' \
      "$(<"$dir/lens")" "$(<"$dir/revision")" "$(<"$dir/model")"
    if [ -n "$baseline" ]; then
      total="$(locations "$baseline" | awk 'END { print NR }')"
      printf 'Baseline map: %s locations\n\n' "$total"
      echo '| Run | Turns | Input | Calls per turn | Ranged Read lines | Grep chars | Map entry widths | Coverage |'
      echo '|---|---|---|---|---|---|---|---|'
    else
      echo 'Baseline map: none, so no coverage'
      echo
      echo '| Run | Turns | Input | Calls per turn | Ranged Read lines | Grep chars | Map entry widths |'
      echo '|---|---|---|---|---|---|---|'
    fi
    turns_all="" input_all="" cover_all="" diagnoses=""
    names="$(code_spans "$dir/spec.md" | jq -Rsc 'split("\n") | map(select(. != ""))')"
    while IFS= read -r run; do
      transcript="$dir/$run/transcript.jsonl"
      measures="$(jq -rs "$TRANSCRIPT_JQ" "$transcript")" ||
        fail "$transcript: not a transcript"
      IFS=$'\t' read -r turns input calls reads greps <<<"$measures"
      map="$dir/$run/map.md"
      if [ -f "$map" ]; then map_widths="$(widths "$map")"; else map_widths="-"; fi
      row="| $run | $turns | $input | $calls | $reads | $greps | $map_widths |"
      if [ -n "$baseline" ]; then
        if [ -f "$map" ]; then cover="$(covered "$baseline" "$map")"; else cover=0; fi
        row+=" $cover/$total |"
        cover_all+="$cover"$'\n'
      fi
      printf '%s\n' "$row"
      diagnoses+="$(jq -sc --argjson names "$names" --arg run "$run" "$DIAGNOSIS_JQ" "$transcript")"$'\n'
      turns_all+="$turns"$'\n'
      input_all+="$input"$'\n'
    done < <(runs_of "$dir")

    runs="$(printf '%s' "$turns_all" | awk 'END { print NR }')"
    [ "$runs" -gt 0 ] || continue
    printf '\nSummary over %s runs:\n\n' "$runs"
    echo '| Measure | Mean | Median | Min | Max |'
    echo '|---|---|---|---|---|'
    printf '%s' "$turns_all" | summary_row Turns
    printf '%s' "$input_all" | summary_row Input
    [ -z "$baseline" ] || printf '%s' "$cover_all" | summary_row Coverage "$total"
    echo
    printf '%s' "$diagnoses" | jq -rs "$REPORT_JQ"
  done
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  measure) shift; cmd_measure "$@" ;;
  *) usage ;;
esac
