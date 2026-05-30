# Local AI

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

## Run Docker sandbox with Opencode (and local agent memory)

Create an [Opencode config file](https://opencode.ai/docs/config/) at `~/.config/opencode/opencode.json`:
*Note that you can copy the one from this repository.*

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

Run Docker Sandbox with Opencode from your desired directory: (Automatically mounts current directory)

```sh
# Update `LOCAL_AI_REPO_DIR` in the file first before running any of the following commands

./run-opencode-in-docker-sandbox.sh

# By default the `opencode_skills_path.json` file is copied into the working directory as `opencode.json`. This is useful when working with multiple git repos as child directories as it allows you to update the "skills" key to tell Opencode to look for skills in the child git repos. To not include this, specify the `--skip-skills-path` flag
# Note that if an opencode.json already exists in the current working directory then it won't copy it in even if the flag is not provided. This allows you to update the file to include the git sub directories and load the Docker Sandbox without it overriding it.
# Note that it initializes a git repository in the current working directory if it is not already a git repo, unless the `--skip-skills-path` flag is provided, as this is required for Opencode to pick up on the opencode.json file in the current working directory
# Replace "project/.opencode/skills" in `opencode_skills_path.json` with the sub-directory you have. Add more entries for more sub-directories.
./run-opencode-in-docker-sandbox.sh --skip-skills-path

# Use with local memory and context injection
./run-opencode-in-docker-sandbox.sh --use-local-memory
```

Update the Docker Sandbox image:
```sh
docker pull docker/sandbox-templates:opencode
```

## Instructions when running the local memory
### Run Dream phase: (Used for consolidating memory)

Directly from inside the Docker Sandbox:

```sh
docker build -t dream-phase -f Dockerfile.dream . && docker run dream-phase --model qwen3:14b-fp16 --context my-project
```

### Wipe all memory

Run on host:

```sh
# Remove all current memories
curl -s -u neo4j:password \
  -H "Content-Type: application/json" \
  -X POST http://localhost:7474/db/neo4j/tx/commit \
  -d '{"statements":[{"statement":"MATCH (m:Memory) DETACH DELETE m"}]}'

# Reset watermarks so all sessions reprocess
curl -s -u neo4j:password \
  -H "Content-Type: application/json" \
  -X POST http://localhost:7474/db/neo4j/tx/commit \
  -d '{"statements":[{"statement":"MATCH (s:Session) REMOVE s.dream_watermark"}]}'
```

### Open UI

```sh
open file:///home/stijn/developer/personal/local-ai/neo4j_memory_manager.html
```

## Recommendations

- It's advised to add the following to your global gitignore:

```sh
hooks/
dream/
```
