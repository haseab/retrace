#!/bin/bash

# Setup script for Nomic Embed model
# Downloads and configures the embedding model for Retrace

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
MODEL_DIR="$HOME/Library/Application Support/Retrace/models"
MODEL_FILE="nomic-embed-text-v1.5.Q4_K_M.gguf"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"
MODEL_URL="https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/$MODEL_FILE"

echo -e "${GREEN}Retrace Embedding Model Setup${NC}"
echo "=============================="
echo ""

# Check if model already exists
if [ -f "$MODEL_PATH" ]; then
    echo -e "${YELLOW}Model already exists at:${NC}"
    echo "  $MODEL_PATH"
    echo ""

    # Get file size
    SIZE=$(du -h "$MODEL_PATH" | cut -f1)
    echo "  Size: $SIZE"
    echo ""

    read -p "Download again? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Setup complete. Model ready to use.${NC}"
        exit 0
    fi
fi

# Create model directory
echo -e "${YELLOW}Creating model directory...${NC}"
mkdir -p "$MODEL_DIR"
echo "  ✓ Created: $MODEL_DIR"
echo ""

# Download model
echo -e "${YELLOW}Downloading Nomic Embed v1.5 model...${NC}"
echo "  Source: $MODEL_URL"
echo "  Target: $MODEL_PATH"
echo ""
echo "  Model size: ~80 MB"
echo "  This may take a few minutes..."
echo ""

# Download with curl (shows progress)
if command -v curl &> /dev/null; then
    curl -L --progress-bar -o "$MODEL_PATH" "$MODEL_URL"
elif command -v wget &> /dev/null; then
    wget --show-progress -O "$MODEL_PATH" "$MODEL_URL"
else
    echo -e "${RED}Error: Neither curl nor wget found${NC}"
    echo "Please install curl or wget and try again"
    exit 1
fi

# Verify download
if [ ! -f "$MODEL_PATH" ]; then
    echo -e "${RED}Error: Download failed${NC}"
    exit 1
fi

# Check file size (should be around 80MB)
SIZE_BYTES=$(stat -f%z "$MODEL_PATH" 2>/dev/null || stat -c%s "$MODEL_PATH" 2>/dev/null)
SIZE_MB=$((SIZE_BYTES / 1024 / 1024))

if [ $SIZE_MB -lt 70 ]; then
    echo -e "${RED}Warning: Downloaded file seems too small ($SIZE_MB MB)${NC}"
    echo "Expected around 80 MB. Download may be corrupted."
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Download complete${NC}"
echo ""

# Print model info
echo "Model Information:"
echo "  Name: Nomic Embed Text v1.5"
echo "  Quantization: Q4_K_M (4-bit)"
echo "  Size: ${SIZE_MB} MB"
echo "  Dimensions: 768"
echo "  Context: 8192 tokens"
echo "  Path: $MODEL_PATH"
echo ""

# Print usage instructions
echo -e "${GREEN}Setup Complete!${NC}"
echo ""
echo "The embedding model is ready to use."
echo ""
echo "Next steps:"
echo "  1. Build the project: swift build"
echo "  2. Run tests: swift test --filter LocalEmbeddingServiceTests"
echo "  3. Use in code:"
echo ""
echo "     let service = LocalEmbeddingService(config: .nomicEmbed)"
echo "     try await service.loadModel()"
echo "     let embedding = try await service.embed("
echo "         text: \"your text here\","
echo "         type: .document"
echo "     )"
echo ""
echo "See Search/Embedding/README.md for full documentation."
echo ""

# Check if running on Apple Silicon
if [[ $(uname -m) == "arm64" ]]; then
    echo -e "${GREEN}✓ Running on Apple Silicon - Metal acceleration enabled${NC}"
else
    echo -e "${YELLOW}⚠ Not running on Apple Silicon - GPU acceleration may not work${NC}"
fi

echo ""
echo -e "${GREEN}All done!${NC}"
