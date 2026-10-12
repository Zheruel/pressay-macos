import AppKit
import PressayCore
import SwiftUI

// MARK: - Menu bar

struct MenuContentView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var history: HistoryStore

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
        history = coordinator.history
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !settings.onboardingComplete {
                setupRequired
            } else {
                header
                if !coordinator.permissions.allGranted || !coordinator.modelReady {
                    attentionBanner.padding(.horizontal, 6).padding(.bottom, 6)
                }
                if coordinator.cleanupConfigured {
                    Toggle(isOn: $settings.claudeCleanup) {
                        Text("AI Cleanup")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    MenuSeparator()
                }
                recent
                MenuSeparator()
                if coordinator.liveSession != nil {
                    MenuRow(title: "Stop Notetaker") { coordinator.stopRecording() }
                    MenuRow(title: "Show Notepad") { coordinator.showNotepadIfRecording() }
                } else {
                    MenuRow(title: "Start Notetaker") { coordinator.startMeeting() }
                }
                MenuRow(title: "Notetaker") { coordinator.showNotes() }
                MenuRow(title: "Settings…", shortcut: "⌘,") { coordinator.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                MenuSeparator()
                MenuRow(title: "Quit Pressay", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(6)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: PressayBrand.appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pressay").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var statusColor: Color {
        coordinator.modelReady && coordinator.permissions.allGranted ? .green : .orange
    }

    private var statusLine: String {
        guard coordinator.modelReady else { return coordinator.modelPreparing ? "Loading model…" : "Model not loaded" }
        let model = settings.asrModel.displayName.components(separatedBy: " ").first ?? settings.asrModel.displayName
        let key = settings.holdKey.displayName
        guard settings.claudeCleanup, coordinator.cleanupConfigured else { return "Hold \(key) to talk · \(model)" }
        let cleanup = switch settings.cleanupProvider {
        case .claude: settings.claudeCleanupModel == .haiku55 ? "Haiku" : "Sonnet"
        case .chatgpt: "ChatGPT"
        }
        return "Hold \(key) to talk · \(model) + \(cleanup)"
    }

    @ViewBuilder
    private var recent: some View {
        if history.records.isEmpty {
            Text("Your dictations will show up here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            Text("Recent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(history.records.prefix(3)) { record in
                CompactHistoryRow(record: record, coordinator: coordinator)
            }
        }
    }

    private var setupRequired: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: PressayBrand.appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Pressay").font(.headline)
                    Text("Three quick permissions, then hold a key and speak.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Continue Setup") { coordinator.showOnboarding() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            MenuSeparator()
            MenuRow(title: "Quit Pressay", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
        }
        .padding(10)
    }

    private var attentionBanner: some View {
        Button {
            if !coordinator.permissions.allGranted {
                coordinator.showOnboarding()
            } else {
                coordinator.showSettings()
            }
        } label: {
            Label(
                coordinator.permissions.allGranted ? "Speech model needs attention" : "A permission needs attention",
                systemImage: "exclamationmark.triangle.fill"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
    }
}

private struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(hovering ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.accentColor : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MenuSeparator: View {
    var body: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 5)
    }
}

private struct CompactHistoryRow: View {
    let record: DictationRecord
    let coordinator: AppCoordinator
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            coordinator.copy(record)
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.referenceText)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Text(copied ? "Copied" : meta)
                    .font(.system(size: 11))
                    .foregroundStyle(hovering ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.accentColor : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to copy")
        .contextMenu {
            Button("Copy") { coordinator.copy(record) }
            Button("Paste Again") { coordinator.retry(record) }
            Divider()
            Button("Delete", role: .destructive) { try? coordinator.history.delete(record) }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let app = AppInfo.name(for: record.targetBundleID) { parts.append(app) }
        parts.append(record.createdAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

/// Cached: NSWorkspace lookups hit Launch Services on every history row body pass.
@MainActor
enum AppInfo {
    private static var names: [String: String?] = [:]
    private static var icons: [String: NSImage?] = [:]

    static func name(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let cached = names[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        names[bundleID] = name
        return name
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleID] = icon
        return icon
    }
}

// MARK: - Settings shell

struct SettingsRootView: View {
    @ObservedObject var coordinator: AppCoordinator
    // PRESSAY_PANE opens a given pane, for design review.
    @State private var selection: SettingsSection? = ProcessInfo.processInfo.environment["PRESSAY_PANE"]
        .flatMap(SettingsSection.init(rawValue:)) ?? .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label {
                    HStack {
                        Text(section.title)
                        if section == .notes, coordinator.liveSession != nil {
                            Spacer()
                            Circle().fill(.red).frame(width: 7, height: 7).accessibilityLabel("Recording")
                        }
                    }
                } icon: {
                    SettingsIconTile(systemImage: section.systemImage, color: section.tint)
                }
                .tag(section)
            }
            .frame(minWidth: 215, idealWidth: 215)
            .navigationSplitViewColumnWidth(215)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch selection ?? .general {
            case .notes:
                NotetakerPage(coordinator: coordinator)
            case let section:
                Group {
                    switch section {
                    case .general: GeneralSettingsView(coordinator: coordinator)
                    case .claude: ClaudeCleanupSettingsView(coordinator: coordinator)
                    case .dictionary: DictionarySettingsView(coordinator: coordinator)
                    case .snippets: SnippetsSettingsView(coordinator: coordinator)
                    default: HistoryView(coordinator: coordinator)
                    }
                }
                // Grouped forms read badly when stretched across a wide window.
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .navigationTitle(section.title)
                .toolbar {
                    // Panes without toolbar items get a shorter, hard-edged toolbar that shifts the sidebar.
                    ToolbarItem(placement: .primaryAction) {
                        Color.clear.frame(width: 1, height: 28).accessibilityHidden(true)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
        }
        .onReceive(coordinator.$settingsPaneRequest.compactMap { $0 }) { pane in
            selection = SettingsSection(rawValue: pane) ?? selection
            coordinator.settingsPaneRequest = nil
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

private struct PaneHero: View {
    let section: SettingsSection
    var title: String?
    let blurb: String

    var body: some View {
        Section {
            VStack(spacing: 0) {
                SettingsIconTile(systemImage: section.systemImage, color: section.tint, size: 56)
                Text(title ?? section.title)
                    .font(.title2.weight(.bold))
                    .padding(.top, 8)
                Text(blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 400)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

private struct SettingsIconTile: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(color.gradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case claude
    case dictionary
    case snippets
    case notes
    case history

    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .claude: "AI Cleanup"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .notes: "Notetaker"
        case .history: "History"
        }
    }
    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .claude: "sparkles"
        case .dictionary: "character.book.closed.fill"
        case .snippets: "text.quote"
        case .notes: "person.2.wave.2.fill"
        case .history: "clock.fill"
        }
    }
    var tint: Color {
        switch self {
        case .general: Color(nsColor: .systemGray)
        case .claude: Color(red: 0.91, green: 0.47, blue: 0.31)
        case .dictionary: .blue
        case .snippets: .teal
        case .notes: .orange
        case .history: .purple
        }
    }
}

/// Neutral status: only the dot carries color, as in System Settings.
private struct StatusLabel: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var permissions: PermissionController
    /// Enumerated once per appearance; the HAL query is too costly for `body`.
    @State private var inputDevices: [AudioDeviceMonitor.Device] = []
    @State private var defaultInputName: String?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
        permissions = coordinator.permissions
    }

    var body: some View {
        Form {
            PaneHero(section: .general, blurb: "Choose your talk key, microphone, and speech model.")

            Section {
                LabeledContent {
                    KeyCaptureButton(
                        key: $settings.holdKey,
                        onChange: { coordinator.restartHotkey() },
                        onCaptureActive: coordinator.keyCaptureActive
                    )
                } label: {
                    Text("Hold to talk")
                    Text(coordinator.commandModeAvailable
                         ? "Hold to dictate. Add Shift for Command Mode. Press Esc to cancel."
                         : "Hold to dictate. Press Esc to cancel.")
                }
            }

            Section {
                Picker("Microphone", selection: $settings.inputDeviceUID) {
                    Text(defaultInputName.map { "System Default (\($0))" } ?? "System Default").tag(String?.none)
                    if !inputDevices.isEmpty { Divider() }
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .onChange(of: settings.inputDeviceUID) { _, _ in coordinator.applyMicWarmth() }

                Toggle(isOn: $settings.keepMicWarm) {
                    Text("Keep microphone ready")
                    Text("Keeps the mic on for \(Int(DictationProcessingPolicy.micWarmWindow)) seconds after you dictate, so the next one starts instantly. Never with Bluetooth headphones: an open mic switches them to call audio.")
                }
                .onChange(of: settings.keepMicWarm) { _, _ in coordinator.applyMicWarmth() }
            }

            Section("Transcription") {
                Picker(selection: $settings.asrModel) {
                    ForEach(ASRModel.allCases) { Text($0.displayName).tag($0) }
                } label: {
                    Text("Speech model")
                    Text(settings.asrModel.caption)
                }
                .onChange(of: settings.asrModel) { _, _ in coordinator.applyASRModel() }

                if settings.asrModel.offersLanguageChoice {
                    Picker("Language", selection: $settings.language) {
                        ForEach(settings.asrModel.supportedLanguages) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: settings.language) { _, _ in coordinator.applyTranscriptionLanguage() }
                } else {
                    LabeledContent("Language", value: settings.language.rawValue)
                }

                LabeledContent("Status") { modelStatus }

                Toggle(isOn: $settings.structuredDictation) {
                    Text("On-device formatting")
                    Text("Adds punctuation and paragraphs when AI Cleanup is off.")
                }
            }

            Section("Permissions") {
                if permissions.allGranted {
                    LabeledContent("Microphone, Accessibility, and Input Monitoring") {
                        StatusLabel(text: "Allowed", color: .green)
                    }
                } else {
                    ForEach(PermissionController.Kind.allCases) { kind in
                        PermissionSettingsRow(
                            kind: kind,
                            granted: permissions.isGranted(kind),
                            allow: { permissions.request(kind) },
                            openSettings: { permissions.openPrivacySettings(for: kind) }
                        )
                    }
                }
            }

            Section {
                Toggle("Open at login", isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    LabeledContent {
                        Button("Login Items…") { settings.openLoginItemsSettings() }
                    } label: {
                        Text("Couldn’t update login items")
                        Text(error)
                    }
                }
            }

            if let error = coordinator.lastError {
                Section("Last Issue") {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .onAppear {
            permissions.startMonitoring()
            settings.refreshLaunchAtLogin()
            inputDevices = AudioDeviceMonitor.inputDevices()
            defaultInputName = AudioDeviceMonitor.defaultInputName
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        if coordinator.modelPreparing {
            HStack(spacing: 8) {
                if let progress = coordinator.modelDownloadProgress {
                    ProgressView(value: progress).frame(width: 110)
                    Text("Downloading \(Int((progress * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
            }
        } else if coordinator.modelReady {
            StatusLabel(text: "Ready", color: .green)
        } else {
            HStack(spacing: 8) {
                StatusLabel(text: "Not loaded", color: .orange)
                Button("Retry") { Task { await coordinator.prepareModel() } }
            }
            .help(coordinator.modelStatus)
        }
    }
}

private struct PermissionSettingsRow: View {
    let kind: PermissionController.Kind
    let granted: Bool
    let allow: () -> Void
    let openSettings: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                StatusLabel(text: "Allowed", color: .green)
            } else {
                HStack(spacing: 6) {
                    Button("Allow") { allow() }
                    Button("Open Settings…") { openSettings() }
                }
            }
        } label: {
            Label {
                Text(kind.title)
                Text(kind.detail)
            } icon: {
                Image(systemName: kind.systemImage)
            }
        }
    }
}

// MARK: - Claude Cleanup

/// Saving a key is the opt-in; the switch pauses it without discarding the key.
private struct ClaudeCleanupSettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings
    @State private var keyDraft = ""
    @State private var keyStatus: String?
    @State private var keyStatusIsError = false
    @State private var testing = false
    @State private var confirmingRemove = false
    @State private var confirmingSignOut = false
    @State private var showingPlanWelcome = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
    }

    private var keyConfigured: Bool { coordinator.claudeAPIKey != nil }
    private var account: ChatGPTAccount { coordinator.chatGPT }

    var body: some View {
        Form {
            PaneHero(section: .claude, blurb: "AI fixes misheard names, filler words, and punctuation before your text is typed. Audio never leaves your Mac.")

            Section {
                if coordinator.cleanupConfigured {
                    Toggle(isOn: $settings.claudeCleanup) {
                        Text("Clean up with AI")
                        Text("Skipped in Terminal and for very short dictations.")
                    }
                }
                Picker(selection: $settings.cleanupProvider) {
                    ForEach(CleanupProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                } label: {
                    Text("Provider")
                    Text(settings.cleanupProvider.subtitle)
                }
                switch settings.cleanupProvider {
                case .claude: claudeModelPicker
                case .chatgpt: if account.isSignedIn { chatGPTModelPicker }
                }
            }

            switch settings.cleanupProvider {
            case .claude: keySection
            case .chatgpt: chatGPTAccountSection
            }

            Section {
                Toggle(isOn: $settings.matchAppStyle) {
                    Text("Match each app’s style")
                    Text("Casual in chats, complete sentences in email, tidy paragraphs in documents.")
                }
                LabeledContent {
                    Text(coordinator.commandModeAvailable ? "Shift + \(settings.holdKey.displayName)" : "Needs a talk key other than Shift")
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Command Mode")
                    Text("Hold Shift with your talk key and say what to do: “make this shorter”, “translate to German”, or “write a reply saying I’m running late”. Select text first to change it.")
                }
            } header: {
                Text("Writing")
            }
            .disabled(!coordinator.cleanupConfigured)
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .confirmationDialog("Sign out of ChatGPT?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
        } message: {
            Text("AI Cleanup turns off until you sign in again.")
        }
        .alert("You’re using your ChatGPT plan", isPresented: $showingPlanWelcome) {
            Button("Got it") { settings.chatGPTWelcomeShown = true }
        } message: {
            Text("Cleanup counts toward your ChatGPT plan’s usage limits, which are shared with other apps. Pressay never sees your password.")
        }
        .confirmationDialog("Remove your API key?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) {
                ClaudeAPIKeyStore.clear()
                setStatus(nil, error: false)
                coordinator.reloadClaudeKey()
            }
        } message: {
            Text("AI Cleanup turns off until you add a key.")
        }
    }

    @ViewBuilder
    private var chatGPTAccountSection: some View {
        Section {
            if let credentials = account.credentials, account.isSignedIn {
                LabeledContent {
                    Button("Sign Out…") { confirmingSignOut = true }
                } label: {
                    Text(credentials.email ?? "ChatGPT account")
                    Text("Using ChatGPT plan")
                }
            } else if account.signingIn {
                LabeledContent {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { account.cancelSignIn() }
                    }
                } label: {
                    Text("Waiting for your browser…")
                    Text("Finish signing in to ChatGPT, then come back here.")
                }
            } else {
                LabeledContent {
                    Button("Continue with ChatGPT") { signIn() }
                } label: {
                    Text("Account")
                    Text("Sign in to use your Plus or Pro plan. No API key needed.")
                }
            }
            if let error = account.lastError {
                LabeledContent("Status") {
                    StatusLabel(text: error, color: .red)
                }
            }
        } header: {
            Text("ChatGPT")
        } footer: {
            if account.isSignedIn {
                Link("Manage usage", destination: ChatGPTPlan.usageSettings)
            }
        }
    }

    private var chatGPTModelPicker: some View {
            Picker(selection: $settings.chatGPTModel) {
                ForEach(chatGPTModelChoices, id: \.slug) { choice in
                    let option = ChatGPTModelOption(slug: choice.slug, name: ChatGPTCleanupModel.displayName(for: choice.slug))
                    Text(option.title).tag(choice.slug)
                }
            } label: {
                let option = ChatGPTModelOption(slug: settings.chatGPTModel, name: ChatGPTCleanupModel.displayName(for: settings.chatGPTModel))
                Text("Model")
                Text(option.subtitle)
            }
    }

    /// Always includes the current choice so the picker is never blank while loading.
    private var chatGPTModelChoices: [(slug: String, name: String)] {
        var choices = account.models
        if !choices.contains(where: { $0.slug == settings.chatGPTModel }) {
            choices.insert((settings.chatGPTModel, ChatGPTCleanupModel.displayName(for: settings.chatGPTModel)), at: 0)
        }
        return choices.sorted { ChatGPTModelOption.rank($0.slug) < ChatGPTModelOption.rank($1.slug) }
    }

    private func signIn() {
        Task {
            await account.signIn()
            guard account.isSignedIn else { return }
            settings.claudeCleanup = true
            if !account.models.isEmpty, !account.models.contains(where: { $0.slug == settings.chatGPTModel }) {
                settings.chatGPTModel = account.models[0].slug
            }
            if !settings.chatGPTWelcomeShown { showingPlanWelcome = true }
        }
    }

    private var claudeModelPicker: some View {
            Picker(selection: $settings.claudeCleanupModel) {
                ForEach(ClaudeCleanupModel.allCases) { model in
                    Text(model.optionTitle).tag(model)
                }
            } label: {
                Text("Model")
                Text(keyConfigured ? settings.claudeCleanupModel.optionSubtitle : "Add an API key to choose a model.")
            }
            .disabled(!keyConfigured)
    }

    private var keySection: some View {
        Section {
            if let key = coordinator.claudeAPIKey {
                LabeledContent {
                    HStack(spacing: 6) {
                        Button("Verify") { testConnection() }
                            .disabled(testing)
                        Button("Remove…", role: .destructive) { confirmingRemove = true }
                    }
                } label: {
                    Text("API Key")
                    Text("••••" + String(key.suffix(4)))
                        .monospaced()
                }
            } else {
                LabeledContent {
                    SecureField("API Key", text: $keyDraft, prompt: Text("sk-ant-…"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 240)
                        .onSubmit(saveKey)
                } label: {
                    Text("API Key")
                    Text("Paste your key and press Return.")
                }
            }
            if testing {
                LabeledContent("Status") {
                    ProgressView().controlSize(.small)
                }
            } else if let keyStatus {
                LabeledContent("Status") {
                    StatusLabel(text: keyStatus, color: keyStatusIsError ? .red : .green)
                }
            }
        } header: {
            Text("Anthropic")
        } footer: {
            if !keyConfigured {
                Link("Get an API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            }
        }
    }

    private func setStatus(_ text: String?, error: Bool) {
        keyStatus = text
        keyStatusIsError = error
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let saved = ClaudeAPIKeyStore.save(key)
        keyDraft = ""
        coordinator.reloadClaudeKey()
        if saved {
            settings.claudeCleanup = true
            testConnection()
        } else {
            setStatus("Couldn’t save to Keychain", error: true)
        }
    }

    private func testConnection() {
        guard let key = coordinator.claudeAPIKey else { return }
        testing = true
        keyStatus = nil
        Task {
            do {
                let status = try await ClaudeCleaner().warmUp(apiKey: key)
                switch status {
                case 200: setStatus("Verified", error: false)
                case 401: setStatus("Key rejected", error: true)
                default: setStatus("Error \(status)", error: true)
                }
            } catch {
                setStatus("Can’t reach Anthropic", error: true)
            }
            testing = false
        }
    }
}

private extension ClaudeCleanupModel {
    var optionTitle: String {
        switch self {
        case .haiku55: "Haiku 5.5 (Recommended)"
        case .sonnet55: "Sonnet 5.5"
        }
    }

    var optionSubtitle: String {
        switch self {
        case .haiku55: "Fast and accurate. Under $1 a month."
        case .sonnet55: "Slightly better with rare names. About $5 a month."
        }
    }
}

/// Picker copy; the catalog can list models Pressay hasn't tested.
private struct ChatGPTModelOption {
    let slug: String
    let name: String

    static let recommended = ChatGPTCleanupModel.defaultSlug

    static func rank(_ slug: String) -> Int {
        switch slug {
        case recommended: 0
        case "gpt-6-luna": 1
        default: 2
        }
    }

    var title: String { slug == Self.recommended ? "\(name) (Recommended)" : name }

    var subtitle: String {
        switch slug {
        case Self.recommended: "Best results of every model tested."
        case "gpt-6-luna": "A little quicker, but misses more fixes."
        default: "Not tested with Pressay yet."
        }
    }
}

// MARK: - Notetaker

struct NotetakerSettingsSheet: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NotesSettingsView(coordinator: coordinator)
            .frame(minWidth: 540, idealWidth: 560, minHeight: 420, idealHeight: 640)
            .presentationSizing(.form)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
    }
}

private struct NotesSettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var chatGPT: ChatGPTAccount

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
        chatGPT = coordinator.chatGPT
    }

    var body: some View {
        Form {
            PaneHero(section: .notes, title: "Notetaker Settings", blurb: "Takes notes in your meetings. Pressay transcribes on this Mac as people talk, then writes up clear notes when the call ends.")

            Section {
                Toggle(isOn: Binding(get: { settings.notesUseAI && !options.isEmpty }, set: { settings.notesUseAI = $0 })) {
                    Text("Write up notes with AI")
                    Text("A title, summary, decisions and action items, built from the transcript and your own notes.")
                }
                .disabled(options.isEmpty)
                if !options.isEmpty {
                    Picker("Model", selection: modelBinding) {
                        ForEach(options) { model in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.isRecommended ? "\(model.title) (Recommended)" : model.title)
                                Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(model.id)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(!settings.notesUseAI)
                }
            } header: {
                Text("AI notes")
            } footer: {
                if options.isEmpty {
                    HStack {
                        Text("Add a Claude API key or sign in with ChatGPT to have notes written up. Until then you keep the full transcript.")
                        Spacer()
                        Button("Set Up…") {
                            coordinator.notetakerSettingsShown = false
                            coordinator.settingsPaneRequest = "claude"
                        }
                    }
                } else {
                    Text(providerCaption + " Models appear here for the providers you’ve set up in AI Cleanup.")
                }
            }

            Section {
                Toggle(isOn: $settings.detectCalls) {
                    Text("Offer to take notes when a call starts")
                    Text("Zoom, Teams, Meet, FaceTime, Slack and more. Pressay checks which apps use the microphone, never what they hear.")
                }
                Toggle(isOn: $settings.stopWhenCallEnds) {
                    Text("Stop when the call ends")
                    Text("When the call app stops using the microphone.")
                }
                .disabled(!settings.detectCalls)
                Toggle(isOn: $settings.meetingSystemAudio) {
                    Text("Transcribe the other people")
                    Text("Records your Mac’s sound alongside your microphone, so everyone on the call is in the transcript.")
                }
                Toggle(isOn: $settings.separateVoices) {
                    Text("Tell speakers apart")
                    Text("Labels each voice on the call, on this Mac. The AI adds names when people introduce themselves or are addressed by name.")
                }
                .disabled(!settings.meetingSystemAudio)
            } header: {
                Text("Calls")
            } footer: {
                Text("The first meeting asks for permission to record system audio. Audio is never saved; only the transcript is.")
            }

            Section("While recording") {
                Picker("Stop after", selection: $settings.maxMeetingHours) {
                    ForEach([1, 2, 3, 4, 6, 8], id: \.self) { hours in
                        Text(hours == 1 ? "1 hour" : "\(hours) hours").tag(hours)
                    }
                }
                Toggle(isOn: $settings.openNotepad) {
                    Text("Show the notepad")
                    Text("A small floating window with the timer and your notes, above other apps while you’re in the call.")
                }
                Toggle("Show the live transcript", isOn: $settings.showLiveTranscript)
                    .disabled(!settings.openNotepad)
            }

        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    private var options: [NotesModel] {
        _ = chatGPT.isSignedIn
        return coordinator.notesModelOptions
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { coordinator.notesModel?.id ?? "" },
            set: { settings.notesModel = $0 }
        )
    }

    private var providerCaption: String {
        switch coordinator.notesModel {
        case .claude?: "Uses your Claude API key. Transcripts are sent to Anthropic only to write the notes."
        case .chatgpt?: "Uses your ChatGPT plan at no extra cost. Transcripts are sent to OpenAI only to write the notes."
        case nil: ""
        }
    }

}

// MARK: - Dictionary

private struct DictionaryEntry: Identifiable {
    let preferred: String
    let aliases: [String]
    let line: String
    var id: String { line }
}

private struct LearnedWord: Identifiable {
    let preferred: String
    let records: [LearnedVocabularyStore.Record]
    var id: String { preferred.lowercased() }
}

private struct DictionarySettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var learned: LearnedVocabularyStore
    @ObservedObject private var suggestions: VocabularySuggestionStore
    @State private var confirmingRestore = false
    @State private var addingEntry = false
    @State private var search = ""

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
        learned = coordinator.settings.learnedVocabulary
        suggestions = coordinator.settings.vocabularySuggestions
    }

    var body: some View {
        Form {
            PaneHero(section: .dictionary, blurb: "Names, products, and jargon Pressay should always spell your way.")

            if filteredSections.isEmpty && filteredLearned.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(search.isEmpty ? "No Words" : "No Results", systemImage: search.isEmpty ? "character.book.closed" : "magnifyingglass")
                    } description: {
                        Text(search.isEmpty ? "Add names and terms you say often." : "No words match “\(search)”.")
                    }
                }
            }

            if search.isEmpty && !suggestions.suggestions.isEmpty {
                Section {
                    ForEach(suggestions.suggestions.prefix(8)) { suggestion in
                        SuggestionRow(suggestion: suggestion) {
                            settings.accept(suggestion)
                        } onDismiss: {
                            suggestions.dismiss(suggestion)
                        }
                    }
                } header: {
                    Text("Suggestions")
                } footer: {
                    Text("Words Pressay noticed in your dictations and corrections. Dismissed suggestions won’t come back.")
                }
            }

            ForEach(Array(filteredSections.enumerated()), id: \.offset) { _, section in
                Section(Self.titleCase(section.title ?? "Your Words")) {
                    ForEach(section.entries) { entry in
                        WordRow(
                            word: entry.preferred,
                            detail: entry.aliases.isEmpty ? nil : "Sounds like " + Self.quotedList(entry.aliases)
                        ) {
                            deleteEntry(line: entry.line)
                        }
                    }
                }
            }

            if !filteredLearned.isEmpty {
                Section {
                    ForEach(filteredLearned) { word in
                        WordRow(word: word.preferred, detail: "Heard as " + Self.quotedList(word.records.map(\.heard))) {
                            word.records.forEach { learned.remove($0) }
                        }
                    }
                } header: {
                    Text("Learned Automatically")
                } footer: {
                    Text("Added when you correct a word after dictating, or when Pressay hears a close match to one of your words. Removed spellings aren’t learned again.")
                }
            }

            Section {
                Toggle(isOn: $settings.learnFromEdits) {
                    Text("Learn from corrections")
                    Text("After dictating, Pressay briefly watches for words you retype and adds them. Nothing you type is stored.")
                }
                .toggleStyle(.switch)
            }

            Section {
                LabeledContent("\(settings.vocabularyEntries.count) Words") {
                    Button("Restore Defaults…") { confirmingRestore = true }
                }
            }
        }
        .formStyle(.grouped)
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addingEntry = true } label: { Label("Add Word", systemImage: "plus") }
                    .help("Add a word")
            }
        }
        .sheet(isPresented: $addingEntry) {
            AddDictionaryEntrySheet { preferred, aliases in
                addEntry(preferred: preferred, aliases: aliases)
            }
        }
        .confirmationDialog(
            "Replace your dictionary with the defaults?",
            isPresented: $confirmingRestore
        ) {
            Button("Restore Defaults", role: .destructive) { settings.restoreCuratedVocabulary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Words you added yourself will be removed.")
        }
    }

    /// “a”, “b”, and “c”
    static func quotedList(_ items: [String]) -> String {
        let quoted = items.map { "“\($0)”" }
        return quoted.formatted(.list(type: .and))
    }

    /// Section titles come from free-form `#` comment lines in the source.
    static func titleCase(_ title: String) -> String {
        let minor: Set<String> = ["and", "or", "the", "a", "an", "of", "for", "to", "in", "on"]
        return title.split(separator: " ").enumerated().map { index, word in
            let w = String(word)
            if index > 0, minor.contains(w.lowercased()) { return w.lowercased() }
            guard let first = w.first, first.isLowercase else { return w }
            return first.uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    private var filteredLearned: [LearnedWord] {
        let records = search.isEmpty ? learned.records : learned.records.filter {
            $0.preferred.localizedCaseInsensitiveContains(search) || $0.heard.localizedCaseInsensitiveContains(search)
        }
        var order: [String] = []
        var groups: [String: [LearnedVocabularyStore.Record]] = [:]
        for record in records {
            let key = record.preferred.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(record)
        }
        return order.compactMap { key in
            groups[key].map { LearnedWord(preferred: $0[0].preferred, records: $0) }
        }
    }

    private var filteredSections: [(title: String?, entries: [DictionaryEntry])] {
        let sections = parsedSections
        guard !search.isEmpty else { return sections.filter { !$0.entries.isEmpty } }
        return sections.compactMap { section in
            let entries = section.entries.filter {
                $0.preferred.localizedCaseInsensitiveContains(search)
                    || $0.aliases.contains { $0.localizedCaseInsensitiveContains(search) }
            }
            return entries.isEmpty ? nil : (section.title, entries)
        }
    }

    private var parsedSections: [(title: String?, entries: [DictionaryEntry])] {
        var sections: [(String?, [DictionaryEntry])] = []
        var currentTitle: String?
        var current: [DictionaryEntry] = []
        func flush() {
            if currentTitle != nil || !current.isEmpty {
                sections.append((currentTitle, current))
            }
        }
        for rawLine in settings.vocabularySource.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                flush()
                currentTitle = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                current = []
            } else if let entry = VocabularyParser.parse(line).first {
                current.append(DictionaryEntry(preferred: entry.preferred, aliases: entry.aliases, line: line))
            }
        }
        flush()
        return sections
    }

    private func deleteEntry(line: String) {
        let lines = settings.vocabularySource
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespaces) != line }
        settings.vocabularySource = lines.joined(separator: "\n")
    }

    private func addEntry(preferred: String, aliases: [String]) {
        settings.addVocabularyWord(preferred, aliases: aliases)
    }
}

private struct SuggestionRow: View {
    let suggestion: VocabularySuggestion
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.preferred)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .help(suggestion.example)
            Spacer()
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            Button("Add", action: onAdd)
        }
        .contextMenu {
            Button("Add to Dictionary", action: onAdd)
            Button("Dismiss", action: onDismiss)
        }
    }

    private var detail: String {
        let times = suggestion.count == 1 ? "once" : "\(suggestion.count) times"
        switch suggestion.origin {
        case .edit: return "You corrected “\(suggestion.heard ?? "")” to this"
        case .cleanup: return "AI Cleanup fixed “\(suggestion.heard ?? "")” to this \(times)"
        case .recurring: return "Said in \(suggestion.count) dictations"
        }
    }
}

private struct WordRow: View {
    let word: String
    let detail: String?
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(word)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Remove")
            .accessibilityLabel("Remove \(word)")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove", role: .destructive, action: onDelete)
        }
    }
}

private struct AddDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preferred = ""
    @State private var aliases = ""
    let onSave: (String, [String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Word", text: $preferred, prompt: Text("Required"))
                    TextField("Sounds like", text: $aliases, prompt: Text("Optional"))
                } header: {
                    Text("Add Word")
                } footer: {
                    Text("Type it the way it should be spelled. Add what it sounds like if Pressay keeps mishearing it; separate several with commas.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let aliasList = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    onSave(preferred.trimmingCharacters(in: .whitespaces), aliasList)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preferred.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
    }
}

// MARK: - Snippets

private struct SnippetsSettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings
    @State private var editing: Snippet?
    @State private var adding = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
    }

    private func triggers(except id: UUID?) -> Set<String> {
        Set(settings.snippets.filter { $0.id != id }.map { SnippetExpander.normalized($0.trigger) })
    }

    var body: some View {
        Form {
            PaneHero(section: .snippets, blurb: "Say a short phrase and Pressay types the full text: a link, an address, a sign-off.")

            if settings.snippets.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Snippets", systemImage: "text.quote")
                    } description: {
                        Text("Try “my calendar link” for your booking URL, or “my address” for your shipping address.")
                    } actions: {
                        Button("Add Snippet") { adding = true }
                    }
                }
            } else {
                Section {
                    ForEach(settings.snippets) { snippet in
                        SnippetRow(snippet: snippet) { editing = snippet } onDelete: {
                            settings.snippets.removeAll { $0.id == snippet.id }
                        }
                    }
                } footer: {
                    Text("Works anywhere in a dictation, in any app. Snippet text is inserted exactly as written.")
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add Snippet", systemImage: "plus") }
                    .help("Add a snippet")
            }
        }
        .sheet(isPresented: $adding) {
            SnippetSheet(snippet: nil, taken: triggers(except: nil)) { settings.snippets.append($0) }
        }
        .sheet(item: $editing) { snippet in
            SnippetSheet(snippet: snippet, taken: triggers(except: snippet.id)) { updated in
                if let index = settings.snippets.firstIndex(where: { $0.id == updated.id }) {
                    settings.snippets[index] = updated
                }
            }
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(snippet.trigger)”")
                Text(snippet.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            HStack(spacing: 6) {
                Button(action: onEdit) { Image(systemName: "pencil.circle.fill") }
                    .help("Edit")
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                }
                .help("Remove")
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Remove", role: .destructive, action: onDelete)
        }
    }
}

private struct SnippetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snippet: Snippet?
    let taken: Set<String>
    let onSave: (Snippet) -> Void
    @State private var trigger = ""
    @State private var text = ""

    private var duplicate: Bool { taken.contains(SnippetExpander.normalized(trigger)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("When you say", text: $trigger, prompt: Text("my calendar link"))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pressay types")
                        TextEditor(text: $text)
                            .font(.body)
                            .frame(height: 110)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    }
                } header: {
                    Text(snippet == nil ? "Add Snippet" : "Edit Snippet")
                } footer: {
                    Text(duplicate ? "You already have a snippet for this phrase." : "Use a phrase you wouldn’t say otherwise, like “my calendar link” rather than “calendar”.")
                        .foregroundStyle(duplicate ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(snippet == nil ? "Add" : "Save") {
                    onSave(Snippet(id: snippet?.id ?? UUID(), trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines), text: text))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(SnippetExpander.normalized(trigger).isEmpty || text.isEmpty || duplicate)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .onAppear {
            trigger = snippet?.trigger ?? ""
            text = snippet?.text ?? ""
        }
    }
}

// MARK: - History

private struct HistoryView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var history: HistoryStore
    @State private var showingDeleteAll = false
    @State private var searchText = ""

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        history = coordinator.history
    }

    var body: some View {
        Form {
            if searchText.isEmpty {
                PaneHero(section: .history, blurb: "Everything you’ve dictated, kept only on this Mac for 30 days.")
            }
            if groups.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(searchText.isEmpty ? "No Dictations" : "No Results", systemImage: searchText.isEmpty ? "clock" : "magnifyingglass")
                    } description: {
                        Text(searchText.isEmpty ? "Hold your talk key and speak. Dictations appear here." : "Nothing matches “\(searchText)”.")
                    }
                }
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.records) { record in
                        HistoryRow(record: record, coordinator: coordinator)
                    }
                }
            }
            if !groups.isEmpty {
                Section {} footer: {
                    Text("Audio recordings are deleted after 7 days.")
                }
            }
        }
        .formStyle(.grouped)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Delete All History…", role: .destructive) { showingDeleteAll = true }
                        .disabled(history.records.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
            }
        }
        .confirmationDialog("Delete all history and audio?", isPresented: $showingDeleteAll) {
            Button("Delete All", role: .destructive) { try? history.deleteAll() }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private var filteredRecords: [DictationRecord] {
        guard !searchText.isEmpty else { return history.records }
        return history.records.filter {
            $0.referenceText.localizedCaseInsensitiveContains(searchText)
                || (AppInfo.name(for: $0.targetBundleID)?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var groups: [(title: String, records: [DictationRecord])] {
        let calendar = Calendar.current
        var result: [(String, [DictationRecord])] = []
        for record in filteredRecords {
            let title: String
            if calendar.isDateInToday(record.createdAt) {
                title = "Today"
            } else if calendar.isDateInYesterday(record.createdAt) {
                title = "Yesterday"
            } else if let days = calendar.dateComponents([.day], from: record.createdAt, to: .now).day, days < 7 {
                title = record.createdAt.formatted(.dateTime.weekday(.wide))
            } else {
                title = record.createdAt.formatted(.dateTime.month(.wide).day())
            }
            if result.last?.0 == title {
                result[result.count - 1].1.append(record)
            } else {
                result.append((title, [record]))
            }
        }
        return result
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    let coordinator: AppCoordinator
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            appIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(record.referenceText)
                    .lineLimit(3)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .opacity(hovering || copied ? 1 : 0)
            .help("Copy")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy", action: copy)
            Button("Paste Again") { coordinator.retry(record) }
            Divider()
            Button("Delete", role: .destructive) { try? coordinator.history.delete(record) }
        }
    }

    private func copy() {
        coordinator.copy(record)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = AppInfo.icon(for: record.targetBundleID) {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: "text.cursor")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let app = AppInfo.name(for: record.targetBundleID) { parts.append(app) }
        parts.append(record.createdAt.formatted(date: .omitted, time: .shortened))
        parts.append("\(Int(record.duration.rounded())) sec")
        return parts.joined(separator: " · ")
    }
}
