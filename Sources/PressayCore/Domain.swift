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
    public var shortcutLabel: String {
        let glyph: String? = switch modifierFlagMask {
        case 0x80000: "⌥"
        case 0x100000: "⌘"
        case 0x20000: "⇧"
        case 0x40000: "⌃"
        default: nil
        }
        return glyph.map { $0 + " " + displayName } ?? displayName
    }

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

/// Local transcription choices. Recommendations are task-specific; see docs/benchmarks.md.
public enum ASRModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case orukeet
    case moss
    case parakeetUltra
    case qwen3ASR17 = "qwen3ASR17"
    case megaASR
    // Retained for existing users who need their language coverage.
    case voxtralMini = "voxtralMini"
    case whisperTurboGGML = "whisperTurboGGML"
    case qwen3ASR06 = "qwen3ASR06"
    /// ITN is enabled explicitly; see `requestsExplicitFormatting`.
    case funASRMLTNano = "funASRMLTNano"

    public var id: String { rawValue }

    public static let defaultDictation: ASRModel = .orukeet
    public static let defaultMeeting: ASRModel = .moss
    public static let recommended: [ASRModel] = [.orukeet, .moss, .parakeetUltra, .qwen3ASR17, .megaASR]
    public static let meetingRecommendations: [ASRModel] = [.moss, .orukeet, .parakeetUltra, .qwen3ASR17, .megaASR]
    public static var otherModels: [ASRModel] { allCases.filter { !recommended.contains($0) } }
    public var usesWorker: Bool { Self.recommended.contains(self) }

    /// Preserve explicit choices; fresh installs and retired values use the default.
    public static func migrating(storedRawValue: String?) -> ASRModel {
        guard let stored = storedRawValue,
              let model = ASRModel(rawValue: stored) else { return .defaultDictation }
        return model
    }

    public var displayName: String {
        switch self {
        case .orukeet: "Orukeet"
        case .moss: "MOSS"
        case .parakeetUltra: "Parakeet Ultra"
        case .megaASR: "Mega-ASR"
        case .funASRMLTNano: "Fun-ASR MLT Nano"
        case .whisperTurboGGML: "Whisper V3 Turbo"
        case .voxtralMini: "Voxtral Mini 3B"
        case .qwen3ASR17: "Qwen3-ASR 1.7B"
        case .qwen3ASR06: "Qwen3-ASR 0.6B"
        }
    }

    public var caption: String {
        switch self {
        case .orukeet: "Recommended for dictation. Strong accuracy with very fast local processing. 25 languages."
        case .moss: "Recommended for meetings. Best meeting accuracy in our tests; slower than Orukeet. 50+ languages."
        case .parakeetUltra: "Fast alternative with strong conversational accuracy. 25 languages."
        case .megaASR: "Alternative for difficult audio. Larger download and slower processing. Multilingual."
        case .qwen3ASR17: "Strong accuracy on clear speech and technical terms. 30 languages."
        case .voxtralMini: "Multilingual alternative. 8 languages. Uses about 5 GB of memory."
        case .whisperTurboGGML: "Multilingual alternative. 100 languages. Uses about 1 GB of memory."
        case .qwen3ASR06: "Smaller alternative. 30 languages."
        case .funASRMLTNano: "Multilingual alternative. 31 languages."
        }
    }

    public var ggufDownload: (url: URL, fileName: String)? {
        switch self {
        case .orukeet:
            (URL(string: "https://huggingface.co/oruk/orukeet/resolve/555136b50265a132d4cea0d35560c26fc4f657ab/orukeet-v0.1.0-q8.gguf")!, "orukeet-v0.1.0-q8.gguf")
        case .moss:
            (URL(string: "https://huggingface.co/handy-computer/MOSS-Transcribe-Diarize-gguf/resolve/8c603aa6da33a068e39bbd109786f85786a21834/MOSS-Transcribe-Diarize-Q6_K.gguf")!, "MOSS-Transcribe-Diarize-Q6_K.gguf")
        case .parakeetUltra:
            (URL(string: "https://huggingface.co/handy-computer/parakeet-ultra-gguf/resolve/a1539be1b849ea7463b88343e5277b373d0c4ea9/parakeet-ultra-Q8_0.gguf")!, "parakeet-ultra-Q8_0.gguf")
        case .megaASR: nil
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

    /// Fixed hints only where the installed engine accepts them. The Qwen GGUF
    /// runtime auto-detects all 30 languages but rejects caller-supplied hints.
    public var supportedLanguages: [TranscriptionLanguage] {
        guard supportsLanguageHint else { return [.auto] }
        return [.auto] + languageCodes.compactMap(TranscriptionLanguage.from(code:))
    }

    /// Advertised language coverage is distinct from fixed-language control.
    public var languageCodes: [String] {
        switch self {
        case .orukeet: ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk"]
        case .moss: []
        case .parakeetUltra: ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk"]
        case .qwen3ASR17: ["ar", "yue", "zh", "cs", "da", "nl", "en", "fil", "fi", "fr", "de", "el", "hi", "hu", "id", "it", "ja", "ko", "mk", "ms", "fa", "pl", "pt", "ro", "ru", "es", "sv", "th", "tr", "vi"]
        case .megaASR: []
        case .voxtralMini: ["nl", "en", "fr", "de", "hi", "it", "pt", "es"]
        case .whisperTurboGGML: ["af", "sq", "am", "ar", "hy", "as", "az", "ba", "eu", "be", "bn", "bs", "br", "bg", "yue", "ca", "zh", "hr", "cs", "da", "nl", "en", "et", "fo", "fi", "fr", "gl", "ka", "de", "el", "gu", "ht", "ha", "haw", "he", "hi", "hu", "is", "id", "it", "ja", "jw", "kn", "kk", "km", "ko", "lo", "la", "lv", "ln", "lt", "lb", "mk", "mg", "ms", "ml", "mt", "mi", "mr", "mn", "my", "ne", "no", "nn", "oc", "ps", "fa", "pl", "pt", "pa", "ro", "ru", "sa", "sr", "sn", "sd", "si", "sk", "sl", "so", "es", "su", "sw", "sv", "tl", "tg", "ta", "tt", "te", "th", "bo", "tr", "tk", "uk", "ur", "uz", "vi", "cy", "yi", "yo"]
        case .qwen3ASR06: ["ar", "yue", "zh", "cs", "da", "nl", "en", "fil", "fi", "fr", "de", "el", "hi", "hu", "id", "it", "ja", "ko", "mk", "ms", "fa", "pl", "pt", "ro", "ru", "es", "sv", "th", "tr", "vi"]
        case .funASRMLTNano: ["ar", "bg", "yue", "zh", "hr", "cs", "da", "nl", "en", "et", "fil", "fi", "el", "hi", "hu", "id", "ga", "ja", "ko", "lv", "lt", "ms", "mt", "pl", "pt", "ro", "sk", "sl", "sv", "th", "vi"]
        }
    }

    public var defaultLanguage: TranscriptionLanguage { .auto }

    /// Measured: 60 s splits cut Voxtral worst case 13.3 s → 7.7 s; below ~40 s overhead wins. Whisper chunks internally.
    public var preferredChunkSeconds: TimeInterval? {
        switch self {
        case .orukeet, .moss, .parakeetUltra, .megaASR: 25
        case .funASRMLTNano, .voxtralMini, .qwen3ASR17, .qwen3ASR06: 60
        case .whisperTurboGGML: nil
        }
    }

    public var offersLanguageChoice: Bool { supportedLanguages.count > 1 }

    public var languageCaption: String {
        let count = languageCodes.count
        let coverage = self == .moss ? "50+ languages" : self == .megaASR ? "Multilingual" : "\(count) languages"
        return coverage + (supportsLanguageHint ? " · automatic detection or a fixed language" : " · automatic detection")
    }

    public var supportsLanguageHint: Bool {
        switch self {
        case .funASRMLTNano, .whisperTurboGGML, .voxtralMini: true
        default: false
        }
    }

    /// Fun-ASR ships PnC/ITN off; ITN on cut collapsed long clips 8/46 → 0/46.
    /// Off elsewhere so calibrated engines are never silently re-tuned.
    public var requestsExplicitFormatting: Bool {
        switch self {
        case .funASRMLTNano: true
        case .orukeet, .moss, .parakeetUltra, .megaASR, .whisperTurboGGML, .voxtralMini, .qwen3ASR17, .qwen3ASR06: false
        }
    }

    /// If so, foreign-script output cannot be a real transcript.
    var expectsLatinScriptOnly: Bool {
        supportedLanguages.allSatisfy(\.usesLatinScript)
    }

    /// Whisper excluded: it never refuses, so the filter would drop a real "I'm sorry, I didn't understand."
    var emitsAssistantRefusals: Bool {
        switch self {
        case .moss, .megaASR, .funASRMLTNano, .voxtralMini, .qwen3ASR17, .qwen3ASR06: true
        case .orukeet, .parakeetUltra, .whisperTurboGGML: false
        }
    }

    public func plainTranscript(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // MOSS can emit diarization markers even when timestamps are disabled.
        guard self == .moss,
              text.range(of: #"^\[\d+(?:\.\d+)?\]"#, options: .regularExpression) != nil,
              text.range(of: #"\[\d+(?:\.\d+)?\]$"#, options: .regularExpression) != nil else { return text }
        return text.replacingOccurrences(of: #"\[(?:\d+(?:\.\d+)?|S\d{1,3})\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only short output is judged, so a real dictation that merely *starts* with an apology survives.
    public func isTranscriptionRefusal(_ text: String, language: String = "auto") -> Bool {
        guard text.count <= 64 else { return false }
        if emitsAssistantRefusals {
            let lower = text.lowercased()
            if lower.hasPrefix("i'm sorry, i didn't understand")
                || lower.hasPrefix("i'm sorry, i couldn't understand")
                || lower.hasPrefix("sorry, i didn't understand") {
                return true
            }
        }
        return language == "en" && Self.isPredominantlyNonLatin(text)
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
/// Persisted names remain compatible; engine codes cover the complete shipping model catalog.
public enum TranscriptionLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto = "Automatic"
    case afrikaans = "Afrikaans"
    case albanian = "Albanian"
    case amharic = "Amharic"
    case arabic = "العربية"
    case armenian = "Armenian"
    case assamese = "Assamese"
    case azerbaijani = "Azerbaijani"
    case bashkir = "Bashkir"
    case basque = "Basque"
    case belarusian = "Belarusian"
    case bengali = "Bengali"
    case bosnian = "Bosnian"
    case breton = "Breton"
    case bulgarian = "Bulgarian"
    case cantonese = "Cantonese"
    case catalan = "Catalan"
    case chinese = "中文"
    case croatian = "Croatian"
    case czech = "Czech"
    case danish = "Dansk"
    case dutch = "Nederlands"
    case english = "English"
    case estonian = "Estonian"
    case faroese = "Faroese"
    case filipino = "Filipino"
    case finnish = "Finnish"
    case french = "Français"
    case galician = "Galician"
    case georgian = "Georgian"
    case german = "Deutsch"
    case greek = "Greek"
    case gujarati = "Gujarati"
    case haitianCreole = "Haitian Creole"
    case hausa = "Hausa"
    case hawaiian = "Hawaiian"
    case hebrew = "Hebrew"
    case hindi = "हिन्दी"
    case hungarian = "Hungarian"
    case icelandic = "Icelandic"
    case indonesian = "Indonesian"
    case irish = "Irish"
    case italian = "Italiano"
    case japanese = "日本語"
    case javanese = "Javanese"
    case kannada = "Kannada"
    case kazakh = "Kazakh"
    case khmer = "Khmer"
    case korean = "한국어"
    case lao = "Lao"
    case latin = "Latin"
    case latvian = "Latvian"
    case lingala = "Lingala"
    case lithuanian = "Lithuanian"
    case luxembourgish = "Luxembourgish"
    case macedonian = "Macedonian"
    case malagasy = "Malagasy"
    case malay = "Malay"
    case malayalam = "Malayalam"
    case maltese = "Maltese"
    case maori = "Maori"
    case marathi = "Marathi"
    case mongolian = "Mongolian"
    case myanmar = "Myanmar"
    case nepali = "Nepali"
    case norwegian = "Norsk"
    case nynorsk = "Nynorsk"
    case occitan = "Occitan"
    case pashto = "Pashto"
    case persian = "Persian"
    case polish = "Polski"
    case portuguese = "Português"
    case punjabi = "Punjabi"
    case romanian = "Romanian"
    case russian = "Русский"
    case sanskrit = "Sanskrit"
    case serbian = "Serbian"
    case shona = "Shona"
    case sindhi = "Sindhi"
    case sinhala = "Sinhala"
    case slovak = "Slovak"
    case slovenian = "Slovenian"
    case somali = "Somali"
    case spanish = "Español"
    case sundanese = "Sundanese"
    case swahili = "Swahili"
    case swedish = "Svenska"
    case tagalog = "Tagalog"
    case tajik = "Tajik"
    case tamil = "Tamil"
    case tatar = "Tatar"
    case telugu = "Telugu"
    case thai = "Thai"
    case tibetan = "Tibetan"
    case turkish = "Turkish"
    case turkmen = "Turkmen"
    case ukrainian = "Українська"
    case urdu = "Urdu"
    case uzbek = "Uzbek"
    case vietnamese = "Vietnamese"
    case welsh = "Welsh"
    case yiddish = "Yiddish"
    case yoruba = "Yoruba"

    public var id: String { rawValue }
    public var whisperCode: String {
        switch self {
        case .auto: "auto"
        case .afrikaans: "af"
        case .albanian: "sq"
        case .amharic: "am"
        case .arabic: "ar"
        case .armenian: "hy"
        case .assamese: "as"
        case .azerbaijani: "az"
        case .bashkir: "ba"
        case .basque: "eu"
        case .belarusian: "be"
        case .bengali: "bn"
        case .bosnian: "bs"
        case .breton: "br"
        case .bulgarian: "bg"
        case .cantonese: "yue"
        case .catalan: "ca"
        case .chinese: "zh"
        case .croatian: "hr"
        case .czech: "cs"
        case .danish: "da"
        case .dutch: "nl"
        case .english: "en"
        case .estonian: "et"
        case .faroese: "fo"
        case .filipino: "fil"
        case .finnish: "fi"
        case .french: "fr"
        case .galician: "gl"
        case .georgian: "ka"
        case .german: "de"
        case .greek: "el"
        case .gujarati: "gu"
        case .haitianCreole: "ht"
        case .hausa: "ha"
        case .hawaiian: "haw"
        case .hebrew: "he"
        case .hindi: "hi"
        case .hungarian: "hu"
        case .icelandic: "is"
        case .indonesian: "id"
        case .irish: "ga"
        case .italian: "it"
        case .japanese: "ja"
        case .javanese: "jw"
        case .kannada: "kn"
        case .kazakh: "kk"
        case .khmer: "km"
        case .korean: "ko"
        case .lao: "lo"
        case .latin: "la"
        case .latvian: "lv"
        case .lingala: "ln"
        case .lithuanian: "lt"
        case .luxembourgish: "lb"
        case .macedonian: "mk"
        case .malagasy: "mg"
        case .malay: "ms"
        case .malayalam: "ml"
        case .maltese: "mt"
        case .maori: "mi"
        case .marathi: "mr"
        case .mongolian: "mn"
        case .myanmar: "my"
        case .nepali: "ne"
        case .norwegian: "no"
        case .nynorsk: "nn"
        case .occitan: "oc"
        case .pashto: "ps"
        case .persian: "fa"
        case .polish: "pl"
        case .portuguese: "pt"
        case .punjabi: "pa"
        case .romanian: "ro"
        case .russian: "ru"
        case .sanskrit: "sa"
        case .serbian: "sr"
        case .shona: "sn"
        case .sindhi: "sd"
        case .sinhala: "si"
        case .slovak: "sk"
        case .slovenian: "sl"
        case .somali: "so"
        case .spanish: "es"
        case .sundanese: "su"
        case .swahili: "sw"
        case .swedish: "sv"
        case .tagalog: "tl"
        case .tajik: "tg"
        case .tamil: "ta"
        case .tatar: "tt"
        case .telugu: "te"
        case .thai: "th"
        case .tibetan: "bo"
        case .turkish: "tr"
        case .turkmen: "tk"
        case .ukrainian: "uk"
        case .urdu: "ur"
        case .uzbek: "uz"
        case .vietnamese: "vi"
        case .welsh: "cy"
        case .yiddish: "yi"
        case .yoruba: "yo"
        }
    }
    public static func from(code: String) -> Self? { allCases.first { $0.whisperCode == code } }
    public var displayName: String { self == .auto ? "Automatic" : Locale(identifier: "en").localizedString(forLanguageCode: whisperCode)?.capitalized ?? rawValue }
    public var usesLatinScript: Bool { self != .auto && !Set(["am","ar","as","ba","be","bg","bn","bo","el","fa","gu","he","hi","hy","ja","ka","kk","km","kn","ko","lo","mk","ml","mn","mr","my","ne","pa","ps","ru","sa","sd","si","sr","ta","te","th","uk","ur","uz","yi","yue","zh"]).contains(whisperCode) }
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
