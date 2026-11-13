"""Offline ASR-assisted content check; this does not score naturalness.

Uses the already-cached Qwen3-ASR evaluation environment. No network calls,
reference transcript prompting, or real-person voice recordings are used.
"""
import gc
import importlib.metadata
import json
import os
from pathlib import Path
import re
import time

ROOT = Path(__file__).resolve().parent
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HOME"] = str(ROOT / "results/hf-offline")
os.environ["MPLCONFIGDIR"] = str(ROOT / "results/mpl-cache")
import torch
from qwen_asr import Qwen3ASRModel

FIXTURE = json.loads((ROOT / "cases.json").read_text())
CASES = {c["id"]: c["text"] for c in FIXTURE["cases"]}
CASES["reference"] = FIXTURE["reference"]
MODEL = Path("/private/tmp/lokalbot-funasr-comparison-20260908/models/Qwen/Qwen3-ASR-1.7B")


def words(text):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text.lower().replace("’", "'"))


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, left in enumerate(a, 1):
        current = [i]
        for j, right in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (left != right)))
        previous = current
    return previous[-1]


assert torch.backends.mps.is_available(), "Apple GPU unavailable"
model = Qwen3ASRModel.from_pretrained(str(MODEL), device_map="mps", dtype=torch.bfloat16,
                                    max_inference_batch_size=1, max_new_tokens=1024)
report = {"model": str(MODEL), "qwen_asr_version": importlib.metadata.version("qwen-asr"),
          "torch_version": torch.__version__, "device": str(model.model.device),
          "dtype": str(model.model.dtype), "rows": [],
          "limits": "ASR transcript agreement is a diagnostic, not human listening or a perceptual quality score. Numeric case excluded from aggregate WER because written/spoken forms differ."}
files = sorted((ROOT / "audio").glob("*.wav"))
for path in files:
    if "smoke" in path.stem:
        continue
    case_id = next(k for k in sorted(CASES, key=len, reverse=True) if path.stem == f"kokoro_{k}" or path.stem.startswith(f"breeze_{k}_"))
    torch.mps.synchronize()
    started = time.perf_counter()
    result = model.transcribe(str(path), language="English")
    torch.mps.synchronize()
    transcript = " ".join(r.text for r in result)
    reference = CASES[case_id]
    ref_words, hyp_words = words(reference), words(transcript)
    edits = distance(ref_words, hyp_words)
    row = {"file": path.name, "id": case_id, "reference": reference, "transcript": transcript,
           "edits": edits, "reference_words": len(ref_words), "raw_wer": edits / len(ref_words),
           "include_in_aggregate": case_id not in ("names_numbers", "reference"),
           "asr_seconds": time.perf_counter() - started}
    report["rows"].append(row)
    (ROOT / "results/content.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(row), flush=True)

del model
gc.collect()
torch.mps.empty_cache()
