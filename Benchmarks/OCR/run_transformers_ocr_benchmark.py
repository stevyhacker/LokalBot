#!/usr/bin/env python3
import argparse
import csv
import os
import re
import statistics
import sys
import json
import time
from pathlib import Path

MODEL_IDS = {
    "got-ocr-2": "stepfun-ai/GOT-OCR-2.0-hf",
    "glm-ocr": "zai-org/GLM-OCR",
}


def tokens(text: str) -> set[str]:
    return set(re.findall(r"[A-Za-z0-9_./:-]{3,}", text.lower()))


def jaccard(a: str, b: str) -> float:
    left = tokens(a)
    right = tokens(b)
    if not left and not right:
        return 1.0
    if not left or not right:
        return 0.0
    return len(left & right) / len(left | right)


def rss_mb() -> float:
    import psutil
    return psutil.Process(os.getpid()).memory_info().rss / (1024 * 1024)


def parse_args(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--vision-tsv", required=True)
    parser.add_argument("--model", choices=sorted(MODEL_IDS), required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--limit", type=int, default=3)
    parser.add_argument("--max-new-tokens", type=int, default=1024)
    parser.add_argument("--dtype", choices=["float16", "bfloat16", "float32"], default="bfloat16")
    parser.add_argument("--revision", required=True, help="Immutable 40-character model/code commit SHA, downloaded before this run")
    parser.add_argument("--corpus-kind", required=True, choices=["synthetic", "private"])
    parser.add_argument("--allow-reviewed-remote-code", action="store_true", help="Synthetic fixtures only; execute the already downloaded code at --revision")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.revision):
        parser.error("--revision must be an immutable 40-character commit SHA")
    if args.corpus_kind == "private" and args.allow_reviewed_remote_code:
        parser.error("Remote model code is not permitted with private screen fixtures")
    if args.limit <= 0:
        parser.error("--limit must be positive")
    return args


def restrict_private_network():
    """Irreversibly deny this process network access before model imports."""
    if sys.platform != "darwin":
        raise RuntimeError("Private fixture runs require the macOS network-denied sandbox; use synthetic data on this host")
    import ctypes
    sandbox = ctypes.CDLL("/usr/lib/libsandbox.dylib")
    sandbox.sandbox_init.argtypes = [ctypes.c_char_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_char_p)]
    sandbox.sandbox_init.restype = ctypes.c_int
    sandbox.sandbox_free_error.argtypes = [ctypes.c_char_p]
    error = ctypes.c_char_p()
    if sandbox.sandbox_init(b"(version 1)(allow default)(deny network*)", 0, ctypes.byref(error)) != 0:
        message = error.value.decode("utf-8", errors="replace") if error.value else "sandbox unavailable"
        if error.value:
            sandbox.sandbox_free_error(error)
        raise RuntimeError("Private fixture network isolation failed: " + message)


def validate_rows(rows, corpus_kind):
    if not rows:
        raise ValueError("The fixture manifest is empty")
    for row in rows:
        if not re.fullmatch(r"[A-Za-z0-9_-]+", row["id"]):
            raise ValueError("Unsafe fixture ID")
        for field in ("png_path", "vision_text_path"):
            path = Path(row[field]).resolve(strict=True)
            if not path.is_file():
                raise ValueError("Fixture input must be a file")
            if corpus_kind != "private" and any((parent / ".private-screen-fixtures").exists() for parent in path.parents):
                raise ValueError("Decrypted screen fixtures require --corpus-kind private")


def dtype_from_name(name: str):
    import torch
    return {
        "float16": torch.float16,
        "bfloat16": torch.bfloat16,
        "float32": torch.float32,
    }[name]


def load_rows(path: Path, limit: int):
    rows = []
    with path.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            rows.append(row)
            if len(rows) >= limit:
                break
    return rows


def move_inputs(inputs, device: str):
    moved = {}
    for key, value in inputs.items():
        moved[key] = value.to(device) if hasattr(value, "to") else value
    return moved


def prepare_inputs(model_key: str, processor, image_path: str, device: str):
    if model_key == "got-ocr-2":
        inputs = processor(image_path, return_tensors="pt")
    elif model_key == "glm-ocr":
        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "image", "url": image_path},
                    {"type": "text", "text": "Text Recognition."},
                ],
            }
        ]
        inputs = processor.apply_chat_template(
            messages,
            tokenize=True,
            add_generation_prompt=True,
            return_dict=True,
            return_tensors="pt",
        )
    else:
        raise ValueError(model_key)
    return move_inputs(inputs, device)


def decode_output(model_key: str, processor, generated_ids, prompt_len: int):
    if model_key == "got-ocr-2":
        return processor.decode(generated_ids[0, prompt_len:], skip_special_tokens=True)
    return processor.decode(generated_ids[0][prompt_len:], skip_special_tokens=True)


def main():
    args = parse_args()
    # Apply the network boundary before importing any model implementation.
    # Offline model loading alone does not constrain arbitrary Python sockets.
    if args.corpus_kind == "private":
        restrict_private_network()
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.umask(0o077)
    rows = load_rows(Path(args.vision_tsv), args.limit)
    validate_rows(rows, args.corpus_kind)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    (output_dir / "run.json").write_text(json.dumps({
        "model": MODEL_IDS[args.model], "revision": args.revision,
        "corpus_kind": args.corpus_kind, "local_files_only": True,
        "remote_code": args.allow_reviewed_remote_code,
        "cleanup": "Delete this output directory and decrypted fixtures after review; app retention does not manage them.",
    }, indent=2), encoding="utf-8")
    import torch
    from transformers import AutoModelForImageTextToText, AutoProcessor

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    dtype = dtype_from_name(args.dtype)
    model_id = MODEL_IDS[args.model]

    load_start = time.perf_counter()
    processor = AutoProcessor.from_pretrained(model_id, revision=args.revision,
                                             local_files_only=True, trust_remote_code=args.allow_reviewed_remote_code)
    model = AutoModelForImageTextToText.from_pretrained(
        model_id,
        revision=args.revision,
        local_files_only=True,
        trust_remote_code=args.allow_reviewed_remote_code,
        use_safetensors=True,
        torch_dtype=dtype,
        low_cpu_mem_usage=True,
    ).eval()
    model.to(device)
    load_ms = (time.perf_counter() - load_start) * 1000
    load_rss = rss_mb()

    print(
        "model\tid\tapp\tdevice\tdtype\tload_ms\tinfer_ms\tchars\tvision_chars\tchar_ratio\ttoken_jaccard\trss_mb\toutput_path",
        flush=True,
    )
    metrics = []
    for row in rows:
        vision_text = Path(row["vision_text_path"]).read_text(encoding="utf-8", errors="ignore")
        inputs = prepare_inputs(args.model, processor, row["png_path"], device)
        prompt_len = inputs["input_ids"].shape[1]
        infer_start = time.perf_counter()
        with torch.inference_mode():
            generated_ids = model.generate(
                **inputs,
                max_new_tokens=args.max_new_tokens,
                do_sample=False,
                tokenizer=getattr(processor, "tokenizer", None),
            )
        infer_ms = (time.perf_counter() - infer_start) * 1000
        text = decode_output(args.model, processor, generated_ids, prompt_len).strip()
        output_path = Path(args.output_dir) / f"shot-{row['id']}.{args.model}.txt"
        output_path.write_text(text, encoding="utf-8")
        ratio = len(text) / len(vision_text) if vision_text else 0.0
        overlap = jaccard(vision_text, text)
        now_rss = rss_mb()
        metrics.append({"infer_ms": infer_ms, "chars": len(text), "token_jaccard": overlap, "rss": now_rss})
        print(
            f"{args.model}\t{row['id']}\t{row['app']}\t{device}\t{args.dtype}\t{load_ms:.1f}\t"
            f"{infer_ms:.1f}\t{len(text)}\t{len(vision_text)}\t{ratio:.2f}\t{overlap:.3f}\t"
            f"{now_rss:.1f}\t{output_path}",
            flush=True,
        )

    if metrics:
        print(
            "SUMMARY\t"
            f"{args.model}\t"
            f"n={len(metrics)}\t"
            f"load_ms={load_ms:.1f}\t"
            f"load_rss_mb={load_rss:.1f}\t"
            f"mean_infer_ms={statistics.mean(m['infer_ms'] for m in metrics):.1f}\t"
            f"min_infer_ms={min(m['infer_ms'] for m in metrics):.1f}\t"
            f"max_infer_ms={max(m['infer_ms'] for m in metrics):.1f}\t"
            f"mean_chars={statistics.mean(m['chars'] for m in metrics):.1f}\t"
            f"mean_token_jaccard={statistics.mean(m['token_jaccard'] for m in metrics):.3f}\t"
            f"max_rss_mb={max(m['rss'] for m in metrics):.1f}",
            flush=True,
        )


if __name__ == "__main__":
    main()
