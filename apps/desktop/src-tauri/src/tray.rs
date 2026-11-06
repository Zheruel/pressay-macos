//! Shared tray panel, with a real native menu where tray clicks are unavailable.
use crate::{engine::Shared, workspace::Workspace};
use std::sync::{atomic::Ordering, Arc, Mutex};
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Listener, Manager, PhysicalPosition, PhysicalSize};

const LABEL: &str = "tray";
const WIDTH: f64 = 348.;
#[derive(Clone, Copy, Debug)]
struct Anchor {
    work: [f64; 4],
    icon: [f64; 4],
    scale: f64,
}
#[derive(Default)]
struct TrayState {
    anchor: Mutex<Option<Anchor>>,
    height: Mutex<Option<f64>>,
    update: Mutex<Option<(String, bool)>>,
}

/// All coordinates are physical pixels. Clamp against the selected monitor's
/// work area, including negative origins and taskbars on any edge.
fn placement(anchor: Anchor, logical_height: f64) -> ([i32; 2], [u32; 2]) {
    let [left, top, width, height] = anchor.work;
    let margin = 6. * anchor.scale;
    let w = (WIDTH * anchor.scale).min((width - margin * 2.).max(1.));
    let h = (logical_height * anchor.scale).min((height - margin * 2.).max(1.));
    let [x, y, iw, ih] = anchor.icon;
    let below = y + ih + margin;
    let above = y - h - margin;
    let preferred = if below + h <= top + height - margin {
        below
    } else {
        above
    };
    let px = (x + iw / 2. - w / 2.).clamp(
        left + margin,
        (left + width - w - margin).max(left + margin),
    );
    let py = preferred.clamp(top + margin, (top + height - h - margin).max(top + margin));
    (
        [px.round() as i32, py.round() as i32],
        [w.round().max(1.) as u32, h.round().max(1.) as u32],
    )
}
fn resize(app: &AppHandle, height: f64) -> Result<(), String> {
    let Some(window) = app.get_webview_window(LABEL) else {
        return Ok(());
    };
    *app.state::<TrayState>().height.lock().unwrap() = Some(height);
    let anchor = *app.state::<TrayState>().anchor.lock().unwrap();
    if let Some(anchor) = anchor {
        let (position, size) = placement(anchor, height);
        window
            .set_size(PhysicalSize::new(size[0], size[1]))
            .map_err(|e| e.to_string())?;
        window
            .set_position(PhysicalPosition::new(position[0], position[1]))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
#[tauri::command]
pub fn tray_resize(height: f64, window: tauri::WebviewWindow) -> Result<(), String> {
    if window.label() != LABEL || !height.is_finite() || !(160. ..=1200.).contains(&height) {
        return Err("Invalid tray panel size".into());
    }
    resize(window.app_handle(), height)
}
#[tauri::command]
pub fn tray_hide(app: AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(LABEL) {
        window.hide().map_err(|e| e.to_string())?;
    }
    Ok(())
}
pub fn open_workspace(app: &AppHandle, page: &str) -> Result<(), String> {
    if ![
        "dictation",
        "history",
        "meetings",
        "dictionary",
        "general",
        "ai",
        "onboarding",
    ]
    .contains(&page)
    {
        return Err("Unknown workspace page".into());
    }
    tray_hide(app.clone())?;
    let window = app
        .get_webview_window("main")
        .ok_or("Workspace window is unavailable")?;
    window.show().map_err(|e| e.to_string())?;
    window.unminimize().map_err(|e| e.to_string())?;
    window.set_focus().map_err(|e| e.to_string())?;
    window
        .emit("pressay-navigate", page)
        .map_err(|e| e.to_string())
}
fn show_panel(
    app: &AppHandle,
    position: PhysicalPosition<f64>,
    rect: tauri::Rect,
) -> Result<(), String> {
    let window = app
        .get_webview_window(LABEL)
        .ok_or("Tray panel is unavailable")?;
    if window.is_visible().unwrap_or(false) {
        return window.hide().map_err(|e| e.to_string());
    }
    let monitor = app
        .monitor_from_point(position.x, position.y)
        .map_err(|e| e.to_string())?
        .or(app.primary_monitor().map_err(|e| e.to_string())?)
        .ok_or("No display is available")?;
    let scale = monitor.scale_factor();
    let work = monitor.work_area();
    let p = rect.position.to_physical::<f64>(scale);
    let s = rect.size.to_physical::<f64>(scale);
    *app.state::<TrayState>().anchor.lock().unwrap() = Some(Anchor {
        work: [
            work.position.x as f64,
            work.position.y as f64,
            work.size.width as f64,
            work.size.height as f64,
        ],
        icon: [p.x, p.y, s.width, s.height],
        scale,
    });
    let height = app
        .state::<TrayState>()
        .height
        .lock()
        .unwrap()
        .unwrap_or(650.);
    resize(app, height)?;
    window.show().map_err(|e| e.to_string())?;
    window.set_focus().map_err(|e| e.to_string())?;
    window
        .emit("pressay-tray-open", ())
        .map_err(|e| e.to_string())
}
fn fallback_menu(app: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let shared = app.state::<Arc<Shared>>();
    let view = shared.view.lock().unwrap().clone();
    let permissions = crate::platform::permissions(
        shared.shortcut_registered.load(Ordering::Relaxed),
        shared.microphone_worked.load(Ordering::Relaxed),
    );
    let menu = Menu::new(app)?;
    let item =
        |id: &str, label: &str, enabled| MenuItem::with_id(app, id, label, enabled, None::<&str>);
    menu.append(&item("tray-brand", "Pressay", false)?)?;
    use pressay_core::onboarding::Permission;
    let ready = view.model_ready
        && [
            permissions.microphone,
            permissions.shortcut,
            permissions.insertion,
        ]
        .iter()
        .all(|p| *p == Permission::Granted);
    menu.append(&item(
        "tray-status",
        if ready {
            "Ready to dictate"
        } else {
            "Speech or permissions need attention"
        },
        false,
    )?)?;
    if !view.settings["onboardingComplete"]
        .as_bool()
        .unwrap_or(false)
    {
        menu.append(&item("tray-setup", "Continue setup", true)?)?;
    } else {
        menu.append(&item(
            "tray-key",
            &format!("Hold to talk: {}", view.shortcut_label),
            false,
        )?)?;
        menu.append(&CheckMenuItem::with_id(
            app,
            "tray-ai",
            "AI Cleanup",
            true,
            view.settings["claudeCleanup"].as_bool().unwrap_or(true),
            None::<&str>,
        )?)?;
        menu.append(&PredefinedMenuItem::separator(app)?)?;
        if view.history.is_empty() {
            menu.append(&item("tray-empty", "Your dictations appear here.", false)?)?;
        }
        for record in view.history.iter().take(2) {
            let text = record
                .correction
                .as_deref()
                .filter(|t| !t.is_empty())
                .unwrap_or(&record.text);
            let label: String = text.chars().take(64).collect();
            let copy = item(&format!("tray-copy:{}", record.id), "Copy", true)?;
            let paste = item(
                &format!("tray-paste:{}", record.id),
                "Paste again",
                view.stage == "idle",
            )?;
            let delete = item(&format!("tray-delete:{}", record.id), "Delete", true)?;
            menu.append(&Submenu::with_items(
                app,
                label,
                true,
                &[&copy, &paste, &delete],
            )?)?;
        }
        menu.append(&PredefinedMenuItem::separator(app)?)?;
        let meeting_label = if view.stage == "meeting_starting" {
            "Cancel Notetaker setup"
        } else if view.stage.starts_with("meeting") {
            "Stop Notetaker"
        } else {
            "Start Notetaker"
        };
        menu.append(&item(
            "tray-meeting",
            meeting_label,
            ["idle", "meeting", "meeting_starting"].contains(&view.stage.as_str()),
        )?)?;
        menu.append(&item("tray-show", "Open Pressay", true)?)?;
        menu.append(&item("tray-settings", "Settings…", true)?)?;
    }
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    if let Some((message, available)) = app.state::<TrayState>().update.lock().unwrap().as_ref() {
        menu.append(&item("tray-update-notice", message, false)?)?;
        if *available {
            menu.append(&item(
                "tray-install",
                "Install update",
                view.stage == "idle",
            )?)?;
        }
    }
    menu.append(&item("tray-update", "Check for Updates…", true)?)?;
    menu.append(&item("tray-quit", "Quit Pressay", true)?)?;
    Ok(menu)
}
fn refresh_menu(app: &AppHandle) {
    if let (Some(tray), Ok(menu)) = (app.tray_by_id("pressay"), fallback_menu(app)) {
        let _ = tray.set_menu(Some(menu));
    }
}
fn menu_action(app: &AppHandle, id: &str) {
    let app = app.clone();
    let id = id.to_owned();
    tauri::async_runtime::spawn(async move {
        let result: Result<(), String> = async {
            match id.as_str() {
                "tray-show" => open_workspace(&app, "dictation"),
                "tray-setup" => {
                    tray_hide(app.clone())?;
                    crate::onboarding_window::open_onboarding(app.clone()).await
                }
                "tray-settings" => open_workspace(&app, "general"),
                "tray-ai" => {
                    let enabled = app.state::<Arc<Shared>>().view.lock().unwrap().settings
                        ["claudeCleanup"]
                        .as_bool()
                        .unwrap_or(true);
                    crate::save_settings(
                        serde_json::json!({"claudeCleanup": !enabled}),
                        app.state(),
                    )
                    .await
                }
                "tray-meeting" => {
                    let stage = app
                        .state::<Arc<Shared>>()
                        .view
                        .lock()
                        .unwrap()
                        .stage
                        .clone();
                    if stage == "meeting_starting" {
                        app.state::<Arc<Shared>>().cancel();
                        Ok(())
                    } else if stage.starts_with("meeting") {
                        crate::stop_meeting(app.state())
                    } else {
                        crate::start_meeting("meeting".into(), None, app.clone(), app.state())
                            .await?;
                        open_workspace(&app, "meetings")
                    }
                }
                "tray-update" => {
                    let value = crate::lifecycle::check_update(app.clone()).await?;
                    let message = value["message"]
                        .as_str()
                        .unwrap_or("Update check complete")
                        .to_owned();
                    *app.state::<TrayState>().update.lock().unwrap() =
                        Some((message, value["available"].as_bool().unwrap_or(false)));
                    refresh_menu(&app);
                    Ok(())
                }
                "tray-install" => crate::lifecycle::install_update(app.clone(), app.state()).await,
                "tray-quit" => crate::quit(app.clone(), app.state()).await,
                _ => {
                    if let Some(id) = id.strip_prefix("tray-copy:") {
                        let text = {
                            let workspace = app.state::<Arc<Workspace>>();
                            let store = workspace.store.lock().unwrap();
                            let record = store.dictation(id).map_err(|e| e.to_string())?;
                            record
                                .correction
                                .filter(|t| !t.is_empty())
                                .unwrap_or(record.text)
                        };
                        crate::copy_text(text)
                    } else if let Some(id) = id.strip_prefix("tray-paste:") {
                        crate::workspace::retry_dictation(id.into(), app.clone(), app.state())
                            .await
                            .map(|_| ())
                    } else if let Some(id) = id.strip_prefix("tray-delete:") {
                        crate::delete_dictation(id.into(), app.state()).await
                    } else {
                        Ok(())
                    }
                }
            }
        }
        .await;
        if let Err(error) = result {
            let shared = app.state::<Arc<Shared>>();
            crate::engine::update(&app, &shared, |s| s.error = Some(error));
            let _ = open_workspace(&app, "dictation");
        }
    });
}
pub fn install(app: &tauri::App) -> tauri::Result<()> {
    app.manage(TrayState::default());
    // Linux StatusNotifier does not emit click coordinates. Keep its native
    // system menu, also used when the custom window cannot be created.
    let panel = if cfg!(target_os = "linux") {
        None
    } else {
        tauri::WebviewWindowBuilder::new(app, LABEL, tauri::WebviewUrl::App("tray.html".into()))
            .title("Pressay")
            .inner_size(WIDTH, 650.)
            .decorations(false)
            .resizable(false)
            .always_on_top(true)
            .visible_on_all_workspaces(true)
            .skip_taskbar(true)
            .shadow(true)
            .focused(false)
            .visible(false)
            .accept_first_mouse(true)
            .build()
            .map_err(|error| eprintln!("Could not create tray panel: {error}"))
            .ok()
    };
    if let Some(window) = &panel {
        let handle = window.clone();
        window.on_window_event(move |event| match event {
            tauri::WindowEvent::Focused(false) => {
                let _ = handle.hide();
            }
            tauri::WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close();
                let _ = handle.hide();
            }
            _ => {}
        });
    }
    let mut builder = TrayIconBuilder::with_id("pressay")
        .menu(&fallback_menu(app.handle())?)
        .show_menu_on_left_click(panel.is_none())
        .tooltip("Pressay")
        .on_menu_event(|app, event| menu_action(app, event.id().as_ref()));
    if panel.is_some() {
        builder = builder.on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                position,
                rect,
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                if let Err(error) = show_panel(tray.app_handle(), position, rect) {
                    eprintln!("Could not show tray panel: {error}");
                    let _ = open_workspace(tray.app_handle(), "dictation");
                }
            }
        });
    }
    #[cfg(target_os = "macos")]
    {
        builder = builder
            .icon(tauri::include_image!(
                "../../../Config/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon@2x.png"
            ))
            .icon_as_template(true);
    }
    #[cfg(not(target_os = "macos"))]
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    builder.build(app)?;
    let handle = app.handle().clone();
    let key = Arc::new(Mutex::new(String::new()));
    app.listen("pressay-state", move |_| {
        let next = {
            let state = handle.state::<Arc<Shared>>();
            let view = state.view.lock().unwrap();
            serde_json::to_string(&(
                &view.stage,
                &view.shortcut_label,
                view.model_ready,
                view.settings["onboardingComplete"].clone(),
                view.settings["claudeCleanup"].clone(),
                view.history.iter().take(2).collect::<Vec<_>>(),
            ))
            .unwrap_or_default()
        };
        let mut previous = key.lock().unwrap();
        if *previous == next {
            return;
        }
        *previous = next;
        let app = handle.clone();
        let _ = handle.run_on_main_thread(move || refresh_menu(&app));
    });
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn panel_fits_retina_monitor_and_avoids_bottom_taskbar() {
        let top = Anchor {
            work: [0., 50., 2880., 1700.],
            icon: [2700., 0., 40., 44.],
            scale: 2.,
        };
        let (p, s) = placement(top, 650.);
        assert_eq!(s, [696, 1300]);
        assert!(p[0] >= 12 && p[0] + s[0] as i32 <= 2868);
        assert!(p[1] >= 62);
        let bottom = Anchor {
            work: [-1920., 0., 1920., 1040.],
            icon: [-80., 1040., 32., 40.],
            scale: 1.,
        };
        let (p, s) = placement(bottom, 650.);
        assert!(p[0] >= -1914 && p[0] + s[0] as i32 <= -6);
        assert!(p[1] + s[1] as i32 <= 1034);
    }
    #[test]
    fn short_high_dpi_displays_clamp_size_without_negative_geometry() {
        let (p, s) = placement(
            Anchor {
                work: [-400., -300., 400., 300.],
                icon: [-20., -300., 20., 20.],
                scale: 2.,
            },
            900.,
        );
        assert_eq!(s, [376, 276]);
        assert_eq!(p, [-388, -288]);
    }
}
