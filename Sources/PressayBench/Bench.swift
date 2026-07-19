import AVFoundation
import Foundation
import PressayCore
import PressayPostProcessing
import PressayTranscription

// PressayBench — dev-only evaluation harness.
// Subcommands: asr | polish | overhead | vocab | tune (see --help via each).

struct ManifestEntry: Codable {
    let id: String
    let duration: TimeInterval
    let asrLatency: TimeInterval
    let polishLatency: TimeInterval
    let totalLatency: TimeInterval
    let rawTranscript: String
    let polishedText: String
    let usedLanguageModel: Bool
    let audio: String?
    let targetBundleID: String?
}

struct ASRRow: Codable {
    let id: String
    let duration: TimeInterval
    let workers: Int
    let rep: Int
    let latency: TimeInterval
    let text: String
    let error: String?
}

struct PolishRow: Codable {
    let id: String
    let duration: TimeInterval
    let variant: String
    let latency: TimeInterval
    let accepted: Bool
    let reason: String
    let storedUsedLM: Bool
    let rawChars: Int
    let candidateChars: Int
    let changeRatio: Double
}

struct TimelineEntry: Codable {
    let id: String
    let ts: TimeInterval
    let duration: TimeInterval
    let text: String
}

enum BenchError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self {
        case .usage(let message): message
        }
    }
}

@main
struct Bench {
    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            throw BenchError.usage("expected subcommand: asr | polish | kimi-polish | overhead | vocab | tune")
        }
        let options = parseOptions(Array(args.dropFirst()))
        let manifestURL = URL(fileURLWithPath: options["manifest"] ?? ".build/bench/manifest.json")
        let entries = try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: manifestURL))
        let outDir = manifestURL.deletingLastPathComponent()

        switch command {
        case "asr":
            try await runASR(entries: entries, options: options, outDir: outDir)
        case "polish":
            try await runPolish(entries: entries, options: options, outDir: outDir)
        case "kimi-polish":
            try await runKimiPolish(entries: entries, options: options, outDir: outDir)
        case "overhead":
            try runOverhead(entries: entries, outDir: outDir)
        case "vocab":
            try runVocab(entries: entries, outDir: outDir)
        case "tune":
            try await runTune(options: options)
        default:
            throw BenchError.usage("unknown subcommand \(command)")
        }
    }

    static func parseOptions(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index + 1 < args.count {
            if args[index].hasPrefix("--") {
                result[String(args[index].dropFirst(2))] = args[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    static func loadSamples(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw BenchError.usage("cannot allocate buffer for \(path)") }
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        guard let channel = buffer.floatChannelData?[0], count > 0 else {
            throw BenchError.usage("no samples in \(path)")
        }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func selectClips(_ entries: [ManifestEntry], minDuration: TimeInterval, maxClips: Int) -> [ManifestEntry] {
        let sorted = entries.filter { $0.audio != nil }.sorted { $0.duration > $1.duration }
        // Stratified: every clip >= minDuration, plus every 4th shorter clip.
        var selected: [ManifestEntry] = []
        for (index, entry) in sorted.enumerated() where entry.duration >= minDuration || index % 4 == 0 {
            selected.append(entry)
            if maxClips > 0, selected.count >= maxClips { break }
        }
        return selected
    }

    // MARK: - ASR benchmark

    static func runASR(entries: [ManifestEntry], options: [String: String], outDir: URL) async throws {
        let reps = Int(options["reps"] ?? "2") ?? 2
        let minDuration = TimeInterval(options["min-duration"] ?? "0") ?? 0
        let maxClips = Int(options["max-clips"] ?? "0") ?? 0
        let language = options["language"] ?? "en"
        let ids = (options["ids"] ?? "").split(separator: ",").map(String.init)
        // --engine whisperTurboGGML (default) | parakeetV3
        let engineName = options["engine"] ?? ASRModel.whisperTurboGGML.rawValue
        guard let engine = ASRModel(rawValue: engineName) else {
            throw BenchError.usage("unknown --engine \(engineName); use whisperTurboGGML or parakeetV3")
        }
        let clips = selectClips(entries, minDuration: minDuration, maxClips: maxClips)
            .filter { clip in ids.isEmpty || ids.contains(where: { clip.id.hasPrefix($0) }) }
        print("ASR bench: \(clips.count) clips, engine \(engineName), \(reps) reps, language \(language)")

        var samples: [String: [Float]] = [:]
        for clip in clips {
            samples[clip.id] = try loadSamples(clip.audio!)
        }

        var rows: [ASRRow] = []
        let transcriber = GGMLTranscriber(model: engine, language: language)
        try await transcriber.prepare()
        print("model ready")
        for clip in clips {
            let clipSamples = samples[clip.id]!
            for rep in 1...reps {
                let started = ContinuousClock.now
                do {
                    let transcript = try await transcriber.transcribe(
                        AudioClip(samples: clipSamples)
                    )
                    let latency = started.duration(to: .now).seconds
                    rows.append(ASRRow(
                        id: clip.id,
                        duration: clip.duration,
                        workers: 1,
                        rep: rep,
                        latency: latency,
                        text: transcript.text,
                        error: nil
                    ))
                    print(String(
                        format: "  rep=%d %5.1fs audio -> %6.3fs  %@",
                        rep, clip.duration, latency, String(clip.id.prefix(8))
                    ))
                } catch {
                    rows.append(ASRRow(
                        id: clip.id,
                        duration: clip.duration,
                        workers: 1,
                        rep: rep,
                        latency: -1,
                        text: "",
                        error: String(describing: error)
                    ))
                    print("  rep=\(rep) \(clip.duration)s audio -> ERROR \(error)  \(clip.id.prefix(8))")
                }
            }
        }

        // Determinism check across reps, and drift vs the stored production
        // transcript.
        var reference: [String: String] = [:]
        for row in rows where row.rep == 1 && row.error == nil {
            reference[row.id] = normalized(row.text)
        }
        var mismatches = 0
        for row in rows where row.error == nil {
            guard let ref = reference[row.id] else { continue }
            if normalized(row.text) != ref {
                mismatches += 1
                print("MISMATCH id=\(row.id.prefix(8)) rep=\(row.rep)")
                print("  ref : \(ref.prefix(160))")
                print("  got : \(normalized(row.text).prefix(160))")
            }
        }
        var storedMismatches = 0
        let storedById = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.rawTranscript) })
        for row in rows where row.rep == 1 && row.error == nil {
            if let stored = storedById[row.id], normalized(stored) != normalized(row.text) {
                storedMismatches += 1
                print("STORED-DIFF id=\(row.id.prefix(8)) (re-run differs from production transcript)")
            }
        }
        print("transcript mismatches across reps: \(mismatches); vs stored: \(storedMismatches)")

        var resultsName = "asr-results-\(engineName).json"
        if language != "en" {
            resultsName = resultsName.replacingOccurrences(of: ".json", with: "-lang-\(language).json")
        }
        let url = outDir.appending(path: resultsName)
        try JSONEncoder.bench.encode(rows, to: url)
        print("wrote \(url.path)")
    }

    // MARK: - Polish replay

    static func runPolish(entries: [ManifestEntry], options: [String: String], outDir: URL) async throws {
        let minDuration = TimeInterval(options["min-duration"] ?? "25") ?? 25
        let ids = (options["ids"] ?? "").split(separator: ",").map(String.init)
        let clips = entries
            .filter { $0.duration >= minDuration }
            .filter { clip in ids.isEmpty || ids.contains(where: { clip.id.hasPrefix($0) }) }
            .sorted { $0.duration > $1.duration }
        let vocabulary = VocabularyParser.parse(CuratedVocabulary.source)
        let terms = vocabulary.map(\.preferred)
        let validator = ProtectedTokenValidator()

        // Prompt variants: "shipping" is the production prompt (rewrite into an
        // agent prompt); the "light" family reframes the task as copyediting to
        // probe whether that eliminates hallucination and dropped sentences.
        let configurations: [(name: String, mode: PolisherMode, rules: [String], suffix: String)] = [
            ("shipping", .shipping, [], ""),
            ("light", .light, [], ""),
            ("light-fewshot", .light, [], """


            Examples:
            Dictation: "SwiftData"
            Output: "SwiftData"
            Dictation: "um so the the parser crashes when the input is empty, can you fix that"
            Output: "The parser crashes when the input is empty, can you fix that?"
            Dictation: "In the authentication module replace the retry loop with exponential backoff."
            Output: "In the authentication module replace the retry loop with exponential backoff."
            """),
            ("light-plain", .lightPlain, [], ""),
        ]

        var rows: [PolishRow] = []
        for (variant, mode, rules, suffix) in configurations {
            let polisher = ApplePromptPolisher(mode: mode, extraRules: rules, instructionsSuffix: suffix)
            if rows.isEmpty {
                print("polish replay: \(clips.count) clips, availability: \(await polisher.availabilityDescription)")
            }
            for clip in clips {
                let deterministic = DeterministicPromptCleaner.clean(
                    clip.rawTranscript, vocabulary: vocabulary
                )
                let candidateDir = outDir.appending(path: "polish")
                try? FileManager.default.createDirectory(at: candidateDir, withIntermediateDirectories: true)
                try? deterministic.write(
                    to: candidateDir.appending(path: "source_\(clip.id).txt"),
                    atomically: true, encoding: .utf8
                )
                let context = DictationContext(
                    targetBundleID: clip.targetBundleID,
                    vocabulary: terms
                )
                await polisher.prewarm()
                let started = ContinuousClock.now
                do {
                    let candidate = try await polisher.polish(deterministic, context: context)
                    let latency = started.duration(to: ContinuousClock.now).seconds
                    let validation = validator.validate(
                        source: deterministic, candidate: candidate, vocabulary: terms
                    )
                    try? candidate.write(
                        to: candidateDir.appending(path: "\(variant)_\(clip.id).txt"),
                        atomically: true, encoding: .utf8
                    )
                    rows.append(PolishRow(
                        id: clip.id, duration: clip.duration, variant: variant,
                        latency: latency, accepted: validation.isValid,
                        reason: validation.reason ?? "ok",
                        storedUsedLM: clip.usedLanguageModel,
                        rawChars: deterministic.count, candidateChars: candidate.count,
                        changeRatio: wordChangeRatio(deterministic, candidate)
                    ))
                    print(String(
                        format: "  %-14@ %5.1fs -> %5.3fs accepted=%@ storedLM=%@",
                        variant as NSString, clip.duration, latency,
                        (validation.isValid ? "Y" : "N") as NSString,
                        (clip.usedLanguageModel ? "Y" : "N") as NSString
                    ))
                } catch {
                    rows.append(PolishRow(
                        id: clip.id, duration: clip.duration, variant: variant,
                        latency: 0, accepted: false, reason: "error: \(error.localizedDescription)",
                        storedUsedLM: clip.usedLanguageModel,
                        rawChars: deterministic.count, candidateChars: 0,
                        changeRatio: -1
                    ))
                    print("  \(variant) \(clip.duration)s -> error: \(error.localizedDescription)")
                }
            }
        }

        let url = outDir.appending(path: "polish-results.json")
        try JSONEncoder.bench.encode(rows, to: url)
        print("wrote \(url.path)")
    }

    // MARK: - Kimi prompt-polish template iteration

    /// KIMI_API_KEY env var, or the key the app saved to the keychain
    /// (macOS may show a one-time access prompt for the bench binary).
    static func kimiAPIKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["KIMI_API_KEY"], !key.isEmpty {
            return key
        }
        guard let key = KimiAPIKeyStore.read(), !key.isEmpty else { return nil }
        return key
    }

    struct KimiPolishRow: Codable {
        let id: String
        let duration: TimeInterval
        let template: String
        let latency: TimeInterval
        let rawChars: Int
        let outChars: Int
        let error: String?
    }

    /// Replays cleaned historical transcripts through Kimi K2.7 HighSpeed with
    /// one or more candidate templates so the polish prompt can be iterated
    /// before it ships. Templates come from a JSON object {name: template},
    /// where each template contains a {text} placeholder.
    static func runKimiPolish(entries: [ManifestEntry], options: [String: String], outDir: URL) async throws {
        guard let apiKey = kimiAPIKey() else {
            throw BenchError.usage("KIMI_API_KEY not set and no key in the keychain (dev.localflow.app / kimi-api-key)")
        }
        let minDuration = TimeInterval(options["min-duration"] ?? "0") ?? 0
        let ids = (options["ids"] ?? "").split(separator: ",").map(String.init)
        let clips = entries
            .filter { $0.duration >= minDuration }
            .filter { clip in ids.isEmpty || ids.contains(where: { clip.id.hasPrefix($0) }) }
            .sorted { $0.duration > $1.duration }

        let templatesURL = URL(fileURLWithPath: options["templates"] ?? outDir.appending(path: "kimi-polish-templates.json").path)
        var templates: [String: String]
        if let data = try? Data(contentsOf: templatesURL) {
            templates = try JSONDecoder().decode([String: String].self, from: data)
        } else {
            templates = ["default": KimiPromptPolishClient.defaultTemplate]
            print("no templates file at \(templatesURL.path); using the built-in default template")
        }
        if let filter = options["variants"] {
            let wanted = Set(filter.split(separator: ",").map(String.init))
            templates = templates.filter { wanted.contains($0.key) }
        }
        // Comma-separated model IDs; result rows and output files are keyed
        // by "model+template" when more than one of either is in play.
        let models = (options["model"] ?? KimiPromptPolishClient.model)
            .split(separator: ",").map(String.init)
        // --effort low|high|max sends reasoning_effort; --thinking off sends
        // thinking:{type:disabled} (K2.x routes to K2.6 per Kimi docs).
        var reasoning = KimiReasoning.standard
        if options["effort"] != nil, options["thinking"] == "off" {
            throw BenchError.usage("--effort and --thinking off are mutually exclusive")
        }
        if let effort = options["effort"] { reasoning = .effort(effort) }
        if options["thinking"] == "off" { reasoning = .thinkingDisabled }
        let bodySuffix = (options["effort"].map { "-effort-\($0)" } ?? "")
            + (options["thinking"] == "off" ? "-nothink" : "")
        print("kimi-polish: \(clips.count) clips × \(templates.count) templates × models \(models) reasoning=\(reasoning)")

        let vocabulary = VocabularyParser.parse(CuratedVocabulary.source)
        let client = KimiPromptPolishClient()
        let candidateDir = outDir.appending(path: "kimi-polish")
        try? FileManager.default.createDirectory(at: candidateDir, withIntermediateDirectories: true)

        var rows: [KimiPolishRow] = []
        for model in models {
            for (name, template) in templates.sorted(by: { $0.key < $1.key }) {
                let label = "\(model)_\(name)" + bodySuffix
                for clip in clips {
                    let cleaned = DeterministicPromptCleaner.clean(clip.rawTranscript, vocabulary: vocabulary)
                    try? cleaned.write(
                        to: candidateDir.appending(path: "source_\(clip.id).txt"),
                        atomically: true, encoding: .utf8
                    )
                    let started = ContinuousClock.now
                    do {
                        let output = try await client.polish(
                            cleaned, template: template, model: model, apiKey: apiKey,
                            timeout: 180, reasoning: reasoning
                        )
                        let latency = started.duration(to: .now).seconds
                        try? output.write(
                            to: candidateDir.appending(path: "\(label)_\(clip.id).txt"),
                            atomically: true, encoding: .utf8
                        )
                        rows.append(KimiPolishRow(
                            id: clip.id, duration: clip.duration, template: label,
                            latency: latency, rawChars: cleaned.count, outChars: output.count,
                            error: nil
                        ))
                        print(String(
                            format: "  %-36@ %5.1fs -> %5.2fs %4d -> %4d chars  %@",
                            label as NSString, clip.duration, latency, cleaned.count, output.count,
                            String(clip.id.prefix(8)) as NSString
                        ))
                    } catch {
                        rows.append(KimiPolishRow(
                            id: clip.id, duration: clip.duration, template: label,
                            latency: 0, rawChars: cleaned.count, outChars: 0,
                            error: String(describing: error)
                        ))
                        print("  \(label) \(clip.id.prefix(8)) -> error: \(error)")
                    }
                }
            }
        }

        let url = outDir.appending(path: "kimi-polish-results.json")
        try JSONEncoder.bench.encode(rows, to: url)
        print("wrote \(url.path)")
    }

    /// Word-level edit distance normalized by length (0 = verbatim, 1 = fully rewritten).
    static func wordChangeRatio(_ a: String, _ b: String) -> Double {
        let wa = Array(a.split(whereSeparator: \.isWhitespace))
        let wb = Array(b.split(whereSeparator: \.isWhitespace))
        guard !wa.isEmpty || !wb.isEmpty else { return 0 }
        return Double(EditDistance.between(wa, wb)) / Double(max(wa.count, wb.count))
    }

    // MARK: - Vocabulary tuner acceptance

    /// Acceptance check: runs the production tuner over the record timeline.
    /// `--with-kimi 1` also runs the live Kimi judge (KIMI_API_KEY or keychain).
    static func runTune(options: [String: String]) async throws {
        let timelineURL = URL(fileURLWithPath: options["timeline"] ?? ".build/bench/timeline.json")
        let entries = try JSONDecoder().decode([TimelineEntry].self, from: Data(contentsOf: timelineURL))
        let texts = entries.map(\.text)
        let anchors = VocabularyParser.parse(CuratedVocabulary.source).map(\.preferred)
        let candidates = VocabularyTuner.candidates(in: texts, minimumCount: 1, anchors: anchors)
        print("tuner: \(texts.count) records -> \(candidates.count) candidates")

        let rules = VocabularyTuner.deterministicRules(candidates: candidates, anchors: anchors)
        print("\ndeterministic rules (\(rules.count)):")
        for rule in rules {
            print("  \(rule.heard) -> \(rule.preferred) (×\(rule.count))")
        }

        if options["with-kimi"] == "1" {
            guard let key = kimiAPIKey() else {
                throw BenchError.usage("KIMI_API_KEY not set and no key in the keychain")
            }
            let client = KimiTunerClient()
            let findings = try await client.judge(candidates: candidates, anchors: anchors, apiKey: key)
            let counts = Dictionary(uniqueKeysWithValues: candidates.map { ($0.term, $0.count) })
            let k3Rules = VocabularyTuner.anchorFilteredRules(
                findings: findings.map { ($0.heard, $0.meant) },
                anchors: anchors,
                counts: counts
            )
            print("\nk3 findings (\(findings.count)), accepted after anchor filter (\(k3Rules.count)):")
            for finding in findings {
                let accepted = k3Rules.contains { $0.heard == finding.heard && $0.preferred == finding.meant }
                print("  \(accepted ? "ACCEPT" : "REJECT") \(finding.heard) -> \(finding.meant)")
            }
        }
    }

    // MARK: - Vocabulary audit

    /// Per-term firing report for the curated vocabulary over the corpus.
    static func runVocab(entries: [ManifestEntry], outDir: URL) throws {
        let vocabulary = VocabularyParser.parse(CuratedVocabulary.source)
        struct TermStat: Codable {
            var fires = 0
            var contexts: [String] = []
        }
        var stats: [String: TermStat] = [:]
        var vocabChangedRecords = 0
        var cleanerChangedRecords = 0

        // Compile once per pattern, not once per pattern per record.
        var compiled: [(term: VocabularyParser.Entry, regexes: [NSRegularExpression])] = []
        for term in vocabulary {
            let regexes = (term.aliases + [term.preferred]).compactMap {
                try? NSRegularExpression(pattern: VocabularyParser.wordBoundaryPattern(for: $0))
            }
            compiled.append((term, regexes))
        }

        for entry in entries {
            let raw = entry.rawTranscript
            if VocabularyParser.normalize(raw, entries: vocabulary) != raw {
                vocabChangedRecords += 1
            }
            if DeterministicPromptCleaner.clean(raw, vocabulary: vocabulary) != raw {
                cleanerChangedRecords += 1
            }
            for (term, regexes) in compiled {
                for regex in regexes {
                    let range = NSRange(raw.startIndex..., in: raw)
                    for match in regex.matches(in: raw, range: range) {
                        guard let swiftRange = Range(match.range, in: raw) else { continue }
                        let found = String(raw[swiftRange])
                        guard found != term.preferred else { continue }
                        var stat = stats[term.preferred, default: TermStat()]
                        stat.fires += 1
                        if stat.contexts.count < 4 {
                            let lower = raw.index(swiftRange.lowerBound, offsetBy: -40, limitedBy: raw.startIndex) ?? raw.startIndex
                            let upper = raw.index(swiftRange.upperBound, offsetBy: 40, limitedBy: raw.endIndex) ?? raw.endIndex
                            stat.contexts.append("…\(raw[lower..<upper])…")
                        }
                        stats[term.preferred] = stat
                    }
                }
            }
        }

        print("records: \(entries.count); changed by vocabulary: \(vocabChangedRecords); changed by full cleaner: \(cleanerChangedRecords)")
        print("\nterm fires (preferred: count) — with example contexts:")
        for (preferred, stat) in stats.sorted(by: { $0.value.fires > $1.value.fires }) {
            print("\n\(preferred): \(stat.fires)")
            for context in stat.contexts { print("   \(context)") }
        }
        let neverFired = vocabulary.map(\.preferred).filter { stats[$0] == nil }
        print("\nnever fired (\(neverFired.count)/\(vocabulary.count)): \(neverFired.joined(separator: ", "))")

        let url = outDir.appending(path: "vocab-audit.json")
        try JSONEncoder.bench.encode(stats, to: url)
        print("\nwrote \(url.path)")
    }

    // MARK: - Overhead micro-benchmarks

    static func runOverhead(entries: [ManifestEntry], outDir: URL) throws {
        // 1. CAF save cost (AudioFileStore.save runs on the main actor before inference).
        guard let longest = entries.filter({ $0.audio != nil }).max(by: { $0.duration < $1.duration }),
              let audioPath = longest.audio else {
            throw BenchError.usage("no clips in manifest")
        }
        let samples = try loadSamples(audioPath)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        var saveTimes: [TimeInterval] = []
        for rep in 0..<10 {
            let url = outDir.appending(path: "overhead-\(rep).caf")
            let started = ContinuousClock.now
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
            )!
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
            saveTimes.append(started.duration(to: ContinuousClock.now).seconds)
            try? FileManager.default.removeItem(at: url)
        }
        print(String(
            format: "CAF save (%.1fs audio, %d samples): median %.1f ms over 10 reps",
            longest.duration, samples.count, median(saveTimes) * 1000
        ))

        // 2. Resample 48k -> 16k + trim cost at key release.
        for seconds in [10.0, 30.0, 60.0, 120.0] {
            let count = Int(48_000 * seconds)
            let source = (0..<count).map { index in
                Float(sin(Double(index) * 0.05)) * 0.3
            }
            var times: [TimeInterval] = []
            for _ in 0..<5 {
                let started = ContinuousClock.now
                let converted = try AudioResampler.convert(source, from: 48_000)
                _ = try AudioTrimmer.trim(converted)
                times.append(started.duration(to: ContinuousClock.now).seconds)
            }
            print(String(
                format: "resample+trim %4.0fs audio: median %.1f ms over 5 reps",
                seconds, median(times) * 1000
            ))
        }
    }

    static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

private extension JSONEncoder {
    static var bench: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    func encode<T: Encodable>(_ value: T, to url: URL) throws {
        try encode(value).write(to: url)
    }
}
