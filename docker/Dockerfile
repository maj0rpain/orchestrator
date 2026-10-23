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

COPY --chown=orch:orch . /tmp/orchestrator-src

USER orch
WORKDIR /home/orch

# Install the plugin from the build context as a local marketplace. If the CLI
# cannot do that non-interactively, copy it into the plugin cache layout.
# /home/orch/orchestrator is a stable link to whichever root results.
RUN set -eu; \
    version="$(jq -r .version /tmp/orchestrator-src/.claude-plugin/plugin.json)"; \
    if claude plugin marketplace add /tmp/orchestrator-src \
       && claude plugin install orchestrator@orchestrator \
       && [ -f "/home/orch/.claude/plugins/cache/orchestrator/orchestrator/$version/scripts/orch.sh" ]; then \
      ln -s "/home/orch/.claude/plugins/cache/orchestrator/orchestrator/$version" /home/orch/orchestrator; \
    else \
      dest="/home/orch/.claude/plugins/cache/orchestrator/orchestrator/$version"; \
      mkdir -p "$dest"; \
      cp -a /tmp/orchestrator-src/. "$dest"/; \
      ln -sfn "$dest" /home/orch/orchestrator; \
    fi; \
    rm -rf /tmp/orchestrator-src

ENV ORCH_SH=/home/orch/orchestrator/scripts/orch.sh

ENTRYPOINT ["/home/orch/orchestrator/scripts/autopilot-container.sh"]
