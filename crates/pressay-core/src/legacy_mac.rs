//! Reads the retired Swift app's data so the desktop app can take it over.
//!
//! The Swift app kept dictations in a SwiftData (Core Data SQLite) store, meetings in
//! `Notes.json` and settings in its preferences. Everything is read-only: the original
//! files are never changed, so reinstalling the Swift app still finds them.
use crate::storage::{Dictation, Snapshot};
use crate::{Error, Result};
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Map, Value};
use std::path::Path;

/// Core Data stores dates as seconds since 2001-01-01.
const REFERENCE_DATE: f64 = 978_307_200.0;

/// Fixed so an automatic import runs once; `Store::import` records it.
pub const SOURCE: &str = "pressay-macos:automatic";

/// Settings the desktop app understands or keeps for later.
pub const SETTING_KEYS: &[&str] = &[
    "holdKey",
    "holdKeyCode",
    "language",
    "asrModel",
    "meetingASRModel",
    "meetingLanguage",
    "vocabulary",
    "manualVocabularyOnly",
    "onboardingComplete",
    "hasUsedDictation",
    "inputDeviceUID",
    "claudeCleanup",
    "claudeConnection",
    "cleanupProvider",
    "openAIConnection",
    "chatGPTWelcomeShown",
    "notesModel",
    "detectCalls",
    "maxMeetingHours",
    "notesUseAI",
    "keepMicWarm",
    "learnFromEdits",
    "snippets",
    "structuredDictation",
    "showLiveTranscript",
    "stopWhenCallEnds",
    "meetingSystemAudio",
    "separateVoices",
    "noteStyle",
    "matchAppStyle",
];

/// Whether `directory` (the Swift app's Application Support folder) holds anything to take over.
pub fn has_data(directory: &Path) -> bool {
    directory.join("History.store").is_file() || directory.join("Notes.json").is_file()
}

/// Builds a migration snapshot from the Swift app's folder and its preferences
/// (already converted to JSON by the host).
pub fn snapshot(directory: &Path, preferences: &Map<String, Value>) -> Result<Snapshot> {
    let settings = preferences
        .iter()
        .filter(|(key, _)| SETTING_KEYS.contains(&key.as_str()))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect::<Map<_, _>>();
    Ok(Snapshot {
        schema: 1,
        source: SOURCE.into(),
        settings: Value::Object(settings),
        dictations: dictations(&directory.join("History.store"))?,
        notes: notes(&directory.join("Notes.json"))?,
    })
}

fn dictations(path: &Path) -> Result<Vec<Dictation>> {
    if !path.is_file() {
        return Ok(vec![]);
    }
    let db = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let mut statement = db.prepare(
        "SELECT ZID, ZCREATEDAT, ZDURATION, ZTARGETBUNDLEID, ZTARGETAPPNAME, ZENGINERAWVALUE,
                ZRAWTRANSCRIPT, ZPOLISHEDTEXT, ZCORRECTION, ZASRLATENCY, ZPOLISHLATENCY,
                ZTOTALLATENCY, ZAUDIOPATH, ZISPINNED, ZUSEDLANGUAGEMODEL
         FROM ZDICTATIONRECORD ORDER BY ZCREATEDAT, Z_PK",
    )?;
    let rows = statement.query_map([], |row| {
        let id: Vec<u8> = row.get(0)?;
        let created: f64 = row.get(1)?;
        let text = |i: usize| {
            row.get::<_, Option<String>>(i)
                .map(Option::unwrap_or_default)
        };
        let number = |i: usize| row.get::<_, Option<f64>>(i).map(|v| v.unwrap_or(0.0));
        let flag = |i: usize| row.get::<_, Option<i64>>(i).map(|v| v.unwrap_or(0) != 0);
        Ok((
            id,
            created + REFERENCE_DATE,
            number(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, Option<String>>(4)?,
            text(5)?,
            text(6)?,
            text(7)?,
            row.get::<_, Option<String>>(8)?,
            [number(9)?, number(10)?, number(11)?],
            row.get::<_, Option<String>>(12)?,
            flag(13)?,
            flag(14)?,
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (
            id,
            created_at,
            duration,
            bundle,
            app,
            engine,
            raw,
            text,
            correction,
            latency,
            audio,
            pinned,
            language_model,
        ) = row?;
        let id = uuid::Uuid::from_slice(&id)
            .map_err(|_| Error::Message("A dictation has an unreadable identifier".into()))?
            .hyphenated()
            .to_string()
            .to_uppercase();
        out.push(Dictation {
            legacy: json!({
                "id": id, "createdAt": created_at, "duration": duration,
                "targetBundleID": bundle, "targetAppName": app, "engineRawValue": engine,
                "rawTranscript": raw, "polishedText": text, "correction": correction,
                "asrLatency": latency[0], "polishLatency": latency[1], "totalLatency": latency[2],
                "audioPath": audio, "isPinned": pinned, "usedLanguageModel": language_model,
            }),
            id,
            created_at,
            duration: duration.max(0.0),
            model: engine,
            raw,
            text,
            correction,
            pinned,
            target: bundle,
            latency: latency[2],
        });
    }
    Ok(out)
}

fn notes(path: &Path) -> Result<Vec<Value>> {
    if !path.is_file() {
        return Ok(vec![]);
    }
    let Value::Array(notes) = serde_json::from_slice(&std::fs::read(path)?)? else {
        return Err(Error::Message("Notes.json is not a list of notes".into()));
    };
    notes
        .into_iter()
        .map(|mut note| {
            let object = note
                .as_object_mut()
                .filter(|n| {
                    n.get("id")
                        .and_then(Value::as_str)
                        .is_some_and(|id| !id.is_empty())
                })
                .ok_or_else(|| Error::Message("A meeting has no identifier".into()))?;
            for (legacy, unix) in [("createdAt", "created_at"), ("updatedAt", "updated_at")] {
                if let Some(value) = object.get(legacy) {
                    let seconds = unix_date(value)
                        .ok_or_else(|| Error::Message("A meeting has an unreadable date".into()))?;
                    object.insert(unix.into(), json!(seconds));
                }
            }
            Ok(note)
        })
        .collect()
}

fn unix_date(value: &Value) -> Option<f64> {
    if let Some(seconds) = value.as_f64() {
        return seconds.is_finite().then_some(seconds);
    }
    let text = value.as_str()?;
    chrono::DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|d| d.timestamp_millis() as f64 / 1000.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The schema SwiftData created for the Swift app's `DictationRecord`.
    fn swift_store(path: &Path) {
        let db = Connection::open(path).unwrap();
        db.execute_batch(
            "CREATE TABLE ZDICTATIONRECORD ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
               ZISPINNED INTEGER, ZUSEDLANGUAGEMODEL INTEGER, ZASRLATENCY FLOAT, ZCREATEDAT TIMESTAMP,
               ZDURATION FLOAT, ZPOLISHLATENCY FLOAT, ZTOTALLATENCY FLOAT, ZAUDIOPATH VARCHAR,
               ZCORRECTION VARCHAR, ZENGINERAWVALUE VARCHAR, ZPOLISHEDTEXT VARCHAR, ZRAWTRANSCRIPT VARCHAR,
               ZTARGETBUNDLEID VARCHAR, ZID BLOB , ZTARGETAPPNAME VARCHAR);",
        )
        .unwrap();
        let id = uuid::Uuid::parse_str("2F1C3B0A-9D4E-4F6A-8B7C-1D2E3F405162").unwrap();
        db.execute(
            "INSERT INTO ZDICTATIONRECORD VALUES (1,1,1,1,0,0.4,815755229.5,3.2,0.9,1.4,'a.caf',
              'Fixed text','orukeet','Polished text','raw text','com.tinyspeck.slackmacgap',?1,'Slack')",
            [id.as_bytes().to_vec()],
        )
        .unwrap();
    }

    #[test]
    fn reads_the_swift_apps_dictations_notes_and_settings() {
        let dir = tempfile::tempdir().unwrap();
        swift_store(&dir.path().join("History.store"));
        std::fs::write(
            dir.path().join("Notes.json"),
            r#"[{"id":"N1","title":"Standup","createdAt":"2026-11-02T10:06:19Z","updatedAt":"2026-11-02T10:25:29.500Z","body":"Hi","lines":[]}]"#,
        )
        .unwrap();
        let preferences =
            json!({"asrModel": "moss", "holdKeyCode": 61, "SUHasLaunchedBefore": true});
        assert!(has_data(dir.path()));
        let snapshot = snapshot(dir.path(), preferences.as_object().unwrap()).unwrap();
        assert_eq!(snapshot.source, SOURCE);
        assert_eq!(
            snapshot.settings,
            json!({"asrModel": "moss", "holdKeyCode": 61})
        );
        let record = &snapshot.dictations[0];
        assert_eq!(record.id, "2F1C3B0A-9D4E-4F6A-8B7C-1D2E3F405162");
        assert_eq!(record.created_at, 815_755_229.5 + REFERENCE_DATE);
        assert_eq!(record.text, "Polished text");
        assert_eq!(record.correction.as_deref(), Some("Fixed text"));
        assert!(record.pinned);
        assert_eq!(record.target.as_deref(), Some("com.tinyspeck.slackmacgap"));
        assert_eq!(record.legacy["targetAppName"], "Slack");
        let note = &snapshot.notes[0];
        assert_eq!(note["created_at"], json!(1_793_613_979.0));
        assert_eq!(note["updated_at"], json!(1_793_615_129.5));
        assert_eq!(note["title"], "Standup");
    }

    #[test]
    fn importing_twice_adds_nothing_the_second_time() {
        let dir = tempfile::tempdir().unwrap();
        swift_store(&dir.path().join("History.store"));
        let snapshot = snapshot(dir.path(), &Map::new()).unwrap();
        let mut store = crate::storage::Store::open(&dir.path().join("desktop.sqlite")).unwrap();
        assert!(store.import(&snapshot).unwrap());
        assert!(!store.import(&snapshot).unwrap());
        assert_eq!(store.history(10).unwrap().len(), 1);
    }

    #[test]
    fn missing_folder_is_empty() {
        let dir = tempfile::tempdir().unwrap();
        assert!(!has_data(dir.path()));
        let snapshot = snapshot(dir.path(), &Map::new()).unwrap();
        assert!(snapshot.dictations.is_empty() && snapshot.notes.is_empty());
    }
}
