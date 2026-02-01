#!/bin/bash

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                      RETRACE FRESH INSTALL RESET                             ║
# ║                                                                              ║
# ║  This script resets Retrace to a fresh install state by:                    ║
# ║  • Removing all databases                                                    ║
# ║  • Removing all video segments                                               ║
# ║  • Removing all app preferences                                              ║
# ║  • Resetting permission requests (requires reboot)                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -e  # Exit on error

# Get storage root from app settings or default
source "$(dirname "$0")/_get_storage_root.sh"

BUNDLE_ID="io.retrace.app"
APP_SUPPORT_DIR="$RETRACE_STORAGE_ROOT"
PREFERENCES_DIR="$HOME/Library/Preferences"
CACHES_DIR="$HOME/Library/Caches/$BUNDLE_ID"

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                      RETRACE FRESH INSTALL RESET                             ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Function to remove directory if it exists
remove_dir() {
    local dir=$1
    if [ -d "$dir" ]; then
        echo "🗑️  Removing: $dir"
        rm -rf "$dir"
        echo "   ✓ Removed"
    else
        echo "⏭️  Skip: $dir (doesn't exist)"
    fi
}

# Function to remove file if it exists
remove_file() {
    local file=$1
    if [ -f "$file" ]; then
        echo "🗑️  Removing: $file"
        rm -f "$file"
        echo "   ✓ Removed"
    else
        echo "⏭️  Skip: $file (doesn't exist)"
    fi
}

echo "Step 1: Removing Application Support data"
echo "─────────────────────────────────────────"
remove_dir "$APP_SUPPORT_DIR"
echo ""

echo "Step 2: Removing Preferences"
echo "─────────────────────────────"
remove_file "$PREFERENCES_DIR/$BUNDLE_ID.plist"
remove_file "$PREFERENCES_DIR/io.retrace.app.plist"
echo ""

echo "Step 3: Removing Caches"
echo "───────────────────────"
remove_dir "$CACHES_DIR"
echo ""

echo "Step 4: Clearing defaults database"
echo "───────────────────────────────────"
if defaults read "$BUNDLE_ID" &>/dev/null; then
    echo "🗑️  Removing defaults for $BUNDLE_ID"
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
    echo "   ✓ Removed"
else
    echo "⏭️  Skip: No defaults found"
fi
echo ""

echo "Step 5: Permission Reset Instructions"
echo "─────────────────────────────────────"
echo "⚠️  To reset Screen Recording and Accessibility permissions:"
echo ""
echo "   Option A: Manual Reset (Immediate)"
echo "   ─────────────────────────────────"
echo "   1. Open System Settings → Privacy & Security"
echo "   2. Go to 'Screen Recording' → Remove Retrace if listed"
echo "   3. Go to 'Accessibility' → Remove Retrace if listed"
echo ""
echo "   Option B: TCC Database Reset (Nuclear Option)"
echo "   ─────────────────────────────────────────────"
echo "   Run this command (requires admin password):"
echo "   $ tccutil reset ScreenCapture $BUNDLE_ID"
echo "   $ tccutil reset Accessibility $BUNDLE_ID"
echo ""
echo "   Option C: Full System Reset (Most Complete)"
echo "   ───────────────────────────────────────────"
echo "   Run: sudo tccutil reset All"
echo "   ⚠️  This resets ALL app permissions system-wide!"
echo ""

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "✅ Reset Complete!"
echo ""
echo "Next steps:"
echo "  1. Restart Xcode (Cmd+Q then reopen)"
echo "  2. Clean build folder (Cmd+Shift+K in Xcode)"
echo "  3. Run the app - it will prompt for permissions again"
echo "═══════════════════════════════════════════════════════════════════════════════"
