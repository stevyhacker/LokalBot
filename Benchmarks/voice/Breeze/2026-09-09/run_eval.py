"""Bounded local Breeze/Kokoro evaluation; uses only synthetic fixtures.

Run with uv run --no-project run_eval.py baseline --scratch /private/tmp/...
or replace baseline with breeze. Weights and runtimes remain outside the app.
"""

import argparse
import array
import base64
import ctypes
import json
import math
import os
from pathlib import Path
import subprocess
import threading
import time
import urllib.request
import wave

ROOT = Path(__file__).resolve().parent
FIXTURE = json.loads((ROOT / "cases.json").read_text())
FIELDS = """user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size phys_footprint proc_start_abstime proc_exit_abstime child_user_time child_system_time child_pkg_idle_wkups child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten cpu_time_qos_default cpu_time_qos_maintenance cpu_time_qos_background cpu_time_qos_utility cpu_time_qos_legacy cpu_time_qos_user_initiated cpu_time_qos_user_interactive billed_system_time serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles billed_energy serviced_energy interval_max_phys_footprint runnable_time""".split()


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in FIELDS]


LIB = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
LIB.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
LIB.proc_pid_rusage.restype = ctypes.c_int


def memory(pid):
    usage = Usage()
    if LIB.proc_pid_rusage(pid, 4, ctypes.byref(usage)):
        return {"memory_error": ctypes.get_errno()}
    return {k: getattr(usage, k) for k in ("resident_size", "phys_footprint", "lifetime_max_phys_footprint")}


def save(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def audio_info(path):
    with wave.open(str(path)) as wav:
        assert wav.getsampwidth() == 2 and wav.getnchannels() == 1
        rate = wav.getframerate()
        samples = array.array("h", wav.readframes(wav.getnframes()))
    return {
        "sample_rate": rate, "samples": len(samples),
        "duration_s": len(samples) / rate,
        "peak_amplitude": max((abs(v) for v in samples), default=0) / 32768,
        "rms": math.sqrt(sum(v * v for v in samples) / max(1, len(samples))) / 32768,
        "clipped_fraction": sum(abs(v) >= 32767 for v in samples) / max(1, len(samples)),
    }


def baseline(args):
    model = Path.home() / "Library/Application Support/me.dotenv.LokalBot/sherpa-models/kokoro-multi-lang-v1_0"
    binary = Path("/Applications/LokalBot.app/Contents/Resources/sherpa-onnx/sherpa-onnx-offline-tts")
    common = [str(binary), "--debug=0", f"--kokoro-model={model}/model.onnx",
              f"--kokoro-voices={model}/voices.bin", f"--kokoro-tokens={model}/tokens.txt",
              f"--kokoro-data-dir={model}/espeak-ng-data",
              f"--kokoro-lexicon={model}/lexicon-us-en.txt,{model}/lexicon-zh.txt",
              "--num-threads=2", "--sid=3", "--kokoro-length-scale=1.000000"]
    report = {"engine": "Kokoro 82M", "voice": "af_heart", "threads": 2,
              "timing_scope": "new process through complete output WAV, matching current app engine", "rows": []}
    cases = [{"id": "reference", "text": FIXTURE["reference"]}] + [c for c in FIXTURE["cases"] if c["id"] != "directed"]
    for case in cases:
        output = ROOT / "audio" / f"kokoro_{case['id']}.wav"
        logfile = ROOT / "results" / f"kokoro_{case['id']}.log"
        peak = {}
        started = time.perf_counter()
        with logfile.open("w") as log:
            proc = subprocess.Popen(common + [f"--output-filename={output}", case["text"]], stdout=log, stderr=log)
            try:
                while proc.poll() is None:
                    for key, value in memory(proc.pid).items():
                        peak[key] = max(peak.get(key, 0), value)
                    if time.perf_counter() - started > args.timeout:
                        raise TimeoutError("Kokoro case deadline")
                    time.sleep(0.05)
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=10)
        elapsed = time.perf_counter() - started
        row = {"id": case["id"], "elapsed_s": elapsed, "returncode": proc.returncode, "memory": peak}
        if proc.returncode == 0:
            row.update(audio_info(output))
            row["rtf"] = elapsed / row["duration_s"]
        report["rows"].append(row)
        save(ROOT / "results" / "kokoro.json", report)
        print(json.dumps(row), flush=True)
        if proc.returncode:
            raise RuntimeError(f"Kokoro failed; see {logfile}")


def stream_request(base_url, payload, output, timeout):
    request = urllib.request.Request(base_url + "/v1/audio/speech", data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json", "Accept": "text/event-stream"})
    started = time.perf_counter()
    row = {"first_audio_s": None, "events": [], "done": None, "errors": [], "request": payload}
    pcm = bytearray()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        row["headers_s"] = time.perf_counter() - started
        for raw in response:
            if time.perf_counter() - started > timeout:
                raise TimeoutError("Breeze request deadline")
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            event = json.loads(data)
            elapsed = time.perf_counter() - started
            if event.get("type") == "speech.audio.delta":
                chunk = base64.b64decode(event["audio"])
                if chunk and row["first_audio_s"] is None:
                    row["first_audio_s"] = elapsed
                pcm.extend(chunk)
                row["events"].append({"elapsed_s": elapsed, "pcm_bytes": len(chunk)})
            elif event.get("type") == "speech.audio.done":
                row["done"] = event
            elif event.get("type") == "error":
                row["errors"].append(event)
    row["elapsed_s"] = time.perf_counter() - started
    if pcm:
        with wave.open(str(output), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(24000)
            wav.writeframes(pcm)
        row.update(audio_info(output))
        row["rtf"] = row["elapsed_s"] / row["duration_s"]
    return row


def breeze(args):
    config = {"host": "127.0.0.1", "port": args.port, "backend": "metal", "device": 0,
              "threads": 4, "lazy_load": True, "log_request_body": False, "max_loaded_models": 1,
              "models": [{"id": "breeze", "family": "breeze_tts", "path": str(args.scratch / "breeze-tts-2-q8_0.gguf"),
                          "task": "tts", "mode": "streaming", "session_options": {"breeze_tts.attention": "auto"}}]}
    config_path = args.scratch / "server.json"
    save(config_path, config)
    label = "breeze_smoke" if args.smoke else "breeze"
    report = {"config": config, "rows": []}
    base_url = f"http://127.0.0.1:{args.port}"
    with (ROOT / "results" / f"{label}_server.log").open("w") as log:
        proc = subprocess.Popen([str(args.scratch / "runtime/audiocpp_server"), "--config", str(config_path), "--no-ui", "--log"],
                                cwd=args.scratch / "runtime", stdout=log, stderr=log)
        deadline_timer = threading.Timer(args.timeout * (1 if args.smoke else 10), proc.terminate)
        deadline_timer.start()
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError(f"Breeze server exited {proc.returncode}; inspect server log")
                try:
                    with urllib.request.urlopen(base_url + "/health", timeout=1) as response:
                        if response.status == 200:
                            break
                except OSError:
                    time.sleep(0.2)
            else:
                raise RuntimeError("Breeze server health deadline")
            cases = FIXTURE["cases"][:1] if args.smoke else FIXTURE["cases"]
            queue = [(cases[0], "cold", 42), (cases[0], "warm", 42)]
            if not args.smoke:
                queue += [(cases[0], "warm_seed43", 43)] + [(c, "warm", 42) for c in cases[1:]]
            for case, phase, seed in queue:
                name = f"{label}_{case['id']}_{phase}"
                payload = {"model": "breeze", "input": case["text"], "stream": True,
                           "stream_format": "sse", "response_format": "pcm",
                           "voice_ref": str(ROOT / "audio/kokoro_reference.wav"), "reference_text": FIXTURE["reference"],
                           "options": {"instruction": case["instruction"], "guidance_scale": 4.0 if case["id"] == "directed" else 1.0,
                                       "seed": seed, "max_tokens": 1500, "text_chunk_size": 600,
                                       "stream_frames_per_event": 16, "stream_lookahead_margin": 12}}
                print(f"START {name}", flush=True)
                row = {"id": case["id"], "phase": phase, "memory_before": memory(proc.pid)}
                try:
                    row.update(stream_request(base_url, payload, ROOT / "audio" / f"{name}.wav", args.timeout))
                except Exception as exc:
                    row["exception"] = repr(exc)
                row["memory_after"] = memory(proc.pid)
                row["server_returncode"] = proc.poll()
                report["rows"].append(row)
                save(ROOT / "results" / f"{label}.json", report)
                print(json.dumps({k: v for k, v in row.items() if k not in ("events", "request")}), flush=True)
                if row.get("exception") or row.get("errors") or not row.get("samples"):
                    raise RuntimeError(f"Breeze failed on {name}")
        finally:
            deadline_timer.cancel()
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["baseline", "breeze"])
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--port", type=int, default=18649)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    (ROOT / "audio").mkdir(exist_ok=True)
    (ROOT / "results").mkdir(exist_ok=True)
    (baseline if args.action == "baseline" else breeze)(args)
