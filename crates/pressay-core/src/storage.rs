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
        rows.map(|r| Ok(serde_json::from_str(&r?)?)).collect()
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
        // Existing preview choices win; preserve all legacy fields, including ones
        // this version cannot expose. A future port may still need them.
        let settings: Option<String> = tx
            .query_row("SELECT value FROM metadata WHERE key='settings'", [], |r| {
                r.get(0)
            })
            .optional()?;
        let mut combined = snapshot.settings.clone();
        if let Some(settings) = settings {
            if let Some(existing) = serde_json::from_str::<Value>(&settings)?.as_object() {
                combined.as_object_mut().unwrap().extend(existing.clone());
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
        s.notes = vec![serde_json::json!({"id":"meeting1", "body":"original"})];
        assert!(store.import(&s).unwrap());
        assert!(!store.import(&s).unwrap());
        assert_eq!(store.notes().unwrap().len(), 1);
        assert_eq!(store.settings().unwrap()["vocabulary"], "custom");
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
