import AppKit
import PressayCore
import SwiftUI

/// Modifier keys bind on press (flagsChanged); Escape cancels capture and can never be bound.
struct KeyCaptureButton: View {
    @Binding var key: HoldKey
    var onChange: () -> Void
    /// Called with true while capture is active so the caller can suspend the
    /// global hold-key monitor — otherwise pressing the current hold key to
    /// rebind it would start a dictation mid-capture.
    var onCaptureActive: (Bool) -> Void

    @State private var capturing = false
    @State private var eventMonitor: Any?

    var body: some View {
        Button {
            capturing ? stopCapture() : startCapture()
        } label: {
            Text(capturing ? "Press a key…" : key.shortcutLabel)
                .frame(minWidth: 90)
                .monospacedDigit()
                .contentTransition(.opacity)
        }
        .onDisappear { stopCapture() }
    }

    private func startCapture() {
        capturing = true
        onCaptureActive(true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
        }
    }

    private func stopCapture() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if capturing {
            capturing = false
            onCaptureActive(false)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let code = Int64(event.keyCode)
        if event.type == .keyDown, code == HoldKey.escapeKeyCode {
            stopCapture()
            return nil
        }
        guard HoldKey.isBindable(keyCode: code) else { return nil }
        let candidate = HoldKey(keyCode: code)
        if event.type == .flagsChanged {
            // flagsChanged also fires on release; only bind on the press.
            guard candidate.isDownAsModifier(inFlags: UInt64(event.modifierFlags.rawValue)) else { return nil }
        }
        key = candidate
        stopCapture()
        onChange()
        return nil
    }
}
