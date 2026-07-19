import AppKit
import PressayCore
import SwiftUI

/// Visual identity of the active workflow: dictation keeps the purple→blue
/// voice gradient; prompt polish is amber→pink with a "Polishing…" caption so
/// the multi-second cloud call reads as intentional.
enum OverlayStyle {
    case dictation
    case promptPolish

    var gradient: LinearGradient {
        switch self {
        case .dictation:
            LinearGradient(
                colors: [
                    Color(red: 0.63, green: 0.42, blue: 1),
                    Color(red: 0.48, green: 0.82, blue: 1),
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        case .promptPolish:
            LinearGradient(
                colors: [
                    Color(red: 1, green: 0.62, blue: 0.26),
                    Color(red: 1, green: 0.4, blue: 0.62),
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        }
    }

    var glowColor: Color {
        switch self {
        case .dictation: .indigo
        case .promptPolish: .orange
        }
    }

    var processingLabel: String? {
        switch self {
        case .dictation: nil
        case .promptPolish: "Vibing…"
        }
    }
}

@MainActor
final class OverlayState: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var levels: [Float] = [0, 0, 0, 0]
    @Published var message = ""
    @Published var style: OverlayStyle = .dictation
    @Published var toast: String?
}

@MainActor
final class OverlayPanelController {
    let state = OverlayState()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func showRecording(style: OverlayStyle = .dictation) {
        state.toast = nil
        dismissTask?.cancel()
        state.style = style
        state.phase = .recording
        state.message = ""
        present(width: 78, height: 44)
    }

    /// Keeps the style set by showRecording so the whole session stays visually
    /// consistent from key press to insertion.
    func showProcessing() {
        state.toast = nil
        dismissTask?.cancel()
        state.phase = .processing
        state.message = ""
        present(width: state.style.processingLabel == nil ? 78 : 138, height: 44)
    }

    func showSuccess() {
        state.toast = nil
        state.phase = .succeeded
        state.message = ""
        present(width: 78, height: 44)
        dismiss(after: .milliseconds(520))
    }

    func showError(_ message: String) {
        state.toast = nil
        state.phase = .failed(message)
        state.message = message
        present(width: 280, height: 58)
        dismiss(after: .seconds(2.4))
    }

    /// Celebration for newly learned vocabulary; only shows between sessions.
    func showLearnedToast(_ message: String) {
        guard state.phase == .idle else { return }
        dismissTask?.cancel()
        state.toast = message
        present(width: 320, height: 50)
        dismiss(after: .seconds(2.4))
    }

    func hide() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        state.phase = .idle
        state.levels = [0, 0, 0, 0]
        state.style = .dictation
        state.toast = nil
    }

    private func present(width: CGFloat, height: CGFloat) {
        ensurePanel()
        panel?.setContentSize(NSSize(width: width, height: height))
        positionPanel()
        panel?.orderFrontRegardless()
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 78, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: RecordingOverlayView(state: state))
        self.panel = panel
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 70))
    }

    private func dismiss(after duration: Duration) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
}

private struct RecordingOverlayView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        Group {
            if let toast = state.toast {
                toastContent(toast)
            } else if case .failed = state.phase {
                errorContent
            } else {
                compactContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 0.75)
        }
    }

    private var compactContent: some View {
        ZStack {
            switch state.phase {
            case .recording:
                RecordingVoiceBars(levels: state.levels, style: state.style)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            case .processing:
                ProcessingVoiceDots(style: state.style)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            case .succeeded:
                SuccessCheckmark()
            case .idle:
                RecordingVoiceBars(levels: [0, 0, 0, 0], style: state.style)
            case .failed:
                EmptyView()
            }
        }
        .animation(.snappy(duration: 0.22), value: state.phase)
    }

    private func toastContent(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OverlayStyle.dictation.gradient)
                .shadow(color: .indigo.opacity(0.35), radius: 5)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .transition(.scale(scale: 0.88).combined(with: .opacity))
    }

    private var errorContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(state.message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
    }
}

private struct RecordingVoiceBars: View {
    let levels: [Float]
    let style: OverlayStyle
    private let profiles: [CGFloat] = [0.64, 0.9, 1, 0.72]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(profiles.indices, id: \.self) { index in
                let level = index < levels.count ? CGFloat(levels[index]) : 0
                Capsule()
                    .fill(style.gradient)
                    .frame(width: 5, height: height(for: level, profile: profiles[index]))
                    .opacity(level > 0 ? 1 : 0.52)
                    .shadow(
                        color: level > 0 ? style.glowColor.opacity(0.26) : .clear,
                        radius: 4
                    )
                    .animation(
                        .interpolatingSpring(stiffness: 410, damping: 31),
                        value: level
                    )
            }
        }
        .frame(width: 42, height: 26)
    }

    private func height(for level: CGFloat, profile: CGFloat) -> CGFloat {
        guard level > 0.015 else { return 4 }
        return min(24, 5 + 19 * pow(level, 0.72) * profile)
    }
}

private struct ProcessingVoiceDots: View {
    let style: OverlayStyle

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { index in
                        let progress = sin(time * 8.25 - Double(index) * 0.92)
                        Capsule()
                            .fill(style.gradient)
                            .frame(width: 5, height: 6)
                            .offset(y: CGFloat(progress) * 4)
                            .opacity(0.62 + 0.38 * CGFloat((progress + 1) / 2))
                    }
                }
                .frame(width: 42, height: 26)
                if let label = style.processingLabel {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SuccessCheckmark: View {
    @State private var drawn = false

    var body: some View {
        CheckmarkShape()
            .trim(from: 0, to: drawn ? 1 : 0)
            .stroke(
                Color(red: 0.38, green: 0.86, blue: 0.64),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
            .frame(width: 20, height: 15)
            .onAppear {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    drawn = true
                }
            }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.maxY - rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.05, y: rect.minY + rect.height * 0.08))
        return path
    }
}
