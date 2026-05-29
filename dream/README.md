# dream.py

Offline memory consolidation for [agent-memory-hooks-neo4j](https://github.com/tomasonjo/agent-memory-hooks-neo4j).

Reads accumulated session events from Neo4j, asks a local Ollama model to distil them into durable markdown memory files, then writes the results back as `(:Memory)` nodes. Those memories are injected into the context of future OpenCode sessions automatically by the plugin.

## How it works

```
Neo4j (Session + Event nodes)
        │
        ▼
  fetch unprocessed sessions
        │
        ▼
  build prompt: events + existing memories
        │
        ▼
  Ollama model (local, via HTTP)
        │
        ▼
  JSON array of memory upserts / deletes
        │
        ▼
  Neo4j (:Memory nodes, tagged with context)
        │
        ▼
  session marked with dream_watermark (won't be reprocessed)
```

Each `Memory` node is a markdown file at a semantic path such as `profile/preferences.md`, `tools/git/workflow.md`, or `project/my-app/architecture.md`. The model merges rather than appends — if new events contradict an existing memory, that memory is rewritten in place.

## Requirements

None. `dream.py` uses only the Python standard library (`urllib`, `json`, `re`, `argparse`, `os`). No pip install required.

Requires Python 3.8+.

## Running

### From Docker Compose (recommended)

```bash
# Process all unprocessed sessions
docker compose run --rm dream

# With flags
docker compose run --rm dream --since 24h --dry-run
docker compose run --rm dream --context my-project
```

### Directly (from inside the Docker Sandbox or host)

```bash
python dream.py
python dream.py --since 24h
python dream.py --context my-project --dry-run
```

## CLI flags

| Flag | Description |
|---|---|
| `--since <window>` | Only process sessions created within this window. Accepts `24h`, `7d`, `2w`, etc. |
| `--session <id>` | Process a single session by ID instead of all unprocessed ones. |
| `--context <name>` | Override the context tag written to Memory nodes. Overrides each session's own context. Omit to use each session's stored context (default). |
| `--model <name>` | Ollama model to use. Defaults to `DREAM_MODEL` env var or `qwen3:14b`. |
| `--ollama-url <url>` | Ollama base URL. Defaults to `DREAM_OLLAMA_URL` env var or `http://host.docker.internal:11434`. |
| `--dry-run` | Print what would be written without saving anything to Neo4j. |

## Environment variables

All optional — CLI flags take precedence where both exist.

| Variable | Default | Description |
|---|---|---|
| `HOOKS_NEO4J_HTTP` | `http://host.docker.internal:7474` | Neo4j HTTP API URL |
| `HOOKS_NEO4J_USER` | `neo4j` | Neo4j username |
| `HOOKS_NEO4J_PASSWORD` | `password` | Neo4j password |
| `DREAM_MODEL` | `qwen3:14b` | Ollama model name |
| `DREAM_OLLAMA_URL` | `http://host.docker.internal:11434` | Ollama base URL |

## Context scoping

Memories are tagged with a `context` property that scopes them to a project or marks them as `global`.

The context applied to new memories comes from (in order of precedence):

1. `--context` CLI flag
2. The `context` property stored on the `Session` node (set automatically by the OpenCode plugin from the project directory name or `MEMORY_CONTEXT` env var)
3. Falls back to `global`

At injection time the plugin loads memories where `context` matches the current session's context **or** `context = 'global'`, so global memories appear in every session.

Use `--context global` to promote memories from a project session into the global pool:

```bash
docker compose run --rm dream --session ses_abc123 --context global
```

## Memory format

The model writes each memory as a markdown file with YAML frontmatter:

```markdown
---
updated: 2026-05-14
---

Prefers TypeScript over JavaScript. Uses pnpm as the package manager.
Always runs `tsc --noEmit` before committing.
```

You can view, edit, tag, and delete Memory nodes using the memory manager UI.

## Session watermarking

After successfully processing a session, `dream.py` sets a `dream_watermark` timestamp on the `Session` node. The default run (no `--since` or `--session` flags) only fetches sessions where `dream_watermark` is unset or older than `created_at`, so sessions are never processed twice accidentally. Using `--since` or `--session` bypasses this check and reprocesses regardless.
