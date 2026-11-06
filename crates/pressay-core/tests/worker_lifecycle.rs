//! Exercise actual OS children and pipes, not mocked request futures. Unix CI
//! supplies Python 3; Windows runs the portable worker protocol tests separately.
#![cfg(unix)]

use pressay_core::{audio::SAMPLE_RATE, worker::WorkerHost, Error};
use serde_json::Value;
use std::{
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};
use tokio_util::sync::CancellationToken;

const WORKER: &str = r#"#!/usr/bin/env python3
import base64, json, os, struct, sys, time
model, model_path, runtime = sys.argv[1:]
log = os.path.join(runtime, 'events.jsonl')
def event(kind, **extra):
    with open(log, 'a') as f:
        f.write(json.dumps(dict(kind=kind, pid=os.getpid(), model=model, path=model_path, **extra))+'\n')
def reply(**fields):
    print(json.dumps(fields), flush=True)
event('start')
if model == 'hang-ready': time.sleep(60)
reply(ready=True)
for line in sys.stdin:
    data = base64.b64decode(json.loads(line)['pcm'])
    samples = struct.unpack('<%df' % (len(data)//4), data)
    event('request', count=len(samples), first=samples[0])
    if model == 'hang': time.sleep(60)
    elif model == 'oversized':
        sys.stdout.write('x' * (1048576 + 1)); sys.stdout.flush(); time.sleep(60)
    elif model == 'eof': sys.exit(0)
    elif model == 'incomplete': print('{"text":"incomplete","truncated":false}', end='', flush=True); sys.exit(0)
    elif model == 'bad-json': print('not json', flush=True)
    elif model == 'missing-field': reply(text='missing truncated')
    elif model in ('truncate', 'always-truncate'):
        truncated = model == 'always-truncate' or len(samples) > 16000
        reply(text='DISCARD THIS PARTIAL' if truncated else str(round(samples[0], 1)), truncated=truncated)
    else:
        reply(text=model + ':' + str(len(samples)), truncated=False)
        if model == 'exit': sys.exit(0)
"#;

struct Fixture {
    directory: tempfile::TempDir,
    executable: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("worker.py");
        std::fs::write(&executable, WORKER).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        Self {
            directory,
            executable,
        }
    }
    fn host(&self) -> WorkerHost {
        WorkerHost::new(self.executable.clone(), self.directory.path().into())
            .with_timeout(Duration::from_secs(5))
    }
    fn log(&self) -> PathBuf {
        self.directory.path().join("events.jsonl")
    }
    fn starts(&self) -> Vec<Value> {
        events(&self.log())
            .into_iter()
            .filter(|e| e["kind"] == "start")
            .collect()
    }
}

fn events(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

fn alive(pid: u64) -> bool {
    Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success()
}

async fn wait_for_event(log: &Path, kind: &str) {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if events(log).iter().any(|event| event["kind"] == kind) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("worker never reached expected state");
}

#[tokio::test]
async fn cancellation_kills_and_reaps_during_startup_and_inference() {
    for model in ["hang-ready", "hang"] {
        let fixture = Fixture::new();
        let mut host = fixture.host();
        let cancel = CancellationToken::new();
        let trigger = cancel.clone();
        let log = fixture.log();
        let canceller = tokio::spawn(async move {
            wait_for_event(
                &log,
                if model == "hang-ready" {
                    "start"
                } else {
                    "request"
                },
            )
            .await;
            trigger.cancel();
        });
        let result = host
            .request(model, Path::new("model"), Some(&[0.5]), &cancel)
            .await;
        canceller.await.unwrap();
        assert!(matches!(result, Err(Error::Cancelled)));
        let old_pid = fixture.starts()[0]["pid"].as_u64().unwrap();
        assert!(!alive(old_pid), "cancel returned before reaping worker");
        let result = host
            .request(
                "normal",
                Path::new("model"),
                Some(&[0.1]),
                &CancellationToken::new(),
            )
            .await
            .unwrap();
        assert_eq!(result, ("normal:1".into(), false));
        host.stop().await;
    }
}

#[tokio::test]
async fn deadlines_cover_startup_and_inference_and_prevent_orphans() {
    for model in ["hang-ready", "hang"] {
        let fixture = Fixture::new();
        let mut host = fixture.host().with_timeout(Duration::from_secs(1));
        let result = host
            .request(
                model,
                Path::new("model"),
                Some(&[0.1]),
                &CancellationToken::new(),
            )
            .await;
        assert!(result.unwrap_err().to_string().contains("timed out"));
        let starts = fixture.starts();
        assert_eq!(starts.len(), 1);
        assert!(!alive(starts[0]["pid"].as_u64().unwrap()));
    }
}

#[tokio::test]
async fn reuses_one_model_and_reaps_before_model_or_path_replacement() {
    let fixture = Fixture::new();
    let mut host = fixture.host();
    let cancel = CancellationToken::new();
    host.request("first", Path::new("path-a"), None, &cancel)
        .await
        .unwrap();
    let first = fixture.starts()[0]["pid"].as_u64().unwrap();
    host.request("first", Path::new("path-a"), Some(&[0.1]), &cancel)
        .await
        .unwrap();
    assert_eq!(fixture.starts().len(), 1);
    host.request("second", Path::new("path-a"), Some(&[0.1]), &cancel)
        .await
        .unwrap();
    assert!(!alive(first));
    let second = fixture.starts()[1]["pid"].as_u64().unwrap();
    host.request("second", Path::new("path-b"), None, &cancel)
        .await
        .unwrap();
    assert!(!alive(second));
    assert_eq!(fixture.starts().len(), 3);
    let last = fixture.starts()[2]["pid"].as_u64().unwrap();
    host.stop().await;
    assert!(!alive(last));
}

#[tokio::test]
async fn reloads_a_resident_that_exited_between_jobs() {
    let fixture = Fixture::new();
    let mut host = fixture.host();
    let cancel = CancellationToken::new();
    host.request("exit", Path::new("model"), Some(&[0.1]), &cancel)
        .await
        .unwrap();
    // Let the child finish exiting. The next preparation must not reuse its
    // previous ready handshake merely because model/path happen to match.
    tokio::time::sleep(Duration::from_millis(100)).await;
    host.request("exit", Path::new("model"), None, &cancel)
        .await
        .unwrap();
    assert_eq!(fixture.starts().len(), 2);
    host.stop().await;
}

#[tokio::test]
async fn bad_replies_stop_the_worker_and_allow_a_clean_next_job() {
    for model in [
        "oversized",
        "eof",
        "incomplete",
        "bad-json",
        "missing-field",
    ] {
        let fixture = Fixture::new();
        let mut host = fixture.host();
        let cancel = CancellationToken::new();
        assert!(host
            .request(model, Path::new("model"), Some(&[0.1]), &cancel)
            .await
            .is_err());
        assert!(!alive(fixture.starts()[0]["pid"].as_u64().unwrap()));
        assert_eq!(
            host.request("normal", Path::new("model"), Some(&[0.1]), &cancel)
                .await
                .unwrap()
                .0,
            "normal:1"
        );
        host.stop().await;
    }
}

#[tokio::test]
async fn retries_truncated_chunks_without_returning_partial_or_reordering_audio() {
    let fixture = Fixture::new();
    let mut host = fixture.host();
    let samples: Vec<_> = [0.1, 0.2, 0.3, 0.4]
        .into_iter()
        .flat_map(|s| vec![s; SAMPLE_RATE])
        .collect();
    let text = host
        .transcribe(
            "truncate",
            Path::new("model"),
            &samples,
            &CancellationToken::new(),
        )
        .await
        .unwrap();
    assert_eq!(text, "0.1 0.2 0.3 0.4");
    let requests = events(&fixture.log())
        .into_iter()
        .filter(|e| e["kind"] == "request")
        .count();
    assert_eq!(requests, 7); // 4s, two 2s chunks, four 1s chunks.
    assert_eq!(fixture.starts().len(), 1);
    host.stop().await;
}

#[tokio::test]
async fn repeated_truncation_is_bounded_and_pre_cancelled_work_never_spawns() {
    let fixture = Fixture::new();
    let mut host = fixture.host();
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert!(matches!(
        host.request("normal", Path::new("model"), None, &cancel)
            .await,
        Err(Error::Cancelled)
    ));
    assert!(fixture.starts().is_empty());
    let result = host
        .transcribe(
            "always-truncate",
            Path::new("model"),
            &vec![0.1; SAMPLE_RATE * 2],
            &CancellationToken::new(),
        )
        .await;
    assert!(result.unwrap_err().to_string().contains("could not finish"));
    let requests = events(&fixture.log())
        .into_iter()
        .filter(|e| e["kind"] == "request")
        .count();
    assert_eq!(requests, 2);
    host.stop().await;
}

#[tokio::test]
async fn preserves_qwen_long_context_and_other_models_bounded_chunks() {
    let fixture = Fixture::new();
    let mut host = fixture.host();
    let audio = vec![0.2; 40 * SAMPLE_RATE];
    let cancel = CancellationToken::new();
    for (model, expected) in [
        ("qwen3ASR17", "qwen3ASR17:640000"),
        ("moss", "moss:320000 moss:320000"),
    ] {
        let text = host
            .transcribe(model, fixture.directory.path(), &audio, &cancel)
            .await
            .unwrap();
        assert_eq!(text, expected);
    }
    host.stop().await;
}
