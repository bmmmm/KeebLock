#!/usr/bin/env bash
# Drive the KeebLock perf-test harness from outside the app.
#
# Usage:
#   scripts/run-perf-test.sh <suite> [mode] [output]
#     suite   = burst | savestorm
#     mode    = A (direct, default — safe)
#             | B (real OS-level CGEvent.post — reproduces cursor flicker)
#     output  = path to write JSON snapshot (default: /tmp/keeblock-perf.json)
#
# Safety:
#   - The harness writes $TMPDIR/keeblock-perf-test.lock at launch.
#     Remove that file to abort cleanly:
#         rm "$TMPDIR/keeblock-perf-test.lock"
#   - The app has a hard 30 s timeout regardless of harness state.
#   - Mode A NEVER posts real CGEvents; cannot lock you out.
#   - Mode B requires the lock window to be active; bails if it isn't.

set -euo pipefail

SUITE="${1:?suite required (burst|savestorm)}"
MODE="${2:-A}"
DEFAULT_OUTPUT="${TMPDIR:-/tmp}/keeblock-perf.json"
OUTPUT="${3:-$DEFAULT_OUTPUT}"

case "$SUITE" in
    burst|savestorm) ;;
    *) echo "error: suite must be 'burst' or 'savestorm', got '$SUITE'" >&2; exit 1 ;;
esac
case "$MODE" in
    A|B) ;;
    *) echo "error: mode must be 'A' or 'B', got '$MODE'" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Build debug — the perf-test entry point is #if DEBUG-gated.
if [ ! -x "build/DerivedData/Build/Products/Debug/KeebLock.app/Contents/MacOS/KeebLock" ]; then
    echo "==> building debug…"
    scripts/build.sh
fi

BIN="build/DerivedData/Build/Products/Debug/KeebLock.app/Contents/MacOS/KeebLock"
if [ ! -x "$BIN" ]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> launching perf test  suite=$SUITE  mode=$MODE  output=$OUTPUT"
echo "    (abort externally:  rm \"\$TMPDIR/keeblock-perf-test.lock\")"

# Remove any stale output so we can detect a fresh write.
rm -f "$OUTPUT"

# Run the app. Hard 45 s ceiling at the shell level on top of the in-app
# 30 s — if the binary itself wedges, /usr/bin/timeout (via gtimeout from
# coreutils, falling back to a background kill) prevents an orphan process.
if command -v gtimeout >/dev/null 2>&1; then
    gtimeout 45 "$BIN" --perf-test="$SUITE" --mode="$MODE" --output="$OUTPUT" || true
else
    "$BIN" --perf-test="$SUITE" --mode="$MODE" --output="$OUTPUT" &
    PID=$!
    ( sleep 45; kill -TERM "$PID" 2>/dev/null; sleep 2; kill -KILL "$PID" 2>/dev/null ) &
    WATCHDOG=$!
    wait "$PID" 2>/dev/null || true
    kill "$WATCHDOG" 2>/dev/null || true
fi

if [ -f "$OUTPUT" ]; then
    echo "==> result: $OUTPUT"
    cat "$OUTPUT"
else
    echo "error: no output file produced at $OUTPUT" >&2
    echo "       check ~/Library/Logs/KeebLock/keeblock.log for the harness trace" >&2
    exit 3
fi
