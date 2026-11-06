#[cfg(not(target_os = "macos"))]
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
    fn pressay_input_devices(buffer: *mut std::ffi::c_char, capacity: usize) -> i32;
    fn pressay_input_device_name_for_uid(
        uid: *const std::ffi::c_char,
        buffer: *mut std::ffi::c_char,
        capacity: usize,
    ) -> bool;
    fn pressay_open_permission(kind: i32);
    fn pressay_focused_process() -> u64;
    fn pressay_release_target(token: u64);
    fn pressay_refresh_target(token: u64) -> bool;
    fn pressay_activate_application(identifier: *const std::ffi::c_char) -> i32;
    fn pressay_target_process(token: u64) -> i32;
    fn pressay_clear_targets();
    fn pressay_insert_text(text: *const std::ffi::c_char, token: u64) -> i32;
    fn pressay_target_application(
        token: u64,
        buffer: *mut std::ffi::c_char,
        capacity: usize,
    ) -> bool;
    fn pressay_active_call(buffer: *mut std::ffi::c_char, capacity: usize) -> bool;
    fn pressay_overlay(
        stage: *const std::ffi::c_char,
        detail: *const std::ffi::c_char,
        levels: *const f32,
    );
    fn pressay_set_stop_callback(callback: extern "C" fn());
    fn pressay_export_reminders(
        json: *const std::ffi::c_char,
        callback: extern "C" fn(*const std::ffi::c_char, *mut std::ffi::c_void),
        context: *mut std::ffi::c_void,
    );
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
        #[allow(unused_mut)] // Linux adds portal status below.
        let mut result = Permissions {
            microphone: if microphone_worked {
                Permission::Granted
            } else {
                Permission::Unknown
            },
            shortcut: if shortcut_registered {
                Permission::Granted
            } else {
                Permission::Unavailable
            },
            insertion: Permission::Granted,
            wayland: is_wayland(),
            explanation: None,
        };
        #[cfg(target_os = "linux")]
        if result.wayland {
            if crate::wayland::current_cursor_enabled() {
                let (status, error) = crate::wayland::status();
                result.insertion = status;
                result.explanation = Some(error.unwrap_or_else(|| "Keyboard control inserts at the current cursor. Wayland cannot verify the original application or field; keep your intended field focused until insertion finishes.".into()));
            } else {
                result.insertion = Permission::Unavailable;
                result.explanation = Some("Manual copy keeps the transcript in History. You can explicitly enable insertion at the current cursor and approve keyboard control; Wayland cannot verify the original field.".into());
            }
        }
        result
    }
}
#[cfg(not(target_os = "macos"))]
pub fn is_wayland() -> bool {
    cfg!(target_os = "linux")
        && (std::env::var_os("WAYLAND_DISPLAY").is_some()
            || std::env::var("XDG_SESSION_TYPE").is_ok_and(|v| v == "wayland"))
}
pub fn initialize(data: std::path::PathBuf, current_cursor: bool) {
    #[cfg(target_os = "linux")]
    {
        crate::wayland::initialize(data);
        crate::wayland::set_current_cursor(current_cursor);
    }
    #[cfg(not(target_os = "linux"))]
    let _ = (data, current_cursor);
}
pub fn set_wayland_current_cursor(enabled: bool) {
    #[cfg(target_os = "linux")]
    crate::wayland::set_current_cursor(enabled);
    #[cfg(not(target_os = "linux"))]
    let _ = enabled;
}
#[cfg(target_os = "macos")]
pub fn input_devices() -> Result<Vec<String>, String> {
    let mut bytes = vec![0u8; 65_536];
    match unsafe { pressay_input_devices(bytes.as_mut_ptr().cast(), bytes.len()) } {
        0 => {}
        1 => return Err("Core Audio could not list microphone devices".into()),
        _ => return Err("Microphone device metadata is too large or invalid".into()),
    }
    let json = std::ffi::CStr::from_bytes_until_nul(&bytes).map_err(|e| e.to_string())?;
    let mut names: Vec<String> =
        serde_json::from_slice(json.to_bytes()).map_err(|e| e.to_string())?;
    names.sort();
    names.dedup();
    Ok(names)
}
/// Resolve the original Mac preference without opening an AudioUnit. A missing
/// UID is preserved by callers and must prompt device selection, never default.
pub fn input_device_name_for_uid(uid: &str) -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        let uid = std::ffi::CString::new(uid).ok()?;
        native_string(|buffer, capacity| unsafe {
            pressay_input_device_name_for_uid(uid.as_ptr(), buffer, capacity)
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = uid;
        None
    }
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
    #[cfg(target_os = "linux")]
    if kind == "accessibility" && is_wayland() {
        return crate::wayland::request_keyboard();
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
/// A short-lived token for the focused field. Wayland deliberately returns a
/// session generation instead: it cannot provide an original-focus guarantee.
pub fn focused_target() -> Result<u64, String> {
    #[cfg(target_os = "macos")]
    unsafe {
        Ok(pressay_focused_process())
    }
    #[cfg(not(target_os = "macos"))]
    {
        #[cfg(target_os = "linux")]
        if is_wayland() {
            return Ok(crate::wayland::target());
        }
        targets::capture()
    }
}
/// Reacquire a replaced editor or moved caret at key release, only while the
/// original application's process still owns focus. Failure invalidates the token.
pub fn refresh_target(target: u64) -> bool {
    #[cfg(target_os = "macos")]
    unsafe {
        pressay_refresh_target(target)
    }
    #[cfg(not(target_os = "macos"))]
    {
        #[cfg(target_os = "linux")]
        if is_wayland() {
            return target != 0 && target == crate::wayland::target();
        }
        targets::refresh(target)
    }
}

/// Explicit History action. Only activate an already-running saved application;
/// never start a program or weaken the normal field/password/focus checks.
pub fn retry_insertion(
    text: &str,
    application: Option<&str>,
    cancel: &tokio_util::sync::CancellationToken,
) -> Result<(), String> {
    if cancel.is_cancelled() {
        return Err("Paste Again cancelled".into());
    }
    let application = application
        .filter(|v| !v.is_empty())
        .ok_or("The original application is unavailable")?;
    #[cfg(target_os = "linux")]
    if is_wayland() {
        return Err(
            "Wayland cannot reactivate the original application. Paste at your chosen cursor"
                .into(),
        );
    }
    #[cfg(target_os = "macos")]
    let process = {
        let application =
            std::ffi::CString::new(application).map_err(|_| "Invalid saved application")?;
        let pid = unsafe { pressay_activate_application(application.as_ptr()) };
        if pid == 0 {
            return Err("The original application is closed or could not be activated".into());
        }
        pid
    };
    #[cfg(not(target_os = "macos"))]
    let window = targets::activate(application)?;
    for _ in 0..40 {
        if cancel.is_cancelled() {
            return Err("Paste Again cancelled".into());
        }
        let token = focused_target()?;
        #[cfg(target_os = "macos")]
        let matches = token != 0 && unsafe { pressay_target_process(token) } == process;
        #[cfg(not(target_os = "macos"))]
        let matches = token != 0 && targets::belongs_to_window(token, window);
        if matches {
            if cancel.is_cancelled() {
                release_target(token);
                return Err("Paste Again cancelled".into());
            }
            return insert(text, token);
        }
        release_target(token);
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    Err("The original application did not expose a safe focused field".into())
}

pub fn release_target(target: u64) {
    #[cfg(target_os = "macos")]
    unsafe {
        pressay_release_target(target);
    }
    #[cfg(not(target_os = "macos"))]
    targets::release(target);
}
pub fn cancel_pending_insertions() {
    #[cfg(target_os = "macos")]
    unsafe {
        pressay_clear_targets();
    }
    #[cfg(not(target_os = "macos"))]
    targets::clear();
    #[cfg(target_os = "linux")]
    crate::wayland::cancel_insertion();
}
pub fn target_application(target: u64) -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        native_string(|buffer, length| unsafe {
            pressay_target_application(target, buffer, length)
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        targets::application(target)
    }
}
/// Events/AX insertion leave all clipboard formats untouched. A successful
/// return means the OS accepted insertion, not that an arbitrary app confirmed it.
pub fn insert(text: &str, target: u64) -> Result<(), String> {
    if text.trim().is_empty() {
        return Err("No recognized text to insert".into());
    }
    #[cfg(target_os = "macos")]
    {
        let text = std::ffi::CString::new(text)
            .map_err(|_| "Dictation contains an invalid null character")?;
        let result = unsafe { pressay_insert_text(text.as_ptr(), target) };
        release_target(target);
        match result {
            0 => Ok(()),
            1 => Err("The original field or selection changed. Copy the saved dictation from History when ready.".into()),
            3 => Err("Focus changed during insertion. Some text may have been inserted; check the target before copying the complete dictation from History.".into()),
            _ => Err("This field did not accept insertion. Copy the saved dictation from History.".into()),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        #[cfg(target_os = "linux")]
        if is_wayland() {
            return crate::wayland::insert(text, target);
        }
        let result = (|| {
            if !targets::matches(target, true) {
                return Err(
                    "The original field or cursor changed. Copy the saved dictation from History."
                        .into(),
                );
            }
            let mut keyboard = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;
            // Recheck the field between Unicode characters. Never paste an entire
            // delayed result into a different application after a focus switch.
            for (written, character) in text.chars().enumerate() {
                if !targets::matches(target, false) {
                    return Err(format!("Insertion stopped after {written} characters because focus changed. Check the target before copying the complete text from History."));
                }
                keyboard.text(character.encode_utf8(&mut [0; 4])).map_err(|e| format!("Insertion stopped after {written} characters: {e}. The complete dictation is in History."))?;
            }
            Ok(())
        })();
        release_target(target);
        result
    }
}
pub fn overlay_state(stage: &str, detail: Option<&str>, levels: [f32; 4]) {
    #[cfg(target_os = "macos")]
    if let (Ok(stage), Ok(detail)) = (
        std::ffi::CString::new(stage),
        std::ffi::CString::new(detail.unwrap_or("")),
    ) {
        unsafe {
            pressay_overlay(stage.as_ptr(), detail.as_ptr(), levels.as_ptr());
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (stage, detail, levels);
}
#[cfg(target_os = "macos")]
static STOP_MEETING: std::sync::Mutex<Option<std::sync::Arc<dyn Fn() + Send + Sync>>> =
    std::sync::Mutex::new(None);
pub fn set_stop_callback(callback: std::sync::Arc<dyn Fn() + Send + Sync>) {
    #[cfg(target_os = "macos")]
    {
        *STOP_MEETING.lock().unwrap() = Some(callback);
        extern "C" fn stop() {
            let callback = STOP_MEETING.lock().unwrap().clone();
            if let Some(callback) = callback {
                callback();
            }
        }
        unsafe {
            pressay_set_stop_callback(stop);
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = callback;
}
#[cfg(target_os = "macos")]
fn native_string(get: impl FnOnce(*mut std::ffi::c_char, usize) -> bool) -> Option<String> {
    let mut bytes = vec![0u8; 1024];
    if !get(bytes.as_mut_ptr().cast(), bytes.len()) {
        return None;
    }
    std::ffi::CStr::from_bytes_until_nul(&bytes)
        .ok()?
        .to_str()
        .ok()
        .map(str::to_owned)
}
pub fn active_call() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        native_string(|buffer, length| unsafe { pressay_active_call(buffer, length) })
    }
    #[cfg(target_os = "linux")]
    {
        // pactl queries PipeWire-Pulse/PulseAudio's live capture streams, without
        // opening the microphone. No names or audio leave this process.
        let output = std::process::Command::new("pactl")
            .args(["--format=json", "list", "source-outputs"])
            .output()
            .ok()?;
        if !output.status.success() || output.stdout.len() > 2_000_000 {
            return None;
        }
        let streams: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
        streams
            .as_array()?
            .iter()
            .filter(|v| v["corked"] != true)
            .find_map(|stream| {
                let properties = &stream["properties"];
                [
                    "application.process.binary",
                    "application.id",
                    "application.name",
                ]
                .iter()
                .filter_map(|key| properties[*key].as_str())
                .find_map(call_name)
            })
    }
    #[cfg(windows)]
    {
        windows_calls::active()
    }
}
#[cfg(not(target_os = "macos"))]
fn call_name(value: &str) -> Option<String> {
    let name = value.rsplit(['/', '\\']).next()?.to_ascii_lowercase();
    let name = name.strip_suffix(".exe").unwrap_or(&name);
    [
        ("zoom", "Zoom"),
        ("teams", "Microsoft Teams"),
        ("ms-teams", "Microsoft Teams"),
        ("webex", "Webex"),
        ("slack", "Slack"),
        ("discord", "Discord"),
        ("whatsapp", "WhatsApp"),
        ("chrome", "Google Chrome"),
        ("google-chrome", "Google Chrome"),
        ("chromium", "Chromium"),
        ("firefox", "Firefox"),
        ("msedge", "Microsoft Edge"),
        ("brave", "Brave"),
    ]
    .iter()
    .find(|(binary, _)| name == *binary)
    .map(|(_, display)| (*display).to_owned())
}
/// Call from a blocking worker: EventKit permission and save finish via a native
/// callback. Opening Permissions or polling status never requests Reminders access.
pub fn export_reminders(title: &str, items: &[String]) -> Result<(), String> {
    if items.is_empty()
        || items.len() > 500
        || items
            .iter()
            .any(|item| item.trim().is_empty() || item.len() > 16_384)
    {
        return Err("Choose between 1 and 500 nonempty action items".into());
    }
    #[cfg(target_os = "macos")]
    {
        type Sender = std::sync::mpsc::SyncSender<Result<(), String>>;
        extern "C" fn complete(error: *const std::ffi::c_char, context: *mut std::ffi::c_void) {
            let sender = unsafe { Box::from_raw(context.cast::<Sender>()) };
            let result = if error.is_null() {
                Ok(())
            } else {
                Err(unsafe { std::ffi::CStr::from_ptr(error) }
                    .to_string_lossy()
                    .into_owned())
            };
            let _ = sender.send(result);
        }
        let payload =
            std::ffi::CString::new(serde_json::json!({"title": title, "items": items}).to_string())
                .map_err(|e| e.to_string())?;
        let (send, receive) = std::sync::mpsc::sync_channel(1);
        unsafe {
            pressay_export_reminders(
                payload.as_ptr(),
                complete,
                Box::into_raw(Box::new(send)).cast(),
            );
        }
        receive
            .recv()
            .map_err(|_| "Reminders export disconnected".to_string())?
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = title;
        Err(
            "Apple Reminders is available on macOS. Export a calendar file on this platform."
                .into(),
        )
    }
}

#[cfg(not(target_os = "macos"))]
mod targets {
    use std::{
        collections::HashMap,
        sync::{
            atomic::{AtomicU64, Ordering},
            Mutex, OnceLock,
        },
        time::{Duration, Instant},
    };
    #[derive(Clone, PartialEq, Eq)]
    struct Focus {
        window: u64,
        foreground: u64,
        process: u32,
        caret: Option<[i32; 4]>,
        #[cfg(windows)]
        element: Option<Vec<i32>>,
    }
    #[derive(Clone)]
    struct Target {
        focus: Focus,
        application: Option<String>,
        created: Instant,
        invalidated: bool,
    }
    fn registry() -> &'static Mutex<HashMap<u64, Target>> {
        static REGISTRY: OnceLock<Mutex<HashMap<u64, Target>>> = OnceLock::new();
        REGISTRY.get_or_init(Default::default)
    }
    pub fn capture() -> Result<u64, String> {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let focus = current()?;
        if focus.window <= 1 {
            return Ok(0);
        }
        #[cfg(windows)]
        if focus.element.is_none() {
            return Ok(0);
        }
        let application = application_for(&focus);
        let mut registry = registry().lock().unwrap();
        registry.retain(|_, value| value.created.elapsed() < Duration::from_secs(300));
        if registry.len() >= 32 {
            registry.clear();
        }
        let token = NEXT.fetch_add(1, Ordering::Relaxed);
        registry.insert(
            token,
            Target {
                focus,
                application,
                created: Instant::now(),
                invalidated: false,
            },
        );
        Ok(token)
    }
    pub fn refresh(token: u64) -> bool {
        let fresh = current().ok();
        let mut saved = registry().lock().unwrap();
        let valid = saved
            .get(&token)
            .is_some_and(|old| fresh.as_ref().is_some_and(|new| can_refresh(old, new)));
        if valid {
            let target = saved.get_mut(&token).unwrap();
            target.focus = fresh.unwrap();
            target.created = Instant::now();
        } else if let Some(target) = saved.get_mut(&token) {
            target.invalidated = true;
        }
        valid
    }
    fn can_refresh(old: &Target, new: &Focus) -> bool {
        if old.invalidated || old.created.elapsed() >= Duration::from_secs(300) {
            return false;
        }
        let same_owner = if old.focus.process != 0 {
            old.focus.process == new.process
        } else {
            old.focus.foreground != 0 && old.focus.foreground == new.foreground
        };
        #[cfg(windows)]
        let safe = new.element.is_some();
        #[cfg(not(windows))]
        let safe = new.window > 1;
        same_owner && safe
    }
    #[cfg(test)]
    mod refresh_tests {
        use super::*;
        #[test]
        fn moved_caret_or_replaced_field_requires_the_same_process() {
            let focus = Focus {
                window: 10,
                foreground: 20,
                process: 99,
                caret: Some([1, 2, 3, 4]),
                #[cfg(windows)]
                element: Some(vec![1]),
            };
            let mut saved = Target {
                focus: focus.clone(),
                application: Some("editor".into()),
                created: Instant::now(),
                invalidated: false,
            };
            let mut moved = focus;
            moved.window = 11;
            moved.caret = Some([5, 6, 7, 8]);
            #[cfg(windows)]
            {
                moved.element = Some(vec![2]);
            }
            assert!(can_refresh(&saved, &moved));
            moved.process = 100;
            assert!(!can_refresh(&saved, &moved));
            moved.process = 99;
            saved.invalidated = true;
            assert!(!can_refresh(&saved, &moved));
            saved.invalidated = false;
            saved.focus.process = 0;
            moved.process = 0;
            assert!(can_refresh(&saved, &moved));
            moved.foreground = 30;
            assert!(!can_refresh(&saved, &moved));
            #[cfg(windows)]
            {
                moved.foreground = 20;
                moved.element = None;
                assert!(!can_refresh(&saved, &moved));
            }
        }
    }
    pub fn belongs_to_window(token: u64, window: u64) -> bool {
        registry()
            .lock()
            .unwrap()
            .get(&token)
            .is_some_and(|target| target.focus.foreground == window)
    }
    pub fn release(token: u64) {
        registry().lock().unwrap().remove(&token);
    }
    pub fn clear() {
        registry().lock().unwrap().clear();
    }
    pub fn application(token: u64) -> Option<String> {
        registry().lock().unwrap().get(&token)?.application.clone()
    }
    pub fn matches(token: u64, caret: bool) -> bool {
        let target = registry().lock().unwrap().get(&token).cloned();
        target.is_some_and(|target| {
            !target.invalidated
                && target.created.elapsed() < Duration::from_secs(300)
                && current().is_ok_and(|focus| {
                    focus.window == target.focus.window
                        && focus.foreground == target.focus.foreground
                        && (!caret || focus.caret == target.focus.caret)
                        && same_element(&focus, &target.focus)
                })
        })
    }
    fn same_element(a: &Focus, b: &Focus) -> bool {
        #[cfg(windows)]
        {
            a.element.is_some() && a.element == b.element
        }
        #[cfg(not(windows))]
        {
            let _ = (a, b);
            true
        }
    }
    #[cfg(windows)]
    fn current() -> Result<Focus, String> {
        use windows::Win32::UI::WindowsAndMessaging::*;
        unsafe {
            let foreground = GetForegroundWindow();
            let mut info = GUITHREADINFO {
                cbSize: std::mem::size_of::<GUITHREADINFO>() as u32,
                ..Default::default()
            };
            GetGUIThreadInfo(0, &mut info).map_err(|e| e.to_string())?;
            let mut process = 0;
            GetWindowThreadProcessId(foreground, Some(&mut process));
            Ok(Focus {
                process,
                window: info.hwndFocus.0 as usize as u64,
                foreground: foreground.0 as usize as u64,
                element: super::windows_calls::focused_element(),
                caret: (!info.hwndCaret.is_invalid()).then_some([
                    info.rcCaret.left,
                    info.rcCaret.top,
                    info.rcCaret.right,
                    info.rcCaret.bottom,
                ]),
            })
        }
    }
    #[cfg(windows)]
    fn application_for(focus: &Focus) -> Option<String> {
        use windows::Win32::{Foundation::HWND, UI::WindowsAndMessaging::GetWindowThreadProcessId};
        let mut pid = 0;
        unsafe {
            GetWindowThreadProcessId(HWND(focus.foreground as usize as *mut _), Some(&mut pid));
        }
        super::windows_calls::process_path(pid)
    }
    #[cfg(target_os = "linux")]
    fn current() -> Result<Focus, String> {
        use x11rb::protocol::xproto::ConnectionExt;
        let (connection, _) = x11rb::connect(None).map_err(|e| e.to_string())?;
        let window = connection
            .get_input_focus()
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?
            .focus;
        let mut foreground = window;
        let mut client = None;
        for _ in 0..32 {
            let class = connection
                .get_property(
                    false,
                    foreground,
                    x11rb::protocol::xproto::AtomEnum::WM_CLASS,
                    x11rb::protocol::xproto::AtomEnum::STRING,
                    0,
                    1,
                )
                .map_err(|e| e.to_string())?
                .reply()
                .map_err(|e| e.to_string())?;
            if !class.value.is_empty() {
                client = Some(foreground);
            }
            let tree = connection
                .query_tree(foreground)
                .map_err(|e| e.to_string())?
                .reply()
                .map_err(|e| e.to_string())?;
            if tree.parent == tree.root || tree.parent == 0 || tree.parent == foreground {
                break;
            }
            foreground = tree.parent;
        }
        // Reparenting window managers put their own frame above the client.
        // Keep the actual application window used by _NET_CLIENT_LIST_STACKING.
        foreground = client.unwrap_or(foreground);
        let atom = connection
            .intern_atom(false, b"_NET_WM_PID")
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?
            .atom;
        let property = connection
            .get_property(
                false,
                foreground,
                atom,
                x11rb::protocol::xproto::AtomEnum::CARDINAL,
                0,
                1,
            )
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?;
        let process = property
            .value32()
            .and_then(|mut values| values.next())
            .unwrap_or(0);
        Ok(Focus {
            window: window as u64,
            foreground: foreground as u64,
            process,
            caret: None,
        })
    }
    #[cfg(windows)]
    pub fn activate(application: &str) -> Result<u64, String> {
        use windows::core::BOOL;
        use windows::Win32::{
            Foundation::{HWND, LPARAM},
            UI::WindowsAndMessaging::*,
        };
        struct Search<'a> {
            application: &'a str,
            window: HWND,
        }
        unsafe extern "system" fn visit(window: HWND, parameter: LPARAM) -> BOOL {
            let search = &mut *(parameter.0 as *mut Search<'_>);
            if !IsWindowVisible(window).as_bool() {
                return true.into();
            }
            let mut pid = 0;
            GetWindowThreadProcessId(window, Some(&mut pid));
            if super::windows_calls::process_path(pid)
                .is_some_and(|path| path.eq_ignore_ascii_case(search.application))
            {
                search.window = window;
                return false.into();
            }
            true.into()
        }
        let mut search = Search {
            application,
            window: HWND::default(),
        };
        unsafe {
            let _ = EnumWindows(Some(visit), LPARAM(&mut search as *mut _ as isize));
            if search.window.is_invalid() {
                return Err("The original application is closed".into());
            }
            if IsIconic(search.window).as_bool() {
                let _ = ShowWindow(search.window, SW_RESTORE);
            }
            if !SetForegroundWindow(search.window).as_bool() {
                return Err("Windows did not allow activating the original application".into());
            }
        }
        Ok(search.window.0 as usize as u64)
    }
    #[cfg(target_os = "linux")]
    pub fn activate(application: &str) -> Result<u64, String> {
        use x11rb::{connection::Connection, protocol::xproto::*};
        let (connection, screen) = x11rb::connect(None).map_err(|e| e.to_string())?;
        let root = connection.setup().roots[screen].root;
        let list = connection
            .intern_atom(false, b"_NET_CLIENT_LIST_STACKING")
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?
            .atom;
        let property = connection
            .get_property(false, root, list, AtomEnum::WINDOW, 0, 4096)
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| e.to_string())?;
        let windows: Vec<_> = property.value32().map(|v| v.collect()).unwrap_or_default();
        for window in windows.into_iter().rev() {
            let focus = Focus {
                window: window as u64,
                foreground: window as u64,
                process: 0,
                caret: None,
            };
            if application_for(&focus).as_deref() != Some(application) {
                continue;
            }
            let active = connection
                .intern_atom(false, b"_NET_ACTIVE_WINDOW")
                .map_err(|e| e.to_string())?
                .reply()
                .map_err(|e| e.to_string())?
                .atom;
            let message =
                ClientMessageEvent::new(32, window, active, [2, x11rb::CURRENT_TIME, 0, 0, 0]);
            connection
                .send_event(
                    false,
                    root,
                    EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY,
                    message,
                )
                .map_err(|e| e.to_string())?;
            connection.flush().map_err(|e| e.to_string())?;
            return Ok(window as u64);
        }
        Err("The original application is closed or this window manager cannot reactivate it".into())
    }
    #[cfg(target_os = "linux")]
    fn application_for(focus: &Focus) -> Option<String> {
        use x11rb::protocol::xproto::{AtomEnum, ConnectionExt};
        let (connection, _) = x11rb::connect(None).ok()?;
        let mut window = focus.window as u32;
        for _ in 0..32 {
            let property = connection
                .get_property(false, window, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 1024)
                .ok()?
                .reply()
                .ok()?;
            if !property.value.is_empty() {
                let parts: Vec<_> = property
                    .value
                    .split(|byte| *byte == 0)
                    .filter(|v| !v.is_empty())
                    .collect();
                return parts
                    .last()
                    .and_then(|bytes| std::str::from_utf8(bytes).ok())
                    .map(str::to_owned);
            }
            let tree = connection.query_tree(window).ok()?.reply().ok()?;
            if tree.parent == 0 || tree.parent == window {
                break;
            }
            window = tree.parent;
        }
        None
    }
}
#[cfg(windows)]
mod windows_calls {
    pub fn process_path(pid: u32) -> Option<String> {
        use windows::{
            core::PWSTR,
            Win32::{
                Foundation::CloseHandle,
                System::Threading::{
                    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
                    PROCESS_QUERY_LIMITED_INFORMATION,
                },
            },
        };
        unsafe {
            let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
            let mut buffer = vec![0u16; 32768];
            let mut size = buffer.len() as u32;
            let result = QueryFullProcessImageNameW(
                process,
                PROCESS_NAME_WIN32,
                PWSTR(buffer.as_mut_ptr()),
                &mut size,
            );
            let _ = CloseHandle(process);
            result.ok()?;
            String::from_utf16(&buffer[..size as usize]).ok()
        }
    }
    // UIA runtime IDs distinguish fields inside browsers that share one HWND.
    // No field text is read or persisted. Inaccessible/password fields fall back
    // to History rather than silently weakening the original-field guard.
    pub fn focused_element() -> Option<Vec<i32>> {
        use windows::Win32::{
            System::{Com::*, Ole::*},
            UI::Accessibility::*,
        };
        unsafe {
            let initialized = CoInitializeEx(None, COINIT_MULTITHREADED).is_ok();
            let result = (|| {
                let automation: IUIAutomation =
                    CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok()?;
                let element = automation.GetFocusedElement().ok()?;
                if element.CurrentIsPassword().ok()?.as_bool() {
                    return None;
                }
                let array = element.GetRuntimeId().ok()?;
                if array.is_null() {
                    return None;
                }
                let result = (|| {
                    if SafeArrayGetDim(array) != 1 {
                        return None;
                    }
                    let lower = SafeArrayGetLBound(array, 1).ok()?;
                    let upper = SafeArrayGetUBound(array, 1).ok()?;
                    let length = upper.checked_sub(lower)?.checked_add(1)?;
                    if !(1..=256).contains(&length) {
                        return None;
                    }
                    let mut data = std::ptr::null_mut();
                    SafeArrayAccessData(array, &mut data).ok()?;
                    let result = if data.is_null() {
                        None
                    } else {
                        Some(
                            std::slice::from_raw_parts(data.cast::<i32>(), length as usize)
                                .to_vec(),
                        )
                    };
                    let _ = SafeArrayUnaccessData(array);
                    result
                })();
                let _ = SafeArrayDestroy(array);
                result
            })();
            if initialized {
                CoUninitialize();
            }
            result
        }
    }
    pub fn active() -> Option<String> {
        use windows::{
            core::Interface,
            Win32::{Media::Audio::*, System::Com::*},
        };
        unsafe {
            let initialized = CoInitializeEx(None, COINIT_MULTITHREADED).is_ok();
            // RPC_E_CHANGED_MODE means COM already exists on this thread and is usable.
            let result = (|| {
                let enumerator: IMMDeviceEnumerator =
                    CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).ok()?;
                let devices = enumerator
                    .EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE)
                    .ok()?;
                for index in 0..devices.GetCount().ok()? {
                    let device = devices.Item(index).ok()?;
                    let manager: IAudioSessionManager2 = device.Activate(CLSCTX_ALL, None).ok()?;
                    let sessions = manager.GetSessionEnumerator().ok()?;
                    for index in 0..sessions.GetCount().ok()? {
                        let session = sessions.GetSession(index).ok()?;
                        if session.GetState().ok()? != AudioSessionStateActive {
                            continue;
                        }
                        let control: IAudioSessionControl2 = session.cast().ok()?;
                        let pid = control.GetProcessId().ok()?;
                        if pid == std::process::id() {
                            continue;
                        }
                        if let Some(name) = process_path(pid).as_deref().and_then(super::call_name)
                        {
                            return Some(name);
                        }
                    }
                }
                None
            })();
            if initialized {
                CoUninitialize();
            }
            result
        }
    }
}
#[cfg(test)]
mod tests {
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn call_detection_matches_process_names_not_arbitrary_substrings() {
        assert_eq!(
            super::call_name(r"C:\Program Files\Zoom\zoom.exe"),
            Some("Zoom".into())
        );
        assert_eq!(super::call_name("notzoom"), None);
        assert_eq!(super::call_name("Pressay"), None);
    }
    #[cfg(target_os = "linux")]
    #[test]
    #[ignore = "Run under xvfb-run on a disposable X11 desktop"]
    fn x11_insertion_preserves_clipboard_and_rejects_changed_focus() {
        use x11rb::{
            connection::Connection, protocol::xproto::*, wrapper::ConnectionExt as _,
            COPY_DEPTH_FROM_PARENT, CURRENT_TIME,
        };
        let (connection, screen) = x11rb::connect(None).unwrap();
        let root = connection.setup().roots[screen].root;
        let first = connection.generate_id().unwrap();
        let second = connection.generate_id().unwrap();
        for window in [first, second] {
            connection
                .create_window(
                    COPY_DEPTH_FROM_PARENT,
                    window,
                    root,
                    0,
                    0,
                    300,
                    100,
                    0,
                    WindowClass::INPUT_OUTPUT,
                    0,
                    &CreateWindowAux::new()
                        .event_mask(EventMask::KEY_PRESS | EventMask::KEY_RELEASE),
                )
                .unwrap()
                .check()
                .unwrap();
            connection.map_window(window).unwrap().check().unwrap();
        }
        connection
            .change_property8(
                PropMode::REPLACE,
                first,
                AtomEnum::WM_CLASS,
                AtomEnum::STRING,
                b"pressay-qa\0Terminal\0",
            )
            .unwrap()
            .check()
            .unwrap();
        let clipboard = connection
            .intern_atom(false, b"CLIPBOARD")
            .unwrap()
            .reply()
            .unwrap()
            .atom;
        connection
            .set_selection_owner(first, clipboard, CURRENT_TIME)
            .unwrap()
            .check()
            .unwrap();
        connection
            .set_input_focus(InputFocus::PARENT, first, CURRENT_TIME)
            .unwrap()
            .check()
            .unwrap();
        let target = super::focused_target().unwrap();
        assert_ne!(target, 0);
        assert_eq!(
            super::target_application(target).as_deref(),
            Some("Terminal")
        );
        super::insert("Hello", target).unwrap();
        assert_eq!(
            connection
                .get_selection_owner(clipboard)
                .unwrap()
                .reply()
                .unwrap()
                .owner,
            first
        );
        let mut presses = 0;
        while let Some(event) = connection.poll_for_event().unwrap() {
            if matches!(event, x11rb::protocol::Event::KeyPress(_)) {
                presses += 1;
            }
        }
        assert!(presses >= 5, "OS must receive actual text key events");
        let target = super::focused_target().unwrap();
        connection
            .set_input_focus(InputFocus::PARENT, second, CURRENT_TIME)
            .unwrap()
            .check()
            .unwrap();
        assert!(super::insert("must not arrive", target).is_err());
        assert_eq!(
            connection
                .get_selection_owner(clipboard)
                .unwrap()
                .reply()
                .unwrap()
                .owner,
            first
        );
        assert!(connection.poll_for_event().unwrap().is_none());
        connection.destroy_window(first).unwrap().check().unwrap();
        connection.destroy_window(second).unwrap().check().unwrap();
    }
}
