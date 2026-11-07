#!/usr/bin/env python3
"""Mac/Linux synthetic quiet recording benchmark; private sparse PCM is deleted.
Reports wall time and sampled RSS (includes evictable mapped PCM pages).
This tests duration/memory behavior, not transcription or diarization accuracy.
"""
import argparse
import json
from pathlib import Path
import select
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--hours", type=int, choices=[3, 8], default=3)
parser.add_argument("--worker", type=Path, default=Path("target/debug/pressay-analysis-worker"))
parser.add_argument("--runtime", type=Path, required=True)
parser.add_argument("--model", type=Path, required=True)
args = parser.parse_args()
with tempfile.NamedTemporaryFile(suffix=".f32") as pcm, tempfile.TemporaryFile() as log:
    pcm.truncate(args.hours * 3600 * 16000 * 4)
    worker = subprocess.Popen([str(args.worker.resolve()), "diarize", str(args.model.resolve()), str(args.runtime.resolve())], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
    try:
        assert select.select([worker.stdout], [], [], 180)[0], "Model load timeout"
        ready = json.loads(worker.stdout.readline())
        assert ready.get("ready"), ready
        worker.stdin.write((json.dumps({"op": "diarize", "path": pcm.name}) + "\n").encode())
        worker.stdin.flush()
        started = time.monotonic()
        peak = 0
        while worker.poll() is None and time.monotonic() - started < 600:
            rss = subprocess.check_output(["ps", "-o", "rss=", "-p", str(worker.pid)], text=True).strip()
            peak = max(peak, int(rss or "0"))
            assert peak < 3_000_000, "Benchmark stopped above 3 GB RSS"
            if select.select([worker.stdout], [], [], 0.5)[0]:
                result = json.loads(worker.stdout.readline())
                assert result == {"result": []}, result
                print(json.dumps({"hours": args.hours, "seconds": round(time.monotonic() - started, 2), "peak_rss_kib": peak}))
                break
        else:
            raise AssertionError("Analysis did not complete within benchmark limit")
    finally:
        if worker.poll() is None:
            worker.kill()
        worker.wait()
