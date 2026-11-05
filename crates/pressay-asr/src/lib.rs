//! The native ASR process boundary. Audio is 16 kHz, mono, little-endian f32.
//! This crate does not download models, capture audio or depend on a UI runtime.
//! A host owns exactly one worker, kills it on cancellation/timeout, and waits
//! for exit before starting a replacement. Keep this blocking API off UI threads.

use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use std::{
    ffi::{c_char, c_int, c_void, CStr, CString},
    io::{self, BufRead, Read, Write},
    marker::PhantomData,
    path::{Path, PathBuf},
    ptr::NonNull,
    rc::Rc,
    time::Instant,
};

pub const SAMPLE_RATE: usize = 16_000;
pub const MAX_SAMPLES: usize = SAMPLE_RATE * 60;
// Base64 PCM plus a small JSON envelope. Bound allocation before parsing JSON.
pub const MAX_REQUEST_BYTES: usize = MAX_SAMPLES * 4 / 3 * 4 + 1024;
pub const MAX_REPLY_BYTES: usize = 1_048_576;

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct Transcript {
    pub text: String,
    pub truncated: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    pcm: String,
}

pub trait SpeechEngine {
    fn transcribe(&mut self, samples: &[f32]) -> Result<Transcript, String>;
}

/// Parse the existing Swift worker's JSONL request without trusting audio length,
/// float bit patterns, or JSON/base64 validity.
pub fn decode_request(line: &[u8]) -> Result<Vec<f32>, String> {
    if line.len() > MAX_REQUEST_BYTES {
        return Err("Oversized speech worker request".into());
    }
    let request: Request =
        serde_json::from_slice(line).map_err(|_| "Invalid speech worker request")?;
    let bytes = STANDARD
        .decode(request.pcm)
        .map_err(|_| "Invalid PCM encoding")?;
    if bytes.is_empty() || bytes.len() % 4 != 0 || bytes.len() / 4 > MAX_SAMPLES {
        return Err("Invalid audio length".into());
    }
    let samples: Vec<f32> = bytes
        .as_chunks::<4>()
        .0
        .iter()
        .map(|b| f32::from_le_bytes(*b))
        .collect();
    if samples.iter().any(|s| !s.is_finite()) {
        return Err("Invalid audio samples".into());
    }
    Ok(samples)
}

/// Serve serial requests until EOF. Recoverable request errors do not corrupt the
/// next request. An oversized line terminates the connection instead of draining
/// an unbounded stream supplied by a malfunctioning host.
pub fn serve(
    engine: &mut impl SpeechEngine,
    reader: &mut impl BufRead,
    writer: &mut impl Write,
) -> io::Result<()> {
    write_reply(writer, &serde_json::json!({"ready": true}))?;
    loop {
        let mut line = Vec::new();
        let count = (&mut *reader)
            .take((MAX_REQUEST_BYTES + 1) as u64)
            .read_until(b'\n', &mut line)?;
        if count == 0 {
            return Ok(());
        }
        if line.len() > MAX_REQUEST_BYTES {
            write_error(writer, "Oversized speech worker request")?;
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Oversized speech worker request",
            ));
        }
        let start = Instant::now();
        match decode_request(&line).and_then(|samples| engine.transcribe(&samples)) {
            Ok(result) => {
                let reply = serde_json::json!({
                    "text": result.text,
                    "truncated": result.truncated,
                    "seconds": start.elapsed().as_secs_f64(),
                });
                if serde_json::to_vec(&reply)?.len() >= MAX_REPLY_BYTES {
                    write_error(writer, "Oversized speech worker reply")?;
                } else {
                    write_reply(writer, &reply)?;
                }
            }
            Err(error) => write_error(writer, &error)?,
        }
    }
}

pub fn write_error(writer: &mut impl Write, message: &str) -> io::Result<()> {
    write_reply(writer, &serde_json::json!({"error": message}))
}

fn write_reply(writer: &mut impl Write, value: &impl Serialize) -> io::Result<()> {
    serde_json::to_writer(&mut *writer, value)?;
    writer.write_all(b"\n")?;
    writer.flush()
}

unsafe extern "C" {
    fn pressay_asr_load(
        library: *const c_char,
        model: *const c_char,
        orukeet: c_int,
        error: *mut c_char,
        error_size: usize,
    ) -> *mut c_void;
    fn pressay_asr_run(
        handle: *mut c_void,
        pcm: *const f32,
        count: usize,
        text: *mut *const c_char,
        error: *mut c_char,
        error_size: usize,
    ) -> c_int;
    fn pressay_asr_free(handle: *mut c_void);
}

/// Owns one native session. Deliberately neither Send nor Sync: the process host
/// supplies serialization and cancellation, not a mutex around a GPU session.
pub struct NativeEngine {
    handle: NonNull<c_void>,
    _thread_affinity: PhantomData<Rc<()>>,
}

impl NativeEngine {
    pub fn load(model_id: &str, model_path: &Path, runtime_root: &Path) -> Result<Self, String> {
        let library = runtime_library(model_id, runtime_root)?;
        let library = library
            .canonicalize()
            .map_err(|_| format!("Speech runtime is missing: {}", library.display()))?;
        let model = model_path
            .canonicalize()
            .map_err(|_| "Speech model is missing".to_owned())?;
        let library = utf8_path(&library)?;
        let model = utf8_path(&model)?;
        if model_id == "orukeet" {
            // This is a dedicated subprocess: no other threads read this value.
            // The pinned optimized runtime finds its backend beside its dylib.
            std::env::set_var("GGML_BACKEND_DL_PATH", runtime_root.join("orukeet/lib"));
        }
        let mut error = [0 as c_char; 1024];
        // SAFETY: NUL-terminated owned strings and writable bounded error buffer.
        let handle = unsafe {
            pressay_asr_load(
                library.as_ptr(),
                model.as_ptr(),
                i32::from(model_id == "orukeet"),
                error.as_mut_ptr(),
                error.len(),
            )
        };
        let handle = NonNull::new(handle).ok_or_else(|| native_error(&error))?;
        Ok(Self {
            handle,
            _thread_affinity: PhantomData,
        })
    }

    /// Compile backend pipelines before the ready handshake, just like the Mac
    /// worker. A failed warm-up is surfaced instead of claiming readiness.
    pub fn warm_up(&mut self) -> Result<(), String> {
        self.transcribe(&vec![0.0; SAMPLE_RATE]).map(|_| ())
    }
}

fn utf8_path(path: &Path) -> Result<CString, String> {
    // Windows canonicalization returns a verbatim prefix, which LoadLibraryExW
    // accepts; transcribe.cpp itself receives a UTF-8 path as its C API requires.
    CString::new(path.to_str().ok_or("Speech runtime path is not UTF-8")?)
        .map_err(|_| "Speech runtime path contains NUL".into())
}

pub fn runtime_library(model_id: &str, root: &Path) -> Result<PathBuf, String> {
    match model_id {
        "megaASR" => Err("Mega-ASR requires the bundled Apple Silicon Swift/MLX worker".into()),
        "orukeet" if cfg!(all(target_os = "macos", target_arch = "aarch64")) => {
            Ok(root.join("orukeet/lib/libnemo_speech_asr_c.dylib"))
        }
        "orukeet" => Err("The optimized Orukeet runtime is available only on Apple Silicon".into()),
        "moss" | "parakeetUltra" | "qwen3ASR17" => {
            let filename = if cfg!(target_os = "windows") {
                "transcribe.dll"
            } else if cfg!(target_os = "macos") {
                "libtranscribe.dylib"
            } else {
                "libtranscribe.so"
            };
            Ok(root.join("transcribe").join(filename))
        }
        _ => Err(format!("Unsupported speech model: {model_id}")),
    }
}

impl SpeechEngine for NativeEngine {
    fn transcribe(&mut self, samples: &[f32]) -> Result<Transcript, String> {
        if samples.is_empty()
            || samples.len() > MAX_SAMPLES
            || samples.iter().any(|s| !s.is_finite())
        {
            return Err("Invalid audio length or samples".into());
        }
        let mut error = [0 as c_char; 1024];
        let mut text = std::ptr::null();
        // SAFETY: handle is exclusively borrowed; audio/error buffers live until
        // return. Returned text belongs to handle until its next native call.
        let status = unsafe {
            pressay_asr_run(
                self.handle.as_ptr(),
                samples.as_ptr(),
                samples.len(),
                &mut text,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if status != 0 && status != 2 {
            return Err(native_error(&error));
        }
        let text = if text.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(text) }
                .to_str()
                .map_err(|_| "Speech engine returned invalid UTF-8")?
                .to_owned()
        };
        Ok(Transcript {
            text,
            truncated: status == 2,
        })
    }
}

fn native_error(buffer: &[c_char]) -> String {
    // Native adapter always NUL terminates its nonempty error buffer.
    let message = unsafe { CStr::from_ptr(buffer.as_ptr()) }.to_string_lossy();
    if message.is_empty() {
        "Speech engine failed".into()
    } else {
        message.into_owned()
    }
}

impl Drop for NativeEngine {
    fn drop(&mut self) {
        unsafe { pressay_asr_free(self.handle.as_ptr()) }
    }
}
