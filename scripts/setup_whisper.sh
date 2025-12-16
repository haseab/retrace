#!/bin/bash
set -e

# Whisper.cpp Setup Script for Retrace
# Works for both Apple Silicon and Intel Macs

echo "🎙️  Setting up whisper.cpp for Retrace..."

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    echo "📱 Detected: Apple Silicon (arm64)"
    USE_COREML=1
    USE_METAL=1
elif [ "$ARCH" = "x86_64" ]; then
    echo "💻 Detected: Intel Mac (x86_64)"
    USE_COREML=0
    USE_METAL=0
else
    echo "⚠️  Unknown architecture: $ARCH"
    exit 1
fi

# Create directories
INSTALL_DIR="$HOME/Library/Application Support/Retrace"
WHISPER_DIR="$INSTALL_DIR/whisper.cpp"
MODELS_DIR="$INSTALL_DIR/models"

mkdir -p "$INSTALL_DIR"
mkdir -p "$MODELS_DIR"

# Clone or update whisper.cpp
if [ -d "$WHISPER_DIR" ]; then
    echo "📦 Updating whisper.cpp..."
    cd "$WHISPER_DIR"
    git pull
else
    echo "📦 Cloning whisper.cpp..."
    git clone https://github.com/ggml-org/whisper.cpp.git "$WHISPER_DIR"
    cd "$WHISPER_DIR"
fi

# Build whisper.cpp
echo "🔨 Building whisper.cpp..."
cd "$WHISPER_DIR"

if [ "$USE_COREML" = "1" ]; then
    echo "   Building with CoreML + Metal acceleration (Apple Silicon)"
    make clean || true  # Ignore errors if Makefile doesn't exist yet
    WHISPER_COREML=1 WHISPER_METAL=1 make -j$(sysctl -n hw.ncpu)
else
    echo "   Building with CPU acceleration (Intel)"
    make clean || true  # Ignore errors if Makefile doesn't exist yet
    make -j$(sysctl -n hw.ncpu)
fi

echo "✅ whisper.cpp built successfully"

# Download recommended model
MODEL_NAME="small"
MODEL_FILE="ggml-${MODEL_NAME}.bin"
MODEL_PATH="$MODELS_DIR/$MODEL_FILE"

if [ -f "$MODEL_PATH" ]; then
    echo "📦 Model already exists: $MODEL_FILE"
else
    echo "⬇️  Downloading whisper model: $MODEL_NAME (244MB)..."

    # Use the built-in download script
    cd "$WHISPER_DIR"
    bash ./models/download-ggml-model.sh "$MODEL_NAME"

    # Copy to models directory
    cp "models/$MODEL_FILE" "$MODEL_PATH"

    echo "✅ Model downloaded: $MODEL_PATH"
fi

# Convert to CoreML if on Apple Silicon
if [ "$USE_COREML" = "1" ]; then
    COREML_MODEL="$MODELS_DIR/ggml-${MODEL_NAME}-encoder.mlmodelc"

    if [ -d "$COREML_MODEL" ]; then
        echo "📦 CoreML model already exists"
    else
        echo "🔄 Converting model to CoreML for faster inference..."
        cd "$WHISPER_DIR"

        # Install dependencies for conversion
        if ! command -v python3 &> /dev/null; then
            echo "⚠️  Python3 not found. Skipping CoreML conversion."
        else
            pip3 install -q coremltools ane_transformers openai-whisper torch &> /dev/null || true

            # Convert to CoreML
            python3 models/convert-ggml-to-coreml.py "models/$MODEL_FILE" --optimize || {
                echo "⚠️  CoreML conversion failed. Will use CPU model."
            }

            # Copy CoreML model if successful
            if [ -d "models/ggml-${MODEL_NAME}-encoder.mlmodelc" ]; then
                cp -r "models/ggml-${MODEL_NAME}-encoder.mlmodelc" "$COREML_MODEL"
                echo "✅ CoreML model ready for Neural Engine acceleration"
            fi
        fi
    fi
fi

# Create config file
CONFIG_FILE="$INSTALL_DIR/whisper_config.json"
cat > "$CONFIG_FILE" << EOF
{
  "whisper_lib_path": "$WHISPER_DIR/libwhisper.a",
  "model_path": "$MODEL_PATH",
  "coreml_model_path": "$MODELS_DIR/ggml-${MODEL_NAME}-encoder.mlmodelc",
  "use_coreml": $USE_COREML,
  "architecture": "$ARCH",
  "model_size": "$MODEL_NAME"
}
EOF

echo "📝 Config saved to: $CONFIG_FILE"

# Generate module.modulemap for Swift Package Manager
echo ""
echo "🔧 Generating module.modulemap..."
cd "$(dirname "$0")/.."
WHISPER_CPP_PATH="$WHISPER_DIR" ./scripts/generate_modulemap.sh

# Print summary
echo ""
echo "✅ Setup complete!"
echo ""
echo "📍 Installation directory: $INSTALL_DIR"
echo "📦 Whisper.cpp: $WHISPER_DIR"
echo "🎯 Model: $MODEL_PATH"
if [ "$USE_COREML" = "1" ]; then
    echo "⚡ CoreML: Enabled (Neural Engine acceleration)"
else
    echo "💻 CoreML: Disabled (CPU only)"
fi
echo ""
echo "Next steps:"
echo "1. Build your Retrace project: swift build"
echo "2. (Optional) Set WHISPER_CPP_PATH to override default location:"
echo "   export WHISPER_CPP_PATH=\"$WHISPER_DIR\""
echo ""
