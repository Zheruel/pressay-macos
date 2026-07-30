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
        /// Vibe Mode (removed) persisted these; cleared once at init.
        static let retired = ["polishHoldKeyCode", "polishModel"]
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
    @Published private(set) var launchAtLoginError: String?

    /// Rules the vocabulary tuner derived from transcripts; merged into every
    /// cleanup pass alongside the curated entries.
    let learnedVocabulary: LearnedVocabularyStore
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
        let serviceStatus = SMAppService.mainApp.status
        launchAtLogin = Self.launchAtLoginIsOn(serviceStatus)
        launchAtLoginError = Self.launchAtLoginMessage(for: serviceStatus)
    }

    /// requiresApproval counts as on: registration succeeded and the pending
    /// approval is explained by launchAtLoginError, so the toggle must not
    /// bounce back to off.
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
            // This can be transient while LaunchServices registers a freshly
            // replaced build. Surface a real registration error only if the
            // user actually enables the toggle and registration throws.
            nil
        @unknown default:
            "macOS could not determine the launch-at-login status."
        }
    }

    /// Self-validating parse cache: accessed several times per dictation and
    /// per settings render, while the source changes only on user edits.
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
