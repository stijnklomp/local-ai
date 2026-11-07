#!/bin/bash
# Create, list and prune agentmemory snapshots.
#
# agentmemory's snapshot API serializes the whole store into state.json under
# ~/.agentmemory/snapshots and commits it to a local git repository. Every
# commit is a complete restore point, so this wrapper creates one and then
# keeps only the newest N commits; without that the repository grows forever.
#
#   ./scripts/agentmemory-snapshot.sh                 # create + prune
#   ./scripts/agentmemory-snapshot.sh --list
#   ./scripts/agentmemory-snapshot.sh --keep 12       # keep more restore points
#   ./scripts/agentmemory-snapshot.sh --no-prune
#   ./scripts/agentmemory-snapshot.sh --rebuild       # drop history, keep the newest state.json
#
# Every git command runs in a memory-capped scope (systemd-run, 2 GiB) so a
# pathological repository is killed inside its own cgroup instead of pushing the
# host into swap and triggering the global OOM killer. If history or repo size
# exceeds the retention bounds (retention never completed, e.g. every gc was
# killed), the script rebuilds the repository from the newest state.json rather
# than replaying a huge history. Restore points older than the newest one are
# lost in that case; that is deliberate, because an unrunnable history is not a
# restore point.
#
# Restore with:
#   curl -sS -X POST -H "Authorization: Bearer $(cat ~/.agentmemory/secret)" \
#     -H 'Content-Type: application/json' \
#     -d '{"commitHash":"<hash>"}' \
#     http://127.0.0.1:3111/agentmemory/snapshot/restore
#
# Run it on the host, never inside the Docker sandbox. scripts/sync-config.sh
# installs a weekly systemd user timer that invokes it.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

BASE_URL="${AGENTMEMORY_HOST_BASE_URL:-http://127.0.0.1:3111}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-}"
KEEP=3
ACTION="create"
PRUNE=1
REBUILD=0
# A full store snapshot is ~134 MiB. Keeping 3 of them plus git overhead stays
# well under this ceiling; crossing it means retention has stopped working.
MAX_REPO_BYTES="${AGENTMEMORY_SNAPSHOT_MAX_BYTES:-$((2 * 1024 * 1024 * 1024))}"
# How many commits beyond KEEP are tolerated before rebuilding instead of
# replaying history. A rebase of KEEP+2 commits is cheap; a rebase of hundreds
# allocates tens of gigabytes.
HISTORY_SLACK=2

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [create|list] [--keep N] [--no-prune] [--rebuild]

  create (default)  Create a snapshot and prune older commits.
  list              List the available snapshots.
  --keep N          Number of snapshot commits to keep (default 3, minimum 1).
  --no-prune        Create without pruning.
  --rebuild         Discard history and re-root at the newest state.json. Use
                    when pruning can no longer complete (repository too large).

Environment:
  AGENTMEMORY_HOST_BASE_URL      REST base (default http://127.0.0.1:3111)
  SNAPSHOT_DIR                   snapshot repository (default ~/.agentmemory/snapshots)
  AGENTMEMORY_SNAPSHOT_MAX_BYTES object-store ceiling before a rebuild (default 2 GiB)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    create|--create) ACTION="create" ;;
    list|--list) ACTION="list" ;;
    --keep)
      [ "$#" -ge 2 ] || { echo "--keep needs a value" >&2; exit 2; }
      KEEP="$2"
      shift
      ;;
    --no-prune) PRUNE=0 ;;
    --rebuild) REBUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$((10#$KEEP))" -lt 1 ]; then
  echo "--keep must be a positive integer" >&2
  exit 2
fi
KEEP="$((10#$KEEP))"

CONFIG_DIR="$HOME/.config/opencode"
if [ -L "$CONFIG_DIR/plugins" ] || [ -L "$CONFIG_DIR/commands" ]; then
  echo "Error: ${CONFIG_DIR}/plugins or ${CONFIG_DIR}/commands is a symlink, which is what the sandbox looks like from the inside." >&2
  echo "Run this script on the host, not inside the Docker sandbox." >&2
  exit 1
fi

# The weekly timer and a manual run must not rewrite the snapshot history at the
# same time.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agentmemory-host"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true
exec 9>"$STATE_DIR/snapshot.lock"
if command -v flock >/dev/null 2>&1; then
  if ! flock -n 9; then
    echo "Another agentmemory snapshot is already running."
    exit 0
  fi
fi

env_value() {
  local key="$1" file="$HOME/.agentmemory/.env" value
  value="$(sed -n "s/^[[:space:]]*\(export[[:space:]]*\)\?${key}[[:space:]]*=[[:space:]]*//p" "$file" 2>/dev/null | tail -n 1)"
  printf '%s' "$(printf '%s' "$value" | tr -d '"' | tr -d "'")"
}

if [ -z "$SNAPSHOT_DIR" ]; then
  SNAPSHOT_DIR="$(env_value SNAPSHOT_DIR)"
fi
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/.agentmemory/snapshots}"

# Run git with a hard memory cap. systemd-run puts each invocation in its own
# transient scope, so a runaway pack/rebase is OOM-killed there instead of
# driving the whole machine into swap. Falls back to plain git when the user
# manager is unreachable; the service unit's MemoryMax is the backstop then.
GIT_CAPPED=0
if command -v systemd-run >/dev/null 2>&1; then
  if systemd-run --user --scope --quiet -p MemoryMax=2G -p MemorySwapMax=0 -- /bin/true >/dev/null 2>&1; then
    GIT_CAPPED=1
  fi
fi
git_at() {
  local dir="$1"
  shift
  if [ "$GIT_CAPPED" = 1 ]; then
    local rc=0
    systemd-run --user --scope --quiet -p MemoryMax=2G -p MemorySwapMax=0 -- git -C "$dir" "$@" || rc=$?
    case "$rc" in
      0) return 0 ;;
      # The scope could not be created, or git died on a signal that is not an
      # OOM kill. Retry once without the cap; 137 is SIGKILL/OOM and must stay
      # capped.
      125|126|127|134|135)
        echo "git_at: capped git failed (rc=${rc}); retrying without the memory scope" >&2
        ;;
      *) return "$rc" ;;
    esac
  fi
  git -C "$dir" "$@"
}

repo_size_bytes() {
  du -sb "$SNAPSHOT_DIR/.git" 2>/dev/null | cut -f1
}

history_count() {
  git_at "$SNAPSHOT_DIR" rev-list --count HEAD 2>/dev/null || printf '0'
}

# agentmemory creates snapshots with `git add . && git commit` in the server
# process. Once the repo passes git's loose-object threshold (gc.auto, 6700 by
# default) that commit triggers an automatic `git gc --auto` — uncaught, in the
# server's cgroup, and on a large history it is exactly the process that grows
# to tens of GB. Disable auto-gc in the repo; this script runs gc explicitly,
# bounded and after a successful retention pass.
disable_auto_gc() {
  [ -d "$SNAPSHOT_DIR/.git" ] || return 0
  git_at "$SNAPSHOT_DIR" config gc.auto 0 >/dev/null 2>&1 || true
  git_at "$SNAPSHOT_DIR" config maintenance.auto false >/dev/null 2>&1 || true
}

resolve_secret() {
  local secret="${AGENTMEMORY_SECRET:-}"
  if [ -z "$secret" ]; then
    secret="$(env_value AGENTMEMORY_SECRET)"
  fi
  if [ -z "$secret" ] && [ -f "$HOME/.agentmemory/secret" ]; then
    secret="$(cat "$HOME/.agentmemory/secret")"
  fi
  printf '%s' "$secret"
}

SECRET="$(resolve_secret)"
AUTH=()
if [ -n "$SECRET" ]; then
  AUTH=(-H "Authorization: Bearer $SECRET")
fi

api() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sS --max-time 900 -X "$method" "${AUTH[@]}" \
      -H 'Content-Type: application/json' -d "$data" "${BASE_URL}${path}"
  else
    curl -sS --max-time 60 -X "$method" "${AUTH[@]}" "${BASE_URL}${path}"
  fi
}

# The weekly timer can fire while agentmemory is still starting (or right after
# `Persistent=true` catches up a missed run). Wait briefly instead of failing
# the only snapshot attempt of the week.
wait_for_server() {
  local i code
  for i in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
      "${BASE_URL}/agentmemory/livez" 2>/dev/null || true)"
    [ "$code" = "200" ] && return 0
    sleep 2
  done
  return 1
}

list_snapshots() {
  api GET /agentmemory/snapshots
}

# Refuse to touch a git repository that is not an agentmemory snapshot store.
snapshot_repo_ok() {
  [ -d "$SNAPSHOT_DIR/.git" ] || return 1
  git_at "$SNAPSHOT_DIR" cat-file -e HEAD:state.json 2>/dev/null || return 1
}

# Drop the old object store and re-root at the newest snapshot. The new repo is
# built in a staging directory and swapped in only after its commit succeeds, so
# a failure can never leave the snapshot repo with an unborn HEAD. The committed
# blob is preferred over the working file: the server rewrites state.json in
# place, and reading it while the server truncates it is how git gets SIGBUS.
rebuild_history() {
  local stamp tmp prev
  stamp="$(date +%s)"
  tmp="$SNAPSHOT_DIR/.rebuild.${stamp}.$$"
  prev="$SNAPSHOT_DIR/.git.prev.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp" || return 1

  if git_at "$SNAPSHOT_DIR" cat-file -e HEAD:state.json 2>/dev/null; then
    if ! git_at "$SNAPSHOT_DIR" show HEAD:state.json > "$tmp/state.json"; then
      echo "rebuild: could not read HEAD:state.json" >&2
      rm -rf "$tmp"
      return 1
    fi
  elif [ -f "$SNAPSHOT_DIR/state.json" ]; then
    echo "rebuild: no committed snapshot; copying the working state.json" >&2
    if ! cp "$SNAPSHOT_DIR/state.json" "$tmp/state.json"; then
      rm -rf "$tmp"
      return 1
    fi
  else
    echo "rebuild: no state.json to re-root at" >&2
    rm -rf "$tmp"
    return 1
  fi

  if [ ! -s "$tmp/state.json" ] || [ "$(head -c 1 "$tmp/state.json")" != "{" ]; then
    echo "rebuild: state.json looks empty or truncated; refusing to make it the baseline" >&2
    rm -rf "$tmp"
    return 1
  fi

  if ! git_at "$tmp" init -q \
    || ! git_at "$tmp" add state.json \
    || ! git_at "$tmp" -c user.name=agentmemory -c user.email=agentmemory@localhost \
         commit -qm "Retention baseline: rebuilt $(date -Is)"; then
    echo "rebuild: could not build the replacement repository; leaving the existing one untouched" >&2
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$prev"
  if [ -d "$SNAPSHOT_DIR/.git" ] && ! mv "$SNAPSHOT_DIR/.git" "$prev"; then
    echo "rebuild: could not move the old object store aside" >&2
    rm -rf "$tmp"
    return 1
  fi
  if ! mv "$tmp/.git" "$SNAPSHOT_DIR/.git"; then
    [ -d "$prev" ] && mv "$prev" "$SNAPSHOT_DIR/.git"
    echo "rebuild: could not install the replacement repository" >&2
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp" "$prev"
  disable_auto_gc
  echo "rebuild: repository is now $(du -sh "$SNAPSHOT_DIR/.git" 2>/dev/null | cut -f1)" >&2
}

prune_snapshots() {
  if ! snapshot_repo_ok; then
    echo "prune: skipped (${SNAPSHOT_DIR} is not an agentmemory snapshot repository yet)"
    return 0
  fi

  local total size
  total="$(history_count)"
  size="$(repo_size_bytes || printf '0')"
  if [ "$total" -gt "$((KEEP + HISTORY_SLACK))" ] || [ "${size:-0}" -gt "$MAX_REPO_BYTES" ]; then
    echo "prune: history ${total} (limit $((KEEP + HISTORY_SLACK))) or size ${size} bytes (limit ${MAX_REPO_BYTES}) exceeded; rebuilding instead of replaying it" >&2
    rebuild_history || { echo "prune: rebuild failed" >&2; return 1; }
    return 0
  fi

  if [ "$total" -le "$KEEP" ]; then
    echo "prune: ${total} snapshot(s), limit ${KEEP}; nothing to drop"
    return 0
  fi

  # A backward reset would keep the OLDEST commits. To keep the newest KEEP
  # ones, re-root history at the KEEP-th newest commit: create an orphan root
  # with that commit's tree, then replay the newer commits onto it.
  local oldest root
  if ! oldest="$(git_at "$SNAPSHOT_DIR" rev-parse "HEAD~$((KEEP - 1))")"; then
    echo "prune: could not resolve the retention baseline; rebuilding" >&2
    rebuild_history || return 1
    return 0
  fi
  if ! root="$(git_at "$SNAPSHOT_DIR" commit-tree \
      "$oldest^{tree}" \
      -m "Retention baseline: $(git_at "$SNAPSHOT_DIR" log -1 --format=%s "$oldest")" 2>/dev/null)"; then
    echo "prune: could not create a retention baseline; rebuilding" >&2
    rebuild_history || return 1
    return 0
  fi
  echo "prune: dropping $((total - KEEP)) old snapshot(s), keeping ${KEEP}"
  if ! git_at "$SNAPSHOT_DIR" rebase --onto "$root" "$oldest" HEAD >/dev/null 2>&1; then
    git_at "$SNAPSHOT_DIR" rebase --abort >/dev/null 2>&1 || true
    echo "prune: history rewrite failed; rebuilding instead of leaving an unbounded repository" >&2
    rebuild_history || { echo "prune: rebuild failed" >&2; return 1; }
    return 0
  fi

  if ! git_at "$SNAPSHOT_DIR" reflog expire --expire=now --all; then
    echo "prune: reflog expire failed; rebuilding" >&2
    rebuild_history || return 1
    return 0
  fi
  if ! git_at "$SNAPSHOT_DIR" -c pack.window=3 -c pack.depth=10 gc --prune=now --quiet; then
    echo "prune: gc failed (memory cap or disk); rebuilding" >&2
    rebuild_history || return 1
    return 0
  fi

  size="$(repo_size_bytes || printf '0')"
  if [ "${size:-0}" -gt "$MAX_REPO_BYTES" ]; then
    echo "prune: repository still ${size} bytes after gc (limit ${MAX_REPO_BYTES}); rebuilding" >&2
    rebuild_history || return 1
  fi
}

if [ "$REBUILD" -eq 1 ]; then
  if ! snapshot_repo_ok && [ ! -f "$SNAPSHOT_DIR/state.json" ]; then
    echo "rebuild: ${SNAPSHOT_DIR} has neither a committed snapshot nor a state.json" >&2
    exit 1
  fi
  rebuild_history
  exit $?
fi

if [ "$ACTION" = "list" ]; then
  if ! list_snapshots; then
    echo "snapshot API unavailable; showing local repository history" >&2
    if [ -d "$SNAPSHOT_DIR/.git" ]; then
      git_at "$SNAPSHOT_DIR" log --oneline --decorate -n 20
    fi
  fi
  echo
  if [ -d "$SNAPSHOT_DIR/.git" ]; then
    echo "repository: ${SNAPSHOT_DIR} ($(du -sh "$SNAPSHOT_DIR" 2>/dev/null | cut -f1))"
  fi
  exit 0
fi

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

# Before the server commits, not after: this is what stops its `git commit` from
# invoking gc --auto on an already large repository.
disable_auto_gc

MESSAGE="agentmemory snapshot $(date -Is)"
PAYLOAD="$(printf '{"message":%s}' "$(json_escape "$MESSAGE")")"

echo "creating snapshot: ${MESSAGE}"
if ! wait_for_server; then
  echo "snapshot failed; agentmemory is not reachable at ${BASE_URL}" >&2
  exit 1
fi
OUT="$(api POST /agentmemory/snapshot/create "$PAYLOAD")"
printf '%s\n' "$OUT"

# The server answers success:true with this message when its in-memory
# snapshotInFlight flag is set, which also happens when an earlier create call
# never settled (for example because its git was killed). Nothing was written;
# only a server restart clears the flag.
if printf '%s' "$OUT" | grep -q 'Snapshot already in progress'; then
  echo "snapshot: the server reports a snapshot already in progress, so nothing was created." >&2
  echo "snapshot: if this persists, restart the agentmemory server (the flag is in-memory)." >&2
  exit 1
fi

if ! printf '%s' "$OUT" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
  echo "snapshot failed; is SNAPSHOT_ENABLED=true in ~/.agentmemory/.env and the server running?" >&2
  exit 1
fi

if [ "$PRUNE" -eq 1 ]; then
  prune_snapshots
fi
