#!/bin/bash
set -euo pipefail

# Daily launcher for the FreeCAD AI bridge:
#   - ensure FreeCAD is running on the host with the safe freecad-ai MCP server
#   - verify the bearer token and the blocked tools
#   - start the sandboxed OpenCode with the `freecad` static MCP attached
#
# FreeCAD is left running when OpenCode exits.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/freecad-ai"
CONFIG_FILE="$CONFIG_DIR/config.env"
TOKEN_FILE="$CONFIG_DIR/mcp-token"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/freecad-ai"
LOG_FILE="$STATE_DIR/freecad.log"
TEST_SCRIPT="$REPO_DIR/freecad/test_mcp.py"
SERVER_SCRIPT="$REPO_DIR/freecad/mcp_server_safe.py"
DEFAULT_PROJECT_DIR="$HOME/FreeCAD"
MCP_URL="http://127.0.0.1:3000/mcp"

fuse2_available() {
  ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2' && return 0
  find /lib /usr/lib -maxdepth 4 -name 'libfuse.so.2' -print -quit 2>/dev/null |
    grep -q . && return 0
  return 1
}

expand_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

usage() {
  cat <<EOF
Usage: $0 [PROJECT_DIR]

Start FreeCAD with the safe freecad-ai MCP server, then launch sandboxed OpenCode.

PROJECT_DIR defaults to $DEFAULT_PROJECT_DIR. Its basename names the sandbox.
FreeCAD is left running when OpenCode exits.
EOF
}

PROJECT_DIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      echo "Usage: $0 [PROJECT_DIR]" >&2
      exit 1
      ;;
    *)
      if [ -n "$PROJECT_DIR" ]; then
        echo "Error: expected at most one project directory, got \"$PROJECT_DIR\" and \"$1\"." >&2
        echo "Usage: $0 [PROJECT_DIR]" >&2
        exit 1
      fi
      PROJECT_DIR="$1"
      shift
      ;;
  esac
done
PROJECT_DIR="$(expand_path "${PROJECT_DIR:-$DEFAULT_PROJECT_DIR}")"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: $CONFIG_FILE not found." >&2
  echo "Run the one-time setup first: $REPO_DIR/scripts/setup-freecad.sh" >&2
  exit 1
fi

# shellcheck disable=SC1090
if ! source "$CONFIG_FILE"; then
  echo "Error: could not read $CONFIG_FILE." >&2
  exit 1
fi
APPIMAGE="${FREECAD_APPIMAGE:-}"
if [ -z "$APPIMAGE" ] || [ ! -x "$APPIMAGE" ]; then
  echo "Error: FreeCAD AppImage \"${APPIMAGE:-}\" is missing or not executable." >&2
  echo "Rerun setup: $REPO_DIR/scripts/setup-freecad.sh" >&2
  exit 1
fi

if ! command -v sbx >/dev/null 2>&1; then
  echo "Error: 'sbx' (Docker Sandboxes) is not installed or not on PATH." >&2
  echo "Install the dependencies first: $REPO_DIR/scripts/install-dependencies.sh" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required to check the local MCP server." >&2
  exit 1
fi

if ! sbx mcp --help >/dev/null 2>&1; then
  echo "Error: this sbx build has no 'sbx mcp' gateway commands." >&2
  echo "Update sbx to a release that provides the MCP gateway." >&2
  exit 1
fi

if [ ! -s "$TOKEN_FILE" ]; then
  echo "Error: MCP bearer token not found at $TOKEN_FILE." >&2
  echo "Rerun setup: $REPO_DIR/scripts/setup-freecad.sh" >&2
  exit 1
fi
TOKEN="$(cat "$TOKEN_FILE")"

is_freecad_registered() {
  local listing
  if sbx mcp inspect freecad >/dev/null 2>&1; then
    return 0
  fi
  listing="$(sbx mcp ls 2>/dev/null || true)"
  awk '$1 == "freecad" { found = 1 } END { exit(found ? 0 : 1) }' <<< "$listing"
}

if ! is_freecad_registered; then
  echo "Error: the 'freecad' MCP server is not registered with sbx." >&2
  echo "Rerun setup: $REPO_DIR/scripts/setup-freecad.sh" >&2
  exit 1
fi

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${XDG_SESSION_TYPE:-}" ]; then
  echo "Error: no graphical desktop session detected (DISPLAY, WAYLAND_DISPLAY and XDG_SESSION_TYPE are all empty)." >&2
  echo "FreeCAD needs a desktop session; run this from a terminal inside your desktop." >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR"
PROJECT_DIR="$(cd -- "$PROJECT_DIR" && pwd)"
if [ ! -e "$PROJECT_DIR/AGENTS.md" ] && [ ! -L "$PROJECT_DIR/AGENTS.md" ]; then
  if [ -f "$REPO_DIR/freecad/project-AGENTS.md" ]; then
    cp "$REPO_DIR/freecad/project-AGENTS.md" "$PROJECT_DIR/AGENTS.md"
    echo "project: created $PROJECT_DIR/AGENTS.md."
  else
    echo "Warning: $REPO_DIR/freecad/project-AGENTS.md is missing; not creating AGENTS.md." >&2
  fi
fi

# Run FreeCAD with the project as its working directory so relative export
# paths from the agent resolve inside the write root.
cd "$PROJECT_DIR"

if [ ! -f "$TEST_SCRIPT" ]; then
  echo "Error: $TEST_SCRIPT is missing; this repository checkout is incomplete." >&2
  exit 1
fi

mcp_http_up() {
  local code rc
  code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 2 "$MCP_URL" 2>/dev/null)" && rc=0 || rc=$?
  [ -n "$code" ] && [ "$rc" -ne 7 ] && [ "$code" != "000" ]
}

verify_mcp() {
  python3 "$TEST_SCRIPT" --expect-unauthorized --quiet &&
    python3 "$TEST_SCRIPT" --token-file "$TOKEN_FILE" --quiet
}

if mcp_http_up; then
  echo "freecad: MCP server already reachable at $MCP_URL; verifying it..."
  if ! verify_mcp; then
    echo "Error: the MCP server is reachable but verification failed." >&2
    echo "FreeCAD may be using a different token, the server may expose tools outside the allowlist, or it may have been started by the FreeCAD AI toolbar's unsafe toggle." >&2
    echo "Details: python3 \"$TEST_SCRIPT\" --token-file \"$TOKEN_FILE\"" >&2
    echo "Close FreeCAD, then rerun this script." >&2
    exit 1
  fi
  echo "freecad: safe MCP server verified."
else
  mkdir -p "$STATE_DIR"
  if [ ! -f "$SERVER_SCRIPT" ]; then
    echo "Error: $SERVER_SCRIPT is missing; cannot start the safe MCP server." >&2
    exit 1
  fi
  FREECAD_ENV=(
    "MCP_AUTH_TOKEN=$TOKEN"
    "MCP_HOST=127.0.0.1"
    "MCP_PORT=3000"
    "MCP_ALLOWED_HOSTS=127.0.0.1,localhost"
    "FREECAD_AI_WRITE_ROOT=$PROJECT_DIR"
  )
  if [ ! -e /dev/fuse ] || ! fuse2_available; then
    FREECAD_ENV+=("APPIMAGE_EXTRACT_AND_RUN=1")
    echo "freecad: FUSE is unavailable; starting with APPIMAGE_EXTRACT_AND_RUN=1."
  fi

  echo "freecad: starting FreeCAD in the background (log: $LOG_FILE)..."
  nohup env "${FREECAD_ENV[@]}" "$APPIMAGE" "$SERVER_SCRIPT" >>"$LOG_FILE" 2>&1 < /dev/null &
  FREECAD_PID=$!
  disown "$FREECAD_PID" 2>/dev/null || true

  echo "freecad: waiting up to 120s for the MCP server (the first launch may show a dialog)..."
  SERVER_UP=false
  DEADLINE=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$DEADLINE" ]; do
    if mcp_http_up; then
      SERVER_UP=true
      break
    fi
    sleep 2
  done

  if [ "$SERVER_UP" = false ]; then
    echo "Error: the MCP server did not become reachable within 120 seconds." >&2
    echo "If FreeCAD was already open, close it and rerun this script so the safe server can own port 3000." >&2
    echo "Last 30 lines of $LOG_FILE:" >&2
    tail -n 30 "$LOG_FILE" >&2 || true
    exit 1
  fi

  if ! verify_mcp; then
    echo "Error: the MCP server started but verification failed." >&2
    echo "Details: python3 \"$TEST_SCRIPT\" --token-file \"$TOKEN_FILE\"" >&2
    echo "Last 30 lines of $LOG_FILE:" >&2
    tail -n 30 "$LOG_FILE" >&2 || true
    exit 1
  fi
  echo "freecad: safe MCP server verified; leaving FreeCAD running."
fi

cd "$PROJECT_DIR"
export SBX_STATIC_MCP=freecad
exec "$REPO_DIR/scripts/run-opencode-in-docker-sandbox.sh"
