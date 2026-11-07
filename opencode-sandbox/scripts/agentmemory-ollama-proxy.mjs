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
// It injects temperature/top_p only when the request omits them, and repairs
// bare ampersands plus stray `<`/`>` in the text-only XML fields (see
// agentmemory-xml-repair.mjs). Every other path is proxied verbatim.
//
// Usage:
//   PORT=11435 UPSTREAM=http://127.0.0.1:11434 node agentmemory-ollama-proxy.mjs
//   OPENAI_BASE_URL=http://localhost:11435/v1

import http from "node:http";

import { repairContent } from "./agentmemory-xml-repair.mjs";

const PORT = Number(process.env.PORT || 11435);
const UPSTREAM = (process.env.UPSTREAM || "http://127.0.0.1:11434").replace(/\/+$/, "");
const TEMPERATURE = process.env.TEMPERATURE ?? "0";
const TOP_P = process.env.TOP_P ?? "0.1";
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS || 600000);

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
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

  try {
    const pathname = req.url.split("?")[0];
    const isChat = req.method === "POST" && pathname.endsWith("/chat/completions");
    let body = await readBody(req);

    if (isChat && body.length > 0) {
      try {
        const payload = JSON.parse(body.toString("utf8"));
        if (payload.temperature === undefined) payload.temperature = Number(TEMPERATURE);
        if (payload.top_p === undefined) payload.top_p = Number(TOP_P);
        body = Buffer.from(JSON.stringify(payload));
      } catch {
        // Not JSON: forward untouched and let Ollama report the error.
      }
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
    res.off("close", onClientGone);
    req.off("aborted", onClientGone);
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.error(`[proxy] listening on http://127.0.0.1:${PORT} -> ${UPSTREAM}`);
});
