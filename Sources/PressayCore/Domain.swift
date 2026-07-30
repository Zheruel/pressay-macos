import Foundation

/// A single physical key used for push-to-talk. Any key can be bound:
/// modifier keys are tracked through flagsChanged events, every other key
/// through keyDown/keyUp.
public struct HoldKey: Codable, Sendable, Hashable, Identifiable {
    public let keyCode: Int64

    public init(keyCode: Int64) {
        self.keyCode = keyCode
    }

    public var id: Int64 { keyCode }

    public static let rightOption = HoldKey(keyCode: 61)
    public static let leftOption = HoldKey(keyCode: 58)
    public static let rightCommand = HoldKey(keyCode: 54)

    public static let escapeKeyCode: Int64 = 53
    public static let capsLockKeyCode: Int64 = 57

    /// Keys that can never be a hold key: Escape cancels dictation and ends
    /// capture, and Caps Lock toggles instead of holding.
    public static func isBindable(keyCode: Int64) -> Bool {
        keyCode != escapeKeyCode && keyCode != capsLockKeyCode
    }

    /// Legacy persisted values from when HoldKey was a two-case enum.
    public init?(legacyRawValue: String) {
        switch legacyRawValue {
        case "Right Option": self = .rightOption
        case "Left Option": self = .leftOption
        default: return nil
        }
    }

    /// CGEventFlags family bit (maskCommand, maskAlternate, …) when this is a
    /// modifier key; nil for regular keys. Raw values keep Core free of a
    /// CoreGraphics dependency.
    public var modifierFlagMask: UInt64? { Self.modifierFamilies[keyCode]?.family }

    /// Device-specific left/right bit (NX_DEVICE…KEYMASK) telling the two keys
    /// of a modifier family apart in an aggregate flags word.
    public var deviceFlagMask: UInt64? { Self.modifierFamilies[keyCode]?.device }

    /// Both device bits of this key's modifier family, used to detect whether
    /// an event carries device-specific bits at all.
    public var familyDeviceBits: UInt64? { Self.modifierFamilies[keyCode]?.familyDevices }

    public var isModifier: Bool { modifierFlagMask != nil }

    public var displayName: String { Self.keyNames[keyCode] ?? "Key \(keyCode)" }

    /// Whether this modifier key is held, given an event's raw flags word.
    /// Uses the left/right-specific flag bit when present so the paired key of
    /// the same family cannot mask this one's release; synthetic events that
    /// carry no device bits fall back to the aggregate family flag. Shared by
    /// the event-tap monitor and the key-capture UI so their press semantics
    /// cannot diverge.
    public func isDownAsModifier(inFlags rawFlags: UInt64) -> Bool {
        guard let family = modifierFlagMask else { return false }
        guard rawFlags & family != 0 else { return false }
        guard let device = deviceFlagMask,
              let familyBits = familyDeviceBits,
              rawFlags & familyBits != 0 else { return true }
        return rawFlags & device != 0
    }

    /// keyCode → (aggregate family mask, device-specific bit, OR of the
    /// family's device bits). Family masks are CGEventFlags raw values; device
    /// bits are NX_DEVICE…KEYMASK. familyDevices is precomputed because the
    /// lookup runs inside the CGEvent tap callback.
    private static let modifierFamilies: [Int64: (family: UInt64, device: UInt64?, familyDevices: UInt64?)] = [
        55: (0x100000, 0x08, 0x18),    // Left Command
        54: (0x100000, 0x10, 0x18),    // Right Command
        58: (0x80000, 0x20, 0x60),     // Left Option
        61: (0x80000, 0x40, 0x60),     // Right Option
        56: (0x20000, 0x02, 0x06),     // Left Shift
        60: (0x20000, 0x04, 0x06),     // Right Shift
        59: (0x40000, 0x01, 0x2001),   // Left Control
        62: (0x40000, 0x2000, 0x2001), // Right Control
        63: (0x800000, nil, nil),      // Fn/Globe
    ]

    private static let keyNames: [Int64: String] = [
        54: "Right Command", 55: "Left Command",
        58: "Left Option", 61: "Right Option",
        56: "Left Shift", 60: "Right Shift",
        59: "Left Control", 62: "Right Control",
        63: "Fn/Globe",
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 51: "Delete",
        117: "Forward Delete", 114: "Help", 115: "Home", 119: "End",
        116: "Page Up", 121: "Page Down",
        123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
        35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
        13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
        50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\",
        41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
    ]
}

/// The local speech-to-text model powering dictation. Defaults, captions, and
/// language coverage come from a thirteen-engine replay of the 184-clip
/// dictation corpus (see PressayBench + docs/benchmarks.md).
public enum ASRModel: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Fun-ASR MLT Nano 2512 (Q6_K) — the calibrated English default. On the
    /// corpus it beat Whisper V3 Turbo on every axis that matters here: it
    /// never collapsed a long dictation into an unpunctuated lowercase block
    /// (0/47 against Whisper's 3/47), capitalized more consistently, resolved
    /// more technical vocabulary, and ran 2.5x faster from a smaller artifact.
    /// It is English-locked with ITN on; both are load-bearing, see
    /// `supportedLanguages` and `requestsExplicitFormatting`.
    case funASRMLTNano = "funASRMLTNano"
    /// Whisper Large V3 Turbo — the multilingual option at 100 languages, and
    /// the only engine here that chunks long audio inside the runtime.
    case whisperTurboGGML = "whisperTurboGGML"
    /// Voxtral Mini 3B (Q4_K_M) — the quality-first option. It matches the
    /// default on technical vocabulary (81% against 86% is two term
    /// occurrences) and punctuates more densely than anything else that is
    /// also accurate, at roughly 8x the latency and 4x the size. Kept for
    /// people who would rather wait a second than re-type a product name.
    case voxtralMini = "voxtralMini"

    public var id: String { rawValue }

    /// The engine to use for a persisted setting written by an older build.
    /// Retired engines map to their closest surviving replacement; anything
    /// unrecognized (or absent) falls back to the default.
    public static func migrating(storedRawValue: String?) -> ASRModel {
        // Retired raw values ("parakeetV3" from 1.3, "whisperKit" from 1.0)
        // carry no intent worth preserving, so they land on the default.
        guard let stored = storedRawValue,
              let model = ASRModel(rawValue: stored) else { return .funASRMLTNano }
        return model
    }

    public var displayName: String {
        switch self {
        case .funASRMLTNano: "Fun-ASR MLT Nano"
        case .whisperTurboGGML: "Whisper V3 Turbo"
        case .voxtralMini: "Voxtral Mini 3B"
        }
    }

    public var caption: String {
        switch self {
        case .funASRMLTNano: "English · fastest · recommended · ~0.7 GB download"
        case .whisperTurboGGML: "Multilingual · 100 languages · ~0.9 GB download"
        case .voxtralMini: "Highest quality · slower · ~3 GB download · ~5 GB memory"
        }
    }

    /// GGUF artifact for the transcribe.cpp engine.
    public var ggufDownload: (url: URL, fileName: String)? {
        switch self {
        case .funASRMLTNano:
            (URL(string: "https://huggingface.co/handy-computer/Fun-ASR-MLT-Nano-2512-gguf/resolve/main/Fun-ASR-MLT-Nano-2512-Q6_K.gguf")!,
             "Fun-ASR-MLT-Nano-2512-Q6_K.gguf")
        case .whisperTurboGGML:
            (URL(string: "https://huggingface.co/handy-computer/whisper-large-v3-turbo-gguf/resolve/main/whisper-large-v3-turbo-Q8_0.gguf")!,
             "whisper-large-v3-turbo-Q8_0.gguf")
        case .voxtralMini:
            (URL(string: "https://huggingface.co/handy-computer/Voxtral-Mini-3B-2507-gguf/resolve/main/Voxtral-Mini-3B-2507-Q4_K_M.gguf")!,
             "Voxtral-Mini-3B-2507-Q4_K_M.gguf")
        }
    }

    /// Languages offered in Settings for this engine. These describe what the
    /// engine was measured to do safely, not everything it advertises:
    /// Fun-ASR left on auto-detect invented whole sentences in Korean and
    /// Spanish for near-silent clips, and only the English lock removed that.
    public var supportedLanguages: [TranscriptionLanguage] {
        switch self {
        case .funASRMLTNano: [.english]
        case .whisperTurboGGML: TranscriptionLanguage.allCases
        // Voxtral advertises these eight, plus detection. Automatic is the
        // default because forcing a language made it fabricate a sentence for
        // near-silent audio during the 1.3 evaluation.
        case .voxtralMini:
            [.auto, .english, .french, .german, .spanish, .italian,
             .portuguese, .dutch, .hindi]
        }
    }

    /// Language to fall back to when the current selection is not in
    /// `supportedLanguages` — after a model switch, or a stale stored value.
    public var defaultLanguage: TranscriptionLanguage {
        switch self {
        case .funASRMLTNano: .english
        case .whisperTurboGGML, .voxtralMini: .auto
        }
    }

    /// Longest audio to hand this engine in one run, or nil to let it take
    /// whatever it accepts. The autoregressive engines generate a transcript
    /// token by token, so one long decode costs more than two shorter ones:
    /// splitting at 60 s cut the worst-case wait on the corpus from 3.7 s to
    /// 2.0 s for Fun-ASR and from 13.3 s to 7.7 s for Voxtral, with the
    /// transcripts 99.3% identical. Below ~40 s the per-call overhead wins
    /// again and it gets slower, so 60 s is the measured floor, not a guess.
    /// Whisper chunks internally and needs none of this.
    public var preferredChunkSeconds: TimeInterval? {
        switch self {
        case .funASRMLTNano, .voxtralMini: 60
        case .whisperTurboGGML: nil
        }
    }

    /// Whether Settings should let the user pick a language at all.
    public var offersLanguageChoice: Bool { supportedLanguages.count > 1 }

    /// Explains the language picker's state for the selected engine.
    public var languageCaption: String {
        switch self {
        case .funASRMLTNano: "This model runs English only"
        case .whisperTurboGGML: "Automatic handles mixed Norwegian and English"
        case .voxtralMini: "Automatic is safest on short clips for this model"
        }
    }

    /// Whether the engine honors a forced decoding language hint.
    public var supportsLanguageHint: Bool {
        switch self {
        case .funASRMLTNano, .whisperTurboGGML, .voxtralMini: true
        }
    }

    /// Whether to ask the engine for punctuation/capitalization and inverse
    /// text normalization explicitly. Fun-ASR ships both off and emits
    /// verbatim lowercase without them — turning ITN on is what moved it from
    /// 8/46 collapsed long clips to 0/46. Whisper and Voxtral expose no such
    /// runtime toggle, so they stay on the defaults their earlier calibration
    /// was measured against. (Requesting it for them is a proven no-op — the
    /// capability probe declines — but leaving it off keeps the invariant
    /// that a previously calibrated engine is never silently re-tuned.)
    public var requestsExplicitFormatting: Bool {
        switch self {
        case .funASRMLTNano: true
        case .whisperTurboGGML, .voxtralMini: false
        }
    }

    /// True when no language this engine can be set to uses a non-Latin
    /// script, so foreign-script output cannot be a real transcript.
    var expectsLatinScriptOnly: Bool {
        supportedLanguages.allSatisfy(\.usesLatinScript)
    }

    /// Whether this engine can answer unintelligible audio with an assistant
    /// reply instead of a transcript. Only the LLM-decoder engines do. Whisper
    /// is excluded deliberately: it never emits one, and applying the filter
    /// there would drop a real dictation of "I'm sorry, I didn't understand."
    var emitsAssistantRefusals: Bool {
        switch self {
        case .funASRMLTNano, .voxtralMini: true
        case .whisperTurboGGML: false
        }
    }

    /// Whether `text` is an artifact rather than dictated words: an
    /// instruct-tuned model's refusal on unintelligible audio, or a burst of
    /// another script that an engine invented for near-silent audio. Only
    /// short, self-contained output is judged, so a real dictation that merely
    /// *starts* with an apology is left untouched — and the script check is
    /// skipped for engines that can legitimately transcribe those scripts.
    public func isTranscriptionRefusal(_ text: String) -> Bool {
        guard text.count <= 64 else { return false }
        if emitsAssistantRefusals {
            let lower = text.lowercased()
            if lower.hasPrefix("i'm sorry, i didn't understand")
                || lower.hasPrefix("i'm sorry, i couldn't understand")
                || lower.hasPrefix("sorry, i didn't understand") {
                return true
            }
        }
        return expectsLatinScriptOnly && Self.isPredominantlyNonLatin(text)
    }

    /// Most letters fall outside the Latin scripts — Cyrillic, Han, Kana,
    /// Hangul, Arabic, Devanagari. Punctuation and digits are ignored so a
    /// short clip like "아, 그거는." still reads as non-Latin.
    static func isPredominantlyNonLatin(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let nonLatin = letters.filter { $0.value > 0x02FF }.count
        return nonLatin * 2 > letters.count
    }
}

/// Language configuration for Whisper decoding. `auto` lets the model detect
/// the language per audio window; the fixed cases force a language token,
/// which skips the detection pass and cannot misfire on short clips.
public enum TranscriptionLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto = "Automatic"
    case english = "English"
    case norwegian = "Norsk"
    case danish = "Dansk"
    case german = "Deutsch"
    case spanish = "Español"
    case french = "Français"
    case italian = "Italiano"
    case dutch = "Nederlands"
    case polish = "Polski"
    case portuguese = "Português"
    case swedish = "Svenska"
    case ukrainian = "Українська"
    case russian = "Русский"
    case arabic = "العربية"
    case hindi = "हिन्दी"
    case chinese = "中文"
    case japanese = "日本語"
    case korean = "한국어"

    public var id: String { rawValue }

    /// Value passed to WhisperTranscriber ("auto" enables detection).
    public var whisperCode: String {
        switch self {
        case .auto: "auto"
        case .english: "en"
        case .norwegian: "no"
        case .danish: "da"
        case .german: "de"
        case .spanish: "es"
        case .french: "fr"
        case .italian: "it"
        case .dutch: "nl"
        case .polish: "pl"
        case .portuguese: "pt"
        case .swedish: "sv"
        case .ukrainian: "uk"
        case .russian: "ru"
        case .arabic: "ar"
        case .hindi: "hi"
        case .chinese: "zh"
        case .japanese: "ja"
        case .korean: "ko"
        }
    }

    /// Whether transcripts in this language are written in a Latin script.
    /// `auto` is not: an auto-detecting engine may legitimately return any
    /// script, so foreign-script output cannot be treated as a hallucination.
    public var usesLatinScript: Bool {
        switch self {
        case .auto, .ukrainian, .russian, .arabic, .hindi,
             .chinese, .japanese, .korean:
            false
        case .english, .norwegian, .danish, .german, .spanish, .french,
             .italian, .dutch, .polish, .portuguese, .swedish:
            true
        }
    }
}

public enum DictationPhase: Equatable, Sendable {
    case idle
    /// Key is down and the mic is opening, but no audio is flowing yet. A cold
    /// Bluetooth headset spends 500 ms+ here; a warm one skips through it.
    case arming
    case recording
    case processing
    case succeeded
    case failed(String)
}

public struct DictationStateMachine: Sendable {
    public private(set) var phase: DictationPhase = .idle

    public init() {}

    /// Key went down. Capture is requested but not yet confirmed live.
    @discardableResult
    public mutating func arm() -> Bool {
        guard phase == .idle else { return false }
        phase = .arming
        return true
    }

    /// The mic delivered its first real audio. Also accepted straight from
    /// `.idle` so callers that never arm keep working.
    @discardableResult
    public mutating func begin() -> Bool {
        guard phase == .idle || phase == .arming else { return false }
        phase = .recording
        return true
    }

    /// Accepts `.arming` too: releasing the key before the mic opens must still
    /// hand off to processing rather than stranding the session.
    @discardableResult
    public mutating func stop() -> Bool {
        guard phase == .recording || phase == .arming else { return false }
        phase = .processing
        return true
    }

    public mutating func cancel() { phase = .idle }

    public mutating func succeed() {
        guard phase == .processing else { return }
        phase = .succeeded
    }

    public mutating func fail(_ message: String) { phase = .failed(message) }
    public mutating func reset() { phase = .idle }
}

public struct AudioClip: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let duration: TimeInterval

    public init(samples: [Float], sampleRate: Int = 16_000) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
    }
}

public enum DictationProcessingPolicy {
    public static let normalPipelineLimit: TimeInterval = 1.85

    /// Shortest capture worth transcribing; the coordinator's cheap pre-check
    /// and AudioTrimmer's guard must agree on this.
    public static let minimumClipDuration: TimeInterval = 0.25

    /// How long the mic stays open after a dictation.
    ///
    /// Tuned against 548 real gaps: the median is 35 s, and coverage runs
    /// 40% at 30 s → 49.5% at 45 s → 53.5% at 60 s. 45 s clears the median and
    /// sits on the knee — past it each extra second buys much less.
    public static let micWarmWindow: TimeInterval = 45

    /// Audio retained ahead of the key press while the mic is already warm, so
    /// speaking and pressing in the same motion keeps its word onset.
    public static let preRollDuration: TimeInterval = 0.5

    public static func asrTimeout(duration: TimeInterval) -> TimeInterval {
        guard duration >= 30 else { return normalPipelineLimit }
        return min(30, max(6, 2 + duration * 0.12))
    }
}

public struct ASRTranscript: Codable, Sendable {
    public let text: String
    public let processingTime: TimeInterval

    public init(
        text: String,
        processingTime: TimeInterval
    ) {
        self.text = text
        self.processingTime = processingTime
    }
}

public struct DictationContext: Codable, Sendable {
    public let targetBundleID: String?
    public let leadingText: String
    public let trailingText: String
    public let vocabulary: [String]

    public init(
        targetBundleID: String?,
        leadingText: String = "",
        trailingText: String = "",
        vocabulary: [String] = []
    ) {
        self.targetBundleID = targetBundleID
        self.leadingText = String(leadingText.suffix(500))
        self.trailingText = String(trailingText.prefix(500))
        self.vocabulary = vocabulary
    }
}

public enum PressayError: LocalizedError, Sendable {
    case microphoneUnavailable
    case audioConversionFailed
    case recordingTooShort
    case silence
    case modelUnavailable(String)
    case emptyTranscript
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: "No usable microphone is available."
        case .audioConversionFailed: "The microphone audio could not be prepared for transcription."
        case .recordingTooShort: "The hold was too short to contain speech."
        case .silence: "No speech was detected."
        case .modelUnavailable(let detail): "The local model is unavailable: \(detail)"
        case .emptyTranscript: "The model returned an empty transcript."
        case .timedOut: "Local processing exceeded the latency budget."
        }
    }
}
