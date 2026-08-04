#!/bin/bash
set -euo pipefail

LOCAL_AI_REPO_DIR="$HOME/developer/personal/local-ai"
DEPENDENCIES_DIR="$LOCAL_AI_REPO_DIR/dependencies"

AGENTMEMORY_VERSION="0.9.28"

SKIP_DOCKER_SANDBOX=false
SKIP_AGENTMEMORY=false
for arg in "$@"; do
  case "$arg" in
    --skip-docker-sandbox) SKIP_DOCKER_SANDBOX=true ;;
    --skip-agentmemory) SKIP_AGENTMEMORY=true ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--skip-docker-sandbox] [--skip-agentmemory]" >&2
      exit 1
      ;;
  esac
done

if [ "$SKIP_DOCKER_SANDBOX" = false ]; then
  DOCKER_SANDBOX_INSTALL="$DEPENDENCIES_DIR/DockerSandboxes-linux-amd64-ubuntu2604.deb"

  curl -L https://github.com/docker/sbx-releases/releases/download/v0.31.1/DockerSandboxes-linux-amd64-ubuntu2604.deb -o "$DOCKER_SANDBOX_INSTALL"
  sudo apt install "$DOCKER_SANDBOX_INSTALL"
  rm "$DOCKER_SANDBOX_INSTALL"
else
  echo "Skipping Docker Sandbox install (--skip-docker-sandbox)."
fi

if [ "$SKIP_AGENTMEMORY" = false ]; then
  npm install -g @agentmemory/agentmemory@"$AGENTMEMORY_VERSION"

  AGENTMEMORY_MCP_PREFIX="$DEPENDENCIES_DIR/agentmemory-mcp-prefix"
  AGENTMEMORY_MCP_TARBALL="$DEPENDENCIES_DIR/agentmemory-mcp.tar.gz"
  AGENTMEMORY_MCP_TARBALL_TMP="${AGENTMEMORY_MCP_TARBALL}.tmp"

  rm -rf "$AGENTMEMORY_MCP_PREFIX"
  mkdir -p "$AGENTMEMORY_MCP_PREFIX"
  npm install -g --prefix "$AGENTMEMORY_MCP_PREFIX" @agentmemory/agentmemory@"$AGENTMEMORY_VERSION"
  tar -czf "$AGENTMEMORY_MCP_TARBALL_TMP" -C "$AGENTMEMORY_MCP_PREFIX" .

  if ! tar -tzf "$AGENTMEMORY_MCP_TARBALL_TMP" > /dev/null; then
      echo "ERROR: $AGENTMEMORY_MCP_TARBALL_TMP failed integrity check after creation." >&2
      rm -f "$AGENTMEMORY_MCP_TARBALL_TMP"
      exit 1
  fi

  mv "$AGENTMEMORY_MCP_TARBALL_TMP" "$AGENTMEMORY_MCP_TARBALL"
  echo "OK: archive is valid"
  rm -rf "$AGENTMEMORY_MCP_PREFIX"
else
  echo "Skipping agentmemory MCP install (--skip-agentmemory)."
fi
