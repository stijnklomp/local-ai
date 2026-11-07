#!/bin/bash
# Start and stop the host agentmemory server together with its compression-retry
# worker. This is the only supported entry point for the host server.
#
#   ./scripts/agentmemory-host.sh            # start in the foreground (default)
#   ./scripts/agentmemory-host.sh --background
#   ./scripts/agentmemory-host.sh stop       # stop the server and the worker
#   ./scripts/agentmemory-host.sh status
#
# In the foreground the wrapper prints the CLI startup output, keeps the server
# running as a daemon, and stays attached; Ctrl-C stops both processes. In the
# background the wrapper returns after the server is healthy. `stop` works from
# another terminal in either mode.
#
# The retry worker lives only as long as this wrapper: no systemd unit and no
# always-running timer. It resumes its backlog from ~/.local/state/agentmemory-host.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

DATA_DIR="${AGENTMEMORY_DATA_DIR:-$HOME/.local/share/agentmemory}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agentmemory-host"
SERVER_LOG="$STATE_DIR/server.log"
RETRY_LOG="$STATE_DIR/retry.log"
SERVER_PID_FILE="$STATE_DIR/server.pid"
RETRY_PID_FILE="$STATE_DIR/retry.pid"
MANAGED_FILE="$STATE_DIR/managed"
LOCK_FILE="$STATE_DIR/host.lock"
WORKER="$SCRIPT_DIR/agentmemory-compression-retry.mjs"
NODE_OPTIONS_VALUE="--max-old-space-size=4096"
HEALTH_URL="http://127.0.0.1:3111/agentmemory/health"

MODE="foreground"
COMMAND="start"
SERVER_PID=""
CLEANED=0

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [start|stop|status] [--foreground|--background]

  start (default)   Start agentmemory in $DATA_DIR and the compression-retry worker.
  stop              Stop the retry worker and the agentmemory server.
  status            Show whether the server and worker are running.
  --foreground, -f  Attach to the server in this terminal (default).
  --background, -b  Detach after the server becomes healthy.
EOF
}

rotate_log() {
  local file="$1"
  [ -f "$file" ] || return 0
  local size
  size="$(stat -c%s "$file" 2>/dev/null || echo 0)"
  if [ "$size" -gt 10485760 ]; then
    mv -f "$file" "$file.1"
  fi
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

server_up() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$HEALTH_URL" 2>/dev/null || true)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

wait_server() {
  local seconds="${1:-180}" i
  for i in $(seq 1 "$seconds"); do
    if server_up; then return 0; fi
    sleep 1
  done
  return 1
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
    nohup node "$WORKER" --watch >>"$RETRY_LOG" 2>&1 9>&- &
  else
    node "$WORKER" --watch >>"$RETRY_LOG" 2>&1 9>&- &
  fi
  local pid=$!
  echo "$pid" > "$RETRY_PID_FILE"
  echo "retry worker: pid $pid (log: $RETRY_LOG)"
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

stop_server() {
  local pid
  pid="$(read_pid "$SERVER_PID_FILE")"

  # The CLI knows how to stop the iii-engine even if the supervisor was started
  # outside this wrapper.
  if command -v agentmemory >/dev/null 2>&1; then
    ( cd "$DATA_DIR" && timeout 30 agentmemory stop >/dev/null 2>&1 ) || true
  fi

  if is_server_pid "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 30); do
      pid_alive "$pid" || break
      sleep 0.5
    done
    pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$SERVER_PID_FILE" "$MANAGED_FILE"
}

cleanup() {
  [ "$CLEANED" -eq 1 ] && return 0
  CLEANED=1
  stop_worker
  if is_server_pid "$SERVER_PID"; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 30); do
      pid_alive "$SERVER_PID" || break
      sleep 0.5
    done
    pid_alive "$SERVER_PID" && kill -KILL "$SERVER_PID" 2>/dev/null || true
  fi
  # Do not leave the iii-engine behind if the supervisor went away first.
  if command -v agentmemory >/dev/null 2>&1 && [ -d "$DATA_DIR" ]; then
    ( cd "$DATA_DIR" && timeout 15 agentmemory stop >/dev/null 2>&1 ) || true
  fi
  rm -f "$SERVER_PID_FILE" "$RETRY_PID_FILE" "$MANAGED_FILE"
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

start() {
  if ! command -v agentmemory >/dev/null 2>&1; then
    echo "Error: agentmemory is not on PATH. Run ./scripts/install-dependencies.sh." >&2
    exit 1
  fi
  if [ ! -d "$DATA_DIR" ]; then
    echo "Error: $DATA_DIR does not exist. Start agentmemory once or set AGENTMEMORY_DATA_DIR." >&2
    exit 1
  fi

  # The CLI starts a daemon and may exit, so health is the authority on whether
  # the server is up. The marker records that this wrapper owns it.
  if server_up; then
    if [ -f "$MANAGED_FILE" ]; then
      echo "agentmemory is already running (managed daemon)."
      local rpid
      rpid="$(read_pid "$RETRY_PID_FILE")"
      if ! is_worker_pid "$rpid"; then
        start_worker "background"
      fi
      echo "Use '$(basename "$0") status' or '$(basename "$0") stop'."
      exit 0
    fi
    echo "agentmemory is already running but was not started by this wrapper." >&2
    echo "Stop it once with: $0 stop" >&2
    echo "Then start it through the wrapper." >&2
    exit 1
  fi

  # Nothing healthy is listening; clear state left by a previous run.
  rm -f "$SERVER_PID_FILE" "$RETRY_PID_FILE" "$MANAGED_FILE"
  echo "starting agentmemory from $DATA_DIR ..."
  start_server

  if ! wait_server 180; then
    echo "agentmemory did not become healthy; see $SERVER_LOG" >&2
    tail -n 20 "$SERVER_LOG" >&2 || true
    cleanup
    exit 1
  fi

  start_worker "$MODE"
  echo "$$" > "$MANAGED_FILE"
  echo "agentmemory: running (daemon; startup pid $SERVER_PID, log: $SERVER_LOG)"

  if [ "$MODE" = "foreground" ]; then
    # Release the startup lock so 'stop' works while we wait.
    exec 9>&-
    trap on_signal INT TERM HUP
    echo "Ctrl-C or '$(basename "$0") stop' stops both processes."
    local down=0
    while :; do
      if server_up; then
        down=0
      else
        down=$((down + 1))
      fi
      if [ "$down" -ge 5 ]; then
        break
      fi
      sleep 2
    done
    echo "agentmemory stopped."
    cleanup
  fi
}

stop() {
  local any=0
  local spid rpid
  spid="$(read_pid "$SERVER_PID_FILE")"
  rpid="$(read_pid "$RETRY_PID_FILE")"
  if server_up || is_server_pid "$spid" || is_worker_pid "$rpid" || [ -f "$MANAGED_FILE" ]; then
    any=1
  fi

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
  local rpid
  rpid="$(read_pid "$RETRY_PID_FILE")"
  echo "data dir:   $DATA_DIR"
  echo "state dir:  $STATE_DIR"
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
  if [ -f "$STATE_DIR/retry-state.json" ]; then
    echo "retry state: $STATE_DIR/retry-state.json"
  fi
  server_up
}

for arg in "$@"; do
  case "$arg" in
    start|stop|status) COMMAND="$arg" ;;
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
esac
