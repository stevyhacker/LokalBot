"""Experimental NF4 expert storage; original MemT dense and memory blocks stay BF16.

Only the packed MoE expert tensors change representation. Experts remain in CPU
RAM; selected experts are copied to the GPU and dequantized for native F.linear.
No model weights, routing decisions, source text, or memory states are dropped.
"""
import copy
import gc
import json
from pathlib import Path

import bitsandbytes as bnb
import torch
from torch import nn
from torch.nn import functional as F


class OffloadedExperts(nn.Module):
    def __init__(self, original):
        super().__init__()
        self.num_experts = original.num_experts
        self.act_fn = original.act_fn
        self.weights = {}

    def load_projection(self, name, tensor):
        assert name in ("gate_up_proj", "down_proj") and name not in self.weights
        assert tensor.ndim == 3 and tensor.shape[0] == self.num_experts
        rows = []
        for expert in tensor:
            quantized, state = bnb.functional.quantize_4bit(
                expert.to(device="cuda", dtype=torch.bfloat16).contiguous(),
                blocksize=64, compress_statistics=False, quant_type="nf4")
            state.to("cpu")
            rows.append((quantized.cpu(), state))
        self.weights[name] = rows

    def materialize(self, name, index, device):
        quantized, state = self.weights[name][index]
        local_state = copy.copy(state)
        local_state.absmax = state.absmax.to(device)
        local_state.code = state.code.to(device)
        assert state.state2 is None
        return bnb.functional.dequantize_4bit(quantized.to(device), quant_state=local_state)

    def forward(self, hidden_states, top_k_index, top_k_weights):
        result = torch.zeros_like(hidden_states)
        with torch.no_grad():
            mask = F.one_hot(top_k_index, num_classes=self.num_experts).permute(2, 1, 0)
            active = (mask.sum(dim=(-1, -2)) > 0).nonzero().flatten().tolist()
        for index in active:
            top_position, token_index = torch.where(mask[index])
            gate_up = self.materialize("gate_up_proj", index, hidden_states.device)
            gate, up = F.linear(hidden_states[token_index], gate_up).chunk(2, dim=-1)
            del gate_up
            activated = self.act_fn(gate) * up
            down = self.materialize("down_proj", index, hidden_states.device)
            values = F.linear(activated, down)
            del down
            values *= top_k_weights[token_index, top_position, None]
            result.index_add_(0, token_index, values.to(result.dtype))
        return result


def load_model(path):
    from accelerate import init_empty_weights
    from safetensors import safe_open
    from transformers import AutoConfig, AutoModelForCausalLM, GenerationConfig
    path = Path(path)
    config = AutoConfig.from_pretrained(path, trust_remote_code=True, local_files_only=True)
    with init_empty_weights(include_buffers=False):
        model = AutoModelForCausalLM.from_config(
            config, trust_remote_code=True, attn_implementation="sdpa", experts_implementation="eager")
    original = dict(model.named_parameters())
    index = json.loads((path / "model.safetensors.index.json").read_text())['weight_map']
    assert set(original) == set(index), {"missing": sorted(set(original)-set(index)),
                                          "extra": sorted(set(index)-set(original))}
    expected_shapes = {name: tuple(value.shape) for name, value in original.items()}
    packed_modules = [name for name, module in model.named_modules()
                      if hasattr(module, "gate_up_proj") and hasattr(module, "num_experts")]
    assert len(packed_modules) == config.get_text_config().num_hidden_layers
    for name in packed_modules:
        model.set_submodule(name, OffloadedExperts(model.get_submodule(name)))
    del original
    loaded = set()
    for filename in sorted(set(index.values())):
        print("loading", filename, flush=True)
        with safe_open(path / filename, framework="pt", device="cpu") as source:
            assert set(source.keys()) == {key for key, file in index.items() if file == filename}
            for name in source.keys():
                value = source.get_tensor(name)
                assert tuple(value.shape) == expected_shapes[name], name
                module_name, parameter_name = name.rsplit(".", 1)
                module = model.get_submodule(module_name)
                if isinstance(module, OffloadedExperts):
                    module.load_projection(parameter_name, value)
                else:
                    module._parameters[parameter_name] = nn.Parameter(
                        value.to(device="cuda", dtype=torch.bfloat16), requires_grad=False)
                loaded.add(name)
                del value
        gc.collect()
        torch.cuda.empty_cache()
        print("loaded", len(loaded), "/", len(index), "gpu_allocated", torch.cuda.memory_allocated(), flush=True)
    assert loaded == set(index)
    assert all(not p.is_meta for p in model.parameters())
    for name, buffer in list(model.named_buffers()):
        assert not buffer.is_meta, f"Uninitialized buffer: {name}"
        parent, attribute = name.rsplit(".", 1)
        model.get_submodule(parent)._buffers[attribute] = buffer.to("cuda")
    for name in packed_modules:
        assert set(model.get_submodule(name).weights) == {"gate_up_proj", "down_proj"}
    model.generation_config = GenerationConfig.from_pretrained(path, local_files_only=True)
    return model.eval()


def validate():
    """Compare the adapter to an independent explicit NF4 reference for prefill/decode."""
    from types import SimpleNamespace
    torch.manual_seed(0)
    module = OffloadedExperts(SimpleNamespace(num_experts=4, act_fn=F.silu))
    gate_up = torch.randn((4, 64, 64), dtype=torch.bfloat16) * 0.05
    down = torch.randn((4, 64, 32), dtype=torch.bfloat16) * 0.05
    module.load_projection("gate_up_proj", gate_up)
    module.load_projection("down_proj", down)
    comparisons = []
    with torch.inference_mode():
        for tokens in (1, 7):
            hidden = torch.randn((tokens, 64), device="cuda", dtype=torch.bfloat16)
            indices = torch.tensor([[i % 4, (i+1) % 4] for i in range(tokens)], device="cuda")
            weights = torch.full((tokens, 2), 0.5, dtype=torch.bfloat16, device="cuda")
            expected = torch.zeros_like(hidden)
            for expert in range(4):
                selected = (indices == expert).nonzero()
                for token, slot in selected.tolist():
                    g, u = F.linear(hidden[token:token+1], module.materialize("gate_up_proj", expert, "cuda")).chunk(2, -1)
                    y = F.linear(F.silu(g) * u, module.materialize("down_proj", expert, "cuda"))
                    expected[token] += y[0] * weights[token, slot]
            actual = module(hidden, indices, weights)
            torch.testing.assert_close(actual, expected, rtol=0.02, atol=0.001)
            assert torch.isfinite(actual).all()
            comparisons.append({"tokens": tokens, "max_abs_difference": (actual-expected).abs().max().item()})
    assert all(q.device.type == "cpu" and state.absmax.device.type == "cpu"
               for rows in module.weights.values() for q, state in rows)
    print(json.dumps({"adapter_validation": "passed", "comparisons": comparisons}), flush=True)


if __name__ == "__main__":
    validate()
