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

# No `set -e` on purpose: xcodebuild's exit status is captured manually
# (status=$?) so the build log can be filtered and cleaned up before exiting
# with that status. A global `set -e` would abort before that handling runs.
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

# --- Codeword/manifest consistency guard -------------------------------------
# Fails the build if any word in Codewords.all lacks a knowledge entry in the
# bundled manifest (would render as an empty HUD stub). Stdlib-only; skipped
# with a warning if python3 is unavailable so the build still runs.
if command -v python3 >/dev/null 2>&1; then
    if ! python3 scripts/check_codewords.py; then
        echo "build.sh: codeword consistency check failed — aborting" >&2
        exit 1
    fi
else
    echo "build.sh: python3 not found — skipping codeword consistency check" >&2
fi

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

LOG=$(mktemp) || { echo "build.sh: mktemp failed — cannot capture build log" >&2; exit 1; }
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
    filtered="$(grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" "$LOG" | tail -40)"
    if [ -n "$filtered" ]; then
        printf '%s\n' "$filtered"
    fi
    # Surface silent failures: if xcodebuild failed but produced no matching
    # line (crash/launch/toolchain failure), dump the raw log tail so the
    # diagnostic isn't lost when the log is removed below.
    if [ "$status" -ne 0 ] && [ -z "$filtered" ]; then
        echo "build.sh: xcodebuild failed with no error/warning line — raw log tail:" >&2
        tail -40 "$LOG" >&2
    fi
else
    cat "$LOG"
fi

rm -f "$LOG"
exit $status
