# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- comments module --------------------------------------------------------
# The Comments module: the trusted reader, the two dying wrappers over it, the
# rendered shape and the split, called through a sourced orch.sh over comments
# seeded in the gh fake.
echo
echo "comments module"
tick_fixture
fake_issue 7 open ready-for-agent orch:spec
fake_pr 9 open topic main

# cm_run <script>: runs the script in a sourced orch.sh, stdout and stderr
# together, then "rc=<status>".
cm_run() { sourced_orch_script 'rc=0; '"$1"'; echo "rc=$rc"' 2>&1; }

# The reader, issue and PR: one comment each, the shape the callers get.
fake_comment 7 pat 2026-09-02T11:30:00Z "an issue comment"
fake_pr_comment 9 sam 2026-10-01T09:00:00Z "a PR comment"
cm_shape='comments_trusted_read $1 $2 got err || rc=$?; printf "%s|%s\n" "$got" "$err"'
assert_eq "comments_trusted_read issue assigns {author, createdAt, body, url}, no authorAssociation" \
  "$(sourced_orch_script 'rc=0; '"$cm_shape" issue 7 2>&1)" \
  '[{"author":"pat","createdAt":"2026-09-02T11:30:00Z","body":"an issue comment","url":"https://github.com/o/r/issues/7#issuecomment-1"}]|'
assert_eq "comments_trusted_read pr assigns the same shape" \
  "$(sourced_orch_script 'rc=0; '"$cm_shape" pr 9 2>&1)" \
  '[{"author":"sam","createdAt":"2026-10-01T09:00:00Z","body":"a PR comment","url":"https://github.com/o/r/issues/9#issuecomment-1"}]|'

# An untrusted author's comment is dropped, with one stderr line.
fake_comment 7 stranger 2026-09-03T11:30:00Z "from outside" NONE
assert_eq "an untrusted author's comment is dropped, reported once on stderr" \
  "$(sourced_orch_script 'comments_trusted_read issue 7 got err; echo "rc=$?"; jq -r "map(.author)|join(\",\")" <<<"$got"' 2>&1)" \
  "orch: ignored 1 comment(s) from untrusted authors on #7
rc=0
pat"

# Failures: the calling shell goes on.
fake_fail adapter_issue_comments "HTTP 502 comments"
assert_eq "a gh failure returns 1, out empty, gh's reason in err" \
  "$(cm_run 'comments_trusted_read issue 7 got err || rc=$?; echo "got=[$got] err=[$err]"')" \
  "got=[] err=[HTTP 502 comments]
rc=1"
fake_fail adapter_issue_comments ""
assert_eq "a gh failure with empty stderr gives gh gave no reason" \
  "$(cm_run 'comments_trusted_read issue 7 got err || rc=$?; echo "got=[$got] err=[$err]"')" \
  "got=[] err=[gh gave no reason]
rc=1"
fake_unfail
assert_eq "an answer that is not a comment list returns 1 with both empty" \
  "$(cm_run 'adapter_pr_comments() { echo "not json"; }; comments_trusted_read pr 9 got err || rc=$?; echo "got=[$got] err=[$err]"')" \
  "got=[] err=[]
rc=1"

# No Repo resolvable: gh's guard dies with its remedy, the real adapter against
# the fixture gh.
no_repo_dir="$(mktemp -d)"
(
  cd "$no_repo_dir" || exit 1
  git init -q .
  unset GH_REPO GH_HOST
  gh_fixture
  out="$(env -u ORCH_GH_ADAPTER bash -c 'source "$1"; comments_trusted_read issue 5 got err; echo "returned"' _ "$ORCH" 2>&1)"; st=$?
  assert_status "with no repo the reader dies rather than returning" "$st" 1
  assert_contains "naming GH_REPO as the remedy" "$out" "GH_REPO=<owner>/<repo>"
  assert_not_contains "and never returning" "$out" "returned"
)
rm -rf "$no_repo_dir"

# The wrappers, keyed by issue or pr.
assert_eq "comments_trusted issue assigns the trusted array" \
  "$(sourced_orch_script 'comments_trusted issue "read #7" 7 got 2>/dev/null; jq -r "map(.body)|join(\",\")" <<<"$got"')" \
  "an issue comment"
assert_eq "comments_rendered pr assigns the rendered text" \
  "$(sourced_orch_script 'comments_rendered pr "read PR #9" 9 got; printf "%s" "$got"')" \
  "$(printf '<!-- comment @sam 2026-10-01T09:00:00Z -->\na PR comment')"
assert_gh_dies "comments_rendered issue on a gh failure dies with its hint" adapter_issue_comments "$GH_502" 1 \
  "orch: gh could not read #7: HTTP 502: Bad Gateway - the hint" \
  sourced_orch_script 'comments_rendered --hint "the hint" issue "read #7" 7 got'
assert_gh_dies "comments_trusted pr under --exit 2 dies with status 2" adapter_pr_comments "" 2 \
  "orch: gh could not read PR #9: gh gave no reason" \
  sourced_orch_script 'comments_trusted --exit 2 pr "read PR #9" 9 got'
assert_eq "an answer that is not a comment list dies as its comments did not parse, status 2 under --exit 2" \
  "$(sourced_orch_script 'adapter_pr_comments() { echo "not json"; }; rc=0; (comments_rendered --exit 2 pr "read PR #9" 9 got) || rc=$?; echo "rc=$rc"' 2>&1)" \
  "orch: could not read PR #9: its comments did not parse
rc=2"

# More than 131072 bytes of trusted comments, none of 65536 characters: every
# comment comes through.
fake_pr 11 open topic main
cm_big="$(head -c 60000 /dev/zero | tr '\0' x)"
for k in 1 2 3; do fake_pr_comment 11 sam "2026-10-0${k}T09:00:00Z" "$k$cm_big"; done
cm_text="$(sourced_orch_script 'comments_rendered pr "read PR #11" 11 got; printf "%s" "$got"')"
assert_eq "a PR holding over 131072 bytes of trusted comments renders every comment" \
  "$(grep -c '^<!-- comment @sam ' <<<"$cm_text")" "3"

# The rendered shape (COMMENTS_RENDER_JQ), run on normalised comments.
cm_json='[{"author":"triage-bot","createdAt":"2026-09-01T10:00:00Z","body":"## Agent brief\n\nDo the `$HOME` thing in #6."},{"author":"pat","createdAt":"2026-09-02T11:30:00Z","body":"Also: the second line\n\\\\ stays unescaped."}]'
assert_eq "the render step opens each comment with its author-and-date marker, one blank line between" \
  "$(sourced_orch_script 'comments_render <<<"$1"' "$cm_json")" \
  "$(writeln '<!-- comment @triage-bot 2026-09-01T10:00:00Z -->' \
    '## Agent brief' '' 'Do the `$HOME` thing in #6.' '' \
    '<!-- comment @pat 2026-09-02T11:30:00Z -->' 'Also: the second line' '\\ stays unescaped.')"
assert_eq "and prints nothing at all for no comments" \
  "$(sourced_orch_script 'comments_render <<<"[]"' | wc -c | tr -d ' ')" "0"

# The split, one file per comment, each its body alone.
cm_dir="$(mktemp -d)"
sourced_orch_script 'comments_render <<<"$1" >"$2/all"; comments_split "$2/all" "$2"' "$cm_json" "$cm_dir"
assert_eq "the split writes one file per comment, numbered from 1, each its body" \
  "$(cat "$cm_dir/2")" "$(printf 'Also: the second line\n\\\\ stays unescaped.')"
rm -rf "$cm_dir"
