//! Credentials stay in the native host. Only AccountStatus is renderer-safe.
pub mod oauth;
pub use oauth::{AccountStatus, ChatGptAccount};
use std::{fmt, sync::Arc};
use zeroize::Zeroizing;

/// Deliberately not Serialize/Display. Debug redacts all credential material.
#[derive(Clone)]
pub struct Secret(Zeroizing<String>);
impl Secret {
    pub fn new(value: String) -> Self {
        Self(Zeroizing::new(value))
    }
    pub fn expose(&self) -> &str {
        &self.0
    }
}
impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret([REDACTED])")
    }
}

/// Implement with macOS Keychain, Windows Credential Manager and Linux Secret
/// Service. Never silently replace this with renderer storage or a plaintext file.
/// Adapter errors are sanitized by Accounts before they reach the renderer.
pub trait SecretStore: Send + Sync {
    fn get(&self, key: &str) -> Result<Option<Secret>, String>;
    fn set(&self, key: &str, value: &Secret) -> Result<(), String>;
    fn delete(&self, key: &str) -> Result<(), String>;
}

#[derive(Clone, Copy, Debug)]
pub enum ApiProvider {
    Claude,
    OpenAi,
}
impl ApiProvider {
    fn key(self) -> &'static str {
        match self {
            Self::Claude => "claude-api-key",
            Self::OpenAi => "openai-api-key",
        }
    }
}

pub struct Accounts {
    store: Arc<dyn SecretStore>,
    pub chatgpt: ChatGptAccount,
}
impl Accounts {
    pub fn new(store: Arc<dyn SecretStore>) -> Result<Self, crate::ai::AiError> {
        Ok(Self {
            chatgpt: ChatGptAccount::new(store.clone())?,
            store,
        })
    }
    pub fn api_key(&self, provider: ApiProvider) -> Result<Option<Secret>, crate::ai::AiError> {
        self.store
            .get(provider.key())
            .map_err(|_| crate::ai::AiError::CredentialStore)
    }
    pub fn set_api_key(
        &self,
        provider: ApiProvider,
        value: &str,
    ) -> Result<(), crate::ai::AiError> {
        let value = value.trim();
        if value.is_empty() {
            return self
                .store
                .delete(provider.key())
                .map_err(|_| crate::ai::AiError::CredentialStore);
        }
        if value.len() > 8192 || value.chars().any(char::is_control) {
            return Err(crate::ai::AiError::InvalidCredential);
        }
        self.store
            .set(provider.key(), &Secret::new(value.into()))
            .map_err(|_| crate::ai::AiError::CredentialStore)
    }
}
