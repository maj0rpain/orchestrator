# orch.sh trusts a comment by its author's role and an issue by its last writer

Amends ADR-0033 (GitHub is faked at the adapters' domain operations) and
ADR-0030 (the spec review folds an issue's comments into its body).

orch.sh read every issue and PR comment, and an issue's title and body,
without regard to who wrote them. A marked comment was recognised by its first
line alone, so on a public repo any GitHub user could forge a handoff, retire
a live one, post a question, a stop or a `Spec ruling:`, answer a pending
question, or have text folded into the spec (#1903). A stranger could also
open an issue, or edit their own after a maintainer reviewed it, and control
the title and body an autopilot phase reads.

Decision:

- A comment is trusted when its `authorAssociation` is `OWNER`, `MEMBER` or
  `COLLABORATOR`. gh already returns it with the comments, so trust adds no
  gh call.
- One filter, in the `trust.sh` concept module, drops untrusted comments at
  the read, once, in the domain layer just above the gh adapters, before any
  marked comment, answer or spec text is read from one. It prints one stderr
  line, `orch: ignored N comment(s) from untrusted authors on #<n>`, when it
  drops any, and leaves no placeholder in rendered output. The comment
  adapters return raw comment JSON carrying `authorAssociation`, and the
  rendering moves above them, after the filter. `issue fetch --json`'s
  published shape is unchanged.
- An issue is trusted when its author has a role on the repo, or when its
  body and its title were each last written by someone other than the author
  (editing another user's issue already needs a repo role). A title never
  renamed follows the body, and a renamed title follows its newest renamer:
  the literal rule, "the title was last written by a non-author", would
  refuse every stranger's issue that a maintainer only edited the body of.
  One GraphQL read gives the author, the body's last editor and the latest
  title rename's actor.
- The issue rule is enforced only on unattended runs, as the first step of the
  watcher's pickup, before every phase. An untrusted issue gets a refusal stop
  naming the writer, plus `needs-human`; a failed read fails closed with a
  failure stop. Attended reads (`issue fetch`, `init --issue`) only warn.

Consequences: a stranger's comment vanishes from every read, with one stderr
line saying so. Attended reads still let a human interview an outside bug
report. A stranger-authored issue needs a maintainer edit before autopilot
runs it, and a stranger's re-edit afterwards makes it untrusted again.

It amends ADR-0033: the comment adapters return raw comment JSON carrying
`authorAssociation`, and the rendering moves above them. It amends ADR-0030:
the spec review folds only trusted comments into the body.

## Considered Options

- **Trust only the gh-signed-in login.** Rejected: breaks when the answering
  human and the watcher's `GH_TOKEN` are different accounts.
- **Configured allowlist of logins.** Rejected: needs configuration; the
  association is already in the read.
- **Ignore only the markers, keep untrusted comments visible.** Rejected: a
  stranger's reply would still answer a question and their text would still be
  folded into the spec.
- **Filter inside each gh adapter.** Rejected: would bypass the fake and leave
  the rule untested.
- **Issue comments only, PR comments out.** Rejected: PR comments feed the
  review pass's rulings and the review loop's agents the same way.
- **Silent drop, or a placeholder line.** Rejected: silent hides a withheld
  comment from the human; a placeholder still puts stranger-controlled
  metadata in front of an agent.
- **Enforce issue trust on every body read.** Rejected: would block a human
  from interviewing an outside bug report.
- **Permissions-API check for a non-author editor.** Rejected: editing
  another's issue already requires a repo role.
- **Skip an untrusted issue silently in autopilot.** Rejected: leaves it stuck
  with no explanation.
- **Issue body/title as a follow-up issue.** Rejected: folded in at planning,
  so this change covers it.
