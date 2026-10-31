#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${HOME}/.config/opencode"

if [ -L "$CONFIG_DIR/plugins" ] || [ -L "$CONFIG_DIR/commands" ]; then
  echo "Error: ${CONFIG_DIR}/plugins or ${CONFIG_DIR}/commands is a symlink, which is what the sandbox looks like from the inside." >&2
  echo "Run this script on the host, not inside the Docker sandbox." >&2
  exit 1
fi

if command -v node >/dev/null 2>&1; then
  if ! node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$REPO_DIR/opencode.json" 2>/dev/null; then
    echo "Error: $REPO_DIR/opencode.json is not valid JSON; nothing was copied." >&2
    exit 1
  fi
else
  echo "Warning: node not found; skipping the opencode.json syntax check." >&2
fi

mkdir -p "$CONFIG_DIR/plugins" "$CONFIG_DIR/commands" "$CONFIG_DIR/skills"

# Keep the previous version as <name>.bak before overwriting, so host
# customizations are not lost silently. The .bak file has a fixed name and
# is overwritten on every run, so backups never accumulate.
backup_file() {
  local target="$1"
  if [ -f "$target" ]; then
    cp -f "$target" "${target}.bak"
  fi
}

backup_file "$CONFIG_DIR/opencode.json"
backup_file "$CONFIG_DIR/AGENTS.md"

cp -f "$REPO_DIR/opencode.json" "$CONFIG_DIR/opencode.json"
cp -f "$REPO_DIR/global-AGENTS.md" "$CONFIG_DIR/AGENTS.md"

PLUGIN_COUNT=0
for f in "$REPO_DIR"/plugins/*; do
  [ -f "$f" ] || continue
  cp -f "$f" "$CONFIG_DIR/plugins/"
  PLUGIN_COUNT=$((PLUGIN_COUNT + 1))
done

COMMAND_COUNT=0
for f in "$REPO_DIR"/commands/*; do
  [ -f "$f" ] || continue
  cp -f "$f" "$CONFIG_DIR/commands/"
  COMMAND_COUNT=$((COMMAND_COUNT + 1))
done

echo "Synced to ${CONFIG_DIR}: opencode.json, AGENTS.md, ${PLUGIN_COUNT} plugin file(s), ${COMMAND_COUNT} command file(s)."
echo "Previous versions were copied to *.bak (single file per source, overwritten every run)."
echo "If you customized opencode.json, merge your changes manually."
