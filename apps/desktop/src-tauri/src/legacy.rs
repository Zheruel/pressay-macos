//! Takes over the retired Swift app's dictations, meetings and settings on first launch.
//! The Swift app's files are only read; reinstalling it still finds them.
use crate::engine::{Command, Shared};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

const DONE: &str = "swift-app-imported";

pub fn take_over(shared: Arc<Shared>, data: PathBuf) {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return;
    };
    let original = home.join("Library/Application Support/Pressay");
    if data.join(DONE).exists() || !pressay_core::legacy_mac::has_data(&original) {
        return;
    }
    let preferences = home.join("Library/Preferences/dev.localflow.app.plist");
    tauri::async_runtime::spawn(async move {
        let snapshot = tauri::async_runtime::spawn_blocking(move || {
            pressay_core::legacy_mac::snapshot(&original, &read_preferences(&preferences))
        })
        .await;
        let source = match snapshot {
            Ok(Ok(snapshot)) => match serde_json::to_string(&snapshot) {
                Ok(source) => source,
                Err(error) => {
                    return eprintln!("Pressay: couldn't read the Swift app's data: {error}")
                }
            },
            Ok(Err(error)) => {
                return eprintln!("Pressay: couldn't read the Swift app's data: {error}")
            }
            Err(error) => return eprintln!("Pressay: couldn't read the Swift app's data: {error}"),
        };
        let (reply, done) = tokio::sync::oneshot::channel();
        if shared.send(Command::Import(source, reply)).is_err() {
            return;
        }
        match done.await {
            Ok(Ok(())) => {
                let _ = std::fs::write(data.join(DONE), "");
            }
            Ok(Err(error)) => eprintln!("Pressay: couldn't import the Swift app's data: {error}"),
            Err(_) => {}
        }
    });
}

/// The Swift app's preferences as JSON. Dates become Unix seconds; raw data is kept
/// base64-encoded, as the manual export did.
fn read_preferences(path: &Path) -> Map<String, Value> {
    match plist::Value::from_file(path) {
        Ok(plist::Value::Dictionary(values)) => values
            .into_iter()
            .map(|(key, value)| (key, to_json(value)))
            .collect(),
        _ => Map::new(),
    }
}

fn to_json(value: plist::Value) -> Value {
    use base64::Engine;
    match value {
        plist::Value::Boolean(v) => json!(v),
        plist::Value::Integer(v) => v
            .as_signed()
            .map(|v| json!(v))
            .or_else(|| v.as_unsigned().map(|v| json!(v)))
            .unwrap_or(Value::Null),
        plist::Value::Real(v) => json!(v),
        plist::Value::String(v) => json!(v),
        plist::Value::Date(v) => {
            let time: std::time::SystemTime = v.into();
            json!(time
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0))
        }
        plist::Value::Data(v) => json!({
            "encoding": "base64",
            "data": base64::engine::general_purpose::STANDARD.encode(v),
        }),
        plist::Value::Array(v) => Value::Array(v.into_iter().map(to_json).collect()),
        plist::Value::Dictionary(v) => {
            Value::Object(v.into_iter().map(|(k, v)| (k, to_json(v))).collect())
        }
        _ => Value::Null,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn preferences_become_json() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("prefs.plist");
        let mut values = plist::Dictionary::new();
        values.insert("asrModel".into(), "moss".into());
        values.insert("holdKeyCode".into(), 61.into());
        values.insert("claudeCleanup".into(), true.into());
        values.insert("rules".into(), plist::Value::Data(vec![1, 2]));
        plist::Value::Dictionary(values).to_file_xml(&path).unwrap();
        let json = super::read_preferences(&path);
        assert_eq!(json["asrModel"], "moss");
        assert_eq!(json["holdKeyCode"], 61);
        assert_eq!(json["claudeCleanup"], true);
        assert_eq!(json["rules"]["data"], "AQI=");
        assert!(super::read_preferences(&dir.path().join("missing.plist")).is_empty());
    }
}
