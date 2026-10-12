import AppKit
import PressayCore
import SwiftUI

enum OverlayStyle {
    case dictation
    /// Command Mode: the speech is an instruction, not text to insert.
    case command

    var colors: [Color] {
        switch self {
        case .dictation: [Color(red: 0.63, green: 0.42, blue: 1), Color(red: 0.48, green: 0.82, blue: 1)]
        case .command: [Color(red: 1, green: 0.45, blue: 0.3), Color(red: 1, green: 0.78, blue: 0.3)]
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top)
    }
}

/// The camera housing at the top of the screen; zero on screens without one.
struct NotchGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat

    static let none = NotchGeometry(width: 0, height: 0)
    var exists: Bool { width > 0 }

    @MainActor
    static func of(_ screen: NSScreen) -> NotchGeometry {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return .none }
        return NotchGeometry(
            width: screen.frame.width - left.width - right.width,
            height: screen.safeAreaInsets.top
        )
    }
}

@MainActor
final class OverlayState: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var levels: [Float] = [0, 0, 0, 0]
    @Published var message = ""
    @Published var style: OverlayStyle = .dictation
    @Published var toast: String?
    /// Drives the grow/collapse animation; the panel orders out after the fold.
    @Published var visible = false
    @Published var polishing = false
    @Published var recordingStarted: Date?
    @Published var notch = NotchGeometry.none
}

/// Grows out of the notch (or top edge) so it never covers the text being written.
@MainActor
final class OverlayPanelController {
    let state = OverlayState()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var orderOutTask: Task<Void, Never>?

    /// Fixed stage; the island morphs inside it because window resizing can't spring smoothly.
    private static let stage = NSSize(width: 560, height: 150)

    /// Key is down but the mic has not delivered audio yet. Acknowledges the
    /// press immediately so the wait for a cold Bluetooth link doesn't read as
    /// a dropped key press.
    func showArming(style: OverlayStyle = .dictation) {
        state.toast = nil
        dismissTask?.cancel()
        state.style = style
        state.phase = .arming
        state.message = ""
        present()
    }

    func showRecording(style: OverlayStyle = .dictation) {
        state.toast = nil
        dismissTask?.cancel()
        state.style = style
        if state.phase != .recording { state.recordingStarted = Date() }
        state.phase = .recording
        state.message = ""
        present()
    }

    func showProcessing() {
        state.toast = nil
        dismissTask?.cancel()
        state.polishing = false
        state.phase = .processing
        state.message = ""
        present()
    }

    func showPolishing() {
        guard state.phase == .processing else { return }
        state.polishing = true
    }

    func showSuccess() {
        state.toast = nil
        state.phase = .succeeded
        state.message = ""
        present()
        dismiss(after: .milliseconds(900))
    }

    func showError(_ message: String) {
        state.toast = nil
        state.phase = .failed(message)
        state.message = message
        present()
        dismiss(after: .seconds(2.6))
    }

    /// Nothing on screen, or only the collapse of the last session.
    var isIdle: Bool { state.phase == .idle || !state.visible }

    /// Celebration for newly learned vocabulary; only shows between sessions.
    func showLearnedToast(_ message: String) {
        guard isIdle else { return }
        dismissTask?.cancel()
        state.phase = .idle
        state.toast = message
        present()
        dismiss(after: .seconds(2.6))
    }

    func hide() {
        dismissTask?.cancel()
        state.visible = false
        orderOutTask?.cancel()
        orderOutTask = Task { [weak self] in
            // Lets the island fold back into the notch before the window goes.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            panel?.orderOut(nil)
            state.phase = .idle
            state.levels = [0, 0, 0, 0]
            state.style = .dictation
            state.toast = nil
            state.polishing = false
            state.recordingStarted = nil
        }
    }

    private func present() {
        orderOutTask?.cancel()
        ensurePanel()
        let wasOnScreen = panel?.isVisible == true
        if !wasOnScreen { positionPanel() }
        panel?.orderFrontRegardless()
        guard !state.visible else { return }
        if wasOnScreen {
            state.visible = true
        } else {
            // One collapsed frame first, so the island grows out of the notch.
            Task { @MainActor [weak self] in
                self?.state.visible = true
            }
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.stage),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Above the menu bar, so the island can merge with the notch.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: IslandView(state: state))
        self.panel = panel
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        state.notch = .of(screen)
        let frame = screen.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.stage.width / 2, y: frame.maxY - Self.stage.height))
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

// MARK: - Island

private enum Palette {
    static let mic = Color(nsColor: .systemOrange)
    static let success = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let secondary = Color.white.opacity(0.62)
}

private struct IslandMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var shoulder: CGFloat
    var lifted: Bool
}

private struct IslandView: View {
    @ObservedObject var state: OverlayState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bump: CGFloat = 1
    @State private var shake: CGFloat = 0

    private var notch: NotchGeometry { state.notch }
    /// Height of the band beside the camera; also the whole island when compact.
    private var band: CGFloat { notch.exists ? max(notch.height, 30) : 32 }
    private var gap: CGFloat { notch.exists ? notch.width : 0 }

    private var isFailed: Bool {
        if case .failed = state.phase { return true }
        return false
    }

    private var isBanner: Bool { state.toast != nil || isFailed }

    private var ear: CGFloat? {
        guard state.visible, !isBanner else { return nil }
        switch state.phase {
        case .arming: return 36
        case .recording: return notch.exists ? 78 : 64
        case .processing: return notch.exists ? (state.polishing ? 90 : 102) : (state.polishing ? 66 : 74)
        case .succeeded: return notch.exists ? 82 : 60
        case .idle, .failed: return nil
        }
    }

    private var metrics: IslandMetrics {
        if state.visible, isBanner {
            let height = notch.exists ? band + 36 : 40
            return IslandMetrics(width: max(gap + 190, 340), height: height, radius: 20, shoulder: 9, lifted: true)
        }
        if let ear {
            return IslandMetrics(width: gap + 2 * ear, height: band, radius: band * 0.44, shoulder: 7, lifted: true)
        }
        // Collapsed: exactly the hardware notch, or a sliver tucked under the top edge.
        return notch.exists
            ? IslandMetrics(width: notch.width, height: notch.height, radius: 9, shoulder: 5, lifted: false)
            : IslandMetrics(width: 90, height: 6, radius: 3, shoulder: 3, lifted: false)
    }

    private var morph: Animation {
        if reduceMotion { return .easeOut(duration: 0.18) }
        return state.visible
            ? .spring(response: 0.42, dampingFraction: 0.72)
            : .spring(response: 0.34, dampingFraction: 0.92)
    }

    var body: some View {
        let m = metrics
        let shape = IslandShape(shoulder: m.shoulder, radius: m.radius)
        ZStack(alignment: .top) {
            shape.fill(.black)
            content
                .padding(.horizontal, m.shoulder)
        }
        .frame(width: m.width + 2 * m.shoulder, height: m.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(m.lifted ? 0.34 : 0), radius: 14, y: 6)
        .scaleEffect(bump, anchor: .top)
        .offset(x: shake)
        // Without a notch to hide in, the sliver fades as it tucks away.
        .opacity(state.visible || notch.exists ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(morph, value: m)
        .animation(state.visible ? .easeOut(duration: 0.12) : .easeIn(duration: 0.3), value: state.visible)
        .onChange(of: state.phase) { _, phase in
            switch phase {
            case .succeeded: pop()
            case .failed: wiggle()
            default: break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.visible, isBanner {
            VStack(spacing: 0) {
                if notch.exists { Color.clear.frame(height: band) }
                banner
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 18)
            }
            .transition(AnyTransition(.blurReplace).combined(with: .opacity))
        } else if notch.exists {
            HStack(spacing: 0) {
                leading
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 13)
                Color.clear.frame(width: gap)
                trailing
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 13)
            }
            .frame(height: band)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.32), value: contentKey)
        } else {
            // No camera to straddle: one centered group that hugs its content.
            HStack(spacing: 8) {
                leading
                trailing
            }
            .frame(maxWidth: .infinity)
            .frame(height: band)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.32), value: contentKey)
        }
    }

    private var contentKey: String {
        guard state.visible else { return "hidden" }
        switch state.phase {
        case .processing: return state.polishing ? "polish" : "transcribe"
        default: return String(describing: state.phase)
        }
    }

    private var processingLabel: String {
        if state.polishing { return state.style == .command ? "Writing" : "Polishing" }
        return "Transcribing"
    }

    private var earTransition: AnyTransition {
        reduceMotion ? .opacity : AnyTransition(.blurReplace).combined(with: .scale(scale: 0.7))
    }

    private var leading: some View {
        Group {
            if state.visible {
                switch state.phase {
                case .arming:
                    MicGlyph(level: 0, live: false)
                case .recording:
                    HStack(spacing: 7) {
                        MicGlyph(level: CGFloat(state.levels.max() ?? 0), live: !reduceMotion)
                        RecordingTimer(start: state.recordingStarted ?? Date())
                    }
                case .processing:
                    ProcessingGlyph(polishing: state.polishing)
                case .succeeded:
                    SuccessBadge()
                case .idle, .failed:
                    EmptyView()
                }
            }
        }
        .id(contentKey)
        .transition(earTransition)
    }

    private var trailing: some View {
        Group {
            if state.visible {
                switch state.phase {
                case .arming:
                    LiveBars(levels: [0, 0, 0, 0], style: state.style, dimmed: true)
                case .recording:
                    LiveBars(levels: state.levels, style: state.style, dimmed: false)
                case .processing:
                    ShimmerText(text: processingLabel, animated: !reduceMotion)
                case .succeeded:
                    Text("Inserted")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                case .idle, .failed:
                    EmptyView()
                }
            }
        }
        .id(contentKey)
        .transition(earTransition)
    }

    private var banner: some View {
        HStack(spacing: 9) {
            if let toast = state.toast {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state.style.gradient)
                    .symbolEffect(.bounce, options: .nonRepeating, value: toast)
                Text(toast)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.mic)
                Text(state.message)
            }
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func pop() {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { bump = 1.07 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) { bump = 1 }
        }
    }

    private func wiggle() {
        guard !reduceMotion else { return }
        Task { @MainActor in
            for offset in [8.0, -7.0, 5.0, -3.0, 0.0] {
                withAnimation(.spring(response: 0.09, dampingFraction: 0.55)) { shake = offset }
                try? await Task.sleep(for: .milliseconds(55))
            }
        }
    }
}

/// Concave top shoulders so it reads as part of the bezel, not a floating pill.
private struct IslandShape: Shape {
    var shoulder: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, radius) }
        set { shoulder = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(shoulder, rect.width / 4, rect.height / 2)
        let r = max(0, min(radius, (rect.width - 2 * s) / 2, rect.height - s))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s),
                          control: CGPoint(x: rect.minX + s, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s + r, y: rect.maxY),
                          control: CGPoint(x: rect.minX + s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - r),
                          control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - s, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Ear content

/// Orange like the system mic indicator; breathes while arming, before it listens.
private struct MicGlyph: View {
    let level: CGFloat
    let live: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let cycle = CGFloat((t / 1.3).truncatingRemainder(dividingBy: 1))
            let breath = 0.6 + 0.4 * (0.5 + 0.5 * sin(t * 5))
            ZStack {
                if live {
                    Circle()
                        .stroke(Palette.mic, lineWidth: 1.4)
                        .scaleEffect(0.9 + cycle * (0.25 + 0.2 * level))
                        .opacity(Double(0.75 * (1 - cycle)))
                }
                Circle()
                    .fill(Palette.mic.opacity(0.2 + 0.25 * level))
                    .scaleEffect(1 + 0.12 * level)
                Image(systemName: "mic.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Palette.mic)
            }
            .opacity(live ? 1 : breath)
        }
        .frame(width: 21, height: 21)
        .animation(.interpolatingSpring(stiffness: 300, damping: 22), value: level)
    }
}

private struct RecordingTimer: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { timeline in
            let seconds = max(0, Int(timeline.date.timeIntervalSince(start)))
            Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.secondary)
                .contentTransition(.numericText(countsDown: false))
                .animation(.snappy, value: seconds)
        }
    }
}

private struct LiveBars: View {
    let levels: [Float]
    let style: OverlayStyle
    let dimmed: Bool
    private let profiles: [CGFloat] = [0.55, 0.85, 1, 0.8, 0.6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(profiles.indices, id: \.self) { index in
                    let level = dimmed ? 0 : self.level(at: index)
                    let sway = 1 + 1.1 * CGFloat(sin(time * 3.2 + Double(index) * 1.2))
                    Capsule()
                        .fill(style.gradient)
                        .frame(width: 3, height: height(level: level, profile: profiles[index], sway: sway))
                        .animation(.interpolatingSpring(stiffness: 420, damping: 26), value: level)
                }
            }
            .opacity(dimmed ? 0.35 + 0.2 * (0.5 + 0.5 * sin(time * 5)) : 1)
        }
        .frame(height: 18)
    }

    /// Five bars from four meter bands: the middle bar blends its neighbours.
    private func level(at index: Int) -> CGFloat {
        func band(_ i: Int) -> CGFloat { i < levels.count ? CGFloat(levels[i]) : 0 }
        switch index {
        case 0: return band(0)
        case 1: return band(1)
        case 2: return (band(1) + band(2)) / 2
        case 3: return band(2)
        default: return band(3)
        }
    }

    private func height(level: CGFloat, profile: CGFloat, sway: CGFloat) -> CGFloat {
        guard level > 0.015 else { return 3 + sway }
        return min(18, 5 + 13 * pow(level, 0.7) * profile)
    }
}

private struct ProcessingGlyph: View {
    let polishing: Bool

    var body: some View {
        Group {
            if polishing {
                Image(systemName: "sparkles")
                    .foregroundStyle(OverlayStyle.dictation.gradient)
                    .brightness(0.15)
                    .symbolEffect(.breathe.plain.byLayer, options: .repeating)
            } else {
                Image(systemName: "waveform")
                    .foregroundStyle(.white.opacity(0.9))
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 21, height: 21)
    }
}

private struct ShimmerText: View {
    let text: String
    let animated: Bool

    var body: some View {
        let label = Text(text).font(.system(size: 12.5, weight: .semibold))
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat((t / 1.4).truncatingRemainder(dividingBy: 1))
                label
                    .foregroundStyle(.white.opacity(0.42))
                    .overlay {
                        label
                            .foregroundStyle(.white)
                            .mask {
                                GeometryReader { geometry in
                                    let w = geometry.size.width
                                    LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                                        .frame(width: w * 0.7)
                                        .offset(x: -w * 0.7 + phase * w * 1.7)
                                }
                            }
                    }
            }
        } else {
            label.foregroundStyle(.white.opacity(0.85))
        }
    }
}

private struct SuccessBadge: View {
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.success)
                .scaleEffect(drawn ? 1 : 0.4)
            CheckmarkShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 9, height: 7)
        }
        .frame(width: 19, height: 19)
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) { drawn = true }
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
