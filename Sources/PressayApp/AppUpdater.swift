import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns checking, signature verification, replacement, and relaunch.
/// This driver keeps its presentation in Pressay instead of opening update dialogs.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    enum Phase { case idle, checking, available, downloading, preparing, waiting, installing, current, failed }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var version = ""
    @Published private(set) var progress: Double?
    @Published private(set) var errorDetail = ""
    @Published private var canCheckWithSparkle = false
    @Published var automaticallyChecks = true {
        didSet { updater?.automaticallyChecksForUpdates = automaticallyChecks }
    }

    var isBusy: () -> Bool = { false }
    var showInApp: () -> Void = {}
    var willRelaunch: () -> Void = {}
    var isInstalling: Bool { phase == .installing }
    var showsNotice: Bool { phase != .idle }
    var hasUpdate: Bool { [.available, .downloading, .preparing, .waiting, .installing].contains(phase) }
    var canCheck: Bool { canCheckWithSparkle && !hasUpdate && phase != .checking }

    private var updater: SPUUpdater?
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var readyToInstall = false
    private var installRequested = false
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0

    func start(bundle: Bundle = .main) {
        guard updater == nil, bundle.bundleURL.pathExtension == "app" else { return }
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckWithSparkle)
        do {
            try updater.start()
            automaticallyChecks = updater.automaticallyChecksForUpdates
        } catch {
            fail(error)
        }
    }

    func check() {
        guard let updater, canCheck else { return }
        installRequested = false
        updater.checkForUpdates()
    }

    func performAction() {
        switch phase {
        case .available: installRequested = true; installIfIdle()
        case .waiting:
            installRequested = false
            if readyToInstall, let reply = choice {
                // A prepared Sparkle update otherwise installs on quit, even after dismissing its UI.
                choice = nil
                phase = .idle
                reply(.skip)
            } else {
                phase = .available
            }
        case .failed:
            guard let updater, updater.canCheckForUpdates else { return }
            // Retry the whole Sparkle cycle; never reuse an archive after verification failed.
            installRequested = !version.isEmpty
            updater.checkForUpdates()
        case .current: phase = .idle
        default: break
        }
    }

    func resumeIfIdle() {
        if phase == .waiting, installRequested { installIfIdle() }
    }

    private func installIfIdle() {
        guard let reply = choice else { return }
        guard !isBusy() else { phase = .waiting; return }
        choice = nil
        phase = readyToInstall ? .installing : .downloading
        progress = nil
        reply(.install)
    }

    private func fail(_ error: Error) {
        choice = nil
        progress = nil
        errorDetail = error.localizedDescription
        phase = .failed
    }

    // MARK: Sparkle presentation

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticallyChecks, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        phase = .checking
        showInApp()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !appcastItem.isInformationOnlyUpdate, !appcastItem.isMajorUpgrade else {
            reply(.dismiss)
            errorDetail = "This release needs a manual download from GitHub."
            phase = .failed
            return
        }
        version = appcastItem.displayVersionString
        readyToInstall = state.stage == .installing
        choice = reply
        phase = .available
        if installRequested { installIfIdle() }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        version = ""
        phase = .current
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        fail(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedBytes = 0
        receivedBytes = 0
        progress = nil
        phase = .downloading
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        progress = expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : nil
    }

    func showDownloadDidStartExtractingUpdate() { phase = .preparing; progress = nil }
    func showExtractionReceivedProgress(_ progress: Double) { self.progress = min(1, max(0, progress)) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyToInstall = true
        choice = reply
        if installRequested { installIfIdle() } else { phase = .available }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                             retryTerminatingApplication: @escaping () -> Void) { phase = .installing }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        phase = .current
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        choice = nil
        readyToInstall = false
        installRequested = false
        progress = nil
        if phase != .failed && phase != .current { phase = .idle }
    }

    func showUpdateInFocus() { showInApp() }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { willRelaunch() }

    #if DEBUG
    func preview(_ state: String) {
        version = "1.13.0"
        phase = ["available": .available, "downloading": .downloading, "waiting": .waiting,
                 "error": .failed, "current": .current][state] ?? .idle
        progress = phase == .downloading ? 0.42 : nil
        errorDetail = "The connection was interrupted."
    }
    #endif
}

struct UpdateNoticeView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        if updater.showsNotice {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(PressayPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if [.checking, .downloading, .preparing, .installing].contains(updater.phase) {
                    ProgressView(value: updater.progress).progressViewStyle(.linear)
                        .accessibilityLabel(title)
                }
                if let action {
                    Button { updater.performAction() } label: {
                        Text(action).frame(maxWidth: .infinity)
                    }
                        .buttonStyle(PressayButtonStyle(kind: updater.phase == .waiting ? .standard : .primary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(PressayPalette.surface, in: .rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PressayPalette.line))
            .padding(.bottom, 14)
            .help(updater.phase == .failed ? updater.errorDetail : "")
        }
    }

    private var title: String {
        switch updater.phase {
        case .idle: ""
        case .checking: "Checking for updates…"
        case .available: "Update available"
        case .downloading: "Downloading update…"
        case .preparing: "Preparing update…"
        case .waiting: "Update after recording"
        case .installing: "Restarting Pressay…"
        case .current: "You’re up to date"
        case .failed: "Update couldn’t finish"
        }
    }
    private var detail: String {
        switch updater.phase {
        case .available: "Pressay \(updater.version) is ready."
        case .waiting: "Your recording will finish first."
        case .failed: "Pressay is unchanged. Try again."
        case .current: "You have the latest version."
        case .installing: "Your update is being installed."
        default: "You can keep using Pressay."
        }
    }
    private var action: String? {
        switch updater.phase {
        case .available: "Install and Restart"
        case .waiting: "Cancel update"
        case .failed: "Try Again"
        case .current: "Done"
        default: nil
        }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
    }
}

struct UpdatePreferencesView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        PressayGroup {
            PressaySetting(title: "Check for updates automatically", detail: "Updates install only when you choose.") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                    .toggleStyle(PressaySwitchStyle(showsLabel: false)).frame(width: 32)
            }
            PressaySetting(title: "Pressay \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")") {
                CheckForUpdatesButton(updater: updater)
            }
        }
    }
}
