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

# Round trip: each kind's writer line, read back by every reader.
for spec in "question plan" "limited implement" "handoff 01-plan" "refusal review" "failure implement" \
  "spec-review" "spec-ruling"; do
  # shellcheck disable=SC2086 # the words are the kind and its argument
  line="$(marker_of $spec)"
  kind="${spec%% *}"; arg=""; [ "$kind" = "$spec" ] || arg="${spec#* }"
  arr="$(mc_array "first" "$line"$'\nthe text\n' "last")"
  mc newest "$arr" "$kind" $arg
  assert_eq "$kind: the newest comment is found by kind${arg:+ and argument} (writer round trip)" "$mc_out/$mc_rc" "1/0"
  mc body "$arr" "$kind" $arg
  assert_eq "$kind: the stripped body is the text, trailing newline kept" "$mc_out" "the text"
  mc newest "$(mc_object "$line"$'\n')" "$kind" $arg
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

# Exact bodies: trailing newlines are kept; a body with no second line is empty.
q="$(marker_of question plan)"
mc body "$(mc_array "$q"$'\nline\n\n\n')" question
assert_eq "the stripped body keeps its trailing newlines" "$mc_out" "line"$'\n\n'
mc_exact="$(sourced_orch marked_comment_body question <<<"$(mc_array "$q"$'\nline\n\n\n')"; echo x)"
assert_eq "the stripped body is printed byte for byte" "$mc_exact" "line"$'\n\n\n'"x"
mc body "$(mc_array "$q")" question
assert_eq "a marker-only comment has an empty body, exit 0" "$mc_rc:$mc_out" "0:"

# CR line endings.
mc newest "$(mc_array "$q"$'\r\ntext')" question plan
assert_eq "a marker line ending in CR is still a question comment" "$mc_out/$mc_rc" "0/0"
mc body "$(mc_array "$q"$'\r\ntext\r\n')" question
assert_eq "the stripped body of a CR comment drops the marker line and its CR" "$mc_out" $'text\r'

# A retired handoff.
live="$(marker_of handoff 01-plan)"; ret="$(marker_of handoff 01-plan retired)"
arr="$(mc_array "$live" "$ret")"
mc newest "$arr" handoff 01-plan
assert_eq "a retired handoff is the newest handoff of its name" "$mc_out/$mc_rc" "1/0"
mc retired "$arr" handoff 01-plan
assert_eq "the retired predicate says yes for a retired newest" "$mc_rc:$mc_out" "0:"
mc retired "$(mc_array "$ret" "$live")" handoff 01-plan
assert_eq "the retired predicate says no for a live newest" "$mc_rc:$mc_out" "1:"
mc retired "$(mc_array "x")" handoff 01-plan
assert_eq "the retired predicate says no when no comment is of the kind" "$mc_rc:$mc_out" "1:"
mc retired "$(mc_array "$(marker_of question plan retired 2>/dev/null)")" question
assert_eq "retired is read on handoff only" "$mc_rc" "1"
mc newest "$(mc_array "<!-- orch:question plan retired -->")" question
assert_eq "a retired tag on a question marker makes it unmarked" "$mc_rc:$mc_out" "1:"

# The follows predicate.
mc follows "$(mc_array "$q" "later")" question
assert_eq "follows says yes when a comment follows the newest" "$mc_rc:$mc_out" "0:"
mc follows "$(mc_array "later" "$q")" question
assert_eq "follows says no when the newest is last" "$mc_rc:$mc_out" "1:"
mc follows "$(mc_array "later")" question
assert_eq "follows says no when no comment is of the kind" "$mc_rc:$mc_out" "1:"

# Near-misses and mismatches.
mc newest "$(mc_array "<!-- orch:question plan")" question
assert_eq "a marker without its closing is no question comment" "$mc_rc:$mc_out" "1:"
mc newest "$(mc_array "<!-- orch:handoff 01-plan")" handoff
assert_eq "a handoff prefix without its closing is no handoff" "$mc_rc:$mc_out" "1:"
mc newest "$(mc_array $'intro\n'"$q")" question
assert_eq "a marker on the second line is no marker" "$mc_rc:$mc_out" "1:"
mc newest "$(mc_array "$q")" question implement
assert_eq "an argument mismatch finds no comment" "$mc_rc:$mc_out" "1:"
mc newest "$(mc_array "$q")" limited
assert_eq "a kind mismatch finds no comment" "$mc_rc:$mc_out" "1:"
mc newest "$(mc_array "$q" "$(marker_of question implement)")" question
assert_eq "with no argument the newest question of any phase is found" "$mc_rc:$mc_out" "0:1"
mc newest "$(mc_array "$q" "$(marker_of question implement)")" question plan
assert_eq "with an argument the newest question of that phase is found" "$mc_rc:$mc_out" "0:0"
mc body "$(mc_array "other")" question
assert_eq "the body of no comment exits 1, printing nothing" "$mc_rc:$mc_out" "1:"
for fn in newest retired follows body; do
  mc "$fn" '[]' question
  assert_eq "$fn on an empty array exits 1, printing nothing" "$mc_rc:$mc_out" "1:"
done
mc newest '{"comments": []}' question
assert_eq "newest on an issue with no comments exits 1, printing nothing" "$mc_rc:$mc_out" "1:"

# The legacy stop forms.
mc newest "$(mc_array "Autopilot refused to run the review phase: no pr")" refusal review
assert_eq "a legacy refusal opening is a refusal of its phase" "$mc_rc:$mc_out" "0:0"
mc newest "$(mc_array "Autopilot failed in the implement phase: boom")" failure implement
assert_eq "a legacy failure opening is a failure of its phase" "$mc_rc:$mc_out" "0:0"
mc newest "$(mc_array "Autopilot failed in the implement phase: boom")" refusal
assert_eq "a legacy failure is no refusal" "$mc_rc:$mc_out" "1:"

# Spec review.
mc newest "$(mc_array $'## Spec review \t\nRound 1 of 2')" spec-review
assert_eq "spec-review allows trailing spaces and tabs" "$mc_rc:$mc_out" "0:0"
mc newest "$(mc_array $'## Spec review of x\nRound 1')" spec-review
assert_eq "spec-review is exactly the heading" "$mc_rc:$mc_out" "1:"
arr="$(mc_array "keep" $'## Spec review\nRound 1 of 2' "also")"
mc drop "$arr" spec-review
assert_eq "drop leaves the other comments unchanged, in the array shape" "$mc_out" '[{"body":"keep"},{"body":"also"}]'
mc texts "$arr" spec-review
assert_eq "texts drops the spec-review heading line" "$mc_out" '["Round 1 of 2"]'
mc drop "$(mc_object "keep" $'## Spec review\nx')" spec-review
assert_eq "drop on the issue object keeps its shape" "$mc_out" '{"number":1,"comments":[{"body":"keep"}]}'

mc newest "not json" question plan
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
# Every kind the registry holds is written and read back.
for kind in $(sourced_orch_script 'printf "%s " $MARKED_COMMENT_KINDS'); do
  mc texts "$(mc_array "$(marker_of "$kind" plan)"$'\nthe text')" "$kind" plan
  assert_eq "registry kind $kind: the writer's line is recognised and stripped" "$mc_out" '["the text"]'
done
mc newest "$(mc_array $'\nSpec ruling: a')" spec-ruling
assert_eq "a spec ruling whose first line is blank is rejected" "$mc_rc:$mc_out" "1:"

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
