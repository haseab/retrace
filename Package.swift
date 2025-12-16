// swift-tools-version:5.9
import PackageDescription
import Foundation

// MARK: - Whisper.cpp Path Configuration (Bundled)

/// Use bundled whisper.cpp library from Vendors directory
/// This makes the project self-contained - no external dependencies needed for building
let whisperPath = "Vendors/whisper"
let whisperIncludePath = whisperPath + "/include"
let whisperLibPath = whisperPath + "/lib"


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
        // .executable(name: "Retrace", targets: ["RetraceUI"]),
    ],
    dependencies: [
        // NOTE: Dependencies are bundled locally in Vendors/ or will be downloaded at runtime
        // whisper.cpp - bundled in Vendors/whisper/
        // Models (*.bin, *.gguf) - downloaded at runtime on first launch
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
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../Vendors/whisper/lib"
                ])
            ]
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
            path: "Storage/Tests",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../Vendors/whisper/lib"
                ])
            ]
        ),

        // MARK: - Capture module
        .target(
            name: "Capture",
            dependencies: ["Shared"],
            path: "Capture",
            exclude: [
                "Tests",
                "Audio/Tests",  // Exclude from production target
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ]
        ),
        .testTarget(
            name: "CaptureTests",
            dependencies: ["Capture", "Shared"],
            path: "Capture",
            exclude: [
                "Tests/_future",       // Release 2+ tests
                "Audio/Tests/_future"  // Release 2+ audio tests
            ],
            sources: [
                "Tests",
                "Audio/Tests"  // Include in test target
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../Vendors/whisper/lib"
                ])
            ]
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
                "Audio/Tests",  // Exclude from production target
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ],
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
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../Vendors/whisper/lib"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML", .when(platforms: [.macOS])),
                .linkedFramework("Metal", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "ProcessingTests",
            dependencies: ["Processing", "Shared", "Database", "Storage"],
            path: "Processing",
            exclude: [
                "Tests/_future",  // Release 2+ tests (OCR, Accessibility)
                "Audio/Tests/AUDIO_STORAGE_TESTS.md"
            ],
            sources: [
                "Tests",
                "Audio/Tests"  // Include in test target
            ],
            cSettings: [
                .unsafeFlags([
                    "-I" + whisperIncludePath,
                    "-I" + whisperIncludePath + "/ggml",
                    "-fmodule-map-file=" + whisperPath + "/module.modulemap"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../Vendors/whisper/lib"
                ])
            ]
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
            ],
            cSettings: [
                .unsafeFlags([
                    "-I" + whisperIncludePath,
                    "-fmodule-map-file=" + whisperPath + "/module.modulemap"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../Vendors/whisper/lib"
                ])
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                "Shared"
            ],
            path: "App/Tests",
            cSettings: [
                .unsafeFlags([
                    "-I" + whisperIncludePath,
                    "-I" + whisperIncludePath + "/ggml",
                    "-fmodule-map-file=" + whisperPath + "/module.modulemap"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../Vendors/whisper/lib"
                ])
            ]
        ),

        // MARK: - UI module
        .target(
            name: "RetraceUI",
            dependencies: [
                "Shared",
                "App",
                "Database",
                "Storage",
                "Capture",
                "Processing",
                "Search",
                "Migration"
            ],
            path: "UI",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md",
                "RetraceApp.swift"  // Exclude @main from library target
            ],
            cSettings: [
                .unsafeFlags([
                    "-I" + whisperIncludePath,
                    "-fmodule-map-file=" + whisperPath + "/module.modulemap"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../Vendors/whisper/lib"
                ])
            ]
        ),
        .testTarget(
            name: "RetraceUITests",
            dependencies: ["RetraceUI", "Shared", "App"],
            path: "UI/Tests",
            cSettings: [
                .unsafeFlags([
                    "-I" + whisperIncludePath,
                    "-I" + whisperIncludePath + "/ggml",
                    "-fmodule-map-file=" + whisperPath + "/module.modulemap"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../Vendors/whisper/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../../../Vendors/whisper/lib"
                ])
            ]
        ),
    ]
)
