import AppKit
import PressayCore
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Welcome to Pressay"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView(coordinator: coordinator))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        coordinator.permissions.setOnboardingVisible(true)
        ForegroundWindowPresenter.present(window)
    }

    func dismiss() {
        coordinator.permissions.setOnboardingVisible(false)
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        coordinator.permissions.setOnboardingVisible(false)
        return false
    }
}

/// Completion requires a new, real recording and the resulting text in the practice editor.
/// A prepared model, a typed sentence, or a clipboard-only fallback does not finish setup.
struct OnboardingDictationEvidence: Equatable {
    let text: String
    let targetPID: Int32
    let receivedAudio: Bool
    let inserted: Bool
    let completedAt: Date

    func verifies(practiceText: String, startedAt: Date, appPID: Int32) -> Bool {
        let expected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return receivedAudio && inserted && targetPID == appPID && completedAt >= startedAt
            && !expected.isEmpty && practiceText.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }
}

struct OnboardingView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var permissions: PermissionController
    @ObservedObject private var settings: AppSettings
    @State private var step = 0
    @State private var practiceText = ""
    @State private var practiceStartedAt = Date.now
    @FocusState private var practiceFocused: Bool

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        permissions = coordinator.permissions
        settings = coordinator.settings
    }

    private var permission: PermissionController.Kind? {
        (1...3).contains(step) ? PermissionController.Kind.allCases[step - 1] : nil
    }
    private var practiceComplete: Bool {
        coordinator.lastDictationCompletion?.verifies(
            practiceText: practiceText, startedAt: practiceStartedAt,
            appPID: ProcessInfo.processInfo.processIdentifier) == true
    }
    private var microphoneStatus: String {
        if coordinator.liveSession != nil || coordinator.meetingStarting {
            return "Stop the Notetaker before practicing dictation"
        }
        if coordinator.dictationMicrophoneLive { return "Microphone is receiving audio" }
        return coordinator.dictationMicrophoneArming ? "Waiting for microphone audio…" : "Microphone is off"
    }
    private var title: String {
        if let permission { return permission.title }
        switch step {
        case 0: return "Your voice. Your words."
        case 4: return "Prepare your speech model"
        default: return practiceComplete ? "You’re ready to dictate" : "Give it a try"
        }
    }
    private var subtitle: String {
        if let permission { return permission.detail }
        switch step {
        case 0: return "Hold a key, say what’s on your mind, and release. Pressay types it where you’re working."
        case 4: return "Speech recognition runs on your Mac. The model downloads once, then works offline."
        default: return practiceComplete
            ? "Your microphone, speech model and text insertion worked together. You can now dictate in other apps."
            : "Click the field below. Hold \(settings.holdKey.shortcutLabel), speak after the sound, then release to type."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(nsImage: PressayBrand.appIcon).resizable().frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                Spacer()
                Text(step == 0 ? "WELCOME TO PRESSAY" : "STEP \(step) OF 5")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(PressayPalette.muted)
            }.padding(.bottom, 27)
            Text(title).font(.system(size: 31, weight: .semibold)).tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(PressayPalette.muted)
                .lineSpacing(5).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if step == 0 { welcome }
                    else if let permission { permissionStep(permission) }
                    else if step == 4 { modelStep }
                    else { practiceStep }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 25)
            }.scrollIndicators(.hidden)
            Spacer(minLength: 8)
            footer
            HStack(spacing: 5) {
                ForEach(1...5, id: \.self) { index in
                    Capsule().fill(index <= step ? PressayPalette.accent : PressayPalette.line).frame(height: 3)
                }
            }.accessibilityHidden(true).padding(.top, 24)
        }
        .padding(.horizontal, 40).padding(.top, 50).padding(.bottom, 28)
        .frame(width: 540, height: 720, alignment: .topLeading)
        .background(PressayPalette.base).foregroundStyle(PressayPalette.text)
        .toggleStyle(PressaySwitchStyle()).buttonStyle(PressayButtonStyle()).tint(PressayPalette.accent)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { permissions.startMonitoring() }
        .onChange(of: permissions.allGranted) { _, granted in
            // Returning to setup after a revocation must never leave a stale Ready screen.
            if !granted, step >= 4 { goToFirstMissingPermission() }
        }
        .onChange(of: coordinator.modelReady) { _, ready in
            if !ready, step == 5 { step = 4 }
        }
        .onChange(of: step) { _, step in
            permissions.dismissGuide()
            if step == 5 {
                practiceStartedAt = .now
                practiceText = ""
                practiceFocused = true
                coordinator.restartHotkey()
            }
        }
    }

    private var welcome: some View {
        PressayGroup {
            VStack(alignment: .leading, spacing: 22) {
                explanation("lock.shield", "Private by default", "Your speech is transcribed on your Mac. No account is required.")
                explanation("keyboard", "Works where you write", "Three macOS permissions let Pressay hear you, notice your talk key, and type at your cursor.")
                explanation("checkmark.bubble", "Try it before you finish", "We’ll prepare your model and check a real dictation together.")
            }.padding(20)
        }
    }

    private func explanation(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 19)).foregroundStyle(PressayPalette.accent)
                .frame(width: 23).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(PressayPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionStep(_ kind: PermissionController.Kind) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            PressayGroup {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Image(systemName: kind.systemImage).font(.system(size: 26))
                            .foregroundStyle(PressayPalette.accent).accessibilityHidden(true)
                        Spacer()
                        StatusLabel(text: permissions.isGranted(kind) ? "Allowed" : "Not allowed yet",
                                    color: permissions.isGranted(kind) ? PressayPalette.success : PressayPalette.warning)
                    }
                    Text(kind.instructions).font(.system(size: 13)).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                    if !permissions.isGranted(kind) {
                        Button(kind == .microphone ? "Allow microphone" : "Open System Settings") {
                            permissions.request(kind)
                        }.buttonStyle(PressayButtonStyle(kind: .primary))
                    }
                }.padding(22)
            }
            if kind == .microphone, permissions.microphoneRestricted {
                Text("Microphone access is restricted by your Mac’s administrator. Ask them to allow Pressay before continuing.")
                    .font(.system(size: 12)).foregroundStyle(PressayPalette.warning)
            } else {
                Text("This page updates automatically when access changes. You can revoke access at any time in System Settings.")
                    .font(.system(size: 12)).foregroundStyle(PressayPalette.muted)
            }
            Button("Already allowed, but still not working?") { permissions.openPrivacySettings(for: kind) }
                .buttonStyle(PressayButtonStyle(kind: .quiet))
            Text(kind.recoveryInstructions).font(.system(size: 11)).foregroundStyle(PressayPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            PressayGroup {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(PressayPalette.accent).accessibilityHidden(true)
                        Text(coordinator.activeSpeechModelName).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        if coordinator.modelReady { Image(systemName: "checkmark.circle.fill").foregroundStyle(PressayPalette.success) }
                    }
                    Text(coordinator.modelStatus).font(.system(size: 12)).foregroundStyle(PressayPalette.muted)
                    if let fraction = coordinator.modelDownloadProgress {
                        ProgressView(value: fraction).accessibilityLabel("Speech model download")
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 11)).monospacedDigit()
                    } else if coordinator.modelPreparing {
                        ProgressView().controlSize(.small).accessibilityLabel("Preparing speech model")
                    }
                    if !coordinator.modelReady, !coordinator.modelPreparing {
                        Button("Try again") { Task { await coordinator.prepareModel() } }
                    }
                }.padding(22)
            }
            PressaySetting(title: "Hold to talk", detail: "Release to type. Esc to cancel.") {
                KeyCaptureButton(key: $settings.holdKey, onChange: coordinator.restartHotkey,
                                 onCaptureActive: coordinator.keyCaptureActive)
            }
            PressaySetting(title: "Open at login", detail: "Ready every time you open your Mac.") {
                Toggle("Open at login", isOn: $settings.launchAtLogin)
                    .toggleStyle(PressaySwitchStyle(showsLabel: false)).frame(width: 32)
            }
            if let error = settings.launchAtLoginError {
                Text(error).font(.system(size: 11)).foregroundStyle(PressayPalette.danger)
            }
            if !coordinator.modelReady, let error = coordinator.lastError {
                Text(error).font(.system(size: 12)).foregroundStyle(PressayPalette.danger)
            }
            Text("For dictation, the microphone opens when you hold your talk key. A ready model does not mean the microphone is listening.")
                .font(.system(size: 12)).foregroundStyle(PressayPalette.muted)
        }
    }

    private var practiceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try saying “My words, exactly where I need them.”")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(PressayPalette.accent)
            TextEditor(text: $practiceText)
                .font(.system(size: 17)).scrollContentBackground(.hidden)
                .padding(12).frame(height: 150)
                .background(PressayPalette.surface, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PressayPalette.strongLine))
                .focused($practiceFocused)
                .accessibilityLabel("Practice dictation")
                .accessibilityHint("Hold your talk key, speak after the sound, and release. The transcribed words will appear here.")
            Label(microphoneStatus,
                  systemImage: coordinator.dictationMicrophoneLive ? "mic.fill" : "mic.slash")
                .font(.system(size: 12)).foregroundStyle(coordinator.dictationMicrophoneLive ? PressayPalette.success : PressayPalette.muted)
            if practiceComplete {
                Label("Speech captured, transcribed and inserted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(PressayPalette.success)
            } else {
                Text("Use your talk key for this check. Typing or pasting a sample sentence won’t complete it.")
                    .font(.system(size: 12)).foregroundStyle(PressayPalette.muted)
            }
            Button("Try another dictation") {
                practiceText = ""
                practiceStartedAt = .now
                practiceFocused = true
            }.buttonStyle(PressayButtonStyle(kind: .quiet))
            if let error = coordinator.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(PressayPalette.danger)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 { Button("Back") { step -= 1 } }
            Spacer()
            Button(step == 0 ? "Set up Pressay" : step == 5 ? "Start dictating" : "Continue") {
                if step == 5 {
                    coordinator.completeOnboarding(practiceText: practiceText, startedAt: practiceStartedAt)
                } else if step == 0 {
                    goToFirstMissingPermission()
                } else {
                    step += 1
                }
            }
            .buttonStyle(PressayButtonStyle(kind: .primary))
            .disabled(!canContinue)
            .keyboardShortcut(.defaultAction)
        }
    }
    private var canContinue: Bool {
        if let permission { return permissions.isGranted(permission) }
        if step == 4 { return permissions.allGranted && coordinator.modelReady }
        if step == 5 { return permissions.allGranted && coordinator.modelReady && practiceComplete }
        return true
    }
    private func goToFirstMissingPermission() {
        step = PermissionController.Kind.allCases.firstIndex { !permissions.isGranted($0) }.map { $0 + 1 } ?? 4
    }
}
