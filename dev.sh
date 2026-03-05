#!/bin/bash

# Build and run Retrace in DEBUG mode with hot reloading support
# Usage: ./dev.sh

set -e

BUILD_CONFIG="debug"

# ---------------------------------------------------------------------------
# Parse version from project.yml
# ---------------------------------------------------------------------------
MARKETING_VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
BUILD_NUMBER=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
: "${MARKETING_VERSION:=0.0.0}"
: "${BUILD_NUMBER:=0}"

# ---------------------------------------------------------------------------
# Require a clean working tree so the embedded commit hash is accurate
# ---------------------------------------------------------------------------
if [ -n "$(git diff --name-only HEAD 2>/dev/null)" ]; then
    echo "INFO: Building with local uncommitted changes."
    echo "      Build metadata will use HEAD commit (local diff is not encoded)."
    echo "      Local changes:"
    git diff --stat
fi

# ---------------------------------------------------------------------------
# Collect build metadata (passed via environment at launch time)
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
