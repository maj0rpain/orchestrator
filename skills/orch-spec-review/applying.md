# Batch view, answers, and applying

A reference file of the `orch-spec-review` skill, read in **Disposition**
after running `spec-review check` (for the view format and interactive
answers) and to apply the answer and post the changelog.

## Batch view and interactive answers

On exit 0 `check` prints the compact batch view on stdout - the lens lines,
ran or not run with the reason, then the material items as one bulleted list
in batch order, consolidation items first, each under its `batch.md` number
and with no `### Item` heading. The number is written literally, in bold after
the bullet, never as a Markdown ordered-list number, which a renderer would
recount from the first item, so the number a human reads is the number
their answer names. Each entry is one line, its summary and its reason -
`- **<n>** - **<Group>** - <summary> (apply) - <why>`, or `- **<n>** -
**<Group>** - <summary> (recommend decline: <reason>) - <why>`, `<why>` its
`@@ why` line - or for a decision item its header, `- **<n>** - **<Group>**
(decision, option <L> recommended) - <why>`, then one sub-bullet per option,
indented a fixed 2 spaces: `Option <L> - <label>: <summary>`, ` (recommended)`
after the recommended one's label. The compact view cites no finding or
comment and shows no diff: `--full` prints an item in full. Then, under a
`### Minor edits` heading, every minor and resolved item one line each, in
batch order: `- **<n>** - <Group>: <summary>`, a recommend-decline minor
item's line ending `- recommend decline: <reason>`, and a resolved item's
reading `- **<n>** - <Group>: resolved by item <m>`. No line of the view
starts with `<digits>. `. The heading is left out when no item
is minor or resolved, and the item numbers stay the one sequence of
`batch.md`. `check <dir> --full <n>...` validates the batch the same way,
then prints only the named items, any of them, minor or resolved included,
in the order named, each in full: its group, its recommendation, its cited
findings and comments quoted, and its Current and Proposed text in full,
each option's for a decision item. Either form also writes exactly the view
it printed to `<dir>/view.md`, overwriting any earlier one, and its one-line
pass summary goes to stderr: it names that `view.md` by absolute path and
tells you to end your turn on one plain-text reply, with no tool call,
holding the view above word for word and then the question with its answer
words spelled out. A `check` that fails leaves any earlier `view.md` as it was.

The batch question's answers:

- **Apply as recommended (Recommended)**, answer word `recommended` - every
  proposed edit applied, every decision item takes its recommended option,
  every **recommend decline** item skipped. Always offered, first.
- **Apply all**, answer word `all` - offered only when at least one item is
  marked **recommend decline**: as recommended, plus those items too. With no
  such item it would equal the first option, so it is not shown.
- **Apply none**, answer word `none` - always offered.
- **Other** - only the departures from the recommendation, comma-separated,
  e.g. `3B, -4, +2`: `<n><letter>` gives decision item `<n>` option
  `<letter>`; `-<n>` declines item `<n>`, or leaves a decision item undecided,
  and the changelog says so; `+<n>` applies recommend-decline item `<n>`.
  Every item not named stays as recommended. A bare item number is no
  departure and is refused. Other also takes `show <n>` - one or more item
  numbers, e.g. `show 3` or `show 3 5` - which prints those items in full,
  or a free-text question.

The question spells every answer out: `recommended`, `all` when offered,
`none`, a departure list in this format, `show <n>...`, or a question in
plain words. An answer word and its option's full label (`Apply as
recommended`, `Apply all`, `Apply none`) are the same answer, matched as
`docs/turn-final-reply.md` under the plugin root (the doc) says.

Tell an Other answer's form this way. An answer starting with `show`
followed by item numbers is a show request. An answer made only of
departure-shaped tokens - `<n><letter>`, `-<n>`, `+<n>` or a bare `<n>` -
comma-separated, is a departure list: it goes to `apply` as given, which
refuses it as it does today if it is malformed, a bare number included.
A reply that is clearly a question is a question.

A **near-miss reply** (the doc's **Near-miss reply**) matches none of these
forms: a typo, extra words around an answer word, or mixed forms such as
`recommended but not 4`. It is never re-pasted. Its one-line restatement is in
the grammar `apply` accepts (e.g. "Apply as recommended, except item 4
declined" - `-4`). *No* runs the question path below. On Claude Code the
confirmation ask passes the hook: the near-miss message disarmed the guard.

An Other answer of `show <n>...` is not an answer to the batch question.
Run `bash "$ORCH" spec-review check <dir> --full <n>...` with the numbers it
names, then end the turn again on a turn-final reply, per the doc, holding
its stdout word for word and the batch question. It writes the full items'
view to `<dir>/view.md` in place of the batch view, and its pass line names
that file and gives the same instruction as the batch `check`'s. On Claude
Code an ask-tool call is refused until the view is pasted, as for the batch
question. `apply` never receives a `show` answer. A `--full` refusal - a
number not in `batch.md` - is told to the human, and the batch question
asked again, the same way.

A question, or *No* to a near-miss confirmation, is not an answer to the
batch question either: the doc's **Question path** runs. Do not run `apply`,
which never receives a question. Re-run `bash "$ORCH" spec-review check
<dir>`, and end the turn again on its new view word for word and the batch
question. The re-run's pass
line arms the guard again (the human's message disarmed it), so on Claude Code
only a paste made after it lets a later ask through.

The spec batch is asked once; a long spec is one longer question, not twenty
prompts.

## Applying the answer

One call applies the answer, run with the human's answer as given:
`recommended` for **Apply as recommended**, `all`, `none`, or the Other
override list such as `"3B, -4, +2"`. `--round <k>/<n>` names the round. A
departure that matches the recommendation - `-<n>` on a recommend-decline
item, or a decision's recommended letter - is accepted and recorded as
recommended. `apply` refuses, before any write, a token that is not
`<n><letter>`, `-<n>` or `+<n>` (a bare number among them), an unknown item
or option letter, a letter on an item that is no decision, `+` on a decision
item or on an item not recommended for decline, `-` or `+` on a resolved
item, and an item named twice. The human's reasons for declined items - a
`-<n>` decline among them - go in a file, one `<n>: <reason>` line each,
passed as `--reasons <file>`; a line naming an item the answer does not
decline is refused.

```
bash "$ORCH" spec-review apply <dir> <answer> --round <k>/<n> [--reasons <file>]
```

`apply` applies the accepted items to `<dir>/spec.md`, follows the tickets,
publishes the body only when it changed, runs any retire after that
publish, and writes the round's changelog to `<dir>/changelog.md` and posts
it, on Apply none too - see **The changelog**. Nothing calls `gh issue`
directly.

How it exits:

- **0**: the round is published.
- **3**: the ticket pause. An accepted edit changed the body and the issue
  has a ticket breakdown; `apply` printed its kind and wrote nothing to
  GitHub. Read `tickets-follow-the-spec.md` in this skill's directory now,
  and follow it: it drafts `<dir>/tickets.md`, asks the ticket question,
  and runs `apply` again with `--tickets <answer>`.
- **Any other exit, refused**: the `orch:` message names the item, line or
  answer at fault, and nothing was written to GitHub. Fix `batch.md`,
  `tickets.md` or the reasons file and run the same `apply` again; an
  answer `apply` cannot read is asked again.
- **Any other exit, a failed write**: the message names the write that
  failed and every write that already landed, and says the review stops
  here. Stop the review, as **Rounds** says; `apply` refuses to run again
  in that directory.

A standalone review adds `--issue <issue>`, and with host fallbacks to
record, `--host-fallbacks <file>` holding them. `apply` then uses the
stateless `issue` commands and never reads `state.json`. When a round
retired the breakdown, invoke the `orch-to-tickets` skill on the issue after
the **final** round - never before it, so a later round cannot make a fresh
breakdown stale: it reads the published, edited body, and an attended review
follows it through its own quiz until the human approves a breakdown. A
standalone review never writes `state.json`, `.orchestrator/handoff/`,
`02-spec.md`, or a plan's **Rejected alternatives**, and returns nothing to
a flow skill.

## The changelog

`apply` writes it, from `batch.md`, the lens files, `tickets.md`, the
answers and the reasons: the session never types it. It opens with the
`## Spec review` heading and the `Round <k> of <n>` line, then a
Consolidation section, one section per lens - Fidelity first - and a
Tickets section: applied items one line each, declined findings and
comments word for word with the human's reason or **declined as
recommended: <reason>**, an undecided decision item's sides then **left
undecided**, **None** for a group with no items, **not run - <reason>** for
a lens that failed twice, and Fidelity's standalone not-run line. Silence is
never ambiguous: Consolidation, every lens, and Tickets have a line. An
applied item, minor or material, reads `- (<n>) <summary>`, attended or
unattended alike: no line carries a minor tag. The
heading keeps every earlier round's comment out of `comments.md`: `orch.sh`
leaves out a comment whose body opens with it.

The comment is history, visible on the issue; the body is the truth.
`<dir>/changelog.md` stays in the round's working directory after it is
posted. As its last step, once every GitHub write has landed, `apply` also
appends the changelog, exactly as written, to the review-wide settled file
`<dir>/settled.md`, creating it on round 1: a pause or a failed write before
then appends nothing.
