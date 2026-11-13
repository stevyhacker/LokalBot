"""Validate native non-thinking template and schema token masks without inference."""
import json
from pathlib import Path
import torch
from transformers import AutoTokenizer
from lmformatenforcer import JsonSchemaParser
from lmformatenforcer.integrations.transformers import (
    build_token_enforcer_tokenizer_data, build_transformers_prefix_allowed_tokens_fn)

ROOT = Path(__file__).resolve().parent
tokenizer = AutoTokenizer.from_pretrained(ROOT/'model', local_files_only=True, trust_remote_code=True)
data = build_token_enforcer_tokenizer_data(tokenizer)
schema = json.loads((ROOT/'schema.json').read_text())
prompts = json.loads((ROOT/'prompts.json').read_text(encoding='utf-8'))
lengths = []
for prompt in prompts:
    rendered = tokenizer.apply_chat_template(
        [{'role':'system','content':prompt['system']}, {'role':'user','content':prompt['user']}],
        tokenize=False, add_generation_prompt=True, enable_thinking=False)
    assert rendered.endswith('<think>\n\n</think>\n\n'), repr(rendered[-100:])
    lengths.append(len(tokenizer.encode(rendered, add_special_tokens=False)))
assert max(lengths)+1024 <= 8192
for obj in [{'items':[]}, {'items':[{'line':'U3','kind':'fact','text':'Ја живим у Новом Саду.'}]}]:
    tokens = tokenizer.encode(json.dumps(obj, ensure_ascii=False, separators=(',',':')), add_special_tokens=False)
    allow = build_transformers_prefix_allowed_tokens_fn(data, JsonSchemaParser(schema))
    prefix = [tokenizer.bos_token_id or tokenizer.eos_token_id]
    for token in tokens:
        assert token in allow(0, torch.tensor(prefix)), (token, tokenizer.decode([token]))
        prefix.append(token)
    assert tokenizer.eos_token_id in allow(0, torch.tensor(prefix))
result = {'status':'passed', 'cases':len(prompts), 'prompt_tokens_min':min(lengths),
          'prompt_tokens_max':max(lengths), 'valid_empty_and_serbian_json':True,
          'scope':'tokenizer/schema validation only; no model inference'}
(ROOT/'tokenizer-validation.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result),flush=True)
