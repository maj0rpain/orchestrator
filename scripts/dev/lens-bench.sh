#!/usr/bin/env bash
# lens-bench.sh measure <dir>...: the lens benchmark. Measures one or more
# benchmark output directories and prints a Markdown report on stdout.
#
# A directory holds `lens`, `revision` and `model`, one line each; `spec.md`,
# the fixture's spec body; `map.md`, the fixture's baseline map, when it has
# one; and one subdirectory per run, `run-1` to `run-N`, each holding
# `transcript.jsonl`, the lens agent's transcript, and `map.md`, the map the
# lens wrote, when it wrote one.
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
# span (backticked text) in `spec.md` is a name the spec gives; a tool call
# locates spec-named code when its Read path, Grep pattern or Glob pattern
# contains one. A turn is `named` when all its calls do, `mixed` when some do,
# and `unnamed` when none do or it makes no call; the report gives each
# label's share of turns and of input. Beside it, the carried cost by kind: a
# tool result's kind is `the spec` for the Read of the first path in the
# lens's prompt, a ranged read for any other Read passing offset or limit, a
# whole read for one passing neither, Grep/Glob for both, and any other tool
# by its name. A turn's growth over the previous turn's context is split among
# the results read since then by character count, or is assistant output
# when there are none, and is carried over the turns left from that turn on;
# the fixed base is the first turn's context times the number of turns.
#
# A repo-development tool: it does not ship to users. Usage errors exit 2; a
# missing directory, a directory missing its lens, revision or model file or
# its spec body, or a run with no transcript exits 1 naming it, before any
# report is printed.
set -euo pipefail

usage() {
  printf 'usage: %s measure <dir>...\n' "${0##*/}" >&2
  exit 2
}

[ "$#" -ge 2 ] && [ "$1" = measure ] || usage
shift
for arg in "$@"; do
  case "$arg" in -*) usage ;; esac
done

fail() {
  printf 'lens-bench.sh: %s\n' "$1" >&2
  exit 1
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

# covered <baseline> <map>: how many of <baseline>'s locations an entry of
# <map> covers: same path, overlapping range.
covered() {
  awk '
    FNR == NR { path[NR] = $1; from[NR] = $2; to[NR] = $3; n = NR; next }
    { for (i = 1; i <= n; i++)
        if ($1 == path[i] && $2 <= to[i] && from[i] <= $3) hit[i] = 1 }
    END { c = 0; for (i in hit) c++; print c }' \
    <(locations "$1") <(locations "$2")
}

# The per-run measures of one transcript, tab-separated: turns, total input,
# then the space-separated tool calls per turn, ranged Read line counts and
# Grep result characters, each - when empty.
TRANSCRIPT_JQ='
  def text: if type == "string" then .
    elif type == "array" then map(if type == "object" then (.text // "") else tostring end) | join("")
    else "" end;
  def listed: map(tostring) | join(" ") | if . == "" then "-" else . end;
  reduce .[] as $m ({ids: [], usage: {}, calls: {}, uses: [], results: {}};
    ($m.message // {}) as $msg
    | (if $m.type == "assistant" and $msg.id != null then
        $msg.id as $id
        | (if .usage | has($id) then .
           else .ids += [$id] | .usage[$id] = ($msg.usage // {}) | .calls[$id] = 0 end)
        | [($msg.content // [])[]? | select(type == "object" and .type == "tool_use")] as $u
        | .calls[$id] += ($u | length) | .uses += $u
      else . end)
    | if ($msg.content | type) == "array" then
        reduce ($msg.content[] | select(type == "object" and .type == "tool_result")) as $r
          (.; .results[$r.tool_use_id] = ($r.content | text))
      else . end)
  | . as $s
  | [ ($s.ids | length),
      ([$s.ids[] as $i | $s.usage[$i]
        | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)]
       | add // 0),
      ([$s.ids[] as $i | $s.calls[$i]] | listed),
      ([$s.uses[] | select(.name == "Read" and (.input | has("offset") or has("limit")))
        | ($s.results[.id] // "") | [splits("\n")]
        | map(select(test("^ *[0-9]+(\t|→)"))) | length] | listed),
      ([$s.uses[] | select(.name == "Grep") | ($s.results[.id] // "") | length] | listed)
    ] | @tsv'

# The diagnosis of one transcript, as one JSON object: per label, its turns
# and their input, and per kind, the carried cost. $names is the spec's names,
# $run the run's name. A turn's context is its total input; the results that
# came in since the previous turn are the ones read after its last line.
DIAGNOSIS_JQ='
  def text: if type == "string" then .
    elif type == "array" then map(if type == "object" then (.text // "") else tostring end) | join("")
    else "" end;
  def located: (if .name == "Read" then .input.file_path
      elif .name == "Grep" or .name == "Glob" then .input.pattern
      else null end) as $target
    | ($target | type) == "string" and any($names[]; . as $n | $target | contains($n));
  def tag: [.uses[] | located] as $l
    | if ($l | all) and ($l | length) > 0 then "named"
      elif ($l | any) then "mixed" else "unnamed" end;
  reduce .[] as $m ({prompt: null, turns: [], at: {}, uses: {}, pending: []};
    ($m.message // {}) as $msg
    | if $m.type == "assistant" and $msg.id != null then
        $msg.id as $id
        | (if .at | has($id) then .
           else .at[$id] = (.turns | length)
             | .turns += [{context: ($msg.usage // {}
                   | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)),
                 uses: [], results: .pending}]
             | .pending = [] end)
        | .at[$id] as $i
        | reduce (($msg.content // [])[]? | select(type == "object" and .type == "tool_use")) as $u
            (.; .turns[$i].uses += [$u] | .uses[$u.id] = $u)
      elif $m.type == "user" then
        (if .prompt == null and (($msg.content | type) == "string"
             or ([($msg.content // [])[]? | select(type == "object" and .type == "tool_result")] | length) == 0)
         then .prompt = ($msg.content | text) else . end)
        | if ($msg.content | type) == "array" then
            reduce ($msg.content[] | select(type == "object" and .type == "tool_result")) as $r
              (.; .pending += [{id: $r.tool_use_id, chars: ($r.content | text | length)}])
          else . end
      else . end)
  | . as $s
  | (($s.prompt // "") | split("\n") | map(select(. != "")) | .[0] // "" | gsub("^\\s+|\\s+$"; "")) as $spec
  | def kind: ($s.uses[.id] // {name: "unknown", input: {}}) as $u
      | if $u.name == "Read" then
          if $u.input.file_path == $spec then "the spec"
          elif ($u.input | has("offset") or has("limit")) then "ranged reads"
          else "whole reads" end
        elif $u.name == "Grep" or $u.name == "Glob" then "Grep/Glob"
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
        | $s.turns[$i].results as $rs
        | ([$rs[].chars] | add // 0) as $chars
        | if ($rs | length) == 0 then .["assistant output"] += $growth * $left
          else reduce $rs[] as $r (.;
            .[$r | kind] += $growth * $left
              * (if $chars > 0 then $r.chars / $chars else 1 / ($rs | length) end))
          end))}'

# The diagnosis tables of one directory, from its runs' diagnoses: each
# label's share of turns and of input, then the carried cost by kind, one row
# per run and one summed over them. Every other tool is a column by its name.
REPORT_JQ='
  def num: if . == floor then tostring else (. * 10 + 0.5 | floor) / 10 | tostring end;
  def cell($whole): "\(. + 0.5 | floor) (\(if $whole == 0 then 0 else . * 100 / $whole end | (. * 10 + 0.5 | floor) / 10 | num)%)";
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

# stats: the mean, median, minimum and maximum of the numbers on stdin, one
# per line, tab-separated; a whole number prints as one, any other to one
# decimal place.
stats() {
  sort -n | awk '
    function num(x) { return (x == int(x)) ? sprintf("%d", x) : sprintf("%.1f", x) }
    { v[NR] = $1; sum += $1 }
    END {
      if (NR == 0) exit
      median = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
      printf "%s\t%s\t%s\t%s\n", num(sum / NR), num(median), num(v[1]), num(v[NR])
    }'
}

# Every directory is checked before anything is printed.
for dir in "$@"; do
  [ -d "$dir" ] || fail "$dir: no such directory"
  for file in lens revision model spec.md; do
    [ -f "$dir/$file" ] || fail "$dir/$file: missing"
  done
  while IFS= read -r run; do
    [ -f "$dir/$run/transcript.jsonl" ] || fail "$dir/$run/transcript.jsonl: missing"
  done < <(runs_of "$dir")
done

first=1
for dir in "$@"; do
  dir="${dir%/}"
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
  names="$(grep -o '`[^`]*`' "$dir/spec.md" | tr -d '`' | jq -Rsc 'split("\n") | map(select(. != ""))')"
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
  printf '%s' "$turns_all" | stats | awk -F'\t' '{ printf "| Turns | %s | %s | %s | %s |\n", $1, $2, $3, $4 }'
  printf '%s' "$input_all" | stats | awk -F'\t' '{ printf "| Input | %s | %s | %s | %s |\n", $1, $2, $3, $4 }'
  if [ -n "$baseline" ]; then
    printf '%s' "$cover_all" | stats | awk -F'\t' -v t="$total" \
      '{ printf "| Coverage | %s/%s | %s/%s | %s/%s | %s/%s |\n", $1, t, $2, t, $3, t, $4, t }'
  fi
  echo
  printf '%s' "$diagnoses" | jq -rs "$REPORT_JQ"
done
