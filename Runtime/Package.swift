// swift-tools-version: 6.2
import PackageDescription

// Isolate MLX/ggml symbols from the app's legacy CTranscribe framework.
let package = Package(
    name: "PressayASRRuntime",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "PressayASRWorker", targets: ["PressayASRWorker"])],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git",
                 revision: "9d66d6f1da37a4a116c1655e321b167b3013a5cb"),
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
