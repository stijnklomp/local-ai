# Monitoring & health checks

Two small Docker images that check the local AI setup is healthy. Run both
on the host (the machine with the GPU), from this directory.

## GPU monitor

```sh
./run-gpu.sh
```

Prints one snapshot and exits:

```text
== GPU snapshot: 2026-10-13 22:47:06 ==

GPU 0: NVIDIA GeForce RTX 5080
  utilization : 100% (time a kernel was running in the last sample)
  VRAM        : 15234 MiB used / 16310 MiB total (93%), 1076 MiB free

Processes using VRAM:
  PID        PROCESS                      VRAM (MiB)
  12345      llama-server                 15120   <- model weights + KV-cache + CUDA context
  23456      Xorg                          114

llama-server VRAM total: 15120 MiB
```

- **utilization** — how much of the time the GPU was running kernels in the
  last sample. Near 100% while the model generates, near 0% when idle.
- **llama-server VRAM total** — everything the AI process holds in VRAM: the
  model weights, the KV-cache GPU working set (the part of the context cache
  that lives on the GPU; the rest streams from system RAM), and CUDA's own
  overhead. nvidia-smi reports VRAM per process and cannot split the three
  parts apart, so this is one combined number.

Live view (refreshes every 2 seconds, Ctrl-C to stop):

```sh
INTERVAL=2 ./run-gpu.sh
```

## AI speed benchmark

```sh
./run-bench.sh
```

Sends a short test prompt to the model server once as a warm-up, then 3
measured times, and reports per run:

- **first token (TTFT)** — how long until the model starts answering. A
  healthy setup is well under a second.
- **tok/s** — how fast it generates. llama-server reports its own measured
  speed, which the script uses when available.

Qwen 3.8 is a thinking model, so the token count is split into *thinking*
(reasoning tokens) and *answer* tokens. Example measured on this machine:

```text
  run 1: ok    first token 0.12s   49.8 tok/s   (192 tokens in 3.95s; 159 thinking + 31 answer)
  run 2: ok    first token 0.06s   49.3 tok/s   (192 tokens in 3.93s; 159 thinking + 31 answer)
  run 3: ok    first token 0.06s   52.2 tok/s   (192 tokens in 3.71s; 159 thinking + 31 answer)

result: PASS - the model is responding smoothly
```

Exit codes: `0` = PASS, `1` = WARN (slower than expected),
`2` = could not connect or no tokens came back.

Benchmark Ollama instead of llama-server:

```sh
LLAMA_URL=http://localhost:11434/v1 MODEL=mistral-nemo:12b ./run-bench.sh
```

Adjust the warn thresholds (defaults: first token over 3s, or generation
under 15 tok/s):

```sh
TTFT_WARN_S=5 TPS_WARN=10 ./run-bench.sh
```

## How they reach the host

Neither script needs any special Docker setup:

- **run-gpu.sh** shares the GPU device nodes (`/dev/nvidiactl`,
  `/dev/nvidia0`, ...) with the container, which is all nvidia-smi needs.
  No NVIDIA Container Toolkit required.
- **run-bench.sh** runs the container with the host's own network
  (`--network host`), so it reaches the model server at `localhost`
  exactly as your terminal does; no bridge network or firewall rules.
