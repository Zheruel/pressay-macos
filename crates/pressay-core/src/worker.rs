use crate::{audio, Error, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Deserialize;
use std::{
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStdin, ChildStdout, Command},
};
use tokio_util::sync::CancellationToken;

const MAX_REPLY: u64 = 1_048_576;
#[derive(Debug, Deserialize)]
struct Reply {
    ready: Option<bool>,
    text: Option<String>,
    truncated: Option<bool>,
    error: Option<String>,
}
struct Resident {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    model: String,
    path: PathBuf,
}
impl Resident {
    async fn reply(&mut self) -> Result<Reply> {
        let mut line = Vec::new();
        let n = (&mut self.stdout)
            .take(MAX_REPLY + 1)
            .read_until(b'\n', &mut line)
            .await?;
        if n == 0 {
            return Err(Error::Message("Speech worker stopped unexpectedly".into()));
        }
        if n as u64 > MAX_REPLY || line.last() != Some(&b'\n') {
            return Err(Error::Message(
                "Invalid or oversized speech worker reply".into(),
            ));
        }
        let reply: Reply = serde_json::from_slice(&line)?;
        if let Some(error) = reply.error {
            return Err(Error::Message(error));
        }
        Ok(reply)
    }
}
/// One child per host. All calls require exclusive access, so model replacement
/// and inference cannot overlap. Cancellation kills and reaps the child before reuse.
pub struct WorkerHost {
    executable: PathBuf,
    runtime: PathBuf,
    timeout: Duration,
    resident: Option<Resident>,
}
impl WorkerHost {
    pub fn new(executable: PathBuf, runtime: PathBuf) -> Self {
        Self {
            executable,
            runtime,
            timeout: Duration::from_secs(180),
            resident: None,
        }
    }
    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }
    pub async fn stop(&mut self) {
        if let Some(mut resident) = self.resident.take() {
            let _ = resident.child.kill().await;
            let _ = resident.child.wait().await;
        }
    }
    async fn load(&mut self, model: &str, path: &Path) -> Result<()> {
        if let Some(resident) = self.resident.as_mut() {
            if resident.model == model
                && resident.path == path
                && resident.child.try_wait()?.is_none()
            {
                return Ok(());
            }
        }
        self.stop().await;
        let mut child = Command::new(&self.executable)
            .args([Path::new(model), path, &self.runtime])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| Error::Message("Missing worker input".into()))?;
        let stdout = BufReader::new(
            child
                .stdout
                .take()
                .ok_or_else(|| Error::Message("Missing worker output".into()))?,
        );
        self.resident = Some(Resident {
            child,
            stdin,
            stdout,
            model: model.into(),
            path: path.into(),
        });
        if self.resident.as_mut().unwrap().reply().await?.ready != Some(true) {
            return Err(Error::Message("Speech model did not become ready".into()));
        }
        Ok(())
    }
    async fn request_inner(
        &mut self,
        model: &str,
        path: &Path,
        samples: Option<&[f32]>,
    ) -> Result<(String, bool)> {
        if let Some(samples) = samples {
            audio::validate(samples)?;
        }
        self.load(model, path).await?;
        let Some(samples) = samples else {
            return Ok((String::new(), false));
        };
        let pcm: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        let mut data = serde_json::to_vec(&serde_json::json!({"pcm": STANDARD.encode(pcm)}))?;
        data.push(b'\n');
        let resident = self.resident.as_mut().unwrap();
        resident.stdin.write_all(&data).await?;
        resident.stdin.flush().await?;
        let reply = resident.reply().await?;
        match (reply.text, reply.truncated) {
            (Some(text), Some(truncated)) => Ok((text, truncated)),
            _ => Err(Error::Message("Invalid speech worker response".into())),
        }
    }
    pub async fn request(
        &mut self,
        model: &str,
        path: &Path,
        samples: Option<&[f32]>,
        cancel: &CancellationToken,
    ) -> Result<(String, bool)> {
        let timeout = self.timeout;
        let result = tokio::select! {
            biased;
            _ = cancel.cancelled() => Err(Error::Cancelled),
            result = tokio::time::timeout(timeout, self.request_inner(model, path, samples)) => result.unwrap_or_else(|_| Err(Error::Message("Speech engine timed out; please retry".into()))),
        };
        if result.is_err() {
            self.stop().await;
        }
        result
    }
    pub async fn transcribe(
        &mut self,
        model: &str,
        path: &Path,
        samples: &[f32],
        cancel: &CancellationToken,
    ) -> Result<String> {
        if samples.is_empty() || samples.iter().any(|v| !v.is_finite()) {
            return Err(Error::Message("No valid audio was captured".into()));
        }
        let mut chunks = vec![(samples, 0)];
        let mut output = Vec::new();
        while let Some((samples, depth)) = chunks.pop() {
            if cancel.is_cancelled() {
                self.stop().await;
                return Err(Error::Cancelled);
            }
            if samples.len() > audio::MAX_CHUNK_SAMPLES {
                let cut = audio::split_point(samples);
                chunks.push((&samples[cut..], depth));
                chunks.push((&samples[..cut], depth));
                continue;
            }
            let (text, truncated) = self.request(model, path, Some(samples), cancel).await?;
            if truncated {
                if depth >= 6 || samples.len() < 2 * audio::SAMPLE_RATE {
                    return Err(Error::Message(
                        "Speech engine could not finish this audio; try another model".into(),
                    ));
                }
                let cut = audio::split_point(samples);
                chunks.push((&samples[cut..], depth + 1));
                chunks.push((&samples[..cut], depth + 1));
            } else {
                let text = plain_transcript(model, &text);
                if !text.is_empty() {
                    output.push(text);
                }
            }
        }
        let text = output.join(" ");
        if text.is_empty() {
            Err(Error::Message(
                "No speech recognized. Please try again.".into(),
            ))
        } else {
            Ok(text)
        }
    }
}
fn plain_transcript(model: &str, text: &str) -> String {
    let text = text.trim();
    let lower = text.to_lowercase();
    if ["moss", "megaASR", "qwen3ASR17"].contains(&model)
        && text.chars().count() <= 64
        && [
            "i'm sorry, i didn't understand",
            "i'm sorry, i couldn't understand",
            "sorry, i didn't understand",
        ]
        .iter()
        .any(|s| lower.starts_with(s))
    {
        return String::new();
    }
    if model == "moss" {
        let envelope = regex::Regex::new(r"^\[\d+(?:\.\d+)?\].*\[\d+(?:\.\d+)?\]$").unwrap();
        if envelope.is_match(text) {
            return regex::Regex::new(r"\[(?:\d+(?:\.\d+)?|S\d{1,3})\]")
                .unwrap()
                .replace_all(text, " ")
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
        }
    }
    text.into()
}
