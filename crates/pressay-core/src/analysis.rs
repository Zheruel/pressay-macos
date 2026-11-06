//! Local streaming voice activity and optional final speaker separation.
//! Meeting audio is private, temporary PCM on disk; the isolated worker maps it
//! read-only. A checked-in patch computes bounded Sortformer mel windows;
//! speaker cache stays bounded, while compact probabilities grow with duration.
use crate::{catalog::Model, Error, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use std::{
    io::{Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    process::Stdio,
    sync::OnceLock,
    time::Duration,
};
use tempfile::NamedTempFile;
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStdin, ChildStdout, Command},
};
use tokio_util::sync::CancellationToken;
pub const MAX_DIARIZATION_SECONDS: u64 = 8 * 60 * 60;
pub const MAX_MEETING_SECONDS: u64 = 8 * 60 * 60;
pub const SPEAKER_DURATION_WARNING: &str = "Optional speaker separation supports recordings up to eight hours. Your transcript is still available without separated speakers.";
const RATE: u64 = 16_000;
const MAX_REPLY: u64 = 32 * 1024 * 1024;
pub fn models() -> &'static [Model] {
    static MODELS: OnceLock<Vec<Model>> = OnceLock::new();
    MODELS.get_or_init(|| {
        serde_json::from_str(include_str!("analysis_catalog.json"))
            .expect("checked-in analysis catalog")
    })
}
pub fn find(id: &str) -> Result<&'static Model> {
    models()
        .iter()
        .find(|model| model.id == id)
        .ok_or_else(|| Error::Message(format!("Unknown analysis model: {id}")))
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VadResult {
    pub first_frame: u64,
    pub frame_samples: usize,
    pub probabilities: Vec<f32>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpeakerSegment {
    pub start: f64,
    pub end: f64,
    pub speaker: u32,
    pub confidence: Option<f32>,
}
/// A private temporary file owned until this guard is dropped. Append in the
/// common capture timeline; gaps become sparse zeros, overlap is rejected.
/// Call seal before giving its path to the worker, then retain this guard until
/// inference finishes/cancels. No long-lived saved meeting audio is created.
pub struct MeetingSpool {
    file: NamedTempFile,
    // Drop audio before releasing the lifetime lock. Windows byte-range locks
    // deny reads through other handles, so the lock must never cover the PCM.
    _lifetime: NamedTempFile,
    frames: u64,
    limit: u64,
    sealed: bool,
}
impl MeetingSpool {
    pub fn new(directory: &Path, max_duration: Duration) -> Result<Self> {
        if max_duration.is_zero() || max_duration > Duration::from_secs(MAX_MEETING_SECONDS) {
            return Err(Error::Message(
                "Meeting duration must be within eight hours".into(),
            ));
        }
        let limit = (max_duration.as_secs_f64() * RATE as f64).floor() as u64;
        let lifetime = tempfile::Builder::new()
            .prefix(".pressay-meeting-")
            .suffix(".pending")
            .tempfile_in(directory)?;
        lifetime
            .as_file()
            .try_lock()
            .map_err(|e| Error::Message(format!("Could not lock private meeting audio: {e}")))?;
        let path = directory.join(format!(".pressay-meeting-{}", uuid::Uuid::new_v4()));
        // Publish the locked sidecar first. A concurrent cleanup either cannot
        // see this spool yet or sees its held lock, including during creation.
        let lifetime = publish_spool_file(lifetime, path.with_extension("lock"))?;
        let file = tempfile::Builder::new()
            .prefix(".pressay-meeting-")
            .suffix(".pending")
            .tempfile_in(directory)?;
        let file = publish_spool_file(file, path.with_extension("f32"))?;
        Ok(Self {
            file,
            _lifetime: lifetime,
            frames: 0,
            limit,
            sealed: false,
        })
    }
    pub fn append(&mut self, start_seconds: f64, samples: &[f32]) -> Result<()> {
        if self.sealed
            || !start_seconds.is_finite()
            || start_seconds < 0.
            || samples.len() > 160_000
            || samples.iter().any(|s| !s.is_finite())
        {
            return Err(Error::Message("Invalid or sealed meeting audio".into()));
        }
        let start = (start_seconds * RATE as f64).round() as u64;
        let end = start
            .checked_add(samples.len() as u64)
            .ok_or_else(|| Error::Message("Meeting audio is too long".into()))?;
        if start < self.frames || end > self.limit {
            return Err(Error::Message(
                "Meeting audio overlaps or exceeds the duration limit".into(),
            ));
        }
        if samples.is_empty() {
            return Ok(());
        }
        self.file.as_file_mut().seek(SeekFrom::Start(start * 4))?;
        let bytes: Vec<_> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        self.file.write_all(&bytes)?;
        self.frames = end;
        Ok(())
    }
    pub fn duration(&self) -> Duration {
        Duration::from_secs_f64(self.frames as f64 / RATE as f64)
    }
    pub fn seal(&mut self) -> Result<PathBuf> {
        if self.frames == 0 {
            return Err(Error::Message(
                "No system audio available for speaker separation".into(),
            ));
        }
        self.file.as_file_mut().sync_all()?;
        self.sealed = true;
        Ok(self.file.path().to_path_buf())
    }
}
fn publish_spool_file(file: NamedTempFile, path: PathBuf) -> Result<NamedTempFile> {
    let guard = tempfile::TempPath::try_from_path(path)?;
    let file = file
        .persist_noclobber(&guard)
        .map_err(|e| Error::Io(e.error))?;
    Ok(NamedTempFile::from_parts(file, guard))
}
/// Remove crash leftovers without deleting another process's active capture.
/// Only our private temporary naming pattern and regular files are considered;
/// a held sidecar lock is the lifetime marker, released automatically on crash.
/// Also honor PCM locks held by older versions of the application.
pub fn cleanup_stale_spools(directory: &Path) -> Result<usize> {
    let mut removed = 0;
    let mut stems = std::collections::BTreeSet::new();
    for entry in std::fs::read_dir(directory)? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if !name.starts_with(".pressay-meeting-") || !entry.file_type()?.is_file() {
            continue;
        }
        if let Some(stem) = name
            .strip_suffix(".f32")
            .or_else(|| name.strip_suffix(".lock"))
        {
            stems.insert(stem.to_owned());
        }
    }
    for stem in stems {
        let path = directory.join(format!("{stem}.f32"));
        let lock_path = directory.join(format!("{stem}.lock"));
        // Missing sidecars are legitimate legacy spools; non-regular sidecars
        // are never followed or removed. Keep both handles until unlink ends.
        let Some(_lifetime) = lock_stale_spool_file(&lock_path)? else {
            continue;
        };
        let Some(_legacy_audio) = lock_stale_spool_file(&path)? else {
            continue;
        };
        if remove_spool_file(&path)? {
            removed += 1;
        }
        remove_spool_file(&lock_path)?;
    }
    Ok(removed)
}

// Outer None means held lock or an unsafe file: leave the entire pair alone.
// Some(None) means absent, needed for old-format audio and orphan sidecars.
fn lock_stale_spool_file(path: &Path) -> Result<Option<Option<std::fs::File>>> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.file_type().is_file() => return Ok(None),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Some(None)),
        // Windows can report access denied for another cleaner's delete-pending
        // handle. Leave it alone; never replace/recreate a lock under that name.
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => return Ok(None),
        Err(error) => return Err(error.into()),
        Ok(_) => {}
    }
    let file = match std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Some(None)),
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    match file.try_lock() {
        Ok(()) => Ok(Some(Some(file))),
        Err(std::fs::TryLockError::WouldBlock) => Ok(None),
        Err(std::fs::TryLockError::Error(error)) => Err(error.into()),
    }
}
fn remove_spool_file(path: &Path) -> Result<bool> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error.into()),
    }
}

struct Resident {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    mode: &'static str,
    model: PathBuf,
}
impl Resident {
    async fn reply(&mut self) -> Result<serde_json::Value> {
        let mut line = Vec::new();
        let count = (&mut self.stdout)
            .take(MAX_REPLY + 1)
            .read_until(b'\n', &mut line)
            .await?;
        if count == 0 || count as u64 > MAX_REPLY || line.last() != Some(&b'\n') {
            return Err(Error::Message(
                "Analysis worker stopped or sent an invalid response".into(),
            ));
        }
        let value: serde_json::Value = serde_json::from_slice(&line)?;
        if let Some(error) = value.get("error").and_then(|v| v.as_str()) {
            return Err(Error::Message(error.into()));
        }
        Ok(value)
    }
}
/// One process at a time. Cancellation and timeouts kill and reap it. Dropping
/// an in-flight future requires stop() before reuse; dropping this host also
/// kills its child (Tokio's process reaper collects it).
pub struct AnalysisHost {
    executable: PathBuf,
    runtime: PathBuf,
    resident: Option<Resident>,
}
impl AnalysisHost {
    pub fn new(executable: PathBuf, runtime: PathBuf) -> Self {
        Self {
            executable,
            runtime,
            resident: None,
        }
    }
    pub async fn stop(&mut self) {
        if let Some(mut resident) = self.resident.take() {
            let _ = resident.child.kill().await;
            let _ = resident.child.wait().await;
        }
    }
    async fn load(&mut self, mode: &'static str, model: &Path) -> Result<()> {
        if let Some(resident) = self.resident.as_mut() {
            if resident.mode == mode
                && resident.model == model
                && resident.child.try_wait()?.is_none()
            {
                return Ok(());
            }
        }
        self.stop().await;
        let mut child = Command::new(&self.executable)
            .arg(mode)
            .arg(model)
            .arg(&self.runtime)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| Error::Message("Missing analysis input".into()))?;
        let stdout = BufReader::new(
            child
                .stdout
                .take()
                .ok_or_else(|| Error::Message("Missing analysis output".into()))?,
        );
        self.resident = Some(Resident {
            child,
            stdin,
            stdout,
            mode,
            model: model.into(),
        });
        let reply = self.resident.as_mut().unwrap().reply().await?;
        if reply.get("ready").and_then(|v| v.as_bool()) != Some(true)
            || reply.get("frame_samples").and_then(|v| v.as_u64()) != Some(512)
        {
            return Err(Error::Message("Analysis model did not become ready".into()));
        }
        Ok(())
    }
    pub async fn prepare_vad(&mut self, model: &Path, cancel: &CancellationToken) -> Result<()> {
        let result = tokio::select! {biased; _ = cancel.cancelled() => Err(Error::Cancelled), result = tokio::time::timeout(Duration::from_secs(180), self.load("vad", model)) => result.unwrap_or_else(|_| Err(Error::Message("Voice detection model timed out".into())))};
        if result.is_err() {
            self.stop().await;
        }
        result
    }
    async fn request(&mut self, value: serde_json::Value) -> Result<serde_json::Value> {
        let resident = self
            .resident
            .as_mut()
            .ok_or_else(|| Error::Message("Analysis model is not loaded".into()))?;
        let mut bytes = serde_json::to_vec(&value)?;
        bytes.push(b'\n');
        resident.stdin.write_all(&bytes).await?;
        resident.stdin.flush().await?;
        let reply = resident.reply().await?;
        reply
            .get("result")
            .cloned()
            .ok_or_else(|| Error::Message("Missing analysis result".into()))
    }
    async fn vad_request(
        &mut self,
        value: serde_json::Value,
        cancel: &CancellationToken,
    ) -> Result<VadResult> {
        let result = tokio::select! {biased; _ = cancel.cancelled() => Err(Error::Cancelled), result = tokio::time::timeout(Duration::from_secs(20), self.request(value)) => result.unwrap_or_else(|_| Err(Error::Message("Voice detection timed out".into())))};
        let result = result.and_then(|value| {
            let result: VadResult = serde_json::from_value(value)?;
            if result.frame_samples != 512
                || result.probabilities.len() > 314
                || result
                    .probabilities
                    .iter()
                    .any(|p| !p.is_finite() || !(0.0..=1.0).contains(p))
            {
                return Err(Error::Message("Invalid voice detection result".into()));
            }
            Ok(result)
        });
        if result.is_err() {
            self.stop().await;
        }
        result
    }
    pub async fn classify(
        &mut self,
        track: u8,
        pcm: &[f32],
        cancel: &CancellationToken,
    ) -> Result<VadResult> {
        if track > 1 || pcm.is_empty() || pcm.len() > 160_000 || pcm.iter().any(|v| !v.is_finite())
        {
            return Err(Error::Message("Invalid VAD track or audio".into()));
        }
        let bytes: Vec<_> = pcm.iter().flat_map(|v| v.to_le_bytes()).collect();
        self.vad_request(
            serde_json::json!({"op":"feed","track":track,"pcm":STANDARD.encode(bytes)}),
            cancel,
        )
        .await
    }
    pub async fn flush_vad(&mut self, track: u8, cancel: &CancellationToken) -> Result<VadResult> {
        self.vad_request(serde_json::json!({"op":"flush","track":track}), cancel)
            .await
    }
    pub async fn reset_vad(&mut self, track: u8, cancel: &CancellationToken) -> Result<()> {
        self.vad_request(serde_json::json!({"op":"reset","track":track}), cancel)
            .await
            .map(|_| ())
    }
    pub async fn diarize(
        &mut self,
        model: &Path,
        pcm_file: &Path,
        cancel: &CancellationToken,
    ) -> Result<Vec<SpeakerSegment>> {
        let bytes = tokio::fs::metadata(pcm_file).await?.len();
        if bytes == 0 || bytes % 4 != 0 {
            return Err(Error::Message("Invalid meeting audio file".into()));
        }
        if bytes / 4 > MAX_DIARIZATION_SECONDS * RATE {
            return Err(Error::Message(SPEAKER_DURATION_WARNING.into()));
        }
        let duration = bytes as f64 / 64000.;
        let operation = async {
            self.load("diarize", model).await?;
            let value = self
                .request(serde_json::json!({"op":"diarize","path":pcm_file}))
                .await?;
            let segments: Vec<SpeakerSegment> = serde_json::from_value(value)?;
            if segments.len() > 100_000
                || segments.iter().any(|s| {
                    !s.start.is_finite()
                        || !s.end.is_finite()
                        || s.start < 0.
                        || s.end <= s.start
                        || s.end > duration + 0.001
                        || !(1..=4).contains(&s.speaker)
                        || s.confidence.is_some_and(|p| !p.is_finite())
                })
            {
                return Err(Error::Message("Invalid speaker separation result".into()));
            }
            Ok(segments)
        };
        // Bounded inference time, with immediate user cancellation throughout load/run.
        let timeout = Duration::from_secs_f64((duration * 2.).clamp(180., 7200.));
        let result = tokio::select! {biased; _ = cancel.cancelled() => Err(Error::Cancelled), result = tokio::time::timeout(timeout, operation) => result.unwrap_or_else(|_| Err(Error::Message("Optional speaker separation timed out; transcript is still available".into())))};
        self.stop().await;
        result
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn spool_preserves_timeline_is_private_and_disappears() {
        let dir = tempfile::tempdir().unwrap();
        let mut spool = MeetingSpool::new(dir.path(), Duration::from_secs(3)).unwrap();
        spool.append(0., &[0.25, -0.25]).unwrap();
        spool.append(1., &[0.75]).unwrap();
        assert!(spool.append(0.1, &[1.]).is_err());
        let path = spool.seal().unwrap();
        let lock_path = path.with_extension("lock");
        assert!(lock_path.exists());
        assert!(spool.append(2., &[1.]).is_err());
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(bytes.len(), 16001 * 4);
        assert!(bytes[8..64000].iter().all(|b| *b == 0));
        assert_eq!(&bytes[64000..], &0.75f32.to_le_bytes());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
            assert_eq!(
                std::fs::metadata(&lock_path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        drop(spool);
        assert!(!path.exists());
        assert!(!lock_path.exists());
    }
    #[test]
    fn stale_cleanup_preserves_active_and_unrelated_files() {
        let dir = tempfile::tempdir().unwrap();
        let mut active = MeetingSpool::new(dir.path(), Duration::from_secs(3)).unwrap();
        active.append(0., &[0.1]).unwrap();
        let active_path = active.seal().unwrap();
        let orphan = dir.path().join(".pressay-meeting-crashed.f32");
        std::fs::write(&orphan, [1, 2, 3, 4]).unwrap();
        let unrelated = dir.path().join("user-audio.f32");
        std::fs::write(&unrelated, [9]).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&unrelated, dir.path().join(".pressay-meeting-link.f32"))
            .unwrap();
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 1);
        assert!(active_path.exists());
        assert!(!orphan.exists());
        assert_eq!(std::fs::read(unrelated).unwrap(), vec![9]);
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 0);
    }
    #[test]
    fn sidecar_publish_and_legacy_locks_protect_spools() {
        let dir = tempfile::tempdir().unwrap();
        // This is the publication window: the locked sidecar is visible but
        // the PCM has not been published. Cleanup must keep its lock identity.
        let lock_path = dir.path().join(".pressay-meeting-publishing.lock");
        let lock = std::fs::File::create(&lock_path).unwrap();
        lock.try_lock().unwrap();
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 0);
        assert!(lock_path.exists());
        let audio_path = lock_path.with_extension("f32");
        std::fs::write(&audio_path, [1, 2, 3, 4]).unwrap();
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 0);
        assert_eq!(std::fs::read(&audio_path).unwrap(), [1, 2, 3, 4]);
        drop(lock);
        // Two cleanup processes may observe this same stale pair. Once the
        // lifetime lock is held, a second cleaner cannot unlink either file.
        let first_cleanup = lock_stale_spool_file(&lock_path).unwrap().unwrap().unwrap();
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 0);
        assert!(audio_path.exists());
        drop(first_cleanup);
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 1);
        assert!(!lock_path.exists());

        let legacy_path = dir.path().join(".pressay-meeting-legacy.f32");
        let legacy = std::fs::File::create(&legacy_path).unwrap();
        legacy.try_lock().unwrap();
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 0);
        assert!(legacy_path.exists());
        drop(legacy);
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 1);

        // Also reclaim an interrupted publication which never reached PCM.
        std::fs::write(&lock_path, []).unwrap();
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 0);
        assert!(!lock_path.exists());
    }
    #[test]
    fn concurrent_cleaners_never_unlink_publishing_or_live_spools() {
        struct StopOnDrop<'a>(&'a std::sync::atomic::AtomicBool);
        impl Drop for StopOnDrop<'_> {
            fn drop(&mut self) {
                self.0.store(true, std::sync::atomic::Ordering::Release);
            }
        }
        let dir = tempfile::tempdir().unwrap();
        let finished = std::sync::atomic::AtomicBool::new(false);
        std::thread::scope(|scope| {
            let _stop = StopOnDrop(&finished);
            for _ in 0..2 {
                scope.spawn(|| {
                    while !finished.load(std::sync::atomic::Ordering::Acquire) {
                        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 0);
                        std::thread::yield_now();
                    }
                });
            }
            for _ in 0..50 {
                let mut spool = MeetingSpool::new(dir.path(), Duration::from_secs(1)).unwrap();
                spool.append(0., &[0.125]).unwrap();
                let path = spool.seal().unwrap();
                assert_eq!(std::fs::read(path).unwrap(), 0.125_f32.to_le_bytes());
                drop(spool);
            }
        });
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    }
    #[cfg(unix)]
    #[test]
    fn sidecar_symlinks_are_not_followed_or_deleted() {
        let dir = tempfile::tempdir().unwrap();
        let audio = dir.path().join(".pressay-meeting-unsafe.f32");
        let target = dir.path().join("unrelated");
        std::fs::write(&audio, [1]).unwrap();
        std::fs::write(&target, [2]).unwrap();
        std::os::unix::fs::symlink(&target, audio.with_extension("lock")).unwrap();
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 0);
        assert_eq!(std::fs::read(&audio).unwrap(), [1]);
        assert_eq!(std::fs::read(&target).unwrap(), [2]);
    }
    // Invoked by the parent test in a separate process, on every supported OS.
    #[test]
    fn spool_process_fixture() {
        let Some(directory) = std::env::var_os("PRESSAY_SPOOL_TEST_DIRECTORY") else {
            return;
        };
        let directory = PathBuf::from(directory);
        let mut spool = MeetingSpool::new(&directory, Duration::from_secs(1)).unwrap();
        spool.append(0., &[0.25, -0.25]).unwrap();
        let path = spool.seal().unwrap();
        std::fs::write(directory.join("ready.pending"), path.to_str().unwrap()).unwrap();
        std::fs::rename(directory.join("ready.pending"), directory.join("ready")).unwrap();
        // The test deliberately kills this owner to exercise automatic OS lock
        // release after a crash, without running NamedTempFile destructors.
        loop {
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    #[test]
    fn another_process_reads_live_pcm_and_cleanup_waits_for_owner_exit() {
        struct Child(std::process::Child);
        impl Drop for Child {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let dir = tempfile::tempdir().unwrap();
        let mut child = Child(
            std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "analysis::tests::spool_process_fixture",
                    "--nocapture",
                ])
                .env("PRESSAY_SPOOL_TEST_DIRECTORY", dir.path())
                .stdout(std::process::Stdio::null())
                .spawn()
                .unwrap(),
        );
        let ready = dir.path().join("ready");
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        while !ready.exists() {
            assert!(
                child.0.try_wait().unwrap().is_none(),
                "Spool owner exited early"
            );
            assert!(
                std::time::Instant::now() < deadline,
                "Spool owner never became ready"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        let path = PathBuf::from(std::fs::read_to_string(ready).unwrap());
        // A separately opened handle in another process was the Windows error33
        // regression: PCM must remain readable while its owner holds the lock.
        assert_eq!(
            std::fs::read(&path).unwrap(),
            [0.25_f32.to_le_bytes(), (-0.25_f32).to_le_bytes()].concat()
        );
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 0);
        assert!(path.exists());
        child.0.kill().unwrap();
        child.0.wait().unwrap();
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 1);
        assert!(!path.exists());
        assert!(!path.with_extension("lock").exists());
        assert_eq!(cleanup_stale_spools(dir.path()).unwrap(), 0);
    }
    #[test]
    fn spool_bounds_and_catalog_are_explicit() {
        let dir = tempfile::tempdir().unwrap();
        assert!(
            MeetingSpool::new(dir.path(), Duration::from_secs(MAX_MEETING_SECONDS + 1)).is_err()
        );
        let mut spool = MeetingSpool::new(dir.path(), Duration::from_secs(1)).unwrap();
        assert!(spool.append(1., &[1.]).is_err());
        assert!(spool.append(0., &[f32::NAN]).is_err());
        assert!(spool.append(f64::INFINITY, &[1.]).is_err());
        assert!(spool.seal().is_err());
        assert_eq!(models().len(), 2);
        for model in models() {
            for artifact in &model.artifacts {
                assert_eq!(artifact.sha256.len(), 64);
                assert_eq!(
                    artifact
                        .url
                        .split("/resolve/")
                        .nth(1)
                        .unwrap()
                        .split('/')
                        .next()
                        .unwrap()
                        .len(),
                    40
                );
            }
        }
    }
    #[tokio::test]
    async fn duration_guard_never_launches_a_worker() {
        let file = NamedTempFile::new().unwrap();
        file.as_file()
            .set_len((MAX_DIARIZATION_SECONDS * RATE + 1) * 4)
            .unwrap();
        let mut host = AnalysisHost::new("not-an-executable".into(), "not-a-runtime".into());
        let error = host
            .diarize(
                Path::new("not-a-model"),
                file.path(),
                &CancellationToken::new(),
            )
            .await
            .unwrap_err()
            .to_string();
        assert_eq!(error, SPEAKER_DURATION_WARNING);
        assert!(host.resident.is_none());
    }
}
