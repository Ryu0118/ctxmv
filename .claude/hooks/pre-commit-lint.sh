#!/bin/sh
COMMAND=$(jq -r '.tool_input.command // ""')
echo "$COMMAND" | grep -q '^git commit' || exit 0

SRCROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

if [ -x "$SRCROOT/.nest/bin/swiftformat" ]; then
  SWIFTFORMAT="$SRCROOT/.nest/bin/swiftformat"
else
  SWIFTFORMAT=$(command -v swiftformat) || exit 0
fi
if [ -x "$SRCROOT/.nest/bin/swiftlint" ]; then
  SWIFTLINT="$SRCROOT/.nest/bin/swiftlint"
else
  SWIFTLINT=$(command -v swiftlint) || exit 0
fi

STAGED_SWIFT_FILES=$(git diff --cached --name-only --diff-filter=ACM | grep '\.swift$' || true)
if [ -z "$STAGED_SWIFT_FILES" ]; then
  exit 0
fi

if [ -f "$SRCROOT/.swiftformat" ]; then
  echo "$STAGED_SWIFT_FILES" | xargs "$SWIFTFORMAT" --config "$SRCROOT/.swiftformat"
  echo "$STAGED_SWIFT_FILES" | xargs git add
fi

if [ ! -f "$SRCROOT/.swiftlint.yml" ]; then
  exit 0
fi

ABSOLUTE_FILES=""
for file in $STAGED_SWIFT_FILES; do
  if [ -f "$SRCROOT/$file" ]; then
    ABSOLUTE_FILES="$ABSOLUTE_FILES $SRCROOT/$file"
  fi
done

if [ -z "$ABSOLUTE_FILES" ]; then
  exit 0
fi

set +e
# shellcheck disable=SC2086
LINT_OUTPUT=$("$SWIFTLINT" lint --config "$SRCROOT/.swiftlint.yml" --force-exclude --strict --quiet $ABSOLUTE_FILES 2>&1)
LINT_STATUS=$?
set -e

if [ "$LINT_STATUS" -ne 0 ]; then
  REASON=$(printf '%s' "$LINT_OUTPUT" | jq -Rs .)
  printf '{"decision":"block","reason":%s}\n' "$REASON"
fi

exit 0
