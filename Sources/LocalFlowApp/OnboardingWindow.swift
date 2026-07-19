import AppKit
import LocalFlowCore
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 650),
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
            onboardingHeader
            Divider().opacity(0.65)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if permissions.allGranted {
                        readyContent
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        permissionContent
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .padding(32)
            }
        }
        .frame(width: 720, height: 650)
        .background {
            LinearGradient(
                colors: [.indigo.opacity(0.08), .clear, .cyan.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .background(.background)
        }
        .animation(.snappy(duration: 0.35), value: permissions.allGranted)
        .onAppear { permissions.startMonitoring() }
    }

    private var onboardingHeader: some View {
        HStack(spacing: 18) {
            Image(nsImage: PressayBrand.appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 68, height: 68)
                .shadow(color: .indigo.opacity(0.24), radius: 16, y: 7)

            VStack(alignment: .leading, spacing: 4) {
                Text(permissions.allGranted ? "Pressay is ready" : "Set up Pressay")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Hold. Speak. Your words appear at the cursor.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                Label("On-device", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.green.opacity(0.1), in: Capsule())
                Text("No account required")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 30)
        .padding(.bottom, 24)
    }

    private var permissionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            DictationFlowStrip(shortcut: settings.holdKey.displayName)

            VStack(alignment: .leading, spacing: 6) {
                Text("Allow three macOS permissions")
                    .font(.title3.bold())
                Text("Pressay watches for each approval automatically. You can leave this window open while using System Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(PermissionController.Kind.allCases) { kind in
                    PermissionSetupRow(
                        kind: kind,
                        granted: permissions.isGranted(kind),
                        request: { permissions.request(kind) },
                        openSettings: { permissions.openPrivacySettings(for: kind) }
                    )
                }
            }

            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Watching for permission changes")
                    .font(.caption.weight(.medium))
                Spacer()
                Label("Audio stays on this Mac", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("All permissions allowed", systemImage: "checkmark.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(.green)

            DictationFlowStrip(shortcut: settings.holdKey.displayName)

            VStack(spacing: 0) {
                setupChoiceRow(
                    icon: "option",
                    title: "Hold-to-talk shortcut",
                    detail: "Hold to record, release to insert"
                ) {
                    KeyCaptureButton(
                        key: $settings.holdKey,
                        reservedKey: { coordinator.settings.polishHoldKey },
                        onChange: { coordinator.restartHotkey() },
                        onCaptureActive: coordinator.keyCaptureActive
                    )
                }
                Divider().padding(.leading, 52)
                setupChoiceRow(
                    icon: "power",
                    title: "Launch at login",
                    detail: "Keep Pressay ready without opening it manually"
                ) {
                    Toggle("", isOn: $settings.launchAtLogin).labelsHidden()
                }
                Divider().padding(.leading, 52)
                setupChoiceRow(
                    icon: "cpu",
                    title: "Local transcription model",
                    detail: coordinator.modelStatus
                ) {
                    if coordinator.modelPreparing {
                        ProgressView().controlSize(.small)
                    } else if coordinator.modelReady {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Retry") { Task { await coordinator.prepareModel() } }
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.separator.opacity(0.35))
            }

            if let error = settings.launchAtLoginError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("You can change these options later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start using Pressay") { coordinator.completeOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!coordinator.modelReady)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func setupChoiceRow<Accessory: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: 28)
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            accessory()
        }
        .padding(14)
    }
}

private struct DictationFlowStrip: View {
    let shortcut: String

    var body: some View {
        HStack(spacing: 0) {
            step(icon: "option", title: "Hold", detail: shortcut)
            connector
            step(icon: "quote.bubble.fill", title: "Speak", detail: "Naturally")
            connector
            step(icon: "character.cursor.ibeam", title: "Release", detail: "Inserted")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.indigo.opacity(0.12))
        }
    }

    private func step(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 30, height: 30)
                .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connector: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 7)
    }
}

private struct PermissionSetupRow: View {
    let kind: PermissionController.Kind
    let granted: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(granted ? Color.green.opacity(0.12) : Color.blue.opacity(0.1))
                Image(systemName: granted ? "checkmark" : kind.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(granted ? .green : .blue)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.body.weight(.semibold))
                Text(kind.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Allowed")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button("Allow") { request() }
                    .buttonStyle(.borderedProminent)
                Button { openSettings() } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .help("Open the matching Privacy & Security page")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    granted
                        ? Color.green.opacity(0.16)
                        : Color(nsColor: .separatorColor).opacity(0.35)
                )
        }
    }
}
