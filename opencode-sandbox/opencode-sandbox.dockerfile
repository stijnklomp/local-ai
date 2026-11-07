# syntax=docker/dockerfile:1
# Docker's published shell workload supplies the sbx platform floor: bash,
# the agent user (uid 1000), git, a CA store, Node 24, npm, Docker and gh.
# It is a regular public image on Docker Hub, so local builds need no DHI
# registry login. The inherited com.docker.sandboxes.start-docker label is
# what asks the current sbx runtime to start Docker; dockerd@1 is not yet
# implemented by sbx 0.51.0.
FROM docker.io/docker/sbx-kit-shell:1.0.0

ARG OPENCODE_VERSION
ARG AGENTMEMORY_VERSION

USER root

# OpenCode 2 is distributed as @opencode/cli, separately from the v1
# opencode-ai package, so there is no v1 install to remove. Run npm with a
# root-only HOME so no root-owned cache lands in the agent's home. npm's
# postinstall copies the matching platform binary into place.
RUN export HOME=/root \
 && npm install -g \
      "@opencode/cli@${OPENCODE_VERSION}" \
      "@agentmemory/agentmemory@${AGENTMEMORY_VERSION}" \
      --no-fund --no-audit \
 && opencode --version | grep -Fq "${OPENCODE_VERSION}" \
 && agentmemory --version 2>/dev/null | grep -Fq "${AGENTMEMORY_VERSION}" \
 && rm -rf /root/.npm /root/.cache

# sbx launches the agent under bash and sources BASH_ENV, so this block is
# the one place that turns the read-only host mount into runtime environment:
# the host config path, the agentmemory API secret and the optional websearch
# provider keys. The values stay on the host; only this logic is baked in.
RUN cat >> /etc/sandbox-persistent.sh <<'EOF'

# opencode-sandbox: read host-side settings from the read-only config mount.
if [ -n "${OPENCODE_SANDBOX_HOST_HOME:-}" ]; then
  export OPENCODE_CONFIG="$OPENCODE_SANDBOX_HOST_HOME/.config/opencode/opencode.json"
  if [ -r "$OPENCODE_SANDBOX_HOST_HOME/.config/opencode/agentmemory-secret" ]; then
    AGENTMEMORY_SECRET=$(cat "$OPENCODE_SANDBOX_HOST_HOME/.config/opencode/agentmemory-secret")
    export AGENTMEMORY_SECRET
  fi
  if [ -r "$OPENCODE_SANDBOX_HOST_HOME/.config/opencode/websearch.env" ]; then
    set -a
    . "$OPENCODE_SANDBOX_HOST_HOME/.config/opencode/websearch.env"
    set +a
  fi
fi
EOF

# The agentmemory MCP client and the capture plugin both read this URL.
ENV AGENTMEMORY_URL=http://host.docker.internal:3111

USER agent
WORKDIR /home/agent/workspace
# The base's CMD is "-l" for its bash entrypoint; clear it so the launch
# command is exactly `opencode` (plus any agent arguments after --).
ENTRYPOINT ["opencode"]
CMD []
