#!/bin/bash

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                      RETRACE SAFE ONBOARDING RESET                           ║
# ║                                                                               ║
# ║  This script resets ONLY onboarding state without touching data:             ║
# ║  • Clearing UserDefaults (onboarding state, settings)                        ║
# ║  • Removing Keychain encryption key                                          ║
# ║  • Does NOT delete database or Application Support                           ║
# ║  • Does NOT clear caches                                                     ║
# ║  • Does NOT reset permissions (unless --reset-permissions flag is used)      ║
# ║                                                                               ║
# ║  Usage:                                                                       ║
# ║    ./reset_onboarding_safe.sh                  # Normal reset                 ║
# ║    ./reset_onboarding_safe.sh --reset-permissions  # Also reset permissions   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -e  # Exit on error

# Parse flags
RESET_PERMISSIONS=false
for arg in "$@"; do
    case $arg in
        --reset-permissions)
            RESET_PERMISSIONS=true
            shift
            ;;
    esac
done

BUNDLE_ID="io.retrace.app"
DEFAULTS_DOMAIN="Retrace"  # App uses "Retrace" for UserDefaults.standard
PREFERENCES_DIR="$HOME/Library/Preferences"

# Keychain settings (from DatabaseManager.swift)
KEYCHAIN_SERVICE="com.retrace.database"
KEYCHAIN_ACCOUNT="sqlcipher-key"

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                      RETRACE SAFE ONBOARDING RESET                           ║"
if [ "$RESET_PERMISSIONS" = true ]; then
echo "║                (Preserves data, RESETS permissions)                          ║"
else
echo "║                     (Preserves all data and permissions)                     ║"
fi
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Check if Retrace is running and kill it
echo "Step 0: Checking if Retrace is running..."
echo "─────────────────────────────────────────"
if pgrep -x "Retrace" > /dev/null; then
    echo "⚠️  Retrace is running. Killing it..."
    pkill -x "Retrace" || true
    sleep 1
    echo "   ✓ Retrace terminated"
else
    echo "⏭️  Skip: Retrace is not running"
fi
echo ""

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

echo "Step 1: Clearing UserDefaults (onboarding state & settings)"
echo "────────────────────────────────────────────────────────────"
# Clear the "Retrace" domain (used by UserDefaults.standard when app name is Retrace)
if defaults read "$DEFAULTS_DOMAIN" &>/dev/null; then
    echo "🗑️  Removing defaults for $DEFAULTS_DOMAIN"
    defaults delete "$DEFAULTS_DOMAIN" 2>/dev/null || true
    echo "   ✓ Removed"
else
    echo "⏭️  Skip: No defaults found for $DEFAULTS_DOMAIN"
fi

# Also try the bundle ID domain just in case
if defaults read "$BUNDLE_ID" &>/dev/null; then
    echo "🗑️  Removing defaults for $BUNDLE_ID"
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
    echo "   ✓ Removed"
else
    echo "⏭️  Skip: No defaults found for $BUNDLE_ID"
fi

echo ""
echo "   Cleared keys include:"
echo "   • hasCompletedOnboarding"
echo "   • hasDownloadedModels"
echo "   • onboardingSkipped"
echo "   • onboardingVersion"
echo "   • onboardingCurrentStep"
echo "   • timelineShortcutConfig"
echo "   • dashboardShortcutConfig"
echo "   • hasRewindData"
echo "   • rewindMigrationCompleted"
echo "   • encryptionEnabled"
echo "   • useRewindData"
echo ""

echo "Step 2: Removing Keychain encryption key"
echo "─────────────────────────────────────────"
# Use security command to delete keychain item from login keychain
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" "$LOGIN_KEYCHAIN" &>/dev/null; then
    echo "🗑️  Removing keychain item: $KEYCHAIN_SERVICE/$KEYCHAIN_ACCOUNT"
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" "$LOGIN_KEYCHAIN"
    echo "   ✓ Removed"
else
    echo "⏭️  Skip: Keychain item not found"
fi
echo ""

echo "Step 3: Removing Preferences plist"
echo "───────────────────────────────────"
remove_file "$PREFERENCES_DIR/$DEFAULTS_DOMAIN.plist"
remove_file "$PREFERENCES_DIR/$BUNDLE_ID.plist"
echo ""

# Step 4: Reset permissions (only if --reset-permissions flag is used)
if [ "$RESET_PERMISSIONS" = true ]; then
    echo "Step 4: Resetting Screen Recording and Accessibility permissions"
    echo "─────────────────────────────────────────────────────────────────"
    echo "⚠️  This requires admin privileges and will prompt for your password."
    echo ""

    # Reset Screen Recording permission (ScreenCapture)
    echo "🔐 Resetting Screen Recording permission..."
    if tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null; then
        echo "   ✓ Screen Recording permission reset"
    else
        echo "   ⚠️  Could not reset Screen Recording (may need manual reset in System Preferences)"
    fi

    # Reset Accessibility permission
    echo "🔐 Resetting Accessibility permission..."
    if tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null; then
        echo "   ✓ Accessibility permission reset"
    else
        echo "   ⚠️  Could not reset Accessibility (may need manual reset in System Preferences)"
    fi

    echo ""
    echo "   Note: You may need to restart System Preferences/Settings to see the change."
    echo ""
fi

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "✅ Safe Onboarding Reset Complete!"
echo ""
echo "Preserved:"
echo "  • Database and Application Support data"
echo "  • Caches"
if [ "$RESET_PERMISSIONS" = true ]; then
echo ""
echo "Reset:"
echo "  • Screen Recording permission (will need to re-grant)"
echo "  • Accessibility permission (will need to re-grant)"
else
echo "  • Screen Recording and Accessibility permissions"
fi
echo ""
echo "Next steps:"
echo "  1. Run the app - onboarding should appear"
echo "  2. Your existing data will still be available"
if [ "$RESET_PERMISSIONS" = true ]; then
echo "  3. Grant Screen Recording and Accessibility permissions when prompted"
fi
echo "═══════════════════════════════════════════════════════════════════════════════"
