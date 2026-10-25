"""Check the Windows runtime without loading weights or evaluating any test case."""
import importlib.metadata
import json
from pathlib import Path
import platform
import subprocess
import sys
import traceback

ROOT = Path(__file__).resolve().parent
report = {"kind": "compatibility_probe_not_benchmark", "platform": platform.platform(), "checks": {}}


def check(name, action):
    try:
        report["checks"][name] = {"ok": True, "result": action()}
    except Exception:
        report["checks"][name] = {"ok": False, "traceback": traceback.format_exc()}
    (ROOT / "compatibility.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({name: report["checks"][name]}), flush=True)


def packages():
    return {name: importlib.metadata.version(name) for name in
            ["torch", "transformers", "accelerate", "safetensors", "bitsandbytes", "lm-format-enforcer"]}


def device():
    import torch
    result = {"torch": torch.__version__, "hip": torch.version.hip, "available": torch.cuda.is_available()}
    if result["available"]:
        props = torch.cuda.get_device_properties(0)
        result.update(name=props.name, total_memory=props.total_memory, free_memory=torch.cuda.mem_get_info()[0])
    return result


def matmul(dtype_name):
    import torch
    dtype = getattr(torch, dtype_name)
    a = torch.ones((16, 16), device="cuda", dtype=dtype)
    result = a @ a
    torch.cuda.synchronize()
    assert torch.isfinite(result).all() and (result == 16).all()
    return {"dtype": dtype_name, "value": result[0, 0].item()}


def architecture():
    import torch
    from transformers import AutoConfig, AutoModelForCausalLM, BitsAndBytesConfig
    config = AutoConfig.from_pretrained(ROOT / "sources", trust_remote_code=True, local_files_only=True)
    with torch.device("meta"):
        model = AutoModelForCausalLM.from_config(config, trust_remote_code=True, attn_implementation="sdpa")
    total = sum(p.numel() for p in model.parameters())
    packed = sum(p.numel() for name, p in model.named_parameters() if ".experts." in name)
    from transformers.integrations.bitsandbytes import replace_with_bnb_linear
    model = replace_with_bnb_linear(model, quantization_config=BitsAndBytesConfig(load_in_4bit=True))
    remaining = sum(p.numel() for name, p in model.named_parameters() if ".experts." in name)
    return {"parameters": total, "packed_expert_parameters_before": packed,
            "packed_expert_parameters_after_standard_bnb": remaining,
            "unquantized_packed_expert_bf16_bytes": remaining * 2,
            "note": "Meta tensors only. This is a memory estimate, not a checkpoint load or inference result."}


def quantized_linear():
    import torch
    import bitsandbytes as bnb
    torch.manual_seed(0)
    layer = bnb.nn.Linear4bit(64, 32, bias=False, compute_dtype=torch.float16, quant_type="nf4")
    layer = layer.half().cuda()
    with torch.inference_mode():
        result = layer(torch.ones((1, 64), dtype=torch.float16, device="cuda"))
    torch.cuda.synchronize()
    assert torch.isfinite(result).all()
    return {"shape": list(result.shape), "finite": True}


def isolated_quantized_linear():
    # A native kernel can terminate the interpreter instead of raising Python exceptions.
    result = subprocess.run([sys.executable, str(__file__), "--nf4-only"],
                            capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(json.dumps({"returncode": result.returncode,
                                       "stdout": result.stdout, "stderr": result.stderr}))
    return json.loads(result.stdout.strip().splitlines()[-1])


if __name__ == "__main__":
    if "--nf4-only" in sys.argv:
        print(json.dumps(quantized_linear()), flush=True)
        raise SystemExit(0)
    check("packages", packages)
    check("device", device)
    check("fp32_matmul", lambda: matmul("float32"))
    check("fp16_matmul", lambda: matmul("float16"))
    check("bf16_matmul", lambda: matmul("bfloat16"))
    check("standard_4bit_memory_estimate", architecture)
    check("nf4_gpu_linear", isolated_quantized_linear)
