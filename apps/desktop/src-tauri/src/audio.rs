//! Native microphone capture. The CPAL stream is created and dropped on its own thread;
//! the audio callback only downmixes into bounded, fixed-size packets. Resampling and
//! caller callbacks never run on the audio thread.
use crate::meeting_capture::StreamingResampler;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample, SampleFormat, SizedSample};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const OUTPUT_RATE: usize = 16_000;
const MAX_SECONDS: usize = 5 * 60;
const PACKET_FRAMES: usize = 1_024;
const QUEUE_PACKETS: usize = 64;
const POLL_INTERVAL: Duration = Duration::from_millis(5);
const AUDIO_TIMEOUT: Duration = Duration::from_secs(5);
const OVERFLOW: u8 = 1;
const INVALID_AUDIO: u8 = 2;

struct Packet {
    samples: [f32; PACKET_FRAMES],
    len: usize,
}

enum Command {
    Finish,
    Cancel,
}

/// Owns one microphone session. `finish`, `cancel`, and `Drop` join the owner thread,
/// so they return only after the native stream has closed. Call these from a worker,
/// not a UI/render or realtime thread. The control loop polls every 5 ms.
pub struct Capture {
    commands: SyncSender<Command>,
    thread: Option<JoinHandle<Result<Vec<f32>, String>>>,
}

impl Capture {
    /// Observe a terminal native error without waiting for the user to release
    /// the talk key. The owner still needs joining through finish/cancel.
    pub fn is_finished(&self) -> bool {
        self.thread.as_ref().is_none_or(JoinHandle::is_finished)
    }

    /// Emit continuous 16 kHz mono chunks from the capture owner, never CPAL's
    /// callback. A slow/disconnected observer is dropped; full capture survives.
    /// Compare the received sample count with `finish()` to detect fallback.
    pub fn start_streaming(
        device_id: Option<&str>,
        on_first_audio: Arc<dyn Fn(usize) + Send + Sync>,
        observer: Option<SyncSender<Vec<f32>>>,
        levels: Option<Arc<dyn Fn([f32; 4]) + Send + Sync>>,
    ) -> Result<Self, String> {
        let device_id = device_id.map(str::to_owned);
        let (commands, receive_commands) = mpsc::sync_channel(1);
        let (ready, receive_ready) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("pressay-microphone".into())
            .spawn(move || {
                let result = record(
                    device_id.as_deref(),
                    on_first_audio,
                    receive_commands,
                    &ready,
                    observer,
                    levels,
                );
                if let Err(error) = &result {
                    // Reports initialization failures; never blocks if readiness was sent already.
                    let _ = ready.try_send(Err(error.clone()));
                }
                result
            })
            .map_err(|error| format!("Could not start microphone thread: {error}"))?;
        match receive_ready.recv() {
            Ok(Ok(())) => Ok(Self {
                commands,
                thread: Some(thread),
            }),
            result => {
                let joined = thread.join();
                Err(match result {
                    Ok(Err(error)) => error,
                    _ => match joined {
                        Ok(Err(error)) => error,
                        _ => "Microphone thread stopped before opening the device".into(),
                    },
                })
            }
        }
    }

    pub fn finish(mut self) -> Result<Vec<f32>, String> {
        let _ = self.commands.try_send(Command::Finish);
        let thread = self
            .thread
            .take()
            .ok_or("Microphone session already closed")?;
        thread
            .join()
            .map_err(|_| "Microphone thread stopped unexpectedly")?
    }

    pub fn cancel(mut self) {
        self.close();
    }

    fn close(&mut self) {
        if let Some(thread) = self.thread.take() {
            let _ = self.commands.try_send(Command::Cancel);
            let _ = thread.join();
        }
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.close();
    }
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct InputDevice {
    pub id: String,
    pub name: String,
}
pub fn list_input_options() -> Result<Vec<InputDevice>, String> {
    #[cfg(target_os = "macos")]
    let mut devices = crate::platform::input_devices()?;
    #[cfg(not(target_os = "macos"))]
    let mut devices = cpal::default_host()
        .input_devices()
        .map_err(|error| format!("Could not list microphones: {error}"))?
        // A device that cannot describe itself must not hide every other microphone.
        .filter_map(|device| {
            Some(InputDevice {
                id: format!("cpal:{}", device.id().ok()?),
                name: device.description().ok()?.name().to_owned(),
            })
        })
        .collect::<Vec<_>>();
    devices.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.id.cmp(&b.id)));
    devices.dedup_by(|a, b| a.id == b.id);
    Ok(devices)
}
pub fn list_inputs() -> Result<Vec<String>, String> {
    Ok(list_input_options()?
        .into_iter()
        .map(|device| device.name)
        .collect())
}
pub fn resolve_input(settings: &serde_json::Value) -> Result<Option<String>, String> {
    let saved = settings["inputDevice"]
        .as_str()
        .filter(|value| !value.is_empty());
    let uid = settings["inputDeviceUID"]
        .as_str()
        .filter(|value| !value.is_empty());
    if saved.is_none() && uid.is_none() {
        return Ok(None);
    }
    if let Some(id) = saved.filter(|id| id.starts_with("cpal:")) {
        return Ok(Some(id.to_owned()));
    }
    if saved.is_none() {
        if let Some(uid) = uid {
            return Ok(Some(format!("cpal:coreaudio:{uid}")));
        }
    }
    resolve_input_from(settings, &list_input_options()?)
}
pub fn resolve_input_from(
    settings: &serde_json::Value,
    devices: &[InputDevice],
) -> Result<Option<String>, String> {
    let saved = settings["inputDevice"]
        .as_str()
        .filter(|value| !value.is_empty());
    let uid = settings["inputDeviceUID"]
        .as_str()
        .filter(|value| !value.is_empty());
    if saved.is_none() && uid.is_none() {
        return Ok(None);
    }
    let wanted = saved
        .map(str::to_owned)
        .unwrap_or_else(|| format!("cpal:coreaudio:{}", uid.unwrap()));
    if wanted.starts_with("cpal:") {
        return devices.iter().find(|device| device.id == wanted).map(|device| Some(device.id.clone()))
            .ok_or_else(|| "Your saved microphone is unavailable. Choose another microphone in General settings.".into());
    }
    let mut matches = devices.iter().filter(|device| device.name == wanted);
    let first = matches.next();
    match (first, matches.next()) {
        (Some(device), None) => Ok(Some(device.id.clone())),
        (Some(_), Some(_)) => Err("More than one microphone has your saved name. Choose the intended microphone in General settings.".into()),
        _ => Err("Your saved microphone is unavailable. Choose another microphone in General settings.".into()),
    }
}
pub(crate) fn selected_device(
    host: &cpal::Host,
    selected: Option<&str>,
) -> Result<cpal::Device, String> {
    if let Some(selected) = selected {
        let id: cpal::DeviceId = selected.strip_prefix("cpal:").ok_or("Choose your microphone again in General settings")?
            .parse().map_err(|_| "Your selected microphone belongs to another platform. Choose an available microphone in General settings.")?;
        host.device_by_id(&id).ok_or_else(|| "Your selected microphone is unavailable. Choose another microphone in General settings.".into())
    } else {
        host.default_input_device()
            .ok_or_else(|| "No microphone is available".into())
    }
}

fn record(
    device_id: Option<&str>,
    on_first_audio: Arc<dyn Fn(usize) + Send + Sync>,
    commands: Receiver<Command>,
    ready: &SyncSender<Result<(), String>>,
    observer: Option<SyncSender<Vec<f32>>>,
    levels: Option<Arc<dyn Fn([f32; 4]) + Send + Sync>>,
) -> Result<Vec<f32>, String> {
    let host = cpal::default_host();
    let device = selected_device(&host, device_id)?;
    let supported = device
        .default_input_config()
        .map_err(|error| format!("Could not read microphone format: {error}"))?;
    let sample_rate = supported.sample_rate() as usize;
    let channels = supported.channels() as usize;
    validate_format(sample_rate, channels)?;
    let config: cpal::StreamConfig = supported.clone().into();
    let (packets, receive_packets) = mpsc::sync_channel(QUEUE_PACKETS);
    let (errors, receive_errors) = mpsc::sync_channel(1);
    let failure = Arc::new(AtomicU8::new(0));
    let stream = match supported.sample_format() {
        SampleFormat::I8 => input_stream::<i8>(&device, &config, packets, errors, failure.clone()),
        SampleFormat::I16 => {
            input_stream::<i16>(&device, &config, packets, errors, failure.clone())
        }
        SampleFormat::I24 => {
            input_stream::<cpal::I24>(&device, &config, packets, errors, failure.clone())
        }
        SampleFormat::I32 => {
            input_stream::<i32>(&device, &config, packets, errors, failure.clone())
        }
        SampleFormat::I64 => {
            input_stream::<i64>(&device, &config, packets, errors, failure.clone())
        }
        SampleFormat::U8 => input_stream::<u8>(&device, &config, packets, errors, failure.clone()),
        SampleFormat::U16 => {
            input_stream::<u16>(&device, &config, packets, errors, failure.clone())
        }
        SampleFormat::U24 => {
            input_stream::<cpal::U24>(&device, &config, packets, errors, failure.clone())
        }
        SampleFormat::U32 => {
            input_stream::<u32>(&device, &config, packets, errors, failure.clone())
        }
        SampleFormat::U64 => {
            input_stream::<u64>(&device, &config, packets, errors, failure.clone())
        }
        SampleFormat::F32 => {
            input_stream::<f32>(&device, &config, packets, errors, failure.clone())
        }
        SampleFormat::F64 => {
            input_stream::<f64>(&device, &config, packets, errors, failure.clone())
        }
        format => return Err(format!("Unsupported microphone sample format: {format}")),
    }
    .map_err(|error| format!("Could not open microphone: {error}"))?;
    stream
        .play()
        .map_err(|error| format!("Could not start microphone: {error}"))?;
    if ready.send(Ok(())).is_err() {
        return Err("Microphone start was cancelled".into());
    }
    let started = Instant::now();
    let mut last_audio = started;
    let mut pipeline = CapturePipeline::new(sample_rate, observer)?;
    let mut first_audio = true;
    let mut last_levels = Instant::now() - Duration::from_secs(1);
    let mut display_levels = [0.0; 4];
    loop {
        match commands.try_recv() {
            Ok(Command::Finish) => {
                return finish_capture(
                    stream,
                    receive_packets,
                    pipeline,
                    &failure,
                    &receive_errors,
                );
            }
            Ok(Command::Cancel) | Err(TryRecvError::Disconnected) => {
                return Err("Recording cancelled".into())
            }
            Err(TryRecvError::Empty) => {}
        }
        check_failure(&failure, &receive_errors)?;
        if started.elapsed() >= Duration::from_secs(MAX_SECONDS as u64) || pipeline.at_limit() {
            return finish_capture(stream, receive_packets, pipeline, &failure, &receive_errors);
        }
        if last_audio.elapsed() >= AUDIO_TIMEOUT {
            return Err(
                "No microphone audio arrived for five seconds. Check access and your input device."
                    .into(),
            );
        }
        match receive_packets.recv_timeout(POLL_INTERVAL) {
            Ok(packet) => {
                if last_levels.elapsed() >= Duration::from_millis(50) && packet.len > 0 {
                    let rms = (packet.samples[..packet.len]
                        .iter()
                        .map(|value| value * value)
                        .sum::<f32>()
                        / packet.len as f32)
                        .sqrt();
                    display_levels.rotate_left(1);
                    display_levels[3] = ((rms * 12.0).sqrt()).clamp(0.0, 1.0);
                    if let Some(callback) = &levels {
                        callback(display_levels);
                    }
                    last_levels = Instant::now();
                }
                pipeline.push_packet(packet)?;
                last_audio = Instant::now();
                if first_audio {
                    first_audio = false;
                    // Application callbacks (including UI events) cannot block CPAL's callback.
                    on_first_audio(
                        (pipeline.source_frames as f64 * OUTPUT_RATE as f64 / sample_rate as f64)
                            .round() as usize,
                    );
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err("Microphone stream stopped unexpectedly".into())
            }
        }
    }
}

/// Stop the device before draining its last packets. At the duration bound,
/// truncate only the crossing packet and preserve every preceding sample.
fn finish_capture(
    stream: cpal::Stream,
    packets: Receiver<Packet>,
    mut pipeline: CapturePipeline,
    failure: &AtomicU8,
    errors: &Receiver<cpal::StreamError>,
) -> Result<Vec<f32>, String> {
    drop(stream);
    check_failure(failure, errors)?;
    for packet in packets.try_iter() {
        pipeline.push_packet(packet)?;
    }
    if pipeline.source_frames == 0 {
        return Err("No microphone audio arrived. Check access and your input device.".into());
    }
    pipeline.finish()
}

fn validate_format(sample_rate: usize, channels: usize) -> Result<(), String> {
    if !(8_000..=192_000).contains(&sample_rate) || !(1..=32).contains(&channels) {
        return Err(format!(
            "Unsupported microphone format: {sample_rate} Hz, {channels} channels"
        ));
    }
    Ok(())
}

fn input_stream<T: SizedSample>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    packets: SyncSender<Packet>,
    errors: SyncSender<cpal::StreamError>,
    failure: Arc<AtomicU8>,
) -> Result<cpal::Stream, cpal::BuildStreamError>
where
    f32: FromSample<T>,
{
    let channels = config.channels as usize;
    device.build_input_stream(
        config,
        move |data: &[T], _: &cpal::InputCallbackInfo| {
            enqueue_audio(data, channels, &packets, &failure);
        },
        move |error| {
            let _ = errors.try_send(error);
        },
        None,
    )
}

fn enqueue_audio<T: Sample>(
    data: &[T],
    channels: usize,
    packets: &SyncSender<Packet>,
    failure: &AtomicU8,
) where
    f32: FromSample<T>,
{
    if failure.load(Ordering::Relaxed) != 0 {
        return;
    }
    if channels == 0 || !data.len().is_multiple_of(channels) {
        failure.store(INVALID_AUDIO, Ordering::Release);
        return;
    }
    // Fixed-size stack packets: no allocation, logging, waiting for space, or application
    // callbacks on the realtime thread. Queue overflow fails the recording, never drops speech.
    for chunk in data.chunks(PACKET_FRAMES * channels) {
        let mut packet = Packet {
            samples: [0.0; PACKET_FRAMES],
            len: chunk.len() / channels,
        };
        for (index, frame) in chunk.chunks_exact(channels).enumerate() {
            let mut mono = 0.0;
            for sample in frame {
                let value = sample.to_sample::<f32>();
                if !value.is_finite() {
                    failure.store(INVALID_AUDIO, Ordering::Release);
                    return;
                }
                mono += value.clamp(-1.0, 1.0) / channels as f32;
            }
            packet.samples[index] = mono;
        }
        if packets.try_send(packet).is_err() {
            failure.store(OVERFLOW, Ordering::Release);
            return;
        }
    }
}

fn check_failure(failure: &AtomicU8, errors: &Receiver<cpal::StreamError>) -> Result<(), String> {
    if let Ok(error) = errors.try_recv() {
        return Err(format!("Microphone disconnected or failed: {error}"));
    }
    match failure.load(Ordering::Acquire) {
        0 => Ok(()),
        OVERFLOW => Err(
            "Microphone buffer overflowed. No partial transcript was accepted; please try again."
                .into(),
        ),
        _ => Err("Microphone returned invalid audio samples".into()),
    }
}

/// One conversion path feeds both live recognition and the complete fallback.
/// Retaining 16 kHz output also bounds memory independently of hardware rate.
struct CapturePipeline {
    converter: StreamingResampler,
    sample_rate: usize,
    source_frames: usize,
    samples: Vec<f32>,
    observer: Option<SyncSender<Vec<f32>>>,
}

impl CapturePipeline {
    fn new(sample_rate: usize, observer: Option<SyncSender<Vec<f32>>>) -> Result<Self, String> {
        validate_format(sample_rate, 1)?;
        Ok(Self {
            converter: StreamingResampler::new(sample_rate)?,
            sample_rate,
            source_frames: 0,
            samples: Vec::with_capacity(OUTPUT_RATE * 2),
            observer,
        })
    }

    fn push_packet(&mut self, packet: Packet) -> Result<(), String> {
        if packet.len > PACKET_FRAMES {
            return Err("Microphone returned an invalid audio packet".into());
        }
        let remaining = self.sample_rate * MAX_SECONDS - self.source_frames;
        self.push(&packet.samples[..packet.len.min(remaining)])
    }

    fn at_limit(&self) -> bool {
        self.source_frames == self.sample_rate * MAX_SECONDS
    }

    fn push(&mut self, samples: &[f32]) -> Result<(), String> {
        if self.source_frames.saturating_add(samples.len()) > self.sample_rate * MAX_SECONDS {
            return Err("Dictation exceeded five minutes. Record a shorter dictation.".into());
        }
        if samples.iter().any(|sample| !sample.is_finite()) {
            return Err("Recording has no valid microphone audio".into());
        }
        self.source_frames += samples.len();
        let converted = self.converter.push(samples)?;
        self.emit(converted)
    }

    fn emit(&mut self, chunk: Vec<f32>) -> Result<(), String> {
        if chunk.is_empty() {
            return Ok(());
        }
        let limit = OUTPUT_RATE * MAX_SECONDS;
        if self.samples.len().saturating_add(chunk.len()) > limit {
            return Err("Dictation exceeded five minutes. Record a shorter dictation.".into());
        }
        if self.samples.capacity() - self.samples.len() < chunk.len() {
            self.samples
                .try_reserve_exact(
                    (OUTPUT_RATE * 10)
                        .max(chunk.len())
                        .min(limit - self.samples.len()),
                )
                .map_err(|_| "Not enough memory to capture microphone audio")?;
        }
        self.samples.extend_from_slice(&chunk);
        if self
            .observer
            .as_ref()
            .is_some_and(|sender| sender.try_send(chunk).is_err())
        {
            // Never resume after dropping a chunk: the consumer must see channel
            // closure and fall back to the complete, uninterrupted recording.
            self.observer = None;
        }
        Ok(())
    }

    fn finish(mut self) -> Result<Vec<f32>, String> {
        let tail = self.converter.finish()?;
        self.emit(tail)?;
        if self.samples.is_empty() {
            return Err("Recording is too short".into());
        }
        Ok(self.samples)
    }
}

#[cfg(test)]
fn resample_mono(samples: Vec<f32>, sample_rate: usize) -> Result<Vec<f32>, String> {
    let mut pipeline = CapturePipeline::new(sample_rate, None)?;
    for chunk in samples.chunks(PACKET_FRAMES) {
        pipeline.push(chunk)?;
    }
    pipeline.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(rate: usize, hz: f32, seconds: f32) -> Vec<f32> {
        (0..(rate as f32 * seconds) as usize)
            .map(|n| (2.0 * std::f32::consts::PI * hz * n as f32 / rate as f32).sin() * 0.5)
            .collect()
    }

    fn rms(samples: &[f32]) -> f32 {
        (samples.iter().map(|sample| sample * sample).sum::<f32>() / samples.len() as f32).sqrt()
    }

    #[test]
    fn conversion_preserves_duration_and_in_band_speech() {
        for rate in [8_000, 16_000, 44_100, 48_000, 96_000, 192_000] {
            let original = tone(rate, 1_000.0, 0.25);
            let result = resample_mono(original, rate).unwrap();
            assert_eq!(result.len(), 4_000, "rate {rate}");
            assert!(
                (rms(&result[200..3_800]) - 0.35355).abs() < 0.01,
                "rate {rate}"
            );
            let expected = tone(OUTPUT_RATE, 1_000.0, 0.25);
            let error: Vec<_> = result[200..3_800]
                .iter()
                .zip(&expected[200..3_800])
                .map(|(a, b)| a - b)
                .collect();
            assert!(
                rms(&error) < 0.01,
                "rate {rate}: resampling introduced a timing shift"
            );
        }
    }

    #[test]
    fn downsampling_rejects_ultrasonic_aliases() {
        let result = resample_mono(tone(48_000, 12_000.0, 0.25), 48_000).unwrap();
        assert!(rms(&result[200..3_800]) < 0.005);
    }

    #[test]
    fn partial_chunks_and_silence_keep_exact_length() {
        for count in [1, 100, 1_023, 1_024, 1_025, 20_001] {
            let result = resample_mono(vec![0.0; count], 44_100);
            if count * OUTPUT_RATE / 44_100 == 0 {
                assert!(result.is_err());
            } else {
                let result = result.unwrap();
                assert_eq!(result.len(), count * OUTPUT_RATE / 44_100);
                assert!(result.iter().all(|sample| *sample == 0.0));
            }
        }
        assert!(resample_mono(vec![], 48_000).is_err());
        assert!(resample_mono(vec![f32::NAN], 16_000).is_err());
        assert!(resample_mono(vec![0.0; 100], 0).is_err());
    }

    #[test]
    fn live_chunks_match_complete_capture_at_hardware_rates_including_tail() {
        for rate in [44_100, 48_000] {
            for count in [100, 1_023, 1_024, 1_025, 20_001, rate + 137] {
                let original: Vec<_> = (0..count).map(|n| (n as f32 * 0.17).sin() * 0.5).collect();
                let expected = resample_mono(original.clone(), rate).unwrap();
                for packet_size in [137, 1_024, 2_003] {
                    let (sender, receive) = mpsc::sync_channel(512);
                    let mut pipeline = CapturePipeline::new(rate, Some(sender)).unwrap();
                    for chunk in original.chunks(packet_size) {
                        pipeline.push(chunk).unwrap();
                    }
                    let mut live: Vec<f32> = receive.try_iter().flatten().collect();
                    if count > rate {
                        assert!(!live.is_empty(), "conversion waited until finish");
                    }
                    let before_tail = live.len();
                    let complete = pipeline.finish().unwrap();
                    live.extend(receive.try_iter().flatten());
                    assert_eq!(receive.try_recv(), Err(TryRecvError::Disconnected));
                    assert_eq!(complete.len(), count * OUTPUT_RATE / rate);
                    assert_eq!(live, complete, "live/fallback differ at {rate}/{count}");
                    assert_eq!(complete, expected, "packet boundaries changed the timeline");
                    assert!(
                        live.len() > before_tail,
                        "final filter tail was not delivered"
                    );
                }
            }
        }
    }

    #[test]
    fn slow_or_disconnected_live_observer_keeps_complete_capture() {
        for disconnect in [false, true] {
            let (sender, receiver) = mpsc::sync_channel(1);
            let mut receiver = Some(receiver);
            if disconnect {
                receiver = None;
            }
            let mut pipeline = CapturePipeline::new(OUTPUT_RATE, Some(sender)).unwrap();
            pipeline.push(&[0.1; 32]).unwrap();
            pipeline.push(&[0.2; 32]).unwrap();
            assert!(pipeline.observer.is_none());
            if let Some(receiver) = &receiver {
                assert_eq!(receiver.try_recv().unwrap(), vec![0.1; 32]);
                assert_eq!(receiver.try_recv(), Err(TryRecvError::Disconnected));
            }
            pipeline.push(&[0.3; 32]).unwrap();
            let expected: Vec<_> = [vec![0.1; 32], vec![0.2; 32], vec![0.3; 32]]
                .into_iter()
                .flatten()
                .collect();
            assert_eq!(pipeline.finish().unwrap(), expected);
        }
    }

    #[test]
    fn callback_downmixes_normalizes_and_fails_on_overflow() {
        let (tx, rx) = mpsc::sync_channel(1);
        let failure = AtomicU8::new(0);
        enqueue_audio(&[16_384i16, 0, -16_384, 0], 2, &tx, &failure);
        let packet = rx.try_recv().unwrap();
        assert_eq!(&packet.samples[..packet.len], &[0.25, -0.25]);
        enqueue_audio(&[0.0f32], 1, &tx, &failure);
        enqueue_audio(&[0.0f32], 1, &tx, &failure);
        assert_eq!(failure.load(Ordering::Acquire), OVERFLOW);
    }

    #[test]
    fn terminal_capture_errors_are_observable_before_key_release() {
        let (commands, _) = mpsc::sync_channel(1);
        let (release, wait) = mpsc::sync_channel(1);
        let owner = thread::spawn(move || {
            wait.recv().unwrap();
            Err("Microphone disconnected".into())
        });
        let capture = Capture {
            commands,
            thread: Some(owner),
        };
        assert!(!capture.is_finished());
        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while !capture.is_finished() {
            assert!(Instant::now() < deadline, "capture owner never finished");
            thread::yield_now();
        }
        assert_eq!(capture.finish().unwrap_err(), "Microphone disconnected");
    }

    #[test]
    fn finish_cancel_and_drop_join_the_capture_owner() {
        use std::sync::atomic::AtomicBool;
        for operation in ["finish", "cancel", "drop"] {
            let closed = Arc::new(AtomicBool::new(false));
            let owner_closed = closed.clone();
            let (commands, rx) = mpsc::sync_channel(1);
            let thread = thread::spawn(move || {
                let command = rx.recv().unwrap();
                owner_closed.store(true, Ordering::Release);
                match command {
                    Command::Finish => Ok(vec![0.25; 100]),
                    Command::Cancel => Err("Recording cancelled".into()),
                }
            });
            let capture = Capture {
                commands,
                thread: Some(thread),
            };
            match operation {
                "finish" => assert_eq!(capture.finish().unwrap(), vec![0.25; 100]),
                "cancel" => capture.cancel(),
                _ => drop(capture),
            }
            assert!(
                closed.load(Ordering::Acquire),
                "{operation} returned before capture closed"
            );
        }
    }

    #[test]
    fn five_minute_bound_finishes_with_exact_crossing_tail_instead_of_losing_capture() {
        let mut pipeline = CapturePipeline::new(OUTPUT_RATE, None).unwrap();
        pipeline
            .push(&vec![0.0; OUTPUT_RATE * MAX_SECONDS - 1])
            .unwrap();
        let packet = Packet {
            samples: [0.5; PACKET_FRAMES],
            len: 2,
        };
        pipeline.push_packet(packet).unwrap();
        assert!(pipeline.at_limit());
        pipeline
            .push_packet(Packet {
                samples: [0.9; PACKET_FRAMES],
                len: PACKET_FRAMES,
            })
            .unwrap();
        let complete = pipeline.finish().unwrap();
        assert_eq!(complete.len(), OUTPUT_RATE * MAX_SECONDS);
        assert_eq!(complete[complete.len() - 2], 0.0);
        assert_eq!(complete.last(), Some(&0.5));
    }

    #[test]
    fn callback_rejects_non_finite_or_incomplete_frames() {
        for (samples, channels) in [(vec![0.0, f32::INFINITY], 1), (vec![0.0], 2)] {
            let (tx, rx) = mpsc::sync_channel(2);
            let failure = AtomicU8::new(0);
            enqueue_audio(&samples, channels, &tx, &failure);
            assert_eq!(failure.load(Ordering::Acquire), INVALID_AUDIO);
            assert!(rx.try_recv().is_err());
        }
    }
}
