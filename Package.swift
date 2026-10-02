// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveLearn",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "LiveLearn", targets: ["LiveLearnApp"]),
        .library(name: "AudioDomain", targets: ["AudioDomain"]),
        .library(name: "CaptionDomain", targets: ["CaptionDomain"]),
        .library(name: "ProviderAdapters", targets: ["ProviderAdapters"]),
        .library(name: "SessionDomain", targets: ["SessionDomain"]),
        .library(name: "MacAudio", targets: ["MacAudio"]),
        .library(name: "LocalEngine", targets: ["LocalEngine"]),
        .library(name: "SessionStorage", targets: ["SessionStorage"]),
    ],
    dependencies: [
        .package(path: "Vendor/ThinkingOrbsKit"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        // WhisperKit (MIT): open Whisper models on CoreML, the second on-device recognizer.
        // Pure Swift, no binary target; models are downloaded only when the user asks.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
    ],
    targets: [
        // Platform-neutral value logic: frames, clocks, bounded queues, source descriptors.
        .target(name: "AudioDomain"),
        // Deterministic caption merge logic. No I/O, no platform imports.
        .target(name: "CaptionDomain"),
        // Provider contract, capabilities, and the scripted fake provider.
        .target(name: "ProviderAdapters", dependencies: ["AudioDomain", "CaptionDomain"]),
        // Session / lane state machines and coordination.
        .target(name: "SessionDomain", dependencies: ["AudioDomain", "CaptionDomain", "ProviderAdapters"]),
        // Objective-C shim: converts NSException (AVFoundation raises one on tap format mismatch)
        // into NSError so the capture layer can fail a lane instead of aborting the process.
        .target(name: "LLObjCSupport", path: "Sources/LLObjCSupport", publicHeadersPath: "include"),
        // macOS capture: AVAudioEngine microphone, Core Audio process taps, app identity.
        .target(
            name: "MacAudio",
            dependencies: ["AudioDomain", "LLObjCSupport"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        // Engine stages: the recognizer / translator contracts, the segmenter between them, and
        // the pipeline provider that turns any pair of stages into a TranslationProvider.
        .target(name: "EngineKit", dependencies: ["AudioDomain", "CaptionDomain", "ProviderAdapters"]),
        // On-device stages: Apple SpeechAnalyzer (macOS 26) + Translation framework.
        .target(
            name: "LocalEngine",
            dependencies: ["AudioDomain", "CaptionDomain", "ProviderAdapters", "EngineKit"],
            linkerSettings: [
                .linkedFramework("Speech"),
                .linkedFramework("Translation"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        // Cloud and local-server stages over HTTP / WebSocket: OpenAI-compatible chat models
        // (OpenAI, DeepSeek, Qwen, Ollama, LM Studio…), Anthropic, Gemini; OpenAI Realtime and
        // Deepgram streaming recognition. Nothing here is called until a session is started
        // with such a stage chosen.
        .target(name: "CloudEngine", dependencies: ["AudioDomain", "CaptionDomain", "ProviderAdapters", "EngineKit"]),
        // On-device Whisper (WhisperKit): utterance cutting, decoding, and the model store.
        .target(
            name: "WhisperEngine",
            dependencies: ["AudioDomain", "CaptionDomain", "ProviderAdapters", "EngineKit", .product(name: "WhisperKit", package: "argmax-oss-swift")]
        ),
        // Session archives on disk, crash checkpoints, and TXT / Markdown / SRT / VTT export.
        .target(name: "SessionStorage", dependencies: ["AudioDomain", "CaptionDomain", "SessionDomain"]),
        // The per-frame particle mathematics of the stellar theme (dust field, stardust core,
        // star field): pure Foundation / Accelerate, no UI. It is compiled optimised even in
        // debug builds, because a debug build is what the development loop runs and 12,000
        // grains at 30 Hz through unspecialised generics were the largest single CPU cost.
        .target(
            name: "ParticleMath",
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .executableTarget(
            name: "LiveLearnApp",
            dependencies: ["AudioDomain", "CaptionDomain", "ProviderAdapters", "SessionDomain", "MacAudio", "EngineKit", "LocalEngine", "CloudEngine", "WhisperEngine", "SessionStorage", "ParticleMath", .product(name: "ThinkingOrbsKit", package: "ThinkingOrbsKit"), .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Sources/LiveLearnApp",
            resources: [.copy("Resources/Worlds"), .copy("Resources/ModuleTrust.json")],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(name: "CaptionDomainTests", dependencies: ["CaptionDomain", "ProviderAdapters"], path: "Tests/CaptionDomainTests"),
        .testTarget(name: "AudioDomainTests", dependencies: ["AudioDomain"], path: "Tests/AudioDomainTests"),
        .testTarget(name: "SessionDomainTests", dependencies: ["SessionDomain", "ProviderAdapters", "AudioDomain", "CaptionDomain"], path: "Tests/SessionDomainTests"),
        .testTarget(name: "MacAudioTests", dependencies: ["MacAudio", "AudioDomain"], path: "Tests/MacAudioTests"),
        .testTarget(name: "EngineKitTests", dependencies: ["EngineKit", "CaptionDomain", "AudioDomain", "ProviderAdapters"], path: "Tests/EngineKitTests"),
        .testTarget(name: "LocalEngineTests", dependencies: ["LocalEngine", "CaptionDomain", "EngineKit"], path: "Tests/LocalEngineTests"),
        .testTarget(name: "CloudEngineTests", dependencies: ["CloudEngine", "EngineKit", "CaptionDomain", "AudioDomain", "ProviderAdapters"], path: "Tests/CloudEngineTests"),
        .testTarget(name: "WhisperEngineTests", dependencies: ["WhisperEngine", "EngineKit", "CaptionDomain", "AudioDomain", "ProviderAdapters"], path: "Tests/WhisperEngineTests"),
        .testTarget(name: "SessionStorageTests", dependencies: ["SessionStorage", "SessionDomain", "CaptionDomain", "AudioDomain"], path: "Tests/SessionStorageTests"),
        .testTarget(name: "LiveLearnAppTests", dependencies: ["LiveLearnApp", "ParticleMath"], path: "Tests/LiveLearnAppTests"),
    ],
    swiftLanguageModes: [.v6]
)
