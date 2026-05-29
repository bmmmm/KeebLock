#!/usr/bin/env bash
# KeebLock installer — copies the built app to /Applications.
#
# Usage (from repo root):
#   scripts/install.sh
#   scripts/install.sh /path/to/KeebLock.app   # explicit source

set -euo pipefail

APP_NAME="KeebLock.app"
DEST="/Applications/$APP_NAME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Resolve source — explicit arg, else search common Xcode output paths.
if [[ -n "${1:-}" ]]; then
    APP_SRC="$1"
else
    APP_SRC=""
    for candidate in \
        "$REPO_ROOT/build/DerivedData/Build/Products/Release/$APP_NAME" \
        "$REPO_ROOT/build/DerivedData/Build/Products/Debug/$APP_NAME"; do
        if [[ -d "$candidate" ]]; then
            APP_SRC="$candidate"
            break
        fi
    done
fi

if [[ -z "${APP_SRC:-}" || ! -d "$APP_SRC" ]]; then
    echo "error: cannot find $APP_NAME — build the project first:"
    echo "  scripts/build.sh"
    exit 1
fi

echo "KeebLock Installer"
echo "=================="
echo "Source:      $APP_SRC"
echo "Destination: $DEST"
echo ""

if [[ -d "$DEST" ]]; then
    echo "KeebLock is already installed."
    read -rp "Replace existing installation? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    # Quit if running so we can replace the bundle safely.
    if pgrep -xq "KeebLock" 2>/dev/null; then
        echo "→ Quitting running instance..."
        osascript -e 'tell application "KeebLock" to quit' 2>/dev/null || pkill -x KeebLock 2>/dev/null || true
        sleep 1
    fi
    rm -rf "$DEST"
fi

echo "→ Copying to /Applications..."
# `ditto` (not `cp -r`) preserves the bundle's extended attributes and
# code-signature metadata faithfully — the same tool release.sh uses for
# packaging. `cp -r` can drop xattrs and risks disturbing signing data.
ditto "$APP_SRC" "$DEST"
echo "→ Done."
echo ""
echo "Next: open KeebLock and grant Accessibility permission when prompted."
echo "  System Settings → Privacy & Security → Accessibility → KeebLock ✓"
