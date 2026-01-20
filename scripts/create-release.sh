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

# Step 3: Build the app
echo ""
echo -e "${YELLOW}Step 3: Building Release configuration...${NC}"
xcodebuild -project Retrace.xcodeproj \
    -scheme Retrace \
    -configuration Release \
    -derivedDataPath build \
    clean build \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    | xcbeautify || xcodebuild -project Retrace.xcodeproj \
    -scheme Retrace \
    -configuration Release \
    -derivedDataPath build \
    clean build \
    CODE_SIGN_IDENTITY="Developer ID Application"

APP_PATH="build/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}ERROR: Build failed - app not found at ${APP_PATH}${NC}"
    exit 1
fi

echo -e "${GREEN}  Build successful!${NC}"

# Step 4: Notarize (optional but recommended)
echo ""
echo -e "${YELLOW}Step 4: Notarization${NC}"
echo "  Skipping notarization in this script."
echo "  For production releases, notarize with:"
echo "    xcrun notarytool submit ${APP_NAME}.zip --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password YOUR_APP_SPECIFIC_PASSWORD"

# Step 5: Create ZIP
echo ""
echo -e "${YELLOW}Step 5: Creating ZIP archive...${NC}"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
ZIP_PATH="${RELEASES_DIR}/${ZIP_NAME}"

cd "build/Build/Products/Release"
zip -r -y "../../../../${ZIP_PATH}" "${APP_NAME}.app"
cd "../../../.."

ZIP_SIZE=$(stat -f%z "$ZIP_PATH")
echo "  Created: ${ZIP_PATH}"
echo "  Size: ${ZIP_SIZE} bytes"

# Step 6: Sign the ZIP with Sparkle
echo ""
echo -e "${YELLOW}Step 6: Signing with Sparkle...${NC}"

# Find sign_update tool
SIGN_UPDATE=""
LOCATIONS=(
    "./build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
    "~/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
)

for loc in "${LOCATIONS[@]}"; do
    expanded=$(eval echo "$loc" 2>/dev/null | head -1)
    if [ -f "$expanded" ]; then
        SIGN_UPDATE="$expanded"
        break
    fi
done

if [ -z "$SIGN_UPDATE" ]; then
    SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -path "*/Sparkle/*" 2>/dev/null | head -1)
fi

if [ -z "$SIGN_UPDATE" ] || [ ! -f "$SIGN_UPDATE" ]; then
    echo -e "${RED}  ERROR: Could not find Sparkle's sign_update tool${NC}"
    echo "  Run this after building in Xcode at least once"
    SIGNATURE="GENERATE_SIGNATURE_MANUALLY"
else
    SIGNATURE=$("$SIGN_UPDATE" "$ZIP_PATH" 2>&1 | grep "sparkle:edSignature" | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')
    if [ -z "$SIGNATURE" ]; then
        # Try alternative output format
        SIGNATURE=$("$SIGN_UPDATE" "$ZIP_PATH" 2>&1 | tail -1)
    fi
    echo "  Signature: ${SIGNATURE:0:40}..."
fi

# Step 7: Create/Update appcast.xml
echo ""
echo -e "${YELLOW}Step 7: Updating appcast.xml...${NC}"

# Get current date in RFC 822 format
PUB_DATE=$(date -R)

# Build number (increment from current)
BUILD_NUMBER=$(grep "CURRENT_PROJECT_VERSION" project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
NEW_BUILD=$((BUILD_NUMBER + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"/" project.yml

# Create new item entry
NEW_ITEM="        <item>
            <title>Version ${VERSION}</title>
            <sparkle:version>${NEW_BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:releaseNotesLink>https://retrace.io/releases/${VERSION}.html</sparkle:releaseNotesLink>
            <pubDate>${PUB_DATE}</pubDate>
            <enclosure
                url=\"https://retrace.io/downloads/${ZIP_NAME}\"
                sparkle:edSignature=\"${SIGNATURE}\"
                length=\"${ZIP_SIZE}\"
                type=\"application/octet-stream\"/>
        </item>"

if [ -f "$APPCAST_FILE" ]; then
    # Insert new item after <channel> opening tags (before first <item> or before </channel>)
    # This is a simplified approach - for production, use a proper XML tool
    cp "$APPCAST_FILE" "${APPCAST_FILE}.backup"

    # Use awk to insert after the description/link lines
    awk -v new_item="$NEW_ITEM" '
        /<\/link>/ { print; print ""; print new_item; next }
        { print }
    ' "${APPCAST_FILE}.backup" > "$APPCAST_FILE"

    echo "  Updated ${APPCAST_FILE}"
else
    echo "  appcast.xml not found - see releases/appcast-template.xml"
fi

# Step 8: Create release notes template
echo ""
echo -e "${YELLOW}Step 8: Creating release notes template...${NC}"
RELEASE_NOTES_FILE="${RELEASES_DIR}/${VERSION}.html"
cat > "$RELEASE_NOTES_FILE" << EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            font-size: 13px;
            line-height: 1.5;
            color: #333;
            padding: 10px;
        }
        h2 {
            font-size: 16px;
            margin-bottom: 12px;
            color: #000;
        }
        ul {
            margin: 0;
            padding-left: 20px;
        }
        li {
            margin-bottom: 6px;
        }
        .new { color: #2ecc71; }
        .fix { color: #e74c3c; }
        .improve { color: #3498db; }
    </style>
</head>
<body>
    <h2>What's New in Version ${VERSION}</h2>
    <ul>
        <li><span class="new">New:</span> Your new feature here</li>
        <li><span class="fix">Fix:</span> Bug fix description</li>
        <li><span class="improve">Improved:</span> Performance improvement</li>
    </ul>
</body>
</html>
EOF
echo "  Created: ${RELEASE_NOTES_FILE}"
echo "  Edit this file to add your release notes!"

# Summary
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Release ${VERSION} Prepared!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "Files created:"
echo "  - ${ZIP_PATH}"
echo "  - ${RELEASE_NOTES_FILE}"
echo "  - ${APPCAST_FILE} (updated)"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo ""
echo "1. Edit the release notes:"
echo "   open ${RELEASE_NOTES_FILE}"
echo ""
echo "2. Upload to your server:"
echo "   - ${ZIP_PATH} -> https://retrace.io/downloads/"
echo "   - ${RELEASE_NOTES_FILE} -> https://retrace.io/releases/"
echo "   - ${APPCAST_FILE} -> https://retrace.io/"
echo ""
echo "3. Verify the appcast.xml is accessible:"
echo "   curl https://retrace.io/appcast.xml"
echo ""
echo "4. Test the update by running an older version of the app"
echo ""
