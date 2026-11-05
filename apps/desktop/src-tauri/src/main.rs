#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod audio;
mod engine;
mod platform;
use engine::{Command, Shared};
use serde::Serialize;
use serde_json::Value;
use std::{
    path::PathBuf,
    sync::{atomic::Ordering, Arc},
};
use tauri::{Emitter, Manager, State};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};

#[derive(Serialize)]
struct Status {
    view: engine::ViewState,
    permissions: platform::Permissions,
    models: Vec<pressay_core::catalog::Model>,
    shortcut: &'static str,
}
#[tauri::command]
fn status(state: State<'_, Arc<Shared>>) -> Status {
    Status {
        view: state.view.lock().unwrap().clone(),
        permissions: platform::permissions(
            state.shortcut_registered.load(Ordering::Relaxed),
            state.microphone_worked.load(Ordering::Relaxed),
        ),
        models: pressay_core::catalog::models()
            .iter()
            .filter(|m| m.supported() && m.id != "megaASR")
            .cloned()
            .collect(),
        shortcut: "Ctrl + Shift + Space",
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
fn input_devices() -> Result<Vec<String>, String> {
    audio::list_inputs()
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
    state.shutdown().await;
    app.exit(0);
    Ok(())
}
fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .invoke_handler(tauri::generate_handler![
            status,
            prepare_model,
            cancel,
            request_permission,
            input_devices,
            save_settings,
            complete_onboarding,
            delete_dictation,
            import_migration,
            copy_text,
            quit
        ])
        .setup(|app| {
            let resources = app.path().resource_dir()?;
            let development = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            let runtime = std::env::var_os("PRESSAY_RUNTIME_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    if cfg!(debug_assertions) {
                        let mac = development
                            .join("../../../.build/Pressay.app/Contents/Resources/ASRRuntime");
                        if cfg!(target_os = "macos") && mac.exists() {
                            mac
                        } else {
                            development.join("runtime")
                        }
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
            let shared = engine::launch(
                app.handle().clone(),
                app.path().app_data_dir()?,
                runtime,
                worker,
            )
            .map_err(std::io::Error::other)?;
            app.manage(shared.clone());
            let registered =
                app.global_shortcut()
                    .on_shortcut("Control+Shift+Space", |app, _, event| {
                        let state = app.state::<Arc<Shared>>();
                        let result = if event.state == ShortcutState::Pressed {
                            if state.view.lock().unwrap().stage == "idle" {
                                state.send(Command::Start)
                            } else {
                                Ok(())
                            }
                        } else {
                            state.send(Command::Stop)
                        };
                        if let Err(error) = result {
                            let snapshot = {
                                let mut view = state.view.lock().unwrap();
                                view.error = Some(error);
                                view.clone()
                            };
                            let _ = app.emit("pressay-state", snapshot);
                        }
                    });
            shared
                .shortcut_registered
                .store(registered.is_ok(), Ordering::Relaxed);
            if let Err(e) = registered {
                shared.view.lock().unwrap().error =
                    Some(format!("Global shortcut unavailable: {e}"));
            }
            tauri::WebviewWindowBuilder::new(
                app,
                "overlay",
                tauri::WebviewUrl::App("overlay.html".into()),
            )
            .title("Pressay dictation")
            .inner_size(280., 58.)
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
            let show =
                tauri::menu::MenuItem::with_id(app, "show", "Open Pressay", true, None::<&str>)?;
            let quit =
                tauri::menu::MenuItem::with_id(app, "quit", "Quit Pressay", true, None::<&str>)?;
            let menu = tauri::menu::Menu::with_items(app, &[&show, &quit])?;
            let mut tray = tauri::tray::TrayIconBuilder::new()
                .menu(&menu)
                .tooltip("Pressay Preview")
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "show" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = w.show();
                            let _ = w.set_focus();
                        }
                    }
                    "quit" => {
                        let app = app.clone();
                        let state = app.state::<Arc<Shared>>().inner().clone();
                        tauri::async_runtime::spawn(async move {
                            state.shutdown().await;
                            app.exit(0);
                        });
                    }
                    _ => {}
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            // Without a tray, keep normal close-to-quit behavior so the app cannot
            // strand an invisible microphone process on desktops without a tray host.
            let has_tray = tray.build(app).is_ok();
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
                    state.shutdown().await;
                    app.exit(0);
                });
            }
        });
}
