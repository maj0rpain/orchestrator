# The batch file

A reference file of the `orch-spec-review` skill, read when writing
`<dir>/batch.md` during **Disposition**.

Marker lines; a line starting `@@ ` is reserved, and no body line starts that
way. The `@@ lens` lines come first, one per lens, Fidelity included, then one
block per item, in the batch's order:

```
@@ lens <name> ran                        a lens that answered
@@ lens <name> not-run <reason>           a lens that failed twice
@@ lens fidelity standalone               Fidelity in a standalone review
@@ item <n> <group> apply <mark>                   a proposed edit, recommended
@@ item <n> <group> decline <mark> <reason>        a proposed edit marked recommend decline;
                                                     it still carries the edit it declines
@@ item <n> <group> decision <letter> <mark>        a decision item, <letter> recommended
@@ item <n> <group> resolved                       a finding an earlier item resolves; no mark
@@ summary <one line>                     the changelog's line when the item is applied
@@ why <one line>                         a material item's reason for its edit, at item
                                            level: one per material item, never under an
                                            option, and on no minor or resolved item
@@ finding <lens> <k>                     repeatable: the lens findings the item resolves
@@ comment @<login> <createdAt>           a consolidation item's comment, repeatable,
@@ quote                                    each followed by the comment's spec-bearing part
@@ resolved-by <m>                        the earlier item; a resolved item has no anchor
@@ option <letter> <label>                a decision item's option, with its own summary,
                                            anchor and replacement
@@ anchor                                 exact text already in the body, matching once
@@ replace                                its replacement
@@ end
```

A block line that is `@@` alone or begins with `@@ ` is written with one extra
leading `\` (`\@@ note <text>` reads as `@@ note <text>`); a line of one or
more `\` then `@@` loses exactly one.

`<group>` is `consolidation`, a lens name, or `contradicts-the-plan`.
`<mark>` is `material` or `minor`, the last fixed token of the `@@ item`
line, before any reason; a decision item and a `contradicts-the-plan` item
are always `material`, and a resolved item takes no mark. An
insertion is an anchor plus a replacement that repeats it. Every item with
an anchor, and every option, has its one `@@ summary`: one sentence stating
what the spec will say after the edit, not the topic the edit touches. `check`
and `apply` refuse a summary, an item's or an option's, of more than 30
words - each a run of non-whitespace - naming the item, its option and its
`batch.md` line. Every material item
carries one `@@ why`, a decision item's before its first `@@ option`; on a
recommend-decline item it is still the reason for the edit, and the reason
for declining stays on the `@@ item` line. `check` and `apply` refuse a
material item without one, naming its `@@ item` line, and a `@@ why` that is
empty, on a minor or resolved item, under an option, or a second on one
item. The changelog never carries it. A `@@ finding` cites
the `<k>`-th finding in `<dir>/lens-<lens>.md`, which `apply` copies into the
changelog, so the batch file never quotes a lens. Every finding of a lens that
ran is cited by at least one item; `check` and `apply` refuse a batch that
leaves one uncited, naming each.

`check` and `apply` verify every anchor: each must match the body exactly
once, and `check` names the `batch.md` line of each one that does not. No
hand check is needed - no `grep` loop, no python count - before running
`check`.

## A worked example

A standalone review, so Fidelity is recorded as `standalone`, of this body:

```
# Widget export

## Problem Statement

Exports time out on large widgets.

## Solution

The export streams each widget in pages of 100.
The export writes one file.

## Testing Decisions

- One seam: the `widget export` CLI.
```

Its batch holds one item of each kind, and passes `check`:

```
@@ lens fidelity standalone
@@ lens consistency ran
@@ lens testability ran
@@ lens implementability ran

@@ item 1 consolidation apply material
@@ summary Failed pages are retried once
@@ why A page that fails once should not fail the whole export
@@ comment @alice 2026-10-01T09:00:00Z
@@ quote
A failed page should be retried once before the export gives up.
@@ anchor
The export streams each widget in pages of 100.
@@ replace
The export streams each widget in pages of 100.
A failed page is retried once before the export fails.
@@ end

@@ item 2 testability apply material
@@ finding testability 1
@@ summary The seam's test runs against a fake store
@@ why The seam names no store to test against
@@ anchor
- One seam: the `widget export` CLI.
@@ replace
- One seam: the `widget export` CLI, end to end, against a fake store.
@@ end

@@ item 3 consistency decline minor the glossary's term is widget, as the body says
@@ finding consistency 1
@@ summary Widgets renamed items
@@ anchor
Exports time out on large widgets.
@@ replace
Exports time out on large items.
@@ end

@@ item 4 implementability decision B material
@@ finding implementability 1
@@ why One file cannot hold the largest exports
@@ option A One file
@@ summary The export writes one compressed file
@@ anchor
The export writes one file.
@@ replace
The export writes one compressed file.
@@ end
@@ option B One file per widget
@@ summary The export writes one file per widget
@@ anchor
The export writes one file.
@@ replace
The export writes one file per widget.
@@ end

@@ item 5 implementability resolved
@@ finding implementability 2
@@ resolved-by 4
```

- **Consolidation** (item 1): an `apply` item citing its comment with
  `@@ comment` and `@@ quote` instead of a `@@ finding`. Its edit is an
  insertion: the replacement repeats the anchor and adds a line after it.
- **Apply** (item 2): a `@@ finding`, a `@@ summary`, its `@@ why`, as a
  material item, then one `@@ anchor`, `@@ replace`, `@@ end` block.
- **Decline** (item 3): the same shape as an apply item - summary, anchor,
  replacement and `@@ end` - so **Apply all** can still apply it; the reason
  is on its `@@ item` line, after its mark. Renaming a term is minor, so it
  carries no `@@ why`, and `check` lists it under **Minor edits** with its
  reason.
- **Decision** (item 4): no summary or block of its own, but its one
  `@@ why` before its options; each `@@ option` carries its own
  `@@ summary` and block, and the `@@ item` line names the recommended
  letter.
- **Resolved** (item 5): only its findings and `@@ resolved-by`; it takes no
  mark, `@@ summary`, `@@ why`, `@@ anchor`, `@@ replace` or `@@ end`, and
  `check` lists it under **Minor edits** as resolved by item 4.
