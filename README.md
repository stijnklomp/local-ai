# Local AI

OpenCode running in a Docker Sandbox, with persistent agent memory powered by local Ollama models.

## Prerequisites

1. Run the install dependencies script on the host to install the required dependencies. This script is written for Linux, specifically Debian, and may not work on other operating systems.

```sh
./install-dependencies.sh

# Optional: flags can be chained
./install-dependencies.sh --skip-docker-sandbox
./install-dependencies.sh --skip-agentmemory
```

2. Copy the environment values from `agentmemory.env` into the agentmemory configuration:

```sh
cp agentmemory.env ~/.agentmemory/.env
```

## Setup with Docker Sandbox

### Ollama

Install [Ollama](https://ollama.com/).

Configure Ollama to listen on the host interface so that it can be accessed from the Docker Sandbox:

```sh
sudo systemctl edit ollama
```

Add:

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
```

Restart Ollama:

```sh
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Verify that Ollama is listening:

```sh
ss -tulpen | grep 11434
```

The output should show `0.0.0.0:11434` or `*:11434`.

### Firewall restrictions

Install [Uncomplicated Firewall](https://wiki.ubuntu.com/UncomplicatedFirewall) if it is not already installed:

```sh
sudo apt update
sudo apt install ufw
sudo ufw enable
```

Allow the Docker bridge network to access Ollama:

```sh
# Check the Docker bridge subnet
docker network inspect bridge | grep Subnet

# Replace 172.17.0.0/16 if your Docker bridge uses a different subnet
sudo ufw allow from 172.17.0.0/16 to any port 11434 proto tcp
```

Ensure UFW sees Docker traffic so that Docker does not bypass UFW rules:

```sh
sudo vi /etc/ufw/after.rules
```

Add near the top:

```text
# allow Docker bridge traffic to be filtered by UFW
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -j RETURN
COMMIT
```

Reload UFW:

```sh
sudo ufw reload
```

## Run/install an Ollama model

Install or run the model you want to use:

```sh
ollama run <model>
```

The Ollama server runs on the host and is accessed by the Docker Sandbox.

## Running OpenCode

Run from any project directory:

```sh
sbx run ./local-ai . ~/.config/opencode:ro
```

### Existing sandboxes

The launcher gives each project its own sandbox name based on the project directory. If a sandbox for the current project already exists, it is reused instead of creating a new one. This means running the launcher repeatedly from the same project directory will enter the existing sandbox.
