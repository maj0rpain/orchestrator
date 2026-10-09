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
