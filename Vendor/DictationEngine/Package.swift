// swift-tools-version: 6.0
// TypelessEngine — macOS-native, latency-optimized rewrite of typeless-engine (Python).
// Zero third-party Swift dependencies. libopus is linked from Homebrew via pkg-config.
import PackageDescription

let releaseSwift: [SwiftSetting] = [
    // Whole-module optimization is SwiftPM's release default; add cross-module optimization
    // so the hot path (Core <-> Net <-> Audio <-> CLI) inlines across module boundaries.
    .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
]

let package = Package(
    name: "TypelessEngine",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "typeless-engine", targets: ["typeless-engine"]),
        .library(name: "TypelessCore", targets: ["TypelessCore"]),
        .library(name: "TypelessNet", targets: ["TypelessNet"]),
        .library(name: "TypelessAudio", targets: ["TypelessAudio"]),
    ],
    targets: [
        // Homebrew libopus (1.6.1). pkg-config supplies -I/-L; module map links "opus".
        .systemLibrary(
            name: "COpus",
            path: "Sources/COpus",
            pkgConfig: "opus",
            providers: [.brew(["opus"])]
        ),
        // Tiny C shim: Swift cannot call the variadic opus_encoder_ctl(); the shim also hosts
        // the 32-bit-word WebSocket XOR unmask loop (measurably faster than the Swift loop).
        .target(
            name: "COpusShim",
            dependencies: ["COpus"],
            path: "Sources/COpusShim",
            cSettings: [.unsafeFlags(["-O3"])]
        ),
        .target(
            name: "TypelessCore",
            dependencies: ["COpus", "COpusShim"],
            path: "Sources/TypelessCore",
            swiftSettings: releaseSwift
        ),
        .target(
            name: "TypelessNet",
            dependencies: ["TypelessCore", "COpusShim"],
            path: "Sources/TypelessNet",
            swiftSettings: releaseSwift
        ),
        .target(
            name: "TypelessAudio",
            dependencies: ["TypelessCore"],
            path: "Sources/TypelessAudio",
            swiftSettings: releaseSwift,
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "typeless-engine",
            dependencies: ["TypelessCore", "TypelessNet", "TypelessAudio"],
            path: "Sources/typeless-engine",
            swiftSettings: releaseSwift
        ),
        .testTarget(
            name: "TypelessEngineTests",
            dependencies: ["TypelessCore", "TypelessNet", "TypelessAudio"],
            path: "Tests/TypelessEngineTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
