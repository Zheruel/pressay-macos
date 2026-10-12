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
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Pressay Settings"
        // Keeps the titlebar height steady when a pane adds toolbar items.
        window.toolbar = NSToolbar(identifier: "PressaySettings")
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 740, height: 520)
        // Wider strands grouped-form rows in empty space.
        window.maxSize = NSSize(width: 920, height: CGFloat.greatestFiniteMagnitude)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PressaySettingsWindow26")
        // A frame autosaved before the width cap existed can exceed maxSize;
        // restore only clamps future resizes, so clamp the restored frame too.
        if window.frame.width > window.maxSize.width {
            var frame = window.frame
            frame.size.width = window.maxSize.width
            window.setFrame(frame, display: false)
        }
        let hosting = NSHostingController(rootView: SettingsRootView(coordinator: coordinator))
        // Lets the split view own the toolbar and floating sidebar.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 780, height: 640))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        ForegroundWindowPresenter.present(window)
    }
}
