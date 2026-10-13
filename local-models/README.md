# Local Models

Host-side setup for running local LLM servers and connecting them to the OpenCode sandbox in [`../opencode-sandbox/`](../opencode-sandbox/).

Two runtimes are documented here:

- **Ollama** — general-purpose local runtime, used by agentmemory and OpenCode today.
- **llama.cpp adaptive KV streaming** — an experimental llama.cpp fork that runs a 27B model at up to 256K context on a 16 GB GPU by streaming the KV cache from pinned host RAM into a bounded GPU working set. See the [RTX 5080 guide](llama-cpp-adaptive-kv-streaming.md).

## How the sandbox reaches host services

The sandbox connects to host servers through the Docker bridge gateway (`172.17.0.1`), as configured in `../opencode-sandbox/opencode.json`:

| Server | URL used inside the sandbox |
| --- | --- |
| Ollama | `http://172.17.0.1:11434/v1` |
| llama.cpp `llama-server` (see guide) | `http://172.17.0.1:8080/v1` |

For this to work a server must listen on an address other than `127.0.0.1` (e.g. `0.0.0.0`) and the host firewall must allow the Docker bridge subnet.

## Ollama

### Install Ollama

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

## Firewall restrictions

Install [Uncomplicated Firewall](https://wiki.ubuntu.com/UncomplicatedFirewall) if it is not already installed:

```sh
sudo apt update
sudo apt install ufw
sudo ufw enable
```

Allow the Docker bridge network to access local model servers:

```sh
# Check the Docker bridge subnet
docker network inspect bridge | grep Subnet

# Replace 172.17.0.0/16 if your Docker bridge uses a different subnet
sudo ufw allow from 172.17.0.0/16 to any port 11434 proto tcp   # Ollama
sudo ufw allow from 172.17.0.0/16 to any port 8080 proto tcp    # llama.cpp llama-server
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

agentmemory uses the model selected in `../opencode-sandbox/agentmemory.env` (`OPENAI_MODEL`). That file lists the VRAM sizes, context lengths and headroom for the supported choices on a 16 GB card.
