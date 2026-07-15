import Foundation
import LocalFlowCore
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let holdKey = "holdKey"
        static let vocabulary = "vocabulary"
        static let onboardingComplete = "onboardingComplete"
        static let hasUsedDictation = "hasUsedDictation"
    }

    private let defaults: UserDefaults
    private var isRollingBackLaunchAtLogin = false

    @Published var holdKey: HoldKey { didSet { defaults.set(holdKey.rawValue, forKey: Key.holdKey) } }
    @Published var vocabularySource: String { didSet { defaults.set(vocabularySource, forKey: Key.vocabulary) } }
    @Published var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) } }
    @Published var hasUsedDictation: Bool { didSet { defaults.set(hasUsedDictation, forKey: Key.hasUsedDictation) } }
    @Published private(set) var launchAtLoginError: String?
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
        holdKey = HoldKey(rawValue: defaults.string(forKey: Key.holdKey) ?? "") ?? .rightOption
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
        launchAtLogin = serviceStatus == .enabled
        launchAtLoginError = Self.launchAtLoginMessage(for: serviceStatus)
    }

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        let enabled = status == .enabled
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

    var vocabularyEntries: [VocabularyParser.Entry] {
        VocabularyParser.parse(vocabularySource)
    }

    var vocabularyTerms: [String] {
        vocabularyEntries.map(\.preferred)
    }

    func restoreCuratedVocabulary() {
        vocabularySource = CuratedVocabulary.source
    }
}
