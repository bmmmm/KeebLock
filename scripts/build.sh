#!/usr/bin/env bash
# KeebLock build helper.
#
# Uses a project-local DerivedData path (build/DerivedData) so the build
# works under restricted sandboxes that can only write inside the project
# tree (e.g. Claude Code's default Bash sandbox).
#
# Usage:
#   scripts/build.sh             # build (default)
#   scripts/build.sh analyze     # static analyzer
#   scripts/build.sh clean       # remove local DerivedData
#   scripts/build.sh full        # build, but print full output (no filter)
#
# Output is filtered to errors, warnings, and the final BUILD line. The
# script's exit code reflects xcodebuild's exit code.

set -uo pipefail

cd "$(dirname "$0")/.."

ACTION="${1:-build}"
DERIVED="build/DerivedData"

if [ "$ACTION" = "clean" ]; then
    rm -rf "$DERIVED"
    echo "Cleaned $DERIVED"
    exit 0
fi

FILTER=1
if [ "$ACTION" = "full" ]; then
    FILTER=0
    ACTION="build"
fi

LOG=$(mktemp)
xcodebuild \
    -project KeebLock.xcodeproj \
    -scheme KeebLock \
    -configuration Debug \
    -derivedDataPath "$DERIVED" \
    "$ACTION" >"$LOG" 2>&1
status=$?

if [ "$FILTER" = "1" ]; then
    grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" "$LOG" | tail -40 || true
else
    cat "$LOG"
fi

rm -f "$LOG"
exit $status
