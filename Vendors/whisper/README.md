# Bundled whisper.cpp Library

This directory contains the pre-compiled whisper.cpp library bundled with Retrace to enable self-contained builds.

## Contents

```
Vendors/whisper/
├── lib/
│   └── libwhisper.dylib   # Pre-compiled universal binary (arm64 + x86_64)
├── include/
│   ├── whisper.h          # Main whisper.cpp header
│   └── ggml/              # GGML dependency headers
│       ├── ggml.h
│       ├── ggml-cpu.h
│       └── ... (other ggml headers)
├── module.modulemap       # Swift module bridge
└── README.md             # This file
```

## Why Bundled?

**Previous Approach**: Required manual whisper.cpp installation in `~/Library/Application Support/Retrace/whisper.cpp/`
- ❌ Build failed if not installed
- ❌ Machine-specific paths in Package.swift
- ❌ Hard to onboard new developers

**Current Approach**: Bundle pre-compiled library in repository
- ✅ `git clone` → `swift build` → works immediately
- ✅ No external installation needed
- ✅ Consistent builds across machines

## Runtime Model Downloads

The whisper.cpp library is bundled, but **AI models are downloaded at runtime** on first app launch:

- **Whisper Small Model** (~465 MB): For speech-to-text transcription
- **Nomic Embed v1.5** (~80 MB): For semantic search embeddings

Models are downloaded to: `~/Library/Application Support/Retrace/models/`

This approach:
- Keeps repository size small (~400 KB for library vs ~545 MB for models)
- Gives users control over downloads
- Allows graceful degradation if downloads are skipped

## Version

- whisper.cpp: Latest as of 2025-12-13
- Built on: macOS 13+
- Architecture: Universal (arm64 + x86_64)

## Rebuilding the Library

If you need to rebuild `libwhisper.dylib` (e.g., to update whisper.cpp version):

### 1. Build whisper.cpp

```bash
# Clone whisper.cpp
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp

# Build as universal binary (arm64 + x86_64)
cmake -B build \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DBUILD_SHARED_LIBS=ON \
    -DWHISPER_METAL=ON \
    -DWHISPER_COREML=ON

cmake --build build --config Release
```

### 2. Copy Files

```bash
# From whisper.cpp directory:

# Copy library
cp build/src/libwhisper.dylib /path/to/retrace/Vendors/whisper/lib/

# Copy headers
cp include/whisper.h /path/to/retrace/Vendors/whisper/include/
cp -r ggml/include/* /path/to/retrace/Vendors/whisper/include/ggml/
```

### 3. Verify Universal Binary

```bash
lipo -info Vendors/whisper/lib/libwhisper.dylib
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
module CWhisper {
    header "include/whisper.h"
    export *
}
```

And linked in `Package.swift`:

```swift
cSettings: [
    .unsafeFlags([
        "-I" + whisperIncludePath,
        "-I" + whisperIncludePath + "/ggml",
        "-fmodule-map-file=" + whisperPath + "/module.modulemap"
    ])
],
linkerSettings: [
    .unsafeFlags([
        "-L" + whisperLibPath,
        "-lwhisper",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
    ]),
    .linkedFramework("Accelerate"),
    .linkedFramework("CoreML"),
    .linkedFramework("Metal")
]
```

## License

whisper.cpp is licensed under the MIT License.
See: https://github.com/ggerganov/whisper.cpp/blob/master/LICENSE
