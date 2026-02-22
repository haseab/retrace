#!/bin/bash

set -euo pipefail

APP_NAME="${APP_NAME:-Retrace}"
CYCLES="${1:-5}"

if ! [[ "$CYCLES" =~ ^[0-9]+$ ]] || [ "$CYCLES" -le 0 ]; then
    echo "Usage: $0 [cycles]"
    echo "Example: $0 5"
    exit 1
fi

START_TS="$(date -u '+%Y-%m-%d %H:%M:%S')"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"

echo "============================================================"
echo "Sleep/Wake Stability Validation"
echo "App: ${APP_NAME}"
echo "Cycles: ${CYCLES}"
echo "Start (UTC): ${START_TS}"
echo "============================================================"
echo ""
echo "Runbook:"
echo "1. Ensure ${APP_NAME} is running and actively capturing."
echo "2. For each cycle, put the Mac to sleep and wake it."
echo "3. After wake, verify ${APP_NAME} is responsive, then press Enter."
echo ""

for i in $(seq 1 "$CYCLES"); do
    echo "Cycle ${i}/${CYCLES}: sleep + wake, then press Enter to continue."
    read -r _
done

echo ""
echo "Checking crash reports generated since ${START_TS}..."

CRASH_MATCHES="$(
    find "$CRASH_DIR" -type f \
        \( -name "${APP_NAME}*.crash" -o -name "${APP_NAME}*.ips" \) \
        -newermt "$START_TS" 2>/dev/null || true
)"

if [ -n "$CRASH_MATCHES" ]; then
    echo "FAILED: Found crash reports after soak window:"
    echo "$CRASH_MATCHES"
    exit 1
fi

echo "No crash reports found."
echo "Checking unified logs for known crash signatures..."

LOG_MATCHES="$(
    /usr/bin/log show --style compact --start "$START_TS" --predicate "process == \"${APP_NAME}\"" 2>/dev/null \
    | rg -n 'EXC_BREAKPOINT|Task\\.onSleepWake|fatal error|precondition failed' || true
)"

if [ -n "$LOG_MATCHES" ]; then
    echo "FAILED: Found suspicious crash/hang signatures in unified logs:"
    echo "$LOG_MATCHES"
    exit 1
fi

echo "PASS: No crash reports or known crash signatures detected for ${APP_NAME}."
