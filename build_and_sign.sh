#!/bin/bash

# Build and package Retrace as a proper .app bundle
# This allows macOS to properly identify the app for permissions

set -e  # Exit on error

APP_NAME="Retrace"
BUNDLE_ID="io.retrace.app"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🔨 Building Retrace..."
./scripts/check_no_nanoseconds_sleep.sh
swift build -c release

echo "📦 Creating app bundle..."

# Create app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$BUILD_DIR/Retrace" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "UI/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "✍️  Signing app bundle..."

# Sign the app bundle with ad-hoc signature and entitlements
codesign --force --deep --sign - --entitlements "UI/Retrace.entitlements" "$APP_BUNDLE"

echo "✅ Build complete!"
echo ""
echo "📍 App bundle location: $APP_BUNDLE"
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
