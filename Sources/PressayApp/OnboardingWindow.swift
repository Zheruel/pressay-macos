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
    @State private var ready = false
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        permissions = coordinator.permissions
        settings = coordinator.settings
        _ready = State(initialValue: coordinator.permissions.allGranted)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: PressayBrand.appIcon).resizable().frame(width: 64, height: 64).padding(.bottom, 26)
            Text(ready ? "Pressay is ready" : "Set up Pressay").font(.system(size: 34, weight: .semibold)).tracking(
                -1.1)
            Text(
                ready
                    ? "Hold your talk key to dictate.\nRelease it to type."
                    : "Allow these permissions to dictate in any app."
            )
            .font(.system(size: 14)).foregroundStyle(PressayPalette.muted).lineSpacing(6).padding(.top, 13)
            if ready {
                PressayGroup {
                    PressaySetting(title: "Hold to talk", detail: "Release to type. Esc to cancel.") {
                        KeyCaptureButton(
                            key: $settings.holdKey, onChange: coordinator.restartHotkey,
                            onCaptureActive: coordinator.keyCaptureActive)
                    }
                }.padding(.top, 27).padding(.bottom, 13)
                PressaySetting(title: "Open at login", detail: "Ready every time you open your Mac.") {
                    Toggle("Open at login", isOn: $settings.launchAtLogin).toggleStyle(
                        PressaySwitchStyle(showsLabel: false)
                    ).frame(width: 32)
                }
                ModelStatusView(coordinator: coordinator).padding(.top, 19).padding(.bottom, 24)
                Button {
                    coordinator.completeOnboarding()
                } label: {
                    Text(coordinator.modelReady ? "Start dictating" : "Preparing model…").frame(maxWidth: .infinity)
                }
                .buttonStyle(PressayButtonStyle(kind: .primary)).disabled(!coordinator.modelReady).keyboardShortcut(
                    .defaultAction)
                if let error = settings.launchAtLoginError {
                    Text(error).font(.system(size: 11)).foregroundStyle(PressayPalette.danger).padding(.top, 12)
                }
            } else {
                PressayGroup {
                    ForEach(PermissionController.Kind.allCases) { kind in
                        HStack(spacing: 13) {
                            Image(systemName: kind.systemImage).font(.system(size: 20)).frame(width: 21)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kind.title).font(.system(size: 13, weight: .medium))
                                Text(detail(kind)).font(.system(size: 11)).foregroundStyle(PressayPalette.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if permissions.isGranted(kind) {
                                StatusLabel(text: "Allowed", color: PressayPalette.success)
                            } else {
                                Button("Allow") { permissions.request(kind) }.contextMenu {
                                    Button("Open System Settings") { permissions.openPrivacySettings(for: kind) }
                                }
                            }
                        }.padding(.horizontal, 18).padding(.vertical, 16)
                            .overlay(alignment: .bottom) { Rectangle().fill(PressayPalette.line).frame(height: 1) }
                    }
                }.padding(.top, 27)
                Button {
                    ready = true
                } label: {
                    Text(permissions.allGranted ? "Continue" : "Allow permissions to continue").frame(
                        maxWidth: .infinity)
                }
                .buttonStyle(PressayButtonStyle(kind: permissions.allGranted ? .primary : .standard))
                .disabled(!permissions.allGranted).padding(.top, 22).keyboardShortcut(.defaultAction)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40).padding(.top, 62).padding(.bottom, 32)
        .frame(width: 540, height: 720, alignment: .topLeading)
        .background(PressayPalette.base).foregroundStyle(PressayPalette.text)
        .toggleStyle(PressaySwitchStyle()).buttonStyle(PressayButtonStyle()).tint(PressayPalette.accent)
        .ignoresSafeArea(.container, edges: .top).onAppear { permissions.startMonitoring() }
    }
    private func detail(_ kind: PermissionController.Kind) -> String {
        switch kind {
        case .microphone: "To hear what you say."
        case .accessibility: "To type at your cursor."
        case .inputMonitoring: "To recognize your talk key."
        }
    }
}
