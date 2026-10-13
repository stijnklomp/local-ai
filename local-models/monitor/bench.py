#!/usr/bin/env python3
"""Speed benchmark for a local OpenAI-compatible model server.

Sends a short test prompt a few times and measures, per run:
  - TTFT (time to first token): how long until the model starts answering
  - tok/s: how fast the model generates tokens

The model may be a thinking model (it streams reasoning first, in
delta.reasoning_content, then the answer in delta.content). Both count:
the first streamed token of either kind starts the clock, and the token
split is reported. Token counts prefer the server's own usage report, and
generation speed prefers the server's own timings when it provides them.

Normally run through run-bench.sh. Standalone:
  LLAMA_URL=http://172.17.0.1:8080/v1 python3 bench.py

Environment:
  LLAMA_URL    server base URL (default http://host.docker.internal:8080/v1)
  MODEL        model name (default: whatever the server has loaded)
  RUNS         measured runs, plus one warm-up (default 3)
  TTFT_WARN_S  warn if the first token takes longer than this (default 3)
  TPS_WARN     warn if generation is slower than this (default 15 tok/s)

Exit codes: 0 = all runs smooth, 1 = at least one warning, 2 = not working.
"""

import json
import os
import sys
import time
import urllib.request

BASE = os.environ.get("LLAMA_URL", "http://host.docker.internal:8080/v1").rstrip("/")
MODEL = os.environ.get("MODEL", "")
RUNS = int(os.environ.get("RUNS", "3"))
TTFT_WARN = float(os.environ.get("TTFT_WARN_S", "3"))
TPS_WARN = float(os.environ.get("TPS_WARN", "15"))

PROMPT = "Write a short poem about the sea, 8 lines."
MAX_TOKENS = 192


def short_model_id(model_id):
    # model ids can be long file paths; show just the last segment
    return model_id.rsplit("/", 1)[-1]


def get_loaded_model():
    """Ask the server which model is loaded."""
    with urllib.request.urlopen(BASE + "/models", timeout=10) as resp:
        data = json.load(resp)
    models = data.get("data", [])
    if not models:
        return ""
    return models[0].get("id", "")


def run_once(model):
    """Send one streaming chat completion and time it.

    Returns a dict with the measurements. Raises on failure.
    """
    body = {
        "model": model,
        "messages": [{"role": "user", "content": PROMPT}],
        "max_tokens": MAX_TOKENS,
        "temperature": 0,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    req = urllib.request.Request(
        BASE + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )

    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=600) as resp:
        ttft = None
        reasoning_tokens = 0
        content_tokens = 0
        usage = None
        timings = None
        end = t0
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[len("data:"):].strip()
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if chunk.get("usage"):
                usage = chunk["usage"]
            if chunk.get("timings"):
                timings = chunk["timings"]
            for choice in chunk.get("choices") or []:
                delta = choice.get("delta") or {}
                if delta.get("reasoning_content"):
                    if ttft is None:
                        ttft = time.monotonic() - t0
                    reasoning_tokens += 1
                if delta.get("content"):
                    if ttft is None:
                        ttft = time.monotonic() - t0
                    content_tokens += 1
            end = time.monotonic()

    total = end - t0
    if ttft is None:
        raise RuntimeError("server sent no tokens")

    completion = (usage or {}).get("completion_tokens")
    tokens = completion if completion else reasoning_tokens + content_tokens

    # generation speed: prefer the server's own measurement, else estimate
    # from the client-side clock (all tokens over the generation window)
    tps = (timings or {}).get("predicted_per_second")
    if not tps:
        gen_time = end - (t0 + ttft)
        tps = tokens / gen_time if gen_time > 0 else 0.0

    return {
        "ttft": ttft,
        "tps": tps,
        "tokens": tokens,
        "reasoning_tokens": reasoning_tokens,
        "content_tokens": content_tokens,
        "total": total,
    }


def main():
    print(f"benchmarking {BASE}")
    try:
        model = MODEL or get_loaded_model()
    except Exception as e:
        print(f"cannot reach {BASE}: {e}")
        print("is the server running? is LLAMA_URL correct?")
        return 2
    if model:
        print(f"model: {short_model_id(model)}")
    print(f'prompt: {PROMPT!r} (max {MAX_TOKENS} tokens)')
    print(f"one warm-up + {RUNS} measured runs")
    print()

    try:
        run_once(model)
    except Exception as e:
        print(f"FAILED on warm-up: {e}")
        print("the server answered /models but not /chat/completions")
        return 2
    print("  warm-up: ok (not counted)")

    results = []
    for i in range(1, RUNS + 1):
        try:
            r = run_once(model)
        except Exception as e:
            print(f"  run {i}: FAILED ({e})")
            return 2
        warn = r["ttft"] > TTFT_WARN or r["tps"] < TPS_WARN
        results.append(r)
        status = "WARN" if warn else "ok  "
        print(f"  run {i}: {status}  first token {r['ttft']:.2f}s   "
              f"{r['tps']:.1f} tok/s   "
              f"({r['tokens']} tokens in {r['total']:.2f}s; "
              f"{r['reasoning_tokens']} thinking + "
              f"{r['content_tokens']} answer)")

    print()
    n = len(results)
    avg_ttft = sum(r["ttft"] for r in results) / n
    avg_tps = sum(r["tps"] for r in results) / n
    print(f"average over {n} runs: first token {avg_ttft:.2f}s, {avg_tps:.1f} tok/s")
    print(f"warn thresholds: first token > {TTFT_WARN:.0f}s or < {TPS_WARN:.0f} tok/s")

    if all(r["ttft"] <= TTFT_WARN and r["tps"] >= TPS_WARN for r in results):
        print("result: PASS - the model is responding smoothly")
        return 0
    print("result: WARN - slower than expected")
    print("  possible causes: the GPU is busy with another job, the model is")
    print("  still loading, or the VRAM headroom is too small (see run-gpu.sh)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
