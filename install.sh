#!/bin/bash
set -eu

REPO="Ryu0118/ctxmv"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

error() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *) error "unsupported OS: $os" ;;
  esac

  case "$arch" in
    x86_64|amd64)  arch="x86_64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) error "unsupported architecture: $arch" ;;
  esac

  if [ "$os" = "darwin" ]; then
    echo "darwin-universal"
  else
    echo "${os}-${arch}"
  fi
}

fetch_latest_tag() {
  curl -sI "https://github.com/${REPO}/releases/latest" \
    | grep -i '^location:' \
    | sed 's/.*tag\///' \
    | tr -d '\r\n'
}

main() {
  command -v curl >/dev/null 2>&1 || error "curl is required but not found"
  command -v tar >/dev/null 2>&1 || error "tar is required but not found"

  local platform tag archive_url download_dir

  platform="$(detect_platform)"
  tag="$(fetch_latest_tag)"

  if [ -z "$tag" ]; then
    error "failed to fetch latest release tag"
  fi

  archive_url="https://github.com/${REPO}/releases/download/${tag}/ctxmv-${tag}-${platform}.tar.gz"

  printf 'Installing ctxmv %s (%s)...\n' "$tag" "$platform"

  download_dir="$(mktemp -d)"

  if ! curl -fsSL "$archive_url" | tar xz -C "$download_dir"; then
    rm -rf "$download_dir"
    error "failed to download or extract ctxmv"
  fi

  mkdir -p "$INSTALL_DIR"
  install -m 755 "$download_dir/ctxmv" "$INSTALL_DIR/ctxmv"
  rm -rf "$download_dir"

  if [ ! -x "$INSTALL_DIR/ctxmv" ]; then
    error "installation failed: binary not found at $INSTALL_DIR/ctxmv"
  fi

  printf 'Installed ctxmv to %s/ctxmv\n' "$INSTALL_DIR"

  if ! echo ":$PATH:" | grep -q ":${INSTALL_DIR}:"; then
    printf '\nWARNING: %s is not in your PATH.\n' "$INSTALL_DIR"
    printf 'Add the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):\n\n'
    printf '  export PATH="%s:$PATH"\n\n' "$INSTALL_DIR"
  fi
}

main
