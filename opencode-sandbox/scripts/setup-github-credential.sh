#!/bin/bash
set -euo pipefail

# Approves the GitHub service credential for the opencode-agentmemory kit and
# reports what is left to do. Run on the host, never inside the sandbox.
#
# The kit is third-party (it extends the built-in `opencode` kit), so sbx
# withholds inherited credentials until a binding approves them. Without the
# `github` binding below, sandboxes start with the credential silently
# withheld and `gh` inside them reports the sentinel token as invalid.

BINDINGS_FILE="${HOME}/.config/sbx/credentials.yaml"
GITHUB_BLOCK='  github:
    apiKey:
      domains: [api.github.com, github.com]'

if [ -L "${HOME}/.config/opencode/plugins" ] || [ -L "${HOME}/.config/opencode/commands" ] || [ -L "${HOME}/.config/opencode/skills" ]; then
  echo "Error: ${HOME}/.config/opencode looks like the sandbox view (symlinks)." >&2
  echo "Run this script on the host, not inside the Docker sandbox." >&2
  exit 1
fi

if ! command -v sbx >/dev/null 2>&1; then
  echo "Error: 'sbx' (Docker Sandboxes) is not installed or not on PATH." >&2
  exit 1
fi

mkdir -p "${HOME}/.config/sbx"

if [ -f "$BINDINGS_FILE" ] && grep -q '^  github:' "$BINDINGS_FILE"; then
  echo "Binding: a github entry already exists in ${BINDINGS_FILE}:"
  grep -A2 '^  github:' "$BINDINGS_FILE" | sed 's/^/  /'
  echo "Binding: leaving it untouched; its domains must cover api.github.com and github.com."
elif [ ! -s "$BINDINGS_FILE" ]; then
  printf 'bindings:\n%s\n' "$GITHUB_BLOCK" > "$BINDINGS_FILE"
  echo "Binding: created ${BINDINGS_FILE} with the github binding."
elif grep -q '^bindings:' "$BINDINGS_FILE"; then
  cp -f "$BINDINGS_FILE" "${BINDINGS_FILE}.bak"
  if [ -n "$(tail -c 1 "$BINDINGS_FILE")" ]; then
    echo >> "$BINDINGS_FILE"
  fi
  printf '%s\n' "$GITHUB_BLOCK" >> "$BINDINGS_FILE"
  echo "Binding: appended the github binding to ${BINDINGS_FILE} (previous version: ${BINDINGS_FILE}.bak)."
else
  echo "Error: ${BINDINGS_FILE} exists but has no top-level 'bindings:' key; leaving it untouched." >&2
  echo "Merge this block into it by hand:" >&2
  echo >&2
  printf 'bindings:\n%s\n' "$GITHUB_BLOCK" >&2
  exit 1
fi

echo
if sbx secret ls 2>/dev/null | grep -Eq '(^|[[:space:]])github([[:space:]]|$)'; then
  echo "Secret: a github service secret is stored."
else
  echo "Secret: no github service secret found. Store your fine-grained PAT with:"
  echo
  echo "  printf '%s' \"\$GITHUB_PAT\" | sbx secret set github"
  echo
  echo "Fine-grained PAT permissions: Contents: Read-only, Issues: Read and write,"
  echo "Pull requests: Read and write (Metadata: Read is mandatory). No Contents:write,"
  echo "because the sandbox must never push."
fi

echo
echo "Re-run this script after an 'sbx reset' (stored secrets are deleted with it)."
