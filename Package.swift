// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LocalFlowCore", targets: ["LocalFlowCore"]),
        .library(name: "LocalFlowTranscription", targets: ["LocalFlowTranscription"]),
        .library(name: "LocalFlowPostProcessing", targets: ["LocalFlowPostProcessing"]),
        .executable(name: "LocalFlow", targets: ["LocalFlowApp"]),
        .executable(name: "LocalFlowBench", targets: ["LocalFlowBench"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "LocalFlowCore"),
        .target(name: "LocalFlowObjCShim", publicHeadersPath: "include"),
        // transcribe.cpp (MIT): prebuilt ggml/Metal static lib + vendored Swift
        // wrapper (Sources/TranscribeCpp, from bindings/swift of the same tag).
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.1.3/TranscribeCpp.xcframework.zip",
            checksum: "b7a3442e2f3552cac1ee71b5e164934dd4db243f6b4b16b1e3e3ed5d1645eefd"
        ),
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            exclude: ["LICENSE"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .target(
            name: "LocalFlowTranscription",
            dependencies: [
                "LocalFlowCore",
                "TranscribeCpp",
            ]
        ),
        .target(
            name: "LocalFlowPostProcessing",
            dependencies: ["LocalFlowCore"]
        ),
        .executableTarget(
            name: "LocalFlowBench",
            dependencies: [
                "LocalFlowCore",
                "LocalFlowTranscription",
                "LocalFlowPostProcessing",
            ]
        ),
        .executableTarget(
            name: "LocalFlowApp",
            dependencies: [
                "LocalFlowCore",
                "LocalFlowObjCShim",
                "LocalFlowTranscription",
            ]
        ),
        .testTarget(
            name: "LocalFlowCoreTests",
            dependencies: ["LocalFlowCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
