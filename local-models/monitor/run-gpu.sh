#!/bin/bash
set -euo pipefail

# Build (cheap, uses the cache) and run the GPU monitor.
#
#   ./run-gpu.sh            one snapshot
#   INTERVAL=2 ./run-gpu.sh refresh every 2 seconds (Ctrl-C to stop)
#
# The GPU is shared with the container through its device nodes
# (/dev/nvidiactl, /dev/nvidia0, ...), which is all nvidia-smi needs, so
# this does not require the NVIDIA Container Toolkit.

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="local-ai/gpu-monitor"

[ -e /dev/nvidiactl ] || {
    echo "error: /dev/nvidiactl not found; is the NVIDIA driver installed?" >&2
    exit 1
}
DEVICES=(--device /dev/nvidiactl)
for dev in /dev/nvidia[0-9]*; do
    [ -e "$dev" ] && DEVICES+=(--device "$dev")
done

docker build -q -t "$IMAGE" -f "$DIR/Dockerfile.gpu" "$DIR" >/dev/null
echo "image: $IMAGE" >&2

exec docker run --rm -i "${DEVICES[@]}" -e "INTERVAL=${INTERVAL:-}" "$IMAGE"
