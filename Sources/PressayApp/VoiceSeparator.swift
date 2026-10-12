import FluidAudio
import Foundation
import OSLog
import PressayCore

/// Tells the other people on a call apart, on-device, with LS-EEND (AMI variant, up to 4 voices).
/// Fed the same 16 kHz "Others" audio as the transcriber, so its clock matches the transcript's.
final class VoiceSeparator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.localflow.app.voices", qos: .utility)
    private var diarizer: LSEENDDiarizer?
    /// Audio that arrived while the model was loading.
    private var backlog: [Float] = []
    private var failed = false
    private var loaded = false
    private var finished = false
    private let logger = Logger(subsystem: "dev.localflow.app", category: "meeting")

    /// Ten minutes; a model that takes longer to arrive isn't worth holding more audio for.
    private static let maximumBacklog = 16_000 * 600

    static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pressay/Models/Diarization", directoryHint: .isDirectory)
    }

    init() {
        Task.detached(priority: .utility) { [self] in
            do {
                // The first meeting downloads the model (about 40 MB) from Hugging Face.
                let model = try await LSEENDModel.loadFromHuggingFace(
                    variant: .ami, stepSize: .step100ms, cacheDirectory: Self.modelDirectory, computeUnits: .cpuOnly
                )
                // Handed to the queue once and used only there.
                nonisolated(unsafe) let diarizer = try LSEENDDiarizer(model: model)
                queue.async { [self] in
                    loaded = true
                    guard !failed, !finished else { return }
                    self.diarizer = diarizer
                    feed(backlog)
                    backlog = []
                }
            } catch {
                logger.error("Voice separation unavailable: \(error.localizedDescription, privacy: .public)")
                queue.async { [self] in
                    loaded = true
                    failed = true
                    backlog = []
                }
            }
        }
    }

    /// Called on the segmenter queue, in order.
    func append(_ samples: [Float]) {
        queue.async { [self] in
            guard !failed, !finished else { return }
            if diarizer != nil {
                feed(samples)
            } else if backlog.count + samples.count <= Self.maximumBacklog {
                backlog += samples
            } else {
                logger.notice("Voice separation model took too long to load; skipping it for this meeting")
                failed = true
                backlog = []
            }
        }
    }

    private func feed(_ samples: [Float]) {
        guard let diarizer, !samples.isEmpty else { return }
        do {
            try diarizer.addAudio(samples, sourceSampleRate: 16_000)
            _ = try diarizer.process()
        } catch {
            logger.error("Voice separation failed: \(error.localizedDescription, privacy: .public)")
            failed = true
            self.diarizer = nil
        }
    }

    /// Who spoke when. Waits up to `wait` for a model that is still loading; empty if it never did.
    func finish(wait: TimeInterval = 20) async -> [VoiceTurn] {
        let deadline = Date().addingTimeInterval(wait)
        while queue.sync(execute: { !loaded }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return queue.sync {
            finished = true
            guard let diarizer, !failed else { return [] }
            do {
                try diarizer.finalizeSession()
            } catch {
                logger.error("Voice separation failed to finish: \(error.localizedDescription, privacy: .public)")
                return []
            }
            let turns = diarizer.timeline.speakers.values.flatMap(\.finalizedSegments).map {
                VoiceTurn(start: TimeInterval($0.startTime), end: TimeInterval($0.endTime), speaker: $0.speakerIndex)
            }
            self.diarizer = nil
            return turns.sorted { $0.start < $1.start }
        }
    }

    func cancel() {
        queue.async { [self] in
            finished = true
            diarizer = nil
            backlog = []
        }
    }
}
