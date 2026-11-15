#!/usr/bin/env bash
#
# Sourced by orch_test.sh (the orch.sh suite's runner) and hooks_test.sh: the
# counting fixture, a stub (in a directory its caller puts first on PATH) that
# logs one line each time a command starts and then runs the real command.
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

# counting_stdin_bin <cmd>: like counting_bin, and each start also appends one
# line to <dir>/<cmd>.bytes: the bytes the <cmd> was offered on standard input.
# Its stdin passes through tee into a file, so a command that stops reading
# early shows the read-ahead it was offered, not the whole input. The caller
# gives the wrapped command a stdin that ends (a pipe or </dev/null). Prints
# the dir.
counting_stdin_bin() {
  local dir
  dir="$(mktemp -d)"
  cat >"$dir/$1" <<STUB
#!/usr/bin/env bash
echo x >>"$dir/$1.log"
f="\$(mktemp)"
tee "\$f" | "$(command -v "$1")" "\$@"
st=\${PIPESTATUS[1]}
wc -c <"\$f" | tr -d ' ' >>"$dir/$1.bytes"
rm -f "\$f"
exit "\$st"
STUB
  chmod +x "$dir/$1"
  : >"$dir/$1.log"; : >"$dir/$1.bytes"
  printf '%s\n' "$dir"
}

# counting_bytes <dir> <cmd>: the bytes all starts of the <cmd> in <dir> were
# offered on standard input, in all.
counting_bytes() { awk '{ s += $1 } END { print s + 0 }' "$1/$2.bytes"; }
