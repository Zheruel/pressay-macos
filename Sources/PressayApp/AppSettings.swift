import Foundation
import PressayCore
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let holdKey = "holdKey"
        static let holdKeyCode = "holdKeyCode"
        static let language = "language"
        static let asrModel = "asrModel"
        static let meetingASRModel = "meetingASRModel"
        static let meetingLanguage = "meetingLanguage"
        static let vocabulary = "vocabulary"
        static let onboardingComplete = "onboardingComplete"
        static let hasUsedDictation = "hasUsedDictation"
        static let inputDevice = "inputDeviceUID"
        static let claudeCleanup = "claudeCleanup"
        static let claudeConnection = "claudeConnection"
        static let cleanupProvider = "cleanupProvider"
        static let openAIConnection = "openAIConnection"
        static let chatGPTWelcomeShown = "chatGPTWelcomeShown"
        static let manualVocabularyOnly = "manualVocabularyOnly"
        static let notesModel = "notesModel"
        static let snippets = "snippets"
        static let detectCalls = "detectCalls"
        static let stopWhenCallEnds = "stopWhenCallEnds"
        static let maxMeetingHours = "maxMeetingHours"
        static let notesUseAI = "notesUseAI"
        static let meetingSystemAudio = "meetingSystemAudio"
        static let separateVoices = "separateVoices"
        static let retired = ["polishHoldKeyCode", "polishModel", "noteStyle", "matchAppStyle", "keepMicWarm", "vocabularySuggestions.pending", "vocabularySuggestions.lastMined", "vocabularySuggestions.dismissed",
            "learnFromEdits", "vocabularyTuner.rules", "vocabularyTuner.blocklist",
            "vocabularyTuner.lastDetRun", "vocabularyTuner.lastK3Run",
            "vocabularyTuner.seenCandidates", "vocabularyTuner.schemaVersion", "structuredDictation", "openNotepad", "showLiveTranscript"]
    }

    private let defaults: UserDefaults
    private var isRollingBackLaunchAtLogin = false

    @Published var holdKey: HoldKey { didSet { defaults.set(holdKey.keyCode, forKey: Key.holdKeyCode) } }
    @Published var language: TranscriptionLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    @Published var asrModel: ASRModel { didSet { defaults.set(asrModel.rawValue, forKey: Key.asrModel) } }
    @Published var meetingASRModel: ASRModel { didSet { defaults.set(meetingASRModel.rawValue, forKey: Key.meetingASRModel) } }
    @Published var meetingLanguage: TranscriptionLanguage { didSet { defaults.set(meetingLanguage.rawValue, forKey: Key.meetingLanguage) } }
    @Published var vocabularySource: String { didSet { defaults.set(vocabularySource, forKey: Key.vocabulary) } }
    @Published var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) } }
    @Published var hasUsedDictation: Bool { didSet { defaults.set(hasUsedDictation, forKey: Key.hasUsedDictation) } }
    /// CoreAudio UID of the dictation input, or nil to follow the system default.
    @Published var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: Key.inputDevice) } }
    /// On by default so saving a key is the single opt-in step.
    @Published var claudeCleanup: Bool { didSet { defaults.set(claudeCleanup, forKey: Key.claudeCleanup) } }
    @Published var claudeConnection: CleanupConnection {
        didSet { defaults.set(claudeConnection.rawValue, forKey: Key.claudeConnection) }
    }
    @Published var cleanupProvider: CleanupProvider {
        didSet { defaults.set(cleanupProvider.rawValue, forKey: Key.cleanupProvider) }
    }
    @Published var openAIConnection: CleanupConnection {
        didSet { defaults.set(openAIConnection.rawValue, forKey: Key.openAIConnection) }
    }
    @Published var chatGPTWelcomeShown: Bool {
        didSet { defaults.set(chatGPTWelcomeShown, forKey: Key.chatGPTWelcomeShown) }
    }
    @Published var snippets: [Snippet] {
        didSet { defaults.set(try? JSONEncoder().encode(snippets), forKey: Key.snippets) }
    }
    /// A `NotesModel.id`; empty follows the AI Cleanup provider.
    @Published var notesModel: String { didSet { defaults.set(notesModel, forKey: Key.notesModel) } }
    @Published var detectCalls: Bool { didSet { defaults.set(detectCalls, forKey: Key.detectCalls) } }
    @Published var stopWhenCallEnds: Bool { didSet { defaults.set(stopWhenCallEnds, forKey: Key.stopWhenCallEnds) } }
    @Published var maxMeetingHours: Int { didSet { defaults.set(maxMeetingHours, forKey: Key.maxMeetingHours) } }
    /// Off keeps notes on-device.
    @Published var notesUseAI: Bool { didSet { defaults.set(notesUseAI, forKey: Key.notesUseAI) } }
    @Published var meetingSystemAudio: Bool {
        didSet { defaults.set(meetingSystemAudio, forKey: Key.meetingSystemAudio) }
    }
    /// Labels the other people on a call "Speaker 1", "Speaker 2"… instead of one "Others".
    @Published var separateVoices: Bool { didSet { defaults.set(separateVoices, forKey: Key.separateVoices) } }
    @Published private(set) var launchAtLoginError: String?

    @Published var launchAtLogin: Bool {
        didSet {
            #if DEBUG
            guard !DesignReview.enabled else { return }
            #endif
            guard !isRollingBackLaunchAtLogin else { return }
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                refreshLaunchAtLogin()
            } catch {
                launchAtLoginError = error.localizedDescription
                isRollingBackLaunchAtLogin = true
                launchAtLogin = oldValue
                isRollingBackLaunchAtLogin = false
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notesModel = defaults.string(forKey: Key.notesModel) ?? ""
        snippets = defaults.data(forKey: Key.snippets).flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        detectCalls = defaults.object(forKey: Key.detectCalls) as? Bool ?? true
        stopWhenCallEnds = defaults.object(forKey: Key.stopWhenCallEnds) as? Bool ?? true
        maxMeetingHours = defaults.object(forKey: Key.maxMeetingHours) as? Int ?? 3
        notesUseAI = defaults.object(forKey: Key.notesUseAI) as? Bool ?? true
        meetingSystemAudio = defaults.object(forKey: Key.meetingSystemAudio) as? Bool ?? true
        separateVoices = defaults.object(forKey: Key.separateVoices) as? Bool ?? true
        holdKey = Self.readHoldKey(
            defaults, codeKey: Key.holdKeyCode, legacyKey: Key.holdKey, fallback: .rightOption
        )
        let model = Self.readASRModel(defaults)
        asrModel = model
        let meetingModel = defaults.string(forKey: Key.meetingASRModel).flatMap(ASRModel.init(rawValue:)) ?? .defaultMeeting
        meetingASRModel = meetingModel
        let storedMeetingLanguage = defaults.string(forKey: Key.meetingLanguage).flatMap(TranscriptionLanguage.init(rawValue:)) ?? .auto
        meetingLanguage = meetingModel.supportedLanguages.contains(storedMeetingLanguage) ? storedMeetingLanguage : .auto
        let storedLanguage =
            TranscriptionLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .auto
        language = model.supportedLanguages.contains(storedLanguage)
            ? storedLanguage
            : model.defaultLanguage
        for key in Key.retired { defaults.removeObject(forKey: key) }
        let storedVocabulary = defaults.string(forKey: Key.vocabulary)
        if defaults.bool(forKey: Key.manualVocabularyOnly) {
            vocabularySource = storedVocabulary ?? ""
        } else {
            let manualVocabulary = VocabularyMigration.manualSource(from: storedVocabulary)
            vocabularySource = manualVocabulary
            defaults.set(manualVocabulary, forKey: Key.vocabulary)
            defaults.set(true, forKey: Key.manualVocabularyOnly)
        }
        onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)
        hasUsedDictation = defaults.bool(forKey: Key.hasUsedDictation)
        inputDeviceUID = defaults.string(forKey: Key.inputDevice)
        claudeCleanup = defaults.object(forKey: Key.claudeCleanup) as? Bool ?? true
        claudeConnection = CleanupConnection(rawValue: defaults.string(forKey: Key.claudeConnection) ?? "") ?? .apiKey
        cleanupProvider = CleanupProvider(rawValue: defaults.string(forKey: Key.cleanupProvider) ?? "") ?? .claude
        openAIConnection = CleanupConnection(rawValue: defaults.string(forKey: Key.openAIConnection) ?? "") ?? .subscription
        chatGPTWelcomeShown = defaults.bool(forKey: Key.chatGPTWelcomeShown)
        let serviceStatus = SMAppService.mainApp.status
        launchAtLogin = Self.launchAtLoginIsOn(serviceStatus)
        launchAtLoginError = Self.launchAtLoginMessage(for: serviceStatus)
    }

    /// requiresApproval counts as on: registration succeeded, so the toggle must not bounce back to off.
    private static func launchAtLoginIsOn(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        let enabled = Self.launchAtLoginIsOn(status)
        if enabled != launchAtLogin {
            isRollingBackLaunchAtLogin = true
            launchAtLogin = enabled
            isRollingBackLaunchAtLogin = false
        }
        let message = Self.launchAtLoginMessage(for: status)
        if launchAtLoginError != message { launchAtLoginError = message }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func launchAtLoginMessage(for status: SMAppService.Status) -> String? {
        switch status {
        case .enabled, .notRegistered:
            nil
        case .requiresApproval:
            "Approve Pressay under Login Items to finish enabling launch at login."
        case .notFound:
            // Can be transient while LaunchServices registers a freshly replaced build;
            // only an explicit enable that throws surfaces an error.
            nil
        @unknown default:
            "macOS could not determine the launch-at-login status."
        }
    }

    /// Self-validating parse cache: read several times per dictation; the source changes only on user edits.
    private var parsedVocabulary: (source: String, entries: [VocabularyParser.Entry])?

    var vocabularyEntries: [VocabularyParser.Entry] {
        if parsedVocabulary?.source != vocabularySource {
            parsedVocabulary = (vocabularySource, VocabularyParser.parse(vocabularySource))
        }
        return parsedVocabulary!.entries
    }

    var vocabularyTerms: [String] {
        vocabularyEntries.map(\.preferred)
    }

    func addVocabularyWord(_ preferred: String, aliases: [String] = []) {
        var line = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if !aliases.isEmpty { line += " <= " + aliases.joined(separator: ", ") }
        let source = vocabularySource.trimmingCharacters(in: .whitespacesAndNewlines)
        vocabularySource = source.isEmpty ? line : source + "\n" + line
    }

    private static func readASRModel(_ defaults: UserDefaults) -> ASRModel {
        .migrating(storedRawValue: defaults.string(forKey: Key.asrModel))
    }

    /// Reads a key-code-backed hold key, migrating the legacy enum raw-value
    /// string ("Right Option"/"Left Option") the first release persisted.
    private static func readHoldKey(
        _ defaults: UserDefaults,
        codeKey: String,
        legacyKey: String?,
        fallback: HoldKey
    ) -> HoldKey {
        if defaults.object(forKey: codeKey) != nil {
            let code = Int64(defaults.integer(forKey: codeKey))
            if HoldKey.isBindable(keyCode: code) { return HoldKey(keyCode: code) }
        }
        if let legacyKey,
           let legacy = HoldKey(legacyRawValue: defaults.string(forKey: legacyKey) ?? "") {
            return legacy
        }
        return fallback
    }
}

enum CleanupProvider: String, CaseIterable, Identifiable {
    case claude
    case chatgpt

    var id: Self { self }
    var title: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "OpenAI"
        }
    }

    var subtitle: String {
        switch self {
        case .claude: "Connect Claude Code or an Anthropic API key."
        case .chatgpt: "Connect an eligible ChatGPT plan or an OpenAI API key."
        }
    }
}

enum CleanupConnection: String, CaseIterable, Identifiable {
    case subscription
    case apiKey

    var id: Self { self }
    var title: String { self == .subscription ? "Subscription" : "API key" }
}
