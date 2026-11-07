import { Plugin } from "@opencode/plugin";
import { spawnSync } from "child_process";
import { randomUUID } from "node:crypto";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const API = process.env.AGENTMEMORY_URL || "http://localhost:3111";
const FILE_TOOLS = new Set(["read", "write", "edit", "glob", "grep"]);
const FILE_KEYS = ["filePath", "file_path", "path", "file", "pattern"];
const MAX_STASHED_FILES = 20;
// Title-only pointer to earlier sessions, injected while the conversation has
// no assistant turn yet (a new session or the segment after /clear).
const POINTER_SESSION_LIMIT = 5;
// Fetch a wide window before filtering, otherwise a run of recent trivial
// sessions hides the older substantive ones.
const POINTER_FETCH_LIMIT = 100;
const POINTER_CACHE_MS = 60000;
const POINTER_TITLE_MAX = 60;
// Skip trivial sessions (test prompts, abandoned starts) in the pointer.
const POINTER_MIN_OBSERVATIONS = 10;

// Failed capture calls are spooled to disk so a host restart mid-session does
// not lose observations. The queue is bounded by size and age; replay is
// at-least-once (the server deduplicates observations). It lives in the sandbox
// home, so it survives an OpenCode restart but not `sbx rm`.
const SPOOL_DIR =
  process.env.AGENTMEMORY_SPOOL_DIR ||
  join(process.env.HOME || homedir(), ".local", "share", "opencode-agentmemory-spool");
const SPOOL_FILE = join(SPOOL_DIR, "pending.jsonl");
const SPOOL_FLUSH_FILE = join(SPOOL_DIR, "pending.flushing");
const SPOOL_MAX_BYTES = 5 * 1024 * 1024;
const SPOOL_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;
const SPOOL_FLUSH_MS = 30000;
// Derived work is best-effort: replaying a timed-out summarize or consolidation
// would duplicate expensive model calls, and the server already summarizes on
// session end. Only capture writes are worth spooling.
const SPOOL_EXCLUDE = new Set(["/summarize", "/crystals/auto", "/consolidate-pipeline"]);

const DEBUG = process.env.OPENCODE_AGENTMEMORY_DEBUG === "1";
const SECRET = process.env.AGENTMEMORY_SECRET || "";

function authHeaders(): Record<string, string> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (SECRET) headers["Authorization"] = `Bearer ${SECRET}`;
  return headers;
}

type SendResult = "ok" | "retry" | "drop";
type SpoolEntry = { at: string; path: string; body: Record<string, unknown> };

// A 4xx means the payload will never be accepted, so it is dropped instead of
// blocking the queue. Network errors, 5xx, 408 and 429 are retried.
async function send(
  path: string,
  body: Record<string, unknown>,
  timeoutMs = 5000,
): Promise<SendResult> {
  try {
    const res = await fetch(`${API}/agentmemory${path}`, {
      method: "POST",
      headers: authHeaders(),
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (res.ok) return "ok";
    // A stale secret is recoverable: the next OpenCode process rewrites the
    // spool with the refreshed secret, so keep those entries.
    if (res.status === 401 || res.status === 403) {
      if (DEBUG) console.error(`[agentmemory] POST ${path} -> HTTP ${res.status} (will retry)`);
      return "retry";
    }
    if (res.status >= 400 && res.status < 500 && res.status !== 408 && res.status !== 429) {
      if (DEBUG) console.error(`[agentmemory] POST ${path} -> HTTP ${res.status} (dropped)`);
      return "drop";
    }
    if (DEBUG) console.error(`[agentmemory] POST ${path} -> HTTP ${res.status} (will retry)`);
    return "retry";
  } catch (e) {
    if (DEBUG) console.error(`[agentmemory] POST ${path} failed:`, (e as Error).message);
    return "retry";
  }
}

function trimSpool(): void {
  try {
    if (statSync(SPOOL_FILE).size <= SPOOL_MAX_BYTES) return;
    const lines = readFileSync(SPOOL_FILE, "utf8").split("\n").filter((line) => line.length > 0);
    // Drop the oldest half; recent events are the ones most likely to matter.
    const keep = lines.slice(Math.floor(lines.length / 2));
    writeFileSync(SPOOL_FILE, keep.length ? `${keep.join("\n")}\n` : "", { mode: 0o600 });
    if (DEBUG) console.error(`[agentmemory] spool over ${SPOOL_MAX_BYTES} bytes; kept ${keep.length} entries`);
  } catch {
    // Best effort; a bounded queue is better than an unbounded one.
  }
}

function spoolAppend(path: string, body: Record<string, unknown>): void {
  try {
    mkdirSync(SPOOL_DIR, { recursive: true, mode: 0o700 });
    appendFileSync(
      SPOOL_FILE,
      `${JSON.stringify({ at: new Date().toISOString(), path, body })}\n`,
      { mode: 0o600 },
    );
    trimSpool();
    if (DEBUG) console.error(`[agentmemory] spooled ${path}`);
  } catch (e) {
    if (DEBUG) console.error(`[agentmemory] spool append failed:`, (e as Error).message);
  }
}

let spoolFlushing = false;

async function flushSpool(): Promise<void> {
  if (spoolFlushing) return;
  spoolFlushing = true;
  try {
    // Recover an orphan from a previous run that exited after the rename below
    // but before the unlink. The orphan is older than pending.jsonl, so it must
    // be replayed first; a failed recovery returns rather than overwriting it.
    if (existsSync(SPOOL_FLUSH_FILE)) {
      try {
        const orphan = readFileSync(SPOOL_FLUSH_FILE, "utf8");
        let pending = "";
        try {
          pending = readFileSync(SPOOL_FILE, "utf8");
        } catch {
          // no new entries after the interrupted flush
        }
        writeFileSync(SPOOL_FILE, `${orphan}${pending}`, { mode: 0o600 });
        unlinkSync(SPOOL_FLUSH_FILE);
      } catch (e) {
        if (DEBUG) console.error(`[agentmemory] spool recovery failed:`, (e as Error).message);
        return;
      }
    }
    if (!existsSync(SPOOL_FILE)) return;
    // Claim the queue atomically: appends made during replay go to a fresh
    // pending.jsonl instead of being overwritten when the replay finishes.
    try {
      renameSync(SPOOL_FILE, SPOOL_FLUSH_FILE);
    } catch {
      return;
    }

    let lines: string[];
    try {
      lines = readFileSync(SPOOL_FLUSH_FILE, "utf8").split("\n").filter((line) => line.length > 0);
    } catch {
      return;
    }

    const cutoff = Date.now() - SPOOL_MAX_AGE_MS;
    const remaining: string[] = [];
    let blocked = false;
    for (const line of lines) {
      if (blocked) {
        remaining.push(line);
        continue;
      }
      let entry: SpoolEntry | null = null;
      try {
        entry = JSON.parse(line) as SpoolEntry;
      } catch {
        continue;
      }
      if (!entry || typeof entry.path !== "string" || !entry.body || typeof entry.body !== "object") {
        continue;
      }
      const at = Date.parse(entry.at);
      if (Number.isFinite(at) && at < cutoff) continue;
      const result = await send(entry.path, entry.body, 5000);
      if (result === "retry") {
        // Preserve order: everything after the first failure waits for the
        // next attempt instead of hammering a server that is still down.
        blocked = true;
        remaining.push(line);
      }
    }

    if (remaining.length > 0) {
      let tail = "";
      try {
        tail = readFileSync(SPOOL_FILE, "utf8");
      } catch {
        // no new entries while replaying
      }
      writeFileSync(SPOOL_FILE, `${remaining.join("\n")}\n${tail}`, { mode: 0o600 });
    }
    try {
      unlinkSync(SPOOL_FLUSH_FILE);
    } catch {
      // ignore
    }
    if (DEBUG) {
      console.error(
        `[agentmemory] spool replay: ${lines.length - remaining.length} cleared, ${remaining.length} pending`,
      );
    }
  } catch (e) {
    if (DEBUG) console.error(`[agentmemory] spool flush failed:`, (e as Error).message);
  } finally {
    spoolFlushing = false;
  }
}

async function post(path: string, body: Record<string, unknown>, timeoutMs = 5000): Promise<void> {
  if ((await send(path, body, timeoutMs)) === "retry" && !SPOOL_EXCLUDE.has(path)) {
    spoolAppend(path, body);
  }
}

// Synchronous POST using spawnSync + curl.  Blocks the process until the
// HTTP request completes (or times out).  Used during plugin cleanup because
// OpenCode does not await plugin teardown indefinitely — without this the
// server process can exit before the fetch() promises resolve and sessions
// are left dangling in agentmemory.
function postSync(path: string, body: Record<string, unknown>, timeoutMs = 10000): void {
  try {
    const args: string[] = [
      "-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST",
      `${API}/agentmemory${path}`,
      "-H", "Content-Type: application/json",
    ];
    if (SECRET) {
      args.push("-H", `Authorization: Bearer ${SECRET}`);
    }
    args.push("-d", JSON.stringify(body), "--max-time", String(Math.ceil(timeoutMs / 1000)));
    const proc = spawnSync("curl", args, {
      timeout: timeoutMs,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const status = Number.parseInt(String(proc.stdout ?? "").trim(), 10);
    // curl exits 0 even for HTTP errors, so inspect the status explicitly. A
    // 4xx payload will never be accepted: drop it instead of spooling forever.
    // 401/403 are recoverable with a refreshed secret, and 408/429/5xx are
    // transient, so those are spooled for replay.
    const retry =
      proc.error !== undefined ||
      proc.status !== 0 ||
      !Number.isFinite(status) ||
      status < 200 ||
      status === 401 ||
      status === 403 ||
      status === 408 ||
      status === 429 ||
      status >= 500;
    if (retry) {
      spoolAppend(path, body);
      if (DEBUG) {
        console.error(
          `[agentmemory] sync POST ${path} failed:`,
          proc.error ? proc.error.message : `HTTP ${status || proc.status}`,
        );
      }
    }
  } catch (e) {
    spoolAppend(path, body);
    if (DEBUG) console.error(`[agentmemory] sync POST ${path} threw:`, (e as Error).message);
  }
}

async function postJson(path: string, body: Record<string, unknown>): Promise<unknown | null> {
  try {
    const res = await fetch(`${API}/agentmemory${path}`, {
      method: "POST",
      headers: authHeaders(),
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(5000),
    });
    return res.ok ? await res.json() : null;
  } catch (e) {
    if (DEBUG) console.error(`[agentmemory] POST ${path} failed:`, (e as Error).message);
    return null;
  }
}

async function getJson(path: string): Promise<unknown | null> {
  try {
    const res = await fetch(`${API}/agentmemory${path}`, {
      method: "GET",
      headers: authHeaders(),
      signal: AbortSignal.timeout(5000),
    });
    return res.ok ? await res.json() : null;
  } catch (e) {
    if (DEBUG) console.error(`[agentmemory] GET ${path} failed:`, (e as Error).message);
    return null;
  }
}

function escapeText(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function oneLine(v: unknown, max: number): string {
  if (typeof v !== "string") return "";
  const text = v.replace(/\s+/g, " ").trim();
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

function safeSlice(v: unknown, max: number): string {
  if (typeof v === "string") return v.slice(0, max);
  if (v == null) return "";
  try { return JSON.stringify(v).slice(0, max); } catch { return ""; }
}

function extractFilePaths(args: unknown): string[] {
  if (!args || typeof args !== "object") return [];
  const record = args as Record<string, unknown>;
  const files: string[] = [];
  for (const key of FILE_KEYS) {
    const val = record[key];
    if (typeof val === "string" && val.length > 0) {
      files.push(val);
    }
  }
  return files;
}

export default Plugin.define({
  id: "agentmemory.capture",
  async setup(ctx) {
    const projectPath = ctx.location.directory;
    const controller = new AbortController();

    // Replay anything spooled while the host was unreachable, then keep trying
    // while this OpenCode process lives. unref so an idle timer never keeps the
    // process alive on its own.
    void flushSpool();
    const spoolTimer = setInterval(() => {
      void flushSpool();
    }, SPOOL_FLUSH_MS);
    (spoolTimer as unknown as { unref?: () => void }).unref?.();

    let activeSessionId: string | null = null;
    const stashedFiles = new Map<string, Set<string>>();
    const toolStarts = new Map<string, { tool: string; input: unknown; start: number }>();
    // Short-lived cache of this project's recent session titles.
    let pointerCache: { at: number; entries: SessionPointerEntry[] } | null = null;
    // Fallback throttle for the transcript check, used only if the hook does
    // not expose event.messages.
    const assistantCheck = new Map<string, { at: number; has: boolean }>();

    type SessionPointerEntry = { id: string; date: string; title: string };

    // A conversation is "fresh" until it has an assistant turn. That is true
    // for a new session and again right after /clear, so the pointer returns
    // without being sent on every prompt of a long session.
    async function hasAssistantTurn(sid: string, event: { messages?: unknown }): Promise<boolean> {
      // OpenCode's transcript entries carry `type` ("user", "assistant", ...),
      // not `role`, so accept both shapes.
      const isAssistant = (m: any): boolean =>
        (m?.type ?? m?.info?.role ?? m?.role ?? m?.message?.role) === "assistant";
      if (Array.isArray(event.messages)) return event.messages.some(isAssistant);
      const cached = assistantCheck.get(sid);
      if (cached && Date.now() - cached.at < 1000) return cached.has;
      try {
        const messages = await ctx.session.context({ sessionID: sid });
        const has = Array.isArray(messages) && messages.some(isAssistant);
        assistantCheck.set(sid, { at: Date.now(), has });
        return has;
      } catch {
        return true; // fail closed: skip injection rather than spam
      }
    }

    async function sessionPointer(sid: string): Promise<string | null> {
      if (!pointerCache || Date.now() - pointerCache.at > POINTER_CACHE_MS) {
        const res = await getJson(
          `/sessions?project=${encodeURIComponent(projectPath)}&limit=${POINTER_FETCH_LIMIT}`,
        );
        const raw = (res as any)?.sessions;
        const list: any[] = Array.isArray(raw) ? raw : [];
        const entries: SessionPointerEntry[] = list
          .filter((s) => (typeof s?.observationCount === "number" ? s.observationCount : 0) >= POINTER_MIN_OBSERVATIONS)
          .map((s) => ({
            id: typeof s?.id === "string" ? s.id : "",
            date: typeof s?.startedAt === "string" ? s.startedAt.slice(0, 10) : "",
            title: oneLine(s?.summary?.title ?? s?.firstPrompt, POINTER_TITLE_MAX),
          }))
          .filter((e) => e.id.length > 0 && e.title.length > 0)
          .sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0));
        pointerCache = { at: Date.now(), entries };
      }
      const entries = (pointerCache?.entries ?? [])
        .filter((e) => e.id !== sid)
        .slice(0, POINTER_SESSION_LIMIT);
      if (entries.length === 0) return null;
      return [
        "<agentmemory-sessions>",
        "Earlier sessions in this project (titles only):",
        ...entries.map((e) => `- ${e.date || "unknown date"}  ${escapeText(e.title)}`),
        "</agentmemory-sessions>",
      ].join("\n");
    }

    function stashFor(sid: string): Set<string> {
      let s = stashedFiles.get(sid);
      if (!s) { s = new Set<string>(); stashedFiles.set(sid, s); }
      return s;
    }

    function addToStash(sid: string, file: string): void {
      const stash = stashFor(sid);
      stash.add(file);
      if (stash.size > MAX_STASHED_FILES) {
        const keep = [...stash].slice(-MAX_STASHED_FILES);
        stash.clear();
        for (const f of keep) stash.add(f);
      }
    }

    async function observe(
      sessionId: string,
      hookType: string,
      data: Record<string, unknown>,
    ): Promise<void> {
      await post("/observe", {
        // A stable client eventId makes spool replay idempotent: if the
        // original request reached the server but its response was lost, the
        // replay is reported as a duplicate instead of storing it twice.
        eventId: randomUUID(),
        hookType,
        sessionId,
        project: projectPath,
        cwd: projectPath,
        timestamp: new Date().toISOString(),
        data,
      });
    }

    async function endStaleSessions(
      excludeSessionId: string | null,
      project: string,
    ): Promise<void> {
      try {
        // Page only this project's active sessions. The unfiltered listing
        // fans out a summary read for every session in the store and used to
        // run on every new root session.
        let cursor: string | null = null;
        for (let page = 0; page < 5; page += 1) {
          const params = new URLSearchParams({
            project,
            status: "active",
            limit: "100",
          });
          if (cursor) params.set("cursor", cursor);
          const res = await fetch(`${API}/agentmemory/sessions?${params.toString()}`, {
            signal: AbortSignal.timeout(5000),
            headers: authHeaders(),
          });
          if (!res.ok) return;
          const body = (await res.json()) as {
            sessions?: Array<{ id: string; project: string; status: string }>;
            nextCursor?: string | null;
          };
          for (const s of body.sessions ?? []) {
            if (s.project === project && s.status === "active" && s.id !== excludeSessionId) {
              // final:false asks the server to finalize after its idle
              // timeout. That keeps a genuinely concurrent session (another
              // sandbox on the same project) from being summarized mid-use;
              // a live session reschedules it on its next observation.
              await post("/session/end", { sessionId: s.id, final: false });
            }
          }
          cursor = body.nextCursor ?? null;
          if (!cursor) break;
        }
      } catch {
        // best-effort; new session starts regardless
      }
    }

    // ── event stream ──
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          try {
            switch (event.type) {
            // ── session.created ──
            case "session.created": {
              const data = event.data;
              const sid = data.sessionID;
              activeSessionId = sid;
              stashedFiles.set(sid, new Set());
              const sessionProject = data.location?.directory || projectPath;
              // End any stale active sessions for this project before
              // starting a new root session.  This prevents sessions from
              // accumulating when the sandbox is reused but OpenCode starts
              // a fresh process each time (e.g. `sbx run`).  Child sessions
              // of a subagent must not end their parent.
              if (!data.parentID) {
                await endStaleSessions(sid, sessionProject);
              }
              await post("/session/start", {
                sessionId: sid,
                title: data.title ?? null,
                parentID: data.parentID ?? null,
                version: data.version ?? null,
                project: sessionProject,
                cwd: sessionProject,
              });
              break;
            }

            // ── session.idle ──
            // The server only finalizes sessions registered with final:false;
            // it does not watch OpenCode's idle event itself. Without this,
            // an idle session stayed "active" (and the retry worker skipped
            // it) until process exit, the next session in the project, or the
            // 24h sweep. The server waits AGENTMEMORY_FINALIZE_IDLE_MS and
            // reschedules if another observation arrives.
            case "session.idle": {
              if (event.data.sessionID) {
                await post("/session/end", { sessionId: event.data.sessionID, final: false });
              }
              break;
            }

            // ── session.status ──
            case "session.status": {
              const data = event.data;
              const status = data.status;
              await observe(data.sessionID, "session_status", {
                status_type: status.type,
                attempt: status.type === "retry" ? status.attempt : null,
                message: safeSlice(status.type === "retry" ? status.message : "", 2000),
                next: status.type === "retry" ? status.next : null,
              });
              break;
            }

            // ── session.compaction.* ──
            case "session.compaction.started": {
              const data = event.data;
              await observe(data.sessionID, "compaction_event", {
                auto: data.reason === "auto",
                reason: data.reason,
              });
              break;
            }
            case "session.compaction.ended": {
              const data = event.data;
              await post("/summarize", { sessionId: data.sessionID });
              await observe(data.sessionID, "session_compacted", {
                reason: data.reason,
                model: data.model ?? null,
                cost: data.cost ?? 0,
                input_tokens: data.tokens?.input ?? 0,
                output_tokens: data.tokens?.output ?? 0,
                reasoning_tokens: data.tokens?.reasoning ?? 0,
                text: safeSlice(data.text, 4000),
              });
              break;
            }
            case "session.compaction.failed": {
              const data = event.data;
              await observe(data.sessionID, "compaction_failed", {
                reason: data.reason,
                error: safeSlice(data.error, 2000),
              });
              break;
            }

            // ── session.deleted ──
            case "session.deleted": {
              const sid = event.data.sessionID;
              await post("/session/end", { sessionId: sid });
              post("/crystals/auto", { olderThanDays: 7 }, 30000);
              post("/consolidate-pipeline", { tier: "all", force: true }, 30000);
              if (sid === activeSessionId) activeSessionId = null;
              stashedFiles.delete(sid);
              assistantCheck.delete(sid);
              break;
            }

            // ── session.execution.failed ──
            case "session.execution.failed": {
              const data = event.data;
              await observe(data.sessionID, "post_tool_failure", {
                tool_name: "session.execution.failed",
                tool_input: "",
                tool_output: safeSlice(data.error, 8000),
              });
              break;
            }

            // ── session.retry.scheduled ──
            case "session.retry.scheduled": {
              const data = event.data;
              await observe(data.sessionID, "retry_attempt", {
                messageID: data.assistantMessageID,
                attempt: data.attempt,
                at: data.at,
                error: safeSlice(data.error, 2000),
              });
              break;
            }

            // ── session.step.ended ── (assistant step totals)
            case "session.step.ended": {
              const data = event.data;
              await observe(data.sessionID, "assistant_message", {
                messageID: data.assistantMessageID,
                finish: data.finish,
                raw_finish: data.rawFinish ?? null,
                cost: data.cost ?? 0,
                tokens: {
                  input: data.tokens?.input ?? 0,
                  output: data.tokens?.output ?? 0,
                  reasoning: data.tokens?.reasoning ?? 0,
                  cache_read: data.tokens?.cache?.read ?? 0,
                  cache_write: data.tokens?.cache?.write ?? 0,
                },
                files: data.files ?? [],
              });
              break;
            }

            // ── session.reasoning.ended ──
            case "session.reasoning.ended": {
              const data = event.data;
              await observe(data.sessionID, "reasoning", {
                messageID: data.assistantMessageID,
                ordinal: data.ordinal,
                text: safeSlice(data.text, 4000),
              });
              break;
            }

            // ── permission.asked ──
            case "permission.asked": {
              const data = event.data;
              await observe(data.sessionID, "notification", {
                notification_type: "permission_prompt",
                permission: data.action,
                pattern: Array.isArray(data.resources)
                  ? data.resources.join(", ")
                  : String(data.resources ?? ""),
                tool_call_id: data.source?.id ?? null,
                title: data.action,
                metadata: data.metadata ?? {},
              });
              break;
            }

            // ── permission.replied ──
            case "permission.replied": {
              const data = event.data;
              await observe(data.sessionID, "permission_replied", {
                permission_id: data.requestID,
                response: data.reply,
              });
              break;
            }

            // ── filesystem.changed ── (file.edited successor)
            case "filesystem.changed": {
              const sid = activeSessionId;
              if (sid && event.data.event !== "unlink") {
                addToStash(sid, event.data.file);
              }
              break;
            }

              default:
                break;
            }
          } catch (e) {
            // One unexpected event shape must not tear down the subscription
            // and silently stop capture for the rest of the process.
            console.error(
              `[agentmemory] event ${event.type} failed:`,
              (e as Error).message,
            );
          }
        }
      } catch (e) {
        if (!controller.signal.aborted) {
          console.error("[agentmemory] event stream ended:", (e as Error).message);
        }
      }
    })();

    // ── prompt admission ── (replaces V1 chat.message)
    await ctx.session.hook("prompt", async (event) => {
      const sid = event.sessionID || activeSessionId;
      if (!sid) return;
      const text = event.prompt.text ?? "";
      const files = (event.prompt.files ?? [])
        .map((f) => f.uri || f.name)
        .filter((v): v is string => typeof v === "string" && v.length > 0);
      for (const f of files) addToStash(sid, f);

      await observe(sid, "prompt_submit", {
        agent: null,
        model: null,
        variant: null,
        prompt: text.slice(0, 8000),
        files: files.slice(0, 20),
        parts_summary: ["text", ...files.map(() => "file")],
        delivery: event.delivery,
        metadata: event.metadata ?? null,
      });
    });

    // ── agent-loop model requests ──
    // Replaces V1 chat.params and experimental.chat.system.transform.
    await ctx.session.hook("context", async (event) => {
      const sid = event.sessionID || activeSessionId;
      if (!sid) return;

      // Title-only pointer to earlier sessions, only while this conversation
      // has no assistant turn yet. Titles and dates only, so an unrelated
      // session cannot feed the model stale narratives; it decides whether to
      // recall details.
      if (!(await hasAssistantTurn(sid, event))) {
        const pointer = await sessionPointer(sid);
        if (pointer) event.system.push({ type: "text", text: pointer });
      }

      // File enrichment injection for stashed files.
      const stash = stashFor(sid);
      if (stash.size > 0) {
        const files = [...stash].slice(0, 10);
        const enrichResult = await postJson("/enrich", {
          sessionId: sid,
          files,
          toolName: "enrich_inject",
        });
        const enrichCtx = (enrichResult as any)?.context;
        if (typeof enrichCtx === "string" && enrichCtx.length > 0) {
          event.system.push({ type: "text", text: enrichCtx });
          for (const f of files) stash.delete(f);
        }
      }

      await observe(sid, "llm_params", {
        agent: event.agent,
        model: `${event.model.providerID}/${event.model.id}`,
        variant: event.model.variant ?? null,
        temperature: event.options.temperature ?? null,
        topP: event.options.topP ?? null,
        max_output_tokens: event.options.maxTokens ?? null,
      });
    });

    // ── compaction requests ── (replaces V1 experimental.session.compacting)
    await ctx.session.hook("compaction", async (event) => {
      const sid = event.sessionID || activeSessionId;
      if (!sid) return;
      const result = await postJson("/context", {
        sessionId: sid,
        project: projectPath,
      });
      const contextText = (result as any)?.context;
      if (typeof contextText === "string" && contextText.length > 0) {
        event.system.push({ type: "text", text: contextText });
      }
    });

    // ── tool.execute.before ──
    await ctx.tool.hook("execute.before", (event) => {
      const sid = event.sessionID;
      if (!sid) return;
      toolStarts.set(`${sid}:${event.id}`, {
        tool: event.tool,
        input: event.input,
        start: Date.now(),
      });
      if (FILE_TOOLS.has(event.tool.toLowerCase())) {
        for (const fp of extractFilePaths(event.input)) {
          addToStash(sid, fp);
        }
      }
    });

    // ── tool.execute.after ──
    await ctx.tool.hook("execute.after", async (event) => {
      const sid = event.sessionID;
      if (!sid) return;
      const key = `${sid}:${event.id}`;
      const started = toolStarts.get(key);
      toolStarts.delete(key);
      const input = started?.input ?? event.input;
      const duration = started ? Date.now() - started.start : null;

      if (event.status === "completed") {
        await observe(sid, "post_tool_use", {
          tool_name: event.tool,
          call_id: event.id,
          tool_input: safeSlice(input, 4000),
          tool_output: safeSlice(
            event.result?.content ?? event.result?.output ?? event.result,
            8000,
          ),
          metadata: event.result?.metadata ?? {},
          duration_ms: duration,
        });
      } else {
        await observe(sid, "post_tool_failure", {
          tool_name: event.tool,
          call_id: event.id,
          tool_input: safeSlice(input, 4000),
          tool_output: safeSlice(event.error, 8000),
          duration_ms: duration,
        });
      }
    });

    // ── cleanup ── (replaces V1 dispose)
    // End ALL tracked sessions first via synchronous HTTP calls (postSync)
    // so every session is marked completed even if the process is killed
    // during summarization or consolidation.
    return async () => {
      controller.abort();
      clearInterval(spoolTimer);
      const allSids = new Set(stashedFiles.keys());
      if (activeSessionId) allSids.add(activeSessionId);
      for (const sid of allSids) {
        postSync("/session/end", { sessionId: sid });
      }
      // fire summarization + consolidation as best-effort async work.
      // /session/end already triggers event::session::stopped which
      // calls mem::summarize asynchronously, so explicit summarize
      // calls are redundant but kept as a best-effort backup.
      await Promise.all([
        ...[...allSids].map(sid => post("/summarize", { sessionId: sid }, 30000)),
        post("/crystals/auto", { olderThanDays: 7 }, 30000),
        post("/consolidate-pipeline", { tier: "all", force: true }, 30000),
      ]);
      activeSessionId = null;
      stashedFiles.clear();
      toolStarts.clear();
      assistantCheck.clear();
      pointerCache = null;
    };
  },
});
