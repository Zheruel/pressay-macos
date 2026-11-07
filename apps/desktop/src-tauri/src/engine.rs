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
    StartMeeting(String, Reply),
    StopMeeting,
    Stop,
    Cancel,
    CaptureEnded,
    Settings(Value, Reply),
    BeginPractice(Reply),
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
    pub shortcut_label: String,
    pub shortcut_error: Option<String>,
    pub error: Option<String>,
    pub model_ready: bool,
    pub progress: Option<download::Progress>,
    pub settings: Value,
    pub history: Vec<Dictation>,
    pub notes: Vec<Value>,
    pub practice: Practice,
    pub active_note: Option<String>,
    pub meeting_elapsed: f64,
    pub audio_levels: [f32; 4],
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
    shutdown_error: Mutex<Option<String>>,
    meeting_stop: Mutex<Option<(CancellationToken, crate::meeting::Cancellation)>>,
    pub microphone_worked: AtomicBool,
    pub shortcut_registered: AtomicBool,
}
impl Shared {
    pub fn send(&self, cmd: Command) -> Result<(), String> {
        let generation = self.generation.load(Ordering::Acquire);
        if self.shutdown.is_cancelled() {
            return Err("Pressay is shutting down".into());
        }
        if matches!(cmd, Command::StartMeeting(_, _)) {
            *self.meeting_stop.lock().unwrap() = None;
        }
        if matches!(cmd, Command::StopMeeting) {
            let signals = self.meeting_stop.lock().unwrap().clone();
            if let Some((stop, cancel)) = signals {
                stop.cancel();
                if self.view.lock().unwrap().active_note.is_none() {
                    cancel.cancel();
                }
                return Ok(());
            }
        }
        if matches!(cmd, Command::Cancel) {
            self.cancel();
            return Ok(());
        }
        let is_start = matches!(cmd, Command::Start);
        let is_stop = matches!(cmd, Command::Stop | Command::StopMeeting);
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
                return Err(match view.stage.as_str() {
                    "meeting" | "meeting_finishing" => "Stop the Notetaker to dictate",
                    "processing" | "polishing" => "Still processing the previous dictation",
                    "idle" | "preparing" | "loading" => {
                        "Wait for the local model to finish preparing"
                    }
                    _ => "Finish the current operation first",
                }
                .into());
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
                self.cancel_dictation();
                return Err("Command queue filled; the recording was cancelled".into());
            }
            return Err("Pressay is busy; wait for the current operation".into());
        }
        Ok(())
    }
    pub fn cancel(&self) {
        platform::cancel_pending_insertions();
        // Capture the user's intent now, before the actor can advance from
        // recording to optional speaker analysis while this command is queued.
        if !self.shutdown.is_cancelled() {
            if let Some((_, cancellation)) = self.meeting_stop.lock().unwrap().clone() {
                cancellation.cancel();
            }
        }
        self.generation.fetch_add(1, Ordering::AcqRel);
        self.cancel.lock().unwrap().cancel();
        self.cancel_wake.notify_one();
    }
    /// Escape, shortcut rebinding, screen sleep and session lock end dictation
    /// only. A meeting keeps recording through them, as in the Mac app; only an
    /// explicit discard may delete it. An idle model stays loaded.
    pub fn cancel_dictation(&self) {
        let stage = self.view.lock().unwrap().stage.clone();
        if stage == "idle" || stage.starts_with("meeting") {
            platform::cancel_pending_insertions();
            return;
        }
        self.cancel();
    }
    /// The application must await this before exiting. Cancellation does not by
    /// itself prove that a native microphone or child process has closed.
    pub async fn shutdown(&self) -> Result<(), String> {
        self.shutdown.cancel();
        self.cancel();
        self.stopped.cancelled().await;
        match self.shutdown_error.lock().unwrap().clone() {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }
    pub fn is_shutting_down(&self) -> bool {
        self.shutdown.is_cancelled()
    }
    pub fn shutdown_complete(&self) -> bool {
        self.stopped.is_cancelled() && self.shutdown_error.lock().unwrap().is_none()
    }
}
static OVERLAY_EPOCH: AtomicU64 = AtomicU64::new(0);
pub fn update(app: &AppHandle, shared: &Shared, change: impl FnOnce(&mut ViewState)) {
    let (snapshot, previous, had_active_note) = {
        let mut s = shared.view.lock().unwrap();
        let previous = s.stage.clone();
        let had_active_note = s.active_note.is_some();
        change(&mut s);
        (s.clone(), previous, had_active_note)
    };
    let _ = app.emit("pressay-state", &snapshot);
    let busy =
        ["starting", "recording", "processing", "polishing"].contains(&snapshot.stage.as_str());
    if let Some(controller) = app.try_state::<crate::shortcuts::ShortcutController>() {
        controller.set_busy(busy);
    }
    let meeting_saved = snapshot.stage == "idle"
        && previous == "meeting_finishing"
        && had_active_note
        && snapshot.error.is_none();
    let phase = if snapshot.stage == "idle" && snapshot.error.is_some() {
        "error"
    } else if meeting_saved
        || (snapshot.stage == "idle"
            && ["processing", "polishing"].contains(&previous.as_str())
            && snapshot.practice.inserted)
    {
        "success"
    } else if snapshot.stage == "idle"
        && ["starting", "recording", "processing", "polishing"].contains(&previous.as_str())
    {
        "cancelled"
    } else {
        &snapshot.stage
    };
    let epoch = OVERLAY_EPOCH.fetch_add(1, Ordering::AcqRel) + 1;
    platform::overlay_elapsed(snapshot.meeting_elapsed);
    let detail = snapshot
        .error
        .as_deref()
        .or(meeting_saved.then_some("Saved"));
    platform::overlay_state(phase, detail, snapshot.audio_levels);
    let _ = app.emit("pressay-overlay", json!({"stage":phase,"error":snapshot.error,"overlay_message":meeting_saved.then_some("Saved"),"audio_levels":snapshot.audio_levels,"meeting_elapsed":snapshot.meeting_elapsed}));
    if let Some(overlay) = app.get_webview_window("overlay") {
        let visible = [
            "starting",
            "recording",
            "processing",
            "polishing",
            "meeting",
            "meeting_finishing",
            "success",
            "error",
            "cancelled",
        ]
        .contains(&phase);
        if !["meeting", "meeting_finishing"].contains(&phase) {
            let _ = overlay.set_ignore_cursor_events(true);
        }
        if visible {
            if !overlay.is_visible().unwrap_or(false) {
                if let Ok(Some(monitor)) = overlay.current_monitor() {
                    let position = monitor.position();
                    let width = monitor.size().width as f64;
                    let scale = monitor.scale_factor();
                    let _ = overlay.set_position(tauri::PhysicalPosition::new(
                        position.x + ((width - 560. * scale) / 2.) as i32,
                        position.y,
                    ));
                }
            }
            let _ = overlay.show();
        } else {
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(450)).await;
                if OVERLAY_EPOCH.load(Ordering::Acquire) == epoch {
                    let _ = overlay.hide();
                }
            });
        }
    }
    if ["success", "error", "cancelled"].contains(&phase) {
        let app = app.clone();
        let milliseconds = if phase == "error" {
            2600
        } else if meeting_saved {
            1200
        } else if phase == "success" {
            900
        } else {
            0
        };
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(milliseconds)).await;
            if OVERLAY_EPOCH.load(Ordering::Acquire) == epoch {
                platform::overlay_state("idle", None, [0.; 4]);
                let _ = app.emit("pressay-overlay", json!({"stage":"idle"}));
                tokio::time::sleep(std::time::Duration::from_millis(450)).await;
                if OVERLAY_EPOCH.load(Ordering::Acquire) != epoch {
                    return;
                }
                if let Some(overlay) = app.get_webview_window("overlay") {
                    let _ = overlay.hide();
                }
            }
        });
    }
}

/// A transparent meeting stage must intercept clicks only over its island.
/// Native macOS handles this inside the SwiftUI panel; other desktops poll the
/// global pointer without keyboard hooks or focus changes.
pub fn track_overlay(app: AppHandle, shared: Arc<Shared>) {
    #[cfg(target_os = "macos")]
    let _ = (app, shared);
    #[cfg(not(target_os = "macos"))]
    tauri::async_runtime::spawn(async move {
        let mut hovering = false;
        while !shared.is_shutting_down() {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            let Some(window) = app.get_webview_window("overlay") else {
                break;
            };
            let meeting = ["meeting", "meeting_finishing"]
                .contains(&shared.view.lock().unwrap().stage.as_str());
            let inside = if meeting && window.is_visible().unwrap_or(false) {
                match (
                    window.cursor_position(),
                    window.outer_position(),
                    window.scale_factor(),
                ) {
                    (Ok(cursor), Ok(origin), Ok(scale)) => {
                        let width = if hovering { 258. } else { 142. };
                        let height = if hovering { 76. } else { 32. };
                        let x = (cursor.x - origin.x as f64) / scale;
                        let y = (cursor.y - origin.y as f64) / scale;
                        ((560. - width) / 2. ..=(560. + width) / 2.).contains(&x)
                            && (0. ..=height).contains(&y)
                    }
                    _ => false,
                }
            } else {
                false
            };
            if inside != hovering {
                hovering = inside;
                let _ = window.set_ignore_cursor_events(!inside);
                let _ = window.emit("pressay-overlay-hover", json!({"hover":inside}));
            }
        }
        if let Some(window) = app.get_webview_window("overlay") {
            let _ = window.set_ignore_cursor_events(true);
            let _ = window.hide();
        }
    });
}

/// A rejected hotkey press must not look like a dead key. Only an idle app
/// shows the message, so a meeting island or running dictation stays intact.
pub fn reject_start(app: &AppHandle, shared: &Shared, error: String) {
    crate::feedback::cue(crate::feedback::Cue::Error);
    if shared.view.lock().unwrap().stage == "idle" {
        update(app, shared, |s| s.error = Some(error));
    }
}
fn failed(app: &AppHandle, shared: &Shared, error: impl ToString) {
    shared.cancel.lock().unwrap().cancel();
    crate::feedback::cue(crate::feedback::Cue::Error);
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
    workspace: Arc<crate::workspace::Workspace>,
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
            shortcut_label: crate::shortcuts::Binding::default().label(),
            shortcut_error: None,
            error: None,
            model_ready: false,
            progress: None,
            settings,
            history: store.history(10000).map_err(|e| e.to_string())?,
            notes: store.notes().map_err(|e| e.to_string())?,
            practice: Practice::default(),
            active_note: None,
            meeting_elapsed: 0.,
            audio_levels: [0.; 4],
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
        shutdown_error: Mutex::new(None),
        meeting_stop: Mutex::new(None),
        microphone_worked: AtomicBool::new(false),
        shortcut_registered: AtomicBool::new(false),
    });
    let state = shared.clone();
    tauri::async_runtime::spawn(async move {
        let mut store = store;
        let host = Arc::new(tokio::sync::Mutex::new(WorkerHost::new(
            worker.clone(),
            runtime.clone(),
        )));
        let mut streamer: Option<crate::dictation::Session> = None;
        let mut earcon_guard = Arc::new(Mutex::new(None));
        let mut meeting: Option<crate::meeting::Session> = None;
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
                    Command::StartMeeting(_, reply)
                    | Command::Settings(_, reply)
                    | Command::BeginPractice(reply)
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
                Command::BeginPractice(reply) => {
                    let result = if state.view.lock().unwrap().stage != "idle" {
                        Err("Finish the current operation before practicing".into())
                    } else {
                        update(&app, &state, |s| s.practice = Practice::default());
                        Ok(())
                    };
                    let _ = reply.send(result);
                }
                Command::StartMeeting(kind, reply) => {
                    let result = if capture.is_some()
                        || meeting.as_ref().is_some_and(|m| !m.task.is_finished())
                    {
                        Err("Finish the current recording first".into())
                    } else if !["voice", "meeting"].contains(&kind.as_str()) {
                        Err("Invalid recording type".into())
                    } else {
                        host.lock().await.stop().await;
                        loaded = None;
                        update(&app, &state, |s| {
                            s.stage = "meeting_starting".into();
                            s.error = None;
                            s.model_ready = false;
                            s.meeting_elapsed = 0.;
                        });
                        meeting = Some(crate::meeting::start(
                            app.clone(),
                            workspace.clone(),
                            worker.clone(),
                            runtime.clone(),
                            kind,
                        ));
                        if let Some(session) = &meeting {
                            *state.meeting_stop.lock().unwrap() =
                                Some((session.stop.clone(), session.cancel.clone()));
                        }
                        Ok(())
                    };
                    let _ = reply.send(result);
                }
                Command::StopMeeting => {
                    if let Some(m) = &meeting {
                        m.stop.cancel();
                        if state.view.lock().unwrap().active_note.is_none() {
                            m.cancel.cancel();
                        }
                    }
                }
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
                        host.lock().await.request(&id, &path, None, &token).await?;
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
                                if let Ok(model) = catalog::find(&id) {
                                    s.settings["language"] = json!(model.effective_language(
                                        s.settings["language"].as_str().unwrap_or("auto")
                                    ));
                                }
                            });
                            let settings = state.view.lock().unwrap().settings.clone();
                            if let Err(e) = store.save_settings(&settings) {
                                failed(&app, &state, e);
                            }
                        }
                        Ok(_) => {
                            host.lock().await.stop().await;
                            failed(&app, &state, "Cancelled");
                        }
                        Err(e) => {
                            host.lock().await.stop().await;
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

                    #[cfg(target_os = "macos")]
                    {
                        let permissions = platform::permissions(
                            state.shortcut_registered.load(Ordering::Acquire),
                            false,
                        );
                        if permissions.microphone != pressay_core::onboarding::Permission::Granted
                            || permissions.insertion
                                != pressay_core::onboarding::Permission::Granted
                        {
                            failed(&app, &state, "Finish microphone and text insertion permissions in Pressay setup.");
                            continue;
                        }
                    }
                    let target = match platform::focused_target() {
                        Ok(t) => t,
                        Err(e) => {
                            failed(&app, &state, e);
                            continue;
                        }
                    };
                    let target_guard = TargetGuard(target);
                    let token = CancellationToken::new();
                    *state.cancel.lock().unwrap() = token.clone();
                    if generation != state.generation.load(Ordering::Acquire)
                        || state.shutdown.is_cancelled()
                    {
                        token.cancel();
                        continue;
                    }
                    let language = state.view.lock().unwrap().settings["language"]
                        .as_str()
                        .unwrap_or("auto")
                        .to_string();
                    host.lock().await.set_language(&language);
                    let config =
                        crate::workspace::cleanup_config(&state.view.lock().unwrap().settings);
                    let ai = workspace.ai.clone();
                    let warm_cancel = token.clone();
                    tauri::async_runtime::spawn(async move {
                        let _ = ai.warm_up(config, &warm_cancel).await;
                    });
                    let start = Instant::now();
                    state.microphone_worked.store(false, Ordering::Release);
                    let practice_in_app = platform::target_is_current_app(target, &app);
                    update(&app, &state, |s| {
                        s.stage = "starting".into();
                        s.error = None;
                        s.practice = Practice::default();
                        s.practice.in_app = practice_in_app;
                        s.first_sample_ms = None;
                        s.release_to_text_ms = None;
                    });
                    let callback_state = state.clone();
                    let callback_app = app.clone();
                    let callback_token = token.clone();
                    let mic_settings = state.view.lock().unwrap().settings.clone();
                    let device = match crate::audio::resolve_input(&mic_settings) {
                        Ok(device) => device,
                        Err(error) => {
                            failed(&app, &state, error);
                            continue;
                        }
                    };
                    earcon_guard = Arc::new(Mutex::new(None));
                    let callback_guard = earcon_guard.clone();
                    let level_state = state.clone();
                    let level_app = app.clone();
                    let level_token = token.clone();
                    let levels = Arc::new(move |levels| {
                        if !level_token.is_cancelled() {
                            let phase = {
                                let mut s = level_state.view.lock().unwrap();
                                if !["starting", "recording"].contains(&s.stage.as_str()) {
                                    return;
                                }
                                s.audio_levels = levels;
                                s.stage.clone()
                            };
                            platform::overlay_state(&phase, None, levels);
                            let _ = level_app.emit("pressay-levels", levels);
                        }
                    });
                    let callback = Arc::new(move |captured_samples: usize| {
                        if callback_token.is_cancelled()
                            || generation != callback_state.generation.load(Ordering::Acquire)
                        {
                            return;
                        }
                        if let Some(duration) = crate::feedback::cue(crate::feedback::Cue::Begin) {
                            let end = captured_samples
                                + (duration.as_secs_f64() * 16_000.).ceil() as usize;
                            *callback_guard.lock().unwrap() = Some(captured_samples..end);
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
                    let (live_tx, live_rx) = std::sync::mpsc::sync_channel(64);
                    match tokio::task::spawn_blocking(move || {
                        Capture::start_streaming(
                            device.as_deref(),
                            callback,
                            Some(live_tx),
                            Some(levels),
                        )
                    })
                    .await
                    {
                        Ok(Ok(c)) if token.is_cancelled() || state.shutdown.is_cancelled() => {
                            let _ = tokio::task::spawn_blocking(move || c.cancel()).await;
                            failed(&app, &state, "Cancelled");
                        }
                        Ok(Ok(c)) => {
                            if let Some((model, path)) = &loaded {
                                let analysis = worker
                                    .parent()
                                    .unwrap_or(std::path::Path::new("."))
                                    .join(if cfg!(windows) {
                                        "pressay-analysis-worker.exe"
                                    } else {
                                        "pressay-analysis-worker"
                                    });
                                streamer = Some(crate::dictation::Session::start(
                                    host.clone(),
                                    live_rx,
                                    model.clone(),
                                    path.clone(),
                                    analysis,
                                    runtime.clone(),
                                    workspace.data.clone(),
                                    earcon_guard.clone(),
                                    &token,
                                ));
                            }
                            capture = Some((c, target, start));
                            std::mem::forget(target_guard);
                        }
                        Ok(Err(e)) => failed(&app, &state, e),
                        Err(e) => failed(&app, &state, e),
                    }
                }
                Command::Stop | Command::CaptureEnded => {
                    let Some((c, target, started)) = capture.take() else {
                        continue;
                    };
                    state.start_pending.store(false, Ordering::Release);
                    let _target_guard = TargetGuard(target);
                    let _ = platform::refresh_target(target);
                    let release = Instant::now();
                    let token = state.cancel.lock().unwrap().clone();
                    update(&app, &state, |s| s.stage = "processing".into());
                    let samples = match tokio::task::spawn_blocking(move || c.finish()).await {
                        Ok(Ok(samples)) => samples,
                        Ok(Err(e)) => {
                            if let Some(streamer) = streamer.take() {
                                streamer.cancel().await;
                            }
                            state.microphone_worked.store(false, Ordering::Release);
                            failed(&app, &state, e);
                            continue;
                        }
                        Err(e) => {
                            if let Some(streamer) = streamer.take() {
                                streamer.cancel().await;
                            }
                            failed(&app, &state, e);
                            continue;
                        }
                    };
                    if samples.len() >= 4_000 {
                        crate::feedback::cue(crate::feedback::Cue::Release);
                    }
                    // A very short hold can finish before the first-audio observer
                    // runs; the returned samples are still proof of real capture.
                    state.microphone_worked.store(true, Ordering::Release);
                    update(&app, &state, |s| s.practice.received_audio = true);
                    let Some((model, path)) = &loaded else {
                        if let Some(streamer) = streamer.take() {
                            streamer.cancel().await;
                        }
                        failed(&app, &state, "Speech model is no longer ready");
                        continue;
                    };
                    let duration = samples.len() as f64 / 16_000.;
                    let settings = state.view.lock().unwrap().settings.clone();
                    let entries = vocabulary::parse(settings["vocabulary"].as_str().unwrap_or(""));
                    let config = crate::workspace::cleanup_config(&settings);
                    let target_app = platform::target_application(target);
                    let preparation_cancel = token.child_token();
                    let mut preparation = if config.enabled
                        && !pressay_core::text::is_terminal(target_app.as_deref())
                        && config.provider == pressay_core::ai::Provider::Claude
                        && config.connection == pressay_core::ai::Connection::Subscription
                    {
                        let ai = workspace.ai.clone();
                        let entries = entries.clone();
                        let cancel = preparation_cancel.clone();
                        Some(tauri::async_runtime::spawn(async move {
                            ai.prepare_claude(&entries, &cancel).await
                        }))
                    } else {
                        None
                    };
                    let raw_samples = samples;
                    let guard = earcon_guard.lock().unwrap().clone();
                    let samples = match pressay_core::dictation::trim(&raw_samples, guard) {
                        Ok(samples) => samples,
                        Err(_) => {
                            if let Some(streamer) = streamer.take() {
                                streamer.cancel().await;
                            }
                            preparation_cancel.cancel();
                            if let Some(task) = preparation.take() {
                                task.abort();
                                let _ = task.await;
                            }
                            update(&app, &state, |s| {
                                s.stage = "idle".into();
                                s.error = None;
                            });
                            continue;
                        }
                    };
                    let record_id = uuid::Uuid::new_v4().to_string();
                    let audio_saved = workspace.audio.save(&record_id, &samples).is_ok();
                    let streamed = if let Some(streamer) = streamer.take() {
                        streamer
                            .finish(&raw_samples, &host, model, path, &token)
                            .await
                    } else {
                        None
                    };
                    drop(raw_samples);
                    let transcript = if let Some(text) = streamed {
                        Ok(text)
                    } else {
                        host.lock()
                            .await
                            .transcribe(model, path, &samples, &token)
                            .await
                    };
                    match transcript {
                        Ok(raw) => {
                            let local = pressay_core::text::deterministic(
                                &raw,
                                &entries,
                                target_app.as_deref(),
                                settings["language"].as_str(),
                            );
                            let should_clean = pressay_core::ai::should_clean(
                                &raw,
                                pressay_core::text::is_terminal(target_app.as_deref()),
                            );
                            if !should_clean {
                                preparation_cancel.cancel();
                                if let Some(task) = preparation.take() {
                                    task.abort();
                                    let _ = task.await;
                                }
                            }
                            if should_clean && config.enabled {
                                update(&app, &state, |s| s.stage = "polishing".into());
                            }
                            let budget = pressay_core::ai::cleanup_timeout(&raw, config);
                            let outcome = tokio::select! {biased;
                                _=token.cancelled()=>Err(pressay_core::ai::AiError::Cancelled),
                                result=tokio::time::timeout(budget,async{
                                    let prepared=if let Some(task)=preparation.as_mut(){task.await.ok().and_then(Result::ok)}else{None};
                                    preparation.take();
                                    workspace.ai.cleanup(&raw,&local,target_app.as_deref(),&entries,config,prepared,&token).await
                                })=>result.unwrap_or_else(|_|Ok(pressay_core::ai::CleanupOutcome{text:local.clone(),used_language_model:false,warning:Some("AI cleanup took too long. Your local transcript was kept.".into())}))
                            };
                            preparation_cancel.cancel();
                            if let Some(task) = preparation.take() {
                                task.abort();
                                let _ = task.await;
                            }
                            let (text, warning) = match outcome {
                                Ok(o) => (o.text, o.warning),
                                Err(e) => {
                                    failed(&app, &state, e);
                                    continue;
                                }
                            };
                            if token.is_cancelled() {
                                failed(&app, &state, "Cancelled");
                                continue;
                            }
                            let mut record = Dictation {
                                id: record_id,
                                created_at: storage::now(),
                                duration,
                                model: model.clone(),
                                raw,
                                text: text.clone(),
                                correction: None,
                                pinned: false,
                                target: target_app,
                                latency: release.elapsed().as_secs_f64(),
                                legacy: Value::Null,
                            };
                            if audio_saved {
                                record.legacy = json!({"managedAudio":true});
                            }
                            // Save before insertion so failures never discard recognized speech.
                            if let Err(e) = store.add(&record) {
                                let _ = workspace.audio.remove(&record.id);
                                failed(&app, &state, e);
                                continue;
                            }
                            let insert_text = text.clone();
                            let insertion_cancel = token.clone();
                            let practice_in_app = platform::target_is_current_app(target, &app);
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
                            let history = store.history(10000);
                            state.start_pending.store(false, Ordering::Release);
                            update(&app, &state, |s| {
                                s.stage = "idle".into();
                                if let Ok(history) = history.as_ref() {
                                    s.history = history.clone();
                                }
                                s.practice.recognized_text = text;
                                s.practice.inserted = error.is_none();
                                s.practice.in_app &= practice_in_app;
                                s.error = error.or(warning);
                                if let Err(error) = history {
                                    s.error = Some(format!("Dictation was saved, but History could not refresh: {error}"));
                                }
                                s.release_to_text_ms =
                                    Some(release.elapsed().as_secs_f64() * 1000.);
                            });
                        }
                        Err(e) => {
                            preparation_cancel.cancel();
                            if let Some(task) = preparation {
                                task.abort();
                                let _ = task.await;
                            }
                            // Keep the model selected; nothing would reload it. The worker
                            // stays resident or is relaunched by the next request.
                            failed(&app, &state, e);
                        }
                    }
                    let _ = started;
                }
                Command::Cancel => {
                    if capture.is_some() {
                        crate::feedback::cue(crate::feedback::Cue::Cancel);
                    }
                    let reload = loaded.is_some()
                        || state.view.lock().unwrap().settings["onboardingComplete"] == true;
                    if let Some(m) = meeting.take() {
                        m.cancel.cancel();
                        let _ = m.task.await;
                    }
                    if let Some((c, target, _)) = capture.take() {
                        platform::release_target(target);
                        let _ = tokio::task::spawn_blocking(move || c.cancel()).await;
                    }
                    if let Some(streamer) = streamer.take() {
                        streamer.cancel().await;
                    }
                    host.lock().await.stop().await;
                    loaded = None;
                    state.start_pending.store(false, Ordering::Release);
                    update(&app, &state, |s| {
                        s.stage = "idle".into();
                        s.model_ready = false;
                        s.practice = Practice::default();
                        s.progress = None;
                    });
                    if reload && !state.shutdown.is_cancelled() {
                        let model = state.view.lock().unwrap().settings["asrModel"]
                            .as_str()
                            .unwrap_or("parakeetUltra")
                            .to_string();
                        let _ = state.send(Command::Prepare(model));
                    }
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
                                "language" | "meetingLanguage" | "meetingASRModel"
                                | "notesModel"
                                    if value.is_string() && value.as_str().unwrap().len() < 100 =>
                                {
                                    settings[key] = value.clone();
                                }
                                "cleanupProvider"
                                    if ["claude", "chatgpt"]
                                        .contains(&value.as_str().unwrap_or("")) =>
                                {
                                    settings[key] = value.clone();
                                }
                                "claudeConnection" | "openAIConnection"
                                    if ["apiKey", "subscription"]
                                        .contains(&value.as_str().unwrap_or("")) =>
                                {
                                    settings[key] = value.clone();
                                }
                                "claudeCleanup"
                                | "notesUseAI"
                                | "detectCalls"
                                | "waylandCurrentCursor"
                                    if value.is_boolean() =>
                                {
                                    settings[key] = value.clone();
                                }
                                "maxMeetingHours"
                                    if value.as_u64().is_some_and(|n| (1..=8).contains(&n)) =>
                                {
                                    settings[key] = value.clone();
                                }
                                "shortcut" if value.is_object() => {
                                    let binding: crate::shortcuts::Binding =
                                        serde_json::from_value(value.clone())
                                            .map_err(|e| e.to_string())?;
                                    binding.validate()?;
                                    settings[key] = value.clone();
                                }
                                "vocabulary"
                                    if value.is_string()
                                        && value.as_str().unwrap().len() <= 100000 =>
                                {
                                    settings[key] = value.clone();
                                }
                                "inputDevice" if value.is_string() || value.is_null() => {
                                    settings["inputDeviceUID"] = Value::Null;
                                    settings[key] = value.clone();
                                }
                                _ => return Err(format!("Unsupported setting: {key}")),
                            }
                        }
                        for (model_key, language_key, fallback) in [
                            ("asrModel", "language", "parakeetUltra"),
                            ("meetingASRModel", "meetingLanguage", "moss"),
                        ] {
                            if let Ok(model) =
                                catalog::find(settings[model_key].as_str().unwrap_or(fallback))
                            {
                                settings[language_key] = json!(model.effective_language(
                                    settings[language_key].as_str().unwrap_or("auto")
                                ));
                            }
                        }
                        store.save_settings(&settings).map_err(|e| e.to_string())?;
                        if settings["notesUseAI"] == false {
                            workspace.cancel_note_jobs();
                        }
                        platform::set_wayland_current_cursor(
                            settings["waylandCurrentCursor"].as_bool().unwrap_or(false),
                        );
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
                    let _ = workspace.audio.remove(&id);
                    let result = store
                        .delete_dictation(&id)
                        .and_then(|_| store.history(10000))
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
                    let onboarding = state.view.lock().unwrap().settings["onboardingComplete"]
                        .as_bool()
                        .unwrap_or(false);
                    let mut result = serde_json::from_str::<storage::Snapshot>(&source)
                        .map_err(|e| e.to_string())
                        .and_then(|mut snapshot| {
                            // Completing setup in the Swift app cannot attest to this
                            // newly installed app's permissions or insertion.
                            if let Some(settings) = snapshot.settings.as_object_mut() {
                                settings.insert("onboardingComplete".into(), json!(onboarding));
                            }
                            store.import(&snapshot).map_err(|e| e.to_string())
                        })
                        .map(|_| ());
                    if result.is_ok() {
                        let refreshed = (|| -> pressay_core::Result<_> {
                            Ok((store.settings()?, store.history(10000)?, store.notes()?))
                        })();
                        match refreshed {
                            Ok((settings, history, notes)) => {
                                if let Some(controller) =
                                    app.try_state::<crate::shortcuts::ShortcutController>()
                                {
                                    let binding =
                                        crate::shortcuts::Binding::from_settings(&settings);
                                    if binding != controller.binding() {
                                        if let Err(e) = controller.rebind(binding) {
                                            result = Err(e);
                                        }
                                    }
                                }
                                let model_changed = loaded.as_ref().is_some_and(|(model, _)| {
                                    settings["asrModel"].as_str() != Some(model)
                                });
                                if model_changed {
                                    host.lock().await.stop().await;
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
        if let Some(controller) = app.try_state::<crate::shortcuts::ShortcutController>() {
            controller.shutdown();
        }
        workspace.cancel_all();
        if let Some((capture, target, _)) = capture.take() {
            platform::release_target(target);
            let _ = tokio::task::spawn_blocking(move || capture.cancel()).await;
        }
        if let Some(streamer) = streamer.take() {
            streamer.cancel().await;
        }
        if let Some(m) = meeting.take() {
            m.stop.cancel();
            if state.view.lock().unwrap().active_note.is_none() {
                m.cancel.cancel();
            }
            let _ = m.task.await;
        }
        host.lock().await.stop().await;
        let _ = tokio::task::spawn_blocking(crate::feedback::shutdown).await;
        if let Err(error) = workspace.shutdown().await {
            *state.shutdown_error.lock().unwrap() = Some(error.clone());
            update(&app, &state, |s| {
                s.error = Some(format!(
                    "{error}. Finish or cancel any credential prompt, then quit again."
                ))
            });
            // Report the timeout without abandoning the owned work. A delayed
            // Keychain prompt may finish later; do not make its error permanent.
            state.stopped.cancel();
            while workspace.shutdown().await.is_err() {}
            *state.shutdown_error.lock().unwrap() = None;
            update(&app, &state, |s| {
                s.error = Some("Cleanup finished. You can quit Pressay.".into())
            });
        }
        state.stopped.cancel();
    });
    Ok(shared)
}

struct TargetGuard(u64);
impl Drop for TargetGuard {
    fn drop(&mut self) {
        platform::release_target(self.0);
    }
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
                    shortcut_label: crate::shortcuts::Binding::default().label(),
                    shortcut_error: None,
                    error: None,
                    model_ready: true,
                    progress: None,
                    settings: json!({"asrModel":"moss"}),
                    history: vec![],
                    notes: vec![],
                    practice: Practice::default(),
                    active_note: None,
                    meeting_elapsed: 0.,
                    audio_levels: [0.; 4],
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
                shutdown_error: Mutex::new(None),
                meeting_stop: Mutex::new(None),
                microphone_worked: AtomicBool::new(false),
                shortcut_registered: AtomicBool::new(true),
            }),
            rx,
        )
    }

    #[tokio::test]
    async fn full_command_queue_cannot_turn_meeting_stop_into_discard() {
        let (shared, _rx) = shared(1);
        shared.view.lock().unwrap().active_note = Some("saved-partial-meeting".into());
        let stop = CancellationToken::new();
        let cancel = crate::meeting::Cancellation::new();
        *shared.meeting_stop.lock().unwrap() = Some((stop.clone(), cancel.clone()));
        shared
            .tx
            .try_send(Queued {
                generation: 0,
                command: Command::Stop,
            })
            .unwrap();
        shared.send(Command::StopMeeting).unwrap();
        assert!(stop.is_cancelled());
        assert!(!cancel.is_discarded());
        assert_eq!(shared.generation.load(Ordering::Acquire), 0);
    }

    #[tokio::test]
    async fn meeting_discard_is_signalled_before_the_actor_drains_its_queue() {
        let (shared, _rx) = shared(1);
        let cancellation = crate::meeting::Cancellation::new();
        *shared.meeting_stop.lock().unwrap() =
            Some((CancellationToken::new(), cancellation.clone()));
        shared
            .tx
            .try_send(Queued {
                generation: 0,
                command: Command::Stop,
            })
            .unwrap();
        shared.send(Command::Cancel).unwrap();
        assert!(cancellation.is_discarded());
    }

    #[tokio::test]
    async fn sleep_or_escape_during_a_meeting_never_discards_it() {
        let (shared, _rx) = shared(8);
        let cancellation = crate::meeting::Cancellation::new();
        *shared.meeting_stop.lock().unwrap() =
            Some((CancellationToken::new(), cancellation.clone()));
        for stage in ["meeting_starting", "meeting", "idle"] {
            shared.view.lock().unwrap().stage = stage.into();
            shared.cancel_dictation();
        }
        assert!(!cancellation.is_discarded());
        assert_eq!(shared.generation.load(Ordering::Acquire), 0);
        shared.view.lock().unwrap().stage = "recording".into();
        shared.cancel_dictation();
        assert_eq!(shared.generation.load(Ordering::Acquire), 1);
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
        let meeting_cancel = crate::meeting::Cancellation::new();
        *shared.meeting_stop.lock().unwrap() =
            Some((CancellationToken::new(), meeting_cancel.clone()));
        let stopping = shared.clone();
        let task = tokio::spawn(async move { stopping.shutdown().await });
        shared.shutdown.cancelled().await;
        assert!(
            !meeting_cancel.is_discarded(),
            "Quitting must drain and save the meeting"
        );
        assert!(!task.is_finished());
        assert!(!shared.shutdown_complete());
        assert!(shared.send(Command::Start).is_err());
        shared.stopped.cancel();
        task.await.unwrap().unwrap();
        assert!(shared.shutdown_complete());
    }
}
