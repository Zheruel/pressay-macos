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
