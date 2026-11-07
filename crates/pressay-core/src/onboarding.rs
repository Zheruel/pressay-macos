use serde::{Deserialize, Serialize};
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Permission {
    Unknown,
    Granted,
    Denied,
    Unavailable,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Readiness {
    pub microphone: Permission,
    pub shortcut: Permission,
    pub insertion: Permission,
    pub model_ready: bool,
}
impl Readiness {
    pub fn ready(&self) -> bool {
        self.model_ready
            && [self.microphone, self.shortcut, self.insertion]
                .iter()
                .all(|p| *p == Permission::Granted)
    }
}
/// A model load or a click on Continue is never evidence of successful dictation.
#[derive(Default, Clone, Debug, Serialize, Deserialize)]
pub struct Practice {
    pub received_audio: bool,
    pub recognized_text: String,
    pub inserted: bool,
    #[serde(default)]
    pub in_app: bool,
    pub observed_text: String,
}
impl Practice {
    pub fn complete(&self, readiness: &Readiness) -> bool {
        readiness.ready()
            && self.received_audio
            && self.inserted
            && self.in_app
            && !self.recognized_text.trim().is_empty()
            && self.observed_text.trim() == self.recognized_text.trim()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn requires_real_insertion_and_current_permissions() {
        let mut r = Readiness {
            microphone: Permission::Granted,
            shortcut: Permission::Granted,
            insertion: Permission::Granted,
            model_ready: true,
        };
        let mut p = Practice {
            received_audio: true,
            recognized_text: "Hello".into(),
            inserted: true,
            in_app: true,
            ..Default::default()
        };
        assert!(!p.complete(&r));
        p.observed_text = "Hello".into();
        assert!(p.complete(&r));
        p.in_app = false;
        assert!(
            !p.complete(&r),
            "Dictation in another app is not practice evidence"
        );
        p.in_app = true;
        p.observed_text = "Before Hello after".into();
        assert!(
            !p.complete(&r),
            "Practice must match the completed dictation"
        );
        p.observed_text = "Hello".into();
        r.microphone = Permission::Denied;
        assert!(!p.complete(&r));
    }
}
