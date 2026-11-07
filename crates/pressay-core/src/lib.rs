//! UI-independent dictation services. Platform permissions, audio devices, hotkeys
//! and insertion belong to the host; neither a renderer nor a model owns policy.
pub mod accounts;
pub mod ai;
pub mod audio;
pub mod catalog;
pub mod dictation;
pub mod download;
pub mod legacy_mac;
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

pub(crate) fn sha256(bytes: &[u8]) -> [u8; 32] {
    let digest = aws_lc_rs::digest::digest(&aws_lc_rs::digest::SHA256, bytes);
    digest
        .as_ref()
        .try_into()
        .expect("SHA-256 produces 32 bytes")
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    bytes
        .iter()
        .flat_map(|byte| {
            [
                DIGITS[(byte >> 4) as usize] as char,
                DIGITS[(byte & 15) as usize] as char,
            ]
        })
        .collect()
}
