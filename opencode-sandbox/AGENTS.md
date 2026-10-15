<!-- FOR AI AGENTS - Human readability is a side effect, not a goal -->
<!-- Managed by agent: keep sections and order; edit content, not structure -->
<!-- Last updated: 2026-10-15 | Last verified: 2026-10-15 -->

# AGENTS.md — opencode-sandbox

**Precedence:** the closest `AGENTS.md` to the files you're changing wins. This file governs `opencode-sandbox/`; the sibling `../local-models/AGENTS.md` governs host model serving.

Runs OpenCode 2 inside Docker Sandboxes (`sbx`, schema v2 kit) with the agentmemory MCP. Read [README.md](README.md) before changing the flow; [spec.yaml](spec.yaml) is the kit contract.

## Commands (host, Debian; installs take minutes)
| Task | Command | Notes |
|------|---------|-------|
| Install host deps | `./scripts/install-dependencies.sh` | sbx 0.48.0 (amd64/arm64 deb, pinned SHA-256) + agentmemory 0.9.30 (needs Node >= 20 and a writable npm prefix); flags `--skip-docker-sandbox`, `--skip-agentmemory`; needs KVM + `sbx login`; the sandbox setup installs OpenCode 2.0.29 (`@opencode/cli`) |
| Sync repo config to host | `./scripts/sync-config.sh` | host only, never inside the sandbox; copies opencode.json, global-AGENTS.md (as AGENTS.md), plugins/, commands/ into ~/.config/opencode; validates JSON, keeps a single `*.bak` per file, overwritten every run |
| Install/update skills | `./scripts/install-skills.sh` | host only; clones/updates `mattpocock/skills` into ~/.config/opencode/vendor/ and replaces `~/.config/opencode/skills/{engineering,productivity}`; restart OpenCode afterwards |
| Approve GitHub credential | `./scripts/setup-github-credential.sh` | host only; idempotently merges the `github` apiKey binding into ~/.config/sbx/credentials.yaml (required: the kit is third-party and extends the built-in opencode kit), reports whether a github service secret is stored |
| Enter sandbox | `./scripts/run-opencode-in-docker-sandbox.sh` | run from any project dir; requires sbx and ~/.config/opencode; sandbox name = sanitized basename of $PWD (lowercase, hyphens, 63 chars), reused if it exists; starts OpenCode with `--auto` |
| Reset sandbox | `sbx rm <name>` then relaunch | required after spec.yaml or agentmemory.env changes, including the OpenCode 2 upgrade |

## File Map
| Path | Purpose |
|------|---------|
| spec.yaml | kit: `extends: opencode`, required `home` arg, network allowlist, installs OpenCode 2 CLI, symlinks global AGENTS.md, secret and websearch-key export |
| opencode.json | native OpenCode 2 config: providers (ollama/llama-server on 172.17.0.1), mcp.servers, permissions, a pinned `websearch.provider` (`"random"`), provider policies, update disable |
| global-AGENTS.md | global instructions; synced to ~/.config/opencode/AGENTS.md (OpenCode 2 ignores the `instructions` config field) |
| agentmemory.env | host agentmemory config (OPENAI_MODEL); copy to ~/.agentmemory/.env |
| scripts/install-dependencies.sh | host setup: sha256-verified sbx deb, KVM checks, Node/npm guards, agentmemory install |
| scripts/run-opencode-in-docker-sandbox.sh | launcher: preflight checks (sbx, config dir), sanitizes sandbox name, resolves AGENTMEMORY_SECRET, writes ~/.config/opencode/agentmemory-secret (0600), health-checks :3111, starts OpenCode with `--auto` (no approval prompts) |
| scripts/sync-config.sh | repo to ~/.config/opencode; aborts when plugins/ or commands/ are symlinks (that is the sandbox view) |
| scripts/install-skills.sh | host-only vendored skills: clones/updates mattpocock/skills into ~/.config/opencode/vendor, then replaces `~/.config/opencode/skills/engineering` and `skills/productivity` from it; exactly those two paths are script-owned and rebuilt on every run |
| scripts/setup-github-credential.sh | host-only: ensures the `github` apiKey binding (api.github.com, github.com) in ~/.config/sbx/credentials.yaml without clobbering other bindings, reports whether a github service secret is stored |
| commands/recall.md, commands/remember.md | /recall and /remember slash commands over agentmemory tools |
| plugins/agentmemory-capture.ts | OpenCode 2 plugin (`@opencode/plugin`): subscribes to events and registers prompt/context/compaction/tool hooks; cleanup posts synchronously via curl |
| examples/opencode_project_skills_path_example.json | example `skills` config field for project-local skills |

## Heuristics
| When | Do |
|------|-----|
| Changing opencode.json, global-AGENTS.md, plugins/, commands/ | run `./scripts/sync-config.sh`, restart OpenCode; no sandbox rebuild needed |
| Wanting zero approval prompts | use the launcher: it passes `--auto` and opencode.json allows every action except the explicit denies (agentmemory tools, git push); `sbx run`/dashboard attaches skip the flag |
| Changing spec.yaml or agentmemory.env | recreate the sandbox (`sbx rm <name>`), then relaunch; after spec edits run `sbx kit validate --kit-arg "home=$HOME" .`; allow entries are additive to the user's preset and pinned versions must match the install script |
| Sandbox cannot reach host model servers at 172.17.0.1 | sbx proxies all TCP; non-Open network presets may deny the bridge gateway (allow it scoped, or use host.docker.internal baseURLs; see README troubleshooting) |
| Porting or editing the capture plugin | OpenCode 1 plugins do not run in v2; use the `@opencode/plugin` 2.0.29 API. Local plugin files resolve the package from the loader, no node_modules needed |
| Needing global instructions | edit global-AGENTS.md; the `instructions` config field is ignored by v2 |
| Adding an agentmemory tool deny | put it after the allow rule in `permissions`; last matching permission rule wins |
| Adding or updating the mattpocock skills | run `./scripts/install-skills.sh` on the host (it git-pulls the vendor clone first), then restart OpenCode; the copied skill directories are overwritten on every run |
| Giving sandboxed `gh` GitHub access | run `./scripts/setup-github-credential.sh` (approves the `github` binding; required because the kit is third-party) and store a fine-grained PAT (Contents: Read-only; Issues and Pull requests: write) with `sbx secret set github`; sandboxes started before the binding need `sbx stop <name>`; the proxy injects the token, the sandbox only ever sees a sentinel |
| Keeping pushes on the host | `git push` is denied by the shell rules in opencode.json (after the allow catch-all); the stored PAT has no Contents:write and no GitHub SSH key is loaded; the user pushes manually |
| Host agentmemory health check fails | expected path; the sandbox runs a reduced local toolset until host :3111 is back |
| Calling agentmemory MCP tools | pass `concepts` and `files` as comma-separated strings; the MCP schema rejects arrays |
| Editing ~/.config/opencode directly | don't; it is a read-only mount in the sandbox, the repo is the source of truth |

## Boundaries
- Never commit secrets, the agentmemory-secret file, or `~/.agentmemory/.env`. The GitHub token lives only in the host sbx secret store (`sbx secret set github`), never in the repo or ~/.config/opencode.
- Never call `sbx run` on the kit directly; the launcher supplies the required `home` kit arg.
- Ask first: changing `spec.yaml` schema or args, MCP deny rules, or pinned dependency versions.
