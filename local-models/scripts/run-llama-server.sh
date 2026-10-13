#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_MODELS_DIR="$(dirname "$SCRIPT_DIR")"
LLAMA_DIR="$LOCAL_MODELS_DIR/llama.cpp-adaptive-kv-streaming"
SERVER="$LLAMA_DIR/build-v2/bin/llama-server"

CUDA_HOME=""
if [ -x /usr/local/cuda/bin/nvcc ]; then
  CUDA_HOME="$(readlink -f /usr/local/cuda)"
else
  for _p in /usr/local/cuda-13*/bin/nvcc; do
    if [ -x "$_p" ]; then CUDA_HOME="$(dirname "$(dirname "$(readlink -f "$_p")")")"; fi
  done
fi
if [ -z "$CUDA_HOME" ] && command -v nvcc >/dev/null 2>&1; then
  CUDA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v nvcc)")")")"
fi
SERVER_DIR="$(dirname "$SERVER")"
LD_PATHS="$SERVER_DIR"
if [ -n "$CUDA_HOME" ] && [ -d "$CUDA_HOME/lib64" ]; then
  LD_PATHS="$LD_PATHS:$CUDA_HOME/lib64"
fi
export LD_LIBRARY_PATH="$LD_PATHS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

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
