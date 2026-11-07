# OpenCode Sandbox

OpenCode 2 running in a Docker Sandbox (`sbx`) from a schema v3 workload kit, with optional persistent agent memory powered by agentmemory.

## What to run

One-time host setup, from this directory:

| Step | Command | Notes |
| ---- | ------- | ----- |
| 1 | `./scripts/install-dependencies.sh` | Installs sbx 0.51.0 (SHA-256 verified) and agentmemory 0.9.32, and checks KVM. Calls sudo itself; do not run it with sudo. Flags: `--skip-docker-sandbox`, `--skip-agentmemory`. |
| 2 | `sbx login` | One-time Docker OAuth sign-in; `sbx run` needs it. |
| 3 | `cp agentmemory.env ~/.agentmemory/.env` | Optional: step 4 installs this file automatically. Manual copy is only needed if you skip `sync-config.sh`. |
| 4 | `./scripts/sync-config.sh` | Copies this repo's OpenCode config into `~/.config/opencode`. Required before the first launch. Also installs/enables the `agentmemory-ollama-proxy` systemd user unit, replaces `~/.agentmemory/.env` from `agentmemory.env` after backing it up, and pulls/validates the `qwen3-embedding:0.6b` model, including its vector width (pass `--skip-agentmemory-env` to opt out of the env replacement). |
| 5 | `sbx skills add mattpocock/skills` | Optional: installs [mattpocock/skills](https://github.com/mattpocock/skills) into the sbx shared skill store. The kit's `agent-skills@1` capability makes the runtime mount the store into OpenCode's global skills path at the next sandbox start. See [Skills](#skills). |
| 6 | `./scripts/setup-github-credential.sh` | Optional: approves the `github` credential for this kit and checks for a stored PAT (`sbx secret set github`); needed before sandboxed `gh` can act on GitHub. See [GitHub access](#github-access). |
| 7 | `sbx secret set-custom --host opencode.ai --env OPENCODE_API_KEY` | Optional: OpenCode (Console) PAT for the default `opencode-go` provider. Set it before the first launch. See [OpenCode (Console) access](#opencode-console-access). |

Launch OpenCode from any project directory:

```sh
/path/to/local-ai/opencode-sandbox/scripts/run-opencode-in-docker-sandbox.sh
```

After changing files in this repo:

| Changed | Do |
| ------- | -- |
| `opencode.json`, `global-AGENTS.md`, `plugins/`, `commands/` | `./scripts/sync-config.sh`, then restart OpenCode inside the sandbox |
| Skills in the sbx shared store | manage them on the host with `sbx skills add` / `sbx skills update`; new entries appear at the next sandbox start, updated contents at the next OpenCode session |
| Your own skills in `~/.config/opencode/skills` | edit them on the host; they are read live from the read-only host mount through the `skills` config field |
| the GitHub binding or sbx credential state | re-run `./scripts/setup-github-credential.sh`; restart sandboxes that started before the change (`sbx stop <name>`) |
| `opencode-sandbox.yaml`, `opencode-sandbox.dockerfile` | Remove the sandbox (`sbx rm <name>`) and relaunch |
| `agentmemory.env` | Restart the host agentmemory server; the sandbox reads only the secret written by the launcher, so no sandbox rebuild is needed |
| An existing sandbox created with the v2 kit | v2 sandboxes cannot be updated in place: `sbx rm <name>`, then relaunch once |

The kit is built and applied only when a sandbox is created. `./scripts/sync-config.sh` runs on the host only, never inside the sandbox.

## Install details

- Written for Debian-family Linux, tested on Debian 13. Docker officially supports Ubuntu 24.04+; the pinned `ubuntu2404` package also runs on Debian, but other distributions are untested.
- The script detects `amd64`/`arm64`, skips the download when `sbx` 0.51.0 or newer is already installed, and otherwise verifies the release artifact against a pinned SHA-256 before installing it.
- Local sandboxes need KVM. The script adds you to the `kvm` group when needed; sign out and back in (or run `newgrp kvm`) afterwards. Inside a VM, nested virtualization must be enabled.

## Running OpenCode

Run the launcher from the project directory the agent should work on (not from `opencode-sandbox/` itself):

```sh
local-ai/opencode-sandbox/scripts/run-opencode-in-docker-sandbox.sh
```

- The launcher derives the sandbox name from the project directory name: lowercased, invalid characters replaced by hyphens, truncated to 63 characters (`/home/me/My App` → `my-app`). Two projects with the same sanitized directory name share one sandbox; rename one of the directories if that is a problem.
- It resolves the agentmemory secret, writes `~/.config/opencode/agentmemory-secret` (mode 0600), and health-checks the host agentmemory server on `:3111`. A missing or unreachable agentmemory only prints a note; the sandbox still starts.
- The first run pulls the base image, boots the VM and builds the kit, which installs OpenCode 2.2.6 and agentmemory 0.9.32 into the image, so it takes minutes. Later runs attach to the existing sandbox with the same name.
- The launcher passes `--kit-arg home="$HOME"` when it creates a sandbox, so the kit config adapts to the host user. Always use the launcher instead of calling `sbx run` on the kit directory directly.
- The launcher starts OpenCode with `--auto` (`sbx run ... -- --auto`), so the sandboxed agent auto-approves every permission that is not explicitly denied and works without confirmation prompts. `deny` rules in `opencode.json` still apply; the sandbox itself is the safety boundary that makes unattended execution safe.

### Syncing repo config to the host

The sandbox reads OpenCode config, global instructions, plugins and commands from the host at `~/.config/opencode` (mounted read-only), not from this repo. After repo changes, run the sync script on the host:

```sh
./scripts/sync-config.sh
```

It copies `opencode.json`, `global-AGENTS.md` (as `AGENTS.md`), `plugins/` and `commands/` into `~/.config/opencode`, creates `plugins/`, `commands/` and `skills/` when missing, validates `opencode.json` before copying, and keeps one `*.bak` per file — a fixed name, written on every run and overwritten in place, so backups never pile up. Other files in those directories are left alone. If you have customized `opencode.json`, merge your changes manually. It also renders `scripts/agentmemory-ollama-proxy.service` with absolute paths into `~/.config/systemd/user/`, enables and restarts that unit, replaces `~/.agentmemory/.env` with this repo's `agentmemory.env` (backing the old file up to `.env.bak` first), and pulls/validates the embedding model named there. Pass `--skip-agentmemory-env` to leave the host env untouched. The script is only ever run manually; nothing invokes it automatically. Changes apply the next time OpenCode starts; no sandbox rebuild is needed. Running it inside the sandbox aborts with a hint, because the sandbox sees `plugins/` and `commands/` as symlinks.

### Skills

Agent skills come from two places:

- Repository skills in the sbx shared store, installed with `sbx skills add`. The kit declares the `agent-skills@1` capability, so the runtime mounts the store at `/home/agent/.config/opencode/skills`, the global path OpenCode 2 scans.
- Your own skills under `~/.config/opencode/skills` on the host. The host config directory is mounted read-only, and `opencode.json` loads them through the `skills` config field.

Install the mattpocock skills on the host:

```sh
sbx skills add mattpocock/skills
sbx skills ls
```

- `sbx skills add` installs every `SKILL.md` it discovers. For `mattpocock/skills` that includes the `in-progress/` and `misc/` buckets; pass `--skill <name>` (repeatable or comma-separated) to install a subset.
- Update repository-installed skills with `sbx skills update` (optionally with skill names).
- Your own host skills are read from the read-only host mount through the `skills` config field, so edits are live. They do not need `sbx skills import`. Import is optional: it copies them into the shared store for other agents or sandboxes, and an import replaces the store entry with a copy, so `sbx skills update` no longer manages it.
- The shared store and your own directory are separate sources now. If the same skill exists in both, keep one copy to avoid duplicate entries.
- New store entries reach a running sandbox only at its next start (`sbx stop <name>`, then relaunch). Updated contents are live through the links, but OpenCode may scan skills only at session start, so start a new session. Removed entries disappear at the next start.
- The shared store is experimental and `sbx reset` clears it.
- If you used the removed `./scripts/install-skills.sh`, delete `~/.config/opencode/vendor/mattpocock-skills` and the copied `engineering/` and `productivity/` directories under `~/.config/opencode/skills`. They are no longer used, and the category directories would not be loaded because they contain no top-level `SKILL.md`.
- Skills marked `disable-model-invocation: true` upstream (for example `grill-me`) stay hidden from the model's skill list. Invoke them manually with the `/skills` picker (it inserts `@grill-me` into the prompt), or mention `@grill-me` directly; model-invoked skills are advertised automatically.
- Run `@setup-matt-pocock-skills` once per project repo before using the engineering skills; it records the issue tracker, triage labels and domain-doc layout in that repo.

### Websearch provider keys

Web search works without keys through the providers' keyless tiers; an API key raises that provider's quota. Add one by writing the provider's environment variable to `~/.config/opencode/websearch.env` on the host:

```sh
cat > ~/.config/opencode/websearch.env <<'EOF'
TAVILY_API_KEY=tvly-...
EOF
chmod 600 ~/.config/opencode/websearch.env
```

One `VAR=value` per line; the built-in providers use `TAVILY_API_KEY`, `EXA_API_KEY`, `FIRECRAWL_API_KEY`, `PARALLEL_API_KEY` and `TINYFISH_API_KEY`. The image exports the file into the sandbox environment at shell start-up, and the kit's network allowlist covers all provider domains so `websearch.provider: "random"` can fail over between them. The export block lives in `opencode-sandbox.dockerfile` and the domains in `opencode-sandbox.yaml`, so changing either needs a new sandbox (`sbx rm <name>`, then relaunch); editing `websearch.env` itself needs only a restart of OpenCode. The file lives outside the repo, is ignored by `sync-config.sh` and is never committed. `/connect` in the TUI is an alternative that stores a key inside the sandbox.

### GitHub access

Inside the sandbox `GH_TOKEN` is a sentinel value; the host-side proxy replaces it with a real credential on requests to `api.github.com` and `github.com`, the domains this kit declares. Two host-side pieces are needed:

1. **An approved credential binding.** This is a third-party kit, so sbx withholds the `github` credential until a binding approves it — without one, sandboxes start with the credential silently withheld and `gh` reports the sentinel token as invalid. `./scripts/setup-github-credential.sh` writes the binding idempotently, merging with any existing entries in `~/.config/sbx/credentials.yaml`:

```sh
./scripts/setup-github-credential.sh
```

2. **A stored secret**: a fine-grained PAT with **Contents: Read-only**, **Issues: Read and write**, **Pull requests: Read and write** (Metadata: Read is mandatory). The missing Contents:write is deliberate: the sandbox must never push.

```sh
printf '%s' "$GITHUB_PAT" | sbx secret set github
sbx secret ls
```

Sandboxes that started before the binding existed must be restarted to pick it up (`sbx stop <name>`; `sbx exec` below starts them again). Verify from the host:

```sh
sbx exec <name> gh auth status
sbx exec <name> gh api user --jq .login
```

Inside the sandbox `gh` reports the sentinel as a `gho_...` token with `Token scopes: none` — that is expected for a fine-grained PAT behind the proxy. Rotating the PAT is re-running the `secret set` command; the token itself never enters the sandbox. `sbx reset` deletes stored secrets, so re-check afterwards.

Pushing stays on the host by design: `opencode.json` denies `git push` through explicit shell rules after the allow catch-all, the stored PAT has no write scope, and the kit does not declare `ssh-agent@1`, so v3 forwards no SSH agent into the sandbox. HTTPS is the supported path. Push manually from the host.

### OpenCode (Console) access

The default model, `opencode-go/deepseek-v4.1-flash`, needs an OpenCode (Console) API key. Store a PAT as a custom sbx secret scoped to OpenCode's API host and exposed as `OPENCODE_API_KEY`:

```sh
sbx secret set-custom \
  --host opencode.ai \
  --env OPENCODE_API_KEY
```

Verify it is registered:

```sh
sbx secret ls
```

```text
SCOPE      TARGETS       ENV                PLACEHOLDER               SECRET
(global)   opencode.ai   OPENCODE_API_KEY   sbx-cs-...                oc_sk_****...****hdFI
```

OpenCode 2 reads `OPENCODE_API_KEY` natively as an environment connection to its `opencode` (Console) integration, and the `opencode-go` provider uses that integration. sbx injects a generated `sbx-cs-...` placeholder into every sandbox created after the secret exists, so no `auth.json` write, `/connect` step or stored credential is needed. The proxy substitutes the real key on requests to `opencode.ai`; the sandbox only sees the `PLACEHOLDER`. `sbx secret ls` masks the stored value in the `SECRET` column; that column staying populated confirms the secret is stored.

Custom secrets apply only to sandboxes created after they are stored. Recreate an existing sandbox after adding the secret (`sbx rm <name>`, then relaunch); the same applies after changing the key. Without the secret the variable stays unset, OpenCode starts without the Console/Go connection, and the provider remains unavailable. Do not run `/connect` for this key: it stores the real key inside the sandbox database instead of using the proxy.

### OpenCode 2 specifics

- `opencode.json` uses the native OpenCode 2 format: `providers`, `mcp.servers`, an ordered `permissions` array, `policies` (provider allowlist) and `update: "disable"`. OpenCode 2 still normalizes the v1 shapes, but this repo keeps the native format. Do not point an OpenCode 1 installation at this config; keep v1 usage on a separate config file.
- The sandbox image bakes in the pinned OpenCode 2 CLI and agentmemory (`@opencode/cli` 2.2.6 and `@agentmemory/agentmemory` 0.9.32, pinned in `opencode-sandbox.yaml`) at build time; there are no create-time npm installs. OpenCode 2 is distributed separately from OpenCode 1: `@opencode/cli` is the v2 package, while `opencode-ai` is v1.
- The image's persistent shell block sets `OPENCODE_CONFIG` to the host `opencode.json`; OpenCode's writable config directory stays at `/home/agent/.config/opencode`. The config loads the host global `AGENTS.md` through the `instructions` field (`{env:OPENCODE_SANDBOX_HOST_HOME}/.config/opencode/AGENTS.md`) and host custom skills through the `skills` field (`{env:OPENCODE_SANDBOX_HOST_HOME}/.config/opencode/skills`). The kit's `agent-context@2` capability writes a separate sandbox-only `AGENTS.md` at `/home/agent/.config/opencode/AGENTS.md`.
- Credentials live in the server's SQLite database (`~/.local/share/opencode/opencode.db`); the legacy `auth.json` is imported only during the V1-to-V2 migration. The OpenCode Console key therefore arrives as the `OPENCODE_API_KEY` environment connection (see [OpenCode (Console) access](#opencode-console-access)), not as an auth file.
- OpenCode 1 plugin implementations do not run in OpenCode 2. `plugins/agentmemory-capture.ts` is written against the OpenCode 2 plugin API (`@opencode/plugin` 2.2.6) and is loaded from the global `~/.config/opencode/plugins/` directory.
- The agentmemory MCP server sets `codemode: false` so its tools stay on the model's native tool list as `agentmemory_memory_*`; `/recall` and `/remember` and the tool deny rules depend on those names.
- `websearch.provider` is pinned to `"random"`, so the first search in a fresh sandbox does not stop to ask which search provider to use. In `random` mode OpenCode keeps one provider per session and retries with another available provider when one returns HTTP 429 — this automatic failover exists only in `random` mode, so pinning a provider ID (`exa`, `firecrawl`, `parallel`, `tavily`, `tinyfish`) means a rate-limited provider keeps failing until its quota resets. Remove the key to get the selection prompt back; provider keys are covered in [Websearch provider keys](#websearch-provider-keys).
- Project-local skills can be added with the `skills` config field; see `examples/opencode_project_skills_path_example.json`.
- The capture plugin is written against the 2.2.6 plugin API. It subscribes to session lifecycle, permission and filesystem events and registers prompt, context, compaction and tool-execute hooks to feed agentmemory; the v1-only `command.executed` observation has no v2 equivalent. While a conversation has no assistant turn yet — a new session, or the segment after `/clear` — it also injects a title-only pointer to recent sessions in the same project, so the agent knows memory exists without receiving their content.

## Local models

The Ollama setup, firewall rules and model instructions live in [`../local-models/README.md`](../local-models/README.md).

- `opencode.json` reaches host model servers through the Docker bridge gateway (`172.17.0.1:11434` for Ollama, `172.17.0.1:8080` for llama-server), so the same config works on the host and in the sandbox. This is why those servers must listen on `0.0.0.0` and why the host firewall must allow the bridge subnet.
- The sandbox proxies all TCP traffic. With the sbx **Open** network preset this works out of the box; with **Balanced** or **Locked Down** (deny by default) the gateway may be blocked. See [Troubleshooting](#troubleshooting) for both fixes.
- `opencode-sandbox.yaml` allowlists `localhost:11434`/`:8080` and the bridge gateway `172.17.0.1:11434`/`:8080`, so both routes are available when the host network preset permits them.

## agentmemory

### agentmemory is optional

agentmemory does not have to be running to use the sandbox. If the host health check fails, the launcher prints a note and starts anyway. Inside the sandbox the agentmemory MCP then falls back to a reduced sandbox-local toolset (explicit saves only, kept inside the sandbox and never synced to the host) and automatic session capture pauses. The full toolset and capture resume automatically once the host server is reachable again.

### Local LLM compression (Ollama)

agentmemory v0.9.x keeps LLM features off until a provider is named explicitly: `OPENAI_API_KEY` alone leaves the server in `noop` mode. `agentmemory.env` therefore sets `AGENTMEMORY_LLM_PROVIDER=openai`; `agentmemory status` should report `Provider: ✓ llm`.

Pointing it straight at Ollama is not enough for reliable compression. agentmemory's compression and summary prompts demand strict XML, and its parser rejects a literal `&` that is not an entity. Shell observations routinely contain `&&`, which local models copy verbatim into `<fact>`; at Ollama's default sampling the output is then rejected. `scripts/agentmemory-ollama-proxy.mjs` is a small OpenAI-compatible proxy that sits in front of Ollama and:

- forces `temperature: 0` and `top_p: 0.1` when the request omits them (agentmemory never sends either), and
- escapes bare `&` in assistant content before returning it.

`agentmemory.env` sets `OPENAI_BASE_URL=http://127.0.0.1:11435/v1`. `./scripts/sync-config.sh` installs the proxy as a systemd user service: it renders `scripts/agentmemory-ollama-proxy.service` with absolute paths into `~/.config/systemd/user/`, enables and restarts it, and replaces `~/.agentmemory/.env` with this repo's `agentmemory.env` (backing it up to `~/.agentmemory/.env.bak` first). Pass `--skip-agentmemory-env` to leave the host env untouched. The repo file does not contain `AGENTMEMORY_SECRET`; if the server rotates the secret on restart, re-run the sandbox launcher so it refreshes `~/.config/opencode/agentmemory-secret`, or copy the secret back from the backup. Re-run the script after moving the checkout or changing the Node binary.

The same env also enables semantic recall: `EMBEDDING_PROVIDER=openai` with `qwen3-embedding:0.6b` (1024 dims, 100+ languages, 32K tokens) through the proxy. `sync-config.sh` pulls that model when missing, checks its embeddings endpoint and verifies the vector width matches `OPENAI_EMBEDDING_DIMENSIONS`. `AGENTMEMORY_VECTOR_BACKFILL=all` with a `AGENTMEMORY_VECTOR_BACKFILL_MAX` above the store size re-embeds everything in one start. Without it, recall is BM25 keyword-only. Changing the embedding model or width makes the existing vectors stale: set `AGENTMEMORY_DROP_STALE_INDEX=true` once to discard and rebuild them.

Verify both layers, then restart agentmemory if the env changed:

```sh
systemctl --user status agentmemory-ollama-proxy --no-pager
curl -s http://127.0.0.1:11435/api/version
agentmemory stop && agentmemory
```

If the systemd user manager is unavailable, run the proxy directly:

```sh
node /path/to/opencode-sandbox/scripts/agentmemory-ollama-proxy.mjs
```

The proxy only rewrites `POST .../chat/completions`; every other path and method is proxied verbatim, and streaming responses pass through unrepaired (agentmemory uses non-streaming calls). Keep it on localhost; it has no authentication of its own.

### API secret

agentmemory v0.9.32 authenticates its REST API. On every launch, the launcher resolves the host secret (`AGENTMEMORY_SECRET` from the environment, else from `~/.agentmemory/.env`, else from `~/.agentmemory/secret`) and writes it to `~/.config/opencode/agentmemory-secret` (mode 0600), inside the read-only host config mount. The image's persistent shell block exports it from there at shell start-up so the MCP client and the capture plugin can authenticate. If you rotate the secret, re-run the launcher and restart the sandbox.

### Hidden agentmemory tools

agentmemory advertises its full tool set regardless of which features are enabled, so tools for disabled features return HTTP 5xx errors when called. Slots (`AGENTMEMORY_SLOTS`) and knowledge-graph extraction (`GRAPH_EXTRACTION_ENABLED`) are disabled in `agentmemory.env`, so this repo denies their tools in `opencode.json`: `agentmemory_memory_slot_*`, `agentmemory_memory_graph_query` and `agentmemory_memory_relations`. OpenCode 2 removes denied tools from the model's tool list entirely, so the agent neither sees nor calls them. The deny rules must stay after the allow catch-all because the last matching permission rule wins. If you enable slots or graph extraction on the host, remove the matching deny line(s) and re-run `scripts/sync-config.sh`; the tools become visible again without recreating the sandbox.

## Troubleshooting

| Symptom | Fix |
| ------- | --- |
| `sbx: command not found` | Run `./scripts/install-dependencies.sh`. |
| Launcher says `~/.config/opencode does not exist` | Run `./scripts/sync-config.sh`. |
| KVM error when starting a sandbox | Enable hardware virtualization in the BIOS/UEFI (and nested virtualization when inside a VM); check `lsmod \| grep kvm` and that your user is in the `kvm` group (`newgrp kvm` after a group change). |
| Sandbox cannot reach `172.17.0.1:11434`/`:8080` | A host network preset can deny the gateway even though the kit allowlists it. Allow it for this sandbox (`sbx policy allow network --sandbox <name> 172.17.0.1:11434,172.17.0.1:8080`) or switch those `baseURL`s to `http://host.docker.internal:<port>/v1` (the kit allows `localhost:11434`/`localhost:8080`; `host.docker.internal` does not resolve on the host). |
| Config edits don't show up in the sandbox | Run `./scripts/sync-config.sh` and restart OpenCode. For `opencode-sandbox.yaml` or `opencode-sandbox.dockerfile` changes, recreate the sandbox: `sbx rm <name>`, then relaunch. `agentmemory.env` changes need only a host agentmemory restart (see the next row). |
| `agentmemory.env` changes don't take effect | agentmemory runs on the host, not in the sandbox: run `./scripts/sync-config.sh` (it replaces `~/.agentmemory/.env`), then restart the host agentmemory server. No sandbox rebuild is needed. |
| agentmemory tools missing or reduced | The host server is unreachable; start it or keep working, explicit saves stay sandbox-local (see [agentmemory is optional](#agentmemory-is-optional)). |
| `agentmemory status` says `Provider: noop (LLM features off)` | Run `./scripts/sync-config.sh` (it replaces `~/.agentmemory/.env` from `agentmemory.env`), then restart agentmemory. A provider key alone does not enable LLM features. |
| Compression stays `raw`, or logs `parse_failed` | The repair proxy is not running or `OPENAI_BASE_URL` does not point at it. Check `curl -s http://127.0.0.1:11435/api/version`, then restart agentmemory. See [Local LLM compression](#local-llm-compression-ollama). |
| `sync-config.sh` fails with `~/.config/systemd/user/agentmemory-ollama-proxy.service: Permission denied` | The unit file is root-owned (usually from an earlier `sudo` run). The script now replaces it via a temp file + rename when the directory is writable. If the directory itself is root-owned, run `sudo chown -R "$USER:$USER" ~/.config/systemd/user`, then re-run the script. |
| OpenCode Console/Go asks for `/connect` or shows unauthenticated | The custom secret was added after this sandbox was created, so `OPENCODE_API_KEY` is unset. Recreate the sandbox (`sbx rm <name>`, then relaunch) and do not run `/connect`; see [OpenCode (Console) access](#opencode-console-access). |
| `opencode-sandbox.yaml` sanity check | From this directory: `sbx kit inspect . --kit-arg home="$HOME"`, or `sbx kit validate --kit-arg home="$HOME" .`; v3 source validation may require the build. |
| Agent asks for approval before a command or edit | Launch via the launcher, which passes `--auto`; direct `sbx run`/dashboard attaches skip the flag. Anything hit by an explicit `deny` in `opencode.json` is blocked rather than prompted. |
| First search asks which provider to use | `./scripts/sync-config.sh` (the config pins `websearch.provider: "random"`) and restart OpenCode. |
| `gh auth status` says the token is invalid | No stored credential or no approved binding: run `./scripts/setup-github-credential.sh`, then store a PAT with `sbx secret set github` (see [GitHub access](#github-access)). |
| `gh` works in one sandbox but not another after adding the secret | The binding is evaluated at sandbox start; restart that sandbox: `sbx stop <name>`, then `sbx exec <name> gh auth status`. |
| `git push` is denied inside the sandbox | By design; pushes are reserved for the host (see [GitHub access](#github-access)). |
| Sandbox was created with the old v2 kit | v2 sandboxes cannot be updated in place: `sbx rm <name>`, then relaunch once. |
