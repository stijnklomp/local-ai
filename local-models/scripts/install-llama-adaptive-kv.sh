#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_MODELS_DIR="$(dirname "$SCRIPT_DIR")"
LLAMA_DIR="$LOCAL_MODELS_DIR/llama.cpp-adaptive-kv-streaming"
REPO_URL="https://github.com/RaymondHuang210129/llama.cpp-adaptive-kv-streaming.git"
BUILDER_DOCKERFILE="$LOCAL_MODELS_DIR/llama-builder.Dockerfile"
BUILDER_IMAGE="local-ai/llama-builder:trixie"
BUILD_DIR="build-v2"

fail() { echo "error: $*" >&2; exit 1; }

find_nvcc() {
  local p found=""
  if [ -x /usr/local/cuda/bin/nvcc ]; then
    readlink -f /usr/local/cuda/bin/nvcc
    return 0
  fi
  for p in /usr/local/cuda-13*/bin/nvcc; do
    if [ -x "$p" ]; then found="$p"; fi
  done
  if [ -n "$found" ]; then
    readlink -f "$found"
    return 0
  fi
  if command -v nvcc >/dev/null 2>&1; then
    readlink -f "$(command -v nvcc)"
    return 0
  fi
  return 1
}

command -v git >/dev/null 2>&1 || fail "git is not installed (sudo apt install git)"
command -v docker >/dev/null 2>&1 || fail "docker is not installed"
docker info >/dev/null 2>&1 || fail "the Docker daemon is not reachable"
command -v nvidia-smi >/dev/null 2>&1 || fail "nvidia-smi not found; is the NVIDIA driver installed?"

NVCC_PATH="$(find_nvcc || true)"
[ -n "$NVCC_PATH" ] || fail "nvcc not found; run scripts/install-cuda-host.sh first (installs the CUDA 13 toolkit)"
NVCC_MAJOR="$(sed -n 's/.*release \([0-9]*\)\..*/\1/p' <<< "$("$NVCC_PATH" --version)")"
if [ -n "$NVCC_MAJOR" ] && [ "$NVCC_MAJOR" -lt 13 ]; then
  echo "warning: CUDA $NVCC_MAJOR detected; CUDA 13 is recommended for the optimized SM120 (RTX 50-series) paths." >&2
fi

CUDA_HOME="$(dirname "$(dirname "$NVCC_PATH")")"
CUDA_REAL="$(readlink -f "$CUDA_HOME")"

echo "GPU:"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
echo "nvcc: $("$NVCC_PATH" --version | tail -n 1)"
echo "CUDA toolkit: $CUDA_REAL"

if [ -d "$LLAMA_DIR/.git" ]; then
  echo "Updating existing clone in $LLAMA_DIR..."
  git -C "$LLAMA_DIR" pull --ff-only
else
  echo "Cloning into $LLAMA_DIR..."
  git clone "$REPO_URL" "$LLAMA_DIR"
fi

echo "Building the builder image (cached after the first run)..."
docker build -t "$BUILDER_IMAGE" -f "$BUILDER_DOCKERFILE" "$LOCAL_MODELS_DIR"

echo "Building llama-server in Docker (this takes a while)..."
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -w /src \
  -v "$LLAMA_DIR:/src" \
  -v "$CUDA_REAL:/usr/local/cuda:ro" \
  "$BUILDER_IMAGE" \
  bash -c "cmake -S /src -B /src/$BUILD_DIR \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_FA_ALL_QUANTS=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
    -DCMAKE_CUDA_ARCHITECTURES=120 && \
  cmake --build /src/$BUILD_DIR --target llama-server -j\$(nproc)"

SERVER="$LLAMA_DIR/$BUILD_DIR/bin/llama-server"
[ -x "$SERVER" ] || fail "build finished but $SERVER was not found"

if command -v ldd >/dev/null 2>&1; then
  MISSING="$(LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$SERVER" | grep 'not found' || true)"
  if [ -n "$MISSING" ]; then
    echo "warning: some libraries are not resolvable on this host:" >&2
    echo "$MISSING" >&2
  fi
fi

echo
echo "Build finished: $SERVER"
echo "Next: download the model into $LOCAL_MODELS_DIR/models, then run scripts/run-llama-server.sh"
