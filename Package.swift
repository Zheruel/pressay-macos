// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Pressay",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PressayCore", targets: ["PressayCore"]),
        .library(name: "PressayTranscription", targets: ["PressayTranscription"]),
        .library(name: "PressayPostProcessing", targets: ["PressayPostProcessing"]),
        .executable(name: "Pressay", targets: ["PressayApp"]),
        .executable(name: "PressayBench", targets: ["PressayBench"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "PressayCore"),
        .target(name: "PressayObjCShim", publicHeadersPath: "include"),
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
            name: "PressayTranscription",
            dependencies: [
                "PressayCore",
                "TranscribeCpp",
            ]
        ),
        .target(
            name: "PressayPostProcessing",
            dependencies: ["PressayCore"]
        ),
        .executableTarget(
            name: "PressayBench",
            dependencies: [
                "PressayCore",
                "PressayTranscription",
                "PressayPostProcessing",
            ]
        ),
        .executableTarget(
            name: "PressayApp",
            dependencies: [
                "PressayCore",
                "PressayObjCShim",
                "PressayTranscription",
            ]
        ),
        .testTarget(
            name: "PressayCoreTests",
            dependencies: ["PressayCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
