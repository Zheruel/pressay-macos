#![cfg(unix)]
use pressay_core::analysis::AnalysisHost;
use std::{
    path::{Path, PathBuf},
    time::Duration,
};
use tokio_util::sync::CancellationToken;
fn fixture(dir: &Path, response: &str) -> PathBuf {
    // Keep executables immutable: concurrent process creation can temporarily
    // inherit another test's writable descriptor and cause Linux ETXTBSY.
    std::fs::write(dir.join("response.sh"), response).unwrap();
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/analysis-worker.sh")
}
fn alive(pid: &str) -> bool {
    std::process::Command::new("kill")
        .args(["-0", pid.trim()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success()
}
#[tokio::test]
async fn cancellation_during_inference_kills_and_reaps() {
    let dir = tempfile::tempdir().unwrap();
    let worker = fixture(dir.path(), "exec sleep 120");
    let pid_path = dir.path().join("pid");
    let mut host = AnalysisHost::new(worker, dir.path().into());
    let cancel = CancellationToken::new();
    host.prepare_vad(&pid_path, &cancel).await.unwrap();
    let pid = std::fs::read_to_string(&pid_path).unwrap();
    assert!(alive(&pid));
    let signal = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(20)).await;
        signal.cancel();
    });
    let result = tokio::time::timeout(
        Duration::from_secs(3),
        host.classify(0, &[0.; 512], &cancel),
    )
    .await
    .unwrap();
    assert!(matches!(result, Err(pressay_core::Error::Cancelled)));
    assert!(!alive(&pid));
}
#[tokio::test]
async fn malformed_result_closes_worker_before_reuse() {
    let dir = tempfile::tempdir().unwrap();
    let worker = fixture(dir.path(), "printf '%s\\n' '{\"result\":{\"first_frame\":0,\"frame_samples\":480,\"probabilities\":[0.2]}}'\nexec sleep 120");
    let pid_path = dir.path().join("pid");
    let mut host = AnalysisHost::new(worker, dir.path().into());
    let cancel = CancellationToken::new();
    host.prepare_vad(&pid_path, &cancel).await.unwrap();
    let pid = std::fs::read_to_string(&pid_path).unwrap();
    assert!(host
        .classify(0, &[0.; 512], &cancel)
        .await
        .unwrap_err()
        .to_string()
        .contains("Invalid voice"));
    assert!(!alive(&pid));
}
#[tokio::test]
async fn dropping_host_terminates_its_child() {
    let dir = tempfile::tempdir().unwrap();
    let worker = fixture(dir.path(), "exec sleep 120");
    let pid_path = dir.path().join("pid");
    let mut host = AnalysisHost::new(worker, dir.path().into());
    host.prepare_vad(&pid_path, &CancellationToken::new())
        .await
        .unwrap();
    let pid = std::fs::read_to_string(&pid_path).unwrap();
    drop(host);
    tokio::time::timeout(Duration::from_secs(3), async {
        while alive(&pid) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
}
