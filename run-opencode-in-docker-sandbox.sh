#!/bin/bash
set -euo pipefail

OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
OPENCODE_APPLICATION_DATA_DIR="$HOME/.local/share/opencode"
LOCAL_AI_REPO_DIR="<path-to-local-ai-repo>"

# OpenCode config
cp "$OPENCODE_CONFIG_DIR/opencode.json" ./opencode.json
cp "$OPENCODE_APPLICATION_DATA_DIR/auth.json" ./auth.json

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

sbx run opencode
