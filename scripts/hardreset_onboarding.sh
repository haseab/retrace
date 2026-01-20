#!/bin/bash

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                      RETRACE ONBOARDING RESET                                 ║
# ║                                                                               ║
# ║  This script resets Retrace to re-trigger onboarding by:                     ║
# ║  • Clearing UserDefaults (onboarding state, settings)                        ║
# ║  • Removing Keychain encryption key                                          ║
# ║  • Resetting Screen Recording permission for Retrace                         ║
# ║  • Resetting Accessibility permission for Retrace                            ║
# ║  • Clearing Application Support database                                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -e  # Exit on error

BUNDLE_ID="io.retrace.app"
DEFAULTS_DOMAIN="Retrace"  # App uses "Retrace" for UserDefaults.standard
APP_SUPPORT_DIR="$HOME/Library/Application Support/Retrace"
PREFERENCES_DIR="$HOME/Library/Preferences"
CACHES_DIR="$HOME/Library/Caches/$BUNDLE_ID"

# Keychain settings (from DatabaseManager.swift)
KEYCHAIN_SERVICE="com.retrace.database"
KEYCHAIN_ACCOUNT="sqlcipher-key"

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                      RETRACE ONBOARDING RESET                                 ║"
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

echo "Step 3: Clearing Application Support database"
echo "──────────────────────────────────────────────"
remove_dir "$APP_SUPPORT_DIR"
echo ""

echo "Step 4: Removing Preferences plist"
echo "───────────────────────────────────"
remove_file "$PREFERENCES_DIR/$DEFAULTS_DOMAIN.plist"
remove_file "$PREFERENCES_DIR/$BUNDLE_ID.plist"
echo ""

echo "Step 5: Clearing Caches"
echo "───────────────────────"
remove_dir "$CACHES_DIR"
echo ""

echo "Step 6: Resetting Screen Recording permission"
echo "──────────────────────────────────────────────"
echo "🔄 Resetting Screen Recording for $BUNDLE_ID..."
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || echo "   ⚠️  tccutil failed for $BUNDLE_ID"
echo "🔄 Resetting Screen Recording for Retrace..."
tccutil reset ScreenCapture Retrace 2>/dev/null || echo "   ⚠️  tccutil failed for Retrace"
echo "🔄 Resetting Screen Recording for iTerm2..."
tccutil reset ScreenCapture com.googlecode.iterm2 2>/dev/null || echo "   ⚠️  tccutil failed for iTerm2"
echo "   ✓ Screen Recording permission reset requested"
echo ""

echo "Step 7: Resetting Accessibility permission"
echo "───────────────────────────────────────────"
echo "🔄 Resetting Accessibility for $BUNDLE_ID..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || echo "   ⚠️  tccutil failed for $BUNDLE_ID"
echo "🔄 Resetting Accessibility for Retrace..."
tccutil reset Accessibility Retrace 2>/dev/null || echo "   ⚠️  tccutil failed for Retrace"
echo "🔄 Resetting Accessibility for iTerm2..."
tccutil reset Accessibility com.googlecode.iterm2 2>/dev/null || echo "   ⚠️  tccutil failed for iTerm2"
echo "   ✓ Accessibility permission reset requested"
echo ""

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "✅ Onboarding Reset Complete!"
echo ""
echo "Next steps:"
echo "  1. Run the app - onboarding should appear"
echo "  2. Grant Screen Recording and Accessibility permissions when prompted"
echo ""
echo "Note: If permissions don't reset, you may need to:"
echo "  • Manually remove Retrace from System Settings → Privacy & Security"
echo "  • Or restart your Mac"
echo "═══════════════════════════════════════════════════════════════════════════════"
