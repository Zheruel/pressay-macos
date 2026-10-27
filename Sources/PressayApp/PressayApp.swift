import AppKit
import SwiftUI

@main
struct PressayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = AppCoordinator.shared
    @StateObject private var updates = AppCoordinator.shared.updates

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: coordinator)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .overlay(alignment: .topTrailing) {
                    if updates.hasUpdate {
                        Circle().fill(PressayPalette.accent).frame(width: 5, height: 5)
                    }
                }
                .accessibilityLabel(updates.hasUpdate ? "Pressay, update available" : "Pressay")
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: updates) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // These entry points are deliberately nonisolated and hop explicitly.
    // The compiler-emitted @MainActor check at @objc entry points crashes in
    // swift_task_isCurrentExecutorWithFlagsImpl on swiftlang 6.3.x / macOS 26
    // when executor state is under load (swiftlang/swift#89197).
    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppCoordinator.shared.start() }
        observeSystemMicReleases()
    }

    /// An active mic must not survive sleep or screen lock — resuming into a
    /// half-torn-down Bluetooth link is how the input wedges into silence.
    private nonisolated func observeSystemMicReleases() {
        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppCoordinator.shared.releaseMicForSystemEvent() }
            }
        }
    }

    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppCoordinator.shared.liveSession != nil else {
                AppCoordinator.shared.notes.flush()
                return .terminateNow
            }
            Task { @MainActor in
                await AppCoordinator.shared.finishRecordingForQuit()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    // ggml's Metal device teardown aborts in a C++ static destructor during
    // normal exit(); skipping atexit handlers avoids a crash report per quit.
    nonisolated func applicationWillTerminate(_ notification: Notification) {
        _exit(0)
    }

    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            AppCoordinator.shared.permissions.refresh()
            AppCoordinator.shared.settings.refreshLaunchAtLogin()
        }
    }

    nonisolated func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        Task { @MainActor in
            let coordinator = AppCoordinator.shared
            // Otherwise closing onboarding strands an unfinished setup.
            if coordinator.settings.onboardingComplete {
                coordinator.showSettings()
            } else {
                coordinator.showOnboarding()
            }
        }
        return true
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
