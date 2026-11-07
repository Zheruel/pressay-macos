use crate::{
    catalog::{Artifact, Model},
    Error, Result,
};
use aws_lc_rs::digest::{Context, SHA256};
use futures_util::StreamExt;
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
    time::Duration,
};
use tokio_util::sync::CancellationToken;

#[derive(Clone, serde::Serialize)]
pub struct Progress {
    pub model: String,
    pub downloaded: u64,
    pub total: u64,
    pub stage: &'static str,
}

pub fn verified(path: &Path, artifact: &Artifact) -> Result<bool> {
    verified_cancellable(path, artifact, &CancellationToken::new())
}

fn verified_cancellable(
    path: &Path,
    artifact: &Artifact,
    cancel: &CancellationToken,
) -> Result<bool> {
    let mut file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(e.into()),
    };
    if file.metadata()?.len() != artifact.bytes {
        return Ok(false);
    }
    let mut hash = Context::new(&SHA256);
    let mut buffer = vec![0; 1024 * 1024];
    loop {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    Ok(crate::hex(hash.finish().as_ref()) == artifact.sha256)
}

fn validate_manifest(model: &Model) -> Result<()> {
    let safe_component = |part: &str| {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
    };
    if !safe_component(&model.id) || model.artifacts.is_empty() {
        return Err(Error::Message("Invalid speech model manifest".into()));
    }
    let mut total = 0_u64;
    let mut paths = std::collections::HashSet::new();
    for artifact in &model.artifacts {
        if !artifact.path.split('/').all(safe_component)
            || !paths.insert(&artifact.path)
            || artifact.bytes == 0
            || artifact.sha256.len() != 64
            || !artifact.sha256.bytes().all(|c| c.is_ascii_hexdigit())
        {
            return Err(Error::Message("Invalid speech model artifact".into()));
        }
        total = total
            .checked_add(artifact.bytes)
            .ok_or_else(|| Error::Message("Speech model is too large".into()))?;
    }
    Ok(())
}

/// The caller serializes model preparation with inference. Downloads never
/// execute model-supplied code and only become visible after length/hash checks.
pub async fn prepare(
    root: &Path,
    model: &Model,
    cancel: &CancellationToken,
    progress: impl Fn(Progress),
) -> Result<PathBuf> {
    validate_manifest(model)?;
    if cancel.is_cancelled() {
        return Err(Error::Cancelled);
    }
    if !model.supported() {
        return Err(Error::Message(format!(
            "{} requires Apple Silicon; choose an available model explicitly",
            model.name
        )));
    }
    let directory = root.join(&model.id);
    std::fs::create_dir_all(&directory)?;
    let client = reqwest::Client::builder()
        .https_only(true)
        .connect_timeout(Duration::from_secs(30))
        .read_timeout(Duration::from_secs(60))
        .build()?;
    let mut completed = 0;
    for artifact in &model.artifacts {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let target = directory.join(&artifact.path);
        let path = target.clone();
        let a = artifact.clone();
        let verification_cancel = cancel.clone();
        let verification = tokio::task::spawn_blocking(move || {
            verified_cancellable(&path, &a, &verification_cancel)
        });
        let valid = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(Error::Cancelled),
            result = verification => result.map_err(|e| Error::Message(e.to_string()))??,
        };
        if !valid {
            std::fs::create_dir_all(target.parent().unwrap())?;
            let mut file = tempfile::NamedTempFile::new_in(target.parent().unwrap())?;
            let response = tokio::select! {
                _ = cancel.cancelled() => return Err(Error::Cancelled),
                result = client.get(&artifact.url).send() => result?.error_for_status()?,
            };
            let mut stream = response.bytes_stream();
            let mut written = 0_u64;
            let mut hash = Context::new(&SHA256);
            loop {
                let chunk = tokio::select! {
                    _ = cancel.cancelled() => return Err(Error::Cancelled),
                    chunk = stream.next() => chunk,
                };
                let Some(chunk) = chunk else {
                    break;
                };
                let chunk = chunk?;
                written += chunk.len() as u64;
                if written > artifact.bytes {
                    return Err(Error::Message(
                        "Model download exceeds its pinned size".into(),
                    ));
                }
                hash.update(&chunk);
                file.write_all(&chunk)?;
                progress(Progress {
                    model: model.id.clone(),
                    downloaded: completed + written,
                    total: model.bytes(),
                    stage: "downloading",
                });
            }
            if written != artifact.bytes || crate::hex(hash.finish().as_ref()) != artifact.sha256 {
                return Err(Error::Message(
                    "Model integrity check failed; retry the download".into(),
                ));
            }
            if cancel.is_cancelled() {
                return Err(Error::Cancelled);
            }
            file.as_file().sync_all()?;
            file.persist(&target).map_err(|e| e.error)?;
        }
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        completed += artifact.bytes;
        progress(Progress {
            model: model.id.clone(),
            downloaded: completed,
            total: model.bytes(),
            stage: "verified",
        });
    }
    if cancel.is_cancelled() {
        return Err(Error::Cancelled);
    }
    Ok(if model.id == "megaASR" {
        directory
    } else {
        directory.join(&model.artifacts[0].path)
    })
}
