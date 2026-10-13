#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${HOME}/.config/opencode"

if [ -L "$CONFIG_DIR/plugins" ] || [ -L "$CONFIG_DIR/commands" ]; then
  echo "Error: ${CONFIG_DIR}/plugins or ${CONFIG_DIR}/commands is a symlink, which is what the sandbox looks like from the inside." >&2
  echo "Run this script on the host, not inside the Docker sandbox." >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR/plugins" "$CONFIG_DIR/commands"

cp -f "$SCRIPT_DIR/opencode.json" "$CONFIG_DIR/opencode.json"

PLUGIN_COUNT=0
for f in "$SCRIPT_DIR"/plugins/*; do
  [ -f "$f" ] || continue
  cp -f "$f" "$CONFIG_DIR/plugins/"
  PLUGIN_COUNT=$((PLUGIN_COUNT + 1))
done

COMMAND_COUNT=0
for f in "$SCRIPT_DIR"/commands/*; do
  [ -f "$f" ] || continue
  cp -f "$f" "$CONFIG_DIR/commands/"
  COMMAND_COUNT=$((COMMAND_COUNT + 1))
done

echo "Synced to ${CONFIG_DIR}: opencode.json, ${PLUGIN_COUNT} plugin file(s), ${COMMAND_COUNT} command file(s)."
echo "Existing files were overwritten. If you customized opencode.json, merge your changes manually."
