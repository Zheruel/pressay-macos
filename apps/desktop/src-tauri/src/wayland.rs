//! Portal-only Wayland integration. No root daemon, raw input device, or private
//! compositor protocol. These APIs grant shortcuts and keyboard control; they do
//! NOT reveal the focused application. Current-cursor insertion is explicit opt-in.
use crate::shortcuts::{Callback, Event};
use futures_util::StreamExt;
use pressay_core::onboarding::Permission;
use serde::Serialize;
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Duration,
};
use tokio_util::sync::CancellationToken;
use zbus::{Connection, DynamicType, OwnedObjectPath, OwnedVariant, Proxy, Variant};
const DESTINATION: &str = "org.freedesktop.portal.Desktop";
const DESKTOP: &str = "/org/freedesktop/portal/desktop";
const SHORTCUTS: &str = "org.freedesktop.portal.GlobalShortcuts";
const REMOTE: &str = "org.freedesktop.portal.RemoteDesktop";
type Results = HashMap<String, OwnedVariant>;
type Options<'a> = HashMap<&'a str, Variant<'a>>;
fn token() -> String {
    format!("pressay_{}", uuid::Uuid::new_v4().simple())
}
fn options(token: &str) -> Options<'_> {
    HashMap::from([("handle_token", Variant::from(token))])
}
async fn proxy(
    connection: &Connection,
    path: impl Into<String>,
    interface: &str,
) -> Result<Proxy<'static>, String> {
    Proxy::new_owned(
        connection.clone(),
        DESTINATION.to_owned(),
        path.into(),
        interface.to_owned(),
    )
    .await
    .map_err(|e| e.to_string())
}
fn response_path(connection: &Connection, handle_token: &str) -> Result<String, String> {
    let sender = connection
        .unique_name()
        .ok_or("Portal connection has no unique name")?
        .as_str()
        .trim_start_matches(':')
        .replace('.', "_");
    Ok(format!(
        "/org/freedesktop/portal/desktop/request/{sender}/{handle_token}"
    ))
}
/// Subscribe before making the call: portals may emit Response before the
/// method reply arrives. Timeout/cancel explicitly closes the pending request.
async fn request<B: Serialize + DynamicType>(
    connection: &Connection,
    portal: &Proxy<'_>,
    method: &str,
    body: &B,
    handle_token: &str,
    cancel: &CancellationToken,
) -> Result<Results, String> {
    let path = response_path(connection, handle_token)?;
    let pending = proxy(connection, path.clone(), "org.freedesktop.portal.Request").await?;
    let mut responses = pending
        .receive_signal("Response")
        .await
        .map_err(|e| e.to_string())?;
    let handle_result = tokio::select! {
        _ = cancel.cancelled() => Err("Portal request cancelled".to_string()),
        result = tokio::time::timeout(Duration::from_secs(15), portal.call::<_, _, OwnedObjectPath>(method, body)) =>
            result.map_err(|_| "Desktop portal did not respond".to_string()).and_then(|value| value.map_err(|e| e.to_string())),
    };
    let handle = match handle_result {
        Ok(handle) => handle,
        Err(error) => {
            let _ = tokio::time::timeout(
                Duration::from_secs(2),
                pending.call::<_, _, ()>("Close", &()),
            )
            .await;
            return Err(error);
        }
    };
    if handle.as_str() != path {
        if let Ok(actual) = proxy(
            connection,
            handle.to_string(),
            "org.freedesktop.portal.Request",
        )
        .await
        {
            let _ = tokio::time::timeout(
                Duration::from_secs(2),
                actual.call::<_, _, ()>("Close", &()),
            )
            .await;
        }
        return Err("Desktop portal returned an unexpected request handle".into());
    }
    let outcome = tokio::select! {
        _ = cancel.cancelled() => Err("Portal request cancelled".into()),
        _ = tokio::time::sleep(Duration::from_secs(120)) => Err("Desktop permission request timed out; try again when ready".into()),
        message = responses.next() => {
            let message = message.ok_or("Desktop portal disconnected")?;
            let (status, values): (u32, Results) = message.body().deserialize().map_err(|e| e.to_string())?;
            match status { 0 => Ok(values), 1 => Err("Permission was cancelled. You can try again in Permissions.".into()),
                _ => Err("The desktop denied this permission. Check its privacy settings, then try again.".into()) }
        }
    };
    if outcome.is_err() {
        let _ = tokio::time::timeout(
            Duration::from_secs(2),
            pending.call::<_, _, ()>("Close", &()),
        )
        .await;
    }
    outcome
}
async fn create_session(
    connection: &Connection,
    portal: &Proxy<'_>,
    cancel: &CancellationToken,
) -> Result<OwnedObjectPath, String> {
    let handle = token();
    let session_token = token();
    let mut args = options(&handle);
    args.insert(
        "session_handle_token",
        Variant::from(session_token.as_str()),
    );
    let values = request(
        connection,
        portal,
        "CreateSession",
        &(args,),
        &handle,
        cancel,
    )
    .await?;
    let path = values
        .get("session_handle")
        .ok_or("Portal did not create a session")?;
    // Historical portal implementations encode this field as a string, not `o`.
    let value = <&str>::try_from(path)
        .map(str::to_owned)
        .or_else(|_| OwnedObjectPath::try_from(path.try_clone()?).map(|p| p.to_string()))
        .map_err(|e| e.to_string())?;
    OwnedObjectPath::try_from(value).map_err(|e| e.to_string())
}
async fn close_session(connection: &Connection, session: &OwnedObjectPath) {
    if let Ok(session) = proxy(
        connection,
        session.to_string(),
        "org.freedesktop.portal.Session",
    )
    .await
    {
        let _ = tokio::time::timeout(
            Duration::from_secs(2),
            session.call::<_, _, ()>("Close", &()),
        )
        .await;
    }
}
/// The portal uses XDG trigger spelling, while Tauri uses accelerator spelling.
fn portal_trigger(accelerator: &str) -> Result<String, String> {
    use tauri_plugin_global_shortcut::{Modifiers, Shortcut};
    let shortcut: Shortcut = accelerator
        .parse()
        .map_err(|e| format!("Invalid shortcut: {e}"))?;
    let mut output = String::new();
    for (modifier, name) in [
        (Modifiers::CONTROL, "CTRL+"),
        (Modifiers::ALT, "ALT+"),
        (Modifiers::SHIFT, "SHIFT+"),
        (Modifiers::SUPER, "LOGO+"),
    ] {
        if shortcut.mods.contains(modifier) {
            output.push_str(name);
        }
    }
    let code = shortcut.key.to_string();
    let key = if let Some(letter) = code.strip_prefix("Key") {
        letter.to_ascii_lowercase()
    } else if let Some(digit) = code.strip_prefix("Digit") {
        digit.to_owned()
    } else if code.starts_with('F') && code[1..].parse::<u8>().is_ok_and(|n| (1..=35).contains(&n))
    {
        code.clone()
    } else {
        match code.as_str() {
            "Space" => "space",
            "Enter" => "Return",
            "Escape" => "Escape",
            "Backspace" => "BackSpace",
            "Tab" => "Tab",
            "Delete" => "Delete",
            "Insert" => "Insert",
            "Home" => "Home",
            "End" => "End",
            "PageUp" => "Prior",
            "PageDown" => "Next",
            "ArrowUp" => "Up",
            "ArrowDown" => "Down",
            "ArrowLeft" => "Left",
            "ArrowRight" => "Right",
            "PrintScreen" => "Print",
            "Pause" => "Pause",
            "Minus" => "minus",
            "Equal" => "equal",
            "BracketLeft" => "bracketleft",
            "BracketRight" => "bracketright",
            "Backslash" => "backslash",
            "Semicolon" => "semicolon",
            "Quote" => "apostrophe",
            "Backquote" => "grave",
            "Comma" => "comma",
            "Period" => "period",
            "Slash" => "slash",
            "NumpadEnter" => "KP_Enter",
            "NumpadAdd" => "KP_Add",
            "NumpadSubtract" => "KP_Subtract",
            "NumpadMultiply" => "KP_Multiply",
            "NumpadDivide" => "KP_Divide",
            "NumpadDecimal" => "KP_Decimal",
            "Numpad0" => "KP_0",
            "Numpad1" => "KP_1",
            "Numpad2" => "KP_2",
            "Numpad3" => "KP_3",
            "Numpad4" => "KP_4",
            "Numpad5" => "KP_5",
            "Numpad6" => "KP_6",
            "Numpad7" => "KP_7",
            "Numpad8" => "KP_8",
            "Numpad9" => "KP_9",
            _ => {
                return Err(
                    "Choose a letter, number, function or navigation key for the desktop portal"
                        .into(),
                )
            }
        }
        .to_owned()
    };
    output.push_str(&key);
    Ok(output)
}

fn granted_bindings(values: Results) -> Result<Vec<(String, Results)>, String> {
    let value = values
        .get("shortcuts")
        .ok_or("Desktop returned no shortcut grants")?
        .try_clone()
        .map_err(|e| e.to_string())?;
    Vec::<(String, Results)>::try_from(value).map_err(|e| e.to_string())
}
fn publish_bindings(bindings: &[(String, Results)], callback: &Callback) {
    let trigger = bindings
        .iter()
        .find(|(id, _)| id == "dictation")
        .and_then(|(_, values)| values.get("trigger_description"))
        .and_then(|value| <&str>::try_from(value).ok())
        .unwrap_or("");
    let available = !trigger.trim().is_empty();
    if !available {
        callback(Event::Cancel);
    }
    callback(Event::Availability {
        available,
        trigger: if available {
            trigger.to_owned()
        } else {
            "Configure desktop shortcut".into()
        },
        error: if !available {
            Some("Your desktop has not assigned a dictation key. Configure Pressay in the desktop's global shortcut settings, then retry.".into())
        } else if !bindings.iter().any(|(id, _)| id == "cancel") {
            Some("The desktop did not grant the cancel shortcut. Use Cancel in Pressay.".into())
        } else {
            None
        },
    });
}
pub async fn bind_shortcuts(accelerator: String, callback: Callback, cancel: CancellationToken) {
    let result = run_shortcuts(&accelerator, &callback, &cancel).await;
    callback(Event::Cancel);
    if !cancel.is_cancelled() {
        callback(Event::Availability { available: false, trigger: accelerator,
            error: Some(format!("Wayland shortcuts unavailable: {}. Approve or reconfigure shortcuts, then retry. Older desktops without GlobalShortcuts need a desktop keybinding to Pressay's toggle action.", result.err().unwrap_or_else(|| "desktop session closed".into()))) });
    }
}
async fn run_shortcuts(
    accelerator: &str,
    callback: &Callback,
    cancel: &CancellationToken,
) -> Result<(), String> {
    let connection = Connection::session().await.map_err(|e| e.to_string())?;
    run_shortcuts_on(connection, accelerator, callback, cancel).await
}
async fn run_shortcuts_on(
    connection: Connection,
    accelerator: &str,
    callback: &Callback,
    cancel: &CancellationToken,
) -> Result<(), String> {
    let portal = proxy(&connection, DESKTOP, SHORTCUTS).await?;
    let session = create_session(&connection, &portal, cancel).await?;
    let result = async {
        let session_proxy = proxy(&connection, session.to_string(), "org.freedesktop.portal.Session").await?;
        let mut closed = session_proxy.receive_signal("Closed").await.map_err(|e| e.to_string())?;
        let mut signals = portal.receive_all_signals().await.map_err(|e| e.to_string())?;
        let mut owner = portal.receive_owner_changed().await.map_err(|e| e.to_string())?;
        let preferred = portal_trigger(accelerator)?;
        let shortcuts = vec![
            ("dictation", HashMap::from([("description", Variant::from("Hold to dictate with Pressay")), ("preferred_trigger", Variant::from(preferred.as_str()))])),
            ("cancel", HashMap::from([("description", Variant::from("Cancel Pressay dictation")), ("preferred_trigger", Variant::from("CTRL+SHIFT+Escape"))])),
        ];
        let handle = token();
        let grants = request(&connection, &portal, "BindShortcuts", &(&session, shortcuts, "", options(&handle)), &handle, cancel).await?;
        publish_bindings(&granted_bindings(grants)?, callback);
        loop {
            tokio::select! {
                _ = cancel.cancelled() => return Ok(()),
                _ = closed.next() => return Err("Desktop revoked or closed the shortcut session".into()),
                _ = owner.next() => return Err("Desktop portal restarted; reconnect shortcuts".into()),
                signal = signals.next() => {
                    let signal = signal.ok_or("Desktop shortcut connection closed")?;
                    let member = signal.header().member().map(|m| m.to_string()).unwrap_or_default();
                    if member == "ShortcutsChanged" {
                        let (changed_session, bindings): (OwnedObjectPath, Vec<(String, Results)>) = signal.body().deserialize().map_err(|e| e.to_string())?;
                        if changed_session == session { callback(Event::Cancel); publish_bindings(&bindings, callback); }
                    } else if member == "Activated" || member == "Deactivated" {
                        let (event_session, id, _, _): (OwnedObjectPath, String, u64, Results) = signal.body().deserialize().map_err(|e| e.to_string())?;
                        if event_session != session { continue; }
                        if id == "dictation" { callback(if member == "Activated" { Event::Pressed } else { Event::Released }); }
                        else if id == "cancel" && member == "Activated" { callback(Event::Cancel); }
                    }
                }
            }
        }
    }.await;
    close_session(&connection, &session).await;
    result
}

struct KeyboardSession {
    connection: Connection,
    portal: Proxy<'static>,
    session: OwnedObjectPath,
    cancelled: CancellationToken,
    closed: Mutex<Option<zbus::proxy::SignalStream<'static>>>,
    owner: Mutex<Option<zbus::proxy::OwnerChangedStream<'static>>>,
}
struct Output {
    opted_in: AtomicBool,
    pending: AtomicBool,
    generation: AtomicU64,
    permission: Mutex<(Permission, Option<String>)>,
    keyboard: Mutex<Option<Arc<KeyboardSession>>>,
    data: Mutex<Option<PathBuf>>,
    shutdown: CancellationToken,
    request: Mutex<CancellationToken>,
}
fn output() -> &'static Output {
    static OUTPUT: OnceLock<Output> = OnceLock::new();
    OUTPUT.get_or_init(|| Output {
        opted_in: AtomicBool::new(false),
        pending: AtomicBool::new(false),
        generation: AtomicU64::new(1),
        permission: Mutex::new((Permission::Unknown, None)),
        keyboard: Mutex::new(None),
        data: Mutex::new(None),
        shutdown: CancellationToken::new(),
        request: Mutex::new(CancellationToken::new()),
    })
}
pub fn initialize(data: PathBuf) {
    *output().data.lock().unwrap() = Some(data);
}
pub fn set_current_cursor(enabled: bool) {
    if output().opted_in.swap(enabled, Ordering::AcqRel) != enabled {
        cancel_insertion();
    }
    if !enabled {
        close_keyboard();
        if let Some(path) = restore_path() {
            let _ = std::fs::remove_file(path);
        }
    }
}
pub fn current_cursor_enabled() -> bool {
    output().opted_in.load(Ordering::Acquire)
}
pub fn status() -> (Permission, Option<String>) {
    output().permission.lock().unwrap().clone()
}
pub fn target() -> u64 {
    if current_cursor_enabled() && status().0 == Permission::Granted {
        output().generation.load(Ordering::Acquire)
    } else {
        0
    }
}
pub fn cancel_insertion() {
    output().generation.fetch_add(1, Ordering::AcqRel);
}
fn close_keyboard() {
    output().request.lock().unwrap().cancel();
    cancel_insertion();
    if let Some(keyboard) = output().keyboard.lock().unwrap().take() {
        keyboard.cancelled.cancel();
        tauri::async_runtime::spawn(async move {
            close_session(&keyboard.connection, &keyboard.session).await;
        });
    }
    *output().permission.lock().unwrap() = (Permission::Unknown, None);
}
pub fn shutdown() {
    output().shutdown.cancel();
    close_keyboard();
}
pub fn request_keyboard() -> Result<(), String> {
    if !current_cursor_enabled() {
        return Err("Choose 'Insert at current cursor' to request Wayland keyboard control. Manual copy needs no keyboard permission.".into());
    }
    if output().pending.swap(true, Ordering::AcqRel) {
        return Ok(());
    }
    close_keyboard();
    let cancel = output().shutdown.child_token();
    *output().request.lock().unwrap() = cancel.clone();
    *output().permission.lock().unwrap() = (
        Permission::Unknown,
        Some("Approve keyboard control in your desktop's permission dialog.".into()),
    );
    tauri::async_runtime::spawn(async move {
        let result = prepare_keyboard(cancel.clone()).await;
        output().pending.store(false, Ordering::Release);
        // Only close_keyboard (opt-out, a new request, shutdown) cancels a grant.
        // Insertion cancels bump the generation and must not discard consent.
        if cancel.is_cancelled() || !current_cursor_enabled() || output().shutdown.is_cancelled() {
            if let Ok(session) = result {
                close_session(&session.connection, &session.session).await;
            }
            return;
        }
        match result {
            Ok(session) => {
                let session = Arc::new(session);
                *output().keyboard.lock().unwrap() = Some(session.clone());
                *output().permission.lock().unwrap() = (Permission::Granted, None);
                tauri::async_runtime::spawn(watch_keyboard(session));
            }
            Err(error) => *output().permission.lock().unwrap() = (Permission::Denied, Some(error)),
        }
    });
    Ok(())
}
fn restore_path() -> Option<PathBuf> {
    output()
        .data
        .lock()
        .unwrap()
        .as_ref()
        .map(|root| root.join("wayland-remote-desktop-token"))
}
fn read_restore_token() -> Option<String> {
    let token = std::fs::read_to_string(restore_path()?).ok()?;
    (token.len() <= 4096 && !token.trim().is_empty()).then_some(token)
}
fn save_restore_token(value: &str) -> Result<(), String> {
    use std::{io::Write, os::unix::fs::OpenOptionsExt};
    if value.len() > 4096 {
        return Err("Desktop returned an oversized restore token".into());
    }
    let Some(path) = restore_path() else {
        return Ok(());
    };
    let parent = path.parent().ok_or("Invalid token directory")?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let temporary = parent.join(format!(".portal-token-{}", token()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|e| e.to_string())?;
    let result = (|| {
        file.write_all(value.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result.map_err(|e: std::io::Error| e.to_string())
}
async fn prepare_keyboard(cancel: CancellationToken) -> Result<KeyboardSession, String> {
    let connection = Connection::session().await.map_err(|e| e.to_string())?;
    prepare_keyboard_on(connection, cancel).await
}
async fn prepare_keyboard_on(
    connection: Connection,
    cancel: CancellationToken,
) -> Result<KeyboardSession, String> {
    let portal = proxy(&connection, DESKTOP, REMOTE).await?;
    let session = create_session(&connection, &portal, &cancel).await?;
    // Subscribe before Start: a compositor can revoke immediately after
    // granting consent, before a separately spawned watcher gets scheduled.
    let session_proxy = proxy(
        &connection,
        session.to_string(),
        "org.freedesktop.portal.Session",
    )
    .await?;
    let closed = session_proxy
        .receive_signal("Closed")
        .await
        .map_err(|e| e.to_string())?;
    let owner = portal
        .receive_owner_changed()
        .await
        .map_err(|e| e.to_string())?;
    let result = async {
        let handle = token();
        let mut selection = options(&handle);
        selection.insert("types", Variant::from(1u32)); // Only keyboard. No screen, pointer or microphone.
        let version: u32 = portal
            .get_property("version")
            .await
            .map_err(|e| e.to_string())?;
        let restore = read_restore_token();
        if version >= 2 {
            selection.insert("persist_mode", Variant::from(2u32));
            if let Some(restore) = &restore {
                selection.insert("restore_token", Variant::from(restore.as_str()));
            }
        }
        request(
            &connection,
            &portal,
            "SelectDevices",
            &(&session, selection),
            &handle,
            &cancel,
        )
        .await?;
        let handle = token();
        let grants = request(
            &connection,
            &portal,
            "Start",
            &(&session, "", options(&handle)),
            &handle,
            &cancel,
        )
        .await?;
        let devices = grants
            .get("devices")
            .and_then(|v| u32::try_from(v).ok())
            .unwrap_or(0);
        if devices & 1 == 0 {
            return Err(
                "Keyboard control was not granted. Your dictation remains available in History."
                    .into(),
            );
        }
        if let Some(restore) = grants
            .get("restore_token")
            .and_then(|v| <&str>::try_from(v).ok())
        {
            save_restore_token(restore)?;
        }
        Ok(())
    }
    .await;
    if let Err(error) = result {
        close_session(&connection, &session).await;
        return Err(error);
    }
    Ok(KeyboardSession {
        connection,
        portal,
        session,
        cancelled: cancel,
        closed: Mutex::new(Some(closed)),
        owner: Mutex::new(Some(owner)),
    })
}
async fn watch_keyboard(session: Arc<KeyboardSession>) {
    let Some(mut closed) = session.closed.lock().unwrap().take() else {
        return;
    };
    let Some(mut owner) = session.owner.lock().unwrap().take() else {
        return;
    };
    let monitor = async {
        tokio::select! { _ = session.cancelled.cancelled() => Ok::<_, String>(()), _ = closed.next() => Err("Desktop revoked keyboard control".into()), _ = owner.next() => Err("Desktop portal restarted".into()) }
    }.await;
    if let Err(error) = monitor {
        let is_current = output()
            .keyboard
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, &session));
        if is_current {
            cancel_insertion();
            session.cancelled.cancel();
            *output().keyboard.lock().unwrap() = None;
            *output().permission.lock().unwrap() = (
                Permission::Denied,
                Some(format!(
                    "{error}. Approve keyboard access again, or copy from History."
                )),
            );
        }
    }
}
fn keysyms(text: &str) -> Result<Vec<i32>, String> {
    if text.trim().is_empty() || text.chars().count() > 16_384 {
        return Err(
            "Dictation is empty or too large for direct insertion; copy it from History.".into(),
        );
    }
    // Return/Tab synthetic keys can submit a chat or change fields. A keyboard
    // portal has no atomic insertText API; never turn paragraphs into actions.
    if text.chars().any(char::is_control) {
        return Err("This dictation includes paragraphs or control characters. Copy it from History to preserve them safely.".into());
    }
    Ok(text
        .chars()
        .map(|c| {
            if u32::from(c) <= 0xff {
                u32::from(c) as i32
            } else {
                (0x0100_0000 | u32::from(c)) as i32
            }
        })
        .collect())
}
pub fn insert(text: &str, target: u64) -> Result<(), String> {
    let symbols = keysyms(text)?;
    if target == 0 || !current_cursor_enabled() {
        return Err("Copy this dictation from History, or explicitly enable insertion at the current cursor in Settings.".into());
    }
    if target != output().generation.load(Ordering::Acquire) {
        return Err("Insertion was cancelled or keyboard access changed. Copy the saved dictation from History.".into());
    }
    let session = output()
        .keyboard
        .lock()
        .unwrap()
        .clone()
        .ok_or("Approve Wayland keyboard control again before dictating")?;
    let operation = session.cancelled.child_token();
    let cancelled = operation.clone();
    let (send, receive) = std::sync::mpsc::sync_channel(1);
    tauri::async_runtime::spawn(async move {
        let result = async {
            for (written, keysym) in symbols.into_iter().enumerate() {
                if operation.is_cancelled() || !current_cursor_enabled() || target != output().generation.load(Ordering::Acquire) {
                    return Err(format!("Insertion stopped after {written} characters. The complete dictation is in History; check the target before copying."));
                }
                let args = (&session.session, Options::new(), keysym, 1u32);
                let pressed = tokio::time::timeout(Duration::from_secs(2), session.portal.call::<_, _, ()>("NotifyKeyboardKeysym", &args)).await;
                // A timed-out call may still have reached the compositor. Always
                // attempt release, including cancellation and lost method replies.
                let args = (&session.session, Options::new(), keysym, 0u32);
                let released = tokio::time::timeout(Duration::from_secs(2), session.portal.call::<_, _, ()>("NotifyKeyboardKeysym", &args)).await;
                pressed.map_err(|_| format!("Keyboard control timed out after {written} characters; check the target before copying from History"))?
                    .map_err(|e| format!("Keyboard control failed after {written} characters: {e}"))?;
                released.map_err(|_| "Keyboard release timed out; reconnect keyboard control".to_string())?.map_err(|e| e.to_string())?;
            }
            Ok(())
        }.await;
        if let Err(error) = &result {
            let is_current = output()
                .keyboard
                .lock()
                .unwrap()
                .as_ref()
                .is_some_and(|current| Arc::ptr_eq(current, &session));
            if is_current && !operation.is_cancelled() {
                close_keyboard();
                *output().permission.lock().unwrap() = (
                    Permission::Denied,
                    Some(format!(
                        "{error}. Approve keyboard access again, or copy from History."
                    )),
                );
            }
        }
        let _ = send.send(result);
    });
    match receive.recv_timeout(Duration::from_secs(30)) {
        Ok(result) => result,
        Err(_) => {
            cancelled.cancel();
            // Let the bounded press/release pair finish before returning control
            // to the user. Closing the portal session also releases its keys.
            close_keyboard();
            let stopped = receive.recv_timeout(Duration::from_secs(5)).is_ok();
            Err(if stopped {
                "Insertion timed out and stopped. Check the target before copying the complete text from History."
            } else {
                "Insertion timed out; keyboard access is closing. Check the target before copying the complete text from History."
            }.into())
        }
    }
}

/// login1 exposes sleep and lock state without observing raw keyboard input.
/// A separate connection keeps this independent of portal restarts/revocation.
pub async fn watch_session(suspended: Arc<dyn Fn() + Send + Sync>, cancel: CancellationToken) {
    loop {
        let was_monitoring = watch_session_once(suspended.clone(), cancel.clone()).await;
        if cancel.is_cancelled() {
            return;
        }
        // A lost monitor is also a cancellation boundary. Reconnect after a
        // login1/session-bus restart instead of silently losing lock handling.
        if was_monitoring {
            suspended();
        }
        tokio::select! {
            _ = cancel.cancelled() => return,
            _ = tokio::time::sleep(Duration::from_secs(2)) => {},
        }
    }
}
async fn watch_session_once(
    suspended: Arc<dyn Fn() + Send + Sync>,
    cancel: CancellationToken,
) -> bool {
    let mut connected = false;
    let result = async {
        let connection = Connection::system().await?;
        let manager = Proxy::new(&connection, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager").await?;
        let path: OwnedObjectPath = manager.call("GetSessionByPID", &(std::process::id(),)).await?;
        let session = Proxy::new(&connection, "org.freedesktop.login1", path, "org.freedesktop.login1.Session").await?;
        let mut sleep = manager.receive_signal("PrepareForSleep").await?;
        let mut lock = session.receive_signal("Lock").await?;
        let mut hint = session.receive_property_changed::<bool>("LockedHint").await;
        connected = true;
        loop {
            tokio::select! {
                _ = cancel.cancelled() => return Ok::<_, zbus::Error>(()),
                signal = sleep.next() => { let Some(signal) = signal else { break; }; if signal.body().deserialize::<(bool,)>()?.0 { suspended(); } },
                signal = lock.next() => { if signal.is_none() { break; } suspended(); },
                value = hint.next() => { let Some(value) = value else { break; }; if value.get().await? { suspended(); } },
            }
        }
        Ok(())
    }.await;
    if result.is_err() && !cancel.is_cancelled() {
        // Some minimal desktops have no login1. A standard ScreenSaver signal
        // still cancels on lock; lack of both does not invent a permission grant.
        if let Ok(connection) = Connection::session().await {
            if let Ok(proxy) = Proxy::new(
                &connection,
                "org.freedesktop.ScreenSaver",
                "/org/freedesktop/ScreenSaver",
                "org.freedesktop.ScreenSaver",
            )
            .await
            {
                if let Ok(mut signals) = proxy.receive_signal("ActiveChanged").await {
                    connected = true;
                    loop {
                        tokio::select! {
                            _ = cancel.cancelled() => break,
                            signal = signals.next() => { let Some(signal) = signal else { break; }; if signal.body().deserialize::<(bool,)>().is_ok_and(|(active,)| active) { suspended(); } },
                        }
                    }
                }
            }
        }
    }
    connected
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_does_not_assume_an_english_keyboard_layout() {
        assert_eq!(
            keysyms("Aé日本🙂").unwrap(),
            vec![65, 233, 0x010065e5, 0x0100672c, 0x0101f642]
        );
        assert!(keysyms("first\nsecond").is_err());
        assert!(keysyms("submit\r").is_err());
        assert!(keysyms("\u{1b}").is_err());
    }
    #[test]
    fn translates_only_documented_portal_triggers() {
        assert_eq!(
            portal_trigger("Control+Shift+Space").unwrap(),
            "CTRL+SHIFT+space"
        );
        assert_eq!(portal_trigger("Alt+F9").unwrap(), "ALT+F9");
        assert_eq!(portal_trigger("CmdOrCtrl+Enter").unwrap(), "CTRL+Return");
        assert_eq!(portal_trigger("Control+KeyA").unwrap(), "CTRL+a");
        assert_eq!(portal_trigger("Control+ArrowUp").unwrap(), "CTRL+Up");
        assert!(portal_trigger("Unknown+Space").is_err());
    }
}

#[cfg(test)]
#[path = "wayland_tests.rs"]
mod wire_tests;
