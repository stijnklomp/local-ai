#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_MODELS_DIR="$(dirname "$SCRIPT_DIR")"
LLAMA_DIR="$LOCAL_MODELS_DIR/llama.cpp-adaptive-kv-streaming"
SERVER="$LLAMA_DIR/build-v2/bin/llama-server"

MODEL="${MODEL:-$LOCAL_MODELS_DIR/models/Qwen3.8-27B-UD-IQ4_XS.gguf}"
ARENA_MIB="${ARENA_MIB:-2240}"
CTX_SIZE="${CTX_SIZE:-262144}"
DRAFT_N="${DRAFT_N:-3}"
BATCH_SIZE="${BATCH_SIZE:-256}"
LISTEN_HOST="${LISTEN_HOST:-0.0.0.0}"
LISTEN_PORT="${LISTEN_PORT:-8080}"

[ -x "$SERVER" ] || { echo "error: $SERVER not found; run scripts/install-llama-adaptive-kv.sh first" >&2; exit 1; }
[ -f "$MODEL" ] || { echo "error: model not found: $MODEL" >&2; echo "Download Qwen3.8-27B-UD-IQ4_XS.gguf into $LOCAL_MODELS_DIR/models (see llama-cpp-adaptive-kv-streaming.md)" >&2; exit 1; }

SPEC_ARGS=()
if [ "$DRAFT_N" -gt 0 ]; then
  SPEC_ARGS=(--spec-type draft-mtp --spec-draft-n-max "$DRAFT_N")
fi

exec "$SERVER" \
  --model "$MODEL" \
  --ctx-size "$CTX_SIZE" --parallel 1 \
  --batch-size "$BATCH_SIZE" --ubatch-size "$BATCH_SIZE" --n-gpu-layers 999 \
  --flash-attn on --cache-type-k q8_0 --cache-type-v q4_0 \
  --kv-stream-arena-mib "$ARENA_MIB" \
  "${SPEC_ARGS[@]}" \
  --fit off --no-mmproj \
  --host "$LISTEN_HOST" --port "$LISTEN_PORT"
