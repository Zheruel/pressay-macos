import AppKit
import PressayCore
import SwiftUI

/// Click-to-record hold-key picker: click the keycap, press the key you want,
/// done. Modifier keys are captured on press (flagsChanged); Escape cancels
/// capture and can never be bound.
///
/// Capture holds the global hold-key monitor suspended — otherwise pressing
/// the current hold key to rebind it would start a dictation mid-capture — so
/// every way out of capture has to run through `stopCapture()`, including the
/// ones the user never asked for: a timeout, and the window losing focus.
/// Leaving capture armed leaves push-to-talk dead.
struct KeyCaptureButton: View {
    @Binding var key: HoldKey
    var onChange: () -> Void
    /// Called with true while capture is active so the caller can suspend the
    /// global hold-key monitor.
    var onCaptureActive: (Bool) -> Void

    /// A refused key, and which attempt it was: pressing the same unbindable
    /// key twice has to restart the dismissal timer rather than inherit the
    /// first press's deadline, or the second message blinks out immediately.
    private struct Rejection: Equatable, Sendable {
        let reason: String
        let attempt: Int
    }

    @Environment(\.controlActiveState) private var controlActiveState

    @State private var capturing = false
    @State private var eventMonitor: Any?
    @State private var rejection: Rejection?
    @State private var rejectionCount = 0
    @State private var hovering = false
    @State private var pulsing = false
    @FocusState private var focused: Bool

    /// Long enough to find the key you meant, short enough that clicking the
    /// recorder and walking away doesn't leave dictation switched off.
    private static let captureTimeout = Duration.seconds(12)
    private static let rejectionDuration = Duration.seconds(2)

    private var showsReset: Bool { !capturing && key != .default }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                capturing ? stopCapture() : startCapture()
            } label: {
                recorderChip
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hovering = $0 }
            // .plain drops the focus ring the default style drew, and this is
            // the one control in Settings you might reach for without a mouse.
            .focused($focused)
            .help(capturing ? "Press the key you want to hold" : "Click, then press any key")
            .accessibilityLabel("Hold-to-talk key")
            .accessibilityValue(key.displayName)
            .accessibilityHint("Activates key capture, then press the key you want to hold")

            Button {
                key = .default
                onChange()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Reset to \(HoldKey.default.displayName)")
            .accessibilityLabel("Reset hold-to-talk key to \(HoldKey.default.displayName)")
            // Kept in the layout so binding a key never shifts the row. Fading
            // it out is not enough on its own: an invisible button still takes
            // the pointer, shows its tooltip, and is read out by VoiceOver.
            .opacity(showsReset ? 1 : 0)
            .disabled(!showsReset)
            .allowsHitTesting(showsReset)
            .accessibilityHidden(!showsReset)
            .frame(width: 16)
        }
        .animation(.snappy(duration: 0.16), value: capturing)
        .animation(.snappy(duration: 0.16), value: showsReset)
        .onDisappear { stopCapture() }
        // Clicking into another window or app while armed would otherwise
        // strand capture — and push-to-talk with it. The local event monitor
        // only sees keys routed to this app, so it cannot notice this itself.
        .onChange(of: controlActiveState) { _, state in
            if state != .key { stopCapture() }
        }
        // Both timers are keyed on the state they end, so leaving that state
        // by any route cancels them: no task to store, none left running.
        .task(id: capturing) {
            guard capturing else { return }
            try? await Task.sleep(for: Self.captureTimeout)
            guard !Task.isCancelled else { return }
            stopCapture()
        }
        .task(id: rejection) {
            guard rejection != nil else { return }
            try? await Task.sleep(for: Self.rejectionDuration)
            guard !Task.isCancelled else { return }
            rejection = nil
        }
    }

    private var recorderChip: some View {
        ZStack {
            if capturing {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .scaleEffect(pulsing ? 1 : 0.6)
                        .opacity(pulsing ? 1 : 0.3)
                        .animation(
                            .easeInOut(duration: 0.65).repeatForever(autoreverses: true),
                            value: pulsing
                        )
                        .onAppear { pulsing = true }
                        .onDisappear { pulsing = false }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(rejection == nil ? "Press any key" : "Not that one")
                            .font(.caption.weight(.semibold))
                        Text(rejection?.reason ?? "esc to cancel")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
            } else {
                HStack(spacing: 7) {
                    keycap
                    if key.capGlyph != key.displayName {
                        Text(key.displayName)
                            .font(.callout)
                            .lineLimit(1)
                    }
                }
            }
        }
        // Fixed so the two states, and every key name, occupy the same box —
        // a recorder that resizes as you bind is a recorder that looks broken.
        .frame(width: 172, height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(chipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(chipStroke, lineWidth: capturing ? 1.5 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(focused ? 0.85 : 0), lineWidth: 3)
                .padding(-2.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var keycap: some View {
        Text(key.capGlyph)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .frame(minWidth: 15)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14))
            )
    }

    private var chipFill: Color {
        if capturing { return Color.accentColor.opacity(0.13) }
        return Color.primary.opacity(hovering ? 0.09 : 0.05)
    }

    private var chipStroke: Color {
        capturing ? .accentColor : Color(nsColor: .separatorColor)
    }

    private func startCapture() {
        capturing = true
        rejection = nil
        onCaptureActive(true)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
        }
    }

    private func stopCapture() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        rejection = nil
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
        guard HoldKey.isBindable(keyCode: code) else {
            // Silently swallowing the press reads as a frozen recorder, so say
            // why and stay open for another try.
            if let reason = HoldKey.rejectionReason(keyCode: code) { reject(reason) }
            return nil
        }
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

    /// Shows why a key was refused for a beat; the `rejection`-keyed task
    /// clears it.
    private func reject(_ reason: String) {
        rejectionCount += 1
        rejection = Rejection(reason: reason, attempt: rejectionCount)
    }
}
