#!/usr/bin/env node
// agentmemory-proxy.mjs
// Forwards 127.0.0.1:3111 to the host agentmemory server (host.docker.internal:3111),
// replacing the old socat proxy with a zero-dependency Node script.

import net from "node:net";

const LISTEN_HOST = "127.0.0.1";
const LISTEN_PORT = 3111;
const TARGET_HOST = "host.docker.internal";
const TARGET_PORT = 3111;

const server = net.createServer((client) => {
  const upstream = net.connect(TARGET_PORT, TARGET_HOST, () => {
    client.pipe(upstream);
    upstream.pipe(client);
  });
  upstream.on("error", () => client.destroy());
  client.on("error", () => upstream.destroy());
});

server.on("error", (err) => {
  if (err.code === "EADDRINUSE") {
    console.log(`agentmemory proxy already running on ${LISTEN_HOST}:${LISTEN_PORT}; exiting.`);
    process.exit(0);
  }
  console.error("agentmemory proxy error:", err);
  process.exit(1);
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(`agentmemory proxy listening on ${LISTEN_HOST}:${LISTEN_PORT} -> ${TARGET_HOST}:${TARGET_PORT}`);
});