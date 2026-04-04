#!/bin/bash

# Build and run Retrace in DEBUG mode with hot reloading support
# Usage: ./dev.sh

set -e

echo "🔨 Building Retrace (DEBUG)..."
swift build -c debug

echo ""
echo "🚀 Starting Retrace..."
echo ""

# Convenience preflight for local dev: if another instance currently holds the
# app's single-instance lock, skip launching a duplicate and return the shell.
LOCK_PATH="/tmp/io.retrace.app.instance.lock"
if perl -MFcntl=':DEFAULT,:flock' -e '
my $path = shift;
sysopen(my $fh, $path, O_RDWR | O_CREAT) or exit 2;
exit(flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1);
' "$LOCK_PATH"; then
    LOCK_CHECK_STATUS=0
else
    LOCK_CHECK_STATUS=$?
fi

if [ "$LOCK_CHECK_STATUS" -eq 1 ]; then
    echo "ℹ️ Another Retrace instance is already running; skipping duplicate launch."
    exit 0
fi

# Run the executable directly for hot reload support
.build/debug/Retrace
