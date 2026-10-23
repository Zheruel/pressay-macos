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
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        self.coordinator = coordinator

        window.title = "Pressay"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PressayMainWindow")
        let hosting = NSHostingController(rootView: SettingsRootView(coordinator: coordinator))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1080, height: 740))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var isKey: Bool { window?.isKeyWindow == true }

    func windowDidResignKey(_ notification: Notification) {
        // Switching to the call app mid-meeting brings up the notepad.
        coordinator?.showNotepadIfRecording()
    }

    private weak var coordinator: AppCoordinator?

    func present() {
        guard let window else { return }
        ForegroundWindowPresenter.present(window)
    }
}
