#!/usr/bin/env bash
#
# version-bump.sh: gathers the changelog fragments of a checkout into one
# version bump. Run from the checkout's root, with no arguments; the
# version-bump Action runs it on every push to main.
#
# A fragment is changelog.d/<issue>.md, <issue> all digits: its first line is
# exactly "bump: patch", "bump: minor" or "bump: major", and the rest, after
# any blank lines, is the CHANGELOG prose, non-empty and holding no heading
# line (a line of # marks at column 0 followed by a space or nothing).
# changelog.d/.gitkeep, tracked so the directory survives a release, is not a
# fragment: it is never refused, read or deleted, and the directory is never
# removed. Any other file under changelog.d/, dotfiles included, is refused.
#
# With no fragment it changes nothing, prints nothing and exits 0. Otherwise
# it bumps .claude-plugin/plugin.json and .antigravity-plugin/plugin.json in
# lockstep by the highest level among the fragments, editing only each file's
# "version" line; inserts "## <new version>", a blank line and the fragments'
# prose, in ascending issue-number order and separated by blank lines, above
# CHANGELOG.md's top ## heading; deletes the fragments; and prints the new
# version. It does not commit.

PLUGIN_JSON=.claude-plugin/plugin.json
ANTIGRAVITY_PLUGIN_JSON=.antigravity-plugin/plugin.json
PLUGIN_JSONS=("$PLUGIN_JSON" "$ANTIGRAVITY_PLUGIN_JSON")
CHANGELOG=CHANGELOG.md

# dotglob too, so a stray dotfile under changelog.d/ is refused, not skipped;
# only changelog.d/.gitkeep is left out.
shopt -s nullglob dotglob
fragments=()
for f in changelog.d/*; do
  [ "$f" = changelog.d/.gitkeep ] || fragments+=("$f")
done
[ "${#fragments[@]}" -eq 0 ] && exit 0

work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT

# refuse <file> <problem>: names the file and its problem on stderr and exits
# 1. Every check runs before anything is written, so a refusal changes nothing.
refuse() {
  printf 'version-bump: %s: %s\n' "$1" "$2" >&2
  exit 1
}

for f in "${fragments[@]}"; do
  [[ "${f#changelog.d/}" =~ ^[0-9]+\.md$ ]] && [ -f "$f" ] ||
    refuse "$f" "not a fragment: changelog.d/ holds only <issue>.md files"
done
# The fragments' names, in ascending issue-number order.
mapfile -t names < <(for f in "${fragments[@]}"; do printf '%s\n' "${f#changelog.d/}"; done |
  LC_ALL=C sort -n)

max_level=0
for name in "${names[@]}"; do
  f="changelog.d/$name"
  case "$(head -n 1 "$f")" in
    "bump: patch") level=1 ;;
    "bump: minor") level=2 ;;
    "bump: major") level=3 ;;
    *) refuse "$f" "its first line is not 'bump: patch', 'bump: minor' or 'bump: major'" ;;
  esac
  [ "$level" -gt "$max_level" ] && max_level=$level
  # The prose: every line after the first, leading and trailing blank lines
  # dropped.
  tail -n +2 "$f" | awk '
    /[^[:space:]]/ { while (held > 0) { print ""; held-- } print; seen = 1; next }
    seen { held++ }' >"$work/$name"
  [ -s "$work/$name" ] || refuse "$f" "it has no prose after its bump: line"
  # A heading line would split the release entry, whose one ## heading the
  # release adds. Fences are not tracked: no CHANGELOG reader tracks them.
  heading="$(awk 'NR > 1 && /^#+([[:space:]]|$)/ { print NR ":" $0; exit }' "$f")"
  if [ -n "$heading" ]; then
    refuse "$f" "line ${heading%%:*} is a heading ('${heading#*:}'); its prose holds no heading, since the release adds the entry's one ## heading"
  fi
done

semver_line='^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([0-9]+)\.([0-9]+)\.([0-9]+)"[[:space:]]*,?[[:space:]]*$'
old=""
major="" minor="" patch=""
line_nos=()
for pj in "${PLUGIN_JSONS[@]}"; do
  [ -f "$pj" ] || refuse "$pj" "missing"
  version_lines="$(grep -n '"version"' "$pj")"
  [ -n "$version_lines" ] && [ "$(printf '%s\n' "$version_lines" | wc -l)" -eq 1 ] ||
    refuse "$pj" "it has no single \"version\" line"
  line_nos+=("${version_lines%%:*}")
  [[ "${version_lines#*:}" =~ $semver_line ]] ||
    refuse "$pj" "its \"version\" line holds no MAJOR.MINOR.PATCH version"
  pj_ver="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  if [ -z "$old" ]; then
    major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
    old="$pj_ver"
  elif [ "$pj_ver" != "$old" ]; then
    refuse "$pj" "version $pj_ver does not match $PLUGIN_JSON ($old)"
  fi
done
[ -f "$CHANGELOG" ] || refuse "$CHANGELOG" "missing"
grep -q '^## ' "$CHANGELOG" || refuse "$CHANGELOG" "it has no ## heading to insert the entry above"

case "$max_level" in
  3) new="$((10#$major + 1)).0.0" ;;
  2) new="$((10#$major)).$((10#$minor + 1)).0" ;;
  1) new="$((10#$major)).$((10#$minor)).$((10#$patch + 1))" ;;
esac

for i in "${!PLUGIN_JSONS[@]}"; do
  sed "${line_nos[$i]}s/\"$old\"/\"$new\"/" "${PLUGIN_JSONS[$i]}" >"$work/plugin-$i.json"
done
{
  awk '/^## / { exit } { print }' "$CHANGELOG"
  printf '## %s\n\n' "$new"
  for name in "${names[@]}"; do
    cat "$work/$name"
    echo
  done
  awk '/^## / { found = 1 } found { print }' "$CHANGELOG"
} >"$work/CHANGELOG.md"

for i in "${!PLUGIN_JSONS[@]}"; do
  cat "$work/plugin-$i.json" >"${PLUGIN_JSONS[$i]}"
done
cat "$work/CHANGELOG.md" >"$CHANGELOG"
rm -f "${fragments[@]}"
printf '%s\n' "$new"
