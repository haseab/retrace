#!/bin/bash

# Build and run Retrace in DEBUG mode with hot reloading support
# Usage: ./dev.sh

set -e

echo "🔨 Building Retrace (DEBUG mode)..."
swift build -c debug

echo ""
echo "🔥 Hot Reload Ready!"
echo "   • Make sure InjectionIII is running"
echo "   • Edit any .swift file and save to see instant updates"
echo ""
echo "🚀 Starting Retrace..."
echo ""

# Run the executable directly for hot reload support
.build/debug/Retrace
