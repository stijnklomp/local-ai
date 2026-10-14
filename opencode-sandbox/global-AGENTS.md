# Global agent instructions

- agentmemory MCP tools: provide `concepts` and `files` as comma-separated strings (for example `jwt-refresh-rotation, auth`), never as arrays or JSON. The MCP schema rejects arrays; the server splits the strings and stores proper lists internally.
- agentmemory is not guaranteed to be available. When it is offline, the MCP tools fall back to a local-only store that never syncs to the host, so memory persistence is not guaranteed. This is by design; still use the tools normally.
