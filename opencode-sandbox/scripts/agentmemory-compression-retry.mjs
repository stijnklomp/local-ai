#!/usr/bin/env node
// Retry agentmemory observations whose LLM compression previously failed.
//
// Why this exists:
//   agentmemory marks an observation `compression.status = "failed"` and never
//   retries it on its own. Its internal `summary-recovery` loop only covers
//   sessions that still have a repair token and backs off for minutes, so old
//   failures accumulate indefinitely. A failed observation is still stored,
//   indexed and embedded, but it never gets the richer compressed form.
//
//   The server exposes POST /agentmemory/compression/retry, but that function
//   stops the scan at the first failure and returns a cursor. One call cannot
//   drain a list, so this worker follows `nextCursor` until the scope is done.
//
// Lifecycle:
//   Started and stopped by scripts/agentmemory-host.sh. `--watch` retries on an
//   interval and exits on SIGTERM. `--once` runs a single pass. It no-ops while
//   the server, the repair proxy, the LLM provider or the vector backfill are
//   not ready, so it never burns observations' attempt counts on a dead stack.
//
// Safety:
//   - only completed (non-active) sessions are considered: an active session is
//     still producing observations and its own live compression must not be
//     competing with retries
//   - observations at or above the attempt cap are skipped, but only until
//     AGENTMEMORY_RETRY_CAPPED_AFTER_MS (default 24 hours) has passed since
//     their last attempt, so transient overload (including proxy 503s) is
//     revisited the same day instead of after a week
//   - time-budgeted per pass, with a persisted per-session cursor so long
//     backlogs resume
//   - retries go through the host repair proxy, exactly like live compression

import { closeSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const BASE = (process.env.AGENTMEMORY_URL || "http://127.0.0.1:3111").replace(/\/+$/, "");
const PROXY = (process.env.AGENTMEMORY_PROXY_URL || "http://127.0.0.1:11435").replace(/\/+$/, "");
const STATE_DIR =
  process.env.AGENTMEMORY_RETRY_STATE_DIR ||
  join(process.env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "agentmemory-host");
const STATE_FILE = process.env.AGENTMEMORY_RETRY_STATE || join(STATE_DIR, "retry-state.json");
const LOCK_FILE = join(STATE_DIR, "retry.lock");

const ONCE = process.argv.includes("--once");
if (process.argv.includes("--help") || process.argv.includes("-h")) {
  console.log(`Usage: ${process.argv[1]?.split("/").pop() || "agentmemory-compression-retry.mjs"} [--once|--watch]

  --watch (default)  Retry failed compression in a loop until SIGTERM/SIGINT.
  --once             Run a single pass and exit.

Environment:
  AGENTMEMORY_URL                         REST base (default http://127.0.0.1:3111)
  AGENTMEMORY_SECRET                      shared secret (else ~/.agentmemory/.env or ~/.agentmemory/secret)
  AGENTMEMORY_PROXY_URL                   repair proxy (default http://127.0.0.1:11435)
  AGENTMEMORY_RETRY_INTERVAL_MS           idle interval (default 30m)
  AGENTMEMORY_RETRY_BUSY_INTERVAL_MS      interval while a cursor remains (default 5m)
  AGENTMEMORY_RETRY_NOT_READY_INTERVAL_MS interval while the stack is not ready (default 2m)
  AGENTMEMORY_RETRY_ACTIVE_INTERVAL_MS    interval while an agent session is active (default 2m)
  AGENTMEMORY_RETRY_IDLE_ONLY             skip passes while any session is active
                                          (default true; set to false to retry anyway)
  AGENTMEMORY_RETRY_BUDGET_MS             time budget per pass (default 10m)
  AGENTMEMORY_RETRY_MAX_ATTEMPTS          per-observation attempt cap (default 6)
  AGENTMEMORY_RETRY_CAPPED_AFTER_MS       recheck an observation at the attempt
                                          cap after this long (default 24h)
  AGENTMEMORY_RETRY_BATCH                 retry batch size, 1-100 (default 10)
  AGENTMEMORY_RETRY_STATE_DIR             state directory (default ~/.local/state/agentmemory-host)`);
  process.exit(0);
}
const INTERVAL_MS = positive(process.env.AGENTMEMORY_RETRY_INTERVAL_MS, 30 * 60 * 1000);
const BUSY_INTERVAL_MS = positive(process.env.AGENTMEMORY_RETRY_BUSY_INTERVAL_MS, 5 * 60 * 1000);
const NOT_READY_INTERVAL_MS = positive(process.env.AGENTMEMORY_RETRY_NOT_READY_INTERVAL_MS, 2 * 60 * 1000);
const ACTIVE_INTERVAL_MS = positive(
  process.env.AGENTMEMORY_RETRY_ACTIVE_INTERVAL_MS,
  2 * 60 * 1000,
);
// Retries are background hygiene. While a session is active the user is paying
// for latency, and live compression already has the model; running a pass then
// only lengthens both queues.
const IDLE_ONLY = process.env.AGENTMEMORY_RETRY_IDLE_ONLY !== "false";
const BUDGET_MS = positive(process.env.AGENTMEMORY_RETRY_BUDGET_MS, 10 * 60 * 1000);
const MAX_ATTEMPTS = positive(process.env.AGENTMEMORY_RETRY_MAX_ATTEMPTS, 6);
const CAPPED_RECHECK_MS = positive(
  process.env.AGENTMEMORY_RETRY_CAPPED_AFTER_MS,
  24 * 60 * 60 * 1000,
);
const BATCH = clamp(positive(process.env.AGENTMEMORY_RETRY_BATCH, 10), 1, 100);
const REQUEST_TIMEOUT_MS = positive(process.env.AGENTMEMORY_RETRY_TIMEOUT_MS, 180 * 1000);
const MAX_SESSION_PAGES = 50;
const MAX_PAGE_STEPS = 500;

const stopController = new AbortController();
let stopping = false;
let lockFd = null;

function positive(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function log(message) {
  console.log(`${new Date().toISOString()} ${message}`);
}

function warn(message) {
  console.error(`${new Date().toISOString()} ${message}`);
}

function sleep(ms) {
  return new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      stopController.signal.removeEventListener("abort", onAbort);
      resolve();
    };
    const timer = setTimeout(finish, ms);
    const onAbort = () => finish();
    stopController.signal.addEventListener("abort", onAbort, { once: true });
  });
}

function timeoutSignal(ms) {
  if (typeof AbortSignal.timeout === "function") return AbortSignal.timeout(ms);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  if (typeof timer.unref === "function") timer.unref();
  return controller.signal;
}

function combinedSignal(...signals) {
  const valid = signals.filter(Boolean);
  if (typeof AbortSignal.any === "function") return AbortSignal.any(valid);
  const controller = new AbortController();
  for (const signal of valid) {
    signal.addEventListener("abort", () => controller.abort(signal.reason), { once: true });
  }
  return controller.signal;
}

// Same resolution order as agentmemory's secret-store: explicit env, then the
// env file, then the generated secret file (canonical, data dir, legacy .hmac).
function usable(value) {
  if (typeof value !== "string") return "";
  const trimmed = value.trim();
  if (!trimmed) return "";
  if (trimmed.startsWith("${") && trimmed.endsWith("}")) return "";
  return trimmed;
}

function unquote(value) {
  const quote = value[0];
  if ((quote === '"' || quote === "'") && value.length > 1) {
    const close = value.indexOf(quote, 1);
    if (close !== -1) return value.slice(1, close);
  }
  const hash = value.indexOf(" #");
  return (hash === -1 ? value : value.slice(0, hash)).trim();
}

function readSecretFile(path) {
  try {
    return usable(readFileSync(path, "utf-8"));
  } catch {
    return "";
  }
}

function readEnvFileSecret() {
  const path = process.env.AGENTMEMORY_ENV_FILE || join(homedir(), ".agentmemory", ".env");
  let content;
  try {
    content = readFileSync(path, "utf-8");
  } catch {
    return "";
  }
  let found = "";
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).replace(/^export\s+/, "").trim();
    if (key !== "AGENTMEMORY_SECRET") continue;
    found = usable(unquote(trimmed.slice(eq + 1).trim()));
  }
  return found;
}

function resolveSecret() {
  const fromEnv = usable(process.env.AGENTMEMORY_SECRET);
  if (fromEnv) return fromEnv;
  const fromEnvFile = readEnvFileSecret();
  if (fromEnvFile) return fromEnvFile;
  const dataDir = process.env.AGENTMEMORY_DATA_DIR;
  const candidates = [
    join(homedir(), ".agentmemory", "secret"),
    dataDir ? join(dataDir, "secret") : "",
    dataDir ? join(dataDir, ".hmac") : "",
    join(homedir(), ".agentmemory", ".hmac"),
  ].filter(Boolean);
  for (const candidate of candidates) {
    const secret = readSecretFile(candidate);
    if (secret) return secret;
  }
  return "";
}

const SECRET = resolveSecret();

function authHeaders() {
  return SECRET ? { Authorization: `Bearer ${SECRET}` } : {};
}

async function request(url, { method = "GET", body, timeoutMs = 15000 } = {}) {
  const headers = { ...authHeaders() };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const res = await fetch(url, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: combinedSignal(stopController.signal, timeoutSignal(timeoutMs)),
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    // Non-JSON error bodies are reported as HTTP status only.
  }
  if (!res.ok) {
    const detail = json && typeof json === "object" && typeof json.error === "string" ? `: ${json.error}` : "";
    throw new Error(`HTTP ${res.status} ${url}${detail}`);
  }
  return json;
}

async function serverReachable() {
  // /livez is the unauthenticated liveness probe. /health requires the shared
  // secret and returns 503 for a critical (but still running) report, which
  // used to look like "server unreachable" here.
  try {
    await request(`${BASE}/agentmemory/livez`, { timeoutMs: 5000 });
    return true;
  } catch {
    return false;
  }
}

async function proxyReachable() {
  try {
    const res = await fetch(`${PROXY}/api/version`, {
      signal: combinedSignal(stopController.signal, timeoutSignal(5000)),
    });
    return res.ok;
  } catch {
    return false;
  }
}

async function preflight() {
  if (stopping) return false;
  if (!(await serverReachable())) {
    log("agentmemory is not reachable; skipping pass");
    return false;
  }
  if (!(await proxyReachable())) {
    log(`repair proxy ${PROXY} is not reachable; skipping pass`);
    return false;
  }
  let status;
  try {
    status = await request(`${BASE}/agentmemory/status`, { timeoutMs: 10000 });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes("HTTP 401") || message.includes("HTTP 403")) {
      warn("agentmemory rejected the shared secret; check ~/.agentmemory/secret and AGENTMEMORY_SECRET");
    }
    log(`could not read agentmemory status (${message}); skipping pass`);
    return false;
  }
  if (status?.provider?.llm !== "llm") {
    log("LLM provider is not enabled; skipping pass");
    return false;
  }
  if (status?.provider?.circuitBreaker?.state === "open") {
    log("provider circuit breaker is open; skipping pass");
    return false;
  }
  const pending = Number(status?.index?.pendingVectorBackfill ?? 0);
  const backfill = status?.index?.vectorBackfillState;
  if (pending > 0 || (backfill && backfill !== "idle")) {
    log(`vector backfill is not idle (${backfill || "unknown"}, ${pending} pending); skipping pass`);
    return false;
  }
  return true;
}

// Active sessions are still producing observations. Their live compression is
// already competing for the model, so retrying them here only deepens the
// backlog. They become eligible once the server marks them completed.
async function anyActiveSession() {
  const url = new URL(`${BASE}/agentmemory/sessions`);
  url.searchParams.set("limit", "100");
  try {
    const data = await request(url.toString(), { timeoutMs: 15000 });
    // Sessions are returned newest first, so the current work is on the first
    // page; a full walk is unnecessary just to decide whether to stay idle.
    return (data?.sessions || []).some((session) => session && session.status === "active");
  } catch (error) {
    log(`could not check for active sessions: ${errorMessage(error)}`);
    return false;
  }
}

async function listCompletedSessions() {
  const sessions = [];
  let cursor = null;
  for (let page = 0; page < MAX_SESSION_PAGES; page += 1) {
    if (stopping) break;
    const url = new URL(`${BASE}/agentmemory/sessions`);
    url.searchParams.set("limit", "100");
    if (cursor) url.searchParams.set("cursor", cursor);
    const data = await request(url.toString(), { timeoutMs: 15000 });
    for (const session of data?.sessions || []) {
      if (typeof session?.id !== "string" || !session.id) continue;
      if (session.status === "active") continue;
      sessions.push({
        id: session.id,
        project: typeof session.project === "string" ? session.project : "",
      });
    }
    cursor = data?.nextCursor || null;
    if (!cursor) break;
  }
  return sessions;
}

function defaultState() {
  return { version: 2, sessions: {}, capped: {}, lastRunAt: null, lastPass: null };
}

function loadState() {
  try {
    const parsed = JSON.parse(readFileSync(STATE_FILE, "utf-8"));
    if (
      parsed &&
      typeof parsed === "object" &&
      parsed.version === 2 &&
      parsed.sessions &&
      typeof parsed.sessions === "object"
    ) {
      if (!parsed.capped || typeof parsed.capped !== "object") parsed.capped = {};
      return parsed;
    }
  } catch {
    // Missing or corrupt state starts fresh; compression state lives on the server.
  }
  // Version 1 stored cursors per project. Cursors are bound to their scope, so
  // they cannot be reused for per-session retries; start a fresh pass.
  return defaultState();
}

function saveState(state) {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  const tmp = `${STATE_FILE}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  renameSync(tmp, STATE_FILE);
}

function inspectUrl(sessionId, cursor, limit = 100) {
  const url = new URL(`${BASE}/agentmemory/compression`);
  url.searchParams.set("sessionId", sessionId);
  url.searchParams.set("limit", String(limit));
  if (cursor) url.searchParams.set("cursor", cursor);
  return url.toString();
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function parseTimestamp(value) {
  if (typeof value !== "string" || !value) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

// The compression listing exposes attempts but not lastAttemptAt. Read it from
// the session's observations only when an item sits at the attempt cap; capped
// items are rare, so the page walk stays contained to those sessions.
const observationMetaCache = new Map();

async function observationCompressionMeta(sessionId) {
  const cached = observationMetaCache.get(sessionId);
  if (cached) return cached;
  const meta = new Map();
  let cursor = null;
  let complete = false;
  for (let page = 0; page < MAX_SESSION_PAGES; page += 1) {
    if (stopping) break;
    const url = new URL(`${BASE}/agentmemory/observations`);
    url.searchParams.set("sessionId", sessionId);
    url.searchParams.set("limit", "100");
    if (cursor) url.searchParams.set("cursor", cursor);
    let data;
    try {
      data = await request(url.toString(), { timeoutMs: 20000 });
    } catch (error) {
      log(`could not read observations for ${sessionId}: ${errorMessage(error)}`);
      return meta;
    }
    for (const observation of data?.observations || []) {
      if (observation && typeof observation.id === "string") {
        meta.set(observation.id, observation.compression || {});
      }
    }
    cursor = data?.nextCursor || null;
    if (!cursor) {
      complete = true;
      break;
    }
  }
  // Only cache a complete read; a partial one would make cappedRetryDue fall
  // back to its first-seen marker for an observation it never saw.
  if (complete) {
    if (observationMetaCache.size >= 32) observationMetaCache.clear();
    observationMetaCache.set(sessionId, meta);
  }
  return meta;
}

// An observation at the attempt cap was skipped forever by the old policy, even
// when it only failed because a burst of live compression overloaded the model.
// Recheck it once the cooldown has passed since its last attempt.
async function cappedRetryDue(sessionId, item, state) {
  const meta = await observationCompressionMeta(sessionId);
  const lastAt = parseTimestamp(meta.get(item.observationId)?.lastAttemptAt);
  if (lastAt !== null) {
    if (state.capped[item.observationId] !== undefined) {
      delete state.capped[item.observationId];
      saveState(state);
    }
    return Date.now() - lastAt >= CAPPED_RECHECK_MS;
  }
  // Fallback when the observation or its metadata is unavailable: remember when
  // this worker first saw it capped and recheck after the same cooldown.
  const firstSeen = parseTimestamp(state.capped[item.observationId]);
  if (firstSeen === null) {
    state.capped[item.observationId] = new Date().toISOString();
    saveState(state);
    return false;
  }
  return Date.now() - firstSeen >= CAPPED_RECHECK_MS;
}

async function runSession(session, state, budgetStarted, totals) {
  const sessionId = session.id;
  let cursor = state.sessions[sessionId]?.cursor || null;

  const remember = (next) => {
    state.sessions[sessionId] = { cursor: next, project: session.project };
    saveState(state);
    cursor = next;
  };
  const forget = () => {
    delete state.sessions[sessionId];
    saveState(state);
  };

  for (let step = 0; step < MAX_PAGE_STEPS; step += 1) {
    if (stopping) return;
    if (Date.now() - budgetStarted >= BUDGET_MS) {
      log("retry budget reached; will resume next pass");
      return;
    }

    let peek;
    try {
      // Limit 1 gives us a cursor immediately after the first observation that
      // needs compression, so an observation at the attempt cap can be skipped
      // without spending a model call on it.
      peek = await request(inspectUrl(sessionId, cursor, 1), { timeoutMs: 20000 });
    } catch (error) {
      log(`inspect failed for ${sessionId}: ${errorMessage(error)}`);
      return;
    }
    const first = Array.isArray(peek?.items) ? peek.items[0] : null;
    if (!first) {
      // A sparse page can still return a cursor when the server hit its scan
      // limit; advance instead of assuming the session is finished.
      const next = peek?.nextCursor || null;
      if (next && next !== cursor) {
        remember(next);
        continue;
      }
      forget();
      return;
    }

    if (!first.retryable) {
      const next = peek?.nextCursor || null;
      if (!next || next === cursor) {
        forget();
        return;
      }
      remember(next);
      continue;
    }

    const attempts = Number(first.attempts || 0);
    if (attempts >= MAX_ATTEMPTS && !(await cappedRetryDue(sessionId, first, state))) {
      // Still inside the cooldown. Advance past it; the next iteration peeks at
      // the following observation.
      const next = peek?.nextCursor || null;
      if (!next || next === cursor) {
        forget();
        return;
      }
      remember(next);
      continue;
    }
    if (attempts >= MAX_ATTEMPTS) {
      log(`${sessionId}: rechecking ${first.observationId} after the capped cooldown (${attempts} attempts)`);
    }

    const body = { sessionId, limit: BATCH };
    if (cursor) body.cursor = cursor;
    let result;
    try {
      result = await request(`${BASE}/agentmemory/compression/retry`, {
        method: "POST",
        body,
        timeoutMs: REQUEST_TIMEOUT_MS,
      });
    } catch (error) {
      log(`retry failed for ${sessionId}: ${errorMessage(error)}`);
      return;
    }

    // A retry just refreshed the item's compression metadata (and attempts), so
    // drop the cached view before the next peek in this session.
    observationMetaCache.delete(sessionId);
    delete state.capped[first.observationId];

    const attempted = Number(result?.attempted || 0);
    const recovered = Number(result?.recovered || 0);
    const failed = Number(result?.failed || 0);
    totals.attempted += attempted;
    totals.recovered += recovered;
    totals.failed += failed;

    const next = result?.nextCursor || null;
    if (next && next === cursor) {
      // The server always advances past the last scanned observation, so an
      // unchanged cursor means it made no progress. Stop this session rather
      // than retrying the same batch until the page-step limit.
      log(`${sessionId}: retry cursor did not advance; stopping this session for now`);
      forget();
      return;
    }
    if (next) remember(next);
    else forget();
    state.lastRunAt = new Date().toISOString();
    state.lastPass = { sessionId, attempted, recovered, failed };
    saveState(state);

    log(`${sessionId}: attempted=${attempted} recovered=${recovered} failed=${failed}`);
    if (!next) return;

    // A failure makes the server stop at that item; the cursor has already
    // advanced past it, but pause briefly so a broken provider does not spin.
    if (recovered === 0 && failed > 0) await sleep(2000);
  }
  log(`page-step limit reached for ${sessionId}; will resume next pass`);
}

async function runPass(state) {
  const budgetStarted = Date.now();
  const totals = { attempted: 0, recovered: 0, failed: 0, sessions: 0, sessionsDone: 0 };

  if (!(await preflight())) return { ...totals, skipped: true };

  if (IDLE_ONLY && (await anyActiveSession())) {
    log("an agent session is active; skipping retry pass (idle-only)");
    return { ...totals, skipped: true, reason: "active-session" };
  }

  let sessions;
  try {
    sessions = await listCompletedSessions();
  } catch (error) {
    log(`could not list sessions: ${errorMessage(error)}`);
    return { ...totals, skipped: true };
  }
  totals.sessions = sessions.length;
  if (sessions.length === 0) {
    log("no completed sessions found; active sessions are left to live compression");
    return { ...totals, durationMs: Date.now() - budgetStarted };
  }

  log(`pass starting across ${sessions.length} completed session(s)`);
  for (const session of sessions) {
    if (stopping) break;
    if (Date.now() - budgetStarted >= BUDGET_MS) {
      log("retry budget reached; will resume next pass");
      break;
    }
    const before = totals.recovered;
    await runSession(session, state, budgetStarted, totals);
    if (!state.sessions[session.id]) totals.sessionsDone += 1;
    if (totals.recovered === before && stopping) break;
  }

  totals.durationMs = Date.now() - budgetStarted;
  log(
    `pass done: attempted=${totals.attempted} recovered=${totals.recovered} failed=${totals.failed} ` +
      `sessions=${totals.sessionsDone}/${totals.sessions} duration=${Math.round(totals.durationMs / 1000)}s`,
  );
  return totals;
}

function acquireLock() {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  try {
    lockFd = openSync(LOCK_FILE, "wx", 0o600);
    writeFileSync(lockFd, `${process.pid}\n`);
    return true;
  } catch {
    let existing = 0;
    try {
      existing = Number(readFileSync(LOCK_FILE, "utf-8").trim());
    } catch {
      // fall through
    }
    if (existing && existing !== process.pid) {
      try {
        process.kill(existing, 0);
        warn(`another retry worker is already running (pid ${existing}); exiting`);
        return false;
      } catch {
        // stale lock
      }
    }
    try {
      unlinkSync(LOCK_FILE);
    } catch {
      // ignore
    }
    lockFd = openSync(LOCK_FILE, "wx", 0o600);
    writeFileSync(lockFd, `${process.pid}\n`);
    return true;
  }
}

function releaseLock() {
  if (lockFd === null) return;
  try {
    closeSync(lockFd);
  } catch {
    // ignore
  }
  lockFd = null;
  try {
    unlinkSync(LOCK_FILE);
  } catch {
    // ignore
  }
}

function hasPendingCursor(state) {
  return Object.values(state.sessions || {}).some((entry) => entry && entry.cursor);
}

async function main() {
  if (!acquireLock()) process.exit(0);

  const shutdown = (signal) => {
    if (stopping) return;
    stopping = true;
    log(`received ${signal}; stopping`);
    stopController.abort();
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));

  log(
    `retry worker starting (${ONCE ? "once" : "watch"}) url=${BASE} proxy=${PROXY} ` +
      `batch=${BATCH} maxAttempts=${MAX_ATTEMPTS} budget=${Math.round(BUDGET_MS / 1000)}s ` +
      `idleOnly=${IDLE_ONLY}`,
  );
  if (!SECRET) log("no shared secret found; relying on an unauthenticated loopback server");

  const state = loadState();
  let delay = 0;
  while (!stopping) {
    if (delay > 0) {
      log(`sleeping ${Math.round(delay / 1000)}s before the next pass`);
      await sleep(delay);
      if (stopping) break;
    }
    let result;
    try {
      result = await runPass(state);
    } catch (error) {
      warn(`pass failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    if (ONCE) break;
    if (result?.reason === "active-session") delay = ACTIVE_INTERVAL_MS;
    else if (result?.skipped) delay = NOT_READY_INTERVAL_MS;
    else if (hasPendingCursor(state)) delay = BUSY_INTERVAL_MS;
    else delay = INTERVAL_MS;
  }

  releaseLock();
  log("retry worker stopped");
}

main().catch((error) => {
  releaseLock();
  warn(`fatal: ${error instanceof Error ? error.stack || error.message : String(error)}`);
  process.exit(1);
});
