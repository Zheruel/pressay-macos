//! CPAL's WASAPI host explicitly enables AUDCLNT_STREAMFLAGS_LOOPBACK when an
//! output endpoint is opened as an input stream. No Stereo Mix device is required.
use super::cpal_input::make_stream;
use super::*;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

pub(super) struct Backend {
    streams: Vec<cpal::Stream>,
    host: cpal::Host,
    output_id: Option<String>,
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
        let microphone = crate::audio::selected_device(&host, config.input_device.as_deref())?;
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
            output_id: None,
            next_route_check: Instant::now() + Duration::from_secs(2),
        };
        if config.capture_system_audio {
            let output = backend
                .host
                .default_output_device()
                .ok_or("No default Windows playback endpoint is available for loopback capture")?;
            backend.output_id = Some(output.id().map_err(|error| error.to_string())?.to_string());
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
            if let Some(original) = &self.output_id {
                let current = self
                    .host
                    .default_output_device()
                    .and_then(|device| device.id().ok().map(|id| id.to_string()));
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
