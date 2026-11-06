#!/usr/bin/env python3
"""Real public-model worker smoke; no microphone/private recordings required.
Run after building pressay-analysis-worker:
python3 crates/pressay-asr/tests/analysis_smoke.py --runtime apps/desktop/src-tauri/runtime \
  --models .build/analysis-models --samples .build/portable-asr/darwin-arm64/source/samples
"""
import argparse
import base64
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import wave


def read_wave(path):
    with wave.open(str(path), "rb") as wav:
        assert wav.getframerate() == 16000 and wav.getnchannels() == 1 and wav.getsampwidth() == 2
        raw = wav.readframes(wav.getnframes())
    return b"".join(struct.pack("<f", value / 32768.0) for (value,) in struct.iter_unpack("<h", raw))


class Worker:
    def __init__(self, args, mode, model):
        self.log = tempfile.TemporaryFile()
        self.process = subprocess.Popen([str(args.worker.resolve()), mode, str((args.models / model).resolve()), str(args.runtime.resolve())], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        ready = self.reply()
        assert ready == {"ready": True, "frame_samples": 512}, ready

    def reply(self):
        line = self.process.stdout.readline(32 * 1024 * 1024)
        if not line:
            self.log.seek(0)
            raise AssertionError(self.log.read().decode(errors="replace"))
        result = json.loads(line)
        assert "error" not in result, result
        return result

    def request(self, **request):
        self.process.stdin.write(json.dumps(request).encode() + b"\n")
        self.process.stdin.flush()
        return self.reply()["result"]

    def close(self):
        self.process.stdin.close()
        try:
            assert self.process.wait(timeout=10) == 0
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.log.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", type=Path, default=Path("target/debug/pressay-analysis-worker"))
    for name in ["runtime", "models", "samples"]:
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    jfk = read_wave(args.samples / "jfk.wav")
    vad = Worker(args, "vad", "silero-vad-v6.2-F32.gguf")
    try:
        def classify(data, chunk):
            probabilities = []
            for offset in range(0, len(data), chunk * 4):
                result = vad.request(op="feed", track=0, pcm=base64.b64encode(data[offset:offset + chunk * 4]).decode())
                assert result["first_frame"] == len(probabilities)
                probabilities.extend(result["probabilities"])
            probabilities.extend(vad.request(op="flush", track=0)["probabilities"])
            return probabilities
        reference = classify(jfk, 160000)
        vad.request(op="reset", track=0)
        streamed = classify(jfk, 777)
        assert reference == streamed, "VAD changed with input chunk boundaries"
        speech = sum(p >= 0.5 for p in streamed)
        assert speech / len(streamed) > 0.5, (speech, len(streamed))
        silence = vad.request(op="feed", track=1, pcm=base64.b64encode(bytes(16000 * 4)).decode())
        assert silence["first_frame"] == 0 and max(silence["probabilities"]) < 0.1, silence
        print(f"JFK VAD: {speech}/{len(streamed)} speech frames; independent silent track; chunk parity exact")
    finally:
        vad.close()
    diar = Worker(args, "diarize", "diar_streaming_sortformer_4spk-v2.1-F16.gguf")
    try:
        with tempfile.NamedTemporaryFile(suffix=".f32") as pcm:
            pcm.write(read_wave(args.samples / "sortformer-2spk-mix.wav"))
            pcm.flush()
            segments = diar.request(op="diarize", path=pcm.name)
        speakers = {s["speaker"] for s in segments}
        assert len(speakers) >= 2, segments
        assert all(0 <= s["start"] < s["end"] for s in segments), segments
        # Captured from the unmodified pinned runtime through its public C ABI.
        # The windowed frontend must preserve speaker identities and boundaries.
        reference = [(0.32, 2.40, 1), (7.36, 9.36, 1), (10.24, 10.64, 1),
                     (4.24, 6.64, 2), (9.76, 12.00, 2)]
        assert [(s["start"], s["end"], s["speaker"]) for s in segments] == reference, segments
        print(f"Sortformer public two-speaker sample: {len(segments)} segments, speakers {sorted(speakers)}")
    finally:
        diar.close()


if __name__ == "__main__":
    main()
