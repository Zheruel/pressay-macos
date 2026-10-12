import Foundation

/// Splits long audio for Fun-ASR/Qwen3-ASR, which return `outputTruncated` past their decoder context.
/// Falling back to Whisper would reintroduce its unpunctuated-block failure on long dictations.
public enum AudioChunking {
    static let frameSeconds: TimeInterval = 0.2

    /// Quietest frame centre near `target`, so a split lands between words. Nil when the window
    /// leaves the buffer or nothing is clearly quieter than the clip; split at `target` anyway,
    /// since not splitting loses the tail.
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
        // Quarter-frame hop: finds short word gaps without scanning every sample.
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

    public static func splitPoint(samples: [Float], sampleRate: Int) -> Int {
        let midpoint = samples.count / 2
        return quietestSplitPoint(samples: samples, sampleRate: sampleRate, near: midpoint)
            ?? midpoint
    }

    /// Drops empties so a silent chunk cannot add a double space.
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
