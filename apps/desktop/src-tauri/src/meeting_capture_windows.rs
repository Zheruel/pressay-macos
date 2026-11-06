//! CPAL's WASAPI host explicitly enables AUDCLNT_STREAMFLAGS_LOOPBACK when an
//! output endpoint is opened as an input stream. No Stereo Mix device is required.
use super::*;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SampleFormat, SizedSample};

pub(super) struct Backend {
    streams: Vec<cpal::Stream>,
    host: cpal::Host,
    output_name: Option<String>,
    next_route_check: Instant,
}
impl Backend {
    pub(super) fn start(
        config: &Config,
        origin: Instant,
        sender: RawSender,
        events: &SyncSender<Event>,
    ) -> Result<Self, String> {
        let host = cpal::host_from_id(cpal::HostId::Wasapi).map_err(|error| error.to_string())?;
        let microphone = if let Some(name) = &config.input_device {
            host.input_devices()
                .map_err(|error| error.to_string())?
                .find(|device| device.name().is_ok_and(|candidate| &candidate == name))
                .ok_or("Selected meeting microphone is unavailable")?
        } else {
            host.default_input_device()
                .ok_or("No meeting microphone is available")?
        };
        let mic_format = microphone
            .default_input_config()
            .map_err(|error| error.to_string())?;
        let mic = make_stream(
            &microphone,
            mic_format,
            Track::Microphone,
            origin,
            sender.clone(),
        )?;
        let mut backend = Self {
            streams: vec![mic],
            host,
            output_name: None,
            next_route_check: Instant::now() + Duration::from_secs(2),
        };
        if config.capture_system_audio {
            let output = backend
                .host
                .default_output_device()
                .ok_or("No default Windows playback endpoint is available for loopback capture")?;
            backend.output_name = Some(output.name().map_err(|error| error.to_string())?);
            let format = output
                .default_output_config()
                .map_err(|error| error.to_string())?;
            backend
                .streams
                .push(make_stream(&output, format, Track::System, origin, sender)?);
        }
        for stream in &backend.streams {
            stream
                .play()
                .map_err(|error| format!("Could not start WASAPI meeting audio: {error}"))?;
        }
        if config.echo_cancellation {
            emit(events, Event::Warning("WASAPI meeting capture does not enable microphone echo cancellation. Use headphones to keep call audio out of your microphone track.".into()))?;
        }
        Ok(backend)
    }
    pub(super) fn check(&mut self) -> Result<(), String> {
        if Instant::now() >= self.next_route_check {
            self.next_route_check = Instant::now() + Duration::from_secs(2);
            if let Some(original) = &self.output_name {
                let current = self
                    .host
                    .default_output_device()
                    .and_then(|device| device.name().ok());
                if current.as_ref() != Some(original) {
                    return Err("The Windows playback endpoint changed. Meeting capture stopped; restart it to capture the new output.".into());
                }
            }
        }
        Ok(())
    }
    pub(super) fn stop(&mut self, _graceful: bool) -> Result<(), String> {
        self.streams.clear();
        Ok(())
    }
}
impl Drop for Backend {
    fn drop(&mut self) {
        self.streams.clear();
    }
}

fn make_stream(
    device: &cpal::Device,
    format: cpal::SupportedStreamConfig,
    track: Track,
    origin: Instant,
    sender: RawSender,
) -> Result<cpal::Stream, String> {
    let rate = format.sample_rate().0 as usize;
    let channels = format.channels() as usize;
    if !(8_000..=192_000).contains(&rate) || !(1..=32).contains(&channels) {
        return Err("Unsupported WASAPI meeting audio format".into());
    }
    let config = format.config();
    let result = match format.sample_format() {
        SampleFormat::I8 => stream::<i8>(device, &config, track, origin, sender),
        SampleFormat::I16 => stream::<i16>(device, &config, track, origin, sender),
        SampleFormat::I24 => stream::<cpal::I24>(device, &config, track, origin, sender),
        SampleFormat::I32 => stream::<i32>(device, &config, track, origin, sender),
        SampleFormat::I64 => stream::<i64>(device, &config, track, origin, sender),
        SampleFormat::U8 => stream::<u8>(device, &config, track, origin, sender),
        SampleFormat::U16 => stream::<u16>(device, &config, track, origin, sender),
        SampleFormat::U32 => stream::<u32>(device, &config, track, origin, sender),
        SampleFormat::U64 => stream::<u64>(device, &config, track, origin, sender),
        SampleFormat::F32 => stream::<f32>(device, &config, track, origin, sender),
        SampleFormat::F64 => stream::<f64>(device, &config, track, origin, sender),
        other => return Err(format!("Unsupported WASAPI sample format: {other}")),
    };
    result.map_err(|error| format!("Could not open WASAPI meeting audio: {error}"))
}

fn stream<T: SizedSample>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    track: Track,
    origin: Instant,
    sender: RawSender,
) -> Result<cpal::Stream, cpal::BuildStreamError>
where
    f32: FromSample<T>,
{
    let channels = config.channels as usize;
    let rate = config.sample_rate.0 as usize;
    let errors = sender.failure.clone();
    device.build_input_stream(
        config,
        move |data: &[T], info: &cpal::InputCallbackInfo| {
            if !data.len().is_multiple_of(channels) {
                sender
                    .failure
                    .set("WASAPI returned incomplete audio frames");
                return;
            }
            let timestamp = info.timestamp();
            let latency = timestamp
                .callback
                .duration_since(&timestamp.capture)
                .unwrap_or_default();
            let start = origin.elapsed().saturating_sub(latency).as_secs_f64();
            for (index, block) in data.chunks(RAW_FRAMES * channels).enumerate() {
                let mut samples = Vec::with_capacity(block.len() / channels);
                for frame in block.chunks_exact(channels) {
                    let mut sample = 0.0;
                    for value in frame {
                        let value = value.to_sample::<f32>();
                        if !value.is_finite() {
                            sender.failure.set("WASAPI returned invalid samples");
                            return;
                        }
                        sample += value.clamp(-1.0, 1.0) / channels as f32;
                    }
                    samples.push(sample);
                }
                sender.send(RawPacket {
                    track,
                    start: start + (index * RAW_FRAMES) as f64 / rate as f64,
                    rate,
                    samples,
                });
            }
        },
        move |error| {
            errors.set(format!("WASAPI meeting device failed: {error}"));
        },
        None,
    )
}
