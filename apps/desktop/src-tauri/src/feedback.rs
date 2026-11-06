//! Prewarmed, best-effort playback of the same earcons shipped by the Mac app.
//! A cue is never queued for a cold device; expired commands are silent.
use cpal::{
    traits::{DeviceTrait, HostTrait, StreamTrait},
    FromSample, SampleFormat, SizedSample,
};
use rubato::{FftFixedIn, Resampler};
use std::{
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, SyncSender},
        Arc, Mutex, OnceLock,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

#[derive(Clone, Copy)]
pub enum Cue {
    Begin,
    Release,
    Cancel,
    Error,
}
impl Cue {
    fn index(self) -> usize {
        match self {
            Self::Begin => 0,
            Self::Release => 1,
            Self::Cancel => 2,
            Self::Error => 3,
        }
    }
    fn duration(self) -> Duration {
        Duration::from_millis([170, 160, 90, 200][self.index()])
    }
}
const QUEUE_MARGIN: Duration = Duration::from_millis(20);
const ASSETS: [&[u8]; 4] = [
    include_bytes!("../../../../Config/Sounds/dictation-begin.wav"),
    include_bytes!("../../../../Config/Sounds/dictation-release.wav"),
    include_bytes!("../../../../Config/Sounds/dictation-cancel.wav"),
    include_bytes!("../../../../Config/Sounds/dictation-error.wav"),
];
struct Playback {
    samples: Arc<Vec<[f32; 2]>>,
    expires: Instant,
}
struct Output {
    sender: SyncSender<Playback>,
    assets: Vec<Arc<Vec<[f32; 2]>>>,
    ready: Arc<AtomicBool>,
    latency_us: Arc<AtomicU64>,
}
fn output() -> &'static Mutex<Option<Output>> {
    static OUTPUT: OnceLock<Mutex<Option<Output>>> = OnceLock::new();
    OUTPUT.get_or_init(Default::default)
}
struct Worker {
    stop: Arc<AtomicBool>,
    thread: Mutex<Option<JoinHandle<()>>>,
}
static WORKER: OnceLock<Worker> = OnceLock::new();
pub fn initialize() {
    WORKER.get_or_init(|| {
        let stop = Arc::new(AtomicBool::new(false));
        let closing = stop.clone();
        let handle = thread::Builder::new()
            .name("pressay-feedback".into())
            .spawn(move || {
                while !closing.load(Ordering::Acquire) {
                    let failed = Arc::new(AtomicBool::new(false));
                    let stream = open_output(failed.clone()).ok();
                    while stream.is_some()
                        && !failed.load(Ordering::Acquire)
                        && !closing.load(Ordering::Acquire)
                    {
                        thread::sleep(Duration::from_millis(50));
                    }
                    *output().lock().unwrap() = None;
                    drop(stream);
                    for _ in 0..20 {
                        if closing.load(Ordering::Acquire) {
                            break;
                        }
                        thread::sleep(Duration::from_millis(50));
                    }
                }
            })
            .ok();
        Worker {
            stop,
            thread: Mutex::new(handle),
        }
    });
}
/// Returns a capture exclusion duration only when the already-running output
/// accepted this cue. Includes measured playback latency and bounded queue time.
pub fn cue(cue: Cue) -> Option<Duration> {
    let guard = output().lock().ok()?;
    let output = guard.as_ref()?;
    if !output.ready.load(Ordering::Acquire) {
        return None;
    }
    let latency = Duration::from_micros(output.latency_us.load(Ordering::Acquire));
    let playback = Playback {
        samples: output.assets[cue.index()].clone(),
        expires: Instant::now() + QUEUE_MARGIN,
    };
    output.sender.try_send(playback).ok()?;
    Some(cue.duration() + latency + QUEUE_MARGIN)
}
/// Join from a blocking shutdown task. No cue thread outlives explicit shutdown.
pub fn shutdown() {
    if let Some(worker) = WORKER.get() {
        worker.stop.store(true, Ordering::Release);
        if let Some(thread) = worker.thread.lock().unwrap().take() {
            let _ = thread.join();
        }
    }
}
fn open_output(failed: Arc<AtomicBool>) -> Result<cpal::Stream, String> {
    let device = cpal::default_host()
        .default_output_device()
        .ok_or("No audio output")?;
    let supported = device.default_output_config().map_err(|e| e.to_string())?;
    let mut config: cpal::StreamConfig = supported.clone().into();
    if config.channels == 0
        || config.channels > 32
        || !(8_000..=192_000).contains(&config.sample_rate.0)
    {
        return Err("Unsupported audio output".into());
    }
    if let cpal::SupportedBufferSize::Range { min, max } = supported.buffer_size() {
        config.buffer_size = cpal::BufferSize::Fixed(256u32.clamp(*min, *max));
    }
    let assets = ASSETS
        .iter()
        .map(|bytes| convert_asset(bytes, config.sample_rate.0 as usize).map(Arc::new))
        .collect::<Result<Vec<_>, _>>()?;
    let (sender, receive) = mpsc::sync_channel(1);
    let ready = Arc::new(AtomicBool::new(false));
    let latency = Arc::new(AtomicU64::new(0));
    macro_rules! stream {
        ($sample:ty) => {
            build_output::<$sample>(
                &device,
                &config,
                receive,
                ready.clone(),
                latency.clone(),
                failed,
            )
        };
    }
    let stream = match supported.sample_format() {
        SampleFormat::I8 => stream!(i8),
        SampleFormat::I16 => stream!(i16),
        SampleFormat::I24 => stream!(cpal::I24),
        SampleFormat::I32 => stream!(i32),
        SampleFormat::I64 => stream!(i64),
        SampleFormat::U8 => stream!(u8),
        SampleFormat::U16 => stream!(u16),
        SampleFormat::U32 => stream!(u32),
        SampleFormat::U64 => stream!(u64),
        SampleFormat::F32 => stream!(f32),
        SampleFormat::F64 => stream!(f64),
        _ => return Err("Unsupported audio output format".into()),
    }
    .map_err(|e| e.to_string())?;
    stream.play().map_err(|e| e.to_string())?;
    *output().lock().unwrap() = Some(Output {
        sender,
        assets,
        ready,
        latency_us: latency,
    });
    Ok(stream)
}
fn build_output<T: SizedSample + FromSample<f32>>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    receive: Receiver<Playback>,
    ready: Arc<AtomicBool>,
    latency: Arc<AtomicU64>,
    failed: Arc<AtomicBool>,
) -> Result<cpal::Stream, cpal::BuildStreamError> {
    let channels = config.channels as usize;
    let mut active: Option<Playback> = None;
    let mut offset = 0;
    let invalid = ready.clone();
    device.build_output_stream(
        config,
        move |data: &mut [T], info: &cpal::OutputCallbackInfo| {
            let timestamp = info.timestamp();
            let delay = timestamp
                .playback
                .duration_since(&timestamp.callback)
                .unwrap_or_default();
            latency.store(
                delay.as_micros().min(u64::MAX as u128) as u64,
                Ordering::Release,
            );
            ready.store(true, Ordering::Release);
            if let Ok(next) = receive.try_recv() {
                if next.expires >= Instant::now() {
                    active = Some(next);
                    offset = 0;
                }
            }
            for frame in data.chunks_mut(channels) {
                let pair = active
                    .as_ref()
                    .and_then(|playing| playing.samples.get(offset))
                    .copied()
                    .unwrap_or([0.0; 2]);
                for (channel, sample) in frame.iter_mut().enumerate() {
                    *sample = T::from_sample(if channels == 1 {
                        (pair[0] + pair[1]) * 0.5
                    } else if channel < 2 {
                        pair[channel]
                    } else {
                        0.0
                    });
                }
                offset = offset.saturating_add(1);
            }
        },
        move |_| {
            invalid.store(false, Ordering::Release);
            failed.store(true, Ordering::Release);
        },
        None,
    )
}
fn decode_asset(bytes: &[u8]) -> Result<Vec<[f32; 2]>, String> {
    if bytes.get(..4) != Some(b"RIFF") || bytes.get(8..12) != Some(b"WAVE") {
        return Err("Invalid cue WAV".into());
    }
    let mut offset = 12;
    let mut valid = false;
    while offset + 8 <= bytes.len() {
        let size = u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().unwrap()) as usize;
        let end = offset
            .checked_add(8)
            .and_then(|n| n.checked_add(size))
            .filter(|n| *n <= bytes.len())
            .ok_or("Truncated cue WAV")?;
        let data = &bytes[offset + 8..end];
        if &bytes[offset..offset + 4] == b"fmt " {
            valid = data.len() >= 16
                && data[0..2] == [1, 0]
                && data[2..4] == [2, 0]
                && u32::from_le_bytes(data[4..8].try_into().unwrap()) == 48_000
                && data[14..16] == [16, 0];
        }
        if &bytes[offset..offset + 4] == b"data" {
            if !valid || !data.len().is_multiple_of(4) {
                return Err("Unsupported cue WAV".into());
            }
            return Ok(data
                .as_chunks::<4>()
                .0
                .iter()
                .map(|v| {
                    [
                        i16::from_le_bytes([v[0], v[1]]) as f32 / 32768.0,
                        i16::from_le_bytes([v[2], v[3]]) as f32 / 32768.0,
                    ]
                })
                .collect());
        }
        offset = end + (size % 2);
    }
    Err("Missing cue audio".into())
}
fn convert_asset(bytes: &[u8], rate: usize) -> Result<Vec<[f32; 2]>, String> {
    let source = decode_asset(bytes)?;
    if rate == 48_000 {
        return Ok(source);
    }
    let mut converter =
        FftFixedIn::<f32>::new(48_000, rate, 1024, 2, 2).map_err(|e| e.to_string())?;
    let delay = converter.output_delay();
    let wanted = source.len() * rate / 48_000;
    let mut result = Vec::new();
    let mut offset = 0;
    while result.len() < wanted + delay {
        let count = converter.input_frames_next().min(source.len() - offset);
        let left: Vec<_> = source[offset..offset + count]
            .iter()
            .map(|v| v[0])
            .collect();
        let right: Vec<_> = source[offset..offset + count]
            .iter()
            .map(|v| v[1])
            .collect();
        let output = if count == 0 {
            converter.process_partial::<Vec<f32>>(None, None)
        } else {
            converter.process_partial(Some(&[left, right]), None)
        }
        .map_err(|e| e.to_string())?;
        result.extend(output[0].iter().zip(&output[1]).map(|(l, r)| [*l, *r]));
        offset += count;
    }
    Ok(result[delay..delay + wanted].to_vec())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn original_cues_preserve_duration_stereo_and_quiet_levels() {
        for (index, asset) in ASSETS.iter().enumerate() {
            for rate in [16_000, 44_100, 48_000, 96_000] {
                let samples = convert_asset(asset, rate).unwrap();
                assert_eq!(samples.len(), [170, 160, 90, 200][index] * rate / 1000);
                assert!(samples
                    .iter()
                    .flatten()
                    .all(|v| v.is_finite() && v.abs() < 0.08));
                assert!(samples.iter().any(|v| v[0] != v[1]));
            }
        }
        assert!(decode_asset(b"not wav").is_err());
    }
}
