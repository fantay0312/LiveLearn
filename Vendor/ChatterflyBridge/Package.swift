// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "ChatterflyBridge", platforms: [.macOS("26.0")],
    products: [.executable(name: "LiveLearnChatterfly", targets: ["LiveLearnChatterfly"])],
    targets: [
        .systemLibrary(name: "COpus", pkgConfig: "opus", providers: [.brew(["opus"])]),
        .target(name: "ChatterflyProtocol", dependencies: ["COpus"], resources: [.copy("Resources/ServerPublicKey.der")],
                linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "LiveLearnChatterfly", dependencies: ["ChatterflyProtocol"]),
        .testTarget(name: "ChatterflyProtocolTests", dependencies: ["ChatterflyProtocol"]),
    ], swiftLanguageModes: [.v5])
