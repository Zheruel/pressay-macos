import AppKit
import CoreGraphics
import LocalFlowCore

@MainActor
protocol HoldHotkeyDelegate: AnyObject {
    func holdKeyPressed()
    func holdKeyReleased()
    func holdKeyCancelled()
}

final class HotkeyMonitor: @unchecked Sendable {
    @MainActor weak var delegate: HoldHotkeyDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false
    private var holdKey: HoldKey = .rightOption

    @MainActor init() {}

    func start(holdKey: HoldKey) throws {
        stop()
        self.holdKey = holdKey
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: pointer
        ) else {
            throw LocalFlowError.modelUnavailable("Input Monitoring permission is required")
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        isPressed = false
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }

        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53, isPressed {
            isPressed = false
            Task { @MainActor [weak self] in self?.delegate?.holdKeyCancelled() }
            return
        }

        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == holdKey.keyCode else { return }
        let optionIsDown = event.flags.contains(.maskAlternate)
        if optionIsDown, !isPressed {
            isPressed = true
            Task { @MainActor [weak self] in self?.delegate?.holdKeyPressed() }
        } else if !optionIsDown, isPressed {
            isPressed = false
            Task { @MainActor [weak self] in self?.delegate?.holdKeyReleased() }
        }
    }
}
