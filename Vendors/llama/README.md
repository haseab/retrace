# Bundled llama.cpp Library

This directory contains the pre-compiled llama.cpp library bundled with Retrace for semantic search embeddings.

## Contents

```
Vendors/llama/
├── lib/
│   └── libllama.dylib        # Pre-compiled universal binary (arm64 + x86_64)
├── include/llama/
│   ├── llama.h              # Main llama.cpp header
│   ├── ggml.h               # GGML dependency headers
│   └── ... (other ggml headers)
├── module.modulemap          # Swift module bridge
└── README.md                # This file
```

## Why Bundled?

**Current Approach**: Bundle pre-compiled library in repository
- ✅ `git clone` → `swift build` → works immediately
- ✅ No external installation needed
- ✅ Consistent builds across machines

## Runtime Model Downloads

The llama.cpp library is bundled, but **AI models are downloaded at runtime** on first app launch:

- **Nomic Embed v1.5** (~80 MB): For semantic search embeddings

Models are downloaded to: `{AppPaths.storageRoot}/models/` (default: `~/Library/Application Support/Retrace/models/`, configurable in Settings)

This approach:
- Keeps repository size small (~3.8 MB for library vs ~80 MB for model)
- Gives users control over downloads
- Allows graceful degradation if downloads are skipped

## Version

- llama.cpp: Latest as of 2025-12-14 (v0.0.7403)
- Built on: macOS 13+
- Architecture: Universal (arm64 + x86_64)
- Metal acceleration: Enabled

## Rebuilding the Library

If you need to rebuild `libllama.dylib` (e.g., to update llama.cpp version):

### 1. Build llama.cpp

```bash
# Clone llama.cpp
cd /tmp
rm -rf llama.cpp
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp

# Build as universal binary (arm64 + x86_64)
cmake -B build \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_METAL=ON

cmake --build build --config Release -j$(sysctl -n hw.ncpu)
```

### 2. Copy Files

```bash
# From llama.cpp directory:

# Copy library (rename versioned lib to generic name)
cp build/bin/libllama.*.dylib /path/to/retrace/Vendors/llama/lib/libllama.dylib

# Copy headers
cp include/llama.h /path/to/retrace/Vendors/llama/include/llama/
find ggml/include -name "*.h" -exec cp {} /path/to/retrace/Vendors/llama/include/llama/ \;
```

### 3. Verify Universal Binary

```bash
lipo -info Vendors/llama/lib/libllama.dylib
# Should output: Architectures in the fat file: ... are: x86_64 arm64
```

### 4. Test Build

```bash
swift build
swift test
```

## Integration with Swift

The library is integrated via `module.modulemap`:

```
module llama {
    header "include/llama/llama.h"
    header "include/llama/ggml.h"
    export *
}
```

And linked in `Package.swift` for the Search target:

```swift
cSettings: [
    .unsafeFlags([
        "-I" + llamaIncludePath,
        "-fmodule-map-file=" + llamaPath + "/module.modulemap"
    ])
],
linkerSettings: [
    .unsafeFlags([
        "-L" + llamaLibPath,
        "-lllama",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
    ]),
    .linkedFramework("Accelerate"),
    .linkedFramework("Metal"),
    .linkedFramework("MetalKit")
]
```

## License

llama.cpp is licensed under the MIT License.
See: https://github.com/ggerganov/llama.cpp/blob/master/LICENSE
