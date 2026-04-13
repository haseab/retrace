#!/bin/bash

# Build and run Retrace in DEBUG mode with hot reloading support
# Usage: ./dev.sh

set -e

BUILD_CONFIG="debug"

# ---------------------------------------------------------------------------
# Parse version metadata from project.yml
# ---------------------------------------------------------------------------
MARKETING_VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
BUILD_NUMBER=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
: "${MARKETING_VERSION:=0.0.0}"
: "${BUILD_NUMBER:=0}"

# ---------------------------------------------------------------------------
# Collect build metadata for standalone SwiftPM dev runs
# ---------------------------------------------------------------------------
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
FORK_NAME=$(printf "%s" "$REMOTE_URL" | sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$##')

echo "🔨 Building Retrace v${MARKETING_VERSION} (DEBUG)..."
echo "   commit: ${GIT_COMMIT} (${GIT_BRANCH})"
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
RETRACE_VERSION="$MARKETING_VERSION" \
RETRACE_BUILD_NUMBER="$BUILD_NUMBER" \
RETRACE_GIT_COMMIT="$GIT_COMMIT" \
RETRACE_GIT_COMMIT_FULL="$GIT_COMMIT_FULL" \
RETRACE_GIT_BRANCH="$GIT_BRANCH" \
RETRACE_BUILD_DATE="$BUILD_DATE" \
RETRACE_BUILD_CONFIG="$BUILD_CONFIG" \
RETRACE_IS_DEV_BUILD="true" \
RETRACE_FORK_NAME="$FORK_NAME" \
.build/debug/Retrace
