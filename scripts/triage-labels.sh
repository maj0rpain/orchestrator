# shellcheck shell=bash
# triage-labels.sh - the triage-label parser, sourced by orch.sh and by
# hook-grilling.sh.
#
# Reads this repo's triage-labels doc: the table mapping each canonical
# triage role to the repo's local label name. Needs only ROOT defined, so any
# script that needs the repo's triage labels can source it alone, without
# orch.sh's shared mechanism (#575). Its readers are orch.sh's init
# (validate_adopted_issue), doctor.sh's checks and hook-grilling.sh.
#
# LABELS_DOC is assigned plainly here, its one home: orch.sh sources this
# module and marks it readonly right after, and doctor.sh, sourced after
# orch.sh, does not source this module again - a second assignment of a
# readonly LABELS_DOC would fail.

LABELS_DOC="docs/agents/triage-labels.md"

# The one place that knows how to read a row out of the triage-label table:
# where it starts and ends, which rows belong to it, and how to clean a cell
# once split out. Emits "role<TAB>name" for every valid data row - the left
# column (the canonical triage role name) and the right column (this repo's
# local label for it) - so triage_labels and triage_label_for always agree on
# what the table contains, including correctly ignoring any other table
# elsewhere in the doc (#39).
triage_table_rows() {
  [ -f "$ROOT/$LABELS_DOC" ] || return 0
  awk -F'|' '
    # One cleanup for any cell pulled out of a split row: restore pipes
    # masked below, strip backticks, trim the pad markdown tables pad cells
    # with - shared so l and r can never drift into cleaning a cell two
    # different ways.
    function clean(s) {
      gsub(/\001/, "|", s)
      gsub(/`/, "", s)
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    # A table ends where the pipes stop. Without this, cols still holds the
    # previous table width when the next table begins - a header row arrives a
    # line before the separator that would correct it - so a narrower second
    # table anywhere in the doc leaks its heading out as a label name.
    !/^[[:space:]]*\|/ { cols = 0 }
    /^[[:space:]]*\|/ {
      # `\|` is the markdown escape for a literal pipe, never a column
      # separator. Mask it before the field split and restore it after, or an
      # escaped cell shifts every column after it for that row (#5).
      line = $0
      gsub(/\\\|/, "\001", line)
      $0 = line
      l = clean($2)
      r = clean($3)
      # The separator row settles the width for the whole table, and only it
      # can. Every separator cell holds a dash run, so an empty field at the
      # end of that row is unambiguously the one a trailing pipe leaves behind
      # - whereas on a data row an empty last field is equally well an empty
      # last cell, and guessing there costs a real label. Markdown lets a row
      # drop its trailing pipe; the leading one the match already requires.
      if (r ~ /^:?-+:?$/) {
        last = $NF
        sub(/^[[:space:]]+/, "", last)
        sub(/[[:space:]]+$/, "", last)
        cols = NF - 1
        if (last == "") cols--
        next
      }
      # cols stays 0 until the separator row, which drops the header with it.
      # Under three columns this is a table of some other shape, where $3 is
      # whichever column happens to sit last and its Meaning text would be read
      # out as a label name and demanded of the repo. A diagnostic may fail to
      # parse a doc; it may not invent an answer from one.
      if (cols < 3) next
      print l "\t" r
    }' "$ROOT/$LABELS_DOC"
}

# Parsed, never hardcoded. That file documents its right-hand column as editable,
# so a hardcoded list of the five canonical names would make doctor confidently
# wrong in exactly the repos that customised themselves - the worst thing a
# diagnostic can be. A thin filter over triage_table_rows: every row's local
# label name, skipping rows that left it blank.
triage_labels() {
  triage_table_rows | awk -F'\t' '$2 != "" { print $2 }'
}

# The local name for one of the five triage roles - the right-hand column of
# the row whose left-hand column names it. A repo that customised its
# vocabulary customised this, and filing under the canonical name there would
# create a second label the repo's triage never reads. The role name itself is
# the answer where the doc is missing or does not list it. Also a thin filter
# over triage_table_rows, so it shares triage_labels' table-boundary and
# column-count guard rather than risking a second table elsewhere in the doc.
triage_label_for() {
  local role="$1" name=""
  name="$(triage_table_rows | awk -F'\t' -v role="$role" '
    $1 == role && $2 != "" { print $2; exit }')"
  printf '%s\n' "${name:-$role}"
}

# The five canonical triage roles, each also the label name a repo with no
# labels doc uses (ADR-0028: setup is optional).
TRIAGE_ROLES="needs-triage needs-info ready-for-agent ready-for-human wontfix"

# The label names this repo is expected to carry, one per line: the doc's when
# it is present, the canonical names when it is not. A present doc that parses
# to nothing yields nothing - check_labels_doc reports that one.
triage_expected_labels() {
  if [ -f "$ROOT/$LABELS_DOC" ]; then triage_labels; return 0; fi
  printf '%s\n' $TRIAGE_ROLES
}
