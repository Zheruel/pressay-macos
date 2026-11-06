// Standalone signed helper for the Rust shell. Uses public AVAudioEngine and CoreAudio
// process-tap APIs; stdout is a bounded framed PCM protocol, never diagnostic text.
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Synchronization

private struct CaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class PacketWriter: @unchecked Sendable {
    let origin = AVAudioTime.seconds(forHostTime: mach_absolute_time())
    let failed = Atomic(false)
    private let active = Atomic(false)
    private let queue = DispatchQueue(label: "pressay.meeting.pipe", qos: .userInitiated)
    private let capacity = DispatchSemaphore(value: 64)
    private let output = FileHandle.standardOutput

    func ready() throws {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "elapsed": elapsed])
        queue.sync { write(1, data) }
        active.store(true, ordering: .releasing)
    }
    var elapsed: Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) - origin }
    func audio(track: UInt8, start: Double, samples: [Float]) {
        guard active.load(ordering: .acquiring), !samples.isEmpty else { return }
        guard capacity.wait(timeout: .now()) == .success else { fail("Native meeting audio output queue overflowed"); return }
        queue.async { [self] in
            defer { capacity.signal() }
            var packet = Data([track])
            var timestamp = start.bitPattern.littleEndian
            var count = UInt32(samples.count).littleEndian
            withUnsafeBytes(of: &timestamp) { packet.append(contentsOf: $0) }
            withUnsafeBytes(of: &count) { packet.append(contentsOf: $0) }
            samples.withUnsafeBytes { packet.append(contentsOf: $0) }
            write(2, packet)
        }
    }
    func warning(_ message: String) {
        guard capacity.wait(timeout: .now()) == .success else { fail("Native meeting event queue overflowed"); return }
        queue.async { [self] in defer { capacity.signal() }; write(3, Data(message.utf8)) }
    }
    func fail(_ message: String) {
        guard !failed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        active.store(false, ordering: .releasing)
        queue.async { [self] in write(4, Data(message.utf8)) }
    }
    func finish() {
        queue.sync { if !failed.load(ordering: .acquiring) { write(5, Data()) } }
        active.store(false, ordering: .releasing)
    }
    private func write(_ kind: UInt8, _ payload: Data) {
        var header = Data([kind])
        var count = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &count) { header.append(contentsOf: $0) }
        do { try output.write(contentsOf: header); try output.write(contentsOf: payload) }
        catch { _exit(2) }
    }
}

/// Each track has its own converter and serial processing queue. Slots bound pending
/// raw buffers; the native callbacks never wait for conversion, pipe I/O, or queue space.
private final class TrackProcessor: @unchecked Sendable {
    let track: UInt8
    let frames = Atomic<UInt64>(0)
    let hasSignal = Atomic(false)
    private let writer: PacketWriter
    private let queue: DispatchQueue
    private let slots = DispatchSemaphore(value: 16)
    private var converter: AVAudioConverter?
    private var sourceRate = 0.0
    private var expectedInputTime: Double?
    private var start = 0.0
    private var outputFrames = 0
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(track: UInt8, writer: PacketWriter) {
        self.track = track; self.writer = writer
        queue = DispatchQueue(label: "pressay.meeting.track.\(track)", qos: .userInitiated)
    }
    func append(_ samples: [Float], rate: Double, hostTime: UInt64) {
        guard !samples.isEmpty else { return }
        guard rate.isFinite, (8_000...192_000).contains(rate) else {
            writer.fail("Audio device returned an unsupported sample rate"); return
        }
        guard slots.wait(timeout: .now()) == .success else { writer.fail("Native meeting audio processing queue overflowed"); return }
        let time = hostTime > 0 ? AVAudioTime.seconds(forHostTime: hostTime) - writer.origin
            : writer.elapsed - Double(samples.count) / rate
        queue.async { [self] in
            defer { slots.signal() }
            do {
                guard samples.allSatisfy(\.isFinite) else { throw CaptureFailure("Audio device returned invalid samples") }
                let gap = expectedInputTime.map { abs(time - $0) > 0.1 } ?? false
                if sourceRate != rate || gap {
                    try flushConverter()
                    if gap { writer.warning("An audio device clock changed. The meeting timeline preserves the gap.") }
                    sourceRate = rate
                    start = max(max(time, 0), start + Double(outputFrames) / 16_000)
                    outputFrames = 0
                    converter = rate == 16_000 ? nil : AVAudioConverter(
                        from: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!,
                        to: outputFormat)
                    if rate != 16_000, converter == nil { throw CaptureFailure("Could not create meeting audio converter") }
                }
                expectedInputTime = time + Double(samples.count) / rate
                let converted = try convert(samples)
                frames.wrappingAdd(UInt64(converted.count), ordering: .relaxed)
                if converted.contains(where: { abs($0) > 0.00001 }) { hasSignal.store(true, ordering: .releasing) }
                emit(converted)
            } catch { writer.fail(error.localizedDescription) }
        }
    }
    private func emit(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        writer.audio(track: track, start: start + Double(outputFrames) / 16_000, samples: samples)
        outputFrames += samples.count
    }
    private func convert(_ samples: [Float]) throws -> [Float] {
        guard let converter else { return samples }
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * 16_000 / sourceRate)) + 256)
        else { throw CaptureFailure("Could not allocate meeting audio conversion buffer") }
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let failure { throw failure }
        guard status != .error else { throw CaptureFailure("Meeting audio conversion failed") }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
    private func flushConverter() throws {
        guard let converter else { return }
        for _ in 0..<16 {
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)!
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, state in state.pointee = .endOfStream; return nil }
            if let failure { throw failure }
            if status == .error { throw CaptureFailure("Meeting audio could not flush its final samples") }
            emit(Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))))
            if status == .endOfStream || output.frameLength == 0 { self.converter = nil; return }
        }
        throw CaptureFailure("Meeting audio converter did not finish")
    }
    func finish() {
        queue.sync { do { try flushConverter() } catch { writer.fail(error.localizedDescription) } }
    }
}

private final class Microphone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let processor: TrackProcessor
    private var tapInstalled = false
    private(set) var echoCancellation = false
    init(processor: TrackProcessor) { self.processor = processor }
    func start(device: String?, echo: Bool) throws {
        let input = engine.inputNode
        if let device {
            guard let id = Devices.input(uid: device) else { throw CaptureFailure("The selected meeting microphone is unavailable") }
            try input.auAudioUnit.setDeviceID(id)
        }
        if echo {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            echoCancellation = true
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureFailure("The microphone has no usable audio format") }
        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [processor] buffer, when in
            guard let channels = buffer.floatChannelData else { return }
            // VoiceProcessingIO's first channel is the voice; auxiliary channels are not mic audio.
            let mono = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            processor.append(mono, rate: rate, hostTime: when.isHostTimeValid ? when.hostTime : 0)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }
    func stop() {
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        if engine.inputNode.isVoiceProcessingEnabled { try? engine.inputNode.setVoiceProcessingEnabled(false) }
    }
    deinit { stop() }
}

private final class SystemCapture: @unchecked Sendable {
    private let processor: TrackProcessor
    private let writer: PacketWriter
    private let excludedPIDs: [pid_t]
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var io: AudioDeviceIOProcID?
    private let audioQueue = DispatchQueue(label: "pressay.meeting.system.audio", qos: .userInitiated)
    private let control = DispatchQueue(label: "pressay.meeting.system.control")
    private let rateBits = Atomic<UInt64>(0)
    private var running = false
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
    init(processor: TrackProcessor, writer: PacketWriter, excludedPIDs: [pid_t]) {
        self.processor = processor; self.writer = writer; self.excludedPIDs = excludedPIDs
    }
    func start() throws {
        try control.sync {
            try open(); running = true
            var address = Devices.outputAddress
            let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, running else { return }
                close()
                do { try open(); writer.warning("Call audio reconnected to the new output device.") }
                catch { writer.fail("Call audio could not reconnect: \(error.localizedDescription)") }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, callback) == noErr { outputListener = callback }
        }
    }
    private func open() throws {
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedPIDs.compactMap(Devices.processObject))
            description.uuid = UUID(); description.name = "Pressay Meeting"; description.isPrivate = true; description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
            guard let outputUID = Devices.outputUID else { throw CaptureFailure("No output device is available for meeting capture") }
            let configuration: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Pressay Meeting", kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID, kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]]
            ]
            try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate), "create tap device")
            guard let format = Devices.lastInputFormat(aggregate), format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { throw CaptureFailure("Unsupported system audio format") }
            let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let tapChannels = Int(format.mChannelsPerFrame)
            guard tapChannels > 0, tapChannels <= 32 else { throw CaptureFailure("Invalid system audio channel count") }
            rateBits.store((Devices.nominalRate(aggregate) ?? format.mSampleRate).bitPattern, ordering: .releasing)
            var rateAddress = Devices.rateAddress
            let rateCallback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, let value = Devices.nominalRate(aggregate) else { return }
                rateBits.store(value.bitPattern, ordering: .releasing)
            }
            if AudioObjectAddPropertyListenerBlock(aggregate, &rateAddress, control, rateCallback) == noErr { rateListener = rateCallback }
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, audioQueue) { [weak self] _, input, timestamp, _, _ in
                guard let self else { return }
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                let selected = planar ? Array(buffers.suffix(tapChannels)) : Array(buffers.suffix(1))
                guard !planar || selected.count == tapChannels else { writer.fail("Incomplete system audio channels"); return }
                guard let first = selected.first, let firstData = first.mData else { return }
                let channels = planar ? 1 : Int(max(first.mNumberChannels, 1))
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
                guard frames > 0 else { return }
                var mono = [Float](repeating: 0, count: frames)
                if planar {
                    for buffer in selected {
                        guard let data = buffer.mData, Int(buffer.mDataByteSize) / 4 >= frames else { writer.fail("Incomplete planar system audio buffer"); return }
                        let values = data.assumingMemoryBound(to: Float.self)
                        for frame in 0..<frames { mono[frame] += values[frame] / Float(selected.count) }
                    }
                } else {
                    let values = firstData.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames { for channel in 0..<channels { mono[frame] += values[frame * channels + channel] / Float(channels) } }
                }
                processor.append(mono, rate: Double(bitPattern: rateBits.load(ordering: .acquiring)),
                                 hostTime: timestamp.pointee.mFlags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : 0)
            }, "create tap callback")
            try check(AudioDeviceStart(aggregate, io), "start process tap")
        } catch { close(); throw error }
    }
    private func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw CaptureFailure("Could not \(action) (CoreAudio \(status)). Check System Audio Recording permission.") }
    }
    private func close() {
        if aggregate != kAudioObjectUnknown {
            if let rateListener {
                var address = Devices.rateAddress
                AudioObjectRemovePropertyListenerBlock(aggregate, &address, control, rateListener)
                self.rateListener = nil
            }
            if let io { AudioDeviceStop(aggregate, io); AudioDeviceDestroyIOProcID(aggregate, io) }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        io = nil; aggregate = AudioObjectID(kAudioObjectUnknown); tap = AudioObjectID(kAudioObjectUnknown)
    }
    func stop() {
        control.sync {
            running = false
            if let outputListener {
                var address = Devices.outputAddress
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, outputListener)
                self.outputListener = nil
            }
            close()
        }
    }
    deinit { stop() }
}

private enum Devices {
    static let outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    static let rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func input(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first {
            string($0, kAudioDevicePropertyDeviceUID) == uid
                && lastInputFormat($0) != nil
        }
    }
    static var outputUID: String? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = outputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }
    static func processObject(_ pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr,
              object != kAudioObjectUnknown else { return nil }
        return object
    }
    static func nominalRate(_ id: AudioObjectID) -> Double? {
        var rate = 0.0; var size = UInt32(MemoryLayout<Double>.size); var address = rateAddress
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }
    static func lastInputFormat(_ id: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr, let last = streams.last else { return nil }
        var format = AudioStreamBasicDescription(); size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(last, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }
}

@main private struct MeetingCapture {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let writer = PacketWriter()
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let micProcessor = TrackProcessor(track: 1, writer: writer)
        let systemProcessor = TrackProcessor(track: 2, writer: writer)
        var microphone = Microphone(processor: micProcessor)
        var system: SystemCapture?
        let stop = Atomic(false)
        do {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw CaptureFailure("Allow microphone access in Pressay before starting a meeting.")
            }
            let wantsEcho = !arguments.contains("--no-echo-cancellation")
            do { try microphone.start(device: value("--input"), echo: wantsEcho) }
            catch where wantsEcho {
                microphone.stop(); microphone = Microphone(processor: micProcessor)
                try microphone.start(device: value("--input"), echo: false)
                writer.warning("Microphone echo cancellation is unavailable. Use headphones to keep call audio out of your microphone track.")
            }
            if !arguments.contains("--microphone-only") {
                let excluded = [getpid(), value("--exclude-pid").flatMap(Int32.init)].compactMap { $0 }
                let capture = SystemCapture(processor: systemProcessor, writer: writer, excludedPIDs: excluded)
                try capture.start(); system = capture
            }
            try writer.ready()
            Thread.detachNewThread {
                _ = readLine()
                stop.store(true, ordering: .releasing)
            }
            var checkedEcho = false
            while !stop.load(ordering: .acquiring), !writer.failed.load(ordering: .acquiring) {
                if !RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if !checkedEcho, writer.elapsed >= 2 {
                    checkedEcho = true
                    if microphone.echoCancellation, micProcessor.frames.load(ordering: .acquiring) >= 16_000,
                       !micProcessor.hasSignal.load(ordering: .acquiring) {
                        microphone.stop(); microphone = Microphone(processor: micProcessor)
                        try microphone.start(device: value("--input"), echo: false)
                        writer.warning("The echo-cancelled microphone was silent, so Pressay restarted it without echo cancellation.")
                    }
                }
            }
        } catch { writer.fail(error.localizedDescription) }
        microphone.stop(); system?.stop()
        micProcessor.finish(); systemProcessor.finish()
        writer.finish()
        _exit(writer.failed.load(ordering: .acquiring) ? 1 : 0)
    }
}
