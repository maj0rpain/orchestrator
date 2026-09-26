# The review loop owns its reviewer briefs

Supersedes ADR-0001's premise that the reviewing is done by
`mattpocock-skills:code-review`'s sub-agents. ADR-0001's claim that one
session drives a loop, and its reason - the reviewers never see the driving
session's reasoning - stand.

The review loop starts two plugin agents of its own every iteration,
`orch-reviewer-standards` and `orch-reviewer-spec`, instead of invoking
`code-review`. Invoking `code-review` cost the driving session its skill body,
its per-call setup, prompts written inline with the spec body pasted in, and
the reports twice over as replies and task notifications - several thousand
tokens an iteration, in a session that must last a whole budget. An agent
the plugin owns takes a prompt of four variables (base SHA, spec issue,
iteration, report path), fetches the diff and the spec itself, writes its
report to a file beside the iteration's record, and returns one line.

Owning the briefs also lets the loop restrict the reviewers mechanically:
they get Read, Grep, Glob, and Bash, no Edit or Write, and a brief that allows
one write, the report. And the loop no longer depends on another skill's
internals - its prompt shape, its output shape, or its name staying unshadowed.

The trade-off: the Standards reviewer carries a local copy of `code-review`'s
Fowler smell baseline, copied from `mattpocock-skills` 1.2.3. It no longer
tracks upstream; a change there reaches the loop only when someone copies it
across. The implement phase's ticket subagents still use `code-review` as
before.

## Considered Options

- **Keep invoking `code-review`.** Rejected: its fixed per-call cost is paid
  every iteration and grows the driving session past its context target.
- **Wrap `code-review` in an agent of our own.** Rejected: the wrapper pays
  the same skill body and setup, one level down, and still depends on its
  internals.
- **Keep the briefs as plain files read by general-purpose agents.** Rejected
  except as the host fallback: a general-purpose agent cannot be denied Edit
  and Write, so read-only would rest on the brief alone.
