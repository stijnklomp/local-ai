/**
 * neo4j-memory.js
 *
 * OpenCode plugin that replicates the agent-memory-hooks-neo4j behaviour
 * entirely in Node.js, using Neo4j's HTTP API (port 7474) instead of Bolt.
 *
 * HTTP goes through the sandbox proxy — no Python, no pip, no Bolt issues.
 *
 * Replicates the same graph schema as the upstream repo:
 *   (:Session {session_id, client, created_at})
 *     -[:FIRST_EVENT]->  (:Event)
 *     -[:LATEST_EVENT]-> (:Event)
 *   (:Event {event_id, event_name, client, timestamp, ...})
 *     -[:NEXT]-> (:Event)
 *   (:Memory {path, content, updated_at})
 *
 * Env vars:
 *   HOOKS_NEO4J_HTTP     default: http://host.docker.internal:7474
 *   HOOKS_NEO4J_USER     default: neo4j
 *   HOOKS_NEO4J_PASSWORD default: password
 */

import fs from "fs"
import crypto from "crypto"

const LOG = "/tmp/neo4j-memory.log"
const log = (msg) => {
  try { fs.appendFileSync(LOG, `[${new Date().toISOString()}] ${msg}\n`) } catch (_) {}
}

// ── Neo4j HTTP API client ────────────────────────────────────────────────────

function neo4jConfig() {
  return {
    http:     process.env.HOOKS_NEO4J_HTTP     || "http://host.docker.internal:7474",
    user:     process.env.HOOKS_NEO4J_USER     || "neo4j",
    password: process.env.HOOKS_NEO4J_PASSWORD || "password",
  }
}

async function cypher(statement, parameters = {}) {
  const cfg = neo4jConfig()
  const url = `${cfg.http}/db/neo4j/tx/commit`
  const auth = Buffer.from(`${cfg.user}:${cfg.password}`).toString("base64")

  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "Authorization": `Basic ${auth}`,
    },
    body: JSON.stringify({ statements: [{ statement, parameters }] }),
  })

  if (!res.ok) throw new Error(`Neo4j HTTP ${res.status}: ${await res.text()}`)

  const json = await res.json()
  if (json.errors?.length > 0) throw new Error(`Cypher error: ${json.errors[0].message}`)
  return json
}

// Per-session write queue — serializes writes so concurrent events don't
// deadlock on the LATEST_EVENT relationship delete.
const writeQueues = {}

function enqueueWrite(sessionId, fn) {
  if (!writeQueues[sessionId]) writeQueues[sessionId] = Promise.resolve()
  writeQueues[sessionId] = writeQueues[sessionId]
    .then(fn)
    .catch((err) => log(`write failed [${sessionId}]: ${err.message}`))
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function sanitise(v) {
  if (v == null) return ""
  const s = typeof v === "string" ? v : JSON.stringify(v)
  return s.length > 2000 ? s.slice(0, 2000) + "…" : s
}

function logEvent(sessionId, eventName, extra = {}) {
  const eventId  = crypto.randomUUID()
  const timestamp = new Date().toISOString()

  // MERGE session, delete old LATEST_EVENT, create new Event, link chain
  const stmt = `
    MERGE (s:Session {session_id: $sessionId})
    ON CREATE SET s.client = 'opencode', s.created_at = $timestamp, s.context = $context
    ON MATCH SET s.context = COALESCE(s.context, $context)
    WITH s
    OPTIONAL MATCH (s)-[lr:LATEST_EVENT]->(prev:Event)
    DELETE lr
    WITH s, prev
    CREATE (e:Event {
      event_id:      $eventId,
      event_name:    $eventName,
      client:        'opencode',
      timestamp:     $timestamp,
      cwd:           $cwd,
      tool_name:     $toolName,
      tool_input:    $toolInput,
      tool_response: $toolResponse,
      prompt:        $prompt
    })
    MERGE (s)-[:LATEST_EVENT]->(e)
    WITH s, prev, e
    FOREACH (_ IN CASE WHEN prev IS NULL THEN [1] ELSE [] END |
      MERGE (s)-[:FIRST_EVENT]->(e)
    )
    FOREACH (_ IN CASE WHEN prev IS NOT NULL THEN [1] ELSE [] END |
      MERGE (prev)-[:NEXT]->(e)
    )
  `

  enqueueWrite(sessionId, () => cypher(stmt, {
    sessionId,
    eventId,
    eventName,
    timestamp,
    context:      sanitise(extra.context),
    cwd:          sanitise(extra.cwd),
    toolName:     sanitise(extra.tool_name),
    toolInput:    sanitise(extra.tool_input),
    toolResponse: sanitise(extra.tool_response),
    prompt:       sanitise(extra.prompt),
  }))
}

// Derive context from env var, or fall back to the project directory basename
function getContext(directory) {
  return process.env.MEMORY_CONTEXT || require("path").basename(directory) || "global"
}

async function injectMemory(sessionId, context) {
  try {
    // Inject memories tagged for this context OR tagged as "global"
    const result = await cypher(
      `MATCH (m:Memory)
       WHERE m.context = $context OR m.context = 'global' OR m.context IS NULL
       RETURN m.path AS path, m.content AS content, m.context AS context
       ORDER BY m.updated_at DESC`,
      { context }
    )
    const rows = result.results?.[0]?.data ?? []
    if (rows.length === 0) return null
    const text = rows.map((r) => `### ${r.row[0]}\n${r.row[1]}`).join("\n\n")
    return `## Memories from previous sessions (context: ${context})\n\n${text}`
  } catch (err) {
    log(`injectMemory failed: ${err.message}`)
    return null
  }
}

// ── OpenCode plugin export ───────────────────────────────────────────────────

export const Neo4jMemoryPlugin = async ({ directory, client }) => {
  log("plugin loaded")

  // Dedup sets — track message/call IDs we've already logged this session
  const seenMessages = new Set() // UserPromptSubmit dedup
  const seenCalls    = new Set() // PreToolUse / PostToolUse dedup
  const context      = getContext(directory)
  log(`context: ${context}`)

  return {
    event: async ({ event }) => {
      const sessionId = event.properties?.sessionID || "unknown"

      // ── SessionStart ────────────────────────────────────────────────────
      if (event.type === "session.created") {
        log(`session.created: ${sessionId} [${context}]`)

        // Tag the session node with its context so dream phase can scope memories
        logEvent(sessionId, "SessionStart", { cwd: directory, context })

        const memories = await injectMemory(sessionId, context)
        if (memories) {
          log(`injecting ${memories.length} chars of memory`)
          await client.session.prompt({
            sessionID: sessionId,
            parts: [{ type: "text", text: memories }],
          }).catch((err) => log(`inject prompt failed: ${err.message}`))
        }
      }

      // ── UserPromptSubmit ────────────────────────────────────────────────
      // message.updated fires multiple times per message; dedupe by message ID
      if (event.type === "message.updated" && event.properties?.info?.role === "user") {
        const msgId = event.properties.info.id
        if (msgId && !seenMessages.has(msgId)) {
          seenMessages.add(msgId)
          const prompt = event.properties.info.text || ""
          logEvent(sessionId, "UserPromptSubmit", { cwd: directory, prompt })
        }
      }

      // ── PreToolUse / PostToolUse ────────────────────────────────────────
      // message.part.updated fires multiple times per tool call; dedupe by callID
      if (event.type === "message.part.updated" && event.properties?.part?.type === "tool") {
        const part   = event.properties.part
        const status = part.state?.status
        const callId = part.callID || part.id

        if (status === "running" && callId && !seenCalls.has(`pre:${callId}`)) {
          seenCalls.add(`pre:${callId}`)
          logEvent(sessionId, "PreToolUse", {
            cwd:        directory,
            tool_name:  part.tool,
            tool_input: part.state?.input,
          })
        }

        if (status === "completed" && callId && !seenCalls.has(`post:${callId}`)) {
          seenCalls.add(`post:${callId}`)
          logEvent(sessionId, "PostToolUse", {
            cwd:           directory,
            tool_name:     part.tool,
            tool_input:    part.state?.input,
            tool_response: part.state?.output,
          })
        }
      }

      // ── Stop ────────────────────────────────────────────────────────────
      // session.idle fires once per completed response; dedupe rapid double-fires
      if (event.type === "session.idle") {
        const now  = Date.now()
        const last = Neo4jMemoryPlugin._lastIdle?.[sessionId] || 0
        if (now - last > 2000) {
          Neo4jMemoryPlugin._lastIdle = Neo4jMemoryPlugin._lastIdle || {}
          Neo4jMemoryPlugin._lastIdle[sessionId] = now
          log(`session idle (Stop): ${sessionId}`)
          logEvent(sessionId, "Stop", { cwd: directory })
        }
      }

      if (event.type === "session.deleted") {
        log(`session deleted: ${sessionId}`)
        logEvent(sessionId, "Stop", { cwd: directory })
      }
    },
  }
}
