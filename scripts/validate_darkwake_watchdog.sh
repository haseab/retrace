#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
APP_NAME="${APP_NAME:-Retrace}"
CYCLES="${1:-1}"
SLEEP_MINUTES="${2:-2}"
POST_WAKE_SECONDS="${3:-90}"
APP_LOG_PATH="${APP_LOG_PATH:-$HOME/Library/Logs/Retrace/retrace.log}"
CRASH_DIR="${CRASH_DIR:-$HOME/Library/Logs/DiagnosticReports}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp}"

if [[ "${CYCLES}" == "--help" || "${CYCLES}" == "-h" ]]; then
    cat <<EOF
Usage: ${SCRIPT_NAME} [cycles] [sleep_minutes] [post_wake_seconds]

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} 3 2 90

Environment overrides:
  APP_NAME        Default: Retrace
  APP_LOG_PATH    Default: ~/Library/Logs/Retrace/retrace.log
  ARTIFACT_DIR    Default: /tmp
EOF
    exit 0
fi

is_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

if ! is_positive_int "$CYCLES"; then
    echo "ERROR: cycles must be a positive integer."
    exit 1
fi

if ! is_positive_int "$SLEEP_MINUTES"; then
    echo "ERROR: sleep_minutes must be a positive integer."
    exit 1
fi

if ! is_positive_int "$POST_WAKE_SECONDS"; then
    echo "ERROR: post_wake_seconds must be a positive integer."
    exit 1
fi

for cmd in pmset rg sudo pgrep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd"
        exit 1
    fi
done

START_TS_UTC="$(date -u '+%Y-%m-%d %H:%M:%S')"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')"
ARTIFACT_PATH="${ARTIFACT_DIR%/}/darkwake-watchdog-${RUN_ID}.txt"
APP_LOG_DELTA="${ARTIFACT_DIR%/}/darkwake-watchdog-app-log-${RUN_ID}.txt"
PMSET_LOG_CAPTURE="${ARTIFACT_DIR%/}/darkwake-watchdog-pmset-${RUN_ID}.txt"
UNIFIED_LOG_CAPTURE="${ARTIFACT_DIR%/}/darkwake-watchdog-unified-${RUN_ID}.txt"

mkdir -p "$ARTIFACT_DIR"
: >"$ARTIFACT_PATH"

log() {
    printf '%s\n' "$*" | tee -a "$ARTIFACT_PATH"
}

log "============================================================"
log "Darkwake Watchdog Validation"
log "App: ${APP_NAME}"
log "Cycles: ${CYCLES}"
log "Sleep minutes per cycle: ${SLEEP_MINUTES}"
log "Post-wake observe seconds: ${POST_WAKE_SECONDS}"
log "Start (UTC): ${START_TS_UTC}"
log "Artifact: ${ARTIFACT_PATH}"
log "============================================================"

if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    log "WARNING: No '${APP_NAME}' process found right now. The run will continue."
fi

if [ -f "$APP_LOG_PATH" ]; then
    APP_LOG_BASELINE_LINES="$(wc -l <"$APP_LOG_PATH" | tr -d ' ')"
else
    APP_LOG_BASELINE_LINES=0
fi

log "Requesting sudo for pmset sleep/wake control..."
sudo -v

# Keep sudo alive while the test runs.
while true; do
    sudo -n true >/dev/null 2>&1 || break
    sleep 30
done &
SUDO_KEEPALIVE_PID=$!

cleanup() {
    if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then
        kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

app_died=0
darkwake_cycle_count=0
missing_darkwake_cycles=0

for i in $(seq 1 "$CYCLES"); do
    cycle_start_local="$(date '+%Y-%m-%d %H:%M:%S')"
    wake_local="$(date -v+"${SLEEP_MINUTES}"M '+%m/%d/%y %H:%M:%S')"
    wake_human="$(date -j -f '%m/%d/%y %H:%M:%S' "$wake_local" '+%Y-%m-%d %H:%M:%S %Z')"

    log ""
    log "Cycle ${i}/${CYCLES}: scheduling wake at ${wake_human}"
    sudo pmset schedule wake "$wake_local" >>"$ARTIFACT_PATH" 2>&1

    log "Cycle ${i}/${CYCLES}: sleeping now..."
    sudo pmset sleepnow >>"$ARTIFACT_PATH" 2>&1

    command_returned_at="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    log "Cycle ${i}/${CYCLES}: sleep command returned at ${command_returned_at}"
    log "Cycle ${i}/${CYCLES}: observing for ${POST_WAKE_SECONDS}s..."
    sleep "$POST_WAKE_SECONDS"

    cycle_power_events="$(
        pmset -g log \
        | awk -v start="$cycle_start_local" 'substr($0, 1, 19) >= start' \
        | rg -i 'Sleep\\s+Entering Sleep state|DarkWake|Wake\\s' \
        | tail -n 30 || true
    )"

    if [ -n "$cycle_power_events" ]; then
        log "Cycle ${i}/${CYCLES}: power events since cycle start:"
        log "$cycle_power_events"
    else
        log "Cycle ${i}/${CYCLES}: no matching power events found in pmset slice."
    fi

    if printf '%s' "$cycle_power_events" | rg -qi 'DarkWake'; then
        darkwake_cycle_count=$((darkwake_cycle_count + 1))
        log "Cycle ${i}/${CYCLES}: DarkWake detected."
    else
        missing_darkwake_cycles=$((missing_darkwake_cycles + 1))
        log "Cycle ${i}/${CYCLES}: WARNING - no DarkWake detected in cycle logs."
    fi

    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        log "FAILED: ${APP_NAME} is not running after cycle ${i}."
        app_died=1
        break
    fi

    log "Cycle ${i}/${CYCLES}: ${APP_NAME} is still running."
done

if [ -f "$APP_LOG_PATH" ]; then
    current_lines="$(wc -l <"$APP_LOG_PATH" | tr -d ' ')"
    if [ "$current_lines" -ge "$APP_LOG_BASELINE_LINES" ]; then
        start_line=$((APP_LOG_BASELINE_LINES + 1))
        sed -n "${start_line},${current_lines}p" "$APP_LOG_PATH" >"$APP_LOG_DELTA"
    else
        # Log rotation/truncation fallback.
        cp "$APP_LOG_PATH" "$APP_LOG_DELTA"
    fi
else
    : >"$APP_LOG_DELTA"
fi

pmset -g log | rg -i 'darkwake|wake reason|wake|sleep|maintenance' | tail -n 400 >"$PMSET_LOG_CAPTURE" || true
/usr/bin/log show --style compact --start "$START_TS_UTC" --predicate "process == \"${APP_NAME}\"" >"$UNIFIED_LOG_CAPTURE" 2>/dev/null || true

CRASH_MATCHES="$(
    find "$CRASH_DIR" -type f \
        \( -name "${APP_NAME}*.crash" -o -name "${APP_NAME}*.ips" \) \
        -newermt "$START_TS_UTC" 2>/dev/null || true
)"

AUTO_QUIT_MATCHES_FILE="$(rg -n 'watchdog_auto_quit\\b|Auto-quit threshold reached|Relaunch did not complete after auto-quit trigger' "$APP_LOG_DELTA" || true)"
AUTO_QUIT_MATCHES_UNIFIED="$(rg -n 'watchdog_auto_quit\\b|Auto-quit threshold reached|Relaunch did not complete after auto-quit trigger' "$UNIFIED_LOG_CAPTURE" || true)"
SUPPRESSION_MATCHES="$(rg -n 'watchdog_auto_quit_suppressed_no_display|Auto-quit suppressed: active displays are 0|Auto-quit suspended|Auto-quit resumed' "$APP_LOG_DELTA" || true)"

fail_count=0

log ""
log "-------------------- Result Summary --------------------"

if [ "$app_died" -eq 1 ]; then
    log "FAIL: ${APP_NAME} process was not running after a wake cycle."
    fail_count=$((fail_count + 1))
else
    log "PASS: ${APP_NAME} stayed running after all cycles."
fi

if [ "$darkwake_cycle_count" -gt 0 ]; then
    log "PASS: DarkWake observed in ${darkwake_cycle_count}/${CYCLES} cycles."
else
    log "FAIL: No DarkWake observed in any cycle."
    fail_count=$((fail_count + 1))
fi

if [ "$missing_darkwake_cycles" -gt 0 ]; then
    log "INFO: ${missing_darkwake_cycles}/${CYCLES} cycles had no DarkWake marker."
fi

if [ -n "$CRASH_MATCHES" ]; then
    log "FAIL: Crash reports found since start:"
    log "$CRASH_MATCHES"
    fail_count=$((fail_count + 1))
else
    log "PASS: No new crash reports found."
fi

if [ -n "$AUTO_QUIT_MATCHES_FILE" ] || [ -n "$AUTO_QUIT_MATCHES_UNIFIED" ]; then
    log "FAIL: Detected watchdog auto-quit signals."
    if [ -n "$AUTO_QUIT_MATCHES_FILE" ]; then
        log "App log matches:"
        log "$AUTO_QUIT_MATCHES_FILE"
    fi
    if [ -n "$AUTO_QUIT_MATCHES_UNIFIED" ]; then
        log "Unified log matches:"
        log "$AUTO_QUIT_MATCHES_UNIFIED"
    fi
    fail_count=$((fail_count + 1))
else
    log "PASS: No watchdog auto-quit signals found."
fi

if [ -n "$SUPPRESSION_MATCHES" ]; then
    log "INFO: Suppression markers seen (expected during darkwake/display-off):"
    log "$SUPPRESSION_MATCHES"
else
    log "INFO: No suppression markers seen in app log delta."
fi

log ""
log "Artifacts:"
log "  Main summary: ${ARTIFACT_PATH}"
log "  App log delta: ${APP_LOG_DELTA}"
log "  pmset log slice: ${PMSET_LOG_CAPTURE}"
log "  unified log slice: ${UNIFIED_LOG_CAPTURE}"

if [ "$fail_count" -eq 0 ]; then
    log "RESULT: PASS"
    exit 0
fi

log "RESULT: FAIL (${fail_count} failing checks)"
exit 1
