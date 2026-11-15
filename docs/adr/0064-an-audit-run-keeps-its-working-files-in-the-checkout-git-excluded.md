# An audit run keeps its working files in the checkout, git-excluded

Amends ADR-0060: the audits' read-only promise is no longer "no file in the
checkout".

The audit skills, `orch-audit-docs`, `orch-audit-code` and
`orch-audit-tests`, kept every working file in a temp directory outside the
repo that the session running the audit made, and left the files' names to
that session. On Claude Code a
hunter's write to a findings file named like a report was refused there, the
findings came back inline, and the session retyped them. Files that subagents
write under `.orchestrator/`, such as a spec review's lens files, have not
been refused.

So an audit run keeps its working files in `.orchestrator/audit/<run>/`, made
by `orch.sh audit begin`, under names the skill fixes. The read-only promise
becomes: an audit changes no tracked file and nothing `git status` shows.
`.orchestrator/` is git-excluded, as it is for a standalone spec review and a
review pass. The run directory also outlives the session, so a report can be
opened, and findings filed from it, later.

ADR-0060's rule stands: the audits still run no `agent sync`. Its reason is
narrower now. `agent sync` writes `.junie/agents/`, outside the run
directory, and those copies change how the host starts agents after the audit
has ended. A run directory changes nothing once the audit is over.

## Considered Options

- **Keep the temp directory and fix only the file's name.** Rejected: a name
  the host accepts there was seen a handful of times, against hundreds of
  accepted writes under `.orchestrator/`, and a temp directory does not
  outlive a reboot, while filing from a run may come days later.
- **Have the hunters reply with their findings inline.** Rejected: the session
  then retypes every finding, which is the cost this removes.
- **Let the audits run `agent sync` too, now that they write in the
  checkout.** Rejected: the copies outlive the audit and change later
  sessions.
