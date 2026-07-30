import AppKit
import ApplicationServices
@preconcurrency import AVFoundation
import CoreGraphics

@MainActor
final class PermissionController: ObservableObject {
    enum Kind: CaseIterable, Identifiable, Equatable {
        case microphone
        case accessibility
        case inputMonitoring

        var id: Self { self }
        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .accessibility: "Accessibility"
            case .inputMonitoring: "Input Monitoring"
            }
        }
        var detail: String {
            switch self {
            case .microphone: "Records while you hold the dictation key, plus a half-second before it."
            case .accessibility: "Inserts the finished prompt at your cursor."
            case .inputMonitoring: "Detects your hold-to-talk key in any application."
            }
        }
        var systemImage: String {
            switch self {
            case .microphone: "mic.fill"
            case .accessibility: "accessibility"
            case .inputMonitoring: "keyboard.fill"
            }
        }
    }

    @Published private(set) var microphoneGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false
    var onStatusChange: (() -> Void)?
    private var monitoringTask: Task<Void, Never>?

    var allGranted: Bool { microphoneGranted && accessibilityGranted && inputMonitoringGranted }

    func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .microphone: microphoneGranted
        case .accessibility: accessibilityGranted
        case .inputMonitoring: inputMonitoringGranted
        }
    }

    func refresh() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        let changed = microphone != microphoneGranted
            || accessibility != accessibilityGranted
            || inputMonitoring != inputMonitoringGranted
        microphoneGranted = microphone
        accessibilityGranted = accessibility
        inputMonitoringGranted = inputMonitoring
        if changed { onStatusChange?() }
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        refresh()
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                refresh()
                // Every tick hits tccd. This is now the only refresh: the
                // key-press path no longer does one synchronously, because it
                // runs inside the CGEventTap callback.
                let delay: Duration = allGranted ? .seconds(10) : .milliseconds(400)
                try? await Task.sleep(for: delay)
            }
        }
    }

    func request(_ kind: Kind) {
        switch kind {
        case .microphone:
            Task { await requestMicrophone() }
        case .accessibility:
            requestAccessibility()
        case .inputMonitoring:
            requestInputMonitoring()
        }
    }

    func requestMicrophone() async {
        microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    func requestAccessibility() {
        // The exported constant is imported as mutable global state, which Swift
        // 6 rejects from actor-isolated code. Its documented CFString value is stable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        openSettingsIfStillDenied(.accessibility)
    }

    func requestInputMonitoring() {
        inputMonitoringGranted = CGRequestListenEventAccess()
        openSettingsIfStillDenied(.inputMonitoring)
    }

    private func openSettingsIfStillDenied(_ kind: Kind) {
        Task { @MainActor [weak self] in
            // Both TCC request APIs return before macOS finishes presenting its
            // own prompt. Give that prompt a moment; if access is still denied
            // (including a stale/previously denied record), take the user to the
            // exact Privacy & Security pane instead of making Allow look inert.
            try? await Task.sleep(for: .milliseconds(900))
            guard let self else { return }
            refresh()
            if !isGranted(kind) {
                openPrivacySettings(for: kind)
            }
        }
    }

    func openPrivacySettings(for kind: Kind? = nil) {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case nil: anchor = "Privacy"
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
