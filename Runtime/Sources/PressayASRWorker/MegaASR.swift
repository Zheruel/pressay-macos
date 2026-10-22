import Foundation
import MLX
import MLXNN
import MLXAudioCore
import MLXAudioSTT

/// Mega-ASR's Qwen backbone, learned quality router and LoRA adapter. Port of
/// mlx-audio 0.6.1 mega_asr/{router,lora}.py (MIT). All three are required: a
/// plain Qwen load would silently omit the part that makes this Mega-ASR.
final class MegaASR {
    private let model: Qwen3ASRModel
    private let router: [String: MLXArray]
    private let lora: [String: MLXArray]
    private var active = false
    private(set) var lastRouterProbability: Float = 0

    init(directory: URL) async throws {
        model = try await Qwen3ASRModel.fromModelDirectory(directory)
        router = try MLX.loadArrays(url: directory.appendingPathComponent("extras/router.safetensors"))
        lora = try MLX.loadArrays(url: directory.appendingPathComponent("extras/lora.safetensors"))
        guard router["pos_encoder.pe"] != nil, !lora.isEmpty else {
            throw WorkerError.message("Mega-ASR router or adapter is missing")
        }
        let parameters = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        for key in lora.keys where key.hasSuffix(".lora_A") {
            let source = String(key.dropLast(".lora_A".count))
            let target = Self.targetPath(source)
            guard let a = lora[key], let b = lora[source + ".lora_B"],
                  let original = parameters[target + ".weight"],
                  a.ndim == 2, b.ndim == 2, original.ndim == 2,
                  b.dim(0) == original.dim(0), a.dim(1) == original.dim(1), a.dim(0) == b.dim(1) else {
                throw WorkerError.message("Mega-ASR adapter does not match its backbone: \(source)")
            }
        }
        eval(Array(router.values)); eval(Array(lora.values))
    }

    private static func targetPath(_ source: String) -> String {
        // Python Qwen exposes `layers` as an alias of `model.layers`.
        // The checkpoint contains distinct adapter factors for BOTH names;
        // apply all of them to the same leaves instead of dropping one set.
        source.hasPrefix("layers.") ? "model." + source : source
    }

    private func weight(_ key: String) -> MLXArray { router[key]! }
    private func linear(_ x: MLXArray, _ key: String) -> MLXArray {
        matmul(x, weight(key + ".weight").T) + weight(key + ".bias")
    }
    private func norm(_ x: MLXArray, _ key: String) -> MLXArray {
        let m = mean(x, axis: -1, keepDims: true)
        let v = mean(square(x - m), axis: -1, keepDims: true)
        return (x - m) * rsqrt(v + 1e-5) * weight(key + ".weight") + weight(key + ".bias")
    }
    private func frontend(_ input: MLXArray, _ index: Int) -> MLXArray {
        let conv = "frontend.conv.\(index)", bn = "frontend.conv.\(index + 1)"
        let x = conv1d(input, weight(conv + ".weight"), stride: 2, padding: 1) + weight(conv + ".bias")
        let scaled = (x - weight(bn + ".running_mean")) * rsqrt(weight(bn + ".running_var") + 1e-5)
            * weight(bn + ".weight") + weight(bn + ".bias")
        return gelu(scaled)
    }

    /// Exposed in the worker's optional diagnostic reply for reference parity.
    func degradedProbability(_ audio: MLXArray) -> Float {
        let window = hanningWindow(size: 400, periodic: true)
        let spec = stft(audio: audio, window: window, nFft: 400, hopLength: 160)
        let filters = melFilters(sampleRate: 16000, nFft: 400, nMels: 80, melScale: .slaney)
        // MLX Audio Swift returns [frequency, mel], Python [mel, frequency].
        let mel = matmul(square(abs(spec)), filters)
        var x = ((log10(maximum(mel, 1e-10)) + 4) / 4).expandedDimensions(axis: 0)
        x = frontend(frontend(x, 0), 4)
        x = x + weight("pos_encoder.pe")[0..., 0..<x.dim(1), 0...]
        let layers = router.keys.filter { $0.hasSuffix(".linear1.weight") }.count
        for i in 0..<layers {
            let key = "transformer.layers.\(i)"
            let n = norm(x, key + ".norm1")
            let qkv = matmul(n, weight(key + ".self_attn.in_proj_weight").T)
                + weight(key + ".self_attn.in_proj_bias")
            let parts = split(qkv, parts: 3, axis: -1)
            let steps = x.dim(1), width = x.dim(2), heads = 4, dim = width / heads
            let q = parts[0].reshaped([1, steps, heads, dim]).transposed(0, 2, 1, 3)
            let k = parts[1].reshaped([1, steps, heads, dim]).transposed(0, 2, 3, 1)
            let v = parts[2].reshaped([1, steps, heads, dim]).transposed(0, 2, 1, 3)
            let attention = softmax(matmul(q * (1 / sqrt(Float(dim))), k), axis: -1)
            let values = matmul(attention, v).transposed(0, 2, 1, 3).reshaped([1, steps, width])
            x = x + linear(values, key + ".self_attn.out_proj")
            x = x + linear(gelu(linear(norm(x, key + ".norm2"), key + ".linear1")), key + ".linear2")
        }
        x = norm(x, "transformer.norm")
        let weights = softmax(linear(x, "pooling.query").squeezed(axis: -1), axis: -1)
        let pooled = sum(weights.expandedDimensions(axis: -1) * x, axis: 1)
        let logits = linear(gelu(linear(pooled, "classifier.0")), "classifier.3").squeezed(axis: 0)
        return softmax(logits, axis: -1)[1].item(Float.self)
    }

    func generate(samples: [Float]) throws -> STTOutput {
        let audio = MLXArray(samples)
        lastRouterProbability = degradedProbability(audio)
        let want = lastRouterProbability >= 0.5
        if want != active {
            // Stable order also makes the two alias contributions reproducible.
            for key in lora.keys.filter({ $0.hasSuffix(".lora_A") }).sorted() {
                let source = String(key.dropLast(".lora_A".count)), path = Self.targetPath(source)
                guard let a = lora[key], let b = lora[source + ".lora_B"],
                      let original = model.parameters().flattened().first(where: { $0.0 == path + ".weight" })?.1 else {
                    throw WorkerError.message("Mega-ASR adapter could not resolve \(source)")
                }
                let delta = matmul(b.asType(.float32), a.asType(.float32)).asType(original.dtype)
                let changed = want ? original + delta : original - delta
                // Materialize one leaf at a time, as the reference does.
                // Retaining all original weights and all lazy deltas together
                // can briefly double model memory on a 24 GB Mac.
                eval(changed)
                model.update(parameters: ModuleParameters.unflattened([path + ".weight": changed]))
            }
            // Same reversible BF16 addition/subtraction as the benchmark runtime.
            eval(model)
            active = want
            Memory.clearCache()
        }
        return model.generate(audio: audio, maxTokens: 1200, temperature: 0,
                              chunkDuration: 25)
    }
}
