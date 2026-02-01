#!/bin/bash
set -e

# Rebuild whisper.cpp and llama.cpp dylibs with macOS 13.0 deployment target
# This ensures compatibility with macOS 13.0 and later

echo "🔧 Rebuilding dylibs for macOS 13.0+ compatibility..."

# Get storage root from app settings or default
source "$(dirname "$0")/_get_storage_root.sh"

# macOS 13.0 = deployment target 23.0
export MACOSX_DEPLOYMENT_TARGET=13.0

# Detect architecture
ARCH=$(uname -m)
echo "📱 Architecture: $ARCH"

# Directories
WHISPER_SOURCE="$RETRACE_STORAGE_ROOT/whisper.cpp"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_VENDOR="$PROJECT_ROOT/Vendors/whisper"
LLAMA_VENDOR="$PROJECT_ROOT/Vendors/llama"

# ============================================================================
# WHISPER.CPP
# ============================================================================

echo ""
echo "🎙️  Building whisper.cpp..."

if [ ! -d "$WHISPER_SOURCE" ]; then
    echo "❌ Whisper source not found at: $WHISPER_SOURCE"
    echo "   Run ./scripts/setup_whisper.sh first"
    exit 1
fi

cd "$WHISPER_SOURCE"

# Clean previous build
make clean || true

# Build with correct deployment target
if [ "$ARCH" = "arm64" ]; then
    echo "   Building with CoreML + Metal (Apple Silicon)"
    WHISPER_COREML=1 WHISPER_METAL=1 make libwhisper.dylib -j$(sysctl -n hw.ncpu)
else
    echo "   Building with CPU (Intel)"
    make libwhisper.dylib -j$(sysctl -n hw.ncpu)
fi

# Copy dylib to vendor directory
echo "   Copying libwhisper.dylib to Vendors/whisper/lib/"
mkdir -p "$WHISPER_VENDOR/lib"
cp -v libwhisper.dylib "$WHISPER_VENDOR/lib/"

# Copy ggml dylibs if they exist
if [ -f "libggml.dylib" ]; then
    cp -v libggml*.dylib "$WHISPER_VENDOR/lib/" 2>/dev/null || true
fi

echo "✅ Whisper dylib rebuilt"

# Verify deployment target
echo "   Verifying deployment target..."
otool -l "$WHISPER_VENDOR/lib/libwhisper.dylib" | grep -A 3 "LC_BUILD_VERSION" | grep "minos"

# ============================================================================
# LLAMA.CPP
# ============================================================================

echo ""
echo "🦙 Building llama.cpp..."

LLAMA_SOURCE="$RETRACE_STORAGE_ROOT/llama.cpp"

if [ ! -d "$LLAMA_SOURCE" ]; then
    echo "⚠️  Llama source not found at: $LLAMA_SOURCE"
    echo "   Cloning llama.cpp..."
    mkdir -p "$(dirname "$LLAMA_SOURCE")"
    git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_SOURCE"
fi

cd "$LLAMA_SOURCE"

# Clean previous build
make clean || true

# Build with correct deployment target
if [ "$ARCH" = "arm64" ]; then
    echo "   Building with Metal (Apple Silicon)"
    make libllama.dylib -j$(sysctl -n hw.ncpu)
else
    echo "   Building with CPU (Intel)"
    make libllama.dylib -j$(sysctl -n hw.ncpu)
fi

# Copy dylib to vendor directory
echo "   Copying libllama.dylib to Vendors/llama/lib/"
mkdir -p "$LLAMA_VENDOR/lib"
cp -v libllama.dylib "$LLAMA_VENDOR/lib/"

# Copy ggml dylibs if they exist
if [ -f "libggml.dylib" ]; then
    cp -v libggml*.dylib "$LLAMA_VENDOR/lib/" 2>/dev/null || true
fi

echo "✅ Llama dylib rebuilt"

# Verify deployment target
echo "   Verifying deployment target..."
otool -l "$LLAMA_VENDOR/lib/libllama.dylib" | grep -A 3 "LC_BUILD_VERSION" | grep "minos"

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "✅ All dylibs rebuilt with macOS 13.0 deployment target"
echo ""
echo "📦 Whisper dylib: $WHISPER_VENDOR/lib/libwhisper.dylib"
echo "📦 Llama dylib:   $LLAMA_VENDOR/lib/libllama.dylib"
echo ""
echo "Next steps:"
echo "1. swift build   # Should build without warnings"
echo "2. swift test    # Tests should compile (though may still have linker issues with @main)"
echo ""
