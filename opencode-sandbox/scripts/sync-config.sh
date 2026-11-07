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

# --- embedding model ---------------------------------------------------------
# When the repo env selects a non-local embedding provider, make sure Ollama has
# the model, that its OpenAI-compatible embeddings endpoint answers, and that the
# vector width matches OPENAI_EMBEDDING_DIMENSIONS. A mismatch would make
# agentmemory refuse to start (or silently discard the index with
# AGENTMEMORY_DROP_STALE_INDEX), so catch it here.
EMBED_STATUS="skipped (no EMBEDDING_PROVIDER in agentmemory.env)"
SPEC_EMBED_PROVIDER="$(sed -n 's/^EMBEDDING_PROVIDER=\([^ #]*\).*/\1/p' "$REPO_DIR/agentmemory.env" 2>/dev/null | head -n1)"
SPEC_EMBED_MODEL="$(sed -n 's/^OPENAI_EMBEDDING_MODEL=\([^ #]*\).*/\1/p' "$REPO_DIR/agentmemory.env" 2>/dev/null | head -n1)"
SPEC_EMBED_DIMS="$(sed -n 's/^OPENAI_EMBEDDING_DIMENSIONS=\([^ #]*\).*/\1/p' "$REPO_DIR/agentmemory.env" 2>/dev/null | head -n1)"
if [ -n "$SPEC_EMBED_PROVIDER" ] && [ "$SPEC_EMBED_PROVIDER" != "local" ]; then
  OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
  SPEC_EMBED_MODEL="${SPEC_EMBED_MODEL:-qwen3-embedding:0.6b}"
  if ! command -v curl >/dev/null 2>&1; then
    EMBED_STATUS="skipped (curl not found)"
  else
    if curl -s -m 5 "$OLLAMA_URL/api/tags" | grep -q "\"name\":\"${SPEC_EMBED_MODEL}"; then
      EMBED_STATUS="${SPEC_EMBED_MODEL} already present"
    else
      echo "Pulling ${SPEC_EMBED_MODEL} with Ollama..."
      if curl -s -m 900 -X POST "$OLLAMA_URL/api/pull" -H 'Content-Type: application/json' \
           -d "{\"model\":\"${SPEC_EMBED_MODEL}\",\"stream\":false}" | grep -q '"status":"success"'; then
        EMBED_STATUS="${SPEC_EMBED_MODEL} pulled"
      else
        EMBED_STATUS="${SPEC_EMBED_MODEL} pull failed; run: ollama pull ${SPEC_EMBED_MODEL}"
      fi
    fi

    EMBED_JSON="$(curl -s -m 120 "$OLLAMA_URL/v1/embeddings" -H 'Content-Type: application/json' \
      -d "{\"model\":\"${SPEC_EMBED_MODEL}\",\"input\":\"embedding health check\"}")"
    EMBED_DIMS_ACTUAL=""
    if command -v node >/dev/null 2>&1; then
      EMBED_DIMS_ACTUAL="$(printf '%s' "$EMBED_JSON" | node -e '
        let s = "";
        process.stdin.on("data", (d) => { s += d; })
          .on("end", () => {
            try {
              const v = JSON.parse(s)?.data?.[0]?.embedding;
              if (Array.isArray(v)) console.log(v.length);
            } catch {}
          });
      ' 2>/dev/null)"
    fi

    if [ -n "$EMBED_DIMS_ACTUAL" ]; then
      if [ -n "$SPEC_EMBED_DIMS" ] && [ "$EMBED_DIMS_ACTUAL" != "$SPEC_EMBED_DIMS" ]; then
        EMBED_STATUS="${EMBED_STATUS}; WARNING: model returns ${EMBED_DIMS_ACTUAL} dims but OPENAI_EMBEDDING_DIMENSIONS=${SPEC_EMBED_DIMS}"
      else
        EMBED_STATUS="${EMBED_STATUS}; embeddings OK (${EMBED_DIMS_ACTUAL} dims)"
      fi
    elif printf '%s' "$EMBED_JSON" | grep -q '"embedding"'; then
      EMBED_STATUS="${EMBED_STATUS}; embeddings endpoint OK (dimension not checked)"
    else
      EMBED_STATUS="${EMBED_STATUS}; embeddings endpoint check failed"
    fi
  fi
elif [ "$SPEC_EMBED_PROVIDER" = "local" ]; then
  EMBED_STATUS="local provider; no Ollama model needed"
fi

# --- pinned model digests ------------------------------------------------------
# A tag can be re-pulled under the same name and silently change digest, which
# changes behaviour (context, tokenizer, output quality) between runs. Compare
# /api/tags against models.lock and warn only: a mismatch means "re-validate",
# not "abort the sync". Missing file or an unreachable Ollama is a skip.
MODEL_LOCK_FILE="${REPO_DIR}/models.lock"
MODEL_LOCK_STATUS="skipped (models.lock not found)"
if [ -f "$MODEL_LOCK_FILE" ]; then
  OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
  if ! command -v curl >/dev/null 2>&1; then
    MODEL_LOCK_STATUS="skipped (curl not found)"
  elif ! command -v node >/dev/null 2>&1; then
    MODEL_LOCK_STATUS="skipped (node not found)"
  else
    TAGS_JSON="$(curl -s -m 5 "$OLLAMA_URL/api/tags" 2>/dev/null || true)"
    if [ -z "$TAGS_JSON" ]; then
      MODEL_LOCK_STATUS="skipped (Ollama did not answer at ${OLLAMA_URL})"
    else
      MODEL_LOCK_STATUS="$(printf '%s' "$TAGS_JSON" | node -e '
        const fs = require("fs");
        let s = "";
        process.stdin.on("data", (d) => { s += d; })
          .on("end", () => {
            const lock = fs.readFileSync(process.argv[1], "utf8")
              .split("\n").map((l) => l.trim())
              .filter((l) => l && !l.startsWith("#"));
            let models = [];
            try {
              models = JSON.parse(s).models || [];
            } catch {
              console.log("skipped (invalid /api/tags response)");
              return;
            }
            // /api/tags digests carry a sha256: prefix; models.lock pins bare hex.
            const byName = new Map(models.map((m) => [m.name, String(m.digest || "").replace(/^sha256:/, "")]));
            const matched = [];
            const warnings = [];
            for (const line of lock) {
              const [name, expected] = line.split(/\s+/);
              if (!name || !expected) continue;
              const actual = byName.get(name);
              if (actual === undefined) {
                warnings.push(name + " missing (run: ollama pull " + name + ")");
              } else if (actual !== expected) {
                warnings.push(name + " digest changed (expected " + expected.slice(0, 12) +
                  "\u2026, got " + actual.slice(0, 12) + "\u2026; re-validate, then update models.lock)");
              } else {
                matched.push(name);
              }
            }
            const summary = matched.length + "/" + lock.length + " pinned digests match";
            console.log(warnings.length ? "WARNING: " + warnings.join("; ") + " (" + summary + ")" : summary);
          });
      ' "$MODEL_LOCK_FILE" 2>/dev/null || true)"
      [ -n "$MODEL_LOCK_STATUS" ] || MODEL_LOCK_STATUS="check failed"
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
echo "embedding model: ${EMBED_STATUS}."
echo "model digests: ${MODEL_LOCK_STATUS}."
echo "~/.agentmemory/.env: ${AM_ENV_STATUS}."
echo "Previous versions were copied to *.bak (single file per source, overwritten every run)."
echo "If you customized opencode.json, merge your changes manually."
