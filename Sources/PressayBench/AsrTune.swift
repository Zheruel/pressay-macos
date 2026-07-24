import AVFoundation
import Foundation
import PressayCore
import TranscribeCpp

// asr-tune — dev-only parameter sweep. Drives Model/Session directly (bypassing
// GGMLTranscriber) so every RunOptions / WhisperRunOptions knob and an arbitrary
// GGUF file can be varied per run. Writes asr-results-<tag>.json (same ASRRow
// shape as `asr`) so compare.py can join it with the others.
extension Bench {
    static func runAsrTune(entries: [ManifestEntry], options: [String: String], outDir: URL) async throws {
        guard let tag = options["tag"] else {
            throw BenchError.usage("asr-tune needs --tag <name> for the output file")
        }
        let engineName = options["engine"] ?? ASRModel.whisperTurboGGML.rawValue
        guard let engine = ASRModel(rawValue: engineName) else {
            throw BenchError.usage("unknown --engine \(engineName)")
        }
        // Resolve the GGUF: explicit --gguf, else the engine's cached download.
        let ggufPath: String
        if let p = options["gguf"] {
            ggufPath = p
        } else {
            guard let dl = engine.ggufDownload else {
                throw BenchError.usage("\(engineName) has no ggufDownload; pass --gguf")
            }
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Pressay/Models/GGUF", directoryHint: .isDirectory)
            ggufPath = dir.appending(path: dl.fileName).path
        }
        guard FileManager.default.fileExists(atPath: ggufPath) else {
            throw BenchError.usage("GGUF not found at \(ggufPath) (run `asr --engine \(engineName)` once to download, or pass --gguf)")
        }

        let reps = Int(options["reps"] ?? "1") ?? 1
        let minDuration = TimeInterval(options["min-duration"] ?? "0") ?? 0
        let maxClips = Int(options["max-clips"] ?? "0") ?? 0
        let ids = (options["ids"] ?? "").split(separator: ",").map(String.init)

        // --- Language: default "auto" (nil = autodetect). --language en forces. ---
        let langArg = options["language"] ?? "auto"
        let language: String? = (langArg == "auto") ? nil : langArg

        func parsePnc(_ v: String?) -> Pnc {
            switch v { case "on": .on; case "off": .off; default: .default }
        }
        func parseItn(_ v: String?) -> Itn {
            switch v { case "on": .on; case "off": .off; default: .default }
        }
        let pnc = parsePnc(options["pnc"])
        let itn = parseItn(options["itn"])

        // --- Load model, report what it actually supports. ---
        let model = try Model(path: ggufPath)
        let session = try model.session()
        let acceptsWhisper = model.accepts(.whisper(WhisperRunOptions()))
        print("asr-tune tag=\(tag) engine=\(engineName) gguf=\((ggufPath as NSString).lastPathComponent)")
        print("  arch=\(model.arch) variant=\(model.variant) backend=\(model.backend)")
        print("  supports: PNC=\(model.supports(.pnc)) ITN=\(model.supports(.itn)) " +
              "initialPrompt=\(model.supports(.initialPrompt)) tempFallback=\(model.supports(.temperatureFallback)) " +
              "longForm=\(model.supports(.longForm)) acceptsWhisperRunExt=\(acceptsWhisper)")
        print("  run: language=\(language ?? "auto") pnc=\(pnc) itn=\(itn)")

        // --- Whisper family run-extension: only attach if this model takes it. ---
        var family: RunExtension?
        if acceptsWhisper {
            var w = WhisperRunOptions()
            var any = false
            if let s = options["prompt"] { w.initialPrompt = s; any = true }
            if let s = options["temperature"], let v = Float(s) { w.temperature = v; any = true }
            if let s = options["no-speech-thold"], let v = Float(s) { w.noSpeechThold = v; any = true }
            if let s = options["logprob-thold"], let v = Float(s) { w.logprobThold = v; any = true }
            if let s = options["compression-thold"], let v = Float(s) { w.compressionRatioThold = v; any = true }
            if let s = options["condition-prev"] { w.conditionOnPrevTokens = (s == "on"); any = true }
            if any {
                family = .whisper(w)
                func f(_ v: Float?) -> String { v.map { String($0) } ?? "-" }
                let temp = f(w.temperature), noSpeech = f(w.noSpeechThold)
                let logprob = f(w.logprobThold), compression = f(w.compressionRatioThold)
                let condPrev = w.conditionOnPrevTokens.map { String($0) } ?? "-"
                let hasPrompt = w.initialPrompt != nil
                print("  whisper ext: prompt=\(hasPrompt) temp=\(temp) noSpeech=\(noSpeech) logprob=\(logprob) compression=\(compression) conditionPrev=\(condPrev)")
            }
        }

        var opts = RunOptions()
        opts.timestamps = .none
        opts.language = language
        opts.pnc = pnc
        opts.itn = itn
        opts.family = family

        let clips = selectClips(entries, minDuration: minDuration, maxClips: maxClips)
            .filter { clip in ids.isEmpty || ids.contains(where: { clip.id.hasPrefix($0) }) }
        print("  \(clips.count) clips, \(reps) rep(s)")

        var rows: [ASRRow] = []
        var truncated = 0
        for clip in clips {
            let samples = try loadSamples(clip.audio!)
            for rep in 1...reps {
                let started = ContinuousClock.now
                do {
                    let t = try await session.run(samples, options: opts)
                    let latency = started.duration(to: .now).seconds
                    if session.wasTruncated { truncated += 1 }
                    rows.append(ASRRow(id: clip.id, duration: clip.duration, workers: 1,
                                       rep: rep, latency: latency, text: t.text, error: nil))
                } catch {
                    rows.append(ASRRow(id: clip.id, duration: clip.duration, workers: 1,
                                       rep: rep, latency: -1, text: "", error: String(describing: error)))
                }
            }
        }
        let errs = rows.filter { $0.error != nil }.count
        print("  done: \(rows.count - errs) ok, \(errs) errors, \(truncated) truncated")
        let url = outDir.appending(path: "asr-results-\(tag).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rows).write(to: url)
        print("  wrote \(url.path)")
    }
}
