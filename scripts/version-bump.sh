#!/usr/bin/env bash
#
# version-bump.sh: gathers the changelog fragments of a checkout into one
# version bump. Run from the checkout's root, with no arguments; the
# version-bump Action runs it on every push to main.
#
# A fragment is changelog.d/<issue>.md, <issue> all digits: its first line is
# exactly "bump: patch", "bump: minor" or "bump: major", and the rest, after
# any blank lines, is the CHANGELOG prose, non-empty.
#
# With no fragment it changes nothing, prints nothing and exits 0. Otherwise
# it bumps .claude-plugin/plugin.json's version by the highest level among
# the fragments, editing only its "version" line; inserts "## <new version>",
# a blank line and the fragments' prose, in ascending issue-number order and
# separated by blank lines, above CHANGELOG.md's top ## heading; deletes the
# fragments; and prints the new version. It does not commit.

PLUGIN_JSON=.claude-plugin/plugin.json
CHANGELOG=CHANGELOG.md

# dotglob too, so a stray dotfile under changelog.d/ is refused, not skipped.
shopt -s nullglob dotglob
fragments=(changelog.d/*)
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
done

[ -f "$PLUGIN_JSON" ] || refuse "$PLUGIN_JSON" "missing"
version_lines="$(grep -n '"version"' "$PLUGIN_JSON")"
[ -n "$version_lines" ] && [ "$(printf '%s\n' "$version_lines" | wc -l)" -eq 1 ] ||
  refuse "$PLUGIN_JSON" "it has no single \"version\" line"
line_no="${version_lines%%:*}"
semver_line='^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([0-9]+)\.([0-9]+)\.([0-9]+)"[[:space:]]*,?[[:space:]]*$'
[[ "${version_lines#*:}" =~ $semver_line ]] ||
  refuse "$PLUGIN_JSON" "its \"version\" line holds no MAJOR.MINOR.PATCH version"
major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
old="$major.$minor.$patch"
[ -f "$CHANGELOG" ] || refuse "$CHANGELOG" "missing"
grep -q '^## ' "$CHANGELOG" || refuse "$CHANGELOG" "it has no ## heading to insert the entry above"

case "$max_level" in
  3) new="$((10#$major + 1)).0.0" ;;
  2) new="$((10#$major)).$((10#$minor + 1)).0" ;;
  1) new="$((10#$major)).$((10#$minor)).$((10#$patch + 1))" ;;
esac

sed "${line_no}s/\"$old\"/\"$new\"/" "$PLUGIN_JSON" >"$work/plugin.json"
{
  awk '/^## / { exit } { print }' "$CHANGELOG"
  printf '## %s\n\n' "$new"
  for name in "${names[@]}"; do
    cat "$work/$name"
    echo
  done
  awk '/^## / { found = 1 } found { print }' "$CHANGELOG"
} >"$work/CHANGELOG.md"

cat "$work/plugin.json" >"$PLUGIN_JSON"
cat "$work/CHANGELOG.md" >"$CHANGELOG"
rm -f "${fragments[@]}"
rmdir changelog.d 2>/dev/null
printf '%s\n' "$new"
