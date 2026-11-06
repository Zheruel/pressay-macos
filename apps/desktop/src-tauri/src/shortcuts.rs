//! Native shortcut lifetime. Esc is reserved only while dictation is busy;
//! Wayland portals use an explicit cancel chord instead of stealing global Esc.
use serde::{Deserialize, Serialize};
#[cfg(target_os = "macos")]
use std::sync::OnceLock;
#[cfg(any(target_os = "macos", windows))]
use std::sync::Weak;
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Mutex,
};
use tauri::AppHandle;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
use tokio_util::sync::CancellationToken;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Binding {
    MacKey {
        #[serde(rename = "keyCode")]
        key_code: u16,
    },
    Chord {
        accelerator: String,
    },
}
impl Default for Binding {
    fn default() -> Self {
        if cfg!(target_os = "macos") {
            Self::MacKey { key_code: 61 }
        } else {
            Self::Chord {
                accelerator: "Control+Shift+Space".into(),
            }
        }
    }
}
impl Binding {
    pub fn from_settings(settings: &serde_json::Value) -> Self {
        settings
            .get("shortcut")
            .and_then(|v| serde_json::from_value::<Self>(v.clone()).ok())
            .filter(|b| b.validate().is_ok())
            .or_else(|| {
                settings["holdKeyCode"]
                    .as_u64()
                    .filter(|code| cfg!(target_os = "macos") && *code <= 127)
                    .map(|code| Self::MacKey {
                        key_code: code as u16,
                    })
                    .filter(|b| b.validate().is_ok())
            })
            .unwrap_or_default()
    }
    pub fn validate(&self) -> Result<(), String> {
        match self {
            Self::MacKey { key_code } => {
                if !cfg!(target_os = "macos") {
                    return Err("Physical Mac hold keys are only available on macOS. Choose a shortcut chord.".into());
                }
                if *key_code > 127 || [53, 57].contains(key_code) {
                    return Err("Choose a hold key other than Escape or Caps Lock".into());
                }
                Ok(())
            }
            Self::Chord { accelerator } => {
                if accelerator.len() > 120 {
                    return Err("Shortcut is too long".into());
                }
                let shortcut: Shortcut = accelerator
                    .parse()
                    .map_err(|e| format!("Invalid shortcut: {e}"))?;
                if shortcut.to_string() == "Escape" {
                    return Err("Escape is reserved for cancelling dictation".into());
                }
                // A text key grabbed globally can consume/retrigger our own
                // Unicode insertion on X11. Physical Mac keys use our event
                // tap's synthetic-event guard; other systems need a real chord.
                let key = shortcut.key.to_string();
                let function_key = key
                    .strip_prefix('F')
                    .and_then(|n| n.parse::<u8>().ok())
                    .is_some_and(|n| (1..=24).contains(&n));
                if shortcut.mods.is_empty() && !function_key {
                    return Err("Choose a shortcut with Control, Alt, Shift or Super, or a function key such as F9.".into());
                }
                Ok(())
            }
        }
    }
    pub fn label(&self) -> String {
        match self {
            Self::MacKey { key_code } => match key_code {
                61 => "Right Option".into(),
                58 => "Left Option".into(),
                54 => "Right Command".into(),
                55 => "Left Command".into(),
                56 => "Left Shift".into(),
                60 => "Right Shift".into(),
                59 => "Left Control".into(),
                62 => "Right Control".into(),
                63 => "Fn".into(),
                _ => format!("Mac key {key_code}"),
            },
            Self::Chord { accelerator } => accelerator.replace('+', " + "),
        }
    }
}
#[derive(Clone, Debug)]
pub enum Event {
    Pressed,
    Released,
    Cancel,
    Suspended,
    Availability {
        available: bool,
        trigger: String,
        error: Option<String>,
    },
}
pub type Callback = Arc<dyn Fn(Event) + Send + Sync>;
struct Inner {
    app: AppHandle,
    callback: Callback,
    binding: Mutex<Binding>,
    registered: Mutex<Option<String>>,
    escape_registered: AtomicBool,
    pressed: AtomicBool,
    busy: AtomicBool,
    generation: AtomicU64,
    stopped: AtomicBool,
    shutdown: CancellationToken,
    registration: Mutex<CancellationToken>,
    #[cfg(windows)]
    lifecycle_window: std::sync::atomic::AtomicIsize,
}
impl Inner {
    fn event(&self, event: Event) {
        if self.stopped.load(Ordering::Acquire) {
            return;
        }
        match &event {
            Event::Pressed if self.pressed.swap(true, Ordering::AcqRel) => return,
            Event::Released if !self.pressed.swap(false, Ordering::AcqRel) => return,
            Event::Cancel | Event::Suspended => {
                self.pressed.store(false, Ordering::Release);
                crate::platform::cancel_pending_insertions();
            }
            _ => {}
        }
        (self.callback)(event);
    }
    fn available(&self, available: bool, error: Option<String>) {
        self.event(Event::Availability {
            available,
            trigger: self.binding.lock().unwrap().label(),
            error,
        });
    }
}
#[derive(Clone)]
pub struct ShortcutController {
    inner: Arc<Inner>,
}
pub fn install(
    app: AppHandle,
    binding: Binding,
    callback: impl Fn(Event) + Send + Sync + 'static,
) -> Result<ShortcutController, String> {
    binding.validate()?;
    let inner = Arc::new(Inner {
        app,
        callback: Arc::new(callback),
        binding: Mutex::new(binding.clone()),
        registered: Mutex::new(None),
        escape_registered: AtomicBool::new(false),
        pressed: AtomicBool::new(false),
        busy: AtomicBool::new(false),
        generation: AtomicU64::new(0),
        stopped: AtomicBool::new(false),
        shutdown: CancellationToken::new(),
        registration: Mutex::new(CancellationToken::new()),
        #[cfg(windows)]
        lifecycle_window: std::sync::atomic::AtomicIsize::new(0),
    });
    let controller = ShortcutController { inner };
    #[cfg(target_os = "linux")]
    {
        let weak = Arc::downgrade(&controller.inner);
        let cancel = controller.inner.shutdown.clone();
        tauri::async_runtime::spawn(crate::wayland::watch_session(
            Arc::new(move || {
                if let Some(inner) = weak.upgrade() {
                    inner.event(Event::Suspended);
                }
            }),
            cancel,
        ));
    }
    #[cfg(windows)]
    lifecycle::start(Arc::downgrade(&controller.inner));
    controller.rebind(binding)?;
    Ok(controller)
}
impl ShortcutController {
    pub fn binding(&self) -> Binding {
        self.inner.binding.lock().unwrap().clone()
    }
    pub fn rebind(&self, binding: Binding) -> Result<(), String> {
        binding.validate()?;
        if self.inner.stopped.load(Ordering::Acquire) {
            return Err("Shortcut service has stopped".into());
        }
        self.inner.event(Event::Cancel);
        self.inner.registration.lock().unwrap().cancel();
        let cancel = self.inner.shutdown.child_token();
        *self.inner.registration.lock().unwrap() = cancel.clone();
        let generation = self.inner.generation.fetch_add(1, Ordering::AcqRel) + 1;
        if let Some(old) = self.inner.registered.lock().unwrap().take() {
            let _ = self.inner.app.global_shortcut().unregister(old.as_str());
        }
        *self.inner.binding.lock().unwrap() = binding.clone();
        #[cfg(target_os = "macos")]
        {
            *mac_callback().lock().unwrap() = Arc::downgrade(&self.inner);
            let key = match &binding {
                Binding::MacKey { key_code } => *key_code,
                _ => u16::MAX,
            };
            unsafe {
                pressay_shortcuts_start(key, native_event, std::ptr::null_mut());
            }
            if matches!(binding, Binding::MacKey { .. }) {
                return Ok(());
            }
        }
        let Binding::Chord { accelerator } = binding else {
            return Err("Choose a shortcut chord on this platform".into());
        };
        #[cfg(target_os = "linux")]
        if crate::platform::is_wayland() {
            let weak = Arc::downgrade(&self.inner);
            tauri::async_runtime::spawn(async move {
                crate::wayland::bind_shortcuts(
                    accelerator,
                    Arc::new(move |event| {
                        if let Some(inner) = weak.upgrade() {
                            if inner.generation.load(Ordering::Acquire) == generation {
                                inner.event(event);
                            }
                        }
                    }),
                    cancel,
                )
                .await;
            });
            return Ok(());
        }
        let weak = Arc::downgrade(&self.inner);
        match self.inner.app.global_shortcut().on_shortcut(
            accelerator.as_str(),
            move |_, _, event| {
                if let Some(inner) = weak.upgrade() {
                    if inner.generation.load(Ordering::Acquire) == generation {
                        inner.event(if event.state == ShortcutState::Pressed {
                            Event::Pressed
                        } else {
                            Event::Released
                        });
                    }
                }
            },
        ) {
            Ok(()) => {
                *self.inner.registered.lock().unwrap() = Some(accelerator);
                self.inner.available(true, None);
            }
            Err(error) => self.inner.available(
                false,
                Some(format!(
                    "Shortcut is unavailable: {error}. Choose another key or approve input access."
                )),
            ),
        }
        Ok(())
    }
    pub fn set_busy(&self, busy: bool) {
        if self.inner.busy.swap(busy, Ordering::AcqRel) == busy {
            return;
        }
        #[cfg(target_os = "macos")]
        unsafe {
            pressay_shortcuts_busy(busy);
        }
        #[cfg(not(target_os = "macos"))]
        {
            #[cfg(target_os = "linux")]
            if crate::platform::is_wayland() {
                return;
            }
            if busy {
                let weak = Arc::downgrade(&self.inner);
                let result =
                    self.inner
                        .app
                        .global_shortcut()
                        .on_shortcut("Escape", move |_, _, event| {
                            if event.state == ShortcutState::Pressed {
                                if let Some(inner) = weak.upgrade() {
                                    if inner.busy.load(Ordering::Acquire) {
                                        inner.event(Event::Cancel);
                                    }
                                }
                            }
                        });
                self.inner
                    .escape_registered
                    .store(result.is_ok(), Ordering::Release);
                if let Err(error) = result {
                    let available = self.inner.registered.lock().unwrap().is_some();
                    self.inner.available(
                        available,
                        Some(format!(
                            "Escape could not be registered ({error}). Use Cancel in Pressay."
                        )),
                    );
                }
            } else if self.inner.escape_registered.swap(false, Ordering::AcqRel) {
                let _ = self.inner.app.global_shortcut().unregister("Escape");
            }
        }
    }
    pub fn shutdown(&self) {
        if self.inner.stopped.swap(true, Ordering::AcqRel) {
            return;
        }
        self.inner.shutdown.cancel();
        self.inner.registration.lock().unwrap().cancel();
        crate::platform::cancel_pending_insertions();
        if let Some(old) = self.inner.registered.lock().unwrap().take() {
            let _ = self.inner.app.global_shortcut().unregister(old.as_str());
        }
        if self.inner.escape_registered.swap(false, Ordering::AcqRel) {
            let _ = self.inner.app.global_shortcut().unregister("Escape");
        }
        #[cfg(target_os = "macos")]
        unsafe {
            pressay_shortcuts_stop();
        }
        #[cfg(windows)]
        lifecycle::stop(&self.inner);
        #[cfg(target_os = "linux")]
        crate::wayland::shutdown();
    }
}
#[cfg(target_os = "macos")]
fn mac_callback() -> &'static Mutex<Weak<Inner>> {
    static CALLBACK: OnceLock<Mutex<Weak<Inner>>> = OnceLock::new();
    CALLBACK.get_or_init(|| Mutex::new(Weak::new()))
}
#[cfg(target_os = "macos")]
extern "C" {
    fn pressay_shortcuts_start(
        key: u16,
        callback: extern "C" fn(i32, i32, *mut std::ffi::c_void),
        context: *mut std::ffi::c_void,
    );
    fn pressay_shortcuts_busy(busy: bool);
    fn pressay_shortcuts_stop();
}
#[cfg(target_os = "macos")]
extern "C" fn native_event(event: i32, detail: i32, _: *mut std::ffi::c_void) {
    // Never unwind across Objective-C's event callback boundary.
    let _ = std::panic::catch_unwind(|| {
        let inner = mac_callback().lock().ok().and_then(|weak| weak.upgrade());
        if let Some(inner) = inner {
            match event {
                1 => inner.event(Event::Pressed), 2 => inner.event(Event::Released),
                3 => inner.event(Event::Cancel), 4 => inner.event(Event::Suspended),
                5 => inner.available(detail == 1, (detail != 1).then(|| "Allow Accessibility and Input Monitoring in System Settings. Pressay will reconnect automatically.".into())),
                _ => {}
            }
        }
    });
}

#[cfg(windows)]
mod lifecycle {
    use super::*;
    use windows::{
        core::w,
        Win32::{
            Foundation::{HWND, LPARAM, LRESULT, WPARAM},
            System::{
                LibraryLoader::GetModuleHandleW,
                RemoteDesktop::{
                    WTSRegisterSessionNotification, WTSUnRegisterSessionNotification,
                    NOTIFY_FOR_THIS_SESSION,
                },
            },
            UI::WindowsAndMessaging::*,
        },
    };
    unsafe extern "system" fn procedure(
        hwnd: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        if message == WM_NCCREATE {
            let create = &*(lparam.0 as *const CREATESTRUCTW);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
        }
        let context = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const Weak<Inner>;
        if !context.is_null()
            && ((message == WM_WTSSESSION_CHANGE && [0x2, 0x3, 0x4, 0x6, 0x7].contains(&wparam.0))
                || (message == WM_POWERBROADCAST && wparam.0 == PBT_APMSUSPEND as usize))
        {
            if let Some(inner) = (*context).upgrade() {
                inner.event(Event::Suspended);
            }
        }
        if message == WM_CLOSE {
            let _ = DestroyWindow(hwnd);
            return LRESULT(0);
        }
        if message == WM_DESTROY {
            let _ = WTSUnRegisterSessionNotification(hwnd);
            PostQuitMessage(0);
            return LRESULT(0);
        }
        DefWindowProcW(hwnd, message, wparam, lparam)
    }
    pub fn start(weak: Weak<Inner>) {
        std::thread::spawn(move || unsafe {
            let context = Box::new(weak);
            let instance = match GetModuleHandleW(None) {
                Ok(value) => value,
                Err(_) => return,
            };
            let class = WNDCLASSW {
                lpfnWndProc: Some(procedure),
                hInstance: instance.into(),
                lpszClassName: w!("PressaySessionObserver"),
                ..Default::default()
            };
            RegisterClassW(&class);
            // Hidden top-level windows receive power broadcasts; message-only windows do not.
            let window = match CreateWindowExW(
                WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                class.lpszClassName,
                w!("Pressay session observer"),
                WS_POPUP,
                0,
                0,
                0,
                0,
                None,
                None,
                Some(instance.into()),
                Some(context.as_ref() as *const _ as *const _),
            ) {
                Ok(window) => window,
                Err(_) => return,
            };
            if let Some(inner) = context.upgrade() {
                inner
                    .lifecycle_window
                    .store(window.0 as isize, Ordering::Release);
                if inner.stopped.load(Ordering::Acquire) {
                    let _ = DestroyWindow(window);
                    return;
                }
                if let Err(error) = WTSRegisterSessionNotification(window, NOTIFY_FOR_THIS_SESSION)
                {
                    let available = inner.registered.lock().unwrap().is_some();
                    inner.available(
                        available,
                        Some(format!("Session-lock monitoring could not start: {error}")),
                    );
                }
            } else {
                let _ = DestroyWindow(window);
                return;
            }
            let mut message = MSG::default();
            while GetMessageW(&mut message, None, 0, 0).0 > 0 {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
            if let Some(inner) = context.upgrade() {
                inner.lifecycle_window.store(0, Ordering::Release);
            }
        });
    }
    pub fn stop(inner: &Inner) {
        let window = inner.lifecycle_window.load(Ordering::Acquire);
        if window != 0 {
            unsafe {
                let _ = PostMessageW(Some(HWND(window as *mut _)), WM_CLOSE, WPARAM(0), LPARAM(0));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn persisted_bindings_round_trip_and_reject_reserved_keys() {
        let binding: Binding =
            serde_json::from_str(r#"{"kind":"chord","accelerator":"Control+Shift+Space"}"#)
                .unwrap();
        assert!(binding.validate().is_ok());
        assert_eq!(
            serde_json::from_str::<Binding>(&serde_json::to_string(&binding).unwrap()).unwrap(),
            binding
        );
        assert!(Binding::Chord {
            accelerator: "Escape".into()
        }
        .validate()
        .is_err());
        assert!(Binding::Chord {
            accelerator: "not+a+shortcut".into()
        }
        .validate()
        .is_err());
        assert!(Binding::MacKey { key_code: 53 }.validate().is_err());
        assert!(Binding::Chord {
            accelerator: "A".into()
        }
        .validate()
        .is_err());
        assert!(Binding::Chord {
            accelerator: "Space".into()
        }
        .validate()
        .is_err());
        assert!(Binding::Chord {
            accelerator: "F9".into()
        }
        .validate()
        .is_ok());
    }
}
