# App Module

**Owner**: Integration (built after core modules)
**Status**: Future work

## Responsibility

Wire all modules together:
- Initialize all services
- Coordinate data flow between modules
- Handle app lifecycle
- Provide entry point for UI

## Files to Create

```
App/
├── AppCoordinator.swift      # Main coordinator
├── ServiceContainer.swift    # Dependency injection
├── AppLifecycle.swift        # Handle app states
└── RetraceApp.swift          # SwiftUI App entry point
```

## Data Flow

```swift
// Pseudocode for main pipeline
class AppCoordinator {
    func start() async {
        // 1. Initialize all services
        await database.initialize()
        await storage.initialize(config: storageConfig)
        await processing.initialize(config: processingConfig)
        await search.initialize(config: searchConfig)

        // 2. Start capture
        try await capture.startCapture(config: captureConfig)

        // 3. Process captured frames
        for await frame in capture.frameStream {
            // Store frame
            let writer = try await storage.createSegmentWriter()
            try await writer.appendFrame(frame)

            // Extract text
            let text = try await processing.extractText(from: frame)

            // Index for search
            try await search.index(text: text)

            // Store metadata in database
            let frameRef = FrameReference(...)
            try await database.insertFrame(frameRef)
        }
    }
}
```

## Dependencies

Depends on ALL other modules being complete:
- Database
- Storage
- Capture
- Processing
- Search
