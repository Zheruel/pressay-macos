import Foundation

/// Splitting long dictations for engines whose decoder context bounds how much
/// audio they can take in one run.
///
/// Whisper chunks long audio inside the runtime (`TRANSCRIBE_FEATURE_LONG_FORM`
/// is whisper-only today); Fun-ASR and Qwen3-ASR do not, and return
/// `outputTruncated` once a decode outgrows the context window. Falling back to
/// Whisper for those clips would be the wrong repair — Whisper is the engine
/// measured to collapse long dictations into an unpunctuated block, which is
/// exactly what the other engines were chosen to avoid. So we split the audio
/// and keep the engine the user picked.
public enum AudioChunking {
    /// Frames scanned when looking for a gap between words.
    static let frameSeconds: TimeInterval = 0.2

    /// Index of the quietest frame centre within `searchSeconds` of `target`,
    /// for use as a split point. Prefers a real pause so a split lands between
    /// words rather than inside one.
    ///
    /// Returns `nil` when the search window would fall outside the buffer, or
    /// when nothing in it is meaningfully quieter than the clip as a whole —
    /// in which case the caller should split at `target` and accept the risk of
    /// cutting a word, since not splitting loses the tail entirely.
    public static func quietestSplitPoint(
        samples: [Float],
        sampleRate: Int,
        near target: Int,
        searchSeconds: TimeInterval = 3.0
    ) -> Int? {
        guard sampleRate > 0, !samples.isEmpty else { return nil }
        let frame = max(1, Int(frameSeconds * Double(sampleRate)))
        let search = max(frame, Int(searchSeconds * Double(sampleRate)))
        let lower = max(0, target - search)
        let upper = min(samples.count - frame, target + search)
        guard lower < upper else { return nil }

        var quietestStart = lower
        var quietestEnergy = Float.greatestFiniteMagnitude
        var index = lower
        // Hop by a quarter frame: fine enough to find a short gap between
        // words without scanning every sample of a 100-second buffer.
        let hop = max(1, frame / 4)
        while index <= upper {
            let energy = meanSquare(samples, from: index, count: frame)
            if energy < quietestEnergy {
                quietestEnergy = energy
                quietestStart = index
            }
            index += hop
        }

        // Only treat it as a pause if it is well below the clip's own level;
        // otherwise the "quietest" frame is just ordinary speech.
        let overall = meanSquare(samples, from: 0, count: samples.count)
        guard overall > 0, quietestEnergy < overall * 0.10 else { return nil }
        return quietestStart + frame / 2
    }

    /// Split point for a buffer that must be divided in two, falling back to
    /// the midpoint when no pause is available.
    public static func splitPoint(samples: [Float], sampleRate: Int) -> Int {
        let midpoint = samples.count / 2
        return quietestSplitPoint(samples: samples, sampleRate: sampleRate, near: midpoint)
            ?? midpoint
    }

    /// Joins chunk transcripts into one dictation, dropping empties so a
    /// silent chunk cannot introduce a double space.
    public static func join(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func meanSquare(_ samples: [Float], from start: Int, count: Int) -> Float {
        let end = min(samples.count, start + count)
        guard start < end else { return .greatestFiniteMagnitude }
        var total: Float = 0
        for index in start..<end {
            let value = samples[index]
            total += value * value
        }
        return total / Float(end - start)
    }
}
