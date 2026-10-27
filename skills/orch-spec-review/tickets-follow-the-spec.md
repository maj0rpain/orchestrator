# Tickets follow the spec

A reference file of the `orch-spec-review` skill, read only when
`spec-review apply` pauses with exit 3: an accepted edit changed the body,
and the issue has a ticket breakdown. `orch-to-spec`'s **Unattended rewrite**
also follows its **Drafting** and **Applying** rules.

A spec review on an issue that already has a ticket breakdown - a blueprint a
flow adopted or a quick implementation linked, or any issue reviewed
standalone - would otherwise leave tickets drawn from the old body, and the
implement phase would build them. This step brings the breakdown in line with
the edits just accepted, before the body is published. It is not another
round: within a round, no lens runs again and the spec is not reviewed again
(ADR-0004, ADR-0041). Both entries share it.

## When it runs

`apply` decides, and records the other outcomes itself. With no edit
applied, it runs no `ticket exists` and records **Not checked - no edit
applied**; with no breakdown, **None - no ticket breakdown**. Only when an
accepted edit changed the body and `ticket exists` exits 0 does it pause:
it keeps the edited `<dir>/spec.md`, prints the breakdown kind,
`sub-issues` or `collapsed`, writes nothing to GitHub, and exits 3. Any
other `ticket exists` exit stops `apply` with nothing written, and stops the
review as a failed fetch does.

## Drafting

The session running the review drafts - never a lens, never a new agent:
this is reconciliation, the same kind of work as **Consolidation**.

- Read the body as fetched, `<dir>/spec.fetched.md`, and as edited,
  `<dir>/spec.md`, plus each ticket's body.
- `sub-issues`: `bash "$ORCH" ticket list <issue>` prints each ticket as
  `<n> open` or `<n> closed`; fetch each with
  `bash "$ORCH" issue fetch <n> <dir>/ticket-<n>.md`. `collapsed`: the ticket
  is the body's `## Ticket` section.
- Draft concrete replacement text only for **open** tickets the accepted
  edits touch. A closed ticket is never edited and nothing reopens it: note
  what changed for it, for the changelog.
- An edit that changes only which open tickets block which is applied with
  `ticket block`/`ticket unblock` and rewrites no other part of the body.
  Adding, removing or re-ordering slices still recommends **Retire and break
  down again**. "Open tickets" names the ticket whose edges change: its
  blocker may be open or closed. Each edge change - one edge added or
  removed - is its own numbered item.
- A drafted edit you believe is wrong is still presented, marked **recommend
  decline** with the reason.

Write the items once, to `<dir>/tickets.md`, in the batch file's marker
format:

```
@@ recommend apply|retire                                first line
@@ item <n> ticket <t> apply|decline <reason>            an edit to sub-issue #<t>
@@ item <n> section apply|decline <reason>               an edit to the collapsed ## Ticket section
@@ summary <one line>                                    a text item's changelog line
@@ anchor / @@ replace / @@ end                          a text item's exact anchor and replacement
@@ item <n> block|unblock <t> by <b> apply|decline <reason>    one edge added or removed
@@ closed <t> <what changed>                             a closed ticket the edits touch
@@ none-affected                                         alone in the file: no open ticket affected
```

A `ticket` item's anchor is text in `<dir>/ticket-<t>.md`; a `section`
item's is text in the body as the accepted edits left it.

## The ticket question

If no open ticket is affected, ask nothing: write `@@ none-affected` alone,
or, when the edits touch a closed ticket, `@@ recommend apply` and one
`@@ closed` line per closed ticket, so each is still listed.

Before any ticket item is shown, check `tickets.md`:

```
bash "$ORCH" spec-review check <dir> --tickets
```

It validates `tickets.md` as `apply --tickets` would take the **all**
answer, writing nothing but `<dir>/view.md` and reading no GitHub. On any exit
but 0, each `orch:` line on stderr names what is wrong, most with its
`tickets.md` line: fix `tickets.md` and run it again, until it exits 0. On exit
0 it prints the full ticket view on stdout - each item with its ticket (`#<n>`,
or the `## Ticket` section), its recommendation, and its Current and Proposed
text in full, or for an edge change the block or unblock it makes, then the
closed tickets and the file's recommendation - writes exactly that view to
`<dir>/view.md`, overwriting any earlier one, and prints its one-line pass
summary on stderr, naming that `view.md` by absolute path and telling you to
end your turn on one plain-text reply, with no tool call, holding the view
above word for word and then the question with its answer words spelled out.
With `@@ none-affected` its stdout is the `No open ticket is affected.` stub,
which is no view: it removes any earlier `<dir>/view.md`, writes none, and
its pass line names none.

When an open ticket is affected, ask **one ticket question** as the spec
batch is asked: end your turn on one plain-text reply, with no tool call,
holding `check --tickets`'s stdout word for word, composing no view of your
own, then the ticket question with its answer words spelled out. Never ask
it with the host's ask tool (`AskUserQuestion` on Claude Code, `ask_user` on
Junie): the turn ends on the view and the question, and the human's next
message is the answer. On Claude Code an ask-tool call is refused until the
view is pasted, as the spec batch's is. Its options are the spec batch's,
under the skill's **Disposition**, each offered once and with the same
rules, except:

- **Retire and break down again** is added: no ticket is edited; the
  breakdown is retired after the body is published, and the issue broken
  down again.
- **Other** is its own rule, not the spec batch's override form: the item
  numbers to apply, comma-separated, e.g. `1, 3`. The listed items are
  applied and every item left out is declined. A ticket item has no option
  letter, and takes no `-` or `+`.
- The option you recommend comes first and carries **(Recommended)**:
  **Retire and break down again** when `tickets.md` recommends a retire,
  otherwise **Apply as recommended**.

Its answer words are the option names `apply --tickets` takes: `recommended`,
`all`, `none`, `retire` (only when offered), or the Other form, the item
numbers to apply, comma-separated (e.g. `1, 3`); the question spells them
all out. An answer word and its option's full label (`Retire and break down
again` is `retire`) are the same answer, matched after trimming surrounding
whitespace, letter case and trailing punctuation, as for the spec batch. The
ticket question is a turn-final reply, per `docs/turn-final-reply.md` under
the plugin root. A near-miss reply - one matching none of these forms - is
restated in the grammar `apply --tickets` takes, as the doc's **Near-miss
reply** says. On *No*, or on a reply that is clearly a question, the doc's
**Question path** runs: re-run `check --tickets`, and end the turn again on
its view and the ticket question.

## Applying

Run `apply` again with the same arguments and answer as the paused run, plus
`--tickets <answer>`: `recommended`, `all`, `none`, `retire`, or the Other
list as given. When no question was asked, the answer is `recommended`. Put the
human's reasons for declined ticket items in a file, one `<n>: <reason>` line
each, and pass it as `--ticket-reasons <file>`. A refusal is fixed in
`tickets.md` and the rerun repeated, as for the batch.

`apply` makes the writes, in this order, and nothing calls `gh issue`
directly:

- Each accepted sub-issue edit replaces that ticket's body, through
  `bash "$ORCH" issue update <n> <dir>/ticket-<n>.md`.
- Each accepted edge change runs `bash "$ORCH" ticket block <n> --by <blocker>`
  to add the edge, or `bash "$ORCH" ticket unblock <n> --by <blocker>` to
  remove it; the command rewrites `<n>`'s `## Blocked by` section itself.
  When one ticket gets both a text edit and an edge change, the text edit
  lands first, its `## Blocked by` section left as fetched.
- An accepted edit to a collapsed `## Ticket` section goes into the body,
  published with the review's one body update.
- A retire edits no ticket: `bash "$ORCH" ticket retire <issue>` runs after
  the body is published, so it cuts any `## Ticket` section from that body.

A failed `issue update`, `ticket block` or `ticket unblock` stops the review
as a failed write does.
