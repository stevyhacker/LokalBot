"""Additional frozen arm: same inputs, experimental NF4 experts with CPU offload."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import time

ROOT = Path(__file__).resolve().parent


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--smoke", action="store_true", help="Only a non-benchmark JSON generation probe")
    args = ap.parse_args()
    import torch
    from transformers import AutoTokenizer, GenerationConfig
    from lmformatenforcer import JsonSchemaParser
    from lmformatenforcer.integrations.transformers import (
        build_token_enforcer_tokenizer_data, build_transformers_prefix_allowed_tokens_fn)
    from nf4_offload import load_model
    torch.set_num_threads(6)
    torch.manual_seed(0)
    spec = json.loads((ROOT / "model.json").read_text())
    for filename, digest in spec["baseline_inputs"].items():
        assert sha(ROOT / filename) == digest, filename
    verified = json.loads((ROOT / "verified-model-files.json").read_text())
    assert set(w["file"] for w in spec["weights"]) <= set(verified)
    for w in spec["weights"]:
        assert verified[w["file"]] == w["sha256"], w["file"]
    identity = {"arm": "memt-nano-nf4-offload", "model_revision": spec["revision"],
        "inputs": spec["baseline_inputs"], "software": {p: sha(ROOT / p) for p in
          ["run_windows.py", "nf4_offload.py", "model.json", "verified-model-files.json", "PROTOCOL_EXTENSION.md", "lmformatenforcer-revision.json"]},
        "packages": {p: importlib.metadata.version(p) for p in
          ["torch", "transformers", "bitsandbytes", "accelerate", "lm-format-enforcer"]},
        "settings": {"do_sample": False, "seed": 0, "enable_thinking": False, "max_new_tokens": 1024,
          "max_context_tokens": 8192, "expert_quantization": "NF4, blocksize 64, no double quantization",
          "dense_and_memory_weights": "BF16", "native_memory": "fresh/no prior state for each case",
          "schema_enforcement": "lm-format-enforcer", "BNB_ROCM_VERSION": os.environ.get("BNB_ROCM_VERSION"),
          "MIOPEN_FIND_MODE": os.environ.get("MIOPEN_FIND_MODE")}}
    output = ROOT / "results"
    output.mkdir(exist_ok=True)
    raw_path = output / "memt-nano-nf4-offload.jsonl"
    meta_path = output / "memt-nano-nf4-offload.meta.json"
    completed = {}
    if not args.smoke:
        if meta_path.exists():
            assert json.loads(meta_path.read_text())["identity"] == identity, "Resume identity changed"
        else:
            meta_path.write_text(json.dumps({"identity": identity, "frozen_before_inference": time.time(),
                "platform": platform.platform(), "gpu": torch.cuda.get_device_name(0)}, indent=2) + "\n")
        if raw_path.exists():
            for line in raw_path.read_text(encoding="utf-8").splitlines():
                record = json.loads(line)
                assert record["id"] not in completed
                completed[record["id"]] = record
    model = load_model(ROOT / "model")
    tokenizer = AutoTokenizer.from_pretrained(ROOT / "model", local_files_only=True, trust_remote_code=True)
    tokenizer_data = build_token_enforcer_tokenizer_data(tokenizer)
    prompts = json.loads((ROOT / "prompts.json").read_text(encoding="utf-8"))
    assert set(completed) <= {p["id"] for p in prompts}
    schema = json.loads((ROOT / "schema.json").read_text())
    smoke = {"id": "NON_BENCHMARK_SMOKE", "system": "Reply with JSON only.",
             "user": 'Return exactly {"items":[]}.'}
    prompts = [smoke] + ([] if args.smoke else prompts)
    generation_config = GenerationConfig(do_sample=False, max_new_tokens=1024, num_beams=1,
        eos_token_id=model.generation_config.eos_token_id,
        pad_token_id=model.generation_config.pad_token_id, use_cache=True)
    eos = generation_config.eos_token_id
    eos = {eos} if isinstance(eos, int) else set(eos)
    for p in prompts:
        if p["id"] in completed:
            continue
        started = time.time()
        record = {"id": p["id"], "started": started}
        print("starting", p["id"], flush=True)
        try:
            rendered = tokenizer.apply_chat_template(
                [{"role": "system", "content": p["system"]}, {"role": "user", "content": p["user"]}],
                tokenize=False, add_generation_prompt=True, enable_thinking=False)
            encoded = tokenizer(rendered, add_special_tokens=False, return_tensors="pt").to("cuda")
            count = encoded["input_ids"].shape[1]
            assert count + 1024 <= 8192
            parser = JsonSchemaParser(schema)
            allowed = build_transformers_prefix_allowed_tokens_fn(tokenizer_data, parser)
            with torch.inference_mode():
                tokens = model.generate(**encoded, generation_config=generation_config,
                                        prefix_allowed_tokens_fn=allowed, memory_state=None)
            generated = tokens[0, count:].tolist()
            stopped = bool(generated) and generated[-1] in eos
            visible = generated[:-1] if stopped else generated
            content = tokenizer.decode(visible, skip_special_tokens=False)
            record.update(content=content, reasoning="", finish="stop" if stopped else "length",
                generated_ids=generated, prompt_sha256=hashlib.sha256(rendered.encode()).hexdigest(),
                usage={"prompt_tokens": count, "completion_tokens": len(generated)})
        except Exception as error:
            record.update(content="", error=repr(error))
        record["wall_seconds"] = time.time() - started
        if p["id"] == "NON_BENCHMARK_SMOKE":
            (ROOT / "smoke-result.json").write_text(json.dumps(record, indent=2) + "\n")
            assert record.get("finish") == "stop", record
            assert json.loads(record["content"]) == {"items": []}, record
        else:
            with raw_path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
                f.flush()
                os.fsync(f.fileno())
        print("completed", p["id"], round(record["wall_seconds"], 2), record.get("finish", record.get("error")), flush=True)
        if record.get("error"):
            raise RuntimeError("Observed failure preserved; stopping without retry")
    if not args.smoke:
        (output / "COMPLETE").write_text(str(time.time()) + "\n")


if __name__ == "__main__":
    main()
