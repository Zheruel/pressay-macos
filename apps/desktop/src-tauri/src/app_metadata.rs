//! Read-only installed application names and small icons for dictation history.
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    sync::{Mutex, OnceLock},
};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AppMetadata {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
}

#[tauri::command]
pub async fn history_app_metadata(
    targets: Vec<String>,
) -> Result<BTreeMap<String, AppMetadata>, String> {
    let targets = validated_targets(targets)?;
    tokio::task::spawn_blocking(move || {
        static CACHE: OnceLock<Mutex<BTreeMap<String, AppMetadata>>> = OnceLock::new();
        let cache = CACHE.get_or_init(|| Mutex::new(BTreeMap::new()));
        let mut result = BTreeMap::new();
        for target in targets {
            let cached = cache.lock().unwrap().get(&target).cloned();
            let metadata = cached.unwrap_or_else(|| {
                let value = lookup(&target).unwrap_or_else(|| AppMetadata {
                    name: fallback_name(&target),
                    icon: None,
                });
                let mut cache = cache.lock().unwrap();
                if cache.len() >= 512 {
                    cache.clear();
                }
                cache.insert(target.clone(), value.clone());
                value
            });
            result.insert(target, metadata);
        }
        result
    })
    .await
    .map_err(|_| "Could not read application metadata".into())
}

fn validated_targets(targets: Vec<String>) -> Result<Vec<String>, String> {
    if targets.len() > 256
        || targets.iter().any(|target| {
            target.is_empty() || target.len() > 512 || target.chars().any(char::is_control)
        })
    {
        return Err("Invalid application metadata request".into());
    }
    let unique: std::collections::BTreeSet<_> = targets.into_iter().collect();
    if unique.len() > 128 {
        return Err("Too many application identifiers".into());
    }
    Ok(unique.into_iter().collect())
}
fn fallback_name(target: &str) -> String {
    let component = target
        .rsplit(['/', '\\'])
        .find(|part| !part.is_empty())
        .unwrap_or(target);
    if let Some(name) = component.strip_suffix(".exe") {
        return name.to_owned();
    }
    if component.contains('.') && !component.ends_with(".app") {
        return component.rsplit('.').next().unwrap_or(component).to_owned();
    }
    component
        .strip_suffix(".app")
        .unwrap_or(component)
        .to_owned()
}

#[cfg(target_os = "macos")]
fn lookup(target: &str) -> Option<AppMetadata> {
    use std::ffi::{c_char, CStr, CString};
    // Only bundle IDs reach NSWorkspace, never renderer-supplied file paths.
    if !target
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b".-_".contains(&b))
    {
        return None;
    }
    unsafe extern "C" {
        fn pressay_app_metadata_json(identifier: *const c_char) -> *mut c_char;
        fn pressay_app_metadata_free(value: *mut c_char);
    }
    let identifier = CString::new(target).ok()?;
    let pointer = unsafe { pressay_app_metadata_json(identifier.as_ptr()) };
    if pointer.is_null() {
        return None;
    }
    let result = unsafe { serde_json::from_slice(CStr::from_ptr(pointer).to_bytes()).ok() };
    unsafe { pressay_app_metadata_free(pointer) };
    result
}
#[cfg(not(target_os = "macos"))]
fn lookup(_: &str) -> Option<AppMetadata> {
    None
}

/// OS regional formatting preference, not the UI translation language.
pub fn locale() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        native_locale(None)
    }
    #[cfg(not(target_os = "macos"))]
    {
        ["LC_ALL", "LC_TIME", "LANG"].iter().find_map(|key| {
            std::env::var(key)
                .ok()
                .and_then(|value| normalize_locale(&value))
        })
    }
}
#[cfg(target_os = "macos")]
fn native_locale(identifier: Option<&str>) -> Option<String> {
    unsafe extern "C" {
        fn pressay_formatting_locale(
            identifier: *const std::ffi::c_char,
            buffer: *mut u8,
            capacity: usize,
        ) -> usize;
    }
    let identifier = identifier.map(std::ffi::CString::new).transpose().ok()?;
    let mut buffer = [0u8; 128];
    let length = unsafe {
        pressay_formatting_locale(
            identifier.as_ref().map_or(std::ptr::null(), |s| s.as_ptr()),
            buffer.as_mut_ptr(),
            buffer.len(),
        )
    };
    if length == 0 || length >= buffer.len() {
        return None;
    }
    normalize_locale(std::str::from_utf8(&buffer[..length]).ok()?)
}
fn normalize_locale(value: &str) -> Option<String> {
    let value = value.split(['.', '@']).next()?.replace('_', "-");
    if value.len() > 64
        || value == "C"
        || value == "POSIX"
        || !value
            .split('-')
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_alphanumeric()))
    {
        return None;
    }
    Some(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(target_os = "macos")]
    #[test]
    fn native_locale_preserves_regional_override_and_script() {
        assert_eq!(native_locale(Some("en_US@rg=hrzzzz")), Some("en-HR".into()));
        assert_eq!(
            native_locale(Some("en_GB@calendar=gregorian")),
            Some("en-GB".into())
        );
        assert_eq!(native_locale(Some("zh_Hant_TW")), Some("zh-Hant-TW".into()));
    }
    #[test]
    fn regional_locales_are_valid_language_tags() {
        assert_eq!(
            normalize_locale("en_GB@calendar=gregorian"),
            Some("en-GB".into())
        );
        assert_eq!(normalize_locale("hr_HR.UTF-8"), Some("hr-HR".into()));
        assert_eq!(normalize_locale("zh_Hant_TW"), Some("zh-Hant-TW".into()));
        for value in ["", "C", "POSIX", "en--US", "../en"] {
            assert_eq!(normalize_locale(value), None);
        }
    }
    #[test]
    fn identifiers_are_bounded_and_deduplicated_before_os_lookup() {
        assert_eq!(
            validated_targets(vec!["com.apple.finder".into(); 128]).unwrap(),
            vec!["com.apple.finder"]
        );
        for bad in [
            String::new(),
            "x".repeat(513),
            "bad\0identifier".into(),
            "bad\nidentifier".into(),
        ] {
            assert!(validated_targets(vec![bad]).is_err());
        }
        assert!(validated_targets((0..129).map(|i| format!("app.{i}")).collect()).is_err());
        assert!(validated_targets(vec!["app".into(); 257]).is_err());
    }
    #[test]
    fn fallback_uses_a_name_without_opening_caller_paths() {
        assert_eq!(fallback_name("com.apple.TextEdit"), "TextEdit");
        assert_eq!(
            fallback_name("C:\\Program Files\\Example\\Example.exe"),
            "Example"
        );
        assert_eq!(fallback_name("/Applications/Example.app"), "Example");
        assert_eq!(fallback_name("org.gnome.TextEditor"), "TextEditor");
        assert_eq!(fallback_name("Unknown application"), "Unknown application");
    }
}
