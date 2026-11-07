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
//   - only completed (non-active) sessions are considered
//   - observations at or above the attempt cap are skipped when a whole page is
//     exhausted, and are never retried forever in a tight loop
//   - time-budgeted per pass, with a persisted cursor so long backlogs resume
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
  AGENTMEMORY_RETRY_BUDGET_MS             time budget per pass (default 10m)
  AGENTMEMORY_RETRY_MAX_ATTEMPTS          per-observation attempt cap (default 3)
  AGENTMEMORY_RETRY_BATCH                 retry batch size, 1-100 (default 10)
  AGENTMEMORY_RETRY_STATE_DIR             state directory (default ~/.local/state/agentmemory-host)`);
  process.exit(0);
}
const INTERVAL_MS = positive(process.env.AGENTMEMORY_RETRY_INTERVAL_MS, 30 * 60 * 1000);
const BUSY_INTERVAL_MS = positive(process.env.AGENTMEMORY_RETRY_BUSY_INTERVAL_MS, 5 * 60 * 1000);
const NOT_READY_INTERVAL_MS = positive(process.env.AGENTMEMORY_RETRY_NOT_READY_INTERVAL_MS, 2 * 60 * 1000);
const BUDGET_MS = positive(process.env.AGENTMEMORY_RETRY_BUDGET_MS, 10 * 60 * 1000);
const MAX_ATTEMPTS = positive(process.env.AGENTMEMORY_RETRY_MAX_ATTEMPTS, 3);
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
  try {
    await request(`${BASE}/agentmemory/health`, { timeoutMs: 5000 });
    return true;
  } catch (error) {
    if (error instanceof Error && error.message.includes("HTTP 401")) {
      warn("agentmemory rejected the shared secret (HTTP 401); check ~/.agentmemory/secret and AGENTMEMORY_SECRET");
    }
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
    log(`could not read agentmemory status (${error instanceof Error ? error.message : String(error)}); skipping pass`);
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

async function listProjects() {
  const projects = new Set();
  let cursor = null;
  for (let page = 0; page < MAX_SESSION_PAGES; page += 1) {
    if (stopping) break;
    const url = new URL(`${BASE}/agentmemory/sessions`);
    url.searchParams.set("limit", "100");
    if (cursor) url.searchParams.set("cursor", cursor);
    const data = await request(url.toString(), { timeoutMs: 15000 });
    for (const session of data?.sessions || []) {
      if (typeof session?.project === "string" && session.project.trim()) {
        projects.add(session.project);
      }
    }
    cursor = data?.nextCursor || null;
    if (!cursor) break;
  }
  return [...projects].sort();
}

function defaultState() {
  return { version: 1, projects: {}, lastRunAt: null, lastPass: null };
}

function loadState() {
  try {
    const parsed = JSON.parse(readFileSync(STATE_FILE, "utf-8"));
    if (parsed && typeof parsed === "object" && parsed.version === 1 && parsed.projects && typeof parsed.projects === "object") {
      return parsed;
    }
  } catch {
    // Missing or corrupt state starts fresh; compression state lives on the server.
  }
  return defaultState();
}

function saveState(state) {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  const tmp = `${STATE_FILE}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  renameSync(tmp, STATE_FILE);
}

function inspectUrl(project, cursor, limit = 100) {
  const url = new URL(`${BASE}/agentmemory/compression`);
  url.searchParams.set("project", project);
  url.searchParams.set("limit", String(limit));
  if (cursor) url.searchParams.set("cursor", cursor);
  return url.toString();
}

async function runProject(project, state, budgetStarted, totals) {
  let cursor = state.projects[project]?.cursor || null;
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
      peek = await request(inspectUrl(project, cursor, 1), { timeoutMs: 20000 });
    } catch (error) {
      log(`inspect failed for ${project}: ${error instanceof Error ? error.message : String(error)}`);
      return;
    }
    const first = Array.isArray(peek?.items) ? peek.items[0] : null;
    if (!first) {
      // A sparse page can still return a cursor when the server hit its scan
      // limit; advance instead of assuming the project is finished.
      const next = peek?.nextCursor || null;
      if (next && next !== cursor) {
        state.projects[project] = { cursor: next };
        saveState(state);
        cursor = next;
        continue;
      }
      delete state.projects[project];
      saveState(state);
      return;
    }

    if (!first.retryable || Number(first.attempts || 0) >= MAX_ATTEMPTS) {
      // This observation has exhausted its attempt budget. Advance past it
      // without retrying; the next iteration peeks at the following one.
      const next = peek?.nextCursor || null;
      if (!next || next === cursor) {
        delete state.projects[project];
        saveState(state);
        return;
      }
      state.projects[project] = { cursor: next };
      saveState(state);
      cursor = next;
      continue;
    }

    const body = { project, limit: BATCH };
    if (cursor) body.cursor = cursor;
    let result;
    try {
      result = await request(`${BASE}/agentmemory/compression/retry`, {
        method: "POST",
        body,
        timeoutMs: REQUEST_TIMEOUT_MS,
      });
    } catch (error) {
      log(`retry failed for ${project}: ${error instanceof Error ? error.message : String(error)}`);
      return;
    }

    const attempted = Number(result?.attempted || 0);
    const recovered = Number(result?.recovered || 0);
    const failed = Number(result?.failed || 0);
    totals.attempted += attempted;
    totals.recovered += recovered;
    totals.failed += failed;

    const next = result?.nextCursor || null;
    if (next) state.projects[project] = { cursor: next };
    else delete state.projects[project];
    state.lastRunAt = new Date().toISOString();
    state.lastPass = { project, attempted, recovered, failed };
    saveState(state);

    log(`${project}: attempted=${attempted} recovered=${recovered} failed=${failed}`);
    if (!next) return;
    cursor = next;

    // A failure makes the server stop at that item; the cursor has already
    // advanced past it, but pause briefly so a broken provider does not spin.
    if (recovered === 0 && failed > 0) await sleep(2000);
  }
  log(`page-step limit reached for ${project}; will resume next pass`);
}

async function runPass(state) {
  const budgetStarted = Date.now();
  const totals = { attempted: 0, recovered: 0, failed: 0, projects: 0, projectsDone: 0 };

  if (!(await preflight())) return { ...totals, skipped: true };

  let projects;
  try {
    projects = await listProjects();
  } catch (error) {
    log(`could not list sessions: ${error instanceof Error ? error.message : String(error)}`);
    return { ...totals, skipped: true };
  }
  totals.projects = projects.length;
  if (projects.length === 0) {
    log("no projects with sessions found");
    return { ...totals, durationMs: Date.now() - budgetStarted };
  }

  log(`pass starting across ${projects.length} project(s)`);
  for (const project of projects) {
    if (stopping) break;
    if (Date.now() - budgetStarted >= BUDGET_MS) {
      log("retry budget reached; will resume next pass");
      break;
    }
    const before = totals.recovered;
    await runProject(project, state, budgetStarted, totals);
    if (!state.projects[project]) totals.projectsDone += 1;
    if (totals.recovered === before && stopping) break;
  }

  totals.durationMs = Date.now() - budgetStarted;
  log(
    `pass done: attempted=${totals.attempted} recovered=${totals.recovered} failed=${totals.failed} ` +
      `projects=${totals.projectsDone}/${totals.projects} duration=${Math.round(totals.durationMs / 1000)}s`,
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
  return Object.values(state.projects || {}).some((entry) => entry && entry.cursor);
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
      `batch=${BATCH} maxAttempts=${MAX_ATTEMPTS} budget=${Math.round(BUDGET_MS / 1000)}s`,
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
    if (result?.skipped) delay = NOT_READY_INTERVAL_MS;
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
