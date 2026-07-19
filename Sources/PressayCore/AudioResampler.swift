@preconcurrency import AVFoundation
import Foundation
import os

/// Converts microphone audio to Whisper's 16 kHz input with a proper
/// anti-aliasing filter. Package visibility keeps this out of the public API.
package enum AudioResampler {
    package static func convert(
        _ samples: [Float],
        from sourceRate: Double,
        to targetRate: Double = 16_000
    ) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard sourceRate > 0, targetRate > 0 else {
            throw PressayError.audioConversionFailed
        }
        guard sourceRate != targetRate else { return samples }

        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceRate,
                channels: 1,
                interleaved: false
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetRate,
                channels: 1,
                interleaved: false
            ),
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw PressayError.audioConversionFailed
        }

        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        guard let inputChannel = inputBuffer.floatChannelData?[0] else {
            throw PressayError.audioConversionFailed
        }
        samples.withUnsafeBufferPointer { source in
            inputChannel.update(from: source.baseAddress!, count: samples.count)
        }

        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let estimatedFrames = max(
            1,
            AVAudioFrameCount((Double(samples.count) * targetRate / sourceRate).rounded(.up))
        )
        let inputProvided = OSAllocatedUnfairLock(initialState: false)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            let wasProvided = inputProvided.withLock { provided -> Bool in
                defer { provided = true }
                return provided
            }
            if wasProvided {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return inputBuffer
        }

        func makeOutput(capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw PressayError.audioConversionFailed
            }
            return buffer
        }

        var converted: [Float] = []
        converted.reserveCapacity(Int(estimatedFrames))
        var conversionError: NSError?

        let firstOutput = try makeOutput(capacity: estimatedFrames)
        var status = converter.convert(to: firstOutput, error: &conversionError, withInputFrom: inputBlock)
        try validate(status, error: conversionError)
        append(firstOutput, to: &converted)

        while status != .endOfStream {
            let output = try makeOutput(capacity: 4_096)
            status = converter.convert(to: output, error: &conversionError, withInputFrom: inputBlock)
            try validate(status, error: conversionError)
            append(output, to: &converted)
        }

        guard !converted.isEmpty else { throw PressayError.audioConversionFailed }
        return converted
    }

    private static func validate(_ status: AVAudioConverterOutputStatus, error: NSError?) throws {
        guard status == .error else { return }
        if let error { throw error }
        throw PressayError.audioConversionFailed
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to samples: inout [Float]) {
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
