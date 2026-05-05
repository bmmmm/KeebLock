#!/usr/bin/env bash
# KeebLock uninstaller — double-click this file in Finder to run.
#
# What gets removed:
#   • KeebLock.app from /Applications
#   • UserDefaults (settings, heatmap data)  [domain: bmako101.KeebLock]
#   • ~/Library/Logs/KeebLock/
#
# What you need to do manually afterwards:
#   • Revoke Accessibility permission:
#       System Settings → Privacy & Security → Accessibility → remove KeebLock

set -uo pipefail

BUNDLE_ID="bmako101.KeebLock"
APP_PATH="/Applications/KeebLock.app"
LOG_DIR="$HOME/Library/Logs/KeebLock"

echo "KeebLock Uninstaller"
echo "===================="
echo ""
echo "This will permanently remove:"
echo "  • $APP_PATH"
echo "  • All settings and heatmap data"
echo "  • Log files"
echo ""
read -rp "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# --- 1. Quit the app ---------------------------------------------------------
if pgrep -xq "KeebLock" 2>/dev/null; then
    echo "→ Quitting KeebLock..."
    osascript -e 'tell application "KeebLock" to quit' 2>/dev/null \
        || pkill -x KeebLock 2>/dev/null \
        || true
    sleep 1
fi

# --- 2. Remove UserDefaults --------------------------------------------------
echo "→ Removing settings..."
defaults delete "$BUNDLE_ID" 2>/dev/null && echo "   removed" || echo "   (nothing to remove)"

# --- 3. Remove log files -----------------------------------------------------
if [[ -d "$LOG_DIR" ]]; then
    echo "→ Removing log files..."
    rm -rf "$LOG_DIR"
    echo "   removed"
fi

# --- 4. Remove app bundle ----------------------------------------------------
if [[ -d "$APP_PATH" ]]; then
    echo "→ Moving KeebLock.app to Trash..."
    osascript -e "tell application \"Finder\" to delete POSIX file \"$APP_PATH\"" 2>/dev/null \
        || { rm -rf "$APP_PATH"; echo "   (removed directly)"; }
    echo "   done"
else
    echo "→ KeebLock.app not found in /Applications."
fi

echo ""
echo "KeebLock has been uninstalled."
echo ""
echo "One manual step remains:"
echo "  System Settings → Privacy & Security → Accessibility"
echo "  → Remove KeebLock from the list."
echo ""
read -rp "Press Enter to close..."
