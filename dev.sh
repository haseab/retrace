#!/bin/bash

# Build and run Retrace in DEBUG mode with hot reloading support
# Usage: ./dev.sh

set -e

echo "🔨 Building Retrace (DEBUG)..."
swift build -c debug

echo ""
echo "🚀 Starting Retrace..."
echo ""

# Run the executable directly for hot reload support
.build/debug/Retrace
