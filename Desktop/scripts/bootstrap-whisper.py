#!/usr/bin/env python3
"""Explicit opt-in bootstrap. Pinned source and model; no GPU required."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
COMMIT = "927cfce34f31707e17f2bff35c349632fb9e2c3a"
MODEL_REV = "5359861c739e955e79d9a303bcbc70fb988958b1"
MODEL_HASH = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build", action="store_true", help="Build pinned whisper-cli using git and CMake")
parser.add_argument("--model", action="store_true", help="Download and verify the English base model (148 MB)")
args = parser.parse_args()
if not args.build and not args.model:
    parser.error("Choose --build and/or --model explicitly")
if args.build:
    source = ROOT / "tools/whisper.cpp"
    if not source.exists():
        subprocess.run(["git", "clone", "--no-checkout", "https://github.com/ggml-org/whisper.cpp.git", str(source)], check=True)
    subprocess.run(["git", "-C", str(source), "checkout", "--detach", COMMIT], check=True)
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != COMMIT:
        raise SystemExit("Whisper source pin mismatch")
    build = source / "build"
    subprocess.run(["cmake", "-S", str(source), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF", "-DGGML_CUDA=OFF", "-DGGML_VULKAN=OFF", "-DGGML_METAL=OFF", "-DGGML_NATIVE=OFF"], check=True)
    subprocess.run(["cmake", "--build", str(build), "--config", "Release", "--target", "whisper-cli", "-j", "4"], check=True)
if args.model:
    target = ROOT / "models/ggml-base.en.bin"
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".download")
    url = f"https://huggingface.co/ggerganov/whisper.cpp/resolve/{MODEL_REV}/ggml-base.en.bin"
    urllib.request.urlretrieve(url, temporary)
    if hashlib.sha256(temporary.read_bytes()).hexdigest() != MODEL_HASH:
        temporary.unlink()
        raise SystemExit("Model checksum mismatch; download rejected")
    temporary.replace(target)
    print(f"Verified CPU model: {target}")
print(json.dumps({"whisper_commit": COMMIT, "model_revision": MODEL_REV, "model_sha256": MODEL_HASH}))
