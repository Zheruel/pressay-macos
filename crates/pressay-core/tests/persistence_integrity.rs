use pressay_core::{
    catalog::{Artifact, Model},
    download,
    storage::{Dictation, Snapshot, Store},
    Error,
};
use serde_json::json;
use tokio_util::sync::CancellationToken;

fn model() -> Model {
    Model {
        id: "fixture".into(),
        name: "Fixture".into(),
        mac_only: false,
        artifacts: vec![Artifact {
            path: "weights.bin".into(),
            bytes: 7,
            sha256: "9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c".into(),
            // A valid cached model must not need a network connection.
            url: "https://offline.invalid/weights".into(),
        }],
    }
}

#[test]
fn cached_weights_require_both_pinned_length_and_digest() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("weights.bin");
    let artifact = &model().artifacts[0];
    assert!(!download::verified(&path, artifact).unwrap());
    std::fs::write(&path, b"weights").unwrap();
    assert!(download::verified(&path, artifact).unwrap());
    std::fs::write(&path, b"altered").unwrap();
    assert!(!download::verified(&path, artifact).unwrap());
    std::fs::write(&path, b"weight").unwrap();
    assert!(!download::verified(&path, artifact).unwrap());
}

#[tokio::test]
async fn ready_cached_weights_work_offline_and_cancellation_is_not_success() {
    let directory = tempfile::tempdir().unwrap();
    let model = model();
    std::fs::create_dir(directory.path().join(&model.id)).unwrap();
    let path = directory
        .path()
        .join(&model.id)
        .join(&model.artifacts[0].path);
    std::fs::write(&path, b"weights").unwrap();
    let cancel = CancellationToken::new();
    assert_eq!(
        download::prepare(directory.path(), &model, &cancel, |_| {})
            .await
            .unwrap(),
        path
    );
    let result = download::prepare(directory.path(), &model, &cancel, |_| cancel.cancel()).await;
    assert!(matches!(result, Err(Error::Cancelled)));
    assert_eq!(std::fs::read(&path).unwrap(), b"weights");
}

#[tokio::test]
async fn malformed_manifests_cannot_escape_the_cache_or_panic() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().join("cache");
    let cancel = CancellationToken::new();
    let mut cases = vec![];
    let mut empty = model();
    empty.artifacts.clear();
    cases.push(empty);
    let mut parent = model();
    parent.id = "../outside".into();
    cases.push(parent);
    for path in [
        "../outside",
        "/absolute",
        "C:\\escape",
        "extras/../../outside",
        "extras//weights",
    ] {
        let mut bad = model();
        bad.artifacts[0].path = path.into();
        cases.push(bad);
    }
    let mut duplicate = model();
    duplicate.artifacts.push(duplicate.artifacts[0].clone());
    cases.push(duplicate);
    let mut overflow = model();
    overflow.artifacts[0].bytes = u64::MAX;
    let mut extra = overflow.artifacts[0].clone();
    extra.path = "another.bin".into();
    overflow.artifacts.push(extra);
    cases.push(overflow);
    for model in cases {
        assert!(download::prepare(&root, &model, &cancel, |_| {})
            .await
            .is_err());
        assert!(!root.exists(), "invalid manifest caused filesystem changes");
    }
    cancel.cancel();
    assert!(matches!(
        download::prepare(&root, &model(), &cancel, |_| {}).await,
        Err(Error::Cancelled)
    ));
    assert!(!root.exists());
}

fn record(id: &str) -> Dictation {
    Dictation {
        id: id.into(),
        created_at: 1_700_000_000.0,
        duration: 3.0,
        model: "orukeet".into(),
        raw: "original".into(),
        text: "original".into(),
        correction: Some("corrected".into()),
        pinned: true,
        target: Some("editor".into()),
        latency: 0.25,
        legacy: json!({"audioPath":"legacy.caf", "futureField":{"keep":true}}),
    }
}

#[test]
fn additive_import_preserves_local_edits_and_all_legacy_fields_after_restart() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("core.db");
    let mut store = Store::open(&path).unwrap();
    store
        .save_settings(&json!({"vocabulary":"local words", "holdKey":"local"}))
        .unwrap();
    store.add(&record("existing")).unwrap();
    store
        .save_note(&json!({"id":"existing-note", "body":"local edits"}))
        .unwrap();
    let mut conflicting = record("existing");
    conflicting.text = "outdated import".into();
    let snapshot = Snapshot {
        schema: 1,
        source: "source-v1".into(),
        settings: json!({"vocabulary":"old words", "asrModel":"orukeet", "unknownSetting":42}),
        dictations: vec![conflicting, record("imported")],
        notes: vec![
            json!({"id":"existing-note", "body":"outdated import"}),
            json!({"id":"imported-note", "body":"original meeting", "speakers":["Alice"]}),
        ],
    };
    assert!(store.import(&snapshot).unwrap());
    assert!(!store.import(&snapshot).unwrap());
    drop(store);
    let store = Store::open(&path).unwrap();
    assert_eq!(
        store.settings().unwrap(),
        json!({"vocabulary":"local words", "holdKey":"local", "asrModel":"orukeet", "unknownSetting":42})
    );
    let history = store.history(10).unwrap();
    assert_eq!(history.len(), 2);
    assert!(history.iter().all(|record| record.text == "original"));
    assert_eq!(history[0].legacy["futureField"]["keep"], true);
    assert_eq!(history[0].correction.as_deref(), Some("corrected"));
    let notes = store.notes().unwrap();
    assert!(notes.iter().any(|note| note["body"] == "local edits"));
    assert!(notes
        .iter()
        .any(|note| note["speakers"] == json!(["Alice"])));
}

#[test]
fn unsupported_schema_is_rejected_without_modifying_the_database() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("future.db");
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute_batch("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO metadata VALUES ('schema','999'); CREATE TABLE future_data (value TEXT); INSERT INTO future_data VALUES ('keep');").unwrap();
    drop(db);
    let before = std::fs::read(&path).unwrap();
    assert!(Store::open(&path).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), before);
}

#[test]
fn invalid_record_cannot_poison_history_or_partially_commit_an_import() {
    let directory = tempfile::tempdir().unwrap();
    let mut store = Store::open(&directory.path().join("core.db")).unwrap();
    let mut invalid = record("invalid");
    invalid.duration = f64::NAN;
    assert!(store.add(&invalid).is_err());
    let snapshot = Snapshot {
        schema: 1,
        source: "rollback".into(),
        settings: json!({"unexpected":true}),
        dictations: vec![record("valid"), invalid],
        notes: vec![],
    };
    assert!(store.import(&snapshot).is_err());
    assert_eq!(store.settings().unwrap(), json!({}));
    assert!(store.history(10).unwrap().is_empty());
    assert!(store.save_note(&json!({"id":""})).is_err());
}
