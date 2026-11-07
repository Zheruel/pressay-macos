//! Pause-based inference shares the resident ASR worker with the release path.
//! Capture never waits for this optional optimization; any missing packet or
//! detector/worker failure falls back to the complete captured recording.
use pressay_core::{
    analysis::{self, AnalysisHost},
    dictation::{trim, CutPlanner},
    download,
    worker::WorkerHost,
};
use std::{
    path::PathBuf,
    sync::{
        mpsc::{Receiver, TryRecvError},
        Arc,
    },
    time::Duration,
};
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;
pub type Host = Arc<Mutex<WorkerHost>>;
pub type Earcon = Arc<std::sync::Mutex<Option<std::ops::Range<usize>>>>;
struct Progress {
    planner: CutPlanner,
    text: Vec<String>,
}
pub struct Session {
    finished: CancellationToken,
    cancel: CancellationToken,
    task: Option<tokio::task::JoinHandle<Option<Progress>>>,
}
impl Session {
    #[allow(clippy::too_many_arguments)]
    pub fn start(
        host: Host,
        receiver: Receiver<Vec<f32>>,
        model: String,
        path: PathBuf,
        executable: PathBuf,
        runtime: PathBuf,
        data: PathBuf,
        earcon_guard: Earcon,
        parent: &CancellationToken,
    ) -> Self {
        let cancel = parent.child_token();
        let token = cancel.clone();
        let finished = CancellationToken::new();
        let finish = finished.clone();
        let task = tokio::spawn(async move {
            let mut analysis = AnalysisHost::new(executable, runtime);
            let result = run(
                &host,
                receiver,
                &model,
                &path,
                &data,
                &mut analysis,
                &token,
                &finish,
                &earcon_guard,
            )
            .await;
            analysis.stop().await;
            result.ok()
        });
        Self {
            finished,
            cancel,
            task: Some(task),
        }
    }
    pub async fn finish(
        mut self,
        samples: &[f32],
        host: &Host,
        model: &str,
        path: &std::path::Path,
        cancel: &CancellationToken,
    ) -> Option<String> {
        self.finished.cancel();
        let mut progress = self.task.take()?.await.ok()??;
        let tail = progress.planner.finish(samples.len())?;
        if let Ok(samples) = trim(&samples[tail], None) {
            match host
                .lock()
                .await
                .transcribe(model, path, &samples, cancel)
                .await
            {
                Ok(text) => progress.text.push(text),
                Err(pressay_core::Error::Message(message))
                    if message.starts_with("No speech recognized") => {}
                Err(_) => return None,
            }
        }
        let text = progress
            .text
            .into_iter()
            .filter(|s| !s.trim().is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        if text.is_empty() {
            None
        } else {
            Some(text)
        }
    }
    pub async fn cancel(mut self) {
        self.cancel.cancel();
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}
#[allow(clippy::too_many_arguments)]
async fn run(
    host: &Host,
    receiver: Receiver<Vec<f32>>,
    model: &str,
    path: &std::path::Path,
    data: &std::path::Path,
    analysis: &mut AnalysisHost,
    cancel: &CancellationToken,
    finished: &CancellationToken,
    earcon_guard: &std::sync::Mutex<Option<std::ops::Range<usize>>>,
) -> Result<Progress, String> {
    let vad = analysis::find("sileroVAD").map_err(|e| e.to_string())?;
    let prepare = async {
        let vad_path = download::prepare(&data.join("Models/Analysis"), vad, cancel, |_| {})
            .await
            .map_err(|e| e.to_string())?;
        analysis
            .prepare_vad(&vad_path, cancel)
            .await
            .map_err(|e| e.to_string())
    };
    tokio::select! { biased; _=finished.cancelled()=>return Err("Use the complete clip while the detector is preparing".into()), result=prepare=>result? }
    run_ready(host, receiver, model, path, analysis, cancel, earcon_guard).await
}
async fn run_ready(
    host: &Host,
    receiver: Receiver<Vec<f32>>,
    model: &str,
    path: &std::path::Path,
    analysis: &mut AnalysisHost,
    cancel: &CancellationToken,
    earcon_guard: &std::sync::Mutex<Option<std::ops::Range<usize>>>,
) -> Result<Progress, String> {
    let mut planner = CutPlanner::new(16_000 * 300);
    let mut text = Vec::new();
    let mut buffer = Vec::new();
    let mut base = 0;
    loop {
        if cancel.is_cancelled() {
            return Err("Cancelled".into());
        }
        let mut batch = Vec::new();
        let mut closed = false;
        // Bound each detector request while draining packets accumulated during ASR.
        while batch.len() < 16_000 {
            match receiver.try_recv() {
                Ok(packet) => batch.extend(packet),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    closed = true;
                    break;
                }
            }
        }
        if !batch.is_empty() {
            planner.push_audio(&batch).map_err(|e| e.to_string())?;
            buffer.extend_from_slice(&batch);
            let classified = analysis
                .classify(0, &batch, cancel)
                .await
                .map_err(|e| e.to_string())?;
            for piece in planner.observe(&classified).map_err(|e| e.to_string())? {
                let samples = buffer
                    .get(piece.range.start - base..piece.range.end - base)
                    .ok_or("Invalid live audio boundary")?;
                if piece.has_speech {
                    let trimmed = if piece.first {
                        trim(samples, earcon_guard.lock().unwrap().clone()).ok()
                    } else {
                        Some(samples.to_vec())
                    };
                    if let Some(samples) = trimmed {
                        match host
                            .lock()
                            .await
                            .transcribe(model, path, &samples, cancel)
                            .await
                        {
                            Ok(value) => text.push(value),
                            Err(pressay_core::Error::Message(message))
                                if message.starts_with("No speech recognized") =>
                            {
                                text.push(String::new())
                            }
                            Err(error) => return Err(error.to_string()),
                        }
                    }
                }
                let remove = piece.range.end - base;
                buffer.drain(..remove);
                base = piece.range.end;
            }
        }
        if closed {
            break;
        }
        tokio::select! { _=cancel.cancelled()=>return Err("Cancelled".into()), _=tokio::time::sleep(Duration::from_millis(25))=>{} }
    }
    Ok(Progress { planner, text })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::path::Path;
    async fn fixture() -> (tempfile::TempDir, Host, AnalysisHost) {
        let directory = tempfile::tempdir().unwrap();
        // Never rewrite a script that the parallel test runner may execute.
        let executable =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/dictation-worker.py");
        let host = Arc::new(Mutex::new(WorkerHost::new(
            executable.clone(),
            directory.path().into(),
        )));
        let mut analysis = AnalysisHost::new(executable, directory.path().into());
        analysis
            .prepare_vad(directory.path(), &CancellationToken::new())
            .await
            .unwrap();
        (directory, host, analysis)
    }
    #[tokio::test]
    async fn transcribes_before_release_reuses_one_worker_and_finishes_only_the_tail() {
        let (directory, host, mut analysis) = fixture().await;
        let (tx, rx) = std::sync::mpsc::sync_channel(32);
        let token = CancellationToken::new();
        let background_host = host.clone();
        let background_token = token.clone();
        let path = directory.path().to_path_buf();
        let task = tokio::spawn(async move {
            let result = run_ready(
                &background_host,
                rx,
                "moss",
                &path,
                &mut analysis,
                &background_token,
                &std::sync::Mutex::new(None),
            )
            .await;
            analysis.stop().await;
            result.ok()
        });
        let mut samples = vec![0.2; 8 * 16_000];
        samples.extend(vec![0.; 16_000]);
        for packet in samples.chunks(16_000) {
            tx.send(packet.to_vec()).unwrap();
        }
        tokio::time::timeout(Duration::from_secs(5), async {
            while !directory.path().join("calls").exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        // The capture channel remains open: inference already happened while speaking.
        let tail = vec![0.4; 4 * 16_000];
        for packet in tail.chunks(16_000) {
            tx.send(packet.to_vec()).unwrap();
        }
        samples.extend(tail);
        drop(tx);
        let session = Session {
            finished: CancellationToken::new(),
            cancel: token.clone(),
            task: Some(task),
        };
        let text = session
            .finish(&samples, &host, "moss", directory.path(), &token)
            .await
            .unwrap();
        assert_eq!(text, "speech0.2 speech0.4");
        let calls = std::fs::read_to_string(directory.path().join("calls")).unwrap();
        let pids = calls.lines().collect::<Vec<_>>();
        assert_eq!(pids.len(), 2);
        assert_eq!(pids[0], pids[1]);
        host.lock().await.stop().await;
    }
    #[tokio::test]
    async fn observer_loss_forces_complete_recording_fallback() {
        let (directory, host, mut analysis) = fixture().await;
        let (tx, rx) = std::sync::mpsc::sync_channel(32);
        let token = CancellationToken::new();
        let mut samples = vec![0.2; 8 * 16_000];
        samples.extend(vec![0.; 16_000]);
        for packet in samples.chunks(16_000) {
            tx.send(packet.to_vec()).unwrap();
        }
        drop(tx);
        let result = run_ready(
            &host,
            rx,
            "moss",
            directory.path(),
            &mut analysis,
            &token,
            &std::sync::Mutex::new(None),
        )
        .await
        .unwrap();
        analysis.stop().await;
        let session = Session {
            finished: CancellationToken::new(),
            cancel: token.clone(),
            task: Some(tokio::spawn(async move { Some(result) })),
        };
        samples.extend(vec![0.4; 16_000]);
        assert!(session
            .finish(&samples, &host, "moss", directory.path(), &token)
            .await
            .is_none());
        host.lock().await.stop().await;
    }
}
