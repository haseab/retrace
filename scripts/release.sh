#!/bin/bash

# Retrace Release Script
# Usage: ./scripts/release.sh <version> <build_number>
# Example: ./scripts/release.sh 0.5.1 4
#
# Prerequisites:
#   npm install -g wrangler
#   wrangler login

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check arguments
if [ $# -lt 2 ]; then
    echo -e "${RED}Usage: $0 <version> <build_number>${NC}"
    echo "Example: $0 0.5.1 4"
    exit 1
fi

VERSION=$1
BUILD_NUMBER=$2
PROJECT_DIR="/Users/haseab/Desktop/retrace"
FRONTEND_DIR="/Users/haseab/Desktop/retrace-frontend"
DMG_NAME="Retrace-v${VERSION}.dmg"
DMG_PATH="${PROJECT_DIR}/build/${DMG_NAME}"
SPARKLE_SIGN="/Users/haseab/Library/Developer/Xcode/DerivedData/Retrace-geulxxkzgiewidaakescdtxvqmpc/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
R2_BUCKET="retrace"
ENV_FILE="${PROJECT_DIR}/.env"

# Load local environment variables for release credentials.
if [ -f "${ENV_FILE}" ]; then
    set -a
    source "${ENV_FILE}"
    set +a
fi

: "${APPLE_ID:?Missing APPLE_ID. Set it in ${ENV_FILE} or export it in your shell.}"
: "${APPLE_TEAM_ID:?Missing APPLE_TEAM_ID. Set it in ${ENV_FILE} or export it in your shell.}"
: "${APPLE_APP_PASSWORD:?Missing APPLE_APP_PASSWORD. Set it in ${ENV_FILE} or export it in your shell.}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Retrace Release Script v${VERSION}${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${YELLOW}[preflight] Running sleep API guard...${NC}"
"${PROJECT_DIR}/scripts/check_no_nanoseconds_sleep.sh"
echo -e "${GREEN}✓ Sleep API guard passed${NC}"

# Check for wrangler
if ! command -v wrangler &> /dev/null; then
    echo -e "${YELLOW}Warning: wrangler not installed. R2 upload will be skipped.${NC}"
    echo -e "${YELLOW}Install with: npm install -g wrangler && wrangler login${NC}"
    WRANGLER_AVAILABLE=false
else
    WRANGLER_AVAILABLE=true
fi

# Step 1: Update version in project.yml
echo -e "${YELLOW}[1/10] Updating version in project.yml...${NC}"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"${VERSION}\"/" "${PROJECT_DIR}/project.yml"
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"${BUILD_NUMBER}\"/" "${PROJECT_DIR}/project.yml"
echo -e "${GREEN}✓ Updated to version ${VERSION} (build ${BUILD_NUMBER})${NC}"

# Step 2: Regenerate Xcode project
echo -e "${YELLOW}[2/10] Regenerating Xcode project...${NC}"
cd "${PROJECT_DIR}"
xcodegen generate
echo -e "${GREEN}✓ Xcode project regenerated${NC}"

# Step 3: Archive
echo -e "${YELLOW}[3/10] Archiving app (this may take a few minutes)...${NC}"
xcodebuild -scheme Retrace -configuration Release -archivePath build/Retrace.xcarchive archive 2>&1 | grep -E "(ARCHIVE SUCCEEDED|error:)" || true
if [ ! -d "${PROJECT_DIR}/build/Retrace.xcarchive" ]; then
    echo -e "${RED}✗ Archive failed${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Archive succeeded${NC}"

# Step 4: Export
echo -e "${YELLOW}[4/10] Exporting archive...${NC}"
xcodebuild -exportArchive \
    -archivePath "${PROJECT_DIR}/build/Retrace.xcarchive" \
    -exportPath "${PROJECT_DIR}/build/export" \
    -exportOptionsPlist "${PROJECT_DIR}/ExportOptions.plist" 2>&1 | grep -E "(EXPORT SUCCEEDED|error:)" || true
if [ ! -d "${PROJECT_DIR}/build/export/Retrace.app" ]; then
    echo -e "${RED}✗ Export failed${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Export succeeded${NC}"

# Step 5: Create DMG
echo -e "${YELLOW}[5/10] Creating DMG...${NC}"
rm -f "${DMG_PATH}"
create-dmg \
    --volname "Retrace" \
    --volicon "${PROJECT_DIR}/AppIcon.icns" \
    --background "/Users/haseab/Desktop/dmg_background.png" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Retrace.app" 150 185 \
    --hide-extension "Retrace.app" \
    --app-drop-link 450 185 \
    --no-internet-enable \
    "${DMG_PATH}" \
    "${PROJECT_DIR}/build/export/Retrace.app"
echo -e "${GREEN}✓ DMG created${NC}"

# Step 6: Notarize
echo -e "${YELLOW}[6/10] Notarizing DMG (this may take a few minutes)...${NC}"
xcrun notarytool submit "${DMG_PATH}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_PASSWORD}" \
    --wait
echo -e "${GREEN}✓ Notarization complete${NC}"

# Step 7: Staple
echo -e "${YELLOW}[7/10] Stapling notarization...${NC}"
xcrun stapler staple "${DMG_PATH}"
echo -e "${GREEN}✓ Stapled successfully${NC}"

# Step 8: Sign for Sparkle
echo -e "${YELLOW}[8/10] Signing for Sparkle...${NC}"
SPARKLE_OUTPUT=$("${SPARKLE_SIGN}" "${DMG_PATH}")
echo -e "${GREEN}✓ Sparkle signature generated${NC}"

# Extract signature and length
ED_SIGNATURE=$(echo "$SPARKLE_OUTPUT" | sed 's/.*edSignature="\([^"]*\)".*/\1/')
LENGTH=$(echo "$SPARKLE_OUTPUT" | sed 's/.*length="\([^"]*\)".*/\1/')

# Copy to Desktop
cp "${DMG_PATH}" /Users/haseab/Desktop/
echo -e "${GREEN}✓ DMG copied to Desktop${NC}"

# Step 9: Upload to R2
echo -e "${YELLOW}[9/10] Uploading to R2...${NC}"
if [ "$WRANGLER_AVAILABLE" = true ]; then
    wrangler r2 object put "${R2_BUCKET}/${DMG_NAME}" --file="${DMG_PATH}"
    echo -e "${GREEN}✓ Uploaded to https://cdn.retrace.to/${DMG_NAME}${NC}"
else
    echo -e "${YELLOW}⚠ Skipped (wrangler not installed)${NC}"
    echo -e "${YELLOW}  Manual upload required to R2${NC}"
fi

# Step 10: Update frontend
echo -e "${YELLOW}[10/10] Updating frontend...${NC}"
sed -i '' "s|https://cdn.retrace.to/Retrace-v[^\"]*\.dmg|https://cdn.retrace.to/${DMG_NAME}|g" "${FRONTEND_DIR}/src/lib/track-download.ts"
sed -i '' "s/version: \"[^\"]*\"/version: \"${VERSION}\"/" "${FRONTEND_DIR}/src/lib/track-download.ts"
echo -e "${GREEN}✓ Frontend download URL updated${NC}"

# Generate appcast entry
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
APPCAST_ENTRY="        <item>
            <title>Version ${VERSION}</title>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <pubDate>${PUBDATE}</pubDate>
            <description><![CDATA[
<h2>What's New</h2>
<ul>
  <li><strong>Feature:</strong> Description here</li>
</ul>
]]></description>
            <enclosure
                url=\"https://cdn.retrace.to/${DMG_NAME}\"
                sparkle:edSignature=\"${ED_SIGNATURE}\"
                length=\"${LENGTH}\"
                type=\"application/octet-stream\"/>
        </item>"

# Summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  Release ${VERSION} Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "DMG: ${DMG_PATH}"
echo -e "Also copied to: ~/Desktop/${DMG_NAME}"
if [ "$WRANGLER_AVAILABLE" = true ]; then
    echo -e "R2 URL: https://cdn.retrace.to/${DMG_NAME}"
fi
echo ""
echo -e "${YELLOW}Sparkle signature:${NC}"
echo -e "edSignature=\"${ED_SIGNATURE}\""
echo -e "length=\"${LENGTH}\""
echo ""
echo -e "${YELLOW}Add this to appcast.xml (after <!-- Latest version should be first -->):${NC}"
echo ""
echo "$APPCAST_ENTRY"
echo ""
echo -e "${YELLOW}Remaining steps:${NC}"
if [ "$WRANGLER_AVAILABLE" = false ]; then
    echo "1. Upload ${DMG_NAME} to R2 manually"
    echo "2. Add the above <item> to ${FRONTEND_DIR}/public/appcast.xml"
    echo "3. Push frontend: cd ${FRONTEND_DIR} && git add . && git commit -m 'Release v${VERSION}' && git push"
else
    echo "1. Add the above <item> to ${FRONTEND_DIR}/public/appcast.xml"
    echo "2. Push frontend: cd ${FRONTEND_DIR} && git add . && git commit -m 'Release v${VERSION}' && git push"
fi
echo ""
