use base64::{engine::general_purpose::STANDARD, Engine as _};
use pressay_asr::{
    decode_request, runtime_library, serve, NativeEngine, SpeechEngine, Transcript,
    MAX_REPLY_BYTES, MAX_REQUEST_BYTES, MAX_SAMPLES,
};
use serde_json::{json, Value};
use std::{io::Cursor, path::Path, process::Command};

fn request(samples: &[f32]) -> Vec<u8> {
    let pcm: Vec<u8> = samples
        .iter()
        .flat_map(|sample| sample.to_le_bytes())
        .collect();
    let mut bytes = serde_json::to_vec(&json!({"pcm": STANDARD.encode(pcm)})).unwrap();
    bytes.push(b'\n');
    bytes
}

struct Engine {
    calls: Vec<Vec<f32>>,
    fail: bool,
    text: String,
    truncated: bool,
}

impl Default for Engine {
    fn default() -> Self {
        Self {
            calls: vec![],
            fail: false,
            text: "Zagreb, 日本語.".into(),
            truncated: false,
        }
    }
}

impl SpeechEngine for Engine {
    fn transcribe(&mut self, samples: &[f32]) -> Result<Transcript, String> {
        self.calls.push(samples.to_vec());
        if self.fail {
            return Err("Native engine failed".into());
        }
        Ok(Transcript {
            text: self.text.clone(),
            truncated: self.truncated,
        })
    }
}

fn replies(bytes: &[u8]) -> Vec<Value> {
    bytes
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
        .map(|line| serde_json::from_slice(line).unwrap())
        .collect()
}

#[test]
fn preserves_little_endian_audio_and_unicode_across_consecutive_jobs() {
    let first = vec![0.0, -1.0, 0.75, f32::MIN_POSITIVE];
    let second = vec![0.1; 160];
    let input = [request(&first), request(&second)].concat();
    let mut engine = Engine::default();
    let mut output = vec![];
    serve(&mut engine, &mut Cursor::new(input), &mut output).unwrap();
    assert_eq!(engine.calls, vec![first, second]);
    let results = replies(&output);
    assert_eq!(results.len(), 3);
    assert_eq!(results[0], json!({"ready": true}));
    assert_eq!(results[1]["text"], "Zagreb, 日本語.");
    assert_eq!(results[2]["truncated"], false);
    assert!(results[1]["seconds"].as_f64().unwrap() >= 0.0);
}

#[test]
fn rejects_invalid_audio_before_native_code() {
    for line in [
        b"not-json".as_slice(),
        b"{}",
        br#"{"pcm":""}"#,
        br#"{"pcm":"bad!"}"#,
        br#"{"pcm":"AA=="}"#,
        br#"{"pcm":12}"#,
        br#"{"pcm":"AAAAAA==","extra":true}"#,
    ] {
        assert!(decode_request(line).is_err(), "accepted {line:?}");
    }
    for sample in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
        assert!(decode_request(&request(&[sample])).is_err());
    }
    let input = [b"{}\n".to_vec(), request(&[f32::NAN]), request(&[0.5])].concat();
    let mut engine = Engine::default();
    let mut output = vec![];
    serve(&mut engine, &mut Cursor::new(input), &mut output).unwrap();
    assert_eq!(engine.calls, vec![vec![0.5]]);
    let results = replies(&output);
    assert!(results[1].get("error").is_some());
    assert!(results[2].get("error").is_some());
    assert_eq!(results[3]["text"], engine.text);
}

#[test]
fn bounds_pcm_and_request_memory() {
    assert_eq!(
        decode_request(&request(&vec![0.0; MAX_SAMPLES]))
            .unwrap()
            .len(),
        MAX_SAMPLES
    );
    assert!(decode_request(&request(&vec![0.0; MAX_SAMPLES + 1])).is_err());
    let mut reader = Cursor::new(vec![b' '; MAX_REQUEST_BYTES + 100]);
    let mut engine = Engine::default();
    let mut output = vec![];
    assert!(serve(&mut engine, &mut reader, &mut output).is_err());
    assert_eq!(reader.position(), MAX_REQUEST_BYTES as u64 + 1);
    assert!(engine.calls.is_empty());
    assert_eq!(
        replies(&output)[1]["error"],
        "Oversized speech worker request"
    );
}

#[test]
fn distinguishes_truncation_from_native_failure() {
    let mut engine = Engine {
        truncated: true,
        ..Engine::default()
    };
    let mut output = vec![];
    serve(&mut engine, &mut Cursor::new(request(&[0.5])), &mut output).unwrap();
    assert_eq!(replies(&output)[1]["truncated"], true);
    engine.fail = true;
    output.clear();
    serve(&mut engine, &mut Cursor::new(request(&[0.5])), &mut output).unwrap();
    let result = replies(&output);
    assert_eq!(result[1]["error"], "Native engine failed");
    assert!(result[1].get("text").is_none());
}

#[test]
fn refuses_oversized_native_reply() {
    let mut engine = Engine {
        text: "a".repeat(MAX_REPLY_BYTES),
        ..Engine::default()
    };
    let mut output = vec![];
    serve(&mut engine, &mut Cursor::new(request(&[0.5])), &mut output).unwrap();
    assert!(output.len() < 128);
    assert_eq!(
        replies(&output)[1]["error"],
        "Oversized speech worker reply"
    );
}

#[test]
fn missing_runtime_and_unsupported_models_are_explicit_errors() {
    assert!(NativeEngine::load(
        "moss",
        Path::new("/missing/model"),
        Path::new("/missing/runtime")
    )
    .is_err());
    assert!(runtime_library("megaASR", Path::new("runtime"))
        .unwrap_err()
        .contains("Swift/MLX"));
    assert!(runtime_library("unknown", Path::new("runtime")).is_err());
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    assert!(runtime_library("orukeet", Path::new("runtime")).is_err());
}

#[test]
fn executable_fails_with_json_instead_of_false_readiness() {
    let output = Command::new(env!("CARGO_BIN_EXE_pressay-asr-worker"))
        .args(["moss", "/missing/model", "/missing/runtime"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    let results = replies(&output.stdout);
    assert_eq!(results.len(), 1);
    assert!(results[0]["error"]
        .as_str()
        .unwrap()
        .contains("runtime is missing"));
    assert!(results[0].get("ready").is_none());
}

#[test]
fn language_is_per_request_and_invalid_hints_never_reach_the_engine() {
    #[derive(Default)]
    struct LanguageEngine(Vec<Option<String>>);
    impl SpeechEngine for LanguageEngine {
        fn transcribe(&mut self, _: &[f32]) -> Result<Transcript, String> {
            unreachable!()
        }
        fn transcribe_with_language(
            &mut self,
            _: &[f32],
            language: Option<&str>,
        ) -> Result<Transcript, String> {
            self.0.push(language.map(str::to_string));
            Ok(Transcript {
                text: "fixture".into(),
                truncated: false,
            })
        }
    }
    let mut input = request(&[0.5]);
    for language in ["hr", "auto", "yue", "", "english", "e\0n", "EN", "../en"] {
        let mut line: Value = serde_json::from_slice(&request(&[0.5])).unwrap();
        line["language"] = json!(language);
        input.extend(serde_json::to_vec(&line).unwrap());
        input.push(b'\n');
    }
    let mut engine = LanguageEngine::default();
    let mut output = vec![];
    serve(&mut engine, &mut Cursor::new(input), &mut output).unwrap();
    assert_eq!(
        engine.0,
        vec![
            None,
            Some("hr".into()),
            Some("auto".into()),
            Some("yue".into())
        ]
    );
    assert_eq!(
        replies(&output)
            .iter()
            .filter(|reply| reply.get("error").is_some())
            .count(),
        5
    );
}

#[test]
fn whisper_accepts_full_capture_but_other_engines_remain_limited() {
    struct Whisper;
    impl SpeechEngine for Whisper {
        fn transcribe(&mut self, samples: &[f32]) -> Result<Transcript, String> {
            assert_eq!(samples.len(), pressay_asr::MAX_WHISPER_SAMPLES);
            Ok(Transcript {
                text: "full clip".into(),
                truncated: false,
            })
        }
        fn max_samples(&self) -> usize {
            pressay_asr::MAX_WHISPER_SAMPLES
        }
    }
    let input = request(&vec![0.; pressay_asr::MAX_WHISPER_SAMPLES]);
    assert!(input.len() < 32 * 1024 * 1024);
    let mut output = vec![];
    serve(&mut Whisper, &mut Cursor::new(&input), &mut output).unwrap();
    assert_eq!(replies(&output)[1]["text"], "full clip");
    output.clear();
    let mut regular = Engine::default();
    serve(&mut regular, &mut Cursor::new(&input), &mut output).unwrap();
    assert!(regular.calls.is_empty());
    assert_eq!(replies(&output)[1]["error"], "Invalid audio length");
}

#[cfg(unix)]
#[test]
fn native_adapter_passes_language_and_gates_formatting_against_actual_abi() {
    struct Temp(std::path::PathBuf);
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let temp = Temp(std::env::temp_dir().join(format!(
        "pressay-native-options-{}-{unique}",
        std::process::id()
    )));
    std::fs::create_dir_all(temp.0.join("transcribe")).unwrap();
    let model = temp.0.join("public-fixture.gguf");
    std::fs::write(&model, b"not a real model").unwrap();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let output = Command::new("c++")
        .args(["-shared", "-fPIC", "-std=c++17", "-I"])
        .arg(root.join("../../Runtime/Sources/CNativeASR/vendor"))
        .arg(root.join("tests/fixtures/options_runtime.cpp"))
        .arg("-o")
        .arg(runtime_library("moss", &temp.0).unwrap())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    for (id, expected) in [
        ("funASRMLTNano", "hr:0:2:1"),
        ("whisperTurboGGML", "hr:0:0:1"),
        ("voxtralMini", "hr:0:0:1"),
        ("qwen3ASR06", "auto:0:0:1"),
    ] {
        let mut engine = NativeEngine::load(id, &model, &temp.0).unwrap();
        assert_eq!(
            engine
                .transcribe_with_language(&[0.1], Some("hr"))
                .unwrap()
                .text,
            expected
        );
        let fallback = engine.transcribe_with_language(&[0.1], Some("ja")).unwrap();
        assert!(fallback.text.starts_with("auto:"));
        if id == "whisperTurboGGML" {
            assert!(engine
                .transcribe(&vec![0.; pressay_asr::MAX_WHISPER_SAMPLES])
                .is_ok());
        } else {
            assert!(engine.transcribe(&vec![0.; MAX_SAMPLES + 1]).is_err());
        }
    }
}
