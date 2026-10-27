import AppKit
import Combine
import Sparkle
import SwiftUI

// Keep Sparkle’s status inside Pressay instead of opening update dialogs.
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
        // Preserve the user’s original choice for Retry, including checks without installation.
        if phase != .failed { installRequested = false }
        progress = nil
        if phase != .failed && phase != .current { phase = .idle }
    }

    func showUpdateInFocus() { showInApp() }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { willRelaunch() }

    #if DEBUG
    func preview(_ state: String) {
        version = "1.13.0"
        phase = ["available": .available, "downloading": .downloading, "waiting": .waiting,
                 "error": .failed, "current": .current, "checking": .checking,
                 "preparing": .preparing, "installing": .installing][state] ?? .idle
        progress = phase == .downloading ? 0.42 : nil
        errorDetail = "The connection was interrupted."
    }
    #endif
}

struct UpdateNoticeView: View {
    @ObservedObject var updater: AppUpdater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        if updater.showsNotice {
            Group {
                if actionable {
                    Button { updater.performAction() } label: { content }
                        .buttonStyle(.plain)
                        .focused($focused)
                        .onHover { hovering = $0 }
                        .overlay {
                            Capsule().strokeBorder(focused ? PressayPalette.accent : .clear, lineWidth: 2)
                                .padding(-3)
                        }
                        .accessibilityLabel(actionLabel)
                        .accessibilityValue(accessibilityValue)
                        .accessibilityHint(detail)
                } else {
                    content.accessibilityElement(children: .ignore)
                        .accessibilityLabel(title)
                        .accessibilityValue(accessibilityValue)
                        .accessibilityHint(detail)
                }
            }
            .padding(.vertical, 4)
            .padding(.bottom, 8)
            .help(detail)
            .onChange(of: updater.phase) { hovering = false }
        }
    }

    private var actionable: Bool { [.available, .waiting, .failed, .current].contains(updater.phase) }
    private var working: Bool { [.checking, .downloading, .preparing, .installing].contains(updater.phase) }
    private var fillProgress: Double {
        switch updater.phase {
        case .downloading: updater.progress ?? 0
        case .preparing, .installing: 1
        default: 0
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            Group {
                if working {
                    UpdateSpinner()
                } else {
                    Image(systemName: updater.phase == .failed ? "exclamationmark.triangle"
                          : updater.phase == .current ? "checkmark.circle"
                          : updater.phase == .waiting ? "clock" : "arrow.down.circle")
                        .font(.system(size: 13))
                }
            }
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            if updater.phase == .downloading, let progress = updater.progress {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(PressayPalette.updateSecondary)
            } else if let trailing {
                Text(trailing).font(.system(size: 11)).underline()
                    .foregroundStyle(PressayPalette.updateSecondary)
            }
        }
        .foregroundStyle(PressayPalette.text)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
        .background {
            GeometryReader { geometry in
                PressayPalette.updateTrack
                    .overlay(alignment: .leading) {
                        PressayPalette.updateFill.frame(width: geometry.size.width * fillProgress)
                    }
                    .animation(reduceMotion || updater.phase != .downloading ? nil : .easeOut(duration: 0.18), value: fillProgress)
            }
        }
        .overlay { if hovering { PressayPalette.text.opacity(0.04) } }
        .clipShape(.capsule)
        .contentShape(.capsule)
    }

    private var title: String {
        switch updater.phase {
        case .idle: ""
        case .checking: "Checking…"
        case .available: "Update and restart"
        case .downloading: "Downloading…"
        case .preparing: "Preparing…"
        case .waiting: "After recording"
        case .installing: "Restarting…"
        case .current: "Up to date"
        case .failed: "Update failed"
        }
    }
    private var trailing: String? {
        switch updater.phase {
        case .waiting: "Cancel"
        case .failed: "Retry"
        case .current: "Done"
        default: nil
        }
    }
    private var actionLabel: String {
        switch updater.phase {
        case .waiting: "Cancel queued update"
        case .failed: "Retry update"
        case .current: "Dismiss update status"
        default: title
        }
    }
    private var accessibilityValue: String {
        if updater.phase == .downloading, let progress = updater.progress {
            return progress.formatted(.percent.precision(.fractionLength(0)))
        }
        return trailing == nil ? "" : title
    }
    private var detail: String {
        switch updater.phase {
        case .available: "Pressay \(updater.version) is available. Download, install, and restart."
        case .checking: "Checking for updates."
        case .waiting: "Pressay will update and restart after recording and processing finish. Click to cancel."
        case .failed: updater.errorDetail
        case .current: "You’re using the latest version. Click to dismiss."
        case .preparing: "Verifying and preparing the update. Pressay will restart automatically."
        case .installing: "Restarting Pressay to finish the update."
        default: "Downloading Pressay \(updater.version). You can keep using the app."
        }
    }
}

private struct UpdateSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false

    var body: some View {
        Circle().trim(from: 0.08, to: 0.75)
            .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(rotating && !reduceMotion ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false), value: rotating && !reduceMotion)
            .onAppear { rotating = true }
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
