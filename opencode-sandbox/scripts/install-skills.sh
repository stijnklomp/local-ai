#!/bin/bash
set -euo pipefail

# Vendors mattpocock/skills (https://github.com/mattpocock/skills) into the
# host OpenCode config. The sandbox mounts ~/.config/opencode read-only, so the
# copies appear inside it without any in-sandbox download step.
# Run on the host, never inside the sandbox.

CONFIG_DIR="${HOME}/.config/opencode"
SKILLS_DIR="${CONFIG_DIR}/skills"
CLONE_DIR="${CONFIG_DIR}/vendor/mattpocock-skills"
UPSTREAM_URL="https://github.com/mattpocock/skills"

# Only these category directories are script-owned; every other entry in
# ${SKILLS_DIR} (hand-written skills) is left untouched.
CATEGORIES="engineering productivity"

if [ -L "$CONFIG_DIR/plugins" ] || [ -L "$CONFIG_DIR/commands" ] || [ -L "$SKILLS_DIR" ]; then
  echo "Error: ${CONFIG_DIR}/plugins, ${CONFIG_DIR}/commands or ${CONFIG_DIR}/skills is a symlink, which is what the sandbox looks like from the inside." >&2
  echo "Run this script on the host, not inside the Docker sandbox." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is required but was not found on PATH." >&2
  exit 1
fi

mkdir -p "${CONFIG_DIR}/vendor" "$SKILLS_DIR"

if [ -d "$CLONE_DIR/.git" ]; then
  echo "Updating the mattpocock/skills clone in ${CLONE_DIR}..."
  git -C "$CLONE_DIR" pull --ff-only
elif [ -e "$CLONE_DIR" ]; then
  echo "Error: ${CLONE_DIR} exists but is not a git clone. Remove it and re-run." >&2
  exit 1
else
  echo "Cloning ${UPSTREAM_URL} into ${CLONE_DIR}..."
  git clone "$UPSTREAM_URL" "$CLONE_DIR"
fi

TOTAL=0
for CATEGORY in $CATEGORIES; do
  SRC="${CLONE_DIR}/skills/${CATEGORY}"
  DEST="${SKILLS_DIR}/${CATEGORY}"
  if [ ! -d "$SRC" ]; then
    echo "Error: expected ${SRC} in the clone; aborting before touching ${DEST}." >&2
    exit 1
  fi
  rm -rf "$DEST"
  cp -R "$SRC" "$DEST"
  COUNT="$(find "$DEST" -name SKILL.md -type f | wc -l | tr -d '[:space:]')"
  TOTAL=$((TOTAL + COUNT))
  echo "Copied ${CATEGORY}/ (${COUNT} skills) to ${DEST}."
done

echo
echo "Installed ${TOTAL} mattpocock skill(s) under ${SKILLS_DIR}."
echo "Notes:"
echo "- Restart OpenCode (host or sandbox) so the new skills are picked up."
echo "- The ${CATEGORIES} directories are replaced on every run; keep your own variants as separate skills."
echo "- User-invoked skills are hidden from the model; load them with @skill-id (for example @grill-me)."
echo "- Run @setup-matt-pocock-skills once per project repo before using the engineering skills."
