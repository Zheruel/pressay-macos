//! The original setup is a separate fixed-size window, not a modal over Settings.
use crate::{
    engine::Shared,
    shortcuts::{self, ShortcutController},
};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};

pub fn install(app: &AppHandle, first_run: bool) -> Result<(), String> {
    if first_run {
        if let Some(main) = app.get_webview_window("main") {
            main.hide().map_err(|e| e.to_string())?;
        }
        show(app)?;
    }
    Ok(())
}
fn stop_capture(app: &AppHandle) {
    if app.try_state::<ShortcutController>().is_some() {
        if let Some(state) = app.try_state::<Arc<Shared>>() {
            let _ = shortcuts::set_shortcut_capture(false, String::new(), app.clone(), state);
        }
    }
}
fn hide(app: &AppHandle) -> Result<(), String> {
    stop_capture(app);
    if let Some(window) = app.get_webview_window("onboarding") {
        let _ = window.emit("pressay-onboarding-hidden", ());
        window.hide().map_err(|e| e.to_string())?;
    }
    if !app
        .try_state::<Arc<Shared>>()
        .is_some_and(|state| state.is_shutting_down())
    {
        if let Some(main) = app.get_webview_window("main") {
            main.show().map_err(|e| e.to_string())?;
            main.set_focus().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}
#[tauri::command]
pub async fn open_onboarding(app: AppHandle) -> Result<(), String> {
    // WebView2 window creation deadlocks in synchronous commands. The setup
    // hook may create directly; later user requests run on a worker thread.
    tauri::async_runtime::spawn_blocking(move || show(&app))
        .await
        .map_err(|e| e.to_string())?
}
fn show(app: &AppHandle) -> Result<(), String> {
    static OPEN: Mutex<()> = Mutex::new(());
    let _opening = OPEN.lock().map_err(|_| "Could not open setup")?;
    if app
        .try_state::<Arc<Shared>>()
        .is_some_and(|state| state.is_shutting_down())
    {
        return Err("Pressay is shutting down".into());
    }
    if let Some(window) = app.get_webview_window("onboarding") {
        let _ = window.emit("pressay-onboarding-open", ());
        window.show().map_err(|e| e.to_string())?;
        return window.set_focus().map_err(|e| e.to_string());
    }
    let builder = tauri::WebviewWindowBuilder::new(
        app,
        "onboarding",
        tauri::WebviewUrl::App("index.html?onboarding".into()),
    )
    .title("Welcome to Pressay")
    .inner_size(540., 720.)
    .resizable(false)
    .maximizable(false)
    .visible(false)
    .center();
    #[cfg(target_os = "macos")]
    let builder = builder
        .title_bar_style(tauri::TitleBarStyle::Overlay)
        .hidden_title(true);
    let window = builder.build().map_err(|e| e.to_string())?;
    let owner = app.clone();
    window.on_window_event(move |event| match event {
        tauri::WindowEvent::CloseRequested { api, .. } => {
            api.prevent_close();
            let _ = hide(&owner);
        }
        tauri::WindowEvent::Focused(false) => stop_capture(&owner),
        _ => {}
    });
    window.show().map_err(|e| e.to_string())?;
    window.set_focus().map_err(|e| e.to_string())
}
#[tauri::command]
pub fn close_onboarding(app: AppHandle) -> Result<(), String> {
    hide(&app)
}
