# SHELL_CODE_AWK: the one rule of what counts as code in a shell file, an awk
# function library an awk scanner includes by concatenation (awk
# "$SHELL_CODE_AWK"'...'). Its interface is one function, shell_code_line(line),
# called once per input line: it sets sc_code, the line's code view - its
# comment dropped, strings, substitutions and heredoc bodies kept whole -
# sc_words, its words view - its comment dropped, every quoted string, ${...}
# and quoted heredoc body line collapsed to a q and a closing backtick to a
# space, the code inside $(...) within double quotes and unquoted heredocs
# still read, and a line continuing one that ends in \ prefixed with "q " -
# and sc_top, 1 when the line starts outside any open quote, substitution or
# heredoc. It tracks the quoting stack across lines (single quotes, $'...',
# double quotes, ${...}, $(...), backticks), line continuation and heredocs
# (quoted or not, <<-, several on one line), and resets at each file's first
# line. Every global and function it defines starts with sc_ or shell_code.
  function sc_push(m) { sc_sp++; sc_st[sc_sp] = m; sc_depth[sc_sp] = 0 }
  # sc_scan(line): walks line from the state on sc_st[1..sc_sp], over the
  # code sc_st[0], building its words view in sc_out, and returns the column
  # its comment starts at, 0 for none. A heredoc opened on it is queued in
  # sc_hword[1..sc_nh]; a continuation backslash in code sets sc_cont and
  # leaves the character before it in sc_prev.
  function sc_scan(line,   i, n, c, c2, m, prev, w, j) {
    n = length(line); prev = sc_prev; sc_prev = ""; sc_out = ""
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1); c2 = substr(line, i, 2); m = sc_st[sc_sp]
      if (m == "S") { if (c == "\047") { sc_sp--; sc_out = sc_out "q" } }
      else if (m == "E") { if (c == "\\") i++; else if (c == "\047") { sc_sp--; sc_out = sc_out "q" } }
      else if (m == "D" || m == "H" || m == "P") {
        if (c == "\\") i++
        else if (c2 == "$(") { sc_push("C"); sc_out = sc_out "$("; i++ }
        else if (c2 == "${") { sc_push("P"); i++ }
        else if (c == "`") { sc_push("B"); sc_out = sc_out "`" }
        else if (m == "D" && c == "\"") { sc_sp--; sc_out = sc_out "q" }
        else if (m == "P" && c == "\"") sc_push("D")
        else if (m == "P" && c == "\047" && sc_st[sc_sp - 1] != "D") sc_push("S")
        else if (m == "P" && c == "{") sc_depth[sc_sp]++
        else if (m == "P" && c == "}") {
          if (sc_depth[sc_sp]) sc_depth[sc_sp]--
          else { sc_sp--; if (sc_st[sc_sp] != "D" && sc_st[sc_sp] != "H") sc_out = sc_out "q" }
        }
      }
      else {
        # code: the bottom N, a $(...) C, or a backtick B
        if (c == "\\") { if (i == n) { sc_prev = prev; sc_cont = 1 } else sc_out = sc_out "qq"; i++ }
        else if (c == "#" && (prev == "" || prev ~ /[ \t;&|()]/)) return i
        else if (c2 == "$\047") { sc_push("E"); i++ }
        else if (c == "\047") sc_push("S")
        else if (c == "\"") sc_push("D")
        else if (c2 == "$(") { sc_push("C"); sc_out = sc_out "$("; i++ }
        else if (c2 == "${") { sc_push("P"); i++ }
        else if (c == "`") { if (m == "B") { sc_sp--; sc_out = sc_out " " } else { sc_push("B"); sc_out = sc_out "`" } }
        else if (m == "C" && c == "(") { sc_depth[sc_sp]++; sc_out = sc_out c }
        else if (m == "C" && c == ")") { if (sc_depth[sc_sp]) sc_depth[sc_sp]--; else sc_sp--; sc_out = sc_out c }
        else if (substr(line, i, 3) == "<<<") { sc_out = sc_out "<<<"; i += 2 }
        else if (c2 == "<<") {
          # a heredoc: its delimiter, and whether it is quoted
          j = i + 2; w = substr(line, j); sc_hstrip[sc_nh + 1] = 0
          if (substr(w, 1, 1) == "-") { sc_hstrip[sc_nh + 1] = 1; w = substr(w, 2); j++ }
          match(w, /^[ \t]*/); j += RLENGTH; w = substr(w, RLENGTH + 1)
          if (match(w, /^(\047[^\047]*\047|"[^"]*"|\\[A-Za-z0-9_]+|[A-Za-z0-9_]+)/)) {
            sc_nh++; sc_hword[sc_nh] = substr(w, 1, RLENGTH); sc_hquoted[sc_nh] = 1
            if (sc_hword[sc_nh] ~ /^[\047"]/) sc_hword[sc_nh] = substr(sc_hword[sc_nh], 2, RLENGTH - 2)
            else if (sc_hword[sc_nh] ~ /^\\/) sc_hword[sc_nh] = substr(sc_hword[sc_nh], 2)
            else sc_hquoted[sc_nh] = 0
            i = j + RLENGTH - 1
          } else i++
          sc_out = sc_out "q"
        }
        else sc_out = sc_out c
      }
      prev = c
    }
    return 0
  }
  function shell_code_line(line,   t, base, cut, lead) {
    if (FNR == 1) { sc_sp = 0; sc_st[0] = "N"; sc_nh = 0; sc_hcur = 0; sc_prev = ""; sc_cont = 0 }
    if (sc_hcur) {
      # a heredoc body line, or its terminator: code whole either way, and a
      # q in the words view unless an unquoted body line
      sc_code = line; sc_words = "q"; sc_top = 0
      t = line; if (sc_hstrip[sc_hcur]) sub(/^\t+/, "", t)
      if (t == sc_hword[sc_hcur]) { sc_hcur = sc_hcur < sc_nh ? sc_hcur + 1 : 0; if (!sc_hcur) sc_nh = 0; return }
      if (!sc_hquoted[sc_hcur]) {
        base = sc_sp; sc_push("H"); sc_scan(line); sc_sp = base; sc_prev = ""; sc_words = sc_out
      }
      return
    }
    sc_top = sc_sp == 0
    lead = sc_cont ? "q " : ""; sc_cont = 0
    cut = sc_scan(line)
    sc_code = cut ? substr(line, 1, cut - 1) : line
    sc_words = lead sc_out
    if (sc_nh && !sc_hcur) sc_hcur = 1
  }
