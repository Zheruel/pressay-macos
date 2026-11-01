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

