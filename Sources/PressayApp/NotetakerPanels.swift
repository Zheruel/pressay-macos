import AppKit
import PressayCore
import SwiftUI

/// A floating panel that stays above other apps without taking focus until clicked, and asks to be left out
/// of screen captures (honoured by most, not all, capture methods).
private final class FloatingPanel: NSPanel {
    init(size: NSSize, titled: Bool) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: titled
                ? [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView, .utilityWindow]
                : [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        sharingType = .none
        #if DEBUG
            if DesignReview.enabled { sharingType = .readOnly }
        #endif
        if titled {
            titleVisibility = .hidden
            titlebarAppearsTransparent = true
        } else {
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
        }
    }

    override var canBecomeKey: Bool { true }

    func placeTopRight(margin: CGFloat = 16) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: screen.maxX - frame.width - margin, y: screen.maxY - frame.height - margin))
    }
}

// MARK: - Notepad

@MainActor
final class NotepadPanelController {
    private unowned let coordinator: AppCoordinator
    private var panel: FloatingPanel?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func show(session: LiveSession) {
        if let panel, panel.isVisible { return }
        let height: CGFloat = coordinator.settings.showLiveTranscript ? 490 : 300
        let panel = panel ?? FloatingPanel(size: NSSize(width: 360, height: height), titled: false)
        self.panel = panel
        panel.styleMask.insert(.resizable)
        panel.minSize = NSSize(width: 340, height: 220)
        panel.contentViewController = NSHostingController(
            rootView: NotepadView(coordinator: coordinator, session: session))
        panel.setContentSize(NSSize(width: 360, height: height))
        panel.placeTopRight()
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
    }
}

private struct NotepadView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var session: LiveSession
    @ObservedObject private var settings: AppSettings
    @State private var transcriptHeight: CGFloat = 75

    init(coordinator: AppCoordinator, session: LiveSession) {
        self.coordinator = coordinator
        self.session = session
        settings = coordinator.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let notice = session.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(PressayPalette.warning).padding(14)
            }
            if settings.showLiveTranscript {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Text("Live transcript").font(.system(size: 12, weight: .semibold)).foregroundStyle(
                            PressayPalette.muted)
                        Spacer()
                        Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(PressayPalette.accent)
                    }
                    liveTranscript
                }.padding(.horizontal, 18).padding(.vertical, 17)
                Rectangle().fill(PressayPalette.line).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 13) {
                Text("My notes").font(.system(size: 12, weight: .semibold)).foregroundStyle(PressayPalette.muted)
                MyNotesEditor(text: myNotes, fontSize: 13).frame(minHeight: 70)
            }.padding(.horizontal, 18).padding(.vertical, 17)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(PressayPalette.text).background(PressayPalette.base)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PressayPalette.strongLine))
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(session.phase == .recording ? PressayPalette.danger : PressayPalette.muted).frame(
                width: 7, height: 7)
            TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                Text(
                    TranscriptLine.timestamp(
                        session.offset + (session.stoppedAt ?? context.date).timeIntervalSince(session.startedAt))
                )
                .monospacedDigit().font(.system(size: 14, weight: .semibold))
            }
            if session.phase == .recording {
                RecordingLevelBars(level: max(session.micLevel, session.othersLevel))
            }
            Text(session.phase == .finishing ? "Finishing…" : "Recording")
                .font(.system(size: 11)).foregroundStyle(PressayPalette.muted).frame(
                    maxWidth: .infinity, alignment: .leading)
            Button {
                coordinator.showNotes()
            } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 12)).frame(width: 26, height: 30)
            }.buttonStyle(PressayPlainButtonStyle()).foregroundStyle(PressayPalette.muted).help("Open in Pressay").accessibilityLabel(
                "Open in Pressay")
            Button("Stop") { coordinator.stopRecording() }
                .buttonStyle(PressayButtonStyle(kind: .danger)).disabled(session.phase == .finishing)
        }
        .padding(14).background(PressayPalette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(PressayPalette.line).frame(height: 1) }
    }

    private var myNotes: Binding<String> {
        let id = session.noteID
        return Binding(
            get: { coordinator.notes.note(id)?.myNotes ?? "" },
            set: { text in coordinator.notes.modify(id, persist: false) { $0.myNotes = text } }
        )
    }

    private var liveTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    if session.lines.isEmpty {
                        Text("Listening…").foregroundStyle(.secondary)
                    }
                    let note = coordinator.notes.note(session.noteID)
                    ForEach(Array(session.lines.suffix(40).enumerated()), id: \.offset) { _, line in
                        let label = note?.label(for: line) ?? (line.speaker == .me ? "You" : "Others")
                        Text(
                            "\(Text(label + "  ").foregroundStyle(line.speaker == .me ? PressayPalette.accent : PressayPalette.warning).fontWeight(.semibold))\(line.text)"
                        )
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: NotepadTranscriptHeight.self, value: geometry.size.height)
                    }
                }
            }
            .frame(height: min(max(transcriptHeight, 60), 185))
            .onPreferenceChange(NotepadTranscriptHeight.self) { height in
                if abs(transcriptHeight - height) > 1 { transcriptHeight = height }
            }
            .onChange(of: session.lines.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct NotepadTranscriptHeight: PreferenceKey {
    static let defaultValue: CGFloat = 75
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Call prompt

@MainActor
final class CallPromptController {
    private var panel: FloatingPanel?
    private var timeout: Task<Void, Never>?

    func show(app: String, onStart: @escaping () -> Void) {
        dismiss()
        let panel = FloatingPanel(size: NSSize(width: 496, height: 104), titled: false)
        let view = CallPromptView(
            app: app,
            onStart: { [weak self] in
                self?.dismiss()
                onStart()
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 496, height: 104)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.placeTopRight()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.2
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct CallPromptView: View {
    let app: String
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(nsImage: PressayBrand.appIcon).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("Take notes for this call?").font(.system(size: 13, weight: .semibold))
                Text("\(app) is using your microphone.").font(.system(size: 11)).foregroundStyle(PressayPalette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button("Not now", action: onDismiss).buttonStyle(PressayButtonStyle(kind: .quiet))
                Button("Start", action: onStart).buttonStyle(PressayButtonStyle(kind: .primary))
            }
        }
        .padding(20).frame(width: 496, height: 104)
        .foregroundStyle(PressayPalette.text).background(PressayPalette.base, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PressayPalette.strongLine))
    }
}

private struct RecordingLevelBars: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<7) { index in
                Capsule().fill(PressayPalette.danger)
                    .frame(width: 2, height: max(3, CGFloat(level) * [8, 14, 18, 12, 20, 16, 9][index]))
            }
        }.frame(width: 26, height: 18).accessibilityHidden(true)
    }
}
