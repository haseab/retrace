// swift-tools-version:5.9
import PackageDescription
import Foundation

// MARK: - Whisper.cpp Path Configuration (Bundled)
// ⚠️ RELEASE 2 ONLY - Audio transcription dependencies
// Uncomment these for Release 2 (January 1st) when audio features are re-enabled

/// Use bundled whisper.cpp library from Vendors directory
/// This makes the project self-contained - no external dependencies needed for building
// let whisperPath = "Vendors/whisper"
// let whisperIncludePath = whisperPath + "/include"
// let whisperLibPath = whisperPath + "/lib"


// MARK: - Package Definition

let package = Package(
    name: "Retrace",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "Shared", targets: ["Shared"]),
        .library(name: "Database", targets: ["Database"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "Processing", targets: ["Processing"]),
        .library(name: "Search", targets: ["Search"]),
        .library(name: "Migration", targets: ["Migration"]),
        .library(name: "App", targets: ["App"]),
        .executable(name: "Retrace", targets: ["Retrace"]),
    ],
    dependencies: [
        // NOTE: Dependencies are bundled locally in Vendors/ or will be downloaded at runtime
        // ⚠️ RELEASE 2 ONLY:
        // whisper.cpp - bundled in Vendors/whisper/
        // Models (*.bin, *.gguf) - downloaded at runtime on first launch

        // Hot reloading for development (requires InjectionIII.app)
        .package(url: "https://github.com/krzysztofzablocki/Inject.git", from: "1.5.2"),
    ],
    targets: [
        // MARK: - Shared models and protocols
        .target(
            name: "Shared",
            dependencies: [],
            path: "Shared"
        ),

        // MARK: - Database module
        .target(
            name: "Database",
            dependencies: ["Shared"],
            path: "Database",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ]
        ),
        .testTarget(
            name: "DatabaseTests",
            dependencies: ["Database", "Shared"],
            path: "Database/Tests",
            exclude: [
                "_future"  // Release 2+ tests
            ]
            // ⚠️ RELEASE 2 ONLY - Whisper linker settings removed for Release 1
        ),

        // MARK: - Storage module
        .target(
            name: "Storage",
            dependencies: ["Shared"],
            path: "Storage",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ]
        ),
        .testTarget(
            name: "StorageTests",
            dependencies: ["Storage", "Shared"],
            path: "Storage/Tests"
            // ⚠️ RELEASE 2 ONLY - Whisper linker settings removed for Release 1
        ),

        // MARK: - Capture module
        .target(
            name: "Capture",
            dependencies: ["Shared"],
            path: "Capture",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ]
        ),
        .testTarget(
            name: "CaptureTests",
            dependencies: ["Capture", "Shared"],
            path: "Capture/Tests"
            // ⚠️ RELEASE 2 ONLY - Whisper linker settings removed for Release 1
            // ⚠️ RELEASE 2 ONLY - Audio/Tests excluded for Release 1
        ),

        // MARK: - Processing module
        .target(
            name: "Processing",
            dependencies: [
                "Shared",
                "Database"
            ],
            path: "Processing",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ]
            // ⚠️ RELEASE 2 ONLY - Whisper cSettings and linkerSettings removed for Release 1
            // Re-add Accelerate, CoreML, Metal frameworks when audio transcription is re-enabled
        ),
        .testTarget(
            name: "ProcessingTests",
            dependencies: ["Processing", "Shared", "Database", "Storage"],
            path: "Processing/Tests"
            // ⚠️ RELEASE 2 ONLY - Whisper cSettings and linkerSettings removed for Release 1
            // ⚠️ RELEASE 2 ONLY - Audio/Tests excluded for Release 1
        ),

        // MARK: - Search module
        .target(
            name: "Search",
            dependencies: [
                "Shared"
            ],
            path: "Search",
            exclude: [
                "Tests",
                "VectorSearchTODO",  // Exclude vector search implementation
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ]
        ),
        .testTarget(
            name: "SearchTests",
            dependencies: ["Search", "Shared", "Database"],
            path: "Search/Tests"
        ),

        // MARK: - Migration module
        .target(
            name: "Migration",
            dependencies: ["Shared"],
            path: "Migration",
            exclude: [
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ]
        ),

        // MARK: - App integration layer
        .target(
            name: "App",
            dependencies: [
                "Shared",
                "Database",
                "Storage",
                "Capture",
                "Processing",
                "Search",
                "Migration"
            ],
            path: "App",
            exclude: [
                "Tests",
                "README.md"
            ]
            // ⚠️ RELEASE 2 ONLY - Whisper cSettings and linkerSettings removed for Release 1
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                "Shared"
            ],
            path: "App/Tests"
            // ⚠️ RELEASE 2 ONLY - Whisper cSettings and linkerSettings removed for Release 1
        ),

        // MARK: - UI module
        .executableTarget(
            name: "Retrace",
            dependencies: [
                "Shared",
                "App",
                "Database",
                "Storage",
                "Capture",
                "Processing",
                "Search",
                "Migration",
                .product(name: "Inject", package: "Inject")
            ],
            path: "UI",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md"
            ],
            swiftSettings: [
                // Export symbols for InjectionNext hot reloading
                .unsafeFlags(["-Xfrontend", "-enable-implicit-dynamic"], .when(configuration: .debug))
            ],
            linkerSettings: [
                // Export all symbols for dynamic library loading (InjectionNext)
                .unsafeFlags(["-Xlinker", "-export_dynamic"], .when(configuration: .debug))
            ]
            // ⚠️ RELEASE 2 ONLY - Whisper cSettings and linkerSettings removed for Release 1
        ),
        .testTarget(
            name: "RetraceTests",
            dependencies: ["Retrace", "Shared", "App"],
            path: "UI/Tests"
            // ⚠️ RELEASE 2 ONLY - Whisper cSettings and linkerSettings removed for Release 1
        ),
    ]
)
