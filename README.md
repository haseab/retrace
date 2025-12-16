# Retrace

> ⚠️ **VERY EARLY DEVELOPMENT** - This project is in active development and not yet ready for production use. Expect breaking changes, incomplete features, and bugs.

A local-first screen recording and search application for macOS, inspired by Rewind AI. Retrace captures your screen activity, extracts text via OCR, and makes everything searchable—all on-device with encryption you control.

## What is Retrace?

Retrace is an open source alternative to Rewind AI that gives you photographic memory of everything you've seen on your screen. It continuously captures screenshots (every 2 seconds), extracts text using OCR, and stores everything in a searchable database—entirely on your Mac with no cloud dependencies.

### Key Features

- **📸 Continuous Screen Capture** - Captures active displays every 2 seconds with intelligent deduplication (95% reduction)
- **🔍 Full-Text Search** - Find anything you've seen on screen using natural language queries (SQLite FTS5)
- **🎙️ Audio Transcription (WORK IN PROGRESS)** - Transcribe microphone and system audio using whisper.cpp (local, on-device)
- **🔒 Privacy-First** - All data stays on your device with AES-256-GCM encryption at rest
- **🎬 Efficient Storage (WORK IN PROGRESS)** - HEVC video encoding for ~15-20GB/month storage footprint
- **📦 Rewind Import** - Connect to your existing Rewind AI data without any manual work.
- **🧩 Modular Architecture** - Clean separation of concerns with protocol-based boundaries
- **⚡ Performance Optimized (WORK IN PROGRESS)** - <20% CPU, <1GB RAM target during active capture

## Architecture

Retrace is built with a modular architecture consisting of 8 independent components:

```
┌─────────────────────────────────────────────────────────┐
│                          UI                             │
│                    (SwiftUI Views)                      │
└─────────────────────────────────────────────────────────┘
                            │
┌─────────────────────────────────────────────────────────┐
│                         App                             │
│        (Coordination, Lifecycle, Services)              │
└─────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
┌───────▼──────┐   ┌────────▼────────┐   ┌─────▼──────┐
│   Capture    │   │   Processing    │   │   Search   │
│ (Screen/Audio)│──▶│  (OCR/Whisper)  │──▶│  (FTS5)    │
└───────┬──────┘   └────────┬────────┘   └─────┬──────┘
        │                   │                   │
        └───────────────────┼───────────────────┘
                            │
                ┌───────────┴───────────┐
                │                       │
        ┌───────▼──────┐       ┌────────▼────────┐
        │   Storage    │       │    Database     │
        │ (Video/Audio)│       │   (SQLite)      │
        └──────────────┘       └─────────────────┘
```

- **Database** - SQLite + FTS5 for metadata and full-text search
- **Storage** - HEVC video encoding and audio segment management (WORK IN PROGRESS)
- **Capture** - Screen capture (ScreenCaptureKit) and audio recording (WORK IN PROGRESS)
- **Processing** - OCR (Vision), audio transcription (whisper.cpp - WORK IN PROGRESS), text merging
- **Search** - Query parsing, FTS5 ranking, result snippets, hybrid search (future)
- **Migration** - Import from Rewind AI databases
- **App** - Coordination, lifecycle management, service container
- **UI** - SwiftUI interface with search, timeline, and settings

See [AGENTS.md](AGENTS.md) for detailed architecture documentation.

## Tech Stack

- **Language**: Swift 5.9+ (async/await, Actors, Sendable)
- **Platform**: macOS 13.0+ (Ventura) - requires ScreenCaptureKit
- **UI**: SwiftUI
- **OCR**: Vision framework
- **Video**: VideoToolbox (HEVC encoding)
- **Audio**: AVFoundation, ScreenCaptureKit (system audio) - WORK IN PROGRESS
- **Database**: SQLite with FTS5 (full-text search)
- **Encryption**: CryptoKit (AES-256-GCM)
- **Transcription**: [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (bundled in Vendors/) - WORK IN PROGRESS
- **Embeddings**: [llama.cpp](https://github.com/ggerganov/llama.cpp) (bundled in Vendors/) - WORK IN PROGRESS

## Requirements

- macOS 13.0+ (Ventura or later)
- Xcode 15.0+ or Swift 5.9+
- Apple Silicon (for Metal acceleration)

### Permissions Required

Retrace needs the following macOS permissions:

- **Screen Recording** - To capture your screen
- **Accessibility** (optional) - For enhanced context extraction (WORK IN PROGRESS)
- **Microphone** (optional) - For audio transcription (WORK IN PROGRESS)

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/haseab/retrace.git
cd retrace
```

### 2. Build the Project

```bash
swift build
```

Or open in Xcode:

```bash
open Package.swift
```

### 3. Run the App (WORK IN PROGRESS)

**Note: The app is not yet runnable in v0.1. Full app functionality is coming in future releases.**

Once ready, from Xcode, select the `UI` scheme and run (⌘R).

On first launch:

- Grant Screen Recording permission in System Settings
- The app will create its database at `~/Library/Application Support/Retrace/`

### 4. Reset Database (Development)

If you need to start fresh:

```bash
./scripts/reset_database.sh
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
├── Storage/             # Video/audio file management
├── Capture/             # Screen and audio capture
├── Processing/          # OCR, transcription, text merging
├── Search/              # Query parsing and ranking
├── Migration/           # Rewind import tools
├── Shared/              # Protocols and logging
├── Vendors/             # Bundled C++ libraries (whisper, llama)
└── scripts/             # Setup and utility scripts
```

## Roadmap

**v0.1 (Current Release):**

- [x] Screen capture with deduplication
- [x] OCR text extraction (Vision)
- [x] Full-text search (FTS5)
- [x] Rewind AI import
- [x] Database schema and migrations
- [x] Modular architecture with protocol boundaries

**Future Releases:**

- [ ] HEVC video encoding
- [ ] Audio transcription (whisper.cpp)
- [ ] Timeline view improvements
- [ ] Advanced search filters (date, app, URL)
- [ ] Hybrid search (vector + FTS5)
- [ ] Private window detection (exclude sensitive content)
- [ ] Meeting detection and segmentation
- [ ] Web UI for search
- [ ] iOS companion app

## Performance

Retrace will be designed ((WORK IN PROGRESS) to run in the background with minimal impact:

- **CPU**: <20% average (target)
- **Memory**: <1GB RAM during active capture
- **Storage**: ~15-20GB/month with HEVC compression
- **Capture Rate**: Every 2 seconds (configurable)
- **Deduplication**: ~95% reduction via perceptual hashing

## Privacy & Security

- **100% Local** - All processing happens on your device
- **Encrypted at Rest** - AES-256-GCM encryption for stored data
- **No Telemetry** - No data sent to external servers
- **Open Source** - Audit the code yourself

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on:

- Code conventions and testing requirements
- How to work with AI assistants (Claude, GitHub Copilot)
- Architecture decisions and module boundaries
- Submitting pull requests

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Attribution

Created with ♥ by [@haseab](https://github.com/haseab)

- GitHub: [haseab/retrace](https://github.com/haseab/retrace)
- Twitter/X: [@haseab\_](https://x.com/haseab_)

## Acknowledgments

- Inspired by [Rewind AI](https://www.rewind.ai/)
- (WORK IN PROGRESS) Audio will be Built with [whisper.cpp](https://github.com/ggerganov/whisper.cpp) by @ggerganov
- (WORK IN PROGRESS) Embeddings will be Built with [llama.cpp](https://github.com/ggerganov/llama.cpp) by @ggerganov

---

**Would appreciate a Github Star if the project is useful!** ⭐
