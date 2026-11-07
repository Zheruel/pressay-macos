//! Explicit, additive import from the original Mac app's owned Audio folder.
//! No renderer paths, directory scans for unrelated recordings, or legacy writes.
use crate::workspace::Workspace;
use std::sync::Arc;
use tauri::{AppHandle, State};

#[derive(Debug, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioImportReport {
    pub imported: usize,
    pub already_present: usize,
    pub missing: usize,
    pub unsafe_files: usize,
    pub failed: usize,
    pub cancelled: bool,
    pub source_missing: bool,
}
#[tauri::command]
pub async fn import_mac_audio(
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<AudioImportReport, String> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, state);
        Err("Existing Mac recordings can only be imported on macOS".into())
    }
    #[cfg(target_os = "macos")]
    {
        let job = crate::workspace::NoteJob::start(
            &state,
            "$import-mac-audio",
            &tokio_util::sync::CancellationToken::new(),
        )?;
        let directory = native::legacy_directory()?;
        let result = native::run(
            &state,
            directory,
            &job.token,
            std::path::Path::new("/usr/bin/afconvert"),
            std::time::Duration::from_secs(30),
        )
        .await?;
        state.refresh(&app)?;
        Ok(result)
    }
}
/// Includes converters and bounded source-copy tasks whose IPC caller vanished.
pub async fn wait_for_jobs() {
    #[cfg(any(target_os = "macos", all(test, unix)))]
    native::wait_for_jobs().await;
}

#[cfg(any(target_os = "macos", all(test, unix)))]
mod native {
    use super::*;
    use pressay_core::recordings::MAX_WAV_BYTES;
    use std::{
        ffi::CString,
        fs::{File, OpenOptions},
        io::{Read, Seek, SeekFrom, Write},
        os::{
            fd::{AsRawFd, FromRawFd},
            unix::fs::{MetadataExt, OpenOptionsExt},
        },
        path::{Path, PathBuf},
        process::Stdio,
        sync::{
            atomic::{AtomicUsize, Ordering},
            OnceLock,
        },
        time::Duration,
    };
    use tokio::{
        process::{Child, Command},
        sync::Notify,
    };
    use tokio_util::sync::CancellationToken;
    const MAX_SOURCE: u64 = 64 * 1024 * 1024;
    const MAX_CONVERTED: u64 = (MAX_WAV_BYTES + 65536) as u64;
    #[derive(Default)]
    struct Work {
        count: AtomicUsize,
        changed: Notify,
    }
    fn work() -> &'static Work {
        static WORK: OnceLock<Work> = OnceLock::new();
        WORK.get_or_init(Work::default)
    }
    struct Lease;
    impl Lease {
        fn new() -> Self {
            work().count.fetch_add(1, Ordering::AcqRel);
            Self
        }
    }
    impl Drop for Lease {
        fn drop(&mut self) {
            work().count.fetch_sub(1, Ordering::AcqRel);
            work().changed.notify_waiters();
        }
    }
    pub(super) async fn wait_for_jobs() {
        loop {
            let notified = work().changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if work().count.load(Ordering::Acquire) == 0 {
                return;
            }
            notified.await;
        }
    }
    #[derive(Debug, PartialEq, Eq)]
    enum SourceError {
        Missing,
        Unsafe,
        Cancelled,
        Io,
    }
    fn classify(error: std::io::Error) -> SourceError {
        if error.kind() == std::io::ErrorKind::NotFound {
            SourceError::Missing
        } else if matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR)) {
            SourceError::Unsafe
        } else {
            SourceError::Io
        }
    }
    fn owned(meta: &std::fs::Metadata) -> bool {
        meta.uid() == unsafe { libc::geteuid() }
    }
    fn open_directory(path: &Path) -> Result<File, SourceError> {
        if std::fs::symlink_metadata(path)
            .map_err(classify)?
            .file_type()
            .is_symlink()
        {
            return Err(SourceError::Unsafe);
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC)
            .open(path)
            .map_err(classify)?;
        let meta = file.metadata().map_err(classify)?;
        if !meta.is_dir() || !owned(&meta) {
            return Err(SourceError::Unsafe);
        }
        Ok(file)
    }
    fn open_at(directory: &File, name: &str, is_directory: bool) -> Result<File, SourceError> {
        let name = CString::new(name).map_err(|_| SourceError::Unsafe)?;
        let flags = libc::O_RDONLY
            | libc::O_NOFOLLOW
            | libc::O_CLOEXEC
            | libc::O_NONBLOCK
            | libc::O_NOCTTY
            | if is_directory { libc::O_DIRECTORY } else { 0 };
        let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 {
            return Err(classify(std::io::Error::last_os_error()));
        }
        let file = unsafe { File::from_raw_fd(fd) };
        let meta = file.metadata().map_err(classify)?;
        if !owned(&meta)
            || (is_directory && !meta.is_dir())
            || (!is_directory && (!meta.is_file() || meta.nlink() != 1))
        {
            return Err(SourceError::Unsafe);
        }
        Ok(file)
    }
    #[cfg(target_os = "macos")]
    pub(super) fn legacy_directory() -> Result<Option<File>, String> {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .ok_or("Could not locate the original Mac data folder")?;
        let open = || {
            let mut directory = open_directory(&home)?;
            for name in ["Library", "Application Support", "Pressay", "Audio"] {
                directory = open_at(&directory, name, true)?;
            }
            Ok::<_, SourceError>(directory)
        };
        match open() {
            Ok(directory) => Ok(Some(directory)),
            Err(SourceError::Missing) => Ok(None),
            Err(_) => Err("The original Mac Audio folder could not be opened safely".into()),
        }
    }
    fn source_name(id: &str) -> Result<String, SourceError> {
        let uuid = uuid::Uuid::parse_str(id).map_err(|_| SourceError::Unsafe)?;
        if !id.eq_ignore_ascii_case(&uuid.hyphenated().to_string()) {
            return Err(SourceError::Unsafe);
        }
        Ok(format!("{id}.caf"))
    }
    fn copy_source(
        directory: &File,
        id: &str,
        destination: &Path,
        cancel: &CancellationToken,
    ) -> Result<(), SourceError> {
        if cancel.is_cancelled() {
            return Err(SourceError::Cancelled);
        }
        let mut source = open_at(directory, &source_name(id)?, false)?;
        let before = source.metadata().map_err(classify)?;
        if before.len() < 8 || before.len() > MAX_SOURCE {
            return Err(SourceError::Unsafe);
        }
        let mut magic = [0; 4];
        source.read_exact(&mut magic).map_err(classify)?;
        if &magic != b"caff" {
            return Err(SourceError::Unsafe);
        }
        source.seek(SeekFrom::Start(0)).map_err(classify)?;
        let mut out = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(destination)
            .map_err(classify)?;
        let mut bytes = [0u8; 65536];
        let mut total = 0;
        loop {
            if cancel.is_cancelled() {
                return Err(SourceError::Cancelled);
            }
            let n = source.read(&mut bytes).map_err(classify)?;
            if n == 0 {
                break;
            }
            total += n as u64;
            if total > MAX_SOURCE {
                return Err(SourceError::Unsafe);
            }
            out.write_all(&bytes[..n]).map_err(classify)?;
        }
        let after = source.metadata().map_err(classify)?;
        if total != before.len()
            || before.len() != after.len()
            || before.mtime() != after.mtime()
            || before.mtime_nsec() != after.mtime_nsec()
        {
            return Err(SourceError::Unsafe);
        }
        out.sync_all().map_err(classify)?;
        Ok(())
    }
    struct Converter {
        child: Option<Child>,
        lease: Option<Lease>,
        directory: Arc<tempfile::TempDir>,
    }
    impl Converter {
        fn spawn(program: &Path, directory: Arc<tempfile::TempDir>) -> Result<Self, String> {
            let mut command = Command::new(program);
            command
                .args(["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", "--no-filler"])
                .arg(directory.path().join("input.caf"))
                .arg("-o")
                .arg(directory.path().join("output.wav"))
                .current_dir(directory.path())
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .kill_on_drop(true);
            unsafe {
                command.pre_exec(|| {
                    let file_limit = libc::rlimit {
                        rlim_cur: MAX_CONVERTED as libc::rlim_t,
                        rlim_max: MAX_CONVERTED as libc::rlim_t,
                    };
                    if libc::setrlimit(libc::RLIMIT_FSIZE, &file_limit) != 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
            let child = command
                .spawn()
                .map_err(|_| "Could not start Mac audio conversion".to_string())?;
            Ok(Self {
                child: Some(child),
                lease: Some(Lease::new()),
                directory,
            })
        }
        async fn finish(
            &mut self,
            cancel: &CancellationToken,
            timeout: Duration,
        ) -> Result<(), String> {
            let child = self.child.as_mut().ok_or("Audio converter has closed")?;
            let result = tokio::select! {biased;_=cancel.cancelled()=>Err("Cancelled".into()),result=tokio::time::timeout(timeout,child.wait())=>match result{Ok(Ok(status))if status.success()=>Ok(()),Ok(_)=>Err("Mac audio conversion failed".into()),Err(_)=>Err("Mac audio conversion took too long".into())}};
            if result.is_err() {
                if let Some(child) = self.child.as_mut() {
                    let _ = child.kill().await;
                    let _ = child.wait().await;
                }
            }
            self.child.take();
            result
        }
    }
    impl Drop for Converter {
        fn drop(&mut self) {
            if let Some(mut child) = self.child.take() {
                if child.try_wait().ok().flatten().is_none() {
                    let _ = child.start_kill();
                    if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                        let lease = self.lease.take();
                        let directory = self.directory.clone();
                        runtime.spawn(async move {
                            let _lease = lease;
                            let _directory = directory;
                            let _ = child.wait().await;
                        });
                    }
                }
            }
        }
    }
    pub(super) async fn run(
        workspace: &Workspace,
        directory: Option<File>,
        cancel: &CancellationToken,
        program: &Path,
        timeout: Duration,
    ) -> Result<AudioImportReport, String> {
        let records = workspace
            .store
            .lock()
            .unwrap()
            .history(i64::MAX as usize)
            .map_err(|e| e.to_string())?;
        let mut report = AudioImportReport {
            source_missing: directory.is_none(),
            ..Default::default()
        };
        for record in records {
            if cancel.is_cancelled() {
                report.cancelled = true;
                break;
            }
            if record
                .legacy
                .get("managedAudio")
                .and_then(serde_json::Value::as_bool)
                == Some(true)
            {
                report.already_present += 1;
                continue;
            }
            if source_name(&record.id).is_err()
                || (!record.legacy.is_null() && !record.legacy.is_object())
            {
                report.unsafe_files += 1;
                continue;
            }
            let Some(directory) = &directory else {
                report.missing += 1;
                continue;
            };
            // Existing managed files are never replaced, including a previous
            // interrupted import that did not get to update its database row.
            if workspace.audio.read(&record.id).is_ok() {
                report.already_present += 1;
                continue;
            }
            let temp = Arc::new(
                tempfile::Builder::new()
                    .prefix("pressay-audio-import-")
                    .tempdir()
                    .map_err(|_| "Could not create private conversion files".to_string())?,
            );
            let source = directory
                .try_clone()
                .map_err(|_| "Could not read the original Audio folder".to_string())?;
            let id = record.id.clone();
            let copy_temp = temp.clone();
            let copy_cancel = cancel.clone();
            let lease = Lease::new();
            let copied = tokio::task::spawn_blocking(move || {
                let _lease = lease;
                copy_source(
                    &source,
                    &id,
                    &copy_temp.path().join("input.caf"),
                    &copy_cancel,
                )
            })
            .await
            .map_err(|_| "Could not copy an existing recording".to_string())?;
            match copied {
                Ok(()) => {}
                Err(SourceError::Missing) => {
                    report.missing += 1;
                    continue;
                }
                Err(SourceError::Unsafe) => {
                    report.unsafe_files += 1;
                    continue;
                }
                Err(SourceError::Cancelled) => {
                    report.cancelled = true;
                    break;
                }
                Err(_) => {
                    report.failed += 1;
                    continue;
                }
            }
            if cancel.is_cancelled() {
                report.cancelled = true;
                break;
            }
            let mut converter = match Converter::spawn(program, temp.clone()) {
                Ok(process) => process,
                Err(_) => {
                    report.failed += 1;
                    continue;
                }
            };
            if converter.finish(cancel, timeout).await.is_err() {
                if cancel.is_cancelled() {
                    report.cancelled = true;
                    break;
                }
                report.failed += 1;
                continue;
            }
            let converted = temp.path().join("output.wav");
            let bytes = match std::fs::symlink_metadata(&converted) {
                Ok(meta)
                    if meta.is_file()
                        && !meta.file_type().is_symlink()
                        && meta.len() <= MAX_CONVERTED =>
                {
                    std::fs::read(&converted)
                }
                _ => {
                    report.failed += 1;
                    continue;
                }
            };
            let bytes = match bytes {
                Ok(bytes) => bytes,
                Err(_) => {
                    report.failed += 1;
                    continue;
                }
            };
            if cancel.is_cancelled() {
                report.cancelled = true;
                break;
            }
            let store = workspace.store.lock().unwrap();
            let mut current = match store.dictation(&record.id) {
                Ok(record) => record,
                Err(_) => {
                    report.failed += 1;
                    continue;
                }
            };
            if current
                .legacy
                .get("managedAudio")
                .and_then(serde_json::Value::as_bool)
                == Some(true)
            {
                report.already_present += 1;
                continue;
            }
            match workspace.audio.import_wav(&record.id, &bytes) {
                Ok(true) => {}
                Ok(false) => {
                    report.already_present += 1;
                    continue;
                }
                Err(_) => {
                    report.failed += 1;
                    continue;
                }
            }
            if current.legacy.is_null() {
                current.legacy = serde_json::json!({});
            }
            let Some(metadata) = current.legacy.as_object_mut() else {
                let _ = workspace.audio.remove(&record.id);
                report.failed += 1;
                continue;
            };
            metadata.insert("managedAudio".into(), serde_json::json!(true));
            if store.update_dictation(&current).is_err() {
                let _ = workspace.audio.remove(&record.id);
                report.failed += 1;
                continue;
            }
            report.imported += 1;
        }
        Ok(report)
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use pressay_core::{recordings::wav, storage::Dictation};
        fn workspace(dir: &Path) -> Arc<Workspace> {
            Workspace::new(dir.join("new-app")).unwrap()
        }
        fn record(workspace: &Workspace, id: &str) {
            workspace
                .store
                .lock()
                .unwrap()
                .add(&Dictation {
                    id: id.into(),
                    created_at: pressay_core::storage::now(),
                    duration: 1.,
                    model: "legacy".into(),
                    raw: "public fixture".into(),
                    text: "public fixture".into(),
                    correction: Some("keep correction".into()),
                    pinned: true,
                    target: None,
                    latency: 0.,
                    legacy: serde_json::json!({"audioPath":"must not follow renderer paths"}),
                })
                .unwrap();
        }
        fn fake_caf(path: &Path) {
            std::fs::write(path, b"caff\0\x01\0\0fixture").unwrap();
        }
        #[test]
        fn sources_reject_traversal_symlinks_hardlinks_and_non_caf() {
            let directory = tempfile::tempdir().unwrap();
            let source = open_directory(directory.path()).unwrap();
            let output = tempfile::tempdir().unwrap();
            let id = uuid::Uuid::new_v4().to_string();
            let path = directory.path().join(format!("{id}.caf"));
            let cancel = CancellationToken::new();
            assert_eq!(
                copy_source(&source, "../secret", &output.path().join("bad"), &cancel),
                Err(SourceError::Unsafe)
            );
            let outside = tempfile::NamedTempFile::new().unwrap();
            fake_caf(outside.path());
            std::os::unix::fs::symlink(outside.path(), &path).unwrap();
            assert_eq!(
                copy_source(&source, &id, &output.path().join("symlink"), &cancel),
                Err(SourceError::Unsafe)
            );
            std::fs::remove_file(&path).unwrap();
            std::fs::hard_link(outside.path(), &path).unwrap();
            assert_eq!(
                copy_source(&source, &id, &output.path().join("hardlink"), &cancel),
                Err(SourceError::Unsafe)
            );
            std::fs::remove_file(&path).unwrap();
            std::fs::write(&path, b"not a CAF recording").unwrap();
            assert_eq!(
                copy_source(&source, &id, &output.path().join("not-caf"), &cancel),
                Err(SourceError::Unsafe)
            );
            std::fs::remove_file(&path).unwrap();
            let fifo = CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
            assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
            assert_eq!(
                copy_source(&source, &id, &output.path().join("fifo"), &cancel),
                Err(SourceError::Unsafe)
            );
            std::fs::remove_file(&path).unwrap();
            fake_caf(&path);
            copy_source(&source, &id, &output.path().join("safe"), &cancel).unwrap();
            assert_eq!(
                std::fs::read(&path).unwrap(),
                std::fs::read(output.path().join("safe")).unwrap()
            );
        }
        fn fake_converter(directory: &Path, delay: bool) -> PathBuf {
            use std::os::unix::fs::PermissionsExt;
            let executable = directory.join("converter-fixture");
            let script = if delay {
                r#"#!/usr/bin/env python3
import os,time
open('pid','w').write(str(os.getpid()))
time.sleep(60)
"#
                .to_string()
            } else {
                let bytes = wav(&[0., 0.25, -0.25]);
                format!("#!/usr/bin/env python3\nimport sys\nopen(sys.argv[-1],'wb').write(bytes({bytes:?}))\n")
            };
            std::fs::write(&executable, script).unwrap();
            std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
            executable
        }
        #[tokio::test]
        async fn migration_is_additive_preserves_source_and_existing_record_edits() {
            let directory = tempfile::tempdir().unwrap();
            let old = directory.path().join("old");
            std::fs::create_dir(&old).unwrap();
            let workspace = workspace(directory.path());
            let id = uuid::Uuid::new_v4().to_string();
            record(&workspace, &id);
            let source = old.join(format!("{id}.caf"));
            fake_caf(&source);
            let before = std::fs::read(&source).unwrap();
            let program = fake_converter(directory.path(), false);
            let cancel = CancellationToken::new();
            let report = run(
                &workspace,
                Some(open_directory(&old).unwrap()),
                &cancel,
                &program,
                Duration::from_secs(3),
            )
            .await
            .unwrap();
            assert_eq!(report.imported, 1);
            assert_eq!(workspace.audio.read(&id).unwrap(), wav(&[0., 0.25, -0.25]));
            assert_eq!(std::fs::read(&source).unwrap(), before);
            let record = workspace.store.lock().unwrap().dictation(&id).unwrap();
            assert!(record.pinned);
            assert_eq!(record.correction.as_deref(), Some("keep correction"));
            assert_eq!(record.legacy["managedAudio"], true);
            assert_eq!(record.legacy["audioPath"], "must not follow renderer paths");
            let second = run(
                &workspace,
                Some(open_directory(&old).unwrap()),
                &cancel,
                &program,
                Duration::from_secs(3),
            )
            .await
            .unwrap();
            assert_eq!(second.imported, 0);
            assert_eq!(second.already_present, 1);
        }
        #[tokio::test]
        async fn cancellation_timeout_and_dropped_converter_reap_owned_child() {
            let directory = tempfile::tempdir().unwrap();
            let program = fake_converter(directory.path(), true);
            for mode in ["cancel", "timeout", "drop"] {
                let temp = Arc::new(tempfile::tempdir().unwrap());
                fake_caf(&temp.path().join("input.caf"));
                let mut converter = Converter::spawn(&program, temp.clone()).unwrap();
                let token = CancellationToken::new();
                tokio::time::timeout(Duration::from_secs(3), async {
                    while !temp.path().join("pid").exists() {
                        tokio::time::sleep(Duration::from_millis(5)).await;
                    }
                })
                .await
                .unwrap();
                let pid = std::fs::read_to_string(temp.path().join("pid")).unwrap();
                match mode {
                    "cancel" => {
                        token.cancel();
                        assert!(converter
                            .finish(&token, Duration::from_secs(3))
                            .await
                            .is_err());
                        drop(converter);
                    }
                    "timeout" => {
                        assert!(converter
                            .finish(&token, Duration::from_millis(30))
                            .await
                            .is_err());
                        drop(converter);
                    }
                    _ => drop(converter),
                }
                tokio::time::timeout(Duration::from_secs(5), wait_for_jobs())
                    .await
                    .unwrap();
                let status = Command::new("kill")
                    .args(["-0", &pid])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .await
                    .unwrap();
                assert!(!status.success());
            }
        }
        #[tokio::test]
        async fn conversion_file_size_limit_prevents_unbounded_output() {
            use std::os::unix::fs::PermissionsExt;
            let directory = tempfile::tempdir().unwrap();
            let program = directory.path().join("oversized-converter");
            std::fs::write(
                &program,
                format!(
                    "#!/usr/bin/env python3\nimport sys\nopen(sys.argv[-1], 'wb').truncate({})\n",
                    MAX_CONVERTED + 1
                ),
            )
            .unwrap();
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
            let temp = Arc::new(tempfile::tempdir().unwrap());
            fake_caf(&temp.path().join("input.caf"));
            let mut converter = Converter::spawn(&program, temp.clone()).unwrap();
            assert!(converter
                .finish(&CancellationToken::new(), Duration::from_secs(3))
                .await
                .is_err());
            assert!(
                std::fs::metadata(temp.path().join("output.wav"))
                    .unwrap()
                    .len()
                    <= MAX_CONVERTED
            );
        }
        #[cfg(target_os = "macos")]
        #[tokio::test]
        async fn actual_afconvert_imports_only_a_generated_public_fixture() {
            let directory = tempfile::tempdir().unwrap();
            let old = directory.path().join("old");
            std::fs::create_dir(&old).unwrap();
            let workspace = workspace(directory.path());
            let id = uuid::Uuid::new_v4().to_string();
            record(&workspace, &id);
            let input = directory.path().join("generated.wav");
            std::fs::write(&input, wav(&vec![0.125; 1600])).unwrap();
            let source = old.join(format!("{id}.caf"));
            let status = Command::new("/usr/bin/afconvert")
                .args(["-f", "caff", "-d", "LEI16@16000", "-c", "1"])
                .arg(&input)
                .arg(&source)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .await
                .unwrap();
            assert!(status.success());
            let original = std::fs::read(&source).unwrap();
            let report = run(
                &workspace,
                Some(open_directory(&old).unwrap()),
                &CancellationToken::new(),
                Path::new("/usr/bin/afconvert"),
                Duration::from_secs(5),
            )
            .await
            .unwrap();
            assert_eq!(report.imported, 1);
            let bytes = workspace.audio.read(&id).unwrap();
            assert_eq!(bytes.len(), 44 + 1600 * 2);
            assert_eq!(std::fs::read(&source).unwrap(), original);
        }
    }
}
