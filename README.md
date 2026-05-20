# Local AI

## Recommended models for "RTX 5080 16GB vRAM" GPU

Coding:

- qwen2.5-coder:32b
- qwen2.5-coder:72b (If available but slower)

General:

- llama3.1:70b
- llama3.1:8b (for speed)


## Setup with Docker sandbox

Install [Ollama](https://ollama.com/) and [Docker sandbox](https://docs.docker.com/ai/sandboxes/get-started/)
Edit Ollama config:

```sh
sudo systemctl edit ollama
```

Add:

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
```

Restart:

```sh
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Verify it's setup correctly:

```sh
ss -tulpen | grep 11434 # 0.0.0.0:11434 or *:11434
```

### Firewall restrictions

Install [Uncomplicated Firewall](https://wiki.ubuntu.com/UncomplicatedFirewall) if you don't already have it:

```sh
sudo apt update
sudo apt install ufw
sudo ufw enable
```

Allow Docker bridge network:

```sh
# You can check all Docker networks
docker network inspect bridge | grep Subnet

sudo ufw allow from 172.17.0.0/16 to any port 11434 proto tcp # "172.17.0.0/16" being the default Docker subnet
```

Ensure UFW sees Docker traffic (to prevent Docker from bypassing UFW):

```sh
sudo vi /etc/ufw/after.rules
```

Add near top:

```
# allow Docker bridge traffic to be filtered by UFW
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -j RETURN
COMMIT
```

Reload:

```sh
sudo ufw reload
```

## Run/install Ollama model

```sh
ollama run <model>
```

## Run Docker sandbox with OpenCode

Create an [OpenCode config file](https://opencode.ai/docs/config/) at `~/.config/opencode/opencode.json`:

opencode.json
```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://host.docker.internal:11434/v1"
      },
      "models": {
        ...
      }
    }
  }
}
```

Run Docker Sandbox with OpenCode: (Automatically mounts current directory)

```sh
cp ~/.config/opencode/opencode.json . && sbx run opencode
```

## Run Docker sandbox with OpenCode and agent memory

Follow through all "Run Docker sandbox with OpenCode" steps except for running running the sandbox.

From current repo:
```sh
export LOCAL_AI_REPO_PATH="<path-to-local-ai-repo>"
export AGENT_MEMORY_HOOKS_NEO4J_REPO_PATH="<path-to-agent-memory-hooks-neo4j-repo>"
export OPENCODE_CONFIG_DIR="$HOME/.config/opencode"

sudo mkdir -p "$OPENCODE_CONFIG_DIR/.opencode/plugins"
sudo mkdir -p "$OPENCODE_CONFIG_DIR/hooks"
sudo mkdir -p "$OPENCODE_CONFIG_DIR/plugins"
sudo mkdir -p "$OPENCODE_CONFIG_DIR/dream"

sudo cp "$LOCAL_AI_REPO_PATH/docker-compose.yml" "$OPENCODE_CONFIG_DIR/docker-compose.yml"
sudo cp "$LOCAL_AI_REPO_PATH/Dockerfile.dream" "$OPENCODE_CONFIG_DIR/Dockerfile.dream"

sudo cp "$AGENT_MEMORY_HOOKS_NEO4J_REPO_PATH/.opencode/plugins/neo4j-memory.js" "$OPENCODE_CONFIG_DIR/.opencode/plugins/neo4j-memory.js"
sudo cp "$AGENT_MEMORY_HOOKS_NEO4J_REPO_PATH/hooks/inject_memory.js" "$OPENCODE_CONFIG_DIR/hooks/"
sudo cp "$AGENT_MEMORY_HOOKS_NEO4J_REPO_PATH/hooks/log_event.py" "$OPENCODE_CONFIG_DIR/hooks/"
sudo cp "$AGENT_MEMORY_HOOKS_NEO4J_REPO_PATH/dream/dream.py" "$OPENCODE_CONFIG_DIR/dream/"
```

Run Docker Sandbox with OpenCode: (Automatically mounts current directory)

```sh
./run-opencode-in-docker-sandbox.sh
```

Run Dream phase: (Used for consolidating memory)

```sh
docker compose run --rm dream --since 24h --dry-run
docker compose run --rm dream --context my-project
```

### Directly (from inside the Docker Sandbox or host)

```sh
python dream/dream.py
python dream/dream.py --since 24h
python dream/dream.py --context my-project --dry-run
```
