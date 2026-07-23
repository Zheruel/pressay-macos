import AVFoundation
import Foundation
import PressayCore
import PressayPostProcessing
import PressayTranscription

// PressayBench — dev-only evaluation harness.
// Subcommands: asr | structure | overhead | vocab | tune | tune-eval |
// manifest-from-audio (see the usage errors of each for options).

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

struct StructureRow: Codable {
    let id: String
    let duration: TimeInterval
    let candidate: String
    let latency: TimeInterval
    let changed: Bool
    let idempotent: Bool
    let validatorPassed: Bool
    let paragraphs: Int
    let bulletLines: Int
    let error: String?
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
            throw BenchError.usage("expected subcommand: asr | structure | overhead | vocab | tune | tune-eval | manifest-from-audio")
        }
        let options = parseOptions(Array(args.dropFirst()))
        let manifestURL = URL(fileURLWithPath: options["manifest"] ?? ".build/bench/manifest.json")
        let outDir = manifestURL.deletingLastPathComponent()
        // Manifest-free subcommands must run before decoding: manifest-from-audio
        // exists to create the file the others read.
        func entries() throws -> [ManifestEntry] {
            try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: manifestURL))
        }

        switch command {
        case "asr":
            try await runASR(entries: entries(), options: options, outDir: outDir)
        case "structure":
            try await runStructure(entries: entries(), options: options, outDir: outDir)
        case "overhead":
            try runOverhead(entries: entries(), outDir: outDir)
        case "vocab":
            try runVocab(entries: entries(), outDir: outDir)
        case "tune":
            try await runTune(options: options)
        case "tune-eval":
            try await runTuneEval(options: options, outDir: outDir)
        case "manifest-from-audio":
            try runManifestFromAudio(options: options, manifestURL: manifestURL)
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

    // MARK: - Manifest from audio

    /// Builds a manifest straight from the stored audio clips. Raw transcripts
    /// stay empty; `structure` fills them from its transcription cache.
    static func runManifestFromAudio(options: [String: String], manifestURL: URL) throws {
        let audioDir = URL(fileURLWithPath: options["audio-dir"]
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Pressay/Audio").path)
        let files = try FileManager.default
            .contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "caf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            throw BenchError.usage("no .caf clips in \(audioDir.path)")
        }
        var entries: [ManifestEntry] = []
        for file in files {
            let audioFile = try AVAudioFile(forReading: file)
            let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            entries.append(ManifestEntry(
                id: file.deletingPathExtension().lastPathComponent,
                duration: duration,
                asrLatency: 0, polishLatency: 0, totalLatency: 0,
                rawTranscript: "", polishedText: "", usedLanguageModel: false,
                audio: file.path, targetBundleID: nil
            ))
        }
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder.bench.encode(entries, to: manifestURL)
        print("wrote \(manifestURL.path): \(entries.count) clips from \(audioDir.path)")
    }

    // MARK: - Structuring bake-off

    /// Runs the structuring candidates side by side over the corpus: "rules"
    /// (TranscriptStructurer, always) and "apple" (on-device FoundationModels
    /// formatter, `--with-apple 1`). Transcripts come from the manifest's
    /// stored rawTranscript or, when empty, from transcribing the clip once
    /// into structure-transcripts.json so iteration on the rules is instant.
    /// Output: review.md (side-by-side blocks) + structure-results.json.
    static func runStructure(entries: [ManifestEntry], options: [String: String], outDir: URL) async throws {
        let minDuration = TimeInterval(options["min-duration"] ?? "0") ?? 0
        let maxClips = Int(options["max-clips"] ?? "0") ?? 0
        let withApple = options["with-apple"] == "1"
        let showAll = options["all"] == "1"
        let language = options["language"] ?? "en"

        var clips = entries.filter { $0.duration >= minDuration }
        if maxClips > 0 { clips = Array(clips.prefix(maxClips)) }

        // Phase A: a transcript for every clip, cached across runs.
        let cacheURL = outDir.appending(path: "structure-transcripts.json")
        var cache = (try? JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: cacheURL)
        )) ?? [:]
        var transcriber: GGMLTranscriber?
        var texts: [(entry: ManifestEntry, text: String)] = []
        for clip in clips {
            if !clip.rawTranscript.isEmpty {
                texts.append((clip, clip.rawTranscript))
            } else if let cached = cache[clip.id] {
                texts.append((clip, cached))
            } else if let audio = clip.audio, FileManager.default.fileExists(atPath: audio) {
                if transcriber == nil {
                    let engine = GGMLTranscriber(model: .whisperTurboGGML, language: language)
                    try await engine.prepare()
                    transcriber = engine
                    print("transcribing uncached clips…")
                }
                let transcript = try await transcriber!.transcribe(
                    AudioClip(samples: try loadSamples(audio))
                )
                cache[clip.id] = transcript.text
                try JSONEncoder.bench.encode(cache, to: cacheURL)
                texts.append((clip, transcript.text))
                print(String(format: "  %5.1fs  %@", clip.duration, String(clip.id.prefix(8))))
            }
        }
        print("structure bake-off: \(texts.count) transcripts (\(withApple ? "rules + apple" : "rules only"))")

        // Phase B: candidates over the cleaned transcripts.
        let vocabulary = VocabularyParser.parse(CuratedVocabulary.source)
        let terms = vocabulary.map(\.preferred)
        let validator = ProtectedTokenValidator()
        let polisher = withApple ? ApplePromptPolisher(mode: .structure) : nil
        if let polisher {
            print("apple availability: \(await polisher.availabilityDescription)")
        }

        var rows: [StructureRow] = []
        var review = "# Structuring bake-off review\n"
        for (clip, raw) in texts {
            let cleaned = DeterministicPromptCleaner.clean(raw, vocabulary: vocabulary)

            var outputs: [(candidate: String, text: String, latency: TimeInterval, error: String?)] = []
            let rulesStarted = ContinuousClock.now
            let ruled = TranscriptStructurer.structure(cleaned)
            outputs.append(("rules", ruled, rulesStarted.duration(to: .now).seconds, nil))

            if let polisher {
                await polisher.prewarm()
                let started = ContinuousClock.now
                do {
                    let candidate = try await polisher.polish(
                        cleaned, context: DictationContext(targetBundleID: nil, vocabulary: terms)
                    )
                    outputs.append(("apple", candidate, started.duration(to: .now).seconds, nil))
                } catch {
                    outputs.append(("apple", cleaned, 0, String(describing: error)))
                }
            }

            var anyChanged = false
            for output in outputs {
                let validation = validator.validate(
                    source: cleaned, candidate: output.text, vocabulary: terms
                )
                let idempotent = output.candidate != "rules"
                    || TranscriptStructurer.structure(output.text) == output.text
                let changed = output.text != cleaned
                anyChanged = anyChanged || changed
                rows.append(StructureRow(
                    id: clip.id, duration: clip.duration, candidate: output.candidate,
                    latency: output.latency, changed: changed, idempotent: idempotent,
                    validatorPassed: validation.isValid,
                    paragraphs: output.text.components(separatedBy: "\n\n").count,
                    bulletLines: output.text.components(separatedBy: "\n")
                        .filter { $0.hasPrefix("- ") }.count,
                    error: output.error
                ))
            }

            if anyChanged || showAll {
                review += "\n---\n\n## \(clip.id.prefix(8)) · \(String(format: "%.1f", clip.duration))s\n"
                review += "\n**RAW (cleaned)**\n\n```\n\(cleaned)\n```\n"
                for output in outputs {
                    let label = output.candidate.uppercased()
                    if let error = output.error {
                        review += "\n**\(label)** — error: \(error)\n"
                    } else {
                        review += "\n**\(label)**\n\n```\n\(output.text)\n```\n"
                    }
                }
            }
        }

        for candidate in Set(rows.map(\.candidate)).sorted() {
            let mine = rows.filter { $0.candidate == candidate }
            let changed = mine.filter(\.changed).count
            let validatorFailures = mine.filter { !$0.validatorPassed }.count
            let idempotencyFailures = mine.filter { !$0.idempotent }.count
            let errors = mine.filter { $0.error != nil }.count
            print(String(
                format: "%-6@ changed %d/%d · validator failures %d · idempotency failures %d · errors %d · median latency %.0f ms",
                candidate as NSString, changed, mine.count,
                validatorFailures, idempotencyFailures, errors,
                median(mine.map(\.latency)) * 1000
            ))
        }

        let reviewURL = outDir.appending(path: "review.md")
        try review.write(to: reviewURL, atomically: true, encoding: .utf8)
        let resultsURL = outDir.appending(path: "structure-results.json")
        try JSONEncoder.bench.encode(rows, to: resultsURL)
        print("wrote \(reviewURL.path) and \(resultsURL.path)")
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

    // MARK: - Tuner variant evaluation

    /// Replays the corpus through the tuner variants so their proposals can be
    /// hand-labeled and compared:
    ///   det-legacy   the pre-fix deterministic matcher (regression witness)
    ///   det-fixed    the shipping matcher (DetConfig.fixed)
    ///   k3           the Kimi judge over all candidates (--with-kimi 1)
    ///   k3-residual  the Kimi judge over candidates det-fixed left unresolved
    ///                — its marginal contribution, the number that decides
    ///                whether the LLM stage earns its keep.
    /// Texts come from --asr-results (rep-1 rows), --timeline, or the
    /// structure cache; --include-seen 1 adds the app's seenCandidates.
    /// --labels file.tsv ("heard<TAB>good|bad") prints per-variant precision.
    static func runTuneEval(options: [String: String], outDir: URL) async throws {
        var texts: [String] = []
        if let path = options["asr-results"] {
            let rows = try JSONDecoder().decode([ASRRow].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            texts += rows.filter { $0.rep == 1 && $0.error == nil }.map(\.text)
        }
        if let path = options["timeline"] {
            let rows = try JSONDecoder().decode([TimelineEntry].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            texts += rows.map(\.text)
        }
        if options["use-structure-cache"] == "1" {
            let cacheURL = outDir.appending(path: "structure-transcripts.json")
            let cache = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: cacheURL))
            texts += cache.values
        }
        guard !texts.isEmpty else {
            throw BenchError.usage("tune-eval needs texts: --asr-results, --timeline, or --use-structure-cache 1")
        }

        let anchors = VocabularyParser.parse(CuratedVocabulary.source).map(\.preferred)
        var candidates = VocabularyTuner.candidates(in: texts, minimumCount: 1, anchors: anchors)
        if options["include-seen"] == "1" {
            let seen = UserDefaults(suiteName: "dev.localflow.app")?
                .stringArray(forKey: "vocabularyTuner.seenCandidates") ?? []
            let known = Set(candidates.map { $0.term.lowercased() })
            candidates += seen
                .filter { !known.contains($0.lowercased()) }
                .map { TunerCandidate(term: $0, count: 1, excerpt: "(seenCandidates)") }
        }
        print("tune-eval: \(texts.count) texts -> \(candidates.count) candidates")

        // Full candidate dump for external judges (e.g. replaying the K3
        // prompt through another model): term, count, excerpt per line.
        if let dumpPath = options["candidates-out"] {
            struct CandidateDump: Codable {
                let term: String
                let count: Int
                let excerpt: String
            }
            let dump = candidates.map { CandidateDump(term: $0.term, count: $0.count, excerpt: $0.excerpt) }
            try JSONEncoder.bench.encode(dump, to: URL(fileURLWithPath: dumpPath))
            print("wrote \(dumpPath) (\(dump.count) candidates)")
        }

        func ruleMap(_ rules: [LearnedRule]) -> [String: String] {
            Dictionary(rules.map { ($0.heard.lowercased(), $0.preferred) }) { first, _ in first }
        }
        let legacy = ruleMap(VocabularyTuner.deterministicRules(
            candidates: candidates, anchors: anchors, config: .legacy
        ))
        let fixed = ruleMap(VocabularyTuner.deterministicRules(
            candidates: candidates, anchors: anchors, config: .fixed
        ))

        var k3: [String: String] = [:]
        var k3Residual: [String: String] = [:]
        if options["with-kimi"] == "1" {
            guard let key = kimiAPIKey() else {
                throw BenchError.usage("KIMI_API_KEY not set and no key in the keychain")
            }
            let client = KimiTunerClient()
            let counts = Dictionary(candidates.map { ($0.term, $0.count) }) { first, _ in first }
            func judge(_ subset: [TunerCandidate]) async throws -> [String: String] {
                guard !subset.isEmpty else { return [:] }
                let findings = try await client.judge(candidates: subset, anchors: anchors, apiKey: key)
                return ruleMap(VocabularyTuner.anchorFilteredRules(
                    findings: findings.map { ($0.heard, $0.meant) },
                    anchors: anchors,
                    counts: counts
                ))
            }
            k3 = try await judge(candidates)
            k3Residual = try await judge(candidates.filter { fixed[$0.term.lowercased()] == nil })
        }

        // Review artifact: every candidate any variant proposed a rule for.
        var lines = ["heard\tproposed\tcount\texcerpt\tdet-legacy\tdet-fixed\tk3\tk3-residual"]
        var proposedTerms: [String] = []
        for candidate in candidates {
            let fold = candidate.term.lowercased()
            let proposals = [legacy[fold], fixed[fold], k3[fold], k3Residual[fold]]
            guard let proposed = proposals.compactMap({ $0 }).first else { continue }
            proposedTerms.append(fold)
            lines.append([
                candidate.term,
                proposed,
                String(candidate.count),
                candidate.excerpt.replacingOccurrences(of: "\t", with: " "),
                legacy[fold] != nil ? "Y" : "N",
                fixed[fold] != nil ? "Y" : "N",
                k3[fold] != nil ? "Y" : "N",
                k3Residual[fold] != nil ? "Y" : "N",
            ].joined(separator: "\t"))
        }
        let reviewURL = outDir.appending(path: "tune-eval-review.tsv")
        try lines.joined(separator: "\n").write(to: reviewURL, atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
        print("\nwrote \(reviewURL.path) (\(proposedTerms.count) proposed rules)")

        if let labelsPath = options["labels"] {
            let labelLines = try String(contentsOf: URL(fileURLWithPath: labelsPath), encoding: .utf8)
                .split(separator: "\n")
            var labels: [String: Bool] = [:]
            for line in labelLines {
                let parts = line.split(separator: "\t")
                guard parts.count >= 2 else { continue }
                labels[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) == "good"
            }
            print("\nprecision over \(labels.count) labeled terms:")
            for (name, variant) in [("det-legacy", legacy), ("det-fixed", fixed), ("k3", k3), ("k3-residual", k3Residual)] {
                let judged = variant.keys.compactMap { labels[$0] }
                guard !judged.isEmpty else {
                    print("  \(name): no labeled proposals")
                    continue
                }
                let good = judged.filter { $0 }.count
                print(String(format: "  %-11@ %d/%d good (%.0f%%)", name as NSString, good, judged.count, 100 * Double(good) / Double(judged.count)))
            }
            let unique = k3Residual.keys.filter { labels[$0] == true && fixed[$0] == nil && legacy[$0] == nil }
            print("  true rules unique to k3: \(unique.count)\(unique.isEmpty ? "" : " — \(unique.sorted().joined(separator: ", "))")")
        }
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
