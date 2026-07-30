import CoreAudio
import Foundation

/// Thin read-only wrapper over the CoreAudio HAL.
///
/// `AVAudioEngine` exposes neither the transport type of the input device nor
/// whether anything is playing on the output, and both decide whether the mic
/// may stay warm between dictations.
enum AudioDeviceMonitor {
    struct Device: Identifiable, Equatable, Sendable {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let isBluetooth: Bool
    }

    // MARK: - Defaults

    static var defaultInputDeviceID: AudioDeviceID? {
        systemDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    static var defaultOutputDeviceID: AudioDeviceID? {
        systemDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// True when a process *other than Pressay* is playing audio.
    ///
    /// Deliberately not `kAudioDevicePropertyDeviceIsRunningSomewhere`: on a
    /// Bluetooth headset, opening our own mic brings up the call profile's
    /// output side, so that property flips true within a millisecond of the
    /// warm mic opening. Using it as the guard made the guard close the very
    /// stream that had just tripped it, oscillating open/closed forever.
    /// Attributing playback by PID is immune to our own mic and earcons.
    static var otherProcessIsPlaying: Bool {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        return processObjects().contains { process in
            guard uint32Property(process, kAudioProcessPropertyIsRunningOutput) == 1 else {
                return false
            }
            // An unreadable PID is not evidence of somebody else playing;
            // treating it as such would suppress warmth permanently after a
            // single HAL hiccup.
            guard let owner = pid(of: process) else { return false }
            return owner != ourPID
        }
    }

    private static func pid(of process: AudioObjectID) -> pid_t? {
        var value = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var property = address(kAudioProcessPropertyPID)
        guard AudioObjectGetPropertyData(process, &property, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func processObjects() -> [AudioObjectID] {
        var size = UInt32(0)
        var property = address(kAudioHardwarePropertyProcessObjectList)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var objects = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &objects
        ) == noErr else { return [] }
        return objects
    }

    /// Name of the input the system default currently resolves to, so
    /// "Follow system" can say what it actually means today.
    static var defaultInputName: String? {
        defaultInputDeviceID.map { name($0) }
    }

    static var defaultInputIsBluetooth: Bool {
        guard let device = defaultInputDeviceID else { return false }
        return isBluetooth(device)
    }

    // MARK: - Enumeration

    /// Every device that can capture audio, for the input picker. A device
    /// without a UID cannot be persisted or looked up again, so it is left out
    /// rather than offered as a choice that would silently not apply.
    static func inputDevices() -> [Device] {
        allDeviceIDs()
            .filter { channelCount($0, scope: kAudioObjectPropertyScopeInput) > 0 }
            .compactMap { device in
                guard let uid = uid(device) else { return nil }
                return Device(
                    id: device, name: name(device), uid: uid, isBluetooth: isBluetooth(device)
                )
            }
    }

    static func device(forUID wanted: String) -> Device? {
        inputDevices().first { $0.uid == wanted }
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let transport = uint32Property(device, kAudioDevicePropertyTransportType)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func name(_ device: AudioDeviceID) -> String {
        stringProperty(device, kAudioObjectPropertyName) ?? "Unknown device"
    }

    static func uid(_ device: AudioDeviceID) -> String? {
        stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    // MARK: - HAL plumbing

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func systemDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var property = address(selector)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var size = UInt32(0)
        var property = address(kAudioHardwarePropertyDevices)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var devices = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &devices
        ) == noErr else { return [] }
        return devices
    }

    private static func uint32Property(
        _ device: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> UInt32 {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var property = address(selector)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    /// `Unmanaged` rather than a bridged `CFString` local: passing the address of
    /// a Swift-managed object reference to the HAL is not a valid raw pointer.
    private static func stringProperty(
        _ device: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var property = address(selector)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        return value.takeRetainedValue() as String
    }

    fileprivate static func globalAddress(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        address(selector)
    }

    private static func channelCount(
        _ device: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var size = UInt32(0)
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0
        else { return 0 }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, buffer) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }
}

/// Reports when playback starts or stops on the default output device.
///
/// Sampling this once when a dictation ends is not enough: pausing a video,
/// dictating, then hitting resume is a common pattern, and it lands playback
/// squarely inside the warm window when the one-shot check already said the
/// device was idle.
@MainActor
final class OutputActivityObserver {
    private let handler: (Bool) -> Void
    private var observedDevice: AudioDeviceID?
    private var activityBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?

    init(handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    // No assumeIsolated: deinit on a @MainActor class is nonisolated and may
    // run on any thread, where that would trap. Listener blocks are released
    // with the object, and stop() is called explicitly on teardown paths.
    deinit {}

    func start() {
        guard defaultDeviceBlock == nil else { return }
        var address = AudioDeviceMonitor.globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The headset itself can change mid-session; follow it.
                self.retarget()
                self.handler(AudioDeviceMonitor.otherProcessIsPlaying)
            }
        }
        defaultDeviceBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        retarget()
    }

    func stop() {
        if let defaultDeviceBlock {
            var address = AudioDeviceMonitor.globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, defaultDeviceBlock
            )
        }
        defaultDeviceBlock = nil
        detach()
    }

    private func retarget() {
        let next = AudioDeviceMonitor.defaultOutputDeviceID
        guard next != observedDevice else { return }
        detach()
        guard let next else { return }

        var address = AudioDeviceMonitor.globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.handler(AudioDeviceMonitor.otherProcessIsPlaying)
            }
        }
        activityBlock = block
        observedDevice = next
        AudioObjectAddPropertyListenerBlock(next, &address, DispatchQueue.main, block)
    }

    private func detach() {
        if let observedDevice, let activityBlock {
            var address = AudioDeviceMonitor.globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(
                observedDevice, &address, DispatchQueue.main, activityBlock
            )
        }
        observedDevice = nil
        activityBlock = nil
    }
}
