// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        // Foundation-only helpers shared by the app and the CleanupCheck CLI.
        // No WhisperKit dependency so the CLI stays light and fast to build.
        .target(
            name: "LocalFlowKit",
            path: "Sources/LocalFlowKit"
        ),
        // WhisperKit-backed transcription core shared by the app and the
        // StreamCheck CLI: the engine, its serial wrapper, and the incremental
        // (streaming) transcriber. Kept out of LocalFlowKit so the light
        // CleanupCheck CLI never pulls in WhisperKit.
        .target(
            name: "LocalFlowStreaming",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                "LocalFlowKit"
            ],
            path: "Sources/LocalFlowStreaming"
        ),
        .executableTarget(
            name: "LocalFlow",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                "LocalFlowKit",
                "LocalFlowStreaming"
            ],
            path: "Sources/LocalFlow",
            // Info.plist and the app icon are bundled by Scripts/build-app.sh, not SwiftPM,
            // so exclude them from the target (declaring the .icns as a .copy resource would
            // make SwiftPM emit a LocalFlow_LocalFlow.bundle we don't want).
            exclude: ["Info.plist", "Resources"]
        ),
        .executableTarget(
            name: "SttSmokeCheck",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/SttSmokeCheck"
        ),
        .executableTarget(
            name: "CleanupCheck",
            dependencies: [
                "LocalFlowKit"
            ],
            path: "Sources/CleanupCheck"
        ),
        // Offline, deterministic checks for the Phase 3 pure functions (dictionary
        // replacements, voice-command encode/decode, normalization). LocalFlowKit
        // only — no WhisperKit, so it builds and runs fast.
        .executableTarget(
            name: "DictCheck",
            dependencies: [
                "LocalFlowKit"
            ],
            path: "Sources/DictCheck"
        ),
        // Headless validation + timing evidence for the streaming pipeline.
        .executableTarget(
            name: "StreamCheck",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                "LocalFlowKit",
                "LocalFlowStreaming"
            ],
            path: "Sources/StreamCheck"
        )
    ]
)
