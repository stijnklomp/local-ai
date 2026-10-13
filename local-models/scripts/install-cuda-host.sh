#!/bin/bash
set -euo pipefail

KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb"
TOOLKIT_PACKAGE="cuda-toolkit-13-2"
MIN_DRIVER="580.65.06"

fail() { echo "error: $*" >&2; exit 1; }

find_nvcc() {
  local p found=""
  if [ -x /usr/local/cuda/bin/nvcc ]; then
    readlink -f /usr/local/cuda/bin/nvcc
    return 0
  fi
  for p in /usr/local/cuda-13*/bin/nvcc; do
    if [ -x "$p" ]; then found="$p"; fi
  done
  if [ -n "$found" ]; then
    readlink -f "$found"
    return 0
  fi
  if command -v nvcc >/dev/null 2>&1; then
    readlink -f "$(command -v nvcc)"
    return 0
  fi
  return 1
}

[ -r /etc/os-release ] || fail "/etc/os-release not found"
. /etc/os-release
[ "${ID:-}" = "debian" ] || fail "this script targets Debian (found ID=${ID:-unknown})"
[ "${VERSION_ID:-}" = "13" ] || fail "this script targets Debian 13 (found version ${VERSION_ID:-unknown})"
[ "$(dpkg --print-architecture)" = "amd64" ] || fail "this script targets amd64"

command -v nvidia-smi >/dev/null 2>&1 || fail "nvidia-smi not found; install the NVIDIA driver first (this script does not install drivers)"

DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1)"
if [ "$(printf '%s\n%s\n' "$DRIVER_VERSION" "$MIN_DRIVER" | sort -V | head -n 1)" != "$MIN_DRIVER" ]; then
  fail "driver $DRIVER_VERSION is older than $MIN_DRIVER; CUDA 13 needs a newer driver (this script does not install drivers)"
fi

NVCC_PATH="$(find_nvcc || true)"
NVCC_MAJOR=""
if [ -n "$NVCC_PATH" ]; then
  NVCC_MAJOR="$(sed -n 's/.*release \([0-9]*\)\..*/\1/p' <<< "$("$NVCC_PATH" --version)")"
fi

if [ "$NVCC_MAJOR" = "13" ]; then
  echo "CUDA 13 toolkit already present: $NVCC_PATH"
else
  if [ -n "$NVCC_PATH" ]; then
    echo "Found CUDA ${NVCC_MAJOR:-unknown} at $NVCC_PATH; installing CUDA 13.2 alongside it."
  fi

  if [ "$(id -u)" -eq 0 ]; then
    SUDO=()
  else
    command -v sudo >/dev/null 2>&1 || fail "sudo not found and not running as root"
    SUDO=(sudo)
  fi

  command -v curl >/dev/null 2>&1 || {
    echo "Installing curl..."
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y curl
  }

  AVAIL_KB="$(df -Pk /usr/local | tail -n 1 | awk '{print $4}')"
  if [ "${AVAIL_KB:-0}" -lt 12582912 ]; then
    echo "warning: less than 12 GiB free on /usr/local; the toolkit needs several GB" >&2
  fi

  KEYRING_DEB="$(mktemp --suffix=.deb)"
  trap 'rm -f "$KEYRING_DEB"' EXIT

  echo "Downloading the NVIDIA CUDA keyring for Debian 13..."
  curl -fsSL "$KEYRING_URL" -o "$KEYRING_DEB"

  echo "Installing the keyring..."
  "${SUDO[@]}" dpkg -i "$KEYRING_DEB"
  "${SUDO[@]}" apt-get update

  echo "Installing $TOOLKIT_PACKAGE (this downloads several GB)..."
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$TOOLKIT_PACKAGE"

  NVCC_PATH="$(find_nvcc || true)"
  [ -n "$NVCC_PATH" ] || fail "installation finished but nvcc was not found; check the install log"
  NVCC_MAJOR="$(sed -n 's/.*release \([0-9]*\)\..*/\1/p' <<< "$("$NVCC_PATH" --version)")"
  [ "$NVCC_MAJOR" = "13" ] || fail "expected CUDA 13 but found release $NVCC_MAJOR at $NVCC_PATH"
fi

echo
echo "GPU:  $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -n 1)"
echo "nvcc: $("$NVCC_PATH" --version | tail -n 1)"

CUDA_BIN_DIR="$(dirname "$NVCC_PATH")"
echo
echo "Make nvcc available on PATH (once), if it is not already there:"
echo "  fish: fish_add_path $CUDA_BIN_DIR"
echo "  bash: export PATH=\"$CUDA_BIN_DIR:\$PATH\""
echo
echo "The build and run scripts set everything else up; no ldconfig changes are needed."
