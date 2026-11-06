//! UI-independent dictation services. Platform permissions, audio devices, hotkeys
//! and insertion belong to the host; neither a renderer nor a model owns policy.
pub mod accounts;
pub mod ai;
pub mod audio;
pub mod catalog;
pub mod dictation;
pub mod download;
pub mod onboarding;
pub mod storage;
pub mod text;
pub mod vocabulary;
pub mod worker;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Message(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Database(#[from] rusqlite::Error),
    #[error(transparent)]
    Network(#[from] reqwest::Error),
    #[error("Cancelled")]
    Cancelled,
}
pub type Result<T> = std::result::Result<T, Error>;

pub mod notes;

pub mod recordings;

pub mod segmenter;

pub mod analysis;
