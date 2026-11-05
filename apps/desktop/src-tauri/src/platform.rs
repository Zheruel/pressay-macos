use enigo::{Enigo, Keyboard, Settings};
use pressay_core::onboarding::Permission;
use serde::Serialize;

#[derive(Clone, Serialize)]
pub struct Permissions {
    pub microphone: Permission,
    pub shortcut: Permission,
    pub insertion: Permission,
    pub wayland: bool,
    pub explanation: Option<String>,
}
#[cfg(target_os = "macos")]
extern "C" {
    fn pressay_microphone_status() -> i32;
    fn pressay_accessibility_status() -> i32;
    fn pressay_input_status() -> i32;
    fn pressay_open_permission(kind: i32);
    fn pressay_focused_process() -> u64;
}
#[cfg(target_os = "macos")]
fn permission(status: i32) -> Permission {
    match status {
        1 => Permission::Granted,
        2 => Permission::Denied,
        _ => Permission::Unknown,
    }
}
pub fn permissions(shortcut_registered: bool, microphone_worked: bool) -> Permissions {
    #[cfg(target_os = "macos")]
    unsafe {
        let _ = microphone_worked;
        Permissions {
            microphone: permission(pressay_microphone_status()),
            shortcut: if shortcut_registered {
                permission(pressay_input_status())
            } else {
                Permission::Denied
            },
            insertion: permission(pressay_accessibility_status()),
            wayland: false,
            explanation: None,
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let wayland = is_wayland();
        Permissions { microphone: if microphone_worked { Permission::Granted } else { Permission::Unknown },
            shortcut: if shortcut_registered { Permission::Granted } else { Permission::Unavailable },
            insertion: if wayland { Permission::Unavailable } else { Permission::Granted }, wayland,
            explanation: wayland.then(|| "This preview cannot insert into native Wayland windows yet. Use an X11 session to test the full dictation path.".into()) }
    }
}
#[cfg(not(target_os = "macos"))]
pub fn is_wayland() -> bool {
    cfg!(target_os = "linux")
        && (std::env::var_os("WAYLAND_DISPLAY").is_some()
            || std::env::var("XDG_SESSION_TYPE").is_ok_and(|v| v == "wayland"))
}
pub fn request_permission(kind: &str) -> Result<(), String> {
    match kind {
        "microphone" | "accessibility" | "shortcut" => {}
        _ => return Err("Unknown permission".into()),
    }
    #[cfg(target_os = "macos")]
    unsafe {
        pressay_open_permission(match kind {
            "microphone" => 0,
            "accessibility" => 1,
            _ => 2,
        });
    }
    #[cfg(windows)]
    if kind == "microphone" {
        std::process::Command::new("explorer.exe")
            .arg("ms-settings:privacy-microphone")
            .spawn()
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
pub fn focused_target() -> Result<u64, String> {
    #[cfg(target_os = "macos")]
    unsafe {
        Ok(pressay_focused_process())
    }
    #[cfg(windows)]
    unsafe {
        Ok(windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow().0 as usize as u64)
    }
    #[cfg(target_os = "linux")]
    {
        if is_wayland() {
            return Err("Native Wayland insertion is not available in this preview".into());
        }
        use x11rb::protocol::xproto::ConnectionExt;
        let (connection, _) = x11rb::connect(None).map_err(|e| e.to_string())?;
        let focus = connection
            .get_input_focus()
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?
            .focus;
        Ok(focus as u64)
    }
}
/// Never paste a delayed result into a different application. Unicode event
/// insertion leaves every clipboard format untouched, including images/files.
pub fn insert(text: &str, target: u64) -> Result<(), String> {
    if target == 0 || focused_target()? != target {
        return Err(
            "Focus changed. Your dictation was saved to History; copy it when ready.".into(),
        );
    }
    if text.trim().is_empty() {
        return Err("No recognized text to insert".into());
    }
    Enigo::new(&Settings::default())
        .map_err(|e| e.to_string())?
        .text(text)
        .map_err(|e| e.to_string())
}
