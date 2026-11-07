use crate::{engine::Shared, platform};
use serde_json::{json, Value};
use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_updater::UpdaterExt;
const UPDATE_FAILURE_NOTICE: &str = "update-install-failure.txt";

fn update_failure_message(error: &str) -> String {
    let detail: String = error
        .chars()
        .filter(|c| !c.is_control())
        .take(1_000)
        .collect();
    format!(
        "The update could not be installed. Pressay restarted so you can keep using it. {detail}"
    )
}
fn save_update_failure(directory: &std::path::Path, message: &str) -> Result<(), std::io::Error> {
    use std::io::Write;
    let mut file = tempfile::NamedTempFile::new_in(directory)?;
    file.write_all(message.as_bytes())?;
    file.as_file().sync_all()?;
    file.persist(directory.join(UPDATE_FAILURE_NOTICE))
        .map_err(|error| error.error)?;
    Ok(())
}
pub fn take_update_failure(directory: &std::path::Path) -> Option<String> {
    use std::io::Read;
    let path = directory.join(UPDATE_FAILURE_NOTICE);
    let mut message = String::new();
    std::fs::File::open(&path)
        .ok()?
        .take(8_193)
        .read_to_string(&mut message)
        .ok()?;
    if std::fs::remove_file(path).is_err() || message.is_empty() || message.len() > 8_192 {
        return None;
    }
    Some(message)
}
pub fn show_update_failure(app: &AppHandle, message: String) {
    use tauri_plugin_dialog::{DialogExt, MessageDialogKind};
    app.dialog()
        .message(message)
        .title("Update could not be installed")
        .kind(MessageDialogKind::Error)
        .show(|_| {});
}
#[derive(Default)]
pub struct Updates {
    pending: Mutex<Option<tauri_plugin_updater::Update>>,
    installing: std::sync::atomic::AtomicBool,
}
#[tauri::command]
pub fn autostart_status(app: AppHandle) -> Result<bool, String> {
    app.autolaunch().is_enabled().map_err(|e| e.to_string())
}
#[tauri::command]
pub fn launch_at_login(enabled: bool, app: AppHandle) -> Result<(), String> {
    if enabled {
        app.autolaunch().enable()
    } else {
        app.autolaunch().disable()
    }
    .map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn check_update(app: AppHandle) -> Result<Value, String> {
    let Some(key) = option_env!("PRESSAY_UPDATE_PUBLIC_KEY").filter(|s| !s.trim().is_empty())
    else {
        return Ok(
            json!({"available":false,"message":"This development build has no signed update channel. Install a release build to receive updates."}),
        );
    };
    let endpoint =
        "https://github.com/Zheruel/pressay-macos/releases/download/desktop-updates/desktop-latest.json"
            .parse()
            .map_err(|_| "Invalid update endpoint")?;
    let update = app
        .updater_builder()
        .pubkey(key)
        .endpoints(vec![endpoint])
        .map_err(|e| e.to_string())?
        .build()
        .map_err(|e| e.to_string())?
        .check()
        .await
        .map_err(|e| e.to_string())?;
    let value = match &update {
        Some(u) => {
            json!({"available":true,"version":u.version,"message":format!("Pressay {} is available",u.version)})
        }
        None => json!({"available":false,"message":"You’re up to date."}),
    };
    *app.state::<Updates>().pending.lock().unwrap() = update;
    Ok(value)
}
#[tauri::command]
pub async fn install_update(app: AppHandle, state: State<'_, Arc<Shared>>) -> Result<(), String> {
    use std::sync::atomic::Ordering;
    if state.view.lock().unwrap().stage != "idle" {
        return Err("Finish your current recording or model preparation before updating".into());
    }
    if app
        .state::<Updates>()
        .installing
        .swap(true, Ordering::AcqRel)
    {
        return Err("An update is already being installed".into());
    }
    let result = async {
        let update = app
            .state::<Updates>()
            .pending
            .lock()
            .unwrap()
            .take()
            .ok_or("Check for updates first")?;
        let bytes = update
            .download(|_, _| {}, || {})
            .await
            .map_err(|e| e.to_string())?;
        if state.view.lock().unwrap().stage != "idle" {
            return Err(
                "A recording started while downloading. Finish it before installing.".into(),
            );
        }
        // Signature verification happens in download; quiesce native resources
        // before the installer can replace executables or exit the process.
        state.shutdown().await?;
        if let Err(error) = update.install(bytes) {
            let message = update_failure_message(&error.to_string());
            let workspace = app.state::<Arc<crate::workspace::Workspace>>();
            if save_update_failure(&workspace.data, &message).is_err() {
                use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};
                app.dialog()
                    .message(format!("The update could not be installed: {error}\n\nPressay will restart to resume dictation."))
                    .title("Update could not be installed")
                    .kind(MessageDialogKind::Error)
                    .buttons(MessageDialogButtons::OkCustom("Restart Pressay".into()))
                    .blocking_show();
            }
        }
        app.restart();
    }
    .await;
    app.state::<Updates>()
        .installing
        .store(false, Ordering::Release);
    result
}
#[derive(Default)]
struct CallRecording {
    eligible: bool,
    bound: bool,
    note: Option<String>,
}
impl CallRecording {
    fn begin(&mut self, kind: &str, from_call: bool) {
        self.eligible = kind == "meeting";
        self.bound = self.eligible && from_call;
        self.note = None;
    }
    fn observe(&mut self, stage: &str, note: Option<&str>) {
        if !stage.starts_with("meeting") {
            *self = Self::default();
        } else if self.bound {
            match (&self.note, note) {
                (None, Some(note)) => self.note = Some(note.into()),
                (Some(saved), Some(note)) if saved != note => *self = Self::default(),
                _ => {}
            }
        }
    }
    fn started(&mut self, stage: &str, note: Option<&str>) {
        self.observe(stage, note);
        // Like the native app, a call starting during an existing meeting binds
        // that recording. A later manual recording resets the previous binding.
        if self.eligible && matches!(stage, "meeting_starting" | "meeting") {
            self.bound = true;
            self.note = note.map(str::to_owned);
        }
    }
    fn ended(&mut self, stage: &str, note: Option<&str>) -> bool {
        self.observe(stage, note);
        let stop = self.bound && matches!(stage, "meeting_starting" | "meeting");
        self.bound = false;
        self.note = None;
        stop
    }
}
#[derive(Default)]
struct Calls {
    recording: Mutex<CallRecording>,
    active: std::sync::atomic::AtomicBool,
}
impl Calls {
    fn begin(&self, kind: &str, from_call: bool) {
        let active = self.active.load(std::sync::atomic::Ordering::Acquire);
        self.recording
            .lock()
            .unwrap()
            .begin(kind, from_call || active);
    }
}
pub fn bind_call_recording(app: &AppHandle, kind: &str, from_call: bool) {
    if let Some(calls) = app.try_state::<Calls>() {
        calls.begin(kind, from_call);
    }
}
pub fn watch_calls(app: AppHandle, state: Arc<Shared>) {
    app.manage(Calls::default());
    tauri::async_runtime::spawn(async move {
        let mut candidate: Option<(String, Instant)> = None;
        let mut announced: Option<String> = None;
        let mut absent: Option<Instant> = None;
        let mut interval = tokio::time::interval(Duration::from_secs(2));
        loop {
            interval.tick().await;
            if state.is_shutting_down() {
                break;
            }
            // Detection remains active even when suggestions are disabled: an
            // existing call-bound recording must still stop when its call ends.
            let active = tokio::task::spawn_blocking(platform::active_call)
                .await
                .ok()
                .flatten();
            let (enabled, stage, note) = {
                let view = state.view.lock().unwrap();
                (
                    view.settings["detectCalls"].as_bool().unwrap_or(true),
                    view.stage.clone(),
                    view.active_note.clone(),
                )
            };
            let calls = app.state::<Calls>();
            calls
                .recording
                .lock()
                .unwrap()
                .observe(&stage, note.as_deref());
            if !enabled {
                let _ = app.emit("pressay-call", json!({"active":false}));
            }
            match active {
                Some(name) => {
                    absent = None;
                    if candidate.as_ref().is_none_or(|(n, _)| *n != name) {
                        candidate = Some((name.clone(), Instant::now()));
                    }
                    if candidate
                        .as_ref()
                        .is_some_and(|(_, at)| at.elapsed() >= Duration::from_secs(4))
                        && announced.as_ref() != Some(&name)
                    {
                        announced = Some(name.clone());
                        calls
                            .active
                            .store(true, std::sync::atomic::Ordering::Release);
                        calls
                            .recording
                            .lock()
                            .unwrap()
                            .started(&stage, note.as_deref());
                        if enabled {
                            let _ =
                                app.emit("pressay-call", json!({"active":true,"application":name}));
                        }
                    }
                }
                None => {
                    candidate = None;
                    let since = absent.get_or_insert_with(Instant::now);
                    if since.elapsed() >= Duration::from_secs(10) {
                        calls
                            .active
                            .store(false, std::sync::atomic::Ordering::Release);
                        let stop = calls
                            .recording
                            .lock()
                            .unwrap()
                            .ended(&stage, note.as_deref());
                        if stop {
                            let _ = state.send(crate::engine::Command::StopMeeting);
                        }
                        if announced.take().is_some() {
                            let _ = app.emit("pressay-call", json!({"active":false}));
                        }
                    }
                }
            }
        }
    });
}
#[cfg(test)]
mod tests {
    use super::CallRecording;
    #[test]
    fn manual_start_uses_current_call_and_never_inherits_stale_binding() {
        let calls = super::Calls::default();
        calls
            .active
            .store(true, std::sync::atomic::Ordering::Release);
        calls.begin("meeting", false);
        assert!(calls
            .recording
            .lock()
            .unwrap()
            .ended("meeting", Some("current")));
        calls.begin("voice", false);
        assert!(!calls
            .recording
            .lock()
            .unwrap()
            .ended("meeting", Some("voice")));
        calls
            .active
            .store(false, std::sync::atomic::Ordering::Release);
        calls.begin("meeting", false);
        assert!(!calls
            .recording
            .lock()
            .unwrap()
            .ended("meeting", Some("later")));
    }

    #[test]
    fn call_end_only_stops_the_bound_recording_and_clears_it() {
        let mut call = CallRecording::default();
        call.begin("meeting", true);
        call.observe("meeting", Some("first"));
        assert!(call.ended("meeting", Some("first")));
        assert!(!call.ended("meeting", Some("first")));
        call.begin("meeting", false);
        assert!(!call.ended("meeting", Some("manual")));
    }
    #[test]
    fn call_start_can_bind_an_existing_meeting_but_not_voice_notes() {
        let mut call = CallRecording::default();
        call.begin("meeting", false);
        call.started("meeting", Some("manual"));
        assert!(call.ended("meeting", Some("manual")));
        call.begin("voice", true);
        call.started("meeting", Some("voice"));
        assert!(!call.ended("meeting", Some("voice")));
    }
    #[test]
    fn preparation_can_stop_and_old_binding_cannot_stop_new_note() {
        let mut call = CallRecording::default();
        call.begin("meeting", true);
        assert!(call.ended("meeting_starting", None));
        call.begin("meeting", true);
        call.observe("meeting", Some("old"));
        assert!(!call.ended("meeting", Some("new")));
        call.begin("meeting", true);
        call.observe("idle", None);
        assert!(!call.ended("meeting", Some("new")));
        call.begin("meeting", true);
        assert!(!call.ended("meeting_finishing", Some("ending")));
    }
}
