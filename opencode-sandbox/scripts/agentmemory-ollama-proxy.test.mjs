// Tests for agentmemory-ollama-proxy.mjs: the proxy must propagate client
// aborts upstream (so Ollama stops generating unread tokens) and keep repairing
// XML on the normal path.
//
//   node --test scripts/agentmemory-ollama-proxy.test.mjs

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import http from "node:http";
import net from "node:net";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const PROXY = path.join(path.dirname(fileURLToPath(import.meta.url)), "agentmemory-ollama-proxy.mjs");

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

async function waitForPort(port, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const ok = await new Promise((resolve) => {
      const socket = net.connect({ port, host: "127.0.0.1" });
      socket.once("connect", () => {
        socket.destroy();
        resolve(true);
      });
      socket.once("error", () => resolve(false));
    });
    if (ok) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`proxy did not listen on 127.0.0.1:${port} within ${timeoutMs}ms`);
}

async function startProxy(upstreamPort) {
  const port = await freePort();
  const child = spawn(process.execPath, [PROXY], {
    env: {
      ...process.env,
      PORT: String(port),
      UPSTREAM: `http://127.0.0.1:${upstreamPort}`,
      TIMEOUT_MS: "600000",
    },
    stdio: ["ignore", "ignore", "pipe"],
  });

  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });

  try {
    await waitForPort(port);
  } catch (err) {
    child.kill("SIGKILL");
    throw new Error(`${err.message}\nproxy stderr:\n${stderr}`);
  }

  return { child, port, stderr: () => stderr };
}

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
}

function close(server) {
  server.closeAllConnections?.();
  return new Promise((resolve) => server.close(() => resolve()));
}

function withDeadline(promise, ms, message) {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), ms);
  });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}

function postChat(port, body) {
  const req = http.request({
    host: "127.0.0.1",
    port,
    method: "POST",
    path: "/v1/chat/completions",
    headers: { "content-type": "application/json" },
  });
  // Aborts and proxy restarts are expected in these tests; don't crash the run.
  req.on("error", () => {});
  req.end(JSON.stringify(body));
  return req;
}

test("client abort closes the upstream request and stays quiet", { timeout: 30000 }, async () => {
  let sawRequest;
  const requestSeen = new Promise((resolve) => {
    sawRequest = resolve;
  });
  let sawClose;
  const requestClosed = new Promise((resolve) => {
    sawClose = resolve;
  });

  // Mock upstream: record the request, then deliberately never respond.
  const upstream = http.createServer((req, res) => {
    sawRequest();
    let closed = false;
    const done = () => {
      if (closed) return;
      closed = true;
      sawClose();
    };
    req.on("close", done);
    res.on("close", done);
  });
  await listen(upstream);
  const upstreamPort = upstream.address().port;

  const { child, port, stderr } = await startProxy(upstreamPort);
  try {
    const client = postChat(port, { messages: [{ role: "user", content: "hello" }] });

    await withDeadline(requestSeen, 5000, "mock upstream never saw the proxied request");
    client.destroy();

    await withDeadline(
      requestClosed,
      5000,
      "upstream request stayed open after the client aborted",
    );

    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(child.exitCode, null, `proxy exited after a client abort:\n${stderr()}`);
    assert.doesNotMatch(stderr(), /-> 502/, "proxy logged a 502 for a client abort");
  } finally {
    child.kill("SIGKILL");
    await close(upstream);
  }
});

test("normal chat response is still repaired", { timeout: 30000 }, async () => {
  const upstream = http.createServer((req, res) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      body += chunk;
    });
    req.on("end", () => {
      const payload = JSON.parse(body);
      assert.equal(payload.temperature, 0);
      assert.equal(payload.top_p, 0.1);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          choices: [
            {
              message: {
                role: "assistant",
                content:
                  "<observation><title>shell</title><fact>run cmd && a < b</fact></observation>",
              },
            },
          ],
        }),
      );
    });
  });
  await listen(upstream);
  const upstreamPort = upstream.address().port;

  const { child, port } = await startProxy(upstreamPort);
  try {
    const payload = await new Promise((resolve, reject) => {
      const req = http.request(
        {
          host: "127.0.0.1",
          port,
          method: "POST",
          path: "/v1/chat/completions",
          headers: { "content-type": "application/json" },
        },
        (res) => {
          let out = "";
          res.setEncoding("utf8");
          res.on("data", (chunk) => {
            out += chunk;
          });
          res.on("end", () => resolve({ status: res.statusCode, body: JSON.parse(out) }));
        },
      );
      req.on("error", reject);
      req.end(JSON.stringify({ messages: [{ role: "user", content: "hi" }] }));
    });

    assert.equal(payload.status, 200);
    assert.equal(
      payload.body.choices[0].message.content,
      "<observation><title>shell</title><fact>run cmd &amp;&amp; a &lt; b</fact></observation>",
    );
  } finally {
    child.kill("SIGKILL");
    await close(upstream);
  }
});
