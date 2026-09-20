# Splitting long transaction-script command functions

This project does not split `orch.sh` command functions that combine
multi-way validation with a multi-step transaction into smaller functions,
even when a single function runs past what might read as "long" in
isolation.

## Why this is out of scope

`orch.sh` is written throughout as a transaction-script file: each command
function validates its preconditions with a case/switch, then runs its steps
top-to-bottom in one place, so the entire effect of running the command is
visible without following calls across functions. A long command function in
this style isn't a deviation to fix — it's the house style working as
intended. Splitting one out only makes it harder to see the whole
transaction at a glance, for the sake of a line count that isn't itself a
documented standard.

## Prior requests

- #64: "cmd_redo_review is a long method combining validation and a five-step transaction" — filed by the review loop as a Standards-axis nit against PR #56, with the reviewing sub-agent itself flagging that this looked in-pattern for the file
