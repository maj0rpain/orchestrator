# shellcheck shell=bash
# glossary.sh - orch.sh's glossary command: the root GLOSSARY.md, read an
# entry at a time.
# Its tests: scripts/test/orch/glossary.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# A reader needs only the entries for the terms in front of it, not the whole
# glossary, so the entry grammar lives here, tested, rather than re-derived in
# each skill. An entry starts at a line that is exactly **<Term>**: and runs up
# to the next such line, the next line starting with #, or end of file, its
# trailing blank lines trimmed. Every op reads GLOSSARY.md at the repo root
# only; exit 2 is an error, so show keeps exit 1 for "no entry for a term".
cmd_glossary() {
  local op="${1:-}"
  shift || true
  local glossary="$ROOT/GLOSSARY.md"
  case "$op" in
    terms)
      [ $# -eq 0 ] || die2 "usage: orch.sh glossary terms"
      [ -f "$glossary" ] || return 0
      glossary_run terms "$glossary" ;;
    show)
      [ $# -ge 1 ] || die2 "usage: orch.sh glossary show <term>..."
      [ -f "$glossary" ] || die2 "no GLOSSARY.md at $ROOT"
      local missing st=0 term
      missing="$(mktemp)"
      GLOSSARY_MISSING="$missing" glossary_run show "$glossary" "$@" || st=$?
      while IFS= read -r term; do
        warn "no glossary entry for '$term'"
      done < "$missing"
      rm -f "$missing"
      return "$st" ;;
    match)
      [ $# -ge 1 ] || die2 "usage: orch.sh glossary match <file>..."
      local file
      for file in "$@"; do
        [ -f "$file" ] && [ -r "$file" ] || die2 "no such file '$file'"
      done
      [ -f "$glossary" ] || return 0
      glossary_run match "$glossary" "$@" ;;
    *) die2 "unknown glossary op: ${op:-<none>} (want terms|show|match)" ;;
  esac
}

# glossary_run <mode> <glossary> [<arg>...]: the one awk pass that parses the
# glossary into entries and answers <mode>. Every file is read through getline
# in BEGIN, so an empty glossary or text file needs no special case. An
# entry's _Avoid_: line lists its aliases, split at commas outside
# parentheses, a trailing period dropped; an alias ends at its first (, and
# one with a parenthetical note is scoped. show writes each term with no entry
# to the file GLOSSARY_MISSING names, one per line, for cmd_glossary to warn.
glossary_run() {
  awk '
    function blank(s) { return s ~ /^[[:space:]]*$/ }
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function add_alias(piece,   p, scoped) {
      p = index(piece, "(")
      scoped = p > 0
      if (scoped) piece = substr(piece, 1, p - 1)
      piece = trim(piece)
      if (piece == "") return
      na[n]++; alias[n, na[n]] = piece; ascoped[n, na[n]] = scoped
    }
    function read_aliases(s,   i, c, depth, piece) {
      s = trim(substr(s, 9)); sub(/\.$/, "", s)
      depth = 0; piece = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "(") depth++
        else if (c == ")" && depth > 0) depth--
        if (c == "," && depth == 0) { add_alias(piece); piece = "" }
        else piece = piece c
      }
      add_alias(piece)
    }
    function emit(i,   k) {
      if (printed++) print ""
      for (k = 1; k <= len[i]; k++) print line[i, k]
    }
    function find(want,   i, k) {
      want = tolower(want)
      for (i = 1; i <= n; i++) if (tolower(term[i]) == want) return i
      for (i = 1; i <= n; i++)
        for (k = 1; k <= na[i]; k++)
          if (tolower(alias[i, k]) == want) { print "# alias of " term[i] > "/dev/stderr"; return i }
      return 0
    }
    function squash(s) { s = tolower(s); gsub(/[[:space:]]+/, " ", s); return s }
    # Whether the squashed text mentions the squashed word: an occurrence
    # not preceded by a word character, whatever follows it.
    function mentions(text, word,   from, p) {
      if (word == "") return 0
      from = 1
      while ((p = index(substr(text, from), word)) > 0) {
        p += from - 1
        if (p == 1 || substr(text, p - 1, 1) !~ /[[:alnum:]_]/) return 1
        from = p + 1
      }
      return 0
    }
    function close_entry() {
      if (!n) return
      while (len[n] > 0 && blank(line[n, len[n]])) len[n]--
    }
    BEGIN {
      mode = ARGV[1]; gfile = ARGV[2]
      nargs = 0
      for (i = 3; i < ARGC; i++) arg[++nargs] = ARGV[i]
      ARGC = 1
      n = 0; inentry = 0
      while ((getline l < gfile) > 0) {
        if (l ~ /^\*\*[^*]+\*\*:$/) {
          close_entry()
          n++; inentry = 1
          term[n] = substr(l, 3, length(l) - 5)
          len[n] = 1; line[n, 1] = l; na[n] = 0
          continue
        }
        if (l ~ /^#/) { close_entry(); inentry = 0; continue }
        if (!inentry) continue
        len[n]++; line[n, len[n]] = l
        if (l ~ /^_Avoid_:/) read_aliases(l)
      }
      close(gfile)
      close_entry()
      if (mode == "terms") for (i = 1; i <= n; i++) print term[i]
      if (mode == "show") {
        status = 0
        for (a = 1; a <= nargs; a++) {
          i = find(arg[a])
          if (!i) { print arg[a] > ENVIRON["GLOSSARY_MISSING"]; status = 1; continue }
          if (!(i in shown)) { shown[i] = 1; emit(i) }
        }
        exit status
      }
      if (mode == "match") {
        text = ""
        for (a = 1; a <= nargs; a++) {
          while ((getline l < arg[a]) > 0) text = text " " l
          close(arg[a])
        }
        text = squash(text)
        for (i = 1; i <= n; i++) {
          hit = mentions(text, squash(term[i]))
          for (k = 1; !hit && k <= na[i]; k++)
            if (!ascoped[i, k]) hit = mentions(text, squash(alias[i, k]))
          if (hit) emit(i)
        }
      }
    }' "$@"
}
