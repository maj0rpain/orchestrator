# Writing a PR

Summary visuals adapted from Dex Horthy's `show-me`
(https://github.com/humanlayer/skills), via the `pr` skill in
mattpocock-skills 1.3.1.

The one standard for every PR body and PR comment the plugin writes, in any
repo. Each site that writes one reads this doc and adds only its own
headings. `orch.sh` checks a body's structure, never its wording.

## Style rules

For bodies and comments alike:

- **No preamble.** Start with the content: no "This PR...", no restating the
  title.
- **Brief prose.** Short sentences, one point each. Cut whatever a reviewer
  would skip.
- **The repo's terms.** Use the words of the repo's glossary, when it has
  one, and the names the code uses.
- **Visual beside its text.** Put each visual next to the sentence it
  supports, never in a gallery at the end.
- **Smallest view.** Pick the smallest view that makes the point: a call
  tree over a full diff, three lines of pseudocode over a whole function.
- **Never restate the spec.** The `Closes #<n>` or `Refs #<n>` line already
  links the issue. Say what this change does, not what the issue asked for.

## Body layout

A flow's PR and a quick implementation's PR carry three parts, in this
order.

### 1. Human layer

**`## Summary`**: what changed, in a few lines, with at least one visual
drawn from this menu:

- **Pseudocode**: the new logic's shape, stripped of syntax.
- **Call tree**: who calls what, indented, the changed nodes marked.
- **Component tree**: the parts of a UI or system and how they nest.
- **File tree**: the files added, moved or removed, marked as such.
- **Mermaid**: a flowchart, sequence or state diagram, in a `mermaid`
  fenced block, when the change is a flow between parts.
- **Diff sketch**: the few lines that carry the change, as a `diff` block,
  with the rest elided.
- **Full block**: the whole of a short new function or config, when it is
  small enough to read at a glance.

**`## Evidence`**: what proves the change works, from real runs only:

- each test that now passes, as given/when/then pseudocode, one per test;
- for a bug fix, the behaviour before the fix: the failing run or the wrong
  output, from the red run its test recorded, never invented;
- as its last line, the verification command, then `pass` or `fail`.

**`## Merge Danger`**: how risky the merge is, in two lines:

```
**Door:** one-way | two-way
**Blast Radius:** <free text>
```

- **Door** is exactly `one-way` or `two-way`. A two-way door reverts
  cleanly. A one-way door cannot be undone by a revert. Typical one-way
  doors:
  - a migration of persisted data or a schema;
  - a rename or removal in a public API, CLI, config key or file format
    others depend on;
  - deleting user data, branches or resources;
  - a published contract, such as an event, webhook or wire format.
- **Blast Radius** says who or what the change can break, in free text.
  It has no fixed vocabulary.

Both lines sit under `## Merge Danger`, before the next heading, and each
appears once.

### 2. The repo's PR template

When the target repo has a PR template - `.github/pull_request_template.md`
or a `.github/PULL_REQUEST_TEMPLATE/` directory - its headings come next.
Answer each one, or mark it `N/A`. Never drop one silently, and never let
the template replace the human layer.

### 3. Audit layer

The writing site's own headings, unchanged and in the site's order. Their
names are exact H2s that tools and agents parse, so never rename, merge or
reword a heading here.

## Release layout

A release PR carries `## Summary` only: what the release delivers, grouped
into themes, each theme with a visual where one helps. It has no Evidence
and no Merge Danger, because every PR it carries was already reviewed.

## Comment shape

A PR comment carries, in this order:

1. **Lead**: 1-3 lines stating the outcome, with no preamble.
2. **`## Summary` and `## Evidence`**: only when the commits the comment
   reports changed code, written as in the body layout.
3. **The site's own headings**, in its fixed order, each present, with its
   `None.` form when empty.

A comment never carries `## Merge Danger`: the merge's risk is a property of
the whole PR, and lives in the body.
