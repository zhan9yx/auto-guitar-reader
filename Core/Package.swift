// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AGRCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AGRCore", targets: ["AGRCore"]),
        .executable(name: "agr-tool", targets: ["agr-tool"]),
    ],
    targets: [
        // Platform-independent core: model, importers, timeline, synth, DSP,
        // score following, scroll control, community client.
        // Must build and test on Linux (no UIKit/AVFoundation/Vision here).
        .target(name: "AGRCore", path: "Sources/AGRCore"),
        .executableTarget(name: "agr-tool", dependencies: ["AGRCore"], path: "Sources/agr-tool"),
        .testTarget(name: "AGRCoreTests", dependencies: ["AGRCore"], path: "Tests/AGRCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
