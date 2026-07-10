# Local AI

OpenCode running in a Docker sandbox, with persistent agent memory powered by local Ollama models.

## Prerequisites

1. Run the install dependencies script one on the host to install all the required depenencies. (This script is written for Linux, specifically Debian. It may not work for another OS)

```sh
./install-dependencies.sh
```

2. Copy the environment values from the `agentmemory.env` file into `~/.agentmemory/.env`:

```sh
cp agentmemory.env ~/.agentmemory/.env
```

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

## Run Docker sandbox with Opencode

- Create an [Opencode config file](https://opencode.ai/docs/config/) at `~/.config/opencode/opencode.json`:
*Note that you can copy the one from this repository.*

- Copy the plugin(s) in `plugins/` to `~/.config/opencode/plugins/`. (Create the directory if it doesn't exist already)

- Run Docker Sandbox with Opencode from your desired directory: (Automatically mounts current directory)

```sh
# Update `LOCAL_AI_REPO_DIR` in the file first before running any of the following commands

./run-opencode-in-docker-sandbox.sh

# By default the `opencode_skills_path.json` file is copied into the working directory as `opencode.json`. This is useful when working with multiple git repos as child directories as it allows you to update the "skills" key to tell Opencode to look for skills in the child git repos. To not include this, specify the `--skip-skills-path` flag
# Note that if an opencode.json already exists in the current working directory then it won't copy it in even if the flag is not provided. This allows you to update the file to include the git sub directories and load the Docker Sandbox without it overriding it.
# Note that it initializes a git repository in the current working directory if it is not already a git repo, unless the `--skip-skills-path` flag is provided, as this is required for Opencode to pick up on the opencode.json file in the current working directory
# Replace "project/.opencode/skills" in `opencode_skills_path.json` with the sub-directory you have. Add more entries for more sub-directories.

# By default the script kills stale socat child processes (accumulated from fork,reuseaddr) before starting a fresh one. To skip this, pass --no-kill-socat:
./run-opencode-in-docker-sandbox.sh --no-kill-socat

# Flags can be combined:
./run-opencode-in-docker-sandbox.sh --skip-skills-path --no-kill-socat
```

## Update Docker Sandbox image

```sh
docker pull docker/sandbox-templates:opencode
```

## agentmemory

Open UI:

```sh
open http://localhost:3113/#dashboard
```

(RUNS AUTOMATICALLY — only needed for manual testing) consolidate-pipeline — Runs the 4-tier memory pipeline: (1) shift episodic observations into semantic facts, (2) detect procedural patterns across sessions, (3) apply memory decay, (4) reflect on clusters to synthesize insights.

```sh
curl -X POST http://localhost:3111/agentmemory/consolidate-pipeline \
  -H "Content-Type: application/json" \
  -d '{"tier":"all","force":true}'
```

(RUNS AUTOMATICALLY — only needed for manual testing) crystals/auto — Compresses completed action chains into compact "crystal" digests (narrative + outcomes + files affected + lessons). These keep long-term context without raw action bloat.

```sh
curl -X POST http://localhost:3111/agentmemory/crystals/auto \
  -H "Content-Type: application/json" \
  -d '{"olderThanDays":0}'
```