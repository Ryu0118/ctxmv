#!/bin/bash
set -euo pipefail

REPO="Ryu0118/ctxmv"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *) echo "error: unsupported OS: $os" >&2; exit 1 ;;
  esac

  case "$arch" in
    x86_64|amd64)  arch="x86_64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) echo "error: unsupported architecture: $arch" >&2; exit 1 ;;
  esac

  # macOS release is a universal binary
  if [ "$os" = "darwin" ]; then
    echo "darwin-universal"
  else
    echo "${os}-${arch}"
  fi
}

fetch_latest_tag() {
  local url
  url="$(curl -sI "https://github.com/${REPO}/releases/latest" \
    | grep -i '^location:' \
    | sed 's/.*tag\///' \
    | tr -d '\r\n')"
  echo "$url"
}

main() {
  local platform tag archive_url
  local tmp=""

  platform="$(detect_platform)"
  tag="$(fetch_latest_tag)"

  if [ -z "$tag" ]; then
    echo "error: failed to fetch latest release tag" >&2
    exit 1
  fi

  archive_url="https://github.com/${REPO}/releases/download/${tag}/ctxmv-${tag}-${platform}.tar.gz"

  echo "Installing ctxmv ${tag} (${platform})..."

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  curl -fsSL "$archive_url" | tar xz -C "$tmp"
  mkdir -p "$INSTALL_DIR"
  install -m 755 "$tmp/ctxmv" "$INSTALL_DIR/ctxmv"

  echo "Installed ctxmv to ${INSTALL_DIR}/ctxmv"

  if ! echo ":$PATH:" | grep -q ":${INSTALL_DIR}:"; then
    echo ""
    echo "WARNING: ${INSTALL_DIR} is not in your PATH."
    echo "Add the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
    echo ""
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    echo ""
  fi
}

main
