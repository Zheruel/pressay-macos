import NaturalLanguage
import PressayCore

/// English filler/stutter heuristics must not rewrite legitimate words in other languages.
enum SpeechLanguage {
    static func usesEnglishRules(_ text: String, hint: TranscriptionLanguage = .auto) -> Bool {
        if hint != .auto { return hint == .english }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 2)[.english, default: 0] >= 0.8
    }
}
