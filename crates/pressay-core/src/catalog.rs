use serde::{Deserialize, Serialize};
use std::sync::OnceLock;
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Artifact {
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
    pub url: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Model {
    pub id: String,
    pub name: String,
    pub mac_only: bool,
    pub artifacts: Vec<Artifact>,
}
impl Model {
    pub fn supported(&self) -> bool {
        !self.mac_only || cfg!(all(target_os = "macos", target_arch = "aarch64"))
    }
    pub fn language_caption(&self) -> &'static str {
        match self.id.as_str() {
            "orukeet" | "parakeetUltra" => "25 European languages · automatic detection",
            "moss" => "50+ languages · automatic detection",
            "qwen3ASR17" | "qwen3ASR06" => "30 languages · automatic detection",
            "funASRMLTNano" => "31 languages · automatic detection or a fixed language",
            "whisperTurboGGML" => "100 languages · automatic detection or a fixed language",
            "voxtralMini" => "8 languages · automatic detection or a fixed language",
            _ => "Multilingual · automatic detection",
        }
    }
    pub fn is_secondary(&self) -> bool {
        matches!(
            self.id.as_str(),
            "funASRMLTNano" | "whisperTurboGGML" | "voxtralMini" | "qwen3ASR06"
        )
    }
    pub fn supports_language_hint(&self) -> bool {
        matches!(
            self.id.as_str(),
            "funASRMLTNano" | "whisperTurboGGML" | "voxtralMini"
        )
    }
    pub fn language_codes(&self) -> &'static [&'static str] {
        match self.id.as_str() {
            "orukeet" => &[
                "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv",
                "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk",
            ],
            "moss" => &[],
            "parakeetUltra" => &[
                "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv",
                "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk",
            ],
            "qwen3ASR17" => &[
                "ar", "yue", "zh", "cs", "da", "nl", "en", "fil", "fi", "fr", "de", "el", "hi",
                "hu", "id", "it", "ja", "ko", "mk", "ms", "fa", "pl", "pt", "ro", "ru", "es", "sv",
                "th", "tr", "vi",
            ],
            "megaASR" => &[],
            "voxtralMini" => &["nl", "en", "fr", "de", "hi", "it", "pt", "es"],
            "whisperTurboGGML" => &[
                "af", "sq", "am", "ar", "hy", "as", "az", "ba", "eu", "be", "bn", "bs", "br", "bg",
                "yue", "ca", "zh", "hr", "cs", "da", "nl", "en", "et", "fo", "fi", "fr", "gl",
                "ka", "de", "el", "gu", "ht", "ha", "haw", "he", "hi", "hu", "is", "id", "it",
                "ja", "jw", "kn", "kk", "km", "ko", "lo", "la", "lv", "ln", "lt", "lb", "mk", "mg",
                "ms", "ml", "mt", "mi", "mr", "mn", "my", "ne", "no", "nn", "oc", "ps", "fa", "pl",
                "pt", "pa", "ro", "ru", "sa", "sr", "sn", "sd", "si", "sk", "sl", "so", "es", "su",
                "sw", "sv", "tl", "tg", "ta", "tt", "te", "th", "bo", "tr", "tk", "uk", "ur", "uz",
                "vi", "cy", "yi", "yo",
            ],
            "qwen3ASR06" => &[
                "ar", "yue", "zh", "cs", "da", "nl", "en", "fil", "fi", "fr", "de", "el", "hi",
                "hu", "id", "it", "ja", "ko", "mk", "ms", "fa", "pl", "pt", "ro", "ru", "es", "sv",
                "th", "tr", "vi",
            ],
            "funASRMLTNano" => &[
                "ar", "bg", "yue", "zh", "hr", "cs", "da", "nl", "en", "et", "fil", "fi", "el",
                "hi", "hu", "id", "ga", "ja", "ko", "lv", "lt", "ms", "mt", "pl", "pt", "ro", "sk",
                "sl", "sv", "th", "vi",
            ],
            _ => &[],
        }
    }
    /// A stale language preference must not break a newly selected engine.
    pub fn effective_language<'a>(&self, requested: &'a str) -> &'a str {
        if self.supports_language_hint() && self.language_codes().contains(&requested) {
            requested
        } else {
            "auto"
        }
    }
    pub fn bytes(&self) -> u64 {
        self.artifacts.iter().map(|a| a.bytes).sum()
    }
}
pub fn models() -> &'static [Model] {
    static MODELS: OnceLock<Vec<Model>> = OnceLock::new();
    MODELS.get_or_init(|| {
        serde_json::from_str(include_str!("catalog.json")).expect("checked-in model catalog")
    })
}
pub fn find(id: &str) -> crate::Result<&'static Model> {
    models()
        .iter()
        .find(|m| m.id == id)
        .ok_or_else(|| crate::Error::Message(format!("Unknown speech model: {id}")))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn all_shipping_models_and_language_choices_are_preserved() {
        let swift = include_str!("../../../Sources/PressayCore/Domain.swift");
        let coverage = swift
            .split("public var languageCodes: [String] {")
            .nth(1)
            .unwrap()
            .split("public var defaultLanguage")
            .next()
            .unwrap();
        let mut expected: Vec<_> = coverage
            .lines()
            .filter_map(|line| {
                line.trim()
                    .strip_prefix("case .")
                    .and_then(|line| line.split(':').next())
            })
            .collect();
        expected.sort();
        let mut actual: Vec<_> = models().iter().map(|model| model.id.as_str()).collect();
        actual.sort();
        assert_eq!(actual, expected);
        for model in models() {
            let prefix = format!("case .{}: ", model.id);
            let language_json = coverage
                .lines()
                .find_map(|line| line.trim().strip_prefix(&prefix))
                .unwrap();
            let languages: Vec<String> = serde_json::from_str(language_json).unwrap();
            assert_eq!(model.language_codes(), languages, "{}", model.id);
            assert_eq!(model.effective_language("invalid"), "auto");
            assert_eq!(model.effective_language("auto"), "auto");
            assert_eq!(
                model.effective_language("en"),
                if model.supports_language_hint() {
                    "en"
                } else {
                    "auto"
                }
            );
        }
    }
    #[test]
    fn catalog_is_pinned_and_safe() {
        for m in models() {
            assert!(!m.artifacts.is_empty());
            for a in &m.artifacts {
                assert_eq!(a.sha256.len(), 64);
                assert!(a.sha256.bytes().all(|c| c.is_ascii_hexdigit()));
                assert!(a.bytes > 0);
                assert!(!a.path.split('/').any(|p| p == ".."));
                let revision = a
                    .url
                    .split("/resolve/")
                    .nth(1)
                    .unwrap()
                    .split('/')
                    .next()
                    .unwrap();
                assert_eq!(revision.len(), 40);
            }
        }
    }
}
