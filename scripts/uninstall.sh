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

# No `set -e`: every step below reports its own success/failure and keeps
# going so a locked log file or a missing app bundle doesn't abort the rest
# of the cleanup — the final summary already tells the user what's left.
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
if defaults domains 2>/dev/null | tr ', ' '\n\n' | grep -qxF "$BUNDLE_ID"; then
    if defaults delete "$BUNDLE_ID" 2>/dev/null; then
        echo "   removed"
    else
        echo "   WARNING: failed to remove UserDefaults domain $BUNDLE_ID — remove manually with: defaults delete $BUNDLE_ID"
    fi
else
    echo "   (nothing to remove)"
fi

# --- 3. Remove log files -----------------------------------------------------
if [[ -d "$LOG_DIR" ]]; then
    echo "→ Removing log files ($LOG_DIR)..."
    if rm -rf "$LOG_DIR" 2>/dev/null; then
        echo "   removed"
    else
        echo "   WARNING: failed to remove $LOG_DIR — remove manually with: rm -rf \"$LOG_DIR\""
    fi
else
    echo "→ No log files found."
fi

# --- 4. Remove app bundle ----------------------------------------------------
if [[ -d "$APP_PATH" ]]; then
    echo "→ Moving KeebLock.app to Trash..."
    if osascript -e "tell application \"Finder\" to delete POSIX file \"$APP_PATH\"" 2>/dev/null; then
        echo "   done"
    elif rm -rf "$APP_PATH" 2>/dev/null; then
        echo "   removed directly — Finder not available"
    else
        echo "   WARNING: failed to remove $APP_PATH — remove manually with: rm -rf \"$APP_PATH\""
    fi
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
