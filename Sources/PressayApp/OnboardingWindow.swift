import AppKit
import PressayCore
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Welcome to Pressay"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Onboarding is a normal app window. Only the tiny recording overlay
        // should float above whichever app the user is dictating into.
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
        ForegroundWindowPresenter.present(window)
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

struct OnboardingView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var permissions: PermissionController
    @ObservedObject private var settings: AppSettings

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        permissions = coordinator.permissions
        settings = coordinator.settings
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 40)
            if permissions.allGranted {
                features
                    .padding(.top, 24)
                    .padding(.horizontal, 44)
            }
            Form {
                if permissions.allGranted {
                    readySections
                } else {
                    permissionSection
                }
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .padding(.horizontal, 24)
            footer
                .padding(.horizontal, 44)
                .padding(.top, 8)
                .padding(.bottom, 28)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy(duration: 0.3), value: permissions.allGranted)
        .onAppear { permissions.startMonitoring() }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Image(nsImage: PressayBrand.appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
            Text("Welcome to Pressay")
                .font(.largeTitle.weight(.bold))
                .padding(.top, 14)
            Text(permissions.allGranted
                 ? "Dictation that types for you, in any app."
                 : "Pressay needs three permissions to hear you and type for you. Audio never leaves your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .padding(.horizontal, 40)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 16) {
            FeatureRow(
                systemImage: "keyboard",
                title: "Hold \(settings.holdKey.displayName) to talk",
                detail: "Let go, and Pressay types what you said at your cursor."
            )
            FeatureRow(
                systemImage: "lock.fill",
                title: "Private by default",
                detail: "Speech is transcribed on this Mac. Audio never leaves it."
            )
            FeatureRow(
                systemImage: "character.book.closed.fill",
                title: "Spells your words your way",
                detail: "Add names and jargon to the dictionary in Settings."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionSection: some View {
        Section {
            ForEach(PermissionController.Kind.allCases) { kind in
                LabeledContent {
                    if permissions.isGranted(kind) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title3)
                            .accessibilityLabel("Allowed")
                    } else {
                        Button("Allow") { permissions.request(kind) }
                            .help("If nothing appears, Pressay opens the Privacy & Security page.")
                    }
                } label: {
                    Label {
                        Text(kind.title)
                        Text(kind.detail)
                    } icon: {
                        Image(systemName: kind.systemImage)
                            .foregroundStyle(.tint)
                    }
                }
                .contextMenu {
                    Button("Open Privacy & Security…") { permissions.openPrivacySettings(for: kind) }
                }
            }
        } footer: {
            Text("Pressay notices each approval on its own, so you can keep this window open.")
        }
    }

    @ViewBuilder
    private var readySections: some View {
        Section {
            LabeledContent("Hold to talk") {
                KeyCaptureButton(
                    key: $settings.holdKey,
                    onChange: { coordinator.restartHotkey() },
                    onCaptureActive: coordinator.keyCaptureActive
                )
            }
            Toggle("Open at login", isOn: $settings.launchAtLogin)
            LabeledContent {
                modelStatus
            } label: {
                Text("Speech model")
                Text(settings.asrModel.displayName)
            }
        } footer: {
            if let error = settings.launchAtLoginError {
                Text(error)
            } else {
                Text("You can change these later in Settings.")
            }
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        if coordinator.modelPreparing {
            if let progress = coordinator.modelDownloadProgress {
                HStack(spacing: 8) {
                    ProgressView(value: progress).frame(width: 90)
                    Text("\(Int((progress * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } else if coordinator.modelReady {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Ready").foregroundStyle(.secondary)
            }
        } else {
            Button("Retry") { Task { await coordinator.prepareModel() } }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if permissions.allGranted {
            Button {
                coordinator.completeOnboarding()
            } label: {
                Text(coordinator.modelReady ? "Start Dictating" : "Downloading Model…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .disabled(!coordinator.modelReady)
            .keyboardShortcut(.defaultAction)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for permissions…")
                    .foregroundStyle(.secondary)
            }
            .frame(height: 44)
        }
    }
}

private struct FeatureRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
