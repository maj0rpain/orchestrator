# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- common.sh is the bottom layer --------------------------------------------
echo
echo "common.sh is the bottom layer"
# common.sh holds the primitives no concept owns and calls nothing a noun
# module defines: its code view (shell_code) names, as a whole word, no function
# defined in a module of its orch/ directory other than common.sh and gh.sh,
# the adapter layer below it. A name in a comment is no call; one in a quoted
# literal is. common_upcalls <scripts-dir> prints each such
# name found in <scripts-dir>/orch/common.sh. A definition is a column-0
# `name()` line. host.sh, triage-labels.sh and planning-allowlist.sh sit
# outside orch/, so common.sh's calls into them are outside the check.
common_upcalls() {
  local defs=() f
  for f in "$1"/orch/*.sh; do
    case "$(basename "$f")" in common.sh|gh.sh) continue ;; esac
    defs+=("$f")
  done
  layer_calls "${defs[@]}" -- "$1/orch/common.sh"
}
layer_dir="$(mktemp -d)"
mkdir "$layer_dir/orch"
printf '%s\n' 'noun_fn() {' '  :' '}' >"$layer_dir/orch/noun.sh"
printf '%s\n' '# noun_fn is named in a comment only' '  # noun_fn again' \
  'prim() { noun_fnx; }' >"$layer_dir/orch/common.sh"
assert_eq "a comment or a longer word is no call into a noun module" \
  "$(common_upcalls "$layer_dir")" ""
printf '%s\n' 'x=1 # noun_fn' >"$layer_dir/orch/common.sh"
assert_eq "a name in a trailing comment is no call into a noun module" \
  "$(common_upcalls "$layer_dir")" ""
printf '%s\n' 'prim() { noun_fn; }' >"$layer_dir/orch/common.sh"
assert_eq "a noun-module function called from common.sh is caught" \
  "$(common_upcalls "$layer_dir")" "noun_fn"
printf '%s\n' "prim() { trap 'noun_fn' EXIT; }" >"$layer_dir/orch/common.sh"
assert_eq "a name in a quoted literal is still a call into a noun module" \
  "$(common_upcalls "$layer_dir")" "noun_fn"
printf '%s\n' 'gh() {' '  :' '}' >"$layer_dir/orch/gh.sh"
printf '%s\n' 'own() {' '  :' '}' 'prim() { gh; own; }' >"$layer_dir/orch/common.sh"
assert_eq "a gh.sh-only function or common.sh's own is no call into a noun module" \
  "$(common_upcalls "$layer_dir")" ""
rm -rf "$layer_dir"
assert_eq "common.sh calls no function a noun module defines" \
  "$(common_upcalls "$(dirname "$ORCH")" | tr '\n' ' ')" ""

# --- orch_dirs_unexcluded -----------------------------------------------------
# The one membership test of the clone's info/exclude: exclude_orch_dirs appends
# what it prints and doctor's check_git_exclude reports it.
echo
echo "orch_dirs_unexcluded"
new_repo >/dev/null
ude_ex="$(git rev-parse --git-common-dir)/info/exclude"
rm -f "$ude_ex"
assert_eq "a missing exclude file lacks every entry" \
  "$(sourced_orch orch_dirs_unexcluded | tr '\n' ' ')" ".orchestrator/ .scratch/ "
printf '%s\n' '# comment' '.scratch/' >"$ude_ex"
assert_eq "only the missing entries print when some are present" \
  "$(sourced_orch orch_dirs_unexcluded | tr '\n' ' ')" ".orchestrator/ "
printf '%s\n' '.orchestrator/' >>"$ude_ex"
assert_eq "nothing prints when every entry is present" \
  "$(sourced_orch orch_dirs_unexcluded)" ""

# --- exclude_line's failed write (#1548) --------------------------------------
# exclude_orch_dirs' four callers (init, side-checkout add, the ticket worktree,
# the review pass) call it bare under set -e, so this pins their message.
echo
echo "exclude_line"
new_repo >/dev/null
el_dir="$(git rev-parse --git-common-dir)"
rm -rf "$el_dir/info/exclude"
mkdir -p "$el_dir/info/exclude"
out="$(sourced_orch exclude_orch_dirs 2>&1)"; st=$?
assert_status "an exclude file it cannot append to exits 1" "$st" 1
assert_eq "naming both missing lines and the file" "$out" \
  "orch: cannot add .orchestrator/, .scratch/ to the git exclude file $el_dir/info/exclude"
rm -rf "$el_dir/info/exclude"
rm -rf "$el_dir/info"
: >"$el_dir/info"
out="$(sourced_orch exclude_orch_dirs 2>&1)"; st=$?
assert_status "an info that is a plain file exits 1" "$st" 1
assert_eq "with the same message" "$out" \
  "orch: cannot add .orchestrator/, .scratch/ to the git exclude file $el_dir/info/exclude"
rm -f "$el_dir/info"
mkdir -p "$el_dir/info"
printf '%s\n' '.scratch/' >"$el_dir/info/exclude"
chmod a-w "$el_dir/info/exclude"
if [ -w "$el_dir/info/exclude" ]; then
  skip "only the missing line is named" "$el_dir/info/exclude stays writable (running as root?)"
else
  out="$(sourced_orch exclude_orch_dirs 2>&1)"; st=$?
  assert_eq "only the missing line is named" "$out" \
    "orch: cannot add .orchestrator/ to the git exclude file $el_dir/info/exclude"
fi
chmod u+w "$el_dir/info/exclude"

# --- list_has -----------------------------------------------------------------
# The one newline-list membership test: whole lines, matched literally.
echo
echo "list_has"
new_repo >/dev/null
lh_list=$'-n\nbug\na.c\nneeds triage'
lh_verdicts=""
for lh_item in -n bug a.c 'needs triage' bu abc needs '-' $'bug\na.c'; do
  if sourced_orch list_has "$lh_list" "$lh_item"; then lh_verdicts="$lh_verdicts y"
  else lh_verdicts="$lh_verdicts n"; fi
done
assert_eq "list_has matches whole lines literally, an item beginning with - included, one spanning lines never" \
  "$lh_verdicts" " y y y y n n n n n"

# --- list_join ----------------------------------------------------------------
# The one newline-list join: non-empty lines, joined by ", ".
echo
echo "list_join"
new_repo >/dev/null
assert_eq "list_join of empty input is an empty line" "$(sourced_orch list_join "")" ""
assert_eq "list_join of one item is that item" "$(sourced_orch list_join "a")" "a"
assert_eq "list_join joins several items with ', '" \
  "$(sourced_orch list_join $'a\nb\nc')" "a, b, c"
assert_eq "list_join keeps an item containing a comma whole" \
  "$(sourced_orch list_join $'a,b.md\nc')" "a,b.md, c"
assert_eq "list_join skips blank lines" \
  "$(sourced_orch list_join $'\na\n\nb\n')" "a, b"

# --- word_listed --------------------------------------------------------------
# The one space-list membership test: a whole word, never several or part.
echo
echo "word_listed"
new_repo >/dev/null
wl_verdicts=""
for wl_item in spec implement 'done' 'spec implement' impl '' 'implement review'; do
  if sourced_orch word_listed "spec implement review done" "$wl_item"; then wl_verdicts="$wl_verdicts y"
  else wl_verdicts="$wl_verdicts n"; fi
done
assert_eq "word_listed accepts a whole word of the list, never part of one, two adjacent words or an empty word" \
  "$wl_verdicts" " y y y n n n n"

# --- is_positive_int ----------------------------------------------------------
# The one whole-number-of-1-or-more test.
echo
echo "is_positive_int"
new_repo >/dev/null
pi_verdicts=""
for pi_item in 1 08 42 0 00 -1 1.5 '' abc ' 3'; do
  if sourced_orch is_positive_int "$pi_item"; then pi_verdicts="$pi_verdicts y"
  else pi_verdicts="$pi_verdicts n"; fi
done
assert_eq "is_positive_int accepts whole numbers of 1 or more, leading zeros included, and nothing else" \
  "$pi_verdicts" " y y y n n n n n n n"

# --- err_line (#1718) ---------------------------------------------------------
# A captured error's first line, everything through its first `orch: ` dropped.
echo
echo "err_line"
new_repo >/dev/null
assert_eq "err_line drops the prefix and keeps the first line" \
  "$(sourced_orch err_line $'orch: first\n     second')" "first"
assert_eq "err_line drops stray text ahead of the first prefix" \
  "$(sourced_orch err_line $'jq: parse error\norch: the reason')" "the reason"
assert_eq "err_line leaves an error with no prefix as its first line" \
  "$(sourced_orch err_line $'plain\nmore')" "plain"

# --- git_push (#1300) ---------------------------------------------------------
# Every push orch.sh makes runs through git_push, which returns the push's
# status and cuts git's reason out of its stderr. pr open, pr publish and
# branch's sections pin each site; this pins the join of several ` ! ` lines,
# which no command's single-ref push can reach.
echo
echo "git_push"
new_repo >/dev/null
gp_bare="$(mktemp -d)/origin.git"
git init -q --bare "$gp_bare"
bare_origin "$gp_bare"
git push -q origin HEAD:refs/heads/main
git commit -q --allow-empty -m "more"
origin_rejects "$gp_bare"
assert_eq "a rejected push of two refs returns 1 with both ' ! ' lines, joined by '; '" \
  "$(sourced_orch eval 'git_push why origin HEAD:refs/heads/a HEAD:refs/heads/b || echo "$?: $why"')" \
  "1: ! [remote rejected] HEAD -> a (pre-receive hook declined); ! [remote rejected] HEAD -> b (pre-receive hook declined)"
restore_suite_env
