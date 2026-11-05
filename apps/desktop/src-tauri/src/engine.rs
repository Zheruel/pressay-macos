use crate::{audio::Capture, platform};
use pressay_core::{
    catalog, download,
    onboarding::{Practice, Readiness},
    storage::{self, Dictation, Store},
    vocabulary,
    worker::WorkerHost,
};
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Instant,
};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::{mpsc, oneshot, Notify};
use tokio_util::sync::CancellationToken;

type Reply = oneshot::Sender<Result<(), String>>;
pub enum Command {
    Prepare(String),
    Start,
    Stop,
    Cancel,
    CaptureEnded,
    Settings(Value, Reply),
    Complete(String, Reply),
    Delete(String, Reply),
    Import(String, Reply),
}
struct Queued {
    generation: u64,
    command: Command,
}
#[derive(Clone, Serialize)]
pub struct ViewState {
    pub stage: String,
    pub error: Option<String>,
    pub model_ready: bool,
    pub progress: Option<download::Progress>,
    pub settings: Value,
    pub history: Vec<Dictation>,
    pub notes: Vec<Value>,
    pub practice: Practice,
    pub first_sample_ms: Option<f64>,
    pub release_to_text_ms: Option<f64>,
}
pub struct Shared {
    pub view: Mutex<ViewState>,
    tx: mpsc::Sender<Queued>,
    pub cancel: Mutex<CancellationToken>,
    generation: AtomicU64,
    start_pending: AtomicBool,
    cancel_wake: Notify,
    shutdown: CancellationToken,
    stopped: CancellationToken,
    pub microphone_worked: AtomicBool,
    pub shortcut_registered: AtomicBool,
}
impl Shared {
    pub fn send(&self, cmd: Command) -> Result<(), String> {
        let generation = self.generation.load(Ordering::Acquire);
        if self.shutdown.is_cancelled() {
            return Err("Pressay is shutting down".into());
        }
        if matches!(cmd, Command::Cancel) {
            self.cancel();
            return Ok(());
        }
        let is_start = matches!(cmd, Command::Start);
        let is_stop = matches!(cmd, Command::Stop);
        let is_prepare = matches!(cmd, Command::Prepare(_));
        // Claim startup before enqueueing. Repeated key-down events must not queue
        // microphone sessions that start after the matching key-up has passed.
        if is_start {
            if self.start_pending.swap(true, Ordering::AcqRel) {
                return Ok(());
            }
            let mut view = self.view.lock().unwrap();
            if view.stage != "idle" || !view.model_ready {
                self.start_pending.store(false, Ordering::Release);
                return Err(
                    "Prepare the speech model and finish the current operation first".into(),
                );
            }
            view.stage = "starting".into();
        }
        if is_prepare {
            let mut view = self.view.lock().unwrap();
            if view.stage != "idle" {
                return Err("Finish the current operation before changing models".into());
            }
            view.stage = "preparing".into();
        }
        let queued = Queued {
            generation,
            command: cmd,
        };
        if self.tx.try_send(queued).is_err() {
            if is_start {
                self.start_pending.store(false, Ordering::Release);
                self.view.lock().unwrap().stage = "idle".into();
            }
            if is_prepare {
                self.view.lock().unwrap().stage = "idle".into();
            }
            if is_stop {
                // Losing a key release must never leave the microphone recording.
                self.cancel();
                return Err("Command queue filled; the recording was cancelled".into());
            }
            return Err("Pressay is busy; wait for the current operation".into());
        }
        Ok(())
    }
    pub fn cancel(&self) {
        self.generation.fetch_add(1, Ordering::AcqRel);
        self.cancel.lock().unwrap().cancel();
        self.cancel_wake.notify_one();
    }
    /// The application must await this before exiting. Cancellation does not by
    /// itself prove that a native microphone or child process has closed.
    pub async fn shutdown(&self) {
        self.shutdown.cancel();
        self.cancel();
        self.stopped.cancelled().await;
    }
    pub fn shutdown_complete(&self) -> bool {
        self.stopped.is_cancelled()
    }
}
fn update(app: &AppHandle, shared: &Shared, change: impl FnOnce(&mut ViewState)) {
    let snapshot = {
        let mut s = shared.view.lock().unwrap();
        change(&mut s);
        s.clone()
    };
    let _ = app.emit("pressay-state", snapshot.clone());
    if let Some(overlay) = app.get_webview_window("overlay") {
        if ["recording", "processing"].contains(&snapshot.stage.as_str()) {
            let _ = overlay.show();
        } else {
            let _ = overlay.hide();
        }
    }
}
fn failed(app: &AppHandle, shared: &Shared, error: impl ToString) {
    shared.start_pending.store(false, Ordering::Release);
    update(app, shared, |s| {
        s.stage = "idle".into();
        s.error = Some(error.to_string());
        s.progress = None;
    });
}

pub fn launch(
    app: AppHandle,
    data: PathBuf,
    runtime: PathBuf,
    worker: PathBuf,
) -> Result<Arc<Shared>, String> {
    let store = Store::open(&data.join("pressay.sqlite3")).map_err(|e| e.to_string())?;
    let mut settings = store.settings().map_err(|e| e.to_string())?;
    let map = settings.as_object_mut().ok_or("Invalid saved settings")?;
    map.entry("asrModel")
        .or_insert(json!(if cfg!(target_os = "macos") {
            "orukeet"
        } else {
            "parakeetUltra"
        }));
    map.entry("vocabulary").or_insert(json!(""));
    map.entry("onboardingComplete").or_insert(json!(false));
    let (tx, mut rx) = mpsc::channel(8);
    let shared = Arc::new(Shared {
        view: Mutex::new(ViewState {
            stage: "idle".into(),
            error: None,
            model_ready: false,
            progress: None,
            settings,
            history: store.history(500).map_err(|e| e.to_string())?,
            notes: store.notes().map_err(|e| e.to_string())?,
            practice: Practice::default(),
            first_sample_ms: None,
            release_to_text_ms: None,
        }),
        tx,
        cancel: Mutex::new(CancellationToken::new()),
        generation: AtomicU64::new(0),
        start_pending: AtomicBool::new(false),
        cancel_wake: Notify::new(),
        shutdown: CancellationToken::new(),
        stopped: CancellationToken::new(),
        microphone_worked: AtomicBool::new(false),
        shortcut_registered: AtomicBool::new(false),
    });
    let state = shared.clone();
    tauri::async_runtime::spawn(async move {
        let mut store = store;
        let mut host = WorkerHost::new(worker, runtime);
        let mut capture: Option<(Capture, u64, Instant)> = None;
        let mut loaded: Option<(String, PathBuf)> = None;
        let mut capture_health = tokio::time::interval(std::time::Duration::from_millis(100));
        capture_health.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            let queued = tokio::select! {
                biased;
                _ = state.shutdown.cancelled() => break,
                _ = state.cancel_wake.notified() => Queued {
                    generation: state.generation.load(Ordering::Acquire), command: Command::Cancel,
                },
                _ = capture_health.tick(), if capture.is_some() => {
                    if !capture.as_ref().is_some_and(|(capture, _, _)| capture.is_finished()) {
                        continue;
                    }
                    Queued { generation: state.generation.load(Ordering::Acquire), command: Command::CaptureEnded }
                },
                queued = rx.recv() => match queued { Some(queued) => queued, None => break },
            };
            let generation = queued.generation;
            if generation != state.generation.load(Ordering::Acquire) {
                match queued.command {
                    Command::Settings(_, reply)
                    | Command::Complete(_, reply)
                    | Command::Delete(_, reply)
                    | Command::Import(_, reply) => {
                        let _ = reply.send(Err("Operation cancelled".into()));
                    }
                    _ => {}
                }
                continue;
            }
            let command = queued.command;
            match command {
                Command::Prepare(id) => {
                    if capture.is_some() {
                        update(&app, &state, |s| {
                            s.error = Some("Finish recording before changing models".into())
                        });
                        continue;
                    }
                    let token = CancellationToken::new();
                    *state.cancel.lock().unwrap() = token.clone();
                    if generation != state.generation.load(Ordering::Acquire)
                        || state.shutdown.is_cancelled()
                    {
                        token.cancel();
                        continue;
                    }
                    loaded = None;
                    update(&app, &state, |s| {
                        s.stage = "preparing".into();
                        s.model_ready = false;
                        s.error = None;
                        s.practice = Practice::default();
                    });
                    let result = async {
                        let model = catalog::find(&id)?;
                        // Preserve cached Mac weights without moving or modifying the old app's data.
                        let root = if cfg!(target_os = "macos") {
                            std::env::var_os("HOME")
                                .map(PathBuf::from)
                                .unwrap_or(data.clone())
                                .join("Library/Application Support/Pressay/Models/ASR")
                        } else {
                            data.join("Models/ASR")
                        };
                        let path = download::prepare(&root, model, &token, |p| {
                            update(&app, &state, |s| s.progress = Some(p))
                        })
                        .await?;
                        update(&app, &state, |s| {
                            s.stage = "loading".into();
                            s.progress = None;
                        });
                        host.request(&id, &path, None, &token).await?;
                        Ok::<_, pressay_core::Error>(path)
                    }
                    .await;
                    match result {
                        Ok(path) if !token.is_cancelled() && !state.shutdown.is_cancelled() => {
                            loaded = Some((id.clone(), path));
                            update(&app, &state, |s| {
                                s.stage = "idle".into();
                                s.model_ready = true;
                                s.progress = None;
                                s.settings["asrModel"] = json!(id);
                            });
                            let settings = state.view.lock().unwrap().settings.clone();
                            if let Err(e) = store.save_settings(&settings) {
                                failed(&app, &state, e);
                            }
                        }
                        Ok(_) => {
                            host.stop().await;
                            failed(&app, &state, "Cancelled");
                        }
                        Err(e) => {
                            host.stop().await;
                            failed(&app, &state, e);
                        }
                    }
                }
                Command::Start => {
                    if capture.is_some() {
                        continue;
                    }
                    if loaded.is_none() {
                        failed(&app, &state, "Prepare your speech model first");
                        continue;
                    }
                    let permissions = platform::permissions(
                        state.shortcut_registered.load(Ordering::Relaxed),
                        state.microphone_worked.load(Ordering::Relaxed),
                    );
                    if permissions.wayland {
                        failed(&app, &state, permissions.explanation.unwrap_or_default());
                        continue;
                    }
                    let target = match platform::focused_target() {
                        Ok(t) => t,
                        Err(e) => {
                            failed(&app, &state, e);
                            continue;
                        }
                    };
                    let token = CancellationToken::new();
                    *state.cancel.lock().unwrap() = token.clone();
                    if generation != state.generation.load(Ordering::Acquire)
                        || state.shutdown.is_cancelled()
                    {
                        token.cancel();
                        continue;
                    }
                    let start = Instant::now();
                    state.microphone_worked.store(false, Ordering::Release);
                    update(&app, &state, |s| {
                        s.stage = "starting".into();
                        s.error = None;
                        s.practice = Practice::default();
                        s.first_sample_ms = None;
                        s.release_to_text_ms = None;
                    });
                    let callback_state = state.clone();
                    let callback_app = app.clone();
                    let callback_token = token.clone();
                    let device = state
                        .view
                        .lock()
                        .unwrap()
                        .settings
                        .get("inputDevice")
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    let callback = Arc::new(move || {
                        if callback_token.is_cancelled()
                            || generation != callback_state.generation.load(Ordering::Acquire)
                        {
                            return;
                        }
                        callback_state
                            .microphone_worked
                            .store(true, Ordering::Relaxed);
                        update(&callback_app, &callback_state, |s| {
                            if s.stage != "starting" || callback_token.is_cancelled() {
                                return;
                            }
                            s.stage = "recording".into();
                            s.first_sample_ms = Some(start.elapsed().as_secs_f64() * 1000.);
                            s.practice.received_audio = true;
                        });
                    });
                    match tokio::task::spawn_blocking(move || {
                        Capture::start(device.as_deref(), callback)
                    })
                    .await
                    {
                        Ok(Ok(c)) if token.is_cancelled() || state.shutdown.is_cancelled() => {
                            let _ = tokio::task::spawn_blocking(move || c.cancel()).await;
                            failed(&app, &state, "Cancelled");
                        }
                        Ok(Ok(c)) => capture = Some((c, target, start)),
                        Ok(Err(e)) => failed(&app, &state, e),
                        Err(e) => failed(&app, &state, e),
                    }
                }
                Command::Stop => {
                    let Some((c, target, started)) = capture.take() else {
                        continue;
                    };
                    let release = Instant::now();
                    let token = state.cancel.lock().unwrap().clone();
                    update(&app, &state, |s| s.stage = "processing".into());
                    let samples = match tokio::task::spawn_blocking(move || c.finish()).await {
                        Ok(Ok(samples)) => samples,
                        Ok(Err(e)) => {
                            state.microphone_worked.store(false, Ordering::Release);
                            failed(&app, &state, e);
                            continue;
                        }
                        Err(e) => {
                            failed(&app, &state, e);
                            continue;
                        }
                    };
                    // A very short hold can finish before the first-audio observer
                    // runs; the returned samples are still proof of real capture.
                    state.microphone_worked.store(true, Ordering::Release);
                    update(&app, &state, |s| s.practice.received_audio = true);
                    let Some((model, path)) = &loaded else {
                        failed(&app, &state, "Speech model is no longer ready");
                        continue;
                    };
                    let duration = samples.len() as f64 / 16_000.;
                    match host.transcribe(model, path, &samples, &token).await {
                        Ok(raw) => {
                            let settings = state.view.lock().unwrap().settings.clone();
                            let entries =
                                vocabulary::parse(settings["vocabulary"].as_str().unwrap_or(""));
                            let text = vocabulary::normalize(&raw, &entries);
                            if token.is_cancelled() {
                                failed(&app, &state, "Cancelled");
                                continue;
                            }
                            let record = Dictation {
                                id: uuid::Uuid::new_v4().to_string(),
                                created_at: storage::now(),
                                duration,
                                model: model.clone(),
                                raw,
                                text: text.clone(),
                                correction: None,
                                pinned: false,
                                target: Some(target.to_string()),
                                latency: release.elapsed().as_secs_f64(),
                                legacy: Value::Null,
                            };
                            // Save before insertion so failures never discard recognized speech.
                            if let Err(e) = store.add(&record) {
                                failed(&app, &state, e);
                                continue;
                            }
                            let insert_text = text.clone();
                            let insertion_cancel = token.clone();
                            let insertion = tokio::task::spawn_blocking(move || {
                                if insertion_cancel.is_cancelled() {
                                    return Err(
                                        "Cancelled; the recognized text remains in History".into(),
                                    );
                                }
                                platform::insert(&insert_text, target)
                            })
                            .await;
                            let error = match insertion {
                                Ok(Ok(())) => None,
                                Ok(Err(e)) => Some(e),
                                Err(e) => Some(e.to_string()),
                            };
                            let history = store.history(500);
                            state.start_pending.store(false, Ordering::Release);
                            update(&app, &state, |s| {
                                s.stage = "idle".into();
                                if let Ok(history) = history.as_ref() {
                                    s.history = history.clone();
                                }
                                s.practice.recognized_text = text;
                                s.practice.inserted = error.is_none();
                                s.error = error;
                                if let Err(error) = history {
                                    s.error = Some(format!("Dictation was saved, but History could not refresh: {error}"));
                                }
                                s.release_to_text_ms =
                                    Some(release.elapsed().as_secs_f64() * 1000.);
                            });
                        }
                        Err(e) => {
                            loaded = None;
                            update(&app, &state, |s| s.model_ready = false);
                            failed(&app, &state, e);
                        }
                    }
                    let _ = started;
                }
                Command::Cancel => {
                    if let Some((c, _, _)) = capture.take() {
                        let _ = tokio::task::spawn_blocking(move || c.cancel()).await;
                    }
                    host.stop().await;
                    loaded = None;
                    state.start_pending.store(false, Ordering::Release);
                    update(&app, &state, |s| {
                        s.stage = "idle".into();
                        s.model_ready = false;
                        s.practice = Practice::default();
                        s.progress = None;
                    });
                }
                Command::CaptureEnded => {
                    let Some((capture, _, _)) = capture.take() else {
                        continue;
                    };
                    state.cancel.lock().unwrap().cancel();
                    state.microphone_worked.store(false, Ordering::Release);
                    // Device failure/overflow must never insert the partial audio
                    // accumulated before the native stream terminated.
                    let error = match tokio::task::spawn_blocking(move || capture.finish()).await {
                        Ok(Err(error)) => error,
                        Err(error) => error.to_string(),
                        Ok(Ok(_)) => "Microphone stopped unexpectedly. Please try again.".into(),
                    };
                    failed(&app, &state, error);
                }
                Command::Settings(patch, reply) => {
                    let result = (|| {
                        if capture.is_some() {
                            return Err("Finish dictation before changing settings".into());
                        }
                        let patch = patch.as_object().ok_or("Invalid settings")?;
                        let mut settings = state.view.lock().unwrap().settings.clone();
                        // Renderer cannot assert permission/model/onboarding completion.
                        for (key, value) in patch {
                            match key.as_str() {
                                "vocabulary" if value.is_string() => {
                                    settings[key] = value.clone();
                                }
                                "inputDevice" if value.is_string() || value.is_null() => {
                                    settings[key] = value.clone();
                                }
                                _ => return Err(format!("Unsupported setting: {key}")),
                            }
                        }
                        store.save_settings(&settings).map_err(|e| e.to_string())?;
                        update(&app, &state, |s| s.settings = settings);
                        Ok(())
                    })();
                    let _ = reply.send(result);
                }
                Command::Complete(observed, reply) => {
                    let p = platform::permissions(
                        state.shortcut_registered.load(Ordering::Relaxed),
                        state.microphone_worked.load(Ordering::Relaxed),
                    );
                    let (mut practice, mut settings, model_ready) = {
                        let s = state.view.lock().unwrap();
                        (s.practice.clone(), s.settings.clone(), s.model_ready)
                    };
                    practice.observed_text = observed;
                    let result = if practice.complete(&Readiness {
                        microphone: p.microphone,
                        shortcut: p.shortcut,
                        insertion: p.insertion,
                        model_ready,
                    }) {
                        settings["onboardingComplete"] = json!(true);
                        store
                            .save_settings(&settings)
                            .map_err(|e| e.to_string())
                            .map(|_| {
                                update(&app, &state, |s| {
                                    s.settings = settings;
                                    s.practice = practice;
                                })
                            })
                    } else {
                        Err("Complete a real dictation into the practice field first".into())
                    };
                    let _ = reply.send(result);
                }
                Command::Delete(id, reply) => {
                    let result = store
                        .delete_dictation(&id)
                        .and_then(|_| store.history(500))
                        .map_err(|e| e.to_string())
                        .map(|history| update(&app, &state, |s| s.history = history));
                    let _ = reply.send(result);
                }
                Command::Import(source, reply) => {
                    if capture.is_some() {
                        let _ =
                            reply.send(Err("Finish dictation before importing settings".into()));
                        continue;
                    }
                    let preview_onboarding = state.view.lock().unwrap().settings
                        ["onboardingComplete"]
                        .as_bool()
                        .unwrap_or(false);
                    let mut result = serde_json::from_str::<storage::Snapshot>(&source)
                        .map_err(|e| e.to_string())
                        .and_then(|mut snapshot| {
                            // Completing setup in the Swift app cannot attest to this
                            // separately signed preview's permissions or insertion.
                            if let Some(settings) = snapshot.settings.as_object_mut() {
                                settings
                                    .insert("onboardingComplete".into(), json!(preview_onboarding));
                            }
                            store.import(&snapshot).map_err(|e| e.to_string())
                        })
                        .map(|_| ());
                    if result.is_ok() {
                        let refreshed = (|| -> pressay_core::Result<_> {
                            Ok((store.settings()?, store.history(500)?, store.notes()?))
                        })();
                        match refreshed {
                            Ok((settings, history, notes)) => {
                                let model_changed = loaded.as_ref().is_some_and(|(model, _)| {
                                    settings["asrModel"].as_str() != Some(model)
                                });
                                if model_changed {
                                    host.stop().await;
                                    loaded = None;
                                }
                                update(&app, &state, |s| {
                                    s.settings = settings;
                                    s.history = history;
                                    s.notes = notes;
                                    if model_changed {
                                        s.model_ready = false;
                                        s.practice = Practice::default();
                                    }
                                });
                            }
                            Err(error) => {
                                result =
                                    Err(format!("Import was saved, but could not refresh: {error}"))
                            }
                        }
                    }
                    let _ = reply.send(result);
                }
            }
        }
        if let Some((capture, _, _)) = capture.take() {
            let _ = tokio::task::spawn_blocking(move || capture.cancel()).await;
        }
        host.stop().await;
        state.stopped.cancel();
    });
    Ok(shared)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shared(capacity: usize) -> (Arc<Shared>, mpsc::Receiver<Queued>) {
        let (tx, rx) = mpsc::channel(capacity);
        (
            Arc::new(Shared {
                view: Mutex::new(ViewState {
                    stage: "idle".into(),
                    error: None,
                    model_ready: true,
                    progress: None,
                    settings: json!({"asrModel":"moss"}),
                    history: vec![],
                    notes: vec![],
                    practice: Practice::default(),
                    first_sample_ms: None,
                    release_to_text_ms: None,
                }),
                tx,
                cancel: Mutex::new(CancellationToken::new()),
                generation: AtomicU64::new(0),
                start_pending: AtomicBool::new(false),
                cancel_wake: Notify::new(),
                shutdown: CancellationToken::new(),
                stopped: CancellationToken::new(),
                microphone_worked: AtomicBool::new(false),
                shortcut_registered: AtomicBool::new(true),
            }),
            rx,
        )
    }

    #[tokio::test]
    async fn repeated_key_down_enqueues_only_one_capture() {
        let (shared, mut rx) = shared(8);
        shared.send(Command::Start).unwrap();
        shared.send(Command::Start).unwrap();
        shared.send(Command::Start).unwrap();
        shared.send(Command::Stop).unwrap();
        assert_eq!(shared.view.lock().unwrap().stage, "starting");
        assert!(matches!(rx.recv().await.unwrap().command, Command::Start));
        assert!(matches!(rx.recv().await.unwrap().command, Command::Stop));
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn a_full_queue_cannot_swallow_key_release_or_cancellation() {
        let (shared, mut rx) = shared(1);
        let token = shared.cancel.lock().unwrap().clone();
        shared.send(Command::Start).unwrap();
        assert!(shared.send(Command::Stop).is_err());
        assert!(token.is_cancelled());
        tokio::time::timeout(
            std::time::Duration::from_millis(100),
            shared.cancel_wake.notified(),
        )
        .await
        .unwrap();
        let queued = rx.recv().await.unwrap();
        assert_ne!(queued.generation, shared.generation.load(Ordering::Acquire));
    }

    #[tokio::test]
    async fn cancel_invalidates_an_already_queued_microphone_start() {
        let (shared, mut rx) = shared(8);
        shared.send(Command::Start).unwrap();
        shared.cancel();
        let queued = rx.recv().await.unwrap();
        assert!(matches!(queued.command, Command::Start));
        assert_ne!(queued.generation, shared.generation.load(Ordering::Acquire));
        assert!(shared.cancel.lock().unwrap().is_cancelled());
    }

    #[tokio::test]
    async fn model_change_claims_state_before_a_hotkey_can_queue_capture() {
        let (shared, mut rx) = shared(8);
        shared.send(Command::Prepare("moss".into())).unwrap();
        assert_eq!(shared.view.lock().unwrap().stage, "preparing");
        assert!(shared.send(Command::Start).is_err());
        assert!(matches!(
            rx.recv().await.unwrap().command,
            Command::Prepare(_)
        ));
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn shutdown_waits_for_native_cleanup_acknowledgement() {
        let (shared, _rx) = shared(8);
        let stopping = shared.clone();
        let task = tokio::spawn(async move { stopping.shutdown().await });
        shared.shutdown.cancelled().await;
        assert!(!task.is_finished());
        assert!(!shared.shutdown_complete());
        assert!(shared.send(Command::Start).is_err());
        shared.stopped.cancel();
        task.await.unwrap();
        assert!(shared.shutdown_complete());
    }
}
