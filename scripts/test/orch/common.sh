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
common_upcalls() { layer_upcalls "$1" common.sh common.sh gh.sh; }
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

# --- exclude_line -------------------------------------------------------------
# exclude_orch_dirs' four callers (init, side-checkout add, the ticket worktree,
# the review pass) call it bare under set -e, so a failed write (#1548) pins
# their message; the appends keep an unterminated last line whole (#1912).
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

# An unterminated last line is ended before the append (#1912).
new_repo >/dev/null
el_ex="$(git rev-parse --git-common-dir)/info/exclude"
printf 'secrets.env' >"$el_ex"
sourced_orch exclude_line "extra/"
assert_eq "an unterminated last line stays whole beside the appended one" \
  "$(cat "$el_ex")" $'secrets.env\nextra/'
rm -f "$el_ex"
sourced_orch exclude_line "extra/"
assert_eq "a missing file gets just the line" "$(od -An -c "$el_ex" | tr -s ' ')" " e x t r a / \\n"
: >"$el_ex"
sourced_orch exclude_line "extra/"
assert_eq "an empty file gets just the line" "$(od -An -c "$el_ex" | tr -s ' ')" " e x t r a / \\n"
printf 'a\n' >"$el_ex"
sourced_orch exclude_line "extra/"
assert_eq "a terminated file gets no blank line" "$(od -An -c "$el_ex" | tr -s ' ')" " a \\n e x t r a / \\n"
printf 'secrets.env' >"$el_ex"
chmod a-w "$el_ex"
if [ -w "$el_ex" ]; then
  skip "a read-only unterminated file dies as before" "$el_ex stays writable (running as root?)"
else
  out="$(sourced_orch exclude_line "extra/" 2>&1)"; st=$?
  assert_eq "a read-only unterminated file dies as before" "$out" \
    "orch: cannot add extra/ to the git exclude file $el_ex"
fi
chmod u+w "$el_ex"

# --- list_has -----------------------------------------------------------------
# The one newline-list membership test: whole lines, matched literally.
echo
echo "list_has"
new_repo >/dev/null
lh_list=$'-n\nbug\na.c\nneeds triage'
lh_out="$(sourced_orch_script '
    for item in -n bug a.c "needs triage" bu abc needs "-" $'"'"'bug\na.c'"'"'; do
      if list_has "$1" "$item"; then printf " y"; else printf " n"; fi
    done
    if list_has "" bug; then printf " y"; else printf " n"; fi' "$lh_list")"
assert_eq "list_has matches whole lines literally, an item beginning with - included, one spanning lines never" \
  "${lh_out% ?}" " y y y y n n n n n"
assert_eq "list_has finds nothing in an empty list" "${lh_out##* }" "n"
assert_eq "list_has matches glob and regex characters and an empty item literally" \
  "$(sourced_orch_script '
    for item in "" "a*" "a?" "[ab]" "a\\b" "x.*" ".*"; do
      if list_has "$1" "$item"; then printf " y"; else printf " n"; fi
    done' $'a*\na?\n[ab]\na\\b\nx.*\n\nq')" " y y y y y y n"
assert_eq "list_has and path_last_into answer with an empty PATH" \
  "$(sourced_orch_script '
    PATH=
    list_has $'"'"'a\nb'"'"' b && printf y; list_has a b || printf n
    path_last_into r /d/e/f.md .md; printf " %s" "$r"')" "yn f"
# path_last_into: a path's last component, a suffix stripped, as basename gives.
assert_eq "path_last_into gives a path's last component, with and without the suffix, directories or none" \
  "$(sourced_orch_script '
    for args in "/a/b/c.md" "/a/b/c.md .md" "c.md" "c.md .md" ".md .md" "/a/b/ " "/ "; do
      set -- $args
      path_last_into r "$1" "${2:-}"; printf "|%s" "$r"
    done')" "|c.md|c|c.md|c|.md|b|/"

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

# --- capture_err and capture without a temp file (#1780) ----------------------
echo
echo "capture_err and capture without a temp file"
new_repo >/dev/null
ran_marker="$(mktemp -u)"
out="$(sourced_orch eval 'TMPDIR=/nonexistent-dir; st=0; capture_err e touch "'"$ran_marker"'" || st=$?; echo "$st|$e"' 2>&1)"
assert_contains "capture_err says so on stderr" "$out" "could not create a temp file for the command's stderr
"
assert_eq "capture_err returns 1, naming the temp file in its variable" "${out##*$'\n'}" "1|could not create a temp file for the command's stderr"
assert_eq "without running the command" "$(on_disk "$ran_marker")" absent
out="$(sourced_orch eval 'TMPDIR=/nonexistent-dir; st=0; capture o e touch "'"$ran_marker"'" || st=$?; echo "$st|$e"' 2>&1)"
assert_contains "capture says so on stderr" "$out" "could not create a temp file for the command's stdout
"
assert_eq "capture returns 1, naming the temp file in its variable" "${out##*$'\n'}" "1|could not create a temp file for the command's stdout"
assert_eq "capture too runs no command" "$(on_disk "$ran_marker")" absent
out="$(sourced_orch eval 'TMPDIR=/nonexistent-dir; d="$(dirty_outside_allowlist)" || echo "refused"' 2>&1)"
assert_contains "a git-status check under || names the temp file, not git" "$out" "could not create a temp file for git status"
restore_suite_env

# --- capture, capture_err and file_read ---------------------------------------
echo
echo "capture, capture_err and file_read"
new_repo >/dev/null
cap_tmp="$(mktemp -d)"
assert_eq "capture strips stdout's trailing newlines" \
  "$(sourced_orch_script 'capture o e printf "a\n\nb\n\n\n"; printf %s "[$o]"')" "[a

b]"
assert_eq "capture returns the command's status" \
  "$(sourced_orch_script 'st=0; capture o e bash -c "echo out; echo err >&2; exit 7" || st=$?; echo "$st [$o] [$e]"')" "7 [out] [err
]"
assert_eq "a capture nested in a captured command keeps both results" \
  "$(sourced_orch_script 'inner() { capture i ie echo in; echo "got $i"; }; capture o e inner; echo "[$o]"')" "[got in]"
assert_eq "no temp file is left in the temp directory afterwards" \
  "$(TMPDIR="$cap_tmp" sourced_orch_script 'capture o e echo hi; capture_err e echo hi >/dev/null; ls -A "$TMPDIR"')" ""
assert_eq "the temp file is owner-only, read from inside the command" \
  "$(TMPDIR="$cap_tmp" sourced_orch_script 'umask 022; capture o e bash -c "stat -L -c %a /proc/\$\$/fd/1; stat -L -c %a /proc/\$\$/fd/2 >&2"; echo "$o $e"' | tr -d '\n')" "600 600"
assert_eq "a file the command makes, and one the caller makes after, get the caller's mask" \
  "$(TMPDIR="$cap_tmp" sourced_orch_script 'umask 022; capture o e bash -c "touch \"$TMPDIR/by-cmd\""; touch "$TMPDIR/by-caller"; stat -c %a "$TMPDIR/by-cmd" "$TMPDIR/by-caller"; umask')" "644
644
0022"
# with the name function replaced: each thing planted at the first name is left
# untouched and the next name used
cap_script='n=0; temp_file_name() { n=$((n+1)); printf -v "$1" "%s/name%s" "$TMPDIR" "$n"; }; '
cap_script+='capture o e echo ok; echo "rc=$? [$o]"; ls -A "$TMPDIR" | tr "\n" " "'
for cap_kind in file link dangling fifo; do
  rm -rf "$cap_tmp"; mkdir "$cap_tmp"
  case "$cap_kind" in
    file) printf 'planted' >"$cap_tmp/name1" ;;
    link) printf 'target' >"$cap_tmp/real"; ln -s "$cap_tmp/real" "$cap_tmp/name1" ;;
    dangling) ln -s "$cap_tmp/nowhere" "$cap_tmp/name1" ;;
    fifo) mkfifo "$cap_tmp/name1" ;;
  esac
  assert_eq "a $cap_kind at the first name is skipped and the next name used" \
    "$(TMPDIR="$cap_tmp" timeout 10 bash -c 'source "$1"; '"$cap_script" _ "$ORCH" 2>&1)" \
    "rc=0 [ok]
$(ls -A "$cap_tmp" | tr '\n' ' ')"
  case "$cap_kind" in
    file) assert_eq "the planted file is not written through" "$(<"$cap_tmp/name1")" "planted" ;;
    link) assert_eq "the link's target is not written through" "$(<"$cap_tmp/real")" "target" ;;
    dangling) assert_eq "the dangling link's target is not created" "$(on_disk "$cap_tmp/nowhere")" absent ;;
    fifo) assert_eq "the fifo is still a fifo" "$([ -p "$cap_tmp/name1" ] && echo fifo)" fifo ;;
  esac
done
rm -rf "$cap_tmp"; mkdir "$cap_tmp"
ran_marker="$cap_tmp/ran"
assert_eq "a name taken on every try ends in the could-not-create message, the command not run" \
  "$(TMPDIR="$cap_tmp" sourced_orch_script 'temp_file_name() { printf -v "$1" "%s" "$TMPDIR"; }; st=0; capture o e touch "'"$ran_marker"'" 2>&1 || st=$?; echo "rc=$st [$e]"')" \
  "could not create a temp file for the command's stdout
rc=1 [could not create a temp file for the command's stdout]"
assert_eq "and the command did not run" "$(on_disk "$ran_marker")" absent
assert_eq "a captured command leaving a background process returns without waiting" \
  "$(timeout 20 bash -c 'source "$1"; capture o e bash -c "sleep 30 & echo started"; echo "[$o]"' _ "$ORCH" 2>&1)" "[started]"
# file_read
printf 'a\n\n' >"$cap_tmp/nl"; : >"$cap_tmp/empty"
assert_eq "file_read keeps trailing newlines" \
  "$(sourced_orch_script 'file_read v "$1"; printf %s "[$v]"' "$cap_tmp/nl")" "[a

]"
assert_eq "file_read of an empty file sets an empty variable" \
  "$(sourced_orch_script 'v=old; file_read v "$1"; echo "$? [$v]"' "$cap_tmp/empty")" "0 []"
assert_eq "file_read of a missing file fails with the variable untouched" \
  "$(sourced_orch_script 'v=old; st=0; file_read v "$1" 2>/dev/null || st=$?; echo "$st [$v]"' "$cap_tmp/missing")" "1 [old]"
assert_eq "file_read of a missing file gives cat's own message" \
  "$(sourced_orch_script 'file_read v "$1" 2>&1' "$cap_tmp/missing")" "cat: $cap_tmp/missing: No such file or directory"
assert_eq "and of a directory too" \
  "$(sourced_orch_script 'file_read v "$1" 2>&1' "$cap_tmp")" "cat: $cap_tmp: Is a directory"
printf 'x' >"$cap_tmp/unreadable"; chmod a-r "$cap_tmp/unreadable"
if [ ! -r "$cap_tmp/unreadable" ]; then
  assert_eq "file_read of an unreadable file fails with the variable untouched" \
    "$(sourced_orch_script 'v=old; st=0; file_read v "$1" 2>/dev/null || st=$?; echo "$st [$v]"' "$cap_tmp/unreadable")" "1 [old]"
else
  skip "file_read of an unreadable file fails with the variable untouched" "permissions do not bite here, e.g. root"
fi
# a socket passes the readable check but cannot be opened
if perl -MSocket -e 'socket(my $s, AF_UNIX, SOCK_STREAM, 0) or exit 1; bind($s, sockaddr_un($ARGV[0])) or exit 1' "$cap_tmp/sock" 2>/dev/null; then
  assert_eq "file_read of a file that cannot be opened fails with the variable untouched" \
    "$(sourced_orch_script 'v=old; st=0; file_read v "$1" 2>/dev/null || st=$?; echo "$st [$v]"' "$cap_tmp/sock")" "1 [old]"
else
  skip "file_read of a file that cannot be opened fails with the variable untouched" "no perl or no Unix socket here"
fi
# a bare PATH: no external command is needed
printf 'a\0b\n' >"$cap_tmp/nul"
assert_eq "file_read drops a NUL byte and keeps the bytes after it, as cat in a substitution did" \
  "$(sourced_orch_script 'file_read v "$1"; printf %s "[$v]"' "$cap_tmp/nul")" "[ab
]"
assert_eq "file_read runs with an empty PATH" \
  "$(sourced_orch_script 'PATH=""; file_read v "$1"; printf %s "[$v]"' "$cap_tmp/nl")" "[a

]"
cap_bin="$(mktemp -d)"; ln -s "$(command -v rm)" "$cap_bin/rm"
assert_eq "capture and capture_err run with a PATH holding only rm" \
  "$(TMPDIR="$cap_tmp" sourced_orch_script 'PATH="'"$cap_bin"'"; capture o e eval "echo out; echo err >&2"; capture_err e2 eval "echo e2 >&2"; echo "[$o] [$e] [$e2]"')" "[out] [err
] [e2
]"
rm -rf "$cap_tmp" "$cap_bin"
restore_suite_env

# --- die_hinted and die_opt_check ---------------------------------------------
echo
echo "die_hinted and die_opt_check"
new_repo >/dev/null
out="$(sourced_orch die_hinted --hint "try again" "it broke" 2>&1)"; st=$?
assert_status "die_hinted dies with status 1" "$st" 1
assert_eq "a hint ends the message as ' - <hint>'" "$out" "orch: it broke - try again"
out="$(sourced_orch die_hinted --hint "" "it broke" 2>&1)"
assert_eq "an empty hint adds nothing" "$out" "orch: it broke"
out="$(sourced_orch die_hinted --exit 2 "it broke" 2>&1)"; st=$?
assert_status "die_hinted --exit 2 dies with status 2" "$st" 2
out="$(sourced_orch die_opt_check demo 2 --exit 3 2>&1)"; st=$?
assert_status "die_opt_check refuses an --exit other than 2" "$st" 1
assert_eq "naming the caller and the option" "$out" "orch: demo: --exit takes 2, not '3'"
out="$(sourced_orch die_opt_check demo 1 --hint 2>&1)"; st=$?
assert_status "die_opt_check refuses a trailing --hint" "$st" 1
assert_eq "naming the caller and the option for a bare --hint" "$out" "orch: demo: --hint needs a value"
