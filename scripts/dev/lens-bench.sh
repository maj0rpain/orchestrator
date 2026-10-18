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
  turns_all="" input_all="" cover_all=""
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
done
