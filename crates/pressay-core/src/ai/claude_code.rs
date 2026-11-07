//! Published Claude Code CLI integration. No shell, credentials-file parsing,
//! tools, session reuse, or transcript in process arguments.
use super::AiError;
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    path::PathBuf,
    process::Stdio,
    sync::Arc,
    time::{Duration, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::{Child, ChildStdin, Command},
    sync::Mutex,
    time::Instant,
};
use tokio_util::sync::CancellationToken;
const MAX_OUTPUT: u64 = 1024 * 1024;
const MAX_INPUT: usize = 10 * 1024 * 1024;

#[derive(Clone, Debug, Serialize)]
pub struct AuthStatus {
    pub available: bool,
    pub logged_in: bool,
    pub auth_method: String,
    pub subscription_type: Option<String>,
    pub uses_subscription: bool,
    #[serde(skip)]
    identity: Option<String>,
}
impl AuthStatus {
    fn parse(bytes: &[u8]) -> Result<Self, AiError> {
        let json: Value = serde_json::from_slice(bytes).map_err(|_| AiError::ClaudeFailed)?;
        let logged_in = json["loggedIn"].as_bool().ok_or(AiError::ClaudeFailed)?;
        let auth_method = json["authMethod"].as_str().unwrap_or("none").to_owned();
        let parts: Vec<_> = ["orgId", "email", "subscriptionType"]
            .iter()
            .filter_map(|k| json[*k].as_str())
            .collect();
        let identity = (!parts.is_empty())
            .then(|| format!("{:x}", Sha256::digest(parts.join("\n").as_bytes())));
        Ok(Self {
            available: true,
            logged_in,
            uses_subscription: logged_in && auth_method == "claude.ai",
            auth_method,
            subscription_type: json["subscriptionType"].as_str().map(str::to_owned),
            identity,
        })
    }
}
#[derive(Clone)]
enum Location {
    System,
    Fixed(Option<PathBuf>),
    #[cfg(test)]
    Directories(Vec<PathBuf>),
}
#[derive(Clone)]
pub struct ClaudeCodeClient {
    location: Location,
}
impl ClaudeCodeClient {
    /// Resolve on each operation, so installing/updating the native CLI does
    /// not require restarting Pressay. Each operation freezes its chosen path.
    pub fn discover() -> Self {
        Self {
            location: Location::System,
        }
    }
    pub fn new(executable: PathBuf) -> Self {
        Self {
            location: Location::Fixed(Some(executable)),
        }
    }
    /// Explicitly disable CLI execution, primarily for isolated native hosts.
    pub fn unavailable() -> Self {
        Self {
            location: Location::Fixed(None),
        }
    }
    fn directories() -> Vec<PathBuf> {
        let mut directories = vec![];
        if let Some(home) = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }) {
            directories.push(PathBuf::from(home).join(".local/bin"));
        }
        if cfg!(windows) {
            if let Some(local) = std::env::var_os("LOCALAPPDATA") {
                directories.push(PathBuf::from(local).join("Microsoft/WinGet/Links"));
            }
        } else {
            directories.extend([
                PathBuf::from("/opt/homebrew/bin"),
                PathBuf::from("/usr/local/bin"),
            ]);
        }
        directories.extend(std::env::split_paths(
            &std::env::var_os("PATH").unwrap_or_default(),
        ));
        directories
    }
    fn executable_path(&self) -> Option<PathBuf> {
        let directories = match &self.location {
            Location::Fixed(path) => return path.clone(),
            Location::System => Self::directories(),
            #[cfg(test)]
            Location::Directories(paths) => paths.clone(),
        };
        let name = if cfg!(windows) {
            "claude.exe"
        } else {
            "claude"
        };
        directories.into_iter().map(|d| d.join(name)).find(|p| {
            if !p.is_file() {
                return false;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                p.metadata()
                    .is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
            }
            #[cfg(not(unix))]
            {
                true
            }
        })
    }
    fn resolved(&self) -> Self {
        Self {
            location: Location::Fixed(self.executable_path()),
        }
    }
    fn identity(&self) -> Option<String> {
        let path = self.executable_path()?.canonicalize().ok()?;
        let meta = path.metadata().ok()?;
        let modified = meta
            .modified()
            .ok()?
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_nanos();
        Some(format!("{}|{}|{}", path.display(), modified, meta.len()))
    }
    pub async fn check_capabilities(&self, cancel: &CancellationToken) -> Result<(), AiError> {
        let result = self
            .run(&["--help".into()], "", Duration::from_secs(5), cancel)
            .await?;
        let text = String::from_utf8(result.stdout).map_err(|_| AiError::ClaudeUpdateRequired)?;
        if result.code != 0
            || ![
                "--safe-mode",
                "--tools",
                "--disallowedTools",
                "--no-session-persistence",
                "--output-format",
                "--system-prompt",
                "--effort",
                "--model",
            ]
            .iter()
            .all(|flag| text.contains(flag))
        {
            return Err(AiError::ClaudeUpdateRequired);
        }
        Ok(())
    }
    pub async fn auth_status(&self, cancel: &CancellationToken) -> Result<AuthStatus, AiError> {
        let client = self.resolved();
        if client.executable_path().is_none() {
            return Ok(AuthStatus {
                available: false,
                logged_in: false,
                auth_method: "none".into(),
                subscription_type: None,
                uses_subscription: false,
                identity: None,
            });
        }
        let result = client
            .run(
                &["auth".into(), "status".into()],
                "",
                Duration::from_secs(5),
                cancel,
            )
            .await?;
        AuthStatus::parse(&result.stdout)
    }
    pub async fn sign_in(&self, cancel: &CancellationToken) -> Result<(), AiError> {
        let result = self
            .run(
                &["auth".into(), "login".into()],
                "",
                Duration::from_secs(180),
                cancel,
            )
            .await?;
        if result.code == 0 {
            Ok(())
        } else {
            Err(AiError::ClaudeFailed)
        }
    }
    async fn run(
        &self,
        args: &[String],
        input: &str,
        timeout: Duration,
        cancel: &CancellationToken,
    ) -> Result<ProcessResult, AiError> {
        if cancel.is_cancelled() {
            return Err(AiError::Cancelled);
        }
        let executable = self.executable_path().ok_or(AiError::ClaudeNotInstalled)?;
        let mut process = Pending::spawn(&executable, args)?;
        process.submit(input, timeout, cancel).await
    }
    pub async fn prepare(
        &self,
        system: &str,
        effort: &str,
        cancel: &CancellationToken,
    ) -> Result<Preparation, AiError> {
        let client = self.resolved();
        let (_, status) = tokio::try_join!(
            client.check_capabilities(cancel),
            client.auth_status(cancel)
        )?;
        if !status.uses_subscription {
            return Err(AiError::ClaudeNotSignedIn);
        }
        if cancel.is_cancelled() {
            return Err(AiError::Cancelled);
        }
        let mut pending = Pending::spawn(
            &client
                .executable_path()
                .ok_or(AiError::ClaudeNotInstalled)?,
            &arguments(system, "claude-haiku-5-5", effort),
        )?;
        // CLI waits for EOF. A newline keeps its stdin reader alive without
        // supplying a prompt or triggering inference.
        pending
            .stdin
            .as_mut()
            .ok_or(AiError::ClaudeFailed)?
            .write_all(b"\n")
            .await
            .map_err(|_| AiError::ClaudeFailed)?;
        let process = Arc::new(Mutex::new(Some(pending)));
        let lifecycle = CancellationToken::new();
        let owned = process.clone();
        let idle_cancel = lifecycle.clone();
        let external = cancel.clone();
        tokio::spawn(async move {
            tokio::select! {_=idle_cancel.cancelled()=>{},_=external.cancelled()=>{},_=tokio::time::sleep(Duration::from_secs(60))=>{}}
            if let Some(mut process) = owned.lock().await.take() {
                process.stop().await;
            }
        });
        Ok(Preparation {
            process,
            lifecycle,
            executable: client.identity(),
            system: system.into(),
            effort: effort.into(),
            account: status.identity,
            started: Instant::now(),
        })
    }
    #[allow(clippy::too_many_arguments)]
    pub async fn complete(
        &self,
        system: &str,
        input: &str,
        model: &str,
        effort: &str,
        timeout: Duration,
        preparation: Option<Preparation>,
        cancel: &CancellationToken,
    ) -> Result<String, AiError> {
        let client = self.resolved();
        let deadline = Instant::now() + timeout;
        let work = async {
            let reusable = preparation.as_ref().is_some_and(|p| {
                p.executable.is_some()
                    && p.executable == client.identity()
                    && p.system == system
                    && p.effort == effort
                    && p.started.elapsed() < Duration::from_secs(55)
                    && model == "claude-haiku-5-5"
                    && !p.lifecycle.is_cancelled()
            });
            if !reusable {
                client.check_capabilities(cancel).await?;
            }
            let status = client.auth_status(cancel).await?;
            if !status.uses_subscription {
                return Err(AiError::ClaudeNotSignedIn);
            }
            let mut pending = if reusable
                && preparation
                    .as_ref()
                    .is_some_and(|p| p.account.is_some() && p.account == status.identity)
            {
                preparation.as_ref().unwrap().process.lock().await.take()
            } else {
                None
            };
            if let Some(process) = pending.as_mut() {
                if process
                    .child
                    .as_mut()
                    .ok_or(AiError::ClaudeFailed)?
                    .try_wait()
                    .map_err(|_| AiError::ClaudeFailed)?
                    .is_some()
                {
                    pending = None;
                }
            }
            let mut pending = match pending {
                Some(p) => p,
                None => Pending::spawn(
                    &client
                        .executable_path()
                        .ok_or(AiError::ClaudeNotInstalled)?,
                    &arguments(system, model, effort),
                )?,
            };
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                pending.stop().await;
                return Err(AiError::Timeout);
            }
            let result = pending.submit(input, remaining, cancel).await?;
            parse_reply(&result.stdout, result.code)
        };
        tokio::select! {biased;_=cancel.cancelled()=>Err(AiError::Cancelled),result=tokio::time::timeout_at(deadline,work)=>result.unwrap_or(Err(AiError::Timeout))}
    }
}
pub struct Preparation {
    process: Arc<Mutex<Option<Pending>>>,
    lifecycle: CancellationToken,
    executable: Option<String>,
    system: String,
    effort: String,
    account: Option<String>,
    started: Instant,
}
impl Preparation {
    pub fn cancel(&self) {
        self.lifecycle.cancel();
    }
}
impl Drop for Preparation {
    fn drop(&mut self) {
        self.lifecycle.cancel();
    }
}
pub fn arguments(system: &str, model: &str, effort: &str) -> Vec<String> {
    [
        "-p",
        "--safe-mode",
        "--tools",
        "",
        "--disallowedTools",
        "mcp__*",
        "--no-session-persistence",
        "--output-format",
        "json",
        "--model",
        model,
        "--effort",
        effort,
        "--system-prompt",
        system,
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}
pub fn parse_reply(bytes: &[u8], exit: i32) -> Result<String, AiError> {
    let json: Value = serde_json::from_slice(bytes).map_err(|_| AiError::ClaudeFailed)?;
    if exit != 0
        || json["type"] != "result"
        || json["subtype"] != "success"
        || json["is_error"] == true
        || json
            .get("stop_reason")
            .and_then(Value::as_str)
            .is_some_and(|s| s != "end_turn")
    {
        return Err(AiError::ClaudeFailed);
    }
    json["result"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .ok_or(AiError::ClaudeFailed)
}
struct ProcessResult {
    stdout: Vec<u8>,
    code: i32,
}
#[derive(Default)]
struct Children {
    count: std::sync::atomic::AtomicUsize,
    changed: tokio::sync::Notify,
}
fn children() -> &'static Children {
    static CHILDREN: std::sync::OnceLock<Children> = std::sync::OnceLock::new();
    CHILDREN.get_or_init(Children::default)
}
struct ChildLease;
impl ChildLease {
    fn new() -> Self {
        children()
            .count
            .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
        Self
    }
}
impl Drop for ChildLease {
    fn drop(&mut self) {
        children()
            .count
            .fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
        children().changed.notify_waiters();
    }
}
/// Call after cancelling all caller/preparation tokens. Includes children whose
/// caller was dropped while cancellation was racing the outer deadline.
pub async fn wait_for_children() {
    loop {
        let notified = children().changed.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        if children().count.load(std::sync::atomic::Ordering::Acquire) == 0 {
            return;
        }
        notified.await;
    }
}
struct Pending {
    lease: Option<ChildLease>,
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    stdout: Option<tokio::task::JoinHandle<Result<Vec<u8>, AiError>>>,
    stderr: Option<tokio::task::JoinHandle<Result<Vec<u8>, AiError>>>,
    _directory: tempfile::TempDir,
}
impl Pending {
    fn spawn(executable: &PathBuf, args: &[String]) -> Result<Self, AiError> {
        let directory = tempfile::tempdir().map_err(|_| AiError::ClaudeFailed)?;
        let mut child = Command::new(executable)
            .args(args)
            .env("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1")
            .current_dir(directory.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|_| AiError::ClaudeNotInstalled)?;
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().ok_or(AiError::ClaudeFailed)?;
        let stderr = child.stderr.take().ok_or(AiError::ClaudeFailed)?;
        async fn read(stream: impl tokio::io::AsyncRead + Unpin) -> Result<Vec<u8>, AiError> {
            let mut bytes = vec![];
            stream
                .take(MAX_OUTPUT + 1)
                .read_to_end(&mut bytes)
                .await
                .map_err(|_| AiError::ClaudeFailed)?;
            if bytes.len() as u64 > MAX_OUTPUT {
                return Err(AiError::ClaudeFailed);
            }
            Ok(bytes)
        }
        Ok(Self {
            lease: Some(ChildLease::new()),
            child: Some(child),
            stdin,
            stdout: Some(tokio::spawn(read(stdout))),
            stderr: Some(tokio::spawn(read(stderr))),
            _directory: directory,
        })
    }
    async fn stop(&mut self) {
        // EOF submits the prepared prompt. Keep stdin open until the child is dead.
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill().await;
            let _ = child.wait().await;
        }
        self.stdin.take();
        self.child.take();
        if let Some(task) = self.stdout.take() {
            task.abort();
        }
        if let Some(task) = self.stderr.take() {
            task.abort();
        }
    }
    async fn submit(
        &mut self,
        input: &str,
        timeout: Duration,
        cancel: &CancellationToken,
    ) -> Result<ProcessResult, AiError> {
        if input.len() > MAX_INPUT {
            self.stop().await;
            return Err(AiError::ClaudeFailed);
        }
        let mut stdin = self.stdin.take().ok_or(AiError::ClaudeFailed)?;
        let stdout = self.stdout.take().ok_or(AiError::ClaudeFailed)?;
        let stderr = self.stderr.take().ok_or(AiError::ClaudeFailed)?;
        let work = async {
            let write = async {
                stdin
                    .write_all(input.as_bytes())
                    .await
                    .map_err(|_| AiError::ClaudeFailed)?;
                stdin.shutdown().await.map_err(|_| AiError::ClaudeFailed)?;
                drop(stdin);
                Ok::<_, AiError>(())
            };
            let output = async { stdout.await.map_err(|_| AiError::ClaudeFailed)? };
            let error = async { stderr.await.map_err(|_| AiError::ClaudeFailed)? };
            let wait = async {
                self.child
                    .as_mut()
                    .ok_or(AiError::ClaudeFailed)?
                    .wait()
                    .await
                    .map_err(|_| AiError::ClaudeFailed)
            };
            let (_, stdout, _, status) = tokio::try_join!(write, output, error, wait)?;
            Ok(ProcessResult {
                stdout,
                code: status.code().unwrap_or(-1),
            })
        };
        let result = tokio::select! {biased;_=cancel.cancelled()=>Err(AiError::Cancelled),result=tokio::time::timeout(timeout,work)=>result.unwrap_or(Err(AiError::Timeout))};
        if result.is_err() {
            self.stop().await;
        }
        result
    }
}

// Outer caller deadlines can drop submit before its cancellation branch runs.
// Kill synchronously on drop and retain ownership until the OS child is reaped.
impl Drop for Pending {
    fn drop(&mut self) {
        if let Some(task) = self.stdout.take() {
            task.abort();
        }
        if let Some(task) = self.stderr.take() {
            task.abort();
        }
        if let Some(mut child) = self.child.take() {
            if child.try_wait().ok().flatten().is_none() {
                let _ = child.start_kill();
                if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                    let lease = self.lease.take();
                    let stdin = self.stdin.take();
                    runtime.spawn(async move {
                        let _lease = lease;
                        let _stdin = stdin;
                        let _ = child.wait().await;
                    });
                }
            }
        }
    }
}

#[cfg(all(test, unix))]
#[path = "claude_code_tests.rs"]
mod tests;

#[cfg(test)]
mod discovery_tests {
    use super::*;
    #[test]
    fn missing_installation_is_rediscovered_without_mutating_environment() {
        let dir = tempfile::tempdir().unwrap();
        let client = ClaudeCodeClient {
            location: Location::Directories(vec![dir.path().into()]),
        };
        assert!(client.executable_path().is_none());
        let path = dir.path().join(if cfg!(windows) {
            "claude.exe"
        } else {
            "claude"
        });
        std::fs::write(&path, b"test fixture only").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        assert_eq!(client.executable_path().as_ref(), Some(&path));
        let resolved = client.resolved();
        std::fs::remove_file(&path).unwrap();
        assert!(client.executable_path().is_none());
        assert_eq!(resolved.executable_path().as_ref(), Some(&path));
    }
}
