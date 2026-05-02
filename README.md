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

## Run Ollama model

```sh
ollama run <model>
```

## Run Docker sandbox with OpenCode

Create an [OpenCode config file](https://opencode.ai/docs/config/) at the project directory:

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

Run Docker Sandbox with OpenCode:

```sh
sbx run opencode
```
