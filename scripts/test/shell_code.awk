# SHELL_CODE_AWK: the one rule of what counts as code in a shell file, an awk
# function library an awk scanner includes by concatenation (awk
# "$SHELL_CODE_AWK"'...'). Its interface is one function, shell_code_line(line),
# called once per input line: it sets sc_code, the line's code view - its
# comment dropped, strings, substitutions and heredoc bodies kept whole -
# sc_words, its words view - its comment dropped, every quoted string, ${...}
# and quoted heredoc body line collapsed to a q and a closing backtick to a
# space, the code inside $(...) within double quotes and unquoted heredocs
# still read, and a line continuing one that ends in \ prefixed with "q " -
# and sc_top, 1 when the line starts outside any open quote, substitution,
# arithmetic or heredoc. It tracks the quoting stack across lines (single quotes, $'...',
# double quotes, ${...}, $(...), backticks), line continuation and heredocs
# (quoted or not, <<-, several on one line), arithmetic, and resets at each
# file's first line. A heredoc's delimiter is read as bash reads it: one shell
# word after << or <<- and any blanks, a run of characters other than blanks
# and ; & | < > ( ), single-quoted spans, double-quoted spans and
# backslash-escaped characters; its terminator line is that word with its
# quotes and escaping backslashes removed, and a word with any quoting makes a
# quoted heredoc. A << inside arithmetic is a shift and opens no heredoc: the
# arithmetic frame is its own, apart from the $( frame, opened by $(( wherever
# $( is read as code, or by an unquoted adjacent ((, and closed by its
# matching )); $( ( and ( ( stay a substitution and a subshell, and let
# x=1<<n is still a heredoc. Every global and function it defines starts with
# sc_ or shell_code.
  function sc_push(m) { sc_sp++; sc_st[sc_sp] = m; sc_depth[sc_sp] = 0 }
  # sc_open_subst(line, i): opens the $(( or $( at column i, adds it to sc_out,
  # and returns the column of its last character.
  function sc_open_subst(line, i) {
    if (substr(line, i, 3) == "$((") { sc_push("A"); sc_out = sc_out "$(("; return i + 2 }
    sc_push("C"); sc_out = sc_out "$("; return i + 1
  }
  # sc_scan(line): walks line from the state on sc_st[1..sc_sp], over the
  # code sc_st[0], building its words view in sc_out, and returns the column
  # its comment starts at, 0 for none. A heredoc opened on it is queued in
  # sc_hword[1..sc_nh]; a continuation backslash in code sets sc_cont and
  # leaves the character before it in sc_prev.
  function sc_scan(line,   i, n, c, c2, m, prev, w, j, k, q, dc) {
    n = length(line); prev = sc_prev; sc_prev = ""; sc_out = ""
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1); c2 = substr(line, i, 2); m = sc_st[sc_sp]
      if (m == "S") { if (c == "\047") { sc_sp--; sc_out = sc_out "q" } }
      else if (m == "E") { if (c == "\\") i++; else if (c == "\047") { sc_sp--; sc_out = sc_out "q" } }
      else if (m == "D" || m == "H" || m == "P") {
        if (c == "\\") i++
        else if (c2 == "$(") {
          i = sc_open_subst(line, i)
        }
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
        # code: the bottom N, a $(...) C, an arithmetic A, or a backtick B
        if (c == "\\") { if (i == n) { sc_prev = prev; sc_cont = 1 } else sc_out = sc_out "qq"; i++ }
        else if (c == "#" && (prev == "" || prev ~ /[ \t;&|()]/)) return i
        else if (c2 == "$\047") { sc_push("E"); i++ }
        else if (c == "\047") sc_push("S")
        else if (c == "\"") sc_push("D")
        else if (c2 == "$(") {
          i = sc_open_subst(line, i)
        }
        else if (c2 == "(("&& m != "A") { sc_push("A"); sc_out = sc_out "(("; i++ }
        else if (c2 == "${") { sc_push("P"); i++ }
        else if (c == "`") { if (m == "B") { sc_sp--; sc_out = sc_out " " } else { sc_push("B"); sc_out = sc_out "`" } }
        else if (m == "A" && c == "(") { sc_depth[sc_sp]++; sc_out = sc_out c }
        else if (m == "A" && c == ")") {
          if (sc_depth[sc_sp]) { sc_depth[sc_sp]--; sc_out = sc_out c }
          else if (substr(line, i, 2) == "))") { sc_sp--; sc_out = sc_out "))"; i++ }
          else { sc_sp--; sc_out = sc_out c }
        }
        else if (m == "C" && c == "(") { sc_depth[sc_sp]++; sc_out = sc_out c }
        else if (m == "C" && c == ")") { if (sc_depth[sc_sp]) sc_depth[sc_sp]--; else sc_sp--; sc_out = sc_out c }
        else if (substr(line, i, 3) == "<<<") { sc_out = sc_out "<<<"; i += 2 }
        else if (c2 == "<<" && m != "A") {
          # a heredoc: its delimiter word, and whether it is quoted
          j = i + 2; sc_hstrip[sc_nh + 1] = 0
          if (substr(line, j, 1) == "-") { sc_hstrip[sc_nh + 1] = 1; j++ }
          while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") j++
          w = ""; q = 0; k = j
          while (k <= n) {
            dc = substr(line, k, 1)
            if (dc == "\047") { q = 1; k++; while (k <= n && substr(line, k, 1) != "\047") w = w substr(line, k++, 1) }
            else if (dc == "\"") {
              q = 1; k++
              while (k <= n && substr(line, k, 1) != "\"") {
                if (substr(line, k, 1) == "\\" && index("\\$`\"", substr(line, k + 1, 1))) k++
                w = w substr(line, k++, 1)
              }
            }
            else if (dc == "\\") { q = 1; k++; w = w substr(line, k, 1) }
            else if (index(" \t;&|<>()", dc)) break
            else w = w dc
            k++
          }
          if (k > j) {
            sc_nh++; sc_hword[sc_nh] = w; sc_hquoted[sc_nh] = q
            i = k - 1
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
