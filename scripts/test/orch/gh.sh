# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# gh_reply <exit> <stdout> <stderr> <argv...>: the canned reply the fixture gh
# answers to exactly that argv.
gh_reply() {
  local r
  r="$(mktemp -d "$GH_FIXTURE/replies/XXXXXX")"
  printf '%s' "$1" >"$r/exit"
  printf '%s' "$2" >"$r/stdout"
  printf '%s' "$3" >"$r/stderr"
  shift 3
  printf '%s\0' "$@" >"$r/argv"
}

# contract <operation> [args...]: runs one real adapter operation, orch.sh
# sourced with ORCH_GH_ADAPTER unset, against whatever gh is on PATH.
contract() { env -u ORCH_GH_ADAPTER bash -c 'source "$1"; shift; "$@"' _ "$ORCH" "$@"; }

# The five multi-field gh ops gh_op_placement looks for, space-separated.
GH_MULTI_FIELD_OPS="adapter_issue_state_labels adapter_issue_state_labels_body adapter_issue_title_labels adapter_pr_state_draft adapter_pr_refs"

# The gh op placement rule, as gh_op_placement's message states it.
GH_OP_PLACEMENT_RULE="The rule: only the gh module, scripts/orch/gh.sh, names a multi-field gh op (${GH_MULTI_FIELD_OPS// /, }); every other script reads one through its reader, which decodes its fields."

# gh_op_placement <dir>: checks every shell script under <dir> (a scripts/
# tree) outside the gh module, orch/gh.sh, and test/ for a name of one of the
# five multi-field gh ops, and prints one line per file and op, sorted, naming
# the file (as scripts/<path>), the op and the rule; returns 1 when it printed
# any. An op counts as a whole word anywhere in code - a command word, or an
# argument to capture, gh_or_die or any other runner; a comment is dropped
# first (a # at a line's start or after a blank or one of ;&|() outside
# quotes), and a name inside a longer name is no match.
gh_op_placement() {
  local out
  out="$(cd "$1" && find . -name '*.sh' ! -path ./orch/gh.sh ! -path './test/*' \
    -exec awk -v rule="$GH_OP_PLACEMENT_RULE" -v opnames="$GH_MULTI_FIELD_OPS" '
    BEGIN { nop = split(opnames, ops, " ") }
    # code(line): the line with its comment dropped; quotes are tracked within
    # the line only.
    function code(line,   i, n, c, q, prev) {
      n = length(line); q = ""; prev = ""
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (q == "\047") { if (c == "\047") q = "" }
        else if (q == "\"") { if (c == "\\") i++; else if (c == "\"") q = "" }
        else if (c == "\\") i++
        else if (c == "\047" || c == "\"") q = c
        else if (c == "#" && (prev == "" || prev ~ /[ \t;&|()]/)) return substr(line, 1, i - 1)
        prev = c
      }
      return line
    }
    {
      s = code($0); file = FILENAME; sub(/^\.\//, "scripts/", file)
      for (k = 1; k <= nop; k++) {
        t = s
        while (match(t, ops[k])) {
          before = substr(t, RSTART - 1, 1); after = substr(t, RSTART + RLENGTH, 1)
          if (before !~ /[A-Za-z0-9_]/ && after !~ /[A-Za-z0-9_]/) {
            printf "%s names %s. %s\n", file, ops[k], rule; break
          }
          t = substr(t, RSTART + 1)
        }
      }
    }
  ' {} +)" || return 2
  [ -z "$out" ] && return 0
  printf '%s\n' "$out" | LC_ALL=C sort -u
  return 1
}

# --- every gh call pinned to the repo (#520) -----------------------------------
# A fork whose gh default points upstream: origin is the fork, GH_REPO unset,
# ORCH_GH_ADAPTER unset so the real adapter operations run, against the fixture
# gh. Every call that reaches it must carry the fork - none may fall back to
# gh's default. The argv each operation hands gh is pinned in "gh adapter
# contract"; this is the guard's own resolution of the repo, from origin.
echo
echo "every gh call pinned to the repo"
new_repo >/dev/null
unset GH_REPO GH_HOST
git remote set-url origin https://github.com/fork/widgets.git
gh_fixture
body="$(mktemp)"
writeln 'Some body.' >"$body"
fetched="$(mktemp)"
# pinned_replies <repo>: the fixture's answers to every call below, for the
# repo named - gh repo view alone takes it in its argv.
pinned_replies() {
  gh_reply 0 $'Some body.\n' '' issue view 5 --json body --jq .body
  gh_reply 0 '' '' issue edit 5 --body-file "$body"
  gh_reply 0 '' '' api 'repos/{owner}/{repo}/issues/50' --jq '.parent_issue_url // empty'
  gh_reply 0 $'main\n' '' repo view "$1" --json defaultBranchRef --jq .defaultBranchRef.name
  gh_reply 0 '[{"bucket":"fail","name":"build","link":"https://github.com/x/y/actions/runs/4242/job/1"}]' '' \
    pr checks 7 --json bucket,name,link
  gh_reply 0 '' '' run rerun 4242 --failed
}
pinned_replies fork/widgets
for args in "issue fetch 5 $fetched" "issue update 5 $body" "ticket parent 50" "base show" "review rerun 7"; do
  # shellcheck disable=SC2086 # each args string is a word list on purpose
  out="$(env -u ORCH_GH_ADAPTER "$ORCH" $args 2>&1)"; st=$?
  assert_status "$args runs in the fork" "$st" 0
done
assert_contains "the rerun reached gh pinned to the fork" \
  "$(cat "$GH_FIXTURE/env.log")" "GH_REPO=fork/widgets GH_HOST=<unset> run rerun 4242 --failed"
assert_contains "gh repo view got the fork as its positional argument" \
  "$(cat "$GH_FIXTURE/env.log")" "GH_REPO=fork/widgets GH_HOST=<unset> repo view fork/widgets "
assert_eq "every gh call carried the fork, and a github.com repo leaves GH_HOST unset" \
  "$(grep -cv '^GH_REPO=fork/widgets GH_HOST=<unset> ' "$GH_FIXTURE/env.log")" "0"
assert_eq "command gh appears in orch.sh and its modules only inside the guard" \
  "$(cat "$ORCH" "$(dirname "$ORCH")"/orch/*.sh | grep -c '\bcommand gh\b')" "1"
assert_contains "and that one is the gh guard's own" \
  "$(sed -n '/^gh() {$/,/^}$/p' "$(dirname "$ORCH")/orch/gh.sh")" 'command gh "$@"'

# No usable repo: the first command that reaches GitHub dies naming GH_REPO,
# in the parent shell (issue fetch) or in a command substitution (ticket
# parent) alike - and behind capture_err's stderr capture too (ticket parent,
# ticket close), whose own capture must not swallow the remedy (#846).
git remote remove origin
: >"$GH_FIXTURE/env.log"
for args in "issue fetch 5 $fetched" "ticket parent 50" "ticket close 50"; do
  # shellcheck disable=SC2086 # each args string is a word list on purpose
  out="$(env -u ORCH_GH_ADAPTER "$ORCH" $args 2>&1)"; st=$?
  assert_status "$args dies with no repo" "$st" 1
  assert_contains "$args names GH_REPO as the remedy" "$out" "GH_REPO=<owner>/<repo>"
done
assert_eq "and nothing reached gh unpinned" "$(cat "$GH_FIXTURE/env.log")" ""
out="$("$ORCH" slug "Some title" 2>&1)"; st=$?
assert_status "a local-only command is unaffected" "$st" 0

# A host other than github.com: gh api takes its host from GH_HOST, not from
# GH_REPO's host part, so every call - gh api's included - must carry both.
git remote add origin git@ghe.example.com:fork/widgets.git
pinned_replies ghe.example.com/fork/widgets
for args in "issue fetch 5 $fetched" "ticket parent 50" "base show" "review rerun 7"; do
  # shellcheck disable=SC2086 # each args string is a word list on purpose
  out="$(env -u ORCH_GH_ADAPTER "$ORCH" $args 2>&1)"; st=$?
  assert_status "$args runs on the repo's own host" "$st" 0
done
assert_contains "gh api was among the calls" "$(cat "$GH_FIXTURE/env.log")" \
  "GH_HOST=ghe.example.com api "
assert_eq "every gh call carried the host-qualified repo and its host" \
  "$(grep -cv '^GH_REPO=ghe.example.com/fork/widgets GH_HOST=ghe.example.com ' "$GH_FIXTURE/env.log")" "0"
restore_suite_env GH_HOST GH_FIXTURE

# --- gh_reason and capture_err (#846) -------------------------------------------

echo
echo "gh_reason and capture_err"
new_repo >/dev/null
# Sourced rather than run, as is_filed_severity is: both are helpers every gh
# death goes through, and sourcing orch.sh defines them without running main.
reason() { bash -c 'source "$1" && gh_reason "$2"' _ "$ORCH" "$1"; }
assert_eq "gh_reason gives only the first line of gh's stderr" \
  "$(reason $'HTTP 502: Bad Gateway\nsecond line\n')" "HTTP 502: Bad Gateway"
assert_eq "and says gh gave no reason when stderr is empty" "$(reason "")" "gh gave no reason"
assert_eq "or when its first line is" "$(reason $'\n')" "gh gave no reason"
# capture_err leaves stdout to the caller's redirect, so a body streamed to a
# file keeps its trailing newlines byte for byte.
cefile="$(mktemp)"
out="$(bash -c 'source "$1"
  emit() { printf "body\n\n"; printf "HTTP 502: Bad Gateway\nsecond line\n" >&2; return 3; }
  st=0; capture_err e emit >"$2" || st=$?
  printf "%s|%s." "$st" "$e"' _ "$ORCH" "$cefile")"
assert_eq "capture_err returns the command's status and sets the error variable to its stderr" \
  "$out" "3|HTTP 502: Bad Gateway
second line
."
assert_eq "and leaves stdout to the caller's redirect, trailing newlines kept" \
  "$(od -c <"$cefile")" "$(printf 'body\n\n' | od -c)"
out="$(bash -c 'source "$1"
  quiet() { printf "x"; }
  e=stale; capture_err e quiet >/dev/null; printf "%s|%s" "$?" "$e"' _ "$ORCH")"
assert_eq "a command that succeeds silently returns 0 and leaves the variable empty" "$out" "0|"
rm -f "$cefile"
unset cefile

# --- gh failure verb and readers (#1022) ----------------------------------------
# gh_die builds the one "gh could not <what>: <reason>" death, gh_or_die runs an
# operation and dies through it, and the readers split a multi-field answer into
# caller-named variables. Sourced, as gh_reason is, against the fake.
echo
echo "gh failure verb and readers"
new_repo >/dev/null
fake_github
# in_orch <script> [args...]: runs the script in a shell that sourced orch.sh,
# the args as its $1...
in_orch() { local s="$1"; shift; bash -c 'source "$1"; shift; '"$s" _ "$ORCH" "$@"; }

out="$(in_orch 'gh_die "read issue #5" "$1"' "$GH_502" 2>&1)"; st=$?
assert_status "gh_die dies with status 1" "$st" 1
assert_eq "naming what gh could not do and only gh's first line" "$out" \
  "orch: gh could not read issue #5: HTTP 502: Bad Gateway"
out="$(in_orch 'gh_die --exit 2 --hint "no member was touched" "read issue #5" ""' 2>&1)"; st=$?
assert_status "gh_die --exit 2 dies with status 2" "$st" 2
assert_eq "and --hint follows the reason" "$out" \
  "orch: gh could not read issue #5: gh gave no reason - no member was touched"

fake_issue 5 open
fake_issue_body 5 $'Body.\n\n'
fake_fail adapter_issue_body "$GH_502"
out="$(in_orch 'gh_or_die "read issue #5" adapter_issue_body 5; echo carried on' 2>&1)"; st=$?
assert_status "gh_or_die dies with status 1 on a failed operation" "$st" 1
assert_eq "with gh_die's message" "$out" "orch: gh could not read issue #5: HTTP 502: Bad Gateway"
out="$(in_orch 'gh_or_die --exit 2 "read issue #5" adapter_issue_body 5' 2>&1)"; st=$?
assert_status "gh_or_die --exit 2 dies with status 2" "$st" 2
out="$(in_orch 'gh_or_die --hint "the flow stays in review" "read issue #5" adapter_issue_body 5' 2>&1)"; st=$?
assert_eq "gh_or_die passes --hint on" "$out" \
  "orch: gh could not read issue #5: HTTP 502: Bad Gateway - the flow stays in review"

# --file on a failure: no partial, created or temp file, an existing target
# unchanged.
vdir="$(mktemp -d)"
in_orch 'gh_or_die --file "$1" "read issue #5" adapter_issue_body 5' "$vdir/new" 2>/dev/null; st=$?
assert_status "gh_or_die --file dies on a failed read" "$st" 1
assert_eq "leaving no file behind, temp or target" "$(ls -A "$vdir")" ""
printf 'old\n' >"$vdir/kept"
in_orch 'gh_or_die --file "$1" "read issue #5" adapter_issue_body 5' "$vdir/kept" 2>/dev/null
assert_eq "and an existing target unchanged, with nothing beside it" \
  "$(cat "$vdir/kept")|$(ls -A "$vdir")" "old|kept"
fake_unfail

out="$(in_orch 'gh_or_die --out out "read issue #5" adapter_issue_body 5; printf "%s|" "$out"')"; st=$?
assert_status "gh_or_die --out succeeds on a good read" "$st" 0
assert_eq "assigning the operation's stdout to the caller's variable" "$out" "Body.|"
out="$(in_orch 'gh_or_die --out err "read issue #5" adapter_issue_body 5; printf "%s|" "$err"')"
assert_eq "even one named as an unprefixed local of the verb would be" "$out" "Body.|"
in_orch 'gh_or_die "read issue #5" adapter_issue_body 5 >"$1"' "$vdir/bare"
assert_eq "a bare gh_or_die leaves stdout to the caller's redirect, byte for byte" \
  "$(od -c <"$vdir/bare")" "$(printf 'Body.\n\n\n' | od -c)"
in_orch 'gh_or_die --file "$1" "read issue #5" adapter_issue_body 5' "$vdir/fetched"; st=$?
assert_status "gh_or_die --file succeeds on a good read" "$st" 0
assert_eq "keeping trailing newlines byte for byte" \
  "$(od -c <"$vdir/fetched")" "$(printf 'Body.\n\n\n' | od -c)"
in_orch 'gh_or_die --file "$1" "read issue #5" adapter_issue_body 5' "$vdir/a/b/fetched"
assert_eq "and fetches into a directory that does not exist yet" \
  "$(cat "$vdir/a/b/fetched")" "Body."
assert_eq "leaving no temp file there" "$(ls -A "$vdir/a/b")" "fetched"

out="$(in_orch 'gh_or_die --exit 2 --out v --file "$1" "read issue #5" adapter_issue_body 5' "$vdir/both" 2>&1)"; st=$?
assert_status "gh_or_die refuses --out with --file, status 1 whatever --exit says" "$st" 1
assert_contains "naming them" "$out" "--out"
assert_contains "both" "$out" "--file"
out="$(in_orch 'gh_or_die --exit 2 --bogus "read issue #5" adapter_issue_body 5' 2>&1)"; st=$?
assert_status "gh_or_die refuses an unknown option with status 1" "$st" 1
assert_contains "naming it" "$out" "--bogus"
rm -rf "$vdir"
unset vdir

# The readers: every output written on success, none on a failure, which fills
# the error variable and prints nothing to stderr. The caller's variables are
# named as an unprefixed reader's locals would be.
rerr="$(mktemp)"
fake_pr 7 open topic main
fake_pr_draft 7
out="$(in_orch 'pr_state_draft_read 7 state draft err; printf "%s|%s" "$state" "$draft"')"
assert_eq "pr_state_draft_read writes the state and the draft flag" "$out" "OPEN|true"
fake_pr 8 merged topic main
out="$(in_orch 'pr_state_draft_read 8 state draft err; printf "%s|%s" "$state" "$draft"')"
assert_eq "a PR that is no draft reads false" "$out" "MERGED|false"
fake_fail adapter_pr_state_draft "$GH_502"
out="$(in_orch 'state=x draft=x; st=0; pr_state_draft_read 7 state draft err || st=$?
  printf "%s|%s|%s|%s" "$st" "$state" "$draft" "$err"' 2>"$rerr")"
assert_eq "a failed read writes neither and fills the error variable" "$out" \
  "1|x|x|$GH_502"
assert_eq "printing nothing to stderr" "$(cat "$rerr")" ""

printf 'abc123\n' >"$ORCH_GH_FAKE_STORE/prs/8/head_oid"
printf 'c1\nc2\n' >"$ORCH_GH_FAKE_STORE/prs/8/commits"
out="$(in_orch 'pr_refs_read 8 oid ref base commits err; printf "%s|%s|%s|%s" "$oid" "$ref" "$base" "$commits"')"
assert_eq "pr_refs_read writes the head SHA, head branch, base and commits" "$out" \
  "abc123|topic|main|c1
c2"
fake_fail adapter_pr_refs "$GH_502"
out="$(in_orch 'oid=x ref=x base=x commits=x; st=0; pr_refs_read 8 oid ref base commits err || st=$?
  printf "%s|%s|%s|%s|%s|%s" "$st" "$oid" "$ref" "$base" "$commits" "$err"' 2>"$rerr")"
assert_eq "a failed refs read writes none and fills the error variable" "$out" \
  "1|x|x|x|x|$GH_502"
assert_eq "printing nothing to stderr" "$(cat "$rerr")" ""

fake_issue 9 open bug enhancement
printf 'A title\n' >"$ORCH_GH_FAKE_STORE/issues/9/title"
out="$(in_orch 'issue_title_labels_read 9 title labels err; printf "%s|%s" "$title" "$labels"')"
assert_eq "issue_title_labels_read writes the title and the labels" "$out" "A title|bug
enhancement"
fake_fail adapter_issue_title_labels "$GH_502"
out="$(in_orch 'title=x labels=x; st=0; issue_title_labels_read 9 title labels err || st=$?
  printf "%s|%s|%s|%s" "$st" "$title" "$labels" "$err"' 2>"$rerr")"
assert_eq "a failed title read writes neither and fills the error variable" "$out" \
  "1|x|x|$GH_502"
assert_eq "printing nothing to stderr" "$(cat "$rerr")" ""
rm -f "$rerr"
unset rerr
fake_unfail
restore_suite_env

# No repo: the gh guard's remedy still reaches the real stderr through
# gh_or_die's capture, as through capture_err's - the real adapter, against
# the fixture gh, since the fake never reaches the guard.
new_repo >/dev/null
unset GH_REPO GH_HOST
gh_fixture
git remote remove origin 2>/dev/null || true
out="$(env -u ORCH_GH_ADAPTER bash -c 'source "$1"; gh_or_die --out v "read issue #5" adapter_issue_body 5' \
  _ "$ORCH" 2>&1)"; st=$?
assert_status "gh_or_die dies with no repo" "$st" 1
assert_contains "naming GH_REPO as the remedy" "$out" "GH_REPO=<owner>/<repo>"
assert_eq "and nothing reached gh" "$(cat "$GH_FIXTURE/env.log" 2>/dev/null)" ""
restore_suite_env GH_HOST GH_FIXTURE
unset -f in_orch

# --- gh fake (#280) --------------------------------------------------------------
# The store-backed fake's own helpers: the store fake_github makes, the seeds
# that land in it in the layout documented at the top of gh_adapter_fake.sh,
# and the lag countdown an operation answers stale by.
echo
echo "gh fake"
fake_github
first_store="$ORCH_GH_FAKE_STORE"
assert_eq "fake_github points orch.sh at the fake" "$ORCH_GH_ADAPTER" "$GH_ADAPTER_FAKE"
assert_eq "with an empty store" "$(find "$first_store" -mindepth 1 | wc -l | tr -d ' ')" "0"
fake_github
assert_ne "a fresh store each time" "$ORCH_GH_FAKE_STORE" "$first_store"
fake_issue 12 open ready-for-agent "needs triage"
assert_eq "fake_issue seeds the issue's state as gh reports it" \
  "$(cat "$ORCH_GH_FAKE_STORE/issues/12/state")" "OPEN"
assert_eq "and its labels, one per line" \
  "$(cat "$ORCH_GH_FAKE_STORE/issues/12/labels")" "$(printf 'ready-for-agent\nneeds triage')"
fake_issue 13 closed
assert_eq "an issue seeded with no labels has none" \
  "$(cat "$ORCH_GH_FAKE_STORE/issues/13/state")|$(cat "$ORCH_GH_FAKE_STORE/issues/13/labels")" "CLOSED|"
lagging() { bash -c 'source "$1"; fake_lagging "$2"' _ "$GH_ADAPTER_FAKE" "$1"; }
fake_lag adapter_issue_body 2
lagging adapter_issue_body; assert_status "a lagged operation answers stale" "$?" 0
lagging adapter_issue_body; assert_status "for as many calls as fake_lag asked" "$?" 0
lagging adapter_issue_body; assert_status "and current after them" "$?" 1
lagging adapter_label_create; assert_status "an operation with no lag is current" "$?" 1
# The fake takes the real adapter's argument grammar (#664): an unknown option,
# or one missing its value, exits 2 with a message on stderr - parsed before
# fake_failing, so even a seeded failure does not mask it. No converted caller
# sends a bad option, so the fake is sourced alone and the operation called.
faked() { bash -c 'source "$1"; shift; "$@"' _ "$GH_ADAPTER_FAKE" "$@"; }
fake_issue 14 open
fake_fail adapter_issue_relabel
fake_fail adapter_issue_close
fake_fail adapter_pr_create
pbody="$(mktemp)"
for bad_args in "adapter_issue_relabel 14 --label x" "adapter_issue_relabel 14 --add" \
           "adapter_issue_relabel 14 --remove" "adapter_issue_relabel 14 x y" \
           "adapter_issue_close 14 --why x" "adapter_issue_close 14 --reason" \
           "adapter_issue_close 14 --comment" "adapter_issue_close 14 completed" \
           "adapter_issue_close 14 --duplicate-of" \
           "adapter_pr_create main x X $pbody --ready" "adapter_pr_create main x X $pbody true"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  err="$(faked $bad_args 2>&1 >/dev/null)"; st=$?
  assert_status "the fake refuses '$bad_args'" "$st" 2
  assert_contains "with a message on stderr" "$err" "${bad_args%% *}"
done
unset bad_args
err="$(faked adapter_issue_relabel 14 --add "" 2>&1 >/dev/null)"; st=$?
assert_status "the fake refuses an empty --add as missing its value" "$st" 2
assert_contains "with a message on stderr" "$err" "--add needs a value"
err="$(faked adapter_issue_close 14 --comment "" 2>&1 >/dev/null)"; st=$?
assert_status "the fake refuses an empty --comment as missing its value" "$st" 2
assert_contains "with a message on stderr" "$err" "--comment needs a value"
# An option directly followed by another of the operation's options is
# missing its value, in either order.
for bad_args in "adapter_issue_relabel 14 --add --remove" "adapter_issue_relabel 14 --remove --add" \
           "adapter_issue_close 14 --reason --comment" "adapter_issue_close 14 --comment --reason"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  err="$(faked $bad_args 2>&1 >/dev/null)"; st=$?
  opts="${bad_args#* * }"
  assert_status "the fake refuses '$bad_args'" "$st" 2
  assert_eq "with its message on stderr" "$err" "fake gh: ${bad_args%% *}: ${opts%% *} needs a value"
done
unset bad_args opts
err="$(faked adapter_issue_relabel 14 --add --remove x 2>&1 >/dev/null)"; st=$?
assert_status "the fake refuses '--add --remove x'" "$st" 2
assert_eq "as --add missing its value, with no unknown option" "$err" \
  "fake gh: adapter_issue_relabel: --add needs a value"
err="$(faked adapter_issue_close 14 --reason --comment Redone. 2>&1 >/dev/null)"; st=$?
assert_status "the fake refuses '--reason --comment Redone.'" "$st" 2
assert_eq "as --reason missing its value, with no unknown option" "$err" \
  "fake gh: adapter_issue_close: --reason needs a value"
rm -f "$pbody"
assert_eq "and a refused close left the issue open" "$(cat "$ORCH_GH_FAKE_STORE/issues/14/state")" "OPEN"
assert_eq "and a refused relabel left its labels unchanged" "$(cat "$ORCH_GH_FAKE_STORE/issues/14/labels")" ""
# A value that only begins with - or -- is a value: the fake refuses by option
# name, never by prefix. A fresh store, with no failure seeded.
fake_github
fake_issue 15 open bug
faked adapter_issue_relabel 15 --add -wip; st=$?
assert_status "the fake adds a label beginning with -" "$st" 0
assert_contains "leaving it among the stored labels" "$(cat "$ORCH_GH_FAKE_STORE/issues/15/labels")" "-wip"
fake_issue 16 open bug
faked adapter_issue_relabel 16 --remove bug --add -wip; st=$?
assert_status "and after an earlier option" "$st" 0
assert_eq "leaving it among the stored labels" "$(cat "$ORCH_GH_FAKE_STORE/issues/16/labels")" "-wip"
fake_issue 17 open
faked adapter_issue_close 17 --comment "--x"; st=$?
assert_status "the fake takes a comment beginning with --" "$st" 0
fake_issue 18 open
faked adapter_issue_close 18 --reason completed --comment "--x"; st=$?
assert_status "and after an earlier option" "$st" 0
fake_issue 19 open
faked adapter_issue_close 19 --duplicate-of 30; st=$?
assert_status "the fake closes an issue as a duplicate" "$st" 0
assert_eq "CLOSED, its reason duplicate" "$(fake_state_of 19) $(fake_reason_of 19)" "CLOSED duplicate"
assert_eq "naming the issue it duplicates" "$(fake_duplicate_of 19)" "30"
# fake_fail_after seeds a failure after n good calls: with an explicit empty
# stderr a silent one (#846), and with the third argument omitted fake_fail's
# message.
fake_issue 20 open
fake_fail_after adapter_issue_state_labels 1 ''
faked adapter_issue_state_labels 20 >/dev/null 2>&1; st=$?
assert_status "fake_fail_after lets the first n calls succeed" "$st" 0
err="$(faked adapter_issue_state_labels 20 2>&1 >/dev/null)"; st=$?
assert_status "then the operation fails" "$st" 1
assert_eq "silently, given an explicit empty stderr" "$err" ""
fake_unfail
fake_fail_after adapter_issue_state_labels 0
err="$(faked adapter_issue_state_labels 20 2>&1 >/dev/null)"; st=$?
assert_status "fake_fail_after with no stderr fails too" "$st" 1
assert_eq "with fake_fail's message" "$err" "fake gh: adapter_issue_state_labels failed"
fake_unfail
restore_suite_env
assert_eq "restore_suite_env undoes fake_github" \
  "${ORCH_GH_ADAPTER-unset} ${ORCH_GH_FAKE_STORE-unset}" "unset unset"

# --- gh adapter contract (#280) ------------------------------------------------
# Each real adapter operation, run against the fixture gh: the exact argv it
# hands gh, the plain text it prints, and a failure - non-zero, gh's stderr
# passed through. The behaviour tests fake these same operations, so these are
# what keeps the fake honest about the real ones.
echo
echo "gh adapter contract"
new_repo >/dev/null
gh_fixture
export GH_REPO=acme/widgets
sev_desc="Review finding filed at major severity"

gh_reply 0 'Label "review:major" created' '' \
  label create review:major --force --color d93f0b --description "$sev_desc"
out="$(contract adapter_label_upsert review:major d93f0b "$sev_desc" 2>&1)"; st=$?
assert_status "label upsert: creates or updates the label with --force" "$st" 0
assert_eq "printing nothing" "$out" ""
assert_contains "pinned to the resolved repo" "$(cat "$GH_FIXTURE/env.log")" \
  "GH_REPO=acme/widgets GH_HOST=<unset> label create review:major --force"

gh_reply 1 '' 'HTTP 403: Resource not accessible by integration' \
  label create review:nit --force --color c5def5 --description "Review finding filed at nit severity"
out="$(contract adapter_label_upsert review:nit c5def5 "Review finding filed at nit severity" 2>&1)"; st=$?
assert_status "label upsert: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Resource not accessible by integration"

gh_reply 0 '' '' label create "triage me" --color e4e669 --description "Not yet triaged"
out="$(contract adapter_label_create "triage me" e4e669 "Not yet triaged" 2>&1)"; st=$?
assert_status "label create: creates a missing label, never with --force" "$st" 0
assert_eq "printing nothing" "$out" ""

gh_reply 1 '' 'label with name "bug" already exists; use `--force` to update its color and description' \
  label create bug --color d73a4a --description "Something isn't working"
out="$(contract adapter_label_create bug d73a4a "Something isn't working" 2>&1)"; st=$?
assert_status "label create: a label that exists fails it" "$st" 1
assert_contains "passing gh's stderr through" "$out" 'label with name "bug" already exists'

: >"$GH_FIXTURE/env.log"
export GH_REPO=ghe.example.com/acme/widgets
gh_reply 0 '' '' label create enhancement --color a2eeef --description "New feature or request"
contract adapter_label_create enhancement a2eeef "New feature or request" >/dev/null 2>&1
assert_contains "a repo on another host pins gh's host too" "$(cat "$GH_FIXTURE/env.log")" \
  "GH_REPO=ghe.example.com/acme/widgets GH_HOST=ghe.example.com label create enhancement"
export GH_REPO=acme/widgets
unset GH_HOST

# The issue operations. Each read prints what gh's own --jq printed, so its
# reply here is that already-formatted text.
gh_reply 0 $'## Problem\n\nTracked in #6.\n' '' issue view 23 --json body --jq .body
out="$(contract adapter_issue_body 23 2>&1)"; st=$?
assert_status "issue body: reads the body" "$st" 0
assert_eq "printing it as it is" "$out" "$(printf '## Problem\n\nTracked in #6.')"
gh_reply 1 '' 'GraphQL: Could not resolve to an issue or pull request with the number of 404.' \
  issue view 404 --json body --jq .body
out="$(contract adapter_issue_body 404 2>&1)"; st=$?
assert_status "issue body: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" \
  "GraphQL: Could not resolve to an issue or pull request with the number of 404."

comments_jq="$(bash -c 'source "$1"; printf "%s" "$COMMENTS_JQ"' _ "$ORCH")"
gh_reply 0 $'<!-- comment @pat 2026-09-02T11:30:00Z -->\nA follow-up.\n' '' \
  issue view 23 --json comments --jq "$comments_jq"
out="$(contract adapter_issue_comments 23 2>&1)"; st=$?
assert_status "issue comments: reads the comments through COMMENTS_JQ" "$st" 0
assert_eq "printing what it formatted" "$out" "$(writeln '<!-- comment @pat 2026-09-02T11:30:00Z -->' 'A follow-up.')"
# COMMENTS_JQ itself, run on gh-shaped JSON: what the fixture's canned reply
# above stands in for.
comments_json='{"comments":[{"author":{"login":"triage-bot"},"createdAt":"2026-09-01T10:00:00Z","body":"## Agent brief\n\nDo the `$HOME` thing in #6."},{"author":{"login":"pat"},"createdAt":"2026-09-02T11:30:00Z","body":"Also: the second line\n\\\\ stays unescaped."}]}'
assert_eq "COMMENTS_JQ opens each comment with its author-and-date marker, one blank line between" \
  "$(printf '%s' "$comments_json" | jq -r "$comments_jq")" \
  "$(writeln '<!-- comment @triage-bot 2026-09-01T10:00:00Z -->' \
    '## Agent brief' '' 'Do the `$HOME` thing in #6.' '' \
    '<!-- comment @pat 2026-09-02T11:30:00Z -->' 'Also: the second line' '\\ stays unescaped.')"
assert_eq "and prints nothing at all for no comments" \
  "$(printf '%s' '{"comments":[]}' | jq -r "$comments_jq" | wc -c | tr -d ' ')" "0"

issue_json_jq="$(bash -c 'source "$1"; printf "%s" "$ISSUE_JSON_JQ"' _ "$ORCH")"
: >"$GH_FIXTURE/env.log"
gh_reply 0 $'{"body":"B.","comments":[],"labels":["bug"],"number":23,"title":"T"}\n' '' \
  issue view 23 --json number,title,body,labels,comments --jq "$issue_json_jq"
out="$(contract adapter_issue_json 23 2>&1)"; st=$?
assert_status "issue json: reads the issue through ISSUE_JSON_JQ" "$st" 0
assert_eq "printing the object it formatted" "$out" '{"body":"B.","comments":[],"labels":["bug"],"number":23,"title":"T"}'
assert_contains "pinned to the resolved repo" "$(cat "$GH_FIXTURE/env.log")" \
  "GH_REPO=acme/widgets GH_HOST=<unset> issue view 23 --json number,title,body,labels,comments"
gh_reply 1 '' 'HTTP 502: Bad Gateway' \
  issue view 404 --json number,title,body,labels,comments --jq "$issue_json_jq"
out="$(contract adapter_issue_json 404 2>&1)"; st=$?
assert_status "issue json: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"
# ISSUE_JSON_JQ itself, run on gh-shaped JSON: every field gh adds beyond the
# trimmed shape - a label's id and colour, a comment author's name and more -
# is dropped.
issue_gh_json='{"number":23,"title":"Widgets need a handle","body":"## Problem\n\nTracked in #6.","labels":[{"id":"LA_1","name":"bug","description":"Broken","color":"d73a4a"},{"id":"LA_2","name":"ready-for-agent","description":"","color":"0e8a16"}],"comments":[{"id":"IC_1","author":{"login":"pat","name":"Pat"},"authorAssociation":"OWNER","body":"A follow-up.","createdAt":"2026-09-02T11:30:00Z","includesCreatedEdit":false,"isMinimized":false,"minimizedReason":"","reactionGroups":[],"url":"https://github.com/acme/widgets/issues/23#issuecomment-1","viewerDidAuthor":true}]}'
assert_eq "ISSUE_JSON_JQ trims gh's answer to number, title, body, label names and comments" \
  "$(printf '%s' "$issue_gh_json" | jq -cS "$issue_json_jq")" \
  '{"body":"## Problem\n\nTracked in #6.","comments":[{"author":"pat","body":"A follow-up.","createdAt":"2026-09-02T11:30:00Z"}],"labels":["bug","ready-for-agent"],"number":23,"title":"Widgets need a handle"}'

gh_reply 0 $'OPEN\nreview:nit\nneeds-triage\n' '' issue view 23 --json state,labels --jq '.state, (.labels[].name)'
out="$(contract adapter_issue_state_labels 23 2>&1)"; st=$?
assert_status "issue state and labels: reads both" "$st" 0
assert_eq "the state first, then one label per line" "$out" "$(writeln OPEN review:nit needs-triage)"

gh_reply 0 $'OPEN\n2\nreview:nit\nready-for-agent\n## Finding\n\n**PR:** x\n' '' \
  issue view 23 --json state,labels,body --jq '.state, (.labels | length), (.labels[].name), .body'
out="$(contract adapter_issue_state_labels_body 23 2>&1)"; st=$?
assert_status "issue state, labels and body: reads all three in one call" "$st" 0
assert_eq "the state, the label count, one label per line, then the body" "$out" \
  "$(writeln OPEN 2 review:nit ready-for-agent '## Finding' '' '**PR:** x')"
gh_reply 1 '' 'HTTP 502: Bad Gateway' \
  issue view 404 --json state,labels,body --jq '.state, (.labels | length), (.labels[].name), .body'
out="$(contract adapter_issue_state_labels_body 404 2>&1)"; st=$?
assert_status "issue state, labels and body: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through (state, labels and body)" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 $'Widgets need a handle\nready-for-agent\n' '' \
  issue view 23 --json title,labels --jq '.title, (.labels[].name)'
out="$(contract adapter_issue_title_labels 23 2>&1)"; st=$?
assert_status "issue title and labels: reads both" "$st" 0
assert_eq "the title first, then one label per line" "$out" "$(writeln 'Widgets need a handle' ready-for-agent)"

gh_reply 0 $'PULL\n' '' \
  issue view 62 --json state,url --jq 'if (.url | test("/pull/")) then "PULL" else .state end'
out="$(contract adapter_issue_state 62 2>&1)"; st=$?
assert_status "issue state: reads the state" "$st" 0
assert_eq "PULL for a pull request's number" "$out" "PULL"

gh_reply 0 $'3\n9\n' '' \
  issue list --state open --label review:nit --label "triage me" --limit 1000 --json number --jq '.[].number'
out="$(contract adapter_issues_labelled review:nit "triage me" 2>&1)"; st=$?
assert_status "issues labelled: lists the open issues carrying every label" "$st" 0
assert_eq "one number per line" "$out" "$(writeln 3 9)"

ibody="$(mktemp)"
writeln 'The body.' >"$ibody"
gh_reply 0 $'https://github.com/acme/widgets/issues/17\n' '' \
  issue create --title "Rename it" --body-file "$ibody" --label review:nit --label "triage me"
out="$(contract adapter_issue_create "Rename it" "$ibody" review:nit "triage me" 2>&1)"; st=$?
assert_status "issue create: files the issue under every label" "$st" 0
assert_eq "printing its number alone" "$out" "17"
gh_reply 0 $'https://github.com/acme/widgets/issues/18\n' '' \
  issue create --title "Unlabelled" --body-file "$ibody"
out="$(contract adapter_issue_create "Unlabelled" "$ibody" 2>&1)"; st=$?
assert_status "issue create: files an issue with no label" "$st" 0
assert_eq "printing its number" "$out" "18"
gh_reply 0 $'Something went sideways\n' '' issue create --title "No URL" --body-file "$ibody"
out="$(contract adapter_issue_create "No URL" "$ibody" 2>/dev/null)"; st=$?
assert_status "issue create: gh output with no issue URL fails it" "$st" 1
assert_eq "printing no number" "$out" ""
gh_reply 1 '' 'could not add label: review:nit not found' issue create --title "Refused" --body-file "$ibody"
out="$(contract adapter_issue_create "Refused" "$ibody" 2>&1)"; st=$?
assert_status "issue create: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "could not add label: review:nit not found"

gh_reply 0 'https://github.com/acme/widgets/issues/23' '' issue edit 23 --body-file "$ibody"
out="$(contract adapter_issue_body_edit 23 "$ibody" 2>&1)"; st=$?
assert_status "issue body edit: replaces the body from the file" "$st" 0
assert_eq "printing nothing" "$out" ""

gh_reply 0 'https://github.com/acme/widgets/issues/23#issuecomment-1' '' issue comment 23 --body-file "$ibody"
out="$(contract adapter_issue_comment 23 "$ibody" 2>&1)"; st=$?
assert_status "issue comment: posts the file as a comment" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 403: Resource not accessible by integration' issue comment 24 --body-file "$ibody"
out="$(contract adapter_issue_comment 24 "$ibody" 2>&1)"; st=$?
assert_status "issue comment: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Resource not accessible by integration"

gh_reply 0 'https://github.com/acme/widgets/issues/23' '' \
  issue edit 23 --remove-label "triage me" --remove-label bug --add-label afk --add-label enhancement
out="$(contract adapter_issue_relabel 23 --add afk --remove "triage me" --add enhancement --remove bug 2>&1)"; st=$?
assert_status "issue relabel: removes and adds in one edit" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 0 '' '' issue edit 24 --add-label wontfix
out="$(contract adapter_issue_relabel 24 --add wontfix 2>&1)"; st=$?
assert_status "issue relabel: with nothing to remove, only adds" "$st" 0
gh_reply 0 '' '' issue edit 25 --remove-label "triage me"
out="$(contract adapter_issue_relabel 25 --remove "triage me" 2>&1)"; st=$?
assert_status "issue relabel: with nothing to add, only removes" "$st" 0
calls="$(gh_calls)"
out="$(contract adapter_issue_relabel 25 2>&1)"; st=$?
assert_status "issue relabel: with nothing to add or remove, succeeds" "$st" 0
assert_eq "printing nothing" "$out" ""
assert_eq "and making no gh call" "$(gh_calls)" "$calls"
# The argument grammar (#664): an unknown option, or one missing its value,
# exits 2 with a message on stderr before any gh call - a caller still on the
# old positional grammar among them.
for bad_args in "--label afk" "--add" "--remove" "afk triage" "--add afk --remove"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  err="$(contract adapter_issue_relabel 25 $bad_args 2>&1 >/dev/null)"; st=$?
  assert_status "issue relabel: '$bad_args' is refused" "$st" 2
  assert_contains "with a message on stderr" "$err" "adapter_issue_relabel"
done
unset bad_args
err="$(contract adapter_issue_relabel 25 --add "" 2>&1 >/dev/null)"; st=$?
assert_status "issue relabel: an empty --add is refused as missing its value" "$st" 2
assert_contains "with a message on stderr" "$err" "--add needs a value"
# An option directly followed by another of the operation's options is
# missing its value, in either order.
for bad_args in "--add --remove" "--remove --add"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  err="$(contract adapter_issue_relabel 25 $bad_args 2>&1 >/dev/null)"; st=$?
  assert_status "issue relabel: '$bad_args' is refused" "$st" 2
  assert_contains "naming the operation" "$err" "adapter_issue_relabel"
  assert_contains "and the option missing its value" "$err" "${bad_args%% *} needs a value"
done
unset bad_args
err="$(contract adapter_issue_relabel 25 --add --remove x 2>&1 >/dev/null)"; st=$?
assert_status "issue relabel: '--add --remove x' is refused" "$st" 2
assert_contains "naming the operation" "$err" "adapter_issue_relabel"
assert_contains "as --add missing its value" "$err" "--add needs a value"
assert_not_contains "not as an unknown option x" "$err" "unknown option"
assert_eq "no refused relabel made a gh call" "$(gh_calls)" "$calls"
# A value that only begins with - is a value, first or after an earlier option.
gh_reply 0 '' '' issue edit 26 --add-label -wip
out="$(contract adapter_issue_relabel 26 --add -wip 2>&1)"; st=$?
assert_status "issue relabel: a label beginning with - is added" "$st" 0
gh_reply 0 '' '' issue edit 27 --remove-label bug --add-label -wip
out="$(contract adapter_issue_relabel 27 --remove bug --add -wip 2>&1)"; st=$?
assert_status "issue relabel: and after an earlier option" "$st" 0

gh_reply 0 'Closed issue #23' '' issue close 23 --reason completed
out="$(contract adapter_issue_close 23 --reason completed 2>&1)"; st=$?
assert_status "issue close: closes with the reason given" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 0 '' '' issue close 24 --reason "not planned" --comment "Retired."
out="$(contract adapter_issue_close 24 --comment "Retired." --reason "not planned" 2>&1)"; st=$?
assert_status "issue close: with a reason and a comment" "$st" 0
gh_reply 0 '' '' issue close 25 --comment "Redone."
out="$(contract adapter_issue_close 25 --comment "Redone." 2>&1)"; st=$?
assert_status "issue close: with a comment and gh's default reason" "$st" 0
gh_reply 0 '' '' issue close 26 --duplicate-of 30
out="$(contract adapter_issue_close 26 --duplicate-of 30 2>&1)"; st=$?
assert_status "issue close: as a duplicate of the issue named" "$st" 0
calls="$(gh_calls)"
for bad_args in "--why completed" "--reason" "--comment" "completed" "--reason completed --comment"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  err="$(contract adapter_issue_close 27 $bad_args 2>&1 >/dev/null)"; st=$?
  assert_status "issue close: '$bad_args' is refused" "$st" 2
  assert_contains "with a message on stderr" "$err" "adapter_issue_close"
done
unset bad_args
err="$(contract adapter_issue_close 27 --reason "" --comment "Redone." 2>&1 >/dev/null)"; st=$?
assert_status "issue close: an empty --reason is refused as missing its value" "$st" 2
assert_contains "with a message on stderr" "$err" "--reason needs a value"
for bad_args in "--reason --comment" "--comment --reason"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  err="$(contract adapter_issue_close 27 $bad_args 2>&1 >/dev/null)"; st=$?
  assert_status "issue close: '$bad_args' is refused" "$st" 2
  assert_contains "naming the operation" "$err" "adapter_issue_close"
  assert_contains "and the option missing its value" "$err" "${bad_args%% *} needs a value"
done
unset bad_args
err="$(contract adapter_issue_close 27 --reason --comment Redone. 2>&1 >/dev/null)"; st=$?
assert_status "issue close: '--reason --comment Redone.' is refused" "$st" 2
assert_contains "naming the operation" "$err" "adapter_issue_close"
assert_contains "as --reason missing its value" "$err" "--reason needs a value"
assert_not_contains "not as an unknown option Redone." "$err" "unknown option"
assert_eq "no refused close made a gh call" "$(gh_calls)" "$calls"
# A comment that only begins with -- is a value, first or after an earlier option.
gh_reply 0 '' '' issue close 28 --comment "--x"
out="$(contract adapter_issue_close 28 --comment "--x" 2>&1)"; st=$?
assert_status "issue close: a comment beginning with -- is posted" "$st" 0
gh_reply 0 '' '' issue close 29 --reason completed --comment "--x"
out="$(contract adapter_issue_close 29 --reason completed --comment "--x" 2>&1)"; st=$?
assert_status "issue close: and after an earlier option" "$st" 0
gh_reply 1 '' 'HTTP 502: Bad Gateway' issue close 26
out="$(contract adapter_issue_close 26 2>&1)"; st=$?
assert_status "issue close: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"
gh_reply 0 'Reopened issue #23' '' issue reopen 23
out="$(contract adapter_issue_reopen 23 2>&1)"; st=$?
assert_status "issue reopen: reopens the issue" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' issue reopen 26
out="$(contract adapter_issue_reopen 26 2>&1)"; st=$?
assert_status "issue reopen: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"
assert_eq "every issue operation was pinned to the resolved repo" \
  "$(grep ' issue ' "$GH_FIXTURE/env.log" | grep -cv '^GH_REPO=acme/widgets GH_HOST=<unset> issue ')" "0"

# The PR operations, the same way: each read's reply is what gh's own --jq
# printed.
gh_reply 0 $'https://github.com/acme/widgets/pull/31\n' '' \
  pr create --draft --base main --head orch/16-x --title "Add it" --body-file "$ibody"
out="$(contract adapter_pr_create main orch/16-x "Add it" "$ibody" --draft 2>&1)"; st=$?
assert_status "pr create: opens a draft PR from head into base" "$st" 0
assert_eq "printing its number alone" "$out" "31"
gh_reply 0 $'https://github.com/acme/widgets/pull/32\n' '' \
  pr create --base main --head uat --title "Release" --body-file "$ibody"
out="$(contract adapter_pr_create main uat "Release" "$ibody" 2>&1)"; st=$?
assert_status "pr create: opens a PR that is not a draft" "$st" 0
assert_eq "printing its number" "$out" "32"
gh_reply 0 $'Warning: 1 uncommitted change\n' '' \
  pr create --base main --head no-url --title "No URL" --body-file "$ibody"
out="$(contract adapter_pr_create main no-url "No URL" "$ibody" 2>/dev/null)"; st=$?
assert_status "pr create: gh output with no PR URL fails it" "$st" 1
assert_eq "printing no number" "$out" ""
gh_reply 1 '' 'a pull request for branch "dup" into branch "main" already exists' \
  pr create --base main --head dup --title "Dup" --body-file "$ibody"
out="$(contract adapter_pr_create main dup "Dup" "$ibody" 2>&1)"; st=$?
assert_status "pr create: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" 'a pull request for branch "dup" into branch "main" already exists'
calls="$(gh_calls)"
for bad_args in "--ready" "true" "--draft --base"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  err="$(contract adapter_pr_create main bad "Bad" "$ibody" $bad_args 2>&1 >/dev/null)"; st=$?
  assert_status "pr create: '$bad_args' is refused" "$st" 2
  assert_contains "with a message on stderr" "$err" "adapter_pr_create"
done
unset bad_args
assert_eq "no refused create made a gh call" "$(gh_calls)" "$calls"

gh_reply 0 $'Closes #12\n\nAdds it.\n' '' pr view 57 --json body --jq .body
out="$(contract adapter_pr_body 57 2>&1)"; st=$?
assert_status "pr body: reads the body" "$st" 0
assert_eq "printing it as it is" "$out" "$(writeln 'Closes #12' '' 'Adds it.')"
gh_reply 1 '' 'no pull requests found for 404' pr view 404 --json body --jq .body
out="$(contract adapter_pr_body 404 2>&1)"; st=$?
assert_status "pr body: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "no pull requests found for 404"

gh_reply 0 $'<!-- comment @pat 2026-10-01T09:00:00Z -->\nLGTM\n' '' \
  pr view 57 --json comments --jq "$comments_jq"
out="$(contract adapter_pr_comments 57 2>&1)"; st=$?
assert_status "pr comments: reads the comments through COMMENTS_JQ" "$st" 0
assert_eq "printing what it formatted" "$out" "$(writeln '<!-- comment @pat 2026-10-01T09:00:00Z -->' 'LGTM')"

refs_jq='(.headRefOid // ""), (.headRefName // ""), (.baseRefName // ""), ((.commits // [])[].oid)'
gh_reply 0 $'bbbb\ntopic\nmain\naaaa\nbbbb\n' '' \
  pr view 57 --json headRefOid,headRefName,baseRefName,commits --jq "$refs_jq"
out="$(contract adapter_pr_refs 57 2>&1)"; st=$?
assert_status "pr refs: reads the PR's head, base and commits" "$st" 0
assert_eq "head SHA, head branch, base branch, then one commit per line, oldest first" \
  "$out" "$(writeln bbbb topic main aaaa bbbb)"
assert_eq "its --jq prints an empty line for a field GitHub leaves null" \
  "$(printf '%s' '{"headRefOid":null,"headRefName":"topic","baseRefName":"main","commits":null}' | jq -r "$refs_jq")" \
  "$(writeln '' topic main)"
gh_reply 1 '' 'HTTP 502: Bad Gateway' \
  pr view 58 --json headRefOid,headRefName,baseRefName,commits --jq "$refs_jq"
out="$(contract adapter_pr_refs 58 2>&1)"; st=$?
assert_status "pr refs: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 '✓ Pull request acme/widgets#57 is marked as "ready for review"' '' pr ready 57
out="$(contract adapter_pr_ready 57 2>&1)"; st=$?
assert_status "pr ready: marks the PR ready" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 403: Resource not accessible by integration' pr ready 58
out="$(contract adapter_pr_ready 58 2>&1)"; st=$?
assert_status "pr ready: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Resource not accessible by integration"

gh_reply 0 '✓ Pull request acme/widgets#57 is converted to "draft"' '' pr ready 57 --undo
out="$(contract adapter_pr_draft 57 2>&1)"; st=$?
assert_status "pr draft: turns the PR into a draft" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 422: Draft pull requests are not supported in this repository.' pr ready 58 --undo
out="$(contract adapter_pr_draft 58 2>&1)"; st=$?
assert_status "pr draft: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 422: Draft pull requests are not supported in this repository."

gh_reply 0 $'OPEN\ntrue\n' '' pr view 57 --json state,isDraft --jq '.state, .isDraft'
out="$(contract adapter_pr_state_draft 57 2>&1)"; st=$?
assert_status "pr state draft: reads the PR's state and draft flag" "$st" 0
assert_eq "the state, then true or false" "$out" "$(writeln OPEN true)"
gh_reply 1 '' 'GraphQL: Could not resolve to a PullRequest with the number of 58.' \
  pr view 58 --json state,isDraft --jq '.state, .isDraft'
out="$(contract adapter_pr_state_draft 58 2>&1)"; st=$?
assert_status "pr state draft: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "GraphQL: Could not resolve to a PullRequest with the number of 58."

gh_reply 0 $'57\n' '' pr list --head quick/12-foo --state open --json number --jq '.[].number'
out="$(contract adapter_prs_open quick/12-foo 2>&1)"; st=$?
assert_status "prs open: lists the open PRs from a branch" "$st" 0
assert_eq "one number per line" "$out" "57"
gh_reply 0 '' '' pr list --head uat --base main --state open --json number --jq '.[].number'
out="$(contract adapter_prs_open uat main 2>&1)"; st=$?
assert_status "prs open: lists the open PRs from a branch into a base" "$st" 0
assert_eq "nothing at all for none" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' pr list --head down --state open --json number --jq '.[].number'
out="$(contract adapter_prs_open down 2>&1)"; st=$?
assert_status "prs open: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 $'61\n' '' pr list --head quick/12-foo --base main --state merged --json number --jq '.[].number'
out="$(contract adapter_prs_merged quick/12-foo main 2>&1)"; st=$?
assert_status "prs merged: lists the merged PRs from a branch into a base" "$st" 0
assert_eq "one number per line" "$out" "61"
gh_reply 1 '' 'HTTP 502: Bad Gateway' pr list --head down --base main --state merged --json number --jq '.[].number'
out="$(contract adapter_prs_merged down main 2>&1)"; st=$?
assert_status "prs merged: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 $'Refs #5\n\nImplements it.\nFixes #6\n' '' \
  pr list --base uat --state merged --limit 1000 --json body --jq '.[].body'
out="$(contract adapter_prs_merged_bodies uat 2>&1)"; st=$?
assert_status "prs merged bodies: reads the bodies of the PRs merged into a base" "$st" 0
assert_eq "each body followed by a newline" "$out" "$(writeln 'Refs #5' '' 'Implements it.' 'Fixes #6')"

gh_reply 0 '✓ Closed pull request acme/widgets#30' '' pr close 30 --comment "Redone."
out="$(contract adapter_pr_close 30 "Redone." 2>&1)"; st=$?
assert_status "pr close: closes the PR with a comment" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' pr close 31 --comment "Redone."
out="$(contract adapter_pr_close 31 "Redone." 2>&1)"; st=$?
assert_status "pr close: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 'https://github.com/acme/widgets/pull/57#issuecomment-1' '' pr comment 57 --body-file "$ibody"
out="$(contract adapter_pr_comment 57 "$ibody" 2>&1)"; st=$?
assert_status "pr comment: posts the file as a comment" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 403: Resource not accessible by integration' pr comment 58 --body-file "$ibody"
out="$(contract adapter_pr_comment 58 "$ibody" 2>&1)"; st=$?
assert_status "pr comment: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Resource not accessible by integration"

gh_reply 0 'https://github.com/acme/widgets/pull/57' '' pr edit 57 --body-file "$ibody"
out="$(contract adapter_pr_body_edit 57 "$ibody" 2>&1)"; st=$?
assert_status "pr body edit: replaces the body from the file" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' pr edit 58 --body-file "$ibody"
out="$(contract adapter_pr_body_edit 58 "$ibody" 2>&1)"; st=$?
assert_status "pr body edit: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"
assert_eq "every PR operation was pinned to the resolved repo" \
  "$(grep ' pr ' "$GH_FIXTURE/env.log" | grep -cv '^GH_REPO=acme/widgets GH_HOST=<unset> pr ')" "0"

# The CI operations. These parse gh's JSON themselves, so each reply here is
# gh's raw answer.
checks_tsv() { printf '%s\t%s\t%s\n' "$@"; }
runs=https://github.com/acme/widgets/actions/runs
gh_reply 0 "[{\"bucket\":\"fail\",\"name\":\"build\",\"link\":\"$runs/4242/job/77\"},{\"bucket\":\"pass\",\"name\":\"lint\",\"link\":null}]" '' \
  pr checks 57 --required --json bucket,name,link
out="$(contract adapter_pr_checks 57 required 2>&1)"; st=$?
assert_status "pr checks: reads the required checks" "$st" 0
assert_eq "one check per line, bucket, name and link as TSV, an empty link for none" \
  "$out" "$(checks_tsv fail build "$runs/4242/job/77" pass lint '')"
gh_reply 0 '[{"bucket":"pass","name":"build","link":"x"}]' '' pr checks 57 --json bucket,name,link
out="$(contract adapter_pr_checks 57 all 2>&1)"; st=$?
assert_status "pr checks: reads every check, without --required" "$st" 0
assert_eq "in the same shape" "$out" "$(checks_tsv pass build x)"
gh_reply 8 '[{"bucket":"pending","name":"build","link":"y"}]' '' pr checks 60 --json bucket,name,link
out="$(contract adapter_pr_checks 60 all 2>&1)"; st=$?
assert_status "pr checks: gh's exit 8 for pending checks is absorbed" "$st" 0
assert_eq "its answer read like an exit 0's" "$out" "$(checks_tsv pending build y)"
gh_reply 8 '' '' pr checks 61 --json bucket,name,link
out="$(contract adapter_pr_checks 61 all 2>&1)"; st=$?
assert_status "pr checks: an exit 8 with nothing readable still succeeds" "$st" 0
assert_eq "as one pending check with no name or link" "$out" "$(checks_tsv pending '' '')"
checks_err="$(mktemp)"
gh_reply 1 '' "no checks reported on the 'topic' branch" pr checks 62 --json bucket,name,link
out="$(contract adapter_pr_checks 62 all 2>"$checks_err")"; st=$?
assert_status "pr checks: no checks reported succeeds" "$st" 0
assert_eq "printing nothing at all on stdout" "$out" ""
assert_eq "passing gh's line through on stderr" "$(cat "$checks_err")" "no checks reported on the 'topic' branch"
gh_reply 1 '' "no required checks reported on the 'topic' branch" pr checks 62 --required --json bucket,name,link
out="$(contract adapter_pr_checks 62 required 2>"$checks_err")"; st=$?
assert_status "pr checks: no required checks reported succeeds" "$st" 0
assert_eq "printing nothing at all on stdout" "$out" ""
assert_eq "passing gh's line through on stderr" "$(cat "$checks_err")" "no required checks reported on the 'topic' branch"
rm -f "$checks_err"
gh_reply 0 '[]' '' pr checks 63 --json bucket,name,link
out="$(contract adapter_pr_checks 63 all 2>&1)"; st=$?
assert_status "pr checks: an empty list succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 0 'not json at all' '' pr checks 64 --json bucket,name,link
out="$(contract adapter_pr_checks 64 all 2>&1)"; st=$?
assert_status "pr checks: an answer jq cannot read fails it, never reads as no checks" "$st" 1
assert_eq "saying what it could not read" "$out" "gh pr checks answered with something jq could not read"
gh_reply 1 '' 'dial tcp: lookup api.github.com: no such host' pr checks 65 --json bucket,name,link
out="$(contract adapter_pr_checks 65 all 2>&1)"; st=$?
assert_status "pr checks: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "dial tcp: lookup api.github.com: no such host"
# ci_probe over the real adapter: a failed read is unreachable, its detail
# the first line of gh's stderr alone, and none of that stderr leaks.
gh_reply 1 '' $'dial tcp: lookup api.github.com: no such host\nsecond line' pr checks 66 --json bucket,name,link
out="$(contract ci_probe 66 all 2>&1)"; st=$?
assert_status "ci probe: a failed checks read is still an answer" "$st" 0
assert_eq "unreachable, with the first line of gh's stderr and nothing else" "$out" \
  "$(writeln unreachable "      dial tcp: lookup api.github.com: no such host")"
# A read that fails with nothing on stderr names that, never a blank detail
# line (#925).
gh_reply 1 '' '' pr checks 68 --json bucket,name,link
out="$(contract ci_probe 68 all 2>&1)"; st=$?
assert_status "ci probe: a silently failed checks read is still an answer" "$st" 0
assert_eq "unreachable, its detail saying gh gave no reason" "$out" \
  "$(writeln unreachable "      gh gave no reason")"
gh_reply 1 '' "no checks reported on the 'topic' branch" pr checks 67 --json bucket,name,link
out="$(contract ci_probe 67 all 2>&1)"; st=$?
assert_status "ci probe: no checks reported is an answer" "$st" 0
assert_eq "classified as none, gh's stderr swallowed" "$out" "none"

prot="repos/{owner}/{repo}/branches/main/protection/required_status_checks"
gh_reply 0 '{"strict":false,"contexts":["build","lint"],"checks":[{"context":"build","app_id":null}]}' '' api "$prot"
out="$(contract adapter_branch_required_checks main 2>&1)"; st=$?
assert_status "branch required checks: reads classic protection" "$st" 0
assert_eq "each required context once, one per line" "$out" "$(writeln build lint)"
gh_reply 1 '{"message":"Branch not protected","status":"404"}' 'gh: Branch not protected (HTTP 404)' \
  api "repos/{owner}/{repo}/branches/open/protection/required_status_checks"
out="$(contract adapter_branch_required_checks open 2>&1)"; st=$?
assert_status "branch required checks: GitHub's 404 for an unprotected branch succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 1 '' 'gh: Branch not protected (HTTP 404)' \
  api "repos/{owner}/{repo}/branches/quiet/protection/required_status_checks"
out="$(contract adapter_branch_required_checks quiet 2>&1)"; st=$?
assert_status "branch required checks: the 404 named on stderr alone succeeds" "$st" 0
assert_eq "printing nothing at all, gh's stderr swallowed" "$out" ""
gh_reply 1 '{"message":"Branch not protected","status":"404"}' '' \
  api "repos/{owner}/{repo}/branches/mute/protection/required_status_checks"
out="$(contract adapter_branch_required_checks mute 2>&1)"; st=$?
assert_status "branch required checks: the 404 named on stdout alone succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 1 '{"message":"Not Found","status":"404"}' 'gh: Not Found (HTTP 404)' \
  api "repos/{owner}/{repo}/branches/hidden/protection/required_status_checks"
out="$(contract adapter_branch_required_checks hidden 2>&1)"; st=$?
assert_status "branch required checks: a bare 404 Not Found fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "gh: Not Found (HTTP 404)"
gh_reply 0 '{"strict":true}' '' api "repos/{owner}/{repo}/branches/loose/protection/required_status_checks"
out="$(contract adapter_branch_required_checks loose 2>&1)"; st=$?
assert_status "branch required checks: protection requiring no checks succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""

gh_reply 0 '[{"type":"deletion"},{"type":"required_status_checks","parameters":{}}]' '' \
  api "repos/{owner}/{repo}/rules/branches/main"
out="$(contract adapter_branch_rules main 2>&1)"; st=$?
assert_status "branch rules: reads the rules on a branch" "$st" 0
assert_eq "one rule type per line" "$out" "$(writeln deletion required_status_checks)"
gh_reply 0 '[]' '' api "repos/{owner}/{repo}/rules/branches/bare"
out="$(contract adapter_branch_rules bare 2>&1)"; st=$?
assert_status "branch rules: a branch no ruleset touches succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' api "repos/{owner}/{repo}/rules/branches/down"
out="$(contract adapter_branch_rules down 2>&1)"; st=$?
assert_status "branch rules: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 '{"total_count":3,"check_runs":[{"name":"build"}]}' '' \
  api 'repos/{owner}/{repo}/commits/aaaa/check-runs?per_page=1'
out="$(contract adapter_commit_has_check_runs aaaa 2>&1)"; st=$?
assert_status "commit has check runs: reads a commit's check runs" "$st" 0
assert_eq "yes where it has any" "$out" "yes"
gh_reply 0 '{"total_count":0,"check_runs":[]}' '' api 'repos/{owner}/{repo}/commits/bbbb/check-runs?per_page=1'
assert_eq "commit has check runs: no where it has none" "$(contract adapter_commit_has_check_runs bbbb 2>&1)" "no"
gh_reply 1 '' 'gh: Server Error (HTTP 502)' api 'repos/{owner}/{repo}/commits/cccc/check-runs?per_page=1'
out="$(contract adapter_commit_has_check_runs cccc 2>&1)"; st=$?
assert_status "commit has check runs: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "gh: Server Error (HTTP 502)"
gh_reply 0 'not json' '' api 'repos/{owner}/{repo}/commits/dddd/check-runs?per_page=1'
out="$(contract adapter_commit_has_check_runs dddd 2>&1)"; st=$?
assert_status "commit has check runs: an answer jq cannot read fails it" "$st" 1

gh_reply 0 '{"state":"success","total_count":1,"statuses":[{"context":"ci/legacy"}]}' '' \
  api "repos/{owner}/{repo}/commits/aaaa/status"
out="$(contract adapter_commit_has_statuses aaaa 2>&1)"; st=$?
assert_status "commit has statuses: reads a commit's combined status" "$st" 0
assert_eq "yes where it has any" "$out" "yes"
gh_reply 0 '{"state":"pending","total_count":0,"statuses":[]}' '' api "repos/{owner}/{repo}/commits/main/status"
assert_eq "commit has statuses: no where it has none" "$(contract adapter_commit_has_statuses main 2>&1)" "no"
gh_reply 1 '' 'gh: Server Error (HTTP 502)' api "repos/{owner}/{repo}/commits/cccc/status"
out="$(contract adapter_commit_has_statuses cccc 2>&1)"; st=$?
assert_status "commit has statuses: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "gh: Server Error (HTTP 502)"

gh_reply 0 '✓ Requested rerun of failed jobs' '' run rerun 4242 --failed
out="$(contract adapter_run_rerun 4242 2>&1)"; st=$?
assert_status "run rerun: reruns the run's failed jobs" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 403: Resource not accessible by integration' run rerun 4243 --failed
out="$(contract adapter_run_rerun 4243 2>&1)"; st=$?
assert_status "run rerun: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Resource not accessible by integration"
assert_eq "every CI operation was pinned to the resolved repo" \
  "$(grep -E ' (pr checks|api|run rerun) ' "$GH_FIXTURE/env.log" | grep -cv '^GH_REPO=acme/widgets GH_HOST=<unset> ')" "0"

# The sub-issue and dependency operations. These run gh api, whose --jq the
# operation owns, so each reply here is what that --jq printed. The writes
# take GitHub's database id, which the operation reads itself.
subs="repos/{owner}/{repo}/issues/50/sub_issues"
subs_jq="$(bash -c 'source "$1"; printf "%s" "$SUB_ISSUES_JQ"' _ "$ORCH")"
gh_reply 0 $'51\tOPEN\t0\n52\tCLOSED\t1\n' '' api --paginate "$subs" --jq "$subs_jq"
out="$(contract adapter_sub_issues 50 2>&1)"; st=$?
assert_status "sub-issues: lists a parent's sub-issues" "$st" 0
assert_eq "one per line: number, OPEN or CLOSED, and its open blockers, as TSV" \
  "$out" "$(printf '51\tOPEN\t0\n52\tCLOSED\t1')"
# The --jq itself, run on gh-shaped JSON: what the canned reply above stands
# in for. GitHub can leave the dependency summary off an issue; its blocker
# field is then empty, not a count.
assert_eq "its --jq reads GitHub's listing, a missing dependency summary as an empty blocker field" \
  "$(printf '%s' '[{"number":51,"state":"open","issue_dependencies_summary":{"blocked_by":0}},{"number":52,"state":"closed","issue_dependencies_summary":{"blocked_by":2}},{"number":53,"state":"open"}]' \
    | jq -r "$subs_jq")" "$(printf '51\tOPEN\t0\n52\tCLOSED\t2\n53\tOPEN\t')"
gh_reply 0 '' '' api --paginate "repos/{owner}/{repo}/issues/49/sub_issues" --jq "$subs_jq"
out="$(contract adapter_sub_issues 49 2>&1)"; st=$?
assert_status "sub-issues: a parent with none succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' api --paginate "repos/{owner}/{repo}/issues/48/sub_issues" --jq "$subs_jq"
out="$(contract adapter_sub_issues 48 2>&1)"; st=$?
assert_status "sub-issues: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 $'51000\n' '' api "repos/{owner}/{repo}/issues/51" --jq .id
gh_reply 0 '{}' '' api --method POST "$subs" -F sub_issue_id=51000
out="$(contract adapter_sub_issue_link 50 51 2>&1)"; st=$?
assert_status "sub-issue link: links the child by its database id" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 0 $'53000\n' '' api "repos/{owner}/{repo}/issues/53" --jq .id
gh_reply 1 '' 'HTTP 422: Sub issue may only have one parent' api --method POST "$subs" -F sub_issue_id=53000
out="$(contract adapter_sub_issue_link 50 53 2>&1)"; st=$?
assert_status "sub-issue link: a refused link fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 422: Sub issue may only have one parent"
gh_reply 1 '' 'HTTP 404: Not Found' api "repos/{owner}/{repo}/issues/404" --jq .id
out="$(contract adapter_sub_issue_link 50 404 2>&1)"; st=$?
assert_status "sub-issue link: a child gh cannot read fails it" "$st" 1
assert_eq "passing gh's stderr through, with no link attempted" "$out" "HTTP 404: Not Found"

gh_reply 0 '{}' '' api --method DELETE "repos/{owner}/{repo}/issues/50/sub_issue" -F sub_issue_id=51000
out="$(contract adapter_sub_issue_unlink 50 51 2>&1)"; st=$?
assert_status "sub-issue unlink: unlinks the child by its database id" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 403: Resource not accessible by integration' \
  api --method DELETE "repos/{owner}/{repo}/issues/50/sub_issue" -F sub_issue_id=53000
out="$(contract adapter_sub_issue_unlink 50 53 2>&1)"; st=$?
assert_status "sub-issue unlink: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Resource not accessible by integration"

gh_reply 0 $'https://api.github.com/repos/acme/widgets/issues/50\n' '' \
  api "repos/{owner}/{repo}/issues/51" --jq '.parent_issue_url // empty'
out="$(contract adapter_issue_parent 51 2>&1)"; st=$?
assert_status "issue parent: reads a sub-issue's parent" "$st" 0
assert_eq "printing its number alone, off the parent's URL" "$out" "50"
gh_reply 0 '' '' api "repos/{owner}/{repo}/issues/50" --jq '.parent_issue_url // empty'
out="$(contract adapter_issue_parent 50 2>&1)"; st=$?
assert_status "issue parent: an issue with no parent succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 0 $'https://api.github.com/repos/acme/widgets/issues/\n' '' \
  api "repos/{owner}/{repo}/issues/52" --jq '.parent_issue_url // empty'
out="$(contract adapter_issue_parent 52 2>&1)"; st=$?
assert_status "issue parent: a parent URL with no number fails it" "$st" 1
assert_contains "saying what it could not read" "$out" "no issue number"
gh_reply 1 '' 'HTTP 404: Not Found' api "repos/{owner}/{repo}/issues/404" --jq '.parent_issue_url // empty'
out="$(contract adapter_issue_parent 404 2>&1)"; st=$?
assert_status "issue parent: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 404: Not Found"

blocked="repos/{owner}/{repo}/issues/52/dependencies/blocked_by"
gh_reply 0 $'53\n51\n' '' api --paginate "$blocked" --jq '.[].number'
out="$(contract adapter_blockers 52 2>&1)"; st=$?
assert_status "blockers: lists an issue's blocked-by edges" "$st" 0
assert_eq "one blocker number per line, in GitHub's order" "$out" "$(writeln 53 51)"
gh_reply 1 '' 'HTTP 502: Bad Gateway' api --paginate "repos/{owner}/{repo}/issues/404/dependencies/blocked_by" --jq '.[].number'
out="$(contract adapter_blockers 404 2>&1)"; st=$?
assert_status "blockers: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

gh_reply 0 '{}' '' api --method POST "$blocked" -F issue_id=51000
out="$(contract adapter_blocker_add 52 51 2>&1)"; st=$?
assert_status "blocker add: adds the edge by the blocker's database id" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 422: Validation Failed' api --method POST "$blocked" -F issue_id=53000
out="$(contract adapter_blocker_add 52 53 2>&1)"; st=$?
assert_status "blocker add: a refused edge fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 422: Validation Failed"
out="$(contract adapter_blocker_add 52 404 2>&1)"; st=$?
assert_status "blocker add: a blocker gh cannot read fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 404: Not Found"

gh_reply 0 '{}' '' api --method DELETE "$blocked/51000"
out="$(contract adapter_blocker_remove 52 51 2>&1)"; st=$?
assert_status "blocker remove: removes the edge by the blocker's database id" "$st" 0
assert_eq "printing nothing" "$out" ""
gh_reply 1 '' 'HTTP 404: Not Found' api --method DELETE "$blocked/53000"
out="$(contract adapter_blocker_remove 52 53 2>&1)"; st=$?
assert_status "blocker remove: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 404: Not Found"
assert_eq "every sub-issue and dependency operation was pinned to the resolved repo" \
  "$(grep -E ' api .*issues/' "$GH_FIXTURE/env.log" | grep -cv '^GH_REPO=acme/widgets GH_HOST=<unset> ')" "0"

# The repo operation. `gh repo view` ignores GH_REPO, so the operation names
# the repo it is handed in gh's argv, never leaving it to the guard's pin.
gh_reply 0 $'trunk\n' '' repo view acme/widgets --json defaultBranchRef --jq .defaultBranchRef.name
out="$(contract adapter_repo_default_branch acme/widgets 2>&1)"; st=$?
assert_status "repo default branch: reads the repo's default branch" "$st" 0
assert_eq "printing the bare branch name" "$out" "trunk"
assert_contains "naming the repo positionally, as gh repo view needs" "$(cat "$GH_FIXTURE/env.log")" \
  "GH_REPO=acme/widgets GH_HOST=<unset> repo view acme/widgets --json defaultBranchRef"
gh_reply 1 '' "GraphQL: Could not resolve to a Repository with the name 'acme/gone'. (repository)" \
  repo view acme/gone --json defaultBranchRef --jq .defaultBranchRef.name
out="$(contract adapter_repo_default_branch acme/gone 2>&1)"; st=$?
assert_status "repo default branch: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" \
  "GraphQL: Could not resolve to a Repository with the name 'acme/gone'. (repository)"

# The doctor-only operations (#551). Each case that asks gh the same argv as
# another runs in its own command substitution, with its own fixture gh, since
# the fixture answers one reply per argv.
gh_reply 0 $'github.com\n  Logged in to github.com account acme (keyring)\n' '' auth status
out="$(contract adapter_auth_status 2>&1)"; st=$?
assert_status "auth status: succeeds where gh is authenticated" "$st" 0
assert_contains "printing gh's own report" "$out" "Logged in to github.com"
assert_contains "pinned to the resolved repo" "$(cat "$GH_FIXTURE/env.log")" \
  "GH_REPO=acme/widgets GH_HOST=<unset> auth status"
out="$(gh_fixture; gh_reply 1 '' 'You are not logged into any GitHub hosts. To log in, run: gh auth login' auth status
  contract adapter_auth_status 2>&1)"; st=$?
assert_status "auth status: an unauthenticated gh fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "You are not logged into any GitHub hosts. To log in, run: gh auth login"

gh_reply 0 $'upstream/widgets\n' '' repo set-default --view
out="$(contract adapter_repo_local_default 2>&1)"; st=$?
assert_status "repo local default: reads gh's local default repo" "$st" 0
assert_eq "printing its owner/name" "$out" "upstream/widgets"
# gh 2.102.0 answers "none set" on stderr, exit 0.
out="$(gh_fixture; gh_reply 0 '' 'X No default remote repository has been set.' repo set-default --view
  contract adapter_repo_local_default 2>/dev/null)"; st=$?
assert_status "repo local default: none set succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
out="$(gh_fixture; gh_reply 1 '' 'not a git repository' repo set-default --view
  contract adapter_repo_local_default 2>&1)"; st=$?
assert_status "repo local default: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "not a git repository"

gh_reply 0 $'bug\nneeds-triage\n' '' label list --limit 1000 --json name --jq '.[].name'
out="$(contract adapter_labels 1000 2>&1)"; st=$?
assert_status "labels: lists the repo's label names" "$st" 0
assert_eq "one name per line" "$out" "$(writeln bug needs-triage)"
gh_reply 0 '' '' label list --limit 5 --json name --jq '.[].name'
out="$(contract adapter_labels 5 2>&1)"; st=$?
assert_status "labels: a repo with none succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
gh_reply 1 '' 'HTTP 502: Bad Gateway' label list --limit 7 --json name --jq '.[].name'
out="$(contract adapter_labels 7 2>&1)"; st=$?
assert_status "labels: a gh failure fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"

probe_list=(issue list --state all --limit 1 --json number --jq '.[0].number // empty')
gh_reply 0 $'7\n' '' "${probe_list[@]}"
gh_reply 0 '[]' '' api "repos/{owner}/{repo}/issues/7/sub_issues"
out="$(contract adapter_sub_issues_supported 2>&1)"; st=$?
assert_status "sub-issues supported: probes the sub-issues endpoint on an issue" "$st" 0
assert_eq "yes where it answers" "$out" "yes"
out="$(gh_fixture; gh_reply 0 $'8\n' '' "${probe_list[@]}"
  gh_reply 1 '' 'HTTP 404: Not Found' api "repos/{owner}/{repo}/issues/8/sub_issues"
  contract adapter_sub_issues_supported 2>/dev/null)"; st=$?
assert_status "sub-issues supported: an endpoint that refuses succeeds" "$st" 0
assert_eq "printing no" "$out" "no"
out="$(gh_fixture; gh_reply 0 $'8\n' '' "${probe_list[@]}"
  gh_reply 1 '' 'HTTP 502: Bad Gateway' api "repos/{owner}/{repo}/issues/8/sub_issues"
  contract adapter_sub_issues_supported 2>&1)"; st=$?
assert_status "sub-issues supported: a 502 from the endpoint fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"
out="$(gh_fixture; gh_reply 0 $'8\n' '' "${probe_list[@]}"
  gh_reply 1 '' 'HTTP 403: Forbidden' api "repos/{owner}/{repo}/issues/8/sub_issues"
  contract adapter_sub_issues_supported 2>&1)"; st=$?
assert_status "sub-issues supported: a 403 from the endpoint fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 403: Forbidden"
out="$(gh_fixture; gh_reply 0 '' '' "${probe_list[@]}"; contract adapter_sub_issues_supported 2>&1)"; st=$?
assert_status "sub-issues supported: a repo with no issue succeeds" "$st" 0
assert_eq "printing nothing at all" "$out" ""
out="$(gh_fixture; gh_reply 1 '' 'HTTP 502: Bad Gateway' "${probe_list[@]}"
  contract adapter_sub_issues_supported 2>&1)"; st=$?
assert_status "sub-issues supported: a gh failure listing issues fails it" "$st" 1
assert_eq "passing gh's stderr through" "$out" "HTTP 502: Bad Gateway"
assert_eq "every doctor operation was pinned to the resolved repo" \
  "$(grep -E ' (auth status|repo set-default|label list|issue list --state all|api repos/[{]owner[}]/[{]repo[}]/issues/7/)' "$GH_FIXTURE/env.log" \
    | grep -cv '^GH_REPO=acme/widgets GH_HOST=<unset> ')" "0"
rm -f "$ibody"
restore_suite_env GH_FIXTURE GH_HOST

# --- gh op placement (#1037) --------------------------------------------------
# gh_op_placement over the real scripts/, then over copies of it, each with a
# planted file naming a multi-field gh op: three that break the rule, and three
# that keep it.
echo
echo "gh op placement (#1037)"
out="$(gh_op_placement "$PLUGIN_ROOT/scripts")"; st=$?
if [ "$st" -eq 0 ] && [ -z "$out" ]; then
  ok "no script of the real tree names a multi-field gh op outside the gh module"
else
  bad "no script of the real tree names a multi-field gh op outside the gh module" "$out"
fi

gh_op_dir="$(tree_copy scripts)"
plant_file "$gh_op_dir/orch" zz-command.sh <<'PLANTED'
  planted_read() {
    adapter_pr_refs "$1"
  }
PLANTED
out="$(gh_op_placement "$gh_op_dir")"; st=$?
assert_status "an op as a command word fails" "$st" 1
assert_eq "naming the file, the op and the rule" "$out" \
  "scripts/orch/zz-command.sh names adapter_pr_refs. $GH_OP_PLACEMENT_RULE"
rm -rf "${gh_op_dir%/scripts}"

gh_op_dir="$(tree_copy scripts)"
plant_file "$gh_op_dir/orch" zz-capture.sh <<'PLANTED'
  if ! capture out err adapter_issue_state_labels_body "$n"; then :; fi
PLANTED
out="$(gh_op_placement "$gh_op_dir")"; st=$?
assert_status "an op as an argument to capture fails" "$st" 1
assert_eq "naming the file and the op" "$out" \
  "scripts/orch/zz-capture.sh names adapter_issue_state_labels_body. $GH_OP_PLACEMENT_RULE"
rm -rf "${gh_op_dir%/scripts}"

gh_op_dir="$(tree_copy scripts)"
plant_file "$gh_op_dir" zz-die.sh <<'PLANTED'
  gh_or_die --out state "could not read #$n" adapter_pr_state_draft "$n"
PLANTED
out="$(gh_op_placement "$gh_op_dir")"; st=$?
assert_status "an op as an argument to gh_or_die fails" "$st" 1
assert_eq "naming the file and the op" "$out" \
  "scripts/zz-die.sh names adapter_pr_state_draft. $GH_OP_PLACEMENT_RULE"
rm -rf "${gh_op_dir%/scripts}"

gh_op_dir="$(tree_copy scripts)"
plant_file "$gh_op_dir/orch" zz-keep.sh <<'PLANTED'
  # adapter_issue_title_labels in a comment, as issue_title_labels_read reads it
  x=1  # and adapter_pr_refs after code
  planted_adapter_pr_refs() { my_adapter_issue_title_labels_x; }
  adapter_pr_state_draft_read n st dr err
PLANTED
printf '%s\n' 'planted_gh() { adapter_issue_title_labels "$1"; }' \
  >>"$gh_op_dir/orch/gh.sh"
out="$(gh_op_placement "$gh_op_dir")"; st=$?
assert_status "comments, longer names and the gh module pass" "$st" 0
assert_eq "and print nothing" "$out" ""
rm -rf "${gh_op_dir%/scripts}"
