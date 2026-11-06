// swift-tools-version: 6.0
import PackageDescription

// Compression runs ffmpeg, which is not bundled: it is found at run time, e.g. where Homebrew puts it
// (`brew install ffmpeg`). See Sources/SmolVidCore/FFmpeg.swift.
let package = Package(
    name: "smol-vid",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SmolVidApp", targets: ["SmolVidApp"]),
        .executable(name: "smolvid", targets: ["smolvid"]),
        .library(name: "SmolVidCore", targets: ["SmolVidCore"]),
    ],
    targets: [
        .target(name: "SmolVidCore"),
        .executableTarget(name: "SmolVidApp", dependencies: ["SmolVidCore"]),
        .executableTarget(name: "smolvid", dependencies: ["SmolVidCore"]),
        .testTarget(name: "SmolVidCoreTests", dependencies: ["SmolVidCore"]),
    ],
    swiftLanguageModes: [.v5]
)
