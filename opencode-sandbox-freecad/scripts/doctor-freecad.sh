#!/bin/bash
set -euo pipefail

# Diagnostic checks for the FreeCAD AI bridge. Does not start the FreeCAD GUI
# or change the bridge configuration or sbx state.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/freecad-ai"
CONFIG_FILE="$CONFIG_DIR/config.env"
TOKEN_FILE="$CONFIG_DIR/mcp-token"
TEST_SCRIPT="$REPO_DIR/freecad/test_mcp.py"
PROJECT_DIR="$HOME/FreeCAD"
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

case "${1:-}" in
  --help)
    cat <<EOF
Usage: $0 [PROJECT_DIR]

Run diagnostic checks for the FreeCAD AI host bridge.
PROJECT_DIR defaults to $HOME/FreeCAD.
EOF
    exit 0
    ;;
  -*)
    echo "Error: unknown option: $1" >&2
    echo "Usage: $0 [PROJECT_DIR]" >&2
    exit 1
    ;;
  "") ;;
  *) PROJECT_DIR="$(expand_path "$1")" ;;
esac
if [ "$#" -gt 1 ]; then
  echo "Error: expected at most one project directory." >&2
  echo "Usage: $0 [PROJECT_DIR]" >&2
  exit 1
fi

FAILURES=0
SKIPS=0
CHECK_OK=false

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

skip() {
  printf 'SKIP  %s\n' "$1"
  SKIPS=$((SKIPS + 1))
}

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$label"
    CHECK_OK=true
  else
    fail "$label"
    CHECK_OK=false
  fi
  return 0
}

mcp_http_up() {
  local code rc
  code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 2 "$MCP_URL" 2>/dev/null)" && rc=0 || rc=$?
  [ -n "$code" ] && [ "$rc" -ne 7 ] && [ "$code" != "000" ]
}

# FreeCAD's user data directory is version-scoped. Ask the same FreeCAD build
# that will run the addon rather than guessing a version string.
discover_user_dirs() {
  local tmp script output app_data config
  tmp="$(mktemp -d)"
  script="$tmp/freecad-dirs.py"
  cat > "$script" <<'PY'
import FreeCAD

print("FREECAD_USER_APP_DATA=" + FreeCAD.getUserAppDataDir())
print("FREECAD_USER_CONFIG=" + getattr(FreeCAD, "getUserConfigDir", lambda: "")())
PY

  output="$(timeout 120 "$APPIMAGE" freecadcmd "$script" 2>/dev/null || true)"
  app_data="$(printf '%s\n' "$output" | sed -n 's/^FREECAD_USER_APP_DATA=//p' | tail -n 1)"

  if [ -z "$app_data" ]; then
    output="$(APPIMAGE_EXTRACT_AND_RUN=1 timeout 120 "$APPIMAGE" freecadcmd "$script" 2>/dev/null || true)"
    app_data="$(printf '%s\n' "$output" | sed -n 's/^FREECAD_USER_APP_DATA=//p' | tail -n 1)"
  fi

  rm -rf "$tmp"
  if [ -z "$app_data" ]; then
    return 1
  fi

  DISCOVERED_APP_DATA="$app_data"
  return 0
}

echo "FreeCAD AI diagnostic"
echo

SBX_OK=false
check "sbx on PATH" command -v sbx
if [ "$CHECK_OK" = true ]; then
  SBX_OK=true
fi

CONFIG_OK=false
if [ -f "$CONFIG_FILE" ]; then
  pass "config.env: $CONFIG_FILE"
  # shellcheck disable=SC1090
  if source "$CONFIG_FILE"; then
    CONFIG_OK=true
  else
    fail "config.env: could not be sourced"
  fi
else
  fail "config.env: missing ($CONFIG_FILE); run scripts/setup-freecad.sh"
fi
APPIMAGE="${FREECAD_APPIMAGE:-}"
AI_DIR="${FREECAD_AI_DIR:-}"

APPIMAGE_OK=false
if [ "$CONFIG_OK" = false ]; then
  skip "appimage: skipped (no config.env)"
elif [ -z "$APPIMAGE" ]; then
  fail "appimage: FREECAD_APPIMAGE is not set in config.env"
elif [ ! -f "$APPIMAGE" ]; then
  fail "appimage: not found at $APPIMAGE"
elif [ ! -x "$APPIMAGE" ]; then
  fail "appimage: not executable: $APPIMAGE"
else
  pass "appimage: $APPIMAGE"
  APPIMAGE_OK=true
fi

if [ -e /dev/fuse ] && fuse2_available; then
  pass "fuse: /dev/fuse and libfuse.so.2 are available"
else
  pass "fuse: unavailable; extract-and-run fallback will be used"
fi

MOD_DIR=""
if [ "$APPIMAGE_OK" = false ]; then
  skip "mod dir: skipped (AppImage unavailable)"
elif discover_user_dirs; then
  MOD_DIR="$DISCOVERED_APP_DATA/Mod"
  pass "mod dir: $MOD_DIR"
else
  fail "mod dir: freecadcmd discovery failed (start FreeCAD once, then rerun; check libfuse2t64)"
fi

if [ -z "$MOD_DIR" ]; then
  skip "mod symlink: skipped (mod dir unavailable)"
elif [ ! -L "$MOD_DIR/freecad-ai" ]; then
  if [ -e "$MOD_DIR/freecad-ai" ]; then
    fail "mod symlink: $MOD_DIR/freecad-ai exists but is not a symlink"
  else
    fail "mod symlink: missing $MOD_DIR/freecad-ai; rerun setup"
  fi
else
  LINK_TARGET="$(readlink "$MOD_DIR/freecad-ai")"
  if [ -n "$AI_DIR" ] && [ "$LINK_TARGET" = "$AI_DIR" ]; then
    pass "mod symlink: $MOD_DIR/freecad-ai -> $LINK_TARGET"
  else
    fail "mod symlink: points to $LINK_TARGET (expected ${AI_DIR:-<unset>})"
  fi
  if [ -f "$MOD_DIR/freecad-ai/InitGui.py" ]; then
    pass "mod symlink target: InitGui.py present"
  else
    fail "mod symlink target: InitGui.py missing"
  fi
fi

if [ -z "$AI_DIR" ]; then
  skip "freecad-ai checkout: skipped (FREECAD_AI_DIR unset)"
elif [ ! -d "$AI_DIR" ]; then
  fail "freecad-ai checkout: $AI_DIR does not exist"
elif [ ! -d "$AI_DIR/.git" ]; then
  fail "freecad-ai checkout: $AI_DIR is not a git repository"
else
  DESC="$(git -C "$AI_DIR" describe --tags --always 2>/dev/null || true)"
  if [ -f "$AI_DIR/InitGui.py" ]; then
    pass "freecad-ai checkout: $AI_DIR ($DESC)"
  else
    fail "freecad-ai checkout: $AI_DIR ($DESC) has no InitGui.py"
  fi
fi

TOKEN=""
if [ -f "$TOKEN_FILE" ]; then
  TOKEN_MODE="$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || echo '?')"
  if [ "$TOKEN_MODE" = "600" ]; then
    pass "token: $TOKEN_FILE (mode 600)"
  else
    fail "token: $TOKEN_FILE has mode $TOKEN_MODE (expected 600)"
  fi
  if [ -s "$TOKEN_FILE" ]; then
    TOKEN="$(cat "$TOKEN_FILE")"
  else
    fail "token: $TOKEN_FILE is empty"
  fi
else
  fail "token: missing $TOKEN_FILE; rerun setup"
fi

MCP_UP=false
if mcp_http_up; then
  pass "mcp endpoint: $MCP_URL is reachable"
  MCP_UP=true
else
  fail "mcp endpoint: not reachable; start it with scripts/run-freecad-ai.sh"
fi

if [ "$MCP_UP" = false ]; then
  skip "mcp auth: unauthenticated request check (server down)"
  skip "mcp tools: authenticated verification (server down)"
elif [ ! -f "$TEST_SCRIPT" ]; then
  fail "test_mcp.py: missing at $TEST_SCRIPT"
  skip "mcp auth: unauthenticated request check (test missing)"
  skip "mcp tools: authenticated verification (test missing)"
else
  if python3 "$TEST_SCRIPT" --expect-unauthorized >/dev/null 2>&1; then
    pass "mcp auth: unauthenticated request rejected (401)"
  else
    fail "mcp auth: expected 401 for an unauthenticated request"
  fi
  if [ -z "$TOKEN" ]; then
    skip "mcp tools: no token available"
  elif python3 "$TEST_SCRIPT" --token-file "$TOKEN_FILE" --quiet; then
    pass "mcp tools: authenticated; required tools present and dangerous names absent"
  else
    fail "mcp tools: authenticated verification failed (token mismatch, required tools missing, or tools outside the allowlist; run test_mcp.py without --quiet for details)"
  fi
fi

if [ "$SBX_OK" = false ]; then
  skip "sbx mcp: skipped (sbx unavailable)"
else
  if sbx mcp inspect freecad >/dev/null 2>&1; then
    pass "sbx mcp: 'freecad' is registered"
    INSPECT_OUTPUT="$(sbx mcp inspect freecad 2>/dev/null || true)"
    if printf '%s\n' "$INSPECT_OUTPUT" | grep -q '^URL:' &&
       ! printf '%s\n' "$INSPECT_OUTPUT" | grep -Fq "$MCP_URL"; then
      fail "sbx mcp: registered URL is not $MCP_URL; remove/re-add the registration"
    fi
    if printf '%s\n' "$INSPECT_OUTPUT" | grep -Eqi 'gateway.*(saas|hosted)'; then
      fail "sbx mcp: registration uses the hosted gateway; set mcp.forceLocalGateway true and restart the daemon"
    fi
  elif sbx mcp ls 2>/dev/null | awk '$1 == "freecad" { found = 1 } END { exit(found ? 0 : 1) }'; then
    pass "sbx mcp: 'freecad' is registered"
  else
    fail "sbx mcp: 'freecad' is not registered; rerun setup"
  fi
fi

if [ "$SBX_OK" = false ]; then
  skip "sbx secret: skipped (sbx unavailable)"
elif sbx secret ls 2>/dev/null | grep -F 'mcp:freecad:freecad-token' >/dev/null; then
  pass "sbx secret: mcp:freecad:freecad-token is stored (value masked)"
else
  fail "sbx secret: mcp:freecad:freecad-token is not stored; rerun setup"
fi

if [ ! -d "$PROJECT_DIR" ]; then
  fail "project: $PROJECT_DIR does not exist; run scripts/run-freecad-ai.sh"
elif [ -f "$PROJECT_DIR/AGENTS.md" ]; then
  pass "project: $PROJECT_DIR with AGENTS.md"
else
  fail "project: $PROJECT_DIR has no AGENTS.md; run scripts/run-freecad-ai.sh to create it"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all checks passed (${SKIPS} skipped)."
  echo "next: $REPO_DIR/scripts/run-freecad-ai.sh ~/FreeCAD"
else
  echo "$FAILURES check(s) failed, ${SKIPS} skipped."
  echo "next steps:"
  echo "  - config/appimage/mod/token failures: rerun $REPO_DIR/scripts/setup-freecad.sh"
  echo "  - MCP endpoint down: start it with $REPO_DIR/scripts/run-freecad-ai.sh ~/FreeCAD"
  echo "  - sbx failures: install deps ($REPO_DIR/scripts/install-dependencies.sh) and rerun setup"
  echo "  - project/AGENTS.md missing: run $REPO_DIR/scripts/run-freecad-ai.sh ~/FreeCAD"
  exit 1
fi
