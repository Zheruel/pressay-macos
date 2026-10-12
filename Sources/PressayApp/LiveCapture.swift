@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os
import PressayCore

/// One converter for the whole recording so chunk edges don't click.
final class StreamResampler: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var sourceRate: Double = 0
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func convert(_ mono: [Float], rate: Double) -> [Float] {
        guard !mono.isEmpty, rate > 0 else { return [] }
        if rate == 16_000 { return mono }
        if converter == nil || rate != sourceRate,
           let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) {
            converter = AVAudioConverter(from: input, to: output)
            sourceRate = rate
        }
        guard let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(mono.count)) else { return [] }
        buffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        let capacity = AVAudioFrameCount(Double(mono.count) * 16_000 / rate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil else { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

/// Own engine so the dictation recorder's warm stream is untouched.
final class LiveMicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let resampler = StreamResampler()
    var onSamples: (@Sendable ([Float]) -> Void)?

    func start(echoCancellation: Bool, preferredInputUID: String?) throws {
        let input = engine.inputNode
        if let preferredInputUID, let device = AudioDeviceMonitor.device(forUID: preferredInputUID) {
            try? input.auAudioUnit.setDeviceID(device.id)
        }
        if echoCancellation {
            try input.setVoiceProcessingEnabled(true)
            // Don't turn the call down while we listen to it.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw PressayError.microphoneUnavailable }
        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            // Voice processing can report extra channels; the first is the voice.
            let mono = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            let converted = resampler.convert(mono, rate: rate)
            onSamples?(converted)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if engine.inputNode.isVoiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
    }
}

/// Everything the Mac plays except Pressay, via a Core Audio process tap.
/// Without System Audio Recording permission it hears silence rather than failing.
final class SystemAudioCapture: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.localflow.app.system-audio", qos: .userInitiated)
    private let resampler = StreamResampler()
    private let logger = Logger(subsystem: "dev.localflow.app", category: "meeting")
    var onSamples: (@Sendable ([Float]) -> Void)?

    enum CaptureError: LocalizedError {
        case failed(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .failed(let step, let status): "Couldn’t capture system audio (\(step), \(status))."
            }
        }
    }

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: AudioDevices.ownProcessObject.map { [$0] } ?? [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Pressay Meeting"
        try check(AudioHardwareCreateProcessTap(description, &tapID), "tap")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "format")

        guard let outputUID = AudioDevices.defaultOutputUID else { try check(-1, "output"); return }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pressay Meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "device")

        let rate = format.mSampleRate
        let channels = Int(max(format.mChannelsPerFrame, 1))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard isFloat, format.mBitsPerChannel == 32 else { try check(-2, "format"); return }
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let mono = Self.downmix(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), channels: channels, interleaved: interleaved)
            let converted = resampler.convert(mono, rate: rate)
            received += converted.count
            peak = max(peak, converted.reduce(0) { max($0, abs($1)) })
            onSamples?(converted)
        }, "io")
        try check(AudioDeviceStart(aggregateID, procID), "start")
    }

    deinit { stop() }

    private var received = 0
    private var peak: Float = 0

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            logger.info("System audio: \(Double(self.received) / 16_000, privacy: .public)s, peak \(self.peak, privacy: .public)")
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            logger.error("System audio \(step, privacy: .public) failed: \(status, privacy: .public)")
            stop()
            throw CaptureError.failed(step, status)
        }
    }

    private static func downmix(_ buffers: UnsafeMutableAudioBufferListPointer, channels: Int, interleaved: Bool) -> [Float] {
        guard let first = buffers.first, let data = first.mData else { return [] }
        if interleaved {
            let total = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            let frames = total / channels
            return (0..<frames).map { frame in
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                return sum / Float(channels)
            }
        }
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        var mono = [Float](repeating: 0, count: frames)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames { mono[frame] += samples[frame] }
        }
        let scale = 1 / Float(max(buffers.count, 1))
        return mono.map { $0 * scale }
    }
}

enum AudioDevices {
    static var ownProcessObject: AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static var defaultOutputUID: String? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
