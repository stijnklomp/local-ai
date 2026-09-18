# OpenCode sandbox kit

Custom `sbx` agent kit: OpenCode with the agentmemory MCP proxied to the host agentmemory server, and your opencode config/skills/plugins/commands mounted read-only from the host.

## Prerequisites (one-time)

1. Host agentmemory server running: `cd ~/.local/share/agentmemory && NODE_OPTIONS='--max-old-space-size=4096' agentmemory` (check: `curl http://localhost:3111/agentmemory/health`)
2. Provider keys in the sbx secret store (never enter the VM):
   - `sbx secret set-custom --host opencode.ai --env OPENCODE_API_KEY --value "$OPENCODE_API_KEY"` (OpenCode Go / Zen)
   - `sbx secret set openrouter` (repeat for openai/anthropic/google/xai/groq/aws if you use them)
3. First launch: approve the inherited credential domains when `sbx` prompts.

## Run (from any project directory)

```sh
sbx run ./local-ai . ~/.config/opencode:ro
```

- `.` = workspace, `~/.config/opencode:ro` = live read-only mount of your opencode config (skills, plugins, commands).
- Tweak skills/config on the host at any time; the next sandbox session picks them up.

## Troubleshooting

- `sbx kit validate .` checks the kit spec.
- If `host.docker.internal` doesn't resolve in the sandbox, start the Docker daemon with `--add-host=host.docker.internal:host-gateway`.
- Remove the sandbox with `sbx rm <name>` to get a clean rebuild.
- If the mount path `/home/stijn` differs on another machine, update it in `spec.yaml` (symlinks + `OPENCODE_CONFIG`).
