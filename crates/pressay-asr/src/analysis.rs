//! Blocking VAD/diarization adapter. Use only inside the isolated analysis worker.
use super::{native_error, runtime_library, utf8_path, write_reply};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use std::{
    ffi::{c_char, c_void},
    io::{self, BufRead, Read, Write},
    marker::PhantomData,
    path::Path,
    ptr::NonNull,
    rc::Rc,
};
const MAX_SAMPLES: usize = 160_000;
const MAX_REQUEST: usize = MAX_SAMPLES * 4 * 4 / 3 + 4096;
unsafe extern "C" {
    fn pressay_analysis_load(
        library: *const c_char,
        model: *const c_char,
        vad: bool,
        error: *mut c_char,
        size: usize,
    ) -> *mut c_void;
    fn pressay_analysis_free(handle: *mut c_void);
    fn pressay_analysis_vad(
        handle: *mut c_void,
        track: i32,
        op: i32,
        pcm: *const f32,
        n: i32,
        output: *mut f32,
        capacity: i32,
        count: *mut i32,
        first: *mut i64,
        error: *mut c_char,
        size: usize,
    ) -> i32;
    fn pressay_analysis_diarize(
        handle: *mut c_void,
        path: *const c_char,
        error: *mut c_char,
        size: usize,
    ) -> i32;
    fn pressay_analysis_segment(
        handle: *mut c_void,
        index: i32,
        start: *mut f64,
        end: *mut f64,
        speaker: *mut i32,
        confidence: *mut f32,
        error: *mut c_char,
        size: usize,
    ) -> i32;
}
#[derive(Debug, Serialize, Deserialize)]
pub struct VadResult {
    pub first_frame: u64,
    pub frame_samples: usize,
    pub probabilities: Vec<f32>,
}
#[derive(Debug, Serialize, Deserialize)]
pub struct SpeakerSegment {
    pub start: f64,
    pub end: f64,
    pub speaker: u32,
    pub confidence: Option<f32>,
}
pub struct Analysis {
    handle: NonNull<c_void>,
    _not_send: PhantomData<Rc<()>>,
}
impl Analysis {
    pub fn load(vad: bool, model: &Path, runtime: &Path) -> Result<Self, String> {
        let library = utf8_path(&runtime_library("moss", runtime)?)?;
        let model = utf8_path(model)?;
        let mut error = [0; 2048];
        let handle = unsafe {
            pressay_analysis_load(
                library.as_ptr(),
                model.as_ptr(),
                vad,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        Ok(Self {
            handle: NonNull::new(handle).ok_or_else(|| native_error(&error))?,
            _not_send: PhantomData,
        })
    }
    pub fn vad(
        &mut self,
        track: u8,
        samples: &[f32],
        flush: bool,
        reset: bool,
    ) -> Result<VadResult, String> {
        if track > 1 || samples.len() > MAX_SAMPLES || samples.iter().any(|s| !s.is_finite()) {
            return Err("Invalid VAD audio or track".into());
        }
        let mut probabilities = vec![0.; samples.len().div_ceil(512) + 1];
        let (mut count, mut first) = (0, 0);
        let mut error = [0; 2048];
        let status = unsafe {
            pressay_analysis_vad(
                self.handle.as_ptr(),
                track.into(),
                if reset {
                    2
                } else if flush {
                    1
                } else {
                    0
                },
                samples.as_ptr(),
                samples.len() as i32,
                probabilities.as_mut_ptr(),
                probabilities.len() as i32,
                &mut count,
                &mut first,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if status != 0 {
            return Err(native_error(&error));
        }
        probabilities.truncate(count as usize);
        if probabilities
            .iter()
            .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
        {
            return Err("Invalid VAD probability".into());
        }
        Ok(VadResult {
            first_frame: first as u64,
            frame_samples: 512,
            probabilities,
        })
    }
    pub fn diarize(&mut self, path: &Path) -> Result<Vec<SpeakerSegment>, String> {
        let duration = std::fs::metadata(path).map_err(|e| e.to_string())?.len() as f64 / 64000.;
        let path = utf8_path(path)?;
        let mut error = [0; 2048];
        let count = unsafe {
            pressay_analysis_diarize(
                self.handle.as_ptr(),
                path.as_ptr(),
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if count < 0 {
            return Err(native_error(&error));
        }
        let mut segments = Vec::with_capacity(count as usize);
        for i in 0..count {
            let (mut start, mut end, mut speaker, mut confidence) = (0., 0., 0, f32::NAN);
            let status = unsafe {
                pressay_analysis_segment(
                    self.handle.as_ptr(),
                    i,
                    &mut start,
                    &mut end,
                    &mut speaker,
                    &mut confidence,
                    error.as_mut_ptr(),
                    error.len(),
                )
            };
            if status != 0 {
                return Err(native_error(&error));
            }
            end = end.min(duration);
            if end > start {
                segments.push(SpeakerSegment {
                    start,
                    end,
                    speaker: speaker as u32,
                    confidence: confidence.is_finite().then_some(confidence),
                });
            }
        }
        Ok(segments)
    }
}
impl Drop for Analysis {
    fn drop(&mut self) {
        unsafe { pressay_analysis_free(self.handle.as_ptr()) };
    }
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Feed { track: u8, pcm: String },
    Flush { track: u8 },
    Reset { track: u8 },
    Diarize { path: String },
}
fn request(engine: &mut Analysis, line: &[u8]) -> Result<serde_json::Value, String> {
    let request: Request = serde_json::from_slice(line).map_err(|e| e.to_string())?;
    let value = match request {
        Request::Feed { track, pcm } => {
            let bytes = STANDARD.decode(pcm).map_err(|e| e.to_string())?;
            if bytes.is_empty() || bytes.len() % 4 != 0 || bytes.len() / 4 > MAX_SAMPLES {
                return Err("Invalid VAD PCM length".into());
            }
            let samples: Vec<f32> = bytes
                .as_chunks::<4>()
                .0
                .iter()
                .map(|b| f32::from_le_bytes(*b))
                .collect();
            serde_json::to_value(engine.vad(track, &samples, false, false)?)
        }
        Request::Flush { track } => serde_json::to_value(engine.vad(track, &[], true, false)?),
        Request::Reset { track } => serde_json::to_value(engine.vad(track, &[], false, true)?),
        Request::Diarize { path } => serde_json::to_value(engine.diarize(Path::new(&path))?),
    }
    .map_err(|e| e.to_string())?;
    Ok(serde_json::json!({"result":value}))
}
pub fn serve(
    engine: &mut Analysis,
    reader: &mut impl BufRead,
    writer: &mut impl Write,
) -> io::Result<()> {
    write_reply(
        writer,
        &serde_json::json!({"ready":true,"frame_samples":512}),
    )?;
    loop {
        let mut line = Vec::new();
        if reader
            .take((MAX_REQUEST + 1) as u64)
            .read_until(b'\n', &mut line)?
            == 0
        {
            return Ok(());
        }
        if line.len() > MAX_REQUEST || line.last() != Some(&b'\n') {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Oversized or incomplete analysis request",
            ));
        }
        let reply =
            request(engine, &line).unwrap_or_else(|error| serde_json::json!({"error":error}));
        write_reply(writer, &reply)?;
    }
}
