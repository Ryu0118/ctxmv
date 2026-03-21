#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
HOOKS_DIR="$REPO_ROOT/.githooks"

if [ ! -d "$HOOKS_DIR" ]; then
  echo "Error: .githooks not found at $HOOKS_DIR"
  exit 1
fi

git config --local core.hooksPath .githooks
chmod +x "$HOOKS_DIR"/*
echo "core.hooksPath=.githooks"
