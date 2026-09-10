# A recorded deviation outranks the Spec review axis

`code-review`'s Spec sub-agent compares the diff against the spec issue and
reports requirements that are missing or misimplemented. It does not see
`03-implement.md`, so anything the implement phase knowingly left out is
reported to the review loop as a defect. The loop does not fix those: a finding
covered by the handoff's **Deviations** section drops to a recorded note, and is
neither fixed nor allowed to block the loop.

The reason is that **Deviations** records a decision the *user* made during the
implement phase, with the code in front of them. A review loop that fixed those
anyway would be overturning a human decision one session later and with less
context than the human had, while presenting itself as merely following the
spec. Where the section does not cover a finding, the normal rubric applies and
scope creep is still caught - which is exactly the distinction the section was
added to make.

## Consequences

The loop can finish, and mark a PR ready, while the spec has requirements that
were never implemented. That is the intended outcome, but it is only safe if it
is visible: every covered deviation is repeated in the loop's PR comment, so the
person merging sees "the spec asked for this and we deliberately did not" without
having to read a handoff file that is git-excluded and eventually archived.

The failure mode to watch for is the section being used to wave work through.
Its authority comes entirely from the user having agreed at implement time; an
implement phase that writes deviations the user never saw would launder scope
cuts into approved ones.
