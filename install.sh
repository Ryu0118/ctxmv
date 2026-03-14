#!/bin/bash
set -eu

REPO="Ryu0118/ctxmv"
BIN_NAME="ctxmv"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
FORCE="${FORCE:-}"

error() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

info() {
  printf '%s\n' "$1"
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

installed_version() {
  local bin=""
  if command -v "$BIN_NAME" >/dev/null 2>&1; then
    bin="$(command -v "$BIN_NAME")"
  elif [ -x "$INSTALL_DIR/$BIN_NAME" ]; then
    bin="$INSTALL_DIR/$BIN_NAME"
  fi

  if [ -n "$bin" ]; then
    "$bin" --version 2>/dev/null | head -1 | sed 's/[^0-9.]//g' || true
  fi
}

needs_sudo() {
  if [ -d "$INSTALL_DIR" ]; then
    [ ! -w "$INSTALL_DIR" ]
  else
    local parent="$INSTALL_DIR"
    while [ ! -d "$parent" ]; do
      parent="$(dirname "$parent")"
    done
    [ ! -w "$parent" ]
  fi
}

run_cmd() {
  if needs_sudo; then
    if ! command -v sudo >/dev/null 2>&1; then
      error "$INSTALL_DIR is not writable and sudo is not available"
    fi
    info "Elevated permissions required for $INSTALL_DIR"
    sudo "$@"
  else
    "$@"
  fi
}

main() {
  command -v curl >/dev/null 2>&1 || error "curl is required but not found"
  command -v tar >/dev/null 2>&1 || error "tar is required but not found"

  local platform version archive_url download_dir

  platform="$(detect_platform)"

  if [ -n "${VERSION:-}" ]; then
    version="$VERSION"
  else
    version="$(fetch_latest_tag)"
  fi

  if [ -z "$version" ]; then
    error "failed to determine version to install"
  fi

  local clean_version
  clean_version="$(echo "$version" | sed 's/^v//')"
  local current
  current="$(installed_version)"

  if [ -n "$current" ] && [ "$current" = "$clean_version" ] && [ -z "$FORCE" ]; then
    info "$BIN_NAME $clean_version is already installed. Use FORCE=1 to reinstall."
    exit 0
  fi

  archive_url="https://github.com/${REPO}/releases/download/${version}/${BIN_NAME}-${version}-${platform}.tar.gz"

  if [ -n "$current" ]; then
    info "Updating $BIN_NAME $current -> $clean_version ($platform)..."
  else
    info "Installing $BIN_NAME $clean_version ($platform)..."
  fi

  download_dir="$(mktemp -d)"

  if ! curl -fsSL "$archive_url" | tar xz -C "$download_dir"; then
    rm -rf "$download_dir"
    error "failed to download or extract $BIN_NAME $version"
  fi

  if [ ! -f "$download_dir/$BIN_NAME" ]; then
    rm -rf "$download_dir"
    error "binary not found in archive"
  fi

  chmod +x "$download_dir/$BIN_NAME"
  run_cmd mkdir -p "$INSTALL_DIR"
  run_cmd mv -f "$download_dir/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
  rm -rf "$download_dir"

  if [ ! -x "$INSTALL_DIR/$BIN_NAME" ]; then
    error "installation failed: $INSTALL_DIR/$BIN_NAME not found"
  fi

  info "Installed $BIN_NAME $clean_version to $INSTALL_DIR/$BIN_NAME"

  if ! echo ":$PATH:" | grep -q ":${INSTALL_DIR}:"; then
    printf '\nWARNING: %s is not in your PATH.\n' "$INSTALL_DIR"
    printf 'Add the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):\n\n'
    printf '  export PATH="%s:$PATH"\n\n' "$INSTALL_DIR"
  fi
}

main
