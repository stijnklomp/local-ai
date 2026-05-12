#!/bin/bash
set -euo pipefail

CURRENT_DIR=$(dirname "$0")

# OpenCode config
cp $CURRENT_DIR/opencode.json .

# Agent memory
cp $CURRENT_DIR/hooks .
cp $CURRENT_DIR/.opencode .

# Start Neo4j
if docker compose -f "/docker-compose.yml" ps neo4j --status running 2>/dev/null | grep -q "running"; then
  echo "neo4j is already running."
else
  echo "Starting neo4j..."
  docker compose -f "/docker-compose.yml" up -d neo4j
fi

sbx run opencode
