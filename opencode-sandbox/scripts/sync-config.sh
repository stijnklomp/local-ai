#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${HOME}/.config/opencode"

usage() {
  cat <<'EOF'
Usage: sync-config.sh [--skip-agentmemory-env]

  --skip-agentmemory-env  Leave ~/.agentmemory/.env untouched. By default it is
                          backed up to .env.bak and replaced with this repo's
                          agentmemory.env.
EOF
}

SKIP_AGENTMEMORY_ENV=0
for arg in "$@"; do
  case "$arg" in
    --skip-agentmemory-env) SKIP_AGENTMEMORY_ENV=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

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
    cp -pf "$target" "${target}.bak"
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

# --- agentmemory Ollama repair proxy -----------------------------------------
# Render the systemd user unit with absolute paths, then enable and restart it.
# The unit itself lives in scripts/ so the deployed file is reproducible.
PROXY_SCRIPT="${REPO_DIR}/scripts/agentmemory-ollama-proxy.mjs"
PROXY_UNIT_SRC="${REPO_DIR}/scripts/agentmemory-ollama-proxy.service"
PROXY_UNIT_DIR="${HOME}/.config/systemd/user"
PROXY_UNIT="${PROXY_UNIT_DIR}/agentmemory-ollama-proxy.service"
PROXY_STATUS="skipped (node or unit template not found)"

if command -v node >/dev/null 2>&1 && [ -f "$PROXY_SCRIPT" ] && [ -f "$PROXY_UNIT_SRC" ]; then
  NODE_BIN="$(command -v node)"
  # sed replacement metacharacters: escape the delimiter and ampersands.
  NODE_ESC="$(printf '%s' "$NODE_BIN" | sed 's/[&|]/\\&/g')"
  PROXY_ESC="$(printf '%s' "$PROXY_SCRIPT" | sed 's/[&|]/\\&/g')"

  if ! mkdir -p "$PROXY_UNIT_DIR" 2>/dev/null; then
    echo "Error: cannot create ${PROXY_UNIT_DIR} as $(id -un)." >&2
    echo "Fix: sudo mkdir -p \"${PROXY_UNIT_DIR}\" && sudo chown -R $(id -un):$(id -gn) \"${PROXY_UNIT_DIR}\"" >&2
    PROXY_STATUS="skipped (unit directory not creatable)"
  elif [ ! -w "$PROXY_UNIT_DIR" ]; then
    echo "Error: ${PROXY_UNIT_DIR} is not writable by $(id -un)." >&2
    echo "Fix: sudo chown -R $(id -un):$(id -gn) \"${PROXY_UNIT_DIR}\"" >&2
    PROXY_STATUS="skipped (unit directory not writable)"
  else
    backup_file "$PROXY_UNIT" || true
    # Write to a temp file and rename: replacing an existing root-owned unit
    # only needs write permission on the directory, not on the file.
    PROXY_UNIT_TMP="$(mktemp "${PROXY_UNIT_DIR}/.agentmemory-ollama-proxy.service.XXXXXX")"
    sed -e "s|@NODE_BIN@|${NODE_ESC}|g" \
        -e "s|@PROXY_SCRIPT@|${PROXY_ESC}|g" \
        "$PROXY_UNIT_SRC" > "$PROXY_UNIT_TMP"
    chmod 644 "$PROXY_UNIT_TMP"
    mv -f "$PROXY_UNIT_TMP" "$PROXY_UNIT"

    if command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload >/dev/null 2>&1; then
      if systemctl --user enable agentmemory-ollama-proxy >/dev/null 2>&1; then
        if systemctl --user restart agentmemory-ollama-proxy >/dev/null 2>&1; then
          PROXY_STATUS="installed, enabled and running on 127.0.0.1:11435"
        else
          PROXY_STATUS="installed and enabled, but restart failed (check journalctl --user -u agentmemory-ollama-proxy)"
        fi
      else
        PROXY_STATUS="installed, but could not be enabled"
      fi
    else
      PROXY_STATUS="installed; systemd user manager unavailable, enable it manually"
    fi
  fi
fi

# --- agentmemory env -----------------------------------------------------------
# Replace the host env with this repo's agentmemory.env (the source of truth).
# Keep a .bak, preserve the secret if it lived only in the old file, and allow
# an opt-out with --skip-agentmemory-env.
AM_ENV="${HOME}/.agentmemory/.env"
AM_ENV_SRC="${REPO_DIR}/agentmemory.env"

if [ "$SKIP_AGENTMEMORY_ENV" -eq 1 ]; then
  AM_ENV_STATUS="skipped (--skip-agentmemory-env)"
elif [ ! -f "$AM_ENV_SRC" ]; then
  AM_ENV_STATUS="source missing: ${AM_ENV_SRC}"
elif [ -f "$AM_ENV" ] && cmp -s "$AM_ENV_SRC" "$AM_ENV"; then
  AM_ENV_STATUS="already up to date"
else
  OLD_HAD_SECRET=0
  if [ -f "$AM_ENV" ] && grep -q '^AGENTMEMORY_SECRET=' "$AM_ENV"; then
    OLD_HAD_SECRET=1
  fi

  mkdir -p "$(dirname -- "$AM_ENV")"
  if [ -f "$AM_ENV" ]; then
    backup_file "$AM_ENV"
    chmod 600 "${AM_ENV}.bak" 2>/dev/null || true
  fi
  cp -f "$AM_ENV_SRC" "$AM_ENV"
  chmod 600 "$AM_ENV" 2>/dev/null || true
  AM_ENV_STATUS="replaced from agentmemory.env; restart agentmemory"

  if [ "$OLD_HAD_SECRET" -eq 1 ] && ! grep -q '^AGENTMEMORY_SECRET=' "$AM_ENV"; then
    echo "Warning: the previous ~/.agentmemory/.env had AGENTMEMORY_SECRET, but agentmemory.env does not." >&2
    echo "         It is preserved in ~/.agentmemory/.env.bak; if the server rotates the secret, re-run the launcher." >&2
  fi
fi

echo "Synced to ${CONFIG_DIR}: opencode.json, AGENTS.md, ${PLUGIN_COUNT} plugin file(s), ${COMMAND_COUNT} command file(s)."
echo "agentmemory proxy: ${PROXY_STATUS}."
echo "~/.agentmemory/.env: ${AM_ENV_STATUS}."
echo "Previous versions were copied to *.bak (single file per source, overwritten every run)."
echo "If you customized opencode.json, merge your changes manually."
