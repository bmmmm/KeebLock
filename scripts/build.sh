#!/usr/bin/env bash
# KeebLock build helper.
#
# Uses a project-local DerivedData path (build/DerivedData) so the build
# works under restricted sandboxes that can only write inside the project
# tree (e.g. Claude Code's default Bash sandbox).
#
# Auto-versioning: MARKETING_VERSION is derived from the latest git tag
# (e.g. v0.1.0 → 0.1.0), CFBundleVersion from `git rev-list --count HEAD`.
# These are passed to xcodebuild as command-line settings so pbxproj stays
# untouched. Override with VERSION=… BUILD=… env vars (release.sh does that
# to pin a build to a specific tag). Without git, falls back to 0.0.0-dev/1.
#
# Usage:
#   scripts/build.sh             # Debug build (default)
#   scripts/build.sh analyze     # static analyzer
#   scripts/build.sh clean       # remove local DerivedData
#   scripts/build.sh full        # Debug build with full xcodebuild log
#   scripts/build.sh release     # Release configuration (used by release.sh)
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
CONFIGURATION="Debug"
case "$ACTION" in
    full)    FILTER=0; ACTION="build" ;;
    release) ACTION="build"; CONFIGURATION="Release" ;;
esac

# --- Version derivation ------------------------------------------------------
VERSION="${VERSION:-}"
BUILD="${BUILD:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
    [ -z "$VERSION" ] && VERSION="0.0.0-dev"
fi
if [ -z "$BUILD" ]; then
    BUILD="$(git rev-list --count HEAD 2>/dev/null || echo "1")"
fi
echo "Building $CONFIGURATION  $VERSION ($BUILD)"

LOG=$(mktemp)
# -allowProvisioningUpdates is required: without it, xcodebuild reads a
# stale signing reference from the build cache and fails with "Signing
# certificate is invalid" even when the keychain has a fresh, valid
# Personal-Team cert. With the flag, xcodebuild re-resolves the identity
# against Xcode's account state on every build.
xcodebuild \
    -project KeebLock.xcodeproj \
    -scheme KeebLock \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    "$ACTION" >"$LOG" 2>&1
status=$?

if [ "$FILTER" = "1" ]; then
    grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" "$LOG" | tail -40 || true
else
    cat "$LOG"
fi

rm -f "$LOG"
exit $status
