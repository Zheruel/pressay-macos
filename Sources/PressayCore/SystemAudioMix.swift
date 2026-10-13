/// Downmixes one interleaved buffer from the system audio tap to mono.
public enum SystemAudioMix {
    public static func mono(_ samples: UnsafeBufferPointer<Float>, channels: Int) -> [Float] {
        let channels = max(channels, 1)
        guard channels > 1 else { return Array(samples) }
        let frames = samples.count / channels
        let scale = 1 / Float(channels)
        return (0..<frames).map { frame in
            var sum: Float = 0
            for channel in 0..<channels { sum += samples[frame * channels + channel] }
            return sum * scale
        }
    }
}
