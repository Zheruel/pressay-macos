import Foundation

/// Modifiers are tracked via flagsChanged, other keys via keyDown/keyUp.
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

    /// Escape cancels dictation; Caps Lock toggles instead of holding.
    public static func isBindable(keyCode: Int64) -> Bool {
        keyCode != escapeKeyCode && keyCode != capsLockKeyCode
    }

    /// Legacy persisted enum values.
    public init?(legacyRawValue: String) {
        switch legacyRawValue {
        case "Right Option": self = .rightOption
        case "Left Option": self = .leftOption
        default: return nil
        }
    }

    /// CGEventFlags raw value; raw keeps Core free of a CoreGraphics dependency.
    public var modifierFlagMask: UInt64? { Self.modifierFamilies[keyCode]?.family }

    /// NX_DEVICE…KEYMASK left/right bit.
    public var deviceFlagMask: UInt64? { Self.modifierFamilies[keyCode]?.device }

    /// Detects whether an event carries device-specific bits at all.
    public var familyDeviceBits: UInt64? { Self.modifierFamilies[keyCode]?.familyDevices }

    public var isModifier: Bool { modifierFlagMask != nil }

    public var displayName: String { Self.keyNames[keyCode] ?? "Key \(keyCode)" }

    /// Prefers the left/right device bit so the paired key can't mask a release; synthetic
    /// events without device bits fall back to the family flag. Shared by the event tap and key-capture UI.
    public func isDownAsModifier(inFlags rawFlags: UInt64) -> Bool {
        guard let family = modifierFlagMask else { return false }
        guard rawFlags & family != 0 else { return false }
        guard let device = deviceFlagMask,
              let familyBits = familyDeviceBits,
              rawFlags & familyBits != 0 else { return true }
        return rawFlags & device != 0
    }

    /// familyDevices is precomputed because the lookup runs inside the CGEvent tap callback.
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

/// Declaration order is the Settings picker order, best first (see docs/benchmarks.md).
public enum ASRModel: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Default: judged 9.0/10, level with Wispr Flow's cloud transcript.
    case qwen3ASR17 = "qwen3ASR17"
    /// 8.9/10, best punctuation, at ~2.4x Qwen's latency.
    case voxtralMini = "voxtralMini"
    case whisperTurboGGML = "whisperTurboGGML"
    case qwen3ASR06 = "qwen3ASR06"
    /// English lock and ITN are load-bearing; see `supportedLanguages`, `requestsExplicitFormatting`.
    case funASRMLTNano = "funASRMLTNano"

    public var id: String { rawValue }

    /// Retired or unknown raw values fall back to the default.
    public static func migrating(storedRawValue: String?) -> ASRModel {
        guard let stored = storedRawValue,
              let model = ASRModel(rawValue: stored) else { return .qwen3ASR17 }
        return model
    }

    public var displayName: String {
        switch self {
        case .funASRMLTNano: "Fun-ASR MLT Nano"
        case .whisperTurboGGML: "Whisper V3 Turbo"
        case .voxtralMini: "Voxtral Mini 3B"
        case .qwen3ASR17: "Qwen3-ASR 1.7B"
        case .qwen3ASR06: "Qwen3-ASR 0.6B"
        }
    }

    public var caption: String {
        switch self {
        case .qwen3ASR17: "Most accurate. English only. Uses 3 GB of memory."
        case .voxtralMini: "Nearly as accurate, but slower. 8 languages. Uses 5 GB of memory."
        case .whisperTurboGGML: "Good accuracy. 100 languages. Uses 1 GB of memory."
        case .qwen3ASR06: "Faster, but less accurate. English only."
        case .funASRMLTNano: "Fastest and least accurate. English only."
        }
    }

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
        case .qwen3ASR17:
            (URL(string: "https://huggingface.co/handy-computer/Qwen3-ASR-1.7B-gguf/resolve/main/Qwen3-ASR-1.7B-Q6_K.gguf")!,
             "Qwen3-ASR-1.7B-Q6_K.gguf")
        case .qwen3ASR06:
            (URL(string: "https://huggingface.co/handy-computer/Qwen3-ASR-0.6B-gguf/resolve/main/Qwen3-ASR-0.6B-Q8_0.gguf")!,
             "Qwen3-ASR-0.6B-Q8_0.gguf")
        }
    }

    /// What each engine was measured to do safely, not everything it advertises:
    /// Fun-ASR on auto-detect invented Korean/Spanish sentences for near-silent clips.
    public var supportedLanguages: [TranscriptionLanguage] {
        switch self {
        // Qwen takes no hint; English-only keeps the non-Latin hallucination filter armed.
        case .funASRMLTNano, .qwen3ASR17, .qwen3ASR06: [.english]
        case .whisperTurboGGML: TranscriptionLanguage.allCases
        // Auto is Voxtral's default: forcing a language made it fabricate text for near-silent audio.
        case .voxtralMini:
            [.auto, .english, .french, .german, .spanish, .italian,
             .portuguese, .dutch, .hindi]
        }
    }

    /// Used when the current selection isn't in `supportedLanguages`.
    public var defaultLanguage: TranscriptionLanguage {
        switch self {
        case .funASRMLTNano, .qwen3ASR17, .qwen3ASR06: .english
        case .whisperTurboGGML, .voxtralMini: .auto
        }
    }

    /// Measured: 60 s splits cut Voxtral worst case 13.3 s → 7.7 s; below ~40 s overhead wins. Whisper chunks internally.
    public var preferredChunkSeconds: TimeInterval? {
        switch self {
        case .funASRMLTNano, .voxtralMini, .qwen3ASR17, .qwen3ASR06: 60
        case .whisperTurboGGML: nil
        }
    }

    public var offersLanguageChoice: Bool { supportedLanguages.count > 1 }

    public var languageCaption: String {
        switch self {
        case .funASRMLTNano, .qwen3ASR17, .qwen3ASR06: "English (this model takes no language hint)"
        case .whisperTurboGGML: "Automatic handles mixed Norwegian and English"
        case .voxtralMini: "Automatic is safest on short clips for this model"
        }
    }

    public var supportsLanguageHint: Bool {
        switch self {
        case .funASRMLTNano, .whisperTurboGGML, .voxtralMini: true
        case .qwen3ASR17, .qwen3ASR06: false
        }
    }

    /// Fun-ASR ships PnC/ITN off; ITN on cut collapsed long clips 8/46 → 0/46.
    /// Off elsewhere so calibrated engines are never silently re-tuned.
    public var requestsExplicitFormatting: Bool {
        switch self {
        case .funASRMLTNano: true
        case .whisperTurboGGML, .voxtralMini, .qwen3ASR17, .qwen3ASR06: false
        }
    }

    /// If so, foreign-script output cannot be a real transcript.
    var expectsLatinScriptOnly: Bool {
        supportedLanguages.allSatisfy(\.usesLatinScript)
    }

    /// Whisper excluded: it never refuses, so the filter would drop a real "I'm sorry, I didn't understand."
    var emitsAssistantRefusals: Bool {
        switch self {
        case .funASRMLTNano, .voxtralMini, .qwen3ASR17, .qwen3ASR06: true
        case .whisperTurboGGML: false
        }
    }

    /// Only short output is judged, so a real dictation that merely *starts* with an apology survives.
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

    /// Ignores punctuation and digits so "아, 그거는." still reads as non-Latin.
    static func isPredominantlyNonLatin(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let nonLatin = letters.filter { $0.value > 0x02FF }.count
        return nonLatin * 2 > letters.count
    }
}

/// Fixed cases force a language token, skipping detection that can misfire on short clips.
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

    /// `auto` is false: an auto-detecting engine may legitimately return any script.
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
    /// Mic opening, no audio yet; a cold Bluetooth headset spends 500 ms+ here.
    case arming
    case recording
    case processing
    case succeeded
    case failed(String)
}

public struct DictationStateMachine: Sendable {
    public private(set) var phase: DictationPhase = .idle

    public init() {}

    @discardableResult
    public mutating func arm() -> Bool {
        guard phase == .idle else { return false }
        phase = .arming
        return true
    }

    /// Also accepted from `.idle` so callers that never arm keep working.
    @discardableResult
    public mutating func begin() -> Bool {
        guard phase == .idle || phase == .arming else { return false }
        phase = .recording
        return true
    }

    /// Accepts `.arming`: releasing before the mic opens must not strand the session.
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

    /// The coordinator's pre-check and AudioTrimmer's guard must agree on this.
    public static let minimumClipDuration: TimeInterval = 0.25

    /// 45 s clears the 35 s median of 548 real inter-dictation gaps and sits on the coverage knee.
    public static let micWarmWindow: TimeInterval = 45

    public static let preRollDuration: TimeInterval = 0.5

    /// A hang guard, not a latency target: 10x+ the worst Qwen3-ASR time seen (2.5 s over 111 dictations).
    public static func asrTimeout(duration: TimeInterval) -> TimeInterval {
        min(180, max(20, 10 + duration * 0.5))
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
        case .timedOut: "Local transcription stalled. Try again."
        }
    }
}
