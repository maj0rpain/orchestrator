# Deriving per-phase case ladders from one phase table

This project does not replace the per-phase `case` ladders in `orch.sh` and
`doctor.sh` with a single phase table or with prev/next lookups computed
from `PHASES`. That covers `handoff_file_for`, `print_boundary`'s
finished-phase name, `phase advance`'s next-phase switch, and doctor's
`check_flow_handoffs`. It also covers merging `phase_write`'s membership
check with `phase advance`'s check on the stored phase.

## Why this is out of scope

The ladders look alike because each switches on the phase, but each
encodes a different fact:

- `handoff_file_for` maps a phase to the handoff file it reads.
- `print_boundary` maps a phase to the name of the phase just finished, and
  for `spec` that name is `plan`, which is not a phase.
- `phase advance` maps a phase to its successor, and has its own refusal
  for `review` (which leaves through `review ready`) and for `done`.

Deriving all of this from `PHASES` would need a table with a column for
each fact plus exceptions for the refusals. In bash 3.2 (no associative
arrays) that table would be harder to read than the four small switches.
`orch.sh` is a switch-based transaction-script file
(`.out-of-scope/command-function-decomposition.md`), and phases stay plain
strings (`.out-of-scope/typed-phase-representation.md`).

The two membership checks guard different values. `phase_write` checks the
phase it is about to write. `phase advance` checks the phase it read from
state.json and points the user at `doctor --flow`, because a bad stored
value means the state is corrupt, not that the caller made an error.
Different values call for different messages.

If a fifth phase is added and the ladders start drifting in practice, that
is new evidence and worth looking at again.

## Prior requests

- #306: "The phase order is restated in several case ladders beside PHASES" (filed by the review loop as a Standards-axis major against PR #303)
- #314: "phase_write and phase advance both check phase membership with different messages" (filed by the review loop as a Standards-axis nit against PR #303)
