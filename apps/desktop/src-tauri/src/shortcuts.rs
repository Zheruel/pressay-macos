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
use tauri::{AppHandle, Emitter, Manager};
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
                49 => "Space".into(),
                36 => "Return".into(),
                76 => "Enter".into(),
                48 => "Tab".into(),
                51 => "Delete".into(),
                117 => "Forward Delete".into(),
                114 => "Help".into(),
                115 => "Home".into(),
                119 => "End".into(),
                116 => "Page Up".into(),
                121 => "Page Down".into(),
                123 => "Left Arrow".into(),
                124 => "Right Arrow".into(),
                125 => "Down Arrow".into(),
                126 => "Up Arrow".into(),
                0 => "A".into(),
                11 => "B".into(),
                8 => "C".into(),
                2 => "D".into(),
                14 => "E".into(),
                3 => "F".into(),
                5 => "G".into(),
                4 => "H".into(),
                34 => "I".into(),
                38 => "J".into(),
                40 => "K".into(),
                37 => "L".into(),
                46 => "M".into(),
                45 => "N".into(),
                31 => "O".into(),
                35 => "P".into(),
                12 => "Q".into(),
                15 => "R".into(),
                1 => "S".into(),
                17 => "T".into(),
                32 => "U".into(),
                9 => "V".into(),
                13 => "W".into(),
                7 => "X".into(),
                16 => "Y".into(),
                6 => "Z".into(),
                29 => "0".into(),
                18 => "1".into(),
                19 => "2".into(),
                20 => "3".into(),
                21 => "4".into(),
                23 => "5".into(),
                22 => "6".into(),
                26 => "7".into(),
                28 => "8".into(),
                25 => "9".into(),
                122 => "F1".into(),
                120 => "F2".into(),
                99 => "F3".into(),
                118 => "F4".into(),
                96 => "F5".into(),
                97 => "F6".into(),
                98 => "F7".into(),
                100 => "F8".into(),
                101 => "F9".into(),
                109 => "F10".into(),
                103 => "F11".into(),
                111 => "F12".into(),
                105 => "F13".into(),
                107 => "F14".into(),
                113 => "F15".into(),
                106 => "F16".into(),
                64 => "F17".into(),
                79 => "F18".into(),
                80 => "F19".into(),
                90 => "F20".into(),
                50 => "`".into(),
                27 => "-".into(),
                24 => "=".into(),
                33 => "[".into(),
                30 => "]".into(),
                42 => "\\".into(),
                41 => ";".into(),
                39 => "'".into(),
                43 => ",".into(),
                47 => ".".into(),
                44 => "/".into(),
                _ => "Unrecognized key — record another".into(),
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
    capturing: AtomicBool,
    capture_epoch: AtomicU64,
    capture_operation: Mutex<()>,
    shutdown: CancellationToken,
    registration: Mutex<CancellationToken>,
    #[cfg(windows)]
    lifecycle_window: std::sync::atomic::AtomicIsize,
}
impl Inner {
    fn event(&self, event: Event) {
        // Serialize a pending key-down with entering local key capture. Once
        // capture owns this gate, no delayed hold can queue a microphone start.
        let _capture_operation = matches!(event, Event::Pressed | Event::Released)
            .then(|| self.capture_operation.lock().unwrap());
        if self.stopped.load(Ordering::Acquire) {
            return;
        }
        if self.capturing.load(Ordering::Acquire) {
            // A Wayland portal may consume its registered chord before the
            // WebView receives it. Recording that same chord is still possible.
            #[cfg(target_os = "linux")]
            if crate::platform::is_wayland() && matches!(event, Event::Pressed | Event::Released) {
                let binding = self.binding.lock().unwrap().clone();
                let _ = self.app.emit("pressay-shortcut-captured", serde_json::json!({"binding":binding,"label":binding.label(),"cancelled":false,"waitForRelease":matches!(event, Event::Pressed)}));
            }
            if matches!(event, Event::Pressed | Event::Released | Event::Cancel) {
                return;
            }
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
        capturing: AtomicBool::new(false),
        capture_epoch: AtomicU64::new(0),
        capture_operation: Mutex::new(()),
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
    // A conflicting shortcut must not prevent opening Settings to repair it.
    // rebind reports registration failure through Availability as well as Err.
    let _ = controller.rebind(binding);
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
            Err(error) => {
                let message = format!(
                    "Shortcut is unavailable: {error}. Choose another key or approve input access."
                );
                self.inner.available(false, Some(message.clone()));
                return Err(message);
            }
        }
        Ok(())
    }
    fn begin_capture(&self, kind: &str, shared: &crate::engine::Shared) -> Result<(), String> {
        let _operation = self.inner.capture_operation.lock().unwrap();
        if shared.view.lock().unwrap().stage != "idle" || shared.is_shutting_down() {
            return Err("Finish the current operation before recording a shortcut".into());
        }
        if self.inner.busy.load(Ordering::Acquire) || self.inner.stopped.load(Ordering::Acquire) {
            return Err("Finish your current dictation before changing the talk key".into());
        }
        if !["macKey", "chord"].contains(&kind) || (kind == "macKey" && !cfg!(target_os = "macos"))
        {
            return Err("Choose a supported shortcut type".into());
        }
        if self.inner.capturing.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        self.inner.pressed.store(false, Ordering::Release);
        let epoch = self.inner.capture_epoch.fetch_add(1, Ordering::AcqRel) + 1;
        let registered = self.inner.registered.lock().unwrap().take();
        if let Some(old) = registered {
            if let Err(error) = self.inner.app.global_shortcut().unregister(old.as_str()) {
                *self.inner.registered.lock().unwrap() = Some(old);
                self.inner.capturing.store(false, Ordering::Release);
                return Err(format!("Could not pause the current shortcut: {error}"));
            }
        }
        #[cfg(target_os = "macos")]
        unsafe {
            pressay_shortcuts_stop();
            if kind == "macKey" {
                pressay_key_capture_start(captured_mac_key);
            }
        }
        let owner = self.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(30)).await;
            if owner.inner.capture_epoch.load(Ordering::Acquire) == epoch
                && owner.inner.capturing.load(Ordering::Acquire)
            {
                let _ = owner.end_capture();
                let _ = owner.inner.app.emit(
                    "pressay-shortcut-captured",
                    serde_json::json!({"cancelled":true}),
                );
            }
        });
        Ok(())
    }
    fn end_capture(&self) -> Result<(), String> {
        let _operation = self.inner.capture_operation.lock().unwrap();
        if !self.inner.capturing.load(Ordering::Acquire) {
            return Ok(());
        }
        self.inner.capture_epoch.fetch_add(1, Ordering::AcqRel);
        #[cfg(target_os = "macos")]
        unsafe {
            pressay_key_capture_stop();
        }
        #[cfg(target_os = "linux")]
        if crate::platform::is_wayland() {
            self.inner.capturing.store(false, Ordering::Release);
            return Ok(());
        }
        let binding = self.binding();
        // Keep capture suppression active during rebind's reset notification.
        let result = self.rebind(binding);
        self.inner.capturing.store(false, Ordering::Release);
        result
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
        self.inner.capturing.store(false, Ordering::Release);
        #[cfg(target_os = "macos")]
        unsafe {
            pressay_key_capture_stop();
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
/// Persist only a successfully registered shortcut. Roll back exactly once on
/// either registration or storage failure; leave the attempted UI draft intact.
pub async fn change_binding<R, S, F>(
    old: Binding,
    new: Binding,
    mut register: R,
    save: S,
) -> Result<(), String>
where
    R: FnMut(Binding) -> Result<(), String>,
    S: FnOnce(Binding) -> F,
    F: std::future::Future<Output = Result<(), String>>,
{
    new.validate()?;
    let result = match register(new.clone()) {
        Ok(()) => save(new).await,
        Err(error) => Err(error),
    };
    if let Err(error) = result {
        return match register(old) {
            Ok(()) => Err(error),
            Err(restore) => Err(format!(
                "{error}. The previous shortcut could not be restored: {restore}"
            )),
        };
    }
    Ok(())
}

#[tauri::command]
pub fn set_shortcut_capture(
    active: bool,
    kind: String,
    app: AppHandle,
    state: tauri::State<'_, Arc<crate::engine::Shared>>,
) -> Result<(), String> {
    let controller = app.state::<ShortcutController>();
    if active {
        if state.view.lock().unwrap().stage != "idle" || state.is_shutting_down() {
            return Err("Finish the current operation before recording a shortcut".into());
        }
        controller.begin_capture(&kind, &state)
    } else {
        controller.end_capture()
    }
}
#[cfg(target_os = "macos")]
extern "C" fn captured_mac_key(code: i32) {
    let _ = std::panic::catch_unwind(|| {
        let inner = mac_callback().lock().ok().and_then(|owner| owner.upgrade());
        if let Some(inner) = inner {
            let controller = ShortcutController {
                inner: inner.clone(),
            };
            let binding = (0..=127).contains(&code).then_some(Binding::MacKey {
                key_code: code as u16,
            });
            if binding
                .as_ref()
                .is_some_and(|binding| binding.validate().is_err())
            {
                return;
            }
            let _ = controller.end_capture();
            let payload = match binding {
                Some(binding) => {
                    serde_json::json!({"label":binding.label(),"binding":binding,"cancelled":false})
                }
                None => serde_json::json!({"cancelled":true}),
            };
            let _ = inner.app.emit("pressay-shortcut-captured", payload);
        }
    });
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
    fn pressay_key_capture_start(callback: extern "C" fn(i32));
    fn pressay_key_capture_stop();
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
    #[tokio::test]
    async fn failed_registration_never_persists_and_restores_previous_key_once() {
        let old = Binding::Chord {
            accelerator: "Control+Shift+A".into(),
        };
        let new = Binding::Chord {
            accelerator: "Control+Shift+B".into(),
        };
        let mut registrations = Vec::new();
        let persisted = std::cell::Cell::new(false);
        let error = change_binding(
            old.clone(),
            new.clone(),
            |binding| {
                registrations.push(binding.clone());
                if binding == new {
                    Err("Already registered by another app".into())
                } else {
                    Ok(())
                }
            },
            |_| async {
                persisted.set(true);
                Ok(())
            },
        )
        .await
        .unwrap_err();
        assert!(error.contains("Already registered"));
        assert!(!persisted.get());
        assert_eq!(registrations, [new, old]);
    }
    #[tokio::test]
    async fn failed_persistence_rolls_back_and_reports_a_failed_restore() {
        let old = Binding::Chord {
            accelerator: "Control+Shift+A".into(),
        };
        let new = Binding::Chord {
            accelerator: "Control+Shift+B".into(),
        };
        let mut registrations = Vec::new();
        let error = change_binding(
            old.clone(),
            new.clone(),
            |binding| {
                registrations.push(binding.clone());
                if binding == old {
                    Err("Old key became unavailable".into())
                } else {
                    Ok(())
                }
            },
            |_| async { Err("Storage unavailable".into()) },
        )
        .await
        .unwrap_err();
        assert!(error.contains("Storage unavailable"));
        assert!(error.contains("Old key became unavailable"));
        assert_eq!(registrations, [new, old]);
    }
    #[tokio::test]
    async fn invalid_shortcut_never_touches_registration_or_storage() {
        let old = Binding::Chord {
            accelerator: "Control+Shift+A".into(),
        };
        let invalid = Binding::Chord {
            accelerator: "Escape".into(),
        };
        assert!(change_binding(
            old,
            invalid,
            |_| panic!("Must not unregister the old key"),
            |_| async { panic!("Must not persist invalid key") }
        )
        .await
        .is_err());
    }

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
