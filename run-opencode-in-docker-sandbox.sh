#!/bin/bash
set -euo pipefail

LOCAL_AI_REPO_DIR="<path-to-local-ai-repo>"

# OpenCode config
cp $LOCAL_AI_REPO_DIR/opencode.json .

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

sbx run opencode
