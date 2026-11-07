#!/usr/bin/env node
// OpenAI-compatible repair proxy in front of Ollama, for agentmemory only.
//
// Why this exists:
//   - agentmemory's compression/summary parser rejects a literal `&` that is not
//     an XML entity and any raw `<` inside a text field. Local models copy shell
//     commands containing `&&` and code such as `a < b` verbatim, so the output
//     fails validation even though it is otherwise well-formed.
//   - agentmemory's client sends no temperature, and before Ollama 0.40.14 the
//     /v1 endpoint ignored Modelfile defaults. Forcing greedy sampling here also
//     keeps local models on the strict XML contract.
//
// It injects temperature/top_p only when the request omits them, caps the
// output length of observation-compression requests, and repairs bare
// ampersands plus stray `<`/`>` in the text-only XML fields (see
// agentmemory-xml-repair.mjs). Every other path is proxied verbatim.
//
// Why the cap: agentmemory hardcodes COMPRESSION_TIMEOUT_MS = 60s for a
// compression attempt *including* its automatic stricter retry, while it sends
// MAX_TOKENS = 4096. A verbose local model can spend the whole budget on one
// generation and the observation is marked compression_failed. Compression
// output is a short XML record, so COMPRESSION_MAX_TOKENS (default 800) is
// plenty; session summaries and every other call keep their requested limit.
//
// Usage:
//   PORT=11435 UPSTREAM=http://127.0.0.1:11434 node agentmemory-ollama-proxy.mjs
//   OPENAI_BASE_URL=http://localhost:11435/v1
//
// Backpressure:
//   agentmemory has no global cap on concurrent LLM work: every session (and
//   every subagent, which is its own session) triggers live compression on its
//   own observation batches. Without a gate, N parallel agents turn into N
//   concurrent 12B generations, each slower than the 60s compression deadline,
//   so they time out, fail, and feed the retry worker — a widening loop.
//
//   This proxy admits at most MAX_INFLIGHT chat completions at a time and holds
//   up to MAX_QUEUE compression requests in a FIFO. Beyond that it answers 503
//   with Retry-After immediately, so the caller fails fast and keeps the
//   observation raw instead of queueing work it will never finish in time.
//   Non-compression calls (session summaries, consolidation, query expansion)
//   are few and valuable: they jump ahead of queued compression in the same
//   semaphore and are not counted against the compression queue limit.
//
//   GET /proxy/metrics returns the live counters as JSON.
//
// Environment:
//   PORT                      listen port (default 11435)
//   UPSTREAM                  Ollama base URL (default http://127.0.0.1:11434)
//   TIMEOUT_MS                upstream request budget (default 600000)
//   COMPRESSION_MAX_TOKENS    max_tokens for compression requests (default 800)
//   MAX_INFLIGHT              concurrent chat completions (default 2)
//   MAX_QUEUE                 queued requests per class (default 8)
//   RETRY_AFTER_SECONDS       Retry-After on 503 (default 30)
//   DEBUG=1                   log request rewrites (capping) to stderr

import http from "node:http";

import { repairContent } from "./agentmemory-xml-repair.mjs";

const PORT = Number(process.env.PORT || 11435);
const UPSTREAM = (process.env.UPSTREAM || "http://127.0.0.1:11434").replace(/\/+$/, "");
const TEMPERATURE = process.env.TEMPERATURE ?? "0";
const TOP_P = process.env.TOP_P ?? "0.1";
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS || 600000);
const COMPRESSION_MAX_TOKENS = positiveInt(process.env.COMPRESSION_MAX_TOKENS, 800);
const MAX_INFLIGHT = positiveInt(process.env.MAX_INFLIGHT, 2);
const MAX_QUEUE = positiveInt(process.env.MAX_QUEUE, 8);
const RETRY_AFTER_SECONDS = positiveInt(process.env.RETRY_AFTER_SECONDS, 30);
const DEBUG = process.env.DEBUG === "1";

// agentmemory's COMPRESSION_SYSTEM prompt starts with this sentence. The
// summary, query-expansion and consolidation prompts use different openings,
// so this keeps the cap scoped to observation compression.
const COMPRESSION_SYSTEM_PREFIX = "You are a memory compression engine";

function positiveInt(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

function isCompressionRequest(payload) {
  const messages = payload?.messages;
  if (!Array.isArray(messages)) return false;
  return messages.some((message) => {
    if (message?.role !== "system") return false;
    const content = message.content;
    return typeof content === "string" && content.trimStart().startsWith(COMPRESSION_SYSTEM_PREFIX);
  });
}

// Returns true when the request was rewritten.
function capCompressionTokens(payload) {
  if (!isCompressionRequest(payload)) return false;
  const current = Number(payload.max_tokens);
  if (Number.isFinite(current) && current > 0 && current <= COMPRESSION_MAX_TOKENS) return false;
  payload.max_tokens = COMPRESSION_MAX_TOKENS;
  return true;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

// --- admission control ------------------------------------------------------
// One semaphore for every chat completion. Compression requests are counted
// against MAX_QUEUE; the rarer summary/consolidation calls get priority and
// are not dropped ahead of compression, because a lost summary is permanent
// while a rejected compression is simply left raw for the retry worker.
const stats = {
  inflight: 0,
  queuedCompression: 0,
  queuedOther: 0,
  rejected: 0,
  completed: 0,
  startedAt: Date.now(),
};

const waiters = [];
let lastRejectLog = 0;

function queueDepth() {
  return stats.queuedCompression + stats.queuedOther;
}

function metricsSnapshot() {
  return {
    inflight: stats.inflight,
    queued: queueDepth(),
    queuedCompression: stats.queuedCompression,
    queuedOther: stats.queuedOther,
    rejected: stats.rejected,
    completed: stats.completed,
    maxInflight: MAX_INFLIGHT,
    maxQueue: MAX_QUEUE,
    uptimeMs: Date.now() - stats.startedAt,
  };
}

function removeWaiter(waiter) {
  const index = waiters.indexOf(waiter);
  if (index === -1) return;
  waiters.splice(index, 1);
  if (waiter.isCompression) stats.queuedCompression -= 1;
  else stats.queuedOther -= 1;
}

// Resolves to "ok", "full" or "aborted".
function acquireSlot(isCompression, signal) {
  if (stats.inflight < MAX_INFLIGHT) {
    stats.inflight += 1;
    return Promise.resolve("ok");
  }
  const queued = isCompression ? stats.queuedCompression : stats.queuedOther;
  if (queued >= MAX_QUEUE) return Promise.resolve("full");

  return new Promise((resolve) => {
    const waiter = {
      isCompression,
      settled: false,
      grant() {
        if (waiter.settled) return;
        waiter.settled = true;
        cleanup();
        resolve("ok");
      },
      cancel() {
        if (waiter.settled) return;
        waiter.settled = true;
        cleanup();
        removeWaiter(waiter);
        resolve("aborted");
      },
    };
    const cleanup = () => signal.removeEventListener("abort", waiter.cancel);
    signal.addEventListener("abort", waiter.cancel, { once: true });

    // Non-compression first, FIFO within each class.
    if (isCompression) {
      waiters.push(waiter);
      stats.queuedCompression += 1;
    } else {
      let index = waiters.findIndex((candidate) => candidate.isCompression);
      if (index === -1) index = waiters.length;
      waiters.splice(index, 0, waiter);
      stats.queuedOther += 1;
    }
  });
}

function releaseSlot() {
  const next = waiters.shift();
  if (!next) {
    stats.inflight = Math.max(0, stats.inflight - 1);
    return;
  }
  if (next.isCompression) stats.queuedCompression -= 1;
  else stats.queuedOther -= 1;
  // The slot passes directly to the waiter; inflight stays the same.
  next.grant();
}

function logRejection(isCompression) {
  const now = Date.now();
  if (now - lastRejectLog < 10000) return;
  lastRejectLog = now;
  console.error(
    `[proxy] overloaded: inflight=${stats.inflight} queued=${queueDepth()} ` +
      `(${stats.queuedCompression} compression); rejecting ${isCompression ? "compression" : "other"} request`,
  );
}

const server = http.createServer(async (req, res) => {
  // Per-request abort wiring: if the client (agentmemory) gives up before the
  // response is complete, abort the upstream fetch so Ollama stops generating
  // tokens nobody will read. `res` "close" fires on normal completion too, so it
  // only counts as a client abort while the response is still writable.
  const controller = new AbortController();
  let clientClosed = false;

  const onClientGone = () => {
    if (res.writableEnded) return;
    clientClosed = true;
    controller.abort();
  };

  res.on("close", onClientGone);
  req.on("aborted", onClientGone);

  let slotHeld = false;

  try {
    const pathname = req.url.split("?")[0];

    if (req.method === "GET" && (pathname === "/proxy/metrics" || pathname === "/metrics")) {
      const payload = Buffer.from(JSON.stringify(metricsSnapshot()));
      res.writeHead(200, {
        "content-type": "application/json",
        "content-length": Buffer.byteLength(payload),
      });
      res.end(payload);
      return;
    }

    const isChat = req.method === "POST" && pathname.endsWith("/chat/completions");
    let body = await readBody(req);
    let compression = false;

    if (isChat && body.length > 0) {
      try {
        const payload = JSON.parse(body.toString("utf8"));
        compression = isCompressionRequest(payload);
        if (payload.temperature === undefined) payload.temperature = Number(TEMPERATURE);
        if (payload.top_p === undefined) payload.top_p = Number(TOP_P);
        const capped = capCompressionTokens(payload);
        body = Buffer.from(JSON.stringify(payload));
        if (capped && DEBUG) {
          console.error(
            `[proxy] capped compression max_tokens to ${COMPRESSION_MAX_TOKENS}: ${req.method} ${pathname}`,
          );
        }
      } catch {
        // Not JSON: forward untouched and let Ollama report the error.
      }
    }

    if (isChat) {
      const outcome = await acquireSlot(compression, controller.signal);
      if (outcome === "aborted") return;
      if (outcome === "full") {
        stats.rejected += 1;
        logRejection(compression);
        if (res.writableEnded || res.destroyed) return;
        res.writeHead(503, {
          "content-type": "application/json",
          "retry-after": String(RETRY_AFTER_SECONDS),
        });
        res.end(
          JSON.stringify({
            error: {
              message: "agentmemory-ollama-proxy: overloaded, retry later",
              type: "overloaded",
            },
          }),
        );
        return;
      }
      slotHeld = true;
    }

    const upstream = await fetch(`${UPSTREAM}${req.url}`, {
      method: req.method,
      headers: {
        "content-type": req.headers["content-type"] || "application/json",
        ...(req.headers.authorization ? { authorization: req.headers.authorization } : {}),
      },
      body: req.method === "GET" || req.method === "HEAD" ? undefined : body,
      signal: AbortSignal.any([AbortSignal.timeout(TIMEOUT_MS), controller.signal]),
    });

    let out = Buffer.from(await upstream.arrayBuffer());
    let repaired = 0;

    if (isChat && (upstream.headers.get("content-type") || "").includes("application/json")) {
      try {
        const data = JSON.parse(out.toString("utf8"));
        if (Array.isArray(data.choices)) {
          for (const choice of data.choices) {
            if (choice?.message && typeof choice.message.content === "string") {
              const fixed = repairContent(choice.message.content);
              if (fixed !== choice.message.content) {
                choice.message.content = fixed;
                repaired += 1;
              }
            }
          }
        }
        out = Buffer.from(JSON.stringify(data));
      } catch {
        // Leave the response untouched if it is not the JSON shape we expect.
      }
    }

    res.writeHead(upstream.status, {
      "content-type": upstream.headers.get("content-type") || "application/json",
      "content-length": Buffer.byteLength(out),
    });
    res.end(out);
    if (isChat) stats.completed += 1;

    if (repaired > 0) {
      console.error(`[proxy] repaired XML in ${repaired} choice(s): ${req.method} ${pathname}`);
    }
  } catch (err) {
    // A client-originated abort is expected (agentmemory's 60s compression /
    // 120s summary cap) and already did its job; stay quiet and don't answer.
    if (clientClosed) return;

    const message =
      err?.name === "TimeoutError"
        ? `upstream timed out after ${TIMEOUT_MS}ms`
        : String(err?.message || err);
    console.error(`[proxy] ${req.method} ${req.url} -> 502 ${message}`);
    if (res.writableEnded || res.destroyed) return;
    res.writeHead(502, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        error: { message: `agentmemory-ollama-proxy: ${message}`, type: "proxy_error" },
      }),
    );
  } finally {
    if (slotHeld) releaseSlot();
    res.off("close", onClientGone);
    req.off("aborted", onClientGone);
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.error(
    `[proxy] listening on http://127.0.0.1:${PORT} -> ${UPSTREAM} ` +
      `(maxInflight=${MAX_INFLIGHT} maxQueue=${MAX_QUEUE})`,
  );
});
