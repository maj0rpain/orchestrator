# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- marked-comment module --------------------------------------------------
# The Marked comment module's functions, called through a sourced orch.sh. The
# format edge cases (CR, retired handoffs, near-misses, the legacy stop form,
# both input shapes) are tested here and nowhere else.

echo
echo "marked-comment module"
new_repo >/dev/null

# mc_array <body>...: the bare comments array of the bodies, oldest first.
mc_array() { jq -cn '$ARGS.positional | map({body: .})' --args "$@"; }
# mc_object <body>...: the issue object holding the same comments.
mc_object() { jq -cn '{number: 1, comments: ($ARGS.positional | map({body: .}))}' --args "$@"; }
# mc_jq <program>: runs the jq <program> over the module's prelude, on stdin.
# shellcheck disable=SC2016 # the program is single-quoted, and the module expands in the child
mc_jq() { sourced_orch_script 'jq -c "$(marked_comment_jq)"'"' $1'"; }
# mc <function> <comments-json> [<arg>...]: sets mc_out and mc_rc from running
# the module's <function> on the JSON.
mc() {
  local fn="$1" json="$2"; shift 2
  mc_out="$(sourced_orch "marked_comment_$fn" "$@" <<<"$json"; echo "rc=$?")"
  mc_rc="${mc_out##*rc=}"; mc_out="${mc_out%rc=*}"
  mc_out="${mc_out%$'\n'}"
}

# mc_newest <comments-json> <kind> [<arg>]: sets mc_out and mc_rc as mc does,
# from the index of the newest comment of <kind> (and <arg>) that the prelude's
# marked_comment_of finds: rc 1 and no output when none is, 2 when jq fails on
# the comments (they cannot be read).
mc_newest() {
  mc_out="$(sourced_orch_script 'jq -r --arg k "$1" --arg a "$2" "$(marked_comment_jq)"'"' marked_comment_of(\$k; \$a) | last | .key // empty'" "$2" "${3-}" <<<"$1" 2>/dev/null; echo "rc=$?")"
  mc_rc="${mc_out##*rc=}"; mc_out="${mc_out%rc=*}"
  mc_out="${mc_out%$'\n'}"
  if [ "$mc_rc" -ne 0 ]; then mc_rc=2; elif [ -z "$mc_out" ]; then mc_rc=1; fi
}
# Round trip: each kind's writer line, read back by the prelude and texts -
# every hidden-marker kind the registry holds, so a newly added one is covered
# too.
hidden_kinds="$(sourced_orch_script 'printf "%s " $MARKED_COMMENT_KINDS')"
# shellcheck disable=SC2086 # the kinds are space-separated words
for entry in $(printf '%s:plan ' $hidden_kinds) "spec-review" "spec-ruling"; do
  spec="${entry/:/ }"
  # shellcheck disable=SC2086 # the words are the kind and its argument
  line="$(marker_of $spec)"
  kind="${spec%% *}"; arg=""; [ "$kind" = "$spec" ] || arg="${spec#* }"
  arr="$(mc_array "first" "$line"$'\nthe text\n' "last")"
  mc_newest "$arr" "$kind" $arg
  assert_eq "$kind: the newest comment is found by kind${arg:+ and argument} (writer round trip)" "$mc_out/$mc_rc" "1/0"
  mc texts "$arr" "$kind" $arg
  assert_eq "$kind: the opening-stripped text is the text, trailing newline kept" "$mc_out" \
    "$([ "$kind" = spec-ruling ] && echo '["\nthe text\n"]' || echo '["the text\n"]')"
  mc_newest "$(mc_object "$line"$'\n')" "$kind" $arg
  assert_eq "$kind: the issue object is read as the bare array is" "$mc_out/$mc_rc" "0/0"
done
assert_eq "the writer prints the question marker" "$(marker_of question plan)" "<!-- orch:question plan -->"
assert_eq "the writer prints the retired handoff marker" "$(marker_of handoff 01-plan retired)" "<!-- orch:handoff 01-plan retired -->"
assert_eq "the writer prints the refusal marker" "$(marker_of refusal plan)" "<!-- orch:refusal plan -->"
assert_eq "the writer prints the spec review heading" "$(marker_of spec-review)" "## Spec review"
assert_eq "the writer prints the Spec ruling opening alone" "$(marker_of spec-ruling)" "Spec ruling:"

# The writer's refusals print nothing and fail.
for bad_args in "bogus x" "question" "question ''" "spec-review x" "spec-ruling x" "question plan retired" \
  "handoff a b"; do
  out="$(eval "sourced_orch marked_comment_write $bad_args" 2>/dev/null)"; rc=$?
  assert_eq "the writer refuses '$bad_args', printing nothing" "$rc:$out" "1:"
done

# Exact texts: trailing newlines are kept; a body with no second line is empty.
q="$(marker_of question plan)"
mc texts "$(mc_array "$q"$'\nline\n\n\n')" question
assert_eq "the opening-stripped text keeps its trailing newlines" "$mc_out" '["line\n\n\n"]'
mc texts "$(mc_array "$q")" question
assert_eq "a marker-only comment has an empty text" "$mc_rc:$mc_out" '0:[""]'

# CR line endings.
mc_newest "$(mc_array "$q"$'\r\ntext')" question plan
assert_eq "a marker line ending in CR is still a question comment" "$mc_out/$mc_rc" "0/0"
mc texts "$(mc_array "$q"$'\r\ntext\r\n')" question
assert_eq "the text of a CR comment drops the marker line and every CR" "$mc_out" '["text\n"]'

# A retired handoff.
live="$(marker_of handoff 01-plan)"; ret="$(marker_of handoff 01-plan retired)"
arr="$(mc_array "$live" "$ret")"
mc_newest "$arr" handoff 01-plan
assert_eq "a retired handoff is the newest handoff of its name" "$mc_out/$mc_rc" "1/0"
got="$(mc_jq 'marked_comment_of("handoff"; "01-plan") | map(.info.retired)' <<<"$arr")"
assert_eq "the prelude marks the retired handoff retired and the live one not" "$got" '[false,true]'

# Near-misses and mismatches.
mc_newest "$(mc_array "<!-- orch:question plan")" question
assert_eq "a marker without its closing is no question comment" "$mc_rc:$mc_out" "1:"
mc_newest "$(mc_array "<!-- orch:handoff 01-plan")" handoff
assert_eq "a handoff prefix without its closing is no handoff" "$mc_rc:$mc_out" "1:"
mc_newest "$(mc_array "$q")" question implement
assert_eq "an argument mismatch finds no comment" "$mc_rc:$mc_out" "1:"
mc_newest "$(mc_array "$q")" limited
assert_eq "a kind mismatch finds no comment" "$mc_rc:$mc_out" "1:"
mc_newest "$(mc_array "$q" "$(marker_of question implement)")" question
assert_eq "with no argument the newest question of any phase is found" "$mc_rc:$mc_out" "0:1"
mc_newest "$(mc_array "$q" "$(marker_of question implement)")" question plan
assert_eq "with an argument the newest question of that phase is found" "$mc_rc:$mc_out" "0:0"
mc_newest '[]' question
assert_eq "an empty array has no question comment" "$mc_rc:$mc_out" "1:"
mc_newest '{"comments": []}' question
assert_eq "an issue object with no comments has no question comment" "$mc_rc:$mc_out" "1:"

# The legacy stop forms.
mc_newest "$(mc_array "Autopilot refused to run the review phase: no pr")" refusal review
assert_eq "a legacy refusal opening is a refusal of its phase" "$mc_rc:$mc_out" "0:0"
mc_newest "$(mc_array "Autopilot failed in the implement phase: boom")" failure implement
assert_eq "a legacy failure opening is a failure of its phase" "$mc_rc:$mc_out" "0:0"
mc_newest "$(mc_array "Autopilot failed in the implement phase: boom")" refusal
assert_eq "a legacy failure is no refusal" "$mc_rc:$mc_out" "1:"

# Spec review.
mc_newest "$(mc_array $'## Spec review \t\nRound 1 of 2')" spec-review
assert_eq "spec-review allows trailing spaces and tabs" "$mc_rc:$mc_out" "0:0"
mc_newest "$(mc_array $'## Spec review of x\nRound 1')" spec-review
assert_eq "spec-review is exactly the heading" "$mc_rc:$mc_out" "1:"
arr="$(mc_array "keep" $'## Spec review\nRound 1 of 2' "also")"
mc drop "$arr" spec-review
assert_eq "drop leaves the other comments unchanged, in the array shape" "$mc_out" '[{"body":"keep"},{"body":"also"}]'
mc texts "$arr" spec-review
assert_eq "texts drops the spec-review heading line" "$mc_out" '["Round 1 of 2"]'
mc drop "$(mc_object "keep" $'## Spec review\nx')" spec-review
assert_eq "drop on the issue object keeps its shape" "$mc_out" '{"number":1,"comments":[{"body":"keep"}]}'

mc_newest "not json" question plan
assert_eq "unreadable comments are exit 2, not none" "$mc_rc:$mc_out" "2:"

# Spec ruling.
mc texts "$(mc_array $'Spec ruling: a\r\n- b\r\n' "x")" spec-ruling
assert_eq "a spec ruling with CR line endings loses its prefix and its CRs" "$mc_out" '[" a\n- b\n"]'
mc texts "$(mc_object $'Spec ruling: q - a' $'Spec ruling:\nlater' "x")" spec-ruling
assert_eq "texts keeps a same-line ruling and a ruling on following lines, on the object shape" "$mc_out" '[" q - a","\nlater"]'
mc texts "$(mc_array "$q"$'\r\nbody\r\n' "$q" "$(marker_of question build)"$'\nother')" question plan
assert_eq "texts drops the marker line, strips CRs, and honours the argument" "$mc_out" '["body\n",""]'
mc texts "$(mc_array "x" "$q")" spec-review
assert_eq "texts prints an empty array when no comment is of the kind" "$mc_rc:$mc_out" "0:[]"
mc texts "$(mc_array "Spec ruling:")" spec-ruling
assert_eq "a ruling that is only its opening gives an empty string" "$mc_out" '[""]'
mc texts "not json" spec-ruling
assert_eq "texts on unreadable comments exits 2, printing nothing" "$mc_rc:$mc_out" "2:"
mc drop "not json" spec-review
assert_eq "drop on unreadable comments fails, printing nothing" "$([ "$mc_rc" != 0 ] && echo failed):$mc_out" "failed:"

# The exported prelude, through jq: each comment's {kind, arg, retired}.
arr="$(mc_array "$q" "$ret" "$(marker_of limited build)"$'\r\n' "Autopilot refused to run the plan phase: x" \
  "$(marker_of failure plan)" $'## Spec review\t' "Spec ruling: z" "plain" "<!-- orch:handoff x" \
  "Autopilot failed in the implement phase: boom" "$live" "$q"$'\r\ntext')"
got="$(mc_jq 'marked_comment_list | map(marked_comment_info)' <<<"$arr")"
assert_eq "the prelude gives every comment its kind, arg and retired" "$got" \
  '[{"kind":"question","arg":"plan","retired":false},{"kind":"handoff","arg":"01-plan","retired":true},{"kind":"limited","arg":"build","retired":false},{"kind":"refusal","arg":"plan","retired":false},{"kind":"failure","arg":"plan","retired":false},{"kind":"spec-review","arg":null,"retired":false},{"kind":"spec-ruling","arg":null,"retired":false},{"kind":null,"arg":null,"retired":false},{"kind":null,"arg":null,"retired":false},{"kind":"failure","arg":"implement","retired":false},{"kind":"handoff","arg":"01-plan","retired":false},{"kind":"question","arg":"plan","retired":false}]'
# The same prelude over the edge cases: a marker on the second line, a retired
# tag on a non-handoff marker, a marker with an extra argument, a CRLF spec
# ruling, a spec ruling whose first line is blank, a question marker without
# its argument.
arr="$(mc_array $'intro\n<!-- orch:question plan -->' "<!-- orch:question plan retired -->" "<!-- orch:question plan extra -->" \
  $'Spec ruling: a\r\n- b\r\n' $'\nSpec ruling: a' "<!-- orch:question -->")"
got="$(mc_jq 'marked_comment_list | map(marked_comment_info)' <<<"$arr")"
assert_eq "the prelude reads the edge cases as unmarked, but for the CRLF spec ruling" "$got" \
  '[{"kind":null,"arg":null,"retired":false},{"kind":null,"arg":null,"retired":false},{"kind":null,"arg":null,"retired":false},{"kind":"spec-ruling","arg":null,"retired":false},{"kind":null,"arg":null,"retired":false},{"kind":null,"arg":null,"retired":false}]'
got="$(mc_jq 'marked_comment_list | map(marked_comment_info)' <<<"[]")"
assert_eq "the prelude reads an empty array as no comments" "$got" "[]"
got="$(mc_jq 'marked_comment_list | length' <<<"$(mc_object a b)")"
assert_eq "the prelude reads the issue object's comments" "$got" "2"
