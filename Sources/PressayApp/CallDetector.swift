import CoreAudio
import Foundation
import PressayCore

/// Polls Core Audio for call apps using the microphone. Needs no permission: it reads which
/// processes have input running, never the audio itself.
@MainActor
final class CallDetector {
    var onEvent: ((CallDetectionState.Event) -> Void)?
    private var timer: Timer?
    private var state = CallDetectionState()
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "dev.localflow.app"

    var isRunning: Bool { timer != nil }
    var inCall: Bool { state.inCall }

    func start() {
        guard timer == nil else { return }
        state = CallDetectionState()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.5
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let apps = Self.processesRunningInput()
            .filter { $0 != ownBundleID }
            .compactMap(CallApps.name(forBundleID:))
        if let event = state.update(activeApps: apps, at: .now) { onEvent?(event) }
    }

    private static func processesRunningInput() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(object, &inputAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { return nil }
            var bundleID: Unmanaged<CFString>?
            var idSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var idAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(object, &idAddress, 0, nil, &idSize, &bundleID) == noErr,
                  let bundleID else { return nil }
            return bundleID.takeRetainedValue() as String
        }
    }
}
