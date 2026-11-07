#!/bin/bash
# Start and stop the host agentmemory server together with its compression-retry
# worker. This is the only supported entry point for the host server.
#
#   ./scripts/agentmemory-host.sh            # start + supervise in the foreground
#   ./scripts/agentmemory-host.sh --background
#   ./scripts/agentmemory-host.sh stop       # stop supervisor, worker and server
#   ./scripts/agentmemory-host.sh status
#
# The wrapper is also the supervisor. It checks the server's health on a fixed
# interval, restarts the server (with capped backoff) when it stays unhealthy,
# restarts the retry worker if it dies, and runs the idempotent project-scope
# migration after every successful start or recovery. In the foreground the
# supervisor lives in the terminal; Ctrl-C stops everything. In the background
# a detached supervisor keeps running after the command returns, so one
# invocation per boot is enough.
#
# The retry worker lives only as long as the supervisor: no systemd unit and no
# always-running timer. It resumes its backlog from
# ~/.local/state/agentmemory-host.
#
# Environment:
#   AGENTMEMORY_HOST_HEALTH_INTERVAL  seconds between health checks (default 5)
#   AGENTMEMORY_HOST_RESTART_AFTER    consecutive failures before a restart (default 3)
#   AGENTMEMORY_HOST_MAX_BACKOFF      maximum restart backoff in seconds (default 60)
#   AGENTMEMORY_HOST_START_TIMEOUT    seconds to wait for health (default 180)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

DATA_DIR="${AGENTMEMORY_DATA_DIR:-$HOME/.local/share/agentmemory}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agentmemory-host"
SERVER_LOG="$STATE_DIR/server.log"
RETRY_LOG="$STATE_DIR/retry.log"
SUPERVISOR_LOG="$STATE_DIR/supervisor.log"
SERVER_PID_FILE="$STATE_DIR/server.pid"
RETRY_PID_FILE="$STATE_DIR/retry.pid"
SUPERVISOR_PID_FILE="$STATE_DIR/supervisor.pid"
MANAGED_FILE="$STATE_DIR/managed"
LOCK_FILE="$STATE_DIR/host.lock"
WORKER="$SCRIPT_DIR/agentmemory-compression-retry.mjs"
NODE_OPTIONS_VALUE="--max-old-space-size=4096"
BASE_URL="${AGENTMEMORY_HOST_BASE_URL:-http://127.0.0.1:3111}"
# /livez is the unauthenticated liveness endpoint. /health requires the shared
# secret and returns 503 for a "critical" health report, which is not the same
# thing as a dead process (and made the old check treat an unauthorized 401 as
# healthy too).
HEALTH_URL="$BASE_URL/agentmemory/livez"
MIGRATE_URL="$BASE_URL/agentmemory/migrate"
MAX_LOG_BYTES=10485760

int_or() {
  local value="${1:-}" fallback="$2"
  if [[ "$value" =~ ^[0-9]+$ ]] && [ "$((10#$value))" -gt 0 ]; then
    printf '%s' "$((10#$value))"
  else
    printf '%s' "$fallback"
  fi
}

HEALTH_INTERVAL="$(int_or "${AGENTMEMORY_HOST_HEALTH_INTERVAL:-}" 5)"
RESTART_AFTER="$(int_or "${AGENTMEMORY_HOST_RESTART_AFTER:-}" 3)"
MAX_BACKOFF="$(int_or "${AGENTMEMORY_HOST_MAX_BACKOFF:-}" 60)"
START_TIMEOUT="$(int_or "${AGENTMEMORY_HOST_START_TIMEOUT:-}" 180)"

MODE="foreground"
COMMAND="start"
SERVER_PID=""
CLEANED=0
SUPERVISOR_DETACHED=0

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [start|stop|status] [--foreground|--background]

  start (default)   Start agentmemory, supervise it and run the retry worker.
  stop              Stop the supervisor, the retry worker and the server.
  status            Show supervisor, server and worker state.
  --foreground, -f  Keep the supervisor attached to this terminal (default).
  --background, -b  Detach a supervisor and return after startup.

Environment:
  AGENTMEMORY_HOST_HEALTH_INTERVAL  seconds between health checks (default 5)
  AGENTMEMORY_HOST_RESTART_AFTER    failed checks before restart (default 3)
  AGENTMEMORY_HOST_MAX_BACKOFF      maximum restart backoff seconds (default 60)
  AGENTMEMORY_HOST_START_TIMEOUT    seconds to wait for health (default 180)
EOF
}

log_line() {
  local line
  line="$(date -Is) $*"
  echo "$line"
  if [ "$SUPERVISOR_DETACHED" -eq 0 ]; then
    printf '%s\n' "$line" >> "$SUPERVISOR_LOG"
  fi
}

# Start-time rotation: nothing is writing the file yet, so a rename is fine.
rotate_log() {
  local file="$1"
  [ -f "$file" ] || return 0
  local size
  size="$(stat -c%s "$file" 2>/dev/null || echo 0)"
  if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$file" "$file.1"
  fi
}

# Live rotation: the server, worker and supervisor hold open append descriptors
# on these logs, so moving the file would leave them writing to the renamed
# inode. Copy the contents and truncate the original in place instead. Every
# writer opens with O_APPEND, so the next write starts at offset 0 and does not
# leave a sparse hole. A line written between the copy and the truncate is lost,
# which is the usual copytruncate trade-off.
rotate_open_log() {
  local file="$1"
  [ -f "$file" ] || return 1
  local size
  size="$(stat -c%s "$file" 2>/dev/null || echo 0)"
  [ "$size" -gt "$MAX_LOG_BYTES" ] || return 1
  # tail -c bounds the read to the newest MAX_LOG_BYTES, so a chatty writer
  # cannot extend the copy the way cp can by chasing EOF. The temp file keeps a
  # failed rotation from leaving a half-written archive.
  local tmp="$file.1.tmp"
  if ! tail -c "$MAX_LOG_BYTES" "$file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file.1"
  : > "$file"
  return 0
}

rotate_running_logs() {
  local rotated=0 file
  for file in "$SERVER_LOG" "$RETRY_LOG" "$SUPERVISOR_LOG"; do
    if rotate_open_log "$file"; then
      rotated=1
    fi
  done
  if [ "$rotated" -eq 1 ]; then
    log_line "logs rotated at ${MAX_LOG_BYTES} bytes; previous contents kept in *.1"
  fi
  return 0
}

pid_alive() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

read_pid() {
  local file="$1"
  [ -f "$file" ] && tr -dc '0-9' < "$file" || true
}

cmdline() {
  local pid="$1"
  [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' < "/proc/$pid/cmdline" || true
}

is_server_pid() {
  local pid="$1"
  pid_alive "$pid" || return 1
  local cmd
  cmd="$(cmdline "$pid")"
  [[ "$cmd" == *agentmemory* ]] &&
    [[ "$cmd" != *agentmemory-compression-retry* ]] &&
    [[ "$cmd" != *agentmemory-ollama-proxy* ]] &&
    [[ "$cmd" != *agentmemory-host.sh* ]]
}

is_worker_pid() {
  local pid="$1"
  pid_alive "$pid" || return 1
  [[ "$(cmdline "$pid")" == *agentmemory-compression-retry* ]]
}

# The pid file is only written by a running supervisor, so ownership is
# established by the cmdline rather than by the hidden --supervise argument
# (foreground supervisors do not carry it).
is_supervisor_pid() {
  local pid="$1"
  pid_alive "$pid" || return 1
  local cmd
  cmd="$(cmdline "$pid")"
  [[ "$cmd" == *agentmemory-host.sh* ]]
}

server_up() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$HEALTH_URL" 2>/dev/null || true)"
  [ "$code" = "200" ]
}

wait_server() {
  local seconds="${1:-$START_TIMEOUT}" i
  for i in $(seq 1 "$seconds"); do
    if server_up; then return 0; fi
    sleep 1
  done
  return 1
}

resolve_secret() {
  local secret="${AGENTMEMORY_SECRET:-}"
  if [ -z "$secret" ] && [ -f "$HOME/.agentmemory/.env" ]; then
    secret="$(sed -n 's/^[[:space:]]*\(export[[:space:]]*\)\?AGENTMEMORY_SECRET[[:space:]]*=[[:space:]]*//p' "$HOME/.agentmemory/.env" | tail -n 1)"
    secret="$(printf '%s' "$secret" | tr -d '"' | tr -d "'")"
  fi
  if [ -z "$secret" ] && [ -f "$HOME/.agentmemory/secret" ]; then
    secret="$(cat "$HOME/.agentmemory/secret")"
  fi
  printf '%s' "$secret"
}

# Idempotent and cheap: fills in the project scope of memories that predate the
# field. Runs after every successful start/recovery; a failure is not fatal.
run_maintenance() {
  local secret out
  local -a auth=()
  secret="$(resolve_secret)"
  if [ -n "$secret" ]; then
    auth=(-H "Authorization: Bearer $secret")
  fi
  out="$(curl -sS --max-time 30 -X POST "${auth[@]}" \
    -H "Content-Type: application/json" \
    -d '{"step":"infer-memory-projects"}' "$MIGRATE_URL" 2>/dev/null || true)"
  if [ -z "$out" ]; then
    return 0
  fi
  if printf '%s' "$out" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    log_line "maintenance: infer-memory-projects $out"
  else
    log_line "maintenance: infer-memory-projects failed: $out"
  fi
}

start_worker() {
  local mode="$1"
  if [ ! -f "$WORKER" ]; then
    echo "Warning: $WORKER not found; compression-retry worker not started." >&2
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "Warning: node not found; compression-retry worker not started." >&2
    return 0
  fi
  rotate_log "$RETRY_LOG"
  if [ "$mode" = "background" ]; then
    nohup env AGENTMEMORY_URL="$BASE_URL" node "$WORKER" --watch >>"$RETRY_LOG" 2>&1 9>&- &
  else
    env AGENTMEMORY_URL="$BASE_URL" node "$WORKER" --watch >>"$RETRY_LOG" 2>&1 9>&- &
  fi
  local pid=$!
  echo "$pid" > "$RETRY_PID_FILE"
  log_line "retry worker: pid $pid (log: $RETRY_LOG)"
}

ensure_worker() {
  local rpid
  rpid="$(read_pid "$RETRY_PID_FILE")"
  if ! is_worker_pid "$rpid"; then
    start_worker "background"
  fi
}

stop_worker() {
  local pid
  pid="$(read_pid "$RETRY_PID_FILE")"
  if is_worker_pid "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 20); do
      pid_alive "$pid" || break
      sleep 0.5
    done
    pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$RETRY_PID_FILE"
}

stop_supervisor() {
  local pid
  pid="$(read_pid "$SUPERVISOR_PID_FILE")"
  if is_supervisor_pid "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 40); do
      pid_alive "$pid" || break
      sleep 0.5
    done
    pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$SUPERVISOR_PID_FILE"
}

# Stop a server process by pid, accepting both the pid this wrapper started and
# one recorded by an earlier run (an adopted supervisor owns neither in memory).
terminate_server_pid() {
  local pid="${1:-}" i
  is_server_pid "$pid" || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for i in $(seq 1 30); do
    pid_alive "$pid" || break
    sleep 0.5
  done
  pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
}

stop_server() {
  local pid
  pid="$(read_pid "$SERVER_PID_FILE")"

  # The CLI knows how to stop the iii-engine even if the supervisor was started
  # outside this wrapper.
  if command -v agentmemory >/dev/null 2>&1; then
    ( cd "$DATA_DIR" && timeout 30 agentmemory stop >/dev/null 2>&1 ) || true
  fi

  terminate_server_pid "$pid"
  terminate_server_pid "$SERVER_PID"
  rm -f "$SERVER_PID_FILE" "$MANAGED_FILE"
}

cleanup() {
  [ "$CLEANED" -eq 1 ] && return 0
  CLEANED=1
  stop_worker
  # An adopted supervisor has no startup pid in SERVER_PID, so also use the
  # pid file before removing it.
  terminate_server_pid "$SERVER_PID"
  terminate_server_pid "$(read_pid "$SERVER_PID_FILE")"
  # Do not leave the iii-engine behind if the supervisor went away first.
  if command -v agentmemory >/dev/null 2>&1 && [ -d "$DATA_DIR" ]; then
    ( cd "$DATA_DIR" && timeout 15 agentmemory stop >/dev/null 2>&1 ) || true
  fi
  rm -f "$SERVER_PID_FILE" "$RETRY_PID_FILE" "$SUPERVISOR_PID_FILE" "$MANAGED_FILE"
}

on_signal() {
  echo
  echo "stopping agentmemory..."
  cleanup
  exit 130
}

start_server() {
  rotate_log "$SERVER_LOG"
  if [ "$MODE" = "background" ]; then
    ( exec 9>&-
      cd "$DATA_DIR" && exec nohup env NODE_OPTIONS="$NODE_OPTIONS_VALUE" agentmemory
    ) >>"$SERVER_LOG" 2>&1 &
  else
    # Tee so the terminal sees the server output while the log is kept.
    ( exec 9>&-
      exec >> >(tee -a "$SERVER_LOG") 2>&1
      cd "$DATA_DIR"
      exec env NODE_OPTIONS="$NODE_OPTIONS_VALUE" agentmemory
    ) &
  fi
  SERVER_PID=$!
  echo "$SERVER_PID" > "$SERVER_PID_FILE"
}

# Health-check loop. Owns the server lifecycle from this point on: restarts the
# server after RESTART_AFTER consecutive failures, with exponential backoff on
# repeated failures, and restarts the worker whenever it is not running.
supervise() {
  local down="${1:-0}"
  local backoff=0 attempt=0

  echo "$$" > "$SUPERVISOR_PID_FILE"
  trap on_signal INT TERM HUP
  log_line "supervisor: pid $$ watching $HEALTH_URL every ${HEALTH_INTERVAL}s (restart after ${RESTART_AFTER} failures)"

  while :; do
    if server_up; then
      down=0
      backoff=0
      local rpid
      rpid="$(read_pid "$RETRY_PID_FILE")"
      if ! is_worker_pid "$rpid"; then
        log_line "supervisor: retry worker is not running; restarting it"
        start_worker "background"
      fi
    else
      down=$((down + 1))
      if [ "$down" -eq 1 ]; then
        log_line "supervisor: health check failed; waiting for recovery"
      fi
    fi

    rotate_running_logs

    if [ "$down" -ge "$RESTART_AFTER" ]; then
      attempt=$((attempt + 1))
      log_line "supervisor: restarting agentmemory (attempt $attempt)"
      stop_worker
      stop_server
      start_server
      if wait_server "$START_TIMEOUT"; then
        echo "$$" > "$MANAGED_FILE"
        log_line "supervisor: server healthy again after restart"
        run_maintenance
        start_worker "background"
        down=0
        backoff=0
        attempt=0
      else
        if [ "$backoff" -eq 0 ]; then
          backoff=5
        else
          backoff=$((backoff * 2))
        fi
        if [ "$backoff" -gt "$MAX_BACKOFF" ]; then
          backoff="$MAX_BACKOFF"
        fi
        log_line "supervisor: restart failed; retrying in ${backoff}s (log: $SERVER_LOG)"
        tail -n 5 "$SERVER_LOG" 2>/dev/null | while IFS= read -r line; do
          log_line "  $line"
        done
        sleep "$backoff"
        continue
      fi
    fi

    sleep "$HEALTH_INTERVAL"
  done
}

# Detach a supervisor that keeps running after this command returns.
launch_supervisor() {
  local down="${1:-0}"
  rotate_log "$SUPERVISOR_LOG"
  SUPERVISOR_DETACHED=1
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup env AGENTMEMORY_SUPERVISE_DOWN="$down" "$SCRIPT_PATH" --supervise >>"$SUPERVISOR_LOG" 2>&1 9>&- </dev/null &
  else
    nohup env AGENTMEMORY_SUPERVISE_DOWN="$down" "$SCRIPT_PATH" --supervise >>"$SUPERVISOR_LOG" 2>&1 9>&- </dev/null &
  fi
  local i pid
  for i in $(seq 1 50); do
    pid="$(read_pid "$SUPERVISOR_PID_FILE")"
    if is_supervisor_pid "$pid"; then
      log_line "supervisor: pid $pid (log: $SUPERVISOR_LOG)"
      return 0
    fi
    sleep 0.1
  done
  echo "Warning: supervisor did not start; check $SUPERVISOR_LOG" >&2
  return 1
}

start() {
  if ! command -v agentmemory >/dev/null 2>&1; then
    echo "Error: agentmemory is not on PATH. Run ./scripts/install-dependencies.sh." >&2
    exit 1
  fi
  if [ ! -d "$DATA_DIR" ]; then
    echo "Error: $DATA_DIR does not exist. Start agentmemory once or set AGENTMEMORY_DATA_DIR." >&2
    exit 1
  fi

  local spid
  spid="$(read_pid "$SUPERVISOR_PID_FILE")"
  if is_supervisor_pid "$spid"; then
    echo "agentmemory is already supervised (pid $spid)."
    ensure_worker
    echo "Use '$(basename "$0") status' or '$(basename "$0") stop'."
    exit 0
  fi

  # The CLI starts a daemon and may exit, so health is the authority on whether
  # the server is up. The marker records that this wrapper owns it.
  if server_up; then
    if [ -f "$MANAGED_FILE" ]; then
      echo "agentmemory is already running (managed daemon); starting supervision."
      rm -f "$SUPERVISOR_PID_FILE"
      run_maintenance
      if [ "$MODE" = "foreground" ]; then
        exec 9>&-
        supervise 0
      else
        launch_supervisor
      fi
      exit 0
    fi
    echo "agentmemory is already running but was not started by this wrapper." >&2
    echo "Stop it once with: $0 stop" >&2
    echo "Then start it through the wrapper." >&2
    exit 1
  fi

  # Nothing healthy is listening; clear state left by a previous run.
  rm -f "$SERVER_PID_FILE" "$RETRY_PID_FILE" "$SUPERVISOR_PID_FILE" "$MANAGED_FILE"
  echo "starting agentmemory from $DATA_DIR ..."
  start_server

  local down=0
  if wait_server "$START_TIMEOUT"; then
    run_maintenance
    start_worker "$MODE"
    echo "agentmemory: running (daemon; startup pid $SERVER_PID, log: $SERVER_LOG)"
  else
    echo "agentmemory did not become healthy; see $SERVER_LOG" >&2
    tail -n 20 "$SERVER_LOG" >&2 || true
    echo "The supervisor will keep retrying." >&2
    down="$RESTART_AFTER"
  fi
  echo "$$" > "$MANAGED_FILE"

  if [ "$MODE" = "foreground" ]; then
    # Release the startup lock so 'stop' works while we wait.
    exec 9>&-
    echo "Ctrl-C or '$(basename "$0") stop' stops everything."
    supervise "$down"
  else
    launch_supervisor "$down"
    if [ "$down" -eq 0 ]; then
      echo "agentmemory: supervised in the background (log: $SUPERVISOR_LOG)"
    else
      echo "agentmemory: supervisor is retrying startup (log: $SUPERVISOR_LOG)" >&2
    fi
  fi
}

stop() {
  local any=0
  local spid rpid
  spid="$(read_pid "$SUPERVISOR_PID_FILE")"
  rpid="$(read_pid "$RETRY_PID_FILE")"
  if is_supervisor_pid "$spid" || server_up || is_server_pid "$(read_pid "$SERVER_PID_FILE")" || is_worker_pid "$rpid" || [ -f "$MANAGED_FILE" ]; then
    any=1
  fi

  # The supervisor's own cleanup stops the worker and server; do it again below
  # so a supervisor killed with SIGKILL still leaves nothing behind.
  stop_supervisor
  stop_worker
  stop_server

  local i
  for i in $(seq 1 20); do
    server_up || break
    sleep 0.5
  done

  if server_up; then
    echo "Warning: :3111 still responds; check for a process started outside this wrapper." >&2
    return 1
  fi

  if [ "$any" -eq 0 ]; then
    echo "agentmemory is not running."
  else
    echo "agentmemory stopped."
  fi
}

status() {
  local spid rpid spid_state
  spid="$(read_pid "$SUPERVISOR_PID_FILE")"
  rpid="$(read_pid "$RETRY_PID_FILE")"
  echo "data dir:   $DATA_DIR"
  echo "state dir:  $STATE_DIR"
  if is_supervisor_pid "$spid"; then
    echo "supervisor: running (pid $spid)"
  else
    echo "supervisor: not running"
  fi
  if server_up; then
    if [ -f "$MANAGED_FILE" ]; then
      echo "server:     running (managed daemon)"
    else
      echo "server:     running (not started by this wrapper)"
    fi
  else
    echo "server:     not running"
  fi
  if is_worker_pid "$rpid"; then
    echo "retry:      running (pid $rpid)"
  else
    echo "retry:      not running"
  fi
  echo "server log: $SERVER_LOG"
  echo "retry log:  $RETRY_LOG"
  echo "sup. log:   $SUPERVISOR_LOG"
  if [ -f "$STATE_DIR/retry-state.json" ]; then
    echo "retry state: $STATE_DIR/retry-state.json"
  fi
  server_up
}

for arg in "$@"; do
  case "$arg" in
    start|stop|status) COMMAND="$arg" ;;
    --supervise) COMMAND="supervise" ;;
    --foreground|-f) MODE="foreground" ;;
    --background|-b) MODE="background" ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage
      exit 2
      ;;
  esac
done

if [ "$COMMAND" = "supervise" ]; then
  # The detached supervisor must not tee to a terminal or hold the start lock.
  MODE="background"
  SUPERVISOR_DETACHED=1
fi

CONFIG_DIR="$HOME/.config/opencode"
if [ -L "$CONFIG_DIR/plugins" ] || [ -L "$CONFIG_DIR/commands" ]; then
  echo "Error: ${CONFIG_DIR}/plugins or ${CONFIG_DIR}/commands is a symlink, which is what the sandbox looks like from the inside." >&2
  echo "Run this script on the host, not inside the Docker sandbox." >&2
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

case "$COMMAND" in
  start|stop)
    exec 9>"$LOCK_FILE"
    if command -v flock >/dev/null 2>&1; then
      if ! flock -n 9; then
        echo "Another agentmemory-host action is in progress." >&2
        exit 1
      fi
    fi
    ;;
esac

case "$COMMAND" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  supervise) supervise "${AGENTMEMORY_SUPERVISE_DOWN:-0}" ;;
esac
