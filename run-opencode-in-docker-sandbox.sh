#!/bin/bash
set -euo pipefail

OPENCODE_CONFIG_DIR="$HOME/.config/opencode"

# OpenCode config
cp $OPENCODE_CONFIG_DIR/opencode.json .

# Agent memory
cp -r $OPENCODE_CONFIG_DIR/hooks .
cp -r $OPENCODE_CONFIG_DIR/.opencode .

# Start Neo4j
if docker compose -f "$OPENCODE_CONFIG_DIR/docker-compose.yml" ps neo4j --status running 2>/dev/null | grep -q "running"; then
  echo "neo4j is already running."
else
  echo "Starting neo4j..."
  docker compose -f "$OPENCODE_CONFIG_DIR/docker-compose.yml" up -d neo4j
fi

sbx run opencode
