# OpenCode Sandbox

OpenCode 2 running in a Docker Sandbox (`sbx`), with optional persistent agent memory powered by agentmemory.

## What to run

One-time host setup, from this directory:

| Step | Command | Notes |
| ---- | ------- | ----- |
| 1 | `./scripts/install-dependencies.sh` | Installs sbx 0.48.0 (SHA-256 verified) and agentmemory 0.9.30, and checks KVM. Calls sudo itself; do not run it with sudo. Flags: `--skip-docker-sandbox`, `--skip-agentmemory`. |
| 2 | `sbx login` | One-time Docker OAuth sign-in; `sbx run` needs it. |
| 3 | `cp agentmemory.env ~/.agentmemory/.env` | Host agentmemory configuration. Optional; skip if you don't want memory on this machine. |
| 4 | `./scripts/sync-config.sh` | Copies this repo's OpenCode config into `~/.config/opencode`. Required before the first launch. |

Launch OpenCode from any project directory:

```sh
/path/to/local-ai/opencode-sandbox/scripts/run-opencode-in-docker-sandbox.sh
```

After changing files in this repo:

| Changed | Do |
| ------- | -- |
| `opencode.json`, `global-AGENTS.md`, `plugins/`, `commands/` | `./scripts/sync-config.sh`, then restart OpenCode inside the sandbox |
| `spec.yaml`, `agentmemory.env` | Remove the sandbox (`sbx rm <name>`) and relaunch |

`spec.yaml` is applied only when a sandbox is created. `./scripts/sync-config.sh` runs on the host only, never inside the sandbox.

## Install details

- Written for Debian-family Linux, tested on Debian 13. Docker officially supports Ubuntu 24.04+; the pinned `ubuntu2404` package also runs on Debian, but other distributions are untested.
- The script detects `amd64`/`arm64`, skips the download when a new-enough `sbx` is already installed, and otherwise verifies the release artifact against a pinned SHA-256 before installing it.
- Local sandboxes need KVM. The script adds you to the `kvm` group when needed; sign out and back in (or run `newgrp kvm`) afterwards. Inside a VM, nested virtualization must be enabled.

## Running OpenCode

Run the launcher from the project directory the agent should work on (not from `opencode-sandbox/` itself):

```sh
local-ai/opencode-sandbox/scripts/run-opencode-in-docker-sandbox.sh
```

- The launcher derives the sandbox name from the project directory name: lowercased, invalid characters replaced by hyphens, truncated to 63 characters (`/home/me/My App` → `my-app`). Two projects with the same sanitized directory name share one sandbox; rename one of the directories if that is a problem.
- It resolves the agentmemory secret, writes `~/.config/opencode/agentmemory-secret` (mode 0600), and health-checks the host agentmemory server on `:3111`. A missing or unreachable agentmemory only prints a note; the sandbox still starts.
- The first run pulls the image, boots the VM and runs the kit setup (installs OpenCode 2.0.29 and agentmemory 0.9.30), which takes minutes. Later runs attach to the existing sandbox with the same name.
- The launcher passes `--kit-arg home="$HOME"` when it creates a sandbox, so the kit config adapts to the host user. Always use the launcher instead of calling `sbx run` on the kit directory directly.
- The launcher starts OpenCode with `--auto` (`sbx run ... -- --auto`), so the sandboxed agent auto-approves every permission that is not explicitly denied and works without confirmation prompts. `deny` rules in `opencode.json` still apply; the sandbox itself is the safety boundary that makes unattended execution safe.

### Syncing repo config to the host

The sandbox reads OpenCode config, global instructions, plugins and commands from the host at `~/.config/opencode` (mounted read-only), not from this repo. After repo changes, run the sync script on the host:

```sh
./scripts/sync-config.sh
```

It copies `opencode.json`, `global-AGENTS.md` (as `AGENTS.md`), `plugins/` and `commands/` into `~/.config/opencode`, creates `plugins/`, `commands/` and `skills/` when missing, validates `opencode.json` before copying, and keeps one `*.bak` per file — a fixed name, written on every run and overwritten in place, so backups never pile up. Other files in those directories are left alone. If you have customized `opencode.json`, merge your changes manually. The script is only ever run manually; nothing invokes it automatically. Changes apply the next time OpenCode starts; no sandbox rebuild is needed. Running it inside the sandbox aborts with a hint, because the sandbox sees those directories as symlinks.

### OpenCode 2 specifics

- `opencode.json` uses the native OpenCode 2 format: `providers`, `mcp.servers`, an ordered `permissions` array, `policies` (provider allowlist) and `update: "disable"`. OpenCode 2 still normalizes the v1 shapes, but this repo keeps the native format. Do not point an OpenCode 1 installation at this config; keep v1 usage on a separate config file.
- The sandbox image ships OpenCode 1; the kit setup replaces it with the pinned OpenCode 2 CLI (`@opencode/cli` 2.0.29, pinned in `spec.yaml`). OpenCode 2 is distributed separately from OpenCode 1: GitHub Releases only lists 1.x, and `npm install -g @opencode/cli` is the v2 package.
- OpenCode 2 ignores the `instructions` config field. Global instructions live in `global-AGENTS.md`, which syncs to `~/.config/opencode/AGENTS.md` (OpenCode 2 discovers that file globally). The kit symlinks it into the sandbox home config directory.
- OpenCode 1 plugin implementations do not run in OpenCode 2. `plugins/agentmemory-capture.ts` is written against the OpenCode 2 plugin API (`@opencode/plugin` 2.0.29) and is loaded from the global `~/.config/opencode/plugins/` directory.
- The agentmemory MCP server sets `codemode: false` so its tools stay on the model's native tool list as `agentmemory_memory_*`; `/recall` and `/remember` and the tool deny rules depend on those names.
- `websearch.provider` is pinned to `"random"`, so the first search in a fresh sandbox does not stop to ask which search provider to use. `random` selects any provider with credentials and retries with another on rate limits. Set it to a provider ID (`exa`, `firecrawl`, `parallel`, `tavily`, `tinyfish`) to pin one, or remove the key to get the selection prompt back; the provider domains must be reachable through the sbx network policy.
- Project-local skills can be added with the `skills` config field; see `examples/opencode_project_skills_path_example.json`.
- Capture mapping changed with the v2 event stream: sessions start/end from `session.created`/`session.deleted`, idle summarization from `session.status`/`session.idle`, compaction from `session.compaction.*`, assistant steps from `session.step.ended`, reasoning from `session.reasoning.ended`, permission prompts from `permission.asked`/`permission.replied`, and file changes from `filesystem.changed`. Tool calls, prompts, model params and compaction enrichment are captured through plugin hooks (`prompt`, `context`, `compaction`, `tool.execute.before`/`after`). The v1-only `command.executed` observation has no v2 equivalent; todo updates are captured as `todowrite` tool calls.

## Local models

The Ollama setup, firewall rules and model instructions live in [`../local-models/README.md`](../local-models/README.md).

- `opencode.json` reaches host model servers through the Docker bridge gateway (`172.17.0.1:11434` for Ollama, `172.17.0.1:8080` for llama-server), so the same config works on the host and in the sandbox. This is why those servers must listen on `0.0.0.0` and why the host firewall must allow the bridge subnet.
- The sandbox proxies all TCP traffic. With the sbx **Open** network preset this works out of the box; with **Balanced** or **Locked Down** (deny by default) the gateway may be blocked. See [Troubleshooting](#troubleshooting) for both fixes.
- `spec.yaml` allowlists `localhost:11434` and `localhost:8080`, so the `host.docker.internal` route works under any preset.

## agentmemory

### agentmemory is optional

agentmemory does not have to be running to use the sandbox. If the host health check fails, the launcher prints a note and starts anyway. Inside the sandbox the agentmemory MCP then falls back to a reduced sandbox-local toolset (explicit saves only, kept inside the sandbox and never synced to the host) and automatic session capture pauses. The full toolset and capture resume automatically once the host server is reachable again.

### API secret

agentmemory v0.9.30 authenticates its REST API. On every launch, the launcher resolves the host secret (`AGENTMEMORY_SECRET` from the environment, else from `~/.agentmemory/.env`, else from `~/.agentmemory/secret`) and writes it to `~/.config/opencode/agentmemory-secret` (mode 0600, inside the read-only mount). The sandbox exports it from there at startup so the MCP client and the capture plugin can authenticate. If you rotate the secret, re-run the launcher and restart the sandbox.

### Hidden agentmemory tools

agentmemory advertises its full tool set regardless of which features are enabled, so tools for disabled features return HTTP 5xx errors when called. Slots (`AGENTMEMORY_SLOTS`) and knowledge-graph extraction (`GRAPH_EXTRACTION_ENABLED`) are disabled in `agentmemory.env`, so this repo denies their tools in `opencode.json`: `agentmemory_memory_slot_*`, `agentmemory_memory_graph_query` and `agentmemory_memory_relations`. OpenCode 2 removes denied tools from the model's tool list entirely, so the agent neither sees nor calls them. The deny rules must stay after the allow catch-all because the last matching permission rule wins. If you enable slots or graph extraction on the host, remove the matching deny line(s) and re-run `scripts/sync-config.sh`; the tools become visible again without recreating the sandbox.

## Troubleshooting

| Symptom | Fix |
| ------- | --- |
| `sbx: command not found` | Run `./scripts/install-dependencies.sh`. |
| Launcher says `~/.config/opencode does not exist` | Run `./scripts/sync-config.sh`. |
| KVM error when starting a sandbox | Enable hardware virtualization in the BIOS/UEFI (and nested virtualization when inside a VM); check `lsmod \| grep kvm` and that your user is in the `kvm` group (`newgrp kvm` after a group change). |
| Sandbox cannot reach `172.17.0.1:11434`/`:8080` | Your sbx network preset denies the gateway. Allow it for this sandbox (`sbx policy allow network --sandbox <name> 172.17.0.1:11434,172.17.0.1:8080`) or switch those `baseURL`s to `http://host.docker.internal:<port>/v1` (the kit allows `localhost:11434`/`localhost:8080`; `host.docker.internal` does not resolve on the host). |
| Config edits don't show up in the sandbox | Run `./scripts/sync-config.sh` and restart OpenCode. For `spec.yaml` or `agentmemory.env` changes, recreate the sandbox: `sbx rm <name>`, then relaunch. |
| agentmemory tools missing or reduced | The host server is unreachable; start it or keep working, explicit saves stay sandbox-local (see [agentmemory is optional](#agentmemory-is-optional)). |
| `spec.yaml` sanity check | `sbx kit validate --kit-arg "home=$HOME" .` from this directory. |
| Agent asks for approval before a command or edit | Launch via the launcher, which passes `--auto`; direct `sbx run`/dashboard attaches skip the flag. Anything hit by an explicit `deny` in `opencode.json` is blocked rather than prompted. |
| First search asks which provider to use | `./scripts/sync-config.sh` (the config pins `websearch.provider: "random"`) and restart OpenCode. |
