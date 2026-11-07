//! Bounded two-track native meeting capture. Audio is emitted continuously and never
//! accumulated for the duration of a meeting. Track timestamps share one monotonic clock.
use rubato::{
    audioadapter_buffers::direct::InterleavedSlice, Fft, FixedSync, Indexing, Resampler,
    WindowFunction,
};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

#[cfg(target_os = "macos")]
#[path = "meeting_capture_macos.rs"]
mod platform;
#[cfg(target_os = "linux")]
#[path = "meeting_capture_linux.rs"]
mod platform;
#[cfg(windows)]
#[path = "meeting_capture_windows.rs"]
mod platform;

#[cfg(any(target_os = "windows", target_os = "linux"))]
#[path = "meeting_capture_cpal.rs"]
mod cpal_input;

pub const SAMPLE_RATE: usize = 16_000;
const RAW_FRAMES: usize = 4_096;
const RUNNING: u8 = 0;
const FINISH: u8 = 1;
const CANCEL: u8 = 2;
const POLL: Duration = Duration::from_millis(10);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Track {
    Microphone,
    System,
}

#[derive(Debug)]
pub struct Chunk {
    pub track: Track,
    /// Seconds since capture startup, on the same monotonic timeline for both tracks.
    pub start: f64,
    /// Mono, finite f32 PCM at exactly 16 kHz.
    pub samples: Vec<f32>,
}

#[derive(Debug)]
pub enum Event {
    Audio(Chunk),
    Warning(String),
}

#[derive(Clone, Debug)]
pub struct Config {
    pub input_device: Option<String>,
    pub max_duration: Duration,
    pub chunk_frames: usize,
    pub queue_capacity: usize,
    pub capture_system_audio: bool,
    pub echo_cancellation: bool,
    /// Defaults to PressayMeetingCapture alongside the running app executable.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    pub mac_helper: Option<PathBuf>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            input_device: None,
            max_duration: Duration::from_secs(3 * 60 * 60),
            chunk_frames: SAMPLE_RATE,
            queue_capacity: 32,
            capture_system_audio: true,
            echo_cancellation: true,
            mac_helper: None,
        }
    }
}

pub struct Capture {
    control: Arc<AtomicU8>,
    thread: Option<JoinHandle<Result<(), String>>>,
}

impl Capture {
    /// Starts native capture and returns a bounded receiver. Consume it continuously;
    /// queue saturation stops capture with an error instead of silently dropping speech.
    /// Call startup/finish/cancel from a worker because native stream teardown can block.
    pub fn start(config: Config) -> Result<(Self, Receiver<Event>), String> {
        if !(SAMPLE_RATE / 10..=SAMPLE_RATE * 10).contains(&config.chunk_frames)
            || !(2..=128).contains(&config.queue_capacity)
            || !(Duration::from_secs(1)..=Duration::from_secs(8 * 60 * 60))
                .contains(&config.max_duration)
        {
            return Err("Invalid meeting duration or audio queue limits".into());
        }
        let (events, receiver) = mpsc::sync_channel(config.queue_capacity);
        let (ready, receive_ready) = mpsc::sync_channel(1);
        let control = Arc::new(AtomicU8::new(RUNNING));
        let thread_control = control.clone();
        let thread = thread::Builder::new()
            .name("pressay-meeting-capture".into())
            .spawn(move || {
                let result = run(config, thread_control, events, &ready);
                if let Err(error) = &result {
                    let _ = ready.try_send(Err(error.clone()));
                }
                result
            })
            .map_err(|error| format!("Could not start meeting capture: {error}"))?;
        match receive_ready.recv() {
            Ok(Ok(())) => Ok((
                Self {
                    control,
                    thread: Some(thread),
                },
                receiver,
            )),
            result => {
                control.store(CANCEL, Ordering::Release);
                let joined = thread.join();
                Err(match result {
                    Ok(Err(error)) => error,
                    _ => match joined {
                        Ok(Err(error)) => error,
                        _ => "Meeting capture stopped before startup completed".into(),
                    },
                })
            }
        }
    }

    pub fn is_finished(&self) -> bool {
        self.thread.as_ref().is_none_or(JoinHandle::is_finished)
    }

    /// Closes both native tracks and emits their final partial chunks. The receiver
    /// remains drainable after this call. Continue consuming while finishing if it is full.
    pub fn finish(mut self) -> Result<(), String> {
        self.control.store(FINISH, Ordering::Release);
        self.join()
    }

    pub fn cancel(mut self) {
        self.control.store(CANCEL, Ordering::Release);
        let _ = self.join();
    }

    fn join(&mut self) -> Result<(), String> {
        if let Some(thread) = self.thread.take() {
            thread
                .join()
                .map_err(|_| "Meeting capture thread stopped unexpectedly")?
        } else {
            Ok(())
        }
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.control.store(CANCEL, Ordering::Release);
        let _ = self.join();
    }
}

#[derive(Clone)]
struct RawSender {
    sender: SyncSender<RawPacket>,
    failure: Arc<Failure>,
}

impl RawSender {
    fn send(&self, packet: RawPacket) {
        if self.sender.try_send(packet).is_err() {
            self.failure.set("Meeting audio queue overflowed or its reader closed. Capture stopped without accepting a partial transcript.");
        }
    }
}

struct RawPacket {
    track: Track,
    start: f64,
    rate: usize,
    samples: Vec<f32>,
}

#[derive(Default)]
struct Failure {
    failed: AtomicBool,
    message: Mutex<Option<String>>,
}

impl Failure {
    fn set(&self, message: impl Into<String>) {
        // Called from native callbacks: never wait on a lock or the processing queue.
        if !self.failed.load(Ordering::Relaxed) {
            if let Ok(mut slot) = self.message.try_lock() {
                if slot.is_none() {
                    *slot = Some(message.into());
                }
            }
            self.failed.store(true, Ordering::Release);
        }
    }
    fn check(&self) -> Result<(), String> {
        if self.failed.load(Ordering::Acquire) {
            Err(self
                .message
                .lock()
                .ok()
                .and_then(|value| value.clone())
                .unwrap_or_else(|| "Native meeting audio capture failed".into()))
        } else {
            Ok(())
        }
    }
}

fn emit(events: &SyncSender<Event>, event: Event) -> Result<(), String> {
    events.try_send(event).map_err(|_| "Meeting transcription is not keeping up with audio. Capture stopped because its bounded queue is full or disconnected.".into())
}

fn run(
    config: Config,
    control: Arc<AtomicU8>,
    events: SyncSender<Event>,
    ready: &SyncSender<Result<(), String>>,
) -> Result<(), String> {
    let origin = Instant::now();
    let (sender, raw) = mpsc::sync_channel(128);
    let failure = Arc::new(Failure::default());
    let sender = RawSender {
        sender,
        failure: failure.clone(),
    };
    let mut backend = platform::Backend::start(&config, origin, sender, &events)?;
    let mut microphone = Pipeline::new(Track::Microphone, config.chunk_frames, config.max_duration);
    let mut system = Pipeline::new(Track::System, config.chunk_frames, config.max_duration);
    ready
        .send(Ok(()))
        .map_err(|_| "Meeting start was cancelled")?;
    let mut last_mic = Instant::now();
    let mut system_frames = 0usize;
    let mut system_nonzero = false;
    let mut silence_warning = false;
    loop {
        failure.check()?;
        backend.check()?;
        let command = control.load(Ordering::Acquire);
        if command == CANCEL {
            backend.stop(false)?;
            return Ok(());
        }
        if command == FINISH || origin.elapsed() >= config.max_duration {
            if command != FINISH {
                emit(
                    &events,
                    Event::Warning(
                        "Meeting reached its configured maximum duration and has stopped.".into(),
                    ),
                )?;
            }
            backend.stop(true)?;
            failure.check()?;
            while let Ok(packet) = raw.try_recv() {
                match packet.track {
                    Track::Microphone => microphone.push(packet, &events)?,
                    Track::System => system.push(packet, &events)?,
                }
            }
            microphone.finish(&events)?;
            system.finish(&events)?;
            return Ok(());
        }
        if last_mic.elapsed() >= Duration::from_secs(5) {
            return Err("No microphone audio arrived for five seconds. Meeting capture has stopped; check microphone access and the selected input.".into());
        }
        match raw.recv_timeout(POLL) {
            Ok(packet) => match packet.track {
                Track::Microphone => {
                    last_mic = Instant::now();
                    microphone.push(packet, &events)?;
                }
                Track::System => {
                    system_frames += packet.samples.len();
                    if !system_nonzero && packet.samples.iter().any(|sample| sample.abs() > 0.00001)
                    {
                        system_nonzero = true;
                        if silence_warning {
                            emit(
                                &events,
                                Event::Warning("Call audio is now being received.".into()),
                            )?;
                        }
                    }
                    system.push(packet, &events)?;
                }
            },
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err("Native meeting audio streams closed unexpectedly".into())
            }
        }
        if config.capture_system_audio
            && !system_nonzero
            && !silence_warning
            && (origin.elapsed() >= Duration::from_secs(90)
                || system_frames == 0 && origin.elapsed() >= Duration::from_secs(10))
        {
            emit(&events, Event::Warning("No call audio has been detected. Check the output device and system-audio permission; microphone capture is still running.".into()))?;
            silence_warning = true;
        }
    }
}

struct Pipeline {
    track: Track,
    chunk_frames: usize,
    limit_frames: u64,
    resampler: Option<StreamingResampler>,
    rate: usize,
    expected_raw_end: Option<f64>,
    start: f64,
    emitted: usize,
    pending: Vec<f32>,
}

impl Pipeline {
    fn new(track: Track, chunk_frames: usize, max_duration: Duration) -> Self {
        Self {
            track,
            chunk_frames,
            limit_frames: (max_duration.as_nanos() * SAMPLE_RATE as u128 / 1_000_000_000) as u64,
            resampler: None,
            rate: 0,
            expected_raw_end: None,
            start: 0.0,
            emitted: 0,
            pending: Vec::with_capacity(chunk_frames + SAMPLE_RATE),
        }
    }
    fn push(&mut self, packet: RawPacket, events: &SyncSender<Event>) -> Result<(), String> {
        if packet.samples.len() > RAW_FRAMES
            || packet.samples.is_empty()
            || !packet.start.is_finite()
            || packet.start < 0.0
            || packet.samples.iter().any(|value| !value.is_finite())
            || !(8_000..=192_000).contains(&packet.rate)
        {
            return Err("Native meeting capture returned invalid audio".into());
        }
        let discontinuity = self
            .expected_raw_end
            .is_some_and(|expected| (packet.start - expected).abs() > 0.1);
        if self.rate != packet.rate || discontinuity {
            self.finish(events)?;
            self.start = packet
                .start
                .max(self.start + self.emitted as f64 / SAMPLE_RATE as f64);
            self.emitted = 0;
            self.rate = packet.rate;
            self.resampler = Some(StreamingResampler::new(packet.rate)?);
            if discontinuity {
                emit(
                    events,
                    Event::Warning(
                        "An audio device clock changed. The meeting timeline preserves the gap."
                            .into(),
                    ),
                )?;
            }
        }
        self.expected_raw_end =
            Some(packet.start + packet.samples.len() as f64 / packet.rate as f64);
        let samples = self.resampler.as_mut().unwrap().push(&packet.samples)?;
        self.append(samples, events)
    }
    fn append(&mut self, samples: Vec<f32>, events: &SyncSender<Event>) -> Result<(), String> {
        self.pending.extend(samples);
        while self.pending.len() >= self.chunk_frames {
            let tail = self.pending.split_off(self.chunk_frames);
            let chunk = std::mem::replace(&mut self.pending, tail);
            self.send(chunk, events)?;
        }
        Ok(())
    }
    fn send(&mut self, mut samples: Vec<f32>, events: &SyncSender<Event>) -> Result<(), String> {
        let source_count = samples.len();
        let start = self.start + self.emitted as f64 / SAMPLE_RATE as f64;
        // Native stop can flush callbacks beyond the configured deadline. Use
        // the same sample-grid rounding as MeetingSpool, including route-change
        // origins, and never emit a chunk that its bounded file would reject.
        let start_frame = (start * SAMPLE_RATE as f64).round() as u64;
        let remaining = self.limit_frames.saturating_sub(start_frame) as usize;
        samples.truncate(remaining);
        if !samples.is_empty() {
            emit(
                events,
                Event::Audio(Chunk {
                    track: self.track,
                    start,
                    samples,
                }),
            )?;
        }
        self.emitted += source_count;
        Ok(())
    }
    fn finish(&mut self, events: &SyncSender<Event>) -> Result<(), String> {
        if let Some(mut resampler) = self.resampler.take() {
            self.append(resampler.finish()?, events)?;
        }
        if !self.pending.is_empty() {
            let remaining = std::mem::take(&mut self.pending);
            self.send(remaining, events)?;
        }
        Ok(())
    }
}

/// Stateful anti-aliased conversion. Memory depends on FFT/chunk size, never meeting length.
pub(crate) struct StreamingResampler {
    converter: Option<Fft<f32>>,
    input: Vec<f32>,
    source_rate: usize,
    source_frames: u64,
    output_frames: u64,
    delay_remaining: usize,
}
impl StreamingResampler {
    pub(crate) fn new(rate: usize) -> Result<Self, String> {
        let converter = if rate == SAMPLE_RATE {
            None
        } else {
            let (mut a, mut b) = (rate, SAMPLE_RATE);
            while b != 0 {
                (a, b) = (b, a % b);
            }
            let unit = 2 * rate / a;
            Some(
                Fft::new_custom(
                    rate,
                    SAMPLE_RATE,
                    1_024usize.div_ceil(unit) * unit,
                    1,
                    1,
                    WindowFunction::BlackmanHarris2,
                    FixedSync::Input,
                )
                .map_err(|error| error.to_string())?,
            )
        };
        let delay_remaining = converter.as_ref().map_or(0, Resampler::output_delay);
        Ok(Self {
            converter,
            input: vec![],
            source_rate: rate,
            source_frames: 0,
            output_frames: 0,
            delay_remaining,
        })
    }
    pub(crate) fn push(&mut self, samples: &[f32]) -> Result<Vec<f32>, String> {
        self.source_frames += samples.len() as u64;
        let Some(converter) = &mut self.converter else {
            self.output_frames += samples.len() as u64;
            return Ok(samples.to_vec());
        };
        self.input.extend_from_slice(samples);
        let mut output = vec![];
        let mut consumed = 0;
        while self.input.len() - consumed >= converter.input_frames_next() {
            let count = converter.input_frames_next();
            let input = InterleavedSlice::new(&self.input[consumed..consumed + count], 1, count)
                .map_err(|e| e.to_string())?;
            let block = converter.process(&input, None).map_err(|e| e.to_string())?;
            output.extend(block.take_data());
            consumed += count;
        }
        self.input.drain(..consumed);
        let skip = self.delay_remaining.min(output.len());
        self.delay_remaining -= skip;
        output.drain(..skip);
        self.output_frames += output.len() as u64;
        Ok(output)
    }
    pub(crate) fn finish(&mut self) -> Result<Vec<f32>, String> {
        let wanted = self.source_frames * SAMPLE_RATE as u64 / self.source_rate as u64;
        let remaining = wanted.saturating_sub(self.output_frames) as usize;
        let Some(converter) = &mut self.converter else {
            return Ok(vec![]);
        };
        let mut output = vec![];
        if !self.input.is_empty() {
            let input = InterleavedSlice::new(&self.input, 1, self.input.len())
                .map_err(|e| e.to_string())?;
            let block = converter
                .process(&input, Some(&Indexing::new().partial_len(self.input.len())))
                .map_err(|e| e.to_string())?;
            output.extend(block.take_data());
        }
        while output.len() < remaining + self.delay_remaining {
            let input = InterleavedSlice::new(&[], 1, 0).map_err(|e| e.to_string())?;
            let block = converter
                .process(&input, Some(&Indexing::new().partial_len(0)))
                .map_err(|e| e.to_string())?;
            output.extend(block.take_data());
        }
        output.copy_within(self.delay_remaining..self.delay_remaining + remaining, 0);
        output.truncate(remaining);
        self.delay_remaining = 0;
        self.input.clear();
        self.output_frames += remaining as u64;
        Ok(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chunks_preserve_track_timing_and_final_partial_audio() {
        let (tx, rx) = mpsc::sync_channel(8);
        let mut mic = Pipeline::new(Track::Microphone, 1_600, Duration::from_secs(8 * 3600));
        let mut system = Pipeline::new(Track::System, 1_600, Duration::from_secs(8 * 3600));
        for index in 0..3 {
            mic.push(
                RawPacket {
                    track: Track::Microphone,
                    start: 0.2 + index as f64 * 0.05,
                    rate: SAMPLE_RATE,
                    samples: vec![0.1; 800],
                },
                &tx,
            )
            .unwrap();
            system
                .push(
                    RawPacket {
                        track: Track::System,
                        start: 0.25 + index as f64 * 0.05,
                        rate: SAMPLE_RATE,
                        samples: vec![0.2; 800],
                    },
                    &tx,
                )
                .unwrap();
        }
        mic.finish(&tx).unwrap();
        system.finish(&tx).unwrap();
        let chunks: Vec<_> = rx
            .try_iter()
            .filter_map(|event| {
                if let Event::Audio(c) = event {
                    Some(c)
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(chunks.len(), 4);
        for (track, start, sample) in [(Track::Microphone, 0.2, 0.1), (Track::System, 0.25, 0.2)] {
            let matching: Vec<_> = chunks.iter().filter(|c| c.track == track).collect();
            assert_eq!(matching[0].samples.len(), 1_600);
            assert_eq!(matching[1].samples.len(), 800);
            assert!((matching[0].start - start).abs() < 1e-9);
            assert!((matching[1].start - start - 0.1).abs() < 1e-9);
            assert!(matching
                .iter()
                .all(|c| c.samples.iter().all(|v| (*v - sample).abs() < 1e-6)));
        }
    }
    #[test]
    fn streaming_resampling_is_continuous_and_bounded() {
        for rate in [8_000, 44_100, 48_000, 96_000] {
            let input: Vec<_> = (0..rate * 2 + 31)
                .map(|i| (i as f32 * 1_000.0 * std::f32::consts::TAU / rate as f32).sin() * 0.5)
                .collect();
            let mut resampler = StreamingResampler::new(rate).unwrap();
            let mut output = vec![];
            for block in input.chunks(733) {
                output.extend(resampler.push(block).unwrap());
                assert!(
                    resampler.input.len()
                        < resampler.converter.as_ref().unwrap().input_frames_next()
                );
            }
            output.extend(resampler.finish().unwrap());
            assert_eq!(output.len(), input.len() * SAMPLE_RATE / rate);
            let mean_error = output
                .iter()
                .enumerate()
                .skip(200)
                .take(output.len() - 400)
                .map(|(i, v)| {
                    (v - (i as f32 * 1_000.0 * std::f32::consts::TAU / SAMPLE_RATE as f32).sin()
                        * 0.5)
                        .abs()
                })
                .sum::<f32>()
                / (output.len() - 400) as f32;
            assert!(mean_error < 0.005, "{rate}: {mean_error}");
        }
    }
    #[test]
    fn a_slow_consumer_is_an_error_not_dropped_audio() {
        let (tx, _rx) = mpsc::sync_channel(1);
        let mut pipeline = Pipeline::new(Track::Microphone, 1_600, Duration::from_secs(8 * 3600));
        assert!(pipeline
            .push(
                RawPacket {
                    track: Track::Microphone,
                    start: 0.0,
                    rate: SAMPLE_RATE,
                    samples: vec![0.1; 3_200]
                },
                &tx
            )
            .is_err());
    }
    #[test]
    fn maximum_duration_clips_crossing_tail_and_ignores_late_callbacks() {
        for track in [Track::Microphone, Track::System] {
            let (tx, rx) = mpsc::sync_channel(8);
            let mut pipeline = Pipeline::new(track, 1600, Duration::from_secs(1));
            // Native callbacks queued during stop cross the deadline. The valid
            // prefix must survive; the late suffix must never reach the spool.
            for (start, count, value) in [(0.95, 1200, 0.25), (1.025, 800, 0.5)] {
                pipeline
                    .push(
                        RawPacket {
                            track,
                            start,
                            rate: SAMPLE_RATE,
                            samples: vec![value; count],
                        },
                        &tx,
                    )
                    .unwrap();
            }
            pipeline.finish(&tx).unwrap();
            let audio: Vec<_> = rx
                .try_iter()
                .filter_map(|event| match event {
                    Event::Audio(chunk) => Some(chunk),
                    _ => None,
                })
                .collect();
            assert_eq!(audio.len(), 1);
            assert_eq!(audio[0].start, 0.95);
            assert_eq!(audio[0].samples, vec![0.25; 800]);
            let dir = std::env::temp_dir()
                .join(format!("pressay-capture-limit-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&dir).unwrap();
            let mut spool =
                pressay_core::analysis::MeetingSpool::new(&dir, Duration::from_secs(1)).unwrap();
            spool.append(audio[0].start, &audio[0].samples).unwrap();
            assert_eq!(spool.duration(), Duration::from_secs(1));
            drop(spool);
            std::fs::remove_dir(dir).unwrap();
        }
    }
    #[test]
    fn maximum_duration_keeps_exact_endpoint_and_resampled_partial_flush() {
        for rate in [16000, 44100, 48000] {
            let (tx, rx) = mpsc::sync_channel(8);
            let mut pipeline = Pipeline::new(Track::System, 1600, Duration::from_secs(1));
            // Two packets end exactly at one second; a third is entirely late.
            for index in 0..3 {
                pipeline
                    .push(
                        RawPacket {
                            track: Track::System,
                            start: 0.9 + index as f64 * 0.05,
                            rate,
                            samples: vec![0.25; rate / 20],
                        },
                        &tx,
                    )
                    .unwrap();
            }
            pipeline.finish(&tx).unwrap();
            let audio: Vec<_> = rx
                .try_iter()
                .filter_map(|event| match event {
                    Event::Audio(chunk) => Some(chunk),
                    _ => None,
                })
                .collect();
            assert_eq!(
                audio.iter().map(|c| c.samples.len()).sum::<usize>(),
                1600,
                "rate {rate}"
            );
            assert!(audio
                .iter()
                .all(|c| (c.start * 16000.).round() as usize + c.samples.len() <= 16000));
            assert!(audio.iter().all(|c| !c.samples.is_empty()));
        }
    }
}
