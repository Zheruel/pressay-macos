use super::*;
use serde_json::json;
use std::os::unix::fs::symlink;
use std::path::Path;
struct FakeCli {
    dir: tempfile::TempDir,
    client: ClaudeCodeClient,
}
impl FakeCli {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("claude-fixture");
        // The executable is immutable even while other tests fork children.
        symlink(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/claude-cli.py"),
            &path,
        )
        .unwrap();
        let fixture = Self {
            dir,
            client: ClaudeCodeClient::new(path),
        };
        fixture.configure(json!({}));
        fixture
    }
    fn configure(&self, value: Value) {
        std::fs::write(self.dir.path().join("config.json"), value.to_string()).unwrap();
    }
    fn events(&self) -> Vec<Value> {
        std::fs::read_to_string(self.dir.path().join("events.jsonl"))
            .unwrap_or_default()
            .lines()
            .filter_map(|s| serde_json::from_str(s).ok())
            .collect()
    }
    async fn wait_kind(&self, kind: &str, count: usize) {
        tokio::time::timeout(Duration::from_secs(3), async {
            while self.events().iter().filter(|e| e["kind"] == kind).count() < count {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
    }
    async fn wait_dead(&self, pid: u32) {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let status = tokio::process::Command::new("kill")
                    .args(["-0", &pid.to_string()])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .await
                    .unwrap();
                if !status.success() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("CLI process must be killed and reaped");
    }
}
#[tokio::test]
async fn preparation_never_infers_and_transcript_only_uses_stdin() {
    let fixture = FakeCli::new();
    let cancel = CancellationToken::new();
    let preparation = fixture
        .client
        .prepare("system", "low", &cancel)
        .await
        .unwrap();
    fixture.wait_kind("waiting", 1).await;
    assert!(!fixture.events().iter().any(|e| e["kind"] == "submitted"));
    let input = "$(touch SHOULD_NOT_EXIST) `touch ALSO_NOT` ; private transcript";
    let result = fixture
        .client
        .complete(
            "system",
            input,
            "claude-haiku-5-5",
            "low",
            Duration::from_secs(3),
            Some(preparation),
            &cancel,
        )
        .await
        .unwrap();
    assert_eq!(result, "Cleaned dictation.");
    let events = fixture.events();
    assert_eq!(events.iter().filter(|e| e["kind"] == "waiting").count(), 1);
    let submitted = events.iter().find(|e| e["kind"] == "submitted").unwrap();
    assert_eq!(submitted["text"], format!("\n{input}"));
    let args = submitted["args"].as_array().unwrap();
    assert!(!args
        .iter()
        .any(|a| a.as_str().unwrap().contains("private transcript")));
    assert!(args.contains(&json!("--safe-mode")));
    assert!(args.contains(&json!("--no-session-persistence")));
    assert!(args.windows(2).any(|p| p == [json!("--tools"), json!("")]));
    assert!(args
        .windows(2)
        .any(|p| p == [json!("--disallowedTools"), json!("mcp__*")]));
    let cwd = PathBuf::from(submitted["cwd"].as_str().unwrap());
    assert_ne!(cwd, std::env::current_dir().unwrap());
    assert!(!cwd.join("SHOULD_NOT_EXIST").exists());
    assert!(!cwd.join("ALSO_NOT").exists());
    fixture
        .wait_dead(submitted["pid"].as_u64().unwrap() as u32)
        .await;
}
#[tokio::test]
async fn dropped_and_cancelled_preparations_kill_waiting_processes() {
    for drop_only in [true, false] {
        let fixture = FakeCli::new();
        let cancel = CancellationToken::new();
        let preparation = fixture
            .client
            .prepare("system", "low", &cancel)
            .await
            .unwrap();
        fixture.wait_kind("waiting", 1).await;
        let pid = fixture.events()[0]["pid"].as_u64().unwrap() as u32;
        if drop_only {
            drop(preparation);
        } else {
            cancel.cancel();
            tokio::time::sleep(Duration::from_millis(20)).await;
            drop(preparation);
        }
        fixture.wait_dead(pid).await;
        assert!(!fixture.events().iter().any(|e| e["kind"] == "submitted"));
    }
}
#[tokio::test]
async fn cancellation_outer_drop_and_timeout_reap_inference() {
    for kind in ["cancel", "drop", "timeout"] {
        let fixture = FakeCli::new();
        fixture.configure(json!({"delay":10}));
        let cancel = CancellationToken::new();
        let client = fixture.client.clone();
        let task = {
            let cancel = cancel.clone();
            tokio::spawn(async move {
                client
                    .complete(
                        "system",
                        "private transcript",
                        "claude-haiku-5-5",
                        "low",
                        if kind == "timeout" {
                            Duration::from_secs(2)
                        } else {
                            Duration::from_secs(5)
                        },
                        None,
                        &cancel,
                    )
                    .await
            })
        };
        fixture.wait_kind("submitted", 1).await;
        let pid = fixture
            .events()
            .iter()
            .find(|e| e["kind"] == "submitted")
            .unwrap()["pid"]
            .as_u64()
            .unwrap() as u32;
        match kind {
            "cancel" => {
                cancel.cancel();
                assert!(matches!(task.await.unwrap(), Err(AiError::Cancelled)));
            }
            "drop" => {
                task.abort();
                assert!(task.await.unwrap_err().is_cancelled());
            }
            _ => assert!(matches!(task.await.unwrap(), Err(AiError::Timeout))),
        }
        fixture.wait_dead(pid).await;
    }
}
#[tokio::test]
async fn api_billing_is_rejected_and_account_switch_discards_preparation() {
    let fixture = FakeCli::new();
    fixture.configure(json!({"auth":"api_key"}));
    assert!(matches!(
        fixture
            .client
            .prepare("system", "low", &CancellationToken::new())
            .await,
        Err(AiError::ClaudeNotSignedIn)
    ));
    assert!(fixture.events().is_empty());
    fixture.configure(json!({}));
    let prep = fixture
        .client
        .prepare("system", "low", &CancellationToken::new())
        .await
        .unwrap();
    fixture.wait_kind("waiting", 1).await;
    let old = fixture.events()[0]["pid"].as_u64().unwrap() as u32;
    fixture.configure(json!({"org":"different-account"}));
    fixture
        .client
        .complete(
            "system",
            "private transcript",
            "claude-haiku-5-5",
            "low",
            Duration::from_secs(3),
            Some(prep),
            &CancellationToken::new(),
        )
        .await
        .unwrap();
    fixture.wait_dead(old).await;
    assert_eq!(
        fixture
            .events()
            .iter()
            .filter(|e| e["kind"] == "submitted")
            .count(),
        1
    );
    assert_ne!(
        fixture
            .events()
            .iter()
            .find(|e| e["kind"] == "submitted")
            .unwrap()["pid"]
            .as_u64()
            .unwrap() as u32,
        old
    );
}
#[tokio::test]
async fn malformed_and_oversized_output_is_bounded_and_sanitized() {
    for config in [json!({"malformed":true}), json!({"oversized":true})] {
        let fixture = FakeCli::new();
        fixture.configure(config);
        let error = fixture
            .client
            .complete(
                "system",
                "input",
                "claude-haiku-5-5",
                "low",
                Duration::from_secs(3),
                None,
                &CancellationToken::new(),
            )
            .await
            .unwrap_err();
        assert!(matches!(error, AiError::ClaudeFailed));
        assert!(!error.to_string().contains("fixture-token"));
        let pid = fixture.events()[0]["pid"].as_u64().unwrap() as u32;
        fixture.wait_dead(pid).await;
    }
}

#[tokio::test]
async fn shutdown_drain_waits_for_dropped_processes_to_be_reaped() {
    let fixture = FakeCli::new();
    let preparation = fixture
        .client
        .prepare("system", "low", &CancellationToken::new())
        .await
        .unwrap();
    fixture.wait_kind("waiting", 1).await;
    let pid = fixture.events()[0]["pid"].as_u64().unwrap() as u32;
    drop(preparation);
    tokio::time::timeout(Duration::from_secs(10), wait_for_children())
        .await
        .unwrap();
    let status = tokio::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .unwrap();
    assert!(!status.success());
}

#[tokio::test]
async fn installation_after_startup_enables_auth_and_cleanup_without_restart() {
    let fixture = FakeCli::new();
    let bin = fixture.dir.path().join("new-install");
    std::fs::create_dir(&bin).unwrap();
    let client = ClaudeCodeClient {
        location: Location::Directories(vec![bin.clone()]),
    };
    let cancel = CancellationToken::new();
    assert!(!client.auth_status(&cancel).await.unwrap().available);
    let executable = bin.join("claude");
    symlink(fixture.client.executable_path().unwrap(), &executable).unwrap();
    assert!(client.auth_status(&cancel).await.unwrap().uses_subscription);
    let prepared = client.prepare("system", "low", &cancel).await.unwrap();
    assert_eq!(
        client
            .complete(
                "system",
                "dictation",
                "claude-haiku-5-5",
                "low",
                Duration::from_secs(3),
                Some(prepared),
                &cancel
            )
            .await
            .unwrap(),
        "Cleaned dictation."
    );
}
