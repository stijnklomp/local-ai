#!/bin/bash
set -euo pipefail

# Build (cheap, uses the cache) and run the AI speed benchmark.
#
#   ./run-bench.sh                 benchmark the llama-server on port 8080
#   LLAMA_URL=http://localhost:11434/v1 MODEL=mistral-nemo:12b \
#       ./run-bench.sh              benchmark Ollama instead
#
# The container runs with the host's own network (--network host), so the
# model server is reached at localhost, exactly as from this terminal;
# no bridge network or firewall rules are involved.
#
# Tunables (all optional): RUNS, TTFT_WARN_S, TPS_WARN

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="local-ai/ai-bench"

docker build -q -t "$IMAGE" -f "$DIR/Dockerfile.bench" "$DIR" >/dev/null
echo "image: $IMAGE" >&2

exec docker run --rm --network host \
    -e "LLAMA_URL=${LLAMA_URL:-http://localhost:8080/v1}" \
    -e "MODEL=${MODEL:-}" \
    -e "RUNS=${RUNS:-3}" \
    -e "TTFT_WARN_S=${TTFT_WARN_S:-3}" \
    -e "TPS_WARN=${TPS_WARN:-15}" \
    "$IMAGE"
