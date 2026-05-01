#!/bin/sh
SRCROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$SRCROOT/.gitnagg.yml" ] || exit 0

if [ -x "$SRCROOT/.nest/bin/gitnagg" ]; then
  GITNAGG="$SRCROOT/.nest/bin/gitnagg"
elif command -v gitnagg >/dev/null 2>&1; then
  GITNAGG=$(command -v gitnagg)
else
  exit 0
fi

"$GITNAGG" check --config "$SRCROOT/.gitnagg.yml" --claude-hook
