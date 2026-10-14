import { Plugin } from "@opencode/plugin";
import { spawnSync } from "child_process";

const API = process.env.AGENTMEMORY_URL || "http://localhost:3111";
const FILE_TOOLS = new Set(["read", "write", "edit", "glob", "grep"]);
const FILE_KEYS = ["filePath", "file_path", "path", "file", "pattern"];
const MAX_STASHED_FILES = 20;
const IDLE_SUMMARIZE_COOLDOWN_MS = 3000;

const DEBUG = process.env.OPENCODE_AGENTMEMORY_DEBUG === "1";
const SECRET = process.env.AGENTMEMORY_SECRET || "";

function authHeaders(): Record<string, string> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (SECRET) headers["Authorization"] = `Bearer ${SECRET}`;
  return headers;
}

async function post(path: string, body: Record<string, unknown>, timeoutMs = 5000): Promise<void> {
  try {
    await fetch(`${API}/agentmemory${path}`, {
      method: "POST",
      headers: authHeaders(),
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (e) {
    if (DEBUG) console.error(`[agentmemory] POST ${path} failed:`, (e as Error).message);
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
      "-s", "-X", "POST",
      `${API}/agentmemory${path}`,
      "-H", "Content-Type: application/json",
    ];
    if (SECRET) {
      args.push("-H", `Authorization: Bearer ${SECRET}`);
    }
    args.push("-d", JSON.stringify(body), "--max-time", String(Math.ceil(timeoutMs / 1000)));
    const proc = spawnSync("curl", args, { timeout: timeoutMs, stdio: "ignore" });
    if (proc.error && DEBUG) {
      console.error(`[agentmemory] sync POST ${path} failed:`, proc.error.message);
    }
    if (proc.status !== 0 && proc.status !== null && DEBUG) {
      console.error(`[agentmemory] sync POST ${path} exit code:`, proc.status);
    }
  } catch (e) {
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

    let activeSessionId: string | null = null;
    const stashedFiles = new Map<string, Set<string>>();
    const toolStarts = new Map<string, { tool: string; input: unknown; start: number }>();
    const lastIdleSummarize = new Map<string, number>();

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
        const res = await fetch(`${API}/agentmemory/sessions`, {
          signal: AbortSignal.timeout(5000),
          headers: authHeaders(),
        });
        if (!res.ok) return;
        const body = (await res.json()) as {
          sessions?: Array<{ id: string; project: string; status: string }>;
        };
        const sessions = body.sessions ?? [];
        for (const s of sessions) {
          if (s.project === project && s.status === "active" && s.id !== excludeSessionId) {
            await post("/session/end", { sessionId: s.id });
          }
        }
      } catch {
        // best-effort; new session starts regardless
      }
    }

    // Fire-and-forget summarization on idle.  Both session.status idle and
    // session.idle are observed; a short cooldown keeps them from doubling up.
    async function summarizeOnIdle(sessionId: string): Promise<void> {
      const now = Date.now();
      const last = lastIdleSummarize.get(sessionId) ?? 0;
      if (now - last < IDLE_SUMMARIZE_COOLDOWN_MS) return;
      lastIdleSummarize.set(sessionId, now);
      await post("/summarize", { sessionId });
    }

    // ── event stream ──
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
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
            case "session.idle": {
              await summarizeOnIdle(event.data.sessionID);
              break;
            }

            // ── session.status ──
            case "session.status": {
              const data = event.data;
              const status = data.status;
              if (status.type === "idle") {
                await summarizeOnIdle(data.sessionID);
              }
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
              lastIdleSummarize.delete(sid);
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
                pattern: data.resources.join(", "),
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
        }
      } catch (e) {
        if (!controller.signal.aborted && DEBUG) {
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
      lastIdleSummarize.clear();
    };
  },
});
