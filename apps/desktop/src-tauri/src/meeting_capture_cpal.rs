use super::*;
use cpal::traits::DeviceTrait;
use cpal::{FromSample, SampleFormat, SizedSample};

pub(super) fn make_stream(
    device: &cpal::Device,
    format: cpal::SupportedStreamConfig,
    track: Track,
    origin: Instant,
    sender: RawSender,
) -> Result<cpal::Stream, String> {
    let rate = format.sample_rate() as usize;
    let channels = format.channels() as usize;
    if !(8_000..=192_000).contains(&rate) || !(1..=32).contains(&channels) {
        return Err("This meeting audio format is not supported".into());
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
        SampleFormat::U24 => stream::<cpal::U24>(device, &config, track, origin, sender),
        SampleFormat::U32 => stream::<u32>(device, &config, track, origin, sender),
        SampleFormat::U64 => stream::<u64>(device, &config, track, origin, sender),
        SampleFormat::F32 => stream::<f32>(device, &config, track, origin, sender),
        SampleFormat::F64 => stream::<f64>(device, &config, track, origin, sender),
        other => return Err(format!("Unsupported meeting sample format: {other}")),
    };
    result.map_err(|error| format!("Could not open meeting audio: {error}"))
}

fn stream<T: SizedSample>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    track: Track,
    origin: Instant,
    sender: RawSender,
) -> Result<cpal::Stream, cpal::Error>
where
    f32: FromSample<T>,
{
    let channels = config.channels as usize;
    let rate = config.sample_rate as usize;
    let errors = sender.failure.clone();
    device.build_input_stream(
        *config,
        move |data: &[T], info: &cpal::InputCallbackInfo| {
            if !data.len().is_multiple_of(channels) {
                sender
                    .failure
                    .set("The meeting audio device returned incomplete frames");
                return;
            }
            let timestamp = info.timestamp();
            let latency = timestamp.callback.duration_since(timestamp.capture);
            let start = origin.elapsed().saturating_sub(latency).as_secs_f64();
            for (index, block) in data.chunks(RAW_FRAMES * channels).enumerate() {
                let mut samples = Vec::with_capacity(block.len() / channels);
                for frame in block.chunks_exact(channels) {
                    let mut sample = 0.0;
                    for value in frame {
                        let value = value.to_sample::<f32>();
                        if !value.is_finite() {
                            sender
                                .failure
                                .set("The meeting audio device returned invalid samples");
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
            errors.set(format!("The meeting audio device failed: {error}"));
        },
        None,
    )
}
