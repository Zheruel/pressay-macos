@preconcurrency import AVFoundation
import Foundation
import OSLog
import PressayCore
import PressayTranscription

/// A voice note or meeting, transcribed on-device utterance by utterance. No audio is kept.
@MainActor
final class LiveSession: ObservableObject {
    enum Phase: Equatable {
        case recording
        case finishing
    }

    let noteID: UUID
    let kind: Note.Kind
    /// Start on the note's timeline, so multi-sitting notes keep one clock.
    let offset: TimeInterval
    let startedAt: Date

    @Published private(set) var stoppedAt: Date?
    @Published private(set) var phase: Phase = .recording
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var othersLevel: Float = 0
    @Published private(set) var pending = 0
    @Published var notice: String?
    var createdNote = false
    /// Started from a detected call, so the call ending may stop it.
    var fromCall = false

    var onLine: ((TranscriptLine) -> Void)?
    /// Test hook: the injected file has played to the end.
    var onInjectedFileEnd: (() -> Void)?

    private var mic = LiveMicCapture()
    private let system: SystemAudioCapture?
    private let voices: VoiceSeparator?
    private let pipeline: SegmentPipeline
    private let logger = Logger(subsystem: "dev.localflow.app", category: "meeting")

    init(
        noteID: UUID,
        kind: Note.Kind,
        offset: TimeInterval,
        transcriber: any SpeechTranscriber,
        vocabulary: [VocabularyParser.Entry],
        inputUID: String?,
        captureSystemAudio: Bool,
        separateVoices: Bool = false,
        startedAt: Date = .now
    ) throws {
        self.startedAt = startedAt
        self.noteID = noteID
        self.kind = kind
        self.offset = offset
        system = kind == .meeting && captureSystemAudio ? SystemAudioCapture() : nil
        voices = system != nil && separateVoices ? VoiceSeparator() : nil

        let (stream, continuation) = AsyncStream<SegmentPipeline.Item>.makeStream()
        pipeline = SegmentPipeline(continuation: continuation, detector: kind == .meeting ? SpeechDetector.make() : nil)
        if let voices {
            pipeline.othersTap = { voices.append($0) }
        }
        workerTask = Task { [weak self] in
            for await item in stream {
                let clip = AudioClip(samples: item.segment.samples)
                let text: String
                do {
                    text = try await transcriber.transcribe(clip).text
                } catch {
                    self?.logger.error("Live segment failed: \(error.localizedDescription, privacy: .public)")
                    self?.pending -= 1
                    continue
                }
                let cleaned = DeterministicPromptCleaner.clean(text, vocabulary: vocabulary, englishRules: SpeechLanguage.usesEnglishRules(text))
                guard let self, !Task.isCancelled else { continue }
                pending -= 1
                guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let start = offset + item.segment.start
                let line = TranscriptLine(speaker: item.speaker, start: start, text: cleaned, end: start + item.segment.duration)
                let index = lines.firstIndex { $0.start > line.start } ?? lines.endIndex
                lines.insert(line, at: index)
                onLine?(line)
            }
        }

        pipeline.onQueued = { [weak self] in
            Task { @MainActor in self?.pending += 1 }
        }
        pipeline.onLevel = { [weak self] speaker, level in
            Task { @MainActor in
                guard let self else { return }
                if speaker == .me { self.micLevel = level } else { self.othersLevel = level }
            }
        }
        mic.onSamples = { [pipeline] in pipeline.append($0, from: .me) }
        #if DEBUG
        if DesignReview.enabled {
            lines = [.init(speaker: .me, start: 0, text: "Let’s start with the first-time experience."),
                     .init(speaker: .others, start: 4, text: "I think we should keep the setup to a few simple steps.")]
            micLevel = 0.7
            return
        }
        #endif
        // Echo cancellation keeps speaker output out of "Me".
        do {
            try mic.start(echoCancellation: kind == .meeting, preferredInputUID: inputUID)
        } catch where kind == .meeting {
            logger.notice("Echo cancellation unavailable, recording the mic plain: \(error.localizedDescription, privacy: .public)")
            mic.stop()
            try mic.start(echoCancellation: false, preferredInputUID: inputUID)
        }
        if kind == .meeting { watchForSilentMic(inputUID: inputUID) }
        #if DEBUG
        let injected = ProcessInfo.processInfo.environment["PRESSAY_LIVE_FILE"].flatMap { kind == .meeting ? $0 : nil }
        #else
        let injected: String? = nil
        #endif
        if let path = injected {
            // Test hook: plays a file into "Others" in real time, silently.
            injectFile(path)
        } else if let system {
            system.onSamples = { [pipeline] in pipeline.append($0, from: .others) }
            do {
                try system.start()
                watchForMissingSystemAudio()
            } catch {
                logger.error("System audio unavailable: \(error.localizedDescription, privacy: .public)")
                notice = "Only your microphone is being recorded: Pressay couldn’t capture the call’s audio."
            }
        }
    }

    private var workerTask: Task<Void, Never>?

    /// Echo cancellation yields digital silence on some inputs (AirPods); restart without it.
    private func watchForSilentMic(inputUID: String?) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, phase == .recording, pipeline.received(from: .me) >= 16_000, pipeline.peak(of: .me) == 0 else { return }
            logger.notice("Echo-cancelled mic is silent; restarting it plain")
            mic.stop()
            let plain = LiveMicCapture()
            plain.onSamples = { [pipeline] in pipeline.append($0, from: .me) }
            do {
                try plain.start(echoCancellation: false, preferredInputUID: inputUID)
                mic = plain
            } catch {
                notice = "Your microphone stopped responding. Only the call’s audio is being transcribed."
            }
        }
    }

    /// Without System Audio Recording permission the tap delivers exact zeros, with no error.
    private func watchForMissingSystemAudio() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, phase == .recording else { return }
            if pipeline.received(from: .others) == 0 { return showMissingSystemAudio() }
            try? await Task.sleep(for: .seconds(86))
            guard phase == .recording, pipeline.peak(of: .others) == 0 else { return }
            logger.error("System audio has been digital silence for 90 s")
            showMissingSystemAudio()
        }
    }

    private func showMissingSystemAudio() {
        notice = "Only your microphone is being transcribed. To include the other people, allow Pressay in System Settings › Privacy & Security › Screen & System Audio Recording, under System Audio Recording Only."
    }

    private func injectFile(_ path: String) {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return }
        let mono = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        let samples = StreamResampler().convert(mono, rate: file.processingFormat.sampleRate)
        let speed = ProcessInfo.processInfo.environment["PRESSAY_LIVE_SPEED"].flatMap(Double.init) ?? 1
        Task.detached { [pipeline] in
            for chunk in stride(from: 0, to: samples.count, by: 1_600) {
                pipeline.append(Array(samples[chunk..<min(chunk + 1_600, samples.count)]), from: .others)
                try? await Task.sleep(for: .milliseconds(100 / speed))
            }
            await MainActor.run { [weak self] in self?.onInjectedFileEnd?() }
        }
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    func finish() async -> [TranscriptLine] {
        guard phase == .recording else { return lines }
        stoppedAt = stoppedAt ?? .now
        phase = .finishing
        mic.stop()
        system?.stop()
        await pipeline.finish()
        await workerTask?.value
        if let voices {
            let turns = await voices.finish().map { VoiceTurn(start: offset + $0.start, end: offset + $0.end, speaker: $0.speaker) }
            lines = VoiceLabeler.label(lines, turns: turns)
            logger.info("Told apart \(Set(self.lines.compactMap(\.voice)).count, privacy: .public) voices")
        }
        return lines
    }

    /// Stops at once and drops whatever was still being transcribed.
    func discard() {
        stoppedAt = stoppedAt ?? .now
        phase = .finishing
        onLine = nil
        mic.stop()
        system?.stop()
        pipeline.cancel()
        workerTask?.cancel()
        voices?.cancel()
    }
}

/// Owns the segmenters off the main thread; fed from real-time audio threads.
final class SegmentPipeline: @unchecked Sendable {
    struct Item: Sendable {
        let speaker: TranscriptLine.Speaker
        let segment: SpeechSegmenter.Segment
    }

    private let queue = DispatchQueue(label: "dev.localflow.app.segmenter", qos: .userInitiated)
    private var levelSamples: [TranscriptLine.Speaker: (sum: Float, count: Int)] = [:]
    private let continuation: AsyncStream<Item>.Continuation
    private var finished = false
    private var stats: [TranscriptLine.Speaker: (samples: Int, peak: Float, segments: Int)] = [:]
    private let logger = Logger(subsystem: "dev.localflow.app", category: "meeting")

    var onQueued: (@Sendable () -> Void)?
    /// Sees every "Others" sample in order, on the segmenter queue.
    var othersTap: (@Sendable ([Float]) -> Void)?
    var onLevel: (@Sendable (TranscriptLine.Speaker, Float) -> Void)?

    /// Audio waiting for the voice activity model, in arrival order.
    private let audio: AsyncStream<(TranscriptLine.Speaker, [Float])>.Continuation
    private var segmenting: Task<Void, Never>?

    init(continuation: AsyncStream<Item>.Continuation, detector: SpeechDetector? = nil) {
        self.continuation = continuation
        let (stream, audio) = AsyncStream<(TranscriptLine.Speaker, [Float])>.makeStream()
        self.audio = audio
        segmenting = Task.detached(priority: .userInitiated) { [self] in
            var segmenters: [TranscriptLine.Speaker: SpeechSegmenter] = [:]
            var buffers: [TranscriptLine.Speaker: [Float]] = [:]
            func feed(_ chunk: [Float], _ speaker: TranscriptLine.Speaker, speech: Bool?) {
                var segmenter = segmenters[speaker] ?? Self.makeSegmenter()
                for segment in segmenter.append(chunk, speech: speech) { emit(segment, speaker) }
                segmenters[speaker] = segmenter
            }
            for await (speaker, samples) in stream {
                var buffer = buffers[speaker, default: []] + samples
                while buffer.count >= SpeechDetector.chunk {
                    let chunk = Array(buffer.prefix(SpeechDetector.chunk))
                    buffer.removeFirst(SpeechDetector.chunk)
                    feed(chunk, speaker, speech: await detector?.isSpeech(chunk, from: speaker))
                }
                buffers[speaker] = buffer
            }
            guard !Task.isCancelled else { return }
            for (speaker, rest) in buffers where !rest.isEmpty { feed(rest, speaker, speech: nil) }
            for (speaker, var segmenter) in segmenters {
                if let last = segmenter.finish() { emit(last, speaker) }
            }
            continuation.finish()
        }
    }

    func append(_ samples: [Float], from speaker: TranscriptLine.Speaker) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            guard !finished else { return }
            var stat = stats[speaker] ?? (0, 0, 0)
            stat.samples += samples.count
            stat.peak = max(stat.peak, samples.reduce(0) { max($0, abs($1)) })
            stats[speaker] = stat
            if speaker == .others { othersTap?(samples) }
            audio.yield((speaker, samples))

            var level = levelSamples[speaker] ?? (0, 0)
            level.sum += samples.reduce(0) { $0 + $1 * $1 }
            level.count += samples.count
            if level.count >= 1_300 {
                let rms = (level.sum / Float(level.count)).squareRoot()
                onLevel?(speaker, min(1, rms * 8))
                level = (0, 0)
            }
            levelSamples[speaker] = level
        }
    }

    func received(from speaker: TranscriptLine.Speaker) -> Int {
        queue.sync { stats[speaker]?.samples ?? 0 }
    }

    func peak(of speaker: TranscriptLine.Speaker) -> Float {
        queue.sync { stats[speaker]?.peak ?? 0 }
    }

    /// Flushes what's still being segmented, then ends the stream of segments.
    func finish() async {
        let first = queue.sync {
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        audio.finish()
        await segmenting?.value
        queue.sync {
            for (speaker, stat) in stats {
                logger.info("\(speaker.rawValue, privacy: .public): \(Double(stat.samples) / 16_000, privacy: .public)s peak \(stat.peak, privacy: .public) segments \(stat.segments, privacy: .public)")
            }
        }
    }

    /// Stops at once, dropping audio not yet segmented.
    func cancel() {
        queue.sync { finished = true }
        segmenting?.cancel()
        audio.finish()
        continuation.finish()
    }

    private func emit(_ segment: SpeechSegmenter.Segment, _ speaker: TranscriptLine.Speaker) {
        queue.async { [self] in stats[speaker, default: (0, 0, 0)].segments += 1 }
        onQueued?()
        continuation.yield(Item(speaker: speaker, segment: segment))
    }

    /// 12 s keeps the transcript live with enough context to spell names consistently.
    private static func makeSegmenter() -> SpeechSegmenter {
        var segmenter = SpeechSegmenter()
        segmenter.maximumLength = 12
        return segmenter
    }
}
