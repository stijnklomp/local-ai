#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_MODELS_DIR="$(dirname "$SCRIPT_DIR")"
LLAMA_DIR="$LOCAL_MODELS_DIR/llama.cpp-adaptive-kv-streaming"
REPO_URL="https://github.com/RaymondHuang210129/llama.cpp-adaptive-kv-streaming.git"

fail() { echo "error: $*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || fail "git is not installed"
command -v cmake >/dev/null 2>&1 || fail "cmake is not installed (sudo apt install cmake)"
command -v nvidia-smi >/dev/null 2>&1 || fail "nvidia-smi not found; is the NVIDIA driver installed?"
command -v nvcc >/dev/null 2>&1 || fail "nvcc not found; install the CUDA 13 toolkit first (see llama-cpp-adaptive-kv-streaming.md)"

NVCC_MAJOR="$(nvcc --version | sed -n 's/.*release \([0-9]*\)\..*/\1/p')"
if [ -n "$NVCC_MAJOR" ] && [ "$NVCC_MAJOR" -lt 13 ]; then
  echo "warning: CUDA $NVCC_MAJOR detected; CUDA 13 is recommended for the optimized SM120 (RTX 50-series) paths."
fi

echo "GPU:"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
nvcc --version | tail -n 1

if [ -d "$LLAMA_DIR/.git" ]; then
  echo "Updating existing clone in $LLAMA_DIR..."
  git -C "$LLAMA_DIR" pull --ff-only
else
  echo "Cloning into $LLAMA_DIR..."
  git clone "$REPO_URL" "$LLAMA_DIR"
fi

echo "Configuring and building llama-server (this takes a while)..."
cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-v2" \
  -DGGML_CUDA=ON \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$LLAMA_DIR/build-v2" --target llama-server -j"$(nproc)"

echo
echo "Build finished: $LLAMA_DIR/build-v2/bin/llama-server"
echo "Next: download the model into $LOCAL_MODELS_DIR/models, then run scripts/run-llama-server.sh"
