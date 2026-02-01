#!/bin/bash
set -euo pipefail

# Generate module.modulemap for whisper.cpp with correct paths
# Usage: ./scripts/generate_modulemap.sh

# Get storage root from app settings or default
source "$(dirname "$0")/_get_storage_root.sh"

# Determine whisper.cpp installation path
# Priority: WHISPER_CPP_PATH env var > app settings > default location
WHISPER_PATH="${WHISPER_CPP_PATH:-$RETRACE_STORAGE_ROOT/whisper.cpp}"

# Verify whisper.cpp is installed
WHISPER_HEADER="$WHISPER_PATH/include/whisper.h"
if [ ! -f "$WHISPER_HEADER" ]; then
    echo "❌ Error: whisper.cpp not found at: $WHISPER_PATH"
    echo ""
    echo "Expected header: $WHISPER_HEADER"
    echo ""
    echo "To fix this:"
    echo "  1. Run: ./scripts/setup_whisper.sh"
    echo "  2. Or set WHISPER_CPP_PATH environment variable to your whisper.cpp installation"
    echo ""
    exit 1
fi

# Output file
OUTPUT_FILE="Processing/Audio/module.modulemap"

# Generate module.modulemap
cat > "$OUTPUT_FILE" <<EOF
module CWhisper {
    header "$WHISPER_HEADER"
    export *
}
EOF

echo "✅ Generated $OUTPUT_FILE"
echo "   Using whisper.cpp from: $WHISPER_PATH"
