//! Text-only optional AI. Errors never contain provider bodies, prompts or tokens.
pub mod claude_code;
pub mod notes;
pub mod prompts;
pub mod review;
mod transport;
use crate::{
    accounts::{Accounts, ApiProvider},
    vocabulary::Entry,
};
use serde::{Deserialize, Serialize};
use std::{sync::Arc, time::Duration};
use tokio_util::sync::CancellationToken;
pub use transport::{Endpoints, HttpAi};

pub const CLAUDE_DICTATION_MODEL: &str = "claude-haiku-5-5";
pub const CLAUDE_DICTATION_EFFORT: &str = "low";
pub const OPENAI_DICTATION_MODEL: &str = "gpt-6-luna";
pub const OPENAI_DICTATION_EFFORT: &str = "medium";
pub const OPENAI_NOTES_MODEL: &str = "gpt-6.1-sol";

#[derive(Debug, thiserror::Error)]
pub enum AiError {
    #[error("Cancelled")]
    Cancelled,
    #[error("AI cleanup took too long")]
    Timeout,
    #[error("Connect an AI provider in Settings first")]
    NotConfigured,
    #[error("AI provider could not be reached")]
    Transport,
    #[error("AI provider returned HTTP {0}")]
    Http(u16),
    #[error("AI provider returned an invalid response")]
    BadResponse,
    #[error("AI provider stopped before completing the response")]
    Incomplete,
    #[error("AI provider refused this edit")]
    Refusal,
    #[error("The reply did not look like an edit of the dictation")]
    Implausible,
    #[error("ChatGPT usage limit reached")]
    UsageLimit,
    #[error("ChatGPT plan usage is not available for this account")]
    NotEligible,
    #[error("Pressay was not granted permission to use your ChatGPT plan")]
    PlanNotGranted,
    #[error("Could not access the operating system credential store")]
    CredentialStore,
    #[error("The credential or sign-in token could not be verified")]
    InvalidCredential,
    #[error("Your ChatGPT sign-in expired; sign in again")]
    RefreshExpired,
    #[error("The sign-in response did not match this request")]
    Callback,
    #[error("Could not open the system browser")]
    Browser,
    #[error("Sign-in was cancelled or denied")]
    SignInDenied,
    #[error("A sign-in is already in progress")]
    SignInBusy,
    #[error("Install Claude Code to use your Claude subscription")]
    ClaudeNotInstalled,
    #[error("Update Claude Code to use it with Pressay")]
    ClaudeUpdateRequired,
    #[error("Sign in to Claude Code with your Claude subscription")]
    ClaudeNotSignedIn,
    #[error("Claude Code could not finish; check your sign-in and plan limits")]
    ClaudeFailed,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum Provider {
    #[serde(rename = "claude")]
    Claude,
    #[serde(rename = "chatgpt")]
    OpenAi,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum Connection {
    #[serde(rename = "apiKey")]
    ApiKey,
    #[serde(rename = "subscription")]
    Subscription,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct CleanupConfig {
    pub enabled: bool,
    pub provider: Provider,
    pub connection: Connection,
}
impl Default for CleanupConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            provider: Provider::Claude,
            connection: Connection::ApiKey,
        }
    }
}
#[derive(Debug, Serialize)]
pub struct CleanupOutcome {
    pub text: String,
    pub used_language_model: bool,
    pub warning: Option<String>,
}

pub fn should_clean(text: &str, is_terminal: bool) -> bool {
    !is_terminal && text.split_whitespace().count() >= 10
}
pub fn cleanup_timeout(text: &str, config: CleanupConfig) -> Duration {
    let words = text.split_whitespace().count() as f64;
    Duration::from_secs_f64(
        if config.provider == Provider::Claude && config.connection == Connection::Subscription {
            (8.0 + words * 0.01).min(15.0)
        } else {
            (3.0 + words * 0.01).min(8.0)
        },
    )
}
pub fn plausible(input: &str, output: &str) -> bool {
    let input = input.split_whitespace().count();
    let output = output.split_whitespace().count();
    output > 0
        && if input < 8 {
            output <= input * 3 + 6
        } else {
            output as f64 >= input as f64 * 0.35 && output as f64 <= input as f64 * 1.6 + 10.0
        }
}

pub struct AiService {
    pub accounts: Arc<Accounts>,
    pub claude_code: claude_code::ClaudeCodeClient,
    pub http: HttpAi,
}
impl AiService {
    /// The native host rejects new work and cancels jobs before calling this.
    pub async fn shutdown(&self) {
        tokio::join!(
            self.accounts.chatgpt.shutdown(),
            self.http.invalidate(),
            claude_code::wait_for_children()
        );
    }
    pub fn new(accounts: Arc<Accounts>) -> Result<Self, AiError> {
        Ok(Self {
            accounts,
            claude_code: claude_code::ClaudeCodeClient::discover(),
            http: HttpAi::new()?,
        })
    }
    /// Call while recording; opens/checks transport only, never inference.
    pub async fn warm_up(
        &self,
        config: CleanupConfig,
        cancel: &CancellationToken,
    ) -> Result<(), AiError> {
        if !config.enabled || config.provider != Provider::OpenAi {
            return Ok(());
        }
        let key = self.credential(config, cancel).await?;
        self.http.warm_up(&key, cancel).await
    }
    /// Call during real ASR work. Drop/cancel the single-use preparation when
    /// cleanup is skipped. No transcript or dummy inference is sent here.
    pub async fn prepare_claude(
        &self,
        vocabulary: &[Entry],
        cancel: &CancellationToken,
    ) -> Result<claude_code::Preparation, AiError> {
        self.claude_code
            .prepare(
                &prompts::cleanup_system(vocabulary),
                CLAUDE_DICTATION_EFFORT,
                cancel,
            )
            .await
    }
    async fn credential(
        &self,
        config: CleanupConfig,
        cancel: &CancellationToken,
    ) -> Result<crate::accounts::Secret, AiError> {
        match (config.provider, config.connection) {
            (Provider::OpenAi, Connection::Subscription) => {
                self.accounts.chatgpt.access_token(cancel).await
            }
            (provider, Connection::ApiKey) => self
                .accounts
                .api_key(if provider == Provider::Claude {
                    ApiProvider::Claude
                } else {
                    ApiProvider::OpenAi
                })?
                .ok_or(AiError::NotConfigured),
            _ => Err(AiError::NotConfigured),
        }
    }
    /// `local` is the already-computed deterministic result. Never feed those
    /// phonetic rewrites back to the model: AI receives the raw ASR transcript.
    #[allow(clippy::too_many_arguments)]
    pub async fn cleanup(
        &self,
        raw: &str,
        local: &str,
        target: Option<&str>,
        vocabulary: &[Entry],
        config: CleanupConfig,
        preparation: Option<claude_code::Preparation>,
        cancel: &CancellationToken,
    ) -> Result<CleanupOutcome, AiError> {
        if cancel.is_cancelled() {
            return Err(AiError::Cancelled);
        }
        if !config.enabled || !should_clean(raw, crate::text::is_terminal(target)) {
            drop(preparation);
            return Ok(CleanupOutcome {
                text: local.into(),
                used_language_model: false,
                warning: None,
            });
        }
        let timeout = cleanup_timeout(raw, config);
        let operation = async {
            let system = prompts::cleanup_system(vocabulary);
            let user = prompts::cleanup_user(raw, target);
            let text = if config.provider == Provider::Claude
                && config.connection == Connection::Subscription
            {
                self.claude_code
                    .complete(
                        &system,
                        &user,
                        CLAUDE_DICTATION_MODEL,
                        CLAUDE_DICTATION_EFFORT,
                        timeout,
                        preparation,
                        cancel,
                    )
                    .await?
            } else {
                drop(preparation);
                let credential = self.credential(config, cancel).await?;
                match config.provider {
                    Provider::Claude => {
                        self.http
                            .claude(
                                &system,
                                &user,
                                CLAUDE_DICTATION_MODEL,
                                "low",
                                4000,
                                &credential,
                                timeout,
                                cancel,
                            )
                            .await?
                    }
                    Provider::OpenAi => {
                        self.http
                            .openai(
                                &system,
                                &user,
                                OPENAI_DICTATION_MODEL,
                                OPENAI_DICTATION_EFFORT,
                                true,
                                &credential,
                                timeout,
                                cancel,
                            )
                            .await?
                    }
                }
            };
            if !plausible(raw, &text) {
                return Err(AiError::Implausible);
            }
            Ok::<_, AiError>(text)
        };
        let result = tokio::select! {biased;_=cancel.cancelled()=>Err(AiError::Cancelled),result=tokio::time::timeout(timeout,operation)=>result.unwrap_or(Err(AiError::Timeout))};
        match result {
            Ok(text) => Ok(CleanupOutcome {
                text,
                used_language_model: true,
                warning: None,
            }),
            Err(AiError::Cancelled) => Err(AiError::Cancelled),
            Err(error) => Ok(CleanupOutcome {
                text: local.into(),
                used_language_model: false,
                warning: Some(error.to_string()),
            }),
        }
    }
    pub async fn complete(
        &self,
        system: &str,
        user: &str,
        model: &notes::NotesModel,
        connection: Connection,
        timeout: Duration,
        cancel: &CancellationToken,
    ) -> Result<String, AiError> {
        let config = CleanupConfig {
            enabled: true,
            provider: model.provider(),
            connection,
        };
        let work = async {
            if model.provider() == Provider::Claude && connection == Connection::Subscription {
                return self
                    .claude_code
                    .complete(
                        system,
                        user,
                        model.slug(),
                        model.effort(),
                        timeout,
                        None,
                        cancel,
                    )
                    .await;
            }
            let credential = self.credential(config, cancel).await?;
            match model.provider() {
                Provider::Claude => {
                    self.http
                        .claude(
                            system,
                            user,
                            model.slug(),
                            model.effort(),
                            16000,
                            &credential,
                            timeout,
                            cancel,
                        )
                        .await
                }
                Provider::OpenAi => {
                    self.http
                        .openai(
                            system,
                            user,
                            model.slug(),
                            model.effort(),
                            false,
                            &credential,
                            timeout,
                            cancel,
                        )
                        .await
                }
            }
        };
        tokio::select! {biased;_=cancel.cancelled()=>Err(AiError::Cancelled),result=tokio::time::timeout(timeout,work)=>result.unwrap_or(Err(AiError::Timeout))}
    }
}

#[cfg(test)]
pub(crate) mod test_support;
#[cfg(test)]
mod tests;
