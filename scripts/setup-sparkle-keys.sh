#!/bin/bash
# =============================================================================
# Sparkle Key Generation Script
# =============================================================================
# This script generates the EdDSA key pair needed for Sparkle auto-updates.
# Run this ONCE when setting up auto-updates for the first time.
#
# The private key is stored in your macOS Keychain (secure).
# The public key is printed - you need to add it to Info.plist.
# =============================================================================

set -e

echo "================================================"
echo "  Sparkle EdDSA Key Generation"
echo "================================================"
echo ""

# Find Sparkle's generate_keys tool
SPARKLE_BIN=""

# Check common locations
LOCATIONS=(
    "./DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
    "../DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
    "~/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/generate_keys"
)

for loc in "${LOCATIONS[@]}"; do
    expanded=$(eval echo "$loc" 2>/dev/null | head -1)
    if [ -f "$expanded" ]; then
        SPARKLE_BIN="$expanded"
        break
    fi
done

# If not found, try to find it
if [ -z "$SPARKLE_BIN" ]; then
    echo "Looking for Sparkle's generate_keys tool..."
    SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -path "*/Sparkle/*" 2>/dev/null | head -1)
fi

if [ -z "$SPARKLE_BIN" ] || [ ! -f "$SPARKLE_BIN" ]; then
    echo "ERROR: Could not find Sparkle's generate_keys tool."
    echo ""
    echo "Please build the project first in Xcode to download Sparkle,"
    echo "then run this script again."
    echo ""
    echo "Alternatively, download Sparkle manually from:"
    echo "  https://github.com/sparkle-project/Sparkle/releases"
    echo ""
    echo "And run: ./Sparkle.framework/bin/generate_keys"
    exit 1
fi

echo "Found Sparkle tools at: $SPARKLE_BIN"
echo ""
echo "This will generate a new EdDSA key pair."
echo "The PRIVATE key will be stored securely in your macOS Keychain."
echo "The PUBLIC key will be displayed - copy it to Info.plist."
echo ""
read -p "Press Enter to continue (or Ctrl+C to cancel)..."
echo ""

# Run the key generator
"$SPARKLE_BIN"

echo ""
echo "================================================"
echo "  NEXT STEPS"
echo "================================================"
echo ""
echo "1. Copy the PUBLIC key shown above"
echo ""
echo "2. Open UI/Info.plist and replace:"
echo "   REPLACE_WITH_YOUR_EDDSA_PUBLIC_KEY"
echo "   with your actual public key"
echo ""
echo "3. The private key is now in your Keychain."
echo "   It will be used automatically when signing updates."
echo ""
echo "IMPORTANT: If you need to sign updates on another machine,"
echo "you'll need to export the private key from Keychain Access."
echo ""
