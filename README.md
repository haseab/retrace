
# Retrace

> ⚠️ **VERY EARLY DEVELOPMENT** - This project is in very early development. Expect breaking changes, incomplete features, and bugs.

A local-first screen recording and search application for macOS, inspired by Rewind AI. Retrace captures your screen activity, extracts text via OCR, and makes everything searchable—all locally on-device.

## What is Retrace?

Retrace is an open source alternative to Rewind AI that gives you photographic memory of everything you've seen on your screen. It continuously captures screenshots (every 2 seconds by default), extracts text using OCR, and stores everything in a searchable database—entirely on your Mac with no cloud dependencies.

## Current Status (v0.5)

### ✅ What's Working

- **Continuous screen capture** with configurable intervals (every 2 seconds default)
- **OCR text extraction** using Apple's Vision framework
- **Full-text search** with advanced filters (app, date, exclusions)
- **Timeline viewer** - Scrub through your screen history frame-by-frame
- **Dashboard analytics** - Visualize app usage, screen time, and activity patterns
- **Rewind AI import** - Seamless, resumable background import of existing Rewind data
- **Settings panel** - Comprehensive controls for capture, storage, privacy, and shortcuts
- **Global hotkeys** - Quick access (Cmd+Shift+T for timeline, Cmd+Shift+D for dashboard)
- **HEVC video encoding** - Working but not yet optimized for efficiency
- **Search highlighting** - Visual highlighting of search results in frames
- **Privacy controls** - Exclude apps and private browsing windows

### 🚧 Coming Soon

- **Optimized storage** - Improving HEVC compression efficiency
- **Audio recording and transcription** - Whisper.cpp integration ready but disabled
- **Advanced keyboard shortcuts** - More customizable shortcuts
- **Decrypt and backup Rewind database** - Export your Rewind data

## Architecture

**v0.5 Data Flow (Current Implementation):**

```
CGWindowListCapture (every 2s)
    ↓
Frame Deduplication
    ↓
Split into two paths:
    ├─ OCR Path: Vision OCR → Text Extraction → SQLite Database
    └─ Video Path: HEVC Encoding → .mp4 segments
    ↓
Full-Text Search (FTS5) → Timeline/Dashboard UI
```

Retrace is built with a modular architecture:

- **Database** - SQLite + FTS5 for metadata and full-text search
- **Storage** - HEVC video encoding for screen recordings
- **Capture** - Screen capture using CGWindowListCapture API
- **Processing** - OCR text extraction using Apple's Vision framework
- **Search** - Query parsing, FTS5 ranking, and result snippets
- **Migration** - Import from Rewind AI databases
- **App** - Coordination, lifecycle management, service container
- **UI** - SwiftUI interface with search, timeline, and settings

See [AGENTS.md](AGENTS.md) for detailed architecture documentation.

## Tech Stack

### Active in v0.5

- **Language**: Swift 5.9+ with async/await, Actors, Sendable
- **Platform**: macOS 13.0+ (Apple Silicon required)
- **UI**: SwiftUI with custom design system
- **Screen Capture**: CGWindowListCapture API (legacy, no privacy indicator)
- **OCR**: Vision framework (macOS native)
- **Video**: VideoToolbox (HEVC encoding)
- **Database**: SQLite with FTS5 full-text search
- **Encryption**: CryptoKit (AES-256-GCM) for database

### Planned for Future Releases

- **Audio transcription**: whisper.cpp (bundled, ready but disabled)
- **Embeddings**: llama.cpp for semantic search (prepared but not active)

## Requirements

- **macOS 13.0+** (Ventura or later)
- **Apple Silicon** (M1/M2/M3) - Intel not supported
- **Xcode 15.0+** or Swift 5.9+ for building from source

### Permissions Required

Retrace needs the following macOS permissions:

- **Screen Recording** - To capture your screen
- **Accessibility** - For enhanced context extraction (app names, window titles, browser URLs)

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/haseab/retrace.git
cd retrace
```

### 2. Build and Run

**Option A: Using Xcode (Recommended)**

```bash
open Package.swift
```

1. Wait for Swift Package Manager to resolve dependencies
2. Select the `Retrace` scheme in Xcode
3. Build and run (⌘R)

**Option B: Command Line**

```bash
# Build the project
swift build -c release

# Run the executable
.build/release/Retrace
```

**First Launch:**

1. Grant **Screen Recording** permission when prompted (System Settings → Privacy & Security)
2. Grant **Accessibility** permission for enhanced context extraction
3. Complete the onboarding flow
4. Optionally import existing Rewind AI data
5. Configure settings (capture interval, excluded apps, shortcuts)

The app will create its database at the default location (`~/Library/Application Support/Retrace/`) or a custom location if configured in Settings.

### 3. Development Scripts

**Reset database** (keeps settings):

```bash
./scripts/reset_database.sh
```

**Reset onboarding** (safe, preserves data):

```bash
./scripts/reset_onboarding_safe.sh
```

**Hard reset** (deletes everything):

```bash
./scripts/hardreset_onboarding.sh
```

## Development

Retrace follows a Test-Driven Development (TDD) approach. See [CONTRIBUTING.md](CONTRIBUTING.md) for:

- Development workflow and conventions
- Testing requirements (TDD, mocking protocols)
- AI-assisted development guidelines
- Module boundaries and architecture decisions
- Code style and Swift patterns

### Running Tests

```bash
swift test
```

### Project Structure

```
retrace/
├── App/                 # App coordination and lifecycle
├── UI/                  # SwiftUI views and view models
├── Database/            # SQLite + FTS5 implementation
├── Storage/             # HEVC video encoding and file management
├── Capture/             # Screen capture (CGWindowListCapture)
├── Processing/          # OCR and text extraction
├── Search/              # Query parsing and FTS5 ranking
├── Migration/           # Rewind import tools
├── Shared/              # Protocols and shared models
└── scripts/             # Build and utility scripts
```

## Roadmap

### v0.5 (Current Release - February 2026) ✅

- [x] Screen capture with deduplication
- [x] OCR text extraction (Vision framework)
- [x] Full-text search (SQLite FTS5)
- [x] Dashboard with app usage analytics
- [x] Timeline frame viewer
- [x] HEVC video encoding (working but not optimized)
- [x] Settings and preferences
- [x] Rewind AI import (resumable)
- [x] Menu bar and global hotkeys
- [x] Search highlighting

### v0.2+ (Future Releases) - TBD

_Roadmap for future releases to be determined based on user feedback and priorities._

## Performance

**Current v0.5 Metrics:**

- **Capture Rate**: Every 2 seconds (configurable: 1-60 seconds)
- **OCR Speed**: ~200-500ms per frame on Apple Silicon
- **Search Speed**: <100ms for typical queries

**Storage (Work in Progress):**

- **Current**: ~50-70GB/month (HEVC working but not optimized)
- **Target**: ~15-20GB/month with optimized compression

## Known Limitations (v0.5)

- **macOS 13.0+ and Apple Silicon only** - Intel Macs not supported
- **Storage not yet efficient** - Currently 4-5x less efficient than Rewind AI (~50-70GB/month vs ~15GB/month). HEVC encoding is working but not optimized
- **No audio capture** - Audio recording and transcription infrastructure exists but is disabled for v0.5

See [GitHub Issues](https://github.com/haseab/retrace/issues) for known bugs and feature requests.

## Privacy & Security

- **100% Local** - All processing happens on your device
- **Encrypted at Rest** - AES-256-GCM encryption for stored data
- **No Telemetry** - No data sent to external servers
- **Open Source** - Audit the code yourself

## Dependencies

Retrace uses minimal external dependencies:

- **[swift-sqlcipher](https://github.com/skiptools/swift-sqlcipher)** - SQLite with encryption for Rewind database import
- **[Sparkle](https://github.com/sparkle-project/Sparkle)** - Auto-update framework
- **Apple Frameworks**: CoreGraphics, Vision, AppKit, SwiftUI, VideoToolbox, CryptoKit

Future releases will add:
- **whisper.cpp** (bundled in Vendors/) - Local audio transcription
- **llama.cpp** (bundled in Vendors/) - Local embeddings for semantic search

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on:

- Code conventions and testing requirements
- How to work with AI assistants (Claude, GitHub Copilot)
- Architecture decisions and module boundaries
- Submitting pull requests

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Attribution

Created with ♥ by [@haseab](https://github.com/haseab)

- GitHub: [haseab/retrace](https://github.com/haseab/retrace)
- Twitter/X: [@haseab\_](https://x.com/haseab_)

## Acknowledgments

- Inspired by [Rewind AI](https://www.rewind.ai/)
- Future audio transcription will use [whisper.cpp](https://github.com/ggerganov/whisper.cpp) by @ggerganov
- Future semantic search will use [llama.cpp](https://github.com/ggerganov/llama.cpp) by @ggerganov

---

**Would appreciate a Github Star if the project is useful!** ⭐
