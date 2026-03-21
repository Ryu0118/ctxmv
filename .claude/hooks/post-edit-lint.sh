#!/bin/sh
FILE_PATH=$(jq -r '.tool_input.file_path // ""')
echo "$FILE_PATH" | grep -q '\.swift$' || exit 0
[ -f "$FILE_PATH" ] || exit 0

SRCROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

if [ -x "$SRCROOT/.nest/bin/swiftlint" ]; then
  SWIFTLINT="$SRCROOT/.nest/bin/swiftlint"
else
  SWIFTLINT=$(command -v swiftlint) || exit 0
fi
[ -f "$SRCROOT/.swiftlint.yml" ] || exit 0

LINT_OUTPUT=$("$SWIFTLINT" lint --config "$SRCROOT/.swiftlint.yml" --strict --quiet "$FILE_PATH" 2>&1) || true
if [ -n "$LINT_OUTPUT" ]; then
  echo "$LINT_OUTPUT"
fi

exit 0
