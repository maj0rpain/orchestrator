# orchestrator on the Junie CLI

"Junie" in the orchestrator's docs and across the plugin means the Junie CLI,
not the Junie plugin for JetBrains IDEs. Junie CLI support rests on its
bundled documentation, and some of it is unverified (see
[docs/host-capabilities.md](../host-capabilities.md)). How doctor detects the
host, and why the whole plugin must be installed, is in
[docs/how-it-works.md's Hosts section](../how-it-works.md#hosts).

## The AGENTS.md snippet

Junie loads the plugin's `agents/`, but a capability filter at agent start
usually hides them from the model, so the flow starts a general-purpose agent
briefed with the agent's file instead. JetBrains tracks this as
[JUNIE-5493](https://youtrack.jetbrains.com/issue/JUNIE-5493); until it is
fixed, append the plugin's snippet [AGENTS.md](AGENTS.md), beside this file,
to your user-scoped `~/.junie/AGENTS.md`. It tells Junie each skill needs its
custom agents, and also carries a standing planning section and a standing
finding-the-plugin section: where `orch.sh` is, and what to do when an orch-*
skill or agent is hidden:

```
cat "$HOME"/.junie/extensions/*/orchestrator/docs/junie/AGENTS.md >> ~/.junie/AGENTS.md
```

If the glob matches more than one install, pick one path and `cat` only that.
The snippet sits between `<!-- orchestrator:begin -->` and
`<!-- orchestrator:end -->` markers, so it can be replaced cleanly; its
custom-agents section goes once JUNIE-5493 is fixed.

As a fallback, naming the agent in your own prompt keeps it visible, for
example "For step 4, start the custom agent orch-implementer by name." Naming
it in a skill does not.

## Agent settings on Junie

Junie has its own agent setting, kept beside Claude Code's: a model and a
reasoning effort per role, set with `--host junie`. For example, to run the
reviewers on `gpt-5` at high effort:

```
orch.sh agent set reviewer --host junie --model gpt-5 --effort high
```

That stores `orchestrator.junie.model.reviewer` and
`orchestrator.junie.effort.reviewer` in git config and runs `orch.sh agent
sync`, which writes generated copies of the role's agents into the checkout's
`.junie/agents/` (git-excluded, never committed). Junie runs a project copy in
place of the plugin's agent of the same name. On Junie every skill runs
`agent sync` once per run, before its first plugin agent.

A model is a Junie LLM name or `custom:<profile-id>`, never an alias: Junie's
aliases resolve unpredictably (`opus` runs an old Opus). LLM names come from
Junie's `/model` picker, its `--model` flag, and the `Allowed LLM names` list
Junie logs when it does not recognise a value. The effort is `low`, `medium` or
`high`; `inherit` clears a key.

An unknown model name falls back silently to the session's model, and the
subagent still reports success. To check the setting took:

- Run `orch.sh doctor`. It lists each role's Junie setting, warns when the
  checkout's copies are missing, stale or extra, shows what each `orch-*` agent
  ran on in your last Junie session, and fails on a model Junie did not
  recognise.
- Look at the agent block in Junie's TUI.
- Read `~/.junie/sessions/<id>/events.jsonl`.
