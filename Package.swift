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
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
    ],
    targets: [
        .target(name: "LocalFlowCore"),
        .target(
            name: "LocalFlowTranscription",
            dependencies: [
                "LocalFlowCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .target(
            name: "LocalFlowPostProcessing",
            dependencies: ["LocalFlowCore"]
        ),
        .executableTarget(
            name: "LocalFlowApp",
            dependencies: [
                "LocalFlowCore",
                "LocalFlowTranscription",
                "LocalFlowPostProcessing",
            ]
        ),
        .testTarget(
            name: "LocalFlowCoreTests",
            dependencies: ["LocalFlowCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
