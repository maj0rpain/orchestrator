---
name: orch-finding-triage
description: Triage the review loop's filed findings - the open review:<severity> issues still labelled needs-triage, or with --all (a re-check) every open one whatever its triage label - against the current default branch, putting one numbered batch of proposed outcomes per source PR to the human (close as completed when already fixed, ready-for-agent, ready-for-human, or wontfix, each with its bug/enhancement category kept or flipped; an already-triaged finding in a re-check is proposed only close as completed or leave as is), and applying the answered batch; with --bundle, grouping the open findings already triaged to ready-for-agent or ready-for-human by code area into bundle issues, one batch across source PRs, each member closed as a duplicate of its bundle. Use when the human asks to triage, re-check or bundle filed findings or review:* issues, or runs /orchestrator:finding-triage [--all] [<issue> | --pr <n>] or /orchestrator:finding-triage --bundle. Not for any other issue - upstream triage keeps those.
---

# Orchestrator finding triage

**Finding triage** (see `GLOSSARY.md`) checks open **filed findings** against
the current default branch and settles each: closed as completed when the code
it names has since been fixed, otherwise to `ready-for-agent`,
`ready-for-human`, or `wontfix`. It takes only the issues the closer files -
those labelled `review:<severity>` and `needs-triage` - and nothing else;
upstream `triage` keeps every other issue. A **re-check** (`--all`, see
`GLOSSARY.md`) also takes the open `review:<severity>` issues already out of
`needs-triage`: each is closed as completed when it no longer holds, and
otherwise left as labelled unless the human names another outcome. With
`--bundle` it instead groups the open findings already triaged to
`ready-for-agent` or `ready-for-human` by code area into **bundles** (see
`GLOSSARY.md`) - see **Bundle mode** below. Why the plugin owns this step is
recorded in `docs/adr/0031-the-plugin-triages-its-own-filed-findings.md`, and
why a bundle's members close as its duplicates in
`docs/adr/0040-bundled-findings-close-as-duplicates-of-their-bundle.md`.

What this skill never does:

- **No direct `gh`.** `orch.sh finding-triage scan` lists and sorts the
  findings, `orch.sh issue fetch` reads a body, and `orch.sh finding-triage
  apply` and, in bundle mode, `orch.sh finding-triage bundle` are the only
  writes. Never call `gh` yourself.
- **No grilling.** A finding whose fix needs a decision goes to the human as
  `ready-for-human`, with the options its body names; you do not decide it
  here, and you write no agent brief beyond the triage comment.
- **No record edits.** Never edit `GLOSSARY.md`, `GLOSSARY-MAP.md` or anything
  under `docs/adr/` (ADR-0022): a record changes only with the change it
  describes.
- **No subagent.** This skill does all its work in this session, so it needs
  no host fallback for one.
- **No flow state.** It reads and writes nothing under `.orchestrator/`, and
  runs the same with or without an active flow. It changes no branch, HEAD or
  working tree.

On a host with no plugin commands, the human reaches this skill by asking to
triage filed findings rather than running `/orchestrator:finding-triage`.

`orch.sh` resolves as:

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, run `ls "$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh`
(the Junie CLI install). If it prints one path, `ORCH` is that path.
If it prints more than one, stop and show the human the paths.
If it prints nothing, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).

If `orch.sh` is at none of these paths, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension, which is unverified).

This skill needs shell commands and one capability beyond them: ask a
multiple-choice question. `docs/host-capabilities.md` under the plugin root
maps it to each host.

## 1. Scan

With `--bundle` among the arguments, skip steps 1-5 and follow **Bundle
mode** below instead.

The caller's arguments narrow the scan: nothing (every open filed finding
still in `needs-triage`), one issue number, or `--pr <n>` (the findings filed
from PR `<n>`). A leading `--all` makes the triage a **re-check**: it drops
the `needs-triage` filter, so the scan takes every open filed finding whatever
its triage label - all of them, PR `<n>`'s, or the one issue, which then need
not be in `needs-triage`. Without `--all`, a named issue must still be in
`needs-triage`. Run, with that mode and narrowing:

```
bash "$ORCH" finding-triage scan [--all] [<issue> | --pr <n>]
```

It fetches `origin/<default>` and prints one tab-separated line per finding:

```
<issue>	<pr>	<file>:<line>	<result>	<detail>	<state>
```

No field is ever empty: an empty `<pr>` or `<detail>` prints `-`.
`<result>` and `<detail>` are:

- `unchanged` - the finding's lines have no change since the filed SHA, even
  if the file changed elsewhere. That says nothing about the rest of the
  code: a fix can land at another site and leave these lines as they were.
- `changed` - `<detail>` is the full SHA of the newest commit touching the
  finding's lines, or touching its file when the line range can't be followed
  (it starts past the file's end).
- `gone` - the file no longer exists on the default branch.
- `unknown` - `<detail>` says why: an unreachable SHA, a body that does not
  parse, or a file that differs only by commits that never reached the
  default branch.

`<state>` is the finding's current triage state: every triage-role label the
issue carries - `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `wontfix`, each by the repo's label for the role -
comma-joined in that order, or `-` when it carries none. It decides a
re-check's proposals in step 3.

If it dies, relay its reason and stop. If it prints nothing, tell the human
there is no filed finding to triage and stop.

Run `bash "$ORCH" default-branch` to name the default branch, and then,
after the scan, `bash "$ORCH" default-branch --sha` for the **default SHA**
the rest of the triage is checked at. It reads `origin/<default>` without
fetching, so it is the remote tip the scan's own fetch set, and it stays
fixed for the whole triage.

## 2. Judge

For every finding, read its filed body with
`bash "$ORCH" issue fetch <issue> <file>` (a temp file outside the repo): its
`**Axis:**`, `**Severity:**`, `**Location:**`, `**PR:**` and `**Why not fixed
in the loop:**` lines, the `**Spec question:**` line where the body has one,
the claim, and any options it names. A finding with a `**Spec question:**`
line is a **spec question**: a behaviour decision the spec left open, so it
needs a decision.

Then read every finding's code on the default branch at the default SHA -
`git show <default SHA>:<file>`, never by checking anything out - and judge
whether the finding still holds. The scan's result only directs the read; it
is never proof that a finding still holds. Whatever the result, a fix can land
away from the filed lines - another copy, a caller, a new helper - so also
check every other location the body names, and read the commits since the
**filed SHA**, the SHA after the last "at" on the body's `**Location:**` line
(`git log <filed SHA>..<default SHA>`). A finding the read cannot settle is
proposed as still open, its comment saying what the read could not settle.
What each result adds:

- `changed`: read the touching commit (`git show <detail>`) and the code at
  the location now.
- `gone`: deletion is never proof of a fix. Look for where the code moved
  (`git log --diff-filter=D --follow`, or a search on the default branch) and
  judge it there; if it is truly gone, the finding no longer holds.
- `unknown`: judge from the body's claim against today's code, and name the
  scan's reason in the proposal.
- `unchanged`: nothing beyond the read above - the filed lines are as they
  were, so any fix landed elsewhere.

For a finding that still holds, find its current location on the default
branch - `file:line at <default SHA>` - for the comment in step 4.

## 3. Propose one batch per source PR

Group the findings by their source PR, one batch per PR, PRs in ascending
order. Within a batch, number the findings and give each one proposed outcome
with a one-line reason:

- **Close as completed** - the finding no longer holds. Name the fixing
  commit the read found - for `changed`, often the commit the scan reported,
  but never assumed to be it. With none found, name the default SHA at which
  the finding was found not to hold, and why.
- **ready-for-agent** - it still holds, and its filed "Why not fixed" reason
  does not call for a decision.
- **ready-for-human** - it still holds, and its fix needs a decision. List the
  options the filed body names. A spec question that still holds is always
  proposed here, never `ready-for-agent`, and its proposal quotes the body's
  `**Spec question:**` line.
- **wontfix** - proposed only with a reason. The human can always choose it.

**In a re-check** a batch may mix states. A finding whose `<state>` includes
`needs-triage` gets the proposals above. Every other finding counts as
already triaged - `needs-info`, `wontfix` on an open issue, and `-` (no
triage label) included - and is proposed one of only two outcomes:

- **Close as completed** - the finding no longer holds, named as above.
- **Leave as is** - it still holds, or the read could not settle it. Its
  state and category labels stay exactly as they are; name the reason in one
  line.

The human can still give an already-triaged finding any other outcome or
category through the batch's **Other** answer below. Every finding is still
read in full per step 2 (ADR-0039), whatever its state.

Each still-open outcome other than Leave as is also states its category, `bug`
or `enhancement`: keep it, or flip it with a one-line reason - a Standards finding that is a
real defect becomes `bug`, a Spec finding that is a nice-to-have becomes
`enhancement`. The category in place is the one the closer's rule sets from
the body's `**Axis:**` line - `bug` for Spec, `enhancement` for Standards -
and that is also the default for a finding filed before categories, which
carries none.

Present each batch and ask **one blocking question** per batch with the
multiple-choice question capability, the batch and the call in the same
response:

- **Accept as proposed (Recommended)** - every finding takes its proposed
  outcome and category.
- **Other** - the exceptions by number, each with the outcome (and, for an
  open one, the category) it should take instead, e.g.
  `2 wontfix: out of scope; 4 ready-for-human`. Any finding not named takes
  its proposal. The question text states this format. In a re-check, an
  already-triaged finding can be named with any outcome - `ready-for-agent`,
  `ready-for-human` or `wontfix`, with a category - and one proposed for
  closing can be named `leave as is`.

Nothing is written before the answer. Presenting the batch is not the end of
the step; the answer is. A wrong proposal costs nothing until then.

## 4. Apply the answered batch

Once a batch is answered, apply each finding in it with one call, writing its
comment to a temp file outside the repo first - except a finding left as is,
which writes nothing: no `apply`, no comment, no label change. `apply` prepends the
AI-generated disclaimer itself; do not write it.

```
bash "$ORCH" finding-triage apply <issue> <close-fixed|wontfix> --comment-file <file>
bash "$ORCH" finding-triage apply <issue> <ready-for-agent|ready-for-human> --category <bug|enhancement> --comment-file <file>
```

The comment, by outcome:

- **Close as completed** (`close-fixed`): names the commit, or the default
  SHA, from step 3, and why the finding no longer holds.
- **ready-for-agent** / **ready-for-human**: re-anchors the location to
  `file:line at <default SHA>`, says the finding was checked against the
  default branch, and gives the reason for its state; a `ready-for-human`
  comment lists the options. A finding the read could not settle says what
  it could not settle. A flipped category gives its reason.
- **wontfix**: gives the reason.

If an `apply` dies, relay its reason, stop applying - in a re-check as in any
other batch - and report what was and was not applied.

## 5. Report

Per PR, list each finding's issue number and the outcome applied (with its
category, for an open one), each finding left as is in a re-check, and any
finding left untouched with why. Nothing
else changed: no flow state, branch, or record file.

## Bundle mode

`/orchestrator:finding-triage --bundle` groups the open filed findings already
triaged to `ready-for-agent` or `ready-for-human` by code area into
**bundles**: one ordinary issue per group, labelled `finding-bundle`, whose
body restates every **member** so it reads alone. Each member is commented
`Bundled into #<bundle>` and closed as a duplicate of the bundle, keeping its
labels. A bundle run is not a re-check: it closes a candidate that no longer
holds as completed, but never re-triages one.

`--bundle` takes no other argument. If the caller's arguments also carry an
`<issue>`, `--pr <n>` or `--all`, refuse: tell the human `--bundle` groups
across source PRs and takes no narrowing, that a finding is dropped from a
bundle through the batch's **Other** answer, and stop.

### B1. Candidates

Run:

```
bash "$ORCH" finding-triage scan --all
```

and sort its lines (step 1's format) by their `<state>` column - the only
label read this mode uses:

- exactly `ready-for-agent` or `ready-for-human` (the repo's label for each
  role): a **candidate**.
- any value containing `needs-triage`: not a candidate. Report it, with a
  pointer to run `/orchestrator:finding-triage` on it first.
- exactly `needs-info` or exactly `wontfix`: dropped silently.
- any other value - `-`, or a combination such as
  `ready-for-agent,ready-for-human`: not a candidate. Report it with its
  state.

If the scan dies, relay its reason and stop. With no candidate, there is
nothing to judge: report the sorted lines and stop. A lone candidate is still
judged, since it may be proposed close as completed. Then name the
default branch and the **default SHA** exactly as step 1 does.

### B2. Judge

Judge every candidate exactly as step 2 does (ADR-0039): read its filed body
with `issue fetch`, read its code at the default SHA, check every other
location it names and the commits since its filed SHA. The scan line only
directs the read. A candidate that no longer holds is proposed **close as
completed**, named as step 3 names one; it is never bundled. For one that
still holds, note its current location, `file:line at <default SHA>`, its
severity and axis, its claim, any options it names, and its category label
(`bug` or `enhancement`).

### B3. Propose one batch

Group the candidates that still hold by code area - one file or module, or
one concern spread across files. A group has at least two members; a
candidate that fits no group is left as is, never forced into one. Present
one numbered batch:

- **Groups**, numbered, each with:
  - its title: the area and the member count, e.g. `Split helpers:
    first_line / lines_split leftovers (4 findings)` - no `Bundle:` prefix,
    the label does the marking;
  - a one-line reason the members belong together;
  - its triage state: `ready-for-human` if any member is, else
    `ready-for-agent`;
  - its category: `bug` if any member is, else `enhancement`;
  - its members, by issue number and title.
- **Closes**, numbered after the groups: each candidate proposed close as
  completed, with its one-line reason.
- **Left as is**: the candidates in no group, unnumbered.

With no group and no close to propose, there is nothing to ask: go to B5.

Ask **one blocking question** with the multiple-choice question capability,
the batch and the call in the same response:

- **Accept as proposed (Recommended)** - every group is created and every
  close applied as proposed.
- **Other** - the changes, by number or issue: move a finding to another
  group, drop it from a group, split or merge groups, change any
  candidate's outcome - to a group member, close as completed, or left as
  is - or make a group's state or category stricter (`ready-for-human`,
  `bug`). Any candidate, group or close not named takes its proposal. The question text states
  this. A group left with fewer than two members after the answer is not
  created; its member is left as is.

Nothing is written before the answer.

### B4. Apply

Apply the accepted closes first, each with step 4's call and comment:

```
bash "$ORCH" finding-triage apply <issue> close-fixed --comment-file <file>
```

Then the accepted groups, in batch order. For each, write its body to a temp
file outside the repo, then run:

```
bash "$ORCH" finding-triage bundle --title <title> --body-file <file> --state <ready-for-agent|ready-for-human> --category <bug|enhancement> <member>...
```

It creates the bundle, prints its number, and comments and closes each member
as its duplicate. Do not write the AI disclaimer: the verb adds it to each
member comment.

The bundle body carries one section per member, in member order, headed
`#<n> - <title>`, each with:

- the member's severity and axis;
- its claim;
- its location, re-anchored to `file:line at <default SHA>`;
- any options it names.

The body is self-contained: nothing in it requires opening a member.

On any die - an `apply` or a `bundle` - relay its reason and stop applying.
Report what was applied, what was not, and, when the error names one, the
`finding-triage bundle --into <bundle> <member>...` command that resumes the
failed bundle without creating a second.

### B5. Report

List each close applied, each bundle created with its number, title and
members, each candidate left as is, and each scan line reported in B1 as not
a candidate. Nothing else changed: no flow state, branch, or record file.
