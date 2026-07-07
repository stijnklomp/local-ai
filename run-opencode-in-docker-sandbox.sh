#!/bin/bash
set -euo pipefail

LOCAL_AI_REPO_DIR="$HOME/developer/personal/local-ai"
OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
OPENCODE_APPLICATION_DATA_DIR="$HOME/.local/share/opencode"

AGENTMEMORY_DIR="$HOME/.local/share/agentmemory"
SANDBOX_NAME="opencode-$(basename $PWD)"

if ! curl -s http://localhost:3111/agentmemory/health > /dev/null; then
  echo "agentmemory is not running. Starting background daemon..."

  mkdir -p "$AGENTMEMORY_DIR"

  export LLM_PROVIDER="ollama"
  export LLM_MODEL="deepseek-r1:32b"
  export HOST="0.0.0.0"

  (cd "$AGENTMEMORY_DIR" && nohup npx @agentmemory/agentmemory > /tmp/agentmemory_daemon.log 2>&1 &)

  echo "Waiting for agentmemory to initialize..."

  ready=false
  for i in $(seq 1 90); do
    if curl -fsS http://localhost:3111/agentmemory/health >/dev/null 2>&1; then
      echo "agentmemory is online."
      ready=true
      break
    fi
    sleep 1
  done

  if [ "$ready" != true ]; then
    echo "ERROR: agentmemory took too long to start." >&2
    echo "Last 40 lines of /tmp/agentmemory_daemon.log:" >&2
    tail -40 /tmp/agentmemory_daemon.log >&2
    exit 1
  fi
else
  echo "agentmemory is already running."
fi

SKIP_SKILLS_PATH=false
for arg in "$@"; do
  if [ "$arg" = "--skip-skills-path" ]; then
    SKIP_SKILLS_PATH=true
    break
  fi
done

if ! sbx ls | grep -q "^$SANDBOX_NAME "; then
  sbx create opencode .

  # Loop up to 30 seconds waiting for apt/dpkg locks to clear
  for i in $(seq 1 30); do
    if sbx exec "$SANDBOX_NAME" -- sudo fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; then
      echo "Apt is busy, waiting 1s..."
      sleep 1
    else
      break
    fi
  done

  sbx exec "$SANDBOX_NAME" -- sudo apt-get update -y
  sbx exec "$SANDBOX_NAME" -- sudo apt-get install -y socat
  echo "socat installed."

  AGENTMEMORY_MCP_TARBALL="$LOCAL_AI_REPO_DIR/dependencies/agentmemory-mcp.tar.gz"

  if [ ! -f "$AGENTMEMORY_MCP_TARBALL" ]; then
    echo "ERROR: $AGENTMEMORY_MCP_TARBALL not found. Run install-dependencies.sh first." >&2
    exit 1
  fi
 
  cp "$AGENTMEMORY_MCP_TARBALL" ./agentmemory-mcp-tmp.tar.gz
  sbx exec "$SANDBOX_NAME" -- sudo mkdir -p /usr/local/lib/agentmemory-mcp
  sbx exec "$SANDBOX_NAME" -- sudo tar -xzf "$PWD/agentmemory-mcp-tmp.tar.gz" -C /usr/local/lib/agentmemory-mcp
  sbx exec "$SANDBOX_NAME" -- sudo ln -sf /usr/local/lib/agentmemory-mcp/bin/agentmemory /usr/local/bin/agentmemory
  rm -f ./agentmemory-mcp-tmp.tar.gz
  echo "agentmemory installed."

  sbx exec "$SANDBOX_NAME" -- sudo mkdir -p /home/agent/.config/opencode/skills
  sbx exec "$SANDBOX_NAME" -- sudo mkdir -p /home/agent/.config/opencode/plugins
  sbx exec "$SANDBOX_NAME" -- sudo mkdir -p /home/agent/.config/opencode/commands
  sbx exec "$SANDBOX_NAME" -- sudo mkdir -p /home/agent/.local/share/opencode
  sbx exec "$SANDBOX_NAME" -- sudo chown -R agent:agent /home/agent/.config
  sbx exec "$SANDBOX_NAME" -- sudo chown -R agent:agent /home/agent/.local
fi

sbx cp "$OPENCODE_CONFIG_DIR/opencode.json" "$SANDBOX_NAME:/home/agent/.config/opencode/opencode.json"

if [ -d "$OPENCODE_CONFIG_DIR/skills" ]; then
    sbx cp "$OPENCODE_CONFIG_DIR/skills/." "$SANDBOX_NAME:/home/agent/.config/opencode/skills"
fi

if [ -d "$OPENCODE_CONFIG_DIR/plugins" ]; then
    sbx cp "$OPENCODE_CONFIG_DIR/plugins/." "$SANDBOX_NAME:/home/agent/.config/opencode/plugins"
fi

if [ -d "$OPENCODE_CONFIG_DIR/commands" ]; then
    sbx cp "$OPENCODE_CONFIG_DIR/commands/." "$SANDBOX_NAME:/home/agent/.config/opencode/commands"
fi

sbx cp "$OPENCODE_APPLICATION_DATA_DIR/auth.json" "$SANDBOX_NAME:/home/agent/.local/share/opencode/auth.json"

if [ "$SKIP_SKILLS_PATH" = false ] && [ ! -f "opencode.json" ]; then
  sbx cp "$LOCAL_AI_REPO_DIR/opencode_skills_path.json" "$SANDBOX_NAME:$PWD/opencode.json"
  if command -v git &>/dev/null && ! git rev-parse --git-dir &>/dev/null; then
    git init
  fi
else
  echo "Skipping opencode.json copy (either omitted by flag or file already exists locally)."
fi

# Kill any existing socat instance from previous runs
sbx exec "$SANDBOX_NAME" -- pkill -f "socat TCP-LISTEN:3111" || true

# Start socat in the background inside the sandbox
sbx exec "$SANDBOX_NAME" -- bash -c \
  "nohup socat TCP-LISTEN:3111,fork,reuseaddr TCP:host.docker.internal:3111 > /tmp/socat_proxy.log 2>&1 &"
sbx exec "$SANDBOX_NAME" -- bash -c "echo '127.0.0.1 localhost' | sudo tee -a /etc/hosts"

sbx run "$SANDBOX_NAME"
