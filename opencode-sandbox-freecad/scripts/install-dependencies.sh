#!/bin/bash
set -euo pipefail

# Host setup for the opencode-sandbox kit:
#   - Docker Sandboxes (sbx) from the pinned release artifact, sha256-verified
#   - KVM availability checks (local sandboxes need hardware virtualization)
#   - agentmemory CLI / MCP server from npm
#
# Written and tested on Debian 13. Docker supports local sandboxes on
# Ubuntu 24.04+; other Debian-family systems usually work but are untested.

AGENTMEMORY_VERSION="0.9.30"
DOCKER_SANDBOX_VERSION="0.48.0"

SKIP_DOCKER_SANDBOX=false
SKIP_AGENTMEMORY=false
for arg in "$@"; do
  case "$arg" in
    --skip-docker-sandbox) SKIP_DOCKER_SANDBOX=true ;;
    --skip-agentmemory) SKIP_AGENTMEMORY=true ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--skip-docker-sandbox] [--skip-agentmemory]" >&2
      exit 1
      ;;
  esac
done

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  echo "Error: run this script as $SUDO_USER, not via sudo." >&2
  echo "It calls sudo itself where needed." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"

if [ "$SKIP_DOCKER_SANDBOX" = false ]; then
  if [ "$(uname -s)" != "Linux" ]; then
    echo "Error: local sandboxes need Linux; Docker supports Ubuntu 24.04 and later." >&2
    echo "See https://docs.docker.com/ai/sandboxes/install/" >&2
    exit 1
  fi

  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
    echo "Error: installing the sbx package needs apt-get and dpkg (Debian-family systems)." >&2
    echo "Install sbx manually on other distributions, then rerun this script." >&2
    echo "See https://github.com/docker/sbx-releases#manual-install-from-release-artifacts" >&2
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required to download the sbx package." >&2
    exit 1
  fi

  SBX_ARCH="$(dpkg --print-architecture)"
  case "$SBX_ARCH" in
    amd64) SBX_SHA256="ba972487a0625ca87c2230a65c83a2f7177f97930a74b69c310c1106232c0388" ;;
    arm64) SBX_SHA256="5824039bc796dcf54a46d50191395f0ac16d712f3ba6d5142bdcbe8a41410b68" ;;
    *)
      echo "Error: unsupported architecture \"$SBX_ARCH\"; Docker Sandboxes publishes amd64 and arm64." >&2
      exit 1
      ;;
  esac

  INSTALLED_SBX="$(sbx version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  if [ -n "$INSTALLED_SBX" ] &&
     [ "$(printf '%s\n%s\n' "$DOCKER_SANDBOX_VERSION" "$INSTALLED_SBX" | sort -V | tail -n 1)" = "$INSTALLED_SBX" ]; then
    echo "Docker Sandbox: sbx $INSTALLED_SBX is already installed (>= $DOCKER_SANDBOX_VERSION), skipping."
  else
    DEB_NAME="DockerSandboxes-linux-${SBX_ARCH}-ubuntu2404.deb"
    DEB_URL="https://github.com/docker/sbx-releases/releases/download/v${DOCKER_SANDBOX_VERSION}/${DEB_NAME}"

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT

    echo "Docker Sandbox: downloading sbx $DOCKER_SANDBOX_VERSION ($SBX_ARCH)..."
    curl -fL --proto '=https' --tlsv1.2 "$DEB_URL" -o "$TMP_DIR/$DEB_NAME"

    if ! echo "$SBX_SHA256  $TMP_DIR/$DEB_NAME" | sha256sum -c -; then
      echo "Error: $DEB_NAME failed SHA-256 verification; aborting." >&2
      exit 1
    fi

    sudo apt-get install -y "$TMP_DIR/$DEB_NAME"
    echo "Docker Sandbox: installed sbx $DOCKER_SANDBOX_VERSION."
  fi

  # Prerequisites for local sandboxes, from the official docs:
  # https://docs.docker.com/ai/sandboxes/install/#linux
  if id -nG "$TARGET_USER" | grep -qw kvm; then
    echo "KVM: $TARGET_USER is already in the kvm group."
  else
    sudo groupadd -f kvm
    sudo usermod -aG kvm "$TARGET_USER"
    echo "Added $TARGET_USER to the kvm group. Sign out and back in (or run 'newgrp kvm') for the change to take effect."
  fi

  if [ -e /dev/kvm ] || lsmod 2>/dev/null | grep -q '^kvm'; then
    echo "KVM: hardware virtualization is available."
  else
    echo "KVM: not enabled; attempting to load the KVM kernel modules..."
    sudo modprobe kvm 2>/dev/null || true
    if grep -qw vmx /proc/cpuinfo; then
      sudo modprobe kvm_intel 2>/dev/null || true
    elif grep -qw svm /proc/cpuinfo; then
      sudo modprobe kvm_amd 2>/dev/null || true
    fi

    if [ -e /dev/kvm ] || lsmod 2>/dev/null | grep -q '^kvm'; then
      echo "KVM: enabled."
    else
      if ! command -v kvm-ok >/dev/null 2>&1; then
        sudo apt-get install -y cpu-checker >/dev/null 2>&1 || true
      fi
      if command -v kvm-ok >/dev/null 2>&1; then
        kvm-ok || true
      fi
      echo "WARNING: KVM is not available. Local sandboxes need KVM; enable hardware virtualization in the BIOS/UEFI (and nested virtualization when running inside a VM), then rerun this script." >&2
    fi
  fi
else
  echo "Skipping Docker Sandbox install (--skip-docker-sandbox)."
fi

if [ "$SKIP_AGENTMEMORY" = false ]; then
  if ! command -v npm >/dev/null 2>&1; then
    echo "Error: npm is needed to install the agentmemory CLI, but was not found on PATH." >&2
    echo "Install Node.js 20 or later (for example with nvm) and rerun this script." >&2
    exit 1
  fi

  NODE_MAJOR="$(node --version 2>/dev/null | sed -n 's/^v\([0-9]\+\).*/\1/p')"
  if [ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -lt 20 ]; then
    echo "Error: agentmemory needs Node.js 20 or later (found $(node --version))." >&2
    exit 1
  fi

  NPM_PREFIX="$(npm config get prefix 2>/dev/null || true)"
  if [ -n "$NPM_PREFIX" ] && [ ! -w "$NPM_PREFIX" ]; then
    echo "Error: npm's global prefix \"$NPM_PREFIX\" is not writable by $TARGET_USER." >&2
    echo "Use a Node version manager such as nvm, or configure a user-writable npm prefix." >&2
    exit 1
  fi

  npm install -g @agentmemory/agentmemory@"$AGENTMEMORY_VERSION"
  echo "OK: agentmemory $AGENTMEMORY_VERSION installed."
else
  echo "Skipping agentmemory install (--skip-agentmemory)."
fi
