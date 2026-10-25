"""End-to-end loader/parity checks using tiny random weights, never benchmark data."""
import faulthandler
import json
from pathlib import Path
import shutil
import tempfile
import sys

TRACE = open(Path(__file__).with_name('adapter-test-trace.log'), 'w', buffering=1)
faulthandler.enable(file=TRACE)
print('importing runtime', flush=True)

import torch
from safetensors.torch import save_file
from transformers import AutoConfig, AutoModelForCausalLM, GenerationConfig
from nf4_offload import OffloadedExperts, load_model

ROOT = Path(__file__).resolve().parent
torch.manual_seed(0)
torch.set_num_threads(4)


def main():
    faulthandler.dump_traceback_later(60, repeat=True, file=TRACE)
    with tempfile.TemporaryDirectory(prefix="memt-adapter-test-", dir=ROOT) as directory:
        path = Path(directory)
        raw = json.loads((ROOT / "sources/config.json").read_text())
        text = raw['backbone_configs']['text_config']
        text.update(hidden_size=64, num_attention_heads=4, num_key_value_heads=1, head_dim=16,
                    moe_intermediate_size=16, shared_expert_intermediate_size=16, num_experts=4,
                    num_experts_per_tok=2, num_hidden_layers=4, vocab_size=256,
                    layer_types=['linear_attention']*3+['full_attention'],
                    linear_num_value_heads=4, linear_num_key_heads=2,
                    linear_key_head_dim=16, linear_value_head_dim=16,
                    bos_token_id=0, eos_token_id=1, pad_token_id=0, max_position_embeddings=8192)
        text['rope_parameters']['mrope_section'] = [1, 1, 0]
        raw['memt'].update(num_memory_heads=4, num_kv_heads=4)
        raw.update(pad_token_id=0)
        (path / 'config.json').write_text(json.dumps(raw))
        for name in ['configuration_memt.py', 'modeling_memt.py']:
            shutil.copyfile(ROOT / 'sources' / name, path / name)
        config = AutoConfig.from_pretrained(path, trust_remote_code=True, local_files_only=True)
        print('building tiny reference', flush=True)
        reference = AutoModelForCausalLM.from_config(config, trust_remote_code=True,
            attn_implementation='sdpa', experts_implementation='eager').to(dtype=torch.bfloat16, device='cuda').eval()
        print('saving tiny checkpoint', flush=True)
        state = {name: value.cpu().contiguous() for name, value in reference.state_dict().items()}
        save_file(state, path / 'test.safetensors')
        (path / 'model.safetensors.index.json').write_text(json.dumps(
            {'weight_map': {name: 'test.safetensors' for name in state}}))
        GenerationConfig(eos_token_id=1, pad_token_id=0).save_pretrained(path)
        print('loading tiny adapter', flush=True)
        actual = load_model(path)
        # Reference uses exactly the dequantized weights but keeps the original expert class.
        for name, module in actual.named_modules():
            if isinstance(module, OffloadedExperts):
                target = reference.get_submodule(name)
                for projection in ['gate_up_proj', 'down_proj']:
                    tensor = torch.stack([module.materialize(projection, index, 'cuda')
                                          for index in range(module.num_experts)])
                    setattr(target, projection, torch.nn.Parameter(tensor, requires_grad=False))
        checks = {}
        def compare(label, a, b):
            torch.testing.assert_close(a, b, atol=0.002, rtol=0.02)
            checks[label] = (a-b).abs().max().item()
        ids = torch.tensor([[3, 7, 11, 19, 23, 29, 31]], device='cuda')
        with torch.inference_mode():
            print('prefill comparison', flush=True)
            r = reference(ids, use_cache=True)
            a = actual(ids, use_cache=True)
            compare('prefill_logits', a.logits, r.logits)
            next_id = torch.tensor([[37]], device='cuda')
            r2 = reference(next_id, past_key_values=r.past_key_values, use_cache=True)
            a2 = actual(next_id, past_key_values=a.past_key_values, use_cache=True)
            compare('cached_decode_logits', a2.logits, r2.logits)
            print('memory comparison', flush=True)
            rm = reference.commit_memory(ids)
            am = actual.commit_memory(ids)
            assert set(am) == set(rm) and am
            for layer in rm:
                compare(f'memory_commit_layer_{layer}', am[layer], rm[layer])
            compare('memory_read_logits', actual(next_id, memory_state=am).logits,
                    reference(next_id, memory_state=rm).logits)
        result = {'status': 'passed', 'scope': 'tiny random checkpoint; not model accuracy',
                  'max_absolute_differences': checks}
        (ROOT / 'adapter-model-validation.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result), flush=True)
        faulthandler.cancel_dump_traceback_later()


if __name__ == '__main__':
    main()
