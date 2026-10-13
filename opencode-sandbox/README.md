# OpenCode Sandbox

OpenCode running in a Docker Sandbox, with persistent agent memory powered by agentmemory.

## Prerequisites

1. Run the install dependencies script on the host to install the required dependencies. This script is written for Linux, specifically Debian, and may not work on other operating systems. It installs Docker Sandbox (`sbx`) 0.48.0 or later; the sandbox kit uses schema v2 kit arguments, which need sbx 0.45.0+.

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

## Local models

The Ollama setup, firewall rules and model instructions live in [`../local-models/README.md`](../local-models/README.md). The sandbox reaches host-run model servers through the Docker bridge gateway (`172.17.0.1`), which is why those servers must listen on `0.0.0.0` and why the host firewall must allow the bridge subnet.

## Running OpenCode

Run from any project directory:

```sh
local-ai/opencode-sandbox/run-opencode-in-docker-sandbox.sh
```

The launcher passes `--kit-arg home="$HOME"` when it creates a sandbox, so the kit config adapts to the host user. Run the launcher itself rather than calling `sbx run` on the kit directly, otherwise the required `home` argument is not supplied.

### Syncing repo config to the host

The sandbox reads OpenCode config, plugins and commands from the host at `~/.config/opencode` (mounted read-only), not from this repo. After repo changes, run the sync script on the host:

```sh
./sync-config.sh
```

It copies `opencode.json`, `plugins/` and `commands/` into `~/.config/opencode`, overwriting existing files and leaving other files in those directories alone. If you have customized `opencode.json`, merge your changes manually. The script is only ever run manually; nothing invokes it automatically. Changes apply the next time OpenCode starts; no sandbox rebuild is needed.

### agentmemory is optional

agentmemory does not have to be running to use the sandbox. If the host health check fails, the launcher prints a note and starts anyway. Inside the sandbox the agentmemory MCP then falls back to a reduced sandbox-local toolset (explicit saves only, kept inside the sandbox and never synced to the host) and automatic session capture pauses. The full toolset and capture resume automatically once the host server is reachable again.

### agentmemory API secret note (no-op)

agentmemory v0.9.30 authenticates its REST API. On every launch, the launcher resolves the host secret (`AGENTMEMORY_SECRET` from the environment, else from `~/.agentmemory/.env`, else from `~/.agentmemory/secret`) and writes it to `~/.config/opencode/agentmemory-secret` (mode 0600, inside the read-only mount). The sandbox exports it as `AGENTMEMORY_SECRET` at startup so the MCP client and the capture plugin can authenticate. If you rotate the secret, re-run the launcher and restart the sandbox.

Spec changes only apply when a sandbox is (re)created: remove an existing sandbox with `sbx rm <name>` before relaunching to pick them up. Sandboxes created before the kit-argument change keep working; recreate them through the launcher to move to the portable spec.

### Existing sandboxes

The launcher gives each project its own sandbox name based on the project directory. If a sandbox for the current project already exists, it is reused instead of creating a new one. This means running the launcher repeatedly from the same project directory will enter the existing sandbox.
