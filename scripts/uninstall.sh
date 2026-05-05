#!/usr/bin/env bash
# KeebLock uninstaller — removes all app data and the app bundle.
#
# What gets removed:
#   • KeebLock.app from /Applications
#   • UserDefaults (settings, heatmap data)  [domain: bmako101.KeebLock]
#   • ~/Library/Logs/KeebLock/
#
# What you need to do manually afterwards:
#   • Revoke Accessibility permission:
#       System Settings → Privacy & Security → Accessibility → remove KeebLock
#
# Usage (from repo root or inside the app bundle):
#   scripts/uninstall.sh             # interactive
#   scripts/uninstall.sh --yes       # skip confirmation (CI/scripting)

set -uo pipefail

BUNDLE_ID="bmako101.KeebLock"
APP_PATH="/Applications/KeebLock.app"
LOG_DIR="$HOME/Library/Logs/KeebLock"
SKIP_CONFIRM=0
[[ "${1:-}" == "--yes" ]] && SKIP_CONFIRM=1

echo "KeebLock Uninstaller"
echo "===================="
echo ""
echo "This will permanently remove:"
echo "  • $APP_PATH"
echo "  • All settings and heatmap data (UserDefaults: $BUNDLE_ID)"
echo "  • Log files ($LOG_DIR)"
echo ""

if [[ "$SKIP_CONFIRM" -eq 0 ]]; then
    read -rp "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# --- 1. Quit the app ---------------------------------------------------------
if pgrep -xq "KeebLock" 2>/dev/null; then
    echo "→ Quitting KeebLock..."
    osascript -e 'tell application "KeebLock" to quit' 2>/dev/null \
        || pkill -x KeebLock 2>/dev/null \
        || true
    sleep 1
fi

# --- 2. Remove UserDefaults --------------------------------------------------
echo "→ Removing settings (UserDefaults)..."
defaults delete "$BUNDLE_ID" 2>/dev/null && echo "   removed" || echo "   (nothing to remove)"

# --- 3. Remove log files -----------------------------------------------------
if [[ -d "$LOG_DIR" ]]; then
    echo "→ Removing log files ($LOG_DIR)..."
    rm -rf "$LOG_DIR"
    echo "   removed"
else
    echo "→ No log files found."
fi

# --- 4. Remove app bundle ----------------------------------------------------
if [[ -d "$APP_PATH" ]]; then
    echo "→ Moving KeebLock.app to Trash..."
    osascript -e "tell application \"Finder\" to delete POSIX file \"$APP_PATH\"" 2>/dev/null \
        || { rm -rf "$APP_PATH"; echo "   (removed directly — Finder not available)"; }
    echo "   done"
else
    echo "→ KeebLock.app not found in /Applications (already removed?)."
fi

# --- Done --------------------------------------------------------------------
echo ""
echo "KeebLock has been uninstalled."
echo ""
echo "One manual step remains:"
echo "  System Settings → Privacy & Security → Accessibility"
echo "  → Remove KeebLock from the list to revoke the event-tap permission."
