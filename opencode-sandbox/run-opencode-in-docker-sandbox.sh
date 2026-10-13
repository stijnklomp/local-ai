#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_NAME="$(basename "$PWD")"

SECRET="${AGENTMEMORY_SECRET:-}"
if [ -z "$SECRET" ] && [ -f "$HOME/.agentmemory/.env" ]; then
  SECRET="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?AGENTMEMORY_SECRET[[:space:]]*=[[:space:]]*//p' "$HOME/.agentmemory/.env" | tail -n 1)"
  SECRET="$(printf '%s' "$SECRET" | tr -d '"' | tr -d "'")"
fi
if [ -z "$SECRET" ] && [ -f "$HOME/.agentmemory/secret" ]; then
  SECRET="$(cat "$HOME/.agentmemory/secret")"
fi

SECRET_FILE="$HOME/.config/opencode/agentmemory-secret"
if [ -n "$SECRET" ]; then
  mkdir -p "$(dirname "$SECRET_FILE")"
  printf '%s\n' "$SECRET" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
else
  rm -f "$SECRET_FILE"
fi

AUTH_HEADER=()
if [ -n "$SECRET" ]; then
  AUTH_HEADER=(-H "Authorization: Bearer $SECRET")
fi

if curl -fsS --max-time 2 \
    "${AUTH_HEADER[@]}" \
    http://localhost:3111/agentmemory/health \
    >/dev/null 2>&1; then

  echo "agentmemory: available on the host (memory enabled)."
else
  echo "agentmemory: not running on the host; continuing without it." >&2
  echo >&2
  echo "Start it manually with:" >&2
  echo "  cd \$HOME/.local/share/agentmemory && NODE_OPTIONS='--max-old-space-size=4096' agentmemory" >&2
fi

echo "sandbox: checking for existing sandbox \"$SANDBOX_NAME\"..."

if sbx ls -q | grep -Fxq "$SANDBOX_NAME"; then
  echo "sandbox: attaching to existing sandbox \"$SANDBOX_NAME\"."
  exec sbx run --name "$SANDBOX_NAME"
else
  echo "sandbox: creating sandbox \"$SANDBOX_NAME\" (first run pulls the image and boots the VM, may take a few minutes)."
  exec sbx run \
    --name "$SANDBOX_NAME" \
    --kit-arg "home=$HOME" \
    "$SCRIPT_DIR" \
    . \
    "$HOME/.config/opencode:ro"
fi
