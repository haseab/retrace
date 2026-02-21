#!/bin/bash

# Build and run Retrace in DEBUG mode with hot reloading support
# Usage: ./dev.sh

set -e

BUILDINFO_FILE="UI/BuildInfo.swift"
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
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "⚠️  Working tree is dirty.  The build will embed the HEAD commit hash,"
    echo "   but your uncommitted changes won't be reflected in that hash."
    echo ""
    echo "   Uncommitted changes:"
    git diff --stat
    echo ""
    read -p "   Continue anyway? [y/N] " answer
    case "$answer" in
        [yY]*) echo "   Proceeding with dirty tree..." ;;
        *)     echo "   Aborting. Commit your changes first, then rebuild."; exit 1 ;;
    esac
fi

# ---------------------------------------------------------------------------
# Inject build metadata into BuildInfo.swift
# ---------------------------------------------------------------------------
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
FORK_NAME=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github.com/||; s|\.git$||' || echo "")

cp "$BUILDINFO_FILE" "$BUILDINFO_FILE.bak"

sed -i '' \
    -e "s|static let version = \".*\"|static let version = \"$MARKETING_VERSION\"|" \
    -e "s|static let buildNumber = \".*\"|static let buildNumber = \"$BUILD_NUMBER\"|" \
    -e "s|static let gitCommit = \".*\"|static let gitCommit = \"$GIT_COMMIT\"|" \
    -e "s|static let gitCommitFull = \".*\"|static let gitCommitFull = \"$GIT_COMMIT_FULL\"|" \
    -e "s|static let gitBranch = \".*\"|static let gitBranch = \"$GIT_BRANCH\"|" \
    -e "s|static let buildDate = \".*\"|static let buildDate = \"$BUILD_DATE\"|" \
    -e "s|static let buildConfig = \".*\"|static let buildConfig = \"$BUILD_CONFIG\"|" \
    -e "s|static let isDevBuild = .*|static let isDevBuild = true|" \
    -e "s|static let forkName = \".*\"|static let forkName = \"$FORK_NAME\"|" \
    "$BUILDINFO_FILE"

restore_buildinfo() {
    if [ -f "$BUILDINFO_FILE.bak" ]; then
        mv "$BUILDINFO_FILE.bak" "$BUILDINFO_FILE"
    fi
}
trap restore_buildinfo EXIT

echo "🔨 Building Retrace v${MARKETING_VERSION} (DEBUG)..."
echo "   commit: ${GIT_COMMIT} (${GIT_BRANCH})"
swift build -c debug

echo ""
echo "🚀 Starting Retrace..."
echo ""

# Run the executable directly for hot reload support
.build/debug/Retrace
