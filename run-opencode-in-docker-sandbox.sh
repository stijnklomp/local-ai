#!/bin/bash
set -euo pipefail

LOCAL_AI_REPO_DIR="<path-to-local-ai-repo>"

SKIP_SKILLS_PATH=false
for arg in "$@"; do
  if [ "$arg" = "--skip-skills-path" ]; then
    SKIP_SKILLS_PATH=true
    break
  fi
done

if [ "${1:-}" = "--use-local-memory" ]; then
  echo "Setting up Agent memory and Neo4j..."
  # Agent memory
  cp -r $LOCAL_AI_REPO_DIR/hooks .
  cp -r $LOCAL_AI_REPO_DIR/.opencode .
  cp -r $LOCAL_AI_REPO_DIR/dream .

  # Start Neo4j
  if docker compose -f "$LOCAL_AI_REPO_DIR/docker-compose.yml" ps neo4j --status running 2>/dev/null | grep -q "running"; then
    echo "neo4j is already running."
  else
    echo "Starting neo4j..."
    docker compose -f "$LOCAL_AI_REPO_DIR/docker-compose.yml" up -d neo4j

    # Fulltext index creation
    curl -s -u neo4j:password \
      -H "Content-Type: application/json" \
      -X POST http://localhost:7474/db/neo4j/tx/commit \
      -d '{"statements":[{"statement":"CREATE FULLTEXT INDEX memory_fulltext IF NOT EXISTS FOR (m:Memory) ON EACH [m.content, m.path]"}]}'
  fi
else
  echo "Skipping Agent memory and Neo4j initialization."
fi

OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
OPENCODE_APPLICATION_DATA_DIR="$HOME/.local/share/opencode"

SANDBOX_NAME="opencode-$(basename $PWD)"

if ! sbx ls | grep -q "^$SANDBOX_NAME "; then
  sbx create opencode .
  sbx exec "$SANDBOX_NAME" -- sudo mkdir -p /home/agent/.config/opencode/skills
  sbx exec "$SANDBOX_NAME" -- sudo mkdir -p /home/agent/.local/share/opencode
  sbx exec "$SANDBOX_NAME" -- sudo chown -R agent:agent /home/agent/.config
  sbx exec "$SANDBOX_NAME" -- sudo chown -R agent:agent /home/agent/.local
fi

sbx cp "$OPENCODE_CONFIG_DIR/opencode.json" "$SANDBOX_NAME:/home/agent/.config/opencode/opencode.json"

if [ -d "$OPENCODE_CONFIG_DIR/skills" ]; then
    sbx cp "$OPENCODE_CONFIG_DIR/skills/." "$SANDBOX_NAME:/home/agent/.config/opencode/skills"
fi

sbx cp "$OPENCODE_APPLICATION_DATA_DIR/auth.json" "$SANDBOX_NAME:/home/agent/.local/share/opencode/auth.json"

if [ "$SKIP_SKILLS_PATH" = false ] && [ ! -f "opencode.json" ]; then
  sbx cp "$LOCAL_AI_REPO_DIR/opencode_skills_path.json" "$SANDBOX_NAME:$PWD/opencode.json"
  if command -v git &>/dev/null && ! git rev-parse --git-dir &>/dev/null; then
    git init
  fi
else
  echo "Skipping opencode.json copy (either omitted by flag or file already exists locally)."
fi

sbx run "$SANDBOX_NAME"
