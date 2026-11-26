"""The spec concept's module: the spec noun (ADR-0067; the bash spec module
went at its cutover), and the round directory the spec-review noun works in -
the files saying where a spec review round stands, the working-directory
reset, what a round hands the next, and the round count's parse.

The noun is the spec review's one hand on GitHub. The body is the truth the
implement phase reads, so the four ways it is read and written - fetch,
update, comment and comments - go through here, where they are tested,
rather than through a `gh issue edit` in skill prose: each resolves the
number from the flow's state and runs the issue noun's op on it in-process.
A done flow's issue is finished work: state.json lingers after the flow
ends, so a spec op there would quietly touch an issue nobody is reviewing any
more - it refuses and points at the stateless issue ops. pause touches no
issue: it writes the spec-paused marker, the stop of the spec phase's session
once the spec is written. pause --round writes the round marker, the stop
after a spec review round, and in an autopilot flow releases the claim
through the Standing module's chain. Every verb keeps the bash module's
arguments, usage lines, stdout, exit codes, `orch:` messages and check order,
and refuses before any write. round-dir prepares a flow's round directory and
writes the round marker last; round reads the marker back for a resumed spec
phase.

The two markers sit in the handoff folder, and neither is a handoff - no
phase table entry names it, so handoff validate and doctor never look at it -
nor a state.json field (ADR-0005). The redo noun's redo spec (orch/redo.py)
moves both aside with the stale handoffs, by the names kept here.

This module owns the round directory: its spec_round_* functions keep the
bash names they had and bash's messages and the order of its local steps.
The golden round directories of tests/spec_round/ hold each state's files,
read by pytest alone since no bash reader of the round directory is left. The
golden line bash wrote before its saved-answer writer went,
tests/spec_round/answer/bash-written, is the bash side of the saved-answer
format, which a round that died under bash still resumes by.

The saved answer (apply-answer) is one shell-quoted line, as bash's `printf
%q` writes it: spec_round_answer_save writes each word with shlex.quote, and
spec_round_answer_load reads it with shlex.split. That reads every line bash
writes but one holding control characters, which %q writes as $'...' and
shlex.split would read as a literal $ and the quoted text: such a line is
refused, as unreadable.
"""
from __future__ import annotations

import glob
import os
import shlex
from typing import List, Mapping, Optional, Sequence, Tuple

from orch.autopilot import autopilot_active
from orch.common import (ORCH_DIR_NAME, copy_or_die, die, mkdir_p_or_die, plain_number,
                         plain_positive_number, read_raw, read_words, rm_f_or_die,
                         rm_rf_or_die, text_file_append, text_file_write)
from orch.flow_state import flow_state_file, require_state_read, require_value
from orch.gh import adapter_of
from orch.git import Git
from orch.handoff import handoff_dir
from orch.host import print_next_block
from orch.root import checkout_root

# The verbs, in the unknown-op message's order. docs_lint.sh reads this line
# as the verbs the noun dispatches, so it stays one `OPS = "<verb>|..."` line.
OPS = "fetch|update|comment|comments|pause|round|round-dir"
# The verbs that read or write the flow's issue through the issue noun.
ISSUE_OPS = ("fetch", "update", "comment", "comments")

# The marker a spec phase leaves when it stops its session once the spec is
# written (#1181), holding the issue number: the fresh session's spec phase
# reads it and goes straight to the spec review. A file in the handoff folder
# but not a handoff - no phase table entry names it, so handoff validate and
# doctor never look at it - and no state.json field (ADR-0005). redo spec
# moves it aside with the stale handoffs.
SPEC_PAUSED_MARKER = "spec-paused"
# The round marker (#1346): the file a flow's spec review leaves in the
# handoff folder naming the flow's issue, a round k and the round count n, as
# one line `<issue> <k> <n>` - a format spec round alone reads. Like
# spec-paused it is no handoff and no state.json field.
SPEC_ROUND_MARKER = "spec-round"

# The empty file spec_round_complete writes in a round's directory, as its
# last local step but the answer's clearing: a round counts as complete only
# when its directory holds it.
ROUND_COMPLETE = "round-complete"
# The held-back fundamental items of an autopilot round, written by
# spec_round_hold (spec_round_complete removes it): while it exists the round
# waits for the human's answer.
ROUND_FUNDAMENTAL = "fundamental.md"
# The saved answer of an apply that is running or died in the round's
# directory, written by spec_round_answer_save and cleared by
# spec_round_answer_clear: while it exists the round is applying.
ROUND_APPLY_ANSWER = "apply-answer"
# The file every round's changelog is appended to, read by the next round's
# lenses.
ROUND_SETTLED = "settled.md"
# What a round hands the next: the Implementability lens's code map and the
# settled file, kept by spec_round_dir_reset's carry.
ROUND_CARRIED = ("map-implementability.md", ROUND_SETTLED)
# The file round 1 of a flow's spec review writes its `agent get lens` read
# to, in its round directory: every later round, in a session of its own,
# starts its lenses on these values rather than reading the setting again, so
# the whole review runs on one lens setting (#1353). A flow's round-dir
# carries it; a standalone review reads the lens setting once, in one
# session.
ROUND_LENS_SETTING = "agent-lens"


def spec_rounds_dir(root: str) -> str:
    """The flow's rounds directory of the checkout at <root>: where a flow's
    spec review rounds work, one directory per round number, under the
    orchestrator directory. Not under spec-review/, the flow-less entry
    archive keeps: these belong to the flow and are archived with it. Built
    as one "%s/%s/<name>" format naming ORCH_DIR_NAME, the form the
    side-checkout entry classification scans for."""
    return "%s/%s/spec-rounds" % (root, ORCH_DIR_NAME)


def spec_round_state(directory: str) -> str:
    """The round's state: `applying` while <directory> holds the saved apply
    answer, else `waiting` while it holds fundamental.md, else `open` while it
    holds no round-complete, else `complete`. A missing <directory> is
    open."""
    if os.path.exists(os.path.join(directory, ROUND_APPLY_ANSWER)):
        return "applying"
    if os.path.exists(os.path.join(directory, ROUND_FUNDAMENTAL)):
        return "waiting"
    if not os.path.exists(os.path.join(directory, ROUND_COMPLETE)):
        return "open"
    return "complete"


def spec_round_held(directory: str) -> bool:
    """Whether <directory> holds fundamental.md, the items an autopilot round
    held back - apart from the state, as a resumed apply of a held round is
    `applying` and held at once."""
    return os.path.exists(os.path.join(directory, ROUND_FUNDAMENTAL))


def spec_round_answer_name() -> str:
    """The saved answer's file name, for a caller's message that names it."""
    return ROUND_APPLY_ANSWER


def spec_round_answer_save(
        directory: str, file_options: Sequence[str], args: Sequence[str]) -> None:
    """apply's answer arguments <args> saved to <directory>/apply-answer, one
    shell-quoted line, before the first GitHub write. The argument after each
    of <file_options> is a file, copied into <directory> as
    apply-<option>.copy first and saved as the copy, so a resume never reads a
    file the dead session left elsewhere."""
    saved = []
    file_option = ""
    for arg in args:
        if file_option:
            copy = "%s/apply-%s.copy" % (directory, file_option[2:] if file_option.startswith("--")
                                         else file_option)
            copy_or_die(arg, copy,
                        "could not copy %s to %s - nothing written to GitHub" % (arg, copy))
            saved.append(copy)
            file_option = ""
            continue
        saved.append(arg)
        if arg in file_options:
            file_option = arg
    line = "".join(shlex.quote(word) + " " for word in saved) + "\n"
    path = "%s/%s" % (directory, ROUND_APPLY_ANSWER)
    text_file_write(path, line, "could not write %s - nothing written to GitHub" % path)


def _ansi_c_quoted(line: str) -> bool:
    """Whether a word of <line> starts with an unquoted $' - the ANSI-C
    quoting bash's %q writes for a word holding control characters, and for
    nothing else, since it writes a literal $ as \\$."""
    quote = ""
    escaped = False
    word_start = True
    for i, char in enumerate(line):
        if escaped:
            escaped, word_start = False, False
            continue
        if quote == "'":
            if char == "'":
                quote = ""
            continue
        if quote == '"':
            if char == "\\":
                escaped = True
            elif char == '"':
                quote = ""
            continue
        if char in " \t\n":
            word_start = True
            continue
        if word_start and char == "$" and line[i + 1:i + 2] == "'":
            return True
        word_start = False
        if char == "\\":
            escaped = True
        elif char in "'\"":
            quote = char
    return False


def spec_round_answer_load(directory: str) -> List[str]:
    """The saved answer's arguments; dies when the file is unreadable, or
    holds a line shlex.split cannot read as bash would."""
    path = "%s/%s" % (directory, ROUND_APPLY_ANSWER)
    unreadable = "%s is unreadable - rerun the round" % path
    text = read_raw(path) if not os.path.isdir(path) else None
    if text is None or _ansi_c_quoted(text):
        die(unreadable)
    try:
        return shlex.split(text)
    except ValueError:
        die(unreadable)


def _remove(path: str) -> bool:
    """rm -f <path>: whether nothing is left there - true when there was
    nothing; a directory is left, as rm without -r leaves it."""
    if not os.path.lexists(path):
        return True
    if os.path.isdir(path) and not os.path.islink(path):
        return False
    try:
        os.remove(path)
    except OSError:
        return False
    return True


def spec_round_answer_clear(directory: str, landed: str) -> None:
    """The saved answer and its file copies removed, at the end of the run
    that no resume continues. <landed> names the GitHub writes that landed,
    for the message."""
    paths = [os.path.join(directory, ROUND_APPLY_ANSWER)]
    paths += sorted(glob.glob(os.path.join(glob.escape(directory), "apply-*.copy")))
    removed = [_remove(path) for path in paths]
    if not all(removed):
        die("could not remove %s/%s - every GitHub write landed: %s"
            % (directory, ROUND_APPLY_ANSWER, landed))


def spec_round_hold(directory: str, blocks: str) -> None:
    """The end of an autopilot round's first run - the held-back fundamental
    items' <blocks> written, byte for byte, to <directory>/fundamental.md: the
    round's save point, which the round's state reads as waiting."""
    path = "%s/%s" % (directory, ROUND_FUNDAMENTAL)
    text_file_write(path, blocks, "could not write %s - nothing written to GitHub" % path)


def _ends_with(path: str, log: str) -> bool:
    """Whether the file at <path> ends with <log> and a newline, as bash's
    `$(tail -c <n>)` compares it, its trailing newlines dropped; false when
    it cannot be read."""
    want = (log + "\n").encode("utf-8", "surrogateescape")
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return False
    return data[-len(want):].rstrip(b"\n") == log.encode("utf-8", "surrogateescape")


def spec_round_complete(directory: str, log: str, landed: str) -> None:
    """The round's local tail once its changelog comment landed, safe to run
    again: <log> appended to settled.md unless it already ends with it, then
    fundamental.md removed, round-complete written, the saved answer
    cleared. <landed> names the GitHub writes, for the messages."""
    settled = "%s/%s" % (directory, ROUND_SETTLED)
    if not os.path.isfile(settled) or not _ends_with(settled, log):
        text_file_append(settled, log, "could not append the changelog to %s - every GitHub"
                         " write landed: %s" % (settled, landed))
    appended = "every GitHub write landed and settled.md is appended: " + landed
    fundamental = "%s/%s" % (directory, ROUND_FUNDAMENTAL)
    rm_f_or_die(fundamental, "could not remove %s - %s" % (fundamental, appended))
    marker = "%s/%s" % (directory, ROUND_COMPLETE)
    text_file_write(marker, "", "could not write %s - %s" % (marker, appended))
    spec_round_answer_clear(directory, landed)


def spec_round_in_flow(directory: str, rounds: str) -> bool:
    """Whether <directory> is under the flow's rounds directory <rounds>, at
    any depth - a flow's round directory, not a standalone review's."""
    path = (directory[:-1] if directory.endswith("/") else directory) + "/"
    return path.startswith(rounds + "/") and len(path) > len(rounds) + 1


def spec_entries_rm_or_die(directory: str, kept: Sequence[str], unremoved: str) -> None:
    """Every entry of <directory> but the names in <kept> deleted, in name
    order; dies with <unremoved> when <directory> cannot be listed or an
    entry cannot be removed."""
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        die(unremoved)
    for name in names:
        if name not in kept:
            rm_rf_or_die(os.path.join(directory, name), unremoved)


def spec_round_dir_reset(directory: str, carry: bool = False) -> None:
    """A round's working directory made ready to run in: the reset a flow's
    `spec round-dir` and a standalone review's begin run, keeping bash
    spec_round_dir_reset's name and messages. With <carry>, every entry of
    an existing <directory> but the code map and the settled file is deleted
    in place, keeping what a round hands the next; without it <directory> is
    removed whole. Either way it is then created when missing. Dies naming
    the directory when it cannot, where bash's rm, find or mkdir gave its
    own error."""
    unreset = "could not reset the round directory %s" % directory
    if carry and os.path.isdir(directory):
        spec_entries_rm_or_die(directory, ROUND_CARRIED, unreset)
    else:
        rm_rf_or_die(directory, unreset)
    mkdir_p_or_die(directory, unreset)


def spec_round_count_parse(arg: str) -> Tuple[int, int]:
    """A round and the round count, `<k>/<n>`, two positive whole numbers
    with k no greater than n; dies otherwise."""
    want = ("want <k>/<n>, a round and the round count, two positive whole numbers, got: %s"
            % arg)
    if "/" not in arg:
        die(want)
    k, n = arg.split("/", 1)
    if not plain_positive_number(k) or not plain_positive_number(n):
        die(want)
    if int(k) > int(n):
        die("round %s is past the round count %s" % (k, n))
    return int(k), int(n)


# --- the noun -----------------------------------------------------------------


def spec_phase_guard(op: str, issue: str, phase: str, code: int) -> None:
    """The refusals every op that acts inside the spec phase shares once the
    caller holds the flow's <issue> and <phase> from its entry read - no
    recorded issue, a done flow, a phase other than spec - each dying with
    exit <code>; it reads nothing."""
    require_value("issue", issue, code)
    if phase == "done":
        die("the flow on issue #%s is done - spec %s acts only on an active flow" % (issue, op),
            code)
    if phase != "spec":
        die("spec %s runs only in the spec phase - the flow is at phase %s" % (op, phase), code)


def spec_marker_write(root: str, marker: str, line: str) -> None:
    """Creates the handoff folder of the checkout at <root> and writes <line>
    as the one line of the marker file <marker> in it - the one writer of the
    spec module's two markers; dies naming what it could not create or
    write."""
    directory = handoff_dir(root)
    mkdir_p_or_die(directory, "cannot create " + directory)
    path = "%s/%s" % (directory, marker)
    text_file_write(path, line + "\n", "cannot write " + path)


def issue_op(op: str, args: List[str], issue: str, phase: str, gh_of, git,
             env: Mapping[str, str]) -> int:
    """`spec <fetch|update|comment|comments> <file>`: `issue <op>` on the
    flow's recorded issue, run in-process, so the drift line and every issue
    message come from the code that prints them. A done flow's issue is
    finished work - state.json lingers after the flow ends - so the op refuses
    it and points at the stateless issue op."""
    if len(args) != 1:
        die("usage: orch.sh spec <fetch|update|comment|comments> <file>")
    require_value("issue", issue)
    if phase == "done":
        die("the flow on issue #%s is done - spec %s acts only on an active flow's issue;"
            " for another issue use orch.sh issue %s <n> <file>" % (issue, op, op))
    # Imported on call, so a spec-review run, which loads this module for the
    # round directory, never loads the issue noun.
    from orch.issue import Issue

    return getattr(Issue(gh_of(), git, env), op)([issue, args[0]])


PAUSE_USAGE = "usage: orch.sh spec pause [--round <k>/<n>]"


def pause(args: List[str], issue: str, phase: str, root: str, gh_of,
          env: Mapping[str, str]) -> int:
    """`spec pause`: stops the spec phase's session after the spec is
    written - writes the spec-paused marker, then prints the stop block with
    the host's Next line. The marker is written first, so a failed write
    prints no block; the phase is left at spec. With --round <k>/<n>, the
    stop after a spec review round instead: see pause_round."""
    if args[:1] == ["--round"]:
        return pause_round(args[1:], issue, phase, root, gh_of, env)
    if args:
        die(PAUSE_USAGE)
    spec_phase_guard("pause", issue, phase, 1)
    spec_marker_write(root, SPEC_PAUSED_MARKER, issue)
    print_next_block(env, "Spec #%s written. The spec review runs in a fresh session." % issue)
    return 0


def pause_round(args: List[str], issue: str, phase: str, root: str, gh_of,
                env: Mapping[str, str]) -> int:
    """`spec pause --round <k>/<n>` (#1347): the stop after round k of n,
    k < n, has applied its answer - writes the round marker naming the
    flow's issue, the next round k+1 and the count n, so the fresh session's
    spec round resumes there, then prints the stop block. The marker is
    written first, so a failed write prints no block. The last round never
    pauses: the ticket breakdown and the handoff follow it in the same
    session. In an autopilot flow the round's session ends here: the claim is
    released between the marker and the block (#1457), and the next tick
    starts the next round."""
    if len(args) != 1:
        die(PAUSE_USAGE)
    k, n = spec_round_count_parse(args[0])
    if k >= n:
        die("round %d is the last of %d - the last round never pauses; go on to the ticket"
            " breakdown" % (k, n))
    spec_phase_guard("pause", issue, phase, 1)
    spec_marker_write(root, SPEC_ROUND_MARKER, "%s %d %d" % (issue, k + 1, n))
    if autopilot_active(env):
        # Imported on call, as the issue noun is: a spec-review run never
        # loads the chain.
        from orch.standing import standing_pause

        standing_pause(gh_of(), issue, "wrote the round marker")
    print_next_block(env, "Spec review round %d of %d applied. Round %d runs in a fresh session."
                     % (k, n, k + 1))
    return 0


def spec_round_sweep(rounds: str, directory: str) -> None:
    """Round 1's sweep: every entry of the rounds directory <rounds> but
    round 1's <directory> deleted, so a redone review leaks nothing stale;
    dies naming <directory> when it cannot, as spec_round_dir_reset does,
    where bash's find gave its own error."""
    spec_entries_rm_or_die(rounds, ("1",),
                           "could not reset the round directory %s" % directory)


def spec_round_carry(rounds: str, k: int) -> None:
    """Copies into round <k>'s directory under <rounds> what round k-1 of a
    flow's review hands it - the lens setting, the code map and the settled
    file, each when it exists; dies naming the file when a copy fails. A
    copy, not a carry in place: every round keeps its own directory for the
    final session to read its changelog from."""
    previous = "%s/%d" % (rounds, k - 1)
    for name in (ROUND_LENS_SETTING,) + ROUND_CARRIED:
        source = "%s/%s" % (previous, name)
        if os.path.isfile(source):
            copy_or_die(source, "%s/%d/%s" % (rounds, k, name),
                        "cannot copy round %d's %s into %s/%d" % (k - 1, name, rounds, k))


def round_dir(args: List[str], issue: str, phase: str, root: str) -> int:
    """`spec round-dir <k>/<n>`: round k's working directory made ready and
    printed, after the round marker naming the flow's issue, k and n is
    written - last, so a failed write prints no path and a round never runs
    without its marker."""
    if len(args) != 1:
        die("usage: orch.sh spec round-dir <k>/<n>")
    k, n = spec_round_count_parse(args[0])
    spec_phase_guard("round-dir", issue, phase, 1)
    rounds = spec_rounds_dir(root)
    directory = "%s/%d" % (rounds, k)
    spec_round_dir_reset(directory)
    if k == 1:
        spec_round_sweep(rounds, directory)
    else:
        spec_round_carry(rounds, k)
    spec_marker_write(root, SPEC_ROUND_MARKER, "%s %d %d" % (issue, k, n))
    print(directory + "/")
    return 0


def spec_round_marker_parse(marker: str) -> Tuple[str, int, int]:
    """The round marker at <marker>, its first line read as `<issue> <k> <n>`
    - a plain issue number, then a round and the round count no greater, two
    positive whole numbers, and nothing after - split on blanks as bash's
    `read` splits it. Dies, exit 2, naming the marker and its line when it
    is malformed, or saying it is empty when it holds nothing; a marker that
    cannot be read is empty, as bash's read of it gave no line."""
    rerun = "want <issue> <k> <n>; rerun orch.sh spec round-dir <k>/<n>"
    text = read_raw(marker) or ""
    if not text:
        die("malformed round marker %s: it is empty - %s" % (marker, rerun), 2)
    line = text.split("\n", 1)[0]
    issue, k, n, extra = read_words(line, 4)
    if not plain_number(issue) or not plain_positive_number(k) \
            or not plain_positive_number(n) or extra or int(k) > int(n):
        die("malformed round marker %s: '%s' - %s" % (marker, line, rerun), 2)
    return issue, int(k), int(n)


def round_op(args: List[str], root: str, env: Mapping[str, str]) -> int:
    """`spec round`: the round a resumed flow's spec review runs next, from
    the round marker - `<k> <n> applying` while the marker's round holds a
    saved apply answer (an apply died), `<k> <n> waiting` while it holds
    fundamental items back for the human's answer (autopilot), else `<k>
    <n>`, the marker's k, or k+1 once round k's directory holds
    round-complete - or `done <n>` once round n's does. Exit 1, printing
    nothing, when there is no marker or it names another issue; every
    failure is exit 2, so a caller never reads one as "no marker"."""
    if args:
        die("usage: orch.sh spec round", 2)
    state = require_state_read(flow_state_file(root), env, ("issue", "phase"), 2)
    spec_phase_guard("round", state["issue"], state["phase"], 2)
    marker = "%s/%s" % (handoff_dir(root), SPEC_ROUND_MARKER)
    if not os.path.isfile(marker):
        return 1
    issue, k, n = spec_round_marker_parse(marker)
    if issue != state["issue"]:
        return 1
    rounds = spec_rounds_dir(root)
    round_state = spec_round_state("%s/%d" % (rounds, k))
    if round_state in ("applying", "waiting"):
        print("%d %d %s" % (k, n, round_state))
    elif round_state == "open":
        print("%d %d" % (k, n))
    elif k < n:
        print("%d %d" % (k + 1, n))
    else:
        print("done %d" % n)
    return 0


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
) -> int:
    """`orch.sh spec <op> ...`: the real adapters and the process's
    environment unless a test hands in fakes. Outside a checkout it dies
    first, as orch.sh does, whatever the op. Every op but round makes the
    entry read of the flow's issue and phase here, before the op is checked,
    and hands both on; round reserves exit 1 for "no round marker", so it
    makes its own read, dying exit 2."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    args = argv[1:]
    state = {"issue": "", "phase": ""}
    if op != "round":
        state = require_state_read(flow_state_file(root), env, ("issue", "phase"), 1)
    if op not in OPS.split("|"):
        die("unknown spec op: %s (want %s)" % (op or "<none>", OPS))
    issue, phase = state["issue"], state["phase"]

    # The gh adapter, made at the first GitHub call: only the issue ops and
    # an autopilot flow's pause --round make one.
    gh_of = adapter_of(gh, env)
    if op in ISSUE_OPS:
        return issue_op(op, args, issue, phase, gh_of, git, env)
    if op == "pause":
        return pause(args, issue, phase, root, gh_of, env)
    if op == "round-dir":
        return round_dir(args, issue, phase, root)
    return round_op(args, root, env)
