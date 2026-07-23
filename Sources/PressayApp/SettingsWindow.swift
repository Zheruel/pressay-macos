import AppKit
import SwiftUI

@MainActor
enum ForegroundWindowPresenter {
    static func present(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(coordinator: AppCoordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Pressay Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 760, height: 540)
        // The content column is capped at ~760 pt; letting the window stretch
        // arbitrarily wide just strands it in empty space.
        window.maxSize = NSSize(width: 1080, height: CGFloat.greatestFiniteMagnitude)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PressaySettingsWindow")
        // A frame autosaved before the width cap existed can exceed maxSize;
        // restore only clamps future resizes, so clamp the restored frame too.
        if window.frame.width > window.maxSize.width {
            var frame = window.frame
            frame.size.width = window.maxSize.width
            window.setFrame(frame, display: false)
        }
        window.contentView = NSHostingView(rootView: SettingsRootView(coordinator: coordinator))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        ForegroundWindowPresenter.present(window)
    }
}
