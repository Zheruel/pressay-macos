import AppKit
import PressayCore
import SwiftUI

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
        VStack(alignment: .leading, spacing: 15) {
            if !settings.onboardingComplete {
                setupRequired
            } else {
                if !coordinator.permissions.allGranted || !coordinator.modelReady {
                    attentionBanner
                }
                if !settings.hasUsedDictation {
                    firstUseHint
                }
                if history.records.isEmpty {
                    ContentUnavailableView(
                        "No recent dictations",
                        systemImage: "clock",
                        description: Text("Your prompts will appear here after you speak.")
                    )
                    .frame(height: 116)
                } else {
                    HStack {
                        Text("Recent").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("Stored locally").font(.caption2).foregroundStyle(.tertiary)
                    }
                    ForEach(history.records.prefix(4)) { record in
                        CompactHistoryRow(record: record, coordinator: coordinator)
                    }
                }
                Divider()
                HStack {
                    Button { coordinator.showSettings() } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
                .pointerStyle(.link)
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private var setupRequired: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: PressayBrand.appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .shadow(color: .indigo.opacity(0.18), radius: 9, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Pressay").font(.title3.bold())
                    Text("Three quick permissions, then hold Option and speak.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Label("Private by design — audio and text stay on this Mac", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Continue setup") { coordinator.showOnboarding() }
                .pointerStyle(.link)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .pointerStyle(.link)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
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
                coordinator.permissions.allGranted ? "Local model needs attention" : "A permission needs attention",
                systemImage: "exclamationmark.triangle.fill"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
    }

    private var firstUseHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "option")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 32, height: 32)
                .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text("Hold \(settings.holdKey.displayName) and speak")
                    .font(.callout.weight(.semibold))
                Text("Release to insert at the cursor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(11)
        .background(.indigo.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.indigo.opacity(0.1))
        }
    }
}

private struct CompactHistoryRow: View {
    let record: DictationRecord
    let coordinator: AppCoordinator

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.referenceText)
                    .lineLimit(2)
                    .font(.callout)
                Text("\(record.totalLatency, format: .number.precision(.fractionLength(2)))s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { coordinator.copy(record) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
            Button { coordinator.retry(record) } label: { Image(systemName: "arrow.turn.down.left") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
        .contextMenu {
            Button(record.isPinned ? "Unpin" : "Pin") { try? coordinator.history.togglePin(record) }
                .pointerStyle(.link)
            Button("Delete", role: .destructive) { try? coordinator.history.delete(record) }
                .pointerStyle(.link)
        }
    }
}

/// Hand-built two-pane shell instead of NavigationSplitView: the sidebar is
/// the whole navigation, so it must not collapse, float as a glass panel, or
/// carry toolbar chrome — a flat tinted column with a hairline against the
/// detail pane reads as one construction.
struct SettingsRootView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var selection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().ignoresSafeArea()
            detail
        }
        .frame(minWidth: 780, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: PressayBrand.appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                Text("Pressay").font(.title3.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    SidebarNavItem(section: section, isSelected: selection == section) {
                        selection = section
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)
        }
        // Clears the traffic lights in the transparent title bar.
        .padding(.top, 56)
        .frame(width: 206)
        .frame(maxHeight: .infinity)
        // A whisper darker than the window background — enough to read as a
        // rail, not enough to read as a different surface.
        .background(Color.black.opacity(0.09))
        .ignoresSafeArea()
    }

    private var detail: some View {
        Group {
            switch selection {
            case .general:
                GeneralSettingsView(coordinator: coordinator)
            case .dictionary:
                DictionarySettingsView(coordinator: coordinator)
            case .history:
                HistoryView(coordinator: coordinator)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Scroll views span the window's full height so their indicators run
        // edge to edge instead of floating below the invisible title bar.
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct SidebarNavItem: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(section.title)
                    .font(.callout.weight(isSelected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    isSelected
                        ? Color.primary.opacity(0.09)
                        : hovering ? Color.primary.opacity(0.05) : .clear
                )
        )
        .onHover { hovering = $0 }
        .pointerStyle(.link)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case dictionary
    case history

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .dictionary: "text.book.closed"
        case .history: "clock.arrow.circlepath"
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var permissions: PermissionController
    @State private var apiKeyDraft = ""
    @State private var keyStatus: String?
    @State private var testingConnection = false
    /// Cached presence check: SecItemCopyMatching is a securityd IPC, too
    /// expensive to run on every body pass (each SecureField keystroke).
    @State private var keyConfigured = false
    /// Enumerated once per appearance; the HAL query is too costly for `body`.
    @State private var inputDevices: [AudioDeviceMonitor.Device] = []
    @State private var defaultInputName: String?

    /// "Follow system" is meaningless without naming what it resolves to —
    /// especially when that is a Bluetooth headset with its own trade-offs.
    private var microphoneCaption: String {
        guard settings.inputDeviceUID == nil else { return "Pressay always records from this input" }
        guard let defaultInputName else { return "Which input Pressay records from" }
        return "Following the system default — currently \(defaultInputName)"
    }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
        permissions = coordinator.permissions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsPageHeader(
                    title: "General",
                    subtitle: "Shortcut, startup, model, and macOS access"
                )

                SettingsCard(title: "Dictation", systemImage: "option") {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hold-to-talk shortcut").font(.body.weight(.medium))
                            Text("Hold to record, release to insert")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        KeyCaptureButton(
                            key: $settings.holdKey,
                            onChange: { coordinator.restartHotkey() },
                            onCaptureActive: coordinator.keyCaptureActive
                        )
                    }

                    Divider()

                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Microphone").font(.body.weight(.medium))
                            Text(microphoneCaption)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.inputDeviceUID) {
                            Text("Follow system").tag(String?.none)
                            ForEach(inputDevices) { device in
                                Text(device.name).tag(String?.some(device.uid))
                            }
                        }
                        .labelsHidden()
                        // Trailing: a menu Picker sizes its button to the widest
                        // menu item, so equal frames alone leave ragged right edges.
                        .frame(width: 230, alignment: .trailing)
                        .onChange(of: settings.inputDeviceUID) { _, _ in coordinator.applyMicWarmth() }
                    }

                    Divider()

                    Toggle(isOn: $settings.keepMicWarm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep the microphone ready").font(.body.weight(.medium))
                            Text("Holds the mic open for \(Int(DictationProcessingPolicy.micWarmWindow))s after a dictation so the next one can't clip your first word — the recording indicator stays lit meanwhile")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: settings.keepMicWarm) { _, _ in coordinator.applyMicWarmth() }

                    Divider()

                    Toggle(isOn: $settings.structuredDictation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Structured dictation").font(.body.weight(.medium))
                            Text("Add punctuation, paragraphs, and lists to longer dictations — on-device")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                }

                SettingsCard(title: "Startup", systemImage: "power") {
                    Toggle(isOn: $settings.launchAtLogin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch Pressay at login").font(.body.weight(.medium))
                            Text("Keep dictation ready after you sign in")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if let error = settings.launchAtLoginError {
                        HStack(spacing: 8) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Open Login Items") { settings.openLoginItemsSettings() }
                                .pointerStyle(.link)
                        }
                    }
                }

                SettingsCard(title: "Local transcription", systemImage: "cpu") {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Model").font(.body.weight(.medium))
                            Text(settings.asrModel.caption)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.asrModel) {
                            ForEach(ASRModel.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        // Trailing: a menu Picker sizes its button to the widest
                        // menu item, so equal frames alone leave ragged right edges.
                        .frame(width: 230, alignment: .trailing)
                        .onChange(of: settings.asrModel) { _, _ in coordinator.applyASRModel() }
                    }

                    // Status for the model named directly above, so the two can
                    // never disagree the way a second hardcoded card did.
                    HStack(spacing: 10) {
                        if coordinator.modelPreparing {
                            if let progress = coordinator.modelDownloadProgress {
                                ProgressView(value: progress).frame(width: 120)
                                Text("\(Int((progress * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        } else if coordinator.modelReady {
                            Label("Ready", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(.green)
                        } else {
                            Button("Retry") { Task { await coordinator.prepareModel() } }
                                .pointerStyle(.link)
                        }
                        // modelStatus names the model too, which only reads as
                        // repetition once the picker above is the source of truth.
                        Text(coordinator.modelReady
                            ? "Runs on your Mac — audio never leaves the device"
                            : coordinator.modelStatus)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }

                    Divider()

                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Language").font(.body.weight(.medium))
                            Text(settings.asrModel.languageCaption)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $settings.language) {
                            ForEach(settings.asrModel.supportedLanguages) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 155, alignment: .trailing)
                        .disabled(!settings.asrModel.offersLanguageChoice)
                        .onChange(of: settings.language) { _, _ in coordinator.applyTranscriptionLanguage() }
                    }
                }

                SettingsCard(title: "macOS access", systemImage: "lock.shield") {
                    ForEach(PermissionController.Kind.allCases) { kind in
                        PermissionSettingsRow(
                            kind: kind,
                            granted: permissions.isGranted(kind),
                            allow: { permissions.request(kind) },
                            openSettings: { permissions.openPrivacySettings(for: kind) }
                        )
                        if kind != PermissionController.Kind.allCases.last {
                            Divider()
                        }
                    }

                    Divider()

                    HStack {
                        Label("Status updates automatically", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Setup Assistant") { coordinator.showOnboarding() }
                            .pointerStyle(.link)
                    }
                }

                if let error = coordinator.lastError {
                    SettingsCard(title: "Last issue", systemImage: "exclamationmark.triangle") {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                SettingsCard(title: "Kimi cloud features", systemImage: "sparkles.rectangle.stack") {
                    Text("Optional. A Kimi API key lets Pressay periodically ask Kimi to review new names found in your transcripts and suggest vocabulary fixes. Without a key, dictation and tuning stay fully on-device.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        SecureField("sk-kimi-…", text: $apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            let saved = KimiAPIKeyStore.save(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                            apiKeyDraft = ""
                            keyStatus = saved ? "Saved to Keychain" : "Keychain refused the key — try again"
                            keyConfigured = saved || keyConfigured
                        }
                        .pointerStyle(.link)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if keyConfigured {
                            Button(testingConnection ? "Testing…" : "Test") { testConnection() }
                                .pointerStyle(.link)
                                .disabled(testingConnection)
                            Button("Clear") {
                                KimiAPIKeyStore.clear()
                                keyStatus = "Removed"
                                keyConfigured = false
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Circle()
                            .fill(keyConfigured ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(keyConfigured ? "Key saved — Kimi review enabled" : "Not set — on-device tuning only")
                            .font(.caption).foregroundStyle(.secondary)
                        if let keyStatus {
                            Text("· \(keyStatus)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(28)
            .padding(.top, 18)
        }
        .onAppear {
            permissions.startMonitoring()
            settings.refreshLaunchAtLogin()
            keyConfigured = KimiAPIKeyStore.read() != nil
            inputDevices = AudioDeviceMonitor.inputDevices()
            defaultInputName = AudioDeviceMonitor.defaultInputName
        }
    }

    private func testConnection() {
        guard let key = KimiAPIKeyStore.read() else { return }
        testingConnection = true
        keyStatus = nil
        Task {
            do {
                _ = try await KimiTunerClient().testConnection(apiKey: key)
                keyStatus = "Connection works"
            } catch {
                keyStatus = "Failed: \(error.localizedDescription)"
            }
            testingConnection = false
        }
    }
}

private struct PermissionSettingsRow: View {
    let kind: PermissionController.Kind
    let granted: Bool
    let allow: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.body.weight(.medium))
                Text(kind.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                if granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Allow") { allow() }
                        .pointerStyle(.link)
                    Button("System Settings") { openSettings() }
                        .pointerStyle(.link)
                }
            }
            .font(.caption.weight(.medium))
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
            Divider()
            content
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.32))
        }
    }
}

private struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

private struct DictionaryEntry: Identifiable {
    let preferred: String
    let aliases: [String]
    let line: String
    var id: String { line }
}

private struct DictionarySettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var learned: LearnedVocabularyStore
    @ObservedObject private var runner: VocabularyTunerRunner
    @State private var confirmingRestore = false
    @State private var addingEntry = false
    @State private var hoveredRow: String?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
        learned = coordinator.settings.learnedVocabulary
        runner = coordinator.tunerRunner
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    SettingsPageHeader(
                        title: "Dictionary",
                        subtitle: "How Pressay spells the names and terms you dictate"
                    )
                    Spacer()
                    Button("Add new") { addingEntry = true }
                        .pointerStyle(.link)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }

                learnedCard
                yourDictionaryCard

                HStack {
                    Spacer()
                    Button("Restore curated defaults") { confirmingRestore = true }
                        .pointerStyle(.link)
                        .font(.caption)
                }
                Text("\(settings.vocabularyEntries.count) terms (incl. \(learned.records.count) learned) · used for casing cleanup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(28)
            .padding(.top, 18)
        }
        .sheet(isPresented: $addingEntry) {
            AddDictionaryEntrySheet { preferred, aliases in
                addEntry(preferred: preferred, aliases: aliases)
            }
        }
        .confirmationDialog(
            "Replace your dictionary with the curated defaults?",
            isPresented: $confirmingRestore
        ) {
            Button("Restore defaults", role: .destructive) { settings.restoreCuratedVocabulary() }
                .pointerStyle(.link)
            Button("Cancel", role: .cancel) {}
                .pointerStyle(.link)
        } message: {
            Text("Any custom terms you added will be replaced.")
        }
    }

    private var learnedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Learned automatically", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                switch runner.status {
                case .idle, .done:
                    Button("Optimize now") { runner.runNow(history: coordinator.history, settings: settings) }
                        .pointerStyle(.link)
                        .controlSize(.small)
                case .running:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reviewing…").font(.caption).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Text("Kimi review failed: \(message)").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.bottom, 4)

            Text("Mishearings Pressay fixed from your recent transcripts.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 8)

            if learned.records.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.title3).foregroundStyle(.tertiary)
                    Text("Nothing learned yet — keep dictating and fixes show up here on their own.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 18)
            } else {
                ForEach(Array(learned.records.enumerated()), id: \.element.heard) { index, record in
                    if index > 0 { Divider() }
                    DictionaryRow(
                        alias: record.heard,
                        preferred: record.preferred,
                        badge: "✨",
                        trailing: "×\(record.count) · \(record.source)",
                        hovered: hoveredRow == "learned|\(record.heard)",
                        onDelete: { learned.remove(record) }
                    )
                    .onHover { hoveredRow = $0 ? "learned|\(record.heard)" : nil }
                }
            }

            Divider().padding(.top, 6)
            Text("Learned words stay while you keep using them; unused rules expire after ~3 months · deleted rules are never re-learned")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.32))
        }
    }

    private var yourDictionaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Your dictionary", systemImage: "text.book.closed")
                .font(.headline)
                .padding(.bottom, 8)

            ForEach(Array(parsedSections.enumerated()), id: \.offset) { sectionIndex, section in
                if let title = section.title {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.top, sectionIndex == 0 ? 2 : 12)
                        .padding(.bottom, 4)
                }
                ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    dictionaryRows(entry)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.32))
        }
    }

    @ViewBuilder
    private func dictionaryRows(_ entry: DictionaryEntry) -> some View {
        if entry.aliases.isEmpty {
            DictionaryRow(
                alias: nil,
                preferred: entry.preferred,
                badge: nil,
                trailing: nil,
                hovered: hoveredRow == entry.line,
                onDelete: { deleteEntry(line: entry.line) }
            )
            .onHover { hoveredRow = $0 ? entry.line : nil }
        } else {
            ForEach(entry.aliases, id: \.self) { alias in
                let rowKey = "\(entry.line)|\(alias)"
                DictionaryRow(
                    alias: alias,
                    preferred: entry.preferred,
                    badge: nil,
                    trailing: nil,
                    hovered: hoveredRow == rowKey,
                    onDelete: { removeAlias(entry: entry, alias: alias) }
                )
                .onHover { hoveredRow = $0 ? rowKey : nil }
            }
        }
    }

    private func removeAlias(entry: DictionaryEntry, alias: String) {
        let remaining = entry.aliases.filter { $0 != alias }
        var newLine = entry.preferred
        if !remaining.isEmpty { newLine += " <= " + remaining.joined(separator: ", ") }
        let lines = settings.vocabularySource
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) == entry.line ? newLine : $0 }
        settings.vocabularySource = lines.joined(separator: "\n")
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
        var line = preferred
        if !aliases.isEmpty { line += " <= " + aliases.joined(separator: ", ") }
        var source = settings.vocabularySource.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.contains("# Custom") { source += "\n\n# Custom" }
        source += "\n" + line
        settings.vocabularySource = source
    }
}

private struct DictionaryRow: View {
    let alias: String?
    let preferred: String
    let badge: String?
    let trailing: String?
    let hovered: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let alias {
                Text(alias)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(preferred)
                .font(.body.weight(alias == nil ? .regular : .semibold))
            if let badge {
                Text(badge).font(.caption)
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }
            if hovered {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .pointerStyle(.link)
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct AddDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preferred = ""
    @State private var aliases = ""
    let onSave: (String, [String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to dictionary").font(.title3.bold())
            Text("The preferred spelling is what gets inserted; aliases are the mishearings that map to it.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Preferred spelling (e.g. SonarCloud)", text: $preferred)
                .textFieldStyle(.roundedBorder)
            TextField("Aliases, comma-separated (e.g. soonercloud, sooner cloud)", text: $aliases)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .pointerStyle(.link)
                Button("Add") {
                    let aliasList = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    onSave(preferred.trimmingCharacters(in: .whitespaces), aliasList)
                    dismiss()
                }
                .pointerStyle(.link)
                .buttonStyle(.borderedProminent)
                .disabled(preferred.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct HistoryView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var history: HistoryStore
    @State private var showingDeleteAll = false
    @State private var searchText = ""
    @State private var hoveredID: UUID?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        history = coordinator.history
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                SettingsPageHeader(
                    title: "History",
                    subtitle: "Recent prompts stored only on this Mac"
                )
                Spacer()
                Button("Delete all", role: .destructive) { showingDeleteAll = true }
                    .pointerStyle(.link)
            }
            Text("Text expires after 30 days, audio after 7 days.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search prompts", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.top, 8)

            List(filteredRecords) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.referenceText).lineLimit(3)
                    Text(metaLine(record))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .overlay(alignment: .trailing) {
                    if hoveredID == record.id {
                        Button { coordinator.copy(record) } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy")
                    }
                }
                .onHover { hoveredID = $0 ? record.id : nil }
                .contextMenu {
                    Button("Copy") { coordinator.copy(record) }
                        .pointerStyle(.link)
                    Button("Delete entry", role: .destructive) { try? history.delete(record) }
                        .pointerStyle(.link)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: 760)
        .padding(28)
        .padding(.top, 18)
        .confirmationDialog("Delete all local history and audio?", isPresented: $showingDeleteAll) {
            Button("Delete all", role: .destructive) { try? history.deleteAll() }
                .pointerStyle(.link)
        }
    }

    private func metaLine(_ record: DictationRecord) -> String {
        let parts = [
            record.createdAt.formatted(.relative(presentation: .named)),
            record.totalLatency.formatted(.number.precision(.fractionLength(2))) + "s",
        ]
        return parts.joined(separator: " · ")
    }

    private var filteredRecords: [DictationRecord] {
        guard !searchText.isEmpty else { return history.records }
        return history.records.filter {
            $0.referenceText.localizedCaseInsensitiveContains(searchText)
                || ($0.targetBundleID?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
}
