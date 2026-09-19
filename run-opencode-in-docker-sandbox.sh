#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_NAME="$(basename "$PWD")"

if ! curl -fsS --max-time 2 \
    http://localhost:3111/agentmemory/health \
    >/dev/null; then

  echo "ERROR: agentmemory is not running." >&2
  echo >&2
  echo "Start it manually with:" >&2
  echo "  cd \$HOME/.local/share/agentmemory && NODE_OPTIONS='--max-old-space-size=4096' agentmemory" >&2
  exit 1
fi

exec sbx run \
  --name "$SANDBOX_NAME" \
  "$SCRIPT_DIR" . ~/.config/opencode:ro
