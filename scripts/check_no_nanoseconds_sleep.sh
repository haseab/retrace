#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[check_no_nanoseconds_sleep] Scanning Swift sources for Task.sleep(nanoseconds:)..."

MATCHES="$(rg -n 'Task\.sleep\(nanoseconds:' App Capture Database Migration Processing Storage UI --glob '*.swift' || true)"
if [ -n "$MATCHES" ]; then
    echo "[check_no_nanoseconds_sleep] ERROR: Found disallowed Task.sleep(nanoseconds:) usage."
    echo "$MATCHES"
    echo "[check_no_nanoseconds_sleep] Use Task.sleep(for: ..., clock: .continuous) instead."
    exit 1
fi

echo "[check_no_nanoseconds_sleep] OK: no Task.sleep(nanoseconds:) usages found."
