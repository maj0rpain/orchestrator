# shellcheck shell=bash
# marked-comment.sh - the Marked comment module: a concept module with no
# orch.sh noun of its own, owning the writing and reading of marked comments -
# issue comments whose first line names their kind. It holds the kind
# registry, the marker grammar (prefix, argument, ` -->`, the `retired` tag,
# the visible openings, the legacy stop form) and CR handling. Callers name a
# kind and never write a marker or recognise a comment by one. Its tests:
# scripts/test/orch/marked-comment.sh.
# Sourced by orch.sh, after common.sh and the ROOT block. Sourced after
# autopilot.sh, handoff.sh and issue.sh, so they expand marked_comment_jq at
# call time, inside a function, never into a constant.
#
# The kinds: question, limited (a limit stop), handoff (argument: its name,
# optionally tagged retired), refusal and failure (arguments: a phase; a stop
# comment posted before the hidden marker existed is read by its prose
# opening), spec-review (the first line `## Spec review`) and spec-ruling (a
# first line beginning `Spec ruling:`).
#
# The readers: marked_comment_newest, _retired, _follows, _body, _texts (the
# opening-stripped texts of a kind) and _drop, over the prelude's
# marked_comment_list, _info, _entries and _of.
#
# Every reader takes the comments JSON on stdin: the issue object from the
# structured issue read, or the bare comment array.

# The legacy openings of a refusal and a failure stop comment, frozen: they
# only recognise comments posted before those kinds had a marker.
MARKED_COMMENT_LEGACY_REFUSAL='Autopilot refused to run the '
MARKED_COMMENT_LEGACY_FAILURE='Autopilot failed in the '

# The kind registry, written once: the hidden-marker kinds (space-separated,
# as their marker text), the one kind that can be retired, and the two visible
# openings. The writer's checks and the jq prelude's recognition are built
# from these.
MARKED_COMMENT_KINDS='question limited handoff refusal failure'
MARKED_COMMENT_RETIRABLE='handoff'
MARKED_COMMENT_SPEC_REVIEW_OPENING='## Spec review'
MARKED_COMMENT_SPEC_RULING_OPENING='Spec ruling:'

# marked_comment_jq: prints the jq definitions every reader shares. Expand it
# at call time. marked_comment_list is the comment array of the input, in
# either shape; marked_comment_info is, for a comment, {kind, arg, retired}
# (kind and arg null for an unmarked comment, retired a boolean);
# marked_comment_entries is, for the input, {key, c, info} of each comment: its
# index, the comment and its marked_comment_info; marked_comment_of($k; $a) is
# the entries of kind $k (and of arg $a, unless it is empty).
marked_comment_jq() {
  local kinds="${MARKED_COMMENT_KINDS// /|}"
  cat <<EOJQ
def marked_comment_list: if type == "object" then .comments else . end;
def marked_comment_info:
  ((.body // "") | split("\n")[0] // "" | rtrimstr("\r")) as \$l
  | ([\$l | capture("^<!-- orch:(?<kind>$kinds) (?<arg>[^ ]+)(?<retired> retired)? -->\$")?] | .[0]) as \$m
  | ([\$l | capture("^$MARKED_COMMENT_LEGACY_REFUSAL(?<p>[^ ]+) phase")?] | .[0]) as \$lr
  | ([\$l | capture("^$MARKED_COMMENT_LEGACY_FAILURE(?<p>[^ ]+) phase")?] | .[0]) as \$lf
  | if \$m != null and ((\$m.retired // "") == "" or \$m.kind == "$MARKED_COMMENT_RETIRABLE") then
      {kind: \$m.kind, arg: \$m.arg, retired: ((\$m.retired // "") != "")}
    elif (\$l | test("^${MARKED_COMMENT_SPEC_REVIEW_OPENING}[ \t]*\$")) then {kind: "spec-review", arg: null, retired: false}
    elif (\$l | startswith("$MARKED_COMMENT_SPEC_RULING_OPENING")) then {kind: "spec-ruling", arg: null, retired: false}
    elif \$lr != null then
      {kind: "refusal", arg: \$lr.p, retired: false}
    elif \$lf != null then
      {kind: "failure", arg: \$lf.p, retired: false}
    else {kind: null, arg: null, retired: false} end;
def marked_comment_entries:
  marked_comment_list | to_entries | map({key, c: .value, info: (.value | marked_comment_info)});
def marked_comment_of(\$k; \$a):
  marked_comment_entries | map(select(.info | .kind == \$k and (\$a == "" or .arg == \$a)));
EOJQ
}

# marked_comment_write <kind> [<arg>] [retired]: prints the first line of a
# <kind> comment, newline-terminated. Dies, printing nothing, on an unknown
# kind, a missing (or blank, or spaced) argument for a kind that takes one, an
# argument to spec-review or spec-ruling, or retired on any kind but handoff.
marked_comment_write() {
  local kind="${1:-}" arg="${2-}" tag="${3-}"
  case "$kind" in
    spec-review | spec-ruling)
      [ $# -le 1 ] || die "marked comment: $kind takes no argument"
      case "$kind" in
        spec-review) printf '%s\n' "$MARKED_COMMENT_SPEC_REVIEW_OPENING" ;;
        *) printf '%s\n' "$MARKED_COMMENT_SPEC_RULING_OPENING" ;;
      esac
      return ;;
    *) case " $MARKED_COMMENT_KINDS " in
         *" $kind "*) ;;
         *) die "marked comment: unknown kind: $kind" ;;
       esac ;;
  esac
  case "$arg" in
    '' | *[[:space:]]*) die "marked comment: $kind needs an argument without whitespace" ;;
  esac
  case "$tag" in
    '') printf '<!-- orch:%s %s -->\n' "$kind" "$arg" ;;
    retired)
      [ "$kind" = "$MARKED_COMMENT_RETIRABLE" ] || die "marked comment: only a handoff can be retired"
      printf '<!-- orch:%s %s retired -->\n' "$kind" "$arg" ;;
    *) die "marked comment: unknown tag: $tag" ;;
  esac
}

# marked_comment_newest <kind> [<arg>]: the index of the newest comment of
# <kind> (and of <arg>, when given) in the comments on stdin. Exits 1,
# printing nothing, when none is, and 2 when the comments cannot be read.
marked_comment_newest() {
  local out
  out="$(jq -r --arg k "$1" --arg a "${2-}" "$(marked_comment_jq)"'
    marked_comment_of($k; $a) | last | .key // empty')" || return 2
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# marked_comment_at <jq-flags> <program> <kind> [<arg>]: reads the comments on
# stdin and runs the jq <program>, under <jq-flags>, with $i bound to the index
# marked_comment_newest finds for <kind> [<arg>]; the one place the readers'
# exit status is settled. Passes marked_comment_newest's 1 and 2 through, else
# jq's own status.
marked_comment_at() {
  local flags="$1" program="$2" json i
  shift 2
  json="$(cat)"
  i="$(marked_comment_newest "$@" <<<"$json")" || return $?
  jq "$flags" --argjson i "$i" "$(marked_comment_jq)$program" <<<"$json"
}

# marked_comment_retired <kind> [<arg>]: succeeds when the newest comment of
# <kind> is tagged retired; prints nothing. Fails with 1 when it is not, or none
# is, and with 2 when the comments cannot be read.
marked_comment_retired() {
  marked_comment_at -e '
    marked_comment_list[$i] | marked_comment_info | .retired' "$@" >/dev/null
}

# marked_comment_follows <kind> [<arg>]: succeeds when some comment follows
# the newest comment of <kind>; prints nothing. Fails with 1 when none does, or
# none is of that kind, and with 2 when the comments cannot be read.
marked_comment_follows() {
  marked_comment_at -e '
    marked_comment_list | length > $i + 1' "$@" >/dev/null
}

# marked_comment_body <kind> [<arg>]: the body of the newest comment of <kind>
# with its first line stripped, printed exactly, trailing newlines kept. Exits
# 1, printing nothing, when none is of that kind, and 2 when the comments cannot
# be read.
marked_comment_body() {
  marked_comment_at -j '
    marked_comment_list[$i].body | (index("\n") // empty) as $n | .[$n + 1:]' "$@"
}

# marked_comment_texts <kind> [<arg>]: a JSON array of, for every comment of
# <kind> (and of <arg>, when given) on stdin in order, its body with its opening
# removed - the whole first line, newline included, for every kind but
# spec-ruling, whose `Spec ruling:` prefix alone goes - and every CR removed.
# A comment of only its opening gives "". Prints [] when none is of that kind,
# and exits 2, printing nothing, when the comments cannot be read.
marked_comment_texts() {
  local out
  out="$(jq -c --arg k "$1" --arg a "${2-}" --arg ruling "$MARKED_COMMENT_SPEC_RULING_OPENING" "$(marked_comment_jq)"'
    marked_comment_of($k; $a)
    | map((.c.body // "") as $b
      | (if $k == "spec-ruling" then $b | ltrimstr($ruling)
         else ($b | index("\n")) as $n | if $n == null then "" else $b[$n + 1:] end end)
      | gsub("\r"; ""))')" || return 2
  printf '%s\n' "$out"
}

# marked_comment_drop <kind>: the comments on stdin, in the input's shape, with
# every comment of <kind> dropped; each kept comment unchanged. Exits non-zero,
# printing nothing, when the comments cannot be read.
marked_comment_drop() {
  jq -c --arg k "$1" "$(marked_comment_jq)"'
    def run: map(select((marked_comment_info).kind != $k));
    if type == "object" then .comments |= run else run end'
}
