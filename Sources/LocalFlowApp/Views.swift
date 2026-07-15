import AppKit
import LocalFlowCore
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
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
                Text("Hold (settings.holdKey.rawValue) and speak")
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
            Button("Delete", role: .destructive) { try? coordinator.history.delete(record) }
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    Image(nsImage: PressayBrand.appIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 38, height: 38)
                        .shadow(color: .indigo.opacity(0.16), radius: 7, y: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Pressay").font(.headline)
                        Text(coordinator.modelReady ? "Ready · On-device" : "Preparing local model")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

                Divider()

                List(SettingsSection.allCases, selection: $selection) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .background(.ultraThinMaterial)
        } detail: {
            switch selection ?? .general {
            case .general:
                GeneralSettingsView(coordinator: coordinator)
            case .vocabulary:
                VocabularySettingsView(settings: coordinator.settings)
            case .history:
                HistoryView(coordinator: coordinator)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case vocabulary
    case history

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .vocabulary: "text.book.closed"
        case .history: "clock.arrow.circlepath"
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var permissions: PermissionController

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
                        Picker("", selection: $settings.holdKey) {
                            ForEach(HoldKey.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 155)
                        .onChange(of: settings.holdKey) { _, _ in coordinator.restartHotkey() }
                    }

                    Divider()

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
                        }
                    }
                }

                SettingsCard(title: "Local transcription", systemImage: "cpu") {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.badge.sparkles")
                            .font(.title2)
                            .foregroundStyle(.indigo)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Whisper Large V3 Turbo").font(.body.weight(.medium))
                            Text(coordinator.modelStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if coordinator.modelPreparing {
                            ProgressView().controlSize(.small)
                        } else if coordinator.modelReady {
                            Label("Ready", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(.green)
                        } else {
                            Button("Retry") { Task { await coordinator.prepareModel() } }
                        }
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
                    }
                }

                if let error = coordinator.lastError {
                    SettingsCard(title: "Last issue", systemImage: "exclamationmark.triangle") {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(28)
        }
        .background(.background)
        .onAppear {
            permissions.startMonitoring()
            settings.refreshLaunchAtLogin()
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
                    Button("System Settings") { openSettings() }
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

private struct VocabularySettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var confirmingRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                SettingsPageHeader(
                    title: "Vocabulary",
                    subtitle: "Curated for Slack and coding, with room for your projects and names"
                )
                Spacer()
                Button("Restore curated defaults") { confirmingRestore = true }
            }
            .padding(.bottom, 8)
            Text("One preferred spelling per line. Add safe mishearings with `Preferred <= alias, another alias`. Lines beginning with # are section labels.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $settings.vocabularySource)
                .font(.system(.body, design: .monospaced))
                .lineSpacing(2)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5)))
            Text("\(settings.vocabularyEntries.count) terms · used for safe casing cleanup and polish validation")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .confirmationDialog(
            "Replace your vocabulary with the curated Slack and coding defaults?",
            isPresented: $confirmingRestore
        ) {
            Button("Restore defaults", role: .destructive) { settings.restoreCuratedVocabulary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any custom names or aliases in the editor will be replaced.")
        }
    }
}

private struct HistoryView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var history: HistoryStore
    @State private var editing: DictationRecord?
    @State private var showingDeleteAll = false
    @State private var searchText = ""

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        history = coordinator.history
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SettingsPageHeader(
                    title: "History",
                    subtitle: "Recent prompts and calibration examples stored only on this Mac"
                )
                Spacer()
                Button("Delete all", role: .destructive) { showingDeleteAll = true }
            }
            Text("Text expires after 30 days and audio after 7 days. Edited or pinned entries are retained.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Editing changes copy and retry for that entry; it does not retrain the transcription model.")
                .font(.caption).foregroundStyle(.secondary)
            List(filteredRecords) { record in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.referenceText).lineLimit(3)
                        Text("\(record.createdAt.formatted()) · \(record.totalLatency.formatted(.number.precision(.fractionLength(2))))s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { try? history.togglePin(record) } label: {
                        Image(systemName: record.isPinned ? "pin.fill" : "pin")
                    }
                    .help(record.isPinned ? "Unpin" : "Pin")
                    Button("Edit text") { editing = record }
                    Button { coordinator.copy(record) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy")
                    Button(role: .destructive) { try? history.delete(record) } label: { Image(systemName: "trash") }
                        .help("Delete")
                }
            }
        }
        .padding(28)
        .searchable(text: $searchText, prompt: "Search prompts")
        .sheet(item: $editing) { CorrectionView(record: $0, history: history) }
        .confirmationDialog("Delete all local history and audio?", isPresented: $showingDeleteAll) {
            Button("Delete all", role: .destructive) { try? history.deleteAll() }
        }
    }

    private var filteredRecords: [DictationRecord] {
        guard !searchText.isEmpty else { return history.records }
        return history.records.filter {
            $0.referenceText.localizedCaseInsensitiveContains(searchText)
                || ($0.targetBundleID?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
}

private struct CorrectionView: View {
    @Environment(\.dismiss) private var dismiss
    let record: DictationRecord
    let history: HistoryStore
    @State private var correction: String

    init(record: DictationRecord, history: HistoryStore) {
        self.record = record
        self.history = history
        _correction = State(initialValue: record.correction ?? record.polishedText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit saved text").font(.title2.bold())
            Text("Raw: \(record.rawTranscript)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $correction).frame(minHeight: 180)
                .padding(6).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save and retain") {
                    try? history.update(record, correction: correction, pin: true)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
