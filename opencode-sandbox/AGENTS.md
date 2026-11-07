<!-- FOR AI AGENTS - Human readability is a side effect, not a goal -->
<!-- Managed by agent: keep sections and order; edit content, not structure -->
<!-- Last updated: 2026-11-07 | Last verified: 2026-11-07 -->

# AGENTS.md — opencode-sandbox

**Precedence:** the closest `AGENTS.md` to the files you're changing wins. This file governs `opencode-sandbox/`; the sibling `../local-models/AGENTS.md` governs host model serving.

Runs OpenCode 2 inside Docker Sandboxes (`sbx`, schema v3 workload kit) with the agentmemory MCP. Read [README.md](README.md) before changing the flow; [opencode-sandbox.yaml](opencode-sandbox.yaml) is the kit contract and [opencode-sandbox.dockerfile](opencode-sandbox.dockerfile) builds the image.

## Commands (host, Debian; installs take minutes)
| Task | Command | Notes |
|------|---------|-------|
| Install host deps | `./scripts/install-dependencies.sh` | sbx 0.51.0 (amd64/arm64 deb, pinned SHA-256) + agentmemory 0.9.32 (needs Node >= 20 and a writable npm prefix); flags `--skip-docker-sandbox`, `--skip-agentmemory`; needs KVM + `sbx login`; the kit image bakes OpenCode 2.2.6 (`@opencode/cli`) and agentmemory 0.9.32 at build time |
| Sync repo config to host | `./scripts/sync-config.sh` | host only, never inside the sandbox; copies opencode.json, global-AGENTS.md (as AGENTS.md), plugins/, commands/ into ~/.config/opencode; validates JSON, keeps a single `*.bak` per file, overwritten every run; also renders/enables the `agentmemory-ollama-proxy` systemd user unit, replaces `~/.agentmemory/.env` from the repo after backing it up, and pulls/validates the embedding model when the repo env selects one; `--skip-agentmemory-env` opts out of the env replacement |
| Install/update skills | `sbx skills add mattpocock/skills` (first time) / `sbx skills update` | host only; the runtime mounts the sbx shared store via the kit's `agent-skills@1` capability; host custom skills load from the read-only host mount through the `skills` config field; new store entries need a sandbox restart |
| Approve GitHub credential | `./scripts/setup-github-credential.sh` | host only; idempotently merges the `github` apiKey binding into ~/.config/sbx/credentials.yaml (required: the kit is third-party), reports whether a github service secret is stored |
| Enter sandbox | `./scripts/run-opencode-in-docker-sandbox.sh` | run from any project dir; requires sbx and ~/.config/opencode; sandbox name = sanitized basename of $PWD (lowercase, hyphens, 63 chars), reused if it exists; starts OpenCode with `--auto` |
| Reset sandbox | `sbx rm <name>` then relaunch | required after `opencode-sandbox.yaml` or `opencode-sandbox.dockerfile` changes; also required once for existing v2 sandboxes, which cannot be updated in place; `agentmemory.env` only needs a host server restart |
| Run LLM repair proxy | `systemctl --user status agentmemory-ollama-proxy` | installed, enabled and restarted by `./scripts/sync-config.sh`; listens on `127.0.0.1:11435`; verify with `curl -s http://127.0.0.1:11435/api/version` |

## File Map
| Path | Purpose |
|------|---------|
| opencode-sandbox.yaml | v3 workload kit descriptor: required `home` arg, version args, network allowlist, GitHub `credential@1`, lifecycle install, `agent-skills@1`, `agent-context@2` |
| opencode-sandbox.dockerfile | image build: `docker/sbx-kit-shell:1.0.0`, bakes OpenCode 2.2.6 + agentmemory 0.9.32, persistent shell exports host config path, agentmemory secret and websearch keys from the read-only mount |
| opencode.json | native OpenCode 2 config: providers (ollama/llama-server on 172.17.0.1), mcp.servers, permissions, a pinned `websearch.provider` (`"random"`), provider policies, update disable; `instructions`/`skills` point at the host config mount |
| global-AGENTS.md | global instructions; synced to ~/.config/opencode/AGENTS.md and loaded through the `instructions` field in opencode.json |
| agentmemory.env | source of truth for `~/.agentmemory/.env` (LLM, proxy, embeddings/backfill); `sync-config.sh` replaces the host file with it (backup first) unless `--skip-agentmemory-env` is passed |
| scripts/agentmemory-ollama-proxy.mjs | host-only OpenAI-compatible proxy in front of Ollama for agentmemory: forces greedy sampling and escapes bare `&` in responses so the strict XML compression parser accepts shell observations; listens on 127.0.0.1:11435 |
| scripts/agentmemory-ollama-proxy.service | systemd user unit template for the proxy; `sync-config.sh` substitutes the absolute node and repo paths and installs it to ~/.config/systemd/user/ |
| scripts/install-dependencies.sh | host setup: sha256-verified sbx deb, KVM checks, Node/npm guards, agentmemory install |
| scripts/run-opencode-in-docker-sandbox.sh | launcher: preflight checks (sbx, config dir), sanitizes sandbox name, resolves AGENTMEMORY_SECRET, writes ~/.config/opencode/agentmemory-secret (0600), health-checks :3111, mounts `~/.config/opencode` read-only as an extra workspace, starts OpenCode with `--auto` (no approval prompts) |
| scripts/sync-config.sh | repo to ~/.config/opencode; aborts when plugins/ or commands/ are symlinks (that is the sandbox view) |
| scripts/setup-github-credential.sh | host-only: ensures the `github` apiKey binding (api.github.com, github.com) in ~/.config/sbx/credentials.yaml without clobbering other bindings, reports whether a github service secret is stored |
| commands/recall.md, commands/remember.md | /recall and /remember slash commands over agentmemory tools |
| plugins/agentmemory-capture.ts | OpenCode 2 plugin (`@opencode/plugin`): subscribes to events and registers prompt/context/compaction/tool hooks; cleanup posts synchronously via curl |
| examples/opencode_project_skills_path_example.json | example `skills` config field for project-local skills |

## Heuristics
| When | Do |
|------|-----|
| Changing opencode.json, global-AGENTS.md, plugins/, commands/ | run `./scripts/sync-config.sh`, restart OpenCode; no sandbox rebuild needed |
| Changing your own skills under `~/.config/opencode/skills` | edit them on the host; they are read live from the read-only host mount through the `skills` config field; start a new session to pick up additions |
| Wanting zero approval prompts | use the launcher: it passes `--auto` and opencode.json allows every action except the explicit denies (agentmemory tools, git push); `sbx run`/dashboard attaches skip the flag |
| Changing `opencode-sandbox.yaml` or `opencode-sandbox.dockerfile` | recreate the sandbox (`sbx rm <name>`), then relaunch; after kit edits run `sbx kit validate --kit-arg "home=$HOME" .` (v3 source validation may require the build); allow entries are additive to the user's preset and pinned versions must match the install script. `agentmemory.env` only needs a host server restart |
| Sandbox cannot reach host model servers at 172.17.0.1 | sbx proxies all TCP; non-Open network presets may deny the bridge gateway (allow it scoped, or use host.docker.internal baseURLs; see README troubleshooting) |
| Porting or editing the capture plugin | OpenCode 1 plugins do not run in OpenCode 2; use the `@opencode/plugin` 2.2.6 API. Local plugin files resolve the package from the loader, no node_modules needed |
| Needing global instructions | edit global-AGENTS.md; it syncs to ~/.config/opencode/AGENTS.md and opencode.json loads it through the `instructions` field |
| Adding an agentmemory tool deny | put it after the allow rule in `permissions`; last matching permission rule wins |
| Adding or updating the mattpocock skills | run `sbx skills add mattpocock/skills` on the host the first time, then `sbx skills update`; the runtime mounts the shared store via `agent-skills@1`, and new store entries appear after `sbx stop <name>` and relaunch |
| Making host skills available in sandboxes | put them under `~/.config/opencode/skills`; the host config mount is read-only and opencode.json loads them through the `skills` field. Do not use `sbx skills import` for them unless you intentionally want copies in the shared store |
| Shared skills missing inside the sandbox | check `sbx skills ls` on the host; verify the kit's `agent-skills@1` capability and that the sandbox was created with the v3 kit, then `sbx stop <name>` and relaunch |
| Skill not offered by the model, or manual invocation | user-invoked skills (`disable-model-invocation: true`, e.g. `grill-me`) are absent from the model's list by design; open the `/skills` picker and select one (it inserts `@<skill>`), or mention `@<skill>` in the prompt |
| Giving OpenCode Console/Go its API key | store it before sandbox creation with `sbx secret set-custom --host opencode.ai --env OPENCODE_API_KEY`; sbx injects the placeholder and OpenCode 2 reads it as the `opencode` integration environment connection used by the `opencode-go` provider. Do not declare `OPENCODE_API_KEY` in `opencode-sandbox.yaml`, write `auth.json`, or use `/connect`: V2 keeps credentials in SQLite and `/connect` puts the real key inside the sandbox |
| Giving sandboxed `gh` GitHub access | run `./scripts/setup-github-credential.sh` (approves the `github` binding; required because the kit is third-party) and store a fine-grained PAT (Contents: Read-only; Issues and Pull requests: write) with `sbx secret set github`; sandboxes started before the binding need `sbx stop <name>`; the proxy injects the token, the sandbox only ever sees a sentinel |
| Keeping pushes on the host | `git push` is denied by the shell rules in opencode.json (after the allow catch-all); the stored PAT has no Contents:write and no GitHub SSH key is loaded; the user pushes manually |
| Host agentmemory health check fails | expected path; the sandbox runs a reduced local toolset until host :3111 is back |
| agentmemory status says `Provider: noop`, or compression stays `raw` | v0.9.x needs `AGENTMEMORY_LLM_PROVIDER=openai`; a provider key alone is noop. Run `./scripts/sync-config.sh` (it replaces `~/.agentmemory/.env` from the repo) and restart the host server |
| Compression logs `parse_failed` or observations stay `raw` | the host repair proxy is not running, or `OPENAI_BASE_URL` is not `http://127.0.0.1:11435/v1`. Local models emit raw `&&` in shell facts, which agentmemory's XML parser rejects; the proxy forces greedy sampling and escapes bare `&`. Check `curl -s http://127.0.0.1:11435/api/version`, then restart agentmemory |
| Changing the embedding model or `OPENAI_EMBEDDING_DIMENSIONS` | agentmemory refuses to start on stale vectors (or discards them if `AGENTMEMORY_DROP_STALE_INDEX=true`). Set that flag, restart once to re-embed the whole store, then remove it. `sync-config.sh` verifies the model's real width against the env before you restart |
| Moving the repo checkout or changing the `node` binary | re-run `./scripts/sync-config.sh`; it re-renders the proxy unit with the new absolute paths and restarts it |
| Customizing the host agentmemory env | edit repo `agentmemory.env`; `sync-config.sh` replaces `~/.agentmemory/.env` with it and keeps the old file at `.env.bak`. Pass `--skip-agentmemory-env` to preserve host-only edits. `AGENTMEMORY_SECRET` lives only in the host file, so keep the backup |
| Calling agentmemory MCP tools | pass `concepts` and `files` as comma-separated strings; the MCP schema rejects arrays |
| Editing ~/.config/opencode directly | don't; it is a read-only mount in the sandbox, the repo is the source of truth |

## Boundaries
- Never commit secrets, the agentmemory-secret file, or `~/.agentmemory/.env`. The GitHub token lives only in the host sbx secret store (`sbx secret set github`), never in the repo or ~/.config/opencode.
- Never call `sbx run` on the kit directly; the launcher supplies the required `home` kit arg.
- Ask first: changing the `opencode-sandbox.yaml` schema or args, `opencode-sandbox.dockerfile`, MCP deny rules, or pinned dependency versions.
