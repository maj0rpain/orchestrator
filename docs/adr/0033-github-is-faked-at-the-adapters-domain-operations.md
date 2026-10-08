# GitHub is faked at the adapter's domain operations, not at the gh binary

Amended by #663: an operation prints plain text, except `adapter_issue_json`, whose JSON object is the shape `issue fetch --json` publishes.

orch.sh and doctor.sh reach GitHub only through adapter operations named for what their callers need; each owns gh's flags, `--jq` expressions, URL parsing and exit-code quirks, and prints plain text. Behaviour tests replace those operations in-process with a fake backed by a file store of issues, PRs, edges and checks - it parses none of gh's flags, only each operation's own arguments. Each real operation is pinned by a contract test against a fixture gh that answers by exact argv, which also proves the gh guard pins the repo. Rejected: a fake gh on PATH (`stub_gh`), which had to parse gh's flags and reproduce `--jq` output shapes, and which a second in-process fake had to mirror by hand.
