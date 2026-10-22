// swift-tools-version: 6.2
import PackageDescription

// Separate process: MLX and the two ggml runtimes never share a symbol namespace
// with the app's legacy CTranscribe framework. No Python installation is needed.
let package = Package(
    name: "PressayASRRuntime",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "PressayASRWorker", targets: ["PressayASRWorker"])],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git",
                 revision: "19f2296420c875b4f782825c5f5fcb554ed87e38"),
    ],
    targets: [
        .target(name: "CNativeASR", exclude: ["vendor/TRANSCRIBE_LICENSE"],
                publicHeadersPath: "include"),
        .executableTarget(name: "PressayASRWorker", dependencies: [
            "CNativeASR",
            .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
        ]),
    ],
    cxxLanguageStandard: .cxx17
)
