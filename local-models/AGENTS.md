<!-- FOR AI AGENTS - Human readability is a side effect, not a goal -->
<!-- Managed by agent: keep sections and order; edit content, not structure -->
<!-- Last updated: 2026-10-14 | Last verified: 2026-10-14 -->

# AGENTS.md — local-models

**Precedence:** the closest `AGENTS.md` to the files you're changing wins. This file governs `local-models/`; the sibling `../opencode-sandbox/AGENTS.md` governs the sandbox side.

Host-side setup for local LLM servers (Ollama plus a llama.cpp adaptive-KV fork) on an RTX 5080 16 GB, reached by the sandbox via the Docker bridge gateway 172.17.0.1.

Docs: [README.md](README.md) (Ollama/firewall), [llama-cpp-adaptive-kv-streaming.md](llama-cpp-adaptive-kv-streaming.md) (qualified flags, tuning, troubleshooting), [monitor/README.md](monitor/README.md).

## Commands (host, Debian 13 amd64)
| Task | Command | Notes |
|------|---------|-------|
| Install CUDA 13 toolkit | `scripts/install-cuda-host.sh` | requires NVIDIA driver >= 580.65.06; does not install drivers |
| Build/update llama-server | `scripts/install-llama-adaptive-kv.sh` | pulls the fork clone, builds builder image and `build-v2` in Docker (SM120); needs ~30 GB disk |
| Run server | `scripts/run-llama-server.sh` | env overrides: ARENA_MIB 2240, CTX_SIZE 262144, DRAFT_N 3 (0 = no MTP), BATCH_SIZE 256, LISTEN_HOST 0.0.0.0, LISTEN_PORT 8080, MODEL |
| GPU snapshot | `monitor/run-gpu.sh` | INTERVAL=2 for live refresh; shares nvidia device nodes, no NVIDIA Container Toolkit |
| Speed benchmark | `monitor/run-bench.sh` | LLAMA_URL and MODEL target Ollama instead; RUNS, TTFT_WARN_S, TPS_WARN; exit 0 PASS, 1 WARN, 2 unreachable |

## File Map
| Path | Purpose |
|------|---------|
| scripts/ | host install/run scripts (CUDA, fork build, server) |
| monitor/ | Dockerized GPU monitor and benchmark (gpu.sh, bench.py, Dockerfiles) |
| llama-builder.Dockerfile | Debian 13 build container; the build toolchain never runs on the host |
| models/ | GGUF weights (Qwen3.8-27B-UD-IQ4_XS.gguf, 13.3 GiB); gitignored |
| llama.cpp-adaptive-kv-streaming/ | gitignored fork clone; server at build-v2/bin/llama-server |

## Heuristics
| When | Do |
|------|-----|
| Starting the 27B server | unload Ollama first (`ollama ps`, `ollama stop <model>`); weights + arena nearly fill 16 GB |
| "shared arena quota insufficient" | lower ARENA_MIB in 128 MiB steps (desktop session: ~1856-1984) |
| First request CUDA OOM in MTP path | rerun with DRAFT_N=0 |
| Native attention or libcudart link errors | rebuild via the install script; never enlarge the arena |
| After updating the fork | rerun the install script (pull --ff-only, then rebuild) |
| Exposing a server to the sandbox | listen on 0.0.0.0; UFW allow from 172.17.0.0/16 (README firewall section) |
| Adding the model in OpenCode | mirror the ollama provider block in ../opencode-sandbox/opencode.json, then run sync-config.sh |

## Boundaries
- Never commit `models/` or `llama.cpp-adaptive-kv-streaming/` (both gitignored).
- Never set GGML_CUDA_ENABLE_UNIFIED_MEMORY=1, and keep `--parallel` at 1; the streaming path is qualified with UVM off and serial requests only.
- Never modify the fork clone's source; report failures upstream with GPU, driver, toolkit and full logs.
- Ask first: changing qualified flags (cache types, spec-type, batch size) or the host toolkit install.
