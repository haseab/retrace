#!/bin/bash

# Build and package Retrace as a proper .app bundle
# This allows macOS to properly identify the app for permissions

set -e  # Exit on error

APP_NAME="Retrace"
BUNDLE_ID="io.retrace.app"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BUILD_CONFIG="release"

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
# Require a clean working tree so the embedded commit hash is accurate
# ---------------------------------------------------------------------------
if [ -n "$(git diff --name-only HEAD 2>/dev/null)" ]; then
    echo "INFO: Building with local uncommitted changes."
    echo "      Build metadata will use HEAD commit (local diff is not encoded)."
    echo "      Local changes:"
    git diff --stat
fi

# ---------------------------------------------------------------------------
# Collect build metadata (embedded into generated Info.plist)
# ---------------------------------------------------------------------------
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Detect fork name from the origin remote (e.g. "aculich/retrace")
REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
FORK_NAME=$(printf "%s" "$REMOTE_URL" | sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$##')

echo "🔨 Building Retrace..."
./scripts/check_no_nanoseconds_sleep.sh
echo "🔨 Building Retrace v${MARKETING_VERSION} (${BUILD_CONFIG})..."
echo "   commit: ${GIT_COMMIT} (${GIT_BRANCH})"
./scripts/check_no_nanoseconds_sleep.sh
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

set_plist_string() {
    local key="$1"
    local value="$2"
    /usr/libexec/PlistBuddy -c "Set :$key \"$value\"" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :$key string \"$value\"" "$APP_BUNDLE/Contents/Info.plist"
}

set_plist_bool() {
    local key="$1"
    local value="$2"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :$key bool $value" "$APP_BUNDLE/Contents/Info.plist"
}

set_plist_string "RetraceVersion" "$MARKETING_VERSION"
set_plist_string "RetraceBuildNumber" "$BUILD_NUMBER"
set_plist_string "RetraceGitCommit" "$GIT_COMMIT"
set_plist_string "RetraceGitCommitFull" "$GIT_COMMIT_FULL"
set_plist_string "RetraceGitBranch" "$GIT_BRANCH"
set_plist_string "RetraceBuildDate" "$BUILD_DATE"
set_plist_string "RetraceBuildConfig" "$BUILD_CONFIG"
set_plist_bool "RetraceIsDevBuild" "true"
set_plist_string "RetraceForkName" "$FORK_NAME"

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
