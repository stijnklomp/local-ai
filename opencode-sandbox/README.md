# OpenCode Sandbox

OpenCode 2 running in a Docker Sandbox, with persistent agent memory powered by agentmemory.

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

The sandbox image ships OpenCode 1; the kit setup replaces it with the pinned OpenCode 2 CLI (`@opencode/cli` 2.0.29, pinned in `spec.yaml`). OpenCode 2 is distributed separately from OpenCode 1: GitHub Releases only lists 1.x, and `npm install -g @opencode/cli` is the v2 package.

## Local models

The Ollama setup, firewall rules and model instructions live in [`../local-models/README.md`](../local-models/README.md). The sandbox reaches host-run model servers through the Docker bridge gateway (`172.17.0.1`), which is why those servers must listen on `0.0.0.0` and why the host firewall must allow the bridge subnet.

## Running OpenCode

Run from any project directory:

```sh
local-ai/opencode-sandbox/run-opencode-in-docker-sandbox.sh
```

The launcher passes `--kit-arg home="$HOME"` when it creates a sandbox, so the kit config adapts to the host user. Run the launcher itself rather than calling `sbx run` on the kit directly, otherwise the required `home` argument is not supplied.

### Syncing repo config to the host

The sandbox reads OpenCode config, global instructions, plugins and commands from the host at `~/.config/opencode` (mounted read-only), not from this repo. After repo changes, run the sync script on the host:

```sh
./sync-config.sh
```

It copies `opencode.json`, `global-AGENTS.md` (as `AGENTS.md`), `plugins/` and `commands/` into `~/.config/opencode`, overwriting existing files and leaving other files in those directories alone. If you have customized `opencode.json`, merge your changes manually. The script is only ever run manually; nothing invokes it automatically. Changes apply the next time OpenCode starts; no sandbox rebuild is needed.

### OpenCode 2 specifics

- `opencode.json` uses the native OpenCode 2 format: `providers`, `mcp.servers`, an ordered `permissions` array, `policies` (provider allowlist) and `update: "disable"`. OpenCode 2 still normalizes the v1 shapes, but this repo keeps the native format. Do not point an OpenCode 1 installation at this config; keep v1 usage on a separate config file.
- OpenCode 2 ignores the `instructions` config field. Global instructions live in `global-AGENTS.md`, which syncs to `~/.config/opencode/AGENTS.md` (OpenCode 2 discovers that file globally). The kit symlinks it into the sandbox home config directory.
- OpenCode 1 plugin implementations do not run in OpenCode 2. `plugins/agentmemory-capture.ts` is written against the OpenCode 2 plugin API (`@opencode/plugin` 2.0.29) and is loaded from the global `~/.config/opencode/plugins/` directory.
- The agentmemory MCP server sets `codemode: false` so its tools stay on the model's native tool list as `agentmemory_memory_*`; `/recall` and `/remember` and the tool deny rules depend on those names.
- Capture mapping changed with the v2 event stream: sessions start/end from `session.created`/`session.deleted`, idle summarization from `session.status`/`session.idle`, compaction from `session.compaction.*`, assistant steps from `session.step.ended`, reasoning from `session.reasoning.ended`, permission prompts from `permission.asked`/`permission.replied`, and file changes from `filesystem.changed`. Tool calls, prompts, model params and compaction enrichment are captured through plugin hooks (`prompt`, `context`, `compaction`, `tool.execute.before`/`after`). The v1-only `command.executed` observation has no v2 equivalent; todo updates are captured as `todowrite` tool calls.

Spec changes only apply when a sandbox is (re)created: remove an existing sandbox with `sbx rm <name>` before relaunching to pick them up. This upgrade needs a recreation, because the kit setup installs OpenCode 2. Sandboxes created before the kit-argument change keep working; recreate them through the launcher to move to the portable spec.

### agentmemory is optional

agentmemory does not have to be running to use the sandbox. If the host health check fails, the launcher prints a note and starts anyway. Inside the sandbox the agentmemory MCP then falls back to a reduced sandbox-local toolset (explicit saves only, kept inside the sandbox and never synced to the host) and automatic session capture pauses. The full toolset and capture resume automatically once the host server is reachable again.

### agentmemory API secret note (no-op)

agentmemory v0.9.30 authenticates its REST API. On every launch, the launcher resolves the host secret (`AGENTMEMORY_SECRET` from the environment, else from `~/.agentmemory/.env`, else from `~/.agentmemory/secret`) and writes it to `~/.config/opencode/agentmemory-secret` (mode 0600, inside the read-only mount). The sandbox exports it as `AGENTMEMORY_SECRET` at startup so the MCP client and the capture plugin can authenticate. If you rotate the secret, re-run the launcher and restart the sandbox.

### Existing sandboxes

The launcher gives each project its own sandbox name based on the project directory. If a sandbox for the current project already exists, it is reused instead of creating a new one. This means running the launcher repeatedly from the same project directory will enter the existing sandbox.

## Hidden agentmemory tools

agentmemory advertises its full tool set regardless of which features are enabled, so tools for disabled features return HTTP 5xx errors when called. Slots (`AGENTMEMORY_SLOTS`) and knowledge-graph extraction (`GRAPH_EXTRACTION_ENABLED`) are disabled in `agentmemory.env`, so this repo denies their tools in `opencode.json`: `agentmemory_memory_slot_*`, `agentmemory_memory_graph_query` and `agentmemory_memory_relations`. OpenCode 2 removes denied tools from the model's tool list entirely, so the agent neither sees nor calls them. The deny rules must stay after the allow catch-all because the last matching permission rule wins. If you enable slots or graph extraction on the host, remove the matching deny line(s) and re-run `sync-config.sh`; the tools become visible again without recreating the sandbox.
