#!/bin/bash
set -euo pipefail

LOCAL_AI_REPO_DIR="$HOME/developer/personal/local-ai"
DEPENDENCIES_DIR="$LOCAL_AI_REPO_DIR/dependencies"

AGENTMEMORY_MCP_PREFIX="$DEPENDENCIES_DIR/DockerSandboxes-linux-amd64-ubuntu2604.deb"

curl -L https://github.com/docker/sbx-releases/releases/download/v0.31.1/DockerSandboxes-linux-amd64-ubuntu2604.deb -o "$AGENTMEMORY_MCP_PREFIX"
sudo apt install "$AGENTMEMORY_MCP_PREFIX"
rm "$AGENTMEMORY_MCP_PREFIX"

npm install -g @agentmemory/agentmemory

AGENTMEMORY_MCP_PREFIX="$DEPENDENCIES_DIR/agentmemory-mcp-prefix"
AGENTMEMORY_MCP_TARBALL="$DEPENDENCIES_DIR/agentmemory-mcp.tar.gz"

rm -rf "$AGENTMEMORY_MCP_PREFIX"
mkdir -p "$AGENTMEMORY_MCP_PREFIX"

npm install -g --prefix "$AGENTMEMORY_MCP_PREFIX" @agentmemory/agentmemory

tar -czf "$AGENTMEMORY_MCP_TARBALL" -C "$AGENTMEMORY_MCP_PREFIX" .

if ! tar -tzf "$AGENTMEMORY_MCP_TARBALL" > /dev/null; then
    echo "ERROR: $AGENTMEMORY_MCP_TARBALL failed integrity check after creation." >&2
    exit 1
fi

rm -rf "$AGENTMEMORY_MCP_PREFIX"