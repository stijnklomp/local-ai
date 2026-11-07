Explicitly save an insight, decision, or learning to agentmemory for future sessions. Wraps the `agentmemory_memory_save` MCP tool (OpenCode prefixes MCP tool names with the server name).

## Usage

```
/remember [what to remember]
```

## Instructions

1. Analyze what needs to be remembered — extract the core insight, decision, or fact.
2. Extract 2-5 searchable concepts (lowercased keyword phrases). Prefer specific terms ("jwt-refresh-rotation" over "auth").
3. Extract relevant file paths the memory references.
4. Call `agentmemory_memory_save` with:
   - `content` — full text to remember (preserve user's phrasing)
   - `concepts` — comma-separated string of the extracted concepts
   - `files` — comma-separated string of the extracted file paths (empty string if none)
   - `type` — choose from: pattern, preference, architecture, bug, workflow, fact
5. Confirm the save and show the concepts tagged so the user knows retrieval terms.