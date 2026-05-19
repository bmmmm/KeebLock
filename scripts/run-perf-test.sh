#!/usr/bin/env bash
# Drive the KeebLock perf-test harness from outside the app.
#
# Usage:
#   scripts/run-perf-test.sh <suite> [mode] [output]
#     suite   = burst | savestorm | mousekeymix
#     mode    = A (direct, default — safe)
#             | B (real OS-level CGEvent.post — reproduces cursor flicker /
#                 cursor warp; pre-flighted against lock+tap)
#     output  = path to write JSON snapshot (default: $TMPDIR/keeblock-perf.json)
#
#   scripts/run-perf-test.sh --battery [output-dir]
#     Runs every (suite × mode) combo sequentially, writes one JSON per run
#     into output-dir (default: $TMPDIR), then writes a battery summary
#     at <output-dir>/keeblock-perf-battery-<timestamp>.json containing
#     p99/max for all/key/mouse latency plus tap-timeouts + samples.
#
# Safety:
#   - The harness writes $TMPDIR/keeblock-perf-test.lock at launch.
#     Remove that file to abort cleanly:
#         rm "$TMPDIR/keeblock-perf-test.lock"
#   - The app has a hard 30 s timeout regardless of harness state.
#   - Mode A NEVER posts real CGEvents; cannot lock you out.
#   - Mode B requires the lock window to be active; bails if it isn't.
#   - mousekeymix posts mouseMoved events; the lock's session tap swallows
#     them. If the tap drops, the synthetic cursor warps stop too.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_BUNDLE="$ROOT/build/DerivedData/Build/Products/Debug/KeebLock.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/KeebLock"
TMP="${TMPDIR:-/tmp}"
# Strip trailing slash so we can paste paths without doubles.
TMP="${TMP%/}"

build_if_needed() {
    if [ ! -x "$APP_BIN" ]; then
        echo "==> building debug…"
        scripts/build.sh
    fi
    if [ ! -x "$APP_BIN" ]; then
        echo "error: built binary not found at $APP_BIN" >&2
        exit 1
    fi
}

# Single run. Args: suite, mode, output_path.
#
# Why `open -W -na` instead of direct exec of $APP_BIN: the direct exec
# launches the process without going through LaunchServices/runningboard,
# which leaves the audio HAL in a state where AVAudioPlayerNode() throws
# `comp != nullptr` at SoundPlayer init — long before our perf-test code
# even gets a chance to run. `open -W -na`:
#   -n  new instance (don't reuse an already-running KeebLock)
#   -a  launch the named app
#   -W  wait for it to terminate
# gives the bundle a proper process context, so audio init succeeds and
# the perf-test runs end-to-end as designed.
run_one() {
    local suite="$1" mode="$2" output="$3"
    echo "==> launching perf test  suite=$suite  mode=$mode  output=$output"
    echo "    (abort externally:  rm \"\$TMPDIR/keeblock-perf-test.lock\")"

    # Remove any stale output so we can detect a fresh write.
    rm -f "$output"

    # Hard ceiling at the shell level on top of the in-app 30 s timeout.
    # mousekeymix takes ~10 s of injection + warmup/teardown overhead, so
    # a 60 s shell timeout leaves headroom even when the harness has to
    # write its own snapshot from the hard-timeout path.
    local timeout_secs=60
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$timeout_secs" open -W -na "$APP_BUNDLE" --args \
            --perf-test="$suite" --mode="$mode" --output="$output" || true
    else
        open -W -na "$APP_BUNDLE" --args \
            --perf-test="$suite" --mode="$mode" --output="$output" &
        local pid=$!
        ( sleep "$timeout_secs"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) &
        local watchdog=$!
        wait "$pid" 2>/dev/null || true
        kill "$watchdog" 2>/dev/null || true
    fi

    if [ ! -f "$output" ]; then
        echo "error: no output file produced at $output" >&2
        echo "       check ~/Library/Logs/KeebLock/keeblock.log for the harness trace" >&2
        return 3
    fi
    echo "==> result: $output"
}

run_single() {
    local suite="$1" mode="$2" output="$3"
    case "$suite" in
        burst|savestorm|mousekeymix) ;;
        *) echo "error: suite must be burst|savestorm|mousekeymix, got '$suite'" >&2; exit 1 ;;
    esac
    case "$mode" in
        A|B) ;;
        *) echo "error: mode must be 'A' or 'B', got '$mode'" >&2; exit 1 ;;
    esac
    build_if_needed
    run_one "$suite" "$mode" "$output"
    cat "$output"
}

# Aggregates an array of run files into a summary JSON. Pulls latency + tap
# stats + counters from each. Falls back to python3 if jq is missing.
write_battery_summary() {
    local out="$1"; shift
    local files=("$@")
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if command -v jq >/dev/null 2>&1; then
        local jq_filter='
          {
            timestamp: $ts,
            runs: [ .[] | {
              suite: .suite,
              mode: .mode,
              durationMs: .durationMs,
              latency: {
                all:   .latencyUs       | {avg, p50, p95, p99, max, samples},
                key:   .keyLatencyUs    | {avg, p50, p95, p99, max, samples},
                mouse: .mouseLatencyUs  | {avg, p50, p95, p99, max, samples}
              },
              counters: {
                eventsTotal:      .counters.eventsTotal,
                mouseEventsTotal: .counters.mouseEventsTotal,
                tapTimeouts:      .counters.tapTimeouts,
                wipesTotal:       .counters.wipesTotal
              }
            } ]
          }'
        jq -s --arg ts "$ts" "$jq_filter" "${files[@]}" > "$out"
    else
        python3 - "$out" "$ts" "${files[@]}" <<'PY'
import json, sys
out, ts = sys.argv[1], sys.argv[2]
runs = []
for path in sys.argv[3:]:
    with open(path) as f:
        s = json.load(f)
    def stats(d):
        return {k: d.get(k) for k in ("avg", "p50", "p95", "p99", "max", "samples")}
    runs.append({
        "suite": s.get("suite"),
        "mode": s.get("mode"),
        "durationMs": s.get("durationMs"),
        "latency": {
            "all":   stats(s.get("latencyUs", {})),
            "key":   stats(s.get("keyLatencyUs", {})),
            "mouse": stats(s.get("mouseLatencyUs", {})),
        },
        "counters": {k: s.get("counters", {}).get(k) for k in (
            "eventsTotal", "mouseEventsTotal", "tapTimeouts", "wipesTotal"
        )},
    })
with open(out, "w") as f:
    json.dump({"timestamp": ts, "runs": runs}, f, indent=2, sort_keys=True)
PY
    fi
}

run_battery() {
    local out_dir="${1:-$TMP}"
    out_dir="${out_dir%/}"
    mkdir -p "$out_dir"
    build_if_needed
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local files=()
    for suite in burst savestorm mousekeymix; do
        for mode in A B; do
            local out="$out_dir/keeblock-perf-${suite}-${mode}-${ts}.json"
            echo
            echo "===================================================================="
            echo "  battery step: suite=$suite  mode=$mode"
            echo "===================================================================="
            if run_one "$suite" "$mode" "$out"; then
                files+=("$out")
            else
                echo "warning: $suite/$mode failed, skipping in summary" >&2
            fi
            # Brief gap so the app has time to fully exit between runs;
            # otherwise the next launch can race on the kill-file.
            sleep 1
        done
    done

    if [ "${#files[@]}" -eq 0 ]; then
        echo "error: no successful runs to summarise" >&2
        exit 4
    fi

    local summary="$out_dir/keeblock-perf-battery-${ts}.json"
    write_battery_summary "$summary" "${files[@]}"
    echo
    echo "==> battery summary: $summary"
    cat "$summary"
}

if [ "${1:-}" = "--battery" ]; then
    run_battery "${2:-$TMP}"
else
    SUITE="${1:?suite required (burst|savestorm|mousekeymix) or --battery}"
    MODE="${2:-A}"
    DEFAULT_OUTPUT="$TMP/keeblock-perf.json"
    OUTPUT="${3:-$DEFAULT_OUTPUT}"
    run_single "$SUITE" "$MODE" "$OUTPUT"
fi
