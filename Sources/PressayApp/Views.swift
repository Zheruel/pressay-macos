import AppKit
import PressayCore
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var history: HistoryStore
    @ObservedObject private var permissions: PermissionController
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
        history = coordinator.history
        permissions = coordinator.permissions
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: PressayBrand.appIcon).resizable().frame(width: 34, height: 34)
                Text("Pressay").font(.system(size: 14, weight: .semibold))
                Spacer()
                Circle().fill(
                    coordinator.modelReady && coordinator.permissions.allGranted
                        ? PressayPalette.success : PressayPalette.warning
                ).frame(width: 6, height: 6)
            }.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 18)
            UpdateNoticeView(updater: coordinator.updates)
            if !settings.onboardingComplete {
                Text("Three permissions, then you’re ready.").font(.system(size: 12)).foregroundStyle(
                    PressayPalette.muted
                ).padding(.horizontal, 10).padding(.bottom, 16)
                Button("Continue setup") { coordinator.showOnboarding() }.buttonStyle(
                    PressayButtonStyle(kind: .primary)
                ).padding(.horizontal, 10)
            } else {
                if !coordinator.modelReady || !coordinator.permissions.allGranted {
                    Button {
                        if permissions.allGranted {
                            coordinator.settingsPaneRequest = "general"
                            coordinator.showSettings()
                        } else {
                            coordinator.showOnboarding()
                        }
                    } label: {
                        Label(
                            permissions.allGranted ? "Speech model needs attention" : "A permission needs attention",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.system(size: 11)).foregroundStyle(PressayPalette.warning)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                        .background(PressayPalette.warningSurface, in: .rect(cornerRadius: 9))
                    }.buttonStyle(PressayPlainButtonStyle()).padding(.bottom, 12)
                }
                HStack {
                    Text("Hold to talk").font(.system(size: 12))
                    Spacer()
                    Text(settings.holdKey.shortcutLabel).font(.system(size: 10)).padding(.horizontal, 9).padding(
                        .vertical, 5
                    )
                    .background(PressayPalette.button, in: .rect(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(PressayPalette.strongLine))
                }.padding(.horizontal, 12).padding(.vertical, 13)
                    .background(PressayPalette.surface, in: .rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PressayPalette.line))
                Toggle(isOn: $settings.claudeCleanup) {
                    Label("AI Cleanup", systemImage: "sparkles").font(.system(size: 12))
                }
                .toggleStyle(PressaySwitchStyle()).padding(.horizontal, 11).padding(.vertical, 17)
                menuDivider
                Text("RECENT DICTATIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(
                    PressayPalette.muted
                ).padding(.horizontal, 11).padding(.top, 14).padding(.bottom, 5)
                if history.records.isEmpty {
                    Text("Your dictations appear here.").font(.system(size: 12)).foregroundStyle(PressayPalette.muted)
                        .padding(18)
                }
                ForEach(Array(history.records.prefix(2).enumerated()), id: \.element.id) { index, record in
                    if index > 0 { menuDivider }
                    CompactHistoryRow(record: record, coordinator: coordinator)
                }
                menuDivider.padding(.top, 8).padding(.bottom, 10)
                if coordinator.liveSession != nil {
                    MenuRow(title: "Stop Notetaker", icon: "stop.fill") { coordinator.stopRecording() }
                } else {
                    MenuRow(
                        title: coordinator.meetingStarting ? "Cancel Notetaker setup" : "Start Notetaker", icon: "plus"
                    ) {
                        if coordinator.meetingStarting {
                            coordinator.cancelMeetingStart()
                        } else {
                            coordinator.startMeeting()
                        }
                    }
                }
                MenuRow(title: "Open Pressay", icon: "rectangle.on.rectangle") { coordinator.showSettings() }
                MenuRow(title: "Settings…", icon: "gearshape", shortcut: "⌘,") {
                    coordinator.settingsPaneRequest = "general"
                    coordinator.showSettings()
                }.keyboardShortcut(",", modifiers: .command)
            }
            menuDivider.padding(.top, 10).padding(.bottom, 5)
            CheckForUpdatesButton(updater: coordinator.updates)
                .buttonStyle(PressayPlainButtonStyle()).font(.system(size: 12))
                .padding(.horizontal, 11).frame(height: 38)
            MenuRow(title: "Quit Pressay", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }.keyboardShortcut(
                "q", modifiers: .command)
        }
        .padding(12).frame(width: 348)
        .font(.system(size: 13)).foregroundStyle(PressayPalette.text)
        .background(PressayPalette.base).tint(PressayPalette.accent)
    }
    private var menuDivider: some View { Rectangle().fill(PressayPalette.line).frame(height: 1) }
}

private struct MenuRow: View {
    let title: String
    var icon: String? = nil
    var shortcut: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).font(.system(size: 14)).frame(width: 16) }
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 10)).foregroundStyle(PressayPalette.muted) }
            }.font(.system(size: 12)).padding(.horizontal, 11).frame(height: 38)
                .contentShape(.rect)
        }.buttonStyle(PressayPlainButtonStyle())
    }
}

private struct CompactHistoryRow: View {
    let record: DictationRecord
    let coordinator: AppCoordinator
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(record.referenceText).font(.system(size: 11)).lineSpacing(3).lineLimit(2)
                HStack(spacing: 5) {
                    AppIcon(bundleID: record.targetBundleID, size: 16)
                    Text(
                        copied
                            ? "Copied"
                            : [
                                AppInfo.name(for: record),
                                record.createdAt.formatted(date: .omitted, time: .shortened),
                            ].compactMap { $0 }.joined(separator: " · ")
                    )
                    .font(.system(size: 10)).foregroundStyle(PressayPalette.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                coordinator.copy(record)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12)).frame(
                    width: 24, height: 28)
            }
            .buttonStyle(PressayPlainButtonStyle()).foregroundStyle(PressayPalette.muted).help("Copy dictation").accessibilityLabel(
                "Copy dictation")
        }.padding(.vertical, 12).padding(.horizontal, 11)
            .contextMenu {
                Button("Copy") { coordinator.copy(record) }
                Button("Paste again") { coordinator.retry(record) }
                Button("Delete", role: .destructive) { try? coordinator.history.delete(record) }
            }
    }
}

enum SettingsSection: String {
    case home, notes, history, dictionary, general, claude
    var title: String {
        switch self {
        case .home: "Home"
        case .notes: "Notetaker"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .general: "General"
        case .claude: "AI Cleanup"
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var permissions: PermissionController
    @State private var selection =
        ProcessInfo.processInfo.environment["PRESSAY_PANE"].flatMap(SettingsSection.init(rawValue:)) ?? .home
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        permissions = coordinator.permissions
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: PressayBrand.appIcon).resizable().frame(width: 31, height: 31)
                    Text("Pressay").font(.system(size: 17, weight: .semibold)).tracking(-0.45)
                }.padding(.horizontal, 11).padding(.top, 68).padding(.bottom, 26)
                navGroup([.home, .notes, .history])
                Spacer().frame(height: 20)
                navGroup([.dictionary])
                Spacer().frame(height: 20)
                navGroup([.general, .claude])
                Spacer(minLength: 12)
                UpdateNoticeView(updater: coordinator.updates)
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle().fill(PressayPalette.line).frame(height: 1).padding(.bottom, 9)
                    if let session = coordinator.liveSession {
                        MeetingRecordingStatus(session: session)
                    } else {
                        HStack(spacing: 7) {
                            Circle().fill(
                                coordinator.modelReady && permissions.allGranted
                                    ? PressayPalette.success : PressayPalette.warning
                            ).frame(width: 5, height: 5)
                            Text(
                                !permissions.allGranted
                                    ? "Needs permission"
                                    : coordinator.modelReady
                                        ? "Ready to dictate"
                                        : coordinator.modelPreparing ? "Preparing model…" : "Needs attention"
                            )
                            .font(.system(size: 11))
                        }
                        if coordinator.modelPreparing, let progress = coordinator.modelDownloadProgress {
                            HStack(spacing: 8) {
                                ProgressView(value: progress).controlSize(.small)
                                Text("\(Int(progress * 100))%").font(.system(size: 10)).monospacedDigit()
                                    .foregroundStyle(PressayPalette.muted)
                            }
                        }
                    }
                    Text("On-device · \(coordinator.activeSpeechModelName)").font(.system(size: 10)).foregroundStyle(
                        PressayPalette.muted)
                }.padding(.horizontal, 11).padding(.bottom, 14)
            }.padding(.horizontal, 12).frame(width: 216).background(PressayPalette.sidebar)
                .overlay(alignment: .trailing) { Rectangle().fill(PressayPalette.line).frame(width: 1) }
            Group {
                switch selection {
                case .home: HomeView(coordinator: coordinator) { selection = $0 }
                case .notes: NotetakerPage(coordinator: coordinator)
                case .history: HistoryView(coordinator: coordinator)
                case .dictionary: DictionarySettingsView(coordinator: coordinator)
                case .general: GeneralSettingsView(coordinator: coordinator)
                case .claude: ClaudeCleanupSettingsView(coordinator: coordinator)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(PressayPalette.base)
        }
        .font(.system(size: 13)).foregroundStyle(PressayPalette.text)
        .buttonStyle(PressayButtonStyle()).toggleStyle(PressaySwitchStyle()).tint(PressayPalette.accent)
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(coordinator.$settingsPaneRequest.compactMap { $0 }) { pane in
            selection = SettingsSection(rawValue: pane) ?? selection
            coordinator.settingsPaneRequest = nil
        }
        .frame(minWidth: 900, minHeight: 620)
    }
    private func navGroup(_ sections: [SettingsSection]) -> some View {
        ForEach(sections, id: \.rawValue) { section in
            Button {
                selection = section
            } label: {
                HStack {
                    Text(section.title).font(.system(size: 13, weight: selection == section ? .semibold : .regular))
                    Spacer()
                    if section == .notes, coordinator.liveSession != nil {
                        Circle().fill(PressayPalette.danger).frame(width: 6, height: 6)
                    }
                }
                .foregroundStyle(selection == section ? PressayPalette.text : PressayPalette.navigation)
                .padding(.horizontal, 12).frame(height: 38)
                .background(selection == section ? PressayPalette.selected : .clear, in: .rect(cornerRadius: 7))
                .contentShape(.rect)
            }.buttonStyle(PressayPlainButtonStyle()).accessibilityAddTraits(selection == section ? .isSelected : [])
        }
    }
}

struct StatusLabel: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: text == "Ready" || text == "Allowed" ? "checkmark" : "circle.fill").font(
                .system(size: 9, weight: .semibold))
            Text(text)
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(
            text == "Ready" || text == "Allowed" ? PressayPalette.successSurface : PressayPalette.warningSurface,
            in: .capsule)
    }
}

private struct HomeView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var history: HistoryStore
    @ObservedObject private var settings: AppSettings
    let open: (SettingsSection) -> Void
    init(coordinator: AppCoordinator, open: @escaping (SettingsSection) -> Void) {
        self.coordinator = coordinator
        history = coordinator.history
        settings = coordinator.settings
        self.open = open
    }
    var body: some View {
        let stats = history.stats()
        PressayPage {
            HStack(alignment: .top, spacing: 24) {
                HStack(alignment: .top, spacing: 0) {
                    metric("Words this week", stats.wordsThisWeek.formatted())
                    metricDivider
                    metric("Time saved this week", "\(stats.minutesSavedThisWeek) min", inset: 17)
                    metricDivider
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speaking pace").font(.system(size: 12)).foregroundStyle(PressayPalette.muted).frame(
                            height: 18)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(stats.wordsPerMinute.map(String.init) ?? "—").font(.system(size: 28, weight: .medium))
                                .tracking(-0.8).frame(height: 41)
                            if stats.wordsPerMinute != nil {
                                Text("wpm").font(.system(size: 12)).foregroundStyle(PressayPalette.muted)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 17)
                    metricDivider
                    metric("Streak", "\(stats.streakDays) \(stats.streakDays == 1 ? "day" : "days")", inset: 17)
                }
                StartNotetakerButton(coordinator: coordinator)
            }.padding(.bottom, 28)
            Rectangle().fill(PressayPalette.line).frame(height: 1).padding(.bottom, 28)
            HStack {
                Text("Recent dictations").font(.system(size: 15, weight: .semibold)).frame(height: 22)
                Spacer()
                if !history.records.isEmpty {
                    Button("View history") { open(.history) }.buttonStyle(PressayPlainButtonStyle()).foregroundStyle(PressayPalette.accent)
                        .font(.system(size: 12))
                }
            }.padding(.bottom, 12)
            if history.records.isEmpty {
                PressayGroup {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("No dictations yet").font(.system(size: 13, weight: .medium))
                        Text("Hold \(settings.holdKey.displayName) in any text field to dictate.").font(
                            .system(size: 12)
                        ).foregroundStyle(PressayPalette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 30)
                }
            } else {
                PressayGroup {
                    ForEach(history.records.prefix(6)) { record in
                        HistoryRow(record: record, coordinator: coordinator, showsDay: true)
                    }
                }
            }
        }
    }
    private var metricDivider: some View { Rectangle().fill(PressayPalette.line).frame(width: 1, height: 67) }
    private func metric(_ title: String, _ value: String, inset: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(PressayPalette.muted).frame(height: 18).lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value).font(.system(size: 28, weight: .medium)).tracking(-0.8).frame(height: 41).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, inset)
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
        let name = url.map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
        names[bundleID] = .some(name)
        return name
    }

    /// Falls back to the name saved at capture when the bundle ID is missing or no longer installed.
    static func name(for record: DictationRecord) -> String? {
        name(for: record.targetBundleID) ?? record.targetAppName
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleID] = .some(icon)
        return icon
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var permissions: PermissionController
    @State private var inputDevices: [AudioDeviceMonitor.Device] = []
    @State private var defaultInputName: String?
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
        permissions = coordinator.permissions
    }
    var body: some View {
        PressayPage {
            PressayHeading(title: "General") {
                HStack(spacing: 2) {
                    tab("Dictation", meetings: false)
                    tab("Notetaker", meetings: true)
                }
                .padding(3).background(PressayPalette.base, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PressayPalette.line))
            }
            if coordinator.notetakerSettingsSelected { meetingSettings } else { dictationSettings }
        }
        .task {
            permissions.startMonitoring()
            let inputs = await Task.detached(priority: .userInitiated) {
                (AudioDeviceMonitor.inputDevices(), AudioDeviceMonitor.defaultInputName)
            }.value
            guard !Task.isCancelled else { return }
            inputDevices = inputs.0
            defaultInputName = inputs.1
        }
    }
    private func tab(_ title: String, meetings: Bool) -> some View {
        Button {
            coordinator.notetakerSettingsSelected = meetings
        } label: {
            Text(title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).frame(height: 25)
                .background(
                    coordinator.notetakerSettingsSelected == meetings ? PressayPalette.selected : .clear,
                    in: .rect(cornerRadius: 5))
        }.buttonStyle(PressayPlainButtonStyle()).accessibilityAddTraits(
            coordinator.notetakerSettingsSelected == meetings ? .isSelected : [])
    }
    private var dictationSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            PressaySection(title: "Talk key") {
                PressayGroup {
                    PressaySetting(title: "Hold to talk", detail: "Press Esc to cancel.") {
                        KeyCaptureButton(
                            key: $settings.holdKey, onChange: coordinator.restartHotkey,
                            onCaptureActive: coordinator.keyCaptureActive)
                    }
                }
            }
            PressaySection(title: "Audio") {
                PressayGroup {
                    PressaySetting(title: "Microphone") {
                        PressayPicker(
                            label: "Microphone",
                            value: settings.inputDeviceUID.flatMap { uid in inputDevices.first { $0.uid == uid }?.name }
                                ?? "System Default", selection: $settings.inputDeviceUID,
                            items: [
                                PressayPickerItem<String?>.choice(
                                    defaultInputName.map { "System default (\($0))" } ?? "System default", nil)
                            ] + inputDevices.map { .choice($0.name, Optional($0.uid)) }
                        ).labelsHidden().frame(maxWidth: 260)
                    }
                }
            }
            PressaySection(title: "Transcription") {
                PressayGroup {
                    PressaySetting(title: "Speech model") {
                        SpeechModelPicker(selection: $settings.asrModel, meetings: false)
                            .disabled(
                                coordinator.liveSession != nil || coordinator.meetingStarting
                                    || coordinator.modelPreparing
                            )
                            .onChange(of: settings.asrModel) { _, _ in coordinator.applyASRModel() }
                    }
                    PressaySetting(title: "Language", detail: settings.asrModel.languageCaption) {
                        languagePicker(model: settings.asrModel, selection: $settings.language)
                            .onChange(of: settings.language) { _, _ in coordinator.applyTranscriptionLanguage() }
                    }
                    PressaySetting(title: "Status") { ModelStatusView(coordinator: coordinator) }
                }
            }
            PressaySection(title: "Permissions") {
                PressayGroup {
                    if permissions.allGranted {
                        PressaySetting(title: "Microphone, Accessibility & Input Monitoring") {
                            StatusLabel(text: "Allowed", color: PressayPalette.success)
                        }
                    } else {
                        ForEach(PermissionController.Kind.allCases) { kind in
                            PressaySetting(title: kind.title) {
                                if permissions.isGranted(kind) {
                                    StatusLabel(text: "Allowed", color: PressayPalette.success)
                                } else {
                                    Button("Allow") { permissions.request(kind) }.contextMenu {
                                        Button("Open System Settings") { permissions.openPrivacySettings(for: kind) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            PressaySection(title: "Startup") {
                PressayGroup {
                    PressaySetting(title: "Open at login") {
                        Toggle("Open at login", isOn: $settings.launchAtLogin).toggleStyle(
                            PressaySwitchStyle(showsLabel: false)
                        ).frame(width: 32)
                    }
                    if let error = settings.launchAtLoginError {
                        PressaySetting(title: "Login items", detail: error) {
                            Button("Open settings") { settings.openLoginItemsSettings() }
                        }
                    }
                }
            }
            PressaySection(title: "App updates") {
                UpdatePreferencesView(updater: coordinator.updates)
            }
            if let error = coordinator.lastError {
                Text(error).font(.system(size: 12)).foregroundStyle(PressayPalette.danger).padding(.top, 18)
                    .textSelection(.enabled)
            }
        }
    }
    private var meetingSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            PressaySection(title: "Transcription") {
                PressayGroup {
                    PressaySetting(title: "Meeting speech model") {
                        SpeechModelPicker(selection: $settings.meetingASRModel, meetings: true)
                            .disabled(coordinator.liveSession != nil || coordinator.meetingStarting)
                            .onChange(of: settings.meetingASRModel) { _, model in
                                if !model.supportedLanguages.contains(settings.meetingLanguage) {
                                    settings.meetingLanguage = .auto
                                }
                            }
                    }
                    PressaySetting(title: "Language", detail: settings.meetingASRModel.languageCaption) {
                        languagePicker(model: settings.meetingASRModel, selection: $settings.meetingLanguage)
                            .disabled(coordinator.liveSession != nil || coordinator.meetingStarting)
                    }
                }
            }
            PressaySection(title: "Meeting notes") {
                PressayGroup {
                    PressaySetting(title: "Write up notes with AI", detail: "Summaries, decisions, and action items.") {
                        Toggle("Write notes with AI", isOn: $settings.notesUseAI).toggleStyle(
                            PressaySwitchStyle(showsLabel: false)
                        ).frame(width: 32).disabled(coordinator.notesModelOptions.isEmpty)
                    }
                    if coordinator.notesModelOptions.isEmpty {
                        PressaySetting(title: "Connect meeting AI", detail: "Requires an Anthropic API key or a ChatGPT subscription.") {
                            Button("Set up AI Cleanup") { coordinator.settingsPaneRequest = "claude" }
                        }
                    } else {
                        PressaySetting(title: "AI model", detail: "Uses an account connected in AI Cleanup.") {
                            PressayPicker(
                                label: "Notes model", value: coordinator.notesModel.map(notesTitle) ?? "Choose model",
                                selection: Binding(
                                    get: { coordinator.notesModel?.id ?? "" }, set: { settings.notesModel = $0 }),
                                items: coordinator.notesModelOptions.map { .choice(notesTitle($0), $0.id) }
                            ).labelsHidden().frame(width: 240).disabled(!settings.notesUseAI)
                        }
                    }
                }
            }
            PressaySection(title: "Calls") {
                PressayGroup {
                    switchRow("Offer to take notes when a call starts", nil, $settings.detectCalls)
                }
            }
            PressaySection(title: "While recording") {
                PressayGroup {
                    PressaySetting(title: "Stop after") {
                        PressayPicker(
                            label: "Stop after", value: "\(settings.maxMeetingHours) hours",
                            selection: $settings.maxMeetingHours,
                            items: [1, 2, 3, 4, 6, 8].map { .choice("\($0) \($0 == 1 ? "hour" : "hours")", $0) }
                        ).labelsHidden().frame(width: 130)
                    }
                }
            }
        }
    }
    private func notesTitle(_ model: NotesModel) -> String {
        let rank = model.isRecommended ? "1. " : "2. "
        return rank + model.title + (model.isRecommended ? " · Recommended" : "")
    }
    private func switchRow(_ title: String, _ detail: String?, _ binding: Binding<Bool>) -> some View {
        PressaySetting(title: title, detail: detail) {
            Toggle(title, isOn: binding).toggleStyle(PressaySwitchStyle(showsLabel: false)).frame(width: 32)
        }
    }
    @ViewBuilder private func languagePicker(model: ASRModel, selection: Binding<TranscriptionLanguage>) -> some View {
        if model.offersLanguageChoice {
            PressayPicker(
                label: "Language", value: selection.wrappedValue.displayName, selection: selection,
                items: model.supportedLanguages.map { .choice($0.displayName, $0) }
            ).labelsHidden().frame(width: 200)
        } else {
            Text("Automatic").font(.system(size: 12)).foregroundStyle(PressayPalette.muted)
        }
    }
}

struct SpeechModelPicker: View {
    @Binding var selection: ASRModel
    var meetings = false
    private var modelItems: [PressayPickerItem<ASRModel>] {
        let ranked = (meetings ? ASRModel.meetingRecommendations : ASRModel.recommended)
        return ranked.enumerated().map { rank, model in
            .choice(
                "\(rank + 1). \(model.displayName)\(model == (meetings ? .defaultMeeting : .defaultDictation) ? " · Recommended" : "")",
                model)
        } + [.heading("Other models · not ranked")] + ASRModel.otherModels.map { .choice($0.displayName, $0) }
    }
    var body: some View {
        PressayPicker(
            label: "Speech model",
            value: (meetings ? ASRModel.meetingRecommendations : ASRModel.recommended).firstIndex(of: selection).map {
                "\($0 + 1). "
            }.map {
                $0 + selection.displayName
                    + (selection == (meetings ? .defaultMeeting : .defaultDictation) ? " · Recommended" : "")
            } ?? selection.displayName, selection: $selection, items: modelItems
        ).labelsHidden().frame(width: 240)
    }
}

struct ModelStatusView: View {
    @ObservedObject var coordinator: AppCoordinator
    var body: some View {
        if coordinator.modelPreparing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…")
            }.font(.system(size: 11)).foregroundStyle(PressayPalette.muted)
        } else if coordinator.modelReady {
            StatusLabel(text: "Ready", color: PressayPalette.success)
        } else {
            HStack(spacing: 8) {
                StatusLabel(text: "Not loaded", color: PressayPalette.warning)
                Button("Retry") { Task { await coordinator.prepareModel() } }
            }.help(coordinator.modelStatus)
        }
    }
}

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
    private var account: ChatGPTAccount { coordinator.chatGPT }
    private var selectedKey: String? {
        settings.cleanupProvider == .claude ? coordinator.claudeAPIKey : coordinator.openAIAPIKey
    }
    private var keyConfigured: Bool { selectedKey != nil }
    private var connection: CleanupConnection {
        settings.cleanupProvider == .claude ? settings.claudeConnection : settings.openAIConnection
    }
    private var connectionBinding: Binding<CleanupConnection> {
        Binding(get: { connection }, set: {
            keyDraft = ""
            keyStatus = nil
            if settings.cleanupProvider == .claude { settings.claudeConnection = $0 }
            else { settings.openAIConnection = $0 }
        })
    }
    var body: some View {
        PressayPage {
            PressayHeading(title: "AI Cleanup", subtitle: "Correct dictations before they’re typed.") { EmptyView() }
            PressaySection(title: "Cleanup") {
                PressayGroup {
                    PressaySetting(
                        title: "Clean up with AI", detail: "Fix filler words, punctuation, and misheard names."
                    ) {
                        Toggle("Clean up with AI", isOn: $settings.claudeCleanup).toggleStyle(
                            PressaySwitchStyle(showsLabel: false)
                        ).frame(width: 32)
                    }
                    PressaySetting(title: "Provider", detail: "Choose how Pressay polishes your words.") {
                        HStack(spacing: 2) {
                            provider("Claude", .claude)
                            provider("OpenAI", .chatgpt)
                        }.padding(3).background(PressayPalette.base, in: .rect(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PressayPalette.line))
                    }
                    PressaySetting(title: "Connection") {
                        Picker("Connection", selection: connectionBinding) {
                            ForEach(CleanupConnection.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 230)
                    }
                    if connection == .apiKey {
                        PressaySetting(
                            title: "API key",
                            detail: keyConfigured
                                ? "•••• •••• \(selectedKey.map { String($0.suffix(4)) } ?? "") · Connected"
                                : "Uses your API account."
                        ) {
                            if keyConfigured {
                                HStack(spacing: 8) {
                                    Button(testing ? "Verifying…" : "Verify", action: testConnection).disabled(testing)
                                    Button("Remove") { confirmingRemove = true }.buttonStyle(
                                        PressayButtonStyle(kind: .quiet))
                                }
                            } else {
                                HStack(spacing: 8) {
                                    SecureField(settings.cleanupProvider == .claude ? "sk-ant-…" : "sk-…", text: $keyDraft).textFieldStyle(.roundedBorder).frame(
                                        width: 170
                                    ).onSubmit(saveKey).accessibilityLabel("API key")
                                    Button("Save", action: saveKey).disabled(
                                        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                        }

                    } else if settings.cleanupProvider == .claude {
                        PressaySetting(
                            title: "Claude Code",
                            detail: coordinator.claudeCode.isSignedIn
                                ? "Connected through Claude Code. Uses your plan’s limits."
                                : "Sign in through Claude Code with your Claude subscription."
                        ) {
                            if coordinator.claudeCode.signingIn {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Button("Cancel") { coordinator.claudeCode.cancelSignIn() }
                                }
                            } else {
                                Button(coordinator.claudeCode.isSignedIn ? "Refresh status" : "Continue with Claude") {
                                    Task {
                                        if coordinator.claudeCode.isSignedIn { await coordinator.claudeCode.refreshStatus() }
                                        else {
                                            await coordinator.claudeCode.signIn()
                                            if coordinator.claudeCode.isSignedIn { settings.claudeCleanup = true }
                                        }
                                    }
                                }.disabled(!coordinator.claudeCode.isAvailable)
                            }
                        }
                        if !coordinator.claudeCode.isAvailable {
                            HStack {
                                Link("Install Claude Code", destination: URL(string: "https://code.claude.com/docs/en/overview")!)
                                Button("Check again") { Task { await coordinator.claudeCode.refreshStatus() } }
                            }.font(.system(size: 11)).foregroundStyle(PressayPalette.muted).padding(12)
                        }
                    } else {
                        PressaySetting(
                            title: "Account",
                            detail: account.isSignedIn
                                ? account.credentials?.email : "Use an eligible ChatGPT plan. Cleanup uses plan limits or credits."
                        ) {
                            if account.isSignedIn {
                                Button("Sign out") { confirmingSignOut = true }
                            } else if account.signingIn {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Button("Cancel") { account.cancelSignIn() }
                                }
                            } else {
                                Button("Continue with ChatGPT", action: signIn).buttonStyle(
                                    PressayButtonStyle(kind: .primary))
                            }
                        }
                    }
                }
                if let keyStatus, connection == .apiKey {
                    Text(keyStatus).font(.system(size: 11)).foregroundStyle(
                        keyStatusIsError ? PressayPalette.danger : PressayPalette.success)
                }
                if let error = account.lastError, settings.cleanupProvider == .chatgpt, connection == .subscription {
                    Text(error).font(.system(size: 11)).foregroundStyle(PressayPalette.danger)
                }
            }
            if let error = coordinator.claudeCode.lastError,
                settings.cleanupProvider == .claude, connection == .subscription {
                Text(error).font(.system(size: 11)).foregroundStyle(PressayPalette.danger)
            }
            PressaySection(title: "Example") {
                PressayGroup {
                    HStack(alignment: .top, spacing: 0) {
                        example(
                            "YOU SAY", "“um can you send the figma file\nwhen you get a chance thanks”", accent: false)
                        Rectangle().fill(PressayPalette.line).frame(width: 1)
                        example(
                            "PRESSAY TYPES", "Can you send the Figma file when\nyou get a chance? Thanks!", accent: true
                        )
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: $confirmingRemove) {
            PressayConfirmation(
                title: "Remove API key?", detail: "API cleanup will stop until you add another key or change the connection.",
                action: "Remove key", destructive: true
            ) {
                removeKey()
                confirmingRemove = false
            }
        }
        .confirmationDialog("Sign out of ChatGPT?", isPresented: $confirmingSignOut) {
            Button("Sign out", role: .destructive) { Task { await account.signOut() } }
        }
        .alert("You’re using your ChatGPT plan", isPresented: $showingPlanWelcome) {
            Button("Got it") { settings.chatGPTWelcomeShown = true }
        } message: {
            Text(
                "Cleanup uses your eligible ChatGPT plan’s limits or credits, shared with other apps. Pressay never sees your password."
            )
        }
    }
    private func provider(_ title: String, _ provider: CleanupProvider) -> some View {
        Button {
            keyDraft = ""
            keyStatus = nil
            settings.cleanupProvider = provider
        } label: {
            Text(title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 13).frame(height: 25)
                .background(
                    settings.cleanupProvider == provider ? PressayPalette.button : .clear, in: .rect(cornerRadius: 5))
        }.buttonStyle(PressayPlainButtonStyle()).accessibilityAddTraits(settings.cleanupProvider == provider ? .isSelected : [])
    }
    private func example(_ label: String, _ text: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.system(size: 10)).foregroundStyle(accent ? PressayPalette.accent : PressayPalette.muted)
            Text(text).font(.system(size: 13)).lineSpacing(5).foregroundStyle(
                accent ? PressayPalette.text : PressayPalette.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
    }
    private func signIn() {
        Task {
            await account.signIn()
            guard account.isSignedIn else { return }
            settings.claudeCleanup = true
            if !settings.chatGPTWelcomeShown { showingPlanWelcome = true }
        }
    }

    private func setStatus(_ text: String?, error: Bool) {
        keyStatus = text
        keyStatusIsError = error
    }

    private func removeKey() {
        #if DEBUG
            guard !DesignReview.enabled else { return }
        #endif
        if settings.cleanupProvider == .claude {
            ClaudeAPIKeyStore.clear()
            coordinator.reloadClaudeKey()
        } else {
            OpenAIAPIKeyStore.clear()
            coordinator.reloadOpenAIKey()
        }
        setStatus(nil, error: false)
    }

    private func saveKey() {
        #if DEBUG
            guard !DesignReview.enabled else {
                keyDraft = ""
                return
            }
        #endif
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let saved: Bool
        if settings.cleanupProvider == .claude {
            saved = ClaudeAPIKeyStore.save(key)
            coordinator.reloadClaudeKey()
        } else {
            saved = OpenAIAPIKeyStore.save(key)
            coordinator.reloadOpenAIKey()
        }
        keyDraft = ""
        if saved {
            settings.claudeCleanup = true
            testConnection()
        } else {
            setStatus("Couldn’t save to Keychain", error: true)
        }
    }

    private func testConnection() {
        #if DEBUG
            guard !DesignReview.enabled else {
                setStatus("Verified in review", error: false)
                return
            }
        #endif
        guard let key = selectedKey else { return }
        let provider = settings.cleanupProvider
        testing = true
        keyStatus = nil
        Task {
            do {
                if provider == .chatgpt {
                    try await coordinator.verifyOpenAIKey(key)
                    if settings.cleanupProvider == provider, selectedKey == key { setStatus("Verified", error: false) }
                    testing = false
                    return
                }
                _ = try await ClaudeCleaner().clean(
                    "Please run all the tests and tell me which ones failed, but do not deploy anything yet.",
                    targetBundleID: nil, vocabulary: [], model: .haiku55, apiKey: key, timeout: 12)
                if settings.cleanupProvider == provider, selectedKey == key { setStatus("Verified", error: false) }

            } catch {
                if settings.cleanupProvider == provider, selectedKey == key { setStatus(error.localizedDescription, error: true) }
            }
            testing = false
        }
    }
}

struct PressayConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let detail: String
    let action: String
    var destructive = false
    let confirm: () -> Void
    var body: some View {
        PressaySheet(title: title) {
            Text(detail).font(.system(size: 12)).foregroundStyle(PressayPalette.muted)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action, action: confirm).buttonStyle(PressayButtonStyle(kind: destructive ? .danger : .primary))
                    .keyboardShortcut(.defaultAction)
            }.padding(.top, 24)
        }
    }
}

private struct DictionaryRow: Identifiable, Equatable {
    let id = UUID()
    var word: String
    var soundsLike: String
}

/// One editable row per word, like Hex's vocabulary sheet. Edits save as you type;
/// rows without a word are kept on screen but never saved.
private struct DictionarySettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var settings: AppSettings
    @State private var rows: [DictionaryRow] = []
    @FocusState private var focused: UUID?
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
    }
    var body: some View {
        PressayPage(lazy: true) {
            PressayHeading(title: "Dictionary", subtitle: "Set the spelling of names and terms.") {
                Button(action: add) {
                    Label("Add word", systemImage: "plus")
                }.buttonStyle(PressayButtonStyle(kind: .primary))
            }
            if rows.isEmpty {
                PressayEmpty(
                    title: "No words yet", detail: "Add names and terms you want Pressay to spell correctly.",
                    systemImage: "character.book.closed", actionTitle: "Add your first word", action: add)
            } else {
                PressayGroup {
                    HStack(spacing: 10) {
                        Text("WORD").frame(width: 190, alignment: .leading)
                        Text("SOUNDS LIKE").frame(maxWidth: .infinity, alignment: .leading)
                        Spacer().frame(width: 28)
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(PressayPalette.muted)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    ForEach($rows) { $row in
                        HStack(spacing: 10) {
                            TextField("Word", text: $row.word).modifier(PressayField()).frame(width: 190)
                                .focused($focused, equals: row.id).accessibilityLabel("Word")
                            TextField("Optional, comma-separated", text: $row.soundsLike).modifier(PressayField())
                                .accessibilityLabel("Sounds like")
                            Button {
                                rows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                                    .frame(width: 28, height: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(PressayPlainButtonStyle()).foregroundStyle(PressayPalette.muted).help("Remove")
                            .accessibilityLabel(row.word.isEmpty ? "Remove word" : "Remove \(row.word)")
                        }
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .overlay(alignment: .top) { Rectangle().fill(PressayPalette.line).frame(height: 1) }
                    }
                }
                Text("Pressay writes each word with this spelling. Under Sounds like, add what it gets misheard as.")
                    .font(.system(size: 11)).foregroundStyle(PressayPalette.muted).padding(.top, 10)
            }
        }
        .onAppear(perform: load)
        .onChange(of: rows) { _, rows in
            let source = Self.source(for: rows)
            if source != settings.vocabularySource { settings.vocabularySource = source }
        }
        .onChange(of: settings.vocabularySource) { _, source in
            if source != Self.source(for: rows) { load() }
        }
    }
    private func load() {
        rows = VocabularyParser.parse(settings.vocabularySource).map {
            DictionaryRow(word: $0.preferred, soundsLike: $0.aliases.joined(separator: ", "))
        }
    }
    private func add() {
        if let blank = rows.first(where: { $0.word.trimmingCharacters(in: .whitespaces).isEmpty }) {
            focused = blank.id
            return
        }
        let row = DictionaryRow(word: "", soundsLike: "")
        rows.append(row)
        DispatchQueue.main.async { focused = row.id }
    }
    static func source(for rows: [DictionaryRow]) -> String {
        rows.compactMap { row in
            let word = row.word.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { return nil }
            let aliases = row.soundsLike.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return aliases.isEmpty ? word : "\(word) <= \(aliases.joined(separator: ", "))"
        }.joined(separator: "\n")
    }
}

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
        let groups = groups
        PressayPage(lazy: true) {
            PressayHeading(title: "History") {
                Button("Clear history…") { showingDeleteAll = true }.disabled(history.records.isEmpty).buttonStyle(
                    PressayButtonStyle(kind: .quiet))
            }
            if !history.records.isEmpty {
                PressaySearch(placeholder: "Search dictations", text: $searchText).padding(.bottom, 24)
            }
            if groups.isEmpty {
                PressayEmpty(
                    title: history.records.isEmpty ? "No dictations yet" : "No matching dictations.",
                    detail: history.records.isEmpty
                        ? "Your dictations stay here for 30 days. Hold \(coordinator.settings.holdKey.displayName) in any app to get started."
                        : "Try another word or an app name.",
                    systemImage: history.records.isEmpty ? "clock" : "magnifyingglass",
                    hint: history.records.isEmpty ? coordinator.settings.holdKey.shortcutLabel : nil)
            }
            ForEach(groups, id: \.title) { group in
                PressaySection(title: group.title) {
                    PressayGroup(lazy: true) { ForEach(group.records) { HistoryRow(record: $0, coordinator: coordinator) } }
                }
            }
            if !history.records.isEmpty {
                Text("Dictations are kept for 30 days; audio for 7 days.").font(.system(size: 11)).foregroundStyle(
                    PressayPalette.muted
                ).padding(.top, 5)
            }
        }
        .sheet(isPresented: $showingDeleteAll) {
            PressayConfirmation(
                title: "Clear dictation history?",
                detail: "All dictations and their audio recordings will be deleted. This can’t be undone.",
                action: "Clear history", destructive: true
            ) {
                try? history.deleteAll()
                showingDeleteAll = false
            }
        }
    }
    private var filteredRecords: [DictationRecord] {
        guard !searchText.isEmpty else { return history.records }
        return history.records.filter {
            $0.referenceText.localizedCaseInsensitiveContains(searchText)
                || (AppInfo.name(for: $0)?.localizedCaseInsensitiveContains(searchText) ?? false)
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
    var showsDay = false
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIcon(bundleID: record.targetBundleID).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.referenceText).font(.system(size: 13)).lineSpacing(5).padding(.vertical, 2).lineLimit(3)
                    .textSelection(.enabled)
                Text(meta).font(.system(size: 10)).foregroundStyle(PressayPalette.muted).frame(minHeight: 15)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13)).frame(
                    width: 28, height: 28)
            }
            .buttonStyle(PressayPlainButtonStyle()).foregroundStyle(PressayPalette.muted).help("Copy dictation").accessibilityLabel(
                "Copy dictation")
        }.padding(.horizontal, 17).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(PressayPalette.line).frame(height: 1) }
            .contextMenu {
                Button("Copy", action: copy)
                Button("Paste again") { coordinator.retry(record) }
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
    private var meta: String {
        [
            AppInfo.name(for: record),
            showsDay
                ? record.createdAt.formatted(.relative(presentation: .named))
                : record.createdAt.formatted(date: .omitted, time: .shortened), "\(Int(record.duration.rounded())) sec",
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct MeetingRecordingStatus: View {
    @ObservedObject var session: LiveSession
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(session.phase == .finishing ? PressayPalette.muted : PressayPalette.danger)
                .frame(width: 5, height: 5)
            Text(session.phase == .finishing ? "Finishing meeting" : "Recording meeting")
                .font(.system(size: 11))
        }
    }
}
