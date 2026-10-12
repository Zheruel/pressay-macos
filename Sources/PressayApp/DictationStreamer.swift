import Foundation
import OSLog
import PressayCore
import PressayTranscription

/// Transcribes a long dictation while it is still being spoken. Once the open piece is 8 s long, the next
/// half-second pause closes it and it is transcribed in the background, so release only waits for the tail.
/// On 158 AMI excerpts this matched whole-clip accuracy (28.1% vs 28.2% WER) and cut the wait on clips
/// over 20 s from 1.0 s to 0.4 s (p90 1.9 s to 1.0 s). Anything unexpected falls back to the whole clip.
actor DictationStreamer {
    static let minimumPiece: TimeInterval = 8
    static let pause: TimeInterval = 0.5

    private let engine: any SpeechTranscriber
    private let detector: SpeechDetector
    private let audio: @Sendable (Int) -> AudioRecorder.LiveAudio?
    private let logger = Logger(subsystem: "dev.localflow.app", category: "audio")

    private var loop: Task<Void, Never>?
    private var stopping = false
    private var broken = false
    private var rate: Double = 0
    /// Raw (device-rate) samples: where the open piece starts, and how far the detector has heard.
    private var pieceStart = 0
    private var heard = 0
    /// 16 kHz bookkeeping for the detector.
    private var unjudged: [Float] = []
    private var judged = 0
    private var pieceStart16 = 0
    private var silentChunks = 0
    private var pieceHasSpeech = false
    private var texts: [String] = []

    init(engine: any SpeechTranscriber, detector: SpeechDetector, audio: @escaping @Sendable (Int) -> AudioRecorder.LiveAudio?) {
        self.engine = engine
        self.detector = detector
        self.audio = audio
    }

    func start() async {
        await detector.reset(.me)
        loop = Task { [weak self] in
            while let self, await self.step() {
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// The transcript, or nil when nothing was cut (or something went wrong) and the whole clip should be transcribed.
    func finish(_ capture: AudioRecorder.RawCapture) async -> ASRTranscript? {
        stopping = true
        await loop?.value
        guard !broken, !texts.isEmpty, capture.segments.count == 1, let segment = capture.segments.first,
              segment.sampleRate == rate, pieceStart <= segment.samples.count
        else { return nil }
        let started = Date()
        do {
            let tail = try AudioResampler.convert(Array(segment.samples[pieceStart...]), from: rate)
            var last = ""
            if let trimmed = try? AudioTrimmer.trim(tail) {
                last = try await transcribe(trimmed)
            }
            let text = AudioChunking.join(texts + [last])
            guard !text.isEmpty else { return nil }
            logger.info("Streamed dictation: \(self.texts.count + 1, privacy: .public) pieces, tail \(Double(tail.count) / 16_000, privacy: .public)s")
            return ASRTranscript(text: text, processingTime: Date().timeIntervalSince(started))
        } catch {
            logger.error("Streamed tail failed, transcribing the whole clip: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func cancel() {
        stopping = true
        loop?.cancel()
    }

    /// One poll: judge new audio, and transcribe a piece if a pause closed one. False to stop.
    private func step() async -> Bool {
        guard !stopping, !broken, let live = audio(heard) else { return false }
        rate = live.sampleRate
        guard !live.samples.isEmpty else { return true }
        heard += live.samples.count
        do {
            unjudged += try AudioResampler.convert(live.samples, from: rate)
        } catch {
            broken = true
            return false
        }
        let chunk = SpeechDetector.chunk
        let pauseChunks = Int((Self.pause * 16_000 / Double(chunk)).rounded(.up))
        while unjudged.count >= chunk, !stopping {
            let piece = Array(unjudged.prefix(chunk))
            unjudged.removeFirst(chunk)
            // No model (yet): stop cutting; release transcribes from the last cut, or the whole clip.
            guard let speech = await detector.isSpeech(piece, from: .me) else { return false }
            judged += chunk
            silentChunks = speech ? 0 : silentChunks + 1
            pieceHasSpeech = pieceHasSpeech || speech
            guard silentChunks >= pauseChunks,
                  Double(judged - pieceStart16) / 16_000 >= Self.minimumPiece
            else { continue }
            // Cut in the middle of the pause.
            let cut16 = judged - silentChunks * chunk / 2
            await close(at: Int((Double(cut16) * rate / 16_000).rounded()), cut16: cut16, earcon: live.earconWindow)
            if broken { return false }
        }
        return true
    }

    private func close(at cut: Int, cut16: Int, earcon: Range<TimeInterval>?) async {
        let hadSpeech = pieceHasSpeech
        let first = texts.isEmpty && pieceStart == 0
        defer {
            pieceStart = cut
            pieceStart16 = cut16
            silentChunks = 0
            pieceHasSpeech = false
        }
        guard let live = audio(pieceStart), cut > pieceStart, cut - pieceStart <= live.samples.count else {
            broken = true
            return
        }
        guard hadSpeech else {
            texts.append("")
            return
        }
        do {
            var samples = try AudioResampler.convert(Array(live.samples[..<(cut - pieceStart)]), from: rate)
            if first {
                // Same onset trim as the whole clip, skipping the start cue.
                let guardRange = earcon.map { Int($0.lowerBound * 16_000)..<Int($0.upperBound * 16_000) }
                guard let trimmed = try? AudioTrimmer.trim(samples, earconGuard: guardRange) else {
                    texts.append("")
                    return
                }
                samples = trimmed
            }
            texts.append(try await transcribe(samples))
        } catch {
            logger.error("Streamed piece failed: \(error.localizedDescription, privacy: .public)")
            broken = true
        }
    }

    private func transcribe(_ samples: [Float]) async throws -> String {
        let clip = AudioClip(samples: samples)
        do {
            return try await Timeout.run(for: .seconds(DictationProcessingPolicy.asrTimeout(duration: clip.duration))) { [engine] in
                try await engine.transcribe(clip).text
            }
        } catch PressayError.emptyTranscript {
            return ""
        }
    }
}
