#!/bin/bash
# GPU snapshot: overall utilization/VRAM plus per-process VRAM, with the
# llama-server total highlighted.
#
# The llama-server total is one number that combines the model weights, the
# KV-cache GPU working set, and the CUDA context overhead. nvidia-smi reports
# per-process VRAM only, so the three parts cannot be split apart.
#
# Set INTERVAL (seconds) to refresh in a loop, e.g. INTERVAL=2.

set -eu

INTERVAL="${INTERVAL:-}"

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

while :; do
    if [ -n "$INTERVAL" ] && [ -t 1 ]; then
        clear
    fi

    echo "== GPU snapshot: $(date '+%Y-%m-%d %H:%M:%S') =="
    echo

    # --- whole-GPU stats ---
    # note: nvidia-smi writes its errors to stdout, so capture both streams
    # and fail explicitly instead of letting the error text get swallowed
    if ! GPU_STATS="$(nvidia-smi \
        --query-gpu=index,name,utilization.gpu,memory.total,memory.used,memory.free \
        --format=csv,noheader,nounits 2>&1)"; then
        echo "nvidia-smi failed:" >&2
        echo "$GPU_STATS" >&2
        echo >&2
        echo "the container cannot see a GPU. Run this through run-gpu.sh, which" >&2
        echo "adds --gpus all, and make sure the NVIDIA Container Toolkit is" >&2
        echo "installed on the host (see README.md)." >&2
        if [ -z "$INTERVAL" ]; then
            exit 1
        fi
        sleep "$INTERVAL"
        continue
    fi
    while IFS=',' read -r idx name util mtotal mused mfree; do
        [ -z "$(trim "${idx:-}")" ] && continue
        idx="$(trim "$idx")"; name="$(trim "$name")"; util="$(trim "$util")"
        mtotal="$(trim "$mtotal")"; mused="$(trim "$mused")"; mfree="$(trim "$mfree")"
        pct=$(( mused * 100 / mtotal ))
        echo "GPU ${idx}: ${name}"
        echo "  utilization : ${util}% (time a kernel was running in the last sample)"
        echo "  VRAM        : ${mused} MiB used / ${mtotal} MiB total (${pct}%), ${mfree} MiB free"
    done <<< "$GPU_STATS"
    echo

    # --- per-process VRAM (same stdout quirk as above) ---
    echo "Processes using VRAM:"
    if ! PROCS="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory \
        --format=csv,noheader,nounits 2>&1)"; then
        echo "  (nvidia-smi could not list processes: $PROCS)" >&2
        PROCS=""
    fi
    LLAMA_TOTAL=0
    if [ -z "$PROCS" ]; then
        echo "  (none)"
    else
        printf '  %-10s %-28s %s\n' "PID" "PROCESS" "VRAM (MiB)"
        while IFS=',' read -r pid pname mem; do
            [ -z "$(trim "${pid:-}")" ] && continue
            pid="$(trim "$pid")"; pname="$(trim "$pname")"; mem="$(trim "$mem")"
            note=""
            case "$pname" in
                *llama-server*)
                    LLAMA_TOTAL=$(( LLAMA_TOTAL + mem ))
                    note="   <- model weights + KV-cache + CUDA context"
                    ;;
            esac
            printf '  %-10s %-28s %s%s\n' "$pid" "$pname" "$mem" "$note"
        done <<< "$PROCS"
    fi

    if [ "$LLAMA_TOTAL" -gt 0 ]; then
        echo
        echo "llama-server VRAM total: ${LLAMA_TOTAL} MiB"
    fi

    if [ -n "$INTERVAL" ]; then
        echo
        echo "refreshing every ${INTERVAL}s (Ctrl-C to stop)"
        sleep "$INTERVAL"
    else
        echo
        break
    fi
done
