//! Native microphone capture. The CPAL stream is created and dropped on its own thread;
//! the audio callback only downmixes into bounded, fixed-size packets. Resampling and
//! caller callbacks never run on the audio thread.
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample, SampleFormat, SizedSample};
use rubato::{FftFixedIn, Resampler};
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

struct RawCapture {
    samples: Vec<f32>,
    sample_rate: usize,
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
    thread: Option<JoinHandle<Result<RawCapture, String>>>,
}

impl Capture {
    /// Observe a terminal native error without waiting for the user to release
    /// the talk key. The owner still needs joining through finish/cancel.
    pub fn is_finished(&self) -> bool {
        self.thread.as_ref().is_none_or(JoinHandle::is_finished)
    }

    pub fn start(
        device_name: Option<&str>,
        on_first_audio: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<Self, String> {
        let device_name = device_name.map(str::to_owned);
        let (commands, receive_commands) = mpsc::sync_channel(1);
        let (ready, receive_ready) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("pressay-microphone".into())
            .spawn(move || {
                let result = record(
                    device_name.as_deref(),
                    on_first_audio,
                    receive_commands,
                    &ready,
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
        let raw = thread
            .join()
            .map_err(|_| "Microphone thread stopped unexpectedly")??;
        // Native capture is already closed; no audio-device locks are held while converting.
        resample_mono(raw.samples, raw.sample_rate)
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

pub fn list_inputs() -> Result<Vec<String>, String> {
    let devices = cpal::default_host()
        .input_devices()
        .map_err(|error| format!("Could not list microphones: {error}"))?;
    let mut names = devices
        .map(|device| {
            device
                .name()
                .map_err(|error| format!("Could not read microphone name: {error}"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    names.sort();
    names.dedup();
    Ok(names)
}

fn record(
    device_name: Option<&str>,
    on_first_audio: Arc<dyn Fn() + Send + Sync>,
    commands: Receiver<Command>,
    ready: &SyncSender<Result<(), String>>,
) -> Result<RawCapture, String> {
    let host = cpal::default_host();
    let device = if let Some(name) = device_name {
        host.input_devices()
            .map_err(|error| format!("Could not list microphones: {error}"))?
            .find(|device| device.name().is_ok_and(|candidate| candidate == name))
            .ok_or_else(|| format!("Microphone ‘{name}’ is unavailable. Choose another input."))?
    } else {
        host.default_input_device()
            .ok_or("No microphone is available")?
    };
    let supported = device
        .default_input_config()
        .map_err(|error| format!("Could not read microphone format: {error}"))?;
    let sample_rate = supported.sample_rate().0 as usize;
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
    let mut samples = Vec::with_capacity(sample_rate * 2);
    let mut first_audio = true;
    loop {
        match commands.try_recv() {
            Ok(Command::Finish) => {
                // Drop before draining: no callback can append after the capture boundary.
                drop(stream);
                check_failure(&failure, &receive_errors)?;
                for packet in receive_packets.try_iter() {
                    append_packet(&mut samples, packet, sample_rate)?;
                }
                if samples.is_empty() {
                    return Err(
                        "No microphone audio arrived. Check access and your input device.".into(),
                    );
                }
                return Ok(RawCapture {
                    samples,
                    sample_rate,
                });
            }
            Ok(Command::Cancel) | Err(TryRecvError::Disconnected) => {
                return Err("Recording cancelled".into())
            }
            Err(TryRecvError::Empty) => {}
        }
        check_failure(&failure, &receive_errors)?;
        if started.elapsed() >= Duration::from_secs(MAX_SECONDS as u64) {
            return Err("Dictation exceeded five minutes. Record a shorter dictation.".into());
        }
        if last_audio.elapsed() >= AUDIO_TIMEOUT {
            return Err(
                "No microphone audio arrived for five seconds. Check access and your input device."
                    .into(),
            );
        }
        match receive_packets.recv_timeout(POLL_INTERVAL) {
            Ok(packet) => {
                append_packet(&mut samples, packet, sample_rate)?;
                last_audio = Instant::now();
                if first_audio {
                    first_audio = false;
                    // Application callbacks (including UI events) cannot block CPAL's callback.
                    on_first_audio();
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err("Microphone stream stopped unexpectedly".into())
            }
        }
    }
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

fn append_packet(samples: &mut Vec<f32>, packet: Packet, sample_rate: usize) -> Result<(), String> {
    let limit = sample_rate * MAX_SECONDS;
    if packet.len > PACKET_FRAMES || samples.len().saturating_add(packet.len) > limit {
        return Err("Dictation exceeded five minutes. Record a shorter dictation.".into());
    }
    if samples.capacity() - samples.len() < packet.len {
        // Cap allocation growth too, rather than letting Vec double near the five-minute limit.
        let additional = (sample_rate * 10)
            .max(packet.len)
            .min(limit - samples.len());
        samples
            .try_reserve_exact(additional)
            .map_err(|_| "Not enough memory to capture microphone audio")?;
    }
    samples.extend_from_slice(&packet.samples[..packet.len]);
    Ok(())
}

fn resample_mono(samples: Vec<f32>, sample_rate: usize) -> Result<Vec<f32>, String> {
    validate_format(sample_rate, 1)?;
    if samples.is_empty()
        || samples.len() > sample_rate * MAX_SECONDS
        || samples.iter().any(|s| !s.is_finite())
    {
        return Err("Recording has no valid microphone audio".into());
    }
    if sample_rate == OUTPUT_RATE {
        return Ok(samples);
    }
    let wanted = samples.len() * OUTPUT_RATE / sample_rate;
    if wanted == 0 {
        return Err("Recording is too short".into());
    }
    // FFT resampling includes a low-pass filter. Linear interpolation or frame skipping
    // would fold frequencies above 8 kHz into the speech band when downsampling.
    // Choose an even number of rational-rate units. Odd FFT output lengths have a
    // half-sample filter delay, which rubato's integer output_delay cannot remove.
    let mut a = sample_rate;
    let mut b = OUTPUT_RATE;
    while b != 0 {
        (a, b) = (b, a % b);
    }
    let even_input_unit = 2 * sample_rate / a;
    let chunk_size = 1_024usize.div_ceil(even_input_unit) * even_input_unit;
    let mut resampler = FftFixedIn::<f32>::new(sample_rate, OUTPUT_RATE, chunk_size, 1, 1)
        .map_err(|error| format!("Could not initialize microphone conversion: {error}"))?;
    let delay = resampler.output_delay();
    let mut output = Vec::with_capacity(wanted + delay + resampler.output_frames_max());
    let mut offset = 0;
    while samples.len() - offset >= resampler.input_frames_next() {
        let needed = resampler.input_frames_next();
        let converted = resampler
            .process(&[&samples[offset..offset + needed]], None)
            .map_err(|error| format!("Microphone conversion failed: {error}"))?;
        output.extend_from_slice(&converted[0]);
        offset += needed;
    }
    if offset < samples.len() {
        let converted = resampler
            .process_partial(Some(&[&samples[offset..]]), None)
            .map_err(|error| format!("Microphone conversion failed: {error}"))?;
        output.extend_from_slice(&converted[0]);
    }
    while output.len() < wanted + delay {
        let converted = resampler
            .process_partial::<&[f32]>(None, None)
            .map_err(|error| format!("Microphone conversion failed: {error}"))?;
        output.extend_from_slice(&converted[0]);
    }
    // Remove filter latency and zero-padding without changing the recorded duration.
    output.copy_within(delay..delay + wanted, 0);
    output.truncate(wanted);
    Ok(output)
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
                    Command::Finish => Ok(RawCapture {
                        samples: vec![0.25; 100],
                        sample_rate: OUTPUT_RATE,
                    }),
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
    fn five_minute_sample_bound_never_accepts_a_truncated_packet() {
        let mut samples = vec![0.0; 16_000 * MAX_SECONDS - 1];
        let packet = Packet {
            samples: [0.5; PACKET_FRAMES],
            len: 2,
        };
        assert!(append_packet(&mut samples, packet, 16_000).is_err());
        assert_eq!(samples.len(), 16_000 * MAX_SECONDS - 1);
        assert_eq!(samples.last(), Some(&0.0));
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
