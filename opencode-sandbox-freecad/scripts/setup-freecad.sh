#!/bin/bash
set -euo pipefail

# One-time host setup for the FreeCAD AI bridge:
#   - locate the FreeCAD AppImage and ensure FUSE 2 (or the extract-and-run fallback)
#   - clone freecad-ai at a pinned ref and link it into FreeCAD's versioned Mod dir
#   - create the bearer token and register the `freecad` MCP server with sbx
#
# Run as your normal user, not via sudo. FreeCAD itself is never started here.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/freecad-ai"
CONFIG_FILE="$CONFIG_DIR/config.env"
TOKEN_FILE="$CONFIG_DIR/mcp-token"
DEFAULT_AI_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/freecad-ai"
DEFAULT_REF="v0.33.0-alpha"
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
Usage: $0 [--appimage PATH] [--ref REF] [--rotate-token]

One-time host setup for the FreeCAD AI bridge. Safe to rerun.

Options:
  --appimage PATH   FreeCAD AppImage to use (default: search \$HOME)
  --ref REF         freecad-ai git tag or branch (default: $DEFAULT_REF)
  --rotate-token    Replace the existing MCP bearer token
  --help            Show this help

Environment:
  FREECAD_APPIMAGE  Same as --appimage
  FREECAD_AI_REF    Same as --ref
  FREECAD_AI_DIR    freecad-ai checkout (default: $DEFAULT_AI_DIR)
EOF
}

APPIMAGE_ARG=""
REF_ARG=""
ROTATE_TOKEN=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --appimage)
      if [ "$#" -lt 2 ]; then
        echo "Error: --appimage needs a path." >&2
        exit 1
      fi
      APPIMAGE_ARG="$2"
      shift 2
      ;;
    --ref)
      if [ "$#" -lt 2 ]; then
        echo "Error: --ref needs a tag or branch name." >&2
        exit 1
      fi
      REF_ARG="$2"
      shift 2
      ;;
    --rotate-token)
      ROTATE_TOKEN=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      echo "Usage: $0 [--appimage PATH] [--ref REF] [--rotate-token]" >&2
      exit 1
      ;;
  esac
done

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  echo "Error: run this script as $SUDO_USER, not via sudo." >&2
  echo "It calls sudo itself where needed." >&2
  exit 1
fi

MISSING=()
for cmd in git curl python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING+=("$cmd")
  fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "Error: missing required command(s): ${MISSING[*]}." >&2
  echo "Install them, then rerun this script." >&2
  exit 1
fi

if ! command -v sbx >/dev/null 2>&1; then
  echo "Error: 'sbx' (Docker Sandboxes) is not installed or not on PATH." >&2
  echo "Install the dependencies first: $REPO_DIR/scripts/install-dependencies.sh" >&2
  exit 1
fi

if ! sbx mcp --help >/dev/null 2>&1; then
  echo "Error: this sbx build has no 'sbx mcp' gateway commands." >&2
  echo "FreeCAD needs the MCP gateway. Update sbx to a release that provides it." >&2
  exit 1
fi

HAS_FUSE2=true
if ! fuse2_available; then
  HAS_FUSE2=false
  if command -v apt-get >/dev/null 2>&1; then
    echo "freecad: libfuse2 is missing; installing libfuse2t64 for the AppImage..."
    if sudo apt-get update && sudo apt-get install -y libfuse2t64; then
      sudo ldconfig 2>/dev/null || true
      if fuse2_available; then
        HAS_FUSE2=true
      fi
    fi
  fi
  if [ "$HAS_FUSE2" = false ]; then
    echo "Warning: FUSE 2 is unavailable; the AppImage will use the extract-and-run fallback (APPIMAGE_EXTRACT_AND_RUN=1)." >&2
  fi
fi

APPIMAGE="${APPIMAGE_ARG:-${FREECAD_APPIMAGE:-}}"
if [ -n "$APPIMAGE" ]; then
  APPIMAGE="$(expand_path "$APPIMAGE")"
  if [ ! -f "$APPIMAGE" ]; then
    echo "Error: FreeCAD AppImage not found at \"$APPIMAGE\"." >&2
    exit 1
  fi
  case "$APPIMAGE" in
    /*) ;;
    *) APPIMAGE="$PWD/$APPIMAGE" ;;
  esac
else
  echo "freecad: searching \$HOME for a FreeCAD AppImage..."
  mapfile -t CANDIDATES < <(
    find "$HOME" -maxdepth 5 \
      \( -type d \( -name .Trash -o -name Trash -o -name .cache -o -name cache \) -prune \) -o \
      -type f -name 'FreeCAD_*AppImage' -print 2>/dev/null \
      | sort
  )

  case "${#CANDIDATES[@]}" in
    0)
      echo "Error: no FreeCAD_*AppImage found under $HOME (maxdepth 5)." >&2
      echo "Download FreeCAD 1.1.3 from https://github.com/FreeCAD/FreeCAD/releases" >&2
      echo "and rerun with: $0 --appimage /path/to/FreeCAD.AppImage" >&2
      exit 1
      ;;
    1)
      APPIMAGE="${CANDIDATES[0]}"
      ;;
    *)
      echo "freecad: found multiple FreeCAD AppImages:"
      n=1
      for candidate in "${CANDIDATES[@]}"; do
        printf '  %d) %s\n' "$n" "$candidate"
        n=$((n + 1))
      done
      if [ ! -t 0 ]; then
        echo "Error: multiple AppImages found and stdin is not a TTY; pass --appimage PATH." >&2
        exit 1
      fi
      while true; do
        if ! read -r -p "Select one [1-${#CANDIDATES[@]}]: " CHOICE; then
          echo >&2
          echo "Error: no selection made; pass --appimage PATH." >&2
          exit 1
        fi
        case "$CHOICE" in
          ''|*[!0-9]*)
            echo "Enter a number between 1 and ${#CANDIDATES[@]}." >&2
            continue
            ;;
        esac
        if [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#CANDIDATES[@]}" ]; then
          APPIMAGE="${CANDIDATES[$((CHOICE - 1))]}"
          break
        fi
        echo "Enter a number between 1 and ${#CANDIDATES[@]}." >&2
      done
      ;;
  esac
fi

if [ ! -x "$APPIMAGE" ]; then
  echo "freecad: making \"$APPIMAGE\" executable..."
  if ! chmod +x "$APPIMAGE"; then
    echo "Error: could not make \"$APPIMAGE\" executable." >&2
    exit 1
  fi
fi

AI_DIR="$(expand_path "${FREECAD_AI_DIR:-$DEFAULT_AI_DIR}")"
case "$AI_DIR" in
  /*) ;;
  *) AI_DIR="$PWD/$AI_DIR" ;;
esac
REF="${REF_ARG:-${FREECAD_AI_REF:-$DEFAULT_REF}}"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

{
  printf 'FREECAD_APPIMAGE=%q\n' "$APPIMAGE"
  printf 'FREECAD_AI_DIR=%q\n' "$AI_DIR"
} > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

TOKEN_NEW=false
if [ "$ROTATE_TOKEN" = true ]; then
  rm -f "$TOKEN_FILE"
  echo "freecad: rotating the MCP bearer token."
fi

if [ -s "$TOKEN_FILE" ]; then
  TOKEN="$(cat "$TOKEN_FILE")"
  chmod 600 "$TOKEN_FILE"
else
  TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  (
    umask 077
    printf '%s\n' "$TOKEN" > "$TOKEN_FILE"
  )
  chmod 600 "$TOKEN_FILE"
  TOKEN_NEW=true
  echo "freecad: generated a new MCP bearer token at $TOKEN_FILE."
fi

TMP_DIR="$(mktemp -d)"
STUB_PID=""
cleanup() {
  if [ -n "${STUB_PID:-}" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
    STUB_PID=""
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# FreeCAD's user data directory is version-scoped. Ask the same FreeCAD build
# that will run the addon rather than guessing a version string.
discover_user_dirs() {
  local script output app_data config
  script="$TMP_DIR/freecad-dirs.py"
  cat > "$script" <<'PY'
import FreeCAD

print("FREECAD_USER_APP_DATA=" + FreeCAD.getUserAppDataDir())
print("FREECAD_USER_CONFIG=" + getattr(FreeCAD, "getUserConfigDir", lambda: "")())
PY

  output="$(timeout 120 "$APPIMAGE" freecadcmd "$script" 2>/dev/null || true)"
  app_data="$(printf '%s\n' "$output" | sed -n 's/^FREECAD_USER_APP_DATA=//p' | tail -n 1)"

  if [ -z "$app_data" ]; then
    echo "freecad: retrying directory discovery with APPIMAGE_EXTRACT_AND_RUN=1..." >&2
    output="$(APPIMAGE_EXTRACT_AND_RUN=1 timeout 120 "$APPIMAGE" freecadcmd "$script" 2>/dev/null || true)"
    app_data="$(printf '%s\n' "$output" | sed -n 's/^FREECAD_USER_APP_DATA=//p' | tail -n 1)"
  fi

  if [ -z "$app_data" ]; then
    return 1
  fi

  DISCOVERED_APP_DATA="$app_data"
  return 0
}

if ! discover_user_dirs; then
  echo "Error: could not query FreeCAD's user directories with freecadcmd." >&2
  echo "Start FreeCAD once so it creates its user data directory, close it, then rerun this script." >&2
  echo "If the AppImage does not start, install FUSE 2 (sudo apt-get install libfuse2t64) or run it once with APPIMAGE_EXTRACT_AND_RUN=1." >&2
  exit 1
fi

USER_APP_DATA="$DISCOVERED_APP_DATA"
MOD_DIR="$USER_APP_DATA/Mod"
MOD_LINK="$MOD_DIR/freecad-ai"

if [ -e "$MOD_LINK" ] && [ ! -L "$MOD_LINK" ]; then
  echo "Error: $MOD_LINK already exists and is not a symlink." >&2
  echo "Move it aside (for example: mv \"$MOD_LINK\" \"$MOD_LINK.bak\") and rerun this script." >&2
  exit 1
fi

ACTUAL_REF="$REF"
if [ ! -e "$AI_DIR" ]; then
  echo "freecad-ai: cloning $REF into $AI_DIR..."
  mkdir -p "$(dirname -- "$AI_DIR")"
  git clone --quiet --depth 1 --branch "$REF" https://github.com/ghbalf/freecad-ai.git "$AI_DIR"
elif [ ! -d "$AI_DIR/.git" ]; then
  echo "Error: $AI_DIR exists but is not a git checkout." >&2
  echo "Move it aside and rerun this script." >&2
  exit 1
else
  if [ -n "$(git -C "$AI_DIR" status --porcelain)" ]; then
    ACTUAL_REF="$(git -C "$AI_DIR" describe --tags --always 2>/dev/null || echo unknown)"
    echo "Warning: $AI_DIR has local changes; leaving the checkout at $ACTUAL_REF." >&2
  else
    echo "freecad-ai: updating $AI_DIR to $REF..."
    if git -C "$AI_DIR" rev-parse --verify --quiet "refs/tags/$REF" >/dev/null; then
      git -C "$AI_DIR" fetch --quiet --tags --force origin
      git -C "$AI_DIR" -c advice.detachedHead=false checkout --detach "refs/tags/$REF"
    else
      if ! git -C "$AI_DIR" fetch --quiet --depth 1 --force origin "$REF"; then
        git -C "$AI_DIR" fetch --quiet --tags --force origin
      fi
      git -C "$AI_DIR" -c advice.detachedHead=false checkout --detach FETCH_HEAD
    fi
  fi
fi

if [ ! -f "$AI_DIR/InitGui.py" ]; then
  echo "Error: $AI_DIR/InitGui.py is missing; this does not look like a freecad-ai checkout." >&2
  exit 1
fi

mkdir -p "$MOD_DIR"
ln -sfnT "$AI_DIR" "$MOD_LINK"

if sbx settings get mcp.forceLocalGateway 2>/dev/null | grep -qi 'false'; then
  echo "mcp: warning: sbx may select the hosted MCP gateway; header-bearing servers require the local gateway." >&2
  echo "If registration or tool calls fail, run: sbx settings set mcp.forceLocalGateway true && sbx daemon restart" >&2
fi

echo "mcp: storing the bearer token in the sbx secret store..."
SECRET_SET=false
SECRET_EXISTS=false
if sbx secret ls 2>/dev/null | grep -Fq 'mcp:freecad:freecad-token'; then
  SECRET_EXISTS=true
fi
# Prefer stdin for a new secret so the token is not visible in the sbx
# process arguments. An existing secret needs --token --force to overwrite.
if [ "$SECRET_EXISTS" = false ] &&
   printf '%s\n' "$TOKEN" | timeout 30 sbx secret set mcp:freecad:freecad-token >/dev/null 2>&1; then
  SECRET_SET=true
fi
if [ "$SECRET_SET" = false ]; then
  SECRET_ARGS=(mcp:freecad:freecad-token --token "$TOKEN")
  if sbx secret set --help 2>&1 | grep -F -- '--force' >/dev/null; then
    SECRET_ARGS+=(--force)
  fi
  if sbx secret set "${SECRET_ARGS[@]}"; then
    SECRET_SET=true
  fi
fi
if [ "$SECRET_SET" = false ]; then
  echo "Error: could not store the MCP token in sbx." >&2
  echo "Run this command interactively and paste the token from:" >&2
  echo "  $TOKEN_FILE" >&2
  echo "  sbx secret set mcp:freecad:freecad-token" >&2
  exit 1
fi

is_freecad_registered() {
  local listing
  if sbx mcp inspect freecad >/dev/null 2>&1; then
    return 0
  fi
  listing="$(sbx mcp ls 2>/dev/null || true)"
  awk '$1 == "freecad" { found = 1 } END { exit(found ? 0 : 1) }' <<< "$listing"
}

if is_freecad_registered; then
  MCP_STATE="already registered (left unchanged)"
  echo "mcp: 'freecad' is already registered; leaving it unchanged."
  INSPECT_OUTPUT="$(sbx mcp inspect freecad 2>/dev/null || true)"
  if printf '%s\n' "$INSPECT_OUTPUT" | grep -q '^URL:' &&
     ! printf '%s\n' "$INSPECT_OUTPUT" | grep -Fq "$MCP_URL"; then
    echo "Warning: the existing registration does not show $MCP_URL." >&2
    echo "If it points elsewhere, remove and re-add it: sbx mcp rm freecad && \"$0\"" >&2
  fi
  if [ -n "$INSPECT_OUTPUT" ] &&
     ! printf '%s\n' "$INSPECT_OUTPUT" | grep -Fq '${freecad-token}'; then
    echo "Warning: inspect does not show the \${freecad-token} header placeholder." >&2
    echo "If it was registered with a literal token, remove/re-add it: sbx mcp rm freecad && \"$0\"" >&2
  fi
else
  ADD_ARGS=(--url "$MCP_URL" --header 'Authorization: Bearer ${freecad-token}')
  if sbx mcp add --help 2>&1 | grep -F -- '--skip-ssrf-check' >/dev/null; then
    ADD_ARGS+=(--skip-ssrf-check)
  fi

  port_3000_busy() {
    curl --noproxy '*' -s -o /dev/null --max-time 1 "$MCP_URL" 2>/dev/null
  }

  STUB_STARTED=false
  if ! port_3000_busy; then
    echo "mcp: starting a temporary registration stub on 127.0.0.1:3000..."
    python3 "$REPO_DIR/freecad/registration_stub.py" --port 3000 --timeout 60 \
      >/dev/null 2>&1 &
    STUB_PID=$!
    READY=false
    for _ in {1..50}; do
      if port_3000_busy; then
        READY=true
        break
      fi
      sleep 0.1
    done
    if [ "$READY" = false ]; then
      echo "Error: the registration stub did not start on port 3000." >&2
      exit 1
    fi
    STUB_STARTED=true
  else
    echo "mcp: port 3000 is already in use; registering against the running server."
  fi

  echo "mcp: registering 'freecad' -> $MCP_URL..."
  if ! sbx mcp add freecad "${ADD_ARGS[@]}"; then
    echo "Error: sbx could not complete MCP registration for 'freecad'." >&2
    echo "If FreeCAD is already running on port 3000, close it and rerun setup." >&2
    echo "For diagnostics, retry manually: sbx mcp add freecad ${ADD_ARGS[*]} -D" >&2
    exit 1
  fi

  if [ "$STUB_STARTED" = true ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
    STUB_PID=""
    echo "mcp: stopped the registration stub."
  fi
  MCP_STATE="registered at $MCP_URL"
fi

if ! "$REPO_DIR/scripts/sync-config.sh"; then
  echo "Warning: sync-config.sh failed; ~/.config/opencode may be stale." >&2
fi

cat <<EOF

freecad setup complete:
  appimage:     $APPIMAGE
  freecad-ai:   $AI_DIR ($ACTUAL_REF)
  mod symlink:  $MOD_LINK -> $AI_DIR
  token:        $TOKEN_FILE
  mcp server:   $MCP_STATE

next: $REPO_DIR/scripts/run-freecad-ai.sh ~/FreeCAD
EOF

if [ "$ROTATE_TOKEN" = true ] || [ "$TOKEN_NEW" = true ]; then
  echo
  echo "note: restart FreeCAD and stop/restart the FreeCAD sandbox so the gateway"
  echo "      drops any cached header secret and reads the new token."
fi
