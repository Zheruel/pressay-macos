use crate::{Error, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Dictation {
    pub id: String,
    pub created_at: f64,
    pub duration: f64,
    pub model: String,
    pub raw: String,
    pub text: String,
    pub correction: Option<String>,
    pub pinned: bool,
    pub target: Option<String>,
    pub latency: f64,
    #[serde(default)]
    pub legacy: Value,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Snapshot {
    pub schema: u32,
    pub source: String,
    pub settings: Value,
    pub dictations: Vec<Dictation>,
    pub notes: Vec<Value>,
}
/// Separate database from SwiftData. Import is additive and transactional;
/// restarting the original app is rollback, with no reverse migration required.
pub struct Store {
    db: Connection,
}
impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(path)
            {
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(e.into()),
            }
        }
        let db = Connection::open(path)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        let has_metadata: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='metadata')",
            [],
            |r| r.get(0),
        )?;
        if has_metadata {
            let schema: Option<String> = db
                .query_row("SELECT value FROM metadata WHERE key='schema'", [], |r| {
                    r.get(0)
                })
                .optional()?;
            if schema.as_deref().is_some_and(|v| v != "1") {
                return Err(Error::Message(
                    "This data was written by a newer Pressay; keep it and update the app".into(),
                ));
            }
        }
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS dictations (id TEXT PRIMARY KEY, created_at REAL NOT NULL, data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS imports (source TEXT PRIMARY KEY, imported_at REAL NOT NULL);")?;
        db.execute("INSERT OR IGNORE INTO metadata VALUES ('schema','1')", [])?;
        Ok(Self { db })
    }
    pub fn settings(&self) -> Result<Value> {
        let text: Option<String> = self
            .db
            .query_row("SELECT value FROM metadata WHERE key='settings'", [], |r| {
                r.get(0)
            })
            .optional()?;
        Ok(text
            .map(|s| serde_json::from_str(&s))
            .transpose()?
            .unwrap_or_else(|| serde_json::json!({})))
    }
    pub fn save_settings(&self, settings: &Value) -> Result<()> {
        if !settings.is_object() {
            return Err(Error::Message("Invalid settings".into()));
        }
        self.db.execute("INSERT INTO metadata VALUES ('settings',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [serde_json::to_string(settings)?])?;
        Ok(())
    }
    pub fn add(&self, record: &Dictation) -> Result<()> {
        validate_record(record)?;
        self.db.execute(
            "INSERT INTO dictations VALUES (?1,?2,?3)",
            params![record.id, record.created_at, serde_json::to_string(record)?],
        )?;
        Ok(())
    }
    pub fn history(&self, limit: usize) -> Result<Vec<Dictation>> {
        let mut q = self
            .db
            .prepare("SELECT data FROM dictations ORDER BY created_at DESC LIMIT ?1")?;
        let rows = q.query_map([limit.min(10_000) as i64], |r| r.get::<_, String>(0))?;
        rows.map(|r| Ok(serde_json::from_str(&r?)?)).collect()
    }
    pub fn delete_dictation(&self, id: &str) -> Result<()> {
        self.db
            .execute("DELETE FROM dictations WHERE id=?1", [id])?;
        Ok(())
    }
    /// Clear every dictation, including pinned/corrected rows. The database
    /// change is atomic; only this preview's UUID-named audio files are removed.
    pub fn clear_dictations(&mut self, audio: &crate::recordings::AudioStore) -> Result<usize> {
        let transaction = self.db.transaction()?;
        let ids = {
            let mut query = transaction.prepare("SELECT id FROM dictations")?;
            let rows = query.query_map([], |row| row.get::<_, String>(0))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };
        transaction.execute("DELETE FROM dictations", [])?;
        transaction.commit()?;
        let mut failures = 0;
        for id in &ids {
            if audio.remove(id).is_err() {
                failures += 1;
            }
        }
        if failures > 0 {
            return Err(Error::Message(format!(
                "History cleared, but {failures} recording files could not be removed from {}",
                audio.root().display()
            )));
        }
        Ok(ids.len())
    }
    pub fn save_note(&self, note: &Value) -> Result<()> {
        let id = note
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .ok_or_else(|| Error::Message("Meeting has no identifier".into()))?;
        self.db.execute(
            "INSERT INTO notes VALUES (?1,?2) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
            params![id, serde_json::to_string(note)?],
        )?;
        Ok(())
    }
    pub fn notes(&self) -> Result<Vec<Value>> {
        let mut q = self
            .db
            .prepare("SELECT data FROM notes ORDER BY rowid DESC")?;
        let rows = q.query_map([], |r| r.get::<_, String>(0))?;
        rows.map(|r| {
            let mut value: Value = serde_json::from_str(&r?)?;
            if let Ok(note) = serde_json::from_value::<crate::notes::Note>(value.clone()) {
                value["kind"] = Value::String(note.kind.clone());
                value["actions"] =
                    serde_json::to_value(crate::notes::ActionItem::parse(&note.body))?;
                value["plainTranscript"] = Value::String(note.transcript());
            }
            Ok(value)
        })
        .collect()
    }
    pub fn dictation(&self, id: &str) -> Result<Dictation> {
        let data: String =
            self.db
                .query_row("SELECT data FROM dictations WHERE id=?1", [id], |r| {
                    r.get(0)
                })?;
        Ok(serde_json::from_str(&data)?)
    }
    pub fn edit_dictation(
        &self,
        id: &str,
        correction: Option<&str>,
        pinned: Option<bool>,
    ) -> Result<Dictation> {
        let mut record = self.dictation(id)?;
        if let Some(text) = correction {
            if text.len() > 1_000_000 {
                return Err(Error::Message("Correction is too long".into()));
            }
            let text = text.trim();
            record.correction = (!text.is_empty()).then(|| text.into());
            record.pinned |= record.correction.is_some();
        }
        if let Some(pinned) = pinned {
            record.pinned = pinned;
        }
        self.update_dictation(&record)?;
        Ok(record)
    }
    pub fn update_dictation(&self, record: &Dictation) -> Result<()> {
        validate_record(record)?;
        if self.db.execute(
            "UPDATE dictations SET data=?2 WHERE id=?1",
            params![record.id, serde_json::to_string(record)?],
        )? == 0
        {
            return Err(Error::Message("This dictation no longer exists".into()));
        }
        Ok(())
    }
    pub fn note(&self, id: &str) -> Result<crate::notes::Note> {
        let data: String = self
            .db
            .query_row("SELECT data FROM notes WHERE id=?1", [id], |r| r.get(0))?;
        Ok(serde_json::from_str(&data)?)
    }
    pub fn put_note(&self, note: &crate::notes::Note) -> Result<()> {
        note.validate()?;
        self.save_note(&serde_json::to_value(note)?)
    }
    pub fn delete_note(&self, id: &str) -> Result<()> {
        self.db.execute("DELETE FROM notes WHERE id=?1", [id])?;
        Ok(())
    }
    pub fn patch_note(&self, id: &str, patch: &Value) -> Result<crate::notes::Note> {
        let mut note = self.note(id)?;
        note.apply_patch(patch)?;
        self.put_note(&note)?;
        Ok(note)
    }
    pub fn snapshot(&self) -> Result<Snapshot> {
        let mut q = self
            .db
            .prepare("SELECT data FROM dictations ORDER BY created_at")?;
        let records = q
            .query_map([], |r| r.get::<_, String>(0))?
            .map(|r| Ok(serde_json::from_str(&r?)?))
            .collect::<Result<Vec<_>>>()?;
        Ok(Snapshot {
            schema: 1,
            source: uuid::Uuid::new_v4().to_string(),
            settings: self.settings()?,
            dictations: records,
            notes: self.notes()?,
        })
    }
    /// Remove only managed audio through AudioStore. Legacy paths are never deleted.
    /// Pinned and corrected records are retained, matching the existing app.
    pub fn retain(&self, at: f64, audio: &crate::recordings::AudioStore) -> Result<()> {
        let mut q = self
            .db
            .prepare("SELECT data FROM dictations WHERE created_at<?1")?;
        let rows = q.query_map([at - 7. * 86400.], |r| r.get::<_, String>(0))?;
        let records = rows
            .map(|r| Ok(serde_json::from_str::<Dictation>(&r?)?))
            .collect::<Result<Vec<_>>>()?;
        drop(q);
        for mut record in records {
            if record.pinned || record.correction.as_ref().is_some_and(|c| !c.is_empty()) {
                continue;
            }
            audio.remove(&record.id)?;
            if record.created_at < at - 30. * 86400. {
                self.delete_dictation(&record.id)?;
            } else if record.legacy.get("managedAudio").is_some() {
                record
                    .legacy
                    .as_object_mut()
                    .unwrap()
                    .remove("managedAudio");
                self.update_dictation(&record)?;
            }
        }
        let mut query = self.db.prepare("SELECT id FROM dictations")?;
        let referenced = query
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<std::result::Result<std::collections::HashSet<_>, _>>()?;
        audio.prune_orphans(&referenced, at)?;
        Ok(())
    }
    pub fn import(&mut self, snapshot: &Snapshot) -> Result<bool> {
        if snapshot.schema != 1 || snapshot.source.is_empty() || !snapshot.settings.is_object() {
            return Err(Error::Message("Unsupported migration export".into()));
        }
        let tx = self.db.transaction()?;
        if tx
            .query_row(
                "SELECT 1 FROM imports WHERE source=?1",
                [&snapshot.source],
                |_| Ok(()),
            )
            .optional()?
            .is_some()
        {
            return Ok(false);
        }
        // Existing preview choices win, except blanks the preview seeded before
        // import; preserve all legacy fields, including ones this version cannot
        // expose. A future port may still need them.
        let settings: Option<String> = tx
            .query_row("SELECT value FROM metadata WHERE key='settings'", [], |r| {
                r.get(0)
            })
            .optional()?;
        let mut combined = snapshot.settings.clone();
        if let Some(settings) = settings {
            if let Some(existing) = serde_json::from_str::<Value>(&settings)?.as_object() {
                combined.as_object_mut().unwrap().extend(
                    existing
                        .iter()
                        .filter(|(_, v)| !v.is_null() && v.as_str() != Some(""))
                        .map(|(k, v)| (k.clone(), v.clone())),
                );
            }
        }
        tx.execute("INSERT INTO metadata VALUES ('settings',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [serde_json::to_string(&combined)?])?;
        for record in &snapshot.dictations {
            validate_record(record)?;
            tx.execute(
                "INSERT INTO dictations VALUES (?1,?2,?3) ON CONFLICT(id) DO NOTHING",
                params![record.id, record.created_at, serde_json::to_string(record)?],
            )?;
        }
        for note in &snapshot.notes {
            let id = note
                .get("id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .ok_or_else(|| Error::Message("Invalid meeting in export".into()))?;
            tx.execute(
                "INSERT OR IGNORE INTO notes VALUES (?1,?2)",
                params![id, serde_json::to_string(note)?],
            )?;
        }
        tx.execute(
            "INSERT INTO imports VALUES (?1,?2)",
            params![snapshot.source, now()],
        )?;
        tx.commit()?;
        Ok(true)
    }
}

fn validate_record(record: &Dictation) -> Result<()> {
    if record.id.is_empty()
        || !record.created_at.is_finite()
        || !record.duration.is_finite()
        || record.duration < 0.0
        || !record.latency.is_finite()
        || record.latency < 0.0
    {
        return Err(Error::Message("Invalid dictation record".into()));
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clear_all_includes_pins_corrections_and_rows_beyond_history_limit() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("core.db")).unwrap();
        let audio = crate::recordings::AudioStore::new(dir.path().join("recordings")).unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        audio.save(&id, &[0.1; 160]).unwrap();
        let record = Dictation {
            id: id.clone(),
            created_at: 1.,
            duration: 1.,
            model: "unknown-old-model".into(),
            raw: "raw".into(),
            text: "text".into(),
            correction: Some("corrected".into()),
            pinned: true,
            target: None,
            latency: 0.,
            legacy: serde_json::json!({"audioPath":"/source/original.wav"}),
        };
        store.add(&record).unwrap();
        // IDs are intentionally imported strings: clearing must never treat
        // them as filesystem paths, and cannot use the 10,000-row UI query.
        store.db.execute("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10001) INSERT INTO dictations SELECT '../original-'||x, x, ?1 FROM n", [serde_json::to_string(&record).unwrap()]).unwrap();
        store
            .save_settings(&serde_json::json!({"vocabulary":"Keep me"}))
            .unwrap();
        store
            .save_note(&serde_json::json!({"id":"note","body":"Keep notes"}))
            .unwrap();
        assert_eq!(store.clear_dictations(&audio).unwrap(), 10002);
        assert!(store.history(1).unwrap().is_empty());
        assert!(!audio.root().join(format!("{id}.wav")).exists());
        assert_eq!(store.settings().unwrap()["vocabulary"], "Keep me");
        assert_eq!(store.notes().unwrap().len(), 1);
        assert_eq!(store.clear_dictations(&audio).unwrap(), 0);
    }
    #[test]
    fn clear_reports_audio_cleanup_failure_after_atomic_history_delete() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("core.db")).unwrap();
        let audio = crate::recordings::AudioStore::new(dir.path().join("recordings")).unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        std::fs::create_dir(audio.root().join(format!("{id}.wav"))).unwrap();
        store
            .db
            .execute("INSERT INTO dictations VALUES (?1,1,'{}')", [&id])
            .unwrap();
        assert!(store
            .clear_dictations(&audio)
            .unwrap_err()
            .to_string()
            .contains("1 recording files"));
        assert!(store.history(1).unwrap().is_empty());
    }

    #[test]
    fn import_rolls_back_on_bad_note_and_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("core.db")).unwrap();
        let mut s = Snapshot {
            schema: 1,
            source: "mac-v1".into(),
            settings: serde_json::json!({"vocabulary":"custom", "asrModel":"orukeet"}),
            dictations: vec![],
            notes: vec![serde_json::json!({"bad": true})],
        };
        assert!(store.import(&s).is_err());
        assert_eq!(store.settings().unwrap(), serde_json::json!({}));
        store
            .save_settings(&serde_json::json!({"vocabulary":"", "asrModel":"moss"}))
            .unwrap();
        s.notes = vec![serde_json::json!({"id":"meeting1", "body":"original"})];
        assert!(store.import(&s).unwrap());
        assert!(!store.import(&s).unwrap());
        assert_eq!(store.notes().unwrap().len(), 1);
        assert_eq!(store.settings().unwrap()["vocabulary"], "custom");
        assert_eq!(store.settings().unwrap()["asrModel"], "moss");
        drop(store);
        assert_eq!(
            Store::open(&dir.path().join("core.db"))
                .unwrap()
                .notes()
                .unwrap()[0]["body"],
            "original"
        );
    }
}
