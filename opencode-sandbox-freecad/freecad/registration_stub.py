#!/usr/bin/env python3
"""Temporary unauthenticated MCP endpoint for `sbx mcp add` discovery.

`sbx mcp add` contacts the URL before storing a registration. FreeCAD is not
running during one-time setup, so this stub answers the discovery probe and is
stopped immediately after registration. It exposes no real tools and binds
only to loopback.
"""

import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL_VERSION = "2025-03-26"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _reply(self, status, payload=None):
        body = b"" if payload is None else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        if payload is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        # No OAuth metadata here: a 404 tells discovery this is a plain MCP
        # endpoint, not an OAuth-protected resource.
        self._reply(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            self._reply(400)
            return

        method = message.get("method", "")
        message_id = message.get("id")

        if method in ("notifications/initialized", "notifications/cancelled"):
            self._reply(204)
            return

        if method == "initialize":
            result = {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {
                    "name": "FreeCAD AI (registration stub)",
                    "version": "1.0",
                },
            }
        elif method == "tools/list":
            result = {"tools": []}
        elif method == "ping":
            result = {}
        elif method == "server/discover":
            result = {
                "supportedVersions": [PROTOCOL_VERSION],
                "capabilities": {"tools": {}},
                "instructions": "Temporary registration stub.",
            }
        else:
            self._reply(
                200,
                {
                    "jsonrpc": "2.0",
                    "id": message_id,
                    "error": {"code": -32601, "message": "Method not found"},
                },
            )
            return

        self._reply(
            200,
            {"jsonrpc": "2.0", "id": message_id, "result": result},
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=3000)
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    threading.Timer(args.timeout, server.shutdown).start()
    print(
        "registration stub listening on http://127.0.0.1:%d/mcp" % args.port,
        file=sys.stderr,
        flush=True,
    )
    server.serve_forever()
    server.server_close()


if __name__ == "__main__":
    main()
