#!/bin/bash
set -euo pipefail

LOCAL_AI_REPO_DIR="$HOME/developer/personal/local-ai"
DEPENDENCIES_DIR="$LOCAL_AI_REPO_DIR/dependencies"

AGENTMEMORY_VERSION="0.9.30"
DOCKER_SANDBOX_VERSION="0.48.0"
TARGET_USER="${USER:-$(id -un)}"

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

if [ "$SKIP_DOCKER_SANDBOX" = false ]; then
  DOCKER_SANDBOX_DEB="DockerSandboxes-linux-amd64-ubuntu2404.deb"
  DOCKER_SANDBOX_INSTALL="$DEPENDENCIES_DIR/$DOCKER_SANDBOX_DEB"
  DOCKER_SANDBOX_URL="https://github.com/docker/sbx-releases/releases/download/v${DOCKER_SANDBOX_VERSION}/${DOCKER_SANDBOX_DEB}"

  curl -fL "$DOCKER_SANDBOX_URL" -o "$DOCKER_SANDBOX_INSTALL"
  sudo apt install "$DOCKER_SANDBOX_INSTALL"
  rm "$DOCKER_SANDBOX_INSTALL"

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
        sudo apt install -y cpu-checker >/dev/null 2>&1 || true
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
  npm install -g @agentmemory/agentmemory@"$AGENTMEMORY_VERSION"

  AGENTMEMORY_MCP_PREFIX="$DEPENDENCIES_DIR/agentmemory-mcp-prefix"
  AGENTMEMORY_MCP_TARBALL="$DEPENDENCIES_DIR/agentmemory-mcp.tar.gz"
  AGENTMEMORY_MCP_TARBALL_TMP="${AGENTMEMORY_MCP_TARBALL}.tmp"

  rm -rf "$AGENTMEMORY_MCP_PREFIX"
  mkdir -p "$AGENTMEMORY_MCP_PREFIX"
  npm install -g --prefix "$AGENTMEMORY_MCP_PREFIX" @agentmemory/agentmemory@"$AGENTMEMORY_VERSION"
  tar -czf "$AGENTMEMORY_MCP_TARBALL_TMP" -C "$AGENTMEMORY_MCP_PREFIX" .

  if ! tar -tzf "$AGENTMEMORY_MCP_TARBALL_TMP" > /dev/null; then
      echo "ERROR: $AGENTMEMORY_MCP_TARBALL_TMP failed integrity check after creation." >&2
      rm -f "$AGENTMEMORY_MCP_TARBALL_TMP"
      exit 1
  fi

  mv "$AGENTMEMORY_MCP_TARBALL_TMP" "$AGENTMEMORY_MCP_TARBALL"
  echo "OK: archive is valid"
  rm -rf "$AGENTMEMORY_MCP_PREFIX"
else
  echo "Skipping agentmemory MCP install (--skip-agentmemory)."
fi
