# llama.cpp adaptive KV streaming — RTX 5080 guide

Run [RaymondHuang210129/llama.cpp-adaptive-kv-streaming](https://github.com/RaymondHuang210129/llama.cpp-adaptive-kv-streaming) on an RTX 5080 (16 GB, SM120). This fork streams the KV cache from pinned host RAM into a bounded GPU working set, so a 27B model keeps full 256K context on a 16 GB card instead of dropping old tokens. It also adds MTP speculative decoding with the model's embedded MTP head for roughly 2x decode speed.

The fork's reference machine is an RTX 5070 Ti (same SM120 family and 16,303 MiB VRAM as the RTX 5080), and the configuration below is its qualified one, so it transfers directly. The 5080 has slightly more memory bandwidth (960 GB/s vs 896 GB/s), so expect a small additional speed-up.

> Experimental software: V2 is qualified for text plus the embedded MTP head on this model; image requests and other models are less tested. Expect to retune the arena size for your exact setup.

## What you get

Reference throughput on the RTX 5070 Ti (Unsloth `UD-IQ4_XS`, 256/256 batches, fixed 2,240 MiB arena, single request, 256-token continuation):

| Context | Decode, plain | Decode, MTP draft 3 |
| --- | --- | --- |
| 32K | 41.0 tok/s | 101.1 tok/s |
| 256K | 8.7 tok/s | 19.1 tok/s |

MTP costs a little prefill speed and memory. These are single-run measurements for one prompt and machine, not guarantees.

## Prerequisites

- NVIDIA driver new enough for CUDA 13 (Linux 580.65.06 or newer). Check with `nvidia-smi`; the driver's supported CUDA version is shown in the top-right.
- CUDA Toolkit 13 with `nvcc`, installed once on the host with `local-models/scripts/install-cuda-host.sh` (Debian 13). It installs `cuda-toolkit-13-2` from NVIDIA's Debian repository and prints the `PATH` lines to add. CUDA 13 is required for the optimized SM120 paths. Keep `GGML_CUDA_FA_ALL_QUANTS=ON` in the build (below); mixed Q8_0 K / Q4_0 V attention kernels need it.
- `git` and `docker`. cmake and the C++ toolchain live in the builder container (`local-models/llama-builder.Dockerfile`), not on the host.
- Disk: ~30 GB free (clone ~0.5 GB, toolkit ~5 GB, build several GB, model 13.3 GiB).
- RAM: pinned host memory holds the full KV history, roughly 6–7 GiB at 262,144 tokens (and less at shorter contexts). 32 GB system RAM is comfortable; on 16 GB, lower `--ctx-size` (for example 131072 ≈ 3.3 GiB).
- VRAM: the model weights (~13.3 GiB) plus the arena (~2.2 GiB) nearly fill the 16 GB card. Unload other GPU users first (see [Ollama coexistence](#ollama-coexistence)).

## Install

Install the CUDA 13 toolkit on the host once (Debian 13):

```sh
local-ai/local-models/scripts/install-cuda-host.sh
```

The helper script clones the fork (default branch `feature/adaptive-kv-stream-v2`) into `local-models/llama.cpp-adaptive-kv-streaming/` and builds `llama-server` inside a Debian 13 container that uses the host's CUDA toolkit, so no cmake or C++ toolchain is needed on the host. Run it from anywhere:

```sh
local-ai/local-models/scripts/install-llama-adaptive-kv.sh
```

Or do it manually (from the repository root):

```sh
git clone https://github.com/RaymondHuang210129/llama.cpp-adaptive-kv-streaming.git local-models/llama.cpp-adaptive-kv-streaming

docker build -t local-ai/llama-builder:trixie -f local-models/llama-builder.Dockerfile local-models
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -w /src \
  -v "$(pwd)/local-models/llama.cpp-adaptive-kv-streaming:/src" \
  -v "$(readlink -f /usr/local/cuda):/usr/local/cuda:ro" \
  local-ai/llama-builder:trixie \
  bash -c 'cmake -S /src -B /src/build-v2 -DGGML_CUDA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_CUDA_ARCHITECTURES=120 && cmake --build /src/build-v2 --target llama-server -j$(nproc)'
```

The build pins SM120 (`-DCMAKE_CUDA_ARCHITECTURES=120`), so it needs no GPU inside the container and only produces kernels for RTX 50-series cards.

### Model download

Download `Qwen3.8-27B-UD-IQ4_XS.gguf` (13.3 GiB) from [unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) into `local-models/models/`. The MTP head is embedded in this GGUF; do not download the separate `MTP/mtp-*.gguf` file.

```sh
mkdir -p local-models/models

# With the Hugging Face CLI (pipx install "huggingface_hub[cli]")
hf download unsloth/Qwen3.8-27B-GGUF Qwen3.8-27B-UD-IQ4_XS.gguf --local-dir local-models/models

# Or with curl
curl -L -o local-models/models/Qwen3.8-27B-UD-IQ4_XS.gguf https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-IQ4_XS.gguf
```

Prefer more VRAM headroom? `Qwen3.8-27B-UD-Q3_K_XL.gguf` (12.2 GiB) is the next smaller quant; `UD-IQ4_XS` is the one the fork is qualified on.

## Run

```sh
local-ai/local-models/scripts/run-llama-server.sh
```

The script starts `llama-server` with the configuration below. Override defaults with environment variables: `ARENA_MIB`, `CTX_SIZE`, `DRAFT_N` (0 disables MTP), `BATCH_SIZE`, `LISTEN_HOST`, `LISTEN_PORT`, `MODEL`.

Equivalent manual command (from the clone directory):

```sh
./build-v2/bin/llama-server \
  --model ../models/Qwen3.8-27B-UD-IQ4_XS.gguf \
  --ctx-size 262144 --parallel 1 \
  --batch-size 256 --ubatch-size 256 --n-gpu-layers 999 \
  --flash-attn on --cache-type-k q8_0 --cache-type-v q4_0 \
  --kv-stream-arena-mib 2240 \
  --spec-type draft-mtp --spec-draft-n-max 3 \
  --fit off --no-mmproj \
  --host 0.0.0.0 --port 8080
```

The run script points `LD_LIBRARY_PATH` at the toolkit's `lib64` (found via `nvcc`, or `/usr/local/cuda`) so the CUDA runtime libraries resolve without any system-wide changes. If you run `llama-server` by hand, do the same.

### Why these flags

| Flag | Effect |
| --- | --- |
| `--no-mmproj` | Disables image recognition. The vision projector (~0.9 GiB) is never loaded and no vision workspace is reserved, leaving that VRAM for KV. This is the qualified text-only setup. |
| `--spec-type draft-mtp --spec-draft-n-max 3` | Enables the model's embedded MTP head for speculative decoding. Draft lengths 1–3 are qualified; 3 is fastest. Remove both flags to disable MTP. |
| `--cache-type-k q8_0 --cache-type-v q4_0` | Mixed KV quantization, the qualified pair. Attached MTP inherits these types, so do not add `--cache-type-k-draft`/`--cache-type-v-draft`; the shared layout requires matching types. Requires `GGML_CUDA_FA_ALL_QUANTS=ON` in the build. |
| `--kv-stream-arena-mib 2240` | GPU working-set budget (resident pages + ring + phase workspaces), tuned for 16 GB cards. It excludes model weights. Start at 2240 and adjust per the troubleshooting section. |
| `--ctx-size 262144` | Native full context. GPU memory stays bounded by the arena; host RAM grows with context. Lower it to save pinned system RAM or speed up startup. |
| `--parallel 1` | Streaming supports one serial request only. |
| `--flash-attn on` | Required for the streaming attention path. |
| `--n-gpu-layers 999` | Offload all layers; weights stay outside the arena. |
| `--fit off` | Disables llama.cpp's automatic fit so the fixed arena policy governs memory. |
| `--batch-size/--ubatch-size 256` | Qualified batch sizes for this fork. |
| `--host 0.0.0.0 --port 8080` | Makes the OpenAI-compatible API reachable from the Docker sandbox (`172.17.0.1:8080`). Use the default `127.0.0.1` if you only need host-local access. |

Do not set `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1`: the qualified configuration runs with UVM off, and the arena is device-local either way.

### Tuning

- **Arena size**: `2240` MiB is the tested value on the 16 GB reference card. If startup reports the shared arena quota is insufficient, lower it in steps of 128 MiB until admission passes (the policy degrades gracefully; less arena means more streaming and slightly lower speed). If `nvidia-smi` shows plenty of free VRAM after load, you can raise it toward more resident KV.
- **Context vs host RAM**: KV host memory is roughly linear in context length (~24 KiB per token for this model at Q8_0 K / Q4_0 V, so ~6.4 GiB at 256K). Halve `--ctx-size` to halve it when system RAM is tight.
- **Disable MTP** (`--spec-type` flags removed / `DRAFT_N=0`) when you prefer faster prefill over faster decode, or to save the MTP workspace and host snapshots.
- **Vision**: enabling image requests is possible in this fork with `--mmproj mmproj-F16.gguf --shared-device-memory-mib <mib>` instead of `--kv-stream-arena-mib` (and `--spec-draft-type-k q8_0 --spec-draft-type-v q4_0` for MTP), but it reduces the KV working set and is outside the qualified text-only setup above.

## Ollama coexistence

Ollama and `llama-server` both use the GPU, and this model plus its arena nearly fills 16 GB. Before starting the server, unload Ollama models:

```sh
ollama ps                 # see what is loaded
ollama stop <model>       # unload a specific model
```

To keep VRAM free automatically, set `OLLAMA_KEEP_ALIVE=0` for the Ollama service, or stop Ollama while the 27B model is serving. They use different ports (11434 vs 8080), so they can run side by side if the GPU memory allows.

## Use from the OpenCode sandbox

The sandbox reaches host servers through the Docker bridge gateway, exactly like Ollama. Make sure the server listens on `0.0.0.0` (default in the run script) and that the host firewall allows the bridge subnet on port 8080 (see [Firewall restrictions](README.md#firewall-restrictions)).

Check from inside the sandbox that the API is reachable:

```sh
curl http://172.17.0.1:8080/v1/models
```

The web UI is at `http://172.17.0.1:8080/` (and on the host at `http://localhost:8080/`). Any OpenAI-compatible client can point at `http://172.17.0.1:8080/v1`. To use it in OpenCode itself, add a provider to `opencode-sandbox/opencode.json` mirroring the existing `ollama` block with `baseURL: http://172.17.0.1:8080/v1`, then run `opencode-sandbox/sync-config.sh` on the host.

## Troubleshooting

| Symptom | Meaning and fix |
| --- | --- |
| `shared arena quota insufficient` at startup | The arena is too large for free VRAM. Lower `--kv-stream-arena-mib`. Model weights and CUDA housekeeping live outside the quota but still consume VRAM. |
| `native attention ... unavailable` for your K/V types or query width | A build problem, not an arena problem. Rebuild with `-DGGML_CUDA_FA_ALL_QUANTS=ON` and make sure the build uses CUDA 13. Increasing the arena will not help. |
| `host KV allocation/registration ... failed` | Pinned host-memory pressure. Free system RAM, or reduce `--ctx-size`. Disabling pinned memory is not a supported fallback in this fork. |
| CUDA device allocation / driver error | Not enough free VRAM. Close other GPU processes, `ollama stop` loaded models, and retry. |
| Error naming a missing native attention query width | Kernel/build/geometry admission failure — rebuild as above; do not enlarge the arena. |
| `nvcc` compile errors on older toolkits | CUDA 13 cannot compile pre-SM75 targets and older toolkits lack the SM120 paths. Install CUDA 13. |
| Slow first load | Weights are read from disk into VRAM (and the build is huge). Subsequent starts are faster once cached. |

Report failures to the fork's repo with your GPU, driver, toolkit, build flags and the full log.

## Updating

```sh
git -C local-models/llama.cpp-adaptive-kv-streaming pull --ff-only
local-ai/local-models/scripts/install-llama-adaptive-kv.sh   # rebuilds
```

The install script already does both when the clone exists.
