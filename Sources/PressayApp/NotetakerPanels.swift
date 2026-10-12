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
        let height: CGFloat = coordinator.settings.showLiveTranscript ? 460 : 300
        let panel = panel ?? FloatingPanel(size: NSSize(width: 340, height: height), titled: true)
        self.panel = panel
        panel.minSize = NSSize(width: 300, height: 220)
        panel.contentViewController = NSHostingController(rootView: NotepadView(coordinator: coordinator, session: session))
        panel.setContentSize(NSSize(width: 340, height: height))
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

    init(coordinator: AppCoordinator, session: LiveSession) {
        self.coordinator = coordinator
        self.session = session
        settings = coordinator.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiveHeader(session: session, compact: true)
                .padding(.top, 6)
            if let notice = session.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }
            if settings.showLiveTranscript {
                liveTranscript
                Divider()
            }
            MyNotesEditor(text: myNotes, fontSize: 13)
                .frame(minHeight: 70)
            HStack {
                Button("Open Notetaker") { coordinator.showNotes() }
                Spacer()
                Button {
                    coordinator.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(session.phase != .recording)
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .ignoresSafeArea()
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
                VStack(alignment: .leading, spacing: 6) {
                    if session.lines.isEmpty {
                        Text("Listening…").foregroundStyle(.secondary)
                    }
                    ForEach(Array(session.lines.suffix(40).enumerated()), id: \.offset) { _, line in
                        (Text(line.speaker == .me ? "You  " : "Others  ")
                            .foregroundStyle(line.speaker == .me ? Color.accentColor : .orange)
                            .fontWeight(.semibold)
                            + Text(line.text))
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 90)
            .onChange(of: session.lines.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

// MARK: - Call prompt

@MainActor
final class CallPromptController {
    private var panel: FloatingPanel?
    private var timeout: Task<Void, Never>?

    func show(app: String, onStart: @escaping () -> Void) {
        dismiss()
        let panel = FloatingPanel(size: NSSize(width: 360, height: 84), titled: false)
        let view = CallPromptView(
            app: app,
            onStart: { [weak self] in
                self?.dismiss()
                onStart()
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 84)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.placeTopRight()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
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
        HStack(spacing: 12) {
            Image(nsImage: PressayBrand.appIcon)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Take notes for this call?").font(.headline)
                Text("\(app) is using your microphone.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            VStack(spacing: 6) {
                Button("Start", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                Button("Not Now", action: onDismiss)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
    }
}
