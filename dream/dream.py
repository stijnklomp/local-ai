#!/usr/bin/env python3
"""
dream.py — offline memory consolidation phase for agent-memory-hooks-neo4j.

Reads accumulated session events from Neo4j (via HTTP API), asks a local
Ollama model to distil them into durable markdown memory files, then writes
the results back as (:Memory) nodes.

Usage:
    python dream.py
    python dream.py --since 24h
    python dream.py --since 7d
    python dream.py --session <session_id>
    python dream.py --dry-run
    python dream.py --model qwen3:14b
    python dream.py --ollama-url http://host.docker.internal:11434

Environment variables (all optional, defaults shown):
    HOOKS_NEO4J_HTTP      http://host.docker.internal:7474
    HOOKS_NEO4J_USER      neo4j
    HOOKS_NEO4J_PASSWORD  password
    DREAM_MODEL           qwen3:14b
    DREAM_OLLAMA_URL      http://host.docker.internal:11434
"""

import argparse
import json
import re
import sys
import urllib.request
import urllib.error
from base64 import b64encode
from datetime import datetime, timedelta, timezone


# ── Config ────────────────────────────────────────────────────────────────────

import os

NEO4J_HTTP     = os.environ.get("HOOKS_NEO4J_HTTP",     "http://host.docker.internal:7474")
NEO4J_USER     = os.environ.get("HOOKS_NEO4J_USER",     "neo4j")
NEO4J_PASSWORD = os.environ.get("HOOKS_NEO4J_PASSWORD", "password")
OLLAMA_URL     = os.environ.get("DREAM_OLLAMA_URL",     "http://host.docker.internal:11434")
DEFAULT_MODEL  = os.environ.get("DREAM_MODEL",          "qwen3:14b")


# ── Neo4j HTTP helpers ────────────────────────────────────────────────────────

def neo4j_request(statement, parameters=None):
    url = f"{NEO4J_HTTP}/db/neo4j/tx/commit"
    auth = b64encode(f"{NEO4J_USER}:{NEO4J_PASSWORD}".encode()).decode()
    payload = json.dumps({
        "statements": [{"statement": statement, "parameters": parameters or {}}]
    }).encode()
    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Basic {auth}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read())
    if data.get("errors"):
        raise RuntimeError(f"Cypher error: {data['errors'][0]['message']}")
    return data


def cypher_rows(statement, parameters=None):
    data = neo4j_request(statement, parameters)
    result = data.get("results", [{}])[0]
    columns = result.get("columns", [])
    rows = []
    for row in result.get("data", []):
        rows.append(dict(zip(columns, row["row"])))
    return rows


# ── Ollama helpers ────────────────────────────────────────────────────────────

def ollama_chat(model, messages, think=False):
    """
    Call Ollama's OpenAI-compatible /v1/chat/completions endpoint.
    Set think=False to suppress <think>…</think> tokens from reasoning models.
    """
    url = f"{OLLAMA_URL}/v1/chat/completions"
    payload = json.dumps({
        "model": model,
        "messages": messages,
        "stream": False,
        "options": {
            "temperature": 0.2,
        },
        **({"think": False} if not think else {}),
    }).encode()
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            data = json.loads(resp.read())
    except urllib.error.URLError as e:
        raise RuntimeError(f"Ollama request failed: {e}") from e

    content = data["choices"][0]["message"]["content"]
    # Strip residual <think>…</think> blocks that some models emit
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
    return content


# ── Session event fetching ────────────────────────────────────────────────────

def fetch_sessions(since_dt=None, session_id=None):
    if session_id:
        rows = cypher_rows(
            "MATCH (s:Session {session_id: $sid}) RETURN s.session_id AS id, s.context AS context, s.created_at AS created_at",
            {"sid": session_id},
        )
    elif since_dt:
        rows = cypher_rows(
            "MATCH (s:Session) WHERE s.created_at >= $since RETURN s.session_id AS id, s.context AS context, s.created_at AS created_at ORDER BY s.created_at",
            {"since": since_dt.isoformat()},
        )
    else:
        rows = cypher_rows(
            "MATCH (s:Session) WHERE s.dream_watermark IS NULL OR s.dream_watermark < s.created_at "
            "RETURN s.session_id AS id, s.context AS context, s.created_at AS created_at ORDER BY s.created_at"
        )
    return rows


def fetch_events_for_session(session_id):
    rows = cypher_rows(
        """
        MATCH (s:Session {session_id: $sid})-[:FIRST_EVENT]->(first:Event)
        MATCH path = (first)-[:NEXT*0..]->(e:Event)
        WHERE NOT (e)-[:NEXT]->()
        WITH nodes(path) AS events
        UNWIND events AS e
        RETURN e.event_name AS event_name,
               e.timestamp  AS timestamp,
               e.tool_name  AS tool_name,
               e.tool_input AS tool_input,
               e.tool_response AS tool_response,
               e.prompt     AS prompt
        ORDER BY e.timestamp
        """,
        {"sid": session_id},
    )
    return rows


def fetch_existing_memories(context=None):
    if context and context != "global":
        rows = cypher_rows(
            "MATCH (m:Memory) WHERE m.context = $ctx OR m.context = 'global' OR m.context IS NULL "
            "RETURN m.path AS path, m.content AS content, m.context AS context",
            {"ctx": context},
        )
    else:
        rows = cypher_rows(
            "MATCH (m:Memory) RETURN m.path AS path, m.content AS content, m.context AS context"
        )
    return rows


# ── Prompt construction ───────────────────────────────────────────────────────

SYSTEM_PROMPT = """/no_think
You are a memory consolidation agent. Your job is to read a log of an AI coding session and update a set of persistent markdown memory files that will be injected into future sessions.

## Priority order — what to save

1. **Explicit memory requests** — if the user said anything like "remember", "note that", "my name is", "I prefer", "always do X", "never do Y" — this is the HIGHEST priority. Save it immediately under the most relevant path, verbatim where possible.

2. **Personal facts** — name, role, location, languages spoken, communication preferences.

3. **Stable preferences** — language/framework choices, code style, tooling, workflow habits that appeared consistently across the session.

4. **Project decisions** — architecture choices, naming conventions, constraints the user stated explicitly.

## What NOT to save

- One-off commands or queries (running `ls`, asking what day it is, debugging a single error)
- The content of tool outputs
- Anything the user said only in passing without indicating it should be remembered
- Meta-commentary about the session itself
- Information about the AI model being used

## Rules

- Each memory is a markdown file at a semantic path: `profile/name.md`, `profile/preferences.md`, `project/<name>/decisions.md`, `tools/<tool>/workflow.md`
- Files use YAML frontmatter followed by concise markdown prose — a few sentences maximum
- MERGE, don't append — rewrite existing files if new info extends or contradicts them
- If nothing worth saving happened in the session, return an empty array []
- Output ONLY a valid JSON array. No explanation, no markdown fences, no preamble.

## Output format

[
  {
    "path": "profile/name.md",
    "content": "---\\nupdated: 2026-05-21\\n---\\n\\nPrefers TypeScript.",
    "action": "upsert"
  },
  {
    "path": "project/old-thing/notes.md",
    "action": "delete"
  }
]
"""


def build_user_prompt(events, existing_memories):
    lines = ["## Session events\n"]
    for e in events:
        line = f"[{e.get('timestamp', '')}] {e.get('event_name', '')}"
        if e.get("tool_name"):
            line += f" — tool: {e['tool_name']}"
        if e.get("prompt"):
            prompt_preview = e["prompt"][:1000].replace("\n", " ")
            line += f" — prompt: {prompt_preview}"
        if e.get("tool_input"):
            inp = str(e["tool_input"])[:200].replace("\n", " ")
            line += f" — input: {inp}"
        lines.append(line)

    lines.append("\n## Current memory files\n")
    if existing_memories:
        for m in existing_memories:
            lines.append(f"### {m['path']} (context: {m.get('context') or 'global'})")
            lines.append(m.get("content") or "")
            lines.append("")
    else:
        lines.append("(none yet)")

    lines.append("\nUpdate the memory files based on what happened in this session.")
    return "\n".join(lines)


# ── Memory writing ────────────────────────────────────────────────────────────

def apply_memory_updates(updates, context, dry_run):
    now = datetime.now(timezone.utc).isoformat()
    for update in updates:
        path = update.get("path", "").strip()
        action = update.get("action", "upsert")
        if not path:
            continue

        if action == "delete":
            print(f"  {'[dry-run] ' if dry_run else ''}delete  {path}")
            if not dry_run:
                neo4j_request("MATCH (m:Memory {path: $path}) DETACH DELETE m", {"path": path})

        else:
            content = update.get("content", "")
            mem_ctx = update.get("context", context or "global")
            print(f"  {'[dry-run] ' if dry_run else ''}upsert  {path}  [{mem_ctx}]")
            if not dry_run:
                neo4j_request(
                    "MERGE (m:Memory {path: $path}) "
                    "SET m.content = $content, m.context = $ctx, m.updated_at = $now",
                    {"path": path, "content": content, "ctx": mem_ctx, "now": now},
                )


def mark_session_dreamed(session_id, dry_run):
    if not dry_run:
        neo4j_request(
            "MATCH (s:Session {session_id: $sid}) SET s.dream_watermark = $now",
            {"sid": session_id, "now": datetime.now(timezone.utc).isoformat()},
        )


# ── Parse --since flag ────────────────────────────────────────────────────────

def parse_since(since_str):
    now = datetime.now(timezone.utc)
    m = re.fullmatch(r"(\d+)([hHdDwW])", since_str.strip())
    if not m:
        raise ValueError(f"Invalid --since value '{since_str}'. Use e.g. 24h, 7d, 2w.")
    n, unit = int(m.group(1)), m.group(2).lower()
    delta = {"h": timedelta(hours=n), "d": timedelta(days=n), "w": timedelta(weeks=n)}[unit]
    return now - delta


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    global OLLAMA_URL

    parser = argparse.ArgumentParser(description="Dream phase: consolidate session events into memories.")
    parser.add_argument("--since",   help="Only process sessions created within this window, e.g. 24h, 7d")
    parser.add_argument("--session", help="Process a single session by ID")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be written without saving")
    parser.add_argument("--context", help="Override the context tag for all processed sessions (default: use each session's own context)")
    parser.add_argument("--model",     default=DEFAULT_MODEL, help=f"Ollama model to use (default: {DEFAULT_MODEL})")
    parser.add_argument("--ollama-url", default=OLLAMA_URL, help=f"Ollama base URL (default: {OLLAMA_URL})")
    args = parser.parse_args()

    OLLAMA_URL = args.ollama_url

    since_dt = parse_since(args.since) if args.since else None

    print(f"Dream phase — model: {args.model}  ollama: {OLLAMA_URL}  neo4j: {NEO4J_HTTP}")
    if args.dry_run:
        print("DRY RUN — no writes will be made\n")

    # Test Neo4j connection
    try:
        neo4j_request("RETURN 1")
    except Exception as e:
        print(f"ERROR: Cannot reach Neo4j at {NEO4J_HTTP}: {e}", file=sys.stderr)
        sys.exit(1)

    # Test Ollama connection
    try:
        ollama_chat(args.model, [{"role": "user", "content": "ping"}])
    except Exception as e:
        print(f"ERROR: Cannot reach Ollama at {OLLAMA_URL} with model {args.model}: {e}", file=sys.stderr)
        sys.exit(1)

    sessions = fetch_sessions(since_dt=since_dt, session_id=args.session)
    if not sessions:
        print("No sessions to process.")
        return

    print(f"Processing {len(sessions)} session(s)…\n")

    for sess in sessions:
        sid = sess["id"]
        context = args.context or sess.get("context") or "global"
        print(f"Session {sid}  [context: {context}]")

        events = fetch_events_for_session(sid)
        if not events:
            print("  No events found, skipping.\n")
            continue

        # Cap at most recent 60 events to avoid oversized prompts with large models
        MAX_EVENTS = 60
        if len(events) > MAX_EVENTS:
            print(f"  {len(events)} events (truncating to last {MAX_EVENTS})")
            events = events[-MAX_EVENTS:]
        else:
            print(f"  {len(events)} events")

        existing = fetch_existing_memories(context)
        user_prompt = build_user_prompt(events, existing)

        print(f"  Calling {args.model}…")
        try:
            response = ollama_chat(
                args.model,
                [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user",   "content": user_prompt},
                ],
            )
        except Exception as e:
            print(f"  ERROR: LLM call failed: {e}\n")
            continue

        # Parse JSON — strip accidental markdown fences if the model added them
        response = re.sub(r"^```[a-z]*\n?", "", response.strip())
        response = re.sub(r"\n?```$", "", response.strip())

        try:
            updates = json.loads(response)
        except json.JSONDecodeError as e:
            print(f"  ERROR: Could not parse model output as JSON: {e}")
            print(f"  Raw output:\n{response[:500]}\n")
            continue

        if not isinstance(updates, list):
            print(f"  ERROR: Expected a JSON array, got {type(updates).__name__}\n")
            continue

        print(f"  {len(updates)} memory update(s):")
        apply_memory_updates(updates, context, args.dry_run)
        mark_session_dreamed(sid, args.dry_run)
        print()

    print("Done.")


if __name__ == "__main__":
    main()
