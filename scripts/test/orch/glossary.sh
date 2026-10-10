# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# glossary_fixture: write the fixture GLOSSARY.md at the current repo's root.
# Flow ends at the next term line and holds an inner blank line; Round ends at
# a section heading and has a scoped alias; Side checkout ends at a heading
# followed by prose; Budget ends at end of file, after trailing blank lines.
glossary_fixture() {
  writeln '# Fixture' '' 'Intro prose, never an entry.' '' '## Language' '' \
          '### Flow and phases' '' \
          '**Flow**:' 'One run of the pipeline.' '' 'A second paragraph about it.' \
          '_Avoid_: pipeline run, workflow.' '' \
          '**Round**:' 'One review of the spec.' \
          '_Avoid_: pass, iteration (the review loop'"'"'s).' '' \
          '### Checkouts' '' 'Section prose, never printed.' '' \
          '**Side checkout**:' 'A worktree beside the main one.' \
          '_Avoid_: sibling worktree, second checkout (as the general term, or any).' '' \
          '## More' '' \
          '**Budget**:' 'How many iterations a loop may run.' '' '' >GLOSSARY.md
}

# --- glossary terms -----------------------------------------------------------
# Every term name, one per line, in glossary order, read from the root
# GLOSSARY.md only; no glossary is no terms, and no error.
echo
echo "glossary terms"
new_repo >/dev/null
out="$("$ORCH" glossary terms 2>&1)"; st=$?
assert_status "terms with no GLOSSARY.md succeeds" "$st" 0
assert_eq "and prints nothing" "$out" ""
glossary_fixture
out="$("$ORCH" glossary terms 2>&1)"; st=$?
assert_status "terms succeeds" "$st" 0
assert_eq "listing every term name in glossary order" "$out" \
  "$(writeln Flow Round 'Side checkout' Budget)"
mkdir sub && cd sub || exit 1
assert_eq "read from the root GLOSSARY.md wherever it runs" \
  "$("$ORCH" glossary terms 2>&1)" "$(writeln Flow Round 'Side checkout' Budget)"
cd .. || exit 1
out="$("$ORCH" glossary terms extra 2>&1)"; st=$?
assert_status "terms refuses an argument" "$st" 2
assert_contains "with its usage line" "$out" "usage: orch.sh glossary terms"
out="$("$ORCH" glossary bogus 2>&1)"; st=$?
assert_status "an unknown glossary op is an error" "$st" 2
assert_contains "listed alongside the ops that exist" "$out" "unknown glossary op"

# --- glossary show ------------------------------------------------------------
# The named entries exactly as written, in the order asked, each once, one
# blank line between them and nothing else on stdout. A term matches its name,
# case ignored, else an avoided alias - scoped ones included - which says on
# stderr whose alias it is. An unknown term is named and exits 1, every found
# entry still printed.
echo
echo "glossary show"
new_repo >/dev/null
out="$("$ORCH" glossary show Flow 2>&1)"; st=$?
assert_status "show with no GLOSSARY.md is an error" "$st" 2
assert_eq "naming the missing file" "$out" "orch: no GLOSSARY.md at $PWD"
glossary_fixture
flow_entry="$(writeln '**Flow**:' 'One run of the pipeline.' '' 'A second paragraph about it.' \
                      '_Avoid_: pipeline run, workflow.')"
round_entry="$(writeln '**Round**:' 'One review of the spec.' \
                       '_Avoid_: pass, iteration (the review loop'"'"'s).')"
side_entry="$(writeln '**Side checkout**:' 'A worktree beside the main one.' \
                      '_Avoid_: sibling worktree, second checkout (as the general term, or any).')"
budget_entry="$(writeln '**Budget**:' 'How many iterations a loop may run.')"

out="$("$ORCH" glossary show Flow 2>/dev/null)"; st=$?
assert_status "show one term succeeds" "$st" 0
assert_eq "printing its entry whole, inner blank line kept, ending at the next term line" \
  "$out" "$flow_entry"
assert_eq "an entry ending at a section heading prints no heading" \
  "$("$ORCH" glossary show Round 2>/dev/null)" "$round_entry"
assert_eq "nor does one whose heading is followed by section prose" \
  "$("$ORCH" glossary show 'Side checkout' 2>/dev/null)" "$side_entry"
out="$("$ORCH" glossary show Budget 2>/dev/null; echo x)"
assert_eq "an entry at end of file has its trailing blank lines trimmed" "$out" "$budget_entry"$'\n'x
assert_eq "several terms print in the order asked, one blank line between" \
  "$("$ORCH" glossary show Budget Flow 2>/dev/null)" "$budget_entry"$'\n\n'"$flow_entry"
assert_eq "a term asked twice prints once" \
  "$("$ORCH" glossary show Flow Budget flow 2>/dev/null)" "$flow_entry"$'\n\n'"$budget_entry"
out="$("$ORCH" glossary show 'SIDE CHECKOUT' 2>&1)"; st=$?
assert_status "a term matches its name case-insensitively" "$st" 0
assert_eq "printing its entry and nothing else" "$out" "$side_entry"

err="$(mktemp)"
out="$("$ORCH" glossary show Workflow 2>"$err")"; st=$?
assert_status "an avoided alias resolves" "$st" 0
assert_eq "to its canonical entry" "$out" "$flow_entry"
assert_eq "saying on stderr whose alias it is" "$(cat "$err")" "# alias of Flow"
out="$("$ORCH" glossary show iteration 2>"$err")"; st=$?
assert_status "a scoped alias resolves too" "$st" 0
assert_eq "to its canonical entry" "$out" "$round_entry"
assert_eq "named as an alias on stderr" "$(cat "$err")" "# alias of Round"
assert_eq "an alias whose note holds a comma resolves to its own entry" \
  "$("$ORCH" glossary show 'second checkout' 2>/dev/null)" "$side_entry"

out="$("$ORCH" glossary show Flow Nonesuch Budget Other 2>"$err")"; st=$?
assert_status "an unknown term among known ones exits 1" "$st" 1
assert_eq "every known entry still printed" "$out" "$flow_entry"$'\n\n'"$budget_entry"
assert_eq "each unknown term named on stderr" "$(cat "$err")" \
  "$(writeln "orch: no glossary entry for 'Nonesuch'" "orch: no glossary entry for 'Other'")"
out="$("$ORCH" glossary show 'checkout' 2>&1)"; st=$?
assert_status "part of a term name is no match" "$st" 1
out="$("$ORCH" glossary show 2>&1)"; st=$?
assert_status "show with no term is an error" "$st" 2
assert_contains "with its usage line" "$out" "usage: orch.sh glossary show <term>..."
rm -f "$err"

# --- glossary match -----------------------------------------------------------
# Every entry whose term or unscoped avoided alias the files mention, in
# glossary order and each once. A mention is case-insensitive and starts at a
# word boundary; any ending matches, and any whitespace run matches a space.
echo
echo "glossary match"
new_repo >/dev/null
text="$(mktemp)"
writeln 'Nothing to see here.' >"$text"
out="$("$ORCH" glossary match "$text" 2>&1)"; st=$?
assert_status "match with no GLOSSARY.md succeeds" "$st" 0
assert_eq "and prints nothing" "$out" ""
glossary_fixture
flow_entry="$("$ORCH" glossary show Flow)"
round_entry="$("$ORCH" glossary show Round)"
side_entry="$("$ORCH" glossary show 'Side checkout')"
budget_entry="$("$ORCH" glossary show Budget)"

# match_of <text>: the entries match prints for a file holding <text>.
match_of() { printf '%s\n' "$1" >"$text"; "$ORCH" glossary match "$text" 2>&1; }
assert_eq "a plural mention matches" "$(match_of 'Two flows ran.')" "$flow_entry"
assert_eq "a possessive one, any case, matches" "$(match_of "the FLOW's branch")" "$flow_entry"
assert_eq "a multi-word term wrapped across lines matches" \
  "$(match_of $'open a side\n   checkout here')" "$side_entry"
assert_eq "an unscoped avoided alias pulls its entry in" \
  "$(match_of 'a sibling worktree')" "$side_entry"
assert_eq "a term inside a longer word is no mention" "$(match_of 'look around')" ""
assert_eq "a scoped alias pulls nothing in" "$(match_of 'the next iteration')" ""
assert_eq "nor one whose note holds a comma" "$(match_of 'a second checkout')" ""
out="$(match_of 'Nothing to see here.')"; st=$?
assert_status "no hits succeeds" "$st" 0
assert_eq "printing nothing" "$out" ""

other="$(mktemp)"
writeln 'The budget of a flow.' >"$text"
writeln 'Each round of a workflow, and every Flow.' >"$other"
out="$("$ORCH" glossary match "$text" "$other" 2>&1)"; st=$?
assert_status "match over several files succeeds" "$st" 0
assert_eq "printing glossary order, each entry once, one blank line between" "$out" \
  "$flow_entry"$'\n\n'"$round_entry"$'\n\n'"$budget_entry"

out="$("$ORCH" glossary match "$text" "$PWD/nonesuch.md" 2>&1)"; st=$?
assert_status "a missing file is an error" "$st" 2
assert_eq "naming the file, and printing no entry" "$out" "orch: no such file '$PWD/nonesuch.md'"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$other"
  out="$("$ORCH" glossary match "$other" 2>&1)"; st=$?
  assert_status "an unreadable file is an error" "$st" 2
  assert_eq "naming the file" "$out" "orch: no such file '$other'"
  chmod 644 "$other"
fi
rm -f GLOSSARY.md
out="$("$ORCH" glossary match "$PWD/nonesuch.md" 2>&1)"; st=$?
assert_status "a missing file is an error with no GLOSSARY.md too" "$st" 2
out="$("$ORCH" glossary match 2>&1)"; st=$?
assert_status "match with no file is an error" "$st" 2
assert_contains "with its usage line" "$out" "usage: orch.sh glossary match <file>..."
rm -f "$text" "$other"

# --- glossary help ------------------------------------------------------------
# The noun is discoverable like every other: in orch.sh help, and in the CLI
# conventions' noun table (whose row docs_lint.sh's routed-nouns check holds).
echo
echo "glossary help"
new_repo >/dev/null
out="$("$ORCH" help 2>&1)"
assert_contains "help lists glossary terms" "$out" "glossary terms"
assert_contains "and glossary show" "$out" "glossary show <term>..."
assert_contains "and glossary match" "$out" "glossary match <file>..."
