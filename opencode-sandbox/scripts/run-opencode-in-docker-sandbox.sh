#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

if ! command -v sbx >/dev/null 2>&1; then
  echo "Error: 'sbx' (Docker Sandboxes) is not installed or not on PATH." >&2
  echo "Install the dependencies first: $REPO_DIR/scripts/install-dependencies.sh" >&2
  exit 1
fi

if [ ! -d "$HOME/.config/opencode" ]; then
  echo "Error: $HOME/.config/opencode does not exist." >&2
  echo "Generate it first: $REPO_DIR/scripts/sync-config.sh" >&2
  exit 1
fi

# Sandbox names follow the kit name rules: lowercase alphanumerics and hyphens,
# 1-64 characters. Derive a valid name from the project directory name.
RAW_NAME="$(basename "$PWD")"
SANDBOX_NAME="$(printf '%s' "$RAW_NAME" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
  | cut -c1-63 \
  | sed -E 's/-+$//')"
if [ -z "$SANDBOX_NAME" ]; then
  SANDBOX_NAME="sandbox"
fi
if [ "$SANDBOX_NAME" != "$RAW_NAME" ]; then
  echo "sandbox: sanitized project name \"$RAW_NAME\" to \"$SANDBOX_NAME\"."
fi

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
  echo "Start it manually at any time with:" >&2
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
    "$REPO_DIR" \
    . \
    "$HOME/.config/opencode:ro"
fi
