# The in-memory half of the ORCH_GH_ADAPTER seam.
#
# Sourced into orch.sh's own process via ORCH_GH_ADAPTER, this redefines the
# adapter functions orch.sh calls instead of shelling out to `gh` - so a test
# exercises orch.sh's decision logic without spawning a subprocess for every
# GitHub call. Parameterized by the same GH_STUB_* vocabulary orch_test.sh's
# subprocess fake (`stub_gh`) already answers to, so a test switches between
# the two fakes without learning a second vocabulary, and an assertion written
# against one reads the other's output too.
#
# Label creation was the first primitive covered - the narrowest slice that
# proved the seam works end to end (issue #91, first of the #78 breakdown).
# The issue-resource primitives below (view/edit/comment/create/close, issue
# #92) extend it the same way: each addition keeps mirroring whatever
# GH_STUB_* variable already drives that call's subprocess behaviour in
# stub_gh, rather than inventing a parallel vocabulary.
#
# adapter_label_create - mirrors stub_gh's `label create` branch:
#   GH_STUB_MODE=labelfail   fails the call, like a `gh` that cannot create it
#   GH_STUB_FILED            when set, appended with "label create <args...>",
#                             the same line shape stub_gh writes, so an
#                             assertion against GH_STUB_FILED does not care
#                             which fake produced it
adapter_label_create() {
  if [ "${GH_STUB_MODE:-ok}" = labelfail ]; then return 1; fi
  if [ -n "${GH_STUB_FILED:-}" ]; then printf 'label create %s\n' "$*" >>"$GH_STUB_FILED"; fi
  return 0
}

# Shared by every issue-write primitive below - mirrors stub_gh's own
# record_flags: title/label/body-file/comment flags are appended to
# GH_STUB_FILED with the body-file's contents inlined, everything else as a
# bare flag=value line, so an assertion reads either fake's GH_STUB_FILED the
# same way.
fake_record_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)     printf 'title=%s\n' "$2" >>"$GH_STUB_FILED"; shift ;;
      --label)     printf 'label=%s\n' "$2" >>"$GH_STUB_FILED"; shift ;;
      --body-file) { printf 'body:\n'; cat "$2"; } >>"$GH_STUB_FILED"; shift ;;
      --comment)   { printf 'comment:\n%s\n' "$2"; } >>"$GH_STUB_FILED"; shift ;;
      *)           printf 'flag=%s\n' "$1" >>"$GH_STUB_FILED" ;;
    esac
    shift
  done
}

# adapter_issue_view - mirrors stub_gh's `issue view` branch: logs "issue view
# <args...>" to GH_STUB_FILED when set, fails on GH_STUB_VIEW_EXIT, answers
# GH_STUB_ISSUE_STATE/GH_STUB_ISSUE_LABELS when asked for those fields, and
# GH_STUB_BODY (default "Body of the issue.") otherwise - the same three
# answers stub_gh gives, so cmd_spec fetch reads either fake identically.
adapter_issue_view() {
  if [ -n "${GH_STUB_FILED:-}" ]; then printf 'issue view %s\n' "$*" >>"$GH_STUB_FILED"; fi
  if [ "${GH_STUB_VIEW_EXIT:-0}" != 0 ]; then
    echo "gh stub: issue view refused" >&2
    return "$GH_STUB_VIEW_EXIT"
  fi
  local a
  for a in "$@"; do
    case "$a" in
      state)  printf '%s\n' "${GH_STUB_ISSUE_STATE:-OPEN}"; return 0 ;;
      labels) printf '%s\n' "${GH_STUB_ISSUE_LABELS-ready-for-agent}"; return 0 ;;
    esac
  done
  printf '%s\n' "${GH_STUB_BODY-Body of the issue.}"
  return 0
}

# adapter_issue_edit / adapter_issue_comment - mirror stub_gh's `issue
# edit`/`issue comment` branch: logs "issue <op> <n>" plus the flags
# (fake_record_flags) to GH_STUB_FILED when set, and fails on
# GH_STUB_EDIT_EXIT/GH_STUB_COMMENT_EXIT respectively.
fake_issue_write() {
  local op="$1" n st
  shift
  n="$1"
  if [ -n "${GH_STUB_FILED:-}" ]; then
    printf 'issue %s %s\n' "$op" "$n" >>"$GH_STUB_FILED"
    shift
    fake_record_flags "$@"
  fi
  if [ "$op" = edit ]; then st="${GH_STUB_EDIT_EXIT:-0}"; else st="${GH_STUB_COMMENT_EXIT:-0}"; fi
  if [ "$st" != 0 ]; then
    echo "gh stub: issue $op refused" >&2
    return "$st"
  fi
  return 0
}
adapter_issue_edit()    { fake_issue_write edit "$@"; }
adapter_issue_comment() { fake_issue_write comment "$@"; }

# adapter_issue_create - mirrors stub_gh's `issue create` branch: records the
# flags (fake_record_flags) to GH_STUB_FILED when set, fails on
# GH_STUB_ISSUE_EXIT, otherwise answers a fake issue URL numbered
# GH_STUB_ISSUE_NUMBER (default 42) - the same shape review-file/issue-publish
# already parse the trailing number out of.
adapter_issue_create() {
  if [ -n "${GH_STUB_FILED:-}" ]; then fake_record_flags "$@"; fi
  if [ "${GH_STUB_ISSUE_EXIT:-0}" != 0 ]; then
    echo "gh stub: issue create refused" >&2
    return "$GH_STUB_ISSUE_EXIT"
  fi
  printf 'https://github.com/acme/widgets/issues/%s\n' "${GH_STUB_ISSUE_NUMBER:-42}"
  return 0
}

# adapter_issue_close - mirrors stub_gh's `issue close` branch: logs "issue
# close <n>" plus the flags (fake_record_flags, so a --comment reaches
# GH_STUB_FILED the same way pr close's does) to GH_STUB_FILED when set, and
# fails on GH_STUB_ISSUE_CLOSE_EXIT.
adapter_issue_close() {
  local n="$1"
  if [ -n "${GH_STUB_FILED:-}" ]; then
    printf 'issue close %s\n' "$n" >>"$GH_STUB_FILED"
    shift
    fake_record_flags "$@"
  fi
  if [ "${GH_STUB_ISSUE_CLOSE_EXIT:-0}" != 0 ]; then
    echo "gh stub: issue close refused" >&2
    return "$GH_STUB_ISSUE_CLOSE_EXIT"
  fi
  return 0
}
