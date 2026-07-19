import AppKit
import CoreGraphics
import PressayCore

@MainActor
protocol HoldHotkeyDelegate: AnyObject {
    func holdKeyPressed(_ monitor: HotkeyMonitor)
    func holdKeyReleased(_ monitor: HotkeyMonitor)
    func holdKeyCancelled(_ monitor: HotkeyMonitor)
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
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)

        // A non-modifier hold key must be swallowed while held, or its
        // keyDown/autorepeat/keyUp would type into the app being dictated
        // into; that needs an intercepting tap. Modifier keys produce no text,
        // so they keep the lighter listen-only tap.
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: holdKey.isModifier ? .listenOnly : .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: pointer
        ) else {
            throw PressayError.modelUnavailable("Input Monitoring permission is required")
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
        // Tearing down mid-press would otherwise strand the coordinator in the
        // recording phase with no release event ever arriving.
        if isPressed {
            isPressed = false
            notify { $0.holdKeyCancelled(self) }
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let consumed = monitor.handle(type: type, event: event)
        return consumed ? nil : Unmanaged.passUnretained(event)
    }

    /// Modifier chords that must never trigger a non-modifier hold key:
    /// Cmd+A with "A" bound is a shortcut, not a push-to-talk press.
    private static let chordMask = CGEventFlags([.maskCommand, .maskControl, .maskAlternate])

    /// Returns true when the event was consumed (only ever for a bound
    /// non-modifier key on an intercepting tap).
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            // A release delivered while the tap was disabled is lost; poll the
            // live key state so the session can't stay open forever.
            if isPressed, !Self.holdKeyIsDown(holdKey) {
                isPressed = false
                notify { $0.holdKeyReleased(self) }
            }
            return false
        }

        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == HoldKey.escapeKeyCode, isPressed {
            isPressed = false
            notify { $0.holdKeyCancelled(self) }
            return false
        }

        guard event.getIntegerValueField(.keyboardEventKeycode) == holdKey.keyCode else { return false }
        if holdKey.isModifier {
            guard type == .flagsChanged else { return false }
            setPressed(holdKey.isDownAsModifier(inFlags: event.flags.rawValue))
            return false
        }
        // A chord containing the hold key is a shortcut for the focused app:
        // pass it through untouched and don't start a session.
        guard event.flags.intersection(Self.chordMask).isEmpty else { return false }
        switch type {
        case .keyDown: setPressed(true) // autorepeat keyDowns are no-ops while pressed
        case .keyUp: setPressed(false)
        default: return false
        }
        return true
    }

    private func setPressed(_ down: Bool) {
        if down, !isPressed {
            isPressed = true
            notify { $0.holdKeyPressed(self) }
        } else if !down, isPressed {
            isPressed = false
            notify { $0.holdKeyReleased(self) }
        }
    }

    private static func holdKeyIsDown(_ key: HoldKey) -> Bool {
        if key.isModifier {
            return key.isDownAsModifier(inFlags: CGEventSource.flagsState(.combinedSessionState).rawValue)
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key.keyCode))
    }

    /// The tap source lives on the main run loop, so callbacks are already on
    /// the main thread; synchronous delivery keeps press/release ordered,
    /// which separately rooted Tasks would not guarantee.
    private func notify(_ action: @MainActor (HoldHotkeyDelegate) -> Void) {
        MainActor.assumeIsolated {
            if let delegate { action(delegate) }
        }
    }
}
