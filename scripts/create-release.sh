#!/bin/bash
# =============================================================================
# Retrace Release Script
# =============================================================================
# This script automates the release process:
# 1. Builds the app (Release configuration)
# 2. Creates a signed ZIP
# 3. Generates the signature for Sparkle
# 4. Updates the appcast.xml
# 5. Outputs instructions for uploading
#
# Usage: ./scripts/create-release.sh [version]
# Example: ./scripts/create-release.sh 1.0.1
# =============================================================================

set -e

# Configuration
APP_NAME="Retrace"
BUNDLE_ID="io.retrace.app"
BUILD_DIR="build/Release"
RELEASES_DIR="releases"
APPCAST_FILE="appcast.xml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}  Retrace Release Builder${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# Get version from argument or prompt
VERSION="$1"
if [ -z "$VERSION" ]; then
    # Try to get from project.yml
    CURRENT_VERSION=$(grep "MARKETING_VERSION" project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
    echo -e "Current version in project.yml: ${YELLOW}${CURRENT_VERSION}${NC}"
    read -p "Enter new version number (e.g., 1.0.1): " VERSION
fi

if [ -z "$VERSION" ]; then
    echo -e "${RED}ERROR: Version number is required${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}Building version: ${VERSION}${NC}"
echo ""

# Create releases directory
mkdir -p "$RELEASES_DIR"

# Step 1: Update version in project.yml
echo -e "${YELLOW}Step 1: Updating version in project.yml...${NC}"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"${VERSION}\"/" project.yml
echo "  Updated MARKETING_VERSION to ${VERSION}"

# Step 2: Generate Xcode project
echo ""
echo -e "${YELLOW}Step 2: Generating Xcode project...${NC}"
if command -v xcodegen &> /dev/null; then
    xcodegen generate
    echo "  Xcode project generated"
else
    echo -e "${RED}  ERROR: xcodegen not found. Install with: brew install xcodegen${NC}"
    exit 1
fi

# Step 3: Archive the app
echo ""
echo -e "${YELLOW}Step 3: Archiving...${NC}"
ARCHIVE_PATH="build/${APP_NAME}.xcarchive"
rm -rf "$ARCHIVE_PATH"

xcodebuild -project Retrace.xcodeproj \
    -scheme Retrace \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    clean archive \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    | xcbeautify || xcodebuild -project Retrace.xcodeproj \
    -scheme Retrace \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    clean archive \
    CODE_SIGN_IDENTITY="Developer ID Application"

if [ ! -d "$ARCHIVE_PATH" ]; then
    echo -e "${RED}ERROR: Archive failed${NC}"
    exit 1
fi

echo -e "${GREEN}  Archive successful!${NC}"

# Step 4: Export the app
echo ""
echo -e "${YELLOW}Step 4: Exporting...${NC}"

# Create export options plist
EXPORT_OPTIONS_PATH="build/ExportOptions.plist"
cat > "$EXPORT_OPTIONS_PATH" << 'EXPORTPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>5X5W7C3L9D</string>
</dict>
</plist>
EXPORTPLIST

EXPORT_PATH="build/Build/Products/Release"
rm -rf "$EXPORT_PATH"
mkdir -p "$EXPORT_PATH"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PATH" \
    | xcbeautify || xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PATH"

APP_PATH="$EXPORT_PATH/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}ERROR: Export failed - app not found at ${APP_PATH}${NC}"
    exit 1
fi

echo -e "${GREEN}  Export successful!${NC}"

# Summary
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Release ${VERSION} Built!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "  App: ${APP_PATH}"
echo ""
echo -e "${YELLOW}NEXT STEP:${NC}"
echo ""
echo "  Run: ./scripts/create-dmg.sh ${VERSION}"
echo ""
