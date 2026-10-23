# The autopilot watcher's image. Build context: the plugin root (see compose.yaml).
FROM node:22-bookworm-slim

ARG EXTRA_APT_PACKAGES=""

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl git gnupg jq \
 && mkdir -p -m 755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh $EXTRA_APT_PACKAGES \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code

# Claude Code refuses bypassPermissions as root, so the watcher runs as orch.
# The node base image ships a uid-1000 "node" user; drop it so orch can take 1000.
RUN userdel -r node 2>/dev/null; useradd --create-home --shell /bin/bash --uid 1000 orch \
 && mkdir -p /home/orch/repo \
 && chown -R orch:orch /home/orch

COPY --chown=orch:orch . /home/orch/orchestrator-src

USER orch
WORKDIR /home/orch

# Install the plugin from the build context as a local marketplace. There is no
# copy fallback: a failing step fails the build, naming the step.
# /home/orch/orchestrator is a stable link to the installed plugin root.
RUN set -eu; \
    version="$(jq -r .version /home/orch/orchestrator-src/.claude-plugin/plugin.json)"; \
    installed="/home/orch/.claude/plugins/cache/orchestrator/orchestrator/$version"; \
    claude plugin marketplace add /home/orch/orchestrator-src \
      || { echo "build failed: claude plugin marketplace add" >&2; exit 1; }; \
    claude plugin install orchestrator@orchestrator \
      || { echo "build failed: claude plugin install" >&2; exit 1; }; \
    [ -f "$installed/scripts/orch.sh" ] \
      || { echo "build failed: installed orch.sh not found at $installed/scripts/orch.sh" >&2; exit 1; }; \
    ln -s "$installed" /home/orch/orchestrator

ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
ENV CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING=1
ENV ORCH_SH=/home/orch/orchestrator/scripts/orch.sh

ENTRYPOINT ["/home/orch/orchestrator/scripts/autopilot-container.sh"]
