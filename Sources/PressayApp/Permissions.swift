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
            case .microphone: "Hears your voice during dictation and meetings."
            case .accessibility: "Types the finished text at your cursor."
            case .inputMonitoring: "Notices your talk key in any app."
            }
        }
        var systemImage: String {
            switch self {
            case .microphone: "mic.fill"
            case .accessibility: "accessibility"
            case .inputMonitoring: "keyboard.fill"
            }
        }
        var instructions: String {
            switch self {
            case .microphone:
                "Choose Allow in the macOS prompt. If you previously denied access, turn on Pressay in the Microphone list."
            case .accessibility:
                "Turn on Pressay in the Accessibility list. If it is missing, drag the app from the floating guide into the list, then turn it on."
            case .inputMonitoring:
                "Turn on Pressay in the Input Monitoring list. macOS may ask you to quit and reopen Pressay after changing this permission."
            }
        }
        var recoveryInstructions: String {
            switch self {
            case .microphone:
                "Microphone access must be requested by the app; dragging an app into this list does not grant access. If your microphone is managed, contact your administrator."
            case .accessibility, .inputMonitoring:
                "If an old entry no longer works after an update, remove it, add the current Pressay app, turn it on, then reopen Pressay."
            }
        }
    }

    @Published private(set) var microphoneGranted = false
    @Published private(set) var microphoneRestricted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false
    #if DEBUG
    private var reviewPermissions: Set<Kind> = []
    #endif
    var onStatusChange: (() -> Void)?
    private var monitoringTask: Task<Void, Never>?
    private lazy var guide = PermissionGuideController(permissions: self)
    private var onboardingVisible = false

    var allGranted: Bool { microphoneGranted && accessibilityGranted && inputMonitoringGranted }

    func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .microphone: microphoneGranted
        case .accessibility: accessibilityGranted
        case .inputMonitoring: inputMonitoringGranted
        }
    }

    func refresh() {
        #if DEBUG
        if DesignReview.enabled {
            let allowed = ProcessInfo.processInfo.environment["PRESSAY_REVIEW_PERMISSIONS"] != "missing"
            let microphone = allowed || reviewPermissions.contains(.microphone)
            let accessibility = allowed || reviewPermissions.contains(.accessibility)
            let inputMonitoring = allowed || reviewPermissions.contains(.inputMonitoring)
            if microphoneGranted != microphone { microphoneGranted = microphone }
            if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
            if inputMonitoringGranted != inputMonitoring { inputMonitoringGranted = inputMonitoring }
            return
        }
        #endif

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let microphone = microphoneStatus == .authorized
        if microphoneRestricted != (microphoneStatus == .restricted) {
            microphoneRestricted = microphoneStatus == .restricted
        }
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        let changed = microphone != microphoneGranted
            || accessibility != accessibilityGranted
            || inputMonitoring != inputMonitoringGranted
        if microphoneGranted != microphone { microphoneGranted = microphone }
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
        if inputMonitoringGranted != inputMonitoring { inputMonitoringGranted = inputMonitoring }
        guide.refresh()
        if changed { onStatusChange?() }
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        refresh()
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                refresh()
                // Every tick hits tccd. This is the only refresh: the key-press path runs
                // inside the CGEventTap callback and can't afford a synchronous one.
                let delay: Duration = allGranted && !onboardingVisible ? .seconds(10) : .milliseconds(400)
                try? await Task.sleep(for: delay)
            }
        }
    }

    func request(_ kind: Kind) {
        #if DEBUG
        if DesignReview.enabled { reviewPermissions.insert(kind); refresh(); return }
        #endif
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
        // A previously denied record returns false without a prompt.
        if !microphoneGranted { openPrivacySettings(for: .microphone) }
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
        if let kind, !isGranted(kind) {
            guide.present(kind)
        }
    }

    func dismissGuide() { guide.dismiss() }

    func setOnboardingVisible(_ visible: Bool) {
        guard onboardingVisible != visible else { return }
        onboardingVisible = visible
        if !visible { dismissGuide() }
        // Restart the wait so an existing ten-second idle sleep cannot delay setup status.
        monitoringTask?.cancel()
        monitoringTask = nil
        startMonitoring()
    }
}
