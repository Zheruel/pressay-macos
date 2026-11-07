//! Native workspace commands. Renderer data never contains account credentials.
use crate::engine::{self, Shared};
use base64::Engine;
use pressay_core::{
    accounts::{Accounts, ApiProvider, Secret, SecretStore},
    ai::{
        notes::{AskInput, AskMeeting, Exchange, MeetingInput, NotesModel},
        AiService, CleanupConfig, Connection, Provider,
    },
    notes::{ActionItem, Note},
    recordings::AudioStore,
    storage::Store,
    vocabulary,
};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};
use tauri::{AppHandle, Manager, State};
use tokio_util::sync::CancellationToken;
struct NativeSecrets;
impl NativeSecrets {
    fn entry(key: &str) -> Result<keyring::Entry, String> {
        keyring::Entry::new("dev.localflow.pressay", key)
            .map_err(|_| "Credential store unavailable".into())
    }
}
impl SecretStore for NativeSecrets {
    fn get(&self, key: &str) -> Result<Option<Secret>, String> {
        match Self::entry(key)?.get_password() {
            Ok(s) => Ok(Some(Secret::new(s))),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(_) => Err("Credential store unavailable".into()),
        }
    }
    fn set(&self, key: &str, value: &Secret) -> Result<(), String> {
        Self::entry(key)?
            .set_password(value.expose())
            .map_err(|_| "Credential store unavailable".into())
    }
    fn delete(&self, key: &str) -> Result<(), String> {
        match Self::entry(key)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(_) => Err("Credential store unavailable".into()),
        }
    }
}
// This adapter is constructed only by the explicit import command. It never
// reads subscription files, and cannot modify the original application's vault.
#[cfg(target_os = "macos")]
struct LegacyMacSecrets;
#[cfg(target_os = "macos")]
impl SecretStore for LegacyMacSecrets {
    fn get(&self, key: &str) -> Result<Option<Secret>, String> {
        if !["claude-api-key", "openai-api-key"].contains(&key) {
            return Err("Unsupported legacy credential".into());
        }
        let entry = keyring::Entry::new("dev.localflow.app", key)
            .map_err(|_| "Existing Mac credential store unavailable".to_string())?;
        match entry.get_password() {
            Ok(value) => Ok(Some(Secret::new(value))),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(_) => Err("Existing Mac credential store unavailable".into()),
        }
    }
    fn set(&self, _: &str, _: &Secret) -> Result<(), String> {
        Err("Legacy credentials are read-only".into())
    }
    fn delete(&self, _: &str) -> Result<(), String> {
        Err("Legacy credentials are read-only".into())
    }
}
#[cfg(any(target_os = "macos", test))]
#[derive(Debug, serde::Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ApiKeyImportStatus {
    Imported,
    AlreadyConfigured,
    NotFound,
    Unavailable,
}
#[cfg(any(target_os = "macos", test))]
#[derive(Debug, serde::Serialize)]
pub struct ApiKeyImport {
    pub claude: ApiKeyImportStatus,
    pub openai: ApiKeyImportStatus,
}
#[cfg(any(target_os = "macos", test))]
fn import_missing_api_keys(
    accounts: &Accounts,
    legacy: &dyn SecretStore,
    cancel: &CancellationToken,
) -> Result<ApiKeyImport, String> {
    fn copy(
        accounts: &Accounts,
        legacy: &dyn SecretStore,
        provider: ApiProvider,
        key: &str,
        cancel: &CancellationToken,
    ) -> Result<ApiKeyImportStatus, String> {
        if cancel.is_cancelled() {
            return Err("Cancelled".into());
        }
        match accounts.api_key(provider) {
            Ok(Some(_)) => return Ok(ApiKeyImportStatus::AlreadyConfigured),
            Err(_) => return Ok(ApiKeyImportStatus::Unavailable),
            Ok(None) => {}
        }
        let value = match legacy.get(key) {
            Ok(Some(secret)) => secret,
            Ok(None) => return Ok(ApiKeyImportStatus::NotFound),
            Err(_) => return Ok(ApiKeyImportStatus::Unavailable),
        };
        if cancel.is_cancelled() {
            return Err("Cancelled".into());
        }
        if value.expose().trim().is_empty() {
            return Ok(ApiKeyImportStatus::NotFound);
        }
        // A legacy Keychain prompt can remain open while another application
        // sets a new key. Recheck immediately before the guarded native write.
        match accounts.api_key(provider) {
            Ok(Some(_)) => return Ok(ApiKeyImportStatus::AlreadyConfigured),
            Err(_) => return Ok(ApiKeyImportStatus::Unavailable),
            Ok(None) => {}
        }
        Ok(if accounts.set_api_key(provider, value.expose()).is_ok() {
            ApiKeyImportStatus::Imported
        } else {
            ApiKeyImportStatus::Unavailable
        })
    }
    Ok(ApiKeyImport {
        claude: copy(
            accounts,
            legacy,
            ApiProvider::Claude,
            "claude-api-key",
            cancel,
        )?,
        openai: copy(
            accounts,
            legacy,
            ApiProvider::OpenAi,
            "openai-api-key",
            cancel,
        )?,
    })
}
fn initialize_data_directory(data: &std::path::Path) -> Result<(), String> {
    std::fs::create_dir_all(data).map_err(|e| e.to_string())?;
    pressay_core::analysis::cleanup_stale_spools(data).map_err(|e| e.to_string())?;
    Ok(())
}
pub struct Workspace {
    pub store: Mutex<Store>,
    pub audio: AudioStore,
    pub ai: Arc<AiService>,
    pub data: PathBuf,
    pub jobs: Mutex<HashMap<String, CancellationToken>>,
    pub auth_cancel: Mutex<CancellationToken>,
    auth_busy: AtomicBool,
    shutting_down: AtomicBool,
    jobs_finished: tokio::sync::Notify,
    credential_changes: Arc<tokio::sync::Mutex<()>>,
}
impl Workspace {
    pub fn new(data: PathBuf) -> Result<Arc<Self>, String> {
        initialize_data_directory(&data)?;
        let store = Store::open(&data.join("pressay.sqlite3")).map_err(|e| e.to_string())?;
        let audio = AudioStore::new(data.join("Recordings")).map_err(|e| e.to_string())?;
        store
            .retain(pressay_core::storage::now(), &audio)
            .map_err(|e| e.to_string())?;
        let accounts = Arc::new(Accounts::new(Arc::new(NativeSecrets)).map_err(|e| e.to_string())?);
        Ok(Arc::new(Self {
            store: Mutex::new(store),
            audio,
            ai: Arc::new(AiService::new(accounts).map_err(|e| e.to_string())?),
            data,
            jobs: Mutex::new(HashMap::new()),
            auth_cancel: Mutex::new(CancellationToken::new()),
            auth_busy: AtomicBool::new(false),
            shutting_down: AtomicBool::new(false),
            jobs_finished: tokio::sync::Notify::new(),
            credential_changes: Arc::new(tokio::sync::Mutex::new(())),
        }))
    }
    pub fn refresh(&self, app: &AppHandle) -> Result<(), String> {
        let store = self.store.lock().unwrap();
        let notes = store.notes().map_err(|e| e.to_string())?;
        let history = store.history(10000).map_err(|e| e.to_string())?;
        engine::update(app, &app.state::<Arc<Shared>>(), |s| {
            s.notes = notes;
            s.history = history;
        });
        Ok(())
    }
    pub fn job_ids(&self) -> Vec<String> {
        let mut ids = self
            .jobs
            .lock()
            .unwrap()
            .keys()
            .filter(|id| !id.starts_with('$'))
            .cloned()
            .collect::<Vec<_>>();
        ids.sort();
        ids
    }
    pub async fn shutdown(&self) -> Result<(), String> {
        self.shutting_down.store(true, Ordering::Release);
        self.cancel_all();
        let jobs = async {
            loop {
                let notified = self.jobs_finished.notified();
                tokio::pin!(notified);
                notified.as_mut().enable();
                if self.jobs.lock().unwrap().is_empty() && !self.auth_busy.load(Ordering::Acquire) {
                    return;
                }
                notified.await;
            }
        };
        tokio::time::timeout(std::time::Duration::from_secs(70), async {
            tokio::join!(
                jobs,
                self.ai.shutdown(),
                crate::migration_audio::wait_for_jobs()
            );
        })
        .await
        .map_err(|_| "AI shutdown did not finish before its deadline".to_string())
    }
    pub fn cancel_note_jobs(&self) {
        for (id, token) in self.jobs.lock().unwrap().iter() {
            if !id.starts_with('$') {
                token.cancel();
            }
        }
    }
    pub fn cancel_all(&self) {
        for token in self.jobs.lock().unwrap().values() {
            token.cancel();
        }
        self.auth_cancel.lock().unwrap().cancel();
    }
}
fn pending_writeups(notes: Vec<Value>) -> Vec<String> {
    notes
        .into_iter()
        .filter_map(|value| serde_json::from_value::<Note>(value).ok())
        .filter(|note| {
            note.needs_write_up
                && !note.edited
                && !note.interrupted
                && note.kind == "meeting"
                && !note.lines.is_empty()
        })
        .map(|note| note.id)
        .collect()
}
/// Resume only explicitly pending, finished recordings. Old imported notes
/// without needsWriteUp remain untouched, and unavailable AI stays local.
pub fn resume_pending_writeups(app: AppHandle, state: Arc<Workspace>) {
    tauri::async_runtime::spawn(async move {
        let Ok(job) = NoteJob::start(&state, "$resume-writeups", &CancellationToken::new()) else {
            return;
        };
        let pending = {
            let store = state.store.lock().unwrap();
            store.settings().and_then(|settings| {
                if !settings["notesUseAI"].as_bool().unwrap_or(true) {
                    return Ok((settings, Vec::new()));
                }
                Ok((settings, pending_writeups(store.notes()?)))
            })
        };
        let Ok((settings, ids)) = pending else {
            return;
        };
        if ids.is_empty()
            || model_config(&settings, &state.ai, &job.token)
                .await
                .is_err()
        {
            return;
        }
        for id in ids {
            if job.token.is_cancelled() || app.state::<Arc<Shared>>().is_shutting_down() {
                break;
            }
            if let Err(error) = write_up_recording(&id, &app, &state, &job.token).await {
                if !job.token.is_cancelled() {
                    engine::update(&app, &app.state::<Arc<Shared>>(), |s| {
                        s.error = Some(format!("Saved transcript needs a write-up: {error}"))
                    });
                }
            }
        }
    });
}
#[tauri::command]
pub fn clear_history(
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
    shared: State<'_, Arc<Shared>>,
) -> Result<(), String> {
    if shared.view.lock().unwrap().stage != "idle" || shared.is_shutting_down() {
        return Err(
            "Finish your current recording or model preparation before clearing history".into(),
        );
    }
    let result = state
        .store
        .lock()
        .unwrap()
        .clear_dictations(&state.audio)
        .map_err(|e| e.to_string());
    let refreshed = state.refresh(&app);
    result.map(|_| ()).and(refreshed)
}
pub fn cleanup_config(settings: &Value) -> CleanupConfig {
    let provider = if settings["cleanupProvider"] == "chatgpt" {
        Provider::OpenAi
    } else {
        Provider::Claude
    };
    CleanupConfig {
        enabled: settings["claudeCleanup"].as_bool().unwrap_or(false),
        provider,
        connection: connection(settings, provider),
    }
}
fn connection(settings: &Value, provider: Provider) -> Connection {
    let key = if provider == Provider::Claude {
        "claudeConnection"
    } else {
        "openAIConnection"
    };
    match settings[key].as_str() {
        Some("subscription") => Connection::Subscription,
        Some("apiKey") => Connection::ApiKey,
        _ => {
            if provider == Provider::OpenAi {
                Connection::Subscription
            } else {
                Connection::ApiKey
            }
        }
    }
}
// Notes preserve the shipping app's separate provider contract: Claude API
// credits or ChatGPT plan usage, independently of the dictation connection.
async fn model_config(
    settings: &Value,
    ai: &AiService,
    cancel: &CancellationToken,
) -> Result<(NotesModel, Connection), String> {
    check_notes_enabled(settings)?;
    let claude = ai.accounts.api_key(ApiProvider::Claude);
    let chatgpt = tokio::select! { biased; _=cancel.cancelled()=>return Err("Cancelled".into()), status=ai.accounts.chatgpt.status()=>status };
    let model = resolve_model(
        settings,
        claude.as_ref().is_ok_and(|key| key.is_some()),
        chatgpt.signed_in,
    );
    if model.is_none() {
        if let Err(error) = claude {
            return Err(error.to_string());
        }
        if let Some(error) = chatgpt.error {
            return Err(error);
        }
    }
    let model = model
        .ok_or("Add a Claude API key or sign in with ChatGPT in AI Settings to write notes")?;
    let connection = if model.provider() == Provider::Claude {
        Connection::ApiKey
    } else {
        Connection::Subscription
    };
    Ok((model, connection))
}
fn resolve_model(settings: &Value, claude: bool, chatgpt: bool) -> Option<NotesModel> {
    NotesModel::resolve(
        settings["notesModel"].as_str(),
        settings["cleanupProvider"] == "chatgpt",
        claude,
        chatgpt,
    )
}
fn check_notes_enabled(settings: &Value) -> Result<(), String> {
    if settings["notesUseAI"].as_bool().unwrap_or(true) {
        Ok(())
    } else {
        Err("AI is turned off in Notetaker settings".into())
    }
}
pub(crate) struct NoteJob<'a> {
    state: &'a Workspace,
    id: String,
    pub(crate) token: CancellationToken,
}
fn register_job(
    state: &Workspace,
    id: &str,
    parent: &CancellationToken,
) -> Result<CancellationToken, String> {
    if parent.is_cancelled() {
        return Err("Cancelled".into());
    }
    let token = parent.child_token();
    let mut jobs = state.jobs.lock().unwrap();
    if state.shutting_down.load(Ordering::Acquire) {
        return Err("Pressay is shutting down".into());
    }
    if jobs.contains_key(id) {
        return Err("Wait for the current request or cancel it".into());
    }
    jobs.insert(id.into(), token.clone());
    Ok(token)
}
impl<'a> NoteJob<'a> {
    pub(crate) fn start(
        state: &'a Workspace,
        id: &str,
        parent: &CancellationToken,
    ) -> Result<Self, String> {
        let token = register_job(state, id, parent)?;
        Ok(Self {
            state,
            id: id.into(),
            token,
        })
    }
}
#[cfg(any(target_os = "macos", test))]
struct OwnedNoteJob {
    state: Arc<Workspace>,
    id: String,
    token: CancellationToken,
}
#[cfg(any(target_os = "macos", test))]
impl OwnedNoteJob {
    fn start(state: Arc<Workspace>, id: &str, parent: &CancellationToken) -> Result<Self, String> {
        let token = register_job(&state, id, parent)?;
        Ok(Self {
            state,
            id: id.into(),
            token,
        })
    }
}
#[cfg(any(target_os = "macos", test))]
impl Drop for OwnedNoteJob {
    fn drop(&mut self) {
        self.token.cancel();
        self.state.jobs.lock().unwrap().remove(&self.id);
        self.state.jobs_finished.notify_waiters();
    }
}
impl Drop for NoteJob<'_> {
    fn drop(&mut self) {
        self.token.cancel();
        self.state.jobs.lock().unwrap().remove(&self.id);
        self.state.jobs_finished.notify_waiters();
    }
}
fn check_ai_settings(
    current: &Value,
    expected: &Value,
    cancel: &CancellationToken,
) -> Result<(), String> {
    if cancel.is_cancelled() {
        return Err("Cancelled".into());
    }
    check_notes_enabled(current)?;
    for key in ["notesUseAI", "notesModel", "cleanupProvider", "vocabulary"] {
        if current[key] != expected[key] {
            return Err("AI settings changed; retry when ready".into());
        }
    }
    Ok(())
}
fn ensure_ai_current(
    state: &Workspace,
    expected: &Value,
    cancel: &CancellationToken,
) -> Result<(), String> {
    let current = state
        .store
        .lock()
        .unwrap()
        .settings()
        .map_err(|e| e.to_string())?;
    check_ai_settings(&current, expected, cancel)
}
fn same_note_input(current: &Note, expected: &Note) -> bool {
    current.title == expected.title
        && current.body == expected.body
        && current.edited == expected.edited
        && current.my_notes == expected.my_notes
        && current.participants == expected.participants
        && current.speaker_names == expected.speaker_names
        && current.duration == expected.duration
        && current.transcripts == expected.transcripts
        && serde_json::to_value(&current.lines).ok() == serde_json::to_value(&expected.lines).ok()
}
fn ensure_note_current(current: &Note, expected: &Note) -> Result<(), String> {
    if same_note_input(current, expected) {
        Ok(())
    } else {
        Err("Your note changed during write-up. Your edits were kept; retry when ready.".into())
    }
}
fn review_marker(note: &Note) -> Value {
    json!({"duration":note.duration,"lineCount":note.lines.len(),"lastStart":note.lines.last().map(|l|l.start),"lastEnd":note.lines.last().and_then(|l|l.end)})
}
fn merge_review(note: &mut Note, review: pressay_core::ai::review::ReviewResult) {
    let mut added = Vec::new();
    for (voice, name) in review.names {
        if voice == 0 || voice > 4 {
            continue;
        }
        let index = voice as usize - 1;
        if note.speaker_names.len() <= index {
            note.speaker_names.resize(index + 1, String::new());
        }
        if note.speaker_names[index].trim().is_empty() {
            note.speaker_names[index] = name.clone();
            added.push(name);
        }
    }
    added.sort();
    for name in added {
        if note.participants.len() < 100
            && !note
                .participants
                .iter()
                .any(|p| p.to_lowercase() == name.to_lowercase())
        {
            note.participants.push(name);
        }
    }
    for line in &mut note.lines {
        line.text = pressay_core::ai::review::apply_fixes(&line.text, &review.fixes);
    }
}
#[tauri::command]
pub fn edit_dictation(
    id: String,
    correction: Option<String>,
    pinned: Option<bool>,
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<(), String> {
    state
        .store
        .lock()
        .unwrap()
        .edit_dictation(&id, correction.as_deref(), pinned)
        .map_err(|e| e.to_string())?;
    state.refresh(&app)
}
#[tauri::command]
pub fn recording(id: String, state: State<'_, Arc<Workspace>>) -> Result<String, String> {
    let bytes = state
        .audio
        .read(&id)
        .map_err(|_| "This recording is no longer available".to_string())?;
    Ok(base64::engine::general_purpose::STANDARD.encode(bytes))
}
#[tauri::command]
pub fn edit_note(
    id: String,
    patch: Value,
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<(), String> {
    state
        .store
        .lock()
        .unwrap()
        .patch_note(&id, &patch)
        .map_err(|e| e.to_string())?;
    state.refresh(&app)
}
#[tauri::command]
pub fn delete_note(
    id: String,
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<(), String> {
    if app
        .state::<Arc<Shared>>()
        .view
        .lock()
        .unwrap()
        .active_note
        .as_deref()
        == Some(&id)
    {
        return Err("Stop recording before deleting this meeting".into());
    }
    if let Some(token) = state.jobs.lock().unwrap().get(&id) {
        token.cancel();
    }
    state
        .store
        .lock()
        .unwrap()
        .delete_note(&id)
        .map_err(|e| e.to_string())?;
    state.refresh(&app)
}
#[tauri::command]
pub fn toggle_action(
    id: String,
    item: ActionItem,
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<(), String> {
    let store = state.store.lock().unwrap();
    let mut note = store.note(&id).map_err(|e| e.to_string())?;
    note.body = item.toggle(&note.body).map_err(|e| e.to_string())?;
    note.updated_at = pressay_core::storage::now();
    store.put_note(&note).map_err(|e| e.to_string())?;
    drop(store);
    state.refresh(&app)
}
#[tauri::command]
pub fn cancel_note_job(id: String, state: State<'_, Arc<Workspace>>) {
    if let Some(token) = state.jobs.lock().unwrap().get(&id) {
        token.cancel();
    }
}
#[tauri::command]
pub async fn write_note(
    id: String,
    replace_edits: Option<bool>,
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<(), String> {
    if app
        .state::<Arc<Shared>>()
        .view
        .lock()
        .unwrap()
        .active_note
        .as_deref()
        == Some(id.as_str())
    {
        return Err("Stop recording before writing this meeting".into());
    }
    let result = write_up_inner(
        &id,
        &state,
        false,
        replace_edits.unwrap_or(false),
        &CancellationToken::new(),
    )
    .await;
    // Review corrections may be saved even if the later summary fails.
    let refreshed = state.refresh(&app);
    result.and(refreshed)
}
/// Meeting finalization calls this once after capture and ASR have closed.
/// A durable attempt marker prevents repeated review when finalization retries.
pub async fn write_up_recording(
    id: &str,
    app: &AppHandle,
    state: &Workspace,
    cancel: &CancellationToken,
) -> Result<(), String> {
    let result = write_up_inner(id, state, true, false, cancel).await;
    let refreshed = state.refresh(app);
    result.and(refreshed)
}
async fn write_up_inner(
    id: &str,
    state: &Workspace,
    after_recording: bool,
    replace_edits: bool,
    parent: &CancellationToken,
) -> Result<(), String> {
    let job = NoteJob::start(state, id, parent)?;
    let token = &job.token;
    let (mut note, settings) = {
        let store = state.store.lock().unwrap();
        (
            store.note(id).map_err(|e| e.to_string())?,
            store.settings().map_err(|e| e.to_string())?,
        )
    };
    if after_recording
        && (!settings["notesUseAI"].as_bool().unwrap_or(true)
            || !note.needs_write_up
            || note.interrupted
            || note.edited
            || note.kind != "meeting"
            || note.lines.is_empty())
    {
        return Ok(());
    }
    check_notes_enabled(&settings)?;
    if note.edited && !replace_edits {
        return Err(
            "This note has your edits. Confirm that you want to replace them before rewriting."
                .into(),
        );
    }
    if note.kind != "meeting" {
        return Err(
            "Voice notes keep their original transcript; choose a meeting to write notes".into(),
        );
    }
    if note.transcript().trim().is_empty() && note.my_notes.trim().is_empty() {
        return Err("Record a meeting or add your notes first".into());
    }
    let (model, connection) = match model_config(&settings, &state.ai, token).await {
        Ok(config) => config,
        // Optional automatic notes stay local when no provider is configured or
        // the vault is locked. A manual request still explains how to connect.
        Err(_) if after_recording => return Ok(()),
        Err(error) => return Err(error),
    };
    let vocab = vocabulary::parse(settings["vocabulary"].as_str().unwrap_or(""));
    if after_recording && !note.lines.is_empty() {
        let marker = review_marker(&note);
        if note.extra.get("pressayReviewAttempt") != Some(&marker) {
            ensure_ai_current(state, &settings, token)?;
            // Save before calling the provider: a failure/cancellation must not
            // cause a second review on a finalization retry or manual rewrite.
            {
                let store = state.store.lock().unwrap();
                check_ai_settings(
                    &store.settings().map_err(|e| e.to_string())?,
                    &settings,
                    token,
                )?;
                let mut current = store.note(id).map_err(|e| e.to_string())?;
                ensure_note_current(&current, &note)?;
                current.extra.insert("pressayReviewAttempt".into(), marker);
                store.put_note(&current).map_err(|e| e.to_string())?;
                note = current;
            }
            let input = pressay_core::ai::review::ReviewInput {
                transcript: note
                    .lines
                    .iter()
                    .map(|l| l.plain(&[]))
                    .collect::<Vec<_>>()
                    .join("\n"),
                lines: note
                    .lines
                    .iter()
                    .map(|l| pressay_core::ai::review::ReviewLine {
                        text: l.text.clone(),
                        voice: l.voice,
                    })
                    .collect(),
                participants: note.participants.clone(),
                duration_seconds: note.duration,
            };
            let review = state
                .ai
                .review_transcript(&input, &vocab, &model, connection, token)
                .await;
            ensure_ai_current(state, &settings, token)?;
            if let Ok(review) = review {
                let store = state.store.lock().unwrap();
                check_ai_settings(
                    &store.settings().map_err(|e| e.to_string())?,
                    &settings,
                    token,
                )?;
                let mut current = store.note(id).map_err(|e| e.to_string())?;
                ensure_note_current(&current, &note)?;
                merge_review(&mut current, review);
                store.put_note(&current).map_err(|e| e.to_string())?;
                note = current;
            }
        }
    }
    ensure_ai_current(state, &settings, token)?;
    {
        let store = state.store.lock().unwrap();
        ensure_note_current(&store.note(id).map_err(|e| e.to_string())?, &note)?;
    }
    let input = MeetingInput {
        duration_seconds: note.duration,
        transcript: note.transcript(),
        user_notes: note.my_notes.clone(),
        participants: note.participants.clone(),
        has_separated_voices: note.lines.iter().any(|l| l.voice.is_some()),
        line_count: note.lines.len(),
        has_others: note
            .lines
            .iter()
            .any(|l| l.speaker == pressay_core::notes::Speaker::Others),
    };
    let draft = state
        .ai
        .write_note(&input, &vocab, &model, connection, token)
        .await
        .map_err(|e| e.to_string())?;
    ensure_ai_current(state, &settings, token)?;
    let store = state.store.lock().unwrap();
    check_ai_settings(
        &store.settings().map_err(|e| e.to_string())?,
        &settings,
        token,
    )?;
    let mut current = store.note(id).map_err(|e| e.to_string())?;
    ensure_note_current(&current, &note)?;
    current
        .apply_write_up(draft.title, draft.body, &note.body)
        .map_err(|e| e.to_string())?;
    store.put_note(&current).map_err(|e| e.to_string())?;
    Ok(())
}
/// A date range named in the question ("yesterday", "last week", "on Monday",
/// "in October"), as local-time Unix seconds. The latest mention wins.
fn question_dates(text: &str, now: chrono::DateTime<chrono::Local>) -> Option<(f64, f64)> {
    use chrono::{Datelike, Duration, NaiveDate, TimeZone};
    let text = text.to_lowercase();
    let today = now.date_naive();
    let start_of = |d: NaiveDate| {
        chrono::Local
            .from_local_datetime(&d.and_hms_opt(0, 0, 0).unwrap())
            .earliest()
            .map(|t| t.timestamp() as f64)
            .unwrap_or(0.)
    };
    let span = |from: NaiveDate, days: i64| (start_of(from), start_of(from + Duration::days(days)));
    let monday = today - Duration::days(today.weekday().num_days_from_monday() as i64);
    let has = |phrase: &str| {
        text.match_indices(phrase).any(|(i, _)| {
            let before = text[..i].chars().last();
            let after = text[i + phrase.len()..].chars().next();
            !before.is_some_and(char::is_alphanumeric) && !after.is_some_and(char::is_alphanumeric)
        })
    };
    if has("today") || has("this morning") || has("this afternoon") {
        return Some(span(today, 1));
    }
    if has("yesterday") {
        return Some(span(today - Duration::days(1), 1));
    }
    if has("last week") || has("previous week") {
        return Some(span(monday - Duration::days(7), 7));
    }
    if has("this week") {
        return Some(span(monday, 7));
    }
    if has("last month") {
        let first = today.with_day(1).unwrap();
        let previous = (first - Duration::days(1)).with_day(1).unwrap();
        return Some((start_of(previous), start_of(first)));
    }
    if has("this month") {
        let first = today.with_day(1).unwrap();
        return Some((start_of(first), start_of(today + Duration::days(1))));
    }
    const DAYS: [&str; 7] = [
        "monday",
        "tuesday",
        "wednesday",
        "thursday",
        "friday",
        "saturday",
        "sunday",
    ];
    for (index, day) in DAYS.iter().enumerate() {
        if has(day) {
            let back = (today.weekday().num_days_from_monday() as i64 - index as i64).rem_euclid(7);
            return Some(span(today - Duration::days(back), 1));
        }
    }
    const MONTHS: [&str; 12] = [
        "january",
        "february",
        "march",
        "april",
        "may",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december",
    ];
    for (index, month) in MONTHS.iter().enumerate() {
        // "may" is too common a word to read as a month on its own.
        if (*month != "may" && has(month)) || has(&format!("in {month}")) {
            let number = index as u32 + 1;
            let year = if number > today.month() {
                today.year() - 1
            } else {
                today.year()
            };
            let first = NaiveDate::from_ymd_opt(year, number, 1)?;
            let next = if number == 12 {
                NaiveDate::from_ymd_opt(year + 1, 1, 1)?
            } else {
                NaiveDate::from_ymd_opt(year, number + 1, 1)?
            };
            return Some((start_of(first), start_of(next)));
        }
    }
    None
}
fn note_people(note: &Note) -> String {
    let mut people: Vec<String> = note.participants.clone();
    for name in &note.speaker_names {
        if !name.trim().is_empty() && !people.contains(name) {
            people.push(name.clone());
        }
    }
    people.join(", ")
}
/// Picks the meetings an all-meetings question should read: those in a date
/// range the question names, ranked by how many of its words they mention
/// (titles and names count most, then notes, then the transcript), newest
/// first on ties.
fn relevant_meetings(mut notes: Vec<Note>, question: &str, history: &[Exchange]) -> Vec<Note> {
    use pressay_core::ai::notes::{search_terms, term_hits};
    notes.retain(|n| {
        matches!(n.kind.as_str(), "meeting" | "voice")
            && (!n.transcript().trim().is_empty() || !n.body.trim().is_empty())
    });
    if let Some((from, to)) = question_dates(question, chrono::Local::now()) {
        let dated: Vec<Note> = notes
            .iter()
            .filter(|n| n.created_at >= from && n.created_at < to)
            .cloned()
            .collect();
        if !dated.is_empty() {
            notes = dated;
        }
    }
    let terms = search_terms(
        &std::iter::once(question)
            .chain(history.iter().map(|e| e.question.as_str()))
            .collect::<Vec<_>>()
            .join(" "),
    );
    let mut scored: Vec<(usize, Note)> = notes
        .into_iter()
        .map(|n| {
            let score = 3 * term_hits(&format!("{} {}", n.title, note_people(&n)), &terms)
                + 2 * term_hits(&format!("{} {}", n.body, n.my_notes), &terms)
                + term_hits(&n.transcript(), &terms);
            (score, n)
        })
        .collect();
    scored.sort_by(|(a, x), (b, y)| b.cmp(a).then_with(|| y.created_at.total_cmp(&x.created_at)));
    scored.truncate(25);
    scored.into_iter().map(|(_, n)| n).collect()
}
#[derive(serde::Serialize, Debug)]
pub struct AskSource {
    n: usize,
    id: String,
    title: String,
    created_at: f64,
}
#[derive(serde::Serialize, Debug)]
pub struct AskReply {
    text: String,
    sources: Vec<AskSource>,
}
/// The meetings an answer cites as [n], in the order it first cites them.
fn cited_sources(text: &str, notes: &[Note]) -> Vec<AskSource> {
    let mut seen = vec![];
    let mut rest = text;
    while let Some(open) = rest.find('[') {
        rest = &rest[open + 1..];
        let Some(close) = rest.find(']') else { break };
        for part in rest[..close].split(',') {
            if let Ok(n) = part.trim().parse::<usize>() {
                if n >= 1 && n <= notes.len() && !seen.contains(&n) {
                    seen.push(n);
                }
            }
        }
    }
    seen.into_iter()
        .map(|n| {
            let note = &notes[n - 1];
            AskSource {
                n,
                id: note.id.clone(),
                title: note.title.clone(),
                created_at: note.created_at,
            }
        })
        .collect()
}
#[tauri::command]
pub async fn ask_notes(
    question: String,
    ids: Vec<String>,
    history: Vec<Exchange>,
    state: State<'_, Arc<Workspace>>,
) -> Result<AskReply, String> {
    ask_inner(question, ids, history, &state).await
}
async fn ask_inner(
    question: String,
    ids: Vec<String>,
    history: Vec<Exchange>,
    state: &Workspace,
) -> Result<AskReply, String> {
    if question.trim().is_empty() {
        return Err("Enter a question".into());
    }
    if question.len() > 10000
        || ids.len() > 100
        || history.len() > 20
        || history
            .iter()
            .any(|e| e.question.len() > 10000 || e.answer.len() > 100000)
    {
        return Err("This question is too large".into());
    }
    let job = NoteJob::start(state, "ask", &CancellationToken::new())?;
    let token = &job.token;
    let (notes, settings) = {
        let store = state.store.lock().unwrap();
        let notes = if ids.is_empty() {
            relevant_meetings(
                store
                    .notes()
                    .map_err(|e| e.to_string())?
                    .into_iter()
                    .map(serde_json::from_value::<Note>)
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| e.to_string())?,
                &question,
                &history,
            )
        } else {
            let mut seen = std::collections::HashSet::new();
            ids.into_iter()
                .filter(|id| seen.insert(id.clone()))
                .map(|id| store.note(&id).map_err(|e| e.to_string()))
                .collect::<Result<Vec<_>, _>>()?
        };
        (notes, store.settings().map_err(|e| e.to_string())?)
    };
    check_notes_enabled(&settings)?;
    if notes.is_empty() {
        return Ok(AskReply {
            text: "There are no meetings to search yet.".into(),
            sources: vec![],
        });
    }
    let (model, connection) = model_config(&settings, &state.ai, token).await?;
    ensure_ai_current(state, &settings, token)?;
    let meetings = notes
        .iter()
        .map(|n| {
            let date = chrono::DateTime::from_timestamp(n.created_at as i64, 0)
                .unwrap_or_default()
                .with_timezone(&chrono::Local);
            AskMeeting {
                title: n.title.clone(),
                date: date.format("%Y-%m-%d").to_string(),
                time: date.format("%H:%M").to_string(),
                people: note_people(n),
                notes: n.body.clone(),
                my_notes: n.my_notes.clone(),
                transcript: n.transcript(),
            }
        })
        .collect();
    let input = AskInput {
        question,
        meetings,
        history,
        today: chrono::Local::now().format("%Y-%m-%d (%A)").to_string(),
    };
    let answer = state
        .ai
        .ask(&input, &model, connection, token)
        .await
        .map_err(|e| e.to_string())?;
    ensure_ai_current(state, &settings, token)?;
    // A deleted meeting must not reappear through a late answer.
    {
        let store = state.store.lock().unwrap();
        for note in &notes {
            store
                .note(&note.id)
                .map_err(|_| "A meeting in this question was deleted".to_string())?;
        }
    }
    let sources = cited_sources(&answer.text, &notes);
    Ok(AskReply {
        text: answer.text,
        sources,
    })
}
#[tauri::command]
pub async fn account_status(state: State<'_, Arc<Workspace>>) -> Result<Value, String> {
    let job = NoteJob::start(&state, "$account-status", &CancellationToken::new())?;
    let accounts = &state.ai.accounts;
    let claude = accounts.api_key(ApiProvider::Claude);
    let openai = accounts.api_key(ApiProvider::OpenAi);
    let (chatgpt, cli) = tokio::select! {biased;_=job.token.cancelled()=>return Err("Cancelled".into()),result=async{tokio::join!(accounts.chatgpt.status(),state.ai.claude_code.auth_status(&job.token))}=>result};
    let vault_error = claude
        .as_ref()
        .err()
        .or_else(|| openai.as_ref().err())
        .map(ToString::to_string);
    Ok(
        json!({"claudeApiKey":claude.as_ref().is_ok_and(|k|k.is_some()),"openaiApiKey":openai.as_ref().is_ok_and(|k|k.is_some()),"chatgpt":chatgpt,"claudeCode":cli.as_ref().ok(),"claudeCodeError":cli.err().map(|e|e.to_string()),"error":vault_error}),
    )
}
#[tauri::command]
pub fn open_claude_install() -> Result<(), String> {
    open::that("https://code.claude.com/docs/en/overview")
        .map_err(|_| "Could not open the Claude Code installation guide".into())
}
/// Verify only the saved credential, using a fixed sentence rather than user data.
#[tauri::command]
pub async fn verify_api_key(
    provider: String,
    state: State<'_, Arc<Workspace>>,
) -> Result<(), String> {
    verify_saved_api_key(&provider, state.inner()).await
}
async fn verify_saved_api_key(provider: &str, state: &Arc<Workspace>) -> Result<(), String> {
    use pressay_core::ai::{
        prompts, CLAUDE_DICTATION_EFFORT, CLAUDE_DICTATION_MODEL, OPENAI_DICTATION_EFFORT,
        OPENAI_DICTATION_MODEL,
    };
    let provider = match provider {
        "claude" => ApiProvider::Claude,
        "openai" => ApiProvider::OpenAi,
        _ => return Err("Unknown provider".into()),
    };
    let job = NoteJob::start(state, "$verify-api-key", &CancellationToken::new())?;
    let key = state
        .ai
        .accounts
        .api_key(provider)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Add an API key first".to_string())?;
    let system = prompts::cleanup_system(&[]);
    let user = prompts::cleanup_user(
        "Please run all the tests and tell me which ones failed, but do not deploy anything yet.",
        None,
    );
    let result = match provider {
        ApiProvider::Claude => {
            state
                .ai
                .http
                .claude(
                    &system,
                    &user,
                    CLAUDE_DICTATION_MODEL,
                    CLAUDE_DICTATION_EFFORT,
                    4000,
                    &key,
                    std::time::Duration::from_secs(12),
                    &job.token,
                )
                .await
        }
        ApiProvider::OpenAi => {
            state
                .ai
                .http
                .openai(
                    &system,
                    &user,
                    OPENAI_DICTATION_MODEL,
                    OPENAI_DICTATION_EFFORT,
                    false,
                    &key,
                    std::time::Duration::from_secs(15),
                    &job.token,
                )
                .await
        }
    };
    result.map(|_| ()).map_err(|e| e.to_string())
}
fn cancel_account_work(app: &AppHandle, state: &Workspace) {
    state.cancel_note_jobs();
    let shared = app.state::<Arc<Shared>>();
    let processing =
        ["processing", "polishing"].contains(&shared.view.lock().unwrap().stage.as_str());
    if processing {
        shared.cancel();
    }
}
#[tauri::command]
pub async fn save_api_key(
    provider: String,
    key: String,
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<(), String> {
    let job = NoteJob::start(&state, "$save-key", &CancellationToken::new())?;
    let provider = match provider.as_str() {
        "claude" => ApiProvider::Claude,
        "chatgpt" => ApiProvider::OpenAi,
        _ => return Err("Unknown provider".into()),
    };
    let _changes = tokio::select! {biased;_=job.token.cancelled()=>return Err("Cancelled".into()),guard=state.credential_changes.lock()=>guard};
    cancel_account_work(&app, &state);
    let result = state
        .ai
        .accounts
        .set_api_key(provider, &key)
        .map_err(|e| e.to_string());
    state.ai.http.invalidate().await;
    result
}
/// Explicit user action only. macOS may ask the user to allow Keychain access.
#[tauri::command]
pub async fn import_mac_api_keys(
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<Value, String> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, state);
        Err("Existing Mac API keys can only be imported on macOS".into())
    }
    #[cfg(target_os = "macos")]
    {
        let job = NoteJob::start(&state, "$import-mac-api-keys", &CancellationToken::new())?;
        let changes = tokio::select! {biased;_=job.token.cancelled()=>return Err("Cancelled".into()),guard=state.credential_changes.clone().lock_owned()=>guard};
        let accounts = state.ai.accounts.clone();
        let worker = OwnedNoteJob::start(
            state.inner().clone(),
            "$import-mac-api-keys-worker",
            &job.token,
        )?;
        let result = tokio::task::spawn_blocking(move || {
            let _changes = changes;
            import_missing_api_keys(&accounts, &LegacyMacSecrets, &worker.token)
        })
        .await
        .map_err(|_| "Could not import existing Mac API keys".to_string())??;
        if result.claude == ApiKeyImportStatus::Imported
            || result.openai == ApiKeyImportStatus::Imported
        {
            cancel_account_work(&app, &state);
            state.ai.http.invalidate().await;
        }
        serde_json::to_value(result).map_err(|_| "Could not report imported API keys".to_string())
    }
}
struct AuthJob<'a> {
    state: &'a Workspace,
    token: CancellationToken,
}
impl<'a> AuthJob<'a> {
    fn start(state: &'a Workspace) -> Result<Self, String> {
        let mut old = state.auth_cancel.lock().unwrap();
        if state.shutting_down.load(Ordering::Acquire) {
            return Err("Pressay is shutting down".into());
        }
        if state
            .auth_busy
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err("A sign-in is already in progress".into());
        }
        let token = CancellationToken::new();
        old.cancel();
        *old = token.clone();
        Ok(Self { state, token })
    }
}
impl Drop for AuthJob<'_> {
    fn drop(&mut self) {
        self.token.cancel();
        self.state.auth_busy.store(false, Ordering::Release);
        self.state.jobs_finished.notify_waiters();
    }
}
#[tauri::command]
pub async fn chatgpt_sign_in(
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<(), String> {
    let job = AuthJob::start(&state)?;
    state
        .ai
        .accounts
        .chatgpt
        .sign_in(
            |url| open::that(url).map_err(|_| "Could not open browser".into()),
            &job.token,
        )
        .await
        .map_err(|e| e.to_string())?;
    cancel_account_work(&app, &state);
    state.ai.http.invalidate().await;
    Ok(())
}
#[tauri::command]
pub fn cancel_sign_in(state: State<'_, Arc<Workspace>>) {
    state.auth_cancel.lock().unwrap().cancel();
}
#[tauri::command]
pub async fn claude_sign_in(
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<(), String> {
    let job = AuthJob::start(&state)?;
    state
        .ai
        .claude_code
        .sign_in(&job.token)
        .await
        .map_err(|e| e.to_string())?;
    cancel_account_work(&app, &state);
    Ok(())
}
#[tauri::command]
pub async fn chatgpt_sign_out(
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<(), String> {
    let _job = NoteJob::start(&state, "$sign-out", &CancellationToken::new())?;
    state.auth_cancel.lock().unwrap().cancel();
    cancel_account_work(&app, &state);
    let (result, ()) = tokio::join!(
        state.ai.accounts.chatgpt.sign_out(),
        state.ai.http.invalidate()
    );
    result.map(|_| ()).map_err(|e| e.to_string())
}
#[tauri::command]
pub async fn export_data(
    kind: String,
    id: Option<String>,
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<bool, String> {
    use tauri_plugin_dialog::DialogExt;
    let (name, content) = match kind.as_str() {
        "backup" => (
            "Pressay backup.json".to_string(),
            serde_json::to_string_pretty(
                &state
                    .store
                    .lock()
                    .unwrap()
                    .snapshot()
                    .map_err(|e| e.to_string())?,
            )
            .map_err(|e| e.to_string())?,
        ),
        "note" | "tasks" => {
            let n = state
                .store
                .lock()
                .unwrap()
                .note(id.as_deref().ok_or("Choose a note")?)
                .map_err(|e| e.to_string())?;
            if kind == "tasks" {
                let items = ActionItem::parse(&n.body)
                    .into_iter()
                    .filter(|a| a.is_mine() && !a.done && !a.was_sent(&n.sent_to_reminders))
                    .collect::<Vec<_>>();
                if items.is_empty() {
                    return Err("No unsent open action items assigned to you".into());
                }
                (
                    "Pressay tasks.ics".into(),
                    pressay_core::notes::calendar_tasks(&n, &items),
                )
            } else {
                (
                    "Pressay note.md".into(),
                    format!(
                        "# {}\n\n{}\n\n## My notes\n\n{}\n\n## Transcript\n\n{}\n",
                        n.title,
                        n.body,
                        n.my_notes,
                        n.transcript()
                    ),
                )
            }
        }
        _ => return Err("Unknown export format".into()),
    };
    let file = tokio::task::spawn_blocking(move || {
        app.dialog()
            .file()
            .set_file_name(&name)
            .blocking_save_file()
    })
    .await
    .map_err(|e| e.to_string())?;
    let Some(file) = file else { return Ok(false) };
    let path = file.into_path().map_err(|e| e.to_string())?;
    // Refuse to overwrite the live database or private recordings with an export.
    let parent = path
        .parent()
        .ok_or("Invalid destination")?
        .canonicalize()
        .map_err(|e| e.to_string())?;
    if parent.starts_with(state.data.canonicalize().map_err(|e| e.to_string())?) {
        return Err("Choose a location outside Pressay's private data folder".into());
    }
    #[cfg(target_os = "macos")]
    if let Some(home) = std::env::var_os("HOME") {
        let original = PathBuf::from(home).join("Library/Application Support/Pressay");
        if original
            .canonicalize()
            .is_ok_and(|root| parent.starts_with(root))
        {
            return Err("Choose a location outside the original app's data folder".into());
        }
    }
    use std::io::Write;
    let mut temporary = tempfile::NamedTempFile::new_in(&parent).map_err(|e| e.to_string())?;
    temporary
        .write_all(content.as_bytes())
        .map_err(|e| e.to_string())?;
    temporary.as_file().sync_all().map_err(|e| e.to_string())?;
    temporary.persist(path).map_err(|e| e.to_string())?;
    Ok(true)
}

/// History supplies only an ID; saved text and application are loaded natively.
#[tauri::command]
pub async fn retry_dictation(
    id: String,
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<String, String> {
    if app.state::<Arc<Shared>>().view.lock().unwrap().stage != "idle" {
        return Err("Finish the current recording before using Paste Again".into());
    }
    let workspace = state.inner().clone();
    tokio::task::spawn_blocking(move || {
        let job = NoteJob::start(&workspace, "$retry-dictation", &CancellationToken::new())?;
        let record = workspace
            .store
            .lock()
            .unwrap()
            .dictation(&id)
            .map_err(|e| e.to_string())?;
        let text = record
            .correction
            .as_deref()
            .filter(|text| !text.is_empty())
            .unwrap_or(&record.text);
        if text.trim().is_empty() {
            return Err("This dictation has no text to paste".into());
        }
        match crate::platform::retry_insertion(text, record.target.as_deref(), &job.token) {
            Ok(()) => Ok("Inserted into the original application".into()),
            Err(error) => {
                if job.token.is_cancelled() {
                    return Err("Paste Again cancelled".into());
                }
                crate::copy_text(text.to_owned())?;
                Ok(format!(
                    "Copied instead. {error}. Paste the text where you want it."
                ))
            }
        }
    })
    .await
    .map_err(|_| "Paste Again could not finish".to_string())?
}

#[tauri::command]
pub async fn export_reminders(
    id: String,
    app: AppHandle,
    state: State<'_, Arc<Workspace>>,
) -> Result<usize, String> {
    let note = state
        .store
        .lock()
        .unwrap()
        .note(&id)
        .map_err(|e| e.to_string())?;
    let items = ActionItem::parse(&note.body)
        .into_iter()
        .filter(|a| a.is_mine() && !a.done && !a.was_sent(&note.sent_to_reminders))
        .map(|a| a.text)
        .collect::<Vec<_>>();
    if items.is_empty() {
        return Err("No unsent open action items assigned to you".into());
    }
    let export = items.clone();
    let title = note.title.clone();
    tokio::task::spawn_blocking(move || crate::platform::export_reminders(&title, &export))
        .await
        .map_err(|e| e.to_string())??;
    let count = items.len();
    let store = state.store.lock().unwrap();
    let mut latest = store.note(&id).map_err(|e| e.to_string())?;
    latest.sent_to_reminders.extend(items);
    store.put_note(&latest).map_err(|e| e.to_string())?;
    drop(store);
    state.refresh(&app)?;
    Ok(count)
}

#[cfg(test)]
mod ai_tests {
    use super::*;
    use pressay_core::{
        ai::{
            claude_code::ClaudeCodeClient,
            review::{Fix, ReviewResult},
            Endpoints, HttpAi,
        },
        notes::{Speaker, TranscriptLine},
    };
    use std::time::Duration;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    #[derive(Default)]
    struct MemorySecrets(Mutex<HashMap<String, Secret>>);
    impl SecretStore for MemorySecrets {
        fn get(&self, k: &str) -> Result<Option<Secret>, String> {
            Ok(self.0.lock().unwrap().get(k).cloned())
        }
        fn set(&self, k: &str, v: &Secret) -> Result<(), String> {
            self.0.lock().unwrap().insert(k.into(), v.clone());
            Ok(())
        }
        fn delete(&self, k: &str) -> Result<(), String> {
            self.0.lock().unwrap().remove(k);
            Ok(())
        }
    }
    #[test]
    fn startup_writeups_require_explicit_pending_complete_unedited_meeting() {
        let mut pending = Note::new("meeting");
        pending
            .add_line(pressay_core::notes::TranscriptLine {
                speaker: pressay_core::notes::Speaker::Me,
                start: 0.,
                end: Some(1.),
                text: "Hello".into(),
                voice: None,
            })
            .unwrap();
        let mut old = serde_json::to_value(&pending).unwrap();
        old.as_object_mut().unwrap().remove("needsWriteUp");
        let mut interrupted = pending.clone();
        interrupted.interrupted = true;
        let mut edited = pending.clone();
        edited.edited = true;
        let mut voice = pending.clone();
        voice.kind = "voice".into();
        let mut done = pending.clone();
        done.needs_write_up = false;
        let values = vec![
            old,
            serde_json::to_value(&interrupted).unwrap(),
            serde_json::to_value(&edited).unwrap(),
            serde_json::to_value(&voice).unwrap(),
            serde_json::to_value(&done).unwrap(),
            serde_json::to_value(&pending).unwrap(),
        ];
        assert_eq!(pending_writeups(values), vec![pending.id]);
    }
    struct Fixture {
        workspace: Arc<Workspace>,
        requests: Arc<Mutex<Vec<Value>>>,
        server: tokio::task::JoinHandle<()>,
        directory: PathBuf,
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            self.server.abort();
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }
    impl Fixture {
        async fn new(delay: Duration) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let url = format!("http://{}", listener.local_addr().unwrap());
            let requests = Arc::new(Mutex::new(vec![]));
            let captured = requests.clone();
            let server = tokio::spawn(async move {
                loop {
                    let Ok((mut socket, _)) = listener.accept().await else {
                        return;
                    };
                    let captured = captured.clone();
                    tokio::spawn(async move {
                        let mut bytes = Vec::new();
                        let mut buffer = [0; 4096];
                        let start = loop {
                            let n = socket.read(&mut buffer).await.unwrap_or(0);
                            if n == 0 {
                                return;
                            }
                            bytes.extend_from_slice(&buffer[..n]);
                            if let Some(i) = bytes.windows(4).position(|p| p == b"\r\n\r\n") {
                                break i + 4;
                            }
                        };
                        let headers = String::from_utf8(bytes[..start].to_vec()).unwrap();
                        let count = headers
                            .lines()
                            .find_map(|l| {
                                l.to_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|s| s.trim().parse::<usize>().unwrap())
                            })
                            .unwrap();
                        while bytes.len() < start + count {
                            let n = socket.read(&mut buffer).await.unwrap_or(0);
                            if n == 0 {
                                return;
                            }
                            bytes.extend_from_slice(&buffer[..n]);
                        }
                        let request: Value =
                            serde_json::from_slice(&bytes[start..start + count]).unwrap();
                        let system = request["system"][0]["text"].as_str().unwrap();
                        let response = if system.starts_with("You review a meeting transcript") {
                            r#"{"speakers":{},"fixes":[{"from":"Kubernetis","to":"Kubernetes"}]}"#
                        } else if system.starts_with("You are the user's meeting assistant") {
                            "Ana owns the project."
                        } else {
                            "Project plan\n\n- [ ] Deploy Kubernetes (Me)"
                        };
                        let response=json!({"stop_reason":"end_turn","content":[{"type":"text","text":response}]}).to_string();
                        captured.lock().unwrap().push(request);
                        tokio::time::sleep(delay).await;
                        let header=format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",response.len());
                        let _ = socket.write_all(header.as_bytes()).await;
                        let _ = socket.write_all(response.as_bytes()).await;
                    });
                }
            });
            let directory =
                std::env::temp_dir().join(format!("pressay-ai-fixture-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(&directory).unwrap();
            let store = Store::open(&directory.join("notes.sqlite3")).unwrap();
            store.save_settings(&json!({"notesUseAI":true,"notesModel":"","cleanupProvider":"claude","claudeConnection":"subscription"})).unwrap();
            let secrets = Arc::new(MemorySecrets::default());
            secrets
                .set("claude-api-key", &Secret::new("fixture-only-key".into()))
                .unwrap();
            let accounts = Arc::new(Accounts::new(secrets).unwrap());
            let endpoints = Endpoints {
                anthropic: format!("{url}/messages").parse().unwrap(),
                openai: format!("{url}/responses").parse().unwrap(),
                websocket: url.replacen("http:", "ws:", 1).parse().unwrap(),
            };
            let ai = Arc::new(AiService {
                accounts,
                http: HttpAi::with_endpoints(endpoints).unwrap(),
                claude_code: ClaudeCodeClient::unavailable(),
            });
            let workspace = Arc::new(Workspace {
                store: Mutex::new(store),
                audio: AudioStore::new(directory.join("Recordings")).unwrap(),
                ai,
                data: directory.clone(),
                jobs: Mutex::new(HashMap::new()),
                auth_cancel: Mutex::new(CancellationToken::new()),
                auth_busy: AtomicBool::new(false),
                shutting_down: AtomicBool::new(false),
                jobs_finished: tokio::sync::Notify::new(),
                credential_changes: Arc::new(tokio::sync::Mutex::new(())),
            });
            Self {
                workspace,
                requests,
                server,
                directory,
            }
        }
        fn note(&self) -> String {
            let mut note = Note::new("meeting");
            note.duration = 60.;
            note.add_line(TranscriptLine {
                speaker: Speaker::Me,
                start: 0.,
                end: Some(4.),
                text: "Deploy Kubernetis tomorrow.".into(),
                voice: None,
            })
            .unwrap();
            self.workspace
                .store
                .lock()
                .unwrap()
                .put_note(&note)
                .unwrap();
            note.id
        }
        async fn wait_requests(&self, n: usize) {
            tokio::time::timeout(Duration::from_secs(3), async {
                while self.requests.lock().unwrap().len() < n {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            })
            .await
            .unwrap();
        }
    }
    #[tokio::test]
    async fn key_verification_uses_only_a_fixed_sentence_and_rejects_missing_credentials() {
        let fixture = Fixture::new(Duration::ZERO).await;
        let id = fixture.note();
        assert_eq!(
            verify_saved_api_key("unknown", &fixture.workspace).await,
            Err("Unknown provider".into())
        );
        assert_eq!(
            verify_saved_api_key("openai", &fixture.workspace).await,
            Err("Add an API key first".into())
        );
        assert!(fixture.requests.lock().unwrap().is_empty());
        verify_saved_api_key("claude", &fixture.workspace)
            .await
            .unwrap();
        let requests = fixture.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0]["model"], "claude-haiku-5-5");
        let request = requests[0].to_string();
        assert!(request.contains("Please run all the tests"));
        assert!(!request.contains("Kubernetis"));
        assert!(!request.contains(&id));
        assert!(fixture.workspace.jobs.lock().unwrap().is_empty());
    }
    #[tokio::test]
    async fn key_verification_is_cancelled_and_releases_its_shutdown_job() {
        let fixture = Fixture::new(Duration::from_secs(30)).await;
        let workspace = fixture.workspace.clone();
        let task = tokio::spawn(async move { verify_saved_api_key("claude", &workspace).await });
        fixture.wait_requests(1).await;
        fixture.workspace.cancel_all();
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), task)
                .await
                .unwrap()
                .unwrap(),
            Err("Cancelled".into())
        );
        assert!(fixture.workspace.jobs.lock().unwrap().is_empty());
    }
    #[test]
    fn provider_selection_follows_available_notes_connections_and_source_defaults() {
        let settings = json!({"notesModel":"claude:sonnet55","cleanupProvider":"claude"});
        assert_eq!(
            resolve_model(&settings, false, true),
            Some(NotesModel::OpenAi("gpt-6.1-sol".into()))
        );
        assert_eq!(
            resolve_model(&settings, true, true),
            Some(NotesModel::ClaudeSonnet)
        );
        assert!(resolve_model(&settings, false, false).is_none());
        assert_eq!(
            resolve_model(
                &json!({"notesModel":"","cleanupProvider":"chatgpt"}),
                true,
                false
            ),
            Some(NotesModel::ClaudeHaiku)
        );
        assert_eq!(
            connection(&json!({}), Provider::OpenAi),
            Connection::Subscription
        );
        assert_eq!(connection(&json!({}), Provider::Claude), Connection::ApiKey);
    }
    #[tokio::test]
    async fn recording_reviews_once_without_diarization_and_manual_rewrites_never_review() {
        let fixture = Fixture::new(Duration::ZERO).await;
        let id = fixture.note();
        let cancel = CancellationToken::new();
        write_up_inner(&id, &fixture.workspace, true, false, &cancel)
            .await
            .unwrap();
        assert_eq!(fixture.requests.lock().unwrap().len(), 2);
        let note = fixture.workspace.store.lock().unwrap().note(&id).unwrap();
        assert_eq!(note.lines[0].text, "Deploy Kubernetes tomorrow.");
        assert!(note.extra.contains_key("pressayReviewAttempt"));
        assert_eq!(note.title, "Project plan");
        write_up_inner(&id, &fixture.workspace, true, false, &cancel)
            .await
            .unwrap();
        write_up_inner(&id, &fixture.workspace, false, false, &cancel)
            .await
            .unwrap();
        let requests = fixture.requests.lock().unwrap();
        // A completed automatic write-up is not repeated on startup/retry;
        // the explicit manual rewrite still sends one new request.
        assert_eq!(requests.len(), 3);
        assert_eq!(
            requests
                .iter()
                .filter(|r| r["system"][0]["text"]
                    .as_str()
                    .unwrap()
                    .starts_with("You review a meeting transcript"))
                .count(),
            1
        );
        assert!(fixture.workspace.jobs.lock().unwrap().is_empty());
    }
    #[tokio::test]
    async fn automatic_write_up_skips_hand_edits_and_disabled_ai() {
        let fixture = Fixture::new(Duration::ZERO).await;
        let id = fixture.note();
        fixture
            .workspace
            .store
            .lock()
            .unwrap()
            .patch_note(&id, &json!({"body":"My own words"}))
            .unwrap();
        write_up_inner(
            &id,
            &fixture.workspace,
            true,
            false,
            &CancellationToken::new(),
        )
        .await
        .unwrap();
        assert!(write_up_inner(
            &id,
            &fixture.workspace,
            false,
            false,
            &CancellationToken::new()
        )
        .await
        .unwrap_err()
        .contains("Confirm"));
        assert!(fixture.requests.lock().unwrap().is_empty());
        write_up_inner(
            &id,
            &fixture.workspace,
            false,
            true,
            &CancellationToken::new(),
        )
        .await
        .unwrap();
        assert_eq!(fixture.requests.lock().unwrap().len(), 1);
        fixture
            .workspace
            .store
            .lock()
            .unwrap()
            .save_settings(&json!({"notesUseAI":false}))
            .unwrap();
        assert!(ask_inner(
            "Who owns this?".into(),
            vec![id.clone()],
            vec![],
            &fixture.workspace
        )
        .await
        .unwrap_err()
        .contains("turned off"));
        write_up_inner(
            &id,
            &fixture.workspace,
            true,
            false,
            &CancellationToken::new(),
        )
        .await
        .unwrap();
        assert_eq!(fixture.requests.lock().unwrap().len(), 1);
    }
    #[tokio::test]
    async fn automatic_notes_without_a_configured_provider_stay_local() {
        let fixture = Fixture::new(Duration::ZERO).await;
        let id = fixture.note();
        fixture
            .workspace
            .ai
            .accounts
            .set_api_key(ApiProvider::Claude, "")
            .unwrap();
        write_up_inner(
            &id,
            &fixture.workspace,
            true,
            false,
            &CancellationToken::new(),
        )
        .await
        .unwrap();
        assert!(fixture.requests.lock().unwrap().is_empty());
        assert!(
            fixture
                .workspace
                .store
                .lock()
                .unwrap()
                .note(&id)
                .unwrap()
                .needs_write_up
        );
        assert!(write_up_inner(
            &id,
            &fixture.workspace,
            false,
            false,
            &CancellationToken::new()
        )
        .await
        .unwrap_err()
        .contains("Add a Claude API key"));
    }
    #[tokio::test]
    async fn canceled_or_dropped_jobs_release_the_slot_and_never_commit() {
        for drop_future in [false, true] {
            let fixture = Fixture::new(Duration::from_millis(150)).await;
            let id = fixture.note();
            let state = fixture.workspace.clone();
            let task_id = id.clone();
            let task = tokio::spawn(async move {
                write_up_inner(&task_id, &state, false, false, &CancellationToken::new()).await
            });
            fixture.wait_requests(1).await;
            if drop_future {
                task.abort();
                assert!(task.await.unwrap_err().is_cancelled());
            } else {
                fixture.workspace.cancel_note_jobs();
                assert!(task.await.unwrap().is_err());
            }
            assert!(fixture.workspace.jobs.lock().unwrap().is_empty());
            assert!(fixture
                .workspace
                .store
                .lock()
                .unwrap()
                .note(&id)
                .unwrap()
                .body
                .is_empty());
        }
    }
    #[tokio::test]
    async fn edits_or_ai_off_during_review_stop_both_mutation_and_second_request() {
        for disable in [false, true] {
            let fixture = Fixture::new(Duration::from_millis(100)).await;
            let id = fixture.note();
            let state = fixture.workspace.clone();
            let task_id = id.clone();
            let task = tokio::spawn(async move {
                write_up_inner(&task_id, &state, true, false, &CancellationToken::new()).await
            });
            fixture.wait_requests(1).await;
            if disable {
                fixture
                    .workspace
                    .store
                    .lock()
                    .unwrap()
                    .save_settings(&json!({"notesUseAI":false}))
                    .unwrap();
            } else {
                fixture
                    .workspace
                    .store
                    .lock()
                    .unwrap()
                    .patch_note(&id, &json!({"myNotes":"New context typed while waiting"}))
                    .unwrap();
            }
            assert!(task.await.unwrap().is_err());
            let note = fixture.workspace.store.lock().unwrap().note(&id).unwrap();
            assert_eq!(note.lines[0].text, "Deploy Kubernetis tomorrow.");
            assert!(note.body.is_empty());
            assert_eq!(fixture.requests.lock().unwrap().len(), 1);
        }
    }
    #[tokio::test]
    async fn late_summary_never_overwrites_new_body_labels_or_transcript() {
        for change in ["body", "speakerNames", "transcript"] {
            let fixture = Fixture::new(Duration::from_millis(100)).await;
            let id = fixture.note();
            let state = fixture.workspace.clone();
            let task_id = id.clone();
            let task = tokio::spawn(async move {
                write_up_inner(&task_id, &state, false, false, &CancellationToken::new()).await
            });
            fixture.wait_requests(1).await;
            {
                let store = fixture.workspace.store.lock().unwrap();
                if change == "transcript" {
                    let mut n = store.note(&id).unwrap();
                    n.lines[0].text = "Actually cancel deployment".into();
                    store.put_note(&n).unwrap();
                } else {
                    store
                        .patch_note(
                            &id,
                            &if change == "body" {
                                json!({"body":"My edited summary"})
                            } else {
                                json!({"speakerNames":["User-supplied name"]})
                            },
                        )
                        .unwrap();
                }
            }
            assert!(task.await.unwrap().is_err());
            let note = fixture.workspace.store.lock().unwrap().note(&id).unwrap();
            assert_eq!(note.title, "New meeting");
            assert!(!note.body.contains("Deploy Kubernetes"));
        }
    }
    #[tokio::test]
    async fn ask_empty_selection_searches_relevant_meetings_and_cancellation_is_tracked() {
        let fixture = Fixture::new(Duration::ZERO).await;
        fixture.note();
        assert_eq!(
            ask_inner(
                "What about deployment?".into(),
                vec![],
                vec![],
                &fixture.workspace
            )
            .await
            .unwrap()
            .text,
            "Ana owns the project."
        );
        assert_eq!(fixture.requests.lock().unwrap().len(), 1);
        let request = fixture.requests.lock().unwrap()[0].clone();
        let prompt = request["messages"][0]["content"].as_str().unwrap();
        assert!(prompt.contains("Deploy Kubernetis tomorrow."));
        assert!(prompt.contains(&chrono::Local::now().format("%A").to_string()));
        let fixture = Fixture::new(Duration::from_millis(150)).await;
        let id = fixture.note();
        let state = fixture.workspace.clone();
        let task =
            tokio::spawn(async move { ask_inner("Who?".into(), vec![id], vec![], &state).await });
        fixture.wait_requests(1).await;
        fixture.workspace.cancel_note_jobs();
        assert!(task.await.unwrap().is_err());
        assert!(fixture.workspace.jobs.lock().unwrap().is_empty());
    }
    #[test]
    fn ask_reads_dates_from_the_question() {
        use chrono::TimeZone;
        // Friday 6 November 2026, 15:00 local time.
        let now = chrono::Local
            .with_ymd_and_hms(2026, 11, 6, 15, 0, 0)
            .unwrap();
        let day = |y, m, d| {
            chrono::Local
                .with_ymd_and_hms(y, m, d, 0, 0, 0)
                .unwrap()
                .timestamp() as f64
        };
        assert_eq!(
            question_dates("what happened today?", now),
            Some((day(2026, 11, 6), day(2026, 11, 7)))
        );
        assert_eq!(
            question_dates("Yesterday's call", now),
            Some((day(2026, 11, 5), day(2026, 11, 6)))
        );
        assert_eq!(
            question_dates("recap last week", now),
            Some((day(2026, 10, 26), day(2026, 11, 2)))
        );
        assert_eq!(
            question_dates("on Monday", now),
            Some((day(2026, 11, 2), day(2026, 11, 3)))
        );
        assert_eq!(
            question_dates("in October", now),
            Some((day(2026, 10, 1), day(2026, 11, 1)))
        );
        assert_eq!(
            question_dates("in December", now),
            Some((day(2025, 12, 1), day(2026, 1, 1)))
        );
        assert_eq!(question_dates("you may want to check", now), None);
        assert_eq!(question_dates("what did Sam promise?", now), None);
    }
    #[test]
    fn ask_ranks_meetings_by_question_and_cites_sources() {
        let make = |title: &str, body: &str, kind: &str, at: f64| {
            let mut n = Note::new(kind);
            n.title = title.into();
            n.body = body.into();
            n.created_at = at;
            n
        };
        let notes = vec![
            make("Standup", "Nothing about money.", "meeting", 300.),
            make("Pricing review", "Prices go up in March.", "meeting", 100.),
            make("Voice memo", "Remember the pricing deck.", "voice", 200.),
            make("Empty", "", "meeting", 400.),
        ];
        let picked = relevant_meetings(notes, "What did we decide on pricing?", &[]);
        let titles: Vec<_> = picked.iter().map(|n| n.title.as_str()).collect();
        assert_eq!(titles, ["Pricing review", "Voice memo", "Standup"]);
        let sources = cited_sources(
            "Prices rise in March [2]. Also see [1, 2] and [9].",
            &picked,
        );
        let cited: Vec<_> = sources.iter().map(|s| (s.n, s.title.as_str())).collect();
        assert_eq!(cited, [(2, "Voice memo"), (1, "Pricing review")]);
    }
    #[test]
    fn review_preserves_manual_speaker_names_and_adds_only_new_names() {
        let mut n = Note::new("meeting");
        n.speaker_names = vec!["Manual name".into()];
        n.participants = vec!["José".into()];
        let review = ReviewResult {
            names: std::collections::BTreeMap::from([
                (1, "Wrong overwrite".into()),
                (2, "José".into()),
                (3, "Ana".into()),
            ]),
            fixes: vec![Fix {
                from: "bad".into(),
                to: "good".into(),
            }],
        };
        merge_review(&mut n, review);
        assert_eq!(n.speaker_names, ["Manual name", "José", "Ana"]);
        assert_eq!(n.participants, ["José", "Ana"]);
    }
    #[tokio::test]
    async fn shutdown_cancels_and_drains_jobs_and_rejects_new_requests() {
        let fixture = Fixture::new(Duration::from_secs(1)).await;
        let id = fixture.note();
        let state = fixture.workspace.clone();
        let job_id = id.clone();
        let task = tokio::spawn(async move {
            write_up_inner(&job_id, &state, false, false, &CancellationToken::new()).await
        });
        fixture.wait_requests(1).await;
        assert_eq!(
            fixture.workspace.job_ids().as_slice(),
            std::slice::from_ref(&id)
        );
        fixture.workspace.shutdown().await.unwrap();
        assert!(task.await.unwrap().is_err());
        assert!(fixture.workspace.job_ids().is_empty());
        assert!(fixture
            .workspace
            .store
            .lock()
            .unwrap()
            .note(&id)
            .unwrap()
            .body
            .is_empty());
        assert!(write_up_inner(
            &id,
            &fixture.workspace,
            false,
            false,
            &CancellationToken::new()
        )
        .await
        .unwrap_err()
        .contains("shutting down"));
        assert!(AuthJob::start(&fixture.workspace).is_err());
    }
    #[test]
    fn explicit_import_only_copies_missing_api_keys_and_never_mutates_legacy() {
        struct ReadOnly {
            data: MemorySecrets,
            reads: Mutex<Vec<String>>,
        }
        impl SecretStore for ReadOnly {
            fn get(&self, k: &str) -> Result<Option<Secret>, String> {
                self.reads.lock().unwrap().push(k.into());
                self.data.get(k)
            }
            fn set(&self, _: &str, _: &Secret) -> Result<(), String> {
                panic!("legacy keys must never be overwritten")
            }
            fn delete(&self, _: &str) -> Result<(), String> {
                panic!("legacy keys must never be removed")
            }
        }
        let destination = Arc::new(MemorySecrets::default());
        let accounts = Accounts::new(destination.clone()).unwrap();
        accounts
            .set_api_key(ApiProvider::Claude, "new-app-claude")
            .unwrap();
        let legacy = ReadOnly {
            data: MemorySecrets::default(),
            reads: Mutex::new(vec![]),
        };
        legacy
            .data
            .set("claude-api-key", &Secret::new("old-claude".into()))
            .unwrap();
        legacy
            .data
            .set("openai-api-key", &Secret::new("old-openai".into()))
            .unwrap();
        legacy
            .data
            .set(
                "chatgpt-credentials",
                &Secret::new("never-copy-subscription".into()),
            )
            .unwrap();
        let report =
            import_missing_api_keys(&accounts, &legacy, &CancellationToken::new()).unwrap();
        assert_eq!(report.claude, ApiKeyImportStatus::AlreadyConfigured);
        assert_eq!(report.openai, ApiKeyImportStatus::Imported);
        assert_eq!(*legacy.reads.lock().unwrap(), ["openai-api-key"]);
        assert_eq!(
            accounts
                .api_key(ApiProvider::Claude)
                .unwrap()
                .unwrap()
                .expose(),
            "new-app-claude"
        );
        assert_eq!(
            accounts
                .api_key(ApiProvider::OpenAi)
                .unwrap()
                .unwrap()
                .expose(),
            "old-openai"
        );
        assert_eq!(
            legacy.data.get("openai-api-key").unwrap().unwrap().expose(),
            "old-openai"
        );
        assert!(destination.get("chatgpt-credentials").unwrap().is_none());
        assert!(!serde_json::to_string(&report)
            .unwrap()
            .contains("old-openai"));
    }
    #[test]
    fn import_rechecks_destination_after_legacy_read_and_honors_cancellation() {
        struct ConcurrentLegacy(Arc<MemorySecrets>);
        impl SecretStore for ConcurrentLegacy {
            fn get(&self, k: &str) -> Result<Option<Secret>, String> {
                self.0.set(k, &Secret::new("concurrent-new-key".into()))?;
                Ok(Some(Secret::new("old-key".into())))
            }
            fn set(&self, _: &str, _: &Secret) -> Result<(), String> {
                panic!("read-only")
            }
            fn delete(&self, _: &str) -> Result<(), String> {
                panic!("read-only")
            }
        }
        let destination = Arc::new(MemorySecrets::default());
        let accounts = Accounts::new(destination.clone()).unwrap();
        let legacy = ConcurrentLegacy(destination);
        let report =
            import_missing_api_keys(&accounts, &legacy, &CancellationToken::new()).unwrap();
        assert_eq!(report.claude, ApiKeyImportStatus::AlreadyConfigured);
        assert_eq!(report.openai, ApiKeyImportStatus::AlreadyConfigured);
        assert_eq!(
            accounts
                .api_key(ApiProvider::Claude)
                .unwrap()
                .unwrap()
                .expose(),
            "concurrent-new-key"
        );
        let cancel = CancellationToken::new();
        cancel.cancel();
        assert_eq!(
            import_missing_api_keys(&accounts, &legacy, &cancel).unwrap_err(),
            "Cancelled"
        );
    }
    #[tokio::test]
    async fn key_import_worker_keeps_its_lock_and_shutdown_slot_if_caller_disappears() {
        let fixture = Fixture::new(Duration::ZERO).await;
        let caller =
            NoteJob::start(&fixture.workspace, "$key-import", &CancellationToken::new()).unwrap();
        let worker = OwnedNoteJob::start(
            fixture.workspace.clone(),
            "$key-import-worker",
            &caller.token,
        )
        .unwrap();
        let changes = fixture
            .workspace
            .credential_changes
            .clone()
            .lock_owned()
            .await;
        let (release, wait) = std::sync::mpsc::channel();
        let task = tokio::task::spawn_blocking(move || {
            let _worker = worker;
            let _changes = changes;
            let _ = wait.recv();
        });
        drop(caller);
        assert!(fixture.workspace.credential_changes.try_lock().is_err());
        let state = fixture.workspace.clone();
        let mut shutdown = tokio::spawn(async move { state.shutdown().await });
        assert!(
            tokio::time::timeout(Duration::from_millis(20), &mut shutdown)
                .await
                .is_err()
        );
        release.send(()).unwrap();
        task.await.unwrap();
        shutdown.await.unwrap().unwrap();
        assert!(fixture.workspace.credential_changes.try_lock().is_ok());
        assert!(fixture.workspace.jobs.lock().unwrap().is_empty());
    }
}
