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
    private let control = DispatchQueue(label: "dev.localflow.app.system-audio.control")
    private let resampler = StreamResampler()
    private let logger = Logger(subsystem: "dev.localflow.app", category: "meeting")
    /// The aggregate's clock, not the tap's 48 kHz: AirPods on a call deliver 24 kHz.
    private let rate = OSAllocatedUnfairLock<Double>(initialState: 0)
    private var running = false
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
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
        try control.sync {
            try open()
            running = true
            watchOutputDevice()
        }
    }

    private func open() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: AudioDevices.ownProcessObject.map { [$0] } ?? [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Pressay Meeting"
        try check(AudioHardwareCreateProcessTap(description, &tapID), "tap")

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

        // A headset's own mic comes first; the tap is the last input stream.
        guard let format = AudioDevices.lastInputStreamFormat(of: aggregateID) else { try check(-2, "format"); return }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard isFloat, format.mBitsPerChannel == 32 else { try check(-3, "format"); return }
        let nominal = AudioDevices.nominalSampleRate(of: aggregateID) ?? format.mSampleRate
        rate.withLock { $0 = nominal }
        watchSampleRate()
        logger.info("System audio from \(outputUID, privacy: .public) at \(nominal, privacy: .public) Hz, \(format.mChannelsPerFrame, privacy: .public) ch")

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let mono = Self.downmix(buffers)
            let converted = resampler.convert(mono, rate: rate.withLock { $0 })
            received += converted.count
            peak = max(peak, converted.reduce(0) { max($0, abs($1)) })
            onSamples?(converted)
        }, "io")
        try check(AudioDeviceStart(aggregateID, procID), "start")
    }

    deinit {
        unwatchOutputDevice()
        close()
    }

    private var received = 0
    private var peak: Float = 0

    func stop() {
        control.sync {
            running = false
            unwatchOutputDevice()
            close()
        }
    }

    private func close() {
        if aggregateID != kAudioObjectUnknown {
            logger.info("System audio: \(Double(self.received) / 16_000, privacy: .public)s, peak \(self.peak, privacy: .public)")
            unwatchSampleRate()
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

    private func watchOutputDevice() {
        var address = AudioDevices.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, running else { return }
            logger.notice("Output device changed; reopening system audio")
            close()
            do { try open() } catch { logger.error("System audio lost after output change: \(error.localizedDescription, privacy: .public)") }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, listener) == noErr {
            outputListener = listener
        }
    }

    private func unwatchOutputDevice() {
        guard let outputListener else { return }
        var address = AudioDevices.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, outputListener)
        self.outputListener = nil
    }

    private func watchSampleRate() {
        var address = AudioDevices.nominalRateAddress
        let device = aggregateID
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let nominal = AudioDevices.nominalSampleRate(of: device) else { return }
            logger.notice("System audio rate changed to \(nominal, privacy: .public) Hz")
            rate.withLock { $0 = nominal }
        }
        if AudioObjectAddPropertyListenerBlock(aggregateID, &address, control, listener) == noErr {
            rateListener = listener
        }
    }

    private func unwatchSampleRate() {
        guard let rateListener else { return }
        var address = AudioDevices.nominalRateAddress
        AudioObjectRemovePropertyListenerBlock(aggregateID, &address, control, rateListener)
        self.rateListener = nil
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            logger.error("System audio \(step, privacy: .public) failed: \(status, privacy: .public)")
            close()
            throw CaptureError.failed(step, status)
        }
    }

    private static func downmix(_ buffers: UnsafeMutableAudioBufferListPointer) -> [Float] {
        guard let last = buffers.last, let data = last.mData else { return [] }
        let samples = data.assumingMemoryBound(to: Float.self)
        let channels = Int(max(last.mNumberChannels, 1))
        let frames = Int(last.mDataByteSize) / MemoryLayout<Float>.size / channels
        return (0..<frames).map { frame in
            var sum: Float = 0
            for channel in 0..<channels { sum += samples[frame * channels + channel] }
            return sum / Float(channels)
        }
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

    static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )

    static let nominalRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )

    static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = nominalRateAddress
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    static func lastInputStreamFormat(of device: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let last = streams.last else { return nil }
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(last, &address, 0, nil, &formatSize, &format) == noErr else { return nil }
        return format
    }

    static var defaultOutputUID: String? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultOutputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
