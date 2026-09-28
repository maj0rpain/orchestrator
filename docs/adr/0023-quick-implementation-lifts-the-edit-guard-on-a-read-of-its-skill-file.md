# Quick implementation lifts the edit guard on a read of its skill file

Supersedes ADR-0013: on Junie the edit guard now arms, so the premise that
nothing mechanical can arm it there no longer holds. Its flow-start
working-tree check stands, as the backstop wherever the guard does not arm.

Junie CLI build 3419.7 sends `session_id` on `PreToolUse`, though its bundled
docs still show the payload without one; a live denial on #260 established it,
since `hook-guard.sh` only denies with a session id. So the marker
`hook-grilling.sh` writes on Junie's `UserPromptSubmit` arms the guard there
too. We keep the live guard on Junie rather than disarming it again. But the
only thing that lifted it was `hook-quick-implement.sh` on a `PostToolUse`
`Skill` call (ADR-0006), and Junie has neither, so choosing quick
implementation left every source edit denied.

On a host with no Skill tool the model runs `orch-quick-implement` by reading
its `SKILL.md`, the path `hook-grilling.sh` hands it. That read is the choke
point Junie does have. `hook-quick-implement.sh` also runs as a `PreToolUse`
hook on `Read`, and deletes the session's marker when the read path -
`tool_input.file_path` or `tool_input.path`, a relative one resolved against
the working directory, normalized - is exactly
`<plugin_root>/skills/orch-quick-implement/SKILL.md`, where `<plugin_root>` is
the hook script's own plugin root. There is no host gate: Junie's `PreToolUse`
may lack `project_path`, which is how the hooks tell Junie apart, so the exact
installed path is the whole condition, on every host. The `Skill` trigger is
unchanged, and so is `hook-guard.sh`'s guarding logic (ADR-0006).

The guard's planning denial names both lifts on every host, since the host
cannot be told apart on Junie's `PreToolUse`: the `orchestrator:orch-quick-implement`
Skill call, and a Read of the installed `SKILL.md`. That also recovers a model
that loaded the skill through the shell instead.

## Considered Options

- **Disarm the guard on Junie again** by not writing the marker there.
  Rejected: the guard works on Junie now, and planning-time enforcement is
  what the guard is for; the flow-start check only catches edits after the
  fact.
- **Gate the Read lift to Junie.** Rejected: host detection rests on
  `project_path`, which Junie's `PreToolUse` may not carry, so the gate could
  fail on exactly the host it is for.
- **Match any `orch-quick-implement/SKILL.md`.** Rejected: reading a repo
  checkout's copy while working on this plugin would lift a planning session's
  guard.

## Consequences

On Claude Code, reading the installed `SKILL.md` with the Read tool also lifts
the guard. The model has no reason to read it there, and doing so is a
deliberate step toward quick implementation, which is what the lift stands
for. Which field Junie's `Read` names its path under is unverified, so the
hook accepts both `file_path` and `path`, as `hook-guard.sh` does for edits,
and `docs/host-capabilities.md` marks the row **Unverified** until a live run
confirms it. A model that reads the skill through `cat` does not lift the
guard; the denial tells it how to.
