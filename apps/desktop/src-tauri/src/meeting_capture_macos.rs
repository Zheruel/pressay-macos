use super::*;
use std::io::{Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};

pub(super) struct Backend {
    child: Child,
    input: Option<ChildStdin>,
    reader: Option<JoinHandle<()>>,
    failure: Arc<Failure>,
    stopped: Arc<AtomicBool>,
    closed: bool,
}

impl Backend {
    pub(super) fn start(
        config: &Config,
        origin: Instant,
        sender: RawSender,
        events: &SyncSender<Event>,
    ) -> Result<Self, String> {
        let helper = config.mac_helper.clone().unwrap_or(
            std::env::current_exe()
                .map_err(|error| error.to_string())?
                .with_file_name("PressayMeetingCapture"),
        );
        if !helper.is_file() {
            return Err(
                "The signed meeting-capture helper is missing from this app. Reinstall Pressay."
                    .into(),
            );
        }
        let mut command = Command::new(helper);
        command.args(["--exclude-pid", &std::process::id().to_string()]);
        if let Some(id) = &config.input_device {
            let uid = id
                .strip_prefix("cpal:coreaudio:")
                .ok_or("The selected microphone belongs to another platform")?;
            command.args(["--input", uid]);
        }
        if !config.capture_system_audio {
            command.arg("--microphone-only");
        }
        if !config.echo_cancellation {
            command.arg("--no-echo-cancellation");
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| format!("Could not start native meeting capture: {error}"))?;
        let output = child
            .stdout
            .take()
            .ok_or("Meeting helper has no output pipe")?;
        let input = child.stdin.take();
        let failure = sender.failure.clone();
        let reader_failure = failure.clone();
        let stopped = Arc::new(AtomicBool::new(false));
        let reader_stopped = stopped.clone();
        let (ready, receive_ready) = mpsc::sync_channel(1);
        let events = events.clone();
        let reader = match thread::Builder::new()
            .name("pressay-meeting-native-reader".into())
            .spawn(move || {
                if let Err(error) =
                    read_packets(output, origin, sender, &events, &ready, &reader_stopped)
                {
                    reader_failure.set(error.clone());
                    let _ = ready.try_send(Err(error));
                }
            }) {
            Ok(reader) => reader,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error.to_string());
            }
        };
        let mut backend = Self {
            child,
            input,
            reader: Some(reader),
            failure,
            stopped,
            closed: false,
        };
        match receive_ready.recv_timeout(Duration::from_secs(30)) {
            Ok(Ok(())) => Ok(backend),
            result => {
                let _ = backend.stop(false);
                Err(match result { Ok(Err(error)) => error, _ => "Native meeting capture did not become ready. Check microphone and system-audio access.".into() })
            }
        }
    }
    pub(super) fn check(&mut self) -> Result<(), String> {
        self.failure.check()?;
        if !self.closed && self.child.try_wait().map_err(|e| e.to_string())?.is_some() {
            return Err("Native meeting capture exited unexpectedly".into());
        }
        Ok(())
    }
    pub(super) fn stop(&mut self, graceful: bool) -> Result<(), String> {
        if self.closed {
            return Ok(());
        }
        self.closed = true;
        let mut completed = false;
        if graceful {
            if let Some(mut input) = self.input.take() {
                let _ = input.write_all(b"stop\n");
            }
            let deadline = Instant::now() + Duration::from_secs(3);
            while Instant::now() < deadline {
                match self.child.try_wait() {
                    Ok(Some(status)) => {
                        completed = status.success();
                        break;
                    }
                    Ok(None) => thread::sleep(POLL),
                    Err(_) => break,
                }
            }
        }
        if !completed {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
        self.input = None;
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
        if graceful {
            self.failure.check()?;
            if !completed || !self.stopped.load(Ordering::Acquire) {
                return Err(
                    "Native meeting capture could not flush its final audio before closing".into(),
                );
            }
        }
        Ok(())
    }
}
impl Drop for Backend {
    fn drop(&mut self) {
        let _ = self.stop(false);
    }
}

// Protocol v1: u8 kind + u32 little-endian payload size. Ready=1(JSON), Audio=2
// (u8 track + f64 seconds + u32 frames + f32le PCM), Warning=3, Error=4, Stopped=5.
fn read_packets(
    mut output: impl Read,
    origin: Instant,
    sender: RawSender,
    events: &SyncSender<Event>,
    ready: &SyncSender<Result<(), String>>,
    stopped: &AtomicBool,
) -> Result<(), String> {
    let mut offset = None;
    loop {
        let mut header = [0u8; 5];
        output
            .read_exact(&mut header)
            .map_err(|_| "Native meeting audio pipe closed without a stop acknowledgement")?;
        let size = u32::from_le_bytes(header[1..].try_into().unwrap()) as usize;
        if size > 1_048_576 {
            return Err("Oversized native meeting audio packet".into());
        }
        let mut payload = vec![0u8; size];
        output
            .read_exact(&mut payload)
            .map_err(|_| "Incomplete native meeting audio packet")?;
        match header[0] {
            1 if offset.is_none() => {
                let value: serde_json::Value =
                    serde_json::from_slice(&payload).map_err(|e| e.to_string())?;
                let elapsed = value["elapsed"]
                    .as_f64()
                    .filter(|v| v.is_finite() && *v >= 0.0)
                    .ok_or("Invalid native meeting clock")?;
                if value["version"].as_u64() != Some(1) {
                    return Err("Unsupported native meeting helper version".into());
                }
                offset = Some((origin.elapsed().as_secs_f64() - elapsed).max(0.0));
                ready
                    .send(Ok(()))
                    .map_err(|_| "Meeting start was cancelled")?;
            }
            2 => {
                let offset = offset.ok_or("Native audio arrived before readiness")?;
                if payload.len() < 13 {
                    return Err("Invalid native meeting audio header".into());
                }
                let track = match payload[0] {
                    1 => Track::Microphone,
                    2 => Track::System,
                    _ => return Err("Unknown meeting audio track".into()),
                };
                let start = f64::from_le_bytes(payload[1..9].try_into().unwrap());
                let count = u32::from_le_bytes(payload[9..13].try_into().unwrap()) as usize;
                if count == 0
                    || count > 65_536
                    || payload.len() != 13 + count * 4
                    || !start.is_finite()
                    || start < 0.0
                {
                    return Err("Invalid native meeting audio payload".into());
                }
                for (index, bytes) in payload[13..].chunks(RAW_FRAMES * 4).enumerate() {
                    let samples = bytes
                        .as_chunks::<4>()
                        .0
                        .iter()
                        .map(|value| f32::from_le_bytes(*value))
                        .collect();
                    sender.send(RawPacket {
                        track,
                        start: offset + start + (index * RAW_FRAMES) as f64 / SAMPLE_RATE as f64,
                        rate: SAMPLE_RATE,
                        samples,
                    });
                }
            }
            3 => emit(
                events,
                Event::Warning(String::from_utf8(payload).map_err(|_| "Invalid native warning")?),
            )?,
            4 => return Err(String::from_utf8(payload).map_err(|_| "Invalid native error")?),
            5 if payload.is_empty() && offset.is_some() => {
                stopped.store(true, Ordering::Release);
                return Ok(());
            }
            _ => return Err("Invalid native meeting capture message".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn packet(kind: u8, payload: &[u8]) -> Vec<u8> {
        let mut result = vec![kind];
        result.extend((payload.len() as u32).to_le_bytes());
        result.extend(payload);
        result
    }
    #[test]
    fn helper_protocol_preserves_both_tracks_and_rejects_unbounded_frames() {
        let (raw_tx, raw_rx) = mpsc::sync_channel(8);
        let sender = RawSender {
            sender: raw_tx,
            failure: Arc::new(Failure::default()),
        };
        let (events, _rx) = mpsc::sync_channel(8);
        let (ready, _ready_rx) = mpsc::sync_channel(1);
        let stopped = AtomicBool::new(false);
        let mut bytes = packet(1, br#"{"version":1,"elapsed":0.0}"#);
        for track in [1u8, 2] {
            let mut payload = vec![track];
            payload.extend(0.25f64.to_le_bytes());
            payload.extend(1u32.to_le_bytes());
            payload.extend(0.5f32.to_le_bytes());
            bytes.extend(packet(2, &payload));
        }
        bytes.extend(packet(5, &[]));
        read_packets(
            bytes.as_slice(),
            Instant::now(),
            sender.clone(),
            &events,
            &ready,
            &stopped,
        )
        .unwrap();
        assert!(stopped.load(Ordering::Acquire));
        let mic = raw_rx.try_recv().unwrap();
        let remote = raw_rx.try_recv().unwrap();
        assert_eq!(mic.track, Track::Microphone);
        assert_eq!(remote.track, Track::System);
        assert_eq!(mic.start, remote.start);
        assert_eq!(mic.samples, vec![0.5]);
        let mut invalid = vec![2];
        invalid.extend(2_000_000u32.to_le_bytes());
        assert!(read_packets(
            invalid.as_slice(),
            Instant::now(),
            sender,
            &events,
            &ready,
            &stopped
        )
        .is_err());
    }
    fn fixture_helper() -> (PathBuf, PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "pressay-meeting-fixture-{}-{unique}",
            std::process::id()
        ));
        std::fs::create_dir(&directory).unwrap();
        let helper = directory.join("capture");
        let escaped = |bytes: Vec<u8>| {
            bytes
                .iter()
                .map(|byte| format!("\\{byte:03o}"))
                .collect::<String>()
        };
        let ready = packet(1, br#"{"version":1,"elapsed":0.0}"#);
        let mut pcm = vec![1u8];
        pcm.extend(0.25f64.to_le_bytes());
        pcm.extend(400u32.to_le_bytes());
        for _ in 0..400 {
            pcm.extend(0.5f32.to_le_bytes());
        }
        let script = format!(
            "#!/bin/sh\nprintf '{}'\nprintf '{}'\nIFS= read -r command\nprintf '{}'\n",
            escaped(ready),
            escaped(packet(2, &pcm)),
            escaped(packet(5, &[]))
        );
        std::fs::write(&helper, script).unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o700)).unwrap();
        (directory, helper)
    }

    #[test]
    fn graceful_finish_drains_native_partial_audio_and_closes_receiver() {
        let (directory, helper) = fixture_helper();
        let config = Config {
            mac_helper: Some(helper),
            capture_system_audio: false,
            ..Config::default()
        };
        let (capture, receiver) = Capture::start(config).unwrap();
        capture.finish().unwrap();
        let events: Vec<_> = receiver.into_iter().collect();
        let samples: Vec<_> = events
            .into_iter()
            .filter_map(|event| match event {
                Event::Audio(chunk) => Some(chunk.samples),
                _ => None,
            })
            .flatten()
            .collect();
        assert_eq!(samples, vec![0.5; 400]);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn drop_kills_and_reaps_only_the_owned_native_helper() {
        let (directory, helper) = fixture_helper();
        let config = Config {
            mac_helper: Some(helper),
            capture_system_audio: false,
            ..Config::default()
        };
        let (tx, _rx) = mpsc::sync_channel(128);
        let sender = RawSender {
            sender: tx,
            failure: Arc::new(Failure::default()),
        };
        let (events, _event_rx) = mpsc::sync_channel(8);
        let backend = Backend::start(&config, Instant::now(), sender, &events).unwrap();
        let pid = backend.child.id();
        drop(backend);
        unsafe extern "C" {
            fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
        }
        let mut status = 0;
        assert_eq!(
            unsafe { waitpid(pid as i32, &mut status, 1) },
            -1,
            "helper was not reaped by Drop"
        );
        std::fs::remove_dir_all(directory).unwrap();
    }
}
