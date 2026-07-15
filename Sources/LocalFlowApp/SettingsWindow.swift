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
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PressaySettingsWindow")
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
