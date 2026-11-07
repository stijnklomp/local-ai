Search past session observations and lessons for relevant context. Wrap the `agentmemory_memory_smart_search` and `agentmemory_memory_lesson_recall` MCP tools (OpenCode prefixes MCP tool names with the server name).

## Usage

```
/recall [query]
```

## Instructions

1. Call `agentmemory_memory_smart_search` with the query and `limit: 10` (hybrid BM25 + vector + graph search).
2. Call `agentmemory_memory_lesson_recall` with the same query and `limit: 5` (lesson search).
3. Combine results and present to the user:
   - Group by session
   - Show type, title, and narrative for each observation
   - Highlight high-importance (>= 7) observations
   - Show lessons separately with confidence scores
4. If no results, suggest 2-3 alternative search terms.
5. **Never hallucinate results.** Only present what the MCP tools actually return.