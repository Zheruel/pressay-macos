import Foundation
import CNativeASR
import MLX
import MLXAudioSTT

enum WorkerError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { s } else { "Transcription failed" } }
}

/// Private, local-only protocol. stdout is reserved for JSON; native/MLX
/// diagnostic output goes to stderr, which the app discards (never transcript logs).
@main struct Worker {
    static func main() async {
        let output = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        func reply(_ object: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: object) {
                output.write(data); output.write(Data([10]))
            }
        }
        do {
            let args = CommandLine.arguments
            guard args.count == 4 else { throw WorkerError.message("Invalid speech worker arguments") }
            let engine = args[1], path = args[2], runtime = args[3]
            Memory.cacheLimit = 256 * 1024 * 1024
            var native: OpaquePointer?
            var mega: MegaASR?
            if engine == "megaASR" {
                mega = try await MegaASR(directory: URL(fileURLWithPath: path))
            } else {
                let isOrukeet = engine == "orukeet"
                let library = URL(fileURLWithPath: runtime)
                    .appendingPathComponent(isOrukeet ? "orukeet/lib/libnemo_speech_asr_c.dylib" : "transcribe/libtranscribe.dylib")
                if isOrukeet {
                    setenv("GGML_BACKEND_DL_PATH", library.deletingLastPathComponent().path, 1)
                }
                var error = [CChar](repeating: 0, count: 1024)
                native = pressay_asr_load(library.path, path, isOrukeet ? 1 : 0, &error, error.count)
                guard native != nil else { throw WorkerError.message(String(cString: error)) }
                // Compile Metal pipelines before telling the app it is ready.
                // Discard warmup text; it is never a transcript or history row.
                var discarded: UnsafePointer<CChar>?
                let silence = [Float](repeating: 0, count: 16_000)
                _ = silence.withUnsafeBufferPointer {
                    pressay_asr_run(native, $0.baseAddress, $0.count, &discarded, &error, error.count)
                }
            }
            reply(["ready": true])
            while let line = readLine() {
                do {
                    let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                    guard let pcm = json?["pcm"] as? String, let data = Data(base64Encoded: pcm) else {
                        throw WorkerError.message("Missing audio")
                    }
                    guard data.count > 0, data.count % MemoryLayout<Float>.size == 0 else {
                        throw WorkerError.message("Invalid PCM audio")
                    }
                    let samples: [Float] = data.withUnsafeBytes { bytes in
                        stride(from: 0, to: bytes.count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
                    }
                    guard samples.allSatisfy(\.isFinite), samples.count <= 16_000 * 60 else {
                        throw WorkerError.message("Invalid audio length or samples")
                    }
                    let start = ContinuousClock.now
                    let text: String
                    var truncated = false
                    if let mega {
                        let result = try mega.generate(samples: samples)
                        text = result.text
                        truncated = result.generationTokens >= 1200
                    } else if let native {
                        var error = [CChar](repeating: 0, count: 1024)
                        var value: UnsafePointer<CChar>?
                        let status = samples.withUnsafeBufferPointer {
                            pressay_asr_run(native, $0.baseAddress, $0.count, &value, &error, error.count)
                        }
                        guard status == 0 || status == 2 else { throw WorkerError.message(String(cString: error)) }
                        text = value.map { String(cString: $0) } ?? ""
                        truncated = status == 2
                    } else { throw WorkerError.message("Speech model is not loaded") }
                    let duration = start.duration(to: .now).components
                    var response: [String: Any] = ["text": text, "truncated": truncated,
                        "seconds": Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                        "peak_memory": Memory.peakMemory]
                    if let mega { response["router_probability"] = mega.lastRouterProbability }
                    reply(response)
                } catch { reply(["error": error.localizedDescription]) }
            }
            if let native { pressay_asr_free(native) }
            // As in the app's quit path, skip ggml process-global Metal static
            // destructors. The OS releases the process's remaining GPU state.
            _exit(0)
        } catch { reply(["error": error.localizedDescription]) }
    }
}
