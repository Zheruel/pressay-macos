#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod app_metadata;
mod audio;
mod dictation;
mod engine;
mod feedback;
mod lifecycle;
mod meeting;
mod meeting_capture;
mod migration_audio;
mod onboarding_window;
mod platform;
mod shortcuts;
mod tray;
#[cfg(target_os = "linux")]
mod wayland;
mod workspace;
use engine::{Command, Shared};
use serde::Serialize;
use serde_json::Value;
use std::{
    path::PathBuf,
    sync::{atomic::Ordering, Arc},
};
use tauri::{Manager, State};

#[derive(Serialize)]
struct Status {
    view: engine::ViewState,
    permissions: platform::Permissions,
    models: Vec<serde_json::Value>,
    shortcut: String,
    platform: &'static str,
    locale: Option<String>,
    jobs: Vec<String>,
}
#[tauri::command]
fn status(app: tauri::AppHandle, state: State<'_, Arc<Shared>>) -> Status {
    let view = state.view.lock().unwrap().clone();
    let shortcut = view.shortcut_label.clone();
    Status {
        platform: std::env::consts::OS,
        locale: app_metadata::locale(),
        jobs: app.state::<Arc<workspace::Workspace>>().job_ids(),
        view,
        permissions: platform::permissions(
            state.shortcut_registered.load(Ordering::Relaxed),
            state.microphone_worked.load(Ordering::Relaxed),
        ),
        models: pressay_core::catalog::models()
            .iter()
            .filter(|m| m.supported())
            .map(|m| {
                let mut value = serde_json::to_value(m).expect("model catalog serializes");
                value["languageCaption"] = serde_json::json!(m.language_caption());
                value["secondary"] = serde_json::json!(m.is_secondary());
                value["supportsLanguageHint"] = serde_json::json!(m.supports_language_hint());
                value["languageCodes"] = serde_json::json!(m.language_codes());
                value
            })
            .collect(),
        shortcut,
    }
}
#[tauri::command]
fn prepare_model(id: String, state: State<'_, Arc<Shared>>) -> Result<(), String> {
    if state.view.lock().unwrap().stage != "idle" {
        return Err("Finish the current operation first".into());
    }
    state.send(Command::Prepare(id))
}
#[tauri::command]
fn cancel(state: State<'_, Arc<Shared>>) {
    state.cancel();
}
#[tauri::command]
fn request_permission(kind: String) -> Result<(), String> {
    platform::request_permission(&kind)
}
#[tauri::command]
async fn input_devices() -> Result<Vec<String>, String> {
    tokio::task::spawn_blocking(audio::list_inputs)
        .await
        .map_err(|e| e.to_string())?
}
#[derive(Serialize)]
struct InputDeviceSelection {
    devices: Vec<String>,
    #[serde(rename = "deviceOptions")]
    device_options: Vec<audio::InputDevice>,
    selected: Option<String>,
    unavailable: bool,
}
#[tauri::command]
async fn input_device_selection(
    state: State<'_, Arc<Shared>>,
) -> Result<InputDeviceSelection, String> {
    let settings = state.view.lock().unwrap().settings.clone();
    tokio::task::spawn_blocking(move || {
        let device_options = audio::list_input_options()?;
        let resolved = audio::resolve_input_from(&settings, &device_options);
        let unavailable = resolved.is_err();
        let selected = resolved.unwrap_or_else(|_| {
            settings["inputDevice"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .or_else(|| {
                    settings["inputDeviceUID"]
                        .as_str()
                        .filter(|s| !s.is_empty())
                        .map(|uid| format!("cpal:coreaudio:{uid}"))
                })
        });
        let devices = device_options
            .iter()
            .map(|device| device.name.clone())
            .collect();
        Ok(InputDeviceSelection {
            devices,
            device_options,
            selected,
            unavailable,
        })
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
async fn save_settings(patch: Value, state: State<'_, Arc<Shared>>) -> Result<(), String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    state.send(Command::Settings(patch, tx))?;
    rx.await.map_err(|e| e.to_string())?
}
#[tauri::command]
async fn complete_onboarding(
    observed: String,
    state: State<'_, Arc<Shared>>,
) -> Result<(), String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    state.send(Command::Complete(observed, tx))?;
    rx.await.map_err(|e| e.to_string())?
}
#[tauri::command]
async fn begin_practice(state: State<'_, Arc<Shared>>) -> Result<(), String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    state.send(Command::BeginPractice(tx))?;
    rx.await.map_err(|e| e.to_string())?
}
#[tauri::command]
async fn delete_dictation(id: String, state: State<'_, Arc<Shared>>) -> Result<(), String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    state.send(Command::Delete(id, tx))?;
    rx.await.map_err(|e| e.to_string())?
}
#[tauri::command]
async fn import_migration(source: String, state: State<'_, Arc<Shared>>) -> Result<(), String> {
    if source.len() > 32 * 1024 * 1024 {
        return Err("Migration export is too large".into());
    }
    let (tx, rx) = tokio::sync::oneshot::channel();
    state.send(Command::Import(source, tx))?;
    rx.await.map_err(|e| e.to_string())?
}
#[tauri::command]
fn copy_text(text: String) -> Result<(), String> {
    arboard::Clipboard::new()
        .map_err(|e| e.to_string())?
        .set_text(text)
        .map_err(|e| e.to_string())
}
#[tauri::command]
async fn quit(app: tauri::AppHandle, state: State<'_, Arc<Shared>>) -> Result<(), String> {
    state.shutdown().await?;
    app.exit(0);
    Ok(())
}
#[tauri::command]
async fn start_meeting(
    kind: String,
    from_call: Option<bool>,
    app: tauri::AppHandle,
    state: State<'_, Arc<Shared>>,
) -> Result<(), String> {
    if !["voice", "meeting"].contains(&kind.as_str()) {
        return Err("Invalid recording type".into());
    }
    {
        let mut view = state.view.lock().unwrap();
        if view.stage != "idle" {
            return Err("Finish the current operation first".into());
        }
        view.stage = "meeting_starting".into();
    }
    lifecycle::bind_call_recording(&app, &kind, from_call.unwrap_or(false));
    let (tx, rx) = tokio::sync::oneshot::channel();
    if let Err(e) = state.send(Command::StartMeeting(kind, tx)) {
        lifecycle::bind_call_recording(&app, "", false);
        state.view.lock().unwrap().stage = "idle".into();
        return Err(e);
    }
    let result = rx
        .await
        .map_err(|e| e.to_string())
        .and_then(|result| result);
    if result.is_err() {
        lifecycle::bind_call_recording(&app, "", false);
        state.view.lock().unwrap().stage = "idle".into();
    }
    result
}
#[tauri::command]
fn stop_meeting(state: State<'_, Arc<Shared>>) -> Result<(), String> {
    state.send(Command::StopMeeting)
}
#[tauri::command]
async fn change_shortcut(
    binding: shortcuts::Binding,
    app: tauri::AppHandle,
    state: State<'_, Arc<Shared>>,
) -> Result<(), String> {
    if state.view.lock().unwrap().stage != "idle" {
        return Err("Finish the current operation first".into());
    }
    let controller = app.state::<shortcuts::ShortcutController>();
    shortcuts::change_binding(
        controller.binding(),
        binding,
        |candidate| controller.rebind(candidate),
        |candidate| save_settings(serde_json::json!({"shortcut":candidate}), state),
    )
    .await
}
#[tauri::command]
async fn show_workspace(page: String, app: tauri::AppHandle) -> Result<(), String> {
    if page == "onboarding" {
        tray::tray_hide(app.clone())?;
        return onboarding_window::open_onboarding(app).await;
    }
    tray::open_workspace(&app, &page)
}
fn main() {
    tauri::Builder::default()
        .plugin(
            tauri_plugin_window_state::Builder::default()
                .with_state_flags(
                    tauri_plugin_window_state::StateFlags::SIZE
                        | tauri_plugin_window_state::StateFlags::POSITION
                        | tauri_plugin_window_state::StateFlags::MAXIMIZED,
                )
                .with_filter(|label| label == "main")
                .build(),
        )
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_dialog::init())
        .plugin(
            tauri_plugin_autostart::Builder::new()
                .args(["--background"])
                .build(),
        )
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(tauri::generate_handler![
            status,
            prepare_model,
            cancel,
            request_permission,
            input_devices,
            app_metadata::history_app_metadata,
            input_device_selection,
            save_settings,
            complete_onboarding,
            begin_practice,
            onboarding_window::open_onboarding,
            onboarding_window::close_onboarding,
            delete_dictation,
            workspace::clear_history,
            import_migration,
            copy_text,
            quit,
            show_workspace,
            tray::tray_hide,
            tray::tray_resize,
            start_meeting,
            stop_meeting,
            change_shortcut,
            shortcuts::set_shortcut_capture,
            lifecycle::launch_at_login,
            lifecycle::autostart_status,
            lifecycle::check_update,
            lifecycle::install_update,
            workspace::export_reminders,
            workspace::edit_dictation,
            workspace::retry_dictation,
            workspace::recording,
            workspace::edit_note,
            workspace::delete_note,
            workspace::toggle_action,
            workspace::cancel_note_job,
            workspace::write_note,
            workspace::ask_notes,
            workspace::account_status,
            workspace::verify_api_key,
            workspace::open_claude_install,
            workspace::save_api_key,
            workspace::import_mac_api_keys,
            migration_audio::import_mac_audio,
            workspace::chatgpt_sign_in,
            workspace::claude_sign_in,
            workspace::cancel_sign_in,
            workspace::chatgpt_sign_out,
            workspace::export_data
        ])
        .setup(|app| {
            app.manage(lifecycle::Updates::default());
            let resources = app.path().resource_dir()?;
            let development = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            let runtime = std::env::var_os("PRESSAY_RUNTIME_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    if cfg!(debug_assertions) {
                        development.join("runtime")
                    } else {
                        resources.join("runtime")
                    }
                });
            let name = if cfg!(windows) {
                "pressay-asr-worker.exe"
            } else {
                "pressay-asr-worker"
            };
            let worker = std::env::var_os("PRESSAY_WORKER_PATH")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    if cfg!(debug_assertions) {
                        development.join("../../../target/debug").join(name)
                    } else {
                        resources.join("binaries").join(name)
                    }
                });
            let data = if cfg!(debug_assertions) {
                std::env::var_os("PRESSAY_DATA_DIR")
                    .map(PathBuf::from)
                    .unwrap_or(app.path().app_data_dir()?)
            } else {
                app.path().app_data_dir()?
            };
            let workspace =
                workspace::Workspace::new(data.clone()).map_err(std::io::Error::other)?;
            app.manage(workspace.clone());
            let shared = engine::launch(
                app.handle().clone(),
                data.clone(),
                runtime,
                worker,
                workspace,
            )
            .map_err(std::io::Error::other)?;
            app.manage(shared.clone());
            let update_failure = lifecycle::take_update_failure(&data);
            let update_failed = update_failure.is_some();
            feedback::initialize();
            let stopping = shared.clone();
            platform::set_stop_callback(Arc::new(move || {
                let _ = stopping.send(Command::StopMeeting);
            }));
            let settings = shared.view.lock().unwrap().settings.clone();
            platform::initialize(
                data,
                settings["waylandCurrentCursor"].as_bool().unwrap_or(false),
            );
            let binding = shortcuts::Binding::from_settings(&settings);
            let callback_app = app.handle().clone();
            let callback_shared = shared.clone();
            let controller = shortcuts::install(app.handle().clone(), binding, move |event| {
                use shortcuts::Event;
                match event {
                    Event::Pressed => {
                        if let Err(error) = callback_shared.send(Command::Start) {
                            engine::reject_start(&callback_app, &callback_shared, error);
                        }
                    }
                    Event::Released => {
                        let _ = callback_shared.send(Command::Stop);
                    }
                    Event::Cancel | Event::Suspended => callback_shared.cancel_dictation(),
                    Event::Availability {
                        available,
                        trigger,
                        error,
                    } => {
                        callback_shared
                            .shortcut_registered
                            .store(available, Ordering::Release);
                        engine::update(&callback_app, &callback_shared, |s| {
                            s.shortcut_label = trigger;
                            s.shortcut_error = error;
                        });
                    }
                }
            })
            .map_err(std::io::Error::other)?;
            app.manage(controller);
            onboarding_window::install(
                app.handle(),
                !settings["onboardingComplete"].as_bool().unwrap_or(false),
            )
            .map_err(std::io::Error::other)?;
            lifecycle::watch_calls(app.handle().clone(), shared.clone());
            workspace::resume_pending_writeups(
                app.handle().clone(),
                app.state::<Arc<workspace::Workspace>>().inner().clone(),
            );
            #[cfg(not(target_os = "macos"))]
            tauri::WebviewWindowBuilder::new(
                app,
                "overlay",
                tauri::WebviewUrl::App("overlay.html".into()),
            )
            .title("Pressay dictation")
            .inner_size(560., 150.)
            .transparent(true)
            .decorations(false)
            .resizable(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .focused(false)
            .focusable(false)
            .visible(false)
            .build()?;
            if let Some(overlay) = app.get_webview_window("overlay") {
                let _ = overlay.set_ignore_cursor_events(true);
            }
            // Keep close-to-quit behavior on desktops without a tray host.
            let has_tray = tray::install(app).is_ok();
            engine::track_overlay(app.handle().clone(), shared.clone());
            if has_tray {
                if let Some(window) = app.get_webview_window("main") {
                    let w = window.clone();
                    window.on_window_event(move |event| {
                        if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                            api.prevent_close();
                            let _ = w.hide();
                        }
                    });
                }
            }
            if has_tray && std::env::args().any(|a| a == "--background") {
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.hide();
                }
            }
            if shared.view.lock().unwrap().settings["onboardingComplete"]
                .as_bool()
                .unwrap_or(false)
            {
                if update_failed || !(has_tray && std::env::args().any(|a| a == "--background")) {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                }
                let model = shared.view.lock().unwrap().settings["asrModel"]
                    .as_str()
                    .unwrap_or("parakeetUltra")
                    .to_string();
                let _ = shared.send(Command::Prepare(model));
            }
            if let Some(message) = update_failure {
                lifecycle::show_update_failure(app.handle(), message);
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Pressay desktop could not start")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested {
                code: None, api, ..
            } = event
            {
                let state = app.state::<Arc<Shared>>().inner().clone();
                if state.shutdown_complete() {
                    return;
                }
                api.prevent_exit();
                let app = app.clone();
                tauri::async_runtime::spawn(async move {
                    if state.shutdown().await.is_ok() {
                        app.exit(0);
                    } else if let Some(w) = app.get_webview_window("main") {
                        let _ = w.show();
                        let _ = w.set_focus();
                    }
                });
            }
        });
}
