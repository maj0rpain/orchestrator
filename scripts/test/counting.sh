#!/usr/bin/env bash
#
# Sourced by orch_test.sh (the orch.sh suite's runner), hooks_test.sh and
# docs_lint.sh: the counting fixture, a stub (in a directory its caller puts
# first on PATH) that logs one line each time a command starts
# (counting_argv_bin: each start whose arguments match) and then runs the real
# command.
# Sourcing it only defines functions.
# Bash 4.2+, as the rest of the suite.

# counting_bin <cmd>: a new directory holding a #!/bin/sh <cmd> that appends one
# line per start to <dir>/<cmd>.log (created empty; callers truncate it), then
# execs the real <cmd> found now. Prints the dir.
counting_bin() {
  local dir
  dir="$(mktemp -d)"
  printf '#!/bin/sh\necho x >>"%s/%s.log"\nexec "%s" "$@"\n' "$dir" "$1" "$(command -v "$1")" >"$dir/$1"
  chmod +x "$dir/$1"
  : >"$dir/$1.log"
  printf '%s\n' "$dir"
}

# counting_starts <dir> <cmd>: how many times the <cmd> in <dir> has started.
counting_starts() { wc -l <"$1/$2.log" | tr -d ' '; }

# counting_argv_bin <cmd> <args>: like counting_bin, but a start is logged only
# when its arguments, joined by spaces, equal <args>. Prints the dir.
counting_argv_bin() {
  local dir
  dir="$(counting_bin "$1")"
  printf '#!/bin/sh\n[ "$*" = "%s" ] && echo x >>"%s/%s.log"\nexec "%s" "$@"\n' "$2" "$dir" "$1" "$(command -v "$1")" >"$dir/$1"
  printf '%s\n' "$dir"
}

# counting_stdin_bin <cmd>: like counting_bin, and each start also appends one
# line to <dir>/<cmd>.bytes: the bytes the <cmd> was offered on standard input.
# Its stdin passes through tee into a file, so a command that stops reading
# early shows the read-ahead it was offered, not the whole input. The caller
# gives the wrapped command a stdin that ends (a pipe or </dev/null). Prints
# the dir.
# The count relies on SIGPIPE killing tee when the command stops reading. A
# tee that inherited SIGPIPE ignored gets EPIPE instead and copies the rest of
# its input into the file, so the count becomes the whole input. When
# `env --default-signal=PIPE` is supported (GNU coreutils 8.31+, uutils), the
# wrapper starts tee under it and the count is exact whatever disposition the
# wrapper inherited; this is checked once, when the wrapper is built. Where it
# is not (macOS's BSD env, older coreutils), the wrapper uses plain tee and the
# count is exact only where SIGPIPE is at its default.
counting_stdin_bin() {
  local dir tee_cmd=tee
  dir="$(counting_bin "$1")"
  if env --default-signal=PIPE true 2>/dev/null; then tee_cmd="env --default-signal=PIPE tee"; fi
  cat >"$dir/$1" <<STUB
#!/usr/bin/env bash
echo x >>"$dir/$1.log"
f="\$(mktemp)"
$tee_cmd "\$f" | "$(command -v "$1")" "\$@"
st=\${PIPESTATUS[1]}
wc -c <"\$f" | tr -d ' ' >>"$dir/$1.bytes"
rm -f "\$f"
exit "\$st"
STUB
  : >"$dir/$1.bytes"
  printf '%s\n' "$dir"
}

# counting_bytes <dir> <cmd>: the bytes all starts of the <cmd> in <dir> were
# offered on standard input, in all.
counting_bytes() { awk '{ s += $1 } END { print s + 0 }' "$1/$2.bytes"; }
