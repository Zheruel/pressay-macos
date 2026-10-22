import Foundation

/// Immutable, integrity-checked model data. Executable runtimes ship in the signed app.
public struct ASRArtifact: Sendable {
    public let path: String
    public let bytes: Int64
    public let sha256: String
    public let url: URL
}

extension ASRModel {
    public var workerArtifacts: [ASRArtifact] {
        let repository: String
        let revision: String
        let files: [(String, Int64, String)]
        switch self {
        case .orukeet:
            repository = "oruk/orukeet"
            revision = "555136b50265a132d4cea0d35560c26fc4f657ab"
            files = [
                ("orukeet-v0.1.0-q8.gguf", 714456704, "93ce19c6d8244acbfea980eeaf970531d4f216171578ef8e041dcc2d070a45bd"),
            ]
        case .moss:
            repository = "handy-computer/MOSS-Transcribe-Diarize-gguf"
            revision = "8c603aa6da33a068e39bbd109786f85786a21834"
            files = [
                ("MOSS-Transcribe-Diarize-Q6_K.gguf", 768152256, "7fd37409dbec9c732f912717f3cd8f4cd2c5083841edfab2f3b670f816512b44"),
            ]
        case .parakeetUltra:
            repository = "handy-computer/parakeet-ultra-gguf"
            revision = "a1539be1b849ea7463b88343e5277b373d0c4ea9"
            files = [
                ("parakeet-ultra-Q8_0.gguf", 740363168, "007a59761e9258779f189df396b50d12b83bb5b79e66df4b955c230d2f2a0a59"),
            ]
        case .qwen3ASR17:
            repository = "handy-computer/Qwen3-ASR-1.7B-gguf"
            revision = "0e0a596e3959c3f3f2ab7d443a5b6f0f4a4bba6f"
            files = [
                ("Qwen3-ASR-1.7B-Q6_K.gguf", 1692554208, "c75a961b7134a6c952d89797865cb0d0376876185aee04ef6d12c31c2952e4e1"),
            ]
        case .megaASR:
            repository = "mlx-community/Mega-ASR-bf16"
            revision = "58b2aa4ed62343871f6dba78a4f71db015406152"
            files = [
                ("config.json", 2086, "cf7ab500f801b6fd1383266357af467e4c56705eebc4a600457d818b972a360d"),
                ("model.safetensors", 4076186653, "2f080a3b769ae469aeaaa2dcb9e13a94141e54c9e6d5a7aa63392e0dc5a51789"),
                ("tokenizer_config.json", 12487, "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
                ("vocab.json", 2776833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
                ("merges.txt", 1671853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
                ("extras/router.safetensors", 4691980, "7a27e5d6cd23e58fa928ae37e8dc6f0ee3d1e9f1e4b15c4b85dbd5ea1c961c39"),
                ("extras/lora.safetensors", 92504400, "366a27472d5f98284115c623cf68620eb0c37d826ec175c498e7145148b1342b"),
            ]
        default: return []
        }
        return files.map { path, bytes, hash in
            ASRArtifact(path: path, bytes: bytes, sha256: hash,
                url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")!)
        }
    }

    public var downloadBytes: Int64 { workerArtifacts.reduce(0) { $0 + $1.bytes } }
}
