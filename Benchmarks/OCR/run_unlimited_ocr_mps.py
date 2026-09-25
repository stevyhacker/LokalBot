#!/usr/bin/env python3
"""Run the legacy custom-code OCR model against marked synthetic fixtures.

This runner executes Python shipped in a Hugging Face model snapshot. Keep it
synthetic-only: private screen exports must use the standard Transformers
runner, which refuses custom model code.
"""

import argparse
import contextlib
import ctypes
import json
import os
from pathlib import Path
import re
import sys
import time


SYNTHETIC_MARKER = ".synthetic-ocr-fixtures"
PRIVATE_MARKER = ".private-screen-fixtures"


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", required=True,
                        help="Local Hugging Face snapshots/<revision> directory")
    parser.add_argument("--revision", required=True,
                        help="Immutable 40-character model/code commit SHA")
    parser.add_argument("--allow-reviewed-local-code", action="store_true",
                        help="Acknowledge that Python in the pinned local snapshot was reviewed")
    parser.add_argument("--corpus-kind", required=True, choices=["synthetic"],
                        help="This legacy custom-code runner accepts synthetic fixtures only")
    parser.add_argument("--image", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--max-length", type=int, default=4096)
    parser.add_argument("--dtype", choices=["bfloat16", "float16", "float32"], default="bfloat16")
    parser.add_argument("--mode", choices=["gundam", "base"], default="gundam")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.revision):
        parser.error("--revision must be an immutable 40-character commit SHA")
    if not args.allow_reviewed_local_code:
        parser.error("--allow-reviewed-local-code is required for this custom-code model")
    if args.max_length <= 0:
        parser.error("--max-length must be positive")
    return args


def restrict_network():
    """Irreversibly deny network access before importing model libraries/code."""
    if sys.platform != "darwin":
        raise RuntimeError("The custom-code OCR runner requires the macOS network-denied sandbox")
    sandbox = ctypes.CDLL("/usr/lib/libsandbox.dylib")
    sandbox.sandbox_init.argtypes = [ctypes.c_char_p, ctypes.c_uint64,
                                     ctypes.POINTER(ctypes.c_char_p)]
    sandbox.sandbox_init.restype = ctypes.c_int
    sandbox.sandbox_free_error.argtypes = [ctypes.c_char_p]
    error = ctypes.c_char_p()
    profile = b"(version 1)(allow default)(deny network*)"
    if sandbox.sandbox_init(profile, 0, ctypes.byref(error)) != 0:
        message = error.value.decode("utf-8", errors="replace") if error.value else "sandbox unavailable"
        if error.value:
            sandbox.sandbox_free_error(error)
        raise RuntimeError("Custom-code OCR network isolation failed: " + message)


def validate_model_snapshot(model_dir: str, revision: str) -> Path:
    path = Path(model_dir).expanduser().resolve(strict=True)
    if not path.is_dir():
        raise ValueError("--model-dir must be a local directory")
    # Hugging Face cache snapshots are content-addressed by their immutable Git
    # revision. Do not accept an arbitrary checkout merely because the caller
    # supplied a revision alongside it.
    if path.name.lower() != revision.lower() or path.parent.name != "snapshots":
        raise ValueError("--model-dir must resolve to a Hugging Face snapshots/<revision> directory")
    return path


def validate_synthetic_image(image: str) -> Path:
    supplied = Path(image).expanduser().absolute()
    path = supplied.resolve(strict=True)
    if supplied != path:
        raise ValueError("Synthetic fixture image must not be reached through a symlink")
    if not path.is_file():
        raise ValueError("--image must be a regular file")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", path.stem):
        raise ValueError("Synthetic fixture filename must use a safe identifier")
    parents = [path.parent, *path.parents]
    if any((parent / PRIVATE_MARKER).exists() for parent in parents):
        raise ValueError("Decrypted private screen fixtures cannot use the custom-code runner")
    if not any((parent / SYNTHETIC_MARKER).is_file() for parent in parents):
        raise ValueError(f"Synthetic fixture tree is missing {SYNTHETIC_MARKER}")
    return path


def create_private_output(path: str) -> Path:
    output = Path(path).expanduser().absolute()
    if output.exists():
        raise ValueError("--output-dir must be a new directory")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    if output.stat().st_mode & 0o077:
        raise RuntimeError("Output directory is accessible outside its owner")
    return output


def selected_dtype(torch_module, name: str):
    return {
        "bfloat16": torch_module.bfloat16,
        "float16": torch_module.float16,
        "float32": torch_module.float32,
    }[name]


def install_cuda_to_mps_shim(torch_module, device: str, dtype):
    original_autocast = torch_module.autocast

    def tensor_cuda(self, device=None, non_blocking=False, memory_format=None):
        kwargs = {"non_blocking": non_blocking}
        if memory_format is not None:
            kwargs["memory_format"] = memory_format
        return self.to(device=device or selected_device, **kwargs)

    def module_cuda(self, device=None):
        return self.to(device=device or selected_device)

    def autocast(device_type, *args, **kwargs):
        if device_type == "cuda":
            if selected_device == "cpu":
                return contextlib.nullcontext()
            kwargs["dtype"] = dtype
            return original_autocast(selected_device, *args, **kwargs)
        return original_autocast(device_type, *args, **kwargs)

    selected_device = device
    torch_module.Tensor.cuda = tensor_cuda
    torch_module.nn.Module.cuda = module_cuda
    torch_module.autocast = autocast


def rss_mb():
    import psutil
    return psutil.Process(os.getpid()).memory_info().rss / (1024 * 1024)


def main():
    args = parse_args()
    model_dir = validate_model_snapshot(args.model_dir, args.revision)
    image = validate_synthetic_image(args.image)
    os.umask(0o077)
    output_dir = create_private_output(args.output_dir)

    # Offline flags stop supported Hub clients; the OS sandbox also covers
    # sockets opened directly by the reviewed model implementation.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    restrict_network()

    import torch
    from transformers import AutoModel, AutoTokenizer

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    dtype = selected_dtype(torch, args.dtype)
    install_cuda_to_mps_shim(torch, device, dtype)

    metadata_path = output_dir / "run.json"
    metadata_path.write_text(json.dumps({
        "model_dir": str(model_dir),
        "revision": args.revision.lower(),
        "corpus_kind": "synthetic",
        "image": str(image),
        "local_files_only": True,
        "reviewed_local_code": True,
        "network": "denied by macOS sandbox",
    }, indent=2) + "\n", encoding="utf-8")

    start = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(
        str(model_dir),
        revision=args.revision,
        trust_remote_code=True,
        local_files_only=True,
    )
    model = AutoModel.from_pretrained(
        str(model_dir),
        revision=args.revision,
        trust_remote_code=True,
        use_safetensors=True,
        torch_dtype=dtype,
        low_cpu_mem_usage=True,
        local_files_only=True,
    )
    model = model.eval().to(device)
    load_seconds = time.perf_counter() - start
    load_rss = rss_mb()

    infer_start = time.perf_counter()
    crop_mode = args.mode == "gundam"
    image_size = 640 if crop_mode else 1024
    text = model.infer(
        tokenizer,
        prompt="<image>document parsing.",
        image_file=str(image),
        output_path=str(output_dir),
        base_size=1024,
        image_size=image_size,
        crop_mode=crop_mode,
        max_length=args.max_length,
        no_repeat_ngram_size=35,
        ngram_window=128,
        save_results=False,
        eval_mode=True,
    )
    infer_seconds = time.perf_counter() - infer_start
    infer_rss = rss_mb()

    output_path = output_dir / f"{image.stem}.unlimited.txt"
    output_path.write_text(text or "", encoding="utf-8")

    print(
        "device\tdtype\tmode\tload_s\tinfer_s\tchars\trss_after_load_mb\t"
        "rss_after_infer_mb\toutput_path"
    )
    print(
        f"{device}\t{args.dtype}\t{args.mode}\t{load_seconds:.2f}\t{infer_seconds:.2f}\t"
        f"{len(text or '')}\t{load_rss:.1f}\t{infer_rss:.1f}\t{output_path}"
    )


if __name__ == "__main__":
    main()
