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
        static let structuredDictation = "structuredDictation"
        static let vocabulary = "vocabulary"
        static let onboardingComplete = "onboardingComplete"
        static let hasUsedDictation = "hasUsedDictation"
        static let keepMicWarm = "keepMicWarm"
        static let inputDevice = "inputDeviceUID"
        static let claudeCleanup = "claudeCleanup"
        static let claudeCleanupModel = "claudeCleanupModel"
        static let cleanupProvider = "cleanupProvider"
        static let chatGPTModel = "chatGPTModel"
        static let chatGPTWelcomeShown = "chatGPTWelcomeShown"
        static let learnFromEdits = "learnFromEdits"
        static let notesModel = "notesModel"
        static let detectCalls = "detectCalls"
        static let stopWhenCallEnds = "stopWhenCallEnds"
        static let openNotepad = "openNotepad"
        static let showLiveTranscript = "showLiveTranscript"
        static let maxMeetingHours = "maxMeetingHours"
        static let notesUseAI = "notesUseAI"
        static let meetingSystemAudio = "meetingSystemAudio"
        /// Legacy keys from removed Vibe Mode; cleared once at init.
        static let retired = ["polishHoldKeyCode", "polishModel", "noteStyle"]
    }

    private let defaults: UserDefaults
    private var isRollingBackLaunchAtLogin = false

    @Published var holdKey: HoldKey { didSet { defaults.set(holdKey.keyCode, forKey: Key.holdKeyCode) } }
    @Published var language: TranscriptionLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    @Published var asrModel: ASRModel { didSet { defaults.set(asrModel.rawValue, forKey: Key.asrModel) } }
    @Published var structuredDictation: Bool { didSet { defaults.set(structuredDictation, forKey: Key.structuredDictation) } }
    @Published var vocabularySource: String { didSet { defaults.set(vocabularySource, forKey: Key.vocabulary) } }
    @Published var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) } }
    @Published var hasUsedDictation: Bool { didSet { defaults.set(hasUsedDictation, forKey: Key.hasUsedDictation) } }
    @Published var keepMicWarm: Bool { didSet { defaults.set(keepMicWarm, forKey: Key.keepMicWarm) } }
    /// CoreAudio UID of the dictation input, or nil to follow the system default.
    @Published var inputDeviceUID: String? { didSet { defaults.set(inputDeviceUID, forKey: Key.inputDevice) } }
    /// On by default so saving a key is the single opt-in step.
    @Published var claudeCleanup: Bool { didSet { defaults.set(claudeCleanup, forKey: Key.claudeCleanup) } }
    @Published var claudeCleanupModel: ClaudeCleanupModel {
        didSet { defaults.set(claudeCleanupModel.rawValue, forKey: Key.claudeCleanupModel) }
    }
    @Published var cleanupProvider: CleanupProvider {
        didSet { defaults.set(cleanupProvider.rawValue, forKey: Key.cleanupProvider) }
    }
    @Published var chatGPTModel: String { didSet { defaults.set(chatGPTModel, forKey: Key.chatGPTModel) } }
    @Published var chatGPTWelcomeShown: Bool {
        didSet { defaults.set(chatGPTWelcomeShown, forKey: Key.chatGPTWelcomeShown) }
    }
    @Published var learnFromEdits: Bool { didSet { defaults.set(learnFromEdits, forKey: Key.learnFromEdits) } }
    /// A `NotesModel.id`; empty follows the AI Cleanup provider.
    @Published var notesModel: String { didSet { defaults.set(notesModel, forKey: Key.notesModel) } }
    @Published var detectCalls: Bool { didSet { defaults.set(detectCalls, forKey: Key.detectCalls) } }
    @Published var stopWhenCallEnds: Bool { didSet { defaults.set(stopWhenCallEnds, forKey: Key.stopWhenCallEnds) } }
    @Published var openNotepad: Bool { didSet { defaults.set(openNotepad, forKey: Key.openNotepad) } }
    @Published var showLiveTranscript: Bool { didSet { defaults.set(showLiveTranscript, forKey: Key.showLiveTranscript) } }
    @Published var maxMeetingHours: Int { didSet { defaults.set(maxMeetingHours, forKey: Key.maxMeetingHours) } }
    /// Off keeps notes on-device.
    @Published var notesUseAI: Bool { didSet { defaults.set(notesUseAI, forKey: Key.notesUseAI) } }
    @Published var meetingSystemAudio: Bool {
        didSet { defaults.set(meetingSystemAudio, forKey: Key.meetingSystemAudio) }
    }
    @Published private(set) var launchAtLoginError: String?

    /// Tuner-derived rules, merged into every cleanup pass with the curated entries.
    let learnedVocabulary: LearnedVocabularyStore
    let vocabularySuggestions: VocabularySuggestionStore
    @Published var launchAtLogin: Bool {
        didSet {
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
        learnedVocabulary = LearnedVocabularyStore(defaults: defaults)
        vocabularySuggestions = VocabularySuggestionStore(defaults: defaults)
        learnFromEdits = defaults.object(forKey: Key.learnFromEdits) as? Bool ?? true
        notesModel = defaults.string(forKey: Key.notesModel) ?? ""
        detectCalls = defaults.object(forKey: Key.detectCalls) as? Bool ?? true
        stopWhenCallEnds = defaults.object(forKey: Key.stopWhenCallEnds) as? Bool ?? true
        openNotepad = defaults.object(forKey: Key.openNotepad) as? Bool ?? true
        showLiveTranscript = defaults.object(forKey: Key.showLiveTranscript) as? Bool ?? true
        maxMeetingHours = defaults.object(forKey: Key.maxMeetingHours) as? Int ?? 3
        notesUseAI = defaults.object(forKey: Key.notesUseAI) as? Bool ?? true
        meetingSystemAudio = defaults.object(forKey: Key.meetingSystemAudio) as? Bool ?? true
        holdKey = Self.readHoldKey(
            defaults, codeKey: Key.holdKeyCode, legacyKey: Key.holdKey, fallback: .rightOption
        )
        let model = Self.readASRModel(defaults)
        asrModel = model
        // A language stored against a previous model may not exist on this one
        // (Fun-ASR runs English only; Voxtral covers eight languages).
        let storedLanguage =
            TranscriptionLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .auto
        language = model.supportedLanguages.contains(storedLanguage)
            ? storedLanguage
            : model.defaultLanguage
        // Default on: corpus-validated as word-preserving, and it only ever
        // activates on longer dictations (15+ words, never terminals).
        structuredDictation = defaults.object(forKey: Key.structuredDictation) as? Bool ?? true
        for key in Key.retired { defaults.removeObject(forKey: key) }
        let storedVocabulary = defaults.string(forKey: Key.vocabulary)
        if let storedVocabulary, CuratedVocabulary.replaceableDefaults.contains(storedVocabulary) {
            vocabularySource = CuratedVocabulary.source
            defaults.set(CuratedVocabulary.source, forKey: Key.vocabulary)
        } else {
            vocabularySource = storedVocabulary ?? CuratedVocabulary.source
        }
        onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)
        hasUsedDictation = defaults.bool(forKey: Key.hasUsedDictation)
        // Default on: it removes the cold-start clipping that the window exists
        // to fix, and it only holds the stream between back-to-back dictations.
        keepMicWarm = defaults.object(forKey: Key.keepMicWarm) as? Bool ?? true
        inputDeviceUID = defaults.string(forKey: Key.inputDevice)
        claudeCleanup = defaults.object(forKey: Key.claudeCleanup) as? Bool ?? true
        claudeCleanupModel = ClaudeCleanupModel(
            rawValue: defaults.string(forKey: Key.claudeCleanupModel) ?? ""
        ) ?? .default
        cleanupProvider = CleanupProvider(rawValue: defaults.string(forKey: Key.cleanupProvider) ?? "") ?? .claude
        chatGPTModel = defaults.string(forKey: Key.chatGPTModel) ?? ChatGPTCleanupModel.defaultSlug
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
        launchAtLoginError = Self.launchAtLoginMessage(for: status)
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
        return parsedVocabulary!.entries + learnedVocabulary.entries
    }

    var vocabularyTerms: [String] {
        vocabularyEntries.map(\.preferred)
    }

    /// Every dictionary term and covered heard spelling, lowercased.
    var knownVocabularyFolds: Set<String> {
        Set(vocabularyEntries.flatMap { [$0.preferred] + $0.aliases }.map { $0.lowercased() })
    }

    func addVocabularyWord(_ preferred: String, aliases: [String] = []) {
        var line = preferred
        if !aliases.isEmpty { line += " <= " + aliases.joined(separator: ", ") }
        var source = vocabularySource.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.contains("# Custom") { source += "\n\n# Custom" }
        source += "\n" + line
        vocabularySource = source
    }

    /// An alias becomes a learned rule (lifting any earlier removal); a new word joins the list.
    func accept(_ suggestion: VocabularySuggestion) {
        if let heard = suggestion.heard {
            learnedVocabulary.unblock(heard)
            learnedVocabulary.mergeRules(
                [LearnedRule(heard: heard, preferred: suggestion.preferred, count: suggestion.count, source: .suggestion)],
                source: .suggestion
            )
        } else {
            addVocabularyWord(suggestion.preferred)
        }
        vocabularySuggestions.remove(suggestion)
    }

    func restoreCuratedVocabulary() {
        vocabularySource = CuratedVocabulary.source
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

/// Claude with the user's API key, or OpenAI billed to the user's ChatGPT plan.
enum CleanupProvider: String, CaseIterable, Identifiable {
    case claude
    case chatgpt

    var id: Self { self }
    var title: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        }
    }

    var subtitle: String {
        switch self {
        case .claude: "Your Anthropic API key. Fastest."
        case .chatgpt: "Your Plus or Pro plan, at no extra cost."
        }
    }
}
