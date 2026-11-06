//! PulseAudio's recording client also works with PipeWire's pulse server. The remote
//! track is the actual default sink's monitor, not an arbitrary selectable microphone.
use super::*;
use std::io::{BufRead, BufReader, Read};
use std::process::{Child, Command, Stdio};

pub(super) struct Backend {
    processes: Vec<Child>,
    readers: Vec<JoinHandle<()>>,
    stopping: Arc<AtomicBool>,
    closed: bool,
}

fn pactl(args: &[&str]) -> Result<String, String> {
    let mut child = Command::new("pactl").args(args).stdout(Stdio::piped()).stderr(Stdio::null())
        .spawn().map_err(|_| "Meeting audio requires pulseaudio-utils and a running PulseAudio or PipeWire-pulse session")?;
    let output = child.stdout.take().ok_or("pactl has no output")?;
    let reader = thread::spawn(move || {
        let mut text = String::new();
        output
            .take(1_048_577)
            .read_to_string(&mut text)
            .map(|_| text)
    });
    let deadline = Instant::now() + Duration::from_secs(3);
    let result = loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                break if status.success() {
                    Ok(())
                } else {
                    Err("Could not query the audio session")
                }
            }
            Ok(None) if Instant::now() < deadline => thread::sleep(POLL),
            _ => {
                let _ = child.kill();
                break Err("The PulseAudio/PipeWire session did not respond");
            }
        }
    };
    let _ = child.wait();
    let output = reader
        .join()
        .map_err(|_| "Audio session query failed")?
        .map_err(|error| error.to_string())?;
    result?;
    if output.len() > 1_048_576 {
        return Err("Oversized audio session response".into());
    }
    Ok(output.trim().to_owned())
}

impl Backend {
    pub(super) fn start(
        config: &Config,
        origin: Instant,
        sender: RawSender,
        events: &SyncSender<Event>,
    ) -> Result<Self, String> {
        let sources: serde_json::Value =
            serde_json::from_str(&pactl(&["--format=json", "list", "sources"])?)
                .map_err(|e| e.to_string())?;
        let source = if let Some(selected) = config
            .input_device
            .as_deref()
            .filter(|name| *name != "default" && *name != "pulse")
        {
            sources.as_array().ok_or("Invalid audio source list")?.iter()
                .find(|source| source["name"].as_str() == Some(selected) || source["description"].as_str() == Some(selected))
                .and_then(|source| source["name"].as_str()).ok_or("Selected meeting microphone is unavailable in PulseAudio/PipeWire. Choose the system default input.")?.to_owned()
        } else {
            pactl(&["get-default-source"])?
        };
        // Never use a monitor as the user's microphone, even if it was made the server default.
        if sources.as_array().is_some_and(|sources| {
            sources.iter().any(|s| {
                s["name"].as_str() == Some(&source)
                    && s["monitor_source"]
                        .as_str()
                        .is_some_and(|v| !v.is_empty() && v != "n/a")
            })
        }) {
            return Err("The default microphone is an output monitor. Select a real microphone before starting a meeting.".into());
        }
        let monitor = if config.capture_system_audio {
            let sink = pactl(&["get-default-sink"])?;
            let sinks: serde_json::Value =
                serde_json::from_str(&pactl(&["--format=json", "list", "sinks"])?)
                    .map_err(|e| e.to_string())?;
            Some(
                sinks
                    .as_array()
                    .ok_or("Invalid audio sink list")?
                    .iter()
                    .find(|value| value["name"].as_str() == Some(&sink))
                    .and_then(|value| value["monitor_source"].as_str())
                    .ok_or("The selected output device has no PulseAudio/PipeWire monitor")?
                    .to_owned(),
            )
        } else {
            None
        };
        let mut backend = Self {
            processes: vec![],
            readers: vec![],
            stopping: Arc::new(AtomicBool::new(false)),
            closed: false,
        };
        backend.record(&source, Track::Microphone, origin, sender.clone())?;
        if let Some(monitor) = monitor {
            backend.record(&monitor, Track::System, origin, sender.clone())?;
        }
        backend.watch_routing(sender.failure.clone())?;
        if config.echo_cancellation {
            emit(events, Event::Warning("This Linux audio backend does not enable microphone echo cancellation. Use headphones to keep call audio out of your microphone track.".into()))?;
        }
        Ok(backend)
    }
    fn record(
        &mut self,
        device: &str,
        track: Track,
        origin: Instant,
        sender: RawSender,
    ) -> Result<(), String> {
        let mut child = Command::new("parec")
            .args(["--raw", "--format=float32le", "--rate=16000", "--channels=1", "--latency-msec=50", "--process-time-msec=20", "--client-name=Pressay Meeting"])
            .arg(format!("--device={device}"))
            .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()
            .map_err(|error| format!("Could not start PulseAudio/PipeWire capture (install pulseaudio-utils): {error}"))?;
        let mut output = child
            .stdout
            .take()
            .ok_or("Audio capture has no output pipe")?;
        let stopping = self.stopping.clone();
        self.processes.push(child);
        let reader = thread::Builder::new().name(format!("pressay-meeting-{track:?}")).spawn(move || {
            let mut buffer = [0u8; RAW_FRAMES * 4];
            let mut carry = Vec::with_capacity(RAW_FRAMES * 4 + 3);
            let mut anchor = None;
            let mut frames = 0u64;
            loop {
                match output.read(&mut buffer) {
                    Ok(0) => { if !stopping.load(Ordering::Acquire) { sender.failure.set("PulseAudio/PipeWire meeting capture closed unexpectedly. Check the audio device."); } return; }
                    Ok(count) => {
                        carry.extend_from_slice(&buffer[..count]);
                        let complete = carry.len() / 4 * 4;
                        if complete == 0 { continue; }
                        let samples: Vec<_> = carry[..complete].as_chunks::<4>().0.iter().map(|v| f32::from_le_bytes(*v)).collect();
                        carry.drain(..complete);
                        // The pulse client resamples against the server clock. Its raw transport
                        // has no hardware timestamps: establish a shared monotonic origin once,
                        // accounting for requested latency, then advance by exact sample counts.
                        let start = *anchor.get_or_insert_with(|| (origin.elapsed().as_secs_f64() - samples.len() as f64 / SAMPLE_RATE as f64 - 0.05).max(0.0));
                        let count = samples.len();
                        sender.send(RawPacket { track, start: start + frames as f64 / SAMPLE_RATE as f64, rate: SAMPLE_RATE, samples });
                        frames += count as u64;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(error) => { if !stopping.load(Ordering::Acquire) { sender.failure.set(format!("PulseAudio/PipeWire audio read failed: {error}")); } return; }
                }
            }
        }).map_err(|error| error.to_string())?;
        self.readers.push(reader);
        Ok(())
    }
    fn watch_routing(&mut self, failure: Arc<Failure>) -> Result<(), String> {
        let mut child = Command::new("pactl")
            .arg("subscribe")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| format!("Could not watch audio routing: {error}"))?;
        let output = child
            .stdout
            .take()
            .ok_or("Audio routing watcher has no output")?;
        let stopping = self.stopping.clone();
        self.processes.push(child);
        self.readers.push(thread::spawn(move || {
            let mut reader = BufReader::new(output);
            loop {
                let mut line = String::new();
                match reader.by_ref().take(4_097).read_line(&mut line) {
                    Ok(0) | Err(_) => { if !stopping.load(Ordering::Acquire) { failure.set("The audio routing monitor disconnected. Meeting capture stopped."); } return; }
                    Ok(_) if line.len() > 4_096 => { failure.set("Invalid audio routing event"); return; }
                    Ok(_) if line.contains("on server") => {
                        if !stopping.load(Ordering::Acquire) { failure.set("The default audio routing changed. Meeting capture stopped; restart it to use the new microphone/output."); }
                        return;
                    }
                    _ => {}
                }
            }
        }));
        Ok(())
    }
    pub(super) fn check(&mut self) -> Result<(), String> {
        for child in &mut self.processes {
            if !self.closed && child.try_wait().map_err(|e| e.to_string())?.is_some() {
                return Err("A PulseAudio/PipeWire capture process stopped. Check audio access and output routing.".into());
            }
        }
        Ok(())
    }
    pub(super) fn stop(&mut self, graceful: bool) -> Result<(), String> {
        if self.closed {
            return Ok(());
        }
        self.closed = true;
        self.stopping.store(true, Ordering::Release);
        if graceful {
            // SIGINT lets parec flush its pipe before it exits. All PIDs here belong to
            // children created by this capture; no external audio process is signalled.
            unsafe extern "C" {
                fn kill(pid: i32, signal: i32) -> i32;
            }
            for child in &self.processes {
                unsafe {
                    kill(child.id() as i32, 2);
                }
            }
            let deadline = Instant::now() + Duration::from_millis(500);
            while Instant::now() < deadline {
                if self
                    .processes
                    .iter_mut()
                    .all(|child| child.try_wait().ok().flatten().is_some())
                {
                    break;
                }
                thread::sleep(POLL);
            }
        }
        for child in &mut self.processes {
            let _ = child.kill();
            let _ = child.wait();
        }
        for reader in self.readers.drain(..) {
            let _ = reader.join();
        }
        Ok(())
    }
}
impl Drop for Backend {
    fn drop(&mut self) {
        let _ = self.stop(false);
    }
}
