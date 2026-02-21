#!/bin/bash

# Build and package Retrace as a proper .app bundle
# This allows macOS to properly identify the app for permissions

set -e  # Exit on error

APP_NAME="Retrace"
BUNDLE_ID="io.retrace.app"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BUILD_CONFIG="release"
BUILDINFO_FILE="UI/BuildInfo.swift"

# ---------------------------------------------------------------------------
# Parse version from project.yml (single source of truth)
# ---------------------------------------------------------------------------
MARKETING_VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
BUILD_NUMBER=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')

if [ -z "$MARKETING_VERSION" ]; then
    echo "⚠️  Could not parse MARKETING_VERSION from project.yml, using default"
    MARKETING_VERSION="0.0.0"
fi
if [ -z "$BUILD_NUMBER" ]; then
    BUILD_NUMBER="0"
fi

# ---------------------------------------------------------------------------
# Inject build metadata into BuildInfo.swift
# ---------------------------------------------------------------------------
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Detect fork name from the origin remote (e.g. "aculich/retrace")
FORK_NAME=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github.com/||; s|\.git$||' || echo "")

# Back up the defaults so we can restore after build
cp "$BUILDINFO_FILE" "$BUILDINFO_FILE.bak"

# SPM builds via this script are always dev builds (official releases use
# create-release.sh which goes through xcodebuild archive).
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

# Ensure defaults are restored even if the build fails
restore_buildinfo() {
    if [ -f "$BUILDINFO_FILE.bak" ]; then
        mv "$BUILDINFO_FILE.bak" "$BUILDINFO_FILE"
    fi
}
trap restore_buildinfo EXIT

echo "🔨 Building Retrace v${MARKETING_VERSION} (${BUILD_CONFIG})..."
echo "   commit: ${GIT_COMMIT} (${GIT_BRANCH})"
swift build -c release

echo "📦 Creating app bundle..."

# Create app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Copy executable
cp "$BUILD_DIR/Retrace" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Add rpath so the app finds embedded frameworks when run from .app bundle
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Copy embedded frameworks (Sparkle and any others the app links to)
for fw in Sparkle; do
    if [ -d "$BUILD_DIR/$fw.framework" ]; then
        cp -R "$BUILD_DIR/$fw.framework" "$APP_BUNDLE/Contents/Frameworks/"
    fi
done

# Copy Info.plist with variable substitution (fixes $(MARKETING_VERSION) bug)
sed -e "s/\$(MARKETING_VERSION)/$MARKETING_VERSION/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/g" \
    "UI/Info.plist" > "$APP_BUNDLE/Contents/Info.plist"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "✍️  Signing app bundle..."

# Sign frameworks first (required before signing the app)
for fw in "$APP_BUNDLE/Contents/Frameworks/"*.framework; do
    [ -d "$fw" ] && codesign --force --sign - "$fw"
done

# Sign the app bundle with ad-hoc signature and entitlements
codesign --force --deep --sign - --entitlements "UI/Retrace.entitlements" "$APP_BUNDLE"

echo "✅ Build complete!"
echo ""
echo "📍 App bundle location: $APP_BUNDLE"
echo "   Version: $MARKETING_VERSION ($BUILD_NUMBER) · $GIT_COMMIT"
echo ""

# Check if app is already in Applications
if [ -d "/Applications/$APP_NAME.app" ]; then
    echo "📲 Found existing app in /Applications/, updating in place..."
    echo "   This preserves your permissions settings."

    # Kill the app if running
    pkill -x "$APP_NAME" 2>/dev/null || true

    # Replace the app
    rm -rf "/Applications/$APP_NAME.app"
    cp -r "$APP_BUNDLE" /Applications/

    echo "✅ Updated /Applications/$APP_NAME.app"
    echo ""
    echo "To run:"
    echo "  open /Applications/$APP_NAME.app"
else
    echo "💡 For persistent permissions during development, install to /Applications/:"
    echo "   cp -r $APP_BUNDLE /Applications/ && open /Applications/$APP_NAME.app"
    echo ""
    echo "Or run from build directory (permissions reset on each rebuild):"
    echo "   open $APP_BUNDLE"
fi
