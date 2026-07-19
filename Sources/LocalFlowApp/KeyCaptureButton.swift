import AppKit
import LocalFlowCore
import SwiftUI

/// Wispr-Flow-style hotkey recorder: click, then press any key to bind it.
/// Modifier keys are captured on press (flagsChanged); Escape cancels capture
/// and can never be bound. A key already used by the other workflow is
/// rejected in place.
struct KeyCaptureButton: View {
    @Binding var key: HoldKey
    /// Evaluated at match time, not capture time — the other binding can
    /// change while this button is armed.
    var reservedKey: () -> HoldKey?
    var onChange: () -> Void
    /// Called with true while capture is active so the caller can suspend the
    /// global hold-key monitors — otherwise pressing the current hold key to
    /// rebind it would start a dictation mid-capture.
    var onCaptureActive: (Bool) -> Void

    @State private var capturing = false
    @State private var conflictFlash = 0
    @State private var showsConflict = false
    @State private var eventMonitor: Any?

    var body: some View {
        Button {
            capturing ? stopCapture() : startCapture()
        } label: {
            Text(label)
                .frame(width: 135)
                .contentTransition(.opacity)
        }
        .foregroundStyle(showsConflict ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
        .onDisappear { stopCapture() }
        .task(id: conflictFlash) {
            guard showsConflict else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            showsConflict = false
        }
    }

    private var label: String {
        if showsConflict { return "Key already in use" }
        return capturing ? "Press a key…" : key.displayName
    }

    private func startCapture() {
        capturing = true
        showsConflict = false
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
        if candidate == reservedKey() {
            showsConflict = true
            conflictFlash += 1
            stopCapture()
            return nil
        }
        key = candidate
        stopCapture()
        onChange()
        return nil
    }
}
